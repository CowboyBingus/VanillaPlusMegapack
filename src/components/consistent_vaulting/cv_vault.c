/* Consistent Vaulting: the vault snapshot (vault_data.lua M.snapshot). Every read becomes a guard, verified again
 * before any write; epoch guards (the identity, the query IDs, the scheduler and its records) also decide whether held
 * or prepared writes still belong to this batch. Image addresses are plain loads, the heap is read through vpm_read. */
#include <math.h>
#include <string.h>
#include "cv.h"

static CvVault g_records[3];

CvVault* cv_vault_record(int index) { return &g_records[index]; }

/* The local avatar's chain: its owner, entity record (address and bytes), avatar manager and index. */
typedef struct Chain { uintptr_t owner, entity, manager; const uint8_t* entity_bytes; uint32_t ai; } Chain;

static const uint8_t kAvatarResource[8] = {0x97, 0xFA, 0x4D, 0x29, 0x4D, 0x33, 0x1C, 0x4D}; /* 0x4d1c334d294dfa97 */

static int Read(CvVault* s, uintptr_t address, size_t size, int epoch, uint8_t** bytes)
{
    return cv_guard_read(&s->guards, address, size, epoch, bytes);
}

static int Global(CvVault* s, uint32_t rva, int epoch, uintptr_t* out)
{
    return cv_guard_pointer(&s->guards, vpm_game() + rva, epoch, out);
}

/* The mission gate: the mode pointer and record. In a mission both become the snapshot's first guards. */
static int MissionGate(CvVault* s, int* in_mission)
{
    uint8_t pointer[8], mode[0x44];
    uintptr_t record;
    if (!cv_load(vpm_game() + CV_RVA_MODE, pointer, 8)) return cv_raise("Game data unavailable");
    if (!cv_pointer(pointer, &record)) return cv_raise("Game pointer unavailable");
    if (!vpm_read(record, mode, sizeof mode)) return cv_raise("Game data unavailable");
    *in_mission = cv_u32(mode + 8) != 0 && cv_u32(mode + 0x40) >= 1 && cv_u32(mode + 0x40) <= 7;
    if (!*in_mission) return 1;
    if (cv_guard_add(&s->guards, vpm_game() + CV_RVA_MODE, pointer, 8, 0) == NULL ||
        cv_guard_add(&s->guards, record, mode, sizeof mode, 0) == NULL)
        return cv_raise("Snapshot read budget exceeded");
    return 1;
}

/* The local player's unit reference (in a mission). */
static int LocalUnit(CvVault* s, uint32_t* unit, const char** why)
{
    uintptr_t pm, record;
    uint8_t *counts, *player, *ref;
    CV_TRY(Global(s, VPM_RVA_PLAYER_MANAGER, 1, &pm));
    CV_TRY(Read(s, pm + 0x84, 8, 0, &counts));
    if (cv_u32(counts) > 4 || cv_u32(counts + 4) > 4) return cv_raise("Unsupported player count");
    if (cv_u32(counts) == 0 || cv_u32(counts + 4) == 0) return cv_why(why, "waiting_for_local_player");
    CV_TRY(cv_guard_pointer(&s->guards, pm + 0xE8, 1, &record));
    CV_TRY(Read(s, record, 24, 1, &player));
    if ((player[20] & 1) == 0) return cv_why(why, "waiting_for_local_player");
    CV_TRY(Read(s, pm + 0x3A8, 4, 1, &ref));
    *unit = cv_u32(ref);
    return *unit == 0x7FFFu ? cv_why(why, "waiting_for_local_avatar") : 1;
}

/* The local avatar entity of the unit: its address and bytes. */
static int LocalEntity(CvVault* s, uint32_t unit, Chain* chain, const char** why)
{
    uint32_t ei = 0;
    uint8_t* entity;
    int found = cv_lookup(&s->guards, chain->owner + 0xF22EC8u, unit, 1048576u, &ei);
    if (found < 0) return found;
    if (found == 0 || ei == CV_INVALID) return cv_why(why, "waiting_for_local_avatar");
    if (ei >= 262144u) return cv_raise("Unsupported entity index");
    chain->entity = chain->owner + 0xF32F18u + (uintptr_t)ei * 24u;
    CV_TRY(Read(s, chain->entity, 24, 1, &entity));
    if (memcmp(entity, kAvatarResource, 8) != 0) return cv_raise("Unsupported avatar resource");
    if ((entity[20] & 1) == 0) return cv_why(why, "waiting_for_local_avatar");
    chain->entity_bytes = entity;
    return 1;
}

