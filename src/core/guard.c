/* The crash guard: a fault in the pack's own code stops the component it happened in instead of the game.
 *
 * vpm_guard_call saves a resume point with RtlCaptureContext in its own frame, marks the guard active for the thread, and
 * calls the component. A first-in-line vectored handler takes an access violation, illegal or privileged instruction,
 * or integer division by zero only when (1) a guarded call is active on the faulting thread and (2) the faulting
 * instruction is inside the pack's image. It then puts the saved context in place of the fault's and continues there:
 * vpm_guard_call returns the fault's code, as setjmp/longjmp would, without unwinding through game frames. Anything else
 * (a fault in game code, one outside a guarded call, another thread's) is passed on unchanged, so the game's own
 * exception handling and HellForge's crash notes see it as before; the pack's breadcrumb (crash.c) logs it on the way.
 *
 * What a fault records for the log (vpm_fault_context, at fault time only): the call the thread was in (its VpmCall:
 * which component, which kind of callback), rip, rsp, rbp and the general registers, and up to 8 return addresses into
 * the pack's code found on the stack (a value inside the pack's executable sections that follows a call instruction).
 * A vpm_read probe's fault records none of it: those come from bad pointers, often, and stop nothing.
 *
 * What a resume leaves behind: the component's half-done work (the caller stops it and runs its stop()), and nothing of
 * the game's unless the component faulted inside a callback the game called while it ran (not a pattern the pack uses).
 * Tested in tests/core_test.c (null reads one and two calls deep, a division by zero, a fault in a nested guard, a fault
 * in each kind of callback), and with the same compiler in the 2026-10-22 test (KB hellforge-megapack-native-port §2a):
 * 1,000,000 calls, 10 faults taken.
 * Cost: one RtlCaptureContext (user mode, no system call) per guarded call; the core's call record is two thread-local
 * copies per guarded call (vpm_call_enter/leave), once per tick list per frame for the ticks. */
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
static _Thread_local VpmCall t_call;
static uintptr_t g_selfBase, g_selfEnd;
static uintptr_t g_codeStart, g_codeEnd; /* the pack's executable sections */
static PVOID g_handler;
static char g_problem[96] = "not installed yet";

VpmCall vpm_call_enter(VpmComponent* component, uint32_t kind, uint32_t detail)
{
    VpmCall was = t_call;
    t_call.component = component;
    t_call.kind = kind;
    t_call.detail = detail;
    return was;
}

void vpm_call_leave(VpmCall was) { t_call = was; }
VpmCall vpm_call_now(void) { return t_call; }

static int Guarded(DWORD code, int probe)
{
    if (code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR) return 1;
    /* A read of a guard page (another thread's stack end): the system has taken the guard off already, as it does for a
     * ReadProcessMemory of it, and the read fails. */
    if (probe) return code == EXCEPTION_GUARD_PAGE || code == EXCEPTION_DATATYPE_MISALIGNMENT;
    return code == EXCEPTION_ILLEGAL_INSTRUCTION || code == EXCEPTION_PRIV_INSTRUCTION || code == EXCEPTION_INT_DIVIDE_BY_ZERO;
}

/* Whether the bytes before a return address end in a call instruction: E8 rel32, or FF /2 with a register (FF D0+r, with
 * or without REX), a [reg + disp8] or a [rip + disp32] / [reg + disp32] operand. */
static int AfterCall(uintptr_t at)
{
    if (at < g_codeStart + 7 || at >= g_codeEnd) return 0;
    const uint8_t* p = (const uint8_t*)at;
    if (p[-5] == 0xE8) return 1;
    if (p[-2] == 0xFF && (p[-1] & 0x38) == 0x10 && (p[-1] & 0xC0) == 0xC0) return 1;
    if (p[-3] == 0xFF && (p[-2] & 0x38) == 0x10 && (p[-2] & 0xC0) == 0x40) return 1;
    return p[-6] == 0xFF && (p[-5] & 0x38) == 0x10 && ((p[-5] & 0xC7) == 0x05 || (p[-5] & 0xC0) == 0x80);
}

/* Up to VPM_FAULT_RETURNS return addresses into the pack's code, from rsp towards the stack's base (at most 32 KB): plain
 * loads of the thread's own committed stack. */
static void ScanStack(VpmFault* fault, uintptr_t rsp)
{
    const NT_TIB* tib = (const NT_TIB*)NtCurrentTeb();
    uintptr_t base = (uintptr_t)tib->StackBase, limit = (uintptr_t)tib->StackLimit;
    if (rsp < limit || rsp >= base || g_codeEnd == 0) return;
    uintptr_t end = base - rsp > 32768 ? rsp + 32768 : base;
    for (uintptr_t at = rsp & ~(uintptr_t)7; at + 8 <= end && fault->returns < VPM_FAULT_RETURNS; at += 8)
    {
        uintptr_t value = *(const uintptr_t*)at;
        if (AfterCall(value)) fault->ret[fault->returns++] = value - g_selfBase;
    }
}

