/* Match Your Colors: reading the game's data files (files.lua, slim.lua, patches.lua, texture.lua). Everything here
 * runs on the component's worker thread inside a job (match_your_colors.c), never on the game thread. */
#ifndef MYC_IO_H
#define MYC_IO_H

#include "myc.h"

/* ---- files (files.lua) ------------------------------------------------------------------------------------------- *
 * Blocking reads at explicit offsets (the worker may wait on the disk: the Lua's overlapped polling kept the game's
 * frame from waiting, which a thread of its own does by construction). */

typedef struct MycFiles
{
    wchar_t folder[1024];   /* with a trailing separator */
    int length;
    void** handles;         /* open handles by index (NULL: closed), malloc'd */
    int capacity, held;
    uint64_t reads, bytes;
    double longest;         /* the longest single read, seconds */
    uint32_t longest_size;
} MycFiles;

/* The game's data folder: the executable's folder (bin) replaced by its sibling data folder. 0 when unknown. */
int myc_files_data_folder(wchar_t* out, int capacity);
void myc_files_init(MycFiles* files, const wchar_t* folder);
/* A handle index (0..), or -1 after myc_fail. */
int myc_files_open(MycFiles* files, const char* name, MycErr* err);
int myc_files_read(MycFiles* files, int handle, uint64_t at, uint32_t size, void* out, MycErr* err);
void myc_files_close(MycFiles* files, int handle);
void myc_files_close_all(MycFiles* files);
/* The ASCII names of the folder's files matching pattern (FindFirstFileExW wildcards), into names (arena strings);
 * how many. */
int myc_files_list(MycFiles* files, const char* pattern, MycArena* arena, char*** names);

/* ---- the slim reader (slim.lua) ---------------------------------------------------------------------------------- */

typedef struct MycRecord
{
    uint64_t at[3];         /* main, stream, GPU part offsets */
    uint32_t size[3];
    int patch;              /* the patch (patches.c index) that holds it, or -1: the archive's own */
    uint64_t archive;       /* the archive it was found for */
} MycRecord;
#define MYC_MAIN 0
#define MYC_STREAM 1
#define MYC_GPU 2

typedef struct MycSlim MycSlim;
MycSlim* myc_slim_open(MycFiles* files, MycErr* err);
void myc_slim_close(MycSlim* slim);
/* The record of a resource in one archive (kept once found), or NULL (not in the archive, or after myc_fail). */
const MycRecord* myc_slim_locate(MycSlim* slim, uint64_t archive, uint64_t name, uint64_t type, MycErr* err);
int myc_slim_part(MycSlim* slim, const MycRecord* record, int part, uint64_t at, uint32_t size, uint8_t* out, MycErr* err);
uint32_t myc_slim_decodes(const MycSlim* slim);
/* A table-of-contents file entry's parts (+16/+24/+32 offsets, +56/+60/+64 sizes) into r. */
void myc_record_of(const uint8_t* raw, uint64_t o, MycRecord* r);
/* LZ4 block decoder: the decoded size, or -1 on malformed input. */
int64_t myc_lz4(const uint8_t* src, size_t src_size, uint8_t* dst, size_t capacity);

/* ---- mods' patches (patches.lua) --------------------------------------------------------------------------------- */

#define MYC_BOOT_ARCHIVE 0x9ba626afa44a3aa3ull
typedef struct MycPatchIndex MycPatchIndex;
/* The data folder's patch files, priority order, indexed for the resource types (3: texture, material, unit). */
MycPatchIndex* myc_patches_index(MycFiles* files, MycArena* arena, MycErr* err);
const char* myc_patches_signature(const MycPatchIndex* index);
int myc_patches_count(const MycPatchIndex* index, int* entries, int* skipped);
const char* myc_patch_file(const MycPatchIndex* index, int patch);
/* The record the patches give when `archive` is searched (the boot archive's, then the archive's own), or 0. */
int myc_patches_record(const MycPatchIndex* index, uint64_t archive, uint64_t name, uint64_t type, MycRecord* out);
/* The patch files' order for names (tests): "file" strings, priority order; how many. */
int myc_patches_order(char** names, int count, char** out);

/* Byte ranges an analysis read of one patched resource, per part (half-open, as read). */
typedef struct MycRanges { uint64_t* list[3]; int count[3], capacity[3]; } MycRanges;
void myc_ranges_add(MycRanges* r, int part, uint64_t from, uint64_t to);
void myc_ranges_free(MycRanges* r);
/* 'main:0+116,4096+200|gpu:0+1472' (merged, parts in order) or '-'; and back (0 when malformed). */
void myc_ranges_text(const MycRanges* r, char* out, size_t size);
int myc_ranges_parse(const char* text, MycRanges* out);
/* 'bytes:adler32' over the ranges of a patch record, read again from its files. */
int myc_patches_content_hash(MycFiles* files, const MycPatchIndex* index, const MycRecord* record,
    const MycRanges* ranges, char* out, size_t size, MycErr* err);

