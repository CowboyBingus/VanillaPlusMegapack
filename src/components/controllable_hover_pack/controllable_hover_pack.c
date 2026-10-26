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
 * - The tick runs at the start of game.dll's frame update, where the Lua global update ran. The Lua's step ran after
 *   the updates below it in that chain, which is still before game.dll's update: the same point of the frame, so the
 *   press, the cut and the restoration land on the frames the Lua's did. (The cut is a lasting value in the pack's
 *   record, not a per-frame flag, and the press, the confirmation and the store happen in the same tick with no game
 *   code between them.)
 * - Writes: plain stores into the pack's records, each checked with vpm_writable when found (hover_settings.c).
 * - The Lua's errors (an unsupported duration mode, storage that is not writable data, a write that did not hold) stop
 *   the component at once with vpm_fail, whose stop() puts the duration back; the Lua's guard stopped after 8 in a
 *   burst. Its pause and resume around errors in the game's update, the retries of a restore after a stop and the
 *   shutdown restore are gone: HellForge does not chain the game's update, a stopped component no longer ticks, and
 *   there is no shutdown event (the record goes with the process).
 * - The status the Lua kept (waiting_for_mission, watching_hover, cancel_requested, native_descent...) is the
 *   component's status in the Mods tab, set when it changes; the first cancellation and the first restoration of the
 *   session are logged. Its developer diagnostics (CowboyBingusDiagnostics: the status, its counters and last errors in
 *   a log file) are the pack's Detailed lines (vpm_log_detail; nothing in Normal mode), each on a change only: every
 *   status change (with the game-data error), the hover pack found (id, jump-pack manager, mission type), every
 *   cancellation (pack, duration, its record created or reused and its address), why one waited (the Lua's
 *   last_settings_error) or why a press was not confirmed (the fresh snapshot's status, another key, the flight ended,
 *   the Jump released, the focus lost), every restoration, a lease that ended without a write and why, a restoration's
 *   wait when its reason changes (last_restore_error), and at each mission's end the Lua's counters (cancellations,
 *   restorations, snapshot_waits, settings_waits, restore_waits) with the last of each wait. Its `updates` count is left
 *   out: it would cost a store on every idle frame (the core counts frames). The mark's describe line: the last hover
 *   pack found, the lease, the idle gate's frames left and the counters.
 * - The mission check is the Lua's own (the mode global's active flag and type 1 .. 7), not HF_ON_MISSION_START.
 *
 * COST (calls per frame; the Lua's counts from its frame_budget pins in parentheses; reads are vpm_read, guarded plain
 * loads, where the Lua's were ReadProcessMemory; the game.dll globals the Lua read are plain loads here):
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
 * GetCurrentProcessId at start.
 * The detailed lines: idle frames unchanged (the gate returns before them); no game read and no Windows call added
 * (the press's confirmation makes the same calls, now telling why it failed). A full check with a hover pack compares
 * the pack and manager it last said (2 compares), a game-data wait counts (1 store), a restoration's wait counts and
 * compares its reason; only a frame where something changed makes the core's one global read of the Diagnostics mode
 * per line (plus, in Detailed mode, the line, at most 20 per 600 frames). The mission's end: one listener call, the
 * global read. Unmeasured in game. */
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
    /* the Lua's diagnostics counters (its log file's), for the detailed lines and the mark */
    uint32_t cancellations, snapshot_waits, settings_waits, restore_waits;
    const char* snapshot_error;  /* the last game-data wait, the last restoration's wait (string literals) */
    const char* restore_wait;
    const char* restore_logged;  /* the restoration's wait the detailed lines said last (NULL: none in this lease) */
    uint32_t seen_pack;          /* the hover pack the detailed lines said last */
    uintptr_t seen_manager;
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

/* The pack located afresh: the same pack (key) in the same flight with the Jump held. NULL when it is, else why not. */
static const char* Unconfirmed(const ChpSnapshot* snap)
{
    ChpKey key = snap->key;
    const ChpSnapshot* again = NULL;
    int reason = chp_snapshot(1, &again);
    if (reason != CHP_VALID) return kStatusNames[reason];
    if (!chp_same_key(&again->key, &key)) return "another pack, avatar or manager";
    if (!again->flight) return "the flight ended";
    if (!again->down) return "the Jump was released";
    return NULL;
}

/* A valid snapshot's pack, said when it is another than the last (detailed lines). */
static void NotePack(VpmComponent* self, const ChpSnapshot* snap)
{
    if (snap->pack == s.seen_pack && snap->manager == s.seen_manager) return;
    s.seen_pack = snap->pack;
    s.seen_manager = snap->manager;
    vpm_log_detail(self, "hover pack %u found: jump-pack manager 0x%llX, mission type %u", snap->pack,
        (unsigned long long)snap->manager, snap->mission_type);
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
    if (r == 0)
    {
        s.settings_waits++;
        vpm_log_detail(self, "cancellation not now: %s", chp_settings_wait());
        return 0;
    }
    s.cancellations++;
    if (!s.cancelled)
    {
        s.cancelled = 1;
        vpm_log(self, "cancel_requested: the hover pack's duration is cut from %.2f s to 1/1024 s (its own record %s); "
            "the landing assistance stays. Only the session's first cancellation is logged.",
            (double)chp_lease_original(), chp_settings_created() ? "created" : "reused");
    }
    vpm_log_detail(self, "cancellation %u: pack %u, duration %.2f s cut to 1/1024 s in its own record (%s) at 0x%llX, "
        "jump-pack manager 0x%llX", s.cancellations, target.pack, (double)chp_lease_original(),
        chp_settings_created() ? "created" : "reused", (unsigned long long)chp_settings_record(),
        (unsigned long long)target.manager);
    return r;
}

/* A restoration that waits: counted, and said when its reason changes. */
static void RestoreWaits(VpmComponent* self, const char* why)
{
    s.restore_waits++;
    s.restore_wait = why;
    if (why == s.restore_logged) return;
    s.restore_logged = why;
    vpm_log_detail(self, "restoration waits: %s (the lease is kept)", why);
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
    if (r == 0)
    {
        RestoreWaits(self, why);
        return 0;
    }
    s.restore_logged = NULL;
    int wrote = chp_settings_restorations() > before;
    if (wrote && !s.restored)
    {
        s.restored = 1;
        vpm_log(self, "restored: the hover pack's duration is %.2f s again. Only the session's first restoration is logged.",
            (double)chp_lease_original());
    }
    if (wrote)
        vpm_log_detail(self, "restoration %d: the duration is %.2f s again", chp_settings_restorations(),
            (double)chp_lease_original());
    else vpm_log_detail(self, "lease ended without a write: %s", chp_settings_outcome());
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
    const char* why = Focused() ? Unconfirmed(snap) : "the game lost focus";
    int r = why == NULL ? Cancel(self) : 0;
    if (r == RAISED) return RAISED;
    if (r == 0)
    {
        if (why != NULL) vpm_log_detail(self, "press not confirmed: %s", why);
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
    NotePack(self, snap);
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
    vpm_log_detail(self, "status: %s%s%s", kStatusNames[status], error != NULL ? ": " : "", error != NULL ? error : "");
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
    if (status == CHP_WAITING_FOR_GAME_DATA)
    {
        s.snapshot_waits++;
        s.snapshot_error = chp_snapshot_error();
    }
    Arm(status);
    Show(self, status);
}

/* The Lua's diagnostics counters (its log file's), at each mission's end: a detailed line. */
static void MissionEnd(VpmComponent* self, const HfEventInfo* event)
{
    vpm_log_detail(self, "mission end: %s; cancellations=%u restorations=%d snapshot_waits=%u settings_waits=%u "
        "restore_waits=%u; last game-data wait: %s; last settings wait: %s; last restoration wait: %s",
        vpm_status(self), s.cancellations, chp_settings_restorations(), s.snapshot_waits, s.settings_waits, s.restore_waits,
        s.snapshot_error != NULL ? s.snapshot_error : "none", chp_settings_wait(),
        s.restore_wait != NULL ? s.restore_wait : "none");
}

/* The key state for a tester's mark: the status, the pack followed, the lease, the counters. */
static void Describe(VpmComponent* self, char* out, size_t size)
{
    char pack[64] = "none", lease[64] = "none";
    if (s.seen_pack != 0 || s.seen_manager != 0)
        snprintf(pack, sizeof pack, "%u (manager 0x%llX)", s.seen_pack, (unsigned long long)s.seen_manager);
    if (chp_lease_held())
        snprintf(lease, sizeof lease, "held (%.2f s cut, record %s)", (double)chp_lease_original(),
            chp_settings_created() ? "created" : "reused");
    snprintf(out, size, "last hover pack %s; lease %s; idle frames left %d; cancellations=%u restorations=%d "
        "snapshot_waits=%u settings_waits=%u restore_waits=%u", pack, lease, s.idle_left, s.cancellations,
        chp_settings_restorations(), s.snapshot_waits, s.settings_waits, s.restore_waits);
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
    if (!vpm_listen(self, HF_ON_MISSION_END, MissionEnd, 0)) vpm_log(self, "no counters at a mission's end");
    return 0;
}

const VpmComponentDef vpm_component_controllable_hover_pack = {"controllable_hover_pack", "Controllable Hover Pack", "1.8.1", 0, Start,
    Stop, Describe};
