/* Mod Bindings Menu's texts: UTF-8 checks, lengths in characters and upper case for every script the game's fonts carry
 * (the Lua's bingus_text.lua decode, check, length and upper, and mod_bindings_menu.lua's display_text and resolve). */
#include <string.h>
#include "mbm.h"

/* UTF-8 lead bytes: {first, last, continuation bytes, value base, the second byte's lowest and highest}. */
static const uint8_t kMbmLeads[][6] = {
    {0xC2, 0xDF, 1, 0xC0, 0x80, 0xBF}, {0xE0, 0xE0, 2, 0xE0, 0xA0, 0xBF}, {0xE1, 0xEC, 2, 0xE0, 0x80, 0xBF},
    {0xED, 0xED, 2, 0xE0, 0x80, 0x9F}, {0xEE, 0xEF, 2, 0xE0, 0x80, 0xBF}, {0xF0, 0xF0, 3, 0xF0, 0x90, 0xBF},
    {0xF1, 0xF3, 3, 0xF0, 0x80, 0xBF}, {0xF4, 0xF4, 3, 0xF0, 0x80, 0x8F},
};

/* A lead byte's continuation count (-1 invalid), its first value and the second byte's range. */
static int MbmLead(unsigned c, uint32_t* value, unsigned* lo, unsigned* hi)
{
    for (size_t i = 0; i < sizeof kMbmLeads / sizeof kMbmLeads[0]; i++)
    {
        const uint8_t* lead = kMbmLeads[i];
        if (c < lead[0] || c > lead[1]) continue;
        *value = c - lead[3];
        *lo = lead[4];
        *hi = lead[5];
        return lead[2];
    }
    return -1;
}

/* The code point at text and its byte length, or 0 when the bytes are not valid UTF-8 (overlong forms, surrogates and
 * values above U+10FFFF are invalid). */
static int MbmDecode(const unsigned char* text, uint32_t* value)
{
    if (text[0] < 0x80) { *value = text[0]; return 1; }
    uint32_t v = 0;
    unsigned lo = 0, hi = 0;
    int n = MbmLead(text[0], &v, &lo, &hi);
    if (n < 0) return 0;
    for (int k = 1; k <= n; k++)
    {
        if (text[k] < lo || text[k] > hi) return 0;
        v = v * 64 + (text[k] - 0x80u);
        lo = 0x80;
        hi = 0xBF;
    }
    *value = v;
    return n + 1;
}

static int MbmEncode(uint32_t v, char* out)
{
    if (v < 0x80) { out[0] = (char)v; return 1; }
    if (v < 0x800) { out[0] = (char)(0xC0 + (v >> 6)); out[1] = (char)(0x80 + (v & 63)); return 2; }
    if (v < 0x10000)
    {
        out[0] = (char)(0xE0 + (v >> 12));
        out[1] = (char)(0x80 + ((v >> 6) & 63));
        out[2] = (char)(0x80 + (v & 63));
        return 3;
    }
    out[0] = (char)(0xF0 + (v >> 18));
    out[1] = (char)(0x80 + ((v >> 12) & 63));
    out[2] = (char)(0x80 + ((v >> 6) & 63));
    out[3] = (char)(0x80 + (v & 63));
    return 4;
}

int mbm_text_length(const char* text)
{
    int count = 0;
    for (const unsigned char* p = (const unsigned char*)text; *p != 0; count++)
    {
        uint32_t value;
        int n = MbmDecode(p, &value);
        p += n > 0 ? n : 1;
    }
    return count;
}

/* Valid UTF-8 without control characters. */
static int MbmCheck(const char* text)
{
    for (const unsigned char* p = (const unsigned char*)text; *p != 0;)
    {
        uint32_t v;
        int n = MbmDecode(p, &v);
        if (n == 0 || v < 32 || v == 127 || (v >= 0x80 && v < 0xA0)) return 0;
        p += n;
    }
    return 1;
}

static uint32_t MbmUpperLatin(uint32_t v)
{
    if (v == 0x131) return 0x49;
    if (v == 0x17F) return 0x53;
    if ((v >= 0x139 && v <= 0x148) || (v >= 0x179 && v <= 0x17E)) return v % 2 == 0 ? v - 1 : v;
    if (v != 0x138 && v != 0x149 && v != 0x130) return v % 2 == 1 ? v - 1 : v;
    return v;
}

static uint32_t MbmUpperGreek(uint32_t v)
{
    if (v >= 0x3B1 && v <= 0x3CB) return v == 0x3C2 ? 0x3A3 : v - 32;
    if (v == 0x3AC) return 0x386;
    if (v >= 0x3AD && v <= 0x3AF) return v - 37;
    if (v == 0x3CC) return 0x38C;
    if (v == 0x3CD || v == 0x3CE) return v - 63;
    return v;
}

static uint32_t MbmUpperCyrillic(uint32_t v)
{
    if (v >= 0x430 && v <= 0x44F) return v - 32;
    if (v >= 0x450 && v <= 0x45F) return v - 80;
    return v == 0x491 ? 0x490 : v;
}

/* ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic; other characters stay as they are. */
static uint32_t MbmUpperValue(uint32_t v)
{
    if (v < 0x80) return v >= 0x61 && v <= 0x7A ? v - 32 : v;
    if (v >= 0xE0 && v <= 0xFE && v != 0xF7) return v - 32;
    if (v == 0xFF) return 0x178;
    if (v >= 0x100 && v <= 0x17F) return MbmUpperLatin(v);
    if (v >= 0x386 && v <= 0x3CE) return MbmUpperGreek(v);
    return v >= 0x430 && v <= 0x491 ? MbmUpperCyrillic(v) : v;
}

/* Upper case of text into out (never longer than text); bytes that are not UTF-8 are copied. */
void mbm_upper(const char* text, char* out, size_t size)
{
    size_t at = 0;
    for (const unsigned char* p = (const unsigned char*)text; *p != 0 && at + 5 < size;)
    {
        uint32_t value;
        int n = MbmDecode(p, &value);
        if (n == 0) { out[at++] = (char)*p++; continue; }
        uint32_t upper = MbmUpperValue(value);
        if (upper == value) memcpy(out + at, p, (size_t)n);
        at += upper == value ? (size_t)n : (size_t)MbmEncode(upper, out + at);
        p += n;
    }
    out[at] = 0;
}

/* A registered text as the rows show it: at most limit characters, control characters as spaces, trimmed, upper case;
 * 0 when it is not a usable text (empty, or not UTF-8). */
int mbm_display_text(const char* text, int limit, char* out, size_t size)
{
    char spaced[MBM_TEXT_SIZE];
    size_t n = text != NULL ? strlen(text) : 0;
    if (text == NULL || n >= sizeof spaced || mbm_text_length(text) > limit) return 0;
    size_t start = 0, end = n;
    for (size_t i = 0; i < n; i++) spaced[i] = (unsigned char)text[i] < 32 || text[i] == 127 ? ' ' : text[i];
    while (start < end && spaced[start] == ' ') start++;
    while (end > start && spaced[end - 1] == ' ') end--;
    spaced[end] = 0;
    mbm_upper(spaced + start, out, size);
    return out[0] != 0 && MbmCheck(out);
}
