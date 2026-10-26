/* Match Your Colors: the texture data the color model needs, decoded from the game's own files (texture.lua), 1:1.
 * A texture resource's main part holds a 0xC0-byte resource header and the DDS header (DX10, 148 bytes); its pixels
 * are in the GPU part, or in the stream part when that one holds the whole mip chain, else in the two parts end to
 * end. Layers are stored one after another, each with its full mip chain (DDS order). Runs on the worker only. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "myc_io.h"

#define HEADER 0xC0u
#define DDS_HEADER 128u
#define DX10_HEADER 20u

static uint32_t MycTexU32(const uint8_t* p, uint32_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }

static uint32_t MycTexBlockBytes(uint32_t format)
{
    switch (format)
    {
    case MYC_FMT_BC7: case MYC_FMT_BC3: case MYC_FMT_BC3_SRGB: return 16;
    case MYC_FMT_BC4: case MYC_FMT_BC1: case MYC_FMT_BC1_SRGB: return 8;
    default: return 0;
    }
}

static uint32_t MycTexTexelBytes(uint32_t format)
{
    if (format == MYC_FMT_RGBA32F) return 16;
    if (format == MYC_FMT_RGBA16F) return 8;
    if (format == MYC_FMT_R8) return 1;
    return 4;
}

static uint32_t MycTexShift(uint32_t v, uint32_t m) { uint32_t s = v >> m; return s > 0 ? s : 1; }

uint64_t myc_mip_bytes(uint32_t format, uint32_t w, uint32_t h, uint32_t m)
{
    uint32_t mw = MycTexShift(w, m), mh = MycTexShift(h, m);
    uint32_t block = MycTexBlockBytes(format);
    if (block != 0)
    {
        uint64_t bw = (mw + 3) >> 2, bh = (mh + 3) >> 2;
        return (bw > 0 ? bw : 1) * (bh > 0 ? bh : 1) * block;
    }
    return (uint64_t)mw * mh * MycTexTexelBytes(format);
}

int myc_tex_describe(const uint8_t* main, uint32_t size, MycTexInfo* out, MycErr* err)
{
    if (size < HEADER + DDS_HEADER + DX10_HEADER || MycTexU32(main, HEADER) != 0x20534444u)
        return myc_fail(err, "texture main part holds no DDS header");
    const uint32_t d = HEADER;
    memset(out, 0, sizeof *out);
    out->height = MycTexU32(main, d + 12);
    out->width = MycTexU32(main, d + 16);
    uint32_t mips = MycTexU32(main, d + 28);
    out->mips = mips > 0 ? mips : 1;
    if (MycTexU32(main, d + 84) != 0x30315844u) return myc_fail(err, "texture is not DX10");
    out->format = MycTexU32(main, d + 128);
    uint32_t layers = MycTexU32(main, d + 140);
    out->layers = layers > 0 ? layers : 1;
    uint32_t f = out->format;
    if (f != MYC_FMT_RGBA16F && f != MYC_FMT_RGBA8 && f != MYC_FMT_RGBA8_SRGB && f != MYC_FMT_R8 && f != MYC_FMT_RGBA32F &&
        MycTexBlockBytes(f) == 0)
        return myc_fail(err, "unsupported texture format %u", f);
    if (out->mips > MYC_MAX_MIPS || out->layers > 4096 || out->width == 0 || out->height == 0)
        return myc_fail(err, "unexpected texture of %u x %u, %u mips", out->width, out->height, out->mips);
    out->layer_bytes = 0;
    for (uint32_t m = 0; m < out->mips; m++)
    {
        out->mip_offsets[m] = out->layer_bytes;
        out->layer_bytes += myc_mip_bytes(f, out->width, out->height, m);
    }
    out->mip_offsets[out->mips] = out->layer_bytes;
    out->total = out->layer_bytes * out->layers;
    return 1;
}

/* ---- pixels ------------------------------------------------------------------------------------------------------- */

#define MODE_GPU 0
#define MODE_STREAM 1
#define MODE_BOTH 2

