/* Enemy Collision Synchronized: one listed, eligible unit read and checked in full (the Lua: corpse_data.lua new_unit,
 * ragdoll_runtime, main_members, skeleton, actor_handles, actor_row, actor_body, count_main_body, actionable,
 * inspect_actor, inspect).
 *
 * Its identity guards: the entity header, the mode slot and flag, its pointer array entry. A ragdoll's runtime record
 * (runtime + index * 11192: +11160 body count, update byte, flags) and sync record (sync + index * 432: the count its
 * eligibility check read, +184 rotation count, +428 flag) must match the profile; its main members (712 bytes each, with
 * their registered sub-actors) are read and guarded. The unit object (the exe's unit registry [0x1A100F0]: generation,
 * identity, skeleton size, node matrices), then its actor handles (the exe's actor lists [0x27C5B40], 24 bytes per unit
 * slot). Each actor's pool row (the exe's pools at 0x2369B00, 64 bytes apart; rows copied 16 at a time) and, for an
 * enabled actor, its physics body (160 bytes, its identity checked against the actor). Main bodies are counted and
 * guarded; an auxiliary actor M.plan could act on is kept with the bytes its command guards are made from. Disabled
 * bodies are never read. Every guard is compared again before the unit is handed over. */
#include <string.h>
#include "ecs_internal.h"

#define REGISTRY_RVA 0x1A100F0u    /* exe: the unit registry */
#define ACTOR_LISTS_RVA 0x27C5B40u /* exe: the actor handle lists, by unit slot */
#define POOLS_RVA 0x2369B00u       /* exe: actor pools, 64 bytes apart */
#define RUNTIME_STRIDE 11192u
#define SYNC_STRIDE 432u
#define MEMBER_STRIDE 712u
#define MAX_NODES 256u
#define POOLS 40u

typedef struct Pool { int known; uintptr_t base; uint32_t count, mask, generation, stride, identity_offset, data_offset; } Pool;
typedef struct Row { uintptr_t identity_address, data_address; uint8_t identity[4], data[40]; } Row;
typedef struct Body { uintptr_t address; uint8_t bytes[160]; uint32_t motion, filter; } Body;
typedef struct Inspection
{
    const EcsVisit* visit;
    EcsUnit* unit;
    const EcsProfile* profile;
    uint32_t node_count, name_count;
    uint32_t names[ECS_MAX_BODIES]; /* the main actor names seen */
} Inspection;

static struct
{
    Pool pools[POOLS];
    int body_known[4];
    uintptr_t bodies[4];
} p;

static uint8_t g_members[ECS_MAX_BODIES * MEMBER_STRIDE];
static uint8_t g_nodes[MAX_NODES * 64u];
static uint8_t g_handles[127u * 4u];
static EcsGuard g_guards[ECS_UNIT_GUARDS];
static uint8_t g_guardBytes[ECS_UNIT_GUARD_BYTES];
static EcsGuard g_poseGuards[ECS_MAX_BODIES];
static uint8_t g_poseBytes[ECS_MAX_BODIES * 64u];

void EcsInspectBegin(void) { memset(&p, 0, sizeof p); }

/* EcsRaise for the functions that answer 1 / 0 / -1. */
static int Raised(const char* why)
{
    EcsRaise(why);
    return -1;
}

/* A guard of bytes copied with one view just before (when viewed), or read on its own. */
static int GuardFrom(EcsUnit* unit, uintptr_t address, void* out, uint32_t size, const uint8_t* view)
{
    if (view == NULL) return EcsGuardRead(&unit->guards, address, out, size);
    memcpy(out, view, size);
    return EcsGuardAdd(&unit->guards, address, out, size);
}

/* ---- the unit record and its identity guards --------------------------------------------------------------------- */

