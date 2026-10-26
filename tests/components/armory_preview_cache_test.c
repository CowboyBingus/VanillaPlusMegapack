/* Armory Preview Cache: the Lua tests' scenarios (components/ArmoryPreviewCache/tests/test_*.lua) on the fake game.
 *
 * The world: a synthetic Armory (the Lua tests replayed a capture of build 25327279's UI; this builds the same shapes):
 * the thumbnail manager with two cards (12 visible tiles in card 0, 6 offscreen requests in card 1), the Armory
 * controller's grid (records, 3 rows of 4 widgets), the UI, state stack and dispatch, the package lease table, the kit
 * catalogue the requests resolve through, the preview queue and the dependency catalogue. The game.dll functions are the
 * harness's stand-ins (fake_stand_in: the code checks see the shipped bytes); the exe's get jump stubs once the
 * component has checked their bytes on the ship. As the Lua tests' test_calls: the lease functions change the fake lease
 * table, the engine's texture calls are recorded. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "harness/test.h"
#include "components.h"
#include "components/armory_preview_cache/apc.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_armory_preview_cache};

#define ITEMS 18          /* card 0: 12 visible tiles; card 1: 6 offscreen requests */
#define VISIBLE 12
#define GRID 523752u      /* the Armory grid in its controller */
#define META 597772u      /* the grid's block */
#define CONTROL 280216u   /* the pre-select control */
#define DT (1.0f / 60)

typedef struct World
{
    uint8_t *manager, *atlas, *sm, *ui, *world, *dispatch, *owner, *lease, *preview, *app;
    uint8_t *kits, *kitPointers, *presets, *database, *weapons, *definitions, *groupHeader, *mapRows;
    uint64_t free;
    int memory_fails;
} World;
static World w;

typedef struct Engine
{
    int acquires, releases, creates, destroys, registers, textures, uvs, sizes, alphas, materials, images;
    int unbalanced, refuse_create;
    uint8_t* created[32];
    uintptr_t destroyed[32];
    int created_count, destroyed_count;
    uintptr_t element[256], texture[256];
    int element_count;
    int polls;
} Engine;
static Engine e;

