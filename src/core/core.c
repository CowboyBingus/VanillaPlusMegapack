/* The pack's entry and its components' lifecycle: settings, the build check, starting each switched-on component, and
 * the one registration of each kind (load events, the game-thread tick, game events) that the core makes with HellForge
 * for the whole pack and passes on.
 *
 * Per frame (the frame update's detour, or HellForge's game-thread callback until it is in): the frame's settings
 * countdown (one compare while nothing waits to be saved), then each ticking component's tick under one guard, and after
 * game.dll's update each post-update tick, with two time-stamp counter reads around each (the per-component cost the
 * log reports at a mission's end), one bit scan and an increment for the tick-time histogram, and one compare for the
 * slow-tick count. Per tick list that
 * has ticks: the thread's call record set and put back (two thread-local copies, for the fault line and the crash
 * breadcrumb) and one compare of the status-line flag. One compare of the live-switch flag (a switch or HellForge's
 * change of mods waits for the frame; added for live switches). No Windows call, no log call and no allocation per frame.
 *
 * Live switches (vpm.h): a switch the player changes is noted and applied at the start of the next frame, on the game
 * thread, outside every component's callback (Mod Options Menu applies from its own tick). Each start is a new
 * generation of the component: every registration it makes (load events, listeners, code waits) carries it, and one
 * made by an earlier generation never fires again. Its slot is reused, so switching on and off adds no registrations
 * with HellForge: the core holds one load-event callback per event for the pack and delivers it to the components'
 * registrations itself, and a dead subscription of the same kind and priority is taken over. */
#include <intrin.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "vpm_core.h"

static const HfApi* g_hf;
static HfMod* g_mod;
static VpmComponent g_components[VPM_MAX_COMPONENTS];
static int g_componentCount;
static int g_initialized;      /* vpm_core_init ran and no unload came since */
static int g_buildOk;          /* the game's build is the one the pack was made for */
static int g_vanillaPlus;      /* HellForge's own Vanilla Plus is in the session */
static VpmLive g_live;         /* HellForge's live mods, when its HfApi offers them */
/* The live switches' work for the next frame (one compare per frame while none waits): bit 0 a switch, bit 1 HellForge's
 * mods changed (its HF_EVENT_MODS_CHANGED, on the loader's change thread). */
#define WORK_SWITCH 0x1L
#define WORK_MODS 0x2L
static volatile LONG g_switchWork;
/* Load events arrive on HellForge's watch thread, live switches run on the game thread: one at a time. */
static SRWLOCK g_lifeLock = SRWLOCK_INIT;

/* A load event registration: dead once its generation is not the component's running one. pending: the event had fired
 * when it was made from start(), so it is delivered when start() returns. dispatch: the core's delivery it was made in
 * (that delivery skips it: it was delivered at once). */
typedef struct LoadReg { VpmComponent* component; uint32_t generation; HfEvent event; VpmLoadFn fn; int pending; uint32_t dispatch; } LoadReg;
/* A game event subscription: HellForge keeps it for the session; dead registrations of the same kind and priority are
 * taken over by the next vpm_listen. subscribed: HellForge accepted it. */
typedef struct ListenReg { VpmComponent* component; uint32_t generation; VpmListenFn fn; uint32_t kind; int32_t priority; int subscribed; } ListenReg;
static LoadReg g_loads[VPM_MAX_LOADS];
static int g_loadCount;
static ListenReg g_listens[VPM_MAX_LISTENS];
static int g_listenCount;

static uint64_t g_frame;       /* frames this session: one increment per frame */
static uint64_t g_missionFrame; /* g_frame when the mission started */
static uint64_t g_tscStart;    /* the time-stamp counter and performance counter when the mission started */
static LARGE_INTEGER g_qpcStart;
static uint64_t g_tscInit;     /* the same at the pack's start: the counter's rate before the first mission ends */
static LARGE_INTEGER g_qpcInit;
static uint64_t g_slowCycles = UINT64_MAX; /* VPM_SLOW_TICK_MS in counter cycles (none counted until it is known) */
static int g_starting;         /* vpm_core_init is running the components' start() */

uint64_t vpm_core_frame(void) { return g_frame; }
int vpm_core_starting(void) { return g_starting; }

int vpm_core_alive(const VpmComponent* c, uint32_t generation)
{
    return c != NULL && c->state == VPM_STATE_RUNNING && c->generation == generation;
}
const VpmLive* vpm_core_live(void) { return &g_live; }
const char* vpm_component_next_session(const VpmComponent* component) { return component->def->next_session; }

const HfApi* vpm_hf(void) { return g_hf; }
const HfApi* vpm_core_hf(void) { return g_hf; }
HfMod* vpm_mod(void) { return g_mod; }
const VpmComponentDef* vpm_def(const VpmComponent* self) { return self->def; }
int vpm_running(const VpmComponent* self) { return self != NULL && self->state == VPM_STATE_RUNNING; }
const char* vpm_status(const VpmComponent* self) { return self->status; }
int vpm_component_count(void) { return g_componentCount; }
VpmComponent* vpm_component_at(int index) { return index >= 0 && index < g_componentCount ? &g_components[index] : NULL; }
int vpm_component_switched_on(const VpmComponent* component) { return component->switched_on; }

