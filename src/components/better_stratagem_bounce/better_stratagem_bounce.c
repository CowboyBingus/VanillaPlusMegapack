/* Better Stratagem Bounce v15.4.1 (Lua: components/BetterStratagemBounce/src/navigation_patch.lua and
 * archive_loader.lua), for build 25480438.
 *
 * Stratagem balls bounce off roofs, rocks and props. A stratagem whose settings row sets deploy_on_navmesh_only
 * (beacon_flags, +0x170, bit 0x02; the game tests it at game.dll 0x69CD25) sticks only where the navmesh lies within
 * 0.1 m of the hit and otherwise bounces on. This clears that bit, once per session, in the 103 rows whose
 * supported-build flags set it (navigation_flags.h), of the game's 149. The other landing rules stay (the slope limit of
 * about 45.6 degrees, the areas a mission keeps hellpods out of, the deploy path). The byte's other bits belong to the
 * game and to other mods: only this bit decides whether a row is changed, and a bit already clear is accepted and never
 * written.
 *
 * As the Lua, before anything changes: the loaded settings ([game + 0x348E8F8], 80280 bytes in eleven groups) are read
 * whole and checked: every group header, every record within its group, every record's stratagem type within 1 .. 149
 * and present once, the stratagem list's slot for each type holding that record, 149 records, 103 owned. Right before
 * the changes the settings are read again (unchanged) and their pages checked (committed read-write); after them, read
 * once more (exactly the planned bytes changed). A failure part-way takes back the changes made, and the log says
 * whether that left nothing of this component's.
 *
 * On HellForge:
 * - Each row is changed by identity, not by address: set_live(stratagem type, StratagemSettings.beacon_flags), a mapped
 *   field, with the row's byte less bit 0x02. HellForge finds the row through the stratagem list the game reads now,
 *   writes the byte, keeps the change for the session (made again if the game reloads its data) and reports a conflict
 *   with another mod's edit of the field. Taking a change back (a failure part-way, or the core stopping the component)
 *   is set_live(type, NULL): HellForge puts back the byte from before wherever the row still holds this change. The
 *   field is the whole byte, so a byte someone changed since keeps this change (the Lua set its bit back alone).
 * - HellForge moves the stratagem list when mods add stratagems and rewrites every instruction that reads it, so the
 *   list the records are checked against is taken from the displacement of one of them (game.dll 0x62F087,
 *   `mov rax, [rcx + rdx*8 + list]` in 0x62EC20), not from the vanilla address 0x37CB600.
 * - Stratagems mods add (types 150 and up) are left as they are. Their rows are HellForge's copies of a vanilla row,
 *   made when the game loaded its stratagems (before this runs), so each keeps the beacon flags of the stratagem it
 *   copies. The Lua's rule names only the game's 149 types, and it refused any other record.
 * - It runs at HF_EVENT_ENTITIES_READY, on HellForge's thread (the stratagem settings load before the entity data);
 *   the Lua ran on the game's first update after it loaded. The reader's code is checked first, with
 *   vpm_when_code_ready from HF_EVENT_GAME_LOADED: game.dll's code is decoded in parts after that event, and nothing
 *   orders the entity data after the reader's part (HellForge gives its own stratagem pins 20 s after the game loaded
 *   its stratagems). Until the reader reads as shipped, HF_EVENT_ENTITIES_READY's work waits; the core stops the
 *   component if it never does within 60 s ("the stratagem list's reader changed (game.dll 0x62F087)"), with nothing
 *   changed. After the checks and before the first change, a get_live
 *   of the first row to change says whether HellForge can read the stratagem rows (it cannot while it has not settled
 *   the list, and a set_live then would only queue). If not yet, a tick asks again every 30 frames and makes the whole
 *   attempt again once it can, for at most 600 s, where the Lua would have failed.
 * - Dropped: the Lua's SHA-256 checks of both modules (the core checks the build), its update hook and loader (the
 *   pcall guards, the hook's removal, its LuaJIT notes) and its log file (vpm_log takes the same lines).
 *
 * Cost: per frame, none: no tick once applied (the Lua: 0 calls per idle frame, pinned by its frame_budget). Once per
 * session, at HF_EVENT_GAME_LOADED: 1 code check (the core repeats it every 30 frames while the code is not decoded,
 * for at most 60 s). At HF_EVENT_ENTITIES_READY (or when the code is decoded, if that comes later): 2 plain loads, and
 * reads of the settings (80280 bytes) and the list (1200 bytes, 1584 when moved); with something to change, also
 * 1 get_live, a read of the settings before and one after the
 * changes, a page check (1 VirtualQuery for the settings' region) and 1 set_live per row: 4 reads, 1 get_live, 1
 * VirtualQuery and 103 set_live. Each set_live is a protected write inside HellForge (two VirtualProtect calls, an
 * instruction cache flush, two ReadProcessMemory and two GetModuleHandleA: about 7 Windows calls, unmeasured in game),
 * so the one-off work is about 730 Windows calls where the Lua made 6 reads, 1 VirtualQuery and 103 WriteProcessMemory
 * (plus its two module hashes): the price of HellForge's identity route, paid once, at load. While HellForge cannot
 * read the rows yet: no call on 29 frames of 30, 1 get_live (4 Windows calls inside HellForge) on the 30th. */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"
