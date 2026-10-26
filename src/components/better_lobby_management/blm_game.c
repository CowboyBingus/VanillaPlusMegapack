/* Better Lobby Management: the game's layout (game.lua): the code and natives checked once, the engine's lobby and
 * package API slots, the network context confirmed once, the session snapshot (direct loads), the squad's names and the
 * game's own searches. */
#include <stdio.h>
#include "blm.h"
#include "blm_code.h"

#define ROSTER_RECORD 0xC0u
#define ROSTER_SLOTS 4u
#define NAME_AT 8u
#define NAME_LIMIT 0x78u

VpmComponent* blm_component;
BlmNatives blm_native;
static int g_pageChecks;
static char g_why[128];

int blm_writable(uintptr_t address, size_t size)
{
    g_pageChecks++;
    return vpm_writable(address, size);
}

int blm_page_checks(void) { return g_pageChecks; }

void blm_game_reset(void)
{
    g_pageChecks = 0;
    memset(&blm_native, 0, sizeof blm_native);
    g_why[0] = 0;
}

const char* blm_changed(const char* name)
{
    snprintf(g_why, sizeof g_why, "%s changed", name);
    return g_why;
}

int blm_game_code_ok(const BlmCode* table, int count, const char** why)
{
    for (int i = 0; i < count; i++)
        if (!vpm_game_code_matches(table[i].rva, table[i].pattern)) { *why = blm_changed(table[i].name); return 0; }
    return 1;
}

int blm_code_at(uintptr_t address, const char* pattern)
{
    return address != 0 && vpm_hf()->code_matches(address, pattern);
}

uintptr_t blm_code_address(const BlmCode* table, int count, const char* name)
{
    for (int i = 0; i < count; i++)
        if (strcmp(table[i].name, name) == 0) return vpm_game() + table[i].rva;
    return 0;
}

/* ---- the code checks, as the core's wait takes them ---------------------------------------------------------- */

#define MAX_GAME_PINS 32
#define SLOTS 4
static VpmCodePin g_gamePins[MAX_GAME_PINS];
static VpmCodePin g_slotPins[SLOTS];
static char g_slotNames[SLOTS][48];
static uintptr_t g_targets[SLOTS]; /* the slots' functions: clear_filters, continent, unload_paused, pause_unloads */
static uintptr_t g_lobbyApi;

static int AddPins(int at, const BlmCode* table, int count, uint32_t flags)
{
    for (int i = 0; i < count && at < MAX_GAME_PINS; i++)
        g_gamePins[at++] = (VpmCodePin){table[i].rva, table[i].pattern, table[i].name, flags};
    return at;
}

int blm_game_pins(const VpmCodePin** pins)
{
    int n = AddPins(0, blm_game_code, blm_game_code_count, 0);
    n = AddPins(n, blm_exe_code, blm_exe_code_count, VPM_PIN_EXE);
    n = AddPins(n, blm_game_natives, blm_game_natives_count, 0);
    *pins = g_gamePins;
    return n;
}

int blm_engine_ready(void) { return blm_global(BLM_ENGINE_API_PTR) != 0; }

/* A slot's function as a pin of the core's wait, when it lies in the exe's or game.dll's image (1); else checked at
 * once, as the Lua's check (1 matched, 0 not). */
static int SlotPin(int* pins, uintptr_t target, const BlmCode* slot)
{
    snprintf(g_slotNames[*pins], sizeof g_slotNames[0], "engine %s", slot->name);
    uint32_t flags = VPM_PIN_EXE;
    uintptr_t base = vpm_exe();
    size_t size = vpm_exe_size();
    if (target < base || target - base >= size) { flags = 0; base = vpm_game(); size = vpm_game_size(); }
    if (target == 0 || target < base || target - base >= size) return blm_code_at(target, slot->pattern);
    g_slotPins[*pins] = (VpmCodePin){(uint32_t)(target - base), slot->pattern, g_slotNames[*pins], flags};
    (*pins)++;
    return 1;
}

/* Each slot's function through the pointer the API table holds (targets[i] its address), as pins. NULL, or why not. */
static const char* SlotsOk(uintptr_t api, const BlmCode* slots, int count, uintptr_t* targets, int* pins)
{
    for (int i = 0; i < count; i++)
    {
        targets[i] = vpm_ptr(api + slots[i].rva);
        if (targets[i] == 0 || !SlotPin(pins, targets[i], &slots[i]))
        {
            char name[64];
            snprintf(name, sizeof name, "engine %s", slots[i].name);
            return blm_changed(name);
        }
    }
    return NULL;
}

static void BindGameNatives(void)
{
    const BlmCode* t = blm_game_natives;
    int n = blm_game_natives_count;
    blm_native.start_join = (BlmStartJoin)blm_code_address(t, n, "start_join");
    blm_native.filter_string = (BlmFilterString)blm_code_address(t, n, "filter_string");
    blm_native.browser_start = (BlmBrowserStart)blm_code_address(t, n, "browser_start");
    blm_native.browser_busy = (BlmBrowserBusy)blm_code_address(t, n, "browser_busy");
    blm_native.browser_count = (BlmBrowserCount)blm_code_address(t, n, "browser_count");
    blm_native.browser_result = (BlmBrowserResult)blm_code_address(t, n, "browser_result");
    blm_native.is_friend = (BlmIsFriend)blm_code_address(t, n, "is_friend");
}

