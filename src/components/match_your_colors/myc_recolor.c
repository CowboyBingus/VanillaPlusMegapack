/* Match Your Colors: recolor.lua's helpers, 1:1: an analysis's look and patterns for the matcher, a plan's new LUT data
 * (each planned row keeps its material, or takes its source row's finish, and takes the fitted colors; a cape's tint
 * rows fitted over their material rows) and new pattern textures (texel 0's color). Runs on the worker inside a job. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "myc_recolor.h"

/* ---- named specs -------------------------------------------------------------------------------------------------- */

MycSpec* myc_specs_get(const MycSpecs* list, uint64_t name)
{
    for (int i = 0; i < list->n; i++)
        if (list->items[i].name == name) return list->items[i].spec;
    return NULL;
}

int myc_specs_put(MycArena* arena, MycSpecs* list, uint64_t name, MycSpec* spec)
{
    for (int i = 0; i < list->n; i++)
        if (list->items[i].name == name)
        {
            myc_spec_drop(list->items[i].spec);
            list->items[i].spec = spec;
            return 1;
        }
    if (list->n >= list->capacity)
    {
        int capacity = list->capacity < 8 ? 8 : list->capacity * 2;
        MycNamedSpec* grown = myc_alloc(arena, sizeof(MycNamedSpec) * (size_t)capacity);
        if (grown == NULL) { myc_spec_drop(spec); return 0; }
        if (list->n > 0) memcpy(grown, list->items, sizeof(MycNamedSpec) * (size_t)list->n);
        list->items = grown;
        list->capacity = capacity;
    }
    list->items[list->n].name = name;
    list->items[list->n].spec = spec;
    list->n++;
    return 1;
}

void myc_specs_drop(MycSpecs* list)
{
    for (int i = 0; i < list->n; i++) myc_spec_drop(list->items[i].spec);
    list->n = 0;
}

/* ---- the matcher's view of an analysis ---------------------------------------------------------------------------- */

static int MycRecolorHasLut(const uint64_t* luts, int n, uint64_t lut)
{
    for (int i = 0; i < n; i++)
        if (luts[i] == lut) return 1;
    return 0;
}

static int MycRecolorCovers(const MycAppKit* kit, const MycAnalysis* a)
{
    if (kit == NULL) return 0;
    for (int i = 0; i < a->nrows; i++)
        if (!myc_app_kit_has_lut(kit, a->rows[i].lut)) return 0;
    return 1;
}

/* The analysis's measured kit (none when its geometry came from patches; a transmog's composed record, the one kit
 * measured with exactly its LUTs) and the id its hood rows are listed under. */
static const MycAppKit* MycRecolorMeasured(const MycAnalysis* a, uint32_t* id)
{
    *id = a->kit->id;
    if (a->geometry_patched) return NULL;
    const MycAppKit* kit = myc_app_kit(*id);
    if (MycRecolorCovers(kit, a) || a->nrows == 0) return kit;
    uint64_t luts[512];
    int n = 0;
    for (int i = 0; i < a->nrows && n < 512; i++)
        if (!MycRecolorHasLut(luts, n, a->rows[i].lut)) luts[n++] = a->rows[i].lut;
    const MycAppKit* found = myc_app_kit_for(luts, n);
    if (found != NULL) { kit = found; *id = found->id; }
    return kit;
}

int myc_analysis_look(const MycAnalysis* a, int seen, MycLook* look)
{
    memset(look, 0, sizeof *look);
    if (a->kit->type == MYC_WEAPON) return 0;
    look->seen = seen;
    if (a->kit->type == MYC_CAPE)
    {
        look->borrow = 1;
        look->has_tint = a->has_tint;
        look->tint_cape = a->tint_cape;
        look->tint_material = a->tint_material;
        return 1;
    }
    look->kit = MycRecolorMeasured(a, &look->hood_id);
    look->seen_share = 1;
    look->has_hoods = myc_app_has_hoods(look->hood_id);
    return 1;
}

