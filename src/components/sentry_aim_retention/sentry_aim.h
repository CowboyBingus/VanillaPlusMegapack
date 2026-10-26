/* Sentry Aim Retention: what the component's files share (sentry_layout.c finds and reads the sentries, sentry_hold.c
 * holds their aim, sentry_fire.c pauses their fire and shortens their target search, sentry_natives.c binds and calls
 * the game's functions, sentry_aim_retention.c is the component), and what its test drives directly.
 *
 * The Lua (aim_data.lua) kept rows, records and leases as tables that referenced each other; here they are fixed-size
 * structs in static pools, and a record keeps a copy of the row it last saw (every field a release reads is one the
 * row's layout fixes, so a copy reads as the Lua's reference did). */
#ifndef SENTRY_AIM_H
#define SENTRY_AIM_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"

#define SAR_MAX_ENTRIES 8192u /* the largest targeting registry the Lua accepts */
#define SAR_MAX_CHUNKS 32u    /* pointer chunks of 256 entries */
#define SAR_MAX_SENTRIES 64   /* sentries located at once (another one is left alone until a slot frees) */
#define SAR_MAX_RECORDS 128   /* aim records and fire records each: this check's sentries and the last check's */
#define SAR_RESCAN 30u        /* every 30th check classifies every targeting entry again */
#define SAR_MISSION_EVERY 60u /* outside a mission, the mission is checked on every 60th frame */
#define SAR_FIRING_NODE 12u   /* the behavior node a Gatling or machine gun fires from */
#define SAR_ROW_GUARDS 18
#define SAR_FIRE_GUARDS 10
#define SAR_MAX_WINDOWS 256
#define SAR_ARENA 16384

/* ---- guards and windows ------------------------------------------------------------------------------------------ */

/* Bytes that must still be at an address. */
typedef struct SarGuard { uintptr_t at; uint32_t size; uint8_t bytes[20]; } SarGuard;
/* Bytes this check already read at an address: a guard inside one is compared with them instead of read again. */
typedef struct SarWindow { uintptr_t at; uint32_t size; const uint8_t* bytes; } SarWindow;
typedef struct SarWindows { int count; uint32_t used; SarWindow at[SAR_MAX_WINDOWS]; uint8_t arena[SAR_ARENA]; } SarWindows;

/* A read anywhere: plain loads inside game.dll's and the exe's images, HellForge's read elsewhere. 1 read, 0 not. */
int sar_load(uintptr_t address, void* out, size_t size);
/* The user-mode pointer api.pointer accepted (0x10000 <= p < 0x800000000000), or 0. */
uintptr_t sar_user_pointer(uint64_t value);
/* Whether every guard holds: one inside a window is compared with its bytes, the others are read. */
int sar_verified(const SarGuard* guards, int count, const SarWindow* windows, int window_count);
/* matches(): every guard read. */
int sar_matches(const SarGuard* guards, int count);
void sar_guard_set(SarGuard* guard, uintptr_t at, const void* bytes, uint32_t size);

/* api.writable_data, once per range: a range verified since the targeting registry last changed is not queried again
 * (vpm_writable, one VirtualQuery per region). sar_writable_queries counts the queries made (the test pins them). */
int sar_writable(uintptr_t at, size_t size);
void sar_writable_forget(void);
uint32_t sar_writable_queries(void);

/* ---- sentries and their rows ------------------------------------------------------------------------------------- */

typedef struct SarProfile
{
    uint64_t resource; /* the entity resource (the entity record's first 8 bytes) */
    const char* name;
    uint32_t behavior; /* BehaviorComponent's id at behavior +0 */
    int fire_gate;     /* Gatling and machine gun: the shot permission gate, with its angles */
    double pause, resume;
} SarProfile;
extern const SarProfile sar_profiles[];
extern const int sar_profile_count;

#define SAR_UNKNOWN (-1) /* a Lua nil among false and true */

