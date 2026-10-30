/* Mod Bindings Menu v2.3 (Lua: components/ModBindingsMenu/src/mod_bindings_menu.lua and its seven files), build
 * 25480438. COST: see the end of this comment.
 *
 * A MODS tab on the game's keyboard and controller binding pages, where the pack's components offer keys the player
 * can rebind like the game's own. Each binding owns one of 36 dormant native actions (developer input groups nothing in
 * retail play listens to: the game evaluates every trigger type on every device for them and saves their keys by name):
 * the seven fixed v1 slots, or one of 29 automatic actions kept for the binding's id across sessions. The tab is the
 * game's own list, rebuilt with its builder (0x1812940) under per-component section headers whose texts borrow empty
 * localization cache slots while a page shows them. "Down" is the game's evaluated state of the binding's action
 * (owner + 808 + 32 * (97 * group + action), byte 0). A sweep every 2 s (and before a binding is trusted after its
 * mapping count changed) clears the actions' inherited developer defaults once, keeps every mapping the player chose,
 * cleans lists the game restored, and keeps the six fixed slots' keyboard defaults (Tab, F1, F5-F8) added at run time.
 * Beyond the 36 actions a binding is extended: keys read from the engine's input, chosen on a fifth MORE MODS tab.
 *
 * Files: this one (the frame, the build check, the backend); mbm_maps.c (binding maps, the native answer, the mission
 * check); mbm_sweep.c (the sweep and the keyboard defaults); mbm_assign.c (registration and reservations); mbm_tab.c
 * (the native tabs, the label pool, the MODS title); mbm_text.c (the rows' texts); mbm_extended.c (extended bindings
 * and their store); mbm_capture.c (key capture); mbm_panel.c (the MORE MODS panel).
 *
 * On HellForge, what differs from the Lua:
 *   - The registry is the core's (vpm.h "bindings"): the component is its backend (vpm_bindings_set_backend). attach
 *     assigns a binding's action as register_binding did; down answers as is_down did (1, 0, -1 for nil). A binding is
 *     "<component>.<binding id>"; its label and section are text (VpmBindingDef), the section defaulting to the
 *     component's name (the Lua named it after the calling addon's file). Refused registrations log why (the Lua
 *     returned the reason to the caller). The Lua's API for other Lua mods (_G.ModBindingsMenu: poll, set_binding,
 *     binding, binding_info, revision, ready, options.backend and options.default) is not offered: VpmBindingDef has
 *     none of it, so a registration beyond the 36 actions always becomes extended.
 *   - Reservations, slot 2's owner and the sweep's marks (the Lua's ModBindingsMenu.assignments) and the extended keys
 *     (ModBindingsMenu.bindings) live in the pack's settings file, sections [mod_bindings_menu] and
 *     [mod_bindings_menu.bindings], one key per automatic action, dormant action, shared slot or extended binding: the
 *     core reads settings by key only. Its save (atomic, after a second) replaces the Lua's own temporary file, backup,
 *     damaged-file handling and one-minute retry. The Lua's files are not imported (the game keeps the keys themselves).
 *   - game.dll statics (the input owner, UI state and menu pointers, the mission record pointer, the tab labels and the
 *     action label table) are plain loads; the heap through vpm_read. The Lua's VirtualQuery before every game.dll write
 *     is one check per region at activation (vpm_writable); writes it would have skipped are skipped (logged once).
 *     Before its first store into a binding page's screen object (tab buttons, the row request) and into a binding map,
 *     each is checked writable once, which the Lua did not do.
 *   - Texts: the Lua's locales/en.lua through vpm_text (its only locale; vpm_text's English fallback needs no page-open
 *     refresh, which the Lua's one-locale table made a no-op too). The UTF-8 checks, limits and upper case of every
 *     script the game's fonts carry are kept (mbm_text.c, over the core's one copy of the Lua text module).
 *   - Extended bindings and the MORE MODS page need the engine's input and Gui, which a C mod cannot reach yet
 *     (mbm_engine.h). Their logic is ported behind that interface; without a backend an extended binding answers -1 (the
 *     caller's fixed key; the Lua said false until engine input existed) and the MORE MODS tab is not offered (status).
 *   - The build check's four code checks (the list builder, the tab label setter, the list reset, the input consume)
 *     are the core's wait (vpm_when_code_ready): game.dll's code is decoded in parts after HF_EVENT_GAME_LOADED, and
 *     the Lua's first update (this tick's first frame) comes right after that event. They are checked at the event and
 *     every 30 frames until they read as shipped; the tick does nothing before (no read), then the rest of the build
 *     check (the tab labels and the action label table, plain loads) runs on its next frame, as on the Lua's first.
 *     Bytes that never match within 60 s stop the component ("binding list builder changed (game.dll 0x1812940)"),
 *     with the Lua's inactive note, nothing changed.
 *   - Dropped: the update guard (error bursts, pauses after an error below, the shutdown status), the build hash check
 *     (the core checks the build), the LuaJIT notes, and the Lua's logs of engine button ids. The crash guard covers
 *     faults; stop() gives back what a page borrowed, as the Lua's shut_down.
 *
 * COST per frame (calls; "read" is vpm_read, a guarded plain load; tests/components/mod_bindings_menu_test.c pins the
 * reads; the harness does not count VirtualQuery, so those are from the code). Ship Station Hotkeys' six bindings:
 *   - Idle (no binding page, nothing to save, no sweep due): 1 read, the screen stack (Lua: 1).
 *   - A sweep, every 2 s: each registered native action's defaults and live records, and the screen stack: 13 (Lua:
 *     14). A list that changed is read once more and written back.
 *   - down (vpm_binding_down) of a native binding: 2 reads, the record header and the state byte (Lua: 3). After the
 *     game restored a list (its mapping count changed), the sweep first and the frame reads up.
 *   - A binding page on a native tab: the screen stack, the screen, each action's defaults record, the selected tab, the
 *     tab count: 10 (Lua: 11); every 60 page frames the mission record (1 read; Lua: 2). On the MODS tab also the row
 *     count: 11 (Lua: 12); every 0.5 s every row instead (9 for 7 rows: 19; Lua: 20).
 *   - The frame a page opens: also the gate's read, the mission record, the current tab and the tab bar relabelled
 *     (set_tab_labels; 14 reads with seven bindings, Lua: 20 and 1 VirtualQuery), and 1 VirtualQuery the first time a
 *     screen object is written. The MODS tab's first frame: also each binding's record and the row count, build_rows
 *     and reset_list (19 with seven; Lua: 36 and 7 VirtualQuery). Closing: the sweep and the labels given back with
 *     plain stores (13 for six; Lua: 20 and 6 VirtualQuery).
 *   - The MORE MODS tab (with the engine's Gui only): the page's reads and 5 for the panel (the page kind, both widgets,
 *     the cursor, 11 UI action states; Lua: 7), engine mouse calls, Gui calls only on a change; during a capture 4 (97 UI
 *     action states) and a consume call per active UI action (Lua: 5).
 *   - Before native input exists: 0 reads while the input owner is null (Lua: 1), else the map indexed (up to 9).
 *   - Once per session: the build check (4 code checks at HF_EVENT_GAME_LOADED, repeated every 30 frames while the code
 *     is not decoded, at most 60 s; 37 plain loads on the first frame after), activation (the live map indexed, the defaults
 *     map indexed and each fixed slot's two records, the slot 1 note: 32 reads, 33 with the frame's own; Lua: 40), 2
 *     VirtualQuery of game.dll data, and 1 per binding map before its first write. The first sweep reads 3 records per
 *     binding (18 for six).
 *   No allocation, and no log line on an idle frame. */
