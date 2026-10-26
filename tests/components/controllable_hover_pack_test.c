/* Controllable Hover Pack: the Lua tests' scenarios (components/ControllableHoverPack/tests: test_cancel.lua,
 * test_replay.lua, test_snapshot.lua, test_settings.lua, test_idle_gate.lua) on the fake game. The settings writes are
 * real here (the Lua's snapshot tests stubbed them), so a frame's pinned counts are the whole frame's: reads (vpm_read),
 * focus checks (GetForegroundWindow) and VirtualQuery calls (vpm_writable, counted by the component under VPM_TEST).
 *
 * The test drives the core with its own copy of the fake HfApi whose read can fail at one address or answer another
 * value on the Nth read of one (the Lua tests' "missing" reads), and replaces user32's focus functions with fakes. */
#include <stdio.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/controllable_hover_pack/hover.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_controllable_hover_pack};

#define HOVER 0x5EC80F4F1CDB66CFull
#define OTHER_PACK 0x073270650F859DD0ull
#define AVATAR 0x4D1C334D294DFA97ull
#define PLAYER 0x1111111111111111ull
#define UNIT 391u
#define AVATAR_ID 513u
#define PACK_ID 524u
#define RECORD 280u
#define CUTOFF (1.0f / 1024.0f)
#define DT (1.0f / 60.0f)
#define EMPTY 0xFFFFFFFFu

/* ---- the fake game's registries (test_snapshot.lua's and test_settings.lua's fixtures in one) -------------------- */

typedef struct Game
{
    uint8_t *mode, *pm, *em, *am, *eq, *jm, *attach;
    uint8_t *player, *avatar, *ids, *eqRows, *entries, *pack, *attachRows, *states, *flags, *input;
    uint8_t *forwardRows, *reverseRows, *data, *resources;
    uint32_t index; /* the pack's registry row */
    uint32_t generation;
} Game;
static Game g;