/* "[Name] text" for a component, "[core] text" for the core (NULL or its own record). */
static void LogV(VpmComponent* self, const char* format, va_list args)
{
    char line[1024];
    vsnprintf(line, sizeof line, format, args);
    /* A component's own line that carries its new status says it already: no core status line for it. */
    if (self != NULL && self->status_pending && strstr(line, self->status) != NULL) self->status_pending = 0;
    if (self != NULL && self != vpm_pack()) g_hf->log(g_mod, "[%s] %s", self->def->name, line); /* lint-ok: C4 components log on frames that act only (each one's review) */
    else g_hf->log(g_mod, "[core] %s", line); /* lint-ok: C4 the core logs at start-up, a stop, a status change, a mission's end and a mark */
}

void vpm_log(VpmComponent* self, const char* format, ...)
{
    va_list args;
    va_start(args, format);
    LogV(self, format, args);
    va_end(args);
}

void vpm_core_log(const char* format, ...)
{
    va_list args;
    va_start(args, format);
    LogV(NULL, format, args);
    va_end(args);
}

/* Status lines. A new text is noted; when the callback that set it ends (the outermost one on the thread: a tick list,
 * a listener, a load event...), the core logs it (rate-limited, diag.c) unless the component's own log line meanwhile
 * carried the text (most components log their state changes themselves). The same text again changes nothing. Cost: a
 * compare of the texts per call (the copy was there before); one global compare at the end of each tick list and each
 * outermost guarded callback. */
static int g_statusPending;

void vpm_set_status(VpmComponent* self, const char* status)
{
    if (self->state != VPM_STATE_RUNNING) return;
    const char* text = status != NULL ? status : "running";
    if (strncmp(self->status, text, sizeof self->status - 1) == 0) return;
    snprintf(self->status, sizeof self->status, "%s", text);
    if (g_starting || self == vpm_pack()) return; /* the start-up summary lists every status */
    self->status_pending = 1;
    g_statusPending = 1;
}

void vpm_core_status_lines(void)
{
    if (!g_statusPending) return;
    g_statusPending = 0;
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        if (!c->status_pending) continue;
        c->status_pending = 0;
        vpm_diag_status(c);
    }
}

typedef struct StopCall { VpmComponent* component; } StopCall;
static void RunStop(void* arg) { VpmComponent* c = ((StopCall*)arg)->component; c->def->stop(c); }

/* Its stop(), guarded, when start() had returned 0; then its hooks (taken out with HellForge's live mods). 0 when the
 * stop faulted (what it changed may be left). */
static int RunStopGuarded(VpmComponent* component, int started)
{
    int finished = 1;
    if (started && component->def->stop != NULL)
    {
        StopCall call = {component};
        VpmFault fault;
        VpmCall was = vpm_call_enter(component, VPM_CALL_STOP, 0);
        DWORD code = vpm_guard_call(RunStop, &call, &fault);
        vpm_call_leave(was);
        if (code != 0)
        {
            char text[VPM_STATUS_SIZE];
            vpm_fault_text(&fault, text, sizeof text);
            vpm_diag_fault(&fault);
            vpm_log(component, "its stop did not finish: %s", text);
            finished = 0;
        }
    }
    vpm_hooks_component_off(component);
    return finished;
}

