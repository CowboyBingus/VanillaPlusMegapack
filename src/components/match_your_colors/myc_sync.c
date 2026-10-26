/* Match Your Colors: Sync With Mod Users (sync.lua), 1:1. Each player's color settings travel as a PlayFab lobby member
 * property of the squad's lobby (KEY2 'cbmyc2': 'v=;m=;f=;s=;' fields, and KEY 'cbmyc' for v1.3-v1.4's copies); every
 * mod user then recolors the others' Helldivers locally (myc_remote.c). Lobby: network context [game + 0x347CEF0],
 * engine lobby +0x1D470, its PlayFab lobby +0x10: members +0x100, state +0x118 (3 joined), handle +0x120, the local
 * user's entity key +0x130. PlayFab's exports come from PlayFabMultiplayerWin.dll (vpm_module_export, once per session;
 * on HellForge the multiplayer stand-in serves them). Posts are rare: once per lobby and after an options change has
 * settled; a post names the local user by PlayFab's own key of the local member. Game thread, on the sync poll only. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_squad.h"

#define SYNC_DLL "PlayFabMultiplayerWin.dll"
#define VERSION 1
#define LEVEL 1
#define CONTEXT 0x347CEF0u
#define LOBBY 0x1D470u
#define PLAYFAB 0x10u
#define PL_MEMBERS 0x100u
#define PL_STATE 0x118u
#define PL_HANDLE 0x120u
#define PL_USER 0x130u
#define JOINED 3
#define LEGACY_FLAGS 15
#define MODES 4
#define SCHEMES 64

static const char* const kMycKeys[2] = {MYC_SYNC_KEY2, MYC_SYNC_KEY};
static char myc_sync_values[2][MYC_SYNC_TEXT_MAX + 1];
static const char* myc_sync_value_ptrs[2];
static MycMemberUpdate myc_sync_update = {2, kMycKeys, myc_sync_value_ptrs};

int myc_settings_same(const MycSettings* a, const MycSettings* b)
{
    return a->mode == b->mode && a->keep_sets == b->keep_sets && a->recolor_hoods == b->recolor_hoods
        && a->match_materials == b->match_materials && a->recolor_cape == b->recolor_cape && a->scheme == b->scheme
        && a->recolor_weapons == b->recolor_weapons && a->source_kit == b->source_kit && a->source_cape == b->source_cape;
}

/* ---- values ------------------------------------------------------------------------------------------------------- */

static int MycSyncFlags(const MycSettings* o)
{
    return (o->keep_sets ? 1 : 0) + (o->recolor_hoods ? 2 : 0) + (o->match_materials ? 4 : 0) + (o->recolor_cape ? 8 : 0)
        + (o->recolor_weapons ? 16 : 0) + (o->cape_hidden ? 32 : 0);
}

void myc_sync_encode(const MycSettings* o, char* out, size_t size)
{
    snprintf(out, size, "v=%d;m=%d;f=%d;s=%d;", LEVEL, o->mode, MycSyncFlags(o), o->scheme);
}

void myc_sync_legacy(const MycSettings* o, char* out, size_t size)
{
    snprintf(out, size, "%d|%d|%d|%d", VERSION, o->mode, MycSyncFlags(o) % (LEGACY_FLAGS + 1), o->scheme);
}

static int MycSyncOptions(double mode, double flags, double scheme, MycSettings* out)
{
    if (mode < 1 || mode > MODES || mode != (double)(long long)mode || scheme > SCHEMES || scheme != (double)(long long)scheme) return 0;
    memset(out, 0, sizeof *out);
    out->mode = (int)mode;
    out->scheme = (int)scheme;
    long long f = (long long)flags;
    out->keep_sets = (f & 1) != 0;
    out->recolor_hoods = (f & 2) != 0;
    out->match_materials = (f & 4) != 0;
    out->recolor_cape = (f & 8) != 0;
    out->recolor_weapons = (f & 16) != 0;
    out->cape_hidden = (f & 32) != 0;
    return 1;
}

/* A decimal number of digits only (Lua's %d+), into *out; the text after it. */
static const char* MycSyncDigits(const char* p, double* out)
{
    const char* start = p;
    double v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    *out = v;
    return p > start ? p : NULL;
}

