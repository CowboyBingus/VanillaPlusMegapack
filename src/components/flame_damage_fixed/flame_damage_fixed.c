/* Flame Damage Fixed v1.2 (Lua: components/FlameDamageFixed/src/flame_damage_fixed.lua), for build 25480438.
 *
 * Three fixes to the flame shared by the Lumberer's flamethrower arm and the Flame Sentry:
 *   1. Flame systems 0 and 3 spawn again. Their spawn-rate curves are keyed on normalized effect time (elapsed / effect
 *      lifetime) and step up at 0.3-0.9 % of it; the shared flame's lifetime is 1e10 s, so they never spawned. Their
 *      step keys are rescaled to the Cremator's real timing (64 s lifetime).
 *   2. The four main flame systems start at the Cremator's distances from the nozzle (1-4 m, not 7-15 m). Systems 0 and
 *      3 are not drawn (visualizer count 1 -> 0, like the game's invisible carrier system): they hit, but the flame
 *      looks like one stream.
 *   3. The flame no longer hits the weapon that fires it. From its first burst until it is gone, the weapon's own
 *      hit-boxes (the Lumberer's hull, arm and cannon; the Flame Sentry) share a private Havok system group with that
 *      weapon's flame particle systems, and members of that group skip each other. Every other body keeps its vanilla
 *      collision with the flame: no collision layer is changed.
 * Damage, fuel, heat and fire values are untouched, and other flamethrowers are not affected. flame_effect.c holds fixes
 * 1 and 2 (18 words in the loaded particles resource), flame_physics.c and flame_particles.c fix 3's reads and stores;
 * this file is the Lua's per-frame driver (Fix.new): the weapon scan every 0.5 s, burst starts, the burst's flame
 * instance, the body scan a few blocks per frame, and every check and release, with the same cadence and log lines.
 *
 * On HellForge: the same addresses, checks, stores and timing. Statics in game.dll's and the exe's images (the spray
 * manager, the world and resource roots, the filter, the unit registry, the group allocator) are plain loads; heap reads
 * go through vpm_read, and contiguous fields the Lua read one word at a time are read in one call (a 64-bit pointer is
 * one read, not two; a chain entry, a world header, a unit object, the effect, the spray entity list are one read each).
 * Stores are plain, into memory validated on the same frame: the effect with vpm_writable (the Lua's writable_data), the
 * bodies and particle systems with the Lua's writable_region check (one VirtualQuery per new committed private
 * read-write region, the region kept for the rest of that series of stores), which the core does not offer. HF_ON_SPAWN
 * is not used to find the weapons: it reports no removal and no spray-instance address, and whether the Lumberer's arm
 * passes the spawner HellForge hooks is unverified, so the Lua's 0.5 s spray-manager scan stays. The Lua's update-chain
 * guard (pause on an error below, restart) has no HellForge counterpart; its restore (the reset) runs as stop(). A later
 * improvement, not built: a detour of exe 0x80F200, where the engine registers every particle system with group 0, could
 * give a tracked weapon's flame systems its group as they are made, instead of finding the burst's instance afterwards.
 *
 * Cost per frame, in calls (the Lua's from tests/test_fix.lua's frame_budget pins, on the same synthetic world with two
 * tracked weapons and 21 + 3 own bodies in one span each):
 *   - Idle (no Lumberer arm or Flame Sentry): 0. Every 0.5 s of dt, the weapon scan: 1 plain load and 1 read (the Lua:
 *     3 reads); with spray components, + 1 read for their entity list and 1 per component (the Lua: + 4, + 3 per
 *     component and 2 per tracked one). No spray manager (the ship before one exists): 0 reads.
 *   - A tracked weapon present: 1 read per tracked weapon (as the Lua). The weapon scan with a grouped weapon: 10 reads
 *     (the Lua: 29 reads and 1 64 KB load). A family lookup (once per new weapon): 13 or 14 reads on one frame (the
 *     Lua: 45 or 49), then up to 4 block reads of 64 KB per frame (as the Lua).
 *   - Firing, and 1 s after: + 1 read per firing weapon, its burst's instance id (as the Lua: 3 in all here); until the
 *     instance is found, + 2 (the slot and its records; the Lua: 3 + 1 per instance).
 *   - A weapon's first burst: 37 reads, 1 vpm_writable (the effect, once per mission), 2 VirtualQuery (bodies, flame
 *     systems), 18 + 21 + 5 stores (the Lua: 202 reads + 2 loads, 1 writable_data, 2 writable_region, 44 writes). A
 *     later burst: 34 reads, 1 VirtualQuery, 5 stores (the Lua: 106 reads + 1 load, 1 writable_region, 5 writes).
 *   - The weapons leaving: 1 read per span, 1 VirtualQuery and a store per grouped body, once (3 reads, 2 VirtualQuery,
 *     24 stores; the Lua: 3 reads + 2 loads, 2 writable_region, 24 writes).
 * tests/components/flame_damage_fixed_test.c pins each of these. Nothing is allocated; the Lua's stores were
 * WriteProcessMemory calls, these are plain. */
