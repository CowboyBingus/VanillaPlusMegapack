/* Mod Options Menu: the texts the MODS tab shows (the Lua's options.lua display_text and translation.resolve). The
 * shared text module's parts they use (UTF-8 checks, character counts, upper case) are the core's one copy (vpm.h
 * "text", core text.c), and the lengths the Lua's register_option checked are the core's registration checks: here a
 * text is only checked for what the tab can show (valid UTF-8 without control characters, not blank).
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

/* ---- shown texts ----------------------------------------------------------------------------------------------- */

/* Control bytes as spaces, then leading and trailing white space trimmed (display_text). */
static void Display(const char* text, char* out, size_t size)
{
    while (*text == ' ' || (*text > 0 && *text < 32) || *text == 127) text++;
    size_t n = 0;
    for (; *text && n + 1 < size; text++) out[n++] = (*text > 0 && *text < 32) || *text == 127 ? ' ' : *text;
    while (n > 0 && out[n - 1] == ' ') n--;
    out[n] = 0;
}

const char* mom_text_resolve(const char* text)
{
    static char work[WORK_SIZE];
    if (text == NULL || strlen(text) >= sizeof work) return NULL;
    Display(text, work, sizeof work);
    if (work[0] == 0 || vpm_utf8_check(work, 0, NULL) != 1) return NULL;
    return mom_intern(work);
}

const char* mom_text_named(const char* name, size_t limit)
{
    if (name == NULL || vpm_utf8_length(name, strlen(name)) > limit) return NULL;
    return mom_text_resolve(name);
}

const char* mom_text_upper(const char* text)
{
    static char work[WORK_SIZE];
    vpm_upper(text, work, sizeof work);
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
