/* The core's own interface between its files, and the entry the tests use (tests/harness). Components include vpm.h
 * only. */
#ifndef VPM_CORE_H
#define VPM_CORE_H

#include <windows.h>
#include "vpm.h"

#define VPM_MAX_LOADS 128
#define VPM_MAX_LISTENS 128
#define VPM_MAX_BINDINGS 64
#define VPM_STATUS_SIZE 192

/* VpmComponent.state */
#define VPM_STATE_OFF 0      /* switched off, or not started (overlap, build, refused) */
#define VPM_STATE_RUNNING 1
#define VPM_STATE_STOPPED 2  /* stopped: a fault, or vpm_fail (a switch off and on starts it again) */

struct VpmComponent
{
    const VpmComponentDef* def;
    int index;
    int switched_on;     /* the player's saved switch */
    int state;           /* VPM_STATE_... */
    int started;         /* start() returned 0, so stop() may undo it */
    uint32_t generation; /* counts its starts: a registration made by an earlier start (another generation) is dead */
    int in_start;        /* its start() is running: load events already fired wait until it returns */
    int wanted;          /* a live switch waits for the next frame: 1 on, 0 off (VPM_SWITCH_NONE: none) */
    VpmTickFn tick;      /* NULL: not ticking */
    VpmTickFn post_tick; /* after game.dll's update; NULL: none */
    char status[VPM_STATUS_SIZE];
    uint64_t cycles;     /* time-stamp counter cycles spent in its tick this mission */
    uint64_t calls;      /* tick calls this mission */
    uint64_t peak;       /* the largest single tick call's cycles this mission (pre or post) */
    /* diagnostics (diag.c) */
    VpmDescribeFn summary;       /* vpm_on_summary's */
    uint64_t status_frame;       /* the frame its last status line was logged */
    uint32_t status_unlogged;    /* changes since that line that were not logged */
    int status_logged;           /* a status line was logged this session */
    int status_pending;          /* a new status waits for its line (core.c vpm_core_status_lines) */
    uint64_t detail_frame;       /* the start of its detailed lines' window */
    uint32_t detail_lines;       /* detailed lines logged in the window */
    uint32_t detail_suppressed;  /* detailed lines left out since the last report */
};

/* What the pack is running on a thread (guard.c keeps one per thread): the kind of call into a component, with the
 * component and a detail (a listener's HF_ON_ kind, a load event). The guard copies it into a fault; the crash
 * breadcrumb reads it for a fault the guard does not take (game code the component called). */
#define VPM_CALL_NONE 0u
#define VPM_CALL_START 1u
#define VPM_CALL_STOP 2u
#define VPM_CALL_TICK 3u        /* component NULL: the tick list's current one (vpm_core_tick_component) */
#define VPM_CALL_POST_TICK 4u   /* the same */
#define VPM_CALL_LISTENER 5u    /* detail: HF_ON_... */
#define VPM_CALL_LOAD 6u        /* detail: HF_EVENT_... */
#define VPM_CALL_READY 7u       /* vpm_when_code_ready's ready step */
#define VPM_CALL_OPTION 8u      /* an option's on_change */
#define VPM_CALL_ATTACH 9u      /* the bindings backend's attach */
#define VPM_CALL_BINDING 10u    /* the bindings backend's down */
#define VPM_CALL_GUARDED 11u    /* vpm_guarded: a detour's own work */
#define VPM_CALL_WORKER 12u     /* vpm_guarded_off_thread: a component's worker thread */
#define VPM_CALL_DESCRIBE 13u   /* a describe or summary callback */
typedef struct VpmCall
{
    VpmComponent* component;
    uint32_t kind;       /* VPM_CALL_... */
    uint32_t detail;
} VpmCall;

