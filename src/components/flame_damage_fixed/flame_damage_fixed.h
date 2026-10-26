/* Flame Damage Fixed: what the component's files share (flame_damage_fixed.c drives; flame_effect.c, flame_physics.c
 * and flame_particles.c are the Lua's Fix.* functions). Addresses and layouts for build 25480438, as the Lua's. */
#ifndef FLAME_DAMAGE_FIXED_H
#define FLAME_DAMAGE_FIXED_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"

/* helldivers2.exe RVAs */
#define FDF_RESOURCE_ROOT 0x23621A8u  /* object whose +0x3F8 is the resource manager */
#define FDF_FILTER_PTR 0x27C5E40u     /* the world's hknpGroupCollisionFilter */
#define FDF_FILTER_VTABLE 0x148B938u
#define FDF_WORLDS 0x27BA890u         /* the physics world wrappers, FDF_WORLD_STRIDE apart */
#define FDF_WORLD_STRIDE 176u
#define FDF_WORLD_VTABLE 0x14B3148u
#define FDF_UNITS 0x1A100F0u          /* the unit registry */
#define FDF_GROUPS 0x27C5B88u         /* the system-group allocator */
/* game.dll RVAs */
#define FDF_SPRAY_MANAGER 0x3326BB0u  /* SprayWeaponComponent manager pointer */
#define FDF_WORLD_PTR 0x346BFA0u      /* object whose +0x230888 is the particle manager */

/* The shared Lumberer arm / Flame Sentry firing effect (resource name hash, lo and hi halves) */
#define FDF_EFFECT_LO 0xA42863C4u
#define FDF_EFFECT_HI 0xE3D15622u
#define FDF_EFFECT_SIZE 30896u
#define FDF_EMPTY_BUCKET 0xFFFFFFFEu
#define FDF_CHAIN_END 0x7FFFFFFFu

/* Havok (hknp) filter info: layer (bits 0-6) | subsystem (7-13) | don't-collide subsystem (14-20) | group (21-31). */
#define FDF_FLAME_LAYER 11u
#define FDF_GROUP_SHIFT 21u
#define FDF_GROUP_LOW 2040u
#define FDF_GROUP_TOP 2047u
#define FDF_GROUPS_OWN (FDF_GROUP_TOP - FDF_GROUP_LOW + 1u)
#define FDF_PS_FILTER 5764u           /* a particle system's query filter info */

#define FDF_MAX_INSTANCES 64
#define FDF_MAX_SYSTEMS 32
#define FDF_MAX_FAMILY 16
#define FDF_MAX_BODIES 64
#define FDF_MAX_WORLDS 4
#define FDF_PATCH_COUNT 18

/* What a failed step reports (the Lua's reason strings): an id, and for the per-word effect reasons the patch row. */
typedef uint32_t FdfReason;
enum
{
    FDF_OK = 0,
    FDF_RESOURCE_MANAGER, FDF_TYPE_TABLE, FDF_PARTICLES_TYPE, FDF_NAME_TABLE, FDF_EFFECT_NOT_LOADED, FDF_EFFECT_PENDING,
    FDF_EFFECT_RECORD, FDF_HEADER_CHANGED, FDF_LAYOUT_CHANGED, FDF_EFFECT_WRITABLE, FDF_UNKNOWN_VALUE, FDF_VERIFY_FAILED,
    FDF_FILTER_UNAVAILABLE, FDF_FILTER_TYPE, FDF_FLAME_ROW, FDF_UNIT_REGISTRY, FDF_WEAPON_UNIT, FDF_UNIT_UNREADABLE,
    FDF_FAMILY_TOO_LARGE, FDF_NO_WORLD, FDF_BODY_ARRAY, FDF_TOO_MANY_BODIES, FDF_BODY_WRITABLE, FDF_PARTICLE_WRITABLE,
    FDF_ON_BODIES, FDF_IN_ALLOCATOR,
    FDF_REASON_COUNT
};
#define FDF_REASON_AT(id, row) ((FdfReason)(id) | ((FdfReason)(row) << 8))
/* The reason's text ("unknown value at 328"): out, for a "%s". */
const char* fdf_reason_text(FdfReason reason, char* out, size_t size);

/* ---- the effect (flame_effect.c) ----------------------------------------------------------------------------- */

typedef struct FdfPatch { uint32_t offset, shipped, fixed; } FdfPatch;
extern const FdfPatch fdf_patches[FDF_PATCH_COUNT];
extern const uint32_t fdf_effect_header[24];    /* the shipped file's first 0x60 bytes */
extern const uint32_t fdf_effect_systems[12][2]; /* every system's (offset, size), in file order */

/* The loaded shared effect's data: 1 with *data, or 0 with *why. Reads only. */
int fdf_resolve_effect(uintptr_t* data, FdfReason* why);
/* Writes the fixed value of every patched word that still holds the shipped one, after checking the header, the
 * layout and every patched word: 1 with *writes, or 0 with *why. */
int fdf_apply_effect(uintptr_t data, int* writes, FdfReason* why);

/* ---- physics: filter, family, body scan, groups (flame_physics.c) -------------------------------------------- */

