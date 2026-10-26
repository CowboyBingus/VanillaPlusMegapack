/* Reinforcement Beacons Fixed v4.6.1: the snapshot reader (spawn_data.lua's session, local_player, beacon_records,
 * automatic_anchors, unit_position and source_position), build 25480438.
 *
 * Reads only. game.dll's and the exe's globals are plain loads (the images stay mapped); everything they point to is
 * read through HfApi.read into the buffers below, kept for the session, one kind of data each, and decoded in place.
 * A null pointer or an unreadable range is "waiting for game data" at the stage being read (RBF_WAIT, retried on the
 * next frame); a non-null pointer outside user space or an unsupported layout refuses (vpm_fail), as the Lua's asserts
 * stopped it. */
#include <stddef.h>
#include <string.h>
#include "spawn_data.h"

#define RVA_MISSION_MODE 0x33266A0u     /* game.dll globals */
#define RVA_REINFORCEMENTS 0x33269C0u
#define RVA_POSITIONS 0x3326B20u
#define RVA_ANCHORS 0x33266B0u          /* the active stratagems: count +0x34, 64-byte rows at +0x78 */
#define RVA_SOURCE_ENTITIES 0x346BF98u
#define RVA_FALLBACK 0x346D560u         /* the fallback source position, at +0x3C */
#define EXE_UNIT_REGISTRY 0x1A100F0u    /* helldivers2.exe: the unit registry global */
#define EXE_SCENE_GRAPH 0x2BD870u       /* the scene-graph method a unit's vtable holds at +0xE8 */
#define AT_SOURCE_LOOKUP 0xF22EC8u      /* entity manager: unit id -> entity index (15871688) */
#define AT_SOURCE_RECORDS 0xF32F18u     /* its 24-byte entity records (15937304); the engine reference at +12 */
#define NO_UNIT 0x7FFFu
#define MAX_ENTITY 262144u
#define MAX_LOOKUP 1048576u
#define MAX_PROBES 128u
#define ROW_SIZE 64u
#define AT_ROW_TYPE 12u
#define AT_ROW_POSITION 16u
#define AUTOMATIC HF_STRATAGEM_REINFORCEMENT_BEACON /* the automatic-reinforcement dummy's type (producer ACCC96 /
                                                     * ACCEC5); HellForge's added stratagems take 150 and up */
_Static_assert(HF_STRATAGEM_REINFORCEMENT_BEACON == 0x7Cu, "the automatic reinforcement row type of build 25480438");

const char rbf_stage_player_manager[] = "player_manager";
const char rbf_stage_spawn_state[] = "spawn_state";
static const char kMissionMode[] = "mission_mode";
static const char kLocalPlayer[] = "local_player";
static const char kReinforcements[] = "reinforcement_manager";
static const char kPositions[] = "position_manager";
static const char kRecords[] = "reinforcement_records";
static const char kAnchors[] = "automatic_anchor_manager";
static const char kSourceEntities[] = "source_entity_manager";
static const char kRegistry[] = "source_unit_registry";
static const char kFallback[] = "fallback_position";

/* The session's read buffers (static: about 34 KB). */
static uint8_t g_mode[0x44], g_players[0x440], g_entity[24], g_reinforcements[0x58], g_positions[0x60];
static uint8_t g_entities[RBF_MAX_BEACONS * 8], g_used[RBF_MAX_BEACONS * 4], g_row[8], g_coordinates[12], g_byte[1];
static uint8_t g_anchors[0x80], g_source_lookup[20], g_registry[0xA8];
static uint8_t g_rows[RBF_MAX_ROWS * ROW_SIZE];

static uint32_t U32(const uint8_t* b, size_t at) { uint32_t v; memcpy(&v, b + at, 4); return v; }
static uint64_t U64(const uint8_t* b, size_t at) { uint64_t v; memcpy(&v, b + at, 8); return v; }

/* A float from its bits: 0 for NaN or infinity. */
static int Float(const uint8_t* b, size_t at, float* out)
{
    uint32_t bits = U32(b, at);
    if (((bits >> 23) & 0xFFu) == 0xFFu) return 0;
    memcpy(out, &bits, 4);
    return 1;
}

/* Three floats, each a number within 100 km: 1, or 0 (the Lua's nil). */
static int Vector(const uint8_t* b, size_t at, float* out)
{
    float v[3];
    for (int i = 0; i < 3; i++)
        if (!Float(b, at + 4u * (size_t)i, &v[i]) || (double)v[i] > 100000.0 || (double)v[i] < -100000.0) return 0;
    memcpy(out, v, sizeof v);
    return 1;
}

static int Fail(RbfReader* r, const char* what)
{
    vpm_fail(r->self, "%s", what);
    return RBF_FAILED;
}