#define VPM_FAULT_RETURNS 8
#define VPM_FAULT_GP 14
/* A fault the guard took (guard.c). */
typedef struct VpmFault
{
    DWORD code;          /* EXCEPTION_ACCESS_VIOLATION ... */
    uintptr_t offset;    /* where, from the pack's image base */
    uintptr_t address;   /* an access violation's address */
    ULONG_PTR access;    /* an access violation's kind: 0 read, 1 write, 8 execute */
    VpmCall call;        /* what the thread was running */
    int has_context;     /* the registers and returns below were taken (not for a vpm_read probe) */
    DWORD64 rip, rsp, rbp, gp[VPM_FAULT_GP]; /* rax rbx rcx rdx rsi rdi r8 .. r15 */
    int returns;         /* return addresses in the pack's code found on the stack, newest first */
    uintptr_t ret[VPM_FAULT_RETURNS]; /* offsets from the pack's image base */
} VpmFault;

/* guard.c */
void vpm_guard_install(void);
/* Takes the guard's and the breadcrumb's handlers out (hellforge_mod_unload); vpm_guard_install puts them back. */
void vpm_guard_uninstall(void);
/* NULL when the guard is installed, else why not ("the pack's image was not found"). */
const char* vpm_guard_problem(void);
/* Runs fn(arg) under the guard: 0, or the code of the fault that ended it (described in *fault). */
DWORD vpm_guard_call(void (*fn)(void*), void* arg, VpmFault* fault);
/* Plain loads under a guard of their own (vpm_read): 1 read, 0 unreadable, -1 no guard installed. */
int vpm_guard_copy(void* out, uintptr_t from, size_t size);
/* "fault 0x... at vanilla_plus_megapack.dll+0x... (a read of 0x...)", then " in its <call>" when the call is known. */
void vpm_fault_text(const VpmFault* fault, char* out, size_t size);
uintptr_t vpm_self_base(void);
size_t vpm_self_size(void);
/* The thread's current call: set before a guarded call (the old one returned), put back after it. Two thread-local
 * copies, no Windows call. */
VpmCall vpm_call_enter(VpmComponent* component, uint32_t kind, uint32_t detail);
void vpm_call_leave(VpmCall was);
VpmCall vpm_call_now(void);
/* "a read of", "a write to", "running" for an access violation or in-page error, else NULL. */
const char* vpm_fault_access(DWORD code, ULONG_PTR access);
/* Registers and the pack's return addresses from a fault's context (both handlers; no Windows call, no allocation). */
void vpm_fault_context(VpmFault* fault, const CONTEXT* context);

/* crash.c: the last-in-line breadcrumb for faults the guard passes on (installed with the guard) */
void vpm_crash_install(void);
void vpm_crash_uninstall(void);
void vpm_crash_reset(void);
/* Tests: breadcrumb lines written since the reset. */
int vpm_crash_notes(void);

/* core.c */
#define VPM_SWITCH_NONE -1
/* The HfApi of SDK 15 ends with stats_source: the least a HellForge must offer (a newer header's sizeof is larger). */
#define SDK15_SIZE (offsetof(HfApi, stats_source) + sizeof(void*))
/* HellForge PR 65's SDK 16 numbers (its header names them HF_EVENT_MODS_CHANGED, HF_LOAD_*, HF_UNLOAD_*): used only
 * once vpm_live_detect found its functions, never on the SDK number alone (another SDK 16 proposal uses event 5 for
 * another event). */
#define VPM_EVENT_MODS_CHANGED 5
#define VPM_LOAD_BOOT 0u
#define VPM_LOAD_LIVE 1u
#define VPM_UNLOAD_REMOVE 1u
#define VPM_UNLOAD_REPLACE 2u
const HfApi* vpm_core_hf(void);
/* 1 while a registration made by a component's start of this generation may still fire: it runs, and the generation is
 * its current one. */
