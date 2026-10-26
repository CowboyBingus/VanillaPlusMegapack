/* Laser Sentry Cooldown v1.1.1 (Lua: components/LaserSentryCooldown/src/laser_sentry_cooldown.lua), build 25480438.
 *
 * The A/LAS-98 Laser Sentry builds heat while it fires. At max heat the base game loses it, through two entries of its
 * WeaponHeatComponent record: needs_reload_after_overheat = 1 with 0 spare heat sinks (+0x90: the engine never cools an
 * overheated sentry, WeaponHeat update 0x762F60) and overheat_ability = 2866 (+0x248: the WeaponHeat presentation
 * 0x763780 plays that ability, whose script queues explosion type 190 at the sentry about 0.8 s later). This changes the
 * record once per session: needs_reload_after_overheat 0, the Quasar Cannon's rule, so an overheated sentry cools at
 * temp_loss_per_second_overheated (+0x8C), set to the record's own idle cooling rate (+0x80, 5 heat/s: about 50 s from
 * max heat 250), and fires again once cold; overheat_ability 0, so nothing explodes. The overheat sounds and voice line
 * stay. The turret's AI (behavior 308) switches itself off for good at an overheat (state 6, which has no update), so a
 * turret watch looks every 120 frames for Laser Sentries this machine runs that have cooled down, and asks the game to
 * power their turret up again through the behavior's pending state request (state 7, block +12): the behavior manager
 * applies it before the sentry's next behavior update (0x843040 -> 0x4962C0 -> 0x48EE50 -> 0x32B6B0).
 *
 * On HellForge: the record is found by identity, HfApi.component_record("WeaponHeatComponentData", the Laser Sentry's
 * resource), at HF_EVENT_ENTITIES_READY. It reads the table the Lua read ([[game + 0x346BF98] + 0xF12CC8], the entity
 * state's table of component 266) with the same checks (the block's header, one owner of the resource, the bounds) and
 * also refuses a record other entities share. The event replaces the Lua's boot poll (every 30 frames until the table
 * existed). +0x8C and +0x90 are mapped fields (cool_per_second_overheated, prevent_overheat_cooling): they are changed
 * with set_live, HellForge's live edit (applied at once, as the Lua's write; reported if another mod edits them; undone
 * with a NULL value), after the Lua's checks of the whole record. +0x248 is not mapped: it is written through HfApi.write
 * on the read-only page (HellForge changes the protection for the write, as the Lua's VirtualProtectEx pair did), or with
 * a plain store on a read-write one. The Lua's page check stays: one VirtualQuery over the span before any write
 * (committed private memory, read-only or read-write, inside one region), and one read-back of the span after. If the
 * game reloads its entity data (HF_EVENT_ENTITIES_READY again), HellForge renews the two live edits and the ability is
 * the game's again: the record then counts as unchanged and the change is written again (the Lua never saw a reload).
 * The turret watch and the power-up request are the Lua's, 1:1. HF_ON_SPAWN is not used to find the sentries: it gives
 * the spawn's authority byte once, where the Lua reads the entity record's owned and simulated bits when a sentry
 * overheats and again before the request, so it would not follow a change of owner; the overheated flags still need the
 * WeaponHeat manager's reads. Dropped on purpose: the update guard's pause and resume (an update below the Lua failed:
 * the core's guard stops only the component that faulted), the shutdown note, the loader check, the LuaJIT notes and
 * the live test build's turret log (test_hooks.lua).
 *
 * COST. Idle frames (every frame but one in 120): a frame counter; no read, no Windows call, no allocation (the Lua: the
 * same, under its update guard). One frame in 120, the turret watch's look (reads are HfApi.read, ReadProcessMemory):
 *   menus (no WeaponHeat manager)                0 reads (its pointer is a plain load in game.dll; the Lua: 1 read)
 *   the ship (a manager without instances)       1 read (the Lua: 2)
 *   a mission, nothing overheated                2 reads (the Lua: 3)
 *   a newly overheated weapon                    + 1 read of every record pointer, + 1 per new one (the Lua: the same)
 *   a watched sentry still hot                   3 reads (the Lua: 4)
 *   a cooled sentry run here (once per overheat) 9 reads, 1 VirtualQuery, a 4-byte store, 1 log line (the Lua: 11 reads,
 *                                                1 VirtualQuery, 1 WriteProcessMemory)
 * Once per session, at HF_EVENT_ENTITIES_READY: component_record, 1 read of the record (588 bytes), 1 VirtualQuery, 2
 * set_live, 1 HfApi.write (4 bytes; a plain store on a read-write page), 1 read-back (448 bytes), 1 log line: 2 reads by
 * the component (the Lua: 6 reads, 1 VirtualQuery, 2 VirtualProtectEx, 2 WriteProcessMemory). HellForge's lookups and
 * writes inside component_record and set_live come on top (each lookup reads the table's 58 index rows; each write is a
 * VirtualProtect pair and an instruction-cache flush): the price of editing the mapped fields through HellForge's live
 * edits, once per session, never per frame. A stop (the core stopping the component) undoes it the same way: 1
 * VirtualQuery, 2 set_live, 1 write, 1 read-back. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "../../core/vpm.h"

#define COMPONENT "WeaponHeatComponentData"
#define SENTRY HF_ENTITY_ALAS98_LASER_SENTRY /* content/fac_helldivers/hellpod/laser_cannon_turret/laser_cannon_turret */
#define RESOURCE_LOW 0xCFFFA8A8u              /* its two 32-bit halves, as entity records hold them */
#define RESOURCE_HIGH 0x56070F36u
#define RECORD_SIZE 592u                      /* WeaponHeatComponent */
#define OVERHEAT_TEMPERATURE 250
#define IDLE_COOLING_OFFSET 0x80u             /* temp_loss_per_second: the cooling rate when idle */
#define COOLING_OFFSET 0x8Cu                  /* temp_loss_per_second_overheated (f32), needs_reload_after_overheat (u8) */
#define COOLING_SIZE 5u
#define ABILITY_OFFSET 0x248u                 /* overheat_ability (u32) */
#define ABILITY_SIZE 4u
#define INSPECT_SIZE (ABILITY_OFFSET + ABILITY_SIZE)        /* 588: the record through the overheat ability */
#define SPAN_SIZE (ABILITY_OFFSET + ABILITY_SIZE - COOLING_OFFSET) /* 448: both changed ranges and the bytes between */

