/* Hellpod Steering Unlocked v7.5.1 (Lua: components/HellpodSteeringUnlocked/src/steering_patch.lua, and the poll in
 * archive_loader.lua), build 25480438.
 *
 * The game's base hellpod avoidance system steers a descending pod away from excluded areas (rooftops, rocks, high
 * ground) instead of following the player's input. Its manager ([game.dll + 0x346D578], owned by [game.dll + 0x347CF18]
 * at +0x7C8C90) starts with a one-byte enable flag that mission initialization sets to 1, in storage that sits blank (all
 * zero) aboard ship. This clears that flag to 0, the only change, as the Lua did: everything that reads the flag sees it
 * off, so the pod follows the player's steering over any ground, the keep-out check (game.dll 0x92A390) returns at once,
 * and the city-map clearing push that reads the same flag is gone too (KB hellforge-megapack-native-port, section 3).
 * Every other byte of the manager stays as the game wrote it.
 *
 * Checks, as the Lua made them: both pointers user-mode, the manager exactly owner + 0x7C8C90, five fields readable, then
 * either blank (the ship: wait) or a valid layout (record and link counts, the set's self-pointer and sizes, the map
 * geometry); right before the store the manager, owner, flag, set and dimensions are read again (mission initialization
 * can reset the manager in between), and the whole manager must be committed private read-write memory. The flag is
 * written only over the game's own 1; a 0 needs nothing, and any other value belongs to another writer: it is left alone,
 * reported once and polling goes on. Anything it cannot verify stops the component (vpm_fail), and stop() puts the game's
 * 1 back only over its own 0, in the same manager, owner, set and dimensions, rechecked right before the store.
 *
 * Timing (archive_loader.lua): a poll every 100 ms of game time (dt; a zero, negative or NaN dt adds nothing), the first
 * on the first frame. Between full checks a poll reads only the flag byte (patch.idle): the value the last full check saw
 * means nothing to do; any other value, or a failed read, runs the full check on that same poll, so a mission reset is
 * cleared within one poll. Every 10th poll is a full check anyway (the manager going blank, moved pointers, a layout
 * change are noticed at most 1 s late). Status lines are logged when the status changes, with the Lua's texts
 * ("waiting_for_mission", "avoidance_settings_ready", "avoidance_flag_set_by_another_writer"...).
 *
 * On HellForge:
 * - The two game.dll slots are plain loads (inside the image), not ReadProcessMemory; the manager is heap and is read
 *   through vpm_read. HellForge does not move the manager or its owner.
 * - The page check is this file's PrivateData: the Lua runtime's rule (committed, MEM_PRIVATE, exactly PAGE_READWRITE),
 *   which vpm_writable does not check (it also accepts execute-read-write and image or mapped pages). The store is a plain
 *   one-byte store after that check, where the Lua used WriteProcessMemory: a write that fails after the check faults
 *   instead and the core's guard stops the component.
 * - The 100 ms flag poll is kept in every game state. HF_ON_STATE / HF_ON_MISSION_START do not replace it: the Lua polls
 *   no game state, it watches the flag itself, and the flag's change is not one of those events (a live join saw it 0.1 s
 *   before the state went to mission, KB hotjoin-hellpod-drop-research; a mission reset or another writer during a
 *   mission has no event at all), so an event-driven write would not be exactly equivalent.
 * - The tick runs before the game's update each frame; the Lua's poll ran after the update below it (one frame apart).
 * - Dropped: the Lua update guard's pause and resume after an error in an update below this mod, its 8-errors-in-a-burst
 *   stop and its shutdown handling (HellForge has no update chain below the pack and no shutdown event; the core's crash
 *   guard stops the component on a fault in its own code, and stop() restores). This component stays off while
 *   HellForge's bundled Vanilla Plus (its narrower steering patch at 0x92E0A1) is in the session.
 *
 * COST per frame (60 FPS: a poll every 6 frames), C against the Lua's frame_budget pins (tests/test_data.lua):
 * - frames between polls: 0 calls (the Lua: 0).
 * - an idle poll (9 of 10, ship or mission): 1 read, the flag byte (the Lua: 1).
 * - a full check (every 10th poll, or when the flag changed): 5 reads (the Lua: 7; its two slot reads are plain loads
 *   here). Before the pointers exist: 0 reads per poll (the Lua: 2).
 * - the poll that clears (once per mission): 10 reads, 1 VirtualQuery per memory region of the 69,688-byte manager
 *   (normally 1) and one plain store (the Lua: 14 reads, 1 page check, 1 WriteProcessMemory).
 * - another writer's value seen: 6 reads, then 1 per poll (the Lua: 8, then 1).
 * - stop() over its own write: 9 reads, 1 VirtualQuery per region, one store (the Lua's restore: 13, 1, 1).
 * No allocation and no log line on a frame whose status does not change. Once only: nothing (no code or pattern checks:
 * the core checks the build). */
