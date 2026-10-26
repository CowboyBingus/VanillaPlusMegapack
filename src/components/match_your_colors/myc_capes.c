/* Match Your Colors: a cape kit's analysis (capes.lua Capes.analyse: its material rows that show, its tint rows, design
 * zones and emblems), its report line, and a cape as the matcher's source (source_rows, dark_parts_guard,
 * emblem_patterns), 1:1. Runs on the worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "myc_capes.h"

#define DARK_PART_L 30.0
#define LIGHT_COLOR_L 60.0
#define LINING_OUTSIDE 0.10
#define LINING_PART_SHARE 0.10
#define LINING_TINT_C 5.0

static uint8_t myc_capes_cells_buffer[MYC_CAPE_CELLS * 4];
static uint8_t myc_capes_grad_buffer[MYC_CAPE_CELLS * 4];

/* Texture name sampled on the grid into out; 1, 0 not in the searched archives, -1 after myc_fail. */
static int MycCapesSample(MycFind* find, uint64_t name, uint8_t* out, MycErr* err)
{
    MycPixels p;
    if (name == MYC_NO_NAME) return 0;
    int found = myc_tex_open(find, name, &p, err);
    if (found <= 0) return found;
    return myc_cape_cells(&p, out, err) ? 1 : -1;
}

/* The cape LUT and the gradient's cells, and why no tint is modelled (note), as tint_inputs. */
static void MycCapesTintInputs(const MycPiece* piece, MycKitDeps* deps, MycLut** tint, const uint8_t** grad, char* note,
    size_t size)
{
    *tint = NULL;
    *grad = NULL;
    note[0] = 0;
    if (piece->cape_lut == MYC_NO_NAME) return;
    MycErr why = {0};
    *tint = myc_textures_lut(deps->textures, deps->find, piece->cape_lut, &why);
    if (why.failed) { *tint = NULL; snprintf(note, size, "cape LUT unreadable: %s", why.why); return; }
    if (*tint == NULL) { snprintf(note, size, "cape LUT %016llx not found", (unsigned long long)piece->cape_lut); return; }
    if (piece->gradient == MYC_NO_NAME) return;
    int got = MycCapesSample(deps->find, piece->gradient, myc_capes_grad_buffer, &why);
    if (got < 0) snprintf(note, size, "gradient unreadable: %s", why.why);
    else if (got == 0) snprintf(note, size, "gradient %016llx not found", (unsigned long long)piece->gradient);
    else *grad = myc_capes_grad_buffer;
}

static int MycCapesEmblemLayers(const MycLut* tint, const double areas[5], const double tints[5])
{
    int count = 0;
    for (int layer = 0; layer < 4; layer++)
    {
        int column = 6 + 3 * layer, found = 0;
        for (int r = 0; r < (tint->height < 4 ? tint->height : 4); r++)
        {
            float y = tint->values[((size_t)r * (size_t)tint->width + (size_t)column) * 4 + 1];
            if ((areas[r] > 0 || tints[r] > 0) && fabs((double)y) > 0.001) found = 1;
        }
        count += found;
    }
    return count;
}

/* One analysis row: row r of values (width columns) under key with area. */
static void MycCapesRowEntry(MycModel* model, MycRow* row, uint64_t lut_name, const float* values, int width, int r,
    double area, double emissive)
{
    MycRowInfo info = myc_row_info(model, values, width, r);
    memset(row, 0, sizeof *row);
    row->lut = lut_name;
    row->row = r;
    row->area = area;
    row->L = info.L;
    row->a = info.a;
    row->b = info.b;
    row->metal = info.metal;
    row->camo = info.camo;
    row->mode = info.mode;
    row->full = info.full;
    row->ar = info.ar;
    row->ag = info.ag;
    row->ab = info.ab;
    row->emissive = emissive;
    row->finish_changed = -1;
}

static void MycCapesMaterialRows(MycKitDeps* deps, const MycPiece* piece, const MycLut* lut, const double areas[5],
    MycAnalysis* a)
{
    for (int r = 0; r < lut->height && r < 5; r++)
    {
        if (!(areas[r] > 1e-6)) continue;
        MycRow* row = &a->rows[a->nrows++];
        MycCapesRowEntry(deps->model, row, piece->lut, lut->values, lut->width, r, areas[r], myc_kits_emissive(lut, r));
        myc_row_key(row->key, piece->lut, r);
    }
}