static int NewUnit(const EcsVisit* v, EcsUnit* u)
{
    memset(u, 0, offsetof(EcsUnit, main_bodies));
    u->main_body_count = u->actor_count = 0;
    u->verified = 0;
    u->profile = v->profile;
    u->id = EcsU32(v->header + 8);
    u->unit = EcsU32(v->header + 12);
    u->corpse = v->corpse;
    u->address = v->address;
    u->owner = (EcsU32(v->header + 20) & 1u) != 0;
    u->active = v->index < v->active;
    u->manager = v->manager;
    u->index = v->index;
    u->update_enabled = v->corpse ? -1 : 0;
    u->root_body = -1;
    EcsGuardsInit(&u->guards, g_guards, ECS_UNIT_GUARDS, g_guardBytes, ECS_UNIT_GUARD_BYTES);
    EcsGuardsInit(&u->pose_guards, g_poseGuards, ECS_MAX_BODIES, g_poseBytes, sizeof g_poseBytes);
    return EcsGuardAdd(&u->guards, (uintptr_t)v->address, v->header, 24) &&
        EcsGuardAdd(&u->guards, vpm_game() + ECS_MODE_SLOT_RVA, &v->mode_slot, 8) &&
        EcsGuardAdd(&u->guards, v->mode + 8u, v->mode_bytes + 8, 4) &&
        EcsGuardAdd(&u->guards, v->entities + (uintptr_t)v->index * 8u, &v->pointer, 8);
}

static int Register(EcsUnit* u, uint32_t id)
{
    if (u->registered_count >= ECS_MAX_REGISTERED) return EcsRaise("Sub-actor bounds changed");
    u->registered[u->registered_count++] = id;
    return 1;
}

static int Registered(const EcsUnit* u, uint32_t id)
{
    for (uint32_t i = 0; i < u->registered_count; i++)
        if (u->registered[i] == id) return 1;
    return 0;
}

/* A ragdoll's main member id: 1 with its profile name. */
static int Member(const EcsUnit* u, uint32_t id, uint32_t* name)
{
    for (uint32_t i = 0; i < u->member_count; i++)
        if (u->members[i] == id) { *name = u->member_names[i]; return 1; }
    return 0;
}

/* ---- a ragdoll's runtime and sync records ------------------------------------------------------------------------- */

/* Main member i of a ragdoll's runtime record: its id (unique), its registered sub-actors, its 8-byte guard. */
static int AddMember(EcsUnit* u, const EcsProfile* profile, uintptr_t runtime, uint32_t i)
{
    const uint8_t* member = g_members + i * MEMBER_STRIDE;
    uint32_t id = EcsU32(member), unused;
    if (id == 0xFFFFFFFFu || Member(u, id, &unused)) return EcsRaise("Invalid main actor membership");
    u->members[i] = u->signature.ids[i] = id;
    u->member_names[i] = profile->main[i];
    u->member_count = u->signature.count = i + 1u;
    if (i == 0) { u->root_id = id; u->has_root_id = 1; }
    if (!Register(u, id) || !EcsGuardAdd(&u->guards, runtime + i * MEMBER_STRIDE, member, 8)) return 0;
    uint32_t n = EcsU32(member + 12);
    if (n > 9) return EcsRaise("Sub-actor bounds changed");
    for (uint32_t j = 0; j < n; j++)
        if (!Register(u, EcsU32(member + 28 + j * 76))) return 0;
    return 1;
}

static int MainMembers(EcsUnit* u, const EcsProfile* profile, uintptr_t runtime)
{
    if (!EcsRead(runtime, g_members, (size_t)profile->bodies * MEMBER_STRIDE)) return 0;
    for (uint32_t i = 0; i < profile->bodies; i++)
        if (!AddMember(u, profile, runtime, i)) return 0;
    return 1;
}

