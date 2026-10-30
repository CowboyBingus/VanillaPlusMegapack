/* Better Lobby Management v1.2.1 (Lua: components/BetterLobbyManagement/src, addon.lua and its modules), for build
 * 25480438.
 *
 * Host tools for the squad, all on the game's own systems:
 * - DISBAND SQUAD and PROMOTE <NAME> on the escape menu's GAME tab while hosting a squad on the ship (blm_menu.c,
 *   blm_lobby.c): each confirmed in the game's own dialog, each kick the player menu's own KICK. PROMOTE kicks the
 *   successor home, finds the lobby they host by its host id and moves the squad there with the game's party join; the
 *   successor is the squad member whose player menu the host opened last, else a friend, else the lowest peer id.
 * - CANCEL SOS in a mission while the host's SOS Beacon is on (blm_sos.c): the SOS stops, stays stopped through the
 *   game's re-arms, the lobby's privacy setting comes back at once, and the SOS Beacon gets its use back.
 * - Squad messages before the kicks (blm_chat.c, option "Squad Messages"): the game's own "<name> is the new squad
 *   leader" notice for PROMOTE, a chat line from the host for DISBAND.
 * - The Galactic Map scanner's recharge (blm_scanner.c, option "Scanner Recharge (Seconds)", 5 s by default).
 * - Lobby Region (blm_region.c, option "Lobby Region"): My Continent Only limits the game's lobby searches to the
 *   player's continent.
 * Every part checks its own code first: a mismatch disables that part alone, as in the Lua; the network layout, its
 * natives and the engine's lobby API are needed by all.
 *
 * On HellForge: HF_EVENT_GAME_LOADED runs the checks; the engine API tables may not exist yet then, so the component
 * waits for them (one plain load per frame, at most 600 s). game.dll's code (and the exe's) is decoded in parts after
 * that event, so the code checks wait for it (vpm_when_code_ready): the network code, the PlayFab layout and the natives
 * from the event, the engine slots' functions once the API tables exist, each at once and then every 30 frames until
 * they read as shipped; code that never does within 60 s stops the component ("host-left check changed (game.dll
 * 0x10834ED)"), before anything changed. A part whose own code does not read as shipped yet is left out as before, and
 * looked at again on every 30th frame for 60 s: it joins once its code reads as shipped (its setting applied, a log
 * line), else it stays out for the session. When the engine slots are ready, the Text Language is observed and the
 * options registered, as the Lua's first update did; the settings are applied on the first frame after the checks. The
 * options are the core's (vpm_option, the Lua's ids, kinds and defaults); texts are the Lua's locales/en.lua and
 * zh-Hans.lua through vpm_text. Game state is the Lua's own
 * reads (the mode at +0xAC21C, the host and peers in the network context), not HellForge's events. The SOS Beacon's
 * settings are read through the stratagem
 * list the game reads now (HellForge moves it when mods add stratagems). The lobbies come from HellForge's local
 * backend: DISBAND and CANCEL SOS need nothing of it beyond the game's own lobby calls; PROMOTE finds the successor's
 * lobby only when HellForge's directory lists it (Public, the successor's listing switch and Play with strangers on);
 * the scanner works from the game's compiled 10 s (the backend serves no matchmaking settings); the directory leaves
 * the continent exclusions out of every search, so Lobby Region writes its flags but changes no result. Dropped from
 * the Lua: the test builds' diagnostics recorder (a per-frame copy of the engine's package queue and in-use table while
 * hosting a squad, for the kick crash the game's own KICK fixed), kick modes and unload hold, the BingusTranslations
 * packs (no Lua state), the Mod Options Menu registration retries, the shared runtime's update guard (the core's crash
 * guard stops the component instead), the shutdown hook and the Lua entry points.
 *
 * Diagnostics (the pack's Detailed mode, vpm_log_detail): the test builds' verbose lines come back, on frames that
 * already act and on change only: each successor search, why one waits, its timeout and its results (blm_lobby.c); the
 * squad message's recipients and the chat history before and after it, the squad leader notice's recipients
 * (blm_chat.c); the escape menu's dialog and focus state when it changes (blm_menu.c blm_menu_trace); and at each
 * mission's end the counters of the Lua's shutdown line (actions, page checks, the scanner, the SOS cancels and
 * re-arms, nearby lobbies). describe gives the start-up phase, the parts, the running action and the counters.
 *
 * Direct loads are plain loads on objects a read confirmed once (blm.h), as the Lua's. COST per frame (the Lua's
 * frame_budget pins in brackets):
 * - Idle (nothing pending, escape screen closed), in every session state: 4 plain loads (the menu system and its screen,
 *   the scanner's config object and field), no read, no page check, no Windows call [Lua: 4 direct loads]. The menu
 *   system is confirmed once with one read. With Lobby Region on, every 120th frame adds its check: plain loads and the
 *   engine's continent call [Lua: the same].
 * - Escape menu open with nothing to do (hosting a squad on the ship, or alone in a mission with an SOS on): plain loads
 *   only and no native call, except the opening with an action to offer: that observes the Text Language (0 to 3 reads,
 *   3 when the table is present [Lua: 5]) and rebuilds the offer on a change [Lua: 47 and 46 direct loads, no Windows
 *   call].
 * - A kept SOS cancel: 6 plain loads on top of the full frame [Lua: 6]; a caught re-arm: two native calls, no page check
 *   [Lua: 1 when the lobby had already posted it].
 * - Acting frames: the Lua's reads and native calls (CANCEL SOS: 8 reads, 2 page checks [Lua: 8, 2]; adding the buttons:
 *   1 page check [1]; a new screen: 2 reads [2]). Page checks (VirtualQuery) are made once per target where the Lua
 *   checked before every write: the scanner's field and countdown, the override table, the lobby's post countdown (the
 *   game rewriting the scanner field: 1 read, 0 page checks [Lua: 1, 1]; turning Lobby Region off: 0 [1]).
 * - Detailed mode (the diagnostics above): idle frames unchanged (no read, no log, no vpm_detailed check); frames that
 *   act +1 global read where a detailed line exists (a search step, a squad message, an open escape menu), and in
 *   Detailed mode a menu trace's 13 plain loads per open-menu frame, a line only when they changed; a squad message
 *   +2 plain loads of the chat history.
 * - Once: 73 code checks (HfApi.code_matches) and 6 reads for the engine's lobby and package slots; the ready step
 *   observes the Text Language (0 to 3 reads, 3 when the table is present [Lua: 5]). While code is not decoded yet: the
 *   waiting checks every 30 frames (at most 60 s), nothing else; a part left out: its checks on every 30th frame for
 *   60 s. */