int myc_pixels_init(MycPixels* p, MycReader* reader, const MycRecord* record, const MycTexInfo* info, MycErr* err)
{
    p->reader = reader;
    p->record = record;
    p->info = *info;
    uint64_t stream = record->size[MYC_STREAM], gpu = record->size[MYC_GPU];
    if (gpu >= info->total) p->mode = MODE_GPU;
    else if (stream >= info->total) p->mode = MODE_STREAM;
    else if (stream + gpu < info->total) return myc_fail(err, "texture data shorter than its mip chain");
    else p->mode = MODE_BOTH;
    return 1;
}

int myc_pixels_read(MycPixels* p, uint64_t at, uint32_t size, uint8_t* out, MycErr* err)
{
    if (p->mode == MODE_GPU) return myc_reader_part(p->reader, p->record, MYC_GPU, at, size, out, err);
    if (p->mode == MODE_STREAM) return myc_reader_part(p->reader, p->record, MYC_STREAM, at, size, out, err);
    uint64_t stream = p->record->size[MYC_STREAM];
    if (at < stream)
    {
        uint32_t take = (uint32_t)(size < stream - at ? size : stream - at);
        if (!myc_reader_part(p->reader, p->record, MYC_STREAM, at, take, out, err)) return 0;
        at += take;
        size -= take;
        out += take;
    }
    return size == 0 || myc_reader_part(p->reader, p->record, MYC_GPU, at - stream, size, out, err);
}

/* ---- numbers ------------------------------------------------------------------------------------------------------ */

double myc_half(uint8_t lo, uint8_t hi)
{
    uint32_t h = lo + hi * 256u;
    double sign = h >= 32768 ? -1 : 1;
    uint32_t exponent = (h >> 10) & 31u, mantissa = h & 1023u;
    if (exponent == 0) return sign * mantissa * pow(2, -24);
    if (exponent == 31) return mantissa == 0 ? sign * INFINITY : NAN;
    return sign * (1 + mantissa / 1024.0) * pow(2, (double)exponent - 15);
}

double myc_single(const uint8_t* p)
{
    uint32_t b2 = p[2], b3 = p[3];
    double sign = b3 >= 128 ? -1 : 1;
    uint32_t exponent = (b3 & 127u) * 2 + (b2 >> 7);
    uint32_t mantissa = (b2 & 127u) * 65536u + p[1] * 256u + p[0];
    if (exponent == 0) return sign * ldexp(mantissa, -149);
    if (exponent == 255) return mantissa == 0 ? sign * INFINITY : NAN;
    return sign * ldexp(8388608.0 + mantissa, (int)exponent - 150);
}

/* The LUT's raw texels (bytes per value: 2 half, 4 single) into values. */
static int MycTexLutValues(MycPixels* p, uint64_t count, uint32_t per, float* values, MycErr* err)
{
    uint8_t* raw = myc_scratch(MYC_SCRATCH_MAIN, count * per);
    if (raw == NULL) return myc_fail(err, "out of memory for a LUT");
    if (!myc_pixels_read(p, 0, (uint32_t)(count * per), raw, err)) return 0;
    for (uint64_t i = 0; i < count; i++)
        values[i] = (float)(per == 2 ? myc_half(raw[2 * i], raw[2 * i + 1]) : myc_single(raw + 4 * i));
    return 1;
}

int myc_tex_lut(MycPixels* p, MycArena* arena, MycLut* out, MycErr* err)
{
    const MycTexInfo* info = &p->info;
    uint64_t count = (uint64_t)info->width * info->height * 4;
    uint32_t per = info->format == MYC_FMT_RGBA16F ? 2 : (info->format == MYC_FMT_RGBA32F ? 4 : 0);
    if (per == 0) return myc_fail(err, "material LUT format %u (neither RGBA16F nor RGBA32F)", info->format);
    if (count > (1u << 24)) return myc_fail(err, "material LUT of %u x %u", info->width, info->height);
    float* values = myc_alloc(arena, count * sizeof(float));
    if (values == NULL) return myc_fail(err, "out of memory for a LUT");
    if (!MycTexLutValues(p, count, per, values, err)) return 0;
    out->values = values;
    out->width = (int)info->width;
    out->height = (int)info->height;
    return 1;
}

/* ---- coverage ----------------------------------------------------------------------------------------------------- */

#define MAX_CHANNELS 64

/* Adds the normalized weights of texels [first, first + count) (all layers, `plane` bytes apart) to sums; how many
 * texels counted (weight sum above 0.05). */
