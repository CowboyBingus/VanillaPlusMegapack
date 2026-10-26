/* Sentry Aim Retention: the shot permission gate and the target search after a loss, for Gatling and machine gun
 * sentries (aim_data.lua's M.fire_step, M.selection_step, M.release_fire, M.release_selection and stop_fire).
 *
 * The gate sets the weapon's replicated fire mode to FireMode_None through the game's setter while a sentry turns
 * broadly (aim more than 16 degrees off its target for a Gatling, 14 for a machine gun, or a firing sweep unsettled for
 * 200 ms), has no synchronized target, or its target point is behind static terrain; targeting, the AI trigger and the
 * spin-up keep running. Fire resumes after 60 ms of aim settled within 4 (3) degrees, or at once for a close replacement
 * target with a fresh clear ray. After a target loss on the firing node, the pending native target search deadline
 * (behavior + 152, microseconds) is shortened once, at least 100 ms after the last request. Only the no-fire mode and
 * the deadline this module wrote are ever put back. */
#include <math.h>
#include <string.h>
#include "sentry_aim.h"

#define SETTLE_SECONDS 0.06
#define SWEEP_SECONDS 0.20
#define RESELECTION_SECONDS 0.10

static const uint8_t kZero[8] = {0};

static int Fail(const char** why, const char* text) { *why = text; return 0; }

static int ReadEquals(uintptr_t address, const void* bytes, size_t size)
{
    uint8_t now[8];
    return size <= sizeof now && sar_load(address, now, size) && memcmp(now, bytes, size) == 0;
}

SarFireRecord* sar_fire_record(uint32_t id)
{
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
        if (sar_state.fire_records[k].used && sar_state.fire_records[k].id == id) return &sar_state.fire_records[k];
    return NULL;
}

static SarFireRecord* NewFireRecord(uint32_t id)
{
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
    {
        SarFireRecord* r = &sar_state.fire_records[k];
        if (r->used) continue;
        memset(r, 0, sizeof *r);
        r->used = 1;
        r->id = id;
        r->terrain_blocked = SAR_UNKNOWN;
        return r;
    }
    return NULL;
}

/* The same entity and fire guards, and this machine still controls it. */
static int FireIdentity(const SarRow* s)
{
    uint8_t authority = 0;
    int read = s->authority_address ? sar_load(s->authority_address, &authority, 1) : 1;
    if (!sar_matches(s->guards, s->guard_count) || !sar_matches(s->fire.guards, s->fire.guard_count)) return 0;
    return !s->authority_address || (read && (authority & 3) == 1);
}

/* ---- releases ---------------------------------------------------------------------------------------------------- */

static int Mixed(const uint8_t* current, const uint8_t* after, const uint8_t* before, int cut)
{
    return memcmp(current, after, (size_t)cut) == 0 && memcmp(current + cut, before + cut, (size_t)(8 - cut)) == 0;
}

int sar_release_selection(const SarFireRecord* r)
{
    const SarRow* s = &r->snapshot;
    uint32_t firing = SAR_FIRING_NODE;
    uint8_t current[8];
    if (!FireIdentity(s) || !sar_matches(&s->selection.guard, 1) || !ReadEquals(s->behavior_address + 8, &firing, 4)) return 1;
    if (!sar_load(s->selection.address, current, 8)) return 0;
    int ours = memcmp(current, r->after, 8) == 0;
    for (int cut = 0; !r->completed && !ours && cut <= 8; cut++) ours = Mixed(current, r->after, r->before, cut);
    /* The native handler consumes the request by setting its own new deadline. */
    if (!ours || memcmp(current, r->before, 8) == 0) return 1;
    if (!sar_writable(s->selection.address, 8)) return 0;
    memcpy((void*)s->selection.address, r->before, 8);
    return ReadEquals(s->selection.address, r->before, 8);
}

/* Restores only the no-fire mode this module set. */
int sar_release_fire(const SarFireRecord* r)
{
    const SarRow* s = &r->snapshot;
    uint8_t current[4];
    if (!FireIdentity(s)) return 1;
    if (!sar_load(s->fire.mode_address, current, 4)) return 0;
    if (memcmp(current, kZero, 4) != 0) return 1;
    if (!sar_writable(s->fire.mode_address, 4)) return 0;
    sar_natives()->fire_mode((void*)s->fire.manager, s->id, r->mode);
    return ReadEquals(s->fire.mode_address, &r->mode, 4);
}

