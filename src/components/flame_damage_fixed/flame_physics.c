/* Flame Damage Fixed, fix 3's physics side (the Lua's Fix.check_filter, family, scan_begin, scan_step, verify, mark,
 * unmark and group_free): the world's collision filter, a weapon's unit family, the scan of every physics world's body
 * records for the family's flame-hittable bodies, and the group bits of those bodies.
 *
 * The world's hknpGroupCollisionFilter (query check exe 0xCE6030) decides by the layer matrix unless both sides are in the
 * same non-zero system group; then only the subsystems decide, and two members whose subsystem and don't-collide are both
 * 0 never collide. The engine treats every allocator-claimed group as a ragdoll group, so the mod never writes the
 * allocator: a group from the top of the pool (2047 down to 2040) counts as a weapon's only while the allocator still
 * marks it free, and the weapon's latest body scan found no other body in it. */
#include <string.h>
#include <windows.h>
#include "flame_damage_fixed.h"

#define FILTER_MATRIX 40u          /* the filter's layer matrix: 128 rows of 16 bytes */
#define UNIT_OBJECTS 0x88u         /* unit registry: the unit objects by handle slot */
#define UNIT_HANDLE 0x8u
#define UNIT_PARENT 0x1D0u
#define UNIT_CHILD 0x1D8u
#define UNIT_SIBLING 0x1E0u
#define UNIT_RESOURCE 0x358u
#define UNIT_READ 0x360u           /* a unit object up to its resource */
#define AVATAR_LO 0x294DFA97u      /* avatar_helldiver: a seated pilot stays out of the family */
#define AVATAR_HI 0x4D1C334Du
#define WORLD_HEAD 0x58u           /* a world: vtable +0, body array +0x38, its size +0x40, index bound +0x50 */
#define BODY 160u                  /* a body record */
#define W_FLAGS 17                 /* its u32 words: flags (& 3: in the world), filter info, id (low 24 bits: index), */
#define W_FILTER 27                /* actor handle, unit handle */
#define W_ID 28
#define W_ACTOR 36
#define W_UNIT 37
#define BODY_WORDS 40
#define BLOCK_BODIES 409u          /* bodies per read (65440 B) */
#define SPAN_GAP 64u               /* kept bodies closer than this many records share one read */
#define TOP_FILTER 0xFF000000u     /* a filter info at or above this is in one of groups 2040-2047 */
#define GROUP_CAPACITY 2048u

#ifdef VPM_TEST
FdfTestCounts fdf_test_counts;
#endif

/* Layer 11's row in the live matrix (the flame's collision filter 0x12d0abf1): layers 0 2 14 17 19 20 22 27 31 39 48 54
 * 55 59 60 63 66 77 83 86 94 100 101. */
static const uint32_t kFlameWords[4] = {0x885A4005u, 0x98C10080u, 0x40482004u, 0x00000030u};

static uint32_t g_block[BLOCK_BODIES * BODY_WORDS]; /* one block or span of body records (static: 64 KB) */

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uintptr_t Ptr(const uint8_t* at)
{
    uint64_t v;
    memcpy(&v, at, 8);
    return vpm_plausible((uintptr_t)v) ? (uintptr_t)v : 0;
}
static uintptr_t HeapPtr(uintptr_t address)
{
    uintptr_t v = vpm_ptr(address);
    return vpm_plausible(v) ? v : 0;
}
static uintptr_t ExePtr(uint32_t rva)
{
    uintptr_t v = (uintptr_t)vpm_exe_u64(rva);
    return vpm_plausible(v) ? v : 0;
}

int fdf_hittable(uint32_t layer) { return layer < 128u && ((kFlameWords[layer >> 5] >> (layer & 31u)) & 1u) != 0; }

int fdf_in_family(const FdfFamily* family, uint32_t unit)
{
    for (int i = 0; i < family->n; i++)
        if (family->units[i] == unit) return 1;
    return 0;
}

