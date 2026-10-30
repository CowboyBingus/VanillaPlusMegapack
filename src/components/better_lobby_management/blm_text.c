/* Better Lobby Management: texts (locales/en.lua and zh-Hans.lua through vpm_text), the texts the game's widgets show
 * (kept for the session) and placeholders (the core's format()). Upper case for the game's fonts (bingus_text.lua
 * upper) and the UTF-8 cut of texts and chat lines (chat.lua cut, bingus_text.lua clip) are the core's (vpm_upper,
 * vpm_utf8_clip). */
#include <stdio.h>
#include "blm.h"

/* The game's widgets keep pointers to the texts they show, also after the escape screen that showed them is gone (the
 * Lua kept every text as long as the addon). 512 distinct texts a session (a few per squad member and privacy setting);
 * past that the oldest slot is reused. */
#define TEXT_SLOTS 512
#define TEXT_SIZE 384

static char g_texts[TEXT_SLOTS][TEXT_SIZE];
static int g_textCount, g_textNext;

void blm_text_reset(void)
{
    g_textCount = g_textNext = 0;
}

const char* blm_tr(const char* key, const char* english) { return vpm_text(blm_component, key, english); }

const char* blm_intern(const char* text)
{
    for (int i = 0; i < g_textCount; i++)
        if (strcmp(g_texts[i], text) == 0) return g_texts[i];
    char* slot = g_texts[g_textNext];
    size_t n = vpm_utf8_clip(text, TEXT_SIZE - 1);
    memcpy(slot, text, n);
    slot[n] = 0;
    g_textNext = (g_textNext + 1) % TEXT_SLOTS;
    if (g_textCount < TEXT_SLOTS) g_textCount++;
    return slot;
}

void blm_format(char* out, size_t size, const char* template_text, const char* placeholder, const char* value)
{
    char name[64];
    size_t n = strlen(placeholder);
    if (n >= 2 && placeholder[0] == '{' && placeholder[n - 1] == '}') { placeholder++; n -= 2; }
    if (n >= sizeof name) n = sizeof name - 1;
    memcpy(name, placeholder, n);
    name[n] = 0;
    const char* names[] = {name};
    const char* values[] = {value};
    vpm_text_format(out, size, template_text, names, values, 1);
}
