/* Reinforcement Beacons Fixed v4.6.1 (Lua: components/ReinforcementBeaconsFixed/src/spawn_data.lua and the update wrapper
 * in archive_loader.lua), build 25480438.
 *
 * A queued reinforcement pod lands scattered around its beacon. This centers it: while the local player's own pod is
 * pending (player manager [game + 0x3326468] + 0x2E0 == 2, countdown at +0x12C between 0.1 and 5.1 s), the 8 bytes of
 * its pending X, Y at +0x10C (stored by AC83F0, read by AC8800 to create the pod) are set to the beacon's position. Solo,
 * the automatic reinforcement's anchor (stratagem row type 0x7C) is itself scattered around the death, so the target is
 * the source position frozen when that anchor appeared. Z, the countdown, use bits and ownership stay as the game set
 * them; nothing else is written. spawn_reader.c reads the game's data, spawn_plan.c decides; this file waits for the
 * work, writes, and puts the write back when the component stops.
 *
 * The idle gate (the Lua's spawn_state): between deaths a frame loads the player manager global and reads its spawn
 * state; only 1 (dead, queued) or 2 (pod pending) starts the full snapshot, which then runs every frame until the state
 * leaves 1 and 2 (at both check points while it is the local player's own reinforcement). The death's first snapshot is
 * compared with a baseline: the state the gate saw last (so the initial deployment, 0 -> 2, stays excluded), no
 * beacons, and the automatic rows of the last solo landing on the same player manager. Each correction re-reads the
 * snapshot immediately before the write and writes only if the same pending spawn and the same beacon association still
 * hold; a read-back that differs puts the original X, Y back and stops.
 *
 * On HellForge (what differs from the Lua, and why):
 * - Two checks per frame while a reinforcement is in progress, as the Lua: the tick at the start of game.dll's update
 *   and the post-update tick right after that update returns, under the Lua's condition for its second check (the last
 *   full snapshot is the local player's own, in a gameplay mode, queued or pending). The post tick is started by the
 *   full check that finds that and stopped by the one that ends it, so frames between deaths run the gate alone, as in
 *   the 1:1 port. Why the post point is the same or strictly better than the Lua's: the Lua's two checks ran at the
 *   start of its update chain and after the chain below it, both before game.dll's update (the engine calls it right
 *   after the Lua update: KB squad-join-pipeline-research section 1, static), so a spawn the game commits during its
 *   update in frame N (AC83F0 storing the pending X, Y) was corrected at frame N+1's first check at the earliest, after
 *   the engine's per-world loop, the frame's render and the next Lua update had run with the scattered X, Y in place
 *   (the 1:1 port: at frame N+1's tick). Here the post tick corrects it at the end of that same update, before anything
 *   else runs, and the tick (at the start of game.dll's update, after the whole Lua chain: the Lua's second point or
 *   later) still sees, before the next update, whatever changed between the updates. Without the core's hook of
 *   game.dll's update (its code not decoded yet, or another mod's hook there first) the post tick runs right after the
 *   tick inside HellForge's callback: its check then sees what the tick's saw (a commit inside the update is corrected
 *   at the next frame, as in the 1:1 port), at the Lua's two-check cost; the component cannot tell the two cases apart
 *   through vpm.h. A refused post tick is logged once and leaves one check per frame. The pod waits about 5 s and the
 *   window is 0.1 .. 5.1 s, so either way the correction is the same.
 * - The globals (game.dll and the exe's unit registry) are plain loads; only heap data goes through vpm_read.
 * - The pending X, Y's page is checked (VirtualQuery) at the first correction on each player manager, then the store is
 *   a plain one; the Lua checked at every correction. A player manager lives for the mission.
 * - A refusal (an unsupported layout, an invalid pointer, a failed write) stops the component (vpm_fail), whose stop()
 *   puts back a pending correction that still holds its bytes, as the Lua's guard did. Dropped: the guard's pause after
 *   an error in an update below it (a HellForge tick is not chained to the game's update), its 8-errors-per-burst count
 *   (the core's crash guard stops a component at its first fault) and its shutdown handling (nothing is written then).
 * - None of the game data read here is moved by HellForge: the active stratagem rows are instances (type 0x7C is the
 *   vanilla Reinforcement Beacon; HellForge's added stratagems take types 150 and up).
 * - The log: one line per status change (the Lua printed it and rewrote its own log file); a correction's line carries
 *   the count and the correction (kind, beacon, from, to, association) the Lua's log file held.
 *
 * COST per frame, the tick's + the post check's (reads are vpm_read, guarded plain loads; the globals are plain loads;
 * no Windows call except where named; the Lua's numbers from its tests' frame_budget pins of a whole update, both
 * checks):
 * - Idle, loading (null player manager global): 1 plain load, 0 reads; no post check (the Lua: 1 read).
 * - Idle, on the ship or alive in a mission: 1 plain load, 1 read (the spawn state); no post check (the Lua: 2 reads).
 * - Dead (queued or pending), every frame: one snapshot at each point: 3 to 5 plain loads and 4 reads (mode block,
 *   player block, local entity, reinforcement manager); with n beacons 2 + n more; queued or pending with beacons also
 *   the position manager's block and per beacon its probes and position; solo the anchor manager's block and its rows
 *   (1 read each). Co-op with one beacon: 10 + 10 reads (the Lua: 28); the death's frame 11 + 10 (the Lua: 30).
 * - The correction frame (once per death): the snapshot, its re-read and a read-back at the point that corrects, the
 *   snapshot at the other: 21 + 10 reads co-op with one beacon, or 10 + 21 for a commit inside the update (the Lua: 42
 *   and 1), one 8-byte store, and one VirtualQuery on the player manager's first correction (the Lua: one per
 *   correction).
 * - Solo, the frame that captures the anchor: the source position too, 1 read for the fallback (the Lua: 3), 9 plus the
 *   lookup's probes for a unit (the Lua: 11 plus probes); the post check does not read it again (the solo death: 8 + 6,
 *   the Lua: 25).
 * - The landing's frame: the last full snapshot (4 co-op, 5 solo), which stops the post check.
 * The 1:1 port made the tick's share alone (a queued frame 10 reads); the post check's share is the Lua's second check,
 * back under its own condition, guarded plain loads (unmeasured in game) where the Lua's ReadProcessMemory cost 1-2 us.
 * The post tick costs the core a guarded call and two time-stamp reads per frame while it runs; nothing between deaths.
 * No allocation; one log line per status change only. Once: the tick starts at HF_EVENT_GAME_LOADED. */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"
