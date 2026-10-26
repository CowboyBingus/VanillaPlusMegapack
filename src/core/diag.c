/* The pack's diagnostics for the alpha test (vpm.h "diagnostics"; KB megapack-alpha-diagnostics-plan): what lets one
 * tester's log say which build ran, what went wrong and where.
 *
 * - The identity block at start-up: the pack's version, commit and build date (vpm_version.h), the game build, the SDK,
 *   the co-op role, the local time (one GetLocalTime, so the log's UTC times can be matched with the launcher's), the
 *   module bases, whether the crash guard is in; after the components started, every option that is not at its default.
 * - Faults: the core's fault line names the callback ("in its tick"); here the fault's number this session, its
 *   registers and the pack's return addresses on the stack (vpm_diag_fault), and the same for the crash breadcrumb.
 * - Status changes (vpm_set_status), at most one line per component per 600 frames, the next one counting what it left
 *   out; at a mission's end, every component that is not running and why, the fault count, and the components' summary
 *   lines (vpm_on_summary: Match Your Colors' worker).
 * - Detailed lines (vpm_log_detail) behind the pack's Diagnostics option, through a limiter of 20 lines per component
 *   per 600 frames.
 * - "Note a problem now": a numbered MARK with the local time, the game state and every component's state.
 *
 * Per frame: nothing here runs on a frame that does not act. vpm_detailed is one global read; vpm_log_detail in Normal
 * mode one global read and a return; vpm_set_status a compare of the texts (it copied the text before too) and, on a
 * change, a frame-count compare. Windows calls: GetLocalTime at start-up and at a mark only. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vpm_core.h"
#include "vpm_version.h"

/* The build date: build.ps1's define, or the compiler's date (not reproducible, which is the point of a fallback). */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdate-time"
static const char kBuildDate[] = VPM_BUILD_DATE;
#pragma GCC diagnostic pop

#define STATUS_FRAMES 600 /* one status line per component per 600 frames (10 s at 60 FPS) */

static const VpmComponentDef kPackDef = {"core", VPM_PACK_NAME, VPM_PACK_VERSION, 0, NULL, NULL, NULL};
static VpmComponent g_pack;
static int g_detailed;
static int g_marks;
static volatile LONG g_faults;
static VpmFault g_lastFault;
static int g_hasLastFault;

VpmComponent* vpm_pack(void) { return &g_pack; }
int vpm_detailed(void) { return g_detailed; }
int vpm_diag_faults(void) { return (int)g_faults; }
void vpm_diag_worker_fault(void) { InterlockedIncrement(&g_faults); }

void vpm_diag_reset(void)
{
    memset(&g_pack, 0, sizeof g_pack);
    g_pack.def = &kPackDef;
    g_pack.index = -1;
    g_pack.switched_on = 1;
    g_pack.state = VPM_STATE_RUNNING;
    g_pack.started = 1;
    snprintf(g_pack.status, sizeof g_pack.status, "running");
    g_detailed = g_marks = g_hasLastFault = 0;
    InterlockedExchange(&g_faults, 0);
}

int vpm_diag_last_fault(VpmFault* out)
{
    if (g_hasLastFault && out != NULL) *out = g_lastFault;
    return g_hasLastFault;
}

const char* vpm_diag_name(const VpmComponent* component)
{
    return component == NULL || component == &g_pack ? "the pack" : component->def->name;
}

/* ---- texts ------------------------------------------------------------------------------------------------------- */

static const char* const kEvents[] = {NULL, "HF_ON_STATE", "HF_ON_MISSION_START", "HF_ON_MISSION_END", "HF_ON_PLAYER_SPAWN",
    "HF_ON_PLAYER_DOWN", "HF_ON_DAMAGE", "HF_ON_STRATAGEM", "HF_ON_KILL", "HF_ON_SPAWN", "HF_ON_HEAL", "HF_ON_STAT",
    "HF_ON_WEAPON", "HF_ON_EXPLOSION", "HF_ON_BUGHOLE", "HF_ON_DAMAGE_PRE"};
