/* Match Your Colors: matcher v12's pairing (matcher.lua pair_groups and the source's identity, palette and accent),
 * 1:1. The anchor takes the source's identity; the other target groups are placed by a local search over the source
 * colors (lightness and saturation relative to the anchor, colors already matched, source proportions, light/dark
 * contrast); sums follow numpy's order (myc_npsum) and sorts are Lua's (myc_lua_sort), so plans equal the Lua's. Runs on
 * the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_match.h"

#define TGT_MIN_SHARE 0.02
#define PAIR_MIN_SHARE 0.02
#define ANCHOR_MIN_SHARE 0.10
#define DARK_SALIENCE 0.5
#define DARK_SALIENCE_TEXTURE 0.25
#define UNDER_SALIENCE 0.5
#define ACCENT_VIVID 35.0
#define LARGE_AREA 0.15
#define SOURCE_ACCENT_MIN_L 30.0
#define SOURCE_ACCENT_MIN_SHARE 0.005
#define SOURCE_ACCENT_MIN_SHARE_MEASURED 0.001
#define ACCENT_MIN_L 20.0
#define NEUTRAL_C 10.0
#define LOOK_DARK_L 30.0
#define SECOND_MAIN_SHARE 0.25
#define LIGHTER_MAIN_L 20.0
#define TWO_TONE_SHARE 0.15
#define W_LIGHT 1.0
#define W_CHROMA 0.5
#define W_KEEP 0.15
#define W_PROP 1.0
#define W_FLAT 0.5
#define PALETTE_LIMIT 8
#define BIG_SHARE 0.05
#define VIVID_MAJORITY 0.5
#define VIVID_PART_SHARE 0.10
#define EARTH_HUE_MIN 45.0
#define EARTH_HUE_MAX 110.0

static int MycPairNeutral(const MycGroup* g) { return myc_is_neutral_lab(g->mL, g->ma, g->mb); }
static int MycPairLooksDark(const MycGroup* g) { return g->L < LOOK_DARK_L && myc_chroma(g->a, g->b) < NEUTRAL_C; }

int myc_palette_of(const MycItem* source, MycGroup** out)
{
    int n = 0;
    for (int i = 0; i < source->ngroups; i++)
        if (source->groups[i]->share >= PAIR_MIN_SHARE && n < PALETTE_LIMIT) out[n++] = source->groups[i];
    if (n == 0 && source->ngroups > 0) out[n++] = source->groups[0];
    return n;
}

/* The light a group shows (measured items): its rows' pixels x mean screen luminance, the undersuit part weighed
 * UNDER_SALIENCE. */
static double MycPairLight(const MycGroup* g)
{
    double total = 0.0;
    for (int i = 0; i < g->nrows; i++)
    {
        const MycRow* row = g->rows[i];
        double frac = row->area > 0 ? row->under / row->area : 0.0;
        total = total + row->light * (1.0 - frac * (1.0 - UNDER_SALIENCE));
    }
    return total;
}

static double MycPairSalience(const MycItem* source, const MycGroup* g)
{
    if (!source->armor) return g->share;
    double dark = source->measured ? DARK_SALIENCE : DARK_SALIENCE_TEXTURE;
    return (g->area - g->under * (1 - UNDER_SALIENCE)) / source->paint_area * (MycPairNeutral(g) ? dark : 1.0);
}

static MycGroup* MycPairMostSalient(const MycItem* source, MycGroup* const* pool, int n)
{
    MycGroup* main = pool[0];
    double best = -INFINITY;
    for (int i = 0; i < n; i++)
    {
        double s = MycPairSalience(source, pool[i]);
        if (s > best) { best = s; main = pool[i]; }
    }
    return main;
}

/* The main color (share LARGE_AREA or more) of pool that looks light and shows the most light, if more than main. */
static MycGroup* MycPairLighterMain(MycGroup* const* pool, int n, const MycGroup* main)
{
    MycGroup* light = NULL;
    double most = -INFINITY;
    for (int i = 0; i < n; i++)
        if (pool[i]->share >= LARGE_AREA && !MycPairLooksDark(pool[i]) && MycPairLight(pool[i]) > most)
        {
            light = pool[i];
            most = MycPairLight(pool[i]);
        }
    return light != NULL && most > MycPairLight(main) ? light : NULL;
}

