/* Match Your Colors: the game-thread side (engine.lua, bindings.lua, avatar.lua, preview.lua): the engine calls that
 * recolor, the texture pool, the bindings controller, the local player's Helldiver and the UI preview in game memory,
 * and the jobs' requests and results the worker hands over. Everything here runs on the game thread except where a
 * comment says otherwise. */
#ifndef MYC_RUNTIME_H
#define MYC_RUNTIME_H

#include "myc_recolor.h"

/* ---- the engine (engine.lua) -------------------------------------------------------------------------------------- */

#define MYC_SCRIPT_API_RVA 0x3326308u
#define MYC_GET_ENGINE_API_RVA 0xa4e50u
#define MYC_GET_ENGINE_API_PREFIX "48 83 EC 28 83 F9 01 0F 85"
#define MYC_LUT_SLOT 0x7e662968u
#define MYC_PATTERN_SLOT 0x81d4c49du
#define MYC_CAPE_LUT_SLOT 0x0e494183u
#define MYC_DECAL_SLOT 0x632a8b80u
#define MYC_ALBEDO_SLOT 0xac652e43u
#define MYC_TEXTURE_TYPE 0xCD4238C6A0C69E32ull
#define MYC_RGBA32F 0x80820820u
#define MYC_BC3 0x10000002u
#define MYC_BC1 0x10000000u
#define MYC_MESH_VISIBILITY 0xDCu
#define MYC_TEXTURE_VIEW 3u
#define MYC_UPDATABLE 1u

typedef struct MycNative
{
    uint8_t (*alive)(uint32_t unit);
    uint32_t (*meshes)(uint32_t unit);
    uint64_t (*mesh)(uint32_t unit, uint32_t index);
    uint32_t (*materials)(uint64_t mesh);
    uint64_t (*material)(uint64_t mesh, uint32_t index);
    void (*commit)(uint64_t mesh);
    void (*visibility)(uint32_t unit, uint32_t visible, uint8_t children);
    void (*set_resource)(uint64_t material, uint32_t slot, uint64_t resource);
    uint32_t (*create)(uint32_t size, uint32_t validity, uint32_t view_type, const void* view, const void* data);
    void (*update)(uint32_t handle, uint32_t size, const void* data);
    void (*destroy)(uint32_t handle);
    uint64_t (*resource)(uint32_t handle);
    uint8_t (*can_get)(uint64_t type, uint64_t name);
    uint64_t (*get)(uint64_t type, uint64_t name);
} MycNative;

/* Engine.open: every function the component calls, its address compared with its expected executable offset; 1, 0
 * with why (changed: the component cannot run), or -1 with why when the engine has not filled the script API's tables
 * yet (HellForge's game-loaded event can come before the engine's script setup, where the Lua ran). */
int myc_engine_open(MycNative* out, const char** why);
/* The loaded texture object of a texture resource name, or 0 when it is not loaded. */
uint64_t myc_texture_object(const MycNative* native, uint64_t name);
/* Every material of a live unit (at most 64 x 64): count; meshes[i], materials[i]. */
#define MYC_MAX_UNIT_MATERIALS 4096
int myc_unit_materials(const MycNative* native, uint32_t unit, uint64_t* meshes, uint64_t* materials);
/* A material's texture bindings into big (16 bytes each, at most 64): how many, or 0 (array address in *array). */
int myc_bindings(uint64_t material, uint8_t* big, uint64_t* array);
uint64_t myc_binding_in(const uint8_t* big, int count, uint32_t slot);
uint64_t myc_binding(uint64_t material, uint32_t slot);
/* The address of the texture object field of a material's binding of slot, or 0. */
uint64_t myc_binding_entry(uint64_t material, uint32_t slot);

/* A runtime texture: its engine handle and object, the spec whose data it holds (a reference) and the spec it held
 * before its last refill (kept until it is given back). */
typedef struct MycTexture
{
    uint32_t handle;
    uint64_t object;
    MycSpec* spec;
    MycSpec* previous;
    int width, height, mips, kind, bc1, direct;
    uint32_t format;
    size_t size;
    uint64_t sheet_name;
    uint32_t sheet_sum;
    uint32_t retired_at;
    struct MycTexture* next;   /* the pool's free list */
} MycTexture;