static void Put32(void* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(void* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutF(void* at, float v) { memcpy(at, &v, 4); }
static uint32_t Get32(const void* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t Get64(const void* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static uint64_t P(const void* p) { return (uint64_t)(uintptr_t)p; }
static uint8_t* Game(uint32_t rva) { return (uint8_t*)fake_game() + rva; }
static uint8_t* Exe(uint32_t rva) { return (uint8_t*)fake_exe() + rva; }

/* ---- the reviewed code bytes (the component's signature lists) --------------------------------------------------- */

typedef struct Sig { int exe; uint32_t rva; const char* hex; } Sig;
static const Sig kSigs[] = {
    {0, 0x12FE350u, "45 85 C0 0F 84 75 01 00 00 41 56 41 57 48 83 EC 38"},
    {0, 0x12FE361u, "48 89 5C 24 50 4C 8B FA 48 89 6C 24 58 4C 8B F1 48 89 74 24 60 48 89 7C 24 30 4C 89 64 24 28 4C"
        " 8D 25 B9 24 4D 02 4C 89 6C 24 20 4C 8D 2D 89 25 4D 02 41 8B E8 66 66 0F 1F 84 00 00 00 00 00 41"
        " 8B 56 08 33 C0 49 8B 37 45 8B 46 18 4C 0F AF C6 44 8D 4A FF 85 D2 74 59 49 8B 0E 0F 1F 40 00 8B"
        " D8 49 03 D8 49 23 D9 48 C1 E3 04 48 03 D9 48 39 33 0F 84 F7 00 00 00 FF C0 3B C2 72 E2 4D 8B 5E"
        " 10 4C 8B D1 33 C0 66 0F 1F 84 00 00 00 00 00 8B D8 49 03 D8 49 23 D9 48 C1 E3 04 49 03 DA 48 8B"
        " 0B 49 3B CB 74 0D 48 3B CE 74 08 FF C0 3B C2 72 DE 33 DB 48 89 33 48 C7 43 08 01 00 00 00 48 8B"
        " 15 CA DE 01 02 4C 8D 05 B3 8B 00 01 48 8B 7B 08 49 8B CC 4C 8B CE 48 8D 42 16 49 3B C5 48 0F 42"
        " CA BA 16 00 00 00 48 89 0D A2 DE 01 02 E8 CD F4 1E FF 4C 8B 05 96 DE 01 02 48 8D 0D B7 1B FC 00"
        " FF C0 4C 8B CF 48 63 D0 49 03 D0 48 89 15 7D DE 01 02 48 8D 15 F6 3F FC 00 E8 81 9E 43 00 48 83"
        " 7B 08 01 75 14 48 8B 05 7B 7E 02 02 48 8B CE 48 8B 50 10 FF 92 F0 02 00 00 49 83 C7 08 48 83 ED"
        " 01 0F 85 F8 FE FF FF 4C 8B 6C 24 20 4C 8B 64 24 28 48 8B 7C 24 30 48 8B 74 24 60 48 8B 6C 24 58"
        " 48 8B 5C 24 50 48 83 C4 38 41 5F 41 5E"},
    {0, 0x12FE4CEu, "C3"},
    {0, 0x12FE4CFu, "48 FF 43 08 E9 47 FF FF FF"},
    {0, 0x12FE4E0u, "45 85 C0 0F 84 60 01 00 00 41 56 41 57 48 83 EC 38"},
    {0, 0x12FE4F1u, "48 89 5C 24 50 4C 8B FA 48 89 6C 24 58 4C 8B F1 48 89 74 24 60 4C 89 64 24 28 4C 8D 25 2E 23 4D"
        " 02 4C 89 6C 24 20 4C 8D 2D FE 23 4D 02 48 89 7C 24 30 41 8B E8 66 66 0F 1F 84 00 00 00 00 00 49"
        " 8B 37 48 85 F6 0F 84 D9 00 00 00 41 8B 4E 08 33 C0 41 8B 56 18 48 0F AF D6 44 8D 49 FF 85 C9 0F"
        " 84 BF 00 00 00 4D 8B 06 0F 1F 80 00 00 00 00 8B D8 48 03 DA 49 23 D9 48 C1 E3 04 49 03 D8 48 39"
        " 33 74 0B FF C0 3B C1 72 E6 E9 96 00 00 00 48 8B 7B 08 48 85 FF 0F 84 89 00 00 00 48 8B 15 5D DD"
        " 01 02 4C 8D 05 46 8A 00 01 48 FF CF 49 8B CC 4C 8B CE 48 89 7B 08 48 8D 42 16 49 3B C5 48 0F 42"
        " CA BA 16 00 00 00 48 89 0D 32 DD 01 02 E8 5D F3 1E FF 4C 8B 05 26 DD 01 02 48 8D 0D 47 1A FC 00"
        " FF C0 4C 8B CF 48 63 D0 49 03 D0 48 89 15 0D DD 01 02 48 8D 15 16 3F FC 00 E8 11 9D 43 00 48 83"
        " 7B 08 00 75 1F 48 8B D6 49 8B CE E8 9F 17 43 00 48 8B 05 00 7D 02 02 48 8B CE 48 8B 50 10 FF 92"
        " 00 03 00 00 49 83 C7 08 48 83 ED 01 0F 85 0D FF FF FF 4C 8B 6C 24 20 4C 8B 64 24 28 48 8B 7C 24"
        " 30 48 8B 74 24 60 48 8B 6C 24 58 48 8B 5C 24 50 48 83 C4 38 41 5F 41 5E"},
    {0, 0x12FE649u, "C3"},
    {0, 0x14499E0u, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 49 8B D8 8B FA 48 8B F1 E8 E4 5C 00 00 48 8B D0 E8"},
    {0, 0x143EEF0u, "4C 89 44 24 18 48 89 54 24 10 48 83 EC 28 F3 0F 10 81 14 01 00 00 0F 2E 44 24 38 7A 35 75 33 F3"},
    {0, 0x1447160u, "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3 0F 10 41 0C 48 8B DA 0F"},
    {0, 0x1448AD0u, "40 57 48 83 EC 20 F3 0F 10 41 44 48 8B F9 0F 2E C1 7A 23 75 21 F7 01 00 00 00 08 0F 84 77 01 00"},
    {0, 0x144F800u, "48 89 5C 24 08 57 48 83 EC 20 41 0F B6 F8 48 8B D9 48 85 D2 75 0F 48 8B 5C 24 30 48 83 C4 20 5F"},
    {0, 0x1392680u, "40 53 48 83 EC 20 45 33 C9 48 8B DA 48 8B 15 ED A6 0E 02 41 8B C9 44 8B 82 80 2B 00 00 45 85 C0"},
    {1, 0x31AF50u, "48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 40 48 8B 05 9E 52 6F 01 45 8B F9 41 8B F0"},
    {1, 0x31B360u, "48 89 5C 24 08 57 48 83 EC 20 48 8B 1D 97 4E 6F 01 48 8B F9 48 8B 83 38 03 00 00 80 B8 80 14 00"},
    {1, 0x31E030u, "4C 8B C2 8B D1 48 8B 0D CC 21 6F 01 48 8B 89 38 03 00 00 E9 48 B0 DE FF CC CC CC CC CC CC CC CC"},
};

/* An IDA-style pattern's bytes into the image. */
static void PutHex(uint8_t* at, const char* hex)
{
    for (const char* p = hex; *p != 0;)
    {
        if (*p == ' ') { p++; continue; }
        char b[3] = {p[0], p[1], 0};
        *at++ = (uint8_t)strtoul(b, NULL, 16);
        p += 2;
    }
}

/* The pattern the component checks at a game.dll function. */
static const char* Shipped(uint32_t rva)
{
    for (size_t i = 0; i < sizeof kSigs / sizeof kSigs[0]; i++)
        if (!kSigs[i].exe && kSigs[i].rva == rva) return kSigs[i].hex;
    return "";
}

/* ---- the stand-ins for the game's and the engine's functions ------------------------------------------------------- */

static uint32_t* LeaseRows(void) { return (uint32_t*)(w.lease + 32); }

static int LeaseFind(uint64_t id)
{
    uint32_t* rows = LeaseRows();
    for (int i = 0; i < 1024; i++)
        if (((uint64_t)rows[i * 4 + 1] << 32 | rows[i * 4]) == id) return i;
    return -1;
}

static void LeasePut(int i, uint64_t id, uint32_t count)
{
    uint32_t* rows = LeaseRows();
    rows[i * 4] = (uint32_t)id;
    rows[i * 4 + 1] = (uint32_t)(id >> 32);
    rows[i * 4 + 2] = count;
    rows[i * 4 + 3] = 0;
}

static uint32_t LeaseCount(uint64_t id)
{
    int i = LeaseFind(id);
    return i < 0 ? 0 : LeaseRows()[i * 4 + 2];
}

static int LeaseRowCount(void)
{
    int n = 0;
    for (int i = 0; i < 1024; i++) n += LeaseRows()[i * 4] != 0 || LeaseRows()[i * 4 + 1] != 0;
    return n;
}

static void FakeAcquire(void* system, const uint64_t* ids, uint32_t count)
{
    e.acquires++;
    if (e.unbalanced || system != (void*)w.lease) return;
    int i = LeaseFind(ids[0]);
    if (i >= 0) { LeaseRows()[i * 4 + 2]++; return; }
    i = LeaseFind(0);
    if (i >= 0) LeasePut(i, ids[0], 1);
}

static void FakeRelease(void* system, const uint64_t* ids, uint32_t count)
{
    e.releases++;
    if (e.unbalanced || system != (void*)w.lease) return;
    int i = LeaseFind(ids[0]);
    if (i < 0) return;
    if (--LeaseRows()[i * 4 + 2] == 0) LeasePut(i, 0, 0);
}

static void* FakeCreate(int width, int height, int a, int b, uint32_t name, uint8_t flag)
{
    e.creates++;
    if (e.refuse_create || e.created_count >= 32) return NULL;
    uint8_t* d = fake_heap(104);
    memcpy(d, w.atlas, 104);
    Put64(d, 0x7000 + (uint64_t)e.created_count);
    e.created[e.created_count++] = d;
    return d;
}

static void FakeDestroy(void* texture)
{
    e.destroys++;
    if (e.destroyed_count < 32) e.destroyed[e.destroyed_count++] = (uintptr_t)texture;
}

static void FakeRegister(uint32_t name, void* texture) { e.registers++; }

static void FakeSetTexture(void* element, uint32_t slot, void* texture)
{
    e.textures++;
    for (int i = 0; i < e.element_count; i++)
        if (e.element[i] == (uintptr_t)element) { e.texture[i] = (uintptr_t)texture; return; }
    if (e.element_count < 256)
    {
        e.element[e.element_count] = (uintptr_t)element;
        e.texture[e.element_count++] = (uintptr_t)texture;
    }
}

static void FakeSetUv(void* element, uint64_t low, uint64_t high) { e.uvs++; }
static void FakeSetSize(void* element, uint64_t size) { e.sizes++; }
static void FakeSetAlpha(void* element, float alpha) { e.alphas++; }

static void FakeMaterial(void* element, uint64_t material, uint8_t flag)
{
    e.materials++;
    Put64((uint8_t*)element + 328, 0x600000000000ull + ((uint64_t)(uintptr_t)element & 0xFFFFFFF));
    Put64((uint8_t*)element + 336, 0);
}

static void FakeRegisterImage(void* manager, void* element)
{
    e.images++;
    uint8_t* m = manager;
    uint32_t n = Get32(m + APC_AT_REGISTRY);
    for (uint32_t i = 0; i < n; i++)
        if (Get64(m + 11144 + i * 8) == P(element)) return;
    Put64(m + 11144 + n * 8, P(element));
    Put32(m + APC_AT_REGISTRY, n + 1);
}

static uintptr_t Shown(const void* element)
{
    for (int i = 0; i < e.element_count; i++)
        if (e.element[i] == (uintptr_t)element) return e.texture[i];
    return 0;
}

static int FakeMemory(uint64_t* free, uint64_t* commit)
{
    e.polls++;
    if (w.memory_fails) return 0;
    *free = w.free;
    *commit = 16ull << 30;
    return 1;
}

/* mov rax, target; jmp rax: the fake image's code at a native entry point, once the component has checked its bytes. */
static void Stub(uint8_t* at, void* target)
{
    DWORD old;
    uint8_t code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
    uint64_t t = (uint64_t)(uintptr_t)target;
    memcpy(code + 2, &t, 8);
    VirtualProtect(at, sizeof code, PAGE_EXECUTE_READWRITE, &old); /* lint-ok: C1,C3 the test makes the fake game code executable */
    memcpy(at, code, sizeof code);
}

/* game.dll's functions: the harness's stand-ins (code_matches sees the shipped bytes), in place from the start. */
static void StandIns(void)
{
    static const struct { uint32_t rva; void* fn; } kGame[] = {
        {APC_RVA_ACQUIRE, (void*)FakeAcquire}, {APC_RVA_RELEASE, (void*)FakeRelease},
        {APC_RVA_SET_TEXTURE, (void*)FakeSetTexture}, {APC_RVA_SET_UV, (void*)FakeSetUv},
        {APC_RVA_SET_SIZE, (void*)FakeSetSize}, {APC_RVA_SET_ALPHA, (void*)FakeSetAlpha},
        {APC_RVA_MATERIAL, (void*)FakeMaterial}, {APC_RVA_REGISTER_IMAGE, (void*)FakeRegisterImage},
    };
    for (size_t i = 0; i < sizeof kGame / sizeof kGame[0]; i++) fake_stand_in(kGame[i].rva, Shipped(kGame[i].rva), kGame[i].fn);
}

/* The exe's functions: the harness has no stand-in for them, so their jumps go in once the component has checked the
 * bytes (its first tick). */
static void ExeStubs(void)
{
    Stub(Exe(APC_EXE_CREATE), (void*)FakeCreate);
    Stub(Exe(APC_EXE_DESTROY), (void*)FakeDestroy);
    Stub(Exe(APC_EXE_REGISTER), (void*)FakeRegister);
}

/* ---- the world ------------------------------------------------------------------------------------------------- */

static uint64_t ItemId(int k) { return 0x1000u + (uint64_t)k; }
static uint64_t Package(int k) { return 0xA000000000000000ull + (uint64_t)k; }
static uint8_t* ItemAt(int card, int slot) { return w.manager + card * 1816 + 32 + slot * 120; }
static uint8_t* Record(int k) { return w.owner + GRID + META + 4332 + k * 80; }
static uint8_t* WidgetAt(int index) { return w.owner + GRID + 2816 + (index / 4) * 44752 + 9192 + (index % 4) * 11112; }
static uint8_t* Element(int index) { return WidgetAt(index) + 272; }
static uint8_t* Atlas(void) { return (uint8_t*)(uintptr_t)Get64(w.manager + APC_AT_ATLAS); }

static void Card(int c, uint32_t state, uint32_t count)
{
    Put32(w.manager + c * 1816 + 1832, state);
    Put32(w.manager + c * 1816 + 1836, count);
}

static void Active(uint32_t card, uint32_t phase)
{
    Put32(w.manager + 11064, card);
    Put32(w.manager + 11096, phase);
}

static void Top(uint32_t top, uint32_t depth)
{
    Put32(w.sm + 0x429C, top);
    Put32(w.sm + 0x429C + 20, depth);
}

/* Request k of the category: its identity (+24 id, +32), crop rectangle (+56) and kind (armor, 3). */
static void PutItem(int k, uint32_t generation)
{
    int card = k / VISIBLE, slot = k % VISIBLE;
    uint8_t* item = ItemAt(card, slot);
    Put64(item + 24, ItemId(k) + ((uint64_t)generation << 20));
    Put64(item + 32, 0x100u + (uint64_t)k);
    PutF(item + 56, (float)(slot % 4) * 0.25f);
    PutF(item + 60, (float)(slot / 4) * 0.25f);
    PutF(item + 64, 0.25f);
    PutF(item + 68, 0.25f);
    Put32(item + 100, 3);
    uint8_t* rec = Record(k);
    Put64(rec, 0x5600u + (uint64_t)k + ((uint64_t)generation << 20));
    Put32(rec + 8, 3);
    Put32(rec + 60, (uint32_t)card);
    Put32(rec + 64, (uint32_t)slot);
    rec[68] = 0;
    Put32(rec + 72, 1);
}

static void PutWidget(uint8_t* widget, const uint8_t* record)
{
    PutF(widget + 12, 172);
    PutF(widget + 16, 172);
    PutF(widget + 28, 1);
    PutF(widget + 32, 1);
    PutF(widget + 340, 1);
    Put32(widget + 272, 0xC0000);
    Put64(widget + 600, 0x500000000000ull + P(widget) % 0x1000000); /* a private material instance */
    Put64(widget + 608, 0);
    Put64(widget + 1984, P(record));
    Put32(widget + 2000, 1);
    widget[2005] = 1;
}

/* A category of ITEMS requests, every card complete; generation makes another category. */
static void Category(uint32_t generation, uint32_t state)
{
    for (int k = 0; k < ITEMS; k++) PutItem(k, generation);
    Card(0, state, VISIBLE);
    Card(1, state, ITEMS - VISIBLE);
}

static void BuildManager(void)
{
    w.manager = fake_heap(APC_MANAGER_SIZE);
    w.atlas = fake_heap(104);
    Put64(w.atlas, 0x4000);
    Put32(w.atlas + 20, 1024);
    Put32(w.atlas + 24, 1024);
    Put32(w.atlas + 28, 1);
    Put32(w.atlas + 32, 1);
    w.atlas[99] = 1;
    Put32(w.manager + 16, 0x11);
    PutF(w.manager + 24, 256);
    PutF(w.manager + 28, 256);
    Put32(w.manager + 11052, 7);
    Active(0xFFFFFFFFu, 0);
    Put64(w.manager + 11100, 0x22);
    Put64(w.manager + APC_AT_ATLAS, P(w.atlas));
    Put32(w.manager + APC_AT_REGISTRY, VISIBLE);
    for (int i = 0; i < VISIBLE; i++) Put64(w.manager + 11144 + i * 8, P(Element(i)));
    Category(0, 8);
}

static void BuildGrid(void)
{
    w.owner = fake_heap(GRID + META + 24892 + 64);
    uint8_t* meta = w.owner + GRID + META;
    Put32(meta, 3);                          /* three rows of four */
    Put32(meta + 4280, 1);                   /* the grid kind */
    for (int i = 0; i < 6; i++) Put32(meta + (6205 + i * 3) * 4, i < 2 ? (uint32_t)i : 6u);
    for (int row = 0; row < 3; row++) Put32(w.owner + GRID + 2816 + row * 44752 + 44724, 4);
    for (int i = 0; i < VISIBLE; i++) PutWidget(WidgetAt(i), Record(i));
    w.owner[CONTROL + 37968 + 4] = 1;        /* no pre-select shown */
}

static void BuildUi(void)
{
    w.sm = fake_heap(0x429C + 24);
    w.ui = fake_heap(15432 + 464);
    w.world = fake_heap(64);
    w.dispatch = fake_heap(5744 + 64 * 16);
    w.preview = fake_heap(50456 + 128 * 200);
    Put64(w.ui + 15432, P(w.world));
    Put32(w.dispatch + 5740, 1);
    Put64(w.dispatch + 5744, P(w.owner));
    Put32(w.dispatch + 5744 + 8, 224);
    Top(3, 1);
}

static void BuildLeases(void)
{
    w.lease = fake_heap(16432);
    Put64(w.lease, P(w.lease + 32));
    Put32(w.lease + 8, 1024);
    Put32(w.lease + 24, 2);
    Put64(w.lease + 16416, 0x7F0000001000ull);
}

/* The kit catalogue: preset (the request id) -> kit index -> package; the weapon table; the attachment catalogue. */
static void BuildCatalogue(void)
{
    w.kits = fake_heap(16);
    w.kitPointers = fake_heap(64 * 8);
    w.presets = fake_heap(761060 + 64 * 24);
    w.database = fake_heap(0xF12E18);
    w.weapons = fake_heap(1080 * 16 + 540 * 32);
    w.definitions = fake_heap(10368 + 46600);
    w.groupHeader = fake_heap(16);
    w.mapRows = fake_heap(16 * 16);
    Put64(w.kits, P(w.kitPointers));
    Put32(w.kits + 8, ITEMS);
    for (int k = 0; k < ITEMS; k++)
    {
        uint8_t* row = fake_heap(48);
        Put32(row, (uint32_t)k);
        Put64(row + 32, Package(k));
        Put64(w.kitPointers + k * 8, P(row));
        Put32(w.presets + 761060 + k * 24 + 4, (uint32_t)ItemId(k));
        Put32(w.presets + 761060 + k * 24 + 8, (uint32_t)k);
    }
    Put32(w.presets + 7392, ITEMS);
    Put64(w.database + 0xF12558, P(w.weapons));
    Put64(w.database + 0xF12E10, P(w.definitions));
    Put32(Game(APC_RVA_GROUP_COUNT), 1);
    Put64(Game(APC_RVA_GROUPS), P(w.groupHeader));
    Put64(Game(APC_RVA_PACKAGE_MAP), P(w.mapRows));
    Put32(Game(APC_RVA_PACKAGE_MAP) + 8, 16);
    Put64(Game(APC_RVA_PACKAGE_MAP) + 16, 0xFFFFFFFFFFFFFFFFull);
    Put32(Game(APC_RVA_PACKAGE_MAP) + 24, 1);
}

static void BuildApi(void)
{
    w.app = fake_heap(1024);
    Put64(Game(APC_RVA_ROOT_API), P(Exe(APC_EXE_ROOT_API)));
    Put64(Exe(APC_EXE_ROOT_API) + 16, P(w.app));
    Put64(w.app + 368, P(Exe(APC_EXE_CREATE)));
    Put64(w.app + 400, P(Exe(APC_EXE_DESTROY)));
    Put64(w.app + 528, P(Exe(APC_EXE_REGISTER)));
    Put64(w.app + 752, P(Exe(APC_EXE_PACKAGE_A)));
    Put64(w.app + 768, P(Exe(APC_EXE_PACKAGE_B)));
    Put32(Exe(APC_EXE_FORMAT_SIZE), 32);
    for (size_t i = 0; i < sizeof kSigs / sizeof kSigs[0]; i++) PutHex(kSigs[i].exe ? Exe(kSigs[i].rva) : Game(kSigs[i].rva), kSigs[i].hex);
    StandIns();
}

static void BuildGlobals(void)
{
    Put64(Game(APC_RVA_GLOBALS), P(w.manager));
    Put64(Game(APC_RVA_UI), P(w.ui));
    Put64(Game(APC_RVA_STATE_MACHINE), P(w.sm));
    Put64(Game(APC_RVA_PREVIEW), P(w.preview));
    Put64(Game(APC_RVA_PACKAGES), P(w.lease));
    Put64(Game(APC_RVA_DISPATCH), P(w.dispatch));
    Put64(Game(APC_RVA_KITS), P(w.kits));
    Put64(Game(APC_RVA_PRESETS), P(w.presets));
    Put64(Game(APC_RVA_DATABASE), P(w.database));
}

/* The profile folder: LOCALAPPDATA points the component at a folder of the test's own. */
static wchar_t g_local[MAX_PATH];

static void ProfileFile(wchar_t* out, const wchar_t* suffix)
{
    _snwprintf(out, MAX_PATH, L"%ls\\CowboyBingus\\VanillaPlusMegapack\\armory_preview_cache\\ArmoryPreviewCache.profile%ls", g_local, suffix);
}

static void ForgetProfile(void)
{
    wchar_t path[MAX_PATH];
    const wchar_t* const suffixes[] = {L"", L".bak", L".tmp"};
    for (int i = 0; i < 3; i++)
    {
        ProfileFile(path, suffixes[i]);
        (void)DeleteFileW(path);
    }
}

static size_t ReadProfileFile(const wchar_t* suffix, char* text, size_t size)
{
    wchar_t path[MAX_PATH];
    ProfileFile(path, suffix);
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD got = 0;
    BOOL ok = ReadFile(file, text, (DWORD)size - 1, &got, NULL);
    CloseHandle(file);
    text[ok ? got : 0] = 0;
    return ok ? got : 0;
}

static void WriteProfileFile(const wchar_t* suffix, const char* text)
{
    wchar_t path[MAX_PATH], folder[MAX_PATH];
    _snwprintf(folder, MAX_PATH, L"%ls\\CowboyBingus", g_local);
    (void)CreateDirectoryW(folder, NULL);
    _snwprintf(folder, MAX_PATH, L"%ls\\CowboyBingus\\VanillaPlusMegapack", g_local);
    (void)CreateDirectoryW(folder, NULL);
    _snwprintf(folder, MAX_PATH, L"%ls\\CowboyBingus\\VanillaPlusMegapack\\armory_preview_cache", g_local);
    (void)CreateDirectoryW(folder, NULL);
    ProfileFile(path, suffix);
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD wrote = 0;
    if (file == INVALID_HANDLE_VALUE) return;
    (void)WriteFile(file, text, (DWORD)strlen(text), &wrote, NULL);
    CloseHandle(file);
}

static void WriteSettings(const char* text)
{
    HANDLE file = CreateFileW(L"vpm-test-settings.ini", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD wrote = 0;
    if (file == INVALID_HANDLE_VALUE) return;
    (void)WriteFile(file, text, (DWORD)strlen(text), &wrote, NULL);
    CloseHandle(file);
}

static void BuildWorld(void)
{
    memset(&w, 0, sizeof w);
    memset(&e, 0, sizeof e);
    w.free = 8ull << 30;
    BuildGrid();
    BuildManager();
    BuildUi();
    BuildLeases();
    BuildCatalogue();
    BuildApi();
    BuildGlobals();
    apc_set_memory_source(FakeMemory);
}

static VpmComponent* C(void) { return fake_component(0); }

/* The component started on the ship; its first tick initializes (the code bytes checked), then the exe's stubs go in. */
static void Boot(void)
{
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_frames(2, DT);
    ExeStubs();
}

static void Frames(int n) { fake_frames(n, DT); }

/* One frame's API calls, after the counts were reset. */
static FakeCounts Frame(void)
{
    fake_counts_reset();
    e.polls = 0;
    Frames(1);
    return fake_counts();
}

/* ---- start-up --------------------------------------------------------------------------------------------------- */

/* On the ship nothing is held: every frame after the first steps is idle, 1 read (the state stack; the Lua: 2), no
 * memory poll, no log. The first save writes the profile (empty). */
static void IdlesOnTheShip(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    CHECK(vpm_running(C()));
    CHECK_LOG("[Armory Preview Cache] running: package leases (prewarm on) and rendered-image retention on; 0 learned items");
    Frames(12);
    CHECK_EQ(strcmp(vpm_status(C()), "outside_ship_ui"), 0);
    char text[256];
    CHECK(ReadProfileFile(L"", text, sizeof text) > 0);
    CHECK_EQ(strcmp(text, "ArmoryPreviewCache2 25480438\n"), 0);
    for (int i = 0; i < 240; i++)
    {
        FakeCounts c = Frame();
        CHECK_EQ(c.read, 1);
        CHECK_EQ(c.log + c.write + c.code_matches + e.polls, 0);
    }
    /* In a mission: the same. */
    Top(20, 2);
    Frames(12);
    for (int i = 0; i < 60; i++)
    {
        FakeCounts c = Frame();
        CHECK_EQ(c.read, 1);
        CHECK_EQ(e.polls, 0);
    }
    CHECK_EQ(e.acquires + e.creates + e.textures, 0);
}

/* The tick can start before the game sets up its engine API: no reads while waiting, the checks once it is there. */
static void WaitsForTheEngineApi(void)
{
    BuildWorld();
    Put64(Game(APC_RVA_ROOT_API), 0);
    fake_start(kDefs, 1);
    fake_counts_reset();
    Frames(100);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches, 0);
    CHECK_NO_LOG("running:");
    Put64(Game(APC_RVA_ROOT_API), P(Exe(APC_EXE_ROOT_API)));
    Frames(1);
    CHECK_LOG("running:");
    CHECK(vpm_running(C()));
    fake_setup();
    BuildWorld();
    Put64(Game(APC_RVA_ROOT_API), 0);
    fake_start(kDefs, 1);
    fake_frames(36100, DT);
    CHECK(!vpm_running(C()));
    CHECK_LOG("gave up after 600 s: the engine API is not set up yet");
}

/* Anything not as reviewed: the component stays off, as the Lua's first update stopped it. */
static void RefusesWhatIsNotAsReviewed(void)
{
    static const char* const texts[] = {
        "disabled: Native instruction mismatch",
        "disabled: Image instruction mismatch",
        "disabled: Unexpected script API",
        "disabled: Unexpected package API",
        "disabled: Image application API mismatch",
        "disabled: Unexpected texture format size",
    };
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        BuildWorld();
        if (c == 0) Game(0x12FE361u + 300)[0] ^= 1; /* past the first 256 bytes: the long signature is checked whole */
        if (c == 1) Exe(0x31E030u)[3] ^= 1;
        if (c == 2) Put64(Game(APC_RVA_ROOT_API), P(Exe(APC_EXE_ROOT_API)) + 8);
        if (c == 3) Put64(w.app + 768, P(Exe(APC_EXE_PACKAGE_A)));
        if (c == 4) Put64(w.app + 400, P(Exe(APC_EXE_CREATE)));
        if (c == 5) Put32(Exe(APC_EXE_FORMAT_SIZE), 16);
        fake_start(kDefs, 1);
        Frames(3);
        CHECK(!vpm_running(C()));
        CHECK_LOG(texts[c]);
    }
}

/* With images off (the settings file): no image signature checks, no image work; leases still. */
static void ImagesOffLeasesOnly(void)
{
    BuildWorld();
    WriteSettings("[armory_preview_cache]\nimages = 0\n");
    Exe(0x31E030u)[3] ^= 1; /* an image function's bytes: not checked with images off */
    Boot();
    CHECK(vpm_running(C()));
    CHECK_LOG("rendered-image retention off");
    Top(5, 1);
    Frames(60);
    CHECK_EQ(e.creates + e.textures, 0);
    CHECK_EQ(LeaseCount(Package(0)), 1);
    CHECK_EQ(LeaseCount(Package(ITEMS - 1)), 1);
}

/* ---- the Armory --------------------------------------------------------------------------------------------------- */

static int Bound(uintptr_t texture)
{
    int n = 0;
    for (int i = 0; i < VISIBLE; i++) n += Shown(Element(i)) == texture;
    return n;
}

/* A first visit, every card complete: the whole request is retained in the tick that sees it (a fresh atlas from the
 * engine, the completed one kept and shown on every tile), and the requests' packages are leased, at most 4 per step. */
static void FirstVisitRetainsAndLeases(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(1);
    CHECK_EQ(e.creates, 1);
    CHECK_EQ(e.registers, 1);
    CHECK(Atlas() == e.created[0]);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);     /* the retained original on every tile */
    CHECK_EQ(Bound(P(e.created[0])), 0);
    CHECK_EQ(e.uvs, VISIBLE);
    CHECK_EQ(e.sizes, VISIBLE);
    CHECK_EQ(e.alphas, 2 * VISIBLE);
    CHECK_EQ(e.destroys, 0);
    CHECK_EQ(apc_images_stats()->retained, 1);
    CHECK_EQ(apc_images_stats()->idle_retained, 1);
    CHECK_EQ(apc_images_stats()->last_hits, VISIBLE);
    /* 4 leases per 50 ms step: 18 packages in 5 steps. */
    Frames(2);
    CHECK_EQ(LeaseRowCount(), 4);
    Frames(30);
    CHECK_EQ(LeaseRowCount(), ITEMS);
    for (int k = 0; k < ITEMS; k++) CHECK_EQ(LeaseCount(Package(k)), 1);
    CHECK_EQ(strcmp(vpm_status(C()), "resident"), 0);
    /* Nothing changes: 17 reads per frame (the binding check's refresh, the tick's refresh, the shown texture's
     * ownership; the Lua: 21), and every 50 ms the lease table owner (2) and a memory poll. */
    int policy = 0;
    for (int i = 0; i < 30; i++)
    {
        FakeCounts c = Frame();
        CHECK(c.read == 17 || (c.read == 19 && e.polls == 1));
        policy += c.read == 19;
        CHECK_EQ(c.log + c.write, 0);
    }
    CHECK_EQ(policy, 10);
    CHECK_EQ(apc_images_stats()->gated_ticks >= 30, 1);
    CHECK_EQ(apc_images_stats()->retained, 1);
    CHECK_EQ(e.creates, 1);
    /* A step that cannot reuse its snapshot (the busy flag changed; the image tick stays gated): the asset snapshot (13:
     * the lease table's owner 2, the stack, the UI world and busy flag, the manager, the catalogue key 4, the dependency
     * identity 2, the preview ring) and the valid-lease check (3). */
    for (int i = 0; i < 3 && Frame().read != 19; i++) {}
    Put32(w.ui + 15892, 1);
    Frames(2);
    CHECK_EQ(Frame().read, 17 + 2 + 13 + 3);
    CHECK_EQ(strcmp(vpm_status(C()), "thumbnail_ui_busy"), 0);
}

static void Visit(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(60);
}

/* Leaving: the leases are released (the table as it was), the profile saved once the menu closed (5 s after the last
 * save, the first one at start-up: until then every frame works, as in the Lua), and the frames idle again with the
 * images held: a working frame for the memory poll every 2 s. */
static void LeavingReleasesAndSaves(void)
{
    static char text[8192];
    Visit();
    CHECK_EQ(LeaseRowCount(), ITEMS);
    Top(3, 1);
    Frames(6);
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK_EQ(e.releases, ITEMS);
    CHECK_EQ(strcmp(vpm_status(C()), "outside_ship_ui"), 0);
    CHECK_LOG("menu closed: leases 18 taken, 18 released, ");
    CHECK(ReadProfileFile(L"", text, sizeof text) > 0);
    CHECK_EQ(strcmp(text, "ArmoryPreviewCache2 25480438\n"), 0); /* not yet: the throttle */
    CHECK(Frame().read > 1);                                     /* a working frame: the save is pending */
    Frames(60 * 5);
    CHECK(ReadProfileFile(L"", text, sizeof text) > 0);
    /* The current group touched in reverse: the last request oldest, the first newest. */
    CHECK(strncmp(text, "ArmoryPreviewCache2 25480438\n3:0000000000001011|\n3:0000000000001010|\n", 69) == 0);
    CHECK(strstr(text, "|\n3:0000000000001000|\n") != NULL);
    CHECK_EQ(apc_images_texture_count(), 1);
    CHECK_EQ(e.destroys, 0);
    int idle = 0, polls = 0;
    for (int i = 0; i < 600; i++)
    {
        FakeCounts c = Frame();
        idle += c.read == 1;
        polls += e.polls;
        CHECK(c.read == 1 || c.read == 2 || (c.read == 4 && e.polls == 1));
    }
    CHECK_EQ(polls, 5);
    CHECK(idle >= 585);
}

/* A revisit: the native pipeline renders again (the cards queued); the retained crops show at once, before native
 * completion, and no second atlas is allocated while nothing completes. */
static void RevisitShowsTheCacheEarly(void)
{
    Visit();
    Top(3, 1);
    Frames(30);
    Card(0, 3, VISIBLE);
    Card(1, 3, ITEMS - VISIBLE);
    Active(0, 4);
    for (int i = 0; i < VISIBLE; i++) e.texture[i] = 0;
    Top(5, 1);
    Frames(2);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);
    CHECK_EQ(apc_images_stats()->last_early_hits, VISIBLE);
    CHECK_EQ(e.creates, 1);
    /* Native completion: the re-rendered requests supersede the crops: the new atlas is retained, the old released. */
    Card(0, 8, VISIBLE);
    Card(1, 8, ITEMS - VISIBLE);
    Active(0xFFFFFFFFu, 0);
    Frames(2);
    CHECK_EQ(e.creates, 2);
    CHECK_EQ(apc_images_stats()->refreshed, ITEMS);
    CHECK_EQ(apc_images_texture_count(), 1);
    CHECK_EQ(Bound(P(e.created[0])), VISIBLE);
    CHECK_EQ(e.destroys, 1);
    CHECK(e.destroyed[0] == P(w.atlas));
}

/* Memory pressure: leases released, every tile handed back and the idle backup returned to the game (the completed
 * atlas back in the manager, the blank replacement destroyed), nothing retained. */
static void MemoryPressureHandsBack(void)
{
    Visit();
    w.free = 1ull << 30;
    Frames(4);
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK_EQ(strcmp(vpm_status(C()), "memory_pressure"), 0);
    CHECK(Atlas() == w.atlas);
    CHECK_EQ(e.destroys, 1);
    CHECK(e.destroyed[0] == P(e.created[0]));
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);
    CHECK_EQ(apc_images_texture_count(), 0);
    for (int i = 0; i < VISIBLE; i++) CHECK_EQ(Record(i)[68], 1); /* invalidated: the native pipeline renders it again */
    CHECK_LOG("memory low (low_physical_memory, 1024 MiB free, 16384 MiB commit headroom): leases and retained images released");
    /* Recovery: 30 s after the last low reading and 5 s healthy. */
    w.free = 8ull << 30;
    Frames(60 * 20);
    CHECK_EQ(strcmp(vpm_status(C()), "memory_pressure"), 0);
    CHECK_NO_LOG("memory recovered");
    Frames(60 * 16);
    CHECK(strcmp(vpm_status(C()), "memory_pressure") != 0);
    CHECK_LOG("[Armory Preview Cache] memory recovered");
}

/* The thumbnail manager replaced: the cache drops what it held (the textures released), as the Lua did. */
static void NewManagerClears(void)
{
    Visit();
    Top(3, 1);
    Frames(30);
    uint8_t* copy = fake_heap(APC_MANAGER_SIZE);
    memcpy(copy, w.manager, APC_MANAGER_SIZE);
    Put64(Game(APC_RVA_GLOBALS), P(copy));
    Frames(2);
    CHECK_EQ(apc_images_texture_count(), 0);
    CHECK_EQ(apc_images_stats()->clear_count, 1);
    CHECK_EQ(e.destroys, 1);
    CHECK(e.destroyed[0] == P(w.atlas));
}

/* The core stopping the component: tiles back, leases released, the profile saved. */
static void StopHandsEverythingBack(void)
{
    Visit();
    vpm_core_stop(C(), "test");
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK(Atlas() == w.atlas);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);
    CHECK_EQ(apc_images_texture_count(), 0);
    char text[64];
    CHECK(ReadProfileFile(L"", text, sizeof text) > 0);
}

