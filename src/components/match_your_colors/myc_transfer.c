/* Match Your Colors: the color transfer of matcher v11.1 (transfer.lua), 1:1. A target LUT row takes a desired
 * perceived color and keeps its own material: only its colors (base, detail, wear and camo columns) change, following
 * its paint by rules (tint, hue, shade, shift, tone, flat, own, camo), the new paint fitted in at most FIT_STEPS steps
 * through the row's measured response or the model. Runs on the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_match.h"

#define CLOSE_DE 20.0
#define FIT_STEPS 8
#define FIT_DONE 0.5
#define TINT_C 8.0
#define TINT_HUE 60.0
#define NEUTRAL_C 8.0
#define CHROMA_HEADROOM 10.0
#define CAMO_FLAT 0.25
#define DARKEN_FOLLOW_L 30.0
#define DARK_L 30.0
#define RESPONSE_MISS 6.0
#define FLOOR_TURN 30.0
#define DARK_ROUGH 0.67
#define NEUTRAL_GOAL_C 5.0
#define METAL_PAINT_MIN_L 45.0
#define GLOSSY_PAINT_MIN_L 20.0
#define CLOTH_PAINT_MIN_L 12.0
#define GLOSSY_ROUGH 0.5
#define ROUGHNESS 40
#define METALLIC 27
#define SHEEN 12
#define NCOLUMNS 8
#define CAMO_FIRST 4    /* COLUMNS index of column 16 */
#define ROW_DOUBLES (MYC_MAX_COLUMNS * 4)

#define RULE_NONE 0
#define RULE_TINT 1
#define RULE_HUE 2
#define RULE_SHADE 3
#define RULE_SHIFT 4
#define RULE_TONE 5
#define RULE_FLAT 6
#define RULE_OWN 7
#define RULE_CAMO 8

#define FLAT_NONE 0
#define FLAT_ALL 1
#define FLAT_COAT 2
#define FLAT_METAL 3

static const int myc_tr_columns[NCOLUMNS] = {0, 2, 5, 6, 16, 17, 18, 19};

struct MycTransfer
{
    MycModel* model;
    MycArena* arena;    /* the session's: the rows' own albedos per origin (starts) */
    MycMap starts;
};

MycTransfer* myc_transfer_new(MycArena* arena, MycModel* model)
{
    MycTransfer* tr = myc_alloc(arena, sizeof(MycTransfer));
    if (tr == NULL) return NULL;
    tr->model = model;
    tr->arena = arena;
    return tr;
}

const MycLut* myc_source_lut(const MycSourceLuts* s, uint64_t name)
{
    if (s == NULL) return NULL;
    if (s->analysis != NULL) return myc_analysis_lut(s->analysis, name);
    return s->scheme_lut != NULL && name == s->scheme_name ? s->scheme_lut : NULL;
}

/* ---- rules -------------------------------------------------------------------------------------------------------- */

typedef struct MycTrCtx { int chromatic, all, darken; double neutral_below; } MycTrCtx;

static int MycTrRuleOf(int i, const double lab[3], const double P[3], const MycTrCtx* ctx)
{
    int near = i >= CAMO_FIRST || myc_de2000(lab[0], lab[1], lab[2], P[0], P[1], P[2]) < CLOSE_DE;
    int neutral = myc_chroma(lab[1], lab[2]) < ctx->neutral_below;
    if (ctx->chromatic && !neutral)
    {
        if (myc_hue_gap(lab[1], lab[2], P[1], P[2]) <= TINT_HUE) return RULE_TINT;
        return i >= CAMO_FIRST ? RULE_HUE : RULE_NONE;
    }
    if (!near) return RULE_NONE;
    return neutral && ctx->chromatic ? RULE_SHADE : RULE_SHIFT;
}

static int MycTrAllRule(int i, int rule, const double lab[3], const MycTrCtx* ctx)
{
    if (i == 0 || myc_chroma(lab[1], lab[2]) < ctx->neutral_below) return rule;
    if (rule == RULE_TINT || rule == RULE_HUE || rule == RULE_NONE) return ctx->chromatic ? RULE_HUE : RULE_OWN;
    return rule;
}

static int MycTrColumnRule(int i, const double lab[3], const double P[3], const MycTrCtx* ctx)
{
    int rule = MycTrRuleOf(i, lab, P, ctx);
    if (rule == RULE_NONE && ctx->darken && myc_chroma(lab[1], lab[2]) < ctx->neutral_below)
        rule = ctx->chromatic ? RULE_SHADE : RULE_SHIFT;
    if (i == 0 && rule == RULE_NONE) rule = ctx->chromatic ? RULE_TINT : RULE_SHIFT;
    if (ctx->all) rule = MycTrAllRule(i, rule, lab, ctx);
    return rule;
}

