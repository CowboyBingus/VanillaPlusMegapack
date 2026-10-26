/* Sentry Aim Retention: the game's functions it calls, and the reads around them (aim_data.lua's bind_natives and
 * prepare_fire; windows_api.lua's api.bind, api.cast_terrain and api.actor_filter), for build 25480438.
 *
 * Bound once per session, when the first sentry is seen, after their code is checked as shipped: the targeting control
 * flag setter, the two turn speed setters and the fire mode setter in game.dll (each replicated: it calls the game's
 * replication notifier), and the physics world id getter and the synchronous ray query in the exe. They are called on
 * the game thread, from the component's tick, as the Lua called them through FFI. The engine pose getter is checked
 * but not called: the muzzle matrix is read along the same path (unit table, generation, object, bone matrices). */
#include <math.h>
#include <string.h>
#include "sentry_aim.h"

#define RVA_RETENTION 0x6BF390u
#define RVA_VERTICAL 0x11CB930u
#define RVA_HORIZONTAL 0x11CBA20u
#define RVA_FIRE_MODE 0x755F90u
#define EXE_POSE_GETTER 0x1FD220u
#define EXE_WORLD_ID 0x79F860u
#define EXE_RAYCAST 0x7F4590u
#define EXE_UNITS 0x1A100F0u     /* the unit table */
#define EXE_ACTOR_POOLS 0x2369B00u
#define EXE_WORLDS 0x27BA8A8u
#define EXE_PROPERTIES 0x27C5E48u /* the collision filter names */
#define RVA_RAY_SCHEDULER 0x347D7E0u
#define RVA_PHYSICS_WORLD 0x346BFA0u
#define DESTRUCTIBLE 0x04A8FBF9u /* the collision filter of destructible cover (fences) */
#define POSES 64
#define COVER_HITS 32u

typedef struct Signature { uint32_t rva; const char* code; } Signature;
static const Signature kSetters[] = {
    {RVA_RETENTION, "40 57 41 57 48 83 EC 28 3B 15 82 48 DC 02 45 0F B6 F9 4C 8B 15 87 79 C6"},
    {RVA_VERTICAL, "48 83 EC 28 8B 41 08 3B 05 E3 82 2B 02 0F 84 D0 00 00 00 4C 8B 15 26 B4"},
    {RVA_HORIZONTAL, "48 83 EC 28 8B 41 08 3B 05 F3 81 2B 02 0F 84 D0 00 00 00 4C 8B 15 36 B3"},
    {RVA_FIRE_MODE, "48 89 4C 24 08 53 55 56 57 41 57 48 83 EC 20"},
};
static const char kPoseGetter[] = "40 53 48 83 EC 20 48 63 DA E8 92 06 EA FF 48 8B C8 4C 8B 00 41 FF 90 E8";
static const Signature kTerrain[] = {
    {EXE_WORLD_ID, "33 C0 4C 8D 05 C7 B2 01 02 0F 1F 80 00 00 00 00 49 39 0C C0 74 0C FF C0 83 F8 04 75 F3"},
    {EXE_RAYCAST, "48 8B C4 F3 0F 11 58 20 89 48 08 55 53 56 57 41 54 41 55 41 56 41 57 48"},
};
static const uint8_t kPoseCode[5] = {0x48, 0x8D, 0x41, 0x60, 0xC3}; /* lea rax, [rcx + 0x60]; ret */

/* The path from the unit table to a unit's object, kept per unit while it holds. */
typedef struct PosePath
{
    uint32_t unit, index, nodes;
    uintptr_t units, generations, slot, object;
    uint8_t generation;
} PosePath;

static struct
{
    int bound, overridden;
    SarNatives natives;
    PosePath poses[POSES];
    int pose_entries, pose_count;
    uint32_t jobs[72];
    uint32_t one[11], cover[11 * COVER_HITS]; /* the queries' private result records (44 bytes each) */
} g;

static int Fail(const char** why, const char* text) { *why = text; return 0; }
static int Error(const char** why, const char* text) { *why = text; return -1; }
static uint64_t U64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }

/* ---- binding ----------------------------------------------------------------------------------------------------- */

void sar_natives_start(void) { memset(&g, 0, sizeof g); }
int sar_natives_bound(void) { return g.bound; }
const SarNatives* sar_natives(void) { return &g.natives; }

void sar_natives_override(const SarNatives* natives)
{
    g.overridden = natives != NULL;
    if (natives != NULL) g.natives = *natives;
}

static int ExeCodeMatches(uint32_t rva, const char* pattern)
{
    return vpm_exe() != 0 && rva < vpm_exe_size() && vpm_hf()->code_matches(vpm_exe() + rva, pattern);
}

int sar_bind_natives(const char** why)
{
    for (size_t k = 0; k < sizeof kSetters / sizeof kSetters[0]; k++)
        if (!vpm_game_code_matches(kSetters[k].rva, kSetters[k].code)) return Fail(why, "Unsupported native sentry setter");
    if (!ExeCodeMatches(EXE_POSE_GETTER, kPoseGetter)) return Fail(why, "Unsupported engine pose getter");
    for (size_t k = 0; k < sizeof kTerrain / sizeof kTerrain[0]; k++)
        if (!ExeCodeMatches(kTerrain[k].rva, kTerrain[k].code)) return Fail(why, "Unsupported terrain query");
    if (!g.overridden)
    {
        g.natives.retention = (SarRetentionFn)(void*)(vpm_game() + RVA_RETENTION);
        g.natives.horizontal = (SarSpeedFn)(void*)(vpm_game() + RVA_HORIZONTAL);
        g.natives.vertical = (SarSpeedFn)(void*)(vpm_game() + RVA_VERTICAL);
        g.natives.fire_mode = (SarFireModeFn)(void*)(vpm_game() + RVA_FIRE_MODE);
        g.natives.world_id = (SarWorldIdFn)(void*)(vpm_exe() + EXE_WORLD_ID);
        g.natives.raycast = (SarRaycastFn)(void*)(vpm_exe() + EXE_RAYCAST);
    }
    g.bound = 1;
    return 1;
}

/* ---- the muzzle pose --------------------------------------------------------------------------------------------- */

/* ptr(): the user-mode pointer at address, or -1 'Pose pointer unavailable'. */
static int Ptr(uintptr_t address, uintptr_t* out, const char** why)
{
    uint8_t b[8];
    *out = sar_load(address, b, 8) ? sar_user_pointer(U64(b)) : 0;
    return *out != 0 ? 1 : Error(why, "Pose pointer unavailable");
}

/* uint(): the u32 at address, or -1 'Pose metadata unavailable'. */
static int Uint(uintptr_t address, uint32_t* out, const char** why)
{
    return sar_load(address, out, 4) ? 1 : Error(why, "Pose metadata unavailable");
}

static int GenerationHolds(const PosePath* p)
{
    uint8_t generation;
    return sar_load(p->generations + p->index, &generation, 1) && generation == p->generation;
}

/* The path checked in full; the object's pose code is checked here, once per path. 1, or -1. */
static int LocatePose(uintptr_t units, uint32_t unit, PosePath* p, const char** why)
{
    uint32_t count, id;
    uintptr_t slots, vtable, code;
    uint8_t bytes[5];
    memset(p, 0, sizeof *p);
    p->unit = unit;
    p->units = units;
    p->index = unit % 0x400000u;
    if (Uint(units + 0x98, &count, why) < 0) return -1;
    if (!(p->index < count)) return Error(why, "Unit index unavailable");
    if (Ptr(units + 0xA0, &p->generations, why) < 0) return -1;
    p->generation = (uint8_t)(unit / 0x400000u % 256u);
    if (!GenerationHolds(p)) return Error(why, "Unit generation changed");
    if (Ptr(units + 0x88, &slots, why) < 0) return -1;
    p->slot = slots + 8u * p->index;
    if (Ptr(p->slot, &p->object, why) < 0 || Uint(p->object + 8, &id, why) < 0) return -1;
    if (id != unit) return Error(why, "Fire node unavailable");
    if (Ptr(p->object, &vtable, why) < 0 || Ptr(vtable + 0xE8, &code, why) < 0) return -1;
    if (!sar_load(code, bytes, 5) || memcmp(bytes, kPoseCode, 5) != 0) return Error(why, "Unsupported pose layout");
    return Uint(p->object + 0x70, &p->nodes, why);
}

