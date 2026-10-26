/* Match Your Colors: the session's pipeline (recolor.lua pipeline), 1:1: the shared samples, color model, texture
 * caches, analyses, plans and the kit catalogue, kept for the session; the index of the installed mods' patches (read
 * once); the disk cache of analyses and shared samples. The game-data reader and its buffers exist only while a job
 * reads game files (open .. close). Runs on the worker thread inside jobs. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_pipeline.h"

/* ---- construction ------------------------------------------------------------------------------------------------- */

static int MycPipePatches(MycPipeline* p, MycErr* err)
{
    if (p->patches_indexed) return 1;
    const char* was = p->stage;
    p->stage = "indexing mods' patches";
    MycFiles files;
    myc_files_init(&files, p->data_folder);
    p->patch_index = myc_patches_index(&files, &p->arena, err);
    myc_files_close_all(&files);
    p->stage = was;
    if (err->failed) return 0;
    p->patches_indexed = 1;
    if (p->patch_index != NULL)
    {
        int entries, skipped, count = myc_patches_count(p->patch_index, &entries, &skipped);
        snprintf(p->patch_status, sizeof p->patch_status, "%d patch files hold %d textures, materials or units the mod "
            "reads (%d unreadable)", count, entries, skipped);
    }
    return 1;
}

/* The slim index's chunk count and size and the signature of the installed mods' patches. */
static int MycPipeSignature(MycPipeline* p, char* out, size_t size, MycErr* err)
{
    MycFiles files;
    uint8_t head[32];
    myc_files_init(&files, p->data_folder);
    int handle = myc_files_open(&files, "bundles.nxa", err);
    int ok = handle >= 0 && myc_files_read(&files, handle, 0, 32, head, err);
    myc_files_close_all(&files);
    if (!ok || !MycPipePatches(p, err)) return 0;
    uint32_t chunks = head[8] | head[9] << 8 | head[10] << 16 | (uint32_t)head[11] << 24;
    uint64_t low = head[16] | head[17] << 8 | head[18] << 16 | (uint64_t)head[19] << 24;
    uint64_t high = head[20] | head[21] << 8 | head[22] << 16 | (uint64_t)head[23] << 24;
    snprintf(out, size, "%u:%.0f:%s", chunks, (double)low + (double)high * 4294967296.0,
        p->patch_index != NULL ? myc_patches_signature(p->patch_index) : "none");
    return 1;
}

/* The cache file read and decoded: its entries, their order and the samples, or why it is not used. */
static int MycPipeCache(MycPipeline* p, MycErr* err)
{
    char data[256];
    p->stage = "game data signature";
    if (!MycPipeSignature(p, data, sizeof data, err)) return 0;
    myc_cache_header(data, p->header, sizeof p->header);
    p->has_header = 1;
    p->stage = "reading the analysis cache";
    uint8_t* text;
    size_t size;
    if (!myc_cache_read(p->cache_path, &text, &size)) { snprintf(p->cache_status, sizeof p->cache_status, "none yet"); return 1; }
    p->stage = "decoding the analysis cache";
    char why[128];
    MycCacheDecoded decoded = {NULL, 0, &p->samples, 0};
    if (myc_cache_decode(text, size, p->header, &p->arena, &decoded, why, sizeof why))
    {
        int n = decoded.n;
        p->cached = decoded.entries;
        p->has_samples = decoded.has_samples;
        p->ncached = n;
        p->order = malloc(sizeof *p->order * (size_t)(n + 16));
        p->order_capacity = p->order != NULL ? n + 16 : 0;
        for (int i = 0; i < n && p->order != NULL; i++) memcpy(p->order[p->norder++], p->cached[i].key, MYC_ENTRY_KEY);
        snprintf(p->cache_status, sizeof p->cache_status, "%d kit analyses loaded", n);
    }
    else snprintf(p->cache_status, sizeof p->cache_status, "not used (%s)", why);
    free(text);
    return 1;
}