#include <stdio.h>
#include <string.h>
#include "mbm.h"
#include "locale_data.h"

MbmState mbm;

const MbmDormant mbm_dormant[MBM_ACTIONS] = {
    /* Fixed v1 slots 1-7: the map, the third-party slot, five ship stations. */
    {12, 1, 0x62EA38BFu}, {12, 0, 0x82FBDCB2u}, {10, 1, 0x6218A8BAu}, {10, 4, 0xD46660E4u},
    {10, 8, 0xC60E3A71u}, {10, 14, 0x45C3CE49u}, {10, 9, 0x54041145u},
    /* Automatically assigned (version 2). */
    {10, 0, 0x4A681770u}, {10, 2, 0x03F7407Eu}, {10, 3, 0x533AD91Fu}, {10, 5, 0xC9D1BABCu},
    {10, 6, 0xEB8A3B7Au}, {10, 7, 0x5DAAA6C3u}, {10, 10, 0xF0A84860u}, {10, 11, 0xAAC2B10Eu},
    {10, 12, 0xF884272Du}, {10, 13, 0x6A566AF0u}, {10, 15, 0x3A0B904Cu}, {10, 16, 0x484BB4C1u},
    {10, 17, 0x5556AE64u}, {11, 0, 0x2BF059B1u}, {11, 1, 0x5F892216u}, {11, 2, 0x0BF38A13u},
    {11, 3, 0x5B786E6Bu}, {9, 0, 0x5D7D7666u}, {9, 1, 0x020AE5FCu}, {9, 2, 0x04EE429Eu},
    {9, 3, 0x71D71525u}, {9, 4, 0x026199FAu}, {9, 5, 0x62407E28u}, {9, 6, 0x2A05009Fu},
    {9, 7, 0x6479F954u}, {9, 8, 0x6306672Au}, {9, 9, 0x8E53CE97u}, {9, 10, 0x6E43F1C5u},
    {9, 11, 0xAE71F7A9u},
};

