/* Sound Systems Rebalanced: the Lua tests' scenarios (components/SoundSystemsRebalanced/tests/test_mod.lua) on the fake
 * game, with the calls pinned per scenario, a frame-by-frame equivalence with the Lua's watcher over 6,000 scripted
 * frames, and HellForge's route to Wwise (the plugin's exports, found at HF_EVENT_ENTITIES_READY, through a stand-in
 * lookup).
 *
 * The Lua's scenarios run on the poll: the fake HellForge accepts the HF_ON_STATE subscription but delivers no state
 * until a test drives HellForge's state source (Loader*, a copy of event_sources.c's state poll), which is the session
 * where HellForge never delivers one. The event's own tests then drive that source through fake_emit: the same sets as
 * the Lua over 6,000 scripted frames, entering 6 then 4, a join in progress, the values the event does not report, the
 * refused subscription and the calls per frame. */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/sound_systems_rebalanced/sound_systems_rebalanced.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_sound_systems_rebalanced};

#define GAME_RVA 0x3326340u
#define STATE_AT 0xAC21Cu
#define OBJECT_SIZE (STATE_AT + 4u)
#define GROUP 0xEC643124u
#define ROOM 0x08EEC31Cu
#define DT 0.0625f                       /* exact in binary: 4 frames make one 0.25 s check period */
#define UNREADABLE 0x7FFF00000000ull     /* a plausible pointer the API cannot read */
#define MISSION_LINE "music held at the war-table level (environment_shiphub_room = shiphub_view)."

/* ---- the game: game.dll's static game object pointer and the game object (its state at +0xAC21C) ----------------- */

typedef struct Game { uint8_t* object; uint8_t* other; int holed; } Game;
static Game g;

static void Point(uint64_t pointer) { memcpy((uint8_t*)fake_game() + GAME_RVA, &pointer, 8); }
static void PointAt(const uint8_t* object) { Point((uint64_t)(uintptr_t)object); }
static void StateOf(uint8_t* object, uint32_t value) { memcpy(object + STATE_AT, &value, 4); }
static void State(uint32_t value) { StateOf(g.object, value); }
static uint32_t Now(void) { uint32_t v; memcpy(&v, g.object + STATE_AT, 4); return v; }

static void MakeGame(uint32_t state)
{
    g.object = fake_heap(OBJECT_SIZE);
    g.other = fake_heap(OBJECT_SIZE);
    g.holed = 0;
    PointAt(g.object);
    State(state);
}

/* The game object unreadable (API reads of it fail), and readable again. */
static void Hole(void) { fake_hole((uintptr_t)g.object, OBJECT_SIZE); g.holed = 1; }
static void Unhole(void) { fake_unhole((uintptr_t)g.object); g.holed = 0; }

/* Whether a read of the game state at `at` works: the two objects' states, the first one while it is not holed. */
static int Readable(uintptr_t at)
{
    if (at == (uintptr_t)g.object + STATE_AT) return !g.holed;
    return at == (uintptr_t)g.other + STATE_AT;
}

/* ---- HellForge's state source (mod-loader/event_sources.c EventSourcesTick, the state part) ------------------------
 * Every game update, before the game-thread callbacks (TickDetour runs EventsTick first): the state through the pointer
 * each time, none (0) when the pointer is 0, the read fails or the value is above 8; HF_ON_STATE {from, to} when a state
 * other than none differs from the last one delivered. */
static struct { uint32_t last; int delivered; } hf;

static void LoaderReset(void) { memset(&hf, 0, sizeof hf); }

static uint32_t LoaderReadState(void)
{
    uint64_t object;
    memcpy(&object, (uint8_t*)fake_game() + GAME_RVA, 8);
    if (object == 0 || !Readable((uintptr_t)object + STATE_AT)) return HF_STATE_NONE;
    uint32_t state;
    memcpy(&state, (const void*)((uintptr_t)object + STATE_AT), 4);
    return state > 8 ? HF_STATE_NONE : state;
}

static void LoaderUpdate(void)
{
    uint32_t state = LoaderReadState();
    if (state == HF_STATE_NONE || state == hf.last) return;
    HfStateEvent e = {{sizeof e, HF_ON_STATE, 0}, hf.last, state};
    hf.last = state;
    hf.delivered++;
    fake_emit(&e.info);
}

/* ---- the game's Wwise plugin, as the lookup finds it ------------------------------------------------------------- */

