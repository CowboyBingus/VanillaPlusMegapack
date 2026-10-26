/* Match Your Colors: plans, and the group-level color functions of colour.lua (group_look, diffuse_colors,
 * outside_first, two_tone, nearest_lightness, cape_structure, cape_second), 1:1. Runs on the worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "myc_match.h"

/* ---- plans ------------------------------------------------------------------------------------------------------- */

void myc_plan_init(MycPlan* plan, MycArena* arena)
{
    memset(plan, 0, sizeof *plan);
    plan->arena = arena;
}

static MycGoal* MycPlanFind(const MycPlan* plan, const char* key)
{
    for (int i = 0; i < plan->count; i++)
        if (strcmp(plan->goals[i].key, key) == 0) return &plan->goals[i];
    return NULL;
}

MycGoal* myc_plan_get(const MycPlan* plan, const char* key)
{
    MycGoal* g = MycPlanFind(plan, key);
    return g != NULL && !g->removed ? g : NULL;
}

MycGoal* myc_plan_set(MycPlan* plan, const char* key)
{
    MycGoal* g = MycPlanFind(plan, key);
    if (g == NULL)
    {
        if (plan->count >= plan->capacity)
        {
            int capacity = plan->capacity < 16 ? 16 : plan->capacity * 2;
            MycGoal* grown = myc_alloc(plan->arena, sizeof(MycGoal) * (size_t)capacity);
            if (grown == NULL) return NULL;
            if (plan->count > 0) memcpy(grown, plan->goals, sizeof(MycGoal) * (size_t)plan->count);
            plan->goals = grown;
            plan->capacity = capacity;
        }
        g = &plan->goals[plan->count++];
    }
    memset(g, 0, sizeof *g);
    snprintf(g->key, MYC_KEY, "%s", key);
    return g;
}

void myc_plan_remove(MycPlan* plan, const char* key)
{
    MycGoal* g = MycPlanFind(plan, key);
    if (g != NULL) g->removed = 1;
}

int myc_plan_size(const MycPlan* plan)
{
    int n = 0;
    for (int i = 0; i < plan->count; i++) n += !plan->goals[i].removed;
    return n;
}

/* ---- group colors ------------------------------------------------------------------------------------------------ */

#define FIELD_AREA 1
#define FIELD_TEX 2

/* Colour.weight_field: screen pixels when any row shows, else texture area, else each row alike (0). */
static int MycGroupsField(MycRow* const* rows, int n)
{
    double pixels = 0, texels = 0;
    for (int i = 0; i < n; i++) { pixels = pixels + rows[i]->area; texels = texels + rows[i]->tex_area; }
    if (pixels > 0) return FIELD_AREA;
    return texels > 0 ? FIELD_TEX : 0;
}

static double MycGroupsWeight(const MycRow* row, int field)
{
    if (field == FIELD_AREA) return row->area;
    return field == FIELD_TEX ? row->tex_area : 1.0;
}

MycLab myc_group_look(MycRow* const* rows, int n)
{
    int field = MycGroupsField(rows, n);
    double r = 0, g = 0, b = 0, weight = 0;
    for (int i = 0; i < n; i++)
    {
        double w = MycGroupsWeight(rows[i], field);
        r = r + w * rows[i]->lin[0];
        g = g + w * rows[i]->lin[1];
        b = b + w * rows[i]->lin[2];
        weight = weight + w;
    }
    weight = myc_max(weight, 1e-12);
    return myc_linear_to_lab(myc_max(r / weight, 0), myc_max(g / weight, 0), myc_max(b / weight, 0));
}

/* Colour.row_diffuse: a measured row's diffuse color (its response's g x its mean albedo), or 0. */
int myc_row_diffuse(const MycRow* row, double out[3])
{
    if (!row->has_cal || !row->has_lin) return 0;
    out[0] = row->cal[0] * row->ar;
    out[1] = row->cal[1] * row->ag;
    out[2] = row->cal[2] * row->ab;
    return 1;
}

