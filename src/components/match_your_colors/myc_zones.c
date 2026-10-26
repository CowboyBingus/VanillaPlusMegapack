/* Match Your Colors: a cape's design zones and emblems kept readable when the cape is recolored (zones.lua, Recolor
 * Cape), 1:1. A zone (or emblem) that read against half its border (lightness contrast >= ZONE_READ) and no longer
 * reads against half of it as planned (< ZONE_LOST) takes the source color reading against the most of it, else keeps
 * its own colors, else (a design drawn by lightness) a neutral tone of its border. Runs on the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_match.h"

#define ZONE_READ 15.0
#define ZONE_LOST 10.0
#define ZONE_BINS MYC_ZONE_BINS
#define STRONG_GAP (2 * ZONE_READ)
#define LOST_TONE 30.0
#define PALETTE_LIMIT 8

/* A cape item's rows by LUT row: its base and its tint row. */
typedef struct MycZonePart { const MycRow* base; const MycRow* tint; } MycZonePart;
typedef struct MycZoneParts { MycZonePart p[5]; } MycZoneParts;
/* The cloth around a zone or emblem: cells per row and tint bin. */
typedef struct MycAround { uint32_t counts[5][ZONE_BINS]; uint8_t present[5]; } MycAround;
/* A lost or picked zone's context (keep_zone's zone). */
typedef struct MycZoneCtx
{
    const MycAround* around;
    const MycAround* cloth;     /* NULL: it borders no cloth */
    const MycZoneParts* parts;
    const MycPlan* plan;
    int order, strong;
    double mean;
} MycZoneCtx;
typedef struct MycZoneList { MycGroup* g[PALETTE_LIMIT + 1 + 64]; int n; } MycZoneList;

static void MycZoneParts_(const MycItem* target, const MycAnalysis* cape, MycZoneParts* parts)
{
    memset(parts, 0, sizeof *parts);
    for (int i = 0; i < target->nrows; i++)
    {
        const MycRow* row = &target->rows[i];
        if (row->row < 0 || row->row >= 5) continue;
        if (cape->has_tint && row->lut == cape->tint_cape) parts->p[row->row].tint = row;
        else parts->p[row->row].base = row;
    }
}

static void MycZoneLinear(const MycRow* row, const MycPlan* plan, double out[3])
{
    const MycGoal* goal = plan != NULL ? myc_plan_get(plan, row->key) : NULL;
    if (goal != NULL) myc_lab_to_linear(goal->L, goal->a, goal->b, out);
    else myc_lab_to_linear(row->L, row->a, row->b, out);
}

static double MycZoneLightness(const MycZonePart* p, const MycPlan* plan)
{
    double r = 0, g = 0, b = 0, w = 0, lin[3];
    const MycRow* rows[2] = {p->base, p->tint};
    for (int i = 0; i < 2; i++)
    {
        if (rows[i] == NULL) continue;
        MycZoneLinear(rows[i], plan, lin);
        r = r + rows[i]->tex_area * lin[0];
        g = g + rows[i]->tex_area * lin[1];
        b = b + rows[i]->tex_area * lin[2];
        w = w + rows[i]->tex_area;
    }
    return myc_linear_to_lab(r / w, g / w, b / w).L;
}

static int MycZoneApart(double L, const MycGroup* hue, double cL, double ca, double cb, double threshold)
{
    if (hue == NULL) return fabs(L - cL) >= threshold;
    double dL = hue->L - cL, da = hue->a - ca, db = hue->b - cb;
    return dL * dL + da * da + db * db >= threshold * threshold;
}

typedef struct MycZoneAcc { double good, total, mean; } MycZoneAcc;

static void MycZoneBorderRow(MycZoneAcc* acc, double L, const MycGroup* hue, const uint32_t* counts, const MycZonePart* p,
    const MycPlan* plan, double threshold)
{
    double base[3], tint[3];
    MycZoneLinear(p->base != NULL ? p->base : p->tint, plan, base);
    MycZoneLinear(p->tint != NULL ? p->tint : p->base, plan, tint);
    for (int k = 0; k < ZONE_BINS; k++)
    {
        double n = counts[k];
        if (!(n > 0)) continue;
        double t = (k + 0.5) / ZONE_BINS;
        MycLab c = myc_linear_to_lab(base[0] * (1 - t) + tint[0] * t, base[1] * (1 - t) + tint[1] * t, base[2] * (1 - t) + tint[2] * t);
        acc->total = acc->total + n;
        acc->mean = acc->mean + n * c.L;
        if (MycZoneApart(L, hue, c.L, c.a, c.b, threshold)) acc->good = acc->good + n;
    }
}

