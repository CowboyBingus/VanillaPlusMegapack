/* Armory Preview Cache: package leases and the asset snapshot (native.lua and signatures.lua, v23.1), build 25480438.
 *
 * The only game changes are balanced calls to the game's package lease API: request(system, ids, 1) at game.dll
 * 0x12FE350 takes a reference on a package, 0x12FE4E0 drops one, with the RefcountedPackageSystem at [game.dll +
 * 0x347CEB0] (the same system HellForge's load_package uses for its own references). Every call is checked: the lease
 * table's 1024 rows are decoded before and after it, and the package's count must have moved by exactly one. All
 * thumbnail cards, render targets, queues and executable bytes stay owned and updated by the game.
 *
 * A thumbnail item resolves to its package through the game's catalogues: a weapon (kinds 0, 1) through its loadout
 * package record (component table 28 of the entity state, 1080 index rows and 540 records), a helmet, armor or cape
 * (kinds 2..4) through the kit presets and kits. The bounds the Lua checked stay, with one change for HellForge content:
 * an index row naming a record past the Lua's 540 is skipped, not a failure of the whole catalogue (the Lua's
 * "Weapon record bound changed"). Such rows are HellForge's own records for mod content (its copy of table 28 keeps
 * every vanilla record and puts a mod's after them, from 541: add_entity with own_all or model_from, a weapon naming
 * LoadoutPackageComponentData); the Lua stopped every lease and image while one was loaded. Their items now resolve to
 * no package, as items the component does not know: the game loads them as it does without the component, and every
 * vanilla item keeps its lease. apc_native_skipped counts them (the log says so once per count). Every other bound
 * fails the snapshot as in the Lua. */
#include "apc.h"

#define LEASE_ROWS 1024
#define LEASE_LIMIT 1008

typedef void (*LeaseFn)(void* system, const uint64_t* ids, uint32_t count);

static const ApcSignature kSignatures[] = {
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
};

static struct
{
    LeaseFn acquire, release;
    int has_catalog;
    uint64_t catalog[6];                 /* kits, their pointers and count, presets and count, weapon table */
    uint32_t skipped;                    /* index rows past the Lua's bound in the last catalogue built */
} g;

static uint32_t g_leaseRows[LEASE_ROWS * 4];   /* the lease table's rows (16 bytes: identifier, 64-bit count) */
static uint8_t g_manager[APC_MANAGER_SIZE];
static uint8_t g_buffer[32768];
APC_MAP(g_rows, 2048);                   /* package -> references, the last decode */
APC_MAP(g_kits, 2048);
APC_MAP(g_presets, 8192);
APC_MAP(g_weapons, 2048);

static int Read(uintptr_t address, void* out, size_t size)
{
    if (size == 0 || size > 32768) return apc_fail("Read exceeds bound");
    return apc_need(address, out, size, "Native data unavailable");
}

/* native.lua ptr(p): the pointer stored at p, which must be plausible. */
static int Pointer(uintptr_t address, uintptr_t* out)
{
    uint64_t value = 0;
    if (!Read(address, &value, 8)) return 0;
    if (!ApcPlausible(value)) return apc_fail("Native pointer unavailable");
    *out = (uintptr_t)value;
    return 1;
}

static int GamePointer(uint32_t rva, uintptr_t* out)
{
    *out = ApcGamePointer(rva);
    return *out ? 1 : apc_fail("Native pointer unavailable");
}

static int AppSlot(uintptr_t app, uint32_t offset, uint32_t rva, int* matches)
{
    uintptr_t value;
    if (!Pointer(app + offset, &value)) return 0;
    *matches = value == vpm_exe() + rva;
    return 1;
}

/* native.new: the lease functions' code bytes, the engine API root and the application's package API. */
int apc_native_init(void)
{
    memset(&g, 0, sizeof g);
    apc_map_clear(&g_rows);
    apc_map_clear(&g_kits);
    apc_map_clear(&g_presets);
    apc_map_clear(&g_weapons);
    if (!apc_signatures_match(kSignatures, (int)(sizeof kSignatures / sizeof kSignatures[0])))
        return apc_fail("Native instruction mismatch");
    uintptr_t root, app;
    if (!GamePointer(APC_RVA_ROOT_API, &root)) return 0;
    if (root != vpm_exe() + APC_EXE_ROOT_API) return apc_fail("Unexpected script API");
    if (!Pointer(root + 16, &app)) return 0;
    int a = 0, b = 0;
    if (!AppSlot(app, 752, APC_EXE_PACKAGE_A, &a) || (a && !AppSlot(app, 768, APC_EXE_PACKAGE_B, &b))) return 0;
    if (!a || !b) return apc_fail("Unexpected package API");
    g.acquire = (LeaseFn)(vpm_game() + APC_RVA_ACQUIRE);
    g.release = (LeaseFn)(vpm_game() + APC_RVA_RELEASE);
    return 1;
}

