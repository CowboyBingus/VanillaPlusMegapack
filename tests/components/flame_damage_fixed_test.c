/* Flame Damage Fixed: the Lua tests' scenarios (components/FlameDamageFixed/tests/test_fix.lua) on the fake game, with
 * the same synthetic world: the patch table, the effect lookup, check and fix with its refusals, the collision filter
 * check, the weapon family, the body scan and its read spans, the group allocator, verify / mark / unmark, the flame
 * instances, the driver's calls per frame, and the lifecycle (rescans, regrouping, destroyed vehicles, groups handed out
 * or carried by other bodies, no usable group, refusals, the mission reload, the restore at a stop). The Lua's
 * update-guard, garbage, JIT, loader and second-copy tests have no C counterpart (see the component's header). */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/flame_damage_fixed/flame_damage_fixed.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_flame_damage_fixed};

#define DT (1.0f / 60)
#define PARTICLES_LO 0x526FAD64u
#define PARTICLES_HI 0xA8193123u
/* Units: slot = handle & 0x3FFFFF. The hull's children are the arm, the cannon and a seated pilot (whose rifle hangs
 * below the pilot); the Flame Sentry and a Charger stand alone. */
#define H_HULL 0x400010u
#define H_ARM 0x400011u
#define H_CANNON 0x400012u
#define H_PILOT 0x400013u
#define H_RIFLE 0x400014u
#define H_SENTRY 0x400015u
#define H_CHARGER 0x400016u
#define ID1 0x21512u /* flame instance ids (instance record +0x10) */
#define ID2 0x21544u
#define OWN_ARM 21   /* hull 16 + arm 3 + cannon 2 */
#define OWN_SENTRY 3
#define FLAME_G (11u + (2047u << 21))
#define FLAME_2046 (11u + (2046u << 21))
#define PS_SIZE 0x2000u
#define BODY 160u
#define PAGE 0x1000u

static const uint32_t kFlameRow[] = {0, 2, 14, 17, 19, 20, 22, 27, 31, 39, 48, 54, 55, 59, 60, 63, 66, 77, 83, 86, 94, 100, 101};
static const int kArmBodies[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 18, 19, 20, 21, 22};
static const int kSentryBodies[] = {31, 32, 33};

typedef struct Body { uint32_t unit, filter, flags; } Body;

typedef struct Options
{
    uint32_t instances;   /* live instances of the flame (default 1) */
    uint32_t limit;       /* the body array's index bound (default 48) */
    int foreign_effect;   /* instance 1 belongs to another effect */
    uint32_t stale;       /* this particle system's slot holds an older generation */
    int wrong_world;      /* the physics world's vtable is not the reviewed one */
    int wrong_filter;     /* the collision filter's vtable is not the reviewed one */
    int spread;           /* the hull's bodies at 0-15, the arm's at 200-202, the cannon's at 700-701 */
    const uint32_t* row;  /* layer 11's row, when not the recorded one */
    int row_n;
    const uint32_t* used; /* groups the allocator handed out besides 0-2 */
    int used_n;
} Options;

static struct
{
    uint8_t *data, *spray, *instances, *entities[3], *pm_lists, *sims[2], *bodies, *ps_heap, *bitmap, *unit_heap;
    Body table[64];
    int table_n;
    uint32_t records;
} w;

