/* Better Lobby Management: the escape menu (menu.lua). The actions as native buttons on the escape menu's GAME tab (the
 * squad view), each confirmed with the game's own confirm dialog.
 *
 * The tab keeps a list of up to five native buttons and one type byte per button; the game uses types 0-4, and a host
 * uses two slots on the ship and two (alone) or three in a mission. The buttons here take types 5+ in the free slots.
 * The game's select handler and its dialog result act only on types 0-4, but the select handler still shows the shared
 * confirm dialog for any type, so that dialog is filled while it is hidden, as soon as the focus lands on one of these
 * buttons, and the action runs when the dialog comes back confirmed. The escape screen, and with it every button, is
 * freed when the menu closes; the buttons are added again whenever they are missing.
 *
 * The player menu's own KICK (game_kick): the tab takes input only while the dialog is idle and the squad panel is in
 * state 2; then it runs the focused card's popup, whose KICK fires inside the game's own update once its hold timer
 * passes 3 s. Closing the menu as Esc does: the Main presenter's pending-close byte. */
#include <math.h>
#include <stdio.h>
#include "blm.h"

#define MENU_SYSTEM_PTR 0x347CE38u
#define SCREEN 200u                /* menu system -> escape screen (0 while the menu is closed) */
#define CONFIRM_RETRY 60           /* idle gate: calls between tries to confirm a new menu system */
#define SHOWN 8u                   /* screen: shown content (0 GAME, 1 SOCIAL, 2 OPTIONS) */
#define CONTENT 281480u            /* screen -> GAME content */
#define CARDS 1371024u
#define CARD_SIZE 85552u
#define CARD_PEER 85504u
#define CARD_STATE 85512u
#define POPUP_OPEN 2u
#define BUTTONS 1714544u
#define BUTTON_SIZE 14920u
#define BUTTON_TEXT 1928u
#define BUTTON_LIST 1714272u       /* the container the game attaches the buttons to */
#define COUNT 1789912u
#define TYPES 1789913u
#define MAX_BUTTONS 5u
#define FOCUS 1970000u             /* 0-3 cards, 4 + i button i, 255 none */
#define DIALOG 1970288u
#define DIALOG_INACTIVE 1989648u
#define DIALOG_OPENING 1989649u
#define DIALOG_ANSWERED 1989650u
#define DIALOG_CONFIRMED 1989651u
#define HIDDEN 1989808u            /* content hidden (another tab) */
#define DIALOG_FADE 1989812u
#define PANEL_STATE 1832636u
#define DIALOG_TITLE 1496u         /* the confirm dialog's text widgets and state (0 while hidden) */
#define DIALOG_BODY 2192u
#define DIALOG_STATE 19372u
#define LABEL 272u                 /* text widgets: label id at +272, arguments from +280 */
#define KIND_WRAPPED 8u            /* widget flags bits 18-21 */
#define WIDGET_X 4u
#define WIDGET_WIDTH 12u
#define TEXT_LIMIT 388.0f          /* a 420-wide button less the text inset on both sides (used if unreadable) */
#define TEXT_TEMPLATE 0xC67C7FAFu  /* '#COUNT' is a pure tag template, so a string COUNT argument shows any text */
#define TEXT_KEY 0xAB2A7B35u
#define CONFIRM_LABEL 0xD94B7608u
#define CANCEL_LABEL 0x8A36D40Au
#define FIRST_TYPE 5u
#define CARD_POPUP 7144u           /* the popup runs only while this is set */
#define CARD_KICK_HOLD 85520u      /* float seconds KICK has been held */
#define KICK_HOLD 100.0f           /* past the 3 s, whatever the frame time */
#define PRESENTERS_PTR 0x347CE28u
#define MAIN_PRESENTER 0x4388u
#define PENDING_CLOSE 16u

