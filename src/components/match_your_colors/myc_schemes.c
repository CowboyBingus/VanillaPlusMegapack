/* Match Your Colors: the game's weapon paint schemes (and SEAF) as paint schemes for the Helldiver (schemes.lua), 1:1.
 * A scheme is a source item of three rows of its m_weapon LUT (primary, secondary, cloth); SEAF's roles follow
 * materials (role_plan); a near one-color item under a cape is split by material the same way. Runs on the worker
 * inside a job. */
#include <math.h>
#include <string.h>
#include "myc_match.h"

#define PRIMARY 0.6
#define SECONDARY 0.25
#define CLOTH 0.15
#define ROLE_DARK_L 30.0
#define ROLE_PLATES 0.15
#define ROLE_CLOTH 0.10
#define ROLE_COAT 0.10
#define ROLE_LEAD 1.5
#define ROLE_TONE 6.0
#define LENS_L 28.0
#define CAPE_TONE_UP 2.0
#define CAPE_SPLIT 0.8
#define CAPE_APART 15.0
#define BLUE 1
#define UNIFORM 2
#define GEAR 3

#define NO_LOOKS {{0}}, {0}
const MycScheme myc_schemes[MYC_SCHEMES] = {
    {"helldiver", "Helldiver", 0xd7353578fc8df474ull, 0x9f09bf697ec501a0ull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"forest", "Forest", 0x5ea029039de33479ull, 0x1bd978d3960f3b97ull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"forest_camo", "Forest Camo", 0x6b79bbb20a303671ull, 0x72ba1e791ed0a166ull, 1, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"arctic", "Arctic", 0xbbba973314a3b3f1ull, 0x642d22bee762b6bdull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"arctic_camo", "Arctic Camo", 0x4acfca3e8fe5a0e6ull, 0xb0bfc364b70a43d4ull, 1, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"desert", "Desert", 0x09510b899fdd4a13ull, 0xf8d36a490676ec43ull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"desert_camo", "Desert Camo", 0x444ff90550d8c91bull, 0xade6c402bf0030c9ull, 1, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"urban", "Urban", 0x9bdac09de7dd4b69ull, 0x650af9d69b7696bcull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"urban_camo", "Urban Camo", 0x13455c609ccd9960ull, 0xbeaa6a092dde05d8ull, 1, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"night", "Night", 0x802cc92e12493f63ull, 0x7bb4597035f23c80ull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"venus", "Venus", 0x855ea06e998711dfull, 0x7b9692abb86210b4ull, 0, 0, {0, 1, 2}, 0, NO_LOOKS},
    {"seaf", "SEAF", 0x792b2a2ba11ae85dull, 0x493b5a6a30e49de5ull, 0, 1, {2, 1, 3}, 1,
     {{0, 0, 0}, {40.0, 0.0, 0.0}, {32.0, -1.0, -12.0}, {20.0, 0.0, 0.0}}, {0, 1, 1, 1}},
};

const MycScheme* myc_scheme_get(int index)
{
    return index >= 1 && index <= MYC_SCHEMES ? &myc_schemes[index - 1] : NULL;
}

/* The rows of a scheme's source item, primary first: row index, share, undersuit share. */
static void MycSchemeRoles(const MycScheme* scheme, int rows[3], double shares[3], double unders[3])
{
    rows[0] = scheme->camo ? 1 : 0;
    rows[1] = scheme->camo ? 0 : 1;
    rows[2] = 2;
    if (scheme->has_rows) memcpy(rows, scheme->rows, sizeof(int) * 3);
    shares[0] = PRIMARY;
    shares[1] = SECONDARY;
    shares[2] = CLOTH;
    unders[0] = 0;
    unders[1] = 0;
    unders[2] = CLOTH;
}

