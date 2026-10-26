/* Mod Options Menu v1.2.1 (Lua: components/ModOptionsMenu/src/mod_options_menu.lua and its native, widgets, options,
 * rows and view files), build 25480438.
 *
 * A native MODS tab on the escape menu, after GAME, SOCIAL and OPTIONS, built from game.dll's own C++ widgets: the tab
 * bar gets a fourth label, and while MODS is current the OPTIONS content is shown with its category buttons relabelled
 * (one per category) and the shown panel's rows replaced by toggle, choice and slider rows built from MOM's own setting
 * descriptors (setting 139, whose value type is none, so no game setting is ever read or written). Edits stay pending as
 * on OPTIONS: the game's unapplied-changes flag shows APPLY, Tab applies (with the game's apply sound), and leaving meets
 * the game's UNAPPLIED CHANGES dialog, whose confirm discards. The description box follows the hovered row. Past 8
 * categories the buttons show 7 at a time and the 8th turns the pages. Leaving the tab gives everything back to the game.
 *
 * On HellForge: the options are the core's registry (vpm.h "options"), not the Lua's own API and values file: each
 * component that registered options is a category (named after it, in upper case) listing its options, applied values
 * are vpm_option_value, and APPLY hands each edit to vpm_option_apply (set, the owner's on_change), then writes the
 * settings file at once (vpm_settings_save_now), as the Lua wrote its values file on apply; leaving the tab writes a
 * waiting change too, as the Lua's leave_view. A value set from code (vpm_option_set) replaces the player's pending edit
 * of it and shows on its open row from the next step, as the Lua's set() did: the view compares the core's option
 * revision once per MODS frame, and only on a frame it moved compares the options' values (view.c ShowSetValues); one
 * difference, a set to the value the option already has is no change for the core, so it leaves a pending edit of that
 * option where the Lua's set() dropped it. The core refuses at registration what the Lua's register_option refused
 * (lengths, choices, ranges, kinds, defaults); the tab leaves out only an option whose texts it cannot show (not UTF-8,
 * control characters, blank), with the core's text functions (vpm_utf8_*, vpm_upper). New here: a VANILLA PLUS
 * MEGAPACK category with a switch per component (vpm_component_switch), which the core applies at the next frame, or from
 * the next session for a component that cannot restart while the game runs (the row's description says which, and why).
 * Its own switch is one of those: it draws this menu. The game.dll functions are checked with vpm_game_code_matches (the bytes as shipped, so another
 * mod's hook does not fail them), by the core's wait (vpm_when_code_ready): at HF_EVENT_GAME_LOADED, then every 30
 * frames until all 25 read as decoded, at most 60 s. The 1:1 port checked them at its first tick, which comes right
 * after that event, while HellForge says game.dll's code is still decoded in parts (it gives its own later pins 20 s),
 * so it could stop for no reason; the Lua checked them in its first update. Nothing of MOM runs before they match: the
 * labels and descriptor check, the binding and the tick start in the ready step (CodeReady), and a function that never
 * reads as shipped stops it with the Lua's wording ("Mod options integration unavailable: options_visual changed",
 * the core adding "(game.dll 0x1998590)"). Their calling convention and the arguments they take are checked against
 * the decoded game.dll of 25480438, function by function (native.h). Texts are English (vpm_text). Dropped: the
 * _G.ModOptionsMenu API for Lua mods, the values file and its backup (the core saves), the game's Text Language query
 * and text refresh on each opening (no translations yet), and the Lua update guard (error bursts, pauses, shutdown
 * save): the core's crash guard stops the component on a fault, and stop() hands an open view back to the game as the
 * Lua's guard did.
 *
 * Cost (the Lua's test_options_tab.lua budgets: ReadProcessMemory calls per frame):
 * - Escape menu closed (most of every session): 1 plain load (the UI state pointer in game.dll) and 1 read (the UI stack,
 *   24 bytes); no Windows call of its own, no allocation, no log. The Lua: 1 read.
 * - Menu open on another tab, or covered: 2 reads (the stack, the screen pointer; covered: 1) and plain loads of the tab
 *   bar. The Lua: 2.
 * - MODS shown, nothing changing: 2 reads, 1 native call (the OPTIONS visual pass), plain loads for the page check, the
 *   row polls and the selection (and the dialog and the apply key while an edit is pending), and one compare of the
 *   core's option revision (a call returning a static, no read). The Lua: 2 reads, 1 pass, a queued-set flag.
 * - The frame after a value is set from code: the same 2 reads, plus the options' values compared (plain loads, at most
 *   256) and the native value call of each row showing a changed one. The Lua: its queued rows' native calls.
 * - Frames that act (entering or leaving MODS, a page build, an edit, apply, a description): native calls and a log line,
 *   as the Lua made them; APPLY, and leaving the tab with a change waiting, also write the settings file (the core's
 *   save: CreateFileW, WriteFile, MoveFileExW), as the Lua wrote its values file then.
 * - Once per session: 25 code checks (HfApi.code_matches) at HF_EVENT_GAME_LOADED when the code is decoded by then;
 *   otherwise the core's wait looks every 30 frames (up to the first pin that does not match yet, so 1 to 25 calls a
 *   look) until all match, at most 60 s; then 15 plain loads of the native labels and setting 139's descriptor. The Lua:
 *   the shared runtime's build hash, 25 byte compares, 15 loads, in its first update. */