/* The build check's code: the core's wait (the refusal reads "<name> changed (game.dll 0x...)", as the Lua's reason
 * "<name> changed"). */
static const VpmCodePin kMbmCodeChecks[] = {
    {MBM_BUILD_ROWS_RVA, "48 8B C4 53 41 56 48 81 EC D8 00 00 00", "binding list builder", 0},
    {MBM_SET_TAB_LABELS_RVA, "48 89 54 24 10 53 56 48 83 EC 68 0F 29 74 24 30", "tab bar label setter", 0},
    {MBM_LIST_RESET_RVA, "40 53 48 83 EC 20 48 8B D9 85 D2 74 30 83 EA 01", "binding list reset", 0},
    {MBM_INPUT_CONSUME_RVA, "40 53 48 83 EC 20 4C 8B D1 4C 8B CA 48 8B CA E8 DC 7C 28 FF", "input consume routine", 0},
};
static const uint8_t kMbmTabLabels[12] = {0x51, 0xF4, 0x70, 0x8D, 0x60, 0x5C, 0x5E, 0xF1, 0xEB, 0x7F, 0x84, 0x00};
#define MBM_INACTIVE_NOTE "Mod Bindings Menu is inactive on this game build: it changes nothing in the game " \
    "(no keyboard defaults added, no binding page changes). Update it to a release for this game build."
#define MBM_MISSION_CHECK_FRAMES 60

static struct
{
    int idle_armed; /* the last full step found no page and left nothing to retry */
} s_mbm;

int mbm_code_index(uint32_t code)
{
    for (int i = 0; i < MBM_ACTIONS; i++)
        if (mbm_code_at(i) == code) return i;
    return -1;
}

uint32_t mbm_code_at(int index) { return (uint32_t)mbm_dormant[index].group * 65536u + mbm_dormant[index].action; }
int mbm_pointer(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull; }

uintptr_t mbm_input_owner(void)
{
    uint64_t owner = vpm_game_u64(MBM_INPUT_OWNER_RVA);
    return mbm_pointer(owner) ? (uintptr_t)owner : 0;
}

static int MbmPageOnTop(const uint32_t* stack)
{
    uint32_t depth = stack[5];
    return depth >= 1 && depth <= 5 && stack[depth - 1] == MBM_BINDING_SCREEN;
}

/* The binding page's screen object while a binding page is on top of the UI, else 0: the UI's screen stack (1 read),
 * then the menu system's screen (1 read) while a page is on top. lint: per-frame */
uintptr_t mbm_active_screen(void)
{
    uint64_t ui = vpm_game_u64(MBM_UI_STATE_RVA), menu = vpm_game_u64(MBM_MENU_SYSTEM_RVA);
    uint32_t stack[6];
    if (!mbm_pointer(ui) || !vpm_read((uintptr_t)ui + MBM_SCREEN_STACK, stack, sizeof stack)) return 0;
    if (!MbmPageOnTop(stack) || !mbm_pointer(menu)) return 0;
    uint64_t screen = 0;
    if (!vpm_read_u64((uintptr_t)menu + MBM_MENU_SCREEN, &screen) || !mbm_pointer(screen)) return 0;
    return (uintptr_t)screen;
}

/* ---- the build check, on the first frame after the code checks -------------------------------------------- */

/* The rest of the Lua's check, its code checks having passed (the core's wait): the tab labels, the action labels. */
static const char* MbmLayoutProblem(char* why, size_t size)
{
    uint8_t labels[sizeof kMbmTabLabels];
    if (!vpm_game_read(MBM_TAB_LABELS_RVA, labels, sizeof labels) || memcmp(labels, kMbmTabLabels, sizeof labels) != 0)
        return "binding tab labels changed";
    for (int i = 0; i < MBM_ACTIONS; i++)
    {
        const MbmDormant* d = &mbm_dormant[i];
        uint32_t label = vpm_game_u32(MBM_ACTION_LABELS_RVA + (d->group * MBM_GROUP_ACTIONS + d->action) * 4u);
        if (label == d->label) continue;
        snprintf(why, size, "input action label table changed at %u:%u", d->group, d->action);
        return why;
    }
    return NULL;
}

