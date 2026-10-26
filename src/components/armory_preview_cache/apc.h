/* Armory Preview Cache: what the component's files share (its own interface: only its files and its test include it).
 *
 * The Lua's modules map to files here:
 *   install.lua                          armory_preview_cache.c (the tick, the idle gate, the profile file)
 *   native.lua, signatures.lua           apc_native.c (package leases, catalogues, the asset snapshot)
 *   dependencies.lua                     apc_deps.c (weapon attachment packages)
 *   policy.lua, profile.lua              apc_policy.c (memory guard, lease policy, profile codec)
 *   image_native.lua M.state             apc_state.c (the state view: one signature per refresh)
 *   image_native.lua decode              apc_decode.c (the image snapshot)
 *   image_native.lua M.new, signatures   apc_present.c (textures, handoffs, bindings)
 *   images.lua                           apc_images.c (the image cache) */
#ifndef APC_H
#define APC_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "../../core/vpm.h"

/* ---- game.dll and helldivers2.exe (build 25480438) --------------------------------------------------------------- */

#define APC_RVA_ROOT_API 0x3326308u      /* [game] == exe + APC_EXE_ROOT_API: the engine's script API root */
#define APC_RVA_GLOBALS 0x347CD80u       /* 0x138 bytes: thumbnail manager +0, UI +0x10, state machine +0xA8,
                                          * preview system +0xE0, package system +0x130 */
#define APC_RVA_UI 0x347CD90u
#define APC_RVA_STATE_MACHINE 0x347CE28u
#define APC_RVA_PREVIEW 0x347CE60u
#define APC_RVA_PACKAGES 0x347CEB0u      /* the RefcountedPackageSystem (HellForge's load_package uses it too) */
#define APC_RVA_DISPATCH 0x3326E68u      /* the UI dispatch: controllers by kind (Armory 224, briefing 229) */
#define APC_RVA_KITS 0x33264F8u
#define APC_RVA_PRESETS 0x347CEF8u
#define APC_RVA_DATABASE 0x346BF98u      /* the entity state: component tables at +0xF12478 + 8 * index */
#define APC_RVA_GROUP_COUNT 0x348DA98u
#define APC_RVA_GROUPS 0x37C5B50u
#define APC_RVA_PACKAGE_MAP 0x3799810u
#define APC_RVA_FALLBACK 0x213F2B8u
#define APC_RVA_ACQUIRE 0x12FE350u       /* request(system, const u64* ids, u32 count) */
#define APC_RVA_RELEASE 0x12FE4E0u
#define APC_RVA_SET_TEXTURE 0x14499E0u
#define APC_RVA_SET_UV 0x143EEF0u
#define APC_RVA_SET_SIZE 0x1447160u
#define APC_RVA_SET_ALPHA 0x1448AD0u
#define APC_RVA_MATERIAL 0x144F800u
#define APC_RVA_REGISTER_IMAGE 0x1392680u
#define APC_EXE_ROOT_API 0x27C8D80u
#define APC_EXE_PACKAGE_A 0x320DD0u      /* app + 752 */
#define APC_EXE_PACKAGE_B 0x321030u      /* app + 768 */
#define APC_EXE_CREATE 0x31AF50u         /* app + 368 */
#define APC_EXE_DESTROY 0x31B360u        /* app + 400 */
#define APC_EXE_REGISTER 0x31E030u       /* app + 528 */
#define APC_EXE_FORMAT_SIZE 0x1658990u   /* u32 32 */

#define APC_ATLAS_NAME 3400165836u       /* the thumbnail atlas's resource name (create, register) */
#define APC_TEXTURE_SLOT 984135806u      /* the image element's texture slot (set_texture) */
#define APC_MANAGER_SIZE 12176u
#define APC_AT_ATLAS 11112u              /* the thumbnail manager's working atlas pointer */
#define APC_AT_REGISTRY 11136u           /* its registered image consumers: count, then pointers from +11144 */

/* ---- small helpers --------------------------------------------------------------------------------------------- */

