/* Controllable Hover Pack v1.8.1 (Lua: components/ControllableHoverPack/src: hover_data.lua, settings.lua, cancel.lua,
 * archive_loader.lua), build 25480438.
 *
 * Pressing the Jump Pack action again during a hover pack's powered hover descends early, with the game's own landing
 * assistance: the pack's own hover duration is cut to 1/1024 s (hover_settings.c) for the rest of that flight and put
 * back when the flight ends. The press must follow a release (the activation hold never counts), once per flight, with
 * the game focused; before the cut the pack is located afresh from the registry roots and must be the same pack in the
 * same flight with the Jump held. Ordinary jump packs, grounded movement, the landing assistance, ragdoll, swimming and
 * other players' packs never cancel. Each frame reads the local player's hover pack (hover_data.c).
 *
 * The idle gate (the Lua's M.idle) answers frames after a full check that found nothing to do, while no cut is held:
 * outside a mission 59 frames with no read; in a mission without a usable hover pack 29 frames with no read; with the
 * hover pack worn and inactive 29 frames reading only its 5-byte state row (a set +0 or a failed read ends the wait and
 * the same frame runs the full check). A mission start is seen up to 59 frames late (during the drop), a pack picked up
 * or moved in its registry up to 29 frames late; the window counts frames, never the clock.
 *
 * On HellForge:
 * - The tick runs before the game's update (HellForge's game-thread callback) where the Lua ran after it. The order
 *   does not matter here: the cut is a lasting value in the pack's record, not a per-frame flag, so it reaches the
 *   native lift test on the next physics step either way, and the press, the confirmation and the store happen in the
 *   same tick with no game code between them. At most it moves the press and the restoration by one frame.
 * - Writes: plain stores into the pack's records, each checked with vpm_writable when found (hover_settings.c).
 * - The Lua's errors (an unsupported duration mode, storage that is not writable data, a write that did not hold) stop
 *   the component at once with vpm_fail, whose stop() puts the duration back; the Lua's guard stopped after 8 in a
 *   burst. Its pause and resume around errors in the game's update, the retries of a restore after a stop and the
 *   shutdown restore are gone: HellForge does not chain the game's update, a stopped component no longer ticks, and
 *   there is no shutdown event (the record goes with the process).
 * - Its developer diagnostics (CowboyBingusDiagnostics status lines and log file) are dropped. The status the Lua kept
 *   (waiting_for_mission, watching_hover, cancel_requested, native_descent...) is the component's status in the Mods
 *   tab, set when it changes; the first cancellation and the first restoration of the session are logged.
 * - The mission check is the Lua's own (the mode global's active flag and type 1 .. 7), not HF_ON_MISSION_START.
 *
 * COST (calls per frame; the Lua's counts from its frame_budget pins in parentheses; reads are vpm_read, the Lua's
 * ReadProcessMemory; the game.dll globals the Lua read are plain loads here):
 * - outside a mission: 1 read every 60th frame, none on the 59 between (2);
 * - in a mission without a usable hover pack: 7 reads every 30th frame with no backpack, 10 with another jump pack
 *   (8, 11); none on the 29 between; the first frame in a mission 20 (25);
 * - hover pack worn, not flying: 1 read on 29 of 30 frames (1), 15 on the 30th (16), 34 after a change (41);
 * - flight: 15 reads and one focus check (GetForegroundWindow, GetWindowThreadProcessId) (16 and one);
 * - native descent: 15 reads (16);
 * - early-descent press: 49 reads for the two snapshots and two focus checks (57), then the cut: with the pack's
 *   record created 63 reads and 4 VirtualQuery (69 reads, 5 queries, 5 WriteProcessMemory), with it reused 43 reads and
 *   1 VirtualQuery (46, 1, 1);
 * - the landing after it (restoration): 15 + 29 reads and 1 VirtualQuery (16 + 31, 1 query, 1 write).
 * No allocation and no logging on any frame but the session's first cancellation and first restoration. Once only:
 * GetCurrentProcessId at start. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "../../core/vpm.h"
#include "hover.h"

#define IDLE_SHIP 60
#define IDLE_MISSION 30
#define RAISED (-1) /* the Lua raised: the component was stopped */

