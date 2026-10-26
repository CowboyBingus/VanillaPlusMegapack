/* Match Your Colors: modded gear without a color table (albedo.lua, v1.5), 1:1. Read: the first mip of the albedo no
 * larger than READ_SIDE is decoded with its mra at the same size; its opaque texels are binned (4-4-4 sRGB and a metal
 * bit, linear sums) and clustered (farthest-point seeds at least SEED_DE apart, at most LLOYD_STEPS steps, at most
 * CLUSTERS, a cluster under MERGE_SHARE merged into its nearest). Recolor: each planned cluster's goal moves the
 * texture's block endpoints, every distinct RGB565 endpoint mapped once by its closeness to the clusters. Runs on the
 * worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_albedo.h"

#define READ_SIDE 256u
#define CLUSTERS 8
#define SEED_DE 6.0
#define LLOYD_STEPS 8
#define MERGE_SHARE 0.005
#define METAL_AXIS 30.0
#define WEIGHT_DE 4.0
#define NEUTRAL_C 5.0
#define BINS 8192

static const double kMycResponse[6] = {0.7140, 0.6710, 0.6400, 0.00600, 0.00670, 0.00730};

static double g_bins[BINS * 5];
static double g_toLinear[256];
static int g_tables;

static void MycAlbedoTables(void)
{
    if (g_tables) return;
    for (int i = 0; i < 256; i++)
    {
        double c = i / 255.0;
        g_toLinear[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    g_tables = 1;
}

MycLab myc_albedo_look(double r, double g, double b)
{
    double seen[3];
    myc_seen(kMycResponse, r, g, b, 1, seen);
    return myc_linear_to_lab(seen[0], seen[1], seen[2]);
}

MycLab myc_albedo_unlook(double L, double a, double b)
{
    double k[3];
    myc_lab_to_linear(L, a, b, k);
    return myc_linear_to_lab(myc_max((k[0] - kMycResponse[3]) / kMycResponse[0], 0),
        myc_max((k[1] - kMycResponse[4]) / kMycResponse[1], 0), myc_max((k[2] - kMycResponse[5]) / kMycResponse[2], 0));
}

static int MycAlbedoBc1(uint32_t f) { return f == MYC_FMT_BC1 || f == MYC_FMT_BC1_SRGB; }
static int MycAlbedoBc3(uint32_t f) { return f == MYC_FMT_BC3 || f == MYC_FMT_BC3_SRGB; }
static uint32_t MycAlbedoBlockBytes(uint32_t f) { return MycAlbedoBc1(f) ? 8 : 16; }
static uint32_t MycAlbedoSide(uint32_t v, uint32_t m) { uint32_t s = v >> m; return s > 0 ? s : 1; }

static void MycAlbedo565(uint32_t e, uint32_t* r, uint32_t* g, uint32_t* b)
{
    uint32_t r5 = e >> 11, g6 = (e >> 5) & 63u, b5 = e & 31u;
    *r = (r5 << 3) | (r5 >> 2);
    *g = (g6 << 2) | (g6 >> 4);
    *b = (b5 << 3) | (b5 >> 2);
}

void myc_albedo_color_block(const uint8_t* p, uint8_t out[64], int three_color)
{
    uint32_t c0 = p[0] + p[1] * 256u, c1 = p[2] + p[3] * 256u, r0, g0, b0, r1, g1, b1;
    MycAlbedo565(c0, &r0, &g0, &b0);
    MycAlbedo565(c1, &r1, &g1, &b1);
    int four = c0 > c1 || !three_color;
    uint32_t idx;
    memcpy(&idx, p + 4, 4);
    for (int t = 0; t < 16; t++)
    {
        uint32_t i = (idx >> (2 * t)) & 3u, r = r0, g = g0, b = b0, a = 255;
        if (i == 1) { r = r1; g = g1; b = b1; }
        else if (i == 2)
        {
            if (four) { r = (2 * r0 + r1) / 3; g = (2 * g0 + g1) / 3; b = (2 * b0 + b1) / 3; }
            else { r = (r0 + r1) / 2; g = (g0 + g1) / 2; b = (b0 + b1) / 2; }
        }
        else if (i == 3)
        {
            if (four) { r = (r0 + 2 * r1) / 3; g = (g0 + 2 * g1) / 3; b = (b0 + 2 * b1) / 3; }
            else { r = g = b = a = 0; }
        }
        out[4 * t] = (uint8_t)r;
        out[4 * t + 1] = (uint8_t)g;
        out[4 * t + 2] = (uint8_t)b;
        out[4 * t + 3] = (uint8_t)a;
    }
}

/* ---- eligibility ------------------------------------------------------------------------------------------------------ */

