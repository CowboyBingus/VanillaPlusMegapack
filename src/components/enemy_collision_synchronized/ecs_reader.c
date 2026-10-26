/* Enemy Collision Synchronized: a poll's scan (the Lua: corpse_data.lua scan_poll, in_mission, scan_manager,
 * manager_header, scan_entities, exhausted, visit, sync_count, inspect_listed, first_inspection, hand_over, world_for,
 * checked_world).
 *
 * The mission check: the mode block game.dll [0x33266A0] and its +8 flag (1 in a mission; 0 on the ship, where +0x40
 * stays 2, so that field is not a mission selector). In a mission both managers are scanned, the first alternating per
 * poll so neither starves the other: the ragdoll manager game.dll [0x3326948] and the corpse manager [0x3326920], each
 * header checked (count, active and capacity bounds, the owner partition), then its entity pointer array. The listing
 * names the entries holding a listed resource; from a rotating cursor they are visited within the poll's budget (128
 * entries, 4 inspections, a soft 1 ms from the first inspection, the clock read every 8 entries and after each
 * inspection). A ragdoll qualifies only when its sync count equals its profile's body count (one read covers up to 16
 * entries' counts at the 432-byte stride); a corpse waiting for its re-check is skipped. A qualifying entry's header is
 * read afresh: a changed one is skipped and classified again. Each inspected unit goes to EcsConsume once the
 * manager's slot and header still hold.
 *
 * On HellForge the slots are plain loads (inside game.dll's image), where the Lua copied them with ReadProcessMemory.
 * The entity spawn event (HF_ON_SPAWN) is not used to find candidates: the managers hold an entity from its death
 * (ragdoll) or conversion (corpse) on, which a spawn event does not report, so it is not equivalent to this scan. */
#include <stdio.h>
#include <string.h>
#include "ecs_internal.h"

#define RAGDOLL_SLOT_RVA 0x3326948u   /* game.dll: the ragdoll (RagdollSync) manager */
#define CORPSE_SLOT_RVA 0x3326920u    /* game.dll: the corpse manager */
#define WORLD_SLOTS_RVA 0x27BA8A8u    /* exe: physics world references, 176 bytes apart (worlds 0 .. 3) */
#define BODY_GETTER_RVA 0xD0CFA0u     /* exe: the body getter the corpse reader's path uses (world vtable +136) */
#define MANAGER_HEADER 88u
#define SYNC_STRIDE 432u
#define SYNC_WINDOW 16u
#define CLOCK_EVERY 8u

static struct
{
    uint64_t mode_slot;
    uintptr_t mode;
    uint8_t mode_bytes[0x44];
    int corpse, preflight_due;
    uintptr_t manager, entities, runtime, sync;
    uint32_t count, active;
    uint8_t header[MANAGER_HEADER];
    int window;                          /* sync counts copied this poll after the last inspection */
    uint32_t window_first, window_last;
    uint32_t window_counts[SYNC_WINDOW];
    int world_known[4];
    uintptr_t worlds[4];
    EcsGuards globals;                   /* the manager's slot and header */
    EcsGuard global_items[2];
    uint8_t global_bytes[8 + MANAGER_HEADER];
} r;

static uint64_t g_pointers[ECS_MAX_RAGDOLLS];
static uint8_t g_window[(SYNC_WINDOW - 1u) * SYNC_STRIDE + 4u];
static EcsUnit g_unit;

void EcsReaderBegin(void)
{
    memset(&r, 0, sizeof r);
    EcsGuardsInit(&r.globals, r.global_items, 2, r.global_bytes, sizeof r.global_bytes);
    EcsInspectBegin();
}

/* ---- the physics world (the corpse reader's getter path, checked before any unit's bodies) ------------------------ */