static int MycTexAccumulate(const uint8_t* data, uint32_t plane, uint32_t layers, uint32_t first, uint32_t count,
    double* sums, double* weights)
{
    uint32_t channels = 4 * layers;
    int valid = 0;
    for (uint32_t t = first; t < first + count; t++)
    {
        double total = 0;
        for (uint32_t k = 0; k < channels; k++)
        {
            double v = data[(k - k % 4) / 4 * plane + t * 4 + k % 4] / 255.0;
            weights[k] = v;
            total = total + v;
        }
        if (total > 0.05)
        {
            valid++;
            for (uint32_t k = 0; k < channels; k++) sums[k] = sums[k] + weights[k] / total;
        }
    }
    return valid;
}

typedef struct MycCoverRun { uint32_t w, h, layers, row_bytes, rows_per_block; uint64_t base; } MycCoverRun;

/* The mip coverage reads: the first no larger than COVERAGE_SIZE on either side. */
static void MycTexCoverRun(const MycTexInfo* info, MycCoverRun* run)
{
    uint32_t m = 0;
    while (m + 1 < info->mips && ((info->width >> m) > MYC_COVERAGE_SIZE || (info->height >> m) > MYC_COVERAGE_SIZE)) m++;
    run->w = MycTexShift(info->width, m);
    run->h = MycTexShift(info->height, m);
    run->layers = info->layers;
    run->base = info->mip_offsets[m];
    run->row_bytes = run->w * 4;
    run->rows_per_block = MYC_COVERAGE_BLOCK / (run->row_bytes * run->layers);
    if (run->rows_per_block < 1) run->rows_per_block = 1;
}

/* One block of rows from `first`, every layer's, into data; how many rows. */
static uint32_t MycTexCoverBlock(MycPixels* p, const MycCoverRun* run, uint32_t first, uint8_t* data, MycErr* err)
{
    uint32_t rows = run->rows_per_block < run->h - first ? run->rows_per_block : run->h - first;
    uint32_t plane = rows * run->row_bytes;
    for (uint32_t l = 0; l < run->layers; l++)
        if (!myc_pixels_read(p, l * p->info.layer_bytes + run->base + (uint64_t)first * run->row_bytes, plane, data + l * plane, err))
            return 0;
    return rows;
}

int myc_tex_coverage(MycPixels* p, double* out, MycErr* err, const char** why)
{
    const MycTexInfo* info = &p->info;
    *why = NULL;
    if (info->format != MYC_FMT_RGBA8 && info->format != MYC_FMT_RGBA8_SRGB) { *why = "id mask format"; return 0; }
    if (info->layers * 4 > MAX_CHANNELS) return myc_fail(err, "id mask of %u layers", info->layers);
    MycCoverRun run;
    MycTexCoverRun(info, &run);
    uint8_t* data = myc_scratch(MYC_SCRATCH_BIG, (size_t)run.rows_per_block * run.row_bytes * run.layers);
    if (data == NULL) return myc_fail(err, "out of memory for an id mask");
    double sums[MAX_CHANNELS] = {0}, weights[MAX_CHANNELS];
    int valid = 0;
    for (uint32_t first = 0; first < run.h; first += run.rows_per_block)
    {
        uint32_t rows = MycTexCoverBlock(p, &run, first, data, err);
        if (rows == 0) return 0;
        for (uint32_t y = 0; y < rows; y++)
            valid += MycTexAccumulate(data, rows * run.row_bytes, run.layers, y * run.w, run.w, sums, weights);
    }
    for (uint32_t k = 0; k < 4 * run.layers; k++) out[k] = sums[k] / (valid > 1 ? valid : 1);
    return (int)(4 * run.layers);
}

/* The mask strength of `count` texels (every per-th byte) added to sum, in texel order. */
static double MycTexMaskSum(const uint8_t* data, uint32_t count, uint32_t per, double sum)
{
    for (uint32_t i = 0; i < count; i++) sum = sum + myc_clip(100 * (data[i * per] / 255.0 - 0.5));
    return sum;
}

