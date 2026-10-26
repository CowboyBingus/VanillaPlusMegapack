/* Shallow Water Diving v3.10.1 (Lua: components/ShallowWaterDiving/src/dive_data.lua and archive_loader.lua), for build
 * 25480438.
 *
 * In water up to the shin a dive is accepted, its impulse applied and the stance switched to prone, which lowers the
 * drowning reference from root + 1.3 to root + 0.4; swimming consumes that submersion and cancels the dive about 10-12 ms
 * in. This keeps the standing reference during a newly accepted airborne dive of the local avatar: the Drownable runtime
 * record's offset (+8) holds -1.3 instead of -0.4 until landing (dive_lease.c), so the leap goes on and water is judged
 * again where it lands. The deepest water a dive may start in is Mod Options Menu's "Max Dive Water Depth" slider
 * (shallow_water_diving.max_water_depth: 0.20 .. 1.30, step 0.05, default 0.20).
 *
 * How it waits (the Lua loader's cadence, kept): after a full check that found the local avatar idle ('dive_ended', no
 * lease or retry), every frame runs only the idle gate (one read of its dive controller: dive_snapshot.c) and every
 * 120th frame a full check to follow avatar and mission changes; a failed gate runs the full check at once. Waits
 * before a local avatar exists (no mission, no local player, no local avatar) check every 30th frame. Anything else (a
 * dive, a lease, a retry, a wait on a dive frame) checks every frame. While a local avatar exists or a lease or retry
 * is in progress, a frame checks twice, as the Lua loader checked at both boundaries of its update: at the tick, and
 * after the game's update (the gate while the avatar is idle, a full check otherwise). A check that finds something not
 * as reviewed is an error, as the Lua's asserts were: the first of a burst is logged, 8 in a burst stop the component
 * (which restores), and 3600 frames without one clear the count; a frame counts as clean at its end, after both checks,
 * as the Lua's guard counted it.
 *
 * On HellForge, the two check points. The Lua checked at the start of its update chain and again after the chain below
 * it returned: both before game.dll's update, which the engine calls right after the Lua update (KB
 * squad-join-pipeline-research section 1, static). A dive that game.dll's update starts in frame N was therefore first
 * seen at frame N+1's first check, after the engine's per-world loop, the render and the next Lua update. Here the tick
 * runs at the start of game.dll's update (after the whole Lua chain: the Lua's second point, or later) and the
 * post-update tick right after that update returns. So:
 * - a dive the game's update starts gets its lease at the end of that same update, before anything else runs (no point
 *   between updates is earlier): the earliest answer a check between updates can give to the open question of
 *   TECHNICAL.md and the research (whether a check sees the dive's first frame before swimming consumes it, about 10-12
 *   ms in); not yet confirmed in game;
 * - whatever runs between the updates (the engine, a Lua update) is still seen by the next tick, before game.dll's next
 *   update, as the Lua's second check saw it;
 * - a retry ("snapshot_changed") runs at the post point of the same frame, the Lua's "other update boundary in this
 *   frame".
 * Both points are thus at the Lua's or strictly earlier, under the Lua's own condition for its second check: the post
 * tick runs while a local avatar exists or a lease or retry is in progress, started and stopped by the check that
 * changes that, so frames without a local avatar run the tick alone, as in the 1:1 port. Without the core's hook of
 * game.dll's update (its code not decoded yet, or another mod's hook there first) the post tick runs right after the
 * tick inside HellForge's callback: its check then sees what the tick's saw, at the Lua's two-check cost (the component
 * cannot tell the two cases apart through vpm.h). A refused post tick is logged once and leaves one check per frame for
 * the session (the 1:1 port's), however a later start would answer.
 *
 * game.dll's decoding: HF_EVENT_GAME_LOADED fires once one pin of game.dll reads as decoded, and the rest of its code
 * is decoded in parts after that. This component checks no code bytes (no code_matches, no hook). Its reads of
 * game.dll's image are its globals (data the game writes; null ones wait) and, on the first dive of a session in a
 * mission, the read-only dive timeout and stance offsets: minutes after the event (the ship, then a mission's load),
 * far past HellForge's 20 s for its own pins and the core's 60 s wait, and a mismatch there is one error of a burst,
 * not a stop. So nothing here waits on vpm_when_code_ready.
 *
 * The tick starts at HF_EVENT_GAME_LOADED. The slider is the core's option (registered at start, its saved value
 * applied, changes through on_change) instead of Mod Options Menu's retried registration. The session's counters go to
 * the log at each mission's end and when the component stops (the Lua wrote them to its log file at startup, stop and
 * shutdown). Dropped: the Lua's pause after a failing update below it and its shutdown restore (no such events), the
 * JIT notes.
 *
 * Diagnostics. The Lua's diagnostics log (CowboyBingusDiagnostics: each check's status and the counters, rewritten at
 * most every 2 s) is back as the pack's Detailed lines (vpm_log_detail; nothing in Normal mode), written after a full
 * check and only on a change: the local avatar found (id, dive controller, entity record), a lease taken (the water
 * record, the offset's bits before and after, the Drownable manager and table, the startup debt cleared, the page
 * checks) or given back (why, the restore's own answer, the counters), the check's new reason (on a dive frame with the
 * water depth, the limit, the stance and the timers it was judged by), the post-update check switched on or off, the
 * errors of a burst after its first, and a new depth limit. The mark's describe line: the last reason, the local avatar
 * and the lease followed, the depth limit, the post check, the burst's errors and the counters.
 *
 * Cost per frame, the tick's + the post tick's (reads are vpm_read, guarded plain loads; game.dll's globals and
 * constants are plain loads, which the Lua read through ReadProcessMemory too; its numbers in brackets, from its tests'
 * frame_budget pins of a whole update, both boundaries):
 * - outside a mission: 1 read every 30th frame (the mission record), none between; no post tick [2 every 30th];
 * - no local avatar: every 30th frame the reads up to the wait, 3 while dead (at most 10), none between; no post tick
 *   [5 while dead];
 * - idle in a mission: 1 + 1 reads, the gate before and after the update [2]: the Lua's own count (the 1:1 port read
 *   once), kept so that a dive started inside the update gets its lease in the same frame; 10 + 1 on every 120th frame
 *   (the full check, then the gate) [15];
 * - a dive start: 75 + 24 reads (the lease, then the held check; 76 + 24 when the gate ran first), 1 page check
 *   (VirtualQuery) for the first dive in a record table, 2 stores [129 reads, 1 page check, 2 writes]; a dive the
 *   game's update starts: 1 + 76 on that frame (the tick's gate, then the gate and the lease after the update);
 * - a dive held: 24 + 24 reads [62];
 * - a landing: 37 + 1 reads and 1 store, no page check (the dive's check is reused) [50 reads, 1 write];
 * - a dive not assisted (deep water): 24 + 24 reads per frame [62];
 * - a stop with a lease held: 27 reads, 1 page check, 1 store.
 * The 1:1 port made the tick's share alone (a dive held 24): the post check's reads are the Lua's second boundary, back
 * where it watched, guarded plain loads (unmeasured in game) where the Lua's ReadProcessMemory cost 1-2 us. The post
 * tick costs the core a guarded call and two time-stamp reads per frame while it runs; nothing while it is stopped. No
 * Windows call on a frame that does not act (the page check runs only right before a dive's first write in a table), no
 * allocation (all state is static), no logging (an error's first line in a burst only). Once: the option's registration
 * at start and one log line at HF_EVENT_GAME_LOADED, no reads; one log line at each mission's end.
 * The detailed lines add nothing to an idle frame (the gate's frames never reach them) and no game read anywhere: a
 * full check compares three values it already holds (the reason, the avatar, the lease), and only a check where one
 * changed makes the core's one global read of the Diagnostics mode per line (plus, in Detailed mode, the line itself,
 * at most 20 per 600 frames); a restore stores its answer. Unmeasured in game. */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"
