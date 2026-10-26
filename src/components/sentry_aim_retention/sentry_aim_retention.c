/* Sentry Aim Retention v1.1.1 (Lua: components/SentryAimRetention/src: aim_data.lua, archive_loader.lua and the sentry
 * part of windows_api.lua), for build 25480438.
 *
 * Sentries this machine controls keep their aim when their target is lost (no snap back to a scan before the last burst
 * lands), Gatling and machine gun sentries pause their shots during broad sweeps, at stale aim after a target loss and
 * at target points behind static terrain (destructible cover exempt), and resume at once for a close replacement target;
 * after a loss on the firing node their pending native target search is shortened once. How each part works:
 * sentry_layout.c (finding and reading the sentries), sentry_hold.c (the aim hold), sentry_fire.c (the shot gate and
 * the search request), sentry_natives.c (the game's setters, the muzzle pose and the terrain ray query).
 *
 * On HellForge: the same check as the Lua, from the pack's game-thread ticks, with the same addresses, guards, native
 * calls and decisions. Differences, each for a reason:
 * - The checks per frame are the Lua's (archive_loader.lua step and after): the first at the start of game.dll's
 *   update, where the Lua global `update` ran, and while a sentry is engaged after it (tracks a target, holds aim,
 *   pauses fire or waits on a search request: the Lua's state.engaged) a second one. The Lua made that second check
 *   after its update chain, still before game.dll's update, which runs the targeting update and the fire handlers; here
 *   it runs after game.dll's whole update in the same frame (the core's post-update tick). Why that point is the same
 *   or better:
 *   - A target lost inside that update is answered right after it, in the same frame (the hold, the fire pause, the
 *     search request), as is whatever else that update or HellForge's other mods' callbacks inside it changed. The
 *     Lua's second check, before that update, never saw such a loss: the next frame's first check answered it (the
 *     one-frame gap of the Lua and of the 1:1 port). The answer is in place before the next update either way; now it
 *     is from the end of the frame the loss happened in.
 *   - What the Lua's second check answered before the update, and the post-update point would answer one update
 *     later, are the first check's own changes. What a check changed the next check only keeps (a hold, a pause, a
 *     request, a resume), except one: a check that released a hold because the sentry tracks again saw the retention
 *     bit still set, so only the next check records the new target's aim. The Lua's second check recorded it before
 *     the update, in time for a loss inside it; that frame gets a second check at once, where the Lua made it, and the
 *     post-update check follows (it holds a loss inside the update with that aim, in the same frame).
 *   - A check that failed starts fresh with nothing engaged, as in the Lua: no second check that frame.
 *   The post-update tick is registered while a sentry is engaged and removed when none is: a frame with nothing engaged
 *   has none. Without the core's frame hook it runs right after the tick, back to back, where the Lua made its second
 *   check. When the core refuses the post-update tick, the second check runs at once, there too, and the next engaged
 *   frame asks again.
 * - The seven code checks (the four game.dll setters, the exe's pose getter and terrain query routines) run once, at the
 *   first check that finds a sentry this machine controls, as the Lua's: in a mission, never at HF_EVENT_GAME_LOADED,
 *   the first tick or on the ship (no such sentry then). That is far past HellForge's decoding of game.dll in parts
 *   after that event (its own later pins get 20 s), so they stay there rather than on vpm_when_code_ready. Bytes that
 *   did not match would be an own error of that check (everything restored, a fresh start, the next check tries again;
 *   8 in a burst stop it), as in the Lua.
 * - Reads inside game.dll's and the exe's images (the managers' roots, the clock root, the mission record pointer, the
 *   unit table, actor pools) are plain loads, not ReadProcessMemory.
 * - Memory protection (vpm_writable) is checked once per range, before its first write, and the result kept until the
 *   targeting registry changes (a new mission) or a failure resets the component; the Lua queried before every hold,
 *   release, pause and request (5 queries per target loss, each up to a few ms in game).
 * - Writes to the sentry's own runtime data (the aim, the search deadline) are plain stores to that verified memory.
 * - The game's update errors no longer reach the pack, so the Lua's pause after an error below it is gone; there is no
 *   shutdown event, so neither is the shutdown restore. The JIT notes are dropped; the diagnostics log (opt-in, its
 *   counters and records rewritten with each status, at most every 2 s) is now the detailed lines below.
 * - The sentries are found by the Lua's own scan of the targeting registry, not HellForge's HF_ON_SPAWN: the spawn event
 *   reports authority from the spawn info, not the entity record's control bits the Lua tests, it does not give the
 *   targeting index the runtime rows are reached by, and it misses control passing to this machine in place. The
 *   mission check reads the Lua's mode record, not HfApi.game_state (another global).
 * Multiplayer: the Lua acts only on sentries this machine controls (entity record byte 20 & 3 == 1; which machine that
 * is for a player's sentry is not established offline); the retention flag, turn speed and fire mode setters go through
 * the game's replication, the aim and the search deadline are this machine's simulation state. A sentry whose control
 * moves away is left alone (its release refuses to write). Authority transitions are unverified in game.
 * Diagnostics. With the pack's Diagnostics set to Detailed (vpm_log_detail; nothing in Normal mode), on the check that
 * saw it: the functions checked and bound; a sentry located (its targeting entry, entity, behavior, aim, runtime and
 * weapon manager addresses); a change of how many sentries this machine controls; a hold (node, the held aim, a late
 * aim put back) or why one was refused (once per record); a hold released and why (tracking, scanning, disabled, speeds
 * or another disable bit changed, targeting reclaimed; or the sentry gone, or another instance under its id); a fire
 * pause or resume with the Lua's fire record (reason, error, travel, terrain, synced, targets); a fire mode the game
 * changed; a target behind terrain (the query's result: hit unit, actor, distance) and clear again; a search shortened,
 * released or consumed; a failed check (the burst count; its first line stays in the log in both modes). At each
 * mission's end and at a mark the core logs the counters (vpm_on_summary: checks, holds, releases, late aim, fire
 * pauses, resumes, searches shortened); describe (a mark) gives the status, the sentries and leases, whether the
 * functions are bound and the mission state.
 * Later improvement, not built: detours of the targeting update and the Gatling and machine gun fire handlers would
 * remove the per-frame polling.
 *
 * Cost (heap reads are vpm_read, guarded plain loads with no Windows call (unmeasured in game), where the Lua's were
 * ReadProcessMemory; plain loads and the game's functions are not reads), pinned by the test. The Lua's numbers are its
 * test_snapshot.lua pins per frame, read and read_into together, which leave out its pose and terrain reads (natives in
 * its fixture: 7 and 4 more per check).
 * - Waiting, no sentry this machine controls: no call on most frames, no post-update tick. On the ship the mission
 *   check reads the mode record on every 60th frame: 1 read (the Lua: 2). In a mission every 30th check classifies
 *   every targeting entry again: the registry header, a read per 256 entries and one per entity header, 3 for one
 *   entity (the Lua: 4), 515 for 512 (the Lua: 516), plus the mission check on every 60th.
 * - Engaged frames make two checks, as the Lua. One Gatling tracking a target: 62 reads, with the pose and the ray
 *   query in each check, and the game's ray query and world id functions twice (the Lua: 58, 80 with its pose and
 *   terrain reads). Holding aim: 54 (the Lua: 54). A sentry scanning with nothing held, paused or requested is not
 *   engaged: one check, 26 (the Lua: 26, 33).
 * - The frame a target is lost: 137 reads (the loss 110, then the held check 27; with the frame hook a loss inside the
 *   update is the tracking check 31, then the loss 110 after it: 141), the fire mode, retention and both speed
 *   setters, 3 plain stores; 5 VirtualQuery on the first loss of a located sentry and none after (the Lua: 156 calls
 *   and 5 VirtualQuery on every loss). Reacquired: three checks, one more than the Lua, once per reacquired target,
 *   so the aim is recorded before the update: 168 reads (the release 106, the record 31, the post-update check 31),
 *   no query (the Lua: 152 and 5). Removed while held: one check (nothing engaged after it), 76 reads, 5 VirtualQuery
 *   (the registry emptied, so its memory is checked again; the Lua: 96 and 5).
 * - The post-update tick adds the core's call and two time-stamp counter reads per engaged frame; registering and
 *   removing it, one each per engaged period (a list scan of the core's, no Windows call).
 * - Locating a sentry: 48 reads, once (the Lua: 52).
 * - Once per session, at the first sentry: 7 code checks (HfApi.code_matches; the Lua read the bytes).
 * - Diagnostics: the idle gate and the idle frames above are unchanged (no call, no detailed check; the test pins them in
 *   both modes). Each check compares the sentry count with the last one said; a check that acts (a hold, a release, a
 *   pause, a resume, a search, a block, a located sentry, a failure) adds one global read (the Diagnostics flag) per
 *   detailed line, and a terrain query keeps its result (a copy). Nothing else in Normal mode; the summary runs at a
 *   mission's end only.
 * Nothing is allocated; no clock is read (the time is the frames' dt summed). */