/* Whether a kept path still names the unit: 1, 0 (locate it again), -1. */
static int PoseStill(const PosePath* p, uintptr_t units, uint32_t unit, const char** why)
{
    uintptr_t object;
    uint32_t id;
    if (p->units != units || !GenerationHolds(p)) return 0;
    if (Ptr(p->slot, &object, why) < 0) return -1;
    if (object != p->object) return 0;
    if (Uint(p->object + 8, &id, why) < 0) return -1;
    return id == unit;
}

static PosePath* FindPose(uint32_t unit)
{
    for (int k = 0; k < g.pose_entries; k++)
        if (g.poses[k].unit == unit) return &g.poses[k];
    return NULL;
}

/* Bounded: units are recycled, so a long session forgets old paths (more than 64 locates: only this one stays). */
static PosePath* KeepPose(const PosePath* fresh)
{
    if (++g.pose_count > POSES) { g.pose_entries = 0; g.pose_count = 1; }
    PosePath* p = FindPose(fresh->unit);
    if (p == NULL) p = &g.poses[g.pose_entries++];
    *p = *fresh;
    return p;
}

void sar_pose_forget(void) { g.pose_entries = g.pose_count = 0; }

int sar_pose(uint32_t unit, uint32_t node, uint8_t matrix[64], const char** why)
{
    uintptr_t units, matrices;
    if (Ptr(vpm_exe() + EXE_UNITS, &units, why) < 0) return -1;
    PosePath* p = FindPose(unit);
    int still = p != NULL ? PoseStill(p, units, unit, why) : 0;
    if (still < 0) return -1;
    if (!still)
    {
        PosePath fresh;
        if (LocatePose(units, unit, &fresh, why) < 0) return -1;
        p = KeepPose(&fresh);
    }
    if (!(node < p->nodes)) return Error(why, "Fire node unavailable");
    if (Ptr(p->object + 0x88, &matrices, why) < 0) return -1;
    int read = sar_load(matrices + 64u * node, matrix, 64);
    if (!GenerationHolds(p)) return Error(why, "Pose identity changed");
    return read;
}

/* ---- the collision filter of a hit actor (api.actor_filter) ------------------------------------------------------ */

/* The actor's pool header, entry, collision record and physics body, each read again before its filter is trusted. */
typedef struct Actor
{
    uint32_t world_index, identity, offset, filter, count;
    uintptr_t pool, entry, world_slot, world, bodies, address, properties, names;
    uint8_t h[56], key[4], record[40], body[160];
} Actor;

static uintptr_t ReadPointer(uintptr_t address)
{
    uint8_t b[8];
    return sar_load(address, b, 8) ? sar_user_pointer(U64(b)) : 0;
}

/* The pool header's layout admits the handle: 1 with e->entry. */
static int PoolEntry(Actor* e, uint32_t actor)
{
    uint32_t layout = sar_u32(e->h + 28), stride = layout & 0xFFFFu;
    int32_t index = (int32_t)(actor & sar_u32(e->h + 40));
    uintptr_t base = sar_user_pointer(U64(e->h));
    e->identity = (layout >> 16) & 0xFFu;
    e->offset = layout >> 24;
    if (base == 0 || index < 0 || (uint32_t)index >= sar_u32(e->h + 36) || (actor & sar_u32(e->h + 52)) == 0) return 0;
    if (stride < 40 || stride > 512 || e->identity + 4 > stride || e->offset + 40 > stride) return 0;
    e->entry = base + (uintptr_t)(uint32_t)index * stride;
    return 1;
}

