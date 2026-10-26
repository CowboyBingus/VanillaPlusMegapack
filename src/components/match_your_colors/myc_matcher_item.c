/* Match Your Colors: matcher v12's items (matcher.lua Matcher.item), 1:1. An item is one kit's rows: every LUT row of
 * every piece material. A measured kit (every LUT of its rows measured on the Armory front view) weighs each row by its
 * screen pixels and sees it as it looks there (its measured response); any other kit weighs rows by ID-mask area and
 * sees them as the model color (or what the study knows of each LUT row). Rows are grouped by model color (CIEDE2000
 * under GROUP_DE, same hood, metal and camo class). Runs on the worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "myc_match.h"

#define GROUP_DE 6.0
#define NEUTRAL_L 35.0
#define NEUTRAL_C 10.0
#define LARGE_AREA 0.15
#define SEEN_MIN_SHARE 0.001
#define SEEN_TINT_C 5.0

int myc_is_neutral_lab(double L, double a, double b) { return L < NEUTRAL_L && myc_chroma(a, b) < NEUTRAL_C; }

int myc_is_structure(const MycGroup* g) { return myc_is_neutral_lab(g->mL, g->ma, g->mb) && g->under >= 0.5 * g->area; }

int myc_light(const MycRow* row) { return row->mode >= 2.5 || (row->mode < 0.5 && row->emissive > 0); }

/* Whether an armor's undersuit black is its paint: no group outside it reaches limit of what shows. */
static int MycItemSuitIsPaint(MycGroup* const* groups, int n, double limit)
{
    for (int i = 0; i < n; i++)
        if (!myc_is_structure(groups[i]) && groups[i]->share >= limit) return 0;
    return 1;
}

typedef struct MycOrdered { MycRow* row; int order; } MycOrdered;

/* Descending area, stable (Python's sorted(..., key=lambda r: -r.area)). */
static int MycItemRowLess(const void* x, const void* y, void* ctx)
{
    const MycOrdered* a = x;
    const MycOrdered* b = y;
    if (a->row->area != b->row->area) return a->row->area > b->row->area;
    return a->order < b->order;
}

static int MycItemGroupLess(const void* x, const void* y, void* ctx)
{
    const MycGroup* a = x;
    const MycGroup* b = y;
    if (a->area != b->area) return a->area > b->area;
    return a->order < b->order;
}

static int MycItemPush(MycArena* arena, MycGroup* g, MycRow* row)
{
    if (g->nrows >= g->rows_capacity)
    {
        int capacity = g->rows_capacity < 8 ? 8 : g->rows_capacity * 2;
        MycRow** grown = myc_alloc(arena, sizeof(MycRow*) * (size_t)capacity);
        if (grown == NULL) return 0;
        if (g->nrows > 0) memcpy(grown, g->rows, sizeof(MycRow*) * (size_t)g->nrows);
        g->rows = grown;
        g->rows_capacity = capacity;
    }
    g->rows[g->nrows++] = row;
    return 1;
}

/* The first group of row's class whose founding model color is within GROUP_DE, or NULL. */
static MycGroup* MycItemJoin(MycGroup** groups, int n, const MycRow* row)
{
    for (int i = 0; i < n; i++)
    {
        MycGroup* g = groups[i];
        int same = g->hood == row->hood && g->metal == row->metal && g->camo == row->camo;
        if (same && myc_de2000(g->mL, g->ma, g->mb, row->mL, row->ma, row->mb) < GROUP_DE) return g;
    }
    return NULL;
}

static MycGroup* MycItemFound(MycArena* arena, MycRow* row)
{
    MycGroup* g = myc_alloc(arena, sizeof *g);
    if (g == NULL || !MycItemPush(arena, g, row)) return NULL;
    g->L = row->L;
    g->a = row->a;
    g->b = row->b;
    g->mL = row->mL;
    g->ma = row->ma;
    g->mb = row->mb;
    g->metal = row->metal;
    g->camo = row->camo;
    g->hood = row->hood;
    g->area = row->area;
    g->under = row->under;
    g->rep = row;
    g->kind = MYC_GROUP;
    memcpy(g->rep_key, row->key, MYC_KEY);
    return g;
}