#include "mom.h"

MomState mom;

/* The game's escape menu, every game update: the idle gate first (closed: 1 read), then the MODS tab and the view, as
 * the Lua's step. A view dropped with the menu (closed or rebuilt) never applies its edits; reopening the escape menu
 * re-initialises every widget MOM touched. lint: per-frame */
static void Step(VpmComponent* self, float dt)
{
    uintptr_t screen = 0;
    int status = mom_escape_menu(&screen);
    if (status == MOM_MENU_CLOSED)
    {
        if (!mom.hasView) return;
        mom.hasView = 0;
        mom_drop_pending();
        vpm_log(self, "Escape menu closed on the MODS tab.");
        return;
    }
    if (status != MOM_MENU_OPEN) return;
    if (mom.hasView && mom.view.screen != screen) { mom.hasView = 0; mom_drop_pending(); }
    if (!mom_ensure_mods_tab(screen))
    {
        if (mom.hasView) { mom.hasView = 0; mom_drop_pending(); }
        return;
    }
    uint32_t tab = mom_get32(screen + MOM_TAB_BAR + MOM_TAB_CURRENT);
    if (mom.hasView)
    {
        if (tab != MOM_MODS_TAB) mom_leave_view(&mom.view);
        else mom_maintain_view(&mom.view);
    }
    else if (tab == MOM_MODS_TAB)
        mom_enter_view(screen);
    if (!mom.hasView) return;
    mom_update_apply(&mom.view);
    mom_update_visuals(&mom.view, dt);
    mom_neutralize_dialog(&mom.view);
}

/* game.dll's 25 functions read as shipped (the core's wait, from HF_EVENT_GAME_LOADED): the labels and descriptor
 * verified once, the functions bound, then the step from the next game update on. Before this nothing runs: no tick,
 * no read. */
static void CodeReady(VpmComponent* self, HfEvent event)
{
    const char* failure = mom_native_verify();
    if (failure != NULL)
    {
        vpm_fail(self, MOM_UNAVAILABLE "%s", failure);
        return;
    }
    vpm_log(self, "Native options layout verified for current game build.");
    if (!vpm_tick_start(self, Step)) vpm_fail(self, "the game thread could not be reached");
}

/* Hands an open MODS view back to the game as on leaving the tab, but only while its escape menu is still open on top:
 * a covered or closed menu's view is just dropped, as when the menu closes. The view is dropped first. Stopped while
 * waiting for game.dll's code, nothing was touched. */
static void Stop(VpmComponent* self)
{
    int had = mom.hasView;
    mom.hasView = 0;
    mom_drop_pending();
    uintptr_t screen = 0;
    if (had && mom_escape_menu(&screen) == MOM_MENU_OPEN && screen == mom.view.screen) mom_leave_view(&mom.view);
}

static int Start(VpmComponent* self)
{
    memset(&mom, 0, sizeof mom);
    memset(&mom_native, 0, sizeof mom_native);
    mom.self = self;
    mom_text_reset();
    mom_model_reset();
    mom_rows_reset();
    mom.modsTitle = mom_intern(vpm_text(self, "tab.mods", "MODS"));
    mom.emptyText = mom_intern(vpm_text(self, "category.none", "NO MOD OPTIONS INSTALLED"));
    if (!vpm_when_code_ready(self, mom_native_pins, MOM_NATIVE_COUNT, CodeReady))
        return vpm_fail(self, "game.dll's code checks could not be registered");
    return 0;
}

const VpmComponentDef vpm_component_mod_options_menu = {"mod_options_menu", "Mod Options Menu", "1.2.1", 0, Start, Stop, NULL,
    /* switched off while its own tab shows the switch, the game's menu would keep a MODS tab nothing updates */
    "it draws this menu, and the game's menu would keep its MODS tab without it"};