/* The last committed private read-write region a series of stores checked (0, 0: none yet). */
typedef struct FdfRegion { uintptr_t low, high; } FdfRegion;
/* Whether a 4-byte store at target may go ahead: inside the region checked last, or in a new one (one VirtualQuery). */
int fdf_region_writable(FdfRegion* region, uintptr_t target);
/* A store into memory validated with fdf_region_writable or vpm_writable on this frame. */
void fdf_store(uintptr_t target, uint32_t value);
/* Whether a layer is one the flame can hit (layer 11's row in the world's collision matrix). */
int fdf_hittable(uint32_t layer);

/* The world's collision filter, checked against the recorded flame row: 1 with *filter, or 0 with *why. */
int fdf_check_filter(uintptr_t* filter, FdfReason* why);

/* A weapon's family: the unit handles of its parent (or itself) and every descendant except avatar subtrees. */
typedef struct FdfFamily { uint32_t units[FDF_MAX_FAMILY]; int n; } FdfFamily;
int fdf_in_family(const FdfFamily* family, uint32_t unit);
/* Fills the family from the weapon unit's handle: its size, or -1 with *why. */
int fdf_family(uint32_t handle, FdfFamily* family, FdfReason* why);

/* A body scan and its result: the family's flame-hittable bodies, and which of groups 2040-2047 other bodies carry. */
typedef struct FdfJob
{
    uintptr_t bases[FDF_MAX_WORLDS];  /* each world's body array and index bound */
    uint32_t limits[FDF_MAX_WORLDS];
    int worlds, w;                    /* the world being scanned and the next body index in it */
    uint32_t i;
    int n;                            /* kept bodies */
    uintptr_t base[FDF_MAX_BODIES];   /* each kept body: its body array, index, layer, actor and unit */
    uint32_t index[FDF_MAX_BODIES];
    uint32_t layer[FDF_MAX_BODIES];
    uint32_t actor[FDF_MAX_BODIES];
    uint32_t unit[FDF_MAX_BODIES];
    uint8_t marked[FDF_MAX_BODIES];   /* carries the weapon's group */
    int span_k[FDF_MAX_BODIES + 1];   /* read spans: span s covers kept bodies span_k[s] .. span_k[s + 1] - 1 */
    uintptr_t span_base[FDF_MAX_BODIES];
    int spans;
    uint8_t foreign[FDF_GROUPS_OWN];  /* group 2040 + g is carried by a body that is not this mod's */
} FdfJob;

/* Whether a body of unit carrying group g belongs to one of this mod's weapons (the driver's own_body). */
typedef int (*FdfOwnFn)(uint32_t group, uint32_t unit);
typedef struct FdfScanFor { const FdfFamily* family; uint32_t group; FdfOwnFn own; } FdfScanFor;

/* Starts a body scan over every physics world: 1, or 0 with *why. */
int fdf_scan_begin(FdfJob* job, FdfReason* why);
/* Advances it by up to `blocks` block reads: 1 complete, 0 continues, -1 with *why. */
int fdf_scan_step(FdfJob* job, const FdfScanFor* scan, int blocks, FdfReason* why);

/* The kept bodies by class for group g (0: none), one read per span. */
typedef struct FdfCounts { int own, free, moved, stale; } FdfCounts;
int fdf_verify(FdfJob* job, uint32_t g, FdfCounts* counts);
/* Puts the kept group-free bodies into group g: how many carry g afterwards, or -1 with *why. */
int fdf_mark(FdfJob* job, uint32_t g, FdfReason* why);
/* Takes group g off every kept body of its unit that carries it: how many, or -1 with *why. */
int fdf_unmark(FdfJob* job, uint32_t g, FdfReason* why);
/* Whether the game's system-group allocator still marks group g free. */
int fdf_group_free(uint32_t g);

/* ---- the flame's particle systems (flame_particles.c) -------------------------------------------------------- */

/* The shared flame's instance list entry {count, records} in the particle manager, or 0. */
uintptr_t fdf_flame_slot(void);
/* The flame instance with this id in the slot: 1 with *sim (its simulation, 0 when unreadable), or 0. */
int fdf_find_instance(uintptr_t slot, uint32_t id, uintptr_t* sim);
/* Sets the filter info of an instance's particle systems that hold `from` to `value`: how many, or -1 with *why. */
int fdf_retarget(uintptr_t sim, uintptr_t data, FdfRegion* region, uint32_t value, uint32_t from, FdfReason* why);
/* The same for every live instance in the slot: how many systems, or -1 with *why. */
int fdf_restore_flames(uintptr_t slot, uintptr_t data, FdfRegion* region, uint32_t value, uint32_t from, FdfReason* why);

/* ---- tests ------------------------------------------------------------------------------------------------------ */
#ifdef VPM_TEST
/* The calls the fake API does not count: VirtualQuery for a store region, vpm_writable checks, plain stores. */
typedef struct FdfTestCounts { uint32_t queries, writable, stores; } FdfTestCounts;
extern FdfTestCounts fdf_test_counts;
#define FDF_COUNT(field) (fdf_test_counts.field++)
/* A tracked weapon's state, by its spray instance address: 1 with *out, 0 when no weapon is there. */
typedef struct FdfTestWeapon
{
    uint32_t group;
    int marked, job_ok, kept, destroyed, scanning, flames;
    uint32_t foreign; /* bit g - 2040: the last complete scan found other bodies in group g */
} FdfTestWeapon;
int fdf_test_weapon(uintptr_t address, FdfTestWeapon* out);
int fdf_test_tracked(void);
#else
#define FDF_COUNT(field) ((void)0)
#endif

#endif
