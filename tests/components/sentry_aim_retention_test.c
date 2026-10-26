/* Sentry Aim Retention: the Lua tests' scenarios (components/SentryAimRetention/tests: test_snapshot.lua, test_aim.lua,
 * test_firing.lua, test_windows_api.lua, test_loader.lua, and the two recorded replays) on the fake game.
 *
 * Not ported: test_current_game.lua (its capture holds the real session's addresses, which the fake cannot map),
 * test_idle_gate.lua's side-by-side run against v1.1.0's Lua, its allocation and JIT trace checks, test_module.lua and
 * the hostile-FFI parts of test_windows_api.lua (LuaJIT specifics), and the cases that make a Lua setter or write raise
 * part way (a plain store cannot be cut short and a game function cannot raise into the component). */
#include <math.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/sentry_aim_retention/sentry_aim.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_sentry_aim_retention};

#define SENTRY 9u
#define UNIT 1u
#define TARGET 77u
#define TARGET_UNIT 222u
#define NOW 1000000ull
#define DEADLINE 1700000ull
#define DT (1.0f / 60)
#define RAD 0.017453292519943295 /* math.rad */

static void Put32(void* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(void* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutF(void* at, float v) { memcpy(at, &v, 4); }
static void Ptr(void* at, const void* p) { Put64(at, (uint64_t)(uintptr_t)p); }
static uint32_t Get32(const void* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t Get64(const void* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static float GetF(const void* at) { float v; memcpy(&v, at, 4); return v; }
static uint8_t* Block(size_t size) { return fake_heap(size); }
static uint8_t* Game(uint32_t rva) { return (uint8_t*)fake_game() + rva; }
static uint8_t* Exe(uint32_t rva) { return (uint8_t*)fake_exe() + rva; }
/* A page of its own (inside an 8 KB block), so a test can change its protection alone. */
static uint8_t* Page(void) { uint8_t* b = Block(8192); return (uint8_t*)(((uintptr_t)b + 4095) & ~(uintptr_t)4095); }
static void Vec(uint8_t* at, float x, float y, float z) { PutF(at, x); PutF(at + 4, y); PutF(at + 8, z); }

static void PutCode(uint8_t* at, const char* pattern)
{
    for (const char* p = pattern; *p;)
    {
        if (*p == ' ') { p++; continue; }
        char hex[3] = {p[0], p[1], 0};
        *at++ = (uint8_t)strtol(hex, NULL, 16);
        p += 2;
    }
}

static void Protect(void* at, size_t size, DWORD protection)
{
    DWORD old;
    if (!VirtualProtect(at, size, protection, &old)) printf("  VirtualProtect failed\n"); /* lint-ok: C3 the test changes the fake memory's protection */
}

/* ---- fake game functions ---------------------------------------------------------------------------------------- */

/* Sentries the fake setters know: by id (the retention flag, the fire mode) and by entity (the turn speeds). */
typedef struct Fake { uint32_t id; uintptr_t entity; uint8_t* flags; uint8_t* control; uint8_t* mode; } Fake;
static Fake g_fakes[8];
static int g_fake_count;
static struct { int retention, horizontal, vertical, fire_mode, raycast; } g_calls;
static int g_refuse_vertical;
static uint32_t g_modes[64];
static int g_mode_writes;

static Fake* FakeById(uint32_t id)
{
    for (int k = 0; k < g_fake_count; k++)
        if (g_fakes[k].id == id) return &g_fakes[k];
    return NULL;
}

static Fake* FakeByEntity(uintptr_t entity)
{
    for (int k = 0; k < g_fake_count; k++)
        if (g_fakes[k].entity == entity) return &g_fakes[k];
    return NULL;
}

static void AddFake(uint32_t id, uintptr_t entity, uint8_t* flags, uint8_t* control, uint8_t* mode)
{
    Fake* f = FakeById(id);
    if (f == NULL) f = &g_fakes[g_fake_count++];
    *f = (Fake){id, entity, flags, control, mode};
}

static void FakeRetention(void* manager, uint32_t id, uint32_t bit, uint8_t enabled)
{
    Fake* f = FakeById(id);
    g_calls.retention++;
    if (f == NULL || manager != NULL || bit != 2) return;
    Put32(f->flags, enabled ? Get32(f->flags) | bit : Get32(f->flags) & ~bit);
}

static int g_fault_horizontal;   /* the next horizontal speed call faults (once) */
static int* volatile g_nowhere;  /* NULL: a store through it faults */

static void FakeHorizontal(void* entity, float speed)
{
    Fake* f = FakeByEntity((uintptr_t)entity);
    g_calls.horizontal++;
    if (g_fault_horizontal)
    {
        g_fault_horizontal = 0;
        *g_nowhere = 1;
    }
    if (f != NULL) PutF(f->control + 8, speed);
}

static void FakeVertical(void* entity, float speed)
{
    Fake* f = FakeByEntity((uintptr_t)entity);
    g_calls.vertical++;
    if (g_refuse_vertical) { g_refuse_vertical = 0; return; }
    if (f != NULL) PutF(f->control + 12, speed);
}

static void FakeFireMode(void* manager, uint32_t id, uint32_t mode)
{
    Fake* f = FakeById(id);
    g_calls.fire_mode++;
    if (g_mode_writes < 64) g_modes[g_mode_writes] = mode;
    g_mode_writes++;
    if (f != NULL) Put32(f->mode, mode);
}

static uint32_t FakeWorldId(const void* world) { return 2; }

/* A scene of hits: each record is {distance, unit, actor} at uint32 6, 7, 8 of 11. */
typedef struct SceneHit { float distance; uint32_t unit, actor, flags; } SceneHit;
static struct
{
    int count;
    SceneHit hit[40];
    uint32_t world, collection, actors, filter, flags, ignore, capacity;
    float length, from[3], direction[3];
} g_scene;

static void Record(uint32_t* out, uint32_t i, const SceneHit* h)
{
    PutF(out + 11 * i + 6, h->distance);
    out[11 * i + 7] = h->unit;
    out[11 * i + 8] = h->actor;
}

static void Remember(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, uint32_t capacity)
{
    g_calls.raycast++;
    g_scene.world = world;
    g_scene.collection = collection;
    g_scene.actors = actors;
    g_scene.filter = filter;
    g_scene.flags = flags;
    g_scene.ignore = ignore;
    g_scene.capacity = capacity;
    g_scene.length = length;
    memcpy(g_scene.from, from, 12);
    memcpy(g_scene.direction, direction, 12);
}

/* The hits within the ray, nearest first; collection 1 answers the closest only. */
static uint32_t SceneRaycast(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, void* out, uint32_t capacity)
{
    SceneHit included[40];
    uint32_t n = 0;
    Remember(world, from, direction, length, collection, actors, filter, flags, ignore, capacity);
    for (int k = 0; k < g_scene.count; k++)
        if (g_scene.hit[k].distance <= length) included[n++] = g_scene.hit[k];
    for (uint32_t a = 0; a < n; a++)
        for (uint32_t b = a + 1; b < n; b++)
            if (included[b].distance < included[a].distance) { SceneHit t = included[a]; included[a] = included[b]; included[b] = t; }
    uint32_t count = collection == 1 ? (n < 1 ? n : 1) : n;
    for (uint32_t i = 0; i < count && i < capacity; i++) Record(out, i, &included[i]);
    return count;
}

static const SarNatives kFakes = {FakeRetention, FakeHorizontal, FakeVertical, FakeFireMode, FakeWorldId, SceneRaycast};

static void ResetFakes(void)
{
    memset(g_fakes, 0, sizeof g_fakes);
    g_fake_count = 0;
    memset(&g_calls, 0, sizeof g_calls);
    memset(&g_scene, 0, sizeof g_scene);
    g_refuse_vertical = 0;
    g_fault_horizontal = 0;
    g_mode_writes = 0;
}

static int NativeCalls(void) { return g_calls.retention + g_calls.horizontal + g_calls.vertical + g_calls.fire_mode + g_calls.raycast; }

/* ---- the fake game (test_snapshot.lua's fixture) ----------------------------------------------------------------- */

typedef struct World
{
    uint8_t *tm, *bm, *rm, *wm, *cm, *maps[5];
    uint8_t *entity, *rt, *nt, *behavior, *control;
    uint8_t *clock, *fm, *fmap, *fslots, *target, *weapon, *modes, *triggers, *mission;
    uint8_t *units, *generations, *slots, *object, *vtable, *code, *matrices, *scheduler, *world;
} World;
static World w;

static const char* const kGameCode[][2] = {
    {"6BF390", "40 57 41 57 48 83 EC 28 3B 15 82 48 DC 02 45 0F B6 F9 4C 8B 15 87 79 C6"},
    {"11CB930", "48 83 EC 28 8B 41 08 3B 05 E3 82 2B 02 0F 84 D0 00 00 00 4C 8B 15 26 B4"},
    {"11CBA20", "48 83 EC 28 8B 41 08 3B 05 F3 81 2B 02 0F 84 D0 00 00 00 4C 8B 15 36 B3"},
    {"755F90", "48 89 4C 24 08 53 55 56 57 41 57 48 83 EC 20"},
};
static const char* const kExeCode[][2] = {
    {"1FD220", "40 53 48 83 EC 20 48 63 DA E8 92 06 EA FF 48 8B C8 4C 8B 00 41 FF 90 E8"},
    {"79F860", "33 C0 4C 8D 05 C7 B2 01 02 0F 1F 80 00 00 00 00 49 39 0C C0 74 0C FF C0 83 F8 04 75 F3"},
    {"7F4590", "48 8B C4 F3 0F 11 58 20 89 48 08 55 53 56 57 41 54 41 55 41 56 41 57 48"},
};

static void PutCodes(void)
{
    for (int k = 0; k < 4; k++) PutCode(Game((uint32_t)strtoul(kGameCode[k][0], NULL, 16)), kGameCode[k][1]);
    for (int k = 0; k < 3; k++) PutCode(Exe((uint32_t)strtoul(kExeCode[k][0], NULL, 16)), kExeCode[k][1]);
}

/* A manager's hash map at manager + header (rows at map: id -> index 0 at slot (id * 2) & 7), and its entity array
 * (manager + array -> map + 128, whose first pointer is the entity). */
static void Map(uint8_t* manager, uint32_t header, uint32_t array, uint8_t* map, uint32_t id)
{
    Ptr(manager + header, map);
    Put32(manager + header + 8, 8);
    Put32(manager + header + 12, 0);
    Put32(manager + header + 16, 2);
    Put32(map + 8 * ((id * 2) & 7), id);
    Put32(map + 8 * ((id * 2) & 7) + 4, 0);
    Ptr(manager + array, map + 128);
    Ptr(map + 128, w.entity);
}

static void PutMatrix(uint8_t* at, const float m[16]) { memcpy(at, m, 64); }

/* The unit table path the pose reader follows: unit 1 (index 1, generation 0), 16 nodes, fire node 15's matrix. */
static void MakePose(void)
{
    static const float pose[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -20, 0, 1};
    static const uint8_t code[5] = {0x48, 0x8D, 0x41, 0x60, 0xC3};
    w.units = Block(0xA8);
    Ptr(Exe(0x1A100F0), w.units);
    Put32(w.units + 0x98, 2);
    w.generations = Block(8);
    Ptr(w.units + 0xA0, w.generations);
    w.slots = Block(16);
    Ptr(w.units + 0x88, w.slots);
    w.object = Block(0x90);
    Ptr(w.slots + 8, w.object);
    Put32(w.object + 8, UNIT);
    Put32(w.object + 0x70, 16);
    w.vtable = Block(0xF0);
    Ptr(w.object, w.vtable);
    w.code = Block(8);
    Ptr(w.vtable + 0xE8, w.code);
    memcpy(w.code, code, 5);
    w.matrices = Block(64 * 16);
    Ptr(w.object + 0x88, w.matrices);
    PutMatrix(w.matrices + 64 * 15, pose);
}

/* The ray scheduler idle (nothing pending, all 24 workers done) and a physics world. */
static void MakeTerrain(void)
{
    w.scheduler = Block(0x40008 + 288);
    Ptr(Game(0x347D7E0), w.scheduler);
    for (int i = 0; i < 24; i++) Put32(w.scheduler + 0x40008 + 12 * i + 8, 1);
    w.world = Block(16);
    Ptr(Game(0x346BFA0), w.world);
}

static void Mission(int on)
{
    if (w.mission == NULL) { w.mission = Block(0x44); Ptr(Game(0x33266A0), w.mission); }
    Put32(w.mission + 8, (uint32_t)on);
    Put32(w.mission + 0x40, (uint32_t)on);
}

static void MakeRegistries(void)
{
    w.tm = Block(392);
    w.bm = Block(112);
    w.rm = Block(96);
    w.wm = Block(104);
    w.cm = Block(96);
    for (int k = 0; k < 5; k++) w.maps[k] = Block(128 + 8 * 512);
    w.entity = Block(24);
    w.rt = Block(208);
    w.nt = Block(24);
    w.behavior = Block(504);
    w.control = Block(16);
    Ptr(Game(0x3326D30), w.tm);
    Ptr(Game(0x3326740), w.bm);
    Ptr(Game(0x3326D70), w.rm);
    Ptr(Game(0x3326CE0), w.wm);
    Ptr(Game(0x3326660), w.cm);
    Put32(w.tm + 308, 384);
    Put32(w.tm + 320, 1);
    Put32(w.tm + 324, 1);
    Put32(w.bm + 32, 1024);
    Put32(w.rm + 8, 64);
    Put32(w.rm + 20, 1);
    Put32(w.rm + 24, 1);
    Map(w.tm, 336, 360, w.maps[0], SENTRY);
    Map(w.bm, 64, 88, w.maps[1], SENTRY);
    Map(w.rm, 40, 64, w.maps[2], SENTRY);
    Map(w.wm, 48, 72, w.maps[3], SENTRY);
    Map(w.cm, 40, 64, w.maps[4], SENTRY);
    Ptr(w.tm + 376, w.rt);
    Ptr(w.tm + 384, w.nt);
    Ptr(w.bm + 96, w.behavior);
    Ptr(w.rm + 88, w.control);
}

/* The weapon, its fire mode and trigger, the clock and the target's faction map (target 77, unit 222). */
static void MakeWeapon(void)
{
    w.clock = Block(32);
    Ptr(Game(0x3326348), w.clock);
    Put64(w.clock + 24, NOW);
    w.weapon = Block(1008);
    Ptr(w.wm + 88, w.weapon);
    Put32(w.weapon + 216, 1);
    Put32(w.weapon + 120, 15);
    w.modes = Block(12);
    Ptr(w.wm + 96, w.modes);
    Put32(w.modes, 1);
    w.triggers = Block(8);
    Ptr(w.cm + 88, w.triggers);
    w.triggers[0] = 1;
    w.fm = Block(73840);
    w.fmap = Block(64);
    w.fslots = Block(8);
    w.target = Block(20);
    Ptr(Game(0x3326CB8), w.fm);
    Ptr(w.fm + 73808, w.fmap);
    Put32(w.fm + 73816, 8);
    Put32(w.fm + 73824, 2);
    Put32(w.fmap + 16, TARGET);
    Ptr(w.fm + 73832, w.fslots);
    Ptr(w.fslots, w.target);
    Put32(w.target + 8, TARGET);
    Put32(w.target + 12, TARGET_UNIT);
}

/* Gatling sentry 9 (unit 1) this machine controls, tracking target 77 on its firing node. */
static void MakeSentry(void)
{
    Put64(w.entity, HF_ENTITY_GATLING_SENTRY);
    Put32(w.entity + 8, SENTRY);
    Put32(w.entity + 12, UNIT);
    Put32(w.entity + 16, 12);
    w.entity[20] = 1;
    Put32(w.behavior, 213);
    Put32(w.behavior + 8, 12);
    Put32(w.behavior + 24, TARGET);
    Put32(w.behavior + 96, 3);
    w.behavior[120] = 1;
    Put64(w.behavior + 152, DEADLINE);
    Put32(w.rt, TARGET);
    w.control[0] = 1;
    PutF(w.control + 8, 80);
    PutF(w.control + 12, 50);
}

static void MakeWorld(void)
{
    memset(&w, 0, sizeof w);
    ResetFakes();
    MakeRegistries();
    MakeWeapon();
    MakeSentry();
    MakePose();
    MakeTerrain();
    Mission(1);
    PutCodes();
    AddFake(SENTRY, (uintptr_t)w.entity, w.nt + 16, w.control, w.modes);
}

static void Started(void)
{
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    sar_natives_override(&kFakes);
}

static VpmComponent* Self(void) { return fake_component(0); }
static int StatusIs(const char* text) { return strcmp(vpm_status(Self()), text) == 0; }
static void Target(uint32_t id, uint32_t flags) { Put32(w.behavior + 24, id); Put32(w.behavior + 96, flags); }

/* One snapshot on a fresh cache (M.snapshot without a cache): 1 with the rows, or 0 with *why. */
static int Snapshot(SarRow** rows, int* count, const char** why)
{
    sar_cache_reset();
    return sar_snapshot(rows, count, why);
}

/* ---- per-frame counts -------------------------------------------------------------------------------------------- */

typedef struct Counts { uint32_t read, write, log, queries, natives, polls; } Counts;

static Counts Frames(int n)
{
    uint32_t queries = sar_writable_queries(), polls = sar_state.polls;
    int natives = NativeCalls();
    fake_counts_reset();
    fake_frames(n, DT);
    FakeCounts f = fake_counts();
    return (Counts){f.read, f.write, f.log, sar_writable_queries() - queries, (uint32_t)(NativeCalls() - natives),
        sar_state.polls - polls};
}

static VpmOption* PackOption(const char* id)
{
    for (int i = 0; i < vpm_option_count(); i++)
        if (vpm_option_owner(vpm_option_at(i)) == vpm_pack() && strcmp(vpm_option_def(vpm_option_at(i))->id, id) == 0)
            return vpm_option_at(i);
    return NULL;
}

/* The pack's Diagnostics option: Normal (0) or Detailed (1). */
static void Diagnostics(int detailed)
{
    CHECK(vpm_option_apply(PackOption("diagnostics"), detailed ? 2 : 1));
    CHECK_EQ(vpm_detailed(), detailed);
}

/* Idle-gated frames up to the next full check: each makes no call at all and leaves the status as it was. */
static int IdleUntilCheck(void)
{
    int n = 0;
    char status[192];
    snprintf(status, sizeof status, "%s", vpm_status(Self()));
    while (sar_cache.exists && sar_cache.idle && (sar_cache.checks + 1) % SAR_RESCAN != 0)
    {
        Counts c = Frames(1);
        n++;
        CHECK_EQ(c.read + c.write + c.log + c.queries + c.natives + c.polls, 0);
        CHECK(StatusIs(status));
    }
    return n;
}

/* A 30th frame outside a mission: only the mission check (reads exactly), no full check. */
static void MissionCheck(uint32_t reads)
{
    Counts c = Frames(1);
    CHECK_EQ(c.read, reads);
    CHECK_EQ(c.polls, 0);
    CHECK_EQ(c.write + c.log + c.queries + c.natives, 0);
    CHECK(sar_cache.outside == 1);
}

/* A frame with these checks (two while a sentry is engaged: here, without the frame hook, the second right after the
 * first) whose reads (and queries) equal these exactly. */
static Counts Exact(uint32_t checks, uint32_t reads, uint32_t queries, const char* status)
{
    Counts c = Frames(1);
    CHECK_EQ(c.polls, checks);
    CHECK_EQ(c.read, reads);
    CHECK_EQ(c.queries, queries);
    CHECK_EQ(c.write, 0);
    CHECK(StatusIs(status));
    if (!StatusIs(status)) printf("    status: %s (expected %s)\n", vpm_status(Self()), status);
    return c;
}

/* ---- test_snapshot.lua ------------------------------------------------------------------------------------------- */

/* The native-layout fixture decodes at its offsets: identity, components, fire nodes, target unit and clock. */
static void DecodesTheFixture(void)
{
    MakeWorld();
    Started();
    SarRow* rows[SAR_MAX_SENTRIES];
    int count = 0;
    const char* why = "";
    CHECK(Snapshot(rows, &count, &why));
    CHECK_EQ(count, 1);
    if (count != 1) return;
    SarRow* s = rows[0];
    CHECK(s->id == SENTRY && strcmp(s->profile->name, "Gatling") == 0 && s->node == 12 && s->target == TARGET);
    CHECK(s->runtime_target == TARGET && s->flags == 0 && s->enabled && s->has);
    CHECK(s->raw_address == (uintptr_t)w.rt + 8 && s->flags_address == (uintptr_t)w.nt + 16 && s->control_address == (uintptr_t)w.control);
    CHECK(s->has_fire && s->fire.mode == 1 && s->fire.node == 15 && s->fire.trigger && s->fire.pause == 16 && s->fire.resume == 4);
    CHECK(s->fire.has_target_unit && s->fire.target_unit == TARGET_UNIT);
    CHECK(s->selection.address == (uintptr_t)w.behavior + 152 && s->selection.now == (double)NOW);
    CHECK_EQ(Get64(s->selection.deadline), DEADLINE);
    CHECK_EQ(s->guard_count, 18);
    CHECK_EQ(s->transition_count, 4);
    CHECK_EQ(s->fire.guard_count, 10);
    CHECK_EQ(sar_profile_count, 7);
}

/* One frame through the component: the muzzle pose read along the unit path, and the terrain query from the muzzle to
 * the target's raw point, the sentry's unit ignored, with the static-obstacle preset; once per check, and the tracking
 * sentry is engaged, so the frame makes two. */
static void QueriesTheTerrainFromTheMuzzle(void)
{
    MakeWorld();
    Vec(w.rt + 8, 0, 5, 1);
    Started();
    Frames(1);
    CHECK(StatusIs("observing"));
    CHECK_EQ(sar_state.polls, 2);
    CHECK_EQ(g_calls.raycast, 2);
    CHECK(g_scene.world == 2 && g_scene.collection == 1 && g_scene.actors == 3 && g_scene.filter == 0x393D9518u);
    CHECK(g_scene.flags == 0x80000009u && g_scene.ignore == UNIT && g_scene.capacity == 1);
    CHECK(g_scene.from[0] == 0 && g_scene.from[1] == -20 && g_scene.from[2] == 0);
    CHECK(fabs(g_scene.length - sqrt(25.0 * 25.0 + 1.0)) < 1e-4);
    CHECK(fabs(g_scene.direction[1] - 25 / sqrt(626.0)) < 1e-6);
    CHECK_LOG("[Sentry Aim Retention] waiting_for_sentries");
}

/* Target removal cannot invalidate restoration of the sentry's fire mode: its identity guards stay apart. */
static void TargetRemovalKeepsTheFireRestore(void)
{
    MakeWorld();
    Started();
    SarRow* rows[SAR_MAX_SENTRIES];
    int count = 0;
    const char* why = "";
    CHECK(Snapshot(rows, &count, &why) && count == 1);
    if (count != 1) return;
    SarFireRecord r;
    memset(&r, 0, sizeof r);
    r.snapshot = *rows[0];
    r.paused = 1;
    r.mode = 1;
    Put32(w.target + 8, 78);
    Put32(w.modes, 0);
    CHECK(sar_release_fire(&r));
    CHECK_EQ(Get32(w.modes), 1);
    CHECK_EQ(g_calls.fire_mode, 1);
}

/* Authority and resource gates, malformed maps, identities and vectors. */
static void RefusesWhatIsNotAsReviewed(void)
{
    static const char* const texts[] = {"Unsupported sentry behavior", "Unsupported entity map", "Component identity mismatch",
        "Invalid aim vector"};
    SarRow* rows[SAR_MAX_SENTRIES];
    int count = 0;
    const char* why = "";
    MakeWorld();
    Started();
    w.entity[20] = 0;
    CHECK(Snapshot(rows, &count, &why) && count == 0);
    w.entity[20] = 3;
    CHECK(Snapshot(rows, &count, &why) && count == 0);
    w.entity[20] = 1;
    for (int c = 0; c < 4; c++)
    {
        if (c == 0) Put32(w.behavior, 999);
        if (c == 1) Put32(w.bm + 72, 7);
        if (c == 2) Ptr(w.maps[1] + 128, w.entity + 24);
        if (c == 3) Put32(w.rt + 8, 0x7FC00000u);
        why = "";
        CHECK(!Snapshot(rows, &count, &why));
        CHECK(strcmp(why, texts[c]) == 0);
        if (c == 0) Put32(w.behavior, 213);
        if (c == 1) Put32(w.bm + 72, 8);
        if (c == 2) Ptr(w.maps[1] + 128, w.entity);
        if (c == 3) PutF(w.rt + 8, 0);
    }
    CHECK(Snapshot(rows, &count, &why) && count == 1);
}

/* Without the reviewed code there is no binding and no change; an empty root waits. */
static void BindsOnlyTheReviewedCode(void)
{
    MakeWorld();
    Game(0x6BF390)[0] = 0xCC;
    Started();
    Frames(1);
    CHECK(!sar_natives_bound());
    CHECK_LOG("error: Unsupported native sentry setter");
    CHECK(StatusIs("Unsupported native sentry setter"));
    CHECK_EQ(NativeCalls(), 0);
    CHECK_EQ(Get32(w.modes), 1);
    Ptr(Game(0x3326D30), NULL);
    Frames(1);
    CHECK(StatusIs("waiting_for_sentries"));
}

/* Bound at the first sentry, once per session, to the game's own functions (none is called here: no target). */
static void BindsTheGamesFunctionsOnce(void)
{
    MakeWorld();
    Target(0, 32);
    Put32(w.rt, 0);
    w.triggers[0] = 0;
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(fake_counts().code_matches, 7);
    CHECK(sar_natives_bound());
    const SarNatives* n = sar_natives();
    CHECK((uintptr_t)(void*)n->retention == fake_game() + 0x6BF390 && (uintptr_t)(void*)n->horizontal == fake_game() + 0x11CBA20);
    CHECK((uintptr_t)(void*)n->vertical == fake_game() + 0x11CB930 && (uintptr_t)(void*)n->fire_mode == fake_game() + 0x755F90);
    CHECK((uintptr_t)(void*)n->world_id == fake_exe() + 0x79F860 && (uintptr_t)(void*)n->raycast == fake_exe() + 0x7F4590);
    fake_counts_reset();
    fake_frames(5, DT);
    CHECK_EQ(fake_counts().code_matches, 0);
    CHECK(StatusIs("observing"));
}

/* 512 non-sentries: two bounded chunk reads per check; only changed pointers are read again, every entry on every 30th
 * check. The Lua: 516, 4, 5 and 516 calls (its root read is a plain load here). */
static void ClassifiesOncePerPointer(void)
{
    SarRow* rows[SAR_MAX_SENTRIES];
    int count = 0;
    const char* why = "";
    MakeWorld();
    Put32(w.tm + 308, 512);
    Put32(w.tm + 320, 512);
    Put32(w.tm + 324, 512);
    uint8_t* others = Block(512 * 32 + 32);
    for (int i = 0; i < 512; i++) Ptr(w.maps[0] + 128 + 8 * i, others + 32 * i);
    Started();
    sar_cache_reset();
    fake_counts_reset();
    CHECK(sar_snapshot(rows, &count, &why) && count == 0);
    CHECK_EQ(fake_counts().read, 515);
    fake_counts_reset();
    CHECK(sar_snapshot(rows, &count, &why) && count == 0);
    CHECK_EQ(fake_counts().read, 3);
    Ptr(w.maps[0] + 128 + 8 * 7, others + 32 * 512);
    fake_counts_reset();
    CHECK(sar_snapshot(rows, &count, &why));
    CHECK_EQ(fake_counts().read, 4);
    while (sar_cache.checks < 29) CHECK(sar_snapshot(rows, &count, &why));
    fake_counts_reset();
    CHECK(sar_snapshot(rows, &count, &why));
    CHECK(sar_cache.checks == 30);
    CHECK_EQ(fake_counts().read, 515);
    fake_hole((uintptr_t)(w.maps[0] + 128), 8);
    CHECK(!Snapshot(rows, &count, &why));
    CHECK(strcmp(why, "Runtime read unavailable") == 0);
}

/* The per-frame budget through the component, as the Lua pinned it (test_snapshot.lua): waiting frames make no call;
 * on the ship a mission check every 60th frame, in a mission a rescan every 30th; a kept sentry layout; protection
 * queried once per range. */
static void WaitsOnTheShipAndInAMissionIn(int detailed)
{
    MakeWorld();
    Ptr(Game(0x3326D30), NULL);
    Ptr(Game(0x3326740), NULL);
    Ptr(Game(0x3326D70), NULL);
    Mission(0);
    Started();
    Diagnostics(detailed);
    /* On the ship (no mission, no targeting registry): the first check reads nothing (its root is a plain load). */
    Exact(1, 0, 0, "waiting_for_sentries");
    CHECK_EQ(IdleUntilCheck(), 28);
    CHECK(sar_state.polls == 1 && sar_state.updates == 29);
    MissionCheck(1); /* frame 30: the mode record (its pointer is a plain load); the Lua: 2 reads and a pointer decode */
    CHECK_EQ(IdleUntilCheck(), 29);
    MissionCheck(1); /* frame 60 */
    /* A populated registry on the ship is not rescanned. */
    Ptr(Game(0x3326D30), w.tm);
    Ptr(Game(0x3326740), w.bm);
    Ptr(Game(0x3326D70), w.rm);
    Put64(w.entity, 0);
    CHECK_EQ(IdleUntilCheck(), 29);
    MissionCheck(0); /* frame 90: no rescan, no mission check */
    CHECK_EQ(IdleUntilCheck(), 29);
    MissionCheck(1); /* frame 120 */
    CHECK(sar_state.polls == 1 && sar_state.updates == 120);
    /* A mission starts: seen at the next 60th frame, which runs the full check (record, header, chunk, entity). */
    Mission(1);
    CHECK_EQ(IdleUntilCheck(), 29);
    MissionCheck(0); /* frame 150 */
    CHECK_EQ(IdleUntilCheck(), 29);
    Exact(1, 4, 0, "waiting_for_sentries"); /* frame 180; the Lua: 6 reads, 3 pointer decodes */
    CHECK_EQ(IdleUntilCheck(), 29);
    Exact(1, 3, 0, "waiting_for_sentries"); /* frame 210: the rescan; the Lua: 4 */
    CHECK_EQ(IdleUntilCheck(), 29);
    Exact(1, 4, 0, "waiting_for_sentries"); /* frame 240: the rescan and the mission check; the Lua: 6 */
    CHECK(sar_state.polls == 4 && sar_state.updates == 240);
}

static void WaitsOnTheShipAndInAMission(void) { WaitsOnTheShipAndInAMissionIn(0); }
static void WaitsOnTheShipAndInAMissionDetailed(void) { WaitsOnTheShipAndInAMissionIn(1); }

/* A sentry located, tracking, losing and reacquiring its target, removed while held, then placed again. Per frame, as the
 * Lua's frame_budget pinned it (its read and read_into together): two checks while a sentry is engaged, here without
 * the frame hook, so the second runs right after the first. */
static void HoldsAndPausesOnceATargetIsLostIn(int detailed)
{
    MakeWorld();
    Started();
    Diagnostics(detailed);
    Frames(1); /* located; the functions bound */
    CHECK(StatusIs("observing"));
    /* Tracking, per check: the kept layout 20, the pose 6, the target guard twice, the scheduler 2, the transition 1. The
     * Lua: 58 over its two checks, not counting its pose and terrain reads. */
    Counts c = Exact(2, 62, 0, "observing");
    CHECK_EQ(c.natives, 2); /* the ray query, per check */
    /* The target is lost: fire pauses (its identity read again), the search request (1 query), the hold (3) and the fire
     * mode's (1): each range's first query; then the held check (27). The Lua: 156 and 5 queries over two checks. */
    Target(0, 32);
    c = Exact(2, 137, 5, "firing_paused");
    CHECK_EQ(c.natives, 4); /* fire mode, retention, both speeds */
    CHECK(sar_state.holds == 1 && sar_state.holding == 1 && sar_state.fire_pauses == 1 && sar_state.reselections == 1);
    CHECK_EQ(Get32(w.modes), 0);
    CHECK_EQ(Get32(w.nt + 16), 2);
    CHECK(GetF(w.control + 8) == 0 && GetF(w.control + 12) == 0);
    CHECK_EQ(Get64(w.behavior + 152), NOW);
    Exact(2, 54, 0, "firing_paused"); /* holding: the pending request is followed (1 read per check); the Lua: 54 */
    /* A new target before the native handler used the request: fire resumes, the request is restored and the hold ends.
     * Every range was verified at the loss: no query (the Lua: 5). That check saw the retention bit still set, so the
     * next one records the aim: it runs at once (the Lua's second check did, before the game's update), and the
     * post-update one follows: 106 + 31 + 31 (the Lua: 152 over two checks). */
    Target(TARGET, 3);
    c = Exact(3, 168, 0, "observing");
    CHECK(sar_state.releases == 1 && sar_state.fire_resumes == 1 && sar_state.holding == 0 && sar_state.fire_paused == 0);
    CHECK(Get32(w.modes) == 1 && Get32(w.nt + 16) == 0 && GetF(w.control + 8) == 80 && GetF(w.control + 12) == 50);
    CHECK_EQ(Get64(w.behavior + 152), DEADLINE);
    CHECK(sar_aim_record(SENTRY) != NULL && sar_aim_record(SENTRY)->has_raw);
    Exact(2, 62, 0, "observing");
    Target(0, 32);
    Exact(2, 137, 0, "firing_paused");
    CHECK(sar_state.holds == 2 && sar_state.reselections == 2);
    CHECK_EQ(Get64(w.behavior + 152), NOW + 100000); /* at least 100 ms after the last request */
    /* The sentry vanishes while held: the three releases in one check, which leaves nothing engaged (no second). The
     * registry emptied, so its ranges are queried again (5, as the Lua; its 96 reads in one check too). */
    Put32(w.tm + 324, 0);
    Exact(1, 76, 5, "waiting_for_sentries");
    CHECK(sar_aim_record(SENTRY) == NULL && sar_fire_record(SENTRY) == NULL);
    CHECK(Get32(w.modes) == 1 && Get32(w.nt + 16) == 0 && GetF(w.control + 8) == 80 && Get64(w.behavior + 152) == DEADLINE);
    /* Nothing held, paused or requested any more: the gate waits for the next 30th check. */
    CHECK(IdleUntilCheck() > 0);
    c = Frames(1);
    CHECK_EQ(c.polls, 1);
    CHECK_EQ(c.read, 2); /* the mission record (its first check since the sentry) and the header */
    CHECK(StatusIs("waiting_for_sentries"));
    /* A sentry with no target is not engaged: located at the next 30th check, then its kept layout (20) and pose (6). */
    Put32(w.tm + 324, 1);
    Target(0, 32);
    Put32(w.rt, 0);
    w.triggers[0] = 0;
    CHECK_EQ(IdleUntilCheck(), 29);
    uint32_t mission = (sar_cache.checks + 1) % SAR_MISSION_EVERY == 0 ? 1u : 0u; /* the gate's mission check */
    c = Frames(1);
    CHECK_EQ(c.read, mission + 48u);
    CHECK(StatusIs("observing") && !sar_cache.idle);
    Exact(1, 26, 0, "observing"); /* not engaged: one check (the Lua: 26) */
    CHECK(!vpm_post_ticking(Self()));
}

static void HoldsAndPausesOnceATargetIsLost(void) { HoldsAndPausesOnceATargetIsLostIn(0); }
static void HoldsAndPausesOnceATargetIsLostDetailed(void) { HoldsAndPausesOnceATargetIsLostIn(1); }

/* ---- diagnostics: the detailed lines (the Lua's diagnostics log), the summary, the mark ------------------------- */

static void MissionEnds(void)
{
    HfStateEvent end = {{sizeof end, HF_ON_MISSION_END}, HF_STATE_MISSION, HF_STATE_SHIP};
    fake_emit(&end.info);
}

/* Located, tracking, lost (hold, pause, search), reacquired, behind terrain and clear again, lost and removed, then a
 * failed check. */
static void Engagement(int detailed)
{
    MakeWorld();
    Started();
    Diagnostics(detailed);
    fake_log_clear();
    Frames(2);
    Target(0, 32);
    Frames(2);
    Target(TARGET, 3);
    Frames(2);
    g_scene.count = 1;
    g_scene.hit[0] = (SceneHit){1, 999, 4242, 0};
    Frames(2);
    g_scene.count = 0;
    Frames(2);
    Target(0, 32);
    Frames(1);
    Put32(w.tm + 324, 0);
    Frames(1);
    Put32(w.tm + 324, 1);
    Target(TARGET, 3);
    Frames(30);
    Put32(w.behavior, 999);
    Frames(1);
    Put32(w.behavior, 213);
    Frames(1);
    CHECK(sar_state.holds == 2 && sar_state.releases == 1 && sar_state.reselections == 2 && sar_state.fire_pauses >= 2);
}

static void DetailedModeSaysWhatTheSentriesDid(void)
{
    Engagement(1);
    CHECK_LOG("[Sentry Aim Retention] the game's 7 functions as reviewed: setters bound");
    CHECK_LOG("[Sentry Aim Retention] located Gatling sentry 9 (targeting entry 0): entity 0x");
    CHECK_LOG(", weapon manager 0x");
    CHECK_LOG("[Sentry Aim Retention] 1 sentries this machine controls (holding 0, fire paused 0, searches pending 0)\n");
    CHECK_LOG("[Sentry Aim Retention] Gatling sentry 9 lost its target on node 12: aim held at ");
    CHECK_LOG("[Sentry Aim Retention] Gatling sentry 9: fire paused");
    CHECK_LOG("(target lost; error ");
    CHECK_LOG("[Sentry Aim Retention] Gatling sentry 9 lost its target on the firing node: target search 0.700 s sooner\n");
    CHECK_LOG("[Sentry Aim Retention] Gatling sentry 9: hold released, it tracks a target again (restored)\n");
    CHECK_LOG("[Sentry Aim Retention] Gatling sentry 9: fire resumed");
    CHECK_LOG("[Sentry Aim Retention] sentry 9: search request released (it tracks a target)\n");
    CHECK_LOG("[Sentry Aim Retention] sentry 9: target 77 behind terrain (static obstruction: hit unit 000003E7 actor "
              "00001092 at 1.00 of 20.00 m, 0 hits)\n");
    CHECK_LOG("[Sentry Aim Retention] sentry 9: target 77 clear again (clear)\n");
    CHECK_LOG("[Sentry Aim Retention] sentry 9 is gone: its hold is released (restored)\n");
    CHECK_LOG("[Sentry Aim Retention] 0 sentries this machine controls");
    CHECK_LOG("[Sentry Aim Retention] check failed (0 before it in this burst; 8 stop it): Unsupported sentry behavior; "
              "everything restored, a fresh start\n");
}

static void NormalModeLogsNoneOfThem(void)
{
    Engagement(0);
    CHECK_NO_LOG("functions as reviewed");
    CHECK_NO_LOG("located");
    CHECK_NO_LOG("sentries this machine controls");
    CHECK_NO_LOG("lost its target");
    CHECK_NO_LOG("fire paused");
    CHECK_NO_LOG("released");
    CHECK_NO_LOG("terrain");
    CHECK_NO_LOG("check failed");
    CHECK_LOG("[Sentry Aim Retention] error: Unsupported sentry behavior\n"); /* the burst's own line, in both modes */
}

/* Many lines in a short time: the limiter counts them and says so at the mission's end. */
static void ManyLinesAreLimited(void)
{
    MakeWorld();
    Started();
    Diagnostics(1);
    Frames(2);
    fake_log_clear();
    for (int i = 0; i < 12; i++)
    {
        Target(0, 32);
        Frames(2);
        Target(TARGET, 3);
        Frames(2);
    }
    CHECK_EQ(fake_log_count("[Sentry Aim Retention]"), 17); /* the window's 20 less the first checks' three */
    MissionEnds();
    CHECK_LOG(" detailed lines suppressed (at most 20 per 600 frames)\n");
    CHECK_LOG("[core]   Sentry Aim Retention: checks ");
    CHECK_LOG(", holds 12, releases 12, late aim ");
}

/* "Note a problem now": the describe line and the counters in the mark. */
static void TheMarkCarriesItsState(void)
{
    MakeWorld();
    Started();
    Frames(2);
    Target(0, 32);
    Frames(1);
    fake_log_clear();
    CHECK(vpm_option_apply(PackOption("note_problem"), 1));
    CHECK_LOG("[core] MARK 1: Sentry Aim Retention: firing_paused | firing_paused; 1 sentries (1 located); holding 1, "
              "fire paused 1, searches pending 1; engaged 1; functions bound; mission not checked yet; errors in this burst 0 | "
              "checks ");
    CHECK_LOG(", holds 1, releases 0, late aim 0, fire pauses 1, resumes 0, searches shortened 1\n");
}

/* A hold that fails part way (the vertical setter refused) is undone in the same check: the search request, fire and
 * the hold's controls. The component starts afresh: the next frame pauses fire again for the lost target, without a
 * hold (no aim was tracked since). */
static void UndoesAFailedHold(void)
{
    MakeWorld();
    Started();
    Frames(2);
    Target(0, 32);
    g_refuse_vertical = 1;
    Counts c = Frames(1);
    CHECK_EQ(c.polls, 1);
    CHECK(StatusIs("hold_speed_failed"));
    CHECK_LOG("[Sentry Aim Retention] error: hold_speed_failed");
    CHECK(Get32(w.nt + 16) == 0 && GetF(w.control + 8) == 80 && GetF(w.control + 12) == 50);
    CHECK(Get32(w.modes) == 1 && Get64(w.behavior + 152) == DEADLINE);
    CHECK(sar_aim_record(SENTRY) == NULL && sar_fire_record(SENTRY) == NULL && vpm_running(Self()));
    c = Frames(1);
    CHECK(StatusIs("firing_paused") && sar_state.holding == 0 && sar_state.fire_paused == 1);
    CHECK_EQ(c.queries, 1); /* a fresh start forgets the verified ranges */
}

/* A kept layout follows moved memory: the turret control array moves while the sentry holds aim, the hold follows it,
 * and the speeds it saved go to the new address when the target returns; the old one is never written again. */
static void FollowsMovedArrays(void)
{
    MakeWorld();
    Started();
    Frames(1);
    Target(0, 32);
    Frames(1);
    CHECK(sar_state.holding == 1 && GetF(w.control + 8) == 0);
    uint8_t* control = Block(16);
    memcpy(control, w.control, 16);
    Ptr(w.rm + 88, control);
    memset(w.control, 0xFF, 16);
    AddFake(SENTRY, (uintptr_t)w.entity, w.nt + 16, control, w.modes);
    Frames(1);
    SarAimRecord* r = sar_aim_record(SENTRY);
    CHECK(sar_state.holding == 1 && r != NULL && r->lease.held.control_address == (uintptr_t)control);
    Target(TARGET, 3);
    Frames(1);
    CHECK(sar_state.holding == 0 && sar_state.releases == 1);
    CHECK(GetF(control + 8) == 80 && GetF(control + 12) == 50);
    for (int i = 0; i < 16; i++) CHECK(w.control[i] == 0xFF);
    uint8_t* behavior = Block(504);
    memcpy(behavior, w.behavior, 504);
    Ptr(w.bm + 96, behavior);
    memset(w.behavior, 0, 504);
    Frames(1);
    CHECK(sar_layouts[0].used && sar_layouts[0].row.behavior_address == (uintptr_t)behavior && sar_layouts[0].row.target == TARGET);
}

/* ---- the second check after game.dll's update (the core's frame hook) ---------------------------------------------- */

static void (*g_inUpdate)(void); /* what the game's update changes, on the next engine frame only */
static uint32_t g_holdingInUpdate, g_pausedInUpdate, g_pollsInUpdate;
static int g_recordInUpdate;     /* the sentry's aim was recorded when the game's update ran */

/* The game's own update (fake_after_tick's step, inside game.dll's frame update): it notes what the frame's checks
 * before it had done, then makes the change the test put up. */
static void GameUpdate(float dt)
{
    const SarAimRecord* r = sar_aim_record(SENTRY);
    g_pollsInUpdate = sar_state.polls;
    g_holdingInUpdate = sar_state.holding;
    g_pausedInUpdate = sar_state.fire_paused;
    g_recordInUpdate = r != NULL && r->has_raw;
    void (*change)(void) = g_inUpdate;
    g_inUpdate = NULL;
    if (change != NULL) change();
}

/* hooked: game.dll's frame update decoded, so the core's frame hook goes in at the load and the post-update tick runs
 * after the game's update; otherwise the fallback, with both ticks in HellForge's callback before it. */
static void StartedEngine(int hooked)
{
    MakeWorld();
    fake_frame_update(hooked);
    Started();
    CHECK_EQ(vpm_frame_hooked(), hooked ? 1 : 0);
    fake_after_tick(GameUpdate);
    g_inUpdate = NULL;
}

/* One engine frame whose game update makes this change, and its calls. */
static Counts EngineFrame(void (*change)(void))
{
    uint32_t queries = sar_writable_queries(), polls = sar_state.polls;
    int natives = NativeCalls();
    g_inUpdate = change;
    fake_counts_reset();
    fake_engine_frames(1, DT);
    FakeCounts f = fake_counts();
    return (Counts){f.read, f.write, f.log, sar_writable_queries() - queries, (uint32_t)(NativeCalls() - natives),
        sar_state.polls - polls};
}

static void LoseTarget(void) { Target(0, 32); }
/* The target is lost and the engine moves the raw aim at once (the snap back the hold prevents). */
static void LoseTargetAndSnap(void)
{
    Target(0, 32);
    Vec(w.rt + 8, 9, 9, 9);
}
static void LoseTargetAndFault(void)
{
    Target(0, 32);
    g_fault_horizontal = 1;
}

/* Everything the component changes is back as the game had it. */
static int Untouched(void)
{
    return Get32(w.modes) == 1 && Get32(w.nt + 16) == 0 && GetF(w.control + 8) == 80 && GetF(w.control + 12) == 50 &&
        Get64(w.behavior + 152) == DEADLINE;
}

/* The game's update loses the target. Hooked, the second check answers it after that update, in the same frame: the
 * hold, the fire pause and the search request; in the fallback the next frame's first check answers it. Either way
 * before the next update. */
static void TargetLostInsideTheUpdate(void)
{
    for (int hooked = 1; hooked >= 0; hooked--)
    {
        fake_setup();
        StartedEngine(hooked);
        EngineFrame(NULL); /* located; the functions bound */
        Counts c = EngineFrame(NULL);
        CHECK(c.polls == 2 && c.read == 62 && c.natives == 2 && c.queries == 0); /* tracking: as without the hook */
        CHECK(vpm_post_ticking(Self()));
        c = EngineFrame(LoseTarget);
        CHECK_EQ(c.polls, 2);
        CHECK_EQ(g_holdingInUpdate, 0);
        CHECK_EQ(sar_state.holding, (uint32_t)hooked);
        CHECK_EQ(sar_state.fire_paused, (uint32_t)hooked);
        CHECK_EQ(Get32(w.modes), hooked ? 0u : 1u);
        CHECK_EQ(Get32(w.nt + 16), hooked ? 2u : 0u);
        CHECK_EQ(Get64(w.behavior + 152), hooked ? NOW : DEADLINE);
        CHECK(StatusIs(hooked ? "firing_paused" : "observing"));
        /* Hooked: the tracking check (31), then the loss after the update (110, 5 queries, 4 setters). */
        if (hooked) CHECK(c.read == 141 && c.queries == 5 && c.natives == 1 + 4);
        c = EngineFrame(NULL);
        CHECK(g_holdingInUpdate == 1 && g_pausedInUpdate == 1); /* in place for the next update, either way */
        CHECK(sar_state.holding == 1 && sar_state.holds == 1 && StatusIs("firing_paused"));
        CHECK(c.polls == 2 && c.read == (hooked ? 54u : 27u + 110u));
        vpm_core_stop(Self(), "test");
        CHECK(Untouched());
    }
}

/* A target reacquired while held: that check releases the hold, and the next one records the new target's aim. It runs
 * at once, before the game's update, where the Lua's second check did; so a loss inside that very update is held by
 * the post-update check with the recorded aim, in the same frame. Without the check at once the aim would be recorded
 * only after the update, too late for that loss. */
static void ReacquiredThenLostInTheUpdate(void)
{
    StartedEngine(1);
    EngineFrame(NULL);
    EngineFrame(LoseTarget);
    CHECK_EQ(sar_state.holding, 1);
    Target(TARGET, 3);
    uint8_t aim[12];
    memcpy(aim, w.rt + 8, sizeof aim);
    Counts c = EngineFrame(LoseTargetAndSnap);
    CHECK_EQ(c.polls, 3);
    CHECK(g_recordInUpdate && g_holdingInUpdate == 0);
    CHECK(sar_state.releases == 1 && sar_state.holds == 2 && sar_state.holding == 1 && sar_state.late_aim == 1);
    CHECK(memcmp(w.rt + 8, aim, sizeof aim) == 0); /* the snap undone: the reacquired target's aim */
    CHECK(StatusIs("firing_paused"));
    /* A frame whose check releases nothing makes no check at once. */
    c = EngineFrame(NULL);
    CHECK_EQ(c.polls, 2);
    vpm_core_stop(Self(), "test");
    CHECK(Untouched());
}

/* Frames with no sentry engaged are what they were with the frame hook: no post-update tick, no call on waiting frames
 * but the mission checks, one check per frame for a sentry with no target. */
static void IdleFramesHaveNoPostCheck(void)
{
    StartedEngine(1);
    Ptr(Game(0x3326D30), NULL);
    Ptr(Game(0x3326740), NULL);
    Ptr(Game(0x3326D70), NULL);
    Mission(0);
    uint32_t calls = 0, polls = 0;
    for (int i = 0; i < 120; i++)
    {
        Counts c = EngineFrame(NULL);
        calls += c.read + c.write + c.log + c.queries + c.natives;
        polls += c.polls;
        CHECK(!vpm_post_ticking(Self()));
    }
    CHECK_EQ(polls, 1);
    CHECK_EQ(calls, 3); /* the mission checks at frames 30, 60 and 120 (1 read each) */
    CHECK_EQ(fake_hook_count(), 1); /* the frame hook only */
    fake_setup();
    StartedEngine(1);
    Target(0, 32);
    Put32(w.rt, 0);
    w.triggers[0] = 0;
    EngineFrame(NULL);
    for (int i = 0; i < 5; i++)
    {
        Counts c = EngineFrame(NULL);
        CHECK(c.polls == 1 && c.read == 26 && c.write + c.queries + c.natives == 0);
        CHECK(!vpm_post_ticking(Self()));
    }
    CHECK(StatusIs("observing"));
}

/* The post-update tick goes when nothing is engaged any more, and with the component. */
static void PostCheckStops(void)
{
    StartedEngine(1);
    EngineFrame(NULL);
    EngineFrame(LoseTarget);
    CHECK(sar_state.holding == 1 && vpm_post_ticking(Self()));
    /* The sentry vanishes while held: the releases in the first check, then nothing is engaged. */
    Put32(w.tm + 324, 0);
    Counts c = EngineFrame(NULL);
    CHECK(c.polls == 1 && !vpm_post_ticking(Self()));
    CHECK(Untouched() && StatusIs("waiting_for_sentries"));
    /* Stopped while engaged: restored, and no check runs any more. */
    fake_setup();
    StartedEngine(1);
    EngineFrame(NULL);
    EngineFrame(LoseTarget);
    vpm_core_stop(Self(), "test");
    CHECK(!vpm_post_ticking(Self()) && Untouched());
    c = EngineFrame(NULL);
    CHECK_EQ(c.polls + c.read + c.natives, 0);
}

/* A fault in the post-update check (a game function the hold calls) stops the component; its stop puts back the fire
 * pause, the search request and the half-made hold. The frame's first check, before the update, ran clean. */
static void AFaultInThePostCheck(void)
{
    StartedEngine(1);
    EngineFrame(NULL);
    Counts c = EngineFrame(LoseTargetAndFault);
    CHECK_EQ(c.polls, 2);
    CHECK(!vpm_running(Self()));
    CHECK_LOG("[Sentry Aim Retention] disabled: fault 0xC0000005");
    CHECK_NO_LOG("its stop did not finish");
    CHECK(Untouched());
    c = EngineFrame(NULL);
    CHECK_EQ(c.polls + c.read + c.natives, 0);
}

/* ---- the post-update tick refused (vpm_post_tick_start answers 0) -------------------------------------------------- */

/* One engine frame whose checks must all have run before the game's update, and its calls. */
static Counts FrameAllBeforeTheUpdate(void (*change)(void))
{
    uint32_t polls = sar_state.polls;
    Counts c = EngineFrame(change);
    CHECK_EQ(g_pollsInUpdate, polls + c.polls);
    CHECK(!vpm_post_ticking(Self()));
    return c;
}

/* Refused from the start: while a sentry is engaged the second check runs at once, before the game's update, where the
 * Lua made it: two checks per frame with the Lua's counts; a loss inside the update is answered by the next frame's
 * first check, as in the Lua. Lifted later, the post-update tick is used again. */
static void ARefusedPostTickChecksAtOnce(void)
{
    StartedEngine(1);
    fake_refuse_ticks(0, 1);
    FrameAllBeforeTheUpdate(NULL); /* located; the functions bound */
    Counts c = FrameAllBeforeTheUpdate(NULL);
    CHECK(c.polls == 2 && c.read == 62 && c.natives == 2 && c.queries == 0);
    c = FrameAllBeforeTheUpdate(LoseTarget);
    CHECK(c.polls == 2 && sar_state.holding == 0 && Get32(w.modes) == 1);
    c = FrameAllBeforeTheUpdate(NULL);
    CHECK(c.polls == 2 && c.read == 137 && c.queries == 5 && c.natives == 4);
    CHECK(g_holdingInUpdate == 1 && g_pausedInUpdate == 1 && StatusIs("firing_paused"));
    /* Reacquired: the release, the record at once, the second at once: all before the update. */
    Target(TARGET, 3);
    c = FrameAllBeforeTheUpdate(NULL);
    CHECK(c.polls == 3 && c.read == 168 && g_recordInUpdate);
    fake_refuse_ticks(0, 0);
    uint32_t polls = sar_state.polls;
    c = EngineFrame(NULL);
    CHECK(c.polls == 2 && g_pollsInUpdate == polls + 1 && vpm_post_ticking(Self()));
    vpm_core_stop(Self(), "test");
    CHECK(Untouched());
}

/* Refused after a registration worked: an engaged period with the post-update tick ends (the sentry removed: nothing
 * engaged, the tick removed); the core then refuses; the waiting frames make no check; the sentry back (found at the
 * next 30th check) engages again, and its second checks run at once. */
static void ARefusalAfterARegistrationWorked(void)
{
    StartedEngine(1);
    EngineFrame(NULL);
    uint32_t polls = sar_state.polls;
    Counts c = EngineFrame(NULL);
    CHECK(c.polls == 2 && g_pollsInUpdate == polls + 1 && vpm_post_ticking(Self()));
    Put32(w.tm + 324, 0);
    c = EngineFrame(NULL);
    CHECK(c.polls == 1 && !vpm_post_ticking(Self()) && StatusIs("waiting_for_sentries"));
    fake_refuse_ticks(0, 1);
    Put32(w.tm + 324, 1);
    int waiting = 0;
    while (sar_cache.exists && sar_cache.idle && (sar_cache.checks + 1) % SAR_RESCAN != 0 && waiting < 40)
    {
        c = FrameAllBeforeTheUpdate(NULL);
        CHECK_EQ(c.polls + c.read + c.natives + c.queries, 0);
        waiting++;
    }
    CHECK(waiting > 0 && waiting < 30);
    c = FrameAllBeforeTheUpdate(NULL); /* found, tracking: engaged */
    CHECK(c.polls == 2 && StatusIs("observing"));
    for (int i = 0; i < 5; i++)
    {
        c = FrameAllBeforeTheUpdate(NULL);
        CHECK(c.polls == 2 && c.read == 62);
    }
    vpm_core_stop(Self(), "test");
    CHECK(Untouched());
}

/* StopsAfterEightErrorsInABurst with the post-update tick refused: 7 errors (each leaves nothing engaged: one check),
 * then `engaged` clean frames on the refused branch (tracking: two checks at once), then the 8th error. 3599 clean
 * frames keep the burst (stopped), 3600 end it. 1 running. */
static int RefusedBurst(int engaged)
{
    fake_setup();
    StartedEngine(1);
    fake_refuse_ticks(0, 1);
    EngineFrame(NULL);
    Put32(w.behavior, 999);
    for (int i = 0; i < 7; i++) CHECK_EQ(FrameAllBeforeTheUpdate(NULL).polls, 1);
    CHECK(vpm_running(Self()) && fake_log_count("error: Unsupported sentry behavior") == 1);
    Put32(w.behavior, 213);
    for (int i = 0; i < engaged; i++)
    {
        if (i < 3 || i == engaged - 1) CHECK_EQ(FrameAllBeforeTheUpdate(NULL).polls, 2);
        else fake_engine_frames(1, DT);
    }
    CHECK(StatusIs("observing"));
    Put32(w.behavior, 999);
    EngineFrame(NULL);
    return vpm_running(Self());
}

static void ErrorBurstsOnTheRefusedBranch(void)
{
    CHECK(!RefusedBurst(3599));
    CHECK_LOG("disabled: stopped after 8 errors: Unsupported sentry behavior");
    CHECK(RefusedBurst(3600));
    CHECK_EQ(fake_log_count("error: Unsupported sentry behavior"), 2);
    CHECK(Untouched());
}

/* The seven code checks run once, at the first check that finds a sentry this machine controls (in a mission), never
 * at HF_EVENT_GAME_LOADED or while waiting. Still encoded there, the check fails as an own error (restored, started
 * fresh, still running) and the next check binds once the code reads as shipped. */
static void CodeChecksWaitForTheFirstSentry(void)
{
    MakeWorld();
    Ptr(Game(0x3326D30), NULL); /* no targeting registry yet */
    memset(Game(0x6BF390), 0xCC, 24); /* the retention setter: still encoded */
    fake_counts_reset();
    Started();
    fake_frames(120, DT);
    CHECK_EQ(fake_counts().code_matches, 0); /* the load, the first check, the waiting frames: no code check */
    Ptr(Game(0x3326D30), w.tm); /* the mission's registry with this machine's sentry */
    fake_counts_reset();
    for (int i = 0; i < 30 && sar_state.observed == 0 && fake_counts().code_matches == 0; i++) fake_frames(1, DT);
    CHECK(fake_counts().code_matches > 0 && fake_counts().code_matches < 7);
    CHECK(vpm_running(Self()) && StatusIs("Unsupported native sentry setter") && !sar_natives_bound());
    CHECK(Untouched());
    PutCodes(); /* decoded */
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(fake_counts().code_matches, 7);
    CHECK(sar_natives_bound() && StatusIs("observing"));
    fake_counts_reset();
    fake_frames(5, DT);
    CHECK_EQ(fake_counts().code_matches, 0);
}

/* ---- test_loader.lua: own errors --------------------------------------------------------------------------------- */

/* Each own error restores everything and starts afresh; one line per burst; a clean minute ends a burst; the 8th error
 * of a burst stops the component. */
static void StopsAfterEightErrorsInABurst(void)
{
    MakeWorld();
    Started();
    Frames(1);
    Put32(w.behavior, 999);
    Frames(7);
    CHECK(vpm_running(Self()) && StatusIs("Unsupported sentry behavior"));
    Put32(w.behavior, 213);
    Frames(3600);
    CHECK(StatusIs("observing"));
    Put32(w.behavior, 999);
    Frames(7);
    CHECK(vpm_running(Self()));
    const char* log = fake_log_text();
    int lines = 0;
    for (const char* at = log; (at = strstr(at, "error: Unsupported sentry behavior")) != NULL; at++) lines++;
    CHECK_EQ(lines, 2);
    Frames(1);
    CHECK(!vpm_running(Self()));
    CHECK_LOG("disabled: stopped after 8 errors: Unsupported sentry behavior");
    Counts c = Frames(10);
    CHECK_EQ(c.read + c.polls, 0);
}

/* Without a full restore an error stops the component at once; its stop tries once more. */
static void StopsAtOnceWhenARestoreFails(void)
{
    MakeWorld();
    Started();
    Frames(1);
    Target(0, 32);
    Frames(1);
    CHECK_EQ(sar_state.holding, 1);
    fake_hole((uintptr_t)w.control, 16);
    Frames(1);
    CHECK(!vpm_running(Self()));
    CHECK_LOG("disabled: Runtime read unavailable");
    CHECK_LOG("restore_failed");
    CHECK_NO_LOG("error: Runtime read unavailable");
    CHECK(Get32(w.nt + 16) == 0 && Get32(w.modes) == 1); /* what could be restored was */
}

/* ---- test_aim.lua: the aim step on rows built by the test -------------------------------------------------------- */

/* A sentry the test drives: its identity guard at base, flags at +32, raw aim +40, computed aim +52, control +72
 * (speeds at +8 and +12). The fake setters find it by id and by entity (base). */
static SarRow g_rows_made[4];

static SarRow* NewSentry(int k, uint32_t id, uint8_t* base)
{
    SarRow* s = &g_rows_made[k];
    memset(s, 0, sizeof *s);
    s->id = id;
    snprintf((char*)s->key, sizeof s->key, "instance%u", id);
    s->profile = &sar_profiles[0];
    s->entity = (uintptr_t)base;
    memcpy(base, "identity", 8);
    s->guard_count = 1;
    sar_guard_set(&s->guards[0], (uintptr_t)base, "identity", 8);
    s->enabled = 1;
    s->node = 12;
    s->target = 77;
    s->runtime_target = 77;
    s->has = 1;
    s->source_flags = 3;
    Vec(s->point, 40, 20, 0);
    Vec(s->raw, 40, 20, 2);
    memcpy(s->computed, s->raw, 12);
    PutF(s->horizontal, 150);
    PutF(s->vertical, 90);
    s->flags_address = (uintptr_t)base + 32;
    s->raw_address = (uintptr_t)base + 40;
    s->computed_address = (uintptr_t)base + 52;
    s->control_address = (uintptr_t)base + 72;
    Put32(base + 32, 0);
    memcpy(base + 40, s->raw, 12);
    memcpy(base + 52, s->computed, 12);
    memcpy(base + 80, s->horizontal, 4);
    memcpy(base + 84, s->vertical, 4);
    AddFake(id, (uintptr_t)base, base + 32, base + 72, NULL);
    return s;
}

/* The row as the next snapshot reads it. */
static void Fresh(SarRow* s)
{
    s->flags = Get32((const void*)s->flags_address);
    memcpy(s->raw, (const void*)s->raw_address, 12);
    memcpy(s->computed, (const void*)s->computed_address, 12);
    memcpy(s->horizontal, (const void*)(s->control_address + 8), 4);
    memcpy(s->vertical, (const void*)(s->control_address + 12), 4);
}

static const char* g_why;
static int AimStep(SarRow* const* rows, int count)
{
    g_why = "";
    return sar_aim_step(rows, count, &g_why);
}
static int AimStep1(SarRow* s) { return AimStep(&s, 1); }

static int SpeedIs(const SarRow* s, float horizontal, float vertical)
{
    return GetF((const void*)(s->control_address + 8)) == horizontal && GetF((const void*)(s->control_address + 12)) == vertical;
}

static int RawIs(const SarRow* s, float x, float y, float z)
{
    uint8_t v[12];
    Vec(v, x, y, z);
    return memcmp((const void*)s->raw_address, v, 12) == 0;
}

static void AimStarted(void)
{
    ResetFakes();
    Started();
}

static void LossHoldsAimAndScanReleases(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    CHECK(AimStep1(s));
    s->target = 0;
    s->source_flags = 32;
    Vec(s->raw, 40, 20, 0);
    memcpy(s->computed, s->raw, 12);
    memcpy((void*)s->raw_address, s->raw, 12);
    memcpy((void*)s->computed_address, s->raw, 12);
    CHECK(AimStep1(s));
    Fresh(s);
    CHECK(s->flags == 2 && RawIs(s, 40, 20, 2) && SpeedIs(s, 0, 0));
    CHECK(sar_state.holds == 1 && sar_state.late_aim == 1);
    Vec(s->point, 1, 2, 3);
    CHECK(AimStep1(s) && sar_state.holding == 1); /* the firing node */
    s->node = 3;
    Vec(s->point, 0, 0, 0);
    CHECK(AimStep1(s) && sar_state.holding == 1); /* the transition placeholder */
    Vec(s->point, 10, 30, 2);
    CHECK(AimStep1(s));
    Fresh(s);
    CHECK(sar_state.releases == 1 && sar_state.holding == 0 && s->flags == 0 && SpeedIs(s, 150, 90));
}

static void NewTargetReleasesAtOnce(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    AimStep1(s);
    s->target = 0;
    s->has = 0;
    AimStep1(s);
    Fresh(s);
    s->target = 88;
    s->has = 1;
    s->source_flags = 3;
    CHECK(AimStep1(s));
    Fresh(s);
    CHECK(s->flags == 0 && sar_state.holding == 0);
}

static void IndependentSentriesAndCleanStop(void)
{
    AimStarted();
    SarRow* a = NewSentry(0, 1, Block(128));
    SarRow* b = NewSentry(1, 2, Block(128));
    SarRow* c = NewSentry(2, 3, Block(128));
    SarRow* rows[3] = {a, b, c};
    c->target = 0;
    c->node = 2;
    c->source_flags = 32;
    AimStep(rows, 3);
    a->target = 0;
    a->has = 0;
    AimStep(rows, 3);
    Fresh(a);
    Fresh(b);
    Fresh(c);
    CHECK(a->flags == 2 && b->flags == 0 && c->flags == 0);
    CHECK(sar_aim_stop());
    Fresh(a);
    CHECK(a->flags == 0 && SpeedIs(a, 150, 90));
}

static void NativeDisableMasksAreLeftAlone(void)
{
    static const uint32_t masks[] = {1, 2, 3, 16};
    for (int k = 0; k < 4; k++)
    {
        fake_setup();
        AimStarted();
        SarRow* s = NewSentry(0, 1, Block(128));
        AimStep1(s);
        s->target = 0;
        s->flags = masks[k];
        Put32((void*)s->flags_address, masks[k]);
        CHECK(AimStep1(s));
        CHECK_EQ(NativeCalls(), 0);
        CHECK_EQ(Get32((const void*)s->flags_address), masks[k]);
    }
}

/* A setter that did not take: the hold fails, and the stop restores only what was acquired. */
static void SetterFailureRestoresWhatWasAcquired(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    AimStep1(s);
    s->target = 0;
    Vec(s->raw, 3, 4, 5);
    memcpy(s->computed, s->raw, 12);
    memcpy((void*)s->raw_address, s->raw, 12);
    memcpy((void*)s->computed_address, s->raw, 12);
    g_refuse_vertical = 1;
    CHECK(!AimStep1(s));
    CHECK(strcmp(g_why, "hold_speed_failed") == 0);
    CHECK(sar_aim_stop());
    Fresh(s);
    CHECK(s->flags == 0 && SpeedIs(s, 150, 90) && RawIs(s, 3, 4, 5));
}

static void RefusedMemoryAndChangedIdentityWriteNothing(void)
{
    AimStarted();
    uint8_t* base = Page();
    SarRow* s = NewSentry(0, 1, base);
    AimStep1(s);
    s->target = 0;
    Protect(base, 4096, PAGE_READONLY);
    CHECK(!AimStep1(s));
    CHECK(strcmp(g_why, "hold_memory_unavailable") == 0);
    CHECK_EQ(NativeCalls(), 0);
    Protect(base, 4096, PAGE_READWRITE);
    memcpy(base, "replaced", 8);
    CHECK(AimStep1(s));
    CHECK_EQ(NativeCalls(), 0);
}

/* An unfinished hold's aim: both writes rolled back while ours (the computed one cut short is still ours). */
static SarLease* UnfinishedHold(SarRow* s)
{
    AimStep1(s);
    s->target = 0;
    Vec(s->raw, 3, 4, 5);
    memcpy(s->computed, s->raw, 12);
    memcpy((void*)s->raw_address, s->raw, 12);
    memcpy((void*)s->computed_address, s->raw, 12);
    CHECK(AimStep1(s) && sar_state.holding == 1);
    SarAimRecord* r = sar_aim_record(s->id);
    if (r == NULL) return NULL;
    r->lease.completed = 0;
    memcpy((uint8_t*)s->computed_address + 6, r->lease.aim[1].before + 6, 6);
    return &r->lease;
}

static void OneFailedRollbackLeavesTheOthers(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    SarLease* lease = UnfinishedHold(s);
    if (lease == NULL) return;
    /* The raw write was journaled at an address the release does not check (another page), now read-only. */
    uint8_t* page = Page();
    memcpy(page, lease->aim[0].after, 12);
    lease->aim[0].address = (uintptr_t)page;
    Protect(page, 4096, PAGE_READONLY);
    CHECK(!sar_aim_stop());
    Fresh(s);
    CHECK(s->flags == 0 && SpeedIs(s, 150, 90));
    Protect(page, 4096, PAGE_READWRITE);
    CHECK(sar_aim_stop());
    CHECK(memcmp(page, lease->aim[0].before, 12) == 0);
}

/* A rollback write inside the aim range the release just checked makes no query of its own; one elsewhere does. */
static void RollbackQueriesOnlyOutsideTheCheckedRange(void)
{
    for (int moved = 0; moved <= 1; moved++)
    {
        fake_setup();
        AimStarted();
        SarRow* s = NewSentry(0, 1, Block(128));
        SarLease* lease = UnfinishedHold(s);
        if (lease == NULL) return;
        if (moved)
        {
            uint8_t* other = Block(64);
            lease->held.raw_address = (uintptr_t)other;
        }
        sar_writable_forget();
        uint32_t before = sar_writable_queries();
        const char* why = "";
        CHECK(sar_aim_release(lease, &why));
        CHECK_EQ(sar_writable_queries() - before, moved ? 5u : 3u);
        CHECK(RawIs(s, 3, 4, 5));
        uint8_t v[12];
        Vec(v, 3, 4, 5);
        CHECK(memcmp((const void*)s->computed_address, v, 12) == 0);
    }
}

static void CompactionKeepsTheSavedSpeeds(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    AimStep1(s);
    s->target = 0;
    AimStep1(s);
    Fresh(s);
    uint8_t* base = Block(128);
    SarRow* moved = NewSentry(1, 1, base);
    moved->target = 0;
    moved->source_flags = 32;
    moved->node = 12;
    Put32(base + 32, 2);
    PutF(base + 80, 0);
    PutF(base + 84, 0);
    memcpy((void*)s->guards[0].at, "retired!", 8);
    Fresh(moved);
    CHECK(AimStep1(moved) && sar_state.holding == 1);
    CHECK(sar_aim_stop());
    Fresh(moved);
    CHECK(moved->flags == 0 && SpeedIs(moved, 150, 90));
}

/* A native hash-table replacement alone (the same component slots) cannot orphan a hold. */
static void MapReplacementCannotOrphanAHold(void)
{
    for (int release = 0; release < 3; release++)
    {
        fake_setup();
        AimStarted();
        SarRow* s = NewSentry(0, 1, Block(128));
        uint8_t* map = Block(8);
        memcpy(map, "old map!", 8);
        s->guard_count = 2;
        sar_guard_set(&s->guards[1], (uintptr_t)map, "old map!", 8);
        AimStep1(s);
        s->target = 0;
        s->has = 0;
        AimStep1(s);
        Fresh(s);
        memcpy(map, "new map!", 8);
        sar_guard_set(&s->guards[1], (uintptr_t)map, "new map!", 8);
        if (release == 0) { s->target = 88; s->has = 1; s->source_flags = 3; }
        if (release == 1) { s->has = 1; s->node = 2; s->source_flags = 32; Vec(s->point, 1, 3, 2); }
        CHECK(AimStep1(s));
        if (release == 2) CHECK(sar_aim_stop());
        Fresh(s);
        CHECK(s->flags == 0 && SpeedIs(s, 150, 90));
    }
}

static void NativeSpeedChangesArePreserved(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    AimStep1(s);
    s->target = 0;
    AimStep1(s);
    PutF((void*)(s->control_address + 8), 42);
    Fresh(s);
    CHECK(AimStep1(s));
    Fresh(s);
    CHECK(s->flags == 0 && SpeedIs(s, 42, 90));
}

static void AnotherDisableBitEndsTheHold(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    uint8_t* authority = Block(8);
    authority[0] = 1;
    s->authority_address = (uintptr_t)authority;
    AimStep1(s);
    s->target = 0;
    AimStep1(s);
    Put32((void*)s->flags_address, 18);
    authority[0] = 5;
    Fresh(s);
    CHECK(AimStep1(s));
    Fresh(s);
    CHECK(s->flags == 16 && SpeedIs(s, 150, 90));
}

static void RepeatedCyclesLeaveNoStaleWrites(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    AimStep1(s);
    s->target = 0;
    AimStep1(s);
    Put32((void*)s->flags_address, 0);
    Fresh(s);
    AimStep1(s);
    Fresh(s);
    CHECK(GetF(s->horizontal) == 150);
    CHECK(sar_aim_stop());
    s = NewSentry(1, 2, Block(128));
    AimStep1(s);
    s->target = 0;
    AimStep1(s);
    memcpy((void*)s->guards[0].at, "removed!", 8);
    int before = NativeCalls();
    CHECK(AimStep(NULL, 0));
    CHECK_EQ(NativeCalls(), before);
    CHECK(sar_aim_record(2) == NULL);
}

typedef struct LossRow { double t; uint32_t node, target, runtime_target, flags; int has; float point[3], raw[3], computed[3]; } LossRow;
typedef struct FiringRow
{
    double t;
    uint32_t id, machine_gun, target, runtime_target, trigger, has, flags, enabled;
    float aim[3], pose[16];
    uint32_t rounds, held;
} FiringRow;
static const LossRow* GatlingLoss(int* count);   /* the replays' rows, at the end of this file */
static const FiringRow* FiringSweeps(int* count);

/* The recorded Gatling losses (182 samples): aim held through the fallback, reacquisition and scanning release it. The
 * Lua: 52 held, 8 holds, 8 releases. */
static void RecordedLossesHoldAndRelease(void)
{
    AimStarted();
    SarRow* s = NewSentry(0, 1, Block(128));
    int held = 0, replayed = 0, count = 0;
    const LossRow* rows = GatlingLoss(&count);
    for (int i = 0; i < count; i++)
    {
        const LossRow* row = &rows[i];
        Fresh(s);
        s->node = row->node;
        s->target = row->target;
        s->runtime_target = row->runtime_target;
        s->has = row->has;
        s->source_flags = row->flags;
        Vec(s->point, row->point[0], row->point[1], row->point[2]);
        if (s->flags == 0) /* native targeting cannot replace the aim while our bit is set */
        {
            Vec(s->raw, row->raw[0], row->raw[1], row->raw[2]);
            Vec(s->computed, row->computed[0], row->computed[1], row->computed[2]);
            memcpy((void*)s->raw_address, s->raw, 12);
            memcpy((void*)s->computed_address, s->computed, 12);
        }
        CHECK(AimStep1(s));
        replayed++;
        if (sar_state.holding > 0) { held++; CHECK(GetF((const void*)(s->control_address + 8)) == 0); }
    }
    printf("  replay: %d samples, %d held, %u holds, %u releases\n", replayed, held, sar_state.holds, sar_state.releases);
    CHECK_EQ(replayed, 182);
    CHECK_EQ(held, 52);
    CHECK_EQ(sar_state.holds, 8);
    CHECK_EQ(sar_state.releases, 8);
    CHECK_EQ(sar_state.holding, 0);
    CHECK(sar_aim_stop());
}

/* ---- test_firing.lua: the fire step on a row built by the test --------------------------------------------------- */

static struct { SarRow s; uint8_t* identity; uint8_t* mode; uint8_t* deadline; uint8_t* behavior; uint8_t* clock; } g_fire;

static SarRow* FireFixture(double pause, double resume)
{
    AimStarted();
    memset(&g_fire, 0, sizeof g_fire);
    SarRow* s = &g_fire.s;
    g_fire.identity = Block(8);
    memcpy(g_fire.identity, "identity", 8);
    g_fire.mode = Block(4);
    Put32(g_fire.mode, 1);
    s->id = 1;
    memcpy(s->key, "sentry", 6);
    s->profile = &sar_profiles[0];
    s->guard_count = 1;
    sar_guard_set(&s->guards[0], (uintptr_t)g_fire.identity, "identity", 8);
    s->enabled = 1;
    s->has = 1;
    s->target = 1;
    s->runtime_target = 1;
    s->source_flags = 3;
    s->has_fire = 1;
    s->fire.manager = 20;
    s->fire.mode_address = (uintptr_t)g_fire.mode;
    s->fire.mode = 1;
    s->fire.unit = 1;
    s->fire.node = 1;
    s->fire.trigger = 1;
    s->fire.pause = pause;
    s->fire.resume = resume;
    s->fire.terrain_blocked = SAR_UNKNOWN;
    AddFake(1, 0, NULL, NULL, g_fire.mode);
    return s;
}

/* The computed aim at `degrees` from the muzzle, which points at `bearing` (20 m out). */
static void Aim(double degrees, double bearing)
{
    SarRow* s = &g_fire.s;
    double d = (degrees + bearing) * RAD, b = bearing * RAD;
    float pose[16] = {1, 0, 0, 0, (float)sin(b), (float)cos(b), 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    Vec(s->computed, (float)(sin(d) * 20), (float)(cos(d) * 20), 0);
    memcpy(s->fire.pose, pose, 64);
    s->fire.has_pose = 1;
}

static int FireStep(double t, double degrees, double bearing)
{
    SarRow* s = &g_fire.s;
    s->fire.mode = Get32(g_fire.mode);
    Aim(degrees, bearing);
    g_why = "";
    return sar_fire_step(&s, 1, t, &g_why);
}

static int Writes(void) { return g_mode_writes; }
static uint32_t Written(int k) { return g_modes[k - 1]; }
static int FireStop(void) { int fire = sar_fire_stop(); return sar_aim_stop() && fire; }

static void AngularLimitsMatchTheProfiles(void)
{
    for (int k = 0; k < sar_profile_count; k++)
    {
        const SarProfile* p = &sar_profiles[k];
        if (!p->fire_gate) continue;
        fake_setup();
        CHECK(p->pause == (strcmp(p->name, "Gatling") == 0 ? 16 : 14));
        FireFixture(p->pause, p->resume);
        FireStep(0, 1, 0);
        FireStep(.08, 1, 0);
        FireStep(.1, p->pause - .01, 0);
        CHECK_EQ(Writes(), 0);
        FireStep(.12, p->pause + .01, 0);
        CHECK(Writes() == 1 && Written(1) == 0);
    }
}

static void NearbyTargetChangesKeepFiring(void)
{
    static const double policies[2][3] = {{16, 4, 13.95}, {14, 3, 13.57}};
    for (int k = 0; k < 2; k++)
    {
        fake_setup();
        SarRow* s = FireFixture(policies[k][0], policies[k][1]);
        CHECK(FireStep(0, 1, 0) && FireStep(.08, 1, 0));
        s->target = s->runtime_target = 2;
        CHECK(FireStep(.10, policies[k][2], 1) && FireStep(.14, 2, 4) && FireStep(.21, 1, 5));
        CHECK(Writes() == 0 && sar_state.fire_paused == 0);
    }
}

static void CloseReplacementReopensAtOnce(void)
{
    static const double policies[2][3] = {{16, 4, 13.95}, {14, 3, 13.57}};
    for (int k = 0; k < 2; k++)
    {
        fake_setup();
        SarRow* s = FireFixture(policies[k][0], policies[k][1]);
        s->fire.terrain_blocked = 0;
        FireStep(0, 1, 0);
        FireStep(.08, 1, 0);
        s->target = 0;
        s->has = 0;
        FireStep(.1, 1, 0);
        CHECK(Writes() == 1 && Written(1) == 0);
        FireStep(.8, 1, 0);
        CHECK_EQ(Writes(), 1); /* no rounds during the observed long target gap */
        s->target = s->runtime_target = 2;
        s->has = 1;
        FireStep(.81, policies[k][2], 0);
        CHECK(Writes() == 2 && Written(2) == 1);
        FireStep(.84, 2, 4);
        FireStep(.91, 1, 5);
        CHECK_EQ(Writes(), 2);
    }
}

static void HandoffNeedsSynchronizedAimAndAFreshQuery(void)
{
    SarRow* s = FireFixture(16, 4);
    s->fire.terrain_blocked = 0;
    FireStep(0, 1, 0);
    FireStep(.08, 1, 0);
    s->target = 0;
    s->has = 0;
    FireStep(.1, 1, 0);
    s->target = 2;
    s->has = 1;
    s->fire.terrain_blocked = SAR_UNKNOWN;
    FireStep(.8, 10, 0);
    CHECK_EQ(Writes(), 1); /* the runtime target is still the old one */
    s->runtime_target = 2;
    FireStep(.82, 10, 0);
    CHECK_EQ(Writes(), 1); /* no completed query */
    s->fire.terrain_blocked = 0;
    FireStep(.84, 10, 0);
    CHECK_EQ(Writes(), 2);
}

static void StaleAimCannotFireAtAnotherTarget(void)
{
    SarRow* s = FireFixture(16, 4);
    s->fire.terrain_blocked = 0;
    FireStep(0, 1, 0);
    FireStep(.08, 1, 0);
    s->target = 2; /* the runtime target and computed aim still belong to target 1 */
    FireStep(.1, 1, 0);
    CHECK(Writes() == 1 && Written(1) == 0);
    for (int i = 1; i <= 100; i++) FireStep(.1 + i * .1, 1, 0);
    CHECK(Writes() == 1 && sar_fire_record(1)->reason == SAR_REASON_AIM_PENDING);
    s->runtime_target = 2;
    FireStep(10.2, 8, 0);
    CHECK(Writes() == 2 && Written(2) == 1);
}

static void WideTurnOrObstructionCancelsTheHandoff(void)
{
    for (int cause = 0; cause < 2; cause++)
    {
        fake_setup();
        SarRow* s = FireFixture(16, 4);
        s->fire.terrain_blocked = 0;
        FireStep(0, 1, 0);
        FireStep(.08, 1, 0);
        s->target = 0;
        s->has = 0;
        FireStep(.1, 1, 0);
        s->target = s->runtime_target = 2;
        s->has = 1;
        s->fire.terrain_blocked = cause == 1;
        FireStep(.8, cause == 0 ? 90 : 10, 0);
        s->fire.terrain_blocked = 0;
        FireStep(.9, 10, 0);
        CHECK_EQ(Writes(), 1);
        FireStep(.94, 2, 0);
        FireStep(.98, 2, 0);
        CHECK_EQ(Writes(), 1);
        FireStep(1.01, 2, 0);
        CHECK_EQ(Writes(), 2);
    }
}

static void PausedTimeIsNotASweep(void)
{
    SarRow* s = FireFixture(16, 4);
    s->fire.terrain_blocked = 0;
    FireStep(0, 1, 0);
    FireStep(.08, 1, 0);
    FireStep(.1, 8, 2);
    s->target = 0;
    s->has = 0;
    FireStep(.12, 8, 2);
    FireStep(.9, 8, 2);
    s->target = s->runtime_target = 2;
    s->has = 1;
    FireStep(.92, 10, 2);
    CHECK(Writes() == 2 && Written(2) == 1);
}

static void BroadPauseIsNoHandoff(void)
{
    SarRow* s = FireFixture(16, 4);
    s->fire.terrain_blocked = 0;
    FireStep(0, 90, 0);
    s->target = 0;
    s->has = 0;
    FireStep(.1, 0, 0);
    s->target = s->runtime_target = 2;
    s->has = 1;
    FireStep(.5, 10, 0);
    CHECK_EQ(Writes(), 1);
    FireStep(.6, 2, 0);
    FireStep(.67, 2, 0);
    CHECK_EQ(Writes(), 2);
}

static void BroadSweepsPauseWithHysteresis(void)
{
    static const double turns[] = {84, 180};
    for (int k = 0; k < 2; k++)
    {
        fake_setup();
        SarRow* s = FireFixture(16, 4);
        CHECK(FireStep(0, 1, 0));
        s->target = s->runtime_target = 2;
        CHECK(FireStep(.10, turns[k], 0));
        CHECK(sar_state.fire_paused == 1 && Written(1) == 0);
        CHECK(FireStep(.16, 10, 0) && FireStep(.20, 5, 0));
        CHECK_EQ(Writes(), 1);
        CHECK(FireStep(.25, 3, 0) && FireStep(.28, 3, 0));
        CHECK_EQ(Writes(), 1);
        CHECK(FireStep(.32, 2, 0));
        CHECK(Written(2) == 1 && sar_state.fire_paused == 0);
        CHECK(s->fire.trigger); /* shot permission never releases the AI trigger */
    }
}

static void UnsettledSweepsAreBounded(void)
{
    FireFixture(16, 4);
    FireStep(0, 1, 0);
    FireStep(.08, 1, 0);
    FireStep(.10, 7, 1);
    FireStep(.21, 7, 2);
    FireStep(.31, 7, 3);
    CHECK(Written(1) == 0 && sar_state.fire_paused == 1);
    fake_setup();
    FireFixture(16, 4);
    FireStep(0, 1, 0);
    FireStep(.08, 1, 0);
    FireStep(.10, 6, 6);
    FireStep(.14, 6, 12);
    FireStep(.18, 6, 18);
    CHECK(Writes() >= 1 && Written(1) == 0);
}

static void TrackingKeepsFiringLossStopsTheBurst(void)
{
    SarRow* s = FireFixture(16, 4);
    for (int i = 0; i <= 50; i++) CHECK(FireStep(i * .02, 1, i));
    s->target = 0;
    s->has = 0;
    CHECK_EQ(Writes(), 0);
    CHECK(FireStep(1.1, 80, 50) && FireStep(1.5, 80, 50));
    CHECK(Writes() == 1 && Written(1) == 0);
    CHECK(FireStep(1.6, 0, 50) && FireStep(1.8, 0, 50));
    CHECK_EQ(Writes(), 1);
    s->target = s->runtime_target = 2;
    s->has = 1;
    CHECK(FireStep(1.9, 0, 50) && FireStep(1.98, 0, 50));
    CHECK(Writes() == 2 && Written(2) == 1);
}

static void TerrainBlocksABuriedAim(void)
{
    static const double policies[2][2] = {{16, 4}, {14, 3}};
    for (int k = 0; k < 2; k++)
    {
        fake_setup();
        SarRow* s = FireFixture(policies[k][0], policies[k][1]);
        s->fire.terrain_blocked = 0;
        FireStep(0, 0, 0);
        FireStep(.08, 0, 0);
        CHECK_EQ(Writes(), 0);
        s->fire.terrain_blocked = 1;
        FireStep(.10, 0, 0);
        CHECK(Written(1) == 0 && sar_fire_record(1)->reason == SAR_REASON_TERRAIN_BLOCKED);
        for (int i = 1; i <= 100; i++) FireStep(.10 + i * .02, 0, 0);
        CHECK_EQ(Writes(), 1); /* settled aim below terrain cannot reopen fire */
        s->fire.terrain_blocked = SAR_UNKNOWN;
        FireStep(2.2, 0, 0);
        CHECK_EQ(Writes(), 1); /* pending native workers */
        s->fire.terrain_blocked = 0;
        FireStep(2.3, 0, 0);
        FireStep(2.34, 0, 0);
        CHECK_EQ(Writes(), 1);
        FireStep(2.38, 0, 0);
        CHECK(Writes() == 2 && Written(2) == 1 && s->fire.trigger);
    }
}

static void BlockedStateStaysWithItsTarget(void)
{
    SarRow* s = FireFixture(16, 4);
    s->fire.terrain_blocked = 1;
    FireStep(0, 0, 0);
    s->target = s->runtime_target = 2;
    s->fire.terrain_blocked = 0;
    FireStep(.1, 0, 0);
    FireStep(.18, 0, 0);
    CHECK(Writes() >= 2 && Written(2) == 1);
    s->fire.terrain_blocked = 1;
    FireStep(.2, 0, 0);
    Put32(g_fire.mode, 3);
    CHECK(FireStop());
    CHECK_EQ(Get32(g_fire.mode), 3);
}

static void ScanningAfterTheTriggerReleases(void)
{
    SarRow* s = FireFixture(16, 4);
    s->fire.terrain_blocked = 1;
    FireStep(0, 0, 0);
    s->target = 0;
    s->has = 0;
    s->fire.trigger = 0;
    FireStep(.1, 0, 0);
    CHECK(Writes() == 2 && Written(2) == 1 && sar_state.fire_paused == 0);
}

static void PausedLossWaitsForTheTrigger(void)
{
    SarRow* s = FireFixture(16, 4);
    FireStep(0, 84, 0);
    s->target = 0;
    s->has = 0;
    FireStep(.1, 1, 0);
    CHECK_EQ(Writes(), 1);
    s->fire.trigger = 0;
    FireStep(.2, 1, 0);
    CHECK(Writes() == 2 && Written(2) == 1);
    s->target = s->runtime_target = 2;
    s->has = 1;
    s->fire.trigger = 1;
    FireStep(.3, 1, 0);
    CHECK_EQ(Writes(), 2);
}

static void OwnershipOfTheFireMode(void)
{
    FireFixture(16, 4);
    Put32(g_fire.mode, 0);
    FireStep(0, 90, 0);
    CHECK_EQ(Writes(), 0);
    CHECK(FireStop());
    CHECK_EQ(Get32(g_fire.mode), 0);
    fake_setup();
    FireFixture(16, 4);
    FireStep(0, 90, 0);
    Put32(g_fire.mode, 3);
    CHECK(FireStop());
    CHECK_EQ(Get32(g_fire.mode), 3);
}

static void RelocatedLeasesAndStaleEntities(void)
{
    SarRow* s = FireFixture(16, 4);
    FireStep(0, 90, 0);
    uint8_t* mode = Block(4);
    s->fire.mode_address = (uintptr_t)mode;
    AddFake(1, 0, NULL, NULL, mode);
    s->fire.mode = 0;
    Aim(90, 0);
    CHECK(sar_fire_step(&s, 1, .1, &g_why));
    CHECK(FireStop());
    CHECK_EQ(Get32(mode), 1);
    fake_setup();
    FireFixture(16, 4);
    FireStep(0, 90, 0);
    memcpy(g_fire.identity, "recycled", 8);
    CHECK(FireStop());
    CHECK_EQ(Get32(g_fire.mode), 0);
}

static void InvalidMuzzleFailsFirst(void)
{
    SarRow* s = FireFixture(16, 4);
    FireStep(0, 1, 0);
    memset(s->fire.pose, 0, 64);
    CHECK(!sar_fire_step(&s, 1, .1, &g_why));
    CHECK(strcmp(g_why, "Invalid firing direction") == 0);
    CHECK_EQ(Writes(), 0);
}

/* ---- test_firing.lua: the target search request ------------------------------------------------------------------ */

static SarRow* SelectionFixture(void)
{
    SarRow* s = FireFixture(16, 4);
    g_fire.deadline = Page();
    Put64(g_fire.deadline, 1800000);
    g_fire.behavior = Block(16);
    Put32(g_fire.behavior + 8, 12);
    g_fire.clock = Block(8);
    memcpy(g_fire.clock, "clockptr", 8);
    s->node = 12;
    s->behavior_address = (uintptr_t)g_fire.behavior;
    s->selection.address = (uintptr_t)g_fire.deadline;
    s->selection.now = 1000000;
    memcpy(s->selection.deadline, g_fire.deadline, 8);
    sar_guard_set(&s->selection.guard, (uintptr_t)g_fire.clock, "clockptr", 8);
    return s;
}

static int SelectionStep(double t)
{
    SarRow* s = &g_fire.s;
    Put32(g_fire.behavior + 8, s->node);
    s->selection.now = floor(t * 1000000);
    memcpy(s->selection.deadline, (const void*)s->selection.address, 8);
    CHECK(FireStep(t, 1, 0));
    g_why = "";
    return sar_selection_step(&s, 1, &g_why);
}

static uint64_t Deadline(void) { return Get64((const void*)g_fire.s.selection.address); }

static void LossShortensTheSearchOnce(void)
{
    SarRow* s = SelectionFixture();
    s->fire.terrain_blocked = 0;
    CHECK(SelectionStep(1) && Deadline() == 1800000);
    s->target = 0;
    s->has = 1;
    s->source_flags = 32;
    CHECK(SelectionStep(1.1));
    CHECK(Deadline() == 1100000 && sar_state.reselections == 1 && Get32(g_fire.mode) == 0);
    CHECK(SelectionStep(1.11) && Deadline() == 1100000 && sar_state.reselections == 1);
    /* The native handler's deadline branch runs the query at 1.12 s and selects the adjacent candidate. */
    Put64(g_fire.deadline, 2120000);
    s->target = s->runtime_target = 2;
    s->has = 1;
    s->source_flags = 3;
    CHECK(SelectionStep(1.12));
    CHECK(Get32(g_fire.mode) == 1 && Deadline() == 2120000 && !sar_fire_record(1)->requested);
    s->target = 0;
    s->has = 0;
    CHECK(SelectionStep(1.2) && sar_state.reselections == 2);
    Put64(g_fire.deadline, 1450000); /* the native search found no eligible replacement */
    CHECK(SelectionStep(1.22) && SelectionStep(1.5) && SelectionStep(2));
    CHECK(Deadline() == 1450000 && sar_state.reselections == 2 && Get32(g_fire.mode) == 0);
}

static void InvalidTargetsCannotForceSearchesEveryFrame(void)
{
    SarRow* s = SelectionFixture();
    SelectionStep(1);
    s->target = 0;
    s->has = 0;
    SelectionStep(1.1);
    Put64(g_fire.deadline, 2110000);
    s->target = s->runtime_target = 1;
    s->has = 1;
    SelectionStep(1.11);
    s->target = 0;
    s->has = 0;
    SelectionStep(1.13);
    CHECK(Deadline() == 1200000 && sar_state.reselections == 2);
    CHECK(SelectionStep(1.14) && sar_state.reselections == 2 && Deadline() == 1200000);
}

static void RequestsNeedALossOnTheFiringNode(void)
{
    for (int cause = 0; cause < 7; cause++) /* first sample, scanning, disabled, overdue, long timer, invalid clock, same target */
    {
        fake_setup();
        SarRow* s = SelectionFixture();
        if (cause != 0) SelectionStep(1);
        if (cause != 6) { s->target = 0; s->has = 0; }
        if (cause == 1) s->node = 2;
        if (cause == 2) s->enabled = 0;
        if (cause == 3) Put64(g_fire.deadline, 1000000);
        if (cause == 4) Put64(g_fire.deadline, 5000000);
        uint64_t before = Deadline();
        CHECK(SelectionStep(cause == 5 ? 0 : 1.1));
        CHECK(Deadline() == before && sar_state.reselections == 0);
    }
}

static void StopRestoresAnUnconsumedRequest(void)
{
    for (int consumed = 0; consumed <= 1; consumed++)
    {
        fake_setup();
        SarRow* s = SelectionFixture();
        SelectionStep(1);
        s->target = 0;
        s->has = 0;
        SelectionStep(1.1);
        if (consumed) Put64(g_fire.deadline, 2100000);
        CHECK(FireStop());
        CHECK(Deadline() == (consumed ? 2100000u : 1800000u) && Get32(g_fire.mode) == 1);
    }
}

static void RequestsRefuseChangedGuardsAndMemory(void)
{
    for (int cause = 0; cause < 4; cause++) /* entity, clock, transition, memory */
    {
        fake_setup();
        SarRow* s = SelectionFixture();
        SelectionStep(1);
        s->target = 0;
        s->has = 0;
        Put32(g_fire.mode, 0); /* no fire-mode change in this test */
        uint8_t* state = Block(8);
        if (cause == 0) memcpy(g_fire.identity, "recycled", 8);
        if (cause == 1) memcpy(g_fire.clock, "newclock", 8);
        if (cause == 2) { memcpy(state, "newstate", 8); s->transition_count = 1; sar_guard_set(&s->transition[0], (uintptr_t)state, "oldstate", 8); }
        if (cause == 3) Protect(g_fire.deadline, 4096, PAGE_READONLY);
        CHECK(!SelectionStep(1.1));
        if (cause == 3) Protect(g_fire.deadline, 4096, PAGE_READWRITE);
        CHECK(Deadline() == 1800000 && sar_state.reselections == 0);
        CHECK(strcmp(g_why, cause == 3 ? "selection_memory_unavailable" : "selection_identity_changed") == 0);
    }
}

static void RequestFollowsRelocatedMemory(void)
{
    SarRow* s = SelectionFixture();
    SelectionStep(1);
    s->target = 0;
    s->has = 0;
    SelectionStep(1.1);
    memcpy(g_fire.clock, "newclock", 8);
    sar_guard_set(&s->selection.guard, (uintptr_t)g_fire.clock, "newclock", 8);
    uint8_t* moved = Block(8);
    memcpy(moved, g_fire.deadline, 8);
    s->selection.address = (uintptr_t)moved;
    CHECK(SelectionStep(1.12));
    CHECK(FireStop());
    CHECK(Get64(moved) == 1800000 && Get64(g_fire.deadline) == 1100000);
    fake_setup();
    s = SelectionFixture();
    SelectionStep(1);
    s->target = 0;
    s->has = 0;
    SelectionStep(1.1);
    Put32(g_fire.behavior + 8, 2);
    CHECK(FireStop());
    CHECK_EQ(Get64(g_fire.deadline), 1100000);
}

/* The recorded broad Gatling sweep (613 observations, two sentries): every round more than 12 degrees off a live target
 * and every machine gun round after a target loss is gated; nearby changes keep firing. The Lua: 26, 39 and 3 rounds. */
static void RecordedSweepsAreGated(void)
{
    int broad = 0, blocked = 0, mg_shots = 0, mg_allowed = 0, lost_shots = 0, lost_blocked = 0, count = 0;
    const FiringRow* rows = FiringSweeps(&count);
    for (uint32_t id = 1; id <= 2; id++)
    {
        fake_setup();
        SarRow* s = NULL;
        for (int i = 0; i < count; i++)
        {
            const FiringRow* row = &rows[i];
            if (row->id != id) continue;
            if (s == NULL) s = row->machine_gun ? FireFixture(14, 3) : FireFixture(16, 4);
            s->target = row->target;
            s->runtime_target = row->runtime_target;
            s->fire.trigger = row->trigger == 1;
            s->has = row->has == 1;
            s->source_flags = row->flags;
            s->enabled = row->enabled == 1;
            Vec(s->computed, row->aim[0], row->aim[1], row->aim[2]);
            memcpy(s->fire.pose, row->pose, 64);
            s->fire.has_pose = 1;
            s->fire.mode = Get32(g_fire.mode);
            CHECK(sar_fire_step(&s, 1, row->t, &g_why));
            double forward[3], angle = 0;
            CHECK(sar_fire_geometry(s, forward, &angle, &g_why));
            int closed = Get32(g_fire.mode) == 0;
            if (row->rounds > 0 && s->target != 0 && angle > 12) { broad += (int)row->rounds; if (closed) blocked += (int)row->rounds; }
            if (!row->machine_gun) continue;
            mg_shots += (int)row->rounds;
            if (!closed) mg_allowed += (int)row->rounds;
            if (s->target == 0) { lost_shots += (int)row->rounds; if (closed) lost_blocked += (int)row->rounds; }
        }
    }
    printf("  replay: %d broad-sweep rounds gated; %d MG target-loss rounds gated; %d MG rounds retained\n", blocked, lost_blocked,
        mg_allowed);
    CHECK(broad >= 8 && blocked == broad);
    CHECK(mg_shots > 20 && mg_allowed > 0 && lost_shots > 20 && lost_blocked == lost_shots);
    CHECK_EQ(blocked, 26);
    CHECK_EQ(lost_blocked, 39);
    CHECK_EQ(mg_allowed, 3);
}

/* ---- test_windows_api.lua: the terrain query, the collision filter and the pose path ----------------------------- */

static uint8_t g_origin[12], g_target[12];
static SarCast Cast(SarRaycastFn raycast, float tx, float ty, float tz, int has_target_unit, uint32_t target_unit,
    int (*filter)(uint32_t, uint32_t, uint32_t*))
{
    Vec(g_target, tx, ty, tz);
    return (SarCast){raycast, 2, 123, g_origin, g_target, has_target_unit, target_unit, filter};
}

static int FenceFilter(uint32_t actor, uint32_t unit, uint32_t* filter)
{
    if (actor == 200 || actor == 201) { *filter = 0x04A8FBF9u; return 1; }
    if (actor == 300) { *filter = 0xA0D00A12u; return 1; }
    return 0;
}
static int UnknownFilter(uint32_t actor, uint32_t unit, uint32_t* filter) { return 0; }

static void Hit(int k, float distance, uint32_t unit, uint32_t actor) { g_scene.hit[k] = (SceneHit){distance, unit, actor, 0}; }

/* The live fence: a static body in the destructible filter, 11.286 m along a 29.736 m ray, is no proof of a blocked
 * shot; terrain behind it, a solid body of the same unit and a truncated result are handled. */
static void FencesPermitFiring(void)
{
    SarHit hit;
    const char* why = "";
    ResetFakes();
    Vec(g_origin, 0, 0, 2);
    g_scene.count = 2;
    Hit(0, 11.286f, 500, 200);
    Hit(1, 14, 501, 201);
    SarCast cast = Cast(SceneRaycast, 0, 29.736f, 2, 1, 456, FenceFilter);
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 0 && hit.reason == SAR_HIT_DESTRUCTIBLE_COVER && g_calls.raycast == 2);
    CHECK(g_scene.actors == 3 && g_scene.filter == 0x393D9518u && g_scene.flags == 0x80000009u && g_scene.ignore == 123);
    CHECK(g_scene.collection == 2 && g_scene.capacity == 32);
    g_scene.count = 3;
    Hit(2, 25, 500, 300); /* a solid body in the same unit as the fence */
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 1 && hit.distance == 25 && hit.reason == SAR_HIT_STATIC_OBSTRUCTION);
    g_scene.hit[2].distance = 5; /* solid cover in front of the fence: the closest query alone */
    g_calls.raycast = 0;
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 1 && g_calls.raycast == 1);
    g_scene.count = 2;
    cast.filter = UnknownFilter; /* unknown or recycled actors get no cover exemption */
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 1);
    cast.filter = FenceFilter;
    g_scene.count = 33;
    for (int i = 0; i < 33; i++) Hit(i, (float)(i + 1) * .5f, 500, 200);
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 0 && hit.reason == SAR_HIT_COVER_QUERY_LIMIT && hit.hits == 33);
}

