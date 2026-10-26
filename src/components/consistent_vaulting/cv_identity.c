/* Consistent Vaulting: the slope snapshot (slope_assist.lua A.snapshot): the local avatar's identity through light
 * reads, the kept identity of released-input checks, and the full snapshot of a press or a lease.
 *
 * Light reads. The identity chain and the input land in one reused arena; each read is recorded with its kind. A
 * snapshot that goes on past the light gate turns them into guards in read order: SLOPE ones into its own, VAULT ones
 * (EPOCH: also epoch guards) into the identity the vault snapshot of the same check takes over instead of reading the
 * chain again. The kinds match the guards the vault snapshot gives these reads itself.
 *
 * The kept identity. A snapshot without a key keeps where it found the local avatar (player manager, unit reference,
 * entity record and its bytes, avatar index, the registry's pointer). While the input stays released a check only
 * verifies it: the input at the kept index, the mission, the unit reference, the entity record and the registry slot,
 * 6 reads instead of 18. A difference, a press or a failed check resolves everything again. */
#include <math.h>
#include <string.h>
#include "cv.h"

#define SLOPE 1
#define VAULT 2
#define EPOCH 4
#define CHAIN (SLOPE | VAULT)
#define OWNED (SLOPE | VAULT | EPOCH)
#define LIGHT_SLOT 72   /* the largest light read is 0x44 bytes */
#define LIGHT_SLOTS 208 /* the most one snapshot can make: the player, two globals, maps of 1 + 128 and 1 + 64 rows ... */

static uint8_t g_arena[LIGHT_SLOTS][LIGHT_SLOT];
static uintptr_t g_address[LIGHT_SLOTS];
static uint8_t g_size[LIGHT_SLOTS], g_kind[LIGHT_SLOTS];
static int g_reads;

/* What the light reads found: the avatar's unit reference, ID and unit, owner and manager, its avatar index, the slot
 * and address of its entity record, the registry's pointer to it, and the player manager. */
static struct
{
    uint32_t ref, id, unit, ai;
    uintptr_t pm, owner, manager, address, registry;
    int entity;
} g_found;

/* The kept identity (kept), and whether the last snapshot replaced it with another (renewed). */
static struct
{
    int kept, renewed;
    uint32_t ref, ai;
    uintptr_t pm, owner, manager, address, registry;
    uint32_t entity[6];
} g_kept;

void cv_identity_reset(void)
{
    memset(&g_found, 0, sizeof g_found);
    memset(&g_kept, 0, sizeof g_kept);
    g_reads = 0;
}

int cv_identity_renewed(void)
{
    int renewed = g_kept.renewed;
    g_kept.renewed = 0;
    return renewed;
}

uintptr_t cv_identity_input(void) { return cv_input_address(g_found.manager, g_found.ai); }

/* ---- light reads ------------------------------------------------------------------------------------------------- */

static int LightRead(uintptr_t address, size_t size, int kind, int* slot)
{
    if (g_reads >= LIGHT_SLOTS) return cv_raise("Slope read budget exceeded");
    if (!cv_load(address, g_arena[g_reads], size)) return cv_raise("Slope data unavailable");
    g_address[g_reads] = address;
    g_size[g_reads] = (uint8_t)size;
    g_kind[g_reads] = (uint8_t)kind;
    *slot = g_reads++;
    return 1;
}

static uint32_t Word(int slot, uint32_t offset) { return cv_u32(g_arena[slot] + offset); }

static int LightPointer(int slot, uintptr_t* out)
{
    return cv_pointer(g_arena[slot], out) ? 1 : cv_raise("Slope pointer unavailable");
}

static int LightGlobal(uint32_t rva, int kind, uintptr_t* out)
{
    int slot;
    CV_TRY(LightRead(vpm_game() + rva, 8, kind, &slot));
    return LightPointer(slot, out);
}

static int LightRow(void* context, uintptr_t address, uint32_t* row)
{
    int slot;
    CV_TRY(LightRead(address, 8, CHAIN, &slot));
    memcpy(row, g_arena[slot], 8);
    return 1;
}

/* The value stored for id in the game hash map at address (header and rows recorded as CHAIN reads). */
static int LightLookup(uintptr_t address, uint32_t id, uint32_t limit, uint32_t* value)
{
    int header;
    CV_TRY(LightRead(address, 20, CHAIN, &header));
    CvMap map = {id, limit, LightRow, NULL, &cv_slope_texts};
    return cv_probe(&map, g_arena[header], value);
}

