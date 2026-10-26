/* Match Your Colors: the squad (sync.lua, remote.lua, lineup.lua, cloak.lua) and the weapons target (loadout.lua): each
 * player's color settings as a PlayFab lobby member property, other mod users' Helldivers recolored here, the squad
 * cards of the loadout screen, Hide Cape, and Recolor Weapons for a Helldiver. Game thread. */
#ifndef MYC_SQUAD_H
#define MYC_SQUAD_H

#include "myc_weapon_mem.h"

/* ---- settings ----------------------------------------------------------------------------------------------------- */

/* A player's color settings (the options a sync value carries; source_kit / source_cape: Squadmates' Colors on Your
 * Colors, this player's source item). */
typedef struct MycSettings
{
    int mode, scheme, keep_sets, recolor_hoods, match_materials, recolor_cape, recolor_weapons, cape_hidden;
    uint32_t source_kit, source_cape;
} MycSettings;
int myc_settings_same(const MycSettings* a, const MycSettings* b);

/* ---- sync (sync.lua) ---------------------------------------------------------------------------------------------- */

#define MYC_SYNC_KEY "cbmyc"
#define MYC_SYNC_KEY2 "cbmyc2"
#define MYC_SYNC_TEXT_MAX 127
#define MYC_SYNC_POLL_FRAMES 120
#define MYC_SYNC_POST_DELAY_FRAMES 300
#define MYC_SYNC_RETRY_FRAMES 1800
#define MYC_SYNC_STEADY_FRAMES 600
#define MYC_SYNC_MAX_MEMBERS 16

void myc_sync_encode(const MycSettings* o, char* out, size_t size);
void myc_sync_legacy(const MycSettings* o, char* out, size_t size);
/* The options a value of either key carries: 1, or 0 (unknown level or mode, malformed). */
int myc_sync_decode(const char* text, MycSettings* out);
int myc_sync_peer_of(const char* id, uint32_t* low, uint32_t* high);

typedef struct MycEntityKey { const char* id; const char* type; } MycEntityKey;
typedef struct MycMemberUpdate { uint32_t count; const char* const* keys; const char* const* values; } MycMemberUpdate;
typedef int32_t (*MycPostUpdate)(uint64_t lobby, const MycEntityKey* user, const void* lobby_update,
    const MycMemberUpdate* member_update, void* context);
typedef int32_t (*MycGetMembers)(uint64_t lobby, uint32_t* count, const MycEntityKey** members);
typedef int32_t (*MycGetMemberProperty)(uint64_t lobby, const MycEntityKey* member, const char* key, const char** value);

/* A lobby member's value (a poll's). */
typedef struct MycMember
{
    uint32_t peer_low, peer_high;
    char text[MYC_SYNC_TEXT_MAX + 1];
    int has_text, is_local, failed;
} MycMember;

typedef struct MycSync
{
    void (*note)(const char* line);
    int natives_tried, natives_ok;
    MycPostUpdate post;
    MycGetMembers members;
    MycGetMemberProperty property;
    /* the lobby */
    uint32_t low, high, since;
    int has_lobby, has_since, joined, has_id;
    char id[MYC_SYNC_TEXT_MAX + 1];
    uintptr_t own;                  /* PlayFab's own key of the local member (this poll's) */
    /* posting */
    int has_posted, posted_text_set;
    uint32_t posted_low, posted_high;
    char posted_text[MYC_SYNC_TEXT_MAX + 1];
    int pending_set;
    char pending[MYC_SYNC_TEXT_MAX + 1];
    uint32_t changed_at, next_post;
    int posts, failures;
    MycMember list[MYC_SYNC_MAX_MEMBERS];
    int nlist;
} MycSync;
void myc_sync_init(MycSync* s, void (*note)(const char* line));
/* The lobby poll: text posted when due (NULL: sharing off); the members' values (count), or -1 outside a joined lobby and
 * while sharing is off. include_local: the local member too (loopback). */
int myc_sync_poll(MycSync* s, uint32_t frame, const char* text, int include_local);

/* ---- Recolor Weapons for one Helldiver (loadout.lua) --------------------------------------------------------------- */

#define MYC_ROW_FRAMES 4
#define MYC_ROW_PHASE 2
#define MYC_WEAPONS_SIG 8192

