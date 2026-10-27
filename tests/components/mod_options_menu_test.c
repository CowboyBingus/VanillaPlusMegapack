/* Mod Options Menu: the Lua tests' scenarios on the fake game (components/ModOptionsMenu/tests/test_options_tab.lua,
 * and test_categories.lua and test_slider_numbers.lua where they concern the MODS tab rather than the Lua API), plus
 * the pack's switches, the options the tab cannot show, values set from code, and stop() handing the view back. The
 * Lua's values file (test_values.lua) is the core's settings file, written at once on APPLY as the Lua wrote its file;
 * its translation, update-guard and LuaJIT tests have no C counterpart.
 *
 * game.dll's functions are stand-ins: the fake image holds each function's first bytes as reviewed, so the core's wait
 * for them (vpm_when_code_ready) passes at HF_EVENT_GAME_LOADED, and after it a jump to the stand-in (an absolute jmp
 * [rip] over those bytes, its page made executable), so the component calls game.dll + RVA as it does in the game. The
 * code still encoded at the event (int3 bytes) and never decoded have tests of their own. The stand-ins do what the Lua
 * test's emulated natives did: rows, text widgets, the category selection and the OPTIONS visual pass. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/mod_options_menu/mom.h"

TEST_GLOBALS;

#define TEMPLATE 0xC67C7FAFu
#define KEY 0xAB2A7B35u
#define OFF_LABEL 0xA090BE2Eu
#define ON_LABEL 0x13DC1DA2u
#define APPLY 12 /* Menu.ExtraOption1 (Tab), Menu.Select, Menu.Back */
#define SELECT 10
#define BACK 9
#define DT 0.016f

static const uint32_t kTabLabels[3] = {0xD876B36Eu, 0x78934E12u, 0x8C02BD80u};
static const uint32_t kCategoryLabels[9] = {0x396F27D7u, 0x196248D0u, 0xA522D2D0u, 0x15CECAC1u, 0x9A688238u,
    0x07E3B100u, 0x5DB3B764u, 0xA7C345EFu, 0x9BB47B92u};
static const uint32_t kPanelAt[8] = {1150848u, 1179528u, 1253248u, 1287376u, 1153728u, 1156616u, 1290256u, 1293152u};
static const uint32_t kCountField[8] = {2832u, 33256u, 33256u, 2832u, 2832u, 22352u, 2832u, 2832u};
static const uint32_t kSelectedField[8] = {2872u, 33296u, 33296u, 2872u, 2872u, 22392u, 2880u, 2872u};
static const int kNativeRows[8] = {11, 19, 19, 9, 26, 11, 27, 11};

/* ---- memory -------------------------------------------------------------------------------------------------------- */

static uint8_t G8(uintptr_t at) { uint8_t v; memcpy(&v, (const void*)at, 1); return v; }
static uint32_t G32(uintptr_t at) { uint32_t v; memcpy(&v, (const void*)at, 4); return v; }
static uint64_t G64(uintptr_t at) { uint64_t v; memcpy(&v, (const void*)at, 8); return v; }
static float GF(uintptr_t at) { float v; memcpy(&v, (const void*)at, 4); return v; }
static void P8(uintptr_t at, uint8_t v) { memcpy((void*)at, &v, 1); }
static void P32(uintptr_t at, uint32_t v) { memcpy((void*)at, &v, 4); }
static void P64(uintptr_t at, uint64_t v) { memcpy((void*)at, &v, 8); }
static void PF(uintptr_t at, float v) { memcpy((void*)at, &v, 4); }

/* ---- the fake escape menu ------------------------------------------------------------------------------------------ */

#define VISUAL_EMULATE 0 /* the OPTIONS visual pass as far as MOM depends on it */
#define VISUAL_COUNT 1   /* counted only (the Lua's measure windows) */
#define VISUAL_LATE 2    /* a pass with dt 0 is skipped: no layout pass before hiding (the 2026-10-18 report) */

static struct
{
    uintptr_t ui, menu, screen, input, bar, content, rows, box, frame, title, body, dialog;
    int layoutDirty, visualMode, sliderNaN;
    int visuals;
    float visualDt[64];
    int boxes;
    uint8_t boxCalls[64][2], lastBox[2];
    int selects, lastSelect, finishes, sounds, released, choices, sliders;
    uintptr_t lastFinish;
    uint32_t lastSound;
} w;

static uintptr_t Row(int index) { return w.rows + 31464u * (uint32_t)index; }
static uintptr_t Panel(int index) { return w.content + kPanelAt[index]; }
static uintptr_t Button(int index) { return w.content + 816u + 14920u * (uint32_t)index; }

static void SetStack(int count, uint32_t first, uint32_t second)
{
    uint32_t list[5] = {first, second, 0, 0, 0};
    for (int i = 0; i < 5; i++) P32(w.ui + 0x429C + 4u * (uint32_t)i, i < count ? list[i] : 0);
    P32(w.ui + 0x429C + 20, (uint32_t)count);
}

static void Press(int action) { P8(w.input + 808 + 32u * (uint32_t)action, 1); }
static void ReleaseKeys(void) { memset((void*)(w.input + 808), 0, 32 * 97); }

/* The game's unapplied-changes dialog (mode 0): state 1 opening, 2 open, 3 closing; the confirm button (visible flag 0x10)
 * uses Menu.Select, the cancel button Menu.Back. */
static void SetDialog(uint32_t state)
{
    P32(w.dialog + 19748, 0);
    P32(w.dialog + 19752, state);
    P32(w.dialog + 4608, 0x10);
    P32(w.dialog + 12072, 0);
    P32(w.dialog + 12076, SELECT);
    P32(w.dialog + 12160, 0x10);
    P32(w.dialog + 19624, 0);
    P32(w.dialog + 19628, BACK);
}

/* The game's input update answering the open dialog before this frame's tick (0x1998e00): it closes the dialog, then
 * clears Menu.Select's action state whichever button was used; Menu.Back stays set. */
static void GameAnswers(int action)
{
    P32(w.dialog + 19752, 3);
    if (action == BACK) Press(BACK);
}

/* Widgets: children list at +224 sorted by address, sibling at +232, parent at +240. */
static void AddChild(uintptr_t parent, uintptr_t child)
{
    uintptr_t previous = 0, node = (uintptr_t)G64(parent + 224);
    while (node != 0 && node < child) { previous = node; node = (uintptr_t)G64(node + 232); }
    P64(child + 240, parent);
    if (node == child) return;
    P64(child + 232, node);
    P64(previous != 0 ? previous + 232 : parent + 224, child);
}

/* Releasing a row detaches it from its parent's list, as the game's own pre-build does for all 32 rows. */
static void Release(uintptr_t child)
{
    uintptr_t parent = (uintptr_t)G64(child + 240);
    if (parent != 0)
    {
        uintptr_t previous = 0, node = (uintptr_t)G64(parent + 224);
        while (node != 0 && node != child) { previous = node; node = (uintptr_t)G64(node + 232); }
        if (node == child) P64(previous != 0 ? previous + 232 : parent + 224, G64(child + 232));
    }
    P64(child + 232, 0);
    P64(child + 240, 0);
}

static int Children(uintptr_t parent)
{
    int n = 0;
    for (uintptr_t node = (uintptr_t)G64(parent + 224); node != 0; node = (uintptr_t)G64(node + 232)) n++;
    return n;
}

static int Visible(uintptr_t widget) { return (G32(widget) & 0x10) != 0; }
static void SetVisible(uintptr_t widget, int on) { uint32_t f = G32(widget); P32(widget, on ? f | 0x10u : f & ~0x10u); }
static void TextInit(uintptr_t widget) { P32(widget + 272, 0); P8(widget + 616, 0); }

static const char* Argument(uintptr_t widget)
{
    for (uint32_t i = 0; i < G8(widget + 616); i++)
    {
        uintptr_t record = widget + 280 + 24 * i;
        if (G32(record) == KEY && G32(record + 4) == 1) return (const char*)(uintptr_t)G64(record + 8);
    }
    return NULL;
}

/* Whether a text widget shows this text (its string argument under the template); says what it shows when not. */
static int Shows(uintptr_t widget, const char* text)
{
    const char* shown = G32(widget + 272) == TEMPLATE ? Argument(widget) : NULL;
    if (shown != NULL && strcmp(shown, text) == 0) return 1;
    printf("    the widget shows \"%s\" (label 0x%08X), not \"%s\"\n", shown != NULL ? shown : "", G32(widget + 272), text);
    return 0;
}

/* The game's panel builds: real rows for a category, each re-initialised. */
static void NativeBuild(int category)
{
    for (int i = 31; i >= 0; i--) Release(Row(i));
    for (int i = 0; i < kNativeRows[category]; i++)
    {
        uintptr_t target = Row(i);
        P32(target + 31428, (uint32_t)(category * 100 + i));
        P32(target + 31424, 2);
        TextInit(target + 3992);
        P32(target + 3992 + 272, (uint32_t)(0x1000 + category * 100 + i));
        TextInit(target + 16832);
        SetVisible(target, 1);
        AddChild(Panel(category) + 544, target);
    }
    P32(Panel(category) + kCountField[category], (uint32_t)kNativeRows[category]);
}

/* ---- game.dll's functions: the stand-ins ---------------------------------------------------------------------------- */

static void FakeHideDescription(uintptr_t target, uint8_t hidden, uint8_t animate)
{
    CHECK(target == w.box);
    if (w.boxes < 64) { w.boxCalls[w.boxes][0] = hidden; w.boxCalls[w.boxes][1] = animate; }
    w.boxes++;
    w.lastBox[0] = hidden;
    w.lastBox[1] = animate;
    P8(w.box + 2672, hidden);
}

/* The OPTIONS pass's description: set_description for the current panel's selected row. Setting 139 (MOM rows) and 156
 * (none) have no description; other settings show their own labels. */
static void Describe(void)
{
    uint32_t category = G32(w.content + 1318488), setting = 156;
    if (category <= 7)
    {
        uint32_t index = G32(Panel((int)category) + kSelectedField[category]);
        if (index != 0x7FFFFFFFu) setting = G32(Row((int)index) + 31428);
    }
    if (G32(w.content + 1318500) == setting) return;
    P32(w.content + 1318500, setting);
    if (G32(w.content + 1318476) == setting) return;
    P32(w.content + 1318476, setting);
    if (setting == 156 || setting == 139) { FakeHideDescription(w.box, 1, 1); return; }
    P32(w.title + 272, 0x2000 + setting);
    P32(w.body + 272, 0x3000 + setting);
    FakeHideDescription(w.box, 0, 1);
}

/* The OPTIONS visual pass, as far as MOM depends on it. Its layout part: the escape menu's init marks the layout dirty,
 * and the first pass after it places each visible category button at (0, -64 i) (y at +8); a hidden button keeps its
 * place, (0, 0) after an init. An opening dialog finishes opening inside the pass. */
static void FakeOptionsVisual(uintptr_t target, float dt)
{
    w.visuals++;
    if (w.visualMode == VISUAL_COUNT || (w.visualMode == VISUAL_LATE && dt == 0)) return;
    CHECK(target == w.content && G8(w.content + 1319445) == 0);
    if (w.visuals <= 64) w.visualDt[w.visuals - 1] = dt;
    if (w.layoutDirty)
    {
        for (int i = 0; i < 9; i++)
            if (Visible(Button(i))) PF(Button(i) + 8, -64.0f * (float)i);
        w.layoutDirty = 0;
    }
    if (G32(w.dialog + 19752) == 1) P32(w.dialog + 19752, 2);
    Describe();
}

