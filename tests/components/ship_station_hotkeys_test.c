/* Ship Station Hotkeys: the Lua tests' scenarios (components/GalacticMenuHotkey/tests/test_hotkey.lua) on the fake game.
 *
 * The game's station entries are stubs in the fake game.dll (and the world-position function one in the fake exe): each
 * starts with the reviewed bytes the native check compares, completed into instructions that undo themselves, then jumps
 * to a fake here that checks its arguments and changes the fake game as the game would (the presenter opens, the arcade
 * starts, the briefing opens, the avatar is seated). The component calls them exactly as it calls the game: through C
 * function pointers at game.dll + RVA. user32's key and window calls go to fakes put into the core's user32 table, and
 * a stand-in component is the bindings backend (Mod Bindings Menu). The per-frame tests pin every frame's calls, as the
 * Lua's per_frame_calls did with frame_budget.lua. */
#include <stdlib.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"

TEST_GLOBALS;

#define PRESENTER_OFFSET 17032u
#define TAB 0x09
#define F1 0x70
#define F5 0x74
#define F6 0x75
#define F7 0x76
#define F8 0x77
#define MAP 0
#define HELLPOD 5
#define DT (1.0f / 64)

static const uint8_t kKeys[6] = {TAB, F1, F5, F6, F7, F8};
static const char* const kIds[6] = {"cowboybingus.galactic_menu", "cowboybingus.armory", "cowboybingus.control_center",
    "cowboybingus.ship_management", "cowboybingus.stratagem_hero", "cowboybingus.hellpod"};
/* Each shortcut's native action state entry, 97 * group + action (Mod Bindings Menu's fixed slots 1, 3-7). */
static const uint32_t kEntries[6] = {97 * 12 + 1, 97 * 10 + 1, 97 * 10 + 4, 97 * 10 + 8, 97 * 10 + 14, 97 * 10 + 9};

/* ---- the fake game ----------------------------------------------------------------------------------------------- */

static uint8_t* g_ui;
static uint32_t* g_current;  /* the presenter manager's current presenter (+12) */
static uint32_t* g_depth;    /* and its depth (+40) */
static uint8_t* g_mode;
static uint8_t* g_owner;
static uint8_t* g_podSystem;
static uint8_t* g_podManager;
static uint8_t* g_avatarEntity;
static uint8_t* g_seaterRecord;
static uint8_t* g_screenStack;
static uint8_t* g_loadout;
static uint8_t* g_pool;
static uint8_t* g_arcadeSystem;
static float* g_cabinetAt;
static float* g_avatarAt;

static struct { int presenters, arcades, briefings, seats, positions; } g_calls;

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void PutPtr(uint8_t* at, const void* p) { uint64_t v = (uint64_t)(uintptr_t)p; memcpy(at, &v, 8); }
static uint8_t* Heap(size_t size) { return fake_heap(size); }
static uint8_t* Game(uint32_t rva) { return (uint8_t*)fake_game() + rva; }
static void SetPresenter(uint32_t current, uint32_t depth) { *g_current = current; *g_depth = depth; }

static void PodState(uint32_t mode, uint32_t current, uint32_t target)
{
    Put32(g_podManager + 136, mode);
    Put32(g_podManager + 184, current);
    Put32(g_podManager + 264, target);
}

static void Mission(int on)
{
    Put32(g_mode + 8, on ? 1 : 0);
    Put32(g_mode + 0x40, on ? 3 : 0);
}

/* The loadout screen on top of the screen stack, its intro phase and timer. */
static void ShowLoadout(uint32_t phase, float timer)
{
    Put32(g_screenStack, 11);
    Put32(g_loadout + 2570636, phase);
    memcpy(g_loadout + 2570632, &timer, 4);
}

static float IntroTimer(void) { float v; memcpy(&v, g_loadout + 2570632, 4); return v; }

/* The game's entries as the tests see them. */
static void FakeOpenPresenter(void* manager, int32_t presenter, void* data)
{
    g_calls.presenters++;
    CHECK((uint8_t*)manager == g_ui + PRESENTER_OFFSET);
    CHECK(data == NULL);
    SetPresenter((uint32_t)presenter, 1);
}

static void FakeStartArcade(void* system, void* data, uint32_t entity, uint32_t avatar)
{
    g_calls.arcades++;
    CHECK((uint8_t*)system == g_arcadeSystem);
    CHECK(data == NULL);
    CHECK_EQ(entity, 70);
    CHECK_EQ(avatar, 232);
    Put32(g_pool + 5208, avatar);
}

static void FakeOpenBriefing(void* context, uint32_t slot)
{
    g_calls.briefings++;
    CHECK(context == NULL);
    CHECK_EQ(slot, 0);
    SetPresenter(14, 1);
}

static void FakeEnterSeat(void* context, void* entity, void* request)
{
    const uint8_t* bytes = request;
    uint32_t* placement = NULL;
    memcpy(&placement, bytes + 72, sizeof placement);
    g_calls.seats++;
    CHECK(context == NULL);
    CHECK((uint8_t*)entity == g_avatarEntity);
    CHECK_EQ(bytes[0], 1);
    CHECK(placement != NULL && placement[406] == 60 && placement[407] == 0 && placement[408] == 0);
    CHECK_EQ(*g_current, 14); /* behind the open briefing */
    Put32(g_seaterRecord, 60);
}

static uint64_t FakeUnitPosition(uint32_t unit, int32_t index)
{
    g_calls.positions++;
    CHECK_EQ(index, 0);
    if (unit == 1020) return (uint64_t)(uintptr_t)g_cabinetAt;
    if (unit == 2116) return (uint64_t)(uintptr_t)g_avatarAt;
    return 0;
}