static int Read(uintptr_t at, void* out, size_t size) { return vpm_read(at, out, size) ? RBF_OK : RBF_WAIT; }

/* The pointer stored at b + at (data_pointer): null waits, one outside user space refuses. */
static int DataPointer(RbfReader* r, const uint8_t* b, size_t at, uintptr_t* out)
{
    uint64_t value = U64(b, at);
    if (value == 0) return RBF_WAIT;
    if (!vpm_plausible((uintptr_t)value))
    {
        vpm_fail(r->self, "Invalid spawn data pointer: %s", r->stage);
        return RBF_FAILED;
    }
    *out = (uintptr_t)value;
    return RBF_OK;
}

/* The pointer stored at a heap address (pointer). */
static int Pointer(RbfReader* r, uintptr_t at, uintptr_t* out)
{
    uint8_t cell[8];
    if (!vpm_read(at, cell, sizeof cell)) return RBF_WAIT;
    return DataPointer(r, cell, 0, out);
}

/* A game.dll global, a plain load (global): the stage becomes its name. */
static int Global(RbfReader* r, uint32_t rva, const char* stage, uintptr_t* out)
{
    uint8_t cell[8];
    r->stage = stage;
    if (!vpm_game_read(rva, cell, sizeof cell)) return RBF_WAIT;
    return DataPointer(r, cell, 0, out);
}

/* The index of key in the game's lookup whose 20-byte header is at header + at ({rows, capacity, empty key,
 * multiplier}), probed from key * multiplier: *found 0 when absent. One read per probe, at most 128. */
static int Lookup(RbfReader* r, const uint8_t* header, size_t at, uint32_t key, uint32_t* index, int* found)
{
    uint32_t capacity = U32(header, at + 8), empty = U32(header, at + 12), multiplier = U32(header, at + 16);
    uintptr_t table = 0;
    *found = 0;
    if (capacity == 0) return RBF_OK;
    if (capacity > MAX_LOOKUP || (capacity & (capacity - 1)) != 0) return Fail(r, "Invalid lookup capacity");
    int rc = DataPointer(r, header, at, &table);
    uint32_t first = key * multiplier, probes = capacity < MAX_PROBES ? capacity : MAX_PROBES;
    for (uint32_t probe = 0; rc == RBF_OK && probe < probes; probe++)
    {
        rc = Read(table + 8u * (uintptr_t)((first + probe) & (capacity - 1)), g_row, sizeof g_row);
        if (rc != RBF_OK) break;
        if (U32(g_row, 0) == key)
        {
            *index = U32(g_row, 4);
            *found = *index != 0xFFFFFFFFu;
            break;
        }
        if (U32(g_row, 0) == empty) break;
    }
    return rc;
}

void rbf_clear(RbfSnapshot* out)
{
    memset(out, 0, offsetof(RbfSnapshot, beacons));
    out->count = out->id = out->state = RBF_NIL;
}

/* The mission mode, then (in gameplay modes 1 .. 7 only) the player manager and its player block. */
static int Session(RbfReader* r, RbfSnapshot* out, uint32_t* available)
{
    uintptr_t at = 0;
    int rc = Global(r, RVA_MISSION_MODE, kMissionMode, &at);
    if (rc == RBF_OK) rc = Read(at, g_mode, sizeof g_mode);
    if (rc != RBF_OK) return rc;
    out->mode = U32(g_mode, 8) > 0 ? U32(g_mode, 0x40) : 0;
    if (out->mode < 1 || out->mode > 7) return RBF_OK;
    rc = Global(r, RBF_PLAYER_MANAGER, rbf_stage_player_manager, &at);
    if (rc == RBF_OK) rc = Read(at, g_players, sizeof g_players);
    if (rc != RBF_OK) return rc;
    uint32_t count = U32(g_players, 0x84);
    *available = U32(g_players, 0x88);
    if (count > 4 || *available > 4) return Fail(r, "Unsupported player layout");
    out->identity = at;
    out->address = at + RBF_AT_XY;
    out->count = count;
    out->rows_known = 1;
    return RBF_OK;
}

/* The local player's identity, spawn state, use bit and pending spawn, from the player block. */
static int LocalPlayer(RbfReader* r, RbfSnapshot* out)
{
    uintptr_t entity = 0;
    r->stage = kLocalPlayer;
    int rc = DataPointer(r, g_players, 0xE8, &entity);
    if (rc == RBF_OK) rc = Read(entity, g_entity, sizeof g_entity);
    if (rc != RBF_OK) return rc;
    out->id = U32(g_entity, 8);
    out->owned = (g_entity[20] & 1) != 0;
    out->state = U32(g_players, RBF_AT_SPAWN);
    out->use_bit = U32(g_players, 0x3B4);
    out->positioned = Vector(g_players, RBF_AT_XY, out->position);
    if (out->state == RBF_PENDING) memcpy(out->original, g_players + RBF_AT_XY, 8);
    out->timed = Float(g_players, 0x12C, &out->countdown);
    out->unit_ref = U32(g_players, 0x3A8);
    if (out->use_bit >= 32) return Fail(r, "Unsupported player-use bit");
    return RBF_OK;
}