/* rules[i] (RULE_NONE: the color stays) and labs[i] for row c with paint P toward D. */
static void MycTrRules(const double* c, const double P[3], const double D[3], int flat, int rules[NCOLUMNS],
    double labs[NCOLUMNS][3])
{
    double paint_c = myc_chroma(P[1], P[2]);
    MycTrCtx ctx;
    ctx.all = flat == FLAT_ALL;
    ctx.chromatic = paint_c >= TINT_C;
    ctx.neutral_below = ctx.chromatic ? myc_min(NEUTRAL_C, 0.5 * paint_c) : NEUTRAL_C;
    ctx.darken = P[0] - D[0] >= DARKEN_FOLLOW_L;
    int count = c[87] >= 0 ? NCOLUMNS : CAMO_FIRST;
    for (int i = 0; i < NCOLUMNS; i++) rules[i] = RULE_NONE;
    for (int i = 0; i < count; i++)
    {
        int o = myc_tr_columns[i] * 4;
        MycLab lab = myc_srgb_to_lab(c[o], c[o + 1], c[o + 2]);
        double l3[3] = {lab.L, lab.a, lab.b};
        rules[i] = MycTrColumnRule(i, l3, P, &ctx);
        memcpy(labs[i], l3, sizeof l3);
    }
    for (int i = CAMO_FIRST; i < count; i++) rules[i] = ctx.all ? RULE_CAMO : (ctx.chromatic ? RULE_HUE : RULE_TONE);
    if (ctx.all && count > CAMO_FIRST) rules[0] = RULE_CAMO;
    for (int i = 0; i < NCOLUMNS; i++)
    {
        if (rules[i] == RULE_NONE) continue;
        if (flat == FLAT_COAT || flat == FLAT_METAL) rules[i] = RULE_FLAT;
        else if (myc_chroma(D[1], D[2]) < TINT_C && rules[i] != RULE_OWN && rules[i] != RULE_CAMO) rules[i] = RULE_TONE;
    }
}

/* A color's new CIELAB when the paint goes from P to T. */
static void MycTrFollow(const double lab[3], int rule, const double P[3], const double T[3], double out[3])
{
    double L = lab[0] + (T[0] - P[0]);
    double cc, h;
    switch (rule)
    {
    case RULE_SHIFT: out[0] = L; out[1] = lab[1] + (T[1] - P[1]); out[2] = lab[2] + (T[2] - P[2]); return;
    case RULE_TONE: out[0] = L; out[1] = T[1]; out[2] = T[2]; return;
    case RULE_FLAT: out[0] = T[0]; out[1] = T[1]; out[2] = T[2]; return;
    case RULE_TINT:
        cc = myc_chroma(lab[1], lab[2]) * (myc_chroma(T[1], T[2]) / myc_chroma(P[1], P[2]));
        h = atan2(lab[2], lab[1]) + (atan2(T[2], T[1]) - atan2(P[2], P[1]));
        out[0] = L; out[1] = cc * cos(h); out[2] = cc * sin(h);
        return;
    case RULE_HUE:
        cc = myc_chroma(lab[1], lab[2]) * myc_chroma(T[1], T[2]) / myc_chroma(P[1], P[2]);
        h = atan2(T[2], T[1]);
        out[0] = L; out[1] = cc * cos(h); out[2] = cc * sin(h);
        return;
    case RULE_OWN:
        cc = myc_chroma(T[1], T[2]);
        h = cc > 0 ? myc_min(1, myc_chroma(lab[1], lab[2]) / cc) : 0;
        out[0] = lab[0]; out[1] = T[1] * h; out[2] = T[2] * h;
        return;
    case RULE_CAMO: out[0] = T[0] + CAMO_FLAT * (lab[0] - P[0]); out[1] = T[1]; out[2] = T[2]; return;
    default: out[0] = L; out[1] = lab[1]; out[2] = lab[2]; return;
    }
}

static void MycTrFlatSheen(double* c, double a, double b)
{
    if (fabs(c[3] - 1) >= 0.5) return;
    int o = SHEEN * 4;
    MycLab l = myc_srgb_to_lab(c[o], c[o + 1], c[o + 2]);
    double lab[3] = {l.L, l.a, l.b}, T[3] = {l.L, a, b}, out[3];
    MycTrFollow(lab, RULE_OWN, lab, T, out);
    myc_lab_to_srgb(out[0], out[1], out[2], &c[o]);
}