int myc_patterns_of(const MycAnalysis* a, MycPatternIn* out)
{
    int n = 0;
    for (int i = 0; i < a->npatterns; i++)
    {
        const MycLut* texture = myc_analysis_lut(a, a->patterns[i].pattern);
        if (texture == NULL) continue;
        out[n].pattern = a->patterns[i].pattern;
        out[n].area = a->patterns[i].area;
        out[n].r = texture->values[0];
        out[n].g = texture->values[1];
        out[n].b = texture->values[2];
        out[n].emblem = 0;
        n++;
    }
    return n;
}

/* ---- finishes and copies ------------------------------------------------------------------------------------------ */

static const MycLut* MycRecolorSourceRow(const MycSourceLuts* source, const char* key, int tint, int* row)
{
    uint64_t lut;
    if (!myc_split_key(key, &lut, row)) return NULL;
    const MycAnalysis* a = source != NULL ? source->analysis : NULL;
    if (tint && a != NULL && a->has_tint && lut == a->tint_cape) lut = a->tint_material;
    const MycLut* spec = myc_source_lut(source, lut);
    return spec != NULL && *row >= 0 && *row < spec->height ? spec : NULL;
}

int myc_apply_finish(float* data, int width, int r, const MycSourceLuts* source, const char* key, MycErr* err)
{
    int row;
    const MycLut* spec = MycRecolorSourceRow(source, key, 1, &row);
    if (spec == NULL) return myc_fail(err, "finish source %s not in the source analysis", key);
    const float* v = spec->values + (size_t)row * (size_t)spec->width * 4;
    float* t = data + (size_t)r * (size_t)width * 4;
    int was_paint = t[27] < 0.5;
    t[27] = (float)myc_min(myc_max(v[27], 0), 1);
    t[28] = 0; t[29] = 0; t[30] = 0; t[31] = 0;
    t[32] = v[32]; t[33] = v[33]; t[34] = v[34]; t[35] = v[35];
    t[40] = v[40];
    if (was_paint && t[27] >= 0.5) t[40] = (float)myc_max(t[40], MYC_METAL_ON_PAINT_ROUGH);
    return 1;
}

int myc_apply_copy(float* data, int width, int r, const MycSourceLuts* source, const char* key, MycErr* err)
{
    static const int rgb[4] = {0, 2, 5, 6}, all[5] = {16, 17, 18, 19, 21};
    int row;
    const MycLut* spec = MycRecolorSourceRow(source, key, 0, &row);
    if (spec == NULL) return myc_fail(err, "copy source %s not in the source analysis", key);
    const float* v = spec->values + (size_t)row * (size_t)spec->width * 4;
    float* t = data + (size_t)r * (size_t)width * 4;
    for (int i = 0; i < 4; i++)
        for (int ch = 0; ch < 3; ch++) t[rgb[i] * 4 + ch] = v[rgb[i] * 4 + ch];
    for (int i = 0; i < 5; i++)
        for (int ch = 0; ch < 4; ch++) t[all[i] * 4 + ch] = v[all[i] * 4 + ch];
    t[83] = v[83];
    t[91] = v[91];
    return 1;
}

/* ---- LUTs --------------------------------------------------------------------------------------------------------- */

static void MycRecolorNoteFit(MycFits* fits, double err)
{
    if (fits == NULL || err != err || err == INFINITY) return;
    fits->rows++;
    if (err > fits->err) fits->err = err;
}

static MycSpec* MycRecolorCopy(const MycLut* original, int kind)
{
    size_t bytes = (size_t)original->width * (size_t)original->height * 16;
    MycSpec* spec = myc_spec_new(kind, original->width, original->height, bytes);
    if (spec != NULL) memcpy(spec->data, original->values, bytes);
    return spec;
}

/* A plan's goals of one LUT (row -> goal), from its "lut:row" keys. */
typedef struct MycLutRows { uint64_t lut; const MycGoal** goals; int* rows; int n; } MycLutRows;

