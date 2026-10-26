/* Know Your Constellation's Lua part, the DLL's side (kyc_lua.h). The panel needs the engine's Gui (stingray.Gui, World,
 * Application, Material), which only the game's Lua reaches on HellForge (kyc_gui.c). So the pack ships one Lua file,
 * lua/forecast_panel.lua, in a data patch that HellForge stages with the pack and Bingus Shared Loader starts, and the
 * split is:
 *   C    everything else: the mission reads, the forecast, which screen and mission the panel is for, when it shows,
 *        waits, hides or moves, its layout, measuring, caching and scrolling (kyc_panel.c, unchanged), and the
 *        decision of when the Lua part has work.
 *   Lua  only the engine Gui calls: one dispatcher, a LuaJIT ffi callback, which makes the one call a KycLuaCall names
 *        (kyc_gui.h's members, one op each) and keeps the engine's objects behind numbers; and an update hook whose
 *        idle frames read one integer (the bridge's `work`) and stop there.
 *
 * How they talk. The Lua part finds the pack's DLL already loaded (GetModuleHandleA), attaches once with its
 * dispatcher and gets the bridge (vpm_kyc_lua_attach). The component's frame (the core's tick, at the start of
 * game.dll's update) adopts it as the panel's route (kyc_lua_adopt) and from then on drives the panel through
 * kyc_surface_*: they record the change (show this model at this anchor, keep the frame, clear) and set `work` when it
 * differs from what was drawn. The Lua part's next update, the same point of the next frame where the Lua mod drew,
 * sees `work` and calls vpm_kyc_lua_apply, which runs kyc_panel_show, suspend or clear with the dispatcher as the
 * route: the Lua calls C, which calls back into Lua for each engine call, inside that one call (LuaJIT's supported
 * callback pattern; the Lua part keeps its functions out of the JIT, as callbacks need). The draw's result comes back
 * to the frame on its next show or suspend, so a draw's wait or error is handled exactly as the frame handled them.
 * Both sides run on the game thread: the Lua update, then game.dll's update with the tick.
 *
 * When `work` is set: the change differs from the last draw; the last draw did not draw or failed (retried next
 * frame, as the Lua retried every frame); a headline scrolls (every frame, as in the Lua); and every 30th frame while
 * the panel is up, the world list and the window size are checked again (the Lua checked them every frame: a world
 * that is replaced or a window that is resized now moves or hides the panel within 30 frames, unless the native
 * panel moved first, which redraws at once).
 *
 * Cost (Lua part included; engine calls unmeasured in game):
 * - Idle (the panel hidden, or up and still): C, nothing beyond the frame's own reads (kyc_surface_* compare the model's
 *   signature and the anchor's numbers, no call); Lua, its update reads `work` and returns: no ffi call, no engine call,
 *   no allocation. Off the war table and briefing the frame's idle gate runs alone, as before.
 * - A change (a new forecast, the panel moved, shown, hidden): one apply, with the panel's engine calls (kyc_panel.c:
 *   the world list, main world and window size, then the rectangles and texts that changed), each one ffi callback.
 * - Up and still, every 30th frame: one apply with 3 engine calls (Lua mod: 3 every frame). A scrolling headline:
 *   every frame 3 engine calls plus one text update when it moves (as the Lua mod).
 * The apply runs under the pack's crash guard for the component (vpm_guarded): a fault in the panel's C stops the
 * component, never the game. */
#include <stdio.h>
#include <string.h>
#include "kyc_lua.h"
#include "kyc_gui.h"
#include "kyc_panel.h"

#define RECHECK 30 /* frames between the checks of the world list and window size while the panel is still */

#define OP_NONE 0
#define OP_CLEAR 1
#define OP_SHOW 2
#define OP_SUSPEND 3

static KycLuaBridge g_bridge = {KYC_LUA_VERSION, 0};
static KycLuaCall g_call;
static KycModel g_model;       /* the model the request shows */
static KycAnchor g_anchor;     /* and its anchor */

static struct
{
    VpmComponent* self;
    KycLuaDispatch dispatch;   /* the attached Lua part's, or NULL */
    uint32_t refused_version, refused_size;
    int refused, refusal_seen;
    /* the request */
    int op, changed, has_model, since;
    double dt;
    /* the last draw */
    int result;                /* 1 done, 0 not drawn, KYC_ERROR */
    int unseen;                /* its error is not yet the frame's */
    int given;                 /* this frame was given it (kyc_surface_drop keeps the retry) */
    const char* pending;
    char failure[192];
    char raised[192];          /* the first engine call that raised during the draw */
} l = {.result = 1};

