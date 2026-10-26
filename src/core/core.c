/* The pack's entry and its components' lifecycle: settings, the build check, starting each switched-on component, and
 * the one registration of each kind (load events, the game-thread tick, game events) that the core makes with HellForge
 * for the whole pack and passes on.
 *
 * Per frame (the frame update's detour, or HellForge's game-thread callback until it is in): the frame's settings
 * countdown (one compare while nothing waits to be saved), then each ticking component's tick under one guard, and after
 * game.dll's update each post-update tick, with two time-stamp counter reads around each (the per-component cost the
 * log reports at a mission's end). No Windows call and no allocation per frame. */
#include <intrin.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "vpm_core.h"

static const HfApi* g_hf;
static HfMod* g_mod;
static VpmComponent g_components[VPM_MAX_COMPONENTS];
static int g_componentCount;
static void CoreLog(const char* format, ...) __attribute__((format(printf, 1, 2)));

typedef struct LoadReg { VpmComponent* component; HfEvent event; VpmLoadFn fn; } LoadReg;
typedef struct ListenReg { VpmComponent* component; VpmListenFn fn; } ListenReg;
static LoadReg g_loads[VPM_MAX_LOADS];
static int g_loadCount;
static ListenReg g_listens[VPM_MAX_LISTENS];
static int g_listenCount;

static uint64_t g_frames;      /* frames this mission */
static uint64_t g_tscStart;    /* the time-stamp counter and performance counter when the mission started */
static LARGE_INTEGER g_qpcStart;

const HfApi* vpm_hf(void) { return g_hf; }
const HfApi* vpm_core_hf(void) { return g_hf; }
HfMod* vpm_mod(void) { return g_mod; }
const VpmComponentDef* vpm_def(const VpmComponent* self) { return self->def; }
int vpm_running(const VpmComponent* self) { return self != NULL && self->state == VPM_STATE_RUNNING; }
const char* vpm_status(const VpmComponent* self) { return self->status; }
int vpm_component_count(void) { return g_componentCount; }
VpmComponent* vpm_component_at(int index) { return index >= 0 && index < g_componentCount ? &g_components[index] : NULL; }
int vpm_component_switched_on(const VpmComponent* component) { return component->switched_on; }

static void LogV(VpmComponent* self, const char* format, va_list args)
{
    char line[1024];
    vsnprintf(line, sizeof line, format, args);
    if (self != NULL) g_hf->log(g_mod, "[%s] %s", self->def->name, line); /* lint-ok: C4 components log on frames that act only (each one's review) */
    else g_hf->log(g_mod, "%s", line); /* lint-ok: C4 the core logs at start-up, a stop and a mission's end */
}

void vpm_log(VpmComponent* self, const char* format, ...)
{
    va_list args;
    va_start(args, format);
    LogV(self, format, args);
    va_end(args);
}

static void CoreLog(const char* format, ...)
{
    va_list args;
    va_start(args, format);
    LogV(NULL, format, args);
    va_end(args);
}

void vpm_set_status(VpmComponent* self, const char* status)
{
    if (self->state != VPM_STATE_RUNNING) return;
    snprintf(self->status, sizeof self->status, "%s", status != NULL ? status : "running");
}

typedef struct StopCall { VpmComponent* component; } StopCall;
static void RunStop(void* arg) { VpmComponent* c = ((StopCall*)arg)->component; c->def->stop(c); }

void vpm_core_stop(VpmComponent* component, const char* reason)
{
    if (component->state == VPM_STATE_STOPPED) return;
    int started = component->started;
    component->state = VPM_STATE_STOPPED;
    component->tick = NULL;
    component->post_tick = NULL;
    snprintf(component->status, sizeof component->status, "disabled: %s", reason);
    vpm_log(component, "disabled: %s", reason);
    if (started && component->def->stop != NULL)
    {
        StopCall call = {component};
        VpmFault fault;
        if (vpm_guard_call(RunStop, &call, &fault) != 0)
        {
            char text[160];
            vpm_fault_text(&fault, text, sizeof text);
            vpm_log(component, "its stop did not finish: %s", text);
        }
    }
}