/* The avatar index of the entity's ID, checked against the avatar count and the registry: 1, 0 absent. */
static int AvatarIndex(CvVault* s, Chain* chain)
{
    uint32_t ai = 0;
    uint8_t *count, *record;
    uintptr_t registry;
    int found = cv_lookup(&s->guards, chain->manager + 0xF8u, cv_u32(chain->entity_bytes + 8), 64u, &ai);
    if (found != 1 || ai == CV_INVALID) return found < 0 ? found : 0;
    CV_TRY(Read(s, chain->manager + 0x6Cu, 4, 0, &count));
    if (cv_u32(count) > 8 || ai >= cv_u32(count)) return cv_raise("Unsupported avatar index");
    CV_TRY(cv_guard_pointer(&s->guards, chain->manager + 0x110u + (uintptr_t)ai * 8u, 1, &registry));
    CV_TRY(Read(s, registry, 24, 1, &record));
    if (memcmp(record, chain->entity_bytes, 24) != 0) return cv_raise("Avatar registry mismatch");
    chain->ai = ai;
    return 1;
}

/* The local avatar from the mission gate down. */
static int LocalAvatar(CvVault* s, Chain* chain, const char** why)
{
    int in_mission = 0, found;
    uint32_t unit = 0;
    CV_TRY(MissionGate(s, &in_mission));
    if (!in_mission) return cv_why(why, "waiting_for_mission");
    CV_TRY(LocalUnit(s, &unit, why));
    CV_TRY(Global(s, VPM_RVA_ENTITY_OWNER, 1, &chain->owner));
    CV_TRY(LocalEntity(s, unit, chain, why));
    CV_TRY(Global(s, VPM_RVA_AVATAR_MANAGER, 1, &chain->manager));
    found = AvatarIndex(s, chain);
    return found == 0 ? cv_why(why, "waiting_for_local_avatar") : found;
}

/* The same from the slope snapshot of this check, which resolved the chain with the same checks: its reads become this
 * snapshot's guards (and epoch guards), verified again before any write like every other guard. */
static int SlopeAvatar(CvVault* s, const CvSlope* avatar, Chain* chain)
{
    const CvGuards* identity = &avatar->identity;
    for (int i = 0; i < identity->count; i++)
    {
        const CvGuard* g = &identity->list[i];
        if (cv_guard_add(&s->guards, g->address, identity->bytes + g->at, g->size, g->epoch) == NULL)
            return cv_raise("Snapshot read budget exceeded");
    }
    chain->owner = avatar->key.owner;
    chain->entity = avatar->entity;
    chain->entity_bytes = avatar->entity_bytes;
    chain->manager = avatar->key.manager;
    chain->ai = avatar->ai;
    return 1;
}

/* ---- the controller ---------------------------------------------------------------------------------------------- */

/* A held write still in place reads as the restore would leave it (the first matching write at offset). */
static void Unheld(const CvPending* held, uint8_t* bytes, size_t size, uintptr_t address, uint32_t offset)
{
    for (int i = 0; i < held->count; i++)
    {
        const CvWrite* w = &held->writes[i];
        if (w->address == address + offset && offset + w->size <= size && memcmp(bytes + offset, w->after, w->size) == 0)
        {
            memcpy(bytes + offset, w->before, w->size);
            return;
        }
    }
}

#define HIT_PAIR 28u

/* A guard read through the held writes' view: its bytes are the restored ones. */
static int ReadHeld(CvVault* s, const CvPending* held, uintptr_t address, size_t size, uint8_t** bytes)
{
    CV_TRY(Read(s, address, size, 0, bytes));
    if (held == NULL) return 1;
    if (size == CV_HIT_SIZE) Unheld(held, *bytes, size, address, HIT_PAIR);
    else
        for (uint32_t slot = 0; slot < CV_HITS; slot++) Unheld(held, *bytes, size, address, 0x30u + 44u * slot + HIT_PAIR);
    return 1;
}

