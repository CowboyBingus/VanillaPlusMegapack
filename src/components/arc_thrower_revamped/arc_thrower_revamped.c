/* Arc Thrower Revamped v1.7.1 (Lua: components/ArcThrowerRevamped/src/arc_thrower_auto.lua), for build 25480438.
 *
 * Hold Fire and the ARC-3 Arc Thrower keeps firing. Vanilla fires one arc per press: the engine clears the weapon's fire
 * command when it fires, and its trigger handler copies that command into the weapon's 40-byte charge entry every frame
 * (entry +12, the charging flag). The charge updater advances the charge (entry +4) while the flag is set and, with the
 * weapon's charge record allowing it (WeaponChargeComponentData +184, auto_fire_in_safety), fires by itself when the charge
 * crosses the full-charge time (entry +8). So the record's flag is set once per session, and while the local player holds
 * Fire with an Arc Thrower the engine issued a fire command for, the charging flag is set again on every frame the engine
 * has cleared it. Charge times, cadence, damage and arcs stay stock.
 *
 * As the Lua: the local avatar through both registries (vpm_local_avatar: the core holds this component's resolution) and
 * its processed Fire action (slot 9, held seconds at +8), so mouse, controller and rebound Fire all count and Aim (slot 8)
 * never does. A press is followed only after the engine issued a fire command for a weapon that is an Arc Thrower (its
 * entity resource), owned, and held by the local avatar (the weapon holder table): the trigger manager's flag array first,
 * at most 64 flagged candidates per discovery, at most ten discoveries a second. Its charge entry is found through the
 * charge manager (the kept index checked, else its entity array searched) and re-read every frame, since the arrays move
 * and compact. Unknown input or a binding that cannot be read pauses the writes for at most 0.25 s (then a new fire command
 * is needed); a release, another weapon, another holder or another avatar ends the hold. A cycle stalled below a quarter of
 * the full charge for 1.2 s looks for a replacement binding. The entry's page must be committed private read-write memory
 * (one VirtualQuery per binding and page, before its first write); anything else stops the component.
 * Frames are counted: every 60th tick a poll frame reads whether a mission runs (the mission record) and checks the charge
 * record; in a mission every 15th tick is a check frame, the full Fire check from the registry roots. Between them an idle
 * tick reads only the Fire slot kept from the last full check (one 4-byte read) and stops while Fire is up. Outside a
 * mission nothing can fire: ticks between poll frames read nothing.
 *
 * On HellForge:
 * - The charge record is found by identity, not by the Lua's scan of the game's read-only weapon data region: HellForge's
 *   component_record for the Arc Thrower's entity (HF_ENTITY_ARC3_ARC_THROWER, the Lua's resource bytes), checked as the
 *   Lua checked each record its scan found (the 16-byte animation fingerprint at +168, charge times 1.0, 1.1, 1.2, 0.7 and
 *   1.4 s). Its flag is HellForge's mapped field WeaponCharge.auto_fire_at_full, set with set_live (HellForge changes the
 *   read-only page for the write, keeps the edit for the session and renews it when the game reloads its data) and read
 *   back with get_live. stop() undoes the live edit. The poll frames still read the record (its fingerprint and flag) and
 *   set the flag again if it is clear; a record that no longer checks out, a charge stuck without progress, or
 *   HF_EVENT_ENTITIES_READY firing again looks the record up by identity again (the Lua's rescan).
 * - The fire-mode setter's code (the Lua's build fingerprint) is checked with vpm_when_code_ready from
 *   HF_EVENT_GAME_LOADED: game.dll's code is decoded in parts after that event, and nothing orders the entity data
 *   after the setter's part. Until it reads as shipped, HF_EVENT_ENTITIES_READY's work (the record, the tick) waits; the
 *   core stops the component if it never does within 60 s ("the fire-mode setter changed (game.dll 0x755F90)"), with
 *   nothing changed.
 * - Time is the sum of the ticks' dt (the Lua: the performance counter). The game.dll globals are plain loads (the Lua read
 *   each through ReadProcessMemory); heap reads stay vpm_read. The charging flag is a plain store into the page checked for
 *   the binding (the Lua: WriteProcessMemory).
 * - The tick runs where the Lua ran: at the start of game.dll's whole update (0xAB5000), which the engine calls right
 *   after the game's Lua update, so the store comes before anything game.dll does in the frame, as the Lua's did. The
 *   flag must reach the charge updater before the trigger handler copies the cleared fire command over it again: a
 *   store anywhere after the handler and before the updater (in frame order, wrapping into the next frame) works, a
 *   store between the updater and the handler is lost. The Lua's place worked, and the tick has that place. Until the
 *   core's frame hook is in (or if it is refused), the tick runs from HellForge's game-thread callback (the menu sound
 *   manager's update, game.dll 0x13270B0) inside the same update, a place not checked against the handler and the
 *   updater; the first cycle that stalls in a session is logged ("stalled"), which is what a tick in the wrong place
 *   shows (one arc per press, then the charge stays at 0 while Fire is held).
 * - Dropped: the Lua's update-chain guard (pause after an error below, eight errors stop it: the core's crash guard stops
 *   the component on a fault instead), the shutdown restore (no shutdown event), the developer diagnostics
 *   (ArcThrowerDiagnostics: the shot, hold, idle-reason and release lines; the first stall of a session is logged), the
 *   SHA-256 build gate (the core checks the build), the kernel32 bindings and LuaJIT notes.
 *
 * Cost per tick: reads (vpm_read), as the test pins them; in brackets the Lua's ReadProcessMemory calls, as its
 * frame_budget pinned them. The game.dll globals the Lua read are plain loads here, hence the fewer reads.
 * - Outside a mission: 0 [0]; a poll frame every 60 ticks: the mission record and the charge record, 2 [3].
 * - In a mission, Fire up: 1 [1]; a check frame every 15 ticks: 13 [16]; a poll frame: 15 [19]. No local avatar: 0 [0],
 *   its poll frame 2 [6]. A kept Fire slot that became unreadable: 4 [5], then 0 until the next check frame.
 * - Fire held with another weapon: 3 [4]; a discovery (at most 10 a second): 7 [9]; the press's first tick: 8 [10].
 * - Fire held with an Arc Thrower: 9 [12], and the flag's store when the engine has cleared it [1 WriteProcessMemory];
 *   the press's first tick 15 [19]; a check frame 21 [26]; a poll frame 23 [29]; the entry moved 10 [13]. One
 *   VirtualQuery before a binding's first write and when its entry moves to another page [1 VirtualQueryEx].
 * - A poll frame that finds the record flag cleared: 15 reads, set_live and get_live [20, 1 VirtualQueryEx,
 *   2 VirtualProtectEx, 1 WriteProcessMemory].
 * - No clock (the Lua: 1 QueryPerformanceCounter per active tick), no other Windows call, no allocation, no log; the one
 *   exception is the first stalled cycle of a session, logged once.
 * Once per session, at HF_EVENT_GAME_LOADED: 1 code check (the core repeats it every 30 frames while the code is not
 * decoded, for at most 60 s); at HF_EVENT_ENTITIES_READY (or when the code is decoded, if that comes later):
 * component_record, 1 read of the record, set_live, get_live and a log line [the Lua's first update: 23 reads,
 * 3 VirtualQueryEx, 2 VirtualProtectEx, 1 WriteProcessMemory and 6 QueryPerformanceCounter for its scan, which can take
 * more updates]. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "../../core/vpm.h"

#define CHARGE_MANAGER 0x3326C20u   /* game.dll: the charge manager; +16 its 56-byte header */
#define TRIGGER_MANAGER 0x3326660u  /* game.dll: the trigger manager (fire commands); +24 its 72-byte header */
#define HOLDER_MANAGER 0x3326DC0u   /* game.dll: the weapon holders; +32 weapon id -> row, +64 its 48-byte rows */
#define MISSION_RECORD 0x33266A0u   /* game.dll: the mission record (68 bytes; the loader's frame-state definition) */
#define FIRE_MODE_SETTER 0x755F90u  /* game.dll: the fire-mode setter, the Lua's build fingerprint */
#define ARC_ENTITY HF_ENTITY_ARC3_ARC_THROWER /* the Lua's ARC_RESOURCE, '\xe6\x06\x73\x0f\xd5\x9c\xde\x96' */
#define ARC_LOW ((uint32_t)ARC_ENTITY)
#define ARC_HIGH ((uint32_t)(ARC_ENTITY >> 32))
#define CHARGE_COMPONENT "WeaponChargeComponentData"
#define RECORD_SIZE 216u
#define AT_FINGERPRINT 168u
#define AT_AUTO_FIRE 184u           /* auto_fire_in_safety: WeaponCharge.auto_fire_at_full */
#define ENTRY_SIZE 40u              /* a charge entry: +4 charge, +8 full-charge time, +12 the charging flag */
#define AT_CHARGING 12u
#define TRIGGER_BATCH 64u
#define TRIGGER_LIMIT 4096u
#define CHARGED_LIMIT 512u
#define CHECK_FRAMES 15u
#define POLL_FRAMES 60u
#define RECOVERY_WINDOW 0.25
#define DISCOVERY_INTERVAL 0.1
#define UNKNOWN (-1)