#define WATCH_FRAMES 120u /* an overheat lasts about 50 s: a look every 2 s at 60 frames per second sees every one */
#define HEAT_MANAGER_RVA 0x3326D48u     /* WeaponHeat manager: +20 instances, +64 entity records, +88 states (12 bytes) */
#define BEHAVIOR_MANAGER_RVA 0x3326740u /* behavior manager (world + 0xEEBA08, set by 0x568230) */
#define BEHAVIOR_ID 308u
#define BEHAVIOR_SIZE 504u              /* +0 behavior id, +8 state, +12 pending state request, +16 last state set */
#define STATE_STUCK 6u
#define STATE_POWER_UP 7u
#define NO_REQUEST 0xFFFFFFFFu
#define MAX_INSTANCES 160u              /* heat instances one look covers */
#define MAX_PROBES 64u
#define MAX_MAP (1u << 26)
#define MAX_OTHERS 256
#define MAX_WATCHED (2 * MAX_INSTANCES) /* the last look's sentries and this look's new ones */
#define WHY_SIZE 160

#define VANILLA 1
#define PATCHED 2

_Static_assert(offsetof(HfWeaponHeat, cool_per_second) == IDLE_COOLING_OFFSET, "the mapped idle cooling rate");
_Static_assert(offsetof(HfWeaponHeat, cool_per_second_overheated) == COOLING_OFFSET, "the mapped overheated cooling rate");
_Static_assert(offsetof(HfWeaponHeat, prevent_overheat_cooling) == COOLING_OFFSET + 4, "the mapped reload flag");
_Static_assert(sizeof(HfWeaponHeat) == RECORD_SIZE, "the mapped record size");

static const HfField kCoolingField = HF_FIELD(WeaponHeat, cool_per_second_overheated);
static const HfField kReloadField = HF_FIELD(WeaponHeat, prevent_overheat_cooling);