static struct
{
    int found;           /* what the lookup answers (SSR_WWISE_...) */
    uint8_t initialized; /* IsInitialized's answer */
    int32_t result;      /* SetState's answer */
    int lookups, initChecks, sets;
    uint32_t group, value;
} ww;

static int32_t FakeSetState(uint32_t group, uint32_t value)
{
    ww.sets++;
    ww.group = group;
    ww.value = value;
    return ww.result;
}

static uint8_t FakeIsInitialized(void)
{
    ww.initChecks++;
    return ww.initialized;
}

static int FakeLookup(SsrWwise* out)
{
    ww.lookups++;
    if (ww.found != SSR_WWISE_FOUND) return ww.found;
    out->set_state = FakeSetState;
    out->is_initialized = FakeIsInitialized;
    return SSR_WWISE_FOUND;
}

static void ResetWwise(void)
{
    memset(&ww, 0, sizeof ww);
    ww.found = SSR_WWISE_FOUND;
    ww.initialized = 1;
    ww.result = 1;
    sound_systems_rebalanced_test_wwise(FakeLookup);
}

/* ---- driving it -------------------------------------------------------------------------------------------------- */

static VpmComponent* Self(void) { return fake_component(0); }

/* The pack started with the game state at `state`, up to the entity data's load event (the watch starts there). */
static void Started(uint32_t state)
{
    ResetWwise();
    MakeGame(state);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_fire(HF_EVENT_ENTITIES_READY);
    fake_counts_reset();
}

/* Every call of a frame other than reads and log lines. */
static uint32_t Others(FakeCounts c)
{
    return c.write + c.code_matches + c.find_pattern + c.get_live + c.set_live + c.hook + c.subscribe + c.on + c.other;
}

static FakeCounts Frame(float dt)
{
    fake_counts_reset();
    fake_frames(1, dt);
    FakeCounts c = fake_counts();
    CHECK_EQ(Others(c), 0);
    return c;
}

/* Three frames without a call, then the check frame: its calls. */
static FakeCounts Period(void)
{
    for (int i = 0; i < 3; i++)
    {
        FakeCounts c = Frame(DT);
        CHECK_EQ(c.read + c.log, 0);
    }
    return Frame(DT);
}

static int Status(const char* text) { return strstr(vpm_status(Self()), text) != NULL; }

/* ---- the scenarios ----------------------------------------------------------------------------------------------- */

/* The names hash to the ids it sets (Wwise's FNV-1 of the lower-case name). */
static uint32_t Fnv1(const char* name)
{
    uint32_t h = 2166136261u;
    for (const char* c = name; *c; c++) h = (h * 16777619u) ^ (uint8_t)*c;
    return h;
}

static void TheIdsAreTheLuasNames(void)
{
    CHECK_EQ(Fnv1("environment_shiphub_room"), GROUP);
    CHECK_EQ(Fnv1("shiphub_view"), ROOM);
}

/* The watch starts at HF_EVENT_ENTITIES_READY with the plugin found; frames before it make no call. A reload of the
 * entity data looks for nothing again. */
static void StartsWhenTheEntityDataIsReady(void)
{
    ResetWwise();
    MakeGame(3);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_counts_reset();
    fake_frames(20, DT);
    CHECK_EQ(fake_counts().read + fake_counts().log, 0);
    CHECK_EQ(ww.lookups, 0);
    CHECK(!vpm_ticking(Self()));
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(ww.lookups, 1);
    CHECK(vpm_ticking(Self()));
    CHECK(Status("watching for mission starts"));
    CHECK_LOG("[Sound Systems Rebalanced] watching for mission starts.");
    fake_log_clear();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(ww.lookups, 1);
    CHECK_NO_LOG("watching");
}

/* The first frame reads at once (1 read; the Lua: 2, the pointer and the state); ship frames between checks make no
 * call, check frames one read. */
static void FirstFrameReadsAndShipFramesAreIdle(void)
{
    Started(3);
    CHECK_EQ(Frame(DT).read, 1);
    for (int i = 0; i < 4; i++)
    {
        FakeCounts c = Period();
        CHECK_EQ(c.read, 1);
        CHECK_EQ(c.log, 0);
    }
    CHECK_EQ(ww.sets + ww.initChecks, 0);
    CHECK_NO_LOG("Mission start");
}

