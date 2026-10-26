/* Better Lobby Management: the Lua tests' scenarios (components/BetterLobbyManagement/tests/test_*.lua: game, chat,
 * scanner, region, sos, menu, lobby, addon, idle gate) on the fake game. The game's natives the component calls are
 * fakes, reached through 12-byte jumps the test writes over their code once the component has checked it (the fake
 * images are data, so the jump pages are made executable). Calls per frame are pinned with the harness's counts (reads:
 * ReadProcessMemory) and the component's own page-check count (VirtualQuery); plain loads cost no call and are not
 * counted.
 *
 * Not ported, with the parts they test: the diagnostic recorder and the test builds' kick modes, unload hold and control
 * search (test_diag.lua, parts of test_lobby.lua and test_menu.lua), translations and the Text Language
 * (test_bingus_text.lua, test_locales.lua, the end of test_addon.lua), the Mod Options Menu registration retries and
 * the shared runtime's guard, pause and hostile neighbours (test_addon.lua), the idle gate's equivalence with v1.2 and
 * the LuaJIT trace and allocation checks (test_idle_gate.lua, test_scanner.lua), the Lua API layer and packaging
 * (test_windows_api.lua, test_ffi_names.lua, test_entry.lua, test_package.py), and the scanner's lost write (a plain
 * store always lands). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "harness/test.h"
#include "components.h"
#include "components/better_lobby_management/blm.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_better_lobby_management};

/* ---- the layout (the component's, repeated) ------------------------------------------------------------------- */

#define DT 0.016f
#define M_MENU_SYSTEM_PTR 0x347CE38u
#define M_SCREEN 200u
#define M_SHOWN 8u
#define M_CONTENT 281480u
#define M_CARDS 1371024u
#define M_CARD_SIZE 85552u
#define M_CARD_PEER 85504u
#define M_CARD_STATE 85512u
#define M_POPUP_OPEN 2u
#define M_BUTTONS 1714544u
#define M_BUTTON_SIZE 14920u
#define M_BUTTON_TEXT 1928u
#define M_BUTTON_LIST 1714272u
#define M_COUNT 1789912u
#define M_TYPES 1789913u
#define M_FOCUS 1970000u
#define M_DIALOG 1970288u
#define M_DIALOG_INACTIVE 1989648u
#define M_DIALOG_OPENING 1989649u
#define M_DIALOG_ANSWERED 1989650u
#define M_DIALOG_CONFIRMED 1989651u
#define M_HIDDEN 1989808u
#define M_DIALOG_FADE 1989812u
#define M_PANEL_STATE 1832636u
#define M_DIALOG_TITLE 1496u
#define M_DIALOG_BODY 2192u
#define M_DIALOG_STATE 19372u
#define M_LABEL 272u
#define M_WIDGET_X 4u
#define M_WIDGET_WIDTH 12u
#define M_TEXT_TEMPLATE 0xC67C7FAFu
#define M_CONFIRM_LABEL 0xD94B7608u
#define M_CANCEL_LABEL 0x8A36D40Au
#define M_CARD_POPUP 7144u
#define M_CARD_KICK_HOLD 85520u
#define M_PRESENTERS_PTR 0x347CE28u
#define M_MAIN_PRESENTER 0x4388u
#define M_PENDING_CLOSE 16u
#define M_SCREEN_SIZE 0x22C000u
#define C_CHAT 0xC418u
#define C_HISTORY_COUNT 0x9594u
#define C_NEW_HOST 0xB9E77C36u
#define B_SOS_PTR 0x3326BF0u
#define B_ACTIVE 8u
#define B_ENABLED 24u
#define B_PRIVACY 0xAC550u
#define B_KEYS 56u
#define B_KEY_SIZE 257u
#define B_PENDING 0x20u
#define B_COUNTDOWN 0x1B80u
#define B_PLAYERS_PTR 0x347CE50u
#define B_PLAYER_COUNT 0x2D200u
#define B_SLOTS 0x1C0u
#define B_SLOT_SIZE 0x30u
#define B_SLOT_COUNT 0x7C0u
#define B_STRATAGEMS 0x37CB600u
#define B_USES 0x50u
#define B_SHARED 0x94u
#define B_SOS_STRATAGEM 0x91u
#define B_NO_LIMIT 0xFFFFFFFFu
#define B_LIST_DISPLACEMENT 0x66D3DAu
#define R_CONFIG_PTR 0x347CDF8u
#define R_SYNCED 0x12078u
#define R_TABLE 0xC050u
#define R_ENTRIES 0x20u
#define R_COUNT 24u
#define R_CHECKSUM 0x6020u
#define R_CAPACITY 512u
#define R_ENTRY 48u
#define R_SPAN 0x6020u
#define R_BOOL 7u
#define R_WEIGHT 0x42C80000u
#define R_KEY_A 0x673BC524u
#define R_KEY_B 0x5DF5D36Bu
#define R_CONTINENT_IDS 0x21D45B0u
#define R_SERVER_CHECKSUM 0x6699F3E5u
#define S_CONFIG_PTR 0x347CEE0u
#define S_RECHARGE 0x3CE4Cu
#define S_COUNTDOWN 0x10BD74u
#define EXE_CLEAR_FILTERS 0x8C7620u
#define EXE_CONTINENT 0x8C5F20u
#define EXE_UNLOAD_PAUSED 0x321730u
#define EXE_PAUSE_UNLOADS 0x321750u
#define UNMAPPED 0x1BF00000000ull

#define ME 0x0A1B2C3D4E5F6071ull
#define TANGO 0x0100000000000005ull
#define CHARLIE 0x0A00000000000007ull
#define DELTA 0x0B00000000000009ull

/* ---- memory --------------------------------------------------------------------------------------------------- */

static int g_readOnly; /* regions the test made read-only: its own stores still go through */

static void Poke(uintptr_t at, const void* data, size_t size)
{
    MEMORY_BASIC_INFORMATION info;
    DWORD old;
    if (g_readOnly > 0 && VirtualQuery((const void*)at, &info, sizeof info) == sizeof info && (info.Protect & 0xFF) == PAGE_READONLY)
    {
        if (!VirtualProtect((void*)at, size, PAGE_READWRITE, &old)) { printf("unprotect failed\n"); exit(2); } /* lint-ok: C3 the test's own store into memory it made read-only */
        memcpy((void*)at, data, size);
        if (!VirtualProtect((void*)at, size, PAGE_READONLY, &old)) { printf("protect failed\n"); exit(2); } /* lint-ok: C3 and read-only again */
        return;
    }
    memcpy((void*)at, data, size);
}

static void ReadOnly(uintptr_t at, size_t size, int on)
{
    DWORD old;
    if (!VirtualProtect((void*)at, size, on ? PAGE_READONLY : PAGE_READWRITE, &old)) { printf("protect failed\n"); exit(2); } /* lint-ok: C3 the test makes fake memory read-only */
    g_readOnly += on ? 1 : -1;
}

static void Put8(uintptr_t at, uint8_t v) { Poke(at, &v, 1); }
static void Put32(uintptr_t at, uint32_t v) { Poke(at, &v, 4); }
static void Put64(uintptr_t at, uint64_t v) { Poke(at, &v, 8); }
static void PutF(uintptr_t at, float v) { Poke(at, &v, 4); }
static void PutString(uintptr_t at, const char* text) { Poke(at, text, strlen(text) + 1); }
static uint8_t Get8(uintptr_t at) { return *(const uint8_t*)at; }
static uint32_t Get32(uintptr_t at) { uint32_t v; memcpy(&v, (const void*)at, 4); return v; }
static uint64_t Get64(uintptr_t at) { uint64_t v; memcpy(&v, (const void*)at, 8); return v; }
static float GetF(uintptr_t at) { float v; memcpy(&v, (const void*)at, 4); return v; }
static uintptr_t Game(uint32_t rva) { return fake_game() + rva; }
static uintptr_t Exe(uint32_t rva) { return fake_exe() + rva; }
static uintptr_t Heap(size_t size) { return (uintptr_t)fake_heap(size); }

/* A heap object on pages of its own (so it can be made read-only alone). */
static uintptr_t Pages(size_t size)
{
    uintptr_t at = Heap(size + 0x2000);
    return (at + 0xFFF) & ~(uintptr_t)0xFFF;
}

/* An IDA-style pattern's bytes at an address; wildcards leave the bytes there. */
static void PutPattern(uintptr_t at, const char* pattern)
{
    for (const char* p = pattern; *p;)
    {
        if (*p == ' ') { p++; continue; }
        if (*p == '?') { at++; p += p[1] == '?' ? 2 : 1; continue; }
        char hex[3] = {p[0], p[1], 0};
        Put8(at++, (uint8_t)strtoul(hex, NULL, 16));
        p += 2;
    }
}

static void PutTable(uintptr_t base, const BlmCode* table, int count)
{
    for (int i = 0; i < count; i++) PutPattern(base + table[i].rva, table[i].pattern);
}

/* Changes one byte of a record's code: what a different build would have. */
static void ChangeCode(uintptr_t at) { Put8(at, (uint8_t)(Get8(at) ^ 0xFF)); }

/* ---- the native calls the component made -------------------------------------------------------------------- */

typedef struct Call { const char* name; uint64_t a, b, c, d; char text[128]; } Call;
#define MAX_CALLS 16384
static Call g_calls[MAX_CALLS];
static int g_callCount;
static char g_lastChat[1200];
static uint32_t g_rpcType, g_rpcSize;
static uint32_t g_dialogCancel;
static uint8_t g_dialogHold;

static void Record(const char* name, uint64_t a, uint64_t b, uint64_t c, uint64_t d, const char* text)
{
    if (g_callCount >= MAX_CALLS) return;
    Call* call = &g_calls[g_callCount++];
    *call = (Call){name, a, b, c, d, ""};
    if (text != NULL) snprintf(call->text, sizeof call->text, "%s", text);
}

static int Count(const char* name)
{
    int n = 0;
    for (int i = 0; i < g_callCount; i++) n += strcmp(g_calls[i].name, name) == 0;
    return n;
}

static const Call* Last(const char* name)
{
    static const Call none = {"", 0, 0, 0, 0, ""};
    for (int i = g_callCount - 1; i >= 0; i--)
        if (strcmp(g_calls[i].name, name) == 0) return &g_calls[i];
    return &none;
}

/* ---- the world ---------------------------------------------------------------------------------------------- */

#define MAX_SESSION 8
typedef struct Name { uint64_t id; char name[64]; } Name;
typedef struct Widget { uintptr_t at; uint32_t label; const char* text; float marquee; uintptr_t parent; } Widget;

typedef struct World
{
    uintptr_t ctx, state, roster, match, tables, lobbyApi, packageApi;
    uintptr_t config, main, synced, continentText, scannerConfig;
    uintptr_t sos, sosSettings, players, sosSlot;
    uintptr_t menu, screen, content, dialog, presenters, mainPresenter;
    uint64_t local, host;
    uint64_t session[MAX_SESSION];
    int sessionCount;
    uint32_t mode, hosting, transition, joinState;
    uint8_t partyJoin;
    Name names[8];
    int nameCount;
    uint64_t friends[4];
    int friendCount;
    uint32_t requests[2];
    int busy, count, searches, lobbyAfter, searchFrames, emptyConnection;
    int joinOutcome; /* 0 success, 1 refused, 2 stall */
    int joinFrames, joinStarted, joinStartedFrame, joinRefusesStart;
    uint64_t successor;
    uint64_t arrivals[MAX_SESSION];
    int arrivalCount;
    int keepRemoved;   /* the player menu's KICK fires but the player stays */
    int frame;
    uint8_t chatEnabled;
    uint64_t muted;
    uint8_t sosActive;
    uint32_t sosEnabled;
    uint64_t sosTime;
    uint32_t privacy;
    char playfab[2][8]; /* PlayFab's copy of lobby keys 8 and 19 */
    uint8_t nativeTypes[5];
    int nativeTypeCount;
    int continentKnown;
} World;

static World w;
static Widget g_widgets[64];
static int g_widgetCount;

static Widget* WidgetAt(uintptr_t at)
{
    for (int i = 0; i < g_widgetCount; i++)
        if (g_widgets[i].at == at) return &g_widgets[i];
    if (g_widgetCount >= 64) { printf("too many widgets\n"); exit(2); }
    g_widgets[g_widgetCount] = (Widget){at, 0, NULL, 0, 0};
    return &g_widgets[g_widgetCount++];
}

static const char* PeerName(uint64_t id, int slot, char* buffer, size_t size)
{
    for (int i = 0; i < w.nameCount; i++)
        if (w.names[i].id == id) return w.names[i].name;
    snprintf(buffer, size, "Diver%d", slot + 1);
    return buffer;
}

static void SetName(uint64_t id, const char* name)
{
    w.names[w.nameCount].id = id;
    snprintf(w.names[w.nameCount++].name, 64, "%s", name);
}

static uintptr_t KeyAddress(uint32_t index) { return w.ctx + BLM_LOBBY + B_KEYS + index * B_KEY_SIZE; }
static const char* Key(uint32_t index) { return (const char*)KeyAddress(index); }
static uint32_t SosUses(void) { return Get32(w.sosSlot + 4); }

/* The SOS object, as the game's SOS functions leave it. */
static void SyncSos(void)
{
    Put8(w.sos + B_ACTIVE, w.sosActive);
    Put32(w.sos + B_ENABLED, w.sosEnabled);
    Put64(w.sos, w.sosTime);
}

/* Writes the scenario into memory, as the Lua fake's sync: call before each frame. */
static void Sync(void)
{
    char buffer[16];
    Put32(w.state + BLM_MODE, w.mode);
    Put64(w.ctx + BLM_LOCAL, w.local);
    Put64(w.ctx + BLM_HOST, w.host);
    Put32(w.ctx + BLM_PEER_COUNT, (uint32_t)w.sessionCount);
    for (int i = 0; i < w.sessionCount; i++)
    {
        uintptr_t entry = w.ctx + BLM_PEERS + (uint32_t)i * BLM_PEER_STRIDE;
        Put64(entry, w.session[i]);
        Put32(entry + BLM_PEER_INDEX, (uint32_t)i);
    }
    Put32(w.ctx + BLM_HOST_SYNC + BLM_HS_STATE, w.hosting);
    Put32(w.ctx + BLM_HOST_SYNC + BLM_HS_TRANSITION, w.transition);
    Put32(w.ctx + BLM_JOIN, w.joinState);
    Put8(w.ctx + BLM_CLIENT_SYNC + BLM_CS_PARTY_JOIN, w.partyJoin);
    for (int slot = 0; slot < 4; slot++)
    {
        uintptr_t record = w.roster + (uint32_t)slot * 0xC0u;
        Put64(record, slot < w.sessionCount ? w.session[slot] : 0);
        if (slot < w.sessionCount) PutString(record + 8, PeerName(w.session[slot], slot, buffer, sizeof buffer));
    }
    Put32(w.match + BLM_REQUEST_QUICKPLAY + 4, w.requests[0]);
    Put32(w.match + BLM_REQUEST_SCANNER + 4, w.requests[1]);
    Put8(w.ctx + C_CHAT, w.chatEnabled);
    SyncSos();
    Put32(w.state + B_PRIVACY, w.privacy);
    Put64(w.players, w.local);
}

static void SetSession(int count, const uint64_t* peers)
{
    w.sessionCount = count;
    for (int i = 0; i < count; i++) w.session[i] = peers[i];
}

/* The host and squad members after it. */
static void Squad(int count, uint64_t a, uint64_t b)
{
    const uint64_t peers[3] = {w.local, a, b};
    SetSession(1 + count, peers);
    w.host = w.local;
    Sync();
}

static int RemoveFromSession(uint64_t peer)
{
    for (int i = 0; i < w.sessionCount; i++)
        if (w.session[i] == peer)
        {
            memmove(&w.session[i], &w.session[i + 1], (size_t)(w.sessionCount - i - 1) * sizeof w.session[0]);
            w.sessionCount--;
            return 1;
        }
    return 0;
}

static int Friend(uint64_t peer)
{
    for (int i = 0; i < w.friendCount; i++)
        if (w.friends[i] == peer) return 1;
    return 0;
}

/* Advances the scenario by one frame (browser, join), as the Lua fake's tick. */
static void WorldTick(void)
{
    w.frame++;
    if (w.busy > 0) w.busy--;
    if (w.joinState == 1 && w.joinStarted && w.frame - w.joinStartedFrame >= w.joinFrames)
    {
        if (w.joinOutcome == 0)
        {
            if (w.successor != 0) w.host = w.successor;
            w.joinState = w.hosting = 0;
            if (w.arrivalCount > 0) SetSession(w.arrivalCount, w.arrivals);
        }
        else if (w.joinOutcome == 1) { w.joinState = 0; w.hosting = 1; }
        w.joinStarted = 0;
    }
    Sync();
}

/* ---- the lobby's natives ---------------------------------------------------------------------------------------- */

static uint8_t FakeStartJoin(uint64_t join, uint64_t info, int32_t type, uint64_t unused, int32_t reason)
{
    Record("start_join", join, (uint64_t)type, unused, (uint64_t)reason, (const char*)(uintptr_t)(info + 72));
    if (w.joinRefusesStart) return 0;
    w.joinState = 1;
    w.hosting = 2;
    w.joinStarted = 1;
    w.joinStartedFrame = w.frame;
    return 1;
}

static void FakeFilterString(uint64_t field, int32_t key, uint64_t value, uint32_t op)
{
    Record("filter_string", field, (uint64_t)key, op, 0, (const char*)(uintptr_t)value);
}

static uint64_t FakeBrowserStart(uint64_t field)
{
    Record("browser_start", field, 0, 0, 0, NULL);
    w.busy = w.searchFrames;
    w.searches++;
    w.count = w.searches >= w.lobbyAfter ? 1 : 0;
    return 0;
}

static uint8_t FakeBrowserBusy(uint64_t field) { Record("browser_busy", field, 0, 0, 0, NULL); return w.busy > 0; }
static int32_t FakeBrowserCount(uint64_t field) { Record("browser_count", field, 0, 0, 0, NULL); return w.count; }

static uint64_t FakeBrowserResult(uint64_t field, uint64_t out, uint32_t index)
{
    char name[32];
    Record("browser_result", field, out, index, 0, NULL);
    snprintf(name, sizeof name, "lobby-%u", index);
    PutString(out, name);
    PutString(out + 72, w.emptyConnection ? "" : "connection-string-of-successor");
    return out;
}

static uint8_t FakeIsFriend(uint64_t unused, uint64_t peer) { Record("is_friend", peer, 0, 0, 0, NULL); return (uint8_t)Friend(peer); }
static void FakeClearFilters(uint64_t handle) { Record("clear_filters", handle, 0, 0, 0, NULL); }
static uint64_t FakeContinent(uint64_t self) { return w.continentKnown ? w.continentText : 0; }

/* ---- chat --------------------------------------------------------------------------------------------------------- */

static void FakeChatSend(uint64_t chat, uint64_t unused, uint64_t text)
{
    const char* line = (const char*)(uintptr_t)text;
    snprintf(g_lastChat, sizeof g_lastChat, "%s", line);
    Record("chat_send", chat, unused, strlen(line), 0, line);
    if (chat != w.ctx + C_CHAT || Get8(chat) == 0 || strlen(line) > 512) return;
    for (uint32_t i = 0; i < Get32(w.ctx + BLM_PEER_COUNT); i++)
    {
        uint64_t peer = Get64(w.ctx + BLM_PEERS + i * BLM_PEER_STRIDE);
        if (peer != Get64(w.ctx + BLM_LOCAL) && peer != w.muted) Record("chat_rpc", peer, 0, 0, 0, line);
    }
    Put32(chat + C_HISTORY_COUNT, Get32(chat + C_HISTORY_COUNT) + 1);
}