static void FakeSetTabLabels(uintptr_t target, const uint32_t* labels, int count)
{
    CHECK(target == w.bar);
    P32(w.bar + 57448, (uint32_t)count);
    for (uint32_t i = 0; i < (uint32_t)count; i++)
    {
        P32(w.bar + 57320 + 4 * i, labels[i]);
        P32(w.bar + 8296 + 3400 * i + 272, labels[i]);
        P32(w.bar + 11004 + 3400 * i, 1);
    }
}

static void FakeSelectCategory(uintptr_t target, int category)
{
    CHECK(target == w.content);
    w.selects++;
    w.lastSelect = category;
    P32(w.content + 1318488, (uint32_t)category);
    if (G32(w.content + 1318492) != (uint32_t)category && category <= 7) NativeBuild(category);
}

static void FakeSetContentHidden(uintptr_t target, uint8_t hidden, uint8_t immediate)
{
    CHECK(target == w.content);
    P8(w.content + 1319445, hidden);
}

/* The game loads both rectangles with movaps, which faults unless they are 16-byte aligned (the v1.0 crash). */
static void FakeRowReset(uintptr_t row, const float* first, const float* second)
{
    CHECK(first == second && (uintptr_t)first % 16 == 0);
}

static void FakeRowRelease(uintptr_t row) { w.released++; Release(row); }

static void FakeRowInit(uintptr_t at, MomVec2 position, MomVec2 pivot, MomVec2 anchor, int layer, uintptr_t settings,
    const void* descriptor, uint8_t flag)
{
    uint32_t words[54];
    float floats[54];
    memcpy(words, descriptor, 216);
    memcpy(floats, descriptor, 216);
    CHECK((uintptr_t)descriptor % 16 == 0); /* descriptors are 16-byte aligned like the game's */
    CHECK(layer == 10 && flag == 1 && position.x == 0 && settings == 0);
    CHECK(pivot.x == 0.5f && pivot.y == 1 && anchor.x == 0.5f && anchor.y == 1);
    CHECK(G64(at + 240) == 0); /* row_init on an attached row */
    P32(at + 31428, words[0]);
    P32(at + 31424, words[2] == 2 ? 2 : words[2]);
    TextInit(at + 3992);
    P32(at + 3992 + 272, words[4]);
    SetVisible(at, 1);
    PF(at + 20000, position.y); /* test bookkeeping: the row's position */
    if (words[2] == 2)
    {
        P32(at + 29072, words[16]);
        for (uint32_t i = 0; i < words[16] && i < 16; i++) P32(at + 29080 + 4 * i, words[17 + i]);
        P32(at + 29068, 0);
        TextInit(at + 16832);
        P32(at + 16832 + 272, words[17]);
        return;
    }
    PF(at + 31396, floats[9]);
    PF(at + 31400, floats[10]);
    PF(at + 31408, floats[9]);
    P32(at + 20004, words[14]); /* test bookkeeping: the slider's format */
}

static void FakeAddChild(uintptr_t parent, uintptr_t child) { AddChild(parent, child); }
static void FakeSetVisible(uintptr_t widget, uint8_t on) { SetVisible(widget, on != 0); }
static void FakeSetLabel(uintptr_t widget, uint32_t label) { P32(widget + 272, label); }

static void FakeSetStringArg(uintptr_t at, uint32_t key, const char* text)
{
    uint32_t count = G8(at + 616), slot = count;
    for (uint32_t i = 0; i < count; i++)
        if (G32(at + 280 + 24 * i) == key) slot = i;
    uintptr_t record = at + 280 + 24 * slot;
    P32(record, key);
    P32(record + 4, 1);
    P64(record + 8, (uint64_t)(uintptr_t)text);
    if (slot == count) P8(at + 616, (uint8_t)(count + 1));
}

static uint8_t FakeClearArgs(uintptr_t label) { P8(label + 344, 0); return 1; }

static void FakeSetChoice(uintptr_t selector, uint32_t index)
{
    uintptr_t at = selector - 16016;
    w.choices++;
    P32(at + 29068, index);
    P32(at + 16832 + 272, G32(at + 29080 + 4 * index));
}

/* sliderNaN: a slider the game keeps at NaN. */
static void FakeSetSlider(uintptr_t slider, float value)
{
    w.sliders++;
    PF(slider - 29176 + 31408, w.sliderNaN ? NAN : value);
}

static void FakeFinish(uintptr_t panel) { w.finishes++; w.lastFinish = panel; }
static void FakeScroll(uintptr_t scroll, float value) {}
static void FakeScrollReset(uintptr_t scroll) {}
static void FakeSetOpacity(uintptr_t widget, float value) { PF(widget + 68, value); }

/* Text measure: one 20-unit line per 40 bytes of the shown argument. */
static void FakeMeasureText(uintptr_t widget)
{
    const char* text = Argument(widget);
    double lines = ceil((double)(text != NULL ? strlen(text) : 0) / 40.0);
    PF(widget + 16, (float)(20 * (lines < 1 ? 1 : lines)));
    PF(widget + 32, 1);
}

static void FakeSetPosition(uintptr_t widget, MomVec2 at) { PF(widget + 4, at.x); PF(widget + 8, at.y); }
static void FakeSetSize(uintptr_t widget, MomVec2 size) { PF(widget + 12, size.x); PF(widget + 16, size.y); }
static void FakePlaySound(uintptr_t unused, uint32_t event) { w.sounds++; w.lastSound = event; }

/* Typed as the component calls them, so the compiler checks every stand-in's signature. */
static const MomNative kStandIns = {
    .set_tab_labels = FakeSetTabLabels, .select_category = FakeSelectCategory,
    .set_content_hidden = FakeSetContentHidden, .row_reset = FakeRowReset, .row_release = FakeRowRelease,
    .row_init = FakeRowInit, .add_child = FakeAddChild, .set_visible = FakeSetVisible, .set_label = FakeSetLabel,
    .set_string_arg = FakeSetStringArg, .clear_args = FakeClearArgs, .set_choice = FakeSetChoice,
    .set_slider = FakeSetSlider, .finish_simple = FakeFinish, .finish_access = FakeFinish,
    .scroll_thumb = FakeScroll, .scroll_extent = FakeScroll, .set_opacity = FakeSetOpacity,
    .scroll_reset = FakeScrollReset, .options_visual = FakeOptionsVisual, .measure_text = FakeMeasureText,
    .set_position = FakeSetPosition, .set_size = FakeSetSize, .hide_description = FakeHideDescription,
    .play_sound = FakePlaySound,
};

static void* StandIn(int index)
{
    switch (index)
    {
    case MOM_SET_TAB_LABELS: return (void*)kStandIns.set_tab_labels;
    case MOM_SELECT_CATEGORY: return (void*)kStandIns.select_category;
    case MOM_SET_CONTENT_HIDDEN: return (void*)kStandIns.set_content_hidden;
    case MOM_ROW_RESET: return (void*)kStandIns.row_reset;
    case MOM_ROW_RELEASE: return (void*)kStandIns.row_release;
    case MOM_ROW_INIT: return (void*)kStandIns.row_init;
    case MOM_ADD_CHILD: return (void*)kStandIns.add_child;
    case MOM_SET_VISIBLE: return (void*)kStandIns.set_visible;
    case MOM_SET_LABEL: return (void*)kStandIns.set_label;
    case MOM_SET_STRING_ARG: return (void*)kStandIns.set_string_arg;
    case MOM_CLEAR_ARGS: return (void*)kStandIns.clear_args;
    case MOM_SET_CHOICE: return (void*)kStandIns.set_choice;
    case MOM_SET_SLIDER: return (void*)kStandIns.set_slider;
    case MOM_FINISH_SIMPLE: return (void*)kStandIns.finish_simple;
    case MOM_FINISH_ACCESS: return (void*)kStandIns.finish_access;
    case MOM_SCROLL_THUMB: return (void*)kStandIns.scroll_thumb;
    case MOM_SCROLL_EXTENT: return (void*)kStandIns.scroll_extent;
    case MOM_SET_OPACITY: return (void*)kStandIns.set_opacity;
    case MOM_SCROLL_RESET: return (void*)kStandIns.scroll_reset;
    case MOM_OPTIONS_VISUAL: return (void*)kStandIns.options_visual;
    case MOM_MEASURE_TEXT: return (void*)kStandIns.measure_text;
    case MOM_SET_POSITION: return (void*)kStandIns.set_position;
    case MOM_SET_SIZE: return (void*)kStandIns.set_size;
    case MOM_HIDE_DESCRIPTION: return (void*)kStandIns.hide_description;
    case MOM_PLAY_SOUND: return (void*)kStandIns.play_sound;
    default: return NULL;
    }
}

/* An IDA-style pattern's bytes ("48 89 54"), written where the function starts. */
static void WriteCode(uint8_t* at, const char* code)
{
    for (const char* p = code; *p;)
    {
        if (*p == ' ') { p++; continue; }
        char hex[3] = {p[0], p[1], 0};
        *at++ = (uint8_t)strtoul(hex, NULL, 16);
        p += 2;
    }
}

/* After the code checks: a jmp [rip] to each stand-in at its function's address, the page made executable. */
static void InstallStubs(void)
{
    static const uint8_t jump[6] = {0xFF, 0x25, 0, 0, 0, 0};
    for (int i = 0; i < MOM_NATIVE_COUNT; i++)
    {
        uint8_t* at = (uint8_t*)fake_game() + mom_native_pins[i].rva;
        uint64_t target = (uint64_t)(uintptr_t)StandIn(i);
        memcpy(at, jump, sizeof jump);
        memcpy(at + 6, &target, 8);
        DWORD old;
        CHECK(VirtualProtect(at, 14, PAGE_EXECUTE_READWRITE, &old)); /* lint-ok: C3 the test makes its stand-in jumps executable */
    }
}

/* ---- the test mods ------------------------------------------------------------------------------------------------- */

typedef struct Change { const VpmOption* option; double value; } Change;
static Change g_changes[64];
static int g_changeCount;

static void Changed(VpmComponent* self, VpmOption* option, double value)
{
    if (g_changeCount < 64) g_changes[g_changeCount++] = (Change){option, value};
}

#define HINTS "Shows button hints."
#define MODE "Picks how the weapon fires while the trigger is held down."
#define EXTRA(n) {"extra" #n, VPM_TOGGLE, "Extra " #n, NULL, 0, 0, 0, 0, NULL, 0}
static const char* const kModes[] = {"Single", "Burst", "Auto", NULL};
static const char* const kLevels[] = {"low", "High", NULL};
static const VpmOptionDef kAlphaDefs[15] = {
    {"hints", VPM_TOGGLE, "Show Hints", HINTS, 1, 0, 0, 0, NULL, 0},
    {"mode", VPM_CHOICE, "Fire Mode", "  Picks how the weapon fires\nwhile the trigger is held down.", 2, 0, 0, 0, kModes, 0},
    {"level", VPM_CHOICE, "Level", NULL, 1, 0, 0, 0, kLevels, 0},
    {"volume", VPM_SLIDER, "Volume", NULL, 0.5, 0, 1, 0.05, NULL, 1},
    {"count", VPM_SLIDER, "Count", NULL, 3, 1, 10, 1, NULL, 0},
    EXTRA(1), EXTRA(2), EXTRA(3), EXTRA(4), EXTRA(5), EXTRA(6), EXTRA(7), EXTRA(8), EXTRA(9), EXTRA(10),
};
static VpmOption* g_alpha[15];