double myc_tex_mask_coverage(MycPixels* p, int layer, uint32_t mip, int* ok, MycErr* err)
{
    const MycTexInfo* info = &p->info;
    uint32_t f = info->format;
    uint32_t per = f == MYC_FMT_R8 ? 1 : ((f == MYC_FMT_RGBA8 || f == MYC_FMT_RGBA8_SRGB) ? 4 : 0);
    *ok = 0;
    if (per == 0) return 0;
    if (mip > info->mips - 1) mip = info->mips - 1;
    uint32_t w = MycTexShift(info->width, mip), h = MycTexShift(info->height, mip);
    uint32_t rows = MYC_MASK_BLOCK / w;
    if (rows < 1) rows = 1;
    uint8_t* data = myc_scratch(MYC_SCRATCH_MAIN, (size_t)(rows < h ? rows : h) * w * per);
    if (data == NULL) { myc_fail(err, "out of memory for a pattern mask"); return 0; }
    int n = (int)info->layers, index = ((layer % n) + n) % n;
    uint64_t base = (uint64_t)index * info->layer_bytes + info->mip_offsets[mip];
    double sum = 0;
    for (uint32_t first = 0; first < h; first += rows)
    {
        uint32_t count = (rows < h - first ? rows : h - first) * w;
        if (!myc_pixels_read(p, base + (uint64_t)first * w * per, count * per, data, err)) return 0;
        sum = MycTexMaskSum(data, count, per, sum);
    }
    *ok = 1;
    return sum / ((double)w * h);
}

/* ---- BC7 ---------------------------------------------------------------------------------------------------------- */

/* partition bits, subsets, color bits, alpha bits, endpoint p-bits, shared p-bits, index bits, secondary index bits */
static const uint8_t kMycBc7Modes[8][8] = {
    {4, 3, 4, 0, 1, 0, 3, 0}, {6, 2, 6, 0, 0, 1, 3, 0}, {6, 3, 5, 0, 0, 0, 2, 0}, {6, 2, 7, 0, 1, 0, 2, 0},
    {0, 1, 5, 6, 0, 0, 2, 3}, {0, 1, 7, 8, 0, 0, 2, 2}, {0, 1, 7, 7, 1, 0, 4, 0}, {6, 2, 5, 5, 1, 0, 2, 0},
};
static const char* const kMycPartitions2[64] = {
    "0011001100110011", "0001000100010001", "0111011101110111", "0001001100110111", "0000000100010011",
    "0011011101111111", "0001001101111111", "0000000100110111", "0000000000010011", "0011011111111111",
    "0000000101111111", "0000000000010111", "0001011111111111", "0000000011111111", "0000111111111111",
    "0000000000001111", "0000100011101111", "0111000100000000", "0000000010001110", "0111001100010000",
    "0011000100000000", "0000100011001110", "0000000010001100", "0111001100110001", "0011000100010000",
    "0000100010001100", "0110011001100110", "0011011001101100", "0001011111101000", "0000111111110000",
    "0111000110001110", "0011100110011100", "0101010101010101", "0000111100001111", "0101101001011010",
    "0011001111001100", "0011110000111100", "0101010110101010", "0110100101101001", "0101101010100101",
    "0111001111001110", "0001001111001000", "0011001001001100", "0011101111011100", "0110100110010110",
    "0011110011000011", "0110011010011001", "0000011001100000", "0100111001000000", "0010011100100000",
    "0000001001110010", "0000010011100100", "0110110010010011", "0011011011001001", "0110001110011100",
    "0011100111000110", "0110110011001001", "0110001100111001", "0111111010000001", "0001100011100111",
    "0000111100110011", "0011001111110000", "0010001011101110", "0100010001110111",
};
static const char* const kMycPartitions3[64] = {
    "0011001102212222", "0001001122112221", "0000200122112211", "0222002200110111", "0000000011221122",
    "0011001100220022", "0022002211111111", "0011001122112211", "0000000011112222", "0000111111112222",
    "0000111122222222", "0012001200120012", "0112011201120112", "0122012201220122", "0011011211221222",
    "0011200122002220", "0001001101121122", "0111001120012200", "0000112211221122", "0022002200221111",
    "0111011102220222", "0001000122212221", "0000001101220122", "0000110022102210", "0122012200110000",
    "0012001211222222", "0110122112210110", "0000011012211221", "0022110211020022", "0110011020022222",
    "0011012201220011", "0000200022112221", "0000000211221222", "0222002200120011", "0011001200220222",
    "0120012001200120", "0000111122220000", "0120120120120120", "0120201212010120", "0011220011220011",
    "0011112222000011", "0101010122222222", "0000000021212121", "0022112200221122", "0022001100220011",
    "0220122102201221", "0101222222220101", "0000212121212121", "0101010101012222", "0222011102220111",
    "0002111200021112", "0000211221122112", "0222011101110222", "0002111211120002", "0110011001102222",
    "0000000021122112", "0110011022222222", "0022001100110022", "0022112211220022", "0000000000002112",
    "0002000100020001", "0222122202221222", "0101222222222222", "0111201122012220",
};
static const uint8_t kMycAnchor2[64] = {
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6, 6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
};
static const uint8_t kMycAnchor31[64] = {
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3, 3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15, 3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
};
static const uint8_t kMycAnchor32[64] = {
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8, 15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8, 15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
};
static const uint8_t kMycWeights2[4] = {0, 21, 43, 64};
static const uint8_t kMycWeights3[8] = {0, 9, 18, 27, 37, 46, 55, 64};
static const uint8_t kMycWeights4[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};