#include <stdio.h>
#include "blm.h"
#include "locale_data.h"

#define VERSION "v1.2.1"
#define WAIT_SECONDS 600.0f
#define PARTS_WAIT_SECONDS 60.0f /* a part's code is looked at again for this long (game.dll is decoded in parts) */
#define PARTS_FRAMES 30
#define OPTION_REGION 0
#define OPTION_MESSAGES 1
#define OPTION_SCANNER 2
#define OPTIONS 3
#define WHY_SIZE 96

typedef struct Shown
{
    long long mode;
    int count;
    uint64_t peers[BLM_MAX_PEERS];
    uint64_t chosen;
    int hasChosen;
    int sosOn;
    uint32_t sosPrivacy;
    uint64_t target;
    int hasTarget;
} Shown;

static struct
{
    int verified, ready;
    int settingsPending;          /* the saved settings wait for the first frame */
    float waited;
    int partsPending;             /* a part's code did not read as shipped: looked at again (RecheckParts) */
    float partsWaited;
    int partsFrames;
    double clock;
    int quiet;                    /* nothing pending after the last full frame */
    int menuSeen;                 /* the offer menu's opening: its texts were observed for this opening */
    char textLanguage[32];        /* the tag of the last Text Language observation */
    int menu, sos, chat, region, scanner; /* the parts that passed their checks */
    char menuWhy[WHY_SIZE], sosWhy[WHY_SIZE], chatWhy[WHY_SIZE], regionWhy[WHY_SIZE], scannerWhy[WHY_SIZE];
    uint32_t scanned;
    int hasScanned;
    BlmContextCache gate;
    uint64_t chosen;              /* the squad member whose player menu the host opened last */
    int hasChosen;
    Shown shown;                  /* what the offer was built from: rebuilt only when it changes */
    BlmOffer offer;
    VpmOption* options[OPTIONS];
} s;

