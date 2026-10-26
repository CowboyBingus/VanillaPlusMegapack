/* Reinforcement Beacons Fixed v4.6.1: the spawn data (spawn_data.lua), shared by the component's files.
 *
 * spawn_reader.c reads one snapshot of the game's reinforcement data (spawn_data.lua's session, local_player,
 * beacon_records, automatic_anchors and source_position). spawn_plan.c decides from two snapshots whether the local
 * player's pending spawn can be centered (patch.plan, and the re-checks before the write). The component file runs the
 * idle gate, the write and its restore (patch.apply, patch.restore). Where the Lua had nil, a snapshot has RBF_NIL (a
 * number field) or a 0 flag. */
#ifndef RBF_SPAWN_DATA_H
#define RBF_SPAWN_DATA_H

#include <stdint.h>
#include "../../core/vpm.h"

#define RBF_PLAYER_MANAGER 0x3326468u /* game.dll: the player manager global (VPM_RVA_PLAYER_MANAGER) */
#define RBF_AT_XY 0x10Cu              /* player manager: the local player's pending spawn X, Y (the only write) */
#define RBF_AT_SPAWN 0x2E0u           /* its spawn state: 0 before the first deployment, 1 dead and queued, 2 pod
                                       * pending, 3 alive */
#define RBF_PENDING 2u
#define RBF_MAX_BEACONS 128u
#define RBF_MAX_ROWS 512u
#define RBF_NIL (-1)                  /* a field the snapshot did not read */

/* Results: read, waiting for game data (RbfReader.stage says which), or refused (vpm_fail was called). */
#define RBF_OK 1
#define RBF_WAIT 0
#define RBF_FAILED (-1)

typedef struct RbfBeacon
{
    uint32_t id, used;   /* the beacon entity's id; its use bits (one per player) */
    int owned;           /* this machine owns the beacon entity */
    int positioned;      /* position was read (queued or pending only) and is a usable vector */
    float position[3];
} RbfBeacon;

/* An automatic-reinforcement row (stratagem type 0x7C): its position, whose 12 bytes are also its key. */
typedef struct RbfRow { float position[3]; } RbfRow;

typedef struct RbfSnapshot
{
    /* Everything before beacons is cleared for each read (rbf_clear). */
    uint32_t mode;           /* the mission mode; gameplay modes are 1 .. 7 */
    uintptr_t identity;      /* the player manager (0: outside gameplay modes, not read) */
    uintptr_t address;       /* identity + 0x10C */
    int64_t count;           /* players (RBF_NIL outside gameplay modes) */
    int64_t id, state;       /* the local player's entity id and spawn state (RBF_NIL when not read) */
    int owned;               /* this machine owns the local player */
    uint32_t use_bit, unit_ref;
    int positioned;          /* position is a usable vector */
    float position[3];       /* the pending spawn (player manager + 0x10C) */
    int timed;               /* countdown is a number */
    float countdown;         /* + 0x12C */
    uint8_t original[8];     /* the pending X, Y bytes, read in state 2 only */
    int unobserved;          /* a baseline the gate made in place of an alive snapshot */
    int solo;                /* a solo snapshot read to its end: its source position can be read */
    int source_valid;        /* source holds the source position (read once, or given by a test) */
    float source[3];
    uint32_t beacon_count;
    int rows_known;          /* 0: no automatic rows known (the Lua's nil); 1: rows[0 .. row_count) */
    uint32_t row_count;
    RbfBeacon beacons[RBF_MAX_BEACONS];
    RbfRow rows[RBF_MAX_ROWS];
} RbfSnapshot;

/* A correction: where it goes, why, and (once written) what it replaced. */
typedef struct RbfPlan
{
    uint8_t bytes[8];        /* the target X, Y as the two floats written */
    float target[2];
    int solo;                /* 0: the beacon's position; 1: the frozen source of the solo anchor */
    int remote;              /* 0: associated by the local use bit ("used"); 1: "unmarked_remote" */
    uint32_t beacon;
    float beacon_position[3];
    uintptr_t address;       /* the written XY, and its bytes before the write */
    uint8_t original[8];
} RbfPlan;

typedef struct RbfState
{
    RbfSnapshot* previous;   /* the last snapshot (or the gate's baseline); NULL none */
    int anchored;            /* solo: the anchor row of this death and its frozen source */
    RbfRow anchor;
    float anchor_source[3];
    int pending;             /* this death's correction is written */
    RbfPlan correction;
    int64_t spawn;           /* the spawn state seen last (RBF_NIL) */
    int landed_known;        /* the automatic rows of the last solo landing on this player manager */
    uint32_t landed_count;
    RbfRow landed[RBF_MAX_ROWS];
    uint32_t corrections;
    int has_last;            /* the last correction, for the log */
    RbfPlan last;
    float last_from[2];
} RbfState;

typedef struct RbfReader
{
    VpmComponent* self;      /* for vpm_fail */
    const char* stage;       /* the data being read: a WAIT names it ("waiting_for_game_data:<stage>") */
} RbfReader;

/* Stage names the component's gate reports too. */
extern const char rbf_stage_player_manager[];
extern const char rbf_stage_spawn_state[];
extern const char rbf_waiting_for_reinforcement[];

/* spawn_reader.c */
void rbf_clear(RbfSnapshot* out);
/* One snapshot: RBF_OK (outside gameplay modes, only mode), RBF_WAIT or RBF_FAILED. */
int rbf_snapshot(RbfReader* reader, RbfSnapshot* out);
/* Solo: the source position of a snapshot's local player, read once (source_valid says whether it is usable). */
int rbf_source(RbfReader* reader, RbfSnapshot* current);

/* spawn_plan.c */
void rbf_forget(RbfState* state);
/* What the plan compares the death's first snapshot with (the gate's baseline): 1 made, 0 none (last is nil, 1 or 2). */
int rbf_baseline(RbfSnapshot* out, const RbfSnapshot* current, int64_t last, const RbfState* state);
/* patch.plan: RBF_OK with *reason NULL and the plan made, or a reason; RBF_WAIT (the source's data, every association
 * forgotten) or RBF_FAILED. state->previous becomes current. */
int rbf_plan(RbfReader* reader, RbfState* state, RbfSnapshot* current, RbfPlan* plan, const char** reason);
/* After a full check: the spawn state seen, and back to the gate unless queued or pending. */
void rbf_track(RbfState* state, const RbfSnapshot* current);
/* The re-read right before the write: whether the pending spawn changed, whether the planned beacon still holds. */
int rbf_spawn_changed(const RbfSnapshot* current, const RbfSnapshot* fresh);
int rbf_beacon_kept(const RbfSnapshot* fresh, const RbfPlan* plan);

#endif