/* The tint rows (key "<cape LUT>:<row>"): material row r with column 0 its cape LUT row's column 3; whether any. */
static int MycCapesTintRows(MycKitDeps* deps, const MycPiece* piece, const MycLut* lut, const MycLut* tint,
    const double tints[5], MycAnalysis* a)
{
    float copy[MYC_MAX_COLUMNS * 4];
    int any = 0;
    for (int r = 0; r < lut->height && r < 5; r++)
    {
        if (!(tints[r] > 1e-6) || lut->width > MYC_MAX_COLUMNS) continue;
        memcpy(copy, lut->values + (size_t)r * (size_t)lut->width * 4, (size_t)lut->width * 16);
        size_t t = ((size_t)r * (size_t)tint->width + 3) * 4;
        copy[0] = tint->values[t];
        copy[1] = tint->values[t + 1];
        copy[2] = tint->values[t + 2];
        MycRow* row = &a->rows[a->nrows++];
        MycCapesRowEntry(deps->model, row, piece->cape_lut, copy, lut->width, 0, tints[r], myc_kits_emissive(lut, r));
        row->row = r;
        myc_row_key(row->key, piece->cape_lut, r);
        any = 1;
    }
    return any;
}

/* The analysis's one piece entry (the cape on slot 1, any body). */
static int MycCapesPiece(MycArena* arena, const MycPiece* piece, MycAnalysis* a)
{
    a->pieces = myc_alloc(arena, sizeof(MycAPiece));
    if (a->pieces == NULL) return 0;
    a->npieces = 1;
    MycAPiece* entry = &a->pieces[0];
    entry->piece.path = piece->path;
    entry->piece.slot = 1;
    entry->piece.type = 0;
    entry->piece.body = MYC_BODY_ANY;
    entry->piece.lut = piece->lut;
    entry->piece.tone = 0;
    entry->weight = 1.0;
    entry->materials = myc_alloc(arena, sizeof(MycMaterial));
    if (entry->materials == NULL) return 0;
    entry->nmaterials = 1;
    entry->materials[0].lut = piece->lut;
    return 1;
}

/* The fields on the grid (a plain cape without them); 0 after myc_fail. */
static int MycCapesFields(MycKitDeps* deps, const MycPiece* piece, MycErr* err)
{
    int got = MycCapesSample(deps->find, piece->fields, myc_capes_cells_buffer, err);
    if (got < 0) return 0;
    if (got == 0)
    {
        memset(myc_capes_cells_buffer, 0, sizeof myc_capes_cells_buffer);
        for (int i = 0; i < MYC_CAPE_CELLS; i++) myc_capes_cells_buffer[i * 4 + 3] = 255;
    }
    return 1;
}

/* What follows the rows: tint, zones, emblems and their counts (Capes.analyse's second half). */
static int MycCapesParts(MycKitDeps* deps, const MycPiece* piece, MycLut* lut, MycLut* tint, const uint8_t* grad,
    const double areas[5], const double tints[5], MycAnalysis* a, MycErr* err)
{
    if (!myc_analysis_add_lut(deps->arena, a, piece->lut, lut)) return myc_fail(err, "out of memory (cape LUTs)");
    if (tint != NULL && grad != NULL && MycCapesTintRows(deps, piece, lut, tint, tints, a))
    {
        if (!myc_analysis_add_lut(deps->arena, a, piece->cape_lut, tint)) return myc_fail(err, "out of memory (cape LUTs)");
        a->has_tint = 1;
        a->tint_cape = piece->cape_lut;
        a->tint_material = piece->lut;
    }
    MycZones zones;
    if (myc_cape_zones_of(myc_capes_cells_buffer, lut->height, tint, grad, &zones))
    {
        a->zones = myc_alloc(deps->arena, sizeof(MycZones));
        if (a->zones == NULL) return myc_fail(err, "out of memory (cape zones)");
        *a->zones = zones;
    }
    if (tint == NULL) return 1;
    if (!myc_cape_emblems_of(deps->find, piece, tint, grad, lut->height, deps->arena, a, err)) return 0;
    a->emblem_layers = MycCapesEmblemLayers(tint, areas, tints);
    return 1;
}