static int MycRecolorRow(const MycLut* original, float* data, int r, const MycGoal* goal, MycTransfer* tr,
    const MycSourceLuts* source, MycFits* fits, MycErr* err)
{
    if (goal->finish[0] != 0 && !myc_apply_finish(data, original->width, r, source, goal->finish, err)) return 0;
    if (goal->copy[0] != 0) return myc_apply_copy(data, original->width, r, source, goal->copy, err);
    double e = myc_transfer_apply(tr, data, original->width, r, goal, source, goal->finish[0] == 0 ? original : NULL);
    MycRecolorNoteFit(fits, e);
    return 1;
}

/* One material LUT's new data (Recolor.build_lut); NULL after myc_fail. */
static MycSpec* MycRecolorBuildLut(const MycLut* original, const MycLutRows* rows, MycTransfer* tr,
    const MycSourceLuts* source, MycFits* fits, MycErr* err)
{
    MycSpec* spec = MycRecolorCopy(original, MYC_SPEC_LUT);
    if (spec == NULL) { myc_fail(err, "out of memory (LUT copy)"); return NULL; }
    for (int i = 0; i < rows->n; i++)
        if (rows->rows[i] < original->height
            && !MycRecolorRow(original, spec->data, rows->rows[i], rows->goals[i], tr, source, fits, err))
        {
            myc_spec_drop(spec);
            return NULL;
        }
    return spec;
}

/* A cape LUT's planned tint rows in a copy of it, each fitted over its material row as built (build_tints). */
static MycSpec* MycRecolorBuildTints(const MycLut* cape, const MycLutRows* rows, const MycLut* material,
    const MycSpec* built, MycTransfer* tr, MycFits* fits, MycErr* err)
{
    MycSpec* spec = MycRecolorCopy(cape, MYC_SPEC_CAPE);
    if (spec == NULL) { myc_fail(err, "out of memory (cape LUT copy)"); return NULL; }
    float* data = spec->data;
    const float* values = built != NULL ? built->data : material->values;
    for (int i = 0; i < rows->n; i++)
    {
        int r = rows->rows[i];
        if (r >= cape->height || r >= material->height) continue;
        size_t t = ((size_t)r * (size_t)cape->width + 3) * 4;
        double tint[3] = {cape->values[t], cape->values[t + 1], cape->values[t + 2]}, out[3];
        double e = myc_transfer_fit_base(tr, values, material->width, r, tint, rows->goals[i], out);
        data[t] = (float)out[0];
        data[t + 1] = (float)out[1];
        data[t + 2] = (float)out[2];
        MycRecolorNoteFit(fits, e);
    }
    return spec;
}

/* The plan's goals grouped by LUT; how many LUTs (-1 out of memory). */
static int MycRecolorGroup(MycArena* arena, const MycPlan* plan, MycLutRows** out)
{
    MycLutRows* by = myc_alloc(arena, sizeof(MycLutRows) * (size_t)(plan->count + 1));
    if (by == NULL) return -1;
    int n = 0;
    for (int i = 0; i < plan->count; i++)
    {
        const MycGoal* goal = &plan->goals[i];
        uint64_t lut;
        int row, k = 0;
        if (goal->removed || !myc_split_key(goal->key, &lut, &row)) continue;
        while (k < n && by[k].lut != lut) k++;
        if (k == n)
        {
            by[n].lut = lut;
            by[n].goals = myc_alloc(arena, sizeof(MycGoal*) * (size_t)plan->count);
            by[n].rows = myc_alloc(arena, sizeof(int) * (size_t)plan->count);
            if (by[n].goals == NULL || by[n].rows == NULL) return -1;
            n++;
        }
        by[k].goals[by[k].n] = goal;
        by[k].rows[by[k].n] = row;
        by[k].n++;
    }
    *out = by;
    return n;
}