/* ---- the lease table ------------------------------------------------------------------------------------------------ */

/* The package system and its allocator: the table's identity. */
static int Owner(uint64_t owner[2], uintptr_t* system)
{
    uint32_t h[8];
    uintptr_t p, allocator;
    if (!GamePointer(APC_RVA_PACKAGES, &p) || !Read(p, h, 32)) return 0;
    if (h[2] != 1024 || h[6] != 2 || h[4] != 0 || h[5] != 0) return apc_fail("Unexpected lease table");
    if (ApcPointer(h, 0) != p + 32) return apc_fail("Unexpected lease storage");
    if (!Pointer(p + 16416, &allocator)) return 0;
    owner[0] = p;
    owner[1] = allocator;
    *system = p;
    return 1;
}

/* The table's rows (identifier -> count, one reused map) and how many: counts are 64-bit natively, so a high word or an
 * implausible value is refused. */
static int References(uint64_t owner[2], uintptr_t* system, uint32_t* listed)
{
    if (!Owner(owner, system)) return 0;
    apc_map_clear(&g_rows);
    *listed = 0;
    if (!apc_need(*system + 32, g_leaseRows, sizeof g_leaseRows, "Native data unavailable")) return 0;
    for (uint32_t i = 0; i < LEASE_ROWS * 4; i += 4)
    {
        uint32_t low = g_leaseRows[i], high = g_leaseRows[i + 1], count = g_leaseRows[i + 2];
        if (low == 0 && high == 0) continue;
        if (g_leaseRows[i + 3] != 0) return apc_fail("Invalid package reference count");
        if (count == 0 || count >= 1000000) return apc_fail("Invalid package references");
        (void)apc_map_put(&g_rows, (uint64_t)high << 32 | low, count); /* 2048 slots for 1024 rows: never full */
        (*listed)++;
    }
    return 1;
}

static int SameOwner(const uint64_t a[2], const uint64_t b[2]) { return a[0] == b[0] && a[1] == b[1]; }

static uint64_t Count(uint64_t id)
{
    uint64_t count = 0;
    return apc_map_get(&g_rows, id, &count) ? count : 0;
}

int apc_native_valid_leases(const uint64_t* ids, int count, const uint64_t owner[2], int* valid)
{
    uint64_t current[2];
    uintptr_t system;
    uint32_t listed;
    if (!References(current, &system, &listed)) return 0;
    *valid = SameOwner(current, owner);
    for (int i = 0; *valid && i < count; i++) *valid = Count(ids[i]) != 0;
    return 1;
}

int apc_native_acquire(uint64_t id, const uint64_t owner[2], int* acquired)
{
    uint64_t current[2], check[2];
    uintptr_t system;
    uint32_t listed;
    *acquired = 0;
    if (!References(current, &system, &listed)) return 0;
    uint64_t count = Count(id);
    if (!SameOwner(current, owner) || (count == 0 && listed >= LEASE_LIMIT)) return 1;
    const uint64_t argument = id;
    g.acquire((void*)system, &argument, 1);
    if (!References(check, &system, &listed)) return 0;
    if (!SameOwner(check, owner) || Count(id) != count + 1) return apc_fail("Package acquire did not balance");
    *acquired = 1;
    return 1;
}

int apc_native_release(uint64_t id, const uint64_t owner[2], int* released)
{
    uint64_t current[2], check[2];
    uintptr_t system;
    uint32_t listed;
    *released = 0;
    if (!References(current, &system, &listed)) return 0;
    uint64_t count = Count(id);
    /* A reset manager has already retired its own package references. */
    if (!SameOwner(current, owner) || count == 0) return 1;
    const uint64_t argument = id;
    g.release((void*)system, &argument, 1);
    if (!References(check, &system, &listed)) return 0;
    if (!SameOwner(check, owner) || Count(id) != count - 1) return apc_fail("Package release did not balance");
    *released = 1;
    return 1;
}

/* ---- the catalogues -------------------------------------------------------------------------------------------- */

static int Kits(uintptr_t kp, uint32_t kc)
{
    static uint64_t pointers[1024];
    uint8_t row[48];
    if (!Read(kp, pointers, kc * 8u)) return 0;
    for (uint32_t i = 0; i < kc; i++)
    {
        if (!ApcPlausible(pointers[i])) return apc_fail("assertion failed!");
        if (!Read((uintptr_t)pointers[i], row, 48)) return 0;
        uint64_t id = ApcU64(row, 32);
        if (id != 0) (void)apc_map_put(&g_kits, ApcU32(row, 0), id); /* 2048 slots for at most 1024 kits */
    }
    return 1;
}