static const char* const kStatusNames[CHP_STATUS_COUNT] = {
    "valid", "waiting_for_mission", "waiting_for_player", "waiting_for_avatar", "no_backpack", "no_jump_pack",
    "not_hover_pack", "pack_not_owned", "pack_not_attached", "waiting_for_read", "waiting_for_pointer",
    "waiting_for_game_data", "waiting_for_hover", "watching_hover", "waiting_for_game_focus", "snapshot_changed",
    "cancel_requested", "native_descent", "restore_pending",
};

static struct
{
    int idle_left;           /* frames the idle gate may still answer */
    uintptr_t idle_at;       /* the state row it reads, or 0 */
    ChpPolicy policy;
    unsigned long process;   /* this process, for the focus check */
    int shown;               /* the status set last, and its game-data error */
    const char* shown_error;
    int cancelled;           /* the first cancellation was logged */
    int restored;            /* the first restoration was logged */
} s;

/* The game window is in front: two user32 calls, on flight frames only. */
static int Focused(void)
{
    const VpmUser32* user = vpm_user32();
    void* window = user->GetForegroundWindow(); /* lint-ok: C4 flight frames only, the Lua's focus check */
    if (window == NULL) return 0;
    unsigned long process = 0;
    (void)user->GetWindowThreadProcessId(window, &process); /* lint-ok: C4 flight frames only; the id is the answer */
    return process == s.process;
}

/* lint: per-frame */
static int Idle(void)
{
    uint8_t row[5];
    int left = s.idle_left;
    if (left <= 1 || chp_lease_held())
    {
        s.idle_left = 0;
        return 0;
    }
    s.idle_left = left - 1;
    if (s.idle_at != 0 && (!vpm_read(s.idle_at, row, sizeof row) || row[0] != 0))
    {
        s.idle_left = 0;
        return 0;
    }
    return 1;
}

static int NoHover(int status)
{
    return status == CHP_WAITING_FOR_PLAYER || status == CHP_WAITING_FOR_AVATAR || status == CHP_NO_BACKPACK ||
           status == CHP_NO_JUMP_PACK || status == CHP_NOT_HOVER_PACK || status == CHP_PACK_NOT_OWNED ||
           status == CHP_PACK_NOT_ATTACHED;
}

/* After a full check: how many frames the gate may answer, and what it reads. */
static void Arm(int status)
{
    uintptr_t at = 0;
    int left = 0;
    if (chp_lease_held()) left = 0;
    else if (status == CHP_WAITING_FOR_MISSION) left = IDLE_SHIP;
    else if (NoHover(status)) left = IDLE_MISSION;
    else if (status == CHP_WAITING_FOR_HOVER && !chp_snapshot_last()->active && chp_snapshot_kept_row(&at)) left = IDLE_MISSION;
    s.idle_left = left;
    s.idle_at = at;
}

/* The pack located afresh: the same pack (key) in the same flight with the Jump held. */
static int Confirmed(const ChpSnapshot* snap)
{
    ChpKey key = snap->key;
    const ChpSnapshot* again = NULL;
    return chp_snapshot(1, &again) == CHP_VALID && chp_same_key(&again->key, &key) && again->flight && again->down;
}

/* The cut, for the pack the confirmation found: 1, 0 not now, RAISED. */
static int Cancel(VpmComponent* self)
{
    const ChpSnapshot* now = chp_snapshot_last();
    ChpTarget target;
    target.manager = now->manager;
    target.pack = now->pack;
    memcpy(target.identity, now->key.entity, sizeof target.identity);
    target.key = now->key;
    const char* error = "";
    int r = chp_settings_cancel(&target, &error);
    if (r < 0)
    {
        vpm_fail(self, "%s", error);
        return RAISED;
    }
    if (r > 0 && !s.cancelled)
    {
        s.cancelled = 1;
        vpm_log(self, "cancel_requested: the hover pack's duration is cut from %.2f s to 1/1024 s (its own record %s); "
            "the landing assistance stays. Only the session's first cancellation is logged.",
            (double)chp_lease_original(), chp_settings_created() ? "created" : "reused");
    }
    return r;
}

