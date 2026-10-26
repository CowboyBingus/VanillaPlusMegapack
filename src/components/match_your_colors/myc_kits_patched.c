/* Match Your Colors: what an analysis read from mods' patches (kits.lua Kits.mark_patched), 1:1. A weighted piece
 * whose unit, material, ID mask or pattern mask came from a patch marks the analysis geometry_patched (its measured
 * screen pixels no longer hold); each row of a patched LUT that differs from the archived one gets finish_changed and
 * the archived row's model color and albedo (vanilla). Runs on the worker inside a job. */
#include <math.h>
#include "myc_kits.h"

static const uint8_t myc_color_columns[MYC_MAX_COLUMNS] = {1, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1};

static int MycPatchedHas(const MycNoted* touched, int count, uint64_t name, uint64_t type)
{
    for (int i = 0; i < count; i++)
        if (touched[i].name == name && touched[i].type == type) return 1;
    return 0;
}

static int MycPatchedPiece(const MycAPiece* entry, const MycNoted* touched, int count)
{
    if (MycPatchedHas(touched, count, entry->piece.path, MYC_TYPE_UNIT)) return 1;
    for (int i = 0; i < entry->nmaterials; i++)
    {
        const MycMaterial* m = &entry->materials[i];
        if (MycPatchedHas(touched, count, m->material, MYC_TYPE_MATERIAL)) return 1;
        if (m->has_mask && MycPatchedHas(touched, count, m->mask, MYC_TYPE_TEXTURE)) return 1;
        if (m->has_pattern_mask && MycPatchedHas(touched, count, m->pattern_mask, MYC_TYPE_TEXTURE)) return 1;
    }
    return 0;
}

/* How row r of lut differs from the archived original: 2 its finish (or it is new), 1 its colors only, 0 none. */
static int MycPatchedChange(const MycLut* lut, const MycLut* original, int r)
{
    if (original->width != lut->width || r >= original->height) return 2;
    int color = 0;
    for (int c = 0; c < lut->width; c++)
        for (int ch = 0; ch < 4; ch++)
        {
            size_t i = ((size_t)r * (size_t)lut->width + (size_t)c) * 4 + (size_t)ch;
            double x = lut->values[i], y = original->values[i];
            if (!(fabs(x - y) > 1e-3 * myc_max(1, fabs(y)))) continue;
            if (!(c < MYC_MAX_COLUMNS && myc_color_columns[c] && ch < 3)) return 2;
            color = 1;
        }
    return color;
}

static void MycPatchedRow(MycRow* row, const MycLut* lut, MycOriginalLut original, void* ctx, MycModel* model)
{
    const MycLut* base = original(ctx, row->lut);
    int change = base == NULL ? 2 : (lut != NULL ? MycPatchedChange(lut, base, row->row) : 2);
    if (change == 0) return;
    row->finish_changed = change == 2;
    if (base == NULL || row->row >= base->height) return;
    MycRowInfo info = myc_row_info(model, base->values, base->width, row->row);
    row->has_vanilla = 1;
    row->vanilla = (MycVanilla){info.L, info.a, info.b, info.ar, info.ag, info.ab};
}

void myc_kits_mark_patched(MycAnalysis* a, const MycNoted* touched, int count, MycOriginalLut original, void* ctx,
    MycModel* model)
{
    for (int i = 0; i < a->npieces; i++)
        if (a->pieces[i].weight > 0 && MycPatchedPiece(&a->pieces[i], touched, count)) a->geometry_patched = 1;
    for (int i = 0; i < a->nrows; i++)
    {
        MycRow* row = &a->rows[i];
        if (MycPatchedHas(touched, count, row->lut, MYC_TYPE_TEXTURE) && !row->albedo)
            MycPatchedRow(row, myc_analysis_lut(a, row->lut), original, ctx, model);
    }
}