static const char* const kLoads[] = {NULL, "HF_EVENT_GAME_LOADED", "HF_EVENT_NETWORK_READY", "HF_EVENT_ENTITIES_READY",
    "HF_EVENT_PROJECTILES_READY"};
static const char* const kCalls[] = {"call", "start", "stop", "tick", "post-update tick", "listener", "load event",
    "code-ready step", "option change", "bindings attach", "bindings answer", "guarded work (a detour's)", "worker thread",
    "describe or summary"};
#define COUNT(a) (sizeof (a) / sizeof (a)[0])

void vpm_call_text(const VpmCall* call, char* out, size_t size)
{
    uint32_t kind = call->kind < COUNT(kCalls) ? call->kind : 0;
    uint32_t d = call->detail;
    if (kind == VPM_CALL_LISTENER && d < COUNT(kEvents) && kEvents[d] != NULL) snprintf(out, size, "listener for %s", kEvents[d]);
    else if (kind == VPM_CALL_LISTENER) snprintf(out, size, "listener for game event %u", d);
    else if (kind == VPM_CALL_LOAD && d < COUNT(kLoads) && kLoads[d] != NULL) snprintf(out, size, "handler of %s", kLoads[d]);
    else if (kind == VPM_CALL_LOAD) snprintf(out, size, "handler of load event %u", d);
    else snprintf(out, size, "%s", kCalls[kind]);
}

static int Inside(uintptr_t at, uintptr_t base, size_t size) { return base != 0 && at >= base && at - base < size; }

void vpm_where(uintptr_t address, char* out, size_t size)
{
    unsigned long long a = address;
    if (Inside(address, vpm_game(), vpm_game_size())) snprintf(out, size, "game.dll+0x%llX", a - vpm_game());
    else if (Inside(address, vpm_exe(), vpm_exe_size())) snprintf(out, size, "helldivers2.exe+0x%llX", a - vpm_exe());
    else if (Inside(address, vpm_self_base(), vpm_self_size())) snprintf(out, size, "vanilla_plus_megapack.dll+0x%llX", a - vpm_self_base());
    else snprintf(out, size, "0x%llX", a);
}

/* ---- faults ------------------------------------------------------------------------------------------------------ */

static const char* const kRegisters[VPM_FAULT_GP] = {"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11",
    "r12", "r13", "r14", "r15"};

static void Registers(const VpmFault* fault, char* out, size_t size)
{
    char rip[64];
    vpm_where((uintptr_t)fault->rip, rip, sizeof rip);
    size_t at = (size_t)snprintf(out, size, "rip=%s rsp=0x%llX rbp=0x%llX", rip, (unsigned long long)fault->rsp,
        (unsigned long long)fault->rbp);
    for (int i = 0; i < VPM_FAULT_GP && at < size; i++)
        at += (size_t)snprintf(out + at, size - at, " %s=0x%llX", kRegisters[i], (unsigned long long)fault->gp[i]);
}

static void Returns(const VpmFault* fault, char* out, size_t size)
{
    size_t at = 0;
    out[0] = 0;
    for (int i = 0; i < fault->returns && at < size; i++)
        at += (size_t)snprintf(out + at, size - at, "%svanilla_plus_megapack.dll+0x%llX", i > 0 ? ", " : "",
            (unsigned long long)fault->ret[i]);
}

void vpm_diag_context(const char* lead, const VpmFault* fault)
{
    if (!fault->has_context) return;
    char text[640];
    Registers(fault, text, sizeof text);
    vpm_core_log("%s registers: %s", lead, text);
    Returns(fault, text, sizeof text);
    vpm_core_log("%s return addresses in the pack, newest first: %s", lead, text[0] != 0 ? text : "none found on the stack");
}