typedef struct MenuNatives
{
    void (*add_child)(uint64_t parent, uint64_t child);
    void (*set_label)(uint64_t widget, uint32_t label);
    void (*set_label_wrapped)(uint64_t widget, uint32_t label);
    void (*set_string_arg)(uint64_t widget, uint32_t key, uint64_t text);
    uint8_t (*clear_args)(uint64_t label);
    void (*measure_text)(uint64_t widget);
    void (*set_enabled)(uint64_t widget, uint8_t enabled);
    uint8_t (*dialog_setup)(uint64_t dialog, uint32_t title, uint32_t text, uint32_t confirm, uint32_t cancel, uint8_t hold, uint8_t flag);
    void (*rebuild)(uint64_t content, uint64_t unused);
    void (*set_marquee)(uint64_t text, float width);
    void (*focus)(uint64_t content, uint8_t index);
    void (*card_state)(uint64_t card, int32_t state);
} MenuNatives;

#define TRACE_FIELDS 13
#define NO_TYPE 0xFFFFFFFFu        /* the trace's type of a focus that is not on a button */

typedef struct Prepared { int action; const char* title; const char* body; int full; } Prepared;

static MenuNatives n;
static struct
{
    uintptr_t menuCache, screenCache;
    Prepared prepared;            /* the action whose texts the hidden dialog holds (0: none) */
    int pending;                  /* the action whose dialog is open */
    int release;                  /* our text is on the dialog: clear it once hidden */
    uint8_t lastAnswered;
    int refused;                  /* a write was refused: no retry until the menu opens again */
    const char* labels[MAX_BUTTONS]; /* what our button at each index shows */
    int confirmWait;
    int traced;                   /* Detailed mode: the dialog and focus state last logged (blm_menu_trace) */
    uint32_t trace[TRACE_FIELDS];
} s;

static const char* const kActionNames[BLM_ACTIONS + 1] = {"", "disband", "promote", "cancel_sos"};

void blm_menu_reset(void)
{
    memset(&s, 0, sizeof s);
    memset(&n, 0, sizeof n);
}

static uintptr_t Native(const char* name) { return blm_code_address(blm_menu_natives, blm_menu_natives_count, name); }

static void Bind(void)
{
    n.add_child = (void (*)(uint64_t, uint64_t))Native("add_child");
    n.set_label = (void (*)(uint64_t, uint32_t))Native("set_label");
    n.set_label_wrapped = (void (*)(uint64_t, uint32_t))Native("set_label_wrapped");
    n.set_string_arg = (void (*)(uint64_t, uint32_t, uint64_t))Native("set_string_arg");
    n.clear_args = (uint8_t (*)(uint64_t))Native("clear_args");
    n.measure_text = (void (*)(uint64_t))Native("measure_text");
    n.set_enabled = (void (*)(uint64_t, uint8_t))Native("set_enabled");
    n.dialog_setup = (uint8_t (*)(uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint8_t, uint8_t))Native("dialog_setup");
    n.rebuild = (void (*)(uint64_t, uint64_t))Native("rebuild");
    n.set_marquee = (void (*)(uint64_t, float))Native("set_marquee");
    n.focus = (void (*)(uint64_t, uint8_t))Native("focus");
    n.card_state = (void (*)(uint64_t, int32_t))Native("card_state");
}

/* Once per session: the natives (the start of each) and the code the layout depends on. */
int blm_menu_verify(const char** why)
{
    if (!blm_game_code_ok(blm_menu_natives, blm_menu_natives_count, why)) return 0;
    if (!blm_game_code_ok(blm_menu_code, blm_menu_code_count, why)) return 0;
    Bind();
    return 1;
}

/* ---- the escape screen ----------------------------------------------------------------------------------------- */

/* The escape screen is closed: what it held is forgotten (the screen, a refused write, the dialog prepared, open or
 * holding our text). The one close path, for the screen and the idle gate alike. */
static void ForgetScreen(void)
{
    s.screenCache = 0;
    s.refused = 0;
    s.prepared.action = 0;
    s.pending = 0;
    s.release = 0;
}

/* The menu system, or 0 (not there, or a new one not readable yet). */
static uintptr_t MenuSystem(void)
{
    uintptr_t menu = (uintptr_t)blm_global(MENU_SYSTEM_PTR);
    uint64_t screen;
    if (menu == 0 || menu % 8 != 0) return 0;
    if (menu != s.menuCache)
    {
        if (!vpm_read_u64(menu + SCREEN, &screen)) return 0;
        s.menuCache = menu;
    }
    return menu;
}

