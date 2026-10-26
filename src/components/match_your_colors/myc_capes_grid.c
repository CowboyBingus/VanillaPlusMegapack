/* Match Your Colors: a cape's grid (capes.lua): its outline, the BC3 and BC4 blocks (Pillow's integer arithmetic), the
 * fields and gradient sampled on a GRID x GRID grid, the rows' areas and tints, and the design zones' borders, 1:1.
 * Runs on the worker inside a job. */
#include <math.h>
#include <string.h>
#include "myc_capes.h"

#define ZONE_BINS MYC_ZONE_BINS

/* The outline: GRID rows of GRID bits, most significant bit first (research/capes.py write-lua). */
static const char* const myc_cape_outline_rows[MYC_CAPE_GRID] = {
    "00000000000000000000000000000000", "00000000000000000000000000000000", "00000000000000000000000000000000",
    "00000000000000000000000000000000", "00000000000000000000000000000000", "00000000000000000000000000000000",
    "00000000000000000000000000000000", "00000000000020000004000000000000", "000000000001f000001f800000000000",
    "000000000001fc00003f800000000000", "000000000001fe00007f800000000000", "000000000001ff0000ff800000000000",
    "000000000003ffc003ffc00000000000", "000000000003ffe007ffc00000000000", "000000000003fff00fffc00000000000",
    "000000000003fffc3fffc00000000000", "000000000003ffffffffc00000000000", "000000000003ffffffffc00000000000",
    "000000000003ffffffffc00000000000", "000000000003ffffffffc00000000000", "000000000003ffffffffc00000000000",
    "000000000003ffffffffc00000000000", "000000000003ffffffffc00000000000", "000000000003ffffffffc00000000000",
    "000000000003ffffffffc00000000000", "000000000003ffffffffc00000000000", "000000000007ffffffffe00000000000",
    "000000000007ffffffffe00000000000", "000000000007ffffffffe00000000000", "00000000000ffffffffff00000000000",
    "00000000000ffffffffff00000000000", "00000000001ffffffffff80000000000", "00000000001ffffffffff80000000000",
    "00000000003ffffffffffc0000000000", "00000000007ffffffffffc0000000000", "00000000007ffffffffffe0000000000",
    "0000000000fffffffffffe0000000000", "0000000000ffffffffffff0000000000", "0000000001ffffffffffff8000000000",
    "0000000001ffffffffffff8000000000", "0000000003ffffffffffffc000000000", "0000000003ffffffffffffc000000000",
    "0000000007ffffffffffffe000000000", "0000000007ffffffffffffe000000000", "000000000ffffffffffffff000000000",
    "000000000ffffffffffffff000000000", "000000001ffffffffffffff800000000", "000000001ffffffffffffff800000000",
    "000000003ffffffffffffffc00000000", "000000003ffffffffffffffc00000000", "000000007ffffffffffffffe00000000",
    "000000007ffffffffffffffe00000000", "00000000ffffffffffffffff00000000", "00000000ffffffffffffffff00000000",
    "00000001ffffffffffffffff80000000", "00000001ffffffffffffffff80000000", "00000003ffffffffffffffffc0000000",
    "00000003ffffffffffffffffc0000000", "00000007ffffffffffffffffe0000000", "00000007ffffffffffffffffe0000000",
    "0000000ffffffffffffffffff0000000", "0000001ffffffffffffffffff8000000", "0000001ffffffffffffffffff8000000",
    "0000003ffffffffffffffffffc000000", "0000003ffffffffffffffffffc000000", "0000007ffffffffffffffffffe000000",
    "0000007ffffffffffffffffffe000000", "000000ffffffffffffffffffff000000", "000001ffffffffffffffffffff800000",
    "000001ffffffffffffffffffff800000", "000003ffffffffffffffffffffc00000", "000003ffffffffffffffffffffc00000",
    "000007ffffffffffffffffffffe00000", "000007ffffffffffffffffffffe00000", "00000ffffffffffffffffffffff00000",
    "00001ffffffffffffffffffffff80000", "00001ffffffffffffffffffffff80000", "00003ffffffffffffffffffffffc0000",
    "00003ffffffffffffffffffffffc0000", "00007ffffffffffffffffffffffe0000", "0000ffffffffffffffffffffffff0000",
    "0000ffffffffffffffffffffffff0000", "0001ffffffffffffffffffffffff8000", "0001ffffffffffffffffffffffff8000",
    "0003ffffffffffffffffffffffffc000", "0007ffffffffffffffffffffffffe000", "0007ffffffffffffffffffffffffe000",
    "000ffffffffffffffffffffffffff000", "000ffffffffffffffffffffffffff000", "001ffffffffffffffffffffffffff800",
    "003ffffffffffffffffffffffffffc00", "003ffffffffffffffffffffffffffc00", "007ffffffffffffffffffffffffffe00",
    "007ffffffffffffffffffffffffffe00", "00ffffffffffffffffffffffffffff00", "01ffffffffffffffffffffffffffff80",
    "01ffffffffffffffffffffffffffff80", "03ffffffffffffffffffffffffffffc0", "03ffffffffffffffffffffffffffffc0",
    "07ffffffffffffffffffffffffffffe0", "07ffffffffffffffffffffffffffffe0", "0ffffffffffffffffffffffffffffff0",
    "1ffffffffffffffffffffffffffffff8", "1ffffffffffffffffffffffffffffff8", "3ffffffffffffffffffffffffffffffc",
    "3ffffffffffffffffffffffffffffffc", "1ffffffffffffffffffffffffffffff8", "1ffffffffffffffffffffffffffffff8",
    "3ffffffffffffffffffffffffffffffc", "3ffffffffffffffffffffffffffffffc", "0ffffffffffffffffffffffffffffff0",
    "03ffffffffffffffffffffffffffffc0", "007ffffffffffffffffffffffffffe00", "001ffffffffffffffffffffffffff800",
    "0003ffffffffffffffffffffffffc000", "0000ffffffffffffffffffffffff0000", "00001ffffffffffffffffffffff80000",
    "000007ffffffffffffffffffffe00000", "000000ffffffffffffffffffff000000", "0000001ffffffffffffffffff8000000",
    "00000003ffffffffffffffffc0000000", "000000003ffffffffffffffc00000000", "0000000000ffffffffffff0000000000",
    "000000000007ffffffffe00000000000", "00000000000003ffffc0000000000000", "00000000000000000000000000000000",
    "00000000000000000000000000000000", "00000000000000000000000000000000",
};

