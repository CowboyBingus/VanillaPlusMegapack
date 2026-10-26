/* Mod Bindings Menu's panel for extended bindings: the binding pages' fifth tab, MORE MODS (the Lua's src/panel.lua).
 *
 * The game's list scrolls only over its own rows (each needing a native action), so the tab's native list holds one
 * section header row and the panel draws every extended binding below it, grouped under its section's header, scrolling
 * by whole rows. Only visible rows are drawn, with retained Gui primitives updated only when something shown changes.
 * Geometry: the list viewport (listing + 272) and the header row (listing + 7856) are native widgets whose solved
 * rectangles the game keeps at +148 (x) and +156 (y, the bottom edge; y grows upward), +36 and +40 (size) times the
 * scale at +100 and +140, +84 the opacity and flag 0x10 at +0 while visible. The panel draws only while both are
 * visible, opaque and sane, from the header row's bottom edge to the viewport's, across the header row's width.
 * Input: the game's UI actions (group 0 of the action states: 1 up and 2 down pressed, 5 and 6 held with the game's
 * repeat, 10 select), the menu system's cursor (its widget at menu + 1520, position at +620 while attached to the
 * root), the wheel and the left button from the engine's mouse. Select on a row starts a key capture
 * (mbm_capture.c); while it runs every active UI action is consumed each frame through the game's consume routine,
 * so Back, tab switching and the rest of the page ignore the keys being captured.
 * Drawing goes through MbmGui (mbm_engine.h); without one the tab is not offered (mbm_panel_available). */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "mbm.h"

#define MBM_VIEWPORT 272u
#define MBM_HEADER_ROW 7856u
#define MBM_WIDGET_BYTES 164u
#define MBM_CURSOR 1520u
#define MBM_CURSOR_PARENT 512u
#define MBM_CURSOR_BYTES 116u
#define MBM_ROOT_A 352u
#define MBM_ROOT_B 648u
#define MBM_UI_ACTIONS 11u
#define MBM_UP 1u
#define MBM_DOWN 2u
#define MBM_UP_HELD 5u
#define MBM_DOWN_HELD 6u
#define MBM_SELECT 10u
#define MBM_FONT_RVA 0x3772268u
#define MBM_MATERIAL_RVA 0x37C5478u
#define MBM_ATLAS_RVA 0x3772EE8u
#define MBM_WORLD_CHECK 1.0f
#define MBM_PITCH 62.0f /* UI units at scale 1: the game's rows are 62 apart */
#define MBM_GAP 3.0f
#define MBM_PADDING 24.0f
#define MBM_TEXT 22.0f
#define MBM_ACCENT 4.0f
#define MBM_BAR 6.0f
#define MBM_KEY_COLUMN 0.56f
#define MBM_WHEEL_ROWS 3
#define MBM_MAX_PANEL_ROWS (2 * MBM_MAX_RECORDS)
#define MBM_MAX_SLOTS 64

typedef struct MbmPanelRow { MbmRecord* record; int header; } MbmPanelRow;
typedef struct MbmSlot { uint32_t bg, mark, label, keys; } MbmSlot;
typedef struct MbmStyle { float layer; uint8_t colour[4]; } MbmStyle;

/* Layers sort across every Gui in a world, 0-1023 only. Colours {alpha, red, green, blue}. */
static const MbmStyle kMbmRow = {1011, {150, 14, 18, 26}}, kMbmFocus = {1011, {225, 44, 52, 64}};
static const MbmStyle kMbmHeader = {1011, {210, 6, 8, 12}}, kMbmAccent = {1012, {255, 255, 232, 0}};
static const MbmStyle kMbmTrack = {1011, {120, 60, 68, 80}}, kMbmThumb = {1012, {220, 200, 206, 212}};
static const uint8_t kMbmText[4] = {255, 240, 243, 245}, kMbmMuted[4] = {255, 128, 136, 144};
static const uint8_t kMbmHeading[4] = {255, 255, 232, 0}, kMbmCapture[4] = {255, 255, 232, 0};