int vpm_fail(VpmComponent* self, const char* format, ...)
{
    char reason[VPM_STATUS_SIZE];
    va_list args;
    va_start(args, format);
    vsnprintf(reason, sizeof reason, format, args);
    va_end(args);
    vpm_core_stop(self, reason);
    return 1;
}

int vpm_guarded(VpmComponent* self, void (*fn)(void*), void* arg) { return vpm_core_guarded(self, fn, arg); }

int vpm_guarded_off_thread(void (*fn)(void*), void* arg, char* fault, size_t size)
{
    VpmFault caught;
    if (vpm_guard_call(fn, arg, &caught) == 0) return 1;
    if (fault != NULL && size > 0) vpm_fault_text(&caught, fault, size);
    return 0;
}

int vpm_core_guarded(VpmComponent* component, void (*fn)(void*), void* arg)
{
    VpmFault fault;
    if (vpm_guard_call(fn, arg, &fault) == 0) return 1;
    char text[160];
    vpm_fault_text(&fault, text, sizeof text);
    vpm_core_stop(component, text);
    return 0;
}

/* ---- load events ------------------------------------------------------------------------------------------------- */

typedef struct LoadCall { LoadReg* reg; HfEvent event; } LoadCall;
static void RunLoad(void* arg) { LoadCall* call = arg; call->reg->fn(call->reg->component, call->event); }

static void LoadTrampoline(HfMod* mod, HfEvent event, void* user)
{
    LoadReg* reg = user;
    if (!vpm_running(reg->component)) return;
    LoadCall call = {reg, event};
    vpm_core_guarded(reg->component, RunLoad, &call);
}

int vpm_on_load(VpmComponent* self, HfEvent event, VpmLoadFn fn)
{
    if (g_loadCount >= VPM_MAX_LOADS) { vpm_log(self, "core: no room for another load event"); return 0; }
    LoadReg* reg = &g_loads[g_loadCount++];
    *reg = (LoadReg){self, event, fn};
    if (g_hf->on(g_mod, event, LoadTrampoline, reg) != 0) { vpm_log(self, "core: load event %d refused", (int)event); return 0; }
    return 1;
}

/* ---- game events ------------------------------------------------------------------------------------------------- */

typedef struct ListenCall { ListenReg* reg; const HfEventInfo* event; } ListenCall;
static void RunListen(void* arg) { ListenCall* call = arg; call->reg->fn(call->reg->component, call->event); }

static void ListenTrampoline(HfMod* mod, const HfEventInfo* event, void* user)
{
    ListenReg* reg = user;
    if (!vpm_running(reg->component)) return;
    ListenCall call = {reg, event};
    vpm_core_guarded(reg->component, RunListen, &call);
}

int vpm_listen(VpmComponent* self, uint32_t kind, VpmListenFn fn, int32_t priority)
{
    if (g_listenCount >= VPM_MAX_LISTENS) { vpm_log(self, "core: no room for another listener"); return 0; }
    ListenReg* reg = &g_listens[g_listenCount++];
    *reg = (ListenReg){self, fn};
    if (!g_hf->subscribe(g_mod, kind, ListenTrampoline, reg, priority))
    {
        vpm_log(self, "core: game event %u refused (%s)", kind, g_hf->last_log(g_mod));
        return 0;
    }
    return 1;
}

/* ---- the game-thread ticks --------------------------------------------------------------------------------------- *
 * Two lists of ticking components, in start order: the ticks at the start of game.dll's frame update, and the
 * post-update ticks after it. A stop clears a component's slot; a list is compacted after the frame ran it. g_tickList,
 * g_tickAt and g_tickCurrent live in memory: after a fault the guard resumes in RunTicks, which goes on from the next.
 *
 * Where they run: the core hooks game.dll's whole-frame update (VPM_FRAME_UPDATE, called once per frame by the engine
 * right after the Lua update: KB squad-join-pipeline-research section 1) and runs the ticks before it and the post-update
 * ticks after it. Until that hook is in (game.dll's code is decoded in parts after HF_EVENT_GAME_LOADED), or if it is
 * given up, both run from HellForge's game-thread callback, which HellForge hooks on the menu sound manager's update
 * inside the same frame update (game.dll 0x13270B0, called at 0xAB4BE7). That function also has a second caller, in
 * the late update (0x13F8938, another sound manager): once the frame hook is in, the callback does nothing, so the
 * ticks run exactly once per frame whether HellForge's callback runs once or twice. */