/* 1 matches the profile, 0 does not qualify this poll, -1 raised. */
static int RagdollRuntime(const EcsVisit* v, EcsUnit* u, const EcsProfile* profile)
{
    uintptr_t runtime = v->runtime + (uintptr_t)v->index * RUNTIME_STRIDE;
    uint8_t meta[32];
    if (!EcsGuardRead(&u->guards, runtime + 11160u, meta, sizeof meta)) return -1;
    if (EcsU32(meta) != profile->bodies || meta[12] > 1 || meta[13] != 0 || EcsU64(meta + 16) != 0) return 0;
    u->update_enabled = meta[12] == 1;
    u->update_address = runtime + 11172u;
    uintptr_t sync = v->sync + (uintptr_t)v->index * SYNC_STRIDE;
    /* The eligibility check read the count at sync this poll, with no native call since: its bytes are the guard's. The
     * rotation count (+184) and flag (+428) lie within 245 bytes: one copy, each with its own guard. */
    uint8_t view[245], rotations[4], flag = 0;
    int viewed = EcsCapture(sync + 184u, view, sizeof view);
    if (!EcsGuardAdd(&u->guards, sync, &v->quick, 4) || !GuardFrom(u, sync + 184u, rotations, 4, viewed ? view : NULL) ||
        !GuardFrom(u, sync + 428u, &flag, 1, viewed ? view + 244 : NULL))
        return -1;
    if (v->quick != profile->bodies || EcsU32(rotations) != profile->bodies || flag != 0) return 0;
    return MainMembers(u, profile, runtime) ? 1 : -1;
}

/* ---- the unit object and its actor handles ----------------------------------------------------------------------- */

/* The registry's slot, generation and object: *object, or 0 raised. */
static int UnitObject(EcsUnit* u, uint32_t* slot_index, uintptr_t* object)
{
    uint64_t slot = vpm_exe_u64(REGISTRY_RVA);
    if (!EcsGuardAdd(&u->guards, vpm_exe() + REGISTRY_RVA, &slot, 8)) return 0;
    uintptr_t registry = EcsPointer(slot);
    if (registry == 0) return EcsRaise("Pointer unavailable");
    const uint8_t* header = EcsCached(registry, 0xA8, 0);
    if (header == NULL) return 0;
    uint32_t limit = EcsU32(header + 0x98);
    uintptr_t generations = EcsPointer(EcsU64(header + 0xA0)), slots = EcsPointer(EcsU64(header + 0x88));
    *slot_index = u->unit % 0x400000u;
    if (*slot_index >= limit) return EcsRaise("Unit index changed");
    if (generations == 0) return EcsRaise("Pointer unavailable");
    uint8_t generation = 0;
    if (!EcsGuardRead(&u->guards, generations + *slot_index, &generation, 1)) return 0;
    if ((u->unit >> 22) > 255u || generation != (u->unit >> 22)) return EcsRaise("Unit generation changed");
    if (slots == 0) return EcsRaise("Pointer unavailable");
    uint8_t entry[8];
    if (!EcsGuardRead(&u->guards, slots + (uintptr_t)*slot_index * 8u, entry, 8)) return 0;
    if ((*object = EcsPointer(EcsU64(entry))) == 0) return EcsRaise("Pointer unavailable");
    return 1;
}

/* The unit object's identity (+8), skeleton size (+0x70) and node pointer (+0x88), one copy; then the node matrices. */
static int Skeleton(EcsUnit* u, const EcsProfile* profile, uint32_t* slot_index, uint32_t* node_count)
{
    uintptr_t object = 0;
    if (!UnitObject(u, slot_index, &object)) return 0;
    uint8_t view[0x88], identity[4], count[4], nodes[8];
    int viewed = EcsCapture(object + 8u, view, sizeof view);
    if (!GuardFrom(u, object + 8u, identity, 4, viewed ? view : NULL)) return 0;
    if (EcsU32(identity) != u->unit) return EcsRaise("Unit identity changed");
    if (!GuardFrom(u, object + 0x70u, count, 4, viewed ? view + 0x68 : NULL)) return 0;
    *node_count = EcsU32(count);
    if (*node_count != profile->nodes || *node_count > MAX_NODES) return EcsRaise("Skeleton changed");
    if (!GuardFrom(u, object + 0x88u, nodes, 8, viewed ? view + 0x80 : NULL)) return 0;
    uintptr_t matrices = EcsPointer(EcsU64(nodes));
    if (matrices == 0) return EcsRaise("Pointer unavailable");
    return EcsRead(matrices, g_nodes, (size_t)*node_count * 64u);
}

