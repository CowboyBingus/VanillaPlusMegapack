/* The crash guard: a fault in the pack's own code stops the component it happened in instead of the game.
 *
 * vpm_guard_call saves a resume point with RtlCaptureContext in its own frame, marks the guard active for the thread, and
 * calls the component. A first-in-line vectored handler takes an access violation, illegal or privileged instruction,
 * or integer division by zero only when (1) a guarded call is active on the faulting thread and (2) the faulting
 * instruction is inside the pack's image. It then puts the saved context in place of the fault's and continues there:
 * vpm_guard_call returns the fault's code, as setjmp/longjmp would, without unwinding through game frames. Anything else
 * (a fault in game code, one outside a guarded call, another thread's) is passed on unchanged, so the game's own
 * exception handling and HellForge's crash notes see it as before.
 *
 * What a resume leaves behind: the component's half-done work (the caller stops it and runs its stop()), and nothing of
 * the game's unless the component faulted inside a callback the game called while it ran (not a pattern the pack uses).
 * Tested in tests/core_test.c (null reads one and two calls deep, a division by zero, a fault in a nested guard), and with
 * the same compiler in the 2026-10-22 test (KB hellforge-megapack-native-port §2a): 1,000,000 calls, 10 faults taken.
 * Cost: one RtlCaptureContext (user mode, no system call) per guarded call. */
#include <stdio.h>
#include <string.h>
#include "vpm_core.h"

typedef struct VpmGuard
{
    CONTEXT context;         /* the resume point */
    volatile LONG faulted;   /* set by the handler before it resumes */
    VpmFault fault;
    struct VpmGuard* outer;  /* a guard this one runs inside */
    int probe;               /* a read (vpm_guard_copy): takes the faults of reading memory too, and stops nothing */
} VpmGuard;

/* volatile: the handler reads it from another frame, so no store may be dropped. Without it the optimizer removed the
 * store that arms vpm_guard_copy's guard (it saw that CopyIn never reads it, and the next store overwrites it), and a
 * fault in the copy reached the game (tests/core_test.c GuardedReadsReadAndRefuse caught it at -O1). */
static _Thread_local VpmGuard* volatile t_guard;
static uintptr_t g_selfBase, g_selfEnd;
static PVOID g_handler;

static int Guarded(DWORD code, int probe)
{
    if (code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR) return 1;
    /* A read of a guard page (another thread's stack end): the system has taken the guard off already, as it does for a
     * ReadProcessMemory of it, and the read fails. */
    if (probe) return code == EXCEPTION_GUARD_PAGE || code == EXCEPTION_DATATYPE_MISALIGNMENT;
    return code == EXCEPTION_ILLEGAL_INSTRUCTION || code == EXCEPTION_PRIV_INSTRUCTION || code == EXCEPTION_INT_DIVIDE_BY_ZERO;
}

static LONG CALLBACK GuardHandler(EXCEPTION_POINTERS* info)
{
    VpmGuard* guard = t_guard;
    const EXCEPTION_RECORD* record = info->ExceptionRecord;
    uintptr_t at = (uintptr_t)record->ExceptionAddress;
    if (guard == NULL || guard->faulted || !Guarded(record->ExceptionCode, guard->probe) || at < g_selfBase || at >= g_selfEnd)
        return EXCEPTION_CONTINUE_SEARCH;
    guard->fault.code = record->ExceptionCode;
    guard->fault.offset = at - g_selfBase;
    guard->fault.address = record->NumberParameters >= 2 ? (uintptr_t)record->ExceptionInformation[1] : 0;
    guard->fault.access = record->NumberParameters >= 1 ? record->ExceptionInformation[0] : 0;
    guard->faulted = 1;
    *info->ContextRecord = guard->context;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void FindSelf(void)
{
    HMODULE self = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCWSTR)(void*)&FindSelf, &self) || self == NULL)
        return;
    const IMAGE_DOS_HEADER* dos = (const IMAGE_DOS_HEADER*)self;
    const IMAGE_NT_HEADERS64* nt = (const IMAGE_NT_HEADERS64*)((const uint8_t*)self + dos->e_lfanew);
    g_selfBase = (uintptr_t)self;
    g_selfEnd = g_selfBase + nt->OptionalHeader.SizeOfImage;
}