static const KycGui kLuaRoute;

static int Deferred(void) { return kyc_gui() == &kLuaRoute; }
int kyc_lua_route(void) { return Deferred(); }

/* ---- the route: one dispatcher call per engine call ---------------------------------------------------------- */

/* lint: per-frame */
static int Call(int op)
{
    g_call.op = op;
    int result = l.dispatch(&g_call);
    if (result == KYC_LUA_RAISED && l.raised[0] == 0)
    {
        g_call.error[sizeof g_call.error - 1] = 0;
        snprintf(l.raised, sizeof l.raised, "%s", g_call.error[0] ? g_call.error : "an engine call raised");
    }
    return result;
}

static void Hex(int slot, uint64_t hash) { snprintf(g_call.id[slot], sizeof g_call.id[slot], "%016llx", (unsigned long long)hash); }
static void Colour(KycColour c) { g_call.a = c.a; g_call.r = c.r; g_call.g = c.g; g_call.b = c.b; }

static const char* LuaUnavailable(void) { return l.dispatch != NULL ? NULL : "the Lua part detached"; }

/* lint: per-frame */
static KycRef LuaMainWorld(void) { return Call(KYC_LUA_MAIN_WORLD) == 1 ? (KycRef)g_call.world : 0; }

/* lint: per-frame */
static int LuaWorlds(KycRef* list, int capacity)
{
    g_call.capacity = capacity < KYC_LUA_WORLDS ? capacity : KYC_LUA_WORLDS;
    int count = Call(KYC_LUA_WORLDS_OP);
    if (count < 0) return -1;
    if (count > g_call.capacity) count = g_call.capacity;
    for (int i = 0; i < count; i++) list[i] = (KycRef)g_call.refs[i];
    return count;
}

static KycRef LuaCreateGui(KycRef world)
{
    g_call.world = (double)world;
    return Call(KYC_LUA_CREATE_GUI) == 1 ? (KycRef)g_call.gui : 0;
}

static void LuaDestroyGui(KycRef world, KycRef gui)
{
    g_call.world = (double)world;
    g_call.gui = (double)gui;
    (void)Call(KYC_LUA_DESTROY_GUI);
}

static KycRef LuaMaterial(KycRef gui, uint64_t material)
{
    g_call.gui = (double)gui;
    Hex(0, material);
    return Call(KYC_LUA_MATERIAL) == 1 ? (KycRef)g_call.item : 0;
}

static void LuaSetScalar(KycRef material, uint64_t slot, double value)
{
    g_call.item = (double)material;
    Hex(0, slot);
    g_call.value = value;
    (void)Call(KYC_LUA_SET_SCALAR);
}

static void LuaSetVector2(KycRef material, uint64_t slot, double x, double y)
{
    g_call.item = (double)material;
    Hex(0, slot);
    g_call.x = x;
    g_call.y = y;
    (void)Call(KYC_LUA_SET_VECTOR2);
}

static void LuaSetVector4(KycRef material, uint64_t slot, KycColour colour)
{
    g_call.item = (double)material;
    Hex(0, slot);
    Colour(colour);
    (void)Call(KYC_LUA_SET_VECTOR4);
}

static void LuaSetTexture(KycRef material, uint64_t slot, uint64_t texture)
{
    g_call.item = (double)material;
    Hex(0, slot);
    Hex(1, texture);
    (void)Call(KYC_LUA_SET_TEXTURE);
}

/* lint: per-frame */
static int LuaResolution(double* width, double* height)
{
    if (Call(KYC_LUA_RESOLUTION) != 1) return 0;
    *width = g_call.w;
    *height = g_call.h;
    return 1;
}

static void Text(const char* text, size_t length)
{
    g_call.text = text;
    g_call.length = (uint32_t)length;
}

static int LuaTextExtents(KycRef gui, const char* text, size_t length, uint64_t font, double size, double out[3])
{
    g_call.gui = (double)gui;
    Text(text, length);
    Hex(0, font);
    g_call.size = size;
    int got = Call(KYC_LUA_TEXT_EXTENTS);
    if (got <= 0) return 0;
    for (int i = 0; i < 3; i++) out[i] = g_call.out[i];
    return got & (KYC_EXTENT_MIN | KYC_EXTENT_MAX | KYC_EXTENT_CARET);
}

static void Box(KycRef gui, const KycBox* box, KycColour colour)
{
    g_call.gui = (double)gui;
    g_call.x = box->x;
    g_call.y = box->y;
    g_call.z = box->z;
    g_call.w = box->w;
    g_call.h = box->h;
    Colour(colour);
}