static const uint8_t kFingerprint[16] = {0x0F, 0xD7, 0xD6, 0x1A, 0x96, 0xFB, 0xA2, 0x29, 0xA9, 0x31, 0xEE, 0x67, 0x0E, 0x04,
    0x95, 0x41};
static const HfField kAutoFire = HF_FIELD(WeaponCharge, auto_fire_at_full);

/* The weapon a press follows (the Lua's resolved). */
typedef struct Binding
{
    uintptr_t entity;      /* the weapon's entity */
    uint32_t identity[6];  /* its 24-byte entity record when it armed */
    uint32_t avatar[6];    /* the local avatar's record when it armed */
    int indexed;           /* index: its row in the charge manager last time */
    uint32_t index;
    uintptr_t entry;       /* its charge entry */
    uintptr_t checkedPage; /* the entry's page, checked for this binding (0: none) */
} Binding;

/* The last weapon-holder row that showed the local avatar holding a weapon. */
typedef struct Holder { int valid; uintptr_t manager, rows; uint32_t index, weapon, avatar; } Holder;

static struct
{
    uint32_t frames;       /* the tick count modulo POLL_FRAMES: 0 is a poll frame */
    int mission;           /* the last poll frame found a mission */
    double now;            /* seconds: the ticks' dt added up */
    uintptr_t fireSlot;    /* the idle gate's Fire slot, from the last full check (0: none) */
    VpmAvatar kept;        /* the last full resolution of the local avatar, and its Fire slot (0: none) */
    uintptr_t keptSlot;
    Holder holder;
    int armed;             /* a binding is followed (the Lua's armed, and resolved ~= nil) */
    Binding resolved;
    int discovering;       /* a discovery ran this press: the next one waits until nextDiscovery */
    double nextDiscovery;
    uint32_t discoveryIndex, discoveryCount;
    uintptr_t discoveryEntities;
    int suspended;         /* writes paused since suspendedSince */
    double suspendedSince;
    int heldKnown;
    float heldTime;        /* the Fire held time on the last driven tick */
    int progressKnown;
    double progressTime;   /* the charge last changed */
    int drove;
    double droveSince, drovePeak; /* this charge cycle's start and highest charge */
    int hasPrevious;
    double previous;       /* the charge on the last driven tick */
    uint32_t rescans;
    int stallLogged;
    uintptr_t record;      /* the charge record, as found by identity */
    int patched, wrote, rescanRequested, patchLogged, scanLogged;
    double nextScan;
    char why[200];         /* why the record is not patched */
    int codeReady;         /* the fire-mode setter's bytes read as shipped (CodeReady) */
    int entitiesReady;     /* HF_EVENT_ENTITIES_READY came first: CodeReady takes it up */
} s;