#define LIST_PRE 0
#define LIST_POST 1
typedef struct TickList { VpmComponent* items[VPM_MAX_COMPONENTS]; int count; } TickList;
static TickList g_lists[2];
static volatile int g_tickList;
static volatile int g_tickAt;
static VpmComponent* volatile g_tickCurrent;
static int g_tickHooked;     /* HellForge's game-thread callback registered */
static int g_frameState;     /* the frame hook: 0 not yet, 1 in, -1 given up */
static float g_frameWaited;  /* seconds of game-thread callbacks while waiting for the frame update's code */
typedef void (*FrameUpdateFn)(void* game, float dt);
static FrameUpdateFn g_frameOriginal;

int vpm_frame_hooked(void) { return g_frameState; }

static VpmTickFn* Slot(VpmComponent* c, int list) { return list == LIST_PRE ? &c->tick : &c->post_tick; }

static int TickStart(VpmComponent* self, int list, VpmTickFn fn)
{
    /* Ticks need a way to run: HellForge's game-thread callback (it also retries the frame hook), or the hook itself. */
    if ((!g_tickHooked && g_frameState != 1) || !vpm_running(self) || fn == NULL) return 0;
    if (vpm_test_tick_refused(list == LIST_POST)) return 0;
    TickList* l = &g_lists[list];
    int listed = 0;
    for (int i = 0; i < l->count; i++) listed |= l->items[i] == self;
    if (!listed)
    {
        if (l->count >= VPM_MAX_COMPONENTS) return 0; /* cannot happen: one entry per component */
        l->items[l->count++] = self;
    }
    *Slot(self, list) = fn;
    return 1;
}

int vpm_tick_start(VpmComponent* self, VpmTickFn fn) { return TickStart(self, LIST_PRE, fn); }
void vpm_tick_stop(VpmComponent* self) { self->tick = NULL; }
int vpm_ticking(const VpmComponent* self) { return self->tick != NULL; }
int vpm_post_tick_start(VpmComponent* self, VpmTickFn fn) { return TickStart(self, LIST_POST, fn); }
void vpm_post_tick_stop(VpmComponent* self) { self->post_tick = NULL; }
int vpm_post_ticking(const VpmComponent* self) { return self->post_tick != NULL; }

typedef struct TickCall { float dt; } TickCall;

static void RunTickList(void* arg)
{
    float dt = ((TickCall*)arg)->dt;
    TickList* l = &g_lists[g_tickList];
    while (g_tickAt < l->count)
    {
        VpmComponent* c = l->items[g_tickAt];
        g_tickCurrent = c;
        VpmTickFn fn = *Slot(c, g_tickList);
        if (fn != NULL)
        {
            uint64_t start = __rdtsc();
            fn(c, dt);
            c->cycles += __rdtsc() - start;
            c->calls++;
        }
        g_tickAt = g_tickAt + 1;
    }
}

static void CompactTicks(int list)
{
    TickList* l = &g_lists[list];
    int kept = 0;
    for (int i = 0; i < l->count; i++)
        if (*Slot(l->items[i], list) != NULL) l->items[kept++] = l->items[i];
    l->count = kept;
}