static const char* g_regionChoices[3];
static const char* g_messageChoices[3];
static VpmOptionDef g_options[OPTIONS];

/* ---- settings ---------------------------------------------------------------------------------------------------- */

static void ApplySetting(int option, double value)
{
    if (option == OPTION_SCANNER)
    {
        if (s.scanner) (void)blm_scanner_set_setting(value);
    }
    else if (option == OPTION_MESSAGES) blm_lobby_use(value != 2 && s.chat, s.menu);
    else if (s.region) (void)blm_region_set_mode((int)value);
    else if (value == 2) vpm_log(blm_component, "nearby lobbies unavailable: %s", s.regionWhy);
}

static void OnRegion(VpmComponent* self, VpmOption* option, double value) { if (s.ready && !s.settingsPending) ApplySetting(OPTION_REGION, value); }
static void OnMessages(VpmComponent* self, VpmOption* option, double value) { if (s.ready && !s.settingsPending) ApplySetting(OPTION_MESSAGES, value); }
static void OnScanner(VpmComponent* self, VpmOption* option, double value) { if (s.ready && !s.settingsPending) ApplySetting(OPTION_SCANNER, value); }

static void DefineOptions(void)
{
    g_regionChoices[0] = blm_tr("option.region.default", "Game Default");
    g_regionChoices[1] = blm_tr("option.region.continent", "My Continent Only");
    g_regionChoices[2] = NULL;
    g_messageChoices[0] = "On"; /* the game's own words */
    g_messageChoices[1] = "Off";
    g_messageChoices[2] = NULL;
    g_options[OPTION_REGION] = (VpmOptionDef){"region", VPM_CHOICE, blm_tr("option.region.label", "Lobby Region"),
        blm_tr("option.region.description", "My Continent Only limits the Galactic Map scanner and quickplay to lobbies "
            "hosted on your continent (the lowest-latency hosts the game can tell apart). It adds no searches; fewer "
            "lobbies may be listed."), 1, 0, 0, 0, g_regionChoices, 0};
    g_options[OPTION_MESSAGES] = (VpmOptionDef){"messages", VPM_CHOICE, blm_tr("option.messages.label", "Squad Messages"),
        blm_tr("option.messages.description", "Before kicking, the squad is told why. PROMOTE shows the game's own \"<name> "
            "is the new squad leader\" line; DISBAND posts a chat message from you."), 1, 0, 0, 0, g_messageChoices, 0};
    g_options[OPTION_SCANNER] = (VpmOptionDef){"scanner_seconds", VPM_SLIDER, blm_tr("option.scanner.label",
        "Scanner Recharge (Seconds)"), blm_tr("option.scanner.description", "Seconds the Galactic Map lobby scanner "
            "recharges between scans, from 5 to 20. The game currently uses 20; the mod never makes the wait longer than "
            "the game's own. Every scan is a lobby search, so a shorter wait searches more often."),
        BLM_SCANNER_DEFAULT, BLM_SCANNER_MIN, BLM_SCANNER_MAX, 1, NULL, 0};
}

static void RegisterOptions(VpmComponent* self)
{
    static const VpmOptionFn handlers[OPTIONS] = {OnRegion, OnMessages, OnScanner};
    DefineOptions();
    for (int i = 0; i < OPTIONS; i++)
    {
        s.options[i] = vpm_option(self, &g_options[i]);
        if (s.options[i] != NULL) vpm_option_on_change(s.options[i], handlers[i]);
    }
}

