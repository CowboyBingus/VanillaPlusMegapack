/* Match Your Colors: the color model (colour.lua), 1:1. For one LUT row the shader blends the base color (column 0, or
 * the camo colors 16-19 through the camo tiler) towards column 2 by detail intensity, towards column 6 by detail
 * roughness x camo mix and towards column 5 by roughness squared x camo mix, in sRGB, then converts to linear. The mean
 * linear albedo over 512 detail texels, darkened by 0.55 x metallic (column 6 w), in CIELAB, is the row's perceived
 * color. Row values are indexed c[column * 4 + channel] here (the Lua's c[column * 4 + channel + 1]). */
#include <math.h>
#include <string.h>
#include "myc_colour.h"

#define WHITE_X 0.95047
#define WHITE_Z 1.08883

static double MycColourEpsilon(void) { return pow(6.0 / 29.0, 3); }
static double MycColourKappa(void) { return 3 * pow(6.0 / 29.0, 2); }

double myc_srgb_to_linear(double c)
{
    if (c < 0.000061) c = 0.000061;
    if (c > 0.04045) return pow(c * 0.947867 + 0.052133, 2.4);
    return c * 0.0774;
}

static double MycColourLabF(double t)
{
    if (t > MycColourEpsilon()) return pow(t, 1.0 / 3.0);
    return t / MycColourKappa() + 4.0 / 29.0;
}

