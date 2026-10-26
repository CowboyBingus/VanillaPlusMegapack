/* Match Your Colors: matcher v12's accent bands (tint_bands), cloth off metal and the pattern plan (matcher.lua), 1:1.
 * A painted hard target part of PAINT_SHARE to BAND_MAX_SHARE showing a color of its own, paired with a neutral source
 * color, takes the source accent's paint as a flat coat; cloth paired with a colored metal takes the nearest non-metal
 * palette color; target patterns take the source's accent, neutral or band coat. Runs on the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_match.h"

#define PAIR_MIN_SHARE 0.02
#define ACCENT_MIN_L 20.0
#define TINT_C 8.0
#define OWN_COLOR_C 9.0
#define BLACK_C 4.0
#define BAND_MAX_SHARE 0.4
#define LIGHT_BAND_L 45.0
#define DARK_PAIR_L 30.0
#define BAND_ARMOR_MIN_SHARE 0.10
#define LIGHT_PATTERN_L 40.0
#define PALETTE_LIMIT 8

static int MycBandsHard(const MycGroup* g)
{
    double hard = 0.0, all = 0.0;
    for (int i = 0; i < g->nrows; i++)
    {
        all = all + g->rows[i]->area;
        hard = hard + (g->rows[i]->mode == 0 ? g->rows[i]->area : 0);
    }
    return (all > 0 && hard >= 0.5 * all) || (all <= 0 && g->rep != NULL && g->rep->mode == 0);
}

static int MycBandsPair(const MycChoice* c, const MycGroup* largest)
{
    const MycGroup* t = c->t;
    return c->kind == MYC_KIND_PAIR && !c->main && t != largest && t->share <= BAND_MAX_SHARE && t->under < 0.5 * t->area
        && MycBandsHard(t) && myc_chroma(c->src->ma, c->src->mb) < BLACK_C;
}

static int MycBandsPart(const MycChoice* c, const MycGroup* largest)
{
    const MycGroup* t = c->t;
    int own = myc_chroma(t->ma, t->mb) >= OWN_COLOR_C || (t->L >= LIGHT_BAND_L && c->src->L < DARK_PAIR_L);
    return MycBandsPair(c, largest) && t->share >= MYC_PAINT_SHARE && own;
}

static int MycBandsOf(const MycGroup* t, MycGroup* const* bands, int n)
{
    for (int i = 0; i < n; i++)
    {
        const MycGroup* b = bands[i];
        if (b == t || (b->metal == t->metal && myc_de2000(t->mL, t->ma, t->mb, b->mL, b->ma, b->mb) < MYC_KEEP_DE)) return 1;
    }
    return 0;
}

static MycGroup* MycBandsGroup(const MycItem* source, double least)
{
    MycGroup* best = NULL;
    for (int i = 0; i < source->ngroups; i++)
    {
        MycGroup* g = source->groups[i];
        double c = myc_chroma(g->ma, g->mb);
        int more = best == NULL || c > myc_chroma(best->ma, best->mb);
        if (g->share >= myc_max(PAIR_MIN_SHARE, least) && c >= MYC_ACCENT_C && more) best = g;
    }
    return best;
}

/* The most salient colored light or lens of the source (a pseudo color of its model color), or NULL. */
static MycGroup* MycBandsLight(MycArena* arena, const MycItem* source)
{
    const MycRow* best = NULL;
    double weight = 0;
    for (int i = 0; i < source->nrows; i++)
    {
        const MycRow* row = &source->rows[i];
        double c = myc_chroma(row->ma, row->mb);
        double w = myc_light(row) && c >= MYC_ACCENT_C ? row->tex_area * c : 0;
        if (w > weight) { best = row; weight = w; }
    }
    if (best == NULL) return NULL;
    MycGroup* g = myc_alloc(arena, sizeof(MycGroup));
    if (g == NULL) return NULL;
    g->kind = MYC_PSEUDO;
    g->L = g->mL = best->mL;
    g->a = g->ma = best->ma;
    g->b = g->mb = best->mb;
    return g;
}

