/* Enemy Collision Synchronized v2.13.0 (Lua: components/EnemyCollisionSynchronized/src: corpse_data.lua,
 * corpse_profiles.lua, archive_loader.lua, windows_api.lua), for build 25480438.
 *
 * Large enemies (21 profiles: Impaler, Bile Titans, Chargers, Spewers, Automaton walkers, Illuminate tripods and war
 * machine) die into ragdolls that RagdollSync keeps in step with the owner's, then into Corpses. On a client, auxiliary
 * colliders of such a corpse can stay behind, metres from the body (a recorded Impaler leg 27 m away), and a settled
 * remote ragdoll can be flung again by network corrections. Every 3/64 s of frame time this reads both managers
 * (ecs_reader.c, ecs_inspect.c), realigns a displaced static auxiliary collider to its skeleton node through the
 * engine's queued physics commands, disables the Impaler's three revived claws (ecs_pose.c, ecs_apply.c), and stops
 * renewed motion of a settled remote ragdoll through RagdollSync's own stop, then asks the owner to complete it
 * (ecs_motion.c, ecs_apply.c, ecs_natives.c). Nothing is written to game memory directly; the component holds nothing in
 * the game, so stop() has nothing to put back.
 *
 * On HellForge, compared with the Lua:
 * - The poll runs in the pack's game-thread tick, at the start of game.dll's frame update, where the Lua global update
 *   ran. The Lua polled after the updates below it in its loader's chain, which is still before game.dll's update: the
 *   same point of the frame. Both see the state the previous frame's update left, every 3/64 s of frame time.
 * - Statics in game.dll's and the exe's images (the mode and manager slots, the unit registry, actor lists, pools and
 *   physics world slots, the physics API table) are plain loads; the Lua read them with ReadProcessMemory.
 * - The routines are checked with HfApi.code_matches (the bytes as shipped) and once the game has set its physics API
 *   table (the pack starts before the game's Lua did, see ecs_natives.c).
 * - The session clock for motion histories and cooldowns is the sum of frame times (the Lua: GetTickCount64). The work
 *   budget's 1 ms deadline still reads the performance counter, as the Lua's api.clock, on frames that inspect a unit.
 * - A failed guard group is compared guard by guard at once: the Lua first read the same span a second time.
 * - The kept records are fixed tables (ecs_tables.c, ecs_listing.c), with room beyond what a mission can use.
 * - Dropped: the developer-only profiler (profiler.lua, CowboyBingusDiagnostics), the status file and its periodic
 *   rewrite (now three log lines at each mission's end and at a stop), the pause after an error in an update below the
 *   mod (there is no update chain; the core's crash guard stops the component on a fault), the shutdown report, and the
 *   Lua-only parts (pcall guards, string views, JIT notes, the hostile-VM and garbage tests).
 * - Raised polls (a unit despawning mid-read, a changed layout) are retried as in the Lua; 8 in a row stop the component
 *   ("stopped after: <the first one's reason>"). The game state events are not used: the mission check is the Lua's own
 *   mode block (its flag is not HellForge's state machine), and HF_ON_SPAWN does not report entering the managers.
 *
 * COST (calls per frame, as the test pins them; the Lua's test_performance.lua pins in brackets, where a view and a read
 * are each one ReadProcessMemory). A frame without a poll (2 of 3 at 60 FPS): one add and one compare, no call (Lua: the
 * same). A poll frame, every 3/64 s of frame time:
 * - outside a mission (no mode block): 0 reads [1 view];
 * - on the ship (mode flag 0): 1 read [1 view, 1 read];
 * - idle in a mission (empty managers): 3 reads, the mode block and both manager headers [1 view, 3 reads];
 * - eight living listed enemies: 5 reads, 6 on the polls that scan the ragdolls first (the rolling header verification)
 *   [3 views, 4 reads]; the poll that first sees them: 13 [10 views, 4 reads];
 * - a settled, aligned Bile Titan corpse inspected (69 enabled bodies, one read each, as the Lua's views): 97 reads and
 *   1 QueryPerformanceCounter [84 views, 22 reads, 1 clock, 1 GetTickCount64];
 * - a settled remote Bile Titan ragdoll: 117 reads, 1 QueryPerformanceCounter [101 views, 25 reads, 1 clock, 1 tick count];
 * - two such ragdolls behind eight living enemies: 234 reads, 2 QueryPerformanceCounter [211 views, 38 reads, 2 clocks];
 * - a corpse realignment: 106 reads, 1 QueryPerformanceCounter, 2 queued commands [97 views, 22 reads, 1 clock];
 * - a settled corpse waiting for its re-check: 4 reads [1 view, 4 reads].
 * The work per poll stays bounded as in the Lua: 128 listed entries, 4 inspections, 1 ms from the first inspection. No
 * VirtualQuery, write, allocation or log on a poll frame. Once per session: the bind's plain loads, 8 code comparisons
 * (HfApi.code_matches, 256 bytes at most each) and one QueryPerformanceFrequency; at each mission's end three log lines. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "ecs_internal.h"

#define REVISION "v2.13.0"

static const char kWaitingForApi[] = "waiting for the game's physics API";
static const char kWaitingForMission[] = "waiting_for_mission";
static const char kReady[] = "ready";
static const char kWaitingForStableData[] = "waiting_for_stable_data";

static struct
{
    int bound;
    double elapsed;            /* frame time since the last poll */
    double next_poll;          /* the fallback poll clock, without a usable frame time */
    uint32_t raised;           /* raised polls in a row */
    char first_raised[192];
    const char* status;
} s;