void vpm_diag_fault(const VpmFault* fault)
{
    LONG n = InterlockedIncrement(&g_faults);
    g_lastFault = *fault;
    g_hasLastFault = 1;
    char call[96], lead[192];
    vpm_call_text(&fault->call, call, sizeof call);
    snprintf(lead, sizeof lead, "fault %ld this session (%s's %s):", n, vpm_diag_name(fault->call.component), call);
    vpm_diag_context(lead, fault);
}

/* ---- status lines ------------------------------------------------------------------------------------------------ */

void vpm_diag_status(VpmComponent* c)
{
    if (vpm_core_starting() || c == &g_pack) return; /* the start-up summary lists every status */
    uint64_t now = vpm_core_frame();
    if (c->status_logged && now - c->status_frame < STATUS_FRAMES)
    {
        c->status_unlogged++;
        return;
    }
    if (c->status_unlogged > 0)
        vpm_core_log("%s status: %s (%u changes before it not logged)", c->def->name, c->status, c->status_unlogged);
    else
        vpm_core_log("%s status: %s", c->def->name, c->status);
    c->status_logged = 1;
    c->status_frame = now;
    c->status_unlogged = 0;
}

/* ---- detailed lines ---------------------------------------------------------------------------------------------- */

static void DetailFlush(VpmComponent* c)
{
    if (c->detail_suppressed == 0) return;
    vpm_log(c, "%u detailed lines suppressed (at most %d per %d frames)", c->detail_suppressed, VPM_DETAIL_LINES,
        VPM_DETAIL_FRAMES);
    c->detail_suppressed = 0;
}

/* Whether the component's window has room for a line: a new window every VPM_DETAIL_FRAMES frames, whose first line
 * is preceded by the count of the last one's suppressed lines. */
static int DetailRoom(VpmComponent* c)
{
    uint64_t now = vpm_core_frame();
    if (now - c->detail_frame >= VPM_DETAIL_FRAMES)
    {
        DetailFlush(c);
        c->detail_frame = now;
        c->detail_lines = 0;
    }
    if (c->detail_lines >= VPM_DETAIL_LINES)
    {
        c->detail_suppressed++;
        return 0;
    }
    c->detail_lines++;
    return 1;
}

void vpm_log_detail(VpmComponent* self, const char* format, ...)
{
    if (!g_detailed || self == NULL || !DetailRoom(self)) return;
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    vpm_log(self, "%s", line);
}

/* ---- summaries and describe -------------------------------------------------------------------------------------- */

void vpm_on_summary(VpmComponent* self, VpmDescribeFn fn)
{
    if (self != NULL) self->summary = fn;
}

typedef struct DescribeCall { VpmComponent* component; VpmDescribeFn fn; char* out; size_t size; } DescribeCall;
static void RunDescribe(void* arg)
{
    DescribeCall* call = arg;
    call->fn(call->component, call->out, call->size);
}

/* A describe or summary callback's text into out (guarded): 1 when it wrote one. */
static int Describe(VpmComponent* c, VpmDescribeFn fn, char* out, size_t size)
{
    out[0] = 0;
    if (fn == NULL || !vpm_running(c)) return 0;
    DescribeCall call = {c, fn, out, size};
    if (!vpm_core_guarded(c, VPM_CALL_DESCRIBE, 0, RunDescribe, &call)) out[0] = 0;
    out[size - 1] = 0;
    return out[0] != 0;
}

static int Running(void)
{
    int running = 0;
    for (int i = 0; i < vpm_component_count(); i++) running += vpm_running(vpm_component_at(i));
    return running;
}

static void EndLine(VpmComponent* c)
{
    DetailFlush(c);
    if (!vpm_running(c))
    {
        if (strcmp(c->status, "off") != 0) vpm_core_log("  %s: %s", c->def->name, c->status);
        return;
    }
    char summary[256];
    if (Describe(c, c->summary, summary, sizeof summary)) vpm_core_log("  %s: %s", c->def->name, summary);
}

