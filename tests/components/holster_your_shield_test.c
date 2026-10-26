/* Holster Your Shield: the Lua tests' scenarios (components/HolsterYourShield/tests/test_mod.lua on its simulated game,
 * tests/fake_game.lua) on the fake game: the registries laid out as the Lua's simulation lays them out, in the fake
 * game.dll image and heap.
 *
 * The game's three functions: the fake image holds their first 16 bytes for the check at HF_EVENT_GAME_LOADED; after
 * it, each function's first bytes become a jump to the test's own stand-in (as a hook would make them), which acts on
 * the row as the game does: set_item sets the held carryable, set_mode the carry mode (0 when nothing is held),
 * send_held is recorded. So the component calls game.dll's base + RVA, as it does in the game.
 *
 * The game's re-draw (0xA95A90): without a stand-in the fake image holds no code there, the hook is refused and the
 * component re-stows on the next frame (the Lua's scenarios below run that fallback). A hooked session lays the
 * re-draw's shipped bytes with a stand-in (fake_stand_in) that does what the decoded code does on the fake row: it
 * records the wield, then draws the shield when the weapon in hand is one-handed, the backpack a shield and nothing else
 * held (or the shield), with the broadcast when send is 1. The test plays the game's callers by calling the detour the
 * component hooked (fake_hook_detour), as the game's call of 0xA95A90 reaches it. */
#include <stdarg.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_holster_your_shield};

#define PLAYERS_RVA 0x3326468u
#define OWNER_RVA 0x346BF98u
#define AVATARS_RVA 0x3326D20u
#define INVENTORY_RVA 0x3326738u
#define EQUIPMENT_RVA 0x3326DC0u
#define NONE_ITEM_RVA 0x3483C4Cu
#define SET_ITEM_RVA 0x9ABC30u
#define SET_MODE_RVA 0x9AC8E0u
#define SEND_HELD_RVA 0xBE20B0u
#define REDRAW_RVA 0xA95A90u
#define REDRAW_SHIPPED "48 89 5C 24 20 57 41 54 41 57 48 83 EC 30 41 0F B6 F8 44 8B E2 44 8B 41 08"
#define REDRAW_RESULT 0x5EEDF00DCAFE1234ull /* what the re-draw's stand-in returns: the detour must pass it on */
#define OWNER_SIZE (0xF32F18u + 24u * 32u)
#define SETTINGS_SLOTS 688u
#define AVATAR 1001u
#define AVATAR_NET 5u
#define AVATAR_RECORD_INDEX 3u
#define RIFLE 2001u
#define PISTOL 2002u
#define SUPPORT 2003u
#define SHIELD 3001u
#define DIRECTIONAL 3002u
#define SUPPLY 3003u
#define DRIVE 4001u
#define PRESS_BITS 0x3C888889u /* 1/60 s held, as float bits */
#define CHECK_FRAMES 30
#define RESTOW_LIMIT 6
#define RESTOW_WINDOW 120
#define KEEP 0xFFFFFFFFu

/* {entity id, resource (low, high), equipment type, one-handed} */
typedef struct Entity { uint32_t id, low, high, type, one_handed; } Entity;
static const Entity kEntities[] = {
    {RIFLE, 0x27EE1ED8u, 0xF6FB6356u, 8, 0}, {PISTOL, 0x7B06196Eu, 0x90154C88u, 31, 1},
    {SUPPORT, 0x11111111u, 0x22222222u, 11, 0}, {SHIELD, 0x967ED15Eu, 0x0BAE363Bu, 25, 1},
    {DIRECTIONAL, 0xA4E796F8u, 0x4801B40Au, 25, 1}, {SUPPLY, 0x33333333u, 0x44444444u, 23, 0},
    {DRIVE, 0x55555555u, 0x66666666u, 30, 1},
};
#define ENTITY_COUNT ((int)(sizeof kEntities / sizeof kEntities[0]))

static const uint8_t kPrologues[3][16] = {
    {0x48, 0x89, 0x5C, 0x24, 0x18, 0x48, 0x89, 0x4C, 0x24, 0x08, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41},
    {0x48, 0x89, 0x5C, 0x24, 0x20, 0x44, 0x89, 0x44, 0x24, 0x18, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41},
    {0x48, 0x89, 0x5C, 0x24, 0x10, 0x44, 0x89, 0x4C, 0x24, 0x20, 0x57, 0x48, 0x83, 0xEC, 0x60, 0x48},
};
static const uint32_t kFunctionRvas[3] = {SET_ITEM_RVA, SET_MODE_RVA, SEND_HELD_RVA};

typedef uint64_t (*RedrawFn)(uint64_t record, uint64_t send, uint64_t blend);

static struct
{
    uint8_t *owner, *players, *manager, *inventory, *identities, *rows, *row, *avatar_record;
    uint8_t* key;
    int inert;           /* the game's functions do nothing (the game did not take the move) */
    char calls[2048];    /* the game calls made, "name,args" separated by spaces */
    char expected[512];
    char drawn[512];
    char joined[1024];
    uint64_t frame;      /* the component's frame count */
    RedrawFn detour;     /* what the component hooked at 0xA95A90 */
    int redraws;         /* calls of the re-draw's original (its stand-in) */
    uint64_t redraw_args[3];
    int redraw_inert;    /* the re-draw's stand-in wields only, it draws nothing */
    int nest;            /* the re-draw's stand-in calls the detour again from inside, this many times */
    int nest_from_mode;  /* set_mode(1) calls the detour once from inside (a re-draw inside the component's stow) */
    int fault_on_stow;   /* set_item faults when it is given "nothing held" (the component's stow) */
} w;

static volatile int* volatile g_null; /* the fault fault_on_stow makes: a write through it */

#define CHECK_CALLS(expected) do { test_checks++; if (strcmp(w.calls, (expected)) != 0) { test_failures++; \
    printf("  FAILED %s:%d: calls \"%s\", expected \"%s\"\n", __FILE__, __LINE__, w.calls, (expected)); } } while (0)

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint8_t* Game(uint32_t rva) { return (uint8_t*)fake_game() + rva; }

/* The game's map: a 20-byte header {rows, capacity, empty key 0, multiplier 2} over 8-byte rows {key, value}. */
static void Map(uint8_t* header, const uint32_t* keys, const uint32_t* values, int count, uint32_t capacity)
{
    uint8_t* rows = fake_heap(8u * capacity);
    for (int i = 0; i < count; i++)
        for (uint32_t probe = 0; probe < capacity; probe++)
        {
            uint8_t* row = rows + 8u * ((keys[i] * 2u + probe) & (capacity - 1u));
            if (Get32(row) != 0) continue;
            Put32(row, keys[i]);
            Put32(row + 4, values[i]);
            break;
        }
    Put64(header, (uintptr_t)rows);
    Put32(header + 8, capacity);
    Put32(header + 12, 0);
    Put32(header + 16, 2);
}

static void MapOne(uint8_t* header, uint32_t key, uint32_t value, uint32_t capacity) { Map(header, &key, &value, 1, capacity); }

