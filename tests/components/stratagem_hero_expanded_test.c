/* Stratagem Hero Expanded: the Lua tests' scenarios (components/StratagemHeroExpanded/tests/test_mod.lua) on the fake
 * game, plus HellForge's moved stratagem list. The tables are checked against bytes from a dump of the running game's
 * image (the Lua's tests/vanilla_tables.lua) and against the Lua encoder's own output for the expanded pool; the game's
 * picker is modelled to check every stratagem's odds; the page check runs on this process's own pages too.
 *
 * Not ported: the Lua encoders' run-time refusals (the C tables' array sizes are the picker's limits, so a list that
 * breaks one does not compile), the shutdown report, the loader and update-chain tests (the core's tick replaces the
 * update chain), and LuaJIT specifics. */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/stratagem_hero_expanded/stratagem_hero_expanded.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_stratagem_hero_expanded};

#define TIERS_RVA 0x263CCC0u
#define GROUPS_RVA 0x263CF70u
#define TIERS_SIZE 612u
#define GROUPS_SIZE 640u
#define GAP 76u
#define LIST_SITE 0x17EF922u
#define VANILLA_LIST 0x37CB600u
#define MOVED_LIST 0x4000000u /* inside the fake image, as HellForge's block lies within 2 GB of game.dll */
#define PROBE 124u
#define ROW 0x190u            /* StratagemInfo rows are 400 bytes; the component reads the first 0xC0 */
#define POOL 108

/* Build 25480438's tables as the game holds them (game.dll +0x263CCC0, 612 bytes, and +0x263CF70, 640 bytes), copied
 * from a dump of the running game's image (the Lua's tests/vanilla_tables.lua). */
static const char* const kDumpTiers =
    "48c96247060000000000803f010000000000003f02000000cdcc4c3e03000000cdcc4c3d080000009a99993d00000000"
    "000000000000000000000000000000000000000092db0349040000000000803f010000000000003f02000000cdcc4c3e"
    "03000000cdcc4c3d080000009a99993d000000000000000000000000000000000000000000000000e8eef5f107000000"
    "0000803f010000000000003f02000000cdcc4c3e03000000cdcc4c3d080000009a99993d000000000000000000000000"
    "0000000000000000000000009d3fa39a090000009a99193f010000000000003f02000000cdcc4c3e03000000cdcc4c3d"
    "080000009a99993d00000000000000000000000000000000000000000000000000000000010000000000003f02000000"
    "cdcc4c3e03000000cdcc4c3d080000009a99993d00000000000000000000000000000000000000000000000000000000"
    "0000000000000000010000009a99193f02000000cdcccc3e03000000cdcccc3d080000009a99993d0000000000000000"
    "00000000000000000000000000000000000000000000000000000000010000009a99993e020000000000003f03000000"
    "cdcccc3e080000009a99993d000000000000000000000000000000000000000000000000000000000000000000000000"
    "01000000cdcccc3d020000000000003f030000000000003f080000009a99993d00000000000000000000000000000000"
    "000000000000000000000000000000000000000001000000cdcccc3d02000000cdcc4c3e03000000cdcc4c3f08000000"
    "cdcccc3d0000000000000000000000000000000000000000000000000000000000000000";
static const char* const kDumpGroups =
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000005300000088000000210000001e00000077000000420000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000030000008c0000007d0000006b000000"
    "5c000000820000002a000000930000003500000075000000000000000000000000000000000000000000000000000000"
    "2b0000004900000086000000190000008d00000090000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000001e000000030000008c0000001200000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000089000000420000007500000035000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "2b0000004900000086000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000053000000880000007d0000006b00000000000000000000000000000000000000"
    "00000000000000000000000000000000000000000000000000000000000000007c000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "380000000d0000003f000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "00000000000000000000000000000000";
/* The Lua's expanded tables (Mod.tables().expanded), from the Lua encoder's algorithm run outside the game (the same
 * double arithmetic, each weight rounded to the nearest f32). */
static const char* const kLuaExpandedTiers =
    "48c9624701000000f8e0e342020000000000104103000000000050410400000000008041050000000000804106000000"
    "000060410700000000005041080000000000504192db0349020000000000f04201000000000060410300000000005041"
    "04000000000080410500000000008041060000000000604107000000000050410800000000005041e8eef5f103000000"
    "934de6420100000000006041020000000000104104000000000080410500000000008041060000000000604107000000"
    "0000504108000000000050419d3fa39a040000004617dd41050000004617dd4101000000000060410200000000001041"
    "030000000000504106000000000060410700000000005041080000000000504100000000010000000000604102000000"
    "000010410300000000005041040000000000804105000000000080410600000000006041070000000000504108000000"
    "000050410000000001000000000060410200000000001041030000000000504104000000000080410500000000008041"
    "060000000000604107000000000050410800000000005041000000000100000000006041020000000000104103000000"
    "000050410400000000008041050000000000804106000000000060410700000000005041080000000000504100000000"
    "010000000000604102000000000010410300000000005041040000000000804105000000000080410600000000006041"
    "070000000000504108000000000050410000000001000000000060410200000000001041030000000000504104000000"
    "000080410500000000008041060000000000604107000000000050410800000000005041";