/* The entries' reviewed first bytes, each completed into instructions that undo themselves: PresenterManager::open's
 * last byte 8B becomes mov eax, eax, then add rsp, 0x20 and pop rdi; the arcade start's 48 83 becomes add rsp, 0, then
 * three pops; the seat entry's four pushes are popped; the briefing's mov r9, [rip + disp] reads the next instruction,
 * then add rsp, 0x40 and pop rdi; the world-position function's push and sub are undone. A jump to the fake follows. */
static const uint8_t kPresenterStub[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83,
    0xEC, 0x20, 0x8B, 0xC0, 0x48, 0x83, 0xC4, 0x20, 0x5F};
static const uint8_t kArcadeStub[] = {0x48, 0x8B, 0xC4, 0x48, 0x89, 0x50, 0x10, 0x48, 0x89, 0x48, 0x08, 0x53, 0x55, 0x57,
    0x48, 0x83, 0xC4, 0x00, 0x5F, 0x5D, 0x5B};
static const uint8_t kSeatStub[] = {0x48, 0x89, 0x5C, 0x24, 0x20, 0x48, 0x89, 0x54, 0x24, 0x10, 0x56, 0x57, 0x41, 0x54,
    0x41, 0x55, 0x41, 0x5D, 0x41, 0x5C, 0x5F, 0x5E};
static const uint8_t kBriefingStub[] = {0x48, 0x89, 0x4C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x40, 0x4C, 0x8B, 0x0D,
    0x00, 0x00, 0x00, 0x00, 0x48, 0x83, 0xC4, 0x40, 0x5F};
static const uint8_t kPositionStub[] = {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x83, 0xC4, 0x20, 0x5B};

static void Stub(uint8_t* at, const uint8_t* code, size_t size, uintptr_t target)
{
    DWORD old;
    if (!VirtualProtect(at, size + 12, PAGE_EXECUTE_READWRITE, &old)) /* lint-ok: C3 the test makes its fake entries executable */
    {
        printf("the fake entries cannot be made executable\n");
        exit(2);
    }
    memcpy(at, code, size);
    at[size] = 0x48; /* mov rax, target; jmp rax */
    at[size + 1] = 0xB8;
    uint64_t address = target;
    memcpy(at + size + 2, &address, 8);
    at[size + 10] = 0xFF;
    at[size + 11] = 0xE0;
}

static void MakeEntries(void)
{
    uint8_t* position = (uint8_t*)fake_exe() + 0x100000;
    uint8_t* unit_interface = Heap(32);
    uint8_t* table = Heap(144);
    Stub(Game(0x14C0350), kPresenterStub, sizeof kPresenterStub, (uintptr_t)FakeOpenPresenter);
    Stub(Game(0x997800), kArcadeStub, sizeof kArcadeStub, (uintptr_t)FakeStartArcade);
    Stub(Game(0x639830), kSeatStub, sizeof kSeatStub, (uintptr_t)FakeEnterSeat);
    Stub(Game(0x661CF0), kBriefingStub, sizeof kBriefingStub, (uintptr_t)FakeOpenBriefing);
    Stub(position, kPositionStub, sizeof kPositionStub, (uintptr_t)FakeUnitPosition);
    PutPtr(Game(0x3326308), unit_interface);
    PutPtr(unit_interface + 24, table);
    PutPtr(table + 136, position);
}

/* The live solo ship's Hellpod layout: deployment slot 0 holds pod 60, Hellpod index 0; the avatar 232 is the only
 * seater; the loadout screen object at the screen stack's +176. */
static void MakeHellpod(void)
{
    uint8_t* pod = Heap(24);
    uint8_t* seaters = Heap(80);
    uint8_t* buckets = Heap(64);
    uint8_t* entities = Heap(8);
    g_podSystem = Heap(72988);
    g_podManager = Heap(280);
    g_avatarEntity = Heap(24);
    g_seaterRecord = Heap(64);
    g_screenStack = Heap(184);
    g_loadout = Heap(2570640);
    PutPtr(Game(0x33265F0), g_podSystem);
    PutPtr(Game(0x3326428), g_podManager);
    Put32(g_podSystem + 32, 1);
    Put32(g_podSystem + 36, 1);
    Put32(g_podSystem + 72984, 60);
    Put32(g_podManager + 8, 1);
    PutPtr(g_podManager + 104, pod);
    Put32(pod + 8, 60);
    pod[20] = 1;
    PodState(2, 3, 3);
    PutPtr(Game(0x3326D78), seaters);
    Put32(seaters + 12, 1);
    PutPtr(seaters + 32, buckets);
    Put32(seaters + 40, 8);
    Put32(seaters + 48, 1);
    Put32(buckets, 232);
    PutPtr(entities, g_avatarEntity);
    PutPtr(seaters + 56, entities);
    PutPtr(seaters + 72, g_seaterRecord);
    Put32(g_avatarEntity + 8, 232);
    PutPtr(Game(0x347CE38), g_screenStack);
    PutPtr(g_screenStack + 176, g_loadout);
}

/* The cabinet, entity and local-avatar layout observed on the live ship: the local player's unit 154 is entity record 0
 * (avatar 232, unit 2116), the cabinet entity 70 is record 1 (unit 1020); the arcade system is row 0, type 67. */