#include "navigation_flags.h"

#define BUFFER_RVA 0x348E8F8u        /* the loaded generated_stratagem_settings */
#define DATA_SIZE 80280u
#define GROUPS 11u
#define GROUP_MAGIC 0x444C444Cu      /* each group's header: magic, 1, type, payload size, 1, 0 */
#define GROUP_TYPE 0x30EB6399u
#define HEADER_SIZE 24u
#define RECORD_SIZE 400u             /* StratagemDefinition */
#define AT_FLAGS 0x170u              /* beacon_flags */
#define OWNED NAVIGATION_OWNED_BIT
#define LIST_SITE 0x62F087u          /* mov rax, qword ptr [rcx + rdx*8 + 0x37CB600]: a reader of the list */
#define VANILLA_LIST 0x37CB600u
#define SLOTS 150u                   /* the game's list: types 0 .. 149 */
#define MOVED_SLOTS 198u             /* HellForge's moved list: 150, and room for 48 that mods add */
#define RETRY_FRAMES 30
#define WAIT_SECONDS 600.0f

/* One planned change: the flag byte's offset in the settings, its row's stratagem type, the byte to set. */
typedef struct Change { uint32_t at; uint32_t kind; uint8_t value; } Change;
typedef const char* Why; /* why a check failed (the Lua's assert texts), or NULL */

static struct
{
    uint64_t pointer;       /* [game + 0x348E8F8] as checked */
    uintptr_t buffer;       /* the settings it points to */
    int32_t displacement;   /* the list's, from its reader */
    uint32_t slots;         /* SLOTS, or MOVED_SLOTS */
    int records, owned, already, count;
    int landed;             /* changes set_live took, in order: what Undo takes back */
    Change changes[NAVIGATION_TYPES];
    uint8_t seen[NAVIGATION_TYPES + 1];
    int done;
    int code_ready;         /* the reader's bytes read as shipped (CodeReady) */
    int entities_ready;     /* HF_EVENT_ENTITIES_READY came first: CodeReady takes it up */
    int countdown;
    float waited;
    char why[96];
    char status[160];
} s;

static uint8_t g_source[DATA_SIZE]; /* the settings as checked, then as they should be after the changes */
static uint8_t g_now[DATA_SIZE];    /* a later read of them */
static uint64_t g_list[MOVED_SLOTS];
static const HfField kFlags = HF_FIELD(StratagemSettings, beacon_flags);
static const VpmCodePin kPins[] = {
    {LIST_SITE, "48 8B 84 D1", "the stratagem list's reader", 0},
};

