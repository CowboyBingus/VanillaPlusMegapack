/* Match Your Colors v1.5: the helmet takes the armor's colors, the armor the helmet's, or both the cape's (Color
 * Matching), or both a weapon paint scheme's (Paint Scheme); the cape can follow (Recolor Cape) and so can the weapons
 * (Recolor Weapons, experimental). Squadmates who use the mod see each other's colors (their settings travel as a PlayFab
 * lobby member property, "cbmyc2"); Recolor Squadmates recolors the others on this screen; Hide Cape hides capes.
 *
 * How it recolors (the Lua's, 1:1): a job reads the kits' records in game memory and their textures from the game's
 * data files, analyses their colors (cached on disk), plans new color tables (LUTs), patterns, cape tints, emblem
 * sheets or albedos, and the game thread binds runtime textures holding them to the units' materials through the
 * engine's script C API tables ([game + 0x3326308]: Unit +24, Material +40, Mesh +232) and get_engine_api (exe 0xa4e50:
 * 26 RenderBufferApi, 5 ResourceManagerApi). Nothing is written to game memory: every change is an engine call, and
 * stopping binds the original textures back. The files: myc_addon*.c the step and its jobs, myc_job*.c the jobs,
 * myc_pipeline.c and myc_cache.c the session's data and the disk cache, myc_bindings.c the bindings controller,
 * myc_engine.c the engine calls, myc_avatar.c / myc_preview.c / myc_weapons_mem.c game memory, myc_sync.c /
 * myc_remote.c / myc_lineup.c / myc_cloak.c / myc_loadout.c the squad, capes and weapons, the rest the color math.
 *
 * On HellForge (what differs from the Lua, and why):
 *   - jobs run on a worker thread (myc_worker.c says why) where the Lua sliced a coroutine 1.5 ms per frame; a job is
 *     applied on the frame after it ends, the earliest; the log gives the worker's time in place of the slices;
 *   - the engine is opened on HellForge's game-loaded event and, when the engine has not filled its script API yet,
 *     again every 30 frames until it has (the Lua ran after the engine's script setup);
 *   - the options are the core's (the Lua's ids, kinds, labels and defaults; Recolor Weapons says it is experimental);
 *     texts are English (vpm_text);
 *   - the disk cache lives in vpm_data_folder (%LOCALAPPDATA%\CowboyBingus\VanillaPlusMegapack\match_your_colors\
 *     MatchYourColors.cache); with no shutdown event, it is not written at shutdown (the save after a job still is);
 *   - no pause (the core has none): an error of the step is logged and counted as the Lua's guard did (8 stop it);
 *   - the reader's file handles are closed by the worker (the Lua closed 4 per binding check on the game thread);
 *   - the lobby's PlayFab functions come from vpm_module_export (PlayFabMultiplayerWin.dll, HellForge's stand-in in a
 *     HellForge session), once; its member ids there are SteamID64s in hex, the players' peers, as the sync expects.
 *
 * COST per frame (the Lua's tests/test_addon.lua frame_budget pins in brackets; reads are vpm_read's guarded plain
 * loads, about 25 ns in the test process, where the Lua's read_into was a ReadProcessMemory, 1-2 us in game):
 *   - before the game loads and while the engine's script API is not filled: one compare, and every 30 frames one
 *     code_matches of get_engine_api's first bytes and a plain load of game.dll's script API pointer;
 *   - no local Helldiver (title screen, loading, dead): one resolve every 15 frames (1 read with no player manager, up to
 *     about 20 for the whole chain), nothing between [the same];
 *   - idle (the Helldiver found, nothing changed): 1 read of its 120 unit bytes, +1 on odd frames for its preview slot's
 *     entries while something is recolored; every 30 frames 2 more (one recolored material's binding); every 120 frames
 *     the chain resolved again (about 20 reads); on 1 frame in 4, 1 read of the UI preview's gate while it is not shown
 *     [read_into 1, +1, +2, the chain: the same counts]. No Windows call, no allocation, no log line;
 *   - the squad: every 120 frames the lobby poll (PlayFab's GetMembers and one GetMemberProperty per member, the
 *     network context's reads) [the same]; Recolor Weapons on: 1 read per frame of the weapon in hand's LUT binding and
 *     the inventory row on 1 frame in 4 [the same];
 *   - a job: on its first frame the request and one SetEvent; while it runs one plain load of the worker's flag a frame
 *     [the Lua: up to 1.5 ms of the job's work a frame on the game thread]; on the frame it is applied, the resolve and
 *     the engine calls of the apply (alive, meshes, mesh, materials, material, set_resource, commit, and create or
 *     update for each runtime texture) [the same calls];
 *   - once: the engine's 14 function addresses compared, the PlayFab exports looked up, the worker thread made with the
 *     first job.
 *
 * Diagnostics (the pack's own, not the Lua's): in Detailed mode each apply of the Helldiver's or the preview's plan logs
 * where it read the units and, per unit, the material instances it bound and how many slots read back the texture just
 * bound (myc_controller_report: one binding read per slot and one alive per unit, on that frame only); a tester's mark
 * describes the same for both in short. A stop logs how many slots it put back to their original colors (a fault on
 * the worker stops the component, and its stop is what puts the originals back). Idle frames log nothing in either mode. */
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "myc_addon.h"

