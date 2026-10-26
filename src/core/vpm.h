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
/* The component's game-thread tick: once per frame, at the start of game.dll's update, where the Lua global `update`
 * ran (the engine calls game.dll's update right after it). The core hooks that update (game.dll 0xAB5000) once its code
 * is decoded; until then, or without the hook, the ticks run from HellForge's game-thread callback, which is inside the
 * same update a little later (before the RPC pump, the world update and the UI pass). One per component; a second call
 * replaces it. vpm_tick_stop ends it (from inside the tick too); vpm_tick_start may start it again. */
int vpm_tick_start(VpmComponent* self, VpmTickFn fn);
void vpm_tick_stop(VpmComponent* self);
int vpm_ticking(const VpmComponent* self);
/* A tick after game.dll's whole update in the same frame (after the world update, the mode's update and the UI pass):
 * for work the Lua did after the game's update, or a second check in the frame. Without the core's hook of the update
 * it runs right after the frame's ticks. One per component, as vpm_tick_start. */
int vpm_post_tick_start(VpmComponent* self, VpmTickFn fn);
void vpm_post_tick_stop(VpmComponent* self);
int vpm_post_ticking(const VpmComponent* self);
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

/* Heap reads: 1 read, 0 not (outside the user-mode range, unmapped, no-access or guard page). Plain loads under a guard
 * of their own: a bad pointer fails the read, never the game, and stops nothing; no Windows call (unmeasured in game;
 * about 25 ns in the test process) where the Lua's ReadProcessMemory cost 1-2 us in game. */
int vpm_read(uintptr_t address, void* out, size_t size);
int vpm_read_u8(uintptr_t address, uint8_t* out);
int vpm_read_u16(uintptr_t address, uint16_t* out);
int vpm_read_u32(uintptr_t address, uint32_t* out);
int vpm_read_u64(uintptr_t address, uint64_t* out);
int vpm_read_f32(uintptr_t address, float* out);
/* The user-mode pointer stored at address, or 0: unreadable, or not plausible (the Lua runtime's api.pointer). */
uintptr_t vpm_ptr(uintptr_t address);
/* A user-mode pointer as the Lua runtime's api.pointer accepts one: at least 0x10000 and below 2^47. */
int vpm_plausible(uintptr_t pointer);

/* HfApi.write (protection changed for the write, instruction cache flushed): 1 written, 0 not. Not for idle frames. */
int vpm_write(uintptr_t address, const void* data, size_t size);
/* Whether [address, address + size) is committed private read-write memory now, the Lua runtime's api.writable_data rule:
 * never code, read-only, guard, mapped or module image pages. One VirtualQuery per region: to validate a heap target
 * once, when it is found, before plain stores to it. Never per frame. */
int vpm_writable(uintptr_t address, size_t size);

/* An export of a loaded module (GetModuleHandleA + GetProcAddress; the tests' harness stands in for it), or NULL: a
 * plugin's functions (Wwise's), looked up once, never per frame. */
void* vpm_module_export(const char* module, const char* name);

/* HfApi.code_matches at game.dll + rva: 1 when the bytes as the game shipped them (before any hook) match the IDA-style
 * pattern. */
int vpm_game_code_matches(uint32_t rva, const char* pattern);
/* The same at helldivers2.exe + rva. */
int vpm_exe_code_matches(uint32_t rva, const char* pattern);

/* Code checks that wait for game.dll's code to be decoded. HellForge fires HF_EVENT_GAME_LOADED once one pin of
 * game.dll reads as decoded, and the rest of its code is decoded in parts after that (HellForge itself gives its own
 * pins 20 s): a check made at that event can fail on code that is still encoded. vpm_when_code_ready checks every pin
 * (VpmCodePin: an RVA, its pattern as shipped, a name for the log, VPM_PIN_EXE for the exe's) at
 * HF_EVENT_GAME_LOADED, then every 30 frames until all match, for at most VPM_CODE_WAIT_SECONDS of game time; ready
 * runs once (guarded, with HF_EVENT_GAME_LOADED) when they match. After the wait the component is stopped:
 * "disabled: <name> changed (game.dll 0x<rva>)". The pins must stay valid (static). 1 registered, 0 not. While waiting:
 * one code_matches per pin every 30 frames (an API call), nothing afterwards. */
