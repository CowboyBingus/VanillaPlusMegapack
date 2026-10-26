/* Clickable Scrollbars v2.15.1 (Lua: components/ClickableScrollbars/src: install.lua, platform.lua, native.lua,
 * locate.lua, model.lua, memory.lua), build 25480438.
 *
 * Drag the scrollbars of the equipment lists (the Armory and the mission loadout picker), the Armory's Career panel,
 * the Controls page and the Settings page with the mouse, and click their tracks to page. The game draws these bars
 * natively and does not answer clicks on them. While the left button is held after a press on a bar, the list's own
 * scroll model follows the pointer: the thumb moves by the distance the pointer moved (a track press first puts the
 * thumb's centre under the pointer), through the game's own setters (native.c). Nothing is injected anywhere. A press
 * anywhere else, or on a menu this does not know, does nothing.
 *
 * Each press resolves the visible bar's owner afresh (locate.c): screens rebuild their controllers when entered, and a
 * remembered pointer reads plausibly long after its screen is gone. A held frame re-validates before it writes: it
 * repeats the reads that resolved the owner (resolving again only when one returns other bytes) and re-reads the model,
 * which must still be the grabbed list's (same owner, items, layout kind, content and span); anything else cancels the
 * drag. The first write of a gesture is checked against what the game derives from it (the visible range, the solver's
 * anchor, the rendered thumb, an options list's content offset) once 200 ms have passed; a list that did not answer
 * retires that owner until a press resolves a different one. Focus loss ends a drag; a Settings drag consumes the UI
 * select action every frame until the button is released, also after the drag ended (native.c).
 *
 * On HellForge: the tick is the core's game-thread tick (the Lua's guarded update step); the five game routines
 * are checked with code_matches from HF_EVENT_GAME_LOADED (the core checks the build) through vpm_when_code_ready:
 * game.dll's code is decoded in parts after that event, so they are checked again every 30 frames until they read as
 * shipped, and the component starts then (it is stopped, naming the routine, if they do not within 60 s, before
 * anything ran); game.dll globals are plain loads;
 * time is the tick's dt (the Lua read GetTickCount64); the client origin comes from ScreenToClient on the cursor (the
 * core resolves no ClientToScreen). Dropped: the diagnostics (the opt-in ClickableScrollbars.log flight recorder,
 * trace, frame-interval and capture-budget bookkeeping, display scale), the optional ini (its native-route keys only
 * repeated their defaults; enabled is the component switch), the Bingus runtime's error bursts and pause (the core's
 * crash guard), the shutdown log and the UI-bridge probe (log only). An owner retired and the first verified drag on
 * each route are logged once (the Lua traced them with diagnostics only), so a session's log shows each route working.
 *
 * Tick order: the tick runs where the Lua's step ran, at the start of game.dll's frame update (0xAB5000), which the
 * engine calls right after the game's Lua update (only the engine plugins' pre-update lies between; KB
 * squad-join-pipeline-research section 1). Everything game.dll does in the frame, its UI pass included, comes after
 * it, as it came after the Lua's step. So a Settings drag's consume lands where the Lua's did, before the page's row
 * and tab handlers read the select action, and the drags see the frame as the Lua's did. Until the core's frame hook
 * is in, the tick runs from HellForge's game-thread callback inside the same update, still before the UI pass.
 *
 * COST (per frame; the Lua's pins: tests/test_frame_budget.lua):
 * - Idle (no drag, no Settings capture, no new press: play, the ship, a menu with the pointer resting or the button
 *   held from elsewhere): 1 GetAsyncKeyState, the trigger, and nothing else; no read, no allocation, no log. The Lua:
 *   the same 1 call (0.70 us in game, KB cs-idle-gate-2026-10-17).
 * - A press: 6 Windows calls (the button, GetForegroundWindow, GetWindowThreadProcessId, GetClientRect, GetCursorPos,
 *   ScreenToClient; the Lua 8 and a GetModuleHandleA: it read the clock and asked for the foreground window twice);
 *   reads: the owner (locate.c) and its model (model.c): Armory grid 8, loadout 8, Career 5, Controls 7, Settings 7
 *   (the Lua 9, 10, 6, 10, 11). A press nothing owns stops at the resolution (in play: 3 reads).
 * - A held frame: 4 Windows calls (the button, focus 2, the cursor; the Lua 5, on Settings 7: it read the clock and, on
 *   Settings, the focus twice); reads: the owner's repeat and the model, 8, 8, 5, 7, 7 (the Lua 9, 10, 6, 10, 11, the
 *   input owner included on Settings). Moving: + the game's routines (grid: scroll setter, solver, and the animation
 *   stop while one runs; Career: the position setter; Controls and Settings: the scroll and position setters).
 *   Settings: + 1 input consume.
 *   Once per gesture, 200 ms after the press: + one model read (4, 4, 2, 1, 1).
 * - A release: 3 Windows calls, no read (Settings: + 1 consume; the Lua 3, and 5 and a read on Settings).
 * - A track press: a press, then a held frame's repeat, model and write.
 * Once, at game load: 5 code checks and GetCurrentProcessId; 1 log line. While game.dll's code there is not decoded yet:
 * the 5 code checks every 30 frames (at most 60 s), no tick. */
