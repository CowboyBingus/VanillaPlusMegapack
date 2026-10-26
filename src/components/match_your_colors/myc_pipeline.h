/* Match Your Colors: the worker's side: the disk cache of analyses (cache.lua), the session's pipeline (recolor.lua
 * pipeline: the game-data reader, the color model, analyses and plans kept), the jobs (Recolor.job, weapons_job) and
 * the weapons in game memory (weapons.lua). Everything here runs on the worker thread unless a comment says otherwise. */
#ifndef MYC_PIPELINE_H
#define MYC_PIPELINE_H

#include <wchar.h>
#include "myc_albedo.h"
#include "myc_capes.h"
#include "myc_runtime.h"

/* ---- the disk cache (cache.lua) ------------------------------------------------------------------------------------ */

#define MYC_CACHE_VERSION 13
#define MYC_CACHE_MAX_ENTRIES 64
#define MYC_CACHE_FILE L"MatchYourColors.cache"
#define MYC_GAME_SHA256 "2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E"
#define MYC_EXE_SHA256 "F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06"
#define MYC_ENTRY_KEY 96

typedef struct MycCacheEntry { char key[MYC_ENTRY_KEY]; MycAnalysis* analysis; } MycCacheEntry;
/* Cache.pieces_sum: Adler-32 of a kit's piece list (made once per kit). */
const char* myc_cache_pieces_sum(MycKit* kit);
void myc_cache_key(MycKit* kit, int body, char* out, size_t size);
void myc_cache_header(const char* data, char* out, size_t size);
/* Cache.encode: the whole file (entries most recently used first; at most MAX_ENTRIES written). */
int myc_cache_encode(MycBuf* out, const char* header, const MycCacheEntry* entries, int n, MycSamples* samples);
/* What Cache.decode gives: the entries (in arena), and the samples when the file holds them (has_samples; samples:
 * the caller's to fill). */
typedef struct MycCacheDecoded { MycCacheEntry* entries; int n; MycSamples* samples; int has_samples; } MycCacheDecoded;
/* Cache.decode: 1 with out filled, or 0 with why. */
int myc_cache_decode(const uint8_t* text, size_t size, const char* header, MycArena* arena, MycCacheDecoded* out,
    char* why, size_t why_size);
/* The file's bytes (malloc'd), or 0 when there is none. */
int myc_cache_read(const wchar_t* path, uint8_t** text, size_t* size);
/* Writes through <path>.tmp and a rename: 1, or 0 with why (the previous file stays). */
int myc_cache_write(const wchar_t* path, const uint8_t* text, size_t size, char* why, size_t why_size);

/* ---- the session's pipeline (recolor.lua pipeline) ----------------------------------------------------------------- */

#define MYC_PLANS_KEPT 128
#define MYC_PLAN_KEY 1536

/* A plan of targets made once and kept (planned): its LUTs and patterns, a cape's zones, emblems, sheet recipe and
 * report, a mod albedo's report, the fits. */
typedef struct MycMade
{
    char key[MYC_PLAN_KEY];
    MycArena arena;
    MycSpecs luts, patterns;
    int has_zones, has_emblems, has_sheet;
    MycZoneOutcome zones, emblems;
    MycSheetRecipe sheet;
    char sheet_note[192];
    char* report;
    char* albedo_report;
    MycFits fits;
} MycMade;

typedef struct MycPipeline
{
    MycArena arena;                 /* the session's: analyses, decoded textures, kit stubs, scheme LUTs */
    MycCatalogue* kits;
    wchar_t data_folder[1024];
    /* the game-data reader, open from a job's first read to close */
    int open;
    MycFiles files;
    MycReader reader;
    int patches_indexed;
    MycPatchIndex* patch_index;
    char patch_status[192];
    MycFind find;
    MycTextures textures;
    /* the color model over the shared samples */
    MycSamples samples;
    int has_samples;
    MycModel* model;
    MycTransfer* transfer;
    /* the disk cache */
    wchar_t cache_path[1100];
    int has_cache;
    char header[512];
    int has_header;
    MycCacheEntry* cached;
    int ncached;
    char (*order)[MYC_ENTRY_KEY];
    int norder, order_capacity;
    MycSMap analyses;               /* key -> MycAnalysis*, or MYC_MISSING (it could not be made) */
    int dirty;
    char cache_status[192];
    MycSMap checked;                /* current(): key -> analysis (holds) or MYC_MISSING */
    /* plans kept, least recently used first */
    MycMade* plans[MYC_PLANS_KEPT];
    int nplans;
    /* scheme LUTs (their metallic bias cleared), weapon packages, the last decal sheet read */
    MycNamedLut schemes[MYC_SCHEMES];
    int nschemes;
    MycMap packages;                /* weapon name -> package archive + 1 (0 none) */
    uint8_t* catalogue_buffer;
    uint8_t* compose_buffer;
    uint64_t kept_sheet;
    MycSpec* kept_sheet_data;
    /* what the reader read over the session */
    uint64_t reads, bytes;
    double longest;
    uint32_t longest_size;
    const char* stage;
} MycPipeline;

/* The pipeline of the session's first job: the data signature, the cache read. NULL after myc_fail. */
MycPipeline* myc_pipeline_new(const wchar_t* data_folder, const wchar_t* cache_path, MycErr* err);
void myc_pipeline_free(MycPipeline* p);
int myc_pipeline_open(MycPipeline* p, MycErr* err);
void myc_pipeline_close(MycPipeline* p);
int myc_pipeline_model(MycPipeline* p, MycErr* err);
void myc_pipeline_find_in(MycPipeline* p, uint64_t archive, const uint64_t* extra, int nextra);
const MycLut* myc_pipeline_scheme_lut(MycPipeline* p, const MycScheme* scheme, MycErr* err);
/* A texture's whole first layer in a spec of its own (pipeline chain); NULL (after myc_fail on an error). */
MycSpec* myc_pipeline_chain(MycPipeline* p, uint64_t name, uint64_t archive, MycTexInfo* info, MycErr* err);
/* The kit's analysis for body (the session's, the cache's while it holds, else new); NULL when it cannot be made (a
 * cape without its LUT) or after myc_fail. */
MycAnalysis* myc_pipeline_analysis(MycPipeline* p, MycKit* kit, int body, MycErr* err);
/* Writes the cache when jobs made new analyses: 1, or 0 with why. */
int myc_pipeline_save(MycPipeline* p, char* why, size_t size);
/* The plan kept under key (moved to the most recently used), or NULL. */
MycMade* myc_pipeline_plan(MycPipeline* p, const char* key);
/* A new plan for key, not kept yet (NULL out of memory); kept (the least recently used past PLANS_KEPT let go), or
 * freed when it could not be made. */
MycMade* myc_made_new(const char* key);
void myc_made_free(MycMade* made);
void myc_pipeline_keep(MycPipeline* p, MycMade* made);

/* Recolor.job / weapons_job: out filled (the pipeline made by the session's first job); 0 after myc_fail. */
int myc_job_run(MycPipeline** p, const wchar_t* data_folder, const wchar_t* cache_path, MycRequest* request, MycResult* out,
    MycErr* err);

#endif