static int g_frames;

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutPtr(uint8_t* at, const void* p) { Put64(at, (uint64_t)(uintptr_t)p); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint8_t* Game(uint32_t rva) { return (uint8_t*)fake_game() + rva; }
static uint8_t* Exe(uint32_t rva) { return (uint8_t*)fake_exe() + rva; }

/* Fake heap memory on pages of its own, so a test can change its protection. */
static uint8_t* PageHeap(size_t size)
{
    size_t pages = (size + PAGE - 1) / PAGE * PAGE;
    uintptr_t raw = (uintptr_t)fake_heap(pages + 2 * PAGE);
    return (uint8_t*)((raw + PAGE - 1) & ~(uintptr_t)(PAGE - 1));
}

static void Protect(void* at, size_t size, DWORD protection)
{
    DWORD old;
    if (!VirtualProtect(at, size, protection, &old)) printf("  VirtualProtect failed\n"); /* lint-ok: C3 the test makes fake memory read-only and back */
}

/* ---- the synthetic game: resources and sprays ------------------------------------------------------------------- */

/* The Lua test's stand-in for the shipped effect: the header, every system's size word and the 18 fixable words. */
static void ShippedEffect(uint8_t* data)
{
    memset(data, 0, FDF_EFFECT_SIZE);
    for (int i = 0; i < 24; i++) Put32(data + 4 * i, fdf_effect_header[i]);
    for (int i = 0; i < 12; i++) Put32(data + fdf_effect_systems[i][0] + 0x100, fdf_effect_systems[i][1]);
    for (int i = 0; i < FDF_PATCH_COUNT; i++) Put32(data + fdf_patches[i].offset, fdf_patches[i].shipped);
}

/* The resource manager: its particles bucket holds a decoy type chained to the particles entry, whose name table holds
 * the flame (record 7). */
static void MakeResources(int missing)
{
    uint8_t *root = fake_heap(0x400), *rm = fake_heap(0x308), *types = fake_heap(4 * 0xD0), *names = fake_heap(8 * 24);
    uint8_t* records = fake_heap(8 * 160);
    w.data = PageHeap(FDF_EFFECT_SIZE);
    PutPtr(Exe(FDF_RESOURCE_ROOT), root);
    PutPtr(root + 0x3F8, rm);
    PutPtr(rm + 0x2F0, types);
    Put32(rm + 0x300, 2);
    Put32(rm + 0x304, 4);
    for (int i = 0; i < 4; i++) Put32(types + i * 0xD0 + 0xC8, FDF_EMPTY_BUCKET);
    uint8_t* decoy = types + (PARTICLES_HI % 4) * 0xD0;
    Put32(decoy, 0x11111111u);
    Put32(decoy + 4, PARTICLES_HI);
    Put32(decoy + 0xC8, 0);
    Put32(types, PARTICLES_LO);
    Put32(types + 4, PARTICLES_HI);
    PutPtr(types + 0x10, records);
    Put32(types + 0x20, 2048);
    PutPtr(types + 0x28, names);
    Put32(types + 0x38, 2);
    Put32(types + 0x3C, 8);
    Put32(types + 0xC8, FDF_CHAIN_END);
    for (int i = 0; i < 8; i++) Put32(names + 24 * i + 16, FDF_EMPTY_BUCKET);
    uint8_t* name = names + 24 * (FDF_EFFECT_HI % 8);
    if (!missing)
    {
        Put32(name, FDF_EFFECT_LO);
        Put32(name + 4, FDF_EFFECT_HI);
        Put32(name + 8, 7);
        Put32(name + 16, FDF_CHAIN_END);
    }
    PutPtr(records + 7 * 160, w.data);
    Put64(records + 7 * 160 + 0x18, FDF_EFFECT_SIZE);
    ShippedEffect(w.data);
}

/* The spray manager: the Flame Sentry at index 0, the Lumberer arm at 1, the Cremator at 2. */
static void MakeSprays(uint32_t count)
{
    static const uint32_t kEntities[3][4] = {
        {0xFE962858u, 0x820CC3BAu, 7, H_SENTRY}, {0xD6328726u, 0x0736BEE2u, 8, H_ARM}, {0x63A70795u, 0x78A8185Fu, 9, 0x400099u}};
    uint8_t* list = fake_heap(3 * 8);
    w.spray = fake_heap(0x78);
    w.instances = fake_heap(3 * 0x218);
    PutPtr(Game(FDF_SPRAY_MANAGER), w.spray);
    Put32(w.spray + 0x38, count);
    PutPtr(w.spray + 0x60, list);
    PutPtr(w.spray + 0x70, w.instances);
    for (int i = 0; i < 3; i++)
    {
        w.entities[i] = fake_heap(32);
        memcpy(w.entities[i], kEntities[i], 16);
        PutPtr(list + 8 * i, w.entities[i]);
    }
}
#define SENTRY_STATE (w.instances)
#define ARM_STATE (w.instances + 0x218)
#define SENTRY_ID (SENTRY_STATE + 0x24)
#define ARM_ID (ARM_STATE + 0x24)

static void MakeGame(int missing) { memset(&w, 0, sizeof w); MakeResources(missing); MakeSprays(3); }

/* ---- the synthetic game: physics -------------------------------------------------------------------------------- */

static void Add(uint32_t unit, uint32_t filter, uint32_t flags, int n)
{
    for (int i = 0; i < n; i++) w.table[w.table_n++] = (Body){unit, filter, flags};
}

/* Bodies (index: owner, filter info): the hull's 13 layer-20 and 3 layer-54 hit-boxes, a ragdoll bone in game group 44
 * (layer 52) and a layer-87 body; the arm's 3 and the cannon's 2 layer-20 hit-boxes; the pilot's layer-2 hit-boxes
 * carrying game data in their subsystem bits and a layer-83 body; a Charger's 4 layer-20 hit-boxes; the Flame Sentry's
 * 3 layer-54 bodies and a layer-31 body with game data; a hull body that left the world. */
static void BodyTable(void)
{
    w.table_n = 0;
    Add(H_HULL, 20, 3, 13);
    Add(H_HULL, 54, 3, 3);
    Add(H_HULL, 52 + 1 * 128 + (44u << 21), 3, 1);
    Add(H_HULL, 87, 3, 1);
    Add(H_ARM, 20, 3, 3);
    Add(H_CANNON, 20, 3, 2);
    Add(H_PILOT, 2 + 8 * 128 + 2 * 16384, 3, 3);
    Add(H_PILOT, 83, 3, 1);
    Add(H_CHARGER, 20, 3, 4);
    Add(H_SENTRY, 54, 3, 3);
    Add(H_SENTRY, 31 + 3 * 128, 3, 1);
    Add(H_HULL, 20, 0, 1);
}

static const Body* BodyAt(uint32_t index, int spread)
{
    if (!spread) return index < (uint32_t)w.table_n ? &w.table[index] : NULL;
    if (index < 16) return &w.table[index];
    if (index >= 200 && index <= 202) return &w.table[18 + index - 200];
    if (index >= 700 && index <= 701) return &w.table[21 + index - 700];
    return NULL;
}

/* Instance 1 owns particle systems 1-6 (1-5 flame on layer 11, 6 another filter); instance 2 owns 7-12. Handles: world
 * 2, generation 9. */
static void MakeFlames(const Options* o)
{
    uint8_t *owner = fake_heap(0x230890), *pm = fake_heap(0x280), *entries = fake_heap(8 * 24), *records = fake_heap(2 * 136);
    w.pm_lists = fake_heap(8 * 24);
    PutPtr(Game(FDF_WORLD_PTR), owner);
    PutPtr(owner + 0x230888, pm);
    for (int i = 0; i < 8; i++) Put32(entries + 24 * i + 16, FDF_EMPTY_BUCKET);
    uint8_t* e = entries + 24 * (FDF_EFFECT_HI % 8);
    Put32(e, FDF_EFFECT_LO);
    Put32(e + 4, FDF_EFFECT_HI);
    Put32(e + 8, 5);
    Put32(e + 16, FDF_CHAIN_END);
    PutPtr(pm + 0x1B8, entries);
    Put32(pm + 0x1C8, 1);
    Put32(pm + 0x1CC, 8);
    Put32(pm + 0x228, 0xFF);
    PutPtr(pm + 0x278, w.pm_lists);
    Put32(w.pm_lists + 24 * 5, o->instances ? o->instances : 1);
    PutPtr(w.pm_lists + 24 * 5 + 8, records);
    for (uint32_t i = 0; i < 2; i++)
    {
        uint8_t* systems = fake_heap(12 * 80);
        w.sims[i] = fake_heap(64);
        PutPtr(records + 136 * i + 8, w.sims[i]);
        Put32(records + 136 * i + 16, i == 0 ? ID1 : ID2);
        PutPtr(w.sims[i] + 32, i == 0 && o->foreign_effect ? (void*)fake_heap(16) : (void*)w.data);
        Put32(w.sims[i] + 40, 12);
        Put32(w.sims[i] + 44, 12);
        PutPtr(w.sims[i] + 48, systems);
        for (uint32_t s = 0; s <= 5; s++) Put32(systems + 80 * s + 52, 0x81090000u + 1 + 6 * i + s);
    }
}

/* The hknp world (world 2): body array (+0x38, size +0x40, index bound +0x50) and particle systems. */
static void MakeWorld(const Options* o)
{
    uint32_t limit = o->limit ? o->limit : o->spread ? 800 : 48;
    uint8_t *world = fake_heap(0x500), *table = fake_heap(16), *array = fake_heap(16 * 16);
    w.records = limit > 64 ? limit : 64;
    w.bodies = PageHeap((size_t)w.records * BODY);
    w.ps_heap = PageHeap(13 * PS_SIZE);
    Put64(world, fake_exe() + (o->wrong_world ? 0x2000u : FDF_WORLD_VTABLE));
    PutPtr(world + 0x38, w.bodies);
    Put32(world + 0x40, 4096);
    Put32(world + 0x50, limit);
    PutPtr(world + 32 + 1144, table);
    PutPtr(Exe(FDF_WORLDS + FDF_WORLD_STRIDE * 2), world);
    for (uint32_t index = 0; index < w.records; index++)
    {
        const Body* b = BodyAt(index, o->spread);
        uint8_t* r = w.bodies + (size_t)BODY * index;
        if (b == NULL) continue;
        Put32(r + 68, b->flags);
        Put32(r + 108, b->filter);
        Put32(r + 112, index + (5u << 24));
        Put32(r + 144, 0xB0000000u + index);
        Put32(r + 148, b->unit);
    }
    PutPtr(table + 8, array);
    for (uint32_t index = 1; index <= 12; index++)
    {
        PutPtr(array + 16 * index, w.ps_heap + PS_SIZE * index);
        Put32(array + 16 * index + 8, index + ((o->stale == index ? 8u : 9u) << 24));
    }
    for (uint32_t index = 0; index <= 12; index++) Put32(w.ps_heap + PS_SIZE * index + FDF_PS_FILTER, index == 6 || index == 12 ? 0x4Au : 11u);
}

static void Link(uint8_t* matrix, uint32_t i, uint32_t j)
{
    uint8_t *a = matrix + 16 * i + 4 * (j / 32), *b = matrix + 16 * j + 4 * (i / 32);
    Put32(a, Get32(a) | 1u << (j % 32));
    Put32(b, Get32(b) | 1u << (i % 32));
}

/* The world's collision filter: every layer collides with 0, and layer 11 with its recorded row. */
static void MakeFilter(const Options* o)
{
    uint8_t* filter = fake_heap(8 + 32 + 128 * 16 + 8);
    const uint32_t* row = o->row ? o->row : kFlameRow;
    int n = o->row ? o->row_n : (int)(sizeof kFlameRow / sizeof kFlameRow[0]);
    Put64(filter, fake_exe() + (o->wrong_filter ? 0x1000u : FDF_FILTER_VTABLE));
    for (uint32_t j = 0; j < 128; j++) Link(filter + 40, 0, j);
    for (int i = 0; i < n; i++) Link(filter + 40, 11, row[i]);
    PutPtr(Exe(FDF_FILTER_PTR), filter);
}

static uint8_t* UnitAt(uint32_t handle) { return w.unit_heap + 0x400u * (handle % 4194304u); }

/* The unit registry and tree (+8 handle, +0x1D0 parent, +0x1D8 first child, +0x1E0 next sibling, +0x358 resource). */
static void MakeUnits(void)
{
    static const uint32_t kTree[7][5] = {
        {H_HULL, 0, H_ARM, 0, 0}, {H_ARM, H_HULL, 0, H_CANNON, 0}, {H_CANNON, H_HULL, 0, H_PILOT, 0},
        {H_PILOT, H_HULL, H_RIFLE, 0, 1}, {H_RIFLE, H_PILOT, 0, 0, 0}, {H_SENTRY, 0, 0, 0, 0}, {H_CHARGER, 0, 0, 0, 0}};
    uint8_t *registry = fake_heap(0x90), *objects = fake_heap(32 * 8);
    w.unit_heap = fake_heap(0x400u * 512u);
    PutPtr(Exe(FDF_UNITS), registry);
    PutPtr(registry + 0x88, objects);
    for (int i = 0; i < 7; i++)
    {
        uint8_t* at = UnitAt(kTree[i][0]);
        PutPtr(objects + 8 * (kTree[i][0] % 4194304u), at);
        Put32(at + 8, kTree[i][0]);
        if (kTree[i][1] != 0) PutPtr(at + 0x1D0, UnitAt(kTree[i][1]));
        if (kTree[i][2] != 0) PutPtr(at + 0x1D8, UnitAt(kTree[i][2]));
        if (kTree[i][3] != 0) PutPtr(at + 0x1E0, UnitAt(kTree[i][3]));
        Put64(at + 0x358, kTree[i][4] ? 0x4D1C334D294DFA97ull : 0x1000u + kTree[i][0] % 4194304u);
    }
}

/* Clears group g's free bit in the allocator, as if the game had handed it out. */
static void Allocate(uint32_t g)
{
    uint8_t* at = w.bitmap + 8 + 4 * (g / 32);
    Put32(at, Get32(at) & ~(1u << (g % 32)));
}

/* The system-group allocator: 2048 groups, one summary word, set bit = free; 0-2 in use (and o->used). */
static void MakeAllocator(const Options* o)
{
    uint8_t* allocator = fake_heap(16);
    w.bitmap = fake_heap(8 + 64 * 4);
    PutPtr(Exe(FDF_GROUPS), allocator);
    Put32(allocator, 2048);
    Put32(allocator + 4, 1);
    PutPtr(allocator + 8, w.bitmap);
    Put64(w.bitmap, 0xFFFFFFFFu);
    for (int k = 0; k < 64; k++) Put32(w.bitmap + 8 + 4 * k, 0xFFFFFFFFu);
    for (uint32_t g = 0; g < 3; g++) Allocate(g);
    for (int i = 0; i < o->used_n; i++) Allocate(o->used[i]);
}

static void MakePhysics(const Options* o)
{
    BodyTable();
    MakeFlames(o);
    MakeWorld(o);
    MakeFilter(o);
    MakeUnits();
    MakeAllocator(o);
}

static void MakeAll(const Options* o)
{
    MakeGame(0);
    MakePhysics(o);
}

/* ---- observing it ----------------------------------------------------------------------------------------------- */

static uint32_t FilterOf(uint32_t index) { return Get32(w.bodies + BODY * index + 108); }
static uint32_t GroupOf(uint32_t index) { return FilterOf(index) >> 21; }
static uint32_t LayerOf(uint32_t system) { return Get32(w.ps_heap + PS_SIZE * system + FDF_PS_FILTER); }
static void SetBody(uint32_t index, uint32_t at, uint32_t value) { Put32(w.bodies + BODY * index + at, value); }

static int EffectFixed(void)
{
    for (int i = 0; i < FDF_PATCH_COUNT; i++)
        if (Get32(w.data + fdf_patches[i].offset) != fdf_patches[i].fixed) return 0;
    return 1;
}

static int EffectShipped(void)
{
    for (int i = 0; i < FDF_PATCH_COUNT; i++)
        if (Get32(w.data + fdf_patches[i].offset) != fdf_patches[i].shipped) return 0;
    return 1;
}

/* Every body's filter info equals the table's, except the listed ones, which carry group g on top. */
static int BodiesAre(const int* marked, int n, uint32_t g)
{
    for (int i = 0; i < w.table_n; i++)
    {
        int in = 0;
        for (int j = 0; j < n; j++) in |= marked[j] == i;
        uint32_t want = w.table[i].filter + (in ? g << 21 : 0);
        if (FilterOf((uint32_t)i) != want) { printf("  body %d: filter %08X, want %08X\n", i, FilterOf((uint32_t)i), want); return 0; }
    }
    return 1;
}
#define ARM_BODIES kArmBodies, OWN_ARM
#define SENTRY_BODIES kSentryBodies, OWN_SENTRY
#define NO_BODIES NULL, 0

static FdfTestWeapon Weapon(uint8_t* state)
{
    FdfTestWeapon out;
    memset(&out, 0, sizeof out);
    if (!fdf_test_weapon((uintptr_t)state, &out)) out.group = 0xFFFFFFFFu;
    return out;
}

static int LogCount(const char* text)
{
    int n = 0;
    for (const char* at = fake_log_text(); (at = strstr(at, text)) != NULL; at += strlen(text)) n++;
    return n;
}

/* Calls, as the Lua's frame_budget counted them: API reads and writes, vpm_writable checks, VirtualQuery calls for
 * store regions, plain stores. */
typedef struct Cost { uint32_t reads, writes, logs, writable, queries, stores; } Cost;
static void CostReset(void)
{
    fake_counts_reset();
    memset(&fdf_test_counts, 0, sizeof fdf_test_counts);
}
static Cost CostNow(void)
{
    FakeCounts f = fake_counts();
    Cost c = {f.read, f.write, f.log, fdf_test_counts.writable, fdf_test_counts.queries, fdf_test_counts.stores};
    return c;
}
#define PIN(cost, r, wr, q, st) do { Cost c_ = (cost); CHECK_EQ(c_.reads, r); CHECK_EQ(c_.writable, wr); \
    CHECK_EQ(c_.queries, q); CHECK_EQ(c_.stores, st); CHECK_EQ(c_.writes, 0); } while (0)

