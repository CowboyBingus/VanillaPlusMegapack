/* Consistent Vaulting: the interface between its files (consistent_vaulting.c has the overview).
 *
 * Errors. Every function that can raise (the Lua's assert and error) returns CV_RAISED with the reason in cv_error();
 * the checks that call it turn that into the Lua's outcome: a waiting status (a snapshot that raised), a refusal (a
 * plan or retry that raised), or an error of the check, which restores everything and starts fresh. A function that can
 * also answer "nil and why" returns 0 with *why set, and 1 when it found what it looked for. CV_TRY passes on anything
 * but 1. */
#ifndef CV_H
#define CV_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"

#define CV_INVALID 0xFFFFFFFFu
#define CV_RAISED (-1)
#define CV_PI 3.14159265358979323846
#define CV_TRY(call) do { int cv_try_ = (call); if (cv_try_ != 1) return cv_try_; } while (0)

#define CV_HITS 10
#define CV_HIT_SIZE 44u
#define CV_RECORD_SIZE 128u
#define CV_CONTROLLER_SIZE 0x2B0u
#define CV_CONTROLLER_SPAN 0x1E8u /* every query write lies in [controller, controller + 0x1E8): the phase and the hits */
#define CV_MAX_WRITES 12
#define CV_GUARDS 512
#define CV_GUARD_BYTES 12288u

/* game.dll globals beside the core's VPM_RVA_* */
#define CV_RVA_MODE 0x33266A0u     /* the mode record: +8 nonzero and +0x40 in 1 .. 7 in a mission */
#define CV_RVA_MOVEMENT 0x3326558u
#define CV_RVA_CAMERA 0x346D560u
#define CV_RVA_WORLD 0x346BFA0u
/* the avatar manager's per-avatar rows (+ ai * 0x1238) */
#define CV_AT_CONTROLLER 0x53E1B8u /* the vault controller: phase +4, query IDs +8, hits +0x30, avatar ID +0x2AC */
#define CV_AT_FLAGS 0x53E880u      /* the movement flags (24 bytes) */
#define CV_AT_DIRECTION 0x53E134u  /* the movement direction state: speed cap +8, avatar ID +40 */
#define CV_AVATAR_STRIDE 0x1238u
#define CV_ACTION_CLIMB 14u        /* the manual vault input's action slot */

/* ---- numbers, errors (cv_memory.c) ------------------------------------------------------------------------------ */

int cv_raise(const char* text);
const char* cv_error(void);
static inline int cv_why(const char** why, const char* text) { *why = text; return 0; }
uint16_t cv_u16(const uint8_t* at);
uint32_t cv_u32(const uint8_t* at);
uint64_t cv_u64(const uint8_t* at);
void cv_put_u32(uint8_t* at, uint32_t value);
/* The float at `at` as a double (the Lua's number()), and a double rounded to float32 (the Lua's f32()). */
double cv_num(const uint8_t* at);
double cv_f32(double value);
void cv_put_f32(uint8_t* at, double value);
/* Not NaN and smaller than 100000 (the Lua's finite()). */
int cv_finite(double value);
int cv_finite3(const double* v);
/* The Lua's vector(): three floats, 1, or CV_RAISED ("Invalid vector") unless all are finite. */
int cv_vector(const uint8_t* at, double* out);
/* api.pointer's rule: the little-endian pointer at `at`, 1 when it is at least 0x10000 and below 2^47. */
int cv_pointer(const uint8_t* at, uintptr_t* out);
/* The unit/actor pair of a hit (8 bytes). */
void cv_pair(uint8_t* at, uint32_t unit, uint32_t actor);

/* ---- memory ------------------------------------------------------------------------------------------------------ */

/* A read the way the Lua made it: game.dll's and the exe's images by plain loads, the heap through vpm_read. 1/0. */
int cv_load(uintptr_t address, void* out, size_t size);
/* api.read(address, size) == bytes (size at most 1024). */
int cv_matches(uintptr_t address, const void* bytes, size_t size);
/* The protection check of a store's target: one VirtualQuery the first time a span is seen, then remembered (the Lua
 * checked before every write). 1 writable. */
