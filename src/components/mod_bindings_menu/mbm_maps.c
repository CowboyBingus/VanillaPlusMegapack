/* Mod Bindings Menu: the input owner's two binding maps (fixed 256-record hash maps: the live bindings at +686800 and
 * the shipped defaults at +686968), the native "down" answer and the mission check. The Lua's index_map, map_bucket,
 * live_header, is_down and in_mission (src/mod_bindings_menu.lua). */
#include <string.h>
#include "mbm.h"

#define MBM_SCAN_RECORDS 32u

typedef struct MbmMap
{
    uint32_t offset;            /* MBM_BINDING_MAP or MBM_DEFAULTS_MAP */
    uintptr_t buckets;          /* its records as last indexed */
    uintptr_t cache[MBM_ACTIONS]; /* each dormant action's record, 0 unknown */
    uintptr_t checked;          /* the records the page check below was made for */
    int writable;
} MbmMap;

static struct
{
    MbmMap maps[2];
    int unwritable_logged;
} s_maps;

static uint8_t g_mbmScan[MBM_SCAN_RECORDS * MBM_RECORD_SIZE]; /* 32 records per read (static: 10 KB) */

void mbm_maps_reset(void)
{
    memset(&s_maps, 0, sizeof s_maps);
    s_maps.maps[0].offset = MBM_BINDING_MAP;
    s_maps.maps[1].offset = MBM_DEFAULTS_MAP;
}

static MbmMap* MbmMapOf(uint32_t offset) { return offset == MBM_BINDING_MAP ? &s_maps.maps[0] : &s_maps.maps[1]; }

/* Finds every dormant action's record in a map, 32 records per read: 1 + 8 reads. 0 when the map cannot be read. */
static int MbmIndexMap(MbmMap* map)
{
    uintptr_t owner = mbm_input_owner();
    uint8_t header[12];
    if (owner == 0 || !vpm_read(owner + map->offset, header, sizeof header)) return 0;
    uint64_t buckets;
    uint32_t count;
    memcpy(&buckets, header, 8);
    memcpy(&count, header + 8, 4);
    if (!mbm_pointer(buckets) || count != MBM_MAP_RECORDS) return 0;
    memset(map->cache, 0, sizeof map->cache);
    map->buckets = (uintptr_t)buckets;
    for (uint32_t first = 0; first < MBM_MAP_RECORDS; first += MBM_SCAN_RECORDS)
    {
        uintptr_t address = map->buckets + (uintptr_t)first * MBM_RECORD_SIZE;
        if (!vpm_read(address, g_mbmScan, sizeof g_mbmScan)) return 0;
        for (uint32_t i = 0; i < MBM_SCAN_RECORDS; i++)
        {
            uint32_t code;
            memcpy(&code, g_mbmScan + i * MBM_RECORD_SIZE, 4);
            int index = mbm_code_index(code);
            if (index >= 0) map->cache[index] = address + (uintptr_t)i * MBM_RECORD_SIZE;
        }
    }
    return 1;
}

uintptr_t mbm_map_cached(uint32_t offset, uint32_t code)
{
    int index = mbm_code_index(code);
    return index >= 0 ? MbmMapOf(offset)->cache[index] : 0;
}

void mbm_map_forget(uint32_t offset, uint32_t code)
{
    int index = mbm_code_index(code);
    if (index >= 0) MbmMapOf(offset)->cache[index] = 0;
}

/* The record of code in a map: the cached one while it still holds the code (1 read), else the map indexed again. */
uintptr_t mbm_map_bucket(uint32_t offset, uint32_t code)
{
    int index = mbm_code_index(code);
    if (mbm.base == 0 || index < 0) return 0;
    MbmMap* map = MbmMapOf(offset);
    uint32_t now = 0;
    if (map->cache[index] != 0 && vpm_read_u32(map->cache[index], &now) && now == code) return map->cache[index];
    if (!MbmIndexMap(map)) return 0;
    return map->cache[index];
}

/* Whether the map holding bucket is committed read-write memory: checked once per records array (VirtualQuery),
 * before the first store into it. */
int mbm_maps_writable(uintptr_t bucket)
{
    for (int m = 0; m < 2; m++)
    {
        MbmMap* map = &s_maps.maps[m];
        if (map->buckets == 0 || bucket < map->buckets || bucket >= map->buckets + MBM_MAP_RECORDS * MBM_RECORD_SIZE) continue;
        if (map->checked != map->buckets)
        {
            map->checked = map->buckets;
            map->writable = vpm_writable(map->buckets, MBM_MAP_RECORDS * MBM_RECORD_SIZE);
        }
        if (!map->writable && !s_maps.unwritable_logged)
        {
            s_maps.unwritable_logged = 1;
            vpm_log(mbm.self, "A binding map is not writable; its records are left as they are.");
        }
        return map->writable;
    }
    return 0;
}

/* A native binding's live record and its mapping count, from one 8-byte read of the record's {code, count} header.
 * lint: per-frame */
uintptr_t mbm_live_header(MbmRecord* record, uint32_t* count)
{
    uintptr_t bucket = mbm_map_cached(MBM_BINDING_MAP, record->code);
    uint32_t header[2];
    if (bucket == 0 || !vpm_read(bucket, header, sizeof header) || header[0] != record->code)
    {
        mbm_map_forget(MBM_BINDING_MAP, record->code);
        bucket = mbm_map_bucket(MBM_BINDING_MAP, record->code);
        if (bucket == 0 || !vpm_read(bucket, header, sizeof header)) return 0;
    }
    *count = header[1];
    return bucket;
}

/* The game evaluates every action once per frame; byte 0 of its state is set while any of its mappings satisfies its
 * own trigger. A config re-parse or a Revert may restore inherited defaults: the sweep cleans them first, and the
 * frame reads as up. 2 reads. lint: per-frame */
int mbm_native_down(MbmRecord* record)
{
    if (!mbm.ready) return -1;
    if (mbm.suppressed) return 0;
    uint32_t count = 0;
    if (mbm_live_header(record, &count) == 0) return -1;
    if (count != record->swept_count && mbm_active_screen() == 0)
    {
        mbm_sweep();
        return 0;
    }
    uintptr_t owner = mbm_input_owner();
    uint8_t state = 0;
    uintptr_t at = owner + MBM_ACTION_STATE + MBM_ACTION_STRIDE * (MBM_GROUP_ACTIONS * record->group + record->action);
    if (owner == 0 || !vpm_read_u8(at, &state)) return -1;
    return state != 0;
}

/* Whether a mission runs (the mission-mode record: +8 set, mode +0x40 in 1 .. 7): a plain load and 1 read. An
 * unreadable record counts as a mission, so the MORE MODS panel never draws when the answer is unknown. */
int mbm_in_mission(void)
{
    uint64_t record = vpm_game_u64(MBM_MISSION_MODE_RVA);
    uint32_t words[17];
    if (record == 0) return 0;
    if (!mbm_pointer(record) || !vpm_read((uintptr_t)record, words, sizeof words)) return 1;
    return words[2] != 0 && words[16] >= 1 && words[16] <= 7;
}
