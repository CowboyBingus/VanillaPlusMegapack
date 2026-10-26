/* Holster Your Shield v1.0 (Lua: components/HolsterYourShield/src/holster_your_shield.lua), build 25480438.
 *
 * With a one-handed weapon in hand the game puts a shield backpack (the SH-20 Ballistic Shield or the SH-51 Directional
 * Shield: equipment type 25) into the left hand. The shield in hand is the Helldiver's "held carryable" in carry mode 2
 * (inventory row +20 and +32); on the back nothing is held. The game moves it with two calls, 0x9ABC30 (the held
 * carryable) and 0x9AC8E0 (the carry mode), and tells the other players with rpc_set_held_carryable (0xBE20B0).
 * Switching to a two-handed weapon stows it that way (0xA95910), wielding a one-handed weapon draws it that way
 * (0xA95A90).
 *
 * This makes the same calls when the player presses Backpack Function (action slot 37, after rebinding and controller
 * processing) while wearing a shield backpack:
 *   - shield in hand: it goes on the back, and stays there: when the game draws it again (a weapon switch, a dropped
 *     objective, the re-wield after an action), it goes back inside the game's draw (the re-draw hook below), or on
 *     the next frame when the draw came another way or the hook is not in (at most 6 re-stows in 120 frames);
 *   - pressed again: it comes back to the hand if the weapon in hand is one-handed and nothing else is held (the
 *     game's own conditions); otherwise the game draws it at the next one-handed wield.
 * Before every call everything is found again from the game's registries and the backpack's type is read again. Every
 * move is checked on the next frame against the row (the log says "done" or "FAILED"). It writes no memory. Other
 * backpacks, other players' Helldivers and every other shield are left alone.
 *
 * On HellForge: the three functions are called through C function pointers (game.dll's base + RVA) from the pack's
 * game-thread tick, with the same arguments as the game's own callers, after their first 16 bytes were checked once at
 * HF_EVENT_GAME_LOADED (code_matches: the bytes as the game shipped them, so another mod's hook does not refuse them).
 * game.dll's globals are plain loads; the heap is read through vpm_read. The local Helldiver is found with the Lua's own
 * resolution, not vpm_local_avatar: the inventory row's identity check needs the address of the avatar's record in
 * the entity owner's table, which VpmAvatar does not keep, and the log names the step that failed ("Press refused: not
 * an owned Helldiver avatar."). Its pieces come from the core where they are the same: vpm_lookup (the game's map),
 * vpm_avatar_still (the first three checks of the Lua's still_valid), vpm_action_slot (the key). The Lua's session
 * summary at shutdown is written at each mission's end instead (HellForge has no shutdown event), and when the core
 * stops the component.
 *
 * The game's re-draw, hooked (the Lua could not: GameGuard flags a changed game.dll; decoded game.dll of 25480438).
 * 0xA95A90(avatar record, send, blend) runs on every wield of the weapon in hand: 51 direct calls and no pointer to it,
 * 7 in the weapon code (0xA55F90 .. 0xA926ED, send 1 or their caller's flag) and 44 in animation-event handlers
 * (0x10A1F10 .. 0x119DA0C, send 0); the record is the avatar's 24-byte entity record (+8 its entity id), blend (r8b)
 * picks 1.0 or 0.0 for the wield; no caller uses its result (rax). It first wields the weapon (0x786190, 0x8C0E90;
 * with send 1 also rpc_wield_weapon 0xBE1640 and the RPC 0xBE0980) and only then, when that weapon is one-handed
 * (0x8C2010), the avatar's row is owned here, the backpack is type 25 and nothing else is held (or the shield is),
 * draws the shield: 0x9ABC30(shield), 0x9AC8E0(2) and, with send 1, rpc_set_held_carryable(-2, avatar, shield, 2).
 * So the draw cannot be skipped on its own: skipping the call skips the weapon's wield and its RPCs (the
 * weapon would not be in hand for the game or the other players), and making its checks fail means writing game
 * memory. The detour therefore calls the original exactly once with its three registers and returns its result, and
 * then, for the toggled Helldiver only (the entity id at record + 8) when the row holds the shield, stows it with the
 * checks and calls of a press: the game's own stow (0xA95910's calls) right after the game's own draw, in the same call
 * on the same thread, so the row is as the 1:1 re-stow leaves it one frame later, no frame shows the shield in hand,
 * the caller goes on with the shield on the back (as after a two-handed wield) and both RPCs go out in the same frame,
 * the stow's last. Every other call only calls the original: no toggle, another Helldiver, no draw, the component
 * stopped, a nested call while the original or the component's own calls run (the outermost call stows once, after
 * all of them). A fault in the detour's work stops the component; the original has run and its result is returned.
 * The 1:1 re-stow on the next frame stays as the fallback when the hook cannot go in (its bytes differ, HellForge
 * refuses it), and as the safety net while it is in: the game also draws the shield without 0xA95A90 when an objective
 * is dropped (0xA44B40), when a shield backpack is equipped (0x97CFEE), and from the held-carryable RPC's receivers
 * (0xBA7CF0, 0xB7DB7B).
 *
 * Cost per frame (vpm_read is a guarded plain load; tests/components/holster_your_shield_test.c pins each path; the
 * Lua's frame_budget pins in brackets, its views and pointer reads together):
 *   no local player (menus, loading): nothing; every 30th frame 1 read [3]
 *   kept row, another backpack: 1 read [1]
 *   shield worn, no press: 2 reads [2]
 *   every 30th frame with a kept row: + 4 reads [+ 6]
 *   a press that stows, or a re-stow on the next frame: 31 reads and the 3 game calls [37 and the 3 calls]
 *   a press that draws: 41 reads and the 3 game calls [49 and the 3 calls]
 *   the frame after a move: 2 reads and its log line [2]
 * Per call of the game's re-draw, with the hook in: no toggle, or the component stopped: nothing but the original (two
 * plain loads); toggled, another Helldiver: 1 read; toggled, no draw: 2 reads; a draw put back: 31 reads and the 3 game
 * calls inside the call, where the fallback makes the same 31 reads and 3 calls on the next frame (and the Lua 37 reads
 * and the 3 calls), and the frame after only the move's check. Idle frames cost the same with the hook as without.
 * Fewer reads than the Lua because game.dll's globals are plain loads here. No write, no page query (VirtualQuery), no
 * allocation and no other Windows call on any path. Once per session, at HF_EVENT_GAME_LOADED: 4 code checks (the
 * three functions and the re-draw's first 25 bytes), the hook, and 2 plain loads (the game's "nothing held" ids). */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"