static void Started(void)
{
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    g_frames = 0;
    CostReset();
}

static void Frames(int n)
{
    for (int i = 0; i < n; i++)
    {
        fake_frames(1, DT);
        g_frames++;
    }
}
static Cost Frame(void) { CostReset(); Frames(1); return CostNow(); }
/* Runs up to the next weapon scan (every 30 frames of 1/60 s, from the first) and returns that frame's calls. */
static Cost ScanFrame(void)
{
    while (g_frames % 30 != 0) Frames(1);
    return Frame();
}
static void Fire(uint8_t* state, uint32_t value, uint32_t id)
{
    Put32(state, value);
    Put32(state + 0x24, id);
}
/* The Lua test's arm_grouped: both families scanned (6 frames), then the arm's first burst (frame 7). */
static void ArmGrouped(const Options* o)
{
    MakeAll(o);
    Started();
    Frames(6);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
}

/* ---- the patch table and the effect ----------------------------------------------------------------------------- */

static void PatchTableIsTheShippedLayout(void)
{
    CHECK_EQ(FDF_PATCH_COUNT, 18); /* spawn (8) + emitters (8) + hide (2) words */
    for (int i = 1; i < 12; i++) CHECK_EQ(fdf_effect_systems[i][0], fdf_effect_systems[i - 1][0] + fdf_effect_systems[i - 1][1]);
    CHECK_EQ(fdf_effect_systems[11][0] + fdf_effect_systems[11][1], FDF_EFFECT_SIZE);
    for (int i = 0; i < FDF_PATCH_COUNT; i++)
    {
        const FdfPatch* p = &fdf_patches[i];
        CHECK(p->shipped != p->fixed && p->offset % 4 == 0);
        for (int k = 0; k < 12; k++)
        {
            uint32_t start = fdf_effect_systems[k][0], rel = p->offset - start;
            if (p->offset < start || rel >= fdf_effect_systems[k][1]) continue;
            /* The only header field written is the visualizer count of systems 0 and 3 (1 -> 0). */
            int hide = rel == 0xF8 && p->shipped == 1 && p->fixed == 0 && (k == 0 || k == 3);
            CHECK(hide || rel < 0xE0 || rel >= 0x108);
        }
    }
}

