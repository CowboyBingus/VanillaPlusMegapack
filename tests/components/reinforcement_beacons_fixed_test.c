/* Reinforcement Beacons Fixed: the Lua tests' scenarios (components/ReinforcementBeaconsFixed/tests/test_data.lua,
 * solo_scenarios.lua, test_startup.lua and test_idle_equivalence.lua's main scenario) on the fake game, with the C
 * port's calls per frame pinned. */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/reinforcement_beacons_fixed/spawn_data.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_reinforcement_beacons_fixed};

#define PM_GLOBAL 0x3326468u
#define MODE_GLOBAL 0x33266A0u
#define RM_GLOBAL 0x33269C0u
#define POS_GLOBAL 0x3326B20u
#define SM_GLOBAL 0x33266B0u
#define OWNER_GLOBAL 0x346BF98u
#define CAMERA_GLOBAL 0x346D560u
#define EXE_REGISTRY 0x1A100F0u
#define EXE_METHOD 0x2BD870u
#define AT_XY 0x10Cu
#define AT_SPAWN 0x2E0u
#define DT (1.0f / 60)

/* The status now, and the status the frame's tick left (before the game's update and the check after it). */
#define CHECK_STATUS(text) StatusIs("status", Status(), text, __LINE__)
#define CHECK_TICK(text) StatusIs("tick's status", g_tickStatus, text, __LINE__)

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutF(uint8_t* at, float v) { memcpy(at, &v, 4); }
static float GetF(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static void Global(uint32_t rva, const void* to) { Put64((uint8_t*)fake_game() + rva, (uint64_t)(uintptr_t)to); }
static const char* Status(void) { return vpm_status(fake_component(0)); }
static int Posting(void) { return vpm_post_ticking(fake_component(0)); }

static char g_tickStatus[96];
static void StatusIs(const char* which, const char* actual, const char* expected, int line)
{
    test_checks++;
    if (strcmp(actual, expected) == 0) return;
    test_failures++;
    printf("  FAILED %s:%d: the %s is \"%s\", expected \"%s\"\n", __FILE__, line, which, actual, expected);
}

/* ---- the fake game: test_idle_equivalence.lua's world -------------------------------------------------------------
 * Two player managers, the local player's entity, two beacons (77 owned here, 78 a teammate's) with positions, up to
 * four automatic-reinforcement rows and the fallback source position. */

typedef struct World
{
    uint8_t *pm, *pm2, *p, *mode, *entity, *b1, *b2, *rm, *entities, *used, *pos, *hash, *xyz, *sm, *rows, *camera, *owner;
} World;
static World w;

static void Manager(uint8_t* p)
{
    Put32(p + 0x84, 2);
    Put32(p + 0x88, 2);
    Put64(p + 0xE8, (uint64_t)(uintptr_t)w.entity);
    Put32(p + AT_SPAWN, 3);
    Put32(p + 0x3A8, 0x7FFF);
    Put32(p + 0x3B4, 0);
    PutF(p + AT_XY, 0);
    PutF(p + AT_XY + 4, 0);
    PutF(p + 0x114, 9);
    PutF(p + 0x12C, 5);
}

static void MakeWorld(void)
{
    memset(&w, 0, sizeof w);
    w.entity = fake_heap(24);
    Put32(w.entity + 8, 5);
    w.entity[20] = 1;
    w.pm = fake_heap(0x440);
    w.pm2 = fake_heap(0x440);
    Manager(w.pm);
    Manager(w.pm2);
    w.p = w.pm;
    w.mode = fake_heap(0x44);
    Put32(w.mode + 0x40, 1);
    w.b1 = fake_heap(24);
    w.b2 = fake_heap(24);
    Put32(w.b1 + 8, 77);
    w.b1[20] = 1;
    Put32(w.b2 + 8, 78);
    w.entities = fake_heap(16);
    w.used = fake_heap(8);
    Put64(w.entities, (uint64_t)(uintptr_t)w.b1);
    Put64(w.entities + 8, (uint64_t)(uintptr_t)w.b2);
    w.rm = fake_heap(0x58);
    Put32(w.rm + 8, 4);
    Put64(w.rm + 0x38, (uint64_t)(uintptr_t)w.entities);
    Put64(w.rm + 0x48, (uint64_t)(uintptr_t)w.used);
    w.hash = fake_heap(64);
    memset(w.hash, 0xFF, 64);
    Put32(w.hash + 8 * 5, 77);
    Put32(w.hash + 8 * 5 + 4, 0);
    Put32(w.hash + 8 * 6, 78);
    Put32(w.hash + 8 * 6 + 4, 1);
    w.xyz = fake_heap(24);
    const float xyz[6] = {11, 22, 33, 40, 50, 33};
    memcpy(w.xyz, xyz, sizeof xyz);
    w.pos = fake_heap(0x60);
    Put32(w.pos + 8, 2);
    Put64(w.pos + 0x28, (uint64_t)(uintptr_t)w.hash);
    Put32(w.pos + 0x30, 8);
    Put32(w.pos + 0x34, 0xFFFFFFFFu);
    Put32(w.pos + 0x38, 1);
    Put64(w.pos + 0x50, (uint64_t)(uintptr_t)w.xyz);
    w.rows = fake_heap(4 * 64);
    w.sm = fake_heap(0x80);
    Put64(w.sm + 0x78, (uint64_t)(uintptr_t)w.rows);
    w.camera = fake_heap(0x48);
    PutF(w.camera + 0x3C, 15);
    PutF(w.camera + 0x40, 25);
    PutF(w.camera + 0x44, 3);
    w.owner = fake_heap(64);
    Global(PM_GLOBAL, w.pm);
    Global(MODE_GLOBAL, w.mode);
    Global(RM_GLOBAL, w.rm);
    Global(POS_GLOBAL, w.pos);
    Global(SM_GLOBAL, w.sm);
    Global(CAMERA_GLOBAL, w.camera);
    Global(OWNER_GLOBAL, w.owner);
}

/* Game events. */
static void Mission(uint32_t players)
{
    Put32(w.mode + 8, 1);
    Put32(w.mode + 0x40, 1);
    Put32(w.p + 0x84, players);
    Put32(w.p + 0x88, players);
}
static void Spawn(uint32_t state) { Put32(w.p + AT_SPAWN, state); }
static void Camera(float x, float y) { PutF(w.camera + 0x3C, x); PutF(w.camera + 0x40, y); }
/* One active beacon record: 77 (index 0 in the positions) or 78 (index 1), at x, y, no use bit set. */
static void Beacon(uint32_t which, float x, float y)
{
    int i = which == 77 ? 0 : 1;
    Put32(w.rm + 12, 1);
    Put64(w.entities, (uint64_t)(uintptr_t)(which == 77 ? w.b1 : w.b2));
    Put32(w.used, 0);
    PutF(w.xyz + 12 * i, x);
    PutF(w.xyz + 12 * i + 4, y);
}
/* An automatic-reinforcement row (type 0x7C) at index i. */
static void Row(int i, float x, float y)
{
    Put32(w.rows + 64 * i + 12, 0x7C);
    PutF(w.rows + 64 * i + 16, x);
    PutF(w.rows + 64 * i + 20, y);
    PutF(w.rows + 64 * i + 24, 30);
    if (Get32(w.sm + 0x34) < (uint32_t)i + 1) Put32(w.sm + 0x34, (uint32_t)i + 1);
}
static void Die(void) { Spawn(1); }
/* The queue commits: the pod pending at a scattered X, Y, with the local use bit (1) or only the teammate owner's (2). */
static void Commit(uint32_t used)
{
    Spawn(2);
    Put32(w.used, used);
    PutF(w.p + AT_XY, 50);
    PutF(w.p + AT_XY + 4, 60);
    PutF(w.p + 0x12C, 5);
}
static void Land(void)
{
    Spawn(3);
    Put32(w.rm + 12, 0);
    PutF(w.p + AT_XY, 0);
    PutF(w.p + AT_XY + 4, 0);
}
static void Xy(float x, float y) { PutF(w.p + AT_XY, x); PutF(w.p + AT_XY + 4, y); }
static float X(void) { return GetF(w.p + AT_XY); }
static float Y(void) { return GetF(w.p + AT_XY + 4); }

/* ---- frames: the engine's, with the core's hook of game.dll's update (in game once its code is decoded) --------- *
 * The tick, then the game's update (the tick's status and reads noted, then the step a test put inside it), then the
 * check after the update. Without the hook (the core's fallback) both checks run in HellForge's callback, before the
 * update's step. */

static int g_hooked;              /* the session has the core's hook */
static void (*g_inside)(void);    /* a step inside the next frame's update, between the two checks */
static uint32_t g_tickReads;      /* the reads of the frame's tick */

static void TheGameUpdates(float dt)
{
    void (*step)(void) = g_inside;
    snprintf(g_tickStatus, sizeof g_tickStatus, "%s", Status());
    g_tickReads = fake_counts().read;
    g_inside = NULL;
    if (step != NULL) step();
}

static void Frames(int n) { fake_engine_frames(n, DT); }
static void Frame(void) { Frames(1); }

static void StartedOn(int hooked)
{
    g_hooked = hooked;
    g_inside = NULL;
    if (hooked) fake_frame_update(1);
    fake_after_tick(TheGameUpdates);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
}

static void Started(void) { StartedOn(1); }

/* A two-player mission with the local player's own beacon: alive, queued, corrected to the beacon's 11, 22. */
static void Corrected(void)
{
    Mission(2);
    Beacon(77, 11, 22);
    Spawn(3);
    Frame();
    Die();
    Frame();
    Commit(1);
    Frame();
}

/* ---- the plan on synthetic snapshots (test_data.lua) ------------------------------------------------------------- */

static RbfSnapshot g_snaps[2];
static RbfState g_state;
static RbfReader g_reader;

static RbfSnapshot* Snap(int buffer, int64_t state, int64_t count)
{
    RbfSnapshot* s = &g_snaps[buffer];
    const float position[3] = {50, 60, 4};
    rbf_clear(s);
    s->mode = 1;
    s->identity = 0x100000;
    s->address = 0x10010C;
    s->count = count;
    s->id = 1;
    s->state = state;
    s->owned = 1;
    s->unit_ref = 7;
    s->positioned = 1;
    memcpy(s->position, position, sizeof position);
    s->timed = 1;
    s->countdown = 5;
    memcpy(s->original, "abcdefgh", 8);
    s->rows_known = 1;
    return s;
}

static void AddBeacon(RbfSnapshot* s, uint32_t id, uint32_t used, float x, float y, int owned)
{
    RbfBeacon* b = &s->beacons[s->beacon_count++];
    b->id = id;
    b->used = used;
    b->owned = owned;
    b->positioned = 1;
    b->position[0] = x;
    b->position[1] = y;
    b->position[2] = 3;
}

/* patch.plan: 1 with *plan made, 0 with the reason. */
static int Plan(RbfSnapshot* current, RbfPlan* plan, const char** reason)
{
    memset(plan, 0, sizeof *plan);
    int rc = rbf_plan(&g_reader, &g_state, current, plan, reason);
    return rc == RBF_OK && *reason == NULL;
}

static void Fresh(void)
{
    memset(&g_state, 0, sizeof g_state);
    g_state.spawn = RBF_NIL;
}

static void PlanCorrectsAUsedBeacon(void)
{
    RbfPlan plan;
    const char* reason;
    Fresh();
    RbfSnapshot* a = Snap(0, 1, 2);
    AddBeacon(a, 50, 0, 10, 20, 1);
    CHECK(!Plan(a, &plan, &reason));
    RbfSnapshot* b = Snap(1, 2, 2);
    AddBeacon(b, 50, 1, 10, 20, 1);
    CHECK(Plan(b, &plan, &reason));
    CHECK(!plan.solo && plan.target[0] == 10 && plan.target[1] == 20 && !plan.remote);
    CHECK(GetF(plan.bytes) == 10 && GetF(plan.bytes + 4) == 20);
    for (uint32_t mode = 1; mode <= 7; mode++)
    {
        Fresh();
        RbfSnapshot* before = Snap(0, 1, 2);
        before->mode = mode;
        AddBeacon(before, 50, 0, 10, 20, 1);
        CHECK(!Plan(before, &plan, &reason));
        RbfSnapshot* now = Snap(1, 2, 2);
        now->mode = mode;
        AddBeacon(now, 50, 1, 10, 20, 1);
        CHECK(Plan(now, &plan, &reason));
    }
}

/* Local use bit 0; a teammate-owned beacon keeps used = 2 (its owner's bit) through the local queue commit. */
static void PlanTeammateBeacon(void)
{
    RbfPlan plan;
    const char* reason;
    Fresh();
    CHECK(!Plan(Snap(0, 1, 2), &plan, &reason));
    RbfSnapshot* now = Snap(1, 2, 2);
    now->position[2] = 3;
    AddBeacon(now, 50, 2, 10, 20, 0);
    CHECK(Plan(now, &plan, &reason));
    CHECK(plan.target[0] == 10 && plan.target[1] == 20 && plan.remote && plan.beacon == 50);
}

/* The game picks the first unused record in manager order: an observed remote choice is usable; a newly ambiguous or
 * changed one is not. */
static void PlanFirstUnusedRemote(void)
{
    static const char* const cases[] = {"observed", "ambiguous", "disappeared", "moved", "local_owner", "not_dead", "late", "already_used"};
    for (int c = 0; c < 8; c++)
    {
        RbfPlan plan;
        const char* reason;
        Fresh();
        RbfSnapshot* before = Snap(0, c == 5 ? 3 : c == 6 ? 2 : 1, 2);
        if (c == 0 || c == 2 || c == 3)
        {
            AddBeacon(before, 60, 2, 10, 20, 0);
            AddBeacon(before, 61, 2, 30, 40, 0);
        }
        (void)Plan(before, &plan, &reason);
        RbfSnapshot* now = Snap(1, 2, 2);
        if (c != 2) AddBeacon(now, 60, c == 7 ? 3 : 2, c == 3 ? 11 : 10, 20, c == 4);
        if (c <= 3) AddBeacon(now, 61, 2, 30, 40, 0);
        int made = Plan(now, &plan, &reason);
        if (c == 0) CHECK(made && plan.beacon == 60 && plan.remote);
        else if (c == 7) CHECK(made && !plan.remote);
        else if (made) { test_failures++; printf("  FAILED %s: a plan was made\n", cases[c]); }
        test_checks++;
    }
}

/* Initial drops, ambiguous beacons, used or stale beacons, expired windows, other modes, owners, missions, players. */
static void PlanExclusions(void)
{
    static const char* const cases[] = {"initial", "ambiguous", "used", "expired", "nan", "mode", "ownership", "mission", "players"};
    for (int c = 0; c < 9; c++)
    {
        RbfPlan plan;
        const char* reason;
        Fresh();
        RbfSnapshot* before = Snap(0, c == 0 ? 0 : 1, 2);
        AddBeacon(before, 50, c == 2 ? 1 : 0, 10, 20, 1);
        (void)Plan(before, &plan, &reason);
        RbfSnapshot* now = Snap(1, 2, 2);
        AddBeacon(now, 50, 1, 10, 20, 1);
        if (c == 1) AddBeacon(now, 51, 1, 10, 20, 1);
        if (c == 3) now->countdown = 0;
        if (c == 4) now->timed = 0; /* the reader gives no countdown for a NaN */
        if (c == 5) now->mode = 4;
        if (c == 6) now->owned = 0;
        if (c == 7) now->identity = 0x200000;
        if (c == 8) now->count = 3;
        if (Plan(now, &plan, &reason)) { test_failures++; printf("  FAILED %s: a plan was made\n", cases[c]); }
        test_checks++;
    }
    /* The reasons, as the log reports them. */
    RbfPlan plan;
    const char* reason;
    Fresh();
    RbfSnapshot* before = Snap(0, 0, 2);
    (void)Plan(before, &plan, &reason);
    CHECK(strcmp(reason, "waiting_for_reinforcement") == 0);
    RbfSnapshot* now = Snap(1, 2, 2);
    AddBeacon(now, 50, 1, 10, 20, 1);
    (void)Plan(now, &plan, &reason);
    CHECK(strcmp(reason, "initial_deployment_unchanged") == 0);
    now = Snap(0, 2, 2);
    AddBeacon(now, 50, 1, 900, 20, 1);
    Fresh();
    (void)Plan(Snap(1, 1, 2), &plan, &reason);
    (void)Plan(now, &plan, &reason);
    CHECK(strcmp(reason, "placement_outside_supported_range") == 0);
}

/* solo_scenarios.lua: three solo deaths, the automatic anchor and the pod both scattered; the source moves after the
 * anchor is captured. */
static int SoloTrace(uint32_t mode)
{
    int corrections = 0, n = 0;
    Fresh();
    for (int event = 1; event <= 3; event++)
    {
        const float source[3] = {event * 100.0f, event * 20.0f, 2}, anchor[3] = {source[0] + 30, source[1] - 25, 3};
        const float queued[3] = {anchor[0] + 20, anchor[1] + 15, 2};
        for (int step = 0; step < 5; step++)
        {
            static const int64_t states[5] = {3, 1, 2, 2, 3};
            RbfSnapshot* s = Snap(n++ % 2, states[step], 1);
            s->mode = mode;
            memset(s->position, 0, sizeof s->position);
            if (step == 2 || step == 3) memcpy(s->position, queued, sizeof queued);
            if (step == 2) s->countdown = 4.9f;
            if (step == 3) s->countdown = 2;
            s->source_valid = 1;
            memcpy(s->source, source, sizeof source);
            if (step == 2) { s->source[0] += 0.1f; s->source[1] += 0.1f; }
            if (step == 3) { s->source[0] += 5; s->source[1] -= 5; }
            if (step > 0) { s->row_count = 1; memcpy(s->rows[0].position, anchor, sizeof anchor); }
            if (step == 2) AddBeacon(s, (uint32_t)event + 10, 1, anchor[0], anchor[1], 1);
            RbfPlan plan;
            const char* reason;
            if (!Plan(s, &plan, &reason)) continue;
            CHECK(plan.solo && g_state.anchored);
            CHECK(plan.target[0] == source[0] && plan.target[1] == source[1] && plan.target[0] != anchor[0]);
            g_state.pending = 1;
            corrections++;
        }
    }
    return corrections;
}

static void PlanSoloScenarios(void)
{
    CHECK_EQ(SoloTrace(1), 3);
    CHECK_EQ(SoloTrace(2), 3); /* solo death anchors in the live-reported defense mode too */
}

/* The re-read right before the write (test_data.lua's guarded write): another spawn state or mode, a moved or now
 * locally owned remote beacon, keep it from being written. */
static void ChecksBeforeTheWrite(void)
{
    for (int c = 0; c < 8; c++)
    {
        int remote = c >= 4;
        RbfPlan plan;
        const char* reason;
        Fresh();
        RbfSnapshot* before = Snap(0, 1, 2);
        AddBeacon(before, 50, remote ? 2 : 0, 10, 20, !remote);
        (void)Plan(before, &plan, &reason);
        RbfSnapshot* now = Snap(1, 2, 2);
        AddBeacon(now, 50, remote ? 2 : 1, 10, 20, !remote);
        CHECK(Plan(now, &plan, &reason));
        RbfSnapshot* fresh = Snap(0, 2, 2);
        AddBeacon(fresh, 50, remote ? 2 : 1, 10, 20, !remote);
        if (c == 1) fresh->state = 3;
        if (c == 2) fresh->mode = 2;
        if (c == 3) memcpy(fresh->original, "abcdefgX", 8);
        if (c == 5) fresh->beacons[0].position[0] = 11;
        if (c == 6) fresh->beacons[0].owned = 1;
        if (c == 7) fresh->countdown = 0.05f;
        int changed = rbf_spawn_changed(now, fresh), kept = rbf_beacon_kept(fresh, &plan);
        if (c == 0 || c == 4) CHECK(!changed && kept);
        if (c >= 1 && c <= 3) CHECK(changed);
        if (c == 5 || c == 6) CHECK(!changed && !kept);
        if (c == 7) CHECK(changed);
    }
}

/* ---- the component on the fake game (test_startup.lua) ---------------------------------------------------------- */

/* The tick starts with game.dll (HF_EVENT_GAME_LOADED); before it nothing runs or reads. */
static void TicksFromGameLoaded(void)
{
    MakeWorld();
    fake_start(kDefs, 1);
    CHECK(vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    fake_counts_reset();
    fake_frames(10, DT);
    CHECK_EQ(fake_counts().read, 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(vpm_ticking(fake_component(0)));
    fake_counts_reset();
    Frame();
    CHECK_EQ(fake_counts().read, 1);
}

static void StaysOffWithVanillaPlus(void)
{
    fake_add_mod("skyeshade.vanilla-plus", HF_MOD_CODE);
    Started();
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Reinforcement Beacons Fixed] off: HellForge's Vanilla Plus is on and changes the same thing");
}

/* Null startup pointers wait; each stage of the game's data waits by name; then the correction, Z and the countdown
 * kept. */
static void StagedStartupThenCorrection(void)
{
    MakeWorld();
    Global(PM_GLOBAL, NULL);
    Global(MODE_GLOBAL, NULL);
    Global(RM_GLOBAL, NULL);
    Put64(w.pm + 0xE8, 0);
    Started();
    CHECK_LOG("[Reinforcement Beacons Fixed] waiting_for_reinforcement");
    CHECK(vpm_ticking(fake_component(0)));
    Frames(2);
    CHECK_STATUS("waiting_for_game_data:player_manager");
    Global(PM_GLOBAL, w.pm);
    Frame();
    CHECK_STATUS("waiting_for_reinforcement");
    Die();
    Frame();
    CHECK_STATUS("waiting_for_game_data:mission_mode");
    Global(MODE_GLOBAL, w.mode);
    Frame(); /* aboard the ship: the mode alone */
    CHECK_STATUS("waiting_for_reinforcement");
    Mission(2);
    Frame();
    CHECK_STATUS("waiting_for_game_data:local_player");
    Put64(w.pm + 0xE8, (uint64_t)(uintptr_t)w.entity);
    Frame();
    CHECK_STATUS("waiting_for_game_data:reinforcement_manager");
    Global(RM_GLOBAL, w.rm);
    Frame();
    CHECK_STATUS("waiting_for_reinforcement");
    Beacon(77, 11, 22);
    Frame(); /* the unused beacon, while queued */
    Commit(1);
    Frame();
    CHECK_TICK("beacon_spawn_centered");
    CHECK_STATUS("reinforcement_already_centered"); /* the check after the update */
    CHECK(X() == 11 && Y() == 22);
    CHECK(GetF(w.pm + 0x114) == 9 && GetF(w.pm + 0x12C) == 5 && Get32(w.used) == 1 && w.b1[20] == 1);
    CHECK_LOG("beacon_spawn_centered (corrections=1; beacon beacon=77 from=50.000000,60.000000 to=11.000000,22.000000 association=used)");
    Frame();
    CHECK_STATUS("reinforcement_already_centered");
    CHECK_EQ(fake_counts().write, 0); /* one plain store, no HfApi.write */
}

/* An unreadable player block waits and forgets; the next player manager recovers. */
static void UnreadableTransitionRecovers(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Beacon(77, 11, 22);
    Frame();
    Die();
    Frame();
    fake_hole((uintptr_t)w.pm, 1);
    Frame();
    CHECK_STATUS("waiting_for_game_data:player_manager");
    memcpy(w.pm2, w.pm, 0x440);
    w.p = w.pm2;
    Global(PM_GLOBAL, w.pm2);
    Frame();
    Commit(1);
    Frame();
    CHECK(X() == 11 && Y() == 22);
    CHECK_LOG("corrections=1;");
}

/* A teardown (a null player manager) forgets every association, the pending correction included: the same queue is
 * not corrected again, the next death is. */
static void ReloadForgetsAssociations(void)
{
    MakeWorld();
    Started();
    Corrected();
    Global(PM_GLOBAL, NULL);
    Frame();
    Global(PM_GLOBAL, w.pm);
    Frames(2);
    CHECK_STATUS("beacon_association_unavailable");
    CHECK_NO_LOG("corrections=2");
    Land();
    Frame();
    Die();
    Put32(w.used, 0);
    Put32(w.rm + 12, 1);
    Frame();
    Commit(1);
    Frame();
    CHECK(X() == 11 && Y() == 22);
    CHECK_LOG("corrections=2;");
}

/* A teammate's beacon in the queue-commit frame with only its owner's bit (2): corrected; use bits and ownership kept. */
static void TeammateBeaconThroughTheReader(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Beacon(78, 40, 50);
    Frame();
    Die();
    Frame();
    Commit(2);
    Frame();
    CHECK(X() == 40 && Y() == 50);
    CHECK_LOG("association=unmarked_remote)");
    CHECK(Get32(w.used) == 2 && w.b2[20] == 0 && GetF(w.pm + 0x114) == 9 && GetF(w.pm + 0x12C) == 5);
}

static void EveryGameplayMode(void)
{
    MakeWorld();
    Started();
    Mission(2);
    for (uint32_t mode = 1; mode <= 7; mode++)
    {
        char text[32];
        Put32(w.mode + 0x40, mode);
        Land();
        Frame();
        Die();
        Frame();
        Beacon(78, 40, 50);
        Commit(2);
        Frame();
        CHECK(X() == 40 && Y() == 50);
        snprintf(text, sizeof text, "corrections=%u;", mode);
        CHECK_LOG(text);
    }
}

/* Type 0x7A rows are ignored, the current 0x7C rows recognized; the source is frozen when the anchor appears, so a
 * moving camera does not move the correction; the queue is corrected once; landing clears the association. */
static void SoloAnchorIsFrozen(void)
{
    MakeWorld();
    Started();
    Mission(1);
    Camera(11, 22);
    Frame();
    Die();
    Frame();
    Put32(w.sm + 0x34, 1);
    Put32(w.rows + 12, 0x7A);
    PutF(w.rows + 16, 70);
    PutF(w.rows + 20, 80);
    static RbfSnapshot snap;
    RbfReader reader = {fake_component(0), NULL};
    CHECK_EQ(rbf_snapshot(&reader, &snap), RBF_OK);
    CHECK_EQ(snap.row_count, 0); /* the obsolete anchor type */
    Frame();
    Row(1, 90, 100);
    CHECK_EQ(rbf_snapshot(&reader, &snap), RBF_OK);
    CHECK(snap.row_count == 1 && snap.rows[0].position[0] == 90 && snap.solo);
    Frame(); /* the anchor appears: its source, the fallback position 11, 22, is frozen */
    Camera(500, 600);
    Beacon(77, 90, 100);
    Commit(1);
    Xy(120, 130);
    Frame();
    CHECK_TICK("solo_spawn_centered");
    CHECK_STATUS("reinforcement_already_centered");
    CHECK(X() == 11 && Y() == 22);
    CHECK(GetF(w.pm + 0x114) == 9 && GetF(w.pm + 0x12C) == 5 && Get32(w.used) == 1 && w.b1[20] == 1);
    Frame();
    CHECK_STATUS("reinforcement_already_centered");
    CHECK_NO_LOG("corrections=2");
    Land();
    Put32(w.sm + 0x34, 0);
    Frame();
    CHECK_STATUS("waiting_for_reinforcement");
}

/* One frame's reads: the tick's (the 1:1 port's one check) and the check's after the update. Without the hook the two
 * run back to back and only their sum is seen. */
#define READS(tick, post) do { fake_counts_reset(); Frame(); uint32_t all_ = fake_counts().read; \
    if (g_hooked) { CHECK_EQ(g_tickReads, tick); CHECK_EQ(all_ - g_tickReads, post); } \
    else CHECK_EQ(all_, (tick) + (post)); } while (0)

/* The calls per frame, tick + post (test_startup.lua's frame_budget pins, here vpm_read; game.dll globals are plain
 * loads). Between deaths only the gate runs, and no post check; the snapshot runs while queued or pending, at both
 * points, as the Lua's step and after-update check. */
static void FrameBudgetOn(int hooked)
{
    MakeWorld();
    StartedOn(hooked);
    Global(PM_GLOBAL, NULL);
    READS(0, 0); /* loading (the Lua: 1) */
    CHECK_STATUS("waiting_for_game_data:player_manager");
    Global(PM_GLOBAL, w.pm);
    Frame();
    READS(1, 0); /* on the ship (the Lua: 2) */
    CHECK_EQ(fake_counts().log, 0);
    Mission(2);
    Beacon(77, 11, 22);
    fake_counts_reset();
    Frames(100);
    CHECK_EQ(fake_counts().read, 100); /* alive in a mission with a beacon out (the Lua: 2 per frame) */
    CHECK_EQ(fake_counts().log + fake_counts().write, 0);
    CHECK(!Posting());
    Die();
    READS(11, 10); /* the death's frame: the gate, then the snapshot; the snapshot after the update (the Lua: 30) */
    CHECK(Posting());
    READS(10, 10); /* still queued (the Lua: 28) */
    CHECK_EQ(fake_counts().log, 0);
    Commit(1);
    READS(21, 10); /* the snapshot, its re-read, the read-back; the snapshot after the update (the Lua: 42 + 1) */
    CHECK_EQ(fake_counts().write, 0);
    CHECK(X() == 11 && Y() == 22);
    READS(10, 10); /* the correction held (the Lua: 28) */
    CHECK_STATUS("reinforcement_already_centered");
    Mission(1);
    Land();
    READS(5, 0); /* landed solo: the last full check, which stops the post check (the Lua: 9) */
    CHECK_STATUS("waiting_for_reinforcement");
    CHECK(!Posting());
    READS(1, 0); /* alive solo (the Lua: 2) */
    Die();
    Row(0, 90, 100);
    READS(8, 6); /* the solo death: gate, snapshot, the fallback source; the snapshot after the update (the Lua: 25) */
    READS(6, 6); /* the anchor held, not read again (the Lua: 20) */
    Beacon(77, 90, 100);
    Commit(1);
    READS(25, 12); /* two solo snapshots with a beacon and the read-back; the snapshot after the update */
    CHECK(X() == 15 && Y() == 25); /* the fallback position when the anchor appeared */
}

static void FrameBudget(void) { FrameBudgetOn(1); }
/* Without the core's hook the check after the update runs right after the tick: the same calls. */
static void FrameBudgetWithoutTheHook(void) { FrameBudgetOn(0); }

/* The player layout is read only once the local player is queued or pending, so an unsupported one is met at the
 * death, and stops the component. */
static void LayoutMetAtTheDeath(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Put32(w.pm + 0x84, 99);
    Frame();
    CHECK(vpm_running(fake_component(0)));
    Die();
    Frame();
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: Unsupported player layout");
    Put32(w.pm + 0x84, 2);
    Commit(1);
    Frame();
    CHECK(X() == 50 && Y() == 60);
}

/* A non-null invalid pointer refuses; only null ones wait. */
static void InvalidPointersRefuse(void)
{
    MakeWorld();
    Put64((uint8_t*)fake_game() + PM_GLOBAL, 1);
    Started();
    Frame();
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: Invalid spawn data pointer: player_manager");
    fake_setup();
    MakeWorld();
    Put64((uint8_t*)fake_game() + MODE_GLOBAL, 0x1234);
    Started();
    Mission(2);
    Frame();
    CHECK(vpm_running(fake_component(0)));
    Die();
    Frame();
    CHECK_LOG("disabled: Invalid spawn data pointer: mission_mode");
}

/* A refusal while a correction is pending stops the component and puts the original X, Y back. */
static void RefusalRestoresTheCorrection(void)
{
    MakeWorld();
    Started();
    Corrected();
    CHECK(X() == 11 && Y() == 22);
    Put32(w.pm + 0x84, 99);
    Frame();
    CHECK(!vpm_running(fake_component(0)));
    CHECK(X() == 50 && Y() == 60);
    CHECK_LOG("disabled: Unsupported player layout; correction_restored");
}

/* The restore puts back only this component's own pending write: the same player manager, the spawn still pending and
 * its X, Y still holding the written bytes. */
static void RestoresOnlyItsOwnWrite(void)
{
    static const char* const outcomes[] = {"correction_restored", "correction_left_unchanged", "correction_left_unchanged",
        "correction_left_unchanged", NULL, "correction_restore_failed"};
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        MakeWorld();
        Started();
        if (c != 4) Corrected();
        if (c == 1) Spawn(3);
        if (c == 2) Xy(1, 2);
        if (c == 3) Global(PM_GLOBAL, w.pm2);
        DWORD old;
        if (c == 5) VirtualProtect(w.pm, 0x440, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
        vpm_core_stop(fake_component(0), "test");
        if (c == 5) VirtualProtect(w.pm, 0x440, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
        if (outcomes[c] != NULL)
        {
            char text[96];
            snprintf(text, sizeof text, "disabled: test; %s", outcomes[c]);
            CHECK_LOG(text);
        }
        else CHECK_NO_LOG("correction_");
        if (c == 0) CHECK(X() == 50 && Y() == 60);
        if (c == 1 || c == 5) CHECK(X() == 11 && Y() == 22);
        if (c == 2) CHECK(X() == 1 && Y() == 2);
    }
}

/* The pending X, Y must be committed read-write memory: checked before the first store on each player manager. */
static void ReadOnlyTargetIsRefused(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Beacon(77, 11, 22);
    Frame();
    Die();
    Frame();
    Commit(1);
    DWORD old;
    VirtualProtect(w.pm, 0x440, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
    Frame();
    VirtualProtect(w.pm, 0x440, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK_LOG("disabled: Target is not existing private writable data");
    CHECK(X() == 50 && Y() == 60);
}

/* Queued in one player manager, committed in another: noticed against the previous snapshot, nothing written. */
static void ChangedManagerIsNoticed(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Beacon(77, 11, 22);
    Die();
    Frame();
    Commit(1);
    memcpy(w.pm2, w.pm, 0x440);
    Xy(50, 60);
    Global(PM_GLOBAL, w.pm2);
    Frame();
    CHECK_TICK("waiting_for_reinforcement");
    CHECK(GetF(w.pm + AT_XY) == 50 && GetF(w.pm2 + AT_XY) == 50);
    Global(PM_GLOBAL, w.pm);
    Spawn(3);
    Frame();
    Frame();
    Die();
    Put32(w.used, 0);
    Frame();
    Commit(1);
    Frame();
    CHECK(GetF(w.pm + AT_XY) == 11 && GetF(w.pm2 + AT_XY) == 50);
    CHECK_LOG("corrections=1;");
    CHECK_NO_LOG("corrections=2");
}

/* ---- the check after the game's update (the core's post-update tick) ------------------------------------------- */

static void CommitOne(void) { Commit(1); }
static void LandInTheUpdate(void) { Land(); }

/* Queued at the tick, committed inside the game's update: the check after the update corrects it in the same frame,
 * before the engine's world loop and the frame's render use the scattered X, Y (the Lua and the 1:1 port corrected it
 * on the next frame). A landing inside the update ends the post check in that frame. */
static void CommitInsideTheUpdate(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Beacon(77, 11, 22);
    Frame();
    CHECK(!Posting());
    Die();
    Frame();
    CHECK(Posting());
    g_inside = CommitOne;
    READS(10, 21); /* the tick's snapshot (queued); after the update the snapshot, its re-read, the read-back */
    CHECK_TICK("waiting_for_reinforcement");
    CHECK_STATUS("beacon_spawn_centered");
    CHECK(X() == 11 && Y() == 22);
    CHECK_LOG("beacon_spawn_centered (corrections=1; beacon beacon=77 from=50.000000,60.000000 to=11.000000,22.000000 association=used)");
    READS(10, 10);
    CHECK_STATUS("reinforcement_already_centered");
    g_inside = LandInTheUpdate;
    READS(10, 4); /* the tick: held; after the update: landed (co-op), the post check stops */
    CHECK_STATUS("waiting_for_reinforcement");
    CHECK(!Posting());
    READS(1, 0);
    CHECK_NO_LOG("corrections=2");
}

/* The Lua's condition, not the tick's: queued while this machine does not own the local player, the tick follows the
 * snapshot every frame, but nothing is in progress for the check after the update. */
static void NotOwnedHasNoCheckAfterTheUpdate(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Beacon(77, 11, 22);
    Frame();
    w.entity[20] = 0;
    Die();
    READS(1 + 3, 0); /* the gate, then the snapshot up to the ownership (mode, player block, local entity) */
    CHECK(!Posting());
    READS(3, 0);
    CHECK(!Posting());
    w.entity[20] = 1;
    READS(10, 10); /* owned again: in progress, both checks */
    CHECK(Posting());
}

/* Without the core's hook both checks run before the update: the commit inside it is corrected at the next frame's
 * tick, as in the 1:1 port. */
static void CommitInsideTheUpdateWithoutTheHook(void)
{
    MakeWorld();
    StartedOn(0);
    Mission(2);
    Beacon(77, 11, 22);
    Frame();
    Die();
    Frame();
    CHECK(Posting()); /* it runs, right after the tick */
    g_inside = CommitOne;
    READS(10, 10);
    CHECK(X() == 50 && Y() == 60);
    READS(21, 10);
    CHECK(X() == 11 && Y() == 22);
    CHECK_LOG("corrections=1;");
}

/* The core stopping the component while a correction is pending: the X, Y put back, the post check gone with the tick,
 * and nothing read afterwards. */
static void PostCheckStopsWithTheComponent(void)
{
    MakeWorld();
    Started();
    Corrected();
    CHECK(Posting() && X() == 11 && Y() == 22);
    vpm_core_stop(fake_component(0), "test");
    CHECK(!Posting() && !vpm_ticking(fake_component(0)));
    CHECK(X() == 50 && Y() == 60);
    CHECK_LOG("disabled: test; correction_restored");
    fake_counts_reset();
    Frames(3);
    CHECK_EQ(fake_counts().read, 0);
}

/* The player manager's page made read-only inside the update, after its first correction passed the page check: the
 * second death's store in the check after the update faults. The core's guard stops the component there; nothing was
 * written and nothing is pending, so its stop leaves the X, Y; the game goes on without it. */
static void CommitOnAReadOnlyPage(void)
{
    Commit(1);
    DWORD old;
    VirtualProtect(w.pm, 0x440, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
}

static void FaultAfterTheUpdate(void)
{
    MakeWorld();
    Started();
    Corrected();
    Land();
    Frame();
    Die();
    Put32(w.used, 0);
    Put32(w.rm + 12, 1);
    Frame();
    CHECK(Posting());
    g_inside = CommitOnAReadOnlyPage;
    Frame();
    DWORD old;
    VirtualProtect(w.pm, 0x440, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(!vpm_running(fake_component(0)) && !Posting() && !vpm_ticking(fake_component(0)));
    CHECK_LOG("[Reinforcement Beacons Fixed] disabled: ");
    CHECK_NO_LOG("corrections=2");
    CHECK_NO_LOG("correction_restored");
    CHECK(X() == 50 && Y() == 60);
    fake_counts_reset();
    Frames(3);
    CHECK_EQ(fake_counts().read, 0);
}

/* ---- the idle gate's transitions (test_startup.lua's last block) ------------------------------------------------ */

/* The frame's tick decides (test_startup.lua checked patch.apply alone); the check after the update follows. */
static void Step(uint32_t spawn, const char* expected)
{
    Spawn(spawn);
    Frame();
    CHECK_TICK(expected);
}

/* The beacon the solo queue placed at x, y, used by the local player, and the pod scattered around it. */
static void QueuedAt(float x, float y)
{
    Put32(w.rm + 12, 1);
    Put64(w.entities, (uint64_t)(uintptr_t)w.b1);
    Put32(w.used, 1);
    PutF(w.xyz, x);
    PutF(w.xyz + 4, y);
    Xy(120, 130);
}

static void GateInitialDeploymentAndAliveToPending(void)
{
    MakeWorld();
    Started();
    Mission(2);
    Step(0, "waiting_for_reinforcement");
    Step(0, "waiting_for_reinforcement");
    Put32(w.rm + 12, 1);
    Put32(w.used, 1);
    Xy(50, 60);
    Step(2, "initial_deployment_unchanged");
    Step(2, "beacon_association_unavailable");
    CHECK(X() == 50);
    /* Alive straight to pending (3 -> 2): the beacons' use bits before it were never read, so it is skipped. */
    fake_setup();
    MakeWorld();
    Started();
    Mission(2);
    Step(3, "waiting_for_reinforcement");
    Step(3, "waiting_for_reinforcement");
    Put32(w.rm + 12, 1);
    Put32(w.used, 1);
    Xy(50, 60);
    Step(2, "pending_without_queue_skipped");
    Step(2, "beacon_association_unavailable");
    CHECK(X() == 50);
    /* Co-op 3 -> 1 -> 2 through the gate: corrected once. */
    fake_setup();
    MakeWorld();
    Started();
    Mission(2);
    Step(3, "waiting_for_reinforcement");
    Step(3, "waiting_for_reinforcement");
    Step(1, "waiting_for_reinforcement");
    Put32(w.rm + 12, 1);
    Put32(w.used, 1);
    Xy(50, 60);
    Step(2, "beacon_spawn_centered");
    CHECK(X() == 11 && Y() == 22);
}

/* Solo: the death's own row is captured; an earlier death's row still listed at the next death is not new (the
 * landing's rows are the baseline). */
static void GateSoloDeaths(void)
{
    MakeWorld();
    Started();
    Mission(1);
    Camera(11, 22);
    Step(3, "waiting_for_reinforcement");
    Step(3, "waiting_for_reinforcement");
    Row(0, 90, 100);
    Step(1, "waiting_for_reinforcement");
    Camera(300, 200);
    QueuedAt(90, 100);
    Step(2, "solo_spawn_centered");
    CHECK(X() == 11 && Y() == 22);
    Put32(w.rm + 12, 0);
    Put32(w.used, 0);
    Step(3, "waiting_for_reinforcement"); /* landed, the first death's row still listed */
    Step(3, "waiting_for_reinforcement");
    Row(1, 190, 200);
    Step(1, "waiting_for_reinforcement");
    QueuedAt(190, 200);
    Step(2, "solo_spawn_centered");
    CHECK(X() == 300 && Y() == 200);
}

/* Solo with no landing seen on this player manager and two rows at the death: which is the death's is unknown, so
 * none is captured and the spawn stays. A row appearing in a later dead frame is captured against that frame. */
static void GateAmbiguousAndLateRows(void)
{
    MakeWorld();
    Started();
    Mission(1);
    Camera(11, 22);
    Step(3, "waiting_for_reinforcement");
    Step(3, "waiting_for_reinforcement");
    Row(0, 90, 100);
    Row(1, 190, 200);
    Step(1, "waiting_for_reinforcement");
    QueuedAt(190, 200);
    Step(2, "solo_anchor_unavailable");
    CHECK(X() == 120 && Y() == 130);
    fake_setup();
    MakeWorld();
    Started();
    Mission(1);
    Camera(11, 22);
    Step(3, "waiting_for_reinforcement");
    Step(3, "waiting_for_reinforcement");
    Put32(w.sm + 0x34, 1);
    Put32(w.rows + 12, 0x55);
    Step(1, "waiting_for_reinforcement");
    Row(1, 190, 200);
    Step(1, "waiting_for_reinforcement");
    QueuedAt(190, 200);
    Step(2, "solo_spawn_centered");
    CHECK(X() == 11 && Y() == 22);
}

/* The source's data unavailable when the anchor appears: waiting by name, and every association forgotten (the next
 * frame starts at the gate again), as an unavailable snapshot does. */
static void SourceWaitForgets(void)
{
    MakeWorld();
    Started();
    Mission(1);
    Frame();
    Global(CAMERA_GLOBAL, NULL);
    Die();
    Row(0, 90, 100);
    Frame();
    CHECK_STATUS("waiting_for_game_data:fallback_position");
    Global(CAMERA_GLOBAL, w.camera);
    fake_counts_reset();
    Frame();
    CHECK_EQ(g_tickReads, 1 + 6); /* the gate, then the snapshot: nothing was being followed */
    CHECK_EQ(fake_counts().read, 1 + 6 + 6); /* then the snapshot after the update: queued, so in progress */
    CHECK_STATUS("waiting_for_reinforcement");
    QueuedAt(90, 100);
    Spawn(2);
    Frame();
    CHECK_TICK("solo_anchor_unavailable"); /* the row was seen before it could be frozen: not this death's */
    CHECK(X() == 120 && Y() == 130);
}

/* What the reader refuses, and what it takes as absent. */
static void ReaderRefusesUnsupportedLayouts(void)
{
    static const char* const texts[] = {"disabled: Unsupported reinforcement layout", "disabled: Invalid lookup capacity",
        "disabled: Position index outside live data", "disabled: Unsupported active stratagem count",
        "disabled: Unsupported player-use bit", "disabled: Invalid spawn data pointer: reinforcement_records"};
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        MakeWorld();
        Started();
        Mission(c == 3 ? 1 : 2);
        Beacon(77, 11, 22);
        Frame();
        if (c == 0) Put32(w.rm + 8, 0);
        if (c == 1) Put32(w.pos + 0x30, 6);
        if (c == 2) Put32(w.pos + 8, 0);
        if (c == 3) Put32(w.sm + 0x34, 513);
        if (c == 4) Put32(w.pm + 0x3B4, 32);
        if (c == 5) Put64(w.entities, 0x20);
        Die();
        Frame();
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG(texts[c]);
    }
    /* A position row whose index is the empty one: the beacon has no position, so nothing is associated. */
    fake_setup();
    MakeWorld();
    Started();
    Put32(w.hash + 8 * 5 + 4, 0xFFFFFFFFu);
    Mission(2);
    Beacon(77, 11, 22);
    static RbfSnapshot snap;
    RbfReader reader = {fake_component(0), NULL};
    Die();
    CHECK_EQ(rbf_snapshot(&reader, &snap), RBF_OK);
    CHECK(snap.beacon_count == 1 && !snap.beacons[0].positioned);
    Frame();
    Commit(1);
    Frame();
    CHECK_STATUS("beacon_association_unavailable");
    CHECK(X() == 50 && Y() == 60);
}

/* ---- the source unit (spawn_data.lua unit_position) ------------------------------------------------------------- */

typedef struct Unit { uint8_t *em, *lookup, *registry, *generations, *objects, *object, *vtable, *scene; } Unit;

static Unit MakeUnit(void)
{
    Unit u;
    u.em = fake_heap(0xF32F18u + 24 * 4);
    u.lookup = fake_heap(64);
    memset(u.lookup, 0xFF, 64);
    Put32(u.lookup + 8 * 3, 11);
    Put32(u.lookup + 8 * 3 + 4, 0);
    Put64(u.em + 0xF22EC8u, (uint64_t)(uintptr_t)u.lookup);
    Put32(u.em + 0xF22EC8u + 8, 8);
    Put32(u.em + 0xF22EC8u + 12, 0xFFFFFFFFu);
    Put32(u.em + 0xF22EC8u + 16, 1);
    Put32(u.em + 0xF32F18u + 12, (1u << 22) | 3u);
    u.registry = fake_heap(0xA8);
    u.generations = fake_heap(4);
    u.objects = fake_heap(32);
    u.object = fake_heap(0x90);
    u.vtable = fake_heap(0xF0);
    u.scene = fake_heap(0x3C);
    Put64((uint8_t*)fake_exe() + EXE_REGISTRY, (uint64_t)(uintptr_t)u.registry);
    Put32(u.registry + 0x98, 4);
    Put64(u.registry + 0xA0, (uint64_t)(uintptr_t)u.generations);
    u.generations[3] = 1;
    Put64(u.registry + 0x88, (uint64_t)(uintptr_t)u.objects);
    Put64(u.objects + 24, (uint64_t)(uintptr_t)u.object);
    Put64(u.object, (uint64_t)(uintptr_t)u.vtable);
    Put64(u.vtable + 0xE8, fake_exe() + EXE_METHOD);
    Put64(u.object + 0x88, (uint64_t)(uintptr_t)u.scene);
    PutF(u.scene + 0x30, 1);
    PutF(u.scene + 0x34, 2);
    PutF(u.scene + 0x38, 3);
    Global(OWNER_GLOBAL, u.em);
    Put32(w.pm + 0x3A8, 11);
    return u;
}

/* The solo death of a player with a source unit: its scene-graph position is frozen and becomes the target. */
static void UnitSourcePosition(void)
{
    MakeWorld();
    MakeUnit();
    Started();
    Mission(1);
    Frame();
    Die();
    Row(0, 90, 100);
    fake_counts_reset();
    Frame();
    /* gate 1, snapshot 6, the source 10: the lookup's header and its one probe, the entity record, the registry block,
     * the generation, the object, its vtable, the method, the scene and its position (the Lua: 12 with the two globals) */
    CHECK_EQ(g_tickReads, 1 + 6 + 10);
    CHECK_EQ(fake_counts().read, 1 + 6 + 10 + 6); /* the snapshot after the update: the source is not read again */
    QueuedAt(90, 100);
    Spawn(2);
    Frame();
    CHECK(X() == 1 && Y() == 2);
    static const char* const texts[] = {"disabled: Unit generation changed", "disabled: Unsupported unit scene-graph layout",
        "disabled: Unit slot outside registry"};
    for (int c = 0; c < 3; c++)
    {
        fake_setup();
        MakeWorld();
        Unit u = MakeUnit();
        if (c == 0) u.generations[3] = 2;
        if (c == 1) Put64(u.vtable + 0xE8, fake_exe() + 0x1000);
        if (c == 2) Put32(u.registry + 0x98, 3);
        Started();
        Mission(1);
        Frame();
        Die();
        Row(0, 90, 100);
        Frame();
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG(texts[c]);
    }
}

/* ---- the main scenario (test_idle_equivalence.lua's, 2,100 frames) ---------------------------------------------- *
 * A step's "before" runs before that frame's tick, its "during" inside the game's update, between the tick and the
 * check after the update. With the core's hook the check after the update sees a "during" change in the same frame, as
 * the Lua's after-update check saw its "during" steps; without it both checks run before the update, so a "during"
 * change is seen on the next frame, as in the 1:1 port. The Lua's error in an update below (frame 1430) has no
 * HellForge equivalent and is left out. */

typedef struct MainStep { int frame; int during; int what; } MainStep;
enum { M_MISSION2, M_BEACON77, M_DIE, M_COMMIT1, M_LAND, M_BEACON78, M_COMMIT2, M_SHIP, M_RESTART, M_INITIAL, M_SOLO1,
    M_CAMERA500, M_SOLO1_COMMIT, M_CAMERA30, M_SOLO2, M_SOLO2_COMMIT, M_LAND_CLEAR, M_SOLO3, M_SOLO3_COMMIT, M_PENDING0,
    M_LAYOUT };

static void MainEvent(int what)
{
    switch (what)
    {
    case M_MISSION2: Mission(2); break;
    case M_BEACON77: Beacon(77, 11, 22); break;
    case M_DIE: Die(); break;
    case M_COMMIT1: Commit(1); break;
    case M_LAND: Land(); break;
    case M_BEACON78: Beacon(78, 40, 50); break;
    case M_COMMIT2: Commit(2); break;
    case M_SHIP: Put32(w.mode + 8, 0); break;
    case M_RESTART: Global(PM_GLOBAL, w.pm2); w.p = w.pm2; Spawn(0); Mission(1); break;
    case M_INITIAL: Spawn(2); Xy(5, 5); break;
    case M_SOLO1: Die(); Row(0, 90, 100); break;
    case M_CAMERA500: Camera(500, 600); break;
    case M_SOLO1_COMMIT: Beacon(77, 90, 100); Commit(1); Xy(120, 130); break;
    case M_CAMERA30: Camera(30, 40); break;
    case M_SOLO2: Die(); Row(1, 60, 70); break;
    case M_SOLO2_COMMIT: Beacon(77, 60, 70); Commit(1); Xy(100, 110); break;
    case M_LAND_CLEAR: Land(); Put32(w.sm + 0x34, 0); break;
    case M_SOLO3: Die(); Row(0, 20, 30); break;
    case M_SOLO3_COMMIT: Beacon(77, 20, 30); Commit(1); break;
    case M_PENDING0: Spawn(0); Mission(1); break;
    case M_LAYOUT: Put32(w.p + 0x84, 5); break;
    default: break;
    }
}

static const MainStep kMain[] = {
    {100, 0, M_MISSION2}, {100, 0, M_BEACON77}, {300, 1, M_DIE}, {320, 1, M_COMMIT1}, {360, 1, M_LAND},
    {500, 0, M_BEACON78}, {520, 1, M_DIE}, {540, 1, M_COMMIT2}, {580, 1, M_LAND}, {700, 0, M_SHIP},
    {800, 0, M_RESTART}, {820, 1, M_INITIAL}, {850, 1, M_LAND},
    {1000, 1, M_SOLO1}, {1010, 0, M_CAMERA500}, {1020, 1, M_SOLO1_COMMIT}, {1060, 1, M_LAND},
    {1150, 0, M_CAMERA30}, {1200, 1, M_SOLO2}, {1220, 1, M_SOLO2_COMMIT}, {1260, 1, M_LAND_CLEAR},
    {1400, 1, M_SOLO3}, {1420, 1, M_SOLO3_COMMIT}, {1500, 1, M_LAND_CLEAR},
    {1600, 1, M_DIE}, {1610, 0, M_SHIP}, {1700, 0, M_PENDING0}, {1720, 1, M_INITIAL}, {1750, 1, M_LAND},
    {1900, 1, M_DIE}, {1910, 0, M_LAYOUT},
};

/* The commits each correction follows (all inside the update) and where it puts the pod. */
typedef struct Expected { int commit; float x, y; } Expected;
static const Expected kCorrections[] = {{320, 11, 22}, {540, 40, 50}, {1020, 15, 25}, {1220, 30, 40}, {1420, 30, 40}};

static int g_mainFrame;
static float g_aroundTheStep[4]; /* X, Y right before the update's step and right after it */

static void RunMainSteps(int frame, int during)
{
    for (size_t i = 0; i < sizeof kMain / sizeof kMain[0]; i++)
        if (kMain[i].frame == frame && kMain[i].during == during) MainEvent(kMain[i].what);
}

static void MainDuring(void)
{
    g_aroundTheStep[0] = X();
    g_aroundTheStep[1] = Y();
    RunMainSteps(g_mainFrame, 1);
    g_aroundTheStep[2] = X();
    g_aroundTheStep[3] = Y();
}

/* The correction expected on this frame (its index), or -1: on the commit's frame with the hook, the next without. */
static int CorrectionOn(int frame)
{
    for (int i = 0; i < (int)(sizeof kCorrections / sizeof kCorrections[0]); i++)
        if (kCorrections[i].commit + !g_hooked == frame) return i;
    return -1;
}

/* Whether the component wrote X, Y on this frame: before the update's step (the tick, or both checks without the hook)
 * or after it (the check after the update). before: X, Y when the frame began. */
static int WroteXy(const float* before)
{
    return g_aroundTheStep[0] != before[0] || g_aroundTheStep[1] != before[1] || X() != g_aroundTheStep[2] ||
           Y() != g_aroundTheStep[3];
}

static void PlayMain(int hooked)
{
    MakeWorld();
    StartedOn(hooked);
    int corrected = 0;
    uint32_t idle_reads = 0, idle_frames = 0, idle_logs = 0, idle_posts = 0;
    for (g_mainFrame = 1; g_mainFrame <= 2100; g_mainFrame++)
    {
        int frame = g_mainFrame;
        RunMainSteps(frame, 0);
        const float before[2] = {X(), Y()};
        g_inside = MainDuring;
        fake_counts_reset();
        Frame();
        int idle = (frame > 110 && frame < 300) || (frame > 710 && frame < 800) || (frame > 1270 && frame < 1400);
        if (idle)
        {
            idle_reads += fake_counts().read;
            idle_logs += fake_counts().log;
            idle_posts += (uint32_t)Posting();
            idle_frames++;
        }
        int expected = CorrectionOn(frame);
        if (expected >= 0)
        {
            CHECK(WroteXy(before) && X() == kCorrections[expected].x && Y() == kCorrections[expected].y);
            corrected++;
        }
        else if (WroteXy(before)) { test_failures++; printf("  FAILED: an X, Y written on frame %d\n", frame); }
    }
    CHECK_EQ(corrected, 5);
    CHECK_LOG("corrections=5;");
    CHECK_NO_LOG("corrections=6");
    CHECK_LOG("initial_deployment_unchanged");
    CHECK_LOG("association=unmarked_remote)");
    CHECK_LOG("disabled: Unsupported player layout");
    CHECK(!vpm_running(fake_component(0)) && !Posting());
    CHECK_EQ(idle_reads, idle_frames); /* 1 read per idle frame: the spawn state */
    CHECK_EQ(idle_logs + idle_posts, 0); /* no log, no check after the update */
}

static void MainScenario(void) { PlayMain(1); }
static void MainScenarioWithoutTheHook(void) { PlayMain(0); }

int main(void)
{
    RUN(PlanCorrectsAUsedBeacon);
    RUN(PlanTeammateBeacon);
    RUN(PlanFirstUnusedRemote);
    RUN(PlanExclusions);
    RUN(PlanSoloScenarios);
    RUN(ChecksBeforeTheWrite);
    RUN(TicksFromGameLoaded);
    RUN(StaysOffWithVanillaPlus);
    RUN(StagedStartupThenCorrection);
    RUN(UnreadableTransitionRecovers);
    RUN(ReloadForgetsAssociations);
    RUN(TeammateBeaconThroughTheReader);
    RUN(EveryGameplayMode);
    RUN(SoloAnchorIsFrozen);
    RUN(FrameBudget);
    RUN(FrameBudgetWithoutTheHook);
    RUN(LayoutMetAtTheDeath);
    RUN(InvalidPointersRefuse);
    RUN(RefusalRestoresTheCorrection);
    RUN(RestoresOnlyItsOwnWrite);
    RUN(ReadOnlyTargetIsRefused);
    RUN(ChangedManagerIsNoticed);
    RUN(CommitInsideTheUpdate);
    RUN(NotOwnedHasNoCheckAfterTheUpdate);
    RUN(CommitInsideTheUpdateWithoutTheHook);
    RUN(PostCheckStopsWithTheComponent);
    RUN(FaultAfterTheUpdate);
    RUN(GateInitialDeploymentAndAliveToPending);
    RUN(GateSoloDeaths);
    RUN(GateAmbiguousAndLateRows);
    RUN(SourceWaitForgets);
    RUN(ReaderRefusesUnsupportedLayouts);
    RUN(UnitSourcePosition);
    RUN(MainScenario);
    RUN(MainScenarioWithoutTheHook);
    TEST_END();
}
