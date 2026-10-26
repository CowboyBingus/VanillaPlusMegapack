/* Enemy Collision Synchronized: what its files share. The component, its tick and its cost: enemy_collision_synchronized.c.
 *
 *   ecs_profiles.c  the corpse profile catalogue (the Lua's corpse_profiles.lua) and its lookups
 *   ecs_pose.c      matrices, rigid poses and the repair planner (the Lua's M.rigid, M.plan)
 *   ecs_reads.c     a poll's counted reads, its per-poll cache, and guard lists (the Lua's read, cached, guard, same)
 *   ecs_tables.c    the kept records: motion history, stops, cooldowns, corpse re-check backoff
 *   ecs_listing.c   which manager entries hold a listed resource, kept across polls (the Lua's listing)
 *   ecs_reader.c    the mission check, both managers, the scan and its budget (the Lua's scan_poll)
 *   ecs_inspect.c   one unit read and checked in full (the Lua's inspect)
 *   ecs_motion.c    renewed-motion containment (the Lua's M.fling_action)
 *   ecs_apply.c     a poll: the commands for each unit and the bookkeeping around them (the Lua's M.apply, consume)
 *   ecs_natives.c   the checked game routines and the commands they issue (the Lua's api.bind) */
#ifndef ECS_INTERNAL_H
#define ECS_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"

/* ---- the Lua's tunables (corpse_data.lua M, archive_loader.lua) ------------------------------------------------- */

#define ECS_INTERVAL (3.0 / 64.0)          /* seconds of frame time between polls */
#define ECS_MAX_ENTITIES 128u              /* listed entries visited per poll, both managers together */
#define ECS_MAX_UNITS 4u                   /* units inspected in full per poll */
#define ECS_BUDGET_SECONDS 0.001           /* the soft deadline from a poll's first inspection */
#define ECS_COMPLETION_GRACE 1.0           /* seconds after a remote stop before the owner is asked to convert */
#define ECS_CORPSE_SETTLE_POLLS 24u        /* clean inspections before a corpse's re-checks back off */
#define ECS_CORPSE_RECHECK_POLLS 64u       /* the longest wait between two re-checks */
#define ECS_REPOSE_COOLDOWN 1.0            /* a small repeated realignment of one actor waits this long */
#define ECS_REPOSE_BYPASS_M 0.1
#define ECS_REPOSE_BYPASS_DEGREES 5.0
#define ECS_POLL_ERRORS 8u                 /* raised polls in a row that stop the component */

/* ---- the catalogue (ecs_profiles.c) ------------------------------------------------------------------------------ */

#define ECS_PROFILE_COUNT 21
#define ECS_MAX_BODIES 16                  /* the largest profile has 15 main bodies */

typedef struct EcsActorNode { uint32_t name, node; } EcsActorNode;
typedef struct EcsProfile
{
    const char* name;
    uint64_t resource;              /* the entity resource: an entity header's first 8 bytes */
    uint32_t nodes, bodies;         /* skeleton nodes; main bodies (RagdollSync's) */
    int finish_disabled;            /* tripods: every main body is disabled on landing */
    int impaler;                    /* its three claw actors are disabled, not posed */
    const uint32_t* main;           /* the main bodies' actor names, in the runtime record's order */
    const uint32_t* dynamic_main;   /* main bodies a Corpse may keep dynamic (corpse_dynamic_main) */
    uint32_t dynamic_count;
    const uint32_t* disabled_main;  /* main bodies the game disables on purpose */
    uint32_t disabled_count;
    const EcsActorNode* actors;     /* auxiliary actor name -> skeleton node hash, sorted by name */
    uint32_t actor_count;
} EcsProfile;

extern const EcsProfile EcsProfiles[ECS_PROFILE_COUNT];
/* The profile of an entity resource, or -1. */
int EcsProfileOf(uint64_t resource);
int EcsProfileMain(const EcsProfile* profile, uint32_t name);
int EcsProfileDisabledMain(const EcsProfile* profile, uint32_t name);
int EcsProfileDynamicMain(const EcsProfile* profile, uint32_t name);
/* 1 with *node set when the actor name is allowlisted. */
int EcsProfileActor(const EcsProfile* profile, uint32_t name, uint32_t* node);
/* One of the Impaler's three tentacle claw actors. */
int EcsClaw(uint32_t name);