static int AlphaStart(VpmComponent* self)
{
    for (int i = 0; i < 15; i++)
        if ((g_alpha[i] = vpm_option(self, &kAlphaDefs[i])) == NULL) return 1;
    vpm_option_on_change(g_alpha[0], Changed);
    vpm_option_on_change(g_alpha[1], Changed);
    vpm_option_on_change(g_alpha[3], Changed);
    return 0;
}

static const VpmOptionDef kBetaEnabled = {"enabled", VPM_TOGGLE, "Enabled", NULL, 0, 0, 0, 0, NULL, 0};
/* No step: the Lua's default step 1 (the core's 0). */
static const VpmOptionDef kBetaSpeed = {"speed", VPM_SLIDER, "Speed", "Sets the speed.", 1, 1, 5, 0, NULL, 0};
static VpmOption* g_betaEnabled;
static int BetaStart(VpmComponent* self) { return (g_betaEnabled = vpm_option(self, &kBetaEnabled)) == NULL; }

static const VpmOptionDef kZuluDefs[3] = {
    {"1", VPM_TOGGLE, "Zulu 1", NULL, 0, 0, 0, 0, NULL, 0},
    {"2", VPM_TOGGLE, "Zulu 2", NULL, 0, 0, 0, 0, NULL, 0},
    {"3", VPM_TOGGLE, "Zulu 3", NULL, 0, 0, 0, 0, NULL, 0},
};
static int ZuluStart(VpmComponent* self)
{
    for (int i = 0; i < 3; i++)
        if (vpm_option(self, &kZuluDefs[i]) == NULL) return 1;
    return 0;
}

static const VpmComponentDef kAlpha = {"alpha", "Alpha Mod", "1.0", 0, AlphaStart, NULL};
static const VpmComponentDef kBeta = {"beta", "Beta", "1.0", 0, BetaStart, NULL};
static const VpmComponentDef kZulu = {"zulu", "Zulu", "1.0", 0, ZuluStart, NULL};
static const VpmComponentDef* const kDefs[] = {&kAlpha, &kBeta, &kZulu, &vpm_component_mod_options_menu};
#define MOM_INDEX 3

/* ---- set-up -------------------------------------------------------------------------------------------------------- */

/* The fake image (the natives' first bytes, the labels, setting 139's descriptor and the UI globals) and the menu
 * system's escape menu screen. */
static void MakeWorld(void)
{
    memset(&w, 0, sizeof w);
    memset(g_changes, 0, sizeof g_changes);
    g_changeCount = 0;
    uintptr_t game = fake_game();
    w.ui = (uintptr_t)fake_heap(0x4400);
    w.menu = (uintptr_t)fake_heap(512);
    w.screen = (uintptr_t)fake_heap(3010456 + 1319500);
    w.input = (uintptr_t)fake_heap(808 + 32 * 97);
    w.bar = w.screen + 1248;
    w.content = w.screen + 3010456;
    w.rows = w.content + 144000;
    w.box = w.content + 1315800;
    w.frame = w.box + 272;
    w.title = w.box + 936;
    w.body = w.box + 1632;
    w.dialog = w.content + 1296040;
    P64(game + 0x347CE28, w.ui);
    P64(game + 0x347CE38, w.menu);
    P64(w.menu + 200, w.screen);
    P64(game + 0x347CF18, w.input);
    for (int i = 0; i < 8; i++) P64(Panel(i) + 2816, w.rows);
    for (uint32_t i = 0; i < 3; i++) P32(game + 0x33114D0 + 4 * i, kTabLabels[i]);
    for (uint32_t i = 0; i < 9; i++) P32(game + 0x32EC990 + 48 * i + 8, kCategoryLabels[i]);
    P32(game + 0x32ECC60, 139);
    P32(game + 0x32ECC60 + 4, 10);
    P32(game + 0x32ECC60 + 12, 0);
    for (int i = 0; i < MOM_NATIVE_COUNT; i++) WriteCode((uint8_t*)game + mom_native_pins[i].rva, mom_native_pins[i].pattern);
    w.layoutDirty = 1;
}

/* Started with game.dll's code decoded at HF_EVENT_GAME_LOADED (the code checks pass there, and MOM's ready step runs),
 * a first frame with the menu closed, then the stand-ins in place. */
