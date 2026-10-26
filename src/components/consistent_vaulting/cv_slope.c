/* Consistent Vaulting: the bounded assistance (slope_assist.lua A.step, A.stop, A.idle).
 *
 * A fresh manual press opens a 1.25 s window. Read-only, fresh native probes (cv_assist_candidate) decide whether it
 * needs any help; ordinary candidates take priority, and nothing changes merely because the input was pressed. A
 * validated candidate arms a lease: a steep face (up to 65 degrees) gets slide entry 65, exit 60 and slope support up
 * to 65 degrees, and a walking-speed cap once native climbing starts; a higher top gets a ground climb height of 2.5
 * instead of 1.95. The lease ends on the native climb's outcome, its area (3 units), its timers or any identity or
 * settings change, and every cell it still owns goes back. Without its own settings record the avatar gets one from the
 * original AvatarComponent modifier routine (an empty modifier copies the base record into an engine-owned override).
 *
 * The idle gate: after a check that found nothing to do, the next frames are answered before any check. With the local
 * avatar found and its input released a gated frame makes one read, the input byte at the kept avatar index; outside a
 * mission or without a local avatar it makes none. A press, an unreadable input or work in progress runs the full check
 * on that frame. Every 10th frame of a mission (about 0.17 s at 60 FPS) the full check verifies the identity; outside a
 * mission every 60th looks for one. A check that raised is not gated. */
#include <math.h>
#include <string.h>
#include "cv.h"

#define GATE_MISSION 10
#define GATE_OUTSIDE 60

static CvSlope g_step;   /* this check's snapshot (handed to the vault check) */
static CvSlope g_fresh;  /* the snapshot after an override was created */
static CvSlope g_stop;   /* the restore's snapshot */
static uint8_t g_assist[CV_CELLS][4]; /* what an assist writes (the speed cap is computed) */
static double g_cosLimit; /* cos(65 degrees): the steepest supported slope */
static int g_gateFrames, g_gateDue;
static uintptr_t g_gateInput, g_gateDueInput;

static const int kSlopeCells[3] = {CV_ENTER, CV_EXIT, CV_SLOPE};
static const int kLedgeCells[1] = {CV_HEIGHT};

void cv_slope_reset(void)
{
    g_gateFrames = g_gateDue = 0;
    g_gateInput = g_gateDueInput = 0;
    g_cosLimit = cos(65 * CV_PI / 180);
    memset(g_assist, 0, sizeof g_assist);
    cv_put_f32(g_assist[CV_ENTER], 65);
    cv_put_f32(g_assist[CV_EXIT], 60);
    cv_put_f32(g_assist[CV_SLOPE], g_cosLimit);
    cv_put_f32(g_assist[CV_HEIGHT], 2.5);
}

static int Is(const char* reason, const char* text) { return reason != NULL && strcmp(reason, text) == 0; }
static int Refuse(const char** reason, const char* text) { *reason = text; return 0; }

static int Same(const CvKey* a, const CvKey* b)
{
    return a->id == b->id && a->unit == b->unit && a->ref == b->ref && a->manager == b->manager && a->owner == b->owner;
}

/* ---- restore ----------------------------------------------------------------------------------------------------- */

/* The cell holds this write's bytes, or a byte mix of a partial write (every byte from before or after). */
static int Owned(const CvLeaseWrite* w, const uint8_t* current)
{
    if (memcmp(current, w->after, 4) == 0) return 1;
    if (!(w->partial && memcmp(current, w->before, 4) != 0)) return 0;
    for (int j = 0; j < 4; j++)
        if (current[j] != w->before[j] && current[j] != w->after[j]) return 0;
    return 1;
}

/* Restores one lease write; owned angles are collected for one batch. 0 when the cell cannot be read or restored. */
static int ReleaseCell(const CvSlope* s, const CvLease* lease, const CvLeaseWrite* w, const CvLeaseWrite** angles, int* count)
{
    uintptr_t address = s->cells[w->cell];
    uint8_t current[4];
    /* A replacement mover has its own defaults: never restore into it. */
    if (w->cell == CV_SLOPE && (lease->handle != s->handle || lease->object != s->object)) address = 0;
    if (address == 0) return 1;
    if (!cv_load(address, current, 4)) return 0;
    if (!Owned(w, current)) return 1;
    if (w->cell == CV_ENTER || w->cell == CV_EXIT) { angles[(*count)++] = w; return 1; }
    return cv_write(address, w->before, 4) && cv_matches(address, w->before, 4);
}

