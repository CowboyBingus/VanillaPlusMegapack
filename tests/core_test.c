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

static int g_lateAnswer = -1;
static void AsksForAPostTick(VpmComponent* self, float dt) { g_pre++; g_lateAnswer = vpm_post_tick_start(self, PostTick); }
static int StartAsking(VpmComponent* self) { vpm_tick_start(self, AsksForAPostTick); return 0; }
static const VpmComponentDef kAsking = {"asking", "Asking", "1.0", 0, StartAsking, NULL};

/* A refused start answers 0 and registers nothing; ticks already registered keep running, and a start asked for from
 * inside a running tick is refused the same way. */
static void ARefusedTickStartRegistersNothing(void)
{
    FrameReset();
    fake_frame_update(1);
    fake_refuse_ticks(0, 1);
    const VpmComponentDef* defs[] = {&kBoth, &kAsking};
    fake_start(defs, 2);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(vpm_ticking(fake_component(0)) && !vpm_post_ticking(fake_component(0)));
    fake_engine_frames(3, 0.02f);
    CHECK_EQ(g_pre, 3 + 3);
    CHECK_EQ(g_post, 0);
    CHECK_EQ(g_lateAnswer, 0);
    CHECK(!vpm_post_ticking(fake_component(1)));
    fake_refuse_ticks(1, 0); /* registered ticks go on; a new start of either list follows its own setting */
    fake_engine_frames(2, 0.02f);
    CHECK_EQ(g_pre, 6 + 4);
    CHECK_EQ(g_lateAnswer, 1);
    CHECK_EQ(g_post, 2); /* registered in frame 4's tick, it ran after frame 4's update and 5's */
    CHECK_EQ(vpm_tick_start(fake_component(0), PreTick), 0);
    CHECK(vpm_ticking(fake_component(0))); /* a refused start leaves the tick it has */
    fake_refuse_ticks(0, 0);
    CHECK_EQ(vpm_tick_start(fake_component(0), PreTick), 1);
    CHECK(vpm_running(fake_component(0)) && vpm_running(fake_component(1)));
}

/* A game event HellForge refuses: vpm_listen answers 0, the log says which and why, the component runs on and hears
 * nothing; other kinds still subscribe. */