#include "dive_data.h"

#define GATE_FRAMES 120   /* a full check every 120th idle frame (about 2 s at 60 FPS) */
#define POLL_FRAMES 30    /* without a local avatar, a check every 30th frame */
#define ERROR_LIMIT 8     /* errors in a burst that stop the component */
#define CLEAN_FRAMES 3600 /* frames without an error that end a burst (about a minute) */

static struct
{
    const char* depth_option; /* "registered" or "not registered" */
    int gated;                /* the last full check found the local avatar idle */
    int gate_left, poll_left;
    int errors, clean_run;
    char burst_error[160];
    const char* status;       /* the last check's reason */
    int active;
    int watching;             /* the post-update tick runs (the Lua loader's watch_after) */
    int post_refused;         /* the core refused it: one check per frame for the session */
    int frame_failed;         /* the tick's check was an error: counted at the frame's end, with the post check */
    uintptr_t seen_controller; /* the detailed lines' last local avatar (0: none) and lease */
    uint32_t seen_id;
    int seen_lease;
} s;

static VpmOptionDef g_depth; /* the slider (static: the core keeps it); its texts set at start */

static void SwdAfter(VpmComponent* self, float dt);

/* 1 when the status changed. */
static int SwdShow(VpmComponent* self, const char* status, int active)
{
    s.active = active;
    if (status == s.status) return 0;
    s.status = status;
    vpm_set_status(self, status);
    return 1;
}