/* The reinforcement manager's block and its count of active records; with positioned, the position manager's block. */
static int BeaconManagers(RbfReader* r, int positioned, uint32_t* active)
{
    uintptr_t at = 0;
    int rc = Global(r, RVA_REINFORCEMENTS, kReinforcements, &at);
    if (rc == RBF_OK) rc = Read(at, g_reinforcements, sizeof g_reinforcements);
    if (rc != RBF_OK) return rc;
    *active = U32(g_reinforcements, 12);
    if (*active > RBF_MAX_BEACONS || *active > U32(g_reinforcements, 8)) return Fail(r, "Unsupported reinforcement layout");
    if (!positioned || *active == 0) return RBF_OK;
    rc = Global(r, RVA_POSITIONS, kPositions, &at);
    if (rc == RBF_OK) rc = Read(at, g_positions, sizeof g_positions);
    return rc;
}

/* A beacon's position through the position manager's lookup (b->positioned stays 0 when absent). */
static int BeaconPosition(RbfReader* r, RbfBeacon* b)
{
    uint32_t index = 0;
    int found = 0;
    int rc = Lookup(r, g_positions, 0x28, b->id, &index, &found);
    if (rc != RBF_OK || !found) return rc;
    if (index >= U32(g_positions, 8)) return Fail(r, "Position index outside live data");
    uintptr_t at = 0;
    rc = DataPointer(r, g_positions, 0x50, &at);
    if (rc == RBF_OK) rc = Read(at + (uintptr_t)index * 12u, g_coordinates, sizeof g_coordinates);
    if (rc == RBF_OK) b->positioned = Vector(g_coordinates, 0, b->position);
    return rc;
}

static int BeaconRecord(RbfReader* r, RbfSnapshot* out, uint32_t i, int positioned)
{
    uintptr_t at = 0;
    int rc = DataPointer(r, g_entities, 8u * i, &at);
    if (rc == RBF_OK) rc = Read(at, g_entity, sizeof g_entity);
    if (rc != RBF_OK) return rc;
    RbfBeacon* b = &out->beacons[out->beacon_count];
    b->id = U32(g_entity, 8);
    b->owned = (g_entity[20] & 1) != 0;
    b->positioned = 0;
    if (positioned) rc = BeaconPosition(r, b);
    b->used = U32(g_used, 4u * i);
    if (rc == RBF_OK) out->beacon_count++;
    return rc;
}

/* Every active reinforcement record: id, ownership, position (queued or pending only) and use bits; the entity pointers
 * and the use bits in one read each. */
static int BeaconRecords(RbfReader* r, RbfSnapshot* out)
{
    int positioned = out->state == 1 || out->state == 2;
    uint32_t active = 0;
    int rc = BeaconManagers(r, positioned, &active);
    if (rc != RBF_OK || active == 0) return rc;
    uintptr_t entities = 0, used = 0;
    r->stage = kRecords;
    rc = DataPointer(r, g_reinforcements, 0x38, &entities);
    if (rc == RBF_OK) rc = Read(entities, g_entities, 8u * active);
    if (rc == RBF_OK) rc = DataPointer(r, g_reinforcements, 0x48, &used);
    if (rc == RBF_OK) rc = Read(used, g_used, 4u * active);
    for (uint32_t i = 0; rc == RBF_OK && i < active; i++) rc = BeaconRecord(r, out, i, positioned);
    return rc;
}

/* Solo: every automatic-reinforcement row with a usable position, the active rows read at once. */
static int AutomaticAnchors(RbfReader* r, RbfSnapshot* out)
{
    uintptr_t at = 0;
    int rc = Global(r, RVA_ANCHORS, kAnchors, &at);
    if (rc == RBF_OK) rc = Read(at, g_anchors, sizeof g_anchors);
    if (rc != RBF_OK) return rc;
    uint32_t n = U32(g_anchors, 0x34);
    if (n > RBF_MAX_ROWS) return Fail(r, "Unsupported active stratagem count");
    if (n == 0) return RBF_OK;
    rc = DataPointer(r, g_anchors, 0x78, &at);
    if (rc == RBF_OK) rc = Read(at, g_rows, (size_t)n * ROW_SIZE);
    for (uint32_t i = 0; rc == RBF_OK && i < n; i++)
    {
        const uint8_t* row = g_rows + (size_t)i * ROW_SIZE;
        if (U32(row, AT_ROW_TYPE) == AUTOMATIC && Vector(row, AT_ROW_POSITION, out->rows[out->row_count].position))
            out->row_count++;
    }
    return rc;
}

