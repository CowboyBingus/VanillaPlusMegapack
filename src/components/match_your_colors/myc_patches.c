/* Match Your Colors: mods' loose patch files, read with the priority the game gives them, over the slim data
 * (patches.lua), and the job's reader (Patches.over), 1:1. Mod managers install every mod as patches of the boot archive
 * 9ba626afa44a3aa3: data/9ba626afa44a3aa3.patch_0, _1, ..., each a classic archive file (its table of contents at offset
 * 0) with its stream and GPU parts beside it as .stream and .gpu_resources. A texture, material or unit a patch holds
 * replaces the archived one of the same name and type; between patches the higher number wins. The index is made once
 * per session inside the first job (worker thread). Its signature is a checksum of every indexed entry, so the
 * analysis cache starts over when the installed mods change what they hold; each analysis also carries a content hash
 * of the byte ranges it read from patched resources. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_io.h"

#define TOC_HEADER 72u
#define TOC_TYPE 32u
#define TOC_FILE 80u
#define TOC_MAGIC 0xF0000011u
#define MAX_ENTRIES 262144u
#define UNINDEXED (-2)
#define CHUNK 262144u

static const uint64_t kMycWanted[3] = {0xcd4238c6a0c69e32ull, 0xeac0b497876adedfull, 0xe0a48d0be9a7453full};
static const char* const kMycParts[3] = {"main", "stream", "gpu"};
static const char* const kMycSuffix[3] = {"", ".stream", ".gpu_resources"};

static uint32_t MycPatchU32(const uint8_t* p, uint64_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }

typedef struct MycPatch
{
    char* file;
    uint64_t archive;
    uint32_t number;
    char archive_hex[17];
    uint8_t* raw;
    uint64_t base;
    uint32_t count, indexed;
    MycMap heads;
    int32_t* nexts;
} MycPatch;

struct MycPatchIndex
{
    MycPatch** patches;
    int count, entries, skipped;
    char signature[64];
};

/* ---- order ---------------------------------------------------------------------------------------------------------- */

static int MycPatchHex(const char* name, char archive[17])
{
    for (int i = 0; i < 16; i++)
    {
        char c = name[i];
        int digit = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        int upper = c >= 'A' && c <= 'F';
        if (!digit && !upper) return 0;
        archive[i] = (char)(upper ? c - 'A' + 'a' : c);
    }
    archive[16] = 0;
    return 1;
}

/* A patch file name '<16 hex>.patch_<1-6 digits>' into its archive (lowercase) and number; 0 for any other name. */
static int MycPatchParse(const char* name, char archive[17], uint32_t* number)
{
    size_t n = strlen(name);
    const char* dot = strstr(name, ".patch_");
    if (dot == NULL || dot - name != 16 || n < 24 || n > 29 || !MycPatchHex(name, archive)) return 0;
    uint32_t value = 0;
    for (const char* p = dot + 7; *p; p++)
    {
        if (*p < '0' || *p > '9') return 0;
        value = value * 10 + (uint32_t)(*p - '0');
    }
    *number = value;
    return 1;
}

static int MycPatchBefore(const void* x, const void* y, void* ctx)
{
    const MycPatch* a = x;
    const MycPatch* b = y;
    int c = strcmp(a->archive_hex, b->archive_hex);
    if (c == 0) return a->number > b->number;
    if (a->archive == MYC_BOOT_ARCHIVE || b->archive == MYC_BOOT_ARCHIVE) return a->archive == MYC_BOOT_ARCHIVE;
    return c < 0;
}

/* The patch files among names, in priority order (MycPatch entries in arena); -1 out of memory. */
static int MycPatchOrder(char** names, int count, MycArena* arena, MycPatch*** out)
{
    MycPatch** list = myc_alloc(arena, sizeof(MycPatch*) * (size_t)(count > 0 ? count : 1));
    int n = 0;
    if (list == NULL) return -1;
    for (int i = 0; i < count; i++)
    {
        MycPatch p;
        memset(&p, 0, sizeof p);
        if (!MycPatchParse(names[i], p.archive_hex, &p.number)) continue;
        MycPatch* copy = myc_alloc(arena, sizeof *copy);
        if (copy == NULL) return -1;
        *copy = p;
        copy->file = names[i];
        copy->archive = strtoull(copy->archive_hex, NULL, 16);
        list[n++] = copy;
    }
    myc_lua_sort((void**)list, n, MycPatchBefore, NULL);
    *out = list;
    return n;
}

