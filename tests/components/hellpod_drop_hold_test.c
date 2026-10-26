/* Hellpod Drop Hold: the Lua tests' scenarios (components/HellpodDropHold/tests/test_hold.lua) on the fake game, with
 * the Lua's exact calls per frame translated (the game.dll globals are plain loads here), plus HellForge's copy of the
 * HellpodComponent settings table. */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/hellpod_drop_hold/hellpod_drop_hold.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_hellpod_drop_hold};

#define GAME_RVA 0x3326340u
#define STATE_AT 0xAC21Cu
#define UI_RVA 0x347CE28u
#define PRESENTERS_AT 0x4290u
#define STACK_AT 0x429Cu
#define CUTSCENE_RVA 0x346D530u
#define SCENE_AT 6412u
#define SESSION_RVA 0x347CEF0u
#define CLIENT_STATE_AT 91288u
#define HOTJOIN_AT 92135u
#define MANAGER_RVA 0x3326D58u
#define SETTINGS_RVA 0x346BF98u
#define SETTINGS_TABLE_AT 15805152u
#define CAPACITY 32u
#define LOCALS_SIZE (160u * CAPACITY)
#define MULTIPLIER 2654435761u
#define EMPTY 0xFFFFFFFFu
#define DT (1.0f / 60)

typedef struct Kind { uint32_t low, high; } Kind;
static const Kind kInitial = {0x1928D3E2u, 0xE58163E7u};
static const Kind kReinforce = {0xA9D6D849u, 0xEF9EB729u};
static const Kind kPayload = {0x4E7C9A50u, 0xFBE75EC4u};

static const double T_HOLD = (0.5 - 100) / (400 - 100);

