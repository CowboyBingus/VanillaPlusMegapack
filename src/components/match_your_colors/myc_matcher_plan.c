/* Match Your Colors: matcher v12's plan (matcher.lua choice, map_group, tonal offsets, small accents and Matcher.plan),
 * 1:1. Each recolored row's desired color is its source color plus the row's own offset from its group; transfer.c
 * then fits the row's colors to it. Bands, cloth off metal and the pattern plan are in myc_matcher_bands.c. Runs on
 * the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_match.h"

#define ACCENT_SMALL 0.10
#define ACCENT_VIVID 35.0
#define ACCENT_MAX_SHARE 0.35
#define ACCENT_MIN_L 20.0
#define LARGE_AREA 0.15
#define TGT_MIN_SHARE 0.02
#define PAIR_MIN_SHARE 0.02
#define FAMILY_HUE 30.0
#define TINT_C 8.0
#define LOOK_DARK_L 30.0
#define NEUTRAL_TINT_C 5.0
#define METAL_SHIFT_L 36.6
#define TONAL_K 0.5
#define PAINT_REFLECTION 0.04

/* The share of g's hue family: g's own plus every other saturated target group within FAMILY_HUE of its hue. */
static double MycPlanFamily(const MycGroup* g, const MycItem* target)
{
    double total = g->share;
    for (int i = 0; i < target->ngroups; i++)
    {
        const MycGroup* o = target->groups[i];
        if (o != g && myc_chroma(o->ma, o->mb) >= MYC_ACCENT_C && myc_hue_gap(o->ma, o->mb, g->ma, g->mb) <= FAMILY_HUE)
            total = total + o->share;
    }
    return total;
}

static int MycPlanIsAccent(const MycGroup* g, const MycGroup* anchor, double family)
{
    double c = myc_chroma(g->ma, g->mb);
    if (g->metal) c = myc_max(c, myc_chroma(g->a, g->b));
    if (g == anchor || g->share > ACCENT_MAX_SHARE || c < MYC_ACCENT_C) return 0;
    int neutral_main = anchor != NULL && myc_is_neutral_lab(anchor->mL, anchor->ma, anchor->mb);
    return g->share <= ACCENT_SMALL || c >= ACCENT_VIVID || (family <= LARGE_AREA && neutral_main);
}

int myc_matches_source(const MycGroup* g, const MycItem* source, double min_share)
{
    for (int i = 0; i < source->ngroups; i++)
    {
        const MycGroup* s = source->groups[i];
        if (s->share >= min_share && myc_de2000(g->L, g->a, g->b, s->L, s->a, s->b) < MYC_KEEP_DE) return 1;
    }
    return 0;
}

/* The source's most visible bare-metal group for bare-metal t taking a dark color s (Match Materials off), or NULL. */
static MycGroup* MycPlanMetalEcho(const MycGroup* t, const MycGroup* s, const MycItem* source, int materials)
{
    if (materials || !t->metal || s->metal || s->L >= LOOK_DARK_L || myc_chroma(s->a, s->b) < TINT_C) return NULL;
    for (int i = 0; i < source->ngroups; i++)
        if (source->groups[i]->metal && source->groups[i]->share >= MYC_PAINT_SHARE) return source->groups[i];
    return NULL;
}

static int MycPlanSpeck(const MycGroup* t, const MycGroup* accent)
{
    return accent->share < MYC_ACCENT_SOURCE_BIG && t->share > accent->share
        && myc_hue_gap(t->ma, t->mb, accent->ma, accent->mb) > FAMILY_HUE;
}

typedef struct MycPlanWho { const MycGroup* anchor; MycGroup* accent; MycGroup* second; MycItem* source; MycItem* target; } MycPlanWho;

/* An accent that already matches a source color keeps its own; under a cape a large one takes the cape's main. */
static void MycPlanKept(MycChoice* out, const MycGroup* t, MycItem* source)
{
    if (!(source->cape_source && t->share > ACCENT_SMALL) || myc_matches_source(t, source, MYC_MAIN_COLOR)) return;
    out->src = myc_identity(source);
    out->kind = MYC_KIND_PAIR;
    out->main = 1;
}