void vpm_core_stop(VpmComponent* component, const char* reason)
{
    if (component->state == VPM_STATE_STOPPED) return;
    int started = component->started;
    component->state = VPM_STATE_STOPPED;
    component->started = 0;
    component->tick = NULL;
    component->post_tick = NULL;
    snprintf(component->status, sizeof component->status, "disabled: %s", reason);
    vpm_log(component, "disabled: %s", reason);
    (void)RunStopGuarded(component, started); /* a fault in it is logged */
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

int vpm_guarded(VpmComponent* self, void (*fn)(void*), void* arg) { return vpm_core_guarded(self, VPM_CALL_GUARDED, 0, fn, arg); }

/* A worker's fault: counted, and its text says "in its worker thread"; the component reports it from the game thread. */
int vpm_guarded_off_thread(void (*fn)(void*), void* arg, char* fault, size_t size)
{
    VpmFault caught;
    VpmCall was = vpm_call_enter(NULL, VPM_CALL_WORKER, 0);
    DWORD code = vpm_guard_call(fn, arg, &caught);
    vpm_call_leave(was);
    if (code == 0) return 1;
    vpm_diag_worker_fault();
    if (fault != NULL && size > 0) vpm_fault_text(&caught, fault, size);
    return 0;
}

/* A fault the core took on the game thread: its number, registers and return addresses, then the stop. */
static void FaultStop(VpmComponent* component, VpmFault* fault)
{
    fault->call.component = component;
    char text[VPM_STATUS_SIZE];
    vpm_fault_text(fault, text, sizeof text);
    vpm_diag_fault(fault);
    vpm_core_stop(component, text);
}

int vpm_core_guarded(VpmComponent* component, uint32_t kind, uint32_t detail, void (*fn)(void*), void* arg)
{
    VpmFault fault;
    VpmCall was = vpm_call_enter(component, kind, detail);
    DWORD code = vpm_guard_call(fn, arg, &fault);
    vpm_call_leave(was);
    if (code != 0) FaultStop(component, &fault);
    if (was.kind == VPM_CALL_NONE && g_statusPending) vpm_core_status_lines();
    return code == 0;
}

/* ---- load events ------------------------------------------------------------------------------------------------- *
 * The core registers once per event with HellForge (HookCore) and delivers each to the components' registrations in
 * registration order, as HellForge would have. It remembers which events fired and in which order, so a component
 * started later (a live switch-on) gets them as at boot: right after its start() returns. */

#define FIRST_LOAD HF_EVENT_GAME_LOADED
#define LAST_LOAD HF_EVENT_PROJECTILES_READY
static int g_eventOk[LAST_LOAD + 1];   /* HellForge accepted the core's registration of the event */
static int g_fired[LAST_LOAD + 1];
static HfEvent g_firedOrder[LAST_LOAD];
static int g_firedCount;
static uint32_t g_loadDispatch;        /* counts the core's deliveries of an event */
static int g_loadWalks;                /* a walk over the registrations runs (a delivery): they must not move */

typedef struct LoadCall { LoadReg* reg; HfEvent event; } LoadCall;
static void RunLoad(void* arg) { LoadCall* call = arg; call->reg->fn(call->reg->component, call->event); }

static void DeliverLoad(LoadReg* reg, HfEvent event)
{
    reg->pending = 0;
    if (!vpm_core_alive(reg->component, reg->generation)) return;
    LoadCall call = {reg, event};
    vpm_core_guarded(reg->component, VPM_CALL_LOAD, (uint32_t)event, RunLoad, &call);
}

/* A slot for a new registration, at the end so that deliveries keep registration order: the dead ones are dropped
 * first (the live ones keep their order), unless a delivery is walking the table; then, when it is full, a dead one's
 * slot. NULL when none is free. */
static LoadReg* LoadSlot(void)
{
    if (g_loadWalks == 0)
    {
        int kept = 0;
        for (int i = 0; i < g_loadCount; i++)
            if (vpm_core_alive(g_loads[i].component, g_loads[i].generation)) g_loads[kept++] = g_loads[i];
        g_loadCount = kept;
    }
    if (g_loadCount < VPM_MAX_LOADS) return &g_loads[g_loadCount++];
    for (int i = 0; i < g_loadCount; i++)
        if (!vpm_core_alive(g_loads[i].component, g_loads[i].generation)) return &g_loads[i];
    return NULL;
}

int vpm_on_load(VpmComponent* self, HfEvent event, VpmLoadFn fn)
{
    if ((int)event < FIRST_LOAD || (int)event > LAST_LOAD || !g_eventOk[event] || fn == NULL)
    {
        vpm_log(self, "core: load event %d refused", (int)event);
        return 0;
    }
    LoadReg* reg = LoadSlot();
    if (reg == NULL) { vpm_log(self, "core: no room for another load event"); return 0; }
    *reg = (LoadReg){self, self->generation, event, fn, 0, g_loadDispatch};
    if (!g_fired[event]) return 1;
    if (self->in_start) { reg->pending = 1; return 1; } /* delivered when its start() returns (DeliverPast) */
    g_loadWalks++;
    DeliverLoad(reg, event);
    g_loadWalks--;
    return 1;
}

static void CoreGameLoaded(void);

/* HellForge's load event (on its watch thread, or right after a live init): the core's own work at game.dll's load,
 * then every registration of the event made before this delivery. */
static void CoreLoadEvent(HfMod* mod, HfEvent event, void* user)
{
    if ((int)event < FIRST_LOAD || (int)event > LAST_LOAD) return;
    AcquireSRWLockExclusive(&g_lifeLock); /* lint-ok: C4 a load event: a handful per session */
    if (!g_fired[event]) { g_fired[event] = 1; g_firedOrder[g_firedCount++] = event; }
    uint32_t dispatch = ++g_loadDispatch;
    if (event == HF_EVENT_GAME_LOADED) CoreGameLoaded();
    int count = g_loadCount;
    g_loadWalks++;
    for (int i = 0; i < count; i++)
        if (g_loads[i].event == event && g_loads[i].dispatch != dispatch) DeliverLoad(&g_loads[i], event);
    g_loadWalks--;
    ReleaseSRWLockExclusive(&g_lifeLock); /* lint-ok: C4 a load event: a handful per session */
}

static void CodeWaitsLook(VpmComponent* c);

/* After a start() that returned 0: the events that fired before it, in the order the game fired them; at
 * HF_EVENT_GAME_LOADED its code waits are looked at first, as the core looks at every wait before that event's
 * callbacks. */
static void DeliverPast(VpmComponent* c)
{
    g_loadWalks++;
    for (int e = 0; e < g_firedCount && vpm_running(c); e++)
    {
        HfEvent event = g_firedOrder[e];
        if (event == HF_EVENT_GAME_LOADED) CodeWaitsLook(c);
        for (int i = 0; i < g_loadCount && vpm_running(c); i++)
            if (g_loads[i].component == c && g_loads[i].pending && g_loads[i].event == event) DeliverLoad(&g_loads[i], event);
    }
    g_loadWalks--;
}

/* ---- game events ------------------------------------------------------------------------------------------------- */

typedef struct ListenCall { ListenReg* reg; const HfEventInfo* event; } ListenCall;
static void RunListen(void* arg) { ListenCall* call = arg; call->reg->fn(call->reg->component, call->event); }

/* A game event's delivery: a compare of the generation for a dead registration. lint: per-frame */
static void ListenTrampoline(HfMod* mod, const HfEventInfo* event, void* user)
{
    ListenReg* reg = user;
    if (!vpm_core_alive(reg->component, reg->generation)) return;
    ListenCall call = {reg, event};
    vpm_core_guarded(reg->component, VPM_CALL_LISTENER, reg->kind, RunListen, &call);
}

/* A dead subscription of this kind and priority to take over (the component's own first), or NULL. */
static ListenReg* DeadListen(VpmComponent* self, uint32_t kind, int32_t priority)
{
    ListenReg* any = NULL;
    for (int i = 0; i < g_listenCount; i++)
    {
        ListenReg* reg = &g_listens[i];
        if (!reg->subscribed || reg->kind != kind || reg->priority != priority || vpm_core_alive(reg->component, reg->generation)) continue;
        if (reg->component == self) return reg;
        if (any == NULL) any = reg;
    }
    return any;
}

int vpm_listen(VpmComponent* self, uint32_t kind, VpmListenFn fn, int32_t priority)
{
    ListenReg* dead = fn != NULL ? DeadListen(self, kind, priority) : NULL;
    if (dead != NULL)
    {
        dead->component = self;
        dead->generation = self->generation;
        dead->fn = fn;
        return 1;
    }
    if (g_listenCount >= VPM_MAX_LISTENS) { vpm_log(self, "core: no room for another listener"); return 0; }
    ListenReg* reg = &g_listens[g_listenCount++];
    *reg = (ListenReg){self, self->generation, fn, kind, priority, 0};
    if (!g_hf->subscribe(g_mod, kind, ListenTrampoline, reg, priority))
    {
        vpm_log(self, "core: game event %u refused (%s)", kind, g_hf->last_log(g_mod));
        return 0;
    }
    reg->subscribed = 1;
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
VpmComponent* vpm_core_tick_component(void) { return g_tickCurrent; }

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
            uint64_t spent = __rdtsc() - start;
            c->cycles += spent;
            /* The tick-time histogram and the slow count for the mission-end report (alpha diagnostics, KB
             * megapack-alpha-diagnostics-plan item 7: a spike hides in an average, and a single largest tick is decided
             * by one interruption of the thread). One bit scan, one increment, one compare per tick. */
            int bucket = 63 - __builtin_clzll(spent | 1);
            c->buckets[bucket < VPM_COST_BUCKETS ? bucket : VPM_COST_BUCKETS - 1]++;
            if (spent >= g_slowCycles) c->slow++;
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

/* One list's ticks under one guard; a fault stops the component it happened in and the list goes on from the next.
 * The thread's call record says "tick" for the whole list (its component is g_tickCurrent): two thread-local copies per
 * list per frame, none per tick. */
static void RunTicks(int list, float dt)
{
    TickList* l = &g_lists[list];
    if (l->count == 0) return;
    TickCall call = {dt};
    g_tickList = list;
    g_tickAt = 0;
    VpmCall was = vpm_call_enter(NULL, list == LIST_PRE ? VPM_CALL_TICK : VPM_CALL_POST_TICK, 0);
    while (g_tickAt < l->count)
    {
        VpmFault fault;
        if (vpm_guard_call(RunTickList, &call, &fault) == 0) break;
        FaultStop(g_tickCurrent, &fault);
        g_tickAt = g_tickAt + 1;
    }
    vpm_call_leave(was);
    if (g_statusPending) vpm_core_status_lines();
    for (int i = 0; i < l->count; i++)
        if (*Slot(l->items[i], list) == NULL) { CompactTicks(list); break; }
}

static void CodeWaitsTick(float dt);
static void SwitchWork(void);

static void PreFrame(float dt)
{
    g_frame++;
    if (g_switchWork != 0) SwitchWork();
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
        vpm_core_log("the game's frame update could not be hooked (%s): ticks stay in HellForge's game-thread callback", g_hf->last_log(g_mod));
        return;
    }
    g_frameState = 1;
    vpm_core_log("ticks run at the start and the end of the game's frame update (game.dll 0x%X)", VPM_FRAME_UPDATE);
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
    vpm_core_log("the game's frame update (game.dll 0x%X) did not read as shipped within %.0f s: ticks stay in HellForge's game-thread callback",
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
    int done;         /* ready ran, or the component was stopped: the slot is free again */
    uint32_t generation; /* the component's start that registered it */
    int pending;      /* registered from start() after HF_EVENT_GAME_LOADED: looked at when start() returns */
} CodeWait;
static CodeWait g_codeWaits[MAX_CODE_WAITS];
static int g_codeWaitCount, g_codeWaitsOpen, g_codeLoaded, g_codeFrames;
static int g_codePass; /* a pass over the waits runs (at the event, or a frame's look) */
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
    if (!vpm_core_alive(w->component, w->generation)) { w->done = 1; g_codeWaitsOpen--; return; }
    int unready = FirstUnready(w);
    if (unready < 0)
    {
        w->done = 1;
        g_codeWaitsOpen--;
        ReadyCall call = {w};
        vpm_core_guarded(w->component, VPM_CALL_READY, 0, RunReady, &call);
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
    CodeWait* w = NULL;
    /* A finished wait's slot (a component switched on again); not during a pass, which would look at it again. */
    for (int i = 0; i < g_codeWaitCount && w == NULL && !g_codePass; i++)
        if (g_codeWaits[i].done) w = &g_codeWaits[i];
    if (w == NULL && g_codeWaitCount < MAX_CODE_WAITS && pins != NULL && count > 0 && ready != NULL) w = &g_codeWaits[g_codeWaitCount++];
    if (w == NULL || pins == NULL || count <= 0 || ready == NULL)
    {
        vpm_log(self, "core: code checks refused (%d registered of %d)", g_codeWaitCount, MAX_CODE_WAITS);
        return 0;
    }
    *w = (CodeWait){self, pins, count, ready, 0, self->generation, 0};
    g_codeWaitsOpen++;
    if (!g_codeLoaded) return 1;
    if (self->in_start) w->pending = 1; /* looked at when its start() returns (DeliverPast) */
    else LookAt(w, 0);
    return 1;
}

/* A component's waits registered during its start(), after HF_EVENT_GAME_LOADED: looked at now (DeliverPast). */
static void CodeWaitsLook(VpmComponent* c)
{
    int count = g_codeWaitCount;
    for (int i = 0; i < count && vpm_running(c); i++)
    {
        CodeWait* w = &g_codeWaits[i];
        if (w->component != c || !w->pending) continue;
        w->pending = 0;
        LookAt(w, 0);
    }
}

/* At HF_EVENT_GAME_LOADED: every wait looked at once. A wait a ready registers during the pass was looked at by its
 * registration: the pass covers only those registered before it. */
static void CodeWaitsLoaded(void)
{
    g_codeLoaded = 1;
    int count = g_codeWaitCount;
    g_codePass = 1;
    for (int i = 0; i < count; i++) LookAt(&g_codeWaits[i], 0);
    g_codePass = 0;
}

/* A switched-off component's waits are over: their slots are free for its next start. */
static void CodeWaitsForget(VpmComponent* c)
{
    for (int i = 0; i < g_codeWaitCount; i++)
    {
        CodeWait* w = &g_codeWaits[i];
        if (w->component != c || w->done) continue;
        w->done = 1;
        g_codeWaitsOpen--;
    }
}

/* Per frame while a wait is open: the time, and a look every CODE_CHECK_FRAMES frames. */
static void CodeWaitsTick(float dt)
{
    if (g_codeWaitsOpen <= 0 || !g_codeLoaded) return;
    g_codeWaited += dt;
    int final = g_codeWaited >= VPM_CODE_WAIT_SECONDS;
    if (++g_codeFrames % CODE_CHECK_FRAMES != 0 && !final) return;
    int count = g_codeWaitCount; /* as at the event: one registered during the pass was looked at by its registration */
    g_codePass = 1;
    for (int i = 0; i < count; i++) LookAt(&g_codeWaits[i], final);
    g_codePass = 0;
}

/* ---- costs: per component, at each mission's end --------------------------------------------------------------- */

/* Counter cycles per ms between two (time-stamp counter, performance counter) pairs at least minSeconds apart, or 0. */
static double CyclesPerMs(uint64_t tsc0, LARGE_INTEGER qpc0, uint64_t tsc1, LARGE_INTEGER qpc1, double minSeconds)
{
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency); /* lint-ok: C4 once per mission */
    double seconds = frequency.QuadPart > 0 ? (double)(qpc1.QuadPart - qpc0.QuadPart) / (double)frequency.QuadPart : 0;
    return seconds > 0 && seconds >= minSeconds && tsc1 > tsc0 ? (double)(tsc1 - tsc0) / (seconds * 1000.0) : 0;
}

static void CostsStart(void)
{
    g_missionFrame = g_frame;
    g_tscStart = __rdtsc();
    QueryPerformanceCounter(&g_qpcStart); /* lint-ok: C4 once per mission, at its start */
    double cyclesPerMs = CyclesPerMs(g_tscInit, g_qpcInit, g_tscStart, g_qpcStart, 0.05); /* 50 ms: a rate worth a threshold */
    g_slowCycles = cyclesPerMs > 0 ? (uint64_t)(cyclesPerMs * VPM_SLOW_TICK_MS) : UINT64_MAX;
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        c->cycles = c->calls = c->slow = 0;
        memset(c->buckets, 0, sizeof c->buckets);
    }
}

