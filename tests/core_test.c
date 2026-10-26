/* The core: start-up, switches, the crash guard, ticks, listeners, options, the settings file, bindings, the game's
 * lookup and the local avatar. */
#include <math.h>
#include <string.h>
#include "harness/test.h"

TEST_GLOBALS;

/* ---- test components -------------------------------------------------------------------------------------------- */

static int g_starts, g_stops, g_ticks, g_loads, g_events;
static volatile int* g_null;

static void CountTick(VpmComponent* self, float dt) { g_ticks++; }
static void FaultTick(VpmComponent* self, float dt) { g_ticks++; (void)*g_null; }
static void Deeper(void) { (void)g_null[4]; }
static __attribute__((noinline)) void Deep(void) { Deeper(); }
static void DeepFaultTick(VpmComponent* self, float dt) { Deep(); }
static void OnceTick(VpmComponent* self, float dt) { g_ticks++; vpm_tick_stop(self); }
static void CountLoad(VpmComponent* self, HfEvent event) { g_loads++; }
static void CountEvent(VpmComponent* self, const HfEventInfo* event) { g_events++; }
static void FaultEvent(VpmComponent* self, const HfEventInfo* event) { g_events++; (void)*g_null; }
static void Stop(VpmComponent* self) { g_stops++; }

static int StartTicking(VpmComponent* self) { g_starts++; vpm_tick_start(self, CountTick); vpm_on_load(self, HF_EVENT_GAME_LOADED, CountLoad); return 0; }
static int StartFaulting(VpmComponent* self) { g_starts++; vpm_tick_start(self, FaultTick); return 0; }
static int StartDeepFault(VpmComponent* self) { g_starts++; vpm_tick_start(self, DeepFaultTick); return 0; }
static int StartOnce(VpmComponent* self) { g_starts++; vpm_tick_start(self, OnceTick); return 0; }
static int StartListening(VpmComponent* self) { g_starts++; vpm_listen(self, HF_ON_SPAWN, CountEvent, 0); return 0; }
static int StartFaultListener(VpmComponent* self) { g_starts++; vpm_listen(self, HF_ON_SPAWN, FaultEvent, 5); return 0; }
static int StartRefused(VpmComponent* self) { g_starts++; return vpm_fail(self, "no table here"); }
static int StartFaultInStart(VpmComponent* self) { g_starts++; (void)*g_null; return 0; }
static int StartDivide(VpmComponent* self) { volatile int zero = 0; g_starts++; return 10 / zero; }

static const VpmComponentDef kTicking = {"ticking", "Ticking", "1.0", 0, StartTicking, Stop};
static const VpmComponentDef kFaulting = {"faulting", "Faulting", "1.0", 0, StartFaulting, Stop};
static const VpmComponentDef kDeepFault = {"deep_fault", "Deep Fault", "1.0", 0, StartDeepFault, Stop};
static const VpmComponentDef kOnce = {"once", "Once", "1.0", 0, StartOnce, NULL};
static const VpmComponentDef kListening = {"listening", "Listening", "1.0", 0, StartListening, NULL};
static const VpmComponentDef kFaultListener = {"fault_listener", "Fault Listener", "1.0", 0, StartFaultListener, Stop};
static const VpmComponentDef kRefused = {"refused", "Refused", "1.0", 0, StartRefused, Stop};
static const VpmComponentDef kFaultInStart = {"fault_start", "Fault In Start", "1.0", 0, StartFaultInStart, Stop};
static const VpmComponentDef kDivide = {"divide", "Divide", "1.0", 0, StartDivide, Stop};
static const VpmComponentDef kOverlap = {"overlap", "Overlap", "1.0", VPM_OVERLAPS_VANILLA_PLUS, StartTicking, NULL};
static const VpmComponentDef kDefaultOff = {"default_off", "Default Off", "1.0", VPM_DEFAULT_OFF, StartTicking, NULL};

static void Reset(void) { g_starts = g_stops = g_ticks = g_loads = g_events = 0; }

/* ---- start-up ---------------------------------------------------------------------------------------------------- */

static void StartsSwitchedOnComponents(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kTicking, &kDefaultOff};
    CHECK_EQ(fake_start(defs, 2), 0);
    CHECK_EQ(g_starts, 1);
    CHECK(vpm_running(fake_component(0)));
    CHECK(!vpm_running(fake_component(1)));
    CHECK(strcmp(vpm_status(fake_component(1)), "off") == 0);
    CHECK_LOG("1 of 2 components running");
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(g_loads, 1);
    fake_frames(3, 1.0f / 60);
    CHECK_EQ(g_ticks, 3);
}

static void RefusesAnOldSdk(void)
{
    HfApi old = *fake_api();
    old.version = 14;
    const VpmComponentDef* defs[] = {&kTicking};
    CHECK_EQ(vpm_core_init(&old, fake_mod(), defs, 1), 1);
    CHECK_LOG("needs HellForge mod SDK 15");
}

static void StaysOffOnAnotherBuild(void)
{
    Reset();
    fake_set_build("26088801");
    const VpmComponentDef* defs[] = {&kTicking};
    fake_start(defs, 1);
    CHECK_EQ(g_starts, 0);
    CHECK(strstr(vpm_status(fake_component(0)), "needs game build 25480438") != NULL);
}

static void SkipsOverlapsWithVanillaPlus(void)
{
    Reset();
    fake_add_mod("skyeshade.vanilla-plus", HF_MOD_CODE);
    const VpmComponentDef* defs[] = {&kOverlap, &kTicking};
    fake_start(defs, 2);
    CHECK_EQ(g_starts, 1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Overlap] off: HellForge's Vanilla Plus is on and changes the same thing");
    CHECK(vpm_running(fake_component(1)));
}

static void ARefusedStartStaysOff(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kRefused};
    fake_start(defs, 1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_EQ(g_stops, 0); /* it never started, so nothing to undo */
    CHECK_LOG("[Refused] disabled: no table here");
}

/* ---- the crash guard --------------------------------------------------------------------------------------------- */

static void AFaultingTickStopsOnlyItsComponent(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kFaulting, &kTicking, &kDeepFault};
    fake_start(defs, 3);
    fake_frames(5, 1.0f / 60);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(vpm_running(fake_component(1)));
    CHECK(!vpm_running(fake_component(2)));
    CHECK_EQ(g_ticks, 1 + 5); /* the faulting tick ran once; the healthy one every frame, the first frame included */
    CHECK_EQ(g_stops, 2);
    CHECK_LOG("[Faulting] disabled: fault 0xC0000005 at vanilla_plus_megapack.dll+0x");
    CHECK_LOG("(a read of 0x0)");
    CHECK_LOG("[Deep Fault] disabled: fault 0xC0000005");
    CHECK_LOG("(a read of 0x10)");
}