#define INVENTORY_RVA 0x3326738u   /* inventory: map +40 by avatar entity id, identity pointers +64, 48-byte rows +80 */
#define EQUIPMENT_RVA 0x3326DC0u   /* per-entity EquipmentComponent copies: map +80, 232-byte records at +144 */
#define NONE_ITEM_RVA 0x3483C4Cu   /* the game's "nothing held" id (0 in this build) */
#define NONE_SLOT_RVA 0x3483C5Cu   /* the id 0xA95A90 compares an empty held carryable with (0 in this build) */
#define SET_ITEM_RVA 0x9ABC30u     /* (inventory, avatar entity, item): sets the held carryable */
#define SET_MODE_RVA 0x9AC8E0u     /* (inventory, avatar entity, mode): 2 held, 1 put away */
#define SEND_HELD_RVA 0xBE20B0u    /* (peer, avatar entity, item, mode): rpc_set_held_carryable, peer -2 = everyone */
#define REDRAW_RVA 0xA95A90u       /* (avatar record, send, blend): wields the weapon in hand, then draws the shield */
/* Its first instructions as shipped: mov [rsp+20h], rbx; push rdi; push r12; push r15; sub rsp, 30h; movzx edi, r8b;
 * mov r12d, edx; mov r8d, [rcx+8] (the avatar's entity id). */
#define REDRAW_SHIPPED "48 89 5C 24 20 57 41 54 41 57 48 83 EC 30 41 0F B6 F8 44 8B E2 44 8B 41 08"
#define RECORD_ENTITY 8u           /* the entity id in a 24-byte entity record */

#define PM_COUNTS 0x84u            /* player manager: two counts, each 1 .. 4 with a local player */
#define PM_PLAYER 0xE8u            /* the local player's record (24 bytes, owned bit in word 5) */
#define PM_NETWORK 0x3A8u          /* the local avatar's network id (0x7FFF: none) */
#define OWNER_NETWORK_MAP 0xF22EC8u
#define OWNER_ENTITY_MAP 0xF1AEB0u
#define OWNER_RECORDS 0xF32F18u    /* 24-byte entity records */
#define OWNER_SETTINGS 0xF12BC0u   /* the shared EquipmentComponent settings */
#define AM_MAP 0xF8u
#define AM_COUNT 0x6Cu
#define AM_ENTITIES 0x110u
#define INVENTORY_MAP 40u
#define INVENTORY_IDENTITIES 64u
#define INVENTORY_ROWS 80u
#define COPIES_MAP 80u
#define COPIES_RECORDS 144u
#define AVATAR_TYPE_LOW 0x294DFA97u  /* content/fac_helldivers/cha_avatar/avatar_helldiver */
#define AVATAR_TYPE_HIGH 0x4D1C334Du
#define ROW_SIZE 48u
#define SETTINGS_SLOTS 688u
#define SETTINGS_SIZE 232u
#define TYPE_OFFSET 0x80u
#define ONE_HANDED_OFFSET 0xC4u
#define SHIELD_TYPE 25u            /* EquipmentType_BackpackShield */
#define CHECK_FRAMES 30u           /* the kept addresses are checked on every 30th frame */
#define RESTOW_LIMIT 6             /* re-stows within RESTOW_WINDOW frames before the toggle gives up */
#define RESTOW_WINDOW 120u
#define MODE_HELD 2u
#define MODE_AWAY 1u
#define POSITIVE_INFINITY_BITS 0x7F800000u

