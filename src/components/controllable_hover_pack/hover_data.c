/* Controllable Hover Pack's snapshot (Lua: hover_data.lua M.snapshot and its stages), build 25480438: the local
 * player's hover pack through the game's registries, read only.
 *
 * Full resolution: the mission state, then the player manager's local unit through the entity owner's map to the
 * avatar's entity record, the avatar manager's index for it (its record compared), the equipment registry's row for the
 * avatar (the identity array compared) and the backpack id in it, the jump-pack manager's registry index for that pack
 * (the active and locally simulated prefixes, the pack's entity record and the hover resource 5ec80f4f1cdb66cf with the
 * owned bit), the attachment registry's holder (the avatar again), then the pack's five state bytes, the avatar's
 * movement flags and the Jump action's held time. Local avatar index 0 is never assumed.
 *
 * Kept layout: where the full resolution found each record. Later snapshots read those records at their kept addresses
 * and the registry slots and array pointers that lead to them (one read per registry block), and resolve again from the
 * roots when any of it differs; a fresh snapshot (before a cancellation) always resolves again.
 *
 * Not vpm_local_avatar: the Lua's own resolution differs from the core's (Arc Thrower Revamped's) in what it reports
 * and keeps. It names why there is no avatar (no player, no avatar; an unsupported count or index is a game-data wait,
 * which the idle gate does not wait out), checks each map's row pointer for the user-mode range, and keeps the unit and
 * the entity owner's record address, which the kept layout reads every frame. The core's VpmAvatar holds the avatar
 * manager, index and entity it found, and vpm_action_slot gives the Jump slot (the same formula).
 *
 * Reads go through vpm_read, as the Lua's ReadProcessMemory; game.dll's globals are plain loads (the Lua read them),
 * still counted in the Lua's budget of 160 per snapshot. */
#include <string.h>
#include "../../core/vpm.h"
#include "hover.h"

#define READS 160u                  /* the Lua's read budget per snapshot */
#define AVATAR_LOW 0x294DFA97u      /* the avatar entity type 4d1c334d294dfa97 */
#define AVATAR_HIGH 0x4D1C334Du
#define HOVER_LOW 0x1CDB66CFu       /* the hover pack's resource 5ec80f4f1cdb66cf */
#define HOVER_HIGH 0x5EC80F4Fu
#define PM_COUNTS 0x84u             /* player manager: two counts (at most 4) */
#define PM_PLAYER 0xE8u             /* the local player's 24-byte record (owned bit) */
#define PM_UNIT 0x3A8u              /* the local unit (0x7FFF: none) */
#define OWNER_LOOKUP 0xF22EC8u      /* entity owner: unit -> entity index */
#define OWNER_RECORDS 0xF32F18u     /* entity owner: 24-byte entity records */
#define AM_LOOKUP 0xF8u             /* avatar manager: avatar id -> index */
#define AM_COUNT 0x6Cu
#define AM_SLOT_IN_BLOCK 0xA4u      /* the entity pointers (+0x110) from the count (+0x6C) */
#define AM_BLOCK 0xACu              /* count .. the first entity pointer's end */
#define AM_ENTITIES 0x110u
#define AM_FLAGS 0x53D900u          /* movement flags: + index * 0x1238 + 0xF80 */
#define AM_FLAGS_STRIDE 0x1238u
#define AM_FLAGS_AT 0xF80u
#define EQ_LOOKUP 40u               /* equipment registry: avatar id -> row */
#define EQ_IDS 64u                  /* the identity array (and the rows at +80, read together) */
#define EQ_ROWS 80u
#define EQ_ROW 48u
#define EQ_PACK 12u                 /* the backpack's entity id in a row */
#define JM_COUNTS 16u               /* jump-pack manager: active prefix, locally simulated prefix */
#define JM_LOOKUP 32u               /* pack id -> registry index */
#define JM_ENTRIES 56u              /* entity pointers */
#define JM_STATES 80u               /* five state bytes per pack: +0 active, +1 landing assistance, +4 lift */
#define JM_BLOCK 72u                /* +16 .. +88: counts, map, entries, states in one read */
#define AT_LOOKUP 32u               /* attachment registry: pack id -> row */
#define AT_ROWS 64u
#define AT_ROW 48u
#define AT_HOLDER 4u
#define DIFFERS (-1)                /* the kept layout no longer holds: resolve again */