/* ---- poses (ecs_pose.c) ------------------------------------------------------------------------------------------ */

typedef struct EcsPose { double p[3], q[4]; } EcsPose; /* position XYZ, rotation quaternion XYZW */

/* 16 IEEE singles (a node or body matrix, column-major) as doubles. */
void EcsDecodeMatrix(const uint8_t* bytes, double out[16]);
/* The rigid pose of a matrix (skeletal scale removed): 1, or 0 when it is not a finite orthonormal right-handed basis. */
int EcsRigid(const double m[16], EcsPose* out);
/* Distance (m) and angle (degrees) between a pose and a kept position and rotation. */
void EcsSeparation(const EcsPose* pose, const double position[3], const double rotation[4], double* distance, double* degrees);
/* The body's pose relative to the root's: 1, or 0 when the body's matrix is not rigid. */
int EcsRelativePose(const EcsPose* root, const double m[16], EcsPose* out);
double EcsDegrees(double radians);

/* ---- a poll's reads and guard lists (ecs_reads.c) ------------------------------------------------------------- */

/* A guard: bytes as read at an address this poll, compared again before a command depends on them. */
typedef struct EcsGuard { uintptr_t address; uint32_t size, at; } EcsGuard;
typedef struct EcsGuards
{
    EcsGuard* items;
    uint8_t* bytes;
    uint32_t count, capacity, used, room;
} EcsGuards;

void EcsGuardsInit(EcsGuards* list, EcsGuard* items, uint32_t capacity, uint8_t* bytes, uint32_t room);
void EcsGuardsClear(EcsGuards* list);
/* 1 added, 0 raised (the list is full). */
int EcsGuardAdd(EcsGuards* list, uintptr_t address, const void* bytes, uint32_t size);
int EcsGuardAppend(EcsGuards* list, const EcsGuards* from);
/* Whether every guarded span still holds its bytes: one read per group of nearby heap guards (within 128 bytes of each
 * other, 4096 at most), a plain load for spans in game.dll's or the exe's image. Never raises. */
int EcsSame(const EcsGuards* list);

/* "Raising" (the Lua's error inside a poll): the function returns 0 (or -1) with the reason kept here. */
int EcsRaise(const char* why);
int EcsRaisef(const char* format, ...) __attribute__((format(printf, 1, 2)));
const char* EcsWhy(void);

/* A poll's read budget (4 MB, 18000 calls) and its cache; per poll. */
void EcsReadsBegin(void);
void EcsReadTotals(uint32_t* bytes, uint32_t* calls);
/* A counted heap read: 1, or 0 after a raise ("Data unavailable", the budget). */
int EcsRead(uintptr_t address, void* out, size_t size);
/* A counted read kept for the rest of the poll (the Lua's cached): the bytes, valid until the next EcsCached call, or
 * NULL: raised, or with optional, unreadable (remembered for the poll). */
const uint8_t* EcsCached(uintptr_t address, uint32_t size, int optional);
/* An uncounted heap read (the Lua's view): 1 read, 0 not. */
int EcsCapture(uintptr_t address, void* out, size_t size);
/* EcsRead, then the bytes as a guard. */
int EcsGuardRead(EcsGuards* list, uintptr_t address, void* out, uint32_t size);
/* A plain load inside game.dll's or the exe's image: 1, or 0 when [address, address + size) is in neither. */
int EcsImageRead(uintptr_t address, void* out, size_t size);
/* A pointer the Lua's api.pointer accepts (0x10000 .. 2^47), or 0. */
uintptr_t EcsPointer(uint64_t value);
uint32_t EcsU32(const uint8_t* at);
uint64_t EcsU64(const uint8_t* at);

/* ---- one inspected unit (ecs_inspect.c fills it, ecs_apply.c consumes it) ---------------------------------------- */

#define ECS_MAX_ACTORS 128u
#define ECS_MAX_REGISTERED 160u
#define ECS_UNIT_GUARDS 224u
#define ECS_UNIT_GUARD_BYTES 6144u

typedef struct EcsSignature { uint32_t count; uint32_t ids[ECS_MAX_BODIES]; } EcsSignature; /* count 0: none (a corpse) */

