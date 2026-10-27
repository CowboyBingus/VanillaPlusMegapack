/* Mod Options Menu: game.dll's native functions, labels and setting descriptor, verified once per session (the Lua's
 * native.lua initialize). The Lua compared each function's first bytes in memory at its first update; here the core's
 * wait (vpm_when_code_ready) compares them as the game shipped them, so a hook another mod or HellForge placed on one of
 * them does not fail the check (the call then runs through that hook, as any call into game.dll would), and it compares
 * them from HF_EVENT_GAME_LOADED until they read as decoded (every 30 frames, at most 60 s), since game.dll's code is
 * decoded in parts after that event. The labels and the descriptor are data, read once the functions match. The build
 * itself is the core's check. */
#include <stdio.h>
#include "../../core/vpm.h"
#include "native.h"

const VpmCodePin mom_native_pins[MOM_NATIVE_COUNT] = {
    [MOM_SET_TAB_LABELS] = {0x17AAC50u, "48 89 54 24 10 53 56 48 83 EC 68 0F 29 74 24 30", MOM_UNAVAILABLE "set_tab_labels", 0},
    [MOM_SELECT_CATEGORY] = {0x19999C0u, "40 53 48 83 EC 20 48 8B D9 89 91 58 1E 14 00 39", MOM_UNAVAILABLE "select_category", 0},
    [MOM_SET_CONTENT_HIDDEN] = {0x19984C0u, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 50 41",
        MOM_UNAVAILABLE "set_content_hidden", 0},
    [MOM_ROW_RESET] = {0x17FF700u, "48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55", MOM_UNAVAILABLE "row_reset", 0},
    [MOM_ROW_RELEASE] = {0x17FF4B0u, "48 89 5C 24 08 57 48 83 EC 20 8B 81 C0 7A 00 00", MOM_UNAVAILABLE "row_release", 0},
    [MOM_ROW_INIT] = {0x17FE8D0u, "48 89 5C 24 08 57 48 83 EC 70 48 8B BC 24 B0 00", MOM_UNAVAILABLE "row_init", 0},
    [MOM_ADD_CHILD] = {0x144C5C0u, "40 53 48 83 EC 20 4C 8B CA 48 8B D9 48 8B 91 E0", MOM_UNAVAILABLE "add_child", 0},
    [MOM_SET_VISIBLE] = {0x144CFB0u, "48 83 EC 28 44 8B 01 4C 8B D1 41 8B C0 45 8B C8", MOM_UNAVAILABLE "set_visible", 0},
    [MOM_SET_LABEL] = {0x143BF90u, "48 83 EC 28 4C 8B D9 39 91 10 01 00 00 0F 84 80", MOM_UNAVAILABLE "set_label", 0},
    [MOM_SET_STRING_ARG] = {0x143C950u, "40 53 48 83 EC 20 48 8B D9 48 81 C1 10 01 00 00", MOM_UNAVAILABLE "set_string_arg", 0},
    [MOM_CLEAR_ARGS] = {0x143A0F0u, "80 B9 58 01 00 00 00 C6 81 58 01 00 00 00 0F 97", MOM_UNAVAILABLE "clear_args", 0},
    [MOM_SET_CHOICE] = {0x17FE7E0u, "80 B9 F8 32 00 00 00 74 28 83 FA 10 73 23 48 63", MOM_UNAVAILABLE "set_choice", 0},
    [MOM_SET_SLIDER] = {0x17FC2C0u, "40 53 48 83 EC 20 F3 0F 10 91 AC 08 00 00 48 8B", MOM_UNAVAILABLE "set_slider", 0},
    [MOM_FINISH_SIMPLE] = {0x1807060u, "48 89 5C 24 08 57 48 83 EC 30 8B 81 10 0B 00 00", MOM_UNAVAILABLE "finish_simple", 0},
    [MOM_FINISH_ACCESS] = {0x1800FE0u, "48 89 5C 24 08 57 48 83 EC 30 8B 81 50 57 00 00", MOM_UNAVAILABLE "finish_access", 0},
    [MOM_SCROLL_THUMB] = {0x1793F60u, "48 89 5C 24 10 57 48 83 EC 40 48 8B D9 0F 29 74", MOM_UNAVAILABLE "scroll_thumb", 0},
    [MOM_SCROLL_EXTENT] = {0x1794600u, "F3 0F 10 A1 B0 07 00 00 0F 28 D1 0F 2E E2 7A 02", MOM_UNAVAILABLE "scroll_extent", 0},
    [MOM_SET_OPACITY] = {0x1448AD0u, "40 57 48 83 EC 20 F3 0F 10 41 44 48 8B F9 0F 2E", MOM_UNAVAILABLE "set_opacity", 0},
    [MOM_SCROLL_RESET] = {0x1794570u, "80 B9 B5 07 00 00 00 74 19 F3 0F 10 89 BC 07 00", MOM_UNAVAILABLE "scroll_reset", 0},
    [MOM_OPTIONS_VISUAL] = {0x1998590u, "48 8B C4 57 48 83 EC 70 80 B9 15 22 14 00 00 48", MOM_UNAVAILABLE "options_visual", 0},
    [MOM_MEASURE_TEXT] = {0x144E1A0u, "40 53 48 83 EC 70 48 8B D9 8B 09 8B C1 C1 E8 12", MOM_UNAVAILABLE "measure_text", 0},
    /* Position and size share their first 27 bytes; byte 28 picks the field. */
    [MOM_SET_POSITION] = {0x14476A0u, "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3 0F 10 41 04",
        MOM_UNAVAILABLE "set_position", 0},
    [MOM_SET_SIZE] = {0x1447160u, "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3 0F 10 41 0C",
        MOM_UNAVAILABLE "set_size", 0},
    [MOM_HIDE_DESCRIPTION] = {0x17FAB90u, "48 89 5C 24 10 57 48 83 EC 70 0F B6 DA 48 8B F9",
        MOM_UNAVAILABLE "hide_description", 0},
    [MOM_PLAY_SOUND] = {0x1327F50u, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48", MOM_UNAVAILABLE "play_sound", 0},
};

const uint32_t mom_tab_labels[3] = {0xD876B36Eu, 0x78934E12u, 0x8C02BD80u};
const uint32_t mom_category_labels[9] = {0x396F27D7u, 0x196248D0u, 0xA522D2D0u, 0x15CECAC1u, 0x9A688238u,
    0x07E3B100u, 0x5DB3B764u, 0xA7C345EFu, 0x9BB47B92u};

/* Rows use setting 139 (a BINDINGS activation type): the settings lookup finds it, its value type is none, and no
 * category handler special-cases it, so changing a MODS row never reads or writes a game setting. */
#define INERT_SETTING 139u
#define INERT_CATEGORY 10u

MomNative mom_native;

static void* At(uintptr_t base, int index) { return (void*)(base + mom_native_pins[index].rva); }

#define BIND(field, index) mom_native.field = (__typeof__(mom_native.field))At(base, index)

static void Bind(uintptr_t base)
{
    BIND(set_tab_labels, MOM_SET_TAB_LABELS);
    BIND(select_category, MOM_SELECT_CATEGORY);
    BIND(set_content_hidden, MOM_SET_CONTENT_HIDDEN);
    BIND(row_reset, MOM_ROW_RESET);
    BIND(row_release, MOM_ROW_RELEASE);
    BIND(row_init, MOM_ROW_INIT);
    BIND(add_child, MOM_ADD_CHILD);
    BIND(set_visible, MOM_SET_VISIBLE);
    BIND(set_label, MOM_SET_LABEL);
    BIND(set_string_arg, MOM_SET_STRING_ARG);
    BIND(clear_args, MOM_CLEAR_ARGS);
    BIND(set_choice, MOM_SET_CHOICE);
    BIND(set_slider, MOM_SET_SLIDER);
    BIND(finish_simple, MOM_FINISH_SIMPLE);
    BIND(finish_access, MOM_FINISH_ACCESS);
    BIND(scroll_thumb, MOM_SCROLL_THUMB);
    BIND(scroll_extent, MOM_SCROLL_EXTENT);
    BIND(set_opacity, MOM_SET_OPACITY);
    BIND(scroll_reset, MOM_SCROLL_RESET);
    BIND(options_visual, MOM_OPTIONS_VISUAL);
    BIND(measure_text, MOM_MEASURE_TEXT);
    BIND(set_position, MOM_SET_POSITION);
    BIND(set_size, MOM_SET_SIZE);
    BIND(hide_description, MOM_HIDE_DESCRIPTION);
    BIND(play_sound, MOM_PLAY_SOUND);
}

/* The refusal text, with the value found and the one reviewed, so a log tells a game update from data not filled in
 * yet (zero). */
static int Differs(const char** why, const char* what, uint32_t rva, uint32_t reviewed)
{
    static char text[128];
    uint32_t found = vpm_game_u32(rva);
    if (found == reviewed) return 0;
    snprintf(text, sizeof text, "%s (game.dll+0x%X holds 0x%08X, reviewed 0x%08X)", what, rva, found, reviewed);
    *why = text;
    return 1;
}

static int LabelsAsReviewed(const char** why)
{
    for (uint32_t i = 0; i < 3; i++)
        if (Differs(why, "tab labels changed", MOM_TAB_LABELS_RVA + i * 4u, mom_tab_labels[i])) return 0;
    for (uint32_t i = 0; i < 9; i++)
        if (Differs(why, "category labels changed", MOM_CATEGORY_TABLE_RVA + i * MOM_CATEGORY_RECORD + 8u,
                mom_category_labels[i]))
            return 0;
    if (Differs(why, "setting descriptors changed", MOM_INERT_DESCRIPTOR_RVA, INERT_SETTING) ||
        Differs(why, "setting descriptors changed", MOM_INERT_DESCRIPTOR_RVA + 4u, INERT_CATEGORY) ||
        Differs(why, "setting descriptors changed", MOM_INERT_DESCRIPTOR_RVA + 12u, 0))
        return 0;
    return 1;
}

const char* mom_native_verify(void)
{
    uintptr_t base = vpm_game();
    if (base == 0) return "game modules unavailable";
    const char* reason = NULL;
    if (!LabelsAsReviewed(&reason)) return reason;
    Bind(base);
    return NULL;
}
