/* Match Your Colors: what every file of the component shares (errors, keys, memory, small maps, Lua's sort and sums,
 * the reference-counted texture data). The component's overview and cost are in match_your_colors.c. */
#ifndef MYC_H
#define MYC_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"

#define MYC_KEY 48            /* a row, pattern or goal key ("<16 hex>:<row>", "pattern:<16 hex>", "emblem:<r>:<l>") */
#define MYC_WHY 256

/* ---- errors: a job's first failure, as the Lua's error() text ------------------------------------------------- */

typedef struct MycErr { int failed; char why[MYC_WHY]; } MycErr;
/* Records the first failure (later ones are ignored); returns 0 for `return myc_fail(...)`. */
int myc_fail(MycErr* e, const char* format, ...) __attribute__((format(printf, 2, 3)));

/* ---- numbers as the Lua computes them ------------------------------------------------------------------------- */

double myc_mod(double a, double b);            /* Lua's a % b: a - floor(a / b) * b */
double myc_clip(double x);                     /* min(max(x, 0), 1), NaN to 0 (LuaJIT's math.max/min order) */
double myc_max(double a, double b);            /* math.max(a, b) as LuaJIT: b when a is NaN */
double myc_min(double a, double b);            /* math.min(a, b) as LuaJIT: b when a is NaN */
double myc_deg(double radians);
double myc_rad(double degrees);
double myc_chroma(double a, double b);
/* numpy's pairwise sum (np.add.reduce, n <= 128) and Python's sum() (Neumaier) of a[0 .. n-1]. */
double myc_npsum(const double* a, int n);
double myc_pysum(const double* a, int n);
/* The degrees between two hues (0-180), as the Lua's hue_gap. */
double myc_hue_gap(double a1, double b1, double a2, double b2);

/* ---- names and keys -------------------------------------------------------------------------------------------- */

#define MYC_NO_NAME 0ull      /* '0000000000000000' */
void myc_hex(char out[17], uint64_t value);
/* "<16 hex>:<row>" */
void myc_row_key(char out[MYC_KEY], uint64_t lut, int row);
/* A "<16 hex>:<digits>" key's two parts; 0 when it is not one. */
int myc_split_key(const char* key, uint64_t* lut, int* row);
uint32_t myc_adler_text(const char* text, uint32_t* a, uint32_t* b); /* a running Adler-32 (sums mod 65521) */
uint32_t myc_adler(const char* text);

/* ---- memory ---------------------------------------------------------------------------------------------------- */

/* A bump allocator: zeroed blocks, freed together. Used for a job's matcher items and plans, and for the session's
 * kits, analyses and decoded textures (freed at stop). */
typedef struct MycArenaBlock MycArenaBlock;
typedef struct MycArena { MycArenaBlock* head; size_t total; } MycArena;
void* myc_alloc(MycArena* arena, size_t size); /* zeroed, 16-byte aligned; NULL when out of memory */
char* myc_strdup(MycArena* arena, const char* text);
void myc_arena_free(MycArena* arena);

/* A growable array of fixed-size items inside an arena (its old block is left in the arena when it grows). */
typedef struct MycVec { void* items; int count, capacity; size_t size; } MycVec;
void* myc_vec_push(MycArena* arena, MycVec* vec, size_t size); /* a zeroed new item, or NULL */
#define MYC_AT(vec, type, i) (((type*)(vec).items)[i])

/* A growable byte buffer (malloc'd; failed: an allocation failed, later additions are ignored). */
typedef struct MycBuf { char* data; size_t size, capacity; int failed; } MycBuf;
void myc_buf_add(MycBuf* b, const void* data, size_t size);
void myc_buf_printf(MycBuf* b, const char* format, ...) __attribute__((format(printf, 2, 3)));
void myc_buf_free(MycBuf* b);

/* ---- maps (open addressing) ------------------------------------------------------------------------------------ */

/* u64 -> pointer. Keys are any value but MYC_MAP_EMPTY. Grows inside an arena. */
#define MYC_MAP_EMPTY 0xFFFFFFFFFFFFFFFFull
typedef struct MycMap { uint64_t* keys; void** values; int capacity, count; } MycMap;
void* myc_map_get(const MycMap* map, uint64_t key);
int myc_map_has(const MycMap* map, uint64_t key);
int myc_map_put(MycArena* arena, MycMap* map, uint64_t key, void* value); /* 1, or 0 out of memory */

/* string -> pointer (keys copied into the arena). */
typedef struct MycSMap { char** keys; void** values; int capacity, count; } MycSMap;
void* myc_smap_get(const MycSMap* map, const char* key);
int myc_smap_has(const MycSMap* map, const char* key);
int myc_smap_put(MycArena* arena, MycSMap* map, const char* key, void* value);
/* The sentinel a map stores for "known missing" (the Lua's false). */
extern char myc_missing[1];
#define MYC_MISSING ((void*)myc_missing)

/* ---- Lua's table.sort (lib_table.c auxsort): the same order for the same comparator, ties included ---------- */

typedef int (*MycLess)(const void* x, const void* y, void* ctx); /* 1 when x sorts before y */
void myc_lua_sort(void** items, int count, MycLess less, void* ctx);

/* ---- texture data shared by plans, results and textures (reference counted, any thread) --------------------- */

#define MYC_SPEC_LUT 0      /* a LUT or pattern: RGBA32F width x height, one mip */
#define MYC_SPEC_CAPE 1     /* a cape LUT copy: bound on the cape LUT slot */
#define MYC_SPEC_SHEET 2    /* a decal sheet copy: BC3 with its mip chain */
#define MYC_SPEC_ALBEDO 3   /* a mod's albedo copy: BC1 or BC3 with its mip chain */
#define MYC_SPEC_DIRECT 4   /* the game's own texture (a weapon scheme's decal sheet), bound as it is */

typedef struct MycSpec
{
    volatile long refs;
    int kind;
    int width, height, mips, bc1, format;
    size_t size;            /* bytes of data */
    void* data;             /* float RGBA texels, or the block-compressed mip chain */
    uint64_t name;          /* a sheet's, an albedo's or a direct texture's resource name */
    uint32_t recipe_sum, sample;
} MycSpec;
/* A spec with `size` bytes of zeroed data (malloc'd; NULL out of memory), one reference. */
MycSpec* myc_spec_new(int kind, int width, int height, size_t size);
MycSpec* myc_spec_hold(MycSpec* spec); /* NULL-safe */
void myc_spec_drop(MycSpec* spec);      /* NULL-safe; frees it with its last reference */

/* A decoded texture of the game (LUT, pattern, cape LUT): width x height RGBA as floats. */
typedef struct MycLut { float* values; int width, height; } MycLut;

#endif
