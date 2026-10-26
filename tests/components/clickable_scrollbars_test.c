/* Clickable Scrollbars: the Lua tests' scenarios (components/ClickableScrollbars/tests: test_frame_budget.lua,
 * test_native.lua, test_install.lua, test_settings_input.lua, test_ui_sim.lua's native drags) on the fake game.
 *
 * Each menu is built in the fake heap as test_frame_budget.lua's new_world builds it, with its game.dll globals in the
 * fake image. The five game routines are the reviewed bytes at their RVAs when the component checks them at game load,
 * then jumps into this file's stand-ins, which do what the Lua test's machine-code stubs did (the scroll setter stores
 * its value at bar + 1976, the position setter its vector at +4) and count their calls. user32 is replaced in the core's
 * own table with stand-ins that count their calls. After each tick the world's game update runs (the grid solver
 * derives the visible range and the rendered thumb; Career derives its thumb), as the Lua test's update did. */
#include <stdlib.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/clickable_scrollbars/clickable_scrollbars.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_clickable_scrollbars};

/* game.dll RVAs the component reads or calls */
#define RVA_SOLVER 0x18D2B60u
#define RVA_SCROLL 0x1794530u
#define RVA_POSITION 0x14476A0u
#define RVA_STOP 0x1439D40u
#define RVA_CONSUME 0x12FDE90u
#define RVA_DISPATCH 0x3326E68u
#define RVA_STACK 0x347CE28u
#define RVA_MENU 0x347CE38u
#define RVA_INPUT 0x347CF18u
#define GRID_OFFSET 523752u
#define LOADOUT_OFFSET 864032u
#define PANEL 318472u

enum { GRID, LOADOUT, CAREER, BINDINGS, SETTINGS, ROUTES };
static const char* const kRouteNames[ROUTES] = {"grid", "loadout", "career", "bindings", "settings"};

/* ---- memory helpers ------------------------------------------------------------------------------------------- */

static void P32(uint8_t* base, uint32_t at, uint32_t value) { memcpy(base + at, &value, 4); }
static void PF(uint8_t* base, uint32_t at, float value) { memcpy(base + at, &value, 4); }
static void P64(uint8_t* base, uint32_t at, uint64_t value) { memcpy(base + at, &value, 8); }
static void PPtr(uint8_t* base, uint32_t at, const void* pointer) { P64(base, at, (uint64_t)(uintptr_t)pointer); }
static void PImage(uint32_t rva, const void* pointer) { PPtr((uint8_t*)fake_game(), rva, pointer); }
static float GF(const uint8_t* base, uint32_t at) { float v; memcpy(&v, base + at, 4); return v; }
static double Abs(double v) { return v < 0 ? -v : v; }
static int Near(double a, double b, double tolerance) { return Abs(a - b) <= tolerance; }
static double Floor(double v) { double t = (double)(long long)v; return t > v ? t - 1 : t; }

/* ---- user32 stand-ins ------------------------------------------------------------------------------------------ */

typedef struct Input { int down, focused, x, y, origin_x, origin_y; } Input;
typedef struct Win { int key, cursor, foreground, process, rect, to_client; } Win;
static Input g_in;
static Win g_win;
static int g_window; /* its address is the game window's handle */

static short __stdcall FakeKey(int key) { g_win.key++; return key == VK_LBUTTON && g_in.down ? (short)0x8000 : 0; }
static int __stdcall FakeCursor(void* point)
{
    g_win.cursor++;
    ((POINT*)point)->x = g_in.x;
    ((POINT*)point)->y = g_in.y;
    return 1;
}
static void* __stdcall FakeForeground(void) { g_win.foreground++; return &g_window; }
static unsigned long __stdcall FakeProcess(void* window, unsigned long* process)
{
    g_win.process++;
    *process = g_in.focused ? GetCurrentProcessId() : GetCurrentProcessId() + 1;
    return 1;
}
static int __stdcall FakeRect(void* window, void* rect)
{
    g_win.rect++;
    *(RECT*)rect = (RECT){0, 0, 2560, 1440};
    return 1;
}
static int __stdcall FakeToClient(void* window, void* point)
{
    g_win.to_client++;
    ((POINT*)point)->x -= g_in.origin_x;
    ((POINT*)point)->y -= g_in.origin_y;
    return 1;
}

/* The core's own table (a static it fills at init) gets the stand-ins. */
static void InstallUser32(void)
{
    VpmUser32* u = (VpmUser32*)vpm_user32();
    u->GetAsyncKeyState = FakeKey;
    u->GetCursorPos = FakeCursor;
    u->GetForegroundWindow = FakeForeground;
    u->GetWindowThreadProcessId = FakeProcess;
    u->GetClientRect = FakeRect;
    u->ScreenToClient = FakeToClient;
}

/* ---- game routine stand-ins ------------------------------------------------------------------------------------ */

typedef struct Game { int stop, scroll, position, solve, consume; } Game;
static Game g_game;
static int g_ignore;     /* the setters do nothing */
static int g_frozen;     /* the game's update derives nothing */
static char g_sequence[128];
static uintptr_t g_stopAt, g_positionAt, g_consumeInput, g_scrollBar;
static uint64_t g_positionXY, g_consumeAction;
static float g_consumeHold, g_scrollValue, g_scrollBefore, g_solveScroll;

static void Sequence(const char* step)
{
    size_t n = strlen(g_sequence);
    snprintf(g_sequence + n, sizeof g_sequence - n, "%s%s", n ? "," : "", step);
}
static void FakeStop(void* animation) { g_game.stop++; g_stopAt = (uintptr_t)animation; Sequence("stop"); }
static void FakeScroll(void* bar, float value)
{
    g_game.scroll++;
    g_scrollBar = (uintptr_t)bar;
    g_scrollValue = value;
    g_scrollBefore = GF(bar, 1976);
    Sequence("thumb");
    if (!g_ignore) PF(bar, 1976, value);
}
static void FakePosition(void* widget, uint64_t xy)
{
    g_game.position++;
    g_positionAt = (uintptr_t)widget;
    g_positionXY = xy;
    Sequence("position");
    if (!g_ignore) P64(widget, 4, xy);
}
static void FakeSolve(void* grid) { g_game.solve++; g_solveScroll = GF(grid, 600416); Sequence("layout"); }
static void FakeConsume(void* input, uint64_t action, float hold)
{
    g_game.consume++;
    g_consumeInput = (uintptr_t)input;
    g_consumeAction = action;
    g_consumeHold = hold;
}

