/* Sentry Aim Retention: the aim hold (aim_data.lua's M.step, M.release and stop_aim).
 *
 * A sentry tracking a synchronized target has its aim recorded. Once that target is lost (and the sentry is not
 * scanning), the hold sets the targeting control flag's retention bit through the game's setter (the engine then skips
 * its target-source prepass and fallback path; the AI keeps running), zeroes both turn speeds through their setters,
 * and writes the recorded raw and computed aim back. Every control is journaled in the lease before its setter runs. The
 * hold ends when the sentry tracks or scans again, is disabled, or the engine changed its speeds or flags; the release
 * restores only what is still this module's: a speed still at zero gets the saved speed, the retention bit is cleared
 * while set, and an unfinished hold's aim writes are rolled back while the aim is still ours. */
#include <string.h>
#include "sentry_aim.h"

static const uint8_t kZero[12] = {0};

static int Fail(const char** why, const char* text) { *why = text; return 0; }

static int ReadEquals(uintptr_t address, const void* bytes, size_t size)
{
    uint8_t now[12];
    return size <= sizeof now && sar_load(address, now, size) && memcmp(now, bytes, size) == 0;
}

static int ReadU32Equals(uintptr_t address, uint32_t value) { return ReadEquals(address, &value, 4); }

/* A plain store. checked: the caller verified the range this check; otherwise it is checked first (api.write). */
static int Store(uintptr_t address, const void* bytes, size_t size, int checked)
{
    if (!checked && !sar_writable(address, size)) return 0;
    memcpy((void*)address, bytes, size);
    return 1;
}

SarAimRecord* sar_aim_record(uint32_t id)
{
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
        if (sar_state.records[k].used && sar_state.records[k].id == id) return &sar_state.records[k];
    return NULL;
}

static SarAimRecord* NewRecord(uint32_t id)
{
    SarAimRecord* r = sar_aim_record(id);
    for (int k = 0; r == NULL && k < SAR_MAX_RECORDS; k++)
        if (!sar_state.records[k].used) r = &sar_state.records[k];
    if (r == NULL) return NULL;
    memset(r, 0, sizeof *r);
    r->used = 1;
    r->id = id;
    return r;
}

/* The control memory a hold changes is private read-write data. */
static int Writable(const SarRow* s)
{
    return sar_writable(s->flags_address, 4) && sar_writable(s->raw_address, 24) && sar_writable(s->control_address + 8, 8);
}

static int Same(const SarRow* a, const SarRow* b)
{
    return memcmp(a->key, b->key, 20) == 0 && a->flags_address == b->flags_address && a->control_address == b->control_address &&
        a->raw_address == b->raw_address;
}

/* ---- the release ------------------------------------------------------------------------------------------------- */

/* Whether a lease may be restored: the same entity, this machine still controls it, and its control memory is private
 * read-write data. 1 decided (*restored, *why): a removed or moved entity owns no lease here, never follow an old slot. */
static int ReleaseGate(const SarRow* s, int* restored, const char** why)
{
    uint8_t flags;
    *restored = 1;
    if (!sar_matches(s->guards, s->guard_count)) { *why = "retired"; return 1; }
    if (s->authority_address && (!sar_load(s->authority_address, &flags, 1) || (flags & 1) == 0))
    {
        *why = "authority_changed";
        return 1;
    }
    if (Writable(s)) return 0;
    *restored = 0;
    *why = "restore_memory_unavailable";
    return 1;
}

/* Whether current holds our write, whole or cut short at any byte. */
static int Owned(const uint8_t* current, const SarAimWrite* w)
{
    for (int cut = 0; cut <= 12; cut++)
        if (memcmp(current, w->after, (size_t)cut) == 0 && memcmp(current + cut, w->before + cut, (size_t)(12 - cut)) == 0) return 1;
    return 0;
}

/* Rolls back the aim writes of a hold that did not complete. A derived aim the engine changed is no longer ours. */
static int RollbackAim(const SarLease* lease, const SarRow* s)
{
    int restored = 1;
    for (int k = 0; k < lease->writes; k++)
    {
        const SarAimWrite* w = &lease->aim[k];
        uint8_t current[12];
        if (!sar_load(w->address, current, 12)) { restored = 0; continue; }
        if (!Owned(current, w) || memcmp(current, w->before, 12) == 0) continue;
        /* The release checked raw_address .. +24 just before: a write inside it needs no query of its own. */
        int checked = w->address >= s->raw_address && w->address + 12 <= s->raw_address + 24;
        if (!Store(w->address, w->before, 12, checked) || !ReadEquals(w->address, w->before, 12)) restored = 0;
    }
    return restored;
}