/* The unit's actor handles, inline or behind a pointer: 1 with *n, 0 none, -1 raised. */
static int ActorHandles(EcsUnit* u, uint32_t slot_index, uint32_t* n)
{
    uint64_t slot = vpm_exe_u64(ACTOR_LISTS_RVA);
    if (!EcsGuardAdd(&u->guards, vpm_exe() + ACTOR_LISTS_RVA, &slot, 8)) return -1;
    uintptr_t lists = EcsPointer(slot);
    if (lists == 0) return Raised("Pointer unavailable");
    uintptr_t list = lists + (uintptr_t)slot_index * 24u;
    uint8_t head[24];
    if (!EcsGuardRead(&u->guards, list, head, sizeof head)) return -1;
    uint32_t flags = EcsU32(head + 4);
    if (!(flags & 0x40000000u) || (EcsU32(head) & 0x3FFFFFFFu) != u->unit) return Raised("Actor list identity changed");
    *n = flags & 127u;
    if (*n == 0) return 0;
    uintptr_t handles = (flags & 0x80000000u) ? list + 8u : EcsPointer(EcsU64(head + 8));
    if (handles == 0) return Raised("Pointer unavailable");
    return EcsGuardRead(&u->guards, handles, g_handles, *n * 4u) ? 1 : -1;
}

/* ---- actors ------------------------------------------------------------------------------------------------------- */

static int PoolFor(uint32_t index, Pool** out)
{
    if (index >= POOLS) return EcsRaise("Data unavailable");
    Pool* pool = &p.pools[index];
    *out = pool;
    if (pool->known) return 1;
    uint8_t b[56];
    if (!EcsImageRead(vpm_exe() + POOLS_RVA + 64u * index, b, sizeof b)) return EcsRaise("Data unavailable");
    uint32_t layout = EcsU32(b + 28);
    if ((pool->base = EcsPointer(EcsU64(b))) == 0) return EcsRaise("Pointer unavailable");
    pool->count = EcsU32(b + 36);
    pool->mask = EcsU32(b + 40);
    pool->generation = EcsU32(b + 52);
    pool->stride = layout & 0xFFFFu;
    pool->identity_offset = (layout >> 16) & 0xFFu;
    pool->data_offset = layout >> 24;
    pool->known = 1;
    return 1;
}

/* An actor's pool row: its identity word and 40 data bytes. Rows are copied 16 together when the layout allows; one
 * that cannot be copied is read on its own. */
static int ActorRow(uint32_t id, Row* row)
{
    Pool* pool = NULL;
    if (!PoolFor(((id >> 28) & 3u) + 10u * (id >> 30), &pool)) return 0;
    uint32_t ai = id & pool->mask;
    if (!(ai < pool->count && (id & pool->generation) != 0)) return EcsRaise("Expired actor");
    uintptr_t entry = pool->base + (uintptr_t)ai * pool->stride;
    row->identity_address = entry + pool->identity_offset;
    row->data_address = entry + pool->data_offset;
    if (pool->stride <= 256u && pool->identity_offset + 4u <= pool->stride && pool->data_offset + 40u <= pool->stride)
    {
        uint32_t first = ai - ai % 16u, rows = pool->count - first < 16u ? pool->count - first : 16u;
        const uint8_t* block = EcsCached(pool->base + (uintptr_t)first * pool->stride, rows * pool->stride, 1);
        if (block != NULL)
        {
            const uint8_t* at = block + (size_t)(ai - first) * pool->stride;
            memcpy(row->identity, at + pool->identity_offset, 4);
            memcpy(row->data, at + pool->data_offset, 40);
            return 1;
        }
    }
    return EcsRead(row->identity_address, row->identity, 4) && EcsRead(row->data_address, row->data, 40);
}