static int Presets(uintptr_t po, uint32_t pc)
{
    for (uint32_t first = 0; first < pc; first += 1024)
    {
        uint32_t n = pc - first < 1024 ? pc - first : 1024;
        if (!Read(po + 761060 + (uintptr_t)first * 24, g_buffer, n * 24u)) return 0;
        for (uint32_t i = 0; i < n; i++) (void)apc_map_put(&g_presets, ApcU32(g_buffer, i * 24 + 4), ApcU32(g_buffer, i * 24 + 8));
    }
    return 1;
}

/* The loadout package records: 1080 index rows {entity, record}, then 540 records with the package at +8. A row naming a
 * record past them (HellForge's own record for mod content) is skipped: its entity gets no package from us. */
static int Weapons(uintptr_t wt, uint32_t* skipped)
{
    static uint8_t records[540 * 32];
    *skipped = 0;
    if (!Read(wt, g_buffer, 1080 * 16) || !Read(wt + 17280, records, sizeof records)) return 0;
    for (uint32_t i = 0; i < 1080; i++)
    {
        uint64_t id = ApcU64(g_buffer, i * 16);
        uint32_t index = ApcU32(g_buffer, i * 16 + 8);
        if (id == 0) continue;
        if (index >= 540) { (*skipped)++; continue; }
        uint64_t package = ApcU64(records, index * 32 + 8);
        if (package != 0) (void)apc_map_put(&g_weapons, id, package); /* 2048 slots for 1080 rows */
    }
    return 1;
}

uint32_t apc_native_skipped(void) { return g.skipped; }

/* Rebuilt when the catalogues' identity changes. A rebuild that fails leaves none (the next one builds them again; the
 * Lua kept the half-built tables). */
static int Catalog(void)
{
    uintptr_t ko, po, wo, wt, kp;
    uint32_t kc = 0, pc = 0;
    if (!GamePointer(APC_RVA_KITS, &ko) || !GamePointer(APC_RVA_PRESETS, &po) || !GamePointer(APC_RVA_DATABASE, &wo)) return 0;
    if (!Pointer(wo + 0xF12558, &wt) || !Pointer(ko, &kp) || !Read(ko + 8, &kc, 4) || !Read(po + 7392, &pc, 4)) return 0;
    if (kc == 0 || kc > 1024 || pc == 0 || pc > 4096) return apc_fail("Catalogue bounds changed");
    uint64_t key[6] = {ko, kp, kc, po, pc, wt};
    if (g.has_catalog && memcmp(key, g.catalog, sizeof key) == 0) return 1;
    g.has_catalog = 0;
    apc_map_clear(&g_kits);
    apc_map_clear(&g_presets);
    apc_map_clear(&g_weapons);
    uint32_t skipped = 0;
    if (!Kits(kp, kc) || !Presets(po, pc) || !Weapons(wt, &skipped)) return 0;
    g.skipped = skipped;
    memcpy(g.catalog, key, sizeof key);
    g.has_catalog = 1;
    return 1;
}

static int Resolve(const ApcAssetItem* item, uint64_t* package)
{
    uint64_t preset;
    *package = 0;
    if (!g.has_catalog && !Catalog()) return 0;
    if (item->kind <= 1)
    {
        (void)apc_map_get(&g_weapons, item->id, package);
        return 1;
    }
    if (item->kind > 4 || item->id >> 32 != 0) return 1;
    if (apc_map_get(&g_presets, (uint32_t)item->id, &preset)) (void)apc_map_get(&g_kits, preset, package);
    return 1;
}

/* The item's package, then (weapons) its default and configured attachments' packages other than it. */
int apc_native_resolve_all(const ApcAssetItem* item, uint64_t* ids, int max, int* count)
{
    uint64_t base, packages[APC_ATTACHMENTS * 2];
    *count = 0;
    if (!Resolve(item, &base)) return 0;
    if (base == 0 || max < 1) return 1;
    ids[(*count)++] = base;
    if (item->kind > 1) return 1;
    int n = apc_deps_resolve(item, packages, APC_ATTACHMENTS * 2);
    for (int i = 0; i < n && *count < max; i++)
        if (packages[i] != base) ids[(*count)++] = packages[i];
    return 1;
}

/* ---- the snapshot ------------------------------------------------------------------------------------------------- */