/* The world: the game.dll globals in the fake image, everything they point at in the fake heap. */
typedef struct World
{
    uint8_t *object, *scenes, *session, *ui, *manager, *records, *locals, *nets, *owner, *table, *map;
    uint32_t next_id;
} World;
static World w;

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void PutF(uint8_t* at, float v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static float GetF(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }
static uint64_t Get64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static void SetGlobal(uint32_t rva, const void* value) { Put64((uint8_t*)fake_game() + rva, (uint64_t)(uintptr_t)value); }
static int Close(double a, double b) { return a - b < 1e-6 && b - a < 1e-6; }

/* Whole pages of the fake heap that nothing else shares (the read-only tests protect them). */
static uint8_t* Pages(size_t size)
{
    size_t rounded = (size + 4095u) & ~(size_t)4095u;
    uintptr_t at = (uintptr_t)fake_heap(rounded + 4096u);
    return (uint8_t*)((at + 4095u) & ~(uintptr_t)4095u);
}

static void Setting(uint8_t* table, uint32_t slot, const Kind* kind, uint32_t index, uint32_t variant, float initial, float braking)
{
    Put32(table + slot * 16, kind->low);
    Put32(table + slot * 16 + 4, kind->high);
    Put32(table + slot * 16 + 8, index);
    uint8_t* record = table + 256 + index * 104;
    Put32(record, variant);
    PutF(record + 8, 1000);
    PutF(record + 20, initial);
    PutF(record + 24, 500);
    PutF(record + 28, braking);
    PutF(record + 32, 1);
}

/* The Lua's new_world: in a mission (state 4), an empty manager of capacity 128 with a 64-slot id map, and the settings:
 * payload in slot 0 (record 0), initial spawn in slot 2 (record 3), reinforce in slot 9 (record 5). */
static void NewWorld(void)
{
    memset(&w, 0, sizeof w);
    w.next_id = 100;
    w.object = fake_heap(STATE_AT + 4);
    w.scenes = fake_heap(SCENE_AT + 8);
    w.session = fake_heap(HOTJOIN_AT + 2);
    w.ui = fake_heap(STACK_AT + 32);
    w.manager = fake_heap(128);
    w.records = fake_heap(8 * CAPACITY);
    w.locals = Pages(LOCALS_SIZE);
    w.nets = fake_heap(20 * CAPACITY);
    w.owner = fake_heap(SETTINGS_TABLE_AT + 8);
    w.table = fake_heap(256 + 104 * 8);
    w.map = fake_heap(8 * 64);
    SetGlobal(GAME_RVA, w.object);
    SetGlobal(CUTSCENE_RVA, w.scenes);
    SetGlobal(SESSION_RVA, w.session);
    SetGlobal(UI_RVA, w.ui);
    SetGlobal(MANAGER_RVA, w.manager);
    SetGlobal(SETTINGS_RVA, w.owner);
    Put64(w.owner + SETTINGS_TABLE_AT, (uint64_t)(uintptr_t)w.table);
    Put32(w.object + STATE_AT, 4);
    Put32(w.manager + 36, 128);
    Put64(w.manager + 64, (uint64_t)(uintptr_t)w.map);
    Put32(w.manager + 72, 64);
    Put32(w.manager + 76, EMPTY);
    Put32(w.manager + 80, MULTIPLIER);
    for (uint32_t slot = 0; slot < 64; slot++) Put32(w.map + slot * 8, EMPTY);
    Put64(w.manager + 88, (uint64_t)(uintptr_t)w.records);
    Put64(w.manager + 104, (uint64_t)(uintptr_t)w.locals);
    Put64(w.manager + 112, (uint64_t)(uintptr_t)w.nets);
    Setting(w.table, 0, &kPayload, 0, 0, 400, 100);
    Setting(w.table, 2, &kInitial, 3, 2, 400, 100);
    Setting(w.table, 9, &kReinforce, 5, 1, 350, 100);
}

/* The menu stack (the current menu presenter is its top) and the HUD presenter. */
static void Screens(uint32_t n, const uint32_t* ids, uint32_t hud)
{
    for (uint32_t i = 0; i < 5; i++) Put32(w.ui + STACK_AT + i * 4, i < n ? ids[i] : 0);
    Put32(w.ui + STACK_AT + 20, n);
    Put32(w.ui + PRESENTERS_AT + 4, n > 0 ? ids[n - 1] : 0);
    Put32(w.ui + PRESENTERS_AT, hud);
}
static void Screen(uint32_t id) { Screens(1, &id, 0); }
static void NoScreen(void) { Screens(0, NULL, 0); }
static void GameState(uint32_t state) { Put32(w.object + STATE_AT, state); }
static void Cutscene(uint32_t current, uint32_t queued) { Put32(w.scenes + SCENE_AT, current); Put32(w.scenes + SCENE_AT + 4, queued); }
static void JoinFlags(uint8_t hotjoining, uint8_t hotjoined, uint32_t client)
{
    w.session[HOTJOIN_AT] = hotjoining;
    w.session[HOTJOIN_AT + 1] = hotjoined;
    Put32(w.session + CLIENT_STATE_AT, client);
}

static uint32_t Active(void) { return Get32(w.manager + 48); }

/* The id map rebuilt from the active records the way the game probes it: slot (id * multiplier + probe) & 63. */
static void RebuildMap(uint32_t count)
{
    for (uint32_t slot = 0; slot < 64; slot++) Put32(w.map + slot * 8, EMPTY);
    for (uint32_t index = 0; index < count; index++)
    {
        const uint8_t* record = (const uint8_t*)(uintptr_t)Get64(w.records + index * 8);
        uint32_t id = Get32(record + 8), start = id * MULTIPLIER;
        for (uint32_t probe = 0; probe < 64; probe++)
        {
            uint32_t slot = (start + probe) % 64;
            if (Get32(w.map + slot * 8) != EMPTY) continue;
            Put32(w.map + slot * 8, id);
            Put32(w.map + slot * 8 + 4, index);
            break;
        }
    }
}

static void SetActive(uint32_t n)
{
    Put32(w.manager + 44, n);
    Put32(w.manager + 48, n);
    RebuildMap(n);
}

/* A pod at the end of the active range: its index (its entity id is w.next_id). */
static uint32_t AddPod(const Kind* kind, int owned, float t, uint32_t phase)
{
    uint32_t index = Active();
    uint8_t* record = fake_heap(24);
    w.next_id++;
    Put32(record, kind->low);
    Put32(record + 4, kind->high);
    Put32(record + 8, w.next_id);
    Put32(record + 12, 7);
    Put32(record + 16, 0x7FFF);
    Put32(record + 20, owned ? 1 : 0);
    Put64(w.records + index * 8, (uint64_t)(uintptr_t)record);
    memset(w.locals + index * 160, 0, 160);
    PutF(w.locals + index * 160 + 32, t);
    Put32(w.nets + index * 20, phase);
    PutF(w.nets + index * 20 + 12, 1500);
    SetActive(index + 1);
    return index;
}
static uint32_t OwnPod(void) { return AddPod(&kInitial, 1, 1, 0); }

/* The pod at index removed the way the game does: the last pod moves into its place. */
static void RemovePod(uint32_t index)
{
    uint32_t last = Active() - 1;
    if (index != last)
    {
        memcpy(w.records + index * 8, w.records + last * 8, 8);
        memcpy(w.locals + index * 160, w.locals + last * 160, 160);
        memcpy(w.nets + index * 20, w.nets + last * 20, 20);
    }
    SetActive(last);
}

static float Factor(uint32_t index) { return GetF(w.locals + index * 160 + 32); }
static void SetFactor(uint32_t index, float t) { PutF(w.locals + index * 160 + 32, t); }

static VpmComponent* Me(void) { return fake_component(0); }
static void Started(void)
{
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
}
/* A fresh fake and world, for a scenario's second world. */
static void Fresh(void)
{
    fake_setup();
    NewWorld();
}

static HdhTestView Now(void)
{
    HdhTestView view;
    hellpod_drop_hold_test_view(&view);
    return view;
}
static int Loading(void) { return Now().loading; }
static int Held(void) { return Now().held; }

/* One frame's calls. */
static FakeCounts Frame(void)
{
    fake_counts_reset();
    fake_frames(1, DT);
    return fake_counts();
}

static int Occurrences(const char* text)
{
    int n = 0;
    for (const char* at = strstr(fake_log_text(), text); at != NULL; at = strstr(at + 1, text)) n++;
    return n;
}
/* The stores so far (the Lua tests' write_batch count): each hold and each release that wrote logs its line. */
static int Stores(void) { return Occurrences("] holding ") + Occurrences(") after "); }

/* ---- scenarios --------------------------------------------------------------------------------------------------- */

/* Ship and menus, no loading screen, no manager: a poll of exactly 2 reads (the state and the presenters; the Lua: 4,
 * with the two pointers) every 15 or 16 frames, nothing at all between, no store, no log line. */
static void IdlePollsTwoReadsFourTimesASecond(void)
{
    NewWorld();
    Screen(1);
    SetGlobal(MANAGER_RVA, NULL);
    Started();
    CHECK(strcmp(vpm_status(Me()), "waiting_for_loading_screen") == 0);
    CHECK_EQ(Frame().read, 2);
    int polls = 0, last = 0, other = 0;
    for (int frame = 1; frame <= 600; frame++)
    {
        FakeCounts c = Frame();
        other += (int)(c.write + c.log + c.code_matches + c.find_pattern + c.get_live + c.set_live + c.hook + c.other);
        if (c.read == 0) continue;
        CHECK_EQ(c.read, 2);
        CHECK(frame - last >= 15 && frame - last <= 16);
        polls++;
        last = frame;
    }
    CHECK(polls >= 37 && polls <= 40);
    CHECK_EQ(other, 0);
    CHECK(!Loading() && !Held());
    CHECK_EQ(Stores(), 0);
}

/* A mission in progress without a loading screen: the pods are never looked at. */
static void NeverHoldsWithoutALoadingScreen(void)
{
    NewWorld();
    NoScreen();
    uint32_t a = OwnPod(), b = AddPod(&kReinforce, 1, 1, 0);
    Started();
    fake_frames(600, DT);
    CHECK(!Held());
    CHECK_EQ(Stores(), 0);
    CHECK(Factor(a) == 1.0f && Factor(b) == 1.0f);
}

/* A join in progress: the loading screen, then the own pod spawns, then the screen leaves. The exact calls per frame. */
static void JoinInProgressHoldsWhileLoading(void)
{
    NewWorld();
    Screen(2);
    AddPod(&kPayload, 1, 1, 0); /* a payload pod and a teammate's drop */
    AddPod(&kInitial, 0, 1, 0);
    Started();
    /* The idle poll 2; the loading frame's signals 5 (state, presenters, client state, hotjoin flags, scenes); the
     * manager header 1; the sighting scan (pointers 1, records 2) and the hold scan (the same 3). The Lua: 4 + 9 + 2 + 3 + 3. */
    CHECK_EQ(Frame().read, 2 + 5 + 1 + 3 + 3);
    CHECK(Loading() && !Held());
    CHECK_EQ(Frame().read, 5 + 1); /* a loading frame, no new pod (the Lua: 9 + 2) */
    uint32_t index = OwnPod();
    /* Signals 5, manager 1; sighting (pointers 1, records 3, height 1, phase 1); hold scan (pointers 1, records 3, phase 1,
     * map 1); settings (table pointer, slots, variant, speeds) 4; t 1; recheck (pointer, record, map) 3; read-back 1; the
     * height for the log 1. The Lua: 9 + 2 + 6 + 6 + 5 + 1 + 3 + 1 + 1, and one write_batch. */
    FakeCounts spawn = Frame();
    CHECK_EQ(spawn.read, 5 + 1 + 6 + 6 + 4 + 1 + 3 + 1 + 1);
    CHECK_EQ(spawn.write, 0); /* a plain store after the page check */
    CHECK(Held() && Close(Factor(index), T_HOLD));
    CHECK(Factor(0) == 1.0f && Factor(1) == 1.0f); /* the other pods untouched */
    CHECK_EQ(Stores(), 1);
    int polls = 0;
    for (int i = 0; i < 60; i++)
    {
        FakeCounts c = Frame();
        CHECK(c.read == 5 || c.read == 5 + 4); /* the cover every frame; manager 1 and the pod 3 every 0.25 s (the Lua: 9, 14) */
        polls += c.read == 5 + 4;
    }
    CHECK(polls == 3 || polls == 4);
    CHECK_EQ(Stores(), 1);
    NoScreen();
    /* The first frame without the cover releases: signals 5; manager 1, the pod (pointer, record, map) 3, t 1, read-back
     * 1, height 1 (the Lua: 9 + 8). */
    CHECK_EQ(Frame().read, 5 + 7);
    CHECK(!Held() && Factor(index) == 1.0f); /* released to exactly 1.0 */
    fake_frames(120, DT);
    CHECK_EQ(Stores(), 2); /* never held again */
    CHECK_LOG("[Hellpod Drop Hold] loading screen up");
    CHECK_LOG("holding initial spawn pod 103 at 1500 m (speed factor 1.000 -> -0.332)");
    CHECK_LOG("released pod 103 (loading screen gone) after 1.0 s at 1500 m");
}

/* Preparing a mission (game state 6) counts as loading, with or without a loading presenter; so does preparing the ship.
 * The log follows the state and the HUD. */
static void PreparingCountsAsLoading(void)
{
    NewWorld();
    NoScreen();
    GameState(6);
    Started();
    fake_frames(20, DT);
    CHECK(Loading());
    uint32_t index = OwnPod();
    fake_frames(2, DT);
    CHECK(Held());
    GameState(4); /* the mission begins, with the mission HUD */
    Screens(0, NULL, 3);
    fake_frames(1, DT);
    CHECK(!Held() && Factor(index) == 1.0f); /* released at once */
    CHECK_LOG("game state 6, hud none, menu none, popup 0, menu stack [], cutscene none (next none), client state 0, hotjoining 0, hotjoined 0");
    CHECK_LOG("game state 4, hud mission");
    Fresh();
    NoScreen();
    GameState(5);
    Started();
    fake_frames(20, DT);
    CHECK(Loading());
}

/* The join seen live on 2026-10-05: preparing ended before the pod existed, while the join cutscene went on. A cutscene
 * on the ship never keeps a loading period going, and one in a mission without a loading screen before it never starts
 * one. */
static void JoinCutsceneKeepsThePodHeld(void)
{
    NewWorld();
    NoScreen();
    GameState(3);
    Cutscene(15, 0); /* on the ship: the network-join cutscene plays */
    JoinFlags(1, 1, 3);
    Started();
    fake_frames(30, DT);
    CHECK(!Loading()); /* a cutscene alone never starts a loading period */
    GameState(6);      /* preparing the mission (7 s in the live join) */
    fake_frames(30, DT);
    CHECK(Loading());
    GameState(4);      /* the mission: no pod yet, the cutscene goes on */
    fake_frames(30, DT);
    CHECK(Loading() && !Held());
    uint32_t index = OwnPod(); /* the host's drop arrives behind the cutscene */
    fake_frames(2, DT);
    CHECK(Held());
    fake_frames(120, DT);
    CHECK(Held()); /* held while the cutscene plays */
    Cutscene(0, 0); /* synchronized tasks done: the cutscene is interrupted */
    JoinFlags(0, 1, 3);
    fake_frames(1, DT);
    CHECK(!Held() && Factor(index) == 1.0f); /* released at once */
    CHECK_LOG("cutscene ship teleporter network join");
    CHECK_LOG("own initial spawn pod 101 seen at 1500 m, phase 0");
    CHECK_LOG("hotjoining 1");
    CHECK_LOG("hotjoining 0");
    Fresh();
    NoScreen();
    GameState(5);
    Cutscene(9, 0);
    Started();
    fake_frames(20, DT);
    CHECK(Loading());
    GameState(3);
    fake_frames(20, DT);
    CHECK(!Loading());
    Fresh();
    NoScreen();
    Cutscene(1, 0);
    uint32_t reinforce = AddPod(&kReinforce, 1, 1, 0);
    Started();
    fake_frames(60, DT);
    CHECK(!Held() && Factor(reinforce) == 1.0f);
}

/* is_hotjoining alone keeps a loading period going in the mission (a join without the cutscene); unreadable join flags
 * never count, nor do the flags on the ship. */
static void HotjoiningKeepsThePodHeld(void)
{
    NewWorld();
    NoScreen();
    GameState(6);
    JoinFlags(1, 1, 3);
    Started();
    fake_frames(20, DT);
    CHECK(Loading());
    GameState(4);
    uint32_t index = OwnPod();
    fake_frames(2, DT);
    CHECK(Held());
    fake_frames(300, DT);
    CHECK(Held()); /* held while the join is still finishing */
    JoinFlags(0, 1, 3); /* synchronized tasks done */
    fake_frames(120, DT);
    CHECK(!Held() && Factor(index) == 1.0f);
    Fresh();
    NoScreen();
    GameState(6);
    SetGlobal(SESSION_RVA, NULL);
    Started();
    fake_frames(20, DT);
    CHECK(Loading());
    GameState(4);
    fake_frames(20, DT);
    CHECK(!Loading());
    CHECK_LOG("client state 255, hotjoining 255, hotjoined 255");
    Fresh();
    NoScreen();
    GameState(3);
    JoinFlags(1, 1, 3);
    Started();
    fake_frames(40, DT);
    CHECK(!Loading());
}

/* A slow load at mission start, a second loading screen later, a reinforce-type pod: loading screens 2 and 4 at any depth
 * hold, screen 3 does not, and a reinforce pod uses its own speeds. */
static void LoadingScreensAndReinforcements(void)
{
    NewWorld();
    Screens(2, (const uint32_t[]){14, 2}, 0); /* loading below another screen still counts */
    Started();
    fake_frames(3, DT);
    uint32_t index = AddPod(&kReinforce, 1, 1, 0);
    fake_frames(1, DT);
    CHECK(Held());
    CHECK(Close(Factor(index), (0.5 - 100) / (350 - 100)));
    Screen(4); /* the tutorial screen counts too */
    fake_frames(200, DT);
    CHECK(Held());
    Screen(3); /* the ship loading screen does not */
    fake_frames(200, DT);
    CHECK(!Held() && Factor(index) == 1.0f);
}

/* Only own falling or braking drop pods that the id map confirms are held; the saved factor comes back. */
static void PhasesAndOwnership(void)
{
    NewWorld();
    Screen(2);
    uint32_t landed = AddPod(&kInitial, 1, 1, 2), remote = AddPod(&kInitial, 0, 1, 0), payload = AddPod(&kPayload, 1, 1, 0);
    Started();
    fake_frames(30, DT);
    CHECK(!Held());
    uint32_t braking = AddPod(&kInitial, 1, 0.4f, 1);
    fake_frames(1, DT);
    CHECK(Held());
    CHECK(Factor(landed) == 1.0f && Factor(remote) == 1.0f && Factor(payload) == 1.0f);
    CHECK(Close(Factor(braking), T_HOLD));
    NoScreen();
    fake_frames(200, DT);
    CHECK(Factor(braking) == 0.4f); /* released to the saved 0.4 */
    Fresh();
    Screen(2);
    uint32_t stray = OwnPod();
    for (uint32_t slot = 0; slot < 64; slot++) Put32(w.map + slot * 8, EMPTY); /* the id map does not place it */
    Started();
    fake_frames(30, DT);
    CHECK(!Held() && Factor(stray) == 1.0f);
}

/* A held pod that the manager moves is found again and released at its new index. */
static void FollowsAPodTheManagerMoves(void)
{
    NewWorld();
    Screen(2);
    AddPod(&kPayload, 1, 1, 0);
    AddPod(&kPayload, 1, 1, 0);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held() && Now().index == index);
    RemovePod(0); /* the game moves the held pod into index 0 */
    fake_frames(20, DT);
    CHECK(Held() && Now().index == 0); /* located at its new index */
    NoScreen();
    fake_frames(200, DT);
    CHECK(!Held() && Factor(0) == 1.0f);
    CHECK_EQ(Stores(), 2);
}