MycItem* myc_scheme_item(MycArena* arena, MycModel* model, const MycScheme* scheme, const MycLut* lut)
{
    int index[3];
    double shares[3], unders[3];
    MycSchemeRoles(scheme, index, shares, unders);
    MycRow* rows = myc_alloc(arena, sizeof(MycRow) * 3);
    if (rows == NULL) return NULL;
    int n = 0;
    for (int i = 0; i < 3; i++)
    {
        int r = index[i];
        if (r >= lut->height) continue;
        MycRowInfo info = myc_row_info(model, lut->values, lut->width, r);
        MycRow* row = &rows[n++];
        MycLab lab = myc_linear_to_lab(info.ar, info.ag, info.ab);
        if (r < 8 && scheme->has_look[r]) lab = (MycLab){scheme->looks[r][0], scheme->looks[r][1], scheme->looks[r][2]};
        myc_row_key(row->key, scheme->lut, r);
        row->lut = scheme->lut;
        row->row = r;
        row->area = shares[i];
        row->under = unders[i];
        row->L = lab.L;
        row->a = lab.a;
        row->b = lab.b;
        row->camo = info.camo;
        row->mode = info.mode;
        row->ar = info.ar;
        row->ag = info.ag;
        row->ab = info.ab;
        row->copy = info.camo;
        row->finish_changed = -1;
    }
    return myc_item(arena, rows, n, 1, NULL, 0, NULL, 0);
}

/* ---- material roles ----------------------------------------------------------------------------------------------- */

static int MycSchemeDark(const MycGroup* g) { return g->mL < ROLE_DARK_L && myc_chroma(g->ma, g->mb) < MYC_ACCENT_C; }
static int MycSchemeAccent(const MycGroup* g) { return myc_chroma(g->ma, g->mb) >= MYC_ACCENT_C && g->share < MYC_MAIN_COLOR; }
static int MycSchemeHard(const MycRow* row) { return row->mode < 0.5; }
static int MycSchemeClothing(const MycRow* row)
{
    return !MycSchemeHard(row) && row->area > 0 && row->under >= 0.5 * row->area;
}

/* What target item t has of its own (inventory) and the role plan's options. */
typedef struct MycHas
{
    int plates, cloth, armor, accent_role, materials, cape, metal_second;
    const MycGroup* main;
    double paint_area;
    const char** lead;  /* the uniform rows' keys (lead_rows) */
    int nlead;
} MycHas;

static int MycSchemeBefore(const void* x, const void* y, void* ctx)
{
    const MycRow* a = x;
    const MycRow* b = y;
    if (a->tex_area != b->tex_area) return a->tex_area > b->tex_area;
    return strcmp(a->key, b->key) < 0;
}

/* The dark clothing rows of LUT lut (not lit by light clothing) into out; how many. */
static int MycSchemeDarkClothing(const MycItem* t, uint64_t lut, MycRow** out)
{
    int n = 0;
    for (int i = 0; i < t->ngroups; i++)
    {
        const MycGroup* g = t->groups[i];
        if (g->hood || MycSchemeAccent(g) || !MycSchemeDark(g)) continue;
        for (int r = 0; r < g->nrows; r++)
            if (MycSchemeClothing(g->rows[r]) && g->rows[r]->lut == lut) out[n++] = g->rows[r];
    }
    return n;
}

/* The uniform rows of an item without light clothing (lead_rows): per LUT without light clothing, its largest dark
 * clothing row when ROLE_LEAD times the next. light: the LUTs with light clothing. */