/* '<version>|<mode>|<flags>|<scheme>' (v1.3-v1.4's): 1 decoded, 0 refused, -1 not that format. */
static int MycSyncLegacyDecode(const char* text, MycSettings* out)
{
    double v[4];
    const char* p = text;
    for (int i = 0; i < 4; i++)
    {
        p = MycSyncDigits(p, &v[i]);
        if (p == NULL || (i < 3 && *p != '|') || (i == 3 && *p != 0)) return -1;
        if (i < 3) p++;
    }
    if (v[0] != VERSION || v[2] > LEGACY_FLAGS) return 0;
    return MycSyncOptions(v[1], v[2], v[3], out);
}

static int MycSyncNameChar(char c, int first)
{
    int alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    return first ? alpha : alpha || (c >= '0' && c <= '9');
}

/* KEY2's fields v, m, f, s (a list of 'name=value;' or refused); 1 when well formed. */
static int MycSyncFields(const char* text, char fields[4][MYC_SYNC_TEXT_MAX + 1], int has[4])
{
    static const char* const names[4] = {"v", "m", "f", "s"};
    const char* p = text;
    for (int i = 0; i < 4; i++) has[i] = 0;
    while (*p)
    {
        const char* name = p;
        if (!MycSyncNameChar(*p, 1)) return 0;
        while (MycSyncNameChar(*p, 0)) p++;
        size_t name_len = (size_t)(p - name);
        if (*p++ != '=') return 0;
        const char* value = p;
        while (*p && *p != ';' && *p != '=') p++;
        if (*p != ';') return 0;
        for (int i = 0; i < 4; i++)
            if (name_len == 1 && name[0] == names[i][0])
            {
                memcpy(fields[i], value, (size_t)(p - value));
                fields[i][p - value] = 0;
                has[i] = 1;
            }
        p++;
    }
    return 1;
}

/* Lua's tonumber of a field: a number (decimal, or 0x hex), else none. */
static int MycSyncNumber(const char* text, double* out)
{
    char* end = NULL;
    if (*text == 0) return 0;
    *out = strtod(text, &end);
    while (end != NULL && (*end == ' ' || *end == '\t')) end++;
    return end != NULL && *end == 0 && *out == *out;
}

int myc_sync_decode(const char* text, MycSettings* out)
{
    size_t n = text != NULL ? strlen(text) : 0;
    if (n == 0 || n > MYC_SYNC_TEXT_MAX) return 0;
    int legacy = MycSyncLegacyDecode(text, out);
    if (legacy >= 0) return legacy;
    char fields[4][MYC_SYNC_TEXT_MAX + 1];
    int has[4];
    double level, mode, flags = 0, scheme = 0;
    if (!MycSyncFields(text, fields, has) || !has[0] || !MycSyncNumber(fields[0], &level) || level > LEVEL) return 0;
    if (has[2] && !MycSyncNumber(fields[2], &flags)) return 0;
    if (flags < 0 || flags != (double)(long long)flags || flags >= 2147483648.0) return 0;
    if (!has[1] || !MycSyncNumber(fields[1], &mode)) return 0;
    if (has[3] && !MycSyncNumber(fields[3], &scheme)) return 0;
    return MycSyncOptions(mode, flags, scheme, out);
}