#include <string.h>
#include <windows.h>
#include "clickable_scrollbars.h"

#define VERIFY_MS 200.0 /* native_verify_ms: the check of a gesture's first write waits this long */
#define TRACK_MARGIN 3.0 /* px either side of the bar a press still takes */

typedef struct Drag
{
    int on;
    CsTrack track;   /* the track on the desktop at the press */
    double press_y;  /* the grab point (a track press: the thumb's centre) */
    CsModel model;   /* the press snapshot, immutable for the gesture */
    CsKey key;
    double started;  /* s.now at the press */
    int writes, checked, has_sent;
    double sent;     /* the last value written */
} Drag;

/* The desktop position of the game's client area and the cursor (the Lua's viewport() and cursor()). */
typedef struct View { double x, y, height, cursor_x, cursor_y; } View;

static struct
{
    VpmComponent* self;
    const VpmUser32* user32;
    unsigned long process;  /* this process's id */
    double now;             /* ms of game time (dt) */
    int last_button;
    int capture;            /* a Settings press consumes the select action until mouse-up (settings_capture) */
    int drag_active;        /* a drag wrote this gesture */
    Drag drag;
    CsBridge* native;       /* the owner last resolved, or NULL */
    int has_model;
    CsModel model;          /* its model as last read (state.native_model) */
    int failed;             /* the owner was retired (native_failed) */
    int has_failed_key;
    CsKey failed_key;
    int focus_known, focus; /* the frame's foreground answer, asked once per frame */
    void* window;
    uint32_t clicks, pages, drags, writes, verified, retired, logged_routes;
    const char* reason;     /* the last decision (note) */
} s;

static CsBridge g_bridges[2]; /* the owner and the spare a resolution fills (each with its tape: static) */

static void Note(const char* reason) { s.reason = reason; }

static void DropDrag(void)
{
    s.drag.on = 0;
    s.drag_active = 0;
}

static CsBridge* Spare(void) { return s.native == &g_bridges[0] ? &g_bridges[1] : &g_bridges[0]; }

/* platform.foreground_self: the foreground window belongs to this process. Asked once per frame. */
/* lint: per-frame */
static int ForegroundSelf(void)
{
    if (s.focus_known) return s.focus;
    unsigned long process = 0;
    s.window = s.user32->GetForegroundWindow(); /* lint-ok: C4 a frame with a gesture or a press only */
    if (s.window != NULL) (void)s.user32->GetWindowThreadProcessId(s.window, &process); /* lint-ok: C4 as above */
    s.focus = s.window != NULL && process == s.process;
    s.focus_known = 1;
    return s.focus;
}

/* The client area's top-left on the desktop (ClientToScreen of its origin in the Lua: the cursor less its client
 * position here), its height, and the cursor. */
/* lint: per-frame */
static int ReadView(View* v)
{
    RECT rect;
    POINT cursor, client;
    if (!s.user32->GetClientRect(s.window, &rect)) return 0; /* lint-ok: C4 a press only */
    if (!s.user32->GetCursorPos(&cursor)) return 0; /* lint-ok: C4 a press only */
    client = cursor;
    if (!s.user32->ScreenToClient(s.window, &client)) return 0; /* lint-ok: C4 a press only */
    v->x = (double)(cursor.x - client.x);
    v->y = (double)(cursor.y - client.y);
    v->height = (double)rect.bottom;
    v->cursor_x = (double)cursor.x;
    v->cursor_y = (double)cursor.y;
    return 1;
}

static void LogFirstVerified(uint32_t route)
{
    static const char* const kRoutes[] = {"", "equipment list", "Career", "Controls", "Settings"};
    uint32_t bit = 1u << route;
    if (route > CS_ROUTE_SETTINGS || (s.logged_routes & bit)) return;
    s.logged_routes |= bit;
    vpm_log(s.self, "%s scrollbar: the game answered the first drag", kRoutes[route]);
}

/* native_retire: this owner is not driven again until a press resolves a different one. */
static void Retire(const char* reason)
{
    s.failed = 1;
    s.has_failed_key = s.native != NULL;
    if (s.native != NULL) s.failed_key = s.native->key;
    s.retired++;
    Note("native_retired");
    vpm_log(s.self, "native retired (%s) after %u writes", reason, s.writes);
}

