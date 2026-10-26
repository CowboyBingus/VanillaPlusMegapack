/* Mod Options Menu's files share this (the Lua's `mom` table and `state`): the model of what the MODS tab shows, the
 * view of an open MODS tab, the escape menu's layout and the plain loads and stores on its screen object.
 *
 * Files (the Lua's, by the same names): native.c game.dll's functions and labels; text.c texts (UTF-8 checks, upper
 * case, one buffer per distinct text); model.c the rows each category lists, over the core's options and the pack's
 * switches (options.lua's presentation part); widgets.c text widgets, the MODS tab, category buttons and the
 * description box; rows.c option rows and category pages; view.c the idle gate, entering, keeping and leaving the MODS
 * tab, apply and the UNAPPLIED CHANGES dialog; mod_options_menu.c the component and its tick. */
#ifndef MOM_H
#define MOM_H

#include <stdint.h>
#include <string.h>
#include "../../core/vpm.h"
#include "native.h"

/* ---- limits (the game's widgets) ------------------------------------------------------------------------------- */

#define MOM_MAX_ROWS 32        /* the shared row array */
#define MOM_CATEGORIES 9       /* the OPTIONS content's category buttons; the ninth (ACCOUNT) opens another screen */
#define MOM_MOD_BUTTONS 8
#define MOM_PAGE_MODS 7        /* past 8 categories: 7 per page and the page control on the 8th button */
#define MOM_MAX_CHOICES 16     /* the game's selector limit, so at most 16 pages */
#define MOM_MAX_MODS (MOM_PAGE_MODS * MOM_MAX_CHOICES)
#define MOM_MAX_OPTIONS 256    /* the core's registry (VPM_MAX_OPTIONS) */
#define MOM_MAX_SWITCHES 32    /* the core's components (VPM_MAX_COMPONENTS) */
#define MOM_MAX_KEYS (MOM_MAX_OPTIONS + MOM_MAX_SWITCHES)
#define MOM_NO_KEY (-1)        /* the page control's row: never an edit */

#define MOM_TEXT_TEMPLATE 0xC67C7FAFu /* '#COUNT': a pure tag template, so a string COUNT argument shows any text */
#define MOM_INERT_SETTING 139u        /* setting 139 (a BINDINGS activation type): its value type is none */

/* ---- the model (model.c) --------------------------------------------------------------------------------------- */

/* One row a category lists: an option of the core's registry, a component's switch, or the page control. */
typedef struct MomItem
{
    VpmOption* option;          /* an option, or NULL */
    VpmComponent* component;    /* a switch's component, or NULL */
    int key;                    /* its pending edit's slot (MOM_NO_KEY: the page control) */
    int turn;                   /* the page control: turning it turns the category pages */
    double value;               /* the page control's value: the page shown */
    uint32_t kind;              /* VPM_TOGGLE, VPM_CHOICE, VPM_SLIDER */
    const char* label;          /* texts as shown (text.c buffers) */
    const char* description;    /* or NULL */
    int choiceCount;            /* a toggle's 2 (OFF, ON) or a choice's */
    const char* choices[MOM_MAX_CHOICES];
    uint32_t labels[MOM_MAX_CHOICES]; /* a choice's native label: the game's own word, or MOM_TEXT_TEMPLATE */
    double min, max, step;
    int decimals;               /* a slider's shown decimal places */
    int gap;
    const uint8_t* descriptor;  /* the 216-byte setting descriptor its row is built from (16-byte aligned) */
} MomItem;

/* A category: a component's options, the pack's switches, or the page control. */
typedef struct MomCategory
{
    const char* title;
    int sequence;               /* registration order, for categories with the same title */
    VpmComponent* owner;        /* the component whose options these are; NULL for the switches and the page control */
    int count;
    const MomItem* items[MOM_MAX_ROWS];
    int pages;                  /* the page control's */
} MomCategory;

void mom_model_reset(void);
/* The model for the options registered now (rebuilt when the registry grew), and its revision (the option count). */
void mom_model_update(void);
int mom_model_revision(void);
/* The categories in button order (alphabetical, then registration order): their count. */
int mom_model_categories(const MomCategory** out, int capacity);
/* The page control for `count` categories (mom.modsPage clamped to its pages), and the page turned to `page`. */
const MomCategory* mom_page_control(int count);
void mom_page_turned(int page);

/* Values: the applied value, what a row shows (the pending edit, else the applied value), edits and apply. */
double mom_applied(const MomItem* item);
double mom_shown(const MomItem* item);
void mom_set_pending(const MomItem* item, double value);
int mom_apply_pending(void);
void mom_drop_pending(void);
/* A slider's value snapped to its step and shown decimals: 1, or 0 for NaN and the infinities. */
int mom_snap(const MomItem* item, double value, double* out);

/* ---- texts (text.c) -------------------------------------------------------------------------------------------- */

void mom_text_reset(void);
/* The one buffer holding this text (the widgets compare a shown text by its address); it lives for the session. */
const char* mom_intern(const char* text);
/* A registered text as shown: control characters as spaces, trimmed; NULL when it is longer than `limit`
 * characters, empty, or not valid UTF-8 without control characters. */
