/* Know Your Constellation: the Lua tests' scenarios (components/KnowYourConstellation/tests/test_*.lua) on the fake
 * game. The memory is the Lua fixtures' (tests/fixtures/memory.lua, tests/session.lua): the same records at the same
 * offsets, game.dll's statics in the fake image and the heap records in the fake heap. The engine's Gui is a fake
 * route (kyc_gui_use) that records every call, as the Lua tests' engine fakes did. Calls per frame are pinned with the
 * harness's counts (HfApi.read) and the fake Gui's counts (engine calls). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/know_your_constellation/kyc.h"
#include "components/know_your_constellation/kyc_mission.h"
#include "components/know_your_constellation/kyc_panel.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_know_your_constellation};

/* ---- memory ------------------------------------------------------------------------------------------------- */

static uintptr_t Game(uint32_t rva) { return fake_game() + rva; }
static uintptr_t Heap(size_t size) { return (uintptr_t)fake_heap(size); }
static void P8(uintptr_t at, uint8_t v) { memcpy((void*)at, &v, 1); }
static void P16(uintptr_t at, uint16_t v) { memcpy((void*)at, &v, 2); }
static void P32(uintptr_t at, uint32_t v) { memcpy((void*)at, &v, 4); }
static void P64(uintptr_t at, uint64_t v) { memcpy((void*)at, &v, 8); }
static void PF(uintptr_t at, float v) { memcpy((void*)at, &v, 4); }

#define PLANET_76 910588397u
#define PLANET_268 1653510998u
#define PACKET "synthetic-public-test-mission"
#define FONT 0xB56D2ABAC5D17DF2ull
#define MATERIAL 0x9F85B87D3FF20CBBull
#define ATLAS 0xD1EBB991C79F934Bull
#define WAR_STRIDER 0xBFB1567Bu
#define TANK 0x72C5564Au

typedef struct Fixture
{
    uintptr_t screen, root, board, controller, defs, level, config, globals, session, remote, fallback;
    uintptr_t manager, owner, material, briefing, campaign;
    int faction, planet, tag;
    char key[72];
} Fixture;
static Fixture F;

static void Stack(uint32_t top)
{
    memset((void*)(F.screen + 0x429C), 0, 24);
    P32(F.screen + 0x429C, top);
    P32(F.screen + 0x429C + 20, 1);
}

static void ShowScreen(uint32_t top) { Stack(top); }

/* memory.lua M.mission(kind): 'host', 'join' (a joinable Illuminate mission) or 'other' (a joinable hover on planet
 * 268 while the ship's operation is on 76). The difficulty row also holds its level (+4), which the port checks. */
static void Mission(const char* kind)
{
    int joined = strcmp(kind, "host") != 0;
    F.planet = strcmp(kind, "other") == 0 ? 268 : 76;
    F.faction = strcmp(kind, "join") == 0 ? 4 : 2;
    F.tag = strcmp(kind, "join") == 0 ? 29 : 7;
    uint32_t hash = F.planet == 76 ? PLANET_76 : PLANET_268;
    if (F.screen == 0) F.screen = Heap(0x4300);
    F.root = Heap(714000);
    F.board = Heap(4300000);
    F.controller = Heap(1024);
    F.defs = Heap(53260);
    F.level = Heap(18510200);
    F.config = Heap(73900);
    F.globals = Heap(32 * 356);
    F.session = Heap(92200);
    F.campaign = F.board + 1053752;
    P64(Game(0x347CE28), F.screen);
    Stack(15);
    P64(Game(0x3326340), F.root);
    P64(F.root + 0xAE288, F.controller);
    P64(Game(0x347CEE8), F.board);
    P32(F.board + 1548960, joined ? 0xFFFFFFFFu : 0);
    P16(F.board + 1012352 + 16, 76);
    P8(F.board + 1012352 + 24, 1);
    P32(F.board + 1012352 + 28, 1);
    P8(F.board + 1012352 + 52, 1);
    uintptr_t d = F.board + 0x4168D0;
    P32(d, 12345);
    P32(d + 4, 54321);
    P8(d + 8, (uint8_t)F.faction);
    P8(d + 9, 10);
    P32(d + 12, hash);
    P16(d + 26, 84);
    memcpy((void*)(F.controller + 8), (const void*)d, 200);
    P32(F.board + 1548952, 76);
    P32(F.board + 1197132, 275);
    for (int k = 0; k < 2; k++)
    {
        uint32_t p = k == 0 ? 76 : 268;
        P32(F.campaign + 280 * p + 24, p == 76 ? PLANET_76 : PLANET_268);
        P32(F.campaign + 304 * p + 286752 + 36, (uint32_t)F.faction);
        P32(F.campaign + 304 * p + 286752 + 64, 1);
    }
    P64(Game(0x347CEF0), F.session);
    P8(F.session + 92102, 0xA4); /* unrelated data at the old offset, as in play */
    P64(Game(0x347CD98), F.defs);
    P32(F.defs + 53248, 1);
    P32(F.defs, 101);
    P32(F.defs + 4, 40);
    P32(F.defs + 8, 424242);
    P32(F.defs + 24, 13);
    P32(F.defs + 28, 0x9FD5943Au);
    for (uint32_t i = 0; i < 32; i++) P32(Game(0x21E1920) + 4 * i, i == 12 ? 0x9FD5943Au : 1000 + i);
    P64(Game(0x346D518), F.globals);
    P64(F.controller + 648, F.level);
    uint32_t candidate = F.faction == 4 ? 468 : 276;
    uintptr_t row = Game(0x328D2A0 + 9 * 816);
    P32(row + 4, 10);
    P32(row + 272, 1);
    P32(row + candidate, (uint32_t)F.tag + 1);
    PF(row + candidate + 4, 1.0f);
    P64(Game(0x347CDF8), F.config);
    if (joined)
    {
        F.fallback = Heap(5633620);
        F.remote = Heap(1487500);
        P32(F.board + 1548956, (uint32_t)F.planet);
        P8(F.board + 2064401, 1);
        P32(F.board + 1548964, 0xFFFFFFFFu);
        P64(Game(0x3326AA0), F.fallback);
        P32(F.fallback + 5633600, 428);
        P32(F.fallback + 5633608, 10);
        P32(F.board + 2053224, 1);
        P32(F.board + 2044424, 3);
        P32(F.board + 2044424 + 8, 10);
        P32(F.board + 2044424 + 12, 428);
        P64(Game(0x347CE80), F.remote);
        P32(F.remote + 1487456, 1);
        P8(F.remote + 1409456 + 1456, 1);
        memcpy((void*)(F.remote + 1409456 + 944), PACKET, sizeof PACKET);
        memcpy((void*)(F.root + 713400), PACKET, sizeof PACKET);
    }
    snprintf(F.key, sizeof F.key, "12345:54321:%d:10:%u:84", F.faction, hash);
}

static void Widget(uintptr_t at, float x, float y, float w, float h, float alpha)
{
    memset((void*)at, 0, 164);
    P32(at, 0xC0085011u);
    PF(at + 36, w);
    PF(at + 40, h);
    PF(at + 84, alpha);
    PF(at + 100, 4.0f / 3.0f);
    PF(at + 140, 4.0f / 3.0f);
    PF(at + 148, x);
    PF(at + 156, y);
}

/* memory.lua M.presentation(kind): 'map', 'briefing', 'loadout', 'hidden' or 'join'. */
static void Presentation(const char* kind)
{
    int briefing = strcmp(kind, "briefing") == 0 || strcmp(kind, "loadout") == 0;
    if (F.screen == 0) F.screen = Heap(0x4300);
    P64(Game(0x347CE28), F.screen);
    Stack(briefing ? 14 : 15);
    F.manager = Heap(26300);
    F.owner = Heap(526200);
    F.material = Heap(64);
    P64(Game(0x3326E68), F.manager);
    P32(F.manager + 25224, 1);
    P64(F.manager + 25224 + 8, F.owner);
    P32(F.manager + 25224 + 16, 226);
    P32(F.manager + 25272, 1);
    P64(F.manager + 25272 + 8, F.owner);
    P32(F.manager + 25272 + 16, 229);
    P32(F.owner + 8, strcmp(kind, "loadout") == 0 ? 1 : 0);
    Widget(F.owner + 31232, 512, 894.1667f, 533, 360, 1);
    Widget(F.owner + 280528, 512, 696.6667f, 533, 425.5f, 1);
    Widget(F.owner + 526048, 1900, 300, 443, 400, strcmp(kind, "hidden") == 0 ? 0.0f : 1.0f);
    P64(Game(0x3772268), FONT);
    P64(Game(0x37C5478), F.material);
    P64(F.material + 24, MATERIAL);
    P64(Game(0x3772EE8), ATLAS);
}

/* session.lua H.session(kind): the hosted mission with its operation frame visible on the map, or a client's joinable
 * hover; the briefing reuses the loaded mission descriptor through the briefing owner record. */
static void Session(int client)
{
    memset(&F, 0, sizeof F);
    Mission(client ? "join" : "host");
    Presentation(client ? "join" : "map");
    if (!client) Widget(F.owner + 349072, 512, 768.8333f, 533, 489, 1);
    F.briefing = Heap(1300);
    P32(F.manager + 26184, 1);
    P64(F.manager + 26192, F.briefing);
    P32(F.manager + 26192 + 8, 235);
    memcpy((void*)(F.briefing + 1072), (const void*)(F.controller + 8), 200);
}

static void WeightRow(uintptr_t at, uint32_t id, uint32_t family, float factor)
{
    memset((void*)at, 0, 52);
    P32(at, id);
    P32(at + 4, 72);
    P32(at + 8, 9000 + id);
    P32(at + 24, 13);
    P32(at + 28, family);
    P32(at + 36, 2);
    P32(at + 40, (uint32_t)floor(factor * 100));
    PF(at + 44, factor);
    P32(at + 48, 1);
}

static void GlobalEffect(uintptr_t at, uint8_t kind, uint32_t value4, float factor, uint8_t scope, uint32_t value)
{
    memset((void*)at, 0, 356);
    P8(at, kind);
    P32(at + 4, value4);
    PF(at + 8, factor);
    P32(at + 80, 1);
    P8(at + 84, scope);
    P32(at + 88, value);
}

/* session.lua add_weights: category-72 rows 501 and 502 on the session's planet and a war effect in scope everywhere. */
static void AddWeights(void)
{
    P32(F.defs + 53248, 3);
    WeightRow(F.defs + 52, 501, WAR_STRIDER, 5);
    WeightRow(F.defs + 104, 502, TANK, 0.5f);
    uintptr_t listed = F.campaign + 304 * 76 + 286952;
    memset((void*)listed, 0, 132);
    P32(listed, 501);
    P32(listed + 4, 502);
    P32(listed + 128, 2);
    GlobalEffect(F.globals, 15, TANK, 0.25f, 3, 0);
}

/* Three level tags (native 12, 13 and 24): a headline wider than the box; off again with 0. */
static void LongHeadline(int on)
{
    uintptr_t at = F.level + 9160276;
    P32(at, 12);
    P32(at + 4, 13);
    P32(at + 8, 24);
    P32(at + 12, on ? 3 : 0);
}

/* ---- the fake engine Gui ---------------------------------------------------------------------------------------- */

enum { C_MAIN, C_WORLDS, C_CREATE, C_DESTROY, C_MATERIAL, C_SCALAR, C_VECTOR2, C_VECTOR4, C_TEXTURE, C_RESOLUTION,
    C_EXTENTS, C_RECT, C_UPDATE_RECT, C_TEXT, C_UPDATE_TEXT, C_COUNT };
static const char* const kCallNames[C_COUNT] = {"main_world", "worlds", "create_screen_gui", "destroy_gui", "material",
    "set_scalar", "set_vector2", "set_vector4", "set_texture", "resolution", "text_extents", "rect", "update_rect", "text",
    "update_text"};

typedef struct FgText { char text[700]; size_t length; uint64_t font, material; double size, x, y, z; KycColour colour; } FgText;
static struct
{
    int calls[C_COUNT];
    KycRef worlds[4];
    int world_count, no_list;
    KycRef main, ui;
    KycRef next;
    int created, destroyed, wrong_world;
    int no_gui, no_material, no_rect, no_text, no_metrics, no_resolution;
    const char* caret_prefix_of;  /* no caret for proper prefixes of this text */
    double width, height;
    int half_font;                /* session.lua's font: half the size per byte; else test_panel.lua's */
    int scalars, range, shadow, atlas, ink_wrong, outside, uninked;
    KycBox rects[4096];
    KycColour rect_colours[4096];
    int rect_count;
    FgText texts[512];
    int text_count;
} fg;

static double Span(const char* text, size_t length, double size)
{
    double n = 0;
    size_t i = 0;
    while (i < length)
    {
        uint32_t v;
        int bytes = vpm_utf8_decode(text + i, length - i, &v);
        if (bytes == 0) { v = 0xFFFD; bytes = 1; }
        n += size * (v >= 0x2E80 ? 1 : v == 'W' ? 0.9 : v == 'I' ? 0.25 : v == ' ' ? 0.3 : 0.55);
        i += (size_t)bytes;
    }
    return n;
}

static double Width(const char* text, size_t length, double size)
{
    return fg.half_font ? (double)length * size * 0.5 : Span(text, length, size);
}

static const char* FgUnavailable(void) { return NULL; }
static KycRef FgMain(void) { fg.calls[C_MAIN]++; return fg.main; }

static int FgWorlds(KycRef* list, int capacity)
{
    fg.calls[C_WORLDS]++;
    if (fg.no_list) return -1;
    for (int i = 0; i < fg.world_count && i < capacity; i++) list[i] = fg.worlds[i];
    return fg.world_count;
}

static KycRef FgCreate(KycRef world)
{
    fg.calls[C_CREATE]++;
    if (world != fg.ui) fg.wrong_world++;
    if (fg.no_gui) return 0;
    fg.created++;
    fg.rect_count = fg.text_count = 0;
    fg.scalars = fg.range = fg.shadow = fg.atlas = 0;
    return 100 + (KycRef)fg.created;
}

static void FgDestroy(KycRef world, KycRef gui)
{
    fg.calls[C_DESTROY]++;
    if (world == fg.main) fg.wrong_world++;
    fg.destroyed++;
}

static KycRef FgMaterial(KycRef gui, uint64_t material)
{
    fg.calls[C_MATERIAL]++;
    if (material != MATERIAL) fg.ink_wrong++;
    return fg.no_material ? 0 : 7;
}

static void FgScalar(KycRef m, uint64_t slot, double value) { fg.calls[C_SCALAR]++; fg.scalars += value == 0; }
static void FgVector2(KycRef m, uint64_t slot, double x, double y)
{
    fg.calls[C_VECTOR2]++;
    if (slot == 0xE13777CE00000000ull && x == 1 && y == -1) fg.range = 1; else fg.ink_wrong++;
}
static void FgVector4(KycRef m, uint64_t slot, KycColour c)
{
    fg.calls[C_VECTOR4]++;
    if (slot == 0x7701209E00000000ull && c.a == 0) fg.shadow = 1; else fg.ink_wrong++;
}
static void FgTexture(KycRef m, uint64_t slot, uint64_t texture)
{
    fg.calls[C_TEXTURE]++;
    if (slot == 0x88BAC99B00000000ull && texture == ATLAS) fg.atlas = 1; else fg.ink_wrong++;
}

