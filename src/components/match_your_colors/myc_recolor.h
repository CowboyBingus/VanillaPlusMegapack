/* Match Your Colors: from analyses and plans to new LUT and pattern data (recolor.lua's helpers), and the job's
 * results. Runs on the worker inside a job. */
#ifndef MYC_RECOLOR_H
#define MYC_RECOLOR_H

#include "myc_match.h"

#define MYC_METAL_ON_PAINT_ROUGH 0.30

/* Named texture data a plan made (LUT, cape LUT, pattern, sheet, albedo): each spec holds one reference. */
typedef struct MycNamedSpec { uint64_t name; MycSpec* spec; } MycNamedSpec;
typedef struct MycSpecs { MycNamedSpec* items; int n, capacity; } MycSpecs;
MycSpec* myc_specs_get(const MycSpecs* list, uint64_t name);
/* Puts spec under name (taking the caller's reference; one there is dropped); 0 out of memory (spec dropped). */
int myc_specs_put(MycArena* arena, MycSpecs* list, uint64_t name, MycSpec* spec);
void myc_specs_drop(MycSpecs* list);   /* drops every reference (the list's memory stays in its arena) */

/* A fit's statistics (diagnostics): rows fitted and the largest CIEDE2000 error. */
typedef struct MycFits { int rows; double err; } MycFits;

/* Recolor.look_of: the analysis's measured appearance for the matcher; 0 for none (a weapon). seen: a cape as the
 * source (source_look_of). */
int myc_analysis_look(const MycAnalysis* analysis, int seen, MycLook* look);
/* Recolor.patterns_of: the analysis's patterns with texel 0's color; how many (into out, npatterns long). */
int myc_patterns_of(const MycAnalysis* analysis, MycPatternIn* out);
/* Match Materials: LUT row r of data takes source row key's finish; 0 after myc_fail when it is not in the source. */
int myc_apply_finish(float* data, int width, int r, const MycSourceLuts* source, const char* key, MycErr* err);
/* A paint scheme's camo row onto LUT row r of data; 0 after myc_fail. */
int myc_apply_copy(float* data, int width, int r, const MycSourceLuts* source, const char* key, MycErr* err);
/* New LUT data for every target LUT the plan changes, into out (Recolor.build_luts). */
int myc_build_luts(MycArena* arena, const MycAnalysis* target, const MycPlan* plan, MycTransfer* tr,
    const MycSourceLuts* source, MycFits* fits, MycSpecs* out, MycErr* err);
/* The texel color (sRGB) of a planned pattern (Recolor.pattern_texel). */
void myc_pattern_texel(const MycGoal* goal, double out[3]);
/* New pattern textures for every pattern the pattern plan changes (Recolor.build_patterns). */
int myc_build_patterns(MycArena* arena, const MycAnalysis* target, const MycPlan* plan, MycSpecs* out, MycErr* err);

#endif