static void FakeRpcSend(uint32_t hash, uint64_t target, uint64_t args, uint32_t count)
{
    g_rpcType = Get32(args);
    g_rpcSize = Get32(args + 4);
    Record("rpc_send", hash, target, count, Get64(Get64(args + 8)), NULL);
}

/* ---- the SOS system and the lobby wrapper ------------------------------------------------------------------------ */

static int Hosting(void) { return w.host == w.local; }

/* The game's key setter: the text, and the key's pending bit when it changed. */
static void SetKey(uint32_t index, int32_t value)
{
    char text[16];
    snprintf(text, sizeof text, "%d", value);
    if (strcmp(Key(index), text) == 0) return;
    PutString(KeyAddress(index), text);
    uintptr_t lobby = w.ctx + BLM_LOBBY;
    Put32(lobby + B_PENDING, Get32(lobby + B_PENDING) | (1u << index));
}

/* The game's privacy setter: Public while PlayFab shows the SOS flag on. */
static void SetPrivacyKey(uint32_t value) { SetKey(19, strcmp(w.playfab[0], "0") != 0 ? 0 : (int32_t)value); }

static void SosOff(void)
{
    if (Hosting())
    {
        SetKey(8, 0);
        SetPrivacyKey(w.privacy);
    }
    w.sosActive = 0;
    w.sosTime = 0;
    SyncSos();
}

static void SosOn(void)
{
    if (Hosting())
    {
        SetKey(8, 1);
        SetPrivacyKey(0);
    }
    w.sosActive = 1;
    w.sosTime = (uint64_t)w.frame + 1;
    SyncSos();
}

static void FakeDeactivate(uint64_t sos) { Record("sos_deactivate", sos, 0, 0, 0, NULL); SosOff(); }
static void FakeSetKey(uint64_t lobby, uint32_t index, int32_t value) { Record("lobby_set", lobby, index, (uint64_t)value, 0, NULL); SetKey(index, value); }

/* A beacon called in: one SOS Beacon use spent (while one is left), one more enabled component, then its activation
 * while the session holds fewer than 4 peers. */
static void SosBeacon(void)
{
    uint32_t uses = SosUses();
    if (uses > 0 && uses != B_NO_LIMIT) Put32(w.sosSlot + 4, uses - 1);
    w.sosEnabled++;
    SyncSos();
    if (w.sessionCount < 4) SosOn();
}

static void PlayerJoins(uint64_t peer)
{
    w.session[w.sessionCount++] = peer;
    Sync();
    if (w.sessionCount >= 4 && w.sosEnabled > 0 && w.sosActive) SosOff();
}

static void PlayerLeaves(uint64_t peer)
{
    (void)RemoveFromSession(peer);
    Sync();
    if (w.sosEnabled > 0 && !w.sosActive) SosOn();
}

/* The lobby's post countdown; at <= 0 the pending keys go to PlayFab and it restarts at 30 s. */
static void LobbyUpdate(float dt)
{
    uintptr_t lobby = w.ctx + BLM_LOBBY;
    float left = GetF(lobby + B_COUNTDOWN) - dt;
    if (left > 0) { PutF(lobby + B_COUNTDOWN, left); return; }
    PutF(lobby + B_COUNTDOWN, 30);
    uint32_t mask = Get32(lobby + B_PENDING);
    if (mask == 0) return;
    if (mask & (1u << 8)) snprintf(w.playfab[0], 8, "%s", Key(8));
    if (mask & (1u << 19)) snprintf(w.playfab[1], 8, "%s", Key(19));
    Record("lobby_post", 0, 0, 0, 0, NULL);
    Put32(lobby + B_PENDING, 0);
}

/* ---- the escape menu's GAME tab ------------------------------------------------------------------------------------ */

static const uint32_t kNativeLabels[5] = {0x42D7CF06u, 0x65E0947Bu, 0x801EC7E7u, 0x1F6FF863u, 0xCC934148u};

static uintptr_t Button(uint32_t i) { return w.content + M_BUTTONS + i * M_BUTTON_SIZE; }
static uintptr_t Card(uint32_t i) { return w.content + M_CARDS + i * M_CARD_SIZE; }

/* The game's own list: types, count, labels, enabled flags. */
static void GameRebuild(void)
{
    uint32_t count = (uint32_t)w.nativeTypeCount;
    for (uint32_t i = 0; i < 5; i++)
    {
        uint8_t type = i < count ? w.nativeTypes[i] : 0;
        Put8(w.content + M_TYPES + i, type);
        Put32(Button(i), i < count ? 0x45011u : 0x4500Bu);
        WidgetAt(Button(i))->parent = i < count ? w.content + M_BUTTON_LIST : 0;
        WidgetAt(Button(i) + M_BUTTON_TEXT)->label = i < count ? kNativeLabels[type] : 0;
        WidgetAt(Button(i) + M_BUTTON_TEXT)->text = NULL;
    }
    Put8(w.content + M_COUNT, (uint8_t)count);
}

static void NativeTypes(int count, uint8_t a, uint8_t b, uint8_t c)
{
    const uint8_t types[3] = {a, b, c};
    w.nativeTypeCount = count;
    for (int i = 0; i < count; i++) w.nativeTypes[i] = types[i];
}

/* The tab's refresh: one card per squad member, each with its peer and player menu. */
static void FillCards(void)
{
    for (uint32_t i = 0; i < 4; i++)
    {
        uint64_t peer = (int)i < w.sessionCount ? w.session[i] : 0;
        Put64(Card(i) + M_CARD_PEER, peer);
        Put64(Card(i) + M_CARD_POPUP, peer != 0 ? 0x2C300000000ull + i : 0);
    }
}

static void OpenMenu(uint32_t shown)
{
    Put64(w.menu + M_SCREEN, w.screen);
    Put64(w.presenters + M_MAIN_PRESENTER, w.mainPresenter);
    Put32(w.mainPresenter + M_PENDING_CLOSE, 0);
    Put32(w.screen + M_SHOWN, shown);
    Put8(w.content + M_HIDDEN, 0);
    Put8(w.content + M_FOCUS, 255);
    Put8(w.content + M_DIALOG_INACTIVE, 1);
    Put8(w.content + M_DIALOG_OPENING, 0);
    Put8(w.content + M_DIALOG_ANSWERED, 0);
    Put8(w.content + M_DIALOG_CONFIRMED, 0);
    PutF(w.content + M_DIALOG_FADE, 0);
    Put32(w.content + M_PANEL_STATE, 2);
    Put32(w.dialog + M_DIALOG_STATE, 0);
    for (uint32_t i = 0; i < 4; i++) Put32(Card(i) + M_CARD_STATE, 0);
    FillCards();
    GameRebuild();
}

static void CloseMenu(void)
{
    Put64(w.menu + M_SCREEN, 0);
    Put64(w.presenters + M_MAIN_PRESENTER, 0);
}

/* The tab update's player-menu branch (the game's update): with the tab taking input, the focused card's open popup
 * runs, and its KICK fires once the hold timer passes 3 s: the game's own kick, then the card reset. A pending close
 * closes the menu first, as Esc does. */
static void MenuUpdate(void)
{
    uint64_t main = Get64(w.presenters + M_MAIN_PRESENTER);
    if (main != 0 && Get8((uintptr_t)main + M_PENDING_CLOSE) != 0)
    {
        Record("escape_closed", 0, 0, 0, 0, NULL);
        CloseMenu();
        return;
    }
    if (Get64(w.menu + M_SCREEN) == 0 || Get32(w.screen + M_SHOWN) != 0) return;
    if (Get8(w.content + M_HIDDEN) != 0 || Get8(w.content + M_DIALOG_INACTIVE) == 0 || Get8(w.content + M_DIALOG_OPENING) != 0 ||
        GetF(w.content + M_DIALOG_FADE) != 0 || Get32(w.content + M_PANEL_STATE) != 2)
        return;
    uint32_t focus = Get8(w.content + M_FOCUS);
    if (focus >= 4) return;
    uintptr_t card = Card(focus);
    if (Get32(card + M_CARD_STATE) != M_POPUP_OPEN || Get64(card + M_CARD_POPUP) == 0 || GetF(card + M_CARD_KICK_HOLD) < 3) return;
    uint64_t peer = Get64(card + M_CARD_PEER);
    Record("game_popup_kick", peer, 0, 0, 0, NULL);
    if (!w.keepRemoved) (void)RemoveFromSession(peer);
    Put64(card + M_CARD_PEER, 0);
    Put32(card + M_CARD_STATE, 1);
    PutF(card + M_CARD_KICK_HOLD, 0);
}

static void Focus(uint8_t index) { Put8(w.content + M_FOCUS, index); }

/* The game's select handler on the focused button: the common tail shows the dialog. */
static void Select(void)
{
    Put8(w.content + M_DIALOG_INACTIVE, 0);
    Put8(w.content + M_DIALOG_ANSWERED, 0);
    Put32(w.dialog + M_DIALOG_STATE, 1);
}

/* Answering hides the dialog in the same frame: inactive at once, state 3 while it fades out. */
static void Answer(int confirmed)
{
    Put8(w.content + M_DIALOG_ANSWERED, 1);
    Put8(w.content + M_DIALOG_CONFIRMED, confirmed ? 1 : 0);
    Put8(w.content + M_DIALOG_INACTIVE, 1);
    Put32(w.dialog + M_DIALOG_STATE, 3);
}

static void HideDialog(void)
{
    Put8(w.content + M_DIALOG_INACTIVE, 1);
    Put32(w.dialog + M_DIALOG_STATE, 0);
}

/* Opens card's player menu for peer, or (peer 0) closes it; the card keeps its player either way. */
static void OpenPopup(uint32_t card, uint64_t peer)
{
    if (peer != 0) Put64(Card(card) + M_CARD_PEER, peer);
    Put32(Card(card) + M_CARD_STATE, peer != 0 ? M_POPUP_OPEN : 0);
}

static const char* DialogText(uint32_t widget)
{
    const Widget* at = WidgetAt(w.dialog + widget);
    return at->text != NULL ? at->text : "";
}

/* "disband=DISBAND SQUAD promote=PROMOTE TANGO": our buttons and what they show. */
static const char* OurButtons(void)
{
    static char out[512];
    static const char* const names[3] = {"disband", "promote", "cancel_sos"};
    size_t n = 0;
    out[0] = 0;
    for (uint32_t i = 0; i < Get8(w.content + M_COUNT); i++)
    {
        uint8_t type = Get8(w.content + M_TYPES + i);
        if (type < 5 || type > 7) continue;
        const Widget* text = WidgetAt(Button(i) + M_BUTTON_TEXT);
        n += (size_t)snprintf(out + n, sizeof out - n, "%s%s=%s", n > 0 ? " " : "", names[type - 5],
            text->label == M_TEXT_TEMPLATE && text->text != NULL ? text->text : "?");
    }
    return out;
}

static void FakeAddChild(uint64_t parent, uint64_t child) { Record("add_child", parent, child, 0, 0, NULL); WidgetAt(child)->parent = parent; }
static void FakeSetLabel(uint64_t widget, uint32_t label) { Record("set_label", widget, label, 0, 0, NULL); WidgetAt(widget)->label = label; }
static void FakeSetLabelWrapped(uint64_t widget, uint32_t label) { Record("set_label_wrapped", widget, label, 0, 0, NULL); WidgetAt(widget)->label = label; }

static void FakeSetStringArg(uint64_t widget, uint32_t key, uint64_t text)
{
    Record("set_string_arg", widget, key, 0, 0, (const char*)(uintptr_t)text);
    WidgetAt(widget)->text = (const char*)(uintptr_t)text;
}

static uint8_t FakeClearArgs(uint64_t label) { Record("clear_args", label, 0, 0, 0, NULL); WidgetAt(label - M_LABEL)->text = NULL; return 1; }
static void FakeMeasureText(uint64_t widget) { Record("measure_text", widget, 0, 0, 0, NULL); }

static void FakeSetEnabled(uint64_t widget, uint8_t on)
{
    uint32_t flags = Get32(widget);
    Record("set_enabled", widget, on, 0, 0, NULL);
    Put32(widget, on ? (flags - flags % 32 + flags % 16 + 16) : (flags - (flags / 16 % 2) * 16));
}

static uint8_t FakeDialogSetup(uint64_t dialog, uint32_t title, uint32_t text, uint32_t confirm, uint32_t cancel, uint8_t hold, uint8_t flag)
{
    Record("dialog_setup", dialog, title, text, confirm, NULL);
    g_dialogCancel = cancel;
    g_dialogHold = hold;
    WidgetAt(dialog + M_DIALOG_TITLE)->label = title;
    WidgetAt(dialog + M_DIALOG_BODY)->label = text;
    return flag;
}

static void FakeRebuild(uint64_t content, uint64_t unused) { Record("rebuild", content, unused, 0, 0, NULL); GameRebuild(); }
static void FakeSetMarquee(uint64_t widget, float width) { Record("set_marquee", widget, 0, 0, 0, NULL); WidgetAt(widget)->marquee = width; }

static void FakeFocus(uint64_t content, uint8_t index)
{
    Record("focus", content, index, 0, 0, NULL);
    uint8_t old = Get8(w.content + M_FOCUS);
    if (old == index) return;
    if (old < 4) Put32(Card(old) + M_CARD_STATE, 0);
    if (index < 4) Put32(Card(index) + M_CARD_STATE, 1);
    Put8(w.content + M_FOCUS, index);
}

static void FakeCardState(uint64_t card, int32_t state)
{
    Record("card_state", card, (uint64_t)state, 0, 0, NULL);
    if (Get32(card + M_CARD_STATE) == (uint32_t)state) return;
    Put32(card + M_CARD_STATE, (uint32_t)state);
    if ((uint32_t)state != M_POPUP_OPEN) PutF(card + M_CARD_KICK_HOLD, 0);
}

/* ---- the jumps to the fakes ------------------------------------------------------------------------------------- */

/* mov rax, fake; jmp rax over the native's first 12 bytes, on a page made executable. */
static void Jump(uintptr_t at, uintptr_t fake)
{
    uint8_t code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
    uint64_t target = fake;
    DWORD old;
    memcpy(code + 2, &target, 8);
    if (!VirtualProtect((void*)at, sizeof code, PAGE_EXECUTE_READWRITE, &old)) { printf("jump page failed\n"); exit(2); } /* lint-ok: C3 the test's stand-ins for the game's code */
    memcpy((void*)at, code, sizeof code);
}

static uintptr_t Native(const BlmCode* table, int count, const char* name)
{
    uintptr_t at = blm_code_address(table, count, name);
    if (at == 0) { printf("no native %s\n", name); exit(2); }
    return at;
}

static void GameJumps(void)
{
    const BlmCode* t = blm_game_natives;
    int n = blm_game_natives_count;
    Jump(Native(t, n, "start_join"), (uintptr_t)FakeStartJoin);
    Jump(Native(t, n, "filter_string"), (uintptr_t)FakeFilterString);
    Jump(Native(t, n, "browser_start"), (uintptr_t)FakeBrowserStart);
    Jump(Native(t, n, "browser_busy"), (uintptr_t)FakeBrowserBusy);
    Jump(Native(t, n, "browser_count"), (uintptr_t)FakeBrowserCount);
    Jump(Native(t, n, "browser_result"), (uintptr_t)FakeBrowserResult);
    Jump(Native(t, n, "is_friend"), (uintptr_t)FakeIsFriend);
    Jump(Exe(EXE_CLEAR_FILTERS), (uintptr_t)FakeClearFilters);
    Jump(Exe(EXE_CONTINENT), (uintptr_t)FakeContinent);
    Jump(Game(blm_sos_deactivate.rva), (uintptr_t)FakeDeactivate);
    Jump(Game(blm_sos_set_key.rva), (uintptr_t)FakeSetKey);
    Jump(Game(blm_chat_send_code.rva), (uintptr_t)FakeChatSend);
    Jump(Game(blm_chat_rpc_code.rva), (uintptr_t)FakeRpcSend);
}

static void MenuJumps(void)
{
    const BlmCode* t = blm_menu_natives;
    int n = blm_menu_natives_count;
    Jump(Native(t, n, "add_child"), (uintptr_t)FakeAddChild);
    Jump(Native(t, n, "set_label"), (uintptr_t)FakeSetLabel);
    Jump(Native(t, n, "set_label_wrapped"), (uintptr_t)FakeSetLabelWrapped);
    Jump(Native(t, n, "set_string_arg"), (uintptr_t)FakeSetStringArg);
    Jump(Native(t, n, "clear_args"), (uintptr_t)FakeClearArgs);
    Jump(Native(t, n, "measure_text"), (uintptr_t)FakeMeasureText);
    Jump(Native(t, n, "set_enabled"), (uintptr_t)FakeSetEnabled);
    Jump(Native(t, n, "dialog_setup"), (uintptr_t)FakeDialogSetup);
    Jump(Native(t, n, "rebuild"), (uintptr_t)FakeRebuild);
    Jump(Native(t, n, "set_marquee"), (uintptr_t)FakeSetMarquee);
    Jump(Native(t, n, "focus"), (uintptr_t)FakeFocus);
    Jump(Native(t, n, "card_state"), (uintptr_t)FakeCardState);
}

/* ---- building the world ----------------------------------------------------------------------------------------- */

static uint32_t ContinentId(const char* code)
{
    static const char* const codes[7] = {"AF", "AN", "AS", "EU", "NA", "OC", "SA"};
    static const uint32_t ids[7] = {0x9061BF63u, 0xC59A4447u, 0x617288E9u, 0x0FAB5B27u, 0x29CE1E3Fu, 0xCCC7BF91u, 0xD044AF30u};
    for (int i = 0; i < 7; i++)
        if (strcmp(codes[i], code) == 0) return ids[i];
    return 0;
}

static uint32_t PairKey(const char* own, const char* other)
{
    const uint32_t words[4] = {R_KEY_A, R_KEY_B, ContinentId(own), ContinentId(other)};
    return blm_region_combine(words, 4);
}

static uint32_t RowKey(const char* own)
{
    static const char* const codes[6] = {"AF", "AS", "EU", "NA", "OC", "SA"};
    static const uint32_t keys[6] = {0xF2594CB8u, 0x5EF09DD9u, 0x59CB3FB8u, 0xBCEC4078u, 0x976F5E8Bu, 0xA7E90B96u};
    for (int i = 0; i < 6; i++)
        if (strcmp(codes[i], own) == 0) return keys[i];
    return 0;
}

/* The server's continent matrix read from the running game: the 16 disallowed pairs and their keys. */
typedef struct LivePair { const char* own; const char* other; uint32_t key; } LivePair;
static const LivePair kLivePairs[16] = {{"AF", "NA", 0xAB51EEC3u}, {"AF", "OC", 0x80D2F030u}, {"AF", "SA", 0xB054A52Du},
    {"AS", "NA", 0xB68B9196u}, {"AS", "SA", 0xAD8EDA78u}, {"EU", "SA", 0x42D3342Du}, {"NA", "AF", 0xFCC740C3u},
    {"NA", "AS", 0x506E91A2u}, {"NA", "OC", 0x99F152F0u}, {"OC", "AF", 0xA3B874FCu}, {"OC", "NA", 0xED0D783Cu},
    {"OC", "SA", 0xF60833D2u}, {"SA", "AF", 0x2744B955u}, {"SA", "AS", 0x8BED6834u}, {"SA", "EU", 0x8CD6CA55u},
    {"SA", "OC", 0x4272AB66u}};
typedef struct Extra { const char* own; const char* other; uint32_t value; } Extra;

