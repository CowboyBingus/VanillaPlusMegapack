/* Enemy Collision Synchronized: the Lua tests' scenarios (components/EnemyCollisionSynchronized/tests) on the fake game.
 * test_snapshot.lua: the reader on one unit of every profile (Fix); test_performance.lua, test_repose_cooldown.lua,
 * test_metadata_cache.lua: a scene of Bile Titans (Scene), with the calls per poll pinned; test_fling.lua,
 * test_settlement.lua, test_completion.lua, test_repair.lua: the policy on synthetic units; test_loader.lua: the bind,
 * the cadence, raised polls, a quiet busy mission; test_profiles.py: the catalogue. Dropped with the Lua: the
 * profiler's, module wrapper's, FFI-name, hostile-VM, float-decoder and garbage tests. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/enemy_collision_synchronized/ecs_internal.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_enemy_collision_synchronized};
#define DT (1.0f / 60)
#define UNIT 0x400007u

static EcsUnit g_u;
static EcsAction g_actions[ECS_MAX_ACTORS];

/* ---- memory helpers --------------------------------------------------------------------------------------------- */

static uint8_t* G(void) { return (uint8_t*)fake_game(); }
static uint8_t* E(void) { return (uint8_t*)fake_exe(); }
static uint8_t* Heap(size_t n) { return fake_heap(n); }
static void P32(void* at, uint32_t v) { memcpy(at, &v, 4); }
static void P64(void* at, uint64_t v) { memcpy(at, &v, 8); }
static void Ptr(void* at, const void* target) { P64(at, (uint64_t)(uintptr_t)target); }
static uint32_t G32(const void* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t G64(const void* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static int Is(const char* a, const char* b) { return a != NULL && strcmp(a, b) == 0; }

static void Rotation(double m[16], double x, double y, double z, double degrees)
{
    double c = cos(degrees * 3.14159265358979323846 / 180), s = sin(degrees * 3.14159265358979323846 / 180);
    double v[16] = {c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, x, y, z, 1};
    memcpy(m, v, sizeof v);
}

static void Matrix(uint8_t* at, double x, double y, double z, double degrees)
{
    double m[16];
    float f[16];
    Rotation(m, x, y, z, degrees);
    for (int i = 0; i < 16; i++) f[i] = (float)m[i];
    memcpy(at, f, sizeof f);
}

static void Hex(uint8_t* at, const char* hex)
{
    for (const char* c = hex; c[0] != 0 && c[1] != 0;)
    {
        if (*c == ' ') { c++; continue; }
        char pair[3] = {c[0], c[1], 0};
        *at++ = (uint8_t)strtoul(pair, NULL, 16);
        c += 2;
    }
}

static int Named(const char* name)
{
    for (int i = 0; i < ECS_PROFILE_COUNT; i++)
        if (Is(EcsProfiles[i].name, name)) return i;
    return -1;
}

/* ---- the game's routines: stubs that count, and the bytes the bind checks ---------------------------------------- */

typedef struct Runtime { uintptr_t manager; uint32_t index; uint8_t* update; } Runtime;
static struct
{
    uint32_t poses, disables, stops, requests, clocks, entity, last_pose, index, runtimes, keep_update;
    uintptr_t manager;
    double per_read;
    void (*on_pose)(void);
    void (*on_stop)(void);
    Runtime runtime[64];
} N;

static void StubStop(void* manager, uint32_t index)
{
    N.stops++;
    N.manager = (uintptr_t)manager;
    N.index = index;
    for (uint32_t i = 0; i < N.runtimes && !N.keep_update; i++)
        if (N.runtime[i].manager == (uintptr_t)manager && N.runtime[i].index == index) *N.runtime[i].update = 0;
    if (N.on_stop != NULL) N.on_stop();
}
static void StubCompletion(void* service, uintptr_t zero, uint32_t entity) { N.requests++; N.entity = entity; }
static void StubPosition(uint32_t actor, const float* p)
{
    N.poses++;
    N.last_pose = actor;
    if (N.on_pose != NULL) N.on_pose();
}
static void StubRotation(uint32_t actor, const float* q) {}
static void StubEnabled(const uint32_t* ids, uint32_t count, uint32_t enabled) { N.disables++; }
static double StubClock(void) { N.clocks++; return N.per_read * fake_counts().read; }
static const EcsNatives kStubs = {StubStop, StubCompletion, StubPosition, StubRotation, StubEnabled, StubClock};

static void AddRuntime(uintptr_t manager, uint32_t index, uint8_t* update)
{
    if (N.runtimes < 64) N.runtime[N.runtimes++] = (Runtime){manager, index, update};
}

/* The reviewed routines' bytes: both setters' first 8 in the exe, the stop and completion routines in game.dll. */
static void PutCode(void)
{
    for (int i = 0; i < EcsCodePinCount; i++)
        Hex(((EcsCodePins[i].flags & VPM_PIN_EXE) ? E() : G()) + EcsCodePins[i].rva, EcsCodePins[i].pattern);
}

static void Game(void)
{
    Ptr(G() + 0x3326338, E() + 0x27CD910);
    Ptr(E() + 0x27CD910 + 8, E() + 0x77F4F0);
    Ptr(E() + 0x27CD910 + 0x60, E() + 0x799880);
    Ptr(E() + 0x27CD910 + 0x68, E() + 0x799BA0);
    PutCode();
    Ptr(G() + 0x346D500, Heap(24));
}

/* Started and bound (the tests call EcsApply themselves; frames bind again through the tick). */
static VpmComponent* Started(void)
{
    Game();
    EcsUseNatives(&kStubs);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(EcsBind(fake_component(0)), 1);
    return fake_component(0);
}

static int Apply(double now)
{
    int ready = 0;
    Ecs.now = now;
    return EcsApply(&ready);
}

/* ---- the Lua's snapshot fixture: one listed unit, its profile's main bodies and one auxiliary actor 27 m from its node */

static struct
{
    int corpse, profile;
    uint32_t bodies, extra;
    uint8_t *mode, *manager, *entities, *entity, *runtime, *sync, *generation, *list, *handles, *actors, *bodies_, *getter;
} F;

static uint8_t* Actor(uint32_t i) { return F.actors + 40u * i; }
static uint8_t* Body(uint32_t i) { return F.bodies_ + 160u * i; }

static void FixManager(int corpse, const EcsProfile* p)
{
    uint8_t *rm = Heap(88), *cm = Heap(88);
    Ptr(G() + 0x3326948, rm);
    Ptr(G() + 0x3326920, cm);
    F.manager = corpse ? cm : rm;
    F.entities = Heap(8);
    F.entity = Heap(24);
    P64(F.entity, p->resource);
    P32(F.entity + 8, 37);
    P32(F.entity + 12, UNIT);
    P32(F.entity + 16, 99);
    F.runtime = Heap(corpse ? 72 : 11192);
    F.sync = Heap(corpse ? 56 : 432);
    P32(F.manager + (corpse ? 16 : 4), 1);
    P32(F.manager + (corpse ? 24 : 12), 1);
    P32(F.manager + (corpse ? 28 : 16), 1);
    Ptr(F.manager + (corpse ? 64 : 56), F.entities);
    Ptr(F.entities, F.entity);
    Ptr(F.manager + 72, F.runtime);
    Ptr(F.manager + 80, F.sync);
    if (corpse) return;
    P32(F.runtime + 11160, p->bodies);
    F.runtime[11172] = 1;
    P32(F.sync, p->bodies);
    P32(F.sync + 184, p->bodies);
    for (uint32_t i = 0; i < p->bodies; i++) P32(F.runtime + i * 712, 0x90000001u + i);
    AddRuntime((uintptr_t)F.manager, 0, F.runtime + 11172);
}

static void FixUnitObject(const EcsProfile* p)
{
    uint8_t *registry = Heap(0xA8), *generations = Heap(32), *slots = Heap(256), *object = Heap(0x100), *nodes = Heap(p->nodes * 64u);
    Ptr(E() + 0x1A100F0, registry);
    Ptr(registry + 0xA0, generations);
    Ptr(registry + 0x88, slots);
    P32(registry + 0x98, 32);
    F.generation = generations + 7;
    *F.generation = 1;
    Ptr(slots + 56, object);
    P32(object + 8, UNIT);
    P32(object + 0x70, p->nodes);
    Ptr(object + 0x88, nodes);
    Matrix(nodes + 72 * 64, -161.2, 107.25, 20.17, 0);
    uint8_t* lists = Heap(32 * 24);
    Ptr(E() + 0x27C5B40, lists);
    F.list = lists + 7 * 24;
    P32(F.list, UNIT);
    P32(F.list + 4, 0x40000000u + F.extra);
    F.handles = Heap(128);
    Ptr(F.list + 8, F.handles);
}

static void FixActors(int corpse, const EcsProfile* p, uint32_t aux, uint32_t node)
{
    uint8_t* pool = E() + 0x2369B00 + 64 * 21;
    F.actors = Heap(32 * 40);
    Ptr(pool, F.actors);
    P32(pool + 28, 40);
    P32(pool + 36, 32);
    P32(pool + 40, 255);
    P32(pool + 52, 0xC0000000u);
    uint8_t *world = Heap(64), *vt = Heap(144);
    F.bodies_ = Heap(32 * 160);
    Ptr(E() + 0x27BA8A8 + 176 * 2, world);
    Ptr(world, vt);
    F.getter = vt + 136;
    Ptr(F.getter, E() + 0xD0CFA0);
    Ptr(world + 24, F.bodies_);
    for (uint32_t index = 1; index <= F.extra; index++)
    {
        uint32_t id = 0x90000000u + index;
        int extra = index == F.extra;
        P32(F.handles + 4 * (index - 1), id);
        P32(Actor(index), id);
        P32(Actor(index) + 12, UNIT);
        P32(Actor(index) + 16, 1);
        P32(Actor(index) + 20, index);
        P32(Actor(index) + 24, extra ? aux : p->main[index - 1]);
        P32(Actor(index) + 28, extra ? 72 : 0);
        P32(Actor(index) + 32, extra ? node : p->main[index - 1]);
        if (extra) Matrix(Body(index), -183.4, 119.01, 30.1, 0);
        else Matrix(Body(index), 0, 0, 0, 0);
        P32(Body(index) + 108, extra ? 20 : corpse ? 48 : 52);
        P32(Body(index) + 144, id);
        P32(Body(index) + 148, UNIT);
    }
}

static void Fix(int corpse, int profile)
{
    memset(&F, 0, sizeof F);
    memset(&N, 0, sizeof N);
    const EcsProfile* p = &EcsProfiles[profile];
    F.corpse = corpse;
    F.profile = profile;
    F.bodies = p->bodies;
    F.extra = p->bodies + 1;
    F.mode = Heap(0x44);
    P32(F.mode + 8, 1);
    P32(F.mode + 0x40, 1);
    Ptr(G() + 0x33266A0, F.mode);
    FixManager(corpse, p);
    FixUnitObject(p);
    uint32_t aux = p->impaler ? 0x70F1DB61u : p->actors[0].name, node = 0;
    CHECK(EcsProfileActor(p, aux, &node));
    FixActors(corpse, p, aux, node);
}

/* The fixture's unit read in full, as the reader would visit it (the Lua's M.snapshot units). */
static int Inspect(EcsUnit* u)
{
    static uint8_t header[24];
    memcpy(header, F.entity, sizeof header);
    EcsReadsBegin();
    EcsReaderBegin();
    EcsVisit v = {0, F.corpse ? 0 : G32(F.sync), G32(F.manager + (F.corpse ? 28 : 16)), F.corpse, F.profile,
        (uint64_t)(uintptr_t)F.entity, (uintptr_t)F.manager, (uintptr_t)F.entities, (uintptr_t)F.runtime,
        (uintptr_t)F.sync, (uintptr_t)F.mode, header, G64(F.entities), G64(G() + 0x33266A0), F.mode};
    return EcsInspect(&v, u);
}

static int ActorSame(const EcsActor* a)
{
    static EcsGuard items[4];
    static uint8_t bytes[56];
    EcsGuards guards;
    EcsGuardsInit(&guards, items, 4, bytes, sizeof bytes);
    return EcsGuardAdd(&guards, a->identity_address, a->identity, 4) && EcsGuardAdd(&guards, a->data_address, a->data, 40) &&
        EcsGuardAdd(&guards, a->body_address + 64, a->body + 64, 4) &&
        EcsGuardAdd(&guards, a->body_address + 144, a->body + 144, 8) && EcsSame(&guards);
}

/* The Lua's snapshot substitute: the fixture's unit, then a change before it is consumed. */
static int ChangedBeforeConsume(double now, void (*change)(void))
{
    Ecs.now = now;
    EcsApplyBegin();
    CHECK_EQ(Inspect(&g_u), 1);
    g_u.verified = 1;
    change();
    int consumed = EcsConsume(&g_u);
    EcsApplyEnd(1);
    return consumed;
}

/* ---- the catalogue (test_profiles.py) and the bind (test_loader.lua) ------------------------------------------------ */

static int ProfileAsReviewed(const EcsProfile* p)
{
    for (uint32_t i = 1; i < p->actor_count; i++)
        if (p->actors[i - 1].name >= p->actors[i].name) return 0;
    for (uint32_t i = 0; i < p->actor_count; i++)
        if (EcsProfileMain(p, p->actors[i].name)) return 0;
    for (uint32_t i = 0; i < p->disabled_count; i++)
        if (!EcsProfileMain(p, p->disabled_main[i])) return 0;
    for (uint32_t i = 0; i < p->dynamic_count; i++)
        if (!EcsProfileMain(p, p->dynamic_main[i])) return 0;
    return p->finish_disabled == (p->disabled_count == p->bodies) && p->nodes <= 256 && p->actor_count > 0;
}

static void CatalogueAsReviewed(void)
{
    uint32_t actors = 0, tripods = 0, dynamic = 0, node = 0;
    for (int i = 0; i < ECS_PROFILE_COUNT; i++)
    {
        const EcsProfile* p = &EcsProfiles[i];
        CHECK_EQ(EcsProfileOf(p->resource), i);
        CHECK(ProfileAsReviewed(p));
        CHECK(p->bodies == 6 || p->bodies == 10 || p->bodies == 14 || p->bodies == 15);
        actors += p->actor_count;
        tripods += (uint32_t)p->finish_disabled;
        dynamic += p->dynamic_count;
        CHECK(EcsProfileActor(p, p->actors[p->actor_count - 1].name, &node) && node == p->actors[p->actor_count - 1].node);
    }
    CHECK_EQ(actors, 680);
    CHECK_EQ(tripods, 2);
    CHECK_EQ(dynamic, 3);
    CHECK_EQ(EcsProfiles[Named("Automaton assault walker")].dynamic_count, 3);
    CHECK_EQ(EcsProfileOf(0x1234), -1);
    CHECK(!EcsProfileActor(&EcsProfiles[0], 0x12345678u, &node));
}

static void BindsOnceThePhysicsApiIsSet(void)
{
    memset(&N, 0, sizeof N);
    Game();
    P64(G() + 0x3326338, 0);
    EcsUseNatives(&kStubs);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_counts_reset();
    fake_frames(30, DT);
    CHECK(strstr(vpm_status(fake_component(0)), "physics API") != NULL);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches + fake_counts().log + fake_counts().write, 0);
    Ptr(G() + 0x3326338, E() + 0x27CD910);
    fake_frames(3, DT);
    /* The code was checked at HF_EVENT_GAME_LOADED (TheCodeIsCheckedAtLoad): the bind checks the table only. */
    CHECK_EQ(fake_counts().code_matches, 0);
    CHECK_LOG("[Enemy Collision Synchronized] v2.13.0: waiting_for_mission");
    CHECK(Is(vpm_status(fake_component(0)), "waiting_for_mission"));
    CHECK_EQ(Ecs.polls, 1);
}

static void Break(int c)
{
    if (c == 0) Ptr(G() + 0x3326338, E() + 0x27CD918);
    if (c == 1) Ptr(E() + 0x27CD910 + 0x60, E() + 0x799881);
    if (c == 2) E()[0x799880] = 0x90;
    if (c == 3) E()[0x799BA0 + 7] = 0x90;
    if (c == 4) G()[0x7ABD00 + 151] = 0x90;
    if (c == 5) G()[0x13C0350 + 421] = 0x90;
}

static void RefusesWhatIsNotAsReviewed(void)
{
    static const char* const texts[] = {"disabled: Unsupported physics API", "disabled: Unsupported physics function",
        "disabled: Position setter changed", "disabled: Rotation setter changed", "disabled: Ragdoll stop routine changed",
        "disabled: Corpse completion request changed"};
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        Game();
        Break(c);
        EcsUseNatives(&kStubs);
        fake_start(kDefs, 1);
        fake_fire(HF_EVENT_GAME_LOADED);
        fake_frames(1, DT);
        /* changed code reads as code not decoded yet: the core waits for it, then stops the component, naming it */
        if (c >= 2) CHECK(vpm_running(fake_component(0)));
        if (c >= 2) fake_frames(60, 1.0f);
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG(texts[c]);
    }
    CHECK_LOG("disabled: Corpse completion request changed (game.dll 0x13C04D0)");
}