static void EffectLookupCheckAndFix(void)
{
    Options o = {0};
    MakeAll(&o);
    Started();
    uintptr_t data = 0;
    FdfReason why = FDF_OK;
    CHECK(fdf_resolve_effect(&data, &why) && data == (uintptr_t)w.data); /* through both hash chains */
    /* Root (a plain load) -> manager, the type table, the decoy and the particles entry, the name, the record. */
    CHECK_EQ(CostNow().reads, 6);
    int writes = 0;
    CostReset();
    CHECK(fdf_apply_effect(data, &writes, &why) && writes == 18 && EffectFixed());
    PIN(CostNow(), 2, 1, 0, 18); /* the Lua: 90 word reads, 1 writable_data, 18 writes */
    int changed = 0;
    uint8_t shipped[FDF_EFFECT_SIZE];
    ShippedEffect(shipped);
    for (uint32_t i = 0; i < FDF_EFFECT_SIZE; i++) changed += w.data[i] != shipped[i];
    CHECK(changed <= 72); /* only the 18 patched words differ from the shipped file */
    CostReset();
    CHECK(fdf_apply_effect(data, &writes, &why) && writes == 0);
    PIN(CostNow(), 1, 0, 0, 0); /* the Lua: 54 word reads */

    MakeGame(1);
    CHECK(!fdf_resolve_effect(&data, &why) && why == FDF_EFFECT_NOT_LOADED);
    MakeGame(0);
    Put32(w.data + fdf_patches[2].offset, 0x04030201u);
    CHECK(!fdf_apply_effect((uintptr_t)w.data, &writes, &why) && why == FDF_REASON_AT(FDF_UNKNOWN_VALUE, 2));
    char text[64];
    CHECK(strcmp(fdf_reason_text(why, text, sizeof text), "unknown value at 328") == 0);
    MakeGame(0);
    w.data[0] = 'X';
    CHECK(!fdf_apply_effect((uintptr_t)w.data, &writes, &why) && why == FDF_HEADER_CHANGED);
    MakeGame(0);
    Put32(w.data + fdf_effect_systems[5][0] + 0x100, 1);
    CHECK(!fdf_apply_effect((uintptr_t)w.data, &writes, &why) && why == FDF_LAYOUT_CHANGED);
    MakeGame(0);
    Protect(w.data, FDF_EFFECT_SIZE, PAGE_READONLY);
    CHECK(!fdf_apply_effect((uintptr_t)w.data, &writes, &why) && why == FDF_EFFECT_WRITABLE);
    Protect(w.data, FDF_EFFECT_SIZE, PAGE_READWRITE);
    CHECK(EffectShipped());
}

/* ---- the collision filter, the family, the body scan ------------------------------------------------------------ */

static void CollisionFilterCheck(void)
{
    Options o = {0};
    uintptr_t filter = 0;
    FdfReason why = FDF_OK;
    MakeAll(&o);
    Started();
    CHECK(fdf_check_filter(&filter, &why) && filter == (uintptr_t)vpm_exe_u64(FDF_FILTER_PTR));
    CHECK_EQ(CostNow().reads, 1); /* the Lua: 8 */
    o.wrong_filter = 1;
    MakeAll(&o);
    CHECK(!fdf_check_filter(&filter, &why) && why == FDF_FILTER_TYPE);
    static const uint32_t changed[] = {0, 2, 20};
    Options r = {0};
    r.row = changed;
    r.row_n = 3;
    MakeAll(&r);
    CHECK(!fdf_check_filter(&filter, &why) && why == FDF_FLAME_ROW);
    fake_setup();
    MakeGame(0);
    Started();
    CHECK(!fdf_check_filter(&filter, &why) && why == FDF_FILTER_UNAVAILABLE);
}

static void FamilyIsTheVehicleWithoutThePilot(void)
{
    Options o = {0};
    FdfFamily family;
    FdfReason why = FDF_OK;
    MakeAll(&o);
    Started();
    CHECK_EQ(fdf_family(H_ARM, &family, &why), 3);
    CHECK(fdf_in_family(&family, H_HULL) && fdf_in_family(&family, H_ARM) && fdf_in_family(&family, H_CANNON));
    CHECK(!fdf_in_family(&family, H_PILOT) && !fdf_in_family(&family, H_RIFLE) && !fdf_in_family(&family, H_CHARGER));
    /* objects, the unit, its handle, its parent; the hull, three sibling links, the pilot (skipped), cannon and arm */
    CHECK_EQ(CostNow().reads, 11);
    CHECK_EQ(fdf_family(H_CANNON, &family, &why), 3); /* the same family from the cannon */
    CHECK(fdf_family(H_SENTRY, &family, &why) == 1 && family.units[0] == H_SENTRY); /* no parent: its own family */
    CHECK(fdf_family(H_ARM + 0x400000u, &family, &why) < 0 && why == FDF_WEAPON_UNIT);
    /* A parent with more than 16 descendants is refused. */
    for (uint32_t k = 0; k < 18; k++)
    {
        uint8_t* child = UnitAt(H_SENTRY + 0x100 + k);
        Put32(child + 8, H_SENTRY + 0x100 + k);
        if (k < 17) PutPtr(child + 0x1E0, UnitAt(H_SENTRY + 0x101 + k));
    }
    PutPtr(UnitAt(H_SENTRY) + 0x1D8, UnitAt(H_SENTRY + 0x100));
    CHECK(fdf_family(H_SENTRY, &family, &why) < 0 && why == FDF_FAMILY_TOO_LARGE);
    fake_setup();
    MakeGame(0);
    Started();
    CHECK(fdf_family(H_ARM, &family, &why) < 0 && why == FDF_UNIT_REGISTRY);
}

static FdfJob g_job;
static FdfFamily g_family;
static int NotOwn(uint32_t group, uint32_t unit) { return 0; }

/* The Lua test's scanned(): a complete body scan of handle's family with group g. */
static FdfJob* Scanned(uint32_t handle, uint32_t g)
{
    FdfReason why = FDF_OK;
    FdfScanFor scan = {&g_family, g, NotOwn};
    memset(&g_job, 0, sizeof g_job);
    CHECK(fdf_family(handle, &g_family, &why) >= 0);
    CHECK(fdf_scan_begin(&g_job, &why));
    CHECK_EQ(fdf_scan_step(&g_job, &scan, 16, &why), 1);
    return &g_job;
}

static void BodyScanKeepsTheFamilysHittableBodies(void)
{
    Options o = {0};
    FdfReason why = FDF_OK;
    MakeAll(&o);
    Started();
    CHECK(fdf_family(H_ARM, &g_family, &why) == 3);
    memset(&g_job, 0, sizeof g_job);
    CostReset();
    CHECK(fdf_scan_begin(&g_job, &why) && g_job.worlds == 1 && g_job.bases[0] == (uintptr_t)w.bodies && g_job.limits[0] == 48);
    CHECK_EQ(CostNow().reads, 1); /* 4 world slots (plain loads), one world header (the Lua: 14) */
    FdfScanFor scan = {&g_family, 0, NotOwn};
    CostReset();
    CHECK_EQ(fdf_scan_step(&g_job, &scan, 4, &why), 1);
    CHECK_EQ(g_job.n, OWN_ARM);
    CHECK_EQ(CostNow().reads, 1); /* one block */
    for (int k = 0; k < g_job.n; k++) CHECK_EQ(g_job.index[k], kArmBodies[k]);
    CHECK_EQ(g_job.spans, 1); /* bodies close together share one read */
    /* A large body array is read in blocks of 409 bodies, 4 blocks per call. */
    o.limit = 2000;
    MakeAll(&o);
    memset(&g_job, 0, sizeof g_job);
    CHECK(fdf_scan_begin(&g_job, &why));
    CostReset();
    CHECK(fdf_scan_step(&g_job, &scan, 4, &why) == 0 && g_job.i == 4 * 409);
    CHECK_EQ(CostNow().reads, 4);
    CostReset();
    CHECK(fdf_scan_step(&g_job, &scan, 4, &why) == 1 && g_job.n == OWN_ARM);
    CHECK_EQ(CostNow().reads, 1);
    Options wrong = {0};
    wrong.wrong_world = 1;
    MakeAll(&wrong);
    CHECK(!fdf_scan_begin(&g_job, &why) && why == FDF_NO_WORLD);
}

/* Bodies far apart are read in separate spans (hull at 0-15, arm at 200-202, cannon at 700-701). */
static void FarBodiesAreSeparateSpans(void)
{
    Options o = {0};
    FdfReason why = FDF_OK;
    o.spread = 1;
    MakeAll(&o);
    Started();
    FdfJob* job = Scanned(H_ARM, 0);
    CHECK(job->n == OWN_ARM && job->spans == 3);
    CostReset();
    CHECK_EQ(fdf_mark(job, 2047, &why), OWN_ARM);
    PIN(CostNow(), 3, 0, 1, OWN_ARM); /* one read per span */
    static const uint32_t spread[] = {0, 15, 200, 202, 700, 701};
    for (int i = 0; i < 6; i++) CHECK_EQ(GroupOf(spread[i]), 2047);
}