MycAnalysis* myc_capes_analyse(MycKit* kit, int body, MycKitDeps* deps, char* why, size_t why_size, MycErr* err)
{
    const MycPiece* piece = kit->npieces > 0 ? &kit->pieces[0] : NULL;
    if (piece == NULL || piece->lut == MYC_NO_NAME) { snprintf(why, why_size, "cape without a material LUT"); return NULL; }
    MycLut* lut = myc_textures_lut(deps->textures, deps->find, piece->lut, err);
    if (err->failed) return NULL;
    if (lut == NULL) { snprintf(why, why_size, "cape LUT %016llx not found", (unsigned long long)piece->lut); return NULL; }
    if (!MycCapesFields(deps, piece, err)) return NULL;
    MycLut* tint;
    const uint8_t* grad;
    MycAnalysis* a = myc_alloc(deps->arena, sizeof(MycAnalysis));
    if (a == NULL) { myc_fail(err, "out of memory (cape analysis)"); return NULL; }
    MycCapesTintInputs(piece, deps, &tint, &grad, a->tint_note, sizeof a->tint_note);
    double areas[5], tints[5], total;
    myc_cape_areas(myc_capes_cells_buffer, lut->height, tint, grad, areas, tints, &total);
    a->kit = kit;
    a->body = body;
    a->weight = total;
    a->rows = myc_alloc(deps->arena, sizeof(MycRow) * 10);
    if (a->rows == NULL || !MycCapesPiece(deps->arena, piece, a)) { myc_fail(err, "out of memory (cape rows)"); return NULL; }
    MycCapesMaterialRows(deps, piece, lut, areas, a);
    return MycCapesParts(deps, piece, lut, tint, grad, areas, tints, a, err) ? a : NULL;
}

void myc_capes_report(const MycAnalysis* c, const MycZoneOutcome* zones, const MycZoneOutcome* emblems,
    const char* sheet_note, int fits_rows, double fits_err, char* out, size_t size)
{
    double tint = 0;
    for (int i = 0; i < c->nrows; i++)
        if (c->has_tint && c->rows[i].lut == c->tint_cape) tint = tint + c->rows[i].area;
    MycZoneOutcome none = {0, 0, 0};
    const MycZoneOutcome* z = zones != NULL ? zones : &none;
    const MycZoneOutcome* e = emblems != NULL ? emblems : &none;
    char note[200] = "", sheet[200] = "";
    if (c->tint_note[0] != 0) snprintf(note, sizeof note, " (no tint modelled: %s)", c->tint_note);
    if (sheet_note != NULL && sheet_note[0] != 0) snprintf(sheet, sizeof sheet, " (sheet not recolored: %s)", sheet_note);
    snprintf(out, size, "Cape %08x: tint %.0f%% of it%s; design zones: %d recolored to stay readable, %d kept their "
        "colors, %d unreadable; emblems: %d recolored to stay readable%s, %d unreadable, %d in their own colors; %d "
        "rows fitted (largest error dE %.1f).", c->kit->id, tint * 100, note, z->picked, z->kept, z->lost, e->picked,
        sheet, e->lost, c->nemblems - e->picked - e->lost, fits_rows, fits_err);
}

/* ---- a cape as the source ----------------------------------------------------------------------------------------- */

static int MycCapesIsTint(const MycAnalysis* cape, const MycRow* row) { return cape->has_tint && row->lut == cape->tint_cape; }

/* A material row and its tint row blended into one (in linear light by their areas). */
static MycRow MycCapesBlend(const MycRow* row, const MycRow* tint)
{
    double w = row->area + tint->area;
    double p = row->area / w, q = tint->area / w, x[3], y[3];
    MycRow out = *row;
    out.area = w;
    out.under = 0;
    out.ar = p * row->ar + q * tint->ar;
    out.ag = p * row->ag + q * tint->ag;
    out.ab = p * row->ab + q * tint->ab;
    myc_lab_to_linear(row->L, row->a, row->b, x);
    myc_lab_to_linear(tint->L, tint->a, tint->b, y);
    MycLab lab = myc_linear_to_lab(myc_max(p * x[0] + q * y[0], 0), myc_max(p * x[1] + q * y[1], 0),
        myc_max(p * x[2] + q * y[2], 0));
    out.L = lab.L;
    out.a = lab.a;
    out.b = lab.b;
    return out;
}

static void MycCapesOutside(MycRow* row)
{
    row->outside = row->row == MYC_CAPE_INSIDE_ROW ? 0 : row->area;
    row->has_outside = 1;
    row->cape = 1;
}

