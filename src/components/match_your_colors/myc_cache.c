/* Match Your Colors: the analyses of kits seen before, kept on disk (cache.lua), 1:1 in format: a later session
 * recolors as soon as the Helldiver appears instead of reading the game files again. One file, MatchYourColors.cache,
 * in the component's data folder (vpm_data_folder; the Lua kept it beside its log). Its first line names the format
 * version, the game build and the game data; any difference, or anything the parser does not expect, discards the
 * whole file. Then the shared tiler samples (S), and per kit and body: K, R, V, P, T, L (raw float32 LUTs), D, C, Z and
 * E lines. Written through a temporary file and a rename. Runs on the worker inside a job or the save. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "myc_pipeline.h"

#define NUMBER "%.17g"
#define LAYER_BYTES (512 * 4)

const char* myc_cache_pieces_sum(MycKit* kit)
{
    if (kit->pieces_sum[0] != 0) return kit->pieces_sum; /* made once per kit */
    uint32_t a = 1, b = 0;
    for (int i = 0; i < kit->npieces; i++)
    {
        const MycPiece* p = &kit->pieces[i];
        char text[1024];
        int n = snprintf(text, sizeof text, "%016llx,%u,%u,%u,%016llx,%u", (unsigned long long)p->path, p->slot, p->type,
            p->body, (unsigned long long)p->lut, p->tone);
        if (p->is_cape)
            n += snprintf(text + n, sizeof text - (size_t)n, ",%016llx,%016llx,%016llx,%016llx", (unsigned long long)p->fields,
                (unsigned long long)p->cape_lut, (unsigned long long)p->gradient, (unsigned long long)p->decal);
        myc_adler_text(text, &a, &b);
        if (p->overrides_text != NULL) { myc_adler_text(",", &a, &b); myc_adler_text(p->overrides_text, &a, &b); }
    }
    snprintf(kit->pieces_sum, sizeof kit->pieces_sum, "%08x", b * 65536 + a);
    return kit->pieces_sum;
}

void myc_cache_key(MycKit* kit, int body, char* out, size_t size)
{
    snprintf(out, size, "%08x:%d:%016llx:%s", kit->id, body, (unsigned long long)kit->archive, myc_cache_pieces_sum(kit));
}

void myc_cache_header(const char* data, char* out, size_t size)
{
    snprintf(out, size, "MYCCACHE %d %s %s %s", MYC_CACHE_VERSION, MYC_EXE_SHA256, MYC_GAME_SHA256, data);
}

/* ---- encoding ------------------------------------------------------------------------------------------------------ */

static void MycCacheRows(MycBuf* out, const MycAnalysis* a)
{
    for (int i = 0; i < a->nrows; i++)
    {
        const MycRow* r = &a->rows[i];
        myc_buf_printf(out, "R %s %016llx %d " NUMBER " " NUMBER " " NUMBER " " NUMBER " " NUMBER " %d %d " NUMBER " %d " NUMBER
            " " NUMBER " " NUMBER " " NUMBER "\n", r->key, (unsigned long long)r->lut, r->row, r->area, r->under, r->L, r->a,
            r->b, r->metal ? 1 : 0, r->camo ? 1 : 0, r->mode, r->full ? 1 : 0, r->ar, r->ag, r->ab, r->emissive);
    }
    for (int i = 0; i < a->nrows; i++)
    {
        const MycRow* r = &a->rows[i];
        if (r->finish_changed < 0) continue;
        MycVanilla v = r->has_vanilla ? r->vanilla : (MycVanilla){0, 0, 0, 0, 0, 0};
        myc_buf_printf(out, "V %s %d %d " NUMBER " " NUMBER " " NUMBER " " NUMBER " " NUMBER " " NUMBER "\n", r->key,
            r->finish_changed == 1, r->has_vanilla ? 1 : 0, v.L, v.a, v.b, v.ar, v.ag, v.ab);
    }
}