static int FgResolution(double* w, double* h)
{
    fg.calls[C_RESOLUTION]++;
    if (fg.no_resolution) return 0;
    *w = fg.width;
    *h = fg.height;
    return 1;
}

static int FgExtents(KycRef gui, const char* text, size_t length, uint64_t font, double size, double out[3])
{
    fg.calls[C_EXTENTS]++;
    if (font != FONT) fg.ink_wrong++;
    if (fg.no_metrics) return 0;
    double w = Width(text, length, size);
    out[0] = -0.08 * size;
    out[1] = w + 0.04 * size;
    out[2] = w;
    if (fg.caret_prefix_of != NULL && length < strlen(fg.caret_prefix_of) && memcmp(text, fg.caret_prefix_of, length) == 0)
        return KYC_EXTENT_MIN | KYC_EXTENT_MAX;
    return KYC_EXTENT_MIN | KYC_EXTENT_MAX | KYC_EXTENT_CARET;
}

static void CheckRect(const KycBox* b)
{
    if (!(b->x >= 0 && b->y >= 0 && b->x + b->w <= fg.width + 1 && b->y + b->h <= fg.height + 1)) fg.outside++;
}

static KycRef FgRect(KycRef gui, const KycBox* box, KycColour colour)
{
    fg.calls[C_RECT]++;
    if (fg.no_rect || fg.rect_count >= 4096) return 0;
    CheckRect(box);
    fg.rects[fg.rect_count] = *box;
    fg.rect_colours[fg.rect_count++] = colour;
    return (KycRef)fg.rect_count;
}

static void FgUpdateRect(KycRef gui, KycRef id, const KycBox* box, KycColour colour)
{
    fg.calls[C_UPDATE_RECT]++;
    CheckRect(box);
    fg.rects[id - 1] = *box;
    fg.rect_colours[id - 1] = colour;
}

static void StoreText(FgText* t, const KycLabel* l)
{
    size_t n = l->length < sizeof t->text - 1 ? l->length : sizeof t->text - 1;
    memcpy(t->text, l->text, n);
    t->text[n] = 0;
    t->length = n;
    t->font = l->font;
    t->material = l->material;
    t->size = l->size;
    t->x = l->x;
    t->y = l->y;
    t->z = l->z;
    t->colour = l->colour;
    if (!(fg.scalars >= 4 && fg.range && fg.shadow && fg.atlas)) fg.uninked++;
    if (l->font != FONT || l->material != MATERIAL) fg.ink_wrong++;
    if (!(l->x >= 0 && l->y >= 0 && l->y + l->size <= fg.height && l->x + Width(l->text, l->length, l->size) <= fg.width + 1))
        fg.outside++;
}

static KycRef FgText_(KycRef gui, const KycLabel* label)
{
    fg.calls[C_TEXT]++;
    if (fg.no_text || fg.text_count >= 512) return 0;
    StoreText(&fg.texts[fg.text_count++], label);
    return (KycRef)fg.text_count;
}

static void FgUpdateText(KycRef gui, KycRef id, const KycLabel* label)
{
    fg.calls[C_UPDATE_TEXT]++;
    StoreText(&fg.texts[id - 1], label);
}

static const KycGui kFakeGui = {"fake", FgUnavailable, FgMain, FgWorlds, FgCreate, FgDestroy, FgMaterial, FgScalar,
    FgVector2, FgVector4, FgTexture, FgResolution, FgExtents, FgRect, FgUpdateRect, FgText_, FgUpdateText};

/* test_panel.lua's engine at a resolution: worlds {main, overlay}. */
static void FakeGui(double width, double height)
{
    memset(&fg, 0, sizeof fg);
    fg.main = 1;
    fg.ui = 2;
    fg.worlds[0] = 1;
    fg.worlds[1] = 2;
    fg.world_count = 2;
    fg.width = width;
    fg.height = height;
    kyc_gui_use(&kFakeGui);
}

/* session.lua's engine: worlds {main, UI, another}, 2560 x 1440, half the size per byte. */
static void SessionGui(void)
{
    FakeGui(2560, 1440);
    fg.worlds[2] = 3;
    fg.world_count = 3;
    fg.half_font = 1;
}

static void ResetCalls(void) { memset(fg.calls, 0, sizeof fg.calls); }
static int Calls(int which) { return fg.calls[which]; }

/* Exactly these engine calls (name, count pairs ending in -1) since the last ResetCalls. */
static int OnlyCalls(const int* expected)
{
    int want[C_COUNT] = {0};
    for (int i = 0; expected[i] >= 0; i += 2) want[expected[i]] = expected[i + 1];
    int same = 1;
    for (int i = 0; i < C_COUNT; i++)
        if (fg.calls[i] != want[i]) { printf("    engine %s: %d calls, pinned at %d\n", kCallNames[i], fg.calls[i], want[i]); same = 0; }
    return same;
}

/* ---- running the component ------------------------------------------------------------------------------------- */

