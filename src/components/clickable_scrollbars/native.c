/* Clickable Scrollbars: the game's scroll and input routines and the writes that drive them (Lua: native.lua's
 * native_signatures, native_calls, native_apply and native_settings_input).
 *
 * A drag moves a list the way the game's own handlers do, never by synthesised input:
 * - an equipment grid as its wheel handler does: stop a running scroll animation (0x1439D40, only while its flag at
 *   grid + 600322 is set), the ScrollBar's value setter (0x1794530, which also places the rendered thumb), the pixel
 *   offset (grid + 600416, a plain store: the Lua's direct FFI store), then the layout solver (0x18D2B60), which
 *   re-solves the visible rows; writing the value first would make the setter skip its work;
 * - Career through its list container's position setter (0x14476A0): its frame update derives the thumb from
 *   (y + padding) / (content - viewport);
 * - the Controls and Settings lists as their input handler does: the bar's value, then the content container's
 *   vertical position (updating only the bar moves the thumb but not the rows).
 * The position setter takes its two-float vector packed in the second integer register.
 *
 * While a Settings drag holds the button, the UI select action is consumed every frame through the routine the game's
 * buttons use (0x12FDE90, action 0xA00000000, -1: until release), so rows and tabs the pointer crosses never activate.
 * The input owner is the game.dll global 0x347CF18: a plain load (the Lua read it with ReadProcessMemory).
 *
 * Every routine's first bytes are checked once, at game load, as the Lua checked them before any native scrolling; a
 * mismatch leaves the component off. */
#include <string.h>
#include "clickable_scrollbars.h"

#define GRID_SOLVER 0x18D2B60u
#define SCROLL_SET 0x1794530u
#define POSITION_SET 0x14476A0u
#define ANIMATION_STOP 0x1439D40u
#define INPUT_CONSUME 0x12FDE90u
#define INPUT_STATE 0x347CF18u     /* game.dll: the input owner */
#define UI_SELECT 0xA00000000ull   /* the UI select action */
#define GRID_ANIMATION 600320u     /* grid: the scroll animation (stop's argument); its running flag at +2 */

typedef void (*ObjectFn)(void* object);
typedef void (*ScrollFn)(void* bar, float value);
typedef void (*PositionFn)(void* widget, uint64_t xy);
typedef void (*ConsumeFn)(void* input, uint64_t action, float hold);

typedef struct Routine { uint32_t rva; const char* code; } Routine;
/* native.lua native_signatures, in its order */
static const Routine kRoutines[] = {
    {GRID_SOLVER, "48 8B C4 53 55 56 57 41 54 41 55 41 56 41 57 48 81 EC F8 00 00 00 83 B9"},
    {SCROLL_SET, "0F 57 D2 0F 2F D1 77 0C F3 0F 10 15 30 28 C3 00 F3 0F 5D D1 F3 0F 10 81"},
    {POSITION_SET, "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3"},
    {ANIMATION_STOP, "40 53 48 83 EC 40 48 8B 05 C3 22 20 01 48 33 C4 48 89 44 24 30 0F B6 01"},
    {INPUT_CONSUME, "40 53 48 83 EC 20 4C 8B D1 4C 8B CA 48 8B CA E8 DC 7C 28 FF"},
};

static struct
{
    ObjectFn stop, solve;
    ScrollFn scroll;
    PositionFn position;
    ConsumeFn consume;
} g_calls;

int cs_routines_check(void)
{
    memset(&g_calls, 0, sizeof g_calls);
    for (size_t i = 0; i < sizeof kRoutines / sizeof kRoutines[0]; i++)
        if (!vpm_game_code_matches(kRoutines[i].rva, kRoutines[i].code)) return 0;
    uintptr_t game = vpm_game();
    g_calls.solve = (ObjectFn)(game + GRID_SOLVER);
    g_calls.scroll = (ScrollFn)(game + SCROLL_SET);
    g_calls.position = (PositionFn)(game + POSITION_SET);
    g_calls.stop = (ObjectFn)(game + ANIMATION_STOP);
    g_calls.consume = (ConsumeFn)(game + INPUT_CONSUME);
    return 1;
}

/* The two floats as the engine's vector: x in the low half. */
static uint64_t Vector(double x, double y)
{
    float xy[2] = {(float)x, (float)y};
    uint64_t bits;
    memcpy(&bits, xy, sizeof bits);
    return bits;
}

/* memory.lua write_f32: a bounded store into the owner the same frame re-validated. */
static int StoreF32(uintptr_t address, double value)
{
    if (value != value || cs_abs(value) > CS_MAX_PIXELS) return 0;
    float stored = (float)value;
    memcpy((void*)address, &stored, sizeof stored);
    return 1;
}

/* lint: per-frame */
static int ApplyGrid(uintptr_t grid, const CsModel* model, double value, const char** reason)
{
    /* the flag lies inside the row-table block this frame's model read checked */
    if (*(volatile const uint8_t*)(grid + GRID_ANIMATION + 2) != 0) g_calls.stop((void*)(grid + GRID_ANIMATION));
    g_calls.scroll((void*)(grid + CS_GRID_BAR), (float)value);
    if (!StoreF32(grid + CS_GRID_SCROLL, value * model->span))
    {
        g_calls.scroll((void*)(grid + CS_GRID_BAR), (float)model->value);
        *reason = "scroll write refused";
        return 0;
    }
    g_calls.solve((void*)grid);
    return 1;
}

/* lint: per-frame */
int cs_apply(const CsBridge* bridge, const CsModel* model, double value, double* written, const char** reason)
{
    if (bridge == NULL || model == NULL || g_calls.scroll == NULL || value != value || model->span <= 0 ||
        model->span != model->span || model->span > CS_MAX_PIXELS)
    {
        *reason = "invalid native target";
        return 0;
    }
    value = cs_clamp(value, 0, 1);
    if (bridge->route == CS_ROUTE_CAREER)
        g_calls.position((void*)(bridge->panel + CS_CAREER_LIST), Vector(model->list_x, value * model->span - CS_CAREER_PADDING));
    else if (bridge->route == CS_ROUTE_BINDINGS || bridge->route == CS_ROUTE_SETTINGS)
    {
        g_calls.scroll((void*)bridge->bar, (float)value);
        g_calls.position((void*)(bridge->grid + CS_OPTIONS_CONTENT), Vector(0, value * model->span));
    }
    else if (!ApplyGrid(bridge->grid, model, value, reason))
        return 0;
    *written = value;
    return 1;
}

/* lint: per-frame */
int cs_settings_input(void)
{
    uintptr_t input = cs_pointer(vpm_game_u64(INPUT_STATE));
    if (input == 0 || g_calls.consume == NULL) return 0;
    g_calls.consume((void*)input, UI_SELECT, -1.0f);
    return 1;
}