/* api.pointer: a value that can be a user-mode pointer, else 0. */
static uintptr_t Pointer(uint64_t value) { return vpm_plausible((uintptr_t)value) ? (uintptr_t)value : 0; }

/* One record: its type within 1 .. 149 and not seen before, and the list's slot for it holding this record. Then only
 * this component's bit decides: a row it owns with the bit set is planned, one with the bit clear is accepted. */
static Why PlanRecord(uint32_t record)
{
    uint32_t kind;
    memcpy(&kind, g_source + record, 4);
    if (kind < 1 || kind > NAVIGATION_TYPES || s.seen[kind]) return "Unexpected or duplicate stratagem";
    if (Pointer(g_list[kind]) != s.buffer + record) return "Settings table identity mismatch";
    s.seen[kind] = 1;
    s.records++;
    if (!(kNavigationFlags[kind - 1] & OWNED)) return NULL;
    s.owned++;
    uint8_t flags = g_source[record + AT_FLAGS];
    if (!(flags & OWNED)) { s.already++; return NULL; }
    s.changes[s.count++] = (Change){record + AT_FLAGS, kind, (uint8_t)(flags & ~OWNED)};
    return NULL;
}

/* A group's records: {items pointer, count} at its root, the records inside the group. */
static Why PlanGroup(uint32_t root, uint32_t finish)
{
    uint32_t count;
    uint64_t items;
    memcpy(&count, g_source + root + 8, 4);
    if (count == 0 || count > NAVIGATION_TYPES) return "Invalid record count";
    memcpy(&items, g_source + root, 8);
    uintptr_t first = Pointer(items);
    if (first == 0) return "Settings items unavailable";
    int64_t start = (int64_t)first - (int64_t)s.buffer;
    if (start < (int64_t)root + 16 || start + (int64_t)count * RECORD_SIZE > (int64_t)finish) return "Settings records out of bounds";
    for (uint32_t i = 0; i < count; i++)
    {
        Why why = PlanRecord((uint32_t)start + i * RECORD_SIZE);
        if (why != NULL) return why;
    }
    return NULL;
}

/* A group's header at offset: 1 as reviewed (*size its payload's), 0 not, -1 past the settings' end. */
static int Header(uint32_t offset, uint32_t* size)
{
    uint32_t field[6];
    if (offset > DATA_SIZE - HEADER_SIZE) return -1;
    memcpy(field, g_source + offset, sizeof field);
    *size = field[3];
    return field[0] == GROUP_MAGIC && field[1] == 1 && field[2] == GROUP_TYPE && field[4] == 1 && field[5] == 0;
}

/* The Lua's prepare over g_source: every group and record checked, the changes planned in the settings' order (the
 * order the Lua's sort gives: groups follow one another and a group's records lie inside it). */
static Why Plan(void)
{
    uint32_t groups, offset = 4;
    memcpy(&groups, g_source, 4);
    if (groups != GROUPS) return "Unexpected settings group count";
    for (uint32_t group = 0; group < GROUPS; group++)
    {
        uint32_t size = 0;
        int header = Header(offset, &size);
        if (header < 0) return "Settings field out of bounds";
        if (header == 0) return "Unexpected settings header";
        uint32_t root = offset + HEADER_SIZE;
        if (size < 16 || size > DATA_SIZE - root) return "Settings group out of bounds";
        Why why = PlanGroup(root, root + size);
        if (why != NULL) return why;
        offset = root + size;
    }
    if (offset != DATA_SIZE || s.records != NAVIGATION_TYPES || s.owned != NAVIGATION_OWNED) return "Incomplete stratagem settings";
    return NULL;
}

/* The list the game reads now, from its reader's displacement (relative to game.dll's base), or 0. The reader's code
 * was checked before (CodeReady). */
static uintptr_t CurrentList(void)
{
    if (!vpm_game_read(LIST_SITE + 4, &s.displacement, 4)) return 0;
    s.slots = (uint32_t)s.displacement == VANILLA_LIST ? SLOTS : MOVED_SLOTS;
    return vpm_game() + (uintptr_t)(intptr_t)s.displacement;
}