int myc_sync_peer_of(const char* id, uint32_t* low, uint32_t* high)
{
    size_t n = id != NULL ? strlen(id) : 0;
    if (n < 1 || n > 16) return 0;
    for (size_t i = 0; i < n; i++)
    {
        char c = id[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return 0;
    }
    uint64_t v = strtoull(id, NULL, 16);
    *low = (uint32_t)v;
    *high = (uint32_t)(v >> 32);
    return 1;
}

/* ---- reads -------------------------------------------------------------------------------------------------------- */

static int MycSyncRead(uintptr_t address, void* out, size_t size)
{
    if (address < 0x10000 || address >= 0x800000000000ull) return 0;
    return vpm_read(address, out, size);
}

static uint64_t MycSyncU64(uintptr_t address)
{
    uint64_t v = 0;
    return MycSyncRead(address, &v, 8) ? v : 0;
}

/* A C string up to TEXT_MAX bytes (shorter reads when a long one fails); 0 when it does not end within the bytes read. */
static int MycSyncText(uintptr_t address, char* out)
{
    static const size_t sizes[6] = {MYC_SYNC_TEXT_MAX + 1, 64, 48, 24, 16, 8};
    char b[MYC_SYNC_TEXT_MAX + 1];
    for (int i = 0; i < 6; i++)
    {
        if (!MycSyncRead(address, b, sizes[i])) continue;
        size_t n = 0;
        while (n < sizes[i] && b[n] != 0) n++;
        if (n == sizes[i]) return 0;
        memcpy(out, b, n + 1);
        return 1;
    }
    return 0;
}

/* ---- the session -------------------------------------------------------------------------------------------------- */

void myc_sync_init(MycSync* s, void (*note)(const char* line))
{
    memset(s, 0, sizeof *s);
    s->note = note;
}

static int MycSyncNatives(MycSync* s)
{
    if (s->natives_tried) return s->natives_ok;
    s->natives_tried = 1;
    s->post = (MycPostUpdate)vpm_module_export(SYNC_DLL, "PFLobbyPostUpdate");
    s->members = (MycGetMembers)vpm_module_export(SYNC_DLL, "PFLobbyGetMembers");
    s->property = (MycGetMemberProperty)vpm_module_export(SYNC_DLL, "PFLobbyGetMemberProperty");
    s->natives_ok = s->post != NULL && s->members != NULL && s->property != NULL;
    if (!s->natives_ok)
        s->note(s->post == NULL && s->members == NULL && s->property == NULL ? "Sync: " SYNC_DLL " not loaded."
            : "Sync: PlayFab lobby exports missing.");
    return s->natives_ok;
}

/* The squad's PlayFab lobby (lobby): 0 when there is none. */
static int MycSyncLobby(MycSync* s)
{
    uint64_t context = vpm_game_u64(CONTEXT);
    uint64_t engine = context != 0 ? MycSyncU64((uintptr_t)context + LOBBY) : 0;
    uint64_t pl = engine != 0 ? MycSyncU64((uintptr_t)engine + PLAYFAB) : 0;
    uint32_t halves[2];
    if (pl == 0 || !MycSyncRead((uintptr_t)pl + PL_HANDLE, halves, 8) || (halves[0] == 0 && halves[1] == 0)) return 0;
    if (!s->has_lobby || halves[0] != s->low || halves[1] != s->high)
    {
        s->low = halves[0];
        s->high = halves[1];
        s->has_lobby = 1;
        s->has_since = 0;
    }
    uint64_t id_at = MycSyncU64((uintptr_t)pl + PL_USER);
    s->has_id = id_at != 0 && MycSyncText((uintptr_t)id_at, s->id);
    uint32_t state = 0;
    s->joined = MycSyncRead((uintptr_t)pl + PL_STATE, &state, 4) && state == JOINED;
    return 1;
}

static uint64_t MycSyncHandle(const MycSync* s) { return (uint64_t)s->high << 32 | s->low; }

/* One member's value into the next record: KEY2's, else (no KEY2) KEY's. */
static void MycSyncMember(MycSync* s, uintptr_t key_at, uint32_t low, uint32_t high, int own)
{
    const char* value = NULL;
    int32_t result = s->property(MycSyncHandle(s), (const MycEntityKey*)key_at, MYC_SYNC_KEY2, &value);
    if (result == 0 && value == NULL) result = s->property(MycSyncHandle(s), (const MycEntityKey*)key_at, MYC_SYNC_KEY, &value);
    MycMember* m = &s->list[s->nlist++];
    memset(m, 0, sizeof *m);
    m->peer_low = low;
    m->peer_high = high;
    m->is_local = own;
    m->has_text = result == 0 && value != NULL && MycSyncText((uintptr_t)value, m->text);
    m->failed = result != 0;
}

static void MycSyncMembers(MycSync* s, int include_local)
{
    s->nlist = 0;
    s->own = 0;
    uint32_t count = 0;
    const MycEntityKey* array = NULL;
    if (s->members(MycSyncHandle(s), &count, &array) != 0) return;
    for (uint32_t i = 0; i < (count < MYC_SYNC_MAX_MEMBERS ? count : MYC_SYNC_MAX_MEMBERS); i++)
    {
        uintptr_t key_at = (uintptr_t)array + 16 * (uintptr_t)i;
        char id[MYC_SYNC_TEXT_MAX + 1], type[MYC_SYNC_TEXT_MAX + 1];
        int has_id = MycSyncText((uintptr_t)MycSyncU64(key_at), id);
        uint32_t low, high;
        int peer = has_id && myc_sync_peer_of(id, &low, &high);
        int own = has_id && s->has_id && strcmp(id, s->id) == 0;
        if (own && MycSyncText((uintptr_t)MycSyncU64(key_at + 8), type)) s->own = key_at;
        if (peer && (include_local || !own)) MycSyncMember(s, key_at, low, high, own);
    }
}

static int MycSyncPostedHere(const MycSync* s) { return s->has_posted && s->posted_low == s->low && s->posted_high == s->high; }

static void MycSyncPost(MycSync* s, uint32_t frame, const char* text)
{
    MycSettings options;
    int legacy = text != NULL && myc_sync_decode(text, &options);
    if (text != NULL) { snprintf(myc_sync_values[0], sizeof myc_sync_values[0], "%s", text); myc_sync_value_ptrs[0] = myc_sync_values[0]; }
    else myc_sync_value_ptrs[0] = NULL;
    if (legacy) { myc_sync_legacy(&options, myc_sync_values[1], sizeof myc_sync_values[1]); myc_sync_value_ptrs[1] = myc_sync_values[1]; }
    else myc_sync_value_ptrs[1] = NULL;
    int32_t result = s->post(MycSyncHandle(s), (const MycEntityKey*)s->own, NULL, &myc_sync_update, NULL);
    s->next_post = frame + MYC_SYNC_POST_DELAY_FRAMES;
    char line[192];
    if (result == 0)
    {
        s->has_posted = 1;
        s->posted_low = s->low;
        s->posted_high = s->high;
        s->posted_text_set = text != NULL;
        snprintf(s->posted_text, sizeof s->posted_text, "%s", text != NULL ? text : "");
        s->posts++;
        if (text != NULL) snprintf(line, sizeof line, "Sync: shared %s.", text);
        else snprintf(line, sizeof line, "Sync: sharing removed.");
    }
    else
    {
        s->failures++;
        s->next_post = frame + MYC_SYNC_RETRY_FRAMES;
        snprintf(line, sizeof line, "Sync: post failed (0x%08X); retrying later.", (uint32_t)result);
    }
    s->note(line);
}

static int MycSyncSameText(int a_set, const char* a, const char* b) { return b == NULL ? !a_set : (a_set && strcmp(a, b) == 0); }

/* Posts the value when it differs from what this lobby has and has settled (maybe_post). */
static void MycSyncMaybePost(MycSync* s, uint32_t frame, const char* text)
{
    if (!MycSyncSameText(s->pending_set, s->pending, text))
    {
        s->pending_set = text != NULL;
        snprintf(s->pending, sizeof s->pending, "%s", text != NULL ? text : "");
        s->changed_at = frame;
    }
    int due = !MycSyncSameText(s->posted_text_set, s->posted_text, text) || !MycSyncPostedHere(s);
    if (!due || frame < s->next_post || frame - s->changed_at < MYC_SYNC_POST_DELAY_FRAMES) return;
    if (text == NULL && !MycSyncPostedHere(s))
    {
        s->has_posted = 1;
        s->posted_low = s->low;
        s->posted_high = s->high;
        s->posted_text_set = 0;
        return;
    }
    if (s->own == 0 || frame - s->since < MYC_SYNC_STEADY_FRAMES) return;
    MycSyncPost(s, frame, text);
}

int myc_sync_poll(MycSync* s, uint32_t frame, const char* text, int include_local)
{
    int lobby = MycSyncLobby(s);
    if (!lobby || !s->joined || !s->has_id || !MycSyncNatives(s))
    {
        if (lobby) s->has_since = 0;
        return -1;
    }
    if (!s->has_since) { s->since = frame; s->has_since = 1; }
    MycSyncMembers(s, include_local);
    MycSyncMaybePost(s, frame, text);
    return text == NULL ? -1 : s->nlist;
}
