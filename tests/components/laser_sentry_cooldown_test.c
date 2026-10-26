/* Laser Sentry Cooldown: the Lua tests' scenarios (components/LaserSentryCooldown/tests/test_cooldown.lua and
 * test_turret.lua, and test_equivalence.lua's session script) on the fake game, with the Laser Sentry's live heat record
 * of build 25480438 (tests/heat_fixture.lua), plus HellForge's routes: the record by identity (component_record), the
 * mapped fields as live edits (set_live), a reload of the entity data.
 *
 * The fake HellForge answers component_record without a record size, keeps set_live's values in a table of its own, and
 * its write cannot reach a read-only page. So the component runs here on a copy of the fake's API whose component_record,
 * set_live and write behave as HellForge's: the record and its 592 bytes; a live edit written into the record, its
 * original put back on undo while the record still holds the edit; the page made writable for the write. Each still
 * calls the fake's own, so the fake counts them. */
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "harness/test.h"
#include "components.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_laser_sentry_cooldown};

#define COMPONENT "WeaponHeatComponentData"
#define SENTRY HF_ENTITY_ALAS98_LASER_SENTRY
#define RESOURCE_LOW 0xCFFFA8A8u
#define RESOURCE_HIGH 0x56070F36u
#define RECORD_SIZE 592u
#define COOLING 0x8Cu
#define ABILITY 0x248u
#define PAGE 0x1000u
#define BLOCK_SIZE 0x4000u
#define RECORD_AT 0x228Cu /* in the weapon data block: the live table 0x57C in (not 8-byte aligned), + 928 + 592 * 11 */
#define WATCH 120
#define DT (1.0f / 60)
#define HEAT_MANAGER_RVA 0x3326D48u
#define BEHAVIOR_MANAGER_RVA 0x3326740u
#define BEHAVIOR_ID 308u
#define BEHAVIOR_SIZE 504u
#define STATE_FIRING 13u
#define STATE_STUCK 6u
#define NO_REQUEST 0xFFFFFFFFu
#define MAP_EMPTY 0xFFFFFFFFu
#define MAP_MULTIPLIER 0x9E3779B1u
#define MAX_SCENE 16

/* The Laser Sentry's WeaponHeatComponent record, read from the running game (Steam build 25480438). */
static const char kRecordHex[] =
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000803f0000803f01000000000000000600000000000000"
    "00007a430000000000002f430000c8420000000000000040000000410000c8420000a0400000403f0000c03f0000c843"
    "010000000000c842000048430000fa430000000047e6ea0fc018c7b500004842df5fb79c6052f47d009970c9e17b7f05"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000803f0000803f000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000803f0000803f"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000803f0000803f000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000803f0000803f"
    "00000000d0772f11d0772f11724dbfae724dbfae6355119b66ea2ab8f00d9d15000000000000000000000000efed0d61"
    "f505005600000000a7518c2b81efc7cea2e63e405b455f356da07a8eb2ad467adcc9b49949b5801c1e604b78938f7f86"
    "d2123be948b224bf320b00000000c842";

/* The record's two changed ranges joined (0x8C: 5 bytes, 0x248: 4 bytes). */
static const uint8_t kChange[9] = {0x00, 0x00, 0xA0, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00};  /* 5.0 (its idle rate), 0; 0 */
static const uint8_t kVanilla[9] = {0x00, 0x00, 0xC8, 0x43, 0x01, 0x32, 0x0B, 0x00, 0x00}; /* 400.0, 1; 2866 */

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static float GetF32(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }

static void Fixture(uint8_t* out)
{
    for (uint32_t i = 0; i < RECORD_SIZE; i++)
    {
        char pair[3] = {kRecordHex[2 * i], kRecordHex[2 * i + 1], 0};
        out[i] = (uint8_t)strtoul(pair, NULL, 16);
    }
}

static uint32_t Total(FakeCounts c)
{
    return c.read + c.write + c.code_matches + c.find_pattern + c.get_live + c.set_live + c.hook + c.log + c.subscribe + c.on + c.other;
}

/* A memory span made writable for a store, then given its protection back. */
static void Poke(void* at, const void* data, size_t size)
{
    DWORD old = 0, ignored = 0;
    CHECK(VirtualProtect(at, size, PAGE_READWRITE, &old)); /* lint-ok: C3 the test stands in for HellForge's write */
    memcpy(at, data, size);
    CHECK(VirtualProtect(at, size, old, &ignored)); /* lint-ok: C3 and puts the protection back */
}

static void Protect(void* at, size_t size, DWORD protection)
{
    DWORD old = 0;
    CHECK(VirtualProtect(at, size, protection, &old)); /* lint-ok: C3 the test gives the fake memory the game's protection */
}

static DWORD ProtectionOf(const void* at)
{
    MEMORY_BASIC_INFORMATION info;
    return VirtualQuery(at, &info, sizeof info) == sizeof info ? info.Protect : 0;
}

static uint8_t* PageAligned(size_t size)
{
    uint8_t* raw = fake_heap(size + 2 * PAGE);
    return (uint8_t*)(((uintptr_t)raw + PAGE - 1) & ~(uintptr_t)(PAGE - 1));
}