static void MakeAvatarAndArcade(void)
{
    uint8_t* players = Heap(0x430);
    uint8_t* player = Heap(24);
    uint8_t* entities = Heap(0xF32F18 + 48);
    uint8_t* map = Heap(64);
    uint8_t* arcade = Heap(96);
    uint8_t* arcade_buckets = Heap(1024);
    uint8_t* systems = Heap(19536);
    static const uint8_t kAvatarType[8] = {0x97, 0xFA, 0x4D, 0x29, 0x4D, 0x33, 0x1C, 0x4D};
    PutPtr(Game(0x3326468), players);
    Put32(players + 0x84, 1);
    Put32(players + 0x88, 1);
    PutPtr(players + 0xE8, player);
    player[20] = 1;
    Put32(players + 0x3A8, 154);
    PutPtr(Game(0x346BF98), entities);
    PutPtr(entities + 0xF22EC8, map);
    Put32(entities + 0xF22EC8 + 8, 8);
    Put32(entities + 0xF22EC8 + 16, 1);
    Put32(map + 2 * 8, 154);
    Put32(map + 6 * 8, 70);
    Put32(map + 6 * 8 + 4, 1);
    memcpy(entities + 0xF32F18, kAvatarType, 8);
    Put32(entities + 0xF32F18 + 8, 232);
    Put32(entities + 0xF32F18 + 12, 2116);
    entities[0xF32F18 + 20] = 1;
    Put32(entities + 0xF32F18 + 24 + 8, 118);
    Put32(entities + 0xF32F18 + 24 + 12, 1020);
    entities[0xF32F18 + 24 + 20] = 1;
    g_pool = Heap(5232);
    g_arcadeSystem = Heap(8);
    PutPtr(Game(0x3326700), arcade);
    Put32(arcade + 24, 1);
    PutPtr(arcade + 48, arcade_buckets);
    Put32(arcade + 56, 128);
    PutPtr(arcade + 88, g_pool);
    Put32(arcade_buckets + 12 * 8, 70);
    Put32(g_pool + 5212, 232); /* the last player stays here; +5208 is the guard */
    PutPtr(Game(0x3326E68), systems);
    Put32(systems + 19512, 1);
    PutPtr(systems + 19520, g_arcadeSystem);
    Put32(systems + 19528, 67);
    g_cabinetAt = (float*)Heap(12);
    g_avatarAt = (float*)Heap(12);
    g_avatarAt[0] = 1; /* one unit from the cabinet */
}

/* ---- user32 and the bindings backend ----------------------------------------------------------------------------- */

static uint8_t g_keys[256];
static char g_gameWindow, g_otherWindow;
static void* g_window;
static struct { long key, foreground, process; } g_user32;

static short __stdcall FakeKeyState(int key) { g_user32.key++; return g_keys[key & 0xFF] ? (short)-32768 : 0; }
static void* __stdcall FakeForeground(void) { g_user32.foreground++; return g_window; }
static unsigned long __stdcall FakeWindowProcess(void* window, unsigned long* process)
{
    g_user32.process++;
    *process = window == &g_gameWindow ? GetCurrentProcessId() : GetCurrentProcessId() + 1;
    return 1;
}

/* The harness has no user32 of its own: the core's table (found at init) gets the fakes. */
static void UseFakeUser32(void)
{
    VpmUser32* user32 = (VpmUser32*)vpm_user32();
    user32->GetAsyncKeyState = FakeKeyState;
    user32->GetForegroundWindow = FakeForeground;
    user32->GetWindowThreadProcessId = FakeWindowProcess;
}

/* Mod Bindings Menu's stand-in: each binding answers -1 (no binding saved), 0 or 1; nothing while not ready. */
static int g_ready;
static int g_answers[6];
static long g_downCalls;

static void* BackendAttach(VpmBinding* binding)
{
    for (int i = 0; i < 6; i++)
        if (strcmp(vpm_binding_def(binding)->id, kIds[i]) == 0) return &g_answers[i];
    return NULL;
}

static int BackendDown(const VpmBinding* binding, void* data)
{
    g_downCalls++;
    return g_ready && data != NULL ? *(const int*)data : -1;
}

static const VpmBindingBackend kBackend = {BackendAttach, BackendDown};
static int BackendStart(VpmComponent* self) { vpm_bindings_set_backend(self, &kBackend); return 0; }
static const VpmComponentDef kBackendDef = {"fake_bindings", "Fake Bindings", "1", 0, BackendStart, NULL};

/* Another component holding 59 of the pack's 64 bindings, so the last of the six is refused. */
static VpmBindingDef g_fillers[59];
static char g_fillerIds[59][8];
static int FillerStart(VpmComponent* self)
{
    for (int i = 0; i < 59; i++)
    {
        snprintf(g_fillerIds[i], sizeof g_fillerIds[i], "f%02d", i);
        g_fillers[i] = (VpmBindingDef){g_fillerIds[i], "FILLER", NULL, 0, 0};
        if (vpm_binding(self, &g_fillers[i]) == NULL) return 1;
    }
    return 0;
}
static const VpmComponentDef kFillerDef = {"filler", "Filler", "1", 0, FillerStart, NULL};

/* ---- set-up and frames ------------------------------------------------------------------------------------------- */

static VpmComponent* g_ssh;

static void MakeGame(void)
{
    memset(&g_calls, 0, sizeof g_calls);
    memset(g_keys, 0, sizeof g_keys);
    memset(g_answers, 0, sizeof g_answers);
    g_ready = 1;
    g_window = &g_gameWindow;
    g_ui = Heap(PRESENTER_OFFSET + 64);
    g_current = (uint32_t*)(g_ui + PRESENTER_OFFSET + 12);
    g_depth = (uint32_t*)(g_ui + PRESENTER_OFFSET + 40);
    PutPtr(Game(0x347CE28), g_ui);
    g_mode = Heap(72);
    PutPtr(Game(0x33266A0), g_mode);
    g_owner = Heap(808 + 32 * 97 * 13);
    PutPtr(Game(0x347CF18), g_owner);
    MakeEntries();
    MakeHellpod();
    MakeAvatarAndArcade();
}