void vpm_diag_mission_end(void)
{
    vpm_core_log("at the mission's end: %d of %d components running; faults this session: %d", Running(),
        vpm_component_count(), vpm_diag_faults());
    for (int i = 0; i < vpm_component_count(); i++) EndLine(vpm_component_at(i));
}

/* ---- "Note a problem now" ---------------------------------------------------------------------------------------- */

static const char* StateName(uint32_t state)
{
    static const char* const names[] = {"none", "splash", "title", "ship", "mission", "loading the ship", "loading a mission"};
    return state < COUNT(names) ? names[state] : "unknown";
}

static void MarkLine(int mark, VpmComponent* c)
{
    DetailFlush(c);
    if (!vpm_running(c))
    {
        if (strcmp(c->status, "off") != 0) vpm_core_log("MARK %d: %s: %s", mark, c->def->name, c->status);
        return;
    }
    char describe[256], summary[256];
    int described = Describe(c, c->def->describe, describe, sizeof describe);
    int summed = Describe(c, c->summary, summary, sizeof summary);
    vpm_core_log("MARK %d: %s: %s%s%s%s%s", mark, c->def->name, c->status, described ? " | " : "", described ? describe : "",
        summed ? " | " : "", summed ? summary : "");
}

static void WriteMark(void)
{
    SYSTEMTIME t;
    GetLocalTime(&t);
    vpm_core_status_lines();
    int mark = ++g_marks;
    uint32_t state = vpm_core_hf()->game_state(vpm_mod());
    vpm_core_log("MARK %d at %04u-%02u-%02u %02u:%02u:%02u.%03u local time; game: %s; frame %llu; %d of %d components "
                 "running; faults this session: %d", mark, t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
        t.wMilliseconds, StateName(state), (unsigned long long)vpm_core_frame(), Running(), vpm_component_count(),
        vpm_diag_faults());
    for (int i = 0; i < vpm_component_count(); i++) MarkLine(mark, vpm_component_at(i));
    vpm_core_log("MARK %d end", mark);
}

/* ---- the pack's options ------------------------------------------------------------------------------------------ */

static const char* const kDiagnosticsChoices[] = {"Normal", "Detailed", NULL};
static const VpmOptionDef kDiagnostics = {"diagnostics", VPM_CHOICE, "Diagnostics",
    "Normal: the log has what every session needs. Detailed: components also log the steps behind what they do (at most "
    "about 20 lines per 10 s each), to chase a problem. Applies at once.",
    1, 0, 0, 0, kDiagnosticsChoices, 1};
static const VpmOptionDef kNote = {"note_problem", VPM_TOGGLE, "Note a problem now",
    "Switch on and apply when something goes wrong: the pack's log gets a numbered MARK with the time and every "
    "component's state. Name the mark in your report. It switches itself back off.",
    0, 0, 0, 0, NULL, 0};

static void DiagnosticsChanged(VpmComponent* self, VpmOption* option, double value)
{
    g_detailed = value == 2;
    vpm_core_log("diagnostics: %s", g_detailed ? "detailed (components log the steps behind what they do)" : "normal");
}

/* The toggle acts when applied on and switches itself back off (Mod Options Menu has no action rows). */
static void NoteChanged(VpmComponent* self, VpmOption* option, double value)
{
    if (value != 1) return;
    WriteMark();
    (void)vpm_option_set(option, 0);
}

void vpm_diag_settings_loaded(void)
{
    const char* saved = vpm_setting("options", "core.diagnostics");
    g_detailed = saved != NULL && strtod(saved, NULL) == 2;
}

void vpm_diag_register(void)
{
    VpmOption* diagnostics = vpm_option(&g_pack, &kDiagnostics);
    if (diagnostics != NULL)
    {
        vpm_option_on_change(diagnostics, DiagnosticsChanged);
        g_detailed = vpm_option_value(diagnostics) == 2;
    }
    VpmOption* note = vpm_option(&g_pack, &kNote);
    if (note == NULL) return;
    vpm_option_on_change(note, NoteChanged);
    if (vpm_option_value(note) != 0) (void)vpm_option_set(note, 0); /* saved on by a session that ended meanwhile */
}

