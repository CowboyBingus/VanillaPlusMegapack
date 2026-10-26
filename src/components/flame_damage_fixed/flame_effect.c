/* Flame Damage Fixed, fixes 1 and 2: the shared flame effect's data (the Lua's Fix.resolve_effect, check_effect and
 * apply_effect). Systems 0 and 3 spawn again (their spawn-rate step keys rescaled from the 1e10 s lifetime to the
 * Cremator's 64 s), the four main flame systems start at the Cremator's distances, and systems 0 and 3 are not drawn
 * (visualizer count 1 -> 0). 18 words in the loaded particles resource, which is private read-write memory. */
#include <string.h>
#include "flame_damage_fixed.h"

#define RESOURCE_MANAGER 0x3F8u
#define PARTICLES_LO 0x526FAD64u      /* resource type "particles" */
#define PARTICLES_HI 0xA8193123u
#define NOT_LOADED 0xFAFEF0F1u
#define MAX_BUCKETS 1048576u
#define TYPE_ENTRY 0xD0u              /* the type table's entries: next at +0xC8 */
#define TYPE_NEXT 0xC8u
#define NAME_ENTRY 24u                /* a type's name entries: value +8, next +0x10 */
#define NAME_NEXT 0x10u
#define RECORD 160u                   /* a resource record: data +0, size +0x18 */
#define SYSTEM_SIZE_AT 0x100u         /* a system's size word, from its offset */
#define PATCH_FIRST 252u              /* the patched words lie in [PATCH_FIRST, PATCH_END) */
#define PATCH_END 10316u

const uint32_t fdf_effect_header[24] = {
    0x00000073u, 0x501502F9u, 0x501502F9u, 0x5368D4A5u, 0x00000023u, 0x00000000u, 0x0000000Cu, 0x00000000u,
    0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u,
    0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000014u, 0x0000000Bu, 0x00000044u, 0x00000010u,
};
const uint32_t fdf_effect_systems[12][2] = {
    {80, 3600}, {3680, 2572}, {6252, 3084}, {9336, 2544}, {11880, 1256}, {13136, 3396},
    {16532, 2272}, {18804, 2472}, {21276, 3356}, {24632, 2628}, {27260, 2008}, {29268, 1628},
};
/* The Lua's Fix.PATCHES (scripts/patch_table.py: spawn step keys * 64 s / 1e10 s; emitters: the Cremator's values;
 * hide: the restored systems 0 and 3 are not drawn). {offset, shipped, fixed} */
const FdfPatch fdf_patches[FDF_PATCH_COUNT] = {
    {252, 0x41700000u, 0x40800000u},   /* sys0+0xac emitters 15 -> 4 */
    {264, 0x40A8BD3Cu, 0x4060FC50u},   /* sys0+0xb8 emitters 5.2731 -> 3.5154 */
    {328, 0x00000001u, 0x00000000u},   /* sys0+0xf8 hide 1 -> 0 */
    {1212, 0x3C185F07u, 0x2E82E2C8u},  /* sys0+0x46c spawn 0.0093 -> 5.952e-11 */
    {1216, 0x3C185F07u, 0x2E82E2C8u},  /* sys0+0x470 spawn 0.0093 -> 5.952e-11 */
    {1292, 0x3C185F07u, 0x2E82E2C8u},  /* sys0+0x4bc spawn 0.0093 -> 5.952e-11 */
    {1296, 0x3C185F07u, 0x2E82E2C8u},  /* sys0+0x4c0 spawn 0.0093 -> 5.952e-11 */
    {3852, 0x41400000u, 0x40200000u},  /* sys1+0xac emitters 12 -> 2.5 */
    {3864, 0x418F23A3u, 0x41380903u},  /* sys1+0xb8 emitters 17.8924 -> 11.5022 */
    {6424, 0x40E00000u, 0x3F800000u},  /* sys2+0xac emitters 7 -> 1 */
    {6436, 0x4160EECCu, 0x4106F5A3u},  /* sys2+0xb8 emitters 14.0583 -> 8.43497 */
    {9508, 0x40E00000u, 0x40400000u},  /* sys3+0xac emitters 7 -> 3 */
    {9520, 0x40A70F28u, 0x4042E704u},  /* sys3+0xb8 emitters 5.2206 -> 3.04535 */
    {9584, 0x00000001u, 0x00000000u},  /* sys3+0xf8 hide 1 -> 0 */
    {10228, 0x3BCB295Fu, 0x2E2E83B6u}, /* sys3+0x37c spawn 0.0062 -> 3.968e-11 */
    {10232, 0x3B4B295Fu, 0x2DAE83B6u}, /* sys3+0x380 spawn 0.0031 -> 1.984e-11 */
    {10308, 0x3BCB295Fu, 0x2E2E83B6u}, /* sys3+0x3cc spawn 0.0062 -> 3.968e-11 */
    {10312, 0x3B4B295Fu, 0x2DAE83B6u}, /* sys3+0x3d0 spawn 0.0031 -> 1.984e-11 */
};