/* Entering a mission sets the room once; the mission and the loading before it never repeat it. */
static void EnteringAMissionSetsTheRoomOnce(void)
{
    Started(3);
    Frame(DT);
    State(6);
    FakeCounts c = Period();
    CHECK_EQ(c.read, 1);
    CHECK_EQ(c.log, 1);
    CHECK_EQ(ww.initChecks, 1);
    CHECK_EQ(ww.sets, 1);
    CHECK_EQ(ww.group, GROUP);
    CHECK_EQ(ww.value, ROOM);
    CHECK_LOG("[Sound Systems Rebalanced] Mission start (game state 6): " MISSION_LINE);
    CHECK(Status("held mission music at the war-table level 1 time(s)"));
    State(4);
    for (int i = 0; i < 5; i++)
    {
        c = Period();
        CHECK_EQ(c.read, 1);
        CHECK_EQ(c.log, 0);
    }
    CHECK_EQ(ww.sets, 1);
}

/* A mission already running at the first read is handled; back on the ship, the next mission sets it again. */
static void TheNextMissionSetsItAgain(void)
{
    Started(4);
    CHECK_EQ(Frame(DT).read, 1);
    CHECK_EQ(ww.sets, 1);
    CHECK_LOG("Mission start (game state 4): " MISSION_LINE);
    static const uint32_t ship[] = {5, 3, 3};
    for (int i = 0; i < 3; i++)
    {
        State(ship[i]);
        CHECK_EQ(Period().read, 1);
    }
    CHECK_EQ(ww.sets, 1);
    State(6);
    Period();
    State(4);
    Period();
    CHECK_EQ(ww.sets, 2);
    CHECK(Status("2 time(s)"));
}

/* A value that is not a game state makes the next check find the game object again; one not created yet (or not
 * plausible) is looked for with a plain load, no call. The Lua made 2 reads on each finding check and 1 while the
 * pointer was missing. */
static void StaleOrMissingGameObject(void)
{
    Started(3);
    Frame(DT);
    State(0xFFFFFFFFu);
    CHECK_EQ(Period().read, 1);
    State(3);
    CHECK_EQ(Period().read, 1);
    CHECK_EQ(ww.sets, 0);

    fake_setup();
    Started(6);
    Point(0);
    CHECK_EQ(Frame(DT).read, 0);
    CHECK_EQ(Period().read, 0);
    Point(0x1234);
    CHECK_EQ(Period().read, 0);
    CHECK_EQ(ww.sets, 0);
    PointAt(g.object);
    CHECK_EQ(Period().read, 1);
    CHECK_EQ(ww.sets, 1);
}

/* An unreadable game object: a read on each check, nothing set; readable again, it works. */
static void UnreadableGameObject(void)
{
    Started(3);
    Frame(DT);
    Point(UNREADABLE);
    State(6);
    CHECK_EQ(Period().read, 1); /* the kept address still reads: 6 */
    CHECK_EQ(ww.sets, 1);
    State(3);
    CHECK_EQ(Period().read, 1);
    Hole();
    for (int i = 0; i < 3; i++) CHECK_EQ(Period().read, 1); /* fails, then UNREADABLE fails on every check */
    CHECK_EQ(ww.sets, 1);
}

/* A moved game object: the kept address is read while its value is a game state; once it is not, the moved one is
 * found. */
static void MovedGameObject(void)
{
    Started(3);
    Frame(DT);
    PointAt(g.other);
    StateOf(g.other, 6);
    CHECK_EQ(Period().read, 1);
    CHECK_EQ(ww.sets, 0); /* still the old object's 3 */
    State(0xFFFFFFFFu);
    CHECK_EQ(Period().read, 1);
    CHECK_EQ(Period().read, 1);
    CHECK_EQ(ww.sets, 1);
    CHECK_LOG("Mission start (game state 6)");
}

/* The cadence comes from the frame times: about every 0.25 s at 60 frames per second, never when no time passes, every
 * frame at 2 frames per second. */
static void ChecksEveryQuarterSecondOfGameTime(void)
{
    Started(3);
    Frame(DT);
    fake_counts_reset();
    fake_frames(32, 1.0f / 60);
    CHECK_EQ(fake_counts().read, 2);
    fake_counts_reset();
    fake_frames(100, 0);
    CHECK_EQ(fake_counts().read, 0);
    fake_counts_reset();
    fake_frames(10, 0.5f);
    CHECK_EQ(fake_counts().read, 10);
}

/* A sound engine that is not initialised, or a SetState Wwise refuses, logs it and sets nothing; the next mission tries
 * again. */
