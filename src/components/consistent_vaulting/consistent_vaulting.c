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
 *   vpm_read, as the Lua's ReadProcessMemory. Every guard is verified the same way before writes.
 * - Writes are plain stores after one VirtualQuery per target span, remembered for the session (cv_writable), where the
 *   Lua checked protection before every write; each store is read back as before.
 * - The local avatar is the Lua's own resolution (light reads with guards handed to the vault check, a kept identity,
 *   the mission gate first), not vpm_local_avatar: that one has no mission gate, accepts other player counts and keeps
 *   no guards. The input address is vpm_action_slot's (slot 14).
 * - Time is the sum of dt (the Lua's api.time()).
 * - One check per frame, plus the Lua's replayed check on the frame work starts. The Lua's second check after the
 *   game's update while work is in progress is dropped: HellForge's tick runs at one place in the frame (the menu sound
 *   manager's update) and has no after-update callback, and back to back the second check would see the same state.
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
 * COST (tests/components/consistent_vaulting_test.c pins each count; reads are vpm_read, about 1-2 us each in game, and
 * the Lua's are its frame_budget pins of read + read_into, each one ReadProcessMemory; VQ is VirtualQuery):
 * - Idle frames, with the idle gate: outside a mission 59 of 60 frames no call, the 60th 1 read (Lua 2: the mode
 *   pointer is a plain load now); in a mission 9 of 10 frames 1 read (the input byte at the kept avatar index), the
 *   10th 6 reads (Lua 7). No VQ, no write, no native call, no allocation, no log.
 * - Active frames make one check (the Lua two while busy: one more after the game's update), plus the replayed check
 *   on the frame work starts: a press on a gated frame arms with 2 checks and 180 reads (Lua 3 checks, 252).
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

/* One check per frame, before the game's update; the idle gate answers idle frames first. Work that starts right after
 * a frame that left nothing in progress gets a second check at once, as the Lua replayed it: the first check's own
 * native retry can start a climb that an armed lease must cap now. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    CvState* st = &s.state;
    st->now += dt;
    s.failed = 0;
    if (!cv_slope_idle(st))
    {
        Check(self);
        if (vpm_running(self) && !s.failed && s.skipped && st->busy != 0)
        {
            s.skipped = 0;
            Check(self);
        }
    }
    s.skipped = st->busy == 0;
    if (!s.failed && ++s.clean == CLEAN_FRAMES) s.errors = 0;
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