static void GroupAllocator(void)
{
    Options o = {0};
    MakeAll(&o);
    Started();
    CHECK(fdf_group_free(2047) && fdf_group_free(2040));
    CHECK(!fdf_group_free(2) && !fdf_group_free(0));
    CostReset();
    CHECK(fdf_group_free(2047));
    CHECK_EQ(CostNow().reads, 2); /* the Lua: 7 */
    static const uint32_t used[] = {2047};
    o.used = used;
    o.used_n = 1;
    MakeAll(&o);
    CHECK(!fdf_group_free(2047) && fdf_group_free(2046));
}

/* verify, mark and unmark change only the group bits of the family's own group-free bodies. */
static void GroupingTouchesOnlyOwnGroupFreeBodies(void)
{
    Options o = {0};
    FdfReason why = FDF_OK;
    FdfCounts c;
    MakeAll(&o);
    Started();
    FdfJob* job = Scanned(H_ARM, 0);
    CostReset();
    CHECK(fdf_verify(job, 0, &c) && c.free == OWN_ARM && c.own == 0 && c.moved == 0 && c.stale == 0);
    CHECK_EQ(CostNow().reads, 1); /* one read per span */
    CostReset();
    CHECK_EQ(fdf_mark(job, 2047, &why), OWN_ARM);
    PIN(CostNow(), 1, 0, 1, OWN_ARM);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    CHECK(fdf_verify(job, 2047, &c) && c.own == OWN_ARM && c.free == 0);
    CostReset();
    CHECK_EQ(fdf_mark(job, 2047, &why), OWN_ARM);
    PIN(CostNow(), 1, 0, 0, 0); /* already grouped: reads only */
    CostReset();
    CHECK_EQ(fdf_unmark(job, 2047, &why), OWN_ARM);
    PIN(CostNow(), 1, 0, 1, OWN_ARM);
    CHECK(BodiesAre(NO_BODIES, 2047));
    /* A slot recycled by another unit and a body the game gave another group are stale and never touched; a rebuilt
     * body (new actor) is stale for grouping but still ours to clear; a grouped body the game switched to another layer
     * (destruction) is moved, and is cleared with its new layer kept. */
    CHECK_EQ(fdf_mark(job, 2047, &why), OWN_ARM);
    SetBody(3, 148, H_CHARGER);
    SetBody(4, 108, 20 + (5u << 21));
    SetBody(5, 144, 0xC0000123u);
    SetBody(6, 108, 48 + (2047u << 21));
    CHECK(fdf_verify(job, 2047, &c) && c.stale == 3 && c.moved == 1 && c.own == OWN_ARM - 4);
    CHECK_EQ(fdf_unmark(job, 2047, &why), OWN_ARM - 2);
    CHECK(GroupOf(3) == 2047 && GroupOf(4) == 5 && GroupOf(5) == 0 && FilterOf(6) == 48);
    /* Nothing is written when the body memory is not private read-write. */
    MakeAll(&o);
    job = Scanned(H_ARM, 0);
    Protect(w.bodies, (size_t)w.records * BODY, PAGE_READONLY);
    CHECK(fdf_mark(job, 2047, &why) < 0 && why == FDF_BODY_WRITABLE);
    Protect(w.bodies, (size_t)w.records * BODY, PAGE_READWRITE);
    CHECK(BodiesAre(NO_BODIES, 2047));
}

/* A scan that meets bodies already carrying the weapon's group keeps them as grouped. */
static void ScanKeepsBodiesOfTheWeaponsGroup(void)
{
    Options o = {0};
    FdfReason why = FDF_OK;
    MakeAll(&o);
    Started();
    SetBody(2, 108, 20 + (2047u << 21));
    SetBody(19, 108, 20 + (2046u << 21)); /* another group: not ours */
    FdfJob* job = Scanned(H_ARM, 2047);
    CHECK_EQ(job->n, OWN_ARM - 1);
    int marked = 0;
    for (int k = 0; k < job->n; k++) marked += job->marked[k];
    CHECK_EQ(marked, 1);
    CHECK(fdf_unmark(job, 2047, &why) == 1 && GroupOf(2) == 0 && GroupOf(19) == 2046);
    CHECK(job->foreign[2046 - FDF_GROUP_LOW] && !job->foreign[2047 - FDF_GROUP_LOW]);
}

/* ---- the flame instances ---------------------------------------------------------------------------------------- */

static void FlameInstancesByIdAndGrouping(void)
{
    Options o = {0};
    FdfRegion region = {0, 0};
    FdfReason why = FDF_OK;
    uintptr_t sim = 0;
    o.instances = 2;
    MakeAll(&o);
    Started();
    uintptr_t slot = fdf_flame_slot();
    CHECK(slot == (uintptr_t)w.pm_lists + 24 * 5);
    CHECK_EQ(CostNow().reads, 3); /* the manager, its fields, the flame's entry */
    CHECK(fdf_find_instance(slot, ID2, &sim) && sim == (uintptr_t)w.sims[1]);
    CHECK(!fdf_find_instance(slot, 0x999, &sim));
    CostReset();
    CHECK_EQ(fdf_retarget((uintptr_t)w.sims[0], (uintptr_t)w.data, &region, FLAME_G, 11, &why), 5);
    /* The instance's head and system list, the particle-system array once (2), each system's slot and filter (6 x 2);
     * the Lua: 47 reads. One VirtualQuery and 5 stores, as the Lua. */
    PIN(CostNow(), 16, 0, 1, 5);
    for (uint32_t index = 1; index <= 5; index++) CHECK_EQ(LayerOf(index), FLAME_G);
    CHECK(LayerOf(6) == 0x4A && LayerOf(7) == 11); /* other filters and instances untouched */
    FdfRegion fresh = {0, 0};
    CostReset();
    CHECK_EQ(fdf_retarget((uintptr_t)w.sims[0], (uintptr_t)w.data, &fresh, FLAME_G, 11, &why), 0);
    CHECK(CostNow().queries == 0 && CostNow().stores == 0); /* already grouped: reads only */
    o.foreign_effect = 1;
    MakeAll(&o);
    CHECK(fdf_retarget((uintptr_t)w.sims[0], (uintptr_t)w.data, &fresh, FLAME_G, 11, &why) == 0 && LayerOf(1) == 11);
    Options stale = {0};
    stale.stale = 3;
    MakeAll(&stale);
    FdfRegion again = {0, 0};
    CHECK_EQ(fdf_retarget((uintptr_t)w.sims[0], (uintptr_t)w.data, &again, FLAME_G, 11, &why), 4); /* generation mismatch skipped */
    Options plain = {0};
    MakeAll(&plain);
    FdfRegion locked = {0, 0};
    Protect(w.ps_heap, 13 * PS_SIZE, PAGE_READONLY);
    CHECK(fdf_retarget((uintptr_t)w.sims[0], (uintptr_t)w.data, &locked, FLAME_G, 11, &why) < 0 && why == FDF_PARTICLE_WRITABLE);
    Protect(w.ps_heap, 13 * PS_SIZE, PAGE_READWRITE);
    CHECK_EQ(LayerOf(1), 11);
    fake_setup();
    MakeGame(0);
    Started();
    CHECK(fdf_flame_slot() == 0); /* no physics: no slot */
}

/* ---- the per-frame driver --------------------------------------------------------------------------------------- */

