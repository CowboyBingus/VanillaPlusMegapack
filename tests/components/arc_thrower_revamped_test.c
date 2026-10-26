/* Arc Thrower Revamped: the Lua tests' scenarios (components/ArcThrowerRevamped/tests/test_work_budget.lua: the pinned
 * calls per frame, the firing run and the recovery scenarios) on the fake game, plus HellForge's identity lookup of the
 * charge record (component_record, set_live, get_live).
 *
 * The world is the Lua test's: the local avatar at index 1 of the avatar manager, its Fire slot, one weapon holder row,
 * a trigger table of 2 entries (the weapon at 0, a second at 1), a charge table of 512 (the weapon at 511, the second at
 * 510; at 3 of another entry array once "relocated"), the mission record. Each frame the test plays the engine's trigger
 * handler first (every charge entry's flag = the engine's flag), then runs the tick, then counts the flags the tick set.
 * The fake's read and component_record are wrapped here: a read can be blocked and unblocked (fake_hole cannot be
 * undone), and the record the identity lookup answers can change. HellForge's set_live writes the record: the test copies
 * the fake's live value into the record after each frame that called it. */
#include <string.h>
#include "harness/test.h"
#include "components.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_arc_thrower_revamped};

#define ARC HF_ENTITY_ARC3_ARC_THROWER
#define COMPONENT "WeaponChargeComponentData"
#define AUTO_FIRE 184u
#define RVA_PM 0x3326468u
#define RVA_OWNER 0x346BF98u
#define RVA_AM 0x3326D20u
#define RVA_HOLDERS 0x3326DC0u
#define RVA_TRIGGER 0x3326660u
#define RVA_CHARGE 0x3326C20u
#define RVA_MODE 0x33266A0u
#define RVA_SETTER 0x755F90u
#define OWNER_SIZE (0xF32F18u + 4u * 24u)
#define AM_SIZE 0xB0000u
#define ENTRIES_SIZE 0x5000u /* 512 entries of 40 bytes */
#define DT 0.01f              /* the Lua test's update: 10 ms */
#define UNIT 9u
#define AVATAR_ID 222u
#define WEAPON_ID 77u

static const uint8_t kFingerprint[16] = {0x0F, 0xD7, 0xD6, 0x1A, 0x96, 0xFB, 0xA2, 0x29, 0xA9, 0x31, 0xEE, 0x67, 0x0E, 0x04,
    0x95, 0x41};
static const uint8_t kSetter[15] = {0x48, 0x89, 0x4C, 0x24, 0x08, 0x53, 0x55, 0x56, 0x57, 0x41, 0x57, 0x48, 0x83, 0xEC, 0x20};
static const uint8_t kAvatarType[8] = {0x97, 0xFA, 0x4D, 0x29, 0x4D, 0x33, 0x1C, 0x4D};
static const uint32_t kEntryIndexes[3] = {3, 510, 511};

/* The Lua test's script variables. */
typedef struct Knobs
{
    int down, arc, second, relocated, mission, command, aim, inputValid, dense;
    uint32_t missionType, generation, triggerCount, triggerSlot;
    float held, full, charge;
    uint8_t engineFlag;
} Knobs;

typedef struct World
{
    uint8_t *pm, *player, *owner, *avatar, *am, *amRows, *holders, *holderRows, *rows, *trigger, *entities, *flags;
    uint8_t *charge, *charged, *entries[2], *weapon, *second, *ordinary, *mode, *record, *record2, *identity;
    uint32_t avatarIndex;
    int refuseLive;    /* HellForge has no live field for the record: set_live refuses */
    DWORD protect;     /* a protection the first entry array has while the tick runs (0: read-write) */
    Knobs k;
    int writes, wrong; /* charging flags the ticks set: on the expected entry, elsewhere */
    int recordChecks;  /* 216-byte reads (the charge record) */
    int headerReads;   /* reads of the charge manager's header */
} World;
static World w;

/* Reads the test blocks (the Lua test's input_valid = false and blocked[address]). */
enum { BLOCK_INPUT, BLOCK_IDENTITY, BLOCK_HOLDER, BLOCK_BINDING, BLOCKS };
typedef struct Block { uintptr_t at; size_t size; int on; } Block;
static Block g_blocks[BLOCKS];
static HfApi g_api;

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutPointer(uint8_t* at, const void* p) { Put64(at, (uint64_t)(uintptr_t)p); }
static void PutF(uint8_t* at, float v) { memcpy(at, &v, 4); }

static int TestRead(uintptr_t address, void* buffer, size_t size)
{
    int result = fake_api()->read(address, buffer, size);
    if (size == 216) w.recordChecks++;
    if (address == (uintptr_t)w.charge + 16) w.headerReads++;
    for (int i = 0; i < BLOCKS; i++)
        if (g_blocks[i].on && address < g_blocks[i].at + g_blocks[i].size && g_blocks[i].at < address + size) return 1;
    return result;
}

static uintptr_t TestComponentRecord(const char* component, uint64_t resource, uint32_t* stride)
{
    int arc = strcmp(component, COMPONENT) == 0 && resource == ARC && w.identity != NULL;
    if (stride) *stride = arc ? 216 : 0;
    return arc ? (uintptr_t)w.identity : 0;
}

static void Blocking(int which, const void* at, size_t size, int on) { g_blocks[which] = (Block){(uintptr_t)at, size, on}; }

/* ---- the world --------------------------------------------------------------------------------------------------- */

/* A lookup of capacity 8 (multiplier 1, empty key 0xFFFFFFFF) holding key -> index; its rows. */
static void SetRow(uint8_t* rows, uint32_t key, uint32_t index)
{
    Put32(rows + key % 8 * 8, key);
    Put32(rows + key % 8 * 8 + 4, index);
}

static uint8_t* Map(uint8_t* header, uint32_t key, uint32_t index)
{
    uint8_t* rows = fake_heap(64);
    memset(rows, 0xFF, 64);
    SetRow(rows, key, index);
    PutPointer(header, rows);
    Put32(header + 8, 8);
    Put32(header + 12, 0xFFFFFFFFu);
    Put32(header + 16, 1);
    return rows;
}

