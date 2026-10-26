/* Mod Options Menu: game.dll's native functions, labels and setting descriptor, verified once per session (the Lua's
 * native.lua initialize). The Lua compared each function's first bytes in memory; here vpm_game_code_matches compares
 * them as the game shipped them, so a hook another mod or HellForge placed on one of them does not fail the check (the
 * call then runs through that hook, as any call into game.dll would). The build itself is the core's check. */
#include <stdio.h>
#include "../../core/vpm.h"
#include "native.h"

const MomNativeEntry mom_native_entries[MOM_NATIVE_COUNT] = {
    [MOM_SET_TAB_LABELS] = {"set_tab_labels", 0x17AAC50u, "48 89 54 24 10 53 56 48 83 EC 68 0F 29 74 24 30"},
    [MOM_SELECT_CATEGORY] = {"select_category", 0x19999C0u, "40 53 48 83 EC 20 48 8B D9 89 91 58 1E 14 00 39"},
    [MOM_SET_CONTENT_HIDDEN] = {"set_content_hidden", 0x19984C0u, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 50 41"},
    [MOM_ROW_RESET] = {"row_reset", 0x17FF700u, "48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55"},
    [MOM_ROW_RELEASE] = {"row_release", 0x17FF4B0u, "48 89 5C 24 08 57 48 83 EC 20 8B 81 C0 7A 00 00"},
    [MOM_ROW_INIT] = {"row_init", 0x17FE8D0u, "48 89 5C 24 08 57 48 83 EC 70 48 8B BC 24 B0 00"},
    [MOM_ADD_CHILD] = {"add_child", 0x144C5C0u, "40 53 48 83 EC 20 4C 8B CA 48 8B D9 48 8B 91 E0"},
    [MOM_SET_VISIBLE] = {"set_visible", 0x144CFB0u, "48 83 EC 28 44 8B 01 4C 8B D1 41 8B C0 45 8B C8"},
    [MOM_SET_LABEL] = {"set_label", 0x143BF90u, "48 83 EC 28 4C 8B D9 39 91 10 01 00 00 0F 84 80"},
    [MOM_SET_STRING_ARG] = {"set_string_arg", 0x143C950u, "40 53 48 83 EC 20 48 8B D9 48 81 C1 10 01 00 00"},
    [MOM_CLEAR_ARGS] = {"clear_args", 0x143A0F0u, "80 B9 58 01 00 00 00 C6 81 58 01 00 00 00 0F 97"},
    [MOM_SET_CHOICE] = {"set_choice", 0x17FE7E0u, "80 B9 F8 32 00 00 00 74 28 83 FA 10 73 23 48 63"},
    [MOM_SET_SLIDER] = {"set_slider", 0x17FC2C0u, "40 53 48 83 EC 20 F3 0F 10 91 AC 08 00 00 48 8B"},
    [MOM_FINISH_SIMPLE] = {"finish_simple", 0x1807060u, "48 89 5C 24 08 57 48 83 EC 30 8B 81 10 0B 00 00"},
    [MOM_FINISH_ACCESS] = {"finish_access", 0x1800FE0u, "48 89 5C 24 08 57 48 83 EC 30 8B 81 50 57 00 00"},
    [MOM_SCROLL_THUMB] = {"scroll_thumb", 0x1793F60u, "48 89 5C 24 10 57 48 83 EC 40 48 8B D9 0F 29 74"},
    [MOM_SCROLL_EXTENT] = {"scroll_extent", 0x1794600u, "F3 0F 10 A1 B0 07 00 00 0F 28 D1 0F 2E E2 7A 02"},
    [MOM_SET_OPACITY] = {"set_opacity", 0x1448AD0u, "40 57 48 83 EC 20 F3 0F 10 41 44 48 8B F9 0F 2E"},
    [MOM_SCROLL_RESET] = {"scroll_reset", 0x1794570u, "80 B9 B5 07 00 00 00 74 19 F3 0F 10 89 BC 07 00"},
    [MOM_OPTIONS_VISUAL] = {"options_visual", 0x1998590u, "48 8B C4 57 48 83 EC 70 80 B9 15 22 14 00 00 48"},
    [MOM_MEASURE_TEXT] = {"measure_text", 0x144E1A0u, "40 53 48 83 EC 70 48 8B D9 8B 09 8B C1 C1 E8 12"},
    /* Position and size share their first 27 bytes; byte 28 picks the field. */
    [MOM_SET_POSITION] = {"set_position", 0x14476A0u,
        "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3 0F 10 41 04"},
    [MOM_SET_SIZE] = {"set_size", 0x1447160u,
        "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3 0F 10 41 0C"},
    [MOM_HIDE_DESCRIPTION] = {"hide_description", 0x17FAB90u, "48 89 5C 24 10 57 48 83 EC 70 0F B6 DA 48 8B F9"},
    [MOM_PLAY_SOUND] = {"play_sound", 0x1327F50u, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48"},
};

const uint32_t mom_tab_labels[3] = {0xD876B36Eu, 0x78934E12u, 0x8C02BD80u};
const uint32_t mom_category_labels[9] = {0x396F27D7u, 0x196248D0u, 0xA522D2D0u, 0x15CECAC1u, 0x9A688238u,
    0x07E3B100u, 0x5DB3B764u, 0xA7C345EFu, 0x9BB47B92u};

/* Rows use setting 139 (a BINDINGS activation type): the settings lookup finds it, its value type is none, and no
 * category handler special-cases it, so changing a MODS row never reads or writes a game setting. */
#define INERT_SETTING 139u
#define INERT_CATEGORY 10u

MomNative mom_native;

static void* At(uintptr_t base, int index) { return (void*)(base + mom_native_entries[index].rva); }

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

static int LabelsAsReviewed(const char** why)
{
    for (uint32_t i = 0; i < 3; i++)
        if (vpm_game_u32(MOM_TAB_LABELS_RVA + i * 4u) != mom_tab_labels[i]) { *why = "tab labels changed"; return 0; }
    for (uint32_t i = 0; i < 9; i++)
        if (vpm_game_u32(MOM_CATEGORY_TABLE_RVA + i * MOM_CATEGORY_RECORD + 8u) != mom_category_labels[i])
        {
            *why = "category labels changed";
            return 0;
        }
    if (vpm_game_u32(MOM_INERT_DESCRIPTOR_RVA) != INERT_SETTING ||
        vpm_game_u32(MOM_INERT_DESCRIPTOR_RVA + 4u) != INERT_CATEGORY || vpm_game_u32(MOM_INERT_DESCRIPTOR_RVA + 12u) != 0)
    {
        *why = "setting descriptors changed";
        return 0;
    }
    return 1;
}

const char* mom_native_verify(char* why, size_t size)
{
    uintptr_t base = vpm_game();
    if (base == 0) return "game modules unavailable";
    for (int i = 0; i < MOM_NATIVE_COUNT; i++)
        if (!vpm_game_code_matches(mom_native_entries[i].rva, mom_native_entries[i].code))
        {
            snprintf(why, size, "%s changed", mom_native_entries[i].name);
            return why;
        }
    const char* reason = NULL;
    if (!LabelsAsReviewed(&reason)) return reason;
    Bind(base);
    return NULL;
}