/* Restores a turn speed still at our zero; a speed native behavior or another mod changed is not overwritten. */
static int ReleaseAxis(int* owned, const SarRow* s, uint32_t offset, SarSpeedFn setter, const uint8_t saved[4])
{
    uint8_t current[4];
    float speed;
    if (!*owned) return 1;
    if (!sar_load(s->control_address + offset, current, 4)) return 0;
    if (memcmp(current, kZero, 4) == 0)
    {
        memcpy(&speed, saved, 4);
        setter((void*)s->entity, speed);
        if (!ReadEquals(s->control_address + offset, saved, 4)) return 0;
    }
    *owned = 0;
    return 1;
}

/* Clears the retention bit while it is still set. */
static int ReleaseFlag(SarLease* lease, const SarRow* s)
{
    uint8_t current[4];
    if (!sar_load(s->flags_address, current, 4)) return 0;
    uint32_t flags = sar_u32(current);
    if (flags & 2u)
    {
        sar_natives()->retention(NULL, s->id, 2, 0);
        if (!ReadU32Equals(s->flags_address, flags & ~2u)) return 0;
    }
    lease->flag = 0;
    return 1;
}

int sar_aim_release(SarLease* lease, const char** why)
{
    const SarRow* s = &lease->held;
    int restored;
    if (ReleaseGate(s, &restored, why)) return restored;
    restored = 1;
    if (!lease->completed) restored = RollbackAim(lease, s);
    if (!ReleaseAxis(&lease->horizontal, s, 8, sar_natives()->horizontal, s->horizontal)) restored = 0;
    if (!ReleaseAxis(&lease->vertical, s, 12, sar_natives()->vertical, s->vertical)) restored = 0;
    if (lease->flag && !ReleaseFlag(lease, s)) restored = 0;
    *why = restored ? "restored" : "restore_incomplete";
    return restored;
}

/* ---- the hold ---------------------------------------------------------------------------------------------------- */

/* A hold may start: no native disable bit, unchanged identity and transition state, and this machine controls it. NULL,
 * or why not. */
static const char* MayHold(const SarRow* s)
{
    uint8_t flags;
    if (s->flags != 0) return "a native disable bit is set";
    if (!sar_matches(s->guards, s->guard_count)) return "its identity changed";
    if (!sar_matches(s->transition, s->transition_count)) return "its transition state changed";
    if (s->authority_address && !(sar_load(s->authority_address, &flags, 1) && (flags & 3) == 1))
        return "this machine no longer controls it";
    return NULL;
}

/* The retention bit first, then both turn speeds to zero, each journaled before its setter runs. */
static int HoldControls(const SarRow* s, SarLease* lease, const char** why)
{
    const SarNatives* n = sar_natives();
    n->retention(NULL, s->id, 2, 1);
    if (!ReadU32Equals(s->flags_address, 2)) return Fail(why, "hold_flag_failed");
    lease->horizontal = 1;
    n->horizontal((void*)s->entity, 0.0f);
    if (!ReadEquals(s->control_address + 8, kZero, 4)) return Fail(why, "hold_speed_failed");
    lease->vertical = 1;
    n->vertical((void*)s->entity, 0.0f);
    if (!ReadEquals(s->control_address + 12, kZero, 4)) return Fail(why, "hold_speed_failed");
    return 1;
}

/* The recorded aim into both aim fields, each journaled before its write. The hold's Writable() verified raw_address ..
 * +24 in this check, which holds both (computed_address is raw_address + 12). */