/* native.lua's native_signatures, as the Lua wrote them */
typedef struct Stub { uint32_t rva; const char* bytes; uintptr_t target; } Stub;
static Stub g_stubs[5];

static void Stubs(void)
{
    g_stubs[0] = (Stub){RVA_SOLVER, "488bc45355565741544155415641574881ecf800000083b9", (uintptr_t)FakeSolve};
    g_stubs[1] = (Stub){RVA_SCROLL, "0f57d20f2fd1770cf30f10153028c300f30f5dd1f30f1081", (uintptr_t)FakeScroll};
    g_stubs[2] = (Stub){RVA_POSITION, "48895c241848896c24204889542410565741574883ec20f3", (uintptr_t)FakePosition};
    g_stubs[3] = (Stub){RVA_STOP, "40534883ec40488b05c32220014833c448894424300fb601", (uintptr_t)FakeStop};
    g_stubs[4] = (Stub){RVA_CONSUME, "40534883ec204c8bd14c8bca488bcae8dc7c28ff", (uintptr_t)FakeConsume};
}

static void PutHex(uint32_t rva, const char* hex)
{
    uint8_t* at = (uint8_t*)fake_game() + rva;
    for (size_t i = 0; hex[2 * i] != 0; i++)
    {
        char pair[3] = {hex[2 * i], hex[2 * i + 1], 0};
        at[i] = (uint8_t)strtoul(pair, NULL, 16);
    }
}

static void PutSignatures(void)
{
    Stubs();
    for (int i = 0; i < 5; i++) PutHex(g_stubs[i].rva, g_stubs[i].bytes);
}

/* mov rax, target; jmp rax: the routine's address runs this file's stand-in */
static void PutJumps(void)
{
    for (int i = 0; i < 5; i++)
    {
        uint8_t* at = (uint8_t*)fake_game() + g_stubs[i].rva;
        DWORD old;
        VirtualProtect(at, 16, PAGE_EXECUTE_READWRITE, &old); /* lint-ok: C1,C3 the test's own fake game code */
        uint8_t code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
        memcpy(code + 2, &g_stubs[i].target, 8);
        memcpy(at, code, sizeof code);
    }
}

/* ---- the world (test_frame_budget.lua new_world) ---------------------------------------------------------------- */

typedef struct World
{
    int route;
    uint8_t *dispatch, *owner, *menu, *input, *controller, *grid, *panel, *screen, *list;
} World;
static World g_w;

static void Widget(uint8_t* base, uint32_t at, float height, float width, float alpha, float left, float bottom)
{
    PF(base, at + 16, height);
    PF(base, at + 12, width);
    PF(base, at + 84, alpha);
    PF(base, at + 100, 4.0f / 3);
    PF(base, at + 140, 4.0f / 3);
    PF(base, at + 148, left);
    PF(base, at + 156, bottom);
}

static void FillGrid(uint8_t* grid)
{
    P32(grid, 597772, 5);
    P32(grid, 47540, 4);
    P32(grid, 600452, 80);
    P32(grid, 600308, 0);
    P32(grid, 602052, 4);
    PF(grid, 600424, 4018);
    PF(grid, 0x8C0, 3000);
    PF(grid, 0x8C8, 0.5f);
    PF(grid, 600416, 1500);
    Widget(grid, 272, 738, 7, 1, 1528, 138);
    Widget(grid, 888, 134.87964f, 7, 1, 1528, 600);
}

static void Row(int index, uint64_t controller, uint32_t kind)
{
    P64(g_w.dispatch, 5744 + index * 16, controller);
    P32(g_w.dispatch, 5744 + index * 16 + 8, kind);
    P32(g_w.dispatch, 5744 + index * 16 + 12, 0);
}

static void EquipmentWorld(int route)
{
    uint32_t offset = route == LOADOUT ? LOADOUT_OFFSET : GRID_OFFSET;
    g_w.controller = fake_heap(offset + 622700);
    g_w.grid = g_w.controller + offset;
    FillGrid(g_w.grid);
    Row(0, 0x1111111, 12);
    if (route == LOADOUT)
    {
        Row(1, (uint64_t)(uintptr_t)g_w.controller, 229);
        P32(g_w.dispatch, 5740, 2);
        P32(g_w.owner, 0x429C, 14);
        return;
    }
    g_w.panel = g_w.controller + PANEL;
    float career = route == CAREER ? 1.0f : 0.0f;
    Widget(g_w.panel, 195256, 762, 10, career, 1528, 128);
    Widget(g_w.panel, 195808, 439, 10, career, 1528, 434);
    PF(g_w.panel, 2488 + 16, 1315);
    PF(g_w.panel, 2488 + 32, 1);
    PF(g_w.panel, 2488 + 4, 0);
    PF(g_w.panel, 2488 + 8, 320);
    Row(1, (uint64_t)(uintptr_t)g_w.controller, 224);
    Row(2, 0x2222222, 7);
    P32(g_w.dispatch, 5740, 3);
    P32(g_w.owner, 0x429C, 5);
}

static void OptionsWorld(int route)
{
    int settings = route == SETTINGS;
    uint32_t offset = settings ? 4189984u : 338344u;
    g_w.screen = fake_heap(offset + 3000);
    PPtr(g_w.menu, settings ? 200 : 208, g_w.screen);
    g_w.screen[12] = 1;
    g_w.list = g_w.screen + offset;
    Widget(g_w.list, 816, 806, 6, 1, 1668.667f, 117.333f);
    Widget(g_w.list, 1432, 198.3f, 6, 1, 1668.667f, 544.444f);
    PF(g_w.list, 552, 1168);
    PF(g_w.list, 2784, 2470);
    PF(g_w.list, 2792, 0.473f);
    Row(0, 0x1111111, 67);
    P32(g_w.dispatch, 5740, 1);
    P32(g_w.owner, 0x429C, settings ? 1 : 26);
}

static void NewWorld(int route)
{
    memset(&g_w, 0, sizeof g_w);
    g_w.route = route;
    g_w.dispatch = fake_heap(8192);
    g_w.owner = fake_heap(0x4400);
    g_w.menu = fake_heap(512);
    g_w.input = fake_heap(64);
    PImage(RVA_DISPATCH, g_w.dispatch);
    PImage(RVA_STACK, g_w.owner);
    PImage(RVA_MENU, g_w.menu);
    PImage(RVA_INPUT, g_w.input);
    if (route <= CAREER) EquipmentWorld(route);
    else OptionsWorld(route);
    P32(g_w.owner, 0x429C + 20, 1);
}

