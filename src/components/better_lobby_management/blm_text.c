/* Better Lobby Management: texts (locales/en.lua through vpm_text, English), the texts the game's widgets show (kept for
 * the session), placeholders, upper case for the game's fonts (bingus_text.lua upper) and the chat's UTF-8 cut. */
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
    size_t n = blm_cut(text, TEXT_SIZE - 1);
    memcpy(slot, text, n);
    slot[n] = 0;
    g_textNext = (g_textNext + 1) % TEXT_SLOTS;
    if (g_textCount < TEXT_SLOTS) g_textCount++;
    return slot;
}

void blm_format(char* out, size_t size, const char* template_text, const char* placeholder, const char* value)
{
    size_t n = 0, key = strlen(placeholder), length = strlen(value);
    for (const char* p = template_text; *p && n + 1 < size;)
    {
        if (strncmp(p, placeholder, key) == 0)
        {
            size_t copy = length < size - 1 - n ? length : size - 1 - n;
            memcpy(out + n, value, copy);
            n += copy;
            p += key;
            continue;
        }
        out[n++] = *p++;
    }
    out[n] = 0;
}

/* ---- UTF-8 (bingus_text.lua decode, encode, upper) ----------------------------------------------------------------- */

/* A lead byte's continuation bytes and its bits of the value (0: not a lead byte). */
static int Continuations(uint8_t c, int32_t* value)
{
    if (c >= 0xC2 && c <= 0xDF) { *value = c - 0xC0; return 1; }
    if (c >= 0xE0 && c <= 0xEF) { *value = c - 0xE0; return 2; }
    if (c >= 0xF0 && c <= 0xF4) { *value = c - 0xF0; return 3; }
    return 0;
}

/* The code point at text (its byte length in *length), or -1 when the bytes there are not valid UTF-8. */
static int32_t Decode(const uint8_t* text, int* length)
{
    uint8_t c = text[0];
    if (c < 0x80) { *length = 1; return c; }
    int32_t value;
    int n = Continuations(c, &value);
    if (n == 0) return -1;
    uint8_t lo = c == 0xE0 ? 0xA0 : c == 0xF0 ? 0x90 : 0x80;
    uint8_t hi = c == 0xED ? 0x9F : c == 0xF4 ? 0x8F : 0xBF;
    for (int k = 1; k <= n; k++)
    {
        uint8_t d = text[k];
        if (d < lo || d > hi) return -1;
        value = value * 64 + (d - 0x80);
        lo = 0x80;
        hi = 0xBF;
    }
    *length = n + 1;
    return value;
}

static int Encode(int32_t value, uint8_t* out)
{
    if (value < 0x80) { out[0] = (uint8_t)value; return 1; }
    if (value < 0x800)
    {
        out[0] = (uint8_t)(0xC0 + value / 64);
        out[1] = (uint8_t)(0x80 + value % 64);
        return 2;
    }
    if (value < 0x10000)
    {
        out[0] = (uint8_t)(0xE0 + value / 4096);
        out[1] = (uint8_t)(0x80 + value / 64 % 64);
        out[2] = (uint8_t)(0x80 + value % 64);
        return 3;
    }
    out[0] = (uint8_t)(0xF0 + value / 262144);
    out[1] = (uint8_t)(0x80 + value / 4096 % 64);
    out[2] = (uint8_t)(0x80 + value / 64 % 64);
    out[3] = (uint8_t)(0x80 + value % 64);
    return 4;
}

/* Latin Extended-A: pairs of upper and lower case, with the Lua's exceptions. */
static int32_t UpperExtendedA(int32_t v)
{
    if (v == 0x131) return 0x49;
    if (v == 0x17F) return 0x53;
    if ((v >= 0x139 && v <= 0x148) || (v >= 0x179 && v <= 0x17E)) return v % 2 == 0 ? v - 1 : v;
    if (v != 0x138 && v != 0x149 && v != 0x130) return v % 2 == 1 ? v - 1 : v;
    return v;
}

/* Greek and Cyrillic lower case. */
static int32_t UpperGreekCyrillic(int32_t v)
{
    if (v >= 0x3B1 && v <= 0x3CB) return v == 0x3C2 ? 0x3A3 : v - 32;
    if (v == 0x3AC) return 0x386;
    if (v >= 0x3AD && v <= 0x3AF) return v - 37;
    if (v == 0x3CC) return 0x38C;
    if (v == 0x3CD || v == 0x3CE) return v - 63;
    if (v >= 0x430 && v <= 0x44F) return v - 32;
    if (v >= 0x450 && v <= 0x45F) return v - 80;
    if (v == 0x491) return 0x490;
    return v;
}

/* ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic; other characters (CJK, digits, sharp s) stay. */
static int32_t UpperValue(int32_t v)
{
    if (v < 0x80) return (v >= 0x61 && v <= 0x7A) ? v - 32 : v;
    if (v >= 0xE0 && v <= 0xFE && v != 0xF7) return v - 32;
    if (v == 0xFF) return 0x178;
    if (v >= 0x100 && v <= 0x17F) return UpperExtendedA(v);
    return UpperGreekCyrillic(v);
}

void blm_upper(const char* in, char* out, size_t size)
{
    const uint8_t* p = (const uint8_t*)in;
    size_t n = 0;
    while (*p)
    {
        uint8_t bytes[4];
        int length = 1, count = 1;
        int32_t value = Decode(p, &length);
        if (value < 0) { bytes[0] = *p; length = 1; }
        else count = Encode(UpperValue(value), bytes);
        if (value >= 0 && UpperValue(value) == value) { memcpy(bytes, p, (size_t)length); count = length; }
        if (n + (size_t)count + 1 > size) break;
        memcpy(out + n, bytes, (size_t)count);
        n += (size_t)count;
        p += length;
    }
    out[n] = 0;
}

size_t blm_cut(const char* text, size_t max)
{
    size_t length = strlen(text);
    if (length <= max) return length;
    size_t n = max;
    while (n > 0 && ((uint8_t)text[n] & 0xC0) == 0x80) n--;
    return n;
}
