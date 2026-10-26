/* Reinforcement Beacons Fixed v4.6.1: the plan (spawn_data.lua's patch.plan, capture_anchor, spawn_blocked,
 * associated_beacon, placement, track, baseline, spawn_changed and beacon_kept), build 25480438.
 *
 * Pure event tracking on two snapshots: it never adjusts a live pod, timers, use bits or network state. A correction
 * is planned only for the local player's own pending spawn (state 2) after a queued death, inside the spawn window
 * (countdown 0.1 .. 5.1 s), for the one beacon whose local use bit was set since the previous snapshot (or, in co-op,
 * the first unused beacon a teammate owns, which the game does not mark: AC7280 picks the first unused record and AC83F0
 * marks only locally owned ones). Solo, the target is the source position frozen when the death's automatic anchor
 * (type 0x7C) appeared, so a moving corpse or camera cannot move it later. */
#include <string.h>
#include "spawn_data.h"

#define WINDOW_LOW 0.1
#define WINDOW_HIGH 5.1
#define RANGE 512.0
#define SAME 0.05

const char rbf_waiting_for_reinforcement[] = "waiting_for_reinforcement";

static double Abs(double v) { return v < 0 ? -v : v; }

/* same_xy: both positions known and within 5 cm on X and Y. */
static int SameXy(int a_known, const float* a, int b_known, const float* b)
{
    return a_known && b_known && Abs((double)a[0] - (double)b[0]) < SAME && Abs((double)a[1] - (double)b[1]) < SAME;
}

/* The first beacon whose bit in mask is clear, and how many are. */
static const RbfBeacon* FirstUnused(const RbfSnapshot* s, uint32_t mask, uint32_t* count)
{
    const RbfBeacon* first = NULL;
    *count = 0;
    for (uint32_t i = 0; i < s->beacon_count; i++)
    {
        if ((s->beacons[i].used & mask) != 0) continue;
        if (first == NULL) first = &s->beacons[i];
        (*count)++;
    }
    return first;
}

void rbf_forget(RbfState* state)
{
    state->previous = NULL;
    state->anchored = state->pending = 0;
    state->spawn = RBF_NIL;
    state->landed_known = 0;
    state->landed_count = 0;
}

int rbf_baseline(RbfSnapshot* out, const RbfSnapshot* current, int64_t last, const RbfState* state)
{
    if (last == RBF_NIL || last == 1 || last == 2) return 0;
    rbf_clear(out);
    out->identity = current->identity;
    out->id = current->id;
    out->count = current->count;
    out->mode = current->mode;
    out->owned = current->owned;
    out->state = last;
    out->unobserved = 1;
    out->rows_known = state->landed_known;
    out->row_count = state->landed_count;
    memcpy(out->rows, state->landed, (size_t)state->landed_count * sizeof(RbfRow));
    return 1;
}

void rbf_track(RbfState* state, const RbfSnapshot* current)
{
    state->spawn = current->state;
    if (current->state == 1 || current->state == 2) return;
    state->previous = NULL;
    state->landed_known = current->state != RBF_NIL && current->count == 1;
    state->landed_count = state->landed_known ? current->row_count : 0;
    memcpy(state->landed, current->rows, (size_t)state->landed_count * sizeof(RbfRow));
}

static int WasPresent(const RbfSnapshot* previous, const RbfRow* row)
{
    for (uint32_t i = 0; previous->rows_known && i < previous->row_count; i++)
        if (memcmp(previous->rows[i].position, row->position, sizeof row->position) == 0) return 1;
    return 0;
}

/* The automatic dummy exists before its reinforcement component: the first row new since the previous snapshot is this
 * death's anchor, and its source is frozen now. With no rows known, only a lone row can be the anchor. */
static int CaptureAnchor(RbfReader* r, const RbfSnapshot* previous, RbfSnapshot* current, RbfState* state)
{
    if (current->count != 1 || (current->state != 1 && current->state != 2) || state->anchored) return RBF_OK;
    if (!previous->rows_known && current->row_count != 1) return RBF_OK;
    for (uint32_t i = 0; i < current->row_count; i++)
    {
        if (WasPresent(previous, &current->rows[i])) continue;
        int rc = rbf_source(r, current);
        if (rc == RBF_OK && current->source_valid)
        {
            state->anchored = 1;
            state->anchor = current->rows[i];
            memcpy(state->anchor_source, current->source, sizeof state->anchor_source);
        }
        return rc;
    }
    return RBF_OK;
}

/* Why this check cannot correct the spawn before any beacon is considered; NULL when it may. */
static const char* SpawnBlocked(const RbfSnapshot* previous, const RbfSnapshot* current, const RbfState* state)
{
    double countdown = current->countdown;
    if (current->state != 2) return rbf_waiting_for_reinforcement;
    if (previous->state != 2 && previous->state != 1 && previous->state != 3) return "initial_deployment_unchanged";
    /* Alive straight to pending: no beacon use bits were read before this spawn (unmeasured in game). */
    if (previous->unobserved) return "pending_without_queue_skipped";
    if (state->pending) return "reinforcement_already_centered";
    if (!current->positioned || !current->timed || countdown <= WINDOW_LOW || countdown > WINDOW_HIGH)
        return "spawn_window_unavailable";
    return NULL;
}

static int UsedBefore(const RbfSnapshot* previous, uint32_t id, uint32_t mask)
{
    int used = 0;
    for (uint32_t i = 0; i < previous->beacon_count; i++)
        used |= previous->beacons[i].id == id && (previous->beacons[i].used & mask) != 0;
    return used;
}