static void ARefusedGameEventIsLogged(void)
{
    Reset();
    fake_refuse_subscribe(HF_ON_SPAWN);
    const VpmComponentDef* defs[] = {&kListening};
    fake_start(defs, 1);
    char line[64];
    snprintf(line, sizeof line, "core: game event %u refused", (unsigned)HF_ON_SPAWN);
    CHECK_LOG(line);
    HfSpawnEvent spawn = {{sizeof spawn, HF_ON_SPAWN, 1}, 1, 2, 3, 1};
    fake_emit(&spawn.info);
    CHECK_EQ(g_events, 0);
    CHECK(vpm_running(fake_component(0)));
    CHECK_EQ(vpm_listen(fake_component(0), HF_ON_KILL, CountEvent, 0), 1);
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

/* ---- text: the Lua text module's UTF-8 (bingus_text.lua v1, its tests test_bingus_text.lua) -------------------- */

/* What bingus_text.lua v1 says about each text: length(), check() for one line and for multiline (1, or -1 invalid
 * UTF-8 / -2 a control character, at a 1-based byte) and upper(). Written by running the Lua module (LuaJIT 2.1) on
 * these texts: first test_bingus_text.lua's own, then the edges (overlong forms, surrogates, U+10FFFF and above, cut
 * sequences, C0 and C1 controls, line feeds, every special case of the upper-case table). */
typedef struct TextCase
{
    const char* text;
    int length, line, line_at, multiline, multiline_at;
    const char* upper;
} TextCase;

static const TextCase kTextCases[] = {
    {"", 0, 1, 0, 1, 0, ""},
    {"A", 1, 1, 0, 1, 0, "A"},
    {"abc xyz 09", 10, 1, 0, 1, 0, "ABC XYZ 09"},
    {"FORECAST // INTEL AND RECON", 27, 1, 0, 1, 0, "FORECAST // INTEL AND RECON"},
    {"\xE9\xA2\x84\xE6\x8A\xA5 // \xE6\x83\x85\xE6\x8A\xA5", 8, 1, 0, 1, 0,
        "\xE9\xA2\x84\xE6\x8A\xA5 // \xE6\x83\x85\xE6\x8A\xA5"},
    {"Semicolons; are fine now", 24, 1, 0, 1, 0, "SEMICOLONS; ARE FINE NOW"},
    {"tab\tstop", 8, -2, 4, -2, 4, "TAB\tSTOP"},
    {"bell\x07", 5, -2, 5, -2, 5, "BELL\x07"},
    {"del\x7F", 4, -2, 4, -2, 4, "DEL\x7F"},
    {"c1 \xC2\x85 next line", 14, -2, 4, -2, 4, "C1 \xC2\x85 NEXT LINE"},
    {"\x1F", 1, -2, 1, -2, 1, "\x1F"},
    {" ", 1, 1, 0, 1, 0, " "},
    {"\xC2\x9F", 1, -2, 1, -2, 1, "\xC2\x9F"},
    {"\xC2\xA0", 1, 1, 0, 1, 0, "\xC2\xA0"},
    {"two\nlines", 9, -2, 4, 1, 0, "TWO\nLINES"},
    {"one two\nthree\n\nfour", 19, -2, 8, 1, 0, "ONE TWO\nTHREE\n\nFOUR"},
    {"\r\n", 2, -2, 1, -2, 1, "\r\n"},
    {"a\n\tb", 4, -2, 2, -2, 3, "A\n\tB"},
    {"\n", 1, -2, 1, 1, 0, "\n"},
    {"ok \x80", 4, -1, 4, -1, 4, "OK \x80"},
    {"ok \xBF", 4, -1, 4, -1, 4, "OK \xBF"},
    {"ok \xC0\x80", 5, -1, 4, -1, 4, "OK \xC0\x80"},
    {"ok \xC1\xBF", 5, -1, 4, -1, 4, "OK \xC1\xBF"},
    {"ok \xE0\x80\x80", 6, -1, 4, -1, 4, "OK \xE0\x80\x80"},
    {"ok \xED\xA0\x80", 6, -1, 4, -1, 4, "OK \xED\xA0\x80"},
    {"ok \xF0\x80\x80\x80", 7, -1, 4, -1, 4, "OK \xF0\x80\x80\x80"},
    {"ok \xF4\x90\x80\x80", 7, -1, 4, -1, 4, "OK \xF4\x90\x80\x80"},
    {"ok \xF5\x80\x80\x80", 7, -1, 4, -1, 4, "OK \xF5\x80\x80\x80"},
    {"ok \xFF", 4, -1, 4, -1, 4, "OK \xFF"},
    {"ok \xE4\xB8", 5, -1, 4, -1, 4, "OK \xE4\xB8"},
    {"ok \xE4", 4, -1, 4, -1, 4, "OK \xE4"},
    {"ok \xC3", 4, -1, 4, -1, 4, "OK \xC3"},
    {"\xE0\x9F\xBF", 3, -1, 1, -1, 1, "\xE0\x9F\xBF"},
    {"\xF0\x8F\xBF\xBF", 4, -1, 1, -1, 1, "\xF0\x8F\xBF\xBF"},
    {"\xED\xBF\xBF", 3, -1, 1, -1, 1, "\xED\xBF\xBF"},
    {"\xED\x9F\xBF", 1, 1, 0, 1, 0, "\xED\x9F\xBF"},
    {"\xEE\x80\x80", 1, 1, 0, 1, 0, "\xEE\x80\x80"},
    {"\xC2\x80", 1, -2, 1, -2, 1, "\xC2\x80"},
    {"\xE0\xA0\x80", 1, 1, 0, 1, 0, "\xE0\xA0\x80"},
    {"\xF0\x90\x80\x80", 1, 1, 0, 1, 0, "\xF0\x90\x80\x80"},
    {"\xF4\x8F\xBF\xBF", 1, 1, 0, 1, 0, "\xF4\x8F\xBF\xBF"},
    {"\xF0\x9F\x98\x80x", 2, 1, 0, 1, 0, "\xF0\x9F\x98\x80X"},
    {"\x80" "abc", 4, -1, 1, -1, 1, "\x80" "ABC"},
    {"abc\xE4\xB8", 5, -1, 4, -1, 4, "ABC\xE4\xB8"},
    {"abc\xF0\x9F\x98", 6, -1, 4, -1, 4, "ABC\xF0\x9F\x98"},
    {"a\xE4" "b", 3, -1, 2, -1, 2, "A\xE4" "B"},
    {"plong\xC3\xA9" "e \xC3\xA0 \xC3\xBF", 11, 1, 0, 1, 0, "PLONG\xC3\x89" "E \xC3\x80 \xC5\xB8"},
    {"\xC5\xBC\xC3\xB3\xC5\x82w \xC4\x87", 6, 1, 0, 1, 0, "\xC5\xBB\xC3\x93\xC5\x81W \xC4\x86"},
    {"\xD0\xBF\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82 \xD1\x91", 8, 1, 0, 1, 0,
        "\xD0\x9F\xD0\xA0\xD0\x98\xD0\x92\xD0\x95\xD0\xA2 \xD0\x81"},
    {"\xCE\xB1\xCF\x82\xCE\xAC", 3, 1, 0, 1, 0, "\xCE\x91\xCE\xA3\xCE\x86"},
    {"\xE4\xB8\xAD" "a\xC3\x9F", 3, 1, 0, 1, 0, "\xE4\xB8\xAD" "A\xC3\x9F"},
    {"bad \xFF x", 7, -1, 5, -1, 5, "BAD \xFF X"},
    {"ALREADY UPPER", 13, 1, 0, 1, 0, "ALREADY UPPER"},
    {"\xC4\xB1\xC5\xBF", 2, 1, 0, 1, 0, "IS"},
    {"\xC3\xB7\xC3\xBE\xC2\xB5", 3, 1, 0, 1, 0, "\xC3\xB7\xC3\x9E\xC2\xB5"},
    {"\xC4\xB0\xC4\xB8\xC5\x89\xC5\x80\xC5\xBE", 5, 1, 0, 1, 0, "\xC4\xB0\xC4\xB8\xC5\x89\xC4\xBF\xC5\xBD"},
    {"\xCF\x82\xCE\xAC\xCE\xAD\xCF\x8C\xCF\x8D\xCF\x8E\xCF\x8B\xCE\x90", 8, 1, 0, 1, 0,
        "\xCE\xA3\xCE\x86\xCE\x88\xCE\x8C\xCE\x8E\xCE\x8F\xCE\xAB\xCE\x90"},
    {"\xD1\x90\xD1\x9F\xD2\x91\xD1\xA3", 4, 1, 0, 1, 0, "\xD0\x80\xD0\x8F\xD2\x90\xD1\xA3"},
    {"multi\nline \xC3\xA9t\xC3\xA9", 14, -2, 6, 1, 0, "MULTI\nLINE \xC3\x89T\xC3\x89"},
};
#define TEXT_CASES (sizeof kTextCases / sizeof kTextCases[0])

/* clip() at every byte count from 0 to the text's length + 1, from the Lua module: test_bingus_text.lua's mixed text,
 * one with 4-, 2- and 1-byte characters, stray continuation bytes, ASCII. */
typedef struct ClipCase { const char* text; int lengths[13]; } ClipCase;
static const ClipCase kClipCases[] = {
    {"ab\xE4\xB8\xAD" "c\xE4\xB8\xAD", {0, 1, 2, 2, 2, 5, 6, 6, 6, 9, 9}},
    {"\xF0\x9F\x98\x80\xC3\xA9" "a\xF4\x8F\xBF\xBF", {0, 0, 0, 0, 4, 4, 6, 7, 7, 7, 7, 11, 11}},
    {"\x80\x80x\xBF", {0, 0, 2, 2, 4, 4}},
    {"abc", {0, 1, 2, 3, 3}},
};

/* Every code point the Lua's upper() changes, with what it becomes (all others stay): from running it over
 * U+0000-U+10FFFF. */
static const uint32_t kUpperPairs[][2] = {
    {0x61, 0x41}, {0x62, 0x42}, {0x63, 0x43}, {0x64, 0x44}, {0x65, 0x45}, {0x66, 0x46}, {0x67, 0x47}, {0x68, 0x48},
    {0x69, 0x49}, {0x6A, 0x4A}, {0x6B, 0x4B}, {0x6C, 0x4C}, {0x6D, 0x4D}, {0x6E, 0x4E}, {0x6F, 0x4F}, {0x70, 0x50},
    {0x71, 0x51}, {0x72, 0x52}, {0x73, 0x53}, {0x74, 0x54}, {0x75, 0x55}, {0x76, 0x56}, {0x77, 0x57}, {0x78, 0x58},
    {0x79, 0x59}, {0x7A, 0x5A}, {0xE0, 0xC0}, {0xE1, 0xC1}, {0xE2, 0xC2}, {0xE3, 0xC3}, {0xE4, 0xC4}, {0xE5, 0xC5},
    {0xE6, 0xC6}, {0xE7, 0xC7}, {0xE8, 0xC8}, {0xE9, 0xC9}, {0xEA, 0xCA}, {0xEB, 0xCB}, {0xEC, 0xCC}, {0xED, 0xCD},
    {0xEE, 0xCE}, {0xEF, 0xCF}, {0xF0, 0xD0}, {0xF1, 0xD1}, {0xF2, 0xD2}, {0xF3, 0xD3}, {0xF4, 0xD4}, {0xF5, 0xD5},
    {0xF6, 0xD6}, {0xF8, 0xD8}, {0xF9, 0xD9}, {0xFA, 0xDA}, {0xFB, 0xDB}, {0xFC, 0xDC}, {0xFD, 0xDD}, {0xFE, 0xDE},
    {0xFF, 0x178}, {0x101, 0x100}, {0x103, 0x102}, {0x105, 0x104}, {0x107, 0x106}, {0x109, 0x108}, {0x10B, 0x10A},
    {0x10D, 0x10C}, {0x10F, 0x10E}, {0x111, 0x110}, {0x113, 0x112}, {0x115, 0x114}, {0x117, 0x116}, {0x119, 0x118},
    {0x11B, 0x11A}, {0x11D, 0x11C}, {0x11F, 0x11E}, {0x121, 0x120}, {0x123, 0x122}, {0x125, 0x124}, {0x127, 0x126},
    {0x129, 0x128}, {0x12B, 0x12A}, {0x12D, 0x12C}, {0x12F, 0x12E}, {0x131, 0x49}, {0x133, 0x132}, {0x135, 0x134},
    {0x137, 0x136}, {0x13A, 0x139}, {0x13C, 0x13B}, {0x13E, 0x13D}, {0x140, 0x13F}, {0x142, 0x141}, {0x144, 0x143},
    {0x146, 0x145}, {0x148, 0x147}, {0x14B, 0x14A}, {0x14D, 0x14C}, {0x14F, 0x14E}, {0x151, 0x150}, {0x153, 0x152},
    {0x155, 0x154}, {0x157, 0x156}, {0x159, 0x158}, {0x15B, 0x15A}, {0x15D, 0x15C}, {0x15F, 0x15E}, {0x161, 0x160},
    {0x163, 0x162}, {0x165, 0x164}, {0x167, 0x166}, {0x169, 0x168}, {0x16B, 0x16A}, {0x16D, 0x16C}, {0x16F, 0x16E},
    {0x171, 0x170}, {0x173, 0x172}, {0x175, 0x174}, {0x177, 0x176}, {0x17A, 0x179}, {0x17C, 0x17B}, {0x17E, 0x17D},
    {0x17F, 0x53}, {0x3AC, 0x386}, {0x3AD, 0x388}, {0x3AE, 0x389}, {0x3AF, 0x38A}, {0x3B1, 0x391}, {0x3B2, 0x392},
    {0x3B3, 0x393}, {0x3B4, 0x394}, {0x3B5, 0x395}, {0x3B6, 0x396}, {0x3B7, 0x397}, {0x3B8, 0x398}, {0x3B9, 0x399},
    {0x3BA, 0x39A}, {0x3BB, 0x39B}, {0x3BC, 0x39C}, {0x3BD, 0x39D}, {0x3BE, 0x39E}, {0x3BF, 0x39F}, {0x3C0, 0x3A0},
    {0x3C1, 0x3A1}, {0x3C2, 0x3A3}, {0x3C3, 0x3A3}, {0x3C4, 0x3A4}, {0x3C5, 0x3A5}, {0x3C6, 0x3A6}, {0x3C7, 0x3A7},
    {0x3C8, 0x3A8}, {0x3C9, 0x3A9}, {0x3CA, 0x3AA}, {0x3CB, 0x3AB}, {0x3CC, 0x38C}, {0x3CD, 0x38E}, {0x3CE, 0x38F},
    {0x430, 0x410}, {0x431, 0x411}, {0x432, 0x412}, {0x433, 0x413}, {0x434, 0x414}, {0x435, 0x415}, {0x436, 0x416},
    {0x437, 0x417}, {0x438, 0x418}, {0x439, 0x419}, {0x43A, 0x41A}, {0x43B, 0x41B}, {0x43C, 0x41C}, {0x43D, 0x41D},
    {0x43E, 0x41E}, {0x43F, 0x41F}, {0x440, 0x420}, {0x441, 0x421}, {0x442, 0x422}, {0x443, 0x423}, {0x444, 0x424},
    {0x445, 0x425}, {0x446, 0x426}, {0x447, 0x427}, {0x448, 0x428}, {0x449, 0x429}, {0x44A, 0x42A}, {0x44B, 0x42B},
    {0x44C, 0x42C}, {0x44D, 0x42D}, {0x44E, 0x42E}, {0x44F, 0x42F}, {0x450, 0x400}, {0x451, 0x401}, {0x452, 0x402},
    {0x453, 0x403}, {0x454, 0x404}, {0x455, 0x405}, {0x456, 0x406}, {0x457, 0x407}, {0x458, 0x408}, {0x459, 0x409},
    {0x45A, 0x40A}, {0x45B, 0x40B}, {0x45C, 0x40C}, {0x45D, 0x40D}, {0x45E, 0x40E}, {0x45F, 0x40F}, {0x491, 0x490},
};
#define UPPER_PAIRS (sizeof kUpperPairs / sizeof kUpperPairs[0])

/* The bytes of one unit of text at text[i]: a character, or one byte that is not valid UTF-8. */
static size_t TextUnit(const char* text, size_t size, size_t i)
{
    uint32_t v;
    int n = vpm_utf8_decode(text + i, size - i, &v);
    return n > 0 ? (size_t)n : 1;
}

static void TextDecodesEveryWellFormedLength(void)
{
    /* test_bingus_text.lua: every well-formed length, encoded back to the same bytes */
    static const struct { const char* bytes; uint32_t value; int length; } good[] = {
        {"A", 0x41, 1}, {"\xC3\xA9", 0xE9, 2}, {"\xE4\xB8\xAD", 0x4E2D, 3}, {"\xF0\x9F\x98\x80", 0x1F600, 4},
        {"\xF4\x8F\xBF\xBF", 0x10FFFF, 4}};
    for (size_t i = 0; i < sizeof good / sizeof good[0]; i++)
    {
        uint32_t v = 0;
        char out[4];
        CHECK_EQ(vpm_utf8_decode(good[i].bytes, strlen(good[i].bytes), &v), good[i].length);
        CHECK_EQ(v, good[i].value);
        CHECK_EQ(vpm_utf8_encode(good[i].value, out), good[i].length);
        CHECK(memcmp(out, good[i].bytes, (size_t)good[i].length) == 0);
    }
    /* and the malformed bytes RFC 3629 forbids: lone continuations, overlong forms, a surrogate, above U+10FFFF, bytes
     * that start nothing, cut sequences; check() refuses them at their byte */
    static const char* const bad[] = {"\x80", "\xBF", "\xC0\x80", "\xC1\xBF", "\xE0\x80\x80", "\xED\xA0\x80",
        "\xF0\x80\x80\x80", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xFF", "\xE4\xB8", "\xE4", "\xC3"};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
    {
        uint32_t v;
        char text[16];
        size_t at = 0;
        CHECK_EQ(vpm_utf8_decode(bad[i], strlen(bad[i]), &v), 0);
        snprintf(text, sizeof text, "ok %s", bad[i]);
        CHECK_EQ(vpm_utf8_check(text, 0, &at), -1);
        CHECK_EQ(at, 4);
    }
    /* nothing to decode: an empty text, a size of 0; a NUL inside the size is U+0000 */
    uint32_t v = 7;
    CHECK_EQ(vpm_utf8_decode("", 0, &v), 0);
    CHECK_EQ(vpm_utf8_decode("A", 0, &v), 0);
    CHECK(vpm_utf8_decode("\0A", 2, &v) == 1 && v == 0);
}

/* The second bytes that start a character with a lead byte (any third and fourth continuation byte): UTF-8's table. */
static int TextSecondBytes(unsigned lead)
{
    if (lead < 0x80) return 256;
    if (lead == 0xE0 || lead == 0xED) return 32; /* no overlong forms below U+0800; no surrogates */
    if (lead == 0xF0) return 48;                 /* no overlong forms below U+10000 */
    if (lead == 0xF4) return 16;                 /* nothing above U+10FFFF */
    return lead >= 0xC2 && lead <= 0xF3 ? 64 : 0; /* C0, C1 only start overlong forms; F5-FF start nothing */
}

static void TextDecodesExactlyTheShortestForms(void)
{
    /* every code point: its shortest form decodes (a surrogate's does not), and one byte short of it nothing does,
     * though the missing byte is there past the size */
    int wrong = 0;
    for (uint32_t c = 0; c <= 0x10FFFF; c++)
    {
        char bytes[4];
        uint32_t v = 0;
        int n = vpm_utf8_encode(c, bytes);
        int length = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
        int expected = c >= 0xD800 && c <= 0xDFFF ? 0 : length;
        if (n != length || vpm_utf8_decode(bytes, (size_t)n, &v) != expected || (expected != 0 && v != c)) wrong++;
        if (vpm_utf8_decode(bytes, (size_t)n - 1, &v) != 0) wrong++;
    }
    CHECK_EQ(wrong, 0);
    /* every lead, second and third byte (with a continuation and a non-continuation fourth): whatever decodes is the
     * shortest form of a code point that is no surrogate, and the second bytes each lead accepts are UTF-8's */
    int seconds[256] = {0};
    for (unsigned b0 = 0; b0 < 256; b0++)
        for (unsigned b1 = 0; b1 < 256; b1++)
            for (unsigned b2 = 0; b2 < 256; b2++)
                for (unsigned b3 = 0x80; b3 <= 0xC0; b3 += 0x40)
                {
                    const unsigned char t[4] = {(unsigned char)b0, (unsigned char)b1, (unsigned char)b2, (unsigned char)b3};
                    char again[4];
                    uint32_t v = 0;
                    int n = vpm_utf8_decode((const char*)t, 4, &v);
                    if (n == 0) continue;
                    if (vpm_utf8_encode(v, again) != n || memcmp(again, t, (size_t)n) != 0) wrong++;
                    if ((v >= 0xD800 && v <= 0xDFFF) || v > 0x10FFFF) wrong++;
                    if (b2 == 0x80 && b3 == 0x80) seconds[b0]++;
                }
    CHECK_EQ(wrong, 0);
    for (unsigned lead = 0; lead < 256; lead++)
        if (seconds[lead] != TextSecondBytes(lead))
        {
            printf("  lead byte %02X starts a character with %d second bytes, expected %d\n", lead, seconds[lead],
                TextSecondBytes(lead));
            wrong++;
        }
    CHECK_EQ(wrong, 0);
}

static void TextChecksWhatAModMayShow(void)
{
    /* as the Lua's check(): any script, no control characters, a line feed only in multiline texts */
    int wrong = 0;
    for (size_t i = 0; i < TEXT_CASES; i++)
    {
        const TextCase* c = &kTextCases[i];
        size_t line_at = 0, multiline_at = 0;
        int line = vpm_utf8_check(c->text, 0, &line_at), multiline = vpm_utf8_check(c->text, 1, &multiline_at);
        if (line != c->line || (line != 1 && line_at != (size_t)c->line_at) || multiline != c->multiline ||
            (multiline != 1 && multiline_at != (size_t)c->multiline_at))
        {
            printf("  text case %u: check %d at %u, multiline %d at %u\n", (unsigned)i, line, (unsigned)line_at,
                multiline, (unsigned)multiline_at);
            wrong++;
        }
    }
    CHECK_EQ(wrong, 0);
    /* every C0 control and DEL between two letters (a line feed passes multiline), every C1 control (U+0080-U+009F),
     * and the characters next to them */
    for (unsigned c = 1; c < 0x100; c++)
    {
        char text[8] = {'x'};
        int n = vpm_utf8_encode(c, text + 1);
        text[1 + n] = 'y';
        text[2 + n] = 0;
        int control = c < 32 || c == 127 || (c >= 0x80 && c < 0xA0);
        size_t at = 0;
        if (vpm_utf8_check(text, 0, &at) != (control ? -2 : 1) || (control && at != 2)) wrong++;
        if (vpm_utf8_check(text, 1, NULL) != (control && c != 10 ? -2 : 1)) wrong++;
    }
    CHECK_EQ(wrong, 0);
    /* no place to put the byte: still the answer */
    CHECK_EQ(vpm_utf8_check("bad\x01", 0, NULL), -2);
    CHECK_EQ(vpm_utf8_check("bad\xFF", 0, NULL), -1);
    /* no text at all, the Lua's check(nil): refused, at byte 0 */
    size_t at = 9;
    CHECK_EQ(vpm_utf8_check(NULL, 0, &at), -1);
    CHECK_EQ(at, 0);
    CHECK_EQ(vpm_utf8_check(NULL, 1, NULL), -1);
    /* test_bingus_text.lua's "nul\0": a C text ends at its NUL, so the check sees "nul" */
    CHECK_EQ(vpm_utf8_check("nul\0", 0, NULL), 1);
}

static void TextLengthCountsCharacters(void)
{
    int wrong = 0;
    for (size_t i = 0; i < TEXT_CASES; i++)
        if (vpm_utf8_length(kTextCases[i].text, strlen(kTextCases[i].text)) != (size_t)kTextCases[i].length)
        {
            printf("  text case %u: length %u\n", (unsigned)i, (unsigned)vpm_utf8_length(kTextCases[i].text,
                strlen(kTextCases[i].text)));
            wrong++;
        }
    CHECK_EQ(wrong, 0);
    /* test_bingus_text.lua */
    const char* zz = "\xE4\xB8\xAD\xE4\xB8\xAD" "a";
    CHECK_EQ(vpm_utf8_length("abc", 3), 3);
    CHECK_EQ(vpm_utf8_length(zz, 7), 3);
    CHECK_EQ(vpm_utf8_length("", 0), 0);
    /* the size bounds the count: a character it cuts counts its bytes one by one, as invalid bytes do */
    CHECK_EQ(vpm_utf8_length(zz, 0), 0);
    CHECK_EQ(vpm_utf8_length(zz, 3), 1);
    CHECK_EQ(vpm_utf8_length(zz, 4), 2);
    CHECK_EQ(vpm_utf8_length(zz, 5), 3);
    CHECK_EQ(vpm_utf8_length(zz, 6), 2);
    /* the size, not a NUL, ends the text */
    CHECK_EQ(vpm_utf8_length("a\0b", 3), 3);
}

static void TextUpperCasesAsTheLua(void)
{
    /* every code point maps as the Lua's upper() maps it */
    size_t next = 0;
    int wrong = 0;
    for (uint32_t v = 0; v <= 0x10FFFF; v++)
    {
        uint32_t expected = v;
        if (next < UPPER_PAIRS && kUpperPairs[next][0] == v) expected = kUpperPairs[next++][1];
        if (vpm_upper_char(v) != expected && wrong++ < 8) printf("  U+%04X upper case U+%04X\n", v, vpm_upper_char(v));
    }
    CHECK_EQ(wrong, 0);
    CHECK_EQ(next, UPPER_PAIRS);
    /* and in text: each changed character's bytes become its upper case's bytes */
    for (size_t i = 0; i < UPPER_PAIRS; i++)
    {
        char text[8], expected[8], out[8];
        text[vpm_utf8_encode(kUpperPairs[i][0], text)] = 0;
        expected[vpm_utf8_encode(kUpperPairs[i][1], expected)] = 0;
        if (vpm_upper(text, out, sizeof out) != strlen(expected) || strcmp(out, expected) != 0) wrong++;
    }
    CHECK_EQ(wrong, 0);
    /* the texts: test_bingus_text.lua's (Latin-1, Polish, Cyrillic, Greek with final sigma and tonos, CJK and sharp s
     * unchanged, invalid bytes kept, never re-encoded) and the edges */
    for (size_t i = 0; i < TEXT_CASES; i++)
    {
        char out[256];
        size_t n = vpm_upper(kTextCases[i].text, out, sizeof out);
        if (n != strlen(kTextCases[i].upper) || strcmp(out, kTextCases[i].upper) != 0)
        {
            printf("  text case %u: upper case of %u bytes\n", (unsigned)i, (unsigned)n);
            wrong++;
        }
    }
    CHECK_EQ(wrong, 0);
}

/* Whether out (n bytes) is the longest start of whole that ends between units and leaves room for the terminator. */
static int TextLongestWholeStart(const char* whole, size_t total, const char* out, size_t n, size_t size)
{
    if (n >= size || out[n] != 0 || memcmp(out, whole, n) != 0) return 0;
    size_t edge = 0;
    while (edge < n) edge += TextUnit(whole, total, edge);
    return edge == n && (edge == total || edge + TextUnit(whole, total, edge) >= size);
}

static void TextUpperNeverCutsACharacter(void)
{
    /* every case at every output size: the longest start of its upper case that cuts no character (an invalid byte is
     * one unit), terminated; nothing written at size 0 */
    int wrong = 0;
    for (size_t i = 0; i < TEXT_CASES; i++)
    {
        char whole[256];
        size_t total = vpm_upper(kTextCases[i].text, whole, sizeof whole);
        for (size_t size = 0; size <= total + 2; size++)
        {
            char out[256];
            memset(out, '#', sizeof out);
            size_t n = vpm_upper(kTextCases[i].text, out, size);
            int ok = size == 0 ? n == 0 && out[0] == '#' : TextLongestWholeStart(whole, total, out, n, size);
            if (!ok && wrong++ < 8) printf("  text case %u at %u bytes: %u bytes\n", (unsigned)i, (unsigned)size, (unsigned)n);
        }
    }
    CHECK_EQ(wrong, 0);
    /* a full buffer by hand: three 2-byte letters, a 4-byte character, a letter that shrinks, an invalid byte */
    char out[16];
    CHECK(vpm_upper("\xC3\xA9\xC3\xA9\xC3\xA9", out, 7) == 6 && strcmp(out, "\xC3\x89\xC3\x89\xC3\x89") == 0);
    CHECK(vpm_upper("\xC3\xA9\xC3\xA9\xC3\xA9", out, 6) == 4 && strcmp(out, "\xC3\x89\xC3\x89") == 0);
    CHECK(vpm_upper("\xC3\xA9\xC3\xA9\xC3\xA9", out, 5) == 4 && strcmp(out, "\xC3\x89\xC3\x89") == 0);
    CHECK(vpm_upper("\xC3\xA9\xC3\xA9\xC3\xA9", out, 2) == 0 && out[0] == 0);
    CHECK(vpm_upper("\xF0\x9F\x98\x80", out, 4) == 0 && out[0] == 0);
    CHECK(vpm_upper("\xF0\x9F\x98\x80", out, 5) == 4 && strcmp(out, "\xF0\x9F\x98\x80") == 0);
    CHECK(vpm_upper("a\xC4\xB1", out, 2) == 1 && strcmp(out, "A") == 0);
    CHECK(vpm_upper("a\xC4\xB1", out, 3) == 2 && strcmp(out, "AI") == 0);
    CHECK(vpm_upper("a\xFF", out, 2) == 1 && strcmp(out, "A") == 0);
    CHECK(vpm_upper("a\xFF", out, 3) == 2 && strcmp(out, "A\xFF") == 0);
    CHECK(vpm_upper("", out, 1) == 0 && out[0] == 0);
}

static void TextClipKeepsWholeCharacters(void)
{
    /* the Lua's clip() at every byte count */
    int wrong = 0;
    for (size_t i = 0; i < sizeof kClipCases / sizeof kClipCases[0]; i++)
    {
        size_t n = strlen(kClipCases[i].text);
        for (size_t cap = 0; cap <= n + 1; cap++)
            if (vpm_utf8_clip(kClipCases[i].text, cap) != (size_t)kClipCases[i].lengths[cap])
            {
                printf("  clip case %u at %u: %u\n", (unsigned)i, (unsigned)cap,
                    (unsigned)vpm_utf8_clip(kClipCases[i].text, cap));
                wrong++;
            }
    }
    CHECK_EQ(wrong, 0);
    /* test_bingus_text.lua: within the cap, valid, a start of the text, and every whole character that fits kept */
    const char* mixed = "ab\xE4\xB8\xAD" "c\xE4\xB8\xAD";
    size_t n = strlen(mixed);
    for (size_t cap = 0; cap <= n + 2; cap++)
    {
        char start[16];
        size_t clipped = vpm_utf8_clip(mixed, cap);
        memcpy(start, mixed, clipped);
        start[clipped] = 0;
        CHECK(clipped <= cap && vpm_utf8_check(start, 0, NULL) == 1);
        for (size_t edge = 0; edge <= n; edge += edge < n ? TextUnit(mixed, n, edge) : 1)
            if (edge <= cap) CHECK(clipped >= edge);
    }
    CHECK_EQ(vpm_utf8_clip("", 0), 0);
    CHECK_EQ(vpm_utf8_clip("", 4), 0);
    CHECK_EQ(vpm_utf8_clip("abc", 3), 3);
}

static int StartPlain(VpmComponent* self) { return 0; }
static const VpmComponentDef kFolders = {"folder_user", "Folder User", "1.0", 0, StartPlain, NULL};

static void AComponentGetsADataFolder(void)
{
    const VpmComponentDef* defs[] = {&kFolders};
    fake_start(defs, 1);
    wchar_t path[MAX_PATH];
    CHECK(vpm_data_folder(fake_component(0), path, MAX_PATH));
    CHECK(wcscmp(path, L"vpm-test-data\\folder_user") == 0);
    CHECK((GetFileAttributesW(path) & FILE_ATTRIBUTE_DIRECTORY) != 0 && GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES);
    CHECK(vpm_data_folder(fake_component(0), path, MAX_PATH)); /* already there */
    wchar_t tiny[8];
    CHECK(!vpm_data_folder(fake_component(0), tiny, 8)); /* does not fit */
    CHECK(tiny[0] == 0);
}

static int g_exeCalls;
static int ExeStandIn(int x) { g_exeCalls++; return x - 1; }

static void ExeCodeChecksAndStandIns(void)
{
    const VpmComponentDef* defs[] = {&kFolders};
    fake_start(defs, 1);
    fake_stand_in_exe(0x31AF50, "40 53 48 83 EC 20 48 8B D9 E8 11 22 33 44", (void*)&ExeStandIn);
    CHECK(vpm_exe_code_matches(0x31AF50, "40 53 48 83 EC 20 48 8B D9"));
    CHECK(!vpm_exe_code_matches(0x31AF50, "40 53 48 83 EC 30"));
    CHECK(!vpm_exe_code_matches(FAKE_EXE_SIZE + 4, "40"));
    CHECK(!vpm_game_code_matches(0x31AF50, "40 53 48 83 EC 20")); /* the exe's stand-in, not game.dll's */
    int (*fn)(int) = (int (*)(int))(void*)(vpm_exe() + 0x31AF50);
    CHECK_EQ(fn(10), 9);
    CHECK_EQ(g_exeCalls, 1);
}

/* ---- code checks that wait for game.dll's code to be decoded --------------------------------------------------- */

static const char kPinA[] = "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 8B FA";
static const char kPinB[] = "40 53 48 83 EC 20 48 8B D9 E8 11 22 33 44";
static const VpmCodePin kGamePins[] = {{0x111000, kPinA, "first function", 0}, {0x222000, kPinB, "second function", 0}};
static const VpmCodePin kExePins[] = {{0x333000, kPinA, "exe function", VPM_PIN_EXE}};
static int g_readyRuns, g_readyFault;
static HfEvent g_readyEvent;
static void Ready(VpmComponent* self, HfEvent event)
{
    g_readyRuns++;
    g_readyEvent = event;
    if (g_readyFault) (void)*g_null;
}
static int StartWaiting(VpmComponent* self) { return vpm_when_code_ready(self, kGamePins, 2, Ready) ? 0 : 1; }
static int StartWaitingExe(VpmComponent* self) { return vpm_when_code_ready(self, kExePins, 1, Ready) ? 0 : 1; }
static const VpmComponentDef kWaiting = {"waiting", "Waiting", "1.0", 0, StartWaiting, NULL};
static const VpmComponentDef kWaitingExe = {"waiting_exe", "Waiting Exe", "1.0", 0, StartWaitingExe, NULL};

static void LayPin(uint8_t* image, uint32_t rva, const char* pattern)
{
    for (const char* p = pattern; *p;)
    {
        if (*p == ' ') { p++; continue; }
        char hex[3] = {p[0], p[1], 0};
        image[rva++] = (uint8_t)strtol(hex, NULL, 16);
        p += 2;
    }
}

static void ReadyAtOnceWhenDecoded(void)
{
    g_readyRuns = g_readyFault = 0;
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA);
    LayPin((uint8_t*)fake_game(), 0x222000, kPinB);
    const VpmComponentDef* defs[] = {&kWaiting};
    fake_start(defs, 1);
    CHECK_EQ(g_readyRuns, 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(g_readyRuns, 1);
    CHECK(g_readyEvent == HF_EVENT_GAME_LOADED);
    fake_counts_reset();
    fake_frames(120, 1.0f / 60);
    CHECK_EQ(g_readyRuns, 1);
    CHECK_EQ(fake_counts().code_matches, 0); /* nothing more once ready */
}

static void ReadyOnceTheCodeIsDecoded(void)
{
    g_readyRuns = g_readyFault = 0;
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA); /* the second one is still encoded */
    const VpmComponentDef* defs[] = {&kWaiting};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(g_readyRuns, 0);
    fake_counts_reset();
    fake_frames(29, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches, 0); /* a look every 30 frames */
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches, 2); /* the first matches, the second not */
    LayPin((uint8_t*)fake_game(), 0x222000, kPinB);
    fake_frames(29, 1.0f / 60);
    CHECK_EQ(g_readyRuns, 0);
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(g_readyRuns, 1);
    CHECK(vpm_running(fake_component(0)));
    fake_counts_reset();
    fake_frames(300, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches, 0);
    CHECK_EQ(g_readyRuns, 1);
}

