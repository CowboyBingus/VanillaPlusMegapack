/* Mod Options Menu: option rows and category pages (the Lua's rows.lua). A category's rows are built into the game's own
 * rows on the shown category's panel, from MOM's setting descriptors, then checked and polled every frame the MODS tab
 * shows. */
#include <math.h>
#include "mom.h"

#define ROW_ARRAY 144000u
/* Category panels, in category order. Each family keeps its row count, layout and settings pointer at its own offsets;
 * all panels share the row array. */
#define FAMILY_SIMPLE 0
#define FAMILY_LARGE 1
#define FAMILY_ACCESS 2
typedef struct Panel { uint32_t offset; int family; uint32_t selected; } Panel;
static const Panel kPanels[8] = {
    {1150848u, FAMILY_SIMPLE, 2872u}, /* GAMEPLAY */
    {1179528u, FAMILY_LARGE, 33296u}, /* DISPLAY */
    {1253248u, FAMILY_LARGE, 33296u}, /* GRAPHICS */
    {1287376u, FAMILY_SIMPLE, 2872u}, /* AUDIO */
    {1153728u, FAMILY_SIMPLE, 2872u}, /* HUD */
    {1156616u, FAMILY_ACCESS, 22392u}, /* ACCESSIBILITY */
    {1290256u, FAMILY_SIMPLE, 2880u}, /* CONTROLLER */
    {1293152u, FAMILY_SIMPLE, 2872u}, /* MOUSE & KEYBOARD */
};
typedef struct Family { uint32_t count, x, gap, height, settings, scrolls; } Family; /* height 0: none */
static const Family kFamilies[3] = {
    {2832u, 2836u, 2840u, 2844u, 2856u, 2830u},
    {33256u, 33260u, 33264u, 33268u, 33280u, 33254u},
    {22352u, 22356u, 22360u, 0u, 22376u, 22350u},
};
#define PANEL_ROWS 2816u
#define PANEL_CONTAINER 544u
#define PANEL_SCROLL 816u
#define SCROLL_POSITION 1976u
#define VIEW_HEIGHT 806.0
#define ROW_HEIGHT 64.0
#define GAP_HEIGHT 32.0
/* Option rows (31464 bytes each). */
#define ROW_STRIDE 31464u
#define ROW_TEXT 3992u
#define ROW_SELECTOR 16016u
#define ROW_VALUE_TEXT 16832u
#define ROW_INDEX 29068u
#define ROW_SLIDER 29176u
#define ROW_SLIDER_VALUE 31408u
#define ROW_SETTING 31428u
#define ROW_CHOICE_COUNT 29072u /* the selector's choice count and label IDs */
#define ROW_CHOICES 29080u

static const MomVec2 kPivot = {0.5f, 1.0f}; /* the row pivot and anchor */
/* Every panel build first resets all rows; the reset loads both rectangles with movaps, so they are 16-byte aligned. */
static _Alignas(16) const float kZeroRect[4] = {0, 0, 0, 0};
static int g_generation;

void mom_rows_reset(void) { g_generation = 0; }

/* ---- native rows ------------------------------------------------------------------------------------------------- */

static double RowValue(const MomEntry* entry)
{
    if (entry->item->kind == VPM_SLIDER) return mom_getf(entry->row + ROW_SLIDER_VALUE);
    return mom_get32(entry->row + ROW_INDEX);
}

/* The value a row holds: 0 when the item cannot take it (a slider at NaN or an infinity, a selector index past the
 * choices). The player's input never makes one; the game or another mod could. */
static int DecodeRow(const MomItem* item, double raw, double* value)
{
    if (item->kind == VPM_TOGGLE) { *value = raw == 1 ? 1 : 0; return 1; }
    if (item->kind == VPM_CHOICE)
    {
        if (!(raw < item->choiceCount)) return 0;
        *value = raw + 1;
        return 1;
    }
    return mom_snap(item, raw, value);
}