int cv_writable(uintptr_t address, size_t size);
/* A plain store into game data whose span cv_writable accepted. */
void cv_store(uintptr_t address, const void* bytes, size_t size);
/* cv_writable and a plain store: 1 stored, 0 refused. */
int cv_write(uintptr_t address, const void* bytes, size_t size);
#ifdef VPM_TEST
/* Tests: the stores made and the protection checks (VirtualQuery) that the remembered spans did not answer. */
typedef struct CvTestCounts { uint32_t stores, queries; } CvTestCounts;
CvTestCounts* cv_test_counts(void);
/* Tests: the candidate search's answer instead of cv_assist_candidate (the Lua tests' A.candidate), until NULL. */
void cv_test_candidate(int (*candidate)(int* kind));
#endif
void cv_memory_reset(void);
/* The manual vault input of avatar index ai (vpm_action_slot's address, slot 14). */
uintptr_t cv_input_address(uintptr_t manager, uint32_t ai);

/* ---- guards: snapshot reads, verified again before writes -------------------------------------------------------- */

typedef struct CvTexts { const char* unavailable; const char* pointer; const char* map; const char* movement; } CvTexts;
extern const CvTexts cv_vault_texts; /* "Game data unavailable", "Game pointer unavailable", ... */
extern const CvTexts cv_slope_texts; /* "Slope data unavailable", "Slope pointer unavailable", ... */

typedef struct CvGuard { uintptr_t address; uint16_t at, size; uint8_t epoch; } CvGuard;
typedef struct CvGuards
{
    const CvTexts* texts;
    int count;
    uint32_t used;
    CvGuard list[CV_GUARDS];
    uint8_t bytes[CV_GUARD_BYTES];
} CvGuards;

void cv_guards_reset(CvGuards* guards, const CvTexts* texts);
/* Appends a guard holding these bytes (NULL: left for the caller to fill); its bytes, or NULL when full. */
uint8_t* cv_guard_add(CvGuards* guards, uintptr_t address, const void* bytes, size_t size, int epoch);
/* A snapshot read that becomes a guard (epoch: also an epoch guard): 1 with *bytes, or CV_RAISED. */
int cv_guard_read(CvGuards* guards, uintptr_t address, size_t size, int epoch, uint8_t** bytes);
/* The pointer stored at address, read as a guard. */
int cv_guard_pointer(CvGuards* guards, uintptr_t address, int epoch, uintptr_t* out);
/* Every guard (epoch_only: every epoch guard) still holds its bytes: one read each. */
int cv_guards_hold(const CvGuards* guards, int epoch_only);

/* The game's hash map: a 20-byte header {rows, capacity, empty key, multiplier}, rows {key, value} probed linearly from
 * key * multiplier, at most min(capacity, 128) probes. The rows come from read_row (1, or CV_RAISED). */
typedef int (*CvRowFn)(void* context, uintptr_t address, uint32_t* row);
typedef struct CvMap { uint32_t key, limit; CvRowFn read_row; void* context; const CvTexts* texts; } CvMap;
/* 1 with *value, 0 absent, CV_RAISED (an unsupported map or an unreadable row). */
int cv_probe(const CvMap* map, const uint8_t* header, uint32_t* value);
/* The same over guard reads: the header and every row probed become guards. */
int cv_lookup(CvGuards* guards, uintptr_t header, uint32_t key, uint32_t limit, uint32_t* value);

/* The local movement and mover records (the movement global, its map, both records). records_guarded: the records
 * themselves become guards too (the vault snapshot's reads; the slope snapshot's are plain reads). */
typedef struct CvMovement { uint8_t move[132]; uint8_t mover[164]; uintptr_t mover_address; } CvMovement;
int cv_movement(CvGuards* guards, uint32_t id, int records_guarded, CvMovement* out);

/* ---- the vault snapshot (cv_vault.c) ---------------------------------------------------------------------------- */

typedef struct CvHit
{
    int slot;
    uintptr_t address;  /* the hit in the local controller: controller + 0x30 + 44 * slot */
    uintptr_t row;      /* its scheduler record */
    uint8_t bytes[CV_HIT_SIZE];
    uint32_t count;     /* the result count (0 or 1) */
    double position[3];
    double normal_z;
    uint32_t unit, actor;
    uint8_t record[CV_RECORD_SIZE]; /* the query descriptor this hit was cast with */
} CvHit;

typedef struct CvVault
{
    CvGuards guards;
    uint32_t stage;
    uintptr_t controller, input_address, flags_address, entity, world;
    uint8_t manual_bytes;
    int manual, prior_step_report, rebuild_queries, reprojected, ground, has_min_height, hit_count;
    uint8_t controller_bytes[CV_CONTROLLER_SIZE];
    CvHit hits[CV_HITS];
    double normal_threshold, max_height, min_height, ground_reach;
    double root[3], direction[3];
    uint32_t unit, mover_name;
} CvVault;