static void StoppedWhenTheCodeNeverMatches(void)
{
    g_readyRuns = g_readyFault = 0;
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA);
    const VpmComponentDef* defs[] = {&kWaiting};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_frames(59, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(1, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_EQ(g_readyRuns, 0);
    CHECK_LOG("[Waiting] disabled: second function changed (game.dll 0x222000)");
    fake_counts_reset();
    fake_frames(60, 1.0f);
    CHECK_EQ(fake_counts().code_matches, 0);
}

static void ExePinsAreTheExes(void)
{
    g_readyRuns = g_readyFault = 0;
    LayPin((uint8_t*)fake_game(), 0x333000, kPinA); /* in game.dll: not the exe's */
    const VpmComponentDef* defs[] = {&kWaitingExe};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(g_readyRuns, 0);
    LayPin((uint8_t*)fake_exe(), 0x333000, kPinA);
    fake_frames(30, 1.0f / 60);
    CHECK_EQ(g_readyRuns, 1);
}

static VpmComponent* g_lateWaiter;
static int StartLateWaiter(VpmComponent* self) { g_lateWaiter = self; return 0; }
static const VpmComponentDef kLateWaiter = {"late_waiter", "Late Waiter", "1.0", 0, StartLateWaiter, NULL};

static void ARegistrationAfterTheEventIsLookedAtAtOnce(void)
{
    g_readyRuns = g_readyFault = 0;
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA);
    LayPin((uint8_t*)fake_game(), 0x222000, kPinB);
    const VpmComponentDef* defs[] = {&kLateWaiter};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(vpm_when_code_ready(g_lateWaiter, kGamePins, 2, Ready));
    CHECK_EQ(g_readyRuns, 1);
    CHECK(!vpm_when_code_ready(g_lateWaiter, NULL, 0, Ready));
}