int rbf_snapshot(RbfReader* reader, RbfSnapshot* out)
{
    uint32_t available = 0;
    rbf_clear(out);
    int rc = Session(reader, out, &available);
    if (rc != RBF_OK || out->identity == 0 || out->count == 0 || available == 0) return rc;
    rc = LocalPlayer(reader, out);
    if (rc != RBF_OK || !out->owned) return rc;
    rc = BeaconRecords(reader, out);
    if (rc != RBF_OK || out->count != 1) return rc;
    rc = AutomaticAnchors(reader, out);
    out->solo = rc == RBF_OK;
    return rc;
}

/* The unit's object in the registry: its generation, its scene-graph method, its world position. */
static int UnitObject(RbfReader* r, RbfSnapshot* c, uint32_t slot, uint32_t generation)
{
    uintptr_t generations = 0, objects = 0, object = 0, vtable = 0, method = 0, scene = 0;
    int rc = DataPointer(r, g_registry, 0xA0, &generations);
    if (rc == RBF_OK) rc = Read(generations + slot, g_byte, sizeof g_byte);
    if (rc != RBF_OK) return rc;
    if (g_byte[0] != generation) return Fail(r, "Unit generation changed");
    rc = DataPointer(r, g_registry, 0x88, &objects);
    if (rc == RBF_OK) rc = Pointer(r, objects + 8u * (uintptr_t)slot, &object);
    if (rc == RBF_OK) rc = Pointer(r, object, &vtable);
    if (rc == RBF_OK) rc = Pointer(r, vtable + 0xE8u, &method);
    if (rc != RBF_OK) return rc;
    if (method - vpm_exe() != EXE_SCENE_GRAPH) return Fail(r, "Unsupported unit scene-graph layout");
    rc = Pointer(r, object + 0x88u, &scene);
    if (rc == RBF_OK) rc = Read(scene + 0x30u, g_coordinates, sizeof g_coordinates);
    if (rc == RBF_OK) c->source_valid = Vector(g_coordinates, 0, c->source);
    return rc;
}

/* The source unit's world position (AC5BB0's read, without calling it): entity index, engine reference, registry slot
 * and generation, scene-graph object. */
static int UnitPosition(RbfReader* r, RbfSnapshot* c, uintptr_t em, uint32_t index)
{
    if (index >= MAX_ENTITY) return Fail(r, "Entity index outside supported bound");
    int rc = Read(em + AT_SOURCE_RECORDS + (uintptr_t)index * 24u, g_entity, sizeof g_entity);
    if (rc != RBF_OK) return rc;
    uint32_t engine = U32(g_entity, 12);
    uint8_t cell[8];
    uintptr_t registry = 0;
    r->stage = kRegistry;
    rc = vpm_exe_read(EXE_UNIT_REGISTRY, cell, sizeof cell) ? DataPointer(r, cell, 0, &registry) : RBF_WAIT;
    if (rc == RBF_OK) rc = Read(registry, g_registry, sizeof g_registry);
    if (rc != RBF_OK) return rc;
    uint32_t slot = engine & 0x3FFFFFu;
    if (slot >= U32(g_registry, 0x98)) return Fail(r, "Unit slot outside registry");
    return UnitObject(r, c, slot, engine >> 22);
}

/* The position a death anchor freezes: the local player's source unit, else the fallback position. */
static int SourcePosition(RbfReader* r, RbfSnapshot* c)
{
    uintptr_t em = 0, fallback = 0;
    uint32_t index = 0;
    int found = 0;
    int rc = Global(r, RVA_SOURCE_ENTITIES, kSourceEntities, &em);
    if (rc == RBF_OK && c->unit_ref != NO_UNIT)
    {
        rc = Read(em + AT_SOURCE_LOOKUP, g_source_lookup, sizeof g_source_lookup);
        if (rc == RBF_OK) rc = Lookup(r, g_source_lookup, 0, c->unit_ref, &index, &found);
    }
    if (rc != RBF_OK) return rc;
    if (found) return UnitPosition(r, c, em, index);
    rc = Global(r, RVA_FALLBACK, kFallback, &fallback);
    if (rc == RBF_OK) rc = Read(fallback + 0x3Cu, g_coordinates, sizeof g_coordinates);
    if (rc == RBF_OK) c->source_valid = Vector(g_coordinates, 0, c->source);
    return rc;
}

int rbf_source(RbfReader* reader, RbfSnapshot* current)
{
    if (current->source_valid || !current->solo) return RBF_OK;
    return SourcePosition(reader, current);
}
