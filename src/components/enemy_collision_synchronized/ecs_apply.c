/* Enemy Collision Synchronized: a poll and the commands for each inspected unit (the Lua: corpse_data.lua M.apply,
 * consume, note_corpse, defer_repeats, expire, prune_corpse_checks, M.reset).
 *
 * A unit's commands: M.plan's realignments (an auxiliary actor's queued rotation and position, from its node's rigid
 * pose) and the Impaler's claw disables; each only after the unit's guards and that actor's guards (identity, row data,
 * body motion and identity) hold. A small repeat of one actor's realignment within a second waits (up to 10 cm and 5
 * degrees; the first correction and large repeats apply at once). Then the motion sample (EcsFlingAction), after the
 * unit's guards and every main body's pose guard hold again, and at most one native call, last, since it may change the
 * entity: the stop of a fling (RagdollSync's stop, verified by the update byte reading 0 afterwards), the finish of a
 * stop this session made once ownership moved here (the same routine's owned branch), or once, 1 s after a verified
 * remote stop, the owner-routed completion request. A corpse that needed no command on 24 inspections in a row is
 * inspected again after 2, 4, 8 ... polls, at most 64 apart; one that needs a command starts over. Leaving a mission
 * forgets everything (the first poll outside one). */
#include <string.h>
#include "ecs_internal.h"

EcsState Ecs;

static EcsAction g_actions[ECS_MAX_ACTORS];
static EcsGuard g_actorGuards[4];
static uint8_t g_actorBytes[56];

static int SameSignature(const EcsSignature* a, const EcsSignature* b)
{
    return a->count == b->count && memcmp(a->ids, b->ids, sizeof(uint32_t) * a->count) == 0;
}

/* Whether the unit's guards hold: a unit the snapshot just verified holds until its first native command. */
static int Holds(EcsUnit* u) { return u->verified || EcsSame(&u->guards); }

/* An actor's fresh identity and motion, checked again at a command: its row identity and data, its body's motion and
 * identity words. */
static int ActorHolds(const EcsActor* a)
{
    EcsGuards guards;
    EcsGuardsInit(&guards, g_actorGuards, 4, g_actorBytes, sizeof g_actorBytes);
    return EcsGuardAdd(&guards, a->identity_address, a->identity, 4) && EcsGuardAdd(&guards, a->data_address, a->data, 40) &&
        EcsGuardAdd(&guards, a->body_address + 64u, a->body + 64, 4) && EcsGuardAdd(&guards, a->body_address + 144u, a->body + 144, 8) &&
        EcsSame(&guards);
}

/* ---- the corpse re-check backoff and the repeat cooldown ---------------------------------------------------------- */

static void NoteCorpse(const EcsUnit* u, uint32_t actions, int stopped)
{
    if (!u->corpse) return;
    if (actions != 0 || stopped || u->address == 0 || ECS_CORPSE_RECHECK_POLLS == 0)
    {
        EcsTableRemove(&EcsChecks, u->unit);
        return;
    }
    int added;
    uint32_t scan = Ecs.fling_scan;
    EcsCheck* check = EcsTablePut(&EcsChecks, u->unit, &added);
    if (check == NULL) return;
    if (added || check->address != u->address || check->entity != u->id) *check = (EcsCheck){u->address, u->id, scan, 0, 0, 0};
    check->seen = scan;
    if (scan - check->since < ECS_CORPSE_SETTLE_POLLS) return;
    uint32_t wait = check->wait * 2u < 2u ? 2u : check->wait * 2u;
    check->wait = wait > ECS_CORPSE_RECHECK_POLLS ? ECS_CORPSE_RECHECK_POLLS : wait;
    check->due = scan + check->wait;
}

/* A settled remote ragdoll still receiving network corrections nudges its skeleton a few centimetres every tenth of a
 * second, and each nudge requalified the same actor (389 realignments in 4.3 s on one recorded Acid Charger). */