static struct
{
    int open, dirty, model_valid, controller, count, first, focus, hover, guarding, select_was;
    uint32_t model;
    MbmRecord* focus_record;
    MbmPanelRow rows[MBM_MAX_PANEL_ROWS];
    int row_count;
    float left, right, top, bottom, scale;
    int cursor_valid, inside;
    float cursor_x, cursor_y, repeat_last[2], world_timer, open_wait;
    int drawn_valid, drawn_phase;
    MbmRecord* drawn_record;
    uint32_t drawn_bindings;
    int mouse_known, has_left, has_up, has_down;
    uint32_t mouse_left, wheel_up, wheel_down;
    MbmSlot slots[MBM_MAX_SLOTS];
    MbmSlot bar;
    int slots_used;
} s_panel;

static uint8_t g_mbmActions[MBM_GROUP_ACTIONS * MBM_ACTION_STRIDE]; /* the UI action states as read */

void mbm_panel_reset(void)
{
    memset(&s_panel, 0, sizeof s_panel);
    s_panel.focus = s_panel.hover = -1;
    s_panel.dirty = 1;
    s_panel.scale = 1;
}

int mbm_panel_available(void) { return mbm_engine_gui() != NULL && mbm_engine_input() != NULL; }

static float MbmF32(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }

/* A widget's solved rectangle (y up) and scale; 0 unless it is visible, opaque and sane. */
static int MbmSolved(const uint8_t* w, float* x, float* y, float* right, float* scale)
{
    uint32_t flags;
    memcpy(&flags, w, 4);
    float opacity = MbmF32(w + 84), sx = MbmF32(w + 100), sy = MbmF32(w + 140);
    if (!(flags & 0x10u) || !(opacity >= 0.995f && opacity <= 1.01f) || !(sx >= 0.3f && sx <= 4) || fabsf(sx - sy) > 0.01f) return 0;
    float px = MbmF32(w + 148), py = MbmF32(w + 156), width = MbmF32(w + 36) * sx, height = MbmF32(w + 40) * sy;
    if (!(px >= -16384 && px <= 32768 && py >= -16384 && py <= 32768 && width > 0 && width <= 32768 && height > 0 && height <= 32768))
        return 0;
    *x = px;
    *y = py;
    *right = px + width;
    *scale = sx;
    return 1;
}

/* The panel's area from the native widgets: 0 cannot be drawn, 1 unchanged, 2 moved (the panel redraws). */
static int MbmGeometry(uintptr_t listing)
{
    uint32_t page;
    uint8_t viewport[MBM_WIDGET_BYTES], row[MBM_WIDGET_BYTES];
    if (!vpm_read_u32(listing + MBM_CONTROLLER_PAGE, &page) || !vpm_read(listing + MBM_VIEWPORT, viewport, sizeof viewport) ||
        !vpm_read(listing + MBM_HEADER_ROW, row, sizeof row))
        return 0;
    float vx, bottom, vr, scale, left, top, right, rs;
    if (!MbmSolved(viewport, &vx, &bottom, &vr, &scale) || !MbmSolved(row, &left, &top, &right, &rs)) return 0;
    if (top - bottom < MBM_PITCH * scale) return 0;
    int controller = page != 0;
    if (left == s_panel.left && right == s_panel.right && top == s_panel.top && bottom == s_panel.bottom &&
        scale == s_panel.scale && controller == s_panel.controller)
        return 1;
    s_panel.left = left;
    s_panel.right = right;
    s_panel.top = top;
    s_panel.bottom = bottom;
    s_panel.scale = scale;
    s_panel.controller = controller;
    s_panel.dirty = 1;
    s_panel.count = (int)floorf((top - bottom) / (MBM_PITCH * scale));
    if (s_panel.count > MBM_MAX_SLOTS) s_panel.count = MBM_MAX_SLOTS;
    return 2;
}

/* ---- the model, the scroll and the focus ----------------------------------------------------------------------- */

static int MbmBindingRow(int index) { return index >= 0 && index < s_panel.row_count && !s_panel.rows[index].header; }

static void MbmScrollTo(int first)
{
    int last = s_panel.row_count - s_panel.count > 0 ? s_panel.row_count - s_panel.count : 0;
    first = first < 0 ? 0 : first > last ? last : first;
    if (first == s_panel.first) return;
    s_panel.first = first;
    s_panel.dirty = 1;
}

static void MbmShowFocus(void)
{
    int focus = s_panel.focus;
    if (focus < 0) return;
    /* Keeps the section header above the first binding in view. */
    if (focus < s_panel.first) MbmScrollTo(MbmBindingRow(focus - 1) ? focus : focus - 1);
    else if (focus > s_panel.first + s_panel.count - 1) MbmScrollTo(focus - s_panel.count + 1);
}