static void Status(VpmComponent* self, const char* status)
{
    if (s.status == status) return;
    s.status = status;
    vpm_set_status(self, status);
}

/* The Lua's status report, in three lines. */
static void Summary(VpmComponent* self, const char* when)
{
    vpm_log(self, "%s %s: polls=%u units=%u realignments=%u (largest gap %.3f m) claws_disabled=%u reposes_deferred=%u "
        "skipped=%u retries=%u", REVISION, when, Ecs.polls, Ecs.accepted_units, Ecs.realignments, Ecs.max_gap,
        Ecs.claws_disabled, Ecs.reposes_deferred, Ecs.skipped, Ecs.retries);
    vpm_log(self, "motion: armed=%u stops=%u verified=%u limb=%u landed_disabled=%u handoffs=%u completion_requests=%u "
        "completions_observed=%u pending=%u last=%s %s (%.3f m, %.1f degrees)", Ecs.fling_armed, Ecs.fling_stops,
        Ecs.fling_stops_verified, Ecs.fling_limb_stops, Ecs.landed_disabled_stops, Ecs.fling_handoffs, Ecs.completion_requests,
        Ecs.completion_corpse_observed, Ecs.completion_pending, Ecs.last_fling_type ? Ecs.last_fling_type : "none",
        Ecs.last_fling_reason ? Ecs.last_fling_reason : "", Ecs.last_fling_distance, Ecs.last_fling_degrees);
    vpm_log(self, "reader: preflight=%s getter_checks=%u getter_failures=%u scanned=%u inspected=%u yields=%u "
        "rechecks_deferred=%u records_full=%u last_skip=%s", Ecs.preflight ? Ecs.preflight : "none", Ecs.getter_checks,
        Ecs.getter_failures, Ecs.scan_entities, Ecs.deep_inspections, Ecs.budget_yields, Ecs.corpse_rechecks_deferred,
        Ecs.records_full, Ecs.last_skip[0] ? Ecs.last_skip : "none");
}

/* Whether a poll is due: the frame time the game passes (an add and a compare); without a usable one, the Lua's
 * fallback, the tick count. */
static int Due(float dt)
{
    if (dt >= 0 && dt < 3600)
    {
        s.elapsed += dt;
        if (s.elapsed < ECS_INTERVAL) return 0;
        s.elapsed = 0;
        return 1;
    }
    double now = (double)GetTickCount64() / 1000.0; /* lint-ok: C4 only without a usable frame time (the Lua's fallback); HellForge always passes one */
    if (now < s.next_poll) return 0;
    s.next_poll = now + ECS_INTERVAL;
    return 1;
}

/* A raised poll is retried on the next; 8 in a row stop the component. */
static void PollRaised(VpmComponent* self, const char* why)
{
    Ecs.retries++;
    snprintf(Ecs.last_skip, sizeof Ecs.last_skip, "%s", why);
    if (++s.raised == 1) snprintf(s.first_raised, sizeof s.first_raised, "%s", why);
    if (s.raised < ECS_POLL_ERRORS) { Status(self, kWaitingForStableData); return; }
    vpm_fail(self, "stopped after: %s", s.first_raised);
}

static int Bound(VpmComponent* self)
{
    if (EcsBind(self) <= 0) return 0;
    s.bound = 1;
    vpm_log(self, "%s: %s", REVISION, kWaitingForMission);
    Status(self, kWaitingForMission);
    return 1;
}

/* The idle gate is the poll clock: a frame without a poll adds its frame time and compares, nothing else. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    if (dt >= 0 && dt < 3600) Ecs.now += dt;
    if (!Due(dt)) return;
    if (!s.bound && !Bound(self)) return;
    Ecs.polls++;
    int ready = 0;
    if (!EcsApply(&ready)) { PollRaised(self, EcsWhy()); return; }
    s.raised = 0;
    Status(self, ready ? kReady : kWaitingForMission);
}

/* Once per mission: the counters, as the Lua's status report gave them. lint: per-frame */
static void MissionEnd(VpmComponent* self, const HfEventInfo* event)
{
    if (s.bound) Summary(self, "at the mission's end");
}

static void Stop(VpmComponent* self)
{
    if (s.bound) Summary(self, "stopped");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    memset(&Ecs, 0, sizeof Ecs);
    s.elapsed = 1e300; /* the first poll is due at once */
    EcsReset();
    EcsReadsBegin();
    EcsReaderBegin();
    Status(self, kWaitingForApi);
    if (!vpm_tick_start(self, Tick)) return vpm_fail(self, "Game update unavailable");
    if (!vpm_listen(self, HF_ON_MISSION_END, MissionEnd, 0)) vpm_log(self, "no counters at a mission's end");
    return 0;
}

const VpmComponentDef vpm_component_enemy_collision_synchronized = {"enemy_collision_synchronized", "Enemy Collision Synchronized", "2.13.0", 0, Start, Stop};