#include <stdio.h>
#include <string.h>
#include "flame_damage_fixed.h"

#define SCAN_SECONDS 0.5    /* the weapon scan */
#define WATCH_SECONDS 1.0   /* keep looking for a burst's flame instance this long after the last firing frame */
#define RETRY_SECONDS 5.0   /* a failed family lookup is tried again after this long */
#define MAX_SPRAYS 128u
#define MAX_TRACKED 8
#define SCAN_BLOCKS 4
#define SPRAY_FIELDS 0x38u  /* spray manager: +0x38 count, +0x60 entities, +0x70 instances */
#define SPRAY_RECORD 0x218u /* a spray instance: state word +0, burst instance id +0x24 */
#define SPRAY_INSTANCE 0x24u
#define ARM_LO 0xD6328726u  /* the tracked spray weapons' entity resources (lo, hi): Lumberer flamethrower arm */
#define ARM_HI 0x0736BEE2u
#define SENTRY_LO 0xFE962858u /* Flame Sentry */
#define SENTRY_HI 0x820CC3BAu
#define FLAME FDF_FLAME_LAYER
#define TOLD_MAX 128
#define KEY_NO_GROUP 0x10000u /* told keys besides the reasons */
#define KEY_SKIPPED 0x20000u
#define KEY_DROPPED 0x30000u

typedef struct Weapon
{
    int used;
    uintptr_t address;   /* its spray instance */
    uint32_t handle;     /* its unit */
    const char* name;
    uint32_t state;      /* the state word read last frame (the Lua's last[address], kept per address) */
    int firing, started;
    FdfFamily family;
    FdfJob jobs[2];      /* jobs[current]: the last complete body scan; the other: the scan in progress */
    int current;
    int job_ok;          /* a body scan completed */
    double next_try;
    uint32_t group;      /* its private group, 0 for none */
    int marked, destroyed, awaiting, flames, announced;
    uint32_t instance;   /* its burst's flame instance id once found, 0 before */
} Weapon;

static struct
{
    VpmComponent* self;
    double clock, since_scan, watch_until;
    int watch;
    Weapon weapons[2 * MAX_TRACKED]; /* this scan's and the last one's, while a scan replaces them */
    int tracked[MAX_TRACKED];        /* weapons by spray order */
    int tracked_n;
    Weapon* scanning;                /* the weapon whose bodies are being scanned */
    uintptr_t slot, data, patched, filter;
    FdfReason self_hit_off;          /* why the self-hit fix is off for the session (FDF_OK: on) */
    uint32_t told[TOLD_MAX];
    int told_n;
} s;

static uint64_t g_entities[MAX_SPRAYS]; /* the spray manager's entity list as read at a scan */

/* ---- log lines -------------------------------------------------------------------------------------------------- */

static const char* const kReasons[FDF_REASON_COUNT] = {
    "", "resource manager unavailable", "resource type table unavailable", "particles type not registered",
    "particle name table unavailable", "flame effect not loaded", "flame effect pending", "unexpected effect record",
    "effect header changed", "effect layout changed", "effect memory not writable private data", "unknown value at",
    "effect verify failed at", "collision filter unavailable", "collision filter type changed", "flame layer row changed",
    "unit registry unavailable", "weapon unit not found", "unit unreadable", "family too large", "no physics world",
    "body array unreadable", "too many own bodies", "body memory not writable private data",
    "particle system not writable private data", "other bodies carry it", "the game's group allocator handed it out",
};