static void Started(void)
{
    CHECK_EQ(fake_start(kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
}

/* The component started (its readers usable) but not ticking: for the readers' and the panel's own tests. */
static void Loaded(void)
{
    CHECK_EQ(fake_start(kDefs, 1), 0);
}

static void Frames(int n, float dt) { fake_frames(n, dt); }
static uint32_t Reads(void) { return fake_counts().read; }

/* The API reads of one frame. */
static uint32_t FrameReads(float dt)
{
    uint32_t before = Reads();
    Frames(1, dt);
    return Reads() - before;
}

static const KycState* State(void) { return kyc_state(); }
static int StatusIs(const char* prefix) { return strncmp(State()->status, prefix, strlen(prefix)) == 0; }
static const KycPanelView* View(void) { return kyc_panel_view(); }
static int Up(void) { return View()->gui != 0; }
/* A complete report is drawn (not the pending frame). */
static int Shown(void) { return Up() && View()->has_model && !View()->model->pending; }
static int ShownKey(const char* key) { return Shown() && strcmp(View()->model->key.text, key) == 0; }

/* ---- the roster (test_roster.lua) -------------------------------------------------------------------------------- */

#define BUGS 2
#define BOTS 3
#define SQUIDS 4

typedef struct Forecast { KycReport report; } Forecast;

static KycTags Tags(int n, const int* list)
{
    KycTags t;
    t.count = n;
    for (int i = 0; i < n; i++) t.tag[i] = (uint8_t)list[i];
    return t;
}

static KycReport g_report;
/* Computes a forecast; 1 when it worked. */
static int Compute(int faction, KycTags tags, int difficulty, const KycWeights* zone, const KycWeights* war)
{
    kyc_error_clear();
    return kyc_roster_compute(faction, difficulty, &tags, zone, war, &g_report);
}
#define FORECAST(faction, difficulty, ...) Compute(faction, Tags(sizeof((int[]){__VA_ARGS__}) / sizeof(int), (int[]){__VA_ARGS__}), difficulty, NULL, NULL)

/* Whether the last forecast lists a name, and its meter (0 when listed without one, -1 absent). */
static int Listed(const char* name)
{
    int index = kyc_name_find(name);
    for (int i = 0; i < g_report.large_count; i++)
        if (g_report.large[i] == index) return g_report.large_ticks[i];
    for (int i = 0; i < g_report.small_count; i++)
        if (g_report.small[i] == index) return 0;
    return -1;
}
static int Has(const char* name) { return Listed(name) >= 0; }

static int OnlyThese(const char* const* names, int n)
{
    if (g_report.large_count + g_report.small_count != n) return 0;
    for (int i = 0; i < n; i++)
        if (!Has(names[i])) return 0;
    return 1;
}

static KycWeights Weights(int n, const uint32_t* family, const double* value)
{
    KycWeights w;
    memset(&w, 0, sizeof w);
    w.count = n;
    for (int i = 0; i < n; i++) { w.family[i] = family[i]; w.value[i] = value[i]; }
    return w;
}

static void RosterIntegrity(void)
{
    /* every displayed name is plain ASCII, unique, with a size class */
    for (int i = 1; i <= kyc_name_count(); i++)
    {
        const char* name = kyc_name_text(i);
        int ascii = 1;
        for (const char* p = name; *p; p++) ascii &= *p >= 32 && *p <= 126;
        CHECK(ascii && kyc_name_size(i) >= 1 && kyc_name_size(i) <= 4);
        CHECK_EQ(kyc_name_find(name), i);
    }
    CHECK_EQ(kyc_name_count(), 80);
}

static void RosterIlluminate(void)
{
    static const char* const kSnatched[] = {"Wretches", "Crushers", "Voteless", "Fleshmobs"};
    for (int d = 4; d <= 10; d++)
    {
        CHECK(FORECAST(SQUIDS, d, 29));
        CHECK(OnlyThese(kSnatched, 4)); /* Vote Snatchers replace every Overseer, Harvester, Watcher and Stingray */
    }
    CHECK(FORECAST(SQUIDS, 8, 26));
    CHECK(Has("Obtruders") && Has("Veracitors") && Has("Gatekeepers") && Has("Overseers"));
    CHECK(!Has("Voteless") && !Has("Fleshmobs") && !Has("Crescent Overseers") && !Has("Stingrays"));
    CHECK(FORECAST(SQUIDS, 8, 27));
    CHECK(Has("Stingrays") && Has("Watchers") && Has("Crescent Overseers"));
    CHECK(FORECAST(SQUIDS, 8, 28));
    CHECK(!Has("Stingrays"));
}

static void RosterAutomatons(void)
{
    static const int kBases[5] = {13, 14, 15, 17, 18};
    for (int b = 0; b < 5; b++)
        for (int d = 2; d <= 10; d++)
        {
            CHECK(Compute(BOTS, Tags(2, (int[]){kBases[b], 22}), d, NULL, NULL));
            CHECK(!Has("Berserkers") && !Has("Brawlers") && Has("Pyro Troopers") && Has("Conflagration Devastators"));
        }
    for (int b = 0; b < 5; b++)
        for (int jet = 0; jet < 2; jet++)
            for (int d = 1; d <= 10; d++)
            {
                CHECK(Compute(BOTS, Tags(jet ? 2 : 1, (int[]){kBases[b], 19}), d, NULL, NULL));
                int expected = d >= 6 && (jet || kBases[b] == 15 || kBases[b] == 13);
                CHECK_EQ(Has("War Striders"), expected);
                if (Has("War Striders"))
                    CHECK(!Has("Annihilator Tanks") && !Has("Shredder Tanks") && !Has("Barrager Tanks"));
            }
    CHECK(FORECAST(BOTS, 8, 15));
    int heavy = Listed("War Striders");
    KycWeights zone = Weights(1, (uint32_t[]){WAR_STRIDER}, (double[]){5});
    CHECK(Compute(BOTS, Tags(1, (int[]){15}), 8, &zone, NULL));
    CHECK(Listed("War Striders") > heavy); /* a War Strider zone multiplier raises its meter */
    zone = Weights(1, (uint32_t[]){WAR_STRIDER}, (double[]){-1});
    CHECK(Compute(BOTS, Tags(1, (int[]){15}), 8, &zone, NULL));
    CHECK(Has("War Striders") && Listed("War Striders") < heavy);
    zone = Weights(2, (uint32_t[]){WAR_STRIDER, TANK}, (double[]){-1, -1});
    CHECK(Compute(BOTS, Tags(1, (int[]){15}), 8, &zone, NULL));
    CHECK(!Has("War Striders"));
    KycWeights war = Weights(2, (uint32_t[]){WAR_STRIDER, TANK}, (double[]){0, 0});
    CHECK(Compute(BOTS, Tags(1, (int[]){15}), 8, NULL, &war));
    CHECK(!Has("War Striders"));
    CHECK(FORECAST(BOTS, 6, 18) && !Has("Barrager Tanks") && !Has("Factory Striders"));
    CHECK(FORECAST(BOTS, 7, 18) && Has("Barrager Tanks") && Has("Factory Striders"));
    CHECK(FORECAST(BOTS, 7, 17, 20) && Has("Vox Engines") && !Has("Factory Striders") && Has("Radicals") && Has("Agitators"));
    CHECK(FORECAST(BOTS, 8, 18, 19) && Has("Jet Brigade Hulk Bruisers") && !Has("Hulk Bruisers"));
    CHECK(FORECAST(BOTS, 8, 18) && !Has("Gunships"));
    CHECK(FORECAST(BOTS, 8, 18, 21) && Has("Gunships"));
    for (int b = 0; b < 5; b++)
        for (int d = 1; d <= 10; d++) CHECK(Compute(BOTS, Tags(1, &kBases[b]), d, NULL, NULL) && !Has("Hulk Obliterators"));
}

static void RosterTerminids(void)
{
    CHECK(FORECAST(BUGS, 7, 5) && Has("Brood Commanders") && !Has("Alpha Commanders") && !Has("Alpha Warriors"));
    CHECK(FORECAST(BUGS, 8, 5) && Has("Alpha Commanders") && Has("Alpha Warriors") && !Has("Brood Commanders"));
    CHECK(FORECAST(BUGS, 9, 6, 11) && Has("Dragonroaches") && Has("Chargers") && !Has("Bile Titans") && Has("Shriekers"));
    CHECK(FORECAST(BUGS, 8, 5, 9, 11) && Has("Dragonroaches") && Has("Spore Burst Bile Titans") && !Has("Bile Titans"));
    CHECK(FORECAST(BUGS, 9, 6) && !Has("Dragonroaches") && !Has("Shriekers"));
    CHECK(FORECAST(BUGS, 8, 5, 9) && Has("Spore Burst Warriors") && !Has("Warriors") && !Has("Scavengers") && !Has("Hunters"));
    CHECK(FORECAST(BUGS, 8, 3, 8) && Has("Predator Hunters") && Has("Predator Stalkers") && Has("Pouncers") && !Has("Hunters"));
    CHECK(FORECAST(BUGS, 5, 2, 10) && !Has("Rupture Warriors"));
    CHECK(FORECAST(BUGS, 6, 2, 10) && Has("Rupture Warriors"));
    CHECK(FORECAST(BUGS, 10, 1) && Has("Bile Spitters") && Has("Bile Spewers") && Has("Bile Warriors") && Has("Bile Titans") &&
        Has("Spore Chargers"));
    CHECK(FORECAST(BUGS, 6, 6, 23) && !Has("Hive Lords"));
    CHECK(FORECAST(BUGS, 7, 6, 23) && Has("Hive Lords"));
    static const int kBases[6] = {1, 2, 3, 5, 6, 7};
    for (int b = 0; b < 6; b++)
        for (int d = 1; d <= 10; d++)
        {
            CHECK(Compute(BUGS, Tags(1, &kBases[b]), d, NULL, NULL));
            CHECK(!Has("Stalkers") && !Has("Hive Lords"));
            if (d < 4) CHECK(!Has("Chargers"));
        }
    /* the Horde tag only adds groups */
    CHECK(FORECAST(BUGS, 9, 1));
    KycReport base = g_report;
    CHECK(FORECAST(BUGS, 9, 1, 31));
    for (int i = 0; i < base.large_count; i++) CHECK(Has(kyc_name_text(base.large[i])));
    for (int i = 0; i < base.small_count; i++) CHECK(Has(kyc_name_text(base.small[i])));
}

static void RosterOrderAndCache(void)
{
    CHECK(FORECAST(BOTS, 8, 15, 22));
    CHECK(g_report.large_count > 0 && strcmp(kyc_name_text(g_report.large[0]), "War Striders") == 0);
    for (int i = 1; i < g_report.large_count; i++) CHECK(g_report.large_ticks[i] <= g_report.large_ticks[i - 1]);
    CHECK_EQ(kyc_roster_ticks(0.16), 10);
    CHECK_EQ(kyc_roster_ticks(0.08), 9);
    CHECK_EQ(kyc_roster_ticks(0.001), 1);
    CHECK_EQ(kyc_roster_ticks(0), 0);
    kyc_roster_reset();
    const KycReport *first, *again;
    KycTags a = Tags(2, (int[]){15, 22}), b = Tags(2, (int[]){22, 15}), c = Tags(1, (int[]){15});
    CHECK(kyc_roster_report(BOTS, 8, &a, NULL, NULL, &first));
    CHECK(kyc_roster_report(BOTS, 8, &a, NULL, NULL, &again) && kyc_roster_report(BOTS, 8, &b, NULL, NULL, &again));
    CHECK_EQ(kyc_roster_computed(), 1); /* tags in another order reuse it */
    KycWeights zone = Weights(1, (uint32_t[]){WAR_STRIDER}, (double[]){5});
    CHECK(kyc_roster_report(BOTS, 8, &a, &zone, NULL, &again));
    CHECK_EQ(kyc_roster_computed(), 2); /* zone multipliers are part of the key */
    CHECK(kyc_roster_report(BOTS, 8, &c, NULL, NULL, &again));
    CHECK_EQ(kyc_roster_computed(), 3);
    CHECK(!Compute(9, Tags(0, NULL), 8, NULL, NULL));
    CHECK(strcmp(kyc_error_text(), "Unknown faction") == 0);
    CHECK(!Compute(BUGS, Tags(0, NULL), 11, NULL, NULL));
}

/* ---- the draw (test_resolve.lua) --------------------------------------------------------------------------------- */

static KycSettings Settings(const int* ids, const double* weights, int n)
{
    KycSettings s;
    memset(&s, 0, sizeof s);
    s.draws = 1;
    for (int i = 0; i < n; i++) { s.candidates[i].id = (uint8_t)ids[i]; s.candidates[i].weight = (float)weights[i]; }
    return s;
}

static int Drawn(uint32_t seed, const KycSettings* settings, const KycTags* initial, KycTags* out)
{
    kyc_error_clear();
    return kyc_draw_base(seed, settings, initial, out);
}

static void RecordedSeeds(void)
{
    /* fixtures/seeds.lua: recorded native captures (unsigned generator output, float32 rounding) */
    static const struct { uint32_t seed; int expected; double weights[6]; } kSeeds[5] = {
        {2116161941u, 5, {1.0, 0.5, 1.0, 0.699999988079071, 0.699999988079071, 1.0}},
        {883226386u, 6, {1.0, 0.800000011920929, 1.0, 0.5, 0.699999988079071, 0.6000000238418579}},
        {819222653u, 1, {1.0, 0.800000011920929, 1.0, 0.3499999940395355, 0.699999988079071, 0.6000000238418579}},
        {3245070932u, 1, {1.0, 0.800000011920929, 1.0, 0.3499999940395355, 0.699999988079071, 0.6000000238418579}},
        {951144748u, 6, {1.0, 0.800000011920929, 1.0, 0.3499999940395355, 0.699999988079071, 0.6000000238418579}},
    };
    static const int kIds[8] = {1, 2, 3, 5, 7, 6, 0, 0};
    for (int i = 0; i < 5; i++)
    {
        KycSettings s = Settings(kIds, kSeeds[i].weights, 6);
        s.blocker_count = 8;
        KycTags out;
        CHECK(Drawn(kSeeds[i].seed, &s, NULL, &out));
        CHECK(out.count == 1 && out.tag[0] == kSeeds[i].expected);
    }
}

static void DrawRules(void)
{
    KycSettings fallback;
    memset(&fallback, 0, sizeof fallback);
    fallback.draws = 1;
    fallback.fallback = 27;
    fallback.blocker_count = 5;
    memcpy(fallback.blockers, (uint8_t[]){26, 27, 28, 29, 0}, 5);
    KycTags out, initial = Tags(1, (int[]){26}), none = Tags(0, NULL);
    CHECK(Drawn(3, &fallback, &none, &out) && out.count == 1 && out.tag[0] == 27);
    CHECK(Drawn(3, &fallback, &initial, &out) && out.count == 1 && out.tag[0] == 26);
    KycTags tags = Tags(3, (int[]){1, 11, 9});
    CHECK(kyc_tag_filter(&tags, 1u << 1, 1u << 9, &out) && out.count == 1 && out.tag[0] == 11);
    CHECK(kyc_tag_filter(&tags, (1u << 1) | (1u << 11), 0, &out) && out.count == 1 && out.tag[0] == 9);
    KycSettings many;
    memset(&many, 0, sizeof many);
    many.draws = 17;
    CHECK(!Drawn(1, &many, &none, &out) && strcmp(kyc_error_text(), "Invalid draw count") == 0);
    KycSettings bad = Settings((int[]){1}, (double[]){-1}, 1);
    CHECK(!Drawn(1, &bad, &none, &out) && strcmp(kyc_error_text(), "Invalid constellation weight") == 0);
    bad.candidates[0].weight = NAN;
    CHECK(!Drawn(1, &bad, &none, &out));
    uint8_t tag;
    CHECK(kyc_from_native(0, &tag) && tag == 0);
    CHECK(kyc_from_native(1, &tag) && tag == 31);
    for (uint32_t id = 2; id <= 31; id++) CHECK(kyc_from_native(id, &tag) && tag == id - 1);
    kyc_error_clear();
    CHECK(!kyc_from_native(32, &tag));
    kyc_error_clear();
    /* the generator: state * 0x5851F42D4C957F2D + 0x14057B7EF767814F (mod 2^64) */
    CHECK(kyc_draw_step(0) == 0x14057B7EF767814Full);
    CHECK(kyc_draw_step(1) == 0x5851F42D4C957F2Dull + 0x14057B7EF767814Full);
}

/* Draws on the float32 boundary: the first row's running weight is the target (drawn), one float32 step below it (not
 * drawn), or reaches it only through the running sum's rounding (drawn). */
static void BoundaryDraws(void)
{
    uint32_t generator = 2463534242u;
    int boundaries = 0;
    for (int n = 0; n < 4000; n++)
    {
        generator = generator * 1664525u + 1013904223u;
        uint32_t seed = generator;
        uint64_t state = kyc_draw_step(seed);
        float u = (float)((double)(float)(uint32_t)(state >> 32) * 0x1p-32);
        if (u < 0.5f) continue;
        float t = (float)((double)u * 3.0);
        float gap = t > 2 ? 0x1p-22f : 0x1p-23f;
        KycTags out;
        KycSettings a = Settings((int[]){1, 3}, (double[]){t, 3 - (double)t}, 2);
        CHECK(Drawn(seed, &a, NULL, &out) && out.count == 1 && out.tag[0] == 1);
        KycSettings b = Settings((int[]){1, 3}, (double[]){t - gap, 3 - (double)(t - gap)}, 2);
        CHECK(Drawn(seed, &b, NULL, &out) && out.count == 1 && out.tag[0] == 3);
        KycSettings c = Settings((int[]){1, 2, 3}, (double[]){t - gap, 0.75 * gap, 3 - (double)t}, 3);
        CHECK(Drawn(seed, &c, NULL, &out) && out.count == 1 && out.tag[0] == 2);
        boundaries++;
    }
    CHECK(boundaries > 1000);
}

static void Headlines(void)
{
    Loaded();
    VpmComponent* self = fake_component(0);
    char out[KYC_HEADLINE_SIZE];
    for (int id = 1; id <= 31; id++) CHECK(kyc_title_key(id) != NULL && kyc_title_text(self, id) != NULL);
    KycTags t = Tags(2, (int[]){1, 11});
    CHECK(kyc_headline(self, &t, out, sizeof out) && strcmp(out, "DRAGONROACH ACTIVITY // BILE BUGS") == 0);
    t = Tags(2, (int[]){15, 22});
    CHECK(kyc_headline(self, &t, out, sizeof out) && strcmp(out, "INCINERATION CORPS // ARTILLERY FORCES") == 0);
    t = Tags(1, (int[]){27});
    CHECK(kyc_headline(self, &t, out, sizeof out) && strcmp(out, "INVASION FLEET") == 0);
    t = Tags(0, NULL);
    CHECK(kyc_headline(self, &t, out, sizeof out) && strcmp(out, "STANDARD FORCES") == 0);
    /* display text is any script; control characters never are */
    size_t bad;
    const char* why;
    CHECK(kyc_text_check("bad\xE2\x80\x94", 6, &bad, &why) && kyc_text_check("semi;colon", 10, &bad, &why));
    CHECK(!kyc_text_check("bad\x01", 4, &bad, &why) && bad == 4);
    CHECK(!kyc_text_check("bad\xFF", 4, &bad, &why) && strcmp(why, "invalid UTF-8") == 0);
}

static void ExclusionKey(void)
{
    /* mix(value, word) = ((w * m) ^ ((w * m) >> 24)) * m ^ (value * m), m = 1540483477, over 32 bits */
    uint32_t m = 1540483477u, w = 3964548889u, x = w * m;
    uint32_t fixed = ((x ^ (x >> 24)) * m) ^ (3781555287u * m);
    CHECK(kyc_exclusion_key(0, 0) == fixed);
    uint32_t h = 0x9FD5943Au * m;
    CHECK(kyc_exclusion_key(1, 0x9FD5943Au) == (((h ^ (h >> 24)) * m) ^ (fixed * m)));
}

/* ---- text (bingus_text.lua) --------------------------------------------------------------------------------------- */

static int MeasureBytes10(void* context, const char* text, size_t length, double* width)
{
    *width = (double)length * 10;
    return 1;
}
static int MeasureOne(void* context, const char* text, size_t length, double* width) { *width = 1; return 1; }
static int MeasureSpan(void* context, const char* text, size_t length, double* width)
{
    *width = Span(text, length, 1);
    return 1;
}

static void TextWrap(void)
{
    KycLine lines[64];
    char w80[81];
    memset(w80, 'W', 80);
    w80[80] = 0;
    int n = kyc_text_wrap(w80, 80, 40, MeasureBytes10, NULL, lines, 64);
    CHECK_EQ(n, 20); /* long tokens wrap without losing characters */
    size_t total = 0;
    for (int i = 0; i < n; i++) total += lines[i].length;
    CHECK_EQ(total, 80);
    kyc_error_clear();
    CHECK_EQ(kyc_text_wrap("x", 1, 0, MeasureOne, NULL, lines, 64), -1);
    CHECK(strcmp(kyc_error_text(), "Text column too narrow") == 0);
    kyc_error_clear();
    const char* list = "Troopers, MG Raiders, Hulk Bruisers";
    n = kyc_text_wrap(list, strlen(list), 6, MeasureSpan, NULL, lines, 64);
    CHECK_EQ(n, 4); /* Troopers, / MG Raiders, / Hulk / Bruisers: breaks at spaces, which are dropped */
    CHECK(n == 4 && lines[0].length == 9 && memcmp(list + lines[0].at, "Troopers,", 9) == 0);
    CHECK(n == 4 && lines[1].length == 11 && lines[3].length == 8 && memcmp(list + lines[3].at, "Bruisers", 8) == 0);
    /* CJK (one, two, ideographic comma, three, four): breaks between characters, never before closing punctuation */
    const char* cjk = "\xE4\xB8\x80\xE4\xBA\x8C\xE3\x80\x81\xE4\xB8\x89\xE5\x9B\x9B";
    n = kyc_text_wrap(cjk, strlen(cjk), 2.5, MeasureSpan, NULL, lines, 64);
    CHECK_EQ(n, 3);
    CHECK(n == 3 && lines[0].length == 3 && lines[1].length == 6 && lines[2].length == 6); /* 一 / 二、 / 三四 */
    uint16_t bounds[16];
    CHECK_EQ(kyc_text_boundaries(cjk, strlen(cjk), bounds, 16), 6);
    CHECK_EQ(vpm_utf8_length(cjk, strlen(cjk)), 5);
    const char* marked = "e\xCC\x81x"; /* e + combining acute + x: two characters */
    CHECK_EQ(kyc_text_boundaries(marked, strlen(marked), bounds, 16), 3);
}

/* ---- the mission reader (test_mission.lua) ------------------------------------------------------------------------ */

static const KycReaders* Readers(void) { return kyc_game_readers(); }
static KycSnapshot g_snap;

/* 1 a sample, 0 none (no selection or it changed), -1 an error. */
static int Sample(int screen)
{
    int found = 0;
    kyc_error_clear();
    if (!Readers()->sample(screen, &g_snap, &found)) return -1;
    return found;
}

static int Descriptor(int screen, KycDescriptor* out, int* hovered)
{
    int found = 0;
    kyc_error_clear();
    if (!Readers()->descriptor(screen, out, &found, hovered)) return -1;
    return found;
}

static int SnapHas(int tag)
{
    for (int i = 0; i < g_snap.tag_count; i++)
        if (g_snap.tags[i] == tag) return 1;
    return 0;
}

static double ZoneOf(const KycWeights* w, uint32_t family)
{
    for (int i = 0; i < w->count; i++)
        if (w->family[i] == family) return w->value[i];
    return -1;
}

static void HostedForecast(void)
{
    Loaded();
    memset(&F, 0, sizeof F);
    Mission("host");
    int screen;
    CHECK(Readers()->screen(&screen) && screen == KYC_SCREEN_MAP);
    uint32_t before = Reads();
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(strcmp(g_snap.d.key.text, F.key) == 0);
    CHECK(g_snap.tag_count == 1 && g_snap.tags[0] == 7 && g_snap.complete);
    CHECK(Reads() - before < 1500);
    /* the highlighted operation's template carries the Dragonroach modifier (definition 101, hash 424242) */
    P8(Game(0x32E98E0 + 168 * 1 + 9), 1);
    P32(F.campaign + 155672, 1);
    P32(F.campaign + 143384, 76);
    P32(F.campaign + 143384 + 4, 1);
    P32(F.campaign + 143384 + 8, 1234567);
    uintptr_t values = Heap(16), keys = Heap(16), template = Heap(128), list = Heap(16);
    P64(F.board + 0x1F8908, values);
    P64(F.board + 0x1F8908 + 8, keys);
    P32(F.board + 0x1F8908 + 16, 1);
    P64(values, template);
    P32(keys, 1234567);
    P64(template + 88, list);
    P32(template + 96, 1);
    P32(list, 424242);
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(g_snap.complete && SnapHas(11));
    /* browsing a local operation does not move the ship's active planet: the hovered operation's planet is used */
    P32(F.board + 1548952, 268);
    P32(F.campaign + 280 * 268 + 24, 123456789);
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(g_snap.complete && g_snap.d.has_operation && g_snap.d.operation_planet == 76 && g_snap.d.operation_index == 0);
    CHECK(SnapHas(11) && SnapHas(7) && g_snap.tag_count == 2);
    P32(F.board + 1548952, 76);
    P32(F.campaign + 280 * 268 + 24, PLANET_268);
    /* the backend's exclusion of the Dragonroach tag */
    uintptr_t rows = Heap(48);
    P64(F.config + 73848, rows);
    P32(F.config + 73848 + 8, 1);
    P32(F.config + 73848 + 12, 0xFFFFFFFFu);
    P32(F.config + 73848 + 16, 1);
    P32(rows, kyc_exclusion_key(1, 0x9FD5943Au));
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(g_snap.complete && !SnapHas(11) && SnapHas(7));
}

static void JoinableForecast(void)
{
    Loaded();
    memset(&F, 0, sizeof F);
    Mission("join");
    uint32_t before = Reads();
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(strcmp(g_snap.d.key.text, F.key) == 0 && g_snap.complete && g_snap.d.key.faction == 4);
    CHECK(g_snap.tag_count == 1 && g_snap.tags[0] == 29);
    CHECK(Reads() - before < 150);
    KycDescriptor d;
    int hovered;
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 1 && hovered == 1);
    /* a loading preview keeps the hover without using the previous mission */
    memcpy((void*)(F.root + 713400), "different mission packet", 25);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 0 && hovered == 1);
    memcpy((void*)(F.root + 713400), PACKET, sizeof PACKET);
    /* an inactive preview gate ends the hover without a reader failure */
    P8(F.board + 2064401, 0);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 0 && hovered == 0);
    P8(F.board + 2064401, 1);
    /* the controller's fallback selection is respected; with both sources empty the cached mission is never reused */
    uintptr_t fallback = Heap(5633620);
    P64(Game(0x3326AA0), fallback);
    P32(fallback + 5633600, 428);
    P32(fallback + 5633608, 10);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 1 && strcmp(d.key.text, F.key) == 0 && hovered == 1);
    P32(fallback + 5633600, 0xFFFFFFFFu);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 0 && hovered == 0);
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 0);
    P64(Game(0x3326AA0), F.fallback);
    /* an oversized joinable table is refused */
    P32(F.board + 2053224, 441);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == -1 && kyc_error.pending == NULL);
    P32(F.board + 2053224, 1);
    /* a missing preview slot keeps the hover without reading stale data */
    P32(F.board + 4286668, 0xFFFFFFFFu);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 0 && hovered == 1);
    P32(F.board + 4286668, 0);
    /* an invalid local index is not a joinable selection */
    P32(F.board + 1548960, 110);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == -1 && kyc_error.pending != NULL);
    P32(F.board + 1548960, 0xFFFFFFFFu);
    /* an expired advertisement waits without a reader failure */
    P8(F.remote + 1409456 + 1456, 0);
    CHECK(Descriptor(KYC_SCREEN_MAP, &d, &hovered) == 0);
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 0);
    P8(F.remote + 1409456 + 1456, 1);
    /* the advertised mission waits for the matching loaded controller */
    P32(F.controller + 8, 12346);
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(!g_snap.complete && !g_snap.d.controller_matches);
}

