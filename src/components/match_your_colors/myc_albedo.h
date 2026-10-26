/* Match Your Colors: modded gear without a color table (albedo.lua, v1.5): a mod's material that paints its colors
 * into its albedo texture is read as clusters (analysis rows) and recolored by moving its block endpoints. Runs on the
 * worker inside a job. */
#ifndef MYC_ALBEDO_H
#define MYC_ALBEDO_H

#include "myc_kits.h"

#define MYC_SLOT_ALBEDO 0xac652e43u
#define MYC_SLOT_MRA 0x756f6fa6u
#define MYC_ALBEDO_TEMPLATE 0x7712ee7808e0ec50ull

/* A material's texture slots (material_textures): slot -> texture name. */
typedef struct MycTexSlot { uint32_t slot; uint64_t name; } MycTexSlot;
typedef struct MycTexSlots { MycTexSlot* slots; int count; uint64_t parent; } MycTexSlots;
int myc_tex_slot(const MycTexSlots* t, uint32_t slot, uint64_t* name);

typedef struct MycAlbedoEntry { uint64_t albedo, mra; int has_mra; } MycAlbedoEntry;
/* Albedo.eligible: 1 with entry, 0 not readable here (why), -1 after myc_fail. */
int myc_albedo_eligible(const MycRecord* record, const MycTexSlots* textures, MycFind* find, MycAlbedoEntry* out,
    char* why, size_t size, MycErr* err);
/* Albedo.read: the clusters, NULL with why (no opaque texel), or NULL after myc_fail. */
MycAlbedo* myc_albedo_read(MycFind* find, const MycAlbedoEntry* entry, MycArena* arena, char* why, size_t size,
    MycErr* err);
/* A cluster's look and the albedo that looks like a goal (Albedo.look / unlook). */
MycLab myc_albedo_look(double r, double g, double b);
MycLab myc_albedo_unlook(double L, double a, double b);

/* BC1/BC3 color block decode (Albedo.color_block) and the endpoint rewrite (Albedo.rewrite), for the tests. */
void myc_albedo_color_block(const uint8_t* p, uint8_t out[64], int three_color);

#endif
