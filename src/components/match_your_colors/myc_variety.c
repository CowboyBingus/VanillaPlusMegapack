/* Match Your Colors: an armor never left in one color (variety.lua, v1.5), 1:1. An armor's plan is dominated when one
 * design color covers DOMINANT_SHARE of the paint that shows and less than SECOND_MIN of it reads apart (CIE76 >=
 * APART); then that color's rows take roles (hard parts and a coat keep it, clothing takes the source's secondary,
 * gear its dark, colored trims its accent), the darkest main parts are shaded while too little reads apart, and a
 * prosthetic limb takes the source's dark muted color. Runs on the worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "myc_match.h"

#define DOMINANT_SHARE 0.85
#define SECOND_MIN 0.10
#define APART 15.0
#define COAT_SHARE 0.10
#define DARKEST_SHARE 0.25
#define ACCENT_MIN_SHARE 0.005
#define VARIETY_KEEP_DE 8.0
#define SECOND_MIN_SHARE 0.10
#define DARK_SECOND_SHARE 0.05
#define DARK_NEUTRAL_L 35.0
#define DARK_NEUTRAL_C 8.0
#define ROW_MAX 0.90
#define ROLE_TONE 6.0
#define TONE_UP 2.0
#define PROSTHETIC_LUT 0x5789f549cead6c3dull
#define PROSTHETIC_DARK_L 40.0
#define PALETTE_LIMIT 8
#define CELL_KEY (MYC_KEY + 24)

#define ROLE_NONE 0
#define ROLE_MAIN 1
#define ROLE_SECOND 2
#define ROLE_DARK 3
#define ROLE_ACCENT 4

/* A plan color over what shows: its row, group, key (its source, source/tone, or "#<group index>" when kept). */
typedef struct MycCell { MycRow* row; const MycGroup* group; char key[CELL_KEY]; double L, a, b, share; } MycCell;
typedef struct MycCells { MycCell* cells; int n; } MycCells;
/* A role color: g its source group (NULL for a tone of the main color, derived). */
typedef struct MycVColor { double L, a, b; const MycGroup* g; int derived; } MycVColor;
typedef struct MycKept { MycGroup** list; int n; } MycKept;
typedef struct MycDominance { int has; char key[CELL_KEY]; double share, distinct; MycVColor mean; } MycDominance;
typedef struct MycRoles
{
    MycVColor main, second, dark, accent;
    int has_accent;
    char main_key[CELL_KEY];
} MycRoles;

static int MycVarietyApart(double L1, double a1, double b1, const MycVColor* y)
{
    double dL = L1 - y->L, da = a1 - y->a, db = b1 - y->b;
    return dL * dL + da * da + db * db >= APART * APART;
}

static MycVColor MycVarietyColorOf(const MycGroup* g)
{
    MycVColor c = {g->has_g ? g->gL : g->L, g->has_g ? g->ga : g->a, g->has_g ? g->gb : g->b, g, 0};
    return c;
}

static int MycVarietyMuted(const MycGroup* g) { return myc_chroma(g->ma, g->mb) < MYC_ACCENT_C; }

static void MycVarietyCellOf(const MycPlan* plan, const MycGroup* g, int gi, MycRow* row, double paint_area, MycCell* c)
{
    const MycGoal* m = myc_plan_get(plan, row->key);
    c->row = row;
    c->group = g;
    c->share = row->area / paint_area;
    if (m == NULL)
    {
        snprintf(c->key, CELL_KEY, "#%d", gi);
        c->L = row->L;
        c->a = row->a;
        c->b = row->b;
        return;
    }
    if (m->shows[0] != 0) snprintf(c->key, CELL_KEY, "%s", m->shows);
    else if (m->tone[0] != 0) snprintf(c->key, CELL_KEY, "%s/%s", m->source, m->tone);
    else snprintf(c->key, CELL_KEY, "%s", m->source);
    c->L = m->L;
    c->a = m->a;
    c->b = m->b;
}

