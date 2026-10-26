/* Mod Options Menu: game.dll's native functions the MODS tab calls, and the native labels and setting descriptor it
 * relies on, checked once per session against build 25480438 before the menu is touched (native.c; the Lua's
 * native.lua).
 *
 * Calling convention, checked offline against the decoded game.dll of 25480438 (each function's code and how the game's
 * own callers pass its arguments; 2026-10-25): all 25 are plain Microsoft x64 functions taking what MomNative declares,
 * and the pack's compiler (zig cc: clang for x86_64-windows-gnu) passes them the same way (checked in its assembly of
 * rows.c, widgets.c and view.c). Integers and pointers go in rcx, rdx, r8, r9, then on the stack from +0x28 at entry; a
 * float in the xmm register of its position (xmm1 as the second); a MomVec2 {float x, y} (8 bytes) by value in the
 * integer register of its position, x in the low half, as the game's callers load it (one qword over two floats). No
 * declaration needed changing. Per function (callers: direct calls in the image):
 *   set_tab_labels 0x17AAC50     rcx bar; rdx the labels (count x 4 bytes copied to bar + 0xDFE8); r8d count (signed,
 *                                clamped to 8, stored at bar + 0xE068). 27 callers: rdx a static label array, r8d.
 *   select_category 0x19999C0    rcx content; edx the category (stored at +0x141E58, compared with the previous one at
 *                                +0x141E5C). 6 callers: rcx screen + 0x2DEF98, edx a constant.
 *   set_content_hidden 0x19984C0 rcx content; dl hidden (compared with and stored at +0x142215); r8b immediate (movzx).
 *                                4 callers pass dl and r8b.
 *   row_reset 0x17FF700          rcx row; rdx and r8 two rectangles, loaded with movaps (16-byte aligned). 21 callers
 *                                pass two aligned stack rectangles.
 *   row_release 0x17FF4B0        rcx row only. 12 callers.
 *   row_init 0x17FE8D0           rcx row; rdx position, r8 pivot, r9 anchor, each a {float, float} (the callers' r8 and
 *                                r9 are {0.5, 1}); stack +0x28 layer (never read: it passes 10 to its builders itself),
 *                                +0x30 the settings pointer (passed on to 0x17FF1E0), +0x38 the descriptor (kind +8,
 *                                setting +0, label +0x10, slider floats +0x24 to +0x38, choices +0x40), +0x40 the flag
 *                                byte (movzx). 22 callers, the same layout.
 *   add_child 0x144C5C0          rcx parent (children at +0xE0); rdx child (sibling at +0xE8). 3921 callers.
 *   set_visible 0x144CFB0        rcx widget; dl (the flag 0x10 at +0). 71 callers.
 *   set_label 0x143BF90          rcx widget; edx the label (at +0x110). 1157 callers.
 *   set_string_arg 0x143C950     rcx widget; edx key; r8 the text, kept as a pointer ({key, 1, pointer} at +0x118 +
 *                                24 n, the count byte at +0x268), so it must outlive the widget's use of it (text.c).
 *                                109 callers, r8 a static string.
 *   clear_args 0x143A0F0         leaf: rcx the widget's label record (+0x110); clears its count byte (+0x158) and
 *                                returns al = 1 when it held arguments. Nothing in the image calls it, jumps to it or
 *                                points at it: read from its four instructions.
 *   set_choice 0x17FE7E0         leaf: rcx selector; edx the index (unsigned, below 16), then tail jumps. 5 callers.
 *   set_slider 0x17FC2C0         rcx slider; xmm1 the value (less min at +0x8AC, over the range). 11 callers, xmm1.
 *   finish_simple 0x1807060      rcx panel (count +0xB10, scroll +0x330). 1 caller: the GAMEPLAY builder, rcx the panel.
 *   finish_access 0x1800FE0      rcx panel (count +0x5750); reached by two tail jumps of the ACCESSIBILITY builder, rcx
 *                                the panel; it calls scroll_thumb and scroll_extent with xmm1 itself.
 *   scroll_thumb 0x1793F60       rcx scroll; xmm1 the size (stored at +0x7A8); it passes a {float, float} in rdx to
 *                                set_size itself. 45 callers.
 *   scroll_extent 0x1794600      leaf: rcx scroll; xmm1 the extent (stored at +0x7B0). 24 callers.
 *   set_opacity 0x1448AD0        rcx widget; xmm1 (compared with +0x44). 5030 callers.
 *   scroll_reset 0x1794570       leaf: rcx scroll; tail jumps to set_position with a {float, float} in rdx. 61 callers.
 *   options_visual 0x1998590     rcx content; xmm1 dt (kept in xmm7). 1 caller, the escape menu screen's update while
 *                                its current tab (screen + 0xE54C) is OPTIONS: rcx screen + 0x2DEF98, xmm1 the float
 *                                (xmm6) it hands its other contents too.
 *   measure_text 0x144E1A0       rcx widget only. 232 callers.
 *   set_position 0x14476A0       rcx widget; rdx {x, y} (spilled to its home slot, compared as floats with +4 and +8).
 *                                2416 callers load the pair as one qword.
 *   set_size 0x1447160           the same with +0xC and +0x10. 3251 callers.
 *   hide_description 0x17FAB90   rcx box; dl hidden (+0xA70); r8b animate. 2 callers.
 *   play_sound 0x1327F50         edx the event (kept in ebx); rcx is overwritten from a global before any use: unused.
 *                                933 callers set only edx.
 * Every result but clear_args's is unused (void here). */
#ifndef MOM_NATIVE_H
#define MOM_NATIVE_H

#include <stddef.h>
#include <stdint.h>

/* Widget positions and sizes: two floats passed by value in one integer register (the Microsoft x64 rule for an
 * 8-byte struct). */
typedef struct MomVec2 { float x, y; } MomVec2;
_Static_assert(sizeof(MomVec2) == 8, "a MomVec2 travels in one integer register only at 8 bytes");

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