static int MycSchemeLead(MycArena* arena, const MycItem* t, const uint64_t* light, int nlight, MycHas* has)
{
    MycRow** rows = myc_alloc(arena, sizeof(MycRow*) * (size_t)(t->nrows + 1));
    uint64_t* seen = myc_alloc(arena, sizeof(uint64_t) * (size_t)(t->nrows + 1));
    has->lead = myc_alloc(arena, sizeof(char*) * (size_t)(t->nrows + 1));
    if (rows == NULL || seen == NULL || has->lead == NULL) return 0;
    int nseen = 0;
    for (int i = 0; i < t->nrows; i++)
    {
        uint64_t lut = t->rows[i].lut;
        int known = 0;
        for (int k = 0; k < nseen; k++) known |= seen[k] == lut;
        for (int k = 0; k < nlight; k++) known |= light[k] == lut;
        if (known) continue;
        seen[nseen++] = lut;
        int n = MycSchemeDarkClothing(t, lut, rows);
        if (n == 0) continue;
        myc_lua_sort((void**)rows, n, MycSchemeBefore, NULL);
        if (n < 2 || rows[0]->tex_area >= ROLE_LEAD * rows[1]->tex_area) has->lead[has->nlead++] = rows[0]->key;
    }
    return 1;
}

static int MycSchemeInventory(MycArena* arena, const MycItem* t, MycHas* has)
{
    double plates = 0, cloth = 0;
    uint64_t* light = myc_alloc(arena, sizeof(uint64_t) * (size_t)(t->nrows + 1));
    if (light == NULL) return 0;
    int nlight = 0;
    for (int i = 0; i < t->ngroups; i++)
    {
        const MycGroup* g = t->groups[i];
        if (g->hood || MycSchemeAccent(g)) continue;
        int is_dark = MycSchemeDark(g);
        for (int r = 0; r < g->nrows; r++)
        {
            const MycRow* row = g->rows[r];
            double share = row->area / t->paint_area;
            if (!is_dark && MycSchemeHard(row)) plates = plates + share;
            if (!MycSchemeClothing(row) || is_dark) continue;
            cloth = cloth + share;
            light[nlight++] = row->lut;
        }
    }
    memset(has, 0, sizeof *has);
    has->plates = plates >= ROLE_PLATES;
    has->cloth = cloth >= ROLE_CLOTH;
    has->main = t->ngroups > 0 ? t->groups[0] : NULL;
    has->armor = t->armor;
    has->paint_area = t->paint_area;
    return MycSchemeLead(arena, t, light, nlight, has);
}

static int MycSchemeIsLead(const MycHas* has, const char* key)
{
    for (int i = 0; i < has->nlead; i++)
        if (strcmp(has->lead[i], key) == 0) return 1;
    return 0;
}

static int MycSchemeHardRole(const MycGroup* g, const MycHas* has)
{
    if (!MycSchemeDark(g)) return BLUE;
    if (has->plates || (g->share < MYC_PAINT_SHARE && g != has->main)) return GEAR;
    return BLUE;
}

static int MycSchemeSoftRole(const MycGroup* g, const MycRow* row, const MycHas* has)
{
    int large = row->area / has->paint_area >= ROLE_COAT;
    if (!has->armor) return large && g == has->main ? BLUE : GEAR;
    if (!MycSchemeClothing(row)) return large && !MycSchemeDark(g) ? UNIFORM : GEAR;
    if (!MycSchemeDark(g)) return UNIFORM;
    return !has->cloth && MycSchemeIsLead(has, row->key) ? UNIFORM : GEAR;
}

static int MycSchemeRowRole(const MycGroup* g, const MycRow* row, const MycHas* has)
{
    if (MycSchemeAccent(g)) return has->accent_role;
    if (MycSchemeHard(row)) return MycSchemeHardRole(g, has);
    return MycSchemeSoftRole(g, row, has);
}

/* Flat role colors: each row's tonal offset within ROLE_TONE (CAPE_TONE_UP lighter under a cape) of its role's look. */
static void MycSchemeFlat(MycPlan* mapping, const MycGroup* part, const MycGroup* src, int role, int cape)
{
    double L = src->L, a = src->a, b = src->b, up = ROLE_TONE;
    if (cape)
    {
        L = src->has_g ? src->gL : src->L;
        a = src->has_g ? src->ga : src->a;
        b = src->has_g ? src->gb : src->b;
        up = CAPE_TONE_UP;
    }
    for (int i = 0; i < part->nrows; i++)
    {
        MycGoal* goal = myc_plan_get(mapping, part->rows[i]->key);
        if (goal == NULL) continue;
        double tone = myc_max(-ROLE_TONE, myc_min(up, goal->L - L));
        goal->L = L + tone;
        goal->a = a;
        goal->b = b;
        goal->all = 1;
        if (role != UNIFORM && !cape) goal->has_cal = 0;
    }
}

