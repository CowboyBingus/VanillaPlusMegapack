/* Know Your Constellation v4.1.1 (Lua: components/KnowYourConstellation/src, install.lua and the files kyc.h lists),
 * for build 25480438.
 *
 * Shows every enemy a mission can spawn, named as on the Helldivers wiki and weighted by spawn frequency, in a
 * gold-framed panel below the native panel of the war table's highlighted mission and of the briefing. It reads the
 * mission the way the game resolves it (seed, difficulty settings, campaign, operation, war and level modifiers, the
 * backend's exclusions), replays the constellation draw, and replays an offline roster of the build's enemy groups.
 *
 * Frame (install.lua's frame): the screen on top of the UI stack; the native panel's anchor; the selected mission's
 * identity; a re-sample every 0.5 s (every 0.1 s while the report is pending) once the loaded controller holds the
 * selection; the panel drawn with retained primitives. A report is published only from a complete sample of the
 * selection seen both before and after the reads. Expected transient states hide the panel with their reason and retry
 * next frame without counting; genuine errors count in bursts (8 in one burst stop the component; 3600 frames without
 * one end a burst), as the Lua's update guard counted them.
 *
 * On HellForge:
 * - The panel. The Lua drew it with stingray.Gui, which only the game's Lua reaches on HellForge. The pack ships one
 *   Lua file for it (lua/forecast_panel.lua, in the pack's data patch, started by Bingus Shared Loader): it makes the
 *   engine Gui calls and nothing else. This file still decides everything (which screen and mission, show, wait, hide,
 *   move), kyc_panel.c still lays the panel out, and kyc_lua.c hands each change to the Lua part's next update, which
 *   draws it in one call into the DLL (kyc_lua.c says how). So a change is drawn one frame later than the Lua drew it.
 *   Without the Lua part (no Bingus Shared Loader, another version) the panel is off: the first forecast logs why
 *   ("panel off: ..."), and every new forecast is logged (headline, large enemies with their meters, small enemies).
 * - Level 11. HellForge moves the difficulty table and adds level 11: the settings row comes from
 *   HfApi.difficulty_row while it has moved, else from the game's own table (as the Lua), checked by its level; a
 *   level-11 mission is accepted once HellForge has that level (the Lua refused every difficulty above 10), and its
 *   roster replays level 10's: HellForge's level 11 starts every enemy's weight as level 10's and allows every group
 *   that allows level 10, and the offline roster has 10 levels.
 * - game.dll's statics are plain loads (the Lua read them with ReadProcessMemory too); heap records go through
 *   vpm_read (guarded plain loads). The tick runs at the start of game.dll's frame update, where the Lua's update ran
 *   (its frame ran after the updates below it in the chain, which is still before game.dll's update), so the native
 *   panel's rectangle is the one the previous frame solved, as in the Lua.
 * - It starts ticking at HF_EVENT_GAME_LOADED (the Lua's first update came after game.dll had loaded).
 * - Its texts are the core's, from the Lua's locales/en.lua and zh-Hans.lua (vpm_text; the core reads the game's Text
 *   Language at start-up and a menu opening, as bingus_text's observe did). Dropped: the update guard's pause and
 *   resume after the game's own update fails (HellForge does not chain updates); the shutdown status; the Lua's JIT
 *   and loader specifics.
 *
 * Cost per frame (the core's tick): "reads" are vpm_read (guarded plain loads) of heap records, pinned by the tests;
 * the rest of what the Lua read with ReadProcessMemory are game.dll statics, now plain loads. The Lua's frame_budget
 * pins (test_budget.lua, test_idle.lua) counted both. No Windows call, no allocation and no log line on a frame that
 * does not act; no write ever.
 * - Idle (the ship, a mission's own screens): 1 read (the kept UI manager's screen stack); every 30th frame the full
 *   check: 1 read and 1 plain load. The Lua: 1 read, 2 every 30th.
 * - War table, a highlighted mission, steady: 9 reads and 7 plain loads (Lua: 16 reads). Briefing: 10 and 8 (Lua 18).
 *   A client's joinable hover: 21 and 9 (Lua 30). Loadout: 3 and 2 (Lua 5).
 * - A re-sample frame (every 0.5 s while a report is up, 0.1 s while one is pending): map 43 reads (Lua 64), with
 *   campaign spawn weights the same, briefing 44 (Lua 68), client 73 (Lua 99). The frame the war table opens: 44
 *   (Lua 70; the Lua's 5 Text Language reads were at a mod's start and a menu opening, and are the core's there too).
 *   The roster and the model are made again only when their inputs change.
 * - The panel (kyc_lua.c, the Lua part included): while it is hidden or still, no engine call and no ffi call; the
 *   Lua part's update reads one integer. A change (a new forecast, the native panel moved, shown, hidden): one call
 *   into the DLL from the Lua part with the panel's engine calls. Up and still, every 30th frame: the 3 checks (worlds,
 *   main world, window size; the Lua made them every frame). A scrolling headline: those 3 every frame plus one text
 *   update while it moves, as the Lua. Engine calls through the Lua part are unmeasured in game.
 * Once-only: nothing at start (the roster is static data); the first level-11 descriptor asks HellForge once whether
 * it has that level. */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "kyc.h"
