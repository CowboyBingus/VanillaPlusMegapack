/* Match Your Colors: capes (capes.lua): which rows of a cape's material LUT show, how much, and how much of each its
 * tint covers; its design zones and emblem-sheet layers; a cape as the matcher's source. Runs on the worker inside a
 * job. */
#ifndef MYC_CAPES_H
#define MYC_CAPES_H

#include "myc_kits.h"
#include "myc_match.h"

#define MYC_CAPE_GRID 128
#define MYC_CAPE_CELLS (MYC_CAPE_GRID * MYC_CAPE_GRID)
#define MYC_CAPE_THRESHOLD 128
#define MYC_CAPE_W_OUT 13
#define MYC_CAPE_W_IN 7
#define MYC_CAPE_SET 127
#define MYC_CAPE_TINT_STEPS 4096
#define MYC_CAPE_INSIDE_ROW 4
#define MYC_CAPE_SHEET_MIP 3

/* ---- the grid (myc_capes_grid.c) ---------------------------------------------------------------------------------- */

const uint8_t* myc_cape_outline(void);   /* GRID x GRID, 1 inside */
void myc_cape_bc4_block(const uint8_t* block, uint8_t out[64]);
void myc_cape_bc3_block(const uint8_t* block, uint8_t out[64]);

/* A mip read for sampling (read_mip): raw bytes in the big scratch, its format's cell reader. */
#define MYC_CELL_RGBA8 0
#define MYC_CELL_RGBA16F 1
#define MYC_CELL_RGBA32F 2
#define MYC_CELL_BC7 3
#define MYC_CELL_BC3 4
#define MYC_CELL_BC4 5
typedef struct MycCapeMip { const uint8_t* raw; uint32_t w, h, wide; int cell; } MycCapeMip;
int myc_cape_read_mip(MycPixels* p, uint32_t m, MycCapeMip* out, MycErr* err);
/* Texel (x, y) of a mip into out (RGBA bytes). */
void myc_cape_texel(const MycCapeMip* mip, uint32_t x, uint32_t y, uint8_t out[4]);
/* The texture sampled on the grid into out (GRID x GRID x 4, cleared first): Capes.cells. */
int myc_cape_cells(MycPixels* p, uint8_t* out, MycErr* err);
/* A cell's tint steps for material row `row` at gradient byte g (tint_steps); 0 without a tint or past its height. */
double myc_cape_tint_steps(const MycLut* tint, int row, double g);
/* Capes.areas: rows[r] and tints[r] (r < 5; 0 none) and the total weight. */
void myc_cape_areas(const uint8_t* cells, int height, const MycLut* tint, const uint8_t* grad, double rows[5],
    double tints[5], double* total);
/* Capes.zones into zones (cleared); 0 when no zone borders anything. Fills the outside rows the emblems read. */
int myc_cape_zones_of(const uint8_t* cells, int height, const MycLut* tint, const uint8_t* grad, MycZones* zones);
/* The outside row of grid cell i that counts (0-3), -1 for the others (after myc_cape_zones_of). */
int myc_cape_row_at(int i);

/* ---- emblems (myc_capes_emblems.c) -------------------------------------------------------------------------------- */

/* A cape's inputs to the second half of its analysis: its material LUT, its tint (cape LUT) and gradient (NULL: none),
 * and its rows' areas and tint areas (rows 0-4). */
typedef struct MycCapeInputs { MycLut* lut; MycLut* tint; const uint8_t* grad; double areas[5], tints[5]; } MycCapeInputs;
/* The cape's emblems that show (emblems_of), into the analysis (arena); 0 after myc_fail. */
int myc_cape_emblems_of(MycFind* find, const MycPiece* piece, const MycCapeInputs* in, MycArena* arena, MycAnalysis* out,
    MycErr* err);
/* A BC3 sheet's mip chain with the blocks overlapping rect moved by shift (Lab), in place (Capes.recolor_sheet). */
void myc_cape_recolor_sheet(uint8_t* data, uint32_t width, uint32_t height, uint32_t mips, const int rect[4],
    const double shift[3]);

/* ---- analysis and source (myc_capes.c) ---------------------------------------------------------------------------- */

/* Capes.analyse: NULL with why (no material LUT) or after myc_fail (err->failed). */
MycAnalysis* myc_capes_analyse(MycKit* kit, int body, MycKitDeps* deps, char* why, size_t why_size, MycErr* err);
/* Capes.source_rows into out (cape->nrows long); how many. */
int myc_capes_source_rows(const MycAnalysis* cape, MycRow* out);
/* Capes.emblem_patterns into out (cape->nemblems long); how many. */
int myc_capes_emblem_patterns(const MycAnalysis* cape, MycPatternIn* out);
/* Capes.report: the development log line of a cape's plan. */
struct MycFits;
void myc_capes_report(const MycAnalysis* c, const MycZoneOutcome* zones, const MycZoneOutcome* emblems,
    const char* sheet_note, const struct MycFits* fits, char* out, size_t size);
/* Capes.sheet_sums: Adler-32 of a recipe key and of 64 blocks spread over the sheet's bytes. */
void myc_capes_sheet_sums(const char* key, const uint8_t* data, size_t size, uint32_t* key_sum, uint32_t* data_sum);

/* ---- emblem-sheet copies (myc_sheets.c, sheets.lua) --------------------------------------------------------------- */

#define MYC_SHEETS_KEPT 2
#define MYC_SHEET_FORMAT 77
#define MYC_SHEET_CELLS 64
typedef struct MycSheetCell { int rect[4]; double shift[3]; } MycSheetCell;
typedef struct MycSheetRecipe
{
    uint64_t name;
    uint32_t width, height, mips;
    size_t size;
    MycSheetCell cells[MYC_SHEET_CELLS];
    int ncells;
} MycSheetRecipe;
size_t myc_bc3_bytes(uint32_t width, uint32_t height, uint32_t mips);
/* The recipe of a cape plan's sheet (Sheets.sheet_recipe); 0 when no emblem takes a color or its sheet is no BC3. */
int myc_sheet_recipe(const MycAnalysis* target, const MycEmblemPick* picks, MycSheetRecipe* out);
void myc_sheet_key(const MycSheetRecipe* recipe, char* out, size_t size);
/* The original bytes of a recipe's sheet (the pipeline's: its whole mip chain), or NULL with why. */
typedef const uint8_t* (*MycSheetOriginal)(void* ctx, const MycSheetRecipe* recipe, char* why, size_t why_size);
/* The recolored copy of the cape's sheet (Sheets.sheet_spec): a reference for the caller; NULL with why (or after
 * myc_fail: out of memory). Kept recipes (SHEETS_KEPT) and every sheet still referenced are found again. */
MycSpec* myc_sheet_spec(const MycSheetRecipe* recipe, MycSheetOriginal original, void* ctx, char* why, size_t why_size,
    MycErr* err);
void myc_sheets_free(void);  /* the kept sheets (stop) */

#endif
