/* UTF-8 text for the components that show text: the shared Lua text module's decode, encode, check, length, upper and
 * clip (Translations/bingus_text.lua v1 in the research workspace, which every Lua component carried a copy of), in one
 * C copy. Nothing here runs per frame unless a component shows text on that frame; nothing allocates. */
#include <string.h>
#include "vpm.h"

/* A lead byte: the continuation bytes it needs (0: it starts no character), its bits of the value, and the range of
 * the first continuation byte (which rules out overlong forms, surrogates and values above U+10FFFF). */
static int Lead(unsigned c, uint32_t* value, unsigned* lo, unsigned* hi)
{
    *lo = c == 0xE0 ? 0xA0 : c == 0xF0 ? 0x90 : 0x80;
    *hi = c == 0xED ? 0x9F : c == 0xF4 ? 0x8F : 0xBF;
    if (c >= 0xC2 && c <= 0xDF) { *value = c - 0xC0; return 1; }
    if (c >= 0xE0 && c <= 0xEF) { *value = c - 0xE0; return 2; }
    if (c >= 0xF0 && c <= 0xF4) { *value = c - 0xF0; return 3; }
    return 0;
}

int vpm_utf8_decode(const char* text, size_t size, uint32_t* value)
{
    const unsigned char* t = (const unsigned char*)text;
    if (size == 0) return 0;
    if (t[0] < 0x80) { *value = t[0]; return 1; }
    uint32_t v;
    unsigned lo, hi;
    int n = Lead(t[0], &v, &lo, &hi);
    if (n == 0 || (size_t)n >= size) return 0;
    for (int k = 1; k <= n; k++)
    {
        if (t[k] < lo || t[k] > hi) return 0;
        v = v * 64 + (t[k] - 0x80u);
        lo = 0x80;
        hi = 0xBF;
    }
    *value = v;
    return n + 1;
}

int vpm_utf8_encode(uint32_t value, char* out)
{
    unsigned char* o = (unsigned char*)out;
    if (value < 0x80) { o[0] = (unsigned char)value; return 1; }
    if (value < 0x800) { o[0] = (unsigned char)(0xC0 + value / 64); o[1] = (unsigned char)(0x80 + value % 64); return 2; }
    if (value < 0x10000)
    {
        o[0] = (unsigned char)(0xE0 + value / 4096);
        o[1] = (unsigned char)(0x80 + value / 64 % 64);
        o[2] = (unsigned char)(0x80 + value % 64);
        return 3;
    }
    o[0] = (unsigned char)(0xF0 + value / 262144);
    o[1] = (unsigned char)(0x80 + value / 4096 % 64);
    o[2] = (unsigned char)(0x80 + value / 64 % 64);
    o[3] = (unsigned char)(0x80 + value % 64);
    return 4;
}

/* A character no mod shows: the C0 controls (a line feed only where multiline allows it), DEL and the C1 controls. */
static int Control(uint32_t v, int multiline)
{
    return (v < 32 && !(multiline && v == 10)) || v == 127 || (v >= 0x80 && v < 0xA0);
}

/* The check's refusal (-1 or -2) at a 1-based byte, 0 for no text at all. */
static int Refuse(int refusal, size_t at, size_t* bad)
{
    if (bad != NULL) *bad = at;
    return refusal;
}

int vpm_utf8_check(const char* text, int multiline, size_t* bad)
{
    if (text == NULL) return Refuse(-1, 0, bad); /* the Lua's "not a string" */
    size_t n = strlen(text);
    for (size_t i = 0; i < n;)
    {
        uint32_t v;
        int length = vpm_utf8_decode(text + i, n - i, &v);
        if (length == 0) return Refuse(-1, i + 1, bad);
        if (Control(v, multiline)) return Refuse(-2, i + 1, bad);
        i += (size_t)length;
    }
    return 1;
}

size_t vpm_utf8_length(const char* text, size_t size)
{
    size_t count = 0;
    for (size_t i = 0; i < size; count++)
    {
        uint32_t v;
        int length = vpm_utf8_decode(text + i, size - i, &v);
        i += length > 0 ? (size_t)length : 1;
    }
    return count;
}

/* Extended-A (Polish, Czech...): the letters come in pairs, upper case first, except in the two ranges where the lower
 * case is the even one. */
static uint32_t UpperExtendedA(uint32_t v)
{
    if (v == 0x131) return 0x49;
    if (v == 0x17F) return 0x53;
    if ((v >= 0x139 && v <= 0x148) || (v >= 0x179 && v <= 0x17E)) return v % 2 == 0 ? v - 1 : v;
    if (v != 0x138 && v != 0x149 && v != 0x130) return v % 2 == 1 ? v - 1 : v;
    return v;
}

static uint32_t UpperGreekCyrillic(uint32_t v)
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

uint32_t vpm_upper_char(uint32_t v)
{
    if (v < 0x80) return v >= 0x61 && v <= 0x7A ? v - 32 : v;
    if (v >= 0xE0 && v <= 0xFE && v != 0xF7) return v - 32;
    if (v == 0xFF) return 0x178;
    if (v >= 0x100 && v <= 0x17F) return UpperExtendedA(v);
    return UpperGreekCyrillic(v);
}

size_t vpm_upper(const char* text, char* out, size_t size)
{
    size_t n = strlen(text), at = 0;
    if (size == 0) return 0;
    for (size_t i = 0; i < n;)
    {
        uint32_t v;
        int length = vpm_utf8_decode(text + i, n - i, &v);
        char bytes[4];
        int written = 1;
        if (length == 0) { bytes[0] = text[i]; length = 1; }
        else
        {
            uint32_t upper = vpm_upper_char(v);
            if (upper != v) written = vpm_utf8_encode(upper, bytes);
            else { memcpy(bytes, text + i, (size_t)length); written = length; }
        }
        if (at + (size_t)written >= size) break;
        memcpy(out + at, bytes, (size_t)written);
        at += (size_t)written;
        i += (size_t)length;
    }
    out[at] = 0;
    return at;
}

size_t vpm_utf8_clip(const char* text, size_t bytes)
{
    size_t n = strlen(text);
    if (n <= bytes) return n;
    size_t i = bytes;
    while (i > 0 && ((unsigned char)text[i] & 0xC0) == 0x80) i--;
    return i;
}