static int CheckedWorld(uint32_t index, uintptr_t* out)
{
    uint64_t reference = 0;
    *out = 0;
    if (!EcsImageRead(vpm_exe() + WORLD_SLOTS_RVA + 176u * index, &reference, 8)) return EcsRaise("Data unavailable");
    if (reference == 0) return 1;
    uintptr_t world = EcsPointer(reference);
    if (world == 0) return EcsRaise("Physics world unavailable");
    const uint8_t* bytes = EcsCached(world, 8, 0);
    if (bytes == NULL) return 0;
    uintptr_t vtable = EcsPointer(EcsU64(bytes));
    if (vtable == 0) return EcsRaise("Physics vtable unavailable");
    if ((bytes = EcsCached(vtable + 136u, 8, 0)) == NULL) return 0;
    uintptr_t getter = EcsPointer(EcsU64(bytes));
    if (getter == 0) return EcsRaise("Physics getter unavailable");
    int64_t offset = (int64_t)(getter - vpm_exe());
    if (offset != BODY_GETTER_RVA)
    {
        Ecs.getter_failures++;
        EcsRaisef("Body getter changed: world_index=%u world=%llu vtable=%llu actual=%llu expected=%llu offset=%lld", index,
            (unsigned long long)world, (unsigned long long)vtable, (unsigned long long)getter,
            (unsigned long long)(vpm_exe() + BODY_GETTER_RVA), (long long)offset);
        snprintf(Ecs.last_getter_failure, sizeof Ecs.last_getter_failure, "%s", EcsWhy());
        return 0;
    }
    Ecs.getter_checks++;
    *out = world;
    return 1;
}

int EcsWorldFor(uint32_t index, uintptr_t* world)
{
    if (index >= 4u) return EcsRaise("Physics world unavailable");
    if (r.world_known[index])
    {
        if (r.worlds[index] != 0) Ecs.getter_checks++;
        *world = r.worlds[index];
        return 1;
    }
    if (!CheckedWorld(index, world)) return 0;
    r.world_known[index] = 1;
    r.worlds[index] = *world;
    return 1;
}

/* ---- the mission and the managers -------------------------------------------------------------------------------- */

static int InMission(int* in)
{
    *in = 0;
    Ecs.mission_flag = Ecs.mode_field_40 = 0;
    r.mode_slot = vpm_game_u64(ECS_MODE_SLOT_RVA);
    r.mode = EcsPointer(r.mode_slot);
    Ecs.mode = r.mode;
    if (r.mode == 0) return 1;
    if (!EcsRead(r.mode, r.mode_bytes, sizeof r.mode_bytes)) return 0;
    Ecs.mission_flag = EcsU32(r.mode_bytes + 8);
    Ecs.mode_field_40 = EcsU32(r.mode_bytes + 0x40);
    *in = Ecs.mission_flag != 0;
    return 1;
}

static int ManagerHeader(void)
{
    uint32_t rva = r.corpse ? CORPSE_SLOT_RVA : RAGDOLL_SLOT_RVA;
    uint64_t slot = vpm_game_u64(rva);
    EcsGuardsClear(&r.globals);
    if (!EcsGuardAdd(&r.globals, vpm_game() + rva, &slot, 8)) return 0;
    if ((r.manager = EcsPointer(slot)) == 0) return EcsRaise("Pointer unavailable");
    Ecs.managers[r.corpse] = r.manager;
    if (!EcsGuardRead(&r.globals, r.manager, r.header, MANAGER_HEADER)) return 0;
    uint32_t capacity = EcsU32(r.header + (r.corpse ? 16 : 4)), count = EcsU32(r.header + (r.corpse ? 24 : 12));
    r.active = EcsU32(r.header + (r.corpse ? 28 : 16));
    if (r.corpse) Ecs.corpse_count = count;
    else Ecs.ragdoll_count = count;
    if (!(r.active <= count && count <= capacity && capacity <= 8192u && count <= (r.corpse ? ECS_MAX_CORPSES : ECS_MAX_RAGDOLLS)))
        return EcsRaise("Manager bounds changed");
    if (!r.corpse && EcsU32(r.header + 20) > r.active) return EcsRaise("Owner partition changed");
    r.count = count;
    return 1;
}

/* ---- the budget -------------------------------------------------------------------------------------------------- */

/* The clock is read every CLOCK_EVERY visited entries and after every inspection, and only once the poll's first
 * inspection set the deadline: a poll that inspects nothing reads no clock. The deadline stays soft. */
static int Exhausted(void)
{
    if (Ecs.budget.yielded || Ecs.budget.scanned >= ECS_MAX_ENTITIES || Ecs.budget.inspected >= ECS_MAX_UNITS) return 1;
    if (Ecs.budget.scanned == 0 || !Ecs.budget.deadline_set) return 0;
    if (Ecs.budget.scanned % CLOCK_EVERY != 0 && Ecs.budget.inspected == Ecs.budget.clocked) return 0;
    Ecs.budget.clocked = Ecs.budget.inspected;
    return EcsClock() >= Ecs.budget.deadline;
}