/* (border cells read, border cells, mean border L) of a zone of lightness L against around as plan colors it. */
static void MycZoneReads(double L, const MycAround* around, const MycZoneParts* parts, const MycPlan* plan, double threshold,
    const MycGroup* hue, MycZoneAcc* out)
{
    memset(out, 0, sizeof *out);
    for (int q = 0; q < 5; q++)
    {
        const MycZonePart* p = &parts->p[q];
        if (around->present[q] && (p->base != NULL || p->tint != NULL))
            MycZoneBorderRow(out, L, hue, around->counts[q], p, plan, threshold);
    }
    out->mean = out->total > 0 ? out->mean / out->total : 0.0;
}

static void MycZoneCandidates(MycItem* source, MycZoneList* list)
{
    list->n = myc_palette_of(source, list->g);
    MycGroup* accent = myc_source_accent(source);
    if (accent == NULL) return;
    for (int i = 0; i < list->n; i++)
        if (list->g[i] == accent) return;
    list->g[list->n++] = accent;
}

static void MycZoneMinor(const MycItem* source, const MycZoneList* candidates, MycZoneList* list)
{
    list->n = 0;
    for (int i = 0; i < source->ngroups && list->n < 64; i++)
    {
        MycGroup* g = source->groups[i];
        int listed = 0;
        for (int c = 0; c < candidates->n; c++) listed |= candidates->g[c] == g;
        if (g->share >= MYC_ACCENT_SOURCE_BIG && !listed) list->g[list->n++] = g;
    }
}

static int MycZoneOnCloth(const MycGroup* g, const MycZoneCtx* z, int hue)
{
    if (!(hue && z->cloth != NULL)) return 1;
    MycZoneAcc acc;
    MycZoneReads(g->L, z->cloth, z->parts, z->plan, ZONE_READ, g, &acc);
    return 2 * acc.good >= acc.total;
}

/* The candidate reading against the most of a zone's border (ties: the order kept, then the earlier); NULL none. */
static MycGroup* MycZonePick(MycGroup* const* list, int n, const MycZoneCtx* z, int hue, double* best_good)
{
    MycGroup* best = NULL;
    int best_same = 0;
    for (int i = 0; i < n; i++)
    {
        MycGroup* g = list[i];
        if (!MycZoneOnCloth(g, z, hue)) continue;
        MycZoneAcc acc;
        MycZoneReads(g->L, z->around, z->parts, z->plan, ZONE_READ, hue ? g : NULL, &acc);
        int same = (g->L >= z->mean) == z->order;
        if (best == NULL || acc.good > *best_good || (acc.good == *best_good && same && !best_same))
        {
            best = g;
            *best_good = acc.good;
            best_same = same;
        }
    }
    return best;
}

static MycGroup* MycZoneChoice(MycGroup* const* candidates, int nc, MycGroup* const* minor, int nm, const MycZoneCtx* z,
    double total)
{
    double good = 0;
    MycGroup* best = MycZonePick(candidates, nc, z, 0, &good);
    if (best != NULL && 2 * good >= total) return best;
    if (!z->strong)
    {
        best = MycZonePick(candidates, nc, z, 1, &good);
        if (best != NULL && 2 * good >= total) return best;
    }
    best = MycZonePick(minor, nm, z, 0, &good);
    return best != NULL && 2 * good >= total ? best : NULL;
}

/* A neutral tone of the zone's planned border, LOST_TONE apart, named after key. */
static void MycZoneLostTone(const MycZoneCtx* z, const char* key, MycGroup* out)
{
    double L = z->order ? z->mean + LOST_TONE : z->mean - LOST_TONE;
    if (L < 8 || L > 92) L = z->order ? z->mean - LOST_TONE : z->mean + LOST_TONE;
    memset(out, 0, sizeof *out);
    out->kind = MYC_PSEUDO;
    out->L = myc_min(myc_max(L, 8), 92);
    memcpy(out->rep_key, key, MYC_KEY);
}

/* Zone p's rows take best, or (best NULL) keep their own colors; 0 out of memory. */
static int MycZoneApply(MycPlan* mapping, const MycZonePart* p, const MycGroup* best)
{
    const MycRow* rows[2] = {p->base, p->tint};
    for (int i = 0; i < 2; i++)
    {
        if (rows[i] == NULL) continue;
        if (best == NULL) { myc_plan_remove(mapping, rows[i]->key); continue; }
        MycGoal* goal = myc_plan_set(mapping, rows[i]->key);
        if (goal == NULL) return 0;
        memcpy(goal->source, best->rep_key, MYC_KEY);
        goal->kind = MYC_KIND_ZONE;
        goal->L = best->L;
        goal->a = best->a;
        goal->b = best->b;
        goal->has_cal = rows[i]->has_cal;
        memcpy(goal->cal, rows[i]->cal, sizeof goal->cal);
    }
    return 1;
}