static uint8_t g_charge[RECORD_SIZE];     /* the charge record as read */
static uint8_t g_flags[TRIGGER_LIMIT];    /* the trigger manager's fire commands as read (static: 4 KB) */
static uint64_t g_charged[CHARGED_LIMIT]; /* the charge manager's entities as read (static: 4 KB) */

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t U64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static uint64_t Words64(const uint32_t* words) { return words[0] | (uint64_t)words[1] << 32; }
/* A float from its bits, as the Lua decoded every float (no float load of a NaN). */
static double Float(uint32_t bits) { float v; memcpy(&v, &bits, 4); return v; }
static int Near(uint32_t bits, double want) { double d = Float(bits) - want; return d < 1e-3 && d > -1e-3; }
static int Owned(const uint32_t* record) { return (record[5] & 1u) == 1u; }

/* ---- the charge record --------------------------------------------------------------------------------------------- */

static int ValidChargeRecord(const uint8_t* charge)
{
    return memcmp(charge + AT_FINGERPRINT, kFingerprint, sizeof kFingerprint) == 0 && Near(U32(charge + 0), 1.0) &&
        Near(U32(charge + 24), 1.1) && Near(U32(charge + 48), 1.2) && Near(U32(charge + 72), 0.7) &&
        Near(U32(charge + 76), 1.4);
}