/* A helmet's identity: its largest group, unless that is vivid on less than VIVID_MAJORITY of its paint while a muted
 * group covers at least ANCHOR_MIN_SHARE: then the largest muted group. */
static MycGroup* MycPairHelmetMain(MycGroup* const* pool, int n)
{
    MycGroup* top = pool[0];
    if (myc_chroma(top->ma, top->mb) < ACCENT_VIVID || top->share >= VIVID_MAJORITY) return top;
    for (int i = 0; i < n; i++)
        if (myc_chroma(pool[i]->ma, pool[i]->mb) < MYC_ACCENT_C && pool[i]->share >= ANCHOR_MIN_SHARE) return pool[i];
    return top;
}

static MycGroup* MycPairIdentityOf(const MycItem* source, MycGroup* const* palette, int m)
{
    MycGroup* pool[PALETTE_LIMIT];
    MycGroup* ordered[PALETTE_LIMIT];
    int n = 0;
    for (int i = 0; i < m; i++)
        if (source->suit_paint || !myc_is_structure(palette[i])) pool[n++] = palette[i];
    if (n == 0)
        for (int i = 0; i < m; i++) pool[n++] = palette[i];
    MycGroup* const* use = pool;
    if (source->cape_source) { myc_outside_first(pool, n, ordered, NULL); use = ordered; }
    if (!source->armor) return MycPairHelmetMain(use, n);
    MycGroup* main = MycPairMostSalient(source, use, n);
    if (!source->measured || !MycPairLooksDark(main)) return main;
    MycGroup* lighter = MycPairLighterMain(use, n, main);
    return lighter != NULL ? lighter : main;
}

MycGroup* myc_identity(MycItem* source)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette);
    return m > 0 ? MycPairIdentityOf(source, palette, m) : NULL;
}

MycGroup* myc_source_accent(const MycItem* source)
{
    double min_share = source->measured ? SOURCE_ACCENT_MIN_SHARE_MEASURED : SOURCE_ACCENT_MIN_SHARE, best = 0.0;
    MycGroup* pick = NULL;
    for (int i = 0; i < source->ngroups + source->npatterns; i++)
    {
        MycGroup* g = i < source->ngroups ? source->groups[i] : source->patterns[i - source->ngroups];
        double c = myc_chroma(g->ma, g->mb);
        int light = g->mL >= SOURCE_ACCENT_MIN_L || (g->mL >= ACCENT_MIN_L && c >= ACCENT_VIVID);
        int visible = g->share >= min_share && light;
        if (visible && c >= MYC_ACCENT_C && c * sqrt(g->share) > best) { best = c * sqrt(g->share); pick = g; }
    }
    return pick;
}

/* A source's second color (its target's small accents and patterns take it when it has no visible saturated accent):
 * its most salient paint group other than the identity and unlike it (CIEDE2000 KEEP_DE or more), hoods and (unless
 * its suit is its paint) structure left out; NULL when there is none. */
MycGroup* myc_fallback_accent(MycItem* source)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette);
    if (m == 0) return NULL;
    MycGroup* main = MycPairIdentityOf(source, palette, m);
    MycGroup* pick = NULL;
    double best = -INFINITY;
    for (int i = 0; i < m; i++)
    {
        MycGroup* g = palette[i];
        int paint = source->suit_paint || !myc_is_structure(g);
        if (g == main || g->hood || !paint) continue;
        if (myc_de2000(g->L, g->a, g->b, main->L, main->a, main->b) >= MYC_KEEP_DE && MycPairSalience(source, g) > best)
        {
            best = MycPairSalience(source, g);
            pick = g;
        }
    }
    return pick;
}

/* ---- the pairing ------------------------------------------------------------------------------------------------ */

static int MycPairIndex(MycGroup* const* s, int m, const MycGroup* g)
{
    int found = -1;
    for (int j = 0; j < m; j++)
        if (s[j] == g) found = j;
    return found;
}

