/* Shallow Water Diving: the snapshot of the local avatar's dive (dive_data.lua M.snapshot, M.idle and the guards), for
 * build 25480438.
 *
 * The local avatar is resolved as the Lua resolved it: mission record, player manager (counts, player record and unit,
 * one read), entity-owner map, entity record, avatar registry (count, map and pointers, one read) and the registry's
 * record, which must be the same entity; then its dive controller (the dive record +0xB84 and state flags +0xF80, one
 * read). On a dive frame it also reads the Drownable runtime record (validated against the same entity), the stance,
 * the root's height and the Drownable settings (component table 309 of the entity owner, through the pointer the game
 * reads: a HellForge copy of that table is followed like the vanilla one), and verifies the game.dll constants once per
 * session. The core's vpm_local_avatar is not used: it reads the chain in other pieces, probes at most 64 rows where the
 * Lua probes 128, answers unsupported records as "none" where the Lua stops with an error, and keeps no guards.
 *
 * Every read lands in one static arena (8-byte aligned) and is remembered as a guard (address, arena offset, size,
 * identity): the coherence check before a write reads every guard again, and a lease keeps the identity guards to
 * recognise its record when it restores. game.dll's globals and constants are plain loads (guards too, read again as
 * plain loads); everything else is HfApi.read. Nothing allocates. */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"
#include "dive_data.h"

#define RVA_MISSION 0x33266A0u
#define RVA_PLAYERS 0x3326468u
#define RVA_ENTITIES 0x346BF98u
#define RVA_AVATARS 0x3326D20u
#define RVA_DROWNABLE 0x3326A80u
#define RVA_STANCES 0x3326598u
#define RVA_MOVEMENT 0x3326558u
/* game.dll read-only data: the 2.0 s dive timeout (build 25480438 shifted this block by 0x10 but left the timeout's
 * reader at its old address by mistake: the exact 2.0 is the gate, the old address a fallback), the prone and crouch
 * stance offsets. */
#define RVA_TIMEOUT 0x23C7110u
#define RVA_TIMEOUT_OLD 0x23C7100u
#define RVA_TIMEOUT_WINDOW 0x23C7080u
#define TIMEOUT_WINDOW 0x100u
#define RVA_PRONE 0x23C6CCCu
#define RVA_CROUCH 0x23C69F8u
#define TIMEOUT_BITS 0x40000000u  /* 2.0f */
#define PRONE_BITS 0x3F666666u    /* 0.9f */
#define CROUCH_BITS 0x3ECCCCCDu   /* 0.4f */
#define BASE_BITS 0xBFA66666u     /* -1.3f: the Drownable setting */
#define SETTINGS_NODE 0x4A182741u /* the Drownable setting's node hash */
#define AVATAR_LOW 0x294DFA97u    /* the avatar entity resource '\x97\xfa\x4d\x29\x4d\x33\x1c\x4d' */
#define AVATAR_HIGH 0x4D1C334Du
#define CONTROLLER 0xB84u         /* the dive record in the dive controller */
#define CONTROLLER_SIZE 0x414
#define FLAGS (0xF80 - 0xB84)     /* the state flags, from the dive record */
#define SETTINGS_SLOTS 122
#define SETTINGS_RECORD 64
#define ARENA 16384
#define GUARDS 1024
#define IDENTITY_BYTES 24         /* the largest identity guard: an entity record */
#define NONE (-1)
#define FOUND 1
#define ABSENT 0
#define WAITING (-1)

typedef struct Stage { const char* read; const char* pointer; const char* invalid; int no_avatar; } Stage;
static const Stage kMission = {"waiting_for_mission_read", "waiting_for_mission_pointer", "Invalid mission pointer", 1};
static const Stage kLocalPlayer = {"waiting_for_local_player_read", "waiting_for_local_player_pointer",
    "Invalid local_player pointer", 1};
static const Stage kLocalAvatar = {"waiting_for_local_avatar_read", "waiting_for_local_avatar_pointer",
    "Invalid local_avatar pointer", 1};
static const Stage kWater = {"waiting_for_water_read", "waiting_for_water_pointer", "Invalid water pointer", 0};
static const Stage kStance = {"waiting_for_stance_read", "waiting_for_stance_pointer", "Invalid stance pointer", 0};
static const Stage kMovement = {"waiting_for_movement_read", "waiting_for_movement_pointer", "Invalid movement pointer", 0};
static const Stage kWaterSettings = {"waiting_for_water_settings_read", "waiting_for_water_settings_pointer",
    "Invalid water_settings pointer", 0};