int myc_patches_order(char** names, int count, char** out)
{
    MycArena arena = {0};
    MycPatch** list = NULL;
    int n = MycPatchOrder(names, count, &arena, &list);
    for (int i = 0; i < n; i++) out[i] = list[i]->file;
    myc_arena_free(&arena);
    return n < 0 ? 0 : n;
}

/* ---- the index ------------------------------------------------------------------------------------------------------ */

typedef struct MycSum { uint64_t a, b; } MycSum;

/* Adler-32 sums over bytes, reduced every 4,096 bytes (exact). */
static void MycPatchAdler(const uint8_t* p, size_t size, MycSum* s)
{
    for (size_t i = 0; i < size; i += 4096)
    {
        size_t stop = i + 4096 < size ? i + 4096 : size;
        for (size_t k = i; k < stop; k++) { s->a += p[k]; s->b += s->a; }
        s->a %= 65521u;
        s->b %= 65521u;
    }
}

static void MycPatchText(const char* text, MycSum* s)
{
    for (const unsigned char* p = (const unsigned char*)text; *p; p++)
    {
        s->a = (s->a + *p) % 65521u;
        s->b = (s->b + s->a) % 65521u;
    }
}

static int MycPatchWanted(const uint8_t* raw, uint64_t o)
{
    uint32_t low = MycPatchU32(raw, o + 8), high = MycPatchU32(raw, o + 12);
    for (int i = 0; i < 3; i++)
        if ((uint32_t)kMycWanted[i] == low && (uint32_t)(kMycWanted[i] >> 32) == high) return 1;
    return 0;
}

/* The wanted entries chained by their name's low half (backwards: each chain lists entries in file order). */
static int MycPatchChain(MycPatch* patch, MycArena* arena)
{
    for (int64_t i = (int64_t)patch->count - 1; i >= 0; i--)
    {
        uint64_t o = patch->base + (uint64_t)TOC_FILE * (uint64_t)i;
        patch->nexts[i] = UNINDEXED;
        if (!MycPatchWanted(patch->raw, o)) continue;
        uint32_t low = MycPatchU32(patch->raw, o);
        void* first = myc_map_get(&patch->heads, low);
        patch->nexts[i] = first != NULL ? (int32_t)((intptr_t)first - 1) : -1;
        if (!myc_map_put(arena, &patch->heads, low, (void*)(intptr_t)(i + 1))) return 0;
        patch->indexed++;
    }
    return 1;
}

/* One patch file's table of contents read from its open handle: 1 indexed, 0 none of the wanted types, -1 failed. */
static int MycPatchReadToc(MycFiles* files, int handle, MycPatch* patch, MycArena* arena, MycErr* err)
{
    uint8_t head[TOC_HEADER];
    if (!myc_files_read(files, handle, 0, TOC_HEADER, head, err)) return -1;
    if (MycPatchU32(head, 0) != TOC_MAGIC) { myc_fail(err, "bad patch header: %s", patch->file); return -1; }
    uint32_t type_count = MycPatchU32(head, 4), count = MycPatchU32(head, 8);
    if (count == 0 || count > MAX_ENTRIES || type_count > 4096) return 0;
    patch->base = TOC_HEADER + (uint64_t)TOC_TYPE * type_count;
    patch->raw = myc_alloc(arena, patch->base + (uint64_t)TOC_FILE * count);
    patch->nexts = myc_alloc(arena, sizeof(int32_t) * count);
    if (patch->raw == NULL || patch->nexts == NULL) { myc_fail(err, "out of memory for a patch"); return -1; }
    if (!myc_files_read(files, handle, 0, (uint32_t)(patch->base + (uint64_t)TOC_FILE * count), patch->raw, err)) return -1;
    patch->count = count;
    if (!MycPatchChain(patch, arena)) { myc_fail(err, "out of memory for a patch"); return -1; }
    return patch->indexed > 0 ? 1 : 0;
}