static const Entity* Find(uint32_t id)
{
    for (int i = 0; i < ENTITY_COUNT; i++)
        if (kEntities[i].id == id) return &kEntities[i];
    return &kEntities[0];
}

static uint8_t* Record(uint32_t index, uint32_t low, uint32_t high, uint32_t entity)
{
    uint8_t* at = w.owner + 0xF32F18u + 24u * index;
    Put32(at, low);
    Put32(at + 4, high);
    Put32(at + 8, entity);
    Put32(at + 20, 1);
    return at;
}

/* The entity owner: records, the network-id map (the avatar) and the entity-id map (the avatar first, so the shield's
 * entry is the second probe). */
static void MakeEntities(void)
{
    w.owner = fake_heap(OWNER_SIZE);
    Put64(Game(OWNER_RVA), (uintptr_t)w.owner);
    uint32_t keys[ENTITY_COUNT + 1], values[ENTITY_COUNT + 1];
    w.avatar_record = Record(AVATAR_RECORD_INDEX, 0x294DFA97u, 0x4D1C334Du, AVATAR);
    keys[0] = AVATAR;
    values[0] = AVATAR_RECORD_INDEX;
    for (int i = 0; i < ENTITY_COUNT; i++)
    {
        Record(5u + (uint32_t)i, kEntities[i].low, kEntities[i].high, kEntities[i].id);
        keys[i + 1] = kEntities[i].id;
        values[i + 1] = 5u + (uint32_t)i;
    }
    MapOne(w.owner + 0xF22EC8u, AVATAR_NET, AVATAR_RECORD_INDEX, 16);
    Map(w.owner + 0xF1AEB0u, keys, values, ENTITY_COUNT + 1, 32);
}

/* The shared equipment settings: 688 slots, then records; the shield's home slot is taken by another key. */
static void MakeSettings(void)
{
    uint8_t* table = fake_heap(SETTINGS_SLOTS * 16u + 232u * 16u);
    Put64(w.owner + 0xF12BC0u, (uintptr_t)table);
    for (int n = 0; n < ENTITY_COUNT; n++)
    {
        const Entity* e = &kEntities[n];
        uint32_t slot = (uint32_t)((((uint64_t)e->high << 32) | e->low) % SETTINGS_SLOTS);
        if (e->id == SHIELD) { Put32(table + 16u * slot, 0xABCDEFu); slot = (slot + 1u) % SETTINGS_SLOTS; }
        while (Get32(table + 16u * slot) != 0 || Get32(table + 16u * slot + 4) != 0) slot = (slot + 1u) % SETTINGS_SLOTS;
        Put32(table + 16u * slot, e->low);
        Put32(table + 16u * slot + 4, e->high);
        Put32(table + 16u * slot + 8, (uint32_t)n);
        uint8_t* record = table + SETTINGS_SLOTS * 16u + 232u * (uint32_t)n;
        Put32(record + 0x80, e->type);
        Put32(record + 0xC4, e->one_handed);
    }
}

/* Per-entity EquipmentComponent copies of these entities, one-handed flipped (to tell them apart). */
static void MakeCopies(const uint32_t* copies, int count)
{
    uint8_t* block = fake_heap(160);
    uint8_t* records = fake_heap(232u * 8u);
    uint32_t values[8];
    Put64(Game(EQUIPMENT_RVA), (uintptr_t)block);
    Put64(block + 144, (uintptr_t)records);
    for (int i = 0; i < count; i++)
    {
        const Entity* e = Find(copies[i]);
        values[i] = (uint32_t)i;
        Put32(records + 232u * (uint32_t)i + 0x80, e->type);
        Put32(records + 232u * (uint32_t)i + 0xC4, e->one_handed ? 0 : 1);
    }
    Map(block + 80, copies, values, count, 16);
}

static void MakePlayersAndAvatars(void)
{
    w.players = fake_heap(0x400);
    uint8_t* player = fake_heap(24);
    Put64(Game(PLAYERS_RVA), (uintptr_t)w.players);
    Put32(player + 20, 1);
    Put32(w.players + 0x84, 1);
    Put32(w.players + 0x88, 1);
    Put64(w.players + 0xE8, (uintptr_t)player);
    Put32(w.players + 0x3A8, AVATAR_NET);
    w.manager = fake_heap(0x150u + 0x1B68u + 41u * 32u);
    Put64(Game(AVATARS_RVA), (uintptr_t)w.manager);
    MapOne(w.manager + 0xF8, AVATAR, 0, 8);
    Put32(w.manager + 0x6C, 1);
    Put64(w.manager + 0x110, (uintptr_t)w.avatar_record);
    w.key = w.manager + 0x150u + 0x1B68u + 37u * 32u + 8u;
}

/* The inventory: the avatar's row is row 1 (rifle, pistol, support weapon). */
static void MakeInventory(void)
{
    w.inventory = fake_heap(96);
    w.identities = fake_heap(32);
    w.rows = fake_heap(48u * 4u);
    Put64(Game(INVENTORY_RVA), (uintptr_t)w.inventory);
    MapOne(w.inventory + 40, AVATAR, 1, 16);
    Put64(w.identities + 8, (uintptr_t)w.avatar_record);
    Put64(w.inventory + 64, (uintptr_t)w.identities);
    Put64(w.inventory + 80, (uintptr_t)w.rows);
    w.row = w.rows + 48;
    Put32(w.row, RIFLE);
    Put32(w.row + 4, PISTOL);
    Put32(w.row + 8, SUPPORT);
}

/* The world of one local Helldiver with a rifle, a pistol, a support weapon; copies: entities with a per-entity
 * equipment copy. */
static void World(const uint32_t* copies, int count)
{
    memset(&w, 0, sizeof w);
    MakeEntities();
    MakeSettings();
    MakeCopies(copies, count);
    MakePlayersAndAvatars();
    MakeInventory();
    for (int i = 0; i < 3; i++) memcpy(Game(kFunctionRvas[i]), kPrologues[i], 16);
}

static void SetRow(uint32_t backpack, uint32_t held, uint32_t slot, uint32_t mode)
{
    if (backpack != KEEP) Put32(w.row + 12, backpack);
    if (held != KEEP) Put32(w.row + 20, held);
    if (slot != KEEP) Put32(w.row + 28, slot);
    if (mode != KEEP) Put32(w.row + 32, mode);
}

static uint32_t Held(void) { return Get32(w.row + 20); }
static uint32_t Mode(void) { return Get32(w.row + 32); }
static void KeyDown(void) { Put32(w.key, PRESS_BITS); }
static void KeyUp(void) { Put32(w.key, 0); }
/* The game draws the shield (0xA95A90 after a one-handed wield). */
static void GameDraws(void) { SetRow(KEEP, Get32(w.row + 12), KEEP, 2); }