#define VPM_PIN_EXE 0x1u
#define VPM_CODE_WAIT_SECONDS 60.0f
typedef struct VpmCodePin { uint32_t rva; const char* pattern; const char* name; uint32_t flags; } VpmCodePin;
int vpm_when_code_ready(VpmComponent* self, const VpmCodePin* pins, int count, VpmLoadFn ready);

/* The game's hash lookup: a 20-byte header {u64 rows, u32 capacity, u32 empty key, u32 multiplier} whose rows are
 * {u32 key, u32 index}, probed linearly from key * multiplier (at most 64 probes, a power-of-two capacity no larger than
 * limit). 1 with *index set (never 0xFFFFFFFF), 0 when the key is absent or the table unreadable. Reads: 1 + probes. */
int vpm_lookup(uintptr_t header, uint32_t key, uint32_t limit, uint32_t* index);

/* ---- hooks (detours) -------------------------------------------------------------------------------------------- *
 * vpm_hook detours game.dll + rva (vpm_hook_exe: the exe + rva) to detour, after checking the function's bytes as the
 * game shipped them (HfApi.code_matches: another mod's hook does not hide them) against `shipped`, an IDA-style pattern
 * of its first instructions. *original receives what the detour calls to go on (HfApi.hook_ex: the next hook in the
 * function's chain, or the function). 1 hooked, 0 not (the log says why). Call it from start() for the exe, from
 * HF_EVENT_GAME_LOADED or later for game.dll. Hooks stay for the session, so:
 *   - a detour checks vpm_running(self) first and, when the component is stopped, only calls *original;
 *   - a detour runs on the game's stack, outside the core's guard: its own work goes in a function run with
 *     vpm_guarded, and *original is called outside it;
 *   - mark it `lint: per-frame` (it runs on every call of the game's function). */
int vpm_hook(VpmComponent* self, uint32_t rva, const char* shipped, void* detour, void** original);
int vpm_hook_exe(VpmComponent* self, uint32_t rva, const char* shipped, void* detour, void** original);
/* Runs fn(arg) under the crash guard for the component: 1 when it ran to its end, 0 after a fault (the component is then
 * stopped and its stop() run). For a detour's own work. */
int vpm_guarded(VpmComponent* self, void (*fn)(void*), void* arg);

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
    uintptr_t record_at; /* where the entity owner keeps the avatar's record (owner + 0xF32F18 + entity index * 24) */
    uint32_t owner_index; /* the avatar's entity index in the entity owner */
} VpmAvatar;

/* The local player's own avatar through both registries (player manager -> entity owner -> avatar manager), or 0 when
 * there is none (no mission, downed, dead, another player's): 12 reads. why, when not NULL, receives the step that
 * failed ("no player manager", "not an owned Helldiver avatar", ...), a static text. */
int vpm_local_avatar(VpmAvatar* out);
int vpm_local_avatar_why(VpmAvatar* out, const char** why);
/* Whether a kept resolution still holds (the manager global, the entity at the kept index and its 24-byte record): 3 reads
 * where vpm_local_avatar makes 16. A respawn, a new mission or another avatar at the index fails it. */
int vpm_avatar_still(const VpmAvatar* avatar);
/* The address of one of the avatar's action slots (32 bytes; held seconds as a float at +8). */
uintptr_t vpm_action_slot(const VpmAvatar* avatar, uint32_t slot);

/* ---- options (Mod Options Menu's model) ------------------------------------------------------------------------- */

#define VPM_TOGGLE 1u
#define VPM_CHOICE 2u
#define VPM_SLIDER 3u