/* ---- detailed lines (vpm.h "diagnostics"): what the Lua's diagnostics log file held (each check's status and the
 * counters) and what a tester's report needs beside it. Only after a full check, only on a change: the local avatar
 * found, a lease taken or given back (with the restore's answer), the check's new reason (on a dive frame with the
 * water depth and timers it was judged by). */

static void SwdDetailAvatar(VpmComponent* self)
{
    if (!swd.gate)
    {
        s.seen_controller = 0;
        return;
    }
    if (swd.gate_controller == s.seen_controller && swd.gate_id == s.seen_id) return;
    s.seen_controller = swd.gate_controller;
    s.seen_id = swd.gate_id;
    vpm_log_detail(self, "local avatar %u: dive controller 0x%llX, entity record 0x%llX", swd.gate_id,
        (unsigned long long)swd.gate_controller, (unsigned long long)swd.key);
}

static void SwdDetailLease(VpmComponent* self, const char* reason)
{
    if (swd.pending.valid == s.seen_lease) return;
    s.seen_lease = swd.pending.valid;
    const SwdSnapshot* d = &swd_snap;
    if (s.seen_lease)
        vpm_log_detail(self, "lease taken: water record 0x%llX, +8 %08X -> %08X; Drownable manager 0x%llX, table 0x%llX; "
            "startup debt %.3f s%s; page checks %u", (unsigned long long)d->water_address, swd.pending.before,
            swd.pending.after, (unsigned long long)d->manager, (unsigned long long)d->table, (double)d->drown_elapsed,
            d->drown_elapsed > 0 ? " cleared" : "", swd.queries);
    else
        vpm_log_detail(self, "lease given back: %s (restore: %s); observed=%u protected=%u restored=%u", reason,
            swd.restore_why != NULL ? swd.restore_why : "none", swd.observed, swd.protected, swd.restored);
}

static void SwdDetailReason(VpmComponent* self, const char* reason)
{
    if (!(swd.gate && swd.was_dive))
    {
        vpm_log_detail(self, "check: %s", reason);
        return;
    }
    const SwdSnapshot* d = &swd_snap; /* a dive frame: every field is this check's */
    vpm_log_detail(self, "check: %s (water %.2f above the root%s, max %.2f; stance %u, dive time %.3f, landing %.3f, "
        "submersion %.3f)", reason, (double)d->surface - (double)d->root_z, d->water_gate ? "" : ", surface unavailable",
        swd.max_water_depth, d->stance, (double)d->elapsed, (double)d->landing, (double)d->drown_elapsed);
}

