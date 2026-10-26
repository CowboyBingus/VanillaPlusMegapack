/* A stand-in for HellForge and the game, for the pack's tests: an HfApi whose memory calls work on fake game.dll and exe
 * images (zeroed, as large as build 25480438's) and a fake heap, whose events, ticks and live edits the test drives,
 * and which counts every call so a test can pin a component's calls per frame.
 *
 * Reads and writes through the API succeed only inside the fake images and the fake heap, outside any hole the test made
 * (fake_hole): what ReadProcessMemory would answer for a bad pointer. Plain loads by components into the images are
 * ordinary memory. */
#ifndef FAKE_HF_H
#define FAKE_HF_H

#include <stddef.h>
#include <stdint.h>
#include "hellforge_mod.h"
#include "core/vpm_core.h"

#define FAKE_GAME_SIZE 0x4744000u /* game.dll's SizeOfImage on 25480438 */
#define FAKE_EXE_SIZE 0x39E8000u  /* helldivers2.exe's */

typedef struct FakeCounts
{
    uint32_t read, write, code_matches, find_pattern, get_live, set_live, hook, log, subscribe, on, other;
    uint32_t writable; /* VirtualQuery calls of vpm_writable */
    uint32_t exports;  /* vpm_module_export lookups */
} FakeCounts;

/* A fresh HellForge and game: zeroed images and heap, no events fired, no logs, counts 0, the core reset, game state
 * HF_STATE_NONE, build 25480438, no other mods. */
void fake_setup(void);
const HfApi* fake_api(void);
HfMod* fake_mod(void);
/* vpm_core_init with the fake API and these components. */
int fake_start(const VpmComponentDef* const* defs, int count);
/* The component started from defs[index] by fake_start. */
VpmComponent* fake_component(int index);

uintptr_t fake_game(void);
uintptr_t fake_exe(void);
/* Zeroed, 16-byte aligned memory the API reads and writes (a 256 MB arena; reset by fake_setup). */
void* fake_heap(size_t size);
/* API reads and writes touching [address, address + size) fail from now on. */
void fake_hole(uintptr_t address, size_t size);
/* The holes made at address (fake_hole) are gone: reads and writes there work again. */
void fake_unhole(uintptr_t address);
/* The API's write fails from now on (protection refused). Otherwise it writes read-only pages too, as HellForge's
 * write does (it changes their protection for the write). */
void fake_refuse_writes(int refuse);

/* Fires a load event: its registered callbacks run, later registrations get it at once. */
void fake_fire(HfEvent event);
/* Runs the game-thread callback n times; after each, the step fake_after_tick named (the game's own update), if any. */
void fake_frames(int n, float dt);
void fake_after_tick(void (*fn)(float dt));
/* What vpm_user32() answers from now on (a test's stand-ins for GetAsyncKeyState and the others). */
void fake_user32(const VpmUser32* table);
/* The detour the code hooked at target last (hook, hook_ex, vpm_hook), or NULL. Its *original is the target itself
 * (a fake_stand_in's jump reaches the test's function), unless fake_set_original named another. */
void* fake_hook_detour(uintptr_t target);
/* Delivers a game event to its listeners (event->kind). */
void fake_emit(const HfEventInfo* event);
void fake_set_state(uint32_t state);
void fake_set_build(const char* build);
void fake_add_mod(const char* id, uint32_t kind);

FakeCounts fake_counts(void);
void fake_counts_reset(void);

/* The log: every line since fake_setup or fake_log_clear. */
int fake_log_has(const char* text);
const char* fake_log_text(void);
void fake_log_clear(void);
/* Prints the log lines as they come (for debugging a test). */
void fake_log_echo(int echo);

/* Live fields (get_live, set_live), by target, component record name and offset. */
void fake_live_put(uint64_t target, const char* component, uint16_t offset, HfValue value);
int fake_live_now(uint64_t target, const char* component, uint16_t offset, HfValue* out);
/* set_live on that field also stores the value at memory (its record's field), as HellForge's live edit does. */
void fake_live_bind(uint64_t target, const char* component, uint16_t offset, uintptr_t memory);

/* Hooks the code made (hook, hook_ex), and the original a test gives a hooked target. */
typedef struct FakeHook { uintptr_t target; void* detour; int32_t priority; } FakeHook;
int fake_hook_count(void);
FakeHook fake_hook_at(int index);
void fake_set_original(uintptr_t target, void* original);

/* What projectile_row, damage_row, stratagem_row, difficulty_row ("projectile", "damage", "stratagem", "difficulty"),
 * component_record and record (the component's name, by resource) answer for an id. */
void fake_set_row(const char* table, uint64_t id, uintptr_t row);
/* The same with the record size component_record answers in *stride. */
void fake_set_record(const char* table, uint64_t id, uintptr_t row, uint32_t stride);

/* A stand-in for a game function at game.dll + rva: code_matches and read_code see `shipped` (an IDA-style pattern of
 * concrete bytes, at least 14 of them: the function as the game shipped it), while the image holds a jump to fn, so a
 * component that checked the bytes and then calls game.dll + rva calls fn. The page is made executable. */
void fake_stand_in(uint32_t rva, const char* shipped, void* fn);
/* What vpm_module_export answers for a module's export (NULL: absent, the default for every name). */
void fake_export(const char* module, const char* name, void* fn);
/* After the nth API read (1: the next) that touches address, fn(user) runs, right after that read. One at a time. */
void fake_after_read(uintptr_t address, int nth, void (*fn)(void*), void* user);

/* MurmurHash64A, seed 0: the game's resource name hash (resource_hash). */
uint64_t fake_murmur64(const void* data, size_t size);

#endif