#include "kyc_lua.h"
#include "kyc_panel.h"
#include "locale_data.h"

#define QUIET_CHECK 30        /* the idle gate's full check: every 30th frame */
#define BURST_ERRORS 8        /* genuine errors in one burst that stop the component */
#define CLEAN_FRAMES 3600     /* frames without one that end a burst */
#define REFRESH 0.5           /* seconds between re-samples of a published report */
#define PENDING_REFRESH 0.1   /* while the report is pending */

#define PHASE_WAITING 1
#define PHASE_VISIBLE 2
#define PHASE_WAITING_GUI 3
#define PHASE_PANEL_OFF 4

KycError kyc_error;

int kyc_pending(const char* reason)
{
    if (kyc_error.pending == NULL && kyc_error.failure[0] == 0) kyc_error.pending = reason;
    return 0;
}

int kyc_fail(const char* format, ...)
{
    if (kyc_error.pending != NULL || kyc_error.failure[0] != 0) return 0;
    va_list args;
    va_start(args, format);
    vsnprintf(kyc_error.failure, sizeof kyc_error.failure, format, args);
    va_end(args);
    if (kyc_error.failure[0] == 0) snprintf(kyc_error.failure, sizeof kyc_error.failure, "error");
    return 0;
}

void kyc_error_clear(void)
{
    kyc_error.pending = NULL;
    kyc_error.failure[0] = 0;
}

const char* kyc_error_text(void) { return kyc_error.pending != NULL ? kyc_error.pending : kyc_error.failure; }

const char* kyc_screen_name(int screen) { return screen == KYC_SCREEN_MAP ? "map" : screen == KYC_SCREEN_BRIEFING ? "briefing" : ""; }

static struct
{
    const KycReaders* readers;
    const KycReaders* override;
    char status[192];
    KycState state;
    /* the selection */
    int has_current;          /* g_model is the report to draw */
    int has_selected, selected_screen, controller_matches;
    KycKey selected_key;
    double elapsed;
    /* the idle gate */
    int quiet, quiet_frames;
    /* the status draw() last reported and its inputs */
    int drawn_phase, drawn_screen, drawn_has_key;
    char drawn_key[72], drawn_status[192];
    /* the model's inputs */
    int has_made, made_screen;
    uint32_t made_computed;
    KycKey made_key;
    KycTags made_tags;
    /* the burst of genuine errors */
    int burst_errors, clean_run;
    char burst_error[192];
    int told_off;             /* "panel off" is logged, once per start */
} s;

static KycDescriptor g_before, g_after;
static KycSnapshot g_sampled;
static KycAnchor g_anchor;
static KycModel g_model;

const KycState* kyc_state(void)
{
    s.state.status = s.status;
    s.state.burst_errors = s.burst_errors;
    s.state.has_key = s.has_selected;
    s.state.key = s.has_selected ? s.selected_key.text : NULL;
    return &s.state;
}

void kyc_use_readers(const KycReaders* readers)
{
    s.override = readers;
    s.readers = readers != NULL ? readers : kyc_game_readers();
}

/* ---- status --------------------------------------------------------------------------------------------------- */

static int PanelOff(void) { return kyc_gui()->unavailable() != NULL; }

/* The status (logged when it changes, on the frame that changes it). */
static void Report(VpmComponent* self, const char* message)
{
    if (strcmp(s.status, message) == 0) return;
    snprintf(s.status, sizeof s.status, "%s", message);
    vpm_log(self, "%s", message);
    char shown[192];
    if (PanelOff()) snprintf(shown, sizeof shown, "panel off (no Lua part); %s", message);
    vpm_set_status(self, PanelOff() ? shown : message);
}

/* A status change the log does not get (a later error of a burst). */
static void Quietly(VpmComponent* self, const char* message)
{
    snprintf(s.status, sizeof s.status, "%s", message);
    vpm_set_status(self, message);
}