static void DriverCallsPerFrame(void)
{
    Options o = {0};
    MakeAll(&o);
    Started();
    /* The weapon scan (the manager's fields, the entity list, 3 entities), then the first weapon's family lookup (the
     * Flame Sentry: itself, no parent) and its scan's start, in the same frame. The Lua: 49 reads. */
    PIN(Frame(), 13, 0, 0, 0);
    CHECK_EQ(fdf_test_tracked(), 2); /* the Flame Sentry and the Lumberer arm, the Cremator ignored */
    PIN(Frame(), 3, 0, 0, 0);  /* the Flame Sentry's body scan: 2 states and one block (the Lua: 2 + 1 load) */
    PIN(Frame(), 14, 0, 0, 0); /* the Lumberer's family (hull, arm, cannon; pilot skipped) (the Lua: 45) */
    PIN(Frame(), 3, 0, 0, 0);  /* the Lumberer's body scan */
    FdfTestWeapon sentry = Weapon(SENTRY_STATE), arm = Weapon(ARM_STATE);
    CHECK(sentry.job_ok && sentry.kept == OWN_SENTRY && arm.job_ok && arm.kept == OWN_ARM);
    for (int i = 0; i < 10; i++) PIN(Frame(), 2, 0, 0, 0); /* one state read per tracked weapon */
    CHECK(BodiesAre(NO_BODIES, 2047));
    /* First burst: the effect fixed, the arm's own bodies grouped, its burst instance's flame systems grouped. The
     * effect lookup (6), check and read-back (2), the filter (1), the flame slot (3), the bodies (1) and the group (2)
     * and the grouping (1), the burst instance (3) and its systems (16), the states (2). The Lua: 202 reads + 2 loads,
     * 1 writable_data, 2 writable_region, 18 + 26 writes. */
    Fire(ARM_STATE, 1, ID1);
    PIN(Frame(), 37, 1, 2, 18 + OWN_ARM + 5);
    CHECK(EffectFixed());
    CHECK(BodiesAre(ARM_BODIES, 2047));
    for (uint32_t index = 1; index <= 5; index++) CHECK_EQ(LayerOf(index), FLAME_G);
    CHECK_LOG("[Flame Damage Fixed] Flame effect fixed (18 words).");
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix active for the Lumberer (21/21 own bodies in group 2047).");
    /* Firing: the states and the arm's instance id, no stores (as the Lua: 3). */
    Put32(ARM_STATE, 2);
    for (int i = 0; i < 5; i++) PIN(Frame(), 3, 0, 0, 0);
    /* Firing stops: the bodies stay grouped and frames go straight back to the state reads. */
    Put32(ARM_STATE, 3);
    for (int i = 0; i < 5; i++) PIN(Frame(), 2, 0, 0, 0);
    Put32(w.pm_lists + 24 * 5, 0); /* the burst's flame instance died */
    Frames(5);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    /* The weapon scan confirms the group: one read per span and the allocator (2) (the Lua: 22 + 7 reads, 1 load). */
    PIN(ScanFrame(), 10, 0, 0, 0);
    /* Second burst: the bodies confirmed with one read and the group in the allocator; only the new instance is
     * written (the Lua: 106 reads + 1 load, 1 writable_region, 5 writes). */
    int lines = LogCount("[Flame Damage Fixed]");
    Put32(w.pm_lists + 24 * 5, 2);
    Fire(ARM_STATE, 2, ID2);
    PIN(Frame(), 34, 0, 1, 5);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    for (uint32_t index = 7; index <= 11; index++) CHECK_EQ(LayerOf(index), FLAME_G);
    CHECK(LayerOf(12) == 0x4A && LogCount("[Flame Damage Fixed]") == lines); /* nothing logged */
    /* The Flame Sentry fires as well: its own bodies get the next free group. */
    Fire(SENTRY_STATE, 2, ID1);
    Frames(1);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 2047);
    for (int i = 0; i < OWN_SENTRY; i++) CHECK_EQ(GroupOf((uint32_t)kSentryBodies[i]), 2046);
    CHECK_EQ(Weapon(SENTRY_STATE).group, 2046);
    static const uint32_t others[] = {16, 17, 23, 24, 25, 26, 27, 28, 29, 30, 34, 35};
    for (int i = 0; i < 12; i++) CHECK_EQ(FilterOf(others[i]), w.table[others[i]].filter);
    /* Weapons gone: their bodies leave the groups (one read per span, a VirtualQuery and a store per body, as the Lua),
     * and frames go back to one manager read per 0.5 s. */
    Put32(SENTRY_STATE, 0);
    Put32(ARM_STATE, 0);
    Put32(w.spray + 0x38, 0);
    PIN(ScanFrame(), 3, 0, 2, OWN_ARM + OWN_SENTRY);
    CHECK(fdf_test_tracked() == 0 && Weapon(ARM_STATE).group == 0xFFFFFFFFu && Weapon(SENTRY_STATE).group == 0xFFFFFFFFu);
    for (uint32_t index = 0; index < 48; index++) CHECK_EQ(GroupOf(index), index == 16 ? 44u : 0u);
    CostReset();
    Frames(30);
    PIN(CostNow(), 1, 0, 0, 0); /* idle: the manager's count once per scan period (the Lua: 3 reads) */
    CHECK_EQ(CostNow().logs, 0);
}

/* Idle on the ship (no spray manager) and in a mission without a tracked weapon. */
static void IdleFramesCostNothing(void)
{
    Options o = {0};
    MakeAll(&o);
    Put64(Game(FDF_SPRAY_MANAGER), 0);
    Started();
    Frames(120);
    PIN(CostNow(), 0, 0, 0, 0);
    CHECK_EQ(CostNow().logs, 0);
    PutPtr(Game(FDF_SPRAY_MANAGER), w.spray);
    Put32(w.spray + 0x38, 0);
    CostReset();
    Frames(120);
    PIN(CostNow(), 4, 0, 0, 0); /* 4 scans, 1 read each */
    CHECK_EQ(CostNow().logs, 0);
}

/* Lifecycle: a hit-box the game rebuilds starts a new scan (grouped bodies stay grouped); one found group-free again is
 * grouped at the next burst; a grouped body switched to another layer means the vehicle was destroyed, so its bodies
 * leave the group and are not grouped again. */
static void RebuiltRegroupedAndDestroyed(void)
{
    Options o = {0};
    ArmGrouped(&o);
    Put32(ARM_STATE, 0);
    Frames(2);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    SetBody(7, 144, 0xC0000777u); /* body 7 rebuilt: new actor, group kept */
    Frames(40);                   /* a weapon scan sees it stale and starts a new body scan, which completes */
    FdfTestWeapon arm = Weapon(ARM_STATE);
    CHECK(arm.job_ok && arm.marked && arm.kept == OWN_ARM && !arm.scanning);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    SetBody(8, 108, 20); /* the game reset body 8's filter: group-free again */
    Fire(ARM_STATE, 2, ID2);
    /* The states, the burst start (10), the bodies and the group (3), the regrouping (1), the instance id and the slot's
     * records (3; ID2 is not live) */
    PIN(Frame(), 2 + 10 + 3 + 1 + 3, 0, 1, 1);
    CHECK_EQ(GroupOf(8), 2047);
    Put32(ARM_STATE, 0);
    Frames(2);
    SetBody(9, 108, 48 + (2047u << 21)); /* destroyed: the game moves it to layer 48 */
    Frames(40);
    arm = Weapon(ARM_STATE);
    CHECK(arm.destroyed && !arm.marked);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 0);
    CHECK_EQ(FilterOf(9), 48); /* the new layer is kept */
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 0); /* not grouped again */
}

/* A rescan never loses track of the grouped bodies: until it is complete the last complete scan stays in use, so a
 * weapon released mid-rescan leaves no body in its group. Here the rescan starts at a burst (a rebuilt hit-box), one
 * frame before the weapon scan that finds the weapon gone. */
static void ReleasedMidRescan(void)
{
    Options o = {0};
    o.limit = 4000; /* 10 blocks: a body scan takes 3 frames */
    MakeAll(&o);
    Started();
    Frames(20);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    Put32(ARM_STATE, 0);
    while (g_frames < 59) Frames(1);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    SetBody(7, 144, 0xC0000777u);
    Fire(ARM_STATE, 2, ID2);
    Frames(1); /* frame 60: the burst sees body 7 stale and starts a rescan */
    FdfTestWeapon arm = Weapon(ARM_STATE);
    CHECK(arm.scanning && arm.job_ok && arm.kept == OWN_ARM);
    Put32(w.spray + 0x38, 0); /* the weapon leaves before the rescan is done */
    PIN(Frame(), 2, 0, 1, OWN_ARM); /* frame 61: the weapon scan (1) drops it, its last complete scan's span (1) */
    CHECK(fdf_test_tracked() == 0 && Weapon(ARM_STATE).group == 0xFFFFFFFFu);
    CHECK(BodiesAre(NO_BODIES, 2047));
}