static void Put32(void* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(void* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutF(void* at, float v) { memcpy(at, &v, 4); }
static uint32_t Get32(const void* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static float GetF(const void* at) { float v; memcpy(&v, at, 4); return v; }
static void Global(uint32_t rva, const void* p) { Put64((uint8_t*)fake_game() + rva, (uint64_t)(uintptr_t)p); }

/* Memory in pages of its own, so a test can make it read-only. */
static uint8_t* Page(size_t size)
{
    uint8_t* raw = fake_heap(size + 3 * 4096);
    return (uint8_t*)(((uintptr_t)raw + 4095) & ~(uintptr_t)4095);
}

static void Protect(void* at, size_t size, DWORD protect)
{
    DWORD old;
    CHECK(VirtualProtect(at, size, protect, &old)); /* lint-ok: C3 the test makes the fake game's memory read-only and back */
}

/* An 8-row map at header {rows, 8, empty, multiplier}, every row {empty, second}. */
static uint8_t* Map(uint8_t* header, uint32_t multiplier, uint32_t empty, uint32_t second)
{
    uint8_t* rows = Page(64);
    Put64(header, (uint64_t)(uintptr_t)rows);
    Put32(header + 8, 8);
    Put32(header + 12, empty);
    Put32(header + 16, multiplier);
    for (int i = 0; i < 8; i++)
    {
        Put32(rows + 8 * i, empty);
        Put32(rows + 8 * i + 4, second);
    }
    return rows;
}

static void MapSet(uint8_t* rows, uint32_t multiplier, uint32_t key, uint32_t index)
{
    uint8_t* row = rows + 8u * ((key * multiplier) % 8u);
    Put32(row, key);
    Put32(row + 4, index);
}

static void Entity(uint8_t* at, uint64_t resource, uint32_t id, uint32_t unit, int owned)
{
    Put64(at, resource);
    Put32(at + 8, id);
    Put32(at + 12, unit);
    Put32(at + 16, 5);
    Put32(at + 20, owned ? 1u : 0u);
}

static void Player(void)
{
    Put32(g.pm + 0x84, 2);
    Put32(g.pm + 0x88, 2);
    g.player = fake_heap(24);
    Entity(g.player, PLAYER, 10, 99, 1);
    Put64(g.pm + 0xE8, (uint64_t)(uintptr_t)g.player);
    Put32(g.pm + 0x3A8, UNIT);
    MapSet(Map(g.em + 0xF22EC8, 1, EMPTY, EMPTY), 1, UNIT, 2);
    g.avatar = g.em + 0xF32F18 + 2 * 24;
    Entity(g.avatar, AVATAR, AVATAR_ID, UNIT, 1);
    /* the avatar at index ONE: index 0 is never assumed */
    MapSet(Map(g.am + 0xF8, 1, EMPTY, EMPTY), 1, AVATAR_ID, 1);
    Put32(g.am + 0x6C, 2);
    Put64(g.am + 0x118, (uint64_t)(uintptr_t)g.avatar);
    g.flags = g.am + 0x53D900 + 0x1238 + 0xF80;
    Put32(g.flags + 8, 4);
    Put32(g.flags + 12, 4);
    g.input = g.am + 0x150 + 0xA7AEC + 0x1B68 + 15 * 32;
}

static void Backpack(void)
{
    MapSet(Map(g.eq + 40, 1, EMPTY, EMPTY), 1, AVATAR_ID, 1);
    g.ids = fake_heap(16);
    Put64(g.ids + 8, (uint64_t)(uintptr_t)g.avatar);
    Put64(g.eq + 64, (uint64_t)(uintptr_t)g.ids);
    g.eqRows = fake_heap(2 * 48);
    Put32(g.eqRows + 48 + 12, PACK_ID);
    Put64(g.eq + 80, (uint64_t)(uintptr_t)g.eqRows);
    /* the jump-pack registry: pack 524 at row 1, the hover pack, owned; both packs active and simulated here */
    MapSet(Map(g.jm + 32, 1, EMPTY, EMPTY), 1, PACK_ID, 1);
    g.index = 1;
    Put32(g.jm + 16, 2);
    Put32(g.jm + 20, 2);
    g.entries = fake_heap(16);
    g.pack = fake_heap(24);
    Put64(g.entries + 8, (uint64_t)(uintptr_t)g.pack);
    Put64(g.jm + 56, (uint64_t)(uintptr_t)g.entries);
    g.generation = 250;
    Entity(g.pack, HOVER, PACK_ID, g.generation, 1);
    g.states = fake_heap(16);
    Put64(g.jm + 80, (uint64_t)(uintptr_t)g.states);
    memcpy(g.states, "\0\0\1\0\0\0\0\1\0\0", 10);
    MapSet(Map(g.attach + 32, 1, EMPTY, EMPTY), 1, PACK_ID, 1);
    g.attachRows = fake_heap(2 * 48);
    Put32(g.attachRows + 48 + 4, AVATAR_ID);
    Put64(g.attach + 64, (uint64_t)(uintptr_t)g.attachRows);
}

/* The per-pack settings: 32 free records, the maps empty; the shared hover resource (6 s, timed). */
static void Settings(void)
{
    Put32(g.jm + 4, 32);
    Put32(g.jm + 12, 2);
    Put32(g.jm + 152, 0);
    g.data = Page(RECORD * 32);
    Put64(g.jm + 160, (uint64_t)(uintptr_t)g.data);
    g.forwardRows = Map(g.jm + 96, 2, 0, 0);
    g.reverseRows = Map(g.jm + 128, 2, EMPTY, 0);
    g.resources = fake_heap(96 + 3 * RECORD);
    Put64(g.em + 0xF12CB8, (uint64_t)(uintptr_t)g.resources);
    Put64(g.resources, HOVER);
    Put32(g.resources + 8, 0);
    uint8_t* component = g.resources + 96;
    component[153] = component[154] = component[155] = 1;
    PutF(component + 156, 6.0f);
}

static void MakeGame(void)
{
    memset(&g, 0, sizeof g);
    g.mode = fake_heap(0x50);
    g.pm = fake_heap(0x400);
    g.em = fake_heap(0xF33000);
    g.am = fake_heap(0x541000);
    g.eq = fake_heap(0x100);
    g.jm = Page(0x200);
    g.attach = fake_heap(0x100);
    Global(CHP_RVA_MODE, g.mode);
    Global(VPM_RVA_PLAYER_MANAGER, g.pm);
    Global(VPM_RVA_ENTITY_OWNER, g.em);
    Global(VPM_RVA_AVATAR_MANAGER, g.am);
    Global(CHP_RVA_EQUIPMENT, g.eq);
    Global(CHP_RVA_JUMP_PACKS, g.jm);
    Global(CHP_RVA_ATTACHMENT, g.attach);
    Put32(g.mode + 8, 1);
    Put32(g.mode + 0x40, 2);
    Player();
    Backpack();
    Settings();
}

static void Row(const char* five) { memcpy(g.states + 5 * g.index, five, 5); }
static void Held(float seconds) { PutF(g.input + 8, seconds); }
static float Duration(int index) { return GetF(g.data + RECORD * index + 156); }
static void Mission(uint32_t type) { Put32(g.mode + 0x40, type); }
#define FLIGHT "\1\0\1\0\1"
#define IDLE "\0\0\1\0\0"
#define LANDING "\1\1\1\0\1"

/* The jump-pack registry compacts: the pack moves to row index (and the other row is emptied). */
static void Move(uint32_t index)
{
    MapSet(Map(g.jm + 32, 1, EMPTY, EMPTY), 1, PACK_ID, index);
    Put64(g.entries + 8 * index, (uint64_t)(uintptr_t)g.pack);
    Put64(g.entries + 8 * (1 - index), 0);
    g.index = index;
}

static ChpTarget Target(void)
{
    ChpTarget t;
    memset(&t, 0, sizeof t);
    t.manager = (uintptr_t)g.jm;
    t.pack = PACK_ID;
    memcpy(t.identity, g.pack, 20);
    memcpy(t.key.avatar, g.avatar, 24);
    memcpy(t.key.entity, g.pack, 24);
    t.key.manager = (uintptr_t)g.jm;
    return t;
}

/* ---- the fake HellForge with failing reads, and the focus ------------------------------------------------------ */

static HfApi g_api;
static uintptr_t g_missing;            /* a read at exactly this address fails */
static uintptr_t g_changeAt;           /* the g_changeOn-th read at this address answers g_changeTo */
static int g_changeOn, g_changeSeen;
static uint32_t g_changeTo;
static int g_focused, g_focusChecks;

static int TestRead(uintptr_t address, void* buffer, size_t size)
{
    if (address == g_missing) return fake_api()->read(0, buffer, size); /* counted, and refused */
    int r = fake_api()->read(address, buffer, size);
    if (r == 0 && address == g_changeAt && ++g_changeSeen == g_changeOn) memcpy(buffer, &g_changeTo, 4);
    return r;
}

static void ChangeRead(uintptr_t at, int on, uint32_t to)
{
    g_changeAt = at;
    g_changeOn = on;
    g_changeSeen = 0;
    g_changeTo = to;
}

static int g_window; /* the fake game window's handle is its address */

static void* __stdcall FakeForeground(void)
{
    g_focusChecks++;
    return g_focused ? (void*)&g_window : NULL;
}

static unsigned long __stdcall FakeWindowProcess(void* window, unsigned long* process)
{
    *process = GetCurrentProcessId();
    return 1;
}

static void Started(void)
{
    g_api = *fake_api();
    g_api.read = TestRead;
    g_missing = 0;
    ChangeRead(0, 0, 0);
    g_focused = 1;
    g_focusChecks = 0;
    chp_test_queries = 0;
    CHECK_EQ(vpm_core_init(&g_api, fake_mod(), kDefs, 1), 0);
    VpmUser32* user = (VpmUser32*)vpm_user32();
    user->GetForegroundWindow = FakeForeground;
    user->GetWindowThreadProcessId = FakeWindowProcess;
    fake_fire(HF_EVENT_GAME_LOADED);
}

static const char* Status(void) { return vpm_status(fake_component(0)); }

#define CHECK_STATUS(text) do { test_checks++; if (strcmp(Status(), text) != 0) { test_failures++; \
    printf("  FAILED %s:%d: the status is \"%s\", expected \"%s\"\n", __FILE__, __LINE__, Status(), text); } } while (0)

typedef struct Frame { uint32_t reads, logs; int focus, queries; } Frame;

/* The core's status lines (vpm_set_status, rate-limited) are the core's: a frame's logs here are the component's own. */
static int CoreStatusLines(void) { return fake_log_count("[core] Controllable Hover Pack status:"); }

static Frame Tick(void)
{
    int focus = g_focusChecks, queries = chp_test_queries, statusLines = CoreStatusLines();
    fake_counts_reset();
    fake_frames(1, DT);
    Frame f = {fake_counts().read, fake_counts().log - (uint32_t)(CoreStatusLines() - statusLines), g_focusChecks - focus,
        chp_test_queries - queries};
    return f;
}

static void Ticks(int n)
{
    for (int i = 0; i < n; i++) (void)Tick();
}

/* One frame: its status and exact calls (the Lua's frame_budget pins, exact). */
#define CHECK_TICK(status_, reads_, focus_, queries_) do { Frame f_ = Tick(); CHECK_STATUS(status_); \
    CHECK_EQ(f_.reads, reads_); CHECK_EQ(f_.focus, focus_); CHECK_EQ(f_.queries, queries_); CHECK_EQ(f_.logs, 0); } while (0)