static MycGroup* MycSchemeRoleColor(MycGroup* const* roles, int role, int is_hard, const MycHas* has)
{
    if (has->metal_second)
    {
        if (is_hard && role == BLUE) return roles[UNIFORM];
        if (!is_hard && role == UNIFORM) return roles[BLUE];
    }
    return roles[role];
}

/* Group g's rows by role and material (first seen first), each bucket mapped as a part of g. */
static int MycSchemeMapGroup(MycPlan* mapping, const MycGroup* g, MycGroup* const* roles, const MycHas* has)
{
    int keys[8], nkeys = 0;
    MycRow** bucket = myc_alloc(mapping->arena, sizeof(MycRow*) * (size_t)(g->nrows + 1));
    if (bucket == NULL) return 0;
    for (int i = 0; i < g->nrows; i++)
    {
        int k = MycSchemeRowRole(g, g->rows[i], has) * 2 + (MycSchemeHard(g->rows[i]) ? 1 : 0), known = 0;
        for (int j = 0; j < nkeys; j++) known |= keys[j] == k;
        if (!known && nkeys < 8) keys[nkeys++] = k;
    }
    for (int j = 0; j < nkeys; j++)
    {
        int role = keys[j] / 2, is_hard = keys[j] % 2 == 1, n = 0;
        for (int i = 0; i < g->nrows; i++)
            if (MycSchemeRowRole(g, g->rows[i], has) * 2 + (MycSchemeHard(g->rows[i]) ? 1 : 0) == keys[j]) bucket[n++] = g->rows[i];
        MycGroup* color = MycSchemeRoleColor(roles, role, is_hard, has);
        if (color == NULL) continue;
        MycGroup part = *g;
        part.rows = bucket;
        part.nrows = n;
        if (!myc_map_group(mapping, &part, MYC_KIND_PAIR, color, is_hard && has->materials, has->armor, 0)) return 0;
        MycSchemeFlat(mapping, &part, color, role, has->cape);
    }
    return 1;
}

static int MycSchemeLenses(MycPlan* mapping, const MycItem* t, const MycGroup* gear)
{
    for (int i = 0; gear != NULL && i < t->nrows; i++)
    {
        const MycRow* row = &t->rows[i];
        if (!row->lens || !(row->mode < 3.5) || row->emissive > 0 || myc_chroma(row->ma, row->mb) < MYC_ACCENT_C) continue;
        MycGoal* goal = myc_plan_set(mapping, row->key);
        if (goal == NULL) return 0;
        memcpy(goal->source, gear->rep_key, MYC_KEY);
        goal->kind = MYC_KIND_PAIR;
        goal->L = myc_min(row->L, LENS_L);
        goal->all = 1;
    }
    return 1;
}

/* The role plan's options: accent role, hard rows painted, a cape's split, lenses. */
typedef struct MycRoleOpts { int accent, lenses, materials, cape; } MycRoleOpts;

static MycGroup* MycSchemeByKey(MycItem* s, const char* key)
{
    MycGroup* found = NULL;
    for (int i = 0; i < s->ngroups; i++)
        for (int r = 0; r < s->groups[i]->nrows; r++)
            if (strcmp(s->groups[i]->rows[r]->key, key) == 0) found = s->groups[i];
    return found;
}