/* 1 when the native layout is the reviewed one; else the component stops for the session, changing nothing. */
static int MbmInitialize(VpmComponent* self)
{
    mbm.initialized = 1;
    char why[64];
    const char* problem = vpm_game() == 0 ? "game modules unavailable" : MbmLayoutProblem(why, sizeof why);
    if (problem == NULL)
    {
        mbm.base = vpm_game();
        vpm_log(self, "Native binding layout verified for current game build.");
        return 1;
    }
    vpm_fail(self, "%s", problem);
    vpm_log(self, "%s", MBM_INACTIVE_NOTE);
    return 0;
}

/* Slot 1's native mappings, once (the Lua's input probe): one read of its record. */
static void MbmLogProbe(VpmComponent* self)
{
    uintptr_t bucket = mbm_map_bucket(MBM_BINDING_MAP, 12u * 65536u + 1u);
    uint8_t record[MBM_RECORD_SIZE];
    if (bucket == 0 || !vpm_read(bucket, record, sizeof record)) return;
    uint32_t count;
    memcpy(&count, record + 4, 4);
    char line[8 * 41 + 1];
    size_t at = 0;
    for (uint32_t i = 0; i < count && i < 8; i++)
    {
        for (uint32_t b = 0; b < MBM_MAPPING_SIZE; b++)
            at += (size_t)snprintf(line + at, sizeof line - at, "%02X", record[MBM_MAPPINGS + i * MBM_MAPPING_SIZE + b]);
        if (i + 1 < count && i + 1 < 8) line[at++] = ' ';
    }
    line[at] = 0;
    vpm_log(self, "Slot 1 native mappings: %s", line);
}

/* Native input exists once slot 1's action is in the live map: the list functions, the keyboard defaults. */
static void MbmActivate(VpmComponent* self)
{
    if (mbm.ready || mbm_map_bucket(MBM_BINDING_MAP, 12u * 65536u + 1u) == 0) return;
    mbm_set_functions(mbm.base);
    mbm.ready = 1;
    vpm_log(self, "Mod input actions loaded; native keyboard and controller bindings ready.");
    mbm_add_keyboard_defaults();
    mbm.revision++;
    MbmLogProbe(self);
}

/* ---- the frame ---------------------------------------------------------------------------------------------- */

/* The idle gate (the Lua's idle): armed by a full step that found no page and left nothing to retry. An idle frame
 * reads the UI's screen stack once and counts down the sweep timer. lint: per-frame */
static int MbmIdle(float seconds)
{
    if (!s_mbm.idle_armed || mbm.defaults_pending || mbm.suppressed) return 0;
    if (mbm_assign_dirty() || mbm_extended_dirty()) return 0;
    float timer = mbm.sweep_timer - seconds;
    if (timer <= 0) return 0;
    uint64_t ui = vpm_game_u64(MBM_UI_STATE_RVA);
    uint32_t stack[6];
    if (!mbm_pointer(ui) || !vpm_read((uintptr_t)ui + MBM_SCREEN_STACK, stack, sizeof stack)) return 0;
    if (MbmPageOnTop(stack)) return 0;
    mbm.sweep_timer = timer;
    return 1;
}

/* A frame without a binding page: the sweep when due, and what a page borrowed goes back. Returns whether something
 * borrowed is still held. lint: per-frame */
static int MbmAwayFrame(void)
{
    if (mbm.page_open)
    {
        mbm.page_open = 0;
        mbm.page_visited = 1;
        mbm.sweep_timer = 0;
    }
    if (mbm.sweep_timer <= 0 || mbm.defaults_pending)
    {
        mbm.sweep_timer = MBM_SWEEP_INTERVAL;
        mbm_sweep();
    }
    mbm_tab_away();
    if (mbm.release_pending) mbm.release_pending = mbm_release_labels();
    return mbm.release_pending;
}

/* lint: per-frame */
static void MbmTick(VpmComponent* self, float dt)
{
    mbm.frame++;
    if (!mbm.code_ready) return; /* the build check's code is not decoded yet (MbmCodeReady) */
    if (MbmIdle(dt)) return;
    s_mbm.idle_armed = 0;
    if (!mbm.initialized && !MbmInitialize(self)) return;
    if (mbm.base == 0) return;
    if (mbm_assign_dirty()) mbm_assign_flush();
    if (mbm_extended_dirty()) mbm_extended_flush();
    MbmActivate(self);
    if (!mbm.ready) return;
    uintptr_t screen = mbm_active_screen();
    mbm.sweep_timer -= dt;
    /* Revert reads the native defaults while a page is open: they are prepared before its rows are used. */
    if (screen != 0)
    {
        (void)mbm_sanitize_defaults(); /* a record that cannot be read now is retried on the next page frame */
        mbm.sweep_timer = MBM_SWEEP_INTERVAL;
        if (!mbm.page_open)
        {
            mbm.page_open = 1;
            mbm.mission_check = 0;
        }
        mbm_page_frame(screen, dt);
        return;
    }
    if (!MbmAwayFrame() && !mbm.title_active) s_mbm.idle_armed = 1;
}