#define CHECK_GATED(n_, status_, reads_) do { for (int i_ = 0; i_ < (n_); i_++) CHECK_TICK(status_, reads_, 0, 0); } while (0)

/* ---- the press policy (test_cancel.lua, test_replay.lua) -------------------------------------------------------- */

static int Step(ChpPolicy* p, int down, uintptr_t key, int flight)
{
    ChpSnapshot s;
    memset(&s, 0, sizeof s);
    s.down = down;
    s.flight = flight;
    s.key.manager = key;
    return chp_policy_step(p, &s);
}

static void PolicyNeedsAReleaseThenOnePressPerFlight(void)
{
    ChpPolicy p;
    memset(&p, 0, sizeof p);
    CHECK(!Step(&p, 1, 1, 1)); /* the activation hold */
    CHECK(!Step(&p, 1, 1, 1));
    CHECK(!Step(&p, 0, 1, 1));
    CHECK(Step(&p, 1, 1, 1));
    CHECK(!Step(&p, 1, 1, 1));
    CHECK(!Step(&p, 0, 1, 1));
    CHECK(!Step(&p, 1, 1, 1)); /* one cancellation per flight */
    CHECK(!chp_policy_step(&p, NULL));
    CHECK(!Step(&p, 1, 1, 1)); /* a focus or read recovery cannot make a press */
    CHECK(!Step(&p, 0, 1, 1));
    CHECK(Step(&p, 1, 1, 1));
    CHECK(!Step(&p, 1, 2, 1)); /* a replacement pack */
    CHECK(!Step(&p, 0, 2, 1));
    CHECK(Step(&p, 1, 2, 1));
    CHECK(!Step(&p, 0, 1, 0)); /* the next flight */
    CHECK(!Step(&p, 0, 1, 1));
    CHECK(Step(&p, 1, 1, 1));
}

/* A captured vanilla flight (tests/flight_replay.lua): one cancellation, at the first press after the release. */
static void PolicyReplayCancelsAtTheFirstRepress(void)
{
    static const struct { double t; int flight, down; } kRows[] = {
        {0.000000, 0, 0}, {115.293109, 0, 1}, {115.488562, 1, 1}, {115.985159, 1, 0}, {116.072967, 1, 1},
        {116.301563, 1, 0}, {116.442675, 1, 1}, {116.585446, 1, 0}, {117.137111, 1, 1}, {117.701160, 1, 0},
        {118.248922, 1, 1}, {118.709385, 1, 0},
    };
    ChpPolicy p;
    memset(&p, 0, sizeof p);
    int calls = 0;
    double at = 0;
    for (size_t i = 0; i < sizeof kRows / sizeof kRows[0]; i++)
        if (Step(&p, kRows[i].down, 7, kRows[i].flight)) { calls++; at = kRows[i].t; }
    CHECK_EQ(calls, 1);
    CHECK(at > 116.063 && at < 116.083);
}

/* ---- the snapshot (test_snapshot.lua) ---------------------------------------------------------------------------- */

static void SnapshotFindsThePackAtLocalIndexOne(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    const ChpSnapshot* s = NULL;
    fake_counts_reset();
    CHECK_EQ(chp_snapshot(0, &s), CHP_VALID);
    CHECK_EQ(fake_counts().read, 34); /* the mode, then 33 from the registry roots (the Lua: 2 + 39, its globals read) */
    CHECK(s->flight && !s->down && s->active && s->pack == PACK_ID && s->manager == (uintptr_t)g.jm);
    CHECK(memcmp(s->key.entity, g.pack, 24) == 0 && memcmp(s->key.avatar, g.avatar, 24) == 0);
    fake_counts_reset();
    CHECK_EQ(chp_snapshot(0, &s), CHP_VALID);
    CHECK_EQ(fake_counts().read, 15); /* the kept layout (the Lua: 16) */
    fake_counts_reset();
    CHECK_EQ(chp_snapshot(1, &s), CHP_VALID);
    CHECK_EQ(fake_counts().read, 34); /* fresh: from the roots again */
    /* +0x40 is a mission type: 1 .. 7 are missions (Evacuate High-Value Assets is 2) */
    for (uint32_t type = 1; type <= 7; type++)
    {
        Mission(type);
        CHECK_EQ(chp_snapshot(0, &s), CHP_VALID);
    }
    const uint32_t outside[] = {0, 8, 0xFFFFFFFFu};
    for (int i = 0; i < 3; i++)
    {
        Mission(outside[i]);
        CHECK_EQ(chp_snapshot(0, &s), CHP_WAITING_FOR_MISSION);
    }
    Mission(2);
    Put32(g.mode + 8, 0);
    CHECK_EQ(chp_snapshot(0, &s), CHP_WAITING_FOR_MISSION);
}

static void SnapshotChecksHolderResourceStateAndInput(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    const ChpSnapshot* s = NULL;
    Put32(g.attachRows + 48 + 4, 999); /* another holder */
    CHECK_EQ(chp_snapshot(0, &s), CHP_PACK_NOT_ATTACHED);
    Put32(g.attachRows + 48 + 4, AVATAR_ID);
    Entity(g.pack, OTHER_PACK, PACK_ID, 250, 1); /* an ordinary jump pack */
    CHECK_EQ(chp_snapshot(0, &s), CHP_NOT_HOVER_PACK);
    Entity(g.pack, HOVER, PACK_ID, 250, 1);
    CHECK_EQ(chp_snapshot(0, &s), CHP_VALID);
    /* the native action is inhibited during ragdoll, swimming and ordinary grounded movement */
    Put32(g.flags + 12, 0x14);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && !s->flight);
    Put32(g.flags + 12, 4);
    Put32(g.flags + 8, 0x80000004u);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && !s->flight);
    Put32(g.flags + 8, 4);
    Row(IDLE);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && !s->flight && !s->active);
    Row(LANDING); /* the landing assistance: still active, no new cancel window */
    CHECK(chp_snapshot(0, &s) == CHP_VALID && !s->flight && s->active);
    Row(FLIGHT);
    /* +0x14, the locally simulated prefix, lies inside +0x10, the active one */
    Put32(g.jm + 16, 3);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && s->pack == PACK_ID);
    Put32(g.jm + 20, 1);
    CHECK_EQ(chp_snapshot(0, &s), CHP_PACK_NOT_OWNED);
    Put32(g.jm + 16, 2);
    Put32(g.jm + 20, 2);
    /* a NaN or negative held time is unsupported input */
    const uint32_t bad[] = {0x7FC00000u, 0xFFC00000u, 0xBF800000u};
    for (int i = 0; i < 3; i++)
    {
        Put32(g.input + 8, bad[i]);
        CHECK_EQ(chp_snapshot(0, &s), CHP_WAITING_FOR_GAME_DATA);
        CHECK(chp_snapshot_error() != NULL && strcmp(chp_snapshot_error(), "Invalid jump input") == 0);
    }
    Held(0);
    CHECK_EQ(chp_snapshot(0, &s), CHP_VALID);
}