static void AStoppedComponentNeverGetsReady(void)
{
    g_readyRuns = g_readyFault = 0;
    const VpmComponentDef* defs[] = {&kWaiting};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    vpm_core_stop(fake_component(0), "test");
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA);
    LayPin((uint8_t*)fake_game(), 0x222000, kPinB);
    fake_counts_reset();
    fake_frames(90, 1.0f / 60);
    CHECK_EQ(g_readyRuns, 0);
    CHECK_EQ(fake_counts().code_matches, 0);
}

static void AFaultInReadyStopsTheComponent(void)
{
    g_readyRuns = 0;
    g_readyFault = 1;
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA);
    LayPin((uint8_t*)fake_game(), 0x222000, kPinB);
    const VpmComponentDef* defs[] = {&kWaiting};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    g_readyFault = 0;
    CHECK_EQ(g_readyRuns, 1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Waiting] disabled: fault 0xC0000005");
}

static void WaitsOfSeveralComponents(void)
{
    g_readyRuns = g_readyFault = 0;
    LayPin((uint8_t*)fake_game(), 0x111000, kPinA);
    LayPin((uint8_t*)fake_game(), 0x222000, kPinB);
    const VpmComponentDef* defs[] = {&kWaiting, &kWaitingExe};
    fake_start(defs, 2);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(g_readyRuns, 1); /* game.dll's pins match; the exe's never do */
    fake_frames(60, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    CHECK(!vpm_running(fake_component(1)));
    CHECK_LOG("[Waiting Exe] disabled: exe function changed (helldivers2.exe 0x333000)");
}

static void NothingWaitingCostsNothing(void)
{
    const VpmComponentDef* defs[] = {&kTicking};
    fake_start(defs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_counts_reset();
    fake_frames(600, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches + fake_counts().read, 0);
}

int main(void)
{
    RUN(ReadyAtOnceWhenDecoded);
    RUN(ReadyOnceTheCodeIsDecoded);
    RUN(StoppedWhenTheCodeNeverMatches);
    RUN(ExePinsAreTheExes);
    RUN(ARegistrationAfterTheEventIsLookedAtAtOnce);
    RUN(AStoppedComponentNeverGetsReady);
    RUN(AFaultInReadyStopsTheComponent);
    RUN(WaitsOfSeveralComponents);
    RUN(NothingWaitingCostsNothing);
    RUN(AComponentGetsADataFolder);
    RUN(ExeCodeChecksAndStandIns);
    RUN(OptionsAreCheckedAsModOptionsMenuChecksThem);
    RUN(AComponentHoldsThirtyTwoOptions);
    RUN(TheRevisionCountsChangesAndSaveNowWrites);
    RUN(TicksRunAroundTheFrameUpdate);
    RUN(TicksWaitForTheFrameUpdatesCode);
    RUN(TicksGiveUpTheFrameHookAfterAMinute);
    RUN(TicksSurviveARefusedFrameHook);
    RUN(AFaultingPostTickStopsOnlyItsComponent);
    RUN(TicksNeedAWayToRun);
    RUN(ARefusedTickStartRegistersNothing);
    RUN(ARefusedGameEventIsLogged);
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
    RUN(TextDecodesEveryWellFormedLength);
    RUN(TextDecodesExactlyTheShortestForms);
    RUN(TextChecksWhatAModMayShow);
    RUN(TextLengthCountsCharacters);
    RUN(TextUpperCasesAsTheLua);
    RUN(TextUpperNeverCutsACharacter);
    RUN(TextClipKeepsWholeCharacters);
    TEST_END();
}