/* A Gatling's or machine gun's firing fields (row.fire). */
typedef struct SarFire
{
    uintptr_t manager, mode_address; /* the weapon manager and the sentry's replicated fire mode */
    int guard_count;
    SarGuard guards[SAR_FIRE_GUARDS];
    uint32_t unit;                   /* the sentry's unit */
    double pause, resume;
    /* this check */
    uint32_t node, mode;
    int trigger;
    int has_target_unit;
    uint32_t target_unit;            /* the selected target's unit, while the target is located */
    SarGuard target_guard;
    int has_pose;
    uint8_t pose[64];                /* the muzzle's world matrix */
    int terrain_blocked;             /* SAR_UNKNOWN (no query this check), 0, 1 */
    int target_stale;                /* the target's identity changed around the query: locate it again */
} SarFire;

/* The firing node's target search deadline (row.selection). */
typedef struct SarSelection { uintptr_t address; SarGuard guard; uint8_t deadline[8]; double now; } SarSelection;

typedef struct SarRow
{
    uint32_t id;
    uint8_t key[20];                 /* the entity record's first 20 bytes */
    const SarProfile* profile;
    uintptr_t entity, behavior_address, transition_address;
    uintptr_t authority_address;     /* 0: none (rows the tests build) */
    uintptr_t raw_address, computed_address, flags_address, control_address;
    int guard_count;
    SarGuard guards[SAR_ROW_GUARDS];
    int transition_count;
    SarGuard transition[4];
    int has_fire;                    /* fire and selection exist */
    SarFire fire;
    SarSelection selection;
    /* live fields, refreshed by every check */
    uint32_t node, target, source_flags, runtime_target, flags;
    int has, enabled;
    uint8_t point[12], raw[12], computed[12], horizontal[4], vertical[4];
} SarRow;

/* ---- the layout cache (aim_data.lua's cache) --------------------------------------------------------------------- */

typedef struct SarLayout
{
    int used;
    uint32_t index;                  /* the targeting entry */
    uint64_t pointer;                /* the entity pointer seen there */
    uintptr_t address;
    uintptr_t runtime_address, network_address;
    uint8_t behavior[160], control[16], runtime[32], network[24], entity[24], wm_header[56], cm_header[56];
    struct
    {
        uintptr_t wm_header, cm_header, clock_address, node_address, trigger_address;
        uint64_t clock_root;
        uint32_t count, nodes[24];
    } fire;
    int has_target;                  /* L.target: the selected target, located once per target */
    uint32_t target_id, target_unit;
    SarGuard target_guard;
    SarRow row;
} SarLayout;

/* The cache's per-check and kept state. The entries (one per targeting index) are in SarEntries. */
typedef struct SarCache
{
    int exists;                      /* the Lua's state.layout ~= nil */
    uint32_t checks, active;
    int idle;
    int outside;                     /* SAR_UNKNOWN until the first mission check */
    int have_tmb;
    uint64_t tmb;                    /* the targeting registry of the earlier checks */
    /* kept while their pointer bytes are unchanged */
    int have_tm, have_ep, have_bm, have_rm, have_rt, have_nt, have_mode;
    uint64_t tm_word, ep_word, bm_word, rm_word, rt_word, nt_word, mode_word;
    uintptr_t tm, th, ep, bm, bh, rm, rh, rt, nt, mode;
    /* this check */
    int strings;                     /* materialize ran */
    int reg;                         /* the behavior and turret registries: SAR_UNKNOWN, 0 (a root empty), 1 */
    uint32_t chunks;                 /* the last pointer chunk */
    uint8_t root[8], head[84], bm_root[8], rm_root[8], rh_bytes[88], bh_bytes[80], entity[24];
    uint32_t chunk_size[SAR_MAX_CHUNKS];
    uint64_t chunk[SAR_MAX_CHUNKS][256];
    SarWindows windows;
} SarCache;

/* Zero is the state of an entry never seen, so a cleared entry needs no other value. */
#define SAR_CLASS_UNKNOWN 0
#define SAR_CLASS_FALSE 1            /* not a sentry this machine controls */
#define SAR_CLASS_TRUE 2
typedef struct SarEntries
{
    uint8_t known[SAR_MAX_ENTRIES];  /* a pointer was seen at the index */
    uint8_t klass[SAR_MAX_ENTRIES];  /* SAR_CLASS_... */
    uint8_t layout[SAR_MAX_ENTRIES]; /* its layout slot + 1, or 0 */
    uint64_t pointer[SAR_MAX_ENTRIES];
    uintptr_t address[SAR_MAX_ENTRIES]; /* 0 until decoded again after the pointer changed */
} SarEntries;

