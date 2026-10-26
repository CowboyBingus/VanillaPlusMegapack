/* Mod Options Menu: the texts the MODS tab shows (the Lua's options.lua display_text and translation.resolve, and the
 * parts of the shared text module they use: UTF-8 checks, character counts, upper case).
 *
 * Text widgets keep a pointer to the text they show, and a hidden widget may still point at one after the MODS view
 * closes, until the game re-initialises that widget. So every text lives in one buffer for the session, one buffer per
 * distinct text: a widget shows a text when its argument is that text's address (widgets.c). The buffers are static
 * (no allocation); Start resets them. */
#include <stdio.h>
#include <string.h>
#include "mom.h"

#define POOL_SIZE (256u * 1024u)
#define MAX_TEXTS 2048
#define WORK_SIZE 1664 /* 400 characters of up to 4 bytes */

static char g_pool[POOL_SIZE];
static uint32_t g_used;
static uint32_t g_at[MAX_TEXTS], g_hash[MAX_TEXTS];
static int g_count;
static int g_fullLogged;

void mom_text_reset(void)
{
    g_used = 0;
    g_count = 0;
    g_fullLogged = 0;
}

static uint32_t Hash(const char* text)
{
    uint32_t h = 2166136261u;
    for (const unsigned char* p = (const unsigned char*)text; *p; p++) h = (h ^ *p) * 16777619u;
    return h;
}

const char* mom_intern(const char* text)
{
    uint32_t h = Hash(text);
    for (int i = 0; i < g_count; i++)
        if (g_hash[i] == h && strcmp(g_pool + g_at[i], text) == 0) return g_pool + g_at[i];
    size_t n = strlen(text) + 1;
    if (g_count >= MAX_TEXTS || n > POOL_SIZE - g_used)
    {
        if (!g_fullLogged) vpm_log(mom.self, "Text buffers full: further texts show as ?.");
        g_fullLogged = 1;
        return "?";
    }
    memcpy(g_pool + g_used, text, n);
    g_at[g_count] = g_used;
    g_hash[g_count++] = h;
    g_used += (uint32_t)n;
    return g_pool + g_at[g_count - 1];
}

/* ---- UTF-8 ------------------------------------------------------------------------------------------------------ */

/* The code point at t[i] and its length in bytes, or 0 when the bytes are not valid UTF-8 (overlong forms, surrogates and
 * values above U+10FFFF are invalid). */
/* A lead byte's continuation count (0: it starts no code point), its value bits and the first continuation byte's
 * range. */
static int Lead(unsigned c, uint32_t* value, unsigned* lo, unsigned* hi)
{
    *lo = c == 0xE0 ? 0xA0 : c == 0xF0 ? 0x90 : 0x80;
    *hi = c == 0xED ? 0x9F : c == 0xF4 ? 0x8F : 0xBF;
    if (c >= 0xC2 && c <= 0xDF) { *value = c - 0xC0; return 1; }
    if (c >= 0xE0 && c <= 0xEF) { *value = c - 0xE0; return 2; }
    if (c >= 0xF0 && c <= 0xF4) { *value = c - 0xF0; return 3; }
    return 0;
}

static int Decode(const unsigned char* t, uint32_t* value)
{
    unsigned c = t[0], lo, hi;
    if (c < 0x80) { *value = c; return 1; }
    int n = Lead(c, value, &lo, &hi);
    if (n == 0) return 0;
    for (int k = 1; k <= n; k++)
    {
        unsigned d = t[k];
        if (d < lo || d > hi) return 0;
        *value = *value * 64u + (d - 0x80u);
        lo = 0x80;
        hi = 0xBF;
    }
    return n + 1;
}

static int Encode(uint32_t v, char* out)
{
    if (v < 0x80) { out[0] = (char)v; return 1; }
    if (v < 0x800) { out[0] = (char)(0xC0 + v / 64); out[1] = (char)(0x80 + v % 64); return 2; }
    out[0] = (char)(0xE0 + v / 4096);
    out[1] = (char)(0x80 + v / 64 % 64);
    out[2] = (char)(0x80 + v % 64);
    return 3; /* the upper-case table maps nothing above U+FFFF */
}

/* Characters (code points; an invalid byte counts as one). */
static size_t Length(const char* text)
{
    size_t count = 0;
    for (const unsigned char* p = (const unsigned char*)text; *p; count++)
    {
        uint32_t v;
        int n = Decode(p, &v);
        p += n > 0 ? n : 1;
    }
    return count;
}

/* Valid UTF-8 without control characters (C0, DEL, C1). */
static int Valid(const char* text)
{
    for (const unsigned char* p = (const unsigned char*)text; *p;)
    {
        uint32_t v;
        int n = Decode(p, &v);
        if (n == 0 || v < 32 || v == 127 || (v >= 0x80 && v < 0xA0)) return 0;
        p += n;
    }
    return 1;
}

/* Control bytes as spaces, then leading and trailing white space trimmed (display_text). */
static void Display(const char* text, char* out, size_t size)
{
    while (*text == ' ' || (*text > 0 && *text < 32) || *text == 127) text++;
    size_t n = 0;
    for (; *text && n + 1 < size; text++) out[n++] = (*text > 0 && *text < 32) || *text == 127 ? ' ' : *text;
    while (n > 0 && out[n - 1] == ' ') n--;
    out[n] = 0;
}

const char* mom_text_resolve(const char* text, size_t limit)
{
    static char work[WORK_SIZE];
    if (text == NULL || Length(text) > limit || strlen(text) >= sizeof work) return NULL;
    Display(text, work, sizeof work);
    if (work[0] == 0 || !Valid(work)) return NULL;
    return mom_intern(work);
}

/* ---- upper case -------------------------------------------------------------------------------------------------- */

static uint32_t UpperLatin(uint32_t v)
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

static uint32_t Upper(uint32_t v)
{
    if (v < 0x80) return v >= 0x61 && v <= 0x7A ? v - 32 : v;
    if (v >= 0xE0 && v <= 0xFE && v != 0xF7) return v - 32;
    if (v == 0xFF) return 0x178;
    if (v >= 0x100 && v <= 0x17F) return UpperLatin(v);
    return UpperGreekCyrillic(v);
}

const char* mom_text_upper(const char* text)
{
    static char work[WORK_SIZE];
    size_t n = 0;
    for (const unsigned char* p = (const unsigned char*)text; *p && n + 4 < sizeof work;)
    {
        uint32_t v;
        int length = Decode(p, &v);
        if (length == 0) { work[n++] = (char)*p++; continue; }
        uint32_t upper = Upper(v);
        if (upper != v) n += (size_t)Encode(upper, work + n);
        else { memcpy(work + n, p, (size_t)length); n += (size_t)length; }
        p += length;
    }
    work[n] = 0;
    return mom_intern(work);
}

const char* mom_text_page(const char* format, int page, int pages)
{
    static char work[256];
    size_t n = 0;
    for (const char* p = format; *p && n + 12 < sizeof work;)
    {
        if (strncmp(p, "{pages}", 7) == 0) { n += (size_t)snprintf(work + n, sizeof work - n, "%d", pages); p += 7; }
        else if (strncmp(p, "{page}", 6) == 0) { n += (size_t)snprintf(work + n, sizeof work - n, "%d", page); p += 6; }
        else work[n++] = *p++;
    }
    work[n] = 0;
    return mom_intern(work);
}