/* The engine making no texture: nothing retained, the game's atlas untouched. */
static void NoTextureNoHandoff(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    e.refuse_create = 1;
    Frames(12);
    Top(5, 1);
    Frames(10);
    CHECK(e.creates >= 1);
    CHECK(Atlas() == w.atlas);
    CHECK_EQ(apc_images_texture_count(), 0);
    CHECK_EQ(e.textures, 0);
}

/* Nine categories through the eight-atlas budget: the least recently used goes. */
static void EightAtlases(void)
{
    Visit();
    for (uint32_t generation = 1; generation <= 8; generation++)
    {
        Category(generation, 8);
        Frames(3);
    }
    CHECK_EQ(apc_images_stats()->retained, 9);
    CHECK_EQ(apc_images_stats()->evicted, 1);
    CHECK_EQ(apc_images_texture_count(), 8);
    CHECK(e.destroyed[0] == P(w.atlas));
}

/* A late switch: a capture of completed cards that the next request replaced before a safe boundary is dropped, never
 * retained (its pixels may already be overwritten). */
static void LateSwitchIsNotRetained(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    Frames(12);
    Card(1, 6, ITEMS - VISIBLE);             /* card 0 complete, card 1 finalizing: no handoff boundary */
    Top(5, 1);
    Frames(2);
    CHECK_EQ(e.creates, 0);
    CHECK_EQ(apc_images_stats()->pending_items, VISIBLE);
    Category(1, 3);                          /* another category queued; not at a switch boundary (none active) */
    Frames(2);
    CHECK_EQ(apc_images_stats()->late_switches, 1);
    CHECK_EQ(e.creates, 0);
}