/* Every record value the change relies on, with its vanilla value. */
typedef struct Expected { uint32_t offset, size, value; } Expected;
static const Expected kExpected[] = {
    {0x50, 1, 1},           /* overheating is enabled for this weapon */
    {0x54, 4, 0},           /* magazines (spare heat sinks at deployment) */
    {0x5C, 4, 0},           /* magazines_max */
    {0x60, 4, 0x437A0000u}, /* overheat_temperature 250.0 */
    {0x64, 4, 0},           /* overheat_temperature_recover 0.0: the sentry cools all the way down */
};
static const uint8_t kCoolingVanilla[COOLING_SIZE] = {0x00, 0x00, 0xC8, 0x43, 0x01}; /* 400.0f (never used), then 1 */
static const uint8_t kAbilityVanilla[ABILITY_SIZE] = {0x32, 0x0B, 0x00, 0x00};       /* 2866: the self-destruct */
static const uint8_t kAbilityNone[ABILITY_SIZE] = {0, 0, 0, 0};

typedef struct Watched { uint32_t id; uintptr_t pointer; } Watched;      /* a Laser Sentry run here, overheated */
typedef struct Other { uintptr_t pointer; uint32_t generation; } Other;  /* another overheated weapon, skipped */

static struct
{
    uintptr_t record;            /* the Laser Sentry's WeaponHeat record, once found */
    float rate;                  /* its idle cooling rate */
    uint8_t cooling[COOLING_SIZE]; /* the change at 0x8C: that rate, then 0 */
    int live[2];                 /* this session's live edits of 0x8C and 0x90 are in place */
    int wroteAbility;            /* this session wrote 0 at 0x248 */
    uint32_t frames;             /* frames since the last look */
    uint32_t generation;         /* looks so far */
    uint32_t repairs;
    int watchedCount;
    Watched watched[MAX_WATCHED];
    int othersCount;             /* insertions since the cache was last cleared (the Lua's others_count) */
    int othersUsed;
    Other others[MAX_OTHERS];
} s;

/* What one look read (scratch: each look fills them before use). */
static uint8_t g_states[12 * MAX_INSTANCES];
static uint8_t g_flags[MAX_INSTANCES];
static uint64_t g_pointers[MAX_INSTANCES];

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t U64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static int Why(char* why, const char* text) { snprintf(why, WHY_SIZE, "%s", text); return 0; }

/* ---- writes, as the Lua's protected_write --------------------------------------------------------------------- */

/* The protection of [address, address + length) when it lies inside one committed private region and is read-only or
 * read-write, else 0 with *why. One VirtualQuery. */
static DWORD PrivateProtection(uintptr_t address, size_t length, char* why)
{
    MEMORY_BASIC_INFORMATION info;
    if (VirtualQuery((const void*)address, &info, sizeof info) != sizeof info) /* lint-ok: C4 on the frame that writes only: once per session, and once per cooled sentry */
        return Why(why, "page query failed");
    if (info.State != MEM_COMMIT || info.Type != MEM_PRIVATE)
    {
        snprintf(why, WHY_SIZE, "not committed private memory (state %#lx, type %#lx)", (unsigned long)info.State, (unsigned long)info.Type);
        return 0;
    }
    uintptr_t base = (uintptr_t)info.BaseAddress;
    if (address < base || address + length > base + info.RegionSize) return Why(why, "write would leave the region");
    if (info.Protect != PAGE_READWRITE && info.Protect != PAGE_READONLY)
    {
        snprintf(why, WHY_SIZE, "unexpected page protection %#lx", (unsigned long)info.Protect);
        return 0;
    }
    return info.Protect;
}

/* A plain store into read-write memory; HfApi.write (which makes the bytes writable for the write) into read-only. */
static int Store(uintptr_t address, const void* data, size_t size, DWORD protection)
{
    if (protection == PAGE_READWRITE)
    {
        memcpy((void*)address, data, size);
        return 1;
    }
    return vpm_hf()->write(address, data, size) == 0; /* lint-ok: C4 on the frame that writes only (a read-only page) */
}

/* The bytes at address, read back (one read), are data. */
static int ReadsBack(uintptr_t address, const void* data, size_t size)
{
    uint8_t now[8];
    return size <= sizeof now && vpm_read(address, now, size) && memcmp(now, data, size) == 0;
}

/* One range: the page checked, the store, the read-back. 1, or 0 with *why. */
static int ProtectedWrite(uintptr_t address, const void* data, size_t size, char* why)
{
    DWORD protection = PrivateProtection(address, size, why);
    if (protection == 0) return 0;
    if (!Store(address, data, size, protection)) return Why(why, "write failed");
    return ReadsBack(address, data, size) ? 1 : Why(why, "write did not read back");
}