/* What target group t takes (Lua choice): out->src NULL keeps its color. */
static void MycPlanChoice(MycChoice* out, MycGroup* t, MycGroup* s, const MycPlanWho* w)
{
    memset(out, 0, sizeof *out);
    out->t = t;
    if ((w->accent == NULL && w->second != NULL) || !MycPlanIsAccent(t, w->anchor, MycPlanFamily(t, w->target))
        || (w->accent == NULL && w->source->cape_source))
    {
        out->src = s;
        out->kind = MYC_KIND_PAIR;
        return;
    }
    if (w->accent == NULL || t->mL < ACCENT_MIN_L) return;
    if (myc_matches_source(t, w->source, PAIR_MIN_SHARE)) { MycPlanKept(out, t, w->source); return; }
    int big = t->share > ACCENT_SMALL && w->accent->share < MYC_ACCENT_SOURCE_BIG;
    int paired = big || MycPlanSpeck(t, w->accent);
    out->src = paired ? s : w->accent;
    out->kind = paired ? MYC_KIND_PAIR : MYC_KIND_ACCENT;
}

static MycLab MycPlanReflected(double L, double a, double b, double lift)
{
    double lin[3];
    myc_lab_to_linear(L, a, b, lin);
    return myc_linear_to_lab(lin[0] + lift, lin[1] + lift, lin[2] + lift);
}

/* Whether row of t becomes the paint it takes (Match Materials). */
static int MycPlanPainted(const MycGroup* t, int kind, const MycGroup* src, const MycRow* row)
{
    const MycRow* rep = src->rep;
    if (rep == NULL) return 0;
    return row->mode == 0 && row->metal && !rep->metal && (kind == MYC_KIND_ACCENT || t->share >= MYC_PAINT_SHARE);
}

/* Whether row of t becomes the metal it takes (Match Materials, v1.5). */
static int MycPlanMetallized(const MycGroup* t, const MycGroup* src, const MycRow* row, double tone)
{
    const MycRow* rep = src->rep;
    if (rep == NULL || rep->copy || !rep->metal || (rep->mode != 0 && !rep->cape)) return 0;
    if (tone < 0 || myc_is_structure(t)) return 0;
    return row->mode == 0 && !row->metal && !(row->area > 0 && row->under >= 0.5 * row->area);
}

static double MycPlanMetalShift(int source_armor, const MycGroup* src, const MycRow* row)
{
    if (!src->metal) return 0;
    double shift = source_armor ? (row->metal ? 0.0 : -2.8) : -9.4;
    return shift != 0.0 ? shift * src->L / METAL_SHIFT_L : 0;
}

static double MycPlanRowLightness(double base, double row_L, double t_L)
{
    if (base >= t_L) return base + (row_L - t_L);
    double x[3], y[3], z[3];
    myc_lab_to_linear(base, 0, 0, x);
    myc_lab_to_linear(row_L, 0, 0, y);
    myc_lab_to_linear(t_L, 0, 0, z);
    double v = x[0] * y[0] / myc_max(z[0], 1e-9);
    return myc_linear_to_lab(v, v, v).L;
}

/* A group's diffuse goal (map_group's d). */
typedef struct MycPlanDiffuse { double L, sa, sb, scale, tL, ta, tb; int glossy; } MycPlanDiffuse;

static void MycPlanDiffuseOf(const MycGroup* t, const MycGroup* src, MycPlanDiffuse* d)
{
    MycLab s, tl;
    d->glossy = myc_diffuse_colors(t, src, &s, &tl);
    d->L = s.L;
    d->tL = tl.L;
    d->ta = tl.a;
    d->tb = tl.b;
    double s_c = myc_chroma(s.a, s.b);
    if (s_c < NEUTRAL_TINT_C) { d->sa = 0; d->sb = 0; d->scale = 0; return; }
    double t_c = myc_chroma(tl.a, tl.b);
    d->sa = s.a;
    d->sb = s.b;
    d->scale = t_c > 1.0 ? myc_min(1.0, s_c / t_c) : 1.0;
}

/* What map_group's rows share: the options, the tone and the group's diffuse goal. */
typedef struct MycPlanMap { int materials, source_armor; double tone; MycPlanDiffuse d; } MycPlanMap;