/* ---- the identity chain ------------------------------------------------------------------------------------------ */

/* 1 while a mission runs (the mode pointer and record). */
static int InMission(int* in_mission)
{
    uintptr_t mode;
    int slot;
    CV_TRY(LightGlobal(CV_RVA_MODE, CHAIN, &mode));
    CV_TRY(LightRead(mode, 0x44, CHAIN, &slot));
    *in_mission = Word(slot, 8) != 0 && Word(slot, 0x40) >= 1 && Word(slot, 0x40) <= 7;
    return 1;
}

/* The local player's unit reference while a mission runs. */
static int LocalRef(uint32_t* ref, const char** why)
{
    int in_mission = 0, counts, slot;
    uintptr_t pm, player;
    CV_TRY(InMission(&in_mission));
    if (!in_mission) return cv_why(why, "outside_mission");
    CV_TRY(LightGlobal(VPM_RVA_PLAYER_MANAGER, OWNED, &pm));
    CV_TRY(LightRead(pm + 0x84, 8, VAULT, &counts));
    if (Word(counts, 0) > 4 || Word(counts, 4) > 4) return cv_raise("Unsupported player count");
    if (Word(counts, 0) == 0 || Word(counts, 4) == 0) return cv_why(why, "no_local_avatar");
    CV_TRY(LightRead(pm + 0xE8, 8, OWNED, &slot));
    CV_TRY(LightPointer(slot, &player));
    CV_TRY(LightRead(player, 24, OWNED, &slot));
    if ((g_arena[slot][20] & 1) == 0) return cv_why(why, "no_local_avatar");
    g_found.pm = pm;
    CV_TRY(LightRead(pm + 0x3A8, 4, OWNED, &slot));
    *ref = Word(slot, 0);
    return 1;
}

#define AVATAR_LOW 0x294DFA97u /* the avatar resource 0x4d1c334d294dfa97 */
#define AVATAR_HIGH 0x4D1C334Du

/* The avatar entity of ref: its slot. */
static int AvatarEntity(const CvKey* key, uintptr_t owner, uint32_t ref, int* entity, const char** why)
{
    uint32_t ei = 0;
    int found = LightLookup(owner + 0xF22EC8u, ref, 1048576u, &ei);
    if (found < 0) return found;
    if (found == 0 || ei == CV_INVALID) return cv_why(why, "gone");
    if (ei >= 262144u) return cv_raise("Unsupported entity index");
    uintptr_t address = owner + 0xF32F18u + (uintptr_t)ei * 24u;
    CV_TRY(LightRead(address, 24, OWNED, entity));
    if (Word(*entity, 0) != AVATAR_LOW || Word(*entity, 4) != AVATAR_HIGH) return cv_why(why, "gone");
    if (key != NULL && (key->id != Word(*entity, 8) || key->unit != Word(*entity, 12))) return cv_why(why, "gone");
    if (key == NULL && (g_arena[*entity][20] & 1) == 0) return cv_why(why, "no_local_avatar");
    g_found.entity = *entity;
    g_found.address = address;
    return 1;
}

/* The avatar index of id, checked against the avatar count and the registry: 1, 0 absent. */
static int AvatarIndex(uintptr_t manager, uint32_t id, int entity, uint32_t* ai)
{
    int count, slot;
    int found = LightLookup(manager + 0xF8u, id, 64u, ai);
    if (found != 1 || *ai == CV_INVALID) return found < 0 ? found : 0;
    CV_TRY(LightRead(manager + 0x6Cu, 4, VAULT, &count));
    if (!(*ai < Word(count, 0) && *ai < 8)) return cv_raise("Unsupported avatar index");
    CV_TRY(LightRead(manager + 0x110u + (uintptr_t)*ai * 8u, 8, OWNED, &slot));
    CV_TRY(LightPointer(slot, &g_found.registry));
    CV_TRY(LightRead(g_found.registry, 24, OWNED, &slot));
    if (memcmp(g_arena[slot], g_arena[entity], 24) != 0) return cv_raise("Avatar registry mismatch");
    return 1;
}