const char* fdf_reason_text(FdfReason reason, char* out, size_t size)
{
    uint32_t id = reason & 0xFFu, row = (reason >> 8) & 0xFFu;
    const char* text = id < FDF_REASON_COUNT ? kReasons[id] : "unknown";
    if ((id == FDF_UNKNOWN_VALUE || id == FDF_VERIFY_FAILED) && row < FDF_PATCH_COUNT)
        snprintf(out, size, "%s %u", text, fdf_patches[row].offset);
    else
        snprintf(out, size, "%s", text);
    return out;
}

/* Whether a line was logged before (and from now on it was). */
static int Told(uint32_t key)
{
    for (int i = 0; i < s.told_n; i++)
        if (s.told[i] == key) return 1;
    if (s.told_n < TOLD_MAX) s.told[s.told_n++] = key;
    return 0;
}

/* Once per reason (the Lua's tell_once): the reason is the key, whatever the prefix. */
static void TellOnce(FdfReason reason, const char* prefix)
{
    char text[64];
    if (!Told(reason)) vpm_log(s.self, "%s%s", prefix, fdf_reason_text(reason, text, sizeof text));
}

static void Disable(FdfReason reason)
{
    char text[64];
    s.self_hit_off = reason;
    vpm_log(s.self, "Self-hit fix disabled for this session: %s", fdf_reason_text(reason, text, sizeof text));
}

/* ---- weapons ---------------------------------------------------------------------------------------------------- */

static FdfJob* Job(Weapon* w) { return &w->jobs[w->current]; }
static FdfJob* ScanJob(Weapon* w) { return &w->jobs[w->current ^ 1]; }

/* A body of unit in group g is this mod's own when the weapon holding g has the unit in its family. */
static int OwnBody(uint32_t g, uint32_t unit)
{
    for (int i = 0; i < 2 * MAX_TRACKED; i++)
        if (s.weapons[i].used && s.weapons[i].group == g && fdf_in_family(&s.weapons[i].family, unit)) return 1;
    return 0;
}

/* The weapon's bodies leave its group (it is gone, or its vehicle was destroyed): 1, or 0 with *why. */
static int Release(Weapon* w, FdfReason* why)
{
    int ok = 1;
    if (w->marked && w->group != 0 && w->job_ok && fdf_unmark(Job(w), w->group, why) < 0)
    {
        ok = 0;
        TellOnce(*why, "Self-hit group not released: ");
    }
    w->marked = 0;
    return ok;
}

/* Flame systems of live instances still in the weapon's group go back to plain layer 11: 1, or 0 with *why. */
static int RestoreFlames(Weapon* w, uintptr_t slot, FdfReason* why)
{
    if (!(w->flames && w->group != 0 && slot != 0 && s.data != 0)) return 1;
    FdfRegion region = {0, 0};
    int restored = fdf_restore_flames(slot, s.data, &region, FLAME, FLAME + (w->group << FDF_GROUP_SHIFT), why);
    if (restored >= 0) w->flames = 0;
    return restored >= 0;
}

/* Group g can be this weapon's: no other weapon of this mod holds it, the weapon's latest complete body scan found no
 * other body in it, and the game's allocator still marks it free. */
static int Usable(Weapon* w, uint32_t g)
{
    for (int i = 0; i < 2 * MAX_TRACKED; i++)
        if (s.weapons[i].used && &s.weapons[i] != w && s.weapons[i].group == g) return 0;
    if (Job(w)->foreign[g - FDF_GROUP_LOW])
    {
        if (!Told(KEY_SKIPPED + g)) vpm_log(s.self, "Self-hit group %u not used: other bodies carry it", g);
        return 0;
    }
    return fdf_group_free(g);
}

/* Checked at every use of the weapon's group (each burst start, and every 0.5 s while grouped). */
static int StillOwn(Weapon* w, FdfReason* why)
{
    if (Job(w)->foreign[w->group - FDF_GROUP_LOW]) { *why = FDF_ON_BODIES; return 0; }
    if (!fdf_group_free(w->group)) { *why = FDF_IN_ALLOCATOR; return 0; }
    return 1;
}

/* The weapon's group is no longer this mod's alone: its bodies and flame systems leave it at once, and the next
 * grouping picks another free group, or none. A refused store turns the self-hit fix off for the session. 1 when
 * everything left it. */