/* The game's insert: the first empty slot on the probe path (multiplier 2), count + 1. */
static uintptr_t Insert(uintptr_t header, uint32_t key, uint32_t name, uint32_t parent, uint32_t kind, uint32_t value)
{
    uint32_t start = key * 2u;
    for (uint32_t i = 0; i < R_CAPACITY; i++)
    {
        uintptr_t entry = header + R_ENTRIES + ((start + i) % R_CAPACITY) * R_ENTRY;
        if (Get32(entry) != 0) continue;
        Put32(entry, key);
        Put32(entry + 8, name);
        Put32(entry + 12, parent);
        Put32(entry + 16, key);
        Put32(entry + 20, kind);
        Put32(entry + 24, value);
        Put32(entry + 40, R_WEIGHT);
        Put32(header + R_COUNT, Get32(header + R_COUNT) + 1);
        return entry;
    }
    printf("fake table full\n");
    exit(2);
}

static uintptr_t ServerPair(uintptr_t header, const char* own, const char* other, uint32_t value)
{
    return Insert(header, PairKey(own, other), ContinentId(other), RowKey(own), R_BOOL, value);
}

static void ClearTable(uintptr_t header)
{
    for (uintptr_t at = header + R_ENTRIES; at < header + R_SPAN; at += 4) Put32(at, 0);
    Put32(header + 20, 0);
    Put32(header + R_COUNT, 0);
    Put32(header + R_CHECKSUM, 0);
}

/* A config download that changed the table: the game copies the new table (and its checksum) over the old one. */
static void Download(uint32_t checksum, const Extra* extra, int extras)
{
    ClearTable(w.main);
    Put32(w.main + 20, R_KEY_A);
    (void)Insert(w.main, 0xCB9E5905u, 0x70E28FDBu, 0x6A8B050Du, 6, 100); /* an unrelated number entry */
    for (int i = 0; i < 16; i++) (void)ServerPair(w.main, kLivePairs[i].own, kLivePairs[i].other, 0);
    for (int i = 0; i < extras; i++) (void)ServerPair(w.main, extra[i].own, extra[i].other, extra[i].value);
    Put32(w.main + R_CHECKSUM, checksum);
}

/* The entry for key in a fake table, or 0 (the game's probe order). */
static uintptr_t FindEntry(uintptr_t header, uint32_t key)
{
    uint32_t start = key * 2u;
    for (uint32_t i = 0; i < R_CAPACITY; i++)
    {
        uintptr_t entry = header + R_ENTRIES + ((start + i) % R_CAPACITY) * R_ENTRY;
        uint32_t found = Get32(entry);
        if (found == 0) return 0;
        if (found == key) return entry;
    }
    return 0;
}

/* What the search builder sees: the continents excluded for own, in order. */
static const char* Excluded(const char* own)
{
    static const char* const codes[7] = {"AF", "AN", "AS", "EU", "NA", "OC", "SA"};
    static char out[32];
    size_t n = 0;
    out[0] = 0;
    for (int i = 0; i < 7; i++)
    {
        uintptr_t entry = FindEntry(w.synced, PairKey(own, codes[i]));
        if (entry == 0) entry = FindEntry(w.main, PairKey(own, codes[i]));
        if (entry != 0 && Get32(entry + 20) == R_BOOL && Get32(entry + 24) % 256 == 0)
            n += (size_t)snprintf(out + n, sizeof out - n, "%s%s", n > 0 ? " " : "", codes[i]);
    }
    return out;
}

static void InstallConfig(const char* code, const Extra* extra, int extras, const Extra* synced, int synceds)
{
    w.config = Pages(0x18200);
    w.main = w.config + R_TABLE;
    w.synced = w.config + R_SYNCED;
    Put64(Game(R_CONFIG_PTR), w.config);
    uintptr_t headers[2] = {w.main, w.synced};
    for (int i = 0; i < 2; i++)
    {
        Put64(headers[i], headers[i] + R_ENTRIES);
        Put32(headers[i] + 8, R_CAPACITY);
        Put32(headers[i] + 12, 0);
        Put32(headers[i] + 16, 2);
    }
    static const char* const codes[7] = {"AF", "AN", "AS", "EU", "NA", "OC", "SA"};
    for (uint32_t i = 0; i < 7; i++) Put32(Game(R_CONTINENT_IDS + i * 4), ContinentId(codes[i]));
    w.continentText = Heap(16);
    PutString(w.continentText, code);
    w.continentKnown = 1;
    Download(R_SERVER_CHECKSUM, extra, extras);
    Put32(w.synced + 20, 0xE4AED9F8u);
    (void)Insert(w.synced, 0x02E78100u, 0x5BD1E995u, 0xE4AED9F8u, R_BOOL, 1);
    for (int i = 0; i < synceds; i++) (void)ServerPair(w.synced, synced[i].own, synced[i].other, synced[i].value);
    Put32(w.synced + R_CHECKSUM, 0x11111111u);
}

static void InstallEngine(void)
{
    w.tables = Heap(0x200);
    w.lobbyApi = Heap(0x400);
    w.packageApi = Heap(0x400);
    Put64(Game(BLM_ENGINE_API_PTR), w.tables);
    Put64(w.tables + BLM_LOBBY_API, w.lobbyApi);
    Put64(w.tables + BLM_PACKAGE_API, w.packageApi);
    const uint32_t lobbyAt[2] = {EXE_CLEAR_FILTERS, EXE_CONTINENT}, packageAt[2] = {EXE_UNLOAD_PAUSED, EXE_PAUSE_UNLOADS};
    for (int i = 0; i < 2; i++)
    {
        Put64(w.lobbyApi + blm_engine_slots[i].rva, Exe(lobbyAt[i]));
        PutPattern(Exe(lobbyAt[i]), blm_engine_slots[i].pattern);
        Put64(w.packageApi + blm_package_slots[i].rva, Exe(packageAt[i]));
        PutPattern(Exe(packageAt[i]), blm_package_slots[i].pattern);
    }
}

static void InstallMenu(float buttonWidth)
{
    w.menu = Heap(0x100);
    w.screen = Pages(M_SCREEN_SIZE);
    w.content = w.screen + M_CONTENT;
    w.dialog = w.content + M_DIALOG;
    w.presenters = Heap(0x4400);
    w.mainPresenter = Pages(0x40);
    Put64(Game(M_MENU_SYSTEM_PTR), w.menu);
    Put64(w.menu + M_SCREEN, 0);
    Put64(Game(M_PRESENTERS_PTR), w.presenters);
    Put64(w.presenters + M_MAIN_PRESENTER, 0);
    for (uint32_t i = 0; i < 5; i++)
    {
        Put32(Button(i) + M_BUTTON_TEXT, 7u * 262144u); /* text widgets: kind in flag bits 18-21 (7 plain, 8 wrapped) */
        PutF(Button(i) + M_WIDGET_WIDTH, buttonWidth);
        PutF(Button(i) + M_BUTTON_TEXT + M_WIDGET_X, 16);
    }
    Put32(w.dialog + M_DIALOG_TITLE, 7u * 262144u);
    Put32(w.dialog + M_DIALOG_BODY, 8u * 262144u);
    NativeTypes(2, 1, 3, 0);
}

static void InstallSos(void)
{
    w.sosSettings = Pages(0x200);
    w.players = Pages(B_PLAYER_COUNT + 0x10);
    w.sos = Heap(0x40);
    Put64(Game(B_STRATAGEMS + 8 * B_SOS_STRATAGEM), w.sosSettings);
    Put32(w.sosSettings, B_SOS_STRATAGEM);
    Put32(w.sosSettings + B_USES, 1);
    Put32(w.sosSettings + B_SHARED, 0);
    Put64(Game(B_PLAYERS_PTR), w.players);
    Put32(w.players + B_PLAYER_COUNT, 1);
    Put32(w.players + B_SLOT_COUNT, 3);
    const uint32_t kinds[3] = {0x7C, B_SOS_STRATAGEM, 0x21};
    for (uint32_t i = 0; i < 3; i++)
    {
        uintptr_t slot = w.players + B_SLOTS + i * B_SLOT_SIZE;
        Put32(slot, kinds[i]);
        Put32(slot + 4, kinds[i] == B_SOS_STRATAGEM ? 1 : B_NO_LIMIT);
    }
    w.sosSlot = w.players + B_SLOTS + B_SLOT_SIZE;
    Put64(Game(B_SOS_PTR), w.sos);
    PutString(KeyAddress(8), "0");
    PutString(KeyAddress(19), "1");
    snprintf(w.playfab[0], 8, "0");
    snprintf(w.playfab[1], 8, "1");
    PutF(w.ctx + BLM_LOBBY + B_COUNTDOWN, 30);
    w.privacy = 1;
}

/* Every part's code in the fake images: the bytes the component checks. */
static void InstallCode(void)
{
    PutTable(fake_game(), blm_game_code, blm_game_code_count);
    PutTable(fake_exe(), blm_exe_code, blm_exe_code_count);
    PutTable(fake_game(), blm_game_natives, blm_game_natives_count);
    PutTable(fake_game(), blm_menu_natives, blm_menu_natives_count);
    PutTable(fake_game(), blm_menu_code, blm_menu_code_count);
    PutTable(fake_game(), blm_sos_code, blm_sos_code_count);
    PutTable(fake_game(), blm_chat_code, blm_chat_code_count);
    PutTable(fake_game(), blm_region_code, blm_region_code_count);
    PutTable(fake_game(), blm_scanner_code, blm_scanner_code_count);
    PutTable(fake_game(), &blm_sos_deactivate, 1);
    PutTable(fake_game(), &blm_sos_set_key, 1);
    PutTable(fake_game(), &blm_chat_send_code, 1);
    PutTable(fake_game(), &blm_chat_rpc_code, 1);
    Put32(Game(B_LIST_DISPLACEMENT), 0x0315E222u); /* lea r10, [rip + 0x315e222]: the vanilla list */
}

/* A fresh game, as test_addon.lua's install: the config, the menu, the chat (unavailable unless asked: its send's code
 * differs), the scanner and the SOS system. */
static void NewWorld(int chat)
{
    memset(&w, 0, sizeof w);
    g_widgetCount = g_callCount = g_readOnly = 0;
    w.ctx = Pages(0x20000);
    w.state = Heap(0xAD000);
    w.roster = Heap(4 * 0xC0);
    w.match = Pages(0x10C000);
    InstallCode();
    InstallEngine();
    Put64(Game(BLM_CONTEXT_PTR), w.ctx);
    Put64(Game(BLM_GAME_STATE_PTR), w.state);
    Put64(Game(BLM_ROSTER_PTR), w.roster);
    Put64(Game(BLM_MATCHMAKING_PTR), w.match);
    Put64(w.ctx + BLM_BROWSER, 0x2C000000000ull);
    w.local = w.host = ME;
    w.session[0] = ME;
    w.sessionCount = 1;
    w.mode = BLM_MODE_SHIP;
    w.hosting = 1;
    w.lobbyAfter = 1;
    w.searchFrames = 2;
    w.joinFrames = 3;
    w.chatEnabled = 1;
    InstallConfig("NA", NULL, 0, NULL, 0);
    InstallMenu(420);
    w.scannerConfig = Pages(0x3D000);
    Put64(Game(S_CONFIG_PTR), w.scannerConfig);
    Put32(w.scannerConfig + S_RECHARGE, 20);
    PutF(w.match + S_COUNTDOWN, 0);
    InstallSos();
    if (!chat) ChangeCode(Game(blm_chat_send_code.rva));
    SetName(TANGO, "Tango");
    SetName(CHARLIE, "Charlie");
    Sync();
}

/* The component started and its load event fired, then the jumps to the fakes over the checked code. */
static void Started(void)
{
    (void)fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    GameJumps();
    MenuJumps();
}

static VpmComponent* Self(void) { return fake_component(0); }

/* n frames: the scenario written, the component's update, then the game's update of the escape menu's tab. */
static void Frames(int n)
{
    for (int i = 0; i < n; i++)
    {
        Sync();
        fake_frames(1, DT);
        MenuUpdate();
    }
}

/* n frames that also advance the world (the browser and the join), as test_lobby.lua's run. */
static void Ticks(int n)
{
    for (int i = 0; i < n; i++)
    {
        WorldTick();
        Frames(1);
    }
}

/* Focus our button at index, select it, answer the dialog: the action runs in the answer's frame. */
static void Confirm(uint8_t index, int yes)
{
    Focus((uint8_t)(4 + index));
    Frames(1);
    Select();
    Frames(1);
    Answer(yes);
    Frames(1);
    HideDialog();
}

static VpmOption* Option(const char* id)
{
    for (int i = 0; i < vpm_option_count(); i++)
        if (strcmp(vpm_option_def(vpm_option_at(i))->id, id) == 0) return vpm_option_at(i);
    return NULL;
}

/* A settings file the core reads at start-up (the saved option values). */
static void SavedOption(const char* key, const char* value)
{
    FILE* file = fopen("vpm-test-settings.ini", "wb");
    if (file == NULL) { printf("no settings file\n"); exit(2); }
    fprintf(file, "[options]\n%s = %s\n", key, value);
    if (fclose(file) != 0) { printf("settings file not written\n"); exit(2); }
}

static uint32_t Reads(void) { return fake_counts().read; }

/* ==== start-up (test_game.lua, test_addon.lua) ======================================================================= */

static void StartsWhenTheCodeIsAsReviewed(void)
{
    NewWorld(1);
    Started();
    CHECK(vpm_running(Self()));
    CHECK(vpm_ticking(Self()));
    CHECK_LOG("Better Lobby Management v1.2.1 ready: game code and natives verified; menu ready; squad messages ready; "
        "scanner ready; CANCEL SOS ready");
    CHECK_NO_LOG("Lobby Region disabled");
    /* Once: every record's code (73), the engine's lobby and package API and their four slots (6 reads), no page check. */
    CHECK_EQ(fake_counts().code_matches, 73);
    CHECK_EQ(Reads(), 6);
    CHECK_EQ(blm_page_checks(), 0);
    CHECK_EQ(Option("region") != NULL && Option("messages") != NULL && Option("scanner_seconds") != NULL, 1);
    const VpmOptionDef* region = vpm_option_def(Option("region"));
    const VpmOptionDef* scanner = vpm_option_def(Option("scanner_seconds"));
    CHECK(region->kind == VPM_CHOICE && region->value == 1 && strcmp(region->choices[1], "My Continent Only") == 0);
    CHECK(strcmp(vpm_option_def(Option("messages"))->choices[0], "On") == 0);
    CHECK(scanner->kind == VPM_SLIDER && scanner->value == 5 && scanner->min == 5 && scanner->max == 20 && scanner->step == 1);
    CHECK(strlen(region->description) <= 400 && strlen(scanner->description) <= 400);
}

/* Changed network code, exe code or natives: nothing runs, the reason is logged. */
static void RefusesChangedCode(void)
{
    struct { const BlmCode* table; int count; int exe; } cases[3] = {{blm_game_code, blm_game_code_count, 0},
        {blm_exe_code, blm_exe_code_count, 1}, {blm_game_natives, blm_game_natives_count, 0}};
    for (int c = 0; c < 3; c++)
        for (int i = 0; i < cases[c].count; i++)
        {
            char text[96];
            fake_setup();
            NewWorld(0);
            ChangeCode((cases[c].exe ? fake_exe() : fake_game()) + cases[c].table[i].rva);
            Started();
            Frames(2);
            snprintf(text, sizeof text, "disabled: %s changed", cases[c].table[i].name);
            CHECK(!vpm_running(Self()));
            CHECK_LOG(text);
            CHECK_EQ(Get32(w.scannerConfig + S_RECHARGE), 20);
        }
}

static void RefusesAnEngineWithoutItsSlots(void)
{
    static const char* const texts[] = {"engine lobby API unavailable", "engine clear_filters changed",
        "engine continent changed", "engine clear_filters changed", "engine package API unavailable",
        "engine unload_paused changed", "engine pause_unloads changed", "engine pause_unloads changed"};
    for (int c = 0; c < 8; c++)
    {
        fake_setup();
        NewWorld(0);
        if (c == 0) Put64(w.tables + BLM_LOBBY_API, 0);
        if (c == 1) ChangeCode(Exe(EXE_CLEAR_FILTERS));
        if (c == 2) ChangeCode(Exe(EXE_CONTINENT));
        if (c == 3) Put64(w.lobbyApi + blm_engine_slots[0].rva, 0);
        if (c == 4) Put64(w.tables + BLM_PACKAGE_API, 0);
        if (c == 5) ChangeCode(Exe(EXE_UNLOAD_PAUSED));
        if (c == 6) ChangeCode(Exe(EXE_PAUSE_UNLOADS));
        if (c == 7) Put64(w.packageApi + blm_package_slots[1].rva, 0);
        Started();
        CHECK(!vpm_running(Self()));
        CHECK_LOG(texts[c]);
    }
}

/* On HellForge the load event may come before the engine hands game.dll its API: one plain load a frame until then. */
static void WaitsForTheEngine(void)
{
    NewWorld(0);
    Put64(Game(BLM_ENGINE_API_PTR), 0);
    (void)fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK_LOG("Waiting for the game: the engine API is not available yet.");
    CHECK(vpm_running(Self()) && vpm_ticking(Self()));
    fake_counts_reset();
    Frames(90);
    CHECK_EQ(Reads() + fake_counts().log + fake_counts().code_matches, 0);
    Put64(Game(BLM_ENGINE_API_PTR), w.tables);
    Frames(1);
    GameJumps();
    MenuJumps();
    CHECK_LOG("the engine API is available after 1.4 s of waiting");
    CHECK_LOG("ready: game code and natives verified; menu ready");
    Frames(2);
    CHECK_EQ(Get32(w.scannerConfig + S_RECHARGE), 5);

    fake_setup();
    NewWorld(0);
    Put64(Game(BLM_ENGINE_API_PTR), 0);
    (void)fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    Frames(37600);
    CHECK(!vpm_running(Self()));
    CHECK_LOG("gave up after 600 s: engine API unavailable");
}

typedef struct PartCase { const BlmCode* table; int count; const char* prefix; } PartCase;

/* Changed menu, SOS, chat, scanner or region code disables that part alone. */
static void DisablesOnlyThePart(void)
{
    const PartCase cases[7] = {{blm_menu_natives, blm_menu_natives_count, "menu disabled: "},
        {blm_menu_code, blm_menu_code_count, "menu disabled: "}, {blm_sos_code, blm_sos_code_count, "CANCEL SOS unavailable: "},
        {blm_chat_code, blm_chat_code_count, "squad messages unavailable: "},
        {blm_scanner_code, blm_scanner_code_count, "scanner disabled: "},
        {blm_region_code, blm_region_code_count, "Lobby Region disabled: "}, {NULL, 0, NULL}};
    for (int c = 0; cases[c].table != NULL; c++)
        for (int i = 0; i < cases[c].count; i++)
        {
            char text[128];
            fake_setup();
            NewWorld(1);
            ChangeCode(Game(cases[c].table[i].rva));
            Started();
            snprintf(text, sizeof text, "%s%s changed", cases[c].prefix, cases[c].table[i].name);
            CHECK(vpm_running(Self()));
            CHECK_LOG(text);
        }
    struct { const BlmCode* code; const char* text; } singles[4] = {{&blm_sos_deactivate, "CANCEL SOS unavailable: SOS deactivate changed"},
        {&blm_sos_set_key, "CANCEL SOS unavailable: lobby number setter changed"},
        {&blm_chat_send_code, "squad messages unavailable: chat send changed"},
        {&blm_chat_rpc_code, "squad messages unavailable: RPC send changed"}};
    for (int c = 0; c < 4; c++)
    {
        fake_setup();
        NewWorld(1);
        ChangeCode(Game(singles[c].code->rva));
        Started();
        CHECK(vpm_running(Self()));
        CHECK_LOG(singles[c].text);
    }
    fake_setup();
    NewWorld(1);
    Put32(Game(R_CONTINENT_IDS + 8), 0);
    Started();
    CHECK_LOG("; Lobby Region disabled: continent table changed; squad messages ready");
    CHECK(vpm_option_apply(Option("region"), 2)); /* before the first frame: saved, applied by it */
    Frames(1);
    CHECK_LOG("nearby lobbies unavailable: continent table changed");
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
}