/* The open escape screen, or 0. The menu system and a new screen are each confirmed once with a guarded read. */
static uintptr_t OpenScreen(void)
{
    uintptr_t menu = MenuSystem();
    if (menu == 0) return 0;
    uintptr_t screen = (uintptr_t)blm_load64(menu + SCREEN);
    if (screen == 0 || screen % 8 != 0) { ForgetScreen(); return 0; }
    if (screen != s.screenCache)
    {
        uint32_t value;
        if (!vpm_read_u32(screen + SHOWN, &value) || !vpm_read_u32(screen + CONTENT + COUNT, &value)) return 0;
        s.screenCache = screen;
        s.prepared.action = 0;
        s.pending = 0;
        s.release = 0;
        memset(s.labels, 0, sizeof s.labels);
        s.lastAnswered = 0;
        s.refused = 0;
    }
    return screen;
}

uintptr_t blm_menu_screen(void)
{
    uintptr_t screen = OpenScreen();
    if (screen == 0)
    {
        s.prepared.action = 0;
        s.pending = 0;
        s.release = 0;
    }
    return screen;
}

/* lint: per-frame. The idle gate: 1 while the escape screen is closed (two direct loads, no Windows call). An open
 * screen, or a menu system that is not there or not confirmed readable, is left to the full frame; a confirm that failed
 * is tried again on every CONFIRM_RETRY-th call. */
int blm_menu_closed(void)
{
    uintptr_t menu = (uintptr_t)blm_global(MENU_SYSTEM_PTR);
    if (menu == 0 || menu % 8 != 0) return 0;
    if (menu != s.menuCache)
    {
        if (s.confirmWait > 0) { s.confirmWait--; return 0; }
        if (MenuSystem() == 0) { s.confirmWait = CONFIRM_RETRY - 1; return 0; }
    }
    uintptr_t screen = (uintptr_t)blm_load64(menu + SCREEN);
    if (screen != 0 && screen % 8 == 0) return 0;
    if (s.screenCache != 0) ForgetScreen(); /* only a screen seen open holds state */
    return 1;
}

/* ---- texts and buttons --------------------------------------------------------------------------------------------- */

static void ShowText(uintptr_t widget, const char* text)
{
    if (((blm_load32(widget) >> 18) & 15u) == KIND_WRAPPED) n.set_label_wrapped(widget, TEXT_TEMPLATE);
    else n.set_label(widget, TEXT_TEMPLATE);
    n.set_string_arg(widget, TEXT_KEY, (uint64_t)(uintptr_t)text);
}

/* The width a button's text may use: the button's width less the text's inset on both sides. */
static float TextLimit(uintptr_t button)
{
    float width = blm_loadf(button + WIDGET_WIDTH) - 2.0f * blm_loadf(button + BUTTON_TEXT + WIDGET_X);
    if (isnan(width) || width < 64.0f || width > 4096.0f) return TEXT_LIMIT;
    return width;
}

static int OurAction(uint8_t type)
{
    return type >= FIRST_TYPE && type < FIRST_TYPE + BLM_ACTIONS ? type - FIRST_TYPE + 1 : 0;
}

static uintptr_t Button(uintptr_t content, uint32_t index) { return content + BUTTONS + index * BUTTON_SIZE; }

/* Our buttons present: present[action] their index or -1. 0, or 1 after the game rebuilt the list because one of ours
 * is no longer offered. */
static int Present(uintptr_t content, uint32_t count, const BlmOffer* offer, int* present)
{
    for (int a = 0; a <= BLM_ACTIONS; a++) present[a] = -1;
    for (uint32_t i = 0; i < count; i++)
    {
        int action = OurAction(blm_load8(content + TYPES + i));
        if (action == 0) continue;
        if (offer->label[action] == NULL)
        {
            n.rebuild(content, 0);
            memset(s.labels, 0, sizeof s.labels);
            vpm_log(blm_component, "menu: buttons rebuilt (%s no longer offered)", kActionNames[action]);
            return 1;
        }
        present[action] = (int)i;
    }
    return 0;
}