/* Resolves the local avatar, or with a saved key that same avatar (cleanup only: it can find the original avatar after
 * registry compaction or a local-player switch, never grant a new lease). */
static int Identify(const CvKey* key, const char** why)
{
    uint32_t ref = 0, ai = 0;
    uintptr_t owner, manager;
    int entity;
    if (key != NULL) ref = key->ref;
    else CV_TRY(LocalRef(&ref, why));
    if (ref == 0x7FFFu) return cv_why(why, "gone");
    CV_TRY(LightGlobal(VPM_RVA_ENTITY_OWNER, OWNED, &owner));
    CV_TRY(LightGlobal(VPM_RVA_AVATAR_MANAGER, OWNED, &manager));
    if (key != NULL && (owner != key->owner || manager != key->manager)) return cv_why(why, "gone");
    CV_TRY(AvatarEntity(key, owner, ref, &entity, why));
    int found = AvatarIndex(manager, Word(entity, 8), entity, &ai);
    if (found != 1) return found == 0 ? cv_why(why, "gone") : found;
    g_found.ref = ref;
    g_found.id = Word(entity, 8);
    g_found.unit = Word(entity, 12);
    g_found.owner = owner;
    g_found.manager = manager;
    g_found.ai = ai;
    return 1;
}

/* ---- the kept identity ------------------------------------------------------------------------------------------- */

static int KeptMatches(void)
{
    if (!g_kept.kept || g_found.pm != g_kept.pm || g_found.ref != g_kept.ref || g_found.owner != g_kept.owner ||
        g_found.manager != g_kept.manager || g_found.ai != g_kept.ai || g_found.address != g_kept.address ||
        g_found.registry != g_kept.registry)
        return 0;
    return memcmp(g_arena[g_found.entity], g_kept.entity, 24) == 0;
}

static void KeepIdentity(void)
{
    g_kept.renewed = g_kept.kept && !KeptMatches();
    g_kept.pm = g_found.pm;
    g_kept.ref = g_found.ref;
    g_kept.owner = g_found.owner;
    g_kept.manager = g_found.manager;
    g_kept.ai = g_found.ai;
    g_kept.address = g_found.address;
    g_kept.registry = g_found.registry;
    memcpy(g_kept.entity, g_arena[g_found.entity], 24);
    g_kept.kept = 1;
}

/* 1 when the kept identity holds, 0 with *why outside a mission, 2 when the chain must be resolved. */
static int VerifyIdentity(const char** why)
{
    int in_mission = 0, slot, entity;
    CV_TRY(InMission(&in_mission));
    if (!in_mission) { g_kept.kept = 0; return cv_why(why, "outside_mission"); }
    CV_TRY(LightRead(g_kept.pm + 0x3A8u, 4, OWNED, &slot));
    if (Word(slot, 0) != g_kept.ref) return 2;
    CV_TRY(LightRead(g_kept.address, 24, OWNED, &entity));
    if (memcmp(g_arena[entity], g_kept.entity, 24) != 0) return 2;
    CV_TRY(LightRead(g_kept.manager + 0x110u + (uintptr_t)g_kept.ai * 8u, 8, OWNED, &slot));
    if (cv_u64(g_arena[slot]) != (uint64_t)g_kept.registry) return 2;
    g_found.ref = g_kept.ref;
    g_found.id = g_kept.entity[2];
    g_found.unit = g_kept.entity[3];
    g_found.owner = g_kept.owner;
    g_found.manager = g_kept.manager;
    g_found.ai = g_kept.ai;
    g_found.entity = entity;
    g_found.address = g_kept.address;
    return 1;
}

/* The input is released (a light read). */
static int Released(int* released)
{
    int slot;
    CV_TRY(LightRead(cv_identity_input(), 1, SLOPE, &slot));
    *released = g_arena[slot][0] == 0;
    return 1;
}

static uintptr_t VaultPhase(void)
{
    return g_found.manager + CV_AT_CONTROLLER + (uintptr_t)g_found.ai * CV_AVATAR_STRIDE + 4;
}

static int Idle(CvSlope* s, uintptr_t vault_phase)
{
    s->idle = 1;
    s->manual = 0;
    s->vault_phase = vault_phase;
    return 1;
}

/* An idle check through the kept identity: the input first, at the kept index (a press resolves the whole chain
 * anyway). 1 idle, 0 with *why outside a mission, 2 to resolve the chain. */