/* Without the menu's code no buttons; without the SOS code no CANCEL SOS; without the scanner's its field stays. */
static void DisabledPartsStayAway(void)
{
    NewWorld(0);
    ChangeCode(Game(blm_menu_code[2].rva));
    Started();
    Squad(1, TANGO, 0);
    OpenMenu(0);
    Frames(3);
    CHECK(strcmp(OurButtons(), "") == 0);

    fake_setup();
    NewWorld(0);
    ChangeCode(Game(blm_sos_code[0].rva));
    Started();
    w.mode = BLM_MODE_MISSION;
    NativeTypes(2, 2, 3, 0);
    Frames(1);
    SosBeacon();
    OpenMenu(0);
    Frames(2);
    CHECK(strcmp(OurButtons(), "") == 0);
    CHECK_EQ(Count("sos_deactivate"), 0);
    const char* why = "";
    CHECK_EQ(blm_sos_cancel(1, &why), 0);
    CHECK(strcmp(why, "not verified") == 0);

    fake_setup();
    NewWorld(0);
    ChangeCode(Game(blm_scanner_code[0].rva));
    Started();
    Frames(1);
    CHECK_LOG("scanner disabled: recharge reader changed");
    CHECK_EQ(Get32(w.scannerConfig + S_RECHARGE), 20);
}

/* ==== the idle gate (test_addon.lua, test_idle_gate.lua) ============================================================= */

/* While nothing is pending and the escape screen is closed, a frame reads the menu system's screen and runs the scanner's
 * check: 4 plain loads, no read, no page check, no log line, whatever the session. */
static void IdleFrames(void)
{
    NewWorld(0);
    Started();
    fake_counts_reset();
    Frames(1);
    /* The first frame: a full one; the context confirmed (2 reads), the scanner's first write (1 read, 1 page check,
     * the countdown read), and its log line. */
    CHECK_EQ(Reads(), 4);
    CHECK_EQ(blm_page_checks(), 1);
    CHECK_LOG("scanner active: setting 5 s, game 20 s, field 5 s; writes 1, game rewrites 0, countdowns shortened 0");
    CHECK_EQ(Get32(w.scannerConfig + S_RECHARGE), 5);
    fake_counts_reset();
    Frames(1);
    CHECK_EQ(Reads(), 1); /* the menu system confirmed once */
    int pages = blm_page_checks();
    fake_counts_reset();
    Frames(300); /* alone on the ship */
    Put64(Game(BLM_CONTEXT_PTR), 0);
    Frames(300); /* no session */
    Put64(Game(BLM_CONTEXT_PTR), w.ctx);
    Frames(300); /* a new session (confirmed when the menu opens) */
    const uint64_t client[2] = {TANGO, ME};
    SetSession(2, client);
    w.host = TANGO;
    Frames(300); /* client of another host */
    Squad(1, TANGO, 0);
    Frames(300); /* hosting a squad, menu closed */
    Squad(0, 0, 0);
    w.mode = BLM_MODE_MISSION;
    Sync();
    SosBeacon();
    Frames(300); /* alone in a mission, SOS on, menu closed */
    CHECK_EQ(Reads() + fake_counts().log, 0);
    CHECK_EQ(blm_page_checks(), pages);
    /* The menu open alone in a mission without an SOS: full frames, still no read once confirmed. */
    w.sosActive = 0;
    w.sosEnabled = 0;
    OpenMenu(0);
    Frames(1);
    fake_counts_reset();
    Frames(300);
    CHECK_EQ(Reads() + fake_counts().log, 0);
    CloseMenu();
    Frames(300);
    CHECK_EQ(Reads() + fake_counts().log, 0);
    CHECK_EQ(blm_page_checks(), pages);
}

/* A menu system that cannot be confirmed (its screen field unreadable): the full frame runs and the gate tries the
 * guarded read again on every 60th frame only; a readable one gives idle frames again. */
static void UnconfirmedMenuSystem(void)
{
    NewWorld(0);
    fake_hole(w.menu + M_SCREEN, 8);
    Started();
    Frames(1);
    fake_counts_reset();
    Frames(120);
    CHECK_EQ(Reads(), 2);
    uintptr_t menu = Heap(0x100);
    Put64(menu + M_SCREEN, 0);
    Put64(Game(M_MENU_SYSTEM_PTR), menu);
    Frames(60);
    fake_counts_reset();
    Frames(60);
    CHECK_EQ(Reads(), 0);
}

/* ==== the escape menu with a squad (test_addon.lua) ================================================================ */

static void ShipMenuOffersDisbandAndPromote(void)
{
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    Frames(1);
    OpenMenu(0);
    Frames(1);
    CHECK(strcmp(OurButtons(), "disband=DISBAND SQUAD promote=PROMOTE TANGO") == 0);
    /* Opening Charlie's player menu makes Charlie the successor, and it stays after the popup closes. */
    OpenPopup(2, CHARLIE);
    Frames(1);
    OpenPopup(2, 0);
    Frames(2);
    CHECK(strcmp(OurButtons(), "disband=DISBAND SQUAD promote=PROMOTE CHARLIE") == 0);
    /* The menu open with nothing to do: plain loads only, no native call. */
    int calls = g_callCount, pages = blm_page_checks();
    fake_counts_reset();
    Frames(60);
    CHECK_EQ(g_callCount, calls);
    CHECK_EQ(Reads() + fake_counts().log, 0);
    CHECK_EQ(blm_page_checks(), pages);
    /* Promote Charlie: focus, select, confirm in the game's dialog. */
    Focus(4 + 3);
    Frames(1);
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "PROMOTE CHARLIE") == 0);
    CHECK(strncmp(DialogText(M_DIALOG_BODY), "Charlie hosts from their own ship", 33) == 0);
    CHECK(strstr(DialogText(M_DIALOG_BODY), "Picked automatically") == NULL);
    CHECK(strlen(DialogText(M_DIALOG_BODY)) <= 120);
    Select();
    Frames(1);
    Answer(1);
    Frames(1);
    CHECK_EQ(Count("game_popup_kick"), 1);
    CHECK(Last("game_popup_kick")->a == CHARLIE);
    CHECK(strcmp(blm_lobby_status(), "promote: Charlie returns to their ship") == 0);
    CHECK_LOG("menu: promote confirmed");
    GameRebuild(); /* the game rebuilds the list after a removal */
    Frames(3);
    CHECK(strcmp(OurButtons(), "") == 0); /* no buttons while an action runs */
}

static void DisbandFromTheDialog(void)
{
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    OpenMenu(0);
    Frames(2);
    Focus(4 + 2);
    Frames(1);
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "DISBAND SQUAD") == 0);
    CHECK(strcmp(DialogText(M_DIALOG_BODY), "Kick every other player. They return to their own ships.") == 0);
    Select();
    Frames(1);
    Answer(0);
    Frames(1);
    CHECK_EQ(Count("game_popup_kick"), 0);
    CHECK_LOG("menu: disband cancelled");
    HideDialog();
    Frames(1);
    Select();
    Frames(1);
    Answer(1);
    Frames(10);
    CHECK_EQ(Count("game_popup_kick"), 2);
    CHECK_EQ(w.sessionCount, 1);
    CHECK(strcmp(blm_lobby_status(), "disbanded (2 players)") == 0);
    CHECK_LOG("menu: disband confirmed");
    CHECK_LOG("disband: kicking 2 player(s)");
    CHECK_LOG("disband: kicked Tango");
    CHECK_LOG("disband: kicked Charlie");
    CHECK_LOG("game kick: KICK set on 100000000000005's player menu (card 1)");
    CHECK_LOG("disband: disbanded (2 players)");
    CHECK_EQ(blm_lobby_actions(), 1);
}

static void MissionWithoutSosOffersNothing(void)
{
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    w.mode = BLM_MODE_MISSION;
    NativeTypes(3, 0, 2, 3);
    Frames(1);
    int pages = blm_page_checks();
    OpenMenu(0);
    Frames(2);
    CHECK(strcmp(OurButtons(), "") == 0);
    CHECK_EQ(Get8(w.content + M_COUNT), 3);
    CHECK_EQ(blm_page_checks(), pages);
}

/* ==== CANCEL SOS through the menu (test_addon.lua) ================================================================== */

static void CancelSosAlone(void)
{
    char body[256];
    NewWorld(0);
    Started();
    w.mode = BLM_MODE_MISSION;
    NativeTypes(2, 2, 3, 0);
    Frames(1); /* the scanner's first write */
    SosBeacon();
    OpenMenu(0);
    Frames(1);
    CHECK(strcmp(OurButtons(), "cancel_sos=CANCEL SOS") == 0);
    CHECK(Get8(w.content + M_COUNT) == 3 && Get8(w.content + M_TYPES) == 2 && Get8(w.content + M_TYPES + 1) == 3);
    int calls = g_callCount, pages = blm_page_checks();
    fake_counts_reset();
    Frames(60);
    CHECK_EQ(g_callCount, calls);
    CHECK_EQ(Reads() + fake_counts().log, 0);
    CHECK_EQ(blm_page_checks(), pages);
    Focus(4 + 2);
    Frames(1);
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "CANCEL SOS") == 0);
    blm_sos_body(1, body, sizeof body);
    CHECK(strcmp(DialogText(M_DIALOG_BODY), body) == 0);
    Select();
    Frames(1);
    Answer(1);
    Frames(1);
    CHECK_EQ(Count("sos_deactivate"), 1);
    CHECK(strcmp(Key(8), "0") == 0 && strcmp(Key(19), "1") == 0);
    CHECK(GetF(w.ctx + BLM_LOBBY + B_COUNTDOWN) == 0.0f); /* the lobby posts in the game's update of this frame */
    CHECK_EQ(SosUses(), 1); /* the SOS Beacon can be called in again */
    CHECK_LOG("menu: cancel_sos confirmed");
    CHECK_LOG("SOS cancelled: lobby SOS flag 1, privacy 0 -> SOS flag 0, privacy 1");
    CHECK_LOG("SOS Beacon uses 0 -> 1");
    Frames(1);
    CHECK_EQ(Count("rebuild"), 1);
    CHECK(strcmp(OurButtons(), "") == 0); /* the button goes: the game rebuilt its list */
    /* Kept off, the menu closed: the cancel's plain loads a frame (a kept cancel is work: no idle gate), no read. */
    HideDialog();
    CloseMenu();
    Frames(2);
    fake_counts_reset();
    Frames(60);
    CHECK_EQ(Reads() + fake_counts().log, 0);
    /* A new SOS Beacon lists the mission again, the mod lets it, and the menu offers CANCEL SOS again. */
    SosBeacon();
    Frames(1);
    CHECK(SosUses() == 0 && w.sosActive == 1 && strcmp(Key(8), "1") == 0);
    CHECK_LOG("(a new SOS beacon was called in)");
    OpenMenu(0);
    Frames(1);
    CHECK(strcmp(OurButtons(), "cancel_sos=CANCEL SOS") == 0);
    CHECK_EQ(Count("sos_deactivate"), 1);
}

static void CancelSosWithASquad(void)
{
    char body[256];
    int cancels, rearms, leaks;
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    w.mode = BLM_MODE_MISSION;
    NativeTypes(3, 0, 2, 3);
    Frames(1);
    SosBeacon();
    OpenMenu(0);
    Frames(1);
    CHECK(strcmp(OurButtons(), "cancel_sos=CANCEL SOS") == 0);
    CHECK_EQ(Get8(w.content + M_COUNT), 4);
    fake_counts_reset();
    Frames(60);
    CHECK_EQ(Reads(), 0);
    w.privacy = 0;
    Frames(1);
    Focus(4 + 3);
    Frames(1);
    blm_sos_body(0, body, sizeof body);
    CHECK(strcmp(DialogText(M_DIALOG_BODY), body) == 0);
    Select();
    Frames(1);
    Answer(1);
    Frames(1);
    CHECK_EQ(Count("sos_deactivate"), 1);
    LobbyUpdate(DT);
    CHECK(strcmp(w.playfab[0], "0") == 0 && strcmp(w.playfab[1], "0") == 0); /* Public stays Public */
    PlayerLeaves(CHARLIE); /* the game's re-arm */
    Frames(1);
    CHECK_EQ(Count("sos_deactivate"), 2);
    CHECK(strcmp(Key(8), "0") == 0);
    CHECK(strcmp(OurButtons(), "") == 0);
    CHECK_LOG("SOS: the game listed it again (a player left or a new host); cancelled again");
    blm_sos_counts(&cancels, &rearms, &leaks);
    CHECK(cancels == 1 && rearms == 1 && leaks == 0);
}

/* ==== squad messages (test_addon.lua) =============================================================================== */

static void SquadMessagesGoFirst(void)
{
    NewWorld(1);
    Started();
    Frames(1);
    CHECK_LOG("squad messages ready");
    Squad(1, TANGO, 0);
    OpenMenu(0);
    Frames(1);
    Confirm(2, 1);
    CHECK(strcmp(Last("chat_send")->text, "The host disbanded the squad.") == 0);
    CHECK_EQ(Count("chat_rpc"), 1);
    CHECK_LOG("squad message sent to 1 player(s): The host disbanded the squad.");
    Frames(3);
    CHECK_EQ(Count("game_popup_kick"), 0); /* the kick waits for the message */
    Frames(70);
    CHECK_EQ(Count("game_popup_kick"), 1);
    CHECK_EQ(w.sessionCount, 1);
    /* The option switches them off: no line, no wait. */
    CHECK(vpm_option_apply(Option("messages"), 2));
    Squad(1, TANGO, 0);
    OpenMenu(0);
    Frames(1);
    Confirm(2, 1);
    Frames(3);
    CHECK_EQ(Count("chat_send"), 1);
    CHECK_EQ(Count("game_popup_kick"), 2);

    /* Unavailable: the actions still run silently. */
    fake_setup();
    NewWorld(0);
    Started();
    CHECK_LOG("squad messages unavailable: chat send changed");
    Squad(1, TANGO, 0);
    OpenMenu(0);
    Frames(1);
    Confirm(2, 1);
    Frames(2);
    CHECK_EQ(Count("chat_send"), 0);
    CHECK_EQ(Count("game_popup_kick"), 1);
}

/* A message that could not go out never holds the kick up; a successor who left during the notice is not kicked. */
static void MessagesNeverHoldTheKick(void)
{
    NewWorld(1);
    Started();
    Squad(1, TANGO, 0);
    w.chatEnabled = 0;
    OpenMenu(0);
    Frames(1);
    Confirm(2, 1);
    CHECK_LOG("squad message not sent: text chat is off");
    CHECK_EQ(Count("game_popup_kick"), 1); /* in the confirming frame */

    fake_setup();
    NewWorld(1);
    Started();
    Squad(2, TANGO, CHARLIE);
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    CHECK(strcmp(blm_lobby_status(), "promote: telling the squad") == 0);
    Squad(1, CHARLIE, 0); /* Tango left meanwhile */
    Frames(40);
    CHECK(strcmp(blm_lobby_status(), "promote failed: Tango left the squad meanwhile") == 0);
    CHECK_LOG("promote failed at announce: Tango left the squad meanwhile");
    CHECK_EQ(Count("game_popup_kick"), 0);
}

/* The release's PROMOTE: the game's new squad leader notice, the game's KICK 0.5 s later, the escape menu closed, the
 * successor's lobby found, the party join, and how many arrived 15 s later. */
static void PromoteMovesTheSquad(void)
{
    NewWorld(1);
    Started();
    Frames(1);
    Squad(1, TANGO, 0);
    w.successor = TANGO;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    CHECK(Last("rpc_send")->a == C_NEW_HOST && Last("rpc_send")->b == 0xFFFFFFFFFFFFFFFFull && Last("rpc_send")->c == 1);
    CHECK(Last("rpc_send")->d == TANGO && g_rpcType == 9 && g_rpcSize == 8);
    CHECK_EQ(Count("chat_send"), 0);
    CHECK_LOG("squad leader notice sent to 1 player(s): Tango");
    CHECK(strcmp(blm_lobby_status(), "promote: telling the squad") == 0);
    Frames(3);
    CHECK_EQ(Count("game_popup_kick"), 0); /* the kick waits for the notice */
    Frames(60);
    CHECK_EQ(Count("game_popup_kick"), 1);
    CHECK_EQ(Count("escape_closed"), 1);
    CHECK_LOG("promote: escape menu closed");
    w.arrivals[0] = TANGO;
    w.arrivals[1] = ME;
    w.arrivalCount = 2;
    Ticks((int)((0.5 + 2 + 15) / DT) + 1);
    CHECK_LOG("promote: found Tango's lobby after 1 search(es)");
    CHECK_LOG("promote: squad moved to Tango's ship (kicked in ");
    CHECK_LOG("promote: 2 of 2 players in Tango's session 15 s after the move");
    CHECK(Last("start_join")->a == w.ctx + BLM_JOIN && strcmp(Last("start_join")->text, "connection-string-of-successor") == 0);
    CHECK(Last("start_join")->b == 2 && Last("start_join")->c == 0 && Last("start_join")->d == 5);
}

/* ==== squad actions (test_lobby.lua) ================================================================================= */

static void DisbandRefuses(void)
{
    static const char* const texts[] = {"only on the ship", "not hosting", "not hosting", "no other players",
        "a transition is running", "a join is running", "a join is running", "no network session"};
    for (int c = 0; c < 8; c++)
    {
        char text[96];
        const char* why = "";
        fake_setup();
        NewWorld(0);
        Started();
        Squad(2, TANGO, CHARLIE);
        if (c == 0) w.mode = BLM_MODE_MISSION;
        if (c == 1) w.host = CHARLIE;
        if (c == 2) w.hosting = 2;
        if (c == 3) w.sessionCount = 1;
        if (c == 4) w.transition = 1;
        if (c == 5) w.joinState = 1;
        if (c == 6) w.partyJoin = 1;
        Sync();
        if (c == 7) Put64(Game(BLM_CONTEXT_PTR), 0);
        OpenMenu(0);
        CHECK_EQ(blm_lobby_disband(0, &why), 0);
        CHECK(strcmp(why, texts[c]) == 0);
        snprintf(text, sizeof text, "disband refused: %s", texts[c]);
        CHECK(strcmp(blm_lobby_status(), text) == 0);
        CHECK_LOG(text);
        Frames(3);
        CHECK_EQ(Count("game_popup_kick"), 0);
    }
    for (int mode = 0; mode < 2; mode++)
    {
        const char* why = "";
        fake_setup();
        NewWorld(0);
        Started();
        Squad(1, TANGO, 0);
        w.mode = mode == 0 ? BLM_MODE_MISSION : 7;
        Sync();
        CHECK_EQ(blm_lobby_promote(NULL, 0, &why), 0);
        CHECK(strcmp(blm_lobby_status(), "promote refused: only on the ship") == 0);
    }
}

