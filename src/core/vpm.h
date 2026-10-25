/* The Vanilla Plus Megapack's core: what every component of the pack uses (docs: README.md "The core").
 *
 * The pack is one HellForge code mod. Each component is a VpmComponentDef (src/components.c lists them) whose start()
 * runs once, inside hellforge_mod_init, when the player has it switched on. start() registers what the component needs:
 * load events, a game-thread tick, game event listeners, options and bindings. The core makes one registration of each
 * kind with HellForge for the whole pack and passes the calls on, so the pack holds one game-thread callback however many
 * components tick.
 *
 * Every call into a component runs under the core's crash guard (guard.c): an access violation, illegal instruction or
 * division by zero in the pack's own code stops that component (its stop() runs, guarded too), logs where it happened
 * and lets the game and the other components go on. A fault inside game code a component called is not taken: it
 * reaches the game's own handling, as if the pack were not there. Detours a component installs with HfApi.hook run on the
 * game's own stack, outside the guard: keep them short and validate everything they read.
 *
 * Memory. Addresses inside game.dll's or the exe's image (statics: RVA globals and tables) are read with plain loads
 * (vpm_game_u64 and friends): the image stays mapped for the whole process. Everything else (the game's heap) is read
 * through vpm_read, HellForge's ReadProcessMemory, which answers 0 on a bad pointer instead of faulting. Writes to code or
 * read-only data go through vpm_write (HfApi.write: it changes the protection for the write).
 *
 * Per-frame rules (the workspace's performance rules, in C): an idle frame stops at the component's idle gate, makes no
 * Windows calls, allocates nothing and logs nothing. Each component's file header states its calls per frame, idle and
 * active, and its test pins them through the test harness's call counts. */
#ifndef VPM_H
#define VPM_H

#include <stddef.h>
#include <stdint.h>
#include "hellforge_mod.h"

#define VPM_PACK_ID "cowboybingus.vanilla-plus-megapack"
#define VPM_PACK_NAME "Vanilla Plus Megapack"
#define VPM_GAME_BUILD "25480438"

typedef struct VpmComponent VpmComponent; /* a component's runtime record (core.c) */

/* VpmComponentDef.flags */
#define VPM_OVERLAPS_VANILLA_PLUS 0x1u /* stays off while HellForge's bundled skyeshade.vanilla-plus is in the session */
#define VPM_DEFAULT_OFF 0x2u           /* off until the player switches it on (default: on) */

typedef struct VpmComponentDef
{
    const char* id;      /* "foliage_pass_through": its settings key and log prefix; never changes */
    const char* name;    /* "Foliage Pass-Through" */
    const char* version; /* the Lua release it ports ("1.0") */
    uint32_t flags;      /* VPM_... */
    /* Registers callbacks, options and bindings. 0: running; anything else: it stays off (vpm_fail's reason, or the
     * default "start refused"). */
    int (*start)(VpmComponent* self);
    /* Optional: puts back what the component changed, when the core stops it (a fault, or vpm_fail after start). */
    void (*stop)(VpmComponent* self);
} VpmComponentDef;

/* ---- HellForge and the component ------------------------------------------------------------------------------- */

const HfApi* vpm_hf(void);
HfMod* vpm_mod(void);
const VpmComponentDef* vpm_def(const VpmComponent* self);
/* A line in the pack's log, "[Name] ..." (a file write: never on an idle frame). */
void vpm_log(VpmComponent* self, const char* format, ...) __attribute__((format(printf, 2, 3)));
/* Stops the component for the session: its tick and listeners stop, its stop() runs (when it had started), and the log
 * and its status say why ("disabled: <reason>"). Returns 1, for `return vpm_fail(...)` from start(). */
int vpm_fail(VpmComponent* self, const char* format, ...) __attribute__((format(printf, 2, 3)));
/* 1 while the component runs (started, not stopped). */
int vpm_running(const VpmComponent* self);
/* Its status as the Mods tab shows it: "running", "off", "disabled: ...". set_status replaces the running text
 * ("waiting for the projectile settings"); NULL puts back "running". */
const char* vpm_status(const VpmComponent* self);
void vpm_set_status(VpmComponent* self, const char* status);

/* ---- callbacks (register from start(); each runs guarded, only while the component runs) ----------------------- */

typedef void (*VpmLoadFn)(VpmComponent* self, HfEvent event);
typedef void (*VpmTickFn)(VpmComponent* self, float dt);
typedef void (*VpmListenFn)(VpmComponent* self, const HfEventInfo* event);

/* A HellForge load event (HF_EVENT_...), at once if it already happened. 1 registered, 0 not. */
int vpm_on_load(VpmComponent* self, HfEvent event, VpmLoadFn fn);
/* The component's game-thread tick: every game update, before the game's (HfApi.on_game_thread). One per component;
 * a second call replaces it. vpm_tick_stop ends it (from inside the tick too); vpm_tick_start may start it again. */
int vpm_tick_start(VpmComponent* self, VpmTickFn fn);
void vpm_tick_stop(VpmComponent* self);
int vpm_ticking(const VpmComponent* self);
/* A game event (HF_ON_...): HfApi.subscribe with this priority. 1 registered, 0 not (the log says why). */
int vpm_listen(VpmComponent* self, uint32_t kind, VpmListenFn fn, int32_t priority);

