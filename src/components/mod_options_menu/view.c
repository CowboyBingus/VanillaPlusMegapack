/* Mod Options Menu: the MODS view (the Lua's view.lua). The idle gate (is the escape menu open on top?), entering,
 * keeping and leaving the MODS tab, the description following the selection, and applying or discarding edits as the
 * OPTIONS tab does. */
#include "mom.h"

#define MENU_SYSTEM_PTR_RVA 0x347CE38u
#define UI_STATE_PTR_RVA 0x347CE28u
#define UI_STACK 0x429Cu
#define UI_STACK_ENTRIES 5u /* five screen types, then their count */
#define ESCAPE_MENU_SCREEN 200u
#define ESCAPE_MENU_TYPE 1u
/* Escape menu: the screen's shown content is a tab index. */
#define SHOWN_CONTENT 8u
/* OPTIONS content: a column of nine category buttons and one panel per category. */
#define OPTIONS_CONTENT 3010456u
#define CURRENT_CATEGORY 1318488u
#define PREVIOUS_CATEGORY 1318492u
/* Apply, as on the OPTIONS tab: player edits stay pending until the game's apply action. The unapplied-changes flag makes
 * the game show APPLY (hint 2) and meet tab switches and back with its UNAPPLIED CHANGES dialog (mode 0), whose confirm
 * discards the edits. Native settings never change on MODS, so the game's own apply (which also needs its pending
 * settings to differ) and RESET TO DEFAULT never run there. */
#define UNAPPLIED 1319449u
#define DIALOG 1296040u
#define DIALOG_MODE 19748u
#define DIALOG_STATE 19752u
#define DIALOG_CONFIRM 4608u
#define DIALOG_CONFIRM_ACTION 12072u
#define DIALOG_CANCEL 12160u
#define DIALOG_CANCEL_ACTION 19624u
#define DIALOG_OPEN 2u
#define UNAPPLIED_MODE 0u
#define VISIBLE_FLAG 0x10u
/* The game's own confirm of mode 0 reloads the shown panel from the live settings, and the DISPLAY panel's reload then
 * rewrites rows 8 and 11 as its resolution lists. Once open (texts and buttons set), the dialog is switched to a mode the
 * game's confirm ignores, and MOM discards instead. */
#define NEUTRAL_MODE 2u
/* Input actions evaluated this frame: byte 0 of owner + 808 + 32 * (97 * group + action). Apply is Menu.ExtraOption1
 * (Tab), group 0. */
#define INPUT_OWNER_PTR_RVA 0x347CF18u
#define ACTION_STATES 808u
#define ACTION_STRIDE 32u
#define GROUP_ACTIONS 97u
#define ACTION_GROUPS 13u
#define MENU_GROUP 0u
#define APPLY_ACTION 12u
#define APPLY_SOUND 1183616600u

/* view->dialog: 'open' once seen open, 'decided' once decided while still open (its closing then decides nothing). */
#define DIALOG_NONE 0
#define DIALOG_SEEN 1
#define DIALOG_DECIDED 2
/* What the dialog did this frame. */
#define ANSWER_NONE 0
#define ANSWER_OPEN 1
#define ANSWER_CONFIRMED 2
#define ANSWER_CANCELLED 3

int mom_valid_pointer(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull; }

/* ---- categories and the MODS view -------------------------------------------------------------------------------- */

/* What each category button shows: with up to 8 categories, the list itself. With more, page mom.modsPage of 7 (NULL
 * where the last page runs out) and the page control on the last button. */
static void ButtonList(MomView* view)
{
    memset(view->buttons, 0, sizeof view->buttons);
    if (view->modCount <= MOM_MOD_BUTTONS)
    {
        for (int i = 0; i < view->modCount; i++) view->buttons[i] = view->mods[i];
        return;
    }
    int first = mom.modsPage * MOM_PAGE_MODS;
    for (int i = 0; i < MOM_PAGE_MODS; i++) view->buttons[i] = first + i < view->modCount ? view->mods[first + i] : NULL;
    view->buttons[MOM_MOD_BUTTONS - 1] = view->control;
}