/* A held pod that disappears is forgotten without a store. */
static void ForgetsAPodThatIsGone(void)
{
    NewWorld();
    Screen(2);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held());
    RemovePod(index);
    fake_frames(20, DT);
    CHECK(!Held());
    CHECK_EQ(Stores(), 1);
    CHECK_LOG("pod 101 is gone");
    NoScreen();
    fake_frames(200, DT);
    CHECK_EQ(Stores(), 1);
}

/* A factor changed by someone else is never overwritten, at the hold or at the release. */
static void LeavesAFactorSetElsewhere(void)
{
    NewWorld();
    Screen(2);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held());
    SetFactor(index, 0.25f);
    NoScreen();
    fake_frames(200, DT);
    CHECK(!Held() && Factor(index) == 0.25f);
    CHECK_EQ(Stores(), 1);
    CHECK_LOG("released pod 101 (loading screen gone): left unchanged, its speed changed elsewhere");
    Fresh();
    Screen(2);
    uint32_t odd = AddPod(&kInitial, 1, 7, 0);
    Started();
    fake_frames(30, DT);
    CHECK(!Held() && Factor(odd) == 7.0f);
    CHECK_LOG("pod 101 left alone: drop_pod_speed_set_elsewhere");
}

/* The longest hold ends at 120 s, and that pod is not held again under the same screen. */
static void LongestHoldIsTwoMinutes(void)
{
    NewWorld();
    Screen(2);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held());
    fake_frames(119 * 10, 0.1f);
    CHECK(Held());
    fake_frames(20, 0.1f);
    CHECK(!Held() && Factor(index) == 1.0f);
    CHECK_LOG("(longest hold) after 120.0 s");
    fake_frames(300, 0.1f);
    CHECK(!Held());
    CHECK_EQ(Stores(), 2);
}