#include "spawn_data.h"

static const char kWaitingForGameData[] = "waiting_for_game_data";
static const char kBeaconCentered[] = "beacon_spawn_centered";
static const char kSoloCentered[] = "solo_spawn_centered";
static const char kNothingToRestore[] = "nothing_to_restore";

static struct
{
    RbfState state;
    uintptr_t manager;        /* the gate's player manager, and the address of its spawn state */
    uintptr_t spawn_address;
    uintptr_t checked;        /* the player manager whose pending X, Y passed the page check */
    const char* status;       /* the last status reported, and its stage when it was "waiting for game data" */
    const char* stage;
    int watching;             /* the post-update tick runs (the Lua's after-update check) */
    int post_refused;         /* the core refused it: one check per frame for the session */
} s;

static void After(VpmComponent* self, float dt);

/* Three snapshots: the previous one (or the gate's baseline), the current one and the re-read before a write. */
static RbfSnapshot g_snapshots[3];

/* A snapshot buffer that is neither a nor b. */
static RbfSnapshot* Spare(const RbfSnapshot* a, const RbfSnapshot* b)
{
    for (int i = 0; i < 3; i++)
        if (&g_snapshots[i] != a && &g_snapshots[i] != b) return &g_snapshots[i];
    return &g_snapshots[0];
}

static int Same(const char* a, const char* b) { return a == b || (a != NULL && b != NULL && strcmp(a, b) == 0); }

/* The status, logged and shown when it changes (the Lua's report). */
static void Report(VpmComponent* self, const char* status, const char* stage)
{
    if (Same(status, s.status) && Same(stage, s.stage)) return;
    char text[96];
    s.status = status;
    s.stage = stage;
    if (stage != NULL) snprintf(text, sizeof text, "%s:%s", status, stage);
    else snprintf(text, sizeof text, "%s", status);
    vpm_set_status(self, text);
    vpm_log(self, "%s", text);
}

/* Unavailable game data forgets every association (a fresh start). */
static void Waiting(VpmComponent* self, const RbfReader* reader)
{
    rbf_forget(&s.state);
    Report(self, kWaitingForGameData, reader->stage);
}

/* The idle gate's read: the local spawn state, through the player manager global (a plain load). The manager's spawn
 * state address is made once per manager, which the game replaces per mission; a new manager forgets the last state. */