typedef void (*SetItemFn)(uint64_t inventory, uint32_t avatar, uint32_t item);
typedef uint64_t (*SetModeFn)(uint64_t inventory, uint32_t avatar, uint32_t mode);
typedef void (*SendHeldFn)(int64_t peer, uint32_t avatar, uint32_t item, uint32_t mode);
/* Whole registers, so the detour passes on exactly what the caller left in rcx, rdx and r8 (it sets edx and r8b). */
typedef uint64_t (*RedrawFn)(uint64_t record, uint64_t send, uint64_t blend);

typedef struct GameFunction { const char* name; uint32_t rva; const char* prologue; } GameFunction;
/* The first 16 bytes of each function, checked once per session before anything is called. */
static const GameFunction kFunctions[3] = {
    {"set_item", SET_ITEM_RVA, "48 89 5C 24 18 48 89 4C 24 08 55 56 57 41 54 41"},
    {"set_mode", SET_MODE_RVA, "48 89 5C 24 20 44 89 44 24 18 55 56 57 41 54 41"},
    {"send_held", SEND_HELD_RVA, "48 89 5C 24 10 44 89 4C 24 20 57 48 83 EC 60 48"},
};

/* Everything kept about the local Helldiver (the Lua's resolve). */
typedef struct Kept
{
    VpmAvatar avatar;    /* its 24-byte record, the avatar manager, its index and entity pointer there */
    uintptr_t address;   /* the record's address in the entity owner's table: the inventory row's identity */
    uint32_t avatar_id;  /* its entity id (record word 2) */
    uintptr_t inventory;
    uint32_t row_index;
    uintptr_t row;
    uintptr_t key;       /* action 37's held seconds (a float) */
} Kept;

/* The row's words used: backpack (+12), held carryable (+20), slot in hand (+28), carry mode (+32). */
typedef struct Row { uint32_t backpack, held, slot, mode; } Row;

typedef struct Pending { uint32_t mode, shield; const char* label; } Pending;
typedef struct Counts { uint32_t presses, holsters, draws, restows, inside, checked, failed, refused; } Counts;

static struct
{
    VpmComponent* self;
    SetItemFn set_item;
    SetModeFn set_mode;
    SendHeldFn send_held;
    RedrawFn redraw;   /* the hook's original: HellForge rewrites it when another hook joins the chain */
    int hooked;
    int busy;          /* inside the game's re-draw or the component's own calls: a nested re-draw is the game's */
    int bound;
    uint32_t none_item, none_slot;
    uint64_t frame;
    int has_kept;
    Kept kept;
    int has_backpack;
    uint32_t backpack;
    int shield;
    int toggled;
    uint32_t toggled_for;
    uint32_t key_bits;
    int has_pending;
    Pending pending;
    uint64_t restows[RESTOW_LIMIT]; /* the frames of the re-stows within the window */
    int restow_count;
    int has_last;
    uint32_t last_avatar;
    Counts counts;
    char why[48];
} s;

/* ---- the game's registries ------------------------------------------------------------------------------------- */

/* The local player's avatar network id, after the player manager's checks; the entity owner in *owner. */
static const char* LocalNetworkId(uintptr_t* owner, uint32_t* network)
{
    uintptr_t players = (uintptr_t)vpm_game_u64(VPM_RVA_PLAYER_MANAGER);
    *owner = (uintptr_t)vpm_game_u64(VPM_RVA_ENTITY_OWNER);
    if (!vpm_plausible(players) || !vpm_plausible(*owner)) return "player manager not ready";
    uint32_t counts[2], player[6];
    if (!vpm_read(players + PM_COUNTS, counts, sizeof counts)) return "player counts unreadable";
    if (counts[0] < 1 || counts[0] > 4 || counts[1] < 1 || counts[1] > 4) return "no local player";
    if (!vpm_read_u32(players + PM_NETWORK, network) || *network == 0x7FFFu) return "no local avatar";
    uintptr_t record = vpm_ptr(players + PM_PLAYER);
    if (!vpm_plausible(record) || !vpm_read(record, player, sizeof player) || (player[5] & 1u) == 0)
        return "local player record not owned here";
    return NULL;
}