static void OtherPlanetHover(void)
{
    Loaded();
    memset(&F, 0, sizeof F);
    Mission("other");
    uint32_t before = Reads();
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(g_snap.complete && strcmp(g_snap.d.key.text, F.key) == 0 && g_snap.d.has_preview && g_snap.d.preview_planet == 268);
    CHECK(g_snap.tag_count == 1 && g_snap.tags[0] == 7);
    CHECK(Reads() - before < 150);
    /* a displayed planet hash mismatch withholds the report */
    P32(F.campaign + 280 * 268 + 24, PLANET_76);
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && !g_snap.complete);
    CHECK(strcmp(g_snap.first_unresolved, "Selected planet does not match this mission") == 0);
    P32(F.campaign + 280 * 268 + 24, PLANET_268);
    /* planet-scoped enemy modifiers follow the hovered planet, not the ship */
    GlobalEffect(F.globals, 17, 12, 0, 0, 76);
    GlobalEffect(F.globals + 356, 17, 2, 0, 0, 268);
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && g_snap.complete && !SnapHas(11) && SnapHas(1));
    memset((void*)F.globals, 0, 2 * 356);
    /* every one of the eight mission exclusions removes its tag; HordeOnly adds its native tag */
    uintptr_t record = Game(0x3773420 + 896 * 84);
    P32(record + 0x14, 8);
    P32(record + 0x18, 12);
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && !SnapHas(7) && !SnapHas(11));
    memset((void*)record, 0, 896);
    static const uint8_t kMarker[8] = {73, 120, 130, 127, 209, 44, 124, 133};
    P8(record + 52, 2);
    memcpy((void*)(record + 0x360), kMarker, 8);
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && g_snap.complete && SnapHas(31));
    memset((void*)record, 0, 896);
    /* category-72 spawn weights on the hovered planet (once per modifier id) and type-15 war effects in scope */
    P32(F.defs + 53248, 3);
    WeightRow(F.defs + 52, 501, WAR_STRIDER, 5);
    WeightRow(F.defs + 104, 502, TANK, 0.5f);
    uintptr_t hovered = F.campaign + 304 * 268 + 286952, ship = F.campaign + 304 * 76 + 286952;
    P32(hovered, 501);
    P32(hovered + 4, 501);
    P32(hovered + 8, 502);
    P32(hovered + 128, 3);
    P32(ship, 502);
    P32(ship + 128, 1);
    GlobalEffect(F.globals, 15, TANK, 0.25f, 3, 0);
    GlobalEffect(F.globals + 356, 15, WAR_STRIDER, 9, 0, 76);
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && g_snap.complete);
    CHECK(ZoneOf(&g_snap.zone, WAR_STRIDER) == 5 && ZoneOf(&g_snap.zone, TANK) == 0.5 && g_snap.zone.count == 2);
    CHECK(ZoneOf(&g_snap.war, TANK) == 0.25 && ZoneOf(&g_snap.war, WAR_STRIDER) < 0);
    memset((void*)hovered, 0, 132);
    memset((void*)ship, 0, 132);
    memset((void*)F.globals, 0, 2 * 356);
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && g_snap.zone.count == 0 && g_snap.war.count == 0);
    /* no UI state yet (while the game starts) is no forecast screen, and costs no read */
    P64(Game(0x347CE28), 0);
    int screen = -1;
    before = Reads();
    CHECK(Readers()->screen(&screen) && screen == KYC_SCREEN_NONE && Reads() == before);
    P64(Game(0x347CE28), 0x8000);
    CHECK(Readers()->screen(&screen) && screen == KYC_SCREEN_NONE);
}

/* HellForge's level 11: its row by identity from the moved table, the roster at level 10's; refused without it. */
static void LevelEleven(void)
{
    Loaded();
    memset(&F, 0, sizeof F);
    Mission("host");
    P8(F.board + 0x4168D0 + 9, 11);
    P8(F.controller + 8 + 9, 11);
    CHECK(Sample(KYC_SCREEN_MAP) == -1 && kyc_error.pending != NULL); /* no level 11 in this session: not ready */
    CHECK(strcmp(kyc_error_text(), "Mission descriptor not ready") == 0);
    /* HellForge moved the table: 11 rows, level 11 a copy of 10's with its own level */
    uint8_t* moved = fake_heap(11 * 816);
    for (int level = 1; level <= 11; level++)
    {
        memcpy(moved + (level - 1) * 816, (const void*)Game(0x328D2A0 + 9 * 816), 816);
        P32((uintptr_t)(moved + (level - 1) * 816 + 4), (uint32_t)level);
        fake_set_row("difficulty", (uint64_t)level, (uintptr_t)(moved + (level - 1) * 816));
    }
    CHECK_EQ(Sample(KYC_SCREEN_MAP), 1);
    CHECK(g_snap.complete && g_snap.d.key.difficulty == 11 && g_snap.tag_count == 1 && g_snap.tags[0] == 7);
    CHECK(strstr(g_snap.d.key.text, ":11:") != NULL);
    CHECK_EQ(kyc_highest_level(), 11);
    /* the moved row is the one read, for level 10 too: a mod's edit of its draw shows */
    P8(F.board + 0x4168D0 + 9, 10);
    P8(F.controller + 8 + 9, 10);
    P32((uintptr_t)(moved + 9 * 816 + 276), 2); /* the candidate becomes native 2: authored tag 1 */
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && g_snap.tags[0] == 1);
    /* a row that is not its level's is refused */
    P32((uintptr_t)(moved + 9 * 816 + 4), 9);
    CHECK(Sample(KYC_SCREEN_MAP) == -1 && kyc_error.pending == NULL);
    CHECK(strcmp(kyc_error_text(), "Unexpected settings row for difficulty 10") == 0);
    /* the game's own row is checked by its level too */
    fake_setup();
    Loaded();
    memset(&F, 0, sizeof F);
    Mission("host");
    P32(Game(0x328D2A0 + 9 * 816 + 4), 0);
    CHECK(Sample(KYC_SCREEN_MAP) == -1 && strcmp(kyc_error_text(), "Unexpected settings row for difficulty 10") == 0);
}

/* ---- the native panel reader (test_presentation.lua) ------------------------------------------------------------------ */

static KycAnchor g_box;

static int Anchor(int screen)
{
    int found = 0;
    kyc_error_clear();
    if (!Readers()->anchor(screen, &g_box, &found)) return -1;
    return found;
}

static void NativePanel(void)
{
    Loaded();
    memset(&F, 0, sizeof F);
    Presentation("briefing");
    int screen;
    CHECK(Readers()->screen(&screen) && screen == KYC_SCREEN_BRIEFING);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 1);
    CHECK(fabs(g_box.x - 512) < .01 && fabs(g_box.y - 894.1667) < .02 && fabs(g_box.w - 710.6667) < .02);
    CHECK(fabs(g_box.scale - 4.0 / 3.0) < .001 && g_box.font == FONT && g_box.material == MATERIAL && g_box.atlas == ATLAS);
    /* an unready atlas must not render solid glyph blocks */
    P64(Game(0x3772EE8), 0);
    CHECK(Anchor(KYC_SCREEN_BRIEFING) == -1 && strcmp(kyc_error_text(), "Native font is not ready") == 0);
    P64(Game(0x3772EE8), ATLAS);
    /* the pod entry's inherited opacity */
    static const struct { uint32_t tab; float alpha; } kEntry[4] = {{2, 0}, {0, .009f}, {0, .503f}, {0, 1}};
    for (int i = 0; i < 4; i++)
    {
        P32(F.owner + 8, kEntry[i].tab);
        PF(F.owner + 31232 + 84, kEntry[i].alpha);
        CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), kEntry[i].tab == 0 && kEntry[i].alpha >= .995f);
    }
    P32(F.owner + 8, 1);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 0); /* the loadout, even with an opaque stale briefing */
    P32(F.owner + 8, 3);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 0);
    P32(F.owner + 8, 0);
    PF(F.owner + 31232 + 84, NAN);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 0);
    PF(F.owner + 31232 + 84, 1);
    P32(F.manager + 25272, 0);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 0); /* a stale subscriber pointer is never followed */
    P32(F.manager + 25272, 1);
    P32(F.manager + 25288, 226);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 0); /* a reused component allocation */
    Widget(F.owner + 349072, 512, 768.8333f, 533, 371.375f, 1);
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.x == 512 && fabs(g_box.y - 768.8333) < .02 && fabs(g_box.w - 710.6667) < .02);
    PF(F.owner + 349072 + 148, 650);
    PF(F.owner + 349072 + 156, 700);
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.x == 650 && g_box.y == 700);
    PF(F.owner + 349072 + 84, 0);
    memset((void*)(F.owner + 280528), 0, 164);
    memset((void*)(F.owner + 526048), 0, 164);
    CHECK_EQ(Anchor(KYC_SCREEN_MAP), 0);
    CHECK_EQ(Anchor(KYC_SCREEN_NONE), 0);
    /* a separate loadout state */
    fake_setup();
    Loaded();
    memset(&F, 0, sizeof F);
    Presentation("loadout");
    CHECK(Readers()->screen(&screen) && screen == KYC_SCREEN_BRIEFING);
    CHECK_EQ(Anchor(KYC_SCREEN_BRIEFING), 0);
}

static void JoinablePanel(void)
{
    Loaded();
    memset(&F, 0, sizeof F);
    Presentation("join");
    CHECK_EQ(Anchor(KYC_SCREEN_MAP), 1);
    CHECK(g_box.client && g_box.active && fabs(g_box.w - 710.6667) < .02); /* the left planet frame, not the card */
    CHECK(g_box.x == 512 && fabs(g_box.y - 696.6667) < .02);
    double x = g_box.x, y = g_box.y, h = g_box.h;
    Widget(F.owner + 526048, 2000, 200, 443, 650, 1);
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.client && g_box.active && g_box.x == x && g_box.y == y && g_box.h == h);
    PF(F.owner + 526048 + 84, .5f);
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.active); /* a card fade does not hide the fixed frame */
    PF(F.owner + 526048 + 84, 0);
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.client && !g_box.active); /* a dismissed hover */
    PF(F.owner + 526048 + 84, 1);
    PF(F.owner + 280528 + 156, 710);
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.y == 710);
    PF(F.owner + 280528 + 84, .5f);
    CHECK_EQ(Anchor(KYC_SCREEN_MAP), 0); /* the planet frame must be fully visible */
    PF(F.owner + 280528 + 84, 1);
    P32(F.manager + 25224, 0);
    CHECK_EQ(Anchor(KYC_SCREEN_MAP), 0);
    /* the hidden fixture: a dismissed hover with a cached descriptor */
    fake_setup();
    Loaded();
    memset(&F, 0, sizeof F);
    Presentation("hidden");
    CHECK(Anchor(KYC_SCREEN_MAP) == 1 && g_box.client && !g_box.active);
}

/* ---- the panel (test_panel.lua) ---------------------------------------------------------------------------------------- */

static KycModel g_model;