/* Whether category button `index` shows a category or the page control. Button 0 shows the empty text when there is
 * none. */
static int Shows(const MomView* view, uint32_t index)
{
    return index == 0 || (index < MOM_MOD_BUTTONS && view->buttons[index] != NULL);
}

/* The player turned the page control's row to `page`: only the category buttons change. The shown category stays the
 * page control's. */
void mom_turn_page(MomView* view, int page)
{
    mom_page_turned(page);
    ButtonList(view);
    mom_label_categories(view);
    vpm_log(mom.self, "Showing mods page %d of %d.", page, view->control != NULL ? view->control->pages : 0);
}

/* The categories, the page control (when needed) and the buttons, for the model now. */
static void ListMods(MomView* view)
{
    mom_model_update();
    view->revision = mom_model_revision();
    view->modCount = mom_model_categories(view->mods, MOM_MAX_MODS);
    view->control = view->modCount > MOM_MOD_BUTTONS ? mom_page_control(view->modCount) : NULL;
    ButtonList(view);
}

/* The idle gate, run every frame: one read of the UI stack (its entries and their count) answers whether the escape
 * menu is open; only then is its screen pointer read. lint: per-frame */
int mom_escape_menu(uintptr_t* screen)
{
    uint32_t stack[UI_STACK_ENTRIES + 1];
    uint64_t ui = vpm_game_u64(UI_STATE_PTR_RVA);
    if (!mom_valid_pointer(ui) || !vpm_read((uintptr_t)ui + UI_STACK, stack, sizeof stack)) return MOM_MENU_CLOSED;
    uint32_t depth = stack[UI_STACK_ENTRIES];
    if (depth > UI_STACK_ENTRIES) return MOM_MENU_CLOSED;
    int open = 0;
    for (uint32_t i = 0; i < depth; i++) open |= stack[i] == ESCAPE_MENU_TYPE;
    if (!open) return MOM_MENU_CLOSED;
    if (stack[depth - 1] != ESCAPE_MENU_TYPE) return MOM_MENU_COVERED;
    uint64_t menu = vpm_game_u64(MENU_SYSTEM_PTR_RVA), at = 0;
    if (!mom_valid_pointer(menu) || !vpm_read_u64((uintptr_t)menu + ESCAPE_MENU_SCREEN, &at) || !mom_valid_pointer(at) ||
        at % 8 != 0)
        return MOM_MENU_CLOSED;
    *screen = (uintptr_t)at;
    return MOM_MENU_OPEN;
}

/* Switches the shown panel through the game's own category selection, which deactivates the previous panel and builds
 * the next one. The selection keeps no previous index itself, so it is written first; reselecting the shown category
 * goes through another panel to force a fresh build. */
void mom_select_category(uintptr_t content, uint32_t shown, uint32_t target)
{
    if (shown == target)
    {
        uint32_t other = target == 0 ? 3u : 0u;
        mom_put32(content + PREVIOUS_CATEGORY, shown);
        mom_native.select_category(content, (int)other);
        shown = other;
    }
    mom_put32(content + PREVIOUS_CATEGORY, shown);
    mom_native.select_category(content, (int)target);
}

/* The screen runs the OPTIONS content's visual pass (layout, category button states, row animation, description box)
 * only while OPTIONS is the current tab, so the MODS tab runs it once per frame itself: without it a menu opened on
 * another tab is never laid out. The description then follows the selection. */
void mom_update_visuals(MomView* view, float dt)
{
    mom_native.options_visual(view->content, dt);
    int entry = mom_selected_entry(view);
    int64_t key = entry >= 0 ? (int64_t)view->page.generation * 64 + entry : MOM_DESCRIBED_NONE;
    if (key != view->described) mom_describe(view, entry);
}

/* ---- apply and the UNAPPLIED CHANGES dialog ---------------------------------------------------------------------- */

/* Whether an input action triggered this frame, on any device or binding. The input owner is live whenever the menu
 * is: the visual pass reads it. */