/* The game's part of each frame. */
static void WorldUpdate(void)
{
    if (g_frozen) return;
    if (g_w.route == GRID || g_w.route == LOADOUT)
    {
        int row = (int)Floor(GF(g_w.grid, 600416) / 200);
        P32(g_w.grid, 622656, (uint32_t)(row * 4));
        P32(g_w.grid, 622660, (uint32_t)(row * 4 + 20));
        P32(g_w.grid, 602096, (uint32_t)row);
        PF(g_w.grid, 888 + 156, 138 + (1 - GF(g_w.grid, 0x8C8)) * 603);
    }
    else if (g_w.route == CAREER)
        PF(g_w.panel, 195808 + 156, 434 + (GF(g_w.panel, 2488 + 8) + 4) * 0.5f);
}

/* Copies a world block to a new allocation and points its global there (test_frame_budget.lua moved_block). */
static uint8_t* MovedBlock(uint8_t* block, size_t size, uint32_t rva)
{
    uint8_t* copy = fake_heap(size);
    memcpy(copy, block, size);
    PImage(rva, copy);
    return copy;
}

/* ---- sessions and frames ---------------------------------------------------------------------------------------- */

typedef struct Calls { FakeCounts hf; Win win; Game game; } Calls;
static struct { int x, thumb_y, track_y; } g_at;
static CsBridge g_bridge; /* the test's own resolutions */

static CsCounts Counts(void)
{
    CsCounts c;
    cs_counts(&c);
    return c;
}

static void ResetCalls(void)
{
    fake_counts_reset();
    memset(&g_win, 0, sizeof g_win);
    memset(&g_game, 0, sizeof g_game);
    g_sequence[0] = 0;
}

static Calls Frame(float dt)
{
    ResetCalls();
    fake_frames(1, dt);
    WorldUpdate();
    return (Calls){fake_counts(), g_win, g_game};
}
static Calls Tick(void) { return Frame(1.0f / 60); }

/* The model of the world's visible owner, through the component's own reader (uncounted). */
static int WorldModel(CsModel* model)
{
    const char* reason = NULL;
    return cs_resolve(&g_bridge, &reason) && cs_state(&g_bridge, model, &reason);
}

static void Positions(void)
{
    CsModel model;
    CsTrack track;
    CHECK(WorldModel(&model));
    cs_screen_track(&model, 0, 0, 1440, &track);
    double thumb_top = track.top + model.value * track.span;
    g_at.x = (int)Floor((track.left + track.right) / 2);
    g_at.thumb_y = (int)Floor(thumb_top + track.thumb / 2);
    g_at.track_y = (int)Floor(track.top + 10);
}

/* A fresh fake, the world, the component started and past game load (the routines checked), the stand-ins in place. */
static void Session(int route)
{
    fake_setup();
    g_ignore = g_frozen = 0;
    NewWorld(route);
    PutSignatures();
    fake_start(kDefs, 1);
    InstallUser32();
    g_in = (Input){0, 1, 200, 600, 0, 0};
    fake_fire(HF_EVENT_GAME_LOADED);
    PutJumps();
    Positions();
    ResetCalls();
}

/* A press on the thumb and 20 moving frames: a verified drag still held (test_frame_budget.lua held_session). */
static void HeldSession(int route)
{
    Session(route);
    g_in.x = g_at.x;
    g_in.y = g_at.thumb_y;
    Tick();
    g_in.down = 1;
    Tick();
    for (int i = 0; i < 20; i++) { g_in.y++; Tick(); }
    CHECK(Counts().verified == 1 && Counts().drag_active);
}

static void Press(int x, int y)
{
    g_in.down = 0;
    Tick();
    g_in.x = x;
    g_in.y = y;
    g_in.down = 1;
    Tick();
}
static void Move(int x, int y) { g_in.x = x; g_in.y = y; Tick(); }
static void Release(void) { g_in.down = 0; Tick(); }

/* ---- budgets (test_frame_budget.lua limits) --------------------------------------------------------------------- */

typedef struct Budget
{
    int key, foreground, process, rect, cursor, to_client, read, stop, scroll, position, solve, consume, log;
} Budget;

static void Pin(const char* label, const char* name, int actual, int expected)
{
    test_checks++;
    if (actual == expected) return;
    test_failures++;
    printf("  FAILED %s: %s %d, expected %d\n", label, name, actual, expected);
}

static void Expect(const char* route, const char* label, Calls c, Budget b)
{
    char at[96];
    snprintf(at, sizeof at, "%s %s", route, label);
    Pin(at, "GetAsyncKeyState", (int)c.win.key, b.key);
    Pin(at, "GetForegroundWindow", c.win.foreground, b.foreground);
    Pin(at, "GetWindowThreadProcessId", c.win.process, b.process);
    Pin(at, "GetClientRect", c.win.rect, b.rect);
    Pin(at, "GetCursorPos", c.win.cursor, b.cursor);
    Pin(at, "ScreenToClient", c.win.to_client, b.to_client);
    Pin(at, "reads", (int)c.hf.read, b.read);
    Pin(at, "stop", c.game.stop, b.stop);
    Pin(at, "scroll setter", c.game.scroll, b.scroll);
    Pin(at, "position setter", c.game.position, b.position);
    Pin(at, "solver", c.game.solve, b.solve);
    Pin(at, "consume", c.game.consume, b.consume);
    Pin(at, "log lines", (int)c.hf.log, b.log);
    Pin(at, "other calls", (int)(c.hf.write + c.hf.find_pattern + c.hf.hook + c.hf.code_matches), 0);
}

/* The owner's reads (locate.c) and the model's (model.c) per route. */
static const int kOwner[ROUTES] = {4, 4, 3, 6, 6};
static const int kModel[ROUTES] = {4, 4, 2, 1, 1};

static Budget Limits(int route, const char* frame)
{
    int settings = route == SETTINGS, options = route >= BINDINGS, grid = route <= LOADOUT;
    Budget every = {1};
    Budget write = {0};
    write.scroll = grid || options;
    write.solve = grid;
    write.position = route == CAREER || options;
    Budget held = every;
    held.foreground = held.process = held.cursor = 1;
    held.read = kOwner[route] + kModel[route];
    held.consume = settings;
    Budget press = held;
    press.rect = press.to_client = 1;
    Budget b = every;
    if (!strcmp(frame, "press thumb")) b = press;
    if (!strcmp(frame, "held still")) b = held;
    if (!strcmp(frame, "held moving") || !strcmp(frame, "held verification") || !strcmp(frame, "press track"))
    {
        b = !strcmp(frame, "press track") ? press : held;
        b.scroll = write.scroll;
        b.solve = write.solve;
        b.position = write.position;
    }
    if (!strcmp(frame, "held verification"))
    {
        b.read += kModel[route];
        b.log = 1; /* the route's first verified drag of the session */
    }
    if (!strcmp(frame, "press track")) b.read += kOwner[route] + kModel[route];
    if (!strcmp(frame, "release")) { b.foreground = b.process = 1; b.consume = settings; }
    return b;
}