static int MycCacheChanged(const MycAnalysis* a)
{
    int n = 0;
    for (int i = 0; i < a->nrows; i++) n += a->rows[i].finish_changed >= 0;
    return n;
}

static int MycCacheZoneLines(const MycAnalysis* a)
{
    int n = 0;
    for (int z = 0; a->zones != NULL && z < 5; z++)
        for (int q = 0; q < 5; q++) n += a->zones->present[z][q];
    return n;
}

static void MycCacheBins(MycBuf* out, const uint32_t* bins)
{
    for (int k = 0; k < MYC_ZONE_BINS; k++) myc_buf_printf(out, "%s%u", k ? " " : "", bins[k]);
    myc_buf_add(out, "\n", 1);
}

static int MycCacheLutLess(const void* x, const void* y)
{
    uint64_t a = ((const MycNamedLut*)x)->name, b = ((const MycNamedLut*)y)->name;
    return a < b ? -1 : (a > b ? 1 : 0);
}

static void MycCacheTail(MycBuf* out, const MycAnalysis* a)
{
    for (int i = 0; i < a->ndeps; i++)
        myc_buf_printf(out, "D %016llx %016llx %016llx %s %s\n", (unsigned long long)a->deps[i].archive,
            (unsigned long long)a->deps[i].name, (unsigned long long)a->deps[i].kind, a->deps[i].hash,
            a->deps[i].ranges != NULL ? a->deps[i].ranges : "-");
    if (a->has_tint) myc_buf_printf(out, "C %016llx %016llx\n", (unsigned long long)a->tint_cape, (unsigned long long)a->tint_material);
    for (int z = 0; a->zones != NULL && z < 5; z++)
        for (int q = 0; q < 5; q++)
        {
            if (!a->zones->present[z][q]) continue;
            myc_buf_printf(out, "Z %d %d ", z, q);
            MycCacheBins(out, a->zones->counts[z][q]);
        }
    for (int i = 0; i < a->nemblems; i++)
    {
        const MycEmblem* e = &a->emblems[i];
        int r[4] = {-1, -1, -1, -1};
        if (e->has_rect) memcpy(r, e->rect, sizeof r);
        myc_buf_printf(out, "E %d %d " NUMBER " " NUMBER " " NUMBER " %d %d %d %d %d %016llx %u %u %u %u %d ", e->row, e->layer,
            e->L, e->a, e->b, e->cells, r[0], r[1], r[2], r[3], (unsigned long long)e->sheet, e->sheet_width, e->sheet_height,
            e->sheet_format, e->sheet_mips, e->around_row);
        MycCacheBins(out, e->counts);
    }
}

static void MycCacheEntry_(MycBuf* out, const char* key, const MycAnalysis* a)
{
    MycNamedLut* luts = malloc(sizeof(MycNamedLut) * (size_t)(a->nluts + 1));
    if (luts == NULL) { out->failed = 1; return; }
    memcpy(luts, a->luts, sizeof(MycNamedLut) * (size_t)a->nluts);
    qsort(luts, (size_t)a->nluts, sizeof luts[0], MycCacheLutLess);
    myc_buf_printf(out, "K %s %08x %s %016llx %d %d %d %d %d %d %d %d %d %d %d %d %.17g\n", key, a->kit->id,
        myc_kit_type_name(a->kit->type), (unsigned long long)a->kit->archive, a->body, a->nrows, a->npieces, a->nluts,
        a->npatterns, a->geometry_patched ? 1 : 0, MycCacheChanged(a), a->ndeps, a->has_tint ? 1 : 0, MycCacheZoneLines(a),
        a->emblem_layers, a->nemblems, a->weight);
    MycCacheRows(out, a);
    for (int i = 0; i < a->npieces; i++)
    {
        const MycAPiece* e = &a->pieces[i];
        myc_buf_printf(out, "P %u %u %u %d %d\n", e->piece.slot, e->piece.type, e->piece.body, e->skin ? 1 : 0, e->nmaterials);
    }
    for (int i = 0; i < a->npatterns; i++)
        myc_buf_printf(out, "T %016llx " NUMBER "\n", (unsigned long long)a->patterns[i].pattern, a->patterns[i].area);
    for (int i = 0; i < a->nluts; i++)
    {
        size_t size = (size_t)luts[i].lut->width * (size_t)luts[i].lut->height * 16;
        myc_buf_printf(out, "L %016llx %d %d %zu\n", (unsigned long long)luts[i].name, luts[i].lut->width, luts[i].lut->height, size);
        myc_buf_add(out, luts[i].lut->values, size);
    }
    free(luts);
    MycCacheTail(out, a);
}