#define MYC_POOL_SPARES 2
#define MYC_POOL_MAX_FREE 48
#define MYC_POOL_MAX_FREE_SHEETS 1
#define MYC_POOL_MAX_FREE_ALBEDOS 1
#define MYC_POOL_STOCK 6
#define MYC_SHEET_NOTES 16
#define MYC_POOL_LISTS 64

typedef struct MycPoolList { char key[64]; MycTexture* first; int count; } MycPoolList;
typedef struct MycPool
{
    const MycNative* native;
    MycPoolList lists[MYC_POOL_LISTS];
    int nlists;
    int made, refilled, destroyed, sheets_made, sheets_refilled;
    char sheet_notes[MYC_SHEET_NOTES][160];
    int nsheet_notes;
} MycPool;
void myc_pool_init(MycPool* pool, const MycNative* native);
/* The free list a spec's texture belongs to (Engine.pool_key). */
void myc_pool_key(const MycSpec* spec, char* out, size_t size);
/* A free texture of the spec's size refilled with its data, else a new one (and spares); NULL with why. */
MycTexture* myc_pool_take(MycPool* pool, MycSpec* spec, const char** why);
void myc_pool_reserve(MycPool* pool, MycSpec* spec, int count);
void myc_pool_give(MycPool* pool, MycTexture* texture);
/* Makes, ahead of an apply, the textures a prepared plan's apply would make and more (pool.stock); how many. */
int myc_pool_stock(MycPool* pool, const MycSpecs* luts, const MycSpecs* patterns);
int myc_pool_free_count(const MycPool* pool);
/* Every free texture destroyed (stop). */
void myc_pool_clear(MycPool* pool);

/* ---- jobs: requests and results ----------------------------------------------------------------------------------- */

#define MYC_OFF 1
#define MYC_HELMET_FROM_ARMOR 2
#define MYC_ARMOR_FROM_HELMET 3
#define MYC_CAPE_SOURCE 4

#define MYC_TARGET_AVATAR 1
#define MYC_TARGET_UI 2
#define MYC_TARGET_PREPARE 3
#define MYC_TARGET_REMOTE 4
#define MYC_TARGET_CARD 5
#define MYC_TARGET_WEAPONS 6
#define MYC_TARGET_UI_WEAPON 7

/* A weapon (weapons.lua weapon_of / preview): its entity id, name (resource), units, attachments and paint. */
#define MYC_WEAPON_UNITS 40
#define MYC_OVERRIDE_ROWS 10
typedef struct MycOverrideRow { uint32_t slot; uint64_t lut, pattern; } MycOverrideRow;
typedef struct MycWeaponPaint { MycOverrideRow rows[MYC_OVERRIDE_ROWS]; int nrows, has; char text[MYC_OVERRIDE_ROWS * 44 + 1]; } MycWeaponPaint;
typedef struct MycWeapon
{
    uint32_t id, unit;
    uint64_t name;
    uint32_t units[MYC_WEAPON_UNITS];
    int nunits, copy, has_ids;     /* has_ids: a preview weapon (its customization ids; composed in the job) */
    uint64_t attachments[5];        /* by role 1-4; 0 none */
    MycWeaponPaint overrides[5];    /* by role 0-4 */
    uint64_t ids[10];               /* a preview's customization ids */
    int nids;
} MycWeapon;

typedef struct MycRequest
{
    int target;
    char key[192];                  /* a squadmate's or card's key; a weapons request's key */
    int mode, scheme, keep_sets, keep_hoods, materials, capes;
    int has_kits;
    uint32_t helmet, armor, body, cape;
    uint32_t source_kit, source_cape;
    int slot;                       /* a squad card's */
    MycWeapon weapons[3];
    int nweapons;
    char sig[8192];                 /* a weapons request's weapons signature */
    volatile long obsolete;         /* the game thread's: the job ends at its next stage boundary */
} MycRequest;

#define MYC_APPLY 1
#define MYC_RESTORE 2
#define MYC_PREPARED 3
#define MYC_OBSOLETE 4

