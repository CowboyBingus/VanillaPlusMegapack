/* Consistent Vaulting: the vault check after its snapshot (vault_data.lua M.plan, the commit and restore, the stage-2
 * plan held across checks, the stage-3 late native retry, and the vault half of M.apply).
 *
 * Every query write lies in the local controller, inside [controller, controller + 0x1E8): the phase at +4 and the ten
 * 44-byte hits from +0x30. Its protection is checked once per controller (cv_writable); writes are plain stores, each
 * read back. A commit verifies the epoch, the input and every original first; a restore writes the original bytes back
 * wherever a write is still in place, and only while the epoch holds (a consumed or reused batch is never written by a
 * stale address). */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "cv.h"

static int Accept(const char** reason, const char* text) { *reason = text; return 1; }
static int Refuse(const char** reason, const char* text) { *reason = text; return 0; }

/* A reason with the error that raised it (built only on the check that raised). */
static char g_reason[192];
static const char* WithError(const char* prefix)
{
    snprintf(g_reason, sizeof g_reason, "%s: %s", prefix, cv_error());
    return g_reason;
}

/* ---- M.plan ------------------------------------------------------------------------------------------------------ */

enum { REJECTED, ACCEPTED, FALLBACK };

/* The checks before the native ones: one hit, the surface angle, the ledge minimum and the height allowance. */
static int Screened(const CvVault* s, const CvHit* hit)
{
    double height = cv_f32(hit->position[2] - s->root[2]);
    if (hit->count != 1 || hit->unit == 0) return 0;
    if (!cv_finite(hit->normal_z) || hit->normal_z <= s->normal_threshold) return 0;
    if (s->has_min_height && height < s->min_height) return 0;
    return !(height > s->max_height);
}

/* The native exit validator, reused; a valid actor that moves is refused, one with the manual metadata veto (0x100000)
 * is only a fallback. */
static int Consider(const CvVault* s, const CvHit* hit, int have_fallback)
{
    CvActor actor;
    if (!Screened(s, hit)) return REJECTED;
    if (!cv_native_actor(hit->actor, &actor)) return cv_raise("Actor validation unavailable");
    if (!(cv_finite(actor.motion_squared) && actor.motion_squared >= 0)) return cv_raise("Invalid actor motion");
    if (actor.valid && actor.motion_squared > 1) return REJECTED;
    int veto = actor.valid && (actor.flags & 0x100000u) != 0;
    if (veto && have_fallback) return REJECTED;
    int32_t exit = cv_native_exit(s->entity, hit->position, s->direction);
    if (exit != 3 && exit != 4 && exit != 5) return cv_raise("Unsupported exit result");
    if (exit == 5) return REJECTED;
    return veto ? FALLBACK : ACCEPTED;
}

int cv_select(CvVault* s, CvSelection* selection)
{
    int chosen = -1, fallback = -1;
    if (!s->manual) return 0;
    for (int i = 0; i < s->hit_count && chosen < 0; i++)
    {
        int verdict = Consider(s, &s->hits[i], fallback >= 0);
        if (verdict == CV_RAISED) return CV_RAISED;
        if (verdict == ACCEPTED) chosen = i;
        else if (verdict == FALLBACK) fallback = i;
    }
    selection->metadata = chosen < 0 && fallback >= 0;
    selection->slot = chosen >= 0 ? chosen : fallback;
    return selection->slot >= 0;
}

static void AddWrite(CvWrite* writes, int* count, uintptr_t address, const uint8_t* before, const uint8_t* after, uint32_t size)
{
    CvWrite* w = &writes[(*count)++];
    w->address = address;
    w->size = size;
    memcpy(w->before, before, size);
    memcpy(w->after, after, size);
}

/* The chosen hit exposed (its actor cleared for a metadata fallback), every usable earlier slot's unit cleared. */
static int PlanWrites(const CvVault* s, const CvSelection* selection, CvWrite* writes)
{
    int count = 0;
    for (int i = 0; i < s->hit_count; i++)
    {
        const CvHit* hit = &s->hits[i];
        uint8_t replacement[8];
        memcpy(replacement, hit->bytes + 28, 8);
        if (i == selection->slot && selection->metadata) cv_pair(replacement, hit->unit, CV_INVALID);
        else if (i < selection->slot && hit->count == 1 && hit->unit != 0) cv_pair(replacement, 0, hit->actor);
        if (memcmp(replacement, hit->bytes + 28, 8) != 0) AddWrite(writes, &count, hit->address + 28, hit->bytes + 28, replacement, 8);
    }
    return count;
}