static struct
{
    int stage;          /* how far the full resolution got: 0 none, 1 avatar, 2 equipment row, 3 jump-pack registry, 4 all */
    uintptr_t pm;       /* the player manager and the local unit it named */
    uint32_t unit;
    uintptr_t avatar;   /* the avatar's entity record in the entity owner */
    VpmAvatar a;        /* the avatar's record, its manager, index and entity pointer there */
    uintptr_t eq, eq_ids, eq_slot, eq_rows, pack_at;
    uint32_t qi;
    uintptr_t jm, jm_entries, entity, states;
    uint32_t pack_id, ji;
    int has_ji;         /* 0: the backpack is no jump pack */
    int hover;
    uint32_t ew[6];     /* the pack's entity record */
    uintptr_t attach, attach_rows, owner_at;
} L;

static ChpSnapshot S;
static uint32_t g_reads;
static const char* g_error;

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static int Holds(const uint8_t* at, uintptr_t pointer) { uint64_t v; memcpy(&v, at, 8); return v == (uint64_t)pointer; }
static int Owned(const uint8_t* record) { return (record[20] & 1u) != 0; }
static int Plausible(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull; }
static void Forget(void) { L.stage = 0; }

/* What the Lua asserted: a game-data wait. */
static int Fail(const char* error)
{
    g_error = error;
    return CHP_WAITING_FOR_GAME_DATA;
}

static int Budget(void) { return ++g_reads > READS ? Fail("Hover read budget exceeded") : 0; }

static int Read(uintptr_t address, void* out, size_t size)
{
    int r = Budget();
    if (r != 0) return r;
    return vpm_read(address, out, size) ? 0 : CHP_WAITING_FOR_READ;
}

static int PointerAt(const uint8_t* bytes, uintptr_t* out)
{
    uint64_t value;
    memcpy(&value, bytes, 8);
    if (!Plausible(value)) return CHP_WAITING_FOR_POINTER;
    *out = (uintptr_t)value;
    return 0;
}

static int ReadPointer(uintptr_t address, uintptr_t* out)
{
    uint8_t bytes[8];
    int r = Read(address, bytes, sizeof bytes);
    return r != 0 ? r : PointerAt(bytes, out);
}

/* A game.dll global: a plain load (the Lua's read, still counted in its budget). */
static int Global(uint32_t rva, uintptr_t* out)
{
    int r = Budget();
    if (r != 0) return r;
    uint64_t value = vpm_game_u64(rva);
    if (!Plausible(value)) return CHP_WAITING_FOR_POINTER;
    *out = (uintptr_t)value;
    return 0;
}

/* The game's hash map from a 20-byte header already read {rows, capacity, empty key, multiplier}: *found and *index, or
 * an error. At most 64 probes, a power-of-two capacity no larger than limit. */
static int Lookup(const uint8_t* header, uint32_t key, uint32_t limit, int* found, uint32_t* index)
{
    uint32_t capacity = U32(header + 8), empty = U32(header + 12), multiplier = U32(header + 16);
    uintptr_t rows;
    *found = 0;
    if (capacity == 0) return 0;
    if (capacity > limit || (capacity & (capacity - 1)) != 0) return Fail("Unsupported hover map");
    uint32_t product = key * multiplier;
    int r = PointerAt(header, &rows);
    uint32_t probes = capacity < 64 ? capacity : 64;
    for (uint32_t probe = 0; r == 0 && probe < probes; probe++)
    {
        uint8_t row[8];
        r = Read(rows + 8u * ((product + probe) & (capacity - 1)), row, sizeof row);
        if (r != 0 || (U32(row) != key && U32(row) != empty)) continue;
        *found = U32(row) == key && U32(row + 4) != 0xFFFFFFFFu;
        *index = U32(row + 4);
        return 0;
    }
    return r;
}

/* ---- full resolution --------------------------------------------------------------------------------------------- */

static int Mission(void)
{
    uintptr_t mode;
    uint8_t block[0x44];
    int r = Global(CHP_RVA_MODE, &mode);
    if (r == 0) r = Read(mode, block, sizeof block);
    if (r != 0) return r;
    /* +0x40 is a mission type, not a flag: the native player logic accepts 1 .. 7 (Evacuate High-Value Assets is 2). */
    S.mission_type = U32(block + 0x40);
    if (U32(block + 8) == 0 || S.mission_type < 1 || S.mission_type > 7) return CHP_WAITING_FOR_MISSION;
    return 0;
}