/* Adds the offered actions that are missing with one checked write: 1, or 0 when the write was refused. */
static int Add(uintptr_t content, uint32_t count, const BlmOffer* offer, int* present)
{
    uint8_t types[MAX_BUTTONS];
    uint32_t added[MAX_BUTTONS], first = count, total = count;
    int changes = 0;
    for (int k = 0; k < offer->count; k++)
    {
        int action = offer->order[k];
        if (offer->label[action] == NULL || present[action] >= 0 || total >= MAX_BUTTONS) continue;
        types[changes] = (uint8_t)(FIRST_TYPE + (uint32_t)action - 1);
        added[changes++] = total;
        present[action] = (int)total++;
    }
    if (changes == 0) return 1;
    if (s.refused) return 0;
    if (!blm_writable(content + COUNT, 1 + MAX_BUTTONS))
    {
        s.refused = 1;
        vpm_log(blm_component, "menu: button write refused; retried when the menu opens again");
        return 0;
    }
    const uint8_t newCount = (uint8_t)total;
    memcpy((void*)(content + TYPES + first), types, (size_t)changes);
    memcpy((void*)(content + COUNT), &newCount, 1);
    for (int i = 0; i < changes; i++)
    {
        uintptr_t button = Button(content, added[i]);
        n.add_child(content + BUTTON_LIST, button);
        s.labels[added[i]] = NULL;
        n.set_enabled(button, 1);
    }
    return 1;
}

/* Adds what is missing, relabels ours when their text changed, and has the game rebuild the list when one of ours is no
 * longer offered. 0 when the write was refused. */
static int SyncButtons(uintptr_t content, const BlmOffer* offer)
{
    uint32_t count = blm_load8(content + COUNT);
    int present[BLM_ACTIONS + 1];
    if (count > MAX_BUTTONS) return 1;
    if (Present(content, count, offer, present)) return 1;
    if (!Add(content, count, offer, present)) return 0;
    for (int action = 1; action <= BLM_ACTIONS; action++)
    {
        if (present[action] < 0) continue;
        uint32_t index = (uint32_t)present[action];
        const char* text = offer->label[action];
        if (s.labels[index] == text) continue;
        uintptr_t button = Button(content, index);
        ShowText(button + BUTTON_TEXT, text);
        n.set_marquee(button + BUTTON_TEXT, TextLimit(button));
        s.labels[index] = text;
    }
    return 1;
}

/* ---- the dialog ---------------------------------------------------------------------------------------------------- */

/* Puts an action's title and body on the dialog (a label change, allowed at any time). */
static void Retext(uintptr_t content, int action, const BlmOffer* offer, int full)
{
    uintptr_t dialog = content + DIALOG;
    ShowText(dialog + DIALOG_TITLE, offer->title[action]);
    ShowText(dialog + DIALOG_BODY, offer->body[action]);
    n.measure_text(dialog + DIALOG_TITLE);
    n.measure_text(dialog + DIALOG_BODY);
    s.release = 1;
    s.prepared = (Prepared){action, offer->title[action], offer->body[action], full};
}

/* Sets the hidden dialog up as the game does before its own (the confirm and cancel labels and the hold to confirm are
 * the game's), with the action's texts. Only while the dialog is idle: the setup queues otherwise. */
static void Prepare(uintptr_t content, int action, const BlmOffer* offer)
{
    (void)n.dialog_setup(content + DIALOG, TEXT_TEMPLATE, TEXT_TEMPLATE, CONFIRM_LABEL, CANCEL_LABEL, 1, 0);
    Retext(content, action, offer, 1);
}

/* Takes our text off the hidden dialog, so no COUNT argument of ours stays on a native dialog. */
static void ReleaseDialog(uintptr_t content)
{
    uintptr_t dialog = content + DIALOG;
    (void)n.clear_args(dialog + DIALOG_TITLE + LABEL);
    (void)n.clear_args(dialog + DIALOG_BODY + LABEL);
    s.release = 0;
    s.prepared.action = 0;
}