static void AFaultInStartStopsIt(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kFaultInStart, &kDivide, &kTicking};
    fake_start(defs, 3);
    CHECK_EQ(g_starts, 3);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(!vpm_running(fake_component(1)));
    CHECK(vpm_running(fake_component(2)));
    CHECK_EQ(g_stops, 0);
    CHECK_LOG("[Divide] disabled: fault 0xC0000094");
}

static void AFaultingListenerStopsAndOthersHear(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kFaultListener, &kListening};
    fake_start(defs, 2);
    HfSpawnEvent spawn = {{sizeof spawn, HF_ON_SPAWN, 1}, 1, 2, 3, 1};
    fake_emit(&spawn.info);
    fake_emit(&spawn.info);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(vpm_running(fake_component(1)));
    CHECK_EQ(g_events, 1 + 2);
}

static void AGuardNestsAndManyCallsRun(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kTicking};
    fake_start(defs, 1);
    fake_frames(100000, 1.0f / 60);
    CHECK_EQ(g_ticks, 100000);
}

static void TicksStopThemselves(void)
{
    Reset();
    const VpmComponentDef* defs[] = {&kOnce, &kTicking};
    fake_start(defs, 2);
    fake_frames(4, 1.0f / 60);
    CHECK_EQ(g_ticks, 1 + 4);
    CHECK(vpm_running(fake_component(0)));
    CHECK(!vpm_ticking(fake_component(0)));
}

/* ---- options and the settings file ------------------------------------------------------------------------------ */

static VpmOption* g_depth;
static VpmOption* g_mode;
static VpmOption* g_flag;
static double g_changed = -1;
static const char* const kModes[] = {"Armor", "Helmet", "Cape", NULL};
static const VpmOptionDef kDepth = {"max_depth", VPM_SLIDER, "Maximum dive depth", NULL, 1.25, 0.5, 3.0, 0.25};
static const VpmOptionDef kMode = {"mode", VPM_CHOICE, "Colors from", NULL, 1, 0, 0, 0, kModes};
static const VpmOptionDef kFlag = {"flag", VPM_TOGGLE, "A switch", NULL, 1};
static void Changed(VpmComponent* self, VpmOption* option, double value) { g_changed = value; }
static int StartOptions(VpmComponent* self)
{
    g_depth = vpm_option(self, &kDepth);
    g_mode = vpm_option(self, &kMode);
    g_flag = vpm_option(self, &kFlag);
    vpm_option_on_change(g_depth, Changed);
    return 0;
}
static const VpmComponentDef kOptions = {"options_user", "Options User", "1.0", 0, StartOptions, NULL};

static void OptionsHaveDefaultsAndPersist(void)
{
    const VpmComponentDef* defs[] = {&kOptions};
    fake_start(defs, 1);
    CHECK(vpm_option_value(g_depth) == 1.25);
    CHECK(vpm_option_value(g_mode) == 1);
    CHECK(vpm_option_value(g_flag) == 1);
    CHECK_EQ(vpm_option_count(), 3);
    CHECK(vpm_option_set(g_depth, 9.0));      /* out of range: clamped, as Mod Options Menu's snap does */
    CHECK(vpm_option_value(g_depth) == 3.0);
    CHECK(!vpm_option_set(g_mode, 4));        /* no fourth choice */
    CHECK(!vpm_option_set(g_flag, 0.5));
    CHECK(vpm_option_apply(g_depth, 1.6));     /* snapped to the 0.25 step */
    CHECK(vpm_option_value(g_depth) == 1.5);
    CHECK(g_changed == 1.5);
    CHECK(vpm_option_set(g_mode, 3));
    fake_frames(30, 1.0f / 60);                /* half the save delay: nothing written */
    CHECK(GetFileAttributesW(L"vpm-test-settings.ini") == INVALID_FILE_ATTRIBUTES);
    fake_frames(40, 1.0f / 60);
    CHECK(GetFileAttributesW(L"vpm-test-settings.ini") != INVALID_FILE_ATTRIBUTES);
    /* A new session reads them back. */
    vpm_core_reset();
    vpm_settings_path_override(L"vpm-test-settings.ini");
    fake_start(defs, 1);
    CHECK(vpm_option_value(g_depth) == 1.5);
    CHECK(vpm_option_value(g_mode) == 3);
}