static uint8_t myc_cape_shape[MYC_CAPE_CELLS];
static int myc_cape_shape_made;
static int8_t myc_cape_rows[MYC_CAPE_CELLS];  /* the outside row of each counted cell, -1 for the others */

const uint8_t* myc_cape_outline(void)
{
    if (myc_cape_shape_made) return myc_cape_shape;
    for (int y = 0; y < MYC_CAPE_GRID; y++)
        for (int d = 0; d < 32; d++)
        {
            char c = myc_cape_outline_rows[y][d];
            int nibble = c >= 'a' ? c - 'a' + 10 : c - '0';
            for (int k = 0; k < 4; k++) myc_cape_shape[y * MYC_CAPE_GRID + d * 4 + k] = (uint8_t)((nibble >> (3 - k)) & 1);
        }
    myc_cape_shape_made = 1;
    return myc_cape_shape;
}

/* ---- blocks ------------------------------------------------------------------------------------------------------- */

static void MycCapeExpand565(int c, int* r, int* g, int* b)
{
    int r5 = (c & 0xF800) >> 8, g6 = (c & 0x07E0) >> 3, b5 = (c & 0x001F) * 8;
    *r = r5 | (r5 >> 5);
    *g = g6 | (g6 >> 6);
    *b = b5 | (b5 >> 5);
}

static void MycCapeAlphaPalette(int a0, int a1, int a[8])
{
    a[0] = a0;
    a[1] = a1;
    if (a0 > a1)
    {
        for (int k = 1; k <= 6; k++) a[k + 1] = ((7 - k) * a0 + k * a1) / 7;
        return;
    }
    for (int k = 1; k <= 4; k++) a[k + 1] = ((5 - k) * a0 + k * a1) / 5;
    a[6] = 0;
    a[7] = 255;
}

static int MycCapeAlphaIndex(const uint8_t* block, int n)
{
    uint32_t lut1 = block[2] + block[3] * 256u + block[4] * 65536u, lut2 = block[5] + block[6] * 256u + block[7] * 65536u;
    return n < 8 ? (int)((lut1 >> (3 * n)) & 7) : (int)((lut2 >> (3 * (n - 8))) & 7);
}

void myc_cape_bc4_block(const uint8_t* block, uint8_t out[64])
{
    int a[8];
    MycCapeAlphaPalette(block[0], block[1], a);
    for (int n = 0; n < 16; n++)
    {
        out[n * 4] = (uint8_t)a[MycCapeAlphaIndex(block, n)];
        out[n * 4 + 1] = 0;
        out[n * 4 + 2] = 0;
        out[n * 4 + 3] = 255;
    }
}