static int MycVarietyCells(const MycPlan* plan, const MycItem* t, MycCells* out)
{
    int total = 0;
    for (int gi = 0; gi < t->ngroups; gi++) total += t->groups[gi]->nrows;
    out->cells = myc_alloc(plan->arena, sizeof(MycCell) * (size_t)(total + 1));
    out->n = 0;
    if (out->cells == NULL) return 0;
    for (int gi = 0; gi < t->ngroups; gi++)
        for (int r = 0; r < t->groups[gi]->nrows; r++)
            if (t->groups[gi]->rows[r]->area > 0)
                MycVarietyCellOf(plan, t->groups[gi], gi + 1, t->groups[gi]->rows[r], t->paint_area, &out->cells[out->n++]);
    return 1;
}

static double MycVarietyDistinct(const MycCells* cells, const MycVColor* mean)
{
    double distinct = 0.0;
    for (int i = 0; i < cells->n; i++)
        if (MycVarietyApart(cells->cells[i].L, cells->cells[i].a, cells->cells[i].b, mean)) distinct = distinct + cells->cells[i].share;
    return distinct;
}

/* The target's patterns the pattern plan leaves in their own color (Variety.kept_patterns). */
static int MycVarietyKept(MycPlan* plan, MycItem* t, MycItem* s, MycKept* out)
{
    MycPlan planned;
    myc_plan_init(&planned, plan->arena);
    if (!myc_pattern_plan(&planned, t, s, plan)) return 0;
    out->list = myc_alloc(plan->arena, sizeof(MycGroup*) * (size_t)(t->npatterns + 1));
    out->n = 0;
    if (out->list == NULL) return 0;
    char name[17];
    for (int i = 0; i < t->npatterns; i++)
    {
        myc_hex(name, t->patterns[i]->pattern);
        if (myc_plan_get(&planned, name) == NULL && t->patterns[i]->share > 0) out->list[out->n++] = t->patterns[i];
    }
    return 1;
}

typedef struct MycVarietyBy { const char* key; double share, L, a, b; } MycVarietyBy;

/* Variety.dominance into d (d->has 0 when nothing shows); 0 out of memory. */
static int MycVarietyDominance(MycArena* arena, const MycCells* cells, const MycKept* kept, MycDominance* d)
{
    MycVarietyBy* by = myc_alloc(arena, sizeof(MycVarietyBy) * (size_t)(cells->n + 1));
    if (by == NULL) return 0;
    int n = 0;
    double total = 0.0;
    for (int i = 0; i < cells->n; i++)
    {
        const MycCell* c = &cells->cells[i];
        int k = 0;
        while (k < n && strcmp(by[k].key, c->key) != 0) k++;
        if (k == n) by[n++] = (MycVarietyBy){c->key, 0.0, 0.0, 0.0, 0.0};
        by[k].share = by[k].share + c->share;
        by[k].L = by[k].L + c->share * c->L;
        by[k].a = by[k].a + c->share * c->a;
        by[k].b = by[k].b + c->share * c->b;
        total = total + c->share;
    }
    const MycVarietyBy* top = NULL;
    for (int k = 0; k < n; k++)
        if (top == NULL || by[k].share > top->share) top = &by[k];
    memset(d, 0, sizeof *d);
    if (top == NULL || top->share <= 0) return 1;
    d->has = 1;
    snprintf(d->key, CELL_KEY, "%s", top->key);
    d->mean = (MycVColor){top->L / top->share, top->a / top->share, top->b / top->share, NULL, 0};
    double apart_kept = 0.0;
    for (int i = 0; i < kept->n; i++)
        if (MycVarietyApart(kept->list[i]->L, kept->list[i]->a, kept->list[i]->b, &d->mean)) apart_kept = apart_kept + kept->list[i]->share;
    double all = total + apart_kept;
    d->share = top->share / all;
    d->distinct = (MycVarietyDistinct(cells, &d->mean) + apart_kept) / all;
    return 1;
}

static MycVColor MycVarietyTone(const MycVColor* c, double dL, double k)
{
    double L = c->L + dL;
    if (L < 12 || L > 90) L = c->L - dL;
    MycVColor out = {myc_min(myc_max(L, 12), 90), c->a * k, c->b * k, NULL, 1};
    return out;
}

static double MycVarietySecondShare(const MycGroup* g, const MycVColor* c)
{
    if (c->L < DARK_NEUTRAL_L && myc_chroma(g->ma, g->mb) < DARK_NEUTRAL_C) return DARK_SECOND_SHARE;
    return SECOND_MIN_SHARE;
}