#include <string.h>
#include <stdio.h>
#include <windows.h>
#include "../../core/vpm.h"

#define MANAGER_RVA 0x346D578u  /* game.dll: the hellpod avoidance manager's pointer */
#define OWNER_RVA 0x347CF18u    /* game.dll: its owner's pointer */
#define OWNER_OFFSET 0x7C8C90u  /* the manager is its owner + this */
#define MANAGER_SIZE 69688u     /* the manager's whole size: the page check covers it */
#define AT_FLAG 0u              /* the enable byte */
#define AT_RECORDS 32772u       /* u32 record count, at most 1024 */
#define AT_LINKS 65544u         /* u32 link count, at most 8192 */
#define AT_SET 65552u           /* the set (24 bytes): a pointer to manager + 65576, 1024, a count <= 1024, 3, one more word */
#define AT_SET_DATA 65576u
#define AT_DIMS 69672u          /* four floats: map width (64 .. 16384), half width, cell (width / 64), 1 / cell */
#define GAME_VALUE 1u           /* the game's value, set by mission initialization: the only value this replaces */
#define OWN_VALUE 0u            /* this component's value */
#define POLL 0.1                /* seconds between polls */
#define REVALIDATE 10           /* every 10th poll is a full check */

/* The manager as a full check read it (the Lua's view). */
typedef struct Manager
{
    uintptr_t manager, owner;
    uint8_t enabled;
    uint32_t set[6];
    float dims[4];
} Manager;

/* The five fields a full check reads. */
typedef struct Fields
{
    uint8_t flag;
    uint32_t records, links;
    uint32_t set[6];
    float dims[4];
} Fields;

/* A full check's result (the Lua's inspect): valid with the manager, else whether to keep polling, the status, and the
 * blank manager's address when it is blank. */
typedef struct Inspection
{
    int valid, polling;
    const char* status;
    uintptr_t blank;
} Inspection;

/* A poll's result (the Lua's apply): accepted (0 stops the component), the status, and whether the flag is cleared. */
typedef struct Outcome
{
    int accepted;
    const char* status;
    int active;
} Outcome;

static struct
{
    double elapsed;      /* game time since the last poll (POLL at start: the first frame polls) */
    uintptr_t watch;     /* the idle gate: the manager whose flag alone answers a poll, 0 none */
    uint8_t watchValue;  /* the flag value the last full check saw there */
    int watchLeft;       /* polls left before the next full check */
    int owned;           /* this component's own write is recorded in own */
    Manager own;         /* the manager, owner, set and dimensions it cleared */
    char status[96];     /* the last status reported */
} s;

static double Abs(double value) { return value < 0 ? -value : value; }

/* The user-mode pointer in a game.dll slot (the Lua runtime's pointer rules): 0 when null, below 0x10000 or above the
 * 47-bit user range. */
static uintptr_t SlotPointer(uint32_t rva)
{
    uint64_t value = vpm_game_u64(rva);
    return value >= 0x10000u && (value >> 32) < 0x8000u ? (uintptr_t)value : 0;
}

/* All five reads, as the Lua made them, then whether every one succeeded. */
static int ReadFields(uintptr_t manager, Fields* f)
{
    int flag = vpm_read_u8(manager + AT_FLAG, &f->flag);
    int records = vpm_read_u32(manager + AT_RECORDS, &f->records);
    int links = vpm_read_u32(manager + AT_LINKS, &f->links);
    int set = vpm_read(manager + AT_SET, f->set, sizeof f->set);
    int dims = vpm_read(manager + AT_DIMS, f->dims, sizeof f->dims);
    return flag && records && links && set && dims;
}

/* An exact +0.0: all four bytes zero. */
static int Zero(float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits == 0;
}

/* Aboard ship the storage exists but is not initialized: every field read is zero. */
static int Blank(const Fields* f)
{
    static const uint32_t none[6];
    return f->flag == 0 && f->records == 0 && f->links == 0 && memcmp(f->set, none, sizeof none) == 0 &&
        Zero(f->dims[0]) && Zero(f->dims[1]) && Zero(f->dims[2]) && Zero(f->dims[3]);
}

/* a within 0.001% of b (at least 0.00001); false for a NaN. In double, as the Lua's numbers. */
static int Near(double a, double b)
{
    double limit = Abs(b) * 0.00001;
    if (limit < 0.00001) limit = 0.00001;
    return Abs(a - b) <= limit;
}