/* A plane at z = 0: living crawlers above it are reachable even with a downward barrel. */
static int g_plane_calls;
static uint32_t PlaneRaycast(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, void* out, uint32_t capacity)
{
    const float* f = from;
    const float* d = direction;
    g_plane_calls++;
    CHECK(world == 2 && collection == 1 && actors == 3 && filter == 0x393D9518u && flags == 0x80000009u);
    CHECK(ignore == 123 && capacity == 1);
    CHECK(fabs((double)d[0] * d[0] + (double)d[1] * d[1] + (double)d[2] * d[2] - 1) < 0.00001);
    double distance = -(double)f[2] / d[2];
    if (d[2] >= 0 || distance < 0 || distance > length) return 0;
    PutF((uint32_t*)out + 6, (float)distance);
    return 1;
}

static uint32_t NanRaycast(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, void* out, uint32_t capacity)
{
    PutF((uint32_t*)out + 6, NAN);
    return 1;
}

/* An enemy's collision surface in front of its aim node. */
static uint32_t BodyRaycast(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, void* out, uint32_t capacity)
{
    PutF((uint32_t*)out + 6, length - 0.5f);
    ((uint32_t*)out)[7] = 456;
    return 1;
}

static void PlaneTerrain(void)
{
    SarHit hit;
    const char* why = "";
    static const float distances[] = {2, 20, 80};
    Vec(g_origin, 0, 0, 1.5f);
    for (int k = 0; k < 3; k++)
    {
        SarCast above = Cast(PlaneRaycast, 0, distances[k], .2f, 0, 0, NULL);
        CHECK(sar_cast_terrain(&above, &hit, &why) == 0);
        SarCast buried = Cast(PlaneRaycast, 0, distances[k], -.8f, 0, 0, NULL);
        CHECK(sar_cast_terrain(&buried, &hit, &why) == 1);
        SarCast surface = Cast(PlaneRaycast, 0, distances[k], 0, 0, 0, NULL);
        CHECK(sar_cast_terrain(&surface, &hit, &why) == 0);
    }
    SarCast high = Cast(PlaneRaycast, 0, 20, 4, 0, 0, NULL);
    CHECK(sar_cast_terrain(&high, &hit, &why) == 0);
    int before = g_plane_calls;
    SarCast invalid = Cast(PlaneRaycast, 0, 20, NAN, 0, 0, NULL);
    CHECK(sar_cast_terrain(&invalid, &hit, &why) < 0 && strcmp(why, "Invalid terrain ray") == 0);
    SarCast distant = Cast(PlaneRaycast, 0, 3000, 0, 0, 0, NULL);
    CHECK(sar_cast_terrain(&distant, &hit, &why) < 0 && strcmp(why, "Terrain ray outside sentry range") == 0);
    CHECK_EQ(g_plane_calls, before);
    SarCast nan = Cast(NanRaycast, 0, 20, -1, 0, 0, NULL);
    CHECK(sar_cast_terrain(&nan, &hit, &why) < 0 && strcmp(why, "Invalid terrain hit") == 0);
    SarCast body = Cast(BodyRaycast, 0, 20, .2f, 1, 456, NULL);
    CHECK(sar_cast_terrain(&body, &hit, &why) == 0 && hit.reason == SAR_HIT_TARGET_SURFACE && hit.hit_unit == 456);
    body.target_unit = 789;
    CHECK(sar_cast_terrain(&body, &hit, &why) == 1 && hit.reason == SAR_HIT_STATIC_OBSTRUCTION);
    SarCast buried = Cast(PlaneRaycast, 0, 20, -.8f, 1, 456, NULL);
    CHECK(sar_cast_terrain(&buried, &hit, &why) == 1 && hit.hit_unit == 0);
    SarCast none = Cast(PlaneRaycast, 0, 0, 1.52f, 0, 0, NULL);
    CHECK(sar_cast_terrain(&none, &hit, &why) == 0 && hit.reason == SAR_UNKNOWN); /* within 5 cm: no query */
}

