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
 * (kinds 2..4) through the kit presets and kits. The bounds the Lua checked stay: a catalogue outside them fails the
 * snapshot, as in the Lua. HellForge content can reach them (a record of its own in table 28 sits past the vanilla 541:
 * add_entity with own_all or model_from, or a weapon naming LoadoutPackageComponentData), and then the asset step waits
 * ("waiting_for_ui") while that content is loaded, as the Lua would. */
#include "apc.h"

#define LEASE_ROWS 1024
#define LEASE_LIMIT 1008

typedef void (*LeaseFn)(void* system, const uint64_t* ids, uint32_t count);

static const ApcSignature kSignatures[] = {
    {0, 0x12FE350u, "4585c00f8475010000415641574883ec38"},
    {0, 0x12FE361u, "48895c24504c8bfa48896c24584c8bf1488974246048897c24304c896424284c8d25b9244d024c896c24204c8d2d89254d02418be866660f1f840000000000418b560833c0498b37458b46184c0fafc6448d4aff85d27459498b0e0f1f40008bd84903d84923d948c1e3044803d94839330f84f7000000ffc03bc272e24d8b5e104c8bd133c0660f1f8400000000008bd84903d84923d948c1e3044903da488b0b493bcb740d483bce7408ffc03bc272de33db48893348c7430801000000488b15cade01024c8d05b38b0001488b7b08498bcc4c8bce488d4216493bc5480f42caba1600000048890da2de0102e8cdf41eff4c8b0596de0102488d0db71bfc00ffc04c8bcf4863d04903d04889157dde0102488d15f63ffc00e8819e430048837b08017514488b057b7e0202488bce488b5010ff92f00200004983c7084883ed010f85f8feffff4c8b6c24204c8b642428488b7c2430488b742460488b6c2458488b5c24504883c438415f415e"},
    {0, 0x12FE4CEu, "c3"},
    {0, 0x12FE4CFu, "48ff4308e947ffffff"},
    {0, 0x12FE4E0u, "4585c00f8460010000415641574883ec38"},
    {0, 0x12FE4F1u, "48895c24504c8bfa48896c24584c8bf148897424604c896424284c8d252e234d024c896c24204c8d2dfe234d0248897c2430418be866660f1f840000000000498b374885f60f84d9000000418b4e0833c0418b5618480fafd6448d49ff85c90f84bf0000004d8b060f1f80000000008bd84803da4923d948c1e3044903d8483933740bffc03bc172e6e996000000488b7b084885ff0f8489000000488b155ddd01024c8d05468a000148ffcf498bcc4c8bce48897b08488d4216493bc5480f42caba1600000048890d32dd0102e85df31eff4c8b0526dd0102488d0d471afc00ffc04c8bcf4863d04903d04889150ddd0102488d15163ffc00e8119d430048837b0800751f488bd6498bcee89f174300488b05007d0202488bce488b5010ff92000300004983c7084883ed010f850dffffff4c8b6c24204c8b642428488b7c2430488b742460488b6c2458488b5c24504883c438415f415e"},
    {0, 0x12FE649u, "c3"},
};

static struct
{
    LeaseFn acquire, release;
    int has_catalog;
    uint64_t catalog[6];                 /* kits, their pointers and count, presets and count, weapon table */
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

/* The loadout package records: 1080 index rows {entity, record}, then 540 records with the package at +8. */
static int Weapons(uintptr_t wt)
{
    static uint8_t records[540 * 32];
    if (!Read(wt, g_buffer, 1080 * 16) || !Read(wt + 17280, records, sizeof records)) return 0;
    for (uint32_t i = 0; i < 1080; i++)
    {
        uint64_t id = ApcU64(g_buffer, i * 16);
        if (id == 0) continue;
        uint32_t index = ApcU32(g_buffer, i * 16 + 8);
        if (index >= 540) return apc_fail("Weapon record bound changed");
        uint64_t package = ApcU64(records, index * 32 + 8);
        if (package != 0) (void)apc_map_put(&g_weapons, id, package); /* 2048 slots for 1080 rows */
    }
    return 1;
}

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
    if (!Kits(kp, kc) || !Presets(po, pc) || !Weapons(wt)) return 0;
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
