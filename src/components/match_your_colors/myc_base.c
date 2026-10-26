/* Match Your Colors: the shared helpers of myc.h. Nothing here runs per frame except where a caller says so. */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "myc.h"

char myc_missing[1];

int myc_fail(MycErr* e, const char* format, ...)
{
    if (e == NULL || e->failed) return 0;
    va_list args;
    va_start(args, format);
    vsnprintf(e->why, sizeof e->why, format, args);
    va_end(args);
    e->failed = 1;
    return 0;
}

/* ---- numbers ------------------------------------------------------------------------------------------------------ */

double myc_mod(double a, double b) { return a - floor(a / b) * b; }
double myc_max(double a, double b) { return a > b ? a : b; }
double myc_min(double a, double b) { return a < b ? a : b; }
double myc_clip(double x) { return myc_min(myc_max(x, 0.0), 1.0); }
double myc_deg(double radians) { return radians * (180.0 / 3.14159265358979323846); }
double myc_rad(double degrees) { return degrees * (3.14159265358979323846 / 180.0); }
double myc_chroma(double a, double b) { return sqrt(a * a + b * b); }

double myc_npsum(const double* a, int n)
{
    if (n < 8)
    {
        double s = 0;
        for (int i = 0; i < n; i++) s = s + a[i];
        return s;
    }
    double r0 = a[0], r1 = a[1], r2 = a[2], r3 = a[3], r4 = a[4], r5 = a[5], r6 = a[6], r7 = a[7];
    int i = 8, full = n - n % 8;
    while (i < full)
    {
        r0 = r0 + a[i]; r1 = r1 + a[i + 1]; r2 = r2 + a[i + 2]; r3 = r3 + a[i + 3];
        r4 = r4 + a[i + 4]; r5 = r5 + a[i + 5]; r6 = r6 + a[i + 6]; r7 = r7 + a[i + 7];
        i += 8;
    }
    double s = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7));
    for (int k = i; k < n; k++) s = s + a[k];
    return s;
}

double myc_pysum(const double* a, int n)
{
    if (n == 0) return 0;
    double f = a[0], c = 0;
    for (int i = 1; i < n; i++)
    {
        double x = a[i], t = f + x;
        if (fabs(f) >= fabs(x)) c = c + ((f - t) + x);
        else c = c + ((x - t) + f);
        f = t;
    }
    if (c != 0 && c - c == 0) f = f + c; /* c - c is 0 only when c is finite */
    return f;
}

double myc_hue_gap(double a1, double b1, double a2, double b2)
{
    double d = myc_mod(fabs(myc_deg(atan2(b1, a1) - atan2(b2, a2))), 360.0);
    return d > 180.0 ? 360.0 - d : d;
}

/* ---- names and keys ----------------------------------------------------------------------------------------------- */

void myc_hex(char out[17], uint64_t value) { snprintf(out, 17, "%016llx", (unsigned long long)value); }

void myc_row_key(char out[MYC_KEY], uint64_t lut, int row)
{
    snprintf(out, MYC_KEY, "%016llx:%d", (unsigned long long)lut, row);
}

int myc_split_key(const char* key, uint64_t* lut, int* row)
{
    uint64_t value = 0;
    int i = 0;
    for (; key[i] != 0 && key[i] != ':'; i++)
    {
        char c = key[i];
        int digit = c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
        if (digit < 0 || i >= 16) return 0;
        value = value * 16 + (uint64_t)digit;
    }
    if (i == 0 || key[i] != ':' || key[i + 1] == 0) return 0;
    int r = 0;
    for (const char* p = key + i + 1; *p; p++)
    {
        if (*p < '0' || *p > '9' || r > 100000000) return 0;
        r = r * 10 + (*p - '0');
    }
    *lut = value;
    *row = r;
    return 1;
}

uint32_t myc_adler_text(const char* text, uint32_t* a, uint32_t* b)
{
    for (const unsigned char* p = (const unsigned char*)text; *p; p++)
    {
        *a = (*a + *p) % 65521u;
        *b = (*b + *a) % 65521u;
    }
    return *b * 65536u + *a;
}