/* Custom choice words share the '#COUNT' template, so the shown word is the value widget's argument. */
static void ShowChoice(const MomEntry* entry)
{
    const MomItem* item = entry->item;
    if (item->kind != VPM_CHOICE) return;
    uint32_t index = mom_get32(entry->row + ROW_INDEX);
    if (index < (uint32_t)item->choiceCount && item->labels[index] == MOM_TEXT_TEMPLATE)
        mom_show_text(entry->row + ROW_VALUE_TEXT, item->choices[index]);
}

void mom_apply_value(MomEntry* entry, double value)
{
    const MomItem* item = entry->item;
    if (item->kind == VPM_SLIDER) mom_native.set_slider(entry->row + ROW_SLIDER, (float)value);
    else
    {
        uint32_t index = item->kind == VPM_TOGGLE ? (value != 0 ? 1u : 0u) : (uint32_t)(value - 1);
        mom_native.set_choice(entry->row + ROW_SELECTOR, index);
        ShowChoice(entry);
    }
    entry->raw = RowValue(entry);
}

/* The large panels finish inline in their builders; this is the same sequence. */
static void FinishLarge(uintptr_t panel, const Family* family, uint32_t count, double height)
{
    uintptr_t scroll = panel + PANEL_SCROLL;
    if (count == 0)
    {
        mom_native.set_opacity(scroll, 0);
        mom_put8(panel + family->scrolls, 0);
        return;
    }
    mom_native.scroll_thumb(scroll, (float)fmin(1, VIEW_HEIGHT / height));
    mom_native.scroll_extent(scroll, (float)(height - VIEW_HEIGHT));
    if (height > VIEW_HEIGHT)
    {
        mom_native.set_opacity(scroll, 1);
        mom_put8(panel + family->scrolls, 1);
        return;
    }
    mom_native.set_opacity(scroll, 0);
    if (mom_getf(scroll + SCROLL_POSITION) != 0)
    {
        mom_putf(scroll + SCROLL_POSITION, 0);
        mom_native.scroll_reset(scroll);
    }
    mom_put8(panel + family->scrolls, 0);
}

static void FinishPanel(uintptr_t panel, int name)
{
    const Family* family = &kFamilies[name];
    uint32_t count = mom_get32(panel + family->count);
    double height = count * ROW_HEIGHT - mom_getf(panel + family->gap);
    if (family->height != 0) mom_putf(panel + family->height, (float)height);
    if (name == FAMILY_SIMPLE) { mom_native.finish_simple(panel); return; }
    if (name == FAMILY_ACCESS) { mom_native.finish_access(panel); return; }
    FinishLarge(panel, family, count, height);
}

/* ---- category pages ---------------------------------------------------------------------------------------------- */

/* Every panel build first releases all rows, last to first, which detaches them from whichever panel listed them. */
static void ReleaseRows(uintptr_t rows)
{
    for (int i = MOM_MAX_ROWS - 1; i >= 0; i--)
    {
        uintptr_t row = rows + ROW_STRIDE * (uint32_t)i;
        mom_native.row_reset(row, kZeroRect, kZeroRect);
        mom_native.row_release(row);
    }
}

/* The category's rows from the first, at the panel builders' positions and gaps: native row initialisation from the
 * item's descriptor, the row's text and its value. Returns the summed gap. */
static double BuildRows(MomPage* page, uintptr_t panel, uintptr_t rows, uintptr_t settings, const MomCategory* category)
{
    double gap = 0;
    for (int position = 0; position < page->count; position++)
    {
        const MomItem* item = category->items[position];
        if (item->gap && position > 0) gap -= GAP_HEIGHT;
        uintptr_t row = rows + ROW_STRIDE * (uint32_t)position;
        mom_native.row_init(row, (MomVec2){0, (float)(position * -ROW_HEIGHT + gap)}, kPivot, kPivot, 10, settings,
            item->descriptor, 1);
        mom_native.add_child(panel + PANEL_CONTAINER, row);
        mom_show_text(row + ROW_TEXT, item->label);
        MomEntry* entry = &page->entries[position];
        entry->row = row;
        entry->item = item;
        mom_apply_value(entry, mom_shown(item));
    }
    return gap;
}

/* Replaces the rows the game built for category `index` with the items of the category on that button (or the page
 * control's row), following the panel builders: released rows, native row initialisation from a descriptor, the same
 * positions and gaps, then the panel's own finishing layout. */