/* The settings and the list into g_source and g_list, the plan's counts reset. */
static Why ReadAll(uintptr_t list)
{
    s.records = s.owned = s.already = s.count = s.landed = 0;
    memset(s.seen, 0, sizeof s.seen);
    s.pointer = vpm_game_u64(BUFFER_RVA);
    s.buffer = Pointer(s.pointer);
    if (s.buffer == 0) return "Settings buffer unavailable";
    if (!vpm_read(s.buffer, g_source, DATA_SIZE)) return "Cannot read settings";
    if (!vpm_read(list, g_list, (size_t)s.slots * 8)) return "Cannot read settings table";
    return NULL;
}

static void LogMoved(VpmComponent* self)
{
    int added = 0;
    for (uint32_t type = SLOTS; type < MOVED_SLOTS; type++) added += g_list[type] != 0;
    vpm_log(self, "the stratagem list was moved by HellForge (game.dll %+d): %d stratagem(s) mods added (types 150 and up) "
        "keep the beacon flags of the stratagem each copies", s.displacement, added);
}

static int SetFlags(const Change* change)
{
    const HfValue value = HF_U8(change->value);
    return vpm_hf()->set_live(vpm_mod(), change->kind, &kFlags, &value, 0) != 0;
}

/* The Lua's write: the settings unchanged since the check, their pages writable, the changes, then a read-back that
 * must equal the checked settings with exactly the planned bytes changed. s.landed counts the changes made. */
static Why Write(void)
{
    if (vpm_game_u64(BUFFER_RVA) != s.pointer) return "Settings buffer changed";
    if (!vpm_read(s.buffer, g_now, DATA_SIZE) || memcmp(g_now, g_source, DATA_SIZE) != 0) return "Settings changed during validation";
    if (vpm_writable(s.buffer, DATA_SIZE))
        while (s.landed < s.count && SetFlags(&s.changes[s.landed])) s.landed++;
    if (s.landed < s.count)
    {
        snprintf(s.why, sizeof s.why, "Settings write refused or failed after %d of %d flags", s.landed, s.count);
        return s.why;
    }
    for (int i = 0; i < s.count; i++) g_source[s.changes[i].at] = s.changes[i].value;
    if (!vpm_read(s.buffer, g_now, DATA_SIZE) || memcmp(g_now, g_source, DATA_SIZE) != 0) return "Settings verification failed";
    return NULL;
}

/* The Lua's patch.restore, through HellForge: the first `count` changes taken back (set_live(type, NULL)). 1 when none
 * of them remains: the settings still the same, each record still the same stratagem with its bit set again. */
static int Undo(int count)
{
    if (count == 0) return 1;
    int refused = 0;
    for (int i = 0; i < count; i++) refused += vpm_hf()->set_live(vpm_mod(), s.changes[i].kind, &kFlags, NULL, 0) == 0;
    s.landed = 0;
    if (refused > 0 || vpm_game_u64(BUFFER_RVA) != s.pointer || !vpm_read(s.buffer, g_now, DATA_SIZE)) return 0;
    for (int i = 0; i < count; i++)
    {
        uint32_t kind;
        memcpy(&kind, g_now + s.changes[i].at - AT_FLAGS, 4);
        if (kind != s.changes[i].kind || !(g_now[s.changes[i].at] & OWNED)) return 0;
    }
    return 1;
}

/* Whether HellForge can read a stratagem row now (get_live answers 0 while it has not settled the list). */
static int HellForgeReads(uint32_t type)
{
    HfLiveValue now;
    return vpm_hf()->get_live(vpm_mod(), type, &kFlags, &now) != 0;
}

/* 0 wait (HellForge cannot read the stratagem rows yet), 1 applied, -1 failed (vpm_fail called). */
#define WAIT 0
#define DONE 1
#define FAILED (-1)

/* One attempt: everything checked before anything changes, as the Lua's apply; then, with something to change, whether
 * HellForge can read the first row to change. */