static MycGroup* MycBandsHue(MycArena* arena, MycItem* source, MycGroup* accent, int armor)
{
    double least = armor ? BAND_ARMOR_MIN_SHARE : 0;
    if (accent != NULL && myc_chroma(accent->ma, accent->mb) >= MYC_ACCENT_C && accent->share >= least) return accent;
    MycGroup* g = MycBandsGroup(source, least);
    if (g == NULL && !armor) g = MycBandsLight(arena, source);
    return g;
}

/* A band's rows take the accent's paint as a flat coat; the pair's source and finish stay (a metal coat dropped). */
static void MycBandsCoat(MycPlan* mapping, const MycGroup* t, const MycGroup* accent)
{
    for (int i = 0; i < t->nrows; i++)
    {
        MycGoal* m = myc_plan_get(mapping, t->rows[i]->key);
        if (m == NULL) continue;
        m->L = accent->mL;
        m->a = accent->ma;
        m->b = accent->mb;
        m->band = 1;
        memcpy(m->shows, accent->rep_key, MYC_KEY);
        if (m->coat) { m->coat = 0; m->finish[0] = 0; }
    }
}

int myc_tint_bands(MycPlan* mapping, const MycChoice* choices, int n, MycItem* source, MycGroup* accent, int armor)
{
    accent = MycBandsHue(mapping->arena, source, accent, armor);
    if (accent == NULL || n == 0) return 1;
    MycGroup** bands = myc_alloc(mapping->arena, sizeof(MycGroup*) * (size_t)n);
    if (bands == NULL) return 0;
    const MycGroup* largest = choices[0].t;
    int nbands = 0;
    for (int i = 0; i < n; i++)
        if (choices[i].t->share > largest->share) largest = choices[i].t;
    for (int i = 0; i < n; i++)
        if (MycBandsPart(&choices[i], largest)) bands[nbands++] = choices[i].t;
    for (int i = 0; i < n; i++)
        if (MycBandsPair(&choices[i], largest) && MycBandsOf(choices[i].t, bands, nbands)) MycBandsCoat(mapping, choices[i].t, accent);
    return 1;
}

/* ---- cloth off metal ---------------------------------------------------------------------------------------------- */

static MycGroup* MycBandsPlainNearest(const MycItem* source, const MycGroup* src)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette);
    MycGroup* best = NULL;
    double gap = 0;
    for (int i = 0; i < m; i++)
    {
        double d = fabs(palette[i]->L - src->L);
        if (!palette[i]->metal && (best == NULL || d < gap)) { best = palette[i]; gap = d; }
    }
    return best;
}

/* The planned cloth rows of t (soft, no band coat) into rows; how many. */
static int MycBandsCloth(const MycPlan* mapping, const MycGroup* t, MycRow** rows)
{
    int n = 0;
    for (int i = 0; i < t->nrows; i++)
    {
        const MycGoal* m = myc_plan_get(mapping, t->rows[i]->key);
        if (m != NULL && !m->band && t->rows[i]->mode >= 0.5) rows[n++] = t->rows[i];
    }
    return n;
}

int myc_cloth_off_metal(MycPlan* mapping, const MycChoice* choices, int n, MycItem* source, int materials)
{
    for (int i = 0; i < n; i++)
    {
        const MycChoice* c = &choices[i];
        if (c->kind != MYC_KIND_PAIR || !c->src->metal || myc_chroma(c->src->a, c->src->b) < TINT_C) continue;
        MycRow** rows = myc_alloc(mapping->arena, sizeof(MycRow*) * (size_t)(c->t->nrows + 1));
        if (rows == NULL) return 0;
        int k = MycBandsCloth(mapping, c->t, rows);
        MycGroup* alt = k > 0 ? MycBandsPlainNearest(source, c->src) : NULL;
        if (alt == NULL) continue;
        MycGroup part = *c->t;
        part.rows = rows;
        part.nrows = k;
        if (!myc_map_group(mapping, &part, MYC_KIND_PAIR, alt, materials, source->armor, c->tone)) return 0;
    }
    return 1;
}

/* ---- the pattern plan --------------------------------------------------------------------------------------------- */