static uint32_t DeferRepeats(const EcsUnit* u, uint32_t n, double now)
{
    uint32_t kept = 0;
    for (uint32_t i = 0; i < n; i++)
    {
        const EcsAction* action = &g_actions[i];
        const EcsRepose* last = action->kind == ECS_REPOSE ? EcsTableFind(&EcsReposes, u->actors[action->actor].id) : NULL;
        int hold = last != NULL && last->unit == u->unit && last->entity == u->id && now >= last->at &&
            now - last->at < ECS_REPOSE_COOLDOWN && action->gap <= ECS_REPOSE_BYPASS_M && action->degrees <= ECS_REPOSE_BYPASS_DEGREES;
        if (hold) Ecs.reposes_deferred++;
        else g_actions[kept++] = *action;
    }
    return kept;
}

/* ---- commands ---------------------------------------------------------------------------------------------------- */

static void Realigned(const EcsUnit* u, const EcsAction* action, const EcsActor* actor, double now)
{
    int added;
    Ecs.realignments++;
    EcsRepose* entry = EcsTablePut(&EcsReposes, actor->id, &added);
    if (entry != NULL) *entry = (EcsRepose){u->unit, u->id, now};
    if (u->corpse && u->main_static < u->main_enabled) Ecs.mixed_corpse_realignments++;
    if (action->gap > Ecs.max_gap) Ecs.max_gap = action->gap;
    Ecs.last_unit = u->unit;
    Ecs.last_actor = actor->id;
}

static void RunActions(EcsUnit* u, uint32_t n, double now)
{
    for (uint32_t i = 0; i < n; i++)
    {
        const EcsAction* action = &g_actions[i];
        const EcsActor* actor = &u->actors[action->actor];
        if (!Holds(u) || !ActorHolds(actor)) { Ecs.skipped++; continue; }
        u->verified = 0;
        if (action->kind == ECS_DISABLE)
        {
            EcsDisableActor(actor->id);
            Ecs.claws_disabled++;
            continue;
        }
        EcsSetPose(actor->id, action->position, action->rotation);
        Realigned(u, action, actor, now);
    }
}

/* Conversion makes a new entity with the same unit handle: observe the phase (a submitted request alone is not
 * success); a stop record that no longer describes this unit is dropped. Returns the record still in force, or NULL. */
static EcsStop* KeptStop(EcsUnit* u, EcsStop* stopped)
{
    if (stopped != NULL && stopped->requested && u->corpse && u->active && stopped->profile == u->profile && Holds(u))
    {
        Ecs.completion_corpse_observed++;
        EcsTableRemove(&EcsStops, u->unit);
        return NULL;
    }
    if (stopped != NULL && (stopped->entity != u->id || stopped->profile != u->profile ||
        !SameSignature(&stopped->members, &u->signature) || u->corpse || u->update_enabled == 1))
    {
        EcsTableRemove(&EcsStops, u->unit);
        return NULL;
    }
    return stopped;
}

/* RagdollSync's stop on a fling: it changes update_enabled, so it runs last; the remote-only gate keeps it out of the
 * routine's locally owned force-Corpse branch. No pose is rewound. */
static void Stop(const EcsUnit* u, const EcsStopCall* stop, double now)
{
    EcsStopSync(u->manager, u->index);
    Ecs.fling_stops++;
    Ecs.last_fling_unit = u->unit;
    Ecs.last_fling_entity = u->id;
    Ecs.last_fling_type = EcsProfiles[u->profile].name;
    Ecs.last_fling_reason = EcsCauseName(stop->cause);
    Ecs.last_fling_uptime = now;
    Ecs.last_fling_distance = stop->distance;
    Ecs.last_fling_degrees = stop->degrees;
    Ecs.last_fling_actor = stop->actor;
    Ecs.last_fling_limb_distance = stop->limb ? stop->limb_distance : 0;
    Ecs.last_fling_limb_degrees = stop->limb ? stop->limb_degrees : 0;
    if (stop->limb) Ecs.fling_limb_stops++;
    if (stop->cause == ECS_CAUSE_LANDED_DISABLED) Ecs.landed_disabled_stops++;
    if (stop->distance > Ecs.max_fling_distance) Ecs.max_fling_distance = stop->distance;
    uint8_t update = 1;
    if (!vpm_read_u8(u->update_address, &update) || update != 0) return;
    Ecs.fling_stops_verified++;
    EcsTableRemove(&EcsHistories, u->unit);
    int added;
    EcsStop* kept = EcsTablePut(&EcsStops, u->unit, &added);
    if (kept != NULL) *kept = (EcsStop){u->id, Ecs.fling_scan, u->profile, 0, u->signature, now};
}