static void MycTrCapChroma(double T[3], const double D[3], int metal)
{
    double dc = myc_chroma(D[1], D[2]);
    double limit = (metal || dc < TINT_C) ? dc : dc * 1.5 + CHROMA_HEADROOM;
    double cc = myc_chroma(T[1], T[2]);
    if (cc > limit)
    {
        T[1] = T[1] * (limit / cc);
        T[2] = T[2] * (limit / cc);
    }
}

static double MycTrPaintFloor(double paint_L, int metal, int glossy, int cloth)
{
    if (metal) return myc_min(paint_L, METAL_PAINT_MIN_L);
    if (cloth) return myc_min(paint_L, CLOTH_PAINT_MIN_L);
    if (glossy) return myc_min(paint_L, GLOSSY_PAINT_MIN_L);
    return -INFINITY;
}

/* ---- the fit ------------------------------------------------------------------------------------------------------ */

/* A row being fitted: its values, its own albedo when known (the row as copied: starts), and the response. */
typedef struct MycTrRow { double c[ROW_DOUBLES]; const double* own; } MycTrRow;
typedef struct MycTrFit { double L, a, b; const double* cal; int base_only, flat; } MycTrFit;

static MycLab MycTrLook(MycTransfer* tr, const double* c, const double* cal)
{
    if (cal == NULL) return myc_perceived(tr->model, c);
    int soft = fabs(c[3] - 1) < 0.5 && fabs(c[32]) < 0.05;
    return myc_look(tr->model, c, cal, soft);
}

static MycLab MycTrLookFrom(const double* c, const double* cal, double r, double g, double b)
{
    if (cal == NULL) return myc_perceived_of(c, r, g, b, NULL);
    int soft = fabs(c[3] - 1) < 0.5 && fabs(c[32]) < 0.05;
    return myc_look_of(r, g, b, cal, soft);
}

static void MycTrOwnAlbedo(MycTransfer* tr, const MycTrRow* row, double out[3])
{
    if (row->own != NULL) memcpy(out, row->own, sizeof(double) * 3);
    else myc_albedo(tr->model, row->c, out);
}

static void MycTrPaintWith(double* c, const int* rules, double labs[NCOLUMNS][3], const double P[3], const double T[3])
{
    for (int i = 0; i < NCOLUMNS; i++)
    {
        if (rules[i] == RULE_NONE) continue;
        double lab[3];
        MycTrFollow(labs[i], rules[i], P, T, lab);
        myc_lab_to_srgb(lab[0], lab[1], lab[2], &c[myc_tr_columns[i] * 4]);
    }
}

static void MycTrColors(const double* c, const int* rules, double out[NCOLUMNS][3])
{
    for (int i = 0; i < NCOLUMNS; i++)
        if (rules[i] != RULE_NONE) memcpy(out[i], &c[myc_tr_columns[i] * 4], sizeof(double) * 3);
}

/* The next paint T after a step that reached look g (or the first, from the row's own look). */
static void MycTrStep(double T[3], const double from[3], const MycLab* g, const MycTrFit* f, const double D[3], int neutral,
    int metal, double floor)
{
    if (neutral && from == T)
    {
        T[0] = myc_max(T[0] + (f->L - g->L), floor);
        return;
    }
    double next[3] = {myc_max(from[0] + (f->L - g->L), floor), from[1] + (f->a - g->a), from[2] + (f->b - g->b)};
    MycTrCapChroma(next, D, metal);
    memcpy(T, next, sizeof next);
}