#define g myc_g
#define ENGINE_RETRY_FRAMES 30

/* The options in menu order: their ids (as the Lua's, after "cowboybingus.match_your_colors."), the instance's names. */
enum { O_MODE, O_SCHEME, O_SQUAD, O_SQUAD_COLORS, O_HIDE_CAPE, O_SETS, O_HOODS, O_MATERIALS, O_CAPES, O_WEAPONS, O_COUNT };
static const char* const kNames[O_COUNT] = {"mode", "scheme", "squad", "squad_colors", "hide_cape", "keep_sets",
                                            "recolor_hoods", "match_materials", "recolor_cape", "recolor_weapons"};

static struct
{
    VpmComponent* self;
    int open, waiting_noted;
    uint32_t frames;
    VpmOption* options[O_COUNT];
} s;

static VpmOptionDef g_defs[O_COUNT];
static const char* g_modeChoices[5];
static const char* g_schemeChoices[MYC_SCHEMES + 2];
static const char* g_squadChoices[4];
static const char* g_squadColorChoices[3];
static const char* g_hideChoices[4];

static const char* MycTr(const char* key, const char* english) { return vpm_text(s.self, key, english); }

/* ---- options ------------------------------------------------------------------------------------------------------ */

static void MycChoices(void)
{
    g_modeChoices[0] = "Off";
    g_modeChoices[1] = MycTr("option.mode.helmet", "Helmet Matches Armor");
    g_modeChoices[2] = MycTr("option.mode.armor", "Armor Matches Helmet");
    g_modeChoices[3] = MycTr("option.mode.cape", "Helmet and Armor Match Cape");
    g_modeChoices[4] = NULL;
    g_schemeChoices[0] = "Off";
    int n = 1;
    for (int i = 1; i <= MYC_SCHEMES; i++)
    {
        const MycScheme* scheme = myc_scheme_get(i);
        if (scheme == NULL) continue;
        char key[48];
        snprintf(key, sizeof key, "scheme.%s", scheme->id);
        g_schemeChoices[n++] = MycTr(key, scheme->label);
    }
    g_schemeChoices[n] = NULL;
    g_squadChoices[0] = "Off";
    g_squadChoices[1] = MycTr("option.squad.missing", "Squadmates Without the Mod");
    g_squadChoices[2] = MycTr("option.squad.everyone", "Everyone");
    g_squadChoices[3] = NULL;
    g_squadColorChoices[0] = MycTr("option.squad_colors.own", "Their Own Gear");
    g_squadColorChoices[1] = MycTr("option.squad_colors.yours", "Your Colors");
    g_squadColorChoices[2] = NULL;
    g_hideChoices[0] = "Off";
    g_hideChoices[1] = MycTr("option.hide_cape.yours", "Your Cape");
    g_hideChoices[2] = MycTr("option.hide_cape.everyone", "Everyone's Capes");
    g_hideChoices[3] = NULL;
}

