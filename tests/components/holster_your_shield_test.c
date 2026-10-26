/* Holster Your Shield: the Lua tests' scenarios (components/HolsterYourShield/tests/test_mod.lua on its simulated game,
 * tests/fake_game.lua) on the fake game: the registries laid out as the Lua's simulation lays them out, in the fake
 * game.dll image and heap.
 *
 * The game's three functions: the fake image holds their first 16 bytes for the check at HF_EVENT_GAME_LOADED; after
 * it, each function's first bytes become a jump to the test's own stand-in (as a hook would make them), which acts on
 * the row as the game does: set_item sets the held carryable, set_mode the carry mode (0 when nothing is held),
 * send_held is recorded. So the component calls game.dll's base + RVA, as it does in the game. */
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

static struct
{
    uint8_t *owner, *players, *manager, *inventory, *identities, *rows, *row, *avatar_record;
    uint8_t* key;
    int inert;           /* the game's functions do nothing (the game did not take the move) */
    char calls[2048];    /* the game calls made, "name,args" separated by spaces */
    char expected[512];
    uint64_t frame;      /* the component's frame count */
} w;

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
    uint8_t* row = RowOf(inventory, avatar);
    if (row != NULL) Put32(row + 20, item);
}

static uint64_t GameSetMode(uint64_t inventory, uint32_t avatar, uint32_t mode)
{
    Called("set_mode,%llu,%u,%u", (unsigned long long)inventory, avatar, mode);
    uint8_t* row = RowOf(inventory, avatar);
    if (row != NULL) Put32(row + 32, Get32(row + 20) == 0 ? 0 : mode);
    return 0;
}

static void GameSendHeld(int64_t peer, uint32_t avatar, uint32_t item, uint32_t mode)
{
    Called("send_held,%lld,%u,%u,%u", (long long)peer, avatar, item, mode);
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
    CHECK_EQ(c.code_matches, 3);
    CHECK_EQ(c.read + c.write, 0);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_LOG("[Holster Your Shield] Holster Your Shield v1.0 initialized.");
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
    TEST_END();
}