/* The poll's first inspection sets its deadline and runs the read-only preflight: the getter path the corpse reader
 * uses, checked before any unit's bodies. World 2 hosts the enemy actors; its absence while loading is normal. */
static int FirstInspection(void)
{
    if (!Ecs.budget.deadline_set)
    {
        Ecs.budget.deadline = EcsClock() + ECS_BUDGET_SECONDS;
        Ecs.budget.deadline_set = 1;
    }
    if (!r.preflight_due) return 1;
    r.preflight_due = 0;
    Ecs.preflight = "checking";
    uintptr_t world = 0;
    if (!EcsWorldFor(2, &world)) return 0;
    Ecs.preflight = world != 0 ? "verified" : "waiting_for_world";
    return 1;
}

/* ---- visiting the listed entries --------------------------------------------------------------------------------- */

/* A ragdoll's sync count at index: 1 with *count, 0 unreadable. One read copies the counts of up to SYNC_WINDOW entries
 * from index on (only as many as this poll may still visit); an inspection discards them. */
static int SyncCount(uint32_t index, uint32_t* count)
{
    if (r.window && index >= r.window_first && index <= r.window_last)
    {
        *count = r.window_counts[index - r.window_first];
        return 1;
    }
    uint32_t n = r.count - index;
    if (n > SYNC_WINDOW) n = SYNC_WINDOW;
    if (n > ECS_MAX_ENTITIES - Ecs.budget.scanned + 1u) n = ECS_MAX_ENTITIES - Ecs.budget.scanned + 1u;
    uintptr_t at = r.sync + (uintptr_t)index * SYNC_STRIDE;
    if (n > 1 && vpm_read(at, g_window, (size_t)(n - 1u) * SYNC_STRIDE + 4u))
    {
        for (uint32_t k = 0; k < n; k++) r.window_counts[k] = EcsU32(g_window + k * SYNC_STRIDE);
        r.window = 1;
        r.window_first = index;
        r.window_last = index + n - 1u;
        *count = r.window_counts[0];
        return 1;
    }
    return vpm_read_u32(at, count);
}

/* Whether the corpse at this entry waits for its next re-check: its unit's backoff record names this address and is not
 * due. */
static int BackedOff(const EcsEntry* entry)
{
    const EcsCheck* check = entry->has_unit ? EcsTableFind(&EcsChecks, entry->unit) : NULL;
    return check != NULL && check->address == entry->address && Ecs.fling_scan < check->due;
}

/* A unit inspected in full goes to EcsConsume once the manager's slot and header still hold. */
static int HandOver(EcsUnit* unit)
{
    if (!EcsSame(&r.globals) || !EcsGuardAppend(&unit->guards, &r.globals))
    {
        EcsTableRemove(&EcsHistories, unit->unit);
        Ecs.skipped++;
        vpm_log_detail(Ecs.self, "%s unit %08X skipped: the %s manager changed during its inspection",
            EcsProfiles[unit->profile].name, unit->unit, r.corpse ? "corpse" : "ragdoll");
        return 1;
    }
    /* Its own guards were verified by the inspection and the manager's just now, with no native call since. */
    unit->verified = 1;
    return EcsConsume(unit);
}

static int InspectListed(const EcsEntry* entry, uint32_t index, const uint8_t* header, int profile, uint32_t quick)
{
    if (!FirstInspection()) return 0;
    Ecs.budget.inspected++;
    EcsVisit visit = {index, quick, r.active, r.corpse, profile, entry->address, r.manager, r.entities, r.runtime, r.sync,
        r.mode, header, g_pointers[index], r.mode_slot, r.mode_bytes};
    int result = EcsInspect(&visit, &g_unit);
    /* The inspection read memory and its commands may change the game: the next entry's sync count is read afresh. */
    r.window = 0;
    if (result > 0) return HandOver(&g_unit);
    if (result < 0)
    {
        Ecs.skipped++;
        /* The same reason poll after poll is one line: logged on a change. */
        if (vpm_detailed() && strcmp(Ecs.last_skip, EcsWhy()) != 0)
            vpm_log_detail(Ecs.self, "%s unit %08X skipped: %s", EcsProfiles[profile].name, EcsU32(header + 12), EcsWhy());
        snprintf(Ecs.last_skip, sizeof Ecs.last_skip, "%s", EcsWhy());
    }
    EcsTableRemove(&EcsHistories, EcsU32(header + 12));
    return 1;
}