/* model.make over roster.compute for a mission, as test_panel.lua's report(). */
static const KycModel* Model(int faction, KycTags tags, int difficulty, int screen)
{
    static KycSnapshot snap;
    static KycReport report;
    memset(&snap, 0, sizeof snap);
    snap.d.key.faction = (uint8_t)faction;
    snap.d.key.difficulty = (uint8_t)difficulty;
    size_t used = 0;
    for (int i = 0; i < tags.count; i++)
        used += (size_t)snprintf(snap.d.key.text + used, sizeof snap.d.key.text - used, "%s%u", i ? "," : "", tags.tag[i]);
    snprintf(snap.d.key.text + used, sizeof snap.d.key.text - used, "@%d", difficulty);
    snap.d.screen = screen;
    snap.tag_count = tags.count;
    memcpy(snap.tags, tags.tag, sizeof tags.tag);
    kyc_error_clear();
    CHECK(kyc_roster_compute(faction, difficulty, &tags, NULL, NULL, &report));
    CHECK(kyc_model_make(fake_component(0), &snap, &report, &g_model));
    return &g_model;
}
#define MODEL(faction, difficulty, ...) Model(faction, Tags(sizeof((int[]){__VA_ARGS__}) / sizeof(int), (int[]){__VA_ARGS__}), difficulty, KYC_SCREEN_MAP)

/* test_panel.lua's anchor(): the native frame at its place for the resolution. */
static KycAnchor PanelAnchor(double frame_height, int screen)
{
    double s = fmin(fg.width / 1920, fg.height / 1080), h = frame_height * s;
    KycAnchor a = {(fg.width - fmin(fg.width, fg.height * 16 / 9)) / 2 + 54 * s, fg.height - 139 * s - h, 533 * s, h, s, 0, 0,
        FONT, MATERIAL, ATLAS, screen};
    return a;
}

static const FgText* DrawnText(KycRef id) { return &fg.texts[id - 1]; }

/* Every non-empty drawn text, joined. */
static const char* VisibleText(void)
{
    static char all[16384];
    size_t used = 0;
    const KycPanelView* v = View();
    all[0] = 0;
    for (int i = 0; i < v->texts; i++)
    {
        const FgText* t = DrawnText(v->text_ids[i]);
        if (t->length == 0 || used + t->length + 2 > sizeof all) continue;
        memcpy(all + used, t->text, t->length);
        used += t->length;
        all[used++] = ' ';
        all[used] = 0;
    }
    return all;
}

static int ItemIs(const KycItem* item, const char* text)
{
    return item->length == strlen(text) && memcmp(View()->plan->text + item->at, text, item->length) == 0;
}

/* The enemy names the drawn plan lists, and the "and N more" count (list lines rejoined: a name can wrap). */
static int PlanNames(char names[][64], int capacity, int* more)
{
    static char list[8192];
    const KycPlan* plan = View()->plan;
    int n = 0, section = 0;
    size_t used = 0;
    *more = 0;
    for (int i = 0; i < plan->count; i++)
    {
        const KycItem* item = &plan->items[i];
        if (item->kind != KYC_ITEM_TEXT) continue;
        if (ItemIs(item, "LARGE ENEMIES")) section = 1;
        else if (ItemIs(item, "SMALL AND MEDIUM ENEMIES")) section = 2;
        else if (item->role == KYC_ROLE_BODY && section == 1 && n < capacity)
            snprintf(names[n++], 64, "%.*s", item->length, plan->text + item->at);
        else if (item->role == KYC_ROLE_BODY && section != 0)
        {
            if (used > 0) list[used++] = ' ';
            memcpy(list + used, plan->text + item->at, item->length);
            used += item->length;
        }
    }
    memcpy(list + used, ", ", 3);
    for (char* part = list; *part;)
    {
        char* end = strstr(part, ", ");
        if (end == NULL) break;
        *end = 0;
        if (sscanf(part, "and %d more", more) != 1 && *part && n < capacity) snprintf(names[n++], 64, "%s", part);
        part = end + 2;
    }
    return n;
}

/* Every enemy of the model is named in the drawn plan, or counted in "and N more". */
static int EveryEnemy(const KycModel* m, int* more)
{
    char names[160][64];
    int n = PlanNames(names, 160, more), missing = 0;
    for (int e = 0; e < m->large_count + m->small_count; e++)
    {
        const char* name = e < m->large_count ? m->large[e] : m->small[e - m->large_count];
        int found = 0;
        for (int i = 0; i < n && !found; i++) found = strcmp(names[i], name) == 0;
        missing += !found;
    }
    return missing == *more;
}

/* Everything hangs below the native panel, above the prompt row, on the layers above the squad list. */
static int BelowRegion(const KycAnchor* a)
{
    const KycPanelView* v = View();
    double s = a->scale;
    int ok = 1;
    for (int i = 0; i < v->rects; i++)
    {
        const KycBox* r = &fg.rects[v->rect_ids[i] - 1];
        if (!(r->w > 0)) continue;
        ok &= r->z > 1000 && r->z <= 1023;
        ok &= r->x >= a->x - .001 && r->x + r->w <= a->x + a->w + .001;
        ok &= r->y >= KYC_BOTTOM * s - .001 && r->y + r->h <= a->y + KYC_BORDER * s + .001;
    }
    KycRef scrolling = v->has_scroll ? v->scroll->id : 0;
    for (int i = 0; i < v->texts; i++)
    {
        const FgText* t = DrawnText(v->text_ids[i]);
        if (t->length == 0) continue;
        double left = a->x, right = a->x + a->w - KYC_PAD * s + 1;
        if (v->text_ids[i] == scrolling) { left = a->x + KYC_INSET * s - .001; right = a->x + a->w - KYC_INSET * s + .001; }
        ok &= t->z > 1000 && t->z <= 1023;
        ok &= t->x >= left && t->x + Span(t->text, t->length, t->size) <= right;
        ok &= t->y >= KYC_BOTTOM * s && t->y + t->size <= a->y;
    }
    return ok;
}

/* The filled ticks of each meter row, in drawing order; 1 when they are the model's. Ticks sit on whole pixels with
 * identical widths and gaps, and each meter ends at the column's right edge. */
static int Meters(const KycModel* m, const KycAnchor* a)
{
    const KycPanelView* v = View();
    double tick, gap, right = a->x + a->w - KYC_PAD * a->scale;
    kyc_tick_pixels(a->scale, &tick, &gap);
    int row = 0, in_row = 0, filled = 0, ok = 1;
    double first_x = 0, first_y = 0, first_h = 0;
    for (int i = 0; i < v->rects; i++)
    {
        const KycBox* r = &fg.rects[v->rect_ids[i] - 1];
        if (!(r->w > 0) || r->z != KYC_LAYER_CONTENT) continue;
        if (in_row == 0) { first_x = r->x; first_y = r->y; first_h = r->h; }
        ok &= r->x == floor(r->x) && r->y == floor(r->y) && r->h == floor(r->h) && r->w == tick && r->h == first_h &&
            r->y == first_y && r->x == first_x + in_row * (tick + gap);
        filled += fg.rect_colours[v->rect_ids[i] - 1].r == 240;
        if (++in_row == KYC_TICKS)
        {
            ok &= fabs(r->x + tick - right) <= .5 && row < m->large_count && filled == m->ticks[row];
            row++;
            in_row = filled = 0;
        }
    }
    return ok && in_row == 0 && row == m->large_count;
}

/* Every large-enemy name ends before its meter. */
static int ClearOfMeters(const KycPlan* plan, double s)
{
    for (int i = 1; i < plan->count; i++)
    {
        const KycItem* meter = &plan->items[i], *name = &plan->items[i - 1];
        if (meter->kind != KYC_ITEM_METER) continue;
        if (name->kind != KYC_ITEM_TEXT || Span(plan->text + name->at, name->length, name->size) > meter->x - 2 * KYC_GAP * s + .001)
            return 0;
    }
    return 1;
}

static const int kCases[15][6] = {{3, 8, 2, 15, 22}, {3, 8, 1, 18}, {3, 10, 2, 15, 19}, {3, 10, 2, 17, 20}, {3, 3, 1, 14},
    {2, 10, 1, 1}, {2, 9, 3, 6, 11, 23}, {2, 8, 3, 5, 9, 11}, {2, 8, 2, 3, 8}, {2, 10, 2, 2, 10}, {2, 1, 0}, {4, 8, 1, 27},
    {4, 8, 1, 26}, {4, 8, 1, 29}, {4, 8, 1, 28}};

static const KycModel* CaseModel(int i)
{
    int tags[3] = {0, 0, 0};
    for (int k = 0; k < kCases[i][2]; k++) tags[k] = kCases[i][3 + k];
    return Model(kCases[i][0], Tags(kCases[i][2], tags), kCases[i][1], KYC_SCREEN_MAP);
}

/* One resolution and frame height: every case drawn below the native panel, every enemy named, the meters right. */
static void PanelCases(double frame_height)
{
    KycAnchor a = PanelAnchor(frame_height, KYC_SCREEN_MAP);
    CHECK(kyc_panel_clear());
    for (int i = 0; i < 15; i++)
    {
        const KycModel* m = CaseModel(i);
        int more;
        CHECK_EQ(kyc_panel_show(m, 0, &a), 1);
        CHECK(!View()->place.side);
        CHECK(BelowRegion(&a));
        const char* shown = VisibleText();
        CHECK(strstr(shown, "FORECAST // INTEL AND RECON") != NULL && strstr(shown, "Possible encounters.") != NULL);
        CHECK(EveryEnemy(m, &more) && more == 0);
        CHECK(Meters(m, &a));
        CHECK(ClearOfMeters(View()->plan, a.scale));
    }
    CHECK_EQ(fg.outside, 0);
    CHECK_EQ(fg.uninked + fg.ink_wrong + fg.wrong_world, 0);
    /* static forecasts make no GUI call but the per-frame checks; identical content does not redraw */
    const KycModel* m = MODEL(3, 8, 15, 22);
    CHECK_EQ(kyc_panel_show(m, 0, &a), 1);
    ResetCalls();
    for (int i = 0; i < 120; i++) CHECK_EQ(kyc_panel_show(m, 1.0 / 60, &a), 1);
    CHECK(OnlyCalls((const int[]){C_MAIN, 120, C_WORLDS, 120, C_RESOLUTION, 120, -1}));
    m = MODEL(3, 8, 22, 15);
    ResetCalls();
    CHECK_EQ(kyc_panel_show(m, 0, &a), 1);
    CHECK(OnlyCalls((const int[]){C_MAIN, 1, C_WORLDS, 1, C_RESOLUTION, 1, -1}));
    /* pending keeps the panel and drops the enemy text, on the same GUI */
    KycRef gui = View()->gui;
    CHECK_EQ(kyc_panel_suspend(&a), 1);
    CHECK(View()->gui == gui && strstr(VisibleText(), "FORECAST") != NULL && strstr(VisibleText(), "War Striders") == NULL);
    CHECK_EQ(kyc_panel_show(MODEL(3, 8, 15, 22), 0, &a), 1);
    CHECK(strstr(VisibleText(), "War Striders") != NULL && View()->gui == gui);
    /* native movement redraws without measuring again */
    ResetCalls();
    a.x += 3;
    CHECK_EQ(kyc_panel_show(&g_model, 0, &a), 1);
    CHECK(BelowRegion(&a) && Calls(C_EXTENTS) == 0 && Calls(C_UPDATE_RECT) > 0);
    CHECK(kyc_panel_clear());
    CHECK(View()->gui == 0 && kyc_panel_suspend(&a) == 0);
}

static void PanelResolutions(void)
{
    Loaded();
    static const double kResolutions[6][2] = {{1280, 720}, {1920, 1080}, {2560, 1440}, {3440, 1440}, {5120, 1440}, {1280, 1024}};
    for (int r = 0; r < 6; r++)
    {
        FakeGui(kResolutions[r][0], kResolutions[r][1]);
        kyc_panel_reset();
        PanelCases(489);
        PanelCases(371);
    }
    kyc_gui_use(NULL);
}

static void PanelPlacement(void)
{
    Loaded();
    FakeGui(1920, 1080);
    kyc_panel_reset();
    /* the briefing: attached below the native panel, sharing its bottom border */
    KycAnchor b = PanelAnchor(360, KYC_SCREEN_BRIEFING);
    const KycModel* m = Model(3, Tags(2, (int[]){15, 22}), 8, KYC_SCREEN_BRIEFING);
    CHECK(kyc_panel_show(m, 0, &b) == 1 && !View()->place.side);
    KycPlace place = View()->place;
    CHECK(fabs(place.y + place.h - (b.y + KYC_BORDER * b.scale)) < .001);
    /* the native frame's dark gap: the body 7 units in, 4 inside the 3-unit gold outline */
    const KycBox* body = NULL;
    int outline = 0;
    for (int i = 0; i < View()->rects; i++)
    {
        const KycBox* r = &fg.rects[View()->rect_ids[i] - 1];
        KycColour c = fg.rect_colours[View()->rect_ids[i] - 1];
        if (r->w > 0 && r->z == KYC_LAYER_BODY) body = r;
        if (r->w > 0 && r->z == KYC_LAYER_BORDER && c.r == 255 && c.g == 185)
        {
            outline++;
            CHECK(fabs(fmin(r->w, r->h) - 3 * b.scale) < 1e-9);
        }
    }
    CHECK(outline == 4 && body != NULL);
    if (body != NULL)
        CHECK(fabs(body->x - (place.x + 7 * b.scale)) < .001 && fabs(body->y - (place.y + 7 * b.scale)) < .001 &&
            fabs(body->w - (place.w - 14 * b.scale)) < .001 && fabs(body->h - (place.h - 14 * b.scale)) < .001);
    for (int i = 0; i < m->large_count; i++) CHECK(strstr(VisibleText(), m->large[i]) != NULL);
    for (int i = 0; i < m->small_count; i++) CHECK(strstr(VisibleText(), m->small[i]) != NULL);
    b.y = 40 * b.scale;
    CHECK(kyc_panel_show(m, 0, &b) == 1 && View()->place.side); /* no room below: beside the native frame */
    KycAnchor low = PanelAnchor(489, KYC_SCREEN_MAP);
    low.y = 90 * low.scale;
    CHECK(kyc_panel_show(MODEL(2, 10, 1), 0, &low) == 1 && View()->place.side);
    /* headlines with several modifiers stay inside the frame */
    FakeGui(1280, 720);
    kyc_panel_reset();
    KycAnchor a = PanelAnchor(371, KYC_SCREEN_MAP);
    m = MODEL(2, 9, 6, 11, 12, 23, 31);
    CHECK(strcmp(m->headline, "DRAGONROACH ACTIVITY // ROVING SHRIEKERS // HIVE WORLD // HORDE // BUG NURSERY") == 0);
    CHECK_EQ(kyc_panel_show(m, 0, &a), 1);
    CHECK(BelowRegion(&a));
    /* the UI world can change or disappear */
    a = PanelAnchor(489, KYC_SCREEN_MAP);
    CHECK_EQ(kyc_panel_show(MODEL(2, 10, 1), 0, &a), 1);
    fg.worlds[1] = 9;
    fg.ui = 9;
    CHECK_EQ(kyc_panel_show(MODEL(2, 10, 3), 0, &a), 1);
    CHECK(strstr(VisibleText(), "Pouncers") != NULL && View()->world == 9);
    fg.world_count = 1;
    int destroyed = fg.destroyed;
    CHECK(kyc_panel_show(MODEL(2, 10, 3), 0, &a) == 0 && !Up());
    CHECK(fg.destroyed == destroyed && fg.wrong_world == 0); /* a GUI whose world is gone is dropped, not destroyed */
    /* after a world change, a clear still removes the GUI made in the new world (the Lua kept it) */
    fg.world_count = 2;
    fg.worlds[1] = 2;
    fg.ui = 2;
    CHECK_EQ(kyc_panel_show(MODEL(2, 10, 1), 0, &a), 1);
    fg.worlds[1] = fg.ui = 8;
    CHECK_EQ(kyc_panel_show(MODEL(2, 10, 1), 0, &a), 1);
    destroyed = fg.destroyed;
    CHECK(kyc_panel_clear() && !Up() && fg.destroyed == destroyed + 1);
    kyc_gui_use(NULL);
}