typedef struct SnapGuard { uintptr_t address; int offset, size; uint8_t identity, image; } SnapGuard;
typedef struct SnapIdentity { uintptr_t address; int size; uint8_t image; uint8_t bytes[IDENTITY_BYTES]; } SnapIdentity;

/* The chain one snapshot follows, between its stages. */
typedef struct Chain
{
    uintptr_t owner, am, entity_address;
    uint32_t unit, id, ai;
    int entity;                  /* the entity record's arena offset */
} Chain;

SwdSnapshot swd_snap;

static _Alignas(8) uint8_t g_arena[ARENA];
static uint8_t g_recheck[4096];
static SnapGuard g_guards[GUARDS];
static SnapIdentity g_identity[GUARDS]; /* a lease's identity guards (static: 40 KB) */
static int g_identityCount;

/* The running snapshot: the stage, why the last helper stopped, and the arena bytes and guards used so far. */
static struct
{
    const Stage* stage;
    const char* wait;
    int wait_no_avatar;
    int used, guards;
    int failed;
    char error[256];
} r;

void swd_snapshot_reset(void)
{
    memset(&r, 0, sizeof r);
    memset(&swd_snap, 0, sizeof swd_snap);
    g_identityCount = 0;
}

const char* swd_error(void) { return r.error; }
int swd_no_avatar(const char* reason) { return reason != NULL && reason == r.wait && r.wait_no_avatar; }

static uint32_t Word(int o) { uint32_t v; memcpy(&v, g_arena + o, 4); return v; }
static float Real(int o) { float v; memcpy(&v, g_arena + o, 4); return v; }
static int Finite(double n) { return n > -100000.0 && n < 100000.0; }

/* A waiting reason (the stage's, or a stage-specific one): NONE, so a helper can return it. */
static int Waited(const char* why)
{
    r.wait = why;
    r.wait_no_avatar = r.stage->no_avatar;
    return NONE;
}

/* What the Lua's asserts raised: the first one is kept, and every later read is refused. */
static int Refused(const char* message)
{
    if (!r.failed) snprintf(r.error, sizeof r.error, "%s", message);
    r.failed = 1;
    return NONE;
}

/* For the stage functions, which answer 1 (go on) or 0 (stop: waiting or failed). */
static int StageWait(const char* why) { Waited(why); return 0; }
static int StageFail(const char* message) { Refused(message); return 0; }

static void SnapGuardAdd(uintptr_t address, int o, int size, int identity, int image)
{
    if (r.guards >= GUARDS) { Refused("Too many snapshot guards"); return; }
    g_guards[r.guards++] = (SnapGuard){address, o, size, (uint8_t)identity, (uint8_t)image};
}

/* Room for size bytes in the arena: its offset, or NONE. */
static int SnapReserve(int size)
{
    if (r.failed) return NONE;
    if (r.used + size > ARENA) return Refused("Snapshot exceeds its buffer");
    return r.used;
}

static void SnapAdvance(int o, int size) { r.used = o + size + ((-size) & 7); }

/* One heap read without a guard (the caller guards the records it uses): its offset, or NONE. */
static int SnapFetch(uintptr_t address, int size)
{
    int o = SnapReserve(size);
    if (o == NONE) return NONE;
    if (!vpm_read(address, g_arena + o, (size_t)size)) return Waited(r.stage->read);
    SnapAdvance(o, size);
    return o;
}

static int SnapRead(uintptr_t address, int size, int identity)
{
    int o = SnapFetch(address, size);
    if (o != NONE) SnapGuardAdd(address, o, size, identity, 0);
    return o;
}

/* game.dll's data, a plain load (the Lua's api.read of the image), guarded. */
static int SnapImage(uint32_t rva, int size, int identity)
{
    int o = SnapReserve(size);
    if (o == NONE) return NONE;
    if (!vpm_game_read(rva, g_arena + o, (size_t)size)) return Waited(r.stage->read);
    SnapAdvance(o, size);
    SnapGuardAdd(vpm_game() + rva, o, size, identity, 1);
    return o;
}