static void Expected(int route, const char* label, Calls c) { Expect(kRouteNames[route], label, c, Limits(route, label)); }

/* test_frame_budget.lua's scenario loop: every route, every kind of frame. */
static void PinsEveryFrameOfEveryRoute(void)
{
    for (int route = 0; route < ROUTES; route++)
    {
        Session(route);
        for (int i = 0; i < 3; i++) Tick();
        Expected(route, "idle", Tick());
        g_in.x = g_at.x;
        g_in.y = g_at.thumb_y;
        Tick();
        Expected(route, "hover", Tick());
        g_in.down = 1;
        Expected(route, "press thumb", Tick());
        CHECK(!strcmp(Counts().reason, "bar_press"));
        Expected(route, "held still", Tick());
        g_in.y++;
        Expected(route, "held moving", Tick());
        int verified = 0;
        for (int i = 0; i < 20; i++)
        {
            g_in.y++;
            Calls c = Tick();
            if (!verified && Counts().verified == 1) { verified = 1; Expected(route, "held verification", c); }
        }
        CHECK(verified && !Counts().failed);
        g_in.y++;
        Expected(route, "held moving", Tick());
        Expected(route, "held still", Tick());
        g_in.down = 0;
        Expected(route, "release", Tick());
        Expected(route, "after release", Tick());
        g_in.y = g_at.track_y;
        Tick();
        g_in.down = 1;
        Expected(route, "press track", Tick());
        CHECK(!strcmp(Counts().reason, "native_jump"));
        g_in.down = 0;
        Tick();
        CHECK_EQ(Counts().drags, 2);
        CHECK_EQ(Counts().pages, 1);
        CHECK(vpm_running(fake_component(0)));
    }
}

/* Play and the ship: no screen on the stack, the menu's controller unregistered or its page closed. Fire presses
 * every 7th frame, held two more. An idle frame reads the button and nothing else; a press resolves and stops. */
static void PlayFramesReadTheButtonOnly(void)
{
    for (int route = 0; route < ROUTES; route++)
    {
        Session(route);
        P32(g_w.owner, 0x429C + 20, 0);
        if (route <= CAREER) P32(g_w.dispatch, 5744 + 16 + 8, 7); /* the controller's row */
        else g_w.screen[12] = 0;
        Budget idle = {1};
        Budget press = {1, 1, 1};
        press.read = 3; /* the registry's count and rows, the screen stack */
        for (int index = 1; index <= 120; index++)
        {
            int was = g_in.down;
            g_in.down = index % 7 < 3;
            Calls c = Tick();
            Expect(kRouteNames[route], g_in.down && !was ? "play press" : "play frame", c, g_in.down && !was ? press : idle);
        }
        CHECK_EQ(Counts().clicks, 18);
        CHECK_EQ(Counts().writes, 0);
    }
}

/* ---- the model and the owner (test_native.lua, test_frame_budget.lua reads_world) -------------------------------- */

static void ReadsEachWorld(void)
{
    for (int route = 0; route < ROUTES; route++)
    {
        Session(route);
        WorldUpdate();
        CsModel m;
        CHECK(WorldModel(&m));
        if (route <= LOADOUT)
        {
            CHECK(m.columns == 4 && m.rows == 5 && m.items == 80 && m.kind == 4 && m.selected == 0);
            CHECK(m.has_range && m.first == 28 && m.last == 48 && m.anchor == 7);
            CHECK(m.content == 4018 && m.span == 3000 && m.value == 0.5 && m.scroll == 1500 && m.viewport == 1018);
            CHECK(Near(m.rendered_thumb, 439.5, 1e-3) && m.left == 1528 && m.bottom == 138);
            CHECK(Near(m.width, 7 * 4.0 / 3, 1e-3) && Near(m.length, 738 * 4.0 / 3, 1e-3) && Near(m.thumb, 134.87964 * 4 / 3, 1e-3));
            CHECK(g_bridge.route == CS_ROUTE_GRID && g_bridge.grid == (uintptr_t)g_w.grid);
        }
        else if (route == CAREER)
        {
            CHECK(m.content == 1315 && m.span == 553 && m.viewport == 762 && m.scroll == 324 && m.list_x == 0);
            CHECK(Near(m.value, 324.0 / 553, 1e-9) && m.rendered_thumb == 596 && m.left == 1528 && m.bottom == 128);
            CHECK(Near(m.width, 40.0 / 3, 1e-3) && Near(m.length, 1016, 1e-3) && Near(m.thumb, 439 * 4.0 / 3, 1e-3));
            CHECK(g_bridge.route == CS_ROUTE_CAREER);
        }
        else
        {
            CHECK(Near(m.content, 3276, 1e-3) && m.span == 2470 && m.viewport == 806 && m.scroll == 1168);
            CHECK(Near(m.value, 0.473, 1e-6) && Near(m.rendered_thumb, 544.444, 1e-3) && Near(m.left, 1668.667, 1e-3));
            CHECK(Near(m.width, 8, 1e-3) && Near(m.length, 806 * 4.0 / 3, 1e-3) && Near(m.thumb, 198.3 * 4 / 3, 1e-3));
            CHECK(g_bridge.route == (route == SETTINGS ? CS_ROUTE_SETTINGS : CS_ROUTE_BINDINGS));
            CHECK(g_bridge.bar == (uintptr_t)g_w.list + 816);
        }
    }
}

static int Refused(void)
{
    CsModel m;
    const char* reason = NULL;
    return cs_resolve(&g_bridge, &reason) && !cs_state(&g_bridge, &m, &reason);
}