static void SoundEngineNotReadyOrRefused(void)
{
    Started(3);
    Frame(DT);
    ww.initialized = 0;
    State(6);
    CHECK_EQ(Period().log, 1);
    CHECK_EQ(ww.sets, 0);
    CHECK_LOG("Mission start (game state 6): the sound engine is not initialised; the music level is unchanged.");
    State(4);
    CHECK_EQ(Period().log, 0);
    ww.initialized = 1;
    ww.result = 2; /* AK_Fail */
    State(3);
    Period();
    State(6);
    Period();
    CHECK_EQ(ww.sets, 1);
    CHECK_LOG("Mission start (game state 6): Wwise refused environment_shiphub_room = shiphub_view (AKRESULT 2).");
    CHECK(Status("watching for mission starts"));
    ww.result = 1;
    State(3);
    Period();
    State(4);
    Period();
    CHECK_EQ(ww.sets, 2);
    CHECK(Status("held mission music at the war-table level 1 time(s)"));
}

/* Without the plugin or its exports it stays off and never ticks, as the Lua without the engine's binding. The real
 * lookup runs here: the test process has no wwise_pluginw64_release.dll. */
static void StaysOffWithoutThePlugin(void)
{
    ResetWwise();
    sound_systems_rebalanced_test_wwise(NULL);
    MakeGame(6);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(!vpm_running(Self()));
    CHECK(Status("disabled: the game's Wwise plugin (wwise_pluginw64_release.dll) is not loaded"));
    fake_counts_reset();
    fake_frames(20, DT);
    CHECK_EQ(fake_counts().read, 0);
    /* Stopped, its state listener is not called: HellForge's state changes set nothing. */
    LoaderReset();
    LoaderUpdate();
    State(3);
    LoaderUpdate();
    State(4);
    LoaderUpdate();
    CHECK(hf.delivered == 3 && ww.sets + ww.initChecks == 0);

    fake_setup();
    ResetWwise();
    ww.found = SSR_WWISE_NO_EXPORT;
    MakeGame(6);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(Status("disabled: the game's Wwise plugin exports no AK::SoundEngine::SetState"));
    fake_frames(20, DT);
    CHECK_EQ(ww.sets, 0);
}

/* Another game build: the core keeps it off; it looks for nothing and reads nothing. */
static void OffOnAnotherBuild(void)
{
    ResetWwise();
    MakeGame(6);
    fake_set_build("25000000");
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_ENTITIES_READY);
    fake_counts_reset();
    fake_frames(20, DT);
    CHECK(Status("off: needs game build"));
    CHECK_EQ(ww.lookups + ww.sets, 0);
    CHECK_EQ(fake_counts().read, 0);
}

/* ---- equivalence with the Lua's watcher -------------------------------------------------------------------------- *
 * The Lua's step (sound_systems_rebalanced.lua Mod.new) restated over the same memory, counting the reads the C makes
 * (the state read; the pointer is a plain load here). Both run the Lua test's 6,000-frame script: ship, loading,
 * mission and back, stale states, a missing, moved and unreadable game object, frame times of every kind. */

/* observed: a check has read the game state (a value up to 64) since the script last changed it; seen: this frame's
 * check read it. */
typedef struct Lua { uintptr_t stateAt; double elapsed; int inMission, sets, observed, seen; } Lua;

/* One frame of the Lua's step: its reads (as the C counts them). */
static int LuaStep(Lua* m, double dt)
{
    m->seen = 0;
    m->elapsed += dt;
    if (m->elapsed < 0.25) return 0;
    m->elapsed = 0;
    if (m->stateAt == 0)
    {
        uint64_t object;
        memcpy(&object, (uint8_t*)fake_game() + GAME_RVA, 8);
        if (object < 0x10000 || object >= 0x800000000000ull) return 0;
        m->stateAt = (uintptr_t)object + STATE_AT;
    }
    if (!Readable(m->stateAt)) { m->stateAt = 0; return 1; }
    uint32_t value;
    memcpy(&value, (const void*)m->stateAt, 4);
    if (value > 64) { m->stateAt = 0; return 1; }
    int mission = value == 6 || value == 4;
    if (mission && !m->inMission) m->sets++;
    m->inMission = mission;
    m->observed = m->seen = 1;
    return 1;
}

static uint32_t g_seed;
static uint32_t Roll(uint32_t n)
{
    g_seed = (uint32_t)(((uint64_t)g_seed * 1103515245u + 12345u) % 2147483648u);
    return g_seed % n;
}

