/* Match Your Colors: a cape's emblem-sheet layers (capes.lua layer_of, layer_point, sheet_rect, emblems_of) and the
 * recolor of a BC3 sheet's blocks under an emblem (recolor_sheet), 1:1. A layer whose strength |column 6, 9, 12 or 15 y|
 * exceeds LAYER_ON draws the decal sheet over the cloth of its row's outside cells. Runs on the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_capes.h"

#define LAYER_ON 0.001
#define EMBLEM_MIN 0.5
#define RECT_SAMPLES 64
#define RECT_MARGIN 2

typedef struct MycLayer
{
    int row, layer, swap, mirror;
    double cx, cy, sx0, sy0, sx, sy, sn, cs, ox, oy, scale, strength;
} MycLayer;

/* Layer k (0-3) of cape LUT row r; 0 when it is off. */
static int MycEmblemLayerOf(const MycLut* tint, int r, int k, MycLayer* l)
{
    const float* v = tint->values + (size_t)r * (size_t)tint->width * 4;
    const float* c4 = v + (4 + 3 * k) * 4;
    const float* c5 = v + (5 + 3 * k) * 4;
    const float* c6 = v + (6 + 3 * k) * 4;
    double y6 = c6[1];
    if (fabs(y6) <= LAYER_ON) return 0;
    l->row = r;
    l->layer = k;
    l->cx = c4[0];
    l->cy = c4[1];
    l->sx0 = c4[2];
    l->sy0 = c4[3];
    l->sx = myc_max(l->sx0, 1e-4);
    l->sy = myc_max(l->sy0, 1e-4);
    l->sn = sin((double)c5[2]);
    l->cs = cos((double)c5[2]);
    l->ox = c5[0];
    l->oy = c5[1];
    l->swap = c5[3] < 0;
    l->scale = myc_max(fabs((double)c5[3]), 1e-4);
    l->mirror = y6 < 0;
    l->strength = fabs(y6);
    return 1;
}

/* The sheet UV layer l samples at cape uv2 (u, v), as the shader computes it; 0 outside. */
static int MycEmblemPoint(const MycLayer* l, double u, double v, double* su, double* sv)
{
    double lx = (u - (l->cx - 0.5 * l->sx0)) / l->sx, ly = (v - (l->cy - 0.5 * l->sy0)) / l->sy;
    double dx = l->sx0 * (lx - 0.5), dy = l->sy0 * (ly - 0.5);
    if (!(fabs((dx * l->cs + dy * l->sn) / l->sx) < 0.5 && fabs((-dx * l->sn + dy * l->cs) / l->sy) < 0.5)) return 0;
    double qx = l->sx0 * (2.0 * lx - 1.0), qy = l->sy0 * (2.0 * ly - 1.0);
    double p1 = qx * l->cs + qy * l->sn, p2 = -qx * l->sn + qy * l->cs;
    if (l->swap)
    {
        double t = p1;
        p1 = -p2;
        p2 = t;
    }
    p1 = p1 / l->scale;
    p2 = p2 / l->scale;
    if (l->mirror) p1 = -p1;
    double wx = l->ox + p1, wy = l->oy + p2;
    if (!(fabs(0.5 * wx) < 0.5 && fabs(0.5 * wy) < 0.5)) return 0;
    *su = 0.5 * wx + 0.5;
    *sv = 0.5 * wy + 0.5;
    return 1;
}

/* The mip-0 texels of a w x h sheet layer l samples (half-open, clamped, RECT_MARGIN around); 0 when none. */
static int MycEmblemRect(const MycLayer* l, uint32_t w, uint32_t h, int rect[4])
{
    double lo_u = INFINITY, hi_u = -INFINITY, lo_v = INFINITY, hi_v = -INFINITY;
    for (int j = 0; j < RECT_SAMPLES; j++)
    {
        double v = l->cy + l->sy0 * ((j + 0.5) / RECT_SAMPLES - 0.5);
        for (int i = 0; i < RECT_SAMPLES; i++)
        {
            double su, sv;
            if (!MycEmblemPoint(l, l->cx + l->sx0 * ((i + 0.5) / RECT_SAMPLES - 0.5), v, &su, &sv)) continue;
            lo_u = myc_min(lo_u, su);
            hi_u = myc_max(hi_u, su);
            lo_v = myc_min(lo_v, sv);
            hi_v = myc_max(hi_v, sv);
        }
    }
    if (lo_u == INFINITY) return 0;
    rect[0] = (int)myc_max(floor(lo_u * w) - RECT_MARGIN, 0);
    rect[1] = (int)myc_max(floor(lo_v * h) - RECT_MARGIN, 0);
    rect[2] = (int)myc_min(floor(hi_u * w) + 1 + RECT_MARGIN, w);
    rect[3] = (int)myc_min(floor(hi_v * h) + 1 + RECT_MARGIN, h);
    return 1;
}