/* A disband whose kicked players stay ends at its deadline; a player who left before their turn is skipped. */
static void DisbandDeadline(void)
{
    const char* why = "";
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    w.keepRemoved = 1;
    OpenMenu(0);
    CHECK_EQ(blm_lobby_disband(0, &why), 1);
    Frames((int)(11.0 / DT));
    CHECK(strcmp(blm_lobby_status(), "disbanded (2 players; 2 still leaving)") == 0);
    CHECK_LOG("game kick: 100000000000005 is still in the session; the player menu's KICK did not run");

    fake_setup();
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    OpenMenu(0);
    CHECK_EQ(blm_lobby_disband(0, &why), 1);
    Squad(0, 0, 0);
    Frames(2);
    CHECK(strcmp(blm_lobby_status(), "disbanded (1 players)") == 0);
}

static void SuccessorChoice(void)
{
    BlmSession snap;
    BlmPeer pick;
    int friend;
    const char* why = "";
    const uint64_t delta = DELTA, tango = TANGO;
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    CHECK(blm_lobby_snapshot(&snap));
    CHECK(blm_choose_successor(&snap, NULL, &pick, &friend, &why) && pick.id == TANGO && !friend); /* the lowest peer id */
    CHECK_EQ(Count("is_friend"), 2); /* every squad member is asked */
    w.friends[w.friendCount++] = CHARLIE;
    CHECK(blm_choose_successor(&snap, NULL, &pick, &friend, &why) && pick.id == CHARLIE && friend); /* a friend first */
    CHECK(blm_choose_successor(&snap, &tango, &pick, &friend, &why) && pick.id == TANGO); /* the picked player */
    CHECK(!blm_choose_successor(&snap, &delta, &pick, &friend, &why));
    CHECK(strcmp(why, "that player is no longer in the squad") == 0);
    Squad(0, 0, 0);
    CHECK(blm_lobby_snapshot(&snap));
    CHECK(!blm_choose_successor(&snap, NULL, &pick, &friend, &why) && strcmp(why, "no other players") == 0);
}

/* The successor kicked home, its lobby found by host id, the squad party-joins it and stays; 15 s after the move one
 * line says how many arrived, with no reads before then. */
static void PromoteFindsTheLobby(void)
{
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    w.successor = TANGO;
    w.arrivals[0] = TANGO;
    w.arrivals[1] = ME;
    w.arrivals[2] = CHARLIE;
    w.arrivalCount = 3;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    CHECK_EQ(Count("game_popup_kick"), 1);
    CHECK(Last("game_popup_kick")->a == TANGO);
    CHECK_LOG("promote: successor Tango (100000000000005, player 2)");
    Ticks(1);
    CHECK(strcmp(blm_lobby_status(), "promote: waiting for Tango's lobby") == 0);
    /* Waiting for the successor's lobby: plain loads only, no search before FIRST_SEARCH. */
    fake_counts_reset();
    int calls = g_callCount;
    Ticks(5);
    CHECK_EQ(Reads(), 0);
    CHECK_EQ(g_callCount, calls);
    for (int i = 0; i < 60 && Count("browser_start") == 0; i++) Ticks(1);
    CHECK_EQ(Count("clear_filters"), 1);
    CHECK(Last("filter_string")->b == 3 && Last("filter_string")->c == 2);
    CHECK(strcmp(Last("filter_string")->text, "72057594037927941") == 0); /* the successor's id in decimal */
    for (int i = 0; i < 20 && Count("start_join") == 0; i++) Ticks(1);
    CHECK(strcmp(Last("start_join")->text, "connection-string-of-successor") == 0);
    CHECK(strcmp(blm_lobby_status(), "promote: moving the squad to Tango") == 0);
    for (int i = 0; i < 30 && blm_lobby_busy(); i++) Ticks(1);
    double kicked = -1, found = -1, joined = -1;
    CHECK_EQ(sscanf(blm_lobby_status(), "squad moved to Tango's ship (kicked in %lf s, lobby found %lf s later, joined in %lf s)",
        &kicked, &found, &joined), 3);
    CHECK(kicked >= 0 && kicked < 0.05 && found >= 0.5 && found < 0.7 && joined >= 0 && joined < 0.2);
    CHECK_EQ(blm_lobby_actions(), 1);
    CHECK(blm_lobby_arrival_pending());
    fake_counts_reset();
    Frames((int)(14.0 / DT));
    CHECK_EQ(Reads(), 0);
    CHECK_NO_LOG("players in Tango's session");
    Frames((int)(1.5 / DT));
    CHECK_LOG("promote: 3 of 3 players in Tango's session 15 s after the move");
    CHECK(!blm_lobby_arrival_pending());

    /* A member who stayed behind is counted; a host who left the new session is told so. */
    fake_setup();
    NewWorld(0);
    Started();
    Squad(2, TANGO, CHARLIE);
    w.successor = TANGO;
    w.arrivals[0] = TANGO;
    w.arrivals[1] = ME;
    w.arrivalCount = 2;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    Ticks(1100);
    CHECK_LOG("promote: 2 of 3 players in Tango's session");
    fake_setup();
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    w.successor = TANGO;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    for (int i = 0; i < 300 && blm_lobby_busy(); i++) Ticks(1);
    w.host = ME;
    Ticks((int)(16.0 / DT));
    CHECK_LOG("promote: no longer in Tango's session 15 s after the move");
}

/* Searches start 0.5 s after the successor left, retry every 0.5 s for 15 s, then every 4 s, and give up after 60 s. */
static void PromoteRetries(void)
{
    double starts[8];
    int n = 0;
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    w.successor = TANGO;
    w.lobbyAfter = 3;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    for (int i = 0; i < 400 && Count("start_join") == 0; i++)
    {
        int before = Count("browser_start");
        Ticks(1);
        if (Count("browser_start") > before && n < 8) starts[n++] = i * DT;
    }
    CHECK_EQ(n, 3);
    CHECK_EQ(Count("start_join"), 1);
    CHECK(fabs(starts[1] - starts[0] - 0.5) < 0.2 && fabs(starts[2] - starts[1] - 0.5) < 0.2);

    fake_setup();
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    w.successor = TANGO;
    w.lobbyAfter = 1000000;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    for (int i = 0; i < (int)(80.0 / DT) && blm_lobby_busy(); i++) Ticks(1);
    CHECK(strcmp(blm_lobby_status(), "promote failed: Tango's lobby was not found") == 0);
    CHECK_LOG("promote failed at search: Tango's lobby was not found");
    int limit = 29 + 12 + 1, count = Count("browser_start");
    CHECK(count <= limit && count >= limit - 4);
    CHECK_EQ(Count("start_join"), 0);
}

/* The successor search never overlaps a game search (quickplay, the scanner or a busy browser). */
static void SearchWaitsForTheGame(void)
{
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    w.successor = TANGO;
    w.requests[1] = 1;
    OpenMenu(0);
    Frames(1);
    Confirm(3, 1);
    Ticks((int)(3.5 / DT));
    CHECK_EQ(Count("browser_start") + Count("clear_filters"), 0);
    w.requests[1] = 0;
    w.busy = 1000000000;
    Ticks(60);
    CHECK_EQ(Count("browser_start"), 0);
    w.busy = 0;
    for (int i = 0; i < 60 && Count("browser_start") == 0; i++) Ticks(1);
    CHECK_EQ(Count("browser_start"), 1);
}

static void PromoteSetup(void)
{
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    w.successor = TANGO;
    OpenMenu(0);
    Frames(1);
}

/* Refused joins, successors that stay, empty results, refused starts, lost sessions and overlaps fail cleanly. */
static void PromoteFailures(void)
{
    const char* why = "";
    PromoteSetup();
    w.joinOutcome = 1;
    Confirm(3, 1);
    for (int i = 0; i < 3000 && blm_lobby_busy(); i++) Ticks(1);
    CHECK(strcmp(blm_lobby_status(), "promote failed: Tango's game refused the squad (privacy or room)") == 0);

    fake_setup();
    PromoteSetup();
    w.keepRemoved = 1;
    Confirm(3, 1);
    Ticks((int)(11.0 / DT));
    CHECK(strcmp(blm_lobby_status(), "promote failed: Tango is still in the session") == 0);

    fake_setup();
    PromoteSetup();
    w.emptyConnection = 1;
    Confirm(3, 1);
    Ticks((int)(2.0 / DT));
    CHECK_EQ(Count("start_join"), 0); /* a result without a connection string is skipped */
    CHECK(Count("browser_start") >= 2);

    fake_setup();
    PromoteSetup();
    w.joinRefusesStart = 1;
    Confirm(3, 1);
    for (int i = 0; i < 2000 && blm_lobby_busy(); i++) Ticks(1);
    CHECK(strcmp(blm_lobby_status(), "promote failed: the game refused to start the party join") == 0);

    fake_setup();
    PromoteSetup();
    Confirm(3, 1);
    Put64(Game(BLM_CONTEXT_PTR), 0);
    Frames(1);
    CHECK(!blm_lobby_busy());
    CHECK(strcmp(blm_lobby_status(), "promote failed: network session lost") == 0);

    fake_setup();
    PromoteSetup();
    Confirm(3, 1);
    CHECK_EQ(blm_lobby_disband(0, &why), 0);
    CHECK(strcmp(why, "another action is running (promote)") == 0);
    CHECK_EQ(blm_lobby_cancel("test"), 1);
    CHECK(!blm_lobby_busy());
    CHECK(strcmp(blm_lobby_status(), "promote failed: cancelled: test") == 0);
    CHECK_EQ(blm_lobby_cancel("again"), 0);
}

/* The player menu's KICK waits for the menu to take input, gives up after 5 s, and reports a KICK that did not run. */
static void GameKickWaits(void)
{
    const char* why = "";
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    OpenMenu(0);
    Put8(w.content + M_DIALOG_INACTIVE, 0); /* busy: a dialog is showing */
    CHECK_EQ(blm_lobby_disband(0, &why), 1);
    Frames(1);
    CHECK_LOG("game kick: waiting for the escape menu (busy)");
    Frames((int)(5.2 / DT));
    CHECK_LOG("game kick: gave up on 100000000000005 (busy)");
    CHECK(!blm_lobby_ui_pending());
    CHECK_EQ(Count("game_popup_kick"), 0);

    fake_setup();
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    CHECK_EQ(blm_lobby_disband(0, &why), 1); /* the menu closed */
    Frames(1);
    CHECK_LOG("game kick: waiting for the escape menu (menu closed)");
    Frames((int)(5.2 / DT));
    CHECK_LOG("game kick: gave up on 100000000000005 (menu closed)");

    /* A reset drops the action and the queued kicks; nothing is kicked afterwards. */
    fake_setup();
    NewWorld(0);
    Started();
    Squad(1, TANGO, 0);
    CHECK_EQ(blm_lobby_disband(0, &why), 1);
    CHECK(blm_lobby_busy() && blm_lobby_ui_pending());
    fake_counts_reset();
    CHECK_EQ(blm_lobby_reset("paused"), 1);
    CHECK_EQ(Reads(), 0);
    CHECK(!blm_lobby_busy() && !blm_lobby_ui_pending());
    CHECK(strcmp(blm_lobby_status(), "disband failed: cancelled: paused") == 0);
    OpenMenu(0);
    Frames(3);
    CHECK_EQ(Count("game_popup_kick"), 0);
    CHECK_EQ(blm_lobby_reset("again"), 0);
}

/* ==== nearby lobbies (test_region.lua) =============================================================================== */

static void RegionKeys(void)
{
    for (int i = 0; i < 16; i++) CHECK_EQ(PairKey(kLivePairs[i].own, kLivePairs[i].other), kLivePairs[i].key);
    static const char* const rows[6] = {"AF", "AS", "EU", "NA", "OC", "SA"};
    for (int i = 0; i < 6; i++)
    {
        const uint32_t words[3] = {R_KEY_A, R_KEY_B, ContinentId(rows[i])};
        CHECK_EQ(blm_region_combine(words, 3), RowKey(rows[i]));
    }
    const uint32_t a[2] = {0x673BC524u, 0x244E3796u}, b[2] = {0x673BC524u, 0x2F5E2854u};
    CHECK_EQ(blm_region_combine(a, 2), 0xA6EB4F53u);
    CHECK_EQ(blm_region_combine(b, 2), 0xF5007569u);
}

static void Table(uintptr_t header, uint8_t* out) { memcpy(out, (const void*)header, R_CHECKSUM + 4); }
static uint8_t g_before[R_CHECKSUM + 4], g_after[R_CHECKSUM + 4];

static void RegionWorld(const char* code, const Extra* extra, int extras, const Extra* synced, int synceds)
{
    NewWorld(0);
    InstallConfig(code, extra, extras, synced, synceds);
    Started();
}

/* Own continent only (NA): EU flipped, AN added, SA left to the peer-synced table; one page check; the rest untouched;
 * off again the table is the server's byte for byte. */
static void RegionWritesTheRow(void)
{
    static uint8_t synced[R_CHECKSUM + 4];
    const Extra extra[1] = {{"NA", "EU", 1}}, peer[1] = {{"NA", "SA", 1}};
    RegionWorld("NA", extra, 1, peer, 1);
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
    Table(w.main, g_before);
    Table(w.synced, synced);
    uint32_t count = Get32(w.main + R_COUNT);
    int pages = blm_page_checks();
    fake_counts_reset();
    CHECK_EQ(blm_region_set_mode(2), 1);
    CHECK(strcmp(blm_region_status(), "my continent only (NA)") == 0);
    CHECK_EQ(blm_page_checks() - pages, 1); /* one page check for every write */
    CHECK_EQ(Reads(), 8);                   /* both tables' layouts, confirmed once */
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC") == 0);
    CHECK_EQ(Get32(FindEntry(w.synced, PairKey("NA", "SA")) + 24), 1); /* the peer-synced SA flag answers first */
    Table(w.synced, g_after);
    CHECK(memcmp(synced, g_after, sizeof g_after) == 0); /* never written */
    CHECK(strcmp(Excluded("EU"), "SA") == 0 && strcmp(Excluded("AF"), "NA OC SA") == 0); /* other rows untouched */
    CHECK_EQ(Get32(w.main + R_CHECKSUM), R_SERVER_CHECKSUM);
    CHECK_EQ(Get32(w.main + R_COUNT), count + 1);
    /* The added entry looks like the server's own. */
    uintptr_t entry = FindEntry(w.main, PairKey("NA", "AN"));
    const uint32_t expect[12] = {PairKey("NA", "AN"), 0, ContinentId("AN"), RowKey("NA"), PairKey("NA", "AN"), R_BOOL, 0, 0, 0, 0, R_WEIGHT, 0};
    for (uint32_t i = 0; i < 12; i++) CHECK_EQ(Get32(entry + i * 4), expect[i]);
    CHECK_LOG("nearby lobbies: NA->SA set by the peer-synced config; left unchanged");
    CHECK_LOG("nearby lobbies: own continent only, 2 flags written");
    /* Off again: the table is byte-identical to the server's, with no page check (checked once for this object). */
    pages = blm_page_checks();
    CHECK_EQ(blm_region_set_mode(1), 1);
    CHECK_EQ(blm_page_checks(), pages);
    Table(w.main, g_after);
    CHECK(memcmp(g_before, g_after, sizeof g_after) == 0);
    CHECK(strcmp(blm_region_status(), "game default") == 0);
    CHECK_LOG("nearby lobbies: game default, 2 flags restored");
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
    CHECK(blm_region_set_mode(2) && strcmp(Excluded("NA"), "AF AN AS EU OC") == 0);
}

static void RegionOtherContinents(void)
{
    RegionWorld("SA", NULL, 0, NULL, 0);
    CHECK(blm_region_set_mode(2) && strcmp(Excluded("SA"), "AF AN AS EU NA OC") == 0);
    fake_setup();
    RegionWorld("AN", NULL, 0, NULL, 0);
    Table(w.main, g_before);
    CHECK(blm_region_set_mode(2) && strcmp(Excluded("AN"), "AF AS EU NA OC SA") == 0);
    CHECK_EQ(Get32(w.main + R_COUNT), 17 + 6);
    CHECK(blm_region_set_mode(1));
    Table(w.main, g_after);
    CHECK(memcmp(g_before, g_after, sizeof g_after) == 0);
}

/* Nothing while off; nothing between checks; a check with the flags in place is plain loads only. */
static void RegionCost(void)
{
    RegionWorld("NA", NULL, 0, NULL, 0);
    fake_counts_reset();
    blm_region_step();
    CHECK_EQ(Reads(), 0);
    CHECK(blm_region_set_mode(2));
    int pages = blm_page_checks();
    fake_counts_reset();
    for (int i = 0; i < 3 * 120; i++) blm_region_step();
    CHECK_EQ(Reads() + fake_counts().log, 0);
    CHECK_EQ(blm_page_checks(), pages);
}

static void Steps(int n) { for (int i = 0; i < n; i++) blm_region_step(); }

/* Flags survive unchanged downloads, come back after changed ones, and restore to whatever the server sent. */
static void RegionFollowsDownloads(void)
{
    const Extra extra[1] = {{"NA", "EU", 1}};
    RegionWorld("NA", NULL, 0, NULL, 0);
    CHECK(blm_region_set_mode(2));
    int pages = blm_page_checks();
    Steps(240);
    CHECK_EQ(blm_page_checks(), pages);
    Download(0x0BADC0DEu, extra, 1);
    Table(w.main, g_before);
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
    Steps(120);
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0);
    CHECK_LOG("nearby lobbies: re-applied, 3 flags written");
    CHECK(blm_region_set_mode(1));
    Table(w.main, g_after);
    CHECK(memcmp(g_before, g_after, sizeof g_after) == 0); /* the new server table */
    /* Replaced before the next check: the records are dropped, nothing is written. */
    CHECK(blm_region_set_mode(2));
    Download(0x12345678u, NULL, 0);
    Table(w.main, g_before);
    CHECK(blm_region_set_mode(1));
    Table(w.main, g_after);
    CHECK(memcmp(g_before, g_after, sizeof g_after) == 0);
    CHECK(strcmp(blm_region_status(), "game default") == 0);
    /* Cleared and reloaded with the same content and checksum (sign out, sign in). */
    CHECK(blm_region_set_mode(2));
    ClearTable(w.main);
    Steps(120);
    CHECK(strcmp(blm_region_status(), "my continent only: waiting (override data not loaded)") == 0);
    Download(0x12345678u, NULL, 0);
    Steps(120);
    CHECK(strcmp(blm_region_status(), "my continent only (NA)") == 0);
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0);
    CHECK(blm_region_set_mode(1));
    Table(w.main, g_after);
    CHECK(memcmp(g_before, g_after, sizeof g_after) == 0);
}