/* Fits row (its c written with the best colors); returns the error, the look reached in reached (or NULL). */
static double MycTrFitRow(MycTransfer* tr, MycTrRow* row, const MycTrFit* f, MycLab* reached)
{
    double* c = row->c;
    double D[3] = {f->L, f->a, f->b}, alb[3], P[3], labs[NCOLUMNS][3], best[NCOLUMNS][3];
    int rules[NCOLUMNS];
    MycTrOwnAlbedo(tr, row, alb);
    row->own = NULL;
    MycLab p = myc_linear_to_lab(alb[0], alb[1], alb[2]);
    P[0] = p.L; P[1] = p.a; P[2] = p.b;
    MycTrRules(c, P, D, f->flat, rules, labs);
    if (f->base_only)
        for (int i = 1; i < NCOLUMNS; i++) rules[i] = RULE_NONE;
    int neutral = f->cal == NULL && myc_chroma(f->a, f->b) < NEUTRAL_GOAL_C, metal = c[27] > 0.5;
    double floor = f->flat == FLAT_METAL ? -INFINITY : MycTrPaintFloor(P[0], metal, c[40] < GLOSSY_ROUGH, myc_is_soft(c));
    MycLab look = MycTrLookFrom(c, f->cal, alb[0], alb[1], alb[2]), best_look = look;
    double T[3];
    MycTrStep(T, P, &look, f, D, 0, metal, floor);
    if (neutral) { T[1] = f->a; T[2] = f->b; }
    double best_err = myc_de2000(look.L, look.a, look.b, f->L, f->a, f->b);
    if (best_err != best_err) best_err = INFINITY;
    MycTrColors(c, rules, best);
    for (int step = 0; step < FIT_STEPS; step++)
    {
        MycTrPaintWith(c, rules, labs, P, T);
        MycLab g = MycTrLook(tr, c, f->cal);
        double err = myc_de2000(g.L, g.a, g.b, f->L, f->a, f->b);
        if (err < best_err) { best_err = err; best_look = g; MycTrColors(c, rules, best); }
        if (err < FIT_DONE) break;
        MycTrStep(T, T, &g, f, D, neutral, metal, floor);
    }
    for (int i = 0; i < NCOLUMNS; i++)
        if (rules[i] != RULE_NONE) memcpy(&c[myc_tr_columns[i] * 4], best[i], sizeof(double) * 3);
    if (f->flat == FLAT_ALL && !(f->cal != NULL || f->base_only)) MycTrFlatSheen(c, f->a, f->b);
    if (reached != NULL) *reached = best_look;
    return best_err;
}

double myc_transfer_fit_base(MycTransfer* tr, const float* values, int width, int row, const double tint[3],
    const MycGoal* goal, double out[3])
{
    MycTrRow r;
    myc_row_values(values, width, row, r.c);
    r.own = NULL;
    memcpy(r.c, tint, sizeof(double) * 3);
    MycTrFit f = {goal->L, goal->a, goal->b, goal->has_cal ? goal->cal : NULL, 1, FLAT_NONE};
    double err = MycTrFitRow(tr, &r, &f, NULL);
    memcpy(out, r.c, sizeof(double) * 3);
    return err;
}

/* ---- apply -------------------------------------------------------------------------------------------------------- */

/* Transfer.diffuse_goal: the goal less the gloss its response shows at it (a band's or coat's as it is). */
static MycLab MycTrDiffuseGoal(const MycGoal* goal)
{
    MycLab out = {goal->L, goal->a, goal->b};
    if (!goal->has_cal || goal->band || goal->coat) return out;
    double w = myc_min(myc_max(1 - myc_chroma(goal->a, goal->b) / MYC_GLOSS_C, 0), 1), lin[3];
    myc_lab_to_linear(goal->L, goal->a, goal->b, lin);
    return myc_linear_to_lab(myc_max(lin[0] - w * goal->cal[3], 0), myc_max(lin[1] - w * goal->cal[4], 0),
        myc_max(lin[2] - w * goal->cal[5], 0));
}

static int MycTrNotPaintD(const double* v) { return (fabs(v[3] - 1) < 0.5 && fabs(v[32]) < 0.05) || v[METALLIC] > 0.5; }
static int MycTrNotPaintF(const float* v) { return (fabs(v[3] - 1.0) < 0.5 && fabs((double)v[32]) < 0.05) || v[METALLIC] > 0.5; }

static double MycTrPaintL(MycTransfer* tr, const MycTrRow* row)
{
    double alb[3];
    MycTrOwnAlbedo(tr, row, alb);
    return myc_linear_to_lab(alb[0], alb[1], alb[2]).L;
}

/* The roughness a light hard paint turned dark takes (dark_finish), or -1. */
static double MycTrDarkFinish(MycTransfer* tr, const MycTrRow* row, const MycGoal* goal, const MycSourceLuts* source, double dL)
{
    const double* c = row->c;
    if (goal->kind != MYC_KIND_PAIR || source == NULL || goal->source[0] == 0 || dL >= DARK_L) return -1;
    if (source->cloth)
    {
        if (MycTrNotPaintD(c) || c[ROUGHNESS] >= DARK_ROUGH || MycTrPaintL(tr, row) - dL < DARKEN_FOLLOW_L) return -1;
        return DARK_ROUGH;
    }
    if (goal->all) return -1;
    uint64_t lut;
    int r;
    const MycLut* spec = myc_split_key(goal->source, &lut, &r) ? myc_source_lut(source, lut) : NULL;
    if (spec == NULL || spec->width <= 10) return -1;
    const float* v = spec->values + (size_t)r * (size_t)spec->width * 4;
    if (MycTrNotPaintD(c) || MycTrNotPaintF(v) || v[ROUGHNESS] <= c[ROUGHNESS]) return -1;
    if (MycTrPaintL(tr, row) - dL < DARKEN_FOLLOW_L) return -1;
    return v[ROUGHNESS];
}

