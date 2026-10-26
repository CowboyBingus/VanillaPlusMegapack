/* Consistent Vaulting: fresh casts of the retained queries (vault_data.lua M.refresh, M.reproject) and the assisted
 * candidate search (M.assist_candidate: the steep-slope and higher-top passes).
 *
 * Stage 2 is inside the game's frame processing, which a check can miss entirely. At stage 3 the retained local query
 * shapes are cast again into private storage (the game's synchronous shape query), after a private copy of the
 * controller has run the original approach detector. When the approach's geometry changed, A8A140's ten-query geometry
 * is rebuilt privately from it: calling the producer itself would change the shared scheduler. Nothing here writes game
 * memory. */
#include <math.h>
#include <string.h>
#include "cv.h"

/* ---- M.reproject -------------------------------------------------------------------------------------------------- */

typedef struct Geometry { double first[3], last[3], direction[3], span, width, length; } Geometry;
typedef struct Slices { const uint8_t* matrix; double near[3], far[3], span, width, depth; } Slices;

/* The fresh approach of a complete controller copy with finite geometry: its endpoints, direction, span, width and
 * length. */
static int FreshGeometry(const CvVault* s, const uint8_t* fresh, Geometry* g)
{
    if (cv_u32(fresh + 4) != 1 || cv_u32(fresh + 684) != cv_u32(s->controller_bytes + 684) || s->hit_count != CV_HITS) return 0;
    for (uint32_t offset = 488; offset <= 528; offset += 4)
        if (!cv_finite(cv_num(fresh + offset))) return 0;
    (void)cv_vector(fresh + 488, g->first);
    (void)cv_vector(fresh + 500, g->last);
    (void)cv_vector(fresh + 520, g->direction);
    double dx = cv_f32(g->last[0] - g->first[0]), dy = cv_f32(g->last[1] - g->first[1]), dz = cv_f32(g->last[2] - g->first[2]);
    g->length = cv_f32(sqrt(cv_f32(cv_f32(cv_f32(dy * dy) + cv_f32(dx * dx)) + cv_f32(dz * dz))));
    g->span = cv_num(fresh + 512);
    g->width = cv_num(fresh + 516);
    return 1;
}

/* Span, width, length and a horizontal unit direction fit the batch. */
static int GeometryFits(const Geometry* g)
{
    const double* d = g->direction;
    double norm = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
    return !(g->span <= 0.1 || g->span > 3.5 || g->width <= 0 || g->width > 1 || g->length < 0.05 || g->length > 2 ||
        fabs(norm - 1) > 0.001 || fabs(d[2]) > 0.001);
}

/* The native forward/up basis stays horizontal and orthonormal; its translation is replaced per query. */
static int BasisMatches(const uint8_t* matrix, const double* d)
{
    const double expected[12] = {d[1], -d[0], 0, 0, d[0], d[1], 0, 0, 0, 0, 1, 0};
    for (int i = 0; i < 12; i++)
    {
        double actual = cv_num(matrix + i * 4);
        if (!cv_finite(actual) || fabs(actual - expected[i]) > 0.001) return 0;
    }
    return 1;
}

/* The first and last source positions: half a slice in from each endpoint, lowered by the box's vertical half-extent. */
static void Endpoints(const Geometry* g, Slices* slices)
{
    for (int axis = 0; axis < 3; axis++)
    {
        double shift = axis == 2 ? -cv_f32(0.05) : 0;
        double step = cv_f32(slices->depth * g->direction[axis]);
        slices->near[axis] = cv_f32(cv_f32(step + g->first[axis]) + shift);
        slices->far[axis] = cv_f32(cv_f32(g->last[axis] - step) + shift);
    }
}

/* One slot's private descriptor: the retained record with the native basis, the interpolated source and target, and the
 * slice box. */