static void ReportDraw(VpmComponent* self, int phase, int screen, const char* key)
{
    int has_key = key != NULL;
    if (strcmp(s.status, s.drawn_status) == 0 && phase == s.drawn_phase && screen == s.drawn_screen &&
        has_key == s.drawn_has_key && (!has_key || strcmp(key, s.drawn_key) == 0))
        return;
    s.drawn_phase = phase;
    s.drawn_screen = screen;
    s.drawn_has_key = has_key;
    snprintf(s.drawn_key, sizeof s.drawn_key, "%s", has_key ? key : "");
    static const char* const kPhase[5] = {"", "", "visible ", "waiting for GUI ", "panel off: "};
    if (phase == PHASE_WAITING)
        snprintf(s.drawn_status, sizeof s.drawn_status, "waiting for mission data %s %s", kyc_screen_name(screen),
            has_key ? key : "preview loading");
    else
        snprintf(s.drawn_status, sizeof s.drawn_status, "%s%s %s composition rules resolved", kPhase[phase],
            kyc_screen_name(screen), key);
    Report(self, s.drawn_status);
}

/* While the panel is off, each new forecast goes to the log: the in-game check of the port without the panel. */
static void LogForecast(VpmComponent* self, const KycModel* m)
{
    char line[1000];
    size_t used = (size_t)snprintf(line, sizeof line, "forecast %s %s: %s; large:", kyc_screen_name(m->screen), m->key.text,
        m->headline);
    for (int i = 0; i < m->large_count && used < sizeof line; i++)
        used += (size_t)snprintf(line + used, sizeof line - used, "%s %s %u", i > 0 ? "," : "", m->large[i], m->ticks[i]);
    vpm_log(self, "%s", line);
    used = (size_t)snprintf(line, sizeof line, "forecast %s %s small:", kyc_screen_name(m->screen), m->key.text);
    for (int i = 0; i < m->small_count && used < sizeof line; i++)
        used += (size_t)snprintf(line + used, sizeof line - used, "%s %s", i > 0 ? "," : "", m->small[i]);
    vpm_log(self, "%s", line);
}

/* ---- the selection ---------------------------------------------------------------------------------------------- */

static void ResetSelection(void)
{
    s.has_current = s.has_selected = s.controller_matches = 0;
    s.selected_screen = KYC_SCREEN_NONE;
    s.elapsed = 0;
    s.state.screen = KYC_SCREEN_NONE;
    s.state.complete = 0;
}

/* Identity every frame; an unresolved selection resolves at once when the controller catches up, then re-samples
 * at the bounded cadence. */
static int Select(const KycDescriptor* d)
{
    if (d == NULL)
    {
        s.has_current = s.has_selected = s.controller_matches = 0;
        s.state.complete = 0;
        s.elapsed = 0;
        return 1;
    }
    int changed = !s.has_selected || strcmp(s.selected_key.text, d->key.text) != 0 || s.selected_screen != d->screen;
    if (changed)
    {
        if (s.selected_screen != KYC_SCREEN_NONE && s.selected_screen != d->screen && !kyc_surface_clear()) return 0;
        s.has_current = 0;
    }
    if (changed || (d->controller_matches && !s.controller_matches)) s.elapsed = 0.5;
    s.controller_matches = d->controller_matches != 0;
    if (!s.controller_matches) s.has_current = 0;
    s.selected_key = d->key;
    s.has_selected = 1;
    s.selected_screen = d->screen;
    s.state.screen = d->screen;
    return 1;
}

static int Hide(VpmComponent* self, const char* message)
{
    ResetSelection();
    if (!kyc_surface_clear()) return 0;
    Report(self, message);
    return 1;
}

/* Nothing to show. With neither screen on top, the idle gate takes over. */
static int Hidden(VpmComponent* self, int screen)
{
    if (!Hide(self, "hidden")) return 0;
    if (screen == KYC_SCREEN_NONE) { s.quiet = 1; s.quiet_frames = 0; }
    return 1;
}

static int SameTags(const KycTags* a, const KycSnapshot* b)
{
    return a->count == b->tag_count && memcmp(a->tag, b->tags, (size_t)a->count) == 0;
}

/* The report and model of a published sample: the roster is computed again only when the mission inputs change, the
 * model only when the report, the key, the screen or the tags do. */
