/* Shallow Water Diving's dive reader and its lease of the water reference (Lua: components/ShallowWaterDiving/src/
 * dive_data.lua), shared by dive_snapshot.c (the snapshot of the local avatar's dive, its guards and the idle gate),
 * dive_lease.c (the check that takes, holds and gives back the lease) and shallow_water_diving.c (the component). */
#ifndef SWD_DIVE_DATA_H
#define SWD_DIVE_DATA_H

#include <stdint.h>

/* The deepest water (game units above the avatar's root) a dive may start in: 0.20, tightened after the knee-depth
 * test, is the default and the minimum; Mod Options Menu may raise it up to the standing reference itself (1.30),
 * above which the avatar swims and 'deep_water' applies anyway. */
#define SWD_MIN_WATER_DEPTH 0.20
#define SWD_SWIM_DEPTH 1.30

/* ---- the snapshot (dive_snapshot.c) ------------------------------------------------------------------------------- */

/* What one check read: the local avatar's dive controller and, on a dive frame, its Drownable runtime record, stance,
 * root height and the Drownable settings. Outside a dive only the fields up to `id` are fresh. */
typedef struct SwdSnapshot
{
    int dive, swim, ragdoll;
    float elapsed, landing;      /* the native dive timer and landing timer (+8, +12 of the dive record) */
    uintptr_t key;               /* the avatar's entity record (entity owner + 0xF32F18 + index * 24) */
    uint32_t entity[6];          /* that record as read */
    uintptr_t controller;        /* its dive controller (avatar manager + 0x53D900 + index * 0x1238) */
    uint32_t id;                 /* the avatar id */
    uintptr_t manager, table;    /* the Drownable manager and its runtime record table */
    uintptr_t water_address;     /* the avatar's 28-byte Drownable runtime record */
    int enabled, water_gate, deep;
    float offset;                /* +8: the drowning reference below the root (prone -0.4, standing -1.3) */
    uint32_t offset_bits;
    float drown_elapsed, remaining, surface; /* +16, +20, +24 */
    uint32_t elapsed_bits;
    uintptr_t stance_address;
    uint32_t stance;             /* 0 standing, 1 crouching, 2 prone (3: in transition) */
    float root_z, base, prone;   /* the root's height; the Drownable setting (-1.3); base + 0.9 */
} SwdSnapshot;

extern SwdSnapshot swd_snap;

/* Forgets everything the reader kept (start()). */
void swd_snapshot_reset(void);
/* Reads the snapshot into swd_snap: 1 ready, 0 waiting (*wait: why), -1 an error (swd_error(): what was not as
 * reviewed). *verified: the game.dll constants were verified this session (set on the first dive that verifies them). */
int swd_snapshot(int* verified, const char** wait);
const char* swd_error(void);
/* Whether a waiting reason was answered before the local avatar's dive controller was reached (no mission, no local
 * player, no local avatar): no dive can start before one exists, so the component polls those less often. */
int swd_no_avatar(const char* reason);
/* Reads every guard of the last snapshot again (or only its identity guards) and compares it byte for byte. */
int swd_guards_match(int identity_only);
/* Keeps the last snapshot's identity guards for a lease; swd_identities_match reads them again. */
void swd_keep_identities(void);
int swd_identities_match(void);
/* The idle gate: one read of the dive controller. 1 when it shows the same avatar id, no dive and finite timers. */
int swd_idle(uintptr_t controller, uint32_t id);

/* ---- the lease (dive_lease.c) --------------------------------------------------------------------------------------- */

typedef struct SwdLease
{
    int valid;
    uintptr_t address;           /* the record's offset (+8) */
    uint32_t before, after;      /* its bits before the lease, and the standing reference written */
    uintptr_t stance_address;
    float base;
    int checked;                 /* the page check made for the write still covers the record */
    int failed_write;            /* the write's read-back did not hold: a torn value is still ours */
    struct { int valid; uint32_t before, after; } recovery;                      /* a restore's own write */
    struct { int valid; uintptr_t address; uint32_t before, after; } elapsed;    /* a failed startup-debt clear */
} SwdLease;

typedef struct SwdWriteCheck
{
    int valid;
    uintptr_t manager, table, key; /* what the check was made for */
    uintptr_t low, high;           /* the pages it approved */
} SwdWriteCheck;

/* The Lua's state table (ShallowWaterDive): the session's counters and what the last check found. */
typedef struct SwdState
{
    uint32_t observed, protected, restored, startup_clears, short_ends, table_moves;
    uint32_t queries;            /* page checks (VirtualQuery) made */
    uint32_t writes;             /* stores into water records */
    int gate;                    /* gate_controller and gate_id are set: the last check found the local avatar */
    uintptr_t gate_controller;
    uint32_t gate_id;
    int keyed;                   /* key and entity are set */
    uintptr_t key;
    uint32_t entity[6];
    int was_dive, retry_start, constants_verified;
    SwdWriteCheck write_check;
    SwdLease pending;
    const char* restore_why;     /* the last restore's answer ("restored", "already_restored", ...): for the detailed lines */
    double max_water_depth;
} SwdState;

extern SwdState swd;

/* start(): every piece of the dive state zeroed, the depth limit at its minimum. */
void swd_reset(void);
/* The depth limit, clamped to 0.20 .. 1.30: 1 set, 0 refused (not a number). */
int swd_set_max_water_depth(double depth);
/* Why the snapshot's dive is not assisted, or NULL when it may be. */
const char* swd_reason(const SwdSnapshot* s);
/* The full check: 1 accepted (*reason, *active: a lease is held), 0 refused (*reason; the component stops), -1 an error
 * (swd_error()). */
int swd_apply(const char** reason, int* active);
/* Puts the leased record back: 1 done or nothing to do, 0 failed; *reason says which. reuse: the caller saw a normal dive
 * end with a fresh snapshot, so the lease's page check still covers the record. The lease is kept; the caller drops it. */
int swd_restore(int reuse, const char** reason);

#endif