int myc_build_luts(MycArena* arena, const MycAnalysis* target, const MycPlan* plan, MycTransfer* tr,
    const MycSourceLuts* source, MycFits* fits, MycSpecs* out, MycErr* err)
{
    MycLutRows* by = NULL;
    int n = MycRecolorGroup(arena, plan, &by);
    if (n < 0) return myc_fail(err, "out of memory (plan rows)");
    for (int i = 0; i < n; i++)
    {
        const MycLut* original = myc_analysis_lut(target, by[i].lut);
        int tint = target->has_tint && by[i].lut == target->tint_cape;
        if (tint || original == NULL) continue;
        MycSpec* spec = MycRecolorBuildLut(original, &by[i], tr, source, fits, err);
        if (spec == NULL || !myc_specs_put(arena, out, by[i].lut, spec)) return myc_fail(err, "out of memory (LUTs)");
    }
    for (int i = 0; i < n; i++)
    {
        if (!(target->has_tint && by[i].lut == target->tint_cape)) continue;
        const MycLut* cape = myc_analysis_lut(target, by[i].lut);
        const MycLut* material = myc_analysis_lut(target, target->tint_material);
        if (cape == NULL || material == NULL) return myc_fail(err, "cape tint LUT %016llx not analysed", (unsigned long long)by[i].lut);
        MycSpec* spec = MycRecolorBuildTints(cape, &by[i], material, myc_specs_get(out, target->tint_material), tr, fits, err);
        if (spec == NULL || !myc_specs_put(arena, out, by[i].lut, spec)) return myc_fail(err, "out of memory (cape LUT)");
    }
    return 1;
}

/* ---- patterns ----------------------------------------------------------------------------------------------------- */

void myc_pattern_texel(const MycGoal* goal, double out[3])
{
    if (!goal->has_gain) { myc_lab_to_srgb(goal->L, goal->a, goal->b, out); return; }
    double lin[3];
    myc_lab_to_linear(goal->L, goal->a, goal->b, lin);
    double g1 = myc_max(goal->gain[0], 1e-4), g2 = myc_max(goal->gain[1], 1e-4), g3 = myc_max(goal->gain[2], 1e-4);
    double t[3] = {myc_linear_to_srgb(lin[0] / g1), myc_linear_to_srgb(lin[1] / g2), myc_linear_to_srgb(lin[2] / g3)};
    MycLab tl = myc_srgb_to_lab(t[0], t[1], t[2]);
    if (sqrt(goal->a * goal->a + goal->b * goal->b) >= 5.0 && myc_hue_gap(tl.a, tl.b, goal->a, goal->b) <= 60.0)
    {
        memcpy(out, t, sizeof t);
        return;
    }
    double luma = myc_max(g1 * 0.2126 + g2 * 0.7152 + g3 * 0.0722, 1e-4);
    out[0] = myc_linear_to_srgb(lin[0] / luma);
    out[1] = myc_linear_to_srgb(lin[1] / luma);
    out[2] = myc_linear_to_srgb(lin[2] / luma);
}

int myc_build_patterns(MycArena* arena, const MycAnalysis* target, const MycPlan* plan, MycSpecs* out, MycErr* err)
{
    for (int i = 0; i < plan->count; i++)
    {
        const MycGoal* goal = &plan->goals[i];
        if (goal->removed) continue;
        uint64_t name = strtoull(goal->key, NULL, 16);
        const MycLut* original = myc_analysis_lut(target, name);
        if (original == NULL) return myc_fail(err, "pattern %s not in the target analysis", goal->key);
        MycSpec* spec = MycRecolorCopy(original, MYC_SPEC_LUT);
        if (spec == NULL) return myc_fail(err, "out of memory (pattern copy)");
        double texel[3];
        myc_pattern_texel(goal, texel);
        float* data = spec->data;
        data[0] = (float)texel[0];
        data[1] = (float)texel[1];
        data[2] = (float)texel[2];
        if (!myc_specs_put(arena, out, name, spec)) return myc_fail(err, "out of memory (patterns)");
    }
    return 1;
}