static int Forecast(VpmComponent* self, const KycSnapshot* snapshot)
{
    const KycReport* report;
    KycTags tags;
    tags.count = snapshot->tag_count;
    memcpy(tags.tag, snapshot->tags, sizeof tags.tag);
    int level = snapshot->d.key.difficulty > 10 ? 10 : snapshot->d.key.difficulty;
    if (!kyc_roster_report(snapshot->d.key.faction, level, &tags, &snapshot->zone, &snapshot->war, &report)) return 0;
    if (s.has_made && s.made_computed == kyc_roster_computed() && strcmp(s.made_key.text, snapshot->d.key.text) == 0 &&
        s.made_screen == snapshot->d.screen && SameTags(&s.made_tags, snapshot))
        return 1;
    s.has_made = 0;
    if (!kyc_model_make(self, snapshot, report, &g_model)) return 0;
    s.has_made = 1;
    s.made_computed = kyc_roster_computed();
    s.made_key = snapshot->d.key;
    s.made_screen = snapshot->d.screen;
    s.made_tags = tags;
    if (!PanelOff()) return 1;
    if (!s.told_off) vpm_log(self, "panel off: %s; forecasts are computed and logged", kyc_gui()->unavailable());
    s.told_off = 1;
    LogForecast(self, &g_model);
    return 1;
}

/* A complete sample of the selection seen both before and after the reads. */
static int Publishable(const KycSnapshot* snapshot, const KycDescriptor* before, int screen)
{
    return snapshot != NULL && snapshot->complete && snapshot->d.controller_matches && s.controller_matches &&
        strcmp(snapshot->d.key.text, before->key.text) == 0 && strcmp(snapshot->d.key.text, s.selected_key.text) == 0 &&
        snapshot->d.screen == screen && s.selected_screen == screen;
}

#define REFRESHED 1
#define REFRESH_HID 2

/* After the sample: the panel hides when the screen changed, or a client's hover ended, while it was read; else the
 * selection is taken again. *hid 1 when it hid. */
static int StillSelected(VpmComponent* self, int screen, const KycAnchor* anchor, int* hid)
{
    int now, has, hovered;
    *hid = 0;
    if (!s.readers->screen(&now)) return 0;
    if (now == screen)
    {
        if (!s.readers->descriptor(screen, &g_after, &has, &hovered)) return 0;
        if (!(anchor->client && hovered == 0)) return Select(has ? &g_after : NULL);
    }
    *hid = 1;
    return Hide(self, "hidden");
}

/* The re-sample of the selected mission: REFRESHED, REFRESH_HID (the panel had to hide), or 0 after an error. */
static int Refresh(VpmComponent* self, int screen, const KycAnchor* anchor, const KycDescriptor* before)
{
    int found, hid;
    s.elapsed = 0;
    if (!s.readers->sample(screen, &g_sampled, &found)) return 0;
    s.state.refreshes++;
    if (!StillSelected(self, screen, anchor, &hid)) return 0;
    if (hid) return REFRESH_HID;
    s.has_current = 0;
    if (!Publishable(found ? &g_sampled : NULL, before, screen)) return REFRESHED;
    if (!Forecast(self, &g_sampled)) return 0;
    s.has_current = 1;
    return REFRESHED;
}

static int Draw(VpmComponent* self, int screen, const KycAnchor* anchor, float dt)
{
    s.state.complete = s.has_current;
    if (!s.has_current)
    {
        if (kyc_surface_suspend(anchor) == KYC_ERROR) return 0;
        ReportDraw(self, PHASE_WAITING, screen, s.has_selected ? s.selected_key.text : NULL);
        return 1;
    }
    int drawn = kyc_surface_show(&g_model, dt, anchor);
    if (drawn == KYC_ERROR) return 0;
    ReportDraw(self, drawn ? PHASE_VISIBLE : PanelOff() ? PHASE_PANEL_OFF : PHASE_WAITING_GUI, screen, g_model.key.text);
    return 1;
}

/* A different forecast screen than the selection's: the selection and the panel start afresh. */
static int ScreenChange(int screen)
{
    if (s.selected_screen == KYC_SCREEN_NONE || s.selected_screen == screen) return 1;
    ResetSelection();
    return kyc_surface_clear();
}

/* This frame's selection. The native selection ends before the card's fade: a client's unhover hides at once (*hid),
 * while a hovered mission that is still loading keeps the frame. */
static int Selection(VpmComponent* self, int screen, int* hid)
{
    int has, hovered;
    *hid = 0;
    if (!s.readers->descriptor(screen, &g_before, &has, &hovered)) return 0;
    if (g_anchor.client && (hovered == 0 || (hovered == KYC_HOVER_UNKNOWN && !g_anchor.active)))
    {
        *hid = 1;
        return Hide(self, "hidden");
    }
    return Select(has ? &g_before : NULL);
}

/* The Lua part, once: adopted as the panel's route, or refused. */
static void LuaPart(VpmComponent* self)
{
    int adopted = kyc_lua_adopt();
    if (adopted > 0) vpm_log(self, "panel: drawn through the pack's Lua part (the engine's Gui)");
    else if (adopted < 0) vpm_log(self, "panel off: %s", kyc_lua_absent());
}