/* Whether a fit through response cal is done again through the model (refit). */
static int MycTrRefit(MycTransfer* tr, const double* c, const double* cal, double err, const MycTrFit* f)
{
    if (err >= RESPONSE_MISS) return 1;
    if (myc_chroma(f->a, f->b) < NEUTRAL_GOAL_C || myc_linear_to_lab(cal[3], cal[4], cal[5]).L <= f->L) return 0;
    double alb[3];
    myc_albedo(tr->model, c, alb);
    MycLab p = myc_linear_to_lab(alb[0], alb[1], alb[2]);
    return myc_chroma(p.a, p.b) >= NEUTRAL_GOAL_C && myc_hue_gap(p.a, p.b, f->a, f->b) >= FLOOR_TURN;
}

/* The row's own albedo as copied from origin (starts), made once per origin and row; NULL out of memory. */
static const double* MycTrStart(MycTransfer* tr, const MycLut* origin, int row, const double* c)
{
    uint64_t key = ((uint64_t)(uintptr_t)origin->values << 8) | (uint64_t)(row & 0xFF);
    double* s = myc_map_get(&tr->starts, key);
    if (s != NULL) return s;
    s = myc_alloc(tr->arena, sizeof(double) * 3);
    if (s == NULL) return NULL;
    myc_albedo(tr->model, c, s);
    if (!myc_map_put(tr->arena, &tr->starts, key, s)) return NULL;
    return s;
}

static void MycTrWriteRow(float* values, size_t base, const double* c, const MycGoal* goal, double rough)
{
    for (int i = 0; i < NCOLUMNS; i++)
    {
        int o = myc_tr_columns[i] * 4;
        for (int ch = 0; ch < 3; ch++) values[base + (size_t)o + (size_t)ch] = (float)c[o + ch];
    }
    if (goal->all)
        for (int ch = 0; ch < 3; ch++) values[base + SHEEN * 4 + (size_t)ch] = (float)c[SHEEN * 4 + ch];
    if (rough >= 0) values[base + ROUGHNESS] = (float)rough;
}

double myc_transfer_apply(MycTransfer* tr, float* values, int width, int row, const MycGoal* goal,
    const MycSourceLuts* source, const MycLut* origin)
{
    MycTrRow r;
    myc_row_values(values, width, row, r.c);
    const double* start = origin != NULL && row < 256 ? MycTrStart(tr, origin, row, r.c) : NULL;
    r.own = start;
    int flat = goal->all ? FLAT_ALL : (goal->band ? FLAT_COAT : (goal->coat ? FLAT_METAL : FLAT_NONE));
    MycLab d = MycTrDiffuseGoal(goal);
    double rough = flat != FLAT_COAT && flat != FLAT_METAL ? MycTrDarkFinish(tr, &r, goal, source, d.L) : -1;
    if (rough >= 0) { r.c[ROUGHNESS] = rough; r.own = NULL; }
    const double* cal = flat != FLAT_COAT && flat != FLAT_METAL && goal->has_cal ? goal->cal : NULL;
    double rough_cal[6];
    MycTrFit f = {d.L, d.a, d.b, NULL, 0, flat};
    if (cal != NULL && rough >= 0)
    {
        rough_cal[0] = cal[0]; rough_cal[1] = cal[1]; rough_cal[2] = cal[2];
        rough_cal[3] = 0; rough_cal[4] = 0; rough_cal[5] = 0;
        f.cal = rough_cal;
    }
    else if (cal != NULL)
    {
        f = (MycTrFit){goal->L, goal->a, goal->b, cal, 0, flat};
    }
    double err = MycTrFitRow(tr, &r, &f, NULL);
    if (f.cal != NULL && MycTrRefit(tr, r.c, f.cal, err, &f))
    {
        myc_row_values(values, width, row, r.c);
        r.own = start;
        MycTrFit m = {d.L, d.a, d.b, NULL, 0, flat};
        err = MycTrFitRow(tr, &r, &m, NULL);
    }
    MycTrWriteRow(values, (size_t)row * (size_t)width * 4, r.c, goal, rough);
    return err;
}