static MycGroup* MycBandsNeutralPattern(const MycGroup* p, const MycItem* source)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette), count = 0;
    MycGroup* pick = NULL;
    double gap = INFINITY;
    for (int i = 0; i < m; i++)
    {
        MycGroup* g = palette[i];
        if (g->hood || !(source->suit_paint || !myc_is_structure(g)) || myc_chroma(g->ma, g->mb) >= MYC_ACCENT_C) continue;
        count++;
        double d = fabs(g->L - p->L);
        if (d < gap) { pick = g; gap = d; }
    }
    return count >= 2 ? pick : NULL;
}

/* The band coat a pattern of a band's color takes, into goal; 0 when none. */
static int MycBandsPatternCoat(const MycGroup* p, const MycItem* target, const MycPlan* plan, MycGoal* goal)
{
    for (int i = 0; plan != NULL && i < target->ngroups; i++)
    {
        const MycGroup* g = target->groups[i];
        const MycGoal* m = myc_plan_get(plan, g->rows[0]->key);
        if (m == NULL || !m->band || myc_de2000(p->mL, p->ma, p->mb, g->mL, g->ma, g->mb) >= MYC_KEEP_DE) continue;
        MycLab out = {m->L, m->a, m->b};
        if (p->has_gain)
        {
            double lin[3];
            myc_lab_to_linear(m->L, m->a, m->b, lin);
            out = myc_linear_to_lab(myc_max(p->gain[0] * lin[0], 0), myc_max(p->gain[1] * lin[1], 0),
                myc_max(p->gain[2] * lin[2], 0));
        }
        memcpy(goal->source, m->source, MYC_KEY);
        goal->L = out.L;
        goal->a = out.a;
        goal->b = out.b;
        return 1;
    }
    return 0;
}

static MycGroup* MycBandsPatternPick(const MycGroup* p, const MycItem* source, MycGroup* accent)
{
    if (myc_matches_source(p, source, PAIR_MIN_SHARE)) return NULL;
    if (myc_chroma(p->ma, p->mb) < MYC_ACCENT_C) return p->mL >= LIGHT_PATTERN_L ? MycBandsNeutralPattern(p, source) : NULL;
    return p->mL >= ACCENT_MIN_L ? accent : NULL;
}

/* One target pattern's goal (pattern_plan's loop body); 0 out of memory. */
static int MycBandsPatternGoal(MycPlan* out, const MycGroup* p, MycItem* target, MycItem* source, const MycPlan* plan,
    MycGroup* accent)
{
    MycGroup* pick = accent != NULL ? MycBandsPatternPick(p, source, accent) : NULL;
    MycGoal coat;
    memset(&coat, 0, sizeof coat);
    int coated = MycBandsPatternCoat(p, target, plan, &coat);
    int picked = !coated && pick != NULL && myc_de2000(p->L, p->a, p->b, pick->L, pick->a, pick->b) >= MYC_KEEP_DE;
    if (!coated && !picked) return 1;
    char name[17];
    myc_hex(name, p->pattern);
    MycGoal* goal = myc_plan_set(out, name);
    if (goal == NULL) return 0;
    if (coated) memcpy(goal->source, coat.source, MYC_KEY);
    else memcpy(goal->source, pick->rep_key, MYC_KEY);
    goal->L = coated ? coat.L : pick->L;
    goal->a = coated ? coat.a : pick->a;
    goal->b = coated ? coat.b : pick->b;
    goal->has_gain = p->has_gain;
    memcpy(goal->gain, p->gain, sizeof goal->gain);
    return 1;
}

int myc_pattern_plan(MycPlan* out, MycItem* target, MycItem* source, const MycPlan* plan)
{
    MycGroup* accent = myc_source_accent(source);
    if (accent == NULL) accent = myc_fallback_accent(source);
    if (accent == NULL && source->cape_source) accent = myc_identity(source);
    for (int i = 0; i < target->npatterns; i++)
        if (!MycBandsPatternGoal(out, target->patterns[i], target, source, plan, accent)) return 0;
    return 1;
}