/* The check after the game's update, started or stopped when the Lua loader's watch_after changes. */
static void SwdWatch(VpmComponent* self, int watch)
{
    if (watch == s.watching || s.post_refused) return;
    if (!watch)
    {
        vpm_post_tick_stop(self);
        s.watching = 0;
        vpm_log_detail(self, "check after the game's update: off");
        return;
    }
    if (vpm_post_tick_start(self, SwdAfter))
    {
        s.watching = 1;
        vpm_log_detail(self, "check after the game's update: on");
        return;
    }
    s.post_refused = 1;
    vpm_log(self, "no check after the game's update (its tick was refused): one check per frame");
}

/* What the last check found decides the next checks; the post check watches while a dive can start (a local avatar)
 * or a lease or retry is in progress. */
static void SwdSettle(VpmComponent* self, int checked, const char* reason)
{
    s.gated = checked && swd.gate && !(swd.pending.valid || swd.retry_start || swd.was_dive);
    s.gate_left = s.gated ? GATE_FRAMES - 1 : 0;
    s.poll_left = checked && !swd.pending.valid && swd_no_avatar(reason) ? POLL_FRAMES - 1 : 0;
    SwdWatch(self, swd.pending.valid || swd.retry_start || swd.gate);
}

/* A frame without an error, at its end: 3600 in a row end a burst. */
static void SwdCountClean(int failed)
{
    if (!failed && s.errors > 0 && ++s.clean_run == CLEAN_FRAMES) s.errors = 0;
}

/* An error: one log line per burst; ERROR_LIMIT in a burst stop the component. */
static void SwdError(VpmComponent* self, const char* text)
{
    s.clean_run = 0;
    s.errors++;
    if (s.errors == 1)
    {
        snprintf(s.burst_error, sizeof s.burst_error, "%s", text);
        vpm_log(self, "error: %s", text);
    }
    else vpm_log_detail(self, "error %d of this burst: %s", s.errors, text);
    if (s.errors >= ERROR_LIMIT) vpm_fail(self, "stopped after %d errors: %s", ERROR_LIMIT, s.burst_error);
}

/* One full check. A refusal stops the component at once (its stop restores). 1 when it was an error. */
static int SwdCheck(VpmComponent* self)
{
    const char* reason = NULL;
    int active = 0;
    int result = swd_apply(&reason, &active);
    if (result < 0)
    {
        SwdSettle(self, 0, NULL);
        SwdError(self, swd_error());
        return 1;
    }
    if (result == 0)
    {
        vpm_fail(self, "%s", reason);
        return 0;
    }
    SwdSettle(self, 1, reason);
    SwdDetailAvatar(self);
    SwdDetailLease(self, reason);
    if (SwdShow(self, reason, active)) SwdDetailReason(self, reason);
    return 0;
}

/* The loader's step: the poll and the gate first. 1 when the frame's check was an error. */
static int SwdStep(VpmComponent* self)
{
    if (s.poll_left > 0)
    {
        s.poll_left--;
        return 0;
    }
    if (s.gate_left > 0)
    {
        s.gate_left--;
        if (swd_idle(swd.gate_controller, swd.gate_id)) return 0;
    }
    return SwdCheck(self);
}

/* Every game update, before the game's (the Lua loader's step). While the post check runs, the frame is counted after
 * it. lint: per-frame */
static void SwdTick(VpmComponent* self, float dt)
{
    int failed = SwdStep(self);
    if (s.watching) s.frame_failed = failed;
    else SwdCountClean(failed);
}

/* After game.dll's whole update in the same frame, while it watches (the Lua loader's after): the gate while the local
 * avatar is idle, a full check otherwise. lint: per-frame */
static void SwdAfter(VpmComponent* self, float dt)
{
    int failed = 0;
    if (!s.gated || !swd_idle(swd.gate_controller, swd.gate_id)) failed = SwdCheck(self);
    SwdCountClean(failed || s.frame_failed);
}