/* One list's ticks under one guard; a fault stops the component it happened in and the list goes on from the next. */
static void RunTicks(int list, float dt)
{
    TickList* l = &g_lists[list];
    if (l->count == 0) return;
    TickCall call = {dt};
    g_tickList = list;
    g_tickAt = 0;
    while (g_tickAt < l->count)
    {
        VpmFault fault;
        if (vpm_guard_call(RunTickList, &call, &fault) == 0) break;
        char text[160];
        vpm_fault_text(&fault, text, sizeof text);
        vpm_core_stop(g_tickCurrent, text);
        g_tickAt = g_tickAt + 1;
    }
    for (int i = 0; i < l->count; i++)
        if (*Slot(l->items[i], list) == NULL) { CompactTicks(list); break; }
}

static void CodeWaitsTick(float dt);

static void PreFrame(float dt)
{
    g_frames++;
    vpm_settings_tick(dt);
    CodeWaitsTick(dt);
    RunTicks(LIST_PRE, dt);
}

static void PostFrame(float dt) { RunTicks(LIST_POST, dt); }

/* The frame update's detour: the ticks, game.dll's whole update, the post-update ticks. lint: per-frame */
static void FrameDetour(void* game, float dt)
{
    PreFrame(dt);
    g_frameOriginal(game, dt);
    PostFrame(dt);
}

/* The frame update's first bytes as shipped (VPM_FRAME_UPDATE_CODE), for the cheap check while it is not decoded yet. */
static const uint8_t kFrameBytes[] = VPM_FRAME_UPDATE_BYTES;

static void HookFrame(void)
{
    if (g_hf->hook_ex(g_mod, vpm_game() + VPM_FRAME_UPDATE, (void*)FrameDetour, (void**)&g_frameOriginal, 0) != 0)
    {
        g_frameState = -1;
        CoreLog("the game's frame update could not be hooked (%s): ticks stay in HellForge's game-thread callback", g_hf->last_log(g_mod));
        return;
    }
    g_frameState = 1;
    CoreLog("ticks run at the start and the end of the game's frame update (game.dll 0x%X)", VPM_FRAME_UPDATE);
}

/* Hooks the frame update once game.dll's code there is decoded (it is decoded in parts after HF_EVENT_GAME_LOADED).
 * Tried at that event, then at each game-thread callback: a plain-load compare of its first bytes with the shipped ones
 * (no call, no API read), and the hook as soon as they match: bytes as shipped mean no other hook is there either.
 * After VPM_FRAME_WAIT_SECONDS without them (still not decoded, or another mod hooked it first) it is given up and the
 * ticks stay in HellForge's callback. */
static void TryFrameHook(float waited)
{
    if (g_frameState != 0 || vpm_game() == 0) return;
    uint8_t now[sizeof kFrameBytes];
    if (vpm_game_read(VPM_FRAME_UPDATE, now, sizeof now) && memcmp(now, kFrameBytes, sizeof now) == 0)
    {
        HookFrame();
        return;
    }
    if (waited < VPM_FRAME_WAIT_SECONDS) return;
    g_frameState = -1;
    CoreLog("the game's frame update (game.dll 0x%X) did not read as shipped within %.0f s: ticks stay in HellForge's game-thread callback",
        VPM_FRAME_UPDATE, VPM_FRAME_WAIT_SECONDS);
}

/* HellForge's game-thread callback: the ticks until the frame hook is in (both lists, the post-update ticks right after
 * the others), nothing afterwards. */
static void PackTick(HfMod* mod, float dt, void* user)
{
    if (g_frameState == 1) return;
    if (g_frameState == 0)
    {
        g_frameWaited += dt;
        TryFrameHook(g_frameWaited);
    }
    PreFrame(dt);
    PostFrame(dt);
}

/* ---- code checks that wait for game.dll's code (vpm_when_code_ready) -------------------------------------------- */

#define MAX_CODE_WAITS 64
#define CODE_CHECK_FRAMES 30
typedef struct CodeWait
{
    VpmComponent* component;
    const VpmCodePin* pins;
    int count;
    VpmLoadFn ready;
    int done;         /* ready ran, or the component was stopped */
} CodeWait;
static CodeWait g_codeWaits[MAX_CODE_WAITS];
static int g_codeWaitCount, g_codeWaitsOpen, g_codeLoaded, g_codeFrames;
static float g_codeWaited;