static void MycPlanPairGoal(const MycRow* row, const MycGroup* src, const MycPlanDiffuse* d, int source_armor,
    double tone, MycGoal* goal)
{
    double rL = row->L, ra = row->a, rb = row->b, dif[3];
    int diffuse = d->glossy && myc_row_diffuse(row, dif);
    if (diffuse)
    {
        MycLab r = myc_linear_to_lab(myc_max(dif[0], 0), myc_max(dif[1], 0), myc_max(dif[2], 0));
        rL = r.L;
        ra = r.a;
        rb = r.b;
    }
    MycLab out;
    out.L = MycPlanRowLightness(d->L + MycPlanMetalShift(source_armor, src, row) + tone, rL, d->tL);
    out.a = d->sa + (ra - d->ta) * d->scale;
    out.b = d->sb + (rb - d->tb) * d->scale;
    if (diffuse) out = myc_with_gloss(out.L, out.a, out.b, row->cal);
    if (!row->has_cal && row->full && !(src->rep != NULL && src->rep->full))
        out = MycPlanReflected(out.L, out.a, out.b, PAINT_REFLECTION);
    goal->L = out.L;
    goal->a = out.a;
    goal->b = out.b;
}

static void MycPlanGoalSource(MycGoal* goal, int kind, const MycGroup* src)
{
    memcpy(goal->source, src->rep_key, MYC_KEY);
    goal->kind = kind;
}

/* A copied source row's goal: its color, and its finish too when the part takes the paint. */
static void MycPlanCopyGoal(MycGoal* goal, const MycGroup* src, int painted)
{
    goal->L = src->L;
    goal->a = src->a;
    goal->b = src->b;
    memcpy(goal->copy, src->rep->key, MYC_KEY);
    if (painted) memcpy(goal->finish, src->rep->key, MYC_KEY);
}

/* A part that takes the source's paint: its goal look (the seen one when there is one), calibration and finish. */
static void MycPlanPaintGoal(MycGoal* goal, const MycGroup* src)
{
    const MycRow* rep = src->rep;
    goal->L = src->has_g ? src->gL : src->L;
    goal->a = src->has_g ? src->ga : src->a;
    goal->b = src->has_g ? src->gb : src->b;
    goal->has_cal = rep->has_cal;
    memcpy(goal->cal, rep->cal, sizeof goal->cal);
    memcpy(goal->finish, rep->key, MYC_KEY);
}

/* A painted part that takes the source's bare metal: the metal's model color, its finish, a coat. */
static void MycPlanCoatGoal(MycGoal* goal, const MycGroup* src)
{
    const MycRow* rep = src->rep;
    goal->L = rep->mL;
    goal->a = rep->ma;
    goal->b = rep->mb;
    memcpy(goal->finish, rep->key, MYC_KEY);
    goal->coat = 1;
}

/* One row's goal (map_group's branches). */
static void MycPlanRow(MycGoal* goal, const MycRow* row, const MycGroup* t, int kind, const MycGroup* src,
    const MycPlanMap* map)
{
    const MycRow* rep = src->rep;
    MycPlanGoalSource(goal, kind, src);
    if (rep != NULL && rep->copy) MycPlanCopyGoal(goal, src, map->materials && MycPlanPainted(t, kind, src, row));
    else if (map->materials && MycPlanPainted(t, kind, src, row)) MycPlanPaintGoal(goal, src);
    else if (map->materials && MycPlanMetallized(t, src, row, map->tone)) MycPlanCoatGoal(goal, src);
    else
    {
        MycPlanPairGoal(row, src, &map->d, map->source_armor, map->tone, goal);
        goal->has_cal = row->has_cal;
        memcpy(goal->cal, row->cal, sizeof goal->cal);
    }
}

int myc_map_group(MycPlan* mapping, const MycGroup* t, int kind, const MycGroup* src, int materials, int source_armor,
    double tone)
{
    MycPlanMap map;
    map.materials = materials;
    map.source_armor = source_armor;
    map.tone = tone;
    MycPlanDiffuseOf(t, src, &map.d);
    for (int i = 0; i < t->nrows; i++)
    {
        MycGoal* goal = myc_plan_set(mapping, t->rows[i]->key);
        if (goal == NULL) return 0;
        MycPlanRow(goal, t->rows[i], t, kind, src, &map);
    }
    return 1;
}

/* ---- tonal offsets ----------------------------------------------------------------------------------------------- */

/* The lead of choices taking `src` (pairs, not structure): the anchor when among them, else the largest (the first of
 * equals); NULL when fewer than two take it. */
static const MycGroup* MycPlanLead(const MycChoice* choices, int n, const MycGroup* src, const MycGroup* anchor)
{
    const MycGroup* lead = NULL;
    int count = 0;
    for (int i = 0; i < n; i++)
        if (choices[i].kind == MYC_KIND_PAIR && !myc_is_structure(choices[i].t) && choices[i].src == src) count++;
    if (count < 2) return NULL;
    for (int i = 0; i < n; i++)
    {
        const MycGroup* g = choices[i].t;
        if (choices[i].kind != MYC_KIND_PAIR || myc_is_structure(g) || choices[i].src != src) continue;
        if (g == anchor) return g;
        if (lead == NULL || g->share > lead->share) lead = g;
    }
    return lead;
}