static void MycZoneAround(const MycZones* zones, int z, MycAround* out)
{
    memset(out, 0, sizeof *out);
    for (int q = 0; q < 5; q++)
    {
        out->present[q] = zones->present[z][q];
        memcpy(out->counts[q], zones->counts[z][q], sizeof out->counts[q]);
    }
}

static int MycZoneExists(const MycZones* zones, int z)
{
    for (int q = 0; q < 5; q++)
        if (zones->present[z][q]) return 1;
    return 0;
}

/* The part of a zone's border on rows that are no design zones; 0 when none. */
static int MycZoneCloth(const MycAround* around, const MycZones* zones, MycAround* out)
{
    int any = 0;
    memset(out, 0, sizeof *out);
    for (int q = 0; q < 5; q++)
        if (around->present[q] && !MycZoneExists(zones, q))
        {
            out->present[q] = 1;
            memcpy(out->counts[q], around->counts[q], sizeof out->counts[q]);
            any = 1;
        }
    return any;
}

typedef struct MycZoneRule
{
    MycZoneList candidates, minor;
    const MycZones* zones;
    const MycItem* target;
    const MycGroup* taken[256];  /* per target group */
} MycZoneRule;

static int MycZoneGroupOf(const MycItem* target, const MycRow* row)
{
    int found = -1;
    for (int i = 0; i < target->ngroups && found < 0; i++)
        for (int r = 0; r < target->groups[i]->nrows; r++)
            if (target->groups[i]->rows[r] == row) { found = i; break; }
    return found;
}

#define OUTCOME_NONE 0
#define OUTCOME_PICKED 1
#define OUTCOME_KEPT 2
#define OUTCOME_LOST 3

/* A lost zone with no source color reading: its own colors, a lost tone, or lost. */
static int MycZoneFallback(MycPlan* mapping, const MycZonePart* p, double L0, const MycZoneCtx* zone, const MycZoneRule* rule,
    double total, int* outcome)
{
    MycZoneAcc acc;
    MycZoneReads(L0, zone->around, zone->parts, mapping, ZONE_READ, NULL, &acc);
    if (2 * acc.good >= total) { *outcome = OUTCOME_KEPT; return MycZoneApply(mapping, p, NULL); }
    double cloth_cells = 0;
    if (zone->cloth != NULL)
    {
        MycZoneReads(L0, zone->cloth, zone->parts, mapping, ZONE_READ, NULL, &acc);
        cloth_cells = acc.total;
    }
    *outcome = OUTCOME_LOST;
    if (!(zone->strong && 2 * cloth_cells >= total) || rule->candidates.n == 0) return 1;
    MycGroup tone;
    MycZoneLostTone(zone, rule->candidates.g[0]->rep_key, &tone);
    *outcome = OUTCOME_PICKED;
    return MycZoneApply(mapping, p, &tone);
}

/* One zone kept readable (keep_zone); 0 out of memory. */
static int MycZoneKeep(MycPlan* mapping, int z, const MycZoneParts* parts, MycZoneRule* rule, int* outcome)
{
    const MycZonePart* p = &parts->p[z];
    MycAround around, cloth;
    MycZoneAround(rule->zones, z, &around);
    double L0 = MycZoneLightness(p, NULL);
    MycZoneAcc before, now;
    *outcome = OUTCOME_NONE;
    MycZoneReads(L0, &around, parts, NULL, ZONE_READ, NULL, &before);
    if (before.total == 0 || 2 * before.good < before.total) return 1;
    MycZoneReads(MycZoneLightness(p, mapping), &around, parts, mapping, ZONE_LOST, NULL, &now);
    if (2 * now.good >= now.total) return 1;
    MycZoneCtx zone = {&around, MycZoneCloth(&around, rule->zones, &cloth) ? &cloth : NULL, parts, mapping,
                       L0 >= before.mean, fabs(L0 - before.mean) >= STRONG_GAP, now.mean};
    int group = MycZoneGroupOf(rule->target, p->base != NULL ? p->base : p->tint);
    const MycGroup* taken = group >= 0 && group < 256 ? rule->taken[group] : NULL;
    MycGroup* best = NULL;
    if (taken != NULL) best = MycZoneChoice((MycGroup* const*)&taken, 1, NULL, 0, &zone, now.total);
    if (best == NULL) best = MycZoneChoice(rule->candidates.g, rule->candidates.n, rule->minor.g, rule->minor.n, &zone, now.total);
    if (best == NULL) return MycZoneFallback(mapping, p, L0, &zone, rule, now.total, outcome);
    if (group >= 0 && group < 256 && taken == NULL) rule->taken[group] = best;
    *outcome = OUTCOME_PICKED;
    return MycZoneApply(mapping, p, best);
}