#define MYC_MAX_TARGETS 8
typedef struct MycSigned { uint32_t id; const char* signature; } MycSigned;
typedef struct MycResult
{
    int action;
    char reason[64];
    char key[1536];
    MycSpecs luts, patterns;
    int first, last;
    const MycAnalysis* target;
    const MycAnalysis* targets[MYC_MAX_TARGETS];
    int ntargets;
    MycSigned signatures[5];
    int nsignatures;
    char* cape_report;
    char* albedo_report;
    MycArena arena;
    int refs;                       /* game thread: the controllers holding it */
} MycResult;
MycResult* myc_result_new(void);
MycResult* myc_result_hold(MycResult* r);
void myc_result_drop(MycResult* r);

/* ---- the bindings controller (bindings.lua) ----------------------------------------------------------------------- */

#define MYC_PENDING_EVERY 4
#define MYC_PENDING_FRAMES 120
#define MYC_RETIRE_FRAMES 4

/* A unit to recolor: its id, its piece type and slot (Avatar.units), or any (a weapon's: every material), attachment
 * (an attachment's unit: the plan's attachment LUTs). */
typedef struct MycUnitRef { uint32_t unit; int type, slot, preview, any, attachment, weapon; } MycUnitRef;
#define MYC_MAX_UNITS 512
#define MYC_FIXED_UNITS 64
/* What an apply binds: the avatar's (or a preview's) unit arrays and preview slot, its body; or (fixed) a weapons
 * controller's units (Weapons.units). */
typedef struct MycApplyTo { uintptr_t units_at, slot; uint32_t body; int fixed, nunits; MycUnitRef units[MYC_FIXED_UNITS]; } MycApplyTo;

typedef struct MycBinding { uint32_t unit; uint64_t mesh, material; uint32_t slot; uint64_t vanilla, texture; int taken; } MycBinding;
/* A slot holding a texture neither the plan's nor ours (settle): its specs kind (0 LUTs, 1 patterns) and map. */
typedef struct MycWaiting { uint32_t unit; uint64_t mesh, material; uint32_t slot; int patterns, attachment; } MycWaiting;
typedef struct MycNamedTexture { uint64_t name; int attachment; MycTexture* texture; } MycNamedTexture;

typedef struct MycController
{
    const MycNative* native;
    MycPool* pool;
    MycBinding* bindings;
    int nbindings, bindings_capacity;
    MycNamedTexture* textures;
    int ntextures, textures_capacity;
    MycTexture** retired;
    int nretired, retired_capacity;
    char key[1536];
    int has_key;
    MycResult* result;
    int applied, restored, released, probes, turn;
    int* probe_list;
    int probes_capacity;
    /* pending (settle): units without materials and slots waiting at the last apply */
    int has_pending;
    uint32_t pending_units[MYC_MAX_UNITS];
    int npending_units;
    MycWaiting* waiting;
    int nwaiting, waiting_capacity;
    MycApplyTo pending_to;
    uint32_t pending_since;
} MycController;
void myc_controller_init(MycController* c, const MycNative* native, MycPool* pool);
void myc_controller_free(MycController* c);
/* False when the game put a material's original texture back while its unit lives (one probe per call, in turn). */
int myc_controller_check(MycController* c);
void myc_controller_restore(MycController* c, uint32_t frame);
/* Retired textures given back RETIRE_FRAMES frames after; how many remain. */
int myc_controller_collect(MycController* c, uint32_t frame);
void myc_controller_prune(MycController* c);
/* Applies a job result (held by the controller); how many bindings were made, -1 with why (a texture not made). */
int myc_controller_apply(MycController* c, MycResult* result, const MycApplyTo* to, uint32_t frame, char* why, size_t size);
/* settle: the pending units and slots bound once ready; bindings made, *outcome 0 done, 1 pending, 2 expired; -1 why. */
int myc_controller_settle(MycController* c, uint32_t frame, int* outcome, char* why, size_t size);

/* ---- the local player (avatar.lua) and the UI preview (preview.lua) ---------------------------------------------- */

#define MYC_FOUND_NOTHING 0
#define MYC_FOUND_PLAYERS 1
#define MYC_FOUND_KITS 2
#define MYC_STAND_IN 0xffffffffu