/* The game moves the inventory rows (a death in the squad): the avatar's row index changes. */
static void MoveRow(uint32_t index)
{
    uint8_t* to = w.rows + 48u * index;
    memcpy(to, w.row, 48);
    memset(w.row, 0, 48);
    Put64(w.identities + 8u * index, (uintptr_t)w.avatar_record);
    MapOne(w.inventory + 40, AVATAR, index, 16);
    w.row = to;
}

/* A new avatar entity (a respawn): same record slot, new entity id; the maps follow. */
static void Respawn(uint32_t entity)
{
    Put32(w.avatar_record + 8, entity);
    MapOne(w.manager + 0xF8, entity, 0, 8);
    MapOne(w.inventory + 40, entity, 1, 16);
}

/* ---- the game's functions -------------------------------------------------------------------------------------- */

static void Called(const char* format, ...) __attribute__((format(printf, 1, 2)));
static void Called(const char* format, ...)
{
    size_t used = strlen(w.calls);
    if (used > 0 && used + 1 < sizeof w.calls) w.calls[used++] = ' ';
    va_list args;
    va_start(args, format);
    vsnprintf(w.calls + used, sizeof w.calls - used, format, args);
    va_end(args);
}

static uint8_t* RowOf(uint64_t inventory, uint32_t avatar)
{
    if (inventory != (uintptr_t)w.inventory || w.inert || avatar != Get32(w.avatar_record + 8)) return NULL;
    return w.row;
}

static void GameSetItem(uint64_t inventory, uint32_t avatar, uint32_t item)
{
    Called("set_item,%llu,%u,%u", (unsigned long long)inventory, avatar, item);
    if (w.fault_on_stow && item == 0) *g_null = 1; /* in the test's image: the crash guard takes it, as a fault of the pack */
    uint8_t* row = RowOf(inventory, avatar);
    if (row != NULL) Put32(row + 20, item);
}

static uint64_t GameSetMode(uint64_t inventory, uint32_t avatar, uint32_t mode)
{
    Called("set_mode,%llu,%u,%u", (unsigned long long)inventory, avatar, mode);
    if (w.nest_from_mode && mode == 1)
    {
        w.nest_from_mode = 0;
        w.redraw_inert = 1;
        (void)w.detour((uintptr_t)w.avatar_record, 1, 1);
        w.redraw_inert = 0;
    }
    uint8_t* row = RowOf(inventory, avatar);
    if (row != NULL) Put32(row + 32, Get32(row + 20) == 0 ? 0 : mode);
    return 0;
}

static void GameSendHeld(int64_t peer, uint32_t avatar, uint32_t item, uint32_t mode)
{
    Called("send_held,%lld,%u,%u,%u", (long long)peer, avatar, item, mode);
}

/* The shield's draw at the end of 0xA95A90, by the decoded code's conditions: only the row of the avatar owned here
 * (other Helldivers have none in this world), a one-handed weapon in the slot in hand, a type-25 backpack, nothing held
 * or the shield itself; set_item and set_mode(2), and the broadcast when send is 1. With w.nest, the re-draw is called
 * again between set_mode and the broadcast (where an animation event set_mode fires could run one). */
static void GameDrawsTheShield(uint64_t record, uint64_t send, uint64_t blend)
{
    uint32_t avatar = Get32((const uint8_t*)(uintptr_t)record + 8);
    if (w.redraw_inert || avatar != Get32(w.avatar_record + 8)) return;
    uint32_t slot = Get32(w.row + 28), backpack = Get32(w.row + 12), held = Get32(w.row + 20);
    if (slot < 1 || slot > 3 || !Find(Get32(w.row + 4u * (slot - 1u)))->one_handed) return;
    if (backpack == 0 || Find(backpack)->type != 25 || (held != 0 && held != backpack)) return;
    GameSetItem((uintptr_t)w.inventory, avatar, backpack);
    (void)GameSetMode((uintptr_t)w.inventory, avatar, 2);
    if (w.nest > 0)
    {
        w.nest--;
        (void)w.detour(record, send, blend);
    }
    if ((uint32_t)send == 1) GameSendHeld(-2, avatar, backpack, 2);
}

/* The re-draw's stand-in (the original the detour calls): the weapon's wield, recorded with its registers, then the
 * draw; it returns REDRAW_RESULT. */
static uint64_t GameRedraw(uint64_t record, uint64_t send, uint64_t blend)
{
    w.redraws++;
    w.redraw_args[0] = record;
    w.redraw_args[1] = send;
    w.redraw_args[2] = blend;
    Called("redraw,%u,%llu,%llu", Get32((const uint8_t*)(uintptr_t)record + 8), (unsigned long long)send, (unsigned long long)blend);
    GameDrawsTheShield(record, send, blend);
    return REDRAW_RESULT;
}