void myc_cape_bc3_block(const uint8_t* block, uint8_t out[64])
{
    int a[8], p[4][3];
    MycCapeAlphaPalette(block[0], block[1], a);
    MycCapeExpand565(block[8] + block[9] * 256, &p[0][0], &p[0][1], &p[0][2]);
    MycCapeExpand565(block[10] + block[11] * 256, &p[1][0], &p[1][1], &p[1][2]);
    for (int c = 0; c < 3; c++)
    {
        p[2][c] = (2 * p[0][c] + p[1][c]) / 3;
        p[3][c] = (p[0][c] + 2 * p[1][c]) / 3;
    }
    uint32_t indices = block[12] + block[13] * 256u + block[14] * 65536u + block[15] * 16777216u;
    for (int n = 0; n < 16; n++)
    {
        const int* c = p[(indices >> (2 * n)) & 3];
        out[n * 4] = (uint8_t)c[0];
        out[n * 4 + 1] = (uint8_t)c[1];
        out[n * 4 + 2] = (uint8_t)c[2];
        out[n * 4 + 3] = (uint8_t)a[MycCapeAlphaIndex(block, n)];
    }
}

/* ---- sampling ----------------------------------------------------------------------------------------------------- */

static uint32_t MycCapeChooseMip(const MycTexInfo* info)
{
    uint32_t m = 0;
    while (m + 1 < info->mips && (info->width >> (m + 1)) >= MYC_CAPE_GRID && (info->height >> (m + 1)) >= MYC_CAPE_GRID) m++;
    return m;
}

static int MycCapeCellOf(uint32_t format)
{
    switch (format)
    {
    case MYC_FMT_RGBA8: case MYC_FMT_RGBA8_SRGB: return MYC_CELL_RGBA8;
    case MYC_FMT_RGBA16F: return MYC_CELL_RGBA16F;
    case MYC_FMT_RGBA32F: return MYC_CELL_RGBA32F;
    case MYC_FMT_BC7: return MYC_CELL_BC7;
    case MYC_FMT_BC3: return MYC_CELL_BC3;
    case MYC_FMT_BC4: return MYC_CELL_BC4;
    default: return -1;
    }
}

int myc_cape_read_mip(MycPixels* p, uint32_t m, MycCapeMip* out, MycErr* err)
{
    const MycTexInfo* info = &p->info;
    int cell = MycCapeCellOf(info->format);
    if (cell < 0) return myc_fail(err, "cape texture format %u", info->format);
    uint64_t size = info->mip_offsets[m + 1] - info->mip_offsets[m];
    uint8_t* raw = myc_scratch(MYC_SCRATCH_BIG, (size_t)size);
    if (raw == NULL) return myc_fail(err, "out of memory (cape mip)");
    if (!myc_pixels_read(p, info->mip_offsets[m], (uint32_t)size, raw, err)) return 0;
    out->raw = raw;
    out->cell = cell;
    out->w = info->width >> m > 0 ? info->width >> m : 1;
    out->h = info->height >> m > 0 ? info->height >> m : 1;
    out->wide = cell >= MYC_CELL_BC7 ? ((out->w + 3) >> 2 > 0 ? (out->w + 3) >> 2 : 1) : out->w;
    return 1;
}

static uint8_t MycCapeByte(double v)
{
    if (v != v || v < 0) v = 0;
    else if (v > 1) v = 1;
    return (uint8_t)floor(v * 255 + 0.5);
}

static void MycCapeDecode(const MycCapeMip* mip, uint32_t bx, uint32_t by, uint8_t out[64])
{
    size_t bytes = mip->cell == MYC_CELL_BC4 ? 8 : 16;
    const uint8_t* block = mip->raw + ((size_t)by * mip->wide + bx) * bytes;
    if (mip->cell == MYC_CELL_BC7) myc_bc7_block(block, out);
    else if (mip->cell == MYC_CELL_BC3) myc_cape_bc3_block(block, out);
    else myc_cape_bc4_block(block, out);
}