/* The source's secondary and dark colors for main (second_and_dark); 0 when it has no secondary. */
static int MycVarietySecondDark(const MycItem* source, const MycVColor* main, MycVColor* second, MycVColor* dark)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette), has_second = 0, has_dark = 0;
    for (int i = 0; i < m; i++)
    {
        const MycGroup* g = palette[i];
        MycVColor c = MycVarietyColorOf(g);
        if (g == main->g || g->hood || !MycVarietyMuted(g) || !MycVarietyApart(c.L, c.a, c.b, main)) continue;
        int paint = source->suit_paint || !myc_is_structure(g);
        if (!has_second && !g->rep->metal && g->share >= MycVarietySecondShare(g, &c) && paint) { *second = c; has_second = 1; }
        if (!has_dark || c.L < dark->L) { *dark = c; has_dark = 1; }
    }
    if (!has_second) return 0;
    if (!has_dark) *dark = MycVarietyTone(main, main->L >= 40 ? -25 : -6, 0.33);
    return 1;
}

/* The source's accent for main and second (accent_of); 0 when none. */
static int MycVarietyAccentOf(const MycItem* source, const MycVColor* main, const MycVColor* second, MycVColor* out)
{
    MycGroup* a = myc_source_accent(source);
    if (a != NULL && a != main->g)
    {
        MycVColor c = MycVarietyColorOf(a);
        if (MycVarietyApart(c.L, c.a, c.b, main) && MycVarietyApart(c.L, c.a, c.b, second)) { *out = c; return 1; }
    }
    int found = 0;
    double score = -1.0;
    for (int i = 0; i < source->ngroups; i++)
    {
        const MycGroup* g = source->groups[i];
        MycVColor c = MycVarietyColorOf(g);
        double s = myc_chroma(g->ma, g->mb) * sqrt(g->share);
        int apart = MycVarietyApart(c.L, c.a, c.b, main) && MycVarietyApart(c.L, c.a, c.b, second);
        if (g != main->g && !g->hood && g->share >= ACCENT_MIN_SHARE && apart && s > score) { *out = c; score = s; found = 1; }
    }
    return found;
}

static int MycVarietyMatchesPalette(const MycGroup* g, const MycItem* source)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette);
    for (int i = 0; i < m; i++)
    {
        MycVColor c = MycVarietyColorOf(palette[i]);
        if (myc_de2000(g->L, g->a, g->b, c.L, c.a, c.b) < VARIETY_KEEP_DE) return 1;
    }
    return 0;
}

/* The LUTs whose soft rows outside undergarment pieces show on COAT_SHARE of the paint (coats_of): luts/coat arrays. */
typedef struct MycCoats { uint64_t* luts; double* share; int n; } MycCoats;

static int MycVarietyCoats(MycArena* arena, const MycCells* cells, MycCoats* out)
{
    out->luts = myc_alloc(arena, sizeof(uint64_t) * (size_t)(cells->n + 1));
    out->share = myc_alloc(arena, sizeof(double) * (size_t)(cells->n + 1));
    out->n = 0;
    if (out->luts == NULL || out->share == NULL) return 0;
    for (int i = 0; i < cells->n; i++)
    {
        const MycRow* row = cells->cells[i].row;
        if (row->mode < 0.5 || row->under >= 0.5 * row->area) continue;
        int k = 0;
        while (k < out->n && out->luts[k] != row->lut) k++;
        if (k == out->n) { out->luts[k] = row->lut; out->share[k] = 0.0; out->n++; }
        out->share[k] = out->share[k] + cells->cells[i].share;
    }
    return 1;
}

static int MycVarietyIsCoat(const MycCoats* coats, uint64_t lut)
{
    for (int k = 0; k < coats->n; k++)
        if (coats->luts[k] == lut) return coats->share[k] >= COAT_SHARE;
    return 0;
}

static int MycVarietyRoleOf(const MycCell* c, const MycCoats* coats)
{
    const MycGroup* g = c->group;
    const MycRow* row = c->row;
    if (myc_chroma(g->ma, g->mb) >= MYC_ACCENT_C && g->share < MYC_MAIN_COLOR) return ROLE_ACCENT;
    int under = row->under >= 0.5 * row->area, hard = row->mode < 0.5;
    if (!under && (hard || MycVarietyIsCoat(coats, row->lut))) return ROLE_MAIN;
    return under && !hard ? ROLE_SECOND : ROLE_DARK;
}