/* The pointer at an arena offset: 0 (waiting) when null, 0 (failed) when it cannot be one. */
static uintptr_t SnapPointer(int o)
{
    uint64_t p = (uint64_t)Word(o + 4) << 32 | Word(o);
    if (p == 0) { Waited(r.stage->pointer); return 0; }
    if (p < 0x10000ull || p >= 0x800000000000ull) { Refused(r.stage->invalid); return 0; }
    return (uintptr_t)p;
}

static uintptr_t SnapGlobal(uint32_t rva, const char* why, int identity)
{
    int o = SnapImage(rva, 8, identity);
    if (o == NONE) return 0;
    if (Word(o) == 0 && Word(o + 4) == 0) { Waited(why); return 0; }
    return SnapPointer(o);
}

/* The game's hash lookup on a header in the arena: FOUND (*index), ABSENT, or WAITING (also when it failed). The low 32
 * bits of key * multiplier, probed linearly, at most 128 rows. */
static int SnapLookup(int header, uint32_t key, uint32_t limit, int identity, uint32_t* index)
{
    uint32_t capacity = Word(header + 8), empty = Word(header + 12), multiplier = Word(header + 16);
    if (capacity == 0) return ABSENT;
    if (capacity > limit || (capacity & (capacity - 1)) != 0) { Refused("Unsupported map"); return WAITING; }
    uintptr_t rows = SnapPointer(header);
    if (rows == 0) return WAITING;
    uint32_t product = key * multiplier;
    uint32_t probes = capacity < 128 ? capacity : 128;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        int row = SnapRead(rows + (uintptr_t)((product + probe) & (capacity - 1)) * 8u, 8, identity);
        if (row == NONE) return WAITING;
        if (Word(row) == key) { *index = Word(row + 4); return FOUND; }
        if (Word(row) == empty) return ABSENT;
    }
    return ABSENT;
}

/* ---- the stages ------------------------------------------------------------------------------------------------- */

static int SnapMission(void)
{
    r.stage = &kMission;
    uintptr_t mode = SnapGlobal(RVA_MISSION, "waiting_for_mission_global_33266a0", 0);
    if (mode == 0) return 0;
    int m = SnapRead(mode, 0x44, 0);
    if (m == NONE) return 0;
    if (Word(m + 8) == 0 || Word(m + 0x40) < 1 || Word(m + 0x40) > 7) return StageWait("waiting_for_mission");
    return 1;
}

/* Player counts (+0x84), player pointer (+0xE8) and unit (+0x3A8), one read. */
static int SnapPlayer(Chain* c)
{
    r.stage = &kLocalPlayer;
    uintptr_t pm = SnapGlobal(RVA_PLAYERS, "waiting_for_local_player_global_3326468", 0);
    if (pm == 0) return 0;
    int p = SnapFetch(pm + 0x84, 0x328);
    if (p == NONE) return 0;
    SnapGuardAdd(pm + 0x84, p, 8, 0, 0);
    if (Word(p) > 4 || Word(p + 4) > 4) return StageFail("Unsupported player count");
    if (Word(p) == 0 || Word(p + 4) == 0) return StageWait("waiting_for_local_player");
    SnapGuardAdd(pm + 0xE8, p + 0x64, 8, 0, 0);
    uintptr_t player = SnapPointer(p + 0x64);
    if (player == 0) return 0;
    int record = SnapRead(player, 24, 0);
    if (record == NONE) return 0;
    if ((g_arena[record + 20] & 1) == 0) return StageWait("waiting_for_local_player");
    SnapGuardAdd(pm + 0x3A8, p + 0x324, 4, 0, 0);
    c->unit = Word(p + 0x324);
    if (c->unit == 0x7FFF) return StageWait("waiting_for_local_avatar");
    return 1;
}