static int MycPatchToc(MycFiles* files, MycPatch* patch, MycArena* arena, MycErr* err)
{
    int handle = myc_files_open(files, patch->file, err);
    if (handle < 0) return -1;
    int result = MycPatchReadToc(files, handle, patch, arena, err);
    myc_files_close(files, handle);
    return result;
}

/* An indexed patch's entries into the signature: its file name and each entry's 80 bytes. */
static void MycPatchSum(const MycPatch* patch, MycSum* sum)
{
    for (uint32_t k = 0; k < patch->count; k++)
        if (patch->nexts[k] != UNINDEXED)
        {
            MycPatchText(patch->file, sum);
            MycPatchAdler(patch->raw + patch->base + (uint64_t)TOC_FILE * k, TOC_FILE, sum);
        }
}

MycPatchIndex* myc_patches_index(MycFiles* files, MycArena* arena, MycErr* err)
{
    MycPatchIndex* index = myc_alloc(arena, sizeof *index);
    char** names = NULL;
    int count = myc_files_list(files, "*.patch_*", arena, &names);
    MycPatch** order = NULL;
    int n = index != NULL ? MycPatchOrder(names, count, arena, &order) : -1;
    if (n >= 0) index->patches = myc_alloc(arena, sizeof(MycPatch*) * (size_t)(n > 0 ? n : 1));
    if (n < 0 || index->patches == NULL) { myc_fail(err, "out of memory for the patch index"); return NULL; }
    MycSum sum = {1, 0};
    for (int i = 0; i < n; i++)
    {
        MycErr own = {0};
        int got = MycPatchToc(files, order[i], arena, &own);
        if (got < 0) index->skipped++;
        if (got <= 0) continue;
        MycPatchSum(order[i], &sum);
        index->patches[index->count++] = order[i];
        index->entries += (int)order[i]->indexed;
    }
    snprintf(index->signature, sizeof index->signature, "%d:%d:%d:%08x", index->count, index->entries, index->skipped,
        (unsigned)(sum.b * 65536u + sum.a));
    return index;
}

const char* myc_patches_signature(const MycPatchIndex* index) { return index->signature; }

int myc_patches_count(const MycPatchIndex* index, int* entries, int* skipped)
{
    *entries = index->entries;
    *skipped = index->skipped;
    return index->count;
}

const char* myc_patch_file(const MycPatchIndex* index, int patch)
{
    return index != NULL && patch >= 0 && patch < index->count ? index->patches[patch]->file : "";
}

static int MycPatchRecordIn(const MycPatch* patch, uint64_t name, uint64_t type, MycRecord* out)
{
    void* first = myc_map_get(&patch->heads, (uint32_t)name);
    for (int32_t i = first != NULL ? (int32_t)((intptr_t)first - 1) : -1; i >= 0; i = patch->nexts[i])
    {
        uint64_t o = patch->base + (uint64_t)TOC_FILE * (uint64_t)i;
        if (MycPatchU32(patch->raw, o + 4) == (uint32_t)(name >> 32) && MycPatchU32(patch->raw, o + 8) == (uint32_t)type &&
            MycPatchU32(patch->raw, o + 12) == (uint32_t)(type >> 32))
        {
            myc_record_of(patch->raw, o, out);
            return 1;
        }
    }
    return 0;
}

int myc_patches_record(const MycPatchIndex* index, uint64_t archive, uint64_t name, uint64_t type, MycRecord* out)
{
    for (int i = 0; i < index->count; i++)
    {
        const MycPatch* patch = index->patches[i];
        int searched = patch->archive == MYC_BOOT_ARCHIVE || patch->archive == archive;
        if (searched && MycPatchRecordIn(patch, name, type, out))
        {
            out->patch = i;
            out->archive = archive;
            return 1;
        }
    }
    return 0;
}