/* ---- the identity block ------------------------------------------------------------------------------------------ */

static const char* RoleName(uint32_t role)
{
    return role == HF_SESSION_HOST ? "hosting" : role == HF_SESSION_JOINER ? "joined" : role == HF_SESSION_SOLO ? "solo" : "unknown";
}

static void Base(uintptr_t base, size_t size, char* out, size_t room)
{
    if (base == 0) snprintf(out, room, "not loaded yet");
    else snprintf(out, room, "at 0x%llX (%llu bytes)", (unsigned long long)base, (unsigned long long)size);
}

void vpm_diag_identity(int vanillaPlus)
{
    const HfApi* hf = vpm_core_hf();
    vpm_core_log("%s %s (commit %s, built %s) for game build %s (this game: %s)%s", VPM_PACK_NAME, VPM_PACK_VERSION,
        VPM_COMMIT, kBuildDate, VPM_GAME_BUILD, hf->build_id(),
        vanillaPlus ? "; HellForge's Vanilla Plus is in this session" : "");
    HfSession session;
    memset(&session, 0, sizeof session);
    hf->session(vpm_mod(), &session);
    SYSTEMTIME t;
    GetLocalTime(&t);
    vpm_core_log("HellForge mod SDK %u (API table %u bytes); co-op: %s (session version %u); local time %04u-%02u-%02u "
                 "%02u:%02u:%02u", hf->version, hf->size, RoleName(session.role), session.version, t.wYear, t.wMonth, t.wDay,
        t.wHour, t.wMinute, t.wSecond);
    char game[64], exe[64];
    Base(vpm_game(), vpm_game_size(), game, sizeof game);
    Base(vpm_exe(), vpm_exe_size(), exe, sizeof exe);
    const char* problem = vpm_guard_problem();
    vpm_core_log("game.dll %s, helldivers2.exe %s, the pack at 0x%llX (%llu bytes); crash guard: %s%s", game, exe,
        (unsigned long long)vpm_self_base(), (unsigned long long)vpm_self_size(),
        problem == NULL ? "installed" : "NOT installed, a fault in the pack reaches the game: ", problem != NULL ? problem : "");
}

/* "key = value" (a choice's name too) after the line's text; 0 when the line has no room left. */
static int AppendOption(char* line, size_t* at, size_t size, const VpmOption* option)
{
    const VpmOptionDef* def = vpm_option_def(option);
    double value = vpm_option_value(option);
    char text[160];
    int n = def->kind == VPM_CHOICE ? snprintf(text, sizeof text, "%s = %g (%s)", vpm_option_key(option), value,
                                          def->choices[(int)value - 1])
                                    : snprintf(text, sizeof text, "%s = %g", vpm_option_key(option), value);
    if (n < 0 || *at + (size_t)n + 2 >= size) return 0;
    *at += (size_t)snprintf(line + *at, size - *at, "%s%s", *at > 0 ? ", " : "", text);
    return 1;
}

void vpm_diag_options(void)
{
    char line[800];
    size_t at = 0;
    int changed = 0;
    line[0] = 0;
    for (int i = 0; i < vpm_option_count(); i++)
    {
        const VpmOption* option = vpm_option_at(i);
        if (vpm_option_value(option) == vpm_option_default(option)) continue;
        changed++;
        if (AppendOption(line, &at, sizeof line, option)) continue;
        vpm_core_log("options not at their defaults: %s", line);
        at = 0;
        line[0] = 0;
        (void)AppendOption(line, &at, sizeof line, option);
    }
    if (changed == 0) vpm_core_log("options: all %d at their defaults", vpm_option_count());
    else vpm_core_log("options not at their defaults: %s", line);
}
