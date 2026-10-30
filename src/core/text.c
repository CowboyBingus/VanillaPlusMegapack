/* The components' texts: the shared Lua text module's decode, encode, check, length, upper and clip
 * (Translations/bingus_text.lua v1 in the research workspace, which every Lua component carried a copy of), its
 * format(), and its language choice (the game's Text Language, mapped to a tag, with English fallback), in one C copy.
 * The per-component strings themselves are the generator's (src/components/<id>/locale_data.c). Nothing here runs per
 * frame unless a component shows text on that frame; nothing allocates. A language read (vpm_text_refresh) is 0 to 3
 * heap reads (4 when the 16-byte code read falls back to 8), when the first text asks for it and at the menu openings
 * that observe it (Mod Options Menu, Better Lobby Management). */
#include <stdio.h>
#include <string.h>
#include "vpm_core.h"

/* The game's Text Language in bingus_text.lua v1: the settings object at game.dll+0x3326340, its language index at
 * +705500+212, and 15 records at game.dll+0x37C5650 whose code string is at +8. */
#define TEXT_SETTINGS_RVA 0x3326340u
#define TEXT_SETTINGS_INDEX (705500u + 212u)
#define TEXT_TABLE_RVA 0x37C5650u
#define TEXT_LANGUAGES 15
#define TEXT_TAG 17 /* a 16-character tag and its NUL */

typedef struct TextCode { const char* code; const char* tag; } TextCode;

/* Record codes to BCP 47 tags, as bingus_text.lua's GAME_CODES: only 'us' is confirmed; the rest are the game's code
 * spellings. A code not here is kept as its own tag, so no translation matches it and English shows. */
static const TextCode kGameCodes[] = {
    {"us", "en"}, {"en", "en"}, {"en-US", "en"}, {"uk", "en-GB"}, {"gb", "en-GB"}, {"en-GB", "en-GB"},
    {"de", "de"}, {"fr", "fr"}, {"it", "it"}, {"es", "es"}, {"es-ES", "es"}, {"mx", "es-419"}, {"es-MX", "es-419"},
    {"es-419", "es-419"}, {"pl", "pl"}, {"ru", "ru"}, {"jp", "ja"}, {"ja", "ja"}, {"kr", "ko"}, {"ko", "ko"},
    {"br", "pt-BR"}, {"pt-BR", "pt-BR"}, {"pt", "pt"}, {"zh-CN", "zh-Hans"}, {"cn", "zh-Hans"}, {"zh", "zh-Hans"},
    {"zhs", "zh-Hans"}, {"zh-TW", "zh-Hant"}, {"tw", "zh-Hant"}, {"zht", "zh-Hant"}, {"cz", "cs"}, {"cs", "cs"},
    {"gr", "el"}, {"el", "el"}, {"nl", "nl"}, {"tr", "tr"}, {"ua", "uk"},
};

/* Steam's language names (ISteamApps::GetCurrentGameLanguage) to tags, as bingus_text.lua's STEAM. */
static const TextCode kSteamLanguages[] = {
    {"english", "en"}, {"schinese", "zh-Hans"}, {"tchinese", "zh-Hant"}, {"koreana", "ko"}, {"japanese", "ja"},
    {"russian", "ru"}, {"polish", "pl"}, {"french", "fr"}, {"german", "de"}, {"italian", "it"}, {"spanish", "es"},
    {"latam", "es-419"}, {"brazilian", "pt-BR"}, {"portuguese", "pt"}, {"ukrainian", "uk"}, {"czech", "cs"},
    {"dutch", "nl"}, {"turkish", "tr"}, {"thai", "th"}, {"vietnamese", "vi"}, {"danish", "da"}, {"finnish", "fi"},
    {"norwegian", "no"}, {"swedish", "sv"}, {"hungarian", "hu"}, {"romanian", "ro"}, {"bulgarian", "bg"},
    {"greek", "el"}, {"arabic", "ar"}, {"indonesian", "id"},
};

static char g_language[TEXT_TAG] = "en"; /* the game's tag, once read */
static int g_gameLanguage;               /* g_language is the game's (not Steam's, not English) */
static int g_autoObserved;               /* the first vpm_text had its one look */
static int g_steamTried;                 /* Steam's language was asked once */
static char g_steamLanguage[TEXT_TAG];