/* Structure groups keep a dark neutral (the source's nearest by lightness); the paint groups into t; the share each
 * palette color took here into pre_used; a cape of no dark neutral gives them a main color its guard allows. */
/* A structure group given the source's dark neutral nearest by lightness; the share it takes into pre_used. */
static int MycPairToNeutral(MycArena* arena, MycSearch* c, MycPairs* pairs, MycGroup* g, MycGroup** neutrals, int k)
{
    MycGroup* near = myc_nearest_lightness(neutrals, k, g);
    if (!myc_pairs_add(arena, pairs, g, near)) return 0;
    int j = MycPairIndex(c->s, c->m, near);
    c->pre_used[j] = c->pre_used[j] + g->share;
    return 1;
}

static int MycPairStructure(MycArena* arena, MycGroup** targets, int n, MycSearch* c, MycPairs* pairs, int suit, int guard)
{
    MycGroup** neutrals = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(c->m + 1));
    MycGroup** rest = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(n + 1));
    if (neutrals == NULL || rest == NULL) return 0;
    int k = 0, r = 0;
    for (int j = 0; j < c->m; j++)
        if (MycPairNeutral(c->s[j])) neutrals[k++] = c->s[j];
    c->n = 0;
    for (int i = 0; i < n; i++)
    {
        MycGroup* g = targets[i];
        if (suit || !myc_is_structure(g)) c->t[c->n++] = g;
        else if (k == 0) { if (guard) rest[r++] = g; }
        else if (!MycPairToNeutral(arena, c, pairs, g, neutrals, k)) return 0;
    }
    return r == 0 || myc_cape_structure(arena, rest, r, c->s, c->m, pairs, c->pre_used);
}

static int MycPairLargestPaint(const MycSearch* c)
{
    int largest = -1;
    for (int j = 0; j < c->m; j++)
    {
        int paint = c->suit || !myc_is_structure(c->s[j]);
        if (paint && (largest < 0 || c->s[j]->share > c->s[largest]->share)) largest = j;
    }
    if (largest >= 0) return largest;
    largest = 0;
    for (int j = 1; j < c->m; j++)
        if (c->s[j]->share > c->s[largest]->share) largest = j;
    return largest;
}

/* Whether target group g may take source color j: a large area takes only main colors, one it already matches or the
 * largest; an undersuit color goes only to a small dark neutral group, unless the source's undersuit is its paint. */
static int MycPairMayTake(const MycSearch* c, int i, int j, int largest)
{
    const MycGroup* g = c->t[i];
    int keep = MYC_KEEP(c, i, j), small = g->share < LARGE_AREA;
    int size_ok = small || c->s[j]->share >= MYC_MAIN_COLOR || keep || j == largest;
    return size_ok && (keep || c->suit || !myc_is_structure(c->s[j]) || (small && MycPairNeutral(g)));
}

static void MycPairAllowed(MycSearch* c)
{
    int largest = MycPairLargestPaint(c);
    for (int i = 0; i < c->n; i++)
    {
        int any = 0;
        for (int j = 0; j < c->m; j++) any |= MYC_ALLOWED(c, i, j) = MycPairMayTake(c, i, j, largest);
        if (!any) MYC_ALLOWED(c, i, largest) = 1;
    }
}

static int MycPairEarthTone(const MycGroup* g)
{
    double c = myc_chroma(g->ma, g->mb);
    if (c < MYC_ACCENT_C || c >= ACCENT_VIVID) return 0;
    double hue = myc_mod(myc_deg(atan2(g->mb, g->ma)), 360.0);
    return hue >= EARTH_HUE_MIN && hue <= EARTH_HUE_MAX;
}

typedef struct MycGuardPart { int j_main, under, pair_only; double least; } MycGuardPart;