/* One frame that may act: 1, or 0 after an error (kyc_error says which kind). */
static int Frame(VpmComponent* self, float dt)
{
    int screen, found = 0, hid;
    s.state.frames++;
    LuaPart(self);
    if (!s.readers->screen(&screen)) return 0;
    if (screen != KYC_SCREEN_NONE && !s.readers->anchor(screen, &g_anchor, &found)) return 0;
    if (!found) return Hidden(self, screen);
    if (!ScreenChange(screen)) return 0;
    s.selected_screen = s.state.screen = screen;
    if (!Selection(self, screen, &hid)) return 0;
    if (hid) return 1;
    s.elapsed += dt > 0 ? dt : 0;
    if (s.controller_matches && s.elapsed >= (s.has_current ? REFRESH : PENDING_REFRESH))
    {
        int refreshed = Refresh(self, screen, &g_anchor, &g_before);
        if (refreshed != REFRESHED) return refreshed == REFRESH_HID;
    }
    return Draw(self, screen, &g_anchor, dt);
}

/* ---- the frame's outcome: idle, clean, waiting, failed ------------------------------------------------------------ */

/* Removes the forecast and starts the selection afresh (errors removing it are not counted: the Lua's pcall). */
static void Restore(void)
{
    s.quiet = 0;
    ResetSelection();
    (void)kyc_surface_drop();
    kyc_error_clear();
}

/* The idle gate: after a frame that found neither screen and hid everything, frames read only the kept screen stack
 * while it shows neither, and every 30th frame runs the full frame. lint: per-frame */
static int Idle(void)
{
    if (!s.quiet) return 0;
    s.quiet_frames++;
    if (s.quiet_frames >= QUIET_CHECK || !s.readers->quiet())
    {
        s.quiet = 0;
        return 0;
    }
    s.state.frames++;
    return 1;
}

static void Clean(void)
{
    s.clean_run++;
    if (s.clean_run == CLEAN_FRAMES) s.burst_errors = 0;
}

/* An expected transient state: hidden with its reason, retried next frame, never counted. */
static void Waited(VpmComponent* self)
{
    char status[192];
    snprintf(status, sizeof status, "hidden: %s", kyc_error.pending);
    s.state.pending++;
    Restore();
    Report(self, status);
}

/* A genuine error: the forecast is removed and the error counts; the burst's first logs its line, the 8th stops the
 * component. */
static void Failed(VpmComponent* self)
{
    char message[192], status[200];
    snprintf(message, sizeof message, "%s", kyc_error.failure[0] ? kyc_error.failure : "unknown error");
    s.state.failures++;
    s.clean_run = 0;
    Restore();
    snprintf(status, sizeof status, "hidden: %s", message);
    if (s.burst_errors == 0) Report(self, status);
    else Quietly(self, status);
    if (++s.burst_errors == 1)
    {
        snprintf(s.burst_error, sizeof s.burst_error, "%s", message);
        vpm_log(self, "error: %s", message);
    }
    if (s.burst_errors >= BURST_ERRORS) (void)vpm_fail(self, "stopped after: %d errors: %s", BURST_ERRORS, s.burst_error);
}

/* lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    if (Idle()) { Clean(); return; }
    kyc_error_clear();
    if (Frame(self, dt)) { Clean(); return; }
    if (kyc_error.pending != NULL) { Waited(self); Clean(); return; }
    Failed(self);
}

static void GameLoaded(VpmComponent* self, HfEvent event)
{
    if (vpm_ticking(self)) return;
    if (!vpm_tick_start(self, Tick)) (void)vpm_fail(self, "the game thread could not be reached");
}

static void Stop(VpmComponent* self)
{
    (void)kyc_surface_clear();
    kyc_error_clear();
}

static int Start(VpmComponent* self)
{
    const KycReaders* override = s.override;
    memset(&s, 0, sizeof s);
    vpm_text_table(self, &vpm_texts_know_your_constellation);
    kyc_error_clear();
    kyc_mission_reset();
    kyc_roster_reset();
    if (!kyc_lua_route() || kyc_panel_view()->gui == 0) kyc_panel_reset(); /* else a stop's clear waits for the Lua */
    kyc_lua_bind(self);
    kyc_use_readers(override);
    snprintf(s.status, sizeof s.status, "starting");
    Report(self, "ready");
    return vpm_on_load(self, HF_EVENT_GAME_LOADED, GameLoaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_know_your_constellation = {"know_your_constellation", "Know Your Constellation", "4.1.1", 0, Start, Stop};