/* The visible handoff: the visible card composed while the offscreen one prepares (the active card, phase 4): its
 * tiles are kept before the rest finishes; the offscreen card is retained later through the rebind boundary, without
 * capturing the blank regions again. */
static void VisibleThenRebind(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    Frames(12);
    Card(1, 4, ITEMS - VISIBLE);
    Active(1, 4);
    Top(5, 1);
    Frames(2);
    CHECK_EQ(e.creates, 1);
    CHECK_EQ(apc_images_stats()->visible_retained, 1);
    CHECK_EQ(apc_images_stats()->partial_retained, 1);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);
    Frames(5);
    CHECK_EQ(e.creates, 1);                  /* one visible handoff per request */
    Card(1, 8, ITEMS - VISIBLE);
    Active(0xFFFFFFFFu, 0);
    Frames(2);
    CHECK_EQ(e.creates, 2);
    CHECK_EQ(apc_images_stats()->idle_retained, 1);
    CHECK_EQ(apc_images_texture_count(), 2);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);    /* the visible tiles keep their first crops */
}

/* A weapon's configured slots change (the preview queue): the crop retires at once and the tile goes back to the
 * native pipeline. An unobserved configuration never retires one. */
static void ConfigurationChangeRetires(void)
{
    BuildWorld();
    ForgetProfile();
    uint8_t* job = w.preview + 50456;
    Put32(w.preview + 50448, 0);
    Put32(w.preview + 50452, 1);
    Put64(job + 64, ItemId(0));
    Put32(job + 80, 1);
    Put64(job + 88, 0xAABB);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(3);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);
    Put64(job + 88, 0xCCDD);
    Frames(2);
    CHECK_EQ(apc_images_stats()->reappeared, 1);
    CHECK(Shown(Element(0)) == (uintptr_t)Atlas());   /* handed back */
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE - 1);
    Put32(w.preview + 50452, 0);                      /* the queue empties: the last observation stays */
    Frames(2);
    CHECK_EQ(apc_images_stats()->reappeared, 1);
}