static int Attempt(VpmComponent* self)
{
    if (vpm_game() == 0) { vpm_fail(self, "Game module unavailable"); return FAILED; }
    uintptr_t list = CurrentList();
    if (list == 0)
    {
        vpm_fail(self, "the stratagem list's reader at game.dll 0x%X is not the reviewed one", LIST_SITE);
        return FAILED;
    }
    Why why = ReadAll(list);
    if (why == NULL) why = Plan();
    if (why != NULL) { vpm_fail(self, "%s", why); return FAILED; }
    if (s.count > 0 && !HellForgeReads(s.changes[0].kind)) return WAIT;
    if (s.slots == MOVED_SLOTS) LogMoved(self);
    if (s.count > 0 && (why = Write()) != NULL)
    {
        int restored = Undo(s.landed);
        vpm_fail(self, "%s; partial-edit recovery=%s", why, restored ? "true" : "false");
        return FAILED;
    }
    return DONE;
}

static void Done(VpmComponent* self, int waited)
{
    char already[32] = "";
    if (s.already > 0) snprintf(already, sizeof already, " (%d already clear)", s.already);
    snprintf(s.status, sizeof s.status, "navigation_settings_ready: %d flags%s; executable code unchanged", NAVIGATION_OWNED,
        already);
    s.done = 1;
    vpm_set_status(self, s.status);
    vpm_log(self, "%s", s.status);
    if (waited) vpm_log(self, "applied after %.1f s of waiting", s.waited);
}

/* While HellForge cannot read the stratagem rows: a countdown per frame and, every 30 frames, a get_live of the first
 * row to change; the whole attempt again once it answers. lint: per-frame */
static void Wait(VpmComponent* self, float dt)
{
    s.waited += dt;
    if (--s.countdown > 0) return;
    s.countdown = RETRY_FRAMES;
    if (s.waited >= WAIT_SECONDS)
    {
        vpm_fail(self, "gave up after %.0f s: HellForge cannot read the stratagem rows yet", WAIT_SECONDS);
        return;
    }
    if (!HellForgeReads(s.changes[0].kind)) return;
    int result = Attempt(self);
    if (result == WAIT) return;
    vpm_tick_stop(self);
    if (result == DONE) Done(self, 1);
}

/* Once per session: HellForge makes the changes again itself when the game reloads its data (the event then fires
 * again, and finds this done). */
static void EntitiesReady(VpmComponent* self, HfEvent event)
{
    if (s.done || vpm_ticking(self)) return;
    if (!s.code_ready) { s.entities_ready = 1; return; }
    int result = Attempt(self);
    if (result == DONE) { Done(self, 0); return; }
    if (result == FAILED) return;
    vpm_log(self, "Waiting for HellForge: the stratagem rows cannot be read yet.");
    vpm_set_status(self, "waiting: HellForge cannot read the stratagem rows yet");
    s.countdown = RETRY_FRAMES;
    if (!vpm_tick_start(self, Wait)) vpm_fail(self, "the game thread could not be reached to wait for the stratagem rows");
}

/* Takes back this session's changes (the core stopping the component). */
static void Stop(VpmComponent* self)
{
    int count = s.landed;
    if (count > 0 && !Undo(count))
        vpm_log(self, "stopped: not every one of the %d beacon flags changed could be put back (a row changed since)", count);
}

/* The reader's bytes read as shipped: the event's work, if it came first. */
static void CodeReady(VpmComponent* self, HfEvent event)
{
    s.code_ready = 1;
    if (s.entities_ready) EntitiesReady(self, HF_EVENT_ENTITIES_READY);
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    if (!vpm_when_code_ready(self, kPins, 1, CodeReady)) return 1;
    return vpm_on_load(self, HF_EVENT_ENTITIES_READY, EntitiesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_better_stratagem_bounce = {"better_stratagem_bounce", "Better Stratagem Bounce", "15.4.1", VPM_OVERLAPS_VANILLA_PLUS, Start, Stop};
