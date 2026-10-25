/* The core's own interface between its files, and the entry the tests use (tests/harness). Components include vpm.h
 * only. */
#ifndef VPM_CORE_H
#define VPM_CORE_H

#include <windows.h>
#include "vpm.h"

#define VPM_MAX_COMPONENTS 32
#define VPM_MAX_LOADS 128
#define VPM_MAX_LISTENS 128
#define VPM_MAX_OPTIONS 256
#define VPM_MAX_BINDINGS 64
#define VPM_STATUS_SIZE 192

/* VpmComponent.state */
#define VPM_STATE_OFF 0      /* switched off, or not started (overlap, build, refused) */
#define VPM_STATE_RUNNING 1
#define VPM_STATE_STOPPED 2  /* stopped for the session: a fault, or vpm_fail */

struct VpmComponent
{
    const VpmComponentDef* def;
    int index;
    int switched_on;     /* the player's saved switch */
    int state;           /* VPM_STATE_... */
    int started;         /* start() returned 0, so stop() may undo it */
    VpmTickFn tick;      /* NULL: not ticking */
    char status[VPM_STATUS_SIZE];
    uint64_t cycles;     /* time-stamp counter cycles spent in its tick this mission */
    uint64_t calls;      /* tick calls this mission */
};

/* A fault the guard took (guard.c). */
typedef struct VpmFault
{
    DWORD code;          /* EXCEPTION_ACCESS_VIOLATION ... */
    uintptr_t offset;    /* where, from the pack's image base */
    uintptr_t address;   /* an access violation's address */
    ULONG_PTR access;    /* an access violation's kind: 0 read, 1 write, 8 execute */
} VpmFault;

/* guard.c */
void vpm_guard_install(void);
/* Runs fn(arg) under the guard: 0, or the code of the fault that ended it (described in *fault). */
DWORD vpm_guard_call(void (*fn)(void*), void* arg, VpmFault* fault);
void vpm_fault_text(const VpmFault* fault, char* out, size_t size);
uintptr_t vpm_self_base(void);

/* core.c */
const HfApi* vpm_core_hf(void);
/* Stops a component for the session with a reason (its stop() runs guarded when it had started). */
void vpm_core_stop(VpmComponent* component, const char* reason);
/* Runs fn(arg) guarded for a component: on a fault the component is stopped. 1 ran to its end, 0 faulted. */
int vpm_core_guarded(VpmComponent* component, void (*fn)(void*), void* arg);

/* memory.c */
void vpm_memory_init(void);
void vpm_memory_game_loaded(void);

/* options.c: the settings file and the option and switch records */
void vpm_settings_load(void);
void vpm_settings_tick(float dt);
void vpm_settings_flush(void);
void vpm_options_reset(void);
void vpm_bindings_reset(void);

/* Windows functions (core.c) */
void vpm_user32_init(void);

/* The pack's entry with a given component list: hellforge_mod_init passes src/components.c's; the tests pass their
 * own. 0 loaded, 1 refused (an SDK older than 15). */
int vpm_core_init(const HfApi* api, HfMod* mod, const VpmComponentDef* const* defs, int count);
/* Tests: forget every component, registration, option, binding and setting (the guard stays installed). */
void vpm_core_reset(void);
/* Tests: the settings file's path override (NULL: %LOCALAPPDATA%\CowboyBingus\VanillaPlusMegapack\settings.ini). */
void vpm_settings_path_override(const wchar_t* path);

/* src/components.c */
extern const VpmComponentDef* const vpm_components[];
extern const int vpm_component_total;

#endif
