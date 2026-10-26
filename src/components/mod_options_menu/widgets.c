/* Mod Options Menu: the game's widgets the MODS tab writes besides option rows (rows.c): text widgets, the MODS tab,
 * the category buttons and the description box (the Lua's widgets.lua). */
#include "mom.h"

/* Escape menu: one tab bar over the GAME, SOCIAL and OPTIONS contents. The widget has eight tab buttons; the screen asks
 * for three at initialisation. */
#define TAB_COUNT 57448u
#define TAB_LABELS 57320u
#define TAB_BUTTON_STATE 11004u
#define TAB_BUTTON_ACTIVE 11021u
#define TAB_TEXT 8296u
#define TAB_STRIDE 3400u
#define NATIVE_TABS 3u
/* OPTIONS content: a column of nine category buttons and one panel per category. */
#define CATEGORY_BUTTON 816u
#define CATEGORY_STRIDE 14920u
#define CATEGORY_TEXT 1928u
/* Description box beside the rows: a frame, a title and a body text. The game fills it from the selected row's setting
 * descriptor and caches that setting (requested, shown); 156 means none. Heights are size.y x scale.y. */
#define DESCRIPTION_BOX 1315800u
#define DESCRIPTION_FRAME 272u
#define DESCRIPTION_TITLE 936u
#define DESCRIPTION_BODY 1632u
#define DESCRIBED_SETTING 1318500u
#define SHOWN_SETTING 1318476u
#define NO_SETTING 156u
#define WIDGET_HEIGHT 16u
#define WIDGET_SCALE_Y 32u
/* Text widgets hold a label ID at +272 and up to 14 format arguments {key, type, value} of 24 bytes from +280, with
 * their count at +616. The key is MurmurHash64A("COUNT") >> 32. */
#define LABEL 272u
#define ARGUMENTS 280u
#define ARGUMENT_COUNT 616u
#define TEXT_KEY 0xAB2A7B35u
#define STRING_ARGUMENT 1u

/* ---- text widgets ------------------------------------------------------------------------------------------------ */

static uintptr_t TextArgument(uintptr_t widget)
{
    uint32_t count = mom_get8(widget + ARGUMENT_COUNT);
    if (count > 14) count = 14;
    for (uint32_t i = 0; i < count; i++)
    {
        uintptr_t record = widget + ARGUMENTS + 24u * i;
        if (mom_get32(record) == TEXT_KEY) return record;
    }
    return 0;
}

/* `text` is a text.c buffer: the widget shows it when its string argument is that buffer. */
int mom_shows_text(uintptr_t widget, const char* text)
{
    if (mom_get32(widget + LABEL) != MOM_TEXT_TEMPLATE) return 0;
    uintptr_t record = TextArgument(widget);
    if (record == 0 || mom_get32(record + 4) != STRING_ARGUMENT) return 0;
    return mom_get64(record + 8) == (uint64_t)(uintptr_t)text;
}

void mom_show_text(uintptr_t widget, const char* text)
{
    mom_native.set_label(widget, MOM_TEXT_TEMPLATE);
    mom_native.set_string_arg(widget, TEXT_KEY, text);
}

static void ShowLabel(uintptr_t widget, uint32_t label)
{
    (void)mom_native.clear_args(widget + LABEL);
    mom_native.set_label(widget, label);
}

/* ---- the MODS tab and the category buttons ----------------------------------------------------------------------- */

static int NativeTabs(uintptr_t bar, uint32_t* labels)
{
    for (uint32_t i = 0; i < NATIVE_TABS; i++)
    {
        labels[i] = mom_get32(bar + TAB_LABELS + 4u * i);
        if (labels[i] != mom_tab_labels[i]) return 0;
    }
    return 1;
}

/* Adds MODS as the fourth native tab. The game draws it, its index and Q/E (LB/RB) cycling; relabelling resets every
 * button's state, so the current tab's selected state is restored as the screen's opener does. */