int myc_albedo_eligible(const MycRecord* record, const MycTexSlots* textures, MycFind* find, MycAlbedoEntry* out,
    char* why, size_t size, MycErr* err)
{
    uint64_t albedo;
    if (record->patch < 0) { snprintf(why, size, "not a mod's material"); return 0; }
    if (textures->parent != MYC_ALBEDO_TEMPLATE)
    {
        snprintf(why, size, "shader template %016llx", (unsigned long long)textures->parent);
        return 0;
    }
    if (!myc_tex_slot(textures, MYC_SLOT_ALBEDO, &albedo)) { snprintf(why, size, "no albedo"); return 0; }
    MycPixels p;
    MycErr described = {0};
    int got = myc_tex_open(find, albedo, &p, &described);
    if (got <= 0)
    {
        snprintf(why, size, "albedo %016llx: %s", (unsigned long long)albedo, got == 0 ? "not found" : described.why);
        return 0;
    }
    uint32_t f = p.info.format, w = p.info.width, h = p.info.height;
    if (!MycAlbedoBc1(f) && !MycAlbedoBc3(f)) { snprintf(why, size, "albedo format %u", f); return 0; }
    if ((w & (w - 1)) != 0 || (h & (h - 1)) != 0) { snprintf(why, size, "albedo size %u x %u", w, h); return 0; }
    out->albedo = albedo;
    out->has_mra = myc_tex_slot(textures, MYC_SLOT_MRA, &out->mra);
    return 1;
}

/* ---- reading -------------------------------------------------------------------------------------------------------------- */

static uint32_t MycAlbedoReadMip(const MycTexInfo* info)
{
    for (uint32_t m = 0; m < info->mips; m++)
        if (MycAlbedoSide(info->width, m) <= READ_SIDE && MycAlbedoSide(info->height, m) <= READ_SIDE) return m;
    return info->mips - 1;
}

/* The mra's mip of w x h (BC3 blocks) into a buffer (malloc'd), or NULL (no mra, another format, no such mip). */
static uint8_t* MycAlbedoMra(MycFind* find, const MycAlbedoEntry* entry, uint32_t w, uint32_t h, MycErr* err)
{
    MycPixels p;
    if (!entry->has_mra || myc_tex_open(find, entry->mra, &p, err) <= 0 || !MycAlbedoBc3(p.info.format)) return NULL;
    for (uint32_t m = 0; m < p.info.mips; m++)
        if (MycAlbedoSide(p.info.width, m) == w && MycAlbedoSide(p.info.height, m) == h)
        {
            uint32_t size = ((w + 3) >> 2) * ((h + 3) >> 2) * 16;
            uint8_t* mra = malloc(size);
            if (mra == NULL) { myc_fail(err, "out of memory"); return NULL; }
            if (!myc_pixels_read(&p, p.info.mip_offsets[m], size, mra, err)) { free(mra); return NULL; }
            return mra;
        }
    return NULL;
}

static void MycAlbedoBinBlock(const uint8_t* p, int three, const uint8_t* mra)
{
    uint8_t texels[64], mra_texels[64];
    myc_albedo_color_block(p, texels, three);
    if (mra != NULL) myc_albedo_color_block(mra + 8, mra_texels, 0);
    for (int t = 0; t < 16; t++)
    {
        if (texels[4 * t + 3] < 128) continue;
        uint32_t r = texels[4 * t], g = texels[4 * t + 1], b = texels[4 * t + 2];
        int metal = mra != NULL && mra_texels[4 * t] >= 128;
        uint32_t k = ((r >> 4) * 256 + (g >> 4) * 16 + (b >> 4) + (metal ? 4096u : 0u)) * 5;
        g_bins[k] = g_bins[k] + 1;
        g_bins[k + 1] = g_bins[k + 1] + g_toLinear[r];
        g_bins[k + 2] = g_bins[k + 2] + g_toLinear[g];
        g_bins[k + 3] = g_bins[k + 3] + g_toLinear[b];
        if (metal) g_bins[k + 4] = g_bins[k + 4] + 1;
    }
}

typedef struct MycPoint { double count, lin[3], lab[3], metal; } MycPoint;
typedef struct MycCenter { double count, lin[3], lab[3], metal; } MycCenter;

static double MycAlbedoD2(const double plab[3], double pmetal, const double clab[3], double cmetal)
{
    double dL = plab[0] - clab[0], da = plab[1] - clab[1], db = plab[2] - clab[2], dm = (pmetal - cmetal) * METAL_AXIS;
    return dL * dL + da * da + db * db + dm * dm;
}