static void MycZoneCount(MycZoneOutcome* out, int outcome)
{
    if (outcome == OUTCOME_PICKED) out->picked++;
    else if (outcome == OUTCOME_KEPT) out->kept++;
    else if (outcome == OUTCOME_LOST) out->lost++;
}

static double MycZoneArea(const MycZonePart* p)
{
    double area = 0.0;
    if (p->base != NULL) area = area + p->base->tex_area;
    if (p->tint != NULL) area = area + p->tint->tex_area;
    return area;
}

int myc_cape_zones(MycPlan* mapping, MycItem* target, MycItem* source, const MycAnalysis* cape, MycZoneOutcome* out)
{
    memset(out, 0, sizeof *out);
    if (cape->zones == NULL) return 1;
    MycZoneParts parts;
    MycZoneParts_(target, cape, &parts);
    int order[5], n = 0;
    for (int z = 0; z < 5; z++)
        if (MycZoneExists(cape->zones, z) && (parts.p[z].base != NULL || parts.p[z].tint != NULL)) order[n++] = z;
    for (int i = 1; i < n; i++) /* by area, most first, then zone: a strict order */
        for (int j = i; j > 0 && MycZoneArea(&parts.p[order[j]]) > MycZoneArea(&parts.p[order[j - 1]]); j--)
        {
            int t = order[j];
            order[j] = order[j - 1];
            order[j - 1] = t;
        }
    static MycZoneRule rule;
    memset(&rule, 0, sizeof rule);
    MycZoneCandidates(source, &rule.candidates);
    MycZoneMinor(source, &rule.candidates, &rule.minor);
    rule.zones = cape->zones;
    rule.target = target;
    for (int i = 0; i < n; i++)
    {
        int outcome;
        if (!MycZoneKeep(mapping, order[i], &parts, &rule, &outcome)) return 0;
        MycZoneCount(out, outcome);
    }
    return 1;
}

/* One emblem (keep_emblem): its pick, or none. */
static void MycZoneEmblem(const MycEmblem* e, const MycZoneParts* parts, const MycPlan* mapping, const MycZoneList* candidates,
    const MycZoneList* minor, MycEmblemPick* pick, int* outcome)
{
    MycAround around;
    memset(&around, 0, sizeof around);
    around.present[e->around_row] = 1;
    memcpy(around.counts[e->around_row], e->counts, sizeof around.counts[0]);
    MycZoneAcc before, now;
    *outcome = OUTCOME_NONE;
    memset(pick, 0, sizeof *pick);
    MycZoneReads(e->L, &around, parts, NULL, ZONE_READ, NULL, &before);
    if (before.total == 0 || 2 * before.good < before.total) return;
    MycZoneReads(e->L, &around, parts, mapping, ZONE_LOST, NULL, &now);
    if (2 * now.good >= now.total) return;
    MycZoneCtx z = {&around, NULL, parts, mapping, e->L >= before.mean, fabs(e->L - before.mean) >= STRONG_GAP, now.mean};
    MycGroup tone;
    const MycGroup* best = MycZoneChoice(candidates->g, candidates->n, minor->g, minor->n, &z, now.total);
    if (best == NULL && z.strong && candidates->n > 0)
    {
        MycZoneLostTone(&z, candidates->g[0]->rep_key, &tone);
        best = &tone;
    }
    *outcome = OUTCOME_LOST;
    if (best == NULL) return;
    *outcome = OUTCOME_PICKED;
    pick->has = 1;
    memcpy(pick->source, best->rep_key, MYC_KEY);
    pick->L = best->L;
    pick->a = best->a;
    pick->b = best->b;
}

int myc_cape_emblems(const MycPlan* mapping, MycItem* target, MycItem* source, const MycAnalysis* cape,
    MycEmblemPick* picks, MycZoneOutcome* out)
{
    memset(out, 0, sizeof *out);
    if (cape->nemblems == 0) return 1;
    MycZoneParts parts;
    MycZoneParts_(target, cape, &parts);
    int order[64], n = cape->nemblems < 64 ? cape->nemblems : 64;
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 1; i < n; i++) /* by cells, most first, then index: a strict order */
        for (int j = i; j > 0 && cape->emblems[order[j]].cells > cape->emblems[order[j - 1]].cells; j--)
        {
            int t = order[j];
            order[j] = order[j - 1];
            order[j - 1] = t;
        }
    static MycZoneList candidates, minor;
    MycZoneCandidates(source, &candidates);
    MycZoneMinor(source, &candidates, &minor);
    for (int i = 0; i < n; i++)
    {
        int outcome;
        MycZoneEmblem(&cape->emblems[order[i]], &parts, mapping, &candidates, &minor, &picks[order[i]], &outcome);
        if (outcome == OUTCOME_PICKED) out->picked++;
        else if (outcome == OUTCOME_LOST) out->lost++;
    }
    return 1;
}