/* The decal sheet's mip SHEET_MIP (or its last) and its full size; 0 when it is not in the searched archives or not a
 * format read here (after myc_fail for an error). */
typedef struct MycSheet { MycCapeMip mip; uint32_t width, height, format, mips; } MycSheet;

static int MycEmblemSheet(MycFind* find, uint64_t name, MycSheet* out, MycErr* err)
{
    MycPixels p;
    if (name == MYC_NO_NAME) return 0;
    int found = myc_tex_open(find, name, &p, err);
    if (found <= 0) return found;
    uint32_t m = p.info.mips - 1 < MYC_CAPE_SHEET_MIP ? p.info.mips - 1 : MYC_CAPE_SHEET_MIP;
    if (!myc_cape_read_mip(&p, m, &out->mip, err)) return -1;
    out->width = p.info.width;
    out->height = p.info.height;
    out->format = p.info.format;
    out->mips = p.info.mips;
    return 1;
}

typedef struct MycEmblemAcc { double tr, tg, tb, weight; int cells; uint32_t counts[MYC_ZONE_BINS]; } MycEmblemAcc;
typedef struct MycEmblemCtx { const MycSheet* sheet; const MycLut* tint; const uint8_t* grad; } MycEmblemCtx;

static void MycEmblemCell(const MycLayer* l, const MycEmblemCtx* ctx, MycEmblemAcc* acc, int x, int i, double v)
{
    double su, sv;
    if (!MycEmblemPoint(l, (x + 0.5) / MYC_CAPE_GRID, v, &su, &sv)) return;
    const MycCapeMip* s = &ctx->sheet->mip;
    double tx = myc_min(myc_max(floor(su * s->w), 0), s->w - 1.0), ty = myc_min(myc_max(floor(sv * s->h), 0), s->h - 1.0);
    uint8_t t[4];
    myc_cape_texel(s, (uint32_t)tx, (uint32_t)ty, t);
    double blend = l->strength * t[3] / 255.0;
    if (blend <= 0.0) return;
    acc->tr = acc->tr + blend * myc_srgb_to_linear(t[0] / 255.0);
    acc->tg = acc->tg + blend * myc_srgb_to_linear(t[1] / 255.0);
    acc->tb = acc->tb + blend * myc_srgb_to_linear(t[2] / 255.0);
    acc->weight = acc->weight + blend;
    if (blend < EMBLEM_MIN) return;
    acc->cells++;
    double steps = ctx->tint != NULL && ctx->grad != NULL ? myc_cape_tint_steps(ctx->tint, l->row, ctx->grad[i * 4]) : 0;
    double b = floor(steps / (MYC_CAPE_TINT_STEPS / MYC_ZONE_BINS));
    acc->counts[b < MYC_ZONE_BINS - 1 ? (int)b : MYC_ZONE_BINS - 1]++;
}

/* One layer over the grid: its emblem into e; 0 when it shows on no cell. */
static int MycEmblemOf(const MycLayer* l, const MycEmblemCtx* ctx, MycEmblem* e)
{
    MycEmblemAcc acc;
    memset(&acc, 0, sizeof acc);
    for (int y = 0; y < MYC_CAPE_GRID; y++)
    {
        double v = (y + 0.5) / MYC_CAPE_GRID;
        for (int x = 0; x < MYC_CAPE_GRID; x++)
        {
            int i = y * MYC_CAPE_GRID + x;
            if (myc_cape_row_at(i) == l->row) MycEmblemCell(l, ctx, &acc, x, i, v);
        }
    }
    if (acc.cells == 0) return 0;
    memset(e, 0, sizeof *e);
    MycLab lab = myc_linear_to_lab(acc.tr / acc.weight, acc.tg / acc.weight, acc.tb / acc.weight);
    e->row = l->row;
    e->layer = l->layer;
    e->L = lab.L;
    e->a = lab.a;
    e->b = lab.b;
    e->around_row = l->row;
    memcpy(e->counts, acc.counts, sizeof e->counts);
    e->cells = acc.cells;
    e->has_rect = MycEmblemRect(l, ctx->sheet->width, ctx->sheet->height, e->rect);
    return 1;
}