/* A release that cannot read the manager keeps the hold and retries 4 times a second. */
static void RetriesAReleaseWhileTheManagerIsUnreadable(void)
{
    NewWorld();
    Screen(2);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held());
    NoScreen();
    uint8_t* unreadable = fake_heap(128); /* the manager's header unreadable: its global points into a hole */
    fake_hole((uintptr_t)unreadable, 128);
    SetGlobal(MANAGER_RVA, unreadable);
    fake_frames(200, DT);
    CHECK(Held() && Now().retrying); /* kept */
    CHECK(Close(Factor(index), T_HOLD));
    SetGlobal(MANAGER_RVA, w.manager);
    fake_frames(16, DT);
    CHECK(!Held() && Factor(index) == 1.0f);
}

/* A manager or setting that makes no sense stops the component before any store; a missing manager waits; a menu stack
 * deeper than 5 is no loading screen. */
static void RefusalsStopBeforeAnyStore(void)
{
    static const char* const reasons[] = {"disabled: manager_layout", "disabled: manager_layout",
        "disabled: drop_pod_settings_unrecognized", "disabled: drop_pod_settings_unrecognized",
        "disabled: drop_pod_settings_unrecognized"};
    for (int c = 0; c < 5; c++)
    {
        Fresh();
        Screen(2);
        uint32_t index = OwnPod();
        if (c == 0) Put32(w.manager + 36, 5000);                  /* capacity */
        if (c == 1) Put32(w.manager + 48, 99);                    /* active above total */
        if (c == 2) PutF(w.table + 256 + 3 * 104 + 28, 600);      /* braking above initial */
        if (c == 3) Put32(w.table + 256 + 3 * 104, 0);            /* another variant */
        if (c == 4) Put32(w.table + 2 * 16, 0);                   /* the type's slot */
        Started();
        fake_frames(30, DT);
        CHECK(!vpm_running(Me()));
        CHECK_LOG(reasons[c]);
        CHECK_EQ(Stores(), 0);
        CHECK(Factor(index) == 1.0f);
    }
    Fresh();
    Screen(2);
    SetGlobal(MANAGER_RVA, NULL);
    Started();
    fake_frames(60, DT);
    CHECK(vpm_running(Me()) && Loading()); /* no manager yet: keep waiting */
    Fresh();
    Put32(w.ui + STACK_AT + 20, 9);
    Started();
    fake_frames(60, DT);
    CHECK(vpm_running(Me()) && !Loading());
}