/* Record and link bounds, the set's self-pointer and sizes and the map geometry of an initialized manager. The flag is
 * classified apart (Apply). */
static int LayoutValid(uintptr_t manager, const Fields* f)
{
    double width = f->dims[0], half = f->dims[1], cell = f->dims[2], reciprocal = f->dims[3];
    uint64_t self = (uint64_t)f->set[1] << 32 | f->set[0];
    return f->records <= 1024u && f->links <= 8192u && f->set[1] < 0x8000u && self - manager == AT_SET_DATA &&
        f->set[2] == 1024u && f->set[3] <= 1024u && f->set[4] == 3u && width >= 64 && width <= 16384 &&
        Near(half, width / 2) && Near(cell, width / 64) && Near(reciprocal, 1 / cell);
}

/* A full check: the two slots (plain loads), then the manager's five fields (5 reads). */
static Inspection Inspect(Manager* v)
{
    Inspection r = {0, 1, "waiting_for_mission", 0};
    uintptr_t manager = SlotPointer(MANAGER_RVA), owner = SlotPointer(OWNER_RVA);
    if (manager == 0 || owner == 0) return r;
    r.polling = 0;
    if (manager - owner != OWNER_OFFSET) { r.status = "avoidance_owner_mismatch"; return r; }
    Fields f;
    if (!ReadFields(manager, &f)) { r.status = "avoidance_fields_unreadable"; return r; }
    if (Blank(&f)) { r.polling = 1; r.blank = manager; return r; }
    if (!LayoutValid(manager, &f)) { r.status = "avoidance_layout_mismatch"; return r; }
    v->manager = manager;
    v->owner = owner;
    v->enabled = f.flag;
    memcpy(v->set, f.set, sizeof v->set);
    memcpy(v->dims, f.dims, sizeof v->dims);
    r.valid = 1;
    r.polling = 1;
    r.status = NULL;
    return r;
}