/* The record's auto-fire flag: 1 set (already, or now through HellForge's live edit and read back), 0 not (s.why). */
static int EnsureAutoFire(const uint8_t* charge)
{
    if (charge[AT_AUTO_FIRE] == 1) return 1;
    const HfValue one = HF_U8(1);
    if (vpm_hf()->set_live(vpm_mod(), ARC_ENTITY, &kAutoFire, &one, 0) == 0)
    {
        snprintf(s.why, sizeof s.why, "charge record write failed: HellForge refused the edit (%s)", vpm_hf()->last_log(vpm_mod()));
        return 0;
    }
    s.wrote = 1;
    HfLiveValue now;
    if (vpm_hf()->get_live(vpm_mod(), ARC_ENTITY, &kAutoFire, &now) == 0 || now.now.number != 1.0)
    {
        snprintf(s.why, sizeof s.why, "charge record write failed: record flag did not read back");
        return 0;
    }
    return 1;
}

/* The Arc Thrower's charge record by identity, checked, its flag set: 1 patched now, 0 not (s.why). An already-patched
 * record found by a rescan is nothing new (the Lua's recovery scan passed patched copies). */
static int FindRecord(void)
{
    uint32_t stride = 0;
    uintptr_t record = vpm_hf()->component_record(CHARGE_COMPONENT, ARC_ENTITY, &stride);
    if (record == 0 || !vpm_read(record, g_charge, RECORD_SIZE))
    {
        snprintf(s.why, sizeof s.why, "charge record not found");
        return 0;
    }
    if (!ValidChargeRecord(g_charge))
    {
        snprintf(s.why, sizeof s.why, "charge record not found (the Arc Thrower's charge record is not the reviewed one)");
        return 0;
    }
    s.record = record;
    if (s.patched && g_charge[AT_AUTO_FIRE] == 1)
    {
        snprintf(s.why, sizeof s.why, "charge record not found");
        return 0;
    }
    s.patched = EnsureAutoFire(g_charge);
    return s.patched;
}

/* One attempt, at most every 1 s after one that patched and 5 s after one that did not (the Lua's scan cadence). */
static void PatchRecord(VpmComponent* self)
{
    if (s.now < s.nextScan) return;
    s.rescanRequested = 0;
    int found = FindRecord();
    s.nextScan = s.now + (found ? 1.0 : 5.0);
    if (found)
    {
        if (s.patchLogged) return;
        s.patchLogged = 1;
        vpm_set_status(self, NULL);
        vpm_log(self, "Charge record ready.");
        return;
    }
    if (s.patched || s.scanLogged) return;
    s.scanLogged = 1;
    char status[220];
    snprintf(status, sizeof status, "waiting: %s", s.why);
    vpm_set_status(self, status);
    vpm_log(self, "Charge record not ready yet: %s", s.why);
}

/* A poll frame's check of the kept record (one 216-byte read): its flag set again when clear; a record that no longer
 * checks out is never written, it is looked up again at once. */
static void CheckRecord(void)
{
    if (vpm_read(s.record, g_charge, RECORD_SIZE) && ValidChargeRecord(g_charge))
    {
        s.patched = EnsureAutoFire(g_charge);
        return;
    }
    s.record = 0;
    s.patched = 0;
    s.nextScan = s.now;
}

static void Maintain(VpmComponent* self, int poll)
{
    if (s.record != 0 && poll) CheckRecord();
    if (!s.patched || s.rescanRequested) PatchRecord(self);
}

/* ---- the mission and the Fire input -------------------------------------------------------------------------------- */

/* Whether a mission runs: word +8 set and word +0x40 a mission type, 1 .. 7 (1 read). Unreadable: no mission. */
static int InMission(void)
{
    uintptr_t record = (uintptr_t)vpm_game_u64(MISSION_RECORD);
    uint32_t words[17];
    if (record == 0 || !vpm_read(record, words, sizeof words)) return 0;
    return words[2] != 0 && words[16] >= 1 && words[16] <= 7;
}

static void ClearHold(void)
{
    s.armed = s.discovering = s.suspended = s.heldKnown = s.progressKnown = s.drove = s.hasPrevious = 0;
    s.discoveryIndex = 0;
    s.drovePeak = 0;
}

/* Leaving a mission ends any hold and drops the kept Fire slot. */
static void PollMission(void)
{
    int mission = InMission();
    if (s.mission && !mission)
    {
        ClearHold();
        s.fireSlot = s.keptSlot = 0;
    }
    s.mission = mission;
}