MycPipeline* myc_pipeline_new(const wchar_t* data_folder, const wchar_t* cache_path, MycErr* err)
{
    MycPipeline* p = calloc(1, sizeof *p);
    if (p == NULL) { myc_fail(err, "out of memory (pipeline)"); return NULL; }
    p->kits = myc_catalogue_new();
    if (p->kits == NULL) { free(p); myc_fail(err, "out of memory (catalogue)"); return NULL; }
    wcsncpy(p->data_folder, data_folder, sizeof p->data_folder / sizeof p->data_folder[0] - 1);
    p->textures.arena = &p->arena;
    if (cache_path != NULL)
    {
        wcsncpy(p->cache_path, cache_path, sizeof p->cache_path / sizeof p->cache_path[0] - 1);
        p->has_cache = 1;
        if (!MycPipeCache(p, err)) { myc_pipeline_free(p); return NULL; }
    }
    return p;
}

void myc_pipeline_free(MycPipeline* p)
{
    if (p == NULL) return;
    myc_pipeline_close(p);
    for (int i = 0; i < p->nplans; i++) myc_made_free(p->plans[i]);
    myc_spec_drop(p->kept_sheet_data);
    free(p->samples.encoded);
    free(p->order);
    free(p->catalogue_buffer);
    free(p->compose_buffer);
    myc_catalogue_free(p->kits);
    myc_arena_free(&p->arena);
    free(p);
}

/* ---- the reader --------------------------------------------------------------------------------------------------- */

int myc_pipeline_model(MycPipeline* p, MycErr* err)
{
    if (!p->has_samples && !myc_pipeline_open(p, err)) return 0;
    if (p->model != NULL) return 1;
    p->model = myc_alloc(&p->arena, sizeof(MycModel));
    if (p->model == NULL) return myc_fail(err, "out of memory (color model)");
    myc_model_init(p->model, (const double* const*)p->samples.detail, p->samples.detail_layers,
        (const double* const*)p->samples.camo, p->samples.camo_layers);
    p->transfer = myc_transfer_new(&p->arena, p->model);
    return p->transfer != NULL || myc_fail(err, "out of memory (transfer)");
}

int myc_pipeline_open(MycPipeline* p, MycErr* err)
{
    if (p->open) return 1;
    myc_files_init(&p->files, p->data_folder);
    MycSlim* slim = myc_slim_open(&p->files, err);
    if (slim == NULL) { myc_files_close_all(&p->files); return 0; }
    if (!MycPipePatches(p, err)) { myc_slim_close(slim); myc_files_close_all(&p->files); return 0; }
    myc_reader_init(&p->reader, slim, p->patch_index, &p->files);
    p->open = 1;
    p->find.reader = &p->reader;
    if (!p->has_samples)
    {
        int found = myc_kits_shared_samples(&p->reader, &p->arena, &p->samples, err);
        if (found < 0) return 0;
        if (found == 0) return myc_fail(err, "shared customization archive not found");
        p->has_samples = 1;
        p->dirty = 1;
    }
    return myc_pipeline_model(p, err);
}

void myc_pipeline_close(MycPipeline* p)
{
    if (!p->open) return;
    p->reads += p->files.reads;
    p->bytes += p->files.bytes;
    if (p->files.longest > p->longest) { p->longest = p->files.longest; p->longest_size = p->files.longest_size; }
    myc_reader_close(&p->reader);
    myc_files_close_all(&p->files);
    free(p->files.handles);
    memset(&p->files, 0, sizeof p->files);
    myc_scratch_free();
    p->open = 0;
    p->find.reader = NULL;
}

void myc_pipeline_find_in(MycPipeline* p, uint64_t archive, const uint64_t* extra, int nextra)
{
    p->find.reader = &p->reader;
    p->find.count = 0;
    p->find.archives[p->find.count++] = archive;
    p->find.archives[p->find.count++] = p->samples.archive;
    for (int i = 0; i < nextra && p->find.count < 12; i++)
        if (extra[i] != 0) p->find.archives[p->find.count++] = extra[i];
}