/* The lease's restoration: 1 settled, 0 waiting, RAISED. */
static int Restore(VpmComponent* self)
{
    const char* why = "";
    int before = chp_settings_restorations();
    int r = chp_settings_restore(&why);
    if (r < 0)
    {
        vpm_fail(self, "%s", why);
        return RAISED;
    }
    if (chp_settings_restorations() > before && !s.restored)
    {
        s.restored = 1;
        vpm_log(self, "restored: the hover pack's duration is %.2f s again. Only the session's first restoration is logged.",
            (double)chp_lease_original());
    }
    return r;
}

/* A flight frame: the focus check and the policy; a cancellation checks the focus again and locates the pack afresh. */
static int Fly(VpmComponent* self, const ChpSnapshot* snap)
{
    if (!Focused())
    {
        chp_policy_step(&s.policy, NULL);
        return CHP_WAITING_FOR_GAME_FOCUS;
    }
    if (!chp_policy_step(&s.policy, snap)) return CHP_WATCHING_HOVER;
    int r = Focused() && Confirmed(snap) ? Cancel(self) : 0;
    if (r == RAISED) return RAISED;
    if (r == 0)
    {
        chp_policy_step(&s.policy, NULL);
        return CHP_SNAPSHOT_CHANGED;
    }
    return CHP_CANCEL_REQUESTED;
}

static int Work(VpmComponent* self)
{
    const ChpSnapshot* snap = NULL;
    int reason = chp_snapshot(0, &snap);
    if (chp_lease_held())
    {
        if (reason == CHP_VALID && chp_same_key(&snap->key, chp_lease_key()) && snap->active) return CHP_NATIVE_DESCENT;
        int r = Restore(self);
        if (r != 1) return r == RAISED ? RAISED : CHP_RESTORE_PENDING;
        chp_policy_step(&s.policy, NULL);
    }
    /* Without a hover-pack snapshot there is nothing to focus-gate; without a flight no cancellation can start. */
    if (reason != CHP_VALID)
    {
        chp_policy_step(&s.policy, NULL);
        return reason;
    }
    if (!snap->flight)
    {
        chp_policy_step(&s.policy, snap);
        return CHP_WAITING_FOR_HOVER;
    }
    return Fly(self, snap);
}

/* The Mods tab's status, when it changes. */
static void Show(VpmComponent* self, int status)
{
    const char* error = status == CHP_WAITING_FOR_GAME_DATA ? chp_snapshot_error() : NULL;
    if (status == s.shown && error == s.shown_error) return;
    s.shown = status;
    s.shown_error = error;
    if (error == NULL)
    {
        vpm_set_status(self, kStatusNames[status]);
        return;
    }
    char text[128];
    snprintf(text, sizeof text, "%s: %s", kStatusNames[status], error);
    vpm_set_status(self, text);
}

/* lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    if (Idle()) return;
    int status = Work(self);
    if (status == RAISED) return;
    Arm(status);
    Show(self, status);
}

/* Puts the duration back and forgets the flight (the core stopping the component). */
static void Stop(VpmComponent* self)
{
    const char* why = "";
    s.idle_left = 0;
    chp_policy_step(&s.policy, NULL);
    int r = chp_settings_restore(&why);
    if (r < 0) vpm_log(self, "restore_failed: %s", why);
    else if (r == 0) vpm_log(self, "restore_abandoned: %s (a stopped component does not try again)", why);
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.shown = CHP_WAITING_FOR_MISSION;
    chp_snapshot_reset();
    chp_settings_reset();
    const VpmUser32* user = vpm_user32();
    if (user->GetForegroundWindow == NULL || user->GetWindowThreadProcessId == NULL)
        return vpm_fail(self, "user32's GetForegroundWindow or GetWindowThreadProcessId is unavailable");
    s.process = GetCurrentProcessId();
    vpm_set_status(self, kStatusNames[CHP_WAITING_FOR_MISSION]);
    if (!vpm_tick_start(self, Tick)) return vpm_fail(self, "the game thread could not be reached");
    return 0;
}

const VpmComponentDef vpm_component_controllable_hover_pack = {"controllable_hover_pack", "Controllable Hover Pack", "1.8.1", 0, Start, Stop};