static void MbmSettle(void)
{
    MbmScrollTo(s_panel.first);
    MbmShowFocus();
}

static void MbmSetFocus(int index)
{
    if (index == s_panel.focus) return;
    s_panel.focus = index;
    s_panel.dirty = 1;
    s_panel.focus_record = index >= 0 ? s_panel.rows[index].record : NULL;
}

/* Rows: a header per category, then its bindings. The focus follows its binding. */
static void MbmBuildModel(void)
{
    int count = 0, focus = -1;
    const char* last = NULL;
    for (int i = 0; i < mbm.extended_count && count + 2 <= MBM_MAX_PANEL_ROWS; i++)
    {
        MbmRecord* r = mbm.extended_order[i];
        if (last == NULL || strcmp(last, r->category) != 0) s_panel.rows[count++] = (MbmPanelRow){r, 1};
        last = r->category;
        if (r == s_panel.focus_record) focus = count;
        s_panel.rows[count++] = (MbmPanelRow){r, 0};
    }
    s_panel.row_count = count;
    s_panel.model = mbm.revision;
    s_panel.model_valid = 1;
    s_panel.dirty = 1;
    s_panel.focus = focus;
    if (focus < 0) s_panel.focus_record = NULL;
    MbmSettle();
}

static void MbmMoveFocus(int step)
{
    int index = s_panel.focus >= 0 ? s_panel.focus : step > 0 ? -1 : s_panel.row_count;
    do index += step;
    while (index >= 0 && index < s_panel.row_count && !MbmBindingRow(index));
    if (index < 0 || index >= s_panel.row_count) return;
    MbmSetFocus(index);
    MbmShowFocus();
}

/* ---- input ----------------------------------------------------------------------------------------------------- */

/* The input owner, and its first count UI action states read; 0 when either cannot be read. */
static uintptr_t MbmReadActions(uint32_t count)
{
    uintptr_t owner = mbm_input_owner();
    if (owner == 0 || !vpm_read(owner + MBM_ACTION_STATE, g_mbmActions, count * MBM_ACTION_STRIDE)) return 0;
    return owner;
}

static int MbmActive(uint32_t index) { return g_mbmActions[index * MBM_ACTION_STRIDE] != 0; }

/* The game's held repeat (0x178dc50): fires on the press, then after half a second held every 0.1 s (an analog stick
 * part-way: up to every second). */
static int MbmRepeated(uint32_t index, int slot)
{
    float held = MbmF32(g_mbmActions + index * MBM_ACTION_STRIDE + 8);
    if (MbmActive(index))
    {
        s_panel.repeat_last[slot] = held;
        return 1;
    }
    if (held <= 0.5f) return 0;
    float magnitude = fabsf(MbmF32(g_mbmActions + index * MBM_ACTION_STRIDE + 4));
    if (magnitude > 1) magnitude = 1;
    if (held - s_panel.repeat_last[slot] <= magnitude * 0.1f + (1 - magnitude)) return 0;
    s_panel.repeat_last[slot] = held;
    return 1;
}

static void MbmNavigate(void)
{
    if (MbmActive(MBM_UP) || MbmRepeated(MBM_UP_HELD, 0)) MbmMoveFocus(-1);
    if (MbmActive(MBM_DOWN) || MbmRepeated(MBM_DOWN_HELD, 1)) MbmMoveFocus(1);
}

/* The cursor position (y up), or 0 while it is not attached to the root. */
static int MbmCursor(float* x, float* y)
{
    uint64_t menu = vpm_game_u64(MBM_MENU_SYSTEM_RVA);
    uint8_t cursor[MBM_CURSOR_BYTES];
    if (!mbm_pointer(menu) || !vpm_read((uintptr_t)menu + MBM_CURSOR + MBM_CURSOR_PARENT, cursor, sizeof cursor)) return 0;
    uint64_t parent;
    memcpy(&parent, cursor, 8);
    if (parent != menu + MBM_ROOT_A && parent != menu + MBM_ROOT_B) return 0;
    *x = MbmF32(cursor + 108);
    *y = MbmF32(cursor + 112);
    return 1;
}