int mom_build_page(MomView* view, uint32_t index)
{
    if (index >= 8) return 0;
    const Panel* spec = &kPanels[index];
    const Family* family = &kFamilies[spec->family];
    uintptr_t panel = view->content + spec->offset;
    uintptr_t rows = (uintptr_t)mom_get64(panel + PANEL_ROWS);
    if (rows != view->content + ROW_ARRAY) return 0;
    uintptr_t settings = (uintptr_t)mom_get64(panel + family->settings);
    if (!mom_valid_pointer(settings)) settings = 0;
    const MomCategory* category = index < MOM_MOD_BUTTONS ? view->buttons[index] : NULL;
    MomPage* page = &view->page;
    memset(page, 0, sizeof *page);
    page->index = (int)index;
    page->count = category != NULL ? (category->count < MOM_MAX_ROWS ? category->count : MOM_MAX_ROWS) : 0;
    page->generation = ++g_generation;
    ReleaseRows(rows);
    double gap = category != NULL ? BuildRows(page, panel, rows, settings, category) : 0;
    mom_put32(panel + family->count, (uint32_t)page->count);
    mom_putf(panel + family->x, 0);
    mom_putf(panel + family->gap, (float)gap);
    if (mom_get32(panel + spec->selected) >= (uint32_t)page->count) mom_put32(panel + spec->selected, 0);
    FinishPanel(panel, spec->family);
    view->hasPage = 1;
    return 1;
}

/* The page is intact while the panel lists exactly its rows and each still shows its item; a revert or device change
 * rebuilds the panel natively, and the DISPLAY panel's settings reload rewrites rows 8 and 11 in place (their choice
 * lists), so selectors check their choices too. */
int mom_page_intact(const MomView* view)
{
    const MomPage* page = &view->page;
    const Panel* spec = &kPanels[page->index];
    uintptr_t panel = view->content + spec->offset;
    if (mom_get32(panel + kFamilies[spec->family].count) != (uint32_t)page->count) return 0;
    for (int i = 0; i < page->count; i++)
    {
        uintptr_t row = page->entries[i].row;
        const MomItem* item = page->entries[i].item;
        if (mom_get32(row + ROW_SETTING) != MOM_INERT_SETTING || !mom_shows_text(row + ROW_TEXT, item->label)) return 0;
        if (item->kind != VPM_SLIDER && (mom_get32(row + ROW_CHOICE_COUNT) != (uint32_t)item->choiceCount ||
                                            mom_get32(row + ROW_CHOICES) != item->labels[0]))
            return 0;
    }
    return 1;
}

/* A row the player changed: the page control's row turns the page, an item's row becomes a pending edit. */
static void TakeRow(MomView* view, MomEntry* entry, double raw, double value)
{
    entry->raw = raw;
    ShowChoice(entry);
    if (entry->item->turn) mom_turn_page(view, (int)value);
    else mom_set_pending(entry->item, value);
}

/* A row value the item cannot take is refused: the row is set back to the value it showed, once. A row that stays at
 * NaN after that compares unequal to itself on every frame, so it is left alone instead of written again each frame.
 * lint: per-frame */
void mom_poll_page(MomView* view)
{
    for (int i = 0; i < view->page.count && view->hasPage; i++)
    {
        MomEntry* entry = &view->page.entries[i];
        double raw = RowValue(entry), value;
        if (raw == entry->raw) continue;
        if (DecodeRow(entry->item, raw, &value)) TakeRow(view, entry, raw, value);
        else if (raw == raw || entry->raw == entry->raw) mom_apply_value(entry, mom_shown(entry->item));
    }
}

/* The page entry on the row the panel has selected (hovered with the mouse), the same row the game's own description
 * follows; -1 when none. */
int mom_selected_entry(const MomView* view)
{
    if (!view->hasPage) return -1;
    const Panel* spec = &kPanels[view->page.index];
    uint32_t index = mom_get32(view->content + spec->offset + spec->selected);
    return index < (uint32_t)view->page.count ? (int)index : -1;
}