/* The component, after the stand-in backend (and the filler) when asked for. */
static void Started(int backend, int filler)
{
    const VpmComponentDef* defs[3];
    int count = 0;
    if (backend) defs[count++] = &kBackendDef;
    if (filler) defs[count++] = &kFillerDef;
    defs[count++] = &vpm_component_ship_station_hotkeys;
    fake_start(defs, count);
    UseFakeUser32();
    g_ssh = fake_component(count - 1);
}

static void Frame(float dt) { fake_frames(1, dt); }

/* The ship's state, then its first frame: the arrival (the first frame is a check). */
static void Aboard(int backend)
{
    MakeGame();
    Started(backend, 0);
    fake_set_state(HF_STATE_SHIP);
    Frame(DT);
}

/* A fixed key pressed for one frame, then released for one. */
static void Tap(uint8_t key, float dt)
{
    g_keys[key] = 1;
    Frame(dt);
    g_keys[key] = 0;
    Frame(dt);
}

/* A binding down or up, in the backend's answers and in the game's action state byte. */
static void Press(int index, int down)
{
    g_answers[index] = down;
    g_owner[808 + 32 * kEntries[index]] = (uint8_t)down;
}

typedef struct Calls { long read, code, key, foreground, process, down, presenters, log; } Calls;

static Calls Measure(int frames, float dt)
{
    int presenters = g_calls.presenters;
    fake_counts_reset();
    memset(&g_user32, 0, sizeof g_user32);
    g_downCalls = 0;
    fake_frames(frames, dt);
    FakeCounts c = fake_counts();
    return (Calls){c.read, c.code_matches, g_user32.key, g_user32.foreground, g_user32.process, g_downCalls,
        g_calls.presenters - presenters, c.log};
}

static void Expect(const char* label, int frame, Calls got, Calls want)
{
    test_checks++;
    if (memcmp(&got, &want, sizeof got) == 0) return;
    test_failures++;
    printf("  FAILED %s, frame %d: read %ld code %ld key %ld foreground %ld process %ld down %ld presenters %ld log %ld;"
           " expected %ld %ld %ld %ld %ld %ld %ld %ld\n", label, frame, got.read, got.code, got.key, got.foreground,
        got.process, got.down, got.presenters, got.log, want.read, want.code, want.key, want.foreground, want.process,
        want.down, want.presenters, want.log);
}

/* frames frames, each making exactly the calls want. */
static void Frames(const char* label, int frames, Calls want)
{
    for (int i = 0; i < frames; i++) Expect(label, i + 1, Measure(1, DT), want);
}

/* ---- registration and the binding answers ------------------------------------------------------------------------ */

static void RegistersTheSixBindings(void)
{
    static const char* const labels[6] = {"GALACTIC MAP", "ARMORY", "CONTROL CENTER", "SHIP MANAGEMENT", "STRATAGEM HERO",
        "HELLPOD DEPLOYMENT"};
    static const uint32_t slots[6] = {1, 3, 4, 5, 6, 7};
    MakeGame();
    Started(0, 0);
    CHECK(vpm_running(g_ssh));
    CHECK(vpm_ticking(g_ssh));
    CHECK_EQ(vpm_binding_count(), 6);
    for (int i = 0; i < 6 && i < vpm_binding_count(); i++)
    {
        const VpmBindingDef* def = vpm_binding_def(vpm_binding_at(i));
        CHECK(strcmp(def->id, kIds[i]) == 0);
        CHECK(strcmp(def->label, labels[i]) == 0);
        CHECK(def->category != NULL && strcmp(def->category, "Ship Station Hotkeys") == 0);
        CHECK_EQ(def->slot, slots[i]);
        CHECK_EQ(def->key, kKeys[i]);
    }
    CHECK_LOG("[Ship Station Hotkeys] Ship menu hotkeys initialized (Tab, F1, F5-F8).");
    Frame(DT);
    Frame(DT);
    CHECK_LOG("Update callback is running.");
}

/* Without a backend the fixed key answers: Tab opens the Galactic Map. */
static void FixedKeysWithoutBindings(void)
{
    Aboard(0);
    CHECK_LOG("Super Destroyer detected.");
    CHECK_LOG("Native ship menu presenters ready for current game build.");
    Tap(TAB, DT);
    CHECK_EQ(g_calls.presenters, 1);
    CHECK_EQ(*g_current, 15);
    CHECK_LOG("Galactic Map shortcut detected; entering native presenter 15.");
    CHECK_LOG("Galactic Map presenter call returned; current=15.");
}

/* A binding's answer stands for its key: an unpressed binding suppresses Tab, a pressed one acts, and one without a
 * saved binding (-1) or a backend not ready yet leaves Tab in use. No input owner here: the gate stays off. */