typedef struct MycLoadout
{
    MycController controller, shown;
    const MycNative* native;
    void (*note)(const char* line);
    char follow[64];                /* another mod user's ('Sync: <peer>'), or "" */
    int has_where, has_watch, has_resolved, has_entry, has_sig, has_preview, preview_dirty, has_applied;
    MycInventoryWhere where;
    MycInventoryWatch watch;
    MycResolved resolved;
    int dirty, changed, reload, rebinds, reloads, jobs, previews, moves;
    uint64_t entry, texture;
    char sig[MYC_WEAPONS_SIG], pending_sig[MYC_WEAPONS_SIG];
    int has_pending_sig;
    MycWeapon preview;
    char preview_key[256], preview_applied[256];
    uint8_t copy[MYC_COPY_SPAN];
} MycLoadout;
void myc_loadout_init(MycLoadout* l, const MycNative* native, MycPool* pool, void (*note)(const char* line), const char* follow);
void myc_loadout_free(MycLoadout* l);
void myc_loadout_adopt(MycLoadout* l, uint32_t avatar);
void myc_loadout_clear(MycLoadout* l, uint32_t frame);
void myc_loadout_replan(MycLoadout* l);
/* Every frame while on (busy: a chain check ran this frame; every: the row read whatever the frame). 1 when it resolved. */
int myc_loadout_step(MycLoadout* l, uint32_t frame, int busy, int every);
/* The weapons' job request (weapons and sig) into r; 0 when none is due. */
int myc_loadout_request(MycLoadout* l, MycRequest* r);
/* A finished weapons job: bindings made, or -1 when the weapons changed meanwhile (planned again). */
int myc_loadout_finish(MycLoadout* l, MycResult* result, const MycRequest* request, uint32_t frame);
void myc_loadout_check(MycLoadout* l, uint32_t frame);
void myc_loadout_collect(MycLoadout* l, uint32_t frame);
void myc_loadout_preview_changed(MycLoadout* l, uint32_t frame);
int myc_loadout_preview_request(MycLoadout* l, MycRequest* r);
int myc_loadout_finish_preview(MycLoadout* l, MycResult* result, const MycRequest* request, uint32_t frame);
void myc_loadout_signature(const MycResolved* resolved, char* out, size_t size);

/* ---- Hide Cape (cloak.lua) ---------------------------------------------------------------------------------------- */

#define MYC_CLOAK_GRACE_FRAMES 60
#define MYC_CLOAK_POD_FRAMES 20000
#define MYC_CLOAK_NOTES 8
#define MYC_CLOAK_TARGETS 16
#define MYC_CLOAK_CAPES 8

typedef struct MycCloakTarget
{
    char key[32];                   /* "local", or "player <entity id>" */
    int other, ncapes, pod, has_unit;
    uint32_t cape_units[MYC_CLOAK_CAPES];
    uint64_t cape_meshes[MYC_CLOAK_CAPES];
    uint32_t hidden_at, young_until, unit;
    uint64_t helmet_mesh;
    uintptr_t units_at;
} MycCloakTarget;

typedef struct MycCloak
{
    const MycNative* native;
    void (*note)(const char* line);
    MycCloakTarget targets[MYC_CLOAK_TARGETS];  /* in the order added */
    int ntargets, cursor, turn, hidden, shown, reshown;
    uint32_t young_until;
    char decoded[32][MYC_SYNC_TEXT_MAX + 1];
    int decoded_hides[32], ndecoded;
} MycCloak;
void myc_cloak_init(MycCloak* c, const MycNative* native, void (*note)(const char* line));
/* Target key now wears the cape refs of its 30 unit refs (refs[10 * array + 1]); new ones hidden. */
void myc_cloak_wear(MycCloak* c, const char* key, const uint32_t* refs, int other, uint32_t frame);
void myc_cloak_drop(MycCloak* c, const char* key, int show);
void myc_cloak_clear(MycCloak* c);
void myc_cloak_check(MycCloak* c, uint32_t frame);
int myc_cloak_young(MycCloak* c, uint32_t frame);
void myc_cloak_step(MycCloak* c, uint32_t frame);
int myc_cloak_others(const MycCloak* c);
int myc_cloak_needed(MycCloak* c, const MycMember* members, int n, int everyone);
void myc_cloak_update(MycCloak* c, const MycMember* members, int n, int everyone, uint32_t frame);

/* ---- other mod users' Helldivers (remote.lua) ---------------------------------------------------------------------- */

#define MYC_REMOTE_FAILURE_LIMIT 3
#define MYC_REMOTE_WATCH_FRAMES 4
#define MYC_REMOTE_ENTRIES 16
#define MYC_PEER_KEY 40

/* Whether a result was made of the kit records as they read now (the addon's records_same). */
typedef int (*MycRecordsSame)(void* ctx, const MycResult* result, uint32_t helmet, uint32_t armor, uint32_t cape, int has_cape);

typedef struct MycRemoteEntry
{
    char key[MYC_PEER_KEY];
    int failures, dirty, absent, mine, has_settings, has_identity, has_applied, found, has_weapons_reason;
    MycSettings settings;
    MycPlayer player;
    MycIdentity identity;
    MycWatch watch;
    MycController* controller;
    MycRequest applied;
    MycLoadout* loadout;
    char weapons_reason[64];
} MycRemoteEntry;