static int KeptIdle(CvSlope* s, const char** why)
{
    int released = 0;
    g_found.manager = g_kept.manager;
    g_found.ai = g_kept.ai;
    CV_TRY(Released(&released));
    if (!released) return 2;
    int found = VerifyIdentity(why);
    if (found != 1) return found;
    return Idle(s, VaultPhase());
}

/* The snapshot goes on past the light gate: its light reads become guards in read order. */
static int Adopt(CvSlope* s, uintptr_t vault_phase)
{
    cv_guards_reset(&s->guards, &cv_slope_texts);
    cv_guards_reset(&s->identity, &cv_slope_texts);
    for (int slot = 0; slot < g_reads; slot++)
    {
        int kind = g_kind[slot];
        if ((kind & SLOPE) && cv_guard_add(&s->guards, g_address[slot], g_arena[slot], g_size[slot], 0) == NULL)
            return cv_raise("Slope read budget exceeded");
        if ((kind & VAULT) && cv_guard_add(&s->identity, g_address[slot], g_arena[slot], g_size[slot], kind & EPOCH) == NULL)
            return cv_raise("Slope read budget exceeded");
    }
    s->idle = 0;
    s->manual = 0;
    s->entity = g_found.address;
    s->ai = g_found.ai;
    s->vault_phase = vault_phase;
    s->key.ref = g_found.ref;
    s->key.id = g_found.id;
    s->key.unit = g_found.unit;
    s->key.owner = g_found.owner;
    s->key.manager = g_found.manager;
    memcpy(s->entity_bytes, g_arena[g_found.entity], 24);
    return 1;
}

/* ---- the full snapshot ------------------------------------------------------------------------------------------- */

static int Read(CvSlope* s, uintptr_t address, size_t size, uint8_t** bytes)
{
    return cv_guard_read(&s->guards, address, size, 0, bytes);
}

static int Pointer(CvSlope* s, uintptr_t address, uintptr_t* out) { return cv_guard_pointer(&s->guards, address, 0, out); }

static int Near(double value, double expected) { return fabs(value - expected) < 0.001; }

/* The mover's handle pool entry, verified: its record (32 bytes). */
static int MoverRecord(CvSlope* s, uint32_t handle, uint8_t** record)
{
    uintptr_t pool, records;
    uint8_t *h, *bytes;
    CV_TRY(Pointer(s, vpm_exe() + 0x27C3298u + (uintptr_t)(handle >> 30) * 0x810u, &pool));
    CV_TRY(Read(s, pool, 56, &h));
    int32_t index = (int32_t)(handle & cv_u32(h + 40));
    if (!(index >= 0 && (uint32_t)index < cv_u32(h + 36) && (handle & cv_u32(h + 52)) != 0)) return cv_raise("Invalid mover handle");
    uint32_t layout = cv_u32(h + 28);
    if (!cv_pointer(h, &records)) return cv_raise("Slope pointer unavailable");
    uintptr_t start = records + (uintptr_t)index * (layout & 65535u);
    CV_TRY(Read(s, start + ((layout >> 16) & 255u), 4, &bytes));
    if (cv_u32(bytes) != handle) return cv_raise("Reused mover handle");
    CV_TRY(Read(s, start + (layout >> 24), 32, record));
    return cv_u32(*record + 8) == s->key.unit ? 1 : cv_raise("Mover belongs to another unit");
}

/* The mover's character controller object, verified through the handle pool, the mover record and the shared mover
 * definition; the separate 70-degree support and drop limit stays as it is. */
static int ControllerObject(CvSlope* s, const uint8_t* mover)
{
    uintptr_t definition, object, vtable;
    uint8_t *record, *def, *bytes;
    double up[3];
    s->handle = cv_u32(mover + 88);
    CV_TRY(MoverRecord(s, s->handle, &record));
    if (!cv_pointer(record + 16, &definition) || !cv_pointer(record + 24, &object)) return cv_raise("Slope pointer unavailable");
    CV_TRY(Read(s, definition, 28, &def));
    if (cv_u32(def) != cv_u32(mover + 76)) return cv_raise("Mover name mismatch");
    CV_TRY(Pointer(s, object, &vtable));
    if (vtable != vpm_exe() + 0x16A16D8u) return cv_raise("Unsupported character controller");
    CV_TRY(Read(s, object + 80, 12, &bytes));
    for (int i = 0; i < 3; i++) up[i] = cv_num(bytes + i * 4);
    if (!(fabs(up[0]) + fabs(up[1]) + fabs(up[2] - 1) < 0.001)) return cv_raise("Unsupported up vector");
    if (!(Near(cv_num(def + 20), 50 * CV_PI / 180) && Near(cv_num(def + 24), 70 * CV_PI / 180)))
        return cv_raise("Unsupported mover definition");
    CV_TRY(Read(s, object + 100, 4, &bytes));
    if (!Near(cv_num(bytes), cos(70 * CV_PI / 180))) return cv_raise("Unsupported support filter");
    s->object = object;
    return 1;
}