static KycRef LuaRect(KycRef gui, const KycBox* box, KycColour colour)
{
    Box(gui, box, colour);
    return Call(KYC_LUA_RECT) == 1 ? (KycRef)g_call.item : 0;
}

static void LuaUpdateRect(KycRef gui, KycRef id, const KycBox* box, KycColour colour)
{
    Box(gui, box, colour);
    g_call.item = (double)id;
    (void)Call(KYC_LUA_UPDATE_RECT);
}

static void Label(KycRef gui, const KycLabel* label)
{
    g_call.gui = (double)gui;
    Text(label->text, label->length);
    Hex(0, label->font);
    Hex(1, label->material);
    g_call.size = label->size;
    g_call.x = label->x;
    g_call.y = label->y;
    g_call.z = label->z;
    Colour(label->colour);
}

static KycRef LuaText(KycRef gui, const KycLabel* label)
{
    Label(gui, label);
    return Call(KYC_LUA_TEXT) == 1 ? (KycRef)g_call.item : 0;
}

/* lint: per-frame */
static void LuaUpdateText(KycRef gui, KycRef id, const KycLabel* label)
{
    Label(gui, label);
    g_call.item = (double)id;
    (void)Call(KYC_LUA_UPDATE_TEXT);
}

static const KycGui kLuaRoute = {"lua", LuaUnavailable, LuaMainWorld, LuaWorlds, LuaCreateGui, LuaDestroyGui, LuaMaterial,
    LuaSetScalar, LuaSetVector2, LuaSetVector4, LuaSetTexture, LuaResolution, LuaTextExtents, LuaRect, LuaUpdateRect,
    LuaText, LuaUpdateText};

/* ---- the Lua part's calls ------------------------------------------------------------------------------------ */

KycLuaBridge* vpm_kyc_lua_attach(uint32_t version, uint32_t call_size, KycLuaDispatch dispatch)
{
    if (version != KYC_LUA_VERSION || call_size != sizeof(KycLuaCall) || dispatch == NULL)
    {
        l.refused_version = version;
        l.refused_size = call_size;
        l.refused = 1;
        return NULL;
    }
    l.dispatch = dispatch;
    l.refused = 0;
    return &g_bridge;
}

/* Whether the Lua part has work: the bridge's `work`. lint: per-frame */
static void Want(void)
{
    const KycPanelView* view = kyc_panel_view();
    int up = view->gui != 0;
    int work = l.op != OP_NONE && (l.changed || l.result != 1 || (l.op != OP_CLEAR && up && view->has_scroll) ||
        (l.op == OP_SHOW && up && l.since >= RECHECK));
    g_bridge.work = work;
}

static void Draw(void* unused)
{
    int op = l.op, result = 1;
    kyc_error_clear();
    l.raised[0] = 0;
    if (op == OP_CLEAR) result = kyc_panel_clear() ? 1 : KYC_ERROR;
    else if (op == OP_SHOW) result = kyc_panel_show(&g_model, l.dt, &g_anchor);
    else if (op == OP_SUSPEND && kyc_panel_suspend(&g_anchor) == KYC_ERROR) result = KYC_ERROR; /* 0: nothing kept */
    if (l.raised[0] != 0)
    {
        kyc_error_clear();
        (void)kyc_fail("engine Gui: %s", l.raised);
        result = KYC_ERROR;
    }
    l.result = result;
    l.changed = 0;
    l.since = 0;
    l.dt = 0;
    l.unseen = result == KYC_ERROR && op != OP_CLEAR; /* a failed clear retries quietly, as the Lua's was not counted */
    l.pending = kyc_error.pending;
    snprintf(l.failure, sizeof l.failure, "%s", kyc_error.failure);
    kyc_error_clear();
    /* A draw that failed removes the forecast at once, as the Lua mod's frame did on the same frame (its errors here
     * are not counted, as the Lua's pcall did not count them). */
    if (l.unseen) (void)kyc_panel_clear();
    kyc_error_clear();
}

/* lint: per-frame */
void vpm_kyc_lua_apply(void)
{
    if (!Deferred() || l.op == OP_NONE)
    {
        g_bridge.work = 0;
        return;
    }
    if (l.self != NULL) (void)vpm_guarded(l.self, Draw, NULL); /* a fault stops the component, whose stop() clears */
    else Draw(NULL);
    Want();
}

/* ---- the component's side -------------------------------------------------------------------------------------- */