static int LocalUnit(uint32_t* unit)
{
    uintptr_t pm, player;
    uint8_t counts[8], record[24], word[4];
    int r = Global(VPM_RVA_PLAYER_MANAGER, &pm);
    if (r == 0) r = Read(pm + PM_COUNTS, counts, sizeof counts);
    if (r != 0) return r;
    if (U32(counts) > 4 || U32(counts + 4) > 4) return Fail("Unsupported player count");
    if (U32(counts) == 0 || U32(counts + 4) == 0) return CHP_WAITING_FOR_PLAYER;
    r = ReadPointer(pm + PM_PLAYER, &player);
    if (r == 0) r = Read(player, record, sizeof record);
    if (r != 0) return r;
    if (!Owned(record)) return CHP_WAITING_FOR_PLAYER;
    r = Read(pm + PM_UNIT, word, sizeof word);
    if (r != 0) return r;
    *unit = U32(word);
    if (*unit == 0x7FFFu) return CHP_WAITING_FOR_AVATAR;
    L.pm = pm;
    L.unit = *unit;
    return 0;
}

static int AvatarRecord(uint32_t unit, uint8_t* avatar)
{
    uintptr_t owner;
    uint8_t header[20];
    int found = 0;
    uint32_t ei = 0;
    int r = Global(VPM_RVA_ENTITY_OWNER, &owner);
    if (r == 0) r = Read(owner + OWNER_LOOKUP, header, sizeof header);
    if (r == 0) r = Lookup(header, unit, 1048576u, &found, &ei);
    if (r != 0) return r;
    if (!found) return CHP_WAITING_FOR_AVATAR;
    if (ei >= 262144u) return Fail("Unsupported entity index");
    L.avatar = owner + OWNER_RECORDS + (uintptr_t)ei * 24u;
    r = Read(L.avatar, avatar, 24);
    if (r != 0) return r;
    if (U32(avatar) != AVATAR_LOW || U32(avatar + 4) != AVATAR_HIGH || !Owned(avatar)) return CHP_WAITING_FOR_AVATAR;
    return 0;
}

static int AvatarSlot(const uint8_t* avatar)
{
    uintptr_t am, slot;
    uint8_t header[20], word[4], record[24];
    int found = 0;
    uint32_t ai = 0;
    int r = Global(VPM_RVA_AVATAR_MANAGER, &am);
    if (r == 0) r = Read(am + AM_LOOKUP, header, sizeof header);
    if (r == 0) r = Lookup(header, U32(avatar + 8), 64u, &found, &ai);
    if (r != 0) return r;
    if (!found) return CHP_WAITING_FOR_AVATAR;
    r = Read(am + AM_COUNT, word, sizeof word);
    if (r != 0) return r;
    if (U32(word) > 8 || ai >= U32(word)) return Fail("Unsupported avatar index");
    r = ReadPointer(am + AM_ENTITIES + (uintptr_t)ai * 8u, &slot);
    if (r == 0) r = Read(slot, record, sizeof record);
    if (r != 0) return r;
    if (memcmp(record, avatar, 24) != 0) return Fail("Avatar identity mismatch");
    memcpy(L.a.record, avatar, 24);
    L.a.manager = am;
    L.a.index = ai;
    L.a.entity = slot;
    L.stage = 1;
    return 0;
}