/* The histogram's non-empty buckets from 0.01 ms up, as "0.01-0.02 ms: 3, 0.5-1 ms: 1" (Detailed mode's line). */
static void BucketsText(const VpmComponent* c, double cyclesPerMs, char* out, size_t size)
{
    size_t at = 0;
    out[0] = 0;
    for (int b = 0; b < VPM_COST_BUCKETS && at + 1 < size; b++)
    {
        double low = (double)(1ull << b) / cyclesPerMs;
        if (c->buckets[b] == 0 || low * 2 < 0.01) continue;
        int n = b == VPM_COST_BUCKETS - 1 ? snprintf(out + at, size - at, "%s%.3g ms and longer: %u", at ? ", " : "", low, c->buckets[b])
                                          : snprintf(out + at, size - at, "%s%.3g-%.3g ms: %u", at ? ", " : "", low, low * 2, c->buckets[b]);
        if (n < 0) break;
        at += (size_t)n;
    }
}

/* The slowest non-empty bucket's range in ms. */
static double SlowestBucket(const VpmComponent* c, double cyclesPerMs)
{
    for (int b = VPM_COST_BUCKETS - 1; b >= 0; b--)
        if (c->buckets[b] != 0) return (double)(1ull << b) / cyclesPerMs;
    return 0;
}