/* Row c takes role color `color` (Lua assign); 0 out of memory. */
static int MycVarietyAssign(MycPlan* plan, MycCell* c, const MycVColor* color, int kind, const char* main_key, const char* role)
{
    const MycRow* row = c->row;
    double up = color->derived ? TONE_UP : ROLE_TONE;
    double offset = myc_max(-ROLE_TONE, myc_min(up, row->L - c->group->L));
    double L = color->L + offset;
    MycGoal* goal = myc_plan_set(plan, row->key);
    if (goal == NULL) return 0;
    snprintf(goal->source, MYC_KEY, "%s", color->g != NULL ? color->g->rep_key : main_key);
    goal->kind = kind;
    goal->L = L;
    goal->a = color->a;
    goal->b = color->b;
    goal->has_cal = row->has_cal;
    memcpy(goal->cal, row->cal, sizeof goal->cal);
    if (color->derived) snprintf(goal->tone, sizeof goal->tone, "%s", role);
    c->L = L;
    c->a = color->a;
    c->b = color->b;
    return 1;
}

static void MycVarietyUnplan(MycPlan* plan, MycCell* c)
{
    myc_plan_remove(plan, c->row->key);
    c->L = c->row->L;
    c->a = c->row->a;
    c->b = c->row->b;
}

static int MycVarietyProsthetics(MycPlan* plan, MycCells* cells, const MycItem* source)
{
    MycGroup* palette[PALETTE_LIMIT];
    int m = myc_palette_of(source, palette), has = 0;
    MycVColor dark = {0};
    for (int i = 0; i < m; i++)
    {
        MycVColor c = MycVarietyColorOf(palette[i]);
        if (!palette[i]->hood && MycVarietyMuted(palette[i]) && c.L < PROSTHETIC_DARK_L && (!has || c.L < dark.L)) { dark = c; has = 1; }
    }
    for (int i = 0; i < cells->n; i++)
    {
        MycCell* c = &cells->cells[i];
        if (c->row->lut != PROSTHETIC_LUT) continue;
        if (!has) { MycVarietyUnplan(plan, c); continue; }
        if (!MycVarietyAssign(plan, c, &dark, MYC_KIND_PAIR, dark.g->rep_key, "prosthetic")) return 0;
    }
    return 1;
}

static int MycVarietyDarkerLess(const void* x, const void* y, void* ctx)
{
    const MycCell* a = x;
    const MycCell* b = y;
    if (a->row->L != b->row->L) return a->row->L < b->row->L;
    return strcmp(a->row->key, b->row->key) < 0;
}

/* The darkest of cells, up to DARKEST_SHARE of the paint (the darkest alone up to half), take color. */
static int MycVarietyDarken(MycPlan* plan, MycCell** list, int n, const MycVColor* color, const char* main_key, const char* role)
{
    myc_lua_sort((void**)list, n, MycVarietyDarkerLess, NULL);
    double taken = 0.0;
    for (int i = 0; i < n; i++)
    {
        if (taken + list[i]->share > (taken == 0 ? 0.5 : DARKEST_SHARE)) break;
        if (!MycVarietyAssign(plan, list[i], color, MYC_KIND_PAIR, main_key, role)) return 0;
        taken = taken + list[i]->share;
    }
    return 1;
}

static int MycVarietyDominated(const MycDominance* d)
{
    return d->has && d->share >= DOMINANT_SHARE && d->distinct < SECOND_MIN;
}

/* Still dominated by a role color: its darkest cells take the first of colors reading apart from it, else a tone. */
static int MycVarietySettle(MycPlan* plan, const MycItem* t, const MycVColor* colors, const char* main_key, const MycKept* kept)
{
    MycCells cells;
    MycDominance d;
    if (!MycVarietyCells(plan, t, &cells) || !MycVarietyDominance(plan->arena, &cells, kept, &d)) return 0;
    if (!MycVarietyDominated(&d)) return 1;
    MycVColor pick = MycVarietyTone(&d.mean, d.mean.L >= 45 ? -18 : 15, 0.5);
    for (int i = 2; i >= 0; i--)
        if (MycVarietyApart(colors[i].L, colors[i].a, colors[i].b, &d.mean)) pick = colors[i];
    MycCell** list = myc_alloc(plan->arena, sizeof(MycCell*) * (size_t)(cells.n + 1));
    if (list == NULL) return 0;
    int n = 0;
    for (int i = 0; i < cells.n; i++)
        if (strcmp(cells.cells[i].key, d.key) == 0 && cells.cells[i].row->lut != PROSTHETIC_LUT) list[n++] = &cells.cells[i];
    return MycVarietyDarken(plan, list, n, &pick, main_key, "settle");
}

