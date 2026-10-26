/* Consistent Vaulting v8.9.1 (Lua: components/ConsistentVaulting/src/vault_data.lua, slope_assist.lua, archive_loader.lua
 * and windows_api.lua's api.native), for build 25480438.
 *
 * Manual vaults (the climb input, action slot 14) are refused when the climb selector's first hit fails, though a later
 * hit of the same ten-query batch would pass. This gives the game's own driver one freshly validated result:
 * - Stage 2 (a completed query batch not yet consumed): the plan exposes the first hit that passes the surface angle,
 *   actor motion, height and the native exit validator, by clearing the earlier usable hits' units (or, for the only
 *   candidate with the manual metadata veto, its actor). The writes stay while every check would make the same plan.
 * - Stage 3 (consumed): the retained local queries are cast again into private storage (fresh obstacle checks), after a
 *   private controller copy ran the original approach detector; changed geometry is rebuilt privately. The chosen fresh
 *   result is exposed with the phase back to 2, the original driver runs once with zero dt, and everything is restored.
 * - A fresh press also opens a 1.25 s search for an assist (cv_slope.c): a validated steep face (up to 65 degrees) or
 *   higher top (up to 2.5 units: higher ledge detection) arms a lease of a few settings cells, restored when it ends.
 * At most 136 bytes of private game data change at once (120 in the controller, 16 in settings cells), and every change
 * goes back.
 *
 * Files: cv_memory.c (reads, guards, the game's hash map, stores), cv_native.c (the game functions, checked once per
 * session), cv_vault.c (the vault snapshot), cv_commit.c (plan, commit, restore, the late retry), cv_refresh.c (fresh
 * casts, reprojection, the candidate search), cv_identity.c (the slope snapshot and kept identity), cv_slope.c (the
 * assist lease and the idle gate).
 *
 * On HellForge, as in the Lua: the same addresses, reads, checks, writes and native calls, with these differences.
 * - Native calls go through C function pointers to the same game.dll and exe functions, on the game thread (the tick).
 * - Reads of game.dll's and the exe's images (globals, the exe's tables) are plain loads; heap reads go through
 *   vpm_read (a guarded plain load) where the Lua used ReadProcessMemory. Every guard is verified the same way before
 *   writes.
 * - Writes are plain stores after one VirtualQuery per target span, remembered for the session (cv_writable), where the
 *   Lua checked protection before every write; each store is read back as before.
 * - The local avatar is the Lua's own resolution (light reads with guards handed to the vault check, a kept identity,
 *   the mission gate first), not vpm_local_avatar: that one has no mission gate, accepts other player counts and keeps
 *   no guards. The input address is vpm_action_slot's (slot 14).
 * - Time is the sum of dt (the Lua's api.time()).
 * - The checks per frame are the Lua's (archive_loader.lua step and after): the first at the start of game.dll's
 *   update, where the Lua global `update` ran; the replayed one at once on the frame work starts; and while work is in
 *   progress (state.busy not false after them) a second one. The Lua made that second check after its update chain,
 *   still before game.dll's update; here it runs after game.dll's whole update in the same frame (the core's
 *   post-update tick). Why that point is the same or better:
 *   - It sees what that update did, in the frame it did it: the vault stage the update reached (a batch completed or
 *     consumed), a climb the native driver started, an identity or settings cell that changed, and what HellForge's
 *     other mods changed in their callbacks, which run inside that update. The Lua's second check saw none of that
 *     (only its update chain ran in between) and left it to the next frame's first check. The answer (the alternative
 *     prepared, the speed cap, a restore) is in place before the next update either way, now from the end of the frame
 *     it was needed in; the next frame's first check confirms it.
 *   - What the Lua's second check answered before the update, and the post-update point would answer one update
 *     later, are the first check's own changes. What a check changed the next check only keeps (a prepared
 *     alternative, an armed lease, a cap, a restore), except in two cases, where a second check runs at once, where the
 *     Lua made it: a climb the check's own native retry started under an armed slope lease (the Lua capped its speed
 *     before the update; the post-update check still follows), and a check that raised (it restored everything and
 *     started fresh; from there the Lua's second check could prepare a stage-2 batch again before the update consumed
 *     it; that frame has no post-update check, two checks as the Lua's).
 *   The post-update tick is registered when work starts and removed when it ends: an idle frame has none. Without the
 *   core's frame hook it runs right after the tick, back to back, where the Lua made its second check.
 * - Raised errors (a snapshot that could not be read, an invalid native result) keep the Lua's outcomes: a waiting
 *   status, a refusal that stops the component, or an error of the check, which restores everything and starts fresh;
 *   8 in a burst (a burst ends after 3600 clean frames) stop the component. The Lua's pcall guards, its pause after an
 *   error in another mod's update, its shutdown restore, the diagnostics heartbeat file and the probe traces are
 *   dropped (no shutdown event; developer-only); the counters its tests check are kept, not logged.
 * - A write that fails partway cannot happen with plain stores (a fault is the crash guard's); the read-backs and the
 *   partial-write undo stay for writes another thread replaced.
 * Detours on the selector (game.dll 0xA9E450) and the settings lookup would replace the per-frame checks: a later
 * improvement, not built.
 *
 * COST (tests/components/consistent_vaulting_test.c pins each count; reads are vpm_read, guarded plain loads of about
 * 25 ns, and the Lua's are its frame_budget pins of read + read_into, each one ReadProcessMemory; VQ is VirtualQuery):
 * - Idle frames, with the idle gate: outside a mission 59 of 60 frames no call, the 60th 1 read (Lua 2: the mode
 *   pointer is a plain load now); in a mission 9 of 10 frames 1 read (the input byte at the kept avatar index), the
 *   10th 6 reads (Lua 7). No VQ, no write, no native call, no allocation, no log, no post-update tick (pinned with and
 *   without the frame hook).
 * - Busy frames make two checks, as the Lua: a held lease 78 reads (Lua 2 x 44 = 88). Three on the frame work starts,
 *   as the Lua: a press on a gated frame arms with 219 reads (Lua 252). Three on a frame whose own retry started a
 *   climb under an uncapped slope lease, one more than the Lua, at most once per assisted climb, so that the cap is in
 *   place before the update as in the Lua and the post-update check still sees that update. A frame whose check raised
 *   makes two, both before the update, as the Lua. The post-update tick adds the core's call and two time-stamp counter
 *   reads per busy frame; registering and removing it, one each per busy period (a list scan of the core's, no Windows
 *   call).
 * - One check, C reads (Lua reads): input held without a new press 40 (45); held on a retained query 47 (52); slope
 *   lease armed 140 and 2 VQ the first time (163, 2); lease or climb held 39 (44); climb starts, the speed cap, 70 and
 *   1 VQ the first time (81, 1); lease released 101, 0 VQ (114, 3). The vault alone: alternative prepared 161, 1 VQ
 *   the first time per controller (178, 1); held write kept 86 (94); released and restored 41, 0 VQ (48, 1); late
 *   native retry 203, 0 VQ (236, 2); the candidate search 113 (127). Every span is checked once per session where the
 *   Lua checked before every commit, restore, arm, cap and release. The C counts include the read inside the mover
 *   position call (1 per call), which the Lua's pins left out (its tests stubbed api.native; in game it made it too).
 * - Native calls only on checks past the idle gates, as the Lua: per vault check a mover position (3 calls), an actor
 *   check (up to 4) and an exit validation (3) per candidate hit, the approach detector, two per fresh cast, the driver
 *   once per retry; about 15 per vault. Unmeasured in game.
 * - Once per session: the native binding (9 plain loads, 3 code checks; the override routine's code check before each
 *   override creation). Static memory about 220 KB (the snapshot records with their guards). */