/* Page-aligned memory on pages of its own. */
static uint8_t* Pages(size_t size)
{
    uintptr_t at = (uintptr_t)fake_heap(size + 0x2000);
    return (uint8_t*)((at + 0xFFF) & ~(uintptr_t)0xFFF);
}

static uint8_t* MakeRecord(void)
{
    uint8_t* record = fake_heap(216);
    PutF(record + 0, 1.0f);
    PutF(record + 24, 1.1f);
    PutF(record + 48, 1.2f);
    PutF(record + 72, 0.7f);
    PutF(record + 76, 1.4f);
    memcpy(record + 168, kFingerprint, sizeof kFingerprint);
    return record;
}

static uint8_t* Slot(uint32_t index) { return w.am + 0x150 + index * 0xA7AECu + 0x1B68 + 9 * 32; }
static uint8_t* Entry(int array, uint32_t index) { return w.entries[array] + index * 40u; }

static void BuildPlayer(void)
{
    w.pm = fake_heap(0x400);
    w.player = fake_heap(24);
    w.owner = fake_heap(OWNER_SIZE);
    w.am = fake_heap(AM_SIZE);
    Put32(w.pm + 0x84, 2);
    Put32(w.pm + 0x88, 2);
    Put32(w.pm + 0x3A8, UNIT);
    PutPointer(w.pm + 0xE8, w.player);
    w.player[20] = 1;
    (void)Map(w.owner + 0xF22EC8, UNIT, 1);
    w.avatar = w.owner + 0xF32F18 + 24;
    memcpy(w.avatar, kAvatarType, 8);
    Put32(w.avatar + 8, AVATAR_ID);
    Put32(w.avatar + 12, 4194313u);
    w.avatar[20] = 1;
    Put32(w.am + 0x6C, 2);
    PutPointer(w.am + 0x118, w.avatar);
    w.amRows = Map(w.am + 0xF8, AVATAR_ID, 1);
    w.avatarIndex = 1;
}

static void BuildTables(void)
{
    w.holders = fake_heap(72);
    w.rows = fake_heap(48 * 4);
    w.holderRows = Map(w.holders + 32, WEAPON_ID, 1);
    PutPointer(w.holders + 64, w.rows);
    Put32(w.rows + 48 + 4, AVATAR_ID);
    w.trigger = fake_heap(96);
    w.entities = fake_heap(4096 * 8);
    w.flags = fake_heap(4096);
    w.charge = fake_heap(72);
    w.charged = fake_heap(512 * 8);
    w.entries[0] = Pages(ENTRIES_SIZE);
    w.entries[1] = Pages(ENTRIES_SIZE);
    w.weapon = fake_heap(24);
    w.second = fake_heap(24);
    w.ordinary = fake_heap(24);
    memcpy(w.ordinary, "ordinary", 8);
    w.mode = fake_heap(68);
}

static void Build(void)
{
    memset(&w, 0, sizeof w);
    memset(g_blocks, 0, sizeof g_blocks);
    w.k = (Knobs){.mission = 1, .command = 1, .inputValid = 1, .missionType = 1, .generation = 1, .triggerCount = 2,
        .held = 0.5f, .full = 1.2f, .charge = 0.5f};
    BuildPlayer();
    BuildTables();
    w.record = w.identity = MakeRecord();
    uint8_t* game = (uint8_t*)fake_game();
    memcpy(game + RVA_SETTER, kSetter, sizeof kSetter);
    PutPointer(game + RVA_PM, w.pm);
    PutPointer(game + RVA_OWNER, w.owner);
    PutPointer(game + RVA_AM, w.am);
    PutPointer(game + RVA_HOLDERS, w.holders);
    PutPointer(game + RVA_TRIGGER, w.trigger);
    PutPointer(game + RVA_CHARGE, w.charge);
    PutPointer(game + RVA_MODE, w.mode);
}

/* ---- the engine, each frame -------------------------------------------------------------------------------------- */

static void PutWeapon(uint8_t* at)
{
    if (w.k.arc) Put64(at, ARC);
    else memcpy(at, "ordinary", 8);
    Put32(at + 8, WEAPON_ID);
    Put32(at + 16, w.k.generation);
    at[20] = 1;
}

static void SyncTrigger(void)
{
    Put32(w.trigger + 24, w.k.triggerCount);
    PutPointer(w.trigger + 24 + 40, w.entities);
    PutPointer(w.trigger + 24 + 64, w.flags);
    for (uint32_t i = 0; i < 4096; i++) PutPointer(w.entities + i * 8, w.k.dense ? w.ordinary : NULL);
    memset(w.flags, w.k.dense ? 1 : 0, 4096);
    if (!w.k.dense) PutPointer(w.entities + 8, w.second);
    PutPointer(w.entities + w.k.triggerSlot * 8, w.weapon);
    if (!w.k.dense) w.flags[w.k.second ? 1 : w.k.triggerSlot] = (uint8_t)w.k.command;
}

/* The charge table, and the trigger handler's copy of the fire command into every entry's charging flag. */
static void SyncCharge(void)
{
    Put32(w.charge + 16, 512);
    PutPointer(w.charge + 16 + 40, w.charged);
    PutPointer(w.charge + 16 + 48, w.entries[w.k.relocated]);
    memset(w.charged, 0, 512 * 8);
    PutPointer(w.charged + 510 * 8, w.second);
    PutPointer(w.charged + (w.k.relocated ? 3 : 511) * 8, w.weapon);
    for (int a = 0; a < 2; a++)
        for (int i = 0; i < 3; i++)
        {
            uint8_t* entry = Entry(a, kEntryIndexes[i]);
            PutF(entry + 4, w.k.charge);
            PutF(entry + 8, w.k.full);
            entry[12] = w.k.engineFlag;
        }
}