void kyc_lua_bind(VpmComponent* self)
{
    l.self = self;
    if (l.op == OP_CLEAR && l.changed) return; /* a stop's clear not drawn yet: the Lua part's next update draws it */
    l.op = l.changed = l.has_model = l.since = l.unseen = 0;
    l.dt = 0;
    l.result = 1;
    g_bridge.work = 0;
}

/* lint: per-frame */
int kyc_lua_adopt(void)
{
    if (l.refused && !l.refusal_seen)
    {
        l.refusal_seen = 1;
        return -1;
    }
    if (l.dispatch == NULL || !kyc_gui_is_none()) return 0;
    kyc_gui_use(&kLuaRoute);
    l.op = l.changed = l.since = l.unseen = 0;
    l.result = 1;
    return 1;
}

const char* kyc_lua_absent(void)
{
    static char why[192];
    if (l.refused)
        snprintf(why, sizeof why, "the pack's Lua part is version %u with a %u-byte call, this DLL takes version %d with %u "
            "bytes (a mixed install)", l.refused_version, l.refused_size, KYC_LUA_VERSION, (unsigned)sizeof(KycLuaCall));
    else
        snprintf(why, sizeof why, "the pack's Lua part has not started (Bingus Shared Loader starts it; HellForge does not "
            "ship that loader)");
    return why;
}

/* The last draw's error, now the frame's: KYC_ERROR. */
static int Give(void)
{
    l.unseen = 0;
    l.given = 1;
    if (l.pending != NULL) (void)kyc_pending(l.pending);
    else (void)kyc_fail("%s", l.failure[0] ? l.failure : "the forecast panel could not be drawn");
    return KYC_ERROR;
}

static int SameAnchor(const KycAnchor* a)
{
    const KycAnchor* b = &g_anchor;
    return a->x == b->x && a->y == b->y && a->w == b->w && a->h == b->h && a->scale == b->scale && a->font == b->font &&
        a->material == b->material && a->atlas == b->atlas;
}

static int SameModel(const KycModel* m)
{
    return l.has_model && m->signature == g_model.signature && m->pending == g_model.pending &&
        m->screen == g_model.screen && strcmp(m->key.text, g_model.key.text) == 0;
}

/* lint: per-frame */
int kyc_surface_show(const KycModel* model, double dt, const KycAnchor* anchor)
{
    if (!Deferred()) return kyc_panel_show(model, dt, anchor);
    l.given = 0;
    if (l.unseen) return Give();
    if (l.op != OP_SHOW || !SameModel(model) || !SameAnchor(anchor))
    {
        if (!SameModel(model)) memcpy(&g_model, model, sizeof g_model);
        g_anchor = *anchor;
        l.has_model = 1;
        l.op = OP_SHOW;
        l.changed = 1;
    }
    l.dt += dt > 0 ? dt : 0;
    l.since++;
    Want();
    return l.result == 0 && !l.changed ? 0 : 1;
}

/* lint: per-frame */
int kyc_surface_suspend(const KycAnchor* anchor)
{
    if (!Deferred()) return kyc_panel_suspend(anchor);
    l.given = 0;
    if (l.unseen) return Give();
    if (l.op != OP_SUSPEND || !SameAnchor(anchor))
    {
        g_anchor = *anchor;
        l.op = OP_SUSPEND;
        l.changed = 1;
    }
    l.since++;
    Want();
    return 1;
}

/* lint: per-frame */
int kyc_surface_clear(void)
{
    if (!Deferred()) return kyc_panel_clear();
    l.given = 0;
    l.unseen = 0; /* the frame hides: a draw it has not seen is moot, as the Lua never drew it */
    if ((l.op == OP_CLEAR || l.op == OP_NONE) && !l.changed && l.result == 1 && kyc_panel_view()->gui == 0) return 1;
    if (l.op != OP_CLEAR)
    {
        l.op = OP_CLEAR;
        l.changed = 1;
    }
    Want();
    return 1;
}

/* lint: per-frame */
int kyc_surface_drop(void)
{
    if (!Deferred() || !l.given) return kyc_surface_clear();
    l.given = 0; /* the failed draw removed the forecast itself; its retry stays for the Lua part's next update */
    Want();
    return 1;
}

const KycLuaBridge* kyc_lua_bridge(void) { return &g_bridge; }

void kyc_lua_reset(void)
{
    if (Deferred()) kyc_gui_use(NULL);
    memset(&l, 0, sizeof l);
    l.result = 1;
    g_bridge.work = 0;
}