uint32_t myc_adler(const char* text)
{
    uint32_t a = 1, b = 0;
    return myc_adler_text(text, &a, &b);
}

/* ---- memory ------------------------------------------------------------------------------------------------------- */

struct MycArenaBlock { MycArenaBlock* next; size_t used, size; };
#define MYC_BLOCK (1024u * 1024u)

void* myc_alloc(MycArena* arena, size_t size)
{
    size = (size + 15u) & ~(size_t)15u;
    MycArenaBlock* block = arena->head;
    size_t header = (sizeof(MycArenaBlock) + 15u) & ~(size_t)15u;
    if (block == NULL || block->size - block->used < size)
    {
        size_t want = size + header > MYC_BLOCK ? size + header : MYC_BLOCK;
        block = malloc(want);
        if (block == NULL) return NULL;
        block->next = arena->head;
        block->used = header;
        block->size = want;
        arena->head = block;
        arena->total += want;
    }
    void* at = (uint8_t*)block + block->used;
    block->used += size;
    memset(at, 0, size);
    return at;
}

char* myc_strdup(MycArena* arena, const char* text)
{
    size_t n = strlen(text) + 1;
    char* copy = myc_alloc(arena, n);
    if (copy != NULL) memcpy(copy, text, n);
    return copy;
}

void myc_arena_free(MycArena* arena)
{
    MycArenaBlock* block = arena->head;
    while (block != NULL)
    {
        MycArenaBlock* next = block->next;
        free(block);
        block = next;
    }
    arena->head = NULL;
    arena->total = 0;
}

void* myc_vec_push(MycArena* arena, MycVec* vec, size_t size)
{
    if (vec->size == 0) vec->size = size;
    if (vec->count >= vec->capacity)
    {
        int capacity = vec->capacity < 8 ? 8 : vec->capacity * 2;
        void* items = myc_alloc(arena, (size_t)capacity * vec->size);
        if (items == NULL) return NULL;
        if (vec->count > 0) memcpy(items, vec->items, (size_t)vec->count * vec->size);
        vec->items = items;
        vec->capacity = capacity;
    }
    void* item = (uint8_t*)vec->items + (size_t)vec->count * vec->size;
    memset(item, 0, vec->size);
    vec->count++;
    return item;
}

/* ---- maps --------------------------------------------------------------------------------------------------------- */

static uint64_t MycMapMix(uint64_t key)
{
    key ^= key >> 33;
    key *= 0xff51afd7ed558ccdull;
    key ^= key >> 33;
    return key;
}

static int MycMapFind(const MycMap* map, uint64_t key)
{
    if (map->capacity == 0) return -1;
    uint64_t mask = (uint64_t)map->capacity - 1;
    for (uint64_t i = MycMapMix(key) & mask;; i = (i + 1) & mask)
    {
        if (map->keys[i] == key) return (int)i;
        if (map->keys[i] == MYC_MAP_EMPTY) return -1;
    }
}

void* myc_map_get(const MycMap* map, uint64_t key)
{
    int i = MycMapFind(map, key);
    return i >= 0 ? map->values[i] : NULL;
}

int myc_map_has(const MycMap* map, uint64_t key) { return MycMapFind(map, key) >= 0; }

static int MycMapGrow(MycArena* arena, MycMap* map)
{
    int capacity = map->capacity == 0 ? 16 : map->capacity * 2;
    uint64_t* keys = myc_alloc(arena, sizeof(uint64_t) * (size_t)capacity);
    void** values = myc_alloc(arena, sizeof(void*) * (size_t)capacity);
    if (keys == NULL || values == NULL) return 0;
    for (int i = 0; i < capacity; i++) keys[i] = MYC_MAP_EMPTY;
    MycMap grown = {keys, values, capacity, 0};
    for (int i = 0; i < map->capacity; i++)
        if (map->keys[i] != MYC_MAP_EMPTY && !myc_map_put(arena, &grown, map->keys[i], map->values[i])) return 0;
    *map = grown;
    return 1;
}