/* ---- the job's reader: the slim data with the mods' patches first (Patches.over) ------------------------------- */

typedef struct MycNoted { uint64_t archive, name, type; const MycRecord* record; MycRanges ranges; } MycNoted;
typedef struct MycReader
{
    MycSlim* slim;
    const MycPatchIndex* index;     /* NULL: no patches */
    MycFiles* patch_files;
    int* patch_handles;             /* per patch and part (3 a patch): a patch_files handle, or -1 */
    MycArena arena;
    MycSMap found;                  /* "<archive><name><type>" hex -> MycRecord, or MYC_MISSING */
    /* while noting: the patched resources an analysis found and read ({archive, name, type} + ranges) */
    int noting;
    MycNoted* noted;
    int noted_count, noted_capacity;
} MycReader;
void myc_reader_init(MycReader* reader, MycSlim* slim, const MycPatchIndex* index, MycFiles* patch_files);
void myc_reader_close(MycReader* reader);
const MycRecord* myc_reader_locate(MycReader* reader, uint64_t archive, uint64_t name, uint64_t type, MycErr* err);
int myc_reader_part(MycReader* reader, const MycRecord* record, int part, uint64_t at, uint32_t size, uint8_t* out,
    MycErr* err);
/* An analysis starts / ends noting what it reads of patched resources (begin_analysis, after_analysis); a patched
 * resource its find served (touched). */
void myc_reader_note(MycReader* reader, int on);
int myc_reader_touch(MycReader* reader, uint64_t archive, uint64_t name, uint64_t type, const MycRecord* record);

/* ---- textures (texture.lua) -------------------------------------------------------------------------------------- */

#define MYC_FMT_RGBA32F 2
#define MYC_FMT_RGBA16F 10
#define MYC_FMT_RGBA8 28
#define MYC_FMT_RGBA8_SRGB 29
#define MYC_FMT_R8 61
#define MYC_FMT_BC1 71
#define MYC_FMT_BC1_SRGB 72
#define MYC_FMT_BC3 77
#define MYC_FMT_BC3_SRGB 78
#define MYC_FMT_BC4 80
#define MYC_FMT_BC7 98
#define MYC_MAX_MIPS 16
#define MYC_COVERAGE_BLOCK 131072
#define MYC_COVERAGE_SIZE 512
#define MYC_MASK_BLOCK 16384

typedef struct MycTexInfo
{
    uint32_t width, height, mips, format, layers;
    uint64_t mip_offsets[MYC_MAX_MIPS + 1];
    uint64_t layer_bytes, total;
} MycTexInfo;
int myc_tex_describe(const uint8_t* main, uint32_t size, MycTexInfo* out, MycErr* err);
uint64_t myc_mip_bytes(uint32_t format, uint32_t w, uint32_t h, uint32_t m);

/* A texture's pixel bytes (Texture.pixels): offset 0 = layer 0 mip 0, over the GPU part, the stream part, or both. */
typedef struct MycPixels { MycReader* reader; const MycRecord* record; MycTexInfo info; int mode; } MycPixels;
int myc_pixels_init(MycPixels* p, MycReader* reader, const MycRecord* record, const MycTexInfo* info, MycErr* err);
int myc_pixels_read(MycPixels* p, uint64_t at, uint32_t size, uint8_t* out, MycErr* err);

double myc_half(uint8_t lo, uint8_t hi);
double myc_single(const uint8_t* p);
/* The LUT (mip 0) as floats (malloc'd in arena): RGBA16F or RGBA32F. */
int myc_tex_lut(MycPixels* p, MycArena* arena, MycLut* out, MycErr* err);
/* ID-mask coverage: 4 per layer, at most 8; how many (0 with why for another format). */
int myc_tex_coverage(MycPixels* p, double* out, MycErr* err, const char** why);
/* A pattern mask's coverage at mip (the last when fewer); 0 when neither R8 nor RGBA8 (*ok 0). */
double myc_tex_mask_coverage(MycPixels* p, int layer, uint32_t mip, int* ok, MycErr* err);
/* BC7: one block (16 bytes) into 16 RGBA texels. */
void myc_bc7_block(const uint8_t* block, uint8_t out[64]);
/* The first `count` texels of mip `mip` of each layer, channels / 255, into layers[l] (count * 4 doubles each, in
 * arena); the layer count, or -1 after myc_fail. */
int myc_tex_samples(MycPixels* p, uint32_t mip, uint32_t count, MycArena* arena, double** layers, int max_layers,
    MycErr* err);

/* Shared scratch buffers of the worker (Slim.grower): at least `size` bytes, reused. */
uint8_t* myc_scratch(int which, size_t size);
#define MYC_SCRATCH_MAIN 0      /* resource main parts, LUT bytes */
#define MYC_SCRATCH_BIG 1       /* ID-mask row blocks, sheet mips */
#define MYC_SCRATCH_PACKED 2    /* LZ4 input */
#define MYC_SCRATCH_HASH 3      /* content hashes */
void myc_scratch_free(void);

#endif
