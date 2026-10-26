/* Mod Bindings Menu's texts as the rows show them (mod_bindings_menu.lua's display_text and resolve). The UTF-8 checks,
 * lengths in characters and upper case for every script the game's fonts carry (the Lua's bingus_text.lua decode,
 * check, length and upper) are the core's (core text.c). */
#include <string.h>
#include "mbm.h"

/* A registered text as the rows show it: at most limit characters, control characters as spaces, trimmed, upper case;
 * 0 when it is not a usable text (empty, or not UTF-8). */
int mbm_display_text(const char* text, int limit, char* out, size_t size)
{
    char spaced[MBM_TEXT_SIZE];
    size_t n = text != NULL ? strlen(text) : 0;
    if (text == NULL || n >= sizeof spaced || limit < 0 || vpm_utf8_length(text, n) > (size_t)limit) return 0;
    size_t start = 0, end = n;
    for (size_t i = 0; i < n; i++) spaced[i] = (unsigned char)text[i] < 32 || text[i] == 127 ? ' ' : text[i];
    while (start < end && spaced[start] == ' ') start++;
    while (end > start && spaced[end - 1] == ' ') end--;
    spaced[end] = 0;
    vpm_upper(spaced + start, out, size);
    return out[0] != 0 && vpm_utf8_check(out, 0, NULL) == 1;
}