/* The local player's avatar record and its address in the entity owner's table. */
static const char* LocalAvatar(Kept* k)
{
    uintptr_t owner = 0;
    uint32_t network = 0, index = 0;
    const char* why = LocalNetworkId(&owner, &network);
    if (why != NULL) return why;
    if (!vpm_lookup(owner + OWNER_NETWORK_MAP, network, 1048576u, &index) || index >= 262144u)
        return "avatar not in the entity map";
    k->address = owner + OWNER_RECORDS + 24u * (uintptr_t)index;
    uint32_t* w = k->avatar.record;
    if (!vpm_read(k->address, w, 24)) return "avatar record unreadable";
    if (w[0] != AVATAR_TYPE_LOW || w[1] != AVATAR_TYPE_HIGH || (w[5] & 1u) == 0) return "not an owned Helldiver avatar";
    k->avatar_id = w[2];
    return NULL;
}

/* Where the avatar sits in the avatar manager, and its key. */
static const char* AvatarSlot(Kept* k)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(VPM_RVA_AVATAR_MANAGER);
    if (!vpm_plausible(manager)) return "avatar manager not ready";
    uint32_t index = 0, count = 0, record[6];
    if (!vpm_lookup(manager + AM_MAP, k->avatar_id, 64u, &index) || !vpm_read_u32(manager + AM_COUNT, &count) ||
        count > 8 || index >= count)
        return "avatar not in the avatar manager";
    uintptr_t pointer = vpm_ptr(manager + AM_ENTITIES + 8u * (uintptr_t)index);
    if (!vpm_plausible(pointer) || !vpm_read(pointer, record, sizeof record) || memcmp(record, k->avatar.record, 24) != 0)
        return "avatar manager entry holds another entity";
    k->avatar.manager = manager;
    k->avatar.index = index;
    k->avatar.entity = pointer;
    k->key = vpm_action_slot(&k->avatar, VPM_ACTION_BACKPACK) + 8u;
    return NULL;
}

/* The avatar's inventory row: its identity pointer must be the avatar's own entity record (live on the ship). */
static const char* InventoryRow(Kept* k)
{
    uintptr_t inventory = (uintptr_t)vpm_game_u64(INVENTORY_RVA);
    if (!vpm_plausible(inventory)) return "inventory not ready";
    uint32_t index = 0;
    if (!vpm_lookup(inventory + INVENTORY_MAP, k->avatar_id, 65536u, &index)) return "no inventory row";
    uintptr_t identities = vpm_ptr(inventory + INVENTORY_IDENTITIES), rows = vpm_ptr(inventory + INVENTORY_ROWS);
    if (!vpm_plausible(identities) || !vpm_plausible(rows)) return "inventory arrays missing";
    if (vpm_ptr(identities + 8u * (uintptr_t)index) != k->address) return "inventory row of another entity";
    k->inventory = inventory;
    k->row_index = index;
    k->row = rows + ROW_SIZE * (uintptr_t)index;
    return NULL;
}

/* Everything kept about the local Helldiver, found from the registry roots: NULL, or why not. */
static const char* FindHelldiver(Kept* k)
{
    memset(k, 0, sizeof *k);
    const char* why = LocalAvatar(k);
    if (why == NULL) why = AvatarSlot(k);
    if (why == NULL) why = InventoryRow(k);
    return why;
}

/* Whether the kept resolution still holds: the same avatar entry and record, and the same inventory row. */
static int StillValid(const Kept* k)
{
    uint32_t index = 0;
    return vpm_avatar_still(&k->avatar) && (uintptr_t)vpm_game_u64(INVENTORY_RVA) == k->inventory &&
           vpm_lookup(k->inventory + INVENTORY_MAP, k->avatar_id, 65536u, &index) && index == k->row_index;
}

/* The shared EquipmentComponent of a resource (0x508E90): 688 slots of {resource u64, index u32, pad} probed linearly
 * from resource % 688, then 232-byte records. */