static int DropGroup(Weapon* w, FdfReason why)
{
    uint32_t g = w->group;
    FdfReason reason = FDF_OK, failure = FDF_OK;
    int released = Release(w, &reason);
    int restored = RestoreFlames(w, w->flames && s.data != 0 ? fdf_flame_slot() : 0, &failure);
    w->group = 0;
    if (!(released && restored))
    {
        Disable(reason != FDF_OK ? reason : failure);
        return 0;
    }
    char text[64];
    if (!Told(KEY_DROPPED + g))
        vpm_log(s.self, "Self-hit group %u is no longer this mod's alone (%s): the %s's hit-boxes and flames left it.", g,
            fdf_reason_text(why, text, sizeof text), w->name);
    return 1;
}

/* Family and body scan for a weapon: the walk now, the scan over the next frames into the weapon's scan job, while the
 * last complete one stays in use. A walk or scan that fails is tried again after RETRY_SECONDS. */
static void BeginFamily(Weapon* w)
{
    FdfReason why = FDF_OK;
    if (fdf_family(w->handle, &w->family, &why) < 0 || !fdf_scan_begin(ScanJob(w), &why))
    {
        w->next_try = s.clock + RETRY_SECONDS;
        TellOnce(why, "Self-hit fix unavailable: ");
        return;
    }
    s.scanning = w;
}

/* A body that is no longer the one a grouped weapon's scan kept starts a new scan. */
static void RescanIfStale(Weapon* w, const FdfCounts* c)
{
    if (c->stale > 0 && s.scanning == NULL && s.clock >= w->next_try) BeginFamily(w);
}

/* A grouped weapon's bodies and group, on the weapon scan: a body the game moved to another layer means the vehicle was
 * destroyed (its wreck leaves the group); a group no longer this mod's alone is left; a rebuilt body starts a new scan. */
static void CheckMarks(Weapon* w)
{
    FdfCounts c;
    FdfReason why = FDF_OK;
    if (!fdf_verify(Job(w), w->group, &c)) return;
    if (c.moved > 0)
    {
        (void)Release(w, &why);
        w->destroyed = 1;
        return;
    }
    if (StillOwn(w, &why)) RescanIfStale(w, &c);
    else (void)DropGroup(w, why);
}

/* ---- the weapon scan (every SCAN_SECONDS) ------------------------------------------------------------------------ */

static int FindWeapon(uintptr_t address)
{
    for (int i = 0; i < 2 * MAX_TRACKED; i++)
        if (s.weapons[i].used && s.weapons[i].address == address) return i;
    return -1;
}

static int FreeWeapon(void)
{
    for (int i = 0; i < 2 * MAX_TRACKED; i++)
        if (!s.weapons[i].used) return i;
    return -1;
}

/* A new weapon record at the slot, keeping the state word last read at its address. */
static void NewWeapon(Weapon* w, uintptr_t address, uint32_t handle, uint32_t hi, uint32_t state)
{
    memset(w, 0, sizeof *w);
    w->used = 1;
    w->address = address;
    w->handle = handle;
    w->state = state;
    w->name = hi == ARM_HI ? "Lumberer" : hi == SENTRY_HI ? "Flame Sentry" : "weapon";
}

/* A tracked spray weapon this scan: its record, a new one when the address is new or holds another unit now. */
static void Track(uintptr_t address, uint32_t handle, uint32_t hi, uint8_t* seen)
{
    int i = FindWeapon(address);
    if (i >= 0 && s.weapons[i].handle != handle)
    {
        FdfReason why = FDF_OK;
        (void)Release(&s.weapons[i], &why);
        if (s.scanning == &s.weapons[i]) s.scanning = NULL;
        NewWeapon(&s.weapons[i], address, handle, hi, s.weapons[i].state);
    }
    else if (i < 0)
    {
        i = FreeWeapon();
        if (i < 0) return;
        NewWeapon(&s.weapons[i], address, handle, hi, 0);
    }
    s.tracked[s.tracked_n++] = i;
    seen[i] = 1;
}