static int SpawnState(RbfReader* reader, int64_t* spawn)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(RBF_PLAYER_MANAGER);
    uint32_t value = 0;
    if (manager == 0)
    {
        reader->stage = rbf_stage_player_manager;
        return RBF_WAIT;
    }
    if (manager != s.manager)
    {
        if (!vpm_plausible(manager))
        {
            vpm_fail(reader->self, "Invalid spawn data pointer: player_manager");
            return RBF_FAILED;
        }
        s.manager = manager;
        s.spawn_address = manager + RBF_AT_SPAWN;
        s.state.spawn = RBF_NIL;
        s.state.landed_known = 0;
        s.state.landed_count = 0;
    }
    if (!vpm_read_u32(s.spawn_address, &value))
    {
        reader->stage = rbf_stage_spawn_state;
        return RBF_WAIT;
    }
    *spawn = value;
    return RBF_OK;
}

/* The single store and its read-back: 1 written, or 0 after vpm_fail (the original X, Y put back while the spawn is
 * still pending). */
static int Write(VpmComponent* self, const RbfSnapshot* fresh, const RbfPlan* plan)
{
    uintptr_t at = fresh->address;
    uint8_t now[8];
    uint32_t spawn = 0;
    if (s.checked != fresh->identity)
    {
        if (!vpm_writable(at, sizeof now)) return !vpm_fail(self, "Target is not existing private writable data");
        s.checked = fresh->identity;
    }
    memcpy((void*)at, plan->bytes, sizeof plan->bytes);
    if (vpm_read(at, now, sizeof now) && memcmp(now, plan->bytes, sizeof now) == 0) return 1;
    if (vpm_read_u32(fresh->identity + RBF_AT_SPAWN, &spawn) && spawn == RBF_PENDING)
        memcpy((void*)at, fresh->original, sizeof fresh->original);
    vpm_fail(self, "Spawn data write failed; correction stopped");
    return 0;
}

/* Keeps what the write replaced, for the restore, and logs the correction. */
static void Record(VpmComponent* self, const RbfSnapshot* current, const RbfSnapshot* fresh, const RbfPlan* plan)
{
    RbfState* t = &s.state;
    t->correction = *plan;
    t->correction.address = fresh->address;
    memcpy(t->correction.original, fresh->original, sizeof t->correction.original);
    t->pending = 1;
    t->corrections++;
    t->has_last = 1;
    t->last = t->correction;
    t->last_from[0] = current->position[0];
    t->last_from[1] = current->position[1];
    s.status = plan->solo ? kSoloCentered : kBeaconCentered;
    s.stage = NULL;
    vpm_set_status(self, s.status);
    vpm_log(self, "%s (corrections=%u; %s beacon=%u from=%.6f,%.6f to=%.6f,%.6f association=%s)", s.status, t->corrections,
        plan->solo ? "solo" : "beacon", plan->beacon, (double)t->last_from[0], (double)t->last_from[1],
        (double)plan->target[0], (double)plan->target[1], plan->remote ? "unmarked_remote" : "used");
}

/* Re-reads every identity and association immediately before the single write. */
static void Correct(VpmComponent* self, RbfReader* reader, const RbfSnapshot* current, const RbfPlan* plan)
{
    RbfSnapshot* fresh = Spare(current, NULL);
    int rc = rbf_snapshot(reader, fresh);
    if (rc != RBF_OK)
    {
        if (rc == RBF_WAIT) Waiting(self, reader);
        return;
    }
    if (rbf_spawn_changed(current, fresh)) { Report(self, "spawn_changed_before_write", NULL); return; }
    if (!rbf_beacon_kept(fresh, plan)) { Report(self, "beacon_changed_before_write", NULL); return; }
    if (Write(self, fresh, plan)) Record(self, current, fresh, plan);
}

/* A full check: the snapshot, the plan against the previous one (or the gate's baseline), and the correction. */
static void Follow(VpmComponent* self, RbfReader* reader, int tracking, int64_t last)
{
    RbfSnapshot* current = Spare(s.state.previous, NULL);
    RbfPlan plan;
    const char* reason = NULL;
    int rc = rbf_snapshot(reader, current);
    if (rc != RBF_OK)
    {
        if (rc == RBF_WAIT) Waiting(self, reader);
        return;
    }
    if (!tracking)
    {
        RbfSnapshot* baseline = Spare(current, NULL);
        s.state.previous = rbf_baseline(baseline, current, last, &s.state) ? baseline : NULL;
    }
    memset(&plan, 0, sizeof plan);
    rc = rbf_plan(reader, &s.state, current, &plan, &reason);
    if (rc == RBF_FAILED) return;
    rbf_track(&s.state, current);
    if (rc == RBF_WAIT) Report(self, kWaitingForGameData, reader->stage);
    else if (reason != NULL) Report(self, reason, NULL);
    else Correct(self, reader, current, &plan);
}