/* The allocator hands out the weapon's group between bursts: the next weapon scan sees it, the bodies and the live
 * flame systems leave it at once, and the next burst moves to 2046. */
static void GroupHandedOutBetweenBursts(void)
{
    Options o = {0};
    ArmGrouped(&o);
    Put32(ARM_STATE, 3);
    Frames(2);
    CHECK(Weapon(ARM_STATE).group == 2047 && GroupOf(0) == 2047 && LayerOf(1) == FLAME_G);
    Allocate(2047);
    /* Once: the scan, the span and the allocator (as every 0.5 s), then the 21 bodies (a release) and the flame slot with
     * its live instance's 5 systems (the Lua: 96 reads + 2 loads, 2 writable_region, 26 writes). */
    PIN(ScanFrame(), 5 + 1 + 2 + 1 + 3 + 2 + 16 + 2, 0, 2, OWN_ARM + 5);
    CHECK(BodiesAre(NO_BODIES, 2047));
    for (uint32_t index = 1; index <= 5; index++) CHECK_EQ(LayerOf(index), 11);
    FdfTestWeapon arm = Weapon(ARM_STATE);
    CHECK(arm.group == 0 && !arm.marked);
    CHECK_LOG("[Flame Damage Fixed] Self-hit group 2047 is no longer this mod's alone (the game's group allocator handed it out): "
              "the Lumberer's hit-boxes and flames left it.");
    Put32(w.pm_lists + 24 * 5, 2);
    Fire(ARM_STATE, 1, ID2);
    Frames(1);
    CHECK(BodiesAre(ARM_BODIES, 2046));
    for (uint32_t index = 7; index <= 11; index++) CHECK_EQ(LayerOf(index), FLAME_2046);
    CHECK_EQ(Weapon(ARM_STATE).group, 2046);
}

/* Handed out while the weapon rests, found at the burst start itself: it moves to 2046 within that frame, and the
 * burst's flame systems join 2046. */
static void GroupHandedOutAtABurstStart(void)
{
    Options o = {0};
    o.instances = 2;
    ArmGrouped(&o);
    Put32(ARM_STATE, 0);
    Frames(2);
    Allocate(2047);
    Fire(ARM_STATE, 1, ID2);
    /* Once: the burst start (12), the 2047 check that fails, the release (21 stores), the flame slot and both live
     * instances, 2046's check after 2047's, the regrouping (21 stores) and the new instance's 5 systems (the Lua: 236
     * reads + 3 loads, 4 writable_region, 52 writes). */
    PIN(Frame(), 77, 0, 4, 2 * OWN_ARM + 10);
    CHECK(BodiesAre(ARM_BODIES, 2046));
    for (uint32_t index = 1; index <= 5; index++) CHECK_EQ(LayerOf(index), 11);
    for (uint32_t index = 7; index <= 11; index++) CHECK_EQ(LayerOf(index), FLAME_2046);
}

/* Another mod's body (a Charger hit-box) already carries 2047 when the arm's bodies are scanned: the first burst skips
 * 2047 (logged once) and the other body is never touched. */
static void OtherBodyCarriesTheTopGroup(void)
{
    Options o = {0};
    MakeAll(&o);
    SetBody(27, 108, 20 + (2047u << 21));
    Started();
    Frames(6);
    FdfTestWeapon arm = Weapon(ARM_STATE);
    CHECK((arm.foreign & 0x80u) && !(arm.foreign & 0x40u));
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 2046);
    CHECK(GroupOf(27) == 2047 && LayerOf(1) == FLAME_2046);
    CHECK_LOG("[Flame Damage Fixed] Self-hit group 2047 not used: other bodies carry it");
    Put32(ARM_STATE, 0);
    Put32(w.spray + 0x38, 0);
    (void)ScanFrame();
    CHECK(GroupOf(27) == 2047 && GroupOf(0) == 0); /* the release leaves the other body alone */
}

/* This mod's other weapon's bodies are not other bodies: the Flame Sentry grouped in 2047 before the arm's scan. */
static void OwnOtherWeaponIsNotForeign(void)
{
    Options o = {0};
    MakeAll(&o);
    Started();
    Frames(2); /* the Sentry is scanned; the arm's family is looked up next */
    Fire(SENTRY_STATE, 2, ID1);
    Frames(1);
    for (int i = 0; i < OWN_SENTRY; i++) CHECK_EQ(GroupOf((uint32_t)kSentryBodies[i]), 2047);
    Frames(4);
    FdfTestWeapon arm = Weapon(ARM_STATE);
    CHECK(arm.job_ok && !(arm.foreign & 0x80u));
    Put32(w.pm_lists + 24 * 5, 2);
    Fire(ARM_STATE, 2, ID2);
    Frames(1);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 2046);
    for (int i = 0; i < OWN_SENTRY; i++) CHECK_EQ(GroupOf((uint32_t)kSentryBodies[i]), 2047);
}

/* Other bodies start carrying the weapon's group after it was grouped: the next rescan (after a rebuilt hit-box) finds
 * them and the weapon leaves the group at once; the next burst moves to 2046. */
static void OtherBodiesJoinTheGroupLater(void)
{
    Options o = {0};
    ArmGrouped(&o);
    Put32(ARM_STATE, 0);
    Frames(2);
    SetBody(28, 108, 20 + (2047u << 21)); /* another mod's body joins 2047 */
    SetBody(7, 144, 0xC0000777u);         /* a rebuilt hit-box: rescan */
    Frames(40);
    FdfTestWeapon arm = Weapon(ARM_STATE);
    CHECK(arm.group == 0 && !arm.marked && GroupOf(28) == 2047);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 0);
    for (uint32_t index = 1; index <= 5; index++) CHECK_EQ(LayerOf(index), 11);
    CHECK_LOG("[Flame Damage Fixed] Self-hit group 2047 is no longer this mod's alone (other bodies carry it): the Lumberer's "
              "hit-boxes and flames left it.");
    Put32(w.pm_lists + 24 * 5, 2);
    Fire(ARM_STATE, 2, ID2);
    Frames(1);
    for (int i = 0; i < OWN_ARM; i++) CHECK_EQ(GroupOf((uint32_t)kArmBodies[i]), 2046);
    CHECK_EQ(GroupOf(28), 2047); /* the other body keeps its group */
}

/* No usable group left: the weapon keeps the game's own collision (logged once); nothing is written. */
static void NoUsableGroupLeft(void)
{
    Options o = {0};
    ArmGrouped(&o);
    Put32(ARM_STATE, 0);
    Frames(2);
    for (uint32_t g = 2040; g <= 2047; g++) Allocate(g);
    Frames(40);
    CHECK(BodiesAre(NO_BODIES, 2047));
    Put32(w.pm_lists + 24 * 5, 2);
    Fire(ARM_STATE, 2, ID2);
    Frames(1);
    CHECK(BodiesAre(NO_BODIES, 2047));
    for (uint32_t index = 7; index <= 11; index++) CHECK_EQ(LayerOf(index), 11); /* the flame keeps layer 11 */
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix skipped: no free Havok system group in 2040-2047");
}

/* Refusals: no free group, or an unknown filter, fall back to vanilla collision; the effect still fixes. */
static void RefusalsKeepVanillaCollision(void)
{
    static const uint32_t all[] = {2040, 2041, 2042, 2043, 2044, 2045, 2046, 2047};
    Options o = {0};
    o.used = all;
    o.used_n = 8;
    ArmGrouped(&o);
    CHECK(EffectFixed() && LayerOf(1) == 11);
    CHECK(BodiesAre(NO_BODIES, 2047));
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix skipped: no free Havok system group in 2040-2047");

    fake_setup();
    static const uint32_t changed[] = {0, 2, 20};
    Options r = {0};
    r.row = changed;
    r.row_n = 3;
    ArmGrouped(&r);
    CHECK(EffectFixed() && LayerOf(1) == 11);
    CHECK(BodiesAre(NO_BODIES, 2047));
    Put32(ARM_STATE, 0);
    Frames(2);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    CHECK_EQ(LogCount("Self-hit fix disabled for this session: flame layer row changed"), 1); /* logged once */
}