/* The epoch's query IDs (and at stage 2 its phase) become epoch guards; 1 when the manual vault input is held. */
static int ManualInput(CvVault* s, const Chain* chain)
{
    uint8_t* bytes;
    CV_TRY(Read(s, s->controller + 8, 40, 1, &bytes));
    if (s->stage == 2) CV_TRY(Read(s, s->controller + 4, 4, 1, &bytes));
    s->input_address = cv_input_address(chain->manager, chain->ai);
    CV_TRY(Read(s, s->input_address, 1, 0, &bytes));
    s->manual_bytes = bytes[0];
    if (bytes[0] == 0) return 0;
    s->manual = 1;
    return 1;
}

/* A88020/A88160's checks before re-entering the original local driver. */
static int DriverRefuses(const uint8_t* flags, const uint8_t* controller)
{
    int climbing = (cv_u32(flags + 12) & 0x200u) != 0;
    int excluded = (cv_u32(flags) & 0x404000u) != 0 || (cv_u32(flags + 4) & 0x8000000u) != 0 ||
        (cv_u32(flags + 8) & 0x20084000u) != 0 || (cv_u32(flags + 12) & 0x5181Cu) != 0 || (cv_u32(flags + 16) & 9u) != 0;
    return climbing || excluded || (cv_u32(flags) & 2u) == 0 || controller[0x214] != 0;
}

/* The controller as the restore of held writes would leave it, and the movement flags; at stage 3 nothing while the
 * native driver would refuse a retry. +0x214 is pending climb readiness; +0x215 only reports an automatic step (A8A710
 * can keep it across failed detections, A88160 does not veto on it): never cleared. */
static int ControllerFlags(CvVault* s, const CvPending* held, const Chain* chain, uint8_t** flags, const char** why)
{
    uint8_t* controller;
    CV_TRY(ReadHeld(s, held, s->controller, CV_CONTROLLER_SIZE, &controller));
    memcpy(s->controller_bytes, controller, CV_CONTROLLER_SIZE);
    s->flags_address = chain->manager + (uintptr_t)chain->ai * CV_AVATAR_STRIDE + CV_AT_FLAGS;
    CV_TRY(Read(s, s->flags_address, 24, 0, flags));
    if (s->stage != 3) return 1;
    s->prior_step_report = controller[0x215] != 0;
    return DriverRefuses(*flags, controller) ? cv_why(why, "native_vault_state_retained") : 1;
}

/* ---- the query batch --------------------------------------------------------------------------------------------- */

typedef struct Jobs { uintptr_t scheduler; const uint8_t* bytes; uint32_t total; } Jobs;

/* The query scheduler, its job table and query count. At stage 3 the check runs after consumption: retained
 * descriptors and private discovery queries need an idle scheduler. */
static int QueryScheduler(CvVault* s, uintptr_t manager, Jobs* jobs, const char** why)
{
    uint8_t* bytes;
    CV_TRY(cv_guard_pointer(&s->guards, manager + 0x28u, 1, &jobs->scheduler));
    CV_TRY(Read(s, jobs->scheduler + 0x40000u, 100, 1, &bytes));
    jobs->bytes = bytes;
    jobs->total = cv_u32(bytes);
    if (s->stage != 3) return jobs->total > 0 && jobs->total <= 2048 ? 1 : cv_raise("Unsupported query count");
    if (jobs->total != 0) return cv_why(why, "waiting_for_idle_query_scheduler");
    for (int job = 0; job < 8; job++)
        if (cv_u32(bytes + 12 + job * 12) != 1) return cv_why(why, "waiting_for_query_workers");
    return Global(s, CV_RVA_WORLD, 1, &s->world);
}

/* A completed worker job covers the query. */
static int Completed(const uint8_t* jobs, uint32_t query)
{
    int done = 0;
    for (int job = 0; job < 8; job++)
    {
        uint32_t start = cv_u32(jobs + 4 + job * 12), finish = cv_u32(jobs + 8 + job * 12), state = cv_u32(jobs + 12 + job * 12);
        if (query - 1 >= start && query - 1 < finish && state == 1) done = 1;
    }
    return done;
}

/* The scheduler record of the query for the hit slot. Not a guard: ownership must hold for the whole batch before any
 * shared descriptor becomes one. Reused records are never this epoch's: only discovery at stage 3 rebuilds them. */