static uint32_t AngleOffset(int cell) { return cell == CV_EXIT ? 20u : 0u; }

/* Both angles lie in one settings record (+152 and +172): one protection check; after a refusal the others are still
 * tried one by one. */
static int RestoreAngles(const CvSlope* s, const CvLeaseWrite* const* angles, int count)
{
    int restored = cv_writable(s->cells[CV_ENTER], 24);
    for (int i = restored ? 0 : 1; i < count; i++)
    {
        if (restored) cv_store(s->cells[CV_ENTER] + AngleOffset(angles[i]->cell), angles[i]->before, 4);
        else (void)cv_write(s->cells[angles[i]->cell], angles[i]->before, 4);
    }
    for (int i = 0; i < count; i++)
        if (!cv_matches(s->cells[angles[i]->cell], angles[i]->before, 4)) restored = 0;
    return restored;
}

int cv_slope_stop(CvState* st)
{
    const CvLeaseWrite* angles[4];
    int count = 0, restored = 1;
    const char* why = NULL;
    if (!st->has_lease) return 1;
    CvLease* lease = &st->lease;
    int got = cv_slope_snapshot(&g_stop, &lease->key, 0, 0, &why);
    if (got == 0 && Is(why, "gone")) { st->has_lease = 0; return 1; }
    /* Verified once before the writes: between here and them only these cells are read and written. */
    if (got != 1 || !cv_slope_guarded(&g_stop)) return 0;
    for (int i = lease->count - 1; i >= 0; i--)
        if (!ReleaseCell(&g_stop, lease, &lease->writes[i], angles, &count)) restored = 0;
    if (count > 0 && !RestoreAngles(&g_stop, angles, count)) restored = 0;
    if (restored) st->has_lease = 0;
    return restored;
}

/* Ends the assist with this status, restoring every cell it still owns. */
static int Finish(CvState* st, const char* status, const char** reason)
{
    st->slope_status = status;
    st->has_intent = 0;
    if (st->has_lease)
    {
        st->slope_last_release = status;
        if (st->lease.kind == CV_KIND_LEDGE && Is(status, "attempt_timeout")) st->counters.ledge_attempt_expiries++;
    }
    return cv_slope_stop(st) ? 1 : Refuse(reason, "slope_restore_failed");
}

/* ---- a held lease ------------------------------------------------------------------------------------------------ */

/* The snapshot still shows the lease's avatar and mover, and the bytes it wrote. */
static const char* LeaseHolds(const CvLease* lease, const CvSlope* s)
{
    if (!Same(&lease->key, &s->key) || lease->handle != s->handle || lease->object != s->object) return "identity_changed";
    for (int i = 0; i < lease->count; i++)
    {
        const CvLeaseWrite* w = &lease->writes[i];
        if (!s->has_value[w->cell] || memcmp(s->values[w->cell], w->after, 4) != 0) return "settings_changed";
    }
    return NULL;
}

/* Stable steep support has no timer that would drop a stationary player: flat ground ends it after 0.35 s, lost
 * support after 0.25 s. */
static const char* Supported(CvLease* lease, const CvSlope* s, double now)
{
    if (s->ground && s->normal_z >= g_cosLimit)
    {
        lease->has_air = 0;
        if (s->normal_z < cos(44 * CV_PI / 180))
        {
            lease->phase = CV_PHASE_SUPPORT;
            lease->has_flat = 0;
            return NULL;
        }
        if (!lease->has_flat) { lease->has_flat = 1; lease->flat_since = now; }
        return now - lease->flat_since < 0.35 ? NULL : "flat_ground";
    }
    if (!lease->has_air) { lease->has_air = 1; lease->air_since = now; }
    return now - lease->air_since < 0.25 ? NULL : "unsupported";
}

/* A.keep: decisions use actual native climbing and ground contact, walking only, inside the three-unit area. NULL keeps
 * the lease. */