static const char* const kLuaExpandedGroups =
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000065000000780000000e0000008600000037000000180000006000000043000000"
    "2b00000049000000730000008e000000390000000200000000000000000000001e00000003000000310000008c000000"
    "1200000085000000410000007e0000002600000000000000000000000000000000000000000000000000000000000000"
    "760000005300000004000000880000006a0000007d000000150000003e0000006b0000003a000000290000004a000000"
    "220000000000000000000000000000007200000033000000640000005c000000200000000d0000003800000071000000"
    "8d00000050000000830000002d00000051000000700000003d0000003f00000095000000440000009300000027000000"
    "10000000060000006300000059000000190000007f00000082000000360000004b000000610000006e00000057000000"
    "790000004200000008000000170000003500000089000000750000002c000000340000003b0000001600000090000000"
    "09000000680000000000000000000000690000001a0000008700000001000000320000001b0000000a0000005b000000"
    "58000000770000008b0000000c0000002e0000000000000000000000000000007c00000021000000910000002a000000"
    "1c0000000b00000080000000130000004600000005000000940000007400000084000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "00000000000000000000000000000000";

/* This build's settings (Helldivers2_RawData 1.007.100, whose type numbers match game.dll's StratagemType names): the
 * 96 stratagems marked selectable for a loadout, and the 12 mission stratagems the pool adds. */
static const uint32_t kLoadout[] = {1, 2, 3, 4, 6, 8, 9, 10, 12, 13, 14, 16, 18, 21, 22, 23, 24, 25, 26, 27, 30, 32, 34, 38,
    39, 41, 43, 44, 45, 46, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 61, 62, 63, 65, 66, 67, 68, 73, 74, 75, 80, 81, 83,
    87, 88, 89, 91, 92, 96, 97, 99, 100, 101, 104, 105, 106, 107, 110, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
    125, 126, 127, 130, 131, 132, 133, 134, 135, 136, 137, 139, 140, 141, 142, 144, 147, 149};
/* Illumination Flare, Super Earth Flag, Seismic Probe, SEAF Artillery, Resupply, Hellbomb, Eagle Rearm, Prospecting
 * Drill, Reinforce, Upload Data, SOS Beacon, Extraction. */
static const uint32_t kMission[] = {5, 11, 19, 28, 33, 42, 49, 70, 124, 128, 145, 148};
/* What vanilla reaches (decoded from the game's tables by hand, see the knowledge base entry). */
static const uint32_t kVanillaPool[] = {3, 13, 18, 25, 30, 33, 42, 43, 53, 56, 63, 66, 73, 83, 92, 107, 117, 119, 124, 125,
    130, 134, 136, 140, 141, 144, 147};
/* The class each pool stratagem's settings give it (StratagemInfo +0x188, same source). */
typedef struct Class { uint8_t type, klass; } Class;
static const Class kClasses[] = {{1, 27}, {2, 24}, {3, 7}, {4, 2}, {5, 0}, {6, 19}, {8, 30}, {9, 34}, {10, 28},
    {11, 0}, {12, 36}, {13, 13}, {14, 21}, {16, 19}, {18, 9}, {19, 0}, {21, 4}, {22, 33}, {23, 30}, {24, 22}, {25, 20},
    {26, 26}, {27, 28}, {28, 0}, {30, 7}, {32, 13}, {33, 0}, {34, 6}, {38, 10}, {39, 19}, {41, 6}, {42, 0}, {43, 23},
    {44, 32}, {45, 15}, {46, 36}, {49, 7}, {50, 27}, {51, 11}, {52, 32}, {53, 31}, {54, 20}, {55, 22}, {56, 14},
    {57, 24}, {58, 5}, {59, 33}, {61, 16}, {62, 4}, {63, 17}, {65, 9}, {66, 29}, {67, 23}, {68, 18}, {70, 0}, {73, 24},
    {74, 6}, {75, 20}, {80, 15}, {81, 15}, {83, 2}, {87, 20}, {88, 28}, {89, 19}, {91, 28}, {92, 12}, {96, 23},
    {97, 20}, {99, 19}, {100, 11}, {101, 21}, {104, 35}, {105, 26}, {106, 3}, {107, 5}, {110, 20}, {112, 16},
    {113, 14}, {114, 11}, {115, 24}, {116, 0}, {117, 32}, {118, 1}, {119, 36}, {120, 21}, {121, 29}, {124, 0},
    {125, 4}, {126, 9}, {127, 20}, {128, 0}, {130, 20}, {131, 15}, {132, 0}, {133, 9}, {134, 22}, {135, 26}, {136, 3},
    {137, 31}, {139, 36}, {140, 8}, {141, 14}, {142, 24}, {144, 34}, {145, 0}, {147, 19}, {148, 0}, {149, 17}};
#define COUNT(a) ((int)(sizeof (a) / sizeof (a)[0]))

typedef enum Family { MISSION, ORBITAL, EAGLE, WEAPON, BACKPACK, VEHICLE, SENTRY, EMPLACEMENT, MINE, FAMILIES } Family;
/* The families each group (1-8) holds, all of them and nothing else. */
static const unsigned kGroupFamilies[8] = {1u << BACKPACK, 1u << EAGLE, 1u << ORBITAL, 1u << WEAPON, 1u << WEAPON,
    1u << SENTRY | 1u << EMPLACEMENT, 1u << VEHICLE | 1u << MINE, 1u << MISSION};