static int MbmInside(int valid, float x, float y)
{
    return valid && x >= s_panel.left && x <= s_panel.right && y <= s_panel.top && y >= s_panel.bottom;
}

/* The binding row under the cursor, or -1. */
static int MbmRowAt(int valid, float x, float y)
{
    if (!MbmInside(valid, x, y)) return -1;
    int index = s_panel.first + (int)floorf((s_panel.top - y) / (MBM_PITCH * s_panel.scale));
    return index <= s_panel.first + s_panel.count - 1 && MbmBindingRow(index) ? index : -1;
}

/* The cursor: whether it is over the panel; the binding row under it takes the focus when the cursor moves onto it. */
static void MbmTrackCursor(void)
{
    float x = 0, y = 0;
    int valid = MbmCursor(&x, &y);
    int moved = valid != s_panel.cursor_valid || (valid && (x != s_panel.cursor_x || y != s_panel.cursor_y));
    s_panel.cursor_valid = valid;
    s_panel.cursor_x = x;
    s_panel.cursor_y = y;
    s_panel.inside = MbmInside(valid, x, y);
    int hover = MbmRowAt(valid, x, y);
    if (hover != s_panel.hover)
    {
        s_panel.hover = hover;
        s_panel.dirty = 1;
    }
    if (moved && hover >= 0) MbmSetFocus(hover);
}

static const MbmDevice* MbmMouse(void)
{
    const MbmDevice* mouse = mbm_device(MBM_MOUSE);
    if (mouse == NULL || s_panel.mouse_known) return mouse;
    s_panel.mouse_known = 1;
    s_panel.has_left = mouse->button_id("left", &s_panel.mouse_left);
    s_panel.has_up = mouse->button_id("wheel_up", &s_panel.wheel_up);
    s_panel.has_down = mouse->button_id("wheel_down", &s_panel.wheel_down);
    return mouse;
}

static int MbmMousePressed(const MbmDevice* mouse, int has, uint32_t id)
{
    return mouse != NULL && has && mouse->pressed != NULL && mouse->pressed(id);
}

static int MbmHoldBack(void) { s_panel.guarding = 1; return 1; }
static void MbmReleaseBack(void) { s_panel.guarding = 0; }

static void MbmStartCapture(int index)
{
    if (!MbmBindingRow(index)) return;
    MbmSetFocus(index);
    const char* why = "";
    MbmRecord* r = s_panel.rows[index].record;
    if (!mbm_begin_capture(r, s_panel.controller, MbmHoldBack, MbmReleaseBack, &why))
        vpm_log(mbm.self, "Key capture for %s not started: %s.", r->id, why);
}

/* The panel's own input without a capture: navigation, the cursor, the wheel; a click starts a capture on the row under
 * the cursor, select on the focused row. */
static void MbmHandleInput(void)
{
    MbmNavigate();
    MbmTrackCursor();
    const MbmDevice* mouse = MbmMouse();
    if (s_panel.inside && MbmMousePressed(mouse, s_panel.has_up, s_panel.wheel_up)) MbmScrollTo(s_panel.first - MBM_WHEEL_ROWS);
    if (s_panel.inside && MbmMousePressed(mouse, s_panel.has_down, s_panel.wheel_down)) MbmScrollTo(s_panel.first + MBM_WHEEL_ROWS);
    int select = MbmActive(MBM_SELECT), rising = select && !s_panel.select_was;
    s_panel.select_was = select;
    if (MbmMousePressed(mouse, s_panel.has_left, s_panel.mouse_left))
    {
        if (s_panel.hover >= 0) MbmStartCapture(s_panel.hover);
    }
    else if (rising && s_panel.focus >= 0) MbmStartCapture(s_panel.focus);
}

/* While a capture runs: every active UI action of the frame is consumed, so the page does not act on the keys. */
static void MbmGuardPage(void)
{
    uintptr_t owner = MbmReadActions(MBM_GROUP_ACTIONS);
    if (owner == 0) return;
    for (uint32_t i = 0; i < MBM_GROUP_ACTIONS; i++)
        if (MbmActive(i)) mbm_consume(owner, i);
}

