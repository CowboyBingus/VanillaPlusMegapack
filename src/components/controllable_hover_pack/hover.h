/* Controllable Hover Pack: what its three parts share (hover_data.c the snapshot, hover_settings.c the duration lease,
 * controllable_hover_pack.c the component), and the press policy (the Lua's cancel.lua) as inline functions. */
#ifndef CHP_HOVER_H
#define CHP_HOVER_H

#include <stdint.h>
#include <string.h>

/* game.dll globals (build 25480438) */
#define CHP_RVA_MODE 0x33266A0u       /* mission state: +8 active flag, +0x40 mission type (1 .. 7) */
#define CHP_RVA_EQUIPMENT 0x3326738u  /* equipment registry: +40 map, +64 identity array, +80 48-byte rows */
#define CHP_RVA_JUMP_PACKS 0x3326BB8u /* jump-pack manager */
#define CHP_RVA_ATTACHMENT 0x3326DC0u /* attachment registry: +32 map, +64 48-byte rows (holder at +4) */

/* Statuses, as the Lua named them (chp_status_name). CHP_VALID: a snapshot of the local player's hover pack. */
enum
{
    CHP_VALID = 0,
    CHP_WAITING_FOR_MISSION,
    CHP_WAITING_FOR_PLAYER,
    CHP_WAITING_FOR_AVATAR,
    CHP_NO_BACKPACK,
    CHP_NO_JUMP_PACK,
    CHP_NOT_HOVER_PACK,
    CHP_PACK_NOT_OWNED,
    CHP_PACK_NOT_ATTACHED,
    CHP_WAITING_FOR_READ,      /* a read failed (the Lua's WAIT_READ) */
    CHP_WAITING_FOR_POINTER,   /* a pointer outside the user-mode range (WAIT_POINTER) */
    CHP_WAITING_FOR_GAME_DATA, /* a check the Lua asserted (chp_snapshot_error says which) */
    CHP_WAITING_FOR_HOVER,
    CHP_WATCHING_HOVER,
    CHP_WAITING_FOR_GAME_FOCUS,
    CHP_SNAPSHOT_CHANGED,
    CHP_CANCEL_REQUESTED,
    CHP_NATIVE_DESCENT,
    CHP_RESTORE_PENDING,
    CHP_STATUS_COUNT
};

/* A flight's identity (the Lua's S.key): the avatar's and the pack's 24-byte entity records and the jump-pack manager. */
typedef struct ChpKey
{
    uint32_t avatar[6];
    uint32_t entity[6]; /* its first 20 bytes are the pack's identity (S.identity) */
    uintptr_t manager;
} ChpKey;

/* The local player's hover pack (the Lua's S): one record, valid until the next snapshot. */
typedef struct ChpSnapshot
{
    uint32_t mission_type;
    int down;   /* the Jump action is held */
    int active; /* the pack's state +0 */
    int flight; /* powered hover: active, no landing assistance, lift, airborne, not ragdolled or swimming */
    ChpKey key;
    uintptr_t manager;
    uint32_t pack; /* the pack's entity id */
} ChpSnapshot;

static inline int chp_same_key(const ChpKey* a, const ChpKey* b)
{
    return memcmp(a->avatar, b->avatar, sizeof a->avatar) == 0 && memcmp(a->entity, b->entity, sizeof a->entity) == 0 &&
           a->manager == b->manager;
}

/* ---- hover_data.c: the snapshot ------------------------------------------------------------------------------- */

/* The local player's hover pack: CHP_VALID with *out set, or the reason there is none. fresh skips the kept layout and
 * locates everything again from the registry roots. Reads only. */
int chp_snapshot(int fresh, const ChpSnapshot** out);
/* The last snapshot (valid or not: its fields hold until the next one). */
const ChpSnapshot* chp_snapshot_last(void);
/* What the last CHP_WAITING_FOR_GAME_DATA was (a string literal), or NULL. */
const char* chp_snapshot_error(void);
/* The pack's 5-byte state row while the kept layout is complete (the idle gate reads it): 1 with *at, else 0. */
int chp_snapshot_kept_row(uintptr_t* at);
void chp_snapshot_reset(void);

/* ---- hover_settings.c: the duration lease ----------------------------------------------------------------------- */

typedef struct ChpTarget
{
    uintptr_t manager;
    uint32_t pack;
    uint32_t identity[5]; /* the pack's entity record, first 20 bytes */
    ChpKey key;
} ChpTarget;

/* Cuts the pack's own hover duration to 1/1024 s (creating its per-pack record first if it has none): 1 done, the
 * lease held; 0 not now (the settings changed or could not be read: nothing written, no lease); -1 failed (*error;
 * the Lua raised: a lease may be held). */
int chp_settings_cancel(const ChpTarget* target, const char** error);
/* Puts the leased pack's duration back: 1 settled (restored, or the pack is gone; no lease), 0 waiting (*why; the
 * lease kept), -1 failed (*why; the lease kept). With no lease: 1. */
int chp_settings_restore(const char** why);
int chp_lease_held(void);
const ChpKey* chp_lease_key(void);
/* The duration the last lease cut (seconds), whether that cancellation created the pack's record, and how many
 * restorations wrote the duration back this session. */
float chp_lease_original(void);
int chp_settings_created(void);
int chp_settings_restorations(void);
/* For the detailed lines: why the last cancellation waited, how the last lease ended (string literals; "none" before
 * the first), and the pack's record the last inspection found (0: none). */
const char* chp_settings_wait(void);
const char* chp_settings_outcome(void);
uintptr_t chp_settings_record(void);
void chp_settings_reset(void);

#ifdef VPM_TEST
extern int chp_test_queries; /* the settings' vpm_writable calls (one VirtualQuery each): the tests pin them */
#endif

/* ---- the press policy (cancel.lua): a new flight must see the Jump released before a press can cancel it --------- */

typedef struct ChpPolicy
{
    int has_key;
    ChpKey key;
    int armed, down, sent;
} ChpPolicy;

/* One frame's sample (NULL: no snapshot): 1 when this frame asks for the cancellation. */
static inline int chp_policy_step(ChpPolicy* p, const ChpSnapshot* s)
{
    if (s == NULL || !s->flight)
    {
        p->has_key = 0;
        p->armed = p->down = p->sent = 0;
        return 0;
    }
    if (!p->has_key || !chp_same_key(&p->key, &s->key))
    {
        p->has_key = 1;
        p->key = s->key;
        p->armed = !s->down;
        p->down = s->down;
        p->sent = 0;
        return 0;
    }
    int press = s->down && !p->down;
    p->down = s->down;
    if (!s->down) p->armed = 1;
    if (p->armed && press && !p->sent)
    {
        p->sent = 1;
        return 1;
    }
    return 0;
}

#endif