/* The answer first: the game hides the dialog in the very frame it is answered, so it is inactive by now. The action
 * confirmed, or 0. */
static int Answer(uintptr_t content, int inactive)
{
    if (!s.pending) return 0;
    uint8_t answered = blm_load8(content + DIALOG_ANSWERED);
    if (answered != 0 && s.lastAnswered == 0)
    {
        int confirmed = blm_load8(content + DIALOG_CONFIRMED) != 0, done = s.pending;
        s.pending = 0;
        vpm_log(blm_component, "menu: %s %s", kActionNames[done], confirmed ? "confirmed" : "cancelled");
        return confirmed ? done : 0;
    }
    if (inactive) s.pending = 0; /* closed without an answer */
    else s.lastAnswered = answered;
    return 0;
}

/* The dialog is hidden. Our button has the focus: set the dialog up for it. While it still fades out the setup would
 * queue, so only the text changes then; the full setup follows once it is idle. Else our text leaves it. */
static void Hidden(uintptr_t content, int action, int has, int same, const BlmOffer* offer)
{
    if (!has)
    {
        if (s.release) ReleaseDialog(content);
        return;
    }
    if (blm_load32(content + DIALOG + DIALOG_STATE) == 0)
    {
        if (!(same && s.prepared.full)) Prepare(content, action, offer);
    }
    else if (!same) Retext(content, action, offer, 0);
}

static void Dialog(uintptr_t content, int action, int inactive, const BlmOffer* offer)
{
    int has = action != 0 && offer->title[action] != NULL;
    int same = has && s.prepared.action == action && s.prepared.title == offer->title[action] && s.prepared.body == offer->body[action];
    if (inactive) { Hidden(content, action, has, same, offer); return; }
    if (s.pending || !has) return;
    /* The game opened the dialog from our button: it shows this button's texts, whatever was prepared before. */
    if (!same) Retext(content, action, offer, 0);
    s.pending = action;
    s.lastAnswered = blm_load8(content + DIALOG_ANSWERED);
}

/* The squad member whose player menu is open (not the host), or 0. */
static uint64_t Selected(uintptr_t content, uint64_t local)
{
    uint64_t selected = 0;
    for (uint32_t i = 0; i < 4; i++)
    {
        uintptr_t card = content + CARDS + i * CARD_SIZE;
        if (blm_load32(card + CARD_STATE) != POPUP_OPEN) continue;
        uint64_t peer = blm_load64(card + CARD_PEER);
        if (peer != 0 && peer != local) selected = peer;
    }
    return selected;
}

/* lint: per-frame (while the escape screen is open and an action could be offered). */
int blm_menu_step(uintptr_t screen, uint64_t local, const BlmOffer* offer, uint64_t* selected)
{
    uintptr_t content = screen + CONTENT;
    *selected = Selected(content, local);
    if (blm_load32(screen + SHOWN) != 0 || blm_load8(content + HIDDEN) != 0) return 0;
    if (!SyncButtons(content, offer)) return 0;
    uint32_t count = blm_load8(content + COUNT), focus = blm_load8(content + FOCUS);
    int action = focus >= 4 && focus - 4 < count ? OurAction(blm_load8(content + TYPES + focus - 4)) : 0;
    int inactive = blm_load8(content + DIALOG_INACTIVE) != 0;
    int confirmed = Answer(content, inactive);
    Dialog(content, action, inactive, offer);
    return confirmed;
}

/* lint: per-frame (an open escape menu, in Detailed mode only). The dialog and focus state, logged when it changes
 * (menu.lua trace, the Lua's diagnostic builds: to explain a confirm the component did not see). Plain loads. */