int vpm_core_alive(const VpmComponent* component, uint32_t generation);
/* HellForge's live mods (SDK 16), when its HfApi offers them: load_phase and unhook (NULL members otherwise). */
typedef struct VpmLive
{
    int present;                              /* the HfApi covers both and load_phase answered boot or live */
    uint32_t phase;                           /* HF_LOAD_BOOT or HF_LOAD_LIVE */
    uint32_t (*load_phase)(HfMod* mod);
    int (*unhook)(HfMod* mod, uintptr_t target);
} VpmLive;
const VpmLive* vpm_core_live(void);
/* Reads HellForge's live functions out of an HfApi (by its size, not its SDK number). Tests call it with their tables. */
VpmLive vpm_live_detect(const HfApi* api, HfMod* mod);
/* Stops a component for the session with a reason (its stop() runs guarded when it had started). */
void vpm_core_stop(VpmComponent* component, const char* reason);
/* Runs fn(arg) guarded for a component, as a call of this kind (VPM_CALL_...): on a fault the core logs it and the
 * component is stopped. 1 ran to its end, 0 faulted. */
int vpm_core_guarded(VpmComponent* component, uint32_t kind, uint32_t detail, void (*fn)(void*), void* arg);
/* A core line, "[core] ..." (start-up, stops, a mission's end, a mark: never on an idle frame). */
void vpm_core_log(const char* format, ...) __attribute__((format(printf, 1, 2)));
/* The tick list's component now (a VPM_CALL_TICK's), or NULL. */
VpmComponent* vpm_core_tick_component(void);
/* The core's frame count since the session started (one increment per frame, which the core already made). */
uint64_t vpm_core_frame(void);
/* 1 while vpm_core_init runs the components' start() */
int vpm_core_starting(void);
/* The status lines that wait (vpm_set_status): at the end of a callback, a mission's end and a mark. */
void vpm_core_status_lines(void);

/* diag.c: the diagnostics (vpm.h "diagnostics") */
void vpm_diag_reset(void);
/* The identity block (at init, before the settings load) and the options that differ from their defaults (after the
 * components started). */
void vpm_diag_identity(int vanillaPlus);
void vpm_diag_options(void);
/* The pack's own options (after the components started, so theirs keep their indexes); the Diagnostics mode the
 * settings file saved, read right after its load so components see it from their start(). */
void vpm_diag_register(void);
void vpm_diag_settings_loaded(void);
/* A fault the core took on the game thread: its number, registers and the pack's return addresses (two lines). */
void vpm_diag_fault(const VpmFault* fault);
/* Counts a fault on a worker thread (any thread). */
void vpm_diag_worker_fault(void);
int vpm_diag_faults(void);
/* At a mission's end, after the costs: what is not running and why, the faults, the components' summary lines. */
void vpm_diag_mission_end(void);
/* "<lead> registers: rip=... rsp=..." and "<lead> return addresses in the pack: ..." for a fault with its context. */
void vpm_diag_context(const char* lead, const VpmFault* fault);
/* An address as "game.dll+0x...", "helldivers2.exe+0x...", "vanilla_plus_megapack.dll+0x..." or "0x...". */
void vpm_where(uintptr_t address, char* out, size_t size);
/* A component's status changed (vpm_set_status): the rate-limited status line. */
void vpm_diag_status(VpmComponent* component);
/* The text of a call ("tick", "listener for HF_ON_SPAWN") into out. */
void vpm_call_text(const VpmCall* call, char* out, size_t size);
/* A component's display name, or "the pack" for NULL and the core's record. */
const char* vpm_diag_name(const VpmComponent* component);
/* Tests: the last fault the core logged (vpm_diag_fault); 0 when none. */
int vpm_diag_last_fault(VpmFault* out);

/* memory.c */
void vpm_memory_init(void);
void vpm_memory_game_loaded(void);
/* vpm_hook's record of the pack's hooks: a switched-off component's hooks taken out (with HellForge's unhook; without
 * it they stay and their detours only call the original), every record forgotten (after HellForge took the pack out),
 * and how many are in (tests). */