static void ReprojectedRecord(const CvHit* hit, const Slices* slices, uint8_t* record)
{
    memcpy(record, hit->record, CV_RECORD_SIZE);
    memcpy(record + 16, slices->matrix, 64);
    double t = cv_f32(hit->slot / 9.0);
    for (int axis = 0; axis < 3; axis++)
    {
        double start = cv_f32(cv_f32(slices->near[axis] * cv_f32(1 - t)) + cv_f32(slices->far[axis] * t));
        cv_put_f32(record + 64 + axis * 4, start);
        double target = axis == 2 ? cv_f32(cv_f32(-slices->span + start) + cv_f32(cv_f32(0.05) + cv_f32(0.05))) : start;
        cv_put_f32(record + 92 + axis * 4, target);
    }
    cv_put_f32(record + 76, 1);
    cv_put_f32(record + 80, cv_f32(slices->width * 0.5));
    cv_put_f32(record + 84, slices->depth);
    cv_put_f32(record + 88, cv_f32(0.05));
}

int cv_reproject(CvVault* s, const uint8_t* fresh, const char** why)
{
    static uint8_t records[CV_HITS][CV_RECORD_SIZE];
    uint8_t matrix[64];
    Geometry g;
    Slices slices;
    if (!FreshGeometry(s, fresh, &g) || !GeometryFits(&g)) return cv_why(why, "unsupported_fresh_approach");
    cv_native_basis(g.direction, matrix);
    if (!BasisMatches(matrix, g.direction)) return cv_why(why, "unsupported_query_basis");
    slices.matrix = matrix;
    slices.span = g.span;
    slices.width = g.width;
    slices.depth = cv_f32(cv_f32(g.length / 10) * 0.5);
    Endpoints(&g, &slices);
    for (int i = 0; i < s->hit_count; i++)
    {
        if (s->hits[i].slot != i) return cv_why(why, "unsupported_fresh_approach");
        ReprojectedRecord(&s->hits[i], &slices, records[i]);
    }
    for (int i = 0; i < s->hit_count; i++) memcpy(s->hits[i].record, records[i], CV_RECORD_SIZE);
    memcpy(s->controller_bytes, fresh, CV_CONTROLLER_SIZE);
    s->reprojected = 1;
    return 1;
}

/* ---- M.refresh ---------------------------------------------------------------------------------------------------- */

static uint8_t g_fresh[CV_CONTROLLER_SIZE];

static const char* ApproachReason(int matched)
{
    if (matched == CV_APPROACH_BLOCKED) return "native_approach_blocked";
    return matched == CV_APPROACH_CHANGED ? "native_approach_geometry_changed" : NULL;
}

/* Rebuilt queries: no shared descriptor survives, so neither an old hit count nor old geometry may authorize a cast. */
static int RebuiltContext(CvVault* s, CvCounters* c, int matched, const char** why, const char** approach)
{
    if (matched == CV_APPROACH_BLOCKED)
    {
        *approach = ApproachReason(matched);
        return cv_why(why, "fresh_approach_unavailable");
    }
    if (!cv_reproject(s, g_fresh, why)) return 0;
    c->query_rebuilds++;
    c->context_reprojections++;
    return 1;
}

/* The native approach context of a refresh: 1 when the retained (or reprojected) geometry may be cast. */
static int ApproachContext(CvVault* s, CvCounters* c, const char** why, const char** approach)
{
    int matched = cv_native_context(s->controller_bytes, g_fresh);
    if (s->rebuild_queries) return RebuiltContext(s, c, matched, why, approach);
    if (matched == CV_APPROACH_CHANGED)
    {
        if (!cv_reproject(s, g_fresh, why)) return 0;
        c->context_reprojections++;
        return 1;
    }
    return matched == CV_APPROACH_MATCHED ? 1 : cv_why(why, ApproachReason(matched));
}

/* A query's source and target stay near and in front of the native mover (1.5 units horizontally, 5 vertically). */
static int CastInReach(const CvVault* s, const uint8_t* record)
{
    static const uint32_t kOffsets[2] = {64, 92};
    for (int i = 0; i < 2; i++)
    {
        double v[3];
        CV_TRY(cv_vector(record + kOffsets[i], v));
        double dx = v[0] - s->root[0], dy = v[1] - s->root[1];
        if (dx * dx + dy * dy > 2.25 || fabs(v[2] - s->root[2]) > 5 || dx * s->direction[0] + dy * s->direction[1] < -0.15)
            return 0;
    }
    return 1;
}