/* The mission's frames and length, then per ticking component the average ms per frame and how many single ticks took
 * VPM_SLOW_TICK_MS or longer, with the slowest bucket; Detailed mode adds each one's histogram. */
static void CostsReport(void)
{
    LARGE_INTEGER now, frequency;
    uint64_t tscNow = __rdtsc();
    QueryPerformanceCounter(&now); /* lint-ok: C4 once per mission, at its end */
    QueryPerformanceFrequency(&frequency); /* lint-ok: C4 once per mission, at its end */
    double seconds = (double)(now.QuadPart - g_qpcStart.QuadPart) / (double)frequency.QuadPart;
    double cyclesPerMs = CyclesPerMs(g_tscStart, g_qpcStart, tscNow, now, 0);
    uint64_t frames = g_frame - g_missionFrame;
    if (cyclesPerMs <= 0 || frames == 0) return;
    vpm_core_log("this mission: %llu frames over %.1f s (%.2f ms per frame)", (unsigned long long)frames, seconds,
        seconds * 1000.0 / (double)frames);
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        if (c->calls == 0) continue;
        double ms = (double)c->cycles / cyclesPerMs / (double)frames;
        double slowest = SlowestBucket(c, cyclesPerMs);
        vpm_core_log("cost this mission: %s %.4f ms per frame; ticks of %.1f ms or longer: %llu of %llu; slowest "
            "%.3g-%.3g ms (%llu ticks over %llu frames)", c->def->name, ms, VPM_SLOW_TICK_MS,
            (unsigned long long)c->slow, (unsigned long long)c->calls, slowest, slowest * 2, (unsigned long long)c->calls,
            (unsigned long long)frames);
        if (vpm_detailed())
        {
            char text[512];
            BucketsText(c, cyclesPerMs, text, sizeof text);
            vpm_core_log("tick times this mission: %s %s", c->def->name, text[0] ? text : "every tick under 0.01 ms");
        }
    }
}