int myc_cape_emblems_of(MycFind* find, const MycPiece* piece, const MycLut* tint, const uint8_t* grad, int height,
    MycArena* arena, MycAnalysis* out, MycErr* err)
{
    MycLayer found[4 * 4], layer;
    int n = 0, on = 0;
    out->emblems = NULL;
    out->nemblems = 0;
    for (int r = 0; r < (tint->height < height ? tint->height : height); r++)
        for (int k = 0; k < 4; k++)
        {
            if (!MycEmblemLayerOf(tint, r, k, &layer)) continue;
            on++;
            if (r < 4) found[n++] = layer; /* a counted cell's outside row is 0-3: a later row's layer shows on none */
        }
    if (on == 0) return 1;
    MycSheet sheet;
    int have = MycEmblemSheet(find, piece->decal, &sheet, err);
    if (have < 0) return 0;
    if (have == 0) return 1;
    out->emblems = myc_alloc(arena, sizeof(MycEmblem) * (size_t)(n + 1));
    if (out->emblems == NULL) return myc_fail(err, "out of memory (emblems)");
    MycEmblemCtx ctx = {&sheet, tint, grad};
    for (int i = 0; i < n; i++)
    {
        MycEmblem* e = &out->emblems[out->nemblems];
        if (!MycEmblemOf(&found[i], &ctx, e)) continue;
        e->sheet = piece->decal;
        e->sheet_width = sheet.width;
        e->sheet_height = sheet.height;
        e->sheet_format = sheet.format;
        e->sheet_mips = sheet.mips;
        out->nemblems++;
    }
    return 1;
}

/* ---- the sheet's recolor ------------------------------------------------------------------------------------------ */

static int MycEmblemQ(double x, int top)
{
    double v = floor(x * top + 0.5);
    return (int)myc_min(myc_max(v, 0), top);
}

/* An endpoint (5-6-5) moved by shift (Lab), clipped to sRGB. */
static uint16_t MycEmblemEndpoint(int v, const double shift[3])
{
    int r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
    MycLab lab = myc_srgb_to_lab((r * 8 + (r >> 2)) / 255.0, (g * 4 + (g >> 4)) / 255.0, (b * 8 + (b >> 2)) / 255.0);
    double s[3];
    myc_lab_to_srgb(lab.L + shift[0], lab.a + shift[1], lab.b + shift[2], s);
    return (uint16_t)(MycEmblemQ(s[0], 31) * 2048 + MycEmblemQ(s[1], 63) * 32 + MycEmblemQ(s[2], 31));
}

static int32_t myc_emblem_memo[65536];  /* an endpoint's recolor, once per sheet cell (-1: not yet) */

static void MycEmblemBlocks(uint8_t* data, size_t offset, uint32_t bw, uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1,
    const double shift[3])
{
    for (uint32_t by = y0; by < y1; by++)
        for (uint32_t bx = x0; bx < x1; bx++)
        {
            size_t at = offset + ((size_t)by * bw + bx) * 16 + 8;
            for (int k = 0; k <= 2; k += 2)
            {
                int v = data[at + (size_t)k] + data[at + (size_t)k + 1] * 256;
                if (myc_emblem_memo[v] < 0) myc_emblem_memo[v] = MycEmblemEndpoint(v, shift);
                data[at + (size_t)k] = (uint8_t)(myc_emblem_memo[v] & 255);
                data[at + (size_t)k + 1] = (uint8_t)(myc_emblem_memo[v] >> 8);
            }
        }
}

void myc_cape_recolor_sheet(uint8_t* data, uint32_t width, uint32_t height, uint32_t mips, const int rect[4],
    const double shift[3])
{
    memset(myc_emblem_memo, 0xFF, sizeof myc_emblem_memo);
    size_t offset = 0;
    for (uint32_t m = 0; m < mips; m++)
    {
        uint32_t mw = width >> m > 0 ? width >> m : 1, mh = height >> m > 0 ? height >> m : 1;
        uint32_t bw = (mw + 3) >> 2 > 0 ? (mw + 3) >> 2 : 1, bh = (mh + 3) >> 2 > 0 ? (mh + 3) >> 2 : 1;
        uint32_t rx0 = (uint32_t)rect[0] >> m, ry0 = (uint32_t)rect[1] >> m;
        uint32_t rx1 = (uint32_t)rect[2] >> m, ry1 = (uint32_t)rect[3] >> m;
        uint32_t x1 = ((rx1 > rx0 + 1 ? rx1 : rx0 + 1) + 3) / 4, y1 = ((ry1 > ry0 + 1 ? ry1 : ry0 + 1) + 3) / 4;
        MycEmblemBlocks(data, offset, bw, rx0 / 4, ry0 / 4, x1 < bw ? x1 : bw, y1 < bh ? y1 : bh, shift);
        offset += (size_t)bw * bh * 16;
    }
}