/* A record's pending search request, then its no-fire mode. */
static int ReleaseFireRecord(const SarFireRecord* r, const char** why)
{
    if (r->requested && !sar_release_selection(r)) return Fail(why, "selection_restore_failed");
    if (r->paused && !sar_release_fire(r)) return Fail(why, "fire_restore_failed");
    return 1;
}

int sar_fire_stop(void)
{
    int ok = 1;
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
    {
        SarFireRecord* r = &sar_state.fire_records[k];
        if (!r->used) continue;
        int selection = !r->requested || sar_release_selection(r);
        int fire = !r->paused || sar_release_fire(r);
        if (selection && fire) r->used = 0;
        else ok = 0;
    }
    return ok;
}

/* ---- the target search request ----------------------------------------------------------------------------------- */

/* A pending request is released once the sentry tracks again, leaves the firing node or is disabled, and forgotten once
 * the native handler replaced the deadline. */
static int FollowSelection(SarFireRecord* r, const SarRow* s, int tracking, const char** why)
{
    uint8_t current[8];
    if (tracking || !s->enabled || s->node != SAR_FIRING_NODE)
    {
        if (!sar_release_selection(r)) return Fail(why, "selection_restore_failed");
        r->requested = 0;
        return 1;
    }
    if (!sar_load(s->selection.address, current, 8)) return Fail(why, "selection_read_failed");
    if (memcmp(current, r->after, 8) != 0) r->requested = 0;
    return 1;
}

/* The new deadline after a loss on the firing node: 1 (*due), 0 when the pending one is not within a second or no retry
 * is due. Retries are bounded when native perception keeps offering a target that is invalidated at once. */
static int SelectionDue(const SarFireRecord* r, const SarRow* s, double* due)
{
    uint64_t ticks;
    memcpy(&ticks, s->selection.deadline, 8);
    double deadline = (double)ticks, now = s->selection.now, remaining = deadline - now;
    *due = fmax(now, r->last_selection + RESELECTION_SECONDS * 1000000);
    return s->enabled && s->node == SAR_FIRING_NODE && !r->requested && now > 0 && now < 9007199254740991.0 && remaining > 0 &&
        remaining <= 1000000 && *due < deadline;
}

/* Only expires the pending query: native perception, scoring, range checks and target assignment still choose. */
static int RequestSelection(SarFireRecord* r, const SarRow* s, double due, const char** why)
{
    uint64_t after = (uint64_t)due;
    if (!FireIdentity(s) || !sar_matches(&s->selection.guard, 1) || !sar_matches(s->transition, s->transition_count) ||
        !ReadEquals(s->selection.address, s->selection.deadline, 8))
        return Fail(why, "selection_identity_changed");
    if (!sar_writable(s->selection.address, 8)) return Fail(why, "selection_memory_unavailable");
    r->requested = 1;
    r->completed = 0;
    memcpy(r->before, s->selection.deadline, 8);
    memcpy(r->after, &after, 8);
    memcpy((void*)s->selection.address, r->after, 8);
    if (!ReadEquals(s->selection.address, r->after, 8)) return Fail(why, "selection_request_failed");
    r->completed = 1;
    r->last_selection = due;
    sar_state.reselections++;
    return 1;
}

static int SelectionRow(const SarRow* s, const char** why)
{
    SarFireRecord* r = sar_fire_record(s->id);
    double due;
    if (r == NULL) return Fail(why, "Fire record unavailable");
    int tracking = s->enabled && s->node == SAR_FIRING_NODE && s->has && s->target != 0 && (s->source_flags & 1u) != 0;
    if (r->requested && !FollowSelection(r, s, tracking, why)) return 0;
    if (tracking) r->armed = 1;
    else if (r->armed && s->target == 0)
    {
        r->armed = 0; /* one request per observed target loss */
        if (SelectionDue(r, s, &due)) return RequestSelection(r, s, due, why);
    }
    else if (!s->enabled || s->node != SAR_FIRING_NODE) r->armed = 0;
    return 1;
}

int sar_selection_step(SarRow* const* rows, int count, const char** why)
{
    uint32_t pending = 0;
    for (int i = 0; i < count; i++)
    {
        if (!rows[i]->has_fire) continue;
        if (!SelectionRow(rows[i], why)) return 0;
        if (sar_fire_record(rows[i]->id)->requested) pending++;
    }
    sar_state.selections = pending;
    return 1;
}

/* ---- the fire gate ----------------------------------------------------------------------------------------------- */

static int Direction(double x, double y, double z, double out[3], const char** why)
{
    double length = sqrt(x * x + y * y + z * z);
    if (!(sar_finite(length) && length > 0.00001)) return Fail(why, "Invalid firing direction");
    out[0] = x / length;
    out[1] = y / length;
    out[2] = z / length;
    return 1;
}