static uint8_t g_effect[FDF_EFFECT_SIZE]; /* the effect as read at the check (static: 30 KB) */

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uintptr_t Ptr(const uint8_t* at)
{
    uint64_t v;
    memcpy(&v, at, 8);
    return vpm_plausible((uintptr_t)v) ? (uintptr_t)v : 0;
}
static int Fail(FdfReason* why, FdfReason reason) { *why = reason; return 0; }

/* One of the engine's chained hash tables: entries of `stride` bytes, the next index at `next`, bucket hi % buckets. */
typedef struct Chain { uintptr_t entries; uint32_t stride, next, buckets, lo, hi, limit; } Chain;

/* The entry holding (lo, hi), with its bytes in entry, or 0. One read per entry visited (the Lua: 2 to 4). */
static uintptr_t Walk(const Chain* c, uint8_t* entry)
{
    if (!vpm_plausible(c->entries) || c->buckets == 0 || c->buckets > MAX_BUCKETS) return 0;
    uintptr_t base = c->entries + (uintptr_t)(c->hi % c->buckets) * c->stride;
    if (!vpm_read(base, entry, c->stride) || U32(entry + c->next) == FDF_EMPTY_BUCKET) return 0;
    for (uint32_t step = 0; step < c->limit; step++)
    {
        if (U32(entry) == c->lo && U32(entry + 4) == c->hi) return base;
        uint32_t index = U32(entry + c->next);
        if (index == FDF_CHAIN_END || index >= c->limit || step + 1 == c->limit) return 0;
        base = c->entries + (uintptr_t)index * c->stride;
        if (!vpm_read(base, entry, c->stride)) return 0;
    }
    return 0;
}

/* The particles type's entry in the resource manager's type table (its bytes in type), or 0 with *why. */
static int ParticlesType(uint8_t* type, FdfReason* why)
{
    uintptr_t root = (uintptr_t)vpm_exe_u64(FDF_RESOURCE_ROOT);
    uintptr_t manager = vpm_plausible(root) ? vpm_ptr(root + RESOURCE_MANAGER) : 0;
    if (!vpm_plausible(manager)) return Fail(why, FDF_RESOURCE_MANAGER);
    uint8_t table[0x18]; /* +0x2F0 entries, +0x300 count, +0x304 buckets */
    if (!vpm_read(manager + 0x2F0, table, sizeof table) || U32(table + 0x10) > 4096u) return Fail(why, FDF_TYPE_TABLE);
    uint32_t buckets = U32(table + 0x14);
    Chain types = {Ptr(table), TYPE_ENTRY, TYPE_NEXT, buckets, PARTICLES_LO, PARTICLES_HI, buckets};
    if (Walk(&types, type) == 0) return Fail(why, FDF_PARTICLES_TYPE);
    return 1;
}