static Family FamilyOf(int klass)
{
    static const struct { int low, high; Family family; } ranges[] = {{0, 0, MISSION}, {1, 6, ORBITAL}, {7, 10, EAGLE},
        {11, 20, WEAPON}, {21, 24, BACKPACK}, {26, 28, VEHICLE}, {29, 32, SENTRY}, {33, 35, EMPLACEMENT}, {36, 36, MINE}};
    for (int i = 0; i < COUNT(ranges); i++)
        if (klass >= ranges[i].low && klass <= ranges[i].high) return ranges[i].family;
    return FAMILIES;
}

static int ClassOf(uint32_t type)
{
    for (int i = 0; i < COUNT(kClasses); i++)
        if (kClasses[i].type == type) return kClasses[i].klass;
    return -1;
}

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static float GetF32(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }

static int Nibble(char c) { return c >= 'a' ? c - 'a' + 10 : c - '0'; }
static void Unhex(const char* hex, uint8_t* out)
{
    for (size_t i = 0; hex[2 * i] != 0; i++) out[i] = (uint8_t)(Nibble(hex[2 * i]) * 16 + Nibble(hex[2 * i + 1]));
}

static uint8_t* Game(void) { return (uint8_t*)fake_game(); }
static uint8_t* Tiers(void) { return Game() + TIERS_RVA; }
static uint8_t* Groups(void) { return Game() + GROUPS_RVA; }

/* ---- the fake game ---------------------------------------------------------------------------------------------- */

typedef struct World { uint8_t* list; uint8_t* rows[150]; } World;
static World w;

static void PutRow(uint32_t type, const uint8_t* row) { Put64(w.list + type * 8, (uint64_t)(uintptr_t)row); }

/* The game: build 25480438's tables with 76 bytes of other data between them, a settings row for every type 1-149 (its
 * type, a code of 5 inputs, HUD type 2) in a list at `list` (in the fake game.dll, or outside it), and the arcade
 * widget's reader addressing that list. */
static void MakeWorldAt(uint8_t* list)
{
    memset(&w, 0, sizeof w);
    Unhex(kDumpTiers, Tiers());
    memset(Tiers() + TIERS_SIZE, 90, GAP);
    Unhex(kDumpGroups, Groups());
    w.list = list;
    for (uint32_t type = 1; type < 150; type++)
    {
        uint8_t* row = fake_heap(ROW);
        Put32(row, type);
        Put64(row + 0x40, (uint64_t)(uintptr_t)fake_heap(4 * 5));
        Put32(row + 0x48, 5);
        Put32(row + 0xB8, 2);
        w.rows[type] = row;
        PutRow(type, row);
    }
    static const uint8_t site[] = {0x4C, 0x8B, 0xB4, 0xC1};
    memcpy(Game() + LIST_SITE, site, 4);
    int64_t displacement = (int64_t)((intptr_t)list - (intptr_t)Game());
    CHECK(displacement == (int32_t)displacement); /* a list the instruction can address */
    Put32(Game() + LIST_SITE + 4, (uint32_t)(int32_t)displacement);
}

static void MakeWorld(void) { MakeWorldAt(Game() + VANILLA_LIST); }
/* The stratagem settings not loaded yet: the probe's (Reinforce's) pointer unset. */
static void Unload(void) { memset(w.list + PROBE * 8, 0, 8); }
static void Load(void) { PutRow(PROBE, w.rows[PROBE]); }

static void PutTables(const char* tiers, const char* groups)
{
    Unhex(tiers, Tiers());
    Unhex(groups, Groups());
}

static int TablesAre(const char* tiers, const char* groups)
{
    uint8_t expectTiers[TIERS_SIZE], expectGroups[GROUPS_SIZE], gap[GAP];
    Unhex(tiers, expectTiers);
    Unhex(groups, expectGroups);
    memset(gap, 90, GAP);
    CHECK(memcmp(Tiers() + TIERS_SIZE, gap, GAP) == 0); /* the bytes between the tables never change */
    return memcmp(Tiers(), expectTiers, TIERS_SIZE) == 0 && memcmp(Groups(), expectGroups, GROUPS_SIZE) == 0;
}

static int Vanilla(void) { return TablesAre(kDumpTiers, kDumpGroups); }
static int Expanded(void) { return TablesAre(kLuaExpandedTiers, kLuaExpandedGroups); }

/* The component's page query and store, as the Lua's tests gave theirs: one region over the whole fake game.dll,
 * committed image memory of it with read-write pages unless a test changes it. */
typedef struct Page { DWORD state, type, protection; uintptr_t base; int refuse, lose, queries, stores; } Page;
static Page g_page;

static SIZE_T FakeQuery(uintptr_t address, MEMORY_BASIC_INFORMATION* region)
{
    g_page.queries++;
    memset(region, 0, sizeof *region);
    region->BaseAddress = Game();
    region->AllocationBase = (void*)(g_page.base != 0 ? g_page.base : fake_game());
    region->RegionSize = FAKE_GAME_SIZE;
    region->State = g_page.state;
    region->Type = g_page.type;
    region->Protect = g_page.protection;
    return sizeof *region;
}