static inline uint32_t ApcU32(const void* bytes, size_t at) { uint32_t v; memcpy(&v, (const uint8_t*)bytes + at, 4); return v; }
static inline uint64_t ApcU64(const void* bytes, size_t at) { uint64_t v; memcpy(&v, (const uint8_t*)bytes + at, 8); return v; }
static inline float ApcF32(const void* bytes, size_t at) { float v; memcpy(&v, (const uint8_t*)bytes + at, 4); return v; }
/* api.pointer's test: a user-mode address, not a small number (the core's vpm_plausible). */
static inline int ApcPlausible(uint64_t v) { return vpm_plausible((uintptr_t)v); }
static inline uintptr_t ApcPointer(const void* bytes, size_t at) { uint64_t v = ApcU64(bytes, at); return ApcPlausible(v) ? (uintptr_t)v : 0; }
static inline uintptr_t ApcGamePointer(uint32_t rva) { uint64_t v = vpm_game_u64(rva); return ApcPlausible(v) ? (uintptr_t)v : 0; }
static inline int ApcFinite(double n) { return n == n && n < 1000000.0 && n > -1000000.0; }

/* ---- errors: the Lua's assert and error ------------------------------------------------------------------------ *
 * A check that fails records its message (the first since the last clear) and returns 0; every caller returns 0 on.
 * The tick counts such an error as the Lua's update guard did (armory_preview_cache.c). */
int apc_fail(const char* message);
const char* apc_error(void);
void apc_error_clear(void);
/* A heap read as the Lua's api.read made it (1 .. 32768 bytes), and the same read that fails with message. */
int apc_read(uintptr_t address, void* out, size_t size);
int apc_need(uintptr_t address, void* out, size_t size, const char* message);
/* The code-byte checks: the Lua's signature lists as IDA-style patterns ("45 85 C0 ..."; game.dll's and the exe's in
 * arrays of their own, the form scripts/check_code_pins.py reads), handed to the core's wait for decoded code
 * (vpm_when_code_ready) in parts of at most 128 bytes (HellForge's code_matches takes 256), at start-up. */
typedef struct ApcSignature { int exe; uint32_t rva; const char* hex; } ApcSignature;
const ApcSignature* apc_native_signatures(int* count);
const ApcSignature* apc_present_signatures(int exe, int* count);

/* ---- the open-addressing maps (u64 key -> u64 value) the Lua's tables became -------------------------------- */