static int OwnedRecord(CvVault* s, uintptr_t scheduler, uint32_t query, CvHit* hit, int discovery, const char** why)
{
    uintptr_t output;
    hit->row = scheduler + (uintptr_t)(query - 1) * CV_RECORD_SIZE;
    if (!vpm_read(hit->row, hit->record, CV_RECORD_SIZE)) return cv_raise("Game data unavailable");
    hit->address = s->controller + 0x30u + 44u * (uint32_t)hit->slot;
    if (cv_pointer(hit->record, &output) && output == hit->address) return 1;
    if (s->stage != 3) return cv_raise("Query output is not local controller data");
    if (!discovery) return cv_why(why, "retained_query_reused");
    s->rebuild_queries = 1;
    return 1;
}

static int Seen(const uint32_t* seen, int count, uint32_t query)
{
    for (int i = 0; i < count; i++)
        if (seen[i] == query) return 1;
    return 0;
}

/* The ten query records of the batch, each owned by its local hit slot. */
static int QueryRecords(CvVault* s, const uint8_t* epoch, const Jobs* jobs, int discovery, const char** why)
{
    uint32_t seen[CV_HITS];
    uint32_t limit = s->stage == 3 ? 2048u : jobs->total;
    for (int slot = 0; slot < CV_HITS; slot++)
    {
        uint32_t query = cv_u32(epoch + 4 + slot * 4);
        if (query == 0 || query > limit || Seen(seen, slot, query)) return cv_raise("Unsupported query ID");
        seen[slot] = query;
        if (s->stage == 2 && !Completed(jobs->bytes, query)) return cv_why(why, "waiting_for_query_workers");
        s->hits[slot].slot = slot;
        CV_TRY(OwnedRecord(s, jobs->scheduler, query, &s->hits[slot], discovery, why));
    }
    return 1;
}

/* A9BE10 / 175BA70's fixed query metadata for a rebuilt slot; its geometry comes from a fresh native approach. */
static void QueryTemplate(CvHit* hit, const uint8_t* entity)
{
    uint64_t output = hit->address;
    memset(hit->record, 0, CV_RECORD_SIZE);
    memcpy(hit->record, &output, 8);
    cv_put_u32(hit->record + 0x68, 0x05A5271Au);
    cv_put_u32(hit->record + 0x70, cv_u32(entity + 12));
    hit->record[0x74] = 1;
    hit->record[0x7A] = 2;
    hit->record[0x7B] = 1;
    hit->record[0x7C] = 5;
    hit->count = 0;
}

/* A slot's own descriptor, verified, and its result count. */
static int QueryDescriptor(CvVault* s, CvHit* hit, const uint8_t* entity)
{
    uint8_t* guard;
    const uint8_t* r = hit->record;
    CV_TRY(Read(s, hit->row, CV_RECORD_SIZE, 1, &guard));
    if (memcmp(guard, r, CV_RECORD_SIZE) != 0) return cv_raise("Query changed during snapshot");
    if (cv_u32(r + 0x68) != 0x05A5271Au || cv_u32(r + 0x70) != cv_u32(entity + 12)) return cv_raise("Query identity mismatch");
    if (r[0x7A] != 2 || r[0x7B] != 1 || r[0x7C] != 5) return cv_raise("Unsupported query type");
    if (cv_u16(r + 0x74) != 1 || cv_u16(r + 0x76) > 1) return cv_raise("Unsupported query capacity");
    if (s->stage == 3 && (cv_u64(r + 8) != 0 || cv_u32(r + 0x6C) != 0)) return cv_raise("Unsupported retained query options");
    hit->count = cv_u16(r + 0x76);
    return 1;
}

int cv_hit_take(CvHit* hit, const uint8_t* bytes, uint32_t count)
{
    memcpy(hit->bytes, bytes, CV_HIT_SIZE);
    hit->count = count;
    CV_TRY(cv_vector(bytes, hit->position));
    hit->normal_z = cv_num(bytes + 20);
    hit->unit = cv_u32(bytes + 28);
    hit->actor = cv_u32(bytes + 32);
    return 1;
}

