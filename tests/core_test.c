/* The core: start-up, switches, the crash guard, ticks, listeners, options, the settings file, bindings, the game's
 * lookup and the local avatar. */
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

int main(void)
{
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