/* Whether what is shown of a capture or the keys changed (the panel then redraws); 1 while a capture runs. */
static int MbmChangedCapture(void)
{
    MbmRecord* record = NULL;
    int phase = mbm_capture_phase(&record, NULL);
    if (!s_panel.drawn_valid || phase != s_panel.drawn_phase || record != s_panel.drawn_record ||
        mbm.bindings_version != s_panel.drawn_bindings)
    {
        s_panel.drawn_valid = 1;
        s_panel.drawn_phase = phase;
        s_panel.drawn_record = record;
        s_panel.drawn_bindings = mbm.bindings_version;
        s_panel.dirty = 1;
    }
    return phase != MBM_IDLE;
}

static void MbmFrameInput(float seconds)
{
    if (MbmChangedCapture())
    {
        s_panel.select_was = 0; /* consumed actions read as released until they are: select counts from its next press */
        if (s_panel.guarding) MbmGuardPage();
        mbm_update_capture(seconds);
    }
    else if (MbmReadActions(MBM_UI_ACTIONS) != 0) MbmHandleInput();
    (void)MbmChangedCapture();
}

/* ---- texts and drawing ----------------------------------------------------------------------------------------- */

static void MbmPanelText(char* out, size_t size, const char* key, const char* english)
{
    if (!mbm_display_text(vpm_text(mbm.self, key, english), 127, out, size)) snprintf(out, size, "%s", english);
}

/* One alternative's keys, modifiers first ("left ctrl + h"), appended at at. */
static size_t MbmAlternativeLabel(const MbmAlternative* alt, char* text, size_t at, size_t size)
{
    char name[64];
    if (at > 0 && at < size) at += (size_t)snprintf(text + at, size - at, " / ");
    for (int i = alt->count - 1; i >= 0 && at < size; i--)
        at += (size_t)snprintf(text + at, size - at, "%s%s", mbm_input_label(&alt->inputs[i], name, sizeof name), i > 0 ? " + " : "");
    return at;
}

/* A binding's keys on this page, and the colour to show them in. */
static const uint8_t* MbmKeysText(MbmRecord* r, char* out, size_t size)
{
    if (mbm_extended_inactive(r)) { MbmPanelText(out, size, "binding.inactive", "SAVED BY A NEWER VERSION"); return kMbmMuted; }
    char text[MBM_TEXT_SIZE];
    size_t at = 0;
    text[0] = 0;
    for (int a = 0; mbm_current(r) && a < r->alternative_count && at < sizeof text; a++)
        if ((r->alternatives[a].inputs[0].device == MBM_PAD) == (s_panel.controller != 0))
            at = MbmAlternativeLabel(&r->alternatives[a], text, at, sizeof text);
    if (at == 0) { MbmPanelText(out, size, "binding.none", "NOT BOUND"); return kMbmMuted; }
    mbm_upper(text, out, size);
    return kMbmText;
}

/* A binding row's texts: its label and keys, or while its key is being chosen the page's hint and prompt. */
static void MbmRowTexts(MbmRecord* r, char* label, char* keys, size_t size, const uint8_t** label_colour, const uint8_t** keys_colour)
{
    MbmRecord* capturing = NULL;
    if (mbm_capture_phase(&capturing, NULL) != MBM_IDLE && capturing == r)
    {
        int pad = s_panel.controller;
        MbmPanelText(label, size, pad ? "binding.capture_hint_pad" : "binding.capture_hint", pad ? "B: CANCEL, X: CLEAR" : "ESC: CANCEL, DELETE: CLEAR");
        MbmPanelText(keys, size, pad ? "binding.capture_pad" : "binding.capture", pad ? "PRESS A BUTTON" : "PRESS A KEY");
        *label_colour = kMbmMuted;
        *keys_colour = kMbmCapture;
        return;
    }
    snprintf(label, size, "%s", r->text);
    *label_colour = kMbmText;
    *keys_colour = MbmKeysText(r, keys, size);
}

static int MbmTooWide(const char* text, float size, float width)
{
    float measured = 0;
    return !mbm_engine_gui()->text_width(text, size, &measured) || measured > width;
}

/* The longest start of text, whole characters and "...", that fits width; text itself when it fits or the Gui cannot
 * measure. */