/* Rows by descending area (stable), each into the first group it joins, else a new one; groups largest first. */
static int MycItemGroups(MycArena* arena, MycItem* item)
{
    int n = item->npaint;
    MycOrdered* rows = myc_alloc(arena, sizeof(MycOrdered) * (size_t)(n + 1));
    MycOrdered** sorted = myc_alloc(arena, sizeof(MycOrdered*) * (size_t)(n + 1));
    MycGroup** groups = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(n + 1));
    if (rows == NULL || sorted == NULL || groups == NULL) return 0;
    for (int i = 0; i < n; i++) { rows[i] = (MycOrdered){item->paint[i], i}; sorted[i] = &rows[i]; }
    myc_lua_sort((void**)sorted, n, MycItemRowLess, NULL);
    int count = 0;
    for (int i = 0; i < n; i++)
    {
        MycRow* row = sorted[i]->row;
        MycGroup* g = MycItemJoin(groups, count, row);
        if (g != NULL && !MycItemPush(arena, g, row)) return 0;
        if (g != NULL) { g->area = g->area + row->area; g->under = g->under + row->under; continue; }
        g = MycItemFound(arena, row);
        if (g == NULL) return 0;
        g->order = count;
        groups[count++] = g;
    }
    for (int i = 0; i < count; i++) groups[i]->share = groups[i]->area / item->paint_area;
    myc_lua_sort((void**)groups, count, MycItemGroupLess, NULL);
    item->groups = groups;
    item->ngroups = count;
    return 1;
}

static int MycItemMeasuredKit(const MycRow* rows, int n, const MycAppKit* kit)
{
    if (kit == NULL) return 0;
    for (int i = 0; i < n; i++)
        if (!myc_app_kit_has_lut(kit, rows[i].lut)) return 0;
    return 1;
}

static double MycItemLuminance(const double c[3]) { return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; }

/* A mod's changed row: its measured light scaled by how much brighter or darker it looks now. */
static double MycItemLightScale(const MycRow* row)
{
    const MycVanilla* v = &row->vanilla;
    double now[3], before[3];
    if (row->has_cal)
    {
        myc_seen(row->cal, row->ar, row->ag, row->ab, 0, now);
        myc_seen(row->cal, v->ar, v->ag, v->ab, 0, before);
    }
    else
    {
        myc_lab_to_linear(row->L, row->a, row->b, now);
        myc_lab_to_linear(v->L, v->a, v->b, before);
    }
    double n = MycItemLuminance(now), b = MycItemLuminance(before);
    return b > 1e-9 ? n / b : 1.0;
}

/* A row's perceived color through its measured response, unless a mod changed its finish: then its model color. */
static void MycItemRespond(MycRow* row)
{
    const double* cal = row->finish_changed != 1 ? myc_app_row(row->lut, row->row) : NULL;
    row->has_lin = 1;
    if (cal == NULL)
    {
        myc_lab_to_linear(row->L, row->a, row->b, row->lin);
        return;
    }
    memcpy(row->cal, cal, sizeof row->cal);
    row->has_cal = 1;
    myc_seen(row->cal, row->ar, row->ag, row->ab, 0, row->lin);
    MycLab lab = myc_linear_to_lab(row->lin[0], row->lin[1], row->lin[2]);
    row->L = lab.L;
    row->a = lab.a;
    row->b = lab.b;
}

/* Measured rows: screen pixels for area (the undersuit part scaled alike), the light they show, their look. A row 0
 * that coverage leaves out weighs nothing even where the study saw it. */
static void MycItemMeasure(MycRow* rows, int n, const MycAppKit* kit)
{
    for (int i = 0; i < n; i++)
    {
        MycRow* row = &rows[i];
        double frac = row->area > 0 ? row->under / row->area : 0.0;
        const MycAppRow* seen = row->tex_area > 1e-6 ? myc_app_kit_row(kit, row->lut, row->row) : NULL;
        row->area = seen != NULL ? seen->px : 0;
        row->light = seen != NULL ? seen->light : 0;
        row->under = row->area * frac;
        MycItemRespond(row);
        if (row->has_vanilla) row->light = row->light * MycItemLightScale(row);
    }
}