static int Letter(unsigned char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
static int TagChar(unsigned char c) { return Letter(c) || (c >= '0' && c <= '9') || c == '-'; }

static const char* TableTag(const TextCode* table, int count, const char* value)
{
    for (int i = 0; i < count; i++)
        if (strcmp(table[i].code, value) == 0) return table[i].tag;
    return NULL;
}

/* A tag a Steam language may carry: valid_tag's pattern (two letters, an optional third, an optional hyphen, then
 * letters, digits and hyphens; 16 characters at most), so an unknown Steam name is never used as a game tag. */
static int TagFits(const char* value)
{
    size_t n = strlen(value);
    if (n < 2 || n >= TEXT_TAG || !Letter((unsigned char)value[0]) || !Letter((unsigned char)value[1])) return 0;
    size_t i = 2;
    if (i < n && Letter((unsigned char)value[i])) i++;
    if (i < n && value[i] == '-') i++;
    for (; i < n; i++)
        if (!TagChar((unsigned char)value[i])) return 0;
    return 1;
}

/* The code bytes at the record: the settings object's language index, the record's string pointer, then the 16-byte
 * read or, when it failed, the 8-byte one, as the Lua's load(text, 16) or load(text, 8). The table's first entry is a
 * plain image load: when it is absent, [game+0x3326340] is not the settings object (some tests reuse that RVA for the
 * game object), so the index is not read. */
static int GameCodeBytes(char* bytes, size_t* n)
{
    if (!vpm_plausible((uintptr_t)vpm_game_u64(TEXT_TABLE_RVA))) return 0;
    uint64_t settings = vpm_game_u64(TEXT_SETTINGS_RVA);
    if (!vpm_plausible((uintptr_t)settings)) return 0;
    uint32_t index = 0;
    if (!vpm_read_u32((uintptr_t)settings + TEXT_SETTINGS_INDEX, &index) || index >= TEXT_LANGUAGES) return 0;
    uint64_t record = vpm_game_u64(TEXT_TABLE_RVA + 8u * index);
    if (!vpm_plausible((uintptr_t)record)) return 0;
    uint64_t text = 0;
    if (!vpm_read_u64((uintptr_t)record + 8, &text) || !vpm_plausible((uintptr_t)text)) return 0;
    if (vpm_read((uintptr_t)text, bytes, 16)) { *n = 16; return 1; }
    if (vpm_read((uintptr_t)text, bytes, 8)) { *n = 8; return 1; }
    return 0;
}

/* The bytes matched as the Lua did: a letter, then letters and hyphens, then NUL; 12 characters at most. */
static int GameCodeMatch(const char* bytes, size_t n, char* out, size_t size)
{
    if (n == 0 || !Letter((unsigned char)bytes[0])) return 0;
    size_t length = 0;
    while (length < n && bytes[length] != 0)
    {
        if (length > 0 && !(Letter((unsigned char)bytes[length]) || bytes[length] == '-')) return 0;
        length++;
    }
    if (length == 0 || length > 12 || length >= n || length + 1 > size) return 0;
    memcpy(out, bytes, length);
    out[length] = 0;
    return 1;
}

/* The code string at the record. */
static int GameCode(char* out, size_t size)
{
    char bytes[16];
    size_t n = 0;
    if (!GameCodeBytes(bytes, &n)) return 0;
    return GameCodeMatch(bytes, n, out, size);
}

void vpm_text_reset(void)
{
    snprintf(g_language, sizeof g_language, "%s", "en");
    g_gameLanguage = g_autoObserved = g_steamTried = 0;
    g_steamLanguage[0] = 0;
}

/* Steam's current game language: two lookups in steam_api64.dll (the game has it loaded; nothing is loaded) and two
 * calls into it, once per session and only when the game's setting cannot be read, as bingus_text's steam_language. */
static const char* SteamLanguage(void)
{
    typedef void* (__cdecl* SteamAppsFn)(void);
    typedef const char* (__cdecl* SteamLanguageFn)(void* apps);
    SteamAppsFn apps_fn = (SteamAppsFn)(void*)vpm_module_export("steam_api64.dll", "SteamAPI_SteamApps_v008");
    SteamLanguageFn language_fn =
        (SteamLanguageFn)(void*)vpm_module_export("steam_api64.dll", "SteamAPI_ISteamApps_GetCurrentGameLanguage");
    if (apps_fn == NULL || language_fn == NULL) return NULL;
    void* apps = apps_fn();
    return apps != NULL ? language_fn(apps) : NULL;
}

/* The tag vpm_text resolves with now. The first text of a session looks the game's setting up once; if it cannot be
 * read, Steam's language is asked once, then "en". */
static const char* CurrentLanguage(void)
{
    if (!g_gameLanguage && !g_autoObserved) (void)vpm_text_refresh();
    if (g_gameLanguage) return g_language;
    if (!g_steamTried)
    {
        g_steamTried = 1;
        const char* name = SteamLanguage();
        if (name != NULL)
        {
            const char* tag = TableTag(kSteamLanguages, (int)(sizeof kSteamLanguages / sizeof kSteamLanguages[0]), name);
            if (tag == NULL && TagFits(name)) tag = name;
            if (tag != NULL) snprintf(g_steamLanguage, sizeof g_steamLanguage, "%s", tag);
        }
    }
    return g_steamLanguage[0] != 0 ? g_steamLanguage : "en";
}

int vpm_text_refresh(void)
{
    g_autoObserved = 1;
    char code[TEXT_TAG];
    if (!GameCode(code, sizeof code)) return 0;
    const char* tag = TableTag(kGameCodes, (int)(sizeof kGameCodes / sizeof kGameCodes[0]), code);
    if (tag == NULL) tag = code;
    if (strlen(tag) >= sizeof g_language) return 0;
    snprintf(g_language, sizeof g_language, "%s", tag);
    g_gameLanguage = 1;
    return 1;
}

const char* vpm_text_language(void) { return CurrentLanguage(); }

void vpm_text_table(VpmComponent* self, const VpmTextTable* table)
{
    if (self != NULL) self->texts = table;
}

static const VpmTextLocale* FindLocale(const VpmTextTable* table, const char* tag)
{
    if (table == NULL || table->locales == NULL || tag == NULL) return NULL;
    for (int i = 0; i < table->count; i++)
        if (table->locales[i].tag != NULL && strcmp(table->locales[i].tag, tag) == 0) return &table->locales[i];
    return NULL;
}

static const char* LookupText(const VpmTextLocale* locale, const char* key)
{
    if (locale == NULL || locale->entries == NULL) return NULL;
    for (int i = 0; i < locale->count; i++)
        if (locale->entries[i].key != NULL && strcmp(locale->entries[i].key, key) == 0) return locale->entries[i].text;
    return NULL;
}

const char* vpm_text(const VpmComponent* self, const char* key, const char* english)
{
    if (key == NULL) return english;
    const VpmTextTable* table = self != NULL ? self->texts : NULL;
    if (table == NULL) return english;
    const char* language = CurrentLanguage();
    const char* text = LookupText(FindLocale(table, language), key);
    if (text == NULL)
    {
        const char* dash = strchr(language, '-');
        if (dash != NULL)
        {
            char base[TEXT_TAG];
            size_t n = (size_t)(dash - language);
            if (n < sizeof base)
            {
                memcpy(base, language, n);
                base[n] = 0;
                text = LookupText(FindLocale(table, base), key);
            }
        }
    }
    if (text == NULL) text = LookupText(FindLocale(table, "en"), key);
    return text != NULL ? text : english;
}

/* {[A-Za-z_][A-Za-z0-9_]*}: the Lua's placeholder pattern, ASCII as its %a and %w are here. */
static int Placeholder(const char* text, size_t* name)
{
    const char* p = text + 1;
    if (!(Letter((unsigned char)*p) || *p == '_')) return 0;
    size_t n = 1;
    while (p[n] != 0 && (Letter((unsigned char)p[n]) || (p[n] >= '0' && p[n] <= '9') || p[n] == '_')) n++;
    if (p[n] != '}') return 0;
    *name = n;
    return 1;
}

/* The value for a placeholder's name (the bytes between its braces), or NULL when no names[i] matches. */
static const char* FormatValue(const char* name, size_t length, const char* const* names,
    const char* const* values, int count)
{
    for (int i = 0; i < count; i++)
        if (names[i] != NULL && strlen(names[i]) == length && memcmp(names[i], name, length) == 0)
            return values[i];
    return NULL;
}

/* Copies as much of value as fits, and returns how much was copied. */
static size_t FormatCopy(char* out, size_t size, size_t written, const char* value, size_t length)
{
    size_t room = size - 1 - written;
    size_t copy = length < room ? length : room;
    memcpy(out + written, value, copy);
    return copy;
}

size_t vpm_text_format(char* out, size_t size, const char* text, const char* const* names, const char* const* values,
    int count)
{
    if (out == NULL || size == 0) return 0;
    if (text == NULL) text = "";
    size_t written = 0, needed = 0;
    for (const char* p = text; *p;)
    {
        size_t name = 0;
        const char* value = NULL;
        if (*p == '{' && Placeholder(p, &name))
            value = FormatValue(p + 1, name, names, values, count);
        if (value != NULL)
        {
            size_t n = strlen(value);
            written += FormatCopy(out, size, written, value, n);
            needed += n;
            p += name + 2;
            continue;
        }
        if (written + 1 < size) out[written++] = *p;
        needed++;
        p++;
    }
    out[written] = 0;
    return needed;
}

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