/* An unknown continent, a refused write, a full table or a changed layout waits and reports once. */
static void RegionWaits(void)
{
    RegionWorld("NA", NULL, 0, NULL, 0);
    w.continentKnown = 0;
    CHECK_EQ(blm_region_set_mode(2), 0);
    CHECK(strcmp(blm_region_status(), "my continent only: waiting (continent unknown)") == 0);
    fake_log_clear();
    Steps(3 * 120);
    CHECK_NO_LOG("nearby lobbies"); /* a waiting reason is logged once */
    w.continentKnown = 1;
    Steps(120);
    CHECK(strcmp(blm_region_status(), "my continent only (NA)") == 0);
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0);

    fake_setup();
    RegionWorld("NA", NULL, 0, NULL, 0);
    ReadOnly(w.main, R_SPAN, 1);
    int pages = blm_page_checks();
    CHECK_EQ(blm_region_set_mode(2), 0);
    CHECK_EQ(blm_page_checks() - pages, 1);
    CHECK(strcmp(blm_region_status(), "my continent only: waiting (write refused)") == 0);
    pages = blm_page_checks();
    Steps(3 * 120);
    CHECK_EQ(blm_page_checks(), pages); /* a refused write is not retried until the table changes */
    Download(0x0BADC0DEu, NULL, 0);
    Steps(120);
    CHECK_EQ(blm_page_checks() - pages, 1);
    ReadOnly(w.main, R_SPAN, 0);
    Download(0x0BADF00Du, NULL, 0);
    Steps(120);
    CHECK(strcmp(blm_region_status(), "my continent only (NA)") == 0);
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0);

    fake_setup();
    RegionWorld("NA", NULL, 0, NULL, 0);
    uint32_t filler = 1;
    for (uint32_t slot = 0; slot < R_CAPACITY; slot++)
    {
        uintptr_t entry = w.main + R_ENTRIES + slot * R_ENTRY;
        if (Get32(entry) == 0) Put32(entry, filler++);
    }
    pages = blm_page_checks();
    CHECK_EQ(blm_region_set_mode(2), 0);
    CHECK(strcmp(blm_region_status(), "my continent only: waiting (override table full)") == 0);
    CHECK_EQ(blm_page_checks(), pages);

    fake_setup();
    RegionWorld("NA", NULL, 0, NULL, 0);
    Put64(w.main, 0x1000);
    CHECK_EQ(blm_region_set_mode(2), 0);
    CHECK(strcmp(blm_region_status(), "my continent only: waiting (override table layout changed)") == 0);
}

/* Lobby Region follows the option, and the component's stop restores the table. */
static void RegionOption(void)
{
    NewWorld(0);
    Started();
    Frames(1);
    CHECK(vpm_option_apply(Option("region"), 2));
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0);
    CHECK(vpm_option_apply(Option("region"), 1));
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
    CHECK(vpm_option_apply(Option("region"), 2));
    vpm_core_stop(Self(), "test");
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
    CHECK_LOG("Better Lobby Management stopped for this session; region flags restored");

    fake_setup();
    SavedOption("better_lobby_management.region", "2");
    NewWorld(0);
    Started();
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0); /* the saved settings wait for the first frame */
    Frames(1);
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0);
}

/* ==== the scanner (test_scanner.lua) ================================================================================= */

typedef struct ScanCost { uint32_t reads; int pages; } ScanCost;

static ScanCost Check(int* result)
{
    int pages = blm_page_checks();
    fake_counts_reset();
    int value = blm_scanner_check();
    if (result != NULL) *result = value;
    return (ScanCost){Reads(), blm_page_checks() - pages};
}

#define CHECK_SCAN(r_, p_) do { ScanCost c_ = Check(NULL); CHECK_EQ(c_.reads, r_); CHECK_EQ(c_.pages, p_); } while (0)
#define FIELD (w.scannerConfig + S_RECHARGE)
#define SCAN_COUNTDOWN (w.match + S_COUNTDOWN)

static void ScannerWorld(void)
{
    NewWorld(0);
    Started();
}

static void Summary(char* out) { blm_scanner_summary(out, 256); }

static void ScannerFollowsTheGame(void)
{
    char text[256];
    ScannerWorld();
    uintptr_t other = Pages(0x3D000);
    Put32(other + S_RECHARGE, 20);
    Put64(Game(S_CONFIG_PTR), 0);
    CHECK_SCAN(0, 0); /* boot: no config object yet */
    CHECK(strcmp(blm_scanner_state(), "waiting_for_config") == 0);
    Put64(Game(S_CONFIG_PTR), w.scannerConfig);
    uint32_t revision = blm_scanner_revision();
    CHECK_SCAN(2, 1); /* first sight: confirmed, written (its page checked once), the countdown looked at */
    CHECK(Get32(FIELD) == 5 && strcmp(blm_scanner_state(), "active") == 0 && blm_scanner_revision() > revision);
    Summary(text);
    CHECK(strcmp(text, "scanner active: setting 5 s, game 20 s, field 5 s; writes 1, game rewrites 0, countdowns shortened 0") == 0);
    revision = blm_scanner_revision();
    for (int i = 0; i < 5; i++) CHECK_SCAN(0, 0); /* idle: two plain loads */
    CHECK_EQ(blm_scanner_revision(), revision);
    Put32(FIELD, 20); /* the game's config rewrites its usual 20 */
    CHECK_SCAN(1, 0);
    CHECK(Get32(FIELD) == 5 && blm_scanner_revision() == revision);
    CHECK_SCAN(0, 0);
    Put32(FIELD, 20); /* a rewrite that raced a scan result */
    PutF(SCAN_COUNTDOWN, 19.5f);
    CHECK_SCAN(1, 1);
    CHECK(GetF(SCAN_COUNTDOWN) == 5.0f);
    Put32(FIELD, 12); /* the server changes its value */
    PutF(SCAN_COUNTDOWN, 0.4f);
    CHECK_SCAN(1, 0);
    CHECK(Get32(FIELD) == 5 && blm_scanner_revision() > revision);
    revision = blm_scanner_revision();
    CHECK(blm_scanner_set_setting(8) && blm_scanner_revision() > revision);
    PutF(SCAN_COUNTDOWN, 9.25f);
    CHECK_SCAN(1, 0);
    CHECK(Get32(FIELD) == 8 && GetF(SCAN_COUNTDOWN) == 8.0f);
    CHECK_SCAN(0, 0);
    CHECK(blm_scanner_set_setting(6));
    PutF(SCAN_COUNTDOWN, 2.5f);
    CHECK_SCAN(1, 0);
    CHECK(GetF(SCAN_COUNTDOWN) == 2.5f && Get32(FIELD) == 6);
    PutF(SCAN_COUNTDOWN, 0);
    revision = blm_scanner_revision();
    CHECK(blm_scanner_set_setting(6) && blm_scanner_revision() == revision);
    CHECK_SCAN(0, 0);
    CHECK(blm_scanner_set_setting(20)); /* at or above the game's value: the game's value, never longer */
    CHECK_SCAN(0, 0);
    CHECK(Get32(FIELD) == 12 && strcmp(blm_scanner_state(), "game_value_kept") == 0);
    CHECK_SCAN(0, 0);
    Put32(FIELD, 20); /* the server back to 20: the setting 20 matches it, no write */
    CHECK_SCAN(0, 0);
    CHECK(Get32(FIELD) == 20 && strcmp(blm_scanner_state(), "game_value_kept") == 0);
    CHECK(blm_scanner_set_setting(5));
    CHECK_SCAN(1, 0);
    CHECK_EQ(Get32(FIELD), 5);
    /* Whole seconds in 5 .. 20; nonsense is refused. */
    CHECK(blm_scanner_set_setting(0.2) && blm_scanner_set_setting(1) && blm_scanner_set_setting(4.4));
    CHECK(blm_scanner_set_setting(7.6));
    Summary(text);
    CHECK(strstr(text, "setting 8 s") != NULL);
    CHECK(blm_scanner_set_setting(99));
    Summary(text);
    CHECK(strstr(text, "setting 20 s") != NULL);
    CHECK(!blm_scanner_set_setting(NAN));
    CHECK(blm_scanner_set_setting(5));
    CHECK_SCAN(0, 0);
    /* A server value below the shortest setting is the game's choice: kept. */
    Put32(FIELD, 3);
    CHECK_SCAN(0, 0);
    CHECK(Get32(FIELD) == 3 && strcmp(blm_scanner_state(), "game_value_kept") == 0);
    Summary(text);
    CHECK(strstr(text, "game 3 s, field 3 s") != NULL);
    /* Implausible game values are left alone; a sane value resumes. */
    const uint32_t bad[3] = {0, 3601, 0xFFFFFFFFu};
    for (int i = 0; i < 3; i++)
    {
        Put32(FIELD, bad[i]);
        CHECK_SCAN(0, 0);
        CHECK(Get32(FIELD) == bad[i]);
        CHECK(strcmp(blm_scanner_state(), i == 0 ? "waiting_for_game_value" : "unexpected_game_value") == 0);
        Summary(text);
        CHECK(strstr(text, "field nil s") != NULL);
        CHECK_SCAN(0, 0);
    }
    Put32(FIELD, 20);
    CHECK_SCAN(1, 0);
    CHECK(Get32(FIELD) == 5 && strcmp(blm_scanner_state(), "active") == 0);
    /* A new config object: confirmed once, its own value is the game's (a switch is not a rewrite). */
    Put64(Game(S_CONFIG_PTR), other);
    CHECK_SCAN(2, 1);
    CHECK_EQ(Get32(other + S_RECHARGE), 5);
    CHECK_SCAN(0, 0);
    Put64(Game(S_CONFIG_PTR), 0);
    CHECK_SCAN(0, 0);
    CHECK(strcmp(blm_scanner_state(), "waiting_for_config") == 0);
    Put64(Game(S_CONFIG_PTR), other);
    CHECK_SCAN(1, 0); /* the same object back: confirmed again, nothing to write */
    Summary(text);
    CHECK(strcmp(text, "scanner active: setting 5 s, game 20 s, field 5 s; writes 10, game rewrites 9, countdowns shortened 2") == 0);
    Put64(Game(S_CONFIG_PTR), UNMAPPED);
    CHECK_SCAN(1, 0); /* never loaded directly; asked again next frame */
    CHECK(strcmp(blm_scanner_state(), "waiting_for_config_read") == 0);
    CHECK_SCAN(1, 0);
    Put64(Game(S_CONFIG_PTR), 0x1234);
    CHECK_SCAN(0, 0);
    Put64(Game(S_CONFIG_PTR), other + 4);
    CHECK_SCAN(0, 0);
    Put64(Game(S_CONFIG_PTR), other);
    CHECK_SCAN(1, 0);
    /* Another writer fighting over the field: the mod stops instead of writing every frame. */
    int result = 1, rounds = 0;
    while (result && rounds < 1000)
    {
        Put32(other + S_RECHARGE, 7);
        (void)Check(&result);
        rounds++;
    }
    CHECK(strcmp(blm_scanner_state(), "field_contended") == 0 && Get32(other + S_RECHARGE) == 7);
    CHECK_EQ(rounds, 500 - 9 + 1);
    CHECK_SCAN(0, 0);
    CHECK_EQ(blm_scanner_check(), 0);
}

static void ScannerEdges(void)
{
    /* A new object whose own value (5) equals what the mod wrote to the old one: the game's value now. */
    ScannerWorld();
    CHECK_SCAN(2, 1);
    uintptr_t third = Pages(0x3D000);
    Put32(third + S_RECHARGE, 5);
    Put64(Game(S_CONFIG_PTR), third);
    CHECK_SCAN(1, 0);
    CHECK(strcmp(blm_scanner_state(), "game_value_kept") == 0);
    CHECK(blm_scanner_set_setting(8));
    CHECK_SCAN(0, 0);
    CHECK_EQ(Get32(third + S_RECHARGE), 5);
    /* No matchmaking object yet: the countdown is not touched. */
    fake_setup();
    ScannerWorld();
    Put64(Game(BLM_MATCHMAKING_PTR), 0);
    CHECK_SCAN(1, 1);
    CHECK(strcmp(blm_scanner_state(), "active") == 0);
    /* An unreadable countdown: left alone, still active. */
    fake_setup();
    ScannerWorld();
    Put64(Game(BLM_MATCHMAKING_PTR), UNMAPPED);
    CHECK_SCAN(2, 1);
    CHECK(strcmp(blm_scanner_state(), "active") == 0);
    /* A countdown the page check refuses: one recharge stays long, the mod stays active. */
    fake_setup();
    ScannerWorld();
    PutF(SCAN_COUNTDOWN, 15);
    ReadOnly(SCAN_COUNTDOWN, 4, 1);
    CHECK_SCAN(2, 2);
    CHECK(strcmp(blm_scanner_state(), "active") == 0 && GetF(SCAN_COUNTDOWN) == 15.0f);
    char text[256];
    Summary(text);
    CHECK(strstr(text, "countdowns shortened 0") != NULL);
    /* NaN and absurd countdowns are left alone. */
    const float values[3] = {NAN, 5000, -3};
    for (int i = 0; i < 3; i++)
    {
        fake_setup();
        ScannerWorld();
        PutF(SCAN_COUNTDOWN, values[i]);
        CHECK_SCAN(2, 1);
        Summary(text);
        CHECK(strstr(text, "countdowns shortened 0") != NULL);
    }
    /* A refused config write stops it: nothing more is read or written. */
    fake_setup();
    ScannerWorld();
    ReadOnly(FIELD, 4, 1);
    int result = 1;
    (void)Check(&result);
    CHECK_EQ(result, 0);
    CHECK(strcmp(blm_scanner_state(), "config_write_failed") == 0 && Get32(FIELD) == 20);
    CHECK_SCAN(0, 0);
}

/* stop() puts the game's value back only while the field holds the mod's value. */
static void ScannerStops(void)
{
    ScannerWorld();
    CHECK_SCAN(2, 1);
    CHECK(blm_scanner_stop("stopped_after_error") && Get32(FIELD) == 20);
    CHECK(strcmp(blm_scanner_state(), "stopped_after_error") == 0 && blm_scanner_check() == 0);
    fake_setup();
    ScannerWorld();
    CHECK_SCAN(2, 1);
    Put32(FIELD, 25); /* the game wrote meanwhile: its value stays */
    CHECK(blm_scanner_stop("x") && Get32(FIELD) == 25);
    fake_setup();
    ScannerWorld();
    Put64(Game(S_CONFIG_PTR), 0);
    CHECK_SCAN(0, 0);
    CHECK(blm_scanner_stop("x"));
    fake_setup();
    ScannerWorld();
    CHECK(blm_scanner_set_setting(20));
    CHECK_SCAN(1, 0);
    CHECK(strcmp(blm_scanner_state(), "game_value_kept") == 0);
    CHECK(blm_scanner_stop("x") && Get32(FIELD) == 20);
}

/* The component: 5 s by default, the slider, the game's rewrites re-applied, a saved setting, the stop. */
static void ScannerOption(void)
{
    char text[256];
    NewWorld(0);
    Started();
    Frames(1);
    CHECK_EQ(Get32(FIELD), 5);
    CHECK_LOG("scanner active: setting 5 s, game 20 s, field 5 s");
    CHECK(vpm_option_apply(Option("scanner_seconds"), 12));
    Frames(1);
    CHECK_EQ(Get32(FIELD), 12);
    Put32(FIELD, 20); /* the game's configuration download */
    Frames(1);
    CHECK_EQ(Get32(FIELD), 12);
    Summary(text);
    CHECK(strcmp(text, "scanner active: setting 12 s, game 20 s, field 12 s; writes 3, game rewrites 1, countdowns shortened 0") == 0);
    vpm_core_stop(Self(), "test");
    CHECK_EQ(Get32(FIELD), 20);

    fake_setup();
    SavedOption("better_lobby_management.scanner_seconds", "8");
    NewWorld(0);
    Started();
    Frames(1);
    CHECK_EQ(Get32(FIELD), 8);
}

/* ==== CANCEL SOS (test_sos.lua) ====================================================================================== */

static void SosWorld(void)
{
    NewWorld(0);
    Started();
    w.mode = BLM_MODE_MISSION;
    Sync();
}

static void SosTexts(void)
{
    char body[256];
    SosWorld();
    blm_sos_body(0, body, sizeof body);
    CHECK(strcmp(body, "Stops your SOS, also when a slot opens. Quickplay still finds your Public lobby. You can call in "
        "the SOS Beacon again.") == 0);
    blm_sos_body(1, body, sizeof body);
    CHECK(strstr(body, "returns to Friends Only. You can") != NULL);
    blm_sos_body(2, body, sizeof body);
    CHECK(strstr(body, "returns to Invite Only.") != NULL);
    blm_sos_body(3, body, sizeof body);
    CHECK(strstr(body, "returns to Friends and Clan.") != NULL);
    blm_sos_body(9, body, sizeof body);
    CHECK(strstr(body, "returns to its privacy setting.") != NULL);
    for (uint32_t privacy = 0; privacy <= 9; privacy++)
    {
        blm_sos_body(privacy, body, sizeof body);
        CHECK(strlen(body) <= 120);
    }
    const char* why = "";
    CHECK_EQ(blm_sos_cancel(0, &why), 0);
    CHECK(strcmp(why, "no SOS is on") == 0);
}

/* Offered only to a host in a mission with an SOS on: nothing read on the ship or as a client. */
static void SosOffer(void)
{
    BlmSession snap;
    uint32_t privacy = 99;
    SosWorld();
    CHECK(blm_lobby_snapshot(&snap));
    fake_counts_reset();
    CHECK_EQ(blm_sos_offer(&snap, &privacy), 0);
    CHECK_EQ(Reads(), 1); /* the first look: the SOS object confirmed once */
    fake_counts_reset();
    CHECK_EQ(blm_sos_offer(&snap, &privacy), 0);
    CHECK_EQ(Reads(), 0);
    SosBeacon();
    CHECK(blm_lobby_snapshot(&snap));
    CHECK(blm_sos_offer(&snap, &privacy) && privacy == 1);
    w.privacy = 0;
    Sync();
    CHECK(blm_sos_offer(&snap, &privacy) && privacy == 0); /* Public is offered too */
    w.mode = BLM_MODE_SHIP;
    Sync();
    CHECK(blm_lobby_snapshot(&snap));
    fake_counts_reset();
    CHECK_EQ(blm_sos_offer(&snap, &privacy), 0);
    CHECK_EQ(Reads(), 0);
    w.mode = BLM_MODE_MISSION;
    w.host = TANGO;
    Sync();
    CHECK(blm_lobby_snapshot(&snap));
    CHECK_EQ(blm_sos_offer(&snap, &privacy), 0);
    w.host = ME;
    w.transition = 2;
    Sync();
    CHECK(blm_lobby_snapshot(&snap));
    CHECK_EQ(blm_sos_offer(&snap, &privacy), 0);
    w.transition = 0;
    Sync();
    Put64(Game(B_SOS_PTR), 0);
    CHECK(blm_lobby_snapshot(&snap));
    CHECK_EQ(blm_sos_offer(&snap, &privacy), 0);
    CHECK_EQ(Count("sos_deactivate"), 0);
}

/* Why the mod sets key 19 itself: the game's own SOS off (the squad filling up) keeps the lobby Public while PlayFab
 * still shows the SOS (the fake game, as the Lua's). */
static void SosVanillaOff(void)
{
    SosWorld();
    Squad(2, TANGO, CHARLIE);
    SosBeacon();
    for (int i = 0; i < 2000; i++) LobbyUpdate(DT);
    PlayerJoins(DELTA);
    CHECK(w.sosActive == 0 && strcmp(Key(8), "0") == 0 && strcmp(Key(19), "0") == 0);
}