/* Whether source color j counts as a second main color for a guarded part (not a vivid minority). */
static int MycPairSecond(const MycSearch* c, int j, const MycGuardPart* p)
{
    const MycGroup* s = c->s[j];
    const MycGroup* main = c->s[p->j_main];
    int part = s->share >= p->least && s->share <= main->share;
    int lighter = s->share >= SECOND_MAIN_SHARE && s->L >= main->L + LIGHTER_MAIN_L;
    return !p->under && (lighter || (p->pair_only && s->share >= TWO_TONE_SHARE) || part);
}

static void MycPairGuardPart(MycSearch* c, int i, const MycGuardPart* p)
{
    int any = 0;
    for (int j = 0; j < c->m; j++)
    {
        int vivid = myc_chroma(c->s[j]->ma, c->s[j]->mb) >= ACCENT_VIVID;
        if (j != p->j_main && vivid && !MYC_KEEP(c, i, j) && !MycPairSecond(c, j, p)) MYC_ALLOWED(c, i, j) = 0;
        any = any || MYC_ALLOWED(c, i, j);
    }
    if (!any) MYC_ALLOWED(c, i, p->j_main) = 1;
}

/* A muted (or earth-tone) target part of PAINT_SHARE or more, or undergarment cloth, never takes a vivid minority. */
static void MycPairVividGuard(MycSearch* c, int j_main, int cape)
{
    MycGuardPart p = {j_main, 0, cape && myc_two_tone(c->s, c->m, j_main, MYC_MAIN_COLOR, ACCENT_VIVID),
                      cape ? INFINITY : VIVID_PART_SHARE};
    for (int i = 0; i < c->n; i++)
    {
        const MycGroup* t = c->t[i];
        int muted = myc_chroma(t->ma, t->mb) < MYC_ACCENT_C;
        p.under = t->under >= 0.5 * t->area && muted;
        if ((t->share >= MYC_PAINT_SHARE || p.under) && (muted || MycPairEarthTone(t))) MycPairGuardPart(c, i, &p);
    }
}

/* The target group that takes the identity (its look class first). */
static int MycPairAnchor(const MycSearch* c, int j_main)
{
    const MycGroup* identity = c->s[j_main];
    int dark = MycPairLooksDark(identity);
    for (int j = 0; j < c->m; j++)
        if (c->s[j] != identity && c->s[j]->share >= SECOND_MAIN_SHARE && c->s[j]->L >= identity->L + LIGHTER_MAIN_L) dark = 1;
    for (int i = 0; i < c->n; i++)
        if (c->t[i]->share >= ANCHOR_MIN_SHARE && MycPairLooksDark(c->t[i]) == dark) return i;
    for (int i = 0; i < c->n; i++)
        if (c->t[i]->share >= ANCHOR_MIN_SHARE && MYC_KEEP(c, i, j_main)) return i;
    return 0;
}

static int MycPairClosestMain(const MycSearch* c, int i)
{
    int pick = -1;
    double gap = INFINITY;
    const MycGroup* g = c->t[i];
    for (int j = 0; j < c->m; j++)
    {
        if (!MYC_KEEP(c, i, j) || !MYC_ALLOWED(c, i, j) || c->s[j]->share < MYC_MAIN_COLOR) continue;
        double d = myc_de2000(g->L, g->a, g->b, c->s[j]->L, c->s[j]->a, c->s[j]->b);
        if (d < gap) { pick = j; gap = d; }
    }
    return pick;
}

static void MycPairBigSpread(MycGroup* const* list, int n, int* count, double* spread)
{
    double lo = INFINITY, hi = -INFINITY;
    *count = 0;
    for (int i = 0; i < n; i++)
    {
        if (list[i]->share < BIG_SHARE) continue;
        (*count)++;
        lo = myc_min(lo, list[i]->L);
        hi = myc_max(hi, list[i]->L);
    }
    *spread = *count > 0 ? hi - lo : 0;
}

static int MycPairFlatCheck(const MycSearch* c)
{
    int big_t, big_s;
    double spread_t, spread_s;
    MycPairBigSpread(c->t, c->n, &big_t, &spread_t);
    MycPairBigSpread(c->s, c->m, &big_s, &spread_s);
    return big_t >= 2 && spread_t >= 20 && big_s >= 2 && spread_s >= 20;
}