static int MycAlbedoNearest(const MycPoint* p, const MycCenter* c, int k)
{
    int best = 0;
    double bd = INFINITY;
    for (int i = 0; i < k; i++)
    {
        double d = MycAlbedoD2(p->lab, p->metal, c[i].lab, c[i].metal);
        if (d < bd) { best = i; bd = d; }
    }
    return best;
}

/* Farthest-point seeds: the heaviest point, then the farthest while there is one, at most CLUSTERS. */
static int MycAlbedoSeeds(const MycPoint* pts, int n, double* near, MycCenter* out)
{
    const MycPoint* best = NULL;
    for (int i = 0; i < n; i++)
        if (best == NULL || pts[i].count > best->count) best = &pts[i];
    int k = 0;
    memcpy(out[k].lab, best->lab, sizeof best->lab);
    out[k++].metal = best->metal;
    for (int i = 0; i < n; i++) near[i] = INFINITY;
    while (k < CLUSTERS)
    {
        const MycPoint* pick = NULL;
        double score = -1;
        for (int i = 0; i < n; i++)
        {
            double d = myc_min(near[i], MycAlbedoD2(pts[i].lab, pts[i].metal, out[k - 1].lab, out[k - 1].metal));
            near[i] = d;
            if (d >= SEED_DE * SEED_DE && pts[i].count * d > score) { pick = &pts[i]; score = pts[i].count * d; }
        }
        if (pick == NULL) break;
        memcpy(out[k].lab, pick->lab, sizeof pick->lab);
        out[k++].metal = pick->metal;
    }
    return k;
}

/* Clusters from the assignment: mean linear color and metal by count; empty ones dropped; the new count. */
static int MycAlbedoMeans(const MycPoint* pts, int n, const int* assign, int k, MycCenter* out)
{
    MycCenter acc[CLUSTERS];
    memset(acc, 0, sizeof acc);
    for (int i = 0; i < n; i++)
    {
        MycCenter* a = &acc[assign[i]];
        a->count = a->count + pts[i].count;
        for (int c = 0; c < 3; c++) a->lin[c] = a->lin[c] + pts[i].count * pts[i].lin[c];
        a->metal = a->metal + pts[i].count * pts[i].metal;
    }
    int m = 0;
    for (int i = 0; i < k; i++)
    {
        if (acc[i].count <= 0) continue;
        MycCenter* c = &out[m++];
        c->count = acc[i].count;
        for (int j = 0; j < 3; j++) c->lin[j] = acc[i].lin[j] / acc[i].count;
        MycLab lab = myc_linear_to_lab(c->lin[0], c->lin[1], c->lin[2]);
        c->lab[0] = lab.L;
        c->lab[1] = lab.a;
        c->lab[2] = lab.b;
        c->metal = acc[i].metal / acc[i].count;
    }
    return m;
}

static int MycAlbedoAssigned(const MycPoint* pts, int n, const MycCenter* c, int k, int* assign)
{
    int moved = 0;
    for (int i = 0; i < n; i++)
    {
        int nearest = MycAlbedoNearest(&pts[i], c, k);
        if (assign[i] != nearest) { assign[i] = nearest; moved = 1; }
    }
    return moved;
}

static int MycAlbedoClusterLess(const void* x, const void* y, void* ctx)
{
    const MycCluster* a = x;
    const MycCluster* b = y;
    if (a->count != b->count) return a->count > b->count;
    return a->lab[0] < b->lab[0];
}