static int BodyArray(uint32_t world_index, uintptr_t world, uintptr_t* base)
{
    if (!p.body_known[world_index])
    {
        const uint8_t* bytes = EcsCached(world + 24u, 8, 0);
        if (bytes == NULL) return 0;
        if ((p.bodies[world_index] = EcsPointer(EcsU64(bytes))) == 0) return EcsRaise("Pointer unavailable");
        p.body_known[world_index] = 1;
    }
    *base = p.bodies[world_index];
    return 1;
}

/* An enabled actor's physics body, copied whole and checked against the actor. */
static int ActorBody(const EcsUnit* u, uint32_t id, const Row* row, Body* body)
{
    uint32_t world_index = id >> 30;
    uintptr_t world = 0, base = 0;
    if (!EcsWorldFor(world_index, &world)) return 0;
    if (world == 0) return EcsRaise("Physics world unavailable");
    uint32_t bi = EcsU32(row->data + 20) & 0xFFFFFFu;
    if (bi >= 262144u) return EcsRaise("Body index changed");
    if (!BodyArray(world_index, world, &base)) return 0;
    body->address = base + 160u * (uintptr_t)bi;
    if (!EcsRead(body->address, body->bytes, 160)) return 0;
    if (EcsU32(body->bytes + 144) != id || EcsU32(body->bytes + 148) != u->unit) return EcsRaise("Physics body identity changed");
    body->motion = EcsU32(body->bytes + 64);
    body->filter = EcsU32(body->bytes + 108) & 127u;
    return 1;
}

/* A main actor's row guards (its data, then its identity), its name checked unique. */
static int MainRow(Inspection* in, const Row* row, uint32_t name, uint32_t member_name, int enabled)
{
    EcsUnit* u = in->unit;
    int seen = 0;
    for (uint32_t i = 0; i < in->name_count; i++) seen |= in->names[i] == name;
    if ((!u->corpse && name != member_name) || seen || in->name_count >= ECS_MAX_BODIES) return EcsRaise("Main actor names changed");
    in->names[in->name_count++] = name;
    if (!EcsGuardAdd(&u->guards, row->data_address, row->data, 40) ||
        !EcsGuardAdd(&u->guards, row->identity_address, row->identity, 4))
        return 0;
    if (!enabled && EcsProfileDisabledMain(in->profile, name)) u->main_disabled++;
    return 1;
}

/* An enabled main body: counted, its motion and identity guarded, its pose guarded and (ragdolls) decoded. */
static int CountMainBody(Inspection* in, uint32_t id, uint32_t name, const Body* body)
{
    EcsUnit* u = in->unit;
    u->main_enabled++;
    if (body->motion == 0) u->main_static++;
    if (u->corpse && body->motion != 0 && EcsProfileDynamicMain(in->profile, name)) u->main_dynamic_allowed++;
    if (u->main_body_count >= ECS_MAX_BODIES) return EcsRaise("Main actor names changed");
    if (!EcsGuardAdd(&u->guards, body->address + 64u, body->bytes + 64, 4) ||
        !EcsGuardAdd(&u->guards, body->address + 144u, body->bytes + 144, 8) ||
        !EcsGuardAdd(&u->pose_guards, body->address, body->bytes, 64))
        return 0;
    EcsMainBody* main = &u->main_bodies[u->main_body_count];
    main->id = id;
    if (!u->corpse) EcsDecodeMatrix(body->bytes, main->pose);
    else memset(main->pose, 0, sizeof main->pose);
    /* The root's only guard is its pose guard, already among the pose guards. */
    if (u->has_root_id && id == u->root_id) u->root_body = (int)u->main_body_count;
    u->main_body_count++;
    return 1;
}

/* Whether M.plan could act on this auxiliary actor: the allowlisted name and node, not registered, and a claw, or a
 * static body whose matrix differs from its node's (an identical one is aligned already). */