/* The tracked spray weapons (Lumberer arms, Flame Sentries) in the spray manager, at most MAX_TRACKED. */
static void FindSprays(uint8_t* seen)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(FDF_SPRAY_MANAGER);
    uint8_t head[0x40];
    if (!vpm_plausible(manager) || !vpm_read(manager + SPRAY_FIELDS, head, sizeof head)) return;
    uint32_t count;
    uint64_t entities, instances;
    memcpy(&count, head, 4);
    memcpy(&entities, head + 0x28, 8);
    memcpy(&instances, head + 0x38, 8);
    if (count == 0 || count > MAX_SPRAYS || !vpm_plausible((uintptr_t)entities) || !vpm_plausible((uintptr_t)instances)) return;
    if (!vpm_read((uintptr_t)entities, g_entities, 8u * count)) return;
    for (uint32_t index = 0; index < count && s.tracked_n < MAX_TRACKED; index++)
    {
        uint32_t entity[4]; /* resource lo, hi, -, unit handle */
        if (!vpm_plausible((uintptr_t)g_entities[index]) || !vpm_read((uintptr_t)g_entities[index], entity, sizeof entity)) continue;
        if ((entity[0] != ARM_LO && entity[0] != SENTRY_LO) || (entity[1] != ARM_HI && entity[1] != SENTRY_HI)) continue;
        Track((uintptr_t)instances + SPRAY_RECORD * (uintptr_t)index, entity[3], entity[1], seen);
    }
}

/* Every SCAN_SECONDS of game time: per-weapon states and families survive the rescan; a weapon gone is released. */
static void Scan(void)
{
    uint8_t seen[2 * MAX_TRACKED] = {0};
    s.since_scan = 0;
    s.tracked_n = 0;
    FindSprays(seen);
    for (int i = 0; i < 2 * MAX_TRACKED; i++)
    {
        Weapon* w = &s.weapons[i];
        if (!w->used) continue;
        if (!seen[i])
        {
            FdfReason why = FDF_OK;
            (void)Release(w, &why);
            if (s.scanning == w) s.scanning = NULL;
            w->used = 0;
        }
        else if (w->marked && w->job_ok && !w->firing)
        {
            CheckMarks(w);
        }
    }
}

/* ---- bursts ----------------------------------------------------------------------------------------------------- */

/* The highest usable group for the weapon, or 0. */
static uint32_t PickGroup(Weapon* w)
{
    for (uint32_t g = FDF_GROUP_TOP; g >= FDF_GROUP_LOW; g--)
        if (Usable(w, g)) return g;
    return 0;
}

/* Puts the weapon's group-free bodies into its group (its own, checked just before, or a newly picked one). 0 when
 * the self-hit fix cannot go on for this weapon now. */
static int GroupBodies(Weapon* w)
{
    uint32_t g = w->group != 0 ? w->group : PickGroup(w);
    if (g == 0)
    {
        if (!Told(KEY_NO_GROUP)) vpm_log(s.self, "Self-hit fix skipped: no free Havok system group in %u-%u", FDF_GROUP_LOW, FDF_GROUP_TOP);
        return 0;
    }
    w->group = g;
    FdfReason why = FDF_OK;
    int marked = fdf_mark(Job(w), g, &why);
    if (marked < 0)
    {
        Disable(why);
        return 0;
    }
    w->marked = marked > 0;
    if (w->marked && !w->announced)
    {
        w->announced = 1;
        vpm_log(s.self, "Self-hit fix active for the %s (%d/%d own bodies in group %u).", w->name, marked, Job(w)->n, g);
    }
    return 1;
}

static int FirstWordFixed(uintptr_t data)
{
    uint32_t word = 0;
    return vpm_read_u32(data + fdf_patches[0].offset, &word) && word == fdf_patches[0].fixed;
}

/* The effect fix (once per burst start of any tracked weapon). The full lookup runs every burst start: the effect is
 * reloaded with each mission, and a stale shortcut could leave a mission's flame unfixed. */
static void BurstStart(void)
{
    FdfReason why = FDF_OK;
    uintptr_t data = 0;
    if (!fdf_resolve_effect(&data, &why)) data = 0;
    s.data = data;
    if (data == 0) TellOnce(why, "Flame effect not fixed: ");
    else if (!(s.patched == data && FirstWordFixed(data)))
    {
        int writes = 0;
        if (!fdf_apply_effect(data, &writes, &why)) TellOnce(why, "Flame effect not fixed: ");
        else
        {
            s.patched = data;
            if (writes > 0) vpm_log(s.self, "Flame effect fixed (%d words).", writes);
        }
    }
    if (s.filter == 0 && s.self_hit_off == FDF_OK)
    {
        uintptr_t filter = 0;
        if (fdf_check_filter(&filter, &why)) s.filter = filter;
        else Disable(why);
    }
    s.slot = fdf_flame_slot();
}