static void TheGridResolvesAndIsBoundsChecked(void)
{
    Session(GRID);
    const char* reason = NULL;
    static CsBridge again;
    CHECK(cs_resolve(&g_bridge, &reason) && g_bridge.grid == (uintptr_t)g_w.grid);
    CHECK(cs_resolve(&again, &reason) && cs_same_key(&again.key, &g_bridge.key));
    CHECK(cs_unchanged(&g_bridge.tape));
    P32(g_w.grid, 47540, 3);
    CsModel m;
    CHECK(WorldModel(&m) && m.columns == 3); /* three columns with nine-item cache groups is valid */
    static const struct { uint32_t at; int is_float; float value; } kHostile[] = {
        {47540, 0, 0}, {47540, 0, 99}, {597772, 0, 0}, {597772, 0, 99}, {600452, 0, 0}, {600452, 0, 999999},
        {600424, 1, 0}, {0x8C8, 1, 4}, {0x8C0, 1, 0},
    };
    for (size_t i = 0; i < sizeof kHostile / sizeof kHostile[0]; i++)
    {
        Session(GRID);
        if (kHostile[i].is_float) PF(g_w.grid, kHostile[i].at, kHostile[i].value);
        else P32(g_w.grid, kHostile[i].at, (uint32_t)kHostile[i].value);
        CHECK(Refused());
    }
    Session(GRID);
    PF(g_w.grid, 272 + 84, 0);
    CHECK(!cs_resolve(&g_bridge, &reason)); /* a hidden bar cannot capture a press */
    Session(GRID);
    P32(g_w.dispatch, 5744 + 16 + 8, 0);
    CHECK(!cs_resolve(&g_bridge, &reason) && !strcmp(reason, "equipment grid not registered"));
}

/* One bounded registry read, also when full; an absent owner and a hidden one. */
static void TheRegistryIsReadInOneRead(void)
{
    Session(GRID);
    PImage(RVA_STACK, NULL);
    P32(g_w.dispatch, 5740, 64);
    for (int i = 0; i < 64; i++) Row(i, (uint64_t)(uintptr_t)g_w.controller, 7);
    const char* reason = NULL;
    ResetCalls();
    CHECK(!cs_resolve(&g_bridge, &reason));
    CHECK_EQ(fake_counts().read, 2); /* the Lua: 4 (the dispatch and stack pointers through ReadProcessMemory) */
    Row(63, (uint64_t)(uintptr_t)g_w.controller, 224);
    PF(g_w.grid, 272 + 84, 0);
    ResetCalls();
    CHECK(!cs_resolve(&g_bridge, &reason) && !strcmp(reason, "no visible equipment scrollbar"));
    CHECK_EQ(fake_counts().read, 4); /* + the Career and grid bars' alpha (the Lua: 6) */
    fake_hole((uintptr_t)g_w.dispatch + 5744 + 1000, 16);
    CHECK(!cs_resolve(&g_bridge, &reason) && !strcmp(reason, "dispatch rows unreadable"));
}

static void TheLoadoutPickerFollowsTheScreenStack(void)
{
    Session(LOADOUT);
    const char* reason = NULL;
    CHECK(cs_resolve(&g_bridge, &reason) && g_bridge.kind == 229 && g_bridge.grid == (uintptr_t)g_w.grid);
    P32(g_w.owner, 0x429C, 26);
    CHECK(!cs_resolve(&g_bridge, &reason) && !strcmp(reason, "unsupported UI screen"));
    PImage(RVA_STACK, NULL); /* an unreadable stack: the visible bar decides */
    CHECK(cs_resolve(&g_bridge, &reason) && g_bridge.kind == 229);
    PF(g_w.grid, 272 + 84, 0);
    CHECK(!cs_resolve(&g_bridge, &reason) && !strcmp(reason, "no visible equipment scrollbar"));
}

static void TheDragArithmetic(void)
{
    Session(GRID);
    CsModel m;
    CsTrack t;
    double v = 0;
    CHECK(WorldModel(&m));
    cs_screen_track(&m, 0, 0, 1440, &t);
    CHECK(cs_value_at_grab(&m, &t, 500, 500 + t.span / 2, &v) && Near(v, m.value + 0.5, 0.01));
    CHECK(cs_value_at_grab(&m, &t, 500, 5000, &v) && v == 1);
    CHECK(cs_value_at_grab(&m, &t, 500, -5000, &v) && v == 0);
    CsModel moved = m;
    CHECK(!cs_moved(&m, &moved));
    moved.first = 19;
    moved.last = 28;
    CHECK(cs_moved(&m, &moved));
    moved = m;
    moved.value += 0.2;
    moved.scroll += 40; /* the component's own writes are not proof that the game moved */
    CHECK(!cs_moved(&m, &moved));
    moved = m;
    moved.anchor = 21;
    CHECK(cs_moved(&m, &moved));
    Session(CAREER);
    CHECK(WorldModel(&m));
    cs_screen_track(&m, -1920, 100, 1440, &t); /* the UI scale and the window origin */
    CHECK(t.left == -392 && Near(t.top, 1540 - 128 - 762 * 4.0 / 3, 0.001) && Near(t.thumb, 439 * 4.0 / 3, 0.001));
}

/* ---- the writes (test_native.lua apply) ------------------------------------------------------------------------- */

static float VectorY(uint64_t xy) { float f[2]; memcpy(f, &xy, 8); return f[1]; }
static float VectorX(uint64_t xy) { float f[2]; memcpy(f, &xy, 8); return f[0]; }

static void TheGridWriteFollowsTheWheelHandler(void)
{
    Session(GRID);
    CsModel m;
    double written = 0;
    const char* reason = NULL;
    CHECK(WorldModel(&m));
    g_w.grid[600322] = 1; /* a scroll animation runs */
    ResetCalls();
    CHECK(cs_apply(&g_bridge, &m, 0.4, &written, &reason) && written == 0.4);
    CHECK(!strcmp(g_sequence, "stop,thumb,layout"));
    CHECK(g_stopAt == (uintptr_t)g_w.grid + 600320 && g_scrollBar == (uintptr_t)g_w.grid + 272);
    CHECK(g_scrollBefore != g_scrollValue); /* the value was not written first: the setter does its work */
    CHECK(Near(g_solveScroll, 0.4 * m.span, 0.01));
    g_w.grid[600322] = 0;
    ResetCalls();
    CHECK(cs_apply(&g_bridge, &m, 9, &written, &reason) && written == 1 && !strcmp(g_sequence, "thumb,layout"));
    m.span = 0;
    CHECK(!cs_apply(&g_bridge, &m, 0.4, &written, &reason) && !strcmp(reason, "invalid native target"));
}