/* ---- memory ------------------------------------------------------------------------------------------------------ */

/* Module bases and image sizes, found once at init (0 when absent). */
uintptr_t vpm_game(void);
size_t vpm_game_size(void);
uintptr_t vpm_exe(void);
size_t vpm_exe_size(void);

/* Plain loads inside game.dll's or the exe's image, by RVA: 0 (and *out untouched) when the span is outside the image. */
int vpm_game_read(uint32_t rva, void* out, size_t size);
int vpm_exe_read(uint32_t rva, void* out, size_t size);
/* game.dll's u64 / pointer at an RVA, or 0 (outside the image, or the value is 0). */
uint64_t vpm_game_u64(uint32_t rva);
uint32_t vpm_game_u32(uint32_t rva);
uint64_t vpm_exe_u64(uint32_t rva);

/* Heap reads through HfApi.read: 1 read, 0 not (bad pointer, unmapped page). */
int vpm_read(uintptr_t address, void* out, size_t size);
int vpm_read_u8(uintptr_t address, uint8_t* out);
int vpm_read_u16(uintptr_t address, uint16_t* out);
int vpm_read_u32(uintptr_t address, uint32_t* out);
int vpm_read_u64(uintptr_t address, uint64_t* out);
int vpm_read_f32(uintptr_t address, float* out);
/* The pointer stored at address, or 0 (unreadable, or null). */
uintptr_t vpm_ptr(uintptr_t address);
/* A pointer that can be dereferenced: inside the user-mode range and not a small number. */
int vpm_plausible(uintptr_t pointer);

/* HfApi.write (protection changed for the write, instruction cache flushed): 1 written, 0 not. Not for idle frames. */
int vpm_write(uintptr_t address, const void* data, size_t size);
/* Whether [address, address + size) is committed read-write memory now (one VirtualQuery per region): to validate a heap
 * target once, when it is found, before plain stores to it. Never per frame. */
int vpm_writable(uintptr_t address, size_t size);

/* HfApi.code_matches at game.dll + rva: 1 when the bytes as the game shipped them (before any hook) match the IDA-style
 * pattern. */
int vpm_game_code_matches(uint32_t rva, const char* pattern);

/* The game's hash lookup: a 20-byte header {u64 rows, u32 capacity, u32 empty key, u32 multiplier} whose rows are
 * {u32 key, u32 index}, probed linearly from key * multiplier (at most 64 probes, a power-of-two capacity no larger than
 * limit). 1 with *index set (never 0xFFFFFFFF), 0 when the key is absent or the table unreadable. Reads: 1 + probes. */
int vpm_lookup(uintptr_t header, uint32_t key, uint32_t limit, uint32_t* index);

/* ---- the local player (Arc Thrower Revamped v1.7.1's resolution) ------------------------------------------------- */

/* game.dll globals the resolution reads */
#define VPM_RVA_PLAYER_MANAGER 0x3326468u
#define VPM_RVA_ENTITY_OWNER 0x346BF98u
#define VPM_RVA_AVATAR_MANAGER 0x3326D20u
/* action slots in the avatar manager: am + 0x150 + index * 0xA7AEC + 0x1B68 + slot * 32; held seconds at +8 */
#define VPM_ACTION_AIM 8u
#define VPM_ACTION_FIRE 9u
#define VPM_ACTION_JUMP 15u
#define VPM_ACTION_BACKPACK 37u

typedef struct VpmAvatar
{
    uint32_t record[6];  /* the avatar's 24-byte entity record: type (2 words), id, generation, ..., owned bit in word 5 */
    uintptr_t manager;   /* the avatar manager ([game + 0x3326D20]) */
    uint32_t index;      /* the avatar's index there (0 .. 7) */
    uintptr_t entity;    /* the avatar's entity pointer there (am + 0x110 + index * 8) */
} VpmAvatar;

/* The local player's own avatar through both registries (player manager -> entity owner -> avatar manager), or 0 when
 * there is none (no mission, downed, dead, another player's). About 16 reads. */
int vpm_local_avatar(VpmAvatar* out);
/* Whether a kept resolution still holds (the manager global, the entity at the kept index and its 24-byte record): 3 reads
 * where vpm_local_avatar makes 16. A respawn, a new mission or another avatar at the index fails it. */
int vpm_avatar_still(const VpmAvatar* avatar);
/* The address of one of the avatar's action slots (32 bytes; held seconds as a float at +8). */
uintptr_t vpm_action_slot(const VpmAvatar* avatar, uint32_t slot);

/* ---- options (Mod Options Menu's model) ------------------------------------------------------------------------- */

#define VPM_TOGGLE 1u
#define VPM_CHOICE 2u
#define VPM_SLIDER 3u