/* The pool entry, only when the handle resolves to this unit. */
static int ActorEntry(Actor* e, uint32_t actor, uint32_t unit)
{
    e->world_index = actor / 0x40000000u;
    e->pool = vpm_exe() + EXE_ACTOR_POOLS + 64u * (actor / 0x10000000u % 4u + 10u * e->world_index);
    if (!sar_load(e->pool, e->h, 56) || !PoolEntry(e, actor)) return 0;
    if (!sar_load(e->entry + e->identity, e->key, 4) || sar_u32(e->key) != actor) return 0;
    return sar_load(e->entry + e->offset, e->record, 40) && sar_u32(e->record + 12) == unit;
}

/* The actor's physics body, checked against the actor and the unit. */
static int ActorBody(Actor* e, uint32_t actor, uint32_t unit)
{
    e->world_slot = vpm_exe() + EXE_WORLDS + 176u * e->world_index;
    e->world = ReadPointer(e->world_slot);
    if (e->world == 0) return 0;
    e->bodies = ReadPointer(e->world + 24);
    uint32_t body = sar_u32(e->record + 20) & 0xFFFFFFu;
    if (e->bodies == 0 || body >= 262144u) return 0;
    e->address = e->bodies + 160u * body;
    return sar_load(e->address, e->body, 160) && sar_u32(e->body + 144) == actor && sar_u32(e->body + 148) == unit;
}

/* The body's collision filter: 1 with its name word read into name (*named 0 when that read failed), 0 no table. */
static int FilterName(Actor* e, uint8_t name[4], int* named)
{
    uint8_t count[4];
    e->properties = ReadPointer(vpm_exe() + EXE_PROPERTIES);
    if (e->properties == 0) return 0;
    int counted = sar_load(e->properties + 248, count, 4);
    e->names = ReadPointer(e->properties + 256);
    e->filter = sar_u32(e->body + 108) & 127u;
    e->count = sar_u32(count);
    if (!counted || e->count > 128 || e->filter >= e->count || e->names == 0) return 0;
    *named = sar_load(e->names + 4u * e->filter, name, 4);
    return 1;
}

static int ReadSame(uintptr_t address, const uint8_t* bytes, size_t size)
{
    uint8_t now[160];
    return size <= sizeof now && sar_load(address, now, size) && memcmp(now, bytes, size) == 0;
}

/* Every link read again: an actor, body or table that changed meanwhile gives no filter. */
static int Unchanged(const Actor* e, const uint8_t name[4], int named)
{
    uint8_t now[4], count[4];
    if (!ReadSame(e->pool, e->h, 56) || !ReadSame(e->entry + e->identity, e->key, 4) || !ReadSame(e->entry + e->offset, e->record, 40))
        return 0;
    if (ReadPointer(e->world_slot) != e->world || ReadPointer(e->world + 24) != e->bodies || !ReadSame(e->address, e->body, 160))
        return 0;
    if (ReadPointer(vpm_exe() + EXE_PROPERTIES) != e->properties || ReadPointer(e->properties + 256) != e->names) return 0;
    if (!sar_load(e->properties + 248, count, 4) || sar_u32(count) != e->count) return 0;
    int again = sar_load(e->names + 4u * e->filter, now, 4);
    return again == named && (!named || memcmp(now, name, 4) == 0);
}

int sar_actor_filter(uint32_t actor, uint32_t unit, uint32_t* filter)
{
    Actor e;
    uint8_t name[4];
    int named = 0;
    memset(&e, 0, sizeof e);
    if (!ActorEntry(&e, actor, unit) || !ActorBody(&e, actor, unit)) return 0;
    if (!FilterName(&e, name, &named) || !Unchanged(&e, name, named) || !named) return 0;
    *filter = sar_u32(name);
    return 1;
}

/* ---- the terrain query (api.cast_terrain) ------------------------------------------------------------------------ */