int mom_ensure_mods_tab(uintptr_t screen)
{
    uintptr_t bar = screen + MOM_TAB_BAR;
    uint32_t count = mom_get32(bar + TAB_COUNT);
    uintptr_t title = bar + TAB_TEXT + TAB_STRIDE * MOM_MODS_TAB;
    if (count == NATIVE_TABS + 1)
    {
        if (mom_get32(bar + TAB_LABELS + 4u * MOM_MODS_TAB) != MOM_TEXT_TEMPLATE) return 0;
        if (!mom_shows_text(title, mom.modsTitle)) mom_show_text(title, mom.modsTitle);
        return 1;
    }
    if (count != NATIVE_TABS) return 0;
    uint32_t current = mom_get32(bar + MOM_TAB_CURRENT);
    uint32_t labels[NATIVE_TABS + 1];
    if (current >= NATIVE_TABS || !NativeTabs(bar, labels)) return 0;
    labels[MOM_MODS_TAB] = MOM_TEXT_TEMPLATE;
    mom_native.set_tab_labels(bar, labels, (int)NATIVE_TABS + 1);
    uintptr_t button = bar + TAB_STRIDE * current;
    mom_put32(button + TAB_BUTTON_STATE, 3);
    mom_put8(button + TAB_BUTTON_ACTIVE, 1);
    mom_show_text(title, mom.modsTitle);
    if (!mom.modsTabLogged)
    {
        mom.modsTabLogged = 1;
        vpm_log(mom.self, "Added native MODS tab (current tab %u).", current);
    }
    return 1;
}

static uintptr_t CategoryButton(uintptr_t content, uint32_t index)
{
    return content + CATEGORY_BUTTON + CATEGORY_STRIDE * index;
}

/* Each button shows its category (or the page control), button 0 the empty text when there is none; the others hide. */
void mom_label_categories(const MomView* view)
{
    for (uint32_t i = 0; i < MOM_CATEGORIES; i++)
    {
        uintptr_t button = CategoryButton(view->content, i);
        const MomCategory* category = i < MOM_MOD_BUTTONS ? view->buttons[i] : NULL;
        if (category != NULL || (i == 0 && view->modCount == 0))
        {
            mom_show_text(button + CATEGORY_TEXT, category != NULL ? category->title : mom.emptyText);
            mom_native.set_visible(button, 1);
        }
        else
            mom_native.set_visible(button, 0);
    }
}

void mom_restore_categories(uintptr_t content)
{
    for (uint32_t i = 0; i < MOM_CATEGORIES; i++)
    {
        uintptr_t button = CategoryButton(content, i);
        ShowLabel(button + CATEGORY_TEXT, mom_category_labels[i]);
        mom_native.set_visible(button, 1);
    }
}

/* ---- the description box ----------------------------------------------------------------------------------------- */

static double TextHeight(uintptr_t widget)
{
    return (double)mom_getf(widget + WIDGET_HEIGHT) * (double)mom_getf(widget + WIDGET_SCALE_Y);
}

/* Shows the entry's description the way the game's set_description lays out a setting's: title over body, the frame
 * fitted to both. MOM rows share one setting without a description, so the game itself only ever hides the box. */
void mom_describe(MomView* view, int entry)
{
    uintptr_t box = view->content + DESCRIPTION_BOX;
    const MomItem* item = entry >= 0 ? view->page.entries[entry].item : NULL;
    view->described = entry >= 0 ? (int64_t)view->page.generation * 64 + entry : MOM_DESCRIBED_NONE;
    if (item == NULL || item->description == NULL) { mom_native.hide_description(box, 1, 1); return; }
    uintptr_t title = box + DESCRIPTION_TITLE, body = box + DESCRIPTION_BODY;
    mom_show_text(title, item->label);
    mom_show_text(body, item->description);
    mom_native.measure_text(body);
    mom_native.measure_text(title);
    double titleHeight = TextHeight(title), bodyHeight = TextHeight(body);
    mom_native.set_position(body, (MomVec2){14, (float)(-titleHeight - 24)});
    mom_native.set_opacity(body, 1);
    mom_native.set_size(box + DESCRIPTION_FRAME, (MomVec2){450, (float)(bodyHeight + titleHeight + 7 + 72)});
    mom_native.hide_description(box, 0, 1);
}

/* Hands the box back to the game: hidden at once, MOM's text arguments gone, and both setting caches cleared so OPTIONS
 * fills it again. */
void mom_release_description(uintptr_t content)
{
    uintptr_t box = content + DESCRIPTION_BOX;
    mom_native.hide_description(box, 1, 0);
    (void)mom_native.clear_args(box + DESCRIPTION_TITLE + LABEL);
    (void)mom_native.clear_args(box + DESCRIPTION_BODY + LABEL);
    mom_put32(content + DESCRIBED_SETTING, NO_SETTING);
    mom_put32(content + SHOWN_SETTING, NO_SETTING);
}