/* A remote stop never requests Corpse conversion: ask its owner through the engine's own path, once. No ownership,
 * timer or replication storage is edited. Native completion may invalidate entity storage: nothing of this snapshot is
 * read again after it. */
static int Complete(const EcsUnit* u, EcsStop* stopped, double now)
{
    stopped->requested = 1;
    Ecs.completion_requests++;
    Ecs.last_completion_unit = u->unit;
    Ecs.last_completion_entity = u->id;
    Ecs.last_completion_uptime = now;
    return EcsRequestCompletion(u->id);
}

typedef struct Decision { int stop, handoff, completion; EcsStopCall call; } Decision;

/* The motion sample and what a kept stop calls for, once the unit's guards and every main pose guard still hold. */
static void Decide(EcsUnit* u, EcsStop* stopped, int planned, double now, Decision* d)
{
    memset(d, 0, sizeof *d);
    int validate = planned || (!u->corpse && u->owner == 0 && u->active && u->update_enabled == 1 && EcsSettled(u));
    if (validate && !(Holds(u) && EcsSame(&u->pose_guards)))
    {
        EcsTableRemove(&EcsHistories, u->unit);
        return;
    }
    if (stopped != NULL)
    {
        stopped->last_scan = Ecs.fling_scan;
        d->handoff = u->owner && u->active && EcsSettled(u);
        d->completion = !u->owner && u->active && EcsSettled(u) && !stopped->requested &&
            now - stopped->stopped_at >= ECS_COMPLETION_GRACE;
    }
    d->stop = EcsFlingAction(u, now, &d->call);
}

/* The one native call that may change the entity, last. 1, or 0 raised. */
static int Dispatch(EcsUnit* u, EcsStop* stopped, const Decision* d, double now)
{
    if (d->handoff && Holds(u))
    {
        /* The runtime is copied unchanged when ownership moves: finish ONLY a stop this session made, through the
         * routine's normal owned-Corpse branch. It may transition the entity: nothing of it is read again. */
        EcsStopSync(u->manager, u->index);
        Ecs.fling_handoffs++;
        EcsTableRemove(&EcsStops, u->unit);
        return 1;
    }
    if (d->completion && Holds(u)) return Complete(u, stopped, now);
    if (d->stop && Holds(u) && EcsSame(&u->pose_guards)) { Stop(u, &d->call, now); return 1; }
    /* A race at dispatch breaks the observation interval too. */
    if (d->stop) EcsTableRemove(&EcsHistories, u->unit);
    return 1;
}

int EcsConsume(EcsUnit* u)
{
    double now = Ecs.now;
    Ecs.observed++;
    Ecs.accepted_units++;
    uint32_t n = EcsPlan(u, g_actions);
    EcsStop* stopped = EcsTableFind(&EcsStops, u->unit);
    NoteCorpse(u, n, stopped != NULL);
    n = DeferRepeats(u, n, now);
    if (n == 0 && stopped == NULL && u->corpse) return 1;
    stopped = KeptStop(u, stopped);
    /* No actions: this identity pass is redundant. The motion sample still validates identity and every pose below. */
    int planned = n > 0 || stopped != NULL;
    if (!planned) Ecs.guard_passes_skipped++;
    if (planned && !Holds(u))
    {
        EcsTableRemove(&EcsHistories, u->unit);
        return 1;
    }
    RunActions(u, n, now);
    Decision d;
    Decide(u, stopped, planned, now, &d);
    return Dispatch(u, stopped, &d, now);
}