/* The ray from origin to target: its start, unit direction and length; 0 when the points lie within 5 cm. */
static int Ray(const SarCast* cast, float from[3], float direction[3], double* length, const char** why)
{
    float to[3];
    double sum = 0;
    memcpy(from, cast->origin, 12);
    memcpy(to, cast->target, 12);
    for (int i = 0; i < 3; i++)
    {
        double delta = (double)to[i] - (double)from[i];
        if (!(delta == delta && fabs(delta) < 100000.0)) return Error(why, "Invalid terrain ray");
        direction[i] = (float)delta;
        sum += delta * delta;
    }
    *length = sqrt(sum);
    if (*length < 0.05) return 0;
    if (!(*length < 2000.0)) return Error(why, "Terrain ray outside sentry range");
    for (int i = 0; i < 3; i++) direction[i] = (float)((double)direction[i] / *length);
    return 1;
}

typedef struct Query { const SarCast* cast; float from[3], direction[3]; double length; } Query;

/* Matches the native static-obstacle preset: actor class 3, the damage filter and flags 0x80000009, the sentry's own
 * unit ignored. The native filter admits only static bodies: character and ragdoll volumes never veto fire. */
static uint32_t Cast(const Query* q, uint32_t collection, uint32_t* out, uint32_t capacity)
{
    memset(out, 0, 44u * capacity); /* nothing of an earlier query may read as a hit of this one */
    return q->cast->raycast(q->cast->world, q->from, q->direction, (float)q->length, collection, 3, 0x393D9518u, 0x80000009u,
        q->cast->unit, out, capacity);
}

/* One hit: 1 a solid obstruction, 0 not (hit->reason says why), -1 an invalid hit. */
static int Classify(const Query* q, const uint32_t* out, uint32_t index, SarHit* hit, const char** why)
{
    const uint32_t* h = out + 11u * index;
    uint32_t filter;
    memset(hit, 0, sizeof *hit);
    hit->distance = sar_f32((const uint8_t*)(h + 6));
    hit->length = q->length;
    if (!(hit->distance == hit->distance && hit->distance >= 0 && hit->distance <= q->length + 0.05))
        return Error(why, "Invalid terrain hit");
    hit->hit_unit = h[7];
    hit->actor = h[8];
    hit->reason = SAR_HIT_STATIC_OBSTRUCTION;
    if (q->cast->has_target_unit && hit->hit_unit == q->cast->target_unit) hit->reason = SAR_HIT_TARGET_SURFACE;
    else if (hit->distance >= q->length - 0.05) hit->reason = SAR_HIT_ENDPOINT; /* a surface endpoint is legal */
    else if (q->cast->filter != NULL && q->cast->filter(hit->actor, hit->hit_unit, &filter) && filter == DESTRUCTIBLE)
        hit->reason = SAR_HIT_DESTRUCTIBLE_COVER; /* a fence does not prove the weapon cannot shoot through it */
    return hit->reason == SAR_HIT_STATIC_OBSTRUCTION;
}

/* Solid terrain can sit behind a fence, even within the same unit: every hit up to 32, the nearest solid one wins. A
 * truncated result cannot establish obstruction. */
static int BehindCover(const Query* q, SarHit* hit, const char** why)
{
    SarHit nearest = {0}, cover = {0}, h;
    int has_nearest = 0, has_cover = 0;
    uint32_t count = Cast(q, 2, g.cover, COVER_HITS);
    for (uint32_t i = 0; i < (count < COVER_HITS ? count : COVER_HITS); i++)
    {
        int solid = Classify(q, g.cover, i, &h, why);
        if (solid < 0) return -1;
        if (solid && (!has_nearest || h.distance < nearest.distance)) { nearest = h; has_nearest = 1; }
        if (h.reason == SAR_HIT_DESTRUCTIBLE_COVER && !has_cover) { cover = h; has_cover = 1; }
    }
    if (has_nearest) { *hit = nearest; return 1; }
    memset(hit, 0, sizeof *hit);
    if (count > COVER_HITS) { hit->reason = SAR_HIT_COVER_QUERY_LIMIT; hit->hits = count; return 0; }
    if (has_cover) *hit = cover;
    return 0;
}