/* ---- commit and restore ------------------------------------------------------------------------------------------ */

enum { COMMIT_OK, COMMIT_CHANGED, COMMIT_WRITE, COMMIT_RESTORE };

int cv_same_epoch(const CvVault* s) { return cv_guards_hold(&s->guards, 1); }

static const uint8_t* Field(const CvWrite* w, int after) { return after ? w->after : w->before; }

/* The first write whose bytes in memory differ from its field, or -1. */
static int FirstMismatch(const CvWrite* writes, int count, int after)
{
    for (int i = 0; i < count; i++)
        if (!cv_matches(writes[i].address, Field(&writes[i], after), writes[i].size)) return i;
    return -1;
}

/* One protection check for the controller span, then the stores: the number that landed, or -1 refused. */
static int WriteController(uintptr_t controller, const CvWrite* writes, int count, int after)
{
    if (!cv_writable(controller, CV_CONTROLLER_SPAN)) return -1;
    for (int i = 0; i < count; i++)
    {
        if (writes[i].address < controller || writes[i].address + writes[i].size > controller + CV_CONTROLLER_SPAN) return i;
        cv_store(writes[i].address, Field(&writes[i], after), writes[i].size);
    }
    return count;
}

/* Writes the original bytes back wherever a write is still in place, and reads each back. */
static int RestoreInPlace(const CvPending* pending)
{
    CvWrite back[CV_MAX_WRITES];
    int count = 0;
    for (int i = pending->count - 1; i >= 0; i--)
        if (cv_matches(pending->writes[i].address, pending->writes[i].after, pending->writes[i].size)) back[count++] = pending->writes[i];
    if (count == 0) return 1;
    return WriteController(pending->snapshot->controller, back, count, 0) == count && FirstMismatch(back, count, 0) < 0;
}

int cv_restore(const CvPending* pending)
{
    if (pending == NULL || !cv_same_epoch(pending->snapshot)) return 1;
    return RestoreInPlace(pending);
}

/* A store that did not hold may have landed in part: a byte mix of the original and the new bytes is ours to undo.
 * 0 only when undoing it failed. */
static int UndoPartial(const CvVault* s, const CvWrite* w)
{
    uint8_t current[CV_HIT_SIZE];
    if (!cv_load(w->address, current, w->size) || memcmp(current, w->before, w->size) == 0 ||
        memcmp(current, w->after, w->size) == 0 || !cv_same_epoch(s))
        return 1;
    for (uint32_t j = 0; j < w->size; j++)
        if (current[j] != w->before[j] && current[j] != w->after[j]) return 1;
    return cv_write(w->address, w->before, w->size) && cv_matches(w->address, w->before, w->size);
}

/* The epoch, the input and every original verified, then the stores, each read back. pending gets every write before
 * the attempt, so a rollback can undo any of them. */
static int Commit(const CvVault* s, CvPending* pending, const CvWrite* writes, int count)
{
    if (!cv_same_epoch(s) || !cv_matches(s->input_address, &s->manual_bytes, 1) || FirstMismatch(writes, count, 0) >= 0)
        return COMMIT_CHANGED;
    for (int i = 0; i < count && pending->count < CV_MAX_WRITES; i++) pending->writes[pending->count++] = writes[i];
    int landed = WriteController(s->controller, writes, count, 1);
    if (landed < 0) return COMMIT_CHANGED;
    int failed = landed < count ? landed : FirstMismatch(writes, count, 1);
    if (failed < 0) return COMMIT_OK;
    return UndoPartial(s, &writes[failed]) ? COMMIT_WRITE : COMMIT_RESTORE;
}

static CvPending* StartPending(CvState* st, CvVault* s)
{
    st->pending.snapshot = s;
    st->pending.count = 0;
    return &st->pending;
}