/* The cancel: the game's own SOS off and key setter once each, the lobby posted in this frame, the use given back. */
static void SosCancel(void)
{
    const char* why = "";
    int cancels, rearms, leaks;
    SosWorld();
    Squad(1, TANGO, 0);
    w.mode = BLM_MODE_MISSION;
    Sync();
    SosBeacon();
    CHECK_EQ(SosUses(), 0); /* the call-in spent the SOS Beacon's one use */
    for (int i = 0; i < 2000; i++) LobbyUpdate(DT);
    CHECK(strcmp(w.playfab[0], "1") == 0 && strcmp(w.playfab[1], "0") == 0); /* SOS lobbies are Public */
    int pages = blm_page_checks();
    fake_counts_reset();
    CHECK_EQ(blm_sos_cancel(12, &why), 1);
    /* The context, the SOS object, the stratagem settings and the player records confirmed with guarded reads; two
     * checked stores (the countdown's page and the slot's). */
    CHECK_EQ(Reads(), 8);
    CHECK_EQ(blm_page_checks() - pages, 2);
    CHECK_EQ(Count("sos_deactivate"), 1);
    CHECK(Last("sos_deactivate")->a == w.sos);
    CHECK(Last("lobby_set")->a == w.ctx + BLM_LOBBY && Last("lobby_set")->b == 19 && Last("lobby_set")->c == 1);
    CHECK(strcmp(Key(8), "0") == 0 && strcmp(Key(19), "1") == 0); /* the lobby is Friends Only again */
    CHECK(GetF(w.ctx + BLM_LOBBY + B_COUNTDOWN) == 0.0f);
    CHECK_EQ(SosUses(), 1);
    LobbyUpdate(DT);
    CHECK(strcmp(w.playfab[0], "0") == 0 && strcmp(w.playfab[1], "1") == 0); /* PlayFab has it at once */
    CHECK(blm_sos_cancelled());
    blm_sos_counts(&cancels, &rearms, &leaks);
    CHECK_EQ(cancels, 1);
    CHECK_LOG("SOS cancelled: lobby SOS flag 1, privacy 0 -> SOS flag 0, privacy 1 (privacy setting Friends Only); posted "
        "in this frame; SOS Beacon uses 0 -> 1");

    /* A refused write still cancels; the post then comes with the next lobby update. */
    fake_setup();
    SosWorld();
    SosBeacon();
    ReadOnly(w.ctx + BLM_LOBBY + B_COUNTDOWN, 4, 1);
    ReadOnly(w.sosSlot, 8, 1);
    CHECK_EQ(blm_sos_cancel(1, &why), 1);
    CHECK(strcmp(Key(8), "0") == 0 && SosUses() == 0);
    CHECK_LOG("the write was refused; posted at the next lobby update; SOS Beacon use: the write was refused");
}

typedef void (*Configure)(void);
static void UsesAlready(void) { Put32(w.sosSlot + 4, 1); }
static void NoLimit(void) { Put32(w.sosSettings + B_USES, B_NO_LIMIT); }
static void Shared(void) { Put32(w.sosSettings + B_SHARED, 1); }
static void OtherSettings(void) { Put32(w.sosSettings, 0x92); }
static void OtherSlot(void) { Put32(w.sosSlot, 0x92); }
static void OtherRecord(void) { Put64(w.players, 7); }
static void UnreadableRecords(void) { fake_hole(w.players + B_PLAYER_COUNT, 4); }
static void ThreeUses(void) { Put32(w.sosSettings + B_USES, 3); Put32(w.sosSlot + 4, 0); }

/* The use comes back only as the stratagem allows; the cancel works whatever the stratagem data says. */
static void SosRestoresTheUse(void)
{
    struct { Configure configure; const char* text; uint32_t uses; int pages; } cases[8] = {
        {UsesAlready, "; SOS Beacon uses already 1", 1, 1}, {NoLimit, "; the SOS Beacon has no use limit", 0, 1},
        {Shared, "; the SOS Beacon's uses are shared; not restored", 0, 1}, {OtherSettings, "; SOS Beacon settings unreadable", 0, 1},
        {OtherSlot, "; no SOS Beacon slot", 0, 1}, {OtherRecord, "; no player record of yours", 0, 1},
        {UnreadableRecords, "; player records unreadable", 0, 1}, {ThreeUses, "; SOS Beacon uses 0 -> 1", 1, 2}};
    for (int c = 0; c < 8; c++)
    {
        const char* why = "";
        fake_setup();
        SosWorld();
        SosBeacon();
        cases[c].configure();
        int pages = blm_page_checks();
        CHECK_EQ(blm_sos_cancel(3, &why), 1);
        CHECK_LOG(cases[c].text);
        if (cases[c].configure != OtherSlot) CHECK_EQ(Get32(w.sosSlot + 4), cases[c].uses);
        CHECK_EQ(blm_page_checks() - pages, cases[c].pages);
    }
}

/* After a cancel the SOS Beacon can be called in again: the new SOS lists, the mod lets it, a second cancel stops it. */
static void SosCalledInAgain(void)
{
    const char* why = "";
    SosWorld();
    Squad(1, TANGO, 0);
    w.mode = BLM_MODE_MISSION;
    Sync();
    SosBeacon();
    CHECK(blm_sos_cancel(0, &why) && SosUses() == 1);
    SosBeacon();
    CHECK(SosUses() == 0 && w.sosEnabled == 2 && w.sosActive == 1 && strcmp(Key(8), "1") == 0);
    blm_sos_keep(40);
    CHECK(!blm_sos_cancelled() && Count("sos_deactivate") == 1);
    CHECK_LOG("SOS: no longer kept off after 40 s (a new SOS beacon was called in)");
    CHECK(blm_sos_cancel(50, &why) && w.sosActive == 0 && SosUses() == 1 && blm_sos_cancelled());
}

/* Each refusal calls nothing and writes nothing. */
static void SosGates(void)
{
    static const char* const texts[5] = {"not hosting", "not hosting", "not in a mission", "a transition is running",
        "no network session"};
    for (int c = 0; c < 5; c++)
    {
        const char* why = "";
        char text[96];
        fake_setup();
        SosWorld();
        SosBeacon();
        if (c == 0) { const uint64_t peers[2] = {TANGO, ME}; SetSession(2, peers); w.host = TANGO; }
        if (c == 1) w.hosting = 2;
        if (c == 2) w.mode = BLM_MODE_SHIP;
        if (c == 3) w.transition = 1;
        Sync();
        if (c == 4) Put64(Game(BLM_CONTEXT_PTR), 0);
        int pages = blm_page_checks();
        CHECK_EQ(blm_sos_cancel(0, &why), 0);
        CHECK(strcmp(why, texts[c]) == 0);
        CHECK(Count("sos_deactivate") == 0 && blm_page_checks() == pages && !blm_sos_cancelled());
        snprintf(text, sizeof text, "cancel SOS refused: %s", texts[c]);
        CHECK_LOG(text);
    }
}

/* Kept off: the game's re-arm after a leave is turned off in the next frame, before the lobby posts it; a re-arm the
 * lobby already posted is posted again at once. */
static void SosKeptOff(void)
{
    const char* why = "";
    int cancels, rearms, leaks;
    SosWorld();
    Squad(2, TANGO, CHARLIE);
    w.mode = BLM_MODE_MISSION;
    Sync();
    SosBeacon();
    CHECK(blm_sos_cancel(0, &why));
    LobbyUpdate(DT); /* the cancel's post */
    int pages = blm_page_checks();
    fake_counts_reset();
    for (int i = 1; i <= 300; i++) blm_sos_keep(i);
    CHECK_EQ(Reads(), 0);
    int posts = Count("lobby_post");
    PlayerLeaves(CHARLIE); /* the game's re-arm, in the game's update */
    CHECK(w.sosActive == 1 && strcmp(Key(8), "1") == 0);
    LobbyUpdate(DT); /* the rest of that update: the countdown far from 0, nothing posted */
    blm_sos_keep(400);
    CHECK_EQ(Reads(), 0);
    CHECK(Count("sos_deactivate") == 2 && strcmp(Key(8), "0") == 0 && w.sosActive == 0);
    for (int i = 0; i < 2000; i++) LobbyUpdate(DT);
    CHECK(Count("lobby_post") == posts + 1 && strcmp(w.playfab[0], "0") == 0); /* PlayFab never saw the re-arm */
    blm_sos_counts(&cancels, &rearms, &leaks);
    CHECK(rearms == 1 && leaks == 0 && blm_page_checks() == pages); /* no page check for a caught re-arm */
    CHECK_LOG("SOS: the game listed it again (a player left or a new host); cancelled again");
    /* A re-arm the lobby posted in the same update: corrected in the next frame. */
    PlayerJoins(CHARLIE);
    PlayerLeaves(CHARLIE);
    PutF(w.ctx + BLM_LOBBY + B_COUNTDOWN, 0.001f);
    LobbyUpdate(DT);
    CHECK(strcmp(w.playfab[0], "1") == 0); /* the leak: PlayFab has the re-arm */
    blm_sos_keep(500);
    CHECK(blm_page_checks() == pages && GetF(w.ctx + BLM_LOBBY + B_COUNTDOWN) == 0.0f); /* the countdown's page checked once */
    LobbyUpdate(DT);
    CHECK(strcmp(w.playfab[0], "0") == 0 && strcmp(w.playfab[1], "1") == 0);
    blm_sos_counts(&cancels, &rearms, &leaks);
    CHECK(rearms == 2 && leaks == 1);
    CHECK_LOG("the lobby had already posted it, posted again in this frame");
}

static void NewBeacon(void) { SosBeacon(); }
static void NoBeacon(void) { w.sosEnabled = 0; }
static void ToShip(void) { w.mode = BLM_MODE_SHIP; }
static void NewSosObject(void) { Put64(Game(B_SOS_PTR), w.sos + 0x1000); }
static void NoSession(void) { Put64(Game(BLM_CONTEXT_PTR), 0); }
static void NotHost(void) { w.host = TANGO; w.sosActive = 1; }

/* A kept cancel ends with a new beacon, no beacon left, the mission's end, a new session or SOS object and a lost host;
 * one of two beacons gone keeps it. */
static void SosKeepEnds(void)
{
    struct { Configure configure; const char* text; } cases[6] = {{NewBeacon, "(a new SOS beacon was called in)"},
        {NoBeacon, "(no SOS beacon left)"}, {ToShip, "(the mission ended)"}, {NewSosObject, "(new session or mission)"},
        {NoSession, "(new session or mission)"}, {NotHost, "(no longer the host)"}};
    for (int c = 0; c < 6; c++)
    {
        const char* why = "";
        fake_setup();
        SosWorld();
        Squad(1, TANGO, 0);
        w.mode = BLM_MODE_MISSION;
        Sync();
        SosBeacon();
        CHECK(blm_sos_cancel(0, &why) && blm_sos_cancelled());
        cases[c].configure();
        Sync();
        blm_sos_keep(5);
        CHECK(!blm_sos_cancelled());
        CHECK_LOG(cases[c].text);
        CHECK_EQ(Count("sos_deactivate"), 1);
    }
    const char* why = "";
    fake_setup();
    SosWorld();
    SosBeacon();
    SosBeacon();
    CHECK(blm_sos_cancel(0, &why));
    w.sosEnabled = 1;
    Sync();
    blm_sos_keep(1);
    CHECK(blm_sos_cancelled()); /* a beacon gone, one left: still kept */
    SosOn(); /* the game's re-arm */
    blm_sos_keep(2);
    CHECK(blm_sos_cancelled() && Count("sos_deactivate") == 2 && w.sosActive == 0);
}

/* HellForge moved the stratagem list (mods added stratagems): the SOS Beacon's settings are read through the list the
 * game's own reader names now. */
static void SosMovedStratagemList(void)
{
    const char* why = "";
    SosWorld();
    uintptr_t moved = Game(0x4700000u);
    Put64(moved + 8 * B_SOS_STRATAGEM, w.sosSettings);
    Put64(Game(B_STRATAGEMS + 8 * B_SOS_STRATAGEM), 0); /* the vanilla list no longer used */
    Put32(Game(B_LIST_DISPLACEMENT), (uint32_t)(int32_t)(int64_t)(moved - Game(B_LIST_DISPLACEMENT + 4)));
    SosBeacon();
    CHECK(blm_sos_cancel(0, &why));
    CHECK_EQ(SosUses(), 1);
    CHECK_LOG("the stratagem list was moved by HellForge (game.dll +74448896): the SOS Beacon's settings are read there");
    CHECK_LOG("SOS Beacon uses 0 -> 1");
    /* The check of the uses reader leaves the displacement out: a moved list does not disable CANCEL SOS. */
    fake_setup();
    NewWorld(0);
    Put32(Game(B_LIST_DISPLACEMENT), 0x12345678u);
    Started();
    CHECK_LOG("CANCEL SOS ready");
}

/* ==== squad messages (test_chat.lua) ================================================================================ */

#define CTANGO 0x9C8B7A6958473625ull
#define ECHO 0x0A00000100000007ull

static void ChatWorld(void)
{
    NewWorld(1);
    Started();
    const uint64_t peers[3] = {ME, CTANGO, ECHO};
    SetSession(3, peers);
    Sync();
}

static void ChatNewLeader(void)
{
    uint32_t sent = 0;
    const char* why = "";
    ChatWorld();
    fake_counts_reset();
    CHECK(blm_chat_new_leader(CTANGO, &sent, &why) && sent == 2);
    CHECK_EQ(Reads(), 0);
    CHECK(Last("rpc_send")->a == C_NEW_HOST && Last("rpc_send")->b == 0xFFFFFFFFFFFFFFFFull && Last("rpc_send")->c == 1);
    CHECK(g_rpcType == 9 && g_rpcSize == 8 && Last("rpc_send")->d == CTANGO);
    CHECK_EQ(Count("chat_send"), 0);
    CHECK(blm_chat_new_leader(ECHO, &sent, &why) && Last("rpc_send")->d == ECHO);
    w.chatEnabled = 0; /* text chat off does not matter: it is not a chat line */
    Sync();
    CHECK(blm_chat_new_leader(CTANGO, &sent, &why));
    SetSession(1, &w.local);
    Sync();
    CHECK(!blm_chat_new_leader(CTANGO, &sent, &why) && strcmp(why, "nobody else in the session") == 0);
    Put64(Game(BLM_CONTEXT_PTR), 0);
    CHECK(!blm_chat_new_leader(CTANGO, &sent, &why) && strcmp(why, "no network session") == 0);
    CHECK_EQ(Count("rpc_send"), 3);
}

static void ChatSend(void)
{
    static char text[2100];
    uint32_t sent = 0;
    const char* why = "";
    ChatWorld();
    int pages = blm_page_checks();
    fake_counts_reset();
    CHECK(blm_chat_send("Tango is the new host. The squad is moving to their ship.", &sent, &why) && sent == 2);
    CHECK_EQ(Reads(), 1);
    CHECK_EQ(blm_page_checks(), pages);
    CHECK(Last("chat_send")->a == w.ctx + C_CHAT && Last("chat_send")->b == 0);
    CHECK(strcmp(g_lastChat, "Tango is the new host. The squad is moving to their ship.") == 0);
    CHECK(Count("chat_rpc") == 2 && Last("chat_rpc")->a == ECHO);
    CHECK_EQ(Get32(w.ctx + C_CHAT + C_HISTORY_COUNT), 1);
    w.muted = CTANGO; /* a muted peer is the game's business */
    int rpcs = Count("chat_rpc");
    CHECK(blm_chat_send("x", &sent, &why) && sent == 2 && Count("chat_rpc") == rpcs + 1);
    w.muted = 0;
    /* Long text is cut to 512 bytes on a UTF-8 boundary. */
    CHECK_EQ(blm_cut("abc", 5), 3);
    CHECK_EQ(blm_cut("abcdef", 3), 3);
    memset(text, 'x', 510);
    memcpy(text + 510, "\xE2\x82\xAC" "yy", 6);
    CHECK_EQ(blm_cut(text, 512), 510);
    CHECK(blm_chat_send(text, &sent, &why));
    CHECK(strlen(g_lastChat) == 510 && Count("chat_rpc") == rpcs + 3);
    memset(text, 'x', 2000);
    text[2000] = 0;
    CHECK(blm_chat_send(text, &sent, &why));
    CHECK_EQ(strlen(g_lastChat), 512);
}

static void ChatFailures(void)
{
    uint32_t sent = 0;
    const char* why = "";
    ChatWorld();
    w.chatEnabled = 0;
    Sync();
    CHECK(!blm_chat_send("x", &sent, &why) && strcmp(why, "text chat is off") == 0);
    w.chatEnabled = 1;
    SetSession(1, &w.local);
    Sync();
    CHECK(!blm_chat_send("x", &sent, &why) && strcmp(why, "nobody else in the session") == 0);
    const uint64_t peers[2] = {ME, CTANGO};
    SetSession(2, peers);
    Sync();
    Put64(Game(BLM_CONTEXT_PTR), 0);
    CHECK(!blm_chat_send("x", &sent, &why) && strcmp(why, "no network session") == 0);
    Put64(Game(BLM_CONTEXT_PTR), w.ctx);
    fake_hole(w.ctx + C_CHAT, 4);
    CHECK(!blm_chat_send("x", &sent, &why) && strcmp(why, "the chat is unreadable") == 0);
    CHECK_EQ(Count("chat_send"), 0);
}

/* ==== the escape menu (test_menu.lua) =============================================================================== */

static BlmOffer g_offer;
static int g_ran[16];
static int g_ranCount;

static void ShipOffer(const char* promote)
{
    memset(&g_offer, 0, sizeof g_offer);
    g_offer.order[0] = BLM_DISBAND;
    g_offer.order[1] = BLM_PROMOTE;
    g_offer.count = 2;
    g_offer.label[BLM_DISBAND] = blm_intern("DISBAND SQUAD");
    g_offer.title[BLM_DISBAND] = blm_intern("DISBAND SQUAD");
    g_offer.body[BLM_DISBAND] = blm_intern("Kick every other player.");
    g_offer.label[BLM_PROMOTE] = blm_intern(promote);
    g_offer.title[BLM_PROMOTE] = blm_intern("PROMOTE TANGO");
    g_offer.body[BLM_PROMOTE] = blm_intern("Tango hosts; the squad follows.");
}

/* One frame of the menu alone: the open screen's step with g_offer; the actions confirmed are kept in g_ran. */
static uint64_t MenuFrame(void)
{
    uint64_t selected = 0;
    uintptr_t screen = blm_menu_screen();
    if (screen == 0) return 0;
    int action = blm_menu_step(screen, w.local, &g_offer, &selected);
    if (action != 0 && g_ranCount < 16) g_ran[g_ranCount++] = action;
    return selected;
}

static void MenuWorld(void)
{
    NewWorld(0);
    Started();
    g_ranCount = 0;
    ShipOffer("PROMOTE TANGO");
}

/* With the escape menu closed a frame costs two plain loads (one guarded read ever, for the menu system). */
static void MenuClosedCost(void)
{
    MenuWorld();
    fake_counts_reset();
    (void)MenuFrame();
    CHECK_EQ(Reads(), 1);
    fake_counts_reset();
    for (int i = 0; i < 300; i++) (void)MenuFrame();
    CHECK_EQ(Reads(), 0);
    Put64(Game(M_MENU_SYSTEM_PTR), 0);
    CHECK_EQ(blm_menu_screen(), 0);
}

/* An open GAME tab gets our two buttons after the game's two with one page check; labels update once. */
static void MenuAddsButtons(void)
{
    MenuWorld();
    OpenMenu(0);
    int pages = blm_page_checks();
    fake_counts_reset();
    (void)MenuFrame();
    CHECK_EQ(blm_page_checks() - pages, 1);
    CHECK_EQ(Reads(), 3); /* the menu system and the new screen, confirmed once */
    CHECK_EQ(Get8(w.content + M_COUNT), 4);
    CHECK(Get8(w.content + M_TYPES) == 1 && Get8(w.content + M_TYPES + 1) == 3); /* the native buttons kept */
    CHECK(strcmp(OurButtons(), "disband=DISBAND SQUAD promote=PROMOTE TANGO") == 0);
    for (uint32_t i = 2; i < 4; i++)
    {
        CHECK(WidgetAt(Button(i))->parent == w.content + M_BUTTON_LIST); /* attached to the list */
        CHECK(Get32(Button(i)) / 16 % 2 == 1);                          /* enabled */
    }
    CHECK_EQ(WidgetAt(Button(0) + M_BUTTON_TEXT)->label, kNativeLabels[1]); /* native labels untouched */
    CHECK(Count("add_child") == 2 && Count("set_enabled") == 2 && Count("set_string_arg") == 2);
    int calls = g_callCount;
    fake_counts_reset();
    for (int i = 0; i < 120; i++) (void)MenuFrame();
    CHECK_EQ(g_callCount, calls); /* no native calls while nothing changes */
    CHECK_EQ(Reads(), 0);
    ShipOffer("PROMOTE ECHO"); /* another successor: written once */
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "disband=DISBAND SQUAD promote=PROMOTE ECHO") == 0);
    calls = g_callCount;
    (void)MenuFrame();
    CHECK_EQ(g_callCount, calls);
    CHECK_EQ(g_ranCount, 0);
}