/* A press the component follows: armed, or retrying discovery while Fire stays held. Such ticks run the full check. */
static int Holding(void) { return s.armed || s.discovering; }

static void SuspendHold(void)
{
    if (!s.suspended)
    {
        s.suspended = 1;
        s.suspendedSince = s.now;
    }
    s.hasPrevious = 0;
    if (s.now - s.suspendedSince >= RECOVERY_WINDOW) ClearHold();
}

/* The full resolution from the registry roots, kept: the Fire slot, or 0. */
static uintptr_t ResolveSlot(void)
{
    VpmAvatar avatar;
    s.keptSlot = 0;
    if (!vpm_local_avatar(&avatar)) return 0;
    s.kept = avatar;
    s.keptSlot = vpm_action_slot(&avatar, VPM_ACTION_FIRE);
    return s.keptSlot;
}

/* The kept slot while the kept avatar still holds (2 reads), else 0. */
static uintptr_t KeptSlot(void) { return s.keptSlot != 0 && vpm_avatar_still(&s.kept) ? s.keptSlot : 0; }

/* The Fire check: 1 held (*held seconds), 0 up, UNKNOWN; *slot the slot read, 0 when unknown. A check frame resolves
 * from the registry roots; other ticks use the kept slot and resolve again on a mismatch. */
static int LocalFire(int check, float* held, uintptr_t* slot)
{
    uint32_t input[8];
    *slot = check ? 0 : KeptSlot();
    if (*slot == 0) *slot = ResolveSlot();
    if (*slot == 0) return UNKNOWN;
    if (vpm_read(*slot, input, sizeof input))
    {
        *held = (float)Float(input[2]);
        if (*held >= 0.0f && *held < 86400.0f) return *held > 0.0f;
    }
    s.keptSlot = *slot = 0;
    return UNKNOWN;
}

/* The idle gate: one 4-byte read of the kept Fire slot. Zero (either sign) is Fire up; unreadable or anything else sends
 * the tick to the full check. No slot: nothing is read until the next check frame. */
static int FireMayBeHeld(void)
{
    uint32_t bits;
    if (s.fireSlot == 0) return 0;
    if (!vpm_read_u32(s.fireSlot + 8, &bits)) return 1;
    return (bits & 0x7FFFFFFFu) != 0;
}

/* ---- the weapon -------------------------------------------------------------------------------------------------- */

/* Whether the weapon with this id is held by the avatar with this id: 1, 0, or UNKNOWN. cached (held Fire between check
 * frames): the kept row for the same weapon and avatar is verified (the rows pointer and its holder, 2 reads) instead of
 * the lookup; any mismatch, and every check frame, looks it up afresh. */
static int LocalWeapon(uint32_t weapon, uint32_t avatar, int cached)
{
    Holder* h = &s.holder;
    uintptr_t manager = (uintptr_t)vpm_game_u64(HOLDER_MANAGER);
    uint32_t holder = 0, index;
    if (manager == 0) return UNKNOWN;
    if (cached && h->valid && h->manager == manager && h->weapon == weapon && h->avatar == avatar &&
        vpm_ptr(manager + 64) == h->rows && vpm_read_u32(h->rows + (uintptr_t)h->index * 48u + 4u, &holder) && holder == avatar)
        return 1;
    h->valid = 0;
    if (!vpm_lookup(manager + 32, weapon, 8192u, &index) || index >= 4096u) return UNKNOWN;
    uintptr_t rows = vpm_ptr(manager + 64);
    if (rows == 0 || !vpm_read_u32(rows + (uintptr_t)index * 48u + 4u, &holder)) return UNKNOWN;
    if (holder != avatar) return 0;
    *h = (Holder){1, manager, rows, index, weapon, avatar};
    return 1;
}

/* The binding's charge entry, read from the live manager: 1 with *entry (the kept index checked, else the entity array
 * searched), 0 when the readable table no longer holds the weapon, UNKNOWN. */