/* ---- HellForge's component_record, set_live and write over the fake --------------------------------------------- */

typedef struct LiveEdit { int active; uint8_t original[4], value[4]; } LiveEdit;

static HfApi g_api;
static uint8_t* g_block;     /* the weapon data block holding the record */
static uintptr_t g_record;   /* what component_record answers for the Laser Sentry's WeaponHeat record (0: none) */
static uint32_t g_stride;
static int g_lookups;
static int g_liveCalls, g_refuseLive; /* the g_refuseLive-th set_live is refused (0: none) */
static int g_garble;                  /* set_live writes a wrong byte */
static LiveEdit g_edits[2];           /* 0x8C, 0x90 */

static uintptr_t TestComponentRecord(const char* component, uint64_t resource, uint32_t* stride)
{
    g_lookups++;
    if (strcmp(component, COMPONENT) != 0 || resource != SENTRY) return fake_api()->component_record(component, resource, stride);
    if (stride != NULL) *stride = g_record != 0 ? g_stride : 0;
    return g_record;
}

static int TestSetLive(HfMod* mod, HfRef target, const HfField* field, const HfValue* value, uint32_t flags)
{
    if (++g_liveCalls == g_refuseLive) return fake_api()->set_live(mod, 0, field, value, flags); /* refused: no such target */
    int result = fake_api()->set_live(mod, target, field, value, flags);
    if (result == 0) return 0;
    LiveEdit* e = &g_edits[field->offset == COOLING + 4];
    uint8_t* at = (uint8_t*)g_record + field->offset;
    if (value == NULL)
    {
        if (e->active && memcmp(at, e->value, field->size) == 0) Poke(at, e->original, field->size);
        e->active = 0;
        return result;
    }
    uint8_t bytes[4] = {(uint8_t)value->number, 0, 0, 0};
    if (value->type == HF_TYPE_F32) { float f = (float)value->number; memcpy(bytes, &f, 4); }
    if (!e->active) memcpy(e->original, at, field->size);
    e->active = 1;
    memcpy(e->value, bytes, field->size);
    if (g_garble) bytes[0] ^= 0x5A;
    Poke(at, bytes, field->size);
    return result;
}

static int TestWrite(uintptr_t address, const void* data, size_t size)
{
    DWORD old = 0, ignored = 0;
    int opened = VirtualProtect((void*)address, size, PAGE_READWRITE, &old) != 0; /* lint-ok: C3 HellForge's write opens the page */
    int result = fake_api()->write(address, data, size);
    if (opened && !VirtualProtect((void*)address, size, old, &ignored)) result = 1; /* lint-ok: C3 and closes it again */
    return result;
}

/* The weapon data block (its own pages, with the game's protection) holding a copy of bytes as the record. */
static uint8_t* MakeBlock(const uint8_t* bytes, DWORD protection)
{
    g_block = PageAligned(BLOCK_SIZE);
    memcpy(g_block + RECORD_AT, bytes, RECORD_SIZE);
    Protect(g_block, BLOCK_SIZE, protection);
    g_record = (uintptr_t)(g_block + RECORD_AT);
    return g_block + RECORD_AT;
}

/* A fresh world: the record (bytes, or the live fixture), the fake's live fields for its two mapped values. */
static uint8_t* MakeRecord(const uint8_t* bytes, DWORD protection)
{
    uint8_t fixture[RECORD_SIZE];
    Fixture(fixture);
    if (bytes == NULL) bytes = fixture;
    g_stride = RECORD_SIZE;
    g_lookups = g_liveCalls = g_refuseLive = g_garble = 0;
    memset(g_edits, 0, sizeof g_edits);
    HfValue cooling = HF_F32(GetF32(bytes + COOLING)), reload = HF_U8(bytes[COOLING + 4]);
    fake_live_put(SENTRY, COMPONENT, COOLING, cooling);
    fake_live_put(SENTRY, COMPONENT, COOLING + 4, reload);
    return MakeBlock(bytes, protection);
}

static VpmComponent* Self(void) { return fake_component(0); }

