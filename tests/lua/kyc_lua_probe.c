/* The DLL tests/lua/know_your_constellation_test.lua runs the pack's Lua part against: Know Your Constellation's
 * kyc_lua.c and kyc_gui.c as the pack builds them, with the panel (kyc_panel.c) replaced by a script that makes every
 * kyc_gui.h call once with known arguments and records what came back. So the test checks, through LuaJIT's real ffi,
 * the bridge the game uses: the Lua part's cdef against kyc_lua.h's structs, the attach, the update's gate, each
 * engine call's arguments and results, an engine error coming back as a failure, and a refused version.
 * Built by scripts/build.ps1 -Test as build/tests/kyc_lua_probe.dll. */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "components/know_your_constellation/kyc.h"
#include "components/know_your_constellation/kyc_gui.h"
#include "components/know_your_constellation/kyc_lua.h"
#include "components/know_your_constellation/kyc_panel.h"

#define PROBE HF_MOD_EXPORT

/* ---- what know_your_constellation.c and the core give kyc_lua.c ------------------------------------------------ */

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
    return 0;
}

void kyc_error_clear(void)
{
    kyc_error.pending = NULL;
    kyc_error.failure[0] = 0;
}

const char* kyc_error_text(void) { return kyc_error.pending != NULL ? kyc_error.pending : kyc_error.failure; }

int vpm_guarded(VpmComponent* self, void (*fn)(void*), void* arg)
{
    fn(arg);
    return 1;
}

/* ---- the panel: a script over the route ---------------------------------------------------------------------- */

/* r[i]: what each call gave (the test reads them by these indexes). */
static double r[32];
static int32_t counts[4]; /* shows, clears, suspends, draws that ran the whole script */
static KycPanelView view;
static KycRef world;

#define FONT 0x0123456789ABCDEFull
#define MATERIAL 0x1111222233334444ull
#define ATLAS 0xFEDCBA9876543210ull

static KycColour Ink(uint8_t a, uint8_t red, uint8_t green, uint8_t blue) { return (KycColour){a, red, green, blue}; }

static void Ink_(const KycGui* g, KycRef gui)
{
    KycRef material = g->material(gui, MATERIAL);
    r[6] = (double)material;
    g->set_scalar(material, 0x8035C26600000000ull, 0.25);
    g->set_vector2(material, 0xE13777CE00000000ull, 1, -1);
    g->set_vector4(material, 0x7701209E00000000ull, Ink(0, 0, 0, 0));
    g->set_texture(material, 0x88BAC99B00000000ull, ATLAS);
}

static void Script(const KycGui* g)
{
    KycRef list[KYC_LUA_WORLDS];
    r[0] = (double)g->main_world();
    int n = g->worlds(list, KYC_LUA_WORLDS);
    r[1] = n;
    for (int i = 0; i < 3; i++) r[2 + i] = i < n ? (double)list[i] : 0;
    world = n > 1 ? list[1] : 0;
    KycRef gui = g->create_screen_gui(world);
    r[5] = (double)gui;
    if (gui == 0) return;
    Ink_(g, gui);
    double w = 0, h = 0, out[3] = {0, 0, 0};
    r[7] = g->resolution(&w, &h);
    r[8] = w;
    r[9] = h;
    r[10] = g->text_extents(gui, "AB\xC3\xA9", 4, FONT, 18, out);
    r[11] = out[0];
    r[12] = out[1];
    r[13] = out[2];
    KycBox box = {10, 20, 1012, 30, 40}, moved = {11, 21, 1013, 31, 41};
    KycRef rect = g->rect(gui, &box, Ink(255, 1, 2, 3));
    r[14] = (double)rect;
    g->update_rect(gui, rect, &moved, Ink(204, 4, 5, 6));
    KycLabel label = {"Hello there", 5, FONT, MATERIAL, 13, 5, 6, 1014, Ink(255, 240, 243, 245)};
    KycRef text = g->text(gui, &label);
    r[15] = (double)text;
    label.text = "World";
    label.x = 7;
    g->update_text(gui, text, &label);
    r[16] = (double)g->rect(gui, &box, Ink(255, 7, 8, 9));
    view.gui = gui;
    view.world = world;
    counts[3]++;
}

int kyc_panel_show(const KycModel* model, double dt, const KycAnchor* anchor)
{
    counts[0]++;
    r[17] = dt;
    r[18] = anchor->x;
    if (view.gui == 0) Script(kyc_gui());
    return view.gui != 0;
}

int kyc_panel_suspend(const KycAnchor* anchor)
{
    counts[2]++;
    return view.gui != 0;
}

int kyc_panel_clear(void)
{
    counts[1]++;
    if (view.gui != 0) kyc_gui()->destroy_gui(view.world, view.gui);
    view.gui = 0;
    view.has_scroll = 0;
    return 1;
}

const KycPanelView* kyc_panel_view(void) { return &view; }

/* ---- the test's calls -------------------------------------------------------------------------------------------- */

static KycModel g_models[2];
static KycAnchor g_anchors[2];

PROBE double* probe_results(void) { return r; }
PROBE int32_t* probe_counts(void) { return counts; }
PROBE int probe_work(void) { return kyc_lua_bridge()->work; }
PROBE int probe_route(void) { return kyc_lua_route(); }
PROBE const char* probe_absent(void) { return kyc_lua_absent(); }
PROBE const char* probe_error(void) { return kyc_error_text(); }
PROBE void probe_scroll(int on) { view.has_scroll = on; }

/* One step of the component's frame: 0 adopt, 1 and 2 show a model (two different ones), 3 clear, 4 suspend, 5 show
 * model 1 at another anchor. Its result as the frame sees it; probe_error says the error it gave. */
PROBE int probe_tick(int what)
{
    kyc_error_clear();
    g_models[0].signature = 11;
    g_models[1].signature = 22;
    g_anchors[0].x = 100;
    g_anchors[1].x = 200;
    switch (what)
    {
    case 0: return kyc_lua_adopt();
    case 1: return kyc_surface_show(&g_models[0], 1.0 / 60, &g_anchors[0]);
    case 2: return kyc_surface_show(&g_models[1], 1.0 / 60, &g_anchors[0]);
    case 3: return kyc_surface_clear();
    case 4: return kyc_surface_suspend(&g_anchors[0]);
    default: return kyc_surface_show(&g_models[0], 1.0 / 60, &g_anchors[1]);
    }
}