/* One step of the script: the game changes as the Lua test's does (r 10, the Lua guard's pause, has no C counterpart). */
static void Script(const uint32_t* states, uint32_t stateCount)
{
    uint32_t r = Roll(100);
    if (r < 6) State(states[Roll(stateCount)]);
    else if (r == 6) Point(0);
    else if (r == 7) Point(UNREADABLE);
    else if (r == 8) { PointAt(g.other); StateOf(g.other, states[Roll(stateCount)]); }
    else if (r == 9) PointAt(g.object);
}

static void EveryFrameMatchesTheLua(void)
{
    Started(3);
    static const uint32_t states[] = {3, 3, 3, 5, 6, 4, 4, 2, 1, 0xFFFFFFFFu, 65, 64, 6, 4};
    /* the Lua's frame times; its "no dt" (1/60 fallback) and "0.1" (a string) are numbers here */
    static const float dts[] = {DT, DT, 1.0f / 60, 1.0f / 30, 0.5f, 1.0f / 60, 0.1f, 0};
    Lua lua = {0, 0.25, 0, 0, 0, 0};
    g_seed = 12345;
    int mismatches = 0;
    for (int i = 0; i < 6000; i++)
    {
        Script(states, sizeof states / sizeof states[0]);
        float dt = dts[Roll(sizeof dts / sizeof dts[0])];
        int setsBefore = lua.sets;
        int reads = LuaStep(&lua, dt);
        fake_counts_reset();
        int linesBefore = fake_log_count("[Sound Systems Rebalanced]");
        fake_frames(1, dt);
        FakeCounts c = fake_counts();
        /* the component's own lines: the core may log once in a frame too (its frame hook given up after 60 s) */
        int lines = fake_log_count("[Sound Systems Rebalanced]") - linesBefore;
        if ((int)c.read == reads && ww.sets == lua.sets && lines == lua.sets - setsBefore && Others(c) == 0) continue;
        if (mismatches++ == 0)
            printf("  frame %d: reads %u (Lua %d), sets %d (Lua %d), log lines %d (Lua %d)\n", i, c.read, reads, ww.sets, lua.sets,
                lines, lua.sets - setsBefore);
    }
    CHECK_EQ(mismatches, 0);
    CHECK(lua.sets >= 20);
    CHECK_EQ(ww.sets, lua.sets);
    CHECK_EQ(ww.initChecks, lua.sets);
}

/* ---- HellForge's HF_ON_STATE --------------------------------------------------------------------------------------- */

#define TAKES_OVER "[Sound Systems Rebalanced] HellForge's state event reports the game state from now on; the 0.25 s poll stopped."

/* One frame with HellForge's state source: its update, then the pack's tick, every call counted. */
static FakeCounts EventFrame(float dt)
{
    fake_counts_reset();
    LoaderUpdate();
    fake_frames(1, dt);
    FakeCounts c = fake_counts();
    CHECK_EQ(Others(c), 0);
    return c;
}

/* n frames with nothing to report: no call, no read, no log line of the component's (the core logs once when its frame
 * hook is given up after 60 s). */
static void QuietFrames(int n, float dt)
{
    for (int i = 0; i < n; i++)
    {
        int lines = fake_log_count("[Sound Systems Rebalanced]");
        FakeCounts c = EventFrame(dt);
        CHECK_EQ(c.read, 0);
        CHECK_EQ(fake_log_count("[Sound Systems Rebalanced]"), lines);
    }
}

/* The pack started with the game at `state` and HellForge's state source running; `early`: it delivered the state
 * before the watch started (in game it runs from the title screen on, before the entity data is ready). */
static void EventStarted(uint32_t state, int early)
{
    Started(state);
    LoaderReset();
    if (early) LoaderUpdate();
    fake_counts_reset();
}

/* The watch's first frame reads the state itself (the Lua's first read), and with the event delivered the poll stops
 * there: from then on no frame makes a call or a read, and the component no longer ticks. */