static void Started(void)
{
    g_api = *fake_api();
    g_api.component_record = TestComponentRecord;
    g_api.set_live = TestSetLive;
    g_api.write = TestWrite;
    CHECK_EQ(vpm_core_init(&g_api, fake_mod(), kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
}

/* Whether the record's two ranges hold expected (9 bytes, as kChange). */
static int Holds(const uint8_t* record, const uint8_t* expected)
{
    return memcmp(record + COOLING, expected, 5) == 0 && memcmp(record + ABILITY, expected + 5, 4) == 0;
}

static double LiveNow(uint16_t offset)
{
    HfValue value;
    return fake_live_now(SENTRY, COMPONENT, offset, &value) ? value.number : -1;
}

/* Frames that must make no call: how many did. */
static int CallingFrames(int frames)
{
    int calling = 0;
    for (int i = 0; i < frames; i++)
    {
        fake_counts_reset();
        fake_frames(1, DT);
        calling += Total(fake_counts()) != 0;
    }
    return calling;
}

/* ---- the heat record: test_cooldown.lua ------------------------------------------------------------------------ */

static void ConstantsMatchTheLiveData(void)
{
    uint8_t r[RECORD_SIZE];
    Fixture(r);
    CHECK(GetF32(r + 0x80) == 5.0f);    /* the idle cooling rate: 50 s from max heat 250 */
    CHECK(GetF32(r + 0x60) == 250.0f);
    CHECK_EQ(r[0x50], 1);
    CHECK_EQ(Get32(r + 0x54), 0);
    CHECK_EQ(Get32(r + 0x5C), 0);
    CHECK_EQ(Get32(r + 0x64), 0);
    CHECK(memcmp(r + COOLING, kVanilla, 5) == 0);
    CHECK_EQ(Get32(r + ABILITY), 2866);
    CHECK(memcmp(kChange, r + 0x80, 4) == 0);
    CHECK(SENTRY == ((uint64_t)RESOURCE_HIGH << 32 | RESOURCE_LOW));
    /* HellForge's mapped fields are the Lua's offsets */
    CHECK_EQ(offsetof(HfWeaponHeat, cool_per_second), 0x80);
    CHECK_EQ(offsetof(HfWeaponHeat, cool_per_second_overheated), COOLING);
    CHECK_EQ(offsetof(HfWeaponHeat, prevent_overheat_cooling), COOLING + 4);
    CHECK_EQ(sizeof(HfWeaponHeat), RECORD_SIZE);
}

/* Reported 2026-10-05 (v1.0, in a mission): "it overheated and exploded mid-match". With the change in place the record
 * names no overheat ability, and the overheated sentry cools at its own idle rate with no reload needed. */
static void ReportedAnOverheatedSentryExploded(void)
{
    uint8_t* record = MakeRecord(NULL, PAGE_READONLY);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(Get32(record + ABILITY), 0);
    CHECK(GetF32(record + COOLING) == 5.0f && record[COOLING + 4] == 0);
}

/* The Lua's boot wait and its install: nothing before the entity data; at HF_EVENT_ENTITIES_READY the record by
 * identity, one read, the page check, two live edits, the ability through HfApi.write (the page is read-only), one
 * read-back; the page read-only again; then nothing per frame. */
static void AppliesAtLoadThenNothingPerFrame(void)
{
    uint8_t* record = MakeRecord(NULL, PAGE_READONLY);
    Started();
    CHECK(strcmp(vpm_status(Self()), "waiting for the weapon data") == 0);
    CHECK(!vpm_ticking(Self()));
    CHECK_EQ(CallingFrames(300), 0);
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    FakeCounts c = fake_counts();
    CHECK_EQ(c.read, 2);
    CHECK_EQ(c.set_live, 2);
    CHECK_EQ(c.write, 1);
    CHECK_EQ(c.log, 1);
    CHECK_EQ(Total(c), 6);
    CHECK_EQ(g_lookups, 1);
    CHECK(Holds(record, kChange));
    CHECK_EQ(ProtectionOf(record), PAGE_READONLY);
    CHECK(LiveNow(COOLING) == 5.0 && LiveNow(COOLING + 4) == 0);
    CHECK(strcmp(vpm_status(Self()), "active") == 0);
    CHECK_LOG("[Laser Sentry Cooldown] Laser Sentry heat record changed: an overheated Laser Sentry no longer explodes, "
        "cools at its own idle rate (5 heat/s, 50 s from max heat 250 at normal planet temperature) and fires again.");
    CHECK(vpm_ticking(Self()));
    CHECK_EQ(CallingFrames(10 * WATCH), 0); /* the looks find no WeaponHeat manager: a plain load in game.dll */
}

static void AReadWritePageIsWrittenDirectly(void)
{
    uint8_t* record = MakeRecord(NULL, PAGE_READWRITE);
    Started();
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Holds(record, kChange));
    CHECK_EQ(fake_counts().read, 2);
    CHECK_EQ(fake_counts().set_live, 2);
    CHECK_EQ(fake_counts().write, 0); /* the ability: a plain store */
}

/* A record that already holds the change is kept without a write. This session changed nothing, so a stop puts nothing
 * back (the Lua's restore wrote the vanilla bytes over it). */
static void AChangedRecordIsKeptWithoutAWrite(void)
{
    uint8_t bytes[RECORD_SIZE];
    Fixture(bytes);
    memcpy(bytes + COOLING, kChange, 5);
    memcpy(bytes + ABILITY, kChange + 5, 4);
    uint8_t* record = MakeRecord(bytes, PAGE_READONLY);
    Started();
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(fake_counts().read, 1);
    CHECK_EQ(fake_counts().set_live + fake_counts().write, 0);
    CHECK_LOG("Laser Sentry heat record already changed: an overheated Laser Sentry no longer explodes");
    CHECK(vpm_ticking(Self()));
    vpm_core_stop(Self(), "test stop");
    CHECK(Holds(record, kChange));
}

typedef struct Refusal { const char* reason; int untouched; } Refusal;
static const Refusal kRefusals[] = {
    {"Laser Sentry heat record not found", 1},                /* component_record: none (absent, shared, or its table unexpected) */
    {"unexpected Laser Sentry heat record size 600", 1},
    {"Laser Sentry heat record unreadable", 1},
    {"unexpected Laser Sentry heat record (offset 0x60)", 1}, /* overheat temperature 300 */
    {"unexpected Laser Sentry heat record (offset 0x54)", 1}, /* a spare heat sink */
    {"unexpected Laser Sentry heat record (offset 0x50)", 1}, /* overheating off */
    {"unexpected Laser Sentry cooling rate", 1},              /* no idle cooling to copy */
    {"unexpected Laser Sentry cooling rate", 1},              /* NaN */
    {"Laser Sentry heat record already changed by something else", 1}, /* 1.0 heat/s from someone else */
    {"Laser Sentry heat record already changed by something else", 1}, /* another overheat ability */
    {"Laser Sentry heat record already changed by something else", 1}, /* only the cooling range changed */
    {"unexpected page protection 0x20", 1},                   /* an executable page */
    {"write failed (HellForge: fake: no such field)", 1},     /* the first live edit refused: nothing landed */
    {"write failed (HellForge: fake: no such field)", 1},     /* the second refused: the first is undone */
    {"write failed", 1},                                      /* the ability's write refused: both live edits undone */
    {"write did not read back", 0},                           /* the bytes read back wrong: the restore fails the same way */
};
#define REFUSALS ((int)(sizeof kRefusals / sizeof kRefusals[0]))

/* Case c's record bytes and protection, and its failure set up after the world. */
static DWORD RefusalRecord(int c, uint8_t* bytes)
{
    Fixture(bytes);
    if (c == 3) Put32(bytes + 0x60, 0x43960000u);
    if (c == 4) Put32(bytes + 0x54, 1);
    if (c == 5) bytes[0x50] = 0;
    if (c == 6) Put32(bytes + 0x80, 0);
    if (c == 7) Put32(bytes + 0x80, 0x7FC00000u);
    if (c == 8) Put32(bytes + COOLING, 0x3F800000u);
    if (c == 9) Put32(bytes + ABILITY, 1234);
    if (c == 10) memcpy(bytes + COOLING, kChange, 5);
    return c == 11 ? PAGE_EXECUTE_READ : PAGE_READONLY;
}

static void RefusalFailure(int c, uint8_t* record)
{
    if (c == 0) g_record = 0;
    if (c == 1) g_stride = 600;
    if (c == 2) fake_hole((uintptr_t)record, RECORD_SIZE);
    if (c == 12) g_refuseLive = 1;
    if (c == 13) g_refuseLive = 2;
    if (c == 14) fake_refuse_writes(1);
    if (c == 15) g_garble = 1;
}

/* Every refusal: the component stopped, the record and the page as they were (unless the restore itself failed), and
 * nothing per frame afterwards. */
static void RefusalsLeaveTheRecordAlone(void)
{
    for (int c = 0; c < REFUSALS; c++)
    {
        int before = test_failures;
        fake_setup();
        uint8_t bytes[RECORD_SIZE];
        DWORD protection = RefusalRecord(c, bytes);
        uint8_t* record = MakeRecord(bytes, protection);
        RefusalFailure(c, record);
        Started();
        fake_fire(HF_EVENT_ENTITIES_READY);
        CHECK(!vpm_running(Self()));
        CHECK_LOG(kRefusals[c].reason);
        CHECK(memcmp(record, bytes, RECORD_SIZE) == 0 || !kRefusals[c].untouched);
        CHECK_EQ(ProtectionOf(record), protection);
        CHECK(!vpm_ticking(Self()));
        CHECK_EQ(CallingFrames(40), 0);
        if (c >= 12 && c <= 14) CHECK(LiveNow(COOLING) == 400.0 && LiveNow(COOLING + 4) == 1);
        if (!kRefusals[c].untouched) CHECK_LOG("restore failed: write did not read back");
        if (test_failures != before) printf("  (refusal %d: %s)\n", c, kRefusals[c].reason);
    }
}

/* The core stopping the component (a fault, say): the vanilla record back, read-only again, the live edits undone. */
static void AStopRestoresTheVanillaRecord(void)
{
    uint8_t* record = MakeRecord(NULL, PAGE_READONLY);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Holds(record, kChange));
    fake_counts_reset();
    vpm_core_stop(Self(), "test stop");
    CHECK(Holds(record, kVanilla));
    CHECK_EQ(ProtectionOf(record), PAGE_READONLY);
    CHECK(LiveNow(COOLING) == 400.0 && LiveNow(COOLING + 4) == 1);
    CHECK_EQ(fake_counts().set_live, 2);
    CHECK_EQ(fake_counts().write, 1);
    CHECK_EQ(fake_counts().read, 1);
    CHECK_LOG("[Laser Sentry Cooldown] disabled: test stop");
    CHECK_NO_LOG("restore failed");
    CHECK_EQ(CallingFrames(2 * WATCH), 0);
}