void myc_cape_texel(const MycCapeMip* mip, uint32_t x, uint32_t y, uint8_t out[4])
{
    if (mip->cell >= MYC_CELL_BC7)
    {
        uint8_t block[64];
        MycCapeDecode(mip, x >> 2, y >> 2, block);
        memcpy(out, block + ((y & 3) * 4 + (x & 3)) * 4, 4);
        return;
    }
    size_t i = (size_t)y * mip->wide + x;
    for (int c = 0; c < 4; c++)
    {
        if (mip->cell == MYC_CELL_RGBA8) out[c] = mip->raw[i * 4 + (size_t)c];
        else if (mip->cell == MYC_CELL_RGBA16F) out[c] = MycCapeByte(myc_half(mip->raw[i * 8 + (size_t)c * 2], mip->raw[i * 8 + (size_t)c * 2 + 1]));
        else out[c] = MycCapeByte(myc_single(mip->raw + i * 16 + (size_t)c * 4));
    }
}

/* The block row held per block column (block_cell's cache): each block decoded once. */
#define HELD_COLUMNS 4096
static int32_t myc_cape_held[HELD_COLUMNS];
static uint8_t myc_cape_decoded[HELD_COLUMNS * 64];

static void MycCapeBlockCell(const MycCapeMip* mip, uint32_t x, uint32_t y, uint8_t* out)
{
    uint32_t bx = x >> 2, by = y >> 2;
    if (bx >= HELD_COLUMNS) { myc_cape_texel(mip, x, y, out); return; }
    if (myc_cape_held[bx] != (int32_t)by)
    {
        MycCapeDecode(mip, bx, by, myc_cape_decoded + (size_t)bx * 64);
        myc_cape_held[bx] = (int32_t)by;
    }
    memcpy(out, myc_cape_decoded + (size_t)bx * 64 + ((y & 3) * 4 + (x & 3)) * 4, 4);
}

int myc_cape_cells(MycPixels* p, uint8_t* out, MycErr* err)
{
    MycCapeMip mip;
    if (!myc_cape_read_mip(p, MycCapeChooseMip(&p->info), &mip, err)) return 0;
    uint32_t xs[MYC_CAPE_GRID], ys[MYC_CAPE_GRID];
    for (uint32_t k = 0; k < MYC_CAPE_GRID; k++)
    {
        xs[k] = (uint32_t)(((2 * k + 1) * (uint64_t)mip.w) / (2 * MYC_CAPE_GRID));
        ys[k] = (uint32_t)(((2 * k + 1) * (uint64_t)mip.h) / (2 * MYC_CAPE_GRID));
    }
    for (uint32_t k = 0; k < mip.wide && k < HELD_COLUMNS; k++) myc_cape_held[k] = -1;
    const uint8_t* shape = myc_cape_outline();
    memset(out, 0, MYC_CAPE_CELLS * 4);
    for (int gy = 0; gy < MYC_CAPE_GRID; gy++)
        for (int gx = 0; gx < MYC_CAPE_GRID; gx++)
        {
            int i = gy * MYC_CAPE_GRID + gx;
            if (shape[i] != 1) continue;
            if (mip.cell >= MYC_CELL_BC7) MycCapeBlockCell(&mip, xs[gx], ys[gy], out + i * 4);
            else myc_cape_texel(&mip, xs[gx], ys[gy], out + i * 4);
        }
    return 1;
}

/* ---- areas -------------------------------------------------------------------------------------------------------- */

double myc_cape_tint_steps(const MycLut* tint, int row, double g)
{
    if (tint == NULL || row >= tint->height) return 0;
    const float* v = tint->values + (size_t)row * (size_t)tint->width * 4;
    double w = v[15], gp = g / 255;
    if (w < 0) gp = 1 - gp;
    double x = v[27] * (gp - v[26]);
    if (x < 0) x = 0;
    else if (x > 1) x = 1;
    double t = fabs(w) * x;
    if (t > 1) t = 1;
    return floor(t * MYC_CAPE_TINT_STEPS + 0.5);
}

/* A cell's outside row (the first of R, G, B set: 1-3, else 0). */
static int MycCapeOutsideRow(const uint8_t* cell)
{
    if (cell[0] >= MYC_CAPE_SET) return 1;
    if (cell[1] >= MYC_CAPE_SET) return 2;
    return cell[2] >= MYC_CAPE_SET ? 3 : 0;
}

typedef struct MycCapeAcc { int height; const MycLut* tint; double base[5], tinted[5], total; } MycCapeAcc;

static void MycCapeAddSide(MycCapeAcc* acc, int row, double weight, double level)
{
    if (row >= acc->height) return;
    double steps = myc_cape_tint_steps(acc->tint, row, level);
    acc->base[row] = acc->base[row] + weight * (MYC_CAPE_TINT_STEPS - steps);
    acc->tinted[row] = acc->tinted[row] + weight * steps;
    acc->total = acc->total + weight * MYC_CAPE_TINT_STEPS;
}