/* The Lua's api.writable_region: the committed, private, read-write region holding address (one VirtualQuery). */
static int QueryRegion(uintptr_t address, FdfRegion* region)
{
    MEMORY_BASIC_INFORMATION info;
    FDF_COUNT(queries);
    if (VirtualQuery((const void*)address, &info, sizeof info) != sizeof info) return 0; /* lint-ok: C4 only on a frame that stores, before its first store into a new region */
    if (info.State != MEM_COMMIT || info.Type != MEM_PRIVATE || info.Protect != PAGE_READWRITE) return 0;
    region->low = (uintptr_t)info.BaseAddress;
    region->high = region->low + info.RegionSize;
    return 1;
}

int fdf_region_writable(FdfRegion* region, uintptr_t target)
{
    if (region->low != 0 && target >= region->low && target + 4 <= region->high) return 1;
    return QueryRegion(target, region);
}

void fdf_store(uintptr_t target, uint32_t value)
{
    FDF_COUNT(stores);
    memcpy((void*)target, &value, 4);
}

/* ---- the collision filter and the family ------------------------------------------------------------------------ */

int fdf_check_filter(uintptr_t* filter, FdfReason* why)
{
    uint8_t head[FILTER_MATRIX + 16u * (FDF_FLAME_LAYER + 1u)]; /* the vtable and the matrix up to layer 11's row */
    uintptr_t at = ExePtr(FDF_FILTER_PTR);
    if (at == 0) { *why = FDF_FILTER_UNAVAILABLE; return 0; }
    uint64_t vtable = 0;
    if (vpm_read(at, head, sizeof head)) memcpy(&vtable, head, 8);
    if (vtable != vpm_exe() + FDF_FILTER_VTABLE) { *why = FDF_FILTER_TYPE; return 0; }
    for (uint32_t i = 0; i < 4; i++)
    {
        if (U32(head + FILTER_MATRIX + 16u * FDF_FLAME_LAYER + 4u * i) != kFlameWords[i]) { *why = FDF_FLAME_ROW; return 0; }
    }
    *filter = at;
    return 1;
}

/* Visits one unit of the walk: adds it to the family and pushes its children, unless it is an avatar. 0, or a reason. */
static FdfReason Visit(uintptr_t node, FdfFamily* family, uintptr_t* stack, int* depth)
{
    uint8_t unit[UNIT_READ];
    if (!vpm_read(node, unit, sizeof unit)) return FDF_UNIT_UNREADABLE;
    if (U32(unit + UNIT_RESOURCE) == AVATAR_LO && U32(unit + UNIT_RESOURCE + 4) == AVATAR_HI) return FDF_OK;
    if (family->n >= FDF_MAX_FAMILY) return FDF_FAMILY_TOO_LARGE;
    family->units[family->n++] = U32(unit + UNIT_HANDLE);
    for (uintptr_t child = Ptr(unit + UNIT_CHILD); child != 0; child = HeapPtr(child + UNIT_SIBLING))
    {
        if (*depth >= FDF_MAX_FAMILY) return FDF_FAMILY_TOO_LARGE;
        stack[(*depth)++] = child;
    }
    return FDF_OK;
}

int fdf_family(uint32_t handle, FdfFamily* family, FdfReason* why)
{
    uintptr_t registry = ExePtr(FDF_UNITS);
    uintptr_t objects = registry != 0 ? HeapPtr(registry + UNIT_OBJECTS) : 0;
    if (objects == 0) { *why = FDF_UNIT_REGISTRY; return -1; }
    uintptr_t unit = HeapPtr(objects + 8u * (handle % 4194304u));
    uint32_t own = 0;
    if (unit == 0 || !vpm_read_u32(unit + UNIT_HANDLE, &own) || own != handle) { *why = FDF_WEAPON_UNIT; return -1; }
    family->n = 0;
    uintptr_t stack[FDF_MAX_FAMILY];
    uintptr_t parent = HeapPtr(unit + UNIT_PARENT);
    int depth = 1;
    stack[0] = parent != 0 ? parent : unit;
    while (depth > 0)
    {
        FdfReason reason = Visit(stack[--depth], family, stack, &depth);
        if (reason != FDF_OK) { *why = reason; return -1; }
    }
    return family->n;
}