/* ---- the policy ---------------------------------------------------------------------------------------------------- */

/* A package the game holds already keeps its own reference through every lease and release. */
static void IndependentReferencesStay(void)
{
    BuildWorld();
    ForgetProfile();
    LeasePut(0, Package(3), 1);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(40);
    CHECK_EQ(LeaseCount(Package(3)), 2);
    Put32(w.ui + 15892, 1);                  /* the UI busy flag toggles during generation: leases stay */
    Frames(10);
    CHECK_EQ(LeaseCount(Package(3)), 2);
    CHECK_EQ(strcmp(vpm_status(C()), "thumbnail_ui_busy"), 0);
    Put32(w.ui + 15892, 0);
    Top(3, 1);
    Frames(6);
    CHECK_EQ(LeaseCount(Package(3)), 1);
    CHECK_EQ(LeaseRowCount(), 1);
}

/* A table with 1008 rows refuses a new package (no release obligation follows); an unbalanced call is an error. */
static void LeaseTableBounds(void)
{
    BuildWorld();
    ForgetProfile();
    for (int i = 0; i < 1008; i++) LeasePut(i, 0x5000000000000000ull + (uint64_t)i, 1);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(40);
    CHECK_EQ(e.acquires, 0);
    Top(3, 1);
    Frames(6);
    CHECK_EQ(e.releases, 0);
    CHECK_EQ(LeaseRowCount(), 1008);
    /* An acquire that does not balance is an error (logged). The failed step leaves the last step's "settled", so while
     * nothing changes the next steps replay it and do not try again: the Lua's assignment after its tick is skipped the
     * same way. */
    fake_setup();
    BuildWorld();
    ForgetProfile();
    Boot();
    e.unbalanced = 1;
    Frames(12);
    Top(5, 1);
    Frames(30);
    CHECK_LOG("[Armory Preview Cache] error: Package acquire did not balance");
    /* Two tries: the first step came in the handoff's own frame (its snapshot was read before the handoff's writes), so
     * the next step read a new one and tried again; from then on the snapshot is reused and the step replayed. */
    CHECK_EQ(e.acquires, 2);
    Frames(60);
    CHECK_EQ(e.acquires, 2);
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK(vpm_running(C()));
}