/* ---- ranges ----------------------------------------------------------------------------------------------------------- */

void myc_ranges_add(MycRanges* r, int part, uint64_t from, uint64_t to)
{
    if (r->count[part] + 2 > r->capacity[part])
    {
        int capacity = r->capacity[part] < 16 ? 16 : r->capacity[part] * 2;
        uint64_t* grown = realloc(r->list[part], sizeof(uint64_t) * (size_t)capacity);
        if (grown == NULL) return; /* the hash then covers fewer bytes: the cached copy is checked against them */
        r->list[part] = grown;
        r->capacity[part] = capacity;
    }
    r->list[part][r->count[part]++] = from;
    r->list[part][r->count[part]++] = to;
}

void myc_ranges_free(MycRanges* r)
{
    for (int p = 0; p < 3; p++) free(r->list[p]);
    memset(r, 0, sizeof *r);
}

static int MycPatchRangeLess(const void* x, const void* y, void* ctx) { return ((const uint64_t*)x)[0] < ((const uint64_t*)y)[0]; }

/* A part's ranges sorted by start, overlapping and adjacent ones joined, into a malloc'd list (pairs); how many values. */
static int MycPatchMerged(const MycRanges* r, int part, uint64_t** list)
{
    int pairs = r != NULL ? r->count[part] / 2 : 0, n = 0;
    *list = NULL;
    if (pairs == 0) return 0;
    uint64_t** order = malloc(sizeof(uint64_t*) * (size_t)pairs);
    uint64_t* out = malloc(sizeof(uint64_t) * (size_t)pairs * 2);
    if (order == NULL || out == NULL) { free(order); free(out); return 0; }
    for (int i = 0; i < pairs; i++) order[i] = r->list[part] + 2 * i;
    myc_lua_sort((void**)order, pairs, MycPatchRangeLess, NULL);
    for (int i = 0; i < pairs; i++)
    {
        if (n > 0 && order[i][0] <= out[n - 1])
            out[n - 1] = order[i][1] > out[n - 1] ? order[i][1] : out[n - 1];
        else
        {
            out[n++] = order[i][0];
            out[n++] = order[i][1];
        }
    }
    free(order);
    *list = out;
    return n;
}

/* One part's 'part:from+length,...' at out + at (with '|' before it when not first); the new length. */
static size_t MycPatchPartText(const MycRanges* r, int p, char* out, size_t at, size_t size)
{
    uint64_t* list = NULL;
    int n = MycPatchMerged(r, p, &list);
    if (n > 0 && at < size) at += (size_t)snprintf(out + at, size - at, "%s%s:", at > 0 ? "|" : "", kMycParts[p]);
    for (int i = 0; i < n && at < size; i += 2)
        at += (size_t)snprintf(out + at, size - at, "%s%llu+%llu", i > 0 ? "," : "", (unsigned long long)list[i],
            (unsigned long long)(list[i + 1] - list[i]));
    free(list);
    return at;
}

void myc_ranges_text(const MycRanges* r, char* out, size_t size)
{
    size_t at = 0;
    out[0] = 0;
    for (int p = 0; p < 3; p++) at = MycPatchPartText(r, p, out, at, size);
    if (out[0] == 0) snprintf(out, size, "-");
}

/* 'from+length,...' of one part from p (to '|' or the end) into out; the position after it, or NULL when malformed. */
static const char* MycPatchParseList(const char* p, MycRanges* out, int part)
{
    while (*p && *p != '|')
    {
        char* end = NULL;
        unsigned long long from = strtoull(p, &end, 10);
        if (end == p || *end != '+') return NULL;
        p = end + 1;
        unsigned long long length = strtoull(p, &end, 10);
        if (end == p) return NULL;
        p = *end == ',' ? end + 1 : end;
        myc_ranges_add(out, part, from, from + length);
    }
    return out->count[part] > 0 ? p : NULL;
}

