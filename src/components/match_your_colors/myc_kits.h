/* Match Your Colors: kits, their analyses (kits.lua) and the kit catalogue in game memory. Analyses run on the worker
 * inside a job; the catalogue is read there too, and by the game thread's record checks (under a lock). */
#ifndef MYC_KITS_H
#define MYC_KITS_H

#include "myc.h"
#include "myc_colour.h"
#include "myc_io.h"

#define MYC_TYPE_UNIT 0xe0a48d0be9a7453full
#define MYC_TYPE_MATERIAL 0xeac0b497876adedfull
#define MYC_TYPE_TEXTURE 0xcd4238c6a0c69e32ull
#define MYC_SLOT_LUT 0x7e662968u
#define MYC_SLOT_MASK 0xb281e5f2u
#define MYC_SLOT_PATTERN 0x81d4c49du
#define MYC_SLOT_PATTERN_MASK 0x05a27dd5u
#define MYC_SLOT_DECAL 0x632a8b80u
#define MYC_PATTERN_MIP 2
#define MYC_DETAIL_TILER 0x5015467d918378bfull
#define MYC_CAMO_TILER 0xf8b2508e99fb9f28ull
#define MYC_UNDERGARMENT 1
#define MYC_BODY_ANY 3
#define MYC_WEAPON_BIAS 1.5

#define MYC_ARMOR 0
#define MYC_HELMET 1
#define MYC_CAPE 2
#define MYC_WEAPON 3
const char* myc_kit_type_name(int type); /* "Armor", "Helmet", "Cape", "Weapon" */

/* A weapon's paint for one material slot (src/weapons.lua overrides): the LUT and pattern the game binds there, the LUT
 * it binds now (bound, a template's) and a template's decal sheet. */
typedef struct MycOverride { uint32_t slot; uint64_t lut, pattern, bound, decal; int has_bound; } MycOverride;

typedef struct MycPiece
{
    uint64_t path;
    uint32_t slot, type, body, tone;
    uint64_t lut, pattern;
    int is_cape;
    uint64_t cape_lut, gradient, fields, decal;
    MycOverride* overrides;     /* a weapon's, or NULL */
    int noverrides, has_overrides;
    const char* overrides_text; /* NULL: none */
} MycPiece;

typedef struct MycKit
{
    uint32_t id, name_upper;
    uint64_t archive;
    int type;
    MycPiece* pieces;
    int npieces;
    /* a weapon's (weapons.c Weapons.kit) */
    uint64_t name;
    uint64_t extra[8];
    int nextra;
    char template_id[16];
    /* made once (a kit is never changed once read) */
    char* signature;
    uint32_t sum_s, sum_t, sum_n;
    int has_sum;
    char pieces_sum[9];
} MycKit;

/* One material of a piece (piece_materials). */
typedef struct MycMaterial
{
    uint64_t material, lut, mask, bound, pattern, pattern_mask, albedo, mra, decal_from, decal_to;
    int has_mask, has_bound, has_pattern, has_pattern_mask, has_decal, is_albedo, has_mra, patched;
} MycMaterial;

typedef struct MycAPiece
{
    MycPiece piece;             /* a cached analysis keeps slot, type and body only */
    double weight;
    MycMaterial* materials;
    int nmaterials, skin;
} MycAPiece;

typedef struct MycVanilla { double L, a, b, ar, ag, ab; } MycVanilla;

/* An analysis row, and (Matcher.item) a matcher item's row. */
typedef struct MycRow
{
    char key[MYC_KEY];
    uint64_t lut;               /* its LUT (a cape tint row's: the cape LUT; an albedo cluster's: the albedo) */
    int row;
    double area, under, L, a, b, mode, ar, ag, ab, emissive;
    int metal, camo, full, albedo;
    int finish_changed;         /* -1 nil, 0 false, 1 true */
    int has_vanilla;
    MycVanilla vanilla;
    /* a matcher item's */
    double mL, ma, mb, tex_area, light, outside;
    double lin[3], cal[6];
    int has_lin, has_cal, has_outside, lens, hood, cape, copy;
} MycRow;

typedef struct MycNamedLut { uint64_t name; MycLut* lut; } MycNamedLut;
typedef struct MycPatternArea { uint64_t pattern; double area; } MycPatternArea;
typedef struct MycUnread { uint64_t material; char file[64]; char why[96]; } MycUnread;
typedef struct MycPatchDep { uint64_t archive, name, kind; char hash[32]; char* ranges; } MycPatchDep;

/* A mod's albedo cluster (albedo.c). */
typedef struct MycCluster { double count, share, lin[3], lab[3], metal, seen[3]; } MycCluster;
typedef struct MycAlbedo
{
    uint32_t format, width, height, mips;
    uint64_t total;
    MycCluster clusters[8];
    int nclusters;
} MycAlbedo;
typedef struct MycNamedAlbedo { uint64_t name; MycAlbedo* albedo; } MycNamedAlbedo; /* albedo NULL: unreadable */

/* A cape's design zone borders: counts[zone][row][bin] (capes.c), present[zone][row]. */
#define MYC_ZONE_BINS 8
typedef struct MycZones { uint32_t counts[5][5][MYC_ZONE_BINS]; uint8_t present[5][5]; } MycZones;
typedef struct MycEmblem
{
    int row, layer, cells, has_rect, rect[4], around_row;
    double L, a, b;
    uint32_t counts[MYC_ZONE_BINS];
    uint64_t sheet;
    uint32_t sheet_width, sheet_height, sheet_format, sheet_mips;
} MycEmblem;