/* An error every step (the memory query failing, as the Lua test made it): the first is logged, the eighth stops the
 * component, whose stop hands everything back. */
static void EightErrorsStop(void)
{
    Visit();
    w.memory_fails = 1;
    Frames(3 * 7);
    CHECK(vpm_running(C()));
    CHECK_LOG("[Armory Preview Cache] error: Memory telemetry unavailable");
    Frames(3);
    CHECK(!vpm_running(C()));
    CHECK_LOG("disabled: stopped after 8 errors: Memory telemetry unavailable");
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK(Atlas() == w.atlas);
    CHECK_EQ(apc_images_texture_count(), 0);
    const char* first = strstr(fake_log_text(), "error: Memory telemetry unavailable");
    CHECK(first != NULL && strstr(first + 1, "error: Memory telemetry unavailable") == NULL);
}

/* Malformed rows are refused: a 64-bit count, a zero count. */
static void MalformedLeaseRows(void)
{
    for (int c = 0; c < 2; c++)
    {
        fake_setup();
        BuildWorld();
        ForgetProfile();
        LeasePut(5, 9, 1);
        if (c == 0) LeaseRows()[5 * 4 + 3] = 1;
        else LeaseRows()[5 * 4 + 2] = 0;
        Boot();
        Frames(12);
        Top(5, 1);
        Frames(6);
        CHECK_LOG(c == 0 ? "error: Invalid package reference count" : "error: Invalid package references");
        CHECK_EQ(e.acquires, 0);
    }
}

/* A new package system (the manager replaced): its predecessor owned the references, none is released. The same system
 * losing them in place: quarantined, nothing released, nothing leased again. */
static void OwnershipChanges(void)
{
    Visit();
    uint8_t* old = w.lease;
    BuildLeases();
    Put64(Game(APC_RVA_PACKAGES), P(w.lease));
    Frames(30);
    CHECK_EQ(e.releases, 0);
    CHECK_EQ(apc_policy()->retired, ITEMS);
    CHECK_EQ(LeaseRowCount(), ITEMS);         /* leased again from the new system */
    (void)old;
    memset(w.lease + 32, 0, 16384);           /* cleared in place: seen by the next full step (the rows are not in the */
    Put32(w.ui + 15892, 1);                   /* state view: something the policy reads must change, as in the Lua) */
    Frames(6);
    CHECK_EQ(strcmp(vpm_status(C()), "lease_ownership_lost_restart_required"), 0);
    int acquires = e.acquires;
    Frames(30);
    CHECK_EQ(e.acquires, acquires);
    CHECK_EQ(e.releases, 0);
}

/* A learned profile prewarms at start-up (an empty state stack, an idle manager, a UI world), newest first, for 60 s. */
static void StartupPrewarm(void)
{
    BuildWorld();
    ForgetProfile();
    WriteProfileFile(L"", "ArmoryPreviewCache2 25480438\n3:0000000000001000|\n3:0000000000001001|\n3:0000000000001002|\n");
    Card(0, 0, 0);
    Card(1, 0, 0);
    Top(0, 0);
    Boot();
    CHECK_LOG("3 learned items from the profile");
    Frames(12);
    CHECK_EQ(LeaseRowCount(), 3);
    CHECK_EQ(apc_policy()->startup_acquires, 3);
    CHECK_EQ(strcmp(vpm_status(C()), "startup_dependency_prewarm"), 0);
    fake_counts_reset();
    Frames(60);                               /* the window is never idle */
    CHECK(fake_counts().read > 60);
    Frames(60 * 60);
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK_EQ(strcmp(vpm_status(C()), "outside_ship_ui"), 0);
    Frames(12);
    FakeCounts c = Frame();
    CHECK_EQ(c.read, 1);
}

/* Malformed profiles decode to nothing; a bad primary falls back to the backup. */
static void ProfileChecks(void)
{
    static const char* const bad[] = {
        "ArmoryPreviewCache2 other\n3:0000000000001000|\n",
        "ArmoryPreviewCache2 25480438\n3:0000000000001000|",
        "ArmoryPreviewCache2 25480438\n3:0000000000001000|,0000000000000001\n",
        "ArmoryPreviewCache2 25480438\n3:0000000000001000|0000000000000001,0000000000000001\n",
        "ArmoryPreviewCache2 25480438\n3:000000000000100|\n5:0000000000001000|\n3:0000000000000000|\n",
    };
    for (int c = 0; c < 5; c++)
    {
        fake_setup();
        BuildWorld();
        ForgetProfile();
        WriteProfileFile(L"", bad[c]);
        Boot();
        CHECK_LOG("; 0 learned items");
    }
    fake_setup();
    BuildWorld();
    ForgetProfile();
    WriteProfileFile(L"", "ArmoryPreviewCache1 25480438\n2:0000000000000001\n2:0000000000000001\n5:0000000000000001\n2:0000000000000000\n");
    Boot();
    CHECK_LOG("; 1 learned items");
    fake_setup();
    BuildWorld();
    ForgetProfile();
    WriteProfileFile(L"", "garbage\n");
    WriteProfileFile(L".bak", "ArmoryPreviewCache2 25480438\n0:0011223344556677|fedcba9876543210\n4:0000000000000002|\n");
    Boot();
    CHECK_LOG("; 2 learned items");
}

/* HellForge content past the Lua's bounds: a loadout package record of its own (index 541 and up: add_entity with
 * own_all) fails the catalogue as the Lua's check did; the asset step waits and says why, once. */
static void HellForgeRecordsPastTheBounds(void)
{
    BuildWorld();
    ForgetProfile();
    Put64(w.weapons, 0x80932FA0ED6901D3ull);
    Put32(w.weapons + 8, 541);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(60);
    CHECK_EQ(strcmp(vpm_status(C()), "waiting_for_ui"), 0);
    CHECK_LOG("[Armory Preview Cache] waiting for the UI: Weapon record bound changed");
    CHECK_EQ(LeaseRowCount(), 0);
    CHECK(vpm_running(C()));
    const char* log = fake_log_text();
    const char* first = strstr(log, "waiting for the UI");
    CHECK(first != NULL && strstr(first + 1, "waiting for the UI") == NULL);
    /* As in the Lua, the failed snapshot's cleanup also hands every image back: the next frame retains the request
     * again, so an atlas is created and destroyed every 50 ms while that content is loaded. */
    CHECK_EQ(e.creates, 21);
    CHECK_EQ(e.destroys, 20);
}