/* Observe the game's Text Language now, as the Lua's observe_language: 1 when the tag changed. */
static int ObserveLanguage(void)
{
    char tag[32];
    (void)vpm_text_refresh();
    snprintf(tag, sizeof tag, "%s", vpm_text_language());
    int changed = strcmp(s.textLanguage, tag) != 0;
    snprintf(s.textLanguage, sizeof s.textLanguage, "%s", tag);
    return changed;
}

/* The offer menu's opening: observe the language once, and rebuild the offer when it changed. */
static void ObserveMenuOpening(void)
{
    if (s.menuSeen) return;
    s.menuSeen = 1;
    if (ObserveLanguage()) s.shown.mode = -1;
}

static double OptionValue(int option)
{
    return s.options[option] != NULL ? vpm_option_value(s.options[option]) : g_options[option].value;
}

static void ApplySettings(void)
{
    for (int i = 0; i < OPTIONS; i++) ApplySetting(i, OptionValue(i));
}

/* ---- the offer ----------------------------------------------------------------------------------------------------- */

static int Hosts(uintptr_t ctx) { return blm_load64(ctx + BLM_HOST) == blm_load64(ctx + BLM_LOCAL); }

/* The open escape screen when an action could be offered, else 0. Alone, that is CANCEL SOS: in a mission, while the
 * menu is open and an SOS is on, and until the button is gone again (the game rebuilds its list when players come and
 * go, not when the SOS stops). */
static uintptr_t OfferScreen(void)
{
    uintptr_t ctx = blm_context(&s.gate);
    if (ctx == 0) return 0;
    if (blm_load32(ctx + BLM_PEER_COUNT) < 2)
    {
        if (!s.sos) return 0;
        uintptr_t state = (uintptr_t)blm_global(BLM_GAME_STATE_PTR);
        if (state == 0 || blm_load32(state + BLM_MODE) != BLM_MODE_MISSION) return 0;
        uintptr_t screen = blm_menu_screen();
        if (screen == 0 || !(s.shown.sosOn || blm_sos_active()) || !Hosts(ctx)) return 0;
        return screen;
    }
    if (!Hosts(ctx)) return 0;
    return blm_menu_screen();
}

static int Changed(const BlmSession* snap, int sosOn, uint32_t privacy)
{
    if (s.shown.mode != (long long)snap->mode || s.shown.count != (int)snap->peer_count || s.shown.hasChosen != s.hasChosen ||
        (s.hasChosen && s.shown.chosen != s.chosen) || s.shown.sosOn != sosOn || (sosOn && s.shown.sosPrivacy != privacy))
        return 1;
    for (uint32_t i = 0; i < snap->peer_count; i++)
        if (s.shown.peers[i] != snap->peers[i].id) return 1;
    return 0;
}

static void OfferSos(uint32_t privacy)
{
    char body[256];
    blm_sos_body(privacy, body, sizeof body);
    s.offer.order[0] = BLM_CANCEL_SOS;
    s.offer.count = 1;
    s.offer.label[BLM_CANCEL_SOS] = blm_intern(blm_tr("button.cancel_sos", "CANCEL SOS"));
    s.offer.title[BLM_CANCEL_SOS] = blm_intern(blm_tr("dialog.cancel_sos.title", "CANCEL SOS"));
    s.offer.body[BLM_CANCEL_SOS] = blm_intern(body);
}