static int ChargeEntry(Binding* b, uintptr_t* entry)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(CHARGE_MANAGER);
    uint32_t header[14];
    if (manager == 0 || !vpm_read(manager + 16, header, sizeof header)) return UNKNOWN;
    uint32_t count = header[0];
    uintptr_t entities = (uintptr_t)Words64(header + 10), entries = (uintptr_t)Words64(header + 12);
    if (count < 1 || count > CHARGED_LIMIT || entities == 0 || entries == 0) return UNKNOWN;
    if (b->indexed && b->index < count && vpm_ptr(entities + (uintptr_t)b->index * 8u) == b->entity)
    {
        *entry = entries + (uintptr_t)b->index * ENTRY_SIZE;
        return 1;
    }
    if (!vpm_read(entities, g_charged, (size_t)count * 8u)) return UNKNOWN;
    for (uint32_t i = 0; i < count; i++)
    {
        if (g_charged[i] != b->entity) continue;
        b->indexed = 1;
        b->index = i;
        *entry = entries + (uintptr_t)i * ENTRY_SIZE;
        return 1;
    }
    return 0;
}

/* Whether entity is the local player's Arc Thrower: its record (into identity) and its holder. */
static int ArcRecord(uintptr_t entity, const uint32_t* avatar, uint32_t* identity)
{
    return entity != 0 && vpm_read(entity, identity, 24) && identity[0] == ARC_LOW && identity[1] == ARC_HIGH &&
        Owned(identity) && LocalWeapon(identity[2], avatar[2], 0) == 1;
}

/* The first flagged entry from first on that holds the local player's Arc Thrower (into chosen): 1, or 0. At most
 * TRIGGER_BATCH flagged entries are inspected; the next discovery goes on after the last one. */
static int FlaggedArc(const uint32_t* avatar, uint32_t count, uintptr_t entities, uint32_t first, Binding* chosen)
{
    uint32_t examined = 0;
    for (uint32_t offset = 0; offset < count; offset++)
    {
        uint32_t index = (first + offset) % count;
        if (g_flags[index] == 0) continue;
        uintptr_t entity = vpm_ptr(entities + (uintptr_t)index * 8u);
        if (ArcRecord(entity, avatar, chosen->identity))
        {
            chosen->entity = entity;
            return 1;
        }
        if (++examined >= TRIGGER_BATCH)
        {
            s.discoveryIndex = (index + 1) % count;
            return 0;
        }
    }
    return 0;
}

/* The small fire-command table first, so ordinary weapons never walk the charged weapons: 1 with chosen armed-ready (its
 * entity, identity and charge entry), or 0. */
static int ActiveArc(const uint32_t* avatar, Binding* chosen)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(TRIGGER_MANAGER), entry = 0;
    uint8_t header[72];
    memset(chosen, 0, sizeof *chosen);
    if (manager == 0 || !vpm_read(manager + 24, header, sizeof header)) return 0;
    uint32_t count = U32(header);
    uintptr_t entities = (uintptr_t)U64(header + 40), held = (uintptr_t)U64(header + 64);
    if (count < 1 || count > TRIGGER_LIMIT || entities == 0 || held == 0) return 0;
    if (s.discoveryEntities != entities || s.discoveryCount != count)
    {
        s.discoveryIndex = 0;
        s.discoveryEntities = entities;
        s.discoveryCount = count;
    }
    uint32_t first = s.discoveryIndex;
    if (!vpm_read(held, g_flags, count)) return 0;
    s.discoveryIndex = 0;
    if (!FlaggedArc(avatar, count, entities, first, chosen) || ChargeEntry(chosen, &entry) != 1) return 0;
    chosen->entry = entry;
    return 1;
}

/* ---- the hold ------------------------------------------------------------------------------------------------------ */

/* The armed weapon must still be the same entity, held by the same local avatar, with a readable charge binding. 0: the
 * hold was suspended or cleared and this tick writes nothing. check: a check frame looks the holder up afresh. */
static int Revalidate(const uint32_t* avatar, int check)
{
    Binding* b = &s.resolved;
    uint32_t record[6];
    uintptr_t entry = 0;
    if (!vpm_read(b->entity, record, sizeof record)) { SuspendHold(); return 0; }
    if (memcmp(record, b->identity, 24) != 0 || memcmp(avatar, b->avatar, 24) != 0) { ClearHold(); return 0; }
    int owned = LocalWeapon(b->identity[2], avatar[2], !check);
    int found = owned == 1 ? ChargeEntry(b, &entry) : owned;
    if (found == UNKNOWN) { SuspendHold(); return 0; }
    if (found == 0) { ClearHold(); return 0; }
    if (entry != b->entry)
    {
        b->entry = entry;
        s.hasPrevious = s.drove = 0;
        s.drovePeak = 0;
    }
    return 1;
}

