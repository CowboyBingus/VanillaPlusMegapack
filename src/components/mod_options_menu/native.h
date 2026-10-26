/* Mod Options Menu: game.dll's native functions the MODS tab calls, and the native labels and setting descriptor it
 * relies on, checked once per session against build 25480438 before the menu is touched (native.c; the Lua's
 * native.lua). */
#ifndef MOM_NATIVE_H
#define MOM_NATIVE_H

#include <stddef.h>
#include <stdint.h>

/* Widget positions and sizes: two floats passed by value in one register. */
typedef struct MomVec2 { float x, y; } MomVec2;

enum
{
    MOM_SET_TAB_LABELS,
    MOM_SELECT_CATEGORY,
    MOM_SET_CONTENT_HIDDEN,
    MOM_ROW_RESET,
    MOM_ROW_RELEASE,
    MOM_ROW_INIT,
    MOM_ADD_CHILD,
    MOM_SET_VISIBLE,
    MOM_SET_LABEL,
    MOM_SET_STRING_ARG,
    MOM_CLEAR_ARGS,
    MOM_SET_CHOICE,
    MOM_SET_SLIDER,
    MOM_FINISH_SIMPLE,
    MOM_FINISH_ACCESS,
    MOM_SCROLL_THUMB,
    MOM_SCROLL_EXTENT,
    MOM_SET_OPACITY,
    MOM_SCROLL_RESET,
    MOM_OPTIONS_VISUAL,
    MOM_MEASURE_TEXT,
    MOM_SET_POSITION,
    MOM_SET_SIZE,
    MOM_HIDE_DESCRIPTION,
    MOM_PLAY_SOUND,
    MOM_NATIVE_COUNT
};

/* {name, game.dll RVA, its first bytes as shipped} */
typedef struct MomNativeEntry { const char* name; uint32_t rva; const char* code; } MomNativeEntry;
extern const MomNativeEntry mom_native_entries[MOM_NATIVE_COUNT];

/* The native labels of the escape menu's three tabs (4 bytes each) and of the OPTIONS content's nine categories (one
 * record each, the label at +8), and setting 139's descriptor. */
#define MOM_TAB_LABELS_RVA 0x33114D0u
#define MOM_CATEGORY_TABLE_RVA 0x32EC990u
#define MOM_CATEGORY_RECORD 48u
#define MOM_INERT_DESCRIPTOR_RVA 0x32ECC60u
extern const uint32_t mom_tab_labels[3];      /* GAME, SOCIAL, OPTIONS */
extern const uint32_t mom_category_labels[9]; /* GAMEPLAY ... ACCOUNT */

/* The functions, at game.dll + RVA once verified. Object addresses pass as integers. */
typedef struct MomNative
{
    void (*set_tab_labels)(uintptr_t bar, const uint32_t* labels, int count);
    void (*select_category)(uintptr_t content, int category);
    void (*set_content_hidden)(uintptr_t content, uint8_t hidden, uint8_t immediate);
    void (*row_reset)(uintptr_t row, const float* first, const float* second);
    void (*row_release)(uintptr_t row);
    void (*row_init)(uintptr_t row, MomVec2 position, MomVec2 pivot, MomVec2 anchor, int layer, uintptr_t settings,
        const void* descriptor, uint8_t flag);
    void (*add_child)(uintptr_t parent, uintptr_t child);
    void (*set_visible)(uintptr_t widget, uint8_t visible);
    void (*set_label)(uintptr_t widget, uint32_t label);
    void (*set_string_arg)(uintptr_t widget, uint32_t key, const char* text);
    uint8_t (*clear_args)(uintptr_t label);
    void (*set_choice)(uintptr_t selector, uint32_t index);
    void (*set_slider)(uintptr_t slider, float value);
    void (*finish_simple)(uintptr_t panel);
    void (*finish_access)(uintptr_t panel);
    void (*scroll_thumb)(uintptr_t scroll, float size);
    void (*scroll_extent)(uintptr_t scroll, float extent);
    void (*set_opacity)(uintptr_t widget, float opacity);
    void (*scroll_reset)(uintptr_t scroll);
    void (*options_visual)(uintptr_t content, float dt);
    void (*measure_text)(uintptr_t widget);
    void (*set_position)(uintptr_t widget, MomVec2 position);
    void (*set_size)(uintptr_t widget, MomVec2 size);
    void (*hide_description)(uintptr_t box, uint8_t hidden, uint8_t animate);
    void (*play_sound)(uintptr_t unused, uint32_t event); /* posts a UI sound event; the first argument is unused */
} MomNative;
extern MomNative mom_native;

/* Checks every function's bytes, the labels and the descriptor; fills mom_native. NULL when verified, else the reason
 * ("set_tab_labels changed", written into why). */
const char* mom_native_verify(char* why, size_t size);

#endif