/* DISBAND SQUAD and PROMOTE <NAME> for the successor target. */
static void OfferShip(uint64_t target)
{
    BlmNames names;
    char unknown[64], hex[24], upper[BLM_NAME_SIZE * 2], text[512];
    blm_names(&names);
    const char* name = blm_name_of(&names, target);
    if (name == NULL)
    {
        snprintf(hex, sizeof hex, "%llX", (unsigned long long)target);
        blm_format(unknown, sizeof unknown, blm_tr("player.unknown", "player {id}"), "{id}", hex);
        name = unknown;
    }
    vpm_upper(name, upper, sizeof upper); /* upper case for every script the game's fonts carry */
    s.offer.order[0] = BLM_DISBAND;
    s.offer.order[1] = BLM_PROMOTE;
    s.offer.count = 2;
    s.offer.label[BLM_DISBAND] = blm_intern(blm_tr("button.disband", "DISBAND SQUAD"));
    s.offer.title[BLM_DISBAND] = blm_intern(blm_tr("dialog.disband.title", "DISBAND SQUAD"));
    s.offer.body[BLM_DISBAND] = blm_intern(blm_tr("dialog.disband.body", "Kick every other player. They return to their own ships."));
    blm_format(text, sizeof text, blm_tr("button.promote", "PROMOTE {name}"), "{name}", upper);
    s.offer.label[BLM_PROMOTE] = blm_intern(text);
    blm_format(text, sizeof text, blm_tr("dialog.promote.title", "PROMOTE {name}"), "{name}", upper);
    s.offer.title[BLM_PROMOTE] = blm_intern(text);
    /* Short: the dialog box holds about three lines. Without a pick, the player was chosen for the host. */
    if (s.hasChosen)
        blm_format(text, sizeof text, blm_tr("dialog.promote.body", "{name} hosts from their own ship; you and the squad "
            "follow."), "{name}", name);
    else
        blm_format(text, sizeof text, blm_tr("dialog.promote.body_automatic", "{name} hosts from their own ship; you and "
            "the squad follow. Picked automatically; select a player's card to change."), "{name}", name);
    s.offer.body[BLM_PROMOTE] = blm_intern(text);
}

/* The texts, rebuilt only when the mode, the squad, the chosen successor or the SOS offer changed. */
static void Rebuild(const BlmSession* snap, int sosOn, uint32_t privacy)
{
    s.shown.mode = snap->mode;
    s.shown.count = (int)snap->peer_count;
    s.shown.chosen = s.chosen;
    s.shown.hasChosen = s.hasChosen;
    s.shown.sosOn = sosOn;
    s.shown.sosPrivacy = privacy;
    for (uint32_t i = 0; i < snap->peer_count; i++) s.shown.peers[i] = snap->peers[i].id;
    memset(&s.offer, 0, sizeof s.offer);
    s.shown.hasTarget = 0;
    if (sosOn) { OfferSos(privacy); return; }
    if (snap->mode != BLM_MODE_SHIP) return;
    BlmPeer target;
    int friend, found = 0;
    const char* why = "";
    if (s.hasChosen) found = blm_choose_successor(snap, &s.chosen, &target, &friend, &why);
    if (s.hasChosen && !found) s.hasChosen = s.shown.hasChosen = 0;
    if (!found) found = blm_choose_successor(snap, NULL, &target, &friend, &why);
    if (!found) return;
    s.shown.target = target.id;
    s.shown.hasTarget = 1;
    OfferShip(target.id);
}

static void RunAction(int action)
{
    const char* why = "";
    uint64_t target = s.shown.target;
    if (action == BLM_DISBAND) (void)blm_lobby_disband(s.clock, &why);
    else if (action == BLM_PROMOTE) (void)blm_lobby_promote(s.shown.hasTarget ? &target : NULL, s.clock, &why);
    else if (action == BLM_CANCEL_SOS) (void)blm_sos_cancel(s.clock, &why);
}

/* The escape menu while an action could be offered: the offer, then the menu's frame. */
static void MenuFrame(void)
{
    BlmSession snap;
    uint32_t privacy = 0;
    uint64_t selected = 0;
    uintptr_t screen = OfferScreen();
    if (screen == 0) { s.menuSeen = 0; return; }
    ObserveMenuOpening();
    if (blm_lobby_snapshot(&snap))
    {
        int sosOn = s.sos && blm_sos_offer(&snap, &privacy);
        if (Changed(&snap, sosOn, privacy)) Rebuild(&snap, sosOn, privacy);
        int action = blm_menu_step(screen, snap.local, &s.offer, &selected);
        if (selected != 0 && (!s.hasChosen || s.chosen != selected))
        {
            s.chosen = selected;
            s.hasChosen = 1;
        }
        if (action != 0) RunAction(action);
    }
    if (vpm_detailed()) blm_menu_trace(screen); /* the Lua's diagnostic builds: the dialog and focus state on change */
}