/* Without a measurement of its own: a row of a measured LUT no kit showed on SEEN_MIN_SHARE weighs nothing. */
static void MycItemUnmeasured(MycRow* rows, int n)
{
    for (int i = 0; i < n; i++)
    {
        MycRow* row = &rows[i];
        MycItemRespond(row);
        double share = myc_app_seen_share(row->lut, row->row);
        if (share >= 0 && share < SEEN_MIN_SHARE && !row->has_vanilla && row->finish_changed != 1) row->area = row->under = 0;
    }
}

/* A cape's rows fit through the response their cloth borrows (a tint row through its material row's); a cape as the
 * source (look->seen) also gets its look through it. */
static void MycItemBorrow(MycRow* rows, int n, const MycLook* look)
{
    for (int i = 0; i < n; i++)
    {
        MycRow* row = &rows[i];
        uint64_t lut = look->has_tint && row->lut == look->tint_cape ? look->tint_material : row->lut;
        const double* cal = row->finish_changed != 1 ? myc_app_row(lut, row->row) : NULL;
        if (cal != NULL) { memcpy(row->cal, cal, sizeof row->cal); row->has_cal = 1; }
        if (!look->seen) continue;
        row->has_lin = 1;
        if (cal != NULL) myc_seen(row->cal, row->ar, row->ag, row->ab, 0, row->lin);
        else myc_lab_to_linear(row->L, row->a, row->b, row->lin);
    }
}

/* The item's own copies of the analysis rows, with the model color and texture area kept. */
static MycRow* MycItemCopy(MycArena* arena, const MycRow* rows, int n, const MycLook* look, int keep_hoods)
{
    MycRow* out = myc_alloc(arena, sizeof(MycRow) * (size_t)(n > 0 ? n : 1));
    if (out == NULL) return NULL;
    int hoods = keep_hoods && look != NULL && look->has_hoods;
    for (int i = 0; i < n; i++)
    {
        MycRow* row = &out[i];
        *row = rows[i];
        row->lens = myc_light(row);
        row->hood = hoods && myc_app_is_hood(look->hood_id, row->lut, row->row);
        row->mL = row->L;
        row->ma = row->a;
        row->mb = row->b;
        row->tex_area = row->area;
    }
    return out;
}

/* The paint rows (not lens) and the paint area (a measured kit's pattern pixels included; 1 when nothing shows). */
static int MycItemPaint(MycArena* arena, MycItem* item, const MycAppKit* kit)
{
    item->paint = myc_alloc(arena, sizeof(MycRow*) * (size_t)(item->nrows + 1));
    double* areas = myc_alloc(arena, sizeof(double) * (size_t)(item->nrows + 1));
    if (item->paint == NULL || areas == NULL) return 0;
    for (int i = 0; i < item->nrows; i++)
    {
        if (item->rows[i].lens) continue;
        areas[item->npaint] = item->rows[i].area;
        item->paint[item->npaint++] = &item->rows[i];
    }
    double paint_area = myc_pysum(areas, item->npaint);
    for (int i = 0; item->measured && i < kit->npatterns; i++) /* each pattern once: the Lua's map keeps the last */
        if (myc_app_kit_pattern(kit, kit->patterns[i].pattern) == &kit->patterns[i]) paint_area = paint_area + kit->patterns[i].px;
    item->paint_area = paint_area == 0 ? 1.0 : paint_area;
    return 1;
}