static void AnotherBuildLeavesItOff(void)
{
    uint8_t* record = MakeRecord(NULL, PAGE_READONLY);
    fake_set_build("25000000");
    Started();
    CHECK(!vpm_running(Self()));
    CHECK(strstr(vpm_status(Self()), "needs game build 25480438") != NULL);
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Holds(record, kVanilla));
    CHECK_EQ(g_lookups, 0);
}

/* HellForge: the game reloads its entity data (HF_EVENT_ENTITIES_READY again, a new record). HellForge has renewed
 * the two live edits in it, the ability is the game's: the ability is written again. Without the renewal, the whole
 * change is. A stop then puts the new record back. */
static void AReloadWritesTheChangeAgain(void)
{
    uint8_t vanilla[RECORD_SIZE], renewed[RECORD_SIZE];
    Fixture(vanilla);
    uint8_t* first = MakeRecord(vanilla, PAGE_READONLY);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Holds(first, kChange));
    memcpy(renewed, vanilla, RECORD_SIZE);
    memcpy(renewed + COOLING, kChange, 5);
    uint8_t* second = MakeBlock(renewed, PAGE_READONLY);
    fake_counts_reset();
    fake_log_clear();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Holds(second, kChange));
    CHECK_EQ(fake_counts().read, 2);
    CHECK_EQ(fake_counts().set_live, 2);
    CHECK_EQ(fake_counts().write, 1);
    CHECK_LOG("Laser Sentry heat record changed");
    CHECK(vpm_running(Self()) && vpm_ticking(Self()));
    uint8_t* third = MakeBlock(vanilla, PAGE_READONLY);
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Holds(third, kChange));
    vpm_core_stop(Self(), "test stop");
    CHECK(Holds(third, kVanilla));
    CHECK_NO_LOG("restore failed");
}