#include <stdio.h>
#include <string.h>
#include "sentry_aim.h"

#define ERRORS_TO_STOP 8      /* own errors in one burst stop the component */
#define CLEAN_FRAMES 3600     /* a minute without an own error ends a burst */

SarState sar_state;

static struct
{
    double clock;             /* seconds: the frames' dt summed (the Lua's api.time()) */
    const char* status;       /* the reason last shown as the status */
    int engaged;              /* the last check left a sentry engaged (the Lua's state.engaged) */
    int post;                 /* the post-update tick is registered (only while a sentry is engaged) */
    int failed;               /* an own error this frame */
    uint32_t errors, clean_run;
    char burst[160];          /* the first error of the burst */
    int observed_said;        /* the sentry count a detailed line last said (-1: none yet) */
} s;

static SarRow* g_rows[SAR_MAX_SENTRIES];

static void Report(VpmComponent* self, const char* status)
{
    if (status == s.status) return;
    s.status = status;
    vpm_set_status(self, status);
}

/* Restores every hold, fire pause and search request: aim, retention bit, turn speeds, fire mode and deadline. A
 * record that could not be restored stays for the next attempt. 1 everything restored. */
static int Restore(void)
{
    int fire = sar_fire_stop();
    return sar_aim_stop() && fire;
}