/* ---- game.dll's code decoded in parts after HF_EVENT_GAME_LOADED (vpm_when_code_ready) ------------------------- */

static void EncodeCode(void)
{
    for (int i = 0; i < EcsCodePinCount; i++)
        memset(((EcsCodePins[i].flags & VPM_PIN_EXE) ? E() : G()) + EcsCodePins[i].rva, 0xCC, 128);
}

/* Decoded at load: the 8 code comparisons at HF_EVENT_GAME_LOADED and nothing else there; the first poll binds. */
static void TheCodeIsCheckedAtLoad(void)
{
    memset(&N, 0, sizeof N);
    Game();
    EcsUseNatives(&kStubs);
    fake_start(kDefs, 1);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    /* Both setters, the stop routine in 2 parts and the completion request in 4 (128 bytes a call). */
    CHECK_EQ(fake_counts().code_matches, 8);
    CHECK_EQ(fake_counts().read + fake_counts().log + fake_counts().write, 0);
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(fake_counts().code_matches, 0);
    CHECK_LOG("[Enemy Collision Synchronized] v2.13.0: waiting_for_mission");
    CHECK_EQ(Ecs.polls, 1);
}

/* Still encoded at the event, decoded two seconds later: no poll and no read before; the bind on the first poll after
 * the core's next look. */
static void TheCodeDecodedLaterBindsThen(void)
{
    memset(&N, 0, sizeof N);
    Game();
    EncodeCode();
    EcsUseNatives(&kStubs);
    fake_start(kDefs, 1);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(fake_counts().code_matches, 1); /* the first setter does not match: the look stops there */
    fake_counts_reset();
    fake_frames(120, DT);
    CHECK_EQ(fake_counts().code_matches, 4); /* one look every 30 frames */
    CHECK_EQ(fake_counts().read + fake_counts().log + fake_counts().write, 0);
    CHECK_EQ(Ecs.polls, 0);
    CHECK(strstr(vpm_status(fake_component(0)), "physics API") != NULL);
    PutCode();
    fake_counts_reset();
    fake_frames(30, DT);
    CHECK_EQ(fake_counts().code_matches, 8);
    fake_frames(3, DT); /* the next poll (every 3/64 s) */
    CHECK_LOG("[Enemy Collision Synchronized] v2.13.0: waiting_for_mission");
    CHECK(Is(vpm_status(fake_component(0)), "waiting_for_mission"));
    CHECK(Ecs.polls >= 1);
    fake_counts_reset();
    fake_frames(300, DT);
    CHECK_EQ(fake_counts().code_matches + fake_counts().log, 0);
}