static void Ready(const VpmComponentDef* const* defs, int count)
{
    MakeWorld();
    CHECK_EQ(fake_start(defs, count), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_frames(1, DT);
    InstallStubs();
}

static void Frame(void) { fake_frames(1, DT); }

/* HfApi reads over `frames` frames (the Lua's ReadProcessMemory per frame), checking no log line and no other call. */
static uint32_t Reads(int frames)
{
    fake_counts_reset();
    fake_frames(frames, DT);
    FakeCounts c = fake_counts();
    CHECK_EQ(c.log + c.write + c.code_matches + c.find_pattern + c.other, 0);
    return c.read;
}

/* The escape menu open on OPTIONS, last on MOUSE & KEYBOARD. */
static void MenuOnOptions(void)
{
    SetStack(1, 1, 0);
    P32(w.bar + 57448, 3);
    P32(w.bar + 57452, 2);
    for (uint32_t i = 0; i < 3; i++) P32(w.bar + 57320 + 4 * i, kTabLabels[i]);
    P32(w.screen + 8, 2);
    for (int i = 0; i < 9; i++)
    {
        SetVisible(Button(i), 1);
        P32(Button(i) + 1928 + 272, kCategoryLabels[i]);
        P8(Button(i) + 1928 + 616, 0);
    }
    P32(w.content + 1318488, 7);
    NativeBuild(7);
}

/* Selecting MODS: the game hides every content and shows nothing for tab 3. */
static void SelectMods(void)
{
    P32(w.bar + 57452, 3);
    P32(w.screen + 8, 3);
    P8(w.content + 1319445, 1);
}

/* The player (or the game) picks another category button. */
static void PickCategory(uint32_t previous, int category)
{
    P32(w.content + 1318492, previous);
    FakeSelectCategory(w.content, category);
}

static int LogCount(const char* text)
{
    int n = 0;
    for (const char* at = strstr(fake_log_text(), text); at != NULL; at = strstr(at + 1, text)) n++;
    return n;
}

static int Near(double a, double b) { return fabs(a - b) < 1e-6; }

/* Whether the settings file on disk holds this text now. */
static int SettingsFileHas(const char* text)
{
    char buffer[4096] = "";
    FILE* file = fopen("vpm-test-settings.ini", "r");
    if (file == NULL) return 0;
    buffer[fread(buffer, 1, sizeof buffer - 1, file)] = 0;
    fclose(file);
    return strstr(buffer, text) != NULL;
}

#define UNAPPLIED (w.content + 1319449)
#define DESCRIBED (w.content + 1318500)
#define SHOWN (w.content + 1318476)

/* The view went back to the game as on leaving the tab: native categories, the panel MOUSE & KEYBOARD showed, the
 * description box and the unapplied-changes flag released. */
static void HandedBack(void)
{
    CHECK(!mom.hasView && mom.pendingCount == 0);
    CHECK(G8(UNAPPLIED) == 0 && G8(w.box + 2672) == 1 && G32(DESCRIBED) == 156 && G32(SHOWN) == 156);
    for (int i = 0; i < 9; i++)
        CHECK(Visible(Button(i)) && G32(Button(i) + 1928 + 272) == kCategoryLabels[i] && G8(Button(i) + 1928 + 616) == 0);
    CHECK(G32(w.content + 1318488) == 7 && G32(Panel(7) + 2832) == 11 && G32(Row(0) + 31428) == 700);
}

/* ---- the game's functions, checked once -------------------------------------------------------------------------- */

static int CodeBytes(const char* code)
{
    int n = 0;
    for (const char* p = code; *p; p++) n += *p != ' ' ? 1 : 0;
    return n / 2;
}

#define VERIFIED "[Mod Options Menu] Native options layout verified for current game build."

/* The Lua's table (native.lua). Decoded at HF_EVENT_GAME_LOADED: the 25 code checks there, MOM ready at once; then an
 * idle frame makes one read, as before. */
static void VerifiesTheGameOnce(void)
{
    CHECK_EQ(MOM_NATIVE_COUNT, 25);
    CHECK(mom_native_pins[MOM_SET_TAB_LABELS].rva == 0x17AAC50u && mom_native_pins[MOM_ROW_INIT].rva == 0x17FE8D0u);
    CHECK(mom_native_pins[MOM_OPTIONS_VISUAL].rva == 0x1998590u && mom_native_pins[MOM_PLAY_SOUND].rva == 0x1327F50u);
    CHECK(strncmp(mom_native_pins[MOM_SET_TAB_LABELS].pattern, "48 89 54 24 10 53 56 48 83 EC 68", 32) == 0);
    CHECK(strcmp(mom_native_pins[MOM_PLAY_SOUND].name, "Mod options integration unavailable: play_sound") == 0);
    for (int i = 0; i < MOM_NATIVE_COUNT; i++)
    {
        CHECK_EQ(CodeBytes(mom_native_pins[i].pattern), i == MOM_SET_POSITION || i == MOM_SET_SIZE ? 28 : 16);
        CHECK_EQ(mom_native_pins[i].flags, 0);
    }
    MakeWorld();
    CHECK_EQ(fake_start(kDefs, 4), 0);
    VpmComponent* self = fake_component(MOM_INDEX);
    CHECK(!vpm_ticking(self));
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_EQ(fake_counts().code_matches, 25);
    CHECK_EQ(fake_counts().read, 0);
    CHECK_LOG(VERIFIED);
    CHECK(vpm_ticking(self));
    fake_counts_reset();
    Frame();
    CHECK_EQ(fake_counts().code_matches, 0);
    CHECK_EQ(fake_counts().read, 1); /* the idle gate */
    CHECK_EQ(Reads(100), 100);
    CHECK(vpm_running(self));
}

/* game.dll's functions still encoded (int3 bytes, as the harness's undecoded frame update), and decoded. */
static void Encode(int index)
{
    memset((uint8_t*)fake_game() + mom_native_pins[index].rva, 0xCC, (size_t)CodeBytes(mom_native_pins[index].pattern));
}
static void Decode(int index) { WriteCode((uint8_t*)fake_game() + mom_native_pins[index].rva, mom_native_pins[index].pattern); }
static int MomLines(void) { return fake_log_count("[Mod Options Menu]"); }

/* The code still encoded at HF_EVENT_GAME_LOADED and decoded seconds later. Meanwhile nothing of MOM runs, with the
 * escape menu open on OPTIONS: no tick, no read, no write, no log line, the tab bar untouched; the core looks every 30
 * frames, up to the first function that does not match yet. Once the last one is decoded, the next look runs MOM's
 * ready step (the labels, the binding, the tick) and the MODS tab comes as when decoded at the event. */
static void StartsOnceTheCodeIsDecoded(void)
{
    MakeWorld();
    for (int i = 0; i < MOM_NATIVE_COUNT; i++) Encode(i);
    CHECK_EQ(fake_start(kDefs, 4), 0);
    VpmComponent* self = fake_component(MOM_INDEX);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(vpm_running(self) && !vpm_ticking(self));
    MenuOnOptions();
    int lines = MomLines();
    fake_counts_reset();
    fake_frames(180, DT); /* about 3 s: six looks */
    FakeCounts c = fake_counts();
    CHECK(c.code_matches == 6 && c.read == 0 && c.write == 0);
    CHECK(MomLines() == lines && !vpm_ticking(self) && G32(w.bar + 57448) == 3);
    for (int i = 0; i < MOM_NATIVE_COUNT - 1; i++) Decode(i); /* all but play_sound */
    fake_counts_reset();
    fake_frames(60, DT);
    CHECK(fake_counts().code_matches == 50 && fake_counts().read == 0);
    CHECK(!vpm_ticking(self) && MomLines() == lines && G32(w.bar + 57448) == 3);
    SetStack(0, 0, 0);
    Decode(MOM_PLAY_SOUND);
    int frames = 0;
    while (frames < 30 && !vpm_ticking(self)) { Frame(); frames++; }
    CHECK(vpm_ticking(self) && vpm_running(self) && frames == 30);
    CHECK_LOG(VERIFIED);
    InstallStubs();
    CHECK_EQ(Reads(10), 10); /* the idle gate: one read per frame */
    MenuOnOptions();
    Frame();
    CHECK(G32(w.bar + 57448) == 4 && Shows(w.bar + 8296 + 3400 * 3, "MODS"));
}

/* Never decoded (one function): MOM is stopped once 60 s of game time have passed, naming that function in the Lua's
 * wording; it never ticked, read or wrote, and the open escape menu was left alone. */
static void StoppedWhenTheCodeIsNeverDecoded(void)
{
    MakeWorld();
    Encode(MOM_OPTIONS_VISUAL);
    CHECK_EQ(fake_start(kDefs, 4), 0);
    VpmComponent* self = fake_component(MOM_INDEX);
    fake_fire(HF_EVENT_GAME_LOADED);
    MenuOnOptions();
    fake_counts_reset();
    fake_frames(3700, DT); /* 59.2 s */
    CHECK(vpm_running(self) && !vpm_ticking(self));
    fake_frames(100, DT);
    CHECK(!vpm_running(self));
    static const char kWhy[] = "disabled: Mod options integration unavailable: options_visual changed (game.dll 0x1998590)";
    CHECK(strcmp(vpm_status(self), kWhy) == 0);
    CHECK_LOG(kWhy);
    CHECK_NO_LOG(VERIFIED);
    CHECK(fake_counts().read == 0 && fake_counts().write == 0);
    CHECK(G32(w.bar + 57448) == 3 && G32(w.content + 1318488) == 7 && G32(Row(0) + 31428) == 700);
    CHECK_EQ(Reads(100), 0);
}

/* The menu data is filled in after the code matched (a player's machine, 2026-10-26): MOM waits for it, reads nothing
 * but the 15 data words every 30 frames, starts once it reads as reviewed, and logs how long that took. */
static void StartsWhenTheMenuDataIsFilledInLater(void)
{
    fake_setup();
    MakeWorld();
    uintptr_t game = fake_game();
    uint32_t label = G32(game + 0x33114D0);
    P32(game + 0x33114D0, 0); /* not filled in yet */
    CHECK_EQ(fake_start(kDefs, 4), 0);
    VpmComponent* self = fake_component(MOM_INDEX);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(vpm_running(self) && vpm_ticking(self));
    CHECK_NO_LOG(VERIFIED);
    fake_counts_reset();
    fake_frames(29, DT);
    CHECK_EQ(fake_counts().read, 0); /* game.dll's data is plain loads; nothing between looks */
    fake_frames(60, DT);
    CHECK(vpm_running(self));
    CHECK_NO_LOG(VERIFIED);
    CHECK_EQ(fake_counts().log, 0); /* waiting says nothing */
    P32(game + 0x33114D0, label); /* the game fills it in */
    fake_frames(30, DT);
    CHECK_LOG(VERIFIED);
    CHECK_LOG("The game's menu data read as reviewed ");
    CHECK(vpm_running(self));
    InstallStubs(); /* the game's menu functions, as the other tests once verified; the menu opens after */
    MenuOnOptions();
    Frame();
    CHECK(G32(w.bar + 57448) == 4 && Shows(w.bar + 8296 + 3400 * 3, "MODS")); /* the MODS tab, as at once */

    /* never filled in: refused after the wait, saying it holds 0 */
    fake_setup();
    MakeWorld();
    P32(fake_game() + 0x33114D0, 0);
    CHECK_EQ(fake_start(kDefs, 4), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_frames(3700, DT); /* 59.2 s */
    CHECK(vpm_running(fake_component(MOM_INDEX)));
    fake_frames(100, DT);
    CHECK(!vpm_running(fake_component(MOM_INDEX)));
    CHECK_LOG("disabled: Mod options integration unavailable: tab labels changed (game.dll+0x33114D0 holds 0x00000000, reviewed 0x");
}

static void RefusesAChangedGame(void)
{
    static const char* const texts[] = {"options_visual changed", "tab labels changed", "category labels changed",
        "setting descriptors changed"};
    for (int c = 0; c < 4; c++)
    {
        fake_setup();
        MakeWorld();
        uintptr_t game = fake_game();
        if (c == 0) P8(game + 0x1998590 + 9, 0xBA);
        if (c == 1) P32(game + 0x33114D0 + 8, 0);
        if (c == 2) P32(game + 0x32EC990 + 48 * 5 + 8, 1);
        if (c == 3) P32(game + 0x32ECC60 + 4, 11);
        CHECK_EQ(fake_start(kDefs, 4), 0);
        fake_fire(HF_EVENT_GAME_LOADED); /* refused once the 60 s wait is over: changed code and changed data alike */
        if (c > 0) CHECK(vpm_running(fake_component(MOM_INDEX))); /* the data still has time to be filled in */
        fake_frames(3800, DT);
        CHECK(!vpm_running(fake_component(MOM_INDEX)));
        CHECK_LOG("disabled: Mod options integration unavailable: ");
        CHECK_LOG(texts[c]);
        MenuOnOptions();
        CHECK_EQ(Reads(10), 0);
        CHECK_EQ(G32(w.bar + 57448), 3); /* the menu left alone */
    }
}

/* ---- the MODS tab: test_options_tab.lua, in its order ---------------------------------------------------------------- */

/* Escape menu open on OPTIONS, then MODS: the tab, the category buttons, page 0's rows, the layout and the
 * description. */
static void OpensTheModsTab(void)
{
    CHECK(vpm_option_value(g_alpha[0]) == 1 && vpm_option_value(g_alpha[1]) == 2 && vpm_option_value(g_alpha[3]) == 0.5);
    CHECK(vpm_option_value(g_alpha[4]) == 3 && vpm_option_value(g_betaEnabled) == 0 && vpm_option_value(g_alpha[2]) == 1);
    MenuOnOptions();
    Frame();
    CHECK(G32(w.bar + 57448) == 4 && G32(w.bar + 57320 + 12) == TEMPLATE);
    CHECK(Shows(w.bar + 8296 + 3400 * 3, "MODS"));
    CHECK(G32(w.bar + 11004 + 3400 * 2) == 3 && G8(w.bar + 11021 + 3400 * 2) == 1);
    CHECK(!mom.hasView && w.visuals == 0); /* the screen runs OPTIONS' visual pass itself */
    CHECK_LOG("Added native MODS tab (current tab 2).");
    SelectMods();
    Frame();
    CHECK(mom.hasView && G32(w.screen + 8) == 2 && G8(w.content + 1319445) == 0);
    CHECK(Shows(Button(0) + 1928, "ALPHA MOD") && Shows(Button(1) + 1928, "BETA"));
    CHECK(Shows(Button(2) + 1928, "VANILLA PLUS MEGAPACK") && Shows(Button(3) + 1928, "ZULU"));
    for (int i = 4; i < 9; i++) CHECK(!Visible(Button(i)));
    CHECK(w.lastSelect == 0 && G32(w.content + 1318488) == 0);
    CHECK_LOG("Opened MODS tab: 4 mods.");
    /* Page 0: fifteen Alpha options on the GAMEPLAY panel, which natively lists 11 rows. */
    CHECK_EQ(G32(Panel(0) + 2832), 15);
    static const char* const labels[] = {"Show Hints", "Fire Mode", "Level", "Volume", "Count"};
    for (int i = 0; i < 5; i++) CHECK(G32(Row(i) + 31428) == 139 && Shows(Row(i) + 3992, labels[i]));
    CHECK(G32(Row(0) + 29068) == 1 && G32(Row(0) + 29080) == OFF_LABEL);
    CHECK(G32(Row(1) + 29068) == 1 && Shows(Row(1) + 16832, "BURST"));
    CHECK(G32(Row(2) + 29080) == 0xE1F9AB36u && G32(Row(2) + 29084) == 0x208F9597u); /* LOW, HIGH: the game's words */
    CHECK(Near(GF(Row(3) + 31408), 0.5) && G32(Row(3) + 20004) == 0x6220);
    CHECK(GF(Row(3) + 20000) == -3 * 64 - 32 && GF(Row(4) + 20000) == -4 * 64 - 32);
    CHECK(G32(Row(4) + 20004) == 0 && GF(Row(4) + 31408) == 3);
    CHECK(Near(GF(Panel(0) + 2840), -32) && w.lastFinish == Panel(0));
    CHECK(Children(Panel(0) + 544) == 15 && w.released == 32);
    /* The screen skips the OPTIONS visual pass on tab 3, so MOM runs it with the frame time in the step that built the
     * page. The game hides the box for setting 139; row 0 is selected, so MOM then shows its description with the
     * game's layout. Before hiding any category button MOM runs the pass once more with dt 0 and the native column
     * shown, which lays out all nine buttons and describes OPTIONS' selected row (setting 700) first. */
    CHECK(w.visuals == 2 && w.visualDt[0] == 0 && Near(w.visualDt[1], DT));
    CHECK(w.boxes == 3 && w.boxCalls[0][0] == 0 && w.boxCalls[1][0] == 1 && w.boxCalls[2][0] == 0 && w.boxCalls[2][1] == 1);
    for (int i = 0; i < 9; i++) CHECK(GF(Button(i) + 8) == -64.0f * (float)i);
    CHECK(G8(w.box + 2672) == 0 && Shows(w.title, "Show Hints") && Shows(w.body, HINTS));
    CHECK(GF(w.body + 4) == 14 && GF(w.body + 8) == -20 - 24 && GF(w.body + 68) == 1);
    CHECK(GF(w.frame + 12) == 450 && GF(w.frame + 16) == 20 + 20 + 7 + 72);
}

/* Player changes stay pending as on OPTIONS; Tab applies them in registration order, through the core. */
static void AppliesEdits(void)
{
    P32(Row(0) + 29068, 0);
    P32(Row(1) + 29068, 2);
    P32(Row(1) + 16832 + 272, TEMPLATE);
    PF(Row(3) + 31408, 0.7500001f);
    Frame();
    CHECK(vpm_option_value(g_alpha[0]) == 1 && vpm_option_value(g_alpha[1]) == 2 && vpm_option_value(g_alpha[3]) == 0.5);
    CHECK(g_changeCount == 0 && Shows(Row(1) + 16832, "AUTO") && G8(UNAPPLIED) == 1);
    CHECK(w.visuals == 3 && w.boxes == 3); /* same selection: no description work */
    CHECK(!SettingsFileHas("alpha.hints"));
    Press(APPLY);
    Frame();
    ReleaseKeys();
    /* Written at once, as the Lua wrote its values file on apply (the core alone saves a second later). */
    CHECK(SettingsFileHas("alpha.hints = 0") && SettingsFileHas("alpha.mode = 3") && SettingsFileHas("alpha.volume = 0.75"));
    CHECK(vpm_option_value(g_alpha[0]) == 0 && vpm_option_value(g_alpha[1]) == 3 && Near(vpm_option_value(g_alpha[3]), 0.75));
    CHECK(g_changeCount == 3 && g_changes[0].option == g_alpha[0] && g_changes[1].option == g_alpha[1]);
    CHECK(g_changes[2].option == g_alpha[3] && Near(g_changes[2].value, 0.75));
    CHECK(G8(UNAPPLIED) == 0 && w.sounds == 1 && w.lastSound == 1183616600u);
    CHECK_LOG("Applied 3 option changes.");
    const char* hints = vpm_setting("options", "alpha.hints");
    const char* mode = vpm_setting("options", "alpha.mode");
    const char* volume = vpm_setting("options", "alpha.volume");
    CHECK(hints != NULL && strcmp(hints, "0") == 0 && mode != NULL && strcmp(mode, "3") == 0);
    CHECK(volume != NULL && strcmp(volume, "0.75") == 0);
    /* Editing back to the applied value withdraws the edit. */
    P32(Row(0) + 29068, 1);
    Frame();
    CHECK(G8(UNAPPLIED) == 1);
    P32(Row(0) + 29068, 0);
    Frame();
    CHECK(G8(UNAPPLIED) == 0);
}

/* Leaving with an edit meets the game's UNAPPLIED CHANGES dialog; its confirm discards, its cancel keeps the edit,
 * whether the game answers it before or after this tick. */
static void TheUnappliedChangesDialog(void)
{
    /* Answered before this tick: the dialog is already closing and the confirm's Menu.Select has been cleared. */
    P32(Row(0) + 29068, 1);
    Frame();
    SetDialog(2);
    Frame();
    CHECK(G8(UNAPPLIED) == 1);
    CHECK(G32(w.dialog + 19748) == 2); /* once open, a mode the game's own confirm ignores */
    GameAnswers(SELECT);
    Frame();
    ReleaseKeys();
    SetDialog(0);
    CHECK(G8(UNAPPLIED) == 0 && G32(Row(0) + 29068) == 0 && vpm_option_value(g_alpha[0]) == 0);
    CHECK_LOG("Discarded unapplied option changes.");
    /* Without an edit pending, the game's dialog is left alone. */
    SetDialog(2);
    Frame();
    CHECK(G32(w.dialog + 19748) == 0);
    SetDialog(0);
    Frame();
    /* A cancel answered before this tick keeps the edit, as does its closing. */
    P32(Row(0) + 29068, 1);
    Frame();
    SetDialog(2);
    Frame();
    GameAnswers(BACK);
    Frame();
    ReleaseKeys();
    Frame();
    SetDialog(0);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && G32(Row(0) + 29068) == 1);
    /* A dialog that finishes opening inside the visual pass counts from there. */
    SetDialog(1);
    Frame();
    CHECK(G32(w.dialog + 19752) == 2 && G32(w.dialog + 19748) == 2);
    GameAnswers(SELECT);
    Frame();
    SetDialog(0);
    CHECK(G8(UNAPPLIED) == 0 && G32(Row(0) + 29068) == 0);
    /* ... or after this tick (the dialog still open): Tab does nothing while it is open, and a cancel keeps the edit
     * even once the dialog closes. */
    P32(Row(0) + 29068, 1);
    Frame();
    SetDialog(2);
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK(G8(UNAPPLIED) == 1);
    Press(BACK);
    Frame();
    ReleaseKeys();
    SetDialog(3);
    Frame();
    SetDialog(0);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && G32(Row(0) + 29068) == 1);
    SetDialog(2);
    Frame();
    Press(SELECT);
    Frame();
    ReleaseKeys();
    CHECK(G8(UNAPPLIED) == 0 && G32(Row(0) + 29068) == 0); /* decided while still open */
    SetDialog(3);
    Frame();
    SetDialog(0);
    CHECK(G8(UNAPPLIED) == 0 && G32(Row(0) + 29068) == 0 && g_changeCount == 3 && w.sounds == 1);
}

