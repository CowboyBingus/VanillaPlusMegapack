/* Enemy Collision Synchronized: the catalogue's lookups, matrices and rigid poses, and the repair planner (the Lua:
 * corpse_data.lua rigid_values, separation, relative_pose, M.plan). Pure arithmetic on copied bytes: no reads, no
 * Windows calls. The arithmetic is the Lua's, in the same order, in doubles. */
#include <math.h>
#include <string.h>
#include "ecs_internal.h"

/* ---- the catalogue ----------------------------------------------------------------------------------------------- */

int EcsProfileOf(uint64_t resource)
{
    for (int i = 0; i < ECS_PROFILE_COUNT; i++)
        if (EcsProfiles[i].resource == resource) return i;
    return -1;
}

static int Listed(const uint32_t* list, uint32_t count, uint32_t name)
{
    for (uint32_t i = 0; i < count; i++)
        if (list[i] == name) return 1;
    return 0;
}

int EcsProfileMain(const EcsProfile* profile, uint32_t name) { return Listed(profile->main, profile->bodies, name); }
int EcsProfileDisabledMain(const EcsProfile* profile, uint32_t name) { return Listed(profile->disabled_main, profile->disabled_count, name); }
int EcsProfileDynamicMain(const EcsProfile* profile, uint32_t name) { return Listed(profile->dynamic_main, profile->dynamic_count, name); }

int EcsProfileActor(const EcsProfile* profile, uint32_t name, uint32_t* node)
{
    uint32_t low = 0, high = profile->actor_count;
    while (low < high)
    {
        uint32_t middle = low + (high - low) / 2;
        if (profile->actors[middle].name < name) low = middle + 1;
        else high = middle;
    }
    if (low >= profile->actor_count || profile->actors[low].name != name) return 0;
    *node = profile->actors[low].node;
    return 1;
}

int EcsClaw(uint32_t name) { return name == 0x92D0871Fu || name == 0x6635646Bu || name == 0x50B19C0Au; }

/* ---- matrices and rigid poses ------------------------------------------------------------------------------------ */

void EcsDecodeMatrix(const uint8_t* bytes, double out[16])
{
    for (int i = 0; i < 16; i++)
    {
        float value;
        memcpy(&value, bytes + i * 4, 4);
        out[i] = (double)value;
    }
}

double EcsDegrees(double radians) { return radians * (180.0 / 3.14159265358979323846); }

/* The Lua's finite(): a number, not NaN, below 100000 in magnitude. */
static int Finite(double n) { return n == n && fabs(n) < 100000.0; }

static int Unit3(double a, double b, double c, double out[3])
{
    double n = sqrt(a * a + b * b + c * c);
    if (!Finite(n) || n < 0.001) return 0;
    out[0] = a / n;
    out[1] = b / n;
    out[2] = c / n;
    return 1;
}

/* Orthogonal within .025 and right-handed (cross(x, y) . z at least .99). */
static int Orthonormal(const double x[3], const double y[3], const double z[3])
{
    if (fabs(x[0] * y[0] + x[1] * y[1] + x[2] * y[2]) > .025 || fabs(x[0] * z[0] + x[1] * z[1] + x[2] * z[2]) > .025 ||
        fabs(y[0] * z[0] + y[1] * z[1] + y[2] * z[2]) > .025)
        return 0;
    double c1 = x[1] * y[2] - x[2] * y[1], c2 = x[2] * y[0] - x[0] * y[2], c3 = x[0] * y[1] - x[1] * y[0];
    if (c1 * z[0] + c2 * z[1] + c3 * z[2] < .99) return 0;
    return 1;
}

/* Column-major basis to an XYZW quaternion (unnormalised), as the Lua's four branches. */
static void Quaternion(const double x[3], const double y[3], const double z[3], double q[4])
{
    double trace = x[0] + y[1] + z[2], s;
    if (trace > 0)
    {
        s = sqrt(trace + 1) * 2;
        q[0] = (y[2] - z[1]) / s; q[1] = (z[0] - x[2]) / s; q[2] = (x[1] - y[0]) / s; q[3] = s / 4;
    }
    else if (x[0] > y[1] && x[0] > z[2])
    {
        s = sqrt(1 + x[0] - y[1] - z[2]) * 2;
        q[0] = s / 4; q[1] = (y[0] + x[1]) / s; q[2] = (z[0] + x[2]) / s; q[3] = (y[2] - z[1]) / s;
    }
    else if (y[1] > z[2])
    {
        s = sqrt(1 + y[1] - x[0] - z[2]) * 2;
        q[0] = (y[0] + x[1]) / s; q[1] = s / 4; q[2] = (z[1] + y[2]) / s; q[3] = (z[0] - x[2]) / s;
    }
    else
    {
        s = sqrt(1 + z[2] - x[0] - y[1]) * 2;
        q[0] = (z[0] + x[2]) / s; q[1] = (z[1] + y[2]) / s; q[2] = s / 4; q[3] = (x[1] - y[0]) / s;
    }
}

int EcsRigid(const double m[16], EcsPose* out)
{
    static const int fields[12] = {0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14};
    for (int i = 0; i < 12; i++)
        if (!Finite(m[fields[i]])) return 0;
    double x[3], y[3], z[3], q[4];
    if (!Unit3(m[0], m[1], m[2], x) || !Unit3(m[4], m[5], m[6], y) || !Unit3(m[8], m[9], m[10], z)) return 0;
    if (!Orthonormal(x, y, z)) return 0;
    Quaternion(x, y, z, q);
    double length = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (!Finite(length) || length < .001) return 0;
    out->p[0] = m[12];
    out->p[1] = m[13];
    out->p[2] = m[14];
    for (int i = 0; i < 4; i++) out->q[i] = q[i] / length;
    return 1;
}