/* Whether the assignment's source lightnesses and the identity's span less than 10 (light/dark flattened). */
static int MycPairFlat(const MycSearch* c, const int* assign)
{
    double lo = c->ref_s, hi = c->ref_s;
    for (int i = 0; i < c->n; i++)
    {
        double L = c->s[assign[i]]->L;
        if (L < lo) lo = L;
        if (L > hi) hi = L;
    }
    return hi - lo < 10;
}

/* The objective of one assignment (match.py _cost). */
static double MycPairCost(const MycSearch* c, const int* assign, double* per, double* used, double* gaps)
{
    for (int j = 0; j < c->m; j++) used[j] = c->pre_used[j];
    for (int i = 0; i < c->n; i++)
    {
        int j = assign[i];
        const MycGroup* s = c->s[j];
        const MycGroup* t = c->t[i];
        double rel = fabs((s->L - c->ref_s) - (t->L - c->ref_t));
        double dc = fabs(myc_chroma(s->a, s->b) - myc_chroma(t->a, t->b));
        per[i] = t->share * (W_LIGHT * rel / 100 + W_CHROMA * dc / 100 + W_KEEP * (MYC_KEEP(c, i, j) ? 0 : 1));
        used[j] = used[j] + t->share;
    }
    double total = myc_npsum(per, c->n);
    double used_sum = myc_max(myc_npsum(used, c->m), 1e-9);
    for (int j = 0; j < c->m; j++) gaps[j] = fabs(used[j] / used_sum - c->s[j]->share / c->share_sum);
    total = total + W_PROP * myc_npsum(gaps, c->m) / 2;
    if (c->flat_check && MycPairFlat(c, assign)) total = total + W_FLAT;
    return total;
}

typedef struct MycScratch { double* per; double* used; double* gaps; int* trial; } MycScratch;

/* One pass over target group i's allowed alternatives (the assignment and its cost updated in place); whether it
 * improved. */
static int MycPairImprove(const MycSearch* c, int i, int* assign, double* best, MycScratch* w)
{
    int improved = 0;
    for (int j = 0; j < c->m; j++)
    {
        if (j == assign[i] || !MYC_ALLOWED(c, i, j)) continue;
        memcpy(w->trial, assign, sizeof(int) * (size_t)c->n);
        w->trial[i] = j;
        double value = MycPairCost(c, w->trial, w->per, w->used, w->gaps);
        if (value < *best - 1e-9) { *best = value; assign[i] = j; improved = 1; }
    }
    return improved;
}

/* First-improvement local search over single reassignments; fixed groups never move. */
static void MycPairSearch(const MycSearch* c, int* assign, const int* fixed, MycScratch* w)
{
    double best = MycPairCost(c, assign, w->per, w->used, w->gaps);
    int improved = 1;
    while (improved)
    {
        improved = 0;
        for (int i = 0; i < c->n; i++)
            if (!fixed[i]) improved |= MycPairImprove(c, i, assign, &best, w);
    }
}

static void MycPairInitial(const MycSearch* c, int* assign)
{
    for (int i = 0; i < c->n; i++)
    {
        int best = -1;
        double gap = INFINITY;
        for (int j = 0; j < c->m; j++)
        {
            double d = fabs((c->s[j]->L - c->ref_s) - (c->t[i]->L - c->ref_t));
            if (MYC_ALLOWED(c, i, j) && (best < 0 || d < gap)) { best = j; gap = d; }
        }
        assign[i] = best;
    }
}