static void SwitchesPersistAndUnknownEntriesStay(void)
{
    HANDLE file = CreateFileW(L"vpm-test-settings.ini", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    const char text[] = "[components]\nticking = off\nsomething_old = on\n[options]\noptions_user.max_depth = 7\noptions_user.mode = x\n[other]\nkept = yes\n";
    DWORD wrote;
    WriteFile(file, text, sizeof text - 1, &wrote, NULL);
    CloseHandle(file);
    Reset();
    const VpmComponentDef* defs[] = {&kTicking, &kOptions};
    fake_start(defs, 2);
    CHECK_EQ(g_starts, 0);
    CHECK(!vpm_component_switched_on(fake_component(0)));
    CHECK(vpm_option_value(g_depth) == 3.0); /* 7 is out of range: clamped, as Mod Options Menu's decode does */
    CHECK(vpm_option_value(g_mode) == 1);    /* not a number: the default */
    CHECK_LOG("the saved value \"x\" is not valid");
    vpm_component_switch(fake_component(0), 1);
    vpm_settings_flush();
    vpm_core_reset();
    vpm_settings_path_override(L"vpm-test-settings.ini");
    Reset();
    fake_start(defs, 2);
    CHECK_EQ(g_starts, 1);
    CHECK(strcmp(vpm_setting("other", "kept"), "yes") == 0);
    CHECK(strcmp(vpm_setting("components", "something_old"), "on") == 0);
}

/* ---- bindings ---------------------------------------------------------------------------------------------------- */

static VpmBinding* g_binding;
static int g_attached, g_down = 1;
static const VpmBindingDef kArmory = {"armory", "Armory", NULL, 0, 0x70};
static void* Attach(VpmBinding* binding) { g_attached++; return (void*)(uintptr_t)42; } /* lint-ok: C2 a token, never dereferenced */
static int Down(const VpmBinding* binding, void* data) { return data == (void*)(uintptr_t)42 ? g_down : -1; } /* lint-ok: C2 the token compared */
static const VpmBindingBackend kBackend = {Attach, Down};
static int StartBindingUser(VpmComponent* self) { g_binding = vpm_binding(self, &kArmory); return g_binding == NULL; }
static int StartBackend(VpmComponent* self) { vpm_bindings_set_backend(self, &kBackend); return 0; }
static const VpmComponentDef kBindingUser = {"binding_user", "Binding User", "1.0", 0, StartBindingUser, NULL};
static const VpmComponentDef kBackendDef = {"backend", "Backend", "1.0", 0, StartBackend, NULL};

static void BindingsAnswerUnknownWithoutABackend(void)
{
    const VpmComponentDef* defs[] = {&kBindingUser};
    fake_start(defs, 1);
    CHECK_EQ(vpm_binding_down(g_binding), -1);
}

static void BindingsAttachInEitherOrder(void)
{
    g_attached = 0;
    const VpmComponentDef* defs[] = {&kBindingUser, &kBackendDef};
    fake_start(defs, 2);
    CHECK_EQ(g_attached, 1);
    CHECK_EQ(vpm_binding_down(g_binding), 1);
    vpm_core_reset();
    g_attached = 0;
    const VpmComponentDef* reversed[] = {&kBackendDef, &kBindingUser};
    fake_start(reversed, 2);
    CHECK_EQ(g_attached, 1);
    g_down = 0;
    CHECK_EQ(vpm_binding_down(g_binding), 0);
    g_down = 1;
}

/* ---- memory, the lookup and the avatar --------------------------------------------------------------------------- */

static int StartNothing(VpmComponent* self) { return 0; }
static const VpmComponentDef kNothing = {"nothing", "Nothing", "1.0", 0, StartNothing, NULL};

/* A lookup at `header` whose rows (capacity 16, multiplier 1) map key -> index. */
static void PutLookup(uintptr_t header, uint32_t key, uint32_t index)
{
    uint32_t* rows = fake_heap(16 * 8);
    for (int i = 0; i < 16; i++) rows[i * 2] = 0xFFFFFFFFu; /* empty */
    rows[(key & 15) * 2] = key;
    rows[(key & 15) * 2 + 1] = index;
    uint64_t at = (uint64_t)(uintptr_t)rows;
    memcpy((void*)header, &at, 8);
    uint32_t tail[3] = {16, 0xFFFFFFFFu, 1};
    memcpy((void*)(header + 8), tail, 12);
}

static void LookupFindsAndMisses(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    uintptr_t header = (uintptr_t)fake_heap(20);
    PutLookup(header, 0x1234, 7);
    uint32_t index = 0;
    CHECK(vpm_lookup(header, 0x1234, 64, &index));
    CHECK_EQ(index, 7);
    CHECK(!vpm_lookup(header, 0x1235, 64, &index));
    CHECK(!vpm_lookup(header, 0x1234, 8, &index)); /* capacity over the limit */
    fake_hole(header, 20);
    CHECK(!vpm_lookup(header, 0x1234, 64, &index));
}

static void MemoryReadsAreSafe(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    uint32_t value = 0;
    CHECK(!vpm_read_u32(0x10, &value));
    CHECK(vpm_ptr(0x10) == 0);
    *(uint64_t*)(fake_game() + 0x100) = 0x1122334455667788ull;
    CHECK(vpm_game_u64(0x100) == 0x1122334455667788ull);
    CHECK(vpm_game_u64(FAKE_GAME_SIZE - 4) == 0); /* runs past the image */
    uint32_t* heap = fake_heap(16);
    heap[1] = 99;
    CHECK(vpm_read_u32((uintptr_t)&heap[1], &value) && value == 99);
    CHECK(vpm_writable((uintptr_t)heap, 16));
    CHECK(!vpm_writable((uintptr_t)&MemoryReadsAreSafe, 16)); /* code */
}

/* The registries of a local player in a mission, as Arc Thrower Revamped reads them. */
static void PutLocalPlayer(uint32_t avatarId)
{
    uint8_t* pm = fake_heap(0x400);
    uint8_t* owner = fake_heap(0xF32F18 + 24 * 64);
    uint8_t* am = fake_heap(0x150 + 2 * 0xA7AEC);
    *(uint64_t*)(fake_game() + VPM_RVA_PLAYER_MANAGER) = (uint64_t)(uintptr_t)pm;
    *(uint64_t*)(fake_game() + VPM_RVA_ENTITY_OWNER) = (uint64_t)(uintptr_t)owner;
    *(uint64_t*)(fake_game() + VPM_RVA_AVATAR_MANAGER) = (uint64_t)(uintptr_t)am;
    uint32_t counts[2] = {1, 1}, unit = 5;
    memcpy(pm + 0x84, counts, 8);
    memcpy(pm + 0x3A8, &unit, 4);
    uint32_t* player = fake_heap(24);
    player[5] = 1;
    *(uint64_t*)(pm + 0xE8) = (uint64_t)(uintptr_t)player;
    PutLookup((uintptr_t)(owner + 0xF22EC8), unit, 3);
    uint32_t avatar[6] = {0x294DFA97u, 0x4D1C334Du, avatarId, 9, 0, 1};
    memcpy(owner + 0xF32F18 + 3 * 24, avatar, 24);
    PutLookup((uintptr_t)(am + 0xF8), avatarId, 1);
    uint32_t count = 2;
    memcpy(am + 0x6C, &count, 4);
    uint32_t* entity = fake_heap(24);
    memcpy(entity, avatar, 24);
    *(uint64_t*)(am + 0x110 + 8) = (uint64_t)(uintptr_t)entity;
}

static void ResolvesTheLocalAvatar(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    VpmAvatar avatar;
    CHECK(!vpm_local_avatar(&avatar)); /* no registries yet */
    PutLocalPlayer(77);
    fake_counts_reset();
    CHECK(vpm_local_avatar(&avatar));
    CHECK_EQ(avatar.index, 1);
    CHECK_EQ(avatar.record[2], 77);
    CHECK_EQ(fake_counts().read, 12);
    fake_counts_reset();
    CHECK(vpm_avatar_still(&avatar));
    CHECK_EQ(fake_counts().read, 2);
    CHECK(vpm_action_slot(&avatar, VPM_ACTION_FIRE) == avatar.manager + 0x150 + 0xA7AEC + 0x1B68 + 9 * 32);
    /* Another avatar at the index: the kept resolution no longer holds. */
    uint32_t* entity = (uint32_t*)avatar.entity;
    entity[3] = 10;
    CHECK(!vpm_avatar_still(&avatar));
}

static void TheAvatarSaysWhyAndWhere(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    VpmAvatar avatar;
    const char* why = NULL;
    CHECK(!vpm_local_avatar_why(&avatar, &why));
    CHECK(why != NULL && strcmp(why, "no player manager or entity owner") == 0);
    PutLocalPlayer(77);
    CHECK(vpm_local_avatar_why(&avatar, &why));
    CHECK(why != NULL && why[0] == 0);
    CHECK_EQ(avatar.owner_index, 3);
    uintptr_t owner = (uintptr_t)vpm_game_u64(VPM_RVA_ENTITY_OWNER);
    CHECK(avatar.record_at == owner + 0xF32F18 + 3 * 24);
    ((uint32_t*)avatar.record_at)[5] = 0; /* not owned */
    CHECK(!vpm_local_avatar_why(&avatar, &why));
    CHECK(strcmp(why, "not an owned Helldiver avatar") == 0);
}

static void PointersAreUserModeOnly(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    uint64_t* cell = fake_heap(8);
    *cell = 0x800000000000ull;
    CHECK(vpm_ptr((uintptr_t)cell) == 0);
    *cell = 0xFFFF;
    CHECK(vpm_ptr((uintptr_t)cell) == 0);
    *cell = 0x7FFFFFFFFFF0ull;
    CHECK(vpm_ptr((uintptr_t)cell) == 0x7FFFFFFFFFF0ull);
}

static int g_standInCalls;
static int StandIn(int x) { g_standInCalls++; return x + 1; }
static void* g_exported = (void*)&StandIn;
static int g_afterCalls;
static void After(void* user) { g_afterCalls++; *(uint32_t*)user = 5; }

static void TheHarnessStandsIn(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_stand_in(0x123450, "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 8B FA", (void*)&StandIn);
    CHECK(vpm_game_code_matches(0x123450, "48 89 5C 24 08 57 48 83 EC 20"));
    int (*fn)(int) = (int (*)(int))(void*)(vpm_game() + 0x123450);
    CHECK_EQ(fn(41), 42);
    CHECK_EQ(g_standInCalls, 1);
    fake_export("wwise_pluginw64_release.dll", "?SetState@SoundEngine@AK@@YA?AW4AKRESULT@@II@Z", g_exported);
    CHECK(vpm_module_export("WWISE_pluginw64_release.dll", "?SetState@SoundEngine@AK@@YA?AW4AKRESULT@@II@Z") == g_exported);
    CHECK(vpm_module_export("wwise_pluginw64_release.dll", "?IsInitialized@SoundEngine@AK@@YA_NXZ") == NULL);
    CHECK_EQ(fake_counts().exports, 2);
    uint32_t* cell = fake_heap(16);
    uint32_t value = 0;
    fake_after_read((uintptr_t)&cell[1], 2, After, &cell[1]);
    CHECK(vpm_read_u32((uintptr_t)&cell[0], &value)); /* does not touch cell[1] */
    CHECK(vpm_read_u32((uintptr_t)&cell[1], &value) && value == 0);
    CHECK_EQ(g_afterCalls, 0);
    CHECK(vpm_read(((uintptr_t)cell), cell + 2, 8) && g_afterCalls == 1); /* the second read touching it */
    CHECK(vpm_read_u32((uintptr_t)&cell[1], &value) && value == 5);
    fake_counts_reset();
    CHECK(vpm_writable((uintptr_t)cell, 16));
    CHECK_EQ(fake_counts().writable, 1);
}

/* ---- guarded reads (vpm_read's own path: the harness's read hook is taken away) ---------------------------------- */

static volatile LONG g_exceptions;
static LONG CALLBACK CountExceptions(EXCEPTION_POINTERS* info) { InterlockedIncrement(&g_exceptions); return EXCEPTION_CONTINUE_SEARCH; }

/* The core started, its read hook gone (so vpm_read makes its own guarded loads), and a first-in-line counter of every
 * exception raised from now on. */
static PVOID ProbeSetUp(void)
{
    const VpmComponentDef* defs[] = {&kNothing};
    fake_start(defs, 1);
    static const VpmTestHooks none = {0};
    vpm_core_test_hooks(&none);
    g_exceptions = 0;
    return AddVectoredExceptionHandler(1, CountExceptions); /* lint-ok: C7 the test counts the faults the guard takes */
}

static void ProbeTearDown(PVOID counter) { RemoveVectoredExceptionHandler(counter); }

static void GuardedReadsReadAndRefuse(void)
{
    PVOID counter = ProbeSetUp();
    uint8_t* page = VirtualAlloc(NULL, 4 * 4096, MEM_RESERVE, PAGE_NOACCESS);
    VirtualAlloc(page, 4096, MEM_COMMIT, PAGE_READWRITE); /* lint-ok: C1 the test's pages */
    VirtualAlloc(page + 2 * 4096, 4096, MEM_COMMIT, PAGE_READWRITE); /* lint-ok: C1 the test's pages */
    DWORD old;
    VirtualProtect(page + 2 * 4096, 4096, PAGE_NOACCESS, &old); /* lint-ok: C1,C3 a no-access page */
    for (int i = 0; i < 4096; i++) page[i] = (uint8_t)(i * 7);
    uint8_t out[64];
    uint64_t value = 0;
    /* readable, at every alignment */
    for (int at = 0; at < 16; at++)
    {
        CHECK(vpm_read((uintptr_t)page + 100 + at, out, 37));
        CHECK(memcmp(out, page + 100 + at, 37) == 0);
    }
    CHECK(vpm_read_u64((uintptr_t)page + 4089 - 1, &value) && memcmp(&value, page + 4088, 8) == 0);
    CHECK_EQ(g_exceptions, 0);
    /* reserved, a span running into the reserved page, no-access: each fails with one fault, nothing stopped */
    CHECK(!vpm_read((uintptr_t)page + 4096, out, 8));
    CHECK(!vpm_read((uintptr_t)page + 4090, out, 16));
    CHECK(!vpm_read((uintptr_t)page + 2 * 4096 + 8, out, 4));
    CHECK_EQ(g_exceptions, 3);
    CHECK(vpm_running(fake_component(0)));
    /* outside the user-mode range, or wrapping: refused before any load, no fault */
    g_exceptions = 0;
    CHECK(!vpm_read(0, out, 8));
    CHECK(!vpm_read(0x84, out, 8));
    CHECK(!vpm_read(0xFFFF, out, 1));
    CHECK(!vpm_read(0x800000000000ull, out, 8));
    CHECK(!vpm_read(0x7FFFFFFFFFFCull, out, 8)); /* its end is past 2^47 */
    CHECK(!vpm_read(UINTPTR_MAX - 3, out, 8));
    CHECK(!vpm_read((uintptr_t)page, out, 0));
    CHECK(vpm_ptr(0x10) == 0);
    CHECK_EQ(g_exceptions, 0);
    VirtualFree(page, 0, MEM_RELEASE); /* lint-ok: C1 the test's pages */
    ProbeTearDown(counter);
}

static void GuardedReadsSurviveGuardPages(void)
{
    PVOID counter = ProbeSetUp();
    uint8_t* page = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD);
    uint32_t value = 0;
    CHECK(!vpm_read_u32((uintptr_t)page, &value)); /* the guard page's one-shot fault: the read fails */
    CHECK(vpm_read_u32((uintptr_t)page, &value));  /* the system took the guard off, as for a ReadProcessMemory */
    CHECK(vpm_running(fake_component(0)));
    VirtualFree(page, 0, MEM_RELEASE); /* lint-ok: C1 the test's page */
    ProbeTearDown(counter);
}