static int ActionTriggered(uint32_t group, uint32_t action)
{
    uint64_t owner = vpm_game_u64(INPUT_OWNER_PTR_RVA);
    if (!mom_valid_pointer(owner) || group >= ACTION_GROUPS || action >= GROUP_ACTIONS) return 0;
    return mom_get8((uintptr_t)owner + ACTION_STATES + ACTION_STRIDE * (GROUP_ACTIONS * group + action)) != 0;
}

/* Whether a dialog button's action (u32 group, u32 action at key) triggered. */
static int KeyTriggered(uintptr_t dialog, uint32_t key)
{
    return ActionTriggered(mom_get32(dialog + key), mom_get32(dialog + key + 4));
}

static int ButtonTriggered(uintptr_t dialog, uint32_t button, uint32_t key)
{
    return (mom_get32(dialog + button) & VISIBLE_FLAG) != 0 && KeyTriggered(dialog, key);
}

/* The UNAPPLIED CHANGES dialog, decided as the game decides it (0x199ce60): confirmed when its shown confirm button's
 * action triggers, cancelled when its cancel button's does. When the game's input update runs before this one it has
 * already closed the dialog and cleared the confirm action (Menu.Select) but not the cancel action (Menu.Back), so a
 * dialog seen open and closed since was confirmed unless its cancel action triggered. */
static int UnappliedDialog(MomView* view)
{
    uintptr_t dialog = view->content + DIALOG;
    uint32_t mode = mom_get32(dialog + DIALOG_MODE);
    int open = mom_get32(dialog + DIALOG_STATE) == DIALOG_OPEN && (mode == UNAPPLIED_MODE || mode == NEUTRAL_MODE);
    int seen = view->dialog;
    if (!open)
    {
        view->dialog = DIALOG_NONE;
        if (seen != DIALOG_SEEN) return ANSWER_NONE;
        return KeyTriggered(dialog, DIALOG_CANCEL_ACTION) ? ANSWER_CANCELLED : ANSWER_CONFIRMED;
    }
    if (seen == DIALOG_DECIDED) return ANSWER_OPEN;
    view->dialog = DIALOG_DECIDED;
    if (ButtonTriggered(dialog, DIALOG_CONFIRM, DIALOG_CONFIRM_ACTION)) return ANSWER_CONFIRMED;
    if (ButtonTriggered(dialog, DIALOG_CANCEL, DIALOG_CANCEL_ACTION)) return ANSWER_CANCELLED;
    view->dialog = DIALOG_SEEN;
    return ANSWER_OPEN;
}

/* Drops the pending edits and shows the applied values on the page's rows; the page control's row keeps its page. */
static void DiscardPending(MomView* view)
{
    mom_drop_pending();
    for (int i = 0; view->hasPage && i < view->page.count; i++)
    {
        MomEntry* entry = &view->page.entries[i];
        if (entry->item->key != MOM_NO_KEY) mom_apply_value(entry, mom_applied(entry->item));
    }
    vpm_log(mom.self, "Discarded unapplied option changes.");
}

/* Applies the pending edits on the apply action, discards them when the UNAPPLIED CHANGES dialog is confirmed, and keeps
 * the game's unapplied flag in step with them. Nothing runs while no edit is pending. */
void mom_update_apply(MomView* view)
{
    if (mom.pendingCount > 0)
    {
        int dialog = UnappliedDialog(view);
        if (dialog == ANSWER_CONFIRMED) DiscardPending(view);
        else if (dialog == ANSWER_NONE && ActionTriggered(MENU_GROUP, APPLY_ACTION))
        {
            vpm_log(mom.self, "Applied %d option changes.", mom_apply_pending());
            mom_native.play_sound(0, APPLY_SOUND);
        }
    }
    else
        view->dialog = DIALOG_NONE;
    uint8_t unapplied = mom.pendingCount > 0 ? 1 : 0;
    if (unapplied != view->unapplied)
    {
        mom_put8(view->content + UNAPPLIED, unapplied);
        view->unapplied = unapplied;
    }
}

/* Neutralises the UNAPPLIED CHANGES dialog once it is open. It finishes opening inside the visual pass, which runs after
 * update_apply, so this runs after that pass: no frame leaves the game's own confirm armed. A dialog that opened in that
 * pass is watched from here, so a confirm on the game's next input update counts even though update_apply never saw the
 * dialog open. */