const char* mom_text_resolve(const char* text, size_t limit);
/* Upper case in every script the game's font has (Latin, Greek, Cyrillic), into a text buffer. */
const char* mom_text_upper(const char* text);
/* {page} and {pages} in a template replaced by the numbers. */
const char* mom_text_page(const char* format, int page, int pages);

/* ---- the open MODS view (view.c) ------------------------------------------------------------------------------ */

#define MOM_DESCRIBED_NEVER (-2) /* the description box not set yet in this view */
#define MOM_DESCRIBED_NONE (-1)  /* no entry selected */

typedef struct MomEntry
{
    uintptr_t row;
    const MomItem* item;
    double raw;                 /* the value the row held when last seen: a slider's float, a selector's index */
} MomEntry;

typedef struct MomPage
{
    int index;                  /* the category (panel) it is built on */
    int count;
    int generation;             /* a new page for every build: the description follows the entry, not its index */
    MomEntry entries[MOM_MAX_ROWS];
} MomPage;

typedef struct MomView
{
    uintptr_t screen, content;
    int revision;               /* the model's when listed */
    uint32_t saved;             /* the category OPTIONS showed, given back on leaving */
    int64_t described;          /* the entry the description box shows: MOM_DESCRIBED_... or generation * 64 + index */
    uint8_t unapplied;          /* the game's unapplied-changes flag as last written */
    int dialog;                 /* the UNAPPLIED CHANGES dialog as watched (view.c) */
    int modCount;
    const MomCategory* mods[MOM_MAX_MODS];
    const MomCategory* control; /* the page control, past 8 categories */
    const MomCategory* buttons[MOM_MOD_BUTTONS]; /* each button's category, NULL when none */
    int hasPage;
    MomPage page;
} MomView;

#define MOM_MENU_CLOSED 0
#define MOM_MENU_COVERED 1
#define MOM_MENU_OPEN 2
/* The idle gate: whether the escape menu is open on top (*screen set), covered by another screen, or closed. */
int mom_escape_menu(uintptr_t* screen);
void mom_enter_view(uintptr_t screen);
void mom_leave_view(MomView* view);
void mom_maintain_view(MomView* view);
void mom_update_apply(MomView* view);
void mom_update_visuals(MomView* view, float dt);
void mom_neutralize_dialog(MomView* view);
void mom_turn_page(MomView* view, int page);
void mom_select_category(uintptr_t content, uint32_t shown, uint32_t target);
int mom_valid_pointer(uint64_t value);

/* ---- rows and pages (rows.c) ---------------------------------------------------------------------------------- */

void mom_rows_reset(void);
int mom_build_page(MomView* view, uint32_t index);
int mom_page_intact(const MomView* view);
void mom_poll_page(MomView* view);
/* The page's entry on the row the panel has selected (-1 none). */
int mom_selected_entry(const MomView* view);
void mom_apply_value(MomEntry* entry, double value);

/* ---- widgets (widgets.c) --------------------------------------------------------------------------------------- */

#define MOM_TAB_BAR 1248u
#define MOM_TAB_CURRENT 57452u
#define MOM_MODS_TAB 3u
#define MOM_OPTIONS_TAB 2u

void mom_show_text(uintptr_t widget, const char* text);
int mom_shows_text(uintptr_t widget, const char* text);
int mom_ensure_mods_tab(uintptr_t screen);
void mom_label_categories(const MomView* view);
void mom_restore_categories(uintptr_t content);
void mom_describe(MomView* view, int entry);
void mom_release_description(uintptr_t content);

/* ---- the component's state (mod_options_menu.c; Start resets it) ------------------------------------------------ */

typedef struct MomState
{
    VpmComponent* self;
    int hasView;
    MomView view;
    int modsPage;               /* the category page shown, kept for the session */
    int modsTabLogged;
    const char* modsTitle;      /* MOM's own texts */
    const char* emptyText;
    int pendingCount;
    uint8_t pendingSet[MOM_MAX_KEYS];
    double pending[MOM_MAX_KEYS];
} MomState;
extern MomState mom;

/* ---- plain loads and stores on the escape menu's screen object --------------------------------------------------
 * The screen is in use by the game while it is on top of the UI stack, the same frames in which MOM reads and writes it
 * and hands it to native functions (the Lua's get8/get32/put32...: direct loads, no ReadProcessMemory). The idle gate
 * (view.c) checks it first through guarded reads, every frame. */

static inline uint8_t mom_get8(uintptr_t at) { uint8_t v; memcpy(&v, (const void*)at, 1); return v; }
static inline uint32_t mom_get32(uintptr_t at) { uint32_t v; memcpy(&v, (const void*)at, 4); return v; }
static inline float mom_getf(uintptr_t at) { float v; memcpy(&v, (const void*)at, 4); return v; }
static inline uint64_t mom_get64(uintptr_t at) { uint64_t v; memcpy(&v, (const void*)at, 8); return v; }
static inline void mom_put8(uintptr_t at, uint8_t v) { memcpy((void*)at, &v, 1); }
static inline void mom_put32(uintptr_t at, uint32_t v) { memcpy((void*)at, &v, 4); }
static inline void mom_putf(uintptr_t at, float v) { memcpy((void*)at, &v, 4); }

#endif