static void MycCacheSamples(MycBuf* out, MycSamples* s)
{
    if (s->encoded == NULL)
    {
        size_t bytes = (size_t)(s->detail_layers + s->camo_layers) * LAYER_BYTES;
        char head[128];
        int n = snprintf(head, sizeof head, "S %016llx %d %d %zu\n", (unsigned long long)s->archive, s->detail_layers,
            s->camo_layers, bytes);
        uint8_t* block = malloc((size_t)n + bytes);
        if (block == NULL) { out->failed = 1; return; }
        memcpy(block, head, (size_t)n);
        size_t at = (size_t)n;
        for (int l = 0; l < s->detail_layers + s->camo_layers; l++)
        {
            const double* v = l < s->detail_layers ? s->detail[l] : s->camo[l - s->detail_layers];
            for (int i = 0; i < LAYER_BYTES; i++) block[at++] = (uint8_t)(v[i] * 255 + 0.5);
        }
        s->encoded = block;
        s->encoded_size = at;
    }
    myc_buf_add(out, s->encoded, s->encoded_size);
}

int myc_cache_encode(MycBuf* out, const char* header, const MycCacheEntry* entries, int n, MycSamples* samples)
{
    myc_buf_printf(out, "%s\n", header);
    if (samples != NULL) MycCacheSamples(out, samples);
    int written = 0;
    for (int i = 0; i < n && written < MYC_CACHE_MAX_ENTRIES; i++)
    {
        const MycAnalysis* a = entries[i].analysis;
        if (a == NULL || a->nalbedos > 0 || a->nunread > 0) continue;
        MycCacheEntry_(out, entries[i].key, a);
        written++;
    }
    return !out->failed;
}

/* ---- decoding ------------------------------------------------------------------------------------------------------ */

typedef struct MycCacheText { const uint8_t* text; size_t size, at; MycArena* arena; char why[96]; } MycCacheText;

#define MAX_FIELDS 32
/* The next line's fields (split on spaces) into fields, its count; -1 when the text ends without one. */
static int MycCacheLine(MycCacheText* t, char* line, size_t size, char** fields)
{
    size_t start = t->at, stop = start;
    while (stop < t->size && t->text[stop] != '\n') stop++;
    if (stop >= t->size || stop - start >= size) { snprintf(t->why, sizeof t->why, "cache: truncated"); return -1; }
    memcpy(line, t->text + start, stop - start);
    line[stop - start] = 0;
    t->at = stop + 1;
    int n = 0;
    for (char* p = strtok(line, " "); p != NULL && n < MAX_FIELDS; p = strtok(NULL, " ")) fields[n++] = p;
    return n;
}

static int MycCacheBad(MycCacheText* t, const char* what) { snprintf(t->why, sizeof t->why, "cache: %s", what); return 0; }
static double MycCacheNum(const char* text) { return strtod(text, NULL); }
static uint64_t MycCacheHex(const char* text) { return strtoull(text, NULL, 16); }