const MycLut* myc_pipeline_scheme_lut(MycPipeline* p, const MycScheme* scheme, MycErr* err)
{
    for (int i = 0; i < p->nschemes; i++)
        if (p->schemes[i].name == scheme->lut) return p->schemes[i].lut;
    if (!myc_pipeline_open(p, err)) return NULL;
    myc_pipeline_find_in(p, scheme->archive, NULL, 0);
    MycLut* lut = myc_textures_lut(&p->textures, &p->find, scheme->lut, err);
    if (err->failed) return NULL;
    if (lut == NULL) { myc_fail(err, "paint scheme %s not in the game data", scheme->id); return NULL; }
    size_t count = (size_t)lut->width * (size_t)lut->height * 4;
    MycLut* copy = myc_alloc(&p->arena, sizeof(MycLut));
    float* values = myc_alloc(&p->arena, count * sizeof(float));
    if (copy == NULL || values == NULL) { myc_fail(err, "out of memory (scheme LUT)"); return NULL; }
    memcpy(values, lut->values, count * sizeof(float));
    for (int r = 0; r < lut->height; r++)
        for (int i = 27; i <= 31; i++) values[(size_t)r * (size_t)lut->width * 4 + (size_t)i] = 0;
    *copy = (MycLut){values, lut->width, lut->height};
    if (p->nschemes < MYC_SCHEMES) p->schemes[p->nschemes++] = (MycNamedLut){scheme->lut, copy};
    return copy;
}

MycSpec* myc_pipeline_chain(MycPipeline* p, uint64_t name, uint64_t archive, MycTexInfo* info, MycErr* err)
{
    if (!myc_pipeline_open(p, err)) return NULL;
    myc_pipeline_find_in(p, archive, NULL, 0);
    MycPixels px;
    int found = myc_tex_open(&p->find, name, &px, err);
    if (found <= 0) return NULL;
    *info = px.info;
    MycSpec* spec = myc_spec_new(MYC_SPEC_ALBEDO, (int)px.info.width, (int)px.info.height, (size_t)px.info.layer_bytes);
    if (spec == NULL) { myc_fail(err, "no memory for a %llu-byte texture", (unsigned long long)px.info.layer_bytes); return NULL; }
    if (!myc_pixels_read(&px, 0, (uint32_t)px.info.layer_bytes, spec->data, err)) { myc_spec_drop(spec); return NULL; }
    return spec;
}

/* ---- analyses ----------------------------------------------------------------------------------------------------- */

static void MycPipeTouch(MycPipeline* p, const char* key)
{
    int at = -1;
    for (int i = 0; i < p->norder && at < 0; i++)
        if (strcmp(p->order[i], key) == 0) at = i;
    if (at < 0)
    {
        if (p->norder >= p->order_capacity)
        {
            int capacity = p->order_capacity < 64 ? 64 : p->order_capacity * 2;
            void* grown = realloc(p->order, sizeof *p->order * (size_t)capacity);
            if (grown == NULL) return;
            p->order = grown;
            p->order_capacity = capacity;
        }
        at = p->norder++;
    }
    memmove(p->order[1], p->order[0], sizeof *p->order * (size_t)at);
    snprintf(p->order[0], MYC_ENTRY_KEY, "%s", key);
}

/* The archived (unpatched) LUT name in the searched archives, or NULL (pipeline original_lut). */
static MycLut* MycPipeOriginal(void* ctx, uint64_t name)
{
    MycPipeline* p = ctx;
    MycReader base;
    memset(&base, 0, sizeof base);
    base.slim = p->reader.slim;
    MycLut* out = NULL;
    for (int i = 0; i < p->find.count && out == NULL; i++)
    {
        MycErr err = {0};
        const MycRecord* record = myc_slim_locate(base.slim, p->find.archives[i], name, MYC_TYPE_TEXTURE, &err);
        if (record == NULL) continue;
        uint8_t* main = myc_scratch(MYC_SCRATCH_MAIN, record->size[MYC_MAIN]);
        MycTexInfo info;
        MycPixels px;
        out = myc_alloc(&p->arena, sizeof(MycLut));
        int ok = out != NULL && main != NULL && myc_reader_part(&base, record, MYC_MAIN, 0, record->size[MYC_MAIN], main, &err)
            && myc_tex_describe(main, record->size[MYC_MAIN], &info, &err) && myc_pixels_init(&px, &base, record, &info, &err)
            && myc_tex_lut(&px, &p->arena, out, &err);
        if (!ok) out = NULL;
        break;
    }
    myc_arena_free(&base.arena);
    return out;
}