static int HoldAim(const SarRow* s, const SarAimRecord* r, SarLease* lease, const char** why)
{
    SarAimWrite* raw = &lease->aim[lease->writes++];
    raw->address = s->raw_address;
    memcpy(raw->before, s->raw, 12);
    memcpy(raw->after, r->raw, 12);
    if (!Store(raw->address, raw->after, 12, 1)) return Fail(why, "hold_aim_failed");
    SarAimWrite* computed = &lease->aim[lease->writes++];
    computed->address = s->computed_address;
    memcpy(computed->before, s->computed, 12);
    memcpy(computed->after, r->computed, 12);
    if (!Store(computed->address, computed->after, 12, 1)) return Fail(why, "hold_aim_failed");
    if (!ReadEquals(s->raw_address, r->raw, 12) || !ReadEquals(s->computed_address, r->computed, 12))
        return Fail(why, "hold_aim_verify_failed");
    return 1;
}

/* 1 holding or busy, 0 failed. The lease keeps its own copy of the row: the hold must keep the speeds it saved here. */
static int Acquire(const SarRow* s, SarAimRecord* r, const char** why)
{
    const char* refused = MayHold(s);
    if (refused != NULL)
    {
        if (!r->refusal_said)
            vpm_log_detail(sar_state.self, "%s sentry %u lost its target on node %u: no hold, %s (flags %X)", s->profile->name,
                s->id, s->node, refused, s->flags);
        r->refusal_said = 1;
        return 1;
    }
    if (!Writable(s)) return Fail(why, "hold_memory_unavailable");
    SarLease* lease = &r->lease;
    memset(lease, 0, sizeof *lease);
    lease->active = 1;
    lease->held = *s;
    lease->flag = 1;
    if (!HoldControls(s, lease, why)) return 0;
    int late = memcmp(s->raw, r->raw, 12) != 0;
    if (late) sar_state.late_aim++;
    if (!HoldAim(s, r, lease, why)) return 0;
    sar_state.holds++;
    lease->completed = 1;
    vpm_log_detail(sar_state.self, "%s sentry %u lost its target on node %u: aim held at %.2f %.2f %.2f%s", s->profile->name,
        s->id, s->node, (double)sar_f32(r->raw), (double)sar_f32(r->raw + 4), (double)sar_f32(r->raw + 8),
        late ? " (its aim had moved on since the record: put back)" : "");
    return 1;
}

/* A hash-table replacement alone invalidates the old guards and must not retire a live hold without restoring its
 * controls: the lease follows the fresh row; the saved turn speeds stay. */
static void Relocate(SarLease* lease, const SarRow* s)
{
    uint8_t horizontal[4], vertical[4];
    memcpy(horizontal, lease->held.horizontal, 4);
    memcpy(vertical, lease->held.vertical, 4);
    lease->held = *s;
    memcpy(lease->held.horizontal, horizontal, 4);
    memcpy(lease->held.vertical, vertical, 4);
}

/* The aim record of a row: the same instance keeps it; another instance elsewhere releases it first. */
static int RecordFor(const SarRow* s, SarAimRecord** out, const char** why)
{
    SarAimRecord* r = sar_aim_record(s->id);
    *out = NULL;
    if (r != NULL && memcmp(r->snapshot.key, s->key, 20) == 0)
    {
        if (r->lease.active) Relocate(&r->lease, s);
        r->snapshot = *s;
    }
    else if (r != NULL && !Same(&r->snapshot, s))
    {
        if (r->lease.active)
            vpm_log_detail(sar_state.self, "sentry %u: another instance under its id: its hold is released", s->id);
        if (r->lease.active && !sar_aim_release(&r->lease, why)) return 0;
        r->used = 0;
        r = NULL;
    }
    *out = r;
    return 1;
}

/* A hold ends when the sentry tracks or scans again, is disabled, or its speeds or other disable bits changed. It also
 * ends when the engine reclaimed targeting (cleared the retention bit): restore and wait for a fresh target. */
static int HoldEnded(const SarRow* s, int tracking, int scan)
{
    if (tracking || scan || !s->enabled || memcmp(s->horizontal, kZero, 4) != 0 || memcmp(s->vertical, kZero, 4) != 0 ||
        (s->flags & ~2u) != 0)
        return 1;
    return (s->flags & 2u) == 0;
}

/* Why HoldEnded said so, for the detailed line. */
static const char* EndReason(const SarRow* s, int tracking, int scan)
{
    if (tracking) return "it tracks a target again";
    if (scan) return "it scans again";
    if (!s->enabled) return "it was disabled";
    if (memcmp(s->horizontal, kZero, 4) != 0 || memcmp(s->vertical, kZero, 4) != 0) return "its turn speeds changed";
    if ((s->flags & ~2u) != 0) return "another disable bit is set";
    return "the engine reclaimed targeting";
}