int myc_map_put(MycArena* arena, MycMap* map, uint64_t key, void* value)
{
    int i = MycMapFind(map, key);
    if (i >= 0) { map->values[i] = value; return 1; }
    if ((map->count + 1) * 2 > map->capacity && !MycMapGrow(arena, map)) return 0;
    uint64_t mask = (uint64_t)map->capacity - 1;
    uint64_t at = MycMapMix(key) & mask;
    while (map->keys[at] != MYC_MAP_EMPTY) at = (at + 1) & mask;
    map->keys[at] = key;
    map->values[at] = value;
    map->count++;
    return 1;
}

static uint64_t MycSMapHash(const char* key)
{
    uint64_t h = 1469598103934665603ull;
    for (const unsigned char* p = (const unsigned char*)key; *p; p++) h = (h ^ *p) * 1099511628211ull;
    return h;
}

static int MycSMapFind(const MycSMap* map, const char* key)
{
    if (map->capacity == 0) return -1;
    uint64_t mask = (uint64_t)map->capacity - 1;
    for (uint64_t i = MycSMapHash(key) & mask;; i = (i + 1) & mask)
    {
        if (map->keys[i] == NULL) return -1;
        if (strcmp(map->keys[i], key) == 0) return (int)i;
    }
}

void* myc_smap_get(const MycSMap* map, const char* key)
{
    int i = MycSMapFind(map, key);
    return i >= 0 ? map->values[i] : NULL;
}

int myc_smap_has(const MycSMap* map, const char* key) { return MycSMapFind(map, key) >= 0; }

static int MycSMapInsert(MycSMap* map, char* key, void* value)
{
    uint64_t mask = (uint64_t)map->capacity - 1;
    uint64_t at = MycSMapHash(key) & mask;
    while (map->keys[at] != NULL) at = (at + 1) & mask;
    map->keys[at] = key;
    map->values[at] = value;
    map->count++;
    return 1;
}

static int MycSMapGrow(MycArena* arena, MycSMap* map)
{
    int capacity = map->capacity == 0 ? 16 : map->capacity * 2;
    char** keys = myc_alloc(arena, sizeof(char*) * (size_t)capacity);
    void** values = myc_alloc(arena, sizeof(void*) * (size_t)capacity);
    if (keys == NULL || values == NULL) return 0;
    MycSMap grown = {keys, values, capacity, 0};
    for (int i = 0; i < map->capacity; i++)
        if (map->keys[i] != NULL) MycSMapInsert(&grown, map->keys[i], map->values[i]);
    *map = grown;
    return 1;
}

int myc_smap_put(MycArena* arena, MycSMap* map, const char* key, void* value)
{
    int i = MycSMapFind(map, key);
    if (i >= 0) { map->values[i] = value; return 1; }
    if ((map->count + 1) * 2 > map->capacity && !MycSMapGrow(arena, map)) return 0;
    char* copy = myc_strdup(arena, key);
    return copy != NULL && MycSMapInsert(map, copy, value);
}

/* ---- Lua's table.sort --------------------------------------------------------------------------------------------- *
 * LuaJIT's lib_table.c auxsort (Lua 5.1's quicksort), on a 1-based view of items: the same comparisons in the same
 * order, so ties land where the Lua's do. */

typedef struct MycSort { void** a; MycLess less; void* ctx; } MycSort;
#define MYC_A(s, i) ((s)->a[(i) - 1])

static int MycSortLess(MycSort* s, const void* x, const void* y) { return s->less(x, y, s->ctx); }
static void MycSortSwap(MycSort* s, int i, int j) { void* t = MYC_A(s, i); MYC_A(s, i) = MYC_A(s, j); MYC_A(s, j) = t; }