static int MycPatchPartOf(const char** p)
{
    for (int k = 0; k < 3; k++)
    {
        size_t n = strlen(kMycParts[k]);
        if (strncmp(*p, kMycParts[k], n) == 0 && (*p)[n] == ':') { *p += n + 1; return k; }
    }
    return -1;
}

int myc_ranges_parse(const char* text, MycRanges* out)
{
    memset(out, 0, sizeof *out);
    if (strcmp(text, "-") == 0) return 1;
    for (const char* p = text; *p;)
    {
        int part = MycPatchPartOf(&p);
        if (part >= 0 && out->count[part] == 0) p = MycPatchParseList(p, out, part);
        if (part < 0 || p == NULL) { myc_ranges_free(out); return 0; }
        if (*p == '|') p++;
    }
    return 1;
}

typedef struct MycHashing { MycFiles* files; const MycRecord* record; const char* file; MycSum sum; uint64_t total; } MycHashing;

/* One range [from, to) of an open part read in CHUNK pieces into the hash. */
static int MycPatchHashRange(MycHashing* h, int handle, int p, uint64_t from, uint64_t to, MycErr* err)
{
    for (uint64_t done = from; done < to; done += CHUNK)
    {
        uint32_t take = (uint32_t)(to - done < CHUNK ? to - done : CHUNK);
        uint8_t* buffer = myc_scratch(MYC_SCRATCH_HASH, take);
        if (buffer == NULL) return myc_fail(err, "out of memory for a content hash");
        if (!myc_files_read(h->files, handle, h->record->at[p] + done, take, buffer, err)) return 0;
        MycPatchAdler(buffer, take, &h->sum);
        h->total += take;
    }
    return 1;
}

static int MycPatchHashPart(MycHashing* h, const MycRanges* ranges, int p, MycErr* err)
{
    uint64_t* list = NULL;
    int n = MycPatchMerged(ranges, p, &list), ok = 1;
    if (n > 0 && list[n - 1] > h->record->size[p]) ok = myc_fail(err, "content range outside %s %s", h->file, kMycParts[p]);
    if (ok && n > 0)
    {
        char name[300];
        snprintf(name, sizeof name, "%s%s", h->file, kMycSuffix[p]);
        int handle = myc_files_open(h->files, name, err);
        ok = handle >= 0;
        for (int i = 0; ok && i < n; i += 2) ok = MycPatchHashRange(h, handle, p, list[i], list[i + 1], err);
        myc_files_close(h->files, handle);
    }
    free(list);
    return ok;
}

int myc_patches_content_hash(MycFiles* files, const MycPatchIndex* index, const MycRecord* record,
    const MycRanges* ranges, char* out, size_t size, MycErr* err)
{
    MycHashing h = {files, record, myc_patch_file(index, record->patch), {1, 0}, 0};
    for (int p = 0; p < 3; p++)
        if (!MycPatchHashPart(&h, ranges, p, err)) return 0;
    snprintf(out, size, "%llu:%08x", (unsigned long long)h.total, (unsigned)(h.sum.b * 65536u + h.sum.a));
    return 1;
}

/* ---- the job's reader ----------------------------------------------------------------------------------------------- */

void myc_reader_init(MycReader* reader, MycSlim* slim, const MycPatchIndex* index, MycFiles* patch_files)
{
    memset(reader, 0, sizeof *reader);
    reader->slim = slim;
    reader->index = index;
    reader->patch_files = patch_files;
    int n = index != NULL ? index->count * 3 : 0;
    reader->patch_handles = n > 0 ? malloc(sizeof(int) * (size_t)n) : NULL;
    for (int i = 0; i < n && reader->patch_handles != NULL; i++) reader->patch_handles[i] = -1;
}

void myc_reader_close(MycReader* reader)
{
    int n = reader->index != NULL && reader->patch_handles != NULL ? reader->index->count * 3 : 0;
    for (int i = 0; i < n; i++) myc_files_close(reader->patch_files, reader->patch_handles[i]);
    free(reader->patch_handles);
    for (int i = 0; i < reader->noted_count; i++) myc_ranges_free(&reader->noted[i].ranges);
    free(reader->noted);
    myc_slim_close(reader->slim);
    myc_arena_free(&reader->arena);
    memset(reader, 0, sizeof *reader);
}