/* The pre-select (weapon mode): its block and three widgets' record pointers replace the grid block: 10 reads per
 * unchanged frame with nothing bound (the Lua: 12), 12 and a memory poll on a policy step. */
static void PreselectReads(void)
{
    BuildWorld();
    ForgetProfile();
    uint8_t* control = w.owner + CONTROL;
    control[37968 + 4] = 0;
    Put32(control + 37968, 0);               /* the selected card */
    Put32(control + 37968 + 12, 0);          /* weapon mode */
    for (int i = 0; i < 3; i++)
    {
        memcpy(control + 37728 + i * 80, Record(i), 80);
        PutWidget(control + 5256 + i * 12304, control + 37728 + i * 80);
    }
    Card(0, 5, VISIBLE);                     /* preparing: nothing to bind */
    Card(1, 0, 0);
    Active(0, 5);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(12);
    CHECK_EQ(apc_images_stats()->screen, APC_SCREEN_WEAPON_PRESELECT);
    int plain = 0, step = 0;
    for (int i = 0; i < 12; i++)
    {
        FakeCounts c = Frame();
        plain += c.read == 10 && e.polls == 0;
        step += c.read == 12 && e.polls == 1;
    }
    CHECK_EQ(plain, 8);
    CHECK_EQ(step, 4);
}

/* The grid with every card preparing: 8 reads per unchanged frame (the Lua: 10), 10 and a memory poll on a step. */
static void PreparingGridReads(void)
{
    BuildWorld();
    ForgetProfile();
    Card(0, 5, VISIBLE);
    Card(1, 5, ITEMS - VISIBLE);
    Active(0, 5);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(60);
    int plain = 0, step = 0;
    for (int i = 0; i < 30; i++)
    {
        FakeCounts c = Frame();
        plain += c.read == 8 && e.polls == 0;
        step += c.read == 10 && e.polls == 1;
    }
    CHECK_EQ(plain, 20);
    CHECK_EQ(step, 10);
    CHECK_EQ(e.creates, 0);
}

/* The once-only and per-event costs, pinned. */
static void OnceOnlyCosts(void)
{
    BuildWorld();
    ForgetProfile();
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    /* The first tick initializes: 20 code-byte checks (16 functions; the two long ones in 3 patterns each), 7 reads of
     * the engine's application API, then the frame's refresh on the ship (2). */
    FakeCounts c = Frame();
    CHECK_EQ(c.code_matches, 20);
    CHECK_EQ(c.read, 9);
    CHECK_EQ(c.log, 1);
    ExeStubs();
    CHECK_EQ(Frame().read, 2);
    /* The first policy step: the refresh (2) and the asset snapshot on the ship (5: the lease table's owner 2, the
     * stack, the UI world and its busy flag), one memory poll. Then idle: 1 read. */
    c = Frame();
    CHECK_EQ(c.read, 7);
    CHECK_EQ(e.polls, 1);
    CHECK_EQ(Frame().read, 1);
    Frames(9);
    Top(5, 1);
    /* The first Armory frame (no binding to check yet): the refresh (8), the decode's grid reads (3 column counts, 12
     * widgets), the handoff's checks (the working atlas, its descriptor, the fresh atlas's id), the rebind (one ownership
     * read, 2 material reads per tile, the working atlas) and the first apply's working atlas. */
    CHECK_EQ(Frame().read, 8 + 15 + 3 + 26 + 1);
    /* The next: the first binding check after a full snapshot (the controller 3, the UI world, the working atlas, 7 per
     * binding: 89), the refresh and a full tick again (the handoff's writes changed what it decodes: 15 + 26), then the
     * first step: the lease owner (2), the snapshot with the first catalogue build (36) and 4 leases (6 each). */
    c = Frame();
    CHECK_EQ(c.read, 89 + 8 + 15 + 26 + 2 + 36 + 4 * 6);
    CHECK_EQ(e.polls, 1);
    /* The binding check after that full tick, then a gated tick (the refresh, the shown texture's ownership). */
    CHECK_EQ(Frame().read, 89 + 8 + 1);
    CHECK_EQ(Frame().read, 17);
    /* A step taking 4 leases (on a reused snapshot): 19, the valid-lease check (3) and 6 per lease (the table before
     * and after). Steps come every third frame (50 ms at 60 FPS). */
    c = Frame();
    CHECK_EQ(c.read, 19 + 3 + 4 * 6);
    CHECK_EQ(e.polls, 1);
    Frames(19);
    /* Leaving: the binding check (the refresh 2, then 3: the stack, the UI world, the working atlas; the bindings are
     * dropped without a read) and the tick's refresh (2); then the step: the refresh (2), the lease owner (2), the
     * snapshot (5), the valid-lease checks (3 + 3) and 6 per release. */
    Top(3, 1);
    CHECK_EQ(Frame().read, 2 + 3 + 2);
    CHECK_EQ(Frame().read, 2 + 2 + 5 + 6 + ITEMS * 6);
    CHECK_EQ(e.releases, ITEMS);
}

/* ---- the memory guard, the learned list, the profile codec (policy.lua, profile.lua, called directly) ----------- */

static void MemoryGuardThresholds(void)
{
    const uint64_t gib = 1ull << 30;
    ApcGuard g;
    memset(&g, 0, sizeof g);
    CHECK_EQ(apc_guard_tick(&g, 0, 30 * gib, 30 * gib), APC_PRESSURE_NONE);
    CHECK_EQ(apc_guard_tick(&g, 1, gib, 30 * gib), APC_PRESSURE_LOW_PHYSICAL);
    CHECK_EQ(g.trips, 1);
    CHECK_EQ(apc_guard_tick(&g, 2, 30 * gib, 30 * gib), APC_PRESSURE_RECOVERY);
    CHECK_EQ(apc_guard_tick(&g, 30, 30 * gib, 30 * gib), APC_PRESSURE_RECOVERY);
    CHECK_EQ(apc_guard_tick(&g, 31, 30 * gib, 30 * gib), APC_PRESSURE_NONE);
    CHECK(!g.active);
    CHECK_EQ(apc_guard_tick(&g, 32, 30 * gib, gib), APC_PRESSURE_LOW_COMMIT);
    CHECK_EQ(g.trips, 2);
    CHECK_EQ(apc_guard_tick(&g, 70, 3 * gib, 30 * gib), APC_PRESSURE_RECOVERY); /* recovery needs 4 GiB */
    CHECK_EQ(apc_guard_tick(&g, 71, 30 * gib, 30 * gib), APC_PRESSURE_RECOVERY);
    CHECK_EQ(apc_guard_tick(&g, 73, gib, 30 * gib), APC_PRESSURE_LOW_PHYSICAL);  /* a new dip restarts recovery */
    CHECK_EQ(apc_guard_tick(&g, 74, 30 * gib, 30 * gib), APC_PRESSURE_RECOVERY);
    CHECK_EQ(apc_guard_tick(&g, 103, 30 * gib, 30 * gib), APC_PRESSURE_NONE);
}

static ApcAssetItem Learnt(uint32_t kind, uint64_t id)
{
    ApcAssetItem item;
    memset(&item, 0, sizeof item);
    item.kind = kind;
    item.id = id;
    return item;
}

/* 192 learned items at most, oldest dropped; a revisit moves an item to the newest; attachments are kept. */
static void LearnedList(void)
{
    apc_policy_reset(1);
    for (int i = 1; i <= 300; i++)
    {
        ApcAssetItem item = Learnt(2, (uint64_t)i);
        apc_policy_remember(&item);
    }
    CHECK_EQ(apc_policy()->learned_count, APC_LEARNED);
    CHECK_EQ(apc_policy()->learned[0].id, 109);
    ApcAssetItem weapon = Learnt(0, 9000);
    weapon.has_attachments = 1;
    weapon.attachment_count = 1;
    weapon.attachments[0] = 0xAABB;
    apc_policy_remember(&weapon);
    ApcAssetItem other = Learnt(2, 9001), plain = Learnt(0, 9000);
    apc_policy_remember(&other);
    apc_policy_remember(&plain);
    const ApcAssetItem* last = &apc_policy()->learned[APC_LEARNED - 1];
    CHECK_EQ(last->id, 9000);
    CHECK(last->has_attachments && last->attachment_count == 1 && last->attachments[0] == 0xAABB);
    /* The codec: 64-bit attachment ids exact, the build checked, malformed attachments refused, the legacy format read. */
    static char text[APC_PROFILE_MAX];
    size_t size = apc_profile_encode(text, sizeof text, "build");
    CHECK(strstr(text, "0:0000000000002328|000000000000aabb\n") != NULL);
    apc_policy_reset(1);
    CHECK(apc_profile_decode(text, size, "build", 1));
    CHECK_EQ(apc_policy()->learned_count, APC_LEARNED);
    CHECK_EQ(apc_policy()->learned[APC_LEARNED - 1].attachments[0], 0xAABB);
    CHECK(!apc_profile_decode(text, size, "other build", 0));
    const char legacy[] = "ArmoryPreviewCache1 build\n0:0011223344556677\n";
    apc_policy_reset(1);
    CHECK(apc_profile_decode(legacy, sizeof legacy - 1, "build", 1));
    CHECK_EQ(apc_policy()->learned_count, 1);
    CHECK(!apc_policy()->learned[0].has_attachments);
    const char comma[] = "ArmoryPreviewCache2 build\n0:0011223344556677|,fedcba9876543210\n";
    const char twice[] = "ArmoryPreviewCache2 build\n0:0011223344556677|fedcba9876543210,fedcba9876543210\n";
    apc_policy_reset(1);
    CHECK(apc_profile_decode(comma, sizeof comma - 1, "build", 1) && apc_policy()->learned_count == 0);
    CHECK(apc_profile_decode(twice, sizeof twice - 1, "build", 1) && apc_policy()->learned_count == 0);
}