/* Casts a slot's query again into private storage; the hit takes the result. */
static int Recast(CvVault* s, CvCounters* c, CvHit* hit)
{
    uint8_t bytes[CV_HIT_SIZE];
    uint32_t count = cv_native_refresh(hit->record, s->world, bytes);
    c->fresh_queries++;
    return cv_hit_take(hit, bytes, count);
}

int cv_refresh(CvVault* s, CvCounters* counters, uint8_t (*originals)[CV_HIT_SIZE], const char** why, const char** approach)
{
    CV_TRY(ApproachContext(s, counters, why, approach));
    for (int i = 0; i < s->hit_count; i++)
    {
        CvHit* hit = &s->hits[i];
        memcpy(originals[i], hit->bytes, CV_HIT_SIZE);
        if (!s->rebuild_queries && hit->count != 1) continue;
        /* Retained geometry must stay near and in front of this avatar; a fresh cast keeps old hits from surviving
         * removed obstacles. */
        int reach = CastInReach(s, hit->record);
        if (reach != 1) return reach == 0 ? cv_why(why, "retained_query_out_of_reach") : reach;
        CV_TRY(Recast(s, counters, hit));
    }
    return 1;
}

/* ---- the assisted candidate search -------------------------------------------------------------------------------- */

static uint8_t g_raised[CV_CONTROLLER_SIZE]; /* the raised search's fresh approach, kept until the commit check */

static int Is(const char* reason, const char* text) { return reason != NULL && strcmp(reason, text) == 0; }

static int DefaultClimbHeight(const CvVault* s) { return s->ground && fabs(s->max_height - 1.95) < 0.001; }

/* The candidate search's snapshot of a consumed query, for the avatar the slope check verified. */
static int CandidateSnapshot(CvVault* s, const CvSlope* owner, const char** why)
{
    const CvVaultArgs args = {NULL, NULL, 1};
    const char* reason = NULL;
    int got = cv_vault_snapshot(s, &args, &reason);
    if (got == CV_RAISED) return cv_why(why, "candidate_snapshot_unavailable");
    if (got == 0 || s->stage != 3) return cv_why(why, reason != NULL ? reason : "waiting_for_consumed_query");
    return s->entity == owner->entity ? 1 : cv_why(why, "candidate_identity_changed");
}

/* A grounded avatar at the default climb height may replace a blocked, changed, out-of-reach or missing ordinary
 * approach with the independent raised search. */
static int RaisedWanted(const CvVault* s, const char* reason, const char* approach)
{
    if (!DefaultClimbHeight(s)) return 0;
    return Is(reason, "native_approach_blocked") || Is(reason, "native_approach_geometry_changed") ||
        Is(reason, "retained_query_out_of_reach") ||
        (Is(reason, "fresh_approach_unavailable") && Is(approach, "native_approach_blocked"));
}

static CvRaisedArgs RaisedArgs(const CvVault* s)
{
    CvRaisedArgs args = {s->controller_bytes, s->unit, s->mover_name, s->direction, s->ground_reach};
    return args;
}

/* The raised search's fresh approach, reprojected into the private queries. */
static int RaisedContext(CvVault* s, CvCounters* c, const char** why)
{
    CvRaisedArgs args = RaisedArgs(s);
    const char* missing = cv_native_raised(&args, g_raised);
    if (missing != NULL) return cv_why(why, missing);
    if (!cv_reproject(s, g_raised, why)) return 0;
    c->raised_approach_rebuilds++;
    return 1;
}

/* The steep-slope selection, or why not while an ordinary candidate exists. */
static int SlopePass(CvVault* s, CvSelection* selection, const char** why)
{
    CvSelection ordinary;
    int found = cv_select(s, &ordinary);
    if (found != 0) return found == 1 ? cv_why(why, "ordinary_candidate_retained") : found;
    s->normal_threshold = cv_f32(cos(cv_f32(65 * cv_f32(CV_PI / 180))));
    return cv_select(s, selection);
}