static int FakeStore(uintptr_t address, const void* data, size_t size)
{
    g_page.stores++;
    if (g_page.refuse) return 0;
    if (!g_page.lose) memcpy((void*)address, data, size);
    return 1;
}

static const StratagemHeroNative kFakeNative = {FakeQuery, FakeStore};

static void FreshPages(void)
{
    memset(&g_page, 0, sizeof g_page);
    g_page.state = MEM_COMMIT;
    g_page.type = MEM_IMAGE;
    g_page.protection = PAGE_READWRITE;
    stratagem_hero_expanded_native = &kFakeNative;
}

static void ResetCounts(void)
{
    fake_counts_reset();
    g_page.queries = g_page.stores = 0;
}

/* The component started; HF_EVENT_GAME_LOADED comes next (the counts start from 0 just before it). */
static void Started(void)
{
    fake_start(kDefs, 1);
    ResetCounts();
}

static void Loaded(void) { fake_fire(HF_EVENT_GAME_LOADED); }

/* Calls since the last ResetCounts: API reads, code checks, page queries, stores, and nothing else of the API. */
#define CHECK_CALLS(reads_, matches_, queries_, stores_) do { FakeCounts c_ = fake_counts(); CHECK_EQ(c_.read, reads_); \
    CHECK_EQ(c_.code_matches, matches_); CHECK_EQ(g_page.queries, queries_); CHECK_EQ(g_page.stores, stores_); \
    CHECK_EQ(c_.write + c_.get_live + c_.set_live + c_.hook + c_.find_pattern + c_.subscribe + c_.other, 0); } while (0)

/* ---- the game's picker as odds ---------------------------------------------------------------------------------- */

/* game.dll 0x598370: a group by weight (entries until group 0, at most 8), then one of its stratagems uniformly (until 0,
 * at most 16). chance[type] for one tier. */
static void PickerOdds(const uint8_t* tiers, const uint8_t* groups, int tier, double* chance)
{
    uint32_t picked[8];
    double weights[8], total = 0;
    int entries = 0;
    memset(chance, 0, 256 * sizeof *chance);
    for (int slot = 0; slot < 8 && Get32(tiers + tier * 68 + 4 + slot * 8) != 0; slot++, entries++)
    {
        picked[entries] = Get32(tiers + tier * 68 + 4 + slot * 8);
        weights[entries] = GetF32(tiers + tier * 68 + 8 + slot * 8);
        total += weights[entries];
    }
    for (int e = 0; e < entries; e++)
    {
        uint32_t members[16];
        int count = 0;
        for (int slot = 0; slot < 16 && Get32(groups + picked[e] * 64 + slot * 4) != 0; slot++)
            members[count++] = Get32(groups + picked[e] * 64 + slot * 4);
        CHECK(count > 0); /* a tier listing an empty group */
        for (int m = 0; m < count; m++)
            if (members[m] < 256) chance[members[m]] += weights[e] / total / count;
    }
}

static int Near(double a, double b) { return a - b < 1e-6 && b - a < 1e-6; }

static int Reached(const double* chance)
{
    int n = 0;
    for (int t = 0; t < 256; t++) n += chance[t] > 0;
    return n;
}

/* The members of group g (1-9) as the game holds it now; their count. */
static int GroupMembers(uint32_t g, uint32_t* members)
{
    int count = 0;
    for (int slot = 0; slot < 16 && Get32(Groups() + g * 64 + slot * 4) != 0; slot++) members[count++] = Get32(Groups() + g * 64 + slot * 4);
    return count;
}

/* ---- tables and odds -------------------------------------------------------------------------------------------- */

/* Vanilla reaches its 27 stratagems (the dump's tables, through the picker). */
static void VanillaReachesItsStratagems(void)
{
    uint8_t tiers[TIERS_SIZE], groups[GROUPS_SIZE];
    double chance[256], reached[256] = {0};
    Unhex(kDumpTiers, tiers);
    Unhex(kDumpGroups, groups);
    for (int tier = 0; tier < 9; tier++)
    {
        PickerOdds(tiers, groups, tier, chance);
        for (int t = 0; t < 256; t++) reached[t] += chance[t];
    }
    CHECK_EQ(Reached(reached), COUNT(kVanillaPool));
    for (int i = 0; i < COUNT(kVanillaPool); i++) CHECK(reached[kVanillaPool[i]] > 0);
}

static void Apply(void)
{
    FreshPages();
    MakeWorld();
    Started();
    Loaded();
}

/* The applied pool: every loadout and mission stratagem, once; at most 8 groups (a tier lists 8), each 1-16. */
static void ExpandedPoolHoldsEveryLoadoutAndMissionStratagemOnce(void)
{
    Apply();
    CHECK(Expanded());
    int seen[256] = {0}, count = 0;
    for (uint32_t g = 1; g <= 9; g++)
    {
        uint32_t members[16];
        int n = GroupMembers(g, members);
        CHECK(g == 9 ? n == 0 : n >= 1 && n <= 16);
        for (int m = 0; m < n; m++) { CHECK(members[m] < 150 && !seen[members[m]]); seen[members[m] & 0xFF] = 1; count++; }
    }
    CHECK_EQ(COUNT(kLoadout), 96);
    CHECK_EQ(count, POOL);
    for (int i = 0; i < COUNT(kLoadout); i++) CHECK(seen[kLoadout[i]]);
    for (int i = 0; i < COUNT(kMission); i++) CHECK(seen[kMission[i]]);
}