void vpm_hooks_component_off(VpmComponent* component);
void vpm_hooks_unload(void);
int vpm_hooks_in(void);

/* options.c: the settings file and the option and switch records */
void vpm_settings_load(void);
void vpm_settings_tick(float dt);
void vpm_settings_flush(void);
void vpm_options_reset(void);
void vpm_bindings_reset(void);
/* An option's settings key ("component.id") and its default (a slider's snapped as its value is). */
const char* vpm_option_key(const VpmOption* option);
double vpm_option_default(const VpmOption* option);

/* Windows functions (core.c) */
void vpm_user32_init(void);

/* Tests: stand-ins for what the harness cannot fake through HfApi (memory.c). NULL members: the real calls. */
typedef struct VpmTestHooks
{
    void (*writable_query)(void);                                 /* called before each VirtualQuery of vpm_writable */
    void* (*module_export)(const char* module, const char* name); /* answers vpm_module_export */
    int (*read)(uintptr_t address, void* out, size_t size);       /* answers vpm_read's plausible reads: 1 read, 0 not */
    int (*tick_refused)(int post); /* 1: vpm_tick_start (post 0) or vpm_post_tick_start (post 1) refuses */
} VpmTestHooks;
/* Tests: whether a tick start is refused by the test hook (memory.c; 0 in the DLL). */
int vpm_test_tick_refused(int post);
/* The game's whole-frame update the core hooks for its ticks (core.c): game.dll + VPM_FRAME_UPDATE, its first bytes as
 * shipped on 25480438 (read from the decoded image: mov r11, rsp; push rbp; push r14; lea rbp, [r11 - 0x6A8];
 * sub rsp, 0x798), and how long the core retries while game.dll's code is still being decoded. */
#define VPM_FRAME_UPDATE 0xAB5000u
#define VPM_FRAME_UPDATE_BYTES \
    {0x4C, 0x8B, 0xDC, 0x55, 0x41, 0x56, 0x49, 0x8D, 0xAB, 0x58, 0xF9, 0xFF, 0xFF, 0x48, 0x81, 0xEC, 0x98, 0x07, 0x00, 0x00}
#define VPM_FRAME_WAIT_SECONDS 60.0f
/* 1 while the pack's ticks run from its hook of the frame update, 0 while they run from HellForge's game-thread
 * callback (before the hook, or without it), -1 after it was given up. */
int vpm_frame_hooked(void);

/* Tests: the user32 functions vpm_user32() answers. */
void vpm_user32_set(const VpmUser32* table);
void vpm_core_test_hooks(const VpmTestHooks* hooks);

/* The pack's entry with a given component list: hellforge_mod_init passes src/components.c's; the tests pass their
 * own. 0 loaded, 1 refused (an SDK older than 15). */
int vpm_core_init(const HfApi* api, HfMod* mod, const VpmComponentDef* const* defs, int count);
/* Tests: forget every component, registration, option, binding and setting (the guard stays installed). vpm_core_init
 * calls it too, so a second init in the same process (HellForge setting the pack up again) starts afresh. */
void vpm_core_reset(void);
/* hellforge_mod_unload: HellForge takes the pack out (HF_UNLOAD_REMOVE or HF_UNLOAD_REPLACE). Every running component is
 * stopped (its stop() runs), the ticks and the frame hook go, the component hooks are taken out, the settings are saved
 * and the crash guard is removed. 0: nothing of the pack is left running; 1: a stop() faulted (logged). */
int vpm_core_unload(uint32_t reason);
/* Tests: the settings file's path override (NULL: %LOCALAPPDATA%\CowboyBingus\VanillaPlusMegapack\settings.ini). */
void vpm_settings_path_override(const wchar_t* path);

/* src/components.c */
extern const VpmComponentDef* const vpm_components[];
extern const int vpm_component_total;

#endif