extern SarCache sar_cache;
extern SarEntries sar_entries;
extern SarLayout sar_layouts[SAR_MAX_SENTRIES];

void sar_layout_start(void);         /* the session's start: no cache, no layout, no verified range */
void sar_cache_reset(void);          /* drops the cache (the Lua's state.layout = nil): every sentry is located again */
/* One check of the targeting registry: the rows of the sentries this machine controls, refreshed. 1, or 0 with *why. */
int sar_snapshot(SarRow** rows, int* count, const char** why);
/* The idle gate: 1 when this frame needs no check (no read but the mission check on some frames). lint: per-frame */
int sar_idle(void);

/* ---- the game's functions ---------------------------------------------------------------------------------------- */

typedef void (*SarRetentionFn)(void* manager, uint32_t id, uint32_t bit, uint8_t enabled);
typedef void (*SarSpeedFn)(void* entity, float speed);
typedef void (*SarFireModeFn)(void* manager, uint32_t id, uint32_t mode);
typedef uint32_t (*SarWorldIdFn)(const void* world);
typedef uint32_t (*SarRaycastFn)(uint32_t world, const void* from, const void* direction, float length, uint32_t collection,
    uint32_t actors, uint32_t filter, uint32_t flags, uint32_t ignore, void* out, uint32_t capacity);
typedef struct SarNatives
{
    SarRetentionFn retention;        /* game.dll 0x6BF390: the targeting control flag (bit 2: keep the stored aim) */
    SarSpeedFn horizontal, vertical; /* game.dll 0x11CBA20, 0x11CB930: the turret's turn speeds */
    SarFireModeFn fire_mode;         /* game.dll 0x755F90: the weapon's replicated fire mode */
    SarWorldIdFn world_id;           /* exe 0x79F860: a physics world's id */
    SarRaycastFn raycast;            /* exe 0x7F4590: the synchronous ray query */
} SarNatives;

/* The session's start: nothing bound, no override, no pose path kept. */
void sar_natives_start(void);
/* Checks the functions' code once per session and binds them: 1, or 0 with *why. */
int sar_bind_natives(const char** why);
int sar_natives_bound(void);
const SarNatives* sar_natives(void);
/* Tests: these functions instead of the game's, from now on and at the binding (after the same code checks). */
void sar_natives_override(const SarNatives* natives);

/* The muzzle pose of a unit's node, as UnitApi.world_pose selects it: 1 with matrix, 0 the matrix unreadable, -1 *why. */
int sar_pose(uint32_t unit, uint32_t node, uint8_t matrix[64], const char** why);
void sar_pose_forget(void);

/* A terrain query's result (the Lua's detail table). */
#define SAR_HIT_CLEAR 0
#define SAR_HIT_TARGET_SURFACE 1
#define SAR_HIT_ENDPOINT 2
#define SAR_HIT_DESTRUCTIBLE_COVER 3
#define SAR_HIT_STATIC_OBSTRUCTION 4
#define SAR_HIT_COVER_QUERY_LIMIT 5
typedef struct SarHit { int reason; uint32_t hit_unit, actor, hits; double distance, length; } SarHit;
typedef struct SarCast
{
    SarRaycastFn raycast;
    uint32_t world, unit;            /* the physics world's id; the sentry's unit (ignored by the query) */
    const uint8_t* origin;           /* 12 bytes each */
    const uint8_t* target;
    int has_target_unit;
    uint32_t target_unit;
    /* The hit actor's collision filter name (sar_actor_filter): 1 with *filter, 0 unknown. NULL: none known. */
    int (*filter)(uint32_t actor, uint32_t unit, uint32_t* filter);
} SarCast;
/* api.cast_terrain: 1 blocked, 0 clear (*hit says why; hit->reason SAR_UNKNOWN: the points are within 5 cm), -1 *why. */
int sar_cast_terrain(const SarCast* cast, SarHit* hit, const char** why);
/* api.actor_filter: 1 with the hit actor's collision filter name, 0 unknown (unverified handle, body or table). */
int sar_actor_filter(uint32_t actor, uint32_t unit, uint32_t* filter);
/* terrain_path: 1 with *blocked, 0 no query now (native ray work pending), -1 *why. */
int sar_terrain_path(uint32_t unit, const uint8_t origin[12], const uint8_t target[12], uint32_t target_unit, int* blocked,
    const char** why);