static int MeasureSpanSized(void* context, const char* text, size_t length, double size, double* width)
{
    *width = Span(text, length, size);
    return 1;
}

static void PanelPlans(void)
{
    Loaded();
    static KycPlan plan;
    int fits;
    const KycModel* big = MODEL(3, 8, 15, 22);
    KycPlanArgs args = {big, MeasureSpanSized, NULL, 480, 150, 1};
    CHECK(kyc_fit(&args, 0, &plan, &fits) && !fits); /* below the panel nothing is cut */
    CHECK(kyc_fit(&args, 1, &plan, &fits) && fits && plan.size == 12);
    int cut_lines = 0;
    for (int i = 0; i < plan.count; i++)
    {
        const KycItem* item = &plan.items[i];
        char text[256];
        int count;
        snprintf(text, sizeof text, "%.*s", item->length, plan.text + item->at);
        const char* and = strstr(text, "and ");
        cut_lines += item->kind == KYC_ITEM_TEXT && and != NULL && sscanf(and, "and %d more", &count) == 1;
    }
    CHECK_EQ(cut_lines, 1); /* cut lists end with one "and N more" line */
    args.limit = 2000;
    CHECK(kyc_fit(&args, 0, &plan, &fits) && fits && plan.size == kKycSizes[0]);
    /* balanced padding: the plan ends as far below the footer's baseline as the label's capitals start below the top */
    const KycItem* footer = &plan.items[plan.count - 1];
    CHECK(footer->kind == KYC_ITEM_TEXT && footer->length == strlen(big->footer));
    CHECK(fabs(plan.height - (footer->d + KYC_TITLE * (1 - KYC_CAP))) < 1e-9);
    /* scroll timing: hold, move at the set speed (scaled with the UI), hold, restart */
    double period, expected = KYC_SCROLL_HOLD + 100 / KYC_SCROLL_SPEED + KYC_SCROLL_END_HOLD;
    CHECK(kyc_scroll_offset(0, 100, 1, &period) == 0 && period == expected);
    CHECK(kyc_scroll_offset(KYC_SCROLL_HOLD - .01, 100, 1, &period) == 0);
    CHECK(fabs(kyc_scroll_offset(KYC_SCROLL_HOLD + 1, 100, 1, &period) - KYC_SCROLL_SPEED) < 1e-9);
    CHECK(fabs(kyc_scroll_offset(KYC_SCROLL_HOLD + 1, 100, 2, &period) - 2 * KYC_SCROLL_SPEED) < 1e-9);
    CHECK(kyc_scroll_offset(KYC_SCROLL_HOLD + 100 / KYC_SCROLL_SPEED + .01, 100, 1, &period) == 100);
    CHECK(kyc_scroll_offset(expected + .5, 100, 1, &period) == 0);
    /* the window: whole glyphs inside the span widened by the margin; continuing gives a fresh scan's answer */
    const double edges[12] = {0, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100};
    int first = 0, last = 0;
    kyc_scroll_window(edges, 10, 0, 35, 5, &first, &last);
    CHECK(first == 1 && last == 5);
    kyc_scroll_window(edges, 10, 12, 35, 5, &first, &last);
    CHECK(first == 2 && last == 6);
    int f2 = 0, l2 = 0;
    kyc_scroll_window(edges, 10, 12, 35, 5, &f2, &l2);
    CHECK(l2 == 6);
    kyc_scroll_window(edges, 10, 65, 35, 5, &first, &last);
    CHECK(first == 7 && last == 11);
}

static const FgText* ScrollText(void) { return DrawnText(View()->scroll->id); }
static double Origin(void) { return ScrollText()->x - View()->scroll->edge[View()->scroll->first]; }

static void PanelScroll(void)
{
    Loaded();
    FakeGui(2560, 1440);
    kyc_panel_reset();
    KycAnchor a = PanelAnchor(489, KYC_SCREEN_MAP);
    const KycModel* m = MODEL(2, 9, 6, 11, 12, 23, 31);
    CHECK_EQ(kyc_panel_show(m, 0, &a), 1);
    int heads = 0;
    const KycPlan* plan = View()->plan;
    for (int i = 0; i < plan->count; i++)
        if (plan->items[i].length == strlen(m->headline) && memcmp(plan->text + plan->items[i].at, m->headline, plan->items[i].length) == 0)
        {
            heads++;
            CHECK(plan->items[i].kind == KYC_ITEM_SCROLL && plan->items[i].size == KYC_TITLE * a.scale && plan->items[i].travel > 0);
        }
    CHECK_EQ(heads, 1); /* the headline is one line */
    int masks = 0;
    for (int i = 0; i < View()->rects; i++)
    {
        const KycBox* r = &fg.rects[View()->rect_ids[i] - 1];
        KycColour c = fg.rect_colours[View()->rect_ids[i] - 1];
        if (r->z != KYC_LAYER_MASK || !(r->w > 0)) continue;
        masks++;
        CHECK(c.r == kKycBody.r && c.g == kKycBody.g && c.b == kKycBody.b && c.a == 255);
    }
    CHECK_EQ(masks, 2);
    CHECK(View()->has_scroll && strncmp(ScrollText()->text, "DRAGONROACH", 11) == 0);
    CHECK(fabs(Origin() - (a.x + KYC_PAD * a.scale)) < .001);
    CHECK(BelowRegion(&a));
    ResetCalls();
    for (int i = 0; i < 100; i++) kyc_panel_show(m, 1.0 / 60, &a);
    CHECK(Calls(C_UPDATE_TEXT) + Calls(C_TEXT) + Calls(C_RECT) + Calls(C_UPDATE_RECT) == 0); /* holding at the start */
    for (int i = 0; i < 5; i++) kyc_panel_show(m, .1, &a);
    ResetCalls();
    double o = Origin();
    for (int i = 0; i < 60; i++)
    {
        kyc_panel_show(m, 1.0 / 60, &a);
        CHECK(BelowRegion(&a));
    }
    CHECK(Calls(C_UPDATE_TEXT) == 60 && Calls(C_EXTENTS) == 0); /* one text per frame; scrolling never measures */
    CHECK(Origin() < o);
    int guard = 0;
    while (View()->scroll->offset < View()->scroll->travel && guard++ < 1000)
    {
        kyc_panel_show(m, .1, &a);
        CHECK(BelowRegion(&a));
    }
    size_t n = ScrollText()->length;
    CHECK(n >= 11 && memcmp(ScrollText()->text + n - 11, "BUG NURSERY", 11) == 0);
    ResetCalls();
    kyc_panel_show(m, .1, &a);
    CHECK_EQ(Calls(C_UPDATE_TEXT), 0); /* holding at the end */
    guard = 0;
    while (View()->scroll->offset != 0 && guard++ < 100) kyc_panel_show(m, .1, &a);
    CHECK(strncmp(ScrollText()->text, "DRAGONROACH", 11) == 0); /* back to the start */
    /* moving the native panel redraws without measuring and keeps the cycle */
    double t = View()->scroll->time;
    ResetCalls();
    a.x += 3;
    kyc_panel_show(m, 0, &a);
    CHECK(BelowRegion(&a) && View()->scroll->time == t && Calls(C_EXTENTS) == 0);
    /* short headlines neither scroll nor mask */
    kyc_panel_show(MODEL(3, 8, 15, 22), 0, &a);
    CHECK(!View()->has_scroll);
    for (int i = 0; i < View()->rects; i++)
    {
        const KycBox* r = &fg.rects[View()->rect_ids[i] - 1];
        CHECK(r->z != KYC_LAYER_MASK || r->w == 0);
    }
    CHECK(kyc_panel_clear());
    /* only the first non-main world draws on the war table: the one GUI goes there, and clear destroys it */
    fg.worlds[0] = 20;
    fg.worlds[1] = 21;
    fg.worlds[2] = 22;
    fg.world_count = 3;
    fg.main = 20;
    fg.ui = 21;
    int destroyed = fg.destroyed;
    CHECK(kyc_panel_show(MODEL(2, 10, 1), 0, &a) == 1 && View()->world == 21 && fg.wrong_world == 0);
    CHECK(kyc_panel_clear() && fg.destroyed == destroyed + 1);
    kyc_gui_use(NULL);
}

/* ---- the component over the fake game (test_budget.lua, test_panel_budget.lua, test_idle.lua, test_pending.lua) ---- */

static const int kUp[] = {C_MAIN, 1, C_WORLDS, 1, C_RESOLUTION, 1, -1};
static const int kNone[] = {-1};

/* One frame: its API reads and its engine calls, pinned. */
static void Pinned(const char* label, float dt, uint32_t reads, const int* engine)
{
    ResetCalls();
    uint32_t n = FrameReads(dt);
    int same = OnlyCalls(engine);
    if (n != reads || !same) printf("  %s: %u reads (pinned %u)\n", label, n, reads);
    CHECK_EQ(n, reads);
    CHECK(same);
}

static void SessionStart(int client)
{
    Session(client);
    SessionGui();
    Started();
}

static void BudgetHost(void)
{
    SessionStart(0);
    ShowScreen(0);
    Frames(1, .01f);
    CHECK(!Up() && StatusIs("hidden"));
    Pinned("ship", .01f, 1, kNone);
    ShowScreen(2);
    Pinned("mission", .01f, 1, kNone);
    /* the war table: the hosted mission resolves and is published */
    ShowScreen(15);
    Frames(3, .11f);
    CHECK(ShownKey(F.key) && StatusIs("visible map"));
    uint32_t computed = kyc_roster_computed();
    uint64_t signature = View()->model->signature;
    Pinned("map steady", .01f, 9, kUp);
    Pinned("map refresh", .5f, 43, kUp);
    Pinned("map steady", .01f, 9, kUp);
    CHECK(kyc_roster_computed() == computed && View()->model->signature == signature); /* an unchanged refresh keeps it */
    CHECK(View()->place.x == 512 && fabs(View()->place.w - 533 * 4.0 / 3.0) < .01); /* anchored to the native frame */
    /* waiting for mission data with the panel up: the frame and captions stay, drawn once */
    P32(F.controller + 8, 12346);
    Frames(1, .01f);
    CHECK(Up() && View()->model->pending && StatusIs("waiting for mission data"));
    Pinned("waiting", .01f, 9, kUp);
    P32(F.controller + 8, 12345);
    Frames(1, .01f);
    CHECK(Shown() && StatusIs("visible map"));
    /* a headline wider than the box scrolls: hold, move, hold, reset */
    LongHeadline(1);
    Frames(1, .5f);
    CHECK(View()->has_scroll && View()->scroll->travel > 0);
    Frames(1500, .016f);
    for (int guard = 0; !(View()->scroll->offset == 0 && View()->scroll->time < 1) && guard < 5000; guard++) Frames(1, .016f);
    Pinned("scroll holding", .016f, 9, kUp);
    for (int guard = 0; View()->scroll->offset == 0 && guard < 5000; guard++) Frames(1, .016f);
    Pinned("scroll moving", .016f, 9, (const int[]){C_MAIN, 1, C_WORLDS, 1, C_RESOLUTION, 1, C_UPDATE_TEXT, 1, -1});
    LongHeadline(0);
    /* the briefing: the same mission through the briefing owner */
    ShowScreen(14);
    Frames(3, .11f);
    CHECK(ShownKey(F.key) && StatusIs("visible briefing") && View()->model->screen == KYC_SCREEN_BRIEFING);
    Pinned("briefing steady", .01f, 10, kUp);
    Pinned("briefing refresh", .5f, 44, kUp);
    CHECK(View()->place.x == 512 && fabs(View()->place.y + View()->place.h - (894.1667 + 4)) < .02);
    /* the loadout hides the briefing panel: the first frame destroys the GUI, then nothing */
    P32(F.owner + 8, 1);
    Pinned("hiding", .01f, 3, (const int[]){C_WORLDS, 1, C_DESTROY, 1, -1});
    CHECK(!Up());
    Pinned("loadout", .01f, 3, kNone);
    CHECK_EQ(State()->failures, 0);
    kyc_gui_use(NULL);
}

static void BudgetClient(void)
{
    SessionStart(1);
    ShowScreen(15);
    Frames(3, .11f);
    CHECK(ShownKey(F.key) && StatusIs("visible map"));
    Pinned("client steady", .01f, 21, kUp);
    Pinned("client refresh", .5f, 73, kUp);
    CHECK_EQ(State()->failures, 0);
    kyc_gui_use(NULL);
}

/* The campaign's spawn weights and war effects reach the roster; unchanged inputs never compute it again. */
static void BudgetWeighted(void)
{
    SessionStart(0);
    AddWeights();
    ShowScreen(15);
    Frames(3, .11f);
    CHECK(Shown());
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && ZoneOf(&g_snap.zone, WAR_STRIDER) == 5 && ZoneOf(&g_snap.zone, TANK) == 0.5 &&
        ZoneOf(&g_snap.war, TANK) == 0.25);
    uint32_t computed = kyc_roster_computed();
    uint64_t signature = View()->model->signature;
    Pinned("weighted refresh", .5f, 43, kUp);
    CHECK(kyc_roster_computed() == computed && View()->model->signature == signature);
    /* changed weights reach the roster on the next refresh, and the refresh after an unchanged one does not */
    struct { uintptr_t at; uint32_t value; } kChanges[4] = {{F.globals + 8, 0x3F000000u}, {F.campaign + 304 * 76 + 286952 + 128, 1},
        {F.campaign + 304 * 76 + 286952 + 128, 0}, {F.globals + 80, 0}};
    for (int i = 0; i < 4; i++)
    {
        P32(kChanges[i].at, kChanges[i].value);
        Frames(1, .5f);
        CHECK_EQ(kyc_roster_computed(), computed + (uint32_t)i + 1);
        Frames(1, .5f);
        CHECK_EQ(kyc_roster_computed(), computed + (uint32_t)i + 1);
    }
    CHECK(Sample(KYC_SCREEN_MAP) == 1 && g_snap.zone.count == 0 && g_snap.war.count == 0);
    CHECK_EQ(State()->failures, 0);
    kyc_gui_use(NULL);
}