static const char* Keep(CvLease* lease, const CvSlope* s, double now)
{
    if (!s->eligible) return "ineligible";
    double dx = s->root[0] - lease->anchor[0], dy = s->root[1] - lease->anchor[1], dz = s->root[2] - lease->anchor[2];
    if (dx * dx + dy * dy > 9 || fabs(dz) > 3) return "left_area";
    if (s->climbing)
    {
        if (now > lease->started + 8) return "climb_timeout";
        lease->phase = CV_PHASE_CLIMB;
        return NULL;
    }
    if (lease->phase == CV_PHASE_ATTEMPT) return now <= lease->started + 1.25 ? NULL : "attempt_timeout";
    if (lease->kind == CV_KIND_LEDGE) return "ledge_climb_finished";
    return Supported(lease, s, now);
}

/* No movement cap during detection or a rejected attempt: it applies only once this assisted attempt has entered
 * native climbing. 2 once capped, else the step's result. */
static int CapSpeed(CvState* st, const CvSlope* s, CvLease* lease, const char** reason)
{
    double cap = cv_num(s->values[CV_CAP]);
    if (!cv_finite(cap) || !cv_slope_guarded(s)) return Finish(st, "speed_cap_unavailable", reason);
    CvLeaseWrite* w = &lease->writes[lease->count++];
    w->cell = CV_CAP;
    memcpy(w->before, s->values[CV_CAP], 4);
    cv_put_f32(w->after, cap >= 0 ? fmin(cap, s->walk) : s->walk); /* a lower existing cap is respected */
    w->partial = 1;
    if (!cv_write(s->cells[CV_CAP], w->after, 4) || !cv_matches(s->cells[CV_CAP], w->after, 4))
        return Refuse(reason, cv_slope_stop(st) ? "speed_cap_write_failed" : "slope_restore_failed");
    w->partial = 0;
    lease->speed_capped = 1;
    return 2;
}

static void CountPhase(CvCounters* c, const CvLease* lease, int previous)
{
    if (lease->phase == CV_PHASE_CLIMB && previous != CV_PHASE_CLIMB)
    {
        c->slope_climbs++;
        if (lease->kind == CV_KIND_LEDGE) c->ledge_climbs++;
    }
    if (lease->phase == CV_PHASE_SUPPORT && previous != CV_PHASE_SUPPORT) c->slope_landings++;
}

static const char* PhaseName(int phase)
{
    if (phase == CV_PHASE_CLIMB) return "climb";
    return phase == CV_PHASE_SUPPORT ? "support" : "attempt";
}

/* One check of an armed lease: keep it, cap the speed once it climbs, or end it. */
static int Hold(CvState* st, const CvSlope* s, double now, const char** reason)
{
    CvLease* lease = &st->lease;
    const char* why = LeaseHolds(lease, s);
    if (why != NULL) return Finish(st, why, reason);
    int previous = lease->phase;
    why = Keep(lease, s, now);
    if (why != NULL) return Finish(st, why, reason);
    if (lease->kind == CV_KIND_SLOPE && lease->phase != CV_PHASE_ATTEMPT && !lease->speed_capped)
    {
        int capped = CapSpeed(st, s, lease, reason);
        if (capped != 2) return capped;
    }
    CountPhase(&st->counters, lease, previous);
    st->slope_status = PhaseName(lease->phase);
    return 1;
}

/* ---- arming ------------------------------------------------------------------------------------------------------- */

/* The default slide settings: 45 and 40 degrees, slope cosine of 50 degrees. */
static int DefaultSlide(const CvSlope* s)
{
    return !(s->enter != 45 || s->exit != 40 || fabs(cv_num(s->values[CV_SLOPE]) - cos(50 * CV_PI / 180)) > 0.001);
}

/* A ledge assist needs ground contact and the default ground climb height. */
static int LedgeUnfit(int kind, const CvSlope* s)
{
    return kind == CV_KIND_LEDGE && (!s->ground || fabs(s->ground_max - 1.95) > 0.001);
}

/* This check looks for a candidate: a fresh press opened a 1.25 s window for this avatar, eligible and not climbing
 * yet; at most every 0.1 s, with default slide settings and unchanged guards. */