/* The unit's entity record through the entity owner's map. */
static int SnapEntity(Chain* c)
{
    r.stage = &kLocalAvatar;
    c->owner = SnapGlobal(RVA_ENTITIES, "waiting_for_local_avatar_global_346bf98", 1);
    if (c->owner == 0) return 0;
    int header = SnapRead(c->owner + 0xF22EC8, 20, 0);
    if (header == NONE) return 0;
    uint32_t ei = 0;
    int found = SnapLookup(header, c->unit, 1048576u, 0, &ei);
    if (found == WAITING) return 0;
    if (found == ABSENT || ei == 0xFFFFFFFFu) return StageWait("waiting_for_local_avatar");
    if (ei >= 262144u) return StageFail("Unsupported entity index");
    c->entity_address = c->owner + 0xF32F18 + (uintptr_t)ei * 24u;
    c->entity = SnapRead(c->entity_address, 24, 1);
    if (c->entity == NONE) return 0;
    if (Word(c->entity) != AVATAR_LOW || Word(c->entity + 4) != AVATAR_HIGH) return StageFail("Unsupported avatar resource");
    if ((g_arena[c->entity + 20] & 1) == 0) return StageWait("waiting_for_local_avatar");
    c->id = Word(c->entity + 8);
    return 1;
}

/* Avatar count (+0x6C), map header (+0xF8) and registry (+0x110), one read; the registry's record is the entity's. */
static int SnapRegistry(Chain* c)
{
    c->am = SnapGlobal(RVA_AVATARS, "waiting_for_local_avatar_global_3326d20", 1);
    if (c->am == 0) return 0;
    int a = SnapFetch(c->am + 0x6C, 0xE4);
    if (a == NONE) return 0;
    SnapGuardAdd(c->am + 0xF8, a + 0x8C, 20, 0, 0);
    int found = SnapLookup(a + 0x8C, c->id, 64u, 0, &c->ai);
    if (found == WAITING) return 0;
    if (found == ABSENT || c->ai == 0xFFFFFFFFu) return StageWait("waiting_for_local_avatar");
    SnapGuardAdd(c->am + 0x6C, a, 4, 0, 0);
    uint32_t count = Word(a);
    if (count == 0) return StageWait("waiting_for_local_avatar");
    if (count > 8 || c->ai >= count) return StageFail("Unsupported avatar index");
    int slot = a + 0xA4 + (int)c->ai * 8;
    SnapGuardAdd(c->am + 0x110 + (uintptr_t)c->ai * 8u, slot, 8, 1, 0);
    uintptr_t registered = SnapPointer(slot);
    if (registered == 0) return 0;
    int record = SnapRead(registered, 24, 1);
    if (record == NONE) return 0;
    if (memcmp(g_arena + record, g_arena + c->entity, 24) != 0) return StageFail("Avatar registry mismatch");
    return 1;
}

/* The dive controller: the dive record (+0xB84) and state flags (+0xF80), one read. */
static int SnapController(const Chain* c)
{
    uintptr_t controller = c->am + 0x53D900 + (uintptr_t)c->ai * 0x1238u;
    int o = SnapFetch(controller + CONTROLLER, CONTROLLER_SIZE);
    if (o == NONE) return 0;
    SnapGuardAdd(controller + CONTROLLER, o, 20, 0, 0);
    SnapGuardAdd(controller + 0xF80, o + FLAGS, 24, 0, 0);
    if (Word(o) != c->id) return StageFail("Dive controller identity mismatch");
    SwdSnapshot* s = &swd_snap;
    s->dive = (Word(o + FLAGS + 12) & 0x20u) != 0;
    s->swim = (Word(o + FLAGS + 8) & 0x80000000u) != 0;
    s->ragdoll = (Word(o + FLAGS + 12) & 0x10u) != 0;
    s->elapsed = Real(o + 8);
    s->landing = Real(o + 12);
    s->key = c->entity_address;
    memcpy(s->entity, g_arena + c->entity, 24);
    s->controller = controller;
    s->id = c->id;
    return 1;
}

/* The Drownable manager's record for the avatar id: record capacity (+8), map header (+32) and the owner, data and
 * enabled pointers (+56, +64, +72), one read. *d: its arena offset. */
static int SnapWaterIndex(const Chain* c, uintptr_t* dm, int* d, uint32_t* di)
{
    r.stage = &kWater;
    *dm = SnapGlobal(RVA_DROWNABLE, "waiting_for_water_global_3326a80", 1);
    if (*dm == 0) return 0;
    *d = SnapFetch(*dm + 8, 72);
    if (*d == NONE) return 0;
    SnapGuardAdd(*dm + 32, *d + 24, 20, 1, 0);
    int found = SnapLookup(*d + 24, c->id, 32768u, 1, di);
    if (found == WAITING) return 0;
    SnapGuardAdd(*dm + 8, *d, 4, 0, 0);
    uint32_t capacity = Word(*d);
    if (found == ABSENT || *di == 0xFFFFFFFFu || capacity == 0) return StageWait("waiting_for_water_record");
    if (*di >= capacity || capacity > 16384u) return StageFail("Drownable record unavailable");
    return 1;
}