/* The kept layout notices a replacement holder, a moved equipment row and a registry row that no longer holds the
 * pack: each resolves again. */
static void KeptLayoutNoticesWhatMoved(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    const ChpSnapshot* s = NULL;
    CHECK_EQ(chp_snapshot(0, &s), CHP_VALID);
    Put32(g.attachRows + 48 + 4, 999);
    CHECK_EQ(chp_snapshot(0, &s), CHP_PACK_NOT_ATTACHED);
    Put32(g.attachRows + 48 + 4, AVATAR_ID);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && s->pack == PACK_ID);
    uint8_t* moved = fake_heap(2 * 48);
    Put64(g.eq + 80, (uint64_t)(uintptr_t)moved);
    CHECK_EQ(chp_snapshot(0, &s), CHP_NO_BACKPACK);
    Put64(g.eq + 80, (uint64_t)(uintptr_t)g.eqRows);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && s->pack == PACK_ID);
    Put64(g.entries + 8, 0x20000); /* a pointer that reads nothing */
    CHECK_EQ(chp_snapshot(0, &s), CHP_WAITING_FOR_READ);
    Put64(g.entries + 8, (uint64_t)(uintptr_t)g.pack);
    CHECK(chp_snapshot(0, &s) == CHP_VALID && s->pack == PACK_ID);
}

/* ---- cancelling through the tick (test_snapshot.lua's apply sequences, with the real settings) ------------------ */

static void PressCancelsOncePerFlightAndRestoresAfter(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0.3f);
    (void)Tick();
    CHECK_STATUS("watching_hover"); /* the activation hold */
    Held(0);
    (void)Tick();
    CHECK_STATUS("watching_hover");
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("cancel_requested");
    CHECK(chp_lease_held() && Duration(0) == CUTOFF);
    CHECK_LOG("[Controllable Hover Pack] cancel_requested: the hover pack's duration is cut from 6.00 s to 1/1024 s (its own record created)");
    (void)Tick();
    CHECK_STATUS("native_descent");
    g_focused = 0; /* the lease survives a focus loss and the descent */
    (void)Tick();
    CHECK_STATUS("native_descent");
    g_focused = 1;
    Row(LANDING);
    (void)Tick();
    CHECK_STATUS("native_descent");
    CHECK(chp_lease_held() && Duration(0) == CUTOFF);
    Row(IDLE);
    (void)Tick();
    CHECK_STATUS("waiting_for_hover");
    CHECK(!chp_lease_held() && Duration(0) == 6.0f);
    CHECK_LOG("[Controllable Hover Pack] restored: the hover pack's duration is 6.00 s again.");
    /* the next flight: the record is reused, and the press needs a release first again */
    Row(FLIGHT);
    Held(0.3f);
    (void)Tick();
    CHECK_STATUS("watching_hover");
    (void)Tick();
    CHECK(!chp_lease_held());
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("cancel_requested");
    CHECK(Duration(0) == CUTOFF && Get32(g.jm + 152) == 1);
    Held(0);
    Row(IDLE);
    (void)Tick();
    CHECK(Duration(0) == 6.0f && !chp_lease_held());
    CHECK(vpm_running(fake_component(0)));
}

static void FocusAndReadFailuresNeverMakeAPress(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0);
    (void)Tick();
    g_focused = 0;
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("waiting_for_game_focus");
    g_focused = 1;
    (void)Tick();
    CHECK_STATUS("watching_hover"); /* the press held through the focus loss does not count */
    CHECK(!chp_lease_held());
    Held(0);
    g_missing = (uintptr_t)g.pm + 0x3A8;
    (void)Tick();
    CHECK_STATUS("waiting_for_read");
    g_missing = 0;
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("watching_hover"); /* the read failure forgot the flight: this press is its first sample */
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("cancel_requested");
}

/* The press locates the pack afresh: a change the kept layout does not read (the player count) refuses it, and the
 * flight then needs a release and a new press. */
static void ThePressLocatesThePackAfresh(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0);
    (void)Tick();
    (void)Tick();
    Put32(g.pm + 0x84, 0);
    Put32(g.pm + 0x88, 0);
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("snapshot_changed");
    CHECK(!chp_lease_held() && Get32(g.jm + 152) == 0);
    Put32(g.pm + 0x84, 2);
    Put32(g.pm + 0x88, 2);
    (void)Tick();
    CHECK_STATUS("watching_hover");
    CHECK(!chp_lease_held());
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("cancel_requested");
}

/* A context change during the descent (here another holder) puts the duration back at once. */
static void AContextChangeRestores(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK(chp_lease_held());
    Put32(g.attachRows + 48 + 4, 999);
    (void)Tick();
    CHECK_STATUS("pack_not_attached");
    CHECK(!chp_lease_held() && Duration(0) == 6.0f);
}

/* Up to the cancellation press: 60 idle frames, the activation hold, a release, the press. 1 when it cut. */
static int Flight(void)
{
    Row(IDLE);
    Held(0);
    Ticks(60);
    Row(FLIGHT);
    Held(0.3f);
    (void)Tick();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    return strcmp(Status(), "cancel_requested") == 0 && chp_lease_held();
}

/* What the native destruction of a pack does to its record: both map rows removed, the count compacted. */
static void Destroyed(void)
{
    for (int i = 0; i < 8; i++)
    {
        Put32(g.forwardRows + 8 * i, 0);
        Put32(g.forwardRows + 8 * i + 4, 0);
        Put32(g.reverseRows + 8 * i, EMPTY);
        Put32(g.reverseRows + 8 * i + 4, 0);
    }
    Put32(g.jm + 152, 0);
}