static void Items(ApcAssetSnap* out)
{
    const uint8_t* h = g_manager;
    for (uint32_t card = 0; card < 6; card++)
    {
        uint32_t off = 1816 * card, state = ApcU32(h, off + 1832), count = ApcU32(h, off + 1836);
        for (uint32_t i = 0; state != 0 && i < count; i++)
        {
            uint32_t at = off + 32 + i * 120, kind = ApcU32(h, at + 100);
            uint64_t id = ApcU64(h, at + 24);
            if (kind > 4 || id == 0 || out->item_count >= APC_ITEMS) continue;
            ApcAssetItem* item = &out->items[out->item_count++];
            memset(item, 0, sizeof *item);
            item->kind = kind;
            item->id = id;
            item->finished = state == 8 || ApcU32(h, at + 104) == 4;
        }
    }
}

/* The thumbnail manager's requests (asserting its shape first). */
static int Manager(ApcAssetSnap* out, uint32_t* active)
{
    uintptr_t tm;
    if (!GamePointer(APC_RVA_GLOBALS, &tm) || !Read(tm, g_manager, sizeof g_manager)) return 0;
    if (ApcGamePointer(APC_RVA_GLOBALS) != tm || ApcU32(g_manager, 11052) != 7) return apc_fail("Thumbnail manager changed");
    *active = ApcU32(g_manager, 11064);
    if (*active != 0xFFFFFFFFu && *active >= 6) return apc_fail("Invalid thumbnail active card");
    for (uint32_t card = 0; card < 6; card++)
        if (ApcU32(g_manager, 1816 * card + 1832) > 8 || ApcU32(g_manager, 1816 * card + 1836) > 15)
            return apc_fail("Invalid thumbnail card");
    Items(out);
    return 1;
}

/* Briefing has its own controller: state 14 alone must not enable asset work during a controller teardown or an
 * unrelated transition. The menu is open when exactly one briefing controller is registered. */
static int Briefing(int* menu)
{
    uintptr_t dispatch = ApcGamePointer(APC_RVA_DISPATCH);
    uint32_t count = 0, matches = 0;
    if (!dispatch) return 1;
    if (!Read(dispatch + 5740, &count, 4)) return 0;
    if (count > 64) return apc_fail("UI dispatch bound changed");
    if (count > 0 && !Read(dispatch + 5744, g_buffer, count * 16u)) return 0;
    for (uint32_t i = 0; i < count; i++)
        if (ApcU32(g_buffer, i * 16 + 8) == 229 && ApcPointer(g_buffer, i * 16)) matches++;
    *menu = matches == 1;
    return 1;
}

static int Context(ApcAssetSnap* out, uint32_t* depth)
{
    uintptr_t sm, ui;
    uint32_t stack[6], blocked = 0;
    uint64_t world = 0;
    if (!Owner(out->owner, &out->system)) return 0;
    if (!GamePointer(APC_RVA_STATE_MACHINE, &sm) || !Read(sm + 0x429C, stack, 24)) return 0;
    *depth = stack[5];
    out->top = *depth >= 1 && *depth <= 5 ? (int32_t)stack[*depth - 1] : -1;
    if (!GamePointer(APC_RVA_UI, &ui) || !Read(ui + 15432, &world, 8) || !Read(ui + 15892, &blocked, 4)) return 0;
    out->has_world = ApcPlausible(world);
    out->world = out->has_world ? world : 0;
    out->blocked = blocked != 0;
    return 1;
}

/* The asset policy's view of the screen: the lease table's owner, the UI world, whether a thumbnail menu is open (or the
 * startup prefetch could run) and its requests. Gameplay states cannot show thumbnails or run startup prewarming: the
 * owner and world are kept so the policy can release old leases. lint: per-frame (a policy step) */
int apc_native_snapshot(ApcAssetSnap* out)
{
    uint32_t depth = 0, active = 0;
    memset(out, 0, offsetof(ApcAssetSnap, items));
    if (!Context(out, &depth)) return 0;
    if (out->top != 5 && out->top != 14 && depth != 0) return 1;
    if (!Manager(out, &active)) return 0;
    /* The transient UI flag toggles during normal thumbnail work: it is not a world-lifetime signal and never
     * invalidates held leases. */
    out->menu = out->top == 5 && out->has_world;
    if (out->top == 14 && out->has_world && !Briefing(&out->menu)) return 0;
    /* Global package leases need no thumbnail world. During the bounded startup window, an initialized UI world with an
     * empty state stack and an idle preview manager can warm dependencies before the Armory. */
    out->prefetch = out->has_world && depth == 0 && active == 0xFFFFFFFFu;
    out->active = active != 0xFFFFFFFFu;
    if (!out->menu && !out->prefetch) return 1;
    return Catalog() && apc_deps_refresh() && apc_deps_queued(out->items, out->item_count);
}