/* The record's owner is the avatar's entity. */
static int SnapWaterOwner(const Chain* c, uintptr_t dm, int d, uint32_t di)
{
    SnapGuardAdd(dm + 56, d + 48, 8, 1, 0);
    uintptr_t owners = SnapPointer(d + 48);
    if (owners == 0) return 0;
    int owner = SnapRead(owners + 8u * (uintptr_t)di, 8, 1);
    if (owner == NONE) return 0;
    uintptr_t drownable = SnapPointer(owner);
    if (drownable == 0) return 0;
    int record = SnapRead(drownable, 24, 1);
    if (record == NONE) return 0;
    if (memcmp(g_arena + record, g_arena + c->entity, 24) != 0) return StageFail("Drownable identity mismatch");
    return 1;
}

/* The 28-byte runtime record and its two enable bytes. */
static int SnapWaterRecord(uintptr_t dm, int d, uint32_t di)
{
    SwdSnapshot* s = &swd_snap;
    SnapGuardAdd(dm + 64, d + 56, 8, 1, 0);
    uintptr_t data = SnapPointer(d + 56);
    if (data == 0) return 0;
    s->manager = dm;
    s->table = data;
    s->water_address = data + 28u * (uintptr_t)di;
    int water = SnapRead(s->water_address, 28, 0);
    if (water == NONE) return 0;
    SnapGuardAdd(dm + 72, d + 64, 8, 0, 0);
    uintptr_t enabled = SnapPointer(d + 64);
    if (enabled == 0) return 0;
    int e = SnapRead(enabled + 2u * (uintptr_t)di, 2, 0);
    if (e == NONE) return 0;
    s->enabled = g_arena[e] != 0;
    s->water_gate = g_arena[e + 1] != 0;
    if (Word(water + 4) != 0) return StageFail("Unsupported water reference node");
    s->offset = Real(water + 8);
    s->offset_bits = Word(water + 8);
    s->drown_elapsed = Real(water + 16);
    s->remaining = Real(water + 20);
    s->surface = Real(water + 24);
    s->elapsed_bits = Word(water + 16);
    s->deep = g_arena[water + 1] != 0;
    return 1;
}

static int SnapWater(const Chain* c)
{
    uintptr_t dm = 0;
    int d = 0;
    uint32_t di = 0;
    return SnapWaterIndex(c, &dm, &d, &di) && SnapWaterOwner(c, dm, d, di) && SnapWaterRecord(dm, d, di);
}

/* Map header (+24) and stance data pointer (+56), one read. */
static int SnapStance(const Chain* c)
{
    r.stage = &kStance;
    uintptr_t sm = SnapGlobal(RVA_STANCES, "waiting_for_stance_global_3326598", 1);
    if (sm == 0) return 0;
    int st = SnapFetch(sm + 24, 40);
    if (st == NONE) return 0;
    SnapGuardAdd(sm + 24, st, 20, 1, 0);
    uint32_t si = 0;
    int found = SnapLookup(st, c->id, 8192u, 1, &si);
    if (found == WAITING) return 0;
    if (found == ABSENT || si == 0xFFFFFFFFu) return StageWait("waiting_for_stance_record");
    if (si >= 4096u) return StageFail("Unsupported stance index");
    SnapGuardAdd(sm + 56, st + 32, 8, 1, 0);
    uintptr_t stances = SnapPointer(st + 32);
    if (stances == 0) return 0;
    swd_snap.stance_address = stances + 56u * (uintptr_t)si + 28u;
    int o = SnapRead(swd_snap.stance_address, 4, 0);
    if (o == NONE) return 0;
    swd_snap.stance = Word(o);
    if (swd_snap.stance == 3) return StageWait("waiting_for_stance");
    if (swd_snap.stance > 2) return StageFail("Unsupported stance");
    return 1;
}