/* The first pin that does not read as shipped now, or -1. */
static int FirstUnready(const CodeWait* w)
{
    for (int i = 0; i < w->count; i++)
    {
        const VpmCodePin* p = &w->pins[i];
        int ok = (p->flags & VPM_PIN_EXE) ? vpm_exe_code_matches(p->rva, p->pattern) : vpm_game_code_matches(p->rva, p->pattern);
        if (!ok) return i;
    }
    return -1;
}

typedef struct ReadyCall { CodeWait* wait; } ReadyCall;
static void RunReady(void* arg) { CodeWait* w = ((ReadyCall*)arg)->wait; w->ready(w->component, HF_EVENT_GAME_LOADED); }

/* One look at a wait: ready when every pin matches, stopped when the time is up, else it goes on waiting. */
static void LookAt(CodeWait* w, int final)
{
    if (w->done) return;
    if (!vpm_running(w->component)) { w->done = 1; g_codeWaitsOpen--; return; }
    int unready = FirstUnready(w);
    if (unready < 0)
    {
        w->done = 1;
        g_codeWaitsOpen--;
        ReadyCall call = {w};
        vpm_core_guarded(w->component, RunReady, &call);
        return;
    }
    if (!final) return;
    w->done = 1;
    g_codeWaitsOpen--;
    const VpmCodePin* p = &w->pins[unready];
    vpm_fail(w->component, "%s changed (%s 0x%X)", p->name, (p->flags & VPM_PIN_EXE) ? "helldivers2.exe" : "game.dll", p->rva);
}

int vpm_when_code_ready(VpmComponent* self, const VpmCodePin* pins, int count, VpmLoadFn ready)
{
    if (g_codeWaitCount >= MAX_CODE_WAITS || pins == NULL || count <= 0 || ready == NULL)
    {
        vpm_log(self, "core: code checks refused (%d registered of %d)", g_codeWaitCount, MAX_CODE_WAITS);
        return 0;
    }
    CodeWait* w = &g_codeWaits[g_codeWaitCount++];
    *w = (CodeWait){self, pins, count, ready, 0};
    g_codeWaitsOpen++;
    if (g_codeLoaded) LookAt(w, 0);
    return 1;
}

/* At HF_EVENT_GAME_LOADED: every wait looked at once. A wait a ready registers during the pass was looked at by its
 * registration: the pass covers only those registered before it. */
static void CodeWaitsLoaded(void)
{
    g_codeLoaded = 1;
    int count = g_codeWaitCount;
    for (int i = 0; i < count; i++) LookAt(&g_codeWaits[i], 0);
}

/* Per frame while a wait is open: the time, and a look every CODE_CHECK_FRAMES frames. */
static void CodeWaitsTick(float dt)
{
    if (g_codeWaitsOpen <= 0 || !g_codeLoaded) return;
    g_codeWaited += dt;
    int final = g_codeWaited >= VPM_CODE_WAIT_SECONDS;
    if (++g_codeFrames % CODE_CHECK_FRAMES != 0 && !final) return;
    int count = g_codeWaitCount; /* as at the event: one registered during the pass was looked at by its registration */
    for (int i = 0; i < count; i++) LookAt(&g_codeWaits[i], final);
}

/* ---- costs: per component, at each mission's end --------------------------------------------------------------- */

static void CostsStart(void)
{
    g_frames = 0;
    g_tscStart = __rdtsc();
    QueryPerformanceCounter(&g_qpcStart); /* lint-ok: C4 once per mission, at its start */
    for (int i = 0; i < g_componentCount; i++) g_components[i].cycles = g_components[i].calls = 0;
}

