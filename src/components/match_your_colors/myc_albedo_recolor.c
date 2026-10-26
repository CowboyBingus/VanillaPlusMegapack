/* Match Your Colors: a mod's albedo recolored (albedo.lua moves, move_endpoint, rewrite, spec, plan_specs), 1:1. Each
 * planned cluster's goal moves the texture's block endpoints: every distinct RGB565 endpoint is mapped once (memo) by
 * its closeness to the clusters (WEIGHT_DE), each cluster's lightness change as a part's in the matcher and its tint;
 * every block of every mip then takes the mapped endpoints with its indices kept, swapped where a BC1 block's endpoint
 * order flips so it keeps its mode. Runs on the worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_albedo.h"

#define WEIGHT_DE 4.0
#define NEUTRAL_C 5.0

static double myc_albedo_to_linear[256];
static int myc_albedo_to_linear_made;
static uint16_t myc_albedo_memo[65536];
static uint8_t myc_albedo_seen[65536];

typedef struct MycMove { double lab[3], goal[3], scale; int has_goal; } MycMove;

static void MycRecolorTables(void)
{
    if (myc_albedo_to_linear_made) return;
    for (int i = 0; i < 256; i++)
    {
        double c = i / 255.0;
        myc_albedo_to_linear[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    myc_albedo_to_linear_made = 1;
}

static int MycRecolorToByte(double linear)
{
    double c = myc_min(myc_max(linear, 0), 1);
    c = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055;
    return (int)floor(c * 255 + 0.5);
}

static uint16_t MycRecolorPack565(int r, int g, int b)
{
    int r5 = (int)floor(r * 31 / 255.0 + 0.5), g6 = (int)floor(g * 63 / 255.0 + 0.5), b5 = (int)floor(b * 31 / 255.0 + 0.5);
    return (uint16_t)(r5 * 2048 + g6 * 32 + b5);
}

static double MycRecolorLightness(double base, double x_L, double t_L)
{
    if (base >= t_L) return base + (x_L - t_L);
    double a[3], b[3], c[3];
    myc_lab_to_linear(base, 0, 0, a);
    myc_lab_to_linear(x_L, 0, 0, b);
    myc_lab_to_linear(t_L, 0, 0, c);
    double y = a[0] * b[0] / myc_max(c[0], 1e-9);
    return myc_linear_to_lab(y, y, y).L;
}

/* The cluster moves of a plan's goals (Albedo.moves). */
static void MycRecolorMoves(const MycAlbedo* albedo, const MycGoal* const* goals, MycMove* out)
{
    for (int k = 0; k < albedo->nclusters; k++)
    {
        const MycCluster* c = &albedo->clusters[k];
        const MycGoal* g = goals[k];
        MycMove* move = &out[k];
        memset(move, 0, sizeof *move);
        memcpy(move->lab, c->lab, sizeof move->lab);
        if (g == NULL) continue;
        MycLab u = myc_albedo_unlook(g->L, g->a, g->b);
        double gc = sqrt(u.a * u.a + u.b * u.b), cc = sqrt(c->lab[1] * c->lab[1] + c->lab[2] * c->lab[2]);
        move->goal[0] = u.L;
        move->goal[1] = u.a;
        move->goal[2] = u.b;
        move->has_goal = 1;
        move->scale = sqrt(g->a * g->a + g->b * g->b) < NEUTRAL_C ? 0 : (cc > 1 ? myc_min(1, gc / cc) : 1);
    }
}