/* The effect refused: the self-hit fix goes on; each reason is logged once. */
static void EffectRefusalsKeepTheSelfHitFix(void)
{
    Options o = {0};
    MakeGame(1);
    MakePhysics(&o);
    Started();
    Frames(6);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    CHECK_LOG("[Flame Damage Fixed] Flame effect not fixed: flame effect not loaded");
    CHECK(BodiesAre(ARM_BODIES, 2047));
    CHECK_EQ(LayerOf(1), 11); /* no effect data: the burst instance is not identified as the flame's */

    fake_setup();
    MakeAll(&o);
    Put32(w.data + fdf_patches[2].offset, 0x04030201u);
    Started();
    Frames(6);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    Put32(ARM_STATE, 0);
    Frames(1);
    Fire(ARM_STATE, 2, ID2);
    Frames(1);
    CHECK_EQ(LogCount("[Flame Damage Fixed] Flame effect not fixed: unknown value at 328"), 1);
    CHECK(Get32(w.data + fdf_patches[0].offset) == fdf_patches[0].shipped && LayerOf(1) == FLAME_G);

    fake_setup();
    MakeAll(&o);
    Protect(w.data, FDF_EFFECT_SIZE, PAGE_READONLY);
    Started();
    Frames(6);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    Protect(w.data, FDF_EFFECT_SIZE, PAGE_READWRITE);
    CHECK_LOG("[Flame Damage Fixed] Flame effect not fixed: effect memory not writable private data");
    CHECK(EffectShipped() && BodiesAre(ARM_BODIES, 2047));
}

/* The weapon's family cannot be resolved: the self-hit fix is unavailable for it (logged once, tried again after 5 s);
 * the effect still fixes. */
static void FamilyRefusals(void)
{
    Options o = {0};
    MakeAll(&o);
    Put32(w.entities[1] + 12, H_ARM + 0x400000u); /* a handle the unit registry does not hold */
    Started();
    Frames(6);
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix unavailable: weapon unit not found");
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    CHECK(EffectFixed() && BodiesAre(NO_BODIES, 2047));
    Put32(ARM_STATE, 0);
    while (g_frames < 301) Frames(1);
    CHECK_EQ(Frame().reads, 2);     /* frame 302: the states only */
    CHECK_EQ(Frame().reads, 2 + 3); /* frame 303, 5 s after the first try: the family lookup again (refused at the unit) */
    CHECK_EQ(LogCount("weapon unit not found"), 1);

    fake_setup();
    MakeAll(&o);
    Put32(w.entities[1] + 12, H_CANNON); /* from the cannon, the same family */
    Started();
    Frames(6);
    CHECK_EQ(Weapon(ARM_STATE).kept, OWN_ARM);

    fake_setup();
    Options wrong = {0};
    wrong.wrong_world = 1;
    MakeAll(&wrong);
    Started();
    Frames(6);
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix unavailable: no physics world");

    fake_setup();
    MakeGame(0);
    Started();
    Frames(6);
    Fire(ARM_STATE, 2, ID1);
    Frames(1);
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix unavailable: unit registry unavailable");
    CHECK_LOG("[Flame Damage Fixed] Self-hit fix disabled for this session: collision filter unavailable");
    CHECK(EffectFixed());
}

/* A new mission reloads the effect: the next burst fixes it again. */
static void MissionReloadFixesAgain(void)
{
    Options o = {0};
    MakeAll(&o);
    Started();
    Frames(6);
    Put32(ARM_STATE, 2);
    Frames(1);
    Put32(ARM_STATE, 0);
    CHECK(EffectFixed());
    for (int i = 0; i < FDF_PATCH_COUNT; i++) Put32(w.data + fdf_patches[i].offset, fdf_patches[i].shipped); /* reloaded */
    Frames(100);
    Put32(ARM_STATE, 2);
    Frames(1);
    CHECK(EffectFixed());
    CHECK_EQ(LogCount("Flame effect fixed (18 words)."), 2); /* each fix is logged once */
}

/* The core stopping the component puts this mod's group stores back: the bodies leave the group, and the flame systems
 * of live instances still in it go back to layer 11 (the Lua's reset, run by its update guard's stop). */
static void StopRestoresTheGroupStores(void)
{
    Options o = {0};
    o.instances = 2;
    ArmGrouped(&o);
    Put32(ARM_STATE, 3);
    Frames(1);
    CHECK(BodiesAre(ARM_BODIES, 2047));
    for (uint32_t index = 1; index <= 5; index++) CHECK_EQ(LayerOf(index), FLAME_G);
    CostReset();
    vpm_core_stop(fake_component(0), "test");
    /* The flame slot (3), the bodies' span and 21 stores, both live instances and the 5 systems still in the group (the
     * Lua's pause frame: 116 reads + 1 load, 2 writable_region, 26 writes). Then the effect fix put back (new for live
     * switches: a switch-off mid-mission leaves the flame as the game has it): its lookup (6 reads) and check (1 read),
     * one page check and its 18 words. */
    PIN(CostNow(), 3 + 1 + 2 + 16 + 16 + 6 + 1, 1, 2, OWN_ARM + 5 + FDF_PATCH_COUNT);
    CHECK(EffectShipped());
    CHECK_LOG("Flame effect put back (18 words).");
    CHECK(BodiesAre(NO_BODIES, 2047));
    for (uint32_t index = 1; index <= 12; index++) CHECK_EQ(LayerOf(index), index == 6 || index == 12 ? 0x4Au : 11u);
    CHECK(!vpm_running(fake_component(0)));
    CostReset();
    Frames(60);
    PIN(CostNow(), 0, 0, 0, 0);

    /* A restore that cannot store says so. */
    fake_setup();
    ArmGrouped(&o);
    Protect(w.bodies, (size_t)w.records * BODY, PAGE_READONLY);
    vpm_core_stop(fake_component(0), "test");
    Protect(w.bodies, (size_t)w.records * BODY, PAGE_READWRITE);
    CHECK_LOG("[Flame Damage Fixed] Self-hit group not released: body memory not writable private data");
    CHECK_LOG("[Flame Damage Fixed] Self-hit group writes not restored: body memory not writable private data");
    CHECK_EQ(LayerOf(1), 11); /* the flames still went back */
}

static void LogsTheStart(void)
{
    Options o = {0};
    MakeAll(&o);
    Started();
    CHECK_LOG("[Flame Damage Fixed] Flame Damage Fixed v1.2 initialized (spawn fix, Cremator emitter distances, self-hit fix by "
              "Havok system group).");
    CHECK(vpm_ticking(fake_component(0)));
}

int main(void)
{
    RUN(PatchTableIsTheShippedLayout);
    RUN(EffectLookupCheckAndFix);
    RUN(CollisionFilterCheck);
    RUN(FamilyIsTheVehicleWithoutThePilot);
    RUN(BodyScanKeepsTheFamilysHittableBodies);
    RUN(FarBodiesAreSeparateSpans);
    RUN(GroupAllocator);
    RUN(GroupingTouchesOnlyOwnGroupFreeBodies);
    RUN(ScanKeepsBodiesOfTheWeaponsGroup);
    RUN(FlameInstancesByIdAndGrouping);
    RUN(LogsTheStart);
    RUN(DriverCallsPerFrame);
    RUN(IdleFramesCostNothing);
    RUN(RebuiltRegroupedAndDestroyed);
    RUN(ReleasedMidRescan);
    RUN(GroupHandedOutBetweenBursts);
    RUN(GroupHandedOutAtABurstStart);
    RUN(OtherBodyCarriesTheTopGroup);
    RUN(OwnOtherWeaponIsNotForeign);
    RUN(OtherBodiesJoinTheGroupLater);
    RUN(NoUsableGroupLeft);
    RUN(RefusalsKeepVanillaCollision);
    RUN(EffectRefusalsKeepTheSelfHitFix);
    RUN(FamilyRefusals);
    RUN(MissionReloadFixesAgain);
    RUN(StopRestoresTheGroupStores);
    TEST_END();
}
