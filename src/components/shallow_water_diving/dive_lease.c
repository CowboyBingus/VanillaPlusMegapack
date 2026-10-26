/* Shallow Water Diving: the check that takes, holds and gives back the water-reference lease (dive_data.lua M.apply,
 * M.reason, M.restore and the page check), for build 25480438.
 *
 * A newly observed dive from shallow water (prone, no swimming or ragdoll, no landing timer, at most 0.05 s of engine
 * dive time, drowning enabled and not drowned, the original prone offset) gets its Drownable runtime record's offset
 * (+8) set to the standing reference (-1.3) instead of prone's (-0.4), so the swim predicate cannot cancel the dive; a
 * first prone frame's submersion debt (+16, at most 0.05 s) is cleared once. Both are 4-byte stores into the record,
 * after one page check (VirtualQuery) of the record's pages, which is kept for later dives while the same manager,
 * table and avatar are in use. The reference is put back on landing, at the dive's end, on another stance or state,
 * disabled drowning, the 2 s native timeout and in deeper water; the current stance's own value, never stale prone
 * bytes, and only while the record still belongs to the same entity. */
#include <string.h>
#include "../../core/vpm.h"
#include "dive_data.h"

#define PAGE 4096u

SwdState swd;

static uint32_t Bits(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }

void swd_reset(void)
{
    memset(&swd, 0, sizeof swd);
    swd.max_water_depth = SWD_MIN_WATER_DEPTH;
    swd_snapshot_reset();
}

int swd_set_max_water_depth(double depth)
{
    if (depth != depth) return 0;
    swd.max_water_depth = depth < SWD_MIN_WATER_DEPTH ? SWD_MIN_WATER_DEPTH : depth > SWD_SWIM_DEPTH ? SWD_SWIM_DEPTH : depth;
    return 1;
}

/* The native landing timer is zero in flight and becomes positive when the native land_dodge path begins. */
const char* swd_reason(const SwdSnapshot* s)
{
    if (!s->dive) return "dive_ended";
    if (s->swim || s->ragdoll || s->stance != 2) return "other_state";
    if (!s->enabled || s->remaining <= 0) return "water_disabled_or_drowned";
    if (s->landing != 0) return "landing";
    if (s->elapsed < 0 || s->elapsed >= 2) return "native_timeout";
    /* A disabled secondary gate makes surface_z a reset value, not a plane. */
    if (s->deep || (s->water_gate && (double)s->surface > (double)s->root_z - (double)s->base)) return "deep_water";
    /* A reset surface value is not evidence of water. The assistance is kept to the configured depth (lower shin by
     * default); deeper water keeps the game's normal dive decision. */
    if (!s->water_gate) return "water_surface_unavailable";
    double depth = (double)s->surface - (double)s->root_z;
    if (depth <= 0) return "not_in_shallow_water";
    if (depth > swd.max_water_depth + 0.00001) return "water_too_deep";
    return NULL;
}

/* ---- the record's floats ---------------------------------------------------------------------------------------- */

/* A store into the water record. checked: the kept page check covers it; otherwise the page is checked first. */
static int LeaseStore(uintptr_t address, uint32_t bits, int checked)
{
    if (!checked)
    {
        swd.queries++;
        if (!vpm_writable(address, 4)) return 0;
    }
    memcpy((void*)address, &bits, 4);
    swd.writes++;
    return 1;
}

static int LeaseHolds(uintptr_t address, uint32_t bits)
{
    uint32_t now = 0;
    return vpm_read_u32(address, &now) && now == bits;
}

/* A partially written float can contain neither complete value: the first cut bytes of after and the rest of before. */
static int LeasePartial(uint32_t before, uint32_t after, uint32_t current)
{
    for (int cut = 0; cut <= 4; cut++)
    {
        uint32_t mask = cut == 4 ? 0xFFFFFFFFu : (1u << (8 * cut)) - 1u;
        if (current == ((after & mask) | (before & ~mask))) return 1;
    }
    return 0;
}

/* The current stance's own reference: base + 0.9 prone, + 0.4 crouching, base standing. */
static uint32_t LeaseTarget(float base, uint32_t stance)
{
    double offset = stance == 2 ? (double)0.9f : stance == 1 ? (double)0.4f : 0;
    return Bits((float)((double)base + offset));
}

/* A failed startup-debt clear: the timer's own value back, when what is there is a torn copy of ours. */
static int LeaseRestoreElapsed(int checked)
{
    SwdLease* p = &swd.pending;
    if (!p->elapsed.valid) return 1;
    uint32_t current = 0;
    int have = vpm_read_u32(p->elapsed.address, &current);
    if (have && LeasePartial(p->elapsed.before, p->elapsed.after, current) && current != p->elapsed.before)
    {
        (void)LeaseStore(p->elapsed.address, p->elapsed.before, checked); /* the read-back decides, as in the Lua */
        if (!LeaseHolds(p->elapsed.address, p->elapsed.before)) return 0;
    }
    p->elapsed.valid = 0;
    return 1;
}