static void BindingsAnswerFirst(void)
{
    MakeGame();
    PutPtr(Game(0x347CF18), NULL);
    Started(1, 0);
    fake_set_state(HF_STATE_SHIP);
    Frame(DT);
    g_keys[TAB] = 1;
    Frame(DT);
    CHECK_EQ(g_calls.presenters, 0);
    g_answers[MAP] = 1;
    Frame(DT);
    CHECK_EQ(g_calls.presenters, 1);
    SetPresenter(0, 0);
    g_answers[MAP] = 0;
    Frame(DT);
    g_answers[MAP] = -1;
    Frame(DT);
    CHECK_EQ(g_calls.presenters, 2);
    SetPresenter(0, 0);
    g_keys[TAB] = 0;
    Frame(DT);
    g_ready = 0;
    g_keys[TAB] = 1;
    Frame(DT);
    CHECK_EQ(g_calls.presenters, 3);
}

/* A binding the registry refuses keeps its fixed key, and the gate stays off: every focused frame aboard asks the five
 * bindings and reads the sixth's key. */
static void RefusedBindingKeepsItsKey(void)
{
    MakeGame();
    Started(1, 1);
    CHECK_LOG("binding ship_station_hotkeys.cowboybingus.hellpod refused: the pack holds 64");
    CHECK_LOG("Mod binding registration failed for Hellpod Deployment; its fixed key stays in use for this session.");
    fake_set_state(HF_STATE_SHIP);
    Frame(DT);
    Frames("refused binding, idle aboard", 3, (Calls){.key = 1, .down = 5});
    PodState(0, 0, 0);
    Tap(F8, DT);
    CHECK_LOG("Hellpod shortcut detected; select a mission first.");
}

/* ---- the presenters ---------------------------------------------------------------------------------------------- */

/* Each presenter opens only while none is open; an open one is not reopened, a busy stack not interrupted. */
static void PresentersOpenOnlyWhenIdle(void)
{
    static const uint8_t menus[3] = {F1, F5, F6};
    static const uint32_t presenters[3] = {5, 6, 8};
    Aboard(0);
    Tap(TAB, DT);
    CHECK_EQ(*g_current, 15);
    Tap(TAB, DT);
    CHECK_LOG("Galactic Map shortcut detected; presenter already open.");
    SetPresenter(2, 1);
    Tap(F1, DT);
    CHECK_LOG("Armory shortcut detected; presenter is busy (2, depth 1).");
    SetPresenter(1, 1);
    Tap(F6, DT);
    CHECK_LOG("Ship Management shortcut detected; presenter is busy (1, depth 1).");
    SetPresenter(0, 1);
    Tap(F5, DT);
    CHECK_LOG("Control Center shortcut detected; presenter is busy (0, depth 1).");
    CHECK_EQ(g_calls.presenters, 1);
    for (int i = 0; i < 3; i++)
    {
        SetPresenter(0, 0);
        Tap(menus[i], DT);
        CHECK_EQ(*g_current, presenters[i]);
    }
    CHECK_EQ(g_calls.presenters, 4);
    CHECK_LOG("Control Center shortcut detected; entering native presenter 6.");
    PutPtr(Game(0x347CE28), NULL);
    Tap(TAB, DT);
    CHECK_LOG("Galactic Map shortcut detected, but UI state is unavailable.");
    CHECK_EQ(g_calls.presenters, 4);
}

/* ---- the Hellpod ------------------------------------------------------------------------------------------------- */

static void ResetShip(void)
{
    SetPresenter(0, 0);
    Put32(g_seaterRecord, 0);
    Put32(g_screenStack, 0);
    PodState(2, 3, 3);
}

/* F8 refuses without a mission, with the pod occupied, in a shared session and over another presenter. */
static void HellpodRefusals(void)
{
    Aboard(0);
    PodState(0, 0, 0);
    Tap(F8, DT);
    CHECK_LOG("Hellpod shortcut detected; select a mission first.");
    PodState(2, 4, 4);
    Tap(F8, DT);
    CHECK_LOG("Hellpod shortcut detected; the Hellpod is already occupied.");
    Put32(g_podSystem + 32, 2);
    PodState(2, 3, 3);
    Tap(F8, DT);
    CHECK_LOG("Hellpod shortcut detected; only solo ship sessions are supported.");
    Put32(g_podSystem + 32, 1);
    SetPresenter(5, 1);
    Tap(F8, DT);
    CHECK_LOG("Hellpod Deployment shortcut detected; presenter is busy (5, depth 1).");
    CHECK_EQ(g_calls.briefings, 0);
    CHECK_EQ(g_calls.seats, 0);
}

/* The briefing opens first; the seat waits for the intro, expires its timer, then seats on the frame the briefing UI is
 * up. A seated or moving avatar refuses. */
static void HellpodSeatsBehindTheBriefing(void)
{
    Aboard(0);
    g_keys[F8] = 1;
    Expect("F8 pressed, pod open", 1, Measure(1, 0.1f), (Calls){.read = 16, .key = 6, .foreground = 1, .process = 1, .log = 1});
    g_keys[F8] = 0;
    Frame(0.1f);
    CHECK_EQ(g_calls.briefings, 1);
    CHECK_EQ(g_calls.seats, 0);
    CHECK_LOG("Hellpod shortcut detected; opening the briefing.");
    ShowLoadout(0, -1);
    Frame(0.1f);
    CHECK_EQ(g_calls.seats, 0); /* a finished intro seen before the skip does not seat */
    ShowLoadout(1, 2);
    Frame(0.1f);
    CHECK_EQ(g_calls.seats, 0);
    CHECK(IntroTimer() == 0.0f);
    CHECK_LOG("Briefing intro skipped.");
    Expect("the seat waiting for the briefing UI", 1, Measure(1, 0.1f), (Calls){.read = 4, .key = 6, .foreground = 1, .process = 1});
    CHECK_EQ(g_calls.seats, 0);
    ShowLoadout(0, -1);
    Expect("the seat frame", 1, Measure(1, 0.1f), (Calls){.read = 20, .key = 6, .foreground = 1, .process = 1, .log = 1});
    CHECK_EQ(g_calls.seats, 1);
    CHECK_LOG("Native Hellpod seat returned behind the briefing; seat=60, presenter=14.");
    Put32(g_screenStack, 0);
    SetPresenter(0, 0);
    Tap(F8, DT);
    CHECK_LOG("Hellpod shortcut detected; your character is already seated or moving.");
    Put32(g_seaterRecord, 0);
    g_seaterRecord[48] = 1;
    Tap(F8, DT);
    CHECK_EQ(g_calls.briefings, 1);
    g_seaterRecord[48] = 0;
}