static VpmOptionDef MycChoiceOption(const char* id, const char* label, const char* description, int value, const char* const* choices)
{
    return (VpmOptionDef){id, VPM_CHOICE, label, description, value, 0, 0, 0, choices, 0};
}

static VpmOptionDef MycToggleOption(const char* id, const char* label, const char* description, int value)
{
    return (VpmOptionDef){id, VPM_TOGGLE, label, description, value, 0, 0, 0, NULL, 0};
}

static void MycDefinitions(void)
{
    MycChoices();
    g_defs[O_MODE] = MycChoiceOption("mode", MycTr("option.mode.label", "Color Matching"), MycTr("option.mode.description",
        "Recolors your helmet to your armor's colors, your armor to your helmet's, or both to your cape's. Squadmates who use "
        "this mod see your colors too (your settings are shared through the squad's online lobby); players without it see "
        "your gear as it is. Visors, lenses and lights keep their colors."), MYC_HELMET_FROM_ARMOR, g_modeChoices);
    g_defs[O_SCHEME] = MycChoiceOption("paint_scheme", MycTr("option.scheme.label", "Paint Scheme"), MycTr("option.scheme.description",
        "Paints your helmet and armor in one of the game's weapon paint schemes, or in the SEAF troopers' colors. While a "
        "scheme is chosen, Color Matching and Leave Complete Sets do not apply; Recolor Hoods and Match Materials do. Visors, "
        "lenses and lights keep their colors."), 1, g_schemeChoices);
    g_defs[O_SQUAD] = MycChoiceOption("recolor_squadmates", MycTr("option.squad.label", "Recolor Squadmates"), MycTr("option.squad.description",
        "Recolors your squadmates' helmets and armor with your settings, on your screen only. Squadmates Without the Mod: "
        "players who use this mod keep the colors they chose. Everyone: every squadmate takes your settings. Nothing changes "
        "for them: only you see it."), MYC_SQUAD_OFF, g_squadChoices);
    g_defs[O_SQUAD_COLORS] = MycChoiceOption("squadmates_colors", MycTr("option.squad_colors.label", "Squadmates' Colors"),
        MycTr("option.squad_colors.description", "For the squadmates Recolor Squadmates recolors. Their Own Gear: your Color "
        "Matching on their own gear (their armor matches their own helmet, for example), so a matching set barely changes. "
        "Your Colors: their helmet and armor take your colors, those of the item your Color Matching matches (your armor, "
        "helmet or cape); a paint scheme gives everyone the scheme. Only you see it."), MYC_SQUAD_OWN, g_squadColorChoices);
    g_defs[O_HIDE_CAPE] = MycChoiceOption("hide_cape", MycTr("option.hide_cape.label", "Hide Cape"), MycTr("option.hide_cape.description",
        "Hides capes on the ship and in missions. Your Cape: yours, also on the screens of squadmates who use this mod. "
        "Everyone's Capes: yours and every squadmate's, on your screen. The Armory and the loadout screen still show capes, "
        "so you can still pick one. Players without this mod still see your cape."), MYC_HIDE_OFF, g_hideChoices);
    g_defs[O_SETS] = MycToggleOption("keep_sets", MycTr("option.sets.label", "Leave Complete Sets"), MycTr("option.sets.description",
        "Keeps the original colors while your helmet and armor belong to the same set."), 1);
    g_defs[O_HOODS] = MycToggleOption("recolor_hoods", MycTr("option.hoods.label", "Recolor Hoods"), MycTr("option.hoods.description",
        "Recolors hoods too, such as those of the RS-100 Sanctioner and SC-30 Trailblazer Scout helmets. Off: a hood keeps "
        "its own color, like the visor, while the rest of the helmet still matches."), 1);
    g_defs[O_MATERIALS] = MycToggleOption("match_materials", MycTr("option.materials.label", "Match Materials"),
        MycTr("option.materials.description", "Parts take the material of the color they take: metal parts that take a painted "
        "color become that paint (a chrome helmet with a white armor turns white, not bronze), and hard painted parts that "
        "take a helmet's or armor's bare metal become that metal (chrome, gold, cobalt). Cloth and small metal details keep "
        "their material."), 0);
    g_defs[O_CAPES] = MycToggleOption("recolor_cape", MycTr("option.capes.label", "Recolor Cape"), MycTr("option.capes.description",
        "Recolors your cape too, to the same colors: the armor's with Helmet Matches Armor, the helmet's with Armor Matches "
        "Helmet, or the paint scheme's. A complete set left alone still gives its cape its colors. With Helmet and Armor "
        "Match Cape the cape keeps its colors (it is the one matched). Emblems and other decals keep their colors."), 0);
    g_defs[O_WEAPONS] = MycToggleOption("recolor_weapons", MycTr("option.weapons.label", "Recolor Weapons"),
        MycTr("option.weapons.description", "Experimental. Recolors your weapons too (primary, sidearm, support weapon and "
        "their attachments), to the same colors as the cape: the armor's, the helmet's, the cape's or the paint scheme's. "
        "While on, it replaces a weapon's own paint scheme. Lenses, lights and decals keep their colors; grenades and "
        "backpacks keep theirs."), 0);
}