/* An endpoint's new RGB565: its color moved by every cluster's move weighed by closeness. */
static uint16_t MycRecolorEndpoint(uint32_t e, const MycMove* moves, int n)
{
    uint32_t r5 = e >> 11, g6 = (e >> 5) & 63u, b5 = e & 31u;
    int r = (int)((r5 << 3) | (r5 >> 2)), g = (int)((g6 << 2) | (g6 >> 4)), b = (int)((b5 << 3) | (b5 >> 2));
    MycLab lab = myc_linear_to_lab(myc_albedo_to_linear[r], myc_albedo_to_linear[g], myc_albedo_to_linear[b]);
    double sw = 0, sL = 0, sa = 0, sb = 0, best[3] = {0, 0, 0}, bd = INFINITY;
    for (int i = 0; i < n; i++)
    {
        const MycMove* mv = &moves[i];
        double dL = lab.L - mv->lab[0], da = lab.a - mv->lab[1], db = lab.b - mv->lab[2];
        double d = dL * dL + da * da + db * db;
        double w = exp(-d / (2 * WEIGHT_DE * WEIGHT_DE));
        double tL = lab.L, ta = lab.a, tb = lab.b;
        if (mv->has_goal)
        {
            tL = MycRecolorLightness(mv->goal[0], lab.L, mv->lab[0]);
            ta = mv->goal[1] + (lab.a - mv->lab[1]) * mv->scale;
            tb = mv->goal[2] + (lab.b - mv->lab[2]) * mv->scale;
        }
        sw = sw + w;
        sL = sL + w * tL;
        sa = sa + w * ta;
        sb = sb + w * tb;
        if (d < bd) { best[0] = tL; best[1] = ta; best[2] = tb; bd = d; }
    }
    if (sw < 1e-12) { sL = best[0]; sa = best[1]; sb = best[2]; sw = 1; }
    double lin[3];
    myc_lab_to_linear(sL / sw, sa / sw, sb / sw, lin);
    return MycRecolorPack565(MycRecolorToByte(lin[0]), MycRecolorToByte(lin[1]), MycRecolorToByte(lin[2]));
}

static uint16_t MycRecolorMapped(uint16_t e, const MycMove* moves, int n)
{
    if (!myc_albedo_seen[e]) { myc_albedo_memo[e] = MycRecolorEndpoint(e, moves, n); myc_albedo_seen[e] = 1; }
    return myc_albedo_memo[e];
}