/* The installed tick across mission types, registry removals and returns, and new pack generations. */
static void TransitionsNeverCancelAndRecover(void)
{
    MakeGame();
    Started();
    CHECK(Flight());
    for (uint32_t type = 1; type <= 7; type++)
    {
        Mission(type);
        CHECK(Flight());
    }
    Mission(2);
    struct { uint8_t* at; uint32_t size; uint64_t value; const char* what; } transitions[] = {
        {g.am + 0x6C, 4, 0, "avatar registry removal"},
        {g.pack + 8, 4, 525, "pack registry replacement"},
        {g.eq + 64, 8, 0, "equipment pointer unavailable"},
        {g.pm + 0x84, 8, 0, "local player removed"},
        {g.mode + 0x40, 4, 0, "return to ship"},
    };
    for (int i = 0; i < 5; i++)
    {
        uint8_t original[8];
        memcpy(original, transitions[i].at, transitions[i].size);
        memcpy(transitions[i].at, &transitions[i].value, transitions[i].size);
        for (int frame = 0; frame < 2; frame++)
        {
            (void)Tick();
            if (strcmp(Status(), "cancel_requested") != 0) continue;
            test_failures++;
            printf("  FAILED: a cancellation during %s\n", transitions[i].what);
        }
        memcpy(transitions[i].at, original, transitions[i].size);
        /* mission re-entry: a new pack generation (its old record removed natively) */
        Destroyed();
        Put32(g.pack + 16, 6 + (uint32_t)i);
        CHECK(Flight());
    }
    /* a registry that stays invalid: reads only, then it recovers */
    Row(IDLE);
    Ticks(2);
    Put32(g.am + 0x6C, 0);
    Ticks(40); /* past the gate's window (it reads only the state row), then a full check every frame */
    CHECK(!chp_lease_held());
    CHECK_STATUS("waiting_for_game_data: Unsupported avatar index");
    Put32(g.am + 0x6C, 2);
    CHECK(Flight());
    CHECK(vpm_running(fake_component(0)));
}

/* ---- the per-frame budget (test_snapshot.lua's, with the settings real: test_settings.lua's on the same frames) -- */

static void PerFrameBudget(void)
{
    MakeGame();
    Row(FLIGHT);
    Mission(0);
    Put32(g.eqRows + 48 + 12, 0);
    Started();
    /* outside a mission: the mission check, then 59 frames with no call (the Lua: 2 reads) */
    CHECK_TICK("waiting_for_mission", 1, 0, 0);
    CHECK_GATED(59, "waiting_for_mission", 0);
    /* in a mission without a backpack: located from the roots once (25), then 29 frames with no call and the kept
     * layout (8) */
    Mission(2);
    CHECK_TICK("no_backpack", 20, 0, 0);
    CHECK_GATED(29, "no_backpack", 0);
    CHECK_TICK("no_backpack", 7, 0, 0);
    CHECK_GATED(29, "no_backpack", 0);
    /* another jump pack picked up: the kept layout finds a backpack, then locates it (38); kept (11) */
    Put32(g.eqRows + 48 + 12, PACK_ID);
    Entity(g.pack, OTHER_PACK, PACK_ID, 250, 1);
    CHECK_TICK("not_hover_pack", 32, 0, 0);
    CHECK_GATED(29, "not_hover_pack", 0);
    CHECK_TICK("not_hover_pack", 10, 0, 0);
    Entity(g.pack, HOVER, PACK_ID, 250, 1);
    CHECK_GATED(29, "not_hover_pack", 0);
    /* no local player: the changed pack record ends the kept layout, the player is located afresh (13) */
    Put32(g.pm + 0x84, 0);
    Put32(g.pm + 0x88, 0);
    CHECK_TICK("waiting_for_player", 11, 0, 0);
    CHECK_GATED(29, "waiting_for_player", 0);
    Put32(g.pm + 0x84, 2);
    Put32(g.pm + 0x88, 2);
    Row(IDLE);
    CHECK_TICK("waiting_for_hover", 34, 0, 0);
    /* the hover pack worn and inactive: its state row on 29 frames, the kept layout on the 30th (16); no focus check */
    CHECK_GATED(29, "waiting_for_hover", 1);
    CHECK_TICK("waiting_for_hover", 15, 0, 0);
    CHECK_GATED(3, "waiting_for_hover", 1);
    /* activation ends the wait in the same frame: the row, then the kept layout (17), and the focus check */
    Row(FLIGHT);
    CHECK_TICK("watching_hover", 16, 1, 0);
    CHECK_TICK("watching_hover", 15, 1, 0);
    /* the press: the kept layout, the pack located afresh (57), then the record created and the duration cut: 63 reads
     * and 4 VirtualQuery (the Lua: 69 reads, 5 queries, 5 WriteProcessMemory) */
    Held(0.01f);
    Frame f = Tick();
    CHECK_STATUS("cancel_requested");
    CHECK_EQ(f.reads, 15 + 34 + 63);
    CHECK_EQ(f.focus, 2);
    CHECK_EQ(f.queries, 4);
    CHECK_EQ(f.logs, 1); /* the session's first cancellation */
    CHECK_TICK("native_descent", 15, 0, 0);
    /* the flight ends: the kept layout and the restoration, 29 reads and 1 VirtualQuery (the Lua: 16 + 31, 1, 1) */
    Row(IDLE);
    Held(0);
    f = Tick();
    CHECK_STATUS("waiting_for_hover");
    CHECK_EQ(f.reads, 15 + 29);
    CHECK_EQ(f.queries, 1);
    CHECK_EQ(f.logs, 1); /* the first restoration */
    /* the next flight's press reuses the record: 43 reads and 1 VirtualQuery (the Lua: 46, 1, 1) */
    Row(FLIGHT);
    CHECK_TICK("watching_hover", 16, 1, 0);
    Held(0.01f);
    f = Tick();
    CHECK_STATUS("cancel_requested");
    CHECK_EQ(f.reads, 15 + 34 + 43);
    CHECK_EQ(f.focus, 2);
    CHECK_EQ(f.queries, 1);
    CHECK_EQ(f.logs, 0);
    Row(IDLE);
    f = Tick();
    CHECK_EQ(f.reads, 15 + 29);
    CHECK_EQ(f.queries, 1);
    CHECK_EQ(f.logs, 0);
    CHECK(Duration(0) == 6.0f);
}