/* ---- the frame ----------------------------------------------------------------------------------------------------- */

/* The scanner's own check (two plain loads while nothing changed), and a log line when its state moved. */
static void ScannerCheck(void)
{
    if (!s.scanner) return;
    (void)blm_scanner_check();
    if (s.hasScanned && blm_scanner_revision() == s.scanned) return;
    char text[256];
    s.scanned = blm_scanner_revision();
    s.hasScanned = 1;
    blm_scanner_summary(text, sizeof text);
    vpm_log(blm_component, "%s", text);
}

static int NothingPending(void)
{
    if ((s.sos && blm_sos_cancelled()) || blm_lobby_arrival_pending()) return 0;
    return !blm_lobby_busy() && !blm_lobby_ui_pending();
}

/* A full frame. The first applies the settings, as the Lua's first update registered the options. */
static void Run(float dt)
{
    if (s.settingsPending)
    {
        s.settingsPending = 0;
        ApplySettings();
    }
    s.clock += dt;
    ScannerCheck();
    if (s.sos && blm_sos_cancelled()) blm_sos_keep(s.clock); /* a cancelled SOS stays off: the game lists it again when a player leaves */
    if (blm_lobby_arrival_pending()) blm_lobby_check_arrival(s.clock);
    if (blm_lobby_busy()) (void)blm_lobby_step(s.clock);
    else if (s.menu) MenuFrame();
    if (blm_lobby_ui_pending()) blm_lobby_ui_step(s.clock);
    if (s.region) blm_region_step();
    s.quiet = NothingPending();
}

/* An idle frame: what Run does while nothing is pending and the escape screen is closed, without the session reads. */
static void Idle(float dt)
{
    s.clock += dt;
    ScannerCheck();
    if (s.region) blm_region_step();
}

static void RecheckParts(VpmComponent* self, float dt);

/* lint: per-frame. The idle gate first: while quiet, a closed escape screen (two plain loads) ends the frame idle. (A
 * part left out at the start is looked at again first, for at most PARTS_WAIT_SECONDS.) */
static void Tick(VpmComponent* self, float dt)
{
    if (s.partsPending) RecheckParts(self, dt);
    if (s.quiet && (!s.menu || blm_menu_closed())) { Idle(dt); return; }
    Run(dt);
}

/* ---- start-up ------------------------------------------------------------------------------------------------------ */

static void Keep(char* out, const char* why) { snprintf(out, WHY_SIZE, "%s", why); }

/* Every part not verified yet checked (again), in the Lua's order; 1 when all are. */
static int VerifyParts(void)
{
    const char* why = "";
    if (!s.region && !(s.region = blm_region_verify(&why))) Keep(s.regionWhy, why);
    if (!s.scanner && !(s.scanner = blm_scanner_verify(&why))) Keep(s.scannerWhy, why);
    if (!s.menu && !(s.menu = blm_menu_verify(&why))) Keep(s.menuWhy, why);
    if (!s.sos && !(s.sos = blm_sos_verify(&why))) Keep(s.sosWhy, why);
    if (!s.chat && !(s.chat = blm_chat_verify(&why))) Keep(s.chatWhy, why);
    return s.region && s.scanner && s.menu && s.sos && s.chat;
}

/* The parts that joined late: their settings applied (after the first frame's), and a log line each. */
static void PartsJoined(VpmComponent* self, int region, int scanner, int menu, int sos, int chat)
{
    static const char* const names[5] = {"Lobby Region", "scanner", "menu", "CANCEL SOS", "squad messages"};
    const int joined[5] = {!region && s.region, !scanner && s.scanner, !menu && s.menu, !sos && s.sos, !chat && s.chat};
    for (int i = 0; i < 5; i++)
        if (joined[i])
            vpm_log(self, "%s ready after %.1f s: its game code was decoded after the others", names[i], s.partsWaited);
    if (s.settingsPending) return; /* the first frame applies them all */
    if (joined[0]) ApplySetting(OPTION_REGION, OptionValue(OPTION_REGION));
    if (joined[1]) ApplySetting(OPTION_SCANNER, OptionValue(OPTION_SCANNER));
    if (joined[2] || joined[4]) ApplySetting(OPTION_MESSAGES, OptionValue(OPTION_MESSAGES)); /* the lobby's both flags */
}