/* Closing the briefing cancels the pending seat; a pod no longer open skips it after the fallback delay. */
static void HellpodSeatCancels(void)
{
    Aboard(0);
    Tap(F8, DT);
    SetPresenter(0, 0);
    Frame(DT);
    CHECK_LOG("Hellpod seat cancelled; the briefing closed before seating.");
    Tap(F8, DT);
    CHECK_EQ(g_calls.briefings, 2);
    PodState(0, 0, 0);
    fake_frames(3, 1.0f);
    CHECK_LOG("Briefing intro was not observed; seating after the fallback delay.");
    CHECK_LOG("Hellpod seat skipped; the Hellpod is no longer open.");
    CHECK_EQ(g_calls.seats, 0);
}

/* F8 during the pod's ready animation waits for it to open (then enters, seating after the fallback delay); the wait
 * ends after 10 s, when a menu opens, or when the mission is no longer selected. */
static void HellpodWaitsForThePod(void)
{
    Aboard(0);
    PodState(2, 1, 1);
    g_keys[F8] = 1;
    Expect("F8 pressed, pod not open", 1, Measure(1, DT), (Calls){.read = 5, .key = 6, .foreground = 1, .process = 1, .log = 1});
    g_keys[F8] = 0;
    CHECK_LOG("Hellpod shortcut detected; entering when the Hellpod opens.");
    Expect("Hellpod wait", 1, Measure(1, 4.0f), (Calls){.read = 5, .key = 6, .foreground = 1, .process = 1});
    CHECK_EQ(g_calls.briefings, 0);
    PodState(2, 3, 3);
    Frame(0.5f);
    CHECK_EQ(g_calls.briefings, 1);
    Frame(2.0f);
    CHECK_EQ(g_calls.seats, 0);
    Frame(1.0f);
    CHECK_EQ(g_calls.seats, 1);
    ResetShip();
    PodState(2, 1, 1);
    Tap(F8, 11.0f);
    CHECK_LOG("Hellpod shortcut cancelled; the Hellpod did not open in time.");
    Tap(F8, DT);
    SetPresenter(15, 1);
    Frame(DT);
    CHECK_LOG("Hellpod shortcut cancelled; another menu opened.");
    SetPresenter(0, 0);
    Tap(F8, DT);
    PodState(0, 0, 0);
    Frame(DT);
    CHECK_LOG("Hellpod shortcut cancelled; the mission is no longer selected.");
    CHECK_EQ(g_calls.briefings, 1);
}

/* ---- Stratagem Hero ---------------------------------------------------------------------------------------------- */

/* F7 starts the arcade only with no presenter open, beside the idle cabinet. */
static void StratagemHeroBesideTheCabinet(void)
{
    Aboard(0);
    SetPresenter(2, 1);
    Tap(F7, DT);
    CHECK_LOG("Stratagem Hero shortcut detected; presenter is busy (2, depth 1).");
    SetPresenter(0, 0);
    g_avatarAt[0] = 10;
    Tap(F7, DT);
    CHECK_LOG("Stratagem Hero distance squared: 100.00");
    CHECK_LOG("Stratagem Hero shortcut detected; move beside the cabinet first.");
    CHECK_EQ(g_calls.arcades, 0);
    g_avatarAt[0] = 1;
    g_keys[F7] = 1;
    Expect("F7 beside the cabinet", 1, Measure(1, DT), (Calls){.read = 17, .key = 6, .foreground = 1, .process = 1, .log = 3});
    g_keys[F7] = 0;
    Frame(DT);
    CHECK_EQ(g_calls.arcades, 1);
    CHECK_LOG("Stratagem Hero shortcut detected; starting native arcade interaction.");
    CHECK_LOG("Native arcade start returned; active avatar=232.");
    Tap(F7, DT); /* the cabinet is in use now (+5208) */
    CHECK_LOG("Stratagem Hero shortcut detected; arcade or local avatar is unavailable.");
    CHECK_EQ(g_calls.arcades, 1);
}

/* Without the world-position function the distance check fails closed. */
static void ArcadeWithoutPositionFunction(void)
{
    MakeGame();
    ((uint8_t*)fake_exe() + 0x100000)[0] = 0x90;
    Started(0, 0);
    fake_set_state(HF_STATE_SHIP);
    Frame(DT);
    CHECK_LOG("Arcade proximity check unavailable: world-position function changed.");
    CHECK_LOG("Native ship menu presenters ready for current game build.");
    Tap(F7, DT);
    CHECK_LOG("Stratagem Hero shortcut detected; move beside the cabinet first.");
    CHECK_EQ(g_calls.arcades, 0);
    CHECK_EQ(g_calls.positions, 0);
}

/* ---- the native check -------------------------------------------------------------------------------------------- */

/* Entries not as reviewed, or no UI state: the component stops on the frame the ship is first found, with the Lua's
 * reason. That frame ends there (no focus or key call though Tab is held, no action), and nothing runs afterwards. */