/* Captured blockers were non-static character and ragdoll bodies; the native actor class 3 admits static bodies only. */
static struct { int count; SceneHit hit[8]; uint32_t actors; } g_static;
static uint32_t StaticRaycast(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, void* out, uint32_t capacity)
{
    const SceneHit* closest = NULL;
    uint32_t admit = g_static.actors ? g_static.actors : actors;
    for (int k = 0; k < g_static.count; k++)
    {
        const SceneHit* h = &g_static.hit[k];
        int admitted = admit == 5 || (admit == 3 && h->flags % 2 == 1);
        if (admitted && h->distance <= length && (closest == NULL || h->distance < closest->distance)) closest = h;
    }
    if (closest == NULL) return 0;
    PutF((uint32_t*)out + 6, closest->distance);
    ((uint32_t*)out)[7] = closest->unit;
    return 1;
}

static void NonStaticBlockersCannotVeto(void)
{
    SarHit hit;
    const char* why = "";
    memset(&g_static, 0, sizeof g_static);
    Vec(g_origin, 0, 0, 2);
    g_static.count = 4;
    g_static.hit[0] = (SceneHit){0, 200, 0, 6};
    g_static.hit[1] = (SceneHit){6.342f, 201, 0, 14};
    g_static.hit[2] = (SceneHit){6.4f, 201, 0, 8322};
    g_static.hit[3] = (SceneHit){6.5f, 201, 0, 131330};
    SarCast cast = Cast(StaticRaycast, 0, 22.243f, 2, 1, 456, NULL);
    g_static.actors = 5; /* the previous query locked on the incidental body at the muzzle */
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 1);
    g_static.actors = 0;
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 0);
    g_static.hit[g_static.count++] = (SceneHit){10, 300, 0, 1};
    CHECK(sar_cast_terrain(&cast, &hit, &why) == 1 && hit.reason == SAR_HIT_STATIC_OBSTRUCTION && hit.distance == 10);
    SarCast endpoint = Cast(StaticRaycast, 0, 10, 2, 1, 456, NULL); /* a target node at the static surface: the endpoint */
    CHECK(sar_cast_terrain(&endpoint, &hit, &why) == 0);
}