static double Angle(const double a[3], const double b[3])
{
    double dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    return acos(fmax(-1.0, fmin(1.0, dot))) * 57.29577951308232; /* math.deg */
}

static int Vector(const uint8_t* at)
{
    return sar_finite(sar_f32(at)) && sar_finite(sar_f32(at + 4)) && sar_finite(sar_f32(at + 8));
}

int sar_fire_geometry(const SarRow* s, double forward[3], double* angle, const char** why)
{
    const uint8_t* pose = s->fire.pose;
    double aim[3];
    if (!s->fire.has_pose || !Vector(pose + 16) || !Vector(pose + 48)) return Fail(why, "Invalid muzzle pose");
    if (!Direction(sar_f32(pose + 16), sar_f32(pose + 20), sar_f32(pose + 24), forward, why)) return 0;
    if (!Direction((double)sar_f32(s->computed) - sar_f32(pose + 48), (double)sar_f32(s->computed + 4) - sar_f32(pose + 52),
            (double)sar_f32(s->computed + 8) - sar_f32(pose + 56), aim, why))
        return 0;
    *angle = Angle(forward, aim);
    return 1;
}

static void SetAnchor(SarFireRecord* r, const double forward[3])
{
    memcpy(r->anchor, forward, sizeof r->anchor);
    r->has_anchor = 1;
}

/* Clearance results belong to one target. */
static void FireTerrain(SarFireRecord* r, const SarRow* s, int synced, double now)
{
    if (!r->has_terrain_target || r->terrain_target != s->target) { r->terrain_blocked = SAR_UNKNOWN; r->has_checked = 0; }
    r->has_terrain_target = 1;
    r->terrain_target = s->target;
    if (synced && s->fire.terrain_blocked != SAR_UNKNOWN)
    {
        r->terrain_blocked = s->fire.terrain_blocked;
        r->terrain_checked_at = now;
        r->has_checked = 1;
    }
}

static int FireReason(int unavailable, int tracking, int obstructed)
{
    if (unavailable) return tracking ? SAR_REASON_AIM_PENDING : SAR_REASON_TARGET_LOST;
    return obstructed ? SAR_REASON_TERRAIN_BLOCKED : SAR_REASON_NONE;
}

/* Aim held within the resume angle for SETTLE_SECONDS moves the anchor. */
static void FireSettle(SarFireRecord* r, int aligned, const double forward[3], double now)
{
    if (!aligned) { r->has_settled = 0; return; }
    if (!r->has_settled) { r->has_settled = 1; r->settled_since = now; }
    if (now - r->settled_since >= SETTLE_SECONDS) { SetAnchor(r, forward); r->has_sweep = 0; }
}

/* Starts the firing-sweep timer on a turn away from the anchor; returns the turn in degrees. Time with shot permission
 * closed is not a continuing firing sweep. */
static double FireSweep(SarFireRecord* r, const SarRow* s, const double forward[3], int aligned, double now)
{
    double travel = Angle(r->anchor, forward);
    if (r->paused) r->has_sweep = 0;
    if (!s->fire.trigger) { SetAnchor(r, forward); r->has_sweep = 0; }
    else if (!aligned && (travel > 0.5 || (r->synced && r->error > s->fire.resume)) && !r->has_sweep)
    {
        r->has_sweep = 1;
        r->sweep_since = now;
    }
    return travel;
}

/* A broad turn: aim far off target, a wide turn with the trigger held, or a firing sweep unsettled too long. */
static int FireBroad(const SarFireRecord* r, const SarRow* s, double travel, double now)
{
    return (r->synced && r->error > s->fire.pause) || (s->fire.trigger && travel > s->fire.pause) ||
        (s->fire.trigger && r->has_sweep && now - r->sweep_since >= SWEEP_SECONDS);
}

typedef struct Assessment { double forward[3]; int tracking, unavailable, obstructed, broad, settled; } Assessment;