/* The equipped backpack's entity id: the avatar's equipment row (never the first pack found). */
static int Backpack(const uint8_t* avatar, uint32_t* pack_id)
{
    uintptr_t eq, ids, slot, rows;
    uint8_t header[20], record[24], word[4];
    int found = 0;
    uint32_t qi = 0;
    int r = Global(CHP_RVA_EQUIPMENT, &eq);
    if (r == 0) r = Read(eq + EQ_LOOKUP, header, sizeof header);
    if (r == 0) r = Lookup(header, U32(avatar + 8), 8192u, &found, &qi);
    if (r != 0) return r;
    if (!found) return CHP_NO_BACKPACK;
    if (qi >= 4096u) return Fail("Unsupported equipment index");
    r = ReadPointer(eq + EQ_IDS, &ids);
    if (r == 0) r = ReadPointer(ids + (uintptr_t)qi * 8u, &slot);
    if (r == 0) r = Read(slot, record, sizeof record);
    if (r != 0) return r;
    if (memcmp(record, avatar, 24) != 0) return Fail("Equipment identity mismatch");
    r = ReadPointer(eq + EQ_ROWS, &rows);
    if (r != 0) return r;
    L.eq = eq;
    L.qi = qi;
    L.eq_ids = ids;
    L.eq_slot = slot;
    L.eq_rows = rows;
    L.pack_at = rows + (uintptr_t)qi * EQ_ROW + EQ_PACK;
    L.stage = 2;
    r = Read(L.pack_at, word, sizeof word);
    if (r != 0) return r;
    *pack_id = U32(word);
    return *pack_id == 0 || *pack_id == 0xFFFFFFFFu ? CHP_NO_BACKPACK : 0;
}

/* The pack's entity record through the registry's entity array; its id must be the pack's. */
static int PackEntity(uintptr_t jm, uint32_t ji, uint32_t pack_id, uintptr_t* entries, uintptr_t* address, uint8_t* entity)
{
    int r = ReadPointer(jm + JM_ENTRIES, entries);
    if (r == 0) r = ReadPointer(*entries + (uintptr_t)ji * 8u, address);
    if (r == 0) r = Read(*address, entity, 24);
    if (r != 0) return r;
    return U32(entity + 8) == pack_id ? 0 : Fail("Pack identity mismatch");
}

static int JumpPack(uint32_t pack_id, uint8_t* entity)
{
    uintptr_t jm, entries = 0, address = 0;
    uint8_t header[20], counts[8];
    int found = 0;
    uint32_t ji = 0;
    int r = Global(CHP_RVA_JUMP_PACKS, &jm);
    if (r != 0) return r;
    L.jm = jm;
    L.pack_id = pack_id;
    r = Read(jm + JM_LOOKUP, header, sizeof header);
    if (r == 0) r = Lookup(header, pack_id, 128u, &found, &ji);
    if (r != 0) return r;
    if (!found)
    {
        L.has_ji = 0;
        L.stage = 3;
        return CHP_NO_JUMP_PACK;
    }
    r = Read(jm + JM_COUNTS, counts, sizeof counts);
    if (r != 0) return r;
    /* +0x14, the locally simulated prefix, lies inside +0x10, the active one. */
    if (U32(counts + 4) > U32(counts) || U32(counts) > 64) return Fail("Unsupported jump-pack registry");
    if (ji >= U32(counts + 4)) return CHP_PACK_NOT_OWNED;
    r = PackEntity(jm, ji, pack_id, &entries, &address, entity);
    if (r != 0) return r;
    int hover = U32(entity) == HOVER_LOW && U32(entity + 4) == HOVER_HIGH;
    if (hover && !Owned(entity)) return CHP_PACK_NOT_OWNED;
    L.has_ji = 1;
    L.ji = ji;
    L.jm_entries = entries;
    L.entity = address;
    L.hover = hover;
    memcpy(L.ew, entity, 24);
    L.stage = 3;
    return hover ? 0 : CHP_NOT_HOVER_PACK;
}

/* The pack's row in the attachment registry must name the avatar as its holder. */
static int Attached(uint32_t pack_id, const uint8_t* avatar)
{
    uintptr_t attach, rows;
    uint8_t header[20], word[4];
    int found = 0;
    uint32_t bi = 0;
    int r = Global(CHP_RVA_ATTACHMENT, &attach);
    if (r == 0) r = Read(attach + AT_LOOKUP, header, sizeof header);
    if (r == 0) r = Lookup(header, pack_id, 8192u, &found, &bi);
    if (r != 0) return r;
    if (!found) return CHP_PACK_NOT_ATTACHED;
    if (bi >= 4096u) return Fail("Unsupported attachment index");
    r = ReadPointer(attach + AT_ROWS, &rows);
    if (r == 0) r = Read(rows + (uintptr_t)bi * AT_ROW + AT_HOLDER, word, sizeof word);
    if (r != 0) return r;
    if (U32(word) != U32(avatar + 8)) return CHP_PACK_NOT_ATTACHED;
    L.attach = attach;
    L.attach_rows = rows;
    L.owner_at = rows + (uintptr_t)bi * AT_ROW + AT_HOLDER;
    return 0;
}