/* An auxiliary actor M.plan could act on, with the bytes its command guards are made from. */
typedef struct EcsActor
{
    uint32_t id, name, node, node_hash, motion;
    int enabled, registered, same_pose; /* same_pose: the body's matrix bytes equal its node's */
    double pose[16], node_pose[16];
    uintptr_t identity_address, data_address, body_address;
    uint8_t identity[4], data[40], body[160];
} EcsActor;

typedef struct EcsMainBody { uint32_t id; double pose[16]; } EcsMainBody;

typedef struct EcsUnit
{
    int profile;                  /* EcsProfiles index */
    uint32_t id, unit;            /* the entity id (header +8) and unit handle (+12) */
    int corpse, owner, active;    /* owner: header +20 bit 0; active: index below the manager's active count */
    uint64_t address;             /* the entity's address (the listing's key) */
    uintptr_t manager;
    uint32_t index;
    int settled;
    int update_enabled;           /* the runtime's update byte; -1 for a corpse (the Lua's nil) */
    uintptr_t update_address;
    uint32_t main_enabled, main_static, main_disabled, main_dynamic_allowed;
    EcsSignature signature;       /* the runtime's main members, in order (ragdolls) */
    uint32_t members[ECS_MAX_BODIES], member_names[ECS_MAX_BODIES], member_count;
    uint32_t registered[ECS_MAX_REGISTERED], registered_count;
    uint32_t root_id;
    int has_root_id, root_body;   /* root_body: main_bodies index, or -1 */
    EcsMainBody main_bodies[ECS_MAX_BODIES];
    uint32_t main_body_count;
    EcsActor actors[ECS_MAX_ACTORS];
    uint32_t actor_count;
    EcsGuards guards, pose_guards;
    int verified;                 /* its guards held just now, with no native call since */
} EcsUnit;

/* ---- kept records (ecs_tables.c) --------------------------------------------------------------------------------- */

/* An open-addressing table of fixed records by a 64-bit key (unit handles, actor ids). */
typedef struct EcsTable
{
    uint64_t* keys;
    uint8_t* used;
    uint8_t* records;
    uint32_t record_size, capacity, count;
} EcsTable;

void* EcsTableFind(const EcsTable* table, uint64_t key);
/* The key's record (zeroed when new, *added 1), or NULL when the table is half full. */
void* EcsTablePut(EcsTable* table, uint64_t key, int* added);
void EcsTableRemove(EcsTable* table, uint64_t key);
/* Slot-wise iteration: the record in a slot (NULL when empty); removing a slot's record keeps the slot to look at again. */
void* EcsTableSlot(const EcsTable* table, uint32_t slot, uint64_t* key);
void EcsTableRemoveSlot(EcsTable* table, uint32_t slot);
void EcsTableClear(EcsTable* table);

typedef struct EcsLimb { uint32_t id; int excursing; double position[3], rotation[4], excursion_since; } EcsLimb;
typedef struct EcsHistory    /* by unit: a settled remote ragdoll's motion baseline */
{
    int disabled;            /* the landed-disabled form (tripods) */
    uint32_t entity, actor, enabled, samples;
    int profile, armed;
    EcsSignature members;
    double position[3], rotation[4];
    EcsLimb limbs[ECS_MAX_BODIES];
    uint32_t limb_count;
    double since, last;
} EcsHistory;
typedef struct EcsStop       /* by unit: a verified stop this session made */
{
    uint32_t entity, last_scan;
    int profile, requested;
    EcsSignature members;
    double stopped_at;
} EcsStop;
typedef struct EcsRepose { uint32_t unit, entity; double at; } EcsRepose; /* by actor id: the last realignment */
typedef struct EcsCheck { uint64_t address; uint32_t entity, since, wait, due, seen; } EcsCheck; /* by unit: a clean corpse */

extern EcsTable EcsHistories, EcsStops, EcsReposes, EcsChecks;
void EcsTablesReset(void);

/* ---- the listing (ecs_listing.c) ------------------------------------------------------------------------------- */

#define ECS_UNKNOWN (-2)  /* not classified */
#define ECS_UNLISTED (-1)
#define ECS_MAX_RAGDOLLS 2048u
#define ECS_MAX_CORPSES 512u