static const char* SharedSettings(uintptr_t owner, uint32_t low, uint32_t high, uintptr_t* record)
{
    uintptr_t table = vpm_ptr(owner + OWNER_SETTINGS);
    if (!vpm_plausible(table)) return "equipment settings not loaded";
    uint32_t slot = (uint32_t)((((uint64_t)high << 32) | low) % SETTINGS_SLOTS);
    for (uint32_t probe = 0; probe < SETTINGS_SLOTS; probe++)
    {
        uint32_t w[3];
        if (!vpm_read(table + 16u * (uintptr_t)slot, w, sizeof w)) return "equipment settings unreadable";
        if (w[0] == low && w[1] == high)
        {
            *record = table + 16u * SETTINGS_SLOTS + SETTINGS_SIZE * (uintptr_t)w[2];
            return NULL;
        }
        if (w[0] == 0 && w[1] == 0) return "no equipment settings";
        slot = (slot + 1u) % SETTINGS_SLOTS;
    }
    return "no equipment settings";
}

/* The 232-byte EquipmentComponent the game's getter (0x5092B0) uses for an entity: its per-entity copy, else the
 * shared settings of its resource. */
static const char* EquipmentRecord(uint32_t entity, uintptr_t* record)
{
    uintptr_t copies = (uintptr_t)vpm_game_u64(EQUIPMENT_RVA);
    uint32_t index = 0, words[6];
    if (vpm_plausible(copies) && vpm_lookup(copies + COPIES_MAP, entity, 65536u, &index))
    {
        uintptr_t records = vpm_ptr(copies + COPIES_RECORDS);
        if (vpm_plausible(records)) { *record = records + SETTINGS_SIZE * (uintptr_t)index; return NULL; }
    }
    uintptr_t owner = (uintptr_t)vpm_game_u64(VPM_RVA_ENTITY_OWNER);
    if (!vpm_plausible(owner)) return "entities not ready";
    if (!vpm_lookup(owner + OWNER_ENTITY_MAP, entity, 1048576u, &index) ||
        !vpm_read(owner + OWNER_RECORDS + 24u * (uintptr_t)index, words, sizeof words) || words[2] != entity)
    {
        snprintf(s.why, sizeof s.why, "entity %u not found", entity);
        return s.why;
    }
    return SharedSettings(owner, words[0], words[1], record);
}

/* The entity's equipment type and one-handed flag. */
static const char* Equipment(uint32_t entity, uint32_t* kind, int* one_handed)
{
    uintptr_t record = 0;
    uint8_t flag = 0;
    const char* why = EquipmentRecord(entity, &record);
    if (why != NULL) return why;
    if (!vpm_read_u32(record + TYPE_OFFSET, kind)) return "equipment type unreadable";
    if (!vpm_read_u8(record + ONE_HANDED_OFFSET, &flag)) return "equipment flags unreadable";
    *one_handed = flag != 0;
    return NULL;
}

static int ReadRow(uintptr_t row, Row* out)
{
    uint32_t w[6];
    if (!vpm_read(row + 12u, w, sizeof w)) return 0;
    *out = (Row){w[0], w[2], w[4], w[5]};
    return 1;
}

/* The entity id of the weapon in the slot in hand (1 primary, 2 sidearm, 3 support): 1, or 0 for none. */
static int WeaponInHand(uintptr_t row, uint32_t slot, uint32_t* weapon)
{
    return slot >= 1 && slot <= 3 && vpm_read_u32(row + 4u * (uintptr_t)(slot - 1u), weapon);
}

/* ---- the toggle ------------------------------------------------------------------------------------------------ */

static int IsNone(uint32_t id) { return id == 0 || id == s.none_item || id == s.none_slot; }

static void Untoggle(VpmComponent* self, const char* reason)
{
    s.toggled = 0;
    s.toggled_for = 0;
    if (reason != NULL) vpm_log(self, "Shield toggle off: %s.", reason);
}

static void ToggleOn(void)
{
    s.toggled = 1;
    s.toggled_for = s.kept.avatar_id;
}

static void Forget(VpmComponent* self, const char* reason)
{
    if (s.toggled) Untoggle(self, reason);
    s.has_kept = s.has_backpack = s.shield = s.has_pending = 0;
    s.key_bits = 0;
}

/* A new Helldiver (or the first): the toggle ends, the backpack is read again. */
static void NewHelldiver(VpmComponent* self, const Kept* fresh)
{
    if (s.toggled) Untoggle(self, "a new Helldiver");
    s.has_backpack = s.shield = 0;
    s.key_bits = 0;
    if (s.has_last && fresh->avatar_id == s.last_avatar) return;
    s.has_last = 1;
    s.last_avatar = fresh->avatar_id;
    vpm_log(self, "Found your Helldiver (avatar %u, inventory row %u).", fresh->avatar_id, fresh->row_index);
}