/* ---- the settings (test_settings.lua) ---------------------------------------------------------------------------- */

/* The native lift test, as recovered: the landing assistance overrides an expired duration. */
static int NativeLift(int active, int landing, float airborne, float limit) { return active && (limit > airborne || landing); }

static void CutCreatesTheRecordAndRestoreFollowsIt(void)
{
    MakeGame();
    Started();
    ChpTarget t = Target();
    const char* error = "";
    uint8_t shared[RECORD];
    memcpy(shared, g.resources + 96, RECORD);
    fake_counts_reset();
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    CHECK_EQ(fake_counts().read, 63);
    CHECK_EQ(chp_test_queries, 4);
    CHECK_EQ(fake_counts().write, 0);
    CHECK(chp_lease_held() && chp_settings_created());
    CHECK(memcmp(g.resources + 96, shared, RECORD) == 0); /* the shared settings (other players' packs) unchanged */
    float limit = Duration(0);
    CHECK(limit > 0 && limit < 0.002f);
    CHECK(NativeLift(1, 0, 2, 6.0f));
    CHECK(!NativeLift(1, 0, 2, limit)); /* the press ends the lift */
    CHECK(NativeLift(1, 1, 3, limit));  /* the landing assistance still brakes */
    CHECK(memcmp(g.data, shared, 156) == 0 && memcmp(g.data + 160, shared + 160, RECORD - 160) == 0);
    CHECK_EQ(Get32(g.jm + 152), 1);
    CHECK(Get32(g.forwardRows) == PACK_ID && Get32(g.forwardRows + 4) == 0);
    CHECK(Get32(g.reverseRows) == 0 && Get32(g.reverseRows + 4) == PACK_ID);
    fake_counts_reset();
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK_EQ(fake_counts().read, 29);
    CHECK_EQ(chp_test_queries, 1);
    CHECK(!chp_lease_held() && chp_settings_restorations() == 1);
    CHECK(Duration(0) == 6.0f && memcmp(g.data, shared, RECORD) == 0);
    /* reused without touching its other fields or growing the table */
    PutF(g.data + 40, 1.5f);
    fake_counts_reset();
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    CHECK_EQ(fake_counts().read, 43);
    CHECK_EQ(chp_test_queries, 1);
    CHECK(!chp_settings_created() && Get32(g.jm + 152) == 1);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(Duration(0) == 6.0f && GetF(g.data + 40) == 1.5f);
    /* the engine compacts and moves the records: the restoration follows both maps, never a kept address */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    memcpy(g.data + RECORD, g.data, RECORD);
    memset(g.data, 'x', RECORD);
    Put32(g.forwardRows, PACK_ID);
    Put32(g.forwardRows + 4, 1);
    Put32(g.reverseRows + 16, 1);
    Put32(g.reverseRows + 20, PACK_ID);
    Put32(g.jm + 152, 2);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(Duration(1) == 6.0f && g.data[0] == 'x' && g.data[RECORD - 1] == 'x' && GetF(g.data + 156) != 6.0f);
    /* a later edit by the engine or another mod wins */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    CHECK(Duration(1) == CUTOFF);
    PutF(g.data + RECORD + 156, 8.0f);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(Duration(1) == 8.0f && !chp_lease_held());
    /* a recycled entity id gets no restoration */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    Put32(g.pack + 12, 251);
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(!chp_lease_held() && Duration(1) == CUTOFF && chp_test_queries == 0);
}

/* Every creation destination is checked before the first store: refusing any one leaves the memory untouched. */
static void ARefusedDestinationChangesNothing(void)
{
    for (int refused = 0; refused < 4; refused++)
    {
        fake_setup();
        MakeGame();
        Started();
        uint8_t* pages[4] = {g.data, g.reverseRows, g.jm, g.forwardRows};
        uint8_t before[4][RECORD];
        for (int i = 0; i < 4; i++) memcpy(before[i], pages[i], RECORD);
        ChpTarget t = Target();
        const char* error = "";
        chp_test_queries = 0;
        Protect(pages[refused], RECORD, PAGE_READONLY);
        CHECK_EQ(chp_settings_cancel(&t, &error), -1);
        Protect(pages[refused], RECORD, PAGE_READWRITE);
        CHECK(strcmp(error, "Settings storage is not writable data") == 0);
        CHECK_EQ(chp_test_queries, refused + 1);
        CHECK(!chp_lease_held());
        for (int i = 0; i < 4; i++) CHECK(memcmp(before[i], pages[i], RECORD) == 0);
    }
}

static void RefusalsAndWaitsKeepTheLeaseRight(void)
{
    MakeGame();
    Started();
    ChpTarget t = Target();
    const char* error = "";
    /* the duration's page refused on a reused record: nothing changes, no lease */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    CHECK_EQ(chp_settings_restore(&error), 1);
    Protect(g.data, RECORD, PAGE_READONLY);
    CHECK_EQ(chp_settings_cancel(&t, &error), -1);
    CHECK(strcmp(error, "Could not shorten hover duration") == 0 && !chp_lease_held());
    /* a restoration refused keeps the lease and succeeds later */
    Protect(g.data, RECORD, PAGE_READWRITE);
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    Protect(g.data, RECORD, PAGE_READONLY);
    CHECK_EQ(chp_settings_restore(&error), -1);
    Protect(g.data, RECORD, PAGE_READWRITE);
    CHECK(strcmp(error, "Could not restore hover duration") == 0 && chp_lease_held() && Duration(0) == CUTOFF);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(!chp_lease_held() && Duration(0) == 6.0f);
    /* the settings map unreadable during a mission's teardown: the lease waits, nothing written */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    g_missing = (uintptr_t)g.jm + 96;
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_restore(&error), 0);
    CHECK(strcmp(error, "Hover settings unreadable") == 0 && chp_lease_held() && chp_test_queries == 0);
    g_missing = 0;
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(!chp_lease_held() && Duration(0) == 6.0f);
    /* settings that change between the inspection and its re-read: the lease waits with that reason */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    ChangeRead((uintptr_t)g.jm + 152, 2, 99);
    CHECK_EQ(chp_settings_restore(&error), 0);
    CHECK(strcmp(error, "Hover settings changed") == 0 && chp_lease_held() && Duration(0) == CUTOFF);
    ChangeRead(0, 0, 0);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(Duration(0) == 6.0f);
    /* the old manager gone while the lease waits: abandoned without a store through stale addresses */
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    g_missing = (uintptr_t)g.jm + 96;
    CHECK_EQ(chp_settings_restore(&error), 0);
    Global(CHP_RVA_JUMP_PACKS, fake_heap(0x200));
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(!chp_lease_held() && chp_test_queries == 0 && Duration(0) == CUTOFF);
    g_missing = 0;
    /* a destroyed manager (0): its lease abandoned, nothing dereferenced */
    Global(CHP_RVA_JUMP_PACKS, g.jm);
    PutF(g.data + 156, 6.0f);
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    Global(CHP_RVA_JUMP_PACKS, NULL);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(!chp_lease_held() && Duration(0) == CUTOFF);
}