/* The dominant color of the plan, as given and as the prosthetic rule leaves it (Lua dominant); d->has 0 when not
 * dominated. */
static int MycVarietyDominant(MycPlan* plan, MycItem* t, MycItem* s, MycCells* cells, MycDominance* d, MycKept* kept)
{
    if (!MycVarietyCells(plan, t, cells) || !MycVarietyKept(plan, t, s, kept)) return 0;
    if (!MycVarietyDominance(plan->arena, cells, kept, d) || !MycVarietyProsthetics(plan, cells, s)) return 0;
    if (MycVarietyDominated(d)) return 1;
    if (!MycVarietyCells(plan, t, cells) || !MycVarietyDominance(plan->arena, cells, kept, d)) return 0;
    if (!MycVarietyDominated(d)) d->has = 0;
    return 1;
}

static int MycVarietyOneRow(const MycCells* cells)
{
    for (int i = 0; i < cells->n; i++)
        if (cells->cells[i].share > ROW_MAX) return 1;
    return 0;
}

/* The role colors of a dominated plan; 0 when the source has no secondary of its own. */
static int MycVarietyRoleColors(MycItem* s, const MycDominance* d, MycRoles* k)
{
    const MycGroup* main_g = NULL;
    for (int i = 0; i < s->ngroups; i++)
        if (strcmp(s->groups[i]->rep_key, d->key) == 0) main_g = s->groups[i];
    memset(k, 0, sizeof *k);
    k->main = (MycVColor){d->mean.L, d->mean.a, d->mean.b, main_g, 0};
    if (!MycVarietySecondDark(s, &k->main, &k->second, &k->dark)) return 0;
    if (d->key[0] != '#') snprintf(k->main_key, CELL_KEY, "%s", d->key);
    else
    {
        const MycGroup* id = myc_identity(s);
        snprintf(k->main_key, CELL_KEY, "%s", (id != NULL ? id : s->groups[0])->rep_key);
    }
    k->has_accent = MycVarietyAccentOf(s, &k->main, &k->second, &k->accent);
    return 1;
}

static int MycVarietyAccentCell(MycPlan* plan, MycCell* c, const MycRoles* k, const MycItem* s)
{
    if (k->has_accent) return MycVarietyAssign(plan, c, &k->accent, MYC_KIND_ACCENT, k->main_key, "accent");
    if (MycVarietyMatchesPalette(c->group, s)) { MycVarietyUnplan(plan, c); return 1; }
    MycVColor tone = MycVarietyTone(&k->main, k->second.L > k->main.L ? -25 : 25, 1.0);
    return MycVarietyAssign(plan, c, &tone, MYC_KIND_ACCENT, k->main_key, "accent");
}

static int MycVarietyPlayRole(MycPlan* plan, MycCell* c, int role, const MycRoles* k, const MycItem* s)
{
    if (role == ROLE_SECOND) return MycVarietyAssign(plan, c, &k->second, MYC_KIND_PAIR, k->main_key, "second");
    if (role == ROLE_DARK) return MycVarietyAssign(plan, c, &k->dark, MYC_KIND_PAIR, k->main_key, "dark");
    if (role == ROLE_ACCENT) return MycVarietyAccentCell(plan, c, k, s);
    return 1;
}

static double MycVarietyDeviation(double m, double s2, double s3, const double src[3])
{
    double total = m + s2 + s3, stotal = src[0] + src[1] + src[2];
    if (total <= 0 || stotal <= 0) return 0.0;
    return fabs(m / total - src[0] / stotal) + fabs(s2 / total - src[1] / stotal) + fabs(s3 / total - src[2] / stotal);
}

static double MycVarietyGroupShare(const MycGroup* g) { return g != NULL ? g->share : 0.0; }

/* Whether the clothing keeping the main color brings the role shares closer to the source's (shares: main, second,
 * dark). */