/* Only the span an assist uses is read: walking speed (+12) through ground climb height (+260), 252 of 852 bytes. */
#define SETTINGS_FROM 12u
#define SETTINGS_SIZE 252u

/* The effective settings record: the avatar's own override, whose angle and height cells an assist may write, or the
 * shared component record. */
static int SettingsRecord(CvSlope* s, uint8_t* settings)
{
    uint32_t oi = 0;
    uintptr_t component;
    uint8_t* map;
    int found = cv_lookup(&s->guards, s->key.manager + 0x547C70u, s->key.id, 64u, &oi);
    if (found < 0) return found;
    if (found == 1 && oi != CV_INVALID)
    {
        if (oi >= 8) return cv_raise("Unsupported avatar override");
        uintptr_t base = s->key.manager + 0x547D24u + (uintptr_t)oi * 852u;
        if (!cv_load(base + SETTINGS_FROM, settings, SETTINGS_SIZE)) return cv_raise("Slope data unavailable");
        s->cells[CV_ENTER] = base + 152;
        s->cells[CV_EXIT] = base + 172;
        s->cells[CV_HEIGHT] = base + 260;
        return 1;
    }
    CV_TRY(Pointer(s, s->key.owner + 0xF12BB8u, &component));
    CV_TRY(Read(s, component, 32, &map));
    found = 0;
    for (int i = 0; i < 2; i++)
        if (memcmp(map + i * 16, s->entity_bytes, 8) == 0 && cv_u32(map + i * 16 + 8) == 0) found = 1;
    if (!found) return cv_raise("Unsupported avatar resource map");
    return cv_load(component + 32 + SETTINGS_FROM, settings, SETTINGS_SIZE) ? 1 : cv_raise("Slope data unavailable");
}

/* The settings an assist checks and the current bytes of every cell it may write. */
static int SettingsValues(CvSlope* s, const uint8_t* settings)
{
    uint8_t* bytes;
    CV_TRY(Read(s, s->key.manager + 0x547D20u, 4, &bytes));
    s->override_count = cv_u32(bytes); /* the native allocation has a fixed eight-record capacity in this build */
    if (s->override_count > 8) return cv_raise("Unsupported override count");
    s->walk = cv_num(settings + 0);
    s->enter = cv_num(settings + 152 - SETTINGS_FROM);
    s->exit = cv_num(settings + 172 - SETTINGS_FROM);
    s->ground_max = cv_num(settings + 260 - SETTINGS_FROM);
    if (!(cv_finite(s->walk) && s->walk > 0 && s->walk <= 10)) return cv_raise("Unsupported walking speed");
    if (!cv_load(s->cells[CV_CAP], s->values[CV_CAP], 4) || !cv_load(s->cells[CV_SLOPE], s->values[CV_SLOPE], 4))
        return cv_raise("Slope data unavailable");
    s->has_value[CV_CAP] = s->has_value[CV_SLOPE] = 1;
    if (s->cells[CV_ENTER] == 0) return 1;
    memcpy(s->values[CV_ENTER], settings + 152 - SETTINGS_FROM, 4);
    memcpy(s->values[CV_EXIT], settings + 172 - SETTINGS_FROM, 4);
    memcpy(s->values[CV_HEIGHT], settings + 260 - SETTINGS_FROM, 4);
    s->has_value[CV_ENTER] = s->has_value[CV_EXIT] = s->has_value[CV_HEIGHT] = 1;
    return 1;
}