/* The dimensions compared as numbers, as the Lua compared them. */
static int SameDims(const float* a, const float* b)
{
    for (int i = 0; i < 4; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

/* Whether v is the manager this component cleared: the same manager, owner, set and dimensions. */
static int Owns(const Manager* v)
{
    return s.owned && s.own.manager == v->manager && s.own.owner == v->owner &&
        memcmp(s.own.set, v->set, sizeof v->set) == 0 && SameDims(s.own.dims, v->dims);
}

/* Identity and the exact target again, right before a store: the slots (plain loads), then the flag, set and dimensions
 * (up to 3 reads), stopping at the first difference. */
static int Stable(const Manager* v, uint8_t expected)
{
    uint8_t flag = 0;
    uint32_t set[6];
    float dims[4];
    return SlotPointer(MANAGER_RVA) == v->manager && SlotPointer(OWNER_RVA) == v->owner &&
        vpm_read_u8(v->manager + AT_FLAG, &flag) && flag == expected &&
        vpm_read(v->manager + AT_SET, set, sizeof set) && memcmp(set, v->set, sizeof set) == 0 &&
        vpm_read(v->manager + AT_DIMS, dims, sizeof dims) && SameDims(dims, v->dims);
}

/* Whether [address, address + size) is committed private read-write data, never code, read-only, guard, image or mapped
 * pages (the Lua runtime's writable_data). One VirtualQuery per memory region. */
static int PrivateData(uintptr_t address, size_t size)
{
    uintptr_t at = address, end = address + size;
    if (size == 0 || end < address) return 0;
    while (at < end)
    {
        MEMORY_BASIC_INFORMATION info;
        if (VirtualQuery((const void*)at, &info, sizeof info) != sizeof info) return 0; /* lint-ok: C4 only on the poll that stores, right before the store */
        if (info.State != MEM_COMMIT || info.Type != MEM_PRIVATE || info.Protect != PAGE_READWRITE) return 0;
        uintptr_t regionEnd = (uintptr_t)info.BaseAddress + info.RegionSize;
        if (regionEnd <= at) return 0;
        at = regionEnd;
    }
    return 1;
}

/* The single store: the page check over the whole manager, the one-byte store, the read-back. NULL, or the failure. */
static const char* WriteFlag(uintptr_t manager, uint8_t value)
{
    if (!PrivateData(manager, MANAGER_SIZE)) return "avoidance_is_not_writable_private_data";
    *(volatile uint8_t*)(manager + AT_FLAG) = value;
    uint8_t now = 0;
    if (!vpm_read_u8(manager + AT_FLAG, &now) || now != value) return "avoidance_data_write_failed";
    return NULL;
}

/* Clears the game's value in a manager that is still the one just checked. */
static Outcome Clear(const Manager* v)
{
    if (!Stable(v, GAME_VALUE)) return (Outcome){1, "waiting_for_stable_mission", 0};
    const char* failure = WriteFlag(v->manager, OWN_VALUE);
    if (failure != NULL) return (Outcome){0, failure, 0};
    s.own = *v;
    s.owned = 1;
    return (Outcome){1, "avoidance_settings_ready", 1};
}

/* The next REVALIDATE - 1 polls read only this manager's flag while it holds value. */
static void Arm(uintptr_t manager, uint8_t value)
{
    s.watch = manager;
    s.watchValue = value;
    s.watchLeft = REVALIDATE - 1;
}

/* The idle gate (the Lua's patch.idle): 1 when the flag holds the value the last full check saw and no full check is
 * due (the poll is done: 1 read); 0 runs the full check now, and drops the watch. lint: per-frame */
static int Idle(void)
{
    if (s.watch == 0) return 0;
    if (s.watchLeft <= 0) { s.watch = 0; return 0; }
    uint8_t flag = 0;
    if (!vpm_read_u8(s.watch + AT_FLAG, &flag) || flag != s.watchValue) { s.watch = 0; return 0; }
    s.watchLeft--;
    return 1;
}

/* A full check and, over the game's value, the clear (the Lua's patch.apply). A check that read the flag of a blank or
 * valid manager, and needs no recheck at the next poll, arms the watch with that value. */
static Outcome Apply(void)
{
    s.watch = 0;
    Manager v = {0};
    Inspection found = Inspect(&v);
    if (!found.valid)
    {
        s.owned = 0;
        if (found.blank != 0) Arm(found.blank, 0);
        return (Outcome){found.polling, found.status, 0};
    }
    if (v.enabled == OWN_VALUE)
    {
        if (!Owns(&v)) s.owned = 0;
        Arm(v.manager, OWN_VALUE);
        return (Outcome){1, "avoidance_settings_ready", 1};
    }
    s.owned = 0;
    if (v.enabled != GAME_VALUE)
    {
        Arm(v.manager, v.enabled);
        return (Outcome){1, "avoidance_flag_set_by_another_writer", 0};
    }
    Outcome cleared = Clear(&v);
    if (cleared.active) Arm(v.manager, OWN_VALUE);
    return cleared;
}

/* Puts the game's value back, only over this component's own write, rechecked right before the store (the Lua's
 * patch.restore). Forgets the write either way. The outcome: "nothing_to_restore", "avoidance_left_unchanged",
 * "avoidance_restored", or the store's failure. */
static const char* Restore(void)
{
    s.watch = 0;
    if (!s.owned) return "nothing_to_restore";
    Manager v = {0};
    Inspection found = Inspect(&v);
    int ours = found.valid && v.enabled == OWN_VALUE && Owns(&v);
    s.owned = 0;
    if (!ours || !Stable(&v, OWN_VALUE)) return "avoidance_left_unchanged";
    const char* failure = WriteFlag(v.manager, GAME_VALUE);
    return failure != NULL ? failure : "avoidance_restored";
}

/* The status as the Mods tab shows it, logged when it changes (the Lua's report). */
static void Report(VpmComponent* self, const char* status)
{
    if (strcmp(s.status, status) == 0) return;
    snprintf(s.status, sizeof s.status, "%s", status);
    vpm_set_status(self, status);
    vpm_log(self, "%s", status);
}

/* The game-thread tick: the 100 ms poll. Between polls: a compare, no call. lint: per-frame */
static void Poll(VpmComponent* self, float dt)
{
    if (dt > 0.0f) s.elapsed += dt; /* false for a zero, negative or NaN dt, which the Lua did not count either */
    if (s.elapsed < POLL) return;
    s.elapsed = 0;
    if (Idle()) return;
    Outcome outcome = Apply();
    if (!outcome.accepted)
    {
        vpm_fail(self, "%s", outcome.status);
        return;
    }
    Report(self, outcome.status);
}

/* Puts the game's value back over this component's own write when the core stops it (vpm_fail, or a fault). */
static void Stop(VpmComponent* self)
{
    const char* outcome = Restore();
    if (strcmp(outcome, "nothing_to_restore") != 0) vpm_log(self, "%s; %s", vpm_status(self), outcome);
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.elapsed = POLL;
    Report(self, "waiting_for_mission");
    if (!vpm_tick_start(self, Poll)) return vpm_fail(self, "Game update unavailable; no change applied");
    return 0;
}

const VpmComponentDef vpm_component_hellpod_steering_unlocked = {"hellpod_steering_unlocked", "Hellpod Steering Unlocked", "7.5.1", VPM_OVERLAPS_VANILLA_PLUS, Start, Stop};