static int Actionable(const Inspection* in, const Row* row, int registered, const Body* body)
{
    uint32_t name = EcsU32(row->data + 24), node = EcsU32(row->data + 28), allowed = 0;
    if (!EcsProfileActor(in->profile, name, &allowed)) return 0;
    if (node >= in->node_count || registered || allowed != EcsU32(row->data + 32)) return 0;
    if (in->profile->impaler && EcsClaw(name)) return 1;
    return body->motion == 0 && memcmp(g_nodes + (size_t)node * 64u, body->bytes, 64) != 0;
}

static void KeepActor(Inspection* in, uint32_t id, const Row* row, int registered, const Body* body)
{
    EcsUnit* u = in->unit;
    if (u->actor_count >= ECS_MAX_ACTORS) return;
    EcsActor* a = &u->actors[u->actor_count++];
    a->id = id;
    a->name = EcsU32(row->data + 24);
    a->node = EcsU32(row->data + 28);
    a->node_hash = EcsU32(row->data + 32);
    a->motion = body->motion;
    a->enabled = 1;
    a->registered = registered;
    const uint8_t* node = g_nodes + (size_t)a->node * 64u;
    EcsDecodeMatrix(node, a->node_pose);
    a->same_pose = memcmp(node, body->bytes, 64) == 0;
    if (a->same_pose) memcpy(a->pose, a->node_pose, sizeof a->pose);
    else EcsDecodeMatrix(body->bytes, a->pose);
    a->identity_address = row->identity_address;
    a->data_address = row->data_address;
    a->body_address = body->address;
    memcpy(a->identity, row->identity, 4);
    memcpy(a->data, row->data, 40);
    memcpy(a->body, body->bytes, 160);
}

/* One actor of the unit: its row; a main actor's guards and counts; an enabled actor's body; a record for an auxiliary
 * actor M.plan could act on. 1, or 0 raised. */
static int InspectActor(Inspection* in, uint32_t id)
{
    EcsUnit* u = in->unit;
    Row row;
    if (!ActorRow(id, &row)) return 0;
    if (EcsU32(row.identity) != id) return EcsRaise("Actor generation changed");
    if (EcsU32(row.data + 12) != u->unit) return EcsRaise("Actor owner changed");
    uint32_t name = EcsU32(row.data + 24), member_name = 0;
    int enabled = (EcsU32(row.data + 16) & 1u) != 0;
    int main = u->corpse ? EcsProfileMain(in->profile, name) : Member(u, id, &member_name);
    if (main && !MainRow(in, &row, name, member_name, enabled)) return 0;
    /* Disabled tentacles can keep differently tagged body ids: never repair targets, their bodies are never read. */
    if (!enabled) return 1;
    Body body;
    if (!ActorBody(u, id, &row, &body)) return 0;
    if (main && !CountMainBody(in, id, name, &body)) return 0;
    int registered = Registered(u, id) || main || body.filter == 52u || body.filter == 48u || body.filter == 83u;
    if (Actionable(in, &row, registered, &body)) KeepActor(in, id, &row, registered, &body);
    return 1;
}

int EcsInspect(const EcsVisit* v, EcsUnit* u)
{
    const EcsProfile* profile = &EcsProfiles[v->profile];
    if (!NewUnit(v, u)) return -1;
    if (!v->corpse)
    {
        int runtime = RagdollRuntime(v, u, profile);
        if (runtime <= 0) return runtime;
    }
    u->settled = 1;
    uint32_t slot_index = 0, node_count = 0, n = 0;
    if (!Skeleton(u, profile, &slot_index, &node_count)) return -1;
    int handles = ActorHandles(u, slot_index, &n);
    if (handles <= 0) return handles;
    Inspection in = {v, u, profile, node_count, 0, {0}};
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t id = EcsU32(g_handles + i * 4u);
        if (id != 0xFFFFFFFFu && !InspectActor(&in, id)) return -1;
    }
    return EcsSame(&u->guards) ? 1 : 0;
}