/* After a full restore nothing is in progress, so the next check starts as on a fresh load. The counters stay, and so
 * do the bound functions (checked once per session). */
static void FreshStart(void)
{
    sar_state.observed = sar_state.holding = sar_state.fire_paused = sar_state.selections = 0;
    s.engaged = 0; /* nothing in progress: no second check until the next frame's first one */
    sar_cache_reset();
}

/* The runtime guard's own error count: one log line per burst, the 8th error of a burst stops the component. */
static void OwnError(VpmComponent* self, const char* problem)
{
    s.failed = 1;
    s.clean_run = 0;
    s.errors++;
    if (s.errors == 1)
    {
        snprintf(s.burst, sizeof s.burst, "%s", problem);
        vpm_log(self, "error: %s", problem); /* lint-ok: C4 the frame an error is answered, once per burst */
    }
    if (s.errors >= ERRORS_TO_STOP) vpm_fail(self, "stopped after %d errors: %s", ERRORS_TO_STOP, s.burst);
}

/* The check raised or refused: everything it holds is restored and the next frame starts afresh. Without a full
 * restore the component stops at once. */
static void Failed(VpmComponent* self, const char* problem)
{
    vpm_log_detail(self, "check failed (%u before it in this burst; %d stop it): %s; everything restored, a fresh start",
        s.errors, ERRORS_TO_STOP, problem);
    if (!Restore()) { vpm_fail(self, "%s", problem); return; }
    FreshStart();
    Report(self, problem);
    OwnError(self, problem);
}

/* The state an accepted check reports. */
static const char* Outcome(int count)
{
    if (sar_state.fire_paused > 0) return "firing_paused";
    if (sar_state.holding > 0) return "holding";
    return count > 0 ? "observing" : "waiting_for_sentries";
}

/* Whether a target loss inside the next game update could matter: a sentry tracks a target, holds aim, pauses fire or
 * waits on a search request (the Lua's engaged). */
static int Engaged(int count)
{
    if (sar_state.holding > 0 || sar_state.fire_paused > 0 || sar_state.selections > 0) return 1;
    for (int i = 0; i < count; i++)
        if (g_rows[i]->has && g_rows[i]->target != 0) return 1;
    return 0;
}

/* One check (M.apply): 1 accepted (*reason the state), 0 failed (*reason why). */
static int Apply(const char** reason)
{
    int count = 0;
    s.engaged = 0;
    if (!sar_snapshot(g_rows, &count, reason)) { sar_cache_reset(); return 0; }
    if (count == 0 && !sar_natives_bound()) { *reason = "waiting_for_sentries"; return 1; }
    if (!sar_natives_bound() && !sar_bind_natives(reason)) return 0;
    for (int i = 0; i < count; i++)
        if (g_rows[i]->has_fire && !sar_prepare_fire(g_rows[i], reason)) return 0;
    if (!sar_fire_step(g_rows, count, s.clock, reason) || !sar_selection_step(g_rows, count, reason) ||
        !sar_aim_step(g_rows, count, reason))
        return 0;
    s.engaged = Engaged(count);
    *reason = Outcome(count);
    return 1;
}

/* A change of how many sentries this machine controls, on the check that saw it. */
static void Observed(VpmComponent* self)
{
    if ((int)sar_state.observed == s.observed_said) return;
    s.observed_said = (int)sar_state.observed;
    vpm_log_detail(self, "%u sentries this machine controls (holding %u, fire paused %u, searches pending %u)",
        sar_state.observed, sar_state.holding, sar_state.fire_paused, sar_state.selections);
}

static void Check(VpmComponent* self)
{
    const char* reason = "";
    sar_state.polls++;
    if (!Apply(&reason)) { Failed(self, reason); return; }
    Observed(self);
    Report(self, reason);
}