static void CostsReport(void)
{
    LARGE_INTEGER now, frequency;
    QueryPerformanceCounter(&now); /* lint-ok: C4 once per mission, at its end */
    QueryPerformanceFrequency(&frequency); /* lint-ok: C4 once per mission, at its end */
    double seconds = (double)(now.QuadPart - g_qpcStart.QuadPart) / (double)frequency.QuadPart;
    double cyclesPerMs = seconds > 0 ? (double)(__rdtsc() - g_tscStart) / (seconds * 1000.0) : 0;
    if (cyclesPerMs <= 0 || g_frames == 0) return;
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        if (c->calls == 0) continue;
        double ms = (double)c->cycles / cyclesPerMs / (double)g_frames;
        CoreLog("cost this mission: %s %.4f ms per frame (%llu ticks over %llu frames)", c->def->name, ms,
            (unsigned long long)c->calls, (unsigned long long)g_frames);
    }
}

static void CoreMissionStart(HfMod* mod, const HfEventInfo* event, void* user) { CostsStart(); }
static void CoreMissionEnd(HfMod* mod, const HfEventInfo* event, void* user) { CostsReport(); vpm_settings_flush(); }

/* ---- start-up ---------------------------------------------------------------------------------------------------- */

static void CodeWaitsLoaded(void);

static void CoreGameLoaded(HfMod* mod, HfEvent event, void* user)
{
    vpm_memory_game_loaded();
    TryFrameHook(0);
    CodeWaitsLoaded();
}

static int VanillaPlusInSession(void)
{
    for (uint32_t i = 0;; i++)
    {
        HfModInfo info;
        memset(&info, 0, sizeof info);
        info.size = sizeof info;
        if (!g_hf->mods(g_mod, i, &info)) return 0;
        if (info.kind == HF_MOD_CODE && info.id != NULL && strcmp(info.id, "skyeshade.vanilla-plus") == 0) return 1;
    }
}

void vpm_component_switch(VpmComponent* component, int on)
{
    component->switched_on = on != 0;
    vpm_setting_put("components", component->def->id, on ? "on" : "off");
    vpm_settings_save_soon();
}

typedef struct StartCall { VpmComponent* component; int result; } StartCall;
static void RunStart(void* arg) { StartCall* call = arg; call->result = call->component->def->start(call->component); }

static void StartComponent(VpmComponent* c, int buildOk, int vanillaPlus)
{
    if (!c->switched_on) { snprintf(c->status, sizeof c->status, "off"); return; }
    if (!buildOk) { snprintf(c->status, sizeof c->status, "off: needs game build %s", VPM_GAME_BUILD); return; }
    if (vanillaPlus && (c->def->flags & VPM_OVERLAPS_VANILLA_PLUS))
    {
        snprintf(c->status, sizeof c->status, "off: HellForge's Vanilla Plus is on and changes the same thing");
        vpm_log(c, "%s", c->status);
        return;
    }
    c->state = VPM_STATE_RUNNING;
    snprintf(c->status, sizeof c->status, "running");
    StartCall call = {c, 1};
    if (!vpm_core_guarded(c, RunStart, &call)) return;
    if (call.result != 0)
    {
        if (c->state == VPM_STATE_RUNNING) vpm_core_stop(c, "start refused");
        return;
    }
    if (c->state == VPM_STATE_RUNNING) c->started = 1;
}

static void LogSummary(void)
{
    int running = 0;
    for (int i = 0; i < g_componentCount; i++) running += g_components[i].state == VPM_STATE_RUNNING;
    CoreLog("%d of %d components running", running, g_componentCount);
    for (int i = 0; i < g_componentCount; i++)
        CoreLog("  %s v%s: %s", g_components[i].def->name, g_components[i].def->version, g_components[i].status);
}

static void HookCore(void)
{
    g_tickHooked = g_hf->on_game_thread(g_mod, PackTick, NULL);
    if (!g_tickHooked) CoreLog("the game thread could not be reached (%s): components that tick stay idle", g_hf->last_log(g_mod));
    if (g_hf->on(g_mod, HF_EVENT_GAME_LOADED, CoreGameLoaded, NULL) != 0) CoreLog("game.dll's load event refused: components see it as absent");
    if (!g_hf->subscribe(g_mod, HF_ON_MISSION_START, CoreMissionStart, NULL, 0) ||
        !g_hf->subscribe(g_mod, HF_ON_MISSION_END, CoreMissionEnd, NULL, 0))
        CoreLog("mission events refused (%s): no per-mission cost report", g_hf->last_log(g_mod));
}