static int MycCacheDecodeRows(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[1024], *f[MAX_FIELDS];
    a->rows = myc_alloc(t->arena, sizeof(MycRow) * (size_t)(count + 1));
    if (a->rows == NULL) return MycCacheBad(t, "out of memory");
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 17 || strcmp(f[0], "R") != 0) return MycCacheBad(t, "bad row");
        MycRow* r = &a->rows[a->nrows++];
        snprintf(r->key, MYC_KEY, "%s", f[1]);
        r->lut = MycCacheHex(f[2]);
        r->row = atoi(f[3]);
        r->area = MycCacheNum(f[4]);
        r->under = MycCacheNum(f[5]);
        r->L = MycCacheNum(f[6]);
        r->a = MycCacheNum(f[7]);
        r->b = MycCacheNum(f[8]);
        r->metal = strcmp(f[9], "1") == 0;
        r->camo = strcmp(f[10], "1") == 0;
        r->mode = MycCacheNum(f[11]);
        r->full = strcmp(f[12], "1") == 0;
        r->ar = MycCacheNum(f[13]);
        r->ag = MycCacheNum(f[14]);
        r->ab = MycCacheNum(f[15]);
        r->emissive = MycCacheNum(f[16]);
        r->finish_changed = -1;
    }
    return 1;
}

static int MycCacheDecodeChanges(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[1024], *f[MAX_FIELDS];
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 10 || strcmp(f[0], "V") != 0) return MycCacheBad(t, "bad changed row");
        MycRow* row = NULL;
        for (int k = 0; k < a->nrows && row == NULL; k++)
            if (strcmp(a->rows[k].key, f[1]) == 0) row = &a->rows[k];
        if (row == NULL) return MycCacheBad(t, "bad changed row");
        row->finish_changed = strcmp(f[2], "1") == 0;
        row->has_vanilla = strcmp(f[3], "1") == 0;
        if (row->has_vanilla)
            row->vanilla = (MycVanilla){MycCacheNum(f[4]), MycCacheNum(f[5]), MycCacheNum(f[6]), MycCacheNum(f[7]),
                                        MycCacheNum(f[8]), MycCacheNum(f[9])};
    }
    return 1;
}

static int MycCacheDecodePieces(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[256], *f[MAX_FIELDS];
    a->pieces = myc_alloc(t->arena, sizeof(MycAPiece) * (size_t)(count + 1));
    if (a->pieces == NULL) return MycCacheBad(t, "out of memory");
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 6 || strcmp(f[0], "P") != 0) return MycCacheBad(t, "bad piece");
        MycAPiece* e = &a->pieces[a->npieces++];
        e->piece.slot = (uint32_t)atoi(f[1]);
        e->piece.type = (uint32_t)atoi(f[2]);
        e->piece.body = (uint32_t)atoi(f[3]);
        e->skin = strcmp(f[4], "1") == 0;
        e->nmaterials = atoi(f[5]);
        e->materials = myc_alloc(t->arena, sizeof(MycMaterial) * (size_t)(e->nmaterials + 1));
        if (e->materials == NULL) return MycCacheBad(t, "out of memory");
    }
    return 1;
}

static int MycCacheDecodePatterns(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[256], *f[MAX_FIELDS];
    a->patterns = myc_alloc(t->arena, sizeof(MycPatternArea) * (size_t)(count + 1));
    if (a->patterns == NULL) return MycCacheBad(t, "out of memory");
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 3 || strcmp(f[0], "T") != 0) return MycCacheBad(t, "bad pattern");
        a->patterns[a->npatterns++] = (MycPatternArea){MycCacheHex(f[1]), MycCacheNum(f[2])};
    }
    return 1;
}

static int MycCacheDecodeLuts(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[256], *f[MAX_FIELDS];
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 5 || strcmp(f[0], "L") != 0) return MycCacheBad(t, "bad LUT");
        int width = atoi(f[2]), height = atoi(f[3]);
        size_t size = (size_t)strtoull(f[4], NULL, 10);
        if (width <= 0 || height <= 0 || size != (size_t)width * (size_t)height * 16 || t->at + size > t->size)
            return MycCacheBad(t, "bad LUT size");
        MycLut* lut = myc_alloc(t->arena, sizeof(MycLut));
        float* values = myc_alloc(t->arena, size);
        if (lut == NULL || values == NULL) return MycCacheBad(t, "out of memory");
        memcpy(values, t->text + t->at, size);
        *lut = (MycLut){values, width, height};
        t->at += size;
        if (!myc_analysis_add_lut(t->arena, a, MycCacheHex(f[1]), lut)) return MycCacheBad(t, "out of memory");
    }
    return 1;
}