static void GuardedReadsCopyLargeBlocks(void)
{
    PVOID counter = ProbeSetUp();
    static uint8_t source[80 * 1024 + 3], copy[80 * 1024 + 3];
    for (size_t i = 0; i < sizeof source; i++) source[i] = (uint8_t)(i ^ (i >> 8));
    CHECK(vpm_read((uintptr_t)source, copy, sizeof source));
    CHECK(memcmp(source, copy, sizeof source) == 0);
    CHECK_EQ(g_exceptions, 0);
    ProbeTearDown(counter);
}

/* A failed read inside a tick: the read answers 0 and the tick goes on; the component keeps running. */
static int g_tickReads, g_tickAfter;
static uintptr_t g_badAddress;
static void ReadingTick(VpmComponent* self, float dt)
{
    uint32_t value;
    g_tickReads += vpm_read_u32(g_badAddress, &value) ? 100 : 1;
    g_tickAfter++;
}
static int StartReading(VpmComponent* self) { vpm_tick_start(self, ReadingTick); return 0; }
static const VpmComponentDef kReading = {"reading", "Reading", "1.0", 0, StartReading, NULL};

static void AFailedReadDoesNotStopATick(void)
{
    const VpmComponentDef* defs[] = {&kReading};
    fake_start(defs, 1);
    static const VpmTestHooks none = {0};
    vpm_core_test_hooks(&none);
    uint8_t* page = VirtualAlloc(NULL, 4096, MEM_RESERVE, PAGE_NOACCESS);
    g_badAddress = (uintptr_t)page + 16;
    g_tickReads = g_tickAfter = 0;
    fake_frames(50, 1.0f / 60);
    CHECK_EQ(g_tickReads, 50);
    CHECK_EQ(g_tickAfter, 50);
    CHECK(vpm_running(fake_component(0)));
    CHECK_NO_LOG("disabled");
    VirtualFree(page, 0, MEM_RELEASE); /* lint-ok: C1 the test's page */
}