/* ---- the turret watch: test_turret.lua -------------------------------------------------------------------------- */

typedef struct Instance
{
    int present;
    uint32_t id;
    int sentry;          /* a Laser Sentry, else another heat weapon */
    uint32_t flags;      /* entity record +20: 1 = owned and simulated here */
    uint8_t overheated;  /* its replicated state's flag */
    uint32_t behavior;   /* its behavior id (0: none) */
    uint32_t state, request;
    uint8_t* record;     /* its 24-byte entity record */
    uint8_t* block;      /* its behavior block, after Sync */
} Instance;

/* The WeaponHeat and behavior managers of a mission (the Lua's G.scene). */
static struct
{
    Instance pool[MAX_SCENE];
    int used;
    uint32_t capacity;
    int wrongRecord;     /* the map points each sentry at another entity's block */
    uint8_t *heat, *heatRecords, *states, *entities, *manager, *entries, *owners, *blocks;
} g_scene;

static void SetManagers(uint8_t* heat, uint8_t* manager)
{
    Put64((uint8_t*)fake_game() + HEAT_MANAGER_RVA, (uint64_t)(uintptr_t)heat);
    Put64((uint8_t*)fake_game() + BEHAVIOR_MANAGER_RVA, (uint64_t)(uintptr_t)manager);
}

static void MakeScene(uint32_t capacity, int wrongRecord)
{
    memset(&g_scene, 0, sizeof g_scene);
    g_scene.capacity = capacity;
    g_scene.wrongRecord = wrongRecord;
    g_scene.heat = fake_heap(96);
    g_scene.heatRecords = fake_heap(8 * MAX_SCENE);
    g_scene.states = fake_heap(12 * MAX_SCENE);
    g_scene.entities = fake_heap(64 * MAX_SCENE);
    g_scene.manager = fake_heap(104);
    g_scene.entries = fake_heap(8 * 64);
    g_scene.owners = fake_heap(8 * MAX_SCENE);
    g_scene.blocks = PageAligned(PAGE);
    SetManagers(g_scene.heat, g_scene.manager);
}

static Instance* Add(uint32_t id, int sentry, uint32_t flags)
{
    Instance* in = &g_scene.pool[g_scene.used];
    *in = (Instance){1, id, sentry, flags, 0, BEHAVIOR_ID, STATE_FIRING, NO_REQUEST, g_scene.entities + 64 * g_scene.used, NULL};
    g_scene.used++;
    return in;
}

static void Remove(Instance* in) { in->present = 0; in->block = NULL; }

static int Present(Instance** list, int withBehavior)
{
    int n = 0;
    for (int i = 0; i < g_scene.used; i++)
        if (g_scene.pool[i].present && (!withBehavior || g_scene.pool[i].behavior != 0)) list[n++] = &g_scene.pool[i];
    return n;
}

