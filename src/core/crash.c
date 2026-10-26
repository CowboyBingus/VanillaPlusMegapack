/* The crash breadcrumb: one log line (and its registers and the pack's return addresses) when a fatal fault the guard
 * did not take goes on towards the game's own handling: game code a component called (the guard takes faults in the
 * pack's code only), a fault on a thread that is not guarded, or a fault anywhere else in the game.
 *
 * A last-in-line vectored handler (it runs after every other vectored handler; the guard's is first in line and resumes
 * the faults it takes, so they never get here). It looks only at fatal codes: access violation, in-page error, illegal
 * or privileged instruction, integer division by zero, heap corruption (0xC0000374), stack overflow (0xC00000FD) and
 * stack buffer overrun (0xC0000409). It logs, then passes the fault on (EXCEPTION_CONTINUE_SEARCH) and never resumes, so
 * the game's frame handlers, HellForge's crash note and Windows' error reporting see it as before. The line says which
 * component and callback the faulting thread was in (the guard's call record, guard.c) or that it was outside the pack.
 *
 * Limits. A vectored handler runs before the game's own __try/__except frames, so a fault the game then handles also
 * gets a line: the text says "passed on" rather than "crashed", and at most VPM_CRASH_NOTES lines are written per session.
 * A __fastfail (most 0xC0000409) ends the process without any handler. On a stack overflow only the first line is
 * written (the handler runs on what is left of the stack). One thread writes at a time; a second one's fault meanwhile
 * gets no line.
 * Cost: none per frame: the handler runs only when an exception is raised. */
#include <stdio.h>
#include <string.h>
#include "vpm_core.h"

#define VPM_CRASH_NOTES 4
#define STATUS_HEAP_CORRUPTION_CODE 0xC0000374u
#define STATUS_STACK_BUFFER_OVERRUN_CODE 0xC0000409u

static PVOID g_crashHandler;
static volatile LONG g_notes;
static volatile LONG g_writing;

void vpm_crash_reset(void) { InterlockedExchange(&g_notes, 0); }
int vpm_crash_notes(void) { return (int)g_notes; }

static int Fatal(DWORD code)
{
    return code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR || code == EXCEPTION_ILLEGAL_INSTRUCTION ||
           code == EXCEPTION_PRIV_INSTRUCTION || code == EXCEPTION_INT_DIVIDE_BY_ZERO || code == EXCEPTION_STACK_OVERFLOW ||
           code == STATUS_HEAP_CORRUPTION_CODE || code == STATUS_STACK_BUFFER_OVERRUN_CODE;
}

/* "while Foo's tick was running", or "outside any call into the pack". */
static void While(char* out, size_t size)
{
    VpmCall call = vpm_call_now();
    if (call.kind == VPM_CALL_NONE)
    {
        snprintf(out, size, "outside any call into the pack");
        return;
    }
    if (call.component == NULL && (call.kind == VPM_CALL_TICK || call.kind == VPM_CALL_POST_TICK))
        call.component = vpm_core_tick_component();
    char text[96];
    vpm_call_text(&call, text, sizeof text);
    snprintf(out, size, "while %s's %s was running", vpm_diag_name(call.component), text);
}

static void Note(const EXCEPTION_POINTERS* info)
{
    const EXCEPTION_RECORD* record = info->ExceptionRecord;
    uintptr_t at = (uintptr_t)record->ExceptionAddress;
    char where[64], during[192], access[64] = "";
    vpm_where(at, where, sizeof where);
    While(during, sizeof during);
    const char* kind = vpm_fault_access(record->ExceptionCode, record->NumberParameters >= 1 ? record->ExceptionInformation[0] : 0);
    if (kind != NULL && record->NumberParameters >= 2)
        snprintf(access, sizeof access, " (%s 0x%llX)", kind, (unsigned long long)record->ExceptionInformation[1]);
    int inPack = at >= vpm_self_base() && at < vpm_self_base() + vpm_self_size();
    vpm_core_log("crash? exception 0x%08lX at %s%s on thread %lu %s%s; passed on: the game crashes unless it handles it",
        (unsigned long)record->ExceptionCode, where, access, GetCurrentThreadId(), during,
        inPack ? " (in the pack's code, outside its guard)" : "");
    if (record->ExceptionCode == EXCEPTION_STACK_OVERFLOW) return;
    VpmFault fault;
    memset(&fault, 0, sizeof fault);
    vpm_fault_context(&fault, info->ContextRecord);
    vpm_diag_context("crash?", &fault);
}

/* Runs on every exception raised in the process, on the raising thread: a compare for any other code. */
static LONG CALLBACK CrashNote(EXCEPTION_POINTERS* info)
{
    if (!Fatal(info->ExceptionRecord->ExceptionCode) || vpm_core_hf() == NULL || g_notes >= VPM_CRASH_NOTES) return EXCEPTION_CONTINUE_SEARCH;
    if (InterlockedCompareExchange(&g_writing, 1, 0) != 0) return EXCEPTION_CONTINUE_SEARCH;
    if (InterlockedIncrement(&g_notes) <= VPM_CRASH_NOTES) Note(info);
    InterlockedExchange(&g_writing, 0);
    return EXCEPTION_CONTINUE_SEARCH;
}

void vpm_crash_install(void)
{
    if (g_crashHandler != NULL) return;
    g_crashHandler = AddVectoredExceptionHandler(0, CrashNote); /* lint-ok: C7 a breadcrumb: logs a fatal fault and passes it on, never resumes */
}

void vpm_crash_uninstall(void)
{
    if (g_crashHandler != NULL && RemoveVectoredExceptionHandler(g_crashHandler) != 0) g_crashHandler = NULL; /* lint-ok: C7 the breadcrumb's own handler, taken out with the pack */
}