int fdf_resolve_effect(uintptr_t* data, FdfReason* why)
{
    uint8_t type[TYPE_ENTRY], name[NAME_ENTRY], record[0x20];
    if (!ParticlesType(type, why)) return 0;
    uint32_t slots = U32(type + 0x20);
    if (slots > MAX_BUCKETS) return Fail(why, FDF_NAME_TABLE);
    Chain names = {Ptr(type + 0x28), NAME_ENTRY, NAME_NEXT, U32(type + 0x3C), FDF_EFFECT_LO, FDF_EFFECT_HI, slots};
    if (Walk(&names, name) == 0) return Fail(why, FDF_EFFECT_NOT_LOADED);
    uint32_t value = U32(name + 8);
    if (value == NOT_LOADED || value > MAX_BUCKETS) return Fail(why, FDF_EFFECT_PENDING);
    uintptr_t records = Ptr(type + 0x10);
    if (records == 0 || !vpm_read(records + (uintptr_t)value * RECORD, record, sizeof record)) return Fail(why, FDF_EFFECT_RECORD);
    *data = Ptr(record);
    if (*data == 0 || U32(record + 0x18) != FDF_EFFECT_SIZE) return Fail(why, FDF_EFFECT_RECORD);
    return 1;
}

/* Reads the effect and checks it against the shipped header and layout, and every patched word against its shipped or
 * fixed value: 1 with *pending (the words still to fix), or 0 with *why. One read (the Lua: 54 word reads). */
static int CheckEffect(uintptr_t data, int* pending, FdfReason* why)
{
    if (!vpm_read(data, g_effect, sizeof g_effect)) return Fail(why, FDF_HEADER_CHANGED);
    for (int i = 0; i < 24; i++)
        if (U32(g_effect + 4 * i) != fdf_effect_header[i]) return Fail(why, FDF_HEADER_CHANGED);
    for (int i = 0; i < 12; i++)
        if (U32(g_effect + fdf_effect_systems[i][0] + SYSTEM_SIZE_AT) != fdf_effect_systems[i][1]) return Fail(why, FDF_LAYOUT_CHANGED);
    *pending = 0;
    for (int i = 0; i < FDF_PATCH_COUNT; i++)
    {
        uint32_t word = U32(g_effect + fdf_patches[i].offset);
        if (word != fdf_patches[i].shipped && word != fdf_patches[i].fixed) return Fail(why, FDF_REASON_AT(FDF_UNKNOWN_VALUE, i));
        if (word != fdf_patches[i].fixed) (*pending)++;
    }
    return 1;
}

/* Reads the patched words back (one read of their span): 1, or 0 with the first that does not hold. */
static int VerifyEffect(uintptr_t data, FdfReason* why)
{
    if (!vpm_read(data + PATCH_FIRST, g_effect + PATCH_FIRST, PATCH_END - PATCH_FIRST)) return Fail(why, FDF_REASON_AT(FDF_VERIFY_FAILED, 0));
    for (int i = 0; i < FDF_PATCH_COUNT; i++)
        if (U32(g_effect + fdf_patches[i].offset) != fdf_patches[i].fixed) return Fail(why, FDF_REASON_AT(FDF_VERIFY_FAILED, i));
    return 1;
}

int fdf_apply_effect(uintptr_t data, int* writes, FdfReason* why)
{
    int pending = 0;
    *writes = 0;
    if (!CheckEffect(data, &pending, why)) return 0;
    if (pending == 0) return 1;
    FDF_COUNT(writable);
    if (!vpm_writable(data, FDF_EFFECT_SIZE)) return Fail(why, FDF_EFFECT_WRITABLE);
    for (int i = 0; i < FDF_PATCH_COUNT; i++)
    {
        if (U32(g_effect + fdf_patches[i].offset) == fdf_patches[i].fixed) continue;
        fdf_store(data + fdf_patches[i].offset, fdf_patches[i].fixed);
        (*writes)++;
    }
    return VerifyEffect(data, why);
}
