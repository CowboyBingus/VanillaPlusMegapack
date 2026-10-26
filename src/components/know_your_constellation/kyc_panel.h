/* Know Your Constellation's forecast panel (panel.lua), drawn through kyc_gui.h. */
#ifndef KYC_PANEL_H
#define KYC_PANEL_H

#include "kyc.h"
#include "kyc_gui.h"

/* UI units at scale 1 (the native frame is 533 wide). */
#define KYC_BOTTOM 56.0    /* keep the Esc / Back prompt row visible */
#define KYC_BORDER 3.0     /* the native frame: a 3-unit gold outline, a 4-unit dark gap, the body 7 units in */
#define KYC_INSET 7.0
#define KYC_PAD 22.0       /* text starts 22 units in, in line with the native panel's text above */
#define KYC_GAP 6.0
#define KYC_EDGE 5.0
#define KYC_TITLE 18.0
#define KYC_CAPTION 13.0
#define KYC_ROW 1.4        /* line pitch of meter rows and list lines, in text sizes */
#define KYC_LINE 1.3
#define KYC_CAP 0.7        /* capital height, in text sizes */
#define KYC_TICK 8.0
#define KYC_TICK_GAP 3.0
#define KYC_TICKS 10
/* Draw layers: GUI layers sort across every GUI in a world and only 0-1023 order correctly; the squad nameplates draw
 * above 1000 and below 1011 (probed in game), so the box covers them while a mission is highlighted. */
#define KYC_LAYER_SHADE 1011.0
#define KYC_LAYER_BODY 1012.0
#define KYC_LAYER_RULE 1013.0
#define KYC_LAYER_BORDER 1013.0
#define KYC_LAYER_CONTENT 1014.0
#define KYC_LAYER_MASK 1015.0
#define KYC_SCROLL_HOLD 2.0      /* a headline wider than the panel holds, scrolls to the end, holds, then resets */
#define KYC_SCROLL_END_HOLD 1.5
#define KYC_SCROLL_SPEED 40.0    /* units per second at scale 1 */

extern const double kKycSizes[4];   /* body text sizes, largest first */
extern const KycColour kKycBody, kKycSlate, kKycGold, kKycShade, kKycLabelInk, kKycBodyInk, kKycMutedInk;

#define KYC_ITEM_TEXT 0
#define KYC_ITEM_SCROLL 1
#define KYC_ITEM_RULE 2
#define KYC_ITEM_METER 3
#define KYC_ROLE_LABEL 0
#define KYC_ROLE_BODY 1
#define KYC_ROLE_MUTED 2
#define KYC_PLAN_ITEMS 192
#define KYC_PLAN_TEXT 6144
#define KYC_MAX_BOUNDS 1024 /* characters of a scrolling headline, + 1 */

/* One planned element; d is its distance below the content top (y grows downward in a plan). */
typedef struct KycItem
{
    uint8_t kind, role, ticks;
    uint16_t at, length;  /* its text in the plan's arena */
    double size, x, d, h, travel;
} KycItem;

typedef struct KycPlan
{
    int count;
    KycItem items[KYC_PLAN_ITEMS];
    int used;
    char text[KYC_PLAN_TEXT];
    double size, height;
    /* the scrolling headline's character starts (0-based byte offsets, then its length) and carets (edge[k]: before
     * character k, 1-based as the Lua's), measured once per plan */
    int bounds, edges_ready;
    uint16_t bound[KYC_MAX_BOUNDS + 1];
    double edge[KYC_MAX_BOUNDS + 2];
} KycPlan;

typedef struct KycPlace { int side; double x, y, w, h; } KycPlace;

/* A headline's scroll state: the visible window of characters [first, last) at offset. */
typedef struct KycScroll
{
    const char* text;
    const uint16_t* bound;
    const double* edge;
    int count;         /* characters */
    double size, x, y, width, margin, travel, scale, time;
    int has_offset;
    double offset;
    int first, last;   /* 0: none yet */
    KycRef id;
} KycScroll;

/* What the panel shows now (for the component's status and the tests). */
typedef struct KycPanelView
{
    KycRef gui, world;
    int has_model;
    const KycModel* model;
    int has_geometry;
    KycPlace place;
    const KycPlan* plan;
    int has_scroll;
    const KycScroll* scroll;
    int rects, texts;
    const KycRef* rect_ids;
    const KycRef* text_ids;
} KycPanelView;

typedef int (*KycSizedMeasure)(void* context, const char* text, size_t length, double size, double* width);

void kyc_panel_reset(void);
/* 1 drawn, 0 not (no route, no UI world), KYC_ERROR after an error. */
#define KYC_ERROR (-1)
int kyc_panel_show(const KycModel* model, double dt, const KycAnchor* anchor);
/* Keeps the frame and captions of the drawn report without enemy text: 1 drawn, 0 nothing to keep, KYC_ERROR. */
int kyc_panel_suspend(const KycAnchor* anchor);
/* Removes the panel (once: clearing again changes nothing). 1, or 0 after an error. */
int kyc_panel_clear(void);
const KycPanelView* kyc_panel_view(void);

/* The layout (panel.lua's M.*), for the panel and the tests. */
void kyc_tick_pixels(double s, double* tick, double* gap);
double kyc_meter_width(double s);
double kyc_scroll_offset(double time, double travel, double s, double* period);
void kyc_scroll_window(const double* edge, int count, double offset, double width, double margin, int* first, int* last);
/* Lays out a model at body size: 1 with *fits; 0 after an error. shown_large/shown_small -1: all. */
typedef struct KycPlanArgs
{
    const KycModel* model;
    KycSizedMeasure measure;
    void* context;
    double width, limit, s;
} KycPlanArgs;
int kyc_plan(const KycPlanArgs* args, double size, int shown_large, int shown_small, KycPlan* out, int* fits);
/* The largest body size that fits; with cut, the lists shortened from the end at the smallest size. */
int kyc_fit(const KycPlanArgs* args, int cut, KycPlan* out, int* fits);
double kyc_below_limit(const KycAnchor* anchor);
double kyc_side_limit(const KycAnchor* anchor, double height);
/* Where the box goes: below the native panel, else beside it (side). 0 after an error ("Forecast exceeds viewport"). */
int kyc_place(const KycAnchor* anchor, double width, double height, const KycPlan* below, const KycPlan* side,
    KycPlace* out);

#endif