typedef struct MycBc7
{
    const uint8_t* block;
    uint32_t position;
    uint32_t e[4][6];       /* endpoints [channel][endpoint] */
    uint32_t p[6];
    uint32_t primary[16], secondary[16];
    int subsets, partition, rotation, color_bits, alpha_bits, has_alpha_index;
    const uint32_t* color_index;
    const uint32_t* alpha_index;
} MycBc7;

static uint32_t MycBc7Bits(MycBc7* s, uint32_t count)
{
    uint32_t p = s->position, at = p >> 3, shift = p & 7;
    uint32_t value = s->block[at];
    if (shift + count > 8) value = value + s->block[at + 1] * 256u;
    s->position = p + count;
    return (value >> shift) & ((1u << count) - 1);
}

/* The subset of texel t and whether it is its subset's anchor. */
static int MycBc7Subset(int subsets, int partition, int t, int* anchor)
{
    if (subsets == 1) { *anchor = t == 0; return 0; }
    const char* row = subsets == 2 ? kMycPartitions2[partition] : kMycPartitions3[partition];
    int s = row[t] - '0';
    if (s == 0) { *anchor = t == 0; return 0; }
    if (subsets == 2) { *anchor = kMycAnchor2[partition] == t; return 1; }
    *anchor = (s == 1 ? kMycAnchor31 : kMycAnchor32)[partition] == t;
    return s;
}

static uint32_t MycBc7Widen(uint32_t value, uint32_t bits)
{
    value = value << (8 - bits);
    return value | (value >> bits);
}

/* The p-bits: one per endpoint, or one per subset shared by its two endpoints. */
static void MycBc7Pbits(MycBc7* s, const uint8_t* m, int count)
{
    if (m[4])
    {
        for (int i = 0; i < count; i++) s->p[i] = MycBc7Bits(s, 1);
        return;
    }
    for (int k = 0; k < m[1]; k++)
    {
        uint32_t v = MycBc7Bits(s, 1);
        s->p[2 * k] = v;
        s->p[2 * k + 1] = v;
    }
}

/* Endpoint i's channel c with its p-bit below it (when the mode has p-bits), widened to 8 bits. */
static uint32_t MycBc7Finish(const MycBc7* s, int c, int i, int with_p, uint32_t bits)
{
    uint32_t v = with_p ? ((s->e[c][i] << 1) | s->p[i]) : s->e[c][i];
    return MycBc7Widen(v, bits);
}

static void MycBc7Endpoints(MycBc7* s, const uint8_t* m)
{
    int count = m[1] * 2;
    uint32_t color_bits = m[2], alpha_bits = m[3];
    for (int c = 0; c < 3; c++)
        for (int i = 0; i < count; i++) s->e[c][i] = MycBc7Bits(s, color_bits);
    for (int i = 0; i < count; i++) s->e[3][i] = alpha_bits > 0 ? MycBc7Bits(s, alpha_bits) : 255;
    int with_p = m[4] || m[5];
    if (with_p)
    {
        MycBc7Pbits(s, m, count);
        color_bits = color_bits + 1;
        alpha_bits = alpha_bits > 0 ? alpha_bits + 1 : 0;
    }
    for (int i = 0; i < count; i++)
    {
        for (int c = 0; c < 3; c++) s->e[c][i] = MycBc7Finish(s, c, i, with_p, color_bits);
        if (alpha_bits > 0) s->e[3][i] = MycBc7Finish(s, 3, i, with_p, alpha_bits);
    }
}