static void PreflightFailuresOnlyWait(void)
{
    MakeGame();
    Started();
    ChpTarget t = Target();
    const char* error = "";
    /* a read-only preflight that fails between the snapshot and the cut: retried, nothing written */
    g_missing = (uintptr_t)g.jm + 96;
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_cancel(&t, &error), 0);
    CHECK(!chp_lease_held() && chp_test_queries == 0 && Get32(g.jm + 152) == 0);
    g_missing = 0;
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(Duration(0) == 6.0f);
    /* full storage: refused, nothing written */
    fake_setup();
    MakeGame();
    Started();
    t = Target();
    Put32(g.jm + 4, 1);
    Put32(g.jm + 152, 1);
    chp_test_queries = 0;
    CHECK_EQ(chp_settings_cancel(&t, &error), 0);
    CHECK(!chp_lease_held() && chp_test_queries == 0 && Get32(g.jm + 152) == 1);
    /* a duration this cannot cut (0: hold-to-hover) is an error, nothing written */
    fake_setup();
    MakeGame();
    Started();
    t = Target();
    PutF(g.resources + 96 + 156, 0);
    CHECK_EQ(chp_settings_cancel(&t, &error), -1);
    CHECK(strcmp(error, "Unsupported hover duration mode") == 0 && !chp_lease_held() && Get32(g.jm + 152) == 0);
}

/* HellForge gives the jump-pack component table a larger copy when a mod adds entities with records of their own
 * (registry.c): the copy is read through the entity owner's pointer, as the Lua read it. */
static void FollowsAMovedResourceTable(void)
{
    MakeGame();
    Started();
    uint8_t* copy = fake_heap(96 + 4 * RECORD);
    Put64(copy, 0x1234567812345678ull);
    Put32(copy + 8, 0);
    Put64(copy + 3 * 16, HOVER);
    Put32(copy + 3 * 16 + 8, 2);
    memcpy(copy + 96 + 2 * RECORD, g.resources + 96, RECORD);
    PutF(copy + 96 + 2 * RECORD + 156, 4.5f);
    Put64(g.em + 0xF12CB8, (uint64_t)(uintptr_t)copy);
    ChpTarget t = Target();
    const char* error = "";
    CHECK_EQ(chp_settings_cancel(&t, &error), 1);
    CHECK_EQ(chp_settings_restore(&error), 1);
    CHECK(Duration(0) == 4.5f);
}

/* ---- through the tick: a deferred restoration, the stop, an error ---------------------------------------------- */

static void ARestorationWaitsThenTheNextMissionCancels(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0.3f);
    (void)Tick();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK(chp_lease_held());
    /* the mission ends while the settings map cannot be read: the lease waits */
    Mission(0);
    g_missing = (uintptr_t)g.jm + 96;
    /* the mission check, then the inspection up to the unreadable map: 8 reads and the failing one */
    CHECK_TICK("restore_pending", 1 + 9, 0, 0);
    CHECK_TICK("restore_pending", 1 + 9, 0, 0);
    CHECK(chp_lease_held() && Duration(0) == CUTOFF);
    g_missing = 0;
    (void)Tick();
    CHECK_STATUS("waiting_for_mission");
    CHECK(!chp_lease_held() && Duration(0) == 6.0f);
    /* outside a mission the gate answers 59 frames with no read; the next mission is seen at the full check after
     * them, and a Jump held into it does not cancel */
    Mission(2);
    CHECK_GATED(59, "waiting_for_mission", 0);
    (void)Tick();
    CHECK_STATUS("watching_hover");
    CHECK(!chp_lease_held());
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK_STATUS("cancel_requested");
    Row(IDLE);
    (void)Tick();
    CHECK(Duration(0) == 6.0f);
}

static void StopPutsTheDurationBack(void)
{
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK(Duration(0) == CUTOFF);
    vpm_core_stop(fake_component(0), "test");
    CHECK(Duration(0) == 6.0f && !chp_lease_held());
    CHECK_LOG("[Controllable Hover Pack] disabled: test");
    /* a stop that cannot restore says so */
    fake_setup();
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    Protect(g.data, RECORD, PAGE_READONLY);
    vpm_core_stop(fake_component(0), "test");
    Protect(g.data, RECORD, PAGE_READWRITE);
    CHECK_LOG("restore_failed: Could not restore hover duration");
    fake_setup();
    MakeGame();
    Row(FLIGHT);
    Started();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    g_missing = (uintptr_t)g.jm + 96;
    vpm_core_stop(fake_component(0), "test");
    CHECK_LOG("restore_abandoned: Hover settings unreadable");
}

/* What the Lua raised stops the component: here a duration it cannot cut, with nothing written. */
static void AnUnsupportedDurationStopsTheComponent(void)
{
    MakeGame();
    Row(FLIGHT);
    PutF(g.resources + 96 + 156, 0);
    Started();
    Held(0);
    (void)Tick();
    Held(0.01f);
    (void)Tick();
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Controllable Hover Pack] disabled: Unsupported hover duration mode");
    CHECK(Get32(g.jm + 152) == 0 && !chp_lease_held());
}

static void StartsWaitingForAMission(void)
{
    MakeGame();
    Started();
    CHECK_STATUS("waiting_for_mission");
    CHECK_LOG("Controllable Hover Pack v1.8.1: waiting_for_mission");
    CHECK(vpm_ticking(fake_component(0)));
}

/* ---- the idle gate (test_idle_gate.lua) -------------------------------------------------------------------------- */

/* A registry move right before a flight leaves the gate reading the old row: the flight is seen at the next full
 * check, at most 29 frames late. */
static void AFlightAfterARegistryMoveIsSeenWithin29Frames(void)
{
    MakeGame();
    Row(IDLE);
    Started();
    (void)Tick();
    CHECK_STATUS("waiting_for_hover");
    Ticks(5);
    Move(0);
    Row(FLIGHT);
    Held(0.3f);
    int seen = 0;
    for (int i = 1; i <= 30 && seen == 0; i++)
    {
        (void)Tick();
        if (strcmp(Status(), "watching_hover") == 0) seen = i;
    }
    CHECK(seen > 0 && seen <= 29);
}