const char* blm_engine_resolve(const VpmCodePin** pins, int* count)
{
    uintptr_t tables = (uintptr_t)blm_global(BLM_ENGINE_API_PTR);
    const char* why = NULL;
    *count = 0;
    *pins = g_slotPins;
    if (tables == 0) return "engine API unavailable";
    g_lobbyApi = vpm_ptr(tables + BLM_LOBBY_API);
    if (g_lobbyApi == 0) return "engine lobby API unavailable";
    if ((why = SlotsOk(g_lobbyApi, blm_engine_slots, blm_engine_slots_count, g_targets, count)) != NULL) return why;
    uintptr_t packageApi = vpm_ptr(tables + BLM_PACKAGE_API);
    if (packageApi == 0) return "engine package API unavailable";
    return SlotsOk(packageApi, blm_package_slots, blm_package_slots_count, g_targets + blm_engine_slots_count, count);
}

void blm_engine_bind(void)
{
    BindGameNatives();
    blm_native.clear_filters = (BlmHandleCall)g_targets[0];
    blm_native.continent = (BlmSelfCall)g_targets[1];
    blm_native.lobby_api = g_lobbyApi;
}

/* ---- the session ------------------------------------------------------------------------------------------------- */

uintptr_t blm_context(BlmContextCache* cache)
{
    uintptr_t ctx = (uintptr_t)blm_global(BLM_CONTEXT_PTR);
    if (ctx == 0) { cache->ctx = 0; return 0; }
    if (ctx != cache->ctx)
    {
        uintptr_t state = (uintptr_t)blm_global(BLM_GAME_STATE_PTR);
        uint32_t value;
        if (ctx % 8 != 0 || !vpm_read_u32(ctx + BLM_PEER_COUNT, &value) || state == 0 || !vpm_read_u32(state + BLM_MODE, &value))
        {
            cache->ctx = 0;
            return 0;
        }
        cache->ctx = ctx;
    }
    return ctx;
}

void blm_read_session(uintptr_t ctx, BlmSession* s)
{
    s->ctx = ctx;
    s->local = blm_load64(ctx + BLM_LOCAL);
    s->host = blm_load64(ctx + BLM_HOST);
    s->is_host = s->host == s->local;
    uint32_t count = blm_load32(ctx + BLM_PEER_COUNT);
    s->peer_count = count > BLM_MAX_PEERS ? BLM_MAX_PEERS : count;
    for (uint32_t i = 0; i < s->peer_count; i++)
    {
        uintptr_t entry = ctx + BLM_PEERS + i * BLM_PEER_STRIDE;
        s->peers[i].id = blm_load64(entry);
        s->peers[i].index = blm_load32(entry + BLM_PEER_INDEX);
    }
    uintptr_t state = (uintptr_t)blm_global(BLM_GAME_STATE_PTR);
    s->mode = state != 0 ? blm_load32(state + BLM_MODE) : 0;
    s->hosting = blm_load32(ctx + BLM_HOST_SYNC + BLM_HS_STATE);
    s->transition = blm_load32(ctx + BLM_HOST_SYNC + BLM_HS_TRANSITION);
    s->join_state = blm_load32(ctx + BLM_JOIN);
    s->party_join = blm_load8(ctx + BLM_CLIENT_SYNC + BLM_CS_PARTY_JOIN);
}

int blm_has_peer(const BlmSession* s, uint64_t peer)
{
    for (uint32_t i = 0; i < s->peer_count; i++)
        if (s->peers[i].id == peer) return 1;
    return 0;
}

/* A C string of at most limit bytes at address, with direct loads (api.cstring). */
static void CString(uintptr_t address, char* out, size_t limit)
{
    size_t n = 0;
    while (n < limit && blm_load8(address + n) != 0)
    {
        out[n] = (char)blm_load8(address + n);
        n++;
    }
    out[n] = 0;
}

void blm_names(BlmNames* out)
{
    out->count = 0;
    uintptr_t roster = (uintptr_t)blm_global(BLM_ROSTER_PTR);
    uint32_t first;
    if (roster == 0 || !vpm_read_u32(roster, &first)) return;
    for (uint32_t slot = 0; slot < ROSTER_SLOTS; slot++)
    {
        uintptr_t record = roster + slot * ROSTER_RECORD;
        uint64_t id = blm_load64(record);
        if (id == 0) continue;
        out->id[out->count] = id;
        CString(record + NAME_AT, out->name[out->count], NAME_LIMIT);
        out->count++;
    }
}

/* The name of peer, or NULL. A later roster slot with the same id wins, as the Lua's table did. */
const char* blm_name_of(const BlmNames* names, uint64_t peer)
{
    for (int i = names->count - 1; i >= 0; i--)
        if (names->id[i] == peer) return names->name[i];
    return NULL;
}

/* While any game matchmaking request searches (an unreadable one counts as searching): guarded reads. */
int blm_game_searching(void)
{
    static const uint32_t requests[2] = {BLM_REQUEST_QUICKPLAY, BLM_REQUEST_SCANNER};
    uintptr_t matchmaking = (uintptr_t)blm_global(BLM_MATCHMAKING_PTR);
    if (matchmaking == 0) return 0;
    for (int i = 0; i < 2; i++)
    {
        uint32_t state;
        if (!vpm_read_u32(matchmaking + requests[i] + 4, &state) || state == BLM_REQUEST_SEARCHING) return 1;
    }
    return 0;
}