/* S.down, S.active and S.flight from the avatar's movement flags, the pack's five state bytes and the Jump action. */
static int PackState(const VpmAvatar* a, uintptr_t states, uint32_t ji)
{
    uint8_t flags[24], state[5], input[32];
    int r = Read(a->manager + AM_FLAGS + (uintptr_t)a->index * AM_FLAGS_STRIDE + AM_FLAGS_AT, flags, sizeof flags);
    if (r == 0) r = Read(states + (uintptr_t)ji * 5u, state, sizeof state);
    if (r != 0) return r;
    for (int i = 0; i < 5; i++)
        if (state[i] > 1) return Fail("Unsupported pack flags");
    /* The native input helper maps the pair (2, 15) to slot 15; +8 is its held time. */
    r = Read(vpm_action_slot(a, VPM_ACTION_JUMP), input, sizeof input);
    if (r != 0) return r;
    float held;
    memcpy(&held, input + 8, 4);
    if (!(held >= 0.0f && held < 86400.0f)) return Fail("Invalid jump input"); /* a NaN fails both */
    uint32_t moving = U32(flags + 12), body = U32(flags + 8);
    S.down = held > 0.0f;
    S.active = state[0] == 1;
    S.flight = S.active && state[1] == 0 && state[4] == 1 && (moving & 4u) != 0 && (moving & 0x30u) == 0 &&
               (body & 0x80000000u) == 0;
    return 0;
}

static void Identify(const uint8_t* avatar, const uint8_t* entity, uintptr_t jm, uint32_t pack_id)
{
    memcpy(S.key.avatar, avatar, 24);
    memcpy(S.key.entity, entity, 24);
    S.key.manager = jm;
    S.manager = jm;
    S.pack = pack_id;
}

/* Everything from the registry roots down, keeping the layout as it goes. */
static int Resolve(void)
{
    uint8_t avatar[24], entity[24];
    uint32_t unit = 0, pack_id = 0;
    Forget();
    int r = LocalUnit(&unit);
    if (r == 0) r = AvatarRecord(unit, avatar);
    if (r == 0) r = AvatarSlot(avatar);
    if (r == 0) r = Backpack(avatar, &pack_id);
    if (r == 0) r = JumpPack(pack_id, entity);
    if (r == 0) r = Attached(pack_id, avatar);
    if (r == 0) r = ReadPointer(L.jm + JM_STATES, &L.states);
    if (r == 0) r = PackState(&L.a, L.states, L.ji);
    if (r != 0) return r;
    L.stage = 4;
    Identify(avatar, entity, L.jm, pack_id);
    return CHP_VALID;
}

/* ---- kept layout ------------------------------------------------------------------------------------------------- */

static int CheckAvatar(uint8_t* avatar)
{
    uint8_t word[4], block[AM_BLOCK + 7u * 8u];
    uint32_t ai = L.a.index;
    int r = Read(L.pm + PM_UNIT, word, sizeof word);
    if (r != 0) return r;
    if (U32(word) != L.unit) return DIFFERS;
    r = Read(L.avatar, avatar, 24);
    if (r != 0) return r;
    if (memcmp(avatar, L.a.record, 24) != 0) return DIFFERS;
    /* The count (+0x6C) through the avatar's entity pointer (+0x110 + 8 ai) in one read. */
    r = Read(L.a.manager + AM_COUNT, block, AM_BLOCK + (size_t)ai * 8u);
    if (r != 0) return r;
    if (U32(block) > 8 || ai >= U32(block) || !Holds(block + AM_SLOT_IN_BLOCK + ai * 8u, L.a.entity)) return DIFFERS;
    return 0;
}

static int CheckEquipment(uint32_t* pack_id)
{
    uint8_t block[24], word[8];
    int r = Read(L.eq + EQ_IDS, block, sizeof block); /* the identity (+64) and row (+80) arrays */
    if (r != 0) return r;
    if (!Holds(block, L.eq_ids) || !Holds(block + 16, L.eq_rows)) return DIFFERS;
    r = Read(L.eq_ids + (uintptr_t)L.qi * 8u, word, 8);
    if (r != 0) return r;
    if (!Holds(word, L.eq_slot)) return DIFFERS;
    r = Read(L.pack_at, word, 4);
    if (r != 0) return r;
    *pack_id = U32(word);
    return 0;
}