typedef struct VpmOption VpmOption;
typedef struct VpmOptionDef
{
    const char* id;          /* within the component ("max_depth"): saved as "<component>.<id>" */
    uint32_t kind;           /* VPM_TOGGLE, VPM_CHOICE, VPM_SLIDER */
    const char* label;       /* the row's text (English) */
    const char* description; /* shown while the row is selected, or NULL */
    double value;            /* the default: a toggle 0 or 1, a choice's 1-based index, a slider's number */
    double min, max, step;   /* a slider's range and step */
    const char* const* choices; /* a choice's texts, ending in NULL */
    int gap;                 /* 1: space above the row */
} VpmOptionDef;
typedef void (*VpmOptionFn)(VpmComponent* self, VpmOption* option, double value);

/* Registers an option (from start(); the definition must stay valid: static). Returns its handle, with the value the
 * settings file saved or the default; NULL refused (the log says why). */
VpmOption* vpm_option(VpmComponent* self, const VpmOptionDef* def);
/* The applied value: a plain load, fine on any frame. */
double vpm_option_value(const VpmOption* option);
/* Sets it from code (saved; no on_change call). 1 set, 0 refused (out of range). */
int vpm_option_set(VpmOption* option, double value);
/* Called on the game thread when the player applies a change (Mod Options Menu). One per option. */
void vpm_option_on_change(VpmOption* option, VpmOptionFn fn);

/* For Mod Options Menu: every registered option in registration order. */
int vpm_option_count(void);
VpmOption* vpm_option_at(int index);
const VpmOptionDef* vpm_option_def(const VpmOption* option);
VpmComponent* vpm_option_owner(const VpmOption* option);
/* The player applied a value: set and saved, then the owner's on_change runs (guarded). 1 applied, 0 refused. */
int vpm_option_apply(VpmOption* option, double value);

/* The pack's components, for Mod Options Menu's switches: in src/components.c's order. */
int vpm_component_count(void);
VpmComponent* vpm_component_at(int index);
/* The player's switch (saved; takes effect in the next session) and whether it is on now. */
int vpm_component_switched_on(const VpmComponent* component);
void vpm_component_switch(VpmComponent* component, int on);

/* ---- bindings (Mod Bindings Menu's model) ----------------------------------------------------------------------- */

typedef struct VpmBinding VpmBinding;
typedef struct VpmBindingDef
{
    const char* id;          /* within the component ("armory"): saved as "<component>.<id>" */
    const char* label;       /* the row's text (English) */
    const char* category;    /* the heading it is listed under, or NULL for the component's name */
    uint32_t slot;           /* Mod Bindings Menu's fixed native slot, 0 for any free action */
    uint32_t key;            /* the fixed key without Mod Bindings Menu: a Windows virtual-key code, 0 none */
} VpmBindingDef;

/* Registers a binding (from start(); the definition must stay valid). NULL refused. */
VpmBinding* vpm_binding(VpmComponent* self, const VpmBindingDef* def);
/* 1 down, 0 up, -1 unknown (no bindings backend, or it cannot answer now): the caller then uses its fixed key. */
int vpm_binding_down(const VpmBinding* binding);

/* Mod Bindings Menu: the backend that answers vpm_binding_down. attach runs for every binding, registered before or
 * after the backend; its result (backend data) is kept with the binding. */
typedef struct VpmBindingBackend
{
    void* (*attach)(VpmBinding* binding);
    int (*down)(const VpmBinding* binding, void* data);
} VpmBindingBackend;
void vpm_bindings_set_backend(VpmComponent* owner, const VpmBindingBackend* backend);
int vpm_binding_count(void);
VpmBinding* vpm_binding_at(int index);
const VpmBindingDef* vpm_binding_def(const VpmBinding* binding);
VpmComponent* vpm_binding_owner(const VpmBinding* binding);
void* vpm_binding_data(const VpmBinding* binding);

/* ---- the settings file ------------------------------------------------------------------------------------------ *
 * For what options do not cover (Mod Bindings Menu's assignments): "key = value" text in a section of the pack's
 * settings file, saved about a second after a change. Sections "components", "options" and "bindings" belong to the
 * core. Keys under 128 bytes, values under 256. */
const char* vpm_setting(const char* section, const char* key); /* NULL when absent */
void vpm_setting_put(const char* section, const char* key, const char* value); /* value NULL removes it */
void vpm_settings_save_soon(void);

/* ---- Windows functions resolved at run time --------------------------------------------------------------------- *
 * user32's are found with GetProcAddress at init, so the DLL links only kernel32 (HellForge's own source build passes no
 * libraries). NULL when absent. Each call is a Windows call: never on an idle frame. */
typedef struct VpmUser32
{
    short (__stdcall* GetAsyncKeyState)(int key);
    int (__stdcall* GetCursorPos)(void* point);
    void* (__stdcall* GetForegroundWindow)(void);
    int (__stdcall* ScreenToClient)(void* window, void* point);
    int (__stdcall* GetClientRect)(void* window, void* rect);
    unsigned long (__stdcall* GetWindowThreadProcessId)(void* window, unsigned long* process);
} VpmUser32;
const VpmUser32* vpm_user32(void);

/* ---- text ------------------------------------------------------------------------------------------------------- */

/* A component's text in the game's language: English until translations are added. */
const char* vpm_text(const VpmComponent* self, const char* key, const char* english);

#endif