/* Never decoded: stopped after 60 s naming the first setter; no poll, no read, no command. */
static void TheCodeNeverDecodedStopsItAfterAMinute(void)
{
    memset(&N, 0, sizeof N);
    Game();
    EncodeCode();
    EcsUseNatives(&kStubs);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_counts_reset();
    fake_frames(59, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(1, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Enemy Collision Synchronized] disabled: Position setter changed (helldivers2.exe 0x799880)");
    CHECK_EQ(fake_counts().read + fake_counts().write, 0);
    CHECK_EQ(Ecs.polls, 0);
    CHECK_EQ(N.disables, 0);
    CHECK_NO_LOG("waiting_for_mission");
    CHECK_NO_LOG("polls=");
}

static void PollsEveryIntervalOfFrameTime(void)
{
    static const int rates[3][2] = {{60, 3}, {30, 2}, {144, 7}};
    memset(&N, 0, sizeof N);
    Started();
    fake_frames(1, 1.0f / 120);
    CHECK_EQ(Ecs.polls, 1);
    fake_counts_reset();
    fake_frames(1, 1.0f / 120);
    CHECK_EQ(Ecs.polls, 1);
    for (int r = 0; r < 3; r++)
    {
        fake_frames(10, 1.0f / (float)rates[r][0]);
        uint32_t before = Ecs.polls;
        fake_frames(rates[r][1] * 20, 1.0f / (float)rates[r][0]);
        CHECK_EQ(Ecs.polls - before, 20);
    }
    /* Outside a mission a poll frame makes no call either: the mode slot is a plain load. */
    FakeCounts n = fake_counts();
    CHECK_EQ(n.read + n.write + n.code_matches + n.log + n.other + N.clocks, 0);
    uint32_t before = Ecs.polls;
    fake_frames(2, -1.0f); /* no usable frame time: the tick count */
    CHECK_EQ(Ecs.polls - before, 1);
}

static void RaisedPollsRetryThenStop(void)
{
    Fix(1, Named("Impaler"));
    VpmComponent* self = Started();
    fake_frames(1, DT);
    P32(F.manager + 16, 0); /* the count above the capacity: "Manager bounds changed" */
    fake_frames(21, DT);
    CHECK_EQ(Ecs.retries, 7);
    CHECK(Is(vpm_status(self), "waiting_for_stable_data") && vpm_running(self));
    P32(F.manager + 16, 1);
    fake_frames(3, DT);
    CHECK(Is(vpm_status(self), "ready"));
    P32(F.manager + 16, 0);
    fake_frames(24, DT);
    CHECK(!vpm_running(self));
    CHECK_EQ(Ecs.retries, 15);
    CHECK_LOG("disabled: stopped after: Manager bounds changed");
    CHECK_LOG("v2.13.0 stopped: polls=");
}

/* ---- the reader on the fixture (test_snapshot.lua) ------------------------------------------------------------- */

static void ModeFieldTwoAndMissionExit(void)
{
    for (int corpse = 0; corpse < 2; corpse++)
    {
        fake_setup();
        Fix(corpse, Named("Impaler"));
        Started();
        P32(F.mode + 0x40, 2); /* recorded: 2 in a mission and on the ship; not a mission selector */
        CHECK(Apply(0));
        CHECK_EQ(Ecs.observed, 1);
        CHECK_EQ(N.poses, 1);
        CHECK_EQ(Inspect(&g_u), 1);
        P32(F.mode + 8, 0);
        CHECK(!EcsSame(&g_u.guards)); /* mission exit invalidates a pending unit */
        CHECK(Apply(0.1));
        CHECK(Ecs.observed == 0 && Is(Ecs.preflight, "waiting_for_mission"));
    }
}

static void DisabledTaggedBodyDoesNotReject(void)
{
    for (int corpse = 0; corpse < 2; corpse++)
    {
        fake_setup();
        Fix(corpse, Named("Impaler"));
        Started();
        P32(F.list + 4, 0x40000011u);
        P32(F.handles + 16 * 4, 0x90000011u);
        P32(Actor(17), 0x90000011u);
        P32(Actor(17) + 12, UNIT);
        P32(Actor(17) + 20, 17);
        P32(Actor(17) + 24, 0x1245EDBAu);
        P32(Body(17) + 64, 1998);
        P32(Body(17) + 108, 22);
        P32(Body(17) + 144, 0xD0000011u);
        P32(Body(17) + 148, UNIT);
        CHECK_EQ(Inspect(&g_u), 1);
        CHECK_EQ(EcsPlan(&g_u, g_actions), 1);
        CHECK(g_u.main_enabled == 15 && g_u.main_static == 15);
        P32(Actor(17) + 16, 1); /* enabled with a mismatched body: rejected */
        CHECK_EQ(Inspect(&g_u), -1);
        CHECK(strstr(EcsWhy(), "Physics body identity changed") != NULL);
    }
}

static void PreflightAndChangedGetter(void)
{
    for (int corpse = 0; corpse < 2; corpse++)
    {
        fake_setup();
        Fix(corpse, Named("Impaler"));
        Started();
        for (int pass = 0; pass < 3; pass++)
        {
            uint32_t before = Ecs.getter_checks;
            CHECK(Apply(pass));
            CHECK(Is(Ecs.preflight, "verified") && Ecs.getter_checks - before == 17);
        }
        P32(F.mode + 8, 0);
        uint32_t before = Ecs.getter_checks;
        CHECK(Apply(5));
        CHECK(Is(Ecs.preflight, "waiting_for_mission") && Ecs.getter_checks == before);
        P32(F.mode + 8, 1);
        Ptr(F.getter, E() + 0xD11661);
        CHECK(!Apply(6));
        CHECK(strstr(EcsWhy(), "Body getter changed: world_index=2") != NULL && strstr(EcsWhy(), "offset=13702753") != NULL);
        CHECK(Ecs.getter_failures == 1 && strstr(Ecs.last_getter_failure, "world_index=2") != NULL);
    }
}

static void RagdollRecord(void)
{
    CHECK(g_u.root_body == 0 && g_u.main_bodies[0].id == 0x90000001u && g_u.update_enabled == 1);
    CHECK(g_u.main_body_count == 15 && g_u.pose_guards.count == 15);
    Matrix(Body(2), .6, 0, 0, 0);
    CHECK(!EcsSame(&g_u.pose_guards)); /* an independent limb invalidates the stop observation */
    EcsGuards root = g_u.pose_guards;
    root.count = 1;
    CHECK(EcsSame(&root)); /* the root's guard alone would miss it */
    Matrix(Body(2), 0, 0, 0, 0);
    CHECK(g_u.update_address == (uintptr_t)F.runtime + 11172 && g_u.signature.count == 15);
    F.runtime[11172] = 0;
    CHECK_EQ(Inspect(&g_u), 1);
    CHECK(g_u.update_enabled == 0 && EcsPlan(&g_u, g_actions) == 1); /* auxiliary repair goes on after a stop */
    F.runtime[11172] = 1;
}

static void UnitRecordAndExclusions(void)
{
    for (int corpse = 0; corpse < 2; corpse++)
    {
        fake_setup();
        Fix(corpse, Named("Impaler"));
        Started();
        CHECK_EQ(Inspect(&g_u), 1);
        CHECK(g_u.main_enabled == 15 && g_u.main_static == 15 && g_u.owner == 0 && g_u.active == 1);
        CHECK(g_u.manager == (uintptr_t)F.manager && g_u.index == 0);
        if (!corpse) RagdollRecord();
        CHECK_EQ(EcsPlan(&g_u, g_actions), 1);
        CHECK(g_actions[0].gap > 26 && g_actions[0].kind == ECS_REPOSE);
        P32(Body(16) + 148, 0);
        CHECK(!ActorSame(&g_u.actors[g_actions[0].actor])); /* body reassignment invalidates a pending repair */
        P32(Body(16) + 148, UNIT);
        P32(Actor(1) + 16, 0);
        CHECK_EQ(Inspect(&g_u), 1);
        CHECK_EQ(EcsPlan(&g_u, g_actions), 0); /* sinking must not resurrect collision */
        P32(Actor(1) + 16, 1);
        *F.generation = 2;
        CHECK_EQ(Inspect(&g_u), -1);
        *F.generation = 1;
        P32(Body(16) + 148, 0);
        CHECK_EQ(Inspect(&g_u), -1);
    }
}

static void RagdollLifecycleExclusions(void)
{
    int added;
    Fix(0, Named("Impaler"));
    Started();
    P32(F.sync, 0);
    P32(F.sync + 184, 0);
    ((EcsHistory*)EcsTablePut(&EcsHistories, UNIT, &added))->armed = 1;
    CHECK(Apply(0));
    CHECK(Ecs.observed == 0 && EcsTableFind(&EcsHistories, UNIT) == NULL); /* living: no prior reference kept */
    P32(F.sync, 15);
    P32(F.sync + 184, 7);
    CHECK(Apply(.1) && Ecs.observed == 0); /* mixed pose counts */
    P32(F.sync + 184, 15);
    F.runtime[11173] = 1;
    CHECK(Apply(.2) && Ecs.observed == 0); /* the first-stop correction */
    F.runtime[11173] = 0;
    P32(F.mode + 8, 0);
    CHECK(Apply(.3) && Ecs.observed == 0 && Is(Ecs.preflight, "waiting_for_mission"));
    P32(F.mode + 8, 1);
    CHECK(Apply(.4) && Ecs.observed == 1);
}

static void EmptiesTheManager(void)
{
    if (N.stops == 2) { P32(F.manager + 12, 0); P32(F.manager + 16, 0); }
}

static void StopThenHandoff(void)
{
    Fix(0, Named("Impaler"));
    Started();
    N.on_stop = EmptiesTheManager;
    CHECK(Apply(0) && Apply(.5) && Apply(1));
    CHECK(Ecs.fling_armed == 1 && N.stops == 0);
    Matrix(Body(1), 1, 0, 0, 0);
    CHECK(Apply(1.2));
    CHECK(N.stops == 1 && Ecs.fling_stops_verified == 1 && N.manager == (uintptr_t)F.manager && N.index == 0);
    CHECK(Apply(1.4) && N.stops == 1);
    P32(F.entity + 20, 1); /* ownership moved here: finish our stop */
    CHECK(Apply(1.6) && N.stops == 2 && Ecs.fling_handoffs == 1);
    CHECK(Apply(1.8) && N.stops == 2);
}

static void MovesTheLimbAgain(void) { Matrix(Body(2), 1.7, 0, 0, 0); }

static void LimbStopNeedsFreshPoses(void)
{
    for (int stale = 0; stale < 2; stale++)
    {
        fake_setup();
        Fix(0, Named("Impaler"));
        Started();
        CHECK(Apply(0) && Apply(.5) && Apply(1));
        Matrix(Body(2), .6, 0, 0, 0);
        CHECK(Apply(1.2) && N.stops == 0);
        if (stale)
        {
            CHECK(ChangedBeforeConsume(1.4, MovesTheLimbAgain));
            CHECK(N.stops == 0 && EcsTableFind(&EcsHistories, UNIT) == NULL);
            continue;
        }
        CHECK(Apply(1.4) && N.stops == 1 && Ecs.fling_limb_stops == 1 && Ecs.fling_stops_verified == 1);
        CHECK(Ecs.last_fling_actor == 0x90000002u && Is(Ecs.last_fling_reason, "limb_translation"));
    }
}

/* ---- every profile's layout (test_snapshot.lua) ----------------------------------------------------------------- */

/* Disables the profile's declared disabled main actors; their bodies become unreadable. The count. */
static uint32_t DisableDeclared(const EcsProfile* p, uint8_t** limb)
{
    uint32_t disabled = 0;
    for (uint32_t i = 1; i <= p->bodies; i++)
    {
        if (!EcsProfileDisabledMain(p, p->main[i - 1])) { if (i > 1 && limb != NULL) *limb = Body(i); continue; }
        P32(Actor(i) + 16, 0);
        fake_hole((uintptr_t)Body(i), 160);
        disabled++;
    }
    return disabled;
}

static void LayoutChecks(int profile, int corpse)
{
    static const uint32_t filters[3] = {0, 48, 83};
    const EcsProfile* p = &EcsProfiles[profile];
    fake_setup();
    Fix(corpse, profile);
    Started();
    for (int f = 0; f < 3; f++)
    {
        for (uint32_t i = 1; i <= p->bodies; i++) P32(Body(i) + 108, filters[f]);
        CHECK_EQ(Inspect(&g_u), 1);
        CHECK(g_u.main_enabled == p->bodies && EcsPlan(&g_u, g_actions) == 1);
    }
    uint32_t disabled = DisableDeclared(p, NULL);
    CHECK_EQ(Inspect(&g_u), 1);
    CHECK(g_u.main_disabled == disabled && g_u.main_static == p->bodies - disabled && EcsPlan(&g_u, g_actions) == 1);
    P32(F.handles, 0xFFFFFFFFu); /* a missing primary cannot pass as a declared disabled one */
    CHECK_EQ(Inspect(&g_u), 1);
    CHECK_EQ(EcsPlan(&g_u, g_actions), 0);
}

static void RuntimeRejects(int profile)
{
    fake_setup();
    Fix(0, profile);
    Started();
    P32(F.runtime + 11160, F.bodies - 1);
    CHECK_EQ(Inspect(&g_u), 0);
    P32(F.runtime + 11160, F.bodies);
    P32(Actor(1) + 24, 0x12345678u);
    CHECK_EQ(Inspect(&g_u), -1);
}

/* The assault walker's four authored landing disables must not block detection on its six static bodies, or expose
 * their old Havok slots. */
static void WalkerLimbStop(int profile)
{
    uint8_t* limb = NULL;
    fake_setup();
    Fix(0, profile);
    Started();
    DisableDeclared(&EcsProfiles[profile], &limb);
    CHECK(Apply(0) && Apply(.5) && Apply(1) && N.stops == 0 && Ecs.fling_armed == 1);
    Matrix(limb, .6, 0, 0, 0);
    CHECK(Apply(1.2) && N.stops == 0);
    CHECK(Apply(1.4) && N.stops == 1 && Ecs.fling_limb_stops == 1 && Ecs.fling_stops_verified == 1);
}

static void ChangesTheEntity(void) { P32(F.entity + 16, 100); }

enum { NORMAL, OWNER, LIVING, FIRST_STOP, GAP, RE_ENABLED, STALE, VARIANTS };

static void TripodVariant(int profile, int variant)
{
    fake_setup();
    Fix(0, profile);
    Started();
    for (uint32_t i = 1; i <= F.bodies; i++)
    {
        P32(Actor(i) + 16, 0);
        if (i > 1 || variant != RE_ENABLED) fake_hole((uintptr_t)Body(i), 160); /* never read disabled storage */
    }
    if (variant == OWNER) P32(F.entity + 20, 1);
    if (variant == LIVING) { P32(F.sync, 0); P32(F.sync + 184, 0); }
    if (variant == FIRST_STOP) F.runtime[11173] = 1;
    CHECK(Apply(0) && Apply(.5) && N.stops == 0);
    if (variant == RE_ENABLED) P32(Actor(1) + 16, 1);
    if (variant == STALE) CHECK(ChangedBeforeConsume(1, ChangesTheEntity));
    else CHECK(Apply(variant == GAP ? 2 : 1));
    CHECK_EQ(N.stops, variant == NORMAL ? 1 : 0);
    if (variant != NORMAL) return;
    CHECK(Ecs.landed_disabled_stops == 1 && Ecs.fling_stops_verified == 1);
    CHECK(Apply(1.999) && N.requests == 0);
    CHECK(Apply(2) && N.requests == 1 && N.entity == 37);
    CHECK(Apply(3) && N.stops == 1 && N.requests == 1);
}

static void EveryProfileLayout(void)
{
    for (int i = 0; i < ECS_PROFILE_COUNT; i++)
    {
        const EcsProfile* p = &EcsProfiles[i];
        LayoutChecks(i, 0);
        LayoutChecks(i, 1);
        RuntimeRejects(i);
        if (p->disabled_count > 0 && !p->finish_disabled) WalkerLimbStop(i);
        for (int variant = 0; p->finish_disabled && variant < VARIANTS; variant++) TripodVariant(i, variant);
    }
}

/* ---- the policy on synthetic units (test_fling.lua, test_settlement.lua, test_completion.lua, test_repair.lua) ----- */

static EcsGuard g_unitGuards[2], g_poseGuards[2];
static uint8_t g_unitBytes[16], g_poseBytes[16];
static uint8_t *g_identity, *g_root, *g_update;

/* main bodies 1 .. n (the root 1 at the origin, the others at limb_x), one identity guard, one root guard. */
static void Synthetic(EcsUnit* u, int profile, double limb_x)
{
    const EcsProfile* p = &EcsProfiles[profile];
    memset(u, 0, offsetof(EcsUnit, main_bodies));
    u->actor_count = 0;
    u->profile = profile;
    u->unit = 99;
    u->id = 77;
    u->settled = u->active = u->update_enabled = 1;
    u->main_enabled = u->main_static = u->main_body_count = p->bodies;
    u->signature = (EcsSignature){1, {15}};
    u->has_root_id = 1;
    u->root_id = 1;
    u->manager = 100;
    u->index = 2;
    for (uint32_t i = 0; i < p->bodies; i++)
    {
        u->main_bodies[i].id = i + 1;
        Rotation(u->main_bodies[i].pose, i == 0 ? 0 : limb_x, 0, 0, 0);
    }
    if (g_identity == NULL) { g_identity = Heap(8); g_root = Heap(8); g_update = Heap(1); }
    memcpy(g_identity, "identity", 8);
    memcpy(g_root, "rootpose", 8);
    *g_update = 1;
    u->update_address = (uintptr_t)g_update;
    EcsGuardsInit(&u->guards, g_unitGuards, 2, g_unitBytes, sizeof g_unitBytes);
    EcsGuardsInit(&u->pose_guards, g_poseGuards, 2, g_poseBytes, sizeof g_poseBytes);
    CHECK(EcsGuardAdd(&u->guards, (uintptr_t)g_identity, "identity", 8) && EcsGuardAdd(&u->pose_guards, (uintptr_t)g_root, "rootpose", 8));
    N.runtimes = 0;
    AddRuntime(100, 2, g_update);
}

static int Fling(double now, EcsStopCall* stop) { return EcsFlingAction(&g_u, now, stop); }

static EcsHistory* Kept(void) { return EcsTableFind(&EcsHistories, g_u.unit); }

static void Arm(void)
{
    EcsStopCall stop;
    CHECK(!Fling(0, &stop) && !Fling(.5, &stop) && !Fling(1, &stop));
    CHECK(Kept() != NULL && Kept()->armed);
}

static void Armed(int profile, double limb_x)
{
    EcsTablesReset();
    Synthetic(&g_u, profile, limb_x);
    Arm();
}

static void Change(int c)
{
    if (c == 0) g_u.owner = 1;
    if (c == 1) g_u.active = 0;
    if (c == 2) g_u.update_enabled = 0;
    if (c == 3) g_u.main_static--;
    if (c == 4) g_u.main_enabled--;
    if (c == 5) g_u.settled = 0;
    if (c == 6) g_u.corpse = 1;
    if (c == 7) g_u.profile = -1;
    if (c == 8) g_u.main_bodies[0].pose[12] = NAN;
    if (c == 9) g_u.id++;
    if (c == 10) g_u.main_bodies[0].id = 43;
    if (c == 11) g_u.signature.ids[0] = 16;
}

static void FlingResets(int profile)
{
    EcsStopCall stop;
    for (int c = 0; c < 12; c++)
    {
        Armed(profile, 0);
        Rotation(g_u.main_bodies[0].pose, 10, 0, 0, 0);
        Change(c);
        CHECK(!Fling(1.2, &stop));
        CHECK(c < 9 ? Kept() == NULL : Kept() == NULL || !Kept()->armed);
    }
    Armed(profile, 0);
    Rotation(g_u.main_bodies[0].pose, 10, 0, 0, 0);
    CHECK(!Fling(2.01, &stop) && !Kept()->armed); /* a gap loses the stationary reference */
    Armed(profile, 0);
    Rotation(g_u.main_bodies[0].pose, 10, 0, 0, 0);
    CHECK(!Fling(.1, &stop)); /* and so does a clock going back */
}

static void FlingPolicy(void)
{
    EcsStopCall stop;
    for (int profile = 0; profile < ECS_PROFILE_COUNT; profile++)
    {
        Armed(profile, 0);
        Rotation(g_u.main_bodies[0].pose, 1, 0, 0, 0);
        CHECK(Fling(1.2, &stop) && stop.cause == ECS_CAUSE_TRANSLATION && stop.distance == 1);
        Armed(profile, 0);
        Rotation(g_u.main_bodies[0].pose, 0, 0, 0, 25);
        CHECK(Fling(1.2, &stop) && stop.cause == ECS_CAUSE_ROTATION && fabs(stop.degrees - 25) < 1e-6);
        EcsTablesReset();
        Synthetic(&g_u, profile, 0);
        for (int i = 0; i <= 10; i++) { Rotation(g_u.main_bodies[0].pose, i, 0, 0, 0); CHECK(!Fling(i * .2, &stop)); }
        CHECK(!Kept()->armed); /* initial death motion and final corrections come first */
        for (int i = 11; i <= 16; i++) CHECK(!Fling(i * .2, &stop));
        CHECK(Kept()->armed);
        Armed(profile, 0);
        Rotation(g_u.main_bodies[0].pose, .2, 0, 0, 3);
        CHECK(!Fling(1.2, &stop)); /* an armed corpse accepts small corrections */
        FlingResets(profile);
    }
}

/* A poll whose snapshot hands over this unit (the Lua's M.snapshot substitutes). */
static int Poll(EcsUnit* u, double now)
{
    Ecs.now = now;
    EcsApplyBegin();
    int consumed = u == NULL || EcsConsume(u);
    EcsApplyEnd(1);
    return consumed;
}

static void LeaveMission(void)
{
    EcsApplyBegin();
    EcsApplyEnd(0);
    CHECK(EcsHistories.count == 0 && EcsStops.count == 0 && Ecs.completion_pending == 0);
}

static void FlingCommandIntegration(void)
{
    for (int variant = 0; variant < 4; variant++) /* normal, stale, owner, unconfirmed */
    {
        fake_setup();
        memset(&N, 0, sizeof N);
        Started();
        Synthetic(&g_u, 0, 0);
        N.keep_update = variant == 3;
        for (int i = 0; i < 3; i++) CHECK(Poll(&g_u, i * .5));
        Rotation(g_u.main_bodies[0].pose, 1, 0, 0, 0);
        if (variant == 1) g_identity[0] = 'X';
        g_u.owner = variant == 2;
        CHECK(Poll(&g_u, 1.2));
        CHECK_EQ(N.stops, variant == 0 || variant == 3 ? 1 : 0);
        CHECK_EQ(Ecs.fling_stops_verified, variant == 0 ? 1 : 0);
        if (variant == 0)
        {
            g_u.update_enabled = *g_update;
            CHECK(Poll(&g_u, 1.4) && N.stops == 1); /* a stopped ragdoll is not stopped again */
            g_u.owner = 1;
            CHECK(Poll(&g_u, 101.6) && N.stops == 2 && Ecs.fling_handoffs == 1 && EcsStops.count == 0);
            CHECK(Poll(&g_u, 101.8) && N.stops == 2);
        }
        LeaveMission();
    }
}

static void LimbConfirmation(int profile, int rotation)
{
    EcsStopCall stop;
    uint32_t last = EcsProfiles[profile].bodies;
    Armed(profile, 10);
    Rotation(g_u.main_bodies[last - 1].pose, rotation ? 10 : 10.6, 0, 0, rotation ? 20 : 0);
    CHECK(!Fling(1.2, &stop) && !Fling(1.25, &stop)); /* one observation, then 50 ms: not yet */
    CHECK(Fling(1.31, &stop) && stop.cause == (rotation ? ECS_CAUSE_LIMB_ROTATION : ECS_CAUSE_LIMB_TRANSLATION));
    CHECK(stop.actor == last && stop.distance == 0 && stop.degrees == 0);
    CHECK(rotation ? stop.limb_degrees > 19.9 : stop.limb_distance > .59);
}

static void LimbSettlement(void)
{
    EcsStopCall stop;
    for (int profile = 0; profile < ECS_PROFILE_COUNT; profile++)
    {
        uint32_t last = EcsProfiles[profile].bodies;
        LimbConfirmation(profile, 0);
        LimbConfirmation(profile, 1);
        Armed(profile, 10);
        double* pose = g_u.main_bodies[last - 1].pose;
        Rotation(pose, 11, 0, 0, 0); CHECK(!Fling(1.2, &stop));
        Rotation(pose, 10, 0, 0, 0); CHECK(!Fling(1.4, &stop));
        Rotation(pose, 11, 0, 0, 0); CHECK(!Fling(1.6, &stop));
        Rotation(pose, 10, 0, 0, 0);
        Rotation(g_u.main_bodies[last - 2].pose, 11, 0, 0, 0);
        CHECK(!Fling(1.8, &stop)); /* another limb cannot inherit the confirmation */
        Armed(profile, 10);
        double angle = 17 * 3.14159265358979323846 / 180;
        Rotation(g_u.main_bodies[0].pose, .2, 0, 0, 17);
        for (uint32_t i = 1; i < last; i++) Rotation(g_u.main_bodies[i].pose, .2 + 10 * cos(angle), 10 * sin(angle), 0, 17);
        CHECK(!Fling(1.2, &stop) && !Fling(1.4, &stop) && !Fling(1.6, &stop)); /* a coherent turn is not flapping */
        Armed(profile, 10);
        Rotation(g_u.main_bodies[last - 1].pose, 12, 0, 0, 0);
        CHECK(!Fling(1.2, &stop));
        g_u.main_static = last - 1;
        CHECK(!Fling(1.4, &stop) && Kept() == NULL);
        Armed(profile, 10);
        g_u.main_body_count--;
        CHECK(!Fling(1.2, &stop) && Kept() == NULL);
    }
}

enum { C_NORMAL, C_STALE, C_ROOT, C_ENTITY, C_LIMB, C_DYNAMIC, C_INACTIVE, C_RESUMED, C_UNSETTLED, C_UNTRACKED, C_OWNER,
    C_ERROR, C_GONE, C_VARIANTS };

static void CompletionChange(int variant)
{
    if (variant == C_STALE) g_identity[0] = 'X';
    if (variant == C_ROOT) g_root[0] = 'X';
    if (variant == C_ENTITY) g_u.id++;
    if (variant == C_LIMB) g_u.signature.ids[0] = 16;
    if (variant == C_DYNAMIC) g_u.main_static--;
    if (variant == C_INACTIVE) g_u.active = 0;
    if (variant == C_RESUMED) { g_u.update_enabled = 1; memset(g_u.main_bodies[0].pose, 0, sizeof g_u.main_bodies[0].pose); }
    if (variant == C_UNSETTLED) g_u.settled = 0;
    if (variant == C_OWNER) g_u.owner = 1;
    if (variant == C_ERROR) P64(G() + 0x346D500, 0); /* the completion service unreadable: the request raises */
}

static void Converted(void)
{
    CHECK_EQ(Ecs.completion_pending, 1);
    g_u.id += 5; /* native conversion replaces the entity and keeps the unit */
    g_u.corpse = 1;
    g_u.update_enabled = -1;
    g_u.signature.count = 0;
    CHECK(Poll(&g_u, 108) && Ecs.completion_corpse_observed == 1 && Ecs.completion_pending == 0);
    CHECK(Poll(&g_u, 109) && Ecs.completion_corpse_observed == 1);
}

static void CompletionVariant(int profile, int variant)
{
    int added;
    fake_setup();
    memset(&N, 0, sizeof N);
    Started();
    Synthetic(&g_u, profile, 0);
    g_u.update_enabled = 0;
    EcsStop* stop = EcsTablePut(&EcsStops, g_u.unit, &added);
    *stop = (EcsStop){77, 0, profile, 0, g_u.signature, 100};
    if (variant == C_UNTRACKED) EcsTableRemove(&EcsStops, g_u.unit);
    CHECK(Poll(&g_u, 100) && Poll(&g_u, 100.5) && Poll(&g_u, 100.999) && N.requests == 0); /* the 1 s grace */
    CompletionChange(variant);
    EcsUnit* unit = variant == C_GONE ? NULL : &g_u; /* disappeared: the snapshot hands over nothing from now on */
    CHECK_EQ(Poll(unit, 101), variant != C_ERROR);
    int expected = variant == C_NORMAL || variant == C_ERROR;
    CHECK(N.requests == (variant == C_NORMAL ? 1u : 0u) && Ecs.completion_requests == (uint32_t)expected);
    CHECK_EQ(Ecs.completion_corpse_observed, 0); /* a request is not a confirmation */
    CHECK(Poll(unit, 105.1) && Poll(unit, 106) && Poll(unit, 107) && Ecs.completion_requests == (uint32_t)expected);
    CHECK_EQ(N.stops, variant == C_OWNER ? 1 : 0); /* the ownership handoff is kept */
    if (variant == C_NORMAL) Converted();
    LeaveMission();
}

static void CompletionPolicy(void)
{
    for (int profile = 0; profile < ECS_PROFILE_COUNT; profile++)
        for (int variant = 0; variant < C_VARIANTS; variant++) CompletionVariant(profile, variant);
}

/* A synthetic settled corpse with every allowlisted actor static gap metres from its node (the Impaler's 0x70F1DB61 is
 * actor 1000), each with readable bytes behind its command guards. */
static void RepairUnit(int profile, double gap, int settled)
{
    const EcsProfile* p = &EcsProfiles[profile];
    Synthetic(&g_u, profile, 0);
    g_u.corpse = 1;
    g_u.settled = settled;
    g_u.main_body_count = 0;
    for (uint32_t i = 0; i < p->actor_count; i++)
    {
        EcsActor* a = &g_u.actors[g_u.actor_count++];
        memset(a, 0, sizeof *a);
        a->id = p->actors[i].name == 0x70F1DB61u ? 1000 : 1001 + i;
        a->name = p->actors[i].name;
        a->node_hash = p->actors[i].node;
        a->enabled = 1;
        Rotation(a->pose, gap, 0, 0, 0);
        Rotation(a->node_pose, 0, 0, 0, 0);
        uint8_t* bytes = Heap(208);
        memcpy(a->identity, &a->id, 4);
        a->identity_address = (uintptr_t)bytes;
        a->data_address = (uintptr_t)bytes + 8;
        a->body_address = (uintptr_t)bytes + 48;
        memcpy(bytes, a->identity, 4);
    }
}

static const EcsAction* ActionFor(uint32_t n, uint32_t id)
{
    for (uint32_t i = 0; i < n; i++)
        if (g_u.actors[g_actions[i].actor].id == id) return &g_actions[i];
    return NULL;
}

static void ImpalerRepair(void)
{
    int impaler = Named("Impaler");
    RepairUnit(impaler, 27, 1);
    uint32_t n = EcsPlan(&g_u, g_actions), claws = 0;
    const EcsAction* leg = ActionFor(n, 1000);
    CHECK(leg != NULL && leg->kind == ECS_REPOSE && leg->gap > 26 && leg->gap < 28 && leg->position[0] == 0);
    for (uint32_t i = 0; i < n; i++) claws += g_actions[i].kind == ECS_DISABLE;
    CHECK_EQ(claws, 3); /* all three revived tentacle claws */
    RepairUnit(impaler, 11.5, 1);
    n = EcsPlan(&g_u, g_actions);
    CHECK(ActionFor(n, 1000) != NULL && ActionFor(n, 1000)->gap > 11 && ActionFor(n, 1000)->gap < 12);
    for (int c = 0; c < 6; c++)
    {
        RepairUnit(impaler, 27, c != 0);
        EcsActor* leg_actor = &g_u.actors[0];
        for (uint32_t i = 0; i < g_u.actor_count; i++) if (g_u.actors[i].id == 1000) leg_actor = &g_u.actors[i];
        if (c == 1) g_u.main_enabled = 14;
        if (c == 2) leg_actor->registered = 1;
        if (c == 3) leg_actor->node_hash = 0;
        if (c == 4) leg_actor->motion = 7;
        if (c == 5) leg_actor->node_pose[12] = NAN;
        CHECK(ActionFor(EcsPlan(&g_u, g_actions), 1000) == NULL);
    }
}

static void RepairPlans(void)
{
    int titan = Named("Bile Titan");
    ImpalerRepair();
    RepairUnit(titan, 0, 0);
    CHECK_EQ(EcsPlan(&g_u, g_actions), 0); /* parked ragdoll bodies are not dead actors */
    RepairUnit(titan, 0, 1);
    CHECK_EQ(EcsPlan(&g_u, g_actions), 0); /* an aligned static collider is not rewritten */
    g_u.actors[3].pose[12] += 27;
    CHECK(EcsPlan(&g_u, g_actions) == 1 && fabs(g_actions[0].gap - 27) < .0001);
    EcsPose pose;
    double m[16] = {0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 4, 0, 5, 6, 7, 1};
    CHECK(EcsRigid(m, &pose) && pose.p[0] == 5 && pose.p[2] == 7 && fabs(pose.q[2] - sqrt(.5)) < 1e-6 && fabs(pose.q[3] - sqrt(.5)) < 1e-6);
    for (int axis = 0; axis < 3; axis++)
    {
        double flip[16] = {-1, 0, 0, 0, 0, -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1};
        flip[axis * 4 + axis] = 1;
        CHECK(EcsRigid(flip, &pose) && fabs(fabs(pose.q[axis]) - 1) < 1e-6);
    }
    double mirrored[16] = {-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    CHECK(!EcsRigid(mirrored, &pose));
}

/* Command submission checks identity again: never a raw write. */
static void RepairCommandsRecheck(void)
{
    for (int stale = 0; stale < 3; stale++) /* nothing, actor 1000's identity, the unit's */
    {
        fake_setup();
        memset(&N, 0, sizeof N);
        Started();
        RepairUnit(Named("Impaler"), 27, 1);
        for (uint32_t i = 0; stale == 1 && i < g_u.actor_count; i++)
            if (g_u.actors[i].id == 1000) *(uint8_t*)g_u.actors[i].identity_address ^= 0xFF;
        if (stale == 2) g_identity[0] = 'X';
        CHECK(Poll(&g_u, 1));
        CHECK(stale == 0 ? Ecs.realignments > 0 : stale == 1 ? Ecs.skipped == 1 : Ecs.realignments == 0);
    }
}

/* ---- the scene (perf_scene.lua): living ragdolls, then dead settled ragdolls and corpses of the Bile Titan ------------ */

#define SCENE_UNITS 64
static struct
{
    uint8_t *mode, *actorRows, *bodyRows, *lists, *slots, *vt;
    uint8_t* managers[2];
    uint32_t perUnit, units, next, living;
    uint32_t unit[SCENE_UNITS], first[SCENE_UNITS];
    uint8_t* entity[SCENE_UNITS];
} S;

static uint8_t* SceneBody(uint32_t k, uint32_t i) { return S.bodyRows + (size_t)(S.first[k] + i - 1) * 160; }

static void SceneActors(int corpse, uint32_t slot, uint8_t* runtime, const EcsProfile* p)
{
    uint32_t unit = 0x400000u + slot;
    uint8_t *object = Heap(0x100), *nodes = Heap(p->nodes * 64u), *handles = Heap(S.perUnit * 4u), *list = S.lists + slot * 24u;
    Ptr(S.slots + slot * 8u, object);
    P32(object + 8, unit);
    P32(object + 0x70, p->nodes);
    Ptr(object + 0x88, nodes);
    for (uint32_t node = 0; node < p->nodes; node++) Matrix(nodes + node * 64u, 0, 0, 0, 0);
    P32(list, unit);
    P32(list + 4, 0x40000000u + S.perUnit);
    Ptr(list + 8, handles);
    for (uint32_t i = 1; i <= S.perUnit; i++)
    {
        uint32_t row = S.next++, id = 0x90000000u + row;
        int main = i <= p->bodies;
        uint32_t name = main ? p->main[i - 1] : p->actors[i - p->bodies - 1].name;
        uint8_t *ar = S.actorRows + row * 40u, *body = S.bodyRows + row * 160u;
        P32(handles + (i - 1) * 4u, id);
        P32(ar, id);
        P32(ar + 12, unit);
        P32(ar + 16, 1);
        P32(ar + 20, row);
        P32(ar + 24, name);
        P32(ar + 28, i - 1);
        P32(ar + 32, main ? name : p->actors[i - p->bodies - 1].node);
        Matrix(body, 0, 0, 0, 0);
        P32(body + 108, main ? (corpse ? 48 : 52) : 20);
        P32(body + 144, id);
        P32(body + 148, unit);
        if (!corpse && main) P32(runtime + (i - 1) * 712u, id);
    }
}

static void SceneManager(int corpse, uint32_t count, uint32_t dead, const EcsProfile* p)
{
    uint8_t *manager = Heap(88), *entities = Heap(count * 8u + 8u);
    uint8_t *runtime = Heap(count * (corpse ? 72u : 11192u) + 8u), *sync = Heap(count * (corpse ? 56u : 432u) + 8u);
    S.managers[corpse] = manager;
    Ptr(G() + (corpse ? 0x3326920 : 0x3326948), manager);
    P32(manager + (corpse ? 16 : 4), count);
    P32(manager + (corpse ? 24 : 12), count);
    P32(manager + (corpse ? 28 : 16), count);
    Ptr(manager + (corpse ? 64 : 56), entities);
    Ptr(manager + 72, runtime);
    Ptr(manager + 80, sync);
    for (uint32_t index = 0; index < count; index++)
    {
        uint32_t slot = corpse ? S.living + dead + index : index;
        uint8_t *entity = Heap(24), *r = runtime + (size_t)index * 11192u;
        P64(entity, p->resource);
        P32(entity + 8, slot + 100);
        P32(entity + 12, 0x400000u + slot);
        Ptr(entities + index * 8u, entity);
        if (!corpse) { P32(r + 11160, p->bodies); r[11172] = 1; }
        if (!corpse && index >= S.living) { P32(sync + index * 432u, p->bodies); P32(sync + index * 432u + 184, p->bodies); }
        if (!corpse && index < S.living) continue;
        S.unit[S.units] = 0x400000u + slot;
        S.first[S.units] = S.next;
        S.entity[S.units++] = entity;
        if (!corpse) AddRuntime((uintptr_t)manager, index, r + 11172);
        SceneActors(corpse, slot, r, p);
    }
}

static void Scene(uint32_t living, uint32_t dead, uint32_t corpses, double per_read)
{
    const EcsProfile* p = &EcsProfiles[Named("Bile Titan")];
    memset(&S, 0, sizeof S);
    memset(&N, 0, sizeof N);
    N.per_read = per_read;
    uint32_t total = living + dead + corpses;
    S.living = living;
    S.perUnit = p->bodies + p->actor_count;
    S.next = 1;
    S.mode = Heap(0x44);
    P32(S.mode + 8, 1);
    P32(S.mode + 0x40, 2);
    Ptr(G() + 0x33266A0, S.mode);
    uint8_t *registry = Heap(0xA8), *generations = Heap(total + 8);
    S.slots = Heap(total * 8u + 8u);
    S.lists = Heap(total * 24u + 8u);
    Ptr(E() + 0x1A100F0, registry);
    Ptr(registry + 0xA0, generations);
    Ptr(registry + 0x88, S.slots);
    P32(registry + 0x98, total);
    memset(generations, 1, total);
    Ptr(E() + 0x27C5B40, S.lists);
    uint32_t maximum = (dead + corpses) * S.perUnit + 1;
    S.actorRows = Heap(maximum * 40u);
    S.bodyRows = Heap(maximum * 160u);
    uint8_t *pool = E() + 0x2369B00 + 64 * 21, *world = Heap(64);
    Ptr(pool, S.actorRows);
    P32(pool + 28, 40);
    P32(pool + 36, maximum);
    P32(pool + 40, 0xFFFFFFFu);
    P32(pool + 52, 0xC0000000u);
    S.vt = Heap(144);
    Ptr(E() + 0x27BA8A8 + 176 * 2, world);
    Ptr(world, S.vt);
    Ptr(S.vt + 136, E() + 0xD0CFA0);
    Ptr(world + 24, S.bodyRows);
    SceneManager(0, living + dead, dead, p);
    SceneManager(1, corpses, dead, p);
}

/* ---- the scene's scenarios (test_performance.lua, test_repose_cooldown.lua, test_metadata_cache.lua) ---------- */

static void LivingCrowdReadCap(void)
{
    Scene(1500, 0, 0, 0);
    Started();
    for (int i = 1; i <= 20; i++)
    {
        uint32_t scanned = Ecs.scan_entities, inspected = Ecs.deep_inspections;
        fake_counts_reset();
        CHECK(Apply(i / 30.0));
        CHECK(Ecs.scan_entities - scanned <= ECS_MAX_ENTITIES && Ecs.deep_inspections == inspected);
        CHECK(fake_counts().read < 300 && Ecs.observed == 0); /* living crowds trigger no deep reads */
    }
    CHECK_EQ(Ecs.budget_yields, 20);
}

/* Every unit's record after a poll: consumed units leave a history (ragdolls) or a backoff record (corpses). */
static void MarkSeen(uint8_t* seen)
{
    for (uint32_t k = 0; k < S.units; k++)
        if (EcsTableFind(&EcsHistories, S.unit[k]) != NULL || EcsTableFind(&EcsChecks, S.unit[k]) != NULL) seen[k] = 1;
}

static void ManagerFairnessAndMissionReset(void)
{
    uint8_t seen[SCENE_UNITS] = {0};
    Scene(300, 24, 24, 0);
    Started();
    for (int i = 1; i <= 240; i++)
    {
        uint32_t before = Ecs.deep_inspections;
        CHECK(Apply(i / 30.0));
        CHECK(Ecs.deep_inspections - before <= ECS_MAX_UNITS);
        MarkSeen(seen);
    }
    for (uint32_t k = 0; k < S.units; k++) CHECK(seen[k]); /* no manager or unit starved */
    P32(S.mode + 8, 0);
    CHECK(Apply(9));
    CHECK(EcsHistories.count == 0 && EcsStops.count == 0 && EcsChecks.count == 0 && Ecs.cursors[0] == 0 && Ecs.cursors[1] == 0);
}

static void DeadlineEndsTheSlice(void)
{
    Scene(500, 2, 2, .0001); /* the clock advances 0.1 ms a read: one inspection passes the 1 ms deadline */
    Started();
    for (int i = 1; i <= 160; i++)
    {
        uint32_t scanned = Ecs.scan_entities, deep = Ecs.deep_inspections;
        CHECK(Apply(i / 30.0));
        CHECK(Ecs.scan_entities - scanned <= ECS_MAX_ENTITIES && Ecs.deep_inspections - deep <= 1);
    }
    CHECK(Ecs.budget_yields > 0);
}

static void MoveUnit(uint32_t k, double x)
{
    for (uint32_t i = 1; i <= S.perUnit; i++) Matrix(SceneBody(k, i), x, 0, 0, 0);
}

/* A large living crowd still permits repeated observations, arming and a verified stop; an expired sampling gap never
 * reuses a stale baseline. */
static void RenewedMotionInACrowd(void)
{
    Scene(1500, 1, 1, .000001);
    Started();
    for (int i = 1; i <= 180; i++) CHECK(Apply(i / 30.0));
    CHECK(EcsTableFind(&EcsHistories, S.unit[0]) != NULL && ((EcsHistory*)EcsTableFind(&EcsHistories, S.unit[0]))->armed);
    MoveUnit(0, 2);
    for (int i = 600; i <= 620; i++) CHECK(Apply(i / 30.0));
    CHECK(Ecs.fling_stops == 0 && Ecs.max_revisit_seconds > 1);
    for (int i = 621; i <= 800; i++) CHECK(Apply(i / 30.0));
    CHECK(EcsTableFind(&EcsHistories, S.unit[0]) != NULL && ((EcsHistory*)EcsTableFind(&EcsHistories, S.unit[0]))->armed);
    MoveUnit(0, 4);
    for (int i = 801; i <= 860; i++) CHECK(Apply(i / 30.0));
    CHECK(Ecs.fling_stops == 1 && Ecs.fling_stops_verified == 1);
}

static void ChangesTheSceneEntity(void) { P32(S.entity[0] + 16, 123); }

static void RevalidationBetweenCommands(void)
{
    Scene(0, 0, 1, 0);
    Started();
    Matrix(SceneBody(0, 16), 2, 0, 0, 0);
    Matrix(SceneBody(0, 17), 3, 0, 0, 0);
    N.on_pose = ChangesTheSceneEntity;
    CHECK(Apply(1));
    CHECK_EQ(N.poses, 1); /* the first command changed the identity: no second */
}

static uint32_t PollReads(int n, double* now)
{
    uint32_t reads = 0;
    for (int i = 0; i < n; i++)
    {
        fake_counts_reset();
        *now += 1 / 30.0;
        CHECK(Apply(*now));
        reads += fake_counts().read;
    }
    return reads;
}

static void ListingKeptAcrossPolls(void)
{
    double now = 0;
    Scene(0, 0, 1, 0);
    Started();
    P64(S.entity[0], 0); /* an unlisted resource */
    CHECK(PollReads(1, &now) == 5 && Ecs.listing_classified == 1 && Ecs.observed == 0);
    uint32_t reads = PollReads(31, &now); /* 4 a poll, plus the rolling verification when corpses are scanned first */
    CHECK(reads >= 31 * 4 + 15 && reads <= 31 * 4 + 16 && Ecs.observed == 0);
    P64(S.entity[0], EcsProfiles[Named("Bile Titan")].resource);
    int found = 0;
    for (int i = 1; i <= 32 && !found; i++) { PollReads(1, &now); found = Ecs.observed == 1; }
    CHECK(found && Ecs.listing_changes == 1); /* a reallocated entity found by the rolling verification */
    P64(S.entity[0], 0);
    PollReads(1, &now);
    CHECK(Ecs.observed == 0 && Ecs.listing_changes == 2); /* a changed header is skipped before inspection */
    PollReads(1, &now);
    CHECK_EQ(Ecs.observed, 0);
    P32(S.mode + 8, 0);
    PollReads(1, &now);
    CHECK(EcsListingOf(1)->size == 0 && EcsListingOf(1)->n == 0); /* mission exit forgets the listing */
}

static void ChangedArrayClassifiesOnlyNew(void)
{
    double now = 0;
    Scene(0, 0, 2, 0);
    Started();
    P32(S.managers[1] + 24, 1);
    P32(S.managers[1] + 28, 1);
    PollReads(1, &now);
    CHECK(Ecs.listing_classified == 1 && Ecs.observed == 1);
    uint32_t inspected = Ecs.deep_inspections;
    P32(S.managers[1] + 24, 2);
    P32(S.managers[1] + 28, 2);
    PollReads(1, &now);
    CHECK(Ecs.corpse_count == 2 && Ecs.listing_classified == 2 && Ecs.deep_inspections - inspected == 2);
    PollReads(1, &now);
    CHECK_EQ(Ecs.listing_classified, 2);
}

static void CorpseRecheckBackoff(void)
{
    static const uint32_t expected[] = {27, 31, 39, 55, 87, 151, 215};
    uint32_t polls[64], count = 0;
    Scene(0, 0, 1, 0);
    Started();
    for (int i = 1; i <= 260; i++)
    {
        uint32_t before = Ecs.deep_inspections;
        CHECK(Apply((Ecs.fling_scan + 1) / 30.0));
        if (Ecs.deep_inspections > before && count < 64) polls[count++] = Ecs.fling_scan;
    }
    CHECK_EQ(count, 25 + 7);
    for (uint32_t i = 0; i < count; i++) CHECK_EQ(polls[i], i < 25 ? i + 1 : expected[i - 25]);
    fake_counts_reset();
    CHECK(Apply(261 / 30.0) && fake_counts().read == 4); /* a waiting corpse is not read at all */
    Matrix(SceneBody(0, 16), 2, 0, 0, 0);
    while (Ecs.realignments == 0 && Ecs.fling_scan < 400) CHECK(Apply((Ecs.fling_scan + 1) / 30.0));
    CHECK_EQ(Ecs.fling_scan, 279); /* realigned at the next re-check */
    uint32_t before = Ecs.deep_inspections;
    for (int i = 0; i < 5; i++) CHECK(Apply((Ecs.fling_scan + 1) / 30.0));
    CHECK_EQ(Ecs.deep_inspections - before, 5); /* a corpse that needed a command is inspected every poll again */
    P32(S.mode + 8, 0);
    CHECK(Apply(20) && EcsChecks.count == 0);
}

typedef struct Budget { const char* label; uint32_t living, dead, corpses, warm, reads, clocks; int setup; } Budget;

static void BudgetSetup(int setup)
{
    if (setup == 1) P64(G() + 0x33266A0, 0);
    if (setup == 2) P32(S.mode + 8, 0);
    if (setup == 3) Matrix(SceneBody(0, 16), 2, 0, 0, 0);
}

/* The calls of one poll after `warm` polls, pinned (the Lua's budget.check limits are in the header comment). */
static void CallsPerPoll(void)
{
    static const Budget budgets[] = {
        {"outside a mission", 0, 0, 0, 0, 0, 0, 1}, {"on the ship", 0, 0, 0, 0, 1, 0, 2}, {"idle in a mission", 0, 0, 0, 0, 3, 0, 0},
        {"eight living enemies, first seen", 8, 0, 0, 0, 13, 0, 0}, {"eight living enemies", 8, 0, 0, 2, 6, 0, 0},
        {"settled corpse", 0, 0, 1, 1, 97, 1, 0}, {"settled remote ragdoll", 0, 1, 0, 1, 117, 1, 0},
        {"living enemies and two settled ragdolls", 8, 2, 0, 1, 234, 2, 0}, {"corpse realignment", 0, 0, 1, 0, 106, 1, 3},
        {"settled corpse waiting for its re-check", 0, 0, 1, 40, 4, 0, 0},
    };
    for (size_t b = 0; b < sizeof budgets / sizeof budgets[0]; b++)
    {
        const Budget* x = &budgets[b];
        fake_setup();
        Scene(x->living, x->dead, x->corpses, 0);
        Started();
        BudgetSetup(x->setup);
        for (uint32_t i = 1; i <= x->warm; i++) CHECK(Apply(i / 30.0));
        fake_counts_reset();
        N.clocks = 0;
        CHECK(Apply(1));
        FakeCounts n = fake_counts();
        if (n.read != x->reads || N.clocks != x->clocks) printf("  %s: %u reads, %u clocks\n", x->label, n.read, N.clocks);
        CHECK(n.read == x->reads && N.clocks == x->clocks && n.write + n.code_matches + n.log + n.other == 0);
    }
}

static int Repose(double now)
{
    uint32_t before = N.poses;
    CHECK(Apply(now));
    return (int)(N.poses - before);
}

/* Small repeated realignments of one actor wait out a cooldown; the first, large repeats and changed identities apply. */
static void RepeatCooldown(void)
{
    Scene(0, 0, 1, 0);
    Started();
    uint8_t* body = SceneBody(0, 16);
    CHECK_EQ(Repose(0), 0);
    Matrix(body, .05, 0, 0, 0);
    CHECK_EQ(Repose(1), 1);
    CHECK(Repose(1.1) == 0 && Repose(1.5) == 0 && Repose(1.9) == 0 && Ecs.reposes_deferred == 3);
    CHECK_EQ(Repose(2), 1); /* the cooldown expires after one second */
    Matrix(body, 2, 0, 0, 0);
    CHECK_EQ(Repose(2.1), 1); /* a large repeat is an obstruction again */
    Matrix(body, .05, 0, 0, 0);
    CHECK_EQ(Repose(2.2), 0);
    Matrix(body, .05, 0, 0, 8);
    CHECK_EQ(Repose(2.3), 1); /* more than five degrees */
    ((EcsRepose*)EcsTableFind(&EcsReposes, N.last_pose))->entity++;
    Matrix(body, .05, 0, 0, 0);
    CHECK_EQ(Repose(2.4), 1); /* another entity's cooldown never holds this one */
    CHECK_EQ(Repose(2.5), 0);
    CHECK_EQ(Repose(1.0), 1); /* a clock going back never holds a command */
    P32(S.mode + 8, 0);
    CHECK(Repose(1.1) == 0 && EcsReposes.count == 0);
    P32(S.mode + 8, 1);
    CHECK_EQ(Repose(1.2), 1);
    Matrix(body, 0, 0, 0, 0);
    CHECK(Repose(3) == 0 && EcsReposes.count == 0); /* expired entries are pruned */
}

static void MetadataInvalidation(void)
{
    Scene(0, 0, 1, 0);
    Started();
    CHECK(Apply(1) && Ecs.observed == 1 && Ecs.realignments == 0);
    Matrix(SceneBody(0, 16), 2, 0, 0, 0);
    CHECK(Apply(1.1) && Ecs.realignments == 1); /* detected at once on the next poll */
    Ptr(S.vt + 136, E() + 0xD11661);
    CHECK(!Apply(1.2) && Ecs.getter_failures == 1 && Ecs.realignments == 1); /* stale world metadata authorises nothing */
    Ptr(S.vt + 136, E() + 0xD0CFA0);
    P32(E() + 0x2369B00 + 64 * 21 + 36, 0);
    CHECK(Apply(1.3) && Ecs.observed == 0 && Ecs.realignments == 1); /* nor a changed actor pool */
}

static void BatchedGuards(void)
{
    uint8_t* block = Heap(256);
    memset(block, 3, 256);
    static EcsGuard items[4];
    static uint8_t bytes[16];
    EcsGuards guards;
    EcsGuardsInit(&guards, items, 4, bytes, sizeof bytes);
    CHECK(EcsGuardAdd(&guards, (uintptr_t)block + 4, "\3\3\3\3", 4) && EcsGuardAdd(&guards, (uintptr_t)block + 20, "\3\3\3\3", 4));
    CHECK(EcsSame(&guards));
    block[22] = 9;
    CHECK(!EcsSame(&guards));
    block[22] = 3;
    items[1].address = (uintptr_t)block + 40;
    CHECK(EcsSame(&guards));
    block[40] = 9;
    CHECK(!EcsSame(&guards));
    block[40] = 3;
    CHECK(EcsGuardAdd(&guards, (uintptr_t)block + 6, "bad!", 4) && !EcsSame(&guards)); /* overlapping guards */
    guards.count = 2;
    fake_hole((uintptr_t)block + 12, 4); /* an unreadable gap inside the group: each guard on its own */
    CHECK(EcsSame(&guards));
}

/* A busy mission (realignments, a verified stop, 3 raised polls that are retried) logs nothing during play. */
static void BusyMissionLogsNothing(void)
{
    Scene(4, 2, 2, 0);
    VpmComponent* self = Started();
    fake_frames(1, DT);
    fake_counts_reset();
    for (int frame = 1; frame <= 1800; frame++)
    {
        if (frame % 120 == 0) Matrix(SceneBody(2, 16), 2 + frame % 7, 0, 0, 0);
        if (frame == 600) MoveUnit(0, 3);
        P32(S.managers[0] + 4, frame >= 900 && frame < 909 ? 0 : 6); /* three polls raise "Manager bounds changed" */
        fake_frames(1, DT);
    }
    CHECK(Ecs.realignments > 0 && Ecs.fling_stops_verified == 1 && Ecs.retries == 3 && Is(vpm_status(self), "ready"));
    /* the component's own lines: none; the core's status line for the raised polls (the return to "ready" 9 frames
     * later is within its 600-frame limit) */
    CHECK_EQ(fake_counts().log, 1);
    CHECK_LOG("[core] Enemy Collision Synchronized status: waiting");
    HfStateEvent end = {{sizeof end, HF_ON_MISSION_END}, HF_STATE_MISSION, HF_STATE_SHIP};
    fake_emit(&end.info);
    CHECK_LOG("v2.13.0 at the mission's end: polls=");
    CHECK_LOG("motion: armed=");
    CHECK_LOG("reader: preflight=verified");
}

int main(void)
{
    RUN(CatalogueAsReviewed);
    RUN(BindsOnceThePhysicsApiIsSet);
    RUN(RefusesWhatIsNotAsReviewed);
    RUN(TheCodeIsCheckedAtLoad);
    RUN(TheCodeDecodedLaterBindsThen);
    RUN(TheCodeNeverDecodedStopsItAfterAMinute);
    RUN(PollsEveryIntervalOfFrameTime);
    RUN(RaisedPollsRetryThenStop);
    RUN(ModeFieldTwoAndMissionExit);
    RUN(DisabledTaggedBodyDoesNotReject);
    RUN(PreflightAndChangedGetter);
    RUN(UnitRecordAndExclusions);
    RUN(RagdollLifecycleExclusions);
    RUN(StopThenHandoff);
    RUN(LimbStopNeedsFreshPoses);
    RUN(EveryProfileLayout);
    RUN(FlingPolicy);
    RUN(FlingCommandIntegration);
    RUN(LimbSettlement);
    RUN(CompletionPolicy);
    RUN(RepairPlans);
    RUN(RepairCommandsRecheck);
    RUN(BatchedGuards);
    RUN(LivingCrowdReadCap);
    RUN(ManagerFairnessAndMissionReset);
    RUN(DeadlineEndsTheSlice);
    RUN(RenewedMotionInACrowd);
    RUN(RevalidationBetweenCommands);
    RUN(ListingKeptAcrossPolls);
    RUN(ChangedArrayClassifiesOnlyNew);
    RUN(CorpseRecheckBackoff);
    RUN(CallsPerPoll);
    RUN(RepeatCooldown);
    RUN(MetadataInvalidation);
    RUN(BusyMissionLogsNothing);
    TEST_END();
}