/* A teammate's beacon the commit left unmarked: the first unused one, the same one (id and XY) as before the commit,
 * or the only unused one when none was seen before. */
static const RbfBeacon* UnmarkedRemote(const RbfSnapshot* previous, const RbfSnapshot* current, uint32_t mask)
{
    uint32_t before = 0, unused = 0;
    const RbfBeacon* old = FirstUnused(previous, mask, &before);
    const RbfBeacon* candidate = FirstUnused(current, mask, &unused);
    if (candidate == NULL || candidate->owned || !candidate->positioned) return NULL;
    int observed = old != NULL && !old->owned && old->id == candidate->id &&
        SameXy(old->positioned, old->position, candidate->positioned, candidate->position);
    return observed || (old == NULL && unused == 1) ? candidate : NULL;
}

/* The one beacon this spawn belongs to (NULL: none, or several) and whether it is a teammate's unmarked one. */
static const RbfBeacon* AssociatedBeacon(const RbfSnapshot* previous, const RbfSnapshot* current, uint32_t mask, int* remote)
{
    const RbfBeacon* beacon = NULL;
    uint32_t selected = 0;
    *remote = 0;
    for (uint32_t i = 0; i < current->beacon_count; i++)
    {
        const RbfBeacon* b = &current->beacons[i];
        if ((b->used & mask) == 0 || !b->positioned || UsedBefore(previous, b->id, mask)) continue;
        if (selected++ == 0) beacon = b;
    }
    if (selected == 0 && current->count > 1 && previous->state == 1)
    {
        beacon = UnmarkedRemote(previous, current, mask);
        *remote = beacon != NULL;
    }
    return selected > 1 ? NULL : beacon;
}

/* The target (the beacon, or solo the frozen source of its anchor) within 512 m of the pending spawn: NULL with the plan
 * made, or why not. */
static const char* Placement(const RbfSnapshot* current, const RbfState* state, const RbfBeacon* beacon, RbfPlan* plan)
{
    const float* target = beacon->position;
    plan->solo = 0;
    if (current->count == 1)
    {
        if (!state->anchored || !SameXy(1, state->anchor.position, beacon->positioned, beacon->position))
            return "solo_anchor_unavailable";
        target = state->anchor_source;
        plan->solo = 1;
    }
    double dx = (double)target[0] - (double)current->position[0], dy = (double)target[1] - (double)current->position[1];
    if (dx * dx + dy * dy > RANGE * RANGE) return "placement_outside_supported_range";
    memcpy(plan->bytes, target, sizeof plan->bytes);
    plan->target[0] = target[0];
    plan->target[1] = target[1];
    plan->beacon = beacon->id;
    memcpy(plan->beacon_position, beacon->position, sizeof plan->beacon_position);
    return NULL;
}

/* Another player manager, local player, player count or mode, a mode outside gameplay, not owned here, or no
 * reinforcement under way. */
static int Unrelated(const RbfSnapshot* previous, const RbfSnapshot* current)
{
    return previous == NULL || previous->identity != current->identity || previous->id != current->id ||
        previous->count != current->count || previous->mode != current->mode || current->mode < 1 || current->mode > 7 ||
        !current->owned || current->state == 3 || current->state == 0;
}

int rbf_plan(RbfReader* reader, RbfState* state, RbfSnapshot* current, RbfPlan* plan, const char** reason)
{
    const RbfSnapshot* previous = state->previous;
    state->previous = current;
    *reason = NULL;
    if (Unrelated(previous, current))
    {
        state->anchored = state->pending = 0;
        *reason = rbf_waiting_for_reinforcement;
        return RBF_OK;
    }
    int rc = CaptureAnchor(reader, previous, current, state);
    if (rc == RBF_WAIT) rbf_forget(state); /* as an unavailable snapshot does */
    if (rc != RBF_OK) return rc;
    *reason = SpawnBlocked(previous, current, state);
    if (*reason != NULL) return RBF_OK;
    const RbfBeacon* beacon = AssociatedBeacon(previous, current, 1u << current->use_bit, &plan->remote);
    *reason = beacon == NULL ? "beacon_association_unavailable" : Placement(current, state, beacon, plan);
    return RBF_OK;
}

int rbf_spawn_changed(const RbfSnapshot* current, const RbfSnapshot* fresh)
{
    double countdown = fresh->countdown;
    if (fresh->identity != current->identity || fresh->id != current->id || fresh->unit_ref != current->unit_ref ||
        fresh->use_bit != current->use_bit || fresh->count != current->count || fresh->mode != current->mode)
        return 1;
    if (!fresh->owned || fresh->state != 2 || !fresh->timed || countdown <= WINDOW_LOW || countdown > WINDOW_HIGH) return 1;
    return memcmp(fresh->original, current->original, sizeof fresh->original) != 0;
}

int rbf_beacon_kept(const RbfSnapshot* fresh, const RbfPlan* plan)
{
    uint32_t mask = 1u << fresh->use_bit, unused = 0;
    const RbfBeacon* first = FirstUnused(fresh, mask, &unused);
    int found = 0;
    for (uint32_t i = 0; i < fresh->beacon_count; i++)
    {
        const RbfBeacon* b = &fresh->beacons[i];
        if (b->id != plan->beacon || !SameXy(b->positioned, b->position, 1, plan->beacon_position)) continue;
        if (plan->remote) found = !b->owned && first != NULL && first->id == b->id && (b->used & mask) == 0;
        else found = (b->used & mask) != 0;
    }
    return found;
}