static int LeaseOurs(int have, uint32_t current)
{
    const SwdLease* p = &swd.pending;
    if (!have) return 0;
    return current == p->after || (p->failed_write && LeasePartial(p->before, p->after, current)) ||
           (p->recovery.valid && LeasePartial(p->recovery.before, p->recovery.after, current));
}

int swd_restore(int reuse, const char** reason)
{
    SwdLease* p = &swd.pending;
    if (!p->valid) { *reason = "nothing_to_restore"; return 1; }
    if (!swd_identities_match()) { *reason = "retired_identity"; return 1; }
    int checked = reuse && p->checked;
    if (!LeaseRestoreElapsed(checked)) { *reason = "startup_restore_failed"; return 0; }
    uint32_t current = 0, stance = 0;
    int have = vpm_read_u32(p->address, &current);
    if (!LeaseOurs(have, current)) { *reason = "offset_changed_by_engine"; return 1; }
    if (!vpm_read_u32(p->stance_address, &stance) || stance > 2) { *reason = "stance_unavailable"; return 0; }
    /* A native transition to standing may already have written the same bytes we used. */
    uint32_t target = LeaseTarget(p->base, stance);
    if (current == target) { *reason = "already_restored"; return 1; }
    if (!swd_identities_match()) { *reason = "retired_identity"; return 1; }
    p->recovery.valid = 1;
    p->recovery.before = current;
    p->recovery.after = target;
    if (!LeaseStore(p->address, target, checked)) { *reason = "offset_not_writable"; return 0; }
    *reason = "restored";
    return LeaseHolds(p->address, target);
}

static int LeaseRelease(const char* why, int reuse, const char** reason)
{
    const char* detail = NULL;
    int ok = swd_restore(reuse, &detail);
    if (ok)
    {
        swd.pending.valid = 0;
        swd.restored++;
    }
    *reason = ok ? why : "restore_failed";
    return ok;
}

/* ---- the page check --------------------------------------------------------------------------------------------- */

/* One page check covers both floats of the record (+8 .. +20): the pages it approved are kept while the same Drownable
 * manager, table and avatar are in use (the guards read the table pointer and the record's owner again right before
 * every write) and dropped on any wait, avatar change or failed write. A table seen at a new address while one was kept
 * counts as a move. */
static int LeaseWritable(const SwdSnapshot* s)
{
    uintptr_t low = s->water_address + 8, high = s->water_address + 20;
    SwdWriteCheck* c = &swd.write_check;
    if (c->valid && c->manager == s->manager && c->table == s->table && c->key == swd.key && c->low <= low && high <= c->high)
        return 1;
    if (c->valid && (c->manager != s->manager || c->table != s->table)) swd.table_moves++;
    c->valid = 0;
    uintptr_t from = low & ~(uintptr_t)(PAGE - 1), to = (high + PAGE - 1) & ~(uintptr_t)(PAGE - 1);
    swd.queries++;
    if (!vpm_writable(from, to - from)) return 0;
    *c = (SwdWriteCheck){1, s->manager, s->table, swd.key, from, to};
    return 1;
}

/* ---- the check -------------------------------------------------------------------------------------------------- */

/* No snapshot: forget the avatar, and give a held lease back. */
static int LeaseWaiting(const char* waiting, const char** reason)
{
    swd.gate = 0;
    swd.write_check.valid = 0;
    swd.keyed = 0;
    swd.was_dive = 0;
    swd.retry_start = 0;
    if (swd.pending.valid) return LeaseRelease(waiting, 0, reason);
    *reason = waiting;
    return 1;
}

/* Another avatar (or the same entity record reused): an old lease is put back first. 0 when that failed. */
static int LeaseFollow(const SwdSnapshot* s, const char** reason)
{
    if (swd.keyed && swd.key == s->key && memcmp(swd.entity, s->entity, sizeof swd.entity) == 0) return 1;
    if (swd.pending.valid)
    {
        const char* detail = NULL;
        if (!swd_restore(0, &detail)) { *reason = "restore_failed"; return 0; }
        swd.pending.valid = 0;
    }
    swd.keyed = 1;
    swd.key = s->key;
    swd.was_dive = 0;
    swd.retry_start = 0;
    swd.write_check.valid = 0;
    memcpy(swd.entity, s->entity, sizeof swd.entity);
    return 1;
}