/* ---- presentation details --------------------------------------------------------------------------------------- */

/* A bound tile whose material the game cleared or replaced is no longer ours: no texture call reaches it (the native
 * setter clones that material: a cleared pointer would crash). */
static void MaterialLifetime(void)
{
    Visit();
    uint8_t* tile = WidgetAt(0);
    int textures = e.textures;
    Put64(tile + 600, 0);                    /* cleared */
    Put64(WidgetAt(1) + 600, 0x500000ABC000ull); /* replaced */
    Frames(3);
    CHECK(Shown(Element(0)) == P(w.atlas));  /* untouched since */
    CHECK(Shown(Element(1)) == P(w.atlas));
    vpm_core_stop(C(), "test");
    CHECK(Shown(Element(0)) == P(w.atlas));  /* the stop's restore skips both */
    CHECK(Shown(Element(1)) == P(w.atlas));
    CHECK(Shown(Element(2)) == P(w.atlas));  /* the others: back to the working atlas, then the original returned */
    CHECK(e.textures > textures);
}

/* A tile showing the named thumbnail template is initialized (its private material made, registered) before our
 * texture is bound; when the material cannot be made it stays a miss. */
static void TemplateTiles(void)
{
    BuildWorld();
    ForgetProfile();
    Put64(WidgetAt(0) + 600, 0);
    Put64(WidgetAt(0) + 608, 0x27EF06435506E446ull);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(2);
    CHECK_EQ(e.materials, 1);
    CHECK_EQ(e.images, 1);
    CHECK(Shown(Element(0)) == P(w.atlas));
    CHECK_EQ(WidgetAt(0)[2005], 1);
    CHECK_EQ(Bound(P(w.atlas)), VISIBLE);
}

/* Memory pressure while idle with images held: released at the next memory poll (within 2 s). */
static void PressureWhileIdle(void)
{
    Visit();
    Top(3, 1);
    Frames(60 * 6);
    CHECK_EQ(apc_images_texture_count(), 1);
    w.free = 1ull << 30;
    Frames(60 * 2 + 10);
    CHECK_EQ(apc_images_texture_count(), 0);
    CHECK_EQ(e.destroys, 1);
}

/* A briefing on the stack is never idle (its controller decides whether a thumbnail screen shows). */
static void BriefingNeverIdle(void)
{
    BuildWorld();
    ForgetProfile();
    Boot();
    Frames(12);
    Top(14, 1);
    Frames(12);
    int idle = 0;
    for (int i = 0; i < 60; i++) idle += Frame().read == 1;
    CHECK_EQ(idle, 0);
    CHECK_EQ(e.creates, 0);
}

/* The briefing loadout: six records holding their slot's request (kinds helmet, armor, cape, primary, secondary,
 * throwable), each widget pointing at its record: retained and shown as one request. */
static void BriefingLoadout(void)
{
    static const uint32_t kinds[6] = {2, 3, 4, 0, 0, 1};
    BuildWorld();
    ForgetProfile();
    uint8_t* owner = fake_heap(864032 + META + 24892);
    Put64(w.dispatch + 5744, P(owner));
    Put32(w.dispatch + 5744 + 8, 229);
    Card(0, 8, 6);
    Card(1, 0, 0);
    Put32(w.manager + APC_AT_REGISTRY, 6);
    for (int i = 0; i < 6; i++)
    {
        Put32(ItemAt(0, i) + 100, kinds[i]);
        uint8_t* rec = owner + 454728 + i * 80;
        Put64(rec, 0x7700u + (uint64_t)i);
        Put32(rec + 8, 3);
        Put32(rec + 60, 0);
        Put32(rec + 64, (uint32_t)i);
        PutWidget(owner + 422768 + i * 5464, rec);
        Put64(w.manager + 11144 + i * 8, P(owner + 422768 + i * 5464 + 272));
    }
    Boot();
    Frames(12);
    Top(14, 1);
    Frames(3);
    CHECK_EQ(apc_images_stats()->screen, APC_SCREEN_BRIEFING_LOADOUT);
    CHECK_EQ(e.creates, 1);
    for (int i = 0; i < 6; i++) CHECK(Shown(owner + 422768 + i * 5464 + 272) == P(w.atlas));
    CHECK_EQ(apc_images_stats()->briefing_hits >= 6, 1);
    CHECK(strcmp(vpm_status(C()), "outside_ship_ui") != 0); /* one briefing controller: the menu is open */
}

/* A weapon's packages: its own (the loadout package record) and its default attachment's (the weapon configuration's
 * slot, the attachment catalogue, the package map): a dependency lease. */
static void WeaponDependencies(void)
{
    BuildWorld();
    ForgetProfile();
    const uint64_t weapon = 0x0BADC0DE, attachment = 0x4003, packageOf = 0xB000000000000001ull;
    Put64(ItemAt(0, 0) + 24, weapon);
    Put32(ItemAt(0, 0) + 100, 0);
    Put64(w.weapons, weapon);                /* the loadout package record 0 */
    Put32(w.weapons + 8, 0);
    Put64(w.weapons + 17280 + 8, 0xB000000000000000ull);
    Put64(w.definitions, weapon);            /* the configuration 0 */
    Put32(w.definitions + 8, 0);
    uint8_t* config = w.definitions + 10368;
    Put32(config, 1);                        /* slot kind 1: attachment number 77 */
    Put32(config + 4, 77);
    uint8_t* row = fake_heap(88);
    uint32_t* kindList = fake_heap(4);
    kindList[0] = 1;
    Put32(row + 8, 77);
    Put64(row + 32, attachment);
    Put64(row + 48, P(kindList));
    Put32(row + 56, 1);
    Put64(w.groupHeader, P(row));
    Put32(w.groupHeader + 8, 1);
    Put64(w.mapRows + (attachment % 16) * 16, attachment);
    Put64(w.mapRows + (attachment % 16) * 16 + 8, packageOf);
    Boot();
    Frames(12);
    Top(5, 1);
    Frames(40);
    CHECK_EQ(LeaseCount(0xB000000000000000ull), 1);
    CHECK_EQ(LeaseCount(packageOf), 1);
    CHECK_EQ(apc_policy()->dependency_acquires, 1);
}

int main(void)
{
    wchar_t cwd[MAX_PATH];
    GetCurrentDirectoryW(MAX_PATH, cwd);
    _snwprintf(g_local, MAX_PATH, L"%ls\\apc-localappdata", cwd);
    (void)CreateDirectoryW(g_local, NULL);
    SetEnvironmentVariableW(L"LOCALAPPDATA", g_local);
    RUN(IdlesOnTheShip);
    RUN(WaitsForTheEngineApi);
    RUN(RefusesWhatIsNotAsReviewed);
    RUN(ImagesOffLeasesOnly);
    RUN(FirstVisitRetainsAndLeases);
    RUN(LeavingReleasesAndSaves);
    RUN(RevisitShowsTheCacheEarly);
    RUN(MemoryPressureHandsBack);
    RUN(NewManagerClears);
    RUN(StopHandsEverythingBack);
    RUN(NoTextureNoHandoff);
    RUN(EightAtlases);
    RUN(LateSwitchIsNotRetained);
    RUN(VisibleThenRebind);
    RUN(ConfigurationChangeRetires);
    RUN(IndependentReferencesStay);
    RUN(LeaseTableBounds);
    RUN(EightErrorsStop);
    RUN(MalformedLeaseRows);
    RUN(OwnershipChanges);
    RUN(StartupPrewarm);
    RUN(ProfileChecks);
    RUN(HellForgeRecordsPastTheBounds);
    RUN(PreselectReads);
    RUN(PreparingGridReads);
    RUN(OnceOnlyCosts);
    RUN(MemoryGuardThresholds);
    RUN(LearnedList);
    RUN(MaterialLifetime);
    RUN(TemplateTiles);
    RUN(PressureWhileIdle);
    RUN(BriefingNeverIdle);
    RUN(BriefingLoadout);
    RUN(WeaponDependencies);
    TEST_END();
}