static void CoreMissionStart(HfMod* mod, const HfEventInfo* event, void* user) { CostsStart(); }
static void CoreMissionEnd(HfMod* mod, const HfEventInfo* event, void* user)
{
    CostsReport();
    vpm_core_status_lines();
    vpm_diag_mission_end();
    vpm_settings_flush();
}

/* ---- start-up ---------------------------------------------------------------------------------------------------- */

static void CodeWaitsLoaded(void);

/* game.dll's load (inside CoreLoadEvent, before the components' registrations of it). */
static void CoreGameLoaded(void)
{
    int known = vpm_game() != 0;
    vpm_memory_game_loaded();
    if (!known && vpm_game() != 0)
        vpm_core_log("game.dll at 0x%llX (%llu bytes)", (unsigned long long)vpm_game(), (unsigned long long)vpm_game_size());
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

#define OVERLAP_STATUS "off: HellForge's Vanilla Plus is on and changes the same thing"

typedef struct StartCall { VpmComponent* component; int result; } StartCall;
static void RunStart(void* arg) { StartCall* call = arg; call->result = call->component->def->start(call->component); }

/* Starts a switched-on component (at init, or a live switch-on): a new generation, start() guarded, then the load events
 * that already fired. */
static void StartComponent(VpmComponent* c)
{
    if (!c->switched_on) { snprintf(c->status, sizeof c->status, "off"); return; }
    if (!g_buildOk) { snprintf(c->status, sizeof c->status, "off: needs game build %s", VPM_GAME_BUILD); return; }
    if (g_vanillaPlus && (c->def->flags & VPM_OVERLAPS_VANILLA_PLUS))
    {
        snprintf(c->status, sizeof c->status, OVERLAP_STATUS);
        vpm_log(c, "%s", c->status);
        return;
    }
    c->generation++;
    c->state = VPM_STATE_RUNNING;
    c->started = 0;
    c->texts = NULL; /* start() sets its tables again, if it has any */
    snprintf(c->status, sizeof c->status, "running");
    StartCall call = {c, 1};
    c->in_start = 1;
    int ran = vpm_core_guarded(c, VPM_CALL_START, 0, RunStart, &call);
    c->in_start = 0;
    if (!ran) return;
    if (call.result != 0)
    {
        if (c->state == VPM_STATE_RUNNING) vpm_core_stop(c, "start refused");
        return;
    }
    if (c->state != VPM_STATE_RUNNING) return;
    c->started = 1;
    DeliverPast(c);
}

/* Stops a component for a switch (or the pack's unload): its registrations die with its generation, its stop() runs
 * when it had started. A component a fault stopped already ran its stop(): only its status changes. 0 when its stop()
 * faulted. */
static int SwitchOff(VpmComponent* c, const char* status)
{
    int running = c->state == VPM_STATE_RUNNING, started = c->started;
    c->state = VPM_STATE_OFF;
    c->started = 0;
    c->generation++;
    c->tick = NULL;
    c->post_tick = NULL;
    snprintf(c->status, sizeof c->status, "%s", status);
    CodeWaitsForget(c);
    if (!running) return 1;
    vpm_log(c, "%s: stopped", status);
    return RunStopGuarded(c, started);
}

static void Apply(VpmComponent* c, int on)
{
    if (!on)
    {
        if (c->state != VPM_STATE_OFF || strcmp(c->status, "off") != 0) (void)SwitchOff(c, "switched off"); /* a fault is logged */
        snprintf(c->status, sizeof c->status, "off");
        return;
    }
    if (c->state == VPM_STATE_RUNNING) return;
    StartComponent(c);
    vpm_log(c, "switched on: %s", c->status);
}

/* HellForge's mods changed (live mods): its Vanilla Plus came or went, so the components that overlap it stop or start. */
static void ModsChanged(void)
{
    int now = VanillaPlusInSession();
    if (now == g_vanillaPlus) return;
    g_vanillaPlus = now;
    vpm_core_log("HellForge's mods changed: its Vanilla Plus is %s now", now ? "in the session" : "gone");
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        if (!(c->def->flags & VPM_OVERLAPS_VANILLA_PLUS) || c->def->next_session != NULL) continue;
        if (now && c->state == VPM_STATE_RUNNING) (void)SwitchOff(c, OVERLAP_STATUS); /* a fault is logged */
        else if (!now && c->switched_on && c->state != VPM_STATE_RUNNING) Apply(c, 1);
    }
}

/* The frame's live-switch work, at the start of the frame on the game thread (one compare while none waits): every
 * switch the player changed since the last frame, in the components' order. While HellForge's watch thread delivers a
 * load event the work waits for the next frame: the game thread never waits for it. */