/* The source group's look less its rows' gloss (a look as it is where none of its rows shows gloss). */
static MycLab MycGroupsSourceDiffuse(const MycGroup* src)
{
    int field = MycGroupsField(src->rows, src->nrows);
    double fr = 0, fg = 0, fb = 0, weight = 0, d[3];
    for (int i = 0; i < src->nrows; i++)
    {
        const MycRow* row = src->rows[i];
        double w = MycGroupsWeight(row, field);
        if (myc_row_diffuse(row, d))
        {
            fr = fr + w * (row->lin[0] - d[0]);
            fg = fg + w * (row->lin[1] - d[1]);
            fb = fb + w * (row->lin[2] - d[2]);
        }
        weight = weight + w;
    }
    MycLab s = {src->has_g ? src->gL : src->L, src->has_g ? src->ga : src->a, src->has_g ? src->gb : src->b};
    if (fr == 0 && fg == 0 && fb == 0) return s;
    double lin[3];
    myc_lab_to_linear(s.L, s.a, s.b, lin);
    weight = myc_max(weight, 1e-12);
    return myc_linear_to_lab(myc_max(lin[0] - fr / weight, 0), myc_max(lin[1] - fg / weight, 0),
        myc_max(lin[2] - fb / weight, 0));
}

int myc_diffuse_colors(const MycGroup* t, const MycGroup* src, MycLab* s_out, MycLab* t_out)
{
    *s_out = MycGroupsSourceDiffuse(src);
    int field = MycGroupsField(t->rows, t->nrows), any = 0;
    double tr = 0, tg = 0, tb = 0, weight = 0;
    for (int i = 0; i < t->nrows; i++)
    {
        const MycRow* row = t->rows[i];
        double w = MycGroupsWeight(row, field), d[3] = {0, 0, 0};
        if (myc_row_diffuse(row, d)) any = 1;
        else if (row->has_lin) memcpy(d, row->lin, sizeof d);
        tr = tr + w * d[0];
        tg = tg + w * d[1];
        tb = tb + w * d[2];
        weight = weight + w;
    }
    if (!any)
    {
        *t_out = (MycLab){t->L, t->a, t->b};
        return 0;
    }
    weight = myc_max(weight, 1e-12);
    *t_out = myc_linear_to_lab(myc_max(tr / weight, 0), myc_max(tg / weight, 0), myc_max(tb / weight, 0));
    return 1;
}

/* A group's rows' area and their area on a cape's outside. */
static void MycGroupsOutside(const MycGroup* g, double* area, double* outside)
{
    *area = 0;
    *outside = 0;
    for (int i = 0; i < g->nrows; i++)
    {
        *area = *area + g->rows[i]->area;
        *outside = *outside + (g->rows[i]->has_outside ? g->rows[i]->outside : 0);
    }
}

static int MycGroupsOutsideLess(const void* x, const void* y, void* ctx)
{
    const MycGroup* a = x;
    const MycGroup* b = y;
    double aa, ao, ba, bo;
    MycGroupsOutside(a, &aa, &ao);
    MycGroupsOutside(b, &ba, &bo);
    return ao > bo || (ao == bo && a->share > b->share);
}

void myc_outside_first(MycGroup** pool, int n, MycGroup** out, MycArena* arena)
{
    for (int i = 0; i < n; i++) out[i] = pool[i];
    double area, outside;
    if (n == 0) return;
    MycGroupsOutside(pool[0], &area, &outside);
    if (outside >= 0.5 * area) return;
    myc_lua_sort((void**)out, n, MycGroupsOutsideLess, NULL);
}

int myc_two_tone(MycGroup* const* s, int m, int j_main, double min_share, double vivid_c)
{
    for (int j = 0; j < m; j++)
        if (j != j_main && s[j]->share >= min_share && sqrt(pow(s[j]->ma, 2) + pow(s[j]->mb, 2)) < vivid_c) return 0;
    return 1;
}

MycGroup* myc_nearest_lightness(MycGroup* const* list, int n, const MycGroup* g)
{
    MycGroup* pick = NULL;
    double gap = INFINITY;
    for (int i = 0; i < n; i++)
    {
        double d = fabs(list[i]->L - g->L);
        if (d < gap) { pick = list[i]; gap = d; }
    }
    return pick;
}