static void MycBc7Indices(MycBc7* s, int subsets, int partition, uint32_t bits, uint32_t* out)
{
    for (int t = 0; t < 16; t++)
    {
        int anchor;
        (void)MycBc7Subset(subsets, partition, t, &anchor);
        out[t] = MycBc7Bits(s, anchor ? bits - 1 : bits);
    }
}

static uint32_t MycBc7Weight(int bits, uint32_t index)
{
    if (bits == 2) return kMycWeights2[index & 3];
    if (bits == 3) return kMycWeights3[index & 7];
    return kMycWeights4[index & 15];
}

static uint32_t MycBc7Interpolate(uint32_t a, uint32_t b, uint32_t w) { return ((64 - w) * a + w * b + 32) >> 6; }

static void MycBc7Texel(const MycBc7* s, int t, uint8_t* out)
{
    int anchor;
    int sub = MycBc7Subset(s->subsets, s->partition, t, &anchor);
    int e0 = 2 * sub, e1 = 2 * sub + 1;
    uint32_t wc = MycBc7Weight(s->color_bits, s->color_index[t]);
    uint32_t r = MycBc7Interpolate(s->e[0][e0], s->e[0][e1], wc);
    uint32_t g = MycBc7Interpolate(s->e[1][e0], s->e[1][e1], wc);
    uint32_t b = MycBc7Interpolate(s->e[2][e0], s->e[2][e1], wc);
    uint32_t wa = s->has_alpha_index ? MycBc7Weight(s->alpha_bits, s->alpha_index[t]) : wc;
    uint32_t a = MycBc7Interpolate(s->e[3][e0], s->e[3][e1], wa), x;
    if (s->rotation == 1) { x = r; r = a; a = x; }
    else if (s->rotation == 2) { x = g; g = a; a = x; }
    else if (s->rotation == 3) { x = b; b = a; a = x; }
    out[4 * t] = (uint8_t)r;
    out[4 * t + 1] = (uint8_t)g;
    out[4 * t + 2] = (uint8_t)b;
    out[4 * t + 3] = (uint8_t)a;
}

void myc_bc7_block(const uint8_t* block, uint8_t out[64])
{
    uint8_t first = block[0];
    if (first == 0) { memset(out, 0, 64); return; }
    int mode = 0;
    while (((first >> mode) & 1) == 0) mode++;
    MycBc7 s;
    memset(&s, 0, sizeof s);
    s.block = block;
    s.position = (uint32_t)mode + 1;
    const uint8_t* m = kMycBc7Modes[mode];
    s.subsets = m[1];
    s.partition = m[0] > 0 ? (int)MycBc7Bits(&s, m[0]) : 0;
    s.rotation = (mode == 4 || mode == 5) ? (int)MycBc7Bits(&s, 2) : 0;
    uint32_t selector = mode == 4 ? MycBc7Bits(&s, 1) : 0;
    MycBc7Endpoints(&s, m);
    MycBc7Indices(&s, s.subsets, s.partition, m[6], s.primary);
    if (m[7] > 0) MycBc7Indices(&s, 1, 0, m[7], s.secondary);
    s.color_index = s.primary;
    s.alpha_index = m[7] > 0 ? s.secondary : NULL;
    s.has_alpha_index = m[7] > 0;
    s.color_bits = m[6];
    s.alpha_bits = m[7];
    if (selector == 1)
    {
        s.color_index = s.secondary;
        s.alpha_index = s.primary;
        s.color_bits = m[7];
        s.alpha_bits = m[6];
    }
    for (int t = 0; t < 16; t++) MycBc7Texel(&s, t, out);
}

/* ---- samples ------------------------------------------------------------------------------------------------------ */

/* The 16 texels of one decoded block at (bx, by) into values (row-major, w texels a row), those below count only. */
static void MycTexPlace(const uint8_t texel[64], uint32_t bx, uint32_t by, uint32_t w, uint32_t count, double* values)
{
    for (uint32_t t = 0; t < 16; t++)
    {
        uint32_t x = bx * 4 + t % 4, y = by * 4 + (t >> 2), i = y * w + x;
        if (x >= w || i >= count) continue;
        for (int c = 0; c < 4; c++) values[i * 4 + c] = texel[t * 4 + c] / 255.0;
    }
}