/* A pod whose t cannot be written (the page check before the store): the component stops before the store; at the
 * release, the same check stops it with the pod still held. */
static void RefusesReadOnlyPods(void)
{
    DWORD old;
    NewWorld();
    Screen(2);
    uint32_t index = OwnPod();
    VirtualProtect(w.locals, LOCALS_SIZE, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
    Started();
    fake_frames(5, DT);
    VirtualProtect(w.locals, LOCALS_SIZE, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(!vpm_running(Me()));
    CHECK_LOG("disabled: drop_pod_not_writable");
    CHECK(Factor(index) == 1.0f);
    Fresh();
    Screen(2);
    index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held());
    VirtualProtect(w.locals, LOCALS_SIZE, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
    NoScreen();
    fake_frames(1, DT);
    VirtualProtect(w.locals, LOCALS_SIZE, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(!vpm_running(Me()));
    CHECK_LOG("disabled: drop_pod_release_failed");
    CHECK(Close(Factor(index), T_HOLD));
}

/* The core stopping the component (a fault or a refusal) releases the held pod, as the Lua's stop did. */
static void StopReleasesTheHeldPod(void)
{
    NewWorld();
    Screen(2);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held());
    vpm_core_stop(Me(), "test");
    CHECK(Factor(index) == 1.0f);
    CHECK_LOG("released pod 101 (stopped) after");
}

/* HellForge copies a component table when a mod's entity owns records in it, and points the game at the copy: the
 * speeds come from the table the game reads now. */
static void FollowsHellForgesCopyOfTheSettings(void)
{
    NewWorld();
    uint8_t* copy = fake_heap(256 + 104 * 8);
    memcpy(copy, w.table, 256 + 104 * 8);
    PutF(copy + 256 + 3 * 104 + 20, 300); /* the copy's initial-spawn velocity */
    Put64(w.owner + SETTINGS_TABLE_AT, (uint64_t)(uintptr_t)copy);
    Screen(2);
    uint32_t index = OwnPod();
    Started();
    fake_frames(2, DT);
    CHECK(Held() && Close(Factor(index), (0.5 - 100) / (300 - 100)));
}

int main(void)
{
    RUN(IdlePollsTwoReadsFourTimesASecond);
    RUN(NeverHoldsWithoutALoadingScreen);
    RUN(JoinInProgressHoldsWhileLoading);
    RUN(PreparingCountsAsLoading);
    RUN(JoinCutsceneKeepsThePodHeld);
    RUN(HotjoiningKeepsThePodHeld);
    RUN(LoadingScreensAndReinforcements);
    RUN(PhasesAndOwnership);
    RUN(FollowsAPodTheManagerMoves);
    RUN(ForgetsAPodThatIsGone);
    RUN(LeavesAFactorSetElsewhere);
    RUN(LongestHoldIsTwoMinutes);
    RUN(RetriesAReleaseWhileTheManagerIsUnreadable);
    RUN(RefusalsStopBeforeAnyStore);
    RUN(RefusesReadOnlyPods);
    RUN(StopReleasesTheHeldPod);
    RUN(FollowsHellForgesCopyOfTheSettings);
    TEST_END();
}