/* ---- the heat record ------------------------------------------------------------------------------------------- */

/* Reads the record and checks it as the Lua's inspect did: VANILLA (the change is to be written), PATCHED (it is
 * there), or 0 with *why. renewing: this session's live edits are in place, so a cooling range holding them counts as
 * vanilla (the game reloaded its entity data; HellForge renewed them; the ability is the game's again). One read. */
static int Inspect(uintptr_t record, int renewing, char* why)
{
    uint8_t bytes[INSPECT_SIZE];
    if (!vpm_read(record, bytes, sizeof bytes)) return Why(why, "Laser Sentry heat record unreadable");
    for (size_t i = 0; i < sizeof kExpected / sizeof kExpected[0]; i++)
    {
        const Expected* e = &kExpected[i];
        if ((e->size == 1 ? bytes[e->offset] : U32(bytes + e->offset)) != e->value)
        {
            snprintf(why, WHY_SIZE, "unexpected Laser Sentry heat record (offset %#x)", e->offset);
            return 0;
        }
    }
    float rate;
    memcpy(&rate, bytes + IDLE_COOLING_OFFSET, 4);
    if (!(rate > 0 && rate < 1000)) return Why(why, "unexpected Laser Sentry cooling rate");
    s.rate = rate;
    memcpy(s.cooling, bytes + IDLE_COOLING_OFFSET, 4);
    s.cooling[4] = 0;
    int ours = memcmp(bytes + COOLING_OFFSET, s.cooling, COOLING_SIZE) == 0;
    int vanilla = memcmp(bytes + COOLING_OFFSET, kCoolingVanilla, COOLING_SIZE) == 0 || (renewing && ours);
    if (vanilla && memcmp(bytes + ABILITY_OFFSET, kAbilityVanilla, ABILITY_SIZE) == 0) return VANILLA;
    if (ours && memcmp(bytes + ABILITY_OFFSET, kAbilityNone, ABILITY_SIZE) == 0) return PATCHED;
    return Why(why, "Laser Sentry heat record already changed by something else");
}

/* A live edit of one mapped field of the Laser Sentry's record (value NULL undoes this session's). 1, or 0 with *why. */
static int LiveEdit(const HfField* field, const HfValue* value, char* why)
{
    if (vpm_hf()->set_live(vpm_mod(), SENTRY, field, value, 0) != 0) return 1;
    snprintf(why, WHY_SIZE, "write failed (HellForge: %s)", vpm_hf()->last_log(vpm_mod()));
    return 0;
}

/* Whether both ranges read back as cooling and ability, in one read of the span. */
static int SpanReadsBack(const uint8_t* cooling, const uint8_t* ability, char* why)
{
    uint8_t span[SPAN_SIZE];
    if (!vpm_read(s.record + COOLING_OFFSET, span, sizeof span) || memcmp(span, cooling, COOLING_SIZE) != 0 ||
        memcmp(span + (ABILITY_OFFSET - COOLING_OFFSET), ability, ABILITY_SIZE) != 0)
        return Why(why, "write did not read back");
    return 1;
}

/* The change: the span's page checked (one VirtualQuery), the two mapped fields as live edits, the ability, one
 * read-back of the span. 1, or 0 with *why (what landed is flagged for Undo). */
static int WriteChange(char* why)
{
    DWORD protection = PrivateProtection(s.record + COOLING_OFFSET, SPAN_SIZE, why);
    if (protection == 0) return 0;
    const HfValue rate = HF_F32(s.rate), cleared = HF_U8(0);
    if (!LiveEdit(&kCoolingField, &rate, why)) return 0;
    s.live[0] = 1;
    if (!LiveEdit(&kReloadField, &cleared, why)) return 0;
    s.live[1] = 1;
    if (!Store(s.record + ABILITY_OFFSET, kAbilityNone, ABILITY_SIZE, protection)) return Why(why, "write failed");
    s.wroteAbility = 1;
    return SpanReadsBack(s.cooling, kAbilityNone, why);
}

/* Puts back what this session changed (the live edits undone: HellForge writes their original back; the ability's
 * 2866), then one read-back of the span. One attempt, as the Lua's restore. 1, or 0 with *why. */