static void RefusesEntriesNotAsReviewed(void)
{
    static const char* const reasons[5] = {"native presenter changed in memory", "native arcade start changed in memory",
        "native instant seat entry changed in memory", "native Hellpod briefing entry changed in memory", "UI state unavailable"};
    static const uint32_t entries[4] = {0x14C0350, 0x997800, 0x639830, 0x661CF0};
    for (int c = 0; c < 5; c++)
    {
        fake_setup();
        MakeGame();
        if (c < 4) Game(entries[c])[1] ^= 0xFF;
        else PutPtr(Game(0x347CE28), NULL);
        Started(0, 0);
        g_keys[TAB] = 1;
        fake_set_state(HF_STATE_SHIP);
        Calls refusal = Measure(1, DT);
        CHECK(!vpm_running(g_ssh));
        CHECK_LOG(reasons[c]);
        CHECK_EQ(refusal.key + refusal.foreground + refusal.process + refusal.presenters, 0);
        Expect("after the refusal", 1, Measure(30, DT), (Calls){0});
    }
}

static void OffOnAnotherBuild(void)
{
    MakeGame();
    fake_set_build("25000000");
    Started(0, 0);
    CHECK(!vpm_running(g_ssh));
    CHECK(strstr(vpm_status(g_ssh), "off: needs game build") != NULL);
}

/* ---- per-frame calls --------------------------------------------------------------------------------------------- */

/* Before the ship: the context every 15 frames (game_state: not counted by the harness), nothing between. The ship is
 * found at the next check: the native check (5 code checks, 2 reads), the focus, the backend asked (ready), the gate. */
static void UntilTheShip(int backend)
{
    Frames("first frame, before the ship", 1, (Calls){.log = 1});
    Frames("before the ship", 19, (Calls){0});
    fake_set_state(HF_STATE_SHIP);
    Frames("ship loaded, before the next check", 10, (Calls){0});
    if (backend)
        Frames("arrival on the ship", 1, (Calls){.read = 3, .code = 5, .foreground = 1, .process = 1, .down = 1, .log = 2});
    else Frames("arrival on the ship", 1, (Calls){.read = 2, .code = 5, .key = 6, .foreground = 1, .process = 1, .log = 2});
}

/* Aboard with the gate: one read per idle frame; presses read the context, in or out of focus. */
static void GateAboard(void)
{
    Calls idle = {.read = 1}, press = {.read = 3, .foreground = 1, .process = 1, .down = 6, .presenters = 1, .log = 2};
    Frames("ship, idle", 59, idle);
    Frames("ship, mission check", 1, (Calls){.read = 2, .down = 1});
    g_window = &g_otherWindow; /* idle frames do not check the focus */
    Frames("ship, another window in front", 3, idle);
    Press(MAP, 1);
    Frames("ship, Tab pressed in another window", 1, (Calls){.read = 1, .foreground = 1, .process = 1, .down = 6});
    CHECK_EQ(g_calls.presenters, 0);
    Frames("ship, Tab held in another window", 2, (Calls){.read = 1, .foreground = 1});
    g_window = &g_gameWindow; /* held as the game comes back: it acts then */
    Frames("ship, Tab held as the game comes back", 1,
        (Calls){.read = 3, .foreground = 2, .process = 2, .down = 6, .presenters = 1, .log = 2});
    CHECK_EQ(*g_current, 15);
    Frames("ship, Tab held", 2, (Calls){.read = 1, .down = 6});
    Press(MAP, 0);
    SetPresenter(0, 0);
    Frames("ship, Tab released", 1, idle); /* the gate marks every shortcut up */
    Frames("ship, idle", 2, idle);
    Press(MAP, 1);
    Frames("ship, Tab pressed", 1, press);
    Press(MAP, 0);
    SetPresenter(0, 0);
    Frames("ship, Tab released", 1, idle);
}

/* The backend stops answering: the gate stands until the next check, then every focused frame asks it (once for ready,
 * six times for the shortcuts) and reads the fixed keys, until it answers again. */
static void GateBackendPause(void)
{
    g_ready = 0;
    Frames("ship, backend not answering, before the check", 45, (Calls){.read = 1});
    Frames("ship, mission check, backend not answering", 1, (Calls){.read = 1, .key = 6, .down = 7});
    Frames("ship, backend not answering", 3, (Calls){.key = 6, .down = 7});
    g_ready = 1;
    Frames("ship, backend answering again", 1, (Calls){.read = 1, .down = 1});
    Frames("ship, idle", 1, (Calls){.read = 1});
}

/* F8 during the pod's ready animation: until it opens, every frame reads the context, the presenter and the Hellpod,
 * and asks the six without the gate. */
static void GateHellpodWait(void)
{
    PodState(2, 1, 1);
    Press(HELLPOD, 1);
    Frames("ship, F8 pressed, pod not open", 1, (Calls){.read = 6, .foreground = 1, .process = 1, .down = 6, .log = 1});
    Press(HELLPOD, 0);
    Frames("ship, Hellpod wait", 2, (Calls){.read = 5, .foreground = 1, .process = 1, .down = 6});
    PodState(0, 0, 0);
    Frames("ship, Hellpod wait cancelled", 1, (Calls){.read = 5, .foreground = 1, .process = 1, .down = 6, .log = 1});
    CHECK_LOG("Hellpod shortcut cancelled; the mission is no longer selected.");
    Frames("ship, idle", 50, (Calls){.read = 1});
    Frames("ship, mission check", 1, (Calls){.read = 2, .down = 1});
}