/* A downward cast's start and target stay near and in front of the native mover and the start lies above the target. */
static int RaisedInReach(const CvVault* s, const double* start, const double* target)
{
    double dx = start[0] - s->root[0], dy = start[1] - s->root[1];
    double tx = target[0] - s->root[0], ty = target[1] - s->root[1];
    return !(dx * dx + dy * dy > 2.25 || tx * tx + ty * ty > 2.25 || start[2] < target[2] ||
        fabs(start[2] - s->root[2]) > 5 || fabs(target[2] - s->root[2]) > 5 ||
        dx * s->direction[0] + dy * s->direction[1] < -0.15 || tx * s->direction[0] + ty * s->direction[1] < -0.15);
}

/* The room a query box needs above a top at the allowed surface angle: its vertical extent plus its horizontal
 * footprint's rise. 1 with *clearance, 0 unsupported, CV_RAISED. */
static int ProbeClearance(const uint8_t* record, double baseline, double* clearance)
{
    double size[3], extent = 0, horizontal = 0;
    CV_TRY(cv_vector(record + 80, size));
    for (int i = 0; i < 3; i++)
        if (size[i] <= 0 || size[i] > 0.5) return 0;
    extent = fabs(cv_num(record + 24)) * size[0] + fabs(cv_num(record + 40)) * size[1] + fabs(cv_num(record + 56)) * size[2];
    for (int axis = 0; axis < 3; axis++)
    {
        double x = cv_num(record + 16 + axis * 16), y = cv_num(record + 20 + axis * 16);
        horizontal = horizontal + sqrt(x * x + y * y) * size[axis];
    }
    if (!cv_finite(extent) || extent <= 0 || extent > 0.25 || !cv_finite(horizontal) || horizontal <= 0 ||
        horizontal > 0.5 || baseline < 0.7 || baseline > 1)
        return 0;
    *clearance = extent + horizontal * sqrt(fmax(0, 1 - baseline * baseline)) / baseline + 0.01;
    return 1;
}

/* Raises only the start of a private downward cast, anchored to the current native mover with room for the whole box
 * over a top at the allowed surface angle; its end, shape, filter, ignored unit and normals stay. */
static int RaiseHit(CvVault* s, CvCounters* c, CvHit* hit, double baseline, const char** why)
{
    double start[3], target[3], clearance = 0;
    uint8_t record[CV_RECORD_SIZE], bytes[CV_HIT_SIZE];
    CV_TRY(cv_vector(hit->record + 64, start));
    CV_TRY(cv_vector(hit->record + 92, target));
    if (!RaisedInReach(s, start, target)) return cv_why(why, "raised_query_out_of_reach");
    int fits = ProbeClearance(hit->record, baseline, &clearance);
    if (fits != 1) return fits == 0 ? cv_why(why, "unsupported_probe_extent") : fits;
    double ceiling = cv_f32(s->root[2] + s->max_height + clearance);
    if (target[2] >= ceiling) return cv_why(why, "raised_query_out_of_reach");
    memcpy(record, hit->record, CV_RECORD_SIZE);
    cv_put_f32(record + 72, ceiling);
    uint32_t count = cv_native_refresh(record, s->world, bytes);
    c->raised_queries++;
    CV_TRY(cv_hit_take(hit, bytes, count));
    memcpy(hit->record, record, CV_RECORD_SIZE);
    return 1;
}

/* The higher-top selection: every slot cast again from above the 2.5-unit allowance, at the original surface angle. */
static int LedgePass(CvVault* s, CvCounters* c, double baseline, CvSelection* selection, const char** why)
{
    s->normal_threshold = baseline;
    s->max_height = 2.5;
    s->min_height = 0.5;
    s->has_min_height = 1;
    for (int i = 0; i < s->hit_count; i++) CV_TRY(RaiseHit(s, c, &s->hits[i], baseline, why));
    return cv_select(s, selection);
}