static void AMillionGuardedReads(void)
{
    PVOID counter = ProbeSetUp();
    static uint64_t cells[256];
    for (int i = 0; i < 256; i++) cells[i] = (uint64_t)i * 0x9E3779B97F4A7C15ull;
    uint64_t sum = 0, expect = 0, value = 0;
    for (int i = 0; i < 1000000; i++)
    {
        if (vpm_read_u64((uintptr_t)&cells[i & 255], &value)) sum += value;
        expect += cells[i & 255];
    }
    CHECK(sum == expect);
    CHECK_EQ(g_exceptions, 0);
    ProbeTearDown(counter);
}

/* ---- hooks ------------------------------------------------------------------------------------------------------- */

static int g_original(int x) { return x * 2; }
static int (*g_hooked)(int);
static VpmComponent* g_hooker;
static int g_detourWork;
static volatile int* g_detourNull;
typedef struct DetourCall { int x; int result; } DetourCall;
static void DetourWork(void* arg)
{
    DetourCall* call = arg;
    g_detourWork++;
    if (call->x < 0) call->result = *g_detourNull;
    call->result = call->x + 1000;
}
/* lint: per-frame */
static int Detour(int x)
{
    if (vpm_running(g_hooker))
    {
        DetourCall call = {x, 0};
        if (vpm_guarded(g_hooker, DetourWork, &call)) return call.result;
    }
    return g_hooked(x);
}
static uint32_t g_hookRva = 0x234560;
static int StartHooking(VpmComponent* self)
{
    g_hooker = self;
    return vpm_hook(self, g_hookRva, "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 8B FA", (void*)&Detour, (void**)&g_hooked) ? 0 : 1;
}
static const VpmComponentDef kHooking = {"hooking", "Hooking", "1.0", 0, StartHooking, Stop};

static void HooksCheckTheBytesAndChain(void)
{
    Reset();
    g_detourWork = 0;
    fake_stand_in(g_hookRva, "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 8B FA", (void*)&g_original);
    const VpmComponentDef* defs[] = {&kHooking};
    fake_start(defs, 1);
    CHECK(vpm_running(fake_component(0)));
    CHECK_EQ(fake_hook_count(), 1);
    int (*detour)(int) = (int (*)(int))fake_hook_detour(fake_game() + g_hookRva);
    CHECK(detour == &Detour);
    CHECK(g_hooked != NULL && g_hooked(21) == 42); /* the original reaches the function, through its stand-in */
    CHECK_EQ(detour(5), 1005);
    CHECK_EQ(g_detourWork, 1);
    /* A fault in the detour's own work stops the component; the call goes on to the original, and so do later calls. */
    CHECK_EQ(detour(-3), -6);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_EQ(g_stops, 1);
    CHECK_LOG("[Hooking] disabled: fault 0xC0000005");
    CHECK_EQ(detour(7), 14);
    CHECK_EQ(g_detourWork, 2);
}

