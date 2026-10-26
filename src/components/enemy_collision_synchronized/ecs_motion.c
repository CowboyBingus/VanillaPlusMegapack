/* Enemy Collision Synchronized: client-side containment of motion restarting after a fixed remote ragdoll had time to
 * settle (the Lua: corpse_data.lua M.fling_action, sample_limbs, limb_excursion, kept_pose, kept_limbs).
 *
 * A settled remote ragdoll still receiving network corrections can be flung again. Its history (by unit) holds
 * numeric identities and copied poses only: the root body's pose and each main body's pose relative to the root. It
 * starts again whenever the entity, profile, root, members or enabled count change, a sample comes 1 s or more after the
 * last, or the clock goes back. Before arming, a root that moves more than 25 cm or 10 degrees takes a new baseline; 3
 * samples over at least 1 s without that arm it (normal final corrections after the fixed transition come first). Armed,
 * a root more than 75 cm or 20 degrees from the baseline, or a non-root main body more than 50 cm or 15 degrees from its
 * relative pose on samples at least 100 ms apart, calls for the native stop. Tripods disable every main body on landing:
 * once that state has held for 3 samples over 1 s they are finished through the same stop, without reading the disabled
 * bodies. These are experimental containment thresholds, not engine limits. */
#include <string.h>
#include "ecs_internal.h"

static int SameSignature(const EcsSignature* a, const EcsSignature* b)
{
    return a->count == b->count && memcmp(a->ids, b->ids, sizeof(uint32_t) * a->count) == 0;
}

const char* EcsCauseName(int cause)
{
    switch (cause)
    {
    case ECS_CAUSE_TRANSLATION: return "translation";
    case ECS_CAUSE_ROTATION: return "rotation";
    case ECS_CAUSE_LIMB_TRANSLATION: return "limb_translation";
    case ECS_CAUSE_LIMB_ROTATION: return "limb_rotation";
    case ECS_CAUSE_LANDED_DISABLED: return "landed_disabled";
    default: return "none";
    }
}

/* The tripods' landed, all-disabled state: finished through the same native stop once it persists. */
static int LandedDisabled(const EcsUnit* u, double now, EcsStopCall* stop)
{
    EcsHistory* previous = EcsTableFind(&EcsHistories, u->unit);
    if (previous == NULL || !previous->disabled || previous->entity != u->id || previous->profile != u->profile ||
        !SameSignature(&previous->members, &u->signature) || now <= previous->last || now - previous->last > 1)
    {
        int added;
        EcsHistory* h = EcsTablePut(&EcsHistories, u->unit, &added);
        if (h == NULL) return 0;
        memset(h, 0, sizeof *h);
        h->disabled = 1;
        h->entity = u->id;
        h->profile = u->profile;
        h->members = u->signature;
        h->since = h->last = now;
        h->samples = 1;
        return 0;
    }
    previous->last = now;
    previous->samples++;
    if (previous->samples < 3 || now - previous->since < 1) return 0;
    memset(stop, 0, sizeof *stop);
    stop->actor = u->root_id;
    stop->cause = ECS_CAUSE_LANDED_DISABLED;
    return 1;
}

/* Every main body's pose relative to the root's, in main_bodies order: 1, or 0 when a pose is not rigid or a body id
 * repeats. */
static int SampleLimbs(const EcsUnit* u, const EcsPose* root, EcsPose* limbs)
{
    for (uint32_t i = 0; i < u->main_body_count; i++)
    {
        for (uint32_t j = 0; j < i; j++)
            if (u->main_bodies[j].id == u->main_bodies[i].id) return 0;
        if (!EcsRelativePose(root, u->main_bodies[i].pose, &limbs[i])) return 0;
    }
    return 1;
}

static void KeepLimbs(EcsHistory* h, const EcsUnit* u, const EcsPose* limbs)
{
    h->limb_count = u->main_body_count;
    for (uint32_t i = 0; i < u->main_body_count; i++)
    {
        EcsLimb* limb = &h->limbs[i];
        memset(limb, 0, sizeof *limb);
        limb->id = u->main_bodies[i].id;
        memcpy(limb->position, limbs[i].p, sizeof limb->position);
        memcpy(limb->rotation, limbs[i].q, sizeof limb->rotation);
    }
}

static void Begin(const EcsUnit* u, const EcsPose* root, const EcsPose* limbs, double now)
{
    int added;
    EcsHistory* h = EcsTablePut(&EcsHistories, u->unit, &added);
    if (h == NULL) return;
    memset(h, 0, sizeof *h);
    h->entity = u->id;
    h->profile = u->profile;
    h->actor = u->main_bodies[u->root_body].id;
    h->members = u->signature;
    h->enabled = u->main_enabled;
    memcpy(h->position, root->p, sizeof h->position);
    memcpy(h->rotation, root->q, sizeof h->rotation);
    KeepLimbs(h, u, limbs);
    h->since = h->last = now;
    h->samples = 1;
}