/* A row value the option cannot take (a slider at NaN or an infinity, a selector index past its choices) makes no
 * edit, and the row is set back to the value it showed (its pending edit, if any). */
static void RefusesValuesTheOptionCannotTake(void)
{
    const float bad[3] = {NAN, INFINITY, -INFINITY};
    for (int round = 0; round < 3; round++)
    {
        for (int b = 0; b < 3; b++)
        {
            w.sliders = 0;
            PF(Row(3) + 31408, bad[b]);
            Frame();
            CHECK(w.sliders == 1 && GF(Row(3) + 31408) == 0.75f);
            CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0 && Near(vpm_option_value(g_alpha[3]), 0.75));
        }
        P32(Row(1) + 29068, 3);
        Frame();
        CHECK(G32(Row(1) + 29068) == 2 && Shows(Row(1) + 16832, "AUTO") && G8(UNAPPLIED) == 0);
    }
    PF(Row(4) + 31408, 9);
    Frame();
    PF(Row(4) + 31408, NAN);
    Frame();
    CHECK(GF(Row(4) + 31408) == 9 && mom.pendingSet[4] && mom.pending[4] == 9 && G8(UNAPPLIED) == 1);
    PF(Row(4) + 31408, 3);
    Frame();
    CHECK(G8(UNAPPLIED) == 0 && g_changeCount == 3);
    /* A slider the game keeps at NaN is set back once, not on every frame: the MODS frame budget holds (two reads). */
    w.sliderNaN = 1;
    w.sliders = 0;
    PF(Row(3) + 31408, NAN);
    w.visualMode = VISUAL_COUNT;
    CHECK_EQ(Reads(200), 400);
    w.visualMode = VISUAL_EMULATE;
    CHECK(w.sliders == 1);
    CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0 && Near(vpm_option_value(g_alpha[3]), 0.75));
    w.sliderNaN = 0;
    PF(Row(3) + 31408, 0.75f);
    Frame();
    CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0 && g_changeCount == 3);
}

/* Hovering Fire Mode shows its two-line description; Level has none, so the box hides, and an unchanged selection
 * costs nothing. No row selected: the game's own pass hides the box (setting 156); selecting Fire Mode again brings
 * MOM's text back over the game's hide. */
static void DescriptionsFollowTheSelection(void)
{
    int boxes = w.boxes;
    P32(Panel(0) + 2872, 1);
    Frame();
    CHECK(w.boxes == boxes + 1 && G8(w.box + 2672) == 0);
    CHECK(Shows(w.title, "Fire Mode") && Shows(w.body, MODE));
    CHECK(GF(w.body + 8) == -20 - 24 && GF(w.frame + 16) == 40 + 20 + 7 + 72);
    P32(Panel(0) + 2872, 2);
    Frame();
    CHECK(w.boxes == boxes + 2 && G8(w.box + 2672) == 1 && w.lastBox[1] == 1);
    Frame();
    CHECK(w.boxes == boxes + 2);
    P32(Panel(0) + 2872, 0x7FFFFFFFu);
    Frame();
    CHECK(G32(DESCRIBED) == 156 && G8(w.box + 2672) == 1);
    P32(Panel(0) + 2872, 1);
    Frame();
    CHECK(G32(DESCRIBED) == 139 && G8(w.box + 2672) == 0 && Shows(w.body, MODE));
}

/* The player edits Extra 1, then picks BETA: the game deactivates GAMEPLAY and builds DISPLAY, and MOM replaces its
 * rows. The edit survives; the DISPLAY reload and a native rebuild are replaced; a registration while open refreshes. */
static VpmOption* PagesFollowTheButtons(void)
{
    P32(Row(5) + 29068, 1);
    Frame();
    PickCategory(0, 1);
    Frame();
    CHECK(mom.view.page.index == 1 && G32(Panel(1) + 33256) == 1);
    CHECK(Shows(Row(0) + 3992, "Enabled") && G32(Row(0) + 31428) == 139);
    CHECK(Children(Panel(1) + 544) == 1 && Children(Panel(0) + 544) == 0);
    CHECK(G8(w.box + 2672) == 1 && w.lastBox[0] == 1); /* Enabled has no description */
    CHECK(G8(UNAPPLIED) == 1 && vpm_option_value(g_alpha[5]) == 0);
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK(G8(UNAPPLIED) == 0 && vpm_option_value(g_alpha[5]) == 1 && w.sounds == 2);
    int released = w.released;
    P32(Row(0) + 29072, 10);
    Frame();
    CHECK(w.released == released + 32 && G32(Row(0) + 29072) == 2 && Shows(Row(0) + 3992, "Enabled"));
    P32(Row(0) + 29080, 0x12345678u);
    Frame();
    CHECK(w.released == released + 64 && G32(Row(0) + 29080) == OFF_LABEL && Children(Panel(1) + 544) == 1);
    NativeBuild(1);
    Frame();
    CHECK(G32(Panel(1) + 33256) == 1 && Shows(Row(0) + 3992, "Enabled") && Children(Panel(1) + 544) == 1);
    VpmOption* speed = vpm_option(fake_component(1), &kBetaSpeed);
    CHECK(speed != NULL);
    Frame();
    CHECK(G32(Panel(1) + 33256) == 2 && Shows(Row(1) + 3992, "Speed"));
    return speed;
}

/* Per frame with the MODS tab open and nothing changing: two reads (the UI stack, the screen pointer); the tab, page
 * check, value polls and selection are plain loads; one visual pass, no description work. With an edit pending, the
 * dialog and apply-key checks are plain loads too. */
static void ModsFrameBudget(VpmOption* speed)
{
    int boxes = w.boxes, visuals = w.visuals;
    w.visualMode = VISUAL_COUNT;
    CHECK_EQ(Reads(200), 400);
    CHECK(w.visuals == visuals + 200 && w.boxes == boxes);
    PF(Row(1) + 31408, 4);
    Frame();
    CHECK_EQ(Reads(200), 400);
    w.visualMode = VISUAL_EMULATE;
    CHECK(G8(UNAPPLIED) == 1 && vpm_option_value(speed) == 1);
    PF(Row(1) + 31408, 1);
    Frame();
    CHECK(G8(UNAPPLIED) == 0);
}

/* Q back to OPTIONS with Speed's description shown: everything goes back to the game. Reopening MODS from GAMEPLAY
 * builds page 0 afresh; closing the escape menu drops the view and its edit. */