/* A full resolution from the registry roots, kept: NULL, or why not (the kept one stays). */
static const char* Resolve(VpmComponent* self)
{
    Kept fresh;
    const char* why = FindHelldiver(&fresh);
    if (why != NULL) return why;
    if (!s.has_kept || s.kept.avatar_id != fresh.avatar_id) NewHelldiver(self, &fresh);
    s.kept = fresh;
    s.has_kept = 1;
    return NULL;
}

/* The backpack changed: is the new one a shield? (its settings, read once per backpack id) */
static void BackpackChanged(VpmComponent* self, uint32_t backpack)
{
    if (s.toggled) Untoggle(self, "the backpack changed");
    s.has_backpack = 1;
    s.backpack = backpack;
    s.shield = 0;
    s.key_bits = 0;
    if (IsNone(backpack)) return;
    uint32_t kind = 0;
    int one_handed = 0;
    s.shield = Equipment(backpack, &kind, &one_handed) == NULL && kind == SHIELD_TYPE;
    if (s.shield) vpm_log(self, "Shield backpack %u worn: Backpack Function toggles it.", backpack);
}

/* The three calls of one move, exactly as the game makes them, then the check on the next frame. A re-draw the game
 * makes inside them is left to the game (busy): the move does not start another. */
static void Move(uint32_t shield, uint32_t mode, const char* label)
{
    uint64_t inventory = s.kept.inventory;
    uint32_t avatar = s.kept.avatar_id;
    s.busy = 1;
    s.set_item(inventory, avatar, mode == MODE_HELD ? shield : s.none_item);
    (void)s.set_mode(inventory, avatar, mode); /* its result is unused, as in the Lua */
    s.send_held(-2, avatar, shield, mode);
    s.busy = 0;
    s.has_pending = 1;
    s.pending = (Pending){mode, shield, label};
    if (mode == MODE_HELD) s.counts.draws++;
    else s.counts.holsters++;
}

/* The check of the last move: the row must show it. A draw holds the shield in mode 2. A stow leaves nothing held, and
 * with nothing held 0x9AC8E0 writes carry mode 0 whatever mode it was given. */
static void CheckMove(VpmComponent* self, uint32_t held, uint32_t mode)
{
    s.has_pending = 0;
    int ok = s.pending.mode == MODE_HELD ? held == s.pending.shield && mode == MODE_HELD : IsNone(held);
    if (ok) s.counts.checked++;
    else s.counts.failed++;
    vpm_log(self, "%s: %s (held %u, mode %u).", s.pending.label, ok ? "done" : "FAILED, the game did not take it", held, mode);
}

/* Before any move: everything found again from the roots, the backpack still a shield: NULL with the row, or why not. */
static const char* Verified(VpmComponent* self, uint32_t shield, Row* row)
{
    const char* why = Resolve(self);
    if (why != NULL) return why;
    if (!ReadRow(s.kept.row, row)) return "inventory row unreadable";
    if (row->backpack != shield) return "the backpack changed";
    uint32_t kind = 0;
    int one_handed = 0;
    why = Equipment(row->backpack, &kind, &one_handed);
    if (why == NULL && kind != SHIELD_TYPE) why = "the backpack is not a shield";
    return why;
}

static void Refuse(VpmComponent* self, const char* what, const char* why)
{
    s.counts.refused++;
    vpm_log(self, "%s refused: %s.", what, why);
}

/* Whether the weapon in the slot in hand is one-handed (by the game's getter). */
static int WeaponOneHanded(uint32_t slot)
{
    uint32_t weapon = 0, kind = 0;
    int one_handed = 0;
    return WeaponInHand(s.kept.row, slot, &weapon) && Equipment(weapon, &kind, &one_handed) == NULL && one_handed;
}

/* A press of Backpack Function while a shield backpack is worn. */
static void Press(VpmComponent* self, uint32_t shield)
{
    s.counts.presses++;
    Row row;
    const char* why = Verified(self, shield, &row);
    if (why != NULL) { Refuse(self, "Press", why); return; }
    if (row.held == shield) { ToggleOn(); Move(shield, MODE_AWAY, "Shield to the back"); return; }
    if (!IsNone(row.held))
    {
        if (s.toggled) Untoggle(self, NULL);
        else ToggleOn();
        vpm_log(self, "Press while carrying something else: the shield %s.",
            s.toggled ? "stays on the back" : "returns with the next one-handed weapon");
        return;
    }
    if (!s.toggled) { ToggleOn(); vpm_log(self, "Press with the shield on the back: it stays there."); return; }
    Untoggle(self, NULL);
    if (WeaponOneHanded(row.slot)) { Move(shield, MODE_HELD, "Shield to the hand"); return; }
    vpm_log(self, "Shield toggle off: it returns with the next one-handed weapon.");
}