/* The muzzle pose and, while the row tracks a synchronized target, its terrain clearance: 1, or 0 with *why. */
int sar_prepare_fire(SarRow* row, const char** why);

/* ---- aim holds (sentry_hold.c) ----------------------------------------------------------------------------------- */

typedef struct SarAimWrite { uintptr_t address; uint8_t before[12], after[12]; } SarAimWrite;
typedef struct SarLease
{
    int active;
    SarRow held;                     /* the row at the hold, its saved turn speeds kept when it is relocated */
    int flag, horizontal, vertical;  /* controls this lease owns */
    int completed;
    int writes;
    SarAimWrite aim[2];
} SarLease;
typedef struct SarAimRecord
{
    int used;
    uint32_t id;
    SarRow snapshot;                 /* the row last seen under this instance */
    uint32_t node;
    uint8_t source_point[12];
    int has_raw;
    uint8_t raw[12], computed[12];   /* the tracked aim to hold */
    SarLease lease;
    uint32_t seen;
} SarAimRecord;

int sar_aim_step(SarRow* const* rows, int count, const char** why);
/* M.release: 1 restored or nothing to restore (*why says which), 0 not all restored. */
int sar_aim_release(SarLease* lease, const char** why);
/* stop_aim: every hold released (one that could not be stays); 1 all. */
int sar_aim_stop(void);

/* ---- fire pauses and target searches (sentry_fire.c) ------------------------------------------------------------- */

#define SAR_REASON_NONE 0
#define SAR_REASON_AIM_PENDING 1
#define SAR_REASON_TARGET_LOST 2
#define SAR_REASON_TERRAIN_BLOCKED 3
#define SAR_REASON_SWEEP 4
typedef struct SarFireRecord
{
    int used;
    uint32_t id;
    SarRow snapshot;                 /* the row last seen under this id (also the lease's and the request's) */
    int has_anchor;
    double anchor[3];
    double error, travel;
    int synced;
    int has_settled, has_sweep;
    double settled_since, sweep_since;
    int has_terrain_target;
    uint32_t terrain_target;
    int terrain_blocked;             /* SAR_UNKNOWN, 0, 1 */
    int has_checked;
    double terrain_checked_at;
    int reason;
    int paused;                      /* the fire lease: this module set the no-fire mode */
    uint32_t mode;                   /* the mode it saved */
    int handoff;
    int requested;                   /* the selection lease: a shortened deadline */
    uint8_t before[8], after[8];
    int completed;
    int armed;
    double last_selection;
    uint32_t seen;
} SarFireRecord;

int sar_fire_step(SarRow* const* rows, int count, double now, const char** why);
int sar_selection_step(SarRow* const* rows, int count, const char** why);
/* M.fire_geometry: 1 with the muzzle's forward vector and the aim's angle from it in degrees, or 0 with *why. */
int sar_fire_geometry(const SarRow* row, double forward[3], double* angle, const char** why);
/* M.release_fire and M.release_selection for a record: 1 restored (or no longer ours), 0 not. */
int sar_release_fire(const SarFireRecord* record);
int sar_release_selection(const SarFireRecord* record);
/* stop_fire: every request and pause restored (one that could not be stays); 1 all. */
int sar_fire_stop(void);

/* ---- the component's state (archive_loader.lua's) ---------------------------------------------------------------- */

typedef struct SarState
{
    uint32_t updates, polls, observed, holding, holds, releases, late_aim;
    uint32_t fire_paused, fire_pauses, fire_resumes, reselections, selections;
    uint32_t aim_stamp, fire_stamp;
    SarAimRecord records[SAR_MAX_RECORDS];
    SarFireRecord fire_records[SAR_MAX_RECORDS];
} SarState;
extern SarState sar_state;

/* The record of a sentry id, or NULL. */
SarAimRecord* sar_aim_record(uint32_t id);
SarFireRecord* sar_fire_record(uint32_t id);

/* Copies: rows are compared as the Lua compared strings. */
int sar_same_bytes(const void* a, const void* b, size_t size);
uint32_t sar_u32(const uint8_t* at);
float sar_f32(const uint8_t* at);
int sar_finite(double value);

#endif