static int CandidateDue(CvState* st, const CvSlope* s, double now, int rising)
{
    CvIntent* intent = &st->intent;
    st->slope_status = "waiting_for_manual_climb";
    if (rising)
    {
        st->has_intent = 1;
        intent->key = s->key;
        intent->deadline = now + 1.25;
        intent->has_checked = 0;
    }
    if (!s->manual || !s->eligible || s->climbing) { st->has_intent = 0; return 0; }
    if (!st->has_intent || now > intent->deadline || !Same(&intent->key, &s->key)) { st->has_intent = 0; return 0; }
    if (intent->has_checked && now - intent->checked < 0.1) return 0;
    intent->has_checked = 1;
    intent->checked = now;
    if (!DefaultSlide(s)) { st->slope_status = "custom_slope_settings_retained"; return 0; }
    return cv_slope_guarded(s);
}

#ifdef VPM_TEST
static int (*g_testCandidate)(int* kind);
void cv_test_candidate(int (*candidate)(int* kind)) { g_testCandidate = candidate; }
#endif

static int Candidate(CvState* st, const CvSlope* s, int* kind, const char** reason)
{
#ifdef VPM_TEST
    if (g_testCandidate != NULL) return g_testCandidate(kind);
#endif
    return cv_assist_candidate(st, s, kind, reason);
}

/* The assist a fresh native candidate check allows here: CV_KIND_*, 0 none, CV_RAISED. */
static int ValidatedKind(CvState* st, const CvSlope* s)
{
    int kind = 0;
    const char* reason = NULL;
    st->counters.candidate_checks++;
    int found = Candidate(st, s, &kind, &reason);
    if (found < 0) return found;
    if (found != 1 || LedgeUnfit(kind, s) || !cv_slope_guarded(s)) return 0;
    return kind;
}

/* Without its own settings record the avatar gets one from the original modifier routine; the new snapshot, while it
 * still allows this assist (1), 0, CV_RAISED. */
static int WithOverride(CvState* st, const CvSlope* s, int kind, const CvSlope** out)
{
    const char* why = NULL;
    if (s->override_count >= 8) { st->slope_status = "override_capacity_reached"; return 0; }
    CV_TRY(cv_native_ensure_override(s->manager, s->entity));
    st->counters.slope_overrides++;
    int got = cv_slope_snapshot(&g_fresh, NULL, 0, 0, &why);
    if (got < 0) return got;
    const CvSlope* fresh = &g_fresh;
    if (got == 0 || !Same(&s->key, &fresh->key) || fresh->cells[CV_ENTER] == 0 || !fresh->manual || !fresh->eligible ||
        !DefaultSlide(fresh) || LedgeUnfit(kind, fresh) || !cv_slope_guarded(fresh))
        return 0;
    *out = fresh;
    return 1;
}

/* The angles share the settings record (one protection check), the slope cosine is in the controller object, the
 * ledge height is alone; each is read back. 1, 0 failed, -1 refused before any store of a region. */
static int WriteCells(const CvSlope* s, const CvLease* lease)
{
    const CvLeaseWrite* w = lease->writes;
    if (w[0].cell == CV_ENTER)
    {
        if (!cv_writable(s->cells[CV_ENTER], 24)) return -1;
        cv_store(s->cells[CV_ENTER], w[0].after, 4);
        cv_store(s->cells[CV_ENTER] + 20, w[1].after, 4);
        if (!cv_write(s->cells[CV_SLOPE], w[2].after, 4)) return -1;
    }
    else if (!cv_write(s->cells[CV_HEIGHT], w[0].after, 4))
        return -1;
    for (int i = 0; i < lease->count; i++)
        if (!cv_matches(s->cells[w[i].cell], w[i].after, 4)) return 0;
    return 1;
}

static void NewLease(CvState* st, const CvSlope* s, int kind, double now)
{
    CvLease* lease = &st->lease;
    memset(lease, 0, sizeof *lease);
    lease->key = s->key;
    lease->handle = s->handle;
    lease->object = s->object;
    memcpy(lease->anchor, s->root, sizeof lease->anchor);
    lease->started = now;
    lease->kind = kind;
    lease->phase = CV_PHASE_ATTEMPT;
    st->has_lease = 1;
    st->has_intent = 0;
}

/* Arms the lease: every cell must still hold what the snapshot read; the guards were verified after the last native
 * call and are verified again after the writes. Every write is in the lease before the attempt: a failed one may land
 * in part, and the restore decides per cell what is ours. */
