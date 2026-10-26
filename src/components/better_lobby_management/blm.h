/* Better Lobby Management's shared layer (game.lua in the Lua): the game's layout on build 25480438, the session
 * snapshot, the natives, the texts, and each part's interface (better_lobby_management.c lists the parts).
 *
 * Direct loads. The Lua read the network context, the escape screen, the SOS object and the other game objects with
 * direct loads (api.load*) once one guarded read (api.read*, ReadProcessMemory) had confirmed the object. Here those are
 * plain loads (blm_load*) under the core's crash guard, which stops the component on a fault instead of the game: the
 * same calls per frame (no Windows call), the same confirmations (vpm_read). Guarded reads stay vpm_read. */
#ifndef BLM_H
#define BLM_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "../../core/vpm.h"
#include "blm_code.h"

/* The component (set by start(): every part logs through it). */
extern VpmComponent* blm_component;

/* ---- game.dll globals and the network context (game.lua) ------------------------------------------------------- */

#define BLM_CONTEXT_PTR 0x347CEF0u     /* network context: synchronizers, lobby, peers */
#define BLM_GAME_STATE_PTR 0x3326340u  /* +MODE: 3 ship, 4 mission */
#define BLM_ROSTER_PTR 0x347CED8u      /* 4 x 0xC0: peer id +0, persona name +8 */
#define BLM_ENGINE_API_PTR 0x3326308u  /* engine API tables; +0xF8 PlayFab lobby/browser */
#define BLM_MATCHMAKING_PTR 0x347CE80u /* matchmaking object (Galactic Map scanner, quickplay) */
#define BLM_MODE 0xAC21Cu
#define BLM_MODE_SHIP 3u
#define BLM_MODE_MISSION 4u

#define BLM_LOCAL 0xB398u
#define BLM_HOST 0xB3A8u
#define BLM_HOST_SYNC 0x159B0u         /* +24 hosting state (1 hosting), +28 transition step */
#define BLM_HS_STATE 24u
#define BLM_HS_TRANSITION 28u
#define BLM_CLIENT_SYNC 0x162C8u       /* +0x521 party join in progress (byte) */
#define BLM_CS_PARTY_JOIN 0x521u
#define BLM_JOIN 0x171C8u              /* join component; +0 state (0 idle) */
#define BLM_LOBBY 0x1D470u             /* game lobby wrapper; +0 engine lobby */
#define BLM_BROWSER 0x1F028u           /* engine lobby browser handle, shared by every game search */
#define BLM_PEER_COUNT 0x16390u
#define BLM_PEERS 0x16398u
#define BLM_PEER_STRIDE 32u
#define BLM_PEER_INDEX 20u
#define BLM_MAX_PEERS 4u
#define BLM_LOBBY_API 0xF8u
#define BLM_PACKAGE_API 0x10u
#define BLM_REQUEST_QUICKPLAY 0x688u   /* matchmaking requests the mod must not overlap (state at +4; 1 searching) */
#define BLM_REQUEST_SCANNER 0x56E0u
#define BLM_REQUEST_SEARCHING 1u
#define BLM_JOIN_PARTY 2
#define BLM_JOIN_REASON_QUICKPLAY 5
#define BLM_KEY_HOST_PEER 3            /* logical lobby key 3 -> string_key2: the host's peer id in decimal */
#define BLM_OP_EQUAL 2u
#define BLM_NAME_SIZE 0x79u            /* a persona name: at most 0x78 bytes, then the terminator */

/* ---- direct loads ------------------------------------------------------------------------------------------------ */

static inline uint8_t blm_load8(uintptr_t at) { uint8_t v; memcpy(&v, (const void*)at, 1); return v; }
static inline uint32_t blm_load32(uintptr_t at) { uint32_t v; memcpy(&v, (const void*)at, 4); return v; }
static inline uint64_t blm_load64(uintptr_t at) { uint64_t v; memcpy(&v, (const void*)at, 8); return v; }
static inline float blm_loadf(uintptr_t at) { float v; memcpy(&v, (const void*)at, 4); return v; }
/* game.dll's image (always mapped) */
static inline uint64_t blm_global(uint32_t rva) { return vpm_game_u64(rva); }

/* vpm_writable (one VirtualQuery per region), counted: the Lua's api.queries. */
int blm_writable(uintptr_t address, size_t size);
int blm_page_checks(void);

/* ---- the session snapshot (game.lua read_session) --------------------------------------------------------------- */