static void TheEventTakesOverAfterTheFirstRead(void)
{
    EventStarted(3, 1);
    CHECK_EQ(hf.delivered, 1);
    FakeCounts c = EventFrame(DT);
    CHECK(c.read == 1 && c.log == 1);
    CHECK_LOG(TAKES_OVER);
    CHECK(!vpm_ticking(Self()) && vpm_running(Self()) && Status("watching for mission starts"));
    QuietFrames(400, DT);
    QuietFrames(100, 0.5f);
    CHECK_EQ(ww.sets + ww.initChecks, 0);
    /* HellForge's source first delivering after the watch's first read: the poll goes on until then. */
    fake_setup();
    EventStarted(3, 0);
    State(65);
    CHECK_EQ(Frame(DT).read, 1);          /* not a game state: read again 0.25 s later */
    CHECK_EQ(Period().read, 1);
    CHECK(vpm_ticking(Self()));
    State(3);
    CHECK_EQ(Period().read, 1);           /* read, but HellForge has not delivered a state yet */
    CHECK(vpm_ticking(Self()) && hf.delivered == 0);
    c = EventFrame(DT);                   /* HellForge delivers 3: the poll stops on that frame */
    CHECK(c.read == 0 && c.log == 1 && hf.delivered == 1 && !vpm_ticking(Self()));
    QuietFrames(100, DT);
}

/* Entering 6 then 4: the room is set once, on the frame HellForge reports 6, with no read. Back on the ship, the next
 * mission sets it again, as does a mission entered straight from the ship (3 then 4). */
static void EnteringSixThenFourWithTheEvent(void)
{
    EventStarted(3, 1);
    EventFrame(DT);
    State(6);
    FakeCounts c = EventFrame(DT);
    CHECK(c.read == 0 && c.log == 1 && ww.initChecks == 1 && ww.sets == 1);
    CHECK(ww.group == GROUP && ww.value == ROOM);
    CHECK_LOG("[Sound Systems Rebalanced] Mission start (game state 6): " MISSION_LINE);
    CHECK(Status("held mission music at the war-table level 1 time(s)"));
    QuietFrames(10, DT);
    State(4);
    c = EventFrame(DT);
    CHECK(c.read + c.log == 0 && ww.sets == 1 && hf.delivered == 3);
    QuietFrames(10, DT);
    static const uint32_t back[] = {5, 3};
    for (int i = 0; i < 2; i++)
    {
        State(back[i]);
        c = EventFrame(DT);
        CHECK(c.read + c.log == 0);
    }
    State(6);
    EventFrame(DT);
    State(4);
    EventFrame(DT);
    CHECK_EQ(ww.sets, 2);
    State(3);
    EventFrame(DT);
    State(4);
    c = EventFrame(DT);
    CHECK(c.read == 0 && c.log == 1 && ww.sets == 3);
    CHECK_LOG("Mission start (game state 4): " MISSION_LINE);
    CHECK(Status("3 time(s)"));
}

/* A join in progress: the game is in its mission (4) when the watch starts. The first read sets the room once, whether
 * HellForge delivered 4 before the watch or delivers it on the first frame; a game object not readable then is read
 * again 0.25 s later, and HellForge's 4 sets it the moment it comes. */
static void AJoinInProgress(void)
{
    EventStarted(4, 1);
    FakeCounts c = EventFrame(DT);
    CHECK(c.read == 1 && ww.sets == 1 && !vpm_ticking(Self()));
    CHECK_LOG("Mission start (game state 4): " MISSION_LINE);
    QuietFrames(100, DT);
    CHECK_EQ(ww.sets, 1);

    fake_setup();
    EventStarted(4, 0);
    c = EventFrame(DT);
    CHECK(c.read == 1 && ww.sets == 1 && hf.delivered == 1 && !vpm_ticking(Self()));
    QuietFrames(100, DT);
    CHECK_EQ(ww.sets, 1);

    fake_setup();
    EventStarted(4, 0);
    Point(0);                             /* no game object yet at the watch's start */
    c = EventFrame(DT);
    CHECK(c.read == 0 && ww.sets == 0 && vpm_ticking(Self()));
    CHECK_EQ(Period().read, 0);
    PointAt(g.object);
    c = EventFrame(DT);                   /* HellForge reads 4 first: set from its event, the poll stops */
    CHECK(c.read == 0 && ww.sets == 1 && !vpm_ticking(Self()));
    QuietFrames(100, DT);
    CHECK_EQ(ww.sets, 1);
}

/* What the event does not report. A value above 64, an unreadable or missing game object: no event, and the Lua left
 * its mission flag as it was, so back at 4 neither sets the room again. 7 and 8 (the test level, the debug mission) are
 * reported and clear the flag, as in the Lua. 0 and 9 to 64 cleared the Lua's flag but are not reported: back at 4 the
 * event sets nothing where the Lua's poll set the room again (the poll still does when it is the route). game.dll never
 * stores those values once the game is set up (the header says where), so the case does not arise on 25480438. */