static void Sync(void)
{
    Put32(w.mode + 8, (uint32_t)w.k.mission);
    Put32(w.mode + 0x40, w.k.missionType);
    PutF(Slot(w.avatarIndex) + 8, w.k.down ? w.k.held : 0.0f);
    PutF(Slot(w.avatarIndex) - 32 + 8, w.k.aim ? w.k.held : 0.0f); /* Aim, just before Fire: never read */
    PutWeapon(w.weapon);
    PutWeapon(w.second);
    SyncTrigger();
    SyncCharge();
    Blocking(BLOCK_INPUT, Slot(w.avatarIndex), 32, !w.k.inputValid);
}

/* HellForge's set_live writes the record the identity names. */
static void Mirror(void)
{
    HfValue value;
    if (w.identity != NULL && fake_live_now(ARC, COMPONENT, AUTO_FIRE, &value)) w.identity[AUTO_FIRE] = (uint8_t)value.number;
}

static void Protect(DWORD protection)
{
    DWORD old;
    VirtualProtect(w.entries[0], ENTRIES_SIZE, protection, &old); /* lint-ok: C1,C3 the test changes the fake entries' protection */
}

/* The flags the tick set (the engine had cleared them): on the expected entry, or elsewhere. */
static void CountWrites(void)
{
    uint32_t expected = w.k.second ? 510 : (w.k.relocated ? 3 : 511);
    if (w.k.engineFlag == 1) return;
    for (int a = 0; a < 2; a++)
        for (int i = 0; i < 3; i++)
            if (Entry(a, kEntryIndexes[i])[12] == 1)
            {
                if (a == w.k.relocated && kEntryIndexes[i] == expected) w.writes++;
                else w.wrong++;
            }
}

/* One update: the engine's handler, then the tick. */
static void Frame(void)
{
    Sync();
    uint32_t setLive = fake_counts().set_live;
    if (w.protect) Protect(w.protect);
    fake_frames(1, DT);
    if (w.protect) Protect(PAGE_READWRITE);
    if (fake_counts().set_live != setLive) Mirror();
    CountWrites();
}

static void Ticks(int n)
{
    for (int i = 0; i < n; i++) Frame();
}

/* Frames until one checked the charge record (a poll frame). */
static void Settle(void)
{
    int checks = w.recordChecks, n = 0;
    while (w.recordChecks == checks && n++ < 200) Frame();
    CHECK(n <= 200);
}

/* The calls of the next frame. */
static FakeCounts Pin(void)
{
    fake_counts_reset();
    Frame();
    return fake_counts();
}

/* The calls of the first of the next 100 frames that checks the charge record. */
static FakeCounts PollFrame(void)
{
    for (int i = 0; i < 100; i++)
    {
        int checks = w.recordChecks;
        FakeCounts frame = Pin();
        if (w.recordChecks > checks) return frame;
    }
    CHECK(0);
    return fake_counts();
}