static void SyncHeat(void)
{
    Instance* list[MAX_SCENE];
    int count = Present(list, 0);
    memset(g_scene.heat, 0, 96);
    for (int k = 0; k < 3; k++) Put32(g_scene.heat + 20 + 4 * k, (uint32_t)count);
    Put64(g_scene.heat + 64, (uint64_t)(uintptr_t)g_scene.heatRecords);
    Put64(g_scene.heat + 88, (uint64_t)(uintptr_t)g_scene.states);
    for (int i = 0; i < count; i++)
    {
        Instance* in = list[i];
        Put64(g_scene.heatRecords + 8 * i, (uint64_t)(uintptr_t)in->record);
        memset(g_scene.states + 12 * i, 0, 12);
        g_scene.states[12 * i + 8] = in->overheated;
        Put32(in->record, in->sentry ? RESOURCE_LOW : 0x11111111u);
        Put32(in->record + 4, in->sentry ? RESOURCE_HIGH : 0x22222222u);
        Put32(in->record + 8, in->id);
        Put64(in->record + 12, 0);
        Put32(in->record + 20, in->flags);
    }
}

/* The entity id map, probed as the engine fills it: (id * multiplier + k) mod capacity. */
static void SyncMap(Instance** list, int count)
{
    for (uint32_t slot = 0; slot < g_scene.capacity; slot++)
    {
        Put32(g_scene.entries + 8 * slot, MAP_EMPTY);
        Put32(g_scene.entries + 8 * slot + 4, 0);
    }
    for (int index = 0; index < count; index++)
    {
        uint32_t target = g_scene.wrongRecord ? (uint32_t)((index + 1) % count) : (uint32_t)index;
        for (uint32_t k = 0; k < g_scene.capacity; k++)
        {
            uint32_t slot = (list[index]->id * MAP_MULTIPLIER + k) % g_scene.capacity;
            if (Get32(g_scene.entries + 8 * slot) != MAP_EMPTY) continue;
            Put32(g_scene.entries + 8 * slot, list[index]->id);
            Put32(g_scene.entries + 8 * slot + 4, target);
            break;
        }
    }
}

static void SyncBehaviors(void)
{
    Instance* list[MAX_SCENE];
    int count = Present(list, 1);
    uint8_t* m = g_scene.manager;
    memset(m, 0, 104);
    Put32(m + 52, (uint32_t)count);
    Put64(m + 64, (uint64_t)(uintptr_t)g_scene.entries);
    Put32(m + 72, g_scene.capacity);
    Put32(m + 76, MAP_EMPTY);
    Put32(m + 80, MAP_MULTIPLIER);
    Put64(m + 88, (uint64_t)(uintptr_t)g_scene.owners);
    Put64(m + 96, (uint64_t)(uintptr_t)g_scene.blocks);
    SyncMap(list, count);
    for (int i = 0; i < count; i++)
    {
        Instance* in = list[i];
        Put64(g_scene.owners + 8 * i, (uint64_t)(uintptr_t)in->record);
        in->block = g_scene.blocks + BEHAVIOR_SIZE * i;
        uint32_t words[5] = {in->behavior, 0, in->state, in->request, in->state};
        memcpy(in->block, words, sizeof words);
    }
}

static void Sync(void)
{
    SyncHeat();
    SyncBehaviors();
}

/* The instance's behavior block now: state, pending request (the last state set in *last). */
static uint32_t Turret(const Instance* in, uint32_t* request, uint32_t* last)
{
    *request = Get32(in->block + 12);
    if (last != NULL) *last = Get32(in->block + 16);
    return Get32(in->block + 8);
}

/* The game's next behavior update: each pending request becomes the state (0x32B6B0 stores the state, -1 as the request
 * and the state as the last set), unless state 12 refuses it (0x4962C0 for behavior 308). */
static void ApplyRequests(void)
{
    for (int i = 0; i < g_scene.used; i++)
    {
        Instance* in = &g_scene.pool[i];
        if (in->block == NULL) continue;
        uint32_t request, state = Turret(in, &request, NULL);
        if (request == NO_REQUEST || state == 12) continue;
        uint32_t words[3] = {request, NO_REQUEST, request};
        memcpy(in->block + 8, words, sizeof words);
        in->state = request;
        in->request = NO_REQUEST;
    }
}

/* One watch interval: WATCH - 1 frames without a call, then the look. Returns the look's calls. */
static FakeCounts LookCalls(void)
{
    CHECK_EQ(CallingFrames(WATCH - 1), 0);
    fake_counts_reset();
    fake_frames(1, DT);
    return fake_counts();
}

/* A look's calls: reads, log lines, and nothing else. */
#define EXPECT_LOOK(calls, reads, logs) do { FakeCounts c_ = (calls); CHECK_EQ(c_.read, (reads)); CHECK_EQ(c_.log, (logs)); \
    CHECK_EQ(Total(c_), (reads) + (logs)); } while (0)
/* The reads of each kind of look (the Lua's LOOK, less its pointer reads in game.dll: plain loads here). */
#define LOOK_MENUS 0   /* no WeaponHeat manager */
#define LOOK_SHIP 1    /* a manager without instances: its header */
#define LOOK_IDLE 2    /* instances, none overheated, none watched: + their states */
#define LOOK_SEEN 4    /* a newly overheated instance: + every record pointer + its record */
#define LOOK_COOLING 3 /* a watched sentry still hot, or another weapon already known */
#define LOOK_REPAIR 9  /* a watched sentry cooled: its record again, the behavior manager, a map probe, the record check,
                        * the block, the 4-byte request (one page query, a store) and its read-back; once per overheat */