int myc_capes_source_rows(const MycAnalysis* cape, MycRow* out)
{
    const MycRow* tints[5] = {NULL, NULL, NULL, NULL, NULL};
    int n = 0;
    for (int i = 0; i < cape->nrows; i++)
        if (MycCapesIsTint(cape, &cape->rows[i]) && cape->rows[i].row >= 0 && cape->rows[i].row < 5) tints[cape->rows[i].row] = &cape->rows[i];
    for (int i = 0; i < cape->nrows; i++)
    {
        const MycRow* row = &cape->rows[i];
        if (MycCapesIsTint(cape, row)) continue;
        const MycRow* tint = row->row >= 0 && row->row < 5 ? tints[row->row] : NULL;
        out[n] = tint != NULL ? MycCapesBlend(row, tint) : *row;
        MycCapesOutside(&out[n++]);
        if (row->row >= 0 && row->row < 5) tints[row->row] = NULL;
    }
    for (int i = 0; i < cape->nrows; i++)
    {
        const MycRow* row = &cape->rows[i];
        if (row->row < 0 || row->row >= 5 || tints[row->row] != row) continue;
        out[n] = *row;
        MycCapesOutside(&out[n++]);
    }
    return n;
}

static double MycCapesOutsideShare(const MycGroup* g)
{
    double area = 0, outside = 0;
    for (int i = 0; i < g->nrows; i++)
    {
        area = area + g->rows[i]->area;
        outside = outside + (g->rows[i]->has_outside ? g->rows[i]->outside : 0);
    }
    return area > 0 ? outside / area : 1;
}

static void MycCapesGuardDark(MycSearch* c, int i, int darkest)
{
    int any = 0;
    for (int j = 0; j < c->m; j++)
    {
        if (c->s[j]->L >= LIGHT_COLOR_L && !MYC_KEEP(c, i, j)) MYC_ALLOWED(c, i, j) = 0;
        any = any || MYC_ALLOWED(c, i, j);
    }
    if (!any) MYC_ALLOWED(c, i, darkest) = 1;
}

static void MycCapesGuardLining(MycSearch* c, int i, const int* lining, int most)
{
    int any = 0;
    for (int j = 0; j < c->m; j++)
    {
        if (lining[j] && !MYC_KEEP(c, i, j)) MYC_ALLOWED(c, i, j) = 0;
        any = any || MYC_ALLOWED(c, i, j);
    }
    if (!any) MYC_ALLOWED(c, i, most) = 1;
}

void myc_capes_dark_parts_guard(MycSearch* c, double accent_c)
{
    int darkest = 0, most = 0, lining[64];
    double best = -1;
    for (int j = 1; j < c->m; j++)
        if (c->s[j]->L < c->s[darkest]->L) darkest = j;
    for (int j = 0; j < c->m && j < 64; j++)
    {
        double o = MycCapesOutsideShare(c->s[j]);
        lining[j] = o < LINING_OUTSIDE && sqrt(c->s[j]->ma * c->s[j]->ma + c->s[j]->mb * c->s[j]->mb) >= LINING_TINT_C;
        if (o * c->s[j]->share > best) { most = j; best = o * c->s[j]->share; }
    }
    for (int i = 0; i < c->n; i++)
    {
        const MycGroup* g = c->t[i];
        if (g->mL < DARK_PART_L && sqrt(g->ma * g->ma + g->mb * g->mb) < accent_c) MycCapesGuardDark(c, i, darkest);
        if (g->share >= LINING_PART_SHARE) MycCapesGuardLining(c, i, lining, most);
    }
}

int myc_capes_emblem_patterns(const MycAnalysis* cape, MycPatternIn* out)
{
    int n = 0;
    if (!(cape->weight > 0)) return 0;
    for (int i = 0; i < cape->nemblems; i++)
    {
        const MycEmblem* e = &cape->emblems[i];
        double rgb[3];
        myc_lab_to_srgb(e->L, e->a, e->b, rgb);
        memset(&out[n], 0, sizeof out[n]);
        out[n].emblem = 1;
        out[n].erow = e->row;
        out[n].elayer = e->layer;
        out[n].area = (double)e->cells * MYC_CAPE_W_OUT * MYC_CAPE_TINT_STEPS / cape->weight;
        out[n].r = rgb[0];
        out[n].g = rgb[1];
        out[n].b = rgb[2];
        n++;
    }
    return n;
}

void myc_capes_sheet_sums(const char* key, const uint8_t* data, size_t size, uint32_t* key_sum, uint32_t* data_sum)
{
    *key_sum = myc_adler(key);
    uint32_t a = 1, b = 0;
    size_t blocks = size / 16;
    for (int k = 0; k < 64 && blocks > 0; k++)
    {
        size_t at = (size_t)((double)k * (double)(blocks - 1) / 63) * 16;
        for (size_t i = at; i < at + 16; i++)
        {
            a = (a + data[i]) % 65521;
            b = (b + a) % 65521;
        }
    }
    *data_sum = b * 65536 + a;
}