int myc_pairs_add(MycArena* arena, MycPairs* pairs, MycGroup* t, MycGroup* s)
{
    if (pairs->count >= pairs->capacity)
    {
        int capacity = pairs->capacity < 16 ? 16 : pairs->capacity * 2;
        MycGroup** ts = myc_alloc(arena, sizeof(MycGroup*) * (size_t)capacity);
        MycGroup** ss = myc_alloc(arena, sizeof(MycGroup*) * (size_t)capacity);
        if (ts == NULL || ss == NULL) return 0;
        if (pairs->count > 0)
        {
            memcpy(ts, pairs->t, sizeof(MycGroup*) * (size_t)pairs->count);
            memcpy(ss, pairs->s, sizeof(MycGroup*) * (size_t)pairs->count);
        }
        pairs->t = ts;
        pairs->s = ss;
        pairs->capacity = capacity;
    }
    pairs->t[pairs->count] = t;
    pairs->s[pairs->count] = s;
    pairs->count++;
    return 1;
}

int myc_cape_structure(MycArena* arena, MycGroup** rest, int n, MycGroup** palette, int m, MycPairs* pairs, double* used)
{
    MycSearch c;
    memset(&c, 0, sizeof c);
    c.t = rest;
    c.n = n;
    c.s = palette;
    c.m = m;
    c.keep = myc_alloc(arena, sizeof(int) * (size_t)(n * m + 1));
    c.allowed = myc_alloc(arena, sizeof(int) * (size_t)(n * m + 1));
    MycGroup** list = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(m + 1));
    if (c.keep == NULL || c.allowed == NULL || list == NULL) return 0;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < m; j++) /* every color first: a guard's fallback then gives none it blocked */
        {
            MYC_ALLOWED(&c, i, j) = 1;
            MYC_KEEP(&c, i, j) = myc_de2000(rest[i]->L, rest[i]->a, rest[i]->b, palette[j]->L, palette[j]->a, palette[j]->b) < MYC_KEEP_DE;
        }
    myc_capes_dark_parts_guard(&c, MYC_ACCENT_C);
    for (int i = 0; i < n; i++)
    {
        int k = 0;
        for (int j = 0; j < m; j++)
            if (MYC_ALLOWED(&c, i, j) && palette[j]->share >= MYC_MAIN_COLOR) list[k++] = palette[j];
        MycGroup* near = myc_nearest_lightness(list, k, rest[i]);
        if (near == NULL) continue;
        if (!myc_pairs_add(arena, pairs, rest[i], near)) return 0;
        for (int j = 0; j < m; j++)
            if (palette[j] == near) used[j] = used[j] + rest[i]->share;
    }
    return 1;
}

static int MycGroupsMostlyOutside(const MycGroup* g)
{
    double area, outside;
    MycGroupsOutside(g, &area, &outside);
    return outside >= 0.5 * area;
}

/* A cape's second main color: the largest of the palette besides s[j_main] with share SECOND_MAIN_SHARE or more,
 * CIEDE2000 KEEP_DE or more from it and mostly on the outside, or -1. */
static int MycGroupsSecondMain(MycGroup* const* s, int m, int j_main)
{
    int j2 = -1;
    for (int j = 0; j < m; j++)
    {
        int apart = myc_de2000(s[j]->L, s[j]->a, s[j]->b, s[j_main]->L, s[j_main]->a, s[j_main]->b) >= MYC_KEEP_DE;
        int large = s[j]->share >= 0.25 && (j2 < 0 || s[j]->share > s[j2]->share);
        if (j != j_main && apart && large && MycGroupsMostlyOutside(s[j])) j2 = j;
    }
    return j2;
}

void myc_cape_second(const MycSearch* c, int* assign, int anchor, int j_main)
{
    int j2 = MycGroupsSecondMain(c->s, c->m, j_main), pick = -1;
    for (int i = 0; j2 >= 0 && i < c->n; i++)
    {
        const MycGroup* t = c->t[i];
        int main = t->share >= MYC_MAIN_COLOR;
        if (main && assign[i] == j2) return;
        int muted = myc_chroma(t->ma, t->mb) < 9.0;
        int larger = pick < 0 || t->share > c->t[pick]->share;
        if (main && muted && i != anchor && MYC_ALLOWED(c, i, j2) && larger) pick = i;
    }
    if (pick >= 0) assign[pick] = j2;
}