MycLab myc_linear_to_lab(double r, double g, double b)
{
    r = myc_clip(r);
    g = myc_clip(g);
    b = myc_clip(b);
    double fx = MycColourLabF((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / WHITE_X);
    double fy = MycColourLabF(0.2126729 * r + 0.7151522 * g + 0.0721750 * b);
    double fz = MycColourLabF((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / WHITE_Z);
    MycLab out = {116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)};
    return out;
}

MycLab myc_srgb_to_lab(double r, double g, double b)
{
    return myc_linear_to_lab(myc_srgb_to_linear(r), myc_srgb_to_linear(g), myc_srgb_to_linear(b));
}

static double MycColourLabFinv(double t)
{
    if (t > 6.0 / 29.0) return t * t * t;
    return 3 * pow(6.0 / 29.0, 2) * (t - 4.0 / 29.0);
}

double myc_linear_to_srgb(double x)
{
    x = myc_clip(x);
    if (x > 0.0031308) return 1.055 * pow(x, 1 / 2.4) - 0.055;
    return 12.92 * x;
}

void myc_lab_to_linear(double L, double a, double b, double out[3])
{
    double fy = (L + 16) / 116;
    double fx = fy + a / 500, fz = fy - b / 200;
    double x = MycColourLabFinv(fx) * WHITE_X, y = MycColourLabFinv(fy), z = MycColourLabFinv(fz) * WHITE_Z;
    out[0] = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    out[1] = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    out[2] = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
}

void myc_lab_to_srgb(double L, double a, double b, double out[3])
{
    double lin[3];
    myc_lab_to_linear(L, a, b, lin);
    out[0] = myc_linear_to_srgb(lin[0]);
    out[1] = myc_linear_to_srgb(lin[1]);
    out[2] = myc_linear_to_srgb(lin[2]);
}

static double MycColourMeanHue(double h1p, double h2p, int zero)
{
    double hsum = h1p + h2p;
    if (zero) return hsum;
    if (fabs(h1p - h2p) > 180) return hsum < 360 ? (hsum + 360) / 2 : (hsum - 360) / 2;
    return hsum / 2;
}

double myc_de2000(double L1, double a1, double b1, double L2, double a2, double b2)
{
    double C1 = sqrt(a1 * a1 + b1 * b1), C2 = sqrt(a2 * a2 + b2 * b2);
    double Cm7 = pow((C1 + C2) / 2, 7);
    double G = 0.5 * (1 - sqrt(Cm7 / (Cm7 + pow(25, 7))));
    double a1p = (1 + G) * a1, a2p = (1 + G) * a2;
    double C1p = sqrt(a1p * a1p + b1 * b1), C2p = sqrt(a2p * a2p + b2 * b2);
    double h1p = myc_mod(myc_deg(atan2(b1, a1p)), 360);
    double h2p = myc_mod(myc_deg(atan2(b2, a2p)), 360);
    int zero = C1p * C2p == 0;
    double dhp = h2p - h1p;
    if (dhp > 180) dhp = dhp - 360;
    else if (dhp < -180) dhp = dhp + 360;
    if (zero) dhp = 0;
    double dHp = 2 * sqrt(C1p * C2p) * sin(myc_rad(dhp / 2));
    double Lpm = (L1 + L2) / 2, Cpm = (C1p + C2p) / 2;
    double hpm = MycColourMeanHue(h1p, h2p, zero);
    double T = 1 - 0.17 * cos(myc_rad(hpm - 30)) + 0.24 * cos(myc_rad(2 * hpm)) + 0.32 * cos(myc_rad(3 * hpm + 6)) -
               0.20 * cos(myc_rad(4 * hpm - 63));
    double dtheta = 30 * exp(-(pow((hpm - 275) / 25, 2)));
    double Cpm7 = pow(Cpm, 7);
    double Rc = 2 * sqrt(Cpm7 / (Cpm7 + pow(25, 7)));
    double Sl = 1 + 0.015 * pow(Lpm - 50, 2) / sqrt(20 + pow(Lpm - 50, 2));
    double Sc = 1 + 0.045 * Cpm, Sh = 1 + 0.015 * Cpm * T;
    double Rt = -sin(myc_rad(2 * dtheta)) * Rc;
    double l = (L2 - L1) / Sl, c = (C2p - C1p) / Sc, h = dHp / Sh;
    return sqrt(l * l + c * c + h * h + Rt * c * h);
}

void myc_seen(const double cal[6], double r, double g, double b, int soft, double out[3])
{
    double dr = myc_max(cal[0] * r, 0), dg = myc_max(cal[1] * g, 0), db = myc_max(cal[2] * b, 0);
    double w = 1;
    if (!soft)
    {
        MycLab lab = myc_linear_to_lab(dr, dg, db);
        w = myc_min(myc_max(1 - sqrt(lab.a * lab.a + lab.b * lab.b) / MYC_GLOSS_C, 0), 1);
    }
    out[0] = myc_max(dr + w * cal[3], 0);
    out[1] = myc_max(dg + w * cal[4], 0);
    out[2] = myc_max(db + w * cal[5], 0);
}

int myc_is_soft(const double* c) { return fabs(c[3] - 1) < 0.5 && fabs(c[32]) < 0.05; }

MycLab myc_with_gloss(double L, double a, double b, const double cal[6])
{
    int neutral = sqrt(a * a + b * b) < MYC_GLOSS_TINT_C;
    double w = myc_min(myc_max(1 - sqrt(a * a + b * b) / MYC_GLOSS_C, 0), 1);
    double lin[3];
    myc_lab_to_linear(L, a, b, lin);
    MycLab g = myc_linear_to_lab(myc_max(lin[0] + w * cal[3], 0), myc_max(lin[1] + w * cal[4], 0),
        myc_max(lin[2] + w * cal[5], 0));
    double gc = sqrt(g.a * g.a + g.b * g.b);
    if (neutral && gc > MYC_GLOSS_TINT_C)
    {
        g.a = g.a * (MYC_GLOSS_TINT_C / gc);
        g.b = g.b * (MYC_GLOSS_TINT_C / gc);
    }
    return g;
}

/* ---- the model ---------------------------------------------------------------------------------------------------- */

void myc_model_init(MycModel* model, const double* const* detail, int detail_layers, const double* const* camo,
    int camo_layers)
{
    memset(model, 0, sizeof *model);
    model->detail_layers = detail_layers < MYC_MAX_LAYERS ? detail_layers : MYC_MAX_LAYERS;
    model->camo_layers = camo_layers < MYC_MAX_LAYERS ? camo_layers : MYC_MAX_LAYERS;
    for (int i = 0; i < model->detail_layers; i++) model->detail[i] = detail[i];
    for (int i = 0; i < model->camo_layers; i++) model->camo[i] = camo[i];
}

void myc_row_values(const float* values, int width, int row, double* out)
{
    const float* base = values + (size_t)row * (size_t)width * 4u;
    for (int k = 0; k < width * 4; k++) out[k] = base[k];
}

/* Python's int() then % n for a float layer index. */
static int MycColourLayer(double x, int n)
{
    double i = x >= 0 ? floor(x) : ceil(x);
    return (int)myc_mod(i, n);
}

/* The camo-blended sample color (into rgb) and the camo mix of sample i. */
static double MycColourCamo(const double* c, const double* s, int i, double md0, double md1, double rgb[3])
{
    double m0 = myc_clip((s[i * 4] - 0.5) * c[84] + c[85]);
    double m1 = myc_clip((s[i * 4 + 1] - 0.5) * c[84] + c[85]);
    double m2 = myc_clip((s[i * 4 + 2] - 0.5) * c[84] + c[85]);
    double r = ((c[64] * (1 - m0) + c[68] * m0) * (1 - m1) + c[72] * m1) * (1 - m2) + c[76] * m2;
    double g = ((c[65] * (1 - m0) + c[69] * m0) * (1 - m1) + c[73] * m1) * (1 - m2) + c[77] * m2;
    double b = ((c[66] * (1 - m0) + c[70] * m0) * (1 - m1) + c[74] * m1) * (1 - m2) + c[78] * m2;
    if (c[3] != 1.0)
    {
        double mix = myc_clip(md0 * c[71] + md1 * c[75] - c[83]);
        rgb[0] = r * (1 - mix) + c[0] * mix;
        rgb[1] = g * (1 - mix) + c[1] * mix;
        rgb[2] = b * (1 - mix) + c[2] * mix;
        return mix;
    }
    rgb[0] = r;
    rgb[1] = g;
    rgb[2] = b;
    return 1;
}

/* A sample's sRGB color: the row's color rgb (its base, or its camo blend of mix) through the detail's intensity and
 * roughness at the detail sample's controls less 0.5 (md0, md1). */
static void MycColourShade(const double* c, double md0, double md1, double mix, double rgb[3])
{
    double rough = myc_clip(md0 * c[16] + md1 * c[17] + c[7]);
    double intensity = myc_clip(md0 * c[12] + md1 * c[13] + c[6]);
    double cr = rough * mix;
    double cr2 = cr * rough;
    double r = rgb[0], g = rgb[1], b = rgb[2];
    r = r + intensity * (c[8] - r);
    g = g + intensity * (c[9] - g);
    b = b + intensity * (c[10] - b);
    r = r + cr * (c[24] - r);
    g = g + cr * (c[25] - g);
    b = b + cr * (c[26] - b);
    rgb[0] = r + cr2 * (c[20] - r);
    rgb[1] = g + cr2 * (c[21] - g);
    rgb[2] = b + cr2 * (c[22] - b);
}

/* A detail layer's distinct samples: first[i], the first sample whose controls (z, w) are sample i's; firsts, those
 * first samples in order (a NaN control is no key: its sample stands alone). */
static void MycColourDistinct(MycModel* m, int layer)
{
    if (m->distinct_made[layer]) return;
    const double* d = m->detail[layer];
    int n = 0;
    for (int i = 0; i < MYC_SAMPLES; i++)
    {
        double z = d[i * 4 + 2], w = d[i * 4 + 3];
        int j = -1;
        if (z == z && w == w)
            for (int k = 0; k < n && j < 0; k++)
            {
                int f = m->firsts[layer][k];
                if (d[f * 4 + 2] == z && d[f * 4 + 3] == w) j = f;
            }
        if (j < 0)
        {
            j = i;
            m->firsts[layer][n++] = (int16_t)i;
        }
        m->first[layer][i] = (int16_t)j;
    }
    m->nfirsts[layer] = n;
    m->distinct_made[layer] = 1;
}

/* Every sample shaded and linearized (camo: its own color at nearly every sample). */
static void MycColourEach(const double* c, const double* d, const double* s, double out[3])
{
    double sr = 0, sg = 0, sb = 0;
    for (int i = 0; i < MYC_SAMPLES; i++)
    {
        double md0 = 0, md1 = 0, rgb[3];
        if (d != NULL) { md0 = d[i * 4 + 2] - 0.5; md1 = d[i * 4 + 3] - 0.5; }
        double mix = MycColourCamo(c, s, i, md0, md1, rgb);
        MycColourShade(c, md0, md1, mix, rgb);
        sr = sr + myc_srgb_to_linear(rgb[0]);
        sg = sg + myc_srgb_to_linear(rgb[1]);
        sb = sb + myc_srgb_to_linear(rgb[2]);
    }
    out[0] = sr / MYC_SAMPLES;
    out[1] = sg / MYC_SAMPLES;
    out[2] = sb / MYC_SAMPLES;
}

/* Without camo: each distinct sample color linearized once, the sums still over all samples in order. */
static void MycColourDetail(MycModel* m, const double* c, int layer, double out[3])
{
    static double lin_r[MYC_SAMPLES], lin_g[MYC_SAMPLES], lin_b[MYC_SAMPLES]; /* one job at a time */
    const double* d = m->detail[layer];
    MycColourDistinct(m, layer);
    for (int k = 0; k < m->nfirsts[layer]; k++)
    {
        int i = m->firsts[layer][k];
        double rgb[3] = {c[0], c[1], c[2]};
        MycColourShade(c, d[i * 4 + 2] - 0.5, d[i * 4 + 3] - 0.5, 1, rgb);
        lin_r[i] = myc_srgb_to_linear(rgb[0]);
        lin_g[i] = myc_srgb_to_linear(rgb[1]);
        lin_b[i] = myc_srgb_to_linear(rgb[2]);
    }
    double sr = 0, sg = 0, sb = 0;
    for (int i = 0; i < MYC_SAMPLES; i++)
    {
        int j = m->first[layer][i];
        sr = sr + lin_r[j];
        sg = sg + lin_g[j];
        sb = sb + lin_b[j];
    }
    out[0] = sr / MYC_SAMPLES;
    out[1] = sg / MYC_SAMPLES;
    out[2] = sb / MYC_SAMPLES;
}

void myc_albedo(MycModel* m, const double* c, double out[3])
{
    int layer = c[3] <= 3.0 ? MycColourLayer(c[4], m->detail_layers) : -1;
    const double* d = layer >= 0 ? m->detail[layer] : NULL;
    const double* s = c[87] >= 0.0 ? m->camo[MycColourLayer(c[87], m->camo_layers)] : NULL;
    if (s != NULL) { MycColourEach(c, d, s, out); return; }
    if (d == NULL)
    {
        double rgb[3] = {c[0], c[1], c[2]};
        MycColourShade(c, 0, 0, 1, rgb);
        double r = myc_srgb_to_linear(rgb[0]), g = myc_srgb_to_linear(rgb[1]), b = myc_srgb_to_linear(rgb[2]);
        double sr = 0, sg = 0, sb = 0;
        for (int i = 0; i < MYC_SAMPLES; i++) { sr = sr + r; sg = sg + g; sb = sb + b; }
        out[0] = sr / MYC_SAMPLES;
        out[1] = sg / MYC_SAMPLES;
        out[2] = sb / MYC_SAMPLES;
        return;
    }
    MycColourDetail(m, c, layer, out);
}

MycLab myc_albedo_lab(MycModel* m, const double* c)
{
    double rgb[3];
    myc_albedo(m, c, rgb);
    return myc_linear_to_lab(rgb[0], rgb[1], rgb[2]);
}

MycLab myc_perceived_of(const double* c, double r, double g, double b, double* metallic)
{
    double metal = myc_clip(c[27]);
    double dark = 1 - MYC_METAL_DARKEN * metal;
    if (metallic != NULL) *metallic = metal;
    return myc_linear_to_lab(r * dark, g * dark, b * dark);
}

MycLab myc_perceived(MycModel* m, const double* c)
{
    double rgb[3];
    myc_albedo(m, c, rgb);
    return myc_perceived_of(c, rgb[0], rgb[1], rgb[2], NULL);
}

MycLab myc_look_of(double r, double g, double b, const double cal[6], int soft)
{
    double seen[3];
    myc_seen(cal, r, g, b, soft, seen);
    return myc_linear_to_lab(seen[0], seen[1], seen[2]);
}

MycLab myc_look(MycModel* m, const double* c, const double cal[6], int soft)
{
    double rgb[3];
    myc_albedo(m, c, rgb);
    return myc_look_of(rgb[0], rgb[1], rgb[2], cal, soft);
}

MycRowInfo myc_row_info(MycModel* m, const float* values, int width, int row)
{
    static double c[MYC_MAX_COLUMNS * 4]; /* one job at a time (the worker) */
    memset(c, 0, sizeof c);
    myc_row_values(values, width < MYC_MAX_COLUMNS ? width : MYC_MAX_COLUMNS, row, c);
    double rgb[3];
    myc_albedo(m, c, rgb);
    double metallic = myc_clip(c[27]);
    double dark = 1 - MYC_METAL_DARKEN * metallic;
    MycLab lab = myc_linear_to_lab(rgb[0] * dark, rgb[1] * dark, rgb[2] * dark);
    MycRowInfo info = {lab.L, lab.a, lab.b, c[3], rgb[0], rgb[1], rgb[2], metallic > 0.5, c[87] >= 0, metallic >= MYC_METAL_FULL};
    return info;
}