static int Eligible(const uint8_t* flags)
{
    return (cv_u32(flags) & 2u) != 0 && (cv_u32(flags) & 0x404000u) == 0 && (cv_u32(flags + 4) & 0x8000000u) == 0 &&
        (cv_u32(flags + 8) & 0x20084000u) == 0 && (cv_u32(flags + 12) & 0x5181Cu) == 0 && (cv_u32(flags + 16) & 9u) == 0;
}

/* The input, movement flags, ground contact and the native mover position. */
static int Motion(CvSlope* s, const uint8_t* move)
{
    uint8_t *input, *flags;
    double n[3];
    CV_TRY(Read(s, cv_input_address(s->key.manager, s->ai), 1, &input));
    s->manual = input[0] != 0;
    CV_TRY(Read(s, s->key.manager + CV_AT_FLAGS + (uintptr_t)s->ai * CV_AVATAR_STRIDE, 24, &flags));
    s->climbing = (cv_u32(flags + 12) & 0x200u) != 0;
    s->eligible = Eligible(flags);
    s->ground = (cv_u32(flags + 8) & 4u) == 0 && (cv_u32(flags + 12) & 0x26u) == 0 && move[15] == 0 && move[12] == 0;
    for (int i = 0; i < 3; i++) n[i] = cv_num(move + 20 + i * 4);
    double length = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    s->normal_z = cv_finite(length) && length > 0.99 && length < 1.01 ? n[2] / length : -1;
    CV_TRY(cv_native_bind());
    CV_TRY(cv_native_mover_position(s->key.unit, s->mover_name, s->root));
    return cv_finite3(s->root) ? 1 : cv_raise("Invalid mover position");
}

static void ClearCells(CvSlope* s)
{
    memset(s->cells, 0, sizeof s->cells);
    memset(s->has_value, 0, sizeof s->has_value);
    s->manual = s->climbing = s->eligible = s->ground = 0;
}

/* Past the light gate: the controller and direction identities, the mover records and object, the settings and, without
 * a key, the motion. */
static int Full(CvSlope* s, const CvKey* key)
{
    uint8_t *bytes, settings[SETTINGS_SIZE];
    CvMovement movement;
    uintptr_t manager = s->key.manager, row = (uintptr_t)s->ai * CV_AVATAR_STRIDE;
    ClearCells(s);
    CV_TRY(Read(s, manager + CV_AT_CONTROLLER + row + 0x2AC, 4, &bytes));
    if (cv_u32(bytes) != s->key.id) return cv_raise("Vault identity mismatch");
    uintptr_t direction = manager + CV_AT_DIRECTION + row;
    CV_TRY(Read(s, direction + 40, 4, &bytes));
    if (cv_u32(bytes) != s->key.id) return cv_raise("Movement direction identity mismatch");
    CV_TRY(cv_movement(&s->guards, s->key.id, 0, &movement));
    CV_TRY(Read(s, movement.mover_address + 76, 16, &bytes));
    CV_TRY(ControllerObject(s, movement.mover));
    s->manager = manager;
    s->mover_name = cv_u32(movement.mover + 76);
    s->cells[CV_CAP] = direction + 8;
    s->cells[CV_SLOPE] = s->object + 96;
    CV_TRY(SettingsRecord(s, settings));
    CV_TRY(SettingsValues(s, settings));
    return key != NULL ? 1 : Motion(s, movement.move);
}

int cv_slope_snapshot(CvSlope* s, const CvKey* key, int light, int verify, const char** why)
{
    int released = 0;
    g_reads = 0;
    if (verify && key == NULL && g_kept.kept)
    {
        int idle = KeptIdle(s, why);
        if (idle != 2) return idle;
        g_reads = 0;
    }
    int found = Identify(key, why);
    if (found == CV_RAISED) return found;
    if (key == NULL)
    {
        if (found == 1) KeepIdentity();
        else g_kept.kept = g_kept.renewed = 0;
    }
    if (found != 1) return found;
    uintptr_t vault_phase = VaultPhase();
    /* With no lease and the input released, the step uses only the input state: the mover, controller, settings and
     * flags are read and validated in full as soon as the input is pressed, and on every lease check. */
    if (light && key == NULL)
    {
        CV_TRY(Released(&released));
        if (released) return Idle(s, vault_phase);
    }
    CV_TRY(Adopt(s, vault_phase));
    return Full(s, key);
}

int cv_slope_guarded(const CvSlope* s) { return cv_guards_hold(&s->guards, 0); }