static int MycAlbedoCluster(const MycPoint* pts, int n, MycAlbedo* out, MycErr* err)
{
    double* near = malloc(sizeof(double) * (size_t)n);
    int* assign = malloc(sizeof(int) * (size_t)n);
    if (near == NULL || assign == NULL) { free(near); free(assign); return myc_fail(err, "out of memory"); }
    for (int i = 0; i < n; i++) assign[i] = -1;
    MycCenter c[CLUSTERS], kept[CLUSTERS];
    int k = MycAlbedoSeeds(pts, n, near, c);
    for (int step = 0; step < LLOYD_STEPS; step++)
    {
        int moved = MycAlbedoAssigned(pts, n, c, k, assign);
        k = MycAlbedoMeans(pts, n, assign, k, c);
        if (!moved) break;
    }
    double total = 0;
    for (int i = 0; i < k; i++) total = total + c[i].count;
    int m = 0;
    for (int i = 0; i < k; i++)
        if (c[i].count >= MERGE_SHARE * total) kept[m++] = c[i];
    (void)MycAlbedoAssigned(pts, n, kept, m, assign);
    m = MycAlbedoMeans(pts, n, assign, m, c);
    free(near);
    free(assign);
    void* order[CLUSTERS];
    for (int i = 0; i < m; i++)
    {
        MycCluster* cl = &out->clusters[i];
        cl->count = c[i].count;
        memcpy(cl->lin, c[i].lin, sizeof cl->lin);
        memcpy(cl->lab, c[i].lab, sizeof cl->lab);
        cl->metal = c[i].metal;
    }
    MycCluster sorted[CLUSTERS];
    for (int i = 0; i < m; i++) order[i] = &out->clusters[i];
    myc_lua_sort(order, m, MycAlbedoClusterLess, NULL);
    for (int i = 0; i < m; i++) sorted[i] = *(MycCluster*)order[i];
    for (int i = 0; i < m; i++)
    {
        out->clusters[i] = sorted[i];
        out->clusters[i].share = sorted[i].count / total;
        MycLab seen = myc_albedo_look(sorted[i].lin[0], sorted[i].lin[1], sorted[i].lin[2]);
        out->clusters[i].seen[0] = seen.L;
        out->clusters[i].seen[1] = seen.a;
        out->clusters[i].seen[2] = seen.b;
    }
    out->nclusters = m;
    return 1;
}

/* The read mip's color blocks binned into g_bins (with the material's metalness when its MRA is there); 0 on an
 * error (after myc_fail). */
static int MycAlbedoBinMip(MycFind* find, const MycAlbedoEntry* entry, MycPixels* p, MycErr* err)
{
    MycTexInfo info = p->info;
    uint32_t m = MycAlbedoReadMip(&info), w = MycAlbedoSide(info.width, m), h = MycAlbedoSide(info.height, m);
    uint32_t step = MycAlbedoBlockBytes(info.format), blocks = ((w + 3) >> 2) * ((h + 3) >> 2);
    uint8_t* data = malloc((size_t)blocks * step);
    if (data == NULL) return myc_fail(err, "out of memory");
    if (!myc_pixels_read(p, info.mip_offsets[m], blocks * step, data, err)) { free(data); return 0; }
    uint8_t* mra = MycAlbedoMra(find, entry, w, h, err);
    if (err->failed) { free(data); return 0; }
    memset(g_bins, 0, sizeof g_bins);
    for (uint32_t i = 0; i < blocks; i++)
        MycAlbedoBinBlock(data + (size_t)i * step + (step == 16 ? 8 : 0), MycAlbedoBc1(info.format), mra != NULL ? mra + (size_t)i * 16 : NULL);
    free(data);
    free(mra);
    return 1;
}

/* The bins that hold texels as points (their mean color and metalness): how many. */
static int MycAlbedoPoints(MycPoint* pts)
{
    int n = 0;
    for (int k = 0; k < BINS; k++)
    {
        double count = g_bins[5 * k];
        if (count <= 0) continue;
        MycPoint* pt = &pts[n++];
        pt->count = count;
        for (int c = 0; c < 3; c++) pt->lin[c] = g_bins[5 * k + 1 + c] / count;
        MycLab lab = myc_linear_to_lab(pt->lin[0], pt->lin[1], pt->lin[2]);
        pt->lab[0] = lab.L;
        pt->lab[1] = lab.a;
        pt->lab[2] = lab.b;
        pt->metal = g_bins[5 * k + 4] / count;
    }
    return n;
}

MycAlbedo* myc_albedo_read(MycFind* find, const MycAlbedoEntry* entry, MycArena* arena, char* why, size_t size,
    MycErr* err)
{
    MycAlbedoTables();
    MycPixels p;
    int got = myc_tex_open(find, entry->albedo, &p, err);
    if (got < 0) return NULL;
    if (got == 0) { snprintf(why, size, "albedo not found"); return NULL; }
    MycTexInfo info = p.info;
    if (!MycAlbedoBinMip(find, entry, &p, err)) return NULL;
    static MycPoint pts[BINS];
    int n = MycAlbedoPoints(pts);
    if (n == 0) { snprintf(why, size, "no opaque texel"); return NULL; }
    MycAlbedo* albedo = myc_alloc(arena, sizeof *albedo);
    if (albedo == NULL) { myc_fail(err, "out of memory"); return NULL; }
    albedo->format = info.format;
    albedo->width = info.width;
    albedo->height = info.height;
    albedo->mips = info.mips;
    albedo->total = info.layer_bytes;
    return MycAlbedoCluster(pts, n, albedo, err) ? albedo : NULL;
}