/* Assists only after the engine issued a fire command for an Arc Thrower; discovery runs at most ten times a second. */
static int Arm(const uint32_t* avatar)
{
    Binding chosen;
    if (s.discovering && s.now < s.nextDiscovery) return 0;
    s.discovering = 1;
    s.nextDiscovery = s.now + DISCOVERY_INTERVAL;
    if (!ActiveArc(avatar, &chosen)) return 0;
    s.resolved = chosen;
    memcpy(s.resolved.avatar, avatar, 24);
    s.armed = 1;
    s.drove = 0;
    s.drovePeak = 0;
    s.progressKnown = 1;
    s.progressTime = s.now;
    return 1;
}

/* A cycle stalled below a quarter of the full charge for 1.2 s: the current binding is looked up again (the engine's
 * one-shot command may be cleared by now, which alone does not end the hold). 1 when the hold moved to another weapon:
 * this tick writes nothing. */
static int RecheckStall(VpmComponent* self, const uint32_t* avatar, double value, double full)
{
    Binding chosen;
    if (!s.drove)
    {
        s.drove = 1;
        s.droveSince = s.now;
        s.drovePeak = value;
    }
    if (value > s.drovePeak) s.drovePeak = value;
    if (!(s.now - s.droveSince > 1.2 && s.drovePeak < full * 0.25)) return 0;
    s.rescans++;
    if (!s.stallLogged)
    {
        s.stallLogged = 1;
        vpm_log(self, "entry %#llx stalled (peak %.3f) - checking the current binding (#%u); logged once per session",
            (unsigned long long)s.resolved.entry, s.drovePeak, s.rescans);
    }
    int found = ActiveArc(avatar, &chosen);
    s.droveSince = s.now;
    s.drovePeak = value;
    if (!found || (chosen.entity == s.resolved.entity && memcmp(chosen.identity, s.resolved.identity, 24) == 0 &&
        chosen.entry == s.resolved.entry))
        return 0;
    memcpy(chosen.avatar, avatar, 24);
    s.resolved = chosen;
    s.hasPrevious = 0;
    return 1;
}

/* The charge progress of this cycle; a sustained lack of it (a missing record flag can leave the charge stuck at full)
 * asks for the record to be looked up again. */
static void TrackProgress(double value, double full)
{
    int had = s.hasPrevious;
    double previous = s.previous, change = value - s.previous, limit = full * 1.5 > 1.2 ? full * 1.5 : 1.2;
    s.previous = value;
    s.hasPrevious = 1;
    if (!had || change > 1e-4 || change < -1e-4)
    {
        s.progressKnown = 1;
        s.progressTime = s.now;
    }
    if (s.now - (s.progressKnown ? s.progressTime : s.now) > limit)
    {
        s.rescanRequested = 1;
        s.progressKnown = 1;
        s.progressTime = s.now;
    }
    if (had && value < previous - 0.01)
    {
        s.drove = 1;
        s.droveSince = s.now;
        s.drovePeak = value;
    }
}

/* The charging flag, set when the engine has cleared it. The entry's page is checked right before the first write of a
 * binding and again whenever the entry moves to another page: committed private read-write memory, else nothing is
 * written and the component stops. */
static void SetChargingFlag(VpmComponent* self)
{
    Binding* b = &s.resolved;
    uintptr_t address = b->entry + AT_CHARGING, page = address & ~(uintptr_t)0xFFFu;
    if (b->checkedPage != page)
    {
        MEMORY_BASIC_INFORMATION info;
        char text[96];
        memset(&info, 0, sizeof info);
        int known = VirtualQuery((const void*)address, &info, sizeof info) != 0; /* lint-ok: C4 once per binding and page, on the tick that writes */
        if (!known || info.State != MEM_COMMIT || info.Type != MEM_PRIVATE || info.Protect != PAGE_READWRITE)
        {
            if (!known) snprintf(text, sizeof text, "protection query failed");
            else snprintf(text, sizeof text, "state %#lx, protection %#lx, type %#lx", info.State, info.Protect, info.Type);
            vpm_fail(self, "charge entry %#llx is not private read-write memory (%s)", (unsigned long long)b->entry, text);
            return;
        }
        b->checkedPage = page;
    }
    *(volatile uint8_t*)address = 1;
}

/* The engine's charge updater advances the charge by the frame time while the flag is set and fires when it crosses the
 * full-charge time, so keeping the flag set is the whole job. */
