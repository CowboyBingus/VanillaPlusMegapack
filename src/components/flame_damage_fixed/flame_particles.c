/* Flame Damage Fixed, fix 3's flame side (the Lua's Fix.flame_slot, find_instance, retarget_instance and
 * restore_flames): the shared flame's instances in the particle manager and their particle systems' query filter info
 * (PS + 5764). Particle queries run the particle filter's own checks, then the world's group filter (exe 0xE66F60) with
 * the particle system's filter info, copied per query: a flame system in the weapon's group skips the weapon's bodies. */
#include <string.h>
#include "flame_damage_fixed.h"

#define PARTICLE_MANAGER 0x230888u  /* in the object at game.dll 0x346BFA0 */
#define MANAGER_FIELDS 0x1B8u       /* +0x1B8 entries, +0x1C8 count, +0x1CC buckets, +0x228 mask, +0x278 lists */
#define MANAGER_SIZE 0xC8u
#define ENTRY 24u                   /* an effect entry: lo, hi, value +8, next +0x10 */
#define INSTANCE 136u               /* an instance record: simulation +8, id +0x10 */
#define INSTANCE_SIM 8u
#define INSTANCE_ID 0x10u
#define SYSTEM 80u                  /* a simulation's system list: handle at +52 */
#define SYSTEM_HANDLE 52u
#define PS_TABLE (32u + 1144u)      /* a world wrapper's particle-system table; its array at +8 (16-byte slots) */

static uint8_t g_records[FDF_MAX_INSTANCES * INSTANCE]; /* the slot's instance records (static: 8.5 KB) */
static uint8_t g_systems[FDF_MAX_SYSTEMS * SYSTEM];     /* a simulation's system list (2.5 KB) */

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uintptr_t Ptr(const uint8_t* at)
{
    uint64_t v;
    memcpy(&v, at, 8);
    return vpm_plausible((uintptr_t)v) ? (uintptr_t)v : 0;
}

/* The flame's value in the manager's effect table, or 0 (1 with *value). One read per entry visited. */
static int EffectValue(uintptr_t entries, uint32_t count, uint32_t buckets, uint32_t* value)
{
    uint8_t entry[ENTRY];
    uint32_t index = FDF_EFFECT_HI % buckets;
    if (!vpm_read(entries + (uintptr_t)ENTRY * index, entry, sizeof entry) || U32(entry + 0x10) == FDF_EMPTY_BUCKET) return 0;
    for (uint32_t step = 0; step <= count; step++)
    {
        if (U32(entry) == FDF_EFFECT_LO && U32(entry + 4) == FDF_EFFECT_HI) { *value = U32(entry + 8); return 1; }
        index = U32(entry + 0x10);
        if (index == FDF_CHAIN_END || step == count) return 0;
        if (!vpm_read(entries + (uintptr_t)ENTRY * index, entry, sizeof entry)) return 0;
    }
    return 0;
}

/* The entry moves when the effect is unregistered, so it is looked up again at every burst start. */
uintptr_t fdf_flame_slot(void)
{
    uintptr_t world = (uintptr_t)vpm_game_u64(FDF_WORLD_PTR);
    uintptr_t manager = vpm_plausible(world) ? vpm_ptr(world + PARTICLE_MANAGER) : 0;
    uint8_t m[MANAGER_SIZE];
    if (!vpm_plausible(manager) || !vpm_read(manager + MANAGER_FIELDS, m, sizeof m)) return 0;
    uintptr_t entries = Ptr(m), lists = Ptr(m + 0x278 - MANAGER_FIELDS);
    uint32_t count = U32(m + 0x10), buckets = U32(m + 0x14), mask = U32(m + 0x228 - MANAGER_FIELDS), value = 0;
    if (entries == 0 || count == 0 || count > 65536u || buckets == 0 || buckets > 1048576u) return 0;
    if (!EffectValue(entries, count, buckets, &value) || lists == 0) return 0;
    return lists + (uintptr_t)ENTRY * (value & mask);
}