void blm_menu_trace(uintptr_t screen)
{
    uintptr_t content = screen + CONTENT;
    uint32_t focus = blm_load8(content + FOCUS), count = blm_load8(content + COUNT);
    const uint32_t now[TRACE_FIELDS] = {blm_load32(screen + SHOWN), blm_load8(content + HIDDEN), focus,
        focus >= 4 && focus - 4 < count ? blm_load8(content + TYPES + focus - 4) : NO_TYPE,
        blm_load8(content + DIALOG_INACTIVE), blm_load8(content + DIALOG_OPENING), blm_load8(content + DIALOG_ANSWERED),
        blm_load8(content + DIALOG_CONFIRMED), blm_load32(content + DIALOG + DIALOG_STATE),
        blm_loadf(content + DIALOG_FADE) != 0.0f, blm_load32(content + PANEL_STATE), (uint32_t)s.pending,
        (uint32_t)s.prepared.action};
    if (s.traced && memcmp(now, s.trace, sizeof now) == 0) return;
    s.traced = 1;
    memcpy(s.trace, now, sizeof now);
    char type[12] = "-";
    if (now[3] != NO_TYPE) snprintf(type, sizeof type, "%u", now[3]);
    vpm_log_detail(blm_component, "menu trace: tab %u hidden %u focus %u type %s dialog inactive %u opening %u answered %u "
        "confirmed %u state %u fading %u panel %u pending %s prepared %s", now[0], now[1], now[2], type, now[4], now[5],
        now[6], now[7], now[8], now[9], now[10], s.pending ? kActionNames[s.pending] : "-",
        s.prepared.action ? kActionNames[s.prepared.action] : "-");
}

/* ---- the player menu's KICK and the menu's close --------------------------------------------------------------- */

/* The tab takes input: the dialog idle, not opening, not fading, and the squad panel in state 2. */
static int TakesInput(uintptr_t content)
{
    return blm_load8(content + DIALOG_INACTIVE) != 0 && blm_load8(content + DIALOG_OPENING) == 0 &&
        blm_loadf(content + DIALOG_FADE) == 0.0f && blm_load32(content + PANEL_STATE) == 2;
}

/* The player menu's own KICK for peer, as a click on their card and a completed hold would do: the game kicks in its
 * next update of the tab. "started" (*card the card), or why not now. */
const char* blm_menu_game_kick(uintptr_t screen, uint64_t peer, int* card)
{
    if (screen == 0) return "menu closed";
    uintptr_t content = screen + CONTENT;
    if (blm_load32(screen + SHOWN) != 0 || blm_load8(content + HIDDEN) != 0) return "other tab";
    if (!TakesInput(content)) return "busy";
    for (uint32_t i = 0; i < 4; i++)
    {
        uintptr_t at = content + CARDS + i * CARD_SIZE;
        if (blm_load64(at + CARD_PEER) != peer) continue;
        if (blm_load64(at + CARD_POPUP) == 0) return "no player menu";
        n.focus(content, (uint8_t)i);
        n.card_state(at, (int32_t)POPUP_OPEN);
        /* After opening: hiding a popup is what clears the timers. */
        if (!blm_writable(at + CARD_KICK_HOLD, 4)) return "refused";
        const float hold = KICK_HOLD;
        memcpy((void*)(at + CARD_KICK_HOLD), &hold, 4);
        *card = (int)i;
        return "started";
    }
    return "no card";
}

/* Closes the escape menu as Esc does (the squad moving to another ship while the menu was open left the old host's
 * Helldiver in the menu pose). 1, or 0 with *why: "closed", "unreadable", "refused". */
int blm_menu_close(const char** why)
{
    uintptr_t manager = (uintptr_t)blm_global(PRESENTERS_PTR);
    uint64_t main;
    uint32_t pending;
    if (manager == 0) { *why = "closed"; return 0; }
    if (!vpm_read_u64(manager + MAIN_PRESENTER, &main)) { *why = "unreadable"; return 0; }
    if (main == 0) { *why = "closed"; return 0; }
    if (!vpm_read_u32((uintptr_t)main + PENDING_CLOSE, &pending)) { *why = "unreadable"; return 0; }
    if (!blm_writable((uintptr_t)main + PENDING_CLOSE, 4)) { *why = "refused"; return 0; }
    const uint8_t close = 1;
    memcpy((void*)((uintptr_t)main + PENDING_CLOSE), &close, 1);
    return 1;
}