static int StillNoJumpPack(const uint8_t* block, uint32_t pack_id)
{
    int found = 0;
    uint32_t index;
    int r = Lookup(block + 16, pack_id, 128u, &found, &index);
    if (r != 0) return r;
    return found ? DIFFERS : CHP_NO_JUMP_PACK;
}

static int CheckPack(uint32_t pack_id, uint8_t* entity)
{
    uint8_t block[JM_BLOCK], word[8];
    int r = Read(L.jm + JM_COUNTS, block, sizeof block); /* counts (+16), map (+32), entries (+56), states (+80) */
    if (r != 0) return r;
    if (!L.has_ji) return StillNoJumpPack(block, pack_id);
    uint32_t total = U32(block), owned = U32(block + 4);
    if (owned > total || total > 64 || L.ji >= owned || !Holds(block + 40, L.jm_entries)) return DIFFERS;
    r = Read(L.jm_entries + (uintptr_t)L.ji * 8u, word, 8);
    if (r != 0) return r;
    if (!Holds(word, L.entity)) return DIFFERS;
    r = Read(L.entity, entity, 24);
    if (r != 0) return r;
    if (memcmp(entity, L.ew, 24) != 0) return DIFFERS;
    if (!L.hover) return CHP_NOT_HOVER_PACK;
    if (L.stage < 4 || !Holds(block + 64, L.states)) return DIFFERS;
    return 0;
}

static int CheckAttachment(const uint8_t* avatar)
{
    uint8_t word[8];
    int r = Read(L.attach + AT_ROWS, word, 8);
    if (r != 0) return r;
    if (!Holds(word, L.attach_rows)) return DIFFERS;
    r = Read(L.owner_at, word, 4);
    if (r != 0) return r;
    return U32(word) == U32(avatar + 8) ? 0 : DIFFERS;
}

/* The kept layout: S, a reason, an error, or DIFFERS. */
static int Warm(void)
{
    uint8_t avatar[24], entity[24];
    uint32_t pack_id = 0;
    int r = CheckAvatar(avatar);
    if (r != 0) return r;
    if (L.stage < 2) return DIFFERS;
    r = CheckEquipment(&pack_id);
    if (r != 0) return r;
    if (pack_id == 0 || pack_id == 0xFFFFFFFFu) return CHP_NO_BACKPACK;
    if (L.stage < 3 || pack_id != L.pack_id) return DIFFERS;
    r = CheckPack(pack_id, entity);
    if (r == 0) r = CheckAttachment(avatar);
    if (r == 0) r = PackState(&L.a, L.states, L.ji);
    if (r != 0) return r;
    Identify(avatar, entity, L.jm, pack_id);
    return CHP_VALID;
}

/* ---- the snapshot ------------------------------------------------------------------------------------------------ */

static int IsError(int r) { return r == CHP_WAITING_FOR_READ || r == CHP_WAITING_FOR_POINTER || r == CHP_WAITING_FOR_GAME_DATA; }

/* lint: per-frame */
int chp_snapshot(int fresh, const ChpSnapshot** out)
{
    *out = &S;
    g_reads = 0;
    g_error = NULL;
    int r = Mission();
    if (r != 0)
    {
        Forget();
        return r;
    }
    if (L.stage > 0 && !fresh)
    {
        r = Warm();
        if (r != DIFFERS)
        {
            if (IsError(r)) Forget();
            return r;
        }
        g_reads = 0;
    }
    r = Resolve();
    if (IsError(r)) Forget();
    return r;
}

const ChpSnapshot* chp_snapshot_last(void) { return &S; }
const char* chp_snapshot_error(void) { return g_error; }

int chp_snapshot_kept_row(uintptr_t* at)
{
    if (L.stage != 4) return 0;
    *at = L.states + (uintptr_t)L.ji * 5u;
    return 1;
}

void chp_snapshot_reset(void)
{
    memset(&L, 0, sizeof L);
    memset(&S, 0, sizeof S);
    g_reads = 0;
    g_error = NULL;
}