/* Every pool stratagem of a family sits in that family's group(s), and a group holds nothing else; the themes hold every
 * member of their family: 14 backpacks, 9 Eagles, 13 orbitals, 32 support weapons. */
static void GroupsFollowTheGamesClasses(void)
{
    Apply();
    int sizes[9] = {0}, family[FAMILIES] = {0};
    for (uint32_t g = 1; g <= 8; g++)
    {
        uint32_t members[16];
        sizes[g] = GroupMembers(g, members);
        for (int m = 0; m < sizes[g]; m++)
        {
            int klass = ClassOf(members[m]);
            CHECK(klass >= 0);
            CHECK((kGroupFamilies[g - 1] >> FamilyOf(klass)) & 1u);
        }
    }
    for (int i = 0; i < COUNT(kClasses); i++) family[FamilyOf(kClasses[i].klass)]++;
    CHECK_EQ(COUNT(kClasses), POOL);
    CHECK(sizes[1] == family[BACKPACK] && family[BACKPACK] == 14);
    CHECK(sizes[2] == family[EAGLE] && family[EAGLE] == 9);
    CHECK(sizes[3] == family[ORBITAL] && family[ORBITAL] == 13);
    CHECK(sizes[4] + sizes[5] == family[WEAPON] && family[WEAPON] == 32);
}

/* The odds of one themed tier: the theme's groups together get vanilla's theme share, the rest even. */
static void CheckThemedTier(int tier, const double* chance)
{
    static const uint32_t themes[4][2] = {{1}, {2}, {3}, {4, 5}};
    int members[256] = {0}, themed = 0;
    for (int i = 0; i < 2 && themes[tier][i] != 0; i++)
    {
        uint32_t list[16];
        int n = GroupMembers(themes[tier][i], list);
        for (int m = 0; m < n; m++) members[list[m]] = 1;
        themed += n;
    }
    double share = 0;
    for (int t = 0; t < 256; t++) share += members[t] ? chance[t] : 0;
    CHECK(Near(share, tier == 3 ? 0.6 / 1.425 : 1 / 1.825));
    for (int t = 0; t < 256; t++)
        if (chance[t] > 0 && !members[t]) CHECK(Near(chance[t], (1 - share) / (POOL - themed)));
}

/* Even odds in plain rounds, vanilla's theme shares in themed rounds; every tier reaches all 108; banners stay. */
static void ExpandedOddsAreEvenOutsideThemes(void)
{
    Apply();
    uint8_t vanilla[TIERS_SIZE];
    Unhex(kDumpTiers, vanilla);
    for (int tier = 0; tier < 9; tier++)
    {
        double chance[256], total = 0;
        PickerOdds(Tiers(), Groups(), tier, chance);
        CHECK_EQ(Reached(chance), POOL);
        for (int t = 0; t < 256; t++) total += chance[t];
        CHECK(Near(total, 1));
        if (tier >= 4)
            for (int t = 0; t < 256; t++) CHECK(chance[t] == 0 || Near(chance[t], 1.0 / POOL));
        else
            CheckThemedTier(tier, chance);
        CHECK_EQ(Get32(Tiers() + tier * 68), Get32(vanilla + tier * 68));
    }
}

/* ---- the attempt ------------------------------------------------------------------------------------------------ */

/* Applied at load: both tables written (the Lua encoder's bytes), nothing else; no tick; nothing per frame after. */
static void AppliesAtLoad(void)
{
    FreshPages();
    MakeWorld();
    Started();
    Loaded();
    CHECK(Expanded());
    CHECK_LOG("[Stratagem Hero Expanded] applied (108 stratagems in 8 groups; pages 0x04, 0x04), at load.");
    CHECK(strcmp(vpm_status(fake_component(0)), "applied (108 stratagems in 8 groups; pages 0x04, 0x04)") == 0);
    /* 108 row reads (the probe, the list, the tables and the read back are plain loads), the reader's code check, a page
     * query per table, 2 stores, 1 log line. The Lua: 112 reads, 2 page queries, 2 writes. */
    CHECK_CALLS(108, 1, 2, 2);
    CHECK_EQ(fake_counts().log, 1);
    CHECK(!vpm_ticking(fake_component(0)));
    CHECK_NO_LOG("moved");
    ResetCounts();
    fake_frames(10, 1.0f / 60);
    CHECK_CALLS(0, 0, 0, 0);
    CHECK_EQ(fake_counts().log, 0);
}