/* The item's patterns: perceived (a measured one's look through its gain), area and share. */
static int MycItemPatterns(MycArena* arena, MycItem* item, const MycPatternIn* patterns, int n, const MycAppKit* kit)
{
    item->patterns = myc_alloc(arena, sizeof(MycGroup*) * (size_t)(n + 1));
    if (item->patterns == NULL) return 0;
    for (int i = 0; i < n; i++)
    {
        const MycPatternIn* p = &patterns[i];
        MycGroup* e = myc_alloc(arena, sizeof *e);
        if (e == NULL) return 0;
        MycLab m = myc_srgb_to_lab(p->r, p->g, p->b);
        e->kind = MYC_PATTERN;
        e->pattern = p->pattern;
        if (p->emblem) snprintf(e->rep_key, MYC_KEY, "pattern:emblem:%d:%d", p->erow, p->elayer);
        else snprintf(e->rep_key, MYC_KEY, "pattern:%016llx", (unsigned long long)p->pattern);
        e->area = p->area;
        e->L = e->mL = m.L;
        e->a = e->ma = m.a;
        e->b = e->mb = m.b;
        e->texel[0] = p->r;
        e->texel[1] = p->g;
        e->texel[2] = p->b;
        const MycAppPattern* measured = kit != NULL ? myc_app_kit_pattern(kit, p->pattern) : NULL;
        if (kit != NULL) e->area = measured != NULL ? measured->px : 0;
        if (measured != NULL && measured->has_gain)
        {
            memcpy(e->gain, measured->gain, sizeof e->gain);
            e->has_gain = 1;
            MycLab look = myc_linear_to_lab(myc_max(e->gain[0] * myc_srgb_to_linear(p->r), 0),
                myc_max(e->gain[1] * myc_srgb_to_linear(p->g), 0), myc_max(e->gain[2] * myc_srgb_to_linear(p->b), 0));
            e->L = look.L;
            e->a = look.a;
            e->b = look.b;
        }
        e->share = e->area / item->paint_area;
        item->patterns[item->npatterns++] = e;
    }
    return 1;
}

/* The groups' looks: a measured item's perceived colors; a cape source's goal looks (a neutral keeps its model hue). */
static void MycItemLooks(MycItem* item, const MycLook* look)
{
    for (int i = 0; i < item->ngroups; i++)
    {
        MycGroup* g = item->groups[i];
        if (item->measured)
        {
            MycLab l = myc_group_look(g->rows, g->nrows);
            g->L = l.L;
            g->a = l.a;
            g->b = l.b;
        }
        else if (look != NULL && look->seen)
        {
            MycLab l = myc_group_look(g->rows, g->nrows);
            g->gL = l.L;
            g->ga = l.a;
            g->gb = l.b;
            g->has_g = 1;
            if (myc_chroma(g->ma, g->mb) < SEEN_TINT_C) { g->ga = g->ma; g->gb = g->mb; }
        }
    }
}

MycItem* myc_item(MycArena* arena, const MycRow* rows, int nrows, int armor, const MycPatternIn* patterns, int npatterns,
    const MycLook* look, int keep_hoods)
{
    const MycAppKit* kit = look != NULL ? look->kit : NULL;
    MycItem* item = myc_alloc(arena, sizeof *item);
    if (item == NULL) return NULL;
    item->rows = MycItemCopy(arena, rows, nrows, look, keep_hoods);
    if (item->rows == NULL) return NULL;
    item->nrows = nrows;
    item->armor = armor;
    item->measured = MycItemMeasuredKit(item->rows, nrows, kit);
    if (item->measured) MycItemMeasure(item->rows, nrows, kit);
    else if (look != NULL && look->borrow) MycItemBorrow(item->rows, nrows, look);
    else if (look != NULL && look->seen_share) MycItemUnmeasured(item->rows, nrows);
    if (!MycItemPaint(arena, item, kit) || !MycItemGroups(arena, item)) return NULL;
    MycItemLooks(item, look);
    item->suit_paint = armor && MycItemSuitIsPaint(item->groups, item->ngroups, LARGE_AREA);
    item->suit_target = armor && MycItemSuitIsPaint(item->groups, item->ngroups, MYC_PAINT_SHARE);
    if (!MycItemPatterns(arena, item, patterns, npatterns, item->measured ? kit : NULL)) return NULL;
    return item;
}