static void LeavesAndComesBack(void)
{
    P32(Panel(1) + 33296, 1);
    Frame();
    CHECK(G8(w.box + 2672) == 0 && Shows(w.title, "Speed") && Shows(w.body, "Sets the speed."));
    int visuals = w.visuals;
    P32(w.bar + 57452, 2);
    Frame();
    CHECK(!mom.hasView && w.visuals == visuals);
    CHECK_LOG("Closed MODS tab.");
    CHECK(G8(w.box + 2672) == 1 && w.lastBox[0] == 1 && w.lastBox[1] == 0);
    CHECK(G8(w.title + 616) == 0 && G8(w.body + 616) == 0);
    HandedBack();
    CHECK(Visible(Row(10)) && Children(Panel(7) + 544) == 11);
    /* With the escape menu open on another tab: the same two reads, no visual pass. */
    CHECK_EQ(Reads(200), 400);
    CHECK(w.visuals == visuals);
    PickCategory(7, 0);
    SelectMods();
    Frame();
    CHECK(mom.hasView && mom.view.page.index == 0 && G32(Panel(0) + 2832) == 15);
    CHECK(w.visuals == visuals + 2 && G8(w.box + 2672) == 0 && Shows(w.body, MODE));
    CHECK(G32(Row(5) + 29068) == 1); /* the applied Extra 1 */
    P32(Row(6) + 29068, 1);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && mom.pendingCount == 1);
    SetStack(0, 0, 0);
    Frame();
    CHECK(!mom.hasView && w.visuals == visuals + 3 && mom.pendingCount == 0 && vpm_option_value(g_alpha[6]) == 0);
    CHECK_LOG("Escape menu closed on the MODS tab.");
    /* The escape menu closed (most of every session): one read (the UI stack; its pointer is a plain load). Covered by
     * another screen: the same. */
    CHECK_EQ(Reads(200), 200);
    SetStack(2, 1, 5);
    CHECK_EQ(Reads(200), 200);
    CHECK(w.visuals == visuals + 3);
}

static void TheModsTab(void)
{
    Ready(kDefs, 4);
    OpensTheModsTab();
    AppliesEdits();
    TheUnappliedChangesDialog();
    RefusesValuesTheOptionCannotTake();
    DescriptionsFollowTheSelection();
    VpmOption* speed = PagesFollowTheButtons();
    ModsFrameBudget(speed);
    LeavesAndComesBack();
}

/* Reported 2026-10-18: escape menu opened on GAME, straight to MODS, then OPTIONS: GAMEPLAY with category labels drawn
 * over it. The first visual pass of an open ran on MODS with those buttons hidden, so they kept (0, 0). Run both ways:
 * without MOM's layout pass before hiding (the report reproduced), then as released. */
static void GameThenModsThenOptions(int skipLayoutFirst, int* placed)
{
    SetStack(1, 1, 0);
    P32(w.bar + 57448, 3);
    P32(w.bar + 57452, 0);
    for (uint32_t i = 0; i < 3; i++) P32(w.bar + 57320 + 4 * i, kTabLabels[i]);
    P32(w.screen + 8, 0);
    P8(w.content + 1319445, 1);
    for (int i = 0; i < 9; i++)
    {
        SetVisible(Button(i), 1);
        TextInit(Button(i) + 1928);
        P32(Button(i) + 1928 + 272, kCategoryLabels[i]);
        PF(Button(i) + 8, 0);
    }
    w.layoutDirty = 1;
    Frame();
    CHECK(!mom.hasView && G32(w.bar + 57448) == 4);
    if (skipLayoutFirst) w.visualMode = VISUAL_LATE;
    P32(w.bar + 57452, 3);
    P32(w.screen + 8, 3);
    Frame();
    CHECK(mom.hasView);
    for (int i = 3; i < 9; i++) CHECK(!Visible(Button(i)));
    fake_frames(3, DT);
    P32(w.bar + 57452, 2);
    Frame();
    CHECK(!mom.hasView);
    w.visualMode = VISUAL_EMULATE;
    FakeOptionsVisual(w.content, DT); /* the game runs its own OPTIONS pass from then on */
    for (int i = 0; i < 9; i++)
    {
        CHECK(Visible(Button(i)) && G32(Button(i) + 1928 + 272) == kCategoryLabels[i]);
        placed[i] = GF(Button(i) + 8) == -64.0f * (float)i;
    }
    SetStack(0, 0, 0);
    Frame();
}

static const VpmComponentDef* const kThreeDefs[] = {&kAlpha, &kBeta, &vpm_component_mod_options_menu};

static void CategoriesStayInPlace(void)
{
    Ready(kThreeDefs, 3);
    int placed[9];
    GameThenModsThenOptions(1, placed);
    for (int i = 0; i < 3; i++) CHECK(placed[i]);
    for (int i = 3; i < 9; i++) CHECK(!placed[i]); /* the report reproduces without the layout pass */
    GameThenModsThenOptions(0, placed);
    for (int i = 0; i < 9; i++) CHECK(placed[i]);
}

/* ---- Shallow Water Diving's slider ---------------------------------------------------------------------------------- */

#define DEPTH_TEXT "Deepest water, measured up from your feet, that a dive can start in: from 0.20 (lower shin, the " \
    "original limit) up to 1.30, where your Helldiver starts swimming. Deeper water always keeps the game's normal behavior."
static const VpmOptionDef kDepth = {"max_water_depth", VPM_SLIDER, "Max Dive Water Depth", DEPTH_TEXT, 0.20, 0.20, 1.30,
    0.05, NULL, 0};
static VpmOption* g_depth;
static int DivingStart(VpmComponent* self) { return (g_depth = vpm_option(self, &kDepth)) == NULL; }
static const VpmComponentDef kDiving = {"shallow_water_diving", "Shallow Water Diving", "3.10.1", 0, DivingStart, NULL};
static const VpmComponentDef* const kDivingDefs[] = {&kDiving, &vpm_component_mod_options_menu};

/* Two decimals (0.05 steps from 0.20), shown as a float slider; the core keeps the value rounded to those decimals,
 * so an edit back to it, as the row holds it, withdraws. */
static void SlidersAsShallowWaterDivingRegistersThem(void)
{
    Ready(kDivingDefs, 2);
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
    CHECK(Shows(Button(0) + 1928, "SHALLOW WATER DIVING") && Shows(Row(0) + 3992, "Max Dive Water Depth"));
    CHECK(G32(Row(0) + 31424) == 1 && G32(Row(0) + 20004) == 0x6220 && GF(Row(0) + 31408) == 0.2f);
    CHECK(GF(Row(0) + 31396) == 0.2f && GF(Row(0) + 31400) == 1.3f && Shows(w.body, DEPTH_TEXT));
    PF(Row(0) + 31408, 0.62f);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && Near(vpm_option_value(g_depth), 0.2));
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK(G8(UNAPPLIED) == 0 && Near(vpm_option_value(g_depth), 0.6));
    const char* saved = vpm_setting("options", "shallow_water_diving.max_water_depth");
    CHECK(saved != NULL && strcmp(saved, "0.6") == 0);
    PF(Row(0) + 31408, 0.6f);
    Frame();
    CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0);
    PF(Row(0) + 31408, 1.3f);
    Frame();
    CHECK(mom.pendingCount == 1);
    PF(Row(0) + 31408, 0.6000001f);
    Frame();
    CHECK(mom.pendingCount == 0 && G8(UNAPPLIED) == 0);
}

/* ---- more than 8 categories (test_options_tab.lua's pages, test_categories.lua's order) ----------------------------- */

static int PageStart(VpmComponent* self);
#define PAGE(n) {"page" #n, "Page Mod " #n, "1.0", 0, PageStart, NULL}
static const VpmComponentDef kPages[21] = {PAGE(001), PAGE(002), PAGE(003), PAGE(004), PAGE(005), PAGE(006), PAGE(007),
    PAGE(008), PAGE(009), PAGE(010), PAGE(011), PAGE(012), PAGE(013), PAGE(014), PAGE(015), PAGE(016), PAGE(017),
    PAGE(018), PAGE(019), PAGE(020), PAGE(021)};
#define PAGE_TOGGLE(n) {"toggle", VPM_TOGGLE, "Toggle " #n, NULL, 0, 0, 0, 0, NULL, 0}
static const VpmOptionDef kPageToggles[21] = {PAGE_TOGGLE(1), PAGE_TOGGLE(2), PAGE_TOGGLE(3), PAGE_TOGGLE(4),
    PAGE_TOGGLE(5), PAGE_TOGGLE(6), PAGE_TOGGLE(7), PAGE_TOGGLE(8), PAGE_TOGGLE(9), PAGE_TOGGLE(10), PAGE_TOGGLE(11),
    PAGE_TOGGLE(12), PAGE_TOGGLE(13), PAGE_TOGGLE(14), PAGE_TOGGLE(15), PAGE_TOGGLE(16), PAGE_TOGGLE(17),
    PAGE_TOGGLE(18), PAGE_TOGGLE(19), PAGE_TOGGLE(20), PAGE_TOGGLE(21)};
static const VpmOptionDef kPageLevel = {"level", VPM_SLIDER, "Level", NULL, 0, 0, 4, 1, NULL, 0};
static VpmOption* g_pageLevel;

/* Pages 1 to 19 register a toggle at start (17 a slider too); 20 and 21 register theirs while the tab is open. */
static int PageStart(VpmComponent* self)
{
    int n = 0;
    for (int i = 0; i < 21; i++)
        if (vpm_def(self) == &kPages[i]) n = i + 1;
    if (n == 0 || n > 19) return 0;
    if (vpm_option(self, &kPageToggles[n - 1]) == NULL) return 1;
    if (n == 17 && (g_pageLevel = vpm_option(self, &kPageLevel)) == NULL) return 1;
    return 0;
}

/* Registered out of order; shown alphabetically: PAGE MOD 001 .. 019, then VANILLA PLUS MEGAPACK (20 categories). */
static const VpmComponentDef* const kPageDefs[22] = {&kPages[18], &kPages[0], &kPages[17], &kPages[1], &kPages[16],
    &kPages[2], &kPages[15], &kPages[3], &kPages[14], &kPages[4], &kPages[13], &kPages[5], &kPages[12], &kPages[6],
    &kPages[11], &kPages[7], &kPages[10], &kPages[8], &kPages[9], &kPages[19], &kPages[20], &vpm_component_mod_options_menu};

static void PageLabels(int first, int count)
{
    for (int i = 0; i < count; i++)
    {
        char name[32];
        snprintf(name, sizeof name, "PAGE MOD %03d", first + i);
        CHECK(Visible(Button(i)) && Shows(Button(i) + 1928, name));
    }
}

static void TurnPageRow(uint32_t index)
{
    P32(Row(0) + 29068, index);
    P32(Row(0) + 16832 + 272, TEMPLATE);
    Frame();
}