/* ---- the body scan ---------------------------------------------------------------------------------------------- */

int fdf_scan_begin(FdfJob* job, FdfReason* why)
{
    job->worlds = job->w = job->n = job->spans = 0;
    job->i = 0;
    memset(job->foreign, 0, sizeof job->foreign);
    for (uint32_t w = 0; w < FDF_MAX_WORLDS; w++)
    {
        uint8_t head[WORLD_HEAD];
        uint64_t vtable;
        uintptr_t world = ExePtr(FDF_WORLDS + FDF_WORLD_STRIDE * w);
        if (world == 0 || !vpm_read(world, head, sizeof head)) continue;
        memcpy(&vtable, head, 8);
        uintptr_t bodies = Ptr(head + 0x38);
        uint32_t size = U32(head + 0x40), limit = U32(head + 0x50);
        if (vtable != vpm_exe() + FDF_WORLD_VTABLE || bodies == 0 || limit > size || size > 1048576u) continue;
        job->bases[job->worlds] = bodies;
        job->limits[job->worlds] = limit;
        job->worlds++;
    }
    if (job->worlds == 0) { *why = FDF_NO_WORLD; return 0; }
    return 1;
}

/* A live body of interest: keeps one of the family's flame-hittable bodies whose subsystem and don't-collide are 0, in
 * no group or in the weapon's own group (kept as marked); notes a group from 2040 up that any other body carries,
 * unless it is another of this mod's weapons' own. lint: per-frame */
static FdfReason ScanBody(FdfJob* job, const FdfScanFor* scan, const uint32_t* body, uintptr_t base, uint32_t index)
{
    uint32_t filter = body[W_FILTER], unit = body[W_UNIT];
    uint32_t group = filter >> FDF_GROUP_SHIFT, low = filter & 0x1FFFFFu;
    int mine = fdf_in_family(scan->family, unit);
    if (mine && low < 128u && fdf_hittable(low) && (group == 0 || group == scan->group))
    {
        if (job->n >= FDF_MAX_BODIES) return FDF_TOO_MANY_BODIES;
        int n = job->n++;
        job->base[n] = base;
        job->index[n] = index;
        job->layer[n] = low;
        job->actor[n] = body[W_ACTOR];
        job->unit[n] = unit;
        job->marked[n] = group != 0;
    }
    else if (group >= FDF_GROUP_LOW && !(mine && group == scan->group) && !scan->own(group, unit))
    {
        job->foreign[group - FDF_GROUP_LOW] = 1;
    }
    return FDF_OK;
}

/* One block of body records: the filter word first, the unit only for a hittable layer, the rest for those bodies.
 * lint: per-frame */
static FdfReason ScanBlock(FdfJob* job, const FdfScanFor* scan, uintptr_t base, uint32_t first, uint32_t count)
{
    for (uint32_t k = 0; k < count; k++)
    {
        const uint32_t* body = g_block + k * BODY_WORDS;
        uint32_t filter = body[W_FILTER];
        if (filter < TOP_FILTER && !(fdf_hittable(filter) && fdf_in_family(scan->family, body[W_UNIT]))) continue;
        if ((body[W_FLAGS] & 3u) == 0 || (body[W_ID] & 0xFFFFFFu) != first + k) continue;
        FdfReason why = ScanBody(job, scan, body, base, first + k);
        if (why != FDF_OK) return why;
    }
    return FDF_OK;
}

/* Groups the kept bodies (in scan order) into spans that one read covers: the same body array, at most BLOCK_BODIES
 * records, gaps under SPAN_GAP. */