/* An option's value as the instance takes it (the scheme: 0 none, 1 to the schemes' count). */
static int MycValueOf(int option, double value)
{
    int v = (int)value;
    return option == O_SCHEME ? v - 1 : v;
}

static void MycChanged(VpmComponent* self, VpmOption* option, double value)
{
    if (!s.open) return; /* read when the engine opens */
    for (int i = 0; i < O_COUNT; i++)
        if (s.options[i] == option) myc_addon_set_option(kNames[i], MycValueOf(i, value), i >= O_SETS);
}

static void MycRegister(void)
{
    MycDefinitions();
    for (int i = 0; i < O_COUNT; i++)
    {
        s.options[i] = vpm_option(s.self, &g_defs[i]);
        if (s.options[i] != NULL) vpm_option_on_change(s.options[i], MycChanged);
    }
}

/* The menu's values applied (follow): set_option logs only changes from the instance's defaults. */
static void MycFollow(void)
{
    for (int i = 0; i < O_COUNT; i++)
    {
        double value = s.options[i] != NULL ? vpm_option_value(s.options[i]) : g_defs[i].value;
        myc_addon_set_option(kNames[i], MycValueOf(i, value), i >= O_SETS);
    }
    char text[320];
    myc_addon_options_text(text, sizeof text);
    myc_notef("Options: %s.", text);
}

/* ---- the instance ------------------------------------------------------------------------------------------------- */

/* The instance's defaults (Addon.new state.options): Follow then applies the menu's values. */
static void MycDefaults(void)
{
    MycOptions* o = &g.options;
    o->mode = MYC_HELMET_FROM_ARMOR;
    o->keep_sets = 1;
    o->recolor_hoods = 1;
    o->match_materials = o->recolor_cape = o->recolor_weapons = 0;
    o->scheme = 0;
    o->squad = MYC_SQUAD_OFF;
    o->squad_colors = MYC_SQUAD_OWN;
    o->hide_cape = MYC_HIDE_OFF;
    o->cape_hidden = 0;
    g.active = 1;
}

static void MycOpen(void)
{
    myc_pool_init(&g.pool, &g.native);
    myc_controller_init(&g.controller, &g.native, &g.pool);
    myc_controller_init(&g.ui_controller, &g.native, &g.pool);
    myc_sync_init(&g.session, myc_note);
    myc_remote_init(&g.remote, &g.native, &g.pool, myc_note, myc_records_same, NULL, 1);
    myc_lineup_init(&g.lineup, &g.native, &g.pool, myc_note, &g.remote, myc_records_same, NULL);
    myc_loadout_init(&g.loadout, &g.native, &g.pool, myc_note, "");
    myc_cloak_init(&g.cloak, &g.native, myc_note);
    g.has_sync = g.syncing = g.has_lineup = g.has_loadout = 1;
    g.has_cloak = g.native.visibility != NULL;
    MycDefaults();
    myc_addon_init_sync_text();
    vpm_set_status(s.self, "starting");
    s.open = 1;
    myc_note("Match Your Colors v1.5 initialized.");
    MycFollow();
}