static const char* MbmFit(const char* text, float size, float width, char* out, size_t room)
{
    if (text[0] == 0 || mbm_engine_gui()->text_width == NULL || !MbmTooWide(text, size, width)) return text;
    size_t starts[MBM_TEXT_SIZE], n = strlen(text);
    int chars = 0;
    for (size_t i = 0; i < n; i++)
        if (((unsigned char)text[i] & 0xC0) != 0x80) starts[chars++] = i;
    int low = 0, high = chars - 1;
    while (low < high)
    {
        int middle = (low + high + 1) / 2;
        snprintf(out, room, "%.*s...", (int)starts[middle], text);
        if (MbmTooWide(out, size, width)) high = middle - 1;
        else low = middle;
    }
    snprintf(out, room, "%.*s...", (int)(low < chars ? starts[low] : n), text);
    return out;
}

static void MbmRect(uint32_t* handle, float x, float y, float w, float h, const MbmStyle* style)
{
    *handle = mbm_engine_gui()->rect(*handle, x, y, style->layer, w, h, style->colour);
}

static void MbmTextAt(uint32_t* handle, const char* text, float x, float y, float size, const uint8_t* colour)
{
    *handle = mbm_engine_gui()->text(*handle, *handle == 0 && text[0] == 0 ? " " : text, x, y, 1013, size, colour);
}

static void MbmHideSlot(MbmSlot* slot)
{
    if (slot->bg == 0) return;
    MbmRect(&slot->bg, 0, 0, 0, 0, &kMbmRow);
    MbmRect(&slot->mark, 0, 0, 0, 0, &kMbmRow);
    MbmTextAt(&slot->label, "", 0, 0, 1, kMbmText);
    MbmTextAt(&slot->keys, "", 0, 0, 1, kMbmText);
}

/* Draws row index into slot n (0 at the top). */
static void MbmDrawSlot(MbmSlot* slot, int n, int index)
{
    float s = s_panel.scale, pitch = MBM_PITCH * s, top = s_panel.top - (float)n * pitch;
    float x = s_panel.left, width = s_panel.right - s_panel.left - (MBM_BAR + MBM_GAP) * s;
    float bottom = top - pitch + MBM_GAP * s, height = pitch - 2 * MBM_GAP * s;
    float baseline = top - pitch / 2 - MBM_TEXT * s * 0.35f, size = MBM_TEXT * s;
    char label[MBM_TEXT_SIZE], keys[MBM_TEXT_SIZE], fitted[MBM_TEXT_SIZE + 4];
    MbmRecord* r = s_panel.rows[index].record;
    if (s_panel.rows[index].header)
    {
        MbmRect(&slot->bg, x, bottom, width, height, &kMbmHeader);
        MbmRect(&slot->mark, 0, 0, 0, 0, &kMbmAccent);
        MbmTextAt(&slot->label, MbmFit(r->category, size, width - 2 * MBM_PADDING * s, fitted, sizeof fitted), x + MBM_PADDING * s, baseline, size, kMbmHeading);
        MbmTextAt(&slot->keys, "", 0, 0, size, kMbmText);
        return;
    }
    int focused = index == s_panel.focus || index == s_panel.hover;
    float column = width * MBM_KEY_COLUMN;
    const uint8_t *label_colour, *keys_colour;
    MbmRect(&slot->bg, x, bottom, width, height, focused ? &kMbmFocus : &kMbmRow);
    MbmRect(&slot->mark, x, bottom, focused ? MBM_ACCENT * s : 0, height, &kMbmAccent);
    MbmRowTexts(r, label, keys, sizeof label, &label_colour, &keys_colour);
    MbmTextAt(&slot->label, MbmFit(label, size, column - 2 * MBM_PADDING * s, fitted, sizeof fitted), x + MBM_PADDING * s, baseline, size, label_colour);
    MbmTextAt(&slot->keys, MbmFit(keys, size, width - column - MBM_PADDING * s, fitted, sizeof fitted), x + column, baseline, size, keys_colour);
}

static void MbmDrawScrollbar(void)
{
    float s = s_panel.scale;
    int total = s_panel.row_count;
    if (total <= s_panel.count)
    {
        MbmRect(&s_panel.bar.bg, 0, 0, 0, 0, &kMbmTrack);
        MbmRect(&s_panel.bar.mark, 0, 0, 0, 0, &kMbmThumb);
        return;
    }
    float x = s_panel.right - MBM_BAR * s, height = s_panel.top - s_panel.bottom;
    float thumb = fmaxf(MBM_PITCH * s / 2, height * (float)s_panel.count / (float)total);
    float offset = (height - thumb) * (float)s_panel.first / (float)(total - s_panel.count);
    MbmRect(&s_panel.bar.bg, x, s_panel.bottom, MBM_BAR * s, height, &kMbmTrack);
    MbmRect(&s_panel.bar.mark, x, s_panel.top - offset - thumb, MBM_BAR * s, thumb, &kMbmThumb);
}

