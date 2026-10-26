/* Match Your Colors: the measured appearance of every helmet and armor (appearance.lua, matcher v12), from the
 * generated tables of myc_appearance_data.c. Parsed on demand and kept for the session; used by the worker's jobs. */
#ifndef MYC_APPEARANCE_H
#define MYC_APPEARANCE_H

#include "myc.h"

typedef struct MycAppText { uint32_t id; const char* text; } MycAppText;
extern const int myc_app_lut_count, myc_app_kit_count, myc_app_hood_count;
extern const uint64_t myc_app_luts[];
extern const char* const myc_app_rows[];
extern const MycAppText myc_app_kits[];
extern const MycAppText myc_app_hoods[];

typedef struct MycAppRow { uint64_t lut; int row; double px, light; } MycAppRow;
typedef struct MycAppPattern { uint64_t pattern; double px, gain[3]; int has_gain; } MycAppPattern;
typedef struct MycAppKit
{
    uint32_t id;
    uint64_t* luts;
    int nluts;
    MycAppRow* rows;
    int nrows;
    MycAppPattern* patterns;
    int npatterns;
} MycAppKit;

/* The measured response {gr, gg, gb, sr, sg, sb} of a LUT row, or NULL (not measured). */
const double* myc_app_row(uint64_t lut, int r);
const MycAppKit* myc_app_kit(uint32_t id);
/* The one measured kit whose LUTs are exactly luts, or NULL (none, or several). */
const MycAppKit* myc_app_kit_for(const uint64_t* luts, int count);
int myc_app_kit_has_lut(const MycAppKit* kit, uint64_t lut);
const MycAppRow* myc_app_kit_row(const MycAppKit* kit, uint64_t lut, int row);
const MycAppPattern* myc_app_kit_pattern(const MycAppKit* kit, uint64_t pattern);
/* The largest share of a measured kit's screen pixels the row showed on (0: measured, never seen), or -1 (the study
 * has not the LUT). */
double myc_app_seen_share(uint64_t lut, int r);
/* Whether row (lut, r) is a hood row of kit id (Recolor Hoods). */
int myc_app_is_hood(uint32_t id, uint64_t lut, int r);
int myc_app_has_hoods(uint32_t id);
/* Frees the parsed tables (stop). */
void myc_app_free(void);

#endif