/* The self-hit fix for one weapon's new burst: its bodies stay grouped from the first burst until it is gone; a burst
 * confirms the bodies (one read per span) and the group (the allocator), groups bodies found group-free, and moves to
 * another free group when the weapon's group is no longer this mod's alone. */
static void WeaponBurst(Weapon* w)
{
    FdfCounts c;
    FdfReason why = FDF_OK;
    w->instance = 0;
    w->awaiting = 1;
    if (!(s.filter != 0 && s.self_hit_off == FDF_OK && w->job_ok && !w->destroyed)) return;
    if (!fdf_verify(Job(w), w->group, &c)) return;
    if (c.moved > 0)
    {
        (void)Release(w, &why);
        w->destroyed = 1;
        return;
    }
    int regroup = c.free > 0;
    if (w->group != 0 && !StillOwn(w, &why)) regroup = DropGroup(w, why);
    if (regroup && !GroupBodies(w)) return;
    RescanIfStale(w, &c);
}

/* Firing and briefly after: the weapon's burst instance (spray record +0x24) joins its group. lint: per-frame */
static void FindBurstInstance(Weapon* w)
{
    uint32_t id = 0;
    uintptr_t sim = 0;
    if (s.slot == 0) s.slot = fdf_flame_slot();
    if (!vpm_read_u32(w->address + SPRAY_INSTANCE, &id)) id = 0;
    if (s.slot == 0 || id == 0 || id == w->instance || !fdf_find_instance(s.slot, id, &sim)) return;
    w->instance = id;
    w->awaiting = 0;
    if (!w->marked || s.data == 0) return;
    FdfRegion region = {0, 0};
    FdfReason why = FDF_OK;
    int moved = sim != 0 ? fdf_retarget(sim, s.data, &region, FLAME + (w->group << FDF_GROUP_SHIFT), FLAME, &why) : 0;
    if (moved < 0)
    {
        Disable(why);
        (void)Release(w, &why);
    }
    else if (moved > 0)
    {
        w->flames = 1;
    }
}

/* ---- the per-frame step ----------------------------------------------------------------------------------------- */

/* A complete scan becomes the weapon's job. Bodies found still grouped keep their group, and the weapon stays grouped;
 * a group the scan found on other bodies is left at once. */
static void ScanDone(Weapon* w)
{
    s.scanning = NULL;
    w->job_ok = 1;
    w->current ^= 1;
    for (int k = 0; k < Job(w)->n; k++) w->marked = w->marked || Job(w)->marked[k];
    if (w->group != 0 && Job(w)->foreign[w->group - FDF_GROUP_LOW]) (void)DropGroup(w, FDF_ON_BODIES);
}

/* Each tracked weapon's state word: firing (1 or 2) and a burst start (from neither). 1 when any burst started.
 * lint: per-frame */
static int ReadStates(int* firing)
{
    int started = 0;
    *firing = 0;
    for (int i = 0; i < s.tracked_n; i++)
    {
        Weapon* w = &s.weapons[s.tracked[i]];
        uint32_t state = 0, previous = w->state;
        if (!vpm_read_u32(w->address, &state)) state = 0;
        w->state = state;
        w->firing = state == 1 || state == 2;
        w->started = w->firing && previous != 1 && previous != 2;
        *firing |= w->firing;
        started |= w->started;
    }
    return started;
}

/* lint: per-frame */
static void Watch(int firing)
{
    if (firing)
    {
        s.watch = 1;
        s.watch_until = s.clock + WATCH_SECONDS;
    }
    int watching = s.watch && s.clock <= s.watch_until;
    if (s.watch && !watching) s.watch = 0;
    if (!watching) return;
    for (int i = 0; i < s.tracked_n; i++)
    {
        Weapon* w = &s.weapons[s.tracked[i]];
        if (w->firing || w->awaiting) FindBurstInstance(w);
    }
}