static void MycPlanTones(MycChoice* choices, int n, const MycGroup* anchor)
{
    for (int i = 0; i < n; i++)
    {
        MycChoice* c = &choices[i];
        if (c->kind != MYC_KIND_PAIR || myc_is_structure(c->t)) continue;
        const MycGroup* lead = MycPlanLead(choices, n, c->src, anchor);
        if (lead != NULL && c->t != lead) c->tone = TONAL_K * myc_min(c->t->L - lead->L, 0);
    }
}

/* ---- the plan ---------------------------------------------------------------------------------------------------- */

static int MycPlanSmallAccents(MycPlan* mapping, const MycItem* target, const MycItem* source, const MycGroup* small,
    int materials)
{
    for (int i = 0; i < target->ngroups; i++)
    {
        const MycGroup* t = target->groups[i];
        int accent = myc_chroma(t->ma, t->mb) >= MYC_ACCENT_C && t->mL >= ACCENT_MIN_L;
        if (t->share < TGT_MIN_SHARE && !t->hood && accent && !myc_matches_source(t, source, PAIR_MIN_SHARE)
            && !myc_map_group(mapping, t, MYC_KIND_ACCENT, small, materials, source->armor, 0))
            return 0;
    }
    return 1;
}

/* The choices of every pair (choice, metal_echo); how many, -1 out of memory. */
static int MycPlanChoices(MycArena* arena, const MycPairs* pairs, const MycPlanWho* w, int materials, MycChoice** out)
{
    MycChoice* choices = myc_alloc(arena, sizeof(MycChoice) * (size_t)(pairs->count + 1));
    if (choices == NULL) return -1;
    int n = 0;
    for (int i = 0; i < pairs->count; i++)
    {
        MycChoice c;
        MycPlanChoice(&c, pairs->t[i], pairs->s[i], w);
        if (c.kind == MYC_KIND_PAIR && c.src != NULL)
        {
            MycGroup* echo = MycPlanMetalEcho(c.t, c.src, w->source, materials);
            if (echo != NULL) c.src = echo;
        }
        if (c.src != NULL) choices[n++] = c;
    }
    *out = choices;
    return n;
}

static int MycPlanMapChoices(MycPlan* mapping, const MycChoice* choices, int n, const MycItem* source, int materials)
{
    for (int i = 0; i < n; i++)
        if (!myc_map_group(mapping, choices[i].t, choices[i].kind, choices[i].src, materials, source->armor, choices[i].tone))
            return 0;
    return 1;
}

/* The small accents' colors: the source's accent, else its second accent, else (a cape source) its identity color. */
static int MycPlanSmall(MycPlan* mapping, MycItem* target, MycItem* source, const MycPlanWho* w, int materials)
{
    MycGroup* small = w->accent != NULL ? w->accent : w->second;
    if (small == NULL && source->cape_source && w->anchor != NULL) small = myc_identity(source);
    return small == NULL || MycPlanSmallAccents(mapping, target, source, small, materials);
}

int myc_plan(MycPlan* mapping, MycItem* target, MycItem* source, int materials, int cape)
{
    MycPairs pairs;
    memset(&pairs, 0, sizeof pairs);
    MycGroup* anchor = NULL;
    if (!myc_pair_groups(mapping->arena, target, source, &pairs, &anchor)) return 0;
    MycPlanWho w = {anchor, myc_source_accent(source), NULL, source, target};
    if (w.accent == NULL) w.second = myc_fallback_accent(source);
    MycChoice* choices = NULL;
    int n = MycPlanChoices(mapping->arena, &pairs, &w, materials, &choices);
    if (n < 0) return 0;
    if (!cape) MycPlanTones(choices, n, anchor);
    if (!MycPlanMapChoices(mapping, choices, n, source, materials)) return 0;
    if (!myc_tint_bands(mapping, choices, n, source, w.accent, target->armor || target->weapon)) return 0;
    if (!myc_cloth_off_metal(mapping, choices, n, source, materials)) return 0;
    if (!MycPlanSmall(mapping, target, source, &w, materials)) return 0;
    if (target->armor && !cape) return myc_balance(mapping, target, source);
    return 1;
}