static int MycPipeDepLess(const void* x, const void* y)
{
    const MycPatchDep* a = x;
    const MycPatchDep* b = y;
    if (a->archive != b->archive) return a->archive < b->archive ? -1 : 1;
    if (a->name != b->name) return a->name < b->name ? -1 : 1;
    return a->kind < b->kind ? -1 : (a->kind > b->kind ? 1 : 0);
}

/* What a new analysis read from mods' patches: its marks and, per patched resource, its ranges and their hash. */
static int MycPipeAfter(MycPipeline* p, MycAnalysis* made, MycErr* err)
{
    MycReader* r = &p->reader;
    int n = r->noted_count;
    if (made == NULL || n == 0) { myc_reader_note(r, 0); return 1; }
    if (made->kit->type != MYC_CAPE) myc_kits_mark_patched(made, r->noted, n, MycPipeOriginal, p, p->model);
    made->deps = myc_alloc(&p->arena, sizeof(MycPatchDep) * (size_t)n);
    if (made->deps == NULL) { myc_reader_note(r, 0); return myc_fail(err, "out of memory (patched resources)"); }
    for (int i = 0; i < n && !err->failed; i++)
    {
        const MycNoted* t = &r->noted[i];
        MycPatchDep* d = &made->deps[made->ndeps++];
        char ranges[1024];
        d->archive = t->archive;
        d->name = t->name;
        d->kind = t->type;
        myc_ranges_text(&t->ranges, ranges, sizeof ranges);
        d->ranges = myc_strdup(&p->arena, ranges);
        myc_patches_content_hash(&p->files, p->patch_index, t->record, &t->ranges, d->hash, sizeof d->hash, err);
    }
    qsort(made->deps, (size_t)made->ndeps, sizeof made->deps[0], MycPipeDepLess);
    myc_reader_note(r, 0);
    return !err->failed;
}

static MycAnalysis* MycPipeNew(MycPipeline* p, MycKit* kit, int body, MycErr* err)
{
    p->stage = "opening the game data";
    if (!myc_pipeline_open(p, err)) return NULL;
    static char stage[48];
    snprintf(stage, sizeof stage, "analysing kit %08x", kit->id);
    p->stage = stage;
    myc_reader_note(&p->reader, 1);
    myc_pipeline_find_in(p, kit->archive, kit->extra, kit->nextra);
    MycKitDeps deps = {&p->find, &p->textures, p->model, &p->arena, NULL};
    MycAnalysis* made;
    if (kit->type == MYC_CAPE)
    {
        char why[128];
        made = myc_capes_analyse(kit, body, &deps, why, sizeof why, err);
    }
    else made = myc_kits_analyse(kit, body, &deps, err);
    if (err->failed) { myc_reader_note(&p->reader, 0); return NULL; }
    return MycPipeAfter(p, made, err) ? made : NULL;
}

/* Whether a cached analysis still holds: the bytes it read of every patched resource are the same now. */
static int MycPipeCurrent(MycPipeline* p, const char* key, const MycAnalysis* a, MycErr* err)
{
    if (a->ndeps == 0) return 1;
    void* known = myc_smap_get(&p->checked, key);
    if (known != NULL) return known != MYC_MISSING;
    if (!MycPipePatches(p, err)) return 0;
    MycFiles files;
    myc_files_init(&files, p->data_folder);
    int ok = p->patch_index != NULL;
    for (int i = 0; ok && i < a->ndeps; i++)
    {
        const MycPatchDep* d = &a->deps[i];
        MycRecord record;
        MycRanges ranges;
        char hash[32];
        MycErr local = {0};
        memset(&ranges, 0, sizeof ranges);
        ok = myc_patches_record(p->patch_index, d->archive, d->name, d->kind, &record) && myc_ranges_parse(d->ranges, &ranges)
            && myc_patches_content_hash(&files, p->patch_index, &record, &ranges, hash, sizeof hash, &local)
            && strcmp(hash, d->hash) == 0;
        myc_ranges_free(&ranges);
    }
    myc_files_close_all(&files);
    free(files.handles);
    (void)myc_smap_put(&p->arena, &p->checked, key, ok ? (void*)a : MYC_MISSING);
    return ok;
}

static MycAnalysis* MycPipeCached(MycPipeline* p, const char* key)
{
    for (int i = 0; i < p->ncached; i++)
        if (strcmp(p->cached[i].key, key) == 0) return p->cached[i].analysis;
    return NULL;
}

