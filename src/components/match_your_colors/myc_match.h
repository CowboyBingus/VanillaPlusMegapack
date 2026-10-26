/* Match Your Colors: the matcher's items, groups and plans (matcher.lua, colour.lua's group functions, variety.lua,
 * zones.lua, schemes.lua) and the color transfer (transfer.lua). Runs on the worker inside a job; every item, group and
 * plan lives in the job's arena. */
#ifndef MYC_MATCH_H
#define MYC_MATCH_H

#include "myc_appearance.h"
#include "myc_colour.h"
#include "myc_kits.h"

#define MYC_GROUP 0
#define MYC_PATTERN 1
#define MYC_PSEUDO 2     /* a color with no rows (a band's light, a lost zone's tone) */

/* A group of an item's paint rows, a pattern of the item, or a pseudo color. rep: the founding row (NULL for a pattern
 * or a pseudo color, whose rep_key alone names it). */
typedef struct MycGroup
{
    double L, a, b, mL, ma, mb, area, under, share;
    double gL, ga, gb;
    int has_g, metal, camo, hood, kind, order;
    MycRow** rows;
    int nrows, rows_capacity;
    MycRow* rep;
    char rep_key[MYC_KEY];
    uint64_t pattern;
    double texel[3], gain[3];
    int has_gain;
} MycGroup;

typedef struct MycItem
{
    MycRow* rows;
    int nrows;
    MycRow** paint;
    int npaint;
    MycGroup** groups;           /* largest first */
    int ngroups;
    MycGroup** patterns;
    int npatterns;
    int armor, weapon, measured, suit_paint, suit_target, cape_source, part_guard;
    double paint_area;
} MycItem;

/* What the study knows of an analysis's rows (Recolor.look_of): NULL for none (a weapon, a scheme). */
typedef struct MycLook
{
    const MycAppKit* kit;   /* the measured kit, or NULL */
    uint32_t hood_id;
    int has_hoods, borrow, seen, seen_share, has_tint;
    uint64_t tint_cape, tint_material;
    int keep_hoods;         /* Recolor Hoods off: a target's hoods keep their colors (myc_item) */
} MycLook;

/* A pattern for the matcher (Recolor.patterns_of): its texture, area and texel 0's color; emblem: a cape source's
 * emblem (Capes.emblem_patterns: named "emblem:<row>:<layer>", erow and elayer). */
typedef struct MycPatternIn { uint64_t pattern; double area, r, g, b; int emblem, erow, elayer; } MycPatternIn;

#define MYC_KIND_PAIR 1
#define MYC_KIND_ACCENT 2
#define MYC_KIND_ZONE 3

/* One planned row (or pattern): its source, the desired perceived color and how it is fitted. */
typedef struct MycGoal
{
    char key[MYC_KEY];
    char source[MYC_KEY];
    char finish[MYC_KEY];   /* Match Materials: the source row whose finish it takes ("" none) */
    char copy[MYC_KEY];     /* a paint scheme's camo row it copies ("" none) */
    char shows[MYC_KEY];    /* a band's row: the source color whose paint it shows ("" none) */
    char tone[16];          /* a variety role's tone ("" none) */
    int kind, coat, band, all, has_cal, has_gain, removed;
    double L, a, b, cal[6], gain[3];
} MycGoal;

typedef struct MycPlan { MycArena* arena; MycGoal* goals; int count, capacity; } MycPlan;
void myc_plan_init(MycPlan* plan, MycArena* arena);
MycGoal* myc_plan_get(const MycPlan* plan, const char* key);
/* A fresh goal for key (replacing one there), NULL out of memory. */
MycGoal* myc_plan_set(MycPlan* plan, const char* key);
void myc_plan_remove(MycPlan* plan, const char* key);
int myc_plan_size(const MycPlan* plan);

/* ---- group colors (colour.lua) ------------------------------------------------------------------------------- */

MycLab myc_group_look(MycRow* const* rows, int n);
/* Colour.diffuse_colors: the source's diffuse look and target t's; 1 when a row of t shows gloss (glossy). */
int myc_diffuse_colors(const MycGroup* t, const MycGroup* src, MycLab* s_out, MycLab* t_out);
void myc_outside_first(MycGroup** pool, int n, MycGroup** out, MycArena* arena);
int myc_two_tone(MycGroup* const* s, int m, int j_main, double min_share, double vivid_c);
MycGroup* myc_nearest_lightness(MycGroup* const* list, int n, const MycGroup* g);

/* The pairing search's context (matcher.lua pair_groups c). keep and allowed are n x m (row i, column j). */
typedef struct MycSearch
{
    MycGroup** t;
    int n;
    MycGroup** s;
    int m;
    int* keep;
    int* allowed;
    double* pre_used;       /* per palette color */
    double ref_t, ref_s, share_sum;
    int flat_check, suit;
} MycSearch;
#define MYC_KEEP(c, i, j) ((c)->keep[(i) * (c)->m + (j)])
#define MYC_ALLOWED(c, i, j) ((c)->allowed[(i) * (c)->m + (j)])

/* A cape source's guard on the allowed pairs (capes.c Capes.dark_parts_guard). */
void myc_capes_dark_parts_guard(MycSearch* c, double accent_c);
/* Colour.cape_structure: structure groups `rest` take the palette's nearest main color the guard allows; pairs
 * appended (target, source) and used per palette color (pre_used). */
typedef struct MycPairs { MycGroup** t; MycGroup** s; int count, capacity; } MycPairs;
int myc_pairs_add(MycArena* arena, MycPairs* pairs, MycGroup* t, MycGroup* s);
int myc_cape_structure(MycArena* arena, MycGroup** rest, int n, MycGroup** palette, int m, MycPairs* pairs, double* used);
void myc_cape_second(const MycSearch* c, int* assign, int anchor, int j_main);