/* Re-stows older than the window no longer count. */
static void DropOldRestows(void)
{
    int old = 0;
    while (old < s.restow_count && s.frame - s.restows[old] >= RESTOW_WINDOW) old++;
    memmove(s.restows, s.restows + old, (size_t)(s.restow_count - old) * sizeof s.restows[0]);
    s.restow_count -= old;
}

/* The game drew the shield while the toggle is on: stow it again, unless that keeps happening. inside: from the re-draw's
 * detour, in the game's draw; else from the tick, on the frame after it. */
static void Restow(VpmComponent* self, uint32_t shield, int inside)
{
    DropOldRestows();
    if (s.restow_count >= RESTOW_LIMIT)
    {
        char reason[96];
        s.restow_count = 0;
        snprintf(reason, sizeof reason, "the game drew the shield %d times in %u frames, so it stays in hand",
            RESTOW_LIMIT + 1, RESTOW_WINDOW);
        Untoggle(self, reason);
        return;
    }
    Row row;
    const char* why = Verified(self, shield, &row);
    if (why != NULL) { Refuse(self, "Re-stow", why); return; }
    if (!s.toggled || s.kept.avatar_id != s.toggled_for) { Untoggle(self, "a new Helldiver"); return; }
    if (row.held != shield) return;
    s.restows[s.restow_count++] = s.frame;
    s.counts.restows++;
    if (inside) s.counts.inside++;
    Move(shield, MODE_AWAY, inside ? "Shield kept on the back as the game drew it" : "Shield back to the back after the game drew it");
}

/* Action 37's held time, as its float bits: 0 when released, positive below infinity while held. */
static int KeyPressed(void)
{
    uint32_t bits = 0;
    if (!vpm_read_u32(s.kept.key, &bits)) return 0;
    uint32_t before = s.key_bits;
    s.key_bits = bits;
    return before == 0 && bits > 0 && bits < POSITIVE_INFINITY_BITS;
}

/* ---- per frame --------------------------------------------------------------------------------------------------- */

/* Every 30th frame: the kept addresses must still be the local Helldiver's, else find them again (the game moves
 * inventory rows when a Helldiver dies; Resolve keeps the toggle while the avatar entity is the same). */
static void Check(VpmComponent* self)
{
    if (s.has_kept && StillValid(&s.kept)) return;
    const char* why = Resolve(self);
    if (why == NULL || !s.has_kept) return;
    char reason[96];
    snprintf(reason, sizeof reason, "the Helldiver is gone (%s)", why);
    Forget(self, reason);
}

/* One frame with a kept resolution: the row read, then the key read while a shield backpack is worn. Another backpack
 * at the kept row may only mean the game moved the rows (it does when a Helldiver dies): the row is found again from
 * the registries before the change counts. */
static void Watch(VpmComponent* self)
{
    Row row;
    int readable = ReadRow(s.kept.row, &row);
    if (s.has_backpack && (!readable || row.backpack != s.backpack))
    {
        if (Resolve(self) != NULL) { Forget(self, "the Helldiver is gone"); return; }
        readable = ReadRow(s.kept.row, &row);
    }
    if (!readable) { Forget(self, "the inventory row went away"); return; }
    if (s.has_pending) CheckMove(self, row.held, row.mode);
    if (!s.has_backpack || row.backpack != s.backpack) BackpackChanged(self, row.backpack);
    if (!s.shield) return;
    if (KeyPressed()) { Press(self, row.backpack); return; }
    if (s.toggled && row.held == row.backpack) Restow(self, row.backpack, 0); /* the fallback, and the hook's safety net */
}

/* The tick: one row read; a key read while a shield is worn; the rest only when something happens. Without a kept
 * Helldiver, nothing but every 30th frame's resolution attempt. lint: per-frame */
static void Step(VpmComponent* self, float dt)
{
    s.frame++;
    if (s.has_kept) Watch(self);
    if (s.frame % CHECK_FRAMES == 0) Check(self);
}

/* ---- the game's re-draw (0xA95A90) ------------------------------------------------------------------------------- */

/* After the original ran for the toggled Helldiver: the shield it drew goes back at once, through the checks and calls
 * of a re-stow. No draw (a two-handed weapon, an objective held, another backpack): one row read. lint: per-frame */