static void SwdCounters(VpmComponent* self, const char* when)
{
    vpm_log(self, "%s: %s; observed=%u protected=%u restored=%u startup_clears=%u short_ends=%u table_moves=%u "
        "protection_queries=%u", when, s.status != NULL ? s.status : "waiting_for_mission", swd.observed, swd.protected,
        swd.restored, swd.startup_clears, swd.short_ends, swd.table_moves, swd.queries);
}

static void SwdMissionEnd(VpmComponent* self, const HfEventInfo* event) { SwdCounters(self, "mission end"); }

static void SwdGameLoaded(VpmComponent* self, HfEvent event)
{
    if (vpm_game() == 0) { vpm_fail(self, "Required modules unavailable"); return; }
    if (!vpm_tick_start(self, SwdTick)) { vpm_fail(self, "Game update unavailable"); return; }
    SwdShow(self, "waiting_for_mission", 0);
    vpm_log(self, "waiting_for_mission (max dive water depth %.2f; depth option %s)", swd.max_water_depth, s.depth_option);
}

static void SwdDepthChanged(VpmComponent* self, VpmOption* option, double value)
{
    if (swd_set_max_water_depth(value)) vpm_log_detail(self, "max dive water depth: %.2f", swd.max_water_depth);
}

/* The slider for the deepest water a dive may start in; the applied value reaches the dive check through on_change. */
static void SwdRegisterDepth(VpmComponent* self)
{
    g_depth = (VpmOptionDef){"max_water_depth", VPM_SLIDER, vpm_text(self, "option.depth.label", "Max Dive Water Depth"),
        vpm_text(self, "option.depth.description",
            "Deepest water, measured up from your feet, that a dive can start in: from 0.20 (lower shin, the original "
            "limit) up to 1.30, where your Helldiver starts swimming. Deeper water always keeps the game's normal behavior."),
        SWD_MIN_WATER_DEPTH, SWD_MIN_WATER_DEPTH, SWD_SWIM_DEPTH, 0.05, NULL, 0};
    VpmOption* option = vpm_option(self, &g_depth);
    if (option == NULL)
    {
        s.depth_option = "not registered";
        return;
    }
    (void)swd_set_max_water_depth(vpm_option_value(option));
    vpm_option_on_change(option, SwdDepthChanged);
    s.depth_option = "registered";
}

/* The key state for a tester's mark: the last check's reason, the avatar and lease it follows, the counters. */
static void Describe(VpmComponent* self, char* out, size_t size)
{
    char avatar[64] = "none", lease[48] = "none";
    if (swd.gate) snprintf(avatar, sizeof avatar, "%u (controller 0x%llX)", swd.gate_id, (unsigned long long)swd.gate_controller);
    if (swd.pending.valid) snprintf(lease, sizeof lease, "held at 0x%llX", (unsigned long long)swd.pending.address);
    snprintf(out, size, "%s; local avatar %s; lease %s; max depth %.2f; check after update %s; errors in burst %d; "
        "observed=%u protected=%u restored=%u", s.status != NULL ? s.status : "waiting_for_mission", avatar, lease,
        swd.max_water_depth, s.watching ? "on" : s.post_refused ? "refused" : "off", s.errors, swd.observed, swd.protected,
        swd.restored);
}

/* Puts back the water record a lease changed (the page is checked again) and logs the session's counters. */
static void Stop(VpmComponent* self)
{
    const char* why = NULL;
    if (swd_restore(0, &why)) swd.pending.valid = 0;
    else vpm_log(self, "restore_failed (%s)", why);
    SwdCounters(self, "stopped");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    swd_reset();
    SwdRegisterDepth(self);
    if (!vpm_on_load(self, HF_EVENT_GAME_LOADED, SwdGameLoaded)) return 1;
    if (!vpm_listen(self, HF_ON_MISSION_END, SwdMissionEnd, 0)) vpm_log(self, "no counters at a mission's end");
    return 0;
}

const VpmComponentDef vpm_component_shallow_water_diving = {"shallow_water_diving", "Shallow Water Diving", "3.10.1", 0, Start, Stop,
    Describe};