void EcsSeparation(const EcsPose* pose, const double position[3], const double rotation[4], double* distance, double* degrees)
{
    double dx = pose->p[0] - position[0], dy = pose->p[1] - position[1], dz = pose->p[2] - position[2];
    *distance = sqrt(dx * dx + dy * dy + dz * dz);
    double cosine = fabs(pose->q[0] * rotation[0] + pose->q[1] * rotation[1] + pose->q[2] * rotation[2] + pose->q[3] * rotation[3]);
    if (!(cosine < 1)) cosine = 1;
    *degrees = EcsDegrees(2 * acos(cosine));
}

/* The inverse root rotation applied to the displacement, and conjugate(root) times the body's rotation: a coherent
 * whole-corpse turn is not flapping. */
int EcsRelativePose(const EcsPose* root, const double m[16], EcsPose* out)
{
    EcsPose b;
    if (!EcsRigid(m, &b)) return 0;
    double x = -root->q[0], y = -root->q[1], z = -root->q[2], w = root->q[3];
    double dx = b.p[0] - root->p[0], dy = b.p[1] - root->p[1], dz = b.p[2] - root->p[2];
    double tx = 2 * (y * dz - z * dy), ty = 2 * (z * dx - x * dz), tz = 2 * (x * dy - y * dx);
    double qx = b.q[0], qy = b.q[1], qz = b.q[2], qw = b.q[3];
    out->p[0] = dx + w * tx + y * tz - z * ty;
    out->p[1] = dy + w * ty + z * tx - x * tz;
    out->p[2] = dz + w * tz + x * ty - y * tx;
    out->q[0] = w * qx + x * qw + y * qz - z * qy;
    out->q[1] = w * qy - x * qz + y * qw + z * qx;
    out->q[2] = w * qz + x * qy - y * qx + z * qw;
    out->q[3] = w * qw - x * qx - y * qy - z * qz;
    return 1;
}

/* ---- the repair planner (M.plan) --------------------------------------------------------------------------------- */

int EcsSettled(const EcsUnit* unit)
{
    if (unit->profile < 0 || unit->profile >= ECS_PROFILE_COUNT || !unit->settled) return 0;
    const EcsProfile* profile = &EcsProfiles[unit->profile];
    return unit->main_enabled + unit->main_disabled == profile->bodies && unit->main_static == unit->main_enabled;
}

/* Recorded assault-walker Corpses keep a dynamic torso and rocket pods; they must not block auxiliary repair on the
 * fixed base. Corpse-only: it never relaxes the ragdoll stop and completion gates. */
static int MixedCorpse(const EcsUnit* unit, const EcsProfile* profile)
{
    return profile->dynamic_count > 0 && unit->corpse && unit->settled &&
        unit->main_enabled + unit->main_disabled == profile->bodies && unit->main_static > 0 &&
        unit->main_static + unit->main_dynamic_allowed == unit->main_enabled;
}

/* A static, misplaced auxiliary collider: 1 with the pose command filled. 2.5 cm and half a degree leave an aligned
 * collider alone; there is no upper gap cutoff (the recorded 27 m failure must stay repairable). */
static int PoseAction(const EcsActor* actor, EcsAction* action)
{
    EcsPose node, now;
    if (!EcsRigid(actor->node_pose, &node) || !EcsRigid(actor->pose, &now)) return 0;
    double dx = node.p[0] - now.p[0], dy = node.p[1] - now.p[1], dz = node.p[2] - now.p[2];
    double distance = sqrt(dx * dx + dy * dy + dz * dz);
    double rotation = fabs(node.q[0] * now.q[0] + node.q[1] * now.q[1] + node.q[2] * now.q[2] + node.q[3] * now.q[3]);
    if (!(distance > .025 || rotation < .9999904807207345)) return 0;
    action->kind = ECS_REPOSE;
    memcpy(action->position, node.p, sizeof node.p);
    memcpy(action->rotation, node.q, sizeof node.q);
    action->gap = distance;
    action->degrees = EcsDegrees(2 * acos(rotation < 1 ? rotation : 1));
    return 1;
}

static int Candidate(const EcsProfile* profile, const EcsActor* actor)
{
    uint32_t node;
    return actor->enabled && !actor->registered && EcsProfileActor(profile, actor->name, &node) && node == actor->node_hash;
}

uint32_t EcsPlan(const EcsUnit* unit, EcsAction* actions)
{
    if (unit->profile < 0 || unit->profile >= ECS_PROFILE_COUNT) return 0;
    const EcsProfile* profile = &EcsProfiles[unit->profile];
    if (!EcsSettled(unit) && !MixedCorpse(unit, profile)) return 0;
    uint32_t n = 0;
    for (uint32_t i = 0; i < unit->actor_count && n < ECS_MAX_ACTORS; i++)
    {
        const EcsActor* actor = &unit->actors[i];
        if (!Candidate(profile, actor)) continue;
        if (profile->impaler && EcsClaw(actor->name))
        {
            memset(&actions[n], 0, sizeof actions[n]);
            actions[n].kind = ECS_DISABLE;
            actions[n++].actor = i;
        }
        else if (actor->motion == 0 && !actor->same_pose && PoseAction(actor, &actions[n]))
            actions[n++].actor = i;
    }
    return n;
}