/* The actor's pool, body and filter name table, with synthetic addresses and remapped handles. */
static void ActorFilterFollowsOwnership(void)
{
    const uint32_t actor = 0x80020001u, unit = 0x40000Au;
    uint32_t filter = 0;
    uint8_t* pool = Exe(0x2369B00 + 64 * 20);
    uint8_t* entries = Block(56 * 2 + 64);
    Ptr(pool, entries);
    Put32(pool + 28, 56);
    Put32(pool + 36, 2);
    Put32(pool + 40, 0x1FFFF);
    Put32(pool + 52, 0x20000);
    uint8_t* entry = entries + 56;
    Put32(entry, actor);
    Put32(entry + 12, unit);
    Put32(entry + 20, 1);
    uint8_t* world = Block(32);
    uint8_t* bodies = Block(320);
    Ptr(Exe(0x27BA8A8 + 176 * 2), world);
    Ptr(world + 24, bodies);
    uint8_t* body = bodies + 160;
    Put32(body + 68, 1);
    Put32(body + 108, 14);
    Put32(body + 144, actor);
    Put32(body + 148, unit);
    uint8_t* properties = Block(264);
    uint8_t* names = Block(4 * 128);
    Ptr(Exe(0x27C5E48), properties);
    Put32(properties + 248, 103);
    Ptr(properties + 256, names);
    Put32(names + 4 * 14, 0x04A8FBF9u);
    Put32(names + 4 * 55, 0xA0D00A12u);
    CHECK(sar_actor_filter(actor, unit, &filter) && filter == 0x04A8FBF9u);
    Put32(body + 108, 55);
    CHECK(sar_actor_filter(actor, unit, &filter) && filter == 0xA0D00A12u);
    Put32(body + 108, 14);
    CHECK(!sar_actor_filter(actor, unit + 1, &filter));
    Put32(entry, actor + 1);
    CHECK(!sar_actor_filter(actor, unit, &filter));
    Put32(entry, actor);
    Put32(body + 144, actor + 1);
    CHECK(!sar_actor_filter(actor, unit, &filter));
    Put32(body + 144, actor);
    Put32(properties + 248, 14);
    CHECK(!sar_actor_filter(actor, unit, &filter));
    Put32(properties + 248, 103);
    CHECK(sar_actor_filter(actor, unit, &filter));
}

/* The muzzle pose's identity and bounds; the pose code is checked when a unit's path is located. */
static void PosePathIdentity(void)
{
    const uint32_t unit = 0x400001u; /* index 1, generation 1 */
    static const uint8_t code[5] = {0x48, 0x8D, 0x41, 0x60, 0xC3};
    uint8_t matrix[64], expected[64], other[64];
    const char* why = "";
    Started();
    memset(expected, 'm', 64);
    memset(other, 'n', 64);
    uint8_t* units = Block(0xA8);
    Ptr(Exe(0x1A100F0), units);
    Put32(units + 0x98, 2);
    uint8_t* generations = Block(8);
    Ptr(units + 0xA0, generations);
    generations[1] = 1;
    uint8_t* slots = Block(16);
    Ptr(units + 0x88, slots);
    uint8_t* object = Block(0x90);
    Ptr(slots + 8, object);
    Put32(object + 8, unit);
    Put32(object + 0x70, 2);
    uint8_t* vtable = Block(0xF0);
    Ptr(object, vtable);
    uint8_t* bytes = Block(8);
    Ptr(vtable + 0xE8, bytes);
    memcpy(bytes, code, 5);
    uint8_t* matrices = Block(128);
    Ptr(object + 0x88, matrices);
    memcpy(matrices + 64, expected, 64);
    CHECK(sar_pose(unit, 1, matrix, &why) == 1 && memcmp(matrix, expected, 64) == 0);
    CHECK(sar_pose(unit, 2, matrix, &why) < 0 && strcmp(why, "Fire node unavailable") == 0);
    generations[1] = 2;
    CHECK(sar_pose(unit, 1, matrix, &why) < 0);
    generations[1] = 1;
    Put32(object + 8, unit + 1);
    CHECK(sar_pose(unit, 1, matrix, &why) < 0);
    Put32(object + 8, unit);
    CHECK(sar_pose(unit, 1, matrix, &why) == 1);
    bytes[0] = 0x90; /* a path already kept keeps its check; a new path is refused */
    CHECK(sar_pose(unit, 1, matrix, &why) == 1 && memcmp(matrix, expected, 64) == 0);
    sar_pose_forget();
    CHECK(sar_pose(unit, 1, matrix, &why) < 0 && strcmp(why, "Unsupported pose layout") == 0);
    bytes[0] = 0x48;
    /* A kept path is followed again when the unit's slot names another object. */
    uint8_t* object2 = Block(0x90);
    uint8_t* matrices2 = Block(128);
    Ptr(slots + 8, object2);
    Put32(object2 + 8, unit);
    Put32(object2 + 0x70, 2);
    Ptr(object2, vtable);
    Ptr(object2 + 0x88, matrices2);
    memcpy(matrices2 + 64, other, 64);
    CHECK(sar_pose(unit, 1, matrix, &why) == 1 && memcmp(matrix, other, 64) == 0);
    Ptr(slots + 8, object);
    CHECK(sar_pose(unit, 1, matrix, &why) == 1 && memcmp(matrix, expected, 64) == 0);
}

/* Pending queries and each of the 24 busy workers prevent a native cast. */
static void BusyWorkersPreventCasts(void)
{
    int blocked = 0;
    const char* why = "";
    uint8_t point[12] = {0};
    MakeWorld();
    Started();
    Put32(w.scheduler, 1);
    CHECK(sar_terrain_path(UNIT, point, point, 0, &blocked, &why) == 0);
    Put32(w.scheduler, 0);
    for (int i = 0; i < 24; i++)
    {
        Put32(w.scheduler + 0x40008 + 12 * i + 8, 0);
        CHECK(sar_terrain_path(UNIT, point, point, 0, &blocked, &why) == 0);
        Put32(w.scheduler + 0x40008 + 12 * i + 8, 1);
    }
    CHECK_EQ(g_calls.raycast, 0);
    Vec(point + 0, 0, 0, 0);
    uint8_t target[12];
    Vec(target, 0, 10, 0);
    CHECK(sar_terrain_path(UNIT, point, target, 0, &blocked, &why) == 1 && blocked == 0 && g_calls.raycast == 1);
}

/* ---- main -------------------------------------------------------------------------------------------------------- */

/* A hold refused, said once per record: a native disable bit is set when the target is lost. */
static void ARefusedHoldIsSaidOnce(void)
{
    AimStarted();
    Diagnostics(1);
    SarRow* s = NewSentry(0, 1, Block(128));
    AimStep1(s);
    s->target = 0;
    s->flags = 16;
    Put32((void*)s->flags_address, 16);
    for (int i = 0; i < 3; i++) CHECK(AimStep1(s));
    CHECK_EQ(sar_state.holds, 0);
    CHECK_EQ(fake_log_count(" sentry 1 lost its target on node "), 1);
    CHECK_LOG(": no hold, a native disable bit is set (flags 10)");
}

int main(void)
{
    RUN(DecodesTheFixture);
    RUN(QueriesTheTerrainFromTheMuzzle);
    RUN(TargetRemovalKeepsTheFireRestore);
    RUN(RefusesWhatIsNotAsReviewed);
    RUN(BindsOnlyTheReviewedCode);
    RUN(BindsTheGamesFunctionsOnce);
    RUN(ClassifiesOncePerPointer);
    RUN(WaitsOnTheShipAndInAMission);
    RUN(HoldsAndPausesOnceATargetIsLost);
    RUN(WaitsOnTheShipAndInAMissionDetailed);
    RUN(HoldsAndPausesOnceATargetIsLostDetailed);
    RUN(DetailedModeSaysWhatTheSentriesDid);
    RUN(NormalModeLogsNoneOfThem);
    RUN(ARefusedHoldIsSaidOnce);
    RUN(ManyLinesAreLimited);
    RUN(TheMarkCarriesItsState);
    RUN(UndoesAFailedHold);
    RUN(FollowsMovedArrays);
    RUN(TargetLostInsideTheUpdate);
    RUN(ReacquiredThenLostInTheUpdate);
    RUN(IdleFramesHaveNoPostCheck);
    RUN(PostCheckStops);
    RUN(AFaultInThePostCheck);
    RUN(ARefusedPostTickChecksAtOnce);
    RUN(ARefusalAfterARegistrationWorked);
    RUN(ErrorBurstsOnTheRefusedBranch);
    RUN(CodeChecksWaitForTheFirstSentry);
    RUN(StopsAfterEightErrorsInABurst);
    RUN(StopsAtOnceWhenARestoreFails);
    RUN(LossHoldsAimAndScanReleases);
    RUN(NewTargetReleasesAtOnce);
    RUN(IndependentSentriesAndCleanStop);
    RUN(NativeDisableMasksAreLeftAlone);
    RUN(SetterFailureRestoresWhatWasAcquired);
    RUN(RefusedMemoryAndChangedIdentityWriteNothing);
    RUN(OneFailedRollbackLeavesTheOthers);
    RUN(RollbackQueriesOnlyOutsideTheCheckedRange);
    RUN(CompactionKeepsTheSavedSpeeds);
    RUN(MapReplacementCannotOrphanAHold);
    RUN(NativeSpeedChangesArePreserved);
    RUN(AnotherDisableBitEndsTheHold);
    RUN(RepeatedCyclesLeaveNoStaleWrites);
    RUN(RecordedLossesHoldAndRelease);
    RUN(AngularLimitsMatchTheProfiles);
    RUN(NearbyTargetChangesKeepFiring);
    RUN(CloseReplacementReopensAtOnce);
    RUN(HandoffNeedsSynchronizedAimAndAFreshQuery);
    RUN(StaleAimCannotFireAtAnotherTarget);
    RUN(WideTurnOrObstructionCancelsTheHandoff);
    RUN(PausedTimeIsNotASweep);
    RUN(BroadPauseIsNoHandoff);
    RUN(BroadSweepsPauseWithHysteresis);
    RUN(UnsettledSweepsAreBounded);
    RUN(TrackingKeepsFiringLossStopsTheBurst);
    RUN(TerrainBlocksABuriedAim);
    RUN(BlockedStateStaysWithItsTarget);
    RUN(ScanningAfterTheTriggerReleases);
    RUN(PausedLossWaitsForTheTrigger);
    RUN(OwnershipOfTheFireMode);
    RUN(RelocatedLeasesAndStaleEntities);
    RUN(InvalidMuzzleFailsFirst);
    RUN(LossShortensTheSearchOnce);
    RUN(InvalidTargetsCannotForceSearchesEveryFrame);
    RUN(RequestsNeedALossOnTheFiringNode);
    RUN(StopRestoresAnUnconsumedRequest);
    RUN(RequestsRefuseChangedGuardsAndMemory);
    RUN(RequestFollowsRelocatedMemory);
    RUN(RecordedSweepsAreGated);
    RUN(FencesPermitFiring);
    RUN(PlaneTerrain);
    RUN(NonStaticBlockersCannotVeto);
    RUN(ActorFilterFollowsOwnership);
    RUN(PosePathIdentity);
    RUN(BusyWorkersPreventCasts);
    TEST_END();
}

/* ---- the recorded replays (generated from the Lua fixtures) ------------------------------------------------------ */

/* gatling_target_loss.lua: time, node, target, runtime target, source flags, has target, point, raw, computed
 * (182 samples). */