static int MycCacheDecodeDeps(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[2048], *f[MAX_FIELDS];
    a->deps = count > 0 ? myc_alloc(t->arena, sizeof(MycPatchDep) * (size_t)count) : NULL;
    if (count > 0 && a->deps == NULL) return MycCacheBad(t, "out of memory");
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 6 || strcmp(f[0], "D") != 0) return MycCacheBad(t, "bad patched resource");
        MycPatchDep* d = &a->deps[a->ndeps++];
        d->archive = MycCacheHex(f[1]);
        d->name = MycCacheHex(f[2]);
        d->kind = MycCacheHex(f[3]);
        snprintf(d->hash, sizeof d->hash, "%s", f[4]);
        d->ranges = myc_strdup(t->arena, f[5]);
        if (d->ranges == NULL) return MycCacheBad(t, "out of memory");
    }
    return 1;
}

static int MycCacheDecodeTints(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[256], *f[MAX_FIELDS];
    for (int i = 0; i < count; i++)
    {
        if (MycCacheLine(t, line, sizeof line, f) != 3 || strcmp(f[0], "C") != 0 || myc_analysis_lut(a, MycCacheHex(f[1])) == NULL)
            return MycCacheBad(t, "bad tint");
        a->has_tint = 1;
        a->tint_cape = MycCacheHex(f[1]);
        a->tint_material = MycCacheHex(f[2]);
    }
    return 1;
}

static int MycCacheCounts(char** f, int from, int n, uint32_t* out)
{
    for (int k = 0; k < MYC_ZONE_BINS; k++) out[k] = 0;
    for (int k = from; k < n && k - from < MYC_ZONE_BINS; k++) out[k - from] = (uint32_t)strtoul(f[k], NULL, 10);
    return 1;
}

static int MycCacheDecodeZones(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[256], *f[MAX_FIELDS];
    if (count == 0) return 1;
    a->zones = myc_alloc(t->arena, sizeof(MycZones));
    if (a->zones == NULL) return MycCacheBad(t, "out of memory");
    for (int i = 0; i < count; i++)
    {
        int n = MycCacheLine(t, line, sizeof line, f);
        if (n < 4 || strcmp(f[0], "Z") != 0) return MycCacheBad(t, "bad zone");
        int z = atoi(f[1]), q = atoi(f[2]);
        if (z < 0 || z >= 5 || q < 0 || q >= 5) return MycCacheBad(t, "bad zone");
        MycCacheCounts(f, 3, n, a->zones->counts[z][q]);
        a->zones->present[z][q] = 1;
    }
    return 1;
}

static int MycCacheDecodeEmblems(MycCacheText* t, MycAnalysis* a, int count)
{
    char line[512], *f[MAX_FIELDS];
    a->emblems = myc_alloc(t->arena, sizeof(MycEmblem) * (size_t)(count + 1));
    if (a->emblems == NULL) return MycCacheBad(t, "out of memory");
    for (int i = 0; i < count; i++)
    {
        int n = MycCacheLine(t, line, sizeof line, f);
        if (n < 18 || strcmp(f[0], "E") != 0) return MycCacheBad(t, "bad emblem");
        MycEmblem* e = &a->emblems[a->nemblems++];
        e->row = atoi(f[1]);
        e->layer = atoi(f[2]);
        e->L = MycCacheNum(f[3]);
        e->a = MycCacheNum(f[4]);
        e->b = MycCacheNum(f[5]);
        e->cells = atoi(f[6]);
        e->has_rect = atoi(f[7]) >= 0;
        for (int k = 0; k < 4 && e->has_rect; k++) e->rect[k] = atoi(f[7 + k]);
        e->sheet = MycCacheHex(f[11]);
        e->sheet_width = (uint32_t)atoi(f[12]);
        e->sheet_height = (uint32_t)atoi(f[13]);
        e->sheet_format = (uint32_t)atoi(f[14]);
        e->sheet_mips = (uint32_t)atoi(f[15]);
        e->around_row = atoi(f[16]);
        MycCacheCounts(f, 17, n, e->counts);
    }
    return 1;
}