/* refresh_native: resolves the owner and reads its model afresh. 1 with both. */
/* lint: per-frame */
static int RefreshNative(void)
{
    const char* reason = NULL;
    CsBridge* bridge = Spare();
    if (!cs_resolve(bridge, &reason))
    {
        s.native = NULL;
        s.has_model = 0;
        return 0;
    }
    if (s.has_failed_key && !cs_same_key(&s.failed_key, &bridge->key)) s.failed = 0; /* a different screen */
    s.native = bridge;
    s.has_model = cs_state(bridge, &s.model, &reason);
    return s.has_model;
}

/* The list is still the one grabbed. */
static int SameList(const CsModel* now, const CsModel* grabbed)
{
    return now->items == grabbed->items && now->route == grabbed->route && now->kind == grabbed->kind &&
           cs_abs(now->content - grabbed->content) <= 0.1 && cs_abs(now->span - grabbed->span) <= 0.1;
}

/* current_native: the owner and its model as the grabbed list, into s.native and s.model. */
/* lint: per-frame */
static int CurrentNative(void)
{
    const char* reason = NULL;
    CsBridge* bridge = s.native;
    if (bridge == NULL || !cs_unchanged(&bridge->tape))
    {
        bridge = Spare();
        if (!cs_resolve(bridge, &reason) || !cs_same_key(&bridge->key, &s.drag.key)) return 0;
    }
    CsModel model;
    if (!cs_state(bridge, &model, &reason) || !SameList(&model, &s.drag.model)) return 0;
    s.native = bridge;
    s.model = model;
    s.has_model = 1;
    return 1;
}

/* write_native: 0 when the write was refused (the owner is retired and the gesture dropped). */
/* lint: per-frame */
static int WriteNative(double value)
{
    double written = 0;
    const char* reason = "write refused";
    if (!cs_apply(s.native, &s.model, value, &written, &reason))
    {
        Retire(reason);
        DropDrag();
        return 0;
    }
    if (!s.drag.has_sent) s.drags++;
    s.drag_active = 1;
    s.writes++;
    s.drag.has_sent = 1;
    s.drag.sent = written;
    s.drag.writes++;
    return 1;
}

/* verify_native: once per gesture, after VERIFY_MS, also when the pointer has stopped. Small scrolls may leave the
 * visible rows unchanged; the rendered thumb shows those. */
/* lint: per-frame */
static void VerifyNative(void)
{
    if (!s.drag.has_sent || s.drag.checked || s.now - s.drag.started < VERIFY_MS) return;
    const char* reason = NULL;
    CsModel after;
    int moved = cs_state(s.native, &after, &reason) && cs_moved(&s.drag.model, &after);
    if (!moved && cs_abs(s.drag.sent - s.drag.model.value) * s.drag.track.span < 3) return;
    s.drag.checked = 1;
    if (moved)
    {
        s.verified++;
        Note("native_drag");
        LogFirstVerified(s.drag.model.route);
        return;
    }
    Retire("the game did not answer the write");
    DropDrag();
}

/* service_native_drag: the press snapshot is the origin of the pointer delta for the whole gesture. */
/* lint: per-frame */
static void ServiceDrag(double cursor_y)
{
    if (!CurrentNative())
    {
        DropDrag();
        Note("native_cancelled");
        return;
    }
    double value = 0;
    if (!cs_value_at_grab(&s.drag.model, &s.drag.track, s.drag.press_y, cursor_y, &value)) return;
    double from = s.drag.has_sent ? s.drag.sent : s.drag.model.value;
    if (cs_abs(value - from) > 0.000001 && !WriteNative(value)) return;
    VerifyNative();
}

/* begin_native_drag: a Settings press first consumes the select action; failure cancels this hold. */
/* lint: per-frame */
static int BeginDrag(double cursor_y, const CsTrack* track)
{
    if (s.native->route == CS_ROUTE_SETTINGS)
    {
        if (!cs_settings_input())
        {
            Note("settings_input_unavailable");
            return 0;
        }
        s.capture = 1;
    }
    memset(&s.drag, 0, sizeof s.drag);
    s.drag.on = 1;
    s.drag.track = *track;
    s.drag.press_y = cursor_y;
    s.drag.model = s.model;
    s.drag.key = s.native->key;
    s.drag.started = s.now;
    return 1;
}

/* handle_press: an absent, unsupported or hidden owner is a definite no-op. */
/* lint: per-frame */
static void HandlePress(void)
{
    s.clicks++;
    if (!RefreshNative()) return;
    View v;
    if (!ReadView(&v)) return;
    CsTrack track;
    cs_screen_track(&s.model, v.x, v.y, v.height, &track);
    if (v.cursor_x < track.left - TRACK_MARGIN || v.cursor_x > track.right + TRACK_MARGIN || v.cursor_y < track.top ||
        v.cursor_y > track.top + track.length)
        return;
    if (s.failed) return;
    double top = track.top + s.model.value * track.span;
    double centre = top + track.thumb / 2;
    if (!BeginDrag(v.cursor_y, &track)) return;
    if (v.cursor_y < top || v.cursor_y > top + track.thumb)
    {
        s.drag.press_y = centre;
        ServiceDrag(v.cursor_y);
        s.pages++;
        Note("native_jump");
    }
    else
        Note("bar_press");
}