/* A listed entry: the cheap lifecycle check (ragdolls: the sync count), then a fresh header for an eligible one. A header
 * that no longer matches the listing is skipped this poll and classified afresh by the next rebuild. 1, or 0 raised. */
static int Visit(EcsListing* listing, uint32_t index)
{
    uint64_t address = EcsAddressAt(g_pointers, index);
    EcsEntry* entry = address != 0 ? EcsListingFind(listing, address) : NULL;
    if (entry == NULL || entry->key < 0) return 1;
    int profile = entry->key;
    if (r.corpse && BackedOff(entry)) { Ecs.corpse_rechecks_deferred++; return 1; }
    uint32_t quick = 0;
    if (!r.corpse && (!SyncCount(index, &quick) || quick != EcsProfiles[profile].bodies))
    {
        if (entry->has_unit) EcsTableRemove(&EcsHistories, entry->unit);
        return 1;
    }
    uint8_t header[24];
    int fresh = vpm_read((uintptr_t)address, header, sizeof header) ? EcsProfileOf(EcsU64(header)) : -1;
    if (fresh != profile)
    {
        entry->key = ECS_UNKNOWN;
        listing->kept_valid = 0;
        Ecs.listing_changes++;
        return 1;
    }
    return InspectListed(entry, index, header, profile, quick);
}

/* The first listed position whose entry index is at or after cursor (wrapping to the first). */
static uint32_t ListedFrom(const EcsListing* listing, uint32_t cursor)
{
    uint32_t low = 0, high = listing->n - 1u;
    while (low < high)
    {
        uint32_t middle = (low + high) / 2u;
        if (listing->listed[middle] < cursor) low = middle + 1u;
        else high = middle;
    }
    return listing->listed[low] < cursor ? 0 : low;
}

/* The manager's listed entries from its rotating cursor, within the poll's budget. */
static int ScanEntities(EcsListing* listing)
{
    uint32_t n = listing->n;
    if (n == 0) return 1;
    uint32_t* cursor = &Ecs.cursors[r.corpse ? 1 : 0];
    uint32_t first = ListedFrom(listing, *cursor % r.count);
    for (uint32_t step = 0; step < n; step++)
    {
        if (Exhausted()) { Ecs.budget.yielded = 1; break; }
        uint32_t index = listing->listed[(first + step) % n];
        *cursor = (index + 1u) % r.count;
        Ecs.budget.scanned++;
        if (!Visit(listing, index)) return 0;
    }
    return 1;
}

static int ScanManager(int corpse, int first)
{
    r.corpse = corpse;
    if (!ManagerHeader()) return 0;
    r.window = 0;
    EcsListing* listing = EcsListingOf(corpse);
    if (r.count == 0) return 1;
    r.entities = EcsPointer(EcsU64(r.header + (corpse ? 64 : 56)));
    r.runtime = EcsPointer(EcsU64(r.header + 72));
    r.sync = EcsPointer(EcsU64(r.header + 80));
    if (r.entities == 0 || r.runtime == 0 || r.sync == 0) return EcsRaise("Pointer unavailable");
    if (!EcsRead(r.entities, g_pointers, (size_t)r.count * 8u)) return 0;
    EcsListingRefresh(listing, g_pointers, r.count, first);
    return ScanEntities(listing);
}

int EcsScanPoll(int* ready)
{
    int in = 0;
    *ready = 0;
    if (!InMission(&in)) return 0;
    if (!in)
    {
        Ecs.preflight = "waiting_for_mission";
        return 1;
    }
    /* The getter preflight runs before the poll's first inspection: a poll that inspects nothing makes none of it. */
    r.preflight_due = 1;
    if (Ecs.preflight == NULL || strcmp(Ecs.preflight, "waiting_for_mission") == 0) Ecs.preflight = "waiting_for_unit";
    Ecs.manager_turn = !Ecs.manager_turn;
    int corpseFirst = !Ecs.manager_turn;
    if (!ScanManager(corpseFirst, 1) || !ScanManager(!corpseFirst, 0)) return 0;
    *ready = 1;
    return 1;
}