static void Started(void)
{
    g_api = *fake_api();
    g_api.read = TestRead;
    g_api.component_record = TestComponentRecord;
    if (!w.refuseLive) fake_live_put(ARC, COMPONENT, AUTO_FIRE, (HfValue)HF_U8(0));
    CHECK_EQ(vpm_core_init(&g_api, fake_mod(), kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    uint32_t setLive = fake_counts().set_live;
    fake_fire(HF_EVENT_ENTITIES_READY);
    if (fake_counts().set_live != setLive) Mirror();
}

/* Started, and the Lua test's first 20 updates (the first a poll frame). */
static void Running(void)
{
    Build();
    Started();
    Ticks(20);
}

static void MoveAvatar(uint32_t index)
{
    PutPointer(w.am + 0x110, index == 0 ? w.avatar : NULL);
    PutPointer(w.am + 0x118, index == 1 ? w.avatar : NULL);
    SetRow(w.amRows, AVATAR_ID, index);
    PutF(Slot(w.avatarIndex) + 8, 0.0f); /* the former slot stays readable and reads zero */
    w.avatarIndex = index;
}

/* ---- load ---------------------------------------------------------------------------------------------------------- */

/* The record by identity, checked, flagged through HellForge: 1 read, set_live and get_live (the Lua's scan: 23 reads,
 * 3 VirtualQueryEx, 2 VirtualProtectEx, 1 WriteProcessMemory). */
static void PatchesTheRecordAtLoad(void)
{
    Build();
    Started();
    FakeCounts load = fake_counts();
    CHECK_EQ(load.read, 1);
    CHECK_EQ(load.set_live, 1);
    CHECK_EQ(load.get_live, 1);
    CHECK_EQ(load.code_matches, 1);
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    CHECK_LOG("[Arc Thrower Revamped] Charge record ready.");
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_EQ(Pin().read, 15); /* the first tick is a poll frame in a mission: mission, record, the full Fire check */
}

static void AlreadySetWritesNothing(void)
{
    Build();
    w.record[AUTO_FIRE] = 1;
    Started();
    CHECK_EQ(fake_counts().set_live, 0);
    CHECK_LOG("Charge record ready.");
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(fake_counts().set_live, 0); /* not this session's change: nothing to put back */
    CHECK_EQ(w.record[AUTO_FIRE], 1);
}

/* Another setter reads as code not decoded yet: the core waits for it, then stops the component, nothing changed. */
static void RefusesAnotherBuild(void)
{
    Build();
    ((uint8_t*)fake_game())[RVA_SETTER + 14] = 0x28;
    Started();
    CHECK(vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    fake_frames(60, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: the fire-mode setter changed (game.dll 0x755F90)");
    CHECK_EQ(fake_counts().set_live + fake_counts().read, 0);
    CHECK_EQ(w.record[AUTO_FIRE], 0);
}

/* Not the reviewed record (another fingerprint, or another charge time): never written; looked up again every 5 s. */
static void RefusesAnUnreviewedRecord(void)
{
    Build();
    PutF(w.record + 24, 1.5f);
    Started();
    CHECK_LOG("Charge record not ready yet: charge record not found (the Arc Thrower's charge record is not the reviewed one)");
    CHECK(strstr(vpm_status(fake_component(0)), "waiting: charge record not found") != NULL);
    Ticks(1000);
    CHECK_EQ(fake_counts().set_live, 0);
    CHECK_EQ(w.record[AUTO_FIRE], 0);
}

/* No record yet: retried every 5 s on poll frames; patched once the identity answers. */
static void WaitsForTheRecord(void)
{
    Build();
    w.identity = NULL;
    w.k.mission = 0;
    Started();
    CHECK_LOG("Charge record not ready yet: charge record not found");
    CHECK(strcmp(vpm_status(fake_component(0)), "waiting: charge record not found") == 0);
    fake_counts_reset();
    Ticks(60);
    CHECK_EQ(fake_counts().read, 1); /* on the ship: one poll frame (the mission record; the retry waits 5 s) */
    w.identity = w.record;
    Ticks(600);
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    CHECK_LOG("Charge record ready.");
    CHECK(strcmp(vpm_status(fake_component(0)), "running") == 0);
}

/* HellForge refuses the live edit: logged once, retried every 5 s; the charging flag is still kept while Fire is held. */
static void RecordWriteRefused(void)
{
    Build();
    w.refuseLive = 1;
    Started();
    CHECK_LOG("Charge record not ready yet: charge record write failed: HellForge refused the edit (fake: no such field)");
    Ticks(20);
    w.k.arc = w.k.down = 1;
    uint32_t attempts = fake_counts().set_live, logs = fake_counts().log;
    Ticks(600);
    CHECK(fake_counts().set_live > attempts);
    CHECK_EQ(fake_counts().log, logs);
    CHECK(w.writes >= 590);
    CHECK_EQ(w.record[AUTO_FIRE], 0);
}

/* The game reloads its entity data: the record is looked up again and flagged (HellForge renews its edit too). */
static void FollowsReloadedEntityData(void)
{
    Running();
    w.record2 = MakeRecord();
    w.identity = w.record2;
    uint32_t before = fake_counts().set_live;
    fake_fire(HF_EVENT_ENTITIES_READY);
    Mirror();
    CHECK_EQ(fake_counts().set_live, before + 1);
    CHECK_EQ(w.record2[AUTO_FIRE], 1);
}

static void StopPutsTheRecordBack(void)
{
    Running();
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    vpm_core_stop(fake_component(0), "test");
    Mirror();
    CHECK_EQ(w.record[AUTO_FIRE], 0);
    w.k.arc = w.k.down = 1;
    Ticks(20);
    CHECK_EQ(w.writes, 0);
}

/* ---- game.dll's code decoded in parts after HF_EVENT_GAME_LOADED (vpm_when_code_ready) ------------------------- */

static void Encode(void) { memset((uint8_t*)fake_game() + RVA_SETTER, 0xCC, sizeof kSetter); }
static void Decode(void) { memcpy((uint8_t*)fake_game() + RVA_SETTER, kSetter, sizeof kSetter); }

/* Decoded at load: the one code check at HF_EVENT_GAME_LOADED and nothing else there; HF_EVENT_ENTITIES_READY's work as
 * before. */
static void TheSetterIsCheckedAtLoad(void)
{
    Build();
    g_api = *fake_api();
    g_api.read = TestRead;
    g_api.component_record = TestComponentRecord;
    fake_live_put(ARC, COMPONENT, AUTO_FIRE, (HfValue)HF_U8(0));
    CHECK_EQ(vpm_core_init(&g_api, fake_mod(), kDefs, 1), 0);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    FakeCounts loaded = fake_counts();
    CHECK_EQ(loaded.code_matches, 1);
    CHECK_EQ(loaded.read + loaded.set_live + loaded.get_live + loaded.log, 0);
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    Mirror();
    FakeCounts ready = fake_counts();
    CHECK_EQ(ready.code_matches, 0);
    CHECK_EQ(ready.read, 1);
    CHECK_EQ(ready.set_live, 1);
    CHECK_EQ(ready.get_live, 1);
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    CHECK(vpm_ticking(fake_component(0)));
}

/* Still encoded at both events, decoded two seconds later: nothing looked up, written or ticked before; the record and
 * the tick on the frame of the core's next look, as at load. */
static void TheSetterDecodedLaterStartsItThen(void)
{
    Build();
    Encode();
    Started();
    /* set_live stores at once, as HellForge's does (Mirror runs only after a whole frame, and the record's set-up now
     * comes inside one, before the first tick's poll reads the record) */
    fake_live_bind(ARC, COMPONENT, AUTO_FIRE, (uintptr_t)(w.record + AUTO_FIRE));
    CHECK_EQ(fake_counts().read + fake_counts().set_live, 0);
    CHECK(vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    fake_counts_reset();
    w.k.arc = w.k.down = 1;
    Ticks(120);
    CHECK_EQ(fake_counts().code_matches, 4); /* one look every 30 frames */
    CHECK_EQ(fake_counts().read + fake_counts().set_live + fake_counts().log, 0);
    CHECK_EQ(w.writes, 0);
    CHECK_EQ(w.record[AUTO_FIRE], 0);
    Decode();
    fake_counts_reset();
    Ticks(30);
    Mirror();
    CHECK_EQ(fake_counts().code_matches, 1);
    CHECK_EQ(fake_counts().set_live, 1);
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    CHECK_LOG("[Arc Thrower Revamped] Charge record ready.");
    CHECK(vpm_ticking(fake_component(0)));
    Ticks(60);
    CHECK(w.writes > 0); /* Fire held with the Arc Thrower: the hold is followed now */
}

/* Never decoded: stopped after 60 s naming the setter; no record looked up, nothing written. */
static void TheSetterNeverDecodedStopsItAfterAMinute(void)
{
    Build();
    Encode();
    Started();
    fake_frames(59, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(1, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Arc Thrower Revamped] disabled: the fire-mode setter changed (game.dll 0x755F90)");
    CHECK_EQ(fake_counts().read + fake_counts().set_live + fake_counts().get_live, 0);
    CHECK_EQ(w.record[AUTO_FIRE], 0);
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY); /* a reload after the stop: nothing */
    fake_frames(60, 1.0f);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches + fake_counts().set_live, 0);
}

/* ---- the pinned calls per frame (the Lua's budget mode, its labels) ---------------------------------------------- */

static void BudgetIdle(void)
{
    Settle();
    CHECK_EQ(Pin().read, 1);  /* in a mission, fire up [1] */
    Ticks(13);
    CHECK_EQ(Pin().read, 13); /* fire up, check frame [16] */
    CHECK_EQ(PollFrame().read, 15); /* fire up, poll frame [19] */
    w.k.aim = 1;
    Settle();
    CHECK_EQ(Pin().read, 1);  /* aiming, fire up [1] */
    w.k.aim = 0;
    PutPointer((uint8_t*)fake_game() + RVA_PM, NULL);
    Settle();
    CHECK_EQ(Pin().read, 0);  /* no local avatar [0] */
    CHECK_EQ(PollFrame().read, 2); /* no local avatar, poll frame [6] */
    PutPointer((uint8_t*)fake_game() + RVA_PM, w.pm);
    Settle();
}

static void BudgetShip(void)
{
    w.k.mission = 0;
    Settle();
    CHECK_EQ(Pin().read, 0);  /* on the ship [0] */
    w.k.down = 1;
    CHECK_EQ(Pin().read, 0);  /* on the ship, fire held [0] */
    CHECK_EQ(PollFrame().read, 2); /* on the ship, poll frame [3] */
    w.k.down = 0;
    w.k.missionType = 0;
    w.k.mission = 1;
    CHECK_EQ(PollFrame().read, 2); /* mission flag without a mission type, poll frame [3] */
    CHECK_EQ(Pin().read, 0);
    w.k.missionType = 1;
    CHECK_EQ(PollFrame().read, 15); /* mission entered: poll frame [19] */
    CHECK_EQ(Pin().read, 1);  /* mission entered, fire up [1] */
}

static void BudgetOrdinary(void)
{
    w.k.down = 1;
    CHECK_EQ(Pin().read, 8);  /* first frame of a press, ordinary weapon [10] */
    CHECK_EQ(Pin().read, 3);  /* fire held, ordinary weapon [4] */
    int retry = 0;
    for (int i = 0; i < 100 && retry == 0; i++)
    {
        uint32_t reads = Pin().read;
        if (reads > 3) retry = (int)reads;
    }
    CHECK_EQ(retry, 7);       /* discovery retry [9] */
    w.k.down = 0;
    CHECK_EQ(Pin().read, 3);  /* release, ordinary weapon [4] */
    CHECK_EQ(w.writes + w.wrong + w.headerReads, 0);
}

static void BudgetArc(void)
{
    Settle();
    w.k.arc = w.k.engineFlag = w.k.down = 1;
    CHECK_EQ(Pin().read, 15); /* first frame of an Arc Thrower press [19] */
    CHECK_EQ(Pin().read, 9);  /* held, charging flag set by the engine [12] */
    CHECK_EQ(w.writes, 0);
    w.k.engineFlag = 0;
    CHECK_EQ(Pin().read, 9);  /* first write of a binding: page check [12 + VirtualQueryEx] */
    CHECK_EQ(w.writes, 1);
    CHECK_EQ(Pin().read, 9);  /* held after the shot [12] */
    CHECK_EQ(w.writes, 2);
    CHECK_EQ(PollFrame().read, 23); /* held, poll frame [29] */
    Ticks(14);
    CHECK_EQ(Pin().read, 21); /* held, check frame [26] */
    w.k.relocated = 1;
    int before = w.writes;
    CHECK_EQ(Pin().read, 10); /* entry moved to another page [13 + VirtualQueryEx] */
    CHECK_EQ(w.writes, before + 1);
    w.k.relocated = 0;
    Frame();
    w.k.down = 0;
    CHECK_EQ(Pin().read, 3);  /* release, Arc Thrower [4] */
    Settle();
    w.k.down = 1;
    before = w.writes;
    CHECK_EQ(Pin().read, 15); /* first frame of the next press, flag clear [19 + VirtualQueryEx] */
    CHECK_EQ(w.writes, before + 1);
    w.k.down = 0;
    Frame();
    CHECK_EQ(w.wrong, 0);
}

static void BudgetRepairs(void)
{
    w.record[AUTO_FIRE] = 0;
    FakeCounts repair = PollFrame();
    CHECK_EQ(repair.read, 15); /* record repair [20 + VirtualQueryEx + 2 VirtualProtectEx + WriteProcessMemory] */
    CHECK_EQ(repair.set_live, 1);
    CHECK_EQ(repair.get_live, 1);
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    w.k.arc = 0;
    Settle();
    Settle();
    w.k.inputValid = 0;
    CHECK_EQ(Pin().read, 4);   /* kept Fire slot unreadable [5] */
    CHECK_EQ(Pin().read, 0);   /* no Fire slot known [0] */
    w.k.inputValid = 1;
    Settle();
    CHECK_EQ(Pin().read, 1);   /* Fire slot found again on the check frame [1] */
}

/* A respawn moves the local avatar to another index; a press right after it arms by the next check frame. */
static void BudgetRespawn(void)
{
    w.k.arc = w.k.command = 1;
    MoveAvatar(0);
    Settle();
    MoveAvatar(1);
    int before = w.writes, armedAfter = 0;
    w.k.down = 1;
    for (int frame = 1; frame <= 15 && armedAfter == 0; frame++)
    {
        Frame();
        if (w.writes > before) armedAfter = frame;
    }
    CHECK(armedAfter > 0);
    w.k.down = 0;
    Settle();
    FakeCounts frame = fake_counts();
    CHECK_EQ(frame.log, 0); /* no log line on any of these frames */
}

static void PinnedCallsPerFrame(void)
{
    Running();
    BudgetIdle();
    BudgetShip();
    BudgetOrdinary();
    BudgetArc();
    BudgetRepairs();
    BudgetRespawn();
}

/* ---- firing (the Lua test's normal mode) --------------------------------------------------------------------------- */

static int Gained(void (*change)(void))
{
    int before = w.writes;
    change();
    Frame();
    return w.writes - before;
}

static void Nothing(void) {}
static void Relocate(void) { w.k.charge = 0.5f; w.k.command = 1; w.k.relocated = 1; }
static void InputGone(void) { w.k.inputValid = 0; }
static void InputBack(void) { w.k.inputValid = 1; }
static void NewGeneration(void) { w.k.generation = 2; }
static void OtherHolder(void) { Put32(w.rows + 48 + 4, 999); }
static void OtherAvatar(void) { Put32(w.avatar + 16, 5); }

static void OrdinaryWeaponsNeverWrite(void)
{
    w.k.down = 1;
    fake_counts_reset();
    Ticks(100);
    CHECK_EQ(w.writes + w.headerReads, 0);
    CHECK(fake_counts().read <= 2500);
    CHECK_EQ(fake_counts().log, 0);
    w.k.down = 0;
    Frame();
}

static void FiresWhileHeld(void)
{
    Running();
    OrdinaryWeaponsNeverWrite();
    w.k.arc = w.k.down = 1;
    CHECK_EQ(Gained(Nothing), 1); /* the first Arc press assists at once */
    CHECK_EQ(w.headerReads, 1);
    int before = w.writes;
    Ticks(50);
    CHECK_EQ(w.writes, before + 50); /* one write per update while held */
    w.k.charge = 0.8f;
    Frame();
    w.k.charge = 0;
    w.k.command = 0;
    Frame();
    before = w.writes;
    Ticks(150);
    CHECK_EQ(w.writes - before, 150); /* the hold outlives the one-shot command */
    CHECK_LOG("stalled (peak 0.000) - checking the current binding (#1); logged once per session");
    CHECK_EQ(Gained(Relocate), 1);  /* follows the charge array's move */
    CHECK_EQ(Gained(InputGone), 0); /* unavailable input stops the writes */
    CHECK_EQ(Gained(InputBack), 1); /* and valid input brings them back */
    CHECK_EQ(Gained(NewGeneration), 0); /* a reused entity address cannot keep the binding */
    w.k.down = 0;
    Frame();
    w.k.down = 1;
    CHECK_EQ(Gained(Nothing), 1);   /* the new identity arms through the current fire command */
    CHECK_EQ(Gained(OtherHolder), 0); /* another player's holder is not assisted */
    Put32(w.rows + 48 + 4, AVATAR_ID);
    w.k.down = 0;
    before = w.writes;
    Ticks(50);
    CHECK_EQ(w.writes, before);     /* release stops the writes */
}

static void FollowsTheNextWeapon(void)
{
    w.k.second = w.k.down = 1;
    CHECK_EQ(Gained(Nothing), 1);   /* the next press follows a second Arc Thrower */
    w.k.arc = 0;
    int before = w.writes;
    Ticks(20);
    CHECK_EQ(w.writes, before);     /* another weapon identity ends it */
    w.k.arc = w.k.command = 1;
    w.k.second = w.k.down = 0;
    Frame();
    w.k.down = 1;
    CHECK_EQ(Gained(Nothing), 1);
    CHECK_EQ(Gained(OtherAvatar), 0); /* a changed local avatar ends the hold at once */
    Put32(w.avatar + 16, 0);
    w.k.down = 0;
    Frame();
    w.k.down = 1;
    Frame();
    CHECK_EQ(Gained(Nothing), 1);
    SetRow(w.holderRows, WEAPON_ID, 2); /* the weapon moves to another (another player's) holder row */
    Put32(w.rows + 96 + 4, 999);
    Settle();
    CHECK_EQ(Gained(Nothing), 0);   /* the check frame looked the holder up afresh */
    CHECK_EQ(w.wrong, 0);
}

static void FiresAndFollows(void)
{
    FiresWhileHeld();
    FollowsTheNextWeapon();
}

/* ---- recovery (the Lua test's scenarios) ------------------------------------------------------------------------- */

/* An Arc Thrower held, one shot fired, the engine's command cleared. */
static int AfterTheFirstShot(void)
{
    Running();
    w.k.arc = w.k.down = 1;
    Frame();
    CHECK_EQ(w.writes, 1);
    w.k.charge = 0.8f;
    Frame();
    w.k.charge = 0;
    w.k.command = 0;
    Frame();
    return w.writes;
}

static void InputGap(void)
{
    int before = AfterTheFirstShot();
    CHECK_EQ(Gained(InputGone), 0);
    CHECK_EQ(Gained(InputBack), 1); /* the same weapon recovers with its command cleared */
    w.k.down = 0;
    before = w.writes;
    Ticks(5);
    w.k.down = 1;
    Ticks(20);
    CHECK_EQ(w.writes, before);     /* a new hold needs a new fire command */
}

static void InputExpired(void)
{
    int before = AfterTheFirstShot();
    w.k.inputValid = 0;
    Ticks(41);
    w.k.inputValid = 1;
    Ticks(21);
    CHECK_EQ(w.writes, before);
}

static void ReleaseDuringGap(void)
{
    int before = AfterTheFirstShot();
    w.k.inputValid = 0;
    Frame();
    w.k.inputValid = 1;
    w.k.held = 0.01f; /* held less than before: released and pressed again */
    Ticks(21);
    CHECK_EQ(w.writes, before);
}

/* One unreadable binding read pauses the writes; the next frame resumes without a new command. */
static void BindingGaps(void)
{
    static const int kWhich[3] = {BLOCK_IDENTITY, BLOCK_HOLDER, BLOCK_BINDING};
    for (int c = 0; c < 3; c++)
    {
        fake_setup();
        int before = AfterTheFirstShot();
        const void* at[3] = {w.weapon, w.rows + 48 + 4, w.charge + 16};
        static const size_t kSize[3] = {24, 4, 56};
        Blocking(kWhich[c], at[c], kSize[c], 1);
        Frame();
        CHECK_EQ(w.writes, before);
        Blocking(kWhich[c], at[c], kSize[c], 0);
        Frame();
        CHECK_EQ(w.writes, before + 1);
    }
}

static void ChangesDuringGap(void)
{
    for (int c = 0; c < 2; c++)
    {
        fake_setup();
        int before = AfterTheFirstShot();
        w.k.inputValid = 0;
        Frame();
        w.k.inputValid = 1;
        if (c == 0) w.k.generation = 2;
        else Put32(w.rows + 48 + 4, 999);
        Ticks(20);
        CHECK_EQ(w.writes, before);
    }
}

/* A cleared record flag is repaired on a poll frame. */
static void PatchReset(void)
{
    AfterTheFirstShot();
    w.record[AUTO_FIRE] = 0;
    Ticks(60);
    CHECK_EQ(w.record[AUTO_FIRE], 1);
    CHECK_EQ(fake_counts().set_live, 2);
}

/* The record is replaced: the old one (no longer the Arc's) is never written, the new one is found by identity. */
static void PatchReplaced(void)
{
    AfterTheFirstShot();
    w.record2 = MakeRecord();
    w.identity = w.record2;
    w.record[168] = 0;
    w.record[AUTO_FIRE] = 0;
    Ticks(100);
    CHECK_EQ(w.record2[AUTO_FIRE], 1);
    CHECK_EQ(w.record[AUTO_FIRE], 0);
}

/* A charge stuck at full beside a healthy kept record: the record is looked up again and the new one flagged. */
static void PatchShadowCopy(void)
{
    AfterTheFirstShot();
    w.record2 = MakeRecord();
    w.identity = w.record2;
    w.k.charge = w.k.full;
    Ticks(400);
    CHECK_EQ(w.record2[AUTO_FIRE], 1);
}

static void LargeTriggerTables(void)
{
    static const uint32_t kCounts[2] = {65, 4096};
    for (int c = 0; c < 2; c++)
    {
        fake_setup();
        Running();
        w.k.triggerCount = kCounts[c];
        w.k.triggerSlot = kCounts[c] - 1;
        w.k.down = w.k.arc = 1;
        Frame();
        CHECK_EQ(w.writes, 1); /* an Arc at the end of a sparse table arms on the first discovery */
        w.k.down = 0;
        Frame();
        w.k.triggerCount = 0xFFFFFFFFu;
        w.k.down = 1;
        Ticks(30);
        CHECK_EQ(w.writes, 1); /* a corrupt table size writes nothing */
    }
}

static void DenseTriggerTable(void)
{
    Running();
    w.k.triggerCount = 4096;
    w.k.triggerSlot = 64;
    w.k.dense = w.k.down = w.k.arc = 1;
    fake_counts_reset();
    Frame();
    CHECK_EQ(w.writes + w.headerReads, 0); /* the first batch stops before candidate 65 */
    CHECK(fake_counts().read < 200);
    Ticks(12);
    CHECK(w.writes > 0); /* the next batch reaches it */
}

/* The charging flag's page is executable, not private read-write data: never written; the component stops and puts the
 * record back. */
static void EntryRefused(void)
{
    Running();
    w.protect = PAGE_EXECUTE_READ;
    w.k.arc = w.k.down = 1;
    Ticks(30);
    w.protect = 0;
    CHECK_EQ(w.writes + w.wrong, 0);
    CHECK_LOG("disabled: charge entry 0x");
    CHECK_LOG("is not private read-write memory (state 0x1000, protection 0x20, type 0x20000)");
    CHECK(!vpm_running(fake_component(0)));
    CHECK_EQ(w.record[AUTO_FIRE], 0);
    w.k.down = 0;
    Ticks(5);
    w.k.down = 1;
    Ticks(30);
    CHECK_EQ(w.writes, 0);
}

/* The page is checked before a binding's first write, not on every write: a page that changes later is seen by the next
 * binding. */
static void PageCheckedPerBinding(void)
{
    Running();
    w.k.arc = w.k.down = 1;
    Frame();
    CHECK_EQ(w.writes, 1);
    w.protect = PAGE_EXECUTE_READWRITE;
    Ticks(10);
    CHECK_EQ(w.writes, 11);
    w.k.down = 0;
    Frame();
    w.k.down = 1;
    Ticks(5);
    w.protect = 0;
    CHECK_EQ(w.writes, 11);
    CHECK_LOG("is not private read-write memory (state 0x1000, protection 0x40, type 0x20000)");
}

/* ---- the detailed lines (the pack's Diagnostics option) and the mark's describe line ------------------------- */

static VpmOption* PackOption(const char* id)
{
    for (int i = 0; i < vpm_option_count(); i++)
        if (vpm_option_owner(vpm_option_at(i)) == vpm_pack() && strcmp(vpm_option_def(vpm_option_at(i))->id, id) == 0)
            return vpm_option_at(i);
    return NULL;
}

static void Diagnostics(int detailed) { CHECK(vpm_option_apply(PackOption("diagnostics"), detailed ? 2 : 1)); }

/* Fire held with another weapon, then an Arc Thrower press: two shots, two stalls, an input gap, a moved entry, the
 * release; a mission's end and start; a cleared record flag; the game's entity data reloaded. */
static void DetailScenario(void)
{
    w.k.down = 1;
    Ticks(5);
    w.k.down = 0;
    Frame();
    w.k.arc = w.k.down = 1;
    Frame();
    for (int shot = 0; shot < 2; shot++)
    {
        w.k.charge = 0.8f;
        Frame();
        w.k.charge = 0;
        Frame();
    }
    w.k.command = 0;
    Ticks(280);
    InputGone();
    Frame();
    InputBack();
    Frame();
    Relocate();
    Frame();
    w.k.relocated = 0;
    w.k.down = 0;
    Frame();
    w.k.mission = 0;
    Settle();
    w.k.mission = 1;
    Settle();
    w.record[AUTO_FIRE] = 0;
    Settle();
    w.record2 = MakeRecord();
    w.identity = w.record2;
    fake_fire(HF_EVENT_ENTITIES_READY);
    Mirror();
}

static const char* const kDetailLines[] = {
    "[Arc Thrower Revamped] idle: waiting for the engine fire command\n",
    "[Arc Thrower Revamped] assist armed: entity 0x",
    "[Arc Thrower Revamped] charge entry 0x",
    "[Arc Thrower Revamped] shot 1 (charge 0.800 -> 0.000, interval n/a)\n",
    "[Arc Thrower Revamped] shot 2 (charge 0.800 -> 0.000, interval 0.020)\n",
    ") - checking the current binding (#2)\n",
    "[Arc Thrower Revamped] no charge progress for ",
    "[Arc Thrower Revamped] charge record lookup 2: the record found is the one already patched",
    "[Arc Thrower Revamped] idle: native Fire input unavailable\n",
    "[Arc Thrower Revamped] charge entry moved: 0x",
    "[Arc Thrower Revamped] released after 2 shot(s); interval min 0.020 mean 0.020 max 0.020 (1)\n",
    "[Arc Thrower Revamped] mission ended: holds=1 stalls=2 record lookups=2 record repairs=0 (this session)\n",
    "[Arc Thrower Revamped] mission started\n",
    "[Arc Thrower Revamped] the charge record's auto-fire flag was clear: set again (repair 1)\n",
    "[Arc Thrower Revamped] the game reloaded its entity data: the charge record is looked up again\n",
    "[Arc Thrower Revamped] charge record at 0x",
};

static void DetailedLines(void)
{
    for (int detailed = 0; detailed < 2; detailed++)
    {
        fake_setup();
        Running();
        Diagnostics(detailed);
        fake_log_clear();
        DetailScenario();
        CHECK_LOG("stalled (peak 0.000) - checking the current binding (#1); logged once per session");
        for (int i = 0; i < (int)(sizeof kDetailLines / sizeof kDetailLines[0]); i++)
        {
            if (detailed) CHECK_LOG(kDetailLines[i]);
            else CHECK_NO_LOG(kDetailLines[i]);
        }
        CHECK_EQ(w.wrong, 0);
        CHECK(vpm_running(fake_component(0)));
    }
}

/* Idle ticks (Fire up in a mission, its check and poll frames; the ship) keep their reads and log nothing in either
 * mode; so do the ticks of a hold that changes nothing. */
static void DetailedIdleFrames(void)
{
    uint32_t reads[2] = {0, 0};
    for (int detailed = 0; detailed < 2; detailed++)
    {
        fake_setup();
        Running();
        Diagnostics(detailed);
        Settle();
        for (int i = 0; i < 300; i++)
        {
            FakeCounts c = Pin();
            CHECK_EQ(c.log + c.write + c.other, 0);
            reads[detailed] += c.read;
        }
        w.k.arc = w.k.engineFlag = w.k.down = 1;
        Frame();
        for (int i = 0; i < 30; i++) CHECK_EQ(Pin().log, 0); /* held, the engine's flag set: nothing changes */
        w.k.down = w.k.engineFlag = 0;
        Frame();
        w.k.mission = 0;
        Settle();
        for (int i = 0; i < 300; i++)
        {
            FakeCounts c = Pin();
            CHECK_EQ(c.log + c.write + c.other, 0);
            reads[detailed] += c.read;
        }
    }
    CHECK_EQ(reads[0], reads[1]);
}

/* Many presses in a short time: the limiter's 20 lines per 600 ticks, then its count of the lines left out. */
static void DetailedLinesThroughTheLimiter(void)
{
    Running();
    Diagnostics(1);
    w.k.arc = 1;
    for (int i = 0; i < 10; i++)
    {
        w.k.down = 1;
        Frame();
        w.k.down = 0;
        Frame();
    }
    CHECK_NO_LOG("detailed lines suppressed");
    Ticks(600);
    w.k.down = 1;
    Frame();
    CHECK_LOG(" detailed lines suppressed (at most 20 per 600 frames)\n[Arc Thrower Revamped] assist armed: entity 0x");
}

/* The mark's line: the status, then the describe text. */
static void MarkDescribes(void)
{
    Running();
    w.k.arc = w.k.down = 1;
    Frame();
    fake_log_clear();
    CHECK(vpm_option_apply(PackOption("note_problem"), 1));
    CHECK_LOG("[core] MARK 1: Arc Thrower Revamped: running | in a mission; charge record 0x");
    CHECK_LOG(" patched; hold armed (entity 0x");
    CHECK_LOG("); Fire slot 0x");
    CHECK_LOG("; holds=1 stalls=0 lookups=1 repairs=0\n");
}

int main(void)
{
    RUN(PatchesTheRecordAtLoad);
    RUN(AlreadySetWritesNothing);
    RUN(RefusesAnotherBuild);
    RUN(RefusesAnUnreviewedRecord);
    RUN(WaitsForTheRecord);
    RUN(RecordWriteRefused);
    RUN(FollowsReloadedEntityData);
    RUN(StopPutsTheRecordBack);
    RUN(TheSetterIsCheckedAtLoad);
    RUN(TheSetterDecodedLaterStartsItThen);
    RUN(TheSetterNeverDecodedStopsItAfterAMinute);
    RUN(PinnedCallsPerFrame);
    RUN(FiresAndFollows);
    RUN(InputGap);
    RUN(InputExpired);
    RUN(ReleaseDuringGap);
    RUN(BindingGaps);
    RUN(ChangesDuringGap);
    RUN(PatchReset);
    RUN(PatchReplaced);
    RUN(PatchShadowCopy);
    RUN(LargeTriggerTables);
    RUN(DenseTriggerTable);
    RUN(EntryRefused);
    RUN(PageCheckedPerBinding);
    RUN(DetailedLines);
    RUN(DetailedIdleFrames);
    RUN(DetailedLinesThroughTheLimiter);
    RUN(MarkDescribes);
    TEST_END();
}