/* The slot's instance records into g_records: their count, or -1 (unreadable, or more than FDF_MAX_INSTANCES). */
static int ReadInstances(uintptr_t slot)
{
    uint8_t head[16]; /* count, records */
    if (!vpm_read(slot, head, sizeof head)) return -1;
    uint32_t count = U32(head);
    uintptr_t records = Ptr(head + 8);
    if (records == 0 || count > FDF_MAX_INSTANCES) return -1;
    if (count > 0 && !vpm_read(records, g_records, (size_t)count * INSTANCE)) return -1;
    return (int)count;
}

/* lint: per-frame (firing frames, until the burst's instance is found) */
int fdf_find_instance(uintptr_t slot, uint32_t id, uintptr_t* sim)
{
    int count = ReadInstances(slot);
    for (int i = 0; i < count; i++)
    {
        const uint8_t* record = g_records + (size_t)i * INSTANCE;
        if (U32(record + INSTANCE_ID) != id) continue;
        *sim = Ptr(record + INSTANCE_SIM);
        return 1;
    }
    return 0;
}

/* The world's particle-system array, looked up once per instance. */
typedef struct SystemCache { int valid; uint32_t world; uintptr_t array; } SystemCache;

/* The particle system a handle names (world: bits 30-31, generation: 16-23, index: 0-15) while the world's array
 * still holds that generation at that index, else 0. */
static uintptr_t SystemOf(uint32_t handle, SystemCache* cache)
{
    uint32_t index = handle & 0xFFFFu, generation = (handle >> 16) & 0xFFu, w = handle >> 30;
    if (!cache->valid || cache->world != w)
    {
        uintptr_t wrapper = (uintptr_t)vpm_exe_u64(FDF_WORLDS + FDF_WORLD_STRIDE * w);
        uintptr_t table = vpm_plausible(wrapper) ? vpm_ptr(wrapper + PS_TABLE) : 0;
        uintptr_t array = vpm_plausible(table) ? vpm_ptr(table + 8) : 0;
        cache->valid = 1;
        cache->world = w;
        cache->array = vpm_plausible(array) ? array : 0;
    }
    uint8_t slot[16]; /* system pointer, tag */
    if (cache->array == 0 || !vpm_read(cache->array + 16u * index, slot, sizeof slot)) return 0;
    uintptr_t ps = Ptr(slot);
    uint32_t tag = U32(slot + 8);
    return ps != 0 && (tag & 0xFFFFu) == index && (tag >> 24) == generation ? ps : 0;
}

int fdf_retarget(uintptr_t sim, uintptr_t data, FdfRegion* region, uint32_t value, uint32_t from, FdfReason* why)
{
    uint8_t head[24]; /* +32 effect data, +40 system count, +48 system list */
    if (!vpm_read(sim + 32, head, sizeof head) || Ptr(head) != data) return 0; /* another effect's instance */
    uint32_t systems = U32(head + 8);
    uintptr_t list = Ptr(head + 16);
    if (list == 0 || systems > FDF_MAX_SYSTEMS) return 0;
    if (systems > 0 && !vpm_read(list, g_systems, (size_t)systems * SYSTEM)) return 0;
    SystemCache cache = {0, 0, 0};
    int moved = 0;
    for (uint32_t s = 0; s < systems; s++)
    {
        uint32_t handle = U32(g_systems + s * SYSTEM + SYSTEM_HANDLE), filter = 0;
        uintptr_t ps = handle != 0 ? SystemOf(handle, &cache) : 0;
        if (ps == 0 || !vpm_read_u32(ps + FDF_PS_FILTER, &filter) || filter != from) continue;
        if (!fdf_region_writable(region, ps + FDF_PS_FILTER)) { *why = FDF_PARTICLE_WRITABLE; return -1; }
        fdf_store(ps + FDF_PS_FILTER, value);
        moved++;
    }
    return moved;
}

int fdf_restore_flames(uintptr_t slot, uintptr_t data, FdfRegion* region, uint32_t value, uint32_t from, FdfReason* why)
{
    uintptr_t sims[FDF_MAX_INSTANCES];
    int count = ReadInstances(slot), changed = 0;
    for (int i = 0; i < count; i++) sims[i] = Ptr(g_records + (size_t)i * INSTANCE + INSTANCE_SIM);
    for (int i = 0; i < count; i++)
    {
        if (sims[i] == 0) continue;
        int moved = fdf_retarget(sims[i], data, region, value, from, why);
        if (moved < 0) return -1;
        changed += moved;
    }
    return changed;
}