/* One family's body scan at a time, a few block reads per frame; else the next weapon's family lookup. lint: per-frame */
static void BodyScan(void)
{
    Weapon* w = s.scanning;
    if (w == NULL)
    {
        for (int i = 0; i < s.tracked_n; i++)
        {
            Weapon* candidate = &s.weapons[s.tracked[i]];
            if (candidate->job_ok || s.clock < candidate->next_try) continue;
            BeginFamily(candidate);
            break;
        }
        return;
    }
    FdfScanFor scan = {&w->family, w->group, OwnBody};
    FdfReason why = FDF_OK;
    int done = fdf_scan_step(ScanJob(w), &scan, SCAN_BLOCKS, &why);
    if (done < 0)
    {
        s.scanning = NULL;
        w->next_try = s.clock + RETRY_SECONDS;
        TellOnce(why, "Self-hit fix unavailable: ");
    }
    else if (done > 0)
    {
        ScanDone(w);
    }
}

/* The Lua's step. Idle gate: with no tracked weapon a frame only adds dt (the weapon scan runs every SCAN_SECONDS).
 * lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.clock += dt;
    s.since_scan += dt;
    if (s.since_scan >= SCAN_SECONDS) Scan();
    if (s.tracked_n == 0) return;
    int firing = 0;
    if (ReadStates(&firing))
    {
        BurstStart();
        for (int i = 0; i < s.tracked_n; i++)
            if (s.weapons[s.tracked[i]].started) WeaponBurst(&s.weapons[s.tracked[i]]);
    }
    Watch(firing);
    BodyScan();
}

/* ---- start and stop --------------------------------------------------------------------------------------------- */

/* Puts this mod's group stores back (the Lua's reset, run by its update guard's stop): every weapon's bodies leave its
 * group, flame systems of live instances still in a weapon's group go back to plain layer 11, and the weapons are
 * forgotten. The effect fix stays: it needs no upkeep, and the game reloads the effect with every mission. */
static void Stop(VpmComponent* self)
{
    uintptr_t slot = s.data != 0 ? fdf_flame_slot() : 0;
    FdfReason failure = FDF_OK;
    for (int i = 0; i < 2 * MAX_TRACKED; i++)
    {
        Weapon* w = &s.weapons[i];
        FdfReason why = FDF_OK, reason = FDF_OK;
        if (!w->used) continue;
        int released = Release(w, &why), restored = RestoreFlames(w, slot, &reason);
        if (failure == FDF_OK) failure = !released ? why : !restored ? reason : FDF_OK;
        w->used = 0;
    }
    s.tracked_n = 0;
    s.scanning = NULL;
    s.watch = 0;
    s.slot = 0;
    s.since_scan = SCAN_SECONDS;
    char text[64];
    if (failure != FDF_OK) vpm_log(self, "Self-hit group writes not restored: %s", fdf_reason_text(failure, text, sizeof text));
}

static void Loaded(VpmComponent* self, HfEvent event)
{
    if (!vpm_tick_start(self, Tick)) { (void)vpm_fail(self, "no game-thread tick"); return; }
    vpm_log(self, "Flame Damage Fixed v1.2 initialized (spawn fix, Cremator emitter distances, self-hit fix by Havok system group).");
}

#ifdef VPM_TEST
int fdf_test_weapon(uintptr_t address, FdfTestWeapon* out)
{
    int i = FindWeapon(address);
    if (i < 0) return 0;
    Weapon* w = &s.weapons[i];
    memset(out, 0, sizeof *out);
    out->group = w->group;
    out->marked = w->marked;
    out->job_ok = w->job_ok;
    out->kept = Job(w)->n;
    out->destroyed = w->destroyed;
    out->scanning = s.scanning == w;
    out->flames = w->flames;
    for (uint32_t g = 0; g < FDF_GROUPS_OWN; g++)
        if (Job(w)->foreign[g]) out->foreign |= 1u << g;
    return 1;
}

int fdf_test_tracked(void) { return s.tracked_n; }
#endif

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.self = self;
    s.since_scan = SCAN_SECONDS;
    return vpm_on_load(self, HF_EVENT_GAME_LOADED, Loaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_flame_damage_fixed = {"flame_damage_fixed", "Flame Damage Fixed", "1.2", 0, Start, Stop};