typedef struct EcsEntry { uint64_t address; uint32_t stamp, unit; int16_t key; uint8_t has_unit, used; } EcsEntry;
typedef struct EcsListing
{
    EcsEntry* table;
    uint32_t capacity, size, stamp, sweep, count, n;
    uint16_t* listed;           /* the listed entry indices, ascending */
    uint64_t* kept;             /* the pointer array it was built from, when complete */
    uint32_t kept_count;
    int kept_valid, complete;
} EcsListing;

EcsListing* EcsListingOf(int corpse);
EcsEntry* EcsListingFind(EcsListing* listing, uint64_t address);
/* The entity address at an entry of this poll's pointer array, or 0 when it is not a user address. */
uint64_t EcsAddressAt(const uint64_t* pointers, uint32_t index);
/* Rebuilds the listed indices when the array changed; the rolling verification of a few known headers. */
void EcsListingRefresh(EcsListing* listing, const uint64_t* pointers, uint32_t count, int first);
void EcsListingsReset(void);

/* ---- the reader (ecs_reader.c, ecs_inspect.c) --------------------------------------------------------------------- */

/* One scan of both managers, each inspected unit handed to EcsConsume: 1 (with *ready: in a mission), 0 raised. */
int EcsScanPoll(int* ready);
/* The physics world of an index (0 .. 3) for this poll: 1 with *world (0: none yet), 0 raised. */
int EcsWorldFor(uint32_t index, uintptr_t* world);
void EcsReaderBegin(void);

/* A listed, eligible manager entry, with what the poll read before its inspection. */
typedef struct EcsVisit
{
    uint32_t index, quick, active;  /* the entry; a ragdoll's sync count its eligibility check read; the active count */
    int corpse, profile;
    uint64_t address;               /* the entity */
    uintptr_t manager, entities, runtime, sync, mode;
    const uint8_t* header;          /* its 24-byte header, read just now */
    uint64_t pointer;               /* its pointer array entry (entities + index * 8) as read this poll */
    uint64_t mode_slot;             /* the mode slot (game.dll 0x33266A0) as read this poll */
    const uint8_t* mode_bytes;      /* the mode block (0x44 bytes) */
} EcsVisit;

/* Reads and checks one listed, eligible unit into *unit: 1 ready, 0 it does not qualify this poll, -1 raised. */
int EcsInspect(const EcsVisit* visit, EcsUnit* unit);
/* Forgets the poll's decoded actor pools and body arrays. */
void EcsInspectBegin(void);
#define ECS_MODE_SLOT_RVA 0x33266A0u  /* game.dll: the mission mode block (+8: the mission flag) */

/* ---- motion containment (ecs_motion.c) ---------------------------------------------------------------------------- */

#define ECS_CAUSE_TRANSLATION 1
#define ECS_CAUSE_ROTATION 2
#define ECS_CAUSE_LIMB_TRANSLATION 3
#define ECS_CAUSE_LIMB_ROTATION 4
#define ECS_CAUSE_LANDED_DISABLED 5

typedef struct EcsStopCall
{
    int cause;
    uint32_t actor;
    double distance, degrees, limb_distance, limb_degrees;
    int limb;
} EcsStopCall;

/* Whether a unit is settled: every main body accounted for and every enabled one static. */
int EcsSettled(const EcsUnit* unit);
/* 1 with *stop when a settled remote ragdoll's renewed motion calls for a stop now; 0 otherwise (history kept or
 * forgotten as the Lua's M.fling_action does). */
int EcsFlingAction(const EcsUnit* unit, double now, EcsStopCall* stop);
const char* EcsCauseName(int cause);

/* ---- the repair planner (ecs_pose.c) ---------------------------------------------------------------------------- */

#define ECS_DISABLE 1
#define ECS_REPOSE 2
typedef struct EcsAction { int kind; uint32_t actor; double position[3], rotation[4], gap, degrees; } EcsAction;
/* The commands a unit needs (M.plan): their number, actions[] filled (room for ECS_MAX_ACTORS). */
uint32_t EcsPlan(const EcsUnit* unit, EcsAction* actions);

/* ---- a poll (ecs_apply.c) ------------------------------------------------------------------------------------------- */

/* One inspected unit: its commands (1), or 0 raised. */
int EcsConsume(EcsUnit* unit);
/* One poll (M.apply): 1 with *ready, or 0 raised (EcsWhy says why). It is EcsApplyBegin (the poll count, expiries,
 * prunes, the budget), the scan, then EcsApplyEnd (the totals; outside a mission, the first poll's reset). */