/* Limits, as Mod Options Menu's (options.lua, rows.lua); vpm_option refuses an option past them and logs why. */
#define VPM_MAX_COMPONENTS 32      /* components in the pack */
#define VPM_MAX_OPTIONS 256        /* options in the pack */
#define VPM_OPTION_ROWS 32         /* options per component (one category's rows) */
#define VPM_OPTION_LABEL 64        /* characters of a label */
#define VPM_OPTION_DESCRIPTION 400 /* characters of a description */
#define VPM_OPTION_CHOICES 16      /* a choice's names: 2 to 16 */
#define VPM_OPTION_CHOICE 48       /* characters of a choice's name */

typedef struct VpmOption VpmOption;
typedef struct VpmOptionDef
{
    const char* id;          /* within the component ("max_depth"): saved as "<component>.<id>" */
    uint32_t kind;           /* VPM_TOGGLE, VPM_CHOICE, VPM_SLIDER */
    const char* label;       /* the row's text (English) */
    const char* description; /* shown while the row is selected, or NULL */
    double value;            /* the default: a toggle 0 or 1, a choice's 1-based index, a slider's number */
    double min, max, step;   /* a slider's range and step (0: 1, Mod Options Menu's default); values snap to the step
                              * and to the decimals it needs (at most 3; at least 1 when min is not whole) */
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
/* A count that goes up whenever an option's value changes (set or applied): an open view compares it to redraw. */
uint32_t vpm_option_revision(void);

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
/* 1 down, 0 up, -1 unknown (no bindings backend, or it cannot answer now): the caller then uses its fixed key. The
 * backend answers under its own guard: a fault there stops the backend, and this answers -1. */
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
 * core. Keys under 128 bytes, values under 1024. */
const char* vpm_setting(const char* section, const char* key); /* NULL when absent */
/* The section's entries one by one, in the file's order: start *cursor at 0; 1 with *key and *value set, 0 after the
 * last. The texts are valid until the next vpm_setting_put. */
int vpm_setting_next(const char* section, int* cursor, const char** key, const char** value);
void vpm_setting_put(const char* section, const char* key, const char* value); /* value NULL removes it */
void vpm_settings_save_soon(void);
/* Writes a waiting change now (Mod Options Menu's APPLY, as the Lua saved at once); nothing when none waits. */
void vpm_settings_save_now(void);

/* The component's own folder for files it keeps between sessions (caches, profiles):
 * %LOCALAPPDATA%\CowboyBingus\VanillaPlusMegapack\<component id>, as the game sees it (HellForge points the game's
 * LOCALAPPDATA at the installation's user data and copies a sandboxed session's back). Made when missing. 1 with the
 * path in out (UTF-16, terminated), 0 when it cannot be made. File work only off idle frames. */
int vpm_data_folder(const VpmComponent* self, wchar_t* out, size_t size);

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

/* UTF-8, as the Lua text module (bingus_text.lua v1) every text-showing component carried (core text.c):
 * - decode: the code point at text (at most size bytes), its length in bytes, or 0 when the bytes are not valid UTF-8
 *   (overlong forms, surrogates and values above U+10FFFF are invalid);
 * - encode: a code point's bytes (U+10FFFF at most) into out (room for 4), their count;
 * - check: 1 for text a mod may show (valid UTF-8 without control characters; a line feed only with multiline), -1
 *   invalid UTF-8 or -2 a control character, at byte *bad (1-based, when bad is not NULL); NULL is no text: -1 at 0;
 * - length: code points in the first size bytes (an invalid byte counts as one);
 * - upper: upper case for the scripts the game's fonts carry (ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic) into
 *   out (size bytes, always terminated), its length; others, invalid bytes included, stay as they are;
 * - clip: the longest start of text within `bytes` that cuts no character, its length. */
int vpm_utf8_decode(const char* text, size_t size, uint32_t* value);
int vpm_utf8_encode(uint32_t value, char* out);
int vpm_utf8_check(const char* text, int multiline, size_t* bad);
size_t vpm_utf8_length(const char* text, size_t size);
uint32_t vpm_upper_char(uint32_t value);
size_t vpm_upper(const char* text, char* out, size_t size);
size_t vpm_utf8_clip(const char* text, size_t bytes);

#endif