/* Map header (+0x48A0) and position data pointer (+0x48D8), one read. */
static int SnapMovement(const Chain* c)
{
    r.stage = &kMovement;
    uintptr_t mm = SnapGlobal(RVA_MOVEMENT, "waiting_for_movement_global_3326558", 0);
    if (mm == 0) return 0;
    int mv = SnapFetch(mm + 0x48A0, 64);
    if (mv == NONE) return 0;
    SnapGuardAdd(mm + 0x48A0, mv, 20, 0, 0);
    uint32_t mi = 0;
    int found = SnapLookup(mv, c->id, 16384u, 0, &mi);
    if (found == WAITING) return 0;
    if (found == ABSENT || mi == 0xFFFFFFFFu) return StageWait("waiting_for_movement_record");
    if (mi >= 8192u) return StageFail("Unsupported movement index");
    SnapGuardAdd(mm + 0x48D8, mv + 0x38, 8, 0, 0);
    uintptr_t positions = SnapPointer(mv + 0x38);
    if (positions == 0) return 0;
    int pos = SnapRead(positions + 44u * (uintptr_t)mi, 44, 0);
    if (pos == NONE) return 0;
    if (g_arena[pos + 32] == 0) return StageWait("waiting_for_movement_reference");
    swd_snap.root_z = Real(pos + 8);
    return 1;
}

/* The Drownable settings: the entity owner's component table 309 (its 122-slot resource map and the first six records,
 * one read); the avatar's record must be the fifth, with the reviewed node and base. */
static int SnapSettings(const Chain* c)
{
    r.stage = &kWaterSettings;
    int at = SnapRead(c->owner + 0xF12E20, 8, 0);
    if (at == NONE) return 0;
    uintptr_t components = SnapPointer(at);
    if (components == 0) return 0;
    int map = SnapFetch(components, SETTINGS_SLOTS * 16 + 6 * SETTINGS_RECORD);
    if (map == NONE) return 0;
    SnapGuardAdd(components, map, SETTINGS_SLOTS * 16, 0, 0);
    int slot = 0;
    while (slot < SETTINGS_SLOTS && (Word(map + slot * 16) != AVATAR_LOW || Word(map + slot * 16 + 4) != AVATAR_HIGH)) slot++;
    if (slot == SETTINGS_SLOTS) return StageWait("waiting_for_water_settings");
    uint32_t index = Word(map + slot * 16 + 8);
    if (index != 5) return StageFail("Unsupported Drownable resource");
    int resource = map + SETTINGS_SLOTS * 16 + SETTINGS_RECORD * (int)index;
    SnapGuardAdd(components + SETTINGS_SLOTS * 16 + SETTINGS_RECORD * index, resource, SETTINGS_RECORD, 0, 0);
    if (Word(resource) != SETTINGS_NODE || Word(resource + 4) != BASE_BITS) return StageFail("Drownable settings changed");
    swd_snap.base = Real(resource + 4);
    swd_snap.prone = (float)((double)swd_snap.base + (double)0.9f);
    return 1;
}

/* Evidence for the next migration: every 2.0 near the expected block. */
static int SnapTimeoutChanged(void)
{
    uint8_t window[TIMEOUT_WINDOW];
    char found[200] = "";
    size_t n = 0;
    if (vpm_game_read(RVA_TIMEOUT_WINDOW, window, sizeof window))
        for (uint32_t o = 0; o + 4 <= TIMEOUT_WINDOW; o += 4)
        {
            uint32_t v;
            memcpy(&v, window + o, 4);
            if (v != TIMEOUT_BITS || n >= sizeof found - 12) continue;
            n += (size_t)snprintf(found + n, sizeof found - n, "%s0x%x", n > 0 ? "," : "", RVA_TIMEOUT_WINDOW + o);
        }
    char message[256];
    snprintf(message, sizeof message, "Native dive timeout changed (2.0 near expected block at: %s)", n > 0 ? found : "none");
    return StageFail(message);
}

/* The dive timeout (2.0) and both stance offsets are game.dll read-only data: verified on the first dive of a session,
 * not on every frame. */
static int SnapConstants(int* verified)
{
    if (*verified) return 1;
    uint32_t timeout = 0, old = 0;
    int timeoutOk = (vpm_game_read(RVA_TIMEOUT, &timeout, 4) && timeout == TIMEOUT_BITS) ||
                    (vpm_game_read(RVA_TIMEOUT_OLD, &old, 4) && old == TIMEOUT_BITS);
    if (!timeoutOk) return SnapTimeoutChanged();
    int prone = SnapImage(RVA_PRONE, 4, 0);
    if (prone == NONE) return 0;
    if (Word(prone) != PRONE_BITS) return StageFail("Stance offsets changed");
    int crouch = SnapImage(RVA_CROUCH, 4, 0);
    if (crouch == NONE) return 0;
    if (Word(crouch) != CROUCH_BITS) return StageFail("Stance offsets changed");
    *verified = 1;
    return 1;
}