static void SwitchWork(void)
{
    LONG work = InterlockedExchange(&g_switchWork, 0);
    if (!TryAcquireSRWLockExclusive(&g_lifeLock)) /* lint-ok: C4 a frame that applies a switch */
    {
        InterlockedOr(&g_switchWork, work);
        return;
    }
    if (work & WORK_MODS) ModsChanged();
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        if (c->wanted == VPM_SWITCH_NONE) continue;
        int on = c->wanted;
        c->wanted = VPM_SWITCH_NONE;
        Apply(c, on);
    }
    ReleaseSRWLockExclusive(&g_lifeLock); /* lint-ok: C4 a frame that applies a switch */
    if (g_statusPending) vpm_core_status_lines();
}

void vpm_component_switch(VpmComponent* component, int on)
{
    on = on != 0;
    int was = component->switched_on;
    component->switched_on = on;
    vpm_setting_put("components", component->def->id, on ? "on" : "off");
    vpm_settings_save_soon();
    if (component->def->next_session != NULL)
    {
        if (on != was) vpm_log(component, "switched %s: applies from the next session (%s)", on ? "on" : "off", component->def->next_session);
        return;
    }
    component->wanted = on;
    InterlockedOr(&g_switchWork, WORK_SWITCH);
    /* No frame to wait for (no game-thread callback and no frame hook): at once. */
    if (!g_tickHooked && g_frameState != 1) SwitchWork();
}

/* HF_EVENT_MODS_CHANGED (live mods, on HellForge's change thread): noted for the next frame. */
static void CoreModsChanged(HfMod* mod, HfEvent event, void* user) { InterlockedOr(&g_switchWork, WORK_MODS); }

static void LogSummary(void)
{
    int running = 0;
    for (int i = 0; i < g_componentCount; i++) running += g_components[i].state == VPM_STATE_RUNNING;
    vpm_core_log("%d of %d components running", running, g_componentCount);
    for (int i = 0; i < g_componentCount; i++)
        vpm_core_log("  %s v%s: %s", g_components[i].def->name, g_components[i].def->version, g_components[i].status);
}

static void HookCore(void)
{
    g_tickHooked = g_hf->on_game_thread(g_mod, PackTick, NULL);
    if (!g_tickHooked) vpm_core_log("the game thread could not be reached (%s): components that tick stay idle", g_hf->last_log(g_mod));
    for (int event = FIRST_LOAD; event <= LAST_LOAD; event++)
    {
        g_eventOk[event] = 1; /* before on(): HellForge may deliver an event that already fired inside it */
        if (g_hf->on(g_mod, (HfEvent)event, CoreLoadEvent, NULL) == 0) continue;
        g_eventOk[event] = 0;
        vpm_core_log("load event %d refused: components see it as absent", event);
    }
    if (g_live.present && g_hf->on(g_mod, (HfEvent)VPM_EVENT_MODS_CHANGED, CoreModsChanged, NULL) != 0)
        vpm_core_log("HellForge's mods-changed event refused: its Vanilla Plus coming or going applies from the next session");
    if (!g_hf->subscribe(g_mod, HF_ON_MISSION_START, CoreMissionStart, NULL, 0) ||
        !g_hf->subscribe(g_mod, HF_ON_MISSION_END, CoreMissionEnd, NULL, 0))
        vpm_core_log("mission events refused (%s): no per-mission cost report", g_hf->last_log(g_mod));
}

static void Forget(void);

int vpm_core_init(const HfApi* api, HfMod* mod, const VpmComponentDef* const* defs, int count)
{
    g_hf = api;
    g_mod = mod;
    if (api->version < 15 || api->size < SDK15_SIZE)
    {
        api->log(mod, "Vanilla Plus Megapack needs HellForge mod SDK 15 or newer (this HellForge has %u)", api->version);
        return 1;
    }
    Forget(); /* vpm_diag_reset among the rest */
    g_initialized = 1;
    g_tscInit = __rdtsc();
    QueryPerformanceCounter(&g_qpcInit); /* lint-ok: C4 once, at the pack's start */
    g_slowCycles = UINT64_MAX;
    vpm_guard_install();
    vpm_memory_init();
    vpm_user32_init();
    g_buildOk = strcmp(api->build_id(), VPM_GAME_BUILD) == 0;
    g_vanillaPlus = VanillaPlusInSession();
    g_live = vpm_live_detect(api, mod);
    vpm_diag_identity(g_vanillaPlus);
    if (g_live.present)
        vpm_core_log("HellForge's live mods: the pack can be taken out and set up again while the game runs (set up %s)",
            g_live.phase == VPM_LOAD_LIVE ? "while the game runs" : "as the game started");
    vpm_settings_load();
    vpm_diag_settings_loaded();
    HookCore();
    g_componentCount = count < VPM_MAX_COMPONENTS ? count : VPM_MAX_COMPONENTS;
    for (int i = 0; i < g_componentCount; i++)
    {
        VpmComponent* c = &g_components[i];
        memset(c, 0, sizeof *c);
        c->def = defs[i];
        c->index = i;
        c->wanted = VPM_SWITCH_NONE;
        const char* saved = vpm_setting("components", c->def->id);
        c->switched_on = saved != NULL ? strcmp(saved, "off") != 0 : !(c->def->flags & VPM_DEFAULT_OFF);
    }
    g_starting = 1;
    for (int i = 0; i < g_componentCount; i++) StartComponent(&g_components[i]);
    g_starting = 0;
    LogSummary();
    vpm_diag_register();
    vpm_diag_options();
    return 0;
}