/* The analysis of a key not known this session yet: the cache's while it holds, else a new one (one that cannot be
 * made: MYC_MISSING, kept as that); NULL after myc_fail. */
static void* MycPipeLearn(MycPipeline* p, MycKit* kit, int body, const char* key, MycErr* err)
{
    MycAnalysis* cached = kit->type != MYC_WEAPON ? MycPipeCached(p, key) : NULL;
    MycAnalysis* made = cached != NULL && MycPipeCurrent(p, key, cached, err) ? cached : NULL;
    if (err->failed) return NULL;
    if (made == NULL)
    {
        made = MycPipeNew(p, kit, body, err);
        if (err->failed) return NULL;
        if (made != NULL && kit->type != MYC_WEAPON) p->dirty = 1;
    }
    void* known = made != NULL ? (void*)made : MYC_MISSING;
    if (!myc_smap_put(&p->arena, &p->analyses, key, known))
    {
        myc_fail(err, "out of memory (analyses)");
        return NULL;
    }
    return known;
}

MycAnalysis* myc_pipeline_analysis(MycPipeline* p, MycKit* kit, int body, MycErr* err)
{
    char key[MYC_ENTRY_KEY];
    myc_cache_key(kit, body, key, sizeof key);
    void* known = myc_smap_get(&p->analyses, key);
    if (known == NULL) known = MycPipeLearn(p, kit, body, key, err);
    if (known == NULL || known == MYC_MISSING) return NULL;
    MycPipeTouch(p, key);
    return known;
}

int myc_pipeline_save(MycPipeline* p, char* why, size_t size)
{
    if (!p->dirty || !p->has_header) return 1;
    MycCacheEntry* entries = malloc(sizeof(MycCacheEntry) * (size_t)(p->norder + 1));
    if (entries == NULL) { snprintf(why, size, "out of memory"); return 0; }
    int n = 0;
    for (int i = 0; i < p->norder; i++)
    {
        void* a = myc_smap_get(&p->analyses, p->order[i]);
        MycAnalysis* analysis = a != NULL && a != MYC_MISSING ? a : MycPipeCached(p, p->order[i]);
        if (analysis == NULL || analysis->kit->type == MYC_WEAPON) continue;
        memcpy(entries[n].key, p->order[i], MYC_ENTRY_KEY);
        entries[n++].analysis = analysis;
    }
    p->dirty = 0;
    MycBuf text = {0};
    int ok = myc_cache_encode(&text, p->header, entries, n, p->has_samples ? &p->samples : NULL);
    free(entries);
    if (!ok) { myc_buf_free(&text); snprintf(why, size, "out of memory"); return 0; }
    ok = myc_cache_write(p->cache_path, (const uint8_t*)text.data, text.size, why, size);
    myc_buf_free(&text);
    return ok;
}

/* ---- plans kept --------------------------------------------------------------------------------------------------- */

MycMade* myc_made_new(const char* key)
{
    MycMade* made = calloc(1, sizeof *made);
    if (made != NULL) snprintf(made->key, sizeof made->key, "%s", key);
    return made;
}

void myc_made_free(MycMade* made)
{
    if (made == NULL) return;
    myc_specs_drop(&made->luts);
    myc_specs_drop(&made->patterns);
    myc_arena_free(&made->arena);
    free(made);
}

MycMade* myc_pipeline_plan(MycPipeline* p, const char* key)
{
    for (int i = 0; i < p->nplans; i++)
        if (strcmp(p->plans[i]->key, key) == 0)
        {
            MycMade* made = p->plans[i];
            memmove(&p->plans[i], &p->plans[i + 1], sizeof p->plans[0] * (size_t)(p->nplans - i - 1));
            p->plans[p->nplans - 1] = made;
            return made;
        }
    return NULL;
}

void myc_pipeline_keep(MycPipeline* p, MycMade* made)
{
    if (p->nplans >= MYC_PLANS_KEPT)
    {
        myc_made_free(p->plans[0]);
        memmove(&p->plans[0], &p->plans[1], sizeof p->plans[0] * (size_t)(p->nplans - 1));
        p->nplans--;
    }
    p->plans[p->nplans++] = made;
}