static int ReleaseHold(SarAimRecord* r, const char* reason, const char** why)
{
    if (!sar_aim_release(&r->lease, why)) return 0;
    vpm_log_detail(sar_state.self, "%s sentry %u: hold released, %s (%s)", r->snapshot.profile->name, r->id, reason, *why);
    r->lease.active = 0;
    r->has_raw = 0;
    r->refusal_said = 0;
    sar_state.releases++;
    return 1;
}

/* Records the aim of a synchronized target, or holds it once that target is lost (a scan forgets it instead). */
static int TrackOrHold(const SarRow* s, SarAimRecord** record, int tracking, int scan, const char** why)
{
    SarAimRecord* r = *record;
    if (tracking && !(r != NULL && r->lease.active) && s->flags == 0 && s->runtime_target == s->target)
    {
        r = NewRecord(s->id);
        if (r == NULL) return Fail(why, "Too many sentries");
        r->snapshot = *s;
        r->node = s->node;
        memcpy(r->source_point, s->point, 12);
        r->has_raw = 1;
        memcpy(r->raw, s->raw, 12);
        memcpy(r->computed, s->computed, 12);
        *record = r;
    }
    else if (r != NULL && r->has_raw && !r->lease.active && !tracking && s->enabled)
    {
        if (scan) r->refusal_said = 0;
        if (scan) r->has_raw = 0;
        else if (!Acquire(s, r, why)) return 0;
    }
    return 1;
}

static int Nonzero(const uint8_t point[12])
{
    return sar_f32(point) != 0 || sar_f32(point + 4) != 0 || sar_f32(point + 8) != 0;
}

/* A non-target point on another node is scanning; a dead target's point on the firing node and a zero point (the
 * observed transition placeholder) are not. */
static int Scanning(const SarRow* s, const SarAimRecord* r)
{
    return r != NULL && s->has && s->target == 0 && (s->source_flags & 32u) != 0 && s->node != r->node && Nonzero(s->point) &&
        memcmp(s->point, r->source_point, 12) != 0;
}

/* One aim row: its record (or NULL), or 0 with *why. */
static int AimRow(const SarRow* s, SarAimRecord** out, const char** why)
{
    SarAimRecord* r;
    if (!RecordFor(s, &r, why)) return 0;
    int tracking = s->enabled && s->has && s->target != 0 && (s->source_flags & 1u) != 0;
    int scan = Scanning(s, r);
    if (r != NULL && r->lease.active && HoldEnded(s, tracking, scan) && !ReleaseHold(r, EndReason(s, tracking, scan), why))
        return 0;
    if (!TrackOrHold(s, &r, tracking, scan, why)) return 0;
    *out = r;
    return 1;
}

static int ReleaseUnseen(uint32_t stamp, const char** why)
{
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
    {
        SarAimRecord* r = &sar_state.records[k];
        if (!r->used || r->seen == stamp) continue;
        if (r->lease.active && !sar_aim_release(&r->lease, why)) return 0;
        if (r->lease.active) vpm_log_detail(sar_state.self, "sentry %u is gone: its hold is released (%s)", r->id, *why);
        r->used = 0;
    }
    return 1;
}

int sar_aim_step(SarRow* const* rows, int count, const char** why)
{
    uint32_t holding = 0, stamp = ++sar_state.aim_stamp;
    sar_state.observed = (uint32_t)count;
    for (int i = 0; i < count; i++)
    {
        SarAimRecord* r = NULL;
        if (!AimRow(rows[i], &r, why)) return 0;
        if (r == NULL) continue;
        r->seen = stamp;
        if (r->lease.active) holding++;
    }
    if (!ReleaseUnseen(stamp, why)) return 0;
    sar_state.holding = holding;
    return 1;
}

int sar_aim_stop(void)
{
    int ok = 1;
    for (int k = 0; k < SAR_MAX_RECORDS; k++)
    {
        SarAimRecord* r = &sar_state.records[k];
        const char* why;
        if (!r->used) continue;
        if (!r->lease.active || sar_aim_release(&r->lease, &why)) r->used = 0;
        else ok = 0;
    }
    return ok;
}