/* ---- the matcher ---------------------------------------------------------------------------------------------- */

#define MYC_ACCENT_C 20.0
#define MYC_MAIN_COLOR 0.10
#define MYC_PAINT_SHARE 0.05
#define MYC_ACCENT_SOURCE_BIG 0.01
#define MYC_KEEP_DE 8.0

int myc_light(const MycRow* row);
int myc_is_structure(const MycGroup* g);
int myc_is_neutral_lab(double L, double a, double b);
MycItem* myc_item(MycArena* arena, const MycRow* rows, int nrows, int armor, const MycPatternIn* patterns, int npatterns,
    const MycLook* look);
/* The source's palette (its groups of at least PAIR_MIN_SHARE, at most 8; else its largest), into out; how many. */
int myc_palette_of(const MycItem* source, MycGroup** out);
MycGroup* myc_identity(MycItem* source);
MycGroup* myc_source_accent(const MycItem* source);
MycGroup* myc_fallback_accent(MycItem* source);
/* Whether g already matches one of the source's groups of min_share or more, as they look. */
int myc_matches_source(const MycGroup* g, const MycItem* source, double min_share);
/* Colour.row_diffuse: a measured row's diffuse color (its response's g x its mean albedo); 0 without one. */
int myc_row_diffuse(const MycRow* row, double out[3]);
/* Matcher.pair_groups: pairs and the anchor (NULL without paint). */
int myc_pair_groups(MycArena* arena, MycItem* target, MycItem* source, MycPairs* pairs, MycGroup** anchor);
/* A pair's choice (Matcher.plan choices): target group t takes src as kind; main: a cape's main as it is (no band);
 * tone: its tonal offset (0 none). */
typedef struct MycChoice { MycGroup* t; MycGroup* src; int kind, main; double tone; } MycChoice;
int myc_tint_bands(MycPlan* mapping, const MycChoice* choices, int n, MycItem* source, MycGroup* accent, int armor);
int myc_cloth_off_metal(MycPlan* mapping, const MycChoice* choices, int n, MycItem* source, int materials);
/* Matcher.plan (materials: Match Materials on; cape: the target is a cape). */
int myc_plan(MycPlan* plan, MycItem* target, MycItem* source, int materials, int cape);
/* Matcher.pattern_plan: goals keyed by the pattern's hex name. */
int myc_pattern_plan(MycPlan* out, MycItem* target, MycItem* source, const MycPlan* plan);
/* Matcher.map_group: every row of group t taking src (tone: a tonal offset, or 0). */
int myc_map_group(MycPlan* mapping, const MycGroup* t, int kind, const MycGroup* src, int materials, int source_armor,
    double tone);
/* variety.lua: an armor's plan never left in one color. */
int myc_balance(MycPlan* plan, MycItem* t, MycItem* s);
/* zones.lua: a cape's design zones and emblems kept readable. */
typedef struct MycZoneOutcome { int picked, kept, lost; } MycZoneOutcome;
typedef struct MycEmblemPick { int has; char source[MYC_KEY]; double L, a, b; } MycEmblemPick;
int myc_cape_zones(MycPlan* mapping, MycItem* target, MycItem* source, const MycAnalysis* cape, MycZoneOutcome* out);
int myc_cape_emblems(const MycPlan* mapping, MycItem* target, MycItem* source, const MycAnalysis* cape,
    MycEmblemPick* picks, MycZoneOutcome* out);

/* ---- paint schemes (schemes.lua) -------------------------------------------------------------------------------- */

typedef struct MycScheme
{
    const char* id;
    const char* label;
    uint64_t archive, lut;
    int camo, has_rows, rows[3], material_roles;
    double looks[8][3];
    int has_look[8];
} MycScheme;
#define MYC_SCHEMES 12
extern const MycScheme myc_schemes[MYC_SCHEMES];
const MycScheme* myc_scheme_get(int index); /* 1 .. MYC_SCHEMES; NULL otherwise */
MycItem* myc_scheme_item(MycArena* arena, MycModel* model, const MycScheme* scheme, const MycLut* lut);
int myc_scheme_plan(MycPlan* plan, const MycScheme* scheme, MycItem* t, MycItem* s, int materials, int cape);
int myc_metal_second(MycItem* s);

/* ---- the color transfer (transfer.lua) ------------------------------------------------------------------------- */

typedef struct MycSourceLuts
{
    const MycAnalysis* analysis;    /* the source analysis (its LUTs, tint_of), or NULL */
    const MycLut* scheme_lut;       /* a scheme's LUT, keyed by scheme_name */
    uint64_t scheme_name;
    int cloth;                      /* a cape's cloth as the source */
} MycSourceLuts;
const MycLut* myc_source_lut(const MycSourceLuts* s, uint64_t name);
typedef struct MycTransfer MycTransfer;
MycTransfer* myc_transfer_new(MycArena* arena, MycModel* model);
/* Writes the fitted colors of LUT row `row` into values; the CIEDE2000 error. origin: the analysis LUT the values were
 * copied from (its row's own albedo kept), or NULL. */
double myc_transfer_apply(MycTransfer* tr, float* values, int width, int row, const MycGoal* goal,
    const MycSourceLuts* source, const MycLut* origin);
/* A cape tint's base color (column 0 RGB) for goal, with `tint` as the row's base; the error. */
double myc_transfer_fit_base(MycTransfer* tr, const float* values, int width, int row, const double tint[3],
    const MycGoal* goal, double out[3]);

#endif