/* Leaving for a mission, the mission, and the ship again. */
static void GateMissions(void)
{
    fake_set_state(HF_STATE_MISSION);
    Mission(1);
    Frames("ship gone, before the mission check", 2, (Calls){.read = 1});
    Press(MAP, 1);
    Frames("Tab pressed as the ship is gone", 1, (Calls){.read = 1, .down = 6});
    CHECK_EQ(g_calls.presenters, 2);
    Press(MAP, 0);
    Frames("off the ship, before the mission check", 56, (Calls){0});
    Frames("mission check, in a mission", 1, (Calls){.read = 1, .log = 1});
    CHECK_LOG("Mission detected; the shortcuts wait until it ends.");
    Press(MAP, 1);
    Frames("in a mission", 59, (Calls){0});
    Press(MAP, 0);
    Frames("in a mission, mission check", 1, (Calls){.read = 1});
    Mission(0);
    fake_set_state(HF_STATE_SHIP);
    Frames("ship loading", 59, (Calls){0});
    Frames("back on the ship", 1, (Calls){.read = 2, .foreground = 1, .process = 1, .down = 1, .log = 2});
    CHECK_LOG("Mission over; looking for the ship.");
    Frames("ship, idle", 59, (Calls){.read = 1});
    Mission(1);
    fake_set_state(HF_STATE_MISSION);
    Frames("ship to mission at the mission check", 1, (Calls){.read = 1, .log = 1});
    Frames("in a mission", 59, (Calls){0});
}

static void PerFrameCallsWithTheGate(void)
{
    MakeGame();
    Started(1, 0);
    fake_set_state(HF_STATE_TITLE);
    UntilTheShip(1);
    GateAboard();
    GateBackendPause();
    GateHellpodWait();
    GateMissions();
    CHECK_NO_LOG("disabled");
}

/* Without a backend: every focused frame aboard reads the six fixed keys; unfocused, only the focus. */
static void PerFrameCallsWithFixedKeys(void)
{
    Calls idle = {.key = 6};
    MakeGame();
    Started(0, 0);
    fake_set_state(HF_STATE_TITLE);
    UntilTheShip(0);
    Frames("ship, focused", 59, idle);
    Frames("ship, mission check", 1, (Calls){.read = 1, .key = 6});
    g_keys[TAB] = 1;
    Frames("ship, Tab pressed", 1, (Calls){.read = 2, .key = 6, .foreground = 1, .process = 1, .presenters = 1, .log = 2});
    g_keys[TAB] = 0;
    SetPresenter(0, 0);
    g_window = &g_otherWindow;
    Frames("ship, another window in front", 3, idle);
    g_keys[TAB] = 1;
    Frames("ship, Tab pressed in another window", 1, (Calls){.key = 6, .foreground = 1, .process = 1});
    g_keys[TAB] = 0;
    Frames("ship, not focused", 5, (Calls){.foreground = 1});
    g_window = &g_gameWindow;
    Frames("ship, focused again", 1, (Calls){.key = 6, .foreground = 1, .process = 1});
    Frames("ship, focused", 3, idle);
    CHECK_EQ(g_calls.presenters, 1);
}

/* A backend that stops (Mod Bindings Menu faulted) is noticed at the next check: the fixed keys answer from then on. */
static void StoppedBackendFallsBackToKeys(void)
{
    MakeGame();
    Started(1, 0);
    fake_set_state(HF_STATE_SHIP);
    Frame(DT);
    Frames("ship, idle", 3, (Calls){.read = 1});
    vpm_core_stop(fake_component(0), "test");
    Frames("ship, backend stopped, before the check", 56, (Calls){.read = 1});
    Frames("ship, mission check, backend stopped", 1, (Calls){.read = 1, .key = 6});
    Frames("ship, fixed keys", 3, (Calls){.key = 6});
    Tap(TAB, DT);
    CHECK_EQ(g_calls.presenters, 1);
}

/* Ship Station Hotkeys shipped English only: its table is used, and another language falls back to it. */
static void UsesTheLuaLocales(void)
{
    MakeGame();
    Started(0, 0);
    CHECK(strcmp(vpm_text(g_ssh, "binding.section", "fallback"), "Ship Station Hotkeys") == 0);
    CHECK(strcmp(vpm_text(g_ssh, "binding.control_center", "fallback"), "CONTROL CENTER") == 0);
    fake_text_language("zh-CN");
    CHECK(vpm_text_refresh());
    CHECK(strcmp(vpm_text(g_ssh, "binding.section", "fallback"), "Ship Station Hotkeys") == 0);
    CHECK(strcmp(vpm_text(g_ssh, "no.such.key", "fallback"), "fallback") == 0);
}

int main(void)
{
    RUN(RegistersTheSixBindings);
    RUN(UsesTheLuaLocales);
    RUN(FixedKeysWithoutBindings);
    RUN(BindingsAnswerFirst);
    RUN(RefusedBindingKeepsItsKey);
    RUN(PresentersOpenOnlyWhenIdle);
    RUN(HellpodRefusals);
    RUN(HellpodSeatsBehindTheBriefing);
    RUN(HellpodSeatCancels);
    RUN(HellpodWaitsForThePod);
    RUN(StratagemHeroBesideTheCabinet);
    RUN(ArcadeWithoutPositionFunction);
    RUN(RefusesEntriesNotAsReviewed);
    RUN(OffOnAnotherBuild);
    RUN(PerFrameCallsWithTheGate);
    RUN(PerFrameCallsWithFixedKeys);
    RUN(StoppedBackendFallsBackToKeys);
    TEST_END();
}