static void AfterRedraw(void* unused)
{
    Row row;
    if (!s.toggled || !s.has_kept || !s.shield || !ReadRow(s.kept.row, &row)) return;
    if (row.backpack == s.backpack && row.held == row.backpack) Restow(s.self, row.backpack, 1);
}

/* The detour: the original exactly once, with the caller's registers, and its result; then, for the toggled Helldiver
 * only, AfterRedraw under the crash guard. The gate reads nothing until the toggle is on, then the entity id the game
 * itself reads first (record + 8). lint: per-frame */
static uint64_t Redraw(uint64_t record, uint64_t send, uint64_t blend)
{
    uint32_t avatar = 0;
    if (!vpm_running(s.self) || !s.toggled || s.busy || !vpm_read_u32((uintptr_t)record + RECORD_ENTITY, &avatar) ||
        avatar != s.toggled_for)
        return s.redraw(record, send, blend);
    s.busy = 1;
    uint64_t result = s.redraw(record, send, blend);
    s.busy = 0;
    (void)vpm_guarded(s.self, AfterRedraw, NULL); /* a fault stops the component, and the core logs it */
    return result;
}

/* ---- the session ------------------------------------------------------------------------------------------------- */

/* The Lua's summary; with the hook in, the re-stows also say how many were made inside the game's draw. */
static void Summary(char* out, size_t size)
{
    const Counts* c = &s.counts;
    char inside[48] = "";
    if (s.hooked) snprintf(inside, sizeof inside, ", %u inside the game's draw", c->inside);
    snprintf(out, size, "presses %u, to the back %u (re-stows %u%s), to the hand %u, checks done %u, failed %u, refused %u",
        c->presses, c->holsters, c->restows, inside, c->draws, c->checked, c->failed, c->refused);
}

/* The Lua's shutdown summary, at each mission's end (cumulative for the session). lint: per-frame */
static void MissionEnded(VpmComponent* self, const HfEventInfo* event)
{
    if (!s.bound) return;
    char summary[192];
    Summary(summary, sizeof summary);
    vpm_log(self, "This session so far: %s.", summary);
}

/* The game's re-draw hooked, or why the re-stow stays on the next frame (vpm_hook has logged the refusal). */
static void HookRedraw(VpmComponent* self)
{
    s.hooked = vpm_hook(self, REDRAW_RVA, REDRAW_SHIPPED, (void*)Redraw, (void**)&s.redraw);
    vpm_log(self, "The game's re-draw (game.dll 0x%X) %s.", REDRAW_RVA, s.hooked
        ? "is hooked: a shield the game draws while it is on the back goes back inside the draw"
        : "is not hooked: a shield the game draws while it is on the back goes back on the next frame");
}

/* The three functions bound after their first bytes were checked, the "nothing held" ids read, the tick started, the
 * re-draw hooked. */
static void GameLoaded(VpmComponent* self, HfEvent event)
{
    if (s.bound) return;
    for (int i = 0; i < 3; i++)
        if (!vpm_game_code_matches(kFunctions[i].rva, kFunctions[i].prologue))
        {
            vpm_fail(self, "game function differs: %s", kFunctions[i].name);
            return;
        }
    uintptr_t game = vpm_game();
    s.set_item = (SetItemFn)(game + SET_ITEM_RVA);
    s.set_mode = (SetModeFn)(game + SET_MODE_RVA);
    s.send_held = (SendHeldFn)(game + SEND_HELD_RVA);
    s.none_item = vpm_game_u32(NONE_ITEM_RVA);
    s.none_slot = vpm_game_u32(NONE_SLOT_RVA);
    if (!vpm_tick_start(self, Step)) { vpm_fail(self, "the game thread could not be reached"); return; }
    s.bound = 1;
    vpm_log(self,"Holster Your Shield v%s initialized.", vpm_def(self)->version);
    HookRedraw(self);
}

/* Nothing to put back: the component writes no memory, and the shield stays where the game has it. The re-draw's hook
 * stays for the session (HellForge's hooks do) and only calls the original from now on. */
static void Stop(VpmComponent* self)
{
    if (!s.bound) return;
    char summary[192];
    Summary(summary, sizeof summary);
    vpm_log(self, "Stopped: %s.", summary);
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.self = self;
    if (!vpm_on_load(self, HF_EVENT_GAME_LOADED, GameLoaded)) return vpm_fail(self, "game.dll's load event refused");
    (void)vpm_listen(self, HF_ON_MISSION_END, MissionEnded, 0); /* the summary only; the core logs a refusal */
    return 0;
}

const VpmComponentDef vpm_component_holster_your_shield = {"holster_your_shield", "Holster Your Shield", "1.0", 0, Start, Stop};