static void CareerAndTheOptionsListsWriteThroughTheirSetters(void)
{
    Session(CAREER);
    CsModel m;
    double written = 0;
    const char* reason = NULL;
    CHECK(WorldModel(&m) && m.span == 553);
    float ys[3];
    double values[3] = {0, 0.5, 1};
    for (int i = 0; i < 3; i++)
    {
        CHECK(cs_apply(&g_bridge, &m, values[i], &written, &reason));
        CHECK(g_positionAt == (uintptr_t)g_w.panel + 2488 && VectorX(g_positionXY) == 0);
        ys[i] = VectorY(g_positionXY);
    }
    CHECK(ys[0] == -4 && ys[1] == 553.0f / 2 - 4 && ys[2] == 549);
    Session(BINDINGS);
    CHECK(WorldModel(&m));
    ResetCalls();
    CHECK(cs_apply(&g_bridge, &m, 0.75, &written, &reason) && !strcmp(g_sequence, "thumb,position"));
    CHECK(g_scrollBar == (uintptr_t)g_w.list + 816 && g_scrollValue == 0.75f);
    CHECK(g_positionAt == (uintptr_t)g_w.list + 544 && VectorX(g_positionXY) == 0 && VectorY(g_positionXY) == (float)(0.75 * 2470));
    CsModel after = m;
    after.rendered_thumb = 40;
    CHECK(!cs_moved(&m, &after)); /* an options list moves when its content does, not its thumb */
    after.scroll = m.scroll + 5;
    CHECK(cs_moved(&m, &after));
}

static void TheOptionsPagesFollowTheScreenStack(void)
{
    Session(BINDINGS);
    const char* reason = NULL;
    P32(g_w.owner, 0x429C, 25);
    CHECK(!cs_resolve(&g_bridge, &reason));
    P32(g_w.owner, 0x429C, 26);
    PF(g_w.list, 816 + 84, 0);
    CHECK(!cs_resolve(&g_bridge, &reason));
    Session(SETTINGS);
    PF(g_w.list, 1432 + 16, 548.679f);
    PF(g_w.list, 552, 378);
    PF(g_w.list, 2784, 378);
    PF(g_w.list, 2792, 1);
    CsModel m;
    CHECK(WorldModel(&m) && g_bridge.route == CS_ROUTE_SETTINGS && m.span == 378 && m.value == 1);
    ResetCalls();
    CHECK(cs_settings_input() && g_game.consume == 1);
    CHECK(g_consumeInput == (uintptr_t)g_w.input && g_consumeAction == 0xA00000000ull && g_consumeHold == -1.0f);
    CHECK_EQ(fake_counts().read, 0); /* the input owner is a game.dll global: a plain load */
    PImage(RVA_INPUT, NULL);
    CHECK(!cs_settings_input() && g_game.consume == 1);
}

/* ---- the runtime (test_install.lua, test_ui_sim.lua, test_settings_input.lua) ----------------------------------- */

static void StartsAtGameLoad(void)
{
    Session(GRID);
    CHECK_LOG("[Clickable Scrollbars] running: drags the equipment, Career, Controls and Settings scrollbars");
    CHECK(vpm_ticking(fake_component(0)));
    for (int i = 0; i < 5; i++)
    {
        fake_setup();
        NewWorld(GRID);
        PutSignatures();
        ((uint8_t*)fake_game())[g_stubs[i].rva + 3] ^= 0xFF;
        fake_start(kDefs, 1);
        InstallUser32();
        g_in = (Input){1, 1, 200, 600, 0, 0};
        fake_fire(HF_EVENT_GAME_LOADED);
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG("disabled: unsupported native scroll routine");
        ResetCalls();
        fake_frames(10, 1.0f / 60);
        CHECK_EQ(g_win.key, 0);
    }
    fake_setup();
    PutSignatures();
    fake_start(kDefs, 1);
    InstallUser32();
    ((VpmUser32*)vpm_user32())->ScreenToClient = NULL;
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_LOG("disabled: user32.ScreenToClient unavailable");
}

/* Absent, hidden or unsupported owners, and presses outside or unfocused: no write, no log. */
static void InertCasesDoNothing(void)
{
    for (int c = 0; c < 5; c++)
    {
        Session(GRID);
        if (c == 0) PF(g_w.grid, 272 + 84, 0);
        if (c == 1) P32(g_w.grid, 47540, 0);
        if (c == 2) PF(g_w.grid, 888 + 16, 800); /* a thumb as tall as its bar */
        if (c == 3) g_at.x = 100;
        if (c == 4) g_in.focused = 0;
        fake_log_clear();
        for (int i = 0; i < 20; i++) { Press(g_at.x, g_at.thumb_y); Move(g_at.x, g_at.thumb_y + 40); Release(); }
        CHECK_EQ(Counts().writes, 0);
        CHECK(fake_log_text()[0] == 0);
        CHECK(!Counts().dragging);
        CHECK_EQ(Counts().clicks, c == 4 ? 0 : 20); /* an unfocused press is refused before it is counted */
    }
}

static void ThumbDragsFollowThePointer(void)
{
    Session(GRID);
    Press(g_at.x, g_at.thumb_y);
    CHECK_EQ(Counts().writes, 0); /* pressing the thumb does not jump */
    Move(-2000, g_at.thumb_y + 80);
    CsModel m;
    CHECK(WorldModel(&m) && Near(m.value, 0.5 + 80 / (738 * 4.0 / 3 - 134.87964 * 4 / 3), 1e-4)); /* x is ignored */
    int writes = (int)Counts().writes;
    for (int i = 0; i < 40; i++) Tick();
    CHECK_EQ(Counts().writes, writes); /* a still pointer writes nothing */
    CHECK(!Counts().failed);
    Move(4000, -200);
    CHECK(WorldModel(&m) && m.value == 0);
    Move(-2000, 2500);
    CHECK(WorldModel(&m) && m.value == 1);
    Move(3000, g_at.thumb_y);
    CHECK(WorldModel(&m) && m.value == 0.5); /* back at the immutable grab point */
    Release();
    writes = (int)Counts().writes;
    Move(g_at.x, 700);
    CHECK(Counts().writes == (uint32_t)writes && !Counts().drag_active);
    CHECK_LOG("[Clickable Scrollbars] equipment list scrollbar: the game answered the first drag");
}

/* The first verified drag on a route is logged once a session; a running scroll animation is stopped before each
 * grid write. */
static void VerifiedDragsLogOnceAndAnimationsStop(void)
{
    HeldSession(GRID);
    Release();
    CHECK_LOG("equipment list scrollbar: the game answered the first drag");
    fake_log_clear();
    g_w.grid[600322] = 1;
    Press(g_at.x, g_at.thumb_y - 40);
    Calls c = {0};
    for (int i = 0; i < 20; i++)
    {
        g_in.y++;
        c = Tick();
    }
    CHECK(c.game.stop == 1 && c.game.scroll == 1 && c.game.solve == 1 && !strcmp(g_sequence, "stop,thumb,layout"));
    CHECK(g_stopAt == (uintptr_t)g_w.grid + 600320);
    CHECK_EQ(Counts().verified, 2);
    CHECK(fake_log_text()[0] == 0);
}