int sar_cast_terrain(const SarCast* cast, SarHit* hit, const char** why)
{
    Query q = {cast, {0}, {0}, 0};
    memset(hit, 0, sizeof *hit);
    hit->reason = SAR_UNKNOWN;
    int ray = Ray(cast, q.from, q.direction, &q.length, why);
    if (ray <= 0) return ray;
    if (cast->world >= 4) return Error(why, "Invalid physics world");
    if (Cast(&q, 1, g.one, 1) == 0) { hit->reason = SAR_HIT_CLEAR; return 0; }
    int blocked = Classify(&q, g.one, 0, hit, why);
    return blocked < 0 || hit->reason != SAR_HIT_DESTRUCTIBLE_COVER ? blocked : BehindCover(&q, hit, why);
}

/* The native ray workers use this scheduler: query only when nothing is pending and all 24 workers are done, with
 * private inputs and output; never enqueue work. */
int sar_terrain_path(uint32_t unit, const uint8_t origin[12], const uint8_t target[12], uint32_t target_unit, int* blocked,
    const char** why)
{
    uintptr_t scheduler = sar_user_pointer(vpm_game_u64(RVA_RAY_SCHEDULER));
    uintptr_t world = sar_user_pointer(vpm_game_u64(RVA_PHYSICS_WORLD));
    uint32_t pending;
    if (scheduler == 0 || world == 0) return 0;
    if (Uint(scheduler, &pending, why) < 0) return -1;
    if (pending != 0 || !sar_load(scheduler + 0x40008, g.jobs, sizeof g.jobs)) return 0;
    for (int i = 0; i < 24; i++)
        if (g.jobs[3 * i + 2] != 1) return 0;
    SarCast cast = {g.natives.raycast, g.natives.world_id((const void*)world), unit, origin, target, 1, target_unit, sar_actor_filter};
    SarHit hit;
    int r = sar_cast_terrain(&cast, &hit, why);
    if (r < 0) return -1;
    *blocked = r;
    return 1;
}

/* ---- prepare_fire ------------------------------------------------------------------------------------------------ */

static int Synchronized(const SarRow* s)
{
    return s->enabled && s->has && s->target != 0 && s->runtime_target == s->target && (s->source_flags & 1u) != 0;
}

/* The current target point, before ballistic or lead correction: a low target stays legal while terrain does not hide
 * it. The target's identity is checked around the query; a change marks it stale (it is located again). */
static int Clearance(SarRow* s, const char** why)
{
    int blocked = 0;
    if (sar_matches(&s->fire.target_guard, 1))
    {
        if (!s->fire.has_pose) return Fail(why, "Invalid muzzle pose");
        int r = sar_terrain_path(s->fire.unit, s->fire.pose + 48, s->raw, s->fire.target_unit, &blocked, why);
        if (r < 0) return 0;
        s->fire.terrain_blocked = r > 0 ? blocked : SAR_UNKNOWN;
    }
    if (!sar_matches(&s->fire.target_guard, 1)) { s->fire.terrain_blocked = SAR_UNKNOWN; s->fire.target_stale = 1; }
    return 1;
}

int sar_prepare_fire(SarRow* s, const char** why)
{
    uint8_t bytes[113];
    int r = sar_pose(s->fire.unit, s->fire.node, s->fire.pose, why);
    if (r < 0) return 0;
    s->fire.has_pose = r;
    if (!Synchronized(s)) return 1;
    if (s->fire.has_target_unit && !Clearance(s, why)) return 0;
    /* The transition fields, read again in one read. */
    if (!sar_load(s->transition_address, bytes, sizeof bytes)) return Fail(why, "Runtime read unavailable");
    SarWindow window = {s->transition_address, sizeof bytes, bytes};
    return sar_verified(s->transition, s->transition_count, &window, 1) ? 1 : Fail(why, "Terrain target changed");
}