/* The held gesture: a release ends it; a held button moves it. */
/* lint: per-frame */
static void HoldDrag(int down)
{
    if (!down)
    {
        Note("native_release");
        DropDrag();
        return;
    }
    POINT cursor;
    int read = s.user32->GetCursorPos(&cursor) != 0; /* lint-ok: C4 a held drag only */
    if (s.failed)
    {
        DropDrag();
        Note("native_dropped");
    }
    else if (read)
        ServiceDrag((double)cursor.y);
}

/* track_gesture: focus loss cancels ownership, and refuses a press, before the press is counted. */
/* lint: per-frame */
static void TrackGesture(int down, int pressed)
{
    if (!ForegroundSelf())
    {
        DropDrag();
        return;
    }
    if (s.drag.on) HoldDrag(down);
    if (pressed) HandlePress();
}

/* hold_settings_input: consumed before the page's row and tab handlers run, even when the drag was cancelled; only the
 * input owner is resolved here (a previous menu owner may be gone). */
/* lint: per-frame */
static void HoldSettingsInput(int down)
{
    if (ForegroundSelf() && !cs_settings_input())
    {
        DropDrag();
        Note("settings_input_cancelled");
    }
    if (!down) s.capture = 0;
}

/* The left button, down now: the trigger, read every frame as the Lua's idle check read it (0.70 us in game, KB
 * cs-idle-gate-2026-10-17; a screen-stack gate before it measured dearer). */
/* lint: per-frame */
static int ButtonDown(void)
{
    short state = s.user32->GetAsyncKeyState(VK_LBUTTON); /* lint-ok: C4 the trigger (above) */
    return ((unsigned short)state & 0x8000u) != 0;
}

/* The game-thread tick. The idle gate (the Lua's idle()): with no drag and no Settings capture, a frame without a new
 * press reads the button and ends. */
/* lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.now += (double)dt * 1000.0;
    int busy = s.drag.on || s.capture || s.drag_active;
    int down = ButtonDown();
    int pressed = down && !s.last_button;
    s.last_button = down;
    if (!busy && !pressed) return;
    s.focus_known = 0;
    if (s.capture) HoldSettingsInput(down);
    if (s.drag.on || pressed) TrackGesture(down, pressed);
}

/* The user32 function the platform lacks, or NULL (the Lua's named start-up error). */
static const char* MissingUser32(const VpmUser32* u)
{
    if (u->GetAsyncKeyState == NULL) return "GetAsyncKeyState";
    if (u->GetCursorPos == NULL) return "GetCursorPos";
    if (u->GetForegroundWindow == NULL) return "GetForegroundWindow";
    if (u->GetWindowThreadProcessId == NULL) return "GetWindowThreadProcessId";
    if (u->GetClientRect == NULL) return "GetClientRect";
    if (u->ScreenToClient == NULL) return "ScreenToClient";
    return NULL;
}

/* The five routines read as shipped (at game load, or on the frame they first do): bound, and the tick starts. */
static void RoutinesReady(VpmComponent* self, HfEvent event)
{
    cs_routines_bind();
    s.process = GetCurrentProcessId();
    if (!vpm_tick_start(self, Tick)) { vpm_fail(self, "the game thread is not reachable"); return; }
    vpm_log(self, "running: drags the equipment, Career, Controls and Settings scrollbars (game routines checked)");
}

static void GameLoaded(VpmComponent* self, HfEvent event)
{
    if (vpm_ticking(self)) return;
    const char* missing = MissingUser32(s.user32);
    if (missing != NULL) { vpm_fail(self, "user32.%s unavailable", missing); return; }
    int count = 0;
    const VpmCodePin* pins = cs_routine_pins(&count);
    if (!vpm_when_code_ready(self, pins, count, RoutinesReady)) vpm_fail(self, "unsupported native scroll routine");
}

void cs_counts(CsCounts* out)
{
    *out = (CsCounts){s.clicks, s.pages, s.drags, s.writes, s.verified, s.retired, s.drag.on, s.drag_active, s.failed,
        s.capture, s.reason};
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    memset(g_bridges, 0, sizeof g_bridges);
    s.self = self;
    s.user32 = vpm_user32();
    return vpm_on_load(self, HF_EVENT_GAME_LOADED, GameLoaded) ? 0 : 1;
}

const VpmComponentDef vpm_component_clickable_scrollbars = {"clickable_scrollbars", "Clickable Scrollbars", "2.15.1", 0, Start, NULL};