static int MycVarietyMainKeeps(const double share[4], const MycRoles* k)
{
    int same = k->dark.g != NULL && k->dark.g == k->second.g;
    double src[3] = {MycVarietyGroupShare(k->main.g), MycVarietyGroupShare(k->second.g), 0.0};
    double with_second = 0.0, dark = share[ROLE_DARK];
    if (same) { with_second = share[ROLE_DARK]; dark = 0.0; }
    else src[2] = MycVarietyGroupShare(k->dark.g);
    double kept = MycVarietyDeviation(share[ROLE_MAIN], share[ROLE_SECOND] + with_second, dark, src);
    return MycVarietyDeviation(share[ROLE_MAIN] + share[ROLE_SECOND], with_second, dark, src) < kept;
}

static void MycVarietyRoles(const MycCells* cells, const char* key, const MycCoats* coats, const MycRoles* k, int* roles)
{
    double share[4] = {0.0, 0.0, 0.0, 0.0};
    for (int i = 0; i < cells->n; i++)
    {
        const MycCell* c = &cells->cells[i];
        int mine = strcmp(c->key, key) == 0 && c->row->lut != PROSTHETIC_LUT;
        roles[i] = mine ? MycVarietyRoleOf(c, coats) : ROLE_NONE;
        if (roles[i] >= ROLE_MAIN && roles[i] <= ROLE_DARK) share[roles[i]] = share[roles[i]] + c->share;
    }
    if (!(k->second.L > k->main.L && MycVarietyMainKeeps(share, k))) return;
    for (int i = 0; i < cells->n; i++)
        if (roles[i] == ROLE_SECOND) roles[i] = ROLE_MAIN;
}

/* Too little apart after the roles: the darkest main parts take the darker of secondary and dark reading apart. */
static int MycVarietyShade(MycPlan* plan, MycCells* cells, const int* roles, const MycRoles* k)
{
    const MycVColor* darker = k->second.L < k->dark.L ? &k->second : &k->dark;
    const MycVColor* pick = NULL;
    if (MycVarietyApart(darker->L, darker->a, darker->b, &k->main)) pick = darker;
    else if (MycVarietyApart(k->second.L, k->second.a, k->second.b, &k->main)) pick = &k->second;
    if (pick == NULL) return 1;
    MycCell** mains = myc_alloc(plan->arena, sizeof(MycCell*) * (size_t)(cells->n + 1));
    if (mains == NULL) return 0;
    int n = 0;
    for (int i = 0; i < cells->n; i++)
        if (roles[i] == ROLE_MAIN) mains[n++] = &cells->cells[i];
    return MycVarietyDarken(plan, mains, n, pick, k->main_key, "shade");
}

/* The roles, the shade and the two settles of a dominated plan with role colors k. */
static int MycVarietySplit(MycPlan* plan, MycItem* t, MycItem* s, MycCells* cells, const MycDominance* d, const MycKept* kept,
    const MycRoles* k)
{
    MycCoats coats;
    int* roles = myc_alloc(plan->arena, sizeof(int) * (size_t)(cells->n + 1));
    if (roles == NULL || !MycVarietyCoats(plan->arena, cells, &coats)) return 0;
    MycVarietyRoles(cells, d->key, &coats, k, roles);
    for (int i = 0; i < cells->n; i++)
        if (roles[i] != ROLE_NONE && !MycVarietyPlayRole(plan, &cells->cells[i], roles[i], k, s)) return 0;
    if (MycVarietyDistinct(cells, &d->mean) < SECOND_MIN && !MycVarietyShade(plan, cells, roles, k)) return 0;
    MycVColor colors[3] = {k->dark, k->main, k->second};
    for (int i = 0; i < 2; i++)
        if (!MycVarietySettle(plan, t, colors, k->main_key, kept)) return 0;
    return 1;
}

int myc_balance(MycPlan* plan, MycItem* t, MycItem* s)
{
    if (s->ngroups == 0) return 1;
    MycCells cells;
    MycDominance d;
    MycKept kept;
    if (!MycVarietyDominant(plan, t, s, &cells, &d, &kept)) return 0;
    if (!d.has || MycVarietyOneRow(&cells)) return 1;
    MycRoles k;
    if (!MycVarietyRoleColors(s, &d, &k)) return 1;
    return MycVarietySplit(plan, t, s, &cells, &d, &kept, &k);
}
