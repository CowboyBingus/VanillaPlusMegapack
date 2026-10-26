/* Match Your Colors: the Helldiver's weapons in game memory (weapons.lua): the inventory row, each weapon's units and
 * paint, the Armory's preview weapon, the weapon catalogue's packages and the customization deltas the game composes a
 * preview from. Reads only (myc_weapons_mem.c). */
#ifndef MYC_WEAPON_MEM_H
#define MYC_WEAPON_MEM_H

#include "myc_runtime.h"

#define MYC_COPY_SPAN (200 + 400 + 408 * 10 - 0x78)
#define MYC_INVENTORY_ROW 48
#define MYC_CATALOGUE_BYTES 17280

/* An avatar's inventory row (Weapons.locate): with owned also its row's entity (Weapons.owned compares them). */
typedef struct MycInventoryWhere
{
    uintptr_t inventory, rows, row, owners, owner;
    uint32_t avatar, index;
} MycInventoryWhere;
int myc_weapons_locate(uint32_t avatar, int owned, MycInventoryWhere* out);
/* Whether where is still the row of its avatar (2 reads); 1 without an entity to compare. */
int myc_weapons_owned(const MycInventoryWhere* where);

/* An inventory row's weapons (Weapons.resolve): list[1..3] (has[slot]), the slot in hand, the entity ids. */
typedef struct MycResolved { MycWeapon list[4]; int has[4]; uint32_t held, ids[4]; } MycResolved;
int myc_weapons_resolve(const MycInventoryWhere* where, uint8_t* big, MycResolved* out);
void myc_weapons_decode_copy(MycWeapon* w, const uint8_t* big);
/* The package (archive) of a weapon id, or 0; buffer: MYC_CATALOGUE_BYTES. */
uint64_t myc_weapons_package(uint64_t name, uint8_t* buffer);
/* A preview weapon's customization as the game composes it (its ids), decoded into w; 0 with why. */
int myc_weapons_compose(MycWeapon* w, uint8_t* big, const char** why);
/* The Armory's preview weapon (slot 3); 0 when it holds none. */
int myc_weapons_preview(MycWeapon* out);
void myc_weapons_preview_key(const MycWeapon* w, char* out, size_t size);
/* The units of weapons list[1..3] (NULL: none) as a controller's fixed units. */
int myc_weapons_units(const MycWeapon* const* list, MycUnitRef* out, int max);

/* The idle checks: the inventory row (48 bytes) and one binding's texture field. */
typedef struct MycInventoryWatch { uintptr_t row; uint8_t now[MYC_INVENTORY_ROW], kept[MYC_INVENTORY_ROW]; int primed, reads; } MycInventoryWatch;
void myc_inventory_watch_init(MycInventoryWatch* w, const MycInventoryWhere* where);
int myc_inventory_row_changed(MycInventoryWatch* w);
uint32_t myc_inventory_held(const MycInventoryWatch* w);
int myc_inventory_bound(MycInventoryWatch* w, uint64_t entry, uint64_t texture);

#endif