/* ---- stage 2: a plan held across checks -------------------------------------------------------------------------- */

static int Prepared(CvState* st, const CvSelection* selection, const char** reason)
{
    st->has_pending = 1;
    st->counters.prepared++;
    if (selection->metadata) st->counters.metadata_fallbacks++;
    return Accept(reason, selection->metadata ? "local_manual_metadata_fallback_prepared" : "local_manual_alternative_prepared");
}

/* A new stage-2 plan: guards verified, one batch, the epoch and the input verified again after it. */
static int Prepare(CvState* st, CvVault* s, const CvWrite* writes, int count, const CvSelection* selection, const char** reason)
{
    if (!cv_guards_hold(&s->guards, 0)) return Accept(reason, "query_changed_before_commit");
    CvPending* pending = StartPending(st, s);
    int failure = Commit(s, pending, writes, count);
    if (failure != COMMIT_OK)
    {
        int restored = cv_restore(pending);
        if (failure == COMMIT_CHANGED)
            return restored ? Accept(reason, "query_changed_before_commit") : Refuse(reason, "query_restore_failed");
        return Refuse(reason, restored && failure == COMMIT_WRITE ? "query_write_failed" : "query_restore_failed");
    }
    if (!cv_same_epoch(s) || !cv_matches(s->input_address, &s->manual_bytes, 1))
    {
        int restored = cv_restore(pending);
        return restored ? Accept(reason, "query_changed_after_commit") : Refuse(reason, "query_restore_failed");
    }
    return Prepared(st, selection, reason);
}

/* This check would prepare exactly the held writes from unchanged data: they stay, with no restore, no write and no
 * protection check. The snapshot has just read every guard; the held writes and the input are read again. */
static int Keeps(const CvVault* s, const CvPending* held, const CvWrite* writes, int count)
{
    if (count != held->count) return 0;
    for (int i = 0; i < count; i++)
    {
        const CvWrite* w = &writes[i];
        const CvWrite* h = &held->writes[i];
        if (w->address != h->address || w->size != h->size || memcmp(w->before, h->before, w->size) != 0 ||
            memcmp(w->after, h->after, w->size) != 0)
            return 0;
    }
    if (FirstMismatch(held->writes, held->count, 1) >= 0) return 0;
    return cv_matches(s->input_address, &s->manual_bytes, 1);
}

/* Restores the held writes still in place (the epoch was confirmed this check). */
static int Release(CvState* st, const CvPending* held)
{
    if (!RestoreInPlace(held)) return 0;
    st->has_pending = 0;
    return 1;
}

static int PlanBatch(CvState* st, CvVault* s, const CvPending* held, const char** reason)
{
    CvWrite writes[CV_MAX_WRITES];
    CvSelection selection = {-1, 0};
    int count = 0, planned = cv_select(s, &selection);
    if (planned == 1) count = PlanWrites(s, &selection, writes);
    if (held != NULL)
    {
        if (planned >= 0 && Keeps(s, held, writes, count))
        {
            st->pending.snapshot = s;
            return Prepared(st, &selection, reason);
        }
        if (!Release(st, held)) return Refuse(reason, "query_restore_failed");
    }
    if (planned < 0) return Refuse(reason, WithError("validation_failed"));
    if (count == 0) return Accept(reason, "native_vault_checks_retained");
    return Prepare(st, s, writes, count, &selection, reason);
}

/* ---- stage 3: the late native retry ------------------------------------------------------------------------------ */

int cv_out_of_reach(const CvVault* s, const CvHit* hit)
{
    double dx = hit->position[0] - s->root[0], dy = hit->position[1] - s->root[1];
    return dx * dx + dy * dy > 2.25 || dx * s->direction[0] + dy * s->direction[1] < -0.15;
}

int cv_context_still(const CvVault* s)
{
    static uint8_t fresh[CV_CONTROLLER_SIZE];
    return cv_native_context(s->controller_bytes, fresh) == CV_APPROACH_MATCHED;
}

/* The chosen fresh hit (its actor cleared for a metadata fallback), every other originally nonempty slot's unit
 * cleared, and the phase back to 2. */