/* The record changed at load, the scene built (MakeScene, Add, then this), the watch running. */
static void Mission(void)
{
    Sync();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(vpm_ticking(Self()));
}

/* Reported 2026-10-05 (v1.1 test build): "the explosion stop worked but the turret never came back online". Its behavior
 * stayed in state 6. Nothing is written while it cools; the first look after its overheated flag clears requests state 7
 * (power up), once, and the game's next update applies it. */
static void ReportedACooledSentryNeverCameBack(void)
{
    MakeRecord(NULL, PAGE_READONLY);
    MakeScene(16, 0);
    Instance* sentry = Add(721, 1, 1);
    Mission();
    EXPECT_LOOK(LookCalls(), LOOK_IDLE, 0);
    sentry->overheated = 1;
    sentry->state = STATE_STUCK; /* what the firing state does at the overheat */
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_SEEN, 0);
    for (int i = 0; i < 24; i++) EXPECT_LOOK(LookCalls(), LOOK_COOLING, 0); /* 50 s at 60 frames per second */
    uint32_t request, last;
    CHECK_EQ(Turret(sentry, &request, NULL), STATE_STUCK);
    CHECK_EQ(request, NO_REQUEST);
    sentry->overheated = 0; /* cooled: the heat rule cleared the flag; the behavior is still in state 6 */
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_REPAIR, 1);
    CHECK_EQ(Turret(sentry, &request, NULL), STATE_STUCK);
    CHECK_EQ(request, 7);
    ApplyRequests();
    CHECK_EQ(Turret(sentry, &request, &last), 7);
    CHECK_EQ(request, NO_REQUEST);
    CHECK_EQ(last, 7);
    CHECK_LOG("[Laser Sentry Cooldown] Laser Sentry 721 cooled down: its turret powers up again.");
    for (int i = 0; i < 3; i++) EXPECT_LOOK(LookCalls(), LOOK_IDLE, 0);
    CHECK_EQ(Turret(sentry, &request, NULL), 7);
    CHECK_EQ(request, NO_REQUEST);
}

static void LooksOutsideAMission(void)
{
    MakeRecord(NULL, PAGE_READONLY);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    EXPECT_LOOK(LookCalls(), LOOK_MENUS, 0);
    MakeScene(16, 0);
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_SHIP, 0);
}

/* Not owned; not owned and remote; owned but simulated elsewhere. */
static void AnotherMachinesSentryIsLeftAlone(void)
{
    static const uint32_t kFlags[] = {0, 2, 3};
    for (int f = 0; f < 3; f++)
    {
        fake_setup();
        MakeRecord(NULL, PAGE_READONLY);
        MakeScene(16, 0);
        Instance* sentry = Add(900, 1, kFlags[f]);
        Mission();
        sentry->overheated = 1;
        sentry->state = STATE_STUCK;
        Sync();
        EXPECT_LOOK(LookCalls(), LOOK_SEEN, 0);
        EXPECT_LOOK(LookCalls(), LOOK_COOLING, 0); /* known: its record is not read again */
        sentry->overheated = 0;
        Sync();
        EXPECT_LOOK(LookCalls(), LOOK_IDLE, 0);
        uint32_t request;
        CHECK_EQ(Turret(sentry, &request, NULL), STATE_STUCK);
        CHECK_EQ(request, NO_REQUEST);
    }
}

static void AnotherHeatWeaponIsReadOncePerOverheat(void)
{
    MakeRecord(NULL, PAGE_READONLY);
    MakeScene(16, 0);
    Instance* rifle = Add(50, 0, 1);
    Mission();
    rifle->overheated = 1;
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_SEEN, 0);
    for (int i = 0; i < 5; i++) EXPECT_LOOK(LookCalls(), LOOK_COOLING, 0);
    rifle->overheated = 0;
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_IDLE, 0);
    rifle->overheated = 1;
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_SEEN, 0); /* it overheats again: its record is read again */
}

static void ASentryRemovedWhileItCoolsIsForgotten(void)
{
    MakeRecord(NULL, PAGE_READONLY);
    MakeScene(16, 0);
    Instance* sentry = Add(721, 1, 1);
    Add(50, 0, 1);
    Mission();
    sentry->overheated = 1;
    sentry->state = STATE_STUCK;
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_SEEN, 0);
    Remove(sentry);
    Sync();
    EXPECT_LOOK(LookCalls(), LOOK_COOLING, 0); /* gone: its pointer is not there any more */
    EXPECT_LOOK(LookCalls(), LOOK_IDLE, 0);    /* forgotten */
    CHECK_NO_LOG("Laser Sentry 721");
}