/* lint: per-frame. A part's code that did not read as shipped at the start (game.dll is decoded in parts): its checks
 * again on every 30th frame, for PARTS_WAIT_SECONDS; then it stays out for the session, as a part whose code differs. */
static void RecheckParts(VpmComponent* self, float dt)
{
    s.partsWaited += dt;
    if (s.partsWaited >= PARTS_WAIT_SECONDS) { s.partsPending = 0; return; }
    if (++s.partsFrames % PARTS_FRAMES != 0) return;
    int region = s.region, scanner = s.scanner, menu = s.menu, sos = s.sos, chat = s.chat;
    s.partsPending = !VerifyParts();
    PartsJoined(self, region, scanner, menu, sos, chat);
}

static const char* PartText(int ok, const char* prefix, const char* why, char* out, size_t size)
{
    if (ok) return "ready";
    snprintf(out, size, "%s: %s", prefix, why);
    return out;
}

static void LogReady(VpmComponent* self)
{
    char menu[128], region[128] = "", chat[128], scanner[128], sos[128];
    if (!s.region) snprintf(region, sizeof region, "; Lobby Region disabled: %s", s.regionWhy);
    vpm_log(self, "Better Lobby Management " VERSION " ready: game code and natives verified; menu %s%s; squad messages %s; "
        "scanner %s; CANCEL SOS %s", PartText(s.menu, "disabled", s.menuWhy, menu, sizeof menu), region,
        PartText(s.chat, "unavailable", s.chatWhy, chat, sizeof chat), PartText(s.scanner, "disabled", s.scannerWhy, scanner,
        sizeof scanner), PartText(s.sos, "unavailable", s.sosWhy, sos, sizeof sos));
}

/* The engine slots' functions read as shipped: they are bound, then every part's own checks, the settings and the
 * frame. */
static void SlotsReady(VpmComponent* self, HfEvent event)
{
    blm_engine_bind();
    (void)ObserveLanguage();
    RegisterOptions(self);
    s.partsPending = !VerifyParts();
    blm_lobby_use(s.chat, s.menu);
    LogReady(self);
    s.ready = 1;
    s.settingsPending = 1;
    if (!vpm_tick_start(self, Tick)) { vpm_fail(self, "the game thread could not be reached"); return; }
    vpm_set_status(self, "ready");
}

/* The engine's lobby and package slots resolved; their functions handed to the core's wait (SlotsReady at once when they
 * read as shipped). */
static void Begin(VpmComponent* self)
{
    const VpmCodePin* pins = NULL;
    int count = 0;
    const char* why = blm_engine_resolve(&pins, &count);
    if (why != NULL) { vpm_fail(self, "%s", why); return; }
    vpm_tick_stop(self); /* the engine wait's tick, if it ran: SlotsReady starts the frame */
    if (count == 0) { SlotsReady(self, HF_EVENT_GAME_LOADED); return; }
    if (!vpm_when_code_ready(self, pins, count, SlotsReady)) vpm_fail(self, "the engine slots' code checks refused");
}

/* lint: per-frame. The engine API tables do not exist yet: one plain load per frame, for at most WAIT_SECONDS. */
static void WaitEngine(VpmComponent* self, float dt)
{
    if (!blm_engine_ready())
    {
        s.waited += dt;
        if (s.waited >= WAIT_SECONDS) vpm_fail(self, "gave up after %.0f s: engine API unavailable", WAIT_SECONDS);
        return;
    }
    vpm_log(self, "the engine API is available after %.1f s of waiting", s.waited);
    Begin(self);
}