static void BuildSpans(FdfJob* job)
{
    int s = 0;
    for (int k = 0; k < job->n; k++)
    {
        int split = s == 0 || job->span_base[s - 1] != job->base[k] ||
            (int64_t)job->index[k] - (int64_t)job->index[k - 1] > (int64_t)SPAN_GAP ||
            (int64_t)job->index[k] - (int64_t)job->index[job->span_k[s - 1]] + 1 > (int64_t)BLOCK_BODIES;
        if (!split) continue;
        job->span_k[s] = k;
        job->span_base[s] = job->base[k];
        s++;
    }
    job->span_k[s] = job->n;
    job->spans = s;
}

/* lint: per-frame */
int fdf_scan_step(FdfJob* job, const FdfScanFor* scan, int blocks, FdfReason* why)
{
    while (blocks > 0 && job->w < job->worlds)
    {
        uintptr_t base = job->bases[job->w];
        uint32_t limit = job->limits[job->w], first = job->i;
        if (first >= limit)
        {
            job->w++;
            job->i = 0;
            continue;
        }
        uint32_t count = limit - first < BLOCK_BODIES ? limit - first : BLOCK_BODIES;
        if (!vpm_read(base + (uintptr_t)BODY * first, g_block, (size_t)BODY * count)) { *why = FDF_BODY_ARRAY; return -1; }
        blocks--;
        FdfReason reason = ScanBlock(job, scan, base, first, count);
        if (reason != FDF_OK) { *why = reason; return -1; }
        job->i = first + count;
    }
    if (job->w < job->worlds) return 0;
    BuildSpans(job);
    return 1;
}

/* ---- the kept bodies: classes, grouping, release ---------------------------------------------------------------- */

#define CLASS_OWN 0    /* grouped (g) on the layer the scan saw */
#define CLASS_FREE 1   /* still group-free: to be grouped */
#define CLASS_MOVED 2  /* grouped (g) on another layer (the game switched it, as on destruction) */
#define CLASS_STALE 3  /* no longer the body the scan kept (rebuilt, removed or recycled), or the game regrouped it */

#define WALK_TALLY 0
#define WALK_MARK 1
#define WALK_UNMARK 2

typedef struct Walk { int mode; uint32_t g; FdfRegion region; int count; FdfReason failed; FdfCounts counts; } Walk;

static int Classify(const FdfJob* job, int k, const uint32_t* body, uint32_t g)
{
    if ((body[W_ID] & 0xFFFFFFu) != job->index[k] || body[W_ACTOR] != job->actor[k] || body[W_UNIT] != job->unit[k] ||
        (body[W_FLAGS] & 3u) == 0)
        return CLASS_STALE;
    uint32_t filter = body[W_FILTER], group = filter >> FDF_GROUP_SHIFT, low = filter & 0x1FFFFFu;
    if (g != 0 && group == g && low < 128u) return low == job->layer[k] ? CLASS_OWN : CLASS_MOVED;
    if (fdf_hittable(filter)) return CLASS_FREE;
    return CLASS_STALE;
}

static uintptr_t FilterOf(const FdfJob* job, int k) { return job->base[k] + (uintptr_t)BODY * job->index[k] + 4u * W_FILTER; }

/* One store for the walk, region checked first: 1, or 0 with walk->failed set. */
static int WalkStore(Walk* walk, uintptr_t target, uint32_t value)
{
    if (!fdf_region_writable(&walk->region, target)) { walk->failed = FDF_BODY_WRITABLE; return 0; }
    fdf_store(target, value);
    return 1;
}

static void MarkOne(Walk* walk, FdfJob* job, int k, int cls, const uint32_t* body)
{
    job->marked[k] = 0;
    if (cls == CLASS_FREE && !WalkStore(walk, FilterOf(job, k), body[W_FILTER] + (walk->g << FDF_GROUP_SHIFT))) return;
    if (cls != CLASS_FREE && cls != CLASS_OWN) return;
    job->marked[k] = 1;
    walk->count++;
}