/* Every component, registration, option, binding and setting forgotten (the guard stays as it is). The frame update's
 * original stays: a frame of an earlier set-up may still be returning through the detour. */
static void Forget(void)
{
    memset(g_components, 0, sizeof g_components);
    g_componentCount = g_loadCount = g_listenCount = g_tickHooked = g_frameState = 0;
    memset(g_loads, 0, sizeof g_loads);
    memset(g_listens, 0, sizeof g_listens);
    memset(g_lists, 0, sizeof g_lists);
    g_tickList = g_tickAt = 0;
    g_tickCurrent = NULL;
    g_frameWaited = 0;
    memset(g_codeWaits, 0, sizeof g_codeWaits);
    g_codeWaitCount = g_codeWaitsOpen = g_codeLoaded = g_codeFrames = g_codePass = 0;
    g_codeWaited = 0;
    memset(g_eventOk, 0, sizeof g_eventOk);
    memset(g_fired, 0, sizeof g_fired);
    g_firedCount = 0;
    g_loadDispatch = 0;
    g_loadWalks = 0;
    g_frame = g_missionFrame = 0;
    g_starting = g_statusPending = 0;
    g_initialized = g_buildOk = g_vanillaPlus = 0;
    memset(&g_live, 0, sizeof g_live);
    InterlockedExchange(&g_switchWork, 0);
    vpm_hooks_unload();
    vpm_options_reset();
    vpm_text_reset();
    vpm_diag_reset();
    vpm_crash_reset();
    vpm_bindings_reset();
}

void vpm_core_reset(void)
{
    Forget();
    g_frameOriginal = NULL;
}

/* ---- HellForge's live mods (SDK 16) ------------------------------------------------------------------------------ *
 * HellForge PR 65 adds two functions after SDK 15's last one (stats_source): load_phase and unhook. Another SDK 16
 * proposal numbers its own additions differently, so the pack never trusts the SDK number or an event number alone: it
 * takes the functions only when the HfApi's size covers both, both are set, the SDK is 16 or newer and load_phase answers
 * one of its two phases. Built with PR 65's header, the fields are read by name. */

#ifdef HF_LOAD_LIVE
#define LIVE_PHASE_AT offsetof(HfApi, load_phase)
#define LIVE_UNHOOK_AT offsetof(HfApi, unhook)
#else
#define LIVE_PHASE_AT (offsetof(HfApi, stats_source) + sizeof(void*))
#define LIVE_UNHOOK_AT (LIVE_PHASE_AT + sizeof(void*))
#endif

VpmLive vpm_live_detect(const HfApi* api, HfMod* mod)
{
    VpmLive live;
    memset(&live, 0, sizeof live);
    if (api->version < 16 || api->size < LIVE_UNHOOK_AT + sizeof(void*)) return live;
    memcpy(&live.load_phase, (const char*)api + LIVE_PHASE_AT, sizeof live.load_phase);
    memcpy(&live.unhook, (const char*)api + LIVE_UNHOOK_AT, sizeof live.unhook);
    if (live.load_phase == NULL || live.unhook == NULL) { memset(&live, 0, sizeof live); return live; }
    live.phase = live.load_phase(mod);
    if (live.phase != VPM_LOAD_BOOT && live.phase != VPM_LOAD_LIVE) { memset(&live, 0, sizeof live); return live; }
    live.present = 1;
    return live;
}

/* hellforge_mod_unload (HellForge took the pack's callbacks and hooks out already: this stops what the pack started
 * itself, and its components' game edits). On HellForge's change thread. */
int vpm_core_unload(uint32_t reason)
{
    if (!g_initialized) return 0;
    AcquireSRWLockExclusive(&g_lifeLock); /* lint-ok: C4 the pack taken out: once */
    vpm_core_log("HellForge takes the pack out (%s): every component stops", reason == VPM_UNLOAD_REPLACE ? "a new version replaces it" : "removed");
    int finished = 1;
    for (int i = g_componentCount - 1; i >= 0; i--)
    {
        g_components[i].wanted = VPM_SWITCH_NONE;
        finished &= SwitchOff(&g_components[i], "off: the pack was taken out");
    }
    memset(g_lists, 0, sizeof g_lists);
    g_tickHooked = 0;
    if (g_frameState == 1 && g_live.unhook != NULL) (void)g_live.unhook(g_mod, vpm_game() + VPM_FRAME_UPDATE); /* 1 when HellForge took it out already */
    g_frameState = -1; /* a game-thread callback still in flight must not hook it again (the next init starts at 0) */
    vpm_hooks_unload();
    InterlockedExchange(&g_switchWork, 0);
    vpm_settings_flush();
    if (finished) vpm_core_log("the pack is out: no component runs, its hooks and the crash guard are gone");
    else vpm_core_log("the pack is out, but a component's stop did not finish: what it changed may be left (restart the session to be sure)");
    g_initialized = 0;
    ReleaseSRWLockExclusive(&g_lifeLock); /* lint-ok: C4 the pack taken out: once */
    vpm_guard_uninstall();
    return finished ? 0 : 1;
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

#ifndef VPM_TEST
HF_MOD_EXPORT int hellforge_mod_init(const HfApi* api, HfMod* mod)
{
    return vpm_core_init(api, mod, vpm_components, vpm_component_total);
}

/* SDK 16 (HellForge's live mods): called before HellForge takes the pack out. An older HellForge never calls it. */
HF_MOD_EXPORT int hellforge_mod_unload(const HfApi* api, HfMod* mod, uint32_t reason)
{
    return vpm_core_unload(reason);
}
#endif