/* The assisted candidate: *kind and the selection (1), none (0, *why NULL), a pass that gave up (0, *why), CV_RAISED.
 * The ledge pass runs for a grounded avatar at the default climb height when no steep candidate was selected. */
static int AssistedSelection(CvVault* s, CvCounters* c, int has_originals, int* kind, CvSelection* selection, const char** why)
{
    double baseline = s->normal_threshold;
    *kind = CV_KIND_SLOPE;
    if (has_originals)
    {
        int selected = SlopePass(s, selection, why);
        if (selected != 0 || *why != NULL) return selected;
    }
    if (!DefaultClimbHeight(s)) return 0;
    *kind = CV_KIND_LEDGE;
    int selected = LedgePass(s, c, baseline, selection, why);
    if (selected >= 0 && *why == NULL && !has_originals) c->raised_context_fallbacks++;
    return selected;
}

/* The raised search, repeated, returns the same context within 0.02 units. */
static int RaisedUnchanged(const CvVault* s)
{
    static uint8_t fresh[CV_CONTROLLER_SIZE];
    CvRaisedArgs args = RaisedArgs(s);
    if (cv_native_raised(&args, fresh) != NULL || cv_u32(fresh + 4) != 1 || cv_u32(fresh + 684) != cv_u32(g_raised + 684)) return 0;
    for (uint32_t offset = 488; offset <= 528; offset += 4)
    {
        double v = cv_num(fresh + offset);
        if (!cv_finite(v) || fabs(v - cv_num(g_raised + offset)) > 0.02) return 0;
    }
    return 1;
}

/* Why the candidate may not be granted (its approach context or a guard changed), else NULL. */
static const char* CommitBlocked(const CvVault* s, int raised)
{
    if (raised) { if (!RaisedUnchanged(s)) return "raised_context_changed_before_commit"; }
    else if (s->reprojected && !cv_context_still(s)) return "native_context_changed_before_commit";
    return cv_guards_hold(&s->guards, 0) ? NULL : "candidate_changed";
}

/* A higher-top discovery cast does not consume retained hits, so only this private, bounded search may go on after a
 * context rejection; ordinary and slope passes need matched or freshly rebuilt geometry. */
static int Context(CvVault* s, CvCounters* c, uint8_t (*originals)[CV_HIT_SIZE], int* raised, const char** why)
{
    const char* approach = NULL;
    int refreshed = cv_refresh(s, c, originals, why, &approach);
    if (refreshed != 0) return refreshed;
    if (RaisedWanted(s, *why, approach))
    {
        CV_TRY(RaisedContext(s, c, why));
        *raised = 1;
        return 2;
    }
    if (Is(*why, "native_approach_blocked") || Is(*why, "native_approach_geometry_changed") ||
        Is(*why, "native_approach_changed_or_blocked"))
        return 2;
    return 0;
}

int cv_assist_candidate(CvState* st, const CvSlope* owner, int* kind, const char** reason)
{
    static uint8_t originals[CV_HITS][CV_HIT_SIZE];
    CvVault* s = cv_vault_record(2);
    CvSelection selection = {-1, 0};
    const char* why = NULL;
    int raised = 0;
    CV_TRY(CandidateSnapshot(s, owner, reason));
    int context = Context(s, &st->counters, originals, &raised, reason);
    if (context < 1) return context;
    int selected = AssistedSelection(s, &st->counters, context == 1, kind, &selection, &why);
    if (selected < 0) return selected;
    if (why != NULL) return cv_why(reason, why);
    if (selected == 0) return cv_why(reason, "no_usable_assisted_candidate");
    if (cv_out_of_reach(s, &s->hits[selection.slot])) return cv_why(reason, "candidate_out_of_reach");
    why = CommitBlocked(s, raised);
    if (why != NULL) return cv_why(reason, why);
    *reason = *kind == CV_KIND_LEDGE ? "validated_raised_top" : "validated_steep_candidate";
    return 1;
}
