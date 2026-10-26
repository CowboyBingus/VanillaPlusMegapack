/* Match Your Colors: the reader of the game's slim data files (slim.lua), 1:1. data/bundles.nxa is a DSAR file: a
 * table of chunks (LZ4 blocks or stored bytes) whose concatenation is the DSAA index. The index starts with 24-byte
 * item records sorted by name ('<16 hex>', '<16 hex>.gpu_resources', '<16 hex>.stream'; size u64, name offset u32,
 * entry count u32, entry offset u64), the bundle name offsets and the names, then each item's entries {offset in the
 * item u32, offset in a bundle's uncompressed space u32 at +8, bundle number u8 at +15}. Each bundle
 * data/bundles.NN.nxa is again a DSAR file. An archive's main item starts with its table of contents (72-byte header,
 * 32-byte type entries, 80-byte file entries). Runs on the worker only; every call fails on malformed data. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_io.h"

#define CHUNK_RECORD 32u
#define ITEM_RECORD 24u
#define ENTRY_RECORD 16u
#define TOC_HEADER 72u
#define TOC_TYPE 32u
#define TOC_FILE 80u
#define TOC_MAGIC 0xF0000011u
#define STORED_DIRECT 4194304u  /* stored chunks above this size are read in place, never whole */
#define CHUNK_SLOTS 3
#define SMALL_CHUNK 16384u
#define SMALL_BYTES 1048576u
#define ENTRY_CACHE 16
#define MAX_BUNDLES 256