typedef struct CvWrite { uintptr_t address; uint32_t size; uint8_t before[CV_HIT_SIZE], after[CV_HIT_SIZE]; } CvWrite;
typedef struct CvPending { CvVault* snapshot; CvWrite writes[CV_MAX_WRITES]; int count; } CvPending;

/* ---- the slope snapshot (cv_identity.c) -------------------------------------------------------------------------- */

typedef struct CvKey { uint32_t ref, id, unit; uintptr_t owner, manager; } CvKey;
enum { CV_CAP, CV_SLOPE, CV_ENTER, CV_EXIT, CV_HEIGHT, CV_CELLS };

typedef struct CvSlope
{
    int idle;              /* the light snapshot of a released input (the Lua's IDLE): manual 0 and vault_phase only */
    int manual;
    uintptr_t vault_phase; /* the avatar's vault controller phase word */
    CvGuards guards;       /* the slope check's own guards */
    CvGuards identity;     /* the identity chain's reads, which the vault snapshot of the same check takes over */
    uintptr_t entity;      /* the entity record's address */
    uint32_t ai;
    CvKey key;
    uint8_t entity_bytes[24];
    uintptr_t manager, object;
    uint32_t handle, mover_name, override_count;
    uintptr_t cells[CV_CELLS];   /* the cells an assist may write; enter, exit and height 0 without an override */
    uint8_t values[CV_CELLS][4]; /* their bytes as read */
    int has_value[CV_CELLS];
    double walk, enter, exit, ground_max, normal_z, root[3];
    int climbing, eligible, ground;
} CvSlope;

/* ---- the check's state (the Lua's state table) ------------------------------------------------------------------ */

#define CV_UNSET (-1) /* a Lua nil beside false and true */
enum { CV_KIND_SLOPE = 1, CV_KIND_LEDGE = 2 };
enum { CV_PHASE_ATTEMPT, CV_PHASE_CLIMB, CV_PHASE_SUPPORT };

typedef struct CvLeaseWrite { int cell; uint8_t before[4], after[4]; int partial; } CvLeaseWrite;
typedef struct CvLease
{
    CvKey key;
    uint32_t handle;
    uintptr_t object;
    double anchor[3], started, air_since, flat_since;
    int kind, phase, count, speed_capped, has_air, has_flat;
    CvLeaseWrite writes[4];
} CvLease;

typedef struct CvIntent { CvKey key; double deadline, checked; int has_checked; } CvIntent;

/* The Lua's diagnostics counters that its tests check (not logged: the heartbeat file was developer-only). */
typedef struct CvCounters
{
    uint32_t polls, prepared, metadata_fallbacks, fresh_queries, retry_calls, native_starts, context_reprojections,
        query_rebuilds, reprojected_retries, reprojected_starts, step_report_retries, step_report_starts, slope_arms,
        slope_overrides, slope_climbs, slope_landings, candidate_checks, raised_queries, raised_context_fallbacks,
        raised_approach_rebuilds, ledge_arms, ledge_climbs, ledge_attempt_expiries;
} CvCounters;

typedef struct CvState
{
    double now;          /* seconds from dt (the Lua's api.time()) */
    CvPending pending;   /* the query writes in place (has_pending) */
    CvLease lease;       /* the slope assist (has_lease) */
    CvIntent intent;     /* a fresh press's search window (has_intent) */
    int has_pending, has_lease, has_intent;
    int slope_down;      /* CV_UNSET, 0, 1: the input as the last slope check saw it */
    int busy;            /* CV_UNSET, 0, 1: work in progress after the last check */
    int has_retry;
    double last_retry_at;
    CvSlope* avatar;     /* this check's slope snapshot, for the vault check that follows */
    int avatar_outside;  /* the slope check found no mission (the Lua's state.avatar = false) */
    uint32_t observed_queries;
    const char* slope_status;
    const char* slope_last_release;
    CvCounters counters;
} CvState;

void cv_state_reset(CvState* st);

/* ---- natives (cv_native.c, cv_native.h) ------------------------------------------------------------------------- */