static int Restarts(const EcsHistory* h, const EcsUnit* u, double now)
{
    return h->disabled || h->entity != u->id || h->profile != u->profile || h->actor != u->main_bodies[u->root_body].id ||
        !SameSignature(&h->members, &u->signature) || h->enabled != u->main_enabled || now <= h->last || now - h->last > 1;
}

static EcsLimb* LimbOf(EcsHistory* h, uint32_t id)
{
    for (uint32_t i = 0; i < h->limb_count; i++)
        if (h->limbs[i].id == id) return &h->limbs[i];
    return NULL;
}

/* An armed sample's limbs: 1 with *stop for a main body other than the root that stays more than 0.5 m or 15 degrees
 * from its kept relative pose for at least 100 ms; 0 none; -1 when the history lacks one of the bodies. */
static int LimbExcursion(EcsHistory* h, const EcsUnit* u, const EcsPose* limbs, double now, EcsStopCall* stop)
{
    uint32_t root = u->main_bodies[u->root_body].id;
    for (uint32_t i = 0; i < u->main_body_count; i++)
    {
        uint32_t id = u->main_bodies[i].id;
        EcsLimb* old = LimbOf(h, id);
        if (old == NULL) return -1;
        double distance, degrees;
        EcsSeparation(&limbs[i], old->position, old->rotation, &distance, &degrees);
        if (id == root || !(distance > .5 || degrees > 15)) { old->excursing = 0; continue; }
        if (old->excursing && now - old->excursion_since >= .1)
        {
            stop->actor = id;
            stop->limb = 1;
            stop->limb_distance = distance;
            stop->limb_degrees = degrees;
            stop->cause = distance > .5 ? ECS_CAUSE_LIMB_TRANSLATION : ECS_CAUSE_LIMB_ROTATION;
            return 1;
        }
        if (!old->excursing) { old->excursing = 1; old->excursion_since = now; }
    }
    return 0;
}

static int Armed(EcsHistory* h, const EcsUnit* u, const EcsPose* limbs, double distance, double degrees, double now,
    EcsStopCall* stop)
{
    memset(stop, 0, sizeof *stop);
    stop->distance = distance;
    stop->degrees = degrees;
    if (distance > .75 || degrees > 20)
    {
        stop->actor = u->main_bodies[u->root_body].id;
        stop->cause = distance > .75 ? ECS_CAUSE_TRANSLATION : ECS_CAUSE_ROTATION;
        return 1;
    }
    int limb = LimbExcursion(h, u, limbs, now, stop);
    if (limb < 0) EcsTableRemove(&EcsHistories, u->unit);
    return limb > 0;
}

/* Whether the unit is a settled, remote, active ragdoll still updated by RagdollSync. */
static int Observed(const EcsUnit* u)
{
    return EcsSettled(u) && !u->corpse && u->owner == 0 && u->active == 1 && u->update_enabled == 1;
}

int EcsFlingAction(const EcsUnit* u, double now, EcsStopCall* stop)
{
    if (!Observed(u)) { EcsTableRemove(&EcsHistories, u->unit); return 0; }
    /* Tripod settings disable every main actor on landing on purpose: never read disabled bodies or resurrect them. */
    if (EcsProfiles[u->profile].finish_disabled && u->main_enabled == 0) return LandedDisabled(u, now, stop);
    EcsPose root, limbs[ECS_MAX_BODIES];
    if (u->root_body < 0 || u->main_body_count != u->main_enabled || u->main_body_count > ECS_MAX_BODIES ||
        !EcsRigid(u->main_bodies[u->root_body].pose, &root) || !SampleLimbs(u, &root, limbs))
    {
        EcsTableRemove(&EcsHistories, u->unit);
        return 0;
    }
    EcsHistory* previous = EcsTableFind(&EcsHistories, u->unit);
    if (previous == NULL || Restarts(previous, u, now)) { Begin(u, &root, limbs, now); return 0; }
    previous->last = now;
    previous->samples++;
    double distance, degrees;
    EcsSeparation(&root, previous->position, previous->rotation, &distance, &degrees);
    if (previous->armed) return Armed(previous, u, limbs, distance, degrees, now, stop);
    if (distance > .25 || degrees > 10)
    {
        memcpy(previous->position, root.p, sizeof previous->position);
        memcpy(previous->rotation, root.q, sizeof previous->rotation);
        KeepLimbs(previous, u, limbs);
        previous->since = now;
        previous->samples = 1;
    }
    else if (previous->samples >= 3 && now - previous->since >= 1)
    {
        previous->armed = 1;
        Ecs.fling_armed++;
    }
    return 0;
}
