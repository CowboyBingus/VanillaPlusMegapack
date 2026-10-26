/* Clickable Scrollbars: what its files share. clickable_scrollbars.c is the runtime (install.lua and platform.lua: the
 * button, presses, held drags, the settings capture), locate.c finds the visible scrollbar's owner (locate.lua and the
 * read tape of memory.lua), model.c reads the owner's scroll model (model.lua and native.lua's arithmetic), native.c
 * checks and calls the game's scroll and input routines (native.lua). Layout and addresses: build 25480438. */
#ifndef CLICKABLE_SCROLLBARS_H
#define CLICKABLE_SCROLLBARS_H

#include <stdint.h>
#include "../../core/vpm.h"

/* The routes: which object owns the visible scrollbar, and how a drag drives it. */
#define CS_ROUTE_GRID 1u     /* an equipment grid: the Armory (registry kind 224) or the loadout picker (kind 229) */
#define CS_ROUTE_CAREER 2u   /* the Armory's Career panel */
#define CS_ROUTE_BINDINGS 3u /* the Controls page's inline list (screen 26) */
#define CS_ROUTE_SETTINGS 4u /* the Settings page's inline list (screen 1) */

/* Layout (native.lua GRID, CAREER, OPTIONS_LIST, OPTIONS_PAGES) */
#define CS_GRID_OFFSET 523752u         /* Armory controller -> its item grid */
#define CS_LOADOUT_GRID_OFFSET 864032u /* loadout controller -> its item grid */
#define CS_GRID_BAR 272u               /* grid -> its ScrollBar widget */
#define CS_GRID_THUMB 888u             /* grid -> the bar's thumb */
#define CS_GRID_SCROLL 600416u         /* float px, how far the list is scrolled */
#define CS_CAREER_OFFSET 318472u       /* Armory controller -> the Career panel */
#define CS_CAREER_LIST 2488u           /* panel -> its list container */
#define CS_CAREER_TRACK 195256u        /* panel -> its ScrollBar */
#define CS_CAREER_THUMB 195808u
#define CS_CAREER_PADDING 4.0
#define CS_OPTIONS_BAR 816u            /* options list -> its ScrollBar */
#define CS_OPTIONS_THUMB 1432u
#define CS_OPTIONS_CONTENT 544u        /* options list -> its content container */
#define CS_MAX_PIXELS 1000000.0

/* The reads that resolved an owner, in order, with the bytes each returned (memory.lua's api.tape): while every one
 * returns the same bytes, the resolution would find the same owner again. Image reads are plain loads of game.dll
 * globals (address: the RVA); the others went through vpm_read. */
#define CS_TAPE_READS 160
#define CS_TAPE_BYTES 2048u
typedef struct CsTapeRead
{
    uintptr_t address;
    uint32_t at;   /* its bytes in CsTape.bytes */
    uint16_t size;
    uint8_t image; /* a plain load inside game.dll's image */
    uint8_t ok;    /* the read succeeded (a failed read must fail again) */
} CsTapeRead;
typedef struct CsTape
{
    int count;
    int full;      /* a read did not fit: the tape proves nothing */
    uint32_t used;
    CsTapeRead reads[CS_TAPE_READS];
    uint8_t bytes[CS_TAPE_BYTES];
} CsTape;

/* An owner's identity (locate.lua's key "<controller>:<kind>:<route>"). */
typedef struct CsKey { uintptr_t owner; uint32_t kind; uint32_t route; } CsKey;

typedef struct CsBridge
{
    uint32_t route;       /* CS_ROUTE_... */
    uint32_t kind;        /* the registry kind (224, 229) or the screen id (1, 26) */
    uintptr_t controller; /* the equipment controller, or the options screen */
    uintptr_t grid;       /* the item grid, or the options list */
    uintptr_t panel;      /* the Career panel (Armory controllers only), else 0 */
    uintptr_t bar, thumb; /* the visible ScrollBar widget and its thumb */
    CsKey key;
    CsTape tape;
} CsBridge;

/* The owner's scroll model (model.lua's model table). */
typedef struct CsModel
{
    uint32_t route;
    uint32_t kind;     /* a grid's layout kind (+602052); 0 on the other routes, which compare by route */
    uint32_t columns, rows, items, selected, anchor, first, last;
    int has_range;     /* first and last were read (their block can fail on its own) */
    double content, span, value, scroll, viewport, list_x, thumb_ratio, rendered_thumb;
    double left, bottom, width, length, thumb; /* the scrollbar in the game's bottom-left pixel space */
} CsModel;

/* The track on the desktop, in pointer coordinates (model.lua's native_screen_track). */
typedef struct CsTrack { double left, right, top, length, thumb, span; } CsTrack;

/* clickable_scrollbars.c: the runtime's counters and gesture state (the Lua's state table), for the tests. */
typedef struct CsCounts
{
    uint32_t clicks, pages, drags, writes, verified, retired;
    int dragging, drag_active, failed, capture;
    const char* reason; /* the last decision: "bar_press", "native_cancelled", ... */
} CsCounts;
void cs_counts(CsCounts* out);

/* locate.c */
uintptr_t cs_pointer(uint64_t value); /* the shipped reader's pointer decode: 0 below 0x10000 or from 0x800000000000 */
/* native_resolve: the visible owner into *out with every read on its tape. 1 found; 0 with *reason. */
int cs_resolve(CsBridge* out, const char** reason);
/* native_unchanged: every read on the tape returns its bytes again. */
int cs_unchanged(const CsTape* tape);
int cs_same_key(const CsKey* a, const CsKey* b);

/* model.c */
double cs_clamp(double value, double low, double high);
double cs_abs(double value);
/* native_state: the owner's model, bounds-checked. 1 read; 0 refused with *reason. */
int cs_state(const CsBridge* bridge, CsModel* out, const char** reason);
/* native_screen_track for a client area whose top-left is at (x, y) on the desktop and whose height is height. */
void cs_screen_track(const CsModel* model, double x, double y, double height, CsTrack* out);
/* native_moved: whether the game itself moved the list (fields this component never writes). */
int cs_moved(const CsModel* before, const CsModel* after);
/* native_value_at_grab: the value that keeps the grab point under the pointer. 1 with *out; 0 none. */
int cs_value_at_grab(const CsModel* model, const CsTrack* track, double press_y, double cursor_y, double* out);

/* native.c */
/* The five game routines as reviewed (native_api's check), for vpm_when_code_ready; their addresses are bound once they
 * all match. */
const VpmCodePin* cs_routine_pins(int* count);
void cs_routines_bind(void);
/* native_apply: moves the list to value through the game's own setters. 1 with *written; 0 with *reason. */
int cs_apply(const CsBridge* bridge, const CsModel* model, double value, double* written, const char** reason);
/* native_settings_input: consumes the UI select action through the game's input routine. 1 consumed. */
int cs_settings_input(void);

#endif