int EcsApply(int* ready);
void EcsApplyBegin(void);
void EcsApplyEnd(int ready);
/* A fresh start (M.reset): no history, stop, scan position, cooldown, listing or backoff. */
void EcsReset(void);

/* ---- the game's routines (ecs_natives.c) ------------------------------------------------------------------------- */

typedef struct EcsNatives
{
    void (*stop_sync)(void* manager, uint32_t index);                    /* game.dll 0x7ABD00 */
    void (*request_completion)(void* service, uintptr_t zero, uint32_t entity); /* game.dll 0x13C0350 */
    void (*set_position)(uint32_t actor, const float* position);          /* exe 0x799880 */
    void (*set_rotation)(uint32_t actor, const float* rotation);          /* exe 0x799BA0 */
    void (*set_enabled)(const uint32_t* actors, uint32_t count, uint32_t enabled); /* exe 0x77F4F0 */
    double (*clock)(void);                                                /* seconds: the poll's work budget */
} EcsNatives;

/* The reviewed bytes: both setters' first 8 (the exe's), the whole stop and completion routines in parts. */
extern const VpmCodePin EcsCodePins[];
extern const int EcsCodePinCount;
/* Hands EcsCodePins to the core's wait (from start()): EcsBind binds nothing before they read as shipped. 1, or 0
 * refused. */
int EcsWaitForCode(VpmComponent* self);
/* The checks of the Lua's api.bind (the physics API table; both setters' first bytes and the whole stop and completion
 * routines are the core's wait): 1 bound, 0 not yet (the code is not decoded, or the game has not set up its physics
 * API), -1 refused (vpm_fail called). */
int EcsBind(VpmComponent* self);
/* For the tests: these instead of the game's routines once the checks pass (NULL: the game's). */
void EcsUseNatives(const EcsNatives* replacement);
double EcsClock(void);
void EcsStopSync(uintptr_t manager, uint32_t index);
/* 1 requested, 0 raised (the completion service is not readable). */
int EcsRequestCompletion(uint32_t entity);
void EcsSetPose(uint32_t actor, const double position[3], const double rotation[4]);
void EcsDisableActor(uint32_t actor);

/* ---- the component's state and counters (the Lua's state table) ------------------------------------------------ */

typedef struct EcsState
{
    VpmComponent* self;         /* for the detailed lines (vpm_log_detail); NULL in the tests that never start it */
    uintptr_t mode, managers[2]; /* the mode block and the managers (ragdolls, corpses) the last poll found */
    double now;                 /* session seconds from the frame time (the Lua's api.time) */
    uint32_t fling_scan;        /* polls apply made */
    int forgotten, manager_turn;
    uint32_t cursors[2];        /* the next entry index per manager: ragdolls, corpses */
    struct { uint32_t scanned, inspected, clocked; int yielded, deadline_set; double deadline; } budget;
    const char* preflight;      /* the physics getter preflight: waiting_for_mission, waiting_for_unit, checking, ... */
    uint32_t mission_flag, mode_field_40, ragdoll_count, corpse_count;
    uint32_t polls, observed, accepted_units, realignments, claws_disabled, skipped, retries, guard_passes_skipped;
    uint32_t getter_checks, getter_failures, read_bytes, read_calls, last_unit, last_actor;
    uint32_t fling_armed, fling_stops, fling_stops_verified, fling_handoffs, fling_limb_stops, landed_disabled_stops;
    uint32_t last_fling_unit, last_fling_entity, last_fling_actor, mixed_corpse_realignments, reposes_deferred;
    uint32_t completion_requests, completion_corpse_observed, completion_pending, last_completion_unit;
    uint32_t last_completion_entity, scan_entities, deep_inspections, budget_yields, history_expirations;
    uint32_t listing_unreadable, listing_classified, listing_changes, corpse_rechecks_deferred, records_full;
    double max_gap, max_fling_distance, last_fling_distance, last_fling_degrees, last_fling_limb_distance;
    double last_fling_limb_degrees, last_fling_uptime, last_completion_uptime, max_revisit_seconds;
    const char* last_fling_type;
    const char* last_fling_reason;
    char last_skip[192];
    char last_getter_failure[192];
} EcsState;

extern EcsState Ecs;

#endif
