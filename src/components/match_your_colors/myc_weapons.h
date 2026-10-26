/* Match Your Colors: the Helldiver's weapons (weapons.lua, Recolor Weapons v1.5) and the generated weapon tables
 * (myc_weapon_data.c). */
#ifndef MYC_WEAPONS_H
#define MYC_WEAPONS_H

#include "myc_kits.h"

typedef struct MycWdText { uint64_t unit; const char* text; } MycWdText;
typedef struct MycWdClass { const char* scheme; const char* key; uint64_t lut; } MycWdClass;
typedef struct MycWdPair { uint64_t key, value; } MycWdPair;
extern const int myc_wd_unit_count, myc_wd_schemes_count, myc_wd_decals_count, myc_wd_unit_of_count,
    myc_wd_attachment_archive_count;
extern const MycWdText myc_wd_units[];
extern const MycWdClass myc_wd_schemes[];
extern const MycWdClass myc_wd_decals[];
extern const MycWdPair myc_wd_unit_of[];
extern const MycWdPair myc_wd_attachment_archive[];

/* A weapon unit's material as the game draws it (Kits.weapon_rows): its LOD0 triangles and its rows' shares (8); 0
 * when the table has no such unit or material. */
int myc_weapon_rows(uint64_t unit, uint64_t material, double* triangles, double shares[8]);
/* unit_of and attachment_archive: 1 with *out when listed. */
int myc_weapon_unit_of(uint64_t weapon, uint64_t* out);
int myc_weapon_attachment_archive(uint64_t unit, uint64_t* out);

#endif