/* The idle gate: 1 read per quiet frame; the full check every 30th frame (1 read and a plain load). */
static void IdleGate(void)
{
    SessionStart(0);
    ShowScreen(0);
    Frames(1, .016f);
    for (int i = 1; i <= 90; i++) CHECK_EQ(FrameReads(.016f), 1);
    ShowScreen(2);
    for (int i = 1; i <= 60; i++) CHECK_EQ(FrameReads(.016f), 1);
    /* the frame the war table opens: the gate's read sees it, then the full frame runs */
    ShowScreen(0);
    Frames(10, .016f);
    ShowScreen(15);
    CHECK_EQ(FrameReads(.11f), 44);
    CHECK(Shown());
    /* the one intended late case: a UI manager replaced while its old stack still reads as neither screen is seen at the
     * next full check, up to 30 frames late */
    ShowScreen(0);
    Frames(40, .016f);
    uintptr_t other = Heap(0x4300);
    P32(other + 0x429C, 15);
    P32(other + 0x429C + 20, 1);
    P64(Game(0x347CE28), other);
    int n = 0;
    while (!StatusIs("visible") && n <= 40) { Frames(1, .11f); n++; }
    CHECK(n >= 1 && n <= 30);
    /* an unreadable screen stack ends the gate at once and hides with its reason */
    ShowScreen(0);
    P64(Game(0x347CE28), F.screen);
    Frames(40, .016f);
    P64(Game(0x347CE28), 0x10000);
    Frames(31, .016f);
    CHECK(StatusIs("hidden: Mission data unavailable") && State()->failures == 0);
    P64(Game(0x347CE28), F.screen);
    Frames(1, .016f);
    CHECK(StatusIs("hidden") && !StatusIs("hidden:"));
    kyc_gui_use(NULL);
}

/* Each expected transient state, held: hidden with its reason, never counted, back once it clears. */
typedef struct Condition { const char* reason; int client, screen; void (*set)(void); void (*clear)(void); } Condition;
static void UnreadableStack(void) { P64(Game(0x347CE28), 0x10000); }
static void ReadableStack(void) { P64(Game(0x347CE28), F.screen); }
static void NoRoot(void) { P64(Game(0x3326340), 0); }
static void Root(void) { P64(Game(0x3326340), F.root); }
static void NoFaction(void) { P8(F.board + 0x4168D0 + 8, 0); }
static void Faction(void) { P8(F.board + 0x4168D0 + 8, 2); }
static void NoIndex(void) { P32(F.board + 1548960, 120); }
static void Index(void) { P32(F.board + 1548960, 0); }
static void Inactive(void) { P8(F.board + 1012352 + 52, 0); }
static void Active(void) { P8(F.board + 1012352 + 52, 1); }
static void NoBriefings(void) { P32(F.manager + 26184, 0); }
static void Briefings(void) { P32(F.manager + 26184, 1); }
static void OtherOwner(void) { P32(F.manager + 26192 + 8, 236); }
static void Owner(void) { P32(F.manager + 26192 + 8, 235); }
static void NoOwnerPointer(void) { P64(F.manager + 26192, 0); }
static void OwnerPointer(void) { P64(F.manager + 26192, F.briefing); }
static void UnreadablePanel(void) { P64(F.manager + 25224 + 8, 0x10000); }
static void ReadablePanel(void) { P64(F.manager + 25224 + 8, F.owner); }
static void NoManager(void) { P64(Game(0x3326E68), 0); }
static void Manager(void) { P64(Game(0x3326E68), F.manager); }
static void NoFont(void) { P64(Game(0x3772268), 0); }
static void Font(void) { P64(Game(0x3772268), FONT); }
static void NoRemote(void) { P64(Game(0x347CE80), 0); }
static void Remote(void) { P64(Game(0x347CE80), F.remote); }
static void UnreadableDescriptor(void) { fake_hole(F.board + 0x4168D0, 200); }
static void UnreadableJoinable(void) { fake_hole(F.board + 2044424, 20); }

#define HOLD 2000

static void Held(const Condition* c)
{
    ShowScreen((uint32_t)(c->screen ? c->screen : 15));
    Frames(3, .11f);
    CHECK(Shown() && StatusIs("visible"));
    c->set();
    uint32_t pending = State()->pending;
    Frames(HOLD, .016f);
    char status[160];
    snprintf(status, sizeof status, "hidden: %s", c->reason);
    if (strcmp(State()->status, status) != 0) printf("  %s: status \"%s\"\n", c->reason, State()->status);
    CHECK(strcmp(State()->status, status) == 0);
    CHECK(State()->pending == pending + HOLD && State()->burst_errors == 0 && State()->failures == 0 && !Up());
    if (c->clear == NULL) return;
    c->clear();
    Frames(3, .11f);
    CHECK(Shown() && StatusIs("visible"));
}

static void TransientStates(void)
{
    static const Condition kHost[] = {
        {"Mission data unavailable", 0, 0, UnreadableStack, ReadableStack},
        {"Mission pointer unavailable", 0, 0, NoRoot, Root},
        {"Mission descriptor not ready", 0, 0, NoFaction, Faction},
        {"No highlighted mission", 0, 0, NoIndex, Index},
        {"No highlighted mission", 0, 0, Inactive, Active},
        {"Briefing descriptor unavailable", 0, 14, NoBriefings, Briefings},
        {"Briefing owner unavailable", 0, 14, OtherOwner, Owner},
        {"Briefing owner unavailable", 0, 14, NoOwnerPointer, OwnerPointer},
        {"Presentation data unavailable", 0, 0, UnreadablePanel, ReadablePanel},
        {"Presentation owner unavailable", 0, 0, NoManager, Manager},
        {"Native font is not ready", 0, 0, NoFont, Font},
        {"Mission data unavailable", 0, 0, UnreadableDescriptor, NULL}, /* the fake's holes cannot be closed again */
    };
    SessionStart(0);
    for (size_t i = 0; i < sizeof kHost / sizeof kHost[0]; i++) Held(&kHost[i]);
    kyc_gui_use(NULL);
}

static void TransientStatesClient(void)
{
    static const Condition kClient[] = {
        {"Mission pointer unavailable", 1, 0, NoRemote, Remote},
        {"Mission data unavailable", 1, 0, UnreadableJoinable, NULL},
    };
    SessionStart(1);
    for (size_t i = 0; i < sizeof kClient / sizeof kClient[0]; i++) Held(&kClient[i]);
    kyc_gui_use(NULL);
}