/* Engine.open, until the engine has filled its script API: -1 waits (the reason logged once), 0 stops the component. */
static void MycTryOpen(void)
{
    const char* why = NULL;
    int opened = myc_engine_open(&g.native, &why);
    if (opened > 0) { MycOpen(); return; }
    if (opened == 0) { vpm_fail(s.self, "%s", why); return; }
    if (s.waiting_noted) return;
    s.waiting_noted = 1;
    char status[96];
    snprintf(status, sizeof status, "waiting for the engine (%s)", why);
    vpm_set_status(s.self, status);
    myc_notef("Waiting for the engine (%s).", why);
}

/* lint: per-frame */
static void MycTick(VpmComponent* self, float dt)
{
    if (s.open) { myc_addon_step(); return; }
    if (s.frames++ % ENGINE_RETRY_FRAMES == 0) MycTryOpen();
}

static void MycLoaded(VpmComponent* self, HfEvent event)
{
    if (!vpm_tick_start(self, MycTick)) vpm_fail(self, "no game-thread tick");
}

/* The cache file's path in the component's data folder, or none (the cache is then off for the session). */
static void MycPaths(void)
{
    MycWorker* w = &g.worker;
    if (!myc_files_data_folder(w->data_folder, (int)(sizeof w->data_folder / sizeof w->data_folder[0])))
        myc_note("The game's data folder was not found: jobs will fail.");
    wchar_t folder[1024];
    if (!vpm_data_folder(s.self, folder, sizeof folder / sizeof folder[0]))
    {
        myc_note("Analysis cache: off (no data folder).");
        return;
    }
    int n = swprintf(w->cache_path, sizeof w->cache_path / sizeof w->cache_path[0], L"%ls\\%ls", folder, MYC_CACHE_FILE);
    w->has_cache = n > 0;
}

static void MycStop(VpmComponent* self)
{
    /* Always on the game thread: a fault on the worker is reported from there (myc_worker_busy). */
    if (!s.open) return;
    int ended = myc_worker_stop(&g.worker, 1000);
    if (!ended) myc_note("The worker thread did not end within 1 s of the stop; it is left to finish its task.");
    g.job = g.saving = 0;
    int helldiver = g.controller.restored, preview = g.ui_controller.restored;
    myc_addon_restore_all();
    helldiver = g.controller.restored - helldiver;
    preview = g.ui_controller.restored - preview;
    if (ended && g.worker.pipeline != NULL) myc_pipeline_close(g.worker.pipeline);
    g.has_reader_kept = g.close_due = 0;
    const char* status = vpm_status(self);
    const char* reason = strncmp(status, "disabled: ", 10) == 0 ? status + 10 : status;
    myc_notef("Stopped (%s).", reason);
    if (helldiver > 0 || preview > 0)
        myc_notef("Original colors put back: %d slots on the Helldiver, %d on the preview.", helldiver, preview);
}

/* The core's summary line (at a mission's end and at a tester's mark): the worker's state. */
static void MycSummary(VpmComponent* self, char* out, size_t size) { myc_worker_describe(&g.worker, out, size); }

/* The describe line for a tester's mark: what the Helldiver and the preview have bound and what reads back. */
static void MycDescribe(VpmComponent* self, char* out, size_t size)
{
    if (!s.open) { snprintf(out, size, "engine not opened yet"); return; }
    myc_addon_describe(out, size);
}

static int MycStart(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    memset(&g, 0, sizeof g);
    s.self = self;
    g.self = self;
    g.worker.self = self;
    MycRegister();
    MycPaths();
    vpm_on_summary(self, MycSummary);
    if (!vpm_on_load(self, HF_EVENT_GAME_LOADED, MycLoaded)) return vpm_fail(self, "no game-loaded event");
    return 0;
}

const VpmComponentDef vpm_component_match_your_colors = {"match_your_colors", "Match Your Colors", "1.5", 0, MycStart, MycStop,
    MycDescribe, "its background worker, textures and lobby colors need a new session to be let go safely"};