static void DriveCharge(VpmComponent* self, const uint32_t* avatar, float held)
{
    uint32_t entry[10];
    s.suspended = 0;
    s.heldKnown = 1;
    s.heldTime = held;
    if (!vpm_read(s.resolved.entry, entry, sizeof entry)) return;
    double value = Float(entry[1]), full = Float(entry[2]);
    if (!(full > 0.1) || !(value >= 0.0)) return; /* NaN fails both */
    if (RecheckStall(self, avatar, value, full)) return;
    TrackProgress(value, full);
    if ((entry[3] & 0xFFu) != 1u) SetChargingFlag(self);
}

/* Fire is held: an interrupted hold ends, the binding is kept or armed, then the charge driven. */
static void FollowPress(VpmComponent* self, const uint32_t* avatar, float held, int check)
{
    if (s.suspended && (s.now - s.suspendedSince >= RECOVERY_WINDOW || (s.heldKnown && held < s.heldTime))) ClearHold();
    if (s.armed && !Revalidate(avatar, check)) return;
    if (!s.armed && !Arm(avatar)) return;
    DriveCharge(self, avatar, held);
}

/* The full check of the local Fire input and the hold it drives. Unknown input is not a release: a followed press is
 * suspended, nothing written until everything checks out again. */
static void FollowInput(VpmComponent* self, int check)
{
    float held = 0;
    uintptr_t slot = 0;
    int down = LocalFire(check, &held, &slot);
    s.fireSlot = slot;
    if (down == UNKNOWN)
    {
        if (Holding()) SuspendHold();
        else s.hasPrevious = 0;
        return;
    }
    if (!down)
    {
        ClearHold();
        return;
    }
    FollowPress(self, s.kept.record, held, check);
}

/* One tick. An idle tick reads at most the gate's one word: in a mission (no check frame, no press followed, Fire up)
 * the kept Fire slot; outside a mission nothing, except on poll frames. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.now += dt;
    s.frames = s.frames + 1 >= POLL_FRAMES ? 0 : s.frames + 1;
    int poll = s.frames == 0;
    if (poll) PollMission();
    if (!s.mission)
    {
        if (poll) Maintain(self, poll);
        return;
    }
    int check = s.frames % CHECK_FRAMES == 0;
    if (!check && !Holding() && !FireMayBeHeld()) return;
    Maintain(self, poll);
    FollowInput(self, check);
}

/* ---- lifecycle ----------------------------------------------------------------------------------------------------- */

/* The fire-mode setter's code, checked first (the Lua's build fingerprint). */
static const VpmCodePin kPins[] = {
    {FIRE_MODE_SETTER, "48 89 4C 24 08 53 55 56 57 41 57 48 83 EC 20", "the fire-mode setter", 0},
};

/* The record, once the setter's code has been checked; again when the game reloads its entity data (the record may have
 * moved; HellForge renews the live edit). */
static void EntitiesReady(VpmComponent* self, HfEvent event)
{
    if (vpm_ticking(self))
    {
        s.record = 0;
        s.patched = 0;
        s.nextScan = s.now;
        PatchRecord(self);
        return;
    }
    if (!s.codeReady) { s.entitiesReady = 1; return; }
    PatchRecord(self);
    if (!vpm_tick_start(self, Tick)) vpm_fail(self, "no game-thread tick");
}

/* The setter's bytes read as shipped (at HF_EVENT_GAME_LOADED, or on the frame they first do): the event's work, if it
 * came first. */
static void CodeReady(VpmComponent* self, HfEvent event)
{
    s.codeReady = 1;
    if (s.entitiesReady) EntitiesReady(self, HF_EVENT_ENTITIES_READY);
}

/* Ends the hold (the engine clears the charging flag itself on its next frame) and undoes the record's live edit. */
static void Stop(VpmComponent* self)
{
    if (s.wrote && vpm_hf()->set_live(vpm_mod(), ARC_ENTITY, &kAutoFire, NULL, 0) == 0)
        vpm_log(self, "the charge record's auto-fire flag could not be put back (%s)", vpm_hf()->last_log(vpm_mod()));
    s.wrote = s.patched = 0;
    ClearHold();
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.frames = POLL_FRAMES - 1; /* the first tick is a poll frame */
    if (!vpm_when_code_ready(self, kPins, 1, CodeReady)) return 1;
    return vpm_on_load(self, HF_EVENT_ENTITIES_READY, EntitiesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_arc_thrower_revamped = {"arc_thrower_revamped", "Arc Thrower Revamped", "1.7.1", 0, Start, Stop};