/* A cooled sentry whose turret is not as expected is left as it is (the log says why), and the component goes on. */
static void ACooledSentryNotAsExpectedIsLeftAlone(void)
{
    static const char* const kReasons[] = {
        "turret in state 2", "turret state 3 already requested", "unexpected behavior 300", "unexpected behavior manager",
        "behavior of another entity", "unexpected page protection 0x20",
    };
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        MakeRecord(NULL, PAGE_READONLY);
        MakeScene(c == 3 ? 12 : 16, c == 4); /* 12: not a power of two */
        Instance* sentry = Add(721, 1, 1);
        Add(722, 1, 0); /* a second behavior block */
        Mission();
        sentry->overheated = 1;
        sentry->state = c == 0 ? 2 : STATE_STUCK; /* something else moved it on */
        if (c == 1) sentry->request = 3;          /* another request pending */
        if (c == 2) sentry->behavior = 300;
        Sync();
        (void)LookCalls();
        sentry->overheated = 0;
        Sync();
        if (c == 5) Protect(g_scene.blocks, PAGE, PAGE_EXECUTE_READ);
        (void)LookCalls();
        if (c == 5) Protect(g_scene.blocks, PAGE, PAGE_READWRITE);
        char line[160];
        snprintf(line, sizeof line, "Laser Sentry 721 cooled down; its turret was left as it is (%s).", kReasons[c]);
        CHECK_LOG(line);
        uint32_t request;
        CHECK(Turret(sentry, &request, NULL) != 7 && request != 7);
        CHECK(vpm_running(Self()) && vpm_ticking(Self()));
    }
}

/* ---- a whole session: test_equivalence.lua's script ------------------------------------------------------------- */

typedef struct Cast { Instance *a, *b, *rifle, *c; } Cast;

/* What changes in the game on a frame (the Lua's EVENTS); 1 when the scene is to be synced. */
static int SessionEvent(int frame, Cast* k)
{
    switch (frame)
    {
    case 300: MakeScene(16, 0); return 1; /* the ship: a manager without instances */
    case 600: k->a = Add(721, 1, 1); k->b = Add(722, 1, 0); k->rifle = Add(50, 0, 1); return 1;
    case 900: k->a->overheated = 1; k->a->state = STATE_STUCK; k->rifle->overheated = 1; return 1;
    case 1300: k->rifle->overheated = 0; return 1;
    case 1500: k->a->overheated = 0; return 1; /* cooled: the next look requests state 7 */
    case 1700: ApplyRequests(); return 1;      /* the game's behavior update applies it */
    case 1800: k->a->overheated = k->b->overheated = 1; k->a->state = k->b->state = STATE_STUCK; return 1;
    case 2000: Remove(k->a); return 1;         /* gone while it cools */
    case 2100: k->c = Add(723, 1, 1); k->c->overheated = 1; k->c->state = STATE_STUCK; return 1;
    case 2300: k->c->overheated = 0; k->c->request = 3; return 1; /* another request pending: refused */
    case 2400: k->b->overheated = 0; return 1;
    case 2700: Remove(k->b); Remove(k->c); Remove(k->rifle); return 1; /* back to the ship */
    case 2900: SetManagers(NULL, NULL); return 0; /* the menus */
    default: return 0;
    }
}

static void AWholeSession(void)
{
    uint8_t* record = MakeRecord(NULL, PAGE_READONLY);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    Cast k;
    memset(&k, 0, sizeof k);
    int quietWithCalls = 0, looksWithCalls = 0;
    for (int frame = 1; frame <= 3200; frame++)
    {
        if (SessionEvent(frame, &k)) Sync();
        fake_counts_reset();
        fake_frames(1, DT);
        int calls = Total(fake_counts()) != 0;
        if (frame % WATCH != 0) quietWithCalls += calls;
        else looksWithCalls += calls;
    }
    CHECK_EQ(quietWithCalls, 0);
    CHECK_EQ(looksWithCalls, 22); /* frames 360 .. 2880: the ship and the mission (menus: plain loads) */
    CHECK_LOG("Laser Sentry 721 cooled down: its turret powers up again.");
    CHECK_LOG("Laser Sentry 723 cooled down; its turret was left as it is (turret state 3 already requested).");
    CHECK_NO_LOG("Laser Sentry 722");
    CHECK(Holds(record, kChange));
    CHECK(vpm_running(Self()) && strcmp(vpm_status(Self()), "active") == 0);
}

int main(void)
{
    RUN(ConstantsMatchTheLiveData);
    RUN(ReportedAnOverheatedSentryExploded);
    RUN(AppliesAtLoadThenNothingPerFrame);
    RUN(AReadWritePageIsWrittenDirectly);
    RUN(AChangedRecordIsKeptWithoutAWrite);
    RUN(RefusalsLeaveTheRecordAlone);
    RUN(AStopRestoresTheVanillaRecord);
    RUN(AnotherBuildLeavesItOff);
    RUN(AReloadWritesTheChangeAgain);
    RUN(ReportedACooledSentryNeverCameBack);
    RUN(LooksOutsideAMission);
    RUN(AnotherMachinesSentryIsLeftAlone);
    RUN(AnotherHeatWeaponIsReadOncePerOverheat);
    RUN(ASentryRemovedWhileItCoolsIsForgotten);
    RUN(ACooledSentryNotAsExpectedIsLeftAlone);
    RUN(AWholeSession);
    TEST_END();
}