/* A rebuilt slot's hit: no old geometry or count may authorize a cast, so its position is not taken. */
static void TakeRebuilt(CvHit* hit, const uint8_t* bytes)
{
    memcpy(hit->bytes, bytes, CV_HIT_SIZE);
    memset(hit->position, 0, sizeof hit->position);
    hit->normal_z = cv_num(bytes + 20);
    hit->unit = cv_u32(bytes + 28);
    hit->actor = cv_u32(bytes + 32);
}

/* Each slot's descriptor and local hit, read as the restore of held writes would leave it. */
static int ReadHits(CvVault* s, const CvPending* held, const uint8_t* entity)
{
    for (int i = 0; i < CV_HITS; i++)
    {
        CvHit* hit = &s->hits[i];
        uint8_t* bytes;
        if (s->rebuild_queries) QueryTemplate(hit, entity);
        else CV_TRY(QueryDescriptor(s, hit, entity));
        CV_TRY(ReadHeld(s, held, hit->address, CV_HIT_SIZE, &bytes));
        if (s->rebuild_queries) TakeRebuilt(hit, bytes);
        else CV_TRY(cv_hit_take(hit, bytes, hit->count));
    }
    s->hit_count = CV_HITS;
    return 1;
}

/* ---- settings, mover, direction ---------------------------------------------------------------------------------- */

/* The effective settings record: the avatar's override, or the shared component record of its resource. */
static int VaultSettings(CvVault* s, const Chain* chain, uint32_t id, uint8_t** settings)
{
    uint32_t override = 0, index = 0;
    uintptr_t component;
    uint8_t* map;
    int found = cv_lookup(&s->guards, chain->manager + 0x547C70u, id, 64u, &override);
    if (found < 0) return found;
    if (found == 1 && override != CV_INVALID)
    {
        if (override >= 8) return cv_raise("Unsupported settings override");
        return Read(s, chain->manager + 0x547D24u + (uintptr_t)override * 0x354u, 852, 0, settings);
    }
    CV_TRY(cv_guard_pointer(&s->guards, chain->owner + 0xF12BB8u, 0, &component));
    CV_TRY(Read(s, component, 32, 0, &map));
    found = 0; /* this resource's two-slot map is verified, not assumed at index 0 */
    for (int slot = 0; slot < 2; slot++)
        if (memcmp(map + slot * 16, chain->entity_bytes, 8) == 0) { found = 1; index = cv_u32(map + slot * 16 + 8); }
    if (!found || index >= 1) return cv_raise("Unsupported AvatarComponent map");
    return Read(s, component + 32, 852, 0, settings);
}

/* The cosine of the settings' surface angle, in float32 steps. */
static int SurfaceThreshold(CvVault* s, const uint8_t* settings)
{
    double angle = cv_num(settings + 0x98);
    if (!(angle > 0 && angle < 90)) return cv_raise("Unsupported surface angle");
    s->normal_threshold = cv_f32(cos(cv_f32(angle * cv_f32(CV_PI / 180))));
    return 1;
}

/* Ground contact, the vault height it allows and the native mover position. */
static int MoverState(CvVault* s, const uint8_t* settings, const uint8_t* flags, const uint8_t* move)
{
    s->ground = (cv_u32(flags + 8) & 4u) == 0 && (cv_u32(flags + 12) & 0x26u) == 0 && move[15] == 0;
    s->max_height = cv_num(settings + (s->ground ? 0x104 : 0x108));
    if (!(s->max_height > 0 && s->max_height <= 3)) return cv_raise("Unsupported vault height");
    CV_TRY(cv_native_bind());
    s->ground_reach = cv_num(settings + 0x10C);
    CV_TRY(cv_native_mover_position(s->unit, s->mover_name, s->root));
    return cv_finite3(s->root) ? 1 : cv_raise("Mover position unavailable");
}

static int Normalize(const double* v, double* out)
{
    double length = cv_f32(sqrt(cv_f32(cv_f32(cv_f32(v[0] * v[0]) + cv_f32(v[1] * v[1])) + cv_f32(v[2] * v[2]))));
    if (length < 0.0001) return 0;
    for (int i = 0; i < 3; i++) out[i] = cv_f32(v[i] / length);
    return 1;
}

/* The horizontal camera direction, or the avatar's own motion direction while its movement flags select it (A6B790
 * chooses by this entity's bit 79). */