static const LossRow kGatlingLoss[] = {
    {0.0000, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-135.90018f, -114.06993f, 1.5484955f}, {-135.90018f, -114.06993f, 1.5484955f}},
    {0.1720, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {0.3856, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {0.5993, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {0.8135, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {1.0271, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {1.2418, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {1.4570, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {1.6721, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {1.8845, 1, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {2.0137, 7, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {2.0349, 4, 100, 0, 3, 1, {-175.06514f, -153.57457f, 0.0072021484f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {2.0561, 5, 100, 0, 3, 1, {-175.01743f, -153.54022f, 0.0072021484f}, {-116.271194f, -111.56612f, 1.5481129f}, {-116.271194f, -111.56612f, 1.5481129f}},
    {2.0779, 5, 100, 100, 3, 1, {-174.94592f, -153.48874f, 0.0072021484f}, {-174.99559f, -153.567f, 0.7572382f}, {-174.99559f, -153.567f, 0.7572382f}},
    {2.0989, 5, 100, 100, 3, 1, {-174.89857f, -153.45465f, 0.0072021484f}, {-174.94641f, -153.53554f, 0.7552837f}, {-174.94641f, -153.53554f, 0.7552837f}},
    {2.3123, 5, 100, 100, 3, 1, {-174.3798f, -153.0813f, 0.0072021484f}, {-174.40186f, -153.20386f, 0.754563f}, {-174.40186f, -153.20386f, 0.754563f}},
    {2.5262, 5, 100, 100, 3, 1, {-173.83363f, -152.68823f, 0.008575439f}, {-173.88481f, -152.77763f, 0.7555935f}, {-173.88481f, -152.77763f, 0.7555935f}},
    {2.7434, 5, 100, 100, 3, 1, {-173.30911f, -152.31122f, 0.03277588f}, {-173.34792f, -152.46658f, 0.7737439f}, {-173.34792f, -152.46658f, 0.7737439f}},
    {2.9577, 5, 100, 100, 3, 1, {-172.77174f, -151.9274f, 0.10751343f}, {-172.83928f, -152.08282f, 0.842336f}, {-172.83928f, -152.08282f, 0.842336f}},
    {3.0652, 12, 100, 100, 3, 1, {-172.50905f, -151.74078f, 0.12991333f}, {-172.53084f, -151.93057f, 0.8766337f}, {-172.53084f, -151.93057f, 0.8766337f}},
    {3.1734, 12, 100, 100, 3, 1, {-172.24971f, -151.5558f, 0.13708496f}, {-172.24945f, -151.73405f, 0.87491465f}, {-172.24945f, -151.73405f, 0.87491465f}},
    {3.3868, 12, 100, 100, 3, 1, {-171.72188f, -151.17455f, 0.04763794f}, {-171.72646f, -151.24197f, 0.7999535f}, {-171.72646f, -151.24197f, 0.7999535f}},
    {3.6011, 12, 100, 100, 3, 1, {-171.19095f, -150.79248f, 0.020874023f}, {-171.24916f, -150.83786f, 0.77554315f}, {-171.24893f, -150.83813f, 0.7758607f}},
    {3.6648, 12, 0, 100, 32, 1, {-171.05104f, -150.69331f, 0.03439331f}, {-171.10835f, -150.66965f, 0.78880805f}, {-171.11229f, -150.665f, 0.78987104f}},
    {3.8145, 12, 0, 100, 32, 1, {-171.05104f, -150.69331f, 0.03439331f}, {-171.05104f, -150.69331f, 0.03439331f}, {-171.05261f, -150.69156f, 0.03736186f}},
    {4.0287, 12, 0, 100, 32, 1, {-171.05104f, -150.69331f, 0.03439331f}, {-171.05104f, -150.69331f, 0.03439331f}, {-171.0522f, -150.69196f, 0.034986734f}},
    {4.0930, 12, 101, 101, 3, 1, {-176.1204f, -152.81549f, 0.09998405f}, {-176.0193f, -152.807f, 1.2457502f}, {-176.0189f, -152.80751f, 1.2467012f}},
    {4.2422, 12, 101, 101, 3, 1, {-175.82474f, -152.6083f, 0.035858154f}, {-175.77773f, -152.53932f, 1.1487013f}, {-175.77438f, -152.5435f, 1.1478288f}},
    {4.4569, 12, 101, 101, 3, 1, {-175.3787f, -152.30283f, 0.05102539f}, {-175.33495f, -152.3356f, 1.1858921f}, {-175.33733f, -152.33263f, 1.1856964f}},
    {4.6729, 12, 101, 101, 3, 1, {-175.00085f, -152.10544f, 0.06454468f}, {-174.91899f, -152.29663f, 1.0204794f}, {-174.9204f, -152.29492f, 1.022598f}},
    {4.8885, 12, 101, 101, 3, 1, {-174.3625f, -151.81659f, 0.080718994f}, {-174.26353f, -151.95198f, 1.0162232f}, {-174.264f, -151.95139f, 1.0159335f}},
    {5.1023, 12, 101, 101, 3, 1, {-173.93434f, -151.69261f, 0.08224487f}, {-173.99074f, -151.83452f, 0.98595536f}, {-173.99129f, -151.83385f, 0.98665243f}},
    {5.3200, 12, 101, 101, 3, 1, {-173.17548f, -151.37221f, 0.15411377f}, {-173.13664f, -151.43237f, 1.1553533f}, {-173.1373f, -151.43158f, 1.1535865f}},
    {5.5345, 12, 101, 101, 3, 1, {-172.09836f, -150.82462f, 0.06692505f}, {-172.05351f, -150.75607f, 1.2878745f}, {-172.0475f, -150.76335f, 1.2875712f}},
    {5.6193, 12, 0, 101, 32, 1, {-171.994f, -150.75925f, -0.1431421f}, {-171.91055f, -150.69331f, 1.2610799f}, {-171.91446f, -150.6886f, 1.2617358f}},
    {5.7476, 12, 0, 101, 32, 1, {-171.994f, -150.75925f, -0.1431421f}, {-171.994f, -150.75925f, -0.1431421f}, {-171.9969f, -150.75601f, -0.13740635f}},
    {5.9632, 12, 0, 101, 32, 1, {-171.994f, -150.75925f, -0.1431421f}, {-171.994f, -150.75925f, -0.1431421f}, {-171.99683f, -150.75584f, -0.14305508f}},
    {6.0916, 12, 102, 101, 3, 1, {-173.83293f, -153.49202f, 0.0072021484f}, {-171.994f, -150.75925f, -0.1431421f}, {-171.9903f, -150.76373f, -0.14338863f}},
    {6.1127, 12, 102, 102, 3, 1, {-173.8192f, -153.5213f, 0.0072021484f}, {-173.69131f, -153.63225f, 1.241392f}, {-173.68677f, -153.63754f, 1.2412832f}},
    {6.1774, 12, 102, 102, 3, 1, {-173.77014f, -153.62708f, 0.0072021484f}, {-173.6086f, -153.7767f, 1.2745143f}, {-173.61273f, -153.7718f, 1.2594343f}},
    {6.3918, 12, 102, 102, 3, 1, {-174.35396f, -154.06395f, 0.0072021484f}, {-174.74608f, -154.28278f, 1.2334887f}, {-174.74306f, -154.28633f, 1.2335964f}},
    {6.4131, 12, 0, 102, 32, 1, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.77415f, -154.3386f, 1.2001375f}, {-174.77141f, -154.34183f, 1.201255f}},
    {6.6067, 12, 0, 102, 32, 1, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.39764f, -154.11403f, 0.008322954f}},
    {6.8206, 12, 0, 102, 32, 1, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.39606f, -154.11583f, 0.0069818497f}},
    {7.0362, 12, 0, 102, 32, 1, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.3971f, -154.11462f, 0.0072021484f}, {-174.39928f, -154.11208f, 0.007272005f}},
    {7.1005, 12, 103, 103, 3, 1, {-178.07422f, -157.09445f, 0.2609558f}, {-178.02815f, -157.38094f, 0.96611124f}, {-178.0256f, -157.38391f, 0.96626633f}},
    {7.2514, 12, 103, 103, 3, 1, {-177.67986f, -156.85852f, 0.22268677f}, {-177.58675f, -157.07509f, 0.9473364f}, {-177.58957f, -157.07178f, 0.9450414f}},
    {7.4667, 12, 103, 103, 3, 1, {-177.13199f, -156.51993f, 0.114593506f}, {-177.01544f, -156.71681f, 0.8429749f}, {-177.01859f, -156.71317f, 0.8426551f}},
    {7.6799, 12, 0, 103, 32, 1, {-176.6355f, -156.21748f, 0.07110596f}, {-176.6355f, -156.21748f, 0.07110596f}, {-176.63411f, -156.21909f, 0.0706079f}},
    {7.8950, 12, 0, 103, 32, 1, {-176.6355f, -156.21748f, 0.07110596f}, {-176.6355f, -156.21748f, 0.07110596f}, {-176.63416f, -156.21906f, 0.07120621f}},
    {8.1083, 12, 104, 104, 3, 1, {-179.77931f, -155.94891f, 0.2260437f}, {-179.76822f, -155.845f, 1.3228025f}, {-179.7731f, -155.8389f, 1.3229355f}},
    {8.3227, 12, 104, 104, 3, 1, {-179.35323f, -155.68167f, 0.14995313f}, {-179.35818f, -155.72592f, 1.2873524f}, {-179.36514f, -155.71729f, 1.2877086f}},
    {8.4087, 12, 0, 104, 32, 1, {-179.58786f, -155.82825f, 0.1932373f}, {-179.68257f, -155.84894f, 1.5470148f}, {-179.67941f, -155.85287f, 1.543957f}},
    {8.5379, 12, 0, 104, 32, 1, {-179.58786f, -155.82825f, 0.1932373f}, {-179.58786f, -155.82825f, 0.1932373f}, {-179.5903f, -155.8254f, 0.19846165f}},
    {8.7516, 12, 0, 104, 32, 1, {-179.58786f, -155.82825f, 0.1932373f}, {-179.58786f, -155.82825f, 0.1932373f}, {-179.58292f, -155.83441f, 0.19336736f}},
    {8.9655, 12, 0, 104, 32, 1, {-179.58786f, -155.82825f, 0.1932373f}, {-179.58786f, -155.82825f, 0.1932373f}, {-179.59015f, -155.82541f, 0.19291079f}},
    {9.1164, 12, 105, 105, 3, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.51895f, -110.31399f, 1.0118845f}, {-105.518555f, -110.316605f, 1.0119997f}},
    {9.1796, 12, 105, 105, 3, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.51903f, -110.31004f, 1.0091425f}, {-105.529236f, -110.24434f, 1.0078366f}},
    {9.3936, 12, 105, 105, 3, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.5262f, -110.2956f, 1.0013356f}, {-105.531044f, -110.26825f, 0.9993104f}},
    {9.6093, 12, 105, 105, 3, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.52694f, -110.289825f, 0.99771816f}, {-105.52343f, -110.3099f, 0.9955728f}},
    {9.8219, 12, 105, 105, 3, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.51952f, -110.295074f, 0.99948806f}, {-105.51029f, -110.35299f, 0.99807143f}},
    {10.0371, 12, 105, 105, 3, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.50978f, -110.30756f, 1.0040753f}, {-105.50019f, -110.38253f, 1.0041063f}},
    {10.1010, 12, 0, 105, 32, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.555145f, -110.375755f, 1.0053256f}, {-105.554115f, -110.38434f, 1.0054996f}},
    {10.2536, 12, 0, 105, 32, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.554f, -110.38084f, 0.007232666f}, {-105.553604f, -110.38224f, 0.010235548f}},
    {10.4692, 12, 0, 105, 32, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.554f, -110.38084f, 0.007232666f}, {-105.5538f, -110.3825f, 0.007254839f}},
    {10.6855, 12, 0, 105, 32, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.554f, -110.38084f, 0.007232666f}, {-105.55412f, -110.37972f, 0.007313609f}},
    {10.9000, 12, 0, 105, 32, 1, {-105.554f, -110.38084f, 0.007232666f}, {-105.554f, -110.38084f, 0.007232666f}, {-105.553925f, -110.38145f, 0.0073002577f}},
    {11.1149, 5, 0, 105, 0, 0, {0.0f, 0.0f, 0.0f}, {-105.554f, -110.38084f, 0.007232666f}, {-105.554f, -110.38084f, 0.007232666f}},
    {11.1359, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {-116.27198f, -111.56135f, 1.5481129f}, {-116.27198f, -111.56135f, 1.5481129f}},
    {11.3290, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {11.5428, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {11.7568, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {11.9722, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {12.1861, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {12.3989, 4, 106, 0, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {12.4209, 5, 106, 106, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.205734f, -110.48435f, 0.9990582f}, {-106.205734f, -110.48435f, 0.9990582f}},
    {12.6140, 5, 106, 106, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.205956f, -110.48187f, 0.9978933f}, {-106.205956f, -110.48187f, 0.9978933f}},
    {12.8282, 5, 106, 106, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.205505f, -110.48694f, 1.000438f}, {-106.205505f, -110.48694f, 1.000438f}},
    {12.9140, 12, 106, 106, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.20514f, -110.49125f, 1.0025198f}, {-106.20514f, -110.49125f, 1.0025198f}},
    {13.0411, 12, 106, 106, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.20462f, -110.49807f, 1.005952f}, {-106.20462f, -110.49807f, 1.005952f}},
    {13.2542, 12, 106, 106, 3, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.33894f, -110.52999f, 0.63970804f}, {-106.33894f, -110.52999f, 0.63970804f}},
    {13.4701, 12, 0, 106, 32, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.39317f, -110.552986f, 0.64571315f}, {-106.392944f, -110.555f, 0.64562297f}},
    {13.6840, 12, 0, 106, 32, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26102f, -110.55903f, 0.007232666f}, {-106.261024f, -110.55874f, 0.007555723f}},
    {13.8968, 12, 0, 106, 32, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26111f, -110.55827f, 0.0071748495f}},
    {14.1110, 12, 0, 106, 32, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26097f, -110.559555f, 0.0071234703f}},
    {14.3236, 12, 0, 106, 32, 1, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26111f, -110.55824f, 0.0071572065f}},
    {14.4937, 5, 0, 106, 0, 0, {-103.1642f, -109.326515f, 0.007232666f}, {-106.26102f, -110.55903f, 0.007232666f}, {-106.26102f, -110.55903f, 0.007232666f}},
    {14.5149, 12, 107, 107, 3, 1, {-103.03308f, -109.51286f, 0.007232666f}, {-102.98461f, -109.43684f, 0.75269383f}, {-102.98461f, -109.43684f, 0.75269383f}},
    {14.5359, 12, 107, 107, 3, 1, {-103.009605f, -109.53768f, 0.007232666f}, {-102.96766f, -109.45812f, 0.75321096f}, {-102.9677f, -109.469734f, 0.70208246f}},
    {14.6200, 12, 0, 107, 32, 1, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90952f, -109.62479f, 0.003951788f}},
    {14.7477, 12, 0, 107, 32, 1, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90952f, -109.62204f, 0.009418488f}},
    {14.9611, 12, 0, 107, 32, 1, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90965f, -109.62216f, 0.0072495937f}},
    {15.1776, 12, 0, 107, 32, 1, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90951f, -109.62316f, 0.0074049234f}},
    {15.3904, 12, 0, 107, 32, 1, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.9098f, -109.62116f, 0.0071965456f}},
    {15.6026, 12, 0, 107, 32, 1, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.909805f, -109.6211f, 0.007254839f}},
    {15.6235, 5, 0, 107, 0, 0, {0.0f, 0.0f, 0.0f}, {-102.90943f, -109.62379f, 0.007232666f}, {-102.90943f, -109.62379f, 0.007232666f}},
    {15.6447, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {-116.2721f, -111.56049f, 1.5481129f}, {-116.2721f, -111.56049f, 1.5481129f}},
    {15.8172, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {16.0317, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {16.2442, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {16.4584, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {16.6711, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {16.8819, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {17.0931, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {17.3041, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {17.5142, 3, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {17.6398, 6, 0, 0, 32, 1, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}},
    {17.6609, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {17.7238, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {17.9339, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {18.1445, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {18.3549, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {18.5649, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {18.7752, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {18.9854, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {19.1947, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {19.4043, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {19.6141, 3, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {19.6763, 6, 0, 0, 32, 1, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}, {6.2398834f, 19.001678f, 0.0f}},
    {19.6970, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {19.8225, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {20.0323, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {20.2407, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {20.4492, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {20.6568, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {20.8647, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {21.0735, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {21.2838, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {21.4932, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {21.7048, 3, 0, 0, 32, 1, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {21.7255, 8, 0, 0, 32, 1, {-26.417149f, -9.923738f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}, {3.5676432f, -10.879068f, 0.0f}},
    {21.7465, 3, 0, 0, 32, 1, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}},
    {21.9142, 3, 0, 0, 32, 1, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}},
    {22.1243, 3, 0, 0, 32, 1, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}},
    {22.3349, 3, 0, 0, 32, 1, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}},
    {22.5454, 3, 0, 0, 32, 1, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}},
    {22.6292, 2, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-26.417149f, -9.923738f, 0.0f}, {-26.417149f, -9.923738f, 0.0f}},
    {22.7554, 2, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {22.9650, 2, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {23.1740, 2, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {23.3838, 2, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {23.5940, 2, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {23.7832, 6, 0, 0, 32, 1, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}, {-116.166824f, -111.54645f, 1.9919739f}},
    {23.8041, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {24.0133, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {24.2223, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {24.4315, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {24.6417, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {24.8525, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {25.0632, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {25.2744, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {25.4845, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {25.6959, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {25.9057, 2, 0, 0, 32, 1, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}, {-100.25517f, -99.42954f, 1.9919739f}},
    {26.1170, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {26.3272, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {26.5376, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {26.7491, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {26.9593, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {27.1722, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {27.3895, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {27.6016, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {27.8127, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {28.0242, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {28.2350, 2, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {28.4248, 6, 0, 0, 32, 1, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}, {-111.787125f, -127.12456f, 1.9919739f}},
    {28.4455, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {28.6566, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {28.8661, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {29.0770, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {29.2868, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {29.4975, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {29.7063, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {29.9163, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {30.1270, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {30.3382, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {30.5498, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {30.7612, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {30.9712, 2, 0, 0, 32, 1, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {31.0560, 9, 0, 0, 32, 1, {-112.76748f, -127.1938f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}, {-114.39096f, -97.23777f, 1.9919739f}},
    {31.0770, 2, 0, 0, 32, 1, {-112.76748f, -127.1938f, 1.9919739f}, {-112.76748f, -127.1938f, 1.9919739f}, {-112.76748f, -127.1938f, 1.9919739f}},
    {31.1819, 2, 0, 0, 32, 1, {-112.76748f, -127.1938f, 1.9919739f}, {-112.76748f, -127.1938f, 1.9919739f}, {-112.76748f, -127.1938f, 1.9919739f}},
};

/* firing_sweeps.lua: time, sentry, machine gun, target, runtime target, trigger, has target, flags, enabled,
 * relative aim, relative muzzle matrix, rounds fired (613 observations). */
static const FiringRow kFiringSweeps[] = {
    {0.0224, 1, 0, 100, 100, 0, 1, 3, 1, {7.7903595f, -5.5724716f, -0.7992957f}, {-0.5730023f, -0.81955385f, 7.2353636e-05f, 0.0f, 0.81746393f, -0.57154745f, -0.071320504f, 0.0f, 0.058492392f, -0.04080768f, 0.99745345f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.0458, 1, 0, 100, 100, 1, 1, 3, 1, {7.7667847f, -5.655716f, -0.7929802f}, {-0.5797267f, -0.81481105f, 7.0097856e-05f, 0.0f, 0.8127684f, -0.57827955f, -0.07071382f, 0.0f, 0.057658948f, -0.040937718f, 0.9974966f, 0.0f, -0.005411148f, -0.0077056885f, 0.0007606745f, 1.0f}, 1, 0},
    {0.0686, 1, 0, 100, 100, 1, 1, 3, 1, {7.744438f, -5.7440414f, -0.78809077f}, {-0.58546257f, -0.81069976f, 6.7721005e-05f, 0.0f, 0.8087038f, -0.5840271f, -0.07007909f, 0.0f, 0.056852736f, -0.04097391f, 0.9975414f, 0.0f, -0.010101318f, -0.014289856f, 0.0015565157f, 1.0f}, 1, 0},
    {0.0921, 1, 0, 100, 100, 1, 1, 3, 1, {7.725624f, -5.8360214f, -0.78565f}, {-0.5906795f, -0.80690634f, 6.546744e-05f, 0.0f, 0.80495316f, -0.58925533f, -0.06948912f, 0.0f, 0.056109823f, -0.040993076f, 0.9975827f, 0.0f, -0.014429092f, -0.020263672f, 0.0022963285f, 1.0f}, 0, 0},
    {0.1151, 1, 0, 100, 100, 1, 1, 3, 1, {7.7101593f, -5.929825f, -0.78691685f}, {-0.5977146f, -0.801709f, 6.339676e-05f, 0.0f, 0.7997987f, -0.5962959f, -0.06894535f, 0.0f, 0.055311996f, -0.041158948f, 0.99762046f, 0.0f, -0.020366669f, -0.028327942f, 0.0029780865f, 1.0f}, 1, 0},
    {0.1389, 1, 0, 100, 100, 1, 1, 3, 1, {7.7038345f, -6.0645676f, -0.8034526f}, {-0.6035622f, -0.79731625f, 6.315345e-05f, 0.0f, 0.79541963f, -0.602132f, -0.06888425f, 0.0f, 0.05496062f, -0.04152564f, 0.99762464f, 0.0f, -0.025398254f, -0.03501892f, 0.0030546188f, 1.0f}, 1, 0},
    {0.1618, 1, 0, 100, 100, 1, 1, 3, 1, {7.709854f, -6.15464f, -0.8226474f}, {-0.6094203f, -0.7928476f, 6.492017e-05f, 0.0f, 0.79093564f, -0.6079564f, -0.069355994f, 0.0f, 0.05502823f, -0.042215534f, 0.997592f, 0.0f, -0.030536652f, -0.04170227f, 0.0024632215f, 1.0f}, 0, 0},
    {0.1846, 1, 0, 100, 100, 1, 1, 3, 1, {7.7091675f, -6.2512817f, -0.83515567f}, {-0.61407584f, -0.78924716f, 6.802764e-05f, 0.0f, 0.787298f, -0.6125654f, -0.07018384f, 0.0f, 0.05543407f, -0.04304462f, 0.99753404f, 0.0f, -0.03468895f, -0.0470047f, 0.0014252663f, 1.0f}, 1, 0},
    {0.2075, 1, 0, 100, 100, 1, 1, 3, 1, {7.7067337f, -6.3544846f, -0.8414395f}, {-0.61907303f, -0.7853337f, 7.071067e-05f, 0.0f, 0.7833534f, -0.61751837f, -0.07091597f, 0.0f, 0.055736423f, -0.043846756f, 0.9974823f, 0.0f, -0.03919792f, -0.052703857f, 0.0005072355f, 1.0f}, 0, 0},
    {0.2306, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.2535, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.2774, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 0, 1},
    {0.3005, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.3232, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 0, 1},
    {0.3467, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.3702, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.3943, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 0, 1},
    {0.418, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.4412, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.4639, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 0, 1},
    {0.4868, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.5105, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 1},
    {0.5337, 1, 0, 0, 100, 1, 1, 32, 1, {7.7043686f, -6.3573f, -0.8420507f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 0, 1},
    {0.5568, 1, 0, 101, 101, 1, 1, 3, 1, {1.9478569f, 2.0074615f, -0.90421915f}, {-0.6261263f, -0.7797218f, 7.253862e-05f, 0.0f, 0.7777289f, -0.62453264f, -0.07139307f, 0.0f, 0.055712048f, -0.044644658f, 0.9974482f, 0.0f, -0.045646667f, -0.06075287f, -9.095669e-05f, 1.0f}, 1, 0},
    {0.581, 1, 0, 101, 101, 1, 1, 3, 1, {1.9676781f, 1.899353f, -0.90924037f}, {-0.57829326f, -0.8158291f, 7.491594e-05f, 0.0f, 0.8137073f, -0.57679594f, -0.07202223f, 0.0f, 0.05880103f, -0.041588984f, 0.997403f, 0.0f, -0.004293442f, -0.006034851f, -0.00087988377f, 1.0f}, 0, 0},
    {0.6044, 1, 0, 101, 101, 1, 1, 3, 1, {1.9906826f, 1.7334747f, -0.9167178f}, {-0.503908f, -0.8637575f, 7.8879646e-05f, 0.0f, 0.8614453f, -0.5025658f, -0.07307452f, 0.0f, 0.06315838f, -0.036754888f, 0.9973265f, 0.0f, 0.050596237f, 0.079063416f, -0.0021994114f, 1.0f}, 1, 0},
    {0.6284, 1, 0, 101, 101, 1, 1, 3, 1, {2.0026455f, 1.6247864f, -0.91429573f}, {-0.45223364f, -0.8918996f, 8.180889e-05f, 0.0f, 0.8894604f, -0.45100355f, -0.07386643f, 0.0f, 0.06591828f, -0.033332102f, 0.9972681f, 0.0f, 0.08282471f, 0.13819122f, -0.0031924248f, 1.0f}, 1, 0},
    {0.6519, 1, 0, 101, 101, 1, 1, 3, 1, {2.0115204f, 1.5163193f, -0.9134819f}, {-0.3987144f, -0.9170754f, 8.510507e-05f, 0.0f, 0.9145066f, -0.39760453f, -0.07475832f, 0.0f, 0.06859289f, -0.029729357f, 0.9972017f, 0.0f, 0.11165047f, 0.19942474f, -0.0043108463f, 1.0f}, 0, 0},
    {0.6757, 1, 0, 101, 101, 1, 1, 3, 1, {2.020918f, 1.407608f, -0.91218406f}, {-0.34324032f, -0.93924755f, 8.889148e-05f, 0.0f, 0.93654394f, -0.34225947f, -0.07578966f, 0.0f, 0.07121578f, -0.025930798f, 0.99712384f, 0.0f, 0.13703537f, 0.2629013f, -0.005604267f, 1.0f}, 1, 0},
    {0.699, 1, 0, 101, 101, 1, 1, 3, 1, {2.031416f, 1.2981567f, -0.91009885f}, {-0.28624907f, -0.9581555f, 9.3471375e-05f, 0.0f, 0.95530784f, -0.28540584f, -0.07701197f, 0.0f, 0.07381607f, -0.021955356f, 0.9970301f, 0.0f, 0.15867043f, 0.32810974f, -0.0071371794f, 1.0f}, 0, 0},
    {0.7224, 1, 0, 101, 101, 1, 1, 3, 1, {2.0419674f, 1.1887207f, -0.90717155f}, {-0.22836392f, -0.97357583f, 9.9031255e-05f, 0.0f, 0.97056943f, -0.22766674f, -0.07850453f, 0.0f, 0.07645268f, -0.017831484f, 0.99691373f, 0.0f, 0.17630196f, 0.39434814f, -0.009009004f, 1.0f}, 1, 0},
    {0.7224, 2, 1, 0, 0, 0, 1, 32, 1, {9.375069f, -5.294861f, 2.620438f}, {0.4909658f, 0.8711786f, -0.00018882705f, 0.0f, -0.8711784f, 0.4909654f, -0.0009770095f, 0.0f, -0.0007583721f, 0.0006442417f, 0.9999994f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.7466, 1, 0, 101, 101, 1, 1, 3, 1, {2.0590382f, 1.0309372f, -0.9025617f}, {-0.14041072f, -0.99009365f, 0.00011065067f, 0.0f, 0.986787f, -0.13995099f, -0.081644684f, 0.0f, 0.08085143f, -0.011354537f, 0.9966615f, 0.0f, 0.19512177f, 0.49497986f, -0.012947679f, 1.0f}, 1, 0},
    {0.7466, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.7716, 1, 0, 101, 101, 1, 1, 3, 1, {2.0764027f, 0.9275665f, -0.90154344f}, {-0.08111867f, -0.9967045f, 0.00012301712f, 0.0f, 0.99309784f, -0.08083562f, -0.0849857f, 0.0f, 0.084715635f, -0.006771734f, 0.9963821f, 0.0f, 0.20255089f, 0.56282043f, -0.01713872f, 1.0f}, 0, 0},
    {0.7716, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.7956, 1, 0, 101, 101, 1, 1, 3, 1, {2.0976238f, 0.82401276f, -0.9008975f}, {-0.021786608f, -0.99976265f, 0.00014693209f, 0.0f, 0.9955726f, -0.021708725f, -0.09145498f, 0.0f, 0.09143652f, -0.0018462321f, 0.9958092f, 0.0f, 0.20568657f, 0.6306839f, -0.025255442f, 1.0f}, 1, 0},
    {0.7956, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.8195, 1, 0, 101, 101, 1, 1, 3, 1, {2.124874f, 0.7237091f, -0.90318143f}, {0.0117935715f, -0.99993044f, 0.00023188652f, 0.0f, 0.99332637f, 0.011689125f, -0.11474371f, 0.0f, 0.11473297f, 0.0015835225f, 0.99339503f, 0.0f, 0.20394707f, 0.66903687f, -0.054490447f, 1.0f}, 1, 0},
    {0.8195, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.8439, 1, 0, 101, 101, 1, 1, 3, 1, {2.1737251f, 0.58569336f, -0.90557986f}, {0.0034750616f, -0.9999939f, 0.0004217103f, 0.0f, 0.9854421f, 0.003352744f, -0.1699785f, 0.0f, 0.16997609f, 0.001006277f, 0.9854477f, 0.0f, 0.19656563f, 0.6594696f, -0.123928666f, 1.0f}, 0, 0},
    {0.8439, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.8682, 1, 0, 101, 101, 1, 1, 3, 1, {2.2089233f, 0.49306488f, -0.9091929f}, {-0.016554544f, -0.99986297f, 0.0005218531f, 0.0f, 0.9790796f, -0.016316364f, -0.20282319f, 0.0f, 0.20280398f, -0.002846628f, 0.9792152f, 0.0f, 0.19008255f, 0.63682556f, -0.16528738f, 1.0f}, 1, 0},
    {0.8682, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.8922, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {0.8922, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096584f, 0.8711789f, -0.00018894637f, 0.0f, -0.8711786f, 0.49096552f, -0.0009770691f, 0.0f, -0.0007585051f, 0.0006442484f, 0.9999995f, 0.0f, 0.0f, 0.0f, -1.1920929e-07f, 1.0f}, 0, 0},
    {0.9162, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {0.9162, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.94, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {0.94, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {0.9642, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {0.9642, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096584f, 0.8711788f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096555f, -0.000977099f, 0.0f, -0.00075851975f, 0.00064422225f, 0.99999946f, 0.0f, 0.0f, 0.0f, -1.1920929e-07f, 1.0f}, 0, 0},
    {0.988, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {0.988, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.0124, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.0124, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.0364, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.0364, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.0602, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.0602, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018894626f, 0.0f, -0.87117845f, 0.49096552f, -0.0009770095f, 0.0f, -0.000758424f, 0.000644271f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.0841, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.0841, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.1088, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.1088, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.1327, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.1327, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018894626f, 0.0f, -0.87117845f, 0.49096552f, -0.0009770095f, 0.0f, -0.000758424f, 0.000644271f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.156, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.156, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.1805, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.1805, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.2052, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.2052, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096584f, 0.8711789f, -0.00018894637f, 0.0f, -0.8711786f, 0.49096552f, -0.0009770691f, 0.0f, -0.0007585051f, 0.0006442484f, 0.9999995f, 0.0f, 0.0f, 0.0f, -1.1920929e-07f, 1.0f}, 0, 0},
    {1.2302, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.2302, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096578f, 0.8711788f, -0.00018882705f, 0.0f, -0.8711785f, 0.49096543f, -0.0009770691f, 0.0f, -0.0007584532f, 0.0006442191f, 0.9999994f, 0.0f, 0.0f, 0.0f, -1.1920929e-07f, 1.0f}, 0, 0},
    {1.255, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.255, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096578f, 0.8711788f, -0.00018882705f, 0.0f, -0.8711785f, 0.49096543f, -0.0009770691f, 0.0f, -0.0007584532f, 0.0006442191f, 0.9999994f, 0.0f, 0.0f, 0.0f, -1.1920929e-07f, 1.0f}, 0, 0},
    {1.2804, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.2804, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.3055, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.3055, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4909658f, 0.87117875f, -0.00018888665f, 0.0f, -0.8711785f, 0.49096546f, -0.0009770393f, 0.0f, -0.00075843855f, 0.00064424495f, 0.99999946f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f}, 0, 0},
    {1.3297, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.3297, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4911087f, 0.8710983f, -0.00018894626f, 0.0f, -0.8710979f, 0.4911084f, -0.0009770095f, 0.0f, -0.00075831823f, 0.0006443954f, 0.99999946f, 0.0f, 6.866455e-05f, 0.00012207031f, 0.0f, 1.0f}, 0, 0},
    {1.3549, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.3549, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49170285f, 0.870763f, -0.00018888665f, 0.0f, -0.8707627f, 0.4917025f, -0.0009770393f, 0.0f, -0.00075789314f, 0.00064488663f, 0.99999946f, 0.0f, 0.00036239624f, 0.00064086914f, 0.0f, 1.0f}, 0, 0},
    {1.38, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.38, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48967615f, 0.8719044f, -0.00018888665f, 0.0f, -0.8719041f, 0.4896758f, -0.0009770393f, 0.0f, -0.0007593911f, 0.0006431221f, 0.99999946f, 0.0f, -0.00063323975f, -0.0011291504f, 0.0f, 1.0f}, 0, 0},
    {1.4044, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.4044, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48063412f, 0.8769212f, -0.00018888665f, 0.0f, -0.8769209f, 0.48063377f, -0.0009770393f, 0.0f, -0.0007660006f, 0.0006352352f, 0.99999946f, 0.0f, -0.005012512f, -0.009025574f, 0.0f, 1.0f}, 0, 0},
    {1.4286, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.4286, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.46871844f, 0.88334763f, -0.00018888665f, 0.0f, -0.88334733f, 0.46871808f, -0.0009770393f, 0.0f, -0.0007745301f, 0.0006248071f, 0.99999946f, 0.0f, -0.010620117f, -0.019424438f, 0.0f, 1.0f}, 0, 0},
    {1.4529, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.4529, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.44952738f, 0.89326644f, -0.00018894626f, 0.0f, -0.89326614f, 0.4495271f, -0.0009770095f, 0.0f, -0.0007878329f, 0.0006079568f, 0.99999946f, 0.0f, -0.019273758f, -0.03617096f, 0.0f, 1.0f}, 0, 0},
    {1.4764, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.4764, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.42527995f, 0.9050616f, -0.00018882705f, 0.0f, -0.90506136f, 0.42527953f, -0.0009770095f, 0.0f, -0.000803884f, 0.0005864691f, 0.9999994f, 0.0f, -0.029565811f, -0.05734253f, 0.0f, 1.0f}, 0, 0},
    {1.5007, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.5007, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 0.92108923f, 1.0f}, 0, 0},
    {1.5258, 1, 0, 0, 101, 1, 1, 32, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 1, 1},
    {1.5258, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 0.97633874f, 1.0f}, 0, 0},
    {1.5505, 1, 0, 102, 101, 1, 1, 3, 1, {2.2067394f, 0.49129486f, -0.9143457f}, {-0.052086692f, -0.99864256f, 0.0005654888f, 0.0f, 0.9744605f, -0.05094936f, -0.21870375f, 0.0f, 0.21843575f, -0.010840479f, 0.97579116f, 0.0f, 0.18510628f, 0.59693146f, -0.18530309f, 1.0f}, 0, 1},
    {1.5505, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 1.0632136f, 1.0f}, 0, 0},
    {1.5759, 1, 0, 102, 102, 1, 1, 3, 1, {2.3459225f, 25.452225f, -0.9075448f}, {0.006473233f, -0.9999789f, 0.0005645396f, 0.0f, 0.97587013f, 0.006194003f, -0.2182639f, 0.0f, 0.21825571f, 0.0019637216f, 0.9758895f, 0.0f, 0.18677902f, 0.66275024f, -0.18474853f, 1.0f}, 1, 0},
    {1.5759, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 1.25312358f, 1.0f}, 0, 0},
    {1.6003, 1, 0, 102, 102, 1, 1, 3, 1, {2.400301f, 25.497665f, -0.89650583f}, {0.0649706f, -0.99788713f, 0.0005632872f, 0.0f, 0.97393835f, 0.06328839f, -0.21780467f, 0.0f, 0.21730879f, 0.014699455f, 0.97599214f, 0.0f, 0.18460655f, 0.7285156f, -0.18416953f, 1.0f}, 0, 0},
    {1.6003, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 1.41906387f, 1.0f}, 0, 0},
    {1.6243, 1, 0, 102, 102, 1, 1, 3, 1, {2.4609528f, 25.5512f, -0.8813507f}, {0.12310549f, -0.9923935f, 0.0005619108f, 0.0f, 0.9686898f, 0.12004202f, -0.21732545f, 0.0f, 0.21560487f, 0.02729828f, 0.97609895f, 0.0f, 0.17860985f, 0.79389954f, -0.18356538f, 1.0f}, 1, 0},
    {1.6243, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 1.616163f, 1.0f}, 0, 0},
    {1.6485, 1, 0, 102, 102, 1, 1, 3, 1, {2.5740318f, 25.653519f, -0.85393167f}, {0.20966978f, -0.977772f, 0.00055998366f, 0.0f, 0.9545944f, 0.20457563f, -0.21656033f, 0.0f, 0.21163209f, 0.045940682f, 0.976269f, 0.0f, 0.16244507f, 0.89128876f, -0.18260086f, 1.0f}, 1, 0},
    {1.6485, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 1.971374f, 1.0f}, 0, 0},
    {1.6738, 1, 0, 102, 102, 1, 1, 3, 1, {2.6626053f, 25.7351f, -0.8363233f}, {0.26715454f, -0.96365356f, 0.0005584712f, 0.0f, 0.9409345f, 0.26073083f, -0.21601364f, 0.0f, 0.20801674f, 0.05823459f, 0.9763902f, 0.0f, 0.14675903f, 0.955986f, -0.18191159f, 1.0f}, 0, 0},
    {1.6738, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 2.24307764f, 1.0f}, 0, 0},
    {1.6983, 1, 0, 102, 102, 1, 1, 3, 1, {2.754818f, 25.82061f, -0.822678f}, {0.32452342f, -0.94587755f, 0.0005568904f, 0.0f, 0.92370653f, 0.31678987f, -0.21543097f, 0.0f, 0.2035949f, 0.07042679f, 0.97651887f, 0.0f, 0.12696266f, 1.0205688f, -0.18117714f, 1.0f}, 1, 0},
    {1.6983, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 2.393928f, 1.0f}, 0, 0},
    {1.7228, 1, 0, 102, 102, 1, 1, 3, 1, {2.842432f, 25.902283f, -0.81383336f}, {0.38149074f, -0.92437255f, 0.0005551203f, 0.0f, 0.9028403f, 0.37247524f, -0.2148062f, 0.0f, 0.19835424f, 0.082447894f, 0.97665656f, 0.0f, 0.10297394f, 1.0847244f, -0.18038952f, 1.0f}, 1, 0},
    {1.7228, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48824304f, 0.8727026f, -0.0029735544f, 0.0f, 0.0014548544f, 0.0025933448f, 0.9999956f, 0.0f, 0.8727065f, -0.48824522f, -3.47262e-06f, 0.0f, 0.9265766f, -0.51856995f, 2.5461215f, 1.0f}, 0, 0},
    {1.7483, 1, 0, 102, 102, 1, 1, 3, 1, {2.9634228f, 26.01538f, -0.80887693f}, {0.46490303f, -0.88536143f, 0.0005525332f, 0.0f, 0.86494845f, 0.45405078f, -0.21378088f, 0.0f, 0.18902254f, 0.09986526f, 0.9768813f, 0.0f, 0.05939293f, 1.1787262f, -0.17909706f, 1.0f}, 0, 0},
    {1.7483, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48814586f, 0.8727567f, -0.0030129685f, 0.0f, 0.0013235228f, 0.0027119608f, 0.99999547f, 0.0f, 0.87276095f, -0.48814765f, 0.00016871904f, 0.0f, 0.9262924f, -0.5182724f, 2.7751818f, 1.0f}, 0, 0},
    {1.7741, 1, 0, 102, 102, 1, 1, 3, 1, {3.0290718f, 26.075241f, -0.8110125f}, {0.5182271f, -0.8552429f, 0.00055043516f, 0.0f, 0.83567154f, 0.5062309f, -0.21303344f, 0.0f, 0.18191671f, 0.11085964f, 0.97704464f, 0.0f, 0.02571106f, 1.2388458f, -0.17815483f, 1.0f}, 1, 0},
    {1.7741, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48792163f, 0.8728819f, -0.0031039643f, 0.0f, 0.0010204182f, 0.002985587f, 0.9999951f, 0.0f, 0.87288684f, -0.48792234f, 0.000566028f, 0.0f, 0.9256325f, -0.51758575f, 2.926765f, 1.0f}, 0, 0},
    {1.7992, 1, 0, 102, 102, 1, 1, 3, 1, {3.082344f, 26.12519f, -0.8135028f}, {0.56916404f, -0.82222396f, 0.0005482045f, 0.0f, 0.8035599f, 0.55610275f, -0.21223044f, 0.0f, 0.17419612f, 0.1212345f, 0.9772194f, 0.0f, -0.011234283f, 1.2963104f, -0.17714274f, 1.0f}, 1, 0},
    {1.7992, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48764515f, 0.873036f, -0.003216119f, 0.0f, 0.0006470307f, 0.0033224055f, 0.9999943f, 0.0f, 0.87304175f, -0.48764446f, 0.0010552739f, 0.0f, 0.92482185f, -0.51673126f, 3.1532797f, 1.0f}, 0, 0},
    {1.8253, 1, 0, 102, 102, 1, 1, 3, 1, {3.1661263f, 26.202927f, -0.817847f}, {0.64113796f, -0.7674256f, 0.0005445911f, 0.0f, 0.75023735f, 0.62662864f, -0.2109048f, 0.0f, 0.16151248f, 0.13562767f, 0.9775064f, 0.0f, -0.07259941f, 1.3775787f, -0.1754719f, 1.0f}, 1, 0},
    {1.8253, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4876963f, 0.87300736f, -0.0031953864f, 0.0f, 0.0007160375f, 0.003260178f, 0.99999446f, 0.0f, 0.8730129f, -0.48769587f, 0.00096487073f, 0.0f, 0.92497253f, -0.51688385f, 3.30521739f, 1.0f}, 0, 0},
    {1.8509, 1, 0, 102, 102, 1, 1, 3, 1, {3.221342f, 26.25512f, -0.82063013f}, {0.6860548f, -0.72754997f, 0.00054172217f, 0.0f, 0.7114165f, 0.67068505f, -0.20992506f, 0.0f, 0.15236762f, 0.14440553f, 0.97771734f, 0.0f, -0.11728287f, 1.4283447f, -0.17423701f, 1.0f}, 0, 0},
    {1.8509, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48808464f, 0.87279105f, -0.0030377929f, 0.0f, 0.00124082f, 0.0027866391f, 0.9999954f, 0.0f, 0.8727955f, -0.48808616f, 0.00027713898f, 0.0f, 0.9261131f, -0.51808167f, 3.46606648f, 1.0f}, 0, 0},
    {1.8757, 1, 0, 102, 102, 1, 1, 3, 1, {3.3087616f, 26.33886f, -0.82526964f}, {0.74864215f, -0.662974f, 0.00053731387f, 0.0f, 0.6485206f, 0.73215234f, -0.20826405f, 0.0f, 0.13768022f, 0.15626362f, 0.97807246f, 0.0f, -0.189682f, 1.499176f, -0.17214358f, 1.0f}, 1, 0},
    {1.8757, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49305528f, 0.8699968f, -0.0014089196f, 0.0f, 0.008301159f, -0.0030851455f, 0.9999608f, 0.0f, 0.8699584f, -0.49304765f, -0.008743131f, 0.0f, 0.9412575f, -0.5331955f, 3.5886883f, 1.0f}, 0, 0},
    {1.9007, 1, 0, 102, 102, 1, 1, 3, 1, {3.3418179f, 26.413574f, -0.8267746f}, {0.78719705f, -0.61670136f, 0.00053353875f, 0.0f, 0.6034337f, 0.77008235f, -0.2069807f, 0.0f, 0.12723435f, 0.16325654f, 0.97834486f, 0.0f, -0.24158669f, 1.5428848f, -0.17052627f, 1.0f}, 0, 0},
    {1.9007, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4917018f, 0.87075895f, 0.0028488422f, 0.0f, 0.007671868f, -0.007603651f, 0.9999417f, 0.0f, 0.8707299f, -0.49165133f, -0.010419075f, 0.0f, 0.9360676f, -0.5350952f, 3.6013645f, 1.0f}, 0, 0},
    {1.9255, 1, 0, 102, 102, 1, 1, 3, 1, {3.3573036f, 26.500183f, -0.8266242f}, {0.82276255f, -0.56838536f, 0.00052954257f, 0.0f, 0.5563419f, 0.80513775f, -0.20551684f, 0.0f, 0.116386406f, 0.1693861f, 0.9786534f, 0.0f, -0.29580307f, 1.5832748f, -0.16868162f, 1.0f}, 1, 0},
    {1.9255, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48983583f, 0.8718027f, 0.0045712814f, 0.0f, -0.016879844f, 0.0042415154f, 0.9998485f, 0.0f, 0.8716512f, -0.48983875f, 0.01679354f, 0.0f, 0.9033661f, -0.5178299f, 3.59842026f, 1.0f}, 0, 0},
    {1.95, 1, 0, 102, 102, 1, 1, 3, 1, {3.4162292f, 26.64795f, -0.8288874f}, {0.8677251f, -0.49704438f, 0.0005220402f, 0.0f, 0.4868019f, 0.84963095f, -0.20285779f, 0.0f, 0.10038577f, 0.17627892f, 0.97920805f, 0.0f, -0.37587166f, 1.6345367f, -0.165331f, 1.0f}, 1, 0},
    {1.95, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48989132f, 0.8717833f, 0.00051607605f, 0.0f, -0.12348753f, 0.068806745f, 0.9899578f, 0.0f, 0.8629932f, -0.4850354f, 0.14136219f, 0.0f, 0.786705f, -0.44779968f, 3.6017827f, 1.0f}, 0, 0},
    {1.9757, 1, 0, 102, 102, 1, 1, 3, 1, {3.5013542f, 26.741806f, -0.8296979f}, {0.8964757f, -0.443093f, 0.0005156606f, 0.0f, 0.4341773f, 0.87820387f, -0.2006197f, 0.0f, 0.08844036f, 0.18007453f, 0.97966903f, 0.0f, -0.43646622f, 1.6674423f, -0.16251111f, 1.0f}, 0, 0},
    {1.9757, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49020562f, 0.8716065f, 0.0009019221f, 0.0f, -0.22039129f, 0.12295037f, 0.9676317f, 0.0f, 0.8432828f, -0.4745372f, 0.2523654f, 0.0f, 0.6924763f, -0.39517975f, 3.5893217f, 1.0f}, 0, 0},
    {1.9996, 1, 0, 102, 102, 1, 1, 3, 1, {3.5431137f, 26.836037f, -0.8282746f}, {0.9218553f, -0.38753426f, 0.0005072986f, 0.0f, 0.37997133f, 0.9036057f, -0.19778502f, 0.0f, 0.07619005f, 0.182522f, 0.98024523f, 0.0f, -0.4988842f, 1.6966858f, -0.15893996f, 1.0f}, 1, 0},
    {1.9996, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4903459f, 0.87152785f, 0.00043881178f, 0.0f, -0.30759725f, 0.17259169f, 0.93573296f, 0.0f, 0.8154414f, -0.4589678f, 0.35270917f, 0.0f, 0.6075802f, -0.3467102f, 3.56610572f, 1.0f}, 0, 0},
    {2.0236, 1, 0, 102, 102, 1, 1, 3, 1, {3.5714684f, 26.943573f, -0.82735234f}, {0.94361246f, -0.3310522f, 0.0004959663f, 0.0f, 0.32485884f, 0.9256685f, -0.19391966f, 0.0f, 0.06373841f, 0.18314621f, 0.98101723f, 0.0f, -0.56235313f, 1.7220612f, -0.15407085f, 1.0f}, 1, 0},
    {2.0236, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49068454f, 0.87133706f, -0.0005147702f, 0.0f, -0.43119207f, 0.24333473f, 0.8688278f, 0.0f, 0.7571671f, -0.42609844f, 0.49511424f, 0.0f, 0.48701096f, -0.27745056f, 3.5117563f, 1.0f}, 0, 0},
    {2.0482, 1, 0, 102, 102, 1, 1, 3, 1, {3.6077194f, 27.105804f, -0.82800955f}, {0.96955514f, -0.24487306f, 0.0004616077f, 0.0f, 0.24083687f, 0.95323f, -0.18262056f, 0.0f, 0.04427888f, 0.17717189f, 0.9831833f, 0.0f, -0.6591339f, 1.7535934f, -0.1398418f, 1.0f}, 0, 0},
    {2.0482, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096367f, 0.8711795f, -0.0010677901f, 0.0f, -0.509486f, 0.28812078f, 0.8108084f, 0.0f, 0.7066674f, -0.39753345f, 0.5853105f, 0.0f, 0.40821457f, -0.23222351f, 3.46218574f, 1.0f}, 0, 0},
    {2.0726, 1, 0, 102, 102, 1, 1, 3, 1, {3.6363945f, 27.212051f, -0.8349967f}, {0.97761697f, -0.2103933f, 0.0003995758f, 0.0f, 0.20763558f, 0.96449244f, -0.16322517f, 0.0f, 0.033956032f, 0.15965474f, 0.9865887f, 0.0f, -0.69745064f, 1.7660675f, -0.11543119f, 1.0f}, 1, 0},
    {2.0726, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49121603f, 0.8710368f, -0.0013662355f, 0.0f, -0.5824457f, 0.32963228f, 0.743034f, 0.0f, 0.64766014f, -0.36419442f, 0.6692522f, 0.0f, 0.3329544f, -0.18927002f, 3.4026848f, 1.0f}, 0, 0},
    {2.0974, 1, 0, 102, 102, 1, 1, 3, 1, {3.633583f, 27.356026f, -0.8809246f}, {0.98130035f, -0.19248281f, 0.0002093747f, 0.0f, 0.19136827f, 0.97550017f, -0.10852501f, 0.0f, 0.0206849f, 0.106535785f, 0.9940937f, 0.0f, -0.7164898f, 1.7770615f, -0.046681523f, 1.0f}, 1, 0},
    {2.0974, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4913191f, 0.8709789f, -0.0009986276f, 0.0f, -0.67864966f, 0.38354436f, 0.6263612f, 0.0f, 0.5459304f, -0.30706552f, 0.7795323f, 0.0f, 0.23114204f, -0.13197327f, 3.2975487f, 1.0f}, 0, 0},
    {2.1217, 1, 0, 102, 102, 1, 1, 3, 1, {3.6475067f, 27.445976f, -0.8786294f}, {0.9819605f, -0.18908723f, 8.901127e-05f, 0.0f, 0.18854989f, 0.9791346f, -0.0757955f, 0.0f, 0.014244826f, 0.074444935f, 0.99712336f, 0.0f, -0.719944f, 1.7800903f, -0.005611539f, 1.0f}, 0, 0},
    {2.1217, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49056923f, 0.8714017f, 0.000918178f, 0.0f, -0.7341469f, 0.4127315f, 0.5391483f, 0.0f, 0.4694358f, -0.2651637f, 0.8422102f, 0.0f, 0.17087364f, -0.099998474f, 3.2173394f, 1.0f}, 0, 0},
    {2.1469, 1, 0, 102, 102, 1, 1, 3, 1, {3.6658363f, 27.535942f, -0.8613715f}, {0.9822702f, -0.18747121f, 1.3000448e-05f, 0.0f, 0.18718387f, 0.98076046f, -0.05542043f, 0.0f, 0.010376952f, 0.054440312f, 0.9984631f, 0.0f, -0.721653f, 1.781189f, 0.019931078f, 1.0f}, 1, 0},
    {2.1469, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.48935428f, 0.8720788f, 0.0032654875f, 0.0f, -0.78200805f, 0.43714884f, 0.44425672f, 0.0f, 0.3859994f, -0.21995255f, 0.89589345f, 0.0f, 0.11741829f, -0.07236481f, 3.12887704f, 1.0f}, 0, 0},
    {2.171, 1, 0, 102, 102, 1, 1, 3, 1, {3.6919708f, 27.617714f, -0.8329969f}, {0.9822932f, -0.18734983f, -3.5485602e-05f, 0.0f, 0.1871796f, 0.9814086f, -0.042437673f, 0.0f, 0.007985528f, 0.041679587f, 0.999099f, 0.0f, -0.72175026f, 1.7814178f, 0.03619659f, 1.0f}, 1, 0},
    {2.171, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4894923f, 0.8720031f, 0.0028001354f, 0.0f, -0.8350078f, 0.46779504f, 0.28970647f, 0.0f, 0.2513151f, -0.14414729f, 0.9571114f, 0.0f, 0.05465889f, -0.035995483f, 2.982651f, 1.0f}, 0, 0},
    {2.1956, 1, 0, 102, 102, 1, 1, 3, 1, {3.7193565f, 27.691643f, -0.8045079f}, {0.98202133f, -0.18877137f, -7.8418176e-05f, 0.0f, 0.18867877f, 0.98155236f, -0.030917645f, 0.0f, 0.005913295f, 0.030347088f, 0.99952203f, 0.0f, -0.7201195f, 1.7811127f, 0.050623298f, 1.0f}, 0, 0},
    {2.1956, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49048257f, 0.8714499f, 0.001323358f, 0.0f, -0.85752636f, 0.4823744f, 0.178783f, 0.0f, 0.15516217f, -0.08882476f, 0.98388755f, 0.0f, 0.024707794f, -0.01702118f, 2.8762975f, 1.0f}, 0, 0},
    {2.2205, 1, 0, 102, 102, 1, 1, 3, 1, {3.8193665f, 27.657349f, -0.801077f}, {0.9817397f, -0.19023031f, -9.4898394e-05f, 0.0f, 0.19016111f, 0.9813957f, -0.026487112f, 0.0f, 0.0051317858f, 0.025985448f, 0.9996492f, 0.0f, -0.71845627f, 1.7807465f, 0.056169987f, 1.0f}, 1, 0},
    {2.2205, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4901205f, 0.87165284f, 0.0018041434f, 0.0f, -0.8695488f, 0.48879167f, 0.07048059f, 0.0f, 0.06055276f, -0.036112804f, 0.99751145f, 0.0f, 0.005048752f, -0.0061798096f, 2.7714353f, 1.0f}, 0, 0},
    {2.2452, 1, 0, 102, 102, 1, 1, 3, 1, {4.0659485f, 27.556168f, -0.82082367f}, {0.9804473f, -0.19678293f, -0.00010787416f, 0.0f, 0.1967286f, 0.9801888f, -0.022986203f, 0.0f, 0.004628935f, 0.022515643f, 0.99973583f, 0.0f, -0.7109623f, 1.779213f, 0.06055236f, 1.0f}, 1, 0},
    {2.2452, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4901948f, 0.8716113f, 0.0016148146f, 0.0f, -0.87145466f, 0.4900697f, 0.019957807f, 0.0f, 0.016604066f, -0.011190474f, 0.99979943f, 0.0f, -0.00233078f, -0.0015716553f, 2.7224915f, 1.0f}, 0, 0},
    {2.271, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 0, 1},
    {2.271, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49039704f, 0.8714983f, 0.0012826239f, 0.0f, -0.87120897f, 0.4901953f, 0.026526101f, 0.0f, 0.022488667f, -0.014125723f, 0.9996472f, 0.0f, 0.0012454987f, -0.0031204224f, 2.7285017f, 1.0f}, 0, 0},
    {2.2947, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.2947, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49281076f, 0.87013507f, -0.0016531241f, 0.0f, -0.870041f, 0.49278393f, 0.0138884615f, 0.0f, 0.012899435f, -0.0054060696f, 0.9999022f, 0.0f, 0.0019302368f, 0.00019073486f, 2.71613896f, 1.0f}, 0, 0},
    {2.3193, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.3193, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49295333f, 0.8700538f, -0.0018551423f, 0.0f, -0.8700543f, 0.49295542f, 0.00080697326f, 0.0f, 0.001616481f, 0.0012162161f, 0.9999981f, 0.0f, 0.0001335144f, 0.0015335083f, 2.7034981f, 1.0f}, 0, 0},
    {2.3446, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 0, 1},
    {2.3446, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49096933f, 0.8711766f, 0.000336849f, 0.0f, -0.8711758f, 0.49096936f, -0.0013257207f, 0.0f, -0.0013203025f, 0.0003574685f, 0.99999905f, 0.0f, -0.0009326935f, -0.00046539307f, 2.7013943f, 1.0f}, 0, 0},
    {2.3685, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.3685, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49067882f, 0.87134045f, 0.00053385494f, 0.0f, -0.8713384f, 0.49067885f, -0.001925854f, 0.0f, -0.0019400204f, 0.0004798668f, 0.99999785f, 0.0f, -0.0009460449f, -0.00060272217f, 2.7008193f, 1.0f}, 0, 0},
    {2.3938, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.3938, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4906802f, 0.8713397f, 0.0004424944f, 0.0f, -0.87133783f, 0.49068016f, -0.0018717119f, 0.0f, -0.0018481216f, 0.0005329032f, 0.9999982f, 0.0f, -0.0007991791f, -0.0005187988f, 2.700882f, 1.0f}, 0, 0},
    {2.4177, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 0, 1},
    {2.4177, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49076527f, 0.8712919f, 0.00025605247f, 0.0f, -0.8712905f, 0.49076506f, -0.0016183998f, 0.0f, -0.0015358604f, 0.00057117466f, 0.9999986f, 0.0f, -0.000579834f, -0.00035858154f, 2.701141f, 1.0f}, 0, 0},
    {2.4418, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.4418, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49092332f, 0.8712029f, -5.792349e-05f, 0.0f, -0.87120235f, 0.49092305f, -0.0011514222f, 0.0f, -0.0009747742f, 0.0006157148f, 0.99999934f, 0.0f, -0.000207901f, -9.1552734e-05f, 2.7016181f, 1.0f}, 0, 0},
    {2.4668, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.4668, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49181938f, 0.8706972f, -0.00020771369f, 0.0f, -0.87069046f, 0.4918164f, 0.003837496f, 0.0f, 0.0034435117f, -0.0017064947f, 0.99999255f, 0.0f, 0.0007724762f, 0.0005493164f, 2.70651615f, 1.0f}, 0, 0},
    {2.4914, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 0, 1},
    {2.4914, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49266908f, 0.8702168f, -0.00022669218f, 0.0f, -0.8701831f, 0.49265227f, 0.008686185f, 0.0f, 0.007670496f, -0.004082182f, 0.9999622f, 0.0f, 0.0015697479f, 0.001083374f, 2.7112607f, 1.0f}, 0, 0},
    {2.5162, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.5162, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49393108f, 0.869501f, -0.00025487057f, 0.0f, -0.8693889f, 0.49387202f, 0.015920341f, 0.0f, 0.013968636f, -0.0076419166f, 0.99987316f, 0.0f, 0.0027923584f, 0.0018463135f, 2.7183359f, 1.0f}, 0, 0},
    {2.5404, 1, 0, 0, 102, 1, 1, 32, 1, {4.0723877f, 27.555168f, -0.8149144f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 1, 1},
    {2.5404, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49475378f, 0.8690333f, -0.00027342717f, 0.0f, -0.86884606f, 0.49465376f, 0.02059713f, 0.0f, 0.018034821f, -0.009952972f, 0.9997878f, 0.0f, 0.003610611f, 0.0023345947f, 2.7229075f, 1.0f}, 0, 0},
    {2.5659, 1, 0, 103, 103, 1, 1, 3, 1, {3.6990204f, 26.60511f, -1.05411834f}, {0.9791871f, -0.20296003f, -0.00011195638f, 0.0f, 0.20290916f, 0.9789534f, -0.021865517f, 0.0f, 0.004547398f, 0.02138775f, 0.9997609f, 0.0f, -0.70389366f, 1.7777481f, 0.061955094f, 1.0f}, 0, 0},
    {2.5659, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4959688f, 0.8683403f, -0.00029993983f, 0.0f, -0.8680107f, 0.49578997f, 0.027383596f, 0.0f, 0.023927093f, -0.0133210635f, 0.9996249f, 0.0f, 0.004842758f, 0.0030441284f, 2.7295382f, 1.0f}, 0, 0},
    {2.5911, 1, 0, 103, 103, 1, 1, 3, 1, {3.7668571f, 26.584633f, -1.0539594f}, {0.9804325f, -0.19685599f, -9.525998e-05f, 0.0f, 0.19678512f, 0.9800925f, -0.02635336f, 0.0f, 0.005281207f, 0.025818925f, 0.9996527f, 0.0f, -0.71086884f, 1.7792435f, 0.056337476f, 1.0f}, 1, 0},
    {2.5911, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49675655f, 0.8678899f, -0.00031731243f, 0.0f, -0.867447f, 0.49651474f, 0.03176129f, 0.0f, 0.027722899f, -0.015502338f, 0.99949545f, 0.0f, 0.0056610107f, 0.0034866333f, 2.7338134f, 1.0f}, 0, 0},
    {2.6159, 1, 0, 103, 103, 1, 1, 3, 1, {3.795311f, 26.574493f, -1.0600296f}, {0.98067373f, -0.19565019f, -8.9127454e-05f, 0.0f, 0.19557096f, 0.9802891f, -0.028020263f, 0.0f, 0.005569503f, 0.027461352f, 0.9996074f, 0.0f, -0.71224594f, 1.779541f, 0.054250717f, 1.0f}, 1, 0},
    {2.6159, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4975389f, 0.8674416f, -0.00033398264f, 0.0f, -0.8668732f, 0.49722677f, 0.03600645f, 0.0f, 0.03139958f, -0.017625062f, 0.99935144f, 0.0f, 0.0064811707f, 0.003929138f, 2.7379577f, 1.0f}, 0, 0},
    {2.6407, 1, 0, 103, 103, 1, 1, 3, 1, {3.833168f, 26.561394f, -1.0682452f}, {0.98086625f, -0.19468388f, -8.383405e-05f, 0.0f, 0.19459698f, 0.9804412f, -0.029452205f, 0.0f, 0.0058160196f, 0.028872345f, 0.99956614f, 0.0f, -0.7133503f, 1.7797775f, 0.05245793f, 1.0f}, 0, 0},
    {2.6407, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.4986803f, 0.866786f, -0.0003585848f, 0.0f, -0.86600655f, 0.4982494f, 0.042194903f, 0.0f, 0.036752515f, -0.020731252f, 0.9991094f, 0.0f, 0.007701874f, 0.0045547485f, 2.7439964f, 1.0f}, 0, 0},
    {2.6652, 1, 0, 103, 103, 1, 1, 3, 1, {3.8577156f, 26.553413f, -1.0726051f}, {0.98092973f, -0.19436386f, -8.1186416e-05f, 0.0f, 0.19427298f, 0.98048365f, -0.030170858f, 0.0f, 0.0059437603f, 0.029579626f, 0.9995447f, 0.0f, -0.7137184f, 1.7798538f, 0.051558256f, 1.0f}, 1, 0},
    {2.6652, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49870062f, 0.8667742f, -0.00035784638f, 0.0f, -0.8659997f, 0.49827245f, 0.042058647f, 0.0f, 0.0366337f, -0.02066479f, 0.999115f, 0.0f, 0.007698059f, 0.004585266f, 2.7438635f, 1.0f}, 0, 0},
    {2.6899, 1, 0, 103, 103, 1, 1, 3, 1, {3.8778954f, 26.546768f, -1.0760846f}, {0.98071647f, -0.19543651f, -7.9381745e-05f, 0.0f, 0.19534235f, 0.9802565f, -0.030639172f, 0.0f, 0.0060658306f, 0.030032862f, 0.9995305f, 0.0f, -0.71248627f, 1.7796173f, 0.050971866f, 1.0f}, 1, 0},
    {2.6899, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49867892f, 0.8667867f, -0.0003564026f, 0.0f, -0.8660246f, 0.49825764f, 0.041720778f, 0.0f, 0.036340617f, -0.020496618f, 0.9991292f, 0.0f, 0.0076503754f, 0.004585266f, 2.7435338f, 1.0f}, 0, 0},
    {2.7147, 1, 0, 103, 103, 1, 1, 3, 1, {3.9001465f, 26.539215f, -1.08121532f}, {0.9804986f, -0.19652662f, -7.727521e-05f, 0.0f, 0.19642858f, 0.9800217f, -0.031201154f, 0.0f, 0.006207518f, 0.030577522f, 0.9995131f, 0.0f, -0.71123886f, 1.7793655f, 0.050268292f, 1.0f}, 0, 0},
    {2.7147, 2, 1, 0, 0, 0, 1, 32, 1, {-7.9462214f, 4.490135f, 3.0639166f}, {0.49866366f, 0.86679554f, -0.00035552157f, 0.0f, -0.8660431f, 0.49824786f, 0.04145533f, 0.0f, 0.036110345f, -0.020364424f, 0.9991403f, 0.0f, 0.0076141357f, 0.004585266f, 2.743275f, 1.0f}, 0, 0},
    {2.7394, 1, 0, 103, 103, 1, 1, 3, 1, {3.9141006f, 26.534882f, -1.08424443f}, {0.9805143f, -0.19644862f, -7.607124e-05f, 0.0f, 0.19634864f, 0.98002744f, -0.031523854f, 0.0f, 0.006267366f, 0.03089465f, 0.99950296f, 0.0f, -0.7113285f, 1.7793808f, 0.049864173f, 1.0f}, 1, 0},
    {2.7394, 2, 1, 0, 0, 0, 1, 32, 1, {-27.9453421f, 4.302536f, 3.0639166f}, {0.49867323f, 0.86679006f, -0.00035478186f, 0.0f, -0.8660416f, 0.49825966f, 0.04134348f, 0.0f, 0.03601284f, -0.020309629f, 0.9991449f, 0.0f, 0.0076065063f, 0.004600525f, 2.7431657f, 1.0f}, 0, 0},
    {2.7633, 1, 0, 103, 103, 1, 1, 3, 1, {3.9247704f, 26.531525f, -1.0865347f}, {0.9802724f, -0.19765182f, -7.5287535e-05f, 0.0f, 0.19754983f, 0.9797782f, -0.031766295f, 0.0f, 0.0063523543f, 0.031124793f, 0.9994953f, 0.0f, -0.7099495f, 1.7791138f, 0.049560666f, 1.0f}, 0, 0},
    {2.7633, 2, 1, 104, 0, 0, 1, 3, 1, {-7.8511667f, 4.442772f, 2.6200556f}, {0.47336587f, 0.88086575f, -0.00035042164f, 0.0f, -0.88014424f, 0.47299415f, 0.040283173f, 0.0f, 0.035649773f, -0.018760245f, 0.99918824f, 0.0f, -0.0047302246f, -0.017318726f, 2.7421312f, 1.0f}, 0, 0},
    {2.7882, 1, 0, 103, 103, 1, 1, 3, 1, {3.934082f, 26.528328f, -1.0887557f}, {0.98014104f, -0.19830179f, -7.35434e-05f, 0.0f, 0.19819668f, 0.97963387f, -0.0321801f, 0.0f, 0.0064535f, 0.031526443f, 0.999482f, 0.0f, -0.7092056f, 1.7789612f, 0.049042583f, 1.0f}, 1, 0},
    {2.7882, 2, 1, 104, 104, 0, 1, 3, 1, {-3.677003f, 6.8791656f, 2.275065f}, {0.5081226f, 0.86128485f, -0.00031894923f, 0.0f, -0.86082137f, 0.50786126f, 0.03261569f, 0.0f, 0.028253304f, -0.016298255f, 0.999468f, 0.0f, 0.011487961f, 0.013328552f, 2.73464763f, 1.0f}, 0, 0},
    {2.8136, 1, 0, 103, 103, 1, 1, 3, 1, {3.9395638f, 26.526665f, -1.0894523f}, {0.9802356f, -0.19783375f, -7.2880415e-05f, 0.0f, 0.19772772f, 0.97972226f, -0.03237343f, 0.0f, 0.006475985f, 0.031719137f, 0.9994757f, 0.0f, -0.7097416f, 1.779068f, 0.04880047f, 1.0f}, 1, 0},
    {2.8136, 2, 1, 104, 104, 0, 1, 3, 1, {-3.8084126f, 6.919388f, 2.2151418f}, {0.5562528f, 0.8310132f, -0.00031398714f, 0.0f, -0.8305974f, 0.55598634f, 0.031421334f, 0.0f, 0.026285963f, -0.017217407f, 0.99950624f, 0.0f, 0.037693024f, 0.055259705f, 2.7334815f, 1.0f}, 0, 0},
    {2.838, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {2.838, 2, 1, 104, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.6256188f, 0.7801288f, -0.00030497642f, 0.0f, -0.77979094f, 0.6253593f, 0.029188246f, 0.0f, 0.022961251f, -0.018022928f, 0.9995739f, 0.0f, 0.08174133f, 0.115753174f, 2.7313008f, 1.0f}, 0, 0},
    {2.8638, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {2.8638, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {2.8878, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {2.8878, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {2.912, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {2.912, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {2.9359, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {2.9359, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {2.9604, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {2.9604, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {2.9849, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {2.9849, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {3.0089, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.0089, 2, 1, 0, 104, 0, 1, 3, 1, {-3.9341354f, 6.954811f, 2.0625635f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 1},
    {3.0345, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.0345, 2, 1, 105, 105, 0, 1, 3, 1, {4.7927895f, 14.245476f, 1.7093858f}, {0.66970944f, 0.74262315f, -0.00029729068f, 0.0f, -0.7423413f, 0.66946626f, 0.027284324f, 0.0f, 0.020460945f, -0.018051904f, 0.99962765f, 0.0f, 0.114206314f, 0.15425873f, 2.72944129f, 1.0f}, 0, 0},
    {3.0601, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.0601, 2, 1, 105, 105, 0, 1, 3, 1, {4.793833f, 14.246704f, 1.7091928f}, {0.7110054f, 0.7031864f, -0.00029501313f, 0.0f, -0.7029295f, 0.71075684f, 0.026735902f, 0.0f, 0.01901002f, -0.018801996f, 0.99964243f, 0.0f, 0.14847565f, 0.19023895f, 2.7289056f, 1.0f}, 0, 0},
    {3.0846, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.0846, 2, 1, 105, 105, 0, 1, 3, 1, {4.795822f, 14.248482f, 1.7103633f}, {0.76806325f, 0.64037395f, -0.00029161276f, 0.0f, -0.640154f, 0.76781124f, 0.025860846f, 0.0f, 0.01678449f, -0.01967609f, 0.9996655f, 0.0f, 0.20306969f, 0.2399826f, 2.7280508f, 1.0f}, 0, 0},
    {3.1095, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.1095, 2, 1, 105, 105, 0, 1, 3, 1, {4.7974606f, 14.249611f, 1.7121451f}, {0.80294377f, 0.59605455f, -0.00028909819f, 0.0f, -0.595859f, 0.80269253f, 0.025232553f, 0.0f, 0.015272196f, -0.020088075f, 0.9996814f, 0.0f, 0.24159622f, 0.27039337f, 2.727437f, 1.0f}, 0, 0},
    {3.1335, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.1335, 2, 1, 105, 105, 0, 1, 3, 1, {4.8002872f, 14.251236f, 1.716025f}, {0.8506283f, 0.5257673f, -0.00028498535f, 0.0f, -0.52560735f, 0.85038275f, 0.02420947f, 0.0f, 0.012970891f, -0.020443425f, 0.9997068f, 0.0f, 0.3027115f, 0.31201172f, 2.72643745f, 1.0f}, 0, 0},
    {3.1579, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.1579, 2, 1, 105, 105, 0, 1, 3, 1, {4.8024254f, 14.252281f, 1.7194473f}, {0.8789393f, 0.47693378f, -0.0002820852f, 0.0f, -0.47679645f, 0.8787002f, 0.02347675f, 0.0f, 0.011444672f, -0.020500088f, 0.9997243f, 0.0f, 0.3451805f, 0.33673096f, 2.72572148f, 1.0f}, 0, 0},
    {3.1822, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.1822, 2, 1, 105, 105, 0, 1, 3, 1, {4.804777f, 14.253319f, 1.723555f}, {0.90438265f, 0.4267224f, -0.000278947f, 0.0f, -0.42660674f, 0.90415233f, 0.022699535f, 0.0f, 0.0099385865f, -0.020410037f, 0.9997422f, 0.0f, 0.38885498f, 0.35897064f, 2.72496212f, 1.0f}, 0, 0},
    {3.207, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.207, 2, 1, 105, 105, 0, 1, 3, 1, {4.808792f, 14.254906f, 1.7312224f}, {0.93725467f, 0.3486457f, -0.00027403265f, 0.0f, -0.34856015f, 0.9370415f, 0.02142647f, 0.0f, 0.0077269673f, -0.019986494f, 0.9997704f, 0.0f, 0.4567852f, 0.38772583f, 2.72371805f, 1.0f}, 0, 0},
    {3.233, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.233, 2, 1, 105, 105, 0, 1, 3, 1, {4.8117943f, 14.255966f, 1.7373201f}, {0.9555719f, 0.29475814f, -0.00027027068f, 0.0f, -0.29469097f, 0.95537305f, 0.02048695f, 0.0f, 0.0062969094f, -0.019497104f, 0.9997901f, 0.0f, 0.5036793f, 0.40377045f, 2.7227999f, 1.0f}, 0, 0},
    {3.2565, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.2565, 2, 1, 105, 105, 0, 1, 3, 1, {4.815012f, 14.257019f, 1.7440533f}, {0.9709537f, 0.23926738f, -0.0002663909f, 0.0f, -0.23921703f, 0.97077125f, 0.019453198f, 0.0f, 0.004913036f, -0.018824423f, 0.9998108f, 0.0f, 0.55197906f, 0.4172821f, 2.72178948f, 1.0f}, 0, 0},
    {3.2814, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.2814, 2, 1, 105, 105, 0, 1, 3, 1, {4.820112f, 14.258514f, 1.75497001f}, {0.9882957f, 0.15255009f, -0.00025936618f, 0.0f, -0.15252164f, 0.9881422f, 0.017674893f, 0.0f, 0.0029524995f, -0.017428394f, 0.9998438f, 0.0f, 0.62748146f, 0.43257904f, 2.7200512f, 1.0f}, 0, 0},
    {3.3058, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.3058, 2, 1, 105, 105, 0, 1, 3, 1, {4.823702f, 14.259438f, 1.7628031f}, {0.99565274f, 0.09314405f, -0.00025396963f, 0.0f, -0.0931275f, 0.9955209f, 0.016294181f, 0.0f, 0.0017704673f, -0.016199565f, 0.9998673f, 0.0f, 0.6792221f, 0.43914032f, 2.7187014f, 1.0f}, 0, 0},
    {3.3305, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.3305, 2, 1, 105, 105, 0, 1, 3, 1, {4.8274803f, 14.260315f, 1.7712002f}, {0.99945605f, 0.032975f, -0.0002477101f, 0.0f, -0.032967854f, 0.9993483f, 0.014698833f, 0.0f, 0.0007322915f, -0.014682718f, 0.9998919f, 0.0f, 0.7316437f, 0.4426117f, 2.71714151f, 1.0f}, 0, 0},
    {3.3552, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.3552, 2, 1, 105, 105, 0, 1, 3, 1, {4.83333f, 14.261551f, 1.784403f}, {0.99838746f, -0.05676722f, -0.00023637136f, 0.0f, 0.056766123f, 0.9983187f, 0.011730522f, 0.0f, -0.00042992388f, -0.011724992f, 0.9999311f, 0.0f, 0.80986786f, 0.44198608f, 2.7142386f, 1.0f}, 0, 0},
    {3.3816, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.3816, 2, 1, 105, 105, 0, 1, 3, 1, {4.8372135f, 14.262337f, 1.7932553f}, {0.9932988f, -0.11557428f, -0.00022641965f, 0.0f, 0.11557161f, 0.9932576f, 0.009102643f, 0.0f, -0.00082716905f, -0.009067752f, 0.9999585f, 0.0f, 0.8611622f, 0.43779755f, 2.711668f, 1.0f}, 0, 0},
    {3.4078, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.4078, 2, 1, 105, 105, 0, 1, 3, 1, {4.843054f, 14.263481f, 1.8066944f}, {0.9792971f, -0.202428f, -0.00020229409f, 0.0f, 0.20242777f, 0.9792936f, 0.0026740134f, 0.0f, -0.00034316618f, -0.0026596307f, 0.99999636f, 0.0f, 0.9370136f, 0.42616272f, 2.7053775f, 1.0f}, 0, 0},
    {3.432, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.432, 2, 1, 105, 105, 0, 1, 3, 1, {4.846998f, 14.264206f, 1.81586975f}, {0.969497f, -0.24510306f, -0.00016722304f, 0.0f, 0.2450961f, 0.96947426f, -0.0069010854f, 0.0f, 0.0018535813f, 0.006649582f, 0.9999762f, 0.0f, 0.9744377f, 0.4183731f, 2.69600141f, 1.0f}, 0, 0},
    {3.4563, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.4563, 2, 1, 105, 105, 0, 1, 3, 1, {4.850897f, 14.2649f, 1.8249973f}, {0.96499646f, -0.26226264f, -0.00010937569f, 0.0f, 0.26219353f, 0.9647517f, -0.022554934f, 0.0f, 0.006020833f, 0.021736756f, 0.99974567f, 0.0f, 0.9896984f, 0.41547394f, 2.6806567f, 1.0f}, 0, 0},
    {3.4811, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.4811, 2, 1, 105, 105, 0, 1, 3, 1, {4.8554974f, 14.275856f, 1.8616968f}, {0.96260893f, -0.27089456f, -5.733408e-05f, 0.0f, 0.27071145f, 0.9619662f, -0.03655699f, 0.0f, 0.009958222f, 0.035174616f, 0.9993316f, 0.0f, 0.99744415f, 0.4141159f, 2.666914f, 1.0f}, 0, 0},
    {3.5057, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 0, 1},
    {3.5057, 2, 1, 105, 105, 0, 1, 3, 1, {4.862217f, 14.280785f, 1.89157981f}, {0.9621055f, -0.27267727f, -4.303374e-05f, 0.0f, 0.27245283f, 0.9613196f, -0.040424705f, 0.0f, 0.011064268f, 0.038881168f, 0.9991826f, 0.0f, 0.99905014f, 0.41384125f, 2.663115f, 1.0f}, 0, 0},
    {3.5308, 1, 0, 0, 103, 1, 1, 32, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.5308, 2, 1, 105, 105, 0, 1, 3, 1, {4.8728676f, 14.282463f, 1.91992956f}, {0.9618444f, -0.2735968f, -3.7299236e-05f, 0.0f, 0.27335474f, 0.96099925f, -0.041922778f, 0.0f, 0.011505806f, 0.040312953f, 0.99912083f, 0.0f, 0.9998722f, 0.41368103f, 2.661643f, 1.0f}, 0, 0},
    {3.5559, 1, 0, 106, 103, 1, 1, 3, 1, {3.9399605f, 26.526566f, -1.089956f}, {0.98037136f, -0.19715975f, -7.245969e-05f, 0.0f, 0.19705339f, 0.979855f, -0.0324682f, 0.0f, 0.0064724814f, 0.03181657f, 0.9994727f, 0.0f, -0.71051407f, 1.7792206f, 0.048681855f, 1.0f}, 1, 1},
    {3.5559, 2, 1, 105, 105, 0, 1, 3, 1, {4.8941727f, 14.273224f, 1.9558465f}, {0.9615027f, -0.27479538f, -3.7539285e-05f, 0.0f, 0.27455273f, 0.9606592f, -0.041888893f, 0.0f, 0.011546878f, 0.040266052f, 0.99912226f, 0.0f, 1.0009212f, 0.41336823f, 2.6616765f, 1.0f}, 0, 0},
    {3.5823, 1, 0, 106, 106, 1, 1, 3, 1, {-3.6773472f, 28.910767f, 7.7631935f}, {0.98578787f, -0.16799459f, -7.745484e-05f, 0.0f, 0.1679106f, 0.9853092f, -0.031177014f, 0.0f, 0.005313862f, 0.030720925f, 0.9995138f, 0.0f, -0.74390984f, 1.7854538f, 0.050298452f, 1.0f}, 0, 0},
    {3.5823, 2, 1, 105, 105, 0, 1, 3, 1, {4.913147f, 14.2597885f, 1.9748992f}, {0.96122795f, -0.2757549f, -4.025642e-05f, 0.0f, 0.2755196f, 0.96041346f, -0.04117024f, 0.0f, 0.011391502f, 0.039562967f, 0.9991522f, 0.0f, 1.0017529f, 0.4131012f, 2.6623826f, 1.0f}, 0, 0},
    {3.6067, 1, 0, 106, 106, 1, 1, 3, 1, {-3.5758457f, 28.890823f, 7.7327513f}, {0.99399114f, -0.109460786f, -8.918694e-05f, 0.0f, 0.10941542f, 0.99360114f, -0.02802062f, 0.0f, 0.003155707f, 0.027842537f, 0.9996073f, 0.0f, -0.8109379f, 1.7948837f, 0.05425024f, 1.0f}, 1, 0},
    {3.6067, 2, 1, 105, 105, 0, 1, 3, 1, {4.9326515f, 14.240463f, 1.992022f}, {0.9608854f, -0.2769462f, -4.351721e-05f, 0.0f, 0.27671978f, 0.96010596f, -0.04028523f, 0.0f, 0.011198572f, 0.038697526f, 0.9991883f, 0.0f, 1.0027847f, 0.41277313f, 2.663252f, 1.0f}, 0, 0},
    {3.6315, 1, 0, 106, 106, 1, 1, 3, 1, {-3.6060886f, 28.859528f, 7.689733f}, {0.99870795f, -0.05082148f, -0.000106072985f, 0.0f, 0.050805077f, 0.9984331f, -0.023467064f, 0.0f, 0.001298526f, 0.023431467f, 0.9997247f, 0.0f, -0.8780899f, 1.8002853f, 0.05995047f, 1.0f}, 1, 0},
    {3.6315, 2, 1, 105, 105, 0, 1, 3, 1, {4.972515f, 14.201439f, 2.009115f}, {0.9602497f, -0.2791419f, -4.864903e-05f, 0.0f, 0.27892914f, 0.95952475f, -0.038868636f, 0.0f, 0.010896573f, 0.03731f, 0.9992443f, 0.0f, 1.0046902f, 0.41215515f, 2.6646435f, 1.0f}, 0, 0},
    {3.657, 1, 0, 106, 106, 1, 1, 3, 1, {-3.6472626f, 28.817268f, 7.6116394f}, {0.99947625f, 0.032363717f, -0.00015951437f, 0.0f, -0.03236378f, 0.9994357f, -0.009004712f, 0.0f, -0.00013207248f, 0.0090051945f, 0.9999594f, 0.0f, -0.97333145f, 1.8009033f, 0.07804835f, 1.0f}, 0, 0},
    {3.657, 2, 1, 105, 105, 0, 1, 3, 1, {5.008381f, 14.17009f, 2.00305974f}, {0.9596807f, -0.28109264f, -5.1422394e-05f, 0.0f, 0.28088602f, 0.9589818f, -0.038171947f, 0.0f, 0.010779077f, 0.03661853f, 0.9992713f, 0.0f, 1.0063896f, 0.41162872f, 2.6653278f, 1.0f}, 0, 0},
    {3.682, 1, 0, 106, 106, 1, 1, 3, 1, {-3.6699066f, 28.788246f, 7.5418123f}, {0.99819905f, 0.059987787f, -0.00025085505f, 0.0f, -0.059976652f, 0.99807954f, 0.01549834f, 0.0f, 0.001180064f, -0.01545537f, 0.99987984f, 0.0f, -1.0048676f, 1.7982635f, 0.10868943f, 1.0f}, 1, 0},
    {3.682, 2, 1, 105, 105, 0, 1, 3, 1, {5.0532455f, 14.1324005f, 1.9840448f}, {0.95895535f, -0.28355727f, -5.190482e-05f, 0.0f, 0.28335017f, 0.9582616f, -0.038045973f, 0.0f, 0.010837869f, 0.036469746f, 0.99927604f, 0.0f, 1.0085449f, 0.41098785f, 2.6654515f, 1.0f}, 0, 0},
    {3.7074, 1, 0, 106, 106, 1, 1, 3, 1, {-3.734558f, 28.746956f, 7.4137052f}, {0.9971276f, 0.07573946f, -0.00048153487f, 0.0f, -0.075517416f, 0.9946524f, 0.0704557f, 0.0f, 0.005815243f, -0.07021697f, 0.9975148f, 0.0f, -1.0224113f, 1.7916336f, 0.177315f, 1.0f}, 1, 0},
    {3.7074, 2, 1, 105, 105, 0, 1, 3, 1, {5.1404705f, 14.069984f, 1.9354786f}, {0.9574975f, -0.28844163f, -4.780304e-05f, 0.0f, 0.288219f, 0.956765f, -0.039121926f, 0.0f, 0.011330125f, 0.037445374f, 0.99923444f, 0.0f, 1.0128345f, 0.40975952f, 2.66439474f, 1.0f}, 0, 0},
    {3.7329, 1, 0, 106, 106, 1, 1, 3, 1, {-3.7574196f, 28.71106f, 7.3520063f}, {0.99685025f, 0.07930407f, -0.0006552007f, 0.0f, -0.07877643f, 0.9911039f, 0.10727292f, 0.0f, 0.009156555f, -0.10688352f, 0.9942293f, 0.0f, -1.0259457f, 1.7855759f, 0.223212f, 1.0f}, 0, 0},
    {3.7329, 2, 1, 105, 105, 0, 1, 3, 1, {5.2122116f, 14.023399f, 1.8987734f}, {0.9562265f, -0.29262722f, -4.2250613e-05f, 0.0f, 0.2923843f, 0.95543873f, -0.04059872f, 0.0f, 0.011920648f, 0.03880919f, 0.9991755f, 0.0f, 1.0165176f, 0.40870667f, 2.66294396f, 1.0f}, 0, 0},
    {3.7575, 1, 0, 106, 106, 1, 1, 3, 1, {-3.780922f, 28.658844f, 7.250708f}, {0.9967456f, 0.08060782f, -0.0009412165f, 0.0f, -0.07938583f, 0.9835312f, 0.16237205f, 0.0f, 0.014014194f, -0.16176891f, 0.986729f, 0.0f, -1.0263348f, 1.7736435f, 0.29178298f, 1.0f}, 1, 0},
    {3.7575, 2, 1, 105, 105, 0, 1, 3, 1, {5.336893f, 13.943634f, 1.854352f}, {0.95386356f, -0.30024055f, -3.22836e-05f, 0.0f, 0.29995775f, 0.9529695f, -0.04329434f, 0.0f, 0.013029456f, 0.041287236f, 0.9990623f, 0.0f, 1.0232143f, 0.4067459f, 2.6602956f, 1.0f}, 0, 0},
    {3.7836, 1, 0, 106, 106, 1, 1, 3, 1, {-3.7898636f, 28.627014f, 7.1768373f}, {0.99672025f, 0.08091679f, -0.0011335505f, 0.0f, -0.07911418f, 0.9772717f, 0.19667563f, 0.0f, 0.017022142f, -0.19594087f, 0.9804679f, 0.0f, -1.0258179f, 1.7642746f, 0.33440185f, 1.0f}, 1, 0},
    {3.7836, 2, 1, 105, 105, 0, 1, 3, 1, {5.432537f, 13.878319f, 1.8177708f}, {0.9519759f, -0.30617312f, -2.4909503e-05f, 0.0f, 0.3058581f, 0.9510001f, -0.045273542f, 0.0f, 0.0138852075f, 0.04309169f, 0.9989746f, 0.0f, 1.0284328f, 0.40516663f, 2.65835059f, 1.0f}, 0, 0},
    {3.8095, 1, 0, 106, 106, 1, 1, 3, 1, {-3.8211403f, 28.589767f, 7.105949f}, {0.9966622f, 0.081628844f, -0.0012614523f, 0.0f, -0.079379916f, 0.972582f, 0.21859473f, 0.0f, 0.019070435f, -0.21776488f, 0.975815f, 0.0f, -1.0259743f, 1.757431f, 0.3616048f, 1.0f}, 0, 0},
    {3.8095, 2, 1, 105, 105, 1, 1, 3, 1, {5.524561f, 13.810181f, 1.7821441f}, {0.94979995f, -0.3128578f, -1.6564154e-05f, 0.0f, 0.31250417f, 0.94872886f, -0.047485173f, 0.0f, 0.014871808f, 0.04509628f, 0.998872f, 0.0f, 1.0343113f, 0.4033432f, 2.6561768f, 1.0f}, 1, 0},
    {3.8365, 1, 0, 106, 106, 1, 1, 3, 1, {-3.866253f, 28.535881f, 7.0061296f}, {0.9966045f, 0.08232721f, -0.0013633864f, 0.0f, -0.079689085f, 0.96857095f, 0.2356273f, 0.0f, 0.020719051f, -0.23471859f, 0.9718425f, 0.0f, -1.0262089f, 1.7516556f, 0.38272715f, 1.0f}, 1, 0},
    {3.8365, 2, 1, 0, 105, 1, 1, 3, 1, {5.6992035f, 13.615021f, 1.71612436f}, {0.9482311f, -0.31758082f, -3.851019e-06f, 0.0f, 0.31716907f, 0.9470024f, -0.050893277f, 0.0f, 0.01616637f, 0.048257433f, 0.9987041f, 0.0f, 1.0384846f, 0.40208435f, 2.6528263f, 1.0f}, 0, 0},
    {3.8612, 1, 0, 106, 106, 1, 1, 3, 1, {-3.9196224f, 28.826736f, 7.122701f}, {0.9964951f, 0.083639055f, -0.0013947645f, 0.0f, -0.08084257f, 0.9671919f, 0.24084082f, 0.0f, 0.021492833f, -0.23988405f, 0.9705635f, 0.0f, -1.0274754f, 1.7497101f, 0.3891896f, 1.0f}, 1, 0},
    {3.8612, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {3.8866, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {3.8866, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {3.9112, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {3.9112, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {3.9371, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {3.9371, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {3.9619, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {3.9619, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {3.9864, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {3.9864, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.0112, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.0112, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.0359, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.0359, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.0594, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.0594, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.0831, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.0831, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.1079, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.1079, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.1323, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.1323, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.1559, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.1559, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.1812, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.1812, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.2064, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.2064, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.2306, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.2306, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.2556, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.2556, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.2809, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.2809, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.3052, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.3052, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.3294, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.3294, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.3538, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.3538, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.3795, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.3795, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.4033, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.4033, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.4283, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.4283, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.4527, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.4527, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.4764, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.4764, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.5002, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.5002, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.5247, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.5247, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.5491, 1, 0, 0, 106, 1, 1, 32, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 0, 1},
    {4.5491, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.5734, 1, 0, 107, 106, 1, 1, 3, 1, {-3.9205341f, 28.822548f, 7.1390861f}, {0.9963473f, 0.0853819f, -0.0014210773f, 0.0f, -0.08242992f, 0.96597993f, 0.24512944f, 0.0f, 0.022302337f, -0.24411695f, 0.96948934f, 0.0f, -1.0292397f, 1.7480164f, 0.39450467f, 1.0f}, 1, 1},
    {4.5734, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.597, 1, 0, 107, 107, 1, 1, 3, 1, {2.2966194f, 30.865608f, -0.7738236f}, {0.99845046f, 0.055633552f, -0.0014095072f, 0.0f, -0.053620517f, 0.9684864f, 0.2432271f, 0.0f, 0.014896566f, -0.24277452f, 0.96996844f, 0.0f, -0.9967003f, 1.7509613f, 0.39214718f, 1.0f}, 0, 0},
    {4.597, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.6217, 1, 0, 107, 107, 1, 1, 3, 1, {2.1993713f, 30.842255f, -0.76173306f}, {0.9994196f, -0.03404188f, -0.0013530743f, 0.0f, 0.033413693f, 0.9716771f, 0.2339387f, 0.0f, -0.0066490443f, -0.23384807f, 0.97225046f, 0.0f, -0.89834976f, 1.7551498f, 0.3806337f, 1.0f}, 1, 0},
    {4.6217, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.6457, 1, 0, 107, 107, 1, 1, 3, 1, {2.20364f, 30.80571f, -0.74823713f}, {0.9970318f, -0.07698421f, -0.0012531147f, 0.0f, 0.07541793f, 0.97321045f, 0.21719593f, 0.0f, -0.015501173f, -0.21664569f, 0.97612727f, 0.0f, -0.8507843f, 1.7580414f, 0.35986948f, 1.0f}, 1, 0},
    {4.6457, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.6697, 1, 0, 107, 107, 1, 1, 3, 1, {2.2483006f, 30.755348f, -0.715294f}, {0.99537003f, -0.09611179f, -0.001054003f, 0.0f, 0.09468593f, 0.9785992f, 0.18269736f, 0.0f, -0.016527971f, -0.18195117f, 0.98316866f, 0.0f, -0.8287754f, 1.76651f, 0.317042f, 1.0f}, 0, 0},
    {4.6697, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.6931, 1, 0, 107, 107, 1, 1, 3, 1, {2.2705727f, 30.708557f, -0.6727197f}, {0.994361f, -0.10604648f, -0.00084758655f, 0.0f, 0.10504906f, 0.9838499f, 0.1449287f, 0.0f, -0.01453529f, -0.14420047f, 0.9894417f, 0.0f, -0.81679153f, 1.7748795f, 0.27008998f, 1.0f}, 1, 0},
    {4.6931, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.7172, 1, 0, 107, 107, 1, 1, 3, 1, {2.275406f, 30.662369f, -0.6635877f}, {0.99371606f, -0.11192996f, -0.00065485307f, 0.0f, 0.11135482f, 0.98798287f, 0.10719362f, 0.0f, -0.011351206f, -0.106592946f, 0.9942379f, 0.0f, -0.80939865f, 1.7818146f, 0.2231133f, 1.0f}, 1, 0},
    {4.7172, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.7411, 1, 0, 107, 107, 1, 1, 3, 1, {2.2685738f, 30.596786f, -0.65035856f}, {0.993332f, -0.115289174f, -0.000400625f, 0.0f, 0.11515324f, 0.99197966f, 0.05212146f, 0.0f, -0.005611635f, -0.051820055f, 0.99864066f, 0.0f, -0.80476f, 1.7893219f, 0.15443623f, 1.0f}, 0, 0},
    {4.7411, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 1, 1},
    {4.7652, 1, 0, 107, 107, 1, 1, 3, 1, {2.2617836f, 30.554657f, -0.6461032f}, {0.9931033f, -0.1172428f, -0.000298739f, 0.0f, 0.11720612f, 0.99272263f, 0.027657866f, 0.0f, -0.0029461314f, -0.027502203f, 0.9996174f, 0.0f, -0.80228615f, 1.7913742f, 0.12388492f, 1.0f}, 1, 0},
    {4.7652, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.789, 1, 0, 107, 107, 1, 1, 3, 1, {2.251089f, 30.51294f, -0.66473466f}, {0.9929259f, -0.11873557f, -0.00023981609f, 0.0f, 0.11872916f, 0.99284667f, 0.012607902f, 0.0f, -0.0012589581f, -0.012547113f, 0.9999205f, 0.0f, -0.80046844f, 1.7922211f, 0.10507643f, 1.0f}, 0, 0},
    {4.789, 2, 1, 0, 105, 1, 1, 3, 1, {5.575968f, 13.735611f, 1.7411771f}, {0.9466995f, -0.3221182f, 1.238077e-06f, 0.0f, 0.32167813f, 0.94540596f, -0.052258074f, 0.0f, 0.016832126f, 0.04947304f, 0.99863356f, 0.0f, 1.0424709f, 0.40077972f, 2.6514843f, 1.0f}, 0, 1},
    {4.8132, 1, 0, 107, 107, 1, 1, 3, 1, {2.2410698f, 30.472466f, -0.67304075f}, {0.9927856f, -0.11990344f, -0.00020384241f, 0.0f, 0.119903475f, 0.99278086f, 0.0030882657f, 0.0f, -0.00016791455f, -0.0030904491f, 0.9999952f, 0.0f, -0.7990761f, 1.7925797f, 0.0931741f, 1.0f}, 1, 0},
    {4.8132, 2, 1, 108, 108, 1, 1, 3, 1, {7.4310074f, 13.570343f, 1.7820427f}, {0.93661404f, -0.35036257f, 8.743955e-07f, 0.0f, 0.3498858f, 0.9353393f, -0.052157164f, 0.0f, 0.018273108f, 0.04885146f, 0.9986388f, 0.0f, 1.0672092f, 0.3919525f, 2.6515836f, 1.0f}, 0, 0},
    {4.8377, 1, 0, 107, 107, 1, 1, 3, 1, {2.2302303f, 30.413597f, -0.6756817f}, {0.9928251f, -0.11957629f, -0.0001743891f, 0.0f, 0.11957397f, 0.99281317f, -0.0049296618f, 0.0f, 0.0007626537f, 0.0048733624f, 0.9999878f, 0.0f, -0.7994137f, 1.7929764f, 0.083146095f, 1.0f}, 1, 0},
    {4.8377, 2, 1, 108, 108, 1, 1, 3, 1, {7.392462f, 13.589615f, 1.78244585f}, {0.915003f, -0.40344673f, -3.366731e-07f, 0.0f, 0.40290418f, 0.91377246f, -0.05184695f, 0.0f, 0.0209178f, 0.04744004f, 0.998655f, 0.0f, 1.1137009f, 0.373024f, 2.6518886f, 1.0f}, 1, 0},
    {4.8621, 1, 0, 107, 107, 1, 1, 3, 1, {2.221716f, 30.375816f, -0.67444944f}, {0.99271303f, -0.120503165f, -0.0001641761f, 0.0f, 0.12049827f, 0.99268365f, -0.007724583f, 0.0f, 0.0010938018f, 0.007648493f, 0.9999702f, 0.0f, -0.79834175f, 1.7929535f, 0.079649806f, 1.0f}, 0, 0},
    {4.8621, 2, 1, 108, 108, 1, 1, 3, 1, {7.3964767f, 13.587326f, 1.7836835f}, {0.90414274f, -0.42723086f, -2.878718e-06f, 0.0f, 0.4266704f, 0.90295655f, -0.051207274f, 0.0f, 0.021879854f, 0.046297677f, 0.9986881f, 0.0f, 1.1345253f, 0.3635025f, 2.6525176f, 1.0f}, 0, 0},
    {4.8856, 1, 0, 107, 107, 1, 1, 3, 1, {2.210493f, 30.339294f, -0.67248744f}, {0.992685f, -0.120733775f, -0.00015772099f, 0.0f, 0.12072691f, 0.99264044f, -0.009503573f, 0.0f, 0.0013039045f, 0.009415087f, 0.99995494f, 0.0f, -0.7980709f, 1.7929764f, 0.07742429f, 1.0f}, 1, 0},
    {4.8856, 2, 1, 0, 108, 1, 1, 3, 1, {7.4530945f, 13.516739f, 1.7899885f}, {0.89983076f, -0.43623927f, -5.364185e-06f, 0.0f, 0.43568245f, 0.8986824f, -0.050506115f, 0.0f, 0.022037536f, 0.045444727f, 0.9987238f, 0.0f, 1.1424065f, 0.3597107f, 2.6532069f, 1.0f}, 0, 0},
    {4.9099, 1, 0, 107, 107, 1, 1, 3, 1, {2.2032185f, 30.303612f, -0.67037344f}, {0.9926203f, -0.12126422f, -0.00015383447f, 0.0f, 0.12125594f, 0.9925654f, -0.01053825f, 0.0f, 0.0014305955f, 0.010441831f, 0.99994445f, 0.0f, -0.79746056f, 1.7929382f, 0.076129794f, 1.0f}, 1, 0},
    {4.9099, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {4.9353, 1, 0, 107, 107, 1, 1, 3, 1, {2.1885643f, 30.25393f, -0.6704825f}, {0.9925576f, -0.121775836f, -0.00015126239f, 0.0f, 0.1217665f, 0.99249494f, -0.011253893f, 0.0f, 0.0015205268f, 0.011151756f, 0.99993664f, 0.0f, -0.7968712f, 1.7928925f, 0.07523441f, 1.0f}, 0, 0},
    {4.9353, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {4.9601, 1, 0, 107, 107, 1, 1, 3, 1, {2.1817055f, 30.22293f, -0.67259526f}, {0.9926424f, -0.121084765f, -0.00015036529f, 0.0f, 0.121075176f, 0.99257714f, -0.011479735f, 0.0f, 0.0015392137f, 0.011377162f, 0.9999341f, 0.0f, -0.79766273f, 1.7929916f, 0.07495189f, 1.0f}, 1, 0},
    {4.9601, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {4.9841, 1, 0, 107, 107, 1, 1, 3, 1, {2.173111f, 30.193443f, -0.67545605f}, {0.99256605f, -0.1217064f, -0.00014952803f, 0.0f, 0.12169629f, 0.99249864f, -0.011678994f, 0.0f, 0.0015699011f, 0.011573936f, 0.9999317f, 0.0f, -0.7969494f, 1.7929077f, 0.0747025f, 1.0f}, 1, 0},
    {4.9841, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.0083, 1, 0, 107, 107, 1, 1, 3, 1, {2.1615372f, 30.165543f, -0.6792614f}, {0.9925814f, -0.12158282f, -0.0001489895f, 0.0f, 0.121572554f, 0.9925122f, -0.01183936f, 0.0f, 0.0015873024f, 0.011733419f, 0.9999299f, 0.0f, -0.79709244f, 1.7929306f, 0.07450187f, 1.0f}, 0, 0},
    {5.0083, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.0333, 1, 0, 107, 107, 1, 1, 3, 1, {2.1489563f, 30.125282f, -0.6876523f}, {0.9927581f, -0.12013281f, -0.00014779263f, 0.0f, 0.120122164f, 0.99268484f, -0.0121772885f, 0.0f, 0.0016095288f, 0.012071386f, 0.99992585f, 0.0f, -0.7987499f, 1.7931442f, 0.07407904f, 1.0f}, 1, 0},
    {5.0333, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.0577, 1, 0, 107, 107, 1, 1, 3, 1, {2.1384811f, 30.100471f, -0.69455606f}, {0.9927246f, -0.12040748f, -0.00014677586f, 0.0f, 0.12039629f, 0.9926483f, -0.012414008f, 0.0f, 0.001640527f, 0.012305947f, 0.9999229f, 0.0f, -0.7984352f, 1.7931137f, 0.07378292f, 1.0f}, 1, 0},
    {5.0577, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.082, 1, 0, 107, 107, 1, 1, 3, 1, {2.1247368f, 30.077454f, -0.70232487f}, {0.99275225f, -0.120180055f, -0.00014605722f, 0.0f, 0.120168746f, 0.99267304f, -0.012662262f, 0.0f, 0.0016666503f, 0.012553064f, 0.9999199f, 0.0f, -0.7986927f, 1.7931519f, 0.07347226f, 1.0f}, 0, 0},
    {5.082, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.1058, 1, 0, 107, 107, 1, 1, 3, 1, {2.114376f, 30.055725f, -0.7096061f}, {0.9928456f, -0.11940559f, -0.00014533859f, 0.0f, 0.11939385f, 0.9927636f, -0.012876719f, 0.0f, 0.0016817573f, 0.012767308f, 0.99991703f, 0.0f, -0.7995796f, 1.7932663f, 0.07320392f, 1.0f}, 1, 0},
    {5.1058, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.1305, 1, 0, 107, 107, 1, 1, 3, 1, {2.0943012f, 30.026924f, -0.7209555f}, {0.9928134f, -0.11967208f, -0.00014438143f, 0.0f, 0.11965997f, 0.99272835f, -0.013109773f, 0.0f, 0.0017121823f, 0.012998282f, 0.99991405f, 0.0f, -0.79927444f, 1.7932358f, 0.072912335f, 1.0f}, 1, 0},
    {5.1305, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.1549, 1, 0, 107, 107, 1, 1, 3, 1, {2.0823288f, 30.009674f, -0.7279301f}, {0.99287605f, -0.1191517f, -0.0001430047f, 0.0f, 0.119139045f, 0.9927863f, -0.013478011f, 0.0f, 0.0017478741f, 0.013365016f, 0.9999091f, 0.0f, -0.79986954f, 1.7933197f, 0.07245159f, 1.0f}, 0, 0},
    {5.1549, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.1803, 1, 0, 107, 107, 1, 1, 3, 1, {2.070572f, 29.99347f, -0.73394704f}, {0.9928172f, -0.11964233f, -0.00014222658f, 0.0f, 0.11962926f, 0.9927245f, -0.013685495f, 0.0f, 0.0017785263f, 0.013570237f, 0.9999063f, 0.0f, -0.79930687f, 1.7932587f, 0.07219195f, 1.0f}, 1, 0},
    {5.1803, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.2046, 1, 0, 107, 107, 1, 1, 3, 1, {2.0481224f, 29.97165f, -0.7411978f}, {0.9927068f, -0.120555f, -0.00014114927f, 0.0f, 0.12054132f, 0.99261034f, -0.013957918f, 0.0f, 0.0018228206f, 0.013839126f, 0.9999025f, 0.0f, -0.79826164f, 1.7931366f, 0.071851134f, 1.0f}, 1, 0},
    {5.2046, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.231, 1, 0, 107, 107, 1, 1, 3, 1, {2.0365906f, 29.958542f, -0.74434125f}, {0.99270546f, -0.12056425f, -0.00014037103f, 0.0f, 0.12055015f, 0.9926062f, -0.014159292f, 0.0f, 0.0018465124f, 0.014039011f, 0.99989957f, 0.0f, -0.7982502f, 1.7931442f, 0.071599126f, 1.0f}, 0, 0},
    {5.231, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.2554, 1, 0, 107, 107, 1, 1, 3, 1, {2.0225716f, 29.94741f, -0.7473007f}, {0.9926915f, -0.120678045f, -0.0001401311f, 0.0f, 0.120663844f, 0.99259096f, -0.01425612f, 0.0f, 0.001859457f, 0.014135048f, 0.9998983f, 0.0f, -0.7981186f, 1.793129f, 0.07147789f, 1.0f}, 1, 0},
    {5.2554, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.2809, 1, 0, 107, 107, 1, 1, 3, 1, {2.0058022f, 29.933777f, -0.75108206f}, {0.9928593f, -0.11929305f, -0.00013977196f, 0.0f, 0.1192789f, 0.9927573f, -0.014352441f, 0.0f, 0.0018508143f, 0.014233375f, 0.999897f, 0.0f, -0.7997036f, 1.7933273f, 0.07135737f, 1.0f}, 1, 0},
    {5.2809, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.3048, 1, 0, 107, 107, 1, 1, 3, 1, {1.9945927f, 29.926468f, -0.7528154f}, {0.99304175f, -0.11776234f, -0.00013893365f, 0.0f, 0.11774784f, 0.9929366f, -0.014575183f, 0.0f, 0.001854402f, 0.014457366f, 0.99989367f, 0.0f, -0.80145645f, 1.793541f, 0.07107866f, 1.0f}, 0, 0},
    {5.3048, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.3303, 1, 0, 107, 107, 1, 1, 3, 1, {1.9831276f, 29.919968f, -0.75427943f}, {0.99321645f, -0.11628061f, -0.00013887358f, 0.0f, 0.11626623f, 0.99311084f, -0.014601916f, 0.0f, 0.0018358314f, 0.01448671f, 0.9998933f, 0.0f, -0.8031521f, 1.7937393f, 0.07104528f, 1.0f}, 1, 0},
    {5.3303, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.355, 1, 0, 107, 107, 1, 1, 3, 1, {1.972084f, 29.914047f, -0.75615937f}, {0.99320745f, -0.11635684f, -0.00013905345f, 0.0f, 0.11634257f, 0.9931028f, -0.014539421f, 0.0f, 0.0018298514f, 0.014424506f, 0.99989426f, 0.0f, -0.80306625f, 1.7937317f, 0.07112348f, 1.0f}, 1, 0},
    {5.355, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.3809, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.3809, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.4057, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.4057, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.43, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.43, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.4539, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.4539, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.4783, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.4783, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.5023, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.5023, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.5265, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.5265, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.5515, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.5515, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.5763, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.5763, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.601, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.601, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.6253, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.6253, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.6492, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.6492, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.6739, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.6739, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.6992, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.6992, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.7233, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.7233, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.7479, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.7479, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.7729, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.7729, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 1},
    {5.7982, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.7982, 2, 1, 0, 108, 1, 1, 3, 1, {7.4329205f, 13.569656f, 1.7847588f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 1, 1},
    {5.8226, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.8226, 2, 1, 109, 109, 1, 1, 3, 1, {6.75922f, 10.845947f, 1.72353953f}, {0.8981091f, -0.4397727f, -6.2742038e-06f, 0.0f, 0.43921718f, 0.89697534f, -0.05023426f, 0.0f, 0.022097308f, 0.04511304f, 0.99873745f, 0.0f, 1.1454964f, 0.35820007f, 2.65347421f, 1.0f}, 0, 0},
    {5.8478, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.8478, 2, 1, 109, 109, 1, 1, 3, 1, {6.7298775f, 10.876907f, 1.7062968f}, {0.88171756f, -0.47177762f, 2.5140587e-05f, 0.0f, 0.47096545f, 0.8801962f, -0.058704823f, 0.0f, 0.02767342f, 0.051773116f, 0.99827546f, 0.0f, 1.173645f, 0.3440628f, 2.645143f, 1.0f}, 0, 0},
    {5.8719, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.8719, 2, 1, 109, 109, 1, 1, 3, 1, {6.7421684f, 10.88205f, 1.7012227f}, {0.87946284f, -0.47596762f, 4.191068e-05f, 0.0f, 0.47501904f, 0.87770456f, -0.06317958f, 0.0f, 0.030034658f, 0.055584013f, 0.9980022f, 0.0f, 1.1773624f, 0.34217834f, 2.64073956f, 1.0f}, 0, 0},
    {5.8963, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.8963, 2, 1, 109, 109, 1, 1, 3, 1, {6.7493935f, 10.888115f, 1.6929612f}, {0.87883115f, -0.47713274f, 5.2554416e-05f, 0.0f, 0.47609556f, 0.87691355f, -0.06599623f, 0.0f, 0.03144289f, 0.058024522f, 0.99781984f, 0.0f, 1.1784096f, 0.3416748f, 2.6379669f, 1.0f}, 1, 0},
    {5.9206, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.9206, 2, 1, 0, 109, 1, 1, 3, 1, {6.7521763f, 10.890877f, 1.68898016f}, {0.87719685f, -0.48013085f, 5.888508e-05f, 0.0f, 0.47903335f, 0.87518346f, -0.067682296f, 0.0f, 0.032444883f, 0.0593988f, 0.99770683f, 0.0f, 1.1810513f, 0.340271f, 2.6363068f, 1.0f}, 0, 1},
    {5.9449, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {5.9449, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {5.9701, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.9701, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {5.9944, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {5.9944, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.0197, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {6.0197, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.044, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.044, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.0689, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.0689, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.0946, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {6.0946, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.118, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.118, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.1422, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {6.1422, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.1665, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.1665, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.1914, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.1914, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.2156, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {6.2156, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.2398, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.2398, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.265, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.265, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.289, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 1},
    {6.289, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.3154, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.3154, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.3413, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 1, 1},
    {6.3413, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.3673, 1, 0, 0, 107, 1, 1, 32, 1, {1.9697857f, 29.914276f, -0.7562039f}, {0.9932588f, -0.11592056f, -0.00013887335f, 0.0f, 0.11590621f, 0.99315286f, -0.014620334f, 0.0f, 0.0018326871f, 0.014505734f, 0.9998931f, 0.0f, -0.8035641f, 1.7937927f, 0.07102215f, 1.0f}, 0, 0},
    {6.3673, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.3939, 1, 0, 0, 0, 0, 1, 32, 1, {-6.5184727f, -7.753647f, 0.044144988f}, {0.9969185f, -0.07844522f, -0.00011405721f, 0.0f, 0.07842506f, 0.99669284f, -0.021283567f, 0.0f, 0.0017833033f, 0.021209035f, 0.99977344f, 0.0f, -0.84646034f, 1.798172f, 0.06268346f, 1.0f}, 0, 0},
    {6.3939, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.4208, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9979619f, -0.06381267f, -0.00010204909f, 0.0f, 0.06379103f, 0.99766153f, -0.024543136f, 0.0f, 0.0016679105f, 0.024486633f, 0.9996987f, 0.0f, -0.8632126f, 1.7994385f, 0.058603525f, 1.0f}, 0, 0},
    {6.4208, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.4456, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99678284f, -0.08015291f, -7.095386e-05f, 0.0f, 0.08010725f, 0.996244f, -0.032882005f, 0.0f, 0.0027062776f, 0.03277053f, 0.9994592f, 0.0f, -0.8444977f, 1.7981491f, 0.048163652f, 1.0f}, 0, 0},
    {6.4456, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.4697, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99599236f, -0.08943993f, -4.2310567e-05f, 0.0f, 0.089364514f, 0.9951716f, -0.04059115f, 0.0f, 0.0036726175f, 0.040424716f, 0.9991758f, 0.0f, -0.8338642f, 1.797226f, 0.038509488f, 1.0f}, 0, 0},
    {6.4697, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.4938, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99578863f, -0.09168088f, -3.1315605e-05f, 0.0f, 0.09159258f, 0.9948428f, -0.043578506f, 0.0f, 0.004026411f, 0.043392166f, 0.99905f, 0.0f, -0.83130074f, 1.7969666f, 0.034767628f, 1.0f}, 0, 0},
    {6.4938, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.518, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99568635f, -0.09278341f, -2.3521134e-05f, 0.0f, 0.09268582f, 0.9946507f, -0.04560098f, 0.0f, 0.004254484f, 0.045402043f, 0.99895966f, 0.0f, -0.8300419f, 1.7968292f, 0.032234192f, 1.0f}, 0, 0},
    {6.518, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.5436, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9956375f, -0.0933084f, -1.8619932e-05f, 0.0f, 0.09320464f, 0.99453944f, -0.046954304f, 0.0f, 0.004399685f, 0.046747744f, 0.998897f, 0.0f, -0.8294411f, 1.7967529f, 0.030538797f, 1.0f}, 0, 0},
    {6.5436, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.5683, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9955952f, -0.09375666f, -1.3477402e-05f, 0.0f, 0.09364654f, 0.9944322f, -0.048321366f, 0.0f, 0.0045437766f, 0.048107296f, 0.99883187f, 0.0f, -0.8289299f, 1.7966843f, 0.028826118f, 1.0f}, 0, 0},
    {6.5683, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.5953, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9955747f, -0.093974434f, -1.1117314e-05f, 0.0f, 0.09386125f, 0.99438155f, -0.048946887f, 0.0f, 0.0046108062f, 0.048729245f, 0.9988014f, 0.0f, -0.82868195f, 1.7966537f, 0.028042436f, 1.0f}, 0, 0},
    {6.5953, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.6205, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9955457f, -0.09428166f, -8.453499e-06f, 0.0f, 0.094164886f, 0.9943175f, -0.049658984f, 0.0f, 0.0046904404f, 0.049436923f, 0.9987661f, 0.0f, -0.8283329f, 1.796608f, 0.027150273f, 1.0f}, 0, 0},
    {6.6205, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.6455, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9955265f, -0.09448418f, -7.1208924e-06f, 0.0f, 0.0943656f, 0.99428004f, -0.050026298f, 0.0f, 0.004733676f, 0.049801867f, 0.9987479f, 0.0f, -0.8281002f, 1.7965775f, 0.026690006f, 1.0f}, 0, 0},
    {6.6455, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.6705, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.995511f, -0.0946492f, -6.030081e-06f, 0.0f, 0.09452893f, 0.9942492f, -0.050332308f, 0.0f, 0.004769899f, 0.05010582f, 0.99873257f, 0.0f, -0.8279114f, 1.7965622f, 0.02630663f, 1.0f}, 0, 0},
    {6.6705, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.6953, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954966f, -0.09479833f, -4.8199436e-06f, 0.0f, 0.0946765f, 0.99421954f, -0.050635755f, 0.0f, 0.004804984f, 0.050407227f, 0.9987171f, 0.0f, -0.8277416f, 1.7965393f, 0.02592647f, 1.0f}, 0, 0},
    {6.6953, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.7203, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954749f, -0.095025696f, -3.3053802e-06f, 0.0f, 0.094901666f, 0.9941769f, -0.05104956f, 0.0f, 0.0048543066f, 0.050818294f, 0.99869615f, 0.0f, -0.8274822f, 1.7965012f, 0.02540803f, 1.0f}, 0, 0},
    {6.7203, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.7455, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954634f, -0.09514408f, -2.2775494e-06f, 0.0f, 0.09501865f, 0.9941532f, -0.05128947f, 0.0f, 0.0048822337f, 0.05105656f, 0.99868375f, 0.0f, -0.8273468f, 1.7964783f, 0.025107384f, 1.0f}, 0, 0},
    {6.7455, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 1, 1},
    {6.771, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954502f, -0.09528292f, -1.4882535e-06f, 0.0f, 0.09515625f, 0.99412775f, -0.051531434f, 0.0f, 0.0049115596f, 0.05129686f, 0.99867135f, 0.0f, -0.8271885f, 1.796463f, 0.024804235f, 1.0f}, 0, 0},
    {6.771, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.7973, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954327f, -0.0954666f, -1.5646219e-07f, 0.0f, 0.09533806f, 0.9940927f, -0.051870674f, 0.0f, 0.004952102f, 0.051633738f, 0.9986538f, 0.0f, -0.8269787f, 1.7964401f, 0.024379134f, 1.0f}, 0, 0},
    {6.7973, 2, 1, 0, 109, 1, 1, 3, 1, {6.752922f, 10.890297f, 1.68695527f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 1},
    {6.8225, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954238f, -0.0955596f, 5.704351e-07f, 0.0f, 0.09543003f, 0.9940738f, -0.052062422f, 0.0f, 0.0049745077f, 0.051824156f, 0.9986438f, 0.0f, -0.8268719f, 1.7964249f, 0.024138927f, 1.0f}, 0, 0},
    {6.8225, 2, 1, 110, 110, 1, 1, 3, 1, {10.406673f, 14.337746f, 1.69389015f}, {0.87595874f, -0.48238623f, 6.0654245e-05f, 0.0f, 0.48126695f, 0.8739176f, -0.06819382f, 0.0f, 0.03284277f, 0.05976421f, 0.9976721f, 0.0f, 1.1830311f, 0.33919525f, 2.6358031f, 1.0f}, 0, 0},
    {6.8477, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99541235f, -0.095679194f, 1.3590325e-06f, 0.0f, 0.095548406f, 0.9940507f, -0.052286655f, 0.0f, 0.0050013745f, 0.052046902f, 0.9986321f, 0.0f, -0.82673645f, 1.7964096f, 0.023857951f, 1.0f}, 0, 0},
    {6.8477, 2, 1, 110, 110, 1, 1, 3, 1, {10.375309f, 14.361206f, 1.6879532f}, {0.8527817f, -0.5222674f, 3.78337e-05f, 0.0f, 0.52126324f, 0.8511376f, -0.06204179f, 0.0f, 0.032370195f, 0.05292777f, 0.9980736f, 0.0f, 1.2179184f, 0.31879425f, 2.64185941f, 1.0f}, 1, 0},
    {6.8737, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99540263f, -0.09578081f, 1.7235288e-06f, 0.0f, 0.09564941f, 0.9940351f, -0.05240035f, 0.0f, 0.005017165f, 0.052159637f, 0.9986262f, 0.0f, -0.8266182f, 1.7963943f, 0.023715496f, 1.0f}, 0, 0},
    {6.8737, 2, 1, 110, 110, 1, 1, 3, 1, {10.393356f, 14.355591f, 1.68258113f}, {0.8479806f, -0.53002745f, 2.259051e-05f, 0.0f, 0.5291357f, 0.84655136f, -0.05802092f, 0.0f, 0.0307335f, 0.0492127f, 0.9983154f, 0.0f, 1.2246685f, 0.31450653f, 2.64581597f, 1.0f}, 0, 0},
    {6.8983, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99539065f, -0.09590423f, 2.0872103e-06f, 0.0f, 0.09577207f, 0.99401796f, -0.052499205f, 0.0f, 0.0050328146f, 0.052257407f, 0.998621f, 0.0f, -0.82647896f, 1.7963715f, 0.023591638f, 1.0f}, 0, 0},
    {6.8983, 2, 1, 110, 110, 1, 1, 3, 1, {10.403545f, 14.37075f, 1.676692f}, {0.8445477f, -0.5354802f, 1.0453281e-05f, 0.0f, 0.53467774f, 0.84328127f, -0.054739922f, 0.0f, 0.02930332f, 0.04623605f, 0.9985006f, 0.0f, 1.2293968f, 0.31143188f, 2.64904344f, 1.0f}, 0, 0},
    {6.924, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99537313f, -0.09608572f, 2.6329653e-06f, 0.0f, 0.095952615f, 0.9939927f, -0.052648127f, 0.0f, 0.005056088f, 0.052404802f, 0.99861306f, 0.0f, -0.82627106f, 1.7963486f, 0.023404956f, 1.0f}, 0, 0},
    {6.924, 2, 1, 110, 110, 1, 1, 3, 1, {10.406387f, 14.3918915f, 1.67120785f}, {0.843519f, -0.5370993f, 6.6322973e-06f, 0.0f, 0.53632456f, 0.8423017f, -0.053702444f, 0.0f, 0.02883799f, 0.045302622f, 0.998557f, 0.0f, 1.2308006f, 0.3105011f, 2.650064f, 1.0f}, 0, 0},
    {6.9504, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99536043f, -0.09621733f, 3.056135e-06f, 0.0f, 0.09608365f, 0.99397486f, -0.052746058f, 0.0f, 0.005072027f, 0.05250171f, 0.998608f, 0.0f, -0.8261204f, 1.7963333f, 0.02328229f, 1.0f}, 0, 0},
    {6.9504, 2, 1, 110, 110, 1, 1, 3, 1, {10.408657f, 14.42041f, 1.664683f}, {0.84293896f, -0.53800946f, 4.8148213e-06f, 0.0f, 0.5372468f, 0.8417436f, -0.053233296f, 0.0f, 0.02863597f, 0.04487512f, 0.9985821f, 0.0f, 1.2315903f, 0.3099823f, 2.650525f, 1.0f}, 1, 0},
    {6.9751, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953462f, -0.096363224f, 3.3595134e-06f, 0.0f, 0.0962288f, 0.9939561f, -0.0528329f, 0.0f, 0.005087806f, 0.05258731f, 0.99860334f, 0.0f, -0.82595444f, 1.796318f, 0.023173451f, 1.0f}, 0, 0},
    {6.9751, 2, 1, 0, 110, 1, 1, 3, 1, {10.408262f, 14.425575f, 1.677216f}, {0.8446295f, -0.5353511f, 3.2380922e-06f, 0.0f, 0.5346045f, 0.84345144f, -0.052796334f, 0.0f, 0.028261816f, 0.044595078f, 0.99860525f, 0.0f, 1.2292538f, 0.31144714f, 2.650955f, 1.0f}, 0, 0},
    {7.0004, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953229f, -0.09660618f, 3.7230784e-06f, 0.0f, 0.09647101f, 0.9939277f, -0.052927762f, 0.0f, 0.0051094666f, 0.052680615f, 0.99859834f, 0.0f, -0.82567406f, 1.7962875f, 0.0230546f, 1.0f}, 0, 0},
    {7.0004, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.0249, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99531037f, -0.09673333f, 4.025176e-06f, 0.0f, 0.096597664f, 0.99391174f, -0.052994788f, 0.0f, 0.0051223785f, 0.052746672f, 0.9985948f, 0.0f, -0.8255291f, 1.7962723f, 0.022970557f, 1.0f}, 0, 0},
    {7.0249, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.049, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99530005f, -0.09684063f, 4.3289037e-06f, 0.0f, 0.096704304f, 0.99389666f, -0.05308512f, 0.0f, 0.00513646f, 0.052836027f, 0.99858993f, 0.0f, -0.825407f, 1.796257f, 0.022857428f, 1.0f}, 0, 0},
    {7.049, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.0733, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952904f, -0.09693745f, 4.7528883e-06f, 0.0f, 0.096800394f, 0.9938813f, -0.053195447f, 0.0f, 0.0051519144f, 0.05294537f, 0.9985841f, 0.0f, -0.8252983f, 1.7962418f, 0.022719145f, 1.0f}, 0, 0},
    {7.0733, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.0981, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952773f, -0.09707173f, 5.3597614e-06f, 0.0f, 0.09693365f, 0.99385905f, -0.053367585f, 0.0f, 0.005175165f, 0.053116057f, 0.9985749f, 0.0f, -0.8251438f, 1.7962189f, 0.022503495f, 1.0f}, 0, 0},
    {7.0981, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.1229, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99527293f, -0.09711915f, 5.8446312e-06f, 0.0f, 0.09698038f, 0.9938476f, -0.053498417f, 0.0f, 0.005189929f, 0.053246137f, 0.998568f, 0.0f, -0.8250904f, 1.7962112f, 0.022339582f, 1.0f}, 0, 0},
    {7.1229, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.1467, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952713f, -0.09713371f, 6.691902e-06f, 0.0f, 0.09699386f, 0.9938353f, -0.05369982f, 0.0f, 0.005209447f, 0.053446468f, 0.99855703f, 0.0f, -0.82507324f, 1.7962189f, 0.022087097f, 1.0f}, 0, 0},
    {7.1467, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.1713, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952735f, -0.097112805f, 7.1172835e-06f, 0.0f, 0.09697243f, 0.9938304f, -0.0538314f, 0.0f, 0.0052206405f, 0.053577673f, 0.99855f, 0.0f, -0.82509804f, 1.7962036f, 0.02192223f, 1.0f}, 0, 0},
    {7.1713, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.1959, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952777f, -0.097069405f, 7.422408e-06f, 0.0f, 0.09692854f, 0.99382854f, -0.053944588f, 0.0f, 0.0052288887f, 0.053690653f, 0.9985439f, 0.0f, -0.8251476f, 1.7962112f, 0.02178049f, 1.0f}, 0, 0},
    {7.1959, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.2192, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952817f, -0.09702913f, 7.844879e-06f, 0.0f, 0.09688788f, 0.993828f, -0.054027945f, 0.0f, 0.005234467f, 0.05377389f, 0.9985395f, 0.0f, -0.8251934f, 1.7962112f, 0.021675944f, 1.0f}, 0, 0},
    {7.2192, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.2439, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99528474f, -0.09699785f, 8.148607e-06f, 0.0f, 0.09685621f, 0.99382627f, -0.054115713f, 0.0f, 0.0052409857f, 0.05386141f, 0.9985346f, 0.0f, -0.82522964f, 1.7962189f, 0.021566033f, 1.0f}, 0, 0},
    {7.2439, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.2679, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99528635f, -0.09697892f, 8.330215e-06f, 0.0f, 0.09683697f, 0.9938256f, -0.054160565f, 0.0f, 0.005244219f, 0.05390606f, 0.99853224f, 0.0f, -0.8252506f, 1.7962189f, 0.021509767f, 1.0f}, 0, 0},
    {7.2679, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.2922, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99529064f, -0.09693642f, 8.51287e-06f, 0.0f, 0.09679425f, 0.99382645f, -0.054222822f, 0.0f, 0.0052476632f, 0.053968303f, 0.9985289f, 0.0f, -0.8253002f, 1.7962189f, 0.021431804f, 1.0f}, 0, 0},
    {7.2922, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.3163, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9952946f, -0.09689594f, 8.876086e-06f, 0.0f, 0.09675345f, 0.99382555f, -0.054311037f, 0.0f, 0.005253657f, 0.054056417f, 0.9985241f, 0.0f, -0.8253479f, 1.7962265f, 0.021321297f, 1.0f}, 0, 0},
    {7.3163, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.3413, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.995301f, -0.096829675f, 9.421259e-06f, 0.0f, 0.09668652f, 0.99382466f, -0.05444616f, 0.0f, 0.005262644f, 0.054191183f, 0.9985167f, 0.0f, -0.8254242f, 1.7962265f, 0.0211519f, 1.0f}, 0, 0},
    {7.3413, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.3654, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953094f, -0.09674498f, 9.605312e-06f, 0.0f, 0.09660154f, 0.99382854f, -0.054528266f, 0.0f, 0.0052657705f, 0.054273408f, 0.9985122f, 0.0f, -0.82551956f, 1.7962341f, 0.021049023f, 1.0f}, 0, 0},
    {7.3654, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.3908, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953199f, -0.09663609f, 9.907992e-06f, 0.0f, 0.09649248f, 0.9938351f, -0.054600775f, 0.0f, 0.0052665286f, 0.05434615f, 0.9985082f, 0.0f, -0.82564545f, 1.7962494f, 0.020958185f, 1.0f}, 0, 0},
    {7.3908, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.4167, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953367f, -0.09646372f, 1.0211137e-05f, 0.0f, 0.09632003f, 0.99384755f, -0.054681957f, 0.0f, 0.005264602f, 0.054428022f, 0.9985038f, 0.0f, -0.8258438f, 1.7962646f, 0.0208565f, 1.0f}, 0, 0},
    {7.4167, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.4409, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99534696f, -0.09635682f, 1.03323255e-05f, 0.0f, 0.09621311f, 0.993856f, -0.0547134f, 0.0f, 0.005261698f, 0.054459855f, 0.9985021f, 0.0f, -0.8259659f, 1.7962799f, 0.020817041f, 1.0f}, 0, 0},
    {7.4409, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.4653, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99536425f, -0.09617759f, 1.0514865e-05f, 0.0f, 0.09603387f, 0.99386996f, -0.054772884f, 0.0f, 0.0052574268f, 0.05452008f, 0.99849886f, 0.0f, -0.8261719f, 1.7962952f, 0.020742536f, 1.0f}, 0, 0},
    {7.4653, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.4896, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953764f, -0.096052594f, 1.0696938e-05f, 0.0f, 0.095908836f, 0.99387944f, -0.054821998f, 0.0f, 0.0052551148f, 0.054569654f, 0.9984961f, 0.0f, -0.8263149f, 1.7963028f, 0.020680904f, 1.0f}, 0, 0},
    {7.4896, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.5146, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9953898f, -0.09591313f, 1.0998454e-05f, 0.0f, 0.095769234f, 0.9938899f, -0.05487579f, 0.0f, 0.005252344f, 0.05462387f, 0.99849313f, 0.0f, -0.82647324f, 1.796318f, 0.020613551f, 1.0f}, 0, 0},
    {7.5146, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.5389, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99540246f, -0.095781066f, 1.1240481e-05f, 0.0f, 0.095637046f, 0.99389946f, -0.0549317f, 0.0f, 0.0052502546f, 0.054680176f, 0.99849004f, 0.0f, -0.8266258f, 1.7963333f, 0.020543456f, 1.0f}, 0, 0},
    {7.5389, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.5634, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954178f, -0.09562267f, 1.1604745e-05f, 0.0f, 0.09547841f, 0.99390906f, -0.05503601f, 0.0f, 0.0052511077f, 0.054784946f, 0.9984843f, 0.0f, -0.826807f, 1.7963562f, 0.020412803f, 1.0f}, 0, 0},
    {7.5634, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.5868, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954281f, -0.09551531f, 1.1847587e-05f, 0.0f, 0.09537082f, 0.99391544f, -0.055105716f, 0.0f, 0.005251676f, 0.054854944f, 0.99848056f, 0.0f, -0.826931f, 1.7963638f, 0.020325422f, 1.0f}, 0, 0},
    {7.5868, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.6113, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99543804f, -0.09540949f, 1.2089615e-05f, 0.0f, 0.095264874f, 0.99392265f, -0.055158228f, 0.0f, 0.005250659f, 0.054907665f, 0.9984775f, 0.0f, -0.82705116f, 1.7963638f, 0.020259619f, 1.0f}, 0, 0},
    {7.6113, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.6358, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954525f, -0.0952604f, 1.2332108e-05f, 0.0f, 0.09511563f, 0.99393344f, -0.05522278f, 0.0f, 0.005248346f, 0.054972745f, 0.99847394f, 0.0f, -0.8272228f, 1.7963867f, 0.020178676f, 1.0f}, 0, 0},
    {7.6358, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.6595, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954602f, -0.095180854f, 1.2394739e-05f, 0.0f, 0.09503604f, 0.99393845f, -0.055270463f, 0.0f, 0.0052483557f, 0.05502076f, 0.99847144f, 0.0f, -0.82731247f, 1.7963943f, 0.020118952f, 1.0f}, 0, 0},
    {7.6595, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.6833, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954649f, -0.09512897f, 1.2576464e-05f, 0.0f, 0.094984025f, 0.99394065f, -0.055316836f, 0.0f, 0.0052496716f, 0.055067264f, 0.9984689f, 0.0f, -0.8273716f, 1.7963943f, 0.020060897f, 1.0f}, 0, 0},
    {7.6833, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.7073, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954677f, -0.09510114f, 1.2819073e-05f, 0.0f, 0.09495583f, 0.99394006f, -0.055378795f, 0.0f, 0.005253877f, 0.055128966f, 0.99846536f, 0.0f, -0.8274059f, 1.796402f, 0.019983172f, 1.0f}, 0, 0},
    {7.7073, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.7319, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954721f, -0.09505485f, 1.3303128e-05f, 0.0f, 0.09490914f, 0.9939382f, -0.055491984f, 0.0f, 0.0052615996f, 0.055241987f, 0.99845916f, 0.0f, -0.8274574f, 1.796402f, 0.019841313f, 1.0f}, 0, 0},
    {7.7319, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.7569, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99547595f, -0.095014304f, 1.36070885e-05f, 0.0f, 0.09486814f, 0.993937f, -0.055582166f, 0.0f, 0.0052675833f, 0.055332005f, 0.99845403f, 0.0f, -0.8275051f, 1.796402f, 0.019728303f, 1.0f}, 0, 0},
    {7.7569, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.7811, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954793f, -0.09497878f, 1.3970421e-05f, 0.0f, 0.09483232f, 0.9939356f, -0.055669367f, 0.0f, 0.005273523f, 0.05541904f, 0.9984492f, 0.0f, -0.82754517f, 1.7964096f, 0.019619107f, 1.0f}, 0, 0},
    {7.7811, 2, 1, 0, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 1, 1},
    {7.8076, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954838f, -0.09493163f, 1.4456571e-05f, 0.0f, 0.09478447f, 0.99393207f, -0.05581385f, 0.0f, 0.0052840915f, 0.055563223f, 0.99844116f, 0.0f, -0.8275986f, 1.7964096f, 0.019438028f, 1.0f}, 0, 0},
    {7.8076, 2, 1, 111, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.8076, 2, 1, 111, 110, 1, 1, 3, 1, {10.411375f, 14.4673f, 1.6693032f}, {0.84500575f, -0.53475696f, 2.328772e-06f, 0.0f, 0.5340182f, 0.8438382f, -0.05254817f, 0.0f, 0.028098565f, 0.04440468f, 0.9986183f, 0.0f, 1.2287292f, 0.31176758f, 2.65119898f, 1.0f}, 0, 1},
    {7.8317, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.9954858f, -0.09491046f, 1.4760182e-05f, 0.0f, 0.09476289f, 0.9939293f, -0.05589801f, 0.0f, 0.0052906247f, 0.055647142f, 0.99843645f, 0.0f, -0.82762337f, 1.7964096f, 0.019332528f, 1.0f}, 0, 0},
    {7.8317, 2, 1, 0, 111, 1, 1, 3, 1, {10.002644f, 15.26046f, 1.7387338f}, {0.8528934f, -0.522085f, -8.149771e-06f, 0.0f, 0.52143806f, 0.85183704f, -0.049760073f, 0.0f, 0.025985898f, 0.042435877f, 0.9987613f, 0.0f, 1.2175827f, 0.31860352f, 2.6539404f, 1.0f}, 0, 1},
    {7.8561, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99548405f, -0.09493038f, 1.5183934e-05f, 0.0f, 0.09478232f, 0.9939219f, -0.055998743f, 0.0f, 0.005300874f, 0.0557473f, 0.9984308f, 0.0f, -0.8276005f, 1.796402f, 0.019206285f, 1.0f}, 0, 0},
    {7.8561, 2, 1, 0, 111, 1, 1, 3, 1, {10.002644f, 15.26046f, 1.7387338f}, {0.8528934f, -0.522085f, -8.149771e-06f, 0.0f, 0.52143806f, 0.85183704f, -0.049760073f, 0.0f, 0.025985898f, 0.042435877f, 0.9987613f, 0.0f, 1.2175827f, 0.31860352f, 2.6539404f, 1.0f}, 0, 1},
    {7.881, 1, 0, 0, 0, 0, 1, 32, 1, {1.5074234f, 25.84671f, -1.4458319f}, {0.99547917f, -0.09497956f, 1.5365425e-05f, 0.0f, 0.09483116f, 0.99391484f, -0.05603811f, 0.0f, 0.0053072306f, 0.055786148f, 0.9984285f, 0.0f, -0.82754517f, 1.7963943f, 0.019156933f, 1.0f}, 0, 0},
    {7.881, 2, 1, 0, 111, 1, 1, 3, 1, {10.002644f, 15.26046f, 1.7387338f}, {0.8528934f, -0.522085f, -8.149771e-06f, 0.0f, 0.52143806f, 0.85183704f, -0.049760073f, 0.0f, 0.025985898f, 0.042435877f, 0.9987613f, 0.0f, 1.2175827f, 0.31860352f, 2.6539404f, 1.0f}, 1, 1},
};

static const LossRow* GatlingLoss(int* count)
{
    *count = (int)(sizeof kGatlingLoss / sizeof kGatlingLoss[0]);
    return kGatlingLoss;
}

static const FiringRow* FiringSweeps(int* count)
{
    *count = (int)(sizeof kFiringSweeps / sizeof kFiringSweeps[0]);
    return kFiringSweeps;
}