static const MycRecord* MycReaderFound(MycReader* reader, uint64_t archive, uint64_t name, uint64_t type, MycErr* err)
{
    MycRecord patched;
    if (!myc_patches_record(reader->index, archive, name, type, &patched))
        return myc_slim_locate(reader->slim, archive, name, type, err);
    MycRecord* copy = myc_alloc(&reader->arena, sizeof *copy);
    if (copy == NULL) { myc_fail(err, "out of memory for a record"); return NULL; }
    *copy = patched;
    return copy;
}

const MycRecord* myc_reader_locate(MycReader* reader, uint64_t archive, uint64_t name, uint64_t type, MycErr* err)
{
    if (reader->index == NULL) return myc_slim_locate(reader->slim, archive, name, type, err);
    char key[64];
    snprintf(key, sizeof key, "%016llx%016llx%016llx", (unsigned long long)archive, (unsigned long long)name,
        (unsigned long long)type);
    void* known = myc_smap_get(&reader->found, key);
    if (known == MYC_MISSING) return NULL;
    if (known != NULL) return known;
    const MycRecord* record = MycReaderFound(reader, archive, name, type, err);
    if (err->failed) return NULL;
    if (!myc_smap_put(&reader->arena, &reader->found, key, record != NULL ? (void*)record : MYC_MISSING))
        myc_fail(err, "out of memory for a record");
    return record;
}

static MycNoted* MycReaderNoted(MycReader* reader, const MycRecord* record)
{
    for (int i = 0; i < reader->noted_count; i++)
        if (reader->noted[i].record == record) return &reader->noted[i];
    return NULL;
}

int myc_reader_touch(MycReader* reader, uint64_t archive, uint64_t name, uint64_t type, const MycRecord* record)
{
    if (!reader->noting || record->patch < 0) return 1;
    for (int i = 0; i < reader->noted_count; i++)
        if (reader->noted[i].archive == archive && reader->noted[i].name == name && reader->noted[i].type == type) return 1;
    if (reader->noted_count >= reader->noted_capacity)
    {
        int capacity = reader->noted_capacity < 8 ? 8 : reader->noted_capacity * 2;
        MycNoted* grown = realloc(reader->noted, sizeof(MycNoted) * (size_t)capacity);
        if (grown == NULL) return 0;
        reader->noted = grown;
        reader->noted_capacity = capacity;
    }
    MycNoted* n = &reader->noted[reader->noted_count++];
    memset(n, 0, sizeof *n);
    n->archive = archive;
    n->name = name;
    n->type = type;
    n->record = record;
    return 1;
}

int myc_reader_part(MycReader* reader, const MycRecord* record, int part, uint64_t at, uint32_t size, uint8_t* out,
    MycErr* err)
{
    if (record->patch < 0) return myc_slim_part(reader->slim, record, part, at, size, out, err);
    if (at + size > record->size[part]) return myc_fail(err, "read outside a resource part");
    int* handle = &reader->patch_handles[record->patch * 3 + part];
    if (*handle < 0)
    {
        char name[300];
        snprintf(name, sizeof name, "%s%s", myc_patch_file(reader->index, record->patch), kMycSuffix[part]);
        *handle = myc_files_open(reader->patch_files, name, err);
        if (*handle < 0) return 0;
    }
    if (!myc_files_read(reader->patch_files, *handle, record->at[part] + at, size, out, err)) return 0;
    MycNoted* noted = reader->noting && size > 0 ? MycReaderNoted(reader, record) : NULL;
    if (noted != NULL) myc_ranges_add(&noted->ranges, part, at, at + size);
    return 1;
}

void myc_reader_note(MycReader* reader, int on)
{
    reader->noting = on;
    for (int i = 0; i < reader->noted_count; i++) myc_ranges_free(&reader->noted[i].ranges);
    reader->noted_count = 0;
}