/* Every counted cell of the outline: its outside and inside sides (Capes.areas' loop). */
static void MycCapeAddCells(MycCapeAcc* acc, const uint8_t* cells, const uint8_t* grad)
{
    const uint8_t* shape = myc_cape_outline();
    for (int i = 0; i < MYC_CAPE_CELLS; i++)
    {
        const uint8_t* c = cells + i * 4;
        if (shape[i] != 1 || c[3] < MYC_CAPE_THRESHOLD) continue;
        double level = grad != NULL ? grad[i * 4] : 0;
        MycCapeAddSide(acc, MycCapeOutsideRow(c), MYC_CAPE_W_OUT, level);
        MycCapeAddSide(acc, c[0] >= MYC_CAPE_SET ? 1 : 4, MYC_CAPE_W_IN, level);
    }
}

void myc_cape_areas(const uint8_t* cells, int height, const MycLut* tint, const uint8_t* grad, double rows[5],
    double tints[5], double* total)
{
    MycCapeAcc acc;
    memset(&acc, 0, sizeof acc);
    acc.height = height;
    acc.tint = grad != NULL ? tint : NULL;
    MycCapeAddCells(&acc, cells, tint != NULL ? grad : NULL);
    for (int r = 0; r < 5; r++) { rows[r] = 0; tints[r] = 0; }
    *total = acc.total;
    if (acc.total == 0) return;
    for (int r = 0; r < (height < 5 ? height : 5); r++)
    {
        if (acc.base[r] > 0) rows[r] = acc.base[r] / acc.total;
        if (acc.tinted[r] > 0) tints[r] = acc.tinted[r] / acc.total;
    }
}

/* ---- zones -------------------------------------------------------------------------------------------------------- */

int myc_cape_row_at(int i) { return myc_cape_rows[i]; }

typedef struct MycCapeZoneCtx { int height; const MycLut* tint; const uint8_t* grad; MycZones* out; int any; } MycCapeZoneCtx;

static void MycCapeBorderCell(MycCapeZoneCtx* ctx, int zone, int j)
{
    int q = myc_cape_rows[j];
    if (q < 0 || q == zone || q >= ctx->height) return;
    double steps = myc_cape_tint_steps(ctx->tint, q, ctx->grad != NULL ? ctx->grad[j * 4] : 0);
    double b = floor(steps / (MYC_CAPE_TINT_STEPS / ZONE_BINS));
    int bin = b < ZONE_BINS - 1 ? (int)b : ZONE_BINS - 1;
    ctx->out->counts[zone][q][bin]++;
    ctx->out->present[zone][q] = 1;
    ctx->any = 1;
}

static void MycCapeBorder(MycCapeZoneCtx* ctx, int zone, int x, int y)
{
    for (int dy = -1; dy <= 1; dy++)
    {
        int yy = y + dy;
        if (yy < 0 || yy >= MYC_CAPE_GRID) continue;
        for (int dx = -1; dx <= 1; dx++)
        {
            int xx = x + dx;
            if ((dy != 0 || dx != 0) && xx >= 0 && xx < MYC_CAPE_GRID) MycCapeBorderCell(ctx, zone, yy * MYC_CAPE_GRID + xx);
        }
    }
}

int myc_cape_zones_of(const uint8_t* cells, int height, const MycLut* tint, const uint8_t* grad, MycZones* zones)
{
    const uint8_t* shape = myc_cape_outline();
    for (int i = 0; i < MYC_CAPE_CELLS; i++)
    {
        const uint8_t* c = cells + i * 4;
        myc_cape_rows[i] = (int8_t)(shape[i] == 1 && c[3] >= MYC_CAPE_THRESHOLD ? MycCapeOutsideRow(c) : -1);
    }
    memset(zones, 0, sizeof *zones);
    MycCapeZoneCtx ctx = {height, grad != NULL ? tint : NULL, tint != NULL ? grad : NULL, zones, 0};
    for (int y = 0; y < MYC_CAPE_GRID; y++)
        for (int x = 0; x < MYC_CAPE_GRID; x++)
        {
            int zone = myc_cape_rows[y * MYC_CAPE_GRID + x];
            if (zone > 0 && zone < height) MycCapeBorder(&ctx, zone, x, y);
        }
    return ctx.any;
}