/* The network code, the PlayFab layout and the natives read as shipped (the core's wait, from HF_EVENT_GAME_LOADED). */
static void Loaded(VpmComponent* self, HfEvent event)
{
    if (s.verified) return;
    s.verified = 1;
    if (blm_engine_ready()) { Begin(self); return; }
    vpm_log(self, "Waiting for the game: the engine API is not available yet.");
    vpm_set_status(self, "waiting: the engine API is not available yet");
    if (!vpm_tick_start(self, WaitEngine)) vpm_fail(self, "the game thread could not be reached");
}

/* ---- diagnostics ---------------------------------------------------------------------------------------------------- */

/* Detailed mode: the counters the Lua's shutdown line gave, at each mission's end (the core has no shutdown event). */
static void MissionEnded(VpmComponent* self, const HfEventInfo* event)
{
    if (!s.ready || !vpm_detailed()) return;
    char scanner[256] = "scanner off";
    int cancels = 0, rearms = 0, leaks = 0;
    if (s.scanner) blm_scanner_summary(scanner, sizeof scanner);
    blm_sos_counts(&cancels, &rearms, &leaks);
    vpm_log_detail(self, "at the mission's end: %d actions; page checks %d; %s; SOS cancels %d, re-arms caught %d (%d "
        "already posted); nearby lobbies %s", blm_lobby_actions(), blm_page_checks(), scanner, cancels, rearms, leaks,
        s.region ? blm_region_status() : "unavailable");
}

/* The tester's mark: where start-up got to, the parts, the action and the counters. */
static void Describe(VpmComponent* self, char* out, size_t size)
{
    int cancels = 0, rearms = 0, leaks = 0;
    blm_sos_counts(&cancels, &rearms, &leaks);
    const char* phase = s.ready ? "ready" : s.verified ? "waiting for the engine API" : "waiting for game code";
    snprintf(out, size, "%s; menu %s, SOS %s, messages %s, region %s, scanner %s; action: %s; %d actions; SOS cancels %d, "
        "re-arms %d", phase, s.menu ? "on" : "off", s.sos ? "on" : "off", s.chat ? "on" : "off",
        s.region ? blm_region_status() : "off", s.scanner ? blm_scanner_state() : "off", blm_lobby_status(),
        blm_lobby_actions(), cancels, rearms);
}

/* What it changed in the game goes back: the running action is cancelled, the region flags and the scanner's field are
 * restored. A kept SOS cancel ends (the next player leaving lists the SOS again). Switched off with the escape menu
 * open, the buttons it added stay until the menu closes (the game rebuilds the list then) and do nothing; a KICK the
 * game already holds still happens. */
static void Stop(VpmComponent* self)
{
    if (!s.ready) return;
    s.ready = 0;
    (void)blm_lobby_reset("error");
    (void)blm_region_restore();
    if (s.scanner) (void)blm_scanner_stop("stopped_after_error");
    if (s.sos && blm_sos_cancelled()) vpm_log(self, "CANCEL SOS: no longer kept off; a player leaving lists the SOS again");
    vpm_log(self, "Better Lobby Management stopped; region flags restored");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.shown.mode = -1;
    s.shown.count = -1;
    blm_component = self;
    vpm_text_table(self, &vpm_texts_better_lobby_management);
    blm_game_reset();
    /* No blm_text_reset: the game's widgets may still point at texts an earlier start showed (a live switch-off with the
     * escape menu open); interning finds them again, so the pool only grows by texts it never had. */
    blm_chat_reset();
    blm_menu_reset();
    blm_lobby_reset_state();
    blm_sos_reset();
    blm_region_reset();
    blm_scanner_reset();
    (void)vpm_listen(self, HF_ON_MISSION_END, MissionEnded, 0); /* Detailed lines only; the core logs a refusal */
    const VpmCodePin* pins = NULL;
    int count = blm_game_pins(&pins);
    return vpm_when_code_ready(self, pins, count, Loaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_better_lobby_management = {"better_lobby_management", "Better Lobby Management", "1.2.1", 0, Start, Stop,
    Describe};