int vpm_core_init(const HfApi* api, HfMod* mod, const VpmComponentDef* const* defs, int count)
{
    g_hf = api;
    g_mod = mod;
    if (api->version < 15 || api->size < sizeof(HfApi))
    {
        api->log(mod, "Vanilla Plus Megapack needs HellForge mod SDK 15 or newer (this HellForge has %u)", api->version);
        return 1;
    }
    vpm_guard_install();
    vpm_memory_init();
    vpm_user32_init();
    vpm_settings_load();
    int buildOk = strcmp(api->build_id(), VPM_GAME_BUILD) == 0;
    int vanillaPlus = VanillaPlusInSession();
    CoreLog("%s for game build %s (this game: %s)%s", VPM_PACK_NAME, VPM_GAME_BUILD, api->build_id(),
        vanillaPlus ? "; HellForge's Vanilla Plus is in this session" : "");
    HookCore();
    g_componentCount = count < VPM_MAX_COMPONENTS ? count : VPM_MAX_COMPONENTS;
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        memset(c, 0, sizeof *c);
        c->def = defs[i];
        c->index = i;
        const char* saved = vpm_setting("components", c->def->id);
        c->switched_on = saved != NULL ? strcmp(saved, "off") != 0 : !(c->def->flags & VPM_DEFAULT_OFF);
    }
    for (int i = 0; i < g_componentCount; i++) StartComponent(&g_components[i], buildOk, vanillaPlus);
    LogSummary();
    return 0;
}

void vpm_core_reset(void)
{
    memset(g_components, 0, sizeof g_components);
    g_componentCount = g_loadCount = g_listenCount = g_tickHooked = g_frameState = 0;
    memset(g_lists, 0, sizeof g_lists);
    g_tickList = g_tickAt = 0;
    g_tickCurrent = NULL;
    g_frameWaited = 0;
    g_frameOriginal = NULL;
    memset(g_codeWaits, 0, sizeof g_codeWaits);
    g_codeWaitCount = g_codeWaitsOpen = g_codeLoaded = g_codeFrames = 0;
    g_codeWaited = 0;
    g_frames = 0;
    vpm_options_reset();
    vpm_bindings_reset();
}

/* ---- Windows functions found at run time ------------------------------------------------------------------------- */

static VpmUser32 g_user32;
const VpmUser32* vpm_user32(void) { return &g_user32; }
void vpm_user32_set(const VpmUser32* table) { g_user32 = *table; }

void vpm_user32_init(void)
{
    HMODULE user32 = GetModuleHandleA("user32.dll");
    if (user32 == NULL) user32 = LoadLibraryA("user32.dll");
    if (user32 == NULL) return;
    g_user32.GetAsyncKeyState = (short(__stdcall*)(int))(void*)GetProcAddress(user32, "GetAsyncKeyState");
    g_user32.GetCursorPos = (int(__stdcall*)(void*))(void*)GetProcAddress(user32, "GetCursorPos");
    g_user32.GetForegroundWindow = (void*(__stdcall*)(void))(void*)GetProcAddress(user32, "GetForegroundWindow");
    g_user32.ScreenToClient = (int(__stdcall*)(void*, void*))(void*)GetProcAddress(user32, "ScreenToClient");
    g_user32.GetClientRect = (int(__stdcall*)(void*, void*))(void*)GetProcAddress(user32, "GetClientRect");
    g_user32.GetWindowThreadProcessId =
        (unsigned long(__stdcall*)(void*, unsigned long*))(void*)GetProcAddress(user32, "GetWindowThreadProcessId");
}

const char* vpm_text(const VpmComponent* self, const char* key, const char* english) { return english; }

#ifndef VPM_TEST
HF_MOD_EXPORT int hellforge_mod_init(const HfApi* api, HfMod* mod)
{
    return vpm_core_init(api, mod, vpm_components, vpm_component_total);
}
#endif
