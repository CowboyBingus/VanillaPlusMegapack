/* Match Your Colors: the perceived color of a material-LUT row (colour.lua), a port of filediver's lut.frag albedo path
 * as research/effective.py and match.py compute it. Nothing here runs per frame. */
#ifndef MYC_COLOUR_H
#define MYC_COLOUR_H

#include "myc.h"

#define MYC_SAMPLES 512
#define MYC_METAL_DARKEN 0.55
#define MYC_METAL_FULL 0.9
#define MYC_GLOSS_C 20.0
#define MYC_GLOSS_TINT_C 5.0
#define MYC_MAX_LAYERS 64
#define MYC_MAX_COLUMNS 64   /* a LUT row's columns the model reads (the game's LUTs have 23; a narrower one fails) */
#define MYC_LUT_COLUMNS 23

typedef struct MycLab { double L, a, b; } MycLab;

double myc_srgb_to_linear(double c);
double myc_linear_to_srgb(double x);
MycLab myc_linear_to_lab(double r, double g, double b);
MycLab myc_srgb_to_lab(double r, double g, double b);
void myc_lab_to_linear(double L, double a, double b, double out[3]);
void myc_lab_to_srgb(double L, double a, double b, double out[3]);
double myc_de2000(double L1, double a1, double b1, double L2, double a2, double b2);

/* Colour.seen: the color the eye takes for a paint through response cal {gr, gg, gb, sr, sg, sb} at mean albedo r, g,
 * b (display-linear, clipped at 0); soft: a matte soft row counts its whole gloss floor. */
void myc_seen(const double cal[6], double r, double g, double b, int soft, double out[3]);
/* Colour.is_soft over a row's values (c[column * 4 + channel]): mode 1 with column 8 x near 0. */
int myc_is_soft(const double* c);
/* Colour.with_gloss: a diffuse Lab with row c's gloss floor (cal[3..5]) over it. */
MycLab myc_with_gloss(double L, double a, double b, const double cal[6]);

/* The model over the shared tiler samples (Colour.new): detail[layer] and camo[layer] are 512 RGBA texels as doubles
 * (channel bytes / 255). The arrays stay the caller's. */
typedef struct MycModel
{
    const double* detail[MYC_MAX_LAYERS];
    const double* camo[MYC_MAX_LAYERS];
    int detail_layers, camo_layers;
    /* per detail layer: the first sample with each distinct (z, w) control pair (Colour distinct_of), made on use */
    int16_t first[MYC_MAX_LAYERS][MYC_SAMPLES];
    int16_t firsts[MYC_MAX_LAYERS][MYC_SAMPLES];
    int nfirsts[MYC_MAX_LAYERS];
    uint8_t distinct_made[MYC_MAX_LAYERS];
} MycModel;

void myc_model_init(MycModel* model, const double* const* detail, int detail_layers, const double* const* camo,
    int camo_layers);
/* A row's values as doubles (Colour.row_values): out[k] = values[row * width * 4 + k] for k < width * 4. */
void myc_row_values(const float* values, int width, int row, double* out);
/* The mean linear albedo of a row (c: row values, at least 23 columns). */
void myc_albedo(MycModel* model, const double* c, double out[3]);
MycLab myc_albedo_lab(MycModel* model, const double* c);
/* The perceived color from a row's albedo (metal darkened); metallic: column 6 w, clipped. */
MycLab myc_perceived_of(const double* c, double r, double g, double b, double* metallic);
MycLab myc_perceived(MycModel* model, const double* c);
/* The look of a row through its measured response (Colour.look_of / look). */
MycLab myc_look_of(double r, double g, double b, const double cal[6], int soft);
MycLab myc_look(MycModel* model, const double* c, const double cal[6], int soft);

/* Colour.row_info: a LUT row's model color and flags. */
typedef struct MycRowInfo { double L, a, b, mode, ar, ag, ab; int metal, camo, full; } MycRowInfo;
MycRowInfo myc_row_info(MycModel* model, const float* values, int width, int row);

#endif