static int Undo(char* why)
{
    const int live[2] = {s.live[0], s.live[1]}, ability = s.wroteAbility;
    s.live[0] = s.live[1] = s.wroteAbility = 0;
    if (!live[0] && !live[1] && !ability) return 1;
    DWORD protection = PrivateProtection(s.record + COOLING_OFFSET, SPAN_SIZE, why);
    if (protection == 0) return 0;
    if (live[0] && !LiveEdit(&kCoolingField, NULL, why)) return 0;
    if (live[1] && !LiveEdit(&kReloadField, NULL, why)) return 0;
    if (ability && !Store(s.record + ABILITY_OFFSET, kAbilityVanilla, ABILITY_SIZE, protection)) return Why(why, "write failed");
    return SpanReadsBack(kCoolingVanilla, kAbilityVanilla, why);
}

/* The core stopping the component (a fault, or a refusal): the vanilla record back. */
static void Stop(VpmComponent* self)
{
    char why[WHY_SIZE];
    if (!Undo(why)) vpm_log(self, "restore failed: %s", why);
}

/* Refuses for the session. vpm_fail runs Stop once start() has returned; the direct call covers an entity data that
 * was ready before (it finds nothing left to undo after the first). */
static void Refuse(VpmComponent* self, const char* why)
{
    vpm_fail(self, "%s", why);
    Stop(self);
}

/* ---- the turret watch ------------------------------------------------------------------------------------------ */

/* The instance count of the WeaponHeat manager, with its entity record and state arrays, or 0. 1 read. */
static uint32_t HeatInstances(uintptr_t* records, uintptr_t* states)
{
    uintptr_t heat = (uintptr_t)vpm_game_u64(HEAT_MANAGER_RVA);
    uint8_t header[96];
    if (!vpm_plausible(heat) || !vpm_read(heat, header, sizeof header)) return 0;
    uint32_t count = U32(header + 20);
    if (count == 0 || count > MAX_INSTANCES) return 0;
    *records = (uintptr_t)U64(header + 64);
    *states = (uintptr_t)U64(header + 88);
    return count;
}

/* Every instance's overheated flag (state +8) into g_flags: the number set, or -1. 1 read. */
static int ReadFlags(uintptr_t states, uint32_t count)
{
    if (!vpm_plausible(states) || !vpm_read(states, g_states, 12 * (size_t)count)) return -1;
    int hot = 0;
    for (uint32_t i = 0; i < count; i++)
    {
        g_flags[i] = g_states[12 * i + 8];
        hot += g_flags[i] != 0;
    }
    return hot;
}

/* Every instance's entity record pointer into g_pointers. 1 read. */
static int ReadPointers(uintptr_t records, uint32_t count)
{
    return vpm_plausible(records) && vpm_read(records, g_pointers, 8 * (size_t)count);
}

/* 1 with *id when the record at pointer is a Laser Sentry whose behavior runs here (owned, bit 0, and simulated here,
 * bit 1 clear). 1 read. */
static int OwnedSentry(uintptr_t pointer, uint32_t* id)
{
    uint32_t words[6];
    if (!vpm_plausible(pointer) || !vpm_read(pointer, words, sizeof words)) return 0;
    if (words[0] != RESOURCE_LOW || words[1] != RESOURCE_HIGH || (words[5] & 3u) != 1u) return 0;
    *id = words[2];
    return 1;
}

static int WatchedByPointer(uintptr_t pointer)
{
    for (int i = 0; i < s.watchedCount; i++)
        if (s.watched[i].pointer == pointer) return 1;
    return 0;
}

static void Watch(uint32_t id, uintptr_t pointer)
{
    for (int i = 0; i < s.watchedCount; i++)
        if (s.watched[i].id == id) { s.watched[i].pointer = pointer; return; }
    if (s.watchedCount < MAX_WATCHED) s.watched[s.watchedCount++] = (Watched){id, pointer};
}

static Other* FindOther(uintptr_t pointer)
{
    for (int i = 0; i < s.othersUsed; i++)
        if (s.others[i].pointer == pointer) return &s.others[i];
    return NULL;
}