static void StatesTheEventDoesNotReport(void)
{
    EventStarted(4, 1);
    EventFrame(DT);
    CHECK_EQ(ww.sets, 1);
    static const uint32_t silent[] = {65, 0xFFFFFFFFu, 0, 9, 30, 64};
    for (int i = 0; i < 6; i++)
    {
        State(silent[i]);
        QuietFrames(8, DT);
        State(4);
        QuietFrames(8, DT);
    }
    Hole();
    QuietFrames(8, DT);
    Unhole();
    Point(0);
    QuietFrames(8, DT);
    Point(UNREADABLE);
    QuietFrames(8, DT);
    PointAt(g.object);
    QuietFrames(8, DT);
    CHECK(ww.sets == 1 && hf.delivered == 1);
    for (uint32_t state = 7; state <= 8; state++)
    {
        State(state);
        EventFrame(DT);
        State(4);
        EventFrame(DT);
    }
    CHECK(ww.sets == 3 && hf.delivered == 5);
    /* The poll (no event): 0 and 9 to 64 clear the flag as in the Lua; above 64 and unreadable leave it. */
    fake_setup();
    Started(4);
    Frame(DT);
    CHECK_EQ(ww.sets, 1);
    static const uint32_t cleared[] = {0, 9, 30, 64};
    for (int i = 0; i < 4; i++)
    {
        State(cleared[i]);
        Period();
        State(4);
        Period();
    }
    CHECK_EQ(ww.sets, 5);
    State(65);
    Period();
    State(4);
    Period();
    CHECK_EQ(ww.sets, 5);
}

/* Strictly better than the Lua's checks: a ship state shorter than a check, which the Lua's poll never saw (it kept the
 * room as set), and a moved game object, which HellForge reads at once where the Lua kept the old one while it held a
 * value up to 64. */
static void ChangesTheLuasChecksMissed(void)
{
    EventStarted(4, 1);
    Lua lua = {0, 0.25, 0, 0, 0, 0};
    CHECK_EQ(LuaStep(&lua, DT), 1);
    EventFrame(DT);
    CHECK(ww.sets == 1 && lua.sets == 1);
    State(3);                             /* frames 1 and 2 of the Lua's 4-frame check period */
    for (int i = 0; i < 2; i++) { CHECK_EQ(LuaStep(&lua, DT), 0); EventFrame(DT); }
    State(4);
    for (int i = 0; i < 2; i++) { (void)LuaStep(&lua, DT); EventFrame(DT); }
    CHECK(lua.sets == 1 && ww.sets == 2);
    PointAt(g.other);                     /* the game object moved; the old one still holds 4 */
    StateOf(g.other, 3);
    for (int i = 0; i < 4; i++) { (void)LuaStep(&lua, DT); EventFrame(DT); }
    StateOf(g.other, 6);
    for (int i = 0; i < 4; i++) { (void)LuaStep(&lua, DT); EventFrame(DT); }
    CHECK(lua.sets == 1 && ww.sets == 3);
    CHECK_LOG("Mission start (game state 6): " MISSION_LINE);
}

/* The fallback: HellForge refuses the subscription (here its listener table is full). The log says so, and the Lua's
 * poll runs for the whole session at its cadence, with its reads; HellForge's events reach nothing. */
static void FillerListener(HfMod* mod, const HfEventInfo* event, void* user) {}
static int FillerStart(VpmComponent* self)
{
    for (int i = 0; i < 1024 && vpm_hf()->subscribe(vpm_mod(), HF_ON_KILL, FillerListener, NULL, 0); i++) continue;
    return 0;
}
static const VpmComponentDef kFiller = {"filler", "Filler", "1.0", 0, FillerStart, NULL};
static const VpmComponentDef* const kRefusedDefs[] = {&kFiller, &vpm_component_sound_systems_rebalanced};

static void ThePollWhenTheEventIsRefused(void)
{
    ResetWwise();
    MakeGame(3);
    fake_start(kRefusedDefs, 2);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_fire(HF_EVENT_ENTITIES_READY);
    VpmComponent* self = fake_component(1);
    CHECK(vpm_running(self) && vpm_ticking(self));
    CHECK_LOG("[Sound Systems Rebalanced] HellForge's state event is unavailable: the game state is polled every 0.25 s, as the Lua did.");
    LoaderReset();
    fake_counts_reset();
    for (int i = 0; i < 400; i++)
    {
        if (i == 100) State(6);
        if (i == 200) State(3);
        if (i == 300) State(4);
        LoaderUpdate();
        fake_frames(1, DT);
    }
    CHECK(hf.delivered == 4 && vpm_ticking(self));
    CHECK_EQ(fake_counts().read, 100);    /* one read per 0.25 s, as the Lua */
    CHECK_EQ(ww.sets, 2);
    CHECK_NO_LOG("poll stopped");
}