typedef struct BlmPeer { uint64_t id; uint32_t index; } BlmPeer;

typedef struct BlmSession
{
    uintptr_t ctx;
    uint64_t local, host;   /* peer ids (lo | hi << 32) */
    int is_host;
    uint32_t peer_count;    /* clamped to BLM_MAX_PEERS */
    BlmPeer peers[BLM_MAX_PEERS];
    uint32_t mode, hosting, transition, join_state;
    uint8_t party_join;
} BlmSession;

/* A context confirmed once with guarded reads (game.lua context's cache). */
typedef struct BlmContextCache { uintptr_t ctx; } BlmContextCache;

/* Persona names by peer id (game.lua names), read on action frames only. */
typedef struct BlmNames { int count; uint64_t id[4]; char name[4][BLM_NAME_SIZE]; } BlmNames;

/* ---- the natives (windows_api.lua's Lm* types) ------------------------------------------------------------------ */

typedef uint8_t (*BlmStartJoin)(uint64_t join, uint64_t info, int32_t type, uint64_t unused, int32_t reason);
typedef void (*BlmFilterString)(uint64_t field, int32_t key, uint64_t value, uint32_t op);
typedef uint64_t (*BlmBrowserStart)(uint64_t field);
typedef uint8_t (*BlmBrowserBusy)(uint64_t field);
typedef int32_t (*BlmBrowserCount)(uint64_t field);
typedef uint64_t (*BlmBrowserResult)(uint64_t field, uint64_t out, uint32_t index);
typedef uint8_t (*BlmIsFriend)(uint64_t unused, uint64_t peer);
typedef void (*BlmHandleCall)(uint64_t handle);
typedef uint64_t (*BlmSelfCall)(uint64_t self);

/* The lobby natives the release calls. kick_peer, send_kick and the package unload pause are checked too (the Lua's
 * startup refused without them) but only its test builds called them. */
typedef struct BlmNatives
{
    BlmStartJoin start_join;
    BlmFilterString filter_string;
    BlmBrowserStart browser_start;
    BlmBrowserBusy browser_busy;
    BlmBrowserCount browser_count;
    BlmBrowserResult browser_result;
    BlmIsFriend is_friend;
    BlmHandleCall clear_filters;
    BlmSelfCall continent;
    uintptr_t lobby_api;
} BlmNatives;
extern BlmNatives blm_native;

/* ---- blm_game.c ---------------------------------------------------------------------------------------------------- */

void blm_game_reset(void);
/* "<name> changed" in a buffer the next call reuses: callers keep their own copy. */
const char* blm_changed(const char* name);
/* Every record's bytes at game.dll + rva: 1, or 0 with *why naming the first that differs. */
int blm_game_code_ok(const BlmCode* table, int count, const char** why);
/* game.dll + the rva of the record named name, or 0. */
uintptr_t blm_code_address(const BlmCode* table, int count, const char* name);
/* G.CODE, G.EXE_CODE, G.NATIVES as the core's wait for decoded code checks them (vpm_when_code_ready: the refusal
 * reads "host-left check changed (game.dll 0x10834ED)"), in the Lua's order; their count. */
int blm_game_pins(const VpmCodePin** pins);
/* The engine API tables exist (one plain load). */
int blm_engine_ready(void);
/* The engine lobby and package API slots resolved through the tables (6 reads), in the Lua's order: NULL with *pins the
 * slots' functions for the core's wait (a target outside the game's and the exe's images is checked at once, as the
 * Lua's check did), or the refusal ("engine lobby API unavailable", "engine continent changed"). */
const char* blm_engine_resolve(const VpmCodePin** pins, int* count);
/* Once the slots' functions read as shipped: they and the game's natives bound into blm_native. */
void blm_engine_bind(void);
/* A pattern's bytes at an address any module holds (exe code, an engine slot's target). */
int blm_code_at(uintptr_t address, const char* pattern);

uintptr_t blm_context(BlmContextCache* cache);
void blm_read_session(uintptr_t ctx, BlmSession* s);
int blm_has_peer(const BlmSession* s, uint64_t peer);
void blm_names(BlmNames* out);
const char* blm_name_of(const BlmNames* names, uint64_t peer);
int blm_game_searching(void);

/* ---- blm_text.c ---------------------------------------------------------------------------------------------------- */