/* The page control's panel: one selector row naming the pages. Turning it relabels the buttons and nothing else. */
static void ThePageControl(void)
{
    PickCategory(0, 7);
    Frame();
    CHECK(mom.view.page.index == 7 && G32(Panel(7) + 2832) == 1 && Children(Panel(7) + 544) == 1);
    CHECK(G32(Row(0) + 31428) == 139 && Shows(Row(0) + 3992, "Mods Page") && G32(Row(0) + 29072) == 3);
    CHECK(G32(Row(0) + 29068) == 0 && Shows(Row(0) + 16832, "1 / 3"));
    const char* body = Argument(w.body);
    CHECK(G8(w.box + 2672) == 0 && Shows(w.title, "Mods Page") && body != NULL && strstr(body, "7 mods at a time") != NULL);
    int selects = w.selects, released = w.released, choices = w.choices;
    TurnPageRow(1);
    PageLabels(8, 7);
    CHECK(Shows(Button(7) + 1928, "PAGE 2 OF 3") && Shows(Row(0) + 16832, "2 / 3"));
    CHECK(w.selects == selects && w.released == released && w.choices == choices && G32(w.content + 1318488) == 7);
    CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0 && mom.modsPage == 1);
    CHECK_LOG("Showing mods page 2 of 3.");
    /* The last page: five page mods and the pack's category; the 7th button hides. */
    TurnPageRow(2);
    PageLabels(15, 5);
    CHECK(Shows(Button(5) + 1928, "VANILLA PLUS MEGAPACK"));
    CHECK(!Visible(Button(6)) && Visible(Button(7)) && Shows(Button(7) + 1928, "PAGE 3 OF 3"));
    /* The hidden button holds no category: were it selected, MOM goes to the first button. */
    PickCategory(7, 6);
    Frame();
    CHECK(mom.view.page.index == 0 && G32(w.content + 1318488) == 0 && Shows(Row(0) + 3992, "Toggle 15"));
    PickCategory(0, 7);
    Frame();
    CHECK(mom.view.page.index == 7 && G32(Row(0) + 29068) == 2 && Shows(Row(0) + 16832, "3 / 3"));
}

/* A category of that page, edited and applied as on any page; an edit stays pending across page turns; discarding it
 * on the page control's panel keeps the page row's page; a page past the pages is refused. */
static void EditsAcrossPages(void)
{
    PickCategory(7, 2);
    Frame();
    CHECK(mom.view.page.index == 2 && Shows(Row(0) + 3992, "Toggle 17") && Shows(Row(1) + 3992, "Level"));
    PF(Row(1) + 31408, 3);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && vpm_option_value(g_pageLevel) == 0);
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK(G8(UNAPPLIED) == 0 && vpm_option_value(g_pageLevel) == 3);
    PF(Row(1) + 31408, 1);
    Frame();
    PickCategory(2, 7);
    Frame();
    CHECK(G32(Row(0) + 29068) == 2 && Shows(Row(0) + 16832, "3 / 3") && G8(UNAPPLIED) == 1);
    TurnPageRow(0);
    PageLabels(1, 7);
    CHECK(G8(UNAPPLIED) == 1 && mom.pendingCount == 1);
    SetDialog(2);
    Frame();
    GameAnswers(SELECT);
    Frame();
    SetDialog(0);
    CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0 && vpm_option_value(g_pageLevel) == 3);
    CHECK(G32(Row(0) + 29068) == 0 && Shows(Row(0) + 16832, "1 / 3"));
    PageLabels(1, 7);
    P32(Row(0) + 29068, 5);
    Frame();
    CHECK(G32(Row(0) + 29068) == 0 && mom.modsPage == 0);
    PageLabels(1, 7);
    w.visualMode = VISUAL_COUNT; /* per frame on the page control's panel: the MODS budget */
    CHECK_EQ(Reads(200), 400);
    w.visualMode = VISUAL_EMULATE;
}

static void PagesOfCategories(void)
{
    Ready(kPageDefs, 22);
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
    CHECK(mom.hasView && mom.view.page.index == 0 && Shows(Row(0) + 3992, "Toggle 1"));
    PageLabels(1, 7);
    CHECK(Visible(Button(7)) && Shows(Button(7) + 1928, "PAGE 1 OF 3") && !Visible(Button(8)));
    ThePageControl();
    EditsAcrossPages();
    /* Leaving the tab and coming back shows the page last shown, from its first category. */
    TurnPageRow(1);
    P32(w.bar + 57452, 2);
    Frame();
    CHECK(!mom.hasView && G32(Button(7) + 1928 + 272) == kCategoryLabels[7] && Visible(Button(8)));
    SelectMods();
    Frame();
    CHECK(mom.view.page.index == 0 && Shows(Row(0) + 3992, "Toggle 8"));
    PageLabels(8, 7);
    CHECK(Shows(Button(7) + 1928, "PAGE 2 OF 3"));
    /* Registrations while open: a 21st category still fits 3 pages; a 22nd makes a 4th. The page shown stays. */
    CHECK(vpm_option(fake_component(19), &kPageToggles[19]) != NULL);
    Frame();
    CHECK(Shows(Button(7) + 1928, "PAGE 2 OF 3"));
    CHECK(vpm_option(fake_component(20), &kPageToggles[20]) != NULL);
    Frame();
    PageLabels(8, 7);
    CHECK(Shows(Button(7) + 1928, "PAGE 2 OF 4"));
    PickCategory(0, 7);
    Frame();
    CHECK(G32(Row(0) + 29072) == 4 && G32(Row(0) + 29068) == 1 && Shows(Row(0) + 16832, "2 / 4"));
    SetStack(0, 0, 0);
    Frame();
    CHECK(!mom.hasView);
}

/* ---- new on HellForge: the pack's switches ------------------------------------------------------------------------- */

/* VANILLA PLUS MEGAPACK lists a switch per component (Zulu switched off in the settings file: it did not start and
 * registered nothing). Applied, a switch is saved and the core applies it at the next frame: Beta stops, Zulu starts and
 * its options join the tab. Mod Options Menu's own switch applies from the next session, and its row says why. */
static void ThePacksSwitches(void)
{
    FILE* file = fopen("vpm-test-settings.ini", "w");
    CHECK(file != NULL);
    if (file != NULL) { fputs("[components]\nzulu = off\n", file); fclose(file); }
    Ready(kDefs, 4);
    CHECK(!vpm_running(fake_component(2)));
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
    CHECK(Shows(Button(0) + 1928, "ALPHA MOD") && Shows(Button(1) + 1928, "BETA"));
    CHECK(Shows(Button(2) + 1928, "VANILLA PLUS MEGAPACK") && !Visible(Button(3)));
    PickCategory(0, 2);
    Frame();
    static const char* const names[] = {"Alpha Mod", "Beta", "Zulu", "Mod Options Menu"};
    static const uint32_t on[] = {1, 1, 0, 1};
    CHECK_EQ(G32(Panel(2) + 33256), 4 + 2); /* the switches, then the pack's own options */
    for (int i = 0; i < 4; i++)
    {
        CHECK(Shows(Row(i) + 3992, names[i]) && G32(Row(i) + 29068) == on[i]);
        CHECK(G32(Row(i) + 29080) == OFF_LABEL && G32(Row(i) + 29084) == ON_LABEL);
    }
    CHECK(Shows(Row(4) + 3992, "Diagnostics") && G32(Row(4) + 29068) == 0); /* Normal */
    CHECK(Shows(Row(5) + 3992, "Note a problem now") && G32(Row(5) + 29068) == 0);
    P32(Panel(2) + 33296, 1);
    Frame();
    CHECK(Shows(w.title, "Beta") && Shows(w.body, "Switches Beta on or off at once."));
    P32(Panel(2) + 33296, 3);
    Frame();
    CHECK(Shows(w.body, "Switches Mod Options Menu on or off. Applies from the next session: it draws this menu, and the "
        "game's menu would keep its MODS tab without it."));
    P32(Panel(2) + 33296, 1);
    Frame();
    P32(Row(1) + 29068, 0);
    P32(Row(2) + 29068, 1);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && vpm_component_switched_on(fake_component(1)));
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK(G8(UNAPPLIED) == 0 && !vpm_component_switched_on(fake_component(1)) && vpm_component_switched_on(fake_component(2)));
    CHECK_LOG("Applied 2 option changes.");
    CHECK(SettingsFileHas("beta = off") && SettingsFileHas("zulu = on")); /* written at once */
    const char* beta = vpm_setting("components", "beta");
    const char* zulu = vpm_setting("components", "zulu");
    CHECK(beta != NULL && strcmp(beta, "off") == 0 && zulu != NULL && strcmp(zulu, "on") == 0);
    CHECK(vpm_running(fake_component(1)) && !vpm_running(fake_component(2))); /* applied at the next frame */
    Frame();
    CHECK(!vpm_running(fake_component(1)) && vpm_running(fake_component(2)));
    CHECK_LOG("[Beta] switched off: stopped");
    CHECK_LOG("[Zulu] switched on: running");
    CHECK(Shows(Button(3) + 1928, "ZULU")); /* its options, registered by the live start */
    PickCategory(0, 2);
    Frame();
    P32(Row(1) + 29068, 1);
    Frame();
    CHECK(G8(UNAPPLIED) == 1);
    P32(Row(1) + 29068, 0);
    Frame();
    CHECK(G8(UNAPPLIED) == 0);
    fake_frames(70, DT);
    CHECK(SettingsFileHas("beta = off") && SettingsFileHas("zulu = on"));
    /* The pack's "Note a problem now": switched on and applied, it writes a mark and its row goes back off. */
    P32(Row(5) + 29068, 1);
    Frame();
    CHECK(G8(UNAPPLIED) == 1);
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK_LOG("[core] MARK 1 at ");
    CHECK_LOG("[core] MARK 1: Zulu: running");
    CHECK_NO_LOG("[core] MARK 1: Beta: running");
    Frame();
    CHECK(G8(UNAPPLIED) == 0 && G32(Row(5) + 29068) == 0);
}

/* ---- values set from code (test_options_tab.lua's set()) ---------------------------------------------------------- */

static VpmOption* OptionOf(const VpmOptionDef* def)
{
    for (int i = 0; i < vpm_option_count(); i++)
        if (vpm_option_def(vpm_option_at(i)) == def) return vpm_option_at(i);
    return NULL;
}

/* An on_change that sets another option from code, as a mod keeping two options in step would. */
static void SetsCount(VpmComponent* self, VpmOption* option, double value) { (void)vpm_option_set(g_alpha[4], 5); }

static void OpenTheModsTab(void)
{
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
}

/* A value set from code replaces the player's unapplied edit of that option and shows on its row from the next step,
 * without on_change; the set writes no row itself, nor does an option on another page. That frame keeps the MODS budget
 * (two reads), and the frames after it write nothing; neither do the frames after the player's own apply. A value an
 * on_change sets shows the same way. With the escape menu closed nothing is written; the reopened page shows it. */