/* ---- the event against the Lua's poll ------------------------------------------------------------------------------ *
 * The same 6,000-frame script on the values game.dll stores (1 to 8) and the ones both ignore (above 64, an unreadable
 * game object), each state held until the Lua's check has read it (so its 0.25 s sampling misses none: the changes it
 * would miss are ChangesTheLuasChecksMissed's). The Lua's watcher polls; the C gets HellForge's events. The C sets the
 * room on the same changes, never after the Lua (at most one set ahead, between a change and the Lua's next check),
 * equal at every check of the Lua that read a state; its only read is the first. */

static void EventScript(Lua* lua, const uint32_t* states, uint32_t stateCount)
{
    uint32_t r = Roll(100);
    int free = lua->observed || Now() > 64;
    if (r < 6 && (free || g.holed)) { State(states[Roll(stateCount)]); lua->observed = 0; }
    else if (r == 6 && free && !g.holed) Hole();
    else if (r >= 7 && r < 12 && g.holed) Unhole();
}

static void EventsMakeTheLuasSets(void)
{
    EventStarted(3, 1);
    static const uint32_t states[] = {3, 3, 3, 5, 6, 4, 4, 2, 1, 7, 8, 65, 0xFFFFFFFFu, 6, 4};
    static const float dts[] = {DT, DT, 1.0f / 60, 1.0f / 30, 0.5f, 1.0f / 60, 0.1f, 0};
    Lua lua = {0, 0.25, 0, 0, 0, 0};
    g_seed = 54321;
    int mismatches = 0, reads = 0, ahead = 0;
    for (int i = 0; i < 6000; i++)
    {
        EventScript(&lua, states, sizeof states / sizeof states[0]);
        float dt = dts[Roll(sizeof dts / sizeof dts[0])];
        (void)LuaStep(&lua, dt);
        int checked = lua.seen;
        FakeCounts c = EventFrame(dt);
        reads += (int)c.read;
        ahead += ww.sets > lua.sets;
        int ok = ww.sets >= lua.sets && ww.sets <= lua.sets + 1 && (!checked || ww.sets == lua.sets);
        if (ok && (i == 0 || c.read == 0)) continue;
        if (mismatches++ == 0)
            printf("  frame %d: sets %d (Lua %d), reads %u, Lua checked %d\n", i, ww.sets, lua.sets, c.read, checked);
    }
    for (int i = 0; i < 40 && lua.sets != ww.sets; i++) { (void)LuaStep(&lua, DT); EventFrame(DT); }
    CHECK_EQ(mismatches, 0);
    CHECK(lua.sets >= 20 && ahead > 0);
    CHECK_EQ(ww.sets, lua.sets);
    CHECK_EQ(ww.initChecks, ww.sets);
    CHECK_EQ(reads, 1);
    CHECK_EQ(fake_log_count("Mission start"), ww.sets);
    CHECK(!vpm_ticking(Self()));
}

int main(void)
{
    RUN(TheIdsAreTheLuasNames);
    RUN(StartsWhenTheEntityDataIsReady);
    RUN(FirstFrameReadsAndShipFramesAreIdle);
    RUN(EnteringAMissionSetsTheRoomOnce);
    RUN(TheNextMissionSetsItAgain);
    RUN(StaleOrMissingGameObject);
    RUN(UnreadableGameObject);
    RUN(MovedGameObject);
    RUN(ChecksEveryQuarterSecondOfGameTime);
    RUN(SoundEngineNotReadyOrRefused);
    RUN(StaysOffWithoutThePlugin);
    RUN(OffOnAnotherBuild);
    RUN(EveryFrameMatchesTheLua);
    RUN(TheEventTakesOverAfterTheFirstRead);
    RUN(EnteringSixThenFourWithTheEvent);
    RUN(AJoinInProgress);
    RUN(StatesTheEventDoesNotReport);
    RUN(ChangesTheLuasChecksMissed);
    RUN(ThePollWhenTheEventIsRefused);
    RUN(EventsMakeTheLuasSets);
    TEST_END();
}