/* The Lua's generator (an LCG modulo 2^31), from its high bits: its low bits repeat every few calls. */
static uint64_t g_seed;
static uint32_t Random(uint32_t n)
{
    g_seed = (g_seed * 1103515245u + 12345u) % 2147483648u;
    return (uint32_t)(g_seed >> 16) % n;
}

static struct { int frames, cheap, cuts, restorations, stray, wrong; } g_soak;

/* One frame of the soak, with its invariants: VirtualQuery only on a cut or a restoration; the duration 6 s whenever
 * no lease is held. */
static void SoakFrame(void)
{
    int held = chp_lease_held(), restorations = chp_settings_restorations();
    Frame f = Tick();
    g_missing = 0;
    g_soak.frames++;
    g_soak.cheap += f.reads <= 1;
    int cut = !held && chp_lease_held();
    int restored = chp_settings_restorations() > restorations;
    g_soak.cuts += cut;
    g_soak.restorations += restored;
    if (f.queries > 0 && !cut && !restored) g_soak.stray++;
    if (!chp_lease_held() && Get32(g.jm + 152) > 0 && Duration(0) != 6.0f) g_soak.wrong++;
}

static void SoakIdle(int n, int presses)
{
    for (int i = 0; i < n; i++)
    {
        if (presses && Random(8) == 0) Held(Random(2) == 0 ? 0 : 0.02f);
        if (Random(400) == 0) g_missing = (uintptr_t)g.pm + 0x3A8;
        SoakFrame();
    }
    Held(0);
}

static void SoakChange(int which)
{
    switch (which)
    {
    case 0: Mission(0); break;                                     /* back on the ship */
    case 1: Mission(1 + Random(7)); break;                         /* a mission */
    case 2: Put32(g.eqRows + 48 + 12, 0); break;                   /* the backpack dropped */
    case 3: Put32(g.eqRows + 48 + 12, PACK_ID); break;             /* picked up */
    case 4: Entity(g.pack, OTHER_PACK, PACK_ID, g.generation, 1); break; /* another jump pack */
    case 5: Entity(g.pack, HOVER, PACK_ID, g.generation, 1); break;      /* the hover pack */
    case 6: Put32(g.pm + 0x84, 0); Put32(g.pm + 0x88, 0); break;   /* the local player removed */
    case 7: Put32(g.pm + 0x84, 2); Put32(g.pm + 0x88, 2); break;   /* back */
    case 8: g.generation++; Entity(g.pack, HOVER, PACK_ID, g.generation, 1); break; /* a respawn: a new pack */
    case 9: Move(0); break;
    default: Move(1); break;
    }
    SoakIdle(60 + (int)Random(60), 1);
}

static void SoakFly(void)
{
    Row(FLIGHT);
    Held(0.3f);
    int hold = 10 + (int)Random(30), fly = 40 + (int)Random(160);
    for (int i = 0; i < hold; i++) SoakFrame();
    for (int i = 0; i < fly; i++)
    {
        if (Random(4) == 0) Held(GetF(g.input + 8) == 0 && Random(2) == 0 ? 0.02f : 0);
        if (Random(50) == 0) Row(LANDING);
        SoakFrame();
    }
    Row(IDLE);
    Held(0);
}

/* Several thousand frames of the Lua's scripted play (ship and mission, no backpack, another jump pack, flights with
 * presses and the landing assistance, the player removed, respawns, registry moves, one-frame read failures). The Lua
 * compared the gated v1.8.1 with v1.8 frame by frame; here the outcomes are checked directly. */
static void IdleGateSoak(void)
{
    MakeGame();
    Row(IDLE);
    Started();
    memset(&g_soak, 0, sizeof g_soak);
    g_seed = 12345;
    SoakIdle(60, 0);
    for (int round = 0; round < 160; round++)
    {
        uint32_t roll = Random(10);
        if (roll < 3)
        {
            int pair = 2 * (int)Random(4);
            SoakChange(pair);
            if (Random(3) == 0) SoakFly();
            SoakChange(pair + 1);
        }
        else if (roll < 4) SoakChange(8 + (int)Random(3));
        else if (roll < 8)
        {
            SoakFly();
            SoakIdle(1 + (int)Random(40), 1);
        }
        else SoakIdle(30 + (int)Random(90), 1);
    }
    printf("    soak: %d frames, %d with at most one read, %d cuts, %d restorations\n", g_soak.frames, g_soak.cheap,
        g_soak.cuts, g_soak.restorations);
    CHECK(g_soak.frames >= 2000);
    CHECK(g_soak.cuts >= 20);
    CHECK_EQ(g_soak.restorations, g_soak.cuts);
    CHECK(g_soak.cheap > g_soak.frames / 2);
    CHECK_EQ(g_soak.stray, 0);
    CHECK_EQ(g_soak.wrong, 0);
    CHECK(vpm_running(fake_component(0)));
}

int main(void)
{
    RUN(PolicyNeedsAReleaseThenOnePressPerFlight);
    RUN(PolicyReplayCancelsAtTheFirstRepress);
    RUN(SnapshotFindsThePackAtLocalIndexOne);
    RUN(SnapshotChecksHolderResourceStateAndInput);
    RUN(KeptLayoutNoticesWhatMoved);
    RUN(StartsWaitingForAMission);
    RUN(PressCancelsOncePerFlightAndRestoresAfter);
    RUN(FocusAndReadFailuresNeverMakeAPress);
    RUN(ThePressLocatesThePackAfresh);
    RUN(AContextChangeRestores);
    RUN(TransitionsNeverCancelAndRecover);
    RUN(PerFrameBudget);
    RUN(CutCreatesTheRecordAndRestoreFollowsIt);
    RUN(ARefusedDestinationChangesNothing);
    RUN(RefusalsAndWaitsKeepTheLeaseRight);
    RUN(PreflightFailuresOnlyWait);
    RUN(FollowsAMovedResourceTable);
    RUN(ARestorationWaitsThenTheNextMissionCancels);
    RUN(StopPutsTheDurationBack);
    RUN(AnUnsupportedDurationStopsTheComponent);
    RUN(AFlightAfterARegistryMoveIsSeenWithin29Frames);
    RUN(IdleGateSoak);
    TEST_END();
}