static void ValuesSetFromCodeShowOnTheOpenRows(void)
{
    Ready(kDefs, 4);
    OpenTheModsTab();
    CHECK(mom.hasView && GF(Row(4) + 31408) == 3);
    PF(Row(4) + 31408, 9);
    Frame();
    CHECK(G8(UNAPPLIED) == 1 && mom.pendingCount == 1);
    int sliders = w.sliders, choices = w.choices;
    VpmOption* zulu = OptionOf(&kZuluDefs[0]);
    CHECK(zulu != NULL && vpm_option_set(g_alpha[4], 7.4) && vpm_option_set(zulu, 1));
    CHECK(vpm_option_value(g_alpha[4]) == 7 && GF(Row(4) + 31408) == 9 && w.sliders == sliders);
    CHECK_EQ(Reads(1), 2);
    CHECK(w.sliders == sliders + 1 && w.choices == choices && GF(Row(4) + 31408) == 7);
    CHECK(G8(UNAPPLIED) == 0 && mom.pendingCount == 0 && g_changeCount == 0);
    CHECK_EQ(Reads(200), 400);
    CHECK(w.sliders == sliders + 1 && w.choices == choices);
    /* A toggle and a choice on the page; the same value again counts as no change and writes nothing. */
    CHECK(vpm_option_set(g_alpha[0], 0) && vpm_option_set(g_alpha[1], 3));
    Frame();
    CHECK(G32(Row(0) + 29068) == 0 && G32(Row(1) + 29068) == 2 && Shows(Row(1) + 16832, "AUTO"));
    choices = w.choices;
    CHECK(vpm_option_set(g_alpha[0], 0));
    Frame();
    CHECK(w.choices == choices && g_changeCount == 0);
    /* The player's apply: its rows already show the applied values. Its on_change setting Count from code: that row
     * shows 5 from the next step. */
    vpm_option_on_change(g_alpha[0], SetsCount);
    P32(Row(0) + 29068, 1);
    Frame();
    Press(APPLY);
    Frame();
    ReleaseKeys();
    CHECK(vpm_option_value(g_alpha[0]) == 1 && vpm_option_value(g_alpha[4]) == 5 && GF(Row(4) + 31408) == 7);
    sliders = w.sliders;
    choices = w.choices;
    Frame();
    CHECK(w.sliders == sliders + 1 && w.choices == choices && GF(Row(4) + 31408) == 5 && G8(UNAPPLIED) == 0);
    Frame();
    CHECK(w.sliders == sliders + 1 && w.choices == choices);
    vpm_option_on_change(g_alpha[0], Changed);
    /* Set while the tab is open, saved at once when the player leaves it (as the Lua's leave_view). */
    CHECK(vpm_option_set(g_alpha[2], 2));
    CHECK(!SettingsFileHas("alpha.level = 2"));
    P32(w.bar + 57452, 2);
    Frame();
    CHECK(!mom.hasView && SettingsFileHas("alpha.level = 2"));
    /* The escape menu closed: a set writes no row; the reopened page shows it. */
    SetStack(0, 0, 0);
    Frame();
    sliders = w.sliders;
    CHECK(vpm_option_set(g_alpha[4], 2));
    Frame();
    CHECK(w.sliders == sliders);
    OpenTheModsTab();
    CHECK(mom.hasView && mom.view.page.index == 0 && GF(Row(4) + 31408) == 2 && G32(Row(2) + 29068) == 1);
}

/* ---- new on HellForge: options the core accepts that the tab cannot show -------------------------------------------- */

#define X10 "xxxxxxxxxx"
#define X100 X10 X10 X10 X10 X10 X10 X10 X10 X10 X10
#define CJK10 "\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80\xE4\xB8\x80"
static const char* const kOne[] = {"A", NULL};
static const char* const kSeventeen[] = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", NULL};
static const VpmOptionDef kOddDefs[] = {
    {"kept", VPM_TOGGLE, "Kept", NULL, 0, 0, 0, 0, NULL, 0},
    {"one", VPM_CHOICE, "One", NULL, 1, 0, 0, 0, kOne, 0},
    {"seventeen", VPM_CHOICE, "Seventeen", NULL, 1, 0, 0, 0, kSeventeen, 0},
    {"fine", VPM_SLIDER, "Fine", NULL, 0, 0, 1, 1e-39, NULL, 0},
    {"wide", VPM_SLIDER, "Wide", NULL, 0, 0, 3.5e38, 1, NULL, 0},
    {"coarse", VPM_SLIDER, "Coarse", NULL, 0, 0, 1, 2, NULL, 0},
    {"long", VPM_TOGGLE, X10 X10 X10 X10 X10 X10 "xxxxx", NULL, 0, 0, 0, 0, NULL, 0},
    {"cjk", VPM_TOGGLE, CJK10 CJK10 CJK10 CJK10 CJK10 CJK10, NULL, 0, 0, 0, 0, NULL, 0}, /* 60 characters, 180 bytes: fits */
    {"wordy", VPM_TOGGLE, "Wordy", X100 X100 X100 X100 "x", 0, 0, 0, 0, NULL, 0},
    {"blank", VPM_TOGGLE, "Blank", " \n ", 0, 0, 0, 0, NULL, 0},
    {"bytes", VPM_TOGGLE, "bad \xFF bytes", NULL, 0, 0, 0, 0, NULL, 0},
};
#define ODD_COUNT ((int)(sizeof kOddDefs / sizeof kOddDefs[0]))
static const VpmOptionDef kOddLate = {"late", VPM_TOGGLE, "Late", NULL, 0, 0, 0, 0, NULL, 0};

/* Every definition is offered; the core refuses the ones its registration checks catch (they return NULL). */
static int OddStart(VpmComponent* self)
{
    for (int i = 0; i < ODD_COUNT; i++) (void)vpm_option(self, &kOddDefs[i]);
    return 0;
}

static VpmOptionDef g_manyDefs[33];
static char g_manyNames[33][2][16];
static int ManyStart(VpmComponent* self)
{
    for (int i = 0; i < 33; i++)
    {
        snprintf(g_manyNames[i][0], 16, "t%d", i + 1);
        snprintf(g_manyNames[i][1], 16, "Many %d", i + 1);
        g_manyDefs[i] = (VpmOptionDef){g_manyNames[i][0], VPM_TOGGLE, g_manyNames[i][1], NULL, 0, 0, 0, 0, NULL, 0};
        if (vpm_option(self, &g_manyDefs[i]) == NULL && i < 32) return 1;
    }
    return 0;
}

static const VpmComponentDef kOdd = {"odd", "Odd", "1.0", 0, OddStart, NULL};
static const VpmComponentDef kMany = {"many", "Many", "1.0", 0, ManyStart, NULL};
static const VpmComponentDef* const kOddDefsList[] = {&kOdd, &kMany, &vpm_component_mod_options_menu};

/* As the Lua's register_option refused them (lengths in characters, 2 to 16 choices, a range a float can hold, 32
 * options a category): the core refuses them at registration, and the tab leaves out the texts it cannot show (a blank
 * description, bytes that are not UTF-8); each is logged once. */
static void OptionsTheTabCannotShow(void)
{
    static const char* const reasons[] = {
        "[Odd] option one refused: choices must list 2 to 16 names",
        "[Odd] option seventeen refused: choices must list 2 to 16 names",
        "[Odd] option fine refused: slider min, max and step must be finite floats",
        "[Odd] option wide refused: slider min, max and step must be finite floats",
        "[Odd] option coarse refused: slider needs min < max and 0 < step <= max - min",
        "[Odd] option long refused: invalid option registration",
        "[Odd] option wordy refused: invalid description",
        "Option odd.blank is not shown: invalid description.",
        "Option odd.bytes is not shown: invalid option registration.",
        "[Many] option many.t33 refused: the component already has 32 options",
    };
    Ready(kOddDefsList, 3);
    CHECK(vpm_running(fake_component(0)) && vpm_running(fake_component(1)));
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
    CHECK(Shows(Button(0) + 1928, "MANY") && Shows(Button(1) + 1928, "ODD"));
    CHECK_EQ(G32(Panel(0) + 2832), 32);
    CHECK(Shows(Row(31) + 3992, "Many 32"));
    PickCategory(0, 1);
    Frame();
    CHECK_EQ(G32(Panel(1) + 33256), 2);
    CHECK(Shows(Row(0) + 3992, "Kept") && Shows(Row(1) + 3992, CJK10 CJK10 CJK10 CJK10 CJK10 CJK10));
    for (int i = 0; i < 10; i++) CHECK_EQ(LogCount(reasons[i]), 1);
    /* A registration while open rebuilds the model: the refusals are not logged again. */
    CHECK(vpm_option(fake_component(0), &kOddLate) != NULL);
    Frame();
    CHECK(G32(Panel(1) + 33256) == 3 && Shows(Row(2) + 3992, "Late"));
    for (int i = 0; i < 10; i++) CHECK_EQ(LogCount(reasons[i]), 1);
}

/* ---- stop(): the view goes back to the game ------------------------------------------------------------------------- */

static void OpenWithAnEdit(void)
{
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
    P32(Row(0) + 29068, 0);
    Frame();
    CHECK(mom.hasView && mom.pendingCount == 1 && G8(UNAPPLIED) == 1);
}

/* The core stopping the component (a fault, vpm_fail) hands an open view back as on leaving the tab, as the Lua's
 * update guard did when it stopped; the edit is dropped and nothing ticks any more. A covered menu is not touched: the
 * view is only dropped. */
static void StopHandsTheViewBack(void)
{
    Ready(kDefs, 4);
    OpenWithAnEdit();
    vpm_core_stop(fake_component(MOM_INDEX), "test");
    CHECK_LOG("Closed MODS tab.");
    HandedBack();
    CHECK(vpm_option_value(g_alpha[0]) == 1);
    CHECK_EQ(Reads(100), 0);
    fake_setup();
    Ready(kDefs, 4);
    OpenWithAnEdit();
    SetStack(2, 1, 5);
    Frame();
    CHECK(mom.hasView); /* a covered menu keeps its view */
    vpm_core_stop(fake_component(MOM_INDEX), "test");
    CHECK(!mom.hasView && mom.pendingCount == 0 && G8(UNAPPLIED) == 1 && G32(Row(0) + 31428) == 139);
    CHECK_NO_LOG("Closed MODS tab.");
}

/* ---- category names in upper case in every script (the Lua's T.upper) ---------------------------------------------- */

static const VpmOptionDef kPlain = {"on", VPM_TOGGLE, "On", NULL, 0, 0, 0, 0, NULL, 0};
static int PlainStart(VpmComponent* self) { return vpm_option(self, &kPlain) == NULL; }
static const VpmComponentDef kCyrillic = {"cyrillic", "\xD0\xBF\xD0\xBB\xD0\xB0\xD0\xB2", "1.0", 0, PlainStart, NULL};
static const VpmComponentDef kLatin = {"latin", "Caf\xC3\xA9 Mod", "1.0", 0, PlainStart, NULL};
static const VpmComponentDef* const kScriptDefs[] = {&kCyrillic, &kLatin, &vpm_component_mod_options_menu};

static void UpperCaseInEveryScript(void)
{
    Ready(kScriptDefs, 3);
    MenuOnOptions();
    Frame();
    SelectMods();
    Frame();
    CHECK(Shows(Button(0) + 1928, "CAF\xC3\x89 MOD") && Shows(Button(1) + 1928, "VANILLA PLUS MEGAPACK"));
    CHECK(Shows(Button(2) + 1928, "\xD0\x9F\xD0\x9B\xD0\x90\xD0\x92"));
}

int main(void)
{
    RUN(VerifiesTheGameOnce);
    RUN(StartsWhenTheMenuDataIsFilledInLater);
    RUN(RefusesAChangedGame);
    RUN(StartsOnceTheCodeIsDecoded);
    RUN(StoppedWhenTheCodeIsNeverDecoded);
    RUN(TheModsTab);
    RUN(CategoriesStayInPlace);
    RUN(SlidersAsShallowWaterDivingRegistersThem);
    RUN(PagesOfCategories);
    RUN(ThePacksSwitches);
    RUN(ValuesSetFromCodeShowOnTheOpenRows);
    RUN(OptionsTheTabCannotShow);
    RUN(StopHandsTheViewBack);
    RUN(UpperCaseInEveryScript);
    TEST_END();
}