/* The function's first bytes become mov rax, target; jmp rax, on an executable page. */
static void JumpTo(uint32_t rva, uintptr_t target)
{
    uint8_t* at = Game(rva);
    uint8_t stub[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
    DWORD old;
    memcpy(stub + 2, &target, 8);
    CHECK(VirtualProtect(at, sizeof stub, PAGE_EXECUTE_READWRITE, &old)); /* lint-ok: C3 the test's own fake image runs the stub */
    memcpy(at, stub, sizeof stub);
    CHECK(FlushInstructionCache(GetCurrentProcess(), at, sizeof stub)); /* lint-ok: C3 the stub the test just wrote */
}

/* ---- sessions ---------------------------------------------------------------------------------------------------- */

static void Session(int inert)
{
    w.inert = inert;
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    JumpTo(SET_ITEM_RVA, (uintptr_t)GameSetItem);
    JumpTo(SET_MODE_RVA, (uintptr_t)GameSetMode);
    JumpTo(SEND_HELD_RVA, (uintptr_t)GameSendHeld);
}

static void Frames(int n)
{
    fake_frames(n, 1.0f / 60);
    w.frame += (uint64_t)n;
}

static FakeCounts Frame(void)
{
    fake_counts_reset();
    Frames(1);
    return fake_counts();
}

/* Steps until a check frame has resolved (the first resolution happens on a check frame). */
static void Settle(void)
{
    Frames(CHECK_FRAMES + 1);
    CHECK_LOG("Found your Helldiver (avatar 1001, inventory row 1).");
}

static void ClearCalls(void) { w.calls[0] = 0; }

/* A session with the shield (in hand, the pistol out), settled. */
static void ShieldInHandWith(const uint32_t* copies, int count, int inert)
{
    World(copies, count);
    SetRow(SHIELD, SHIELD, 2, 2);
    Session(inert);
    Settle();
    ClearCalls();
}

static void ShieldInHand(void) { ShieldInHandWith(NULL, 0, 0); }

/* One press: the key down for a frame, then up. */
static FakeCounts Press(void)
{
    KeyDown();
    FakeCounts counts = Frame();
    KeyUp();
    return counts;
}

static const char* Expected(uint32_t shield, uint32_t item, uint32_t mode)
{
    unsigned long long inventory = (unsigned long long)(uintptr_t)w.inventory;
    snprintf(w.expected, sizeof w.expected, "set_item,%llu,%u,%u set_mode,%llu,%u,%u send_held,-2,%u,%u,%u", inventory,
        Get32(w.avatar_record + 8), item, inventory, Get32(w.avatar_record + 8), mode, Get32(w.avatar_record + 8), shield, mode);
    return w.expected;
}

static const char* Holster(uint32_t shield) { return Expected(shield, 0, 1); }
static const char* Draw(uint32_t shield) { return Expected(shield, shield, 2); }

static void MissionEnds(void)
{
    HfStateEvent end = {{sizeof end, HF_ON_MISSION_END, 1}, HF_STATE_MISSION, HF_STATE_SHIP};
    fake_emit(&end.info);
}

/* ---- the re-draw hook's sessions ---------------------------------------------------------------------------------- */

/* A session whose game.dll has the re-draw's shipped bytes, with its stand-in: the hook goes in. */
static void HookedSession(void)
{
    fake_stand_in(REDRAW_RVA, REDRAW_SHIPPED, (void*)GameRedraw);
    Session(0);
    w.detour = (RedrawFn)fake_hook_detour(fake_game() + REDRAW_RVA);
    CHECK(w.detour != NULL);
}

/* The shield in hand with the pistol out, hooked, settled. */
static void HookedShieldInHand(void)
{
    World(NULL, 0);
    SetRow(SHIELD, SHIELD, 2, 2);
    HookedSession();
    Settle();
    ClearCalls();
}

/* Then pressed: the toggle on, the shield on the back, the move checked. */
static void HookedShieldOnTheBack(void)
{
    HookedShieldInHand();
    Press();
    Frame();
    CHECK_LOG("Shield to the back: done (held 0, mode 0).");
    ClearCalls();
}

/* The game wields the weapon in hand for this avatar record: its call of 0xA95A90, which reaches the detour. */
static uint64_t WieldFor(const uint8_t* record, uint64_t send, uint64_t blend) { return w.detour((uintptr_t)record, send, blend); }
static uint64_t Wield(uint64_t send, uint64_t blend) { return WieldFor(w.avatar_record, send, blend); }

/* The same, with the calls it made counted. */
static FakeCounts WieldCounted(uint64_t send, uint64_t blend)
{
    fake_counts_reset();
    CHECK(Wield(send, blend) == REDRAW_RESULT);
    return fake_counts();
}

/* The calls GameRedraw records for one call of it on the avatar's row: the wield, then the draw when it draws. */
static const char* GameDraw(uint64_t send, uint64_t blend, int draws)
{
    unsigned long long inventory = (unsigned long long)(uintptr_t)w.inventory;
    uint32_t avatar = Get32(w.avatar_record + 8), backpack = Get32(w.row + 12);
    int n = snprintf(w.drawn, sizeof w.drawn, "redraw,%u,%llu,%llu", avatar, (unsigned long long)send, (unsigned long long)blend);
    if (draws)
        n += snprintf(w.drawn + n, sizeof w.drawn - (size_t)n, " set_item,%llu,%u,%u set_mode,%llu,%u,2", inventory, avatar,
            backpack, inventory, avatar);
    if (draws && send == 1) snprintf(w.drawn + n, sizeof w.drawn - (size_t)n, " send_held,-2,%u,%u,2", avatar, backpack);
    return w.drawn;
}

static const char* Then(const char* first, const char* second)
{
    snprintf(w.joined, sizeof w.joined, "%s %s", first, second);
    return w.joined;
}

/* ---- the Lua's scenarios ----------------------------------------------------------------------------------------- */

static void APressWithTheShieldInHandPutsItOnTheBack(void)
{
    ShieldInHand();
    Press();
    CHECK_CALLS(Holster(SHIELD));
    CHECK_EQ(Held(), 0);
    CHECK_EQ(Mode(), 0);
    Frame();
    CHECK_LOG("Shield to the back: done (held 0, mode 0).");
}

static void TheGameDrawsTheShieldWhileToggled(void)
{
    ShieldInHand();
    Press();
    Frames(3);
    ClearCalls();
    GameDraws(); /* a weapon switch back to a one-handed weapon */
    Frame();
    CHECK_CALLS(Holster(SHIELD));
    Frame();
    CHECK_LOG("Shield back to the back after the game drew it: done (held 0, mode 0).");
    MissionEnds();
    CHECK_LOG("This session so far: presses 1, to the back 2 (re-stows 1), to the hand 0, checks done 2, failed 0, refused 0.");
}

static void APressWhileToggledBringsTheShieldBack(void)
{
    ShieldInHand();
    Press();
    Frames(2);
    ClearCalls();
    Press();
    CHECK_CALLS(Draw(SHIELD));
    CHECK_EQ(Held(), SHIELD);
    CHECK_EQ(Mode(), 2);
    Frame();
    CHECK_LOG("Shield to the hand: done (held 3001, mode 2).");
    Frames(5); /* the toggle is off: the shield in hand stays */
    CHECK_CALLS(Draw(SHIELD));
}

static void APressWhileToggledWithATwoHandedWeaponOnlyEndsTheToggle(void)
{
    ShieldInHand();
    Press();
    Frames(2);
    SetRow(KEEP, KEEP, 1, KEEP); /* the rifle; the shield is already on the back */
    ClearCalls();
    Press();
    CHECK_CALLS("");
    CHECK_LOG("Shield toggle off: it returns with the next one-handed weapon.");
    GameDraws();
    Frame();
    CHECK_CALLS("");
}

static void APressWithTheShieldOnTheBackKeepsItThereThroughTheNextDraw(void)
{
    ShieldInHand();
    SetRow(KEEP, 0, 1, 1);
    Frames(2);
    ClearCalls();
    Press();
    CHECK_CALLS("");
    CHECK_LOG("Press with the shield on the back: it stays there.");
    SetRow(KEEP, KEEP, 2, KEEP);
    GameDraws();
    Frame();
    CHECK_CALLS(Holster(SHIELD));
}

static void CarryingAnObjectiveAPressOnlyFlipsTheToggle(void)
{
    ShieldInHand();
    SetRow(KEEP, DRIVE, KEEP, 2);
    Frames(2);
    ClearCalls();
    Press();
    CHECK_CALLS("");
    CHECK_LOG("Press while carrying something else: the shield stays on the back.");
    Frames(5);
    CHECK_CALLS(""); /* nothing done to the objective */
    GameDraws();     /* dropping the objective draws the shield */
    Frame();
    CHECK_CALLS(Holster(SHIELD));
}

static void TheDirectionalShieldWorksTheSameWay(void)
{
    World(NULL, 0);
    SetRow(DIRECTIONAL, DIRECTIONAL, 2, 2);
    Session(0);
    Settle();
    CHECK_LOG("Shield backpack 3002 worn: Backpack Function toggles it.");
    ClearCalls();
    Press();
    CHECK_CALLS(Holster(DIRECTIONAL));
}

static void OtherBackpacksNeverReadTheKey(void)
{
    World(NULL, 0);
    SetRow(SUPPLY, 0, 2, 0);
    Session(0);
    Settle();
    ClearCalls();
    FakeCounts counts = Press();
    CHECK_EQ(counts.read, 1); /* the row only */
    CHECK_CALLS("");
    CHECK_NO_LOG("Shield backpack");
    MissionEnds();
    CHECK_LOG("This session so far: presses 0,");
}

static void AHeldKeyCountsOnce(void)
{
    ShieldInHand();
    KeyDown();
    Frames(10);
    KeyUp();
    MissionEnds();
    CHECK_LOG("This session so far: presses 1, to the back 1 (re-stows 0)");
}

static void RestowsStopAfterTheLimit(void)
{
    ShieldInHand();
    Press();
    for (int i = 0; i < RESTOW_LIMIT + 3; i++)
    {
        GameDraws();
        Frame();
    }
    CHECK_LOG("Shield toggle off: the game drew the shield 7 times in 120 frames, so it stays in hand.");
    CHECK_EQ(Held(), SHIELD); /* the game keeps it in hand */
    CHECK_EQ(Mode(), 2);
    MissionEnds();
    CHECK_LOG("presses 1, to the back 7 (re-stows 6), to the hand 0, checks done 0, failed 7, refused 0.");
    /* spread out over the window, re-stows go on */
    fake_setup();
    ShieldInHand();
    Press();
    for (int i = 0; i < 10; i++)
    {
        Frames(RESTOW_WINDOW / 4);
        GameDraws();
        Frame();
    }
    CHECK_NO_LOG("Shield toggle off");
    MissionEnds();
    CHECK_LOG("to the back 11 (re-stows 10)");
}

static void AMoveTheGameDoesNotTakeIsLoggedAsFailed(void)
{
    ShieldInHandWith(NULL, 0, 1);
    Press();
    Frame();
    CHECK_LOG("Shield to the back: FAILED, the game did not take it (held 3001, mode 2).");
    MissionEnds();
    CHECK_LOG("checks done 0, failed 1, refused 0.");
}

static void APressWhenTheAvatarIsNoLongerOwnedMakesNoCall(void)
{
    ShieldInHand();
    Put32(w.avatar_record + 20, 0);
    Press();
    CHECK_CALLS("");
    CHECK_LOG("Press refused: not an owned Helldiver avatar.");
}

static void APerEntityEquipmentCopyIsWhatIsRead(void)
{
    /* the copy flips the pistol to two-handed: a press while toggled must not draw */
    const uint32_t pistol = PISTOL, shield = SHIELD;
    ShieldInHandWith(&pistol, 1, 0);
    Press();
    Frames(2);
    ClearCalls();
    Press();
    CHECK_CALLS("");
    /* a copy of the shield with its type is still a shield */
    fake_setup();
    ShieldInHandWith(&shield, 1, 0);
    Press();
    CHECK_CALLS(Holster(SHIELD));
}

static void RowsMovedByTheGameKeepTheToggle(void)
{
    ShieldInHand();
    Press();
    Frames(2);
    MoveRow(2);
    Frames(CHECK_FRAMES);
    CHECK_NO_LOG("Shield toggle off");
    ClearCalls();
    GameDraws();
    Frame();
    CHECK_CALLS(Holster(SHIELD));
}

static void ANewHelldiverEndsTheToggle(void)
{
    ShieldInHand();
    Press();
    Frames(2);
    Respawn(1777);
    Frames(CHECK_FRAMES);
    CHECK_LOG("Shield toggle off: a new Helldiver.");
    CHECK_LOG("Found your Helldiver (avatar 1777, inventory row 1).");
    ClearCalls();
    GameDraws();
    Frame();
    CHECK_CALLS("");
}

/* ---- calls per frame (the Lua's frame_budget pins: views and pointer reads; here the image globals are plain loads) */

static void NoLocalPlayerReadsOnCheckFramesOnly(void)
{
    World(NULL, 0);
    Put32(w.players + 0x84, 0);
    Session(0);
    for (int i = 1; i < CHECK_FRAMES; i++)
    {
        FakeCounts c = Frame();
        CHECK_EQ(c.read + c.write + c.log + c.code_matches + c.other, 0);
    }
    FakeCounts c = Frame(); /* the Lua: 2 pointer reads and 1 view */
    CHECK_EQ(c.read, 1);
    CHECK_EQ(c.log, 0);
}

static void IdleFramesReadTheRowAndTheKey(void)
{
    ShieldInHand();
    SetRow(SUPPLY, 0, KEEP, 0);
    Frame(); /* the backpack change reads the supply pack's settings once */
    for (int i = 0; i < 5; i++)
    {
        FakeCounts c = Frame(); /* the Lua: 1 view */
        CHECK_EQ(c.read, 1);
        CHECK_EQ(c.write + c.log, 0);
    }
    fake_setup();
    ShieldInHand();
    for (int i = 0; i < 5; i++)
    {
        FakeCounts c = Frame(); /* the Lua: 2 views */
        CHECK_EQ(c.read, 2);
        CHECK_EQ(c.write + c.log, 0);
    }
    while ((w.frame + 1) % CHECK_FRAMES != 0) Frames(1);
    FakeCounts c = Frame(); /* the Lua: 5 views and 3 pointer reads */
    CHECK_EQ(c.read, 6);
    CHECK_EQ(c.write + c.log, 0);
}

static void MovesReadEverythingAgain(void)
{
    ShieldInHand();
    FakeCounts c = Press(); /* a press that stows; the Lua: 25 views and 12 pointer reads */
    CHECK_EQ(c.read, 31);
    CHECK_EQ(c.write, 0);
    CHECK_CALLS(Holster(SHIELD));
    c = Frame(); /* the check of the move; the Lua: 2 views */
    CHECK_EQ(c.read, 2);
    CHECK_EQ(c.log, 1);
    Frames(3);
    ClearCalls();
    c = Press(); /* a press that draws; the Lua: 34 views and 15 pointer reads */
    CHECK_EQ(c.read, 41);
    CHECK_CALLS(Draw(SHIELD));
    Frames(3);
    Press();
    Frames(3);
    ClearCalls();
    GameDraws();
    c = Frame(); /* a re-stow; the Lua: 25 views and 12 pointer reads */
    CHECK_EQ(c.read, 31);
    CHECK_EQ(c.write, 0);
    CHECK_CALLS(Holster(SHIELD));
}

/* ---- the session ------------------------------------------------------------------------------------------------- */

static void BindChecksTheFunctionsOnce(void)
{
    World(NULL, 0);
    fake_start(kDefs, 1);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    FakeCounts c = fake_counts();
    /* the three functions, and the re-draw's bytes for its hook: not in this fake image, so refused (the fallback) */
    CHECK_EQ(c.code_matches, 4);
    CHECK_EQ(c.hook, 0);
    CHECK_EQ(c.read + c.write, 0);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_LOG("[Holster Your Shield] Holster Your Shield v1.0 initialized.");
    CHECK_LOG("[Holster Your Shield] hook refused: game.dll+0xA95A90 is not the reviewed function");
    CHECK_LOG("[Holster Your Shield] The game's re-draw (game.dll 0xA95A90) is not hooked: a shield the game draws while it is on the back goes back on the next frame.");
}

static void BindRefusesAFunctionWhoseFirstBytesDiffer(void)
{
    World(NULL, 0);
    Game(SET_MODE_RVA)[0] = 0xC3;
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(!vpm_ticking(fake_component(0)));
    CHECK_LOG("[Holster Your Shield] disabled: game function differs: set_mode");
    CHECK_NO_LOG("Stopped:");
    CHECK_EQ(fake_counts().hook, 0); /* nothing hooked for a component that did not start */
}

static void TheNothingHeldIdsAreReadAtLoad(void)
{
    World(NULL, 0);
    Put32(Game(NONE_ITEM_RVA), 7);
    SetRow(SHIELD, SHIELD, 2, 2);
    Session(0);
    Settle();
    ClearCalls();
    Press();
    CHECK_CALLS(Expected(SHIELD, 7, 1));
    Frame();
    CHECK_LOG("Shield to the back: done (held 7, mode 1).");
}

static void AnotherBuildStartsNothing(void)
{
    fake_set_build("25480437");
    World(NULL, 0);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    CHECK(!vpm_running(fake_component(0)));
    CHECK(!vpm_ticking(fake_component(0)));
    CHECK_EQ(fake_counts().code_matches, 0);
}

static void AStopLogsTheSummary(void)
{
    ShieldInHand();
    Press();
    Frame();
    vpm_core_stop(fake_component(0), "test");
    CHECK_LOG("[Holster Your Shield] Stopped: presses 1, to the back 1 (re-stows 0), to the hand 0, checks done 1, failed 0, refused 0.");
    CHECK(!vpm_ticking(fake_component(0)));
}

/* ---- the game's re-draw, hooked ---------------------------------------------------------------------------------- */

static void TheHookGoesInAtLoad(void)
{
    World(NULL, 0);
    fake_stand_in(REDRAW_RVA, REDRAW_SHIPPED, (void*)GameRedraw);
    fake_start(kDefs, 1);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    FakeCounts c = fake_counts();
    CHECK_EQ(c.code_matches, 4);
    CHECK_EQ(c.hook, 1);
    CHECK_EQ(c.read + c.write, 0);
    CHECK_EQ(fake_hook_count(), 1);
    CHECK(fake_hook_at(0).target == fake_game() + REDRAW_RVA);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_LOG("[Holster Your Shield] The game's re-draw (game.dll 0xA95A90) is hooked: a shield the game draws while it is on the back goes back inside the draw.");
}

static void AGameDrawWhileHolsteredGoesBackInsideIt(void)
{
    HookedShieldOnTheBack();
    /* a weapon switch to the pistol (send 1): the original once, with the caller's registers, its result passed on;
     * the shield drawn and stowed in the same call, the stow last */
    FakeCounts c = WieldCounted(1, 1);
    CHECK_EQ(w.redraws, 1);
    CHECK(w.redraw_args[0] == (uintptr_t)w.avatar_record && w.redraw_args[1] == 1 && w.redraw_args[2] == 1);
    CHECK_CALLS(Then(GameDraw(1, 1, 1), Holster(SHIELD)));
    CHECK_EQ(Held(), 0); /* before any frame */
    CHECK_EQ(Mode(), 0);
    CHECK_EQ(c.read, 31);
    CHECK_EQ(c.write + c.code_matches + c.hook, 0);
    ClearCalls();
    Frame();
    CHECK_LOG("Shield kept on the back as the game drew it: done (held 0, mode 0).");
    Frames(5);
    CHECK_CALLS(""); /* nothing for the next frame's re-stow to do */
    /* an animation event's re-wield (send 0): the game broadcasts nothing; the stow sends mode 1, as the 1:1 re-stow */
    CHECK(Wield(0, 1) == REDRAW_RESULT);
    CHECK_CALLS(Then(GameDraw(0, 1, 1), Holster(SHIELD)));
    Frame();
    CHECK_NO_LOG("after the game drew it");
    MissionEnds();
    CHECK_LOG("This session so far: presses 1, to the back 3 (re-stows 2, 2 inside the game's draw), to the hand 0, checks done 3, failed 0, refused 0.");
}

static void TheRegistersArePassedOnWhole(void)
{
    HookedShieldOnTheBack();
    /* the callers set only edx and r8b: whatever the rest of rdx and r8 holds reaches the original as it was */
    const uint64_t send = 0xFFFFFFFF00000001ull, blend = 0x0123456789ABCD01ull;
    CHECK(Wield(send, blend) == REDRAW_RESULT);
    CHECK_EQ(w.redraws, 1);
    CHECK(w.redraw_args[0] == (uintptr_t)w.avatar_record && w.redraw_args[1] == send && w.redraw_args[2] == blend);
    CHECK_EQ(Held(), 0);
}

static void WithoutTheToggleTheDetourOnlyCallsTheOriginal(void)
{
    HookedShieldInHand();
    FakeCounts c = WieldCounted(1, 1); /* the game draws the shield in hand again, as it does */
    CHECK_EQ(c.read, 0);
    CHECK_EQ(w.redraws, 1);
    CHECK_CALLS(GameDraw(1, 1, 1));
    CHECK_EQ(Held(), SHIELD);
    Frames(5);
    CHECK_CALLS(GameDraw(1, 1, 1));
}

static void OtherHelldiversAreLeftToTheGame(void)
{
    HookedShieldOnTheBack();
    uint8_t* other = fake_heap(24); /* another player's avatar record in this world */
    Put32(other + 8, 1500);
    fake_counts_reset();
    CHECK(WieldFor(other, 1, 1) == REDRAW_RESULT);
    CHECK_EQ(fake_counts().read, 1); /* its entity id only */
    CHECK_EQ(w.redraws, 1);
    CHECK_CALLS("redraw,1500,1,1");
    CHECK_EQ(Held(), 0);
}

static void ATwoHandedWeaponDrawsNothingToPutBack(void)
{
    HookedShieldOnTheBack();
    SetRow(KEEP, KEEP, 1, KEEP); /* the rifle */
    FakeCounts c = WieldCounted(1, 1);
    CHECK_EQ(c.read, 2); /* the entity id and the row */
    CHECK_CALLS(GameDraw(1, 1, 0));
    CHECK_EQ(Held(), 0);
    Frames(3);
    CHECK_CALLS(GameDraw(1, 1, 0));
}

static void AnObjectiveCarriedIsLeftAloneAndItsDropIsCaughtNextFrame(void)
{
    HookedShieldOnTheBack();
    SetRow(KEEP, DRIVE, KEEP, 2);
    FakeCounts c = WieldCounted(1, 1); /* the game draws nothing while the objective is held */
    CHECK_EQ(c.read, 2);
    CHECK_CALLS(GameDraw(1, 1, 0));
    CHECK_EQ(Held(), DRIVE);
    ClearCalls();
    /* dropping it draws the shield through 0xA44B40, not the re-draw: the next frame's re-stow is the safety net */
    GameDraws();
    Frame();
    CHECK_CALLS(Holster(SHIELD));
    Frame();
    CHECK_LOG("Shield back to the back after the game drew it: done (held 0, mode 0).");
    MissionEnds();
    CHECK_LOG("(re-stows 1, 0 inside the game's draw)");
}

static void ARespawnEndsTheToggleWithoutAStow(void)
{
    HookedShieldOnTheBack();
    Respawn(1777);
    fake_counts_reset();
    CHECK(Wield(1, 1) == REDRAW_RESULT); /* the new avatar's first wield: not the toggled entity */
    CHECK_EQ(fake_counts().read, 1);
    CHECK_CALLS(GameDraw(1, 1, 1));
    Frames(CHECK_FRAMES);
    CHECK_LOG("Shield toggle off: a new Helldiver.");
    CHECK_LOG("Found your Helldiver (avatar 1777, inventory row 1).");
    CHECK_CALLS(GameDraw(1, 1, 1)); /* the new Helldiver keeps the shield the game drew */
    CHECK_EQ(Held(), SHIELD);
    ClearCalls();
    CHECK(Wield(1, 1) == REDRAW_RESULT);
    CHECK_CALLS(GameDraw(1, 1, 1));
}

static void AStoppedComponentOnlyCallsTheOriginal(void)
{
    HookedShieldOnTheBack();
    vpm_core_stop(fake_component(0), "test");
    CHECK_LOG("[Holster Your Shield] Stopped: presses 1, to the back 1 (re-stows 0, 0 inside the game's draw), to the hand 0, checks done 1, failed 0, refused 0.");
    FakeCounts c = WieldCounted(1, 1);
    CHECK_EQ(c.read + c.log, 0);
    CHECK_EQ(w.redraws, 1);
    CHECK_CALLS(GameDraw(1, 1, 1));
    CHECK_EQ(Held(), SHIELD); /* the game's draw stands */
}

static void AFaultInTheDetourWorkStopsTheComponent(void)
{
    HookedShieldOnTheBack();
    w.fault_on_stow = 1;
    CHECK(Wield(1, 1) == REDRAW_RESULT); /* the original ran once, and its result came back */
    CHECK_EQ(w.redraws, 1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Holster Your Shield] disabled: fault 0xC0000005");
    CHECK_LOG("[Holster Your Shield] Stopped:");
    w.fault_on_stow = 0;
    ClearCalls();
    SetRow(KEEP, 0, KEEP, 0);
    fake_counts_reset();
    CHECK(Wield(1, 1) == REDRAW_RESULT); /* from now on only the original */
    CHECK_EQ(fake_counts().read, 0);
    CHECK_EQ(w.redraws, 2);
    CHECK_CALLS(GameDraw(1, 1, 1));
    CHECK_EQ(Held(), SHIELD);
}

static void ANestedReDrawIsTheGamesAndTheStowComesLast(void)
{
    HookedShieldOnTheBack();
    /* a re-draw called from inside the draw, before its broadcast: it only calls the original (which draws the held
     * shield again), and the outermost call stows once, after both broadcasts, so the other players see the stow last */
    unsigned long long inventory = (unsigned long long)(uintptr_t)w.inventory;
    char draw[256], expected[1024];
    snprintf(draw, sizeof draw, "set_item,%llu,1001,3001 set_mode,%llu,1001,2", inventory, inventory);
    snprintf(expected, sizeof expected, "redraw,1001,1,1 %s redraw,1001,1,1 %s send_held,-2,1001,3001,2 send_held,-2,1001,3001,2 %s",
        draw, draw, Holster(SHIELD));
    w.nest = 1;
    FakeCounts c = WieldCounted(1, 1);
    CHECK_EQ(w.redraws, 2);
    CHECK_CALLS(expected);
    CHECK_EQ(c.read, 31); /* the nested call read nothing */
    CHECK_EQ(Held(), 0);
    Frame();
    CHECK_LOG("Shield kept on the back as the game drew it: done (held 0, mode 0).");
    MissionEnds();
    CHECK_LOG("(re-stows 1, 1 inside the game's draw)");
}

static void AReDrawInsideTheComponentsOwnStowIsTheGames(void)
{
    /* the press while the hook is in, with a re-draw from inside its set_mode (as an animation event could run one): the
     * detour only calls the original, the press makes its three calls once */
    HookedShieldInHand();
    w.nest_from_mode = 1;
    FakeCounts c = Press();
    unsigned long long inventory = (unsigned long long)(uintptr_t)w.inventory;
    char expected[512];
    snprintf(expected, sizeof expected, "set_item,%llu,1001,0 set_mode,%llu,1001,1 redraw,1001,1,1 send_held,-2,1001,3001,1",
        inventory, inventory);
    CHECK_CALLS(expected);
    CHECK_EQ(w.redraws, 1);
    CHECK_EQ(c.read, 31); /* as without the hook */
    Frame();
    CHECK_LOG("Shield to the back: done (held 0, mode 0).");
}

static void ThePressWhileTheHookIsIn(void)
{
    HookedShieldInHand();
    FakeCounts c = Press(); /* the press stows as without the hook: the detour plays no part */
    CHECK_CALLS(Holster(SHIELD));
    CHECK_EQ(c.read, 31);
    CHECK_EQ(w.redraws, 0);
    Frame();
    ClearCalls();
    CHECK(Wield(1, 1) == REDRAW_RESULT);
    CHECK_CALLS(Then(GameDraw(1, 1, 1), Holster(SHIELD)));
    Frames(3);
    ClearCalls();
    c = Press(); /* pressed again: the toggle off, the shield to the hand */
    CHECK_CALLS(Draw(SHIELD));
    CHECK_EQ(c.read, 41);
    Frame();
    CHECK_LOG("Shield to the hand: done (held 3001, mode 2).");
    ClearCalls();
    c = WieldCounted(1, 1); /* the toggle is off: the game's re-draw stands */
    CHECK_EQ(c.read, 0);
    CHECK_CALLS(GameDraw(1, 1, 1));
    CHECK_EQ(Held(), SHIELD);
}

static void TheLimitHoldsInsideTheDraw(void)
{
    HookedShieldOnTheBack();
    for (int i = 0; i < RESTOW_LIMIT + 1; i++)
    {
        ClearCalls();
        CHECK(Wield(1, 1) == REDRAW_RESULT);
        if (i < RESTOW_LIMIT) CHECK_CALLS(Then(GameDraw(1, 1, 1), Holster(SHIELD)));
        else CHECK_CALLS(GameDraw(1, 1, 1)); /* the seventh in the window stays in hand */
        Frame();
    }
    CHECK_LOG("Shield toggle off: the game drew the shield 7 times in 120 frames, so it stays in hand.");
    CHECK_EQ(Held(), SHIELD);
    CHECK_EQ(Mode(), 2);
    MissionEnds();
    CHECK_LOG("presses 1, to the back 7 (re-stows 6, 6 inside the game's draw), to the hand 0, checks done 7, failed 0, refused 0.");
}

static void TheHookRefusedForOtherBytesLeavesTheReStowNextFrame(void)
{
    World(NULL, 0);
    SetRow(SHIELD, SHIELD, 2, 2);
    /* +4: 0x18, not 0x20 (another build's frame) */
    fake_stand_in(REDRAW_RVA, "48 89 5C 24 18 57 41 54 41 57 48 83 EC 30 41 0F B6 F8 44 8B E2 44 8B 41 08", (void*)GameRedraw);
    Session(0);
    CHECK_LOG("[Holster Your Shield] hook refused: game.dll+0xA95A90 is not the reviewed function");
    CHECK_LOG("is not hooked: a shield the game draws while it is on the back goes back on the next frame.");
    CHECK_EQ(fake_hook_count(), 0);
    CHECK(vpm_running(fake_component(0)));
    Settle();
    Press();
    Frames(2);
    ClearCalls();
    GameDraws();
    FakeCounts c = Frame(); /* the fallback: the 1:1 re-stow, as before the hook */
    CHECK_CALLS(Holster(SHIELD));
    CHECK_EQ(c.read, 31);
    Frame();
    CHECK_LOG("Shield back to the back after the game drew it: done (held 0, mode 0).");
    MissionEnds();
    CHECK_LOG("presses 1, to the back 2 (re-stows 1), to the hand 0,"); /* the Lua's summary, word for word */
}

static int HookExRefused(HfMod* mod, uintptr_t target, void* detour, void** original, int32_t priority) { return 1; }
static const char* LastLogText(HfMod* mod) { return "more than 16 hooks on one function"; }

static void TheHookRefusedByHellForgeLeavesTheReStowNextFrame(void)
{
    static HfApi refusing; /* the core keeps the API it was given */
    refusing = *fake_api();
    refusing.hook_ex = HookExRefused;
    refusing.last_log = LastLogText;
    World(NULL, 0);
    SetRow(SHIELD, SHIELD, 2, 2);
    fake_stand_in(REDRAW_RVA, REDRAW_SHIPPED, (void*)GameRedraw);
    CHECK_EQ(vpm_core_init(&refusing, fake_mod(), kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    for (int i = 0; i < 3; i++) JumpTo(kFunctionRvas[i], i == 0 ? (uintptr_t)GameSetItem : i == 1 ? (uintptr_t)GameSetMode : (uintptr_t)GameSendHeld);
    CHECK_LOG("[Holster Your Shield] hook refused at game.dll+0xA95A90: more than 16 hooks on one function");
    CHECK_LOG("is not hooked:");
    CHECK(vpm_running(fake_component(0)));
    Settle();
    Press();
    Frames(2);
    ClearCalls();
    GameDraws();
    Frame();
    CHECK_CALLS(Holster(SHIELD));
}

static void TheHookMovesTheReStowIntoTheDraw(void)
{
    /* before (the fallback): the frame after the game's draw makes 31 reads and the 3 calls */
    ShieldInHand();
    Press();
    Frames(3);
    ClearCalls();
    GameDraws();
    FakeCounts c = Frame();
    CHECK_EQ(c.read, 31);
    CHECK_CALLS(Holster(SHIELD));
    /* after (hooked): the same work inside the draw's call, the frame after only the move's check, idle frames as before */
    fake_setup();
    HookedShieldOnTheBack();
    for (int i = 0; i < 5; i++)
    {
        c = Frame();
        CHECK_EQ(c.read, 2);
        CHECK_EQ(c.write + c.log + c.hook + c.code_matches, 0);
    }
    c = WieldCounted(1, 1);
    CHECK_EQ(c.read, 31);
    CHECK_CALLS(Then(GameDraw(1, 1, 1), Holster(SHIELD)));
    c = Frame();
    CHECK_EQ(c.read, 2);
    CHECK_EQ(c.log, 1);
    c = Frame();
    CHECK_EQ(c.read, 2);
    CHECK_EQ(c.log, 0);
}

int main(void)
{
    RUN(APressWithTheShieldInHandPutsItOnTheBack);
    RUN(TheGameDrawsTheShieldWhileToggled);
    RUN(APressWhileToggledBringsTheShieldBack);
    RUN(APressWhileToggledWithATwoHandedWeaponOnlyEndsTheToggle);
    RUN(APressWithTheShieldOnTheBackKeepsItThereThroughTheNextDraw);
    RUN(CarryingAnObjectiveAPressOnlyFlipsTheToggle);
    RUN(TheDirectionalShieldWorksTheSameWay);
    RUN(OtherBackpacksNeverReadTheKey);
    RUN(AHeldKeyCountsOnce);
    RUN(RestowsStopAfterTheLimit);
    RUN(AMoveTheGameDoesNotTakeIsLoggedAsFailed);
    RUN(APressWhenTheAvatarIsNoLongerOwnedMakesNoCall);
    RUN(APerEntityEquipmentCopyIsWhatIsRead);
    RUN(RowsMovedByTheGameKeepTheToggle);
    RUN(ANewHelldiverEndsTheToggle);
    RUN(NoLocalPlayerReadsOnCheckFramesOnly);
    RUN(IdleFramesReadTheRowAndTheKey);
    RUN(MovesReadEverythingAgain);
    RUN(BindChecksTheFunctionsOnce);
    RUN(BindRefusesAFunctionWhoseFirstBytesDiffer);
    RUN(TheNothingHeldIdsAreReadAtLoad);
    RUN(AnotherBuildStartsNothing);
    RUN(AStopLogsTheSummary);
    RUN(TheHookGoesInAtLoad);
    RUN(AGameDrawWhileHolsteredGoesBackInsideIt);
    RUN(TheRegistersArePassedOnWhole);
    RUN(WithoutTheToggleTheDetourOnlyCallsTheOriginal);
    RUN(OtherHelldiversAreLeftToTheGame);
    RUN(ATwoHandedWeaponDrawsNothingToPutBack);
    RUN(AnObjectiveCarriedIsLeftAloneAndItsDropIsCaughtNextFrame);
    RUN(ARespawnEndsTheToggleWithoutAStow);
    RUN(AStoppedComponentOnlyCallsTheOriginal);
    RUN(AFaultInTheDetourWorkStopsTheComponent);
    RUN(ANestedReDrawIsTheGamesAndTheStowComesLast);
    RUN(AReDrawInsideTheComponentsOwnStowIsTheGames);
    RUN(ThePressWhileTheHookIsIn);
    RUN(TheLimitHoldsInsideTheDraw);
    RUN(TheHookRefusedForOtherBytesLeavesTheReStowNextFrame);
    RUN(TheHookRefusedByHellForgeLeavesTheReStowNextFrame);
    RUN(TheHookMovesTheReStowIntoTheDraw);
    TEST_END();
}