static uint32_t MycSlimU32(const uint8_t* p, uint64_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }
static uint64_t MycSlimU64(const uint8_t* p, uint64_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
static uint64_t MycSlimMin(uint64_t a, uint64_t b) { return a < b ? a : b; }

/* ---- LZ4 ---------------------------------------------------------------------------------------------------------- */

static const char* g_lz4Why;

/* A length encoded as 15 plus extension bytes. */
static int MycSlimExtended(const uint8_t* src, size_t* ip, size_t src_size, size_t* length)
{
    uint8_t b;
    do
    {
        if (*ip >= src_size) { g_lz4Why = "lz4: truncated length"; return 0; }
        b = src[(*ip)++];
        *length += b;
    } while (b == 255);
    return 1;
}

typedef struct MycLz4 { const uint8_t* src; size_t src_size, ip; uint8_t* dst; size_t capacity, op; } MycLz4;

static int MycSlimLiterals(MycLz4* z, uint8_t token)
{
    size_t count = token >> 4;
    if (count == 15 && !MycSlimExtended(z->src, &z->ip, z->src_size, &count)) return 0;
    if (z->ip + count > z->src_size || z->op + count > z->capacity) { g_lz4Why = "lz4: literals overrun"; return 0; }
    memcpy(z->dst + z->op, z->src + z->ip, count);
    z->ip += count;
    z->op += count;
    return 1;
}

/* One match: an overlapping one (offset below its length) repeats its first `offset` bytes, byte by byte. */
static int MycSlimMatch(MycLz4* z, uint8_t token)
{
    if (z->ip + 2 > z->src_size) { g_lz4Why = "lz4: truncated offset"; return 0; }
    size_t offset = z->src[z->ip] + z->src[z->ip + 1] * 256u;
    z->ip += 2;
    if (offset == 0 || offset > z->op) { g_lz4Why = "lz4: bad offset"; return 0; }
    size_t length = token & 15u;
    if (length == 15 && !MycSlimExtended(z->src, &z->ip, z->src_size, &length)) return 0;
    length += 4;
    if (z->op + length > z->capacity) { g_lz4Why = "lz4: match overrun"; return 0; }
    size_t from = z->op - offset;
    if (offset >= length) memcpy(z->dst + z->op, z->dst + from, length);
    else
        for (size_t k = 0; k < length; k++) z->dst[z->op + k] = z->dst[from + k];
    z->op += length;
    return 1;
}

int64_t myc_lz4(const uint8_t* src, size_t src_size, uint8_t* dst, size_t capacity)
{
    MycLz4 z = {src, src_size, 0, dst, capacity, 0};
    while (z.ip < z.src_size)
    {
        uint8_t token = z.src[z.ip++];
        if (!MycSlimLiterals(&z, token)) return -1;
        if (z.ip >= z.src_size) break;
        if (!MycSlimMatch(&z, token)) return -1;
    }
    return (int64_t)z.op;
}

/* ---- DSAR files --------------------------------------------------------------------------------------------------- */

typedef struct MycSmall { uint8_t* data; uint32_t k; struct MycSmall* next; } MycSmall;

typedef struct MycDsar
{
    int handle;
    uint32_t count;
    uint8_t* chunks;
    char path[64];
    MycSmall* small;        /* decoded small chunks kept */
} MycDsar;

typedef struct MycSlot { MycDsar* owner; uint32_t k; uint8_t* data; size_t capacity; uint64_t used; int live; } MycSlot;
typedef struct MycEntries { uint32_t item; uint8_t* table; } MycEntries;
typedef struct MycToc { uint8_t* raw; uint64_t base; uint32_t count; MycMap heads; int32_t* nexts; } MycToc;

struct MycSlim
{
    MycFiles* files;
    MycArena arena;
    MycDsar index;
    MycDsar* bundles[MAX_BUNDLES];
    MycSlot slots[CHUNK_SLOTS];
    int slot_count;
    uint64_t tick;
    uint8_t* packed;
    size_t packed_size;
    uint32_t small_bytes, decodes;
    uint32_t bundle_count, item_count;
    uint8_t* records;
    uint8_t* names;
    uint64_t names_at, names_size;
    MycEntries entries[ENTRY_CACHE];
    int entry_count;
    MycSMap tocs;           /* archive hex -> MycToc, or MYC_MISSING */
    MycSMap found;          /* "archive name type" hex -> MycRecord, or MYC_MISSING */
};

static int MycSlimDsar(MycSlim* s, MycDsar* d, const char* path, MycErr* err)
{
    memset(d, 0, sizeof *d);
    snprintf(d->path, sizeof d->path, "%s", path);
    d->handle = myc_files_open(s->files, path, err);
    if (d->handle < 0) return 0;
    uint8_t head[32];
    if (!myc_files_read(s->files, d->handle, 0, 32, head, err)) return 0;
    d->count = MycSlimU32(head, 8);
    if (MycSlimU32(head, 0) != 0x52415344u || d->count > 16777216u) return myc_fail(err, "not a DSAR file: %s", path);
    d->chunks = myc_alloc(&s->arena, (size_t)d->count * CHUNK_RECORD + 1);
    if (d->chunks == NULL) return myc_fail(err, "out of memory for %s", path);
    return myc_files_read(s->files, d->handle, 32, d->count * CHUNK_RECORD, d->chunks, err);
}

/* The chunk holding uncompressed offset `at` (binary search; chunks are sorted and contiguous), or -1. */
static int64_t MycSlimFind(const MycDsar* d, uint64_t at, MycErr* err)
{
    int64_t lo = 0, hi = (int64_t)d->count - 1;
    while (lo <= hi)
    {
        int64_t mid = (lo + hi) >> 1;
        uint64_t start = MycSlimU64(d->chunks, (uint64_t)mid * CHUNK_RECORD);
        if (at < start) hi = mid - 1;
        else if (at >= start + MycSlimU32(d->chunks, (uint64_t)mid * CHUNK_RECORD + 16)) lo = mid + 1;
        else return mid;
    }
    myc_fail(err, "offset %llu outside %s", (unsigned long long)at, d->path);
    return -1;
}

static int MycSlimPacked(MycSlim* s, uint32_t size, MycErr* err)
{
    if (size <= s->packed_size) return 1;
    uint8_t* grown = realloc(s->packed, size);
    if (grown == NULL) return myc_fail(err, "out of memory for a chunk");
    s->packed = grown;
    s->packed_size = size;
    return 1;
}

/* Reads chunk k (size bytes decoded) into out. */
static int MycSlimFill(MycSlim* s, MycDsar* d, uint32_t k, uint8_t* out, uint32_t size, MycErr* err)
{
    uint64_t base = (uint64_t)k * CHUNK_RECORD;
    uint64_t packed_at = MycSlimU64(d->chunks, base + 8);
    uint32_t packed_size = MycSlimU32(d->chunks, base + 20);
    uint8_t compression = d->chunks[base + 24];
    if (compression == 0) return myc_files_read(s->files, d->handle, packed_at, size, out, err);
    if (compression != 3) return myc_fail(err, "compression %d in %s", compression, d->path);
    if (!MycSlimPacked(s, packed_size, err) || !myc_files_read(s->files, d->handle, packed_at, packed_size, s->packed, err))
        return 0;
    g_lz4Why = "lz4: short chunk";
    int64_t got = myc_lz4(s->packed, packed_size, out, size);
    if (got < 0) return myc_fail(err, "%s", g_lz4Why);
    if (got != size) return myc_fail(err, "lz4: short chunk in %s", d->path);
    s->decodes++;
    return 1;
}

static void MycSlimFreeSmall(MycDsar* d)
{
    MycSmall* e = d->small;
    while (e != NULL) { MycSmall* next = e->next; free(e->data); free(e); e = next; }
    d->small = NULL;
}

static void MycSlimForgetSmall(MycSlim* s)
{
    MycSlimFreeSmall(&s->index);
    for (int i = 0; i < MAX_BUNDLES; i++)
        if (s->bundles[i] != NULL) MycSlimFreeSmall(s->bundles[i]);
    s->small_bytes = 0;
}

/* A small chunk, decoded into a buffer of its own and kept (kept only once whole). */
static uint8_t* MycSlimSmall(MycSlim* s, MycDsar* d, uint32_t k, uint32_t size, MycErr* err)
{
    MycSmall* e = calloc(1, sizeof *e);
    uint8_t* out = malloc(size > 0 ? size : 1);
    if (e == NULL || out == NULL || !MycSlimFill(s, d, k, out, size, err))
    {
        if (e == NULL || out == NULL) myc_fail(err, "out of memory for a chunk");
        free(e);
        free(out);
        return NULL;
    }
    if (s->small_bytes + size > SMALL_BYTES) MycSlimForgetSmall(s);
    e->data = out;
    e->k = k;
    e->next = d->small;
    d->small = e;
    s->small_bytes += size;
    return out;
}

static uint8_t* MycSlimKept(const MycDsar* d, uint32_t k)
{
    for (MycSmall* e = d->small; e != NULL; e = e->next)
        if (e->k == k) return e->data;
    return NULL;
}

/* The slot holding chunk k of d, or NULL; else in *lru the slot to take (a new one while fewer than CHUNK_SLOTS). */
static MycSlot* MycSlimSlot(MycSlim* s, const MycDsar* d, uint32_t k, MycSlot** lru)
{
    MycSlot* slot = &s->slots[0];
    for (int i = 0; i < s->slot_count; i++)
    {
        MycSlot* t = &s->slots[i];
        if (t->live && t->owner == d && t->k == k) return t;
        if (t->used < slot->used) slot = t;
    }
    if (s->slot_count < CHUNK_SLOTS && s->slots[0].live) slot = &s->slots[s->slot_count++];
    *lru = slot;
    return NULL;
}

static int MycSlimSlotRoom(MycSlot* slot, size_t size, MycErr* err)
{
    if (size <= slot->capacity) return 1;
    size_t capacity = slot->capacity > 0 ? slot->capacity : 262144;
    while (capacity < size) capacity *= 2;
    uint8_t* grown = realloc(slot->data, capacity);
    if (grown == NULL) return myc_fail(err, "out of memory for a chunk");
    slot->data = grown;
    slot->capacity = capacity;
    return 1;
}

/* The decoded bytes of chunk k: a small chunk kept, else one of the shared slots (least recently used first). */
static uint8_t* MycSlimDecoded(MycSlim* s, MycDsar* d, uint32_t k, MycErr* err)
{
    uint8_t* kept = MycSlimKept(d, k);
    if (kept != NULL) return kept;
    uint32_t size = MycSlimU32(d->chunks, (uint64_t)k * CHUNK_RECORD + 16);
    if (size <= SMALL_CHUNK) return MycSlimSmall(s, d, k, size, err);
    s->tick++;
    MycSlot* slot = NULL;
    MycSlot* held = MycSlimSlot(s, d, k, &slot);
    if (held != NULL) { held->used = s->tick; return held->data; }
    slot->live = 0;
    if (!MycSlimSlotRoom(slot, size, err) || !MycSlimFill(s, d, k, slot->data, size, err)) return NULL;
    slot->owner = d;
    slot->k = k;
    slot->used = s->tick;
    slot->live = 1;
    return slot->data;
}

/* Copies one chunk's part [skip, skip + take) into out. */
static int MycSlimChunkPart(MycSlim* s, MycDsar* d, int64_t k, uint64_t skip, uint64_t take, uint8_t* out, MycErr* err)
{
    uint64_t base = (uint64_t)k * CHUNK_RECORD;
    uint32_t length = MycSlimU32(d->chunks, base + 16);
    if (d->chunks[base + 24] == 0 && length > STORED_DIRECT)
        return myc_files_read(s->files, d->handle, MycSlimU64(d->chunks, base + 8) + skip, (uint32_t)take, out, err);
    uint8_t* data = MycSlimDecoded(s, d, (uint32_t)k, err);
    if (data == NULL) return 0;
    memcpy(out, data + skip, take);
    return 1;
}

/* Copies bytes [at, at + size) of the DSAR file's uncompressed space into out. */
static int MycSlimDsarRead(MycSlim* s, MycDsar* d, uint64_t at, uint64_t size, uint8_t* out, MycErr* err)
{
    while (size > 0)
    {
        int64_t k = MycSlimFind(d, at, err);
        if (k < 0) return 0;
        uint64_t base = (uint64_t)k * CHUNK_RECORD;
        uint64_t skip = at - MycSlimU64(d->chunks, base);
        uint64_t take = MycSlimMin(size, MycSlimU32(d->chunks, base + 16) - skip);
        if (!MycSlimChunkPart(s, d, k, skip, take, out, err)) return 0;
        at += take;
        size -= take;
        out += take;
    }
    return 1;
}

/* ---- the index ---------------------------------------------------------------------------------------------------- */

/* -1, 0 or 1: the NUL-terminated name at names[at] against `name`, bytewise. */
static int MycSlimCompare(const uint8_t* names, uint64_t at, uint64_t limit, const char* name)
{
    size_t length = strlen(name);
    for (size_t i = 0; i <= length; i++)
    {
        uint8_t a = at + i < limit ? names[at + i] : 0;
        uint8_t b = i < length ? (uint8_t)name[i] : 0;
        if (a != b) return a < b ? -1 : 1;
        if (a == 0) return 0;
    }
    return 0;
}

static int64_t MycSlimItem(const MycSlim* s, const char* name)
{
    int64_t lo = 0, hi = (int64_t)s->item_count - 1;
    while (lo <= hi)
    {
        int64_t mid = (lo + hi) >> 1;
        int order = MycSlimCompare(s->names, MycSlimU32(s->records, (uint64_t)mid * ITEM_RECORD + 8) - s->names_at,
            s->names_size, name);
        if (order == 0) return mid;
        if (order < 0) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

/* Where the names end: past the last bundle name, at most at the first item's entries. */
static uint64_t MycSlimNamesEnd(const MycSlim* s)
{
    uint64_t end = s->names_at;
    for (uint32_t b = 0; b < s->bundle_count; b++)
    {
        uint64_t e = (uint64_t)MycSlimU32(s->records, (uint64_t)s->item_count * ITEM_RECORD + 4u * b) + 64;
        if (e > end) end = e;
    }
    return MycSlimMin(end, MycSlimU64(s->records, 16));
}

static int MycSlimNames(MycSlim* s, MycErr* err)
{
    uint64_t records_size = (uint64_t)s->item_count * ITEM_RECORD + (uint64_t)s->bundle_count * 4;
    s->records = myc_alloc(&s->arena, records_size + 1);
    if (s->records == NULL) return myc_fail(err, "out of memory for the index");
    if (!MycSlimDsarRead(s, &s->index, 24, records_size, s->records, err)) return 0;
    s->names_at = MycSlimU32(s->records, 8);
    uint64_t names_end = MycSlimNamesEnd(s);
    if (names_end < s->names_at || names_end - s->names_at > 268435456u) return myc_fail(err, "bundles.nxa holds no DSAA index");
    s->names_size = names_end - s->names_at;
    s->names = myc_alloc(&s->arena, s->names_size + 1);
    if (s->names == NULL) return myc_fail(err, "out of memory for the index");
    return MycSlimDsarRead(s, &s->index, s->names_at, s->names_size, s->names, err);
}

static int MycSlimHead(MycSlim* s, MycErr* err)
{
    uint8_t head[24];
    if (!MycSlimDsar(s, &s->index, "bundles.nxa", err) || !MycSlimDsarRead(s, &s->index, 0, 24, head, err)) return 0;
    if (MycSlimU32(head, 0) != 0x41415344u) return myc_fail(err, "bundles.nxa holds no DSAA index");
    s->bundle_count = MycSlimU32(head, 12);
    s->item_count = MycSlimU32(head, 16);
    if (s->bundle_count > MAX_BUNDLES || s->item_count > 16777216u) return myc_fail(err, "unexpected DSAA index");
    return MycSlimNames(s, err);
}

MycSlim* myc_slim_open(MycFiles* files, MycErr* err)
{
    MycSlim* s = calloc(1, sizeof *s);
    if (s == NULL) { myc_fail(err, "out of memory for the game data reader"); return NULL; }
    s->files = files;
    s->slot_count = 1;
    s->index.handle = -1;
    if (MycSlimHead(s, err)) return s;
    myc_slim_close(s);
    return NULL;
}

void myc_slim_close(MycSlim* s)
{
    if (s == NULL) return;
    MycSlimForgetSmall(s);
    myc_files_close(s->files, s->index.handle);
    for (int i = 0; i < MAX_BUNDLES; i++)
        if (s->bundles[i] != NULL) myc_files_close(s->files, s->bundles[i]->handle);
    for (int i = 0; i < CHUNK_SLOTS; i++) free(s->slots[i].data);
    for (int i = 0; i < s->entry_count; i++) free(s->entries[i].table);
    free(s->packed);
    myc_arena_free(&s->arena);
    free(s);
}

uint32_t myc_slim_decodes(const MycSlim* s) { return s->decodes; }

static const char* MycSlimNameAt(const MycSlim* s, uint64_t at, MycErr* err)
{
    uint64_t o = at - s->names_at;
    for (uint64_t n = o; at >= s->names_at && n < s->names_size; n++)
        if (s->names[n] == 0) return (const char*)s->names + o;
    myc_fail(err, "index name runs past the names");
    return NULL;
}

static MycDsar* MycSlimBundle(MycSlim* s, uint32_t number, MycErr* err)
{
    if (number >= s->bundle_count) { myc_fail(err, "bundle number out of range"); return NULL; }
    if (s->bundles[number] != NULL) return s->bundles[number];
    const char* name = MycSlimNameAt(s, MycSlimU32(s->records, (uint64_t)s->item_count * ITEM_RECORD + 4u * number), err);
    MycDsar* d = name != NULL ? myc_alloc(&s->arena, sizeof *d) : NULL;
    if (name != NULL && d == NULL) myc_fail(err, "out of memory for a bundle");
    if (d == NULL) return NULL;
    if (!MycSlimDsar(s, d, name, err)) { myc_files_close(s->files, d->handle); return NULL; }
    s->bundles[number] = d;
    return d;
}

static void MycSlimKeepEntries(MycSlim* s, uint32_t k, uint8_t* table)
{
    if (s->entry_count >= ENTRY_CACHE)
    {
        free(s->entries[0].table);
        memmove(&s->entries[0], &s->entries[1], sizeof(MycEntries) * (ENTRY_CACHE - 1));
        s->entry_count--;
    }
    s->entries[s->entry_count++] = (MycEntries){k, table};
}

/* The entry table of item k (the 16 most recent kept, the oldest let go first). */
static const uint8_t* MycSlimEntries(MycSlim* s, uint32_t k, MycErr* err)
{
    for (int i = 0; i < s->entry_count; i++)
        if (s->entries[i].item == k) return s->entries[i].table;
    uint64_t base = (uint64_t)k * ITEM_RECORD;
    uint32_t count = MycSlimU32(s->records, base + 12);
    uint8_t* table = malloc((size_t)count * ENTRY_RECORD + 1);
    if (table == NULL) { myc_fail(err, "out of memory for an item"); return NULL; }
    if (!MycSlimDsarRead(s, &s->index, MycSlimU64(s->records, base + 16), (uint64_t)count * ENTRY_RECORD, table, err))
    {
        free(table);
        return NULL;
    }
    MycSlimKeepEntries(s, k, table);
    return table;
}

/* The last entry whose item offset is at or below `at`. */
static uint32_t MycSlimEntryFor(const uint8_t* table, uint32_t count, uint64_t at)
{
    int64_t lo = 0, hi = (int64_t)count - 1, best = 0;
    while (lo <= hi)
    {
        int64_t mid = (lo + hi) >> 1;
        if (MycSlimU32(table, (uint64_t)mid * ENTRY_RECORD) <= at) { best = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return (uint32_t)best;
}

typedef struct MycItemRead
{
    const uint8_t* table;
    uint32_t count;
    uint64_t total, at, size;
    const char* name;
    uint8_t* out;
} MycItemRead;

/* One entry's part of an item read: from item->at into item->out, both advanced. */
static int MycSlimEntryRead(MycSlim* s, MycItemRead* item, uint32_t e, MycErr* err)
{
    if (e >= item->count) return myc_fail(err, "archive item entries end early: %s", item->name);
    uint64_t o = (uint64_t)e * ENTRY_RECORD;
    uint64_t start = MycSlimU32(item->table, o), bundle_at = MycSlimU32(item->table, o + 8);
    uint64_t stop = e + 1 < item->count ? MycSlimU32(item->table, o + ENTRY_RECORD) : item->total;
    uint64_t take = MycSlimMin(item->size, stop - item->at);
    MycDsar* bundle = MycSlimBundle(s, item->table[o + 15], err);
    if (bundle == NULL || !MycSlimDsarRead(s, bundle, bundle_at + (item->at - start), take, item->out, err)) return 0;
    item->at += take;
    item->size -= take;
    item->out += take;
    return 1;
}

/* Copies bytes [at, at + size) of item `name`'s virtual file into out. */
static int MycSlimRead(MycSlim* s, const char* name, uint64_t at, uint64_t size, uint8_t* out, MycErr* err)
{
    int64_t k = MycSlimItem(s, name);
    if (k < 0) return myc_fail(err, "archive item missing: %s", name);
    uint64_t base = (uint64_t)k * ITEM_RECORD;
    MycItemRead item = {NULL, MycSlimU32(s->records, base + 12), MycSlimU64(s->records, base), at, size, name, out};
    if (at + size > item.total) return myc_fail(err, "read outside archive item %s", name);
    item.table = MycSlimEntries(s, (uint32_t)k, err);
    if (item.table == NULL) return 0;
    for (uint32_t e = MycSlimEntryFor(item.table, item.count, at); item.size > 0; e++)
        if (!MycSlimEntryRead(s, &item, e, err)) return 0;
    return 1;
}

/* ---- archives ----------------------------------------------------------------------------------------------------- */

/* The entries chained by their name's low half, backwards so each chain lists entries in file order. */
static int MycSlimChain(MycSlim* s, MycToc* t)
{
    for (int64_t i = (int64_t)t->count - 1; i >= 0; i--)
    {
        uint32_t low = MycSlimU32(t->raw, t->base + (uint64_t)TOC_FILE * (uint64_t)i);
        void* head_index = myc_map_get(&t->heads, low);
        t->nexts[i] = head_index != NULL ? (int32_t)((intptr_t)head_index - 1) : -1;
        if (!myc_map_put(&s->arena, &t->heads, low, (void*)(intptr_t)(i + 1))) return 0;
    }
    return 1;
}

static MycToc* MycSlimReadToc(MycSlim* s, const char* name, MycErr* err)
{
    uint8_t head[TOC_HEADER];
    if (!MycSlimRead(s, name, 0, TOC_HEADER, head, err)) return NULL;
    uint32_t types = MycSlimU32(head, 4), count = MycSlimU32(head, 8);
    if (MycSlimU32(head, 0) != TOC_MAGIC || types > 65536 || count > 4194304) { myc_fail(err, "bad archive header: %s", name); return NULL; }
    MycToc* t = myc_alloc(&s->arena, sizeof *t);
    if (t == NULL) { myc_fail(err, "out of memory for an archive"); return NULL; }
    t->base = TOC_HEADER + (uint64_t)TOC_TYPE * types;
    t->count = count;
    t->raw = myc_alloc(&s->arena, t->base + (uint64_t)TOC_FILE * count);
    t->nexts = myc_alloc(&s->arena, sizeof(int32_t) * (count > 0 ? count : 1));
    if (t->raw == NULL || t->nexts == NULL) { myc_fail(err, "out of memory for an archive"); return NULL; }
    if (!MycSlimRead(s, name, 0, t->base + (uint64_t)TOC_FILE * count, t->raw, err)) return NULL;
    if (!MycSlimChain(s, t)) { myc_fail(err, "out of memory for an archive"); return NULL; }
    return t;
}

static MycToc* MycSlimToc(MycSlim* s, uint64_t archive, MycErr* err)
{
    char name[17];
    myc_hex(name, archive);
    void* known = myc_smap_get(&s->tocs, name);
    if (known == MYC_MISSING) return NULL;
    if (known != NULL) return known;
    MycToc* t = MycSlimItem(s, name) >= 0 ? MycSlimReadToc(s, name, err) : NULL;
    if (err->failed) return NULL;
    if (!myc_smap_put(&s->arena, &s->tocs, name, t != NULL ? (void*)t : MYC_MISSING)) myc_fail(err, "out of memory for an archive");
    return t;
}

/* The file entry of name and type in a table of contents, or -1. */
static int64_t MycSlimEntry(const MycToc* t, uint64_t name, uint64_t type)
{
    void* head = t != NULL ? myc_map_get(&t->heads, (uint32_t)name) : NULL;
    for (int32_t i = head != NULL ? (int32_t)((intptr_t)head - 1) : -1; i >= 0; i = t->nexts[i])
    {
        uint64_t o = t->base + (uint64_t)TOC_FILE * (uint64_t)i;
        if (MycSlimU32(t->raw, o + 4) == (uint32_t)(name >> 32) && MycSlimU32(t->raw, o + 8) == (uint32_t)type &&
            MycSlimU32(t->raw, o + 12) == (uint32_t)(type >> 32))
            return (int64_t)o;
    }
    return -1;
}

void myc_record_of(const uint8_t* raw, uint64_t o, MycRecord* r)
{
    r->at[MYC_MAIN] = MycSlimU64(raw, o + 16);
    r->size[MYC_MAIN] = MycSlimU32(raw, o + 56);
    r->at[MYC_STREAM] = MycSlimU64(raw, o + 24);
    r->size[MYC_STREAM] = MycSlimU32(raw, o + 60);
    r->at[MYC_GPU] = MycSlimU64(raw, o + 32);
    r->size[MYC_GPU] = MycSlimU32(raw, o + 64);
}

const MycRecord* myc_slim_locate(MycSlim* s, uint64_t archive, uint64_t name, uint64_t type, MycErr* err)
{
    char key[64];
    snprintf(key, sizeof key, "%016llx%016llx%016llx", (unsigned long long)archive, (unsigned long long)name,
        (unsigned long long)type);
    void* known = myc_smap_get(&s->found, key);
    if (known == MYC_MISSING) return NULL;
    if (known != NULL) return known;
    MycToc* t = MycSlimToc(s, archive, err);
    int64_t o = err->failed ? -1 : MycSlimEntry(t, name, type);
    MycRecord* record = o >= 0 ? myc_alloc(&s->arena, sizeof *record) : NULL;
    if (err->failed || (o >= 0 && record == NULL)) return NULL;
    if (record != NULL)
    {
        myc_record_of(t->raw, (uint64_t)o, record);
        record->patch = -1;
        record->archive = archive;
    }
    if (!myc_smap_put(&s->arena, &s->found, key, record != NULL ? (void*)record : MYC_MISSING)) myc_fail(err, "out of memory");
    return record;
}

int myc_slim_part(MycSlim* s, const MycRecord* record, int part, uint64_t at, uint32_t size, uint8_t* out, MycErr* err)
{
    static const char* const suffix[3] = {"", ".stream", ".gpu_resources"};
    if (at + size > record->size[part]) return myc_fail(err, "read outside a resource part");
    char name[48];
    snprintf(name, sizeof name, "%016llx%s", (unsigned long long)record->archive, suffix[part]);
    return MycSlimRead(s, name, record->at[part] + at, size, out, err);
}