typedef struct CvActor { int valid; uint32_t flags; double motion_squared; } CvActor;
enum { CV_APPROACH_MATCHED = 1, CV_APPROACH_BLOCKED = 2, CV_APPROACH_CHANGED = 3 };
/* The game functions, bound and checked once per session (1, or CV_RAISED as the Lua's api.native raised). */
int cv_native_bind(void);
void cv_native_reset(void);
/* native.actor: 1 with *out, 0 when the actor became invalid during the calls (the Lua's nil). */
int cv_native_actor(uint32_t id, CvActor* out);
int cv_native_mover_position(uint32_t unit, uint32_t name, double* out);
int32_t cv_native_exit(uintptr_t entity, const double* target, const double* direction);
/* native.context_matches: CV_APPROACH_*; fresh gets the approach (matched or changed). fresh must not be controller. */
int cv_native_context(const uint8_t* controller, uint8_t* fresh);
/* native.raised_approach: NULL with fresh filled, or why not. */
typedef struct CvRaisedArgs { const uint8_t* controller; uint32_t unit, name; const double* direction; double reach; } CvRaisedArgs;
const char* cv_native_raised(const CvRaisedArgs* args, uint8_t* fresh);
void cv_native_basis(const double* direction, uint8_t* matrix);
/* native.refresh_query: the private cast's 44-byte result and its count (0 or 1). */
uint32_t cv_native_refresh(const uint8_t* record, uintptr_t world, uint8_t* out);
void cv_native_retry(uintptr_t controller);
int cv_native_ensure_override(uintptr_t manager, uintptr_t entity);

/* ---- the vault snapshot and check (cv_vault.c, cv_commit.c, cv_refresh.c) -------------------------------------- */

typedef struct CvVaultArgs { const CvPending* held; const CvSlope* avatar; int discovery; } CvVaultArgs;
/* M.snapshot: 1, 0 with *why, CV_RAISED. */
int cv_vault_snapshot(CvVault* s, const CvVaultArgs* args, const char** why);
/* The three snapshot records: two used in turn by the checks (a kept write holds the other), one for the candidate
 * search. */
CvVault* cv_vault_record(int index);
int cv_hit_take(CvHit* hit, const uint8_t* bytes, uint32_t count);

typedef struct CvSelection { int slot, metadata; } CvSelection;
/* M.plan's selection: 1 with *selection, 0 none, CV_RAISED. */
int cv_select(CvVault* s, CvSelection* selection);
int cv_same_epoch(const CvVault* s);
int cv_restore(const CvPending* pending);
int cv_out_of_reach(const CvVault* s, const CvHit* hit);
int cv_context_still(const CvVault* s);
/* The previous check's prepared writes while their epoch holds; a changed epoch (a consumed or reused batch) drops them
 * unwritten, as cv_restore does. Read first in every check. */
const CvPending* cv_held_writes(CvState* st);
/* The vault half of a check (after the slope step): 1 accepted, 0 refused, CV_RAISED; *reason. */
int cv_vault_apply(CvState* st, const CvPending* held, const CvSlope* avatar, int outside, const char** reason);
/* M.stop: 1 when everything this component changed is back. */
int cv_stop(CvState* st);

/* M.refresh: 1 with originals[i] (each hit's bytes before its fresh cast), 0 with *why (*approach: the native
 * approach's reason for rebuilt queries), CV_RAISED. */
int cv_refresh(CvVault* s, CvCounters* counters, uint8_t (*originals)[CV_HIT_SIZE], const char** why, const char** approach);
/* M.reproject from a fresh approach: 1, or 0 with *why. */
int cv_reproject(CvVault* s, const uint8_t* fresh, const char** why);
/* M.assist_candidate: 1 with *kind and *reason, 0 with *reason, CV_RAISED. */
int cv_assist_candidate(CvState* st, const CvSlope* owner, int* kind, const char** reason);

/* ---- the slope assist (cv_identity.c, cv_slope.c) --------------------------------------------------------------- */

/* A.snapshot: 1 (s->idle for a released input's light snapshot), 0 with *why, CV_RAISED. */
int cv_slope_snapshot(CvSlope* s, const CvKey* key, int light, int verify, const char** why);
int cv_slope_guarded(const CvSlope* s);
/* Whether the last snapshot replaced a kept identity with another one (cleared by the call). */
int cv_identity_renewed(void);
/* The input address of the avatar the last snapshot found. */
uintptr_t cv_identity_input(void);
void cv_identity_reset(void);
/* A.step: 1 accepted, 0 refused with *reason, CV_RAISED. */
int cv_slope_step(CvState* st, const char** reason);
int cv_slope_stop(CvState* st);
/* The idle gate (A.idle) and its arming after a check (A.settle). */
int cv_slope_idle(const CvState* st);
void cv_slope_settle(int idle);
void cv_slope_reset(void);

/* ---- the check (consistent_vaulting.c) -------------------------------------------------------------------------- */

/* M.apply: one check. */
int cv_check(CvState* st, const char** reason);

#ifdef VPM_TEST
CvState* cv_test_state(void);
#endif

#endif