static int Arm(CvState* st, const CvSlope* s, int kind, double now, const char** reason)
{
    const int* cells = kind == CV_KIND_LEDGE ? kLedgeCells : kSlopeCells;
    int count = kind == CV_KIND_LEDGE ? 1 : 3;
    CvLease* lease = &st->lease;
    NewLease(st, s, kind, now);
    for (int i = 0; i < count; i++)
        if (!cv_matches(s->cells[cells[i]], s->values[cells[i]], 4)) return Finish(st, "slope_changed_before_commit", reason);
    for (int i = 0; i < count; i++)
    {
        CvLeaseWrite* w = &lease->writes[lease->count++];
        w->cell = cells[i];
        memcpy(w->before, s->values[cells[i]], 4);
        memcpy(w->after, g_assist[cells[i]], 4);
        w->partial = 1;
    }
    int written = WriteCells(s, lease);
    if (written < 0) return Finish(st, "slope_changed_before_commit", reason);
    if (written == 0) return Refuse(reason, cv_slope_stop(st) ? "slope_write_failed" : "slope_restore_failed");
    for (int i = 0; i < lease->count; i++) lease->writes[i].partial = 0;
    if (!cv_slope_guarded(s)) return Finish(st, "slope_changed_after_commit", reason);
    st->counters.slope_arms++;
    if (kind == CV_KIND_LEDGE) st->counters.ledge_arms++;
    st->slope_status = "attempt";
    return 1;
}

/* ---- the step ---------------------------------------------------------------------------------------------------- */

/* The local avatar was not resolved: a transition or unavailable data needs a fresh release. */
static int Unresolved(CvState* st, int resolved, const char* why, const char** reason)
{
    st->slope_down = 1;
    if (resolved)
    {
        int outside = Is(why, "outside_mission");
        st->avatar_outside = outside; /* the vault check need not read the mission again */
        g_gateDue = outside ? GATE_OUTSIDE : GATE_MISSION;
    }
    return Finish(st, resolved ? "waiting_for_avatar" : "waiting_for_slope_data", reason);
}

/* No lease and the input released: nothing else runs; the gate may read the input at this avatar index. */
static int ReleasedIdle(CvState* st)
{
    g_gateDue = GATE_MISSION;
    g_gateDueInput = cv_identity_input();
    st->slope_status = "waiting_for_manual_climb";
    st->has_intent = 0;
    return 1;
}

/* A press in its window: a validated candidate arms a lease (after creating the avatar's own settings record). */
static int Press(CvState* st, const CvSlope* s, double now, int rising, const char** reason)
{
    if (!CandidateDue(st, s, now, rising)) return 1;
    int kind = ValidatedKind(st, s);
    if (kind <= 0) return kind == 0 ? 1 : kind;
    if (s->cells[CV_ENTER] == 0)
    {
        int fresh = WithOverride(st, s, kind, &s);
        if (fresh != 1) return fresh == 0 ? 1 : fresh;
    }
    return Arm(st, s, kind, now, reason);
}

int cv_slope_step(CvState* st, const char** reason)
{
    const char* why = NULL;
    st->avatar = NULL;
    st->avatar_outside = 0;
    g_gateDue = 0;
    g_gateDueInput = 0;
    int light = !st->has_lease;
    int got = cv_slope_snapshot(&g_step, NULL, light, light && st->slope_down == 0, &why);
    if (got != 1) return Unresolved(st, got == 0, why, reason);
    if (cv_identity_renewed()) st->slope_down = 1; /* a press already held across a new identity is not a fresh one */
    const CvSlope* s = &g_step;
    st->avatar = &g_step;
    int rising = s->manual && st->slope_down == 0;
    st->slope_down = s->manual;
    if (!st->has_lease && !s->manual) return ReleasedIdle(st);
    if (st->has_lease) return Hold(st, s, st->now, reason);
    return Press(st, s, st->now, rising, reason);
}

/* lint: per-frame */
int cv_slope_idle(const CvState* st)
{
    uint8_t input = 0;
    if (g_gateFrames <= 0 || st->busy != 0) return 0;
    g_gateFrames--;
    if (g_gateInput == 0 || (vpm_read_u8(g_gateInput, &input) && input == 0)) return 1;
    g_gateFrames = 0;
    return 0;
}

void cv_slope_settle(int idle)
{
    if (idle && g_gateDue > 0)
    {
        g_gateFrames = g_gateDue - 1;
        g_gateInput = g_gateDueInput;
    }
    else
    {
        g_gateFrames = 0;
        g_gateInput = 0;
    }
}