static int MycSchemeRolePlan(MycPlan* mapping, MycItem* t, MycItem* s, char keys[3][MYC_KEY], const MycRoleOpts* opts)
{
    MycGroup* roles[4] = {NULL, MycSchemeByKey(s, keys[0]), MycSchemeByKey(s, keys[1]), MycSchemeByKey(s, keys[2])};
    MycHas has;
    if (!MycSchemeInventory(mapping->arena, t, &has)) return 0;
    has.accent_role = opts->accent;
    has.materials = opts->materials;
    has.cape = opts->cape;
    has.metal_second = has.cape && has.materials && roles[UNIFORM] != NULL && roles[UNIFORM] != roles[BLUE]
        && roles[UNIFORM]->rep != NULL && roles[UNIFORM]->rep->metal;
    for (int i = 0; i < t->ngroups; i++)
        if (!t->groups[i]->hood && !MycSchemeMapGroup(mapping, t->groups[i], roles, &has)) return 0;
    if (opts->lenses && !MycSchemeLenses(mapping, t, roles[GEAR])) return 0;
    if (has.cape && t->armor) return myc_balance(mapping, t, s);
    return 1;
}

/* ---- a cape's split ----------------------------------------------------------------------------------------------- */

static int MycSchemeApart(const MycGroup* x, const MycGroup* y)
{
    double dL = x->L - y->L, da = x->a - y->a, db = x->b - y->b;
    return sqrt(dL * dL + da * da + db * db) >= CAPE_APART;
}

/* A cape source's main, second and darkest colors' keys (cape_keys). */
static void MycSchemeCapeKeys(MycItem* s, char keys[3][MYC_KEY])
{
    MycGroup* main = myc_identity(s);
    if (main == NULL) main = s->groups[0];
    MycGroup* second = NULL;
    MycGroup* dark = NULL;
    int dark_muted = 0;
    for (int i = 0; i < s->ngroups; i++)
        if (second == NULL && s->groups[i] != main && MycSchemeApart(s->groups[i], main)) second = s->groups[i];
    for (int i = 0; i < s->ngroups; i++)
    {
        MycGroup* g = s->groups[i];
        int muted = myc_chroma(g->ma, g->mb) < MYC_ACCENT_C;
        if (dark == NULL || (muted && !dark_muted) || (muted == dark_muted && g->L < dark->L)) { dark = g; dark_muted = muted; }
    }
    if (second == NULL) second = main;
    memcpy(keys[0], main->rep_key, MYC_KEY);
    memcpy(keys[1], second->rep_key, MYC_KEY);
    memcpy(keys[2], dark->rep_key, MYC_KEY);
}

int myc_metal_second(MycItem* s)
{
    char keys[3][MYC_KEY];
    if (s->ngroups == 0) return 0;
    MycSchemeCapeKeys(s, keys);
    if (strcmp(keys[1], keys[0]) == 0) return 0;
    for (int i = 0; i < s->ngroups; i++)
        if (strcmp(s->groups[i]->rep_key, keys[1]) == 0) return s->groups[i]->rep != NULL && s->groups[i]->rep->metal;
    return 0;
}

int myc_scheme_plan(MycPlan* plan, const MycScheme* scheme, MycItem* t, MycItem* s, int materials, int cape)
{
    char keys[3][MYC_KEY];
    if (scheme != NULL && scheme->material_roles && !cape)
    {
        int rows[3];
        double shares[3], unders[3];
        MycSchemeRoles(scheme, rows, shares, unders);
        for (int i = 0; i < 3; i++) myc_row_key(keys[i], scheme->lut, rows[i]);
        MycRoleOpts opts = {GEAR, 1, 1, 0};
        return MycSchemeRolePlan(plan, t, s, keys, &opts);
    }
    int split = s->cape_source && !cape && t->ngroups > 0 && s->ngroups > 0
        && (t->groups[0]->share >= CAPE_SPLIT || (materials && myc_metal_second(s)));
    if (split)
    {
        MycSchemeCapeKeys(s, keys);
        MycRoleOpts opts = {UNIFORM, 0, materials ? 1 : 0, 1};
        return MycSchemeRolePlan(plan, t, s, keys, &opts);
    }
    return myc_plan(plan, t, s, materials, cape);
}