/* Updates the record from this check's aim. A retained direction does not imply there is still a target to shoot. */
static int Assess(SarFireRecord* r, const SarRow* s, double now, Assessment* a, const char** why)
{
    double angle;
    if (!sar_fire_geometry(s, a->forward, &angle, why)) return 0;
    r->error = angle;
    if (!r->has_anchor) SetAnchor(r, a->forward);
    a->tracking = s->enabled && s->has && s->target != 0 && (s->source_flags & 1u) != 0;
    int synced = a->tracking && s->runtime_target == s->target;
    FireTerrain(r, s, synced, now);
    a->unavailable = !synced && s->fire.trigger;
    a->obstructed = a->tracking && r->terrain_blocked == 1;
    r->reason = FireReason(a->unavailable, a->tracking, a->obstructed);
    r->synced = synced;
    r->travel = Angle(r->anchor, a->forward);
    int aligned = synced && !a->obstructed && angle <= s->fire.resume;
    FireSettle(r, aligned, a->forward, now);
    a->broad = FireBroad(r, s, FireSweep(r, s, a->forward, aligned, now), now);
    if (r->reason == SAR_REASON_NONE && a->broad) r->reason = SAR_REASON_SWEEP;
    a->settled = aligned && now - r->settled_since >= SETTLE_SECONDS;
    return 1;
}

/* Losing a target is not itself a broad turn: a close replacement with a fresh clear ray may resume at once, unless a
 * broad turn or an obstruction was seen during the pause. */
static int FireHandoff(SarFireRecord* r, const SarRow* s, int broad, int obstructed)
{
    if (r->paused && s->fire.mode != 0) r->paused = 0; /* the engine or another mod changed the mode */
    if (r->paused && (broad || obstructed)) r->handoff = 0;
    return r->paused && r->handoff && r->synced && s->fire.terrain_blocked == 0 && r->error <= s->fire.pause && !broad;
}

static int ResumeFire(SarFireRecord* r, const double forward[3], const char** why)
{
    if (!sar_release_fire(r)) return Fail(why, "fire_restore_failed");
    r->paused = 0;
    SetAnchor(r, forward);
    r->has_sweep = 0;
    sar_state.fire_resumes++;
    return 1;
}

/* Journaled before the setter runs. */
static int PauseFire(SarFireRecord* r, const SarRow* s, int handoff, const char** why)
{
    if (!FireIdentity(s) || !sar_matches(s->transition, s->transition_count)) return Fail(why, "fire_identity_changed");
    if (!sar_writable(s->fire.mode_address, 4)) return Fail(why, "fire_memory_unavailable");
    r->paused = 1;
    r->mode = s->fire.mode;
    r->handoff = handoff;
    sar_natives()->fire_mode((void*)s->fire.manager, s->id, 0);
    if (!ReadEquals(s->fire.mode_address, kZero, 4)) return Fail(why, "fire_pause_failed");
    sar_state.fire_pauses++;
    return 1;
}

/* The record of a row; another instance under the same id releases the old record first. */
static int FireRecordFor(const SarRow* s, SarFireRecord** out, const char** why)
{
    SarFireRecord* r = sar_fire_record(s->id);
    if (r != NULL && memcmp(r->snapshot.key, s->key, 20) != 0)
    {
        if (!ReleaseFireRecord(r, why)) return 0;
        r->used = 0;
        r = NULL;
    }
    if (r == NULL) r = NewFireRecord(s->id);
    if (r == NULL) return Fail(why, "Too many sentries");
    r->snapshot = *s;
    *out = r;
    return 1;
}

static int FireRow(const SarRow* s, double now, SarFireRecord** out, const char** why)
{
    SarFireRecord* r;
    Assessment a;
    if (!FireRecordFor(s, &r, why) || !Assess(r, s, now, &a, why)) return 0;
    *out = r;
    int handoff = FireHandoff(r, s, a.broad, a.obstructed);
    if (r->paused && (a.settled || handoff || (!a.tracking && !s->fire.trigger) || !s->enabled)) return ResumeFire(r, a.forward, why);
    if (!r->paused && (a.broad || a.unavailable || a.obstructed) && s->enabled && s->fire.mode != 0)
        return PauseFire(r, s, a.unavailable && !a.broad && !a.obstructed, why);
    return 1;
}

static int ReleaseUnseenFire(uint32_t stamp, const char** why)
{
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
    {
        SarFireRecord* r = &sar_state.fire_records[k];
        if (!r->used || r->seen == stamp) continue;
        if (!ReleaseFireRecord(r, why)) return 0;
        r->used = 0;
    }
    return 1;
}

int sar_fire_step(SarRow* const* rows, int count, double now, const char** why)
{
    uint32_t paused = 0, stamp = ++sar_state.fire_stamp;
    for (int i = 0; i < count; i++)
    {
        SarFireRecord* r = NULL;
        if (!rows[i]->has_fire) continue;
        if (!FireRow(rows[i], now, &r, why)) return 0;
        r->seen = stamp;
        if (r->paused) paused++;
    }
    if (!ReleaseUnseenFire(stamp, why)) return 0;
    sar_state.fire_paused = paused;
    return 1;
}