/* The three-element median step; returns 1 when the range is done (2 or 3 elements). */
static int MycSortMedian(MycSort* s, int lo, int up)
{
    if (MycSortLess(s, MYC_A(s, up), MYC_A(s, lo))) MycSortSwap(s, lo, up);
    if (up - lo == 1) return 1;
    int i = (lo + up) / 2;
    if (MycSortLess(s, MYC_A(s, i), MYC_A(s, lo))) MycSortSwap(s, i, lo);
    else if (MycSortLess(s, MYC_A(s, up), MYC_A(s, i))) MycSortSwap(s, i, up);
    return up - lo == 2;
}

/* The partition around the pivot a[(lo + up) / 2]; returns where the pivot ends. */
static int MycSortPartition(MycSort* s, int lo, int up)
{
    int i = (lo + up) / 2;
    void* p = MYC_A(s, i);
    MycSortSwap(s, i, up - 1);
    i = lo;
    int j = up - 1;
    for (;;)
    {
        while (++i < up && MycSortLess(s, MYC_A(s, i), p)) {}
        while (--j > lo && MycSortLess(s, p, MYC_A(s, j))) {}
        if (j < i) break;
        MycSortSwap(s, i, j);
    }
    MycSortSwap(s, up - 1, i);
    return i;
}

static void MycSortRange(MycSort* s, int lo, int up)
{
    while (lo < up)
    {
        if (MycSortMedian(s, lo, up)) break;
        int i = MycSortPartition(s, lo, up), j;
        if (i - lo < up - i) { j = lo; i = i - 1; lo = i + 2; }
        else { j = i + 1; i = up; up = j - 2; }
        MycSortRange(s, j, i);
    }
}

void myc_lua_sort(void** items, int count, MycLess less, void* ctx)
{
    MycSort s = {items, less, ctx};
    MycSortRange(&s, 1, count);
}

/* ---- specs -------------------------------------------------------------------------------------------------------- */

MycSpec* myc_spec_new(int kind, int width, int height, size_t size)
{
    MycSpec* spec = calloc(1, sizeof *spec);
    if (spec == NULL) return NULL;
    spec->data = size > 0 ? calloc(1, size) : NULL;
    if (size > 0 && spec->data == NULL) { free(spec); return NULL; }
    spec->refs = 1;
    spec->kind = kind;
    spec->width = width;
    spec->height = height;
    spec->mips = 1;
    spec->size = size;
    return spec;
}

MycSpec* myc_spec_hold(MycSpec* spec)
{
    if (spec != NULL) InterlockedIncrement(&spec->refs);
    return spec;
}

void myc_spec_drop(MycSpec* spec)
{
    if (spec == NULL || InterlockedDecrement(&spec->refs) != 0) return;
    free(spec->data);
    free(spec);
}

/* ---- buffers ------------------------------------------------------------------------------------------------------ */

void myc_buf_add(MycBuf* b, const void* data, size_t size)
{
    if (b->failed) return;
    if (b->size + size + 1 > b->capacity)
    {
        size_t capacity = b->capacity < 4096 ? 4096 : b->capacity;
        while (capacity < b->size + size + 1) capacity *= 2;
        char* grown = realloc(b->data, capacity);
        if (grown == NULL) { b->failed = 1; return; }
        b->data = grown;
        b->capacity = capacity;
    }
    memcpy(b->data + b->size, data, size);
    b->size += size;
    b->data[b->size] = 0;
}

void myc_buf_printf(MycBuf* b, const char* format, ...)
{
    char text[1024];
    va_list args;
    va_start(args, format);
    int n = vsnprintf(text, sizeof text, format, args);
    va_end(args);
    if (n < 0) { b->failed = 1; return; }
    if ((size_t)n < sizeof text) { myc_buf_add(b, text, (size_t)n); return; }
    char* big = malloc((size_t)n + 1);
    if (big == NULL) { b->failed = 1; return; }
    va_start(args, format);
    vsnprintf(big, (size_t)n + 1, format, args);
    va_end(args);
    myc_buf_add(b, big, (size_t)n);
    free(big);
}

void myc_buf_free(MycBuf* b)
{
    free(b->data);
    memset(b, 0, sizeof *b);
}
