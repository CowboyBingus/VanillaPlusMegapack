/* Know Your Constellation's panel layout (panel.lua's M.plan, M.fit, M.place, the limits, the meter and scroll
 * arithmetic): a gold-framed box hanging below the native planet, operation or briefing panel, sharing its bottom
 * stroke, above the bottom prompt row; beside the native panel when even that is too short. Pure arithmetic over a
 * measure function: kyc_panel.c measures with the engine's Gui, the tests with a fake font. Plans are made when the
 * report, the geometry or the font changes, never per frame. */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "kyc_panel.h"

const double kKycSizes[4] = {18, 16, 14, 12};
/* Body and slate (rules, empty ticks): the war-table UI shows dark colours lighter than their values, so these show
 * as the mockup's #0F141E and #3B4654 (KB war-table-gui-rendering). */
const KycColour kKycBody = {255, 6, 10, 17};
const KycColour kKycSlate = {255, 42, 53, 69};
const KycColour kKycGold = {255, 255, 185, 0};
const KycColour kKycShade = {204, 0, 0, 0};
const KycColour kKycLabelInk = {255, 255, 213, 0};
const KycColour kKycBodyInk = {255, 240, 243, 245};
const KycColour kKycMutedInk = {255, 179, 198, 205};

/* Tick and gap widths in whole pixels: fractional sizes would round to uneven gaps (ticks seen in pairs). */
void kyc_tick_pixels(double s, double* tick, double* gap)
{
    double t = floor(KYC_TICK * s + 0.5), g = floor(KYC_TICK_GAP * s + 0.5);
    *tick = t < 1 ? 1 : t;
    *gap = g < 1 ? 1 : g;
}

double kyc_meter_width(double s)
{
    double tick, gap;
    kyc_tick_pixels(s, &tick, &gap);
    return KYC_TICKS * tick + (KYC_TICKS - 1) * gap;
}

/* The scroll distance at `time` seconds into a cycle, for text `travel` units wider than its window, and the cycle's
 * length. */
double kyc_scroll_offset(double time, double travel, double s, double* period)
{
    double speed = KYC_SCROLL_SPEED * s, moving = travel / speed;
    *period = KYC_SCROLL_HOLD + moving + KYC_SCROLL_END_HOLD;
    time = time - floor(time / *period) * *period; /* the Lua's % */
    if (time < KYC_SCROLL_HOLD) return 0;
    if (time < KYC_SCROLL_HOLD + moving) return (time - KYC_SCROLL_HOLD) * speed;
    return travel;
}

/* The characters drawn at scroll offset: those wholly inside the window widened by margin on each side, where the
 * masks hide them. edge[k] is the caret before character k (1-based). Continues from (first, last) found at a smaller
 * or equal offset, or from the start when they are 0. */
void kyc_scroll_window(const double* edge, int count, double offset, double width, double margin, int* first, int* last)
{
    int f = *first > 0 ? *first : 1, l = *last > 0 ? *last : 1;
    while (f <= count && edge[f] < offset - margin) f++;
    if (l < f) l = f;
    while (l <= count && edge[l + 1] <= offset + width + margin) l++;
    *first = f;
    *last = l;
}

/* ---- plans --------------------------------------------------------------------------------------------------- */

typedef struct Builder { const KycPlanArgs* a; KycPlan* plan; double d; } Builder;

static KycItem* NewItem(Builder* b, int kind)
{
    if (b->plan->count >= KYC_PLAN_ITEMS) { kyc_fail("Forecast has too many lines"); return NULL; }
    KycItem* item = &b->plan->items[b->plan->count++];
    memset(item, 0, sizeof *item);
    item->kind = (uint8_t)kind;
    return item;
}

static int AddText(Builder* b, const char* text, size_t length, double size, double x, int role)
{
    KycPlan* p = b->plan;
    if ((size_t)p->used + length > KYC_PLAN_TEXT) return kyc_fail("Forecast text too long");
    KycItem* item = NewItem(b, KYC_ITEM_TEXT);
    if (item == NULL) return 0;
    memcpy(p->text + p->used, text, length);
    item->at = (uint16_t)p->used;
    item->length = (uint16_t)length;
    p->used += (int)length;
    item->size = size;
    item->x = x;
    item->d = b->d + size;
    item->role = (uint8_t)role;
    return 1;
}

static int Measure(Builder* b, const char* text, size_t length, double size, double* width)
{
    return b->a->measure(b->a->context, text, length, size, width);
}