/* The counters, and whether this is a newly observed dive. */
static int LeaseObserve(const SwdSnapshot* s)
{
    swd.gate = 1;
    swd.gate_controller = s->controller;
    swd.gate_id = s->id;
    int fresh = s->dive && !swd.was_dive;
    if (fresh) swd.observed++;
    if (swd.was_dive && !s->dive && (double)s->elapsed <= 0.02) swd.short_ends++;
    swd.was_dive = s->dive;
    return fresh;
}

/* A held lease: given back on any reason, or when the engine replaced the offset (its own value stays). */
static int LeaseHeld(const SwdSnapshot* s, const char* why, const char** reason, int* active)
{
    if (why != NULL) return LeaseRelease(why, 1, reason);
    if (s->offset_bits != swd.pending.after) return LeaseRelease("offset_changed_by_engine", 0, reason);
    *reason = "airborne_reference";
    *active = 1;
    return 1;
}

/* The water update may already have counted the first prone frame. Only that startup debt is cleared, once, while the
 * standing reference is above water. */
static int LeaseStartupDebt(const SwdSnapshot* s, const char** reason, int* active)
{
    if ((double)s->drown_elapsed > 0 && (double)s->drown_elapsed <= 0.05 && s->water_gate)
    {
        uintptr_t at = s->water_address + 16;
        if (!swd_guards_match(1)) return LeaseRelease("identity_changed", 0, reason);
        if (!LeaseHolds(at, s->elapsed_bits)) return LeaseRelease("water_changed", 0, reason);
        if (!(LeaseStore(at, 0, 1) && LeaseHolds(at, 0)))
        {
            swd.write_check.valid = 0;
            swd.pending.elapsed.valid = 1;
            swd.pending.elapsed.address = at;
            swd.pending.elapsed.before = s->elapsed_bits;
            swd.pending.elapsed.after = 0;
            (void)LeaseRelease("startup_write_failed", 0, reason); /* the component stops either way */
            *reason = "startup_write_failed";
            return 0;
        }
        swd.startup_clears++;
    }
    else if ((double)s->drown_elapsed > 0)
        return LeaseRelease("existing_submersion", 0, reason);
    swd.protected++;
    *reason = "airborne_reference";
    *active = 1;
    return 1;
}

/* The lease: the standing reference written after the coherence and page checks; a write that did not hold is put back
 * at once (we own this exact attempt; the entity and record must still match) and stops the component. */
static int LeaseTake(const SwdSnapshot* s, const char** reason, int* active)
{
    uintptr_t address = s->water_address + 8;
    if (!swd_guards_match(0))
    {
        swd.retry_start = 1; /* a coherent snapshot is tried again on the next check */
        *reason = "snapshot_changed";
        return 1;
    }
    if (!LeaseWritable(s)) { *reason = "reference_write_failed"; return 0; }
    SwdLease* p = &swd.pending;
    memset(p, 0, sizeof *p);
    p->valid = 1;
    p->address = address;
    p->before = s->offset_bits;
    p->after = Bits(s->base);
    p->stance_address = s->stance_address;
    p->base = s->base;
    p->checked = 1;
    swd_keep_identities();
    if (!(LeaseStore(address, p->after, 1) && LeaseHolds(address, p->after)))
    {
        const char* detail = NULL;
        swd.write_check.valid = 0;
        p->failed_write = 1;
        if (swd_restore(0, &detail)) p->valid = 0;
        *reason = "reference_write_failed";
        return 0;
    }
    return LeaseStartupDebt(s, reason, active);
}

/* Do not acquire an old dive after a start or rescue an ongoing swim. */
static int LeaseAcquire(const SwdSnapshot* s, int fresh, const char** reason, int* active)
{
    if (!(fresh || swd.retry_start) || (double)s->elapsed > 0.05) { *reason = "waiting_for_dive_start"; return 1; }
    swd.retry_start = 0;
    if ((double)s->drown_elapsed > 0.05 || ((double)s->drown_elapsed > 0 && !s->water_gate))
    {
        *reason = "existing_submersion";
        return 1;
    }
    if (s->offset_bits != Bits(s->prone)) { *reason = "different_reference_owner"; return 1; }
    return LeaseTake(s, reason, active);
}

/* The full check: every call reads the identity chain (the idle gate is the component's). */
int swd_apply(const char** reason, int* active)
{
    *active = 0;
    const char* waiting = NULL;
    int ready = swd_snapshot(&swd.constants_verified, &waiting);
    if (ready < 0) return -1;
    if (ready == 0) return LeaseWaiting(waiting, reason);
    const SwdSnapshot* s = &swd_snap;
    if (!LeaseFollow(s, reason)) return 0;
    int fresh = LeaseObserve(s);
    const char* why = swd_reason(s);
    if (swd.pending.valid) return LeaseHeld(s, why, reason, active);
    if (why != NULL)
    {
        swd.retry_start = 0;
        *reason = why;
        return 1;
    }
    return LeaseAcquire(s, fresh, reason, active);
}