static int RetryWrites(const CvVault* s, uint8_t (*originals)[CV_HIT_SIZE], const CvSelection* selection, CvWrite* writes)
{
    int count = 0;
    uint8_t pair[8], phase[2][4];
    for (int i = 0; i < s->hit_count; i++)
    {
        const CvHit* hit = &s->hits[i];
        const uint8_t* before = originals[i];
        if (i == selection->slot)
        {
            uint8_t after[CV_HIT_SIZE];
            memcpy(after, hit->bytes, CV_HIT_SIZE);
            if (selection->metadata) cv_put_u32(after + 32, CV_INVALID);
            if (memcmp(before, after, CV_HIT_SIZE) != 0) AddWrite(writes, &count, hit->address, before, after, CV_HIT_SIZE);
        }
        else if (cv_u32(before + 28) != 0)
        {
            cv_pair(pair, 0, cv_u32(before + 32));
            AddWrite(writes, &count, hit->address + 28, before + 28, pair, 8);
        }
    }
    cv_put_u32(phase[0], 3);
    cv_put_u32(phase[1], 2);
    AddWrite(writes, &count, s->controller + 4, phase[0], phase[1], 4);
    return count;
}

/* Restores the retry's writes and gives up with the reason. */
static int Rollback(CvState* st, const char* text, const char** reason)
{
    int restored = cv_restore(&st->pending);
    st->has_pending = 0;
    return Refuse(reason, restored ? text : "query_restore_failed");
}

/* The native driver entered climbing: the same epoch, the climbing flag. */
static int NativeStarted(const CvVault* s)
{
    uint8_t flags[24];
    return cv_same_epoch(s) && cv_load(s->flags_address, flags, sizeof flags) && (cv_u32(flags + 12) & 0x200u) != 0;
}

static void CountRetry(CvCounters* c, const CvVault* s, const CvSelection* selection)
{
    c->prepared++;
    if (selection->metadata) c->metadata_fallbacks++;
    c->retry_calls++;
    if (s->reprojected) c->reprojected_retries++;
    if (s->prior_step_report) c->step_report_retries++;
}

static void CountStart(CvCounters* c, const CvVault* s)
{
    c->native_starts++;
    if (s->reprojected) c->reprojected_starts++;
    if (s->prior_step_report) c->step_report_starts++;
}

/* Exposes the fresh result, runs the original driver with zero dt and restores. */
static int RetryCommit(CvState* st, CvVault* s, const CvWrite* writes, int count, const CvSelection* selection, const char** reason)
{
    st->has_pending = 1;
    int failure = Commit(s, StartPending(st, s), writes, count);
    if (failure == COMMIT_CHANGED)
    {
        int restored = cv_restore(&st->pending);
        st->has_pending = 0;
        return restored ? Accept(reason, "query_changed_before_commit") : Refuse(reason, "query_restore_failed");
    }
    if (failure != COMMIT_OK) return Rollback(st, failure == COMMIT_WRITE ? "query_write_failed" : "query_restore_failed", reason);
    if (!cv_same_epoch(s) || !cv_matches(s->input_address, &s->manual_bytes, 1)) return Rollback(st, "query_changed_before_retry", reason);
    CountRetry(&st->counters, s, selection);
    cv_native_retry(s->controller);
    int started = NativeStarted(s);
    int restored = cv_restore(&st->pending);
    st->has_pending = 0;
    if (!restored) return Refuse(reason, "query_restore_failed");
    if (started) CountStart(&st->counters, s);
    return Accept(reason, started ? "native_local_vault_started" : "native_local_retry_rejected");
}

/* M.retry_consumed. The native selectors read the shared scheduler's counts: rebuilt queries are discovery-only and
 * never reach local consumption. At most one retry per 0.1 s. */