static int MycCacheType(const char* name)
{
    if (strcmp(name, "Armor") == 0) return MYC_ARMOR;
    if (strcmp(name, "Helmet") == 0) return MYC_HELMET;
    if (strcmp(name, "Cape") == 0) return MYC_CAPE;
    return strcmp(name, "Weapon") == 0 ? MYC_WEAPON : -1;
}

/* One entry (decode_entry). */
static int MycCacheDecodeEntry(MycCacheText* t, MycCacheEntry* out)
{
    char line[512], *f[MAX_FIELDS];
    if (MycCacheLine(t, line, sizeof line, f) != 18 || strcmp(f[0], "K") != 0 || MycCacheType(f[3]) < 0) return MycCacheBad(t, "bad entry");
    MycAnalysis* a = myc_alloc(t->arena, sizeof(MycAnalysis));
    MycKit* kit = myc_alloc(t->arena, sizeof(MycKit));
    if (a == NULL || kit == NULL) return MycCacheBad(t, "out of memory");
    kit->id = (uint32_t)strtoul(f[2], NULL, 16);
    kit->type = MycCacheType(f[3]);
    kit->archive = MycCacheHex(f[4]);
    a->kit = kit;
    a->body = atoi(f[5]);
    a->cached = 1;
    a->geometry_patched = strcmp(f[10], "1") == 0;
    a->emblem_layers = atoi(f[15]);
    if (kit->type == MYC_CAPE) a->weight = MycCacheNum(f[17]);
    snprintf(out->key, sizeof out->key, "%s", f[1]);
    int rows = atoi(f[6]), pieces = atoi(f[7]), luts = atoi(f[8]), patterns = atoi(f[9]), changed = atoi(f[11]);
    int deps = atoi(f[12]), tints = atoi(f[13]), zones = atoi(f[14]), emblems = atoi(f[16]);
    out->analysis = a;
    return MycCacheDecodeRows(t, a, rows) && MycCacheDecodeChanges(t, a, changed) && MycCacheDecodePieces(t, a, pieces)
        && MycCacheDecodePatterns(t, a, patterns) && MycCacheDecodeLuts(t, a, luts) && MycCacheDecodeDeps(t, a, deps)
        && MycCacheDecodeTints(t, a, tints) && MycCacheDecodeZones(t, a, zones) && MycCacheDecodeEmblems(t, a, emblems);
}

static int MycCacheDecodeSamples(MycCacheText* t, MycSamples* s)
{
    char line[256], *f[MAX_FIELDS];
    size_t block = t->at;
    if (MycCacheLine(t, line, sizeof line, f) != 5) return MycCacheBad(t, "bad samples");
    int detail = atoi(f[2]), camo = atoi(f[3]);
    size_t size = (size_t)strtoull(f[4], NULL, 10);
    if (detail < 1 || camo < 1 || detail > MYC_MAX_LAYERS || camo > MYC_MAX_LAYERS
        || size != (size_t)(detail + camo) * LAYER_BYTES || t->at + size > t->size)
        return MycCacheBad(t, "bad samples size");
    memset(s, 0, sizeof *s);
    s->archive = MycCacheHex(f[1]);
    s->detail_layers = detail;
    s->camo_layers = camo;
    s->encoded_size = t->at + size - block;
    s->encoded = malloc(s->encoded_size);
    if (s->encoded == NULL) return MycCacheBad(t, "out of memory");
    memcpy(s->encoded, t->text + block, s->encoded_size);
    for (int l = 0; l < detail + camo; l++)
    {
        double* v = myc_alloc(t->arena, sizeof(double) * LAYER_BYTES);
        if (v == NULL) return MycCacheBad(t, "out of memory");
        for (int i = 0; i < LAYER_BYTES; i++) v[i] = t->text[t->at + i] / 255.0;
        t->at += LAYER_BYTES;
        if (l < detail) s->detail[l] = v;
        else s->camo[l - detail] = v;
    }
    return 1;
}