/* Another weapon, skipped while it stays overheated; the cache starts afresh after 256 insertions, as the Lua's. */
static void RememberOther(uintptr_t pointer)
{
    if (s.othersCount >= MAX_OTHERS) s.othersCount = s.othersUsed = 0;
    Other* other = FindOther(pointer);
    if (other == NULL) other = &s.others[s.othersUsed++];
    *other = (Other){pointer, s.generation};
    s.othersCount++;
}

/* Newly overheated instances: a Laser Sentry this machine runs is watched; anything else is skipped while it stays
 * overheated (its record is read again once it has cooled and overheats anew). 1 read per instance read. */
static void Track(uint32_t count)
{
    for (uint32_t i = 0; i < count; i++)
    {
        uintptr_t pointer = (uintptr_t)g_pointers[i];
        if (g_flags[i] == 0 || WatchedByPointer(pointer)) continue;
        Other* seen = FindOther(pointer);
        if (seen != NULL && seen->generation + 1 >= s.generation) { seen->generation = s.generation; continue; }
        uint32_t id;
        if (OwnedSentry(pointer, &id)) Watch(id, pointer);
        else RememberOther(pointer);
    }
}

static int IndexOf(uintptr_t pointer, uint32_t count)
{
    for (uint32_t i = 0; i < count; i++)
        if ((uintptr_t)g_pointers[i] == pointer) return (int)i;
    return -1;
}

static int PowerOfTwo(uint32_t value) { return value >= 1 && value <= MAX_MAP && (value & (value - 1)) == 0; }

/* The value of key id in an open-addressing map of {u32 key, u32 value} entries, probed as the engine does: from
 * (id * multiplier) & (capacity - 1), stopping at the empty key. 1 read per probe. */
static int MapValue(uintptr_t entries, uint32_t capacity, uint32_t empty, uint32_t multiplier, uint32_t id, uint32_t* value)
{
    uint32_t start = (id * multiplier) & (capacity - 1), probes = capacity < MAX_PROBES ? capacity : MAX_PROBES;
    for (uint32_t k = 0; k < probes; k++)
    {
        uint32_t row[2];
        if (!vpm_read(entries + 8u * ((start + k) & (capacity - 1)), row, sizeof row)) return 0;
        if (row[0] == empty) return 0;
        if (row[0] == id) { *value = row[1]; return 1; }
    }
    return 0;
}

/* The behavior manager, read at +48 (56 bytes): +52 instances, +64 entity id map (entries, then capacity, empty key and
 * multiplier at +72/+76/+80), +88 entity record pointers, +96 504-byte instance blocks. The block of the behavior that
 * runs entity id, whose record is at record, or 0 with *why. */
static uintptr_t NoBlock(char* why, const char* text)
{
    Why(why, text);
    return 0;
}

static uintptr_t BehaviorBlock(uint32_t id, uintptr_t record, char* why)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(BEHAVIOR_MANAGER_RVA);
    uint8_t m[56];
    if (!vpm_plausible(manager) || !vpm_read(manager + 48, m, sizeof m)) return NoBlock(why, "behavior manager unreadable");
    uint32_t count = U32(m + 4), capacity = U32(m + 24), index = 0;
    uintptr_t entries = (uintptr_t)U64(m + 16), records = (uintptr_t)U64(m + 40), blocks = (uintptr_t)U64(m + 48);
    if (!PowerOfTwo(capacity) || !vpm_plausible(entries) || !vpm_plausible(records) || !vpm_plausible(blocks))
        return NoBlock(why, "unexpected behavior manager");
    if (!MapValue(entries, capacity, U32(m + 28), U32(m + 32), id, &index) || index >= count) return NoBlock(why, "no behavior");
    if (vpm_ptr(records + 8u * (uintptr_t)index) != record) return NoBlock(why, "behavior of another entity");
    return blocks + (uintptr_t)BEHAVIOR_SIZE * index;
}

/* Asks the game to move the Laser Sentry behavior of entity id from state 6 to state 7: the pending state request,
 * written only while none is pending. 1, or 0 with *why. */