/* The frame's last check is done: a frame without an own error counts toward the end of a burst (the guard's
 * count_clean, after its after-update step). */
static void FrameDone(void)
{
    if (!s.failed && ++s.clean_run == CLEAN_FRAMES) s.errors = 0;
}

/* The Lua's second check (archive_loader.lua after()), after game.dll's whole update in the same frame: it answers a
 * target lost inside that update before the next frame. Registered only while a sentry is engaged, so it always
 * checks. lint: per-frame */
static void PostTick(VpmComponent* self, float dt)
{
    Check(self);
    FrameDone();
}

/* Registers the post-update tick while a second check is due and removes it when not: a frame with no sentry engaged
 * has none. One compare while nothing changes. 0 when it could not be registered. */
static int PostDue(VpmComponent* self, int due)
{
    if (due == s.post) return 1;
    if (!due)
    {
        vpm_post_tick_stop(self);
        s.post = 0;
        return 1;
    }
    s.post = vpm_post_tick_start(self, PostTick);
    return s.post;
}

/* The idle gate first: while no sentry this machine controls exists, a frame ends there. A check that released a hold
 * (the sentry tracks again) is followed at once: its snapshot still showed the retention bit, so the reacquired target's
 * aim is recorded by the next check, and the Lua's second check, right after the first, recorded it before the game's
 * update, in time for a loss inside it. While a sentry is engaged (the Lua's condition) the second check runs after
 * game.dll's update (PostTick), else the frame ends here. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.clock += dt;
    sar_state.updates++;
    s.failed = 0;
    uint32_t releases = sar_state.releases;
    if (!sar_idle()) Check(self);
    if (vpm_running(self) && !s.failed && s.engaged && sar_state.releases != releases) Check(self);
    if (!vpm_running(self)) return;
    if (PostDue(self, s.engaged))
    {
        if (!s.engaged) FrameDone();
        return;
    }
    Check(self); /* the post-update tick refused: the second check at once, where the Lua made it */
    FrameDone();
}

static void GameLoaded(VpmComponent* self, HfEvent event)
{
    if (vpm_ticking(self)) return;
    if (!vpm_tick_start(self, Tick)) { vpm_fail(self, "Game update unavailable"); return; }
    vpm_log(self, "waiting_for_sentries");
}

/* Its key state for a mark: the status, what the checks found, the leases in force. */
static void Describe(VpmComponent* self, char* out, size_t size)
{
    int located = 0;
    for (int k = 0; k < SAR_MAX_SENTRIES; k++) located += sar_layouts[k].used;
    snprintf(out, size, "%s; %u sentries (%d located); holding %u, fire paused %u, searches pending %u; engaged %d; "
        "functions %s; %s; errors in this burst %u",
        s.status != NULL ? s.status : "starting", sar_state.observed, located, sar_state.holding, sar_state.fire_paused,
        sar_state.selections, s.engaged, sar_natives_bound() ? "bound" : "not bound yet",
        !sar_cache.exists || sar_cache.outside == SAR_UNKNOWN ? "mission not checked yet" :
            sar_cache.outside ? "outside a mission" : "in a mission", s.errors);
}

/* The counters of the Lua's diagnostics log, at each mission's end and at a mark. */
static void Summary(VpmComponent* self, char* out, size_t size)
{
    snprintf(out, size, "checks %u, holds %u, releases %u, late aim %u, fire pauses %u, resumes %u, searches shortened %u",
        sar_state.polls, sar_state.holds, sar_state.releases, sar_state.late_aim, sar_state.fire_pauses,
        sar_state.fire_resumes, sar_state.reselections);
}

/* The core stopping the component (an error burst, a refused restore, a fault): everything this module owns goes back. */
static void Stop(VpmComponent* self)
{
    if (!Restore()) vpm_log(self, "restore_failed");
}

static int Start(VpmComponent* self)
{
    /* A live switch-on after a stop whose restore failed: one more try before the reset forgets what is still held (the
     * functions are still bound from the earlier start; on a first start no record is in use). */
    if (!Restore()) vpm_log(self, "restore_failed: a sentry changed before this start stays as it is");
    memset(&s, 0, sizeof s);
    memset(&sar_state, 0, sizeof sar_state);
    sar_state.self = self;
    s.observed_said = -1;
    sar_layout_start();
    sar_natives_start();
    Report(self, "waiting_for_sentries");
    vpm_on_summary(self, Summary);
    return vpm_on_load(self, HF_EVENT_GAME_LOADED, GameLoaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_sentry_aim_retention = {"sentry_aim_retention", "Sentry Aim Retention", "1.1.1", 0, Start, Stop, Describe};