static void MbmDraw(void)
{
    for (int n = 0; n < s_panel.count; n++)
    {
        int index = s_panel.first + n;
        if (index < s_panel.row_count) MbmDrawSlot(&s_panel.slots[n], n, index);
        else MbmHideSlot(&s_panel.slots[n]);
    }
    for (int n = s_panel.count; n < s_panel.slots_used; n++) MbmHideSlot(&s_panel.slots[n]);
    if (s_panel.count > s_panel.slots_used) s_panel.slots_used = s_panel.count;
    MbmDrawScrollbar();
    s_panel.dirty = 0;
}

/* ---- the Gui and the frame ------------------------------------------------------------------------------------- */

static void MbmCloseGui(void)
{
    int open = s_panel.open;
    s_panel.open = 0;
    s_panel.dirty = 1;
    s_panel.drawn_valid = 0;
    memset(s_panel.slots, 0, sizeof s_panel.slots);
    memset(&s_panel.bar, 0, sizeof s_panel.bar);
    s_panel.slots_used = 0;
    if (open && mbm_engine_gui() != NULL) mbm_engine_gui()->close();
}

/* Creates the Gui with the active language's body font, its normal material and atlas (the native font initializer
 * keeps them: two plain loads and one read); after a failure the next try waits a second. */
static int MbmOpenGui(float seconds)
{
    s_panel.open_wait -= seconds;
    if (s_panel.open_wait > 0) return 0;
    s_panel.open_wait = MBM_WORLD_CHECK;
    uint64_t font = vpm_game_u64(MBM_FONT_RVA), atlas = vpm_game_u64(MBM_ATLAS_RVA), owner = vpm_game_u64(MBM_MATERIAL_RVA);
    uint64_t material = 0;
    if (font == 0 || atlas == 0 || !mbm_pointer(owner) || !vpm_read_u64((uintptr_t)owner + 24, &material) || material == 0) return 0;
    if (!mbm_engine_gui()->open(font, material, atlas))
    {
        vpm_log(mbm.self, "Panel: no screen Gui.");
        return 0;
    }
    s_panel.open = 1;
    s_panel.world_timer = 0;
    s_panel.open_wait = 0;
    s_panel.dirty = 1;
    return 1;
}

/* The UI world still exists (checked once a second): a world change closes the Gui. */
static int MbmWorldOk(float seconds)
{
    s_panel.world_timer += seconds;
    if (s_panel.world_timer < MBM_WORLD_CHECK) return 1;
    s_panel.world_timer = 0;
    if (mbm_engine_gui()->alive()) return 1;
    s_panel.open = 0;
    memset(s_panel.slots, 0, sizeof s_panel.slots);
    memset(&s_panel.bar, 0, sizeof s_panel.bar);
    s_panel.slots_used = 0;
    return 0;
}

/* Closes the panel (tab left, page closed, layout unusable, stop): any capture ends with reason, the Gui goes.
 * lint: per-frame */
void mbm_panel_hide(const char* reason)
{
    if (mbm_capture_phase(NULL, NULL) != MBM_IDLE) mbm_cancel_capture(reason);
    s_panel.guarding = 0;
    s_panel.select_was = 0;
    if (s_panel.open) MbmCloseGui();
}

/* One frame with the MORE MODS tab shown and its native list built. lint: per-frame */
void mbm_panel_frame(uintptr_t listing, float seconds)
{
    if (!mbm_panel_available() || mbm.base == 0) return;
    int geometry = MbmGeometry(listing);
    if (geometry == 0)
    {
        mbm_panel_hide("the page layout changed");
        return;
    }
    if (!s_panel.model_valid || s_panel.model != mbm.revision) MbmBuildModel();
    else if (geometry == 2) MbmSettle();
    MbmFrameInput(seconds);
    if (s_panel.open && !MbmWorldOk(seconds)) return;
    if (!s_panel.open && !MbmOpenGui(seconds)) return;
    if (s_panel.dirty) MbmDraw();
}