static int VaultDirection(CvVault* s, const Chain* chain, uint32_t id, const uint8_t* flags, const char** why)
{
    uintptr_t camera;
    uint8_t* bytes;
    double v[3];
    CV_TRY(Global(s, CV_RVA_CAMERA, 0, &camera));
    CV_TRY(Read(s, camera + 0x1C, 12, 0, &bytes));
    CV_TRY(cv_vector(bytes, v));
    v[2] = 0;
    int has = Normalize(v, s->direction);
    if (cv_u32(flags + 8) & 0x8000u)
    {
        CV_TRY(Read(s, chain->manager + (uintptr_t)chain->ai * CV_AVATAR_STRIDE + 0x53E15Cu, 4, 0, &bytes));
        if (cv_u32(bytes) != id) return cv_raise("Direction state identity mismatch");
        CV_TRY(Read(s, chain->manager + 0x150u + (uintptr_t)chain->ai * 0xA7AECu + 171698u * 4u, 12, 0, &bytes));
        CV_TRY(cv_vector(bytes, v));
        has = Normalize(v, s->direction);
    }
    return has ? 1 : cv_why(why, "waiting_for_direction");
}

/* ---- the snapshot ------------------------------------------------------------------------------------------------ */

static void Reset(CvVault* s)
{
    cv_guards_reset(&s->guards, &cv_vault_texts);
    s->stage = 0;
    s->controller = s->input_address = s->flags_address = s->entity = s->world = 0;
    s->manual_bytes = 0;
    s->manual = s->prior_step_report = s->rebuild_queries = s->reprojected = s->ground = s->has_min_height = 0;
    s->hit_count = 0;
    s->normal_threshold = s->max_height = s->min_height = s->ground_reach = 0;
}

/* Up to the batch: the avatar, the controller, its phase and query IDs (*epoch), the input and the movement flags. */
static int Front(CvVault* s, const CvVaultArgs* args, Chain* chain, uint8_t** epoch, uint8_t** flags, const char** why)
{
    uint8_t* bytes;
    if (args->avatar != NULL) CV_TRY(SlopeAvatar(s, args->avatar, chain));
    else CV_TRY(LocalAvatar(s, chain, why));
    uint32_t id = cv_u32(chain->entity_bytes + 8);
    s->controller = chain->manager + CV_AT_CONTROLLER + (uintptr_t)chain->ai * CV_AVATAR_STRIDE;
    CV_TRY(Read(s, s->controller + 0x2AC, 4, 1, &bytes));
    if (cv_u32(bytes) != id) return cv_raise("Controller identity mismatch");
    CV_TRY(Read(s, s->controller + 4, 44, 0, epoch));
    s->stage = cv_u32(*epoch);
    if (s->stage != 2 && s->stage != 3) return cv_why(why, "waiting_for_vault_query");
    int manual = ManualInput(s, chain);
    if (manual != 1) return manual == 0 ? cv_why(why, "waiting_for_manual_vault") : manual;
    return ControllerFlags(s, args->held, chain, flags, why);
}

int cv_vault_snapshot(CvVault* s, const CvVaultArgs* args, const char** why)
{
    Chain chain;
    Jobs jobs;
    uint8_t *epoch, *flags, *settings;
    CvMovement movement;
    memset(&chain, 0, sizeof chain);
    Reset(s);
    CV_TRY(Front(s, args, &chain, &epoch, &flags, why));
    uint32_t id = cv_u32(chain.entity_bytes + 8);
    CV_TRY(QueryScheduler(s, chain.manager, &jobs, why));
    CV_TRY(QueryRecords(s, epoch, &jobs, args->discovery, why));
    CV_TRY(ReadHits(s, args->held, chain.entity_bytes));
    CV_TRY(VaultSettings(s, &chain, id, &settings));
    CV_TRY(SurfaceThreshold(s, settings));
    CV_TRY(cv_movement(&s->guards, id, 1, &movement));
    s->unit = cv_u32(chain.entity_bytes + 12);
    s->mover_name = cv_u32(movement.mover + 76);
    CV_TRY(MoverState(s, settings, flags, movement.move));
    CV_TRY(VaultDirection(s, &chain, id, flags, why));
    s->entity = chain.entity;
    return 1;
}