typedef struct MycWanted { char key[MYC_PEER_KEY]; MycSettings settings; int is_mine; } MycWanted;
typedef struct MycRetiring { void* block; MycController* a; MycController* b; } MycRetiring;

typedef struct MycRemote
{
    const MycNative* native;
    MycPool* pool;
    void (*note)(const char* line);
    MycRecordsSame records_same;
    void* records_ctx;
    int weapons;                    /* Recolor Weapons can follow their settings */
    void (*session_text)(char* out, size_t size);
    MycRemoteEntry* entries[MYC_REMOTE_ENTRIES];
    int nentries, cursor, served, jobs, rebinds, pending;
    uint32_t frame;
    MycRetiring retiring[64];
    int nretiring;
    MycWanted wanted[MYC_SYNC_MAX_MEMBERS];
    int nwanted;
    int has_unknown, has_mine;
    MycSettings unknown, mine;
    char local_key[MYC_PEER_KEY];
    char unmatched[MYC_SYNC_MAX_MEMBERS][MYC_PEER_KEY];
    int nunmatched;
    char missing[MYC_SYNC_MAX_MEMBERS][MYC_PEER_KEY];
    int missing_count[MYC_SYNC_MAX_MEMBERS], nmissing;
} MycRemote;
void myc_remote_init(MycRemote* r, const MycNative* native, MycPool* pool, void (*note)(const char* line),
    MycRecordsSame records_same, void* ctx, int weapons);
void myc_remote_free(MycRemote* r);
/* A job request for target with settings s on kits (request_of). */
void myc_remote_request_of(int target, const char* key, const MycSettings* s, uint32_t helmet, uint32_t armor, uint32_t body,
    uint32_t cape, MycRequest* out);
/* From a sync poll (members, or n < 0: none); mine: this player's settings for squadmates, or NULL. */
void myc_remote_update(MycRemote* r, uint32_t frame, const MycMember* members, int n, const MycSettings* mine, int everyone);
int myc_remote_request(MycRemote* r, MycRequest* out);
void myc_remote_finish(MycRemote* r, int ok, MycResult* result, const MycRequest* request, const char* why, uint32_t frame);
void myc_remote_step(MycRemote* r, uint32_t frame);
void myc_remote_check(MycRemote* r);
void myc_remote_clear(MycRemote* r, uint32_t frame);
/* The settings the last poll gave member key, or NULL (is_mine: they are this player's). */
const MycSettings* myc_remote_wanted(const MycRemote* r, const char* key, int* is_mine);

/* ---- the squad cards (lineup.lua) --------------------------------------------------------------------------------- */

#define MYC_LINEUP_FAILURE_LIMIT 3
#define MYC_OWNER_NONE 0
#define MYC_OWNER_LOCAL 1
#define MYC_OWNER_SQUAD 2
#define MYC_OWNER_PEER 3

typedef struct MycCard
{
    int slot, failures, dirty, mine, has_settings, has_applied, key_kind;
    char key[MYC_PEER_KEY];
    MycSettings settings;
    uint32_t helmet, armor, body, cape;
    MycController* controller;
} MycCard;

typedef void (*MycSettleFn)(void* ctx, MycController* c, uint32_t frame, const char* what);

typedef struct MycLineup
{
    const MycNative* native;
    MycPool* pool;
    void (*note)(const char* line);
    MycRemote* remote;
    MycRecordsSame records_same;
    void* records_ctx;
    MycCard* cards[MYC_PREVIEW_SLOTS];
    int pending, busy, remap, stale, served, jobs, rebinds, cursor, has_logged;
    int owner_kind[MYC_PREVIEW_SLOTS];
    char owner_key[MYC_PREVIEW_SLOTS][MYC_PEER_KEY];
    MycPreviewWatch* watch;
    char logged[512];
    MycRetiring retiring[8];
    int nretiring;
    int own;                        /* the slot of the player's own preview at the last observe, -1 none */
} MycLineup;
void myc_lineup_init(MycLineup* l, const MycNative* native, MycPool* pool, void (*note)(const char* line), MycRemote* remote,
    MycRecordsSame records_same, void* ctx);
void myc_lineup_free(MycLineup* l);
void myc_lineup_session_text(char* out, size_t size);
/* The slot of the player's own preview among the shown ones, or -1 (observe). */
int myc_lineup_observe(MycLineup* l, uint32_t frame, MycPreviewWatch* w, const MycIdentity* identity, int loopback);
int myc_lineup_request(MycLineup* l, MycRequest* out);
void myc_lineup_finish(MycLineup* l, int ok, MycResult* result, const MycRequest* request, const char* why, uint32_t frame);
void myc_lineup_check(MycLineup* l);
void myc_lineup_step(MycLineup* l, uint32_t frame, MycSettleFn settle, void* ctx);
void myc_lineup_clear(MycLineup* l, uint32_t frame);
int myc_lineup_any(const MycLineup* l);

#endif