/* A caption pair (left, and right-aligned) and a rule under it. */
static int Section(Builder* b, const char* left, const char* right)
{
    double s = b->a->s, caption = KYC_CAPTION * s, width;
    b->d += KYC_GAP * s;
    if (!AddText(b, left, strlen(left), caption, 0, KYC_ROLE_MUTED) || !Measure(b, right, strlen(right), caption, &width) ||
        !AddText(b, right, strlen(right), caption, b->a->width - width, KYC_ROLE_MUTED))
        return 0;
    b->d += caption * 1.2;
    KycItem* rule = NewItem(b, KYC_ITEM_RULE);
    if (rule == NULL) return 0;
    rule->d = b->d;
    rule->h = s > 1 ? s : 1;
    b->d += 3 * s;
    return 1;
}

/* The label, and the headline at the title size on one line (a wider one scrolls). */
static int Heading(Builder* b)
{
    const KycModel* m = b->a->model;
    double title = KYC_TITLE * b->a->s, width;
    if (!AddText(b, m->label, strlen(m->label), title, 0, KYC_ROLE_LABEL)) return 0;
    b->d += title * 1.3;
    if (!m->has_headline) return 1;
    size_t n = strlen(m->headline);
    if (!AddText(b, m->headline, n, title, 0, KYC_ROLE_BODY) || !Measure(b, m->headline, n, title, &width)) return 0;
    double overflow = width - b->a->width;
    if (overflow > 0)
    {
        KycItem* item = &b->plan->items[b->plan->count - 1];
        item->kind = KYC_ITEM_SCROLL;
        item->travel = overflow;
    }
    b->d += title * 1.25;
    return 1;
}

/* The large enemies, each with its meter: *fits 0 when a name would reach its meter. */
static int Large(Builder* b, double size, int shown, int* fits)
{
    const KycModel* m = b->a->model;
    double s = b->a->s, meter = kyc_meter_width(s);
    *fits = 1;
    if (shown == 0) return 1;
    if (!Section(b, m->large_caption, m->rate_caption)) return 0;
    for (int i = 0; i < shown; i++)
    {
        double width;
        size_t n = strlen(m->large[i]);
        if (!Measure(b, m->large[i], n, size, &width)) return 0;
        if (width > b->a->width - meter - 2 * KYC_GAP * s) { *fits = 0; return 1; }
        if (!AddText(b, m->large[i], n, size, 0, KYC_ROLE_BODY)) return 0;
        KycItem* item = NewItem(b, KYC_ITEM_METER);
        if (item == NULL) return 0;
        item->ticks = m->ticks[i];
        item->x = b->a->width - meter;
        item->d = b->d + size * 1.05;
        item->h = size * 0.8;
        b->d += size * KYC_ROW;
    }
    return 1;
}

/* '{count}' in text replaced by count (unknown placeholders stay), appended to out. */
static int Format(const char* text, int count, char* out, size_t size, size_t* used)
{
    char number[16];
    snprintf(number, sizeof number, "%d", count);
    for (const char* p = text; *p;)
    {
        const char* piece = strncmp(p, "{count}", 7) == 0 ? number : NULL;
        size_t n = piece != NULL ? strlen(number) : 1;
        if (*used + n + 1 > size) return kyc_fail("Forecast text too long");
        memcpy(out + *used, piece != NULL ? piece : p, n);
        *used += n;
        p += piece != NULL ? 7 : 1;
    }
    out[*used] = 0;
    return 1;
}

static int Append(char* out, size_t size, size_t* used, const char* text)
{
    size_t n = strlen(text);
    if (*used + n + 1 > size) return kyc_fail("Forecast text too long");
    memcpy(out + *used, text, n + 1);
    *used += n;
    return 1;
}

/* The small enemies' list and the "and N more" count, joined, for wrapping. */
static int ListText(const KycModel* m, int shown, int hidden, char* out, size_t size, size_t* used)
{
    const char* separator = m->separator != NULL ? m->separator : ", ";
    *used = 0;
    out[0] = 0;
    for (int i = 0; i < shown; i++)
        if ((i > 0 && !Append(out, size, used, separator)) || !Append(out, size, used, m->small[i])) return 0;
    if (hidden == 0) return 1;
    if (*used > 0 && !Append(out, size, used, separator)) return 0;
    return Format(m->more != NULL ? m->more : "and {count} more", hidden, out, size, used);
}

typedef struct SizedMeasure { Builder* b; double size; } SizedMeasure;

static int MeasureAtSize(void* context, const char* text, size_t length, double* width)
{
    SizedMeasure* m = context;
    return Measure(m->b, text, length, m->size, width);
}

