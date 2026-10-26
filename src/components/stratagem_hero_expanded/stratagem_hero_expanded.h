/* Stratagem Hero Expanded: what its test reaches besides the component's definition (src/components.h). */
#ifndef STRATAGEM_HERO_EXPANDED_H
#define STRATAGEM_HERO_EXPANDED_H

#include <stddef.h>
#include <stdint.h>
#include <windows.h>

/* The page query and the store the component makes, as the Lua's `native` was (Mod.native: VirtualQuery and
 * WriteProcessMemory). NULL, the default: VirtualQuery and a plain store. The test gives its own, as the Lua's tests did:
 * its fake game.dll is private memory, not an image. */
typedef struct StratagemHeroNative
{
    SIZE_T (*query)(uintptr_t address, MEMORY_BASIC_INFORMATION* region); /* sizeof *region when answered */
    int (*store)(uintptr_t address, const void* data, size_t size);      /* 1 stored */
} StratagemHeroNative;
extern const StratagemHeroNative* stratagem_hero_expanded_native;

/* Whether [address, address + size) lies in committed image pages of the module at `module` that can be written
 * (read-write, copy-on-write, or their executable forms: never code-only, read-only, guard or private pages), one page
 * query per region; `seen` gets the protections ("0x04, 0x04"). The Lua's Mod.image_writable. */
int stratagem_hero_expanded_image_writable(uintptr_t module, uintptr_t address, size_t size, char* seen, size_t seen_size);

#endif