#include <stdio.h>
#include <string.h>
#include "cv.h"

static struct
{
    CvState state;
    int skipped;      /* the last frame left nothing in progress (the Lua's skipped) */
    int post;         /* the post-update tick is registered (only while work is in progress) */
    int failed;       /* this frame's check raised */
    int errors;       /* own errors in this burst */
    int clean;        /* frames without one since the last */
    char burst[160];  /* the burst's first error */
    char status[192]; /* the last check's reason, as the status shows it */
} s;

#define ERROR_LIMIT 8
#define CLEAN_FRAMES 3600

void cv_state_reset(CvState* st)
{
    memset(st, 0, sizeof *st);
    st->slope_down = CV_UNSET;
    st->busy = CV_UNSET;
    st->slope_status = "startup";
    st->slope_last_release = "none";
}

#ifdef VPM_TEST
CvState* cv_test_state(void) { return &s.state; }
#endif

/* ---- one check (M.apply) ----------------------------------------------------------------------------------------- */

static int Apply(CvState* st, const char** reason)
{
    const CvPending* held = cv_held_writes(st);
    int accepted = cv_slope_step(st, reason);
    if (accepted != 1) return accepted;
    const CvSlope* avatar = st->avatar;
    int outside = st->avatar_outside;
    st->avatar = NULL;
    st->avatar_outside = 0;
    return cv_vault_apply(st, held, avatar, outside, reason);
}

/* state.busy tells the tick whether work is in progress: query writes held, a lease or its press window, or a vault
 * check past its idle gates. A check that found nothing to do lets the idle gate answer the next frames.
 * lint: per-frame */
int cv_check(CvState* st, const char** reason)
{
    uint32_t observed = st->observed_queries;
    int accepted = Apply(st, reason);
    if (accepted == CV_RAISED) return accepted;
    st->busy = st->observed_queries != observed || st->has_pending || st->has_lease || st->has_intent;
    cv_slope_settle(accepted == 1 && !st->busy);
    return accepted;
}

/* ---- the component ----------------------------------------------------------------------------------------------- */

/* A fresh start, as after loading: the press window, the input edge (a fresh release is needed again), the retry
 * interval, the avatar handed over within a check and the work in progress. */
static void FreshStart(void)
{
    CvState* st = &s.state;
    st->has_intent = 0;
    st->slope_down = CV_UNSET;
    st->has_retry = 0;
    st->avatar = NULL;
    st->avatar_outside = 0;
    st->busy = CV_UNSET;
    s.skipped = 0;
}