void blm_text_reset(void);
/* A text's English (vpm_text). */
const char* blm_tr(const char* key, const char* english);
/* A copy that stays for the session: the game's widgets keep pointers to the texts they show. */
const char* blm_intern(const char* text);
/* {name} (any one placeholder) replaced by value. */
void blm_format(char* out, size_t size, const char* template_text, const char* placeholder, const char* value);

/* ---- blm_chat.c ---------------------------------------------------------------------------------------------------- */

void blm_chat_reset(void);
int blm_chat_verify(const char** why);
/* 1 with *sent the other players in the session, or 0 with *why. */
int blm_chat_send(const char* text, uint32_t* sent, const char** why);
int blm_chat_new_leader(uint64_t peer, uint32_t* sent, const char** why);

/* ---- blm_menu.c ---------------------------------------------------------------------------------------------------- */

#define BLM_DISBAND 1
#define BLM_PROMOTE 2
#define BLM_CANCEL_SOS 3
#define BLM_ACTIONS 3

/* What the escape menu offers: by action, its label, its dialog's title and body (interned texts; NULL: not offered),
 * and the order to add them in. */
typedef struct BlmOffer
{
    const char* label[BLM_ACTIONS + 1];
    const char* title[BLM_ACTIONS + 1];
    const char* body[BLM_ACTIONS + 1];
    int order[BLM_ACTIONS];
    int count;
} BlmOffer;

void blm_menu_reset(void);
int blm_menu_verify(const char** why);
uintptr_t blm_menu_screen(void);
int blm_menu_closed(void);
/* One frame on an open escape screen: *selected the squad member whose player menu is open (0 none); returns the
 * action whose dialog was confirmed this frame (0 none). */
int blm_menu_step(uintptr_t screen, uint64_t local, const BlmOffer* offer, uint64_t* selected);
const char* blm_menu_game_kick(uintptr_t screen, uint64_t peer, int* card);
int blm_menu_close(const char** why);
/* Detailed mode: the open screen's dialog and focus state, a line when it changed (menu.lua trace). */
void blm_menu_trace(uintptr_t screen);

/* ---- blm_lobby.c --------------------------------------------------------------------------------------------------- */

void blm_lobby_reset_state(void);
/* Squad messages (the option) and the escape menu's KICK and close (the menu integration): what the actions use. */
void blm_lobby_use(int messages, int menu);
int blm_lobby_snapshot(BlmSession* out);
int blm_choose_successor(const BlmSession* snap, const uint64_t* target, BlmPeer* out, int* friend, const char** why);
int blm_lobby_disband(double now, const char** why);
int blm_lobby_promote(const uint64_t* target, double now, const char** why);
int blm_lobby_step(double now);
int blm_lobby_busy(void);
int blm_lobby_ui_pending(void);
void blm_lobby_ui_step(double now);
int blm_lobby_arrival_pending(void);
void blm_lobby_check_arrival(double now);
int blm_lobby_cancel(const char* reason);
int blm_lobby_reset(const char* reason);
const char* blm_lobby_status(void);
int blm_lobby_actions(void);

/* ---- blm_sos.c ----------------------------------------------------------------------------------------------------- */

void blm_sos_reset(void);
int blm_sos_verify(const char** why);
int blm_sos_active(void);
/* 1 with *privacy (the host's privacy setting) when CANCEL SOS can be offered. */
int blm_sos_offer(const BlmSession* snap, uint32_t* privacy);
int blm_sos_cancel(double now, const char** why);
int blm_sos_cancelled(void);
void blm_sos_keep(double now);
void blm_sos_body(uint32_t privacy, char* out, size_t size);
void blm_sos_counts(int* cancels, int* rearms, int* leaks);

/* ---- blm_region.c -------------------------------------------------------------------------------------------------- */

void blm_region_reset(void);
int blm_region_verify(const char** why);
int blm_region_set_mode(int mode);
void blm_region_step(void);
int blm_region_restore(void);
const char* blm_region_status(void);
uint32_t blm_region_combine(const uint32_t* words, int count);

/* ---- blm_scanner.c ------------------------------------------------------------------------------------------------- */

#define BLM_SCANNER_MIN 5
#define BLM_SCANNER_MAX 20
#define BLM_SCANNER_DEFAULT 5

void blm_scanner_reset(void);
int blm_scanner_verify(const char** why);
int blm_scanner_check(void);
int blm_scanner_set_setting(double value);
int blm_scanner_stop(const char* reason);
uint32_t blm_scanner_revision(void);
void blm_scanner_summary(char* out, size_t size);
const char* blm_scanner_state(void);

#endif