static void TrackPressesPageAndContinueAsADrag(void)
{
    Session(GRID);
    Press(g_at.x, g_at.track_y - 9);
    CsModel m;
    CHECK(WorldModel(&m) && m.value == 0); /* a click at the track's top reaches the top */
    CHECK_EQ(Counts().pages, 1);
    Move(-2000, g_at.track_y + 250); /* the grab point is the thumb's centre: the drag goes on from there */
    CHECK(WorldModel(&m) && m.value > 0.1);
    g_in.focused = 0;
    int writes = (int)Counts().writes;
    Move(0, 600);
    g_in.focused = 1;
    Move(0, 700);
    CHECK(Counts().writes == (uint32_t)writes && !Counts().drag_active); /* focus loss cancels until a fresh press */
}

/* Above about 64 FPS several updates shared one clock value in the Lua; here a frame with dt 0 is still a frame. */
static void FramesWithoutTimeStillAct(void)
{
    Session(GRID);
    g_in.x = g_at.x;
    g_in.y = g_at.thumb_y;
    Frame(0);
    g_in.down = 1;
    Frame(0);
    CHECK(Counts().clicks == 1 && !strcmp(Counts().reason, "bar_press"));
    g_in.y += 80;
    Frame(0);
    CHECK_EQ(Counts().writes, 1);
}

/* The game ignores the setters and derives nothing: the first write is not answered; the owner retires. */
static void AnUnansweredWriteRetiresTheOwner(void)
{
    Session(GRID);
    g_ignore = g_frozen = 1;
    Press(g_at.x, g_at.thumb_y);
    Move(g_at.x, g_at.thumb_y + 90);
    for (int i = 0; i < 30; i++) Tick();
    CHECK(Counts().failed && Counts().retired == 1 && !Counts().dragging);
    CHECK_LOG("[Clickable Scrollbars] native retired (the game did not answer the write) after 1 writes");
    int writes = (int)Counts().writes;
    Release();
    Press(g_at.x, g_at.thumb_y);
    Move(g_at.x, g_at.thumb_y + 20);
    CHECK_EQ(Counts().writes, writes); /* a retired owner stays retired when rediscovered */
}

static void TheScreenOriginMapsThePointer(void)
{
    Session(GRID);
    g_in.origin_x = -1920;
    g_in.origin_y = 100;
    Press(g_at.x - 1920, g_at.thumb_y + 100);
    CHECK(!strcmp(Counts().reason, "bar_press"));
    Move(g_at.x - 1920, g_at.thumb_y + 140);
    CsModel m;
    CHECK(WorldModel(&m) && Near(m.value, 0.5 + 40 / (738 * 4.0 / 3 - 134.87964 * 4 / 3), 1e-4));
}

/* A held drag cancels before writing when the list is no longer the one grabbed, and goes on when its owner is merely
 * re-resolved (test_frame_budget.lua "held drag re-validation"). */
typedef struct Case { int route; const char* label; int cancel; int change; } Case;
enum
{
    LEAVES, CATEGORY, GROWS, SPAN, KIND, HIDDEN, COLUMNS, REGISTRY_MOVES, FADES, ROUNDING, CAREER_OPENS, ROW_ADDED,
    OTHER_SCREEN, STACK_MOVES, CAREER_CLOSES, CAREER_GROWS, PAGE_CLOSES, LIST_HIDDEN, LIST_GROWS, EQUIPMENT_REGISTERS,
    MENU_MOVES, SETTINGS_ON_TOP
};

static void Change(int change)
{
    switch (change)
    {
    case LEAVES: P32(g_w.dispatch, 5744 + 16 + 8, 7); break;
    case CATEGORY: P32(g_w.grid, 600452, 81); break;
    case GROWS: PF(g_w.grid, 600424, 4019); break;
    case SPAN: PF(g_w.grid, 0x8C0, 2990); break;
    case KIND: P32(g_w.grid, 602052, 5); break;
    case HIDDEN: PF(g_w.grid, 272 + 84, 0); break;
    case COLUMNS: P32(g_w.grid, 47540, 0); break;
    case REGISTRY_MOVES: g_w.dispatch = MovedBlock(g_w.dispatch, 8192, RVA_DISPATCH); break;
    case FADES: PF(g_w.grid, 272 + 84, 0.99f); break;
    case ROUNDING: PF(g_w.grid, 600424, 4018.05f); break;
    case CAREER_OPENS: PF(g_w.panel, 195256 + 84, 1); PF(g_w.panel, 195808 + 84, 1); break;
    case ROW_ADDED: P32(g_w.dispatch, 5740, g_w.route == LOADOUT ? 3 : 4); break;
    case OTHER_SCREEN: P32(g_w.owner, 0x429C, 26); break;
    case STACK_MOVES: g_w.owner = MovedBlock(g_w.owner, 0x4400, RVA_STACK); break;
    case CAREER_CLOSES: PF(g_w.panel, 195256 + 84, 0); PF(g_w.panel, 195808 + 84, 0); break;
    case CAREER_GROWS: PF(g_w.panel, 2488 + 16, 1316); break;
    case PAGE_CLOSES: g_w.screen[12] = 0; break;
    case LIST_HIDDEN: PF(g_w.list, 816 + 84, 0); break;
    case LIST_GROWS: PF(g_w.list, 2784, 2471); break;
    case EQUIPMENT_REGISTERS: P32(g_w.dispatch, 5744 + 8, 229); break;
    case MENU_MOVES: g_w.menu = MovedBlock(g_w.menu, 512, RVA_MENU); break;
    case SETTINGS_ON_TOP: P32(g_w.owner, 0x429C, 1); break;
    default: break;
    }
}