static void HooksRefuseOtherBytes(void)
{
    Reset();
    fake_stand_in(g_hookRva, "48 89 5C 24 10 57 48 83 EC 20 48 8B D9 8B FA", (void*)&g_original); /* +4: 10, not 08 */
    const VpmComponentDef* defs[] = {&kHooking};
    fake_start(defs, 1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_EQ(fake_hook_count(), 0);
    CHECK_LOG("hook refused: game.dll+0x234560 is not the reviewed function");
}

static void HooksRefuseOutsideTheImage(void)
{
    Reset();
    uint32_t kept = g_hookRva;
    g_hookRva = FAKE_GAME_SIZE + 0x10;
    const VpmComponentDef* defs[] = {&kHooking};
    fake_start(defs, 1);
    g_hookRva = kept;
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("is not in the image");
    CHECK_EQ(fake_hook_count(), 0);
}

static int HookExRefused(HfMod* mod, uintptr_t target, void* detour, void** original, int32_t priority) { return 1; }
static const char* LastLogText(HfMod* mod) { return "more than 16 hooks on one function"; }

static void HooksSayWhyHellForgeRefused(void)
{
    Reset();
    fake_stand_in(g_hookRva, "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 8B FA", (void*)&g_original);
    HfApi refusing = *fake_api();
    refusing.hook_ex = HookExRefused;
    refusing.last_log = LastLogText;
    const VpmComponentDef* defs[] = {&kHooking};
    CHECK_EQ(vpm_core_init(&refusing, fake_mod(), defs, 1), 0);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("hook refused at game.dll+0x234560: more than 16 hooks on one function");
}

static int StartHookingExe(VpmComponent* self)
{
    g_hooker = self;
    return vpm_hook_exe(self, 0x80F200, "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 8B FA", (void*)&Detour, (void**)&g_hooked) ? 0 : 1;
}
static const VpmComponentDef kHookingExe = {"hooking_exe", "Hooking Exe", "1.0", 0, StartHookingExe, NULL};

static void HooksReachTheExe(void)
{
    /* fake_stand_in names game.dll RVAs: the exe's bytes are laid down by hand. */
    static const uint8_t bytes[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0xD9, 0x8B, 0xFA};
    memcpy((void*)(fake_exe() + 0x80F200), bytes, sizeof bytes);
    const VpmComponentDef* defs[] = {&kHookingExe};
    fake_start(defs, 1);
    CHECK(vpm_running(fake_component(0)));
    CHECK(fake_hook_detour(fake_exe() + 0x80F200) == (void*)&Detour);
}

/* ---- the harness's own steps ------------------------------------------------------------------------------------ */

static int g_afterTicks;
static void AfterTick(float dt) { g_afterTicks++; CHECK_EQ(g_ticks, g_afterTicks); }
static short __stdcall NoKeys(int key) { return (short)(key == 0x70 ? 0x8000 : 0); }

static void TheHarnessRunsTheGameAfterTheTickAndStandsInForUser32(void)
{
    Reset();
    g_afterTicks = 0;
    const VpmComponentDef* defs[] = {&kTicking};
    fake_start(defs, 1);
    fake_after_tick(AfterTick);
    fake_frames(3, 1.0f / 60);
    CHECK_EQ(g_afterTicks, 3);
    VpmUser32 keys = {0};
    keys.GetAsyncKeyState = NoKeys;
    fake_user32(&keys);
    CHECK(vpm_user32()->GetAsyncKeyState == NoKeys);
    CHECK(vpm_user32()->GetAsyncKeyState(0x70) != 0 && vpm_user32()->GetAsyncKeyState(0x71) == 0);
}

/* ---- the frame hook: one tick per frame at the start of game.dll's update, post-update ticks after it ------------- */

static int g_pre, g_post, g_world, g_preSawWorld, g_postSawWorld;
static float g_preDt, g_postDt;
static void World(float dt) { g_world++; }
static void PreTick(VpmComponent* self, float dt) { g_pre++; g_preDt = dt; g_preSawWorld = g_world; }
static void PostTick(VpmComponent* self, float dt) { g_post++; g_postDt = dt; g_postSawWorld = g_world; }
static void FaultingPost(VpmComponent* self, float dt) { g_post++; (void)*g_null; }
static int StartBoth(VpmComponent* self) { vpm_tick_start(self, PreTick); vpm_post_tick_start(self, PostTick); return 0; }
static int StartFaultingPost(VpmComponent* self) { vpm_post_tick_start(self, FaultingPost); return 0; }
static const VpmComponentDef kBoth = {"both", "Both", "1.0", 0, StartBoth, NULL};
static const VpmComponentDef kFaultingPost = {"faulting_post", "Faulting Post", "1.0", 0, StartFaultingPost, Stop};

static void FrameReset(void) { g_pre = g_post = g_world = g_preSawWorld = g_postSawWorld = 0; g_preDt = g_postDt = 0; }

static void TicksRunAroundTheFrameUpdate(void)
{
    FrameReset();
    fake_frame_update(1);
    const VpmComponentDef* defs[] = {&kBoth};
    fake_start(defs, 1);
    fake_after_tick(World);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(vpm_frame_hooked(), 1);
    CHECK_EQ(fake_counts().code_matches + fake_counts().read, 0); /* the bytes were compared with plain loads */
    CHECK_LOG("ticks run at the start and the end of the game's frame update (game.dll 0xAB5000)");
    fake_engine_frames(5, 0.02f);
    CHECK_EQ(fake_game_updates(), 5);
    CHECK_EQ(g_pre, 5);
    CHECK_EQ(g_post, 5);
    CHECK_EQ(g_preSawWorld, 4);   /* before the frame's world update */
    CHECK_EQ(g_postSawWorld, 5);  /* after it */
    CHECK(g_preDt == 0.02f && g_postDt == 0.02f);
    /* HellForge's callback inside the update does nothing now, also when it runs twice in a frame */
    fake_double_tick(1);
    fake_engine_frames(5, 0.02f);
    CHECK_EQ(g_pre, 10);
    CHECK_EQ(g_post, 10);
}

static void TicksWaitForTheFrameUpdatesCode(void)
{
    FrameReset();
    fake_frame_update(0); /* not decoded yet */
    const VpmComponentDef* defs[] = {&kBoth};
    fake_start(defs, 1);
    fake_after_tick(World);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(vpm_frame_hooked(), 0);
    fake_counts_reset();
    fake_engine_frames(3, 1.0f);
    /* meanwhile the ticks run in HellForge's callback, the post-update ticks right after the others, and no API call
     * is made for the wait */
    CHECK_EQ(g_pre, 3);
    CHECK_EQ(g_post, 3);
    CHECK_EQ(g_postSawWorld, 2); /* before the world update: there is no "after" without the hook */
    FakeCounts waiting = fake_counts();
    CHECK_EQ(waiting.read + waiting.code_matches + waiting.hook + waiting.log, 0);
    fake_frame_update(1); /* decoded */
    fake_engine_frames(1, 1.0f); /* the callback hooks it, and still ticks this frame (the detour missed its start) */
    CHECK_EQ(vpm_frame_hooked(), 1);
    CHECK_EQ(g_pre, 4);
    CHECK_EQ(g_post, 4);
    fake_engine_frames(4, 1.0f);
    CHECK_EQ(g_pre, 8);
    CHECK_EQ(g_post, 8);
    CHECK_EQ(g_postSawWorld, 8);
}

static void TicksGiveUpTheFrameHookAfterAMinute(void)
{
    FrameReset();
    fake_frame_update(0);
    const VpmComponentDef* defs[] = {&kBoth};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_engine_frames(59, 1.0f);
    CHECK_EQ(vpm_frame_hooked(), 0);
    fake_engine_frames(1, 1.0f);
    CHECK_EQ(vpm_frame_hooked(), -1);
    CHECK_LOG("did not read as shipped within 60 s: ticks stay in HellForge's game-thread callback");
    fake_frame_update(1); /* decoded later: too late, the fallback stays */
    fake_engine_frames(10, 1.0f);
    CHECK_EQ(vpm_frame_hooked(), -1);
    CHECK_EQ(fake_hook_count(), 0);
    CHECK_EQ(g_pre, 70);
    CHECK_EQ(g_post, 70);
    /* the fallback runs ticks once per call of HellForge's callback: twice in a frame where it is called twice */
    fake_double_tick(1);
    fake_engine_frames(1, 1.0f);
    CHECK_EQ(g_pre, 72);
}

static void TicksSurviveARefusedFrameHook(void)
{
    FrameReset();
    fake_frame_update(1);
    HfApi refusing = *fake_api();
    refusing.hook_ex = HookExRefused;
    refusing.last_log = LastLogText;
    const VpmComponentDef* defs[] = {&kBoth};
    CHECK_EQ(vpm_core_init(&refusing, fake_mod(), defs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(vpm_frame_hooked(), -1);
    CHECK_LOG("the game's frame update could not be hooked (more than 16 hooks on one function)");
    fake_engine_frames(3, 0.5f);
    CHECK_EQ(g_pre, 3);
    CHECK_EQ(g_post, 3);
}

static void AFaultingPostTickStopsOnlyItsComponent(void)
{
    FrameReset();
    Reset();
    fake_frame_update(1);
    const VpmComponentDef* defs[] = {&kFaultingPost, &kBoth};
    fake_start(defs, 2);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_engine_frames(4, 0.1f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(vpm_running(fake_component(1)));
    CHECK_EQ(g_stops, 1);
    CHECK_EQ(g_post, 1 + 4); /* the faulting one once, the other every frame */
    CHECK_EQ(g_pre, 4);
}

static int g_lateStart;
static void LateLoad(VpmComponent* self, HfEvent event) { g_lateStart = vpm_tick_start(self, PreTick); }
static int StartLate(VpmComponent* self) { return vpm_on_load(self, HF_EVENT_GAME_LOADED, LateLoad) ? 0 : 1; }
static const VpmComponentDef kLate = {"late", "Late", "1.0", 0, StartLate, NULL};
static int NoGameThread(HfMod* mod, HfTickCallback callback, void* user) { return 0; }

/* Without HellForge's callback: ticks are refused until the frame hook is in, then accepted. */
static void TicksNeedAWayToRun(void)
{
    FrameReset();
    fake_frame_update(1);
    HfApi none = *fake_api();
    none.on_game_thread = NoGameThread;
    const VpmComponentDef* defs[] = {&kBoth, &kLate};
    CHECK_EQ(vpm_core_init(&none, fake_mod(), defs, 2), 0);
    CHECK(!vpm_ticking(fake_component(0)) && !vpm_post_ticking(fake_component(0)));
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(vpm_frame_hooked(), 1);
    CHECK_EQ(g_lateStart, 1);
    fake_engine_frames(2, 0.1f);
    CHECK_EQ(g_pre, 2);
}

static int g_saves;
static void SaveTick(VpmComponent* self, float dt) { if (++g_saves == 1) vpm_option_set(g_flag, 0); }
static int StartSaving(VpmComponent* self) { g_flag = vpm_option(self, &kFlag); vpm_tick_start(self, SaveTick); return 0; }
static const VpmComponentDef kSaving = {"saving", "Saving", "1.0", 0, StartSaving, NULL};

/* The settings countdown runs once per frame under the hook too: a second after a change, the file. */
static void SettingsSaveOncePerFrameUnderTheHook(void)
{
    g_saves = 0;
    fake_frame_update(1);
    const VpmComponentDef* defs[] = {&kSaving};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_double_tick(1);
    fake_engine_frames(1, 0.1f);
    fake_engine_frames(9, 0.1f);
    CHECK(GetFileAttributesW(L"vpm-test-settings.ini") == INVALID_FILE_ATTRIBUTES); /* 0.9 s after the change */
    fake_engine_frames(2, 0.1f);
    CHECK(GetFileAttributesW(L"vpm-test-settings.ini") != INVALID_FILE_ATTRIBUTES);
}

/* ---- the options' registration checks and their numbers, as Mod Options Menu's ----------------------------------- */

static const char* const kOne[] = {"Only", NULL};
static const char* const kSeventeen[] = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", NULL};
static const char* const kLongChoice[] = {"Short", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", NULL}; /* 49 */
static const char* const kTwo[] = {"A", "B", NULL};
#define X10 "xxxxxxxxxx"
#define CJK "\xE6\xBC\xA2" /* one character, three bytes */
static const VpmOptionDef kRefusedOptions[] = {
    {"one", VPM_CHOICE, "One", NULL, 1, 0, 0, 0, kOne},
    {"seventeen", VPM_CHOICE, "Seventeen", NULL, 1, 0, 0, 0, kSeventeen},
    {"long_choice", VPM_CHOICE, "Long choice", NULL, 1, 0, 0, 0, kLongChoice},
    {"choice_default", VPM_CHOICE, "Default", NULL, 3, 0, 0, 0, kTwo},
    {"fine", VPM_SLIDER, "Fine", NULL, 0, 0, 1, 1e-39},
    {"wide", VPM_SLIDER, "Wide", NULL, 0, 0, 3.5e38, 1},
    {"coarse", VPM_SLIDER, "Coarse", NULL, 0, 0, 1, 2},
    {"empty_range", VPM_SLIDER, "Empty", NULL, 1, 1, 1, 0.1},
    {"long", VPM_TOGGLE, X10 X10 X10 X10 X10 X10 "xxxxx", NULL, 0},
    {"wordy", VPM_TOGGLE, "Wordy", X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10
        X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10 "x", 0},
    {"half", VPM_TOGGLE, "Half", NULL, 0.5},
    {"", VPM_TOGGLE, "No id", NULL, 0},
    {"kind", 7, "Kind", NULL, 0},
};
static const char* const kRefusals[] = {
    "option one refused: choices must list 2 to 16 names", "option seventeen refused: choices must list 2 to 16 names",
    "option long_choice refused: invalid choice name", "option choice_default refused: invalid default",
    "option fine refused: slider min, max and step must be finite floats",
    "option wide refused: slider min, max and step must be finite floats",
    "option coarse refused: slider needs min < max and 0 < step <= max - min",
    "option empty_range refused: slider needs min < max and 0 < step <= max - min",
    "option long refused: invalid option registration", "option wordy refused: invalid description",
    "option half refused: invalid default", "option  refused: invalid option registration",
    "option kind refused: type must be toggle, choice or slider",
};
static const VpmOptionDef kAccepted[] = {
    {"cjk", VPM_TOGGLE, CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK
        CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK
        CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK CJK
        CJK CJK CJK CJK, NULL, 1}, /* 64 characters, 192 bytes: fits */
    {"two", VPM_CHOICE, "Two", NULL, 2, 0, 0, 0, kTwo},
    {"tenths", VPM_SLIDER, "Tenths", NULL, 0.6, 0, 1, 0.1},
    {"steps", VPM_SLIDER, "Steps", NULL, 0.2, 0.2, 1.3, 0.05},
    {"unstepped", VPM_SLIDER, "Unstepped", NULL, 3.4, 0, 10, 0},
    {"half_min", VPM_SLIDER, "Half min", NULL, 2, 0.5, 5, 1},
};
static VpmOption* g_accepted[6];
static int g_refusedNull;
static int StartChecking(VpmComponent* self)
{
    g_refusedNull = 0;
    for (int i = 0; i < 13; i++) g_refusedNull += vpm_option(self, &kRefusedOptions[i]) == NULL;
    for (int i = 0; i < 6; i++) g_accepted[i] = vpm_option(self, &kAccepted[i]);
    return 0;
}
static const VpmComponentDef kChecking = {"checking", "Checking", "1.0", 0, StartChecking, NULL};

static void OptionsAreCheckedAsModOptionsMenuChecksThem(void)
{
    const VpmComponentDef* defs[] = {&kChecking};
    fake_start(defs, 1);
    CHECK_EQ(g_refusedNull, 13);
    for (int i = 0; i < 13; i++) CHECK_LOG(kRefusals[i]);
    for (int i = 0; i < 6; i++) CHECK(g_accepted[i] != NULL);
    CHECK_EQ(vpm_option_count(), 6);
    /* the decimals the step needs: no float noise */
    CHECK(vpm_option_value(g_accepted[2]) == 0.6);
    CHECK(vpm_option_set(g_accepted[2], 0.1 + 0.2 + 0.4) && vpm_option_value(g_accepted[2]) == 0.7);
    CHECK(vpm_option_set(g_accepted[3], 0.26) && vpm_option_value(g_accepted[3]) == 0.25);
    CHECK(vpm_option_set(g_accepted[3], 1.29) && vpm_option_value(g_accepted[3]) == 1.3);
    /* no step: Mod Options Menu's 1 */
    CHECK(vpm_option_value(g_accepted[4]) == 3);
    CHECK(vpm_option_set(g_accepted[4], 7.6) && vpm_option_value(g_accepted[4]) == 8);
    /* a min that is not whole: one decimal at least, steps from min */
    CHECK(vpm_option_set(g_accepted[5], 3.2) && vpm_option_value(g_accepted[5]) == 3.5);
    CHECK(!vpm_option_set(g_accepted[5], NAN) && !vpm_option_set(g_accepted[5], INFINITY));
}

static VpmOptionDef g_rows[33];
static char g_rowIds[33][8];
static int g_rowsAccepted;
static int StartRows(VpmComponent* self)
{
    g_rowsAccepted = 0;
    for (int i = 0; i < 33; i++)
    {
        snprintf(g_rowIds[i], 8, "r%d", i);
        g_rows[i] = (VpmOptionDef){g_rowIds[i], VPM_TOGGLE, "Row", NULL, 0};
        g_rowsAccepted += vpm_option(self, &g_rows[i]) != NULL;
    }
    return 0;
}
static const VpmComponentDef kRows = {"rows", "Rows", "1.0", 0, StartRows, NULL};

static void AComponentHoldsThirtyTwoOptions(void)
{
    const VpmComponentDef* defs[] = {&kRows};
    fake_start(defs, 1);
    CHECK_EQ(g_rowsAccepted, 32);
    CHECK_LOG("option rows.r32 refused: the component already has 32 options");
}

static void TheRevisionCountsChangesAndSaveNowWrites(void)
{
    const VpmComponentDef* defs[] = {&kOptions};
    fake_start(defs, 1);
    uint32_t before = vpm_option_revision();
    CHECK(vpm_option_set(g_depth, 1.25)); /* the value it has: no change */
    CHECK_EQ(vpm_option_revision(), before);
    CHECK(vpm_option_apply(g_depth, 2.0));
    CHECK_EQ(vpm_option_revision(), before + 1);
    CHECK(vpm_option_set(g_mode, 2));
    CHECK_EQ(vpm_option_revision(), before + 2);
    CHECK(!vpm_option_set(g_mode, 9));
    CHECK_EQ(vpm_option_revision(), before + 2);
    CHECK(GetFileAttributesW(L"vpm-test-settings.ini") == INVALID_FILE_ATTRIBUTES);
    vpm_settings_save_now();
    CHECK(GetFileAttributesW(L"vpm-test-settings.ini") != INVALID_FILE_ATTRIBUTES);
}

int main(void)
{
    RUN(OptionsAreCheckedAsModOptionsMenuChecksThem);
    RUN(AComponentHoldsThirtyTwoOptions);
    RUN(TheRevisionCountsChangesAndSaveNowWrites);
    RUN(TicksRunAroundTheFrameUpdate);
    RUN(TicksWaitForTheFrameUpdatesCode);
    RUN(TicksGiveUpTheFrameHookAfterAMinute);
    RUN(TicksSurviveARefusedFrameHook);
    RUN(AFaultingPostTickStopsOnlyItsComponent);
    RUN(TicksNeedAWayToRun);
    RUN(SettingsSaveOncePerFrameUnderTheHook);
    RUN(GuardedReadsReadAndRefuse);
    RUN(GuardedReadsSurviveGuardPages);
    RUN(GuardedReadsCopyLargeBlocks);
    RUN(AFailedReadDoesNotStopATick);
    RUN(AMillionGuardedReads);
    RUN(HooksCheckTheBytesAndChain);
    RUN(HooksRefuseOtherBytes);
    RUN(HooksRefuseOutsideTheImage);
    RUN(HooksSayWhyHellForgeRefused);
    RUN(HooksReachTheExe);
    RUN(TheHarnessRunsTheGameAfterTheTickAndStandsInForUser32);
    RUN(TheAvatarSaysWhyAndWhere);
    RUN(PointersAreUserModeOnly);
    RUN(TheHarnessStandsIn);
    RUN(StartsSwitchedOnComponents);
    RUN(RefusesAnOldSdk);
    RUN(StaysOffOnAnotherBuild);
    RUN(SkipsOverlapsWithVanillaPlus);
    RUN(ARefusedStartStaysOff);
    RUN(AFaultingTickStopsOnlyItsComponent);
    RUN(AFaultInStartStopsIt);
    RUN(AFaultingListenerStopsAndOthersHear);
    RUN(AGuardNestsAndManyCallsRun);
    RUN(TicksStopThemselves);
    RUN(OptionsHaveDefaultsAndPersist);
    RUN(SwitchesPersistAndUnknownEntriesStay);
    RUN(BindingsAnswerUnknownWithoutABackend);
    RUN(BindingsAttachInEitherOrder);
    RUN(LookupFindsAndMisses);
    RUN(MemoryReadsAreSafe);
    RUN(ResolvesTheLocalAvatar);
    TEST_END();
}