/* The search's matrices and scratch, sized for n targets and m colors. */
static int MycPairAlloc(MycArena* arena, MycSearch* c, int n, MycScratch* w, int** assign, int** fixed)
{
    size_t cells = (size_t)(n * c->m + 1);
    c->t = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(n + 1));
    c->keep = myc_alloc(arena, sizeof(int) * cells);
    c->allowed = myc_alloc(arena, sizeof(int) * cells);
    c->pre_used = myc_alloc(arena, sizeof(double) * (size_t)(c->m + 1));
    w->per = myc_alloc(arena, sizeof(double) * (size_t)(n + 1));
    w->used = myc_alloc(arena, sizeof(double) * (size_t)(c->m + 1));
    w->gaps = myc_alloc(arena, sizeof(double) * (size_t)(c->m + 1));
    w->trial = myc_alloc(arena, sizeof(int) * (size_t)(n + 1));
    *assign = myc_alloc(arena, sizeof(int) * (size_t)(n + 1));
    *fixed = myc_alloc(arena, sizeof(int) * (size_t)(n + 1));
    return c->t && c->keep && c->allowed && c->pre_used && w->per && w->used && w->gaps && w->trial && *assign && *fixed;
}

static int MycPairJMain(MycSearch* c, const MycGroup* main)
{
    double shares[PALETTE_LIMIT];
    for (int j = 0; j < c->m; j++) shares[j] = c->s[j]->share;
    c->share_sum = myc_npsum(shares, c->m);
    int j_main = MycPairIndex(c->s, c->m, main);
    return j_main >= 0 ? j_main : 0;
}

/* Everything after the structure pairs: the matrices, guards, anchor and search; assign filled; the anchor index. */
static int MycPairPlace(MycSearch* c, MycItem* target, MycItem* source, const MycGroup* main, int* assign, int* fixed,
    MycScratch* w)
{
    int j_main = MycPairJMain(c, main);
    for (int i = 0; i < c->n; i++)
        for (int j = 0; j < c->m; j++)
            MYC_KEEP(c, i, j) = myc_de2000(c->t[i]->L, c->t[i]->a, c->t[i]->b, c->s[j]->L, c->s[j]->a, c->s[j]->b) < MYC_KEEP_DE;
    int anchor = target->weapon ? 0 : MycPairAnchor(c, j_main);
    MycPairAllowed(c);
    MycPairVividGuard(c, j_main, source->cape_source);
    if (source->part_guard) myc_capes_dark_parts_guard(c, MYC_ACCENT_C);
    c->ref_t = c->t[anchor]->L;
    c->ref_s = c->s[j_main]->L;
    c->flat_check = MycPairFlatCheck(c);
    MycPairInitial(c, assign);
    assign[anchor] = j_main;
    fixed[anchor] = 1;
    for (int i = 0; i < c->n; i++)
    {
        int pick = fixed[i] ? -1 : MycPairClosestMain(c, i);
        if (pick >= 0) { assign[i] = pick; fixed[i] = 1; }
    }
    MycPairSearch(c, assign, fixed, w);
    if (source->cape_source) myc_cape_second(c, assign, anchor, j_main);
    return anchor;
}

int myc_pair_groups(MycArena* arena, MycItem* target, MycItem* source, MycPairs* pairs, MycGroup** anchor)
{
    MycGroup* palette[PALETTE_LIMIT];
    MycSearch c;
    memset(&c, 0, sizeof c);
    *anchor = NULL;
    MycGroup** targets = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(target->ngroups + 1));
    if (targets == NULL) return 0;
    int n = 0;
    for (int i = 0; i < target->ngroups; i++)
        if (target->groups[i]->share >= TGT_MIN_SHARE && !target->groups[i]->hood) targets[n++] = target->groups[i];
    c.m = myc_palette_of(source, palette);
    c.s = palette;
    c.suit = source->suit_paint;
    if (n == 0 || c.m == 0) return 1;
    MycGroup* main = MycPairIdentityOf(source, palette, c.m);
    MycScratch w;
    int* assign = NULL;
    int* fixed = NULL;
    if (!MycPairAlloc(arena, &c, n, &w, &assign, &fixed)) return 0;
    if (!MycPairStructure(arena, targets, n, &c, pairs, target->suit_target, source->cape_source && source->part_guard)) return 0;
    if (c.n == 0) return 1;
    int a = MycPairPlace(&c, target, source, main, assign, fixed, &w);
    for (int i = 0; i < c.n; i++)
        if (!myc_pairs_add(arena, pairs, c.t[i], c.s[assign[i]])) return 0;
    *anchor = c.t[a];
    return 1;
}