static int RetryConsumed(CvState* st, CvVault* s, const char** reason)
{
    static uint8_t originals[CV_HITS][CV_HIT_SIZE];
    CvWrite writes[CV_MAX_WRITES];
    CvSelection selection;
    if (s->rebuild_queries) return Accept(reason, "retained_query_reused");
    if (st->has_retry && st->now - st->last_retry_at < 0.1) return Accept(reason, "waiting_for_retry_interval");
    st->has_retry = 1;
    st->last_retry_at = st->now;
    const char* approach = NULL;
    int refreshed = cv_refresh(s, &st->counters, originals, reason, &approach);
    if (refreshed != 1) return refreshed == 0 ? 1 : CV_RAISED;
    int selected = cv_select(s, &selection);
    if (selected != 1) return selected == 0 ? Accept(reason, "native_vault_checks_retained") : CV_RAISED;
    if (cv_out_of_reach(s, &s->hits[selection.slot])) return Accept(reason, "retained_query_out_of_reach");
    int count = RetryWrites(s, originals, &selection, writes);
    if (s->reprojected && !cv_context_still(s)) return Accept(reason, "native_context_changed_before_commit");
    if (!cv_guards_hold(&s->guards, 0)) return Accept(reason, "query_changed_before_commit");
    return RetryCommit(st, s, writes, count, &selection, reason);
}

/* A retry that raised restores what it holds and refuses. */
static int Retry(CvState* st, CvVault* s, const char** reason)
{
    int accepted = RetryConsumed(st, s, reason);
    if (accepted != CV_RAISED) return accepted;
    int restored = cv_restore(st->has_pending ? &st->pending : NULL);
    st->has_pending = 0;
    return Refuse(reason, restored ? WithError("validation_failed") : "query_restore_failed");
}

/* ---- the vault half of a check ----------------------------------------------------------------------------------- */

const CvPending* cv_held_writes(CvState* st)
{
    if (!st->has_pending) return NULL;
    if (!cv_same_epoch(st->pending.snapshot)) { st->has_pending = 0; return NULL; }
    return &st->pending;
}

/* The idle gate of the vault check: the slope check of this check has just resolved and verified the local avatar, so
 * its controller's phase word (one read) and the input that check read decide; NULL goes on to the full snapshot. */
static const char* VaultIdle(const CvSlope* avatar)
{
    uint32_t stage;
    if (!vpm_read_u32(avatar->vault_phase, &stage)) return NULL;
    if (stage != 2 && stage != 3) return "waiting_for_vault_query";
    return avatar->manual ? NULL : "waiting_for_manual_vault";
}

/* The snapshot record this check fills: not the one a held write still refers to. */
static CvVault* FreeRecord(const CvState* st)
{
    CvVault* first = cv_vault_record(0);
    return st->has_pending && st->pending.snapshot == first ? cv_vault_record(1) : first;
}

static int VaultCheck(CvState* st, const CvPending* held, int got, CvVault* s, const char* why, const char** reason)
{
    /* Without a new stage-2 plan there is nothing to keep: restore first. */
    if (held != NULL && !(got == 1 && s->stage == 2))
    {
        if (!Release(st, held)) return Refuse(reason, "query_restore_failed");
        held = NULL;
    }
    if (got == CV_RAISED) return Accept(reason, WithError("waiting_for_game_data"));
    if (got == 0) return Accept(reason, why);
    st->observed_queries++;
    if (s->stage == 3) return Retry(st, s, reason);
    return PlanBatch(st, s, held, reason);
}

int cv_vault_apply(CvState* st, const CvPending* held, const CvSlope* avatar, int outside, const char** reason)
{
    /* The slope check found no mission: its mission gate reads would answer the same. Held writes still go through
     * the snapshot, whose failure restores them. */
    if (outside && held == NULL) return Accept(reason, "waiting_for_mission");
    const char* idle = avatar != NULL && held == NULL ? VaultIdle(avatar) : NULL;
    if (idle != NULL) return Accept(reason, idle);
    CvVault* s = FreeRecord(st);
    CvVaultArgs args = {held, avatar != NULL && !avatar->idle ? avatar : NULL, 0};
    const char* why = NULL;
    int got = cv_vault_snapshot(s, &args, &why);
    return VaultCheck(st, held, got, s, why, reason);
}

int cv_stop(CvState* st)
{
    int queries = cv_restore(st->has_pending ? &st->pending : NULL);
    if (queries) st->has_pending = 0;
    int slopes = cv_slope_stop(st);
    return queries && slopes;
}