typedef struct MycAnalysis
{
    MycKit* kit;
    int body;
    MycAPiece* pieces;
    int npieces;
    MycNamedLut* luts;
    int nluts, luts_capacity;
    MycRow* rows;
    int nrows;
    MycPatternArea* patterns;
    int npatterns;
    int dropped, drawn, geometry_patched, cached;
    MycUnread* unread;
    int nunread;
    MycNamedAlbedo* albedos;
    int nalbedos;
    MycPatchDep* deps;
    int ndeps;
    /* a cape's (capes.c) */
    int has_tint;
    uint64_t tint_cape, tint_material;  /* tint_of: {[cape LUT] = material LUT} */
    MycZones* zones;
    MycEmblem* emblems;
    int nemblems, emblem_layers;
    double weight;
    char tint_note[160];
} MycAnalysis;

MycLut* myc_analysis_lut(const MycAnalysis* a, uint64_t name);
int myc_analysis_add_lut(MycArena* arena, MycAnalysis* a, uint64_t name, MycLut* lut);

/* ---- the job's texture loaders and finder (Kits.textures, Recolor's find_in) --------------------------------- */

typedef struct MycFind
{
    MycReader* reader;
    uint64_t archives[12];
    int count;
} MycFind;
/* The first archive holding name/type (its record); 0 when none (after myc_fail on an error). A patched resource is
 * noted (touched) while the reader notes. */
int myc_find(MycFind* find, uint64_t name, uint64_t type, uint64_t* archive, const MycRecord** record, MycErr* err);

typedef struct MycTextures
{
    MycArena* arena;            /* the session's: decoded textures are kept for the session */
    MycMap luts, coverages, patterns;
    MycSMap pattern_coverages;
} MycTextures;
/* A texture's description and pixel reader (Kits.textures describe): 1, 0 not found, -1 after myc_fail (the texture's
 * name and patch file in the error). */
int myc_tex_open(MycFind* find, uint64_t name, MycPixels* out, MycErr* err);
MycLut* myc_textures_lut(MycTextures* t, MycFind* find, uint64_t name, MycErr* err);       /* NULL: missing or error */
const double* myc_textures_coverage(MycTextures* t, MycFind* find, uint64_t name, int* channels, MycErr* err);
MycLut* myc_textures_pattern(MycTextures* t, MycFind* find, uint64_t name, MycErr* err);
int myc_textures_pattern_coverage(MycTextures* t, MycFind* find, uint64_t name, int layer, double* out, MycErr* err);

/* ---- analyses --------------------------------------------------------------------------------------------------- */

typedef struct MycKitDeps
{
    MycFind* find;
    MycTextures* textures;
    MycModel* model;
    MycArena* arena;            /* the session's (analyses are kept) */
    const char* const* weapon_units;    /* weapon_data.c units table, or NULL */
} MycKitDeps;

double myc_kit_weight(int kit_type, const MycPiece* piece, int body);
MycAnalysis* myc_kits_analyse(MycKit* kit, int body, MycKitDeps* deps, MycErr* err);
/* The shared detail and camo samples (Kits.shared_samples): 1 found, 0 no shared archive holds them, -1 error. */
typedef struct MycSamples
{
    uint64_t archive;
    double* detail[MYC_MAX_LAYERS];
    double* camo[MYC_MAX_LAYERS];
    int detail_layers, camo_layers;
    uint8_t* encoded;           /* the cache file's block, made once (cache.c) */
    size_t encoded_size;
} MycSamples;
int myc_kits_shared_samples(MycReader* reader, MycArena* arena, MycSamples* out, MycErr* err);
double myc_kits_emissive(const MycLut* lut, int r);
/* A LUT row's analysis row fields (lut_row). */
int myc_kits_lut_row(MycModel* model, const MycLut* lut, int r, int weapon, MycRow* row, MycErr* err);
/* What an analysis read from mods' patches (Kits.mark_patched): touched resources (archive, name, type), the original
 * LUT loader (NULL result: none). */
typedef MycLut* (*MycOriginalLut)(void* ctx, uint64_t name);
void myc_kits_mark_patched(MycAnalysis* a, const MycNoted* touched, int count, MycOriginalLut original, void* ctx,
    MycModel* model);
const char* myc_kits_signature(MycArena* arena, MycKit* kit);

/* ---- the catalogue (customization manager [game + 0x33264F8]) ------------------------------------------------ */

#define MYC_RECORD_BYTES (64 + 8 * 24 + 8 * 32 * 96)
typedef struct MycCatalogue MycCatalogue;
MycCatalogue* myc_catalogue_new(void);
void myc_catalogue_free(MycCatalogue* c);
/* The kit of id as its record reads now (kept while its bytes are the same); NULL after myc_fail. */
MycKit* myc_catalogue_find(MycCatalogue* c, uint32_t id, MycErr* err);
/* The record's content now (no scan): its signature, or NULL before the first lookup or when unreadable. */
const char* myc_catalogue_signature(MycCatalogue* c, uint32_t id);

#endif