/* Clears g from a body that still belongs to its unit (same index and unit; the actor may have been rebuilt) and still
 * carries g, whatever its layer. */
static void UnmarkOne(Walk* walk, FdfJob* job, int k, const uint32_t* body)
{
    uint32_t filter = body[W_FILTER];
    job->marked[k] = 0;
    if ((body[W_ID] & 0xFFFFFFu) != job->index[k] || body[W_UNIT] != job->unit[k] || (filter >> FDF_GROUP_SHIFT) != walk->g) return;
    if (WalkStore(walk, FilterOf(job, k), filter - (walk->g << FDF_GROUP_SHIFT))) walk->count++;
}

static void VisitBody(Walk* walk, FdfJob* job, int k, const uint32_t* body)
{
    if (walk->failed != FDF_OK) return;
    int cls = Classify(job, k, body, walk->g);
    if (walk->mode == WALK_MARK) MarkOne(walk, job, k, cls, body);
    else if (walk->mode == WALK_UNMARK) UnmarkOne(walk, job, k, body);
    else if (cls == CLASS_OWN) walk->counts.own++;
    else if (cls == CLASS_FREE) walk->counts.free++;
    else if (cls == CLASS_MOVED) walk->counts.moved++;
    else walk->counts.stale++;
}

/* Walks the kept bodies span by span (one read per span): 1, or 0 when a span could not be read. */
static int EachBody(FdfJob* job, Walk* walk)
{
    for (int s = 0; s < job->spans; s++)
    {
        int k0 = job->span_k[s], k1 = job->span_k[s + 1] - 1;
        uint32_t first = job->index[k0];
        if (!vpm_read(job->span_base[s] + (uintptr_t)BODY * first, g_block, (size_t)BODY * (job->index[k1] - first + 1))) return 0;
        for (int k = k0; k <= k1; k++) VisitBody(walk, job, k, g_block + (job->index[k] - first) * BODY_WORDS);
    }
    return 1;
}

int fdf_verify(FdfJob* job, uint32_t g, FdfCounts* counts)
{
    Walk walk;
    memset(&walk, 0, sizeof walk);
    walk.mode = WALK_TALLY;
    walk.g = g;
    if (!EachBody(job, &walk)) return 0;
    *counts = walk.counts;
    return 1;
}

static int Stores(FdfJob* job, int mode, uint32_t g, FdfReason* why)
{
    Walk walk;
    memset(&walk, 0, sizeof walk);
    walk.mode = mode;
    walk.g = g;
    if (!EachBody(job, &walk)) { *why = FDF_BODY_ARRAY; return -1; }
    if (walk.failed != FDF_OK) { *why = walk.failed; return -1; }
    return walk.count;
}

int fdf_mark(FdfJob* job, uint32_t g, FdfReason* why) { return Stores(job, WALK_MARK, g, why); }
int fdf_unmark(FdfJob* job, uint32_t g, FdfReason* why) { return Stores(job, WALK_UNMARK, g, why); }

int fdf_group_free(uint32_t g)
{
    uintptr_t allocator = ExePtr(FDF_GROUPS);
    uint8_t head[16]; /* capacity, summary words, bitmap */
    if (allocator == 0 || !vpm_read(allocator, head, sizeof head)) return 0;
    uint32_t capacity = U32(head), words = U32(head + 4);
    uintptr_t bitmap = Ptr(head + 8);
    if (capacity != GROUP_CAPACITY || words < 1 || words > 64 || bitmap == 0) return 0;
    uint32_t word = 0;
    if (!vpm_read_u32(bitmap + 8u * words + 8u * (g / 64u) + 4u * ((g % 64u) / 32u), &word)) return 0;
    return ((word >> (g % 32u)) & 1u) == 1u;
}