void vpm_fault_context(VpmFault* fault, const CONTEXT* context)
{
    fault->has_context = 1;
    fault->rip = context->Rip;
    fault->rsp = context->Rsp;
    fault->rbp = context->Rbp;
    const DWORD64 gp[VPM_FAULT_GP] = {context->Rax, context->Rbx, context->Rcx, context->Rdx, context->Rsi, context->Rdi,
        context->R8, context->R9, context->R10, context->R11, context->R12, context->R13, context->R14, context->R15};
    memcpy(fault->gp, gp, sizeof gp);
    fault->returns = 0;
    ScanStack(fault, (uintptr_t)context->Rsp);
}

static LONG CALLBACK GuardHandler(EXCEPTION_POINTERS* info)
{
    VpmGuard* guard = t_guard;
    const EXCEPTION_RECORD* record = info->ExceptionRecord;
    uintptr_t at = (uintptr_t)record->ExceptionAddress;
    if (guard == NULL || guard->faulted || !Guarded(record->ExceptionCode, guard->probe) || at < g_selfBase || at >= g_selfEnd)
        return EXCEPTION_CONTINUE_SEARCH;
    memset(&guard->fault, 0, sizeof guard->fault);
    guard->fault.code = record->ExceptionCode;
    guard->fault.offset = at - g_selfBase;
    guard->fault.address = record->NumberParameters >= 2 ? (uintptr_t)record->ExceptionInformation[1] : 0;
    guard->fault.access = record->NumberParameters >= 1 ? record->ExceptionInformation[0] : 0;
    guard->fault.call = t_call;
    if (!guard->probe) vpm_fault_context(&guard->fault, info->ContextRecord);
    guard->faulted = 1;
    *info->ContextRecord = guard->context;
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* The pack's image and its executable sections. */
static int FindSelf(void)
{
    HMODULE self = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCWSTR)(void*)&FindSelf, &self) || self == NULL)
    {
        snprintf(g_problem, sizeof g_problem, "the pack's own image was not found (error %lu)", GetLastError());
        return 0;
    }
    const IMAGE_DOS_HEADER* dos = (const IMAGE_DOS_HEADER*)self;
    const IMAGE_NT_HEADERS64* nt = (const IMAGE_NT_HEADERS64*)((const uint8_t*)self + dos->e_lfanew);
    g_selfBase = (uintptr_t)self;
    g_selfEnd = g_selfBase + nt->OptionalHeader.SizeOfImage;
    const IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; i++, section++)
    {
        if (!(section->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uintptr_t start = g_selfBase + section->VirtualAddress, end = start + section->Misc.VirtualSize;
        if (g_codeStart == 0 || start < g_codeStart) g_codeStart = start;
        if (end > g_codeEnd) g_codeEnd = end;
    }
    return 1;
}

uintptr_t vpm_self_base(void) { return g_selfBase; }
size_t vpm_self_size(void) { return g_selfEnd - g_selfBase; }
const char* vpm_guard_problem(void) { return g_handler != NULL ? NULL : g_problem; }

void vpm_guard_install(void)
{
    vpm_crash_install();
    if (g_handler != NULL || !FindSelf()) return;
    g_handler = AddVectoredExceptionHandler(1, GuardHandler); /* lint-ok: C7 the pack's crash guard: only faults in the pack's own code during a guarded call */
    if (g_handler == NULL) snprintf(g_problem, sizeof g_problem, "Windows refused its exception handler");
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

const char* vpm_fault_access(DWORD code, ULONG_PTR access)
{
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_IN_PAGE_ERROR) return NULL;
    return access == 1 ? "a write to" : access == 8 ? "running" : "a read of";
}

void vpm_fault_text(const VpmFault* fault, char* out, size_t size)
{
    char where[112] = "";
    if (fault->call.kind != VPM_CALL_NONE)
    {
        char call[96];
        vpm_call_text(&fault->call, call, sizeof call);
        snprintf(where, sizeof where, " in its %s", call);
    }
    const char* kind = vpm_fault_access(fault->code, fault->access);
    if (kind != NULL)
        snprintf(out, size, "fault 0x%08lX at vanilla_plus_megapack.dll+0x%llX (%s 0x%llX)%s", (unsigned long)fault->code,
            (unsigned long long)fault->offset, kind, (unsigned long long)fault->address, where);
    else
        snprintf(out, size, "fault 0x%08lX at vanilla_plus_megapack.dll+0x%llX%s", (unsigned long)fault->code,
            (unsigned long long)fault->offset, where);
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
 * installed (the caller reads through HellForge instead). It stops no component and logs nothing. Unmeasured in game:
 * about 25 ns plus the copy in the test process (KB hellforge-megapack-native-port 2a), where a ReadProcessMemory costs
 * 1-2 us in game; a fault costs an exception dispatch, a few microseconds, and comes only from a bad pointer. */
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