uintptr_t vpm_self_base(void) { return g_selfBase; }

void vpm_guard_install(void)
{
    if (g_handler != NULL) return;
    FindSelf();
    g_handler = AddVectoredExceptionHandler(1, GuardHandler); /* lint-ok: C7 the pack's crash guard: only faults in the pack's own code during a guarded call */
}

/* noinline: the resume point must stay in this function's own frame, which outlives the call it guards. Locals changed
 * after RtlCaptureContext would come back with their values from the capture, so the only state read after a resume is
 * the volatile flag and memory the handler wrote. */
__attribute__((noinline)) DWORD vpm_guard_call(void (*fn)(void*), void* arg, VpmFault* fault)
{
    VpmGuard guard;
    guard.faulted = 0;
    guard.probe = 0;
    guard.outer = t_guard;
    RtlCaptureContext(&guard.context);
    if (guard.faulted)
    {
        t_guard = guard.outer;
        if (fault != NULL) *fault = guard.fault;
        return guard.fault.code;
    }
    if (g_handler == NULL)
    {
        fn(arg); /* no guard could be installed: run it plainly */
        return 0;
    }
    t_guard = &guard;
    fn(arg);
    t_guard = guard.outer;
    return 0;
}

void vpm_fault_text(const VpmFault* fault, char* out, size_t size)
{
    const char* kind = fault->code == EXCEPTION_ACCESS_VIOLATION ? (fault->access == 1 ? "a write to" : fault->access == 8 ? "running" : "a read of")
                       : NULL;
    if (kind != NULL)
        snprintf(out, size, "fault 0x%08lX at vanilla_plus_megapack.dll+0x%llX (%s 0x%llX)", (unsigned long)fault->code,
            (unsigned long long)fault->offset, kind, (unsigned long long)fault->address);
    else
        snprintf(out, size, "fault 0x%08lX at vanilla_plus_megapack.dll+0x%llX", (unsigned long)fault->code,
            (unsigned long long)fault->offset);
}

/* The copy behind vpm_guard_copy: 8 bytes at a time through volatile loads, so the compiler cannot turn it into a call
 * of memcpy (a fault there would be outside the pack's image, and the guard would pass it on). Unaligned loads are fine
 * on x64. */
typedef uint64_t __attribute__((aligned(1))) Unaligned64;
static __attribute__((noinline)) void CopyIn(uint8_t* out, uintptr_t from, size_t size)
{
    const volatile uint8_t* at = (const volatile uint8_t*)from;
    while (size >= 8)
    {
        uint64_t value = *(const volatile Unaligned64*)at;
        memcpy(out, &value, 8);
        out += 8;
        at += 8;
        size -= 8;
    }
    while (size > 0)
    {
        *out++ = *at++;
        size--;
    }
}

/* A read of the game's memory as plain loads under a guard of its own: 1 read, 0 when the memory cannot be read (an
 * unmapped, no-access or guard page: the fault ends the copy, and *out may hold part of it), -1 when no guard is
 * installed (the caller reads through HellForge instead). It stops no component and logs nothing. About 25 ns plus the
 * copy (KB hellforge-megapack-native-port 2a), where a ReadProcessMemory costs 1-2 us in game; a fault costs an
 * exception dispatch, a few microseconds, and comes only from a bad pointer. */
__attribute__((noinline)) int vpm_guard_copy(void* out, uintptr_t from, size_t size)
{
    if (g_handler == NULL) return -1;
    VpmGuard guard;
    guard.faulted = 0;
    guard.probe = 1;
    guard.outer = t_guard;
    RtlCaptureContext(&guard.context);
    if (guard.faulted)
    {
        t_guard = guard.outer;
        return 0;
    }
    t_guard = &guard;
    CopyIn(out, from, size);
    t_guard = guard.outer;
    return 1;
}