static const Case kGridCases[] = {
    {0, "the controller leaves the registry", 1, LEAVES}, {0, "another category opens", 1, CATEGORY},
    {0, "the content grows", 1, GROWS}, {0, "the span changes", 1, SPAN}, {0, "the layout kind changes", 1, KIND},
    {0, "the scrollbar is hidden", 1, HIDDEN}, {0, "the column count goes out of range", 1, COLUMNS},
    {0, "the registry is reallocated", 0, REGISTRY_MOVES}, {0, "the scrollbar fades but stays visible", 0, FADES},
    {0, "the content moves by a rounding error", 0, ROUNDING},
};
static const Case kCases[] = {
    {GRID, "the Career panel opens over the grid", 1, CAREER_OPENS},
    {GRID, "a registry row is added after the controller", 0, ROW_ADDED},
    {LOADOUT, "another screen goes on top", 1, OTHER_SCREEN},
    {LOADOUT, "the screen stack is reallocated", 0, STACK_MOVES},
    {CAREER, "the Career panel closes", 1, CAREER_CLOSES},
    {CAREER, "the Career list grows", 1, CAREER_GROWS},
    {CAREER, "the controller leaves the registry", 1, LEAVES},
    {CAREER, "the registry is reallocated", 0, REGISTRY_MOVES},
    {BINDINGS, "another screen goes on top", 1, SETTINGS_ON_TOP},
    {BINDINGS, "the page closes", 1, PAGE_CLOSES},
    {BINDINGS, "the scrollbar is hidden", 1, LIST_HIDDEN},
    {BINDINGS, "the list grows", 1, LIST_GROWS},
    {BINDINGS, "an equipment controller registers", 1, EQUIPMENT_REGISTERS},
    {BINDINGS, "the menu is reallocated", 0, MENU_MOVES},
    {SETTINGS, "another screen goes on top", 1, OTHER_SCREEN},
    {SETTINGS, "the page closes", 1, PAGE_CLOSES},
    {SETTINGS, "the menu is reallocated", 0, MENU_MOVES},
};

static void HeldCase(int route, const Case* c)
{
    HeldSession(route);
    Change(c->change);
    uint32_t writes = Counts().writes;
    g_in.y += 3;
    Tick();
    char label[128];
    snprintf(label, sizeof label, "%s: %s", kRouteNames[route], c->label);
    if (c->cancel)
    {
        Pin(label, "writes after the change", (int)Counts().writes, (int)writes);
        Pin(label, "cancelled", !Counts().drag_active && !strcmp(Counts().reason, "native_cancelled"), 1);
        g_in.y += 3;
        Tick();
        Pin(label, "writes after the cancel", (int)Counts().writes, (int)writes);
    }
    else
    {
        Pin(label, "writes after the change", (int)Counts().writes, (int)writes + 1);
        Pin(label, "still held", Counts().drag_active, 1);
        g_in.y += 3;
        Tick();
        Pin(label, "writes after re-resolving", (int)Counts().writes, (int)writes + 2);
    }
    Pin(label, "retired", Counts().failed, 0);
}

static void HeldDragsRevalidate(void)
{
    for (size_t i = 0; i < sizeof kGridCases / sizeof kGridCases[0]; i++)
    {
        HeldCase(GRID, &kGridCases[i]);
        HeldCase(LOADOUT, &kGridCases[i]);
    }
    for (size_t i = 0; i < sizeof kCases / sizeof kCases[0]; i++) HeldCase(kCases[i].route, &kCases[i]);
}

/* A Settings drag consumes the select action every frame until mouse-up, also after the drag ended. */
static void SettingsDragsHoldTheSelection(void)
{
    Session(SETTINGS);
    Press(g_at.x, g_at.thumb_y);
    CHECK(Counts().capture && g_game.consume == 1);
    int consumed = 1;
    for (int i = 0; i < 12; i++) { g_in.y += 5; consumed += Tick().game.consume; }
    CHECK_EQ(consumed, 13);
    CHECK(Counts().writes > 0);
    Release();
    CHECK(g_game.consume == 1 && !Counts().capture);
    CHECK(Tick().game.consume == 0 && Tick().game.consume == 0); /* a released gesture stops consuming */
    Press(100, 700);
    CHECK(g_game.consume == 0 && !Counts().capture); /* an ordinary click elsewhere is the game's */
    Release();

    /* focus loss cancels the drag; the hold stays the component's until mouse-up */
    Session(SETTINGS);
    Press(g_at.x, g_at.thumb_y);
    g_in.focused = 0;
    Calls c = Tick();
    CHECK(c.game.consume == 0 && !Counts().dragging && Counts().capture);
    g_in.focused = 1;
    g_in.x = 100;
    g_in.y = 700;
    c = Tick();
    CHECK(c.game.consume == 1 && Counts().writes == 0);
    Release();
    CHECK(!Counts().capture);

    /* a list change cancels the scrolling, not the hold */
    Session(SETTINGS);
    Press(g_at.x, g_at.thumb_y);
    PF(g_w.list, 2784, 2471);
    g_in.y += 10;
    c = Tick();
    CHECK(c.game.consume == 1 && !Counts().dragging && Counts().capture && Counts().writes == 0);
    CHECK(!strcmp(Counts().reason, "native_cancelled"));
    Release();
    CHECK(!Counts().capture);

    /* without an input owner the Settings route stays inert */
    Session(SETTINGS);
    PImage(RVA_INPUT, NULL);
    Press(g_at.x, g_at.thumb_y);
    Move(g_at.x, g_at.thumb_y + 80);
    CHECK(Counts().writes == 0 && !Counts().capture && !strcmp(Counts().reason, "settings_input_unavailable"));
}

static void OtherRoutesNeverConsume(void)
{
    for (int route = GRID; route <= BINDINGS; route++)
    {
        Session(route);
        int consumed = 0;
        g_in.x = g_at.x;
        g_in.y = g_at.thumb_y;
        Tick();
        g_in.down = 1;
        for (int i = 0; i < 10; i++) { consumed += Tick().game.consume; g_in.y += 2; }
        Release();
        CHECK_EQ(consumed, 0);
        CHECK(Counts().writes > 0);
    }
}

int main(void)
{
    RUN(PinsEveryFrameOfEveryRoute);
    RUN(PlayFramesReadTheButtonOnly);
    RUN(ReadsEachWorld);
    RUN(TheGridResolvesAndIsBoundsChecked);
    RUN(TheRegistryIsReadInOneRead);
    RUN(TheLoadoutPickerFollowsTheScreenStack);
    RUN(TheDragArithmetic);
    RUN(TheGridWriteFollowsTheWheelHandler);
    RUN(CareerAndTheOptionsListsWriteThroughTheirSetters);
    RUN(TheOptionsPagesFollowTheScreenStack);
    RUN(StartsAtGameLoad);
    RUN(InertCasesDoNothing);
    RUN(ThumbDragsFollowThePointer);
    RUN(VerifiedDragsLogOnceAndAnimationsStop);
    RUN(TrackPressesPageAndContinueAsADrag);
    RUN(FramesWithoutTimeStillAct);
    RUN(AnUnansweredWriteRetiresTheOwner);
    RUN(TheScreenOriginMapsThePointer);
    RUN(HeldDragsRevalidate);
    RUN(SettingsDragsHoldTheSelection);
    RUN(OtherRoutesNeverConsume);
    TEST_END();
}