int myc_cache_decode(const uint8_t* text, size_t size, const char* header, MycArena* arena, MycCacheEntry** entries,
    int* n, MycSamples* samples, int* has_samples, char* why, size_t why_size)
{
    size_t h = strlen(header);
    *n = 0;
    *has_samples = 0;
    if (size < h + 1 || memcmp(text, header, h) != 0 || text[h] != '\n')
    {
        snprintf(why, why_size, "built for another version, game build or data");
        return 0;
    }
    MycCacheText t = {text, size, h + 1, arena, ""};
    int capacity = 16;
    *entries = myc_alloc(arena, sizeof(MycCacheEntry) * (size_t)capacity);
    int ok = *entries != NULL;
    if (ok && t.at + 1 < size && text[t.at] == 'S' && text[t.at + 1] == ' ') ok = *has_samples = MycCacheDecodeSamples(&t, samples);
    while (ok && t.at < size)
    {
        if (*n >= capacity)
        {
            MycCacheEntry* grown = myc_alloc(arena, sizeof(MycCacheEntry) * (size_t)capacity * 2);
            if (grown == NULL) { ok = MycCacheBad(&t, "out of memory"); break; }
            memcpy(grown, *entries, sizeof(MycCacheEntry) * (size_t)capacity);
            *entries = grown;
            capacity *= 2;
        }
        ok = MycCacheDecodeEntry(&t, &(*entries)[*n]);
        if (ok) (*n)++;
    }
    if (ok) return 1;
    snprintf(why, why_size, "%s", t.why);
    if (*has_samples) { free(samples->encoded); samples->encoded = NULL; *has_samples = 0; }
    *n = 0;
    return 0;
}

/* ---- the file ------------------------------------------------------------------------------------------------------ */

int myc_cache_read(const wchar_t* path, uint8_t** text, size_t* size)
{
    *text = NULL;
    *size = 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    LARGE_INTEGER length;
    int ok = GetFileSizeEx(f, &length) && length.QuadPart > 0 && length.QuadPart < (1ll << 30);
    uint8_t* data = ok ? malloc((size_t)length.QuadPart + 1) : NULL;
    DWORD got = 0;
    ok = data != NULL && ReadFile(f, data, (DWORD)length.QuadPart, &got, NULL) && got == (DWORD)length.QuadPart;
    CloseHandle(f);
    if (!ok) { free(data); return 0; }
    data[got] = 0;
    *text = data;
    *size = got;
    return 1;
}

int myc_cache_write(const wchar_t* path, const uint8_t* text, size_t size, char* why, size_t why_size)
{
    wchar_t temp[1100];
    _snwprintf(temp, sizeof temp / sizeof temp[0], L"%ls.tmp", path);
    temp[sizeof temp / sizeof temp[0] - 1] = 0;
    HANDLE f = CreateFileW(temp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) { snprintf(why, why_size, "cannot create the cache file (error %lu)", GetLastError()); return 0; }
    DWORD put = 0;
    int written = WriteFile(f, text, (DWORD)size, &put, NULL) && put == (DWORD)size;
    int closed = CloseHandle(f);
    if (!(written && closed))
    {
        snprintf(why, why_size, "cannot write the cache file (error %lu)", GetLastError());
        DeleteFileW(temp);
        return 0;
    }
    if (!MoveFileExW(temp, path, MOVEFILE_REPLACE_EXISTING))
    {
        snprintf(why, why_size, "cannot rename the cache file (error %lu)", GetLastError());
        DeleteFileW(temp);
        return 0;
    }
    return 1;
}