/* The Lua's condition for its check after the update: the last full snapshot is the local player's own, in a gameplay
 * mode, queued or pending. */
static int InProgress(void)
{
    const RbfSnapshot* last = s.state.previous;
    return last != NULL && last->owned && last->mode >= 1 && last->mode <= 7 && (last->state == 1 || last->state == 2);
}

/* After a full check: the post-update tick started or stopped when InProgress changes. A gate-only frame never needs
 * this: the gate runs only when the last full check left nothing in progress, which stopped the post tick then. */
static void Watch(VpmComponent* self)
{
    int watch = InProgress();
    if (watch == s.watching || s.post_refused || !vpm_running(self)) return;
    if (!watch)
    {
        vpm_post_tick_stop(self);
        s.watching = 0;
        return;
    }
    if (vpm_post_tick_start(self, After))
    {
        s.watching = 1;
        return;
    }
    s.post_refused = 1;
    vpm_log(self, "no check after the game's update (its tick was refused): one check per frame");
}

/* Every frame (patch.apply): the idle gate first, unless a reinforcement is being followed. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    RbfReader reader = {self, NULL};
    const RbfSnapshot* previous = s.state.previous;
    int tracking = previous != NULL && (previous->state == 1 || previous->state == 2);
    int64_t last = RBF_NIL, spawn = RBF_NIL;
    if (!tracking)
    {
        int rc = SpawnState(&reader, &spawn);
        if (rc == RBF_WAIT) Waiting(self, &reader);
        if (rc != RBF_OK) return;
        last = s.state.spawn;
        s.state.spawn = spawn;
        if (spawn != 1 && spawn != 2)
        {
            /* Alive (3) or before the first deployment (0) ends any association. */
            s.state.previous = NULL;
            if (spawn == 3 || spawn == 0) s.state.anchored = s.state.pending = 0;
            Report(self, rbf_waiting_for_reinforcement, NULL);
            return;
        }
    }
    Follow(self, &reader, tracking, last);
    Watch(self);
}

/* After game.dll's whole update in the same frame, while a reinforcement is in progress (the Lua's after): the full check
 * the tick makes then. lint: per-frame */
static void After(VpmComponent* self, float dt)
{
    if (InProgress()) Tick(self, dt);
    else Watch(self);
}

/* Puts back the original X, Y of this component's correction, only while the same player manager's spawn is still
 * pending and its X, Y still hold exactly the bytes written; then forgets every association (patch.restore). */
static const char* Restore(void)
{
    int pending = s.state.pending;
    RbfPlan c = s.state.correction;
    uint8_t now[8];
    uint32_t spawn = 0;
    rbf_forget(&s.state);
    if (!pending) return kNothingToRestore;
    uintptr_t manager = (uintptr_t)vpm_game_u64(RBF_PLAYER_MANAGER);
    if (!vpm_plausible(manager) || manager + RBF_AT_XY != c.address || !vpm_read_u32(manager + RBF_AT_SPAWN, &spawn) ||
        spawn != RBF_PENDING || !vpm_read(c.address, now, sizeof now) || memcmp(now, c.bytes, sizeof now) != 0)
        return "correction_left_unchanged";
    if (!vpm_writable(c.address, sizeof now)) return "correction_restore_failed";
    memcpy((void*)c.address, c.original, sizeof c.original);
    if (!vpm_read(c.address, now, sizeof now) || memcmp(now, c.original, sizeof now) != 0) return "correction_restore_failed";
    return "correction_restored";
}

static void Stop(VpmComponent* self)
{
    const char* outcome = Restore();
    if (outcome != kNothingToRestore) vpm_log(self, "%s; %s", vpm_status(self), outcome);
}

static void GameLoaded(VpmComponent* self, HfEvent event)
{
    if (!vpm_ticking(self) && !vpm_tick_start(self, Tick)) vpm_fail(self, "the game thread could not be reached");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.state.spawn = RBF_NIL;
    Report(self, rbf_waiting_for_reinforcement, NULL);
    return vpm_on_load(self, HF_EVENT_GAME_LOADED, GameLoaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_reinforcement_beacons_fixed = {"reinforcement_beacons_fixed", "Reinforcement Beacons Fixed", "4.6.1", VPM_OVERLAPS_VANILLA_PLUS, Start, Stop};