static int Small(Builder* b, double size, int shown, int hidden)
{
    static char list[4096];
    static KycLine lines[128];
    const KycModel* m = b->a->model;
    size_t used;
    if (shown == 0 && hidden == 0) return 1;
    if (shown > 0 && !Section(b, m->small_caption, m->order_caption)) return 0;
    if (!ListText(m, shown, hidden, list, sizeof list, &used)) return 0;
    SizedMeasure measure = {b, size};
    int n = kyc_text_wrap(list, used, b->a->width, MeasureAtSize, &measure, lines, 128);
    if (n < 0) return 0;
    for (int i = 0; i < n; i++)
    {
        if (!AddText(b, list + lines[i].at, lines[i].length, size, 0, KYC_ROLE_BODY)) return 0;
        b->d += size * KYC_LINE;
    }
    return 1;
}

int kyc_plan(const KycPlanArgs* args, double size, int shown_large, int shown_small, KycPlan* out, int* fits)
{
    Builder b = {args, out, 0};
    const KycModel* m = args->model;
    double s = args->s, title = KYC_TITLE * s, footer = KYC_CAPTION * s;
    int large = m->large_count, small = m->small_count;
    out->count = out->used = out->bounds = out->edges_ready = 0;
    shown_large = shown_large < 0 || shown_large > large ? large : shown_large;
    shown_small = shown_small < 0 || shown_small > small ? small : shown_small;
    *fits = 0;
    if (!Heading(&b) || !Large(&b, size, shown_large, fits)) return 0;
    if (!*fits) return 1;
    if (!Small(&b, size, shown_small, (large - shown_large) + (small - shown_small))) return 0;
    b.d += KYC_GAP * s;
    if (!AddText(&b, m->footer, strlen(m->footer), footer, 0, KYC_ROLE_MUTED)) return 0;
    /* End as far below the footer's baseline as the label's capitals start below the top. */
    b.d += footer + title * (1 - KYC_CAP);
    out->size = size;
    out->height = b.d;
    *fits = b.d <= args->limit;
    return 1;
}

/* At the smallest size, the lists shortened from the end: the small enemies first, then the large. */
static int Cut(const KycPlanArgs* args, KycPlan* out, int* fits)
{
    double smallest = kKycSizes[3] * args->s;
    int large = args->model->large_count, small = args->model->small_count;
    for (int k = small - 1; k >= 0; k--)
    {
        if (!kyc_plan(args, smallest, large, k, out, fits)) return 0;
        if (*fits) return 1;
    }
    for (int k = large - 1; k >= 0; k--)
    {
        if (!kyc_plan(args, smallest, k, 0, out, fits)) return 0;
        if (*fits) return 1;
    }
    return 1;
}

int kyc_fit(const KycPlanArgs* args, int cut, KycPlan* out, int* fits)
{
    for (int i = 0; i < 4; i++)
    {
        if (!kyc_plan(args, kKycSizes[i] * args->s, -1, -1, out, fits)) return 0;
        if (*fits) return 1;
    }
    return cut ? Cut(args, out, fits) : 1;
}

/* ---- placement ----------------------------------------------------------------------------------------------- */

/* Chrome around the content: border, inset and inner padding on each side. */
static double Chrome(double s) { return 2 * (KYC_BORDER + KYC_INSET + KYC_EDGE) * s; }

double kyc_below_limit(const KycAnchor* anchor)
{
    double s = anchor->scale;
    return anchor->y + KYC_BORDER * s - KYC_BOTTOM * s - Chrome(s);
}

double kyc_side_limit(const KycAnchor* anchor, double height)
{
    double s = anchor->scale, top = height - 12 * s < anchor->y + anchor->h ? height - 12 * s : anchor->y + anchor->h;
    return top - 12 * s - Chrome(s);
}

int kyc_place(const KycAnchor* anchor, double width, double height, const KycPlan* below, const KycPlan* side,
    KycPlace* out)
{
    double s = anchor->scale;
    if (below != NULL)
    {
        double h = below->height + Chrome(s);
        *out = (KycPlace){0, anchor->x, anchor->y + KYC_BORDER * s - h, anchor->w, h};
        return 1;
    }
    if (side == NULL) return kyc_pending("Forecast exceeds viewport");
    double h = side->height + Chrome(s);
    double x = anchor->x + anchor->w + 12 * s;
    if (x + anchor->w > width - 12 * s) x = anchor->x - anchor->w - 12 * s;
    double top = height - 12 * s < anchor->y + anchor->h ? height - 12 * s : anchor->y + anchor->h;
    double y = top - h;
    if (x < 0 || y < 0) return kyc_pending("Forecast exceeds viewport");
    *out = (KycPlace){1, x, y, anchor->w, h};
    return 1;
}