/* The check raised: restore and start fresh, and count it. A restore that fails stops the component at once. */
static void OwnError(VpmComponent* self, const char* text)
{
    char problem[160];
    snprintf(problem, sizeof problem, "%s", text);
    s.failed = 1;
    s.clean = 0;
    if (!cv_stop(&s.state)) { vpm_fail(self, "%s", problem); return; }
    FreshStart();
    if (++s.errors == 1)
    {
        snprintf(s.burst, sizeof s.burst, "%s", problem);
        vpm_log(self, "error: %s", problem);
    }
    if (s.errors >= ERROR_LIMIT) vpm_fail(self, "stopped after %d errors: %s", ERROR_LIMIT, s.burst);
}

static void Report(VpmComponent* self, const char* reason)
{
    if (reason == NULL || strncmp(reason, s.status, sizeof s.status - 1) == 0) return;
    snprintf(s.status, sizeof s.status, "%s", reason);
    vpm_set_status(self, s.status);
}

static void Check(VpmComponent* self)
{
    const char* reason = NULL;
    s.state.counters.polls++;
    int accepted = cv_check(&s.state, &reason);
    if (accepted == CV_RAISED) OwnError(self, cv_error());
    else if (accepted == 0) vpm_fail(self, "%s", reason != NULL ? reason : "refused");
    else Report(self, reason);
}

/* The frame's last check is done: a frame without an own error counts toward the end of a burst (the guard's
 * count_clean, after its after-update step). */
static void FrameDone(void)
{
    if (!s.failed && ++s.clean == CLEAN_FRAMES) s.errors = 0;
}

/* The Lua's second check (archive_loader.lua after()), after game.dll's whole update in the same frame. Registered only
 * while the frame's checks left work in progress, so it always checks. lint: per-frame */
static void PostTick(VpmComponent* self, float dt)
{
    Check(self);
    FrameDone();
}

/* Registers the post-update tick while a second check is due and removes it when not: an idle frame has none. One
 * compare while nothing changes. 0 when it could not be registered. */
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

/* This frame's checks started a native climb (their own retry) while a slope lease is armed and its speed is not capped
 * yet. The Lua's second check ran right after the first, before the game's update, and capped it there. */
static int ClimbUncapped(const CvState* st, uint32_t starts)
{
    return st->counters.native_starts != starts && st->has_lease && st->lease.kind == CV_KIND_SLOPE &&
        !st->lease.speed_capped;
}

/* The Lua's second check, while work is in progress (state.busy not false after the first, the Lua's condition): after
 * game.dll's update (PostTick, which ends the frame). At once, where the Lua made it, after a check that raised: from
 * the fresh start it may prepare a stage-2 batch again before the update consumes it (and the frame makes two checks,
 * as the Lua's); also when the post-update tick could not be registered. lint: per-frame */
static void SecondCheck(VpmComponent* self)
{
    if (s.skipped)
    {
        (void)PostDue(self, 0);
        FrameDone();
        return;
    }
    if (!s.failed && PostDue(self, 1)) return;
    (void)PostDue(self, 0);
    Check(self);
    FrameDone();
}

/* The first check, before the game's update; the idle gate answers idle frames first. A second check at once, as the
 * Lua's replay: for work that starts right after a frame that left nothing in progress (the first check's own native
 * retry can start a climb that an armed lease must cap now), and for a climb this frame's retry started under an
 * uncapped lease. Then the frame's second check (SecondCheck). lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    CvState* st = &s.state;
    st->now += dt;
    s.failed = 0;
    if (!cv_slope_idle(st))
    {
        uint32_t starts = st->counters.native_starts;
        Check(self);
        if (vpm_running(self) && !s.failed && ((s.skipped && st->busy != 0) || ClimbUncapped(st, starts)))
        {
            s.skipped = 0;
            Check(self);
        }
    }
    s.skipped = st->busy == 0;
    if (vpm_running(self)) SecondCheck(self);
}

static void GameLoaded(VpmComponent* self, HfEvent event)
{
    if (vpm_game() == 0 || vpm_exe() == 0) { vpm_fail(self, "game.dll or the executable is not loaded"); return; }
    if (!vpm_tick_start(self, Tick)) { vpm_fail(self, "the game thread could not be reached"); return; }
    snprintf(s.status, sizeof s.status, "waiting_for_mission");
    vpm_set_status(self, s.status);
    vpm_log(self, "waiting_for_mission");
}

/* Puts back the query writes and the lease's cells this session still holds. */
static void Stop(VpmComponent* self)
{
    if (!cv_stop(&s.state)) vpm_log(self, "local_restore_failed");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    cv_state_reset(&s.state);
    cv_memory_reset();
    cv_native_reset();
    cv_identity_reset();
    cv_slope_reset();
    return vpm_on_load(self, HF_EVENT_GAME_LOADED, GameLoaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_consistent_vaulting = {"consistent_vaulting", "Consistent Vaulting", "8.9.1", 0, Start, Stop};