/* The dialog is filled once while hidden when our button has the focus; only a confirmed answer runs the action; our
 * text leaves the dialog before a native one. */
static void MenuDialog(void)
{
    MenuWorld();
    OpenMenu(0);
    (void)MenuFrame();
    Focus(4 + 3); /* promote */
    int pages = blm_page_checks();
    (void)MenuFrame();
    CHECK_EQ(Count("dialog_setup"), 1); /* filled while hidden */
    const Call* setup = Last("dialog_setup");
    CHECK(setup->a == w.dialog && setup->b == M_TEXT_TEMPLATE && setup->c == M_TEXT_TEMPLATE && setup->d == M_CONFIRM_LABEL);
    CHECK(g_dialogCancel == M_CANCEL_LABEL && g_dialogHold == 1); /* the game's own labels and hold to confirm */
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "PROMOTE TANGO") == 0);
    CHECK(strcmp(DialogText(M_DIALOG_BODY), "Tango hosts; the squad follows.") == 0);
    CHECK_EQ(Count("measure_text"), 2);
    CHECK_EQ(blm_page_checks(), pages); /* filling the dialog writes nothing */
    (void)MenuFrame();
    (void)MenuFrame();
    CHECK_EQ(Count("dialog_setup"), 1); /* once while the focus stays */
    Select();
    (void)MenuFrame();
    CHECK_EQ(g_ranCount, 0);
    Answer(1);
    (void)MenuFrame();
    CHECK(g_ranCount == 1 && g_ran[0] == BLM_PROMOTE);
    CHECK_LOG("menu: promote confirmed");
    (void)MenuFrame();
    (void)MenuFrame();
    CHECK_EQ(g_ranCount, 1); /* runs once */
    HideDialog();
    (void)MenuFrame();
    Focus(4 + 2); /* disband, cancelled */
    (void)MenuFrame();
    CHECK(Count("dialog_setup") == 2 && strcmp(DialogText(M_DIALOG_TITLE), "DISBAND SQUAD") == 0);
    Select();
    (void)MenuFrame();
    Answer(0);
    (void)MenuFrame();
    CHECK_EQ(g_ranCount, 1);
    CHECK_LOG("menu: disband cancelled");
    HideDialog();
    (void)MenuFrame();
    Focus(4 + 1); /* a native button: our text leaves the dialog */
    (void)MenuFrame();
    CHECK(Count("clear_args") == 2 && WidgetAt(w.dialog + M_DIALOG_TITLE)->text == NULL && WidgetAt(w.dialog + M_DIALOG_BODY)->text == NULL);
    Select();
    (void)MenuFrame();
    Answer(1);
    (void)MenuFrame();
    CHECK_EQ(g_ranCount, 1); /* a native button's dialog never runs our action */
    HideDialog();
    (void)MenuFrame();
    Focus(4 + 3); /* a dialog still showing is never refilled (the setup would queue) */
    Put32(w.dialog + M_DIALOG_STATE, 2);
    int setups = Count("dialog_setup");
    (void)MenuFrame();
    CHECK_EQ(Count("dialog_setup"), setups);
    Put32(w.dialog + M_DIALOG_STATE, 0);
    (void)MenuFrame();
    CHECK(Count("dialog_setup") == setups + 1 && strcmp(DialogText(M_DIALOG_TITLE), "PROMOTE TANGO") == 0);
}

/* With the game's timing (hidden when answered, fading out) the dialog shows the clicked button's text and a confirm
 * runs that button's action. */
static void MenuTiming(void)
{
    MenuWorld();
    OpenMenu(0);
    (void)MenuFrame();
    Focus(4 + 2);
    (void)MenuFrame();
    Select();
    (void)MenuFrame();
    Answer(0);
    (void)MenuFrame(); /* hidden at once, fading out */
    CHECK_EQ(g_ranCount, 0);
    int setups = Count("dialog_setup");
    Focus(4 + 3); /* promote, while the dialog still fades out */
    (void)MenuFrame();
    CHECK_EQ(Count("dialog_setup"), setups); /* no setup while it fades out */
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "PROMOTE TANGO") == 0); /* the text follows at once */
    Select();
    (void)MenuFrame();
    Answer(1);
    (void)MenuFrame();
    CHECK(g_ranCount == 1 && g_ran[0] == BLM_PROMOTE);
    HideDialog();
    (void)MenuFrame();
    CHECK_EQ(Count("dialog_setup"), setups + 1); /* the full setup once the dialog is idle */
    Focus(4 + 3);
    (void)MenuFrame(); /* promote prepared */
    Focus(4 + 2); /* disband, clicked before our update ran */
    Select();
    (void)MenuFrame();
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "DISBAND SQUAD") == 0 && strcmp(DialogText(M_DIALOG_BODY), "Kick every other player.") == 0);
    Answer(1);
    (void)MenuFrame();
    CHECK(g_ranCount == 2 && g_ran[1] == BLM_DISBAND);
    HideDialog(); /* closed another way (no answer): nothing runs */
    (void)MenuFrame();
    Focus(4 + 2);
    (void)MenuFrame();
    Select();
    (void)MenuFrame();
    HideDialog();
    (void)MenuFrame();
    CHECK_EQ(g_ranCount, 2);
}

/* A mission's list (the host's types 2 and 3): a third action, type 7, gets its slot, its dialog and its confirm; an
 * offer without it has the game rebuild the list. */
static void MenuMissionList(void)
{
    MenuWorld();
    NativeTypes(2, 2, 3, 0);
    memset(&g_offer, 0, sizeof g_offer);
    g_offer.order[0] = BLM_CANCEL_SOS;
    g_offer.count = 1;
    g_offer.label[BLM_CANCEL_SOS] = blm_intern("CANCEL SOS");
    g_offer.title[BLM_CANCEL_SOS] = blm_intern("CANCEL SOS");
    g_offer.body[BLM_CANCEL_SOS] = blm_intern("No more players join through your SOS.");
    OpenMenu(0);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "cancel_sos=CANCEL SOS") == 0 && Get8(w.content + M_TYPES + 2) == 7);
    Focus(4 + 2);
    (void)MenuFrame();
    CHECK(strcmp(DialogText(M_DIALOG_TITLE), "CANCEL SOS") == 0);
    Select();
    (void)MenuFrame();
    Answer(1);
    (void)MenuFrame();
    CHECK(g_ranCount == 1 && g_ran[0] == BLM_CANCEL_SOS);
    memset(&g_offer, 0, sizeof g_offer);
    (void)MenuFrame();
    CHECK(Count("rebuild") == 1 && strcmp(OurButtons(), "") == 0 && Get8(w.content + M_COUNT) == 2);
    CHECK_LOG("menu: buttons rebuilt (cancel_sos no longer offered)");
}

/* Our labels use the game's marquee at the button's text width (388 px for a 420 px button). */
static void MenuMarquee(void)
{
    MenuWorld();
    OpenMenu(0);
    (void)MenuFrame();
    for (uint32_t i = 2; i < 4; i++) CHECK(WidgetAt(Button(i) + M_BUTTON_TEXT)->marquee == 388.0f);
    CHECK(WidgetAt(Button(0) + M_BUTTON_TEXT)->marquee == 0.0f); /* native buttons untouched */
    int marquees = Count("set_marquee");
    (void)MenuFrame();
    CHECK_EQ(Count("set_marquee"), marquees); /* once per label */
    fake_setup();
    NewWorld(0);
    for (uint32_t i = 0; i < 5; i++) PutF(Button(i) + M_WIDGET_WIDTH, 0);
    Started();
    ShipOffer("PROMOTE TANGO");
    OpenMenu(0);
    (void)MenuFrame();
    CHECK(WidgetAt(Button(2) + M_BUTTON_TEXT)->marquee == 388.0f); /* unreadable width: the default */
}

/* After the game's rebuild ours come back (as many as fit); an offer that shrinks rebuilds; a full list, a refused write,
 * other tabs and hidden content add nothing; a reopened menu is confirmed again. */
static void MenuRebuilds(void)
{
    MenuWorld();
    OpenMenu(0);
    (void)MenuFrame();
    NativeTypes(3, 0, 1, 2);
    w.nativeTypes[3] = 3;
    w.nativeTypeCount = 4;
    GameRebuild(); /* the host changed: the game rebuilds the list */
    CHECK(strcmp(OurButtons(), "") == 0);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "disband=DISBAND SQUAD") == 0); /* as many as fit, in order */
    NativeTypes(2, 1, 3, 0);
    GameRebuild();
    (void)MenuFrame();
    BlmOffer full = g_offer;
    g_offer.label[BLM_DISBAND] = g_offer.title[BLM_DISBAND] = g_offer.body[BLM_DISBAND] = NULL;
    (void)MenuFrame();
    CHECK(Count("rebuild") == 1 && strcmp(OurButtons(), "") == 0);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "promote=PROMOTE TANGO") == 0);
    g_offer = full;
    for (int i = 0; i < 5; i++) w.nativeTypes[i] = (uint8_t)i;
    w.nativeTypeCount = 5;
    GameRebuild(); /* a full list: nothing added */
    int calls = g_callCount;
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "") == 0 && g_callCount == calls);
    NativeTypes(2, 1, 3, 0);
    GameRebuild();
    ReadOnly(w.content + M_COUNT, 8, 1); /* a refused write: nothing attached, not retried on this screen */
    int attached = Count("add_child"), pages = blm_page_checks();
    for (int i = 0; i < 10; i++) (void)MenuFrame();
    CHECK_EQ(blm_page_checks() - pages, 1);
    CHECK(strcmp(OurButtons(), "") == 0 && Count("add_child") == attached);
    CHECK_LOG("menu: button write refused; retried when the menu opens again");
    ReadOnly(w.content + M_COUNT, 8, 0);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "") == 0);
    CloseMenu();
    (void)MenuFrame();
    OpenMenu(0); /* closed and opened again: retried */
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "") != 0);
    GameRebuild(); /* another tab or hidden content: no sync */
    Put32(w.screen + M_SHOWN, 2);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "") == 0);
    Put32(w.screen + M_SHOWN, 0);
    Put8(w.content + M_HIDDEN, 1);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "") == 0);
    Put8(w.content + M_HIDDEN, 0);
    (void)MenuFrame();
    CHECK(strcmp(OurButtons(), "") != 0);
    /* A new screen object: confirmed with two guarded reads, labels written again. */
    CloseMenu();
    CHECK_EQ(MenuFrame(), 0);
    uintptr_t old = w.screen;
    w.screen = Pages(M_SCREEN_SIZE);
    w.content = w.screen + M_CONTENT;
    w.dialog = w.content + M_DIALOG;
    for (uint32_t i = 0; i < 5; i++)
    {
        Put32(Button(i) + M_BUTTON_TEXT, 7u * 262144u);
        PutF(Button(i) + M_WIDGET_WIDTH, 420);
    }
    OpenMenu(0);
    fake_counts_reset();
    (void)MenuFrame();
    CHECK_EQ(Reads(), 2);
    CHECK(strcmp(OurButtons(), "") != 0 && old != w.screen);
}

/* The squad member whose player menu is open is reported; the host's own card is not. */
static void MenuSelection(void)
{
    MenuWorld();
    OpenMenu(0);
    CHECK_EQ(MenuFrame(), 0);
    OpenPopup(2, TANGO);
    CHECK(MenuFrame() == TANGO);
    OpenPopup(2, 0);
    OpenPopup(0, ME);
    CHECK_EQ(MenuFrame(), 0); /* the host's own card is never a successor */
}

/* game_kick focuses the kicked player's card, opens its player menu and completes the KICK hold, only while the GAME
 * tab takes input; it says why otherwise. */
static void MenuGameKick(void)
{
    int card = -1;
    MenuWorld();
    Squad(1, TANGO, 0);
    CHECK(strcmp(blm_menu_game_kick(0, TANGO, &card), "menu closed") == 0);
    OpenMenu(1);
    CHECK(strcmp(blm_menu_game_kick(blm_menu_screen(), TANGO, &card), "other tab") == 0);
    OpenMenu(0);
    uintptr_t screen = blm_menu_screen();
    Put8(w.content + M_DIALOG_INACTIVE, 0);
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "busy") == 0);
    OpenMenu(0);
    Put8(w.content + M_DIALOG_OPENING, 1);
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "busy") == 0);
    OpenMenu(0);
    PutF(w.content + M_DIALOG_FADE, 0.25f);
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "busy") == 0);
    OpenMenu(0);
    Put32(w.content + M_PANEL_STATE, 1);
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "busy") == 0);
    OpenMenu(0);
    CHECK(strcmp(blm_menu_game_kick(screen, 0x0700000007ull, &card), "no card") == 0);
    Put64(Card(1) + M_CARD_POPUP, 0);
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "no player menu") == 0);
    OpenMenu(0);
    ReadOnly(Card(1) + M_CARD_KICK_HOLD, 4, 1);
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "refused") == 0);
    ReadOnly(Card(1) + M_CARD_KICK_HOLD, 4, 0);
    OpenMenu(0);
    int calls = g_callCount;
    CHECK(strcmp(blm_menu_game_kick(screen, TANGO, &card), "started") == 0 && card == 1);
    CHECK(strcmp(g_calls[calls].name, "focus") == 0 && g_calls[calls].b == 1);
    CHECK(strcmp(g_calls[calls + 1].name, "card_state") == 0 && g_calls[calls + 1].a == Card(1) && g_calls[calls + 1].b == M_POPUP_OPEN);
    CHECK(Get8(w.content + M_FOCUS) == 1 && Get32(Card(1) + M_CARD_STATE) == M_POPUP_OPEN);
    CHECK(GetF(Card(1) + M_CARD_KICK_HOLD) == 100.0f); /* the hold timer past 3 s */
    MenuUpdate(); /* the game's next tab update kicks Tango and resets the card */
    CHECK(Last("game_popup_kick")->a == TANGO && Get64(Card(1) + M_CARD_PEER) == 0);
}

/* close sets the escape menu's pending close with one page check, and the game closes it in its next update. */
static void MenuClose(void)
{
    const char* why = "";
    MenuWorld();
    CHECK(!blm_menu_close(&why) && strcmp(why, "closed") == 0 && Count("escape_closed") == 0);
    OpenMenu(0);
    int pages = blm_page_checks();
    fake_counts_reset();
    CHECK(blm_menu_close(&why));
    CHECK_EQ(Reads(), 2);
    CHECK_EQ(blm_page_checks() - pages, 1);
    CHECK(Get8(w.mainPresenter + M_PENDING_CLOSE) == 1 && blm_menu_screen() != 0); /* open until the game's update */
    MenuUpdate();
    CHECK(Count("escape_closed") == 1 && blm_menu_screen() == 0);
    CHECK(!blm_menu_close(&why) && strcmp(why, "closed") == 0);
    OpenMenu(0);
    ReadOnly(w.mainPresenter + M_PENDING_CLOSE, 4, 1);
    CHECK(!blm_menu_close(&why) && strcmp(why, "refused") == 0);
    ReadOnly(w.mainPresenter + M_PENDING_CLOSE, 4, 0);
    fake_hole(w.presenters + M_MAIN_PRESENTER, 8);
    CHECK(!blm_menu_close(&why) && strcmp(why, "unreadable") == 0);
}

/* ==== the component's stop =========================================================================================== */

/* A fault (or vpm_fail) stops the component: the running action is cancelled, the region flags and the scanner's field
 * go back, and the game's update goes on without it. */
static void StopPutsBack(void)
{
    NewWorld(0);
    Started();
    Frames(1);
    CHECK(vpm_option_apply(Option("region"), 2));
    Squad(1, TANGO, 0);
    OpenMenu(0);
    Frames(1);
    Focus(4 + 3);
    Frames(1);
    CHECK(strcmp(Excluded("NA"), "AF AN AS EU OC SA") == 0 && Get32(FIELD) == 5);
    vpm_core_stop(Self(), "test");
    CHECK(!vpm_running(Self()));
    CHECK(strcmp(Excluded("NA"), "AF AS OC") == 0);
    CHECK_EQ(Get32(FIELD), 20);
    CHECK_LOG("Better Lobby Management stopped for this session; region flags restored");
    fake_counts_reset();
    Frames(10);
    CHECK_EQ(Reads(), 0);

    /* A promote running when it stops: cancelled. */
    fake_setup();
    PromoteSetup();
    Confirm(3, 1);
    CHECK(blm_lobby_busy());
    vpm_core_stop(Self(), "test");
    CHECK(strcmp(blm_lobby_status(), "promote failed: cancelled: error") == 0);

    /* A kept SOS cancel ends with a line. */
    const char* why = "";
    fake_setup();
    SosWorld();
    SosBeacon();
    CHECK(blm_sos_cancel(0, &why));
    vpm_core_stop(Self(), "test");
    CHECK_LOG("CANCEL SOS: no longer kept off; a player leaving lists the SOS again");
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0); /* every line out before a fault */
    RUN(StartsWhenTheCodeIsAsReviewed);
    RUN(RefusesChangedCode);
    RUN(RefusesAnEngineWithoutItsSlots);
    RUN(WaitsForTheEngine);
    RUN(DisablesOnlyThePart);
    RUN(DisabledPartsStayAway);
    RUN(IdleFrames);
    RUN(UnconfirmedMenuSystem);
    RUN(ShipMenuOffersDisbandAndPromote);
    RUN(DisbandFromTheDialog);
    RUN(MissionWithoutSosOffersNothing);
    RUN(CancelSosAlone);
    RUN(CancelSosWithASquad);
    RUN(SquadMessagesGoFirst);
    RUN(MessagesNeverHoldTheKick);
    RUN(PromoteMovesTheSquad);
    RUN(DisbandRefuses);
    RUN(DisbandDeadline);
    RUN(SuccessorChoice);
    RUN(PromoteFindsTheLobby);
    RUN(PromoteRetries);
    RUN(SearchWaitsForTheGame);
    RUN(PromoteFailures);
    RUN(GameKickWaits);
    RUN(RegionKeys);
    RUN(RegionWritesTheRow);
    RUN(RegionOtherContinents);
    RUN(RegionCost);
    RUN(RegionFollowsDownloads);
    RUN(RegionWaits);
    RUN(RegionOption);
    RUN(ScannerFollowsTheGame);
    RUN(ScannerEdges);
    RUN(ScannerStops);
    RUN(ScannerOption);
    RUN(SosTexts);
    RUN(SosOffer);
    RUN(SosVanillaOff);
    RUN(SosCancel);
    RUN(SosRestoresTheUse);
    RUN(SosCalledInAgain);
    RUN(SosGates);
    RUN(SosKeptOff);
    RUN(SosKeepEnds);
    RUN(SosMovedStratagemList);
    RUN(ChatNewLeader);
    RUN(ChatSend);
    RUN(ChatFailures);
    RUN(MenuClosedCost);
    RUN(MenuAddsButtons);
    RUN(MenuDialog);
    RUN(MenuTiming);
    RUN(MenuMissionList);
    RUN(MenuMarquee);
    RUN(MenuRebuilds);
    RUN(MenuSelection);
    RUN(MenuGameKick);
    RUN(MenuClose);
    RUN(StopPutsBack);
    TEST_END();
}