typedef struct ApcMap { uint64_t* keys; uint64_t* values; uint8_t* used; uint32_t capacity; uint32_t count; } ApcMap;
void apc_map_clear(ApcMap* map);
int apc_map_put(ApcMap* map, uint64_t key, uint64_t value); /* 0: full */
int apc_map_get(const ApcMap* map, uint64_t key, uint64_t* value);
#define APC_MAP(name, capacity) static uint64_t name##Keys[capacity], name##Values[capacity]; static uint8_t name##Used[capacity]; \
    static ApcMap name = {name##Keys, name##Values, name##Used, capacity, 0}

/* ---- the asset side (native.lua, dependencies.lua, policy.lua) --------------------------------------------------- */

#define APC_ITEMS 90                     /* six cards of 15 requests */
#define APC_ATTACHMENTS 10

typedef struct ApcAssetItem
{
    uint32_t kind;                       /* 0 primary/secondary, 1 throwable, 2..4 helmet, armor, cape */
    uint64_t id;
    uint8_t finished;
    uint8_t has_attachments;             /* the Lua's attachments table (nil vs. a list, possibly empty) */
    uint8_t attachment_count;
    uint64_t attachments[APC_ATTACHMENTS];
} ApcAssetItem;

typedef struct ApcAssetSnap
{
    uint64_t owner[2];                   /* the package system and its allocator: the lease table's identity */
    uintptr_t system;
    int has_world;
    uint64_t world;
    int menu, prefetch, blocked, active;
    int32_t top;
    int item_count;
    ApcAssetItem items[APC_ITEMS];
} ApcAssetSnap;

/* apc_native.c */
int apc_native_init(void);
int apc_native_snapshot(ApcAssetSnap* out);
int apc_native_valid_leases(const uint64_t* ids, int count, const uint64_t owner[2], int* valid);
int apc_native_acquire(uint64_t id, const uint64_t owner[2], int* acquired);
int apc_native_release(uint64_t id, const uint64_t owner[2], int* released);
/* resolve_all: the item's package and its dependencies' packages (deduplicated as the Lua did); *count of max. */
int apc_native_resolve_all(const ApcAssetItem* item, uint64_t* ids, int max, int* count);
/* Loadout package rows the last catalogue skipped: HellForge's records for mod content, past the Lua's bound. */
uint32_t apc_native_skipped(void);

/* apc_deps.c */
void apc_deps_reset(void);
int apc_deps_refresh(void);
/* The packages of a weapon's default and configured attachments, in order, each once. */
int apc_deps_resolve(const ApcAssetItem* item, uint64_t* packages, int max);
/* The weapons queued for preview and their configured attachments (known ones only): fills each item's attachments. */
int apc_deps_queued(ApcAssetItem* items, int count);
/* Weapon configuration rows the last refresh skipped: HellForge's records for mod content, past the Lua's bound. */
uint32_t apc_deps_skipped(void);

/* apc_policy.c: the memory guard */
#define APC_PRESSURE_NONE 0
#define APC_PRESSURE_LOW_PHYSICAL 1
#define APC_PRESSURE_LOW_COMMIT 2
#define APC_PRESSURE_RECOVERY 3
typedef struct ApcGuard
{
    uint32_t trips;
    int active;
    int last_reason;
    double last_low, healthy_since;
    int has_healthy;
} ApcGuard;
int apc_guard_tick(ApcGuard* guard, double now, uint64_t free, uint64_t commit);
const char* apc_pressure_text(int reason);

/* apc_policy.c: the lease policy */
#define APC_LEARNED 192
#define APC_LEASE_LIMIT 128
typedef struct ApcLease { uint64_t id; uint64_t owner[2]; double used; } ApcLease;
typedef struct ApcPolicy
{
    int prewarm;
    int lease_count;
    ApcLease leases[APC_LEASE_LIMIT + 1];
    int learned_count;                   /* oldest first */
    ApcAssetItem learned[APC_LEARNED + 1];
    int has_owner;
    uint64_t owner[2];
    int has_world;                       /* the Lua's self.world is not nil */
    uint64_t world;
    int has_started;
    double started;
    int seen_menu, quarantined, pressure, settled;
    int profile_changed;                 /* -1 never set (nil), 0 false, 1 true */
    uint32_t acquires, releases, hits, unresolved, retired, prewarms, dependency_acquires, startup_acquires;
    uint32_t foreground_pending, tick_hits, tick_unresolved;
    const char* status;
} ApcPolicy;
ApcPolicy* apc_policy(void);
void apc_policy_reset(int prewarm);
void apc_policy_remember(const ApcAssetItem* item);
int apc_policy_tick(const ApcAssetSnap* s, double now, int pressure);
void apc_policy_replay(void);
int apc_policy_clear(void);

/* apc_policy.c: the profile ("ArmoryPreviewCache2 <build>" then "kind:id|attachment,..." per learned item) */
#define APC_PROFILE_MAX 65536
size_t apc_profile_encode(char* out, size_t capacity, const char* build);
/* Decodes text and remembers its items; 1 valid (the header matches), 0 not. */
int apc_profile_decode(const char* text, size_t size, const char* build, int remember);

/* ---- the image side (image_native.lua, images.lua) --------------------------------------------------------------- */

#define APC_KEY_MAX 136                  /* a request key: layout (52) + variant (16, 25 or 29) + identity (48) */
#define APC_LAYOUT 52
#define APC_CAPTURE_MAX 12288            /* atlas + 90 * (card, slot, key) */
#define APC_STAMP_MAX 964                /* a card's stamp: count + 15 * (48 + 16) */
#define APC_WIDGETS 64
#define APC_REGISTRY 128
#define APC_PREVIEW_MAX 80               /* a preview job's configured slots (10 * 8 bytes) */

typedef struct ApcKey { uint16_t size; uint8_t bytes[APC_KEY_MAX]; uint64_t hash; } ApcKey;
int apc_key_equal(const ApcKey* a, const ApcKey* b);
void apc_key_hash(ApcKey* key);

typedef struct ApcItem
{
    int present;
    uint8_t input[104];                  /* the request record +0 .. +104 */
    uint8_t card, index;
    uint8_t ready, pixels_ready, has_key;
    int16_t preview;                     /* the observed preview slots (apc_decode.c), -1 none */
    ApcKey key;
} ApcItem;

typedef struct ApcWidget
{
    ApcKey key;
    uintptr_t owner, world;
    uint32_t controller_kind;
    uintptr_t widget, element;
    uint64_t record_pointer, visual, indices;
    uint8_t bound, invalidated, named_material, native_ready, pixels_ready;
    uint8_t uv[16], size[8];
    double box_width, box_height;
    uint32_t fit;
    uint64_t material_pointer;           /* set when apply binds it */
} ApcWidget;

#define APC_SCREEN_NONE 0
#define APC_SCREEN_GRID 1
#define APC_SCREEN_WEAPON_PRESELECT 2
#define APC_SCREEN_COSMETIC_PRESELECT 3
#define APC_SCREEN_BRIEFING_GRID 4
#define APC_SCREEN_BRIEFING_LOADOUT 5

typedef struct ApcCardSource { int present; uint32_t state; uint16_t stamp_size; uint8_t stamp[APC_STAMP_MAX]; } ApcCardSource;

typedef struct ApcImageSnap
{
    uintptr_t context;                   /* the thumbnail manager (0: none) */
    uintptr_t manager;
    uint8_t view_size;                   /* 0: none; world, kind, owner */
    uint8_t view[17];
    uintptr_t world, owner;
    uint32_t controller_kind;
    uintptr_t atlas;
    uint32_t width, height;
    uint64_t bytes, descriptor_id;
    uint8_t layout[APC_LAYOUT];
    ApcCardSource source[6];
    int blank_cards;
    uint32_t expected_count;
    int complete, can_freeze, quiescent, can_freeze_idle, can_freeze_rebind, can_freeze_visible;
    double tile_width, tile_height;
    int screen;
    ApcItem slots[APC_ITEMS];            /* by card * 15 + index */
    int item_count;
    uint8_t items[APC_ITEMS + 8];        /* slot indexes, in the screen's order (a pre-select may list one twice) */
    int widget_count;
    ApcWidget widgets[APC_WIDGETS];
    size_t capture_size;                 /* 0: no capture id */
    uint8_t capture[APC_CAPTURE_MAX];
    int registry_count;
    uintptr_t registry[APC_REGISTRY];
} ApcImageSnap;

/* apc_state.c: the state view (image_native.lua M.state) */
typedef struct ApcState
{
    uint32_t G[78], STACK[6], UIB[116], DPTR[2], DROWS[257], MB[APC_MANAGER_SIZE / 4], DESC[26], QH[2];
    uint32_t QROWS[127 * 50], SMALL[120], META[6223], TAILS[12], LEASE[10];
    int g_ok, stack_ok, ui_ok, dptr_ok, rows_ok, mb_ok, desc_ok, qh_ok, qrows_ok, small_ok, meta_ok, tails_ok[6];
    uintptr_t meta_address;
    int probed;
    uintptr_t tm, ui, sm, preview, lease, owner, atlas, world;
    int has_depth;
    uint32_t depth;
    uint32_t kind;                       /* 224 Armory, 229 briefing, 0 none */
    uint32_t jobs;
    uint64_t refreshes, image_version, policy_version, lease_version;
    int lease_checked;
} ApcState;
ApcState* apc_state(void);
void apc_state_reset(void);
void apc_state_refresh(void);
/* The idle gate's probe: 1 with the manager (0 none), the stack depth and top (-1 outside 1..5); 0 when unreadable. */
int apc_state_probe(uintptr_t* tm, uint32_t* depth, int32_t* top);
void apc_state_unprobe(void);
void apc_state_refresh_lease(void);
/* uintptr_t pointer of a state buffer word pair. */
static inline uintptr_t ApcWordPointer(const uint32_t* words, size_t at)
{
    uint64_t v = (uint64_t)words[at] | (uint64_t)words[at + 1] << 32;
    return ApcPlausible(v) ? (uintptr_t)v : 0;
}

/* apc_decode.c: the image snapshot */
int apc_decode(ApcImageSnap* out);
void apc_decode_reset(void);
/* The preview slots observed for an item (bytes and size), or NULL. */
const uint8_t* apc_preview_slots(int16_t preview, uint8_t* size);
/* The working atlas left blank behind completed cards by a handoff (freeze), or none. */
void apc_blank_set(const ApcImageSnap* s, uintptr_t fresh, uint64_t id);
void apc_blank_clear(void);
int apc_dispatch_owner(uint32_t kind, uintptr_t* owner); /* image_native.lua controller(kind): the screen's owner */

/* apc_present.c: textures (the retained atlases) */
#define APC_TEXTURES 32
typedef struct ApcTexture
{
    int listed;                          /* held by the image cache */
    uintptr_t handle, replacement;
    uint64_t bytes, id;
    uint32_t width, height;
    uint64_t used;
    int destroyed, returned, retired;
} ApcTexture;
ApcTexture* apc_texture(int index);

/* A captured crop (images.lua entries, image_native.lua capture). */
typedef struct ApcCrop
{
    ApcKey key;
    uint8_t uv[16];
    double width, height;
    uint8_t has_preview, preview_size;
    uint8_t preview[APC_PREVIEW_MAX];
    int8_t texture;
    uint8_t rendered;                    /* images.lua rendered[key]: superseded by a later native render */
} ApcCrop;

#define APC_CANDIDATE_CROPS 96
typedef struct ApcCandidate
{
    int present;
    uintptr_t atlas;
    uint8_t layout[APC_LAYOUT];
    uint64_t bytes, descriptor_id;
    int crop_count;
    ApcCrop crops[APC_CANDIDATE_CROPS];
    size_t request_size;
    uint8_t request[APC_CAPTURE_MAX];
    int all_complete;
} ApcCandidate;

typedef struct ApcApplied { int hits, misses, early, unresolved, initialized; } ApcApplied;

int apc_present_init(void);
void apc_present_reset(void);
int apc_present_snapshot(int fresh, ApcImageSnap* out);
int apc_present_unchanged(void);
int apc_present_prune(void);
int apc_present_restore(int return_working);
int apc_present_capture(const ApcImageSnap* s, ApcCandidate* p);
/* The handoff: 1 with *texture (>= 0) or -1 when the engine made no texture; 0 on error. */
int apc_present_freeze(const ApcImageSnap* s, const ApcCandidate* p, int* texture);
int apc_present_apply(const ApcImageSnap* s, ApcApplied* r);
int apc_present_check_textures(void);
int apc_present_destroy(int texture);
int apc_present_quiet(void);
int apc_present_bound(void);

/* apc_images.c: the image cache */
typedef struct ApcImageStats
{
    uint32_t hits, misses, retained, released, late_switches, early_hits, pending_drops, ready_items, missing_ready_items;
    uint32_t blank_ready_items, pending_items, partial_retained, idle_retained, visible_retained, evicted, ticks;
    uint32_t grid_hits, preselect_hits, briefing_hits, clear_count, rendered_items, refreshed, changed_items;
    uint32_t reappeared, gated_ticks, last_hits, last_misses, last_early_hits, textures;
    uint64_t bytes;
    const char* status;
    int screen;
} ApcImageStats;
void apc_images_reset(int enabled);
int apc_images_enabled(void);
int apc_images_tick(int pressure);
int apc_images_quiet(void);
int apc_images_bound(void);
int apc_images_before(void);
int apc_images_clear(const char* reason);
int apc_images_texture_count(void);
const ApcImageStats* apc_images_stats(void);
/* The crop cached for a key, or NULL (apply reads it). */
ApcCrop* apc_crop_find(const ApcKey* key);

/* ---- the component's own seams ---------------------------------------------------------------------------------- */

/* Memory telemetry (GlobalMemoryStatusEx: available physical memory and commit headroom). A test may replace it. */
typedef int (*ApcMemoryFn)(uint64_t* free, uint64_t* commit);
void apc_set_memory_source(ApcMemoryFn fn);

#endif