static int MycTexBc7Texels(MycPixels* p, uint64_t base, uint32_t w, uint32_t count, double* values, MycErr* err)
{
    uint32_t blocks_wide = (w + 3) >> 2;
    if (blocks_wide < 1) blocks_wide = 1;
    uint32_t block_rows = ((count + w - 1) / w + 3) / 4;
    uint8_t* raw = myc_scratch(MYC_SCRATCH_MAIN, (size_t)blocks_wide * block_rows * 16);
    if (raw == NULL) return myc_fail(err, "out of memory for a tiler");
    if (!myc_pixels_read(p, base, blocks_wide * block_rows * 16, raw, err)) return 0;
    uint8_t texel[64];
    for (uint32_t by = 0; by < block_rows; by++)
        for (uint32_t bx = 0; bx < blocks_wide; bx++)
        {
            myc_bc7_block(raw + (by * blocks_wide + bx) * 16, texel);
            MycTexPlace(texel, bx, by, w, count, values);
        }
    return 1;
}

static int MycTexFloatTexels(MycPixels* p, uint64_t base, uint32_t count, double* values, MycErr* err)
{
    uint32_t per = MycTexTexelBytes(p->info.format) / 4;
    uint8_t* raw = myc_scratch(MYC_SCRATCH_MAIN, (size_t)count * 4 * per);
    if (raw == NULL) return myc_fail(err, "out of memory for a tiler");
    if (!myc_pixels_read(p, base, count * 4 * per, raw, err)) return 0;
    for (uint32_t i = 0; i < count * 4; i++)
    {
        double v = per == 2 ? myc_half(raw[2 * i], raw[2 * i + 1]) : myc_single(raw + 4 * i);
        if (!(v > 0)) v = 0;
        else if (v > 1) v = 1;
        values[i] = floor(v * 255 + 0.5) / 255;
    }
    return 1;
}

static int MycTexByteTexels(MycPixels* p, uint64_t base, uint32_t count, double* values, MycErr* err)
{
    uint8_t* raw = myc_scratch(MYC_SCRATCH_MAIN, (size_t)count * 4);
    if (raw == NULL) return myc_fail(err, "out of memory for a tiler");
    if (!myc_pixels_read(p, base, count * 4, raw, err)) return 0;
    for (uint32_t i = 0; i < count * 4; i++) values[i] = raw[i] / 255.0;
    return 1;
}

/* One layer's first `count` texels of mip `mip`, by the tiler's format. */
static int MycTexLayer(MycPixels* p, uint32_t l, uint32_t mip, uint32_t count, double* values, MycErr* err)
{
    uint32_t f = p->info.format;
    uint64_t base = l * p->info.layer_bytes + p->info.mip_offsets[mip];
    if (f == MYC_FMT_BC7) return MycTexBc7Texels(p, base, MycTexShift(p->info.width, mip), count, values, err);
    if (f == MYC_FMT_RGBA16F || f == MYC_FMT_RGBA32F) return MycTexFloatTexels(p, base, count, values, err);
    return MycTexByteTexels(p, base, count, values, err);
}

int myc_tex_samples(MycPixels* p, uint32_t mip, uint32_t count, MycArena* arena, double** layers, int max_layers,
    MycErr* err)
{
    const MycTexInfo* info = &p->info;
    uint32_t f = info->format;
    int known = f == MYC_FMT_BC7 || f == MYC_FMT_RGBA8 || f == MYC_FMT_RGBA8_SRGB || f == MYC_FMT_RGBA16F || f == MYC_FMT_RGBA32F;
    if (!known) { myc_fail(err, "tiler format %u", f); return -1; }
    if ((int)info->layers > max_layers || mip >= info->mips) { myc_fail(err, "unexpected tiler"); return -1; }
    for (uint32_t l = 0; l < info->layers; l++)
    {
        double* values = myc_alloc(arena, (size_t)count * 4 * sizeof(double));
        if (values == NULL) { myc_fail(err, "out of memory for a tiler"); return -1; }
        if (!MycTexLayer(p, l, mip, count, values, err)) return -1;
        layers[l] = values;
    }
    return (int)info->layers;
}