/* Already applied (the expanded tables found): nothing is written. */
static void AlreadyAppliedWritesNothing(void)
{
    FreshPages();
    MakeWorld();
    PutTables(kLuaExpandedTiers, kLuaExpandedGroups);
    Started();
    Loaded();
    CHECK_LOG("already applied (108 stratagems in 8 groups), at load.");
    CHECK_CALLS(108, 1, 0, 0); /* the Lua: 111 reads */
    CHECK(vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    CHECK(Expanded());
}

/* Waits while the stratagem settings are not loaded: two plain loads per frame and no API call (the Lua: one read per
 * frame); applies on the frame they appear, then stops ticking. */
static void WaitsForTheSettings(void)
{
    FreshPages();
    MakeWorld();
    Unload();
    Started();
    Loaded();
    CHECK_LOG("Waiting for the game: the stratagem settings are not loaded yet.");
    CHECK(strcmp(vpm_status(fake_component(0)), "waiting: the stratagem settings are not loaded yet") == 0);
    CHECK_CALLS(0, 1, 0, 0);
    CHECK(vpm_ticking(fake_component(0)) && Vanilla());
    for (int n = 0; n < 3; n++)
    {
        ResetCounts();
        fake_frames(1, 0.5f);
        CHECK_CALLS(0, 0, 0, 0);
        CHECK_EQ(fake_counts().log, 0);
    }
    CHECK(Vanilla());
    Load();
    ResetCounts();
    fake_frames(1, 0.5f);
    CHECK_CALLS(108, 0, 2, 2); /* the frame that applies; the Lua: 112 reads, 2 page queries, 2 writes */
    CHECK(Expanded() && !vpm_ticking(fake_component(0)));
    /* Waited: 3 frames of 0.5 s; the applying frame adds none. */
    CHECK_LOG("applied (108 stratagems in 8 groups; pages 0x04, 0x04), after 1.5 s.");
    ResetCounts();
    fake_frames(5, 1.0f / 60);
    CHECK_CALLS(0, 0, 0, 0);
}

static void GivesUpAfterTenMinutes(void)
{
    FreshPages();
    MakeWorld();
    Unload();
    Started();
    Loaded();
    fake_frames(10, 600.0f / 4);
    CHECK(!vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    CHECK_LOG("disabled: gave up after 600 s: waiting: the stratagem settings are not loaded yet");
    CHECK(Vanilla());
}

/* Refused at load: disabled, nothing written, no tick. */
static void Refuses(const char* text)
{
    Started();
    Loaded();
    CHECK_LOG(text);
    CHECK(!vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    CHECK_EQ(g_page.stores, 0);
}

/* Settings the arcade cannot show refuse the whole change. */
static void RefusesSettingsTheArcadeCannotShow(void)
{
    static const struct { uint32_t type, at, value; const char* text; } cases[] = {
        {2, 0x00, 3, "disabled: The settings of stratagem 2 belong to another stratagem"},
        {1, 0x48, 11, "disabled: The code of stratagem 1 does not fit the arcade"},
        {5, 0x48, 0, "disabled: The code of stratagem 5 does not fit the arcade"},
        {148, 0x40, 0, "disabled: The code of stratagem 148 does not fit the arcade"}, /* no code pointer */
        {33, 0xB8, 5, "disabled: Unexpected HUD type for stratagem 33"},
    };
    for (int c = 0; c < COUNT(cases); c++)
    {
        fake_setup();
        FreshPages();
        MakeWorld();
        Put32(w.rows[cases[c].type] + cases[c].at, cases[c].value);
        if (cases[c].at == 0x40) Put64(w.rows[cases[c].type] + 0x40, 0);
        Refuses(cases[c].text);
        CHECK(Vanilla());
    }
    fake_setup();
    FreshPages();
    MakeWorld();
    memset(w.list + 149 * 8, 0, 8);
    Refuses("disabled: No settings for stratagem 149");
    CHECK(Vanilla());
    fake_setup();
    FreshPages();
    MakeWorld();
    fake_hole((uintptr_t)w.rows[66], ROW);
    Refuses("disabled: Settings of stratagem 66 unreadable");
    CHECK(Vanilla());
}

/* Tables that are neither build 25480438's nor the expanded ones (one byte changed, or half written) refuse. */
static void RefusesTablesThatDiffer(void)
{
    FreshPages();
    MakeWorld();
    Groups()[100] = 1;
    Refuses("disabled: The arcade's tables differ from build 25480438's");
    CHECK_EQ(Groups()[100], 1);
    fake_setup();
    FreshPages();
    MakeWorld();
    Unhex(kLuaExpandedTiers, Tiers());
    Refuses("disabled: The arcade's tables differ from build 25480438's");
    CHECK(TablesAre(kLuaExpandedTiers, kDumpGroups));
}

/* Pages that are not committed, writable image data of game.dll refuse before any store. */
static void RefusesPagesThatAreNotWritableImageData(void)
{
    static const struct { DWORD state, type, protection; uintptr_t base; } cases[] = {
        {MEM_COMMIT, MEM_PRIVATE, PAGE_READWRITE, 0},           /* private memory */
        {MEM_COMMIT, MEM_IMAGE, PAGE_READONLY, 0},              /* read-only */
        {MEM_COMMIT, MEM_IMAGE, PAGE_EXECUTE_READ, 0},          /* code */
        {MEM_COMMIT, MEM_IMAGE, PAGE_READWRITE | PAGE_GUARD, 0}, /* a guard page */
        {MEM_RESERVE, MEM_IMAGE, PAGE_READWRITE, 0},            /* reserved */
        {MEM_COMMIT, MEM_IMAGE, PAGE_READWRITE, 0x10000},       /* another module */
    };
    for (int c = 0; c < COUNT(cases); c++)
    {
        fake_setup();
        FreshPages();
        MakeWorld();
        g_page.state = cases[c].state;
        g_page.type = cases[c].type;
        g_page.protection = cases[c].protection;
        g_page.base = cases[c].base;
        Refuses("disabled: Arcade tables are not in writable game.dll data pages");
        CHECK_EQ(g_page.queries, 2);
        CHECK(Vanilla());
    }
    /* Copy-on-write and the executable forms pass. */
    static const DWORD writable[] = {PAGE_WRITECOPY, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_WRITECOPY};
    for (int c = 0; c < COUNT(writable); c++)
    {
        fake_setup();
        FreshPages();
        MakeWorld();
        g_page.protection = writable[c];
        Started();
        Loaded();
        CHECK(Expanded());
    }
    CHECK_LOG("pages 0x80, 0x80)");
}

/* Type 7 (an extraction variant outside the pool) has no settings and type 40's code is too long: still applies. */
static void SettingsOutsideThePoolDoNotMatter(void)
{
    FreshPages();
    MakeWorld();
    memset(w.list + 7 * 8, 0, 8);
    Put32(w.rows[40] + 0x48, 50);
    Started();
    Loaded();
    CHECK(Expanded());
}

/* A store that fails, or one that claims success and writes nothing, refuses. */
static void RefusesAFailedOrLostWrite(void)
{
    FreshPages();
    MakeWorld();
    g_page.refuse = 1;
    Started();
    Loaded();
    CHECK_LOG("disabled: Arcade table write failed");
    CHECK(Vanilla());
    fake_setup();
    FreshPages();
    MakeWorld();
    g_page.lose = 1;
    Started();
    Loaded();
    CHECK_LOG("disabled: Arcade table write did not hold");
    CHECK(Vanilla());
}

/* The first writable, non-executable section of this process's own image (its .data): its address. */
static uintptr_t HostDataSection(uintptr_t host)
{
    const IMAGE_NT_HEADERS64* nt = (const IMAGE_NT_HEADERS64*)(host + ((const IMAGE_DOS_HEADER*)host)->e_lfanew);
    const IMAGE_SECTION_HEADER* sections = IMAGE_FIRST_SECTION(nt);
    for (int i = 0; i < nt->FileHeader.NumberOfSections; i++)
    {
        DWORD flags = sections[i].Characteristics;
        if ((flags & IMAGE_SCN_MEM_WRITE) && !(flags & IMAGE_SCN_MEM_EXECUTE) && sections[i].Misc.VirtualSize >= 16)
            return host + sections[i].VirtualAddress;
    }
    return 0;
}

/* The real page query on this process's own pages: image data pages pass; the read-only header page, private memory
 * and another module's pages do not. */
static void PageCheckOnThisProcess(void)
{
    stratagem_hero_expanded_native = NULL;
    uintptr_t host = (uintptr_t)GetModuleHandleW(NULL), kernel = (uintptr_t)GetModuleHandleW(L"kernel32.dll");
    uintptr_t data = HostDataSection(host);
    char seen[64];
    CHECK(data != 0);
    CHECK(stratagem_hero_expanded_image_writable(host, data, 16, seen, sizeof seen));
    CHECK(strncmp(seen, "0x0", 3) == 0); /* 0x04 or 0x08 */
    CHECK(!stratagem_hero_expanded_image_writable(host, host, 16, seen, sizeof seen));
    CHECK(!stratagem_hero_expanded_image_writable(host, (uintptr_t)fake_heap(64), 16, seen, sizeof seen));
    CHECK(kernel != 0 && !stratagem_hero_expanded_image_writable(kernel, data, 16, seen, sizeof seen));
}

/* ---- HellForge -------------------------------------------------------------------------------------------------- */

/* HellForge moved the list (a mod added stratagems): the rows are found through the moved one, and the vanilla list
 * (left all zero here) is never read. */
static void FollowsHellForgesMovedList(void)
{
    FreshPages();
    MakeWorldAt(Game() + MOVED_LIST);
    Started();
    Loaded();
    CHECK(Expanded());
    CHECK_LOG("the stratagem list was moved by HellForge (game.dll +67108864)");
    CHECK_CALLS(108, 1, 2, 2);
}

/* A moved list outside game.dll's image (HellForge's own block) is read through vpm_read: the probe and the list are 2
 * reads more. While it waits there, 1 read per frame (as the Lua's probe); HellForge moves the list only once the
 * settings are loaded, so this is not the usual wait. */
static void ReadsAListOutsideTheImage(void)
{
    FreshPages();
    MakeWorldAt(fake_heap(150 * 8));
    Unload();
    Started();
    Loaded();
    CHECK_CALLS(1, 1, 0, 0);
    ResetCounts();
    fake_frames(1, 1.0f / 60);
    CHECK_CALLS(1, 0, 0, 0);
    Load();
    ResetCounts();
    fake_frames(1, 1.0f / 60);
    CHECK_CALLS(110, 0, 2, 2);
    CHECK(Expanded());
    CHECK_LOG("the stratagem list was moved by HellForge");
}

/* Another reader reads as code not decoded yet: the core waits for it, then stops the component, nothing written. */
static void RefusesAnotherReader(void)
{
    FreshPages();
    MakeWorld();
    Game()[LIST_SITE] = 0x48;
    Started();
    Loaded();
    fake_frames(60, 1.0f);
    CHECK_LOG("disabled: the stratagem list's reader changed (game.dll 0x17EF922)");
    CHECK(!vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    CHECK_EQ(g_page.stores, 0);
    CHECK_EQ(fake_counts().read, 0);
    CHECK(Vanilla());
}

/* ---- game.dll's code decoded in parts after HF_EVENT_GAME_LOADED (vpm_when_code_ready) ------------------------- */

/* The reader as the game holds it before its part of game.dll is decoded, and once it is. */
static void Encode(void) { memset(Game() + LIST_SITE, 0xCC, 8); }
static void Decode(void)
{
    static const uint8_t site[] = {0x4C, 0x8B, 0xB4, 0xC1};
    memcpy(Game() + LIST_SITE, site, 4);
    Put32(Game() + LIST_SITE + 4, (uint32_t)(int32_t)((intptr_t)w.list - (intptr_t)Game()));
}

/* Still encoded at the event, decoded two seconds later: nothing read or written before; the attempt on the frame of
 * the next look, as at load; then nothing. */
static void TheReaderDecodedLaterAppliesThen(void)
{
    FreshPages();
    MakeWorld();
    Encode();
    Started();
    Loaded();
    CHECK_CALLS(0, 1, 0, 0);
    CHECK_EQ(fake_counts().log, 0);
    CHECK(vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    ResetCounts();
    fake_frames(120, 1.0f / 60);
    CHECK_CALLS(0, 4, 0, 0); /* one look every 30 frames */
    CHECK(Vanilla());
    Decode();
    ResetCounts();
    fake_frames(30, 1.0f / 60);
    CHECK_CALLS(108, 1, 2, 2);
    CHECK(Expanded());
    CHECK_LOG("[Stratagem Hero Expanded] applied (108 stratagems in 8 groups; pages 0x04, 0x04), at load.");
    CHECK(!vpm_ticking(fake_component(0)));
    ResetCounts();
    fake_frames(300, 1.0f / 60);
    CHECK_CALLS(0, 0, 0, 0);
}

/* Decoded later, before the stratagem settings load: the wait for them as before. */
static void TheReaderDecodedBeforeTheSettingsWaitsForThem(void)
{
    FreshPages();
    MakeWorld();
    Unload();
    Encode();
    Started();
    Loaded();
    CHECK(!vpm_ticking(fake_component(0)));
    Decode();
    fake_frames(30, 1.0f / 60);
    CHECK_LOG("Waiting for the game: the stratagem settings are not loaded yet.");
    CHECK(vpm_ticking(fake_component(0)) && Vanilla());
    Load();
    fake_frames(1, 1.0f / 60);
    CHECK(Expanded() && !vpm_ticking(fake_component(0)));
}

/* Never decoded: stopped after 60 s naming the reader; nothing read, written or page-checked. */
static void TheReaderNeverDecodedStopsItAfterAMinute(void)
{
    FreshPages();
    MakeWorld();
    Encode();
    Started();
    Loaded();
    fake_frames(59, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(1, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Stratagem Hero Expanded] disabled: the stratagem list's reader changed (game.dll 0x17EF922)");
    CHECK_EQ(fake_counts().read, 0);
    CHECK_EQ(g_page.queries + g_page.stores, 0);
    CHECK(Vanilla());
    ResetCounts();
    fake_frames(60, 1.0f);
    CHECK_CALLS(0, 0, 0, 0);
}

/* Another game build: the core keeps the component off; nothing is read or written. */
static void OffOnAnotherBuild(void)
{
    FreshPages();
    MakeWorld();
    fake_set_build("25000000");
    Started();
    Loaded();
    CHECK(!vpm_running(fake_component(0)));
    CHECK_CALLS(0, 0, 0, 0);
    CHECK(Vanilla());
}

/* The core stopping the component puts build 25480438's tables back. */
static void StopPutsTheVanillaTablesBack(void)
{
    Apply();
    CHECK(Expanded());
    vpm_core_stop(fake_component(0), "test");
    CHECK(Vanilla());
}

int main(void)
{
    RUN(VanillaReachesItsStratagems);
    RUN(ExpandedPoolHoldsEveryLoadoutAndMissionStratagemOnce);
    RUN(GroupsFollowTheGamesClasses);
    RUN(ExpandedOddsAreEvenOutsideThemes);
    RUN(AppliesAtLoad);
    RUN(AlreadyAppliedWritesNothing);
    RUN(WaitsForTheSettings);
    RUN(GivesUpAfterTenMinutes);
    RUN(RefusesSettingsTheArcadeCannotShow);
    RUN(RefusesTablesThatDiffer);
    RUN(RefusesPagesThatAreNotWritableImageData);
    RUN(SettingsOutsideThePoolDoNotMatter);
    RUN(RefusesAFailedOrLostWrite);
    RUN(PageCheckOnThisProcess);
    RUN(FollowsHellForgesMovedList);
    RUN(ReadsAListOutsideTheImage);
    RUN(RefusesAnotherReader);
    RUN(OffOnAnotherBuild);
    RUN(StopPutsTheVanillaTablesBack);
    RUN(TheReaderDecodedLaterAppliesThen);
    RUN(TheReaderDecodedBeforeTheSettingsWaitsForThem);
    RUN(TheReaderNeverDecodedStopsItAfterAMinute);
    TEST_END();
}