/* ---- a poll ------------------------------------------------------------------------------------------------------ */

/* Expires repose cooldowns and motion histories older than now allows. */
static void Expire(double now)
{
    for (uint32_t slot = 0; slot < EcsReposes.capacity;)
    {
        const EcsRepose* entry = EcsTableSlot(&EcsReposes, slot, NULL);
        if (entry != NULL && (now < entry->at || now - entry->at >= ECS_REPOSE_COOLDOWN)) EcsTableRemoveSlot(&EcsReposes, slot);
        else slot++;
    }
    for (uint32_t slot = 0; slot < EcsHistories.capacity;)
    {
        const EcsHistory* entry = EcsTableSlot(&EcsHistories, slot, NULL);
        if (entry == NULL || !(now < entry->last || now - entry->last > 1)) { slot++; continue; }
        if (now - entry->last > Ecs.max_revisit_seconds) Ecs.max_revisit_seconds = now - entry->last;
        Ecs.history_expirations++;
        EcsTableRemoveSlot(&EcsHistories, slot);
    }
}

/* Every 256 polls, forgets backoff records of corpses not inspected for 256 polls (a waiting corpse is inspected at least
 * every 64): the game disposed of them. Stops are forgotten after 256 polls without their unit; polls, not wall time, so
 * a paused game does not forget a stop just before an ownership handoff. */
static void Prune(void)
{
    for (uint32_t slot = 0; Ecs.fling_scan % 256u == 0 && slot < EcsChecks.capacity;)
    {
        const EcsCheck* check = EcsTableSlot(&EcsChecks, slot, NULL);
        if (check != NULL && Ecs.fling_scan - check->seen > 256u) EcsTableRemoveSlot(&EcsChecks, slot);
        else slot++;
    }
    for (uint32_t slot = 0; slot < EcsStops.capacity;)
    {
        const EcsStop* stop = EcsTableSlot(&EcsStops, slot, NULL);
        if (stop != NULL && Ecs.fling_scan - stop->last_scan > 256u) EcsTableRemoveSlot(&EcsStops, slot);
        else slot++;
    }
}

void EcsReset(void)
{
    EcsTablesReset();
    Ecs.cursors[0] = Ecs.cursors[1] = 0;
    EcsListingsReset();
}

static uint32_t Pending(void)
{
    uint32_t pending = 0;
    for (uint32_t slot = 0; EcsStops.count > 0 && slot < EcsStops.capacity; slot++)
    {
        const EcsStop* stop = EcsTableSlot(&EcsStops, slot, NULL);
        if (stop != NULL && stop->requested) pending++;
    }
    return pending;
}

void EcsApplyBegin(void)
{
    Ecs.fling_scan++;
    if (EcsReposes.count > 0 || EcsHistories.count > 0) Expire(Ecs.now);
    Prune();
    Ecs.observed = 0;
    memset(&Ecs.budget, 0, sizeof Ecs.budget);
    EcsReadsBegin();
    EcsReaderBegin();
}

void EcsApplyEnd(int ready)
{
    if (ready) EcsReadTotals(&Ecs.read_bytes, &Ecs.read_calls);
    Ecs.scan_entities += Ecs.budget.scanned;
    Ecs.deep_inspections += Ecs.budget.inspected;
    if (Ecs.budget.yielded) Ecs.budget_yields++;
    /* Off a mission the first poll forgets everything; later ones find it forgotten already. */
    if (ready) Ecs.forgotten = 0;
    else if (!Ecs.forgotten)
    {
        EcsReset();
        Ecs.forgotten = 1;
    }
    Ecs.completion_pending = Pending();
}

int EcsApply(int* ready)
{
    EcsApplyBegin();
    *ready = 0;
    if (!EcsScanPoll(ready)) return 0;
    EcsApplyEnd(*ready);
    return 1;
}