/* A genuine error still counts: a descriptor that names an unknown mission type; the 8th in a burst stops it. */
static void GenuineErrorStops(void)
{
    SessionStart(0);
    ShowScreen(15);
    Frames(3, .11f);
    CHECK(Shown());
    P16(F.board + 0x4168D0 + 26, 300);
    Frames(7, .016f);
    CHECK(State()->burst_errors == 7 && strstr(State()->status, "Unknown mission type") != NULL && !Up());
    Frames(1, .016f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(strcmp(vpm_status(fake_component(0)), "disabled: stopped after: 8 errors: Unknown mission type") == 0);
    CHECK_LOG("[Know Your Constellation] error: Unknown mission type");
    CHECK_LOG("[Know Your Constellation] disabled: stopped after: 8 errors: Unknown mission type");
    uint32_t frames = State()->frames;
    Frames(50, .016f);
    CHECK_EQ(State()->frames, frames);
    kyc_gui_use(NULL);
}

/* No Gui route (kyc_gui.c's none): the panel stays off, every forecast is computed and logged, nothing is drawn. */
static void PanelOff(void)
{
    kyc_gui_use(NULL);
    Session(0);
    Started();
    CHECK_LOG("[Know Your Constellation] panel off: no engine Gui route on HellForge yet");
    CHECK_LOG("[Know Your Constellation] ready");
    ShowScreen(15);
    Frames(3, .11f);
    char status[160], line[200];
    snprintf(status, sizeof status, "panel off: map %s composition rules resolved", F.key);
    CHECK(strcmp(State()->status, status) == 0);
    CHECK(strncmp(vpm_status(fake_component(0)), "panel off (no engine Gui route yet); ", 37) == 0);
    snprintf(line, sizeof line, "[Know Your Constellation] forecast map %s: BALANCED TERMINIDS; large:", F.key);
    CHECK_LOG(line);
    snprintf(line, sizeof line, "[Know Your Constellation] forecast map %s small: ", F.key);
    CHECK_LOG(line);
    CHECK(!Up());
    uint32_t before = Reads();
    Frames(1, .01f);
    CHECK_EQ(Reads() - before, 9); /* the map's steady reads; the panel itself costs nothing */
    /* a refresh of the same mission logs nothing more */
    fake_log_clear();
    fake_counts_reset();
    Frames(4, .5f);
    CHECK_NO_LOG("forecast");
    CHECK_EQ(fake_counts().log, 0);
}

/* ---- the frame over fake readers (test_install.lua, test_update_chain.lua, test_panel.lua's waits) ---------------- */

static struct
{
    int screen, valid, ready, complete, matches, descriptor_pending, sample_pending, client, active, hovered;
    int faction, difficulty, samples;
    KycTags tags;
    char key[64];
    const char* raise;           /* screen() fails with this */
    const char* wait;            /* screen() is pending with this */
    void (*on_sample)(KycSnapshot*);
    int custom_anchor;
    KycAnchor anchor;
} fr;

static void FillKey(KycKey* key, const char* text)
{
    memset(key, 0, sizeof *key);
    snprintf(key->text, sizeof key->text, "%s", text);
    key->faction = (uint8_t)fr.faction;
    key->difficulty = (uint8_t)fr.difficulty;
}

static int FrScreen(int* out)
{
    if (fr.raise != NULL) return kyc_fail("%s", fr.raise);
    if (fr.wait != NULL) return kyc_pending(fr.wait);
    *out = fr.screen;
    return 1;
}

static int FrQuiet(void) { return fr.screen == KYC_SCREEN_NONE; }

static int FrDescriptor(int screen, KycDescriptor* out, int* found, int* hovered)
{
    if (!fr.valid) return kyc_fail("Unavailable");
    *hovered = fr.hovered;
    *found = 0;
    if (fr.descriptor_pending) return 1;
    memset(out, 0, sizeof *out);
    FillKey(&out->key, fr.key);
    out->screen = screen;
    out->controller_matches = fr.matches;
    *found = 1;
    return 1;
}

static int FrSample(int screen, KycSnapshot* out, int* found)
{
    fr.samples++;
    memset(out, 0, sizeof *out);
    FillKey(&out->d.key, fr.key);
    out->d.screen = screen;
    out->d.controller_matches = fr.matches;
    out->tag_count = fr.tags.count;
    memcpy(out->tags, fr.tags.tag, sizeof out->tags);
    out->complete = fr.complete;
    if (fr.on_sample != NULL) fr.on_sample(out);
    *found = !fr.sample_pending;
    return 1;
}

static int FrAnchor(int screen, KycAnchor* out, int* found)
{
    *found = fr.ready;
    if (!fr.ready) return 1;
    *out = fr.custom_anchor ? fr.anchor : PanelAnchor(489, screen);
    out->screen = screen;
    out->client = fr.client;
    out->active = fr.active;
    return 1;
}

static const KycReaders kFakeReaders = {FrScreen, FrQuiet, FrDescriptor, FrSample, FrAnchor};

/* The component over fake readers and the fake Gui at 2560 x 1440. */
static void FakeWorld(int faction, int difficulty, KycTags tags)
{
    memset(&fr, 0, sizeof fr);
    fr.valid = fr.ready = fr.complete = fr.matches = fr.active = 1;
    fr.hovered = KYC_HOVER_UNKNOWN;
    fr.faction = faction;
    fr.difficulty = difficulty;
    fr.tags = tags;
    snprintf(fr.key, sizeof fr.key, "first");
    FakeGui(2560, 1440);
    kyc_use_readers(&kFakeReaders);
    Started();
}

static void Leave(void)
{
    kyc_use_readers(NULL);
    kyc_gui_use(NULL);
}

static void SetKey(const char* key) { snprintf(fr.key, sizeof fr.key, "%s", key); }
static void KeyAfterRead(KycSnapshot* s) { SetKey("after-read"); }
static void NewerRead(KycSnapshot* s) { SetKey("newer-read"); snprintf(s->d.key.text, sizeof s->d.key.text, "newer-read"); }
static void ControllerChanged(KycSnapshot* s) { fr.matches = 0; }
static void MenuClosed(KycSnapshot* s) { fr.screen = KYC_SCREEN_NONE; }
static void RemoteRace(KycSnapshot* s) { fr.descriptor_pending = 1; }
static void UnhoverDuringRead(KycSnapshot* s) { fr.hovered = 0; fr.descriptor_pending = 1; }

static void Publication(void)
{
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    Frames(1, .1f);
    CHECK(!Up());
    fr.screen = KYC_SCREEN_MAP;
    Frames(1, .1f);
    CHECK(ShownKey("first"));
    int destroyed = fg.destroyed;
    SetKey("second");
    Frames(1, .1f);
    CHECK(State()->has_key && strcmp(State()->key, "second") == 0);
    CHECK_EQ(fg.destroyed, destroyed); /* changing the highlighted mission keeps the panel and its scroll position */
    fr.screen = KYC_SCREEN_BRIEFING;
    Frames(1, .1f);
    CHECK(State()->screen == KYC_SCREEN_BRIEFING && fg.destroyed == destroyed + 1); /* a screen change resets it */
    fr.ready = 0;
    Frames(1, .1f);
    CHECK(!Up() && strcmp(State()->status, "hidden") == 0); /* the loadout or the pod entry */
    fr.ready = 1;
    Frames(1, .1f);
    CHECK(Shown());
    fr.valid = 0;
    Frames(1, .1f);
    CHECK(StatusIs("hidden: Unavailable") && State()->failures == 1);
    fr.valid = 1;
    fr.screen = KYC_SCREEN_NONE;
    Frames(1, .1f);
    CHECK(!Up());
    /* pending data never publishes; the report appears only once complete */
    fr.screen = KYC_SCREEN_MAP;
    SetKey("rapid");
    fr.complete = 0;
    Frames(1, .001f);
    CHECK(!Shown());
    int samples = fr.samples;
    Frames(9, .01f);
    CHECK_EQ(fr.samples, samples); /* pending reads do not run every frame */
    Frames(1, .011f);
    CHECK(fr.samples == samples + 1 && !Shown()); /* they retry after 100 ms */
    fr.complete = 1;
    Frames(1, .101f);
    CHECK(ShownKey("rapid") && View()->model->large_count > 0 && strcmp(View()->model->headline, "BILE BUGS") == 0);
    CHECK(strcmp(View()->model->footer, "Possible encounters. Spawns are not guaranteed.") == 0);
    samples = fr.samples;
    uint32_t computed = kyc_roster_computed();
    Frames(4, .1f);
    CHECK_EQ(fr.samples, samples); /* resolved reports keep the slower refresh */
    Frames(1, .101f);
    CHECK_EQ(fr.samples, samples + 1);
    Frames(6, .501f);
    CHECK(fr.samples >= samples + 6 && kyc_roster_computed() == computed); /* an unchanged mission reuses its roster */
    /* rapid switching keeps the frame while the intel resolves; a mismatched controller triggers no full read */
    destroyed = fg.destroyed;
    static const char* const kSwitch[4] = {"other", "rapid", "other", "rapid"};
    for (int i = 0; i < 4; i++)
    {
        SetKey(kSwitch[i]);
        fr.matches = 0;
        samples = fr.samples;
        Frames(1, .001f);
        CHECK(!Shown() && !State()->complete && Up() && fr.samples == samples);
    }
    CHECK_EQ(fg.destroyed, destroyed);
    fr.matches = 1;
    Frames(1, .001f);
    CHECK(ShownKey("rapid")); /* the controller catching up publishes at once */
    fr.matches = 0;
    Frames(1, .001f);
    CHECK(!Shown());
    fr.matches = 1;
    fr.complete = 0;
    Frames(1, .001f);
    CHECK(!Shown()); /* a matched identity alone cannot authorize an incomplete sample */
    fr.complete = 1;
    Frames(1, .101f);
    CHECK(Shown() && fg.destroyed == destroyed);
    fr.complete = 0;
    Frames(1, .501f);
    CHECK(!Shown()); /* an incomplete refresh hides rather than replaces */
    fr.complete = 1;
    Frames(1, .101f);
    CHECK(Shown());
    Leave();
}

static void SelectionRaces(void)
{
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    fr.screen = KYC_SCREEN_MAP;
    Frames(2, .1f);
    CHECK(Shown());
    /* a complete sample of a superseded selection never appears; the next frame retries */
    SetKey("before-read");
    fr.on_sample = KeyAfterRead;
    Frames(1, .001f);
    CHECK(!Shown());
    fr.on_sample = NULL;
    Frames(1, .001f);
    CHECK(ShownKey("after-read"));
    SetKey("before-newer-read");
    fr.on_sample = NewerRead;
    Frames(1, .001f);
    CHECK(!Shown()); /* a newer sample is never combined with the previous selection's anchor */
    fr.on_sample = NULL;
    Frames(1, .001f);
    CHECK(ShownKey("newer-read"));
    SetKey("controller-changed-during-read");
    fr.on_sample = ControllerChanged;
    Frames(1, .001f);
    CHECK(!Shown());
    fr.on_sample = NULL;
    fr.matches = 1;
    Frames(1, .001f);
    CHECK(ShownKey("controller-changed-during-read"));
    /* hiding the native menu cancels pending publication; there is no timeout fallback */
    SetKey("never-ready");
    fr.complete = 0;
    Frames(1, .001f);
    Frames(20, .101f);
    CHECK(!Shown());
    int samples = fr.samples;
    fr.ready = 0;
    Frames(1, .001f);
    fr.complete = 1;
    Frames(10, .1f);
    CHECK(!Shown() && fr.samples == samples && !Up());
    fr.ready = 1;
    Frames(1, .001f);
    CHECK(ShownKey("never-ready")); /* reopening reads the current selection at once */
    SetKey("screen-change-during-read");
    fr.on_sample = MenuClosed;
    Frames(1, .001f);
    CHECK(!Shown());
    fr.on_sample = NULL;
    /* low difficulties may have one section only */
    fr.screen = KYC_SCREEN_MAP;
    SetKey("low-difficulty");
    fr.difficulty = 2;
    Frames(1, .001f);
    CHECK(ShownKey("low-difficulty") && strcmp(View()->model->headline, "BILE BUGS") == 0);
    CHECK(View()->model->large_count == 0 && View()->model->small_count > 0);
    Leave();
}

static void ClientHovers(void)
{
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    fr.screen = KYC_SCREEN_MAP;
    fr.client = 1;
    fr.hovered = 1;
    Frames(2, .1f);
    CHECK(Shown());
    int destroyed = fg.destroyed;
    uint32_t failures = State()->failures;
    /* loading or expiring remote packets clear the report without destroying the frame */
    fr.descriptor_pending = 1;
    Frames(1, .01f);
    CHECK(!Shown() && Up() && !State()->complete && fg.destroyed == destroyed && State()->failures == failures);
    fr.descriptor_pending = 0;
    Frames(1, .01f);
    CHECK(Shown()); /* a newly available remote packet publishes at once */
    SetKey("remote-sample-race");
    fr.sample_pending = 1;
    Frames(1, .01f);
    CHECK(!Shown() && Up() && fg.destroyed == destroyed);
    fr.sample_pending = 0;
    Frames(1, .101f);
    CHECK(ShownKey("remote-sample-race"));
    SetKey("remote-final-descriptor-race");
    fr.on_sample = RemoteRace;
    Frames(1, .01f);
    CHECK(!Shown() && Up() && fg.destroyed == destroyed);
    fr.on_sample = NULL;
    fr.descriptor_pending = 0;
    Frames(1, .01f);
    CHECK(ShownKey("remote-final-descriptor-race"));
    /* the native card fades while a mission is still hovered and its packet loads: the frame stays, without a timer */
    static const float kGaps[3] = {.05f, .16f, .30f};
    for (int i = 0; i < 3; i++)
    {
        fr.active = 0;
        fr.descriptor_pending = 1;
        int samples = fr.samples;
        Frames(1, kGaps[i]);
        CHECK(!Shown() && Up() && fg.destroyed == destroyed && fr.samples == samples);
        fr.active = 1;
        fr.descriptor_pending = 0;
        char key[64];
        snprintf(key, sizeof key, "%s-next", fr.key);
        SetKey(key);
        Frames(1, .01f);
        CHECK(ShownKey(key) && fg.destroyed == destroyed);
    }
    /* an actual unhover hides everything on the same update, even at zero elapsed time */
    fr.hovered = 0;
    fr.descriptor_pending = 1;
    int samples = fr.samples;
    Frames(1, 0);
    CHECK(!Up() && strcmp(State()->status, "hidden") == 0 && !State()->has_key && !State()->complete);
    CHECK_EQ(fr.samples, samples);
    Frames(1, .01f);
    Frames(1, .5f);
    CHECK(!Up() && fr.samples == samples); /* no timer or packet restores a dismissed panel */
    fr.hovered = 1;
    fr.descriptor_pending = 0;
    fr.active = 0;
    Frames(1, .001f);
    CHECK(Shown()); /* a rehover restores a ready forecast without waiting for the card */
    SetKey("unhover-during-read");
    fr.on_sample = UnhoverDuringRead;
    Frames(1, .001f);
    CHECK(!Up());
    fr.on_sample = NULL;
    fr.hovered = 1;
    fr.descriptor_pending = 0;
    fr.active = 1;
    Frames(1, .001f);
    CHECK(Shown());
    fr.ready = 0;
    Frames(1, .001f);
    CHECK(!Up()); /* closing the left native frame hides at once */
    fr.ready = 1;
    Frames(1, .01f);
    fr.descriptor_pending = 1;
    fr.screen = KYC_SCREEN_BRIEFING;
    Frames(1, .001f);
    CHECK(!Up()); /* a screen change clears the GUI even while the new descriptor is pending */
    CHECK_EQ(State()->failures, 0);
    Leave();
}

/* The panel's own waits: engine resources not there yet, a window or native panel too small. Hidden with the reason,
 * never counted, back once they clear. */
typedef struct Wait { const char* reason; int fresh; int* flag; } Wait;

static void PanelWaits(void)
{
    FakeWorld(3, 8, Tags(2, (int[]){15, 22}));
    fr.screen = KYC_SCREEN_MAP;
    SetKey("joinable");
    Frames(1, .01f);
    CHECK(Shown());
    Wait waits[7] = {{"UI worlds unavailable", 1, &fg.no_list}, {"Could not create forecast panel", 1, &fg.no_gui},
        {"Font material unavailable", 1, &fg.no_material}, {"Font metrics unavailable", 1, &fg.no_metrics},
        {"Retained rectangle unavailable", 1, &fg.no_rect}, {"Retained text unavailable", 1, &fg.no_text},
        {"Native panel unavailable", 0, &fg.no_resolution}};
    for (int i = 0; i < 9; i++)
    {
        const char* reason;
        if (i < 7)
        {
            reason = waits[i].reason;
            if (waits[i].fresh) CHECK(kyc_panel_clear());
            if (i == 6) { fg.width = 320; fg.height = 200; }
            else *waits[i].flag = 1;
        }
        else if (i == 7)
        {
            /* a headline that scrolls needs a caret per character; prefixes get none */
            reason = "Font caret unavailable";
            static char headline[KYC_HEADLINE_SIZE];
            KycTags long_tags = Tags(5, (int[]){19, 20, 21, 22, 15});
            CHECK(kyc_headline(fake_component(0), &long_tags, headline, sizeof headline));
            fg.caret_prefix_of = headline;
            fr.tags = long_tags;
            SetKey("long-headline");
        }
        else
        {
            reason = "Forecast exceeds viewport";
            fr.custom_anchor = 1;
            fr.anchor = PanelAnchor(489, KYC_SCREEN_MAP);
            fr.anchor.y = 20;
            fr.anchor.h = 30;
        }
        uint32_t pending = State()->pending;
        Frames(HOLD, .01f);
        char status[160];
        snprintf(status, sizeof status, "hidden: %s", reason);
        if (strcmp(State()->status, status) != 0) printf("  %s: status \"%s\"\n", reason, State()->status);
        CHECK(strcmp(State()->status, status) == 0);
        CHECK(State()->pending == pending + HOLD && State()->burst_errors == 0 && State()->failures == 0);
        if (i < 6) *waits[i].flag = 0;
        if (i == 6) { fg.width = 2560; fg.height = 1440; }
        if (i == 7) { fg.caret_prefix_of = NULL; fr.tags = Tags(2, (int[]){15, 22}); SetKey("joinable"); }
        if (i == 8) fr.custom_anchor = 0;
        Frames(3, .11f);
        CHECK(Shown());
    }
    Leave();
}

/* The update guard's error policy: one log line per burst, the 8th error of a burst stops the component, 3600 frames
 * without one end a burst, expected transient states never count. */
static int ErrorLines(void)
{
    int n = 0;
    for (const char* p = fake_log_text(); (p = strstr(p, "[Know Your Constellation] error: ")) != NULL; p++) n++;
    return n;
}

static void ErrorBursts(void)
{
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    fr.screen = KYC_SCREEN_MAP;
    Frames(1, .016f);
    fr.raise = "reader failed";
    Frames(7, .016f);
    CHECK(State()->burst_errors == 7 && State()->failures == 7 && strcmp(State()->status, "hidden: reader failed") == 0);
    CHECK_EQ(ErrorLines(), 1);
    Frames(1, .016f);
    CHECK(strcmp(vpm_status(fake_component(0)), "disabled: stopped after: 8 errors: reader failed") == 0);
    CHECK_EQ(ErrorLines(), 1);
    uint32_t frames = State()->frames;
    Frames(50, .016f);
    CHECK_EQ(State()->frames, frames); /* no frame runs after the stop */
    Leave();
    /* bursts separated by 3600 error-free frames never add up; one line each */
    fake_setup();
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    fr.screen = KYC_SCREEN_MAP;
    for (int burst = 1; burst <= 3; burst++)
    {
        fr.raise = "transient";
        Frames(7, .016f);
        fr.raise = NULL;
        Frames(3600, .016f);
        CHECK(State()->burst_errors == 0 && ErrorLines() == burst);
    }
    CHECK(State()->failures == 21 && StatusIs("visible"));
    /* 3599 error-free frames do not end a burst: its 8th error stops the component */
    fr.raise = "late";
    Frames(7, .016f);
    fr.raise = NULL;
    Frames(3599, .016f);
    fr.raise = "late again";
    Frames(1, .016f);
    CHECK(strcmp(vpm_status(fake_component(0)), "disabled: stopped after: 8 errors: late") == 0);
    Leave();
}

static void WaitsNeverCount(void)
{
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    fr.screen = KYC_SCREEN_MAP;
    Frames(1, .016f);
    CHECK(Shown());
    fr.wait = "Mission descriptor not ready";
    Frames(10000, .016f);
    CHECK(strcmp(State()->status, "hidden: Mission descriptor not ready") == 0 && State()->pending == 10000);
    CHECK(State()->burst_errors == 0 && State()->failures == 0 && ErrorLines() == 0 && !Up());
    fr.wait = NULL;
    Frames(1, .016f);
    CHECK(Shown() && StatusIs("visible")); /* back once the state clears */
    /* waiting frames neither count nor end a burst before 3600 frames */
    fr.raise = "reader failed";
    Frames(7, .016f);
    fr.raise = NULL;
    fr.wait = "Mission descriptor not ready";
    Frames(100, .016f);
    fr.wait = NULL;
    fr.raise = "reader failed";
    Frames(1, .016f);
    CHECK(strcmp(vpm_status(fake_component(0)), "disabled: stopped after: 8 errors: reader failed") == 0);
    Leave();
    /* 3600 waiting frames end a burst like 3600 error-free frames */
    fake_setup();
    FakeWorld(2, 10, Tags(1, (int[]){1}));
    fr.screen = KYC_SCREEN_MAP;
    fr.raise = "transient";
    Frames(7, .016f);
    fr.raise = NULL;
    fr.wait = "Mission descriptor not ready";
    Frames(3600, .016f);
    CHECK(State()->burst_errors == 0 && State()->pending == 3600);
    fr.wait = NULL;
    fr.raise = "transient";
    Frames(7, .016f);
    CHECK(State()->burst_errors == 7 && strcmp(State()->status, "hidden: transient") == 0 && vpm_running(fake_component(0)));
    Leave();
}

/* The tick starts at HF_EVENT_GAME_LOADED; the core stopping the component removes the panel. */
static void StartsAndStops(void)
{
    Session(0);
    SessionGui();
    CHECK_EQ(fake_start(kDefs, 1), 0);
    ShowScreen(15);
    uint32_t before = Reads();
    Frames(5, .11f);
    CHECK(Reads() == before && !Up());
    fake_fire(HF_EVENT_GAME_LOADED);
    Frames(3, .11f);
    CHECK(Shown());
    int destroyed = fg.destroyed;
    CHECK(vpm_fail(fake_component(0), "test stop") == 1);
    CHECK(!Up() && fg.destroyed == destroyed + 1);
    kyc_gui_use(NULL);
}

int main(void)
{
    RUN(RosterIntegrity);
    RUN(RosterIlluminate);
    RUN(RosterAutomatons);
    RUN(RosterTerminids);
    RUN(RosterOrderAndCache);
    RUN(RecordedSeeds);
    RUN(DrawRules);
    RUN(BoundaryDraws);
    RUN(Headlines);
    RUN(ExclusionKey);
    RUN(TextWrap);
    RUN(HostedForecast);
    RUN(JoinableForecast);
    RUN(OtherPlanetHover);
    RUN(LevelEleven);
    RUN(NativePanel);
    RUN(JoinablePanel);
    RUN(PanelResolutions);
    RUN(PanelPlacement);
    RUN(PanelPlans);
    RUN(PanelScroll);
    RUN(BudgetHost);
    RUN(BudgetClient);
    RUN(BudgetWeighted);
    RUN(IdleGate);
    RUN(TransientStates);
    RUN(TransientStatesClient);
    RUN(GenuineErrorStops);
    RUN(PanelOff);
    RUN(StartsAndStops);
    RUN(Publication);
    RUN(SelectionRaces);
    RUN(ClientHovers);
    RUN(PanelWaits);
    RUN(ErrorBursts);
    RUN(WaitsNeverCount);
    TEST_END();
}