static int PowerUp(uint32_t id, uintptr_t record, char* why)
{
    uintptr_t block = BehaviorBlock(id, record, why);
    uint32_t words[5];
    if (block == 0) return 0;
    if (!vpm_read(block, words, sizeof words)) return Why(why, "behavior unreadable");
    if (words[0] != BEHAVIOR_ID) { snprintf(why, WHY_SIZE, "unexpected behavior %u", words[0]); return 0; }
    if (words[2] != STATE_STUCK) { snprintf(why, WHY_SIZE, "turret in state %u", words[2]); return 0; }
    if (words[3] != NO_REQUEST) { snprintf(why, WHY_SIZE, "turret state %u already requested", words[3]); return 0; }
    const uint32_t request = STATE_POWER_UP;
    return ProtectedWrite(block + 12, &request, sizeof request, why);
}

static void Repair(VpmComponent* self, uint32_t id, uintptr_t pointer)
{
    char why[WHY_SIZE];
    if (PowerUp(id, pointer, why))
    {
        s.repairs++;
        vpm_log(self, "Laser Sentry %u cooled down: its turret powers up again.", id);
    }
    else vpm_log(self, "Laser Sentry %u cooled down; its turret was left as it is (%s).", id, why);
}

/* Watched sentries: gone ones are dropped; cooled ones (overheated flag clear) are dropped and get their turret back
 * when their record still names them. */
static void Recover(VpmComponent* self, uint32_t count)
{
    int kept = 0;
    for (int i = 0; i < s.watchedCount; i++)
    {
        Watched w = s.watched[i];
        int index = IndexOf(w.pointer, count);
        uint32_t id;
        if (index >= 0 && g_flags[index] != 0) { s.watched[kept++] = w; continue; }
        if (index >= 0 && OwnedSentry(w.pointer, &id) && id == w.id) Repair(self, w.id, w.pointer);
    }
    s.watchedCount = kept;
}

/* One look: the WeaponHeat manager's header, every instance's state; with nothing overheated and nothing watched, that
 * is all. Else every record pointer, newly overheated instances, then the watched sentries. */
static void Look(VpmComponent* self)
{
    uintptr_t records = 0, states = 0;
    s.generation++;
    uint32_t count = HeatInstances(&records, &states);
    if (count == 0) { s.watchedCount = 0; return; }
    int hot = ReadFlags(states, count);
    if (hot < 0 || (hot == 0 && s.watchedCount == 0) || !ReadPointers(records, count)) return;
    if (hot > 0) Track(count);
    if (s.watchedCount > 0) Recover(self, count);
}

/* lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    if (++s.frames < WATCH_FRAMES) return;
    s.frames = 0;
    Look(self);
}

/* ---- the change at load ---------------------------------------------------------------------------------------- */

/* The record found by identity, checked, and the change written (or found in place); then the turret watch. */
static void EntitiesReady(VpmComponent* self, HfEvent event)
{
    char why[WHY_SIZE];
    uint32_t stride = 0;
    uintptr_t record = vpm_hf()->component_record(COMPONENT, SENTRY, &stride);
    if (record == 0) { Refuse(self, "Laser Sentry heat record not found"); return; }
    if (stride != RECORD_SIZE)
    {
        snprintf(why, WHY_SIZE, "unexpected Laser Sentry heat record size %u", stride);
        Refuse(self, why);
        return;
    }
    /* After a reload the record is a new one: the ability written into the old one went with it. */
    if (record != s.record) s.wroteAbility = 0;
    s.record = record;
    int found = Inspect(record, s.live[0] && s.live[1], why);
    if (found == 0) { Refuse(self, why); return; }
    if (found == VANILLA && !WriteChange(why)) { Refuse(self, why); return; }
    vpm_set_status(self, "active");
    vpm_log(self, "Laser Sentry heat record %s: an overheated Laser Sentry no longer explodes, cools at its own idle rate "
        "(%g heat/s, %g s from max heat %d at normal planet temperature) and fires again.", found == VANILLA ? "changed" :
        "already changed", (double)s.rate, OVERHEAT_TEMPERATURE / (double)s.rate, OVERHEAT_TEMPERATURE);
    if (vpm_ticking(self)) return;
    s.frames = 0;
    if (!vpm_tick_start(self, Tick)) vpm_log(self, "no game-thread tick: cooled turrets stay off");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    vpm_set_status(self, "waiting for the weapon data");
    return vpm_on_load(self, HF_EVENT_ENTITIES_READY, EntitiesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_laser_sentry_cooldown = {"laser_sentry_cooldown", "Laser Sentry Cooldown", "1.1.1", 0, Start, Stop};