void mom_neutralize_dialog(MomView* view)
{
    if (mom.pendingCount == 0) return;
    uintptr_t dialog = view->content + DIALOG;
    if (mom_get32(dialog + DIALOG_STATE) != DIALOG_OPEN) return;
    uint32_t mode = mom_get32(dialog + DIALOG_MODE);
    if (mode == UNAPPLIED_MODE)
    {
        mom_put32(dialog + DIALOG_MODE, NEUTRAL_MODE);
        mode = NEUTRAL_MODE;
    }
    if (mode == NEUTRAL_MODE && view->dialog == DIALOG_NONE) view->dialog = DIALOG_SEEN;
}

/* ---- entering, keeping and leaving the MODS tab ------------------------------------------------------------------ */

void mom_enter_view(uintptr_t screen)
{
    uintptr_t content = screen + OPTIONS_CONTENT;
    uint32_t shown = mom_get32(content + CURRENT_CATEGORY);
    MomView* view = &mom.view;
    memset(view, 0, sizeof *view);
    view->screen = screen;
    view->content = content;
    view->saved = shown < MOM_MOD_BUTTONS ? shown : 0;
    view->described = MOM_DESCRIBED_NEVER;
    ListMods(view);
    /* The game's tab switch hid every content; MODS shows the OPTIONS content, which the screen feeds input while its
     * shown content is OPTIONS (its visual pass follows the tab instead: mom_update_visuals). */
    mom_put32(screen + SHOWN_CONTENT, MOM_OPTIONS_TAB);
    mom_native.set_content_hidden(content, 0, 1);
    /* The escape menu's init only marks its layout dirty, and the first visual pass of an open places the category
     * buttons visible then. A button MODS hides in that pass keeps (0, 0) until the menu opens again, so after GAME,
     * straight to MODS, then OPTIONS, those buttons drew over GAMEPLAY (reported 2026-10-18). The native column is laid
     * out first, all nine buttons visible; a button laid out once keeps its place while hidden. */
    mom_native.options_visual(content, 0);
    mom_label_categories(view);
    if (shown != 0) mom_select_category(content, shown, 0);
    mom.hasView = 1;
    (void)mom_build_page(view, 0);
    vpm_log(mom.self, "Opened MODS tab: %d mods.", view->modCount);
}

void mom_leave_view(MomView* view)
{
    uintptr_t content = view->content;
    uint32_t shown = view->hasPage ? (uint32_t)view->page.index : mom_get32(content + CURRENT_CATEGORY);
    view->hasPage = 0;
    /* The game lets the view go only once the edits are applied or discarded. */
    mom_drop_pending();
    mom_put8(content + UNAPPLIED, 0);
    mom_release_description(content);
    mom_restore_categories(content);
    if (shown >= MOM_MOD_BUTTONS) shown = MOM_CATEGORIES; /* no panel to deactivate */
    mom_select_category(content, shown, view->saved);
    mom.hasView = 0;
    vpm_log(mom.self, "Closed MODS tab.");
}

static void RefreshView(MomView* view)
{
    ListMods(view);
    mom_label_categories(view);
    uint32_t current = view->hasPage ? (uint32_t)view->page.index : 0;
    view->hasPage = 0;
    if (!Shows(view, current))
    {
        mom_select_category(view->content, current, 0);
        current = 0;
    }
    (void)mom_build_page(view, current);
}

/* lint: per-frame */
void mom_maintain_view(MomView* view)
{
    uint32_t current = mom_get32(view->content + CURRENT_CATEGORY);
    if (view->revision != mom_model_revision()) RefreshView(view);
    else if (!view->hasPage || current != (uint32_t)view->page.index)
    {
        view->hasPage = 0;
        if (Shows(view, current)) (void)mom_build_page(view, current); /* the game already switched panels */
        else
        {
            mom_select_category(view->content, current, 0);
            (void)mom_build_page(view, 0);
        }
    }
    else if (!mom_page_intact(view))
        (void)mom_build_page(view, current);
    if (view->hasPage) mom_poll_page(view);
}