typedef struct MycIdentity
{
    uintptr_t players;
    uint32_t player, unit, ui_slot, peer_low, peer_high;
    int has_ui_slot, has_peer;
    uint32_t record, body, helmet, cape, armor;
    uint32_t avatar, avatar_index;
    uintptr_t units_at, previews;
} MycIdentity;
int myc_avatar_lookup(uintptr_t address, uint32_t key, uint32_t* value);
/* Avatar.resolve: 1, or 0 with why and how far it got (MYC_FOUND_...); out filled as far as it got. */
int myc_avatar_resolve(MycIdentity* out, const char** why, int* found);
int myc_avatar_resolve_remote(const MycIdentity* player, MycIdentity* out, const char** why);
uintptr_t myc_avatar_preview_slot(const MycIdentity* identity);
/* The units to recolor of the avatar's arrays and the preview slot's entries, slots first .. last. */
int myc_avatar_units(const MycIdentity* identity, uintptr_t slot, int first, int last, MycUnitRef* out, int max);
int myc_avatar_desired_kits(uint32_t player, uint32_t* helmet, uint32_t* armor, uint32_t* cape);

typedef struct MycPlayer { uint32_t player, index, peer_low, peer_high, unit; int is_local; } MycPlayer;
#define MYC_MAX_PLAYERS 8
int myc_avatar_players(MycPlayer* out);
typedef struct MycDesired { uint32_t helmet, armor, cape; } MycDesired;
int myc_avatar_others_desired(MycDesired* out);
void myc_avatar_players_text(char* out, size_t size);

/* The idle check of the avatar's 120 unit bytes and its preview slot's entries (Avatar.watch). */
#define MYC_MAX_PREVIEWS 16
#define MYC_PREVIEW_ENTRY 132
typedef struct MycWatch
{
    uintptr_t units_at, copies_at;
    uint32_t now[30], kept[30];
    uint8_t copies_now[4 + MYC_PREVIEW_ENTRY * MYC_MAX_PREVIEWS], copies_kept[4 + MYC_PREVIEW_ENTRY * MYC_MAX_PREVIEWS];
    int primed, copies_primed, copies_read, reads;
} MycWatch;
void myc_watch_init(MycWatch* w, const MycIdentity* identity, uintptr_t slot);
int myc_watch_changed(MycWatch* w, int copies);
uint32_t myc_watch_ref(const MycWatch* w, int i);

/* The UiPreviewSystem's player slots (preview.lua). */
#define MYC_PREVIEW_SYSTEM 0x347CE60u
#define MYC_PREVIEW_RECORD 160
#define MYC_PREVIEW_SLOTS 4
#define MYC_STATUS_ABSENT 0
#define MYC_STATUS_KITS 1
#define MYC_STATUS_UNITS 2
#define MYC_STATUS_SAME 3
typedef struct MycWhere { uintptr_t system, first, record, units_at; int slot; uint32_t bit; } MycWhere;
int myc_preview_locate(uint32_t ui_slot, int has_ui_slot, MycWhere* out);
void myc_preview_retarget(MycWhere* where, int slot);
#define MYC_PREVIEW_SPAN (50440 - 49160 + 16)
typedef struct MycPreviewWatch
{
    MycWhere* where;
    uint8_t now[MYC_PREVIEW_SPAN], kept[MYC_PREVIEW_RECORD * MYC_PREVIEW_SLOTS], gate[16];
    int present[MYC_PREVIEW_SLOTS], statuses[MYC_PREVIEW_SLOTS];
    int64_t head;
    int moved, reads, changes;
} MycPreviewWatch;
void myc_preview_watch_init(MycPreviewWatch* w, MycWhere* where);
int myc_preview_poll(MycPreviewWatch* w);
int myc_preview_status(const MycPreviewWatch* w, int s);
void myc_preview_slot_kits(const MycPreviewWatch* w, int s, uint32_t* helmet, uint32_t* armor, uint32_t* body, uint32_t* cape);
uintptr_t myc_preview_units_at(const MycPreviewWatch* w, int s);
void myc_preview_reset(MycPreviewWatch* w);

#endif