static int SnapIdleValues(void)
{
    if (!Finite(swd_snap.elapsed) || !Finite(swd_snap.landing)) return StageFail("Invalid movement or water value");
    return 1;
}

static int SnapDiveValues(void)
{
    const SwdSnapshot* s = &swd_snap;
    int finite = Finite(s->elapsed) && Finite(s->landing) && Finite(s->offset) && Finite(s->drown_elapsed) &&
                 Finite(s->remaining) && Finite(s->surface) && Finite(s->root_z);
    return finite ? 1 : StageFail("Invalid movement or water value");
}

/* Outside a dive the check needs only the identity and the dive timer (it answers 'dive_ended' before reading anything
 * else), so the water, stance, movement and settings records wait for a dive; they are fully read and validated on every
 * dive frame, before any write. */
int swd_snapshot(int* verified, const char** wait)
{
    r.stage = &kMission;
    r.wait = NULL;
    r.wait_no_avatar = 0;
    r.used = r.guards = r.failed = 0;
    r.error[0] = 0;
    Chain c;
    memset(&c, 0, sizeof c);
    int ok = SnapMission() && SnapPlayer(&c) && SnapEntity(&c) && SnapRegistry(&c) && SnapController(&c);
    if (ok && !swd_snap.dive) ok = SnapIdleValues();
    else if (ok)
        ok = SnapWater(&c) && SnapStance(&c) && SnapMovement(&c) && SnapSettings(&c) && SnapConstants(verified) &&
             SnapDiveValues();
    if (r.failed) return -1;
    if (!ok) { *wait = r.wait; return 0; }
    return 1;
}

/* ---- guards ----------------------------------------------------------------------------------------------------- */

static int SnapGuardRead(uintptr_t address, void* out, int size, int image)
{
    if (image) return vpm_game_read((uint32_t)(address - vpm_game()), out, (size_t)size);
    return vpm_read(address, out, (size_t)size);
}

int swd_guards_match(int identity_only)
{
    for (int i = 0; i < r.guards; i++)
    {
        const SnapGuard* g = &g_guards[i];
        if (identity_only && !g->identity) continue;
        if (!SnapGuardRead(g->address, g_recheck, g->size, g->image)) return 0;
        if (memcmp(g_recheck, g_arena + g->offset, (size_t)g->size) != 0) return 0;
    }
    return 1;
}

/* Identity guards are pointers, map rows, map headers and entity records: never more than IDENTITY_BYTES. */
void swd_keep_identities(void)
{
    g_identityCount = 0;
    for (int i = 0; i < r.guards; i++)
    {
        const SnapGuard* g = &g_guards[i];
        if (!g->identity || g->size > IDENTITY_BYTES) continue;
        SnapIdentity* k = &g_identity[g_identityCount++];
        k->address = g->address;
        k->size = g->size;
        k->image = g->image;
        memcpy(k->bytes, g_arena + g->offset, (size_t)g->size);
    }
}

int swd_identities_match(void)
{
    for (int i = 0; i < g_identityCount; i++)
    {
        const SnapIdentity* k = &g_identity[i];
        uint8_t now[IDENTITY_BYTES];
        if (!SnapGuardRead(k->address, now, k->size, k->image) || memcmp(now, k->bytes, (size_t)k->size) != 0) return 0;
    }
    return 1;
}

/* The idle gate, run by the component between full checks while the last one found the local avatar idle: one read of
 * its dive controller into the arena. The same avatar id, no dive flag (bit 0x20 of +0xF8C) and finite timers mean
 * 'dive_ended', exactly what the full check answers there. Anything else (a dive, another id, a failed read) is 0, and
 * the component runs the full check at once. lint: per-frame */
int swd_idle(uintptr_t controller, uint32_t id)
{
    if (!vpm_read(controller + CONTROLLER, g_arena, CONTROLLER_SIZE)) return 0;
    if (Word(0) != id || (Word(FLAGS + 12) & 0x20u) != 0) return 0;
    return Finite(Real(8)) && Finite(Real(12));
}