static uint32_t MycRecolorLoad32(const uint8_t* p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void MycRecolorStore32(uint8_t* p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

/* A BC1 block's new endpoints in the order that keeps its mode, its indices remapped when they swap (bc1_order). */
static void MycRecolorBc1Order(uint8_t* indices, uint16_t c0, uint16_t c1, uint16_t* n0, uint16_t* n1)
{
    uint16_t a = *n0, b = *n1;
    uint32_t idx = MycRecolorLoad32(indices);
    if (c0 > c1)
    {
        if (a < b) { MycRecolorStore32(indices, idx ^ 0x55555555u); *n0 = b; *n1 = a; return; }
        if (a == b) MycRecolorStore32(indices, 0);
        return;
    }
    if (a > b)
    {
        MycRecolorStore32(indices, idx ^ (~(idx >> 1) & 0x55555555u));
        *n0 = b;
        *n1 = a;
    }
}

/* Every block of a BC1 (step 8) or BC3 (step 16, color at +8) mip chain rewritten with the mapped endpoints. */
static void MycRecolorRewrite(uint8_t* data, size_t blocks, size_t step, const MycMove* moves, int n)
{
    size_t co = step == 16 ? 8 : 0;
    for (size_t i = 0; i < blocks; i++)
    {
        uint8_t* p = data + i * step + co;
        uint16_t c0 = (uint16_t)(p[0] | p[1] << 8), c1 = (uint16_t)(p[2] | p[3] << 8);
        uint16_t n0 = MycRecolorMapped(c0, moves, n), n1 = MycRecolorMapped(c1, moves, n);
        if (step == 8) MycRecolorBc1Order(p + 4, c0, c1, &n0, &n1);
        p[0] = (uint8_t)n0;
        p[1] = (uint8_t)(n0 >> 8);
        p[2] = (uint8_t)n1;
        p[3] = (uint8_t)(n1 >> 8);
    }
}

/* The recolored albedo for goals in spec (its data the whole mip chain, a fresh copy), in place (Albedo.spec). */
static void MycRecolorSpec(uint64_t name, const MycAlbedo* albedo, const MycGoal* const* goals, MycSpec* spec)
{
    MycMove moves[8];
    MycRecolorTables();
    memset(myc_albedo_seen, 0, sizeof myc_albedo_seen);
    MycRecolorMoves(albedo, goals, moves);
    int bc1 = albedo->format == MYC_FMT_BC1 || albedo->format == MYC_FMT_BC1_SRGB;
    size_t step = bc1 ? 8 : 16;
    MycRecolorRewrite(spec->data, (size_t)albedo->total / step, step, moves, albedo->nclusters);
    spec->kind = MYC_SPEC_ALBEDO;
    spec->bc1 = bc1;
    spec->name = name;
    spec->width = (int)albedo->width;
    spec->height = (int)albedo->height;
    spec->mips = (int)albedo->mips;
    spec->size = (size_t)albedo->total;
    spec->format = (int)albedo->format;
}

static int MycRecolorLineLess(const void* x, const void* y) { return strcmp(*(const char* const*)x, *(const char* const*)y); }

/* What plan_specs works with: the plan of a target, the specs it adds to, the chain read and its errors. */
typedef struct MycAlbedoJob
{
    MycArena* arena;
    const MycAnalysis* target;
    const MycPlan* plan;
    MycSpecs* out;
    const MycAlbedoSource* source;
    MycErr* err;
} MycAlbedoJob;

/* An albedo's recolored copy into the specs (the chain read again: it must be the texture analysed). */
static int MycRecolorAlbedoCopy(const MycAlbedoJob* job, const MycNamedAlbedo* a, const MycGoal* const* goals)
{
    MycTexInfo info;
    MycErr* err = job->err;
    MycSpec* spec = job->source->chain(job->source->ctx, a->name, job->target->kit->archive, &info, err);
    if (spec == NULL && err->failed) return 0;
    if (spec == NULL || info.format != a->albedo->format || info.layer_bytes != a->albedo->total)
    {
        myc_spec_drop(spec);
        return myc_fail(err, "mod texture %016llx is not the texture analysed", (unsigned long long)a->name);
    }
    MycRecolorSpec(a->name, a->albedo, goals, spec);
    return myc_specs_put(job->arena, job->out, a->name, spec) || myc_fail(err, "out of memory (albedo)");
}

/* One albedo's goals, count and the log's shares; then its recolored copy into the specs. */
static int MycRecolorAlbedo(const MycAlbedoJob* job, const MycNamedAlbedo* a, char** line)
{
    const MycAlbedo* albedo = a->albedo;
    const MycGoal* goals[8];
    char shares[8 * 24] = "", key[MYC_KEY];
    int count = 0;
    size_t at = 0;
    for (int k = 0; k < albedo->nclusters; k++)
    {
        myc_row_key(key, a->name, k);
        goals[k] = myc_plan_get(job->plan, key);
        count += goals[k] != NULL;
        const MycCluster* c = &albedo->clusters[k];
        at += (size_t)snprintf(shares + at, sizeof shares - at, "%s%.0f%%%s", k ? ", " : "", 100 * c->share,
            c->metal > 0.5 ? " metal" : "");
    }
    if (count > 0 && !MycRecolorAlbedoCopy(job, a, goals)) return 0;
    char text[512];
    snprintf(text, sizeof text, "Mod texture %016llx (a material without a color table): %d colors read (%s); %d recolored.",
        (unsigned long long)a->name, albedo->nclusters, shares, count);
    *line = myc_strdup(job->arena, text);
    return *line != NULL || myc_fail(job->err, "out of memory");
}

/* The lines sorted and joined into the report (in the arena), or NULL when there are none. */
static int MycAlbedoReport(MycArena* arena, char** lines, int n, char** report, MycErr* err)
{
    static char text[2048];
    *report = NULL;
    if (n == 0) return 1;
    qsort(lines, (size_t)n, sizeof lines[0], MycRecolorLineLess);
    size_t at = 0;
    text[0] = 0;
    for (int i = 0; i < n && at < sizeof text; i++) at += (size_t)snprintf(text + at, sizeof text - at, "%s%s", i ? " " : "", lines[i]);
    *report = myc_strdup(arena, text);
    return *report != NULL || myc_fail(err, "out of memory");
}

int myc_albedo_plan_specs(MycArena* arena, const MycAnalysis* target, const MycPlan* plan, MycSpecs* out,
    const MycAlbedoSource* source, char** report, MycErr* err)
{
    char** lines = myc_alloc(arena, sizeof(char*) * (size_t)(target->nunread + target->nalbedos + 1));
    if (lines == NULL) return myc_fail(err, "out of memory");
    int n = 0;
    *report = NULL;
    for (int i = 0; i < target->nunread; i++)
    {
        const MycUnread* u = &target->unread[i];
        char text[512];
        snprintf(text, sizeof text, "Mod material %016llx (from %s) has no color table and is left as it is: %s.",
            (unsigned long long)u->material, u->file[0] ? u->file : "nil", u->why);
        if ((lines[n++] = myc_strdup(arena, text)) == NULL) return myc_fail(err, "out of memory");
    }
    MycAlbedoJob job = {arena, target, plan, out, source, err};
    for (int i = 0; i < target->nalbedos; i++)
        if (target->albedos[i].albedo != NULL && !MycRecolorAlbedo(&job, &target->albedos[i], &lines[n++])) return 0;
    return MycAlbedoReport(arena, lines, n, report, err);
}