/* ---- the backend and the lifecycle -------------------------------------------------------------------------- */

/* vpm_binding_down: 1 down, 0 up, -1 unknown. lint: per-frame */
static int MbmDown(const VpmBinding* binding, void* data)
{
    MbmRecord* record = data;
    if (record == NULL) return -1;
    if (record->extended) return mbm_extended_down(record);
    return mbm_native_down(record);
}

static const VpmBindingBackend kMbmBackend = {mbm_attach, MbmDown};

/* The core stops the component: a key capture ends, the MODS title and the borrowed text slots go back, unless a
 * binding page still shows them. */
static void MbmStop(VpmComponent* self)
{
    if (!mbm.initialized) vpm_log(self, "%s", MBM_INACTIVE_NOTE); /* stopped before the build check passed */
    if (mbm.base == 0) return;
    mbm_panel_hide("stopped");
    if (mbm.ready && mbm_active_screen() != 0)
    {
        vpm_log(self, "A binding page is open; its borrowed text slots stay borrowed.");
        return;
    }
    mbm_mods_title(0);
    (void)mbm_release_labels(); /* a slot that cannot be cleared keeps its buffer: the DLL stays loaded */
}

/* The status says whether the MORE MODS page can be offered (it needs the engine's Gui and input). */
void mbm_refresh_status(void)
{
    if (mbm.self == NULL || !vpm_running(mbm.self)) return;
    vpm_set_status(mbm.self, mbm_panel_available() ? NULL
        : "running; the MORE MODS page is off (it needs the engine's Gui and input, not reachable from C yet)");
}

/* The build check's code read as shipped (the core's wait, from HF_EVENT_GAME_LOADED): the next frame checks the rest. */
static void MbmCodeReady(VpmComponent* self, HfEvent event) { mbm.code_ready = 1; }

static void MbmText(VpmComponent* self, char* out, size_t size, const char* key, const char* english)
{
    if (!mbm_display_text(vpm_text(self, key, english), 64, out, size)) snprintf(out, size, "%s", english);
}

static int MbmStart(VpmComponent* self)
{
    memset(&mbm, 0, sizeof mbm);
    memset(&s_mbm, 0, sizeof s_mbm);
    mbm.self = self;
    vpm_text_table(self, &vpm_texts_mod_bindings_menu);
    mbm.in_mission = 1; /* unknown counts as a mission, so MORE MODS is never offered before the check */
    MbmText(self, mbm.empty_text, sizeof mbm.empty_text, "section.none", "NO MOD BINDINGS INSTALLED");
    MbmText(self, mbm.unnamed_text, sizeof mbm.unnamed_text, "section.unnamed", "MODS");
    MbmText(self, mbm.more_text, sizeof mbm.more_text, "tab.more", "MORE MODS");
    MbmText(self, mbm.more_header_text, sizeof mbm.more_header_text, "section.more", "MORE MOD BINDINGS");
    mbm_maps_reset();
    mbm_sweep_reset();
    mbm_assign_reset();
    mbm_tab_reset();
    mbm_extended_reset();
    mbm_capture_reset();
    mbm_panel_reset();
    if (!vpm_tick_start(self, MbmTick)) return vpm_fail(self, "the game thread could not be reached");
    int checks = (int)(sizeof kMbmCodeChecks / sizeof kMbmCodeChecks[0]);
    if (!vpm_when_code_ready(self, kMbmCodeChecks, checks, MbmCodeReady))
        return vpm_fail(self, "game.dll's code checks refused");
    vpm_log(self, "Mod Bindings Menu initialized; waiting for native input actions.");
    mbm_refresh_status();
    vpm_bindings_set_backend(self, &kMbmBackend);
    return 0;
}

const VpmComponentDef vpm_component_mod_bindings_menu = {"mod_bindings_menu", "Mod Bindings Menu", "2.3", 0, MbmStart, MbmStop, NULL,
    /* MbmStart resets what must last the session: the assignments' session count (reservation expiry), the defaults
     * sweep's captured stock lists, and the binding page's borrowed title and label slots */
    "it keeps this session's binding changes and the game's borrowed menu texts, which a restart would lose"};
