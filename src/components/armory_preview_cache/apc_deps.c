/* Armory Preview Cache: weapon attachment packages (dependencies.lua, v23.1), build 25480438.
 *
 * A read-only reproduction of the game's default-attachment and package lookups: it never calls the allocating
 * configuration builders or edits preview slots. The attachment catalogue (up to 64 groups of rows, 8192 rows in all)
 * gives each attachment its package through the game's package map; each weapon configuration (component table 307 of
 * the entity state: 648 index rows, 324 configurations of 46600 bytes) gives its default attachment per slot kind. The
 * preview queue gives the attachments a queued weapon is shown with. Everything is rebuilt only when the catalogue's
 * identity (the definitions pointer, the group headers and the package map) changes.
 *
 * Bounds as in the Lua: 64 groups, 4096 rows per group, 8192 rows, 16 kinds per row, 324 configurations, with one
 * change for HellForge content: an index row naming a configuration past the Lua's 324 is skipped, not a failure of the
 * whole refresh (the Lua's "Weapon configuration index bounds"). Such a row is HellForge's own record for a mod's weapon
 * or entity (its copy of the table puts a mod's records after the vanilla 325); the Lua stopped every lease and image
 * while one was loaded. That weapon now has no defaults and is not a known weapon (its queued attachments are not
 * read), as a weapon the component does not know; every vanilla weapon keeps its dependencies. apc_deps_skipped counts
 * them. */
#include "apc.h"

#define ATTACHMENTS 8192
#define WEAPONS 648

typedef struct Attachment { uint64_t id, package; uint16_t kinds; } Attachment;
typedef struct Defaults { uint64_t weapon; uint8_t count; uint64_t ids[APC_ATTACHMENTS]; } Defaults;

static struct
{
    int has_identity;
    size_t identity_size;
    int attachment_count, default_count;
    uint32_t skipped;                    /* configuration rows past the Lua's bound in the last tables built */
} g;

static uint8_t g_identity[8 + 64 * 8 + 28 + 64 * 16];
static uint8_t g_next[sizeof g_identity];
static Attachment g_attachments[ATTACHMENTS];
static Defaults g_defaults[WEAPONS];
static uint8_t g_rows[256 * 88];
static uint8_t g_ring[8 + 128 * 200];
static uint8_t g_buckets[648 * 16];
APC_MAP(g_byNumber, 16384);   /* attachment number -> attachment */
APC_MAP(g_byHash, 16384);     /* attachment id -> attachment */
APC_MAP(g_byWeapon, 2048);    /* weapon id -> its defaults (the known weapons) */

void apc_deps_reset(void)
{
    memset(&g, 0, sizeof g);
    apc_map_clear(&g_byNumber);
    apc_map_clear(&g_byHash);
    apc_map_clear(&g_byWeapon);
}

static int Read(uintptr_t address, void* out, size_t size)
{
    if (size == 0 || size > 32768) return apc_fail("Dependency memory unavailable");
    return apc_need(address, out, size, "Dependency memory unavailable");
}

static int Pointer(uintptr_t address, uintptr_t* out)
{
    uint64_t value = 0;
    if (!Read(address, &value, 8)) return 0;
    if (!ApcPlausible(value)) return apc_fail("Dependency pointer unavailable");
    *out = (uintptr_t)value;
    return 1;
}

typedef struct Catalogue
{
    size_t identity_size;                /* of g_next */
    uintptr_t definitions, storage;
    uint32_t groups, count, multiplier;
    uint64_t empty;
    uint8_t headers[64][16];
} Catalogue;

/* Every group's header (rows pointer, count), appended to the identity. */
static int Headers(Catalogue* c, const uint8_t* groups, size_t at)
{
    for (uint32_t i = 0; i < c->groups; i++)
    {
        uintptr_t header = ApcPointer(groups, i * 8);
        if (!header) return apc_fail("assertion failed!");
        if (!Read(header, c->headers[i], 16)) return 0;
        if (ApcU32(c->headers[i], 8) > 4096) return apc_fail("Attachment row bounds");
        memcpy(g_next + at, c->headers[i], 16);
        at += 16;
    }
    c->identity_size = at;
    return 1;
}

/* The catalogue's identity: the definitions pointer, the group pointers, the package map and every group header. */
static int Identity(Catalogue* c)
{
    uintptr_t database = ApcGamePointer(APC_RVA_DATABASE);
    uint8_t map[28], groups[64 * 8];
    if (!database) return apc_fail("Dependency pointer unavailable");
    if (!Pointer(database + 0xF12E10, &c->definitions)) return 0;
    c->groups = vpm_game_u32(APC_RVA_GROUP_COUNT);
    if (c->groups == 0 || c->groups > 64) return apc_fail("Attachment group bounds");
    if (!vpm_game_read(APC_RVA_GROUPS, groups, c->groups * 8u) || !vpm_game_read(APC_RVA_PACKAGE_MAP, map, 28))
        return apc_fail("Dependency memory unavailable");
    c->storage = ApcPointer(map, 0);
    if (!c->storage) return apc_fail("assertion failed!");
    c->count = ApcU32(map, 8);
    c->empty = ApcU64(map, 16);
    c->multiplier = ApcU32(map, 24);
    if (c->count == 0 || c->count > 262144 || (c->count & (c->count - 1)) != 0) return apc_fail("Package mapping bounds");
    uint64_t definitions = c->definitions;
    memcpy(g_next, &definitions, 8);
    memcpy(g_next + 8, groups, c->groups * 8u);
    memcpy(g_next + 8 + c->groups * 8u, map, 28);
    return Headers(c, groups, 8 + c->groups * 8u + 28);
}

/* An attachment's package through the game's package map: a bounded lookup (256 probes), never an invented package. */
static int Package(const Catalogue* c, uint64_t id, uint64_t* package)
{
    uint64_t start = (id * (uint64_t)c->multiplier) % c->count;
    uint32_t probes = c->count < 256 ? c->count : 256;
    uint8_t row[16];
    *package = 0;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        if (!Read(c->storage + ((start + probe) % c->count) * 16, row, 16)) return 0;
        if (ApcU64(row, 0) == id) { *package = ApcU64(row, 8); return 1; }
        if (ApcU64(row, 0) == c->empty) return 1;
    }
    return 1;
}

static int Row(const Catalogue* c, const uint8_t* row)
{
    uint64_t id = ApcU64(row, 32);
    if (id == 0) return 1;
    uint32_t kinds = ApcU32(row, 56);
    if (kinds > 16) return apc_fail("Attachment kind bounds");
    Attachment* a = &g_attachments[g.attachment_count];
    memset(a, 0, sizeof *a);
    a->id = id;
    if (kinds > 0)
    {
        uint32_t values[16];
        uintptr_t list = ApcPointer(row, 48);
        if (!list) return apc_fail("assertion failed!");
        if (!Read(list, values, kinds * 4u)) return 0;
        for (uint32_t k = 0; k < kinds; k++)
            if (values[k] < 16) a->kinds |= (uint16_t)(1u << values[k]);
    }
    if (!Package(c, id, &a->package)) return 0;
    (void)apc_map_put(&g_byNumber, ApcU32(row, 8), (uint64_t)g.attachment_count); /* 16384 slots for 8192 rows */
    (void)apc_map_put(&g_byHash, id, (uint64_t)g.attachment_count);
    g.attachment_count++;
    return 1;
}

/* One group's rows, 256 per read. */
static int Group(const Catalogue* c, uintptr_t rows, uint32_t n)
{
    for (uint32_t first = 0; first < n; first += 256)
    {
        uint32_t amount = n - first < 256 ? n - first : 256;
        if (!Read(rows + (uintptr_t)first * 88, g_rows, amount * 88u)) return 0;
        for (uint32_t j = 0; j < amount; j++)
            if (!Row(c, g_rows + j * 88)) return 0;
    }
    return 1;
}

static int Attachments(const Catalogue* c)
{
    uint32_t total = 0;
    for (uint32_t i = 0; i < c->groups; i++)
    {
        uint32_t n = ApcU32(c->headers[i], 8);
        total += n;
        if (total > ATTACHMENTS) return apc_fail("Attachment catalogue bound");
        uintptr_t rows = n > 0 ? ApcPointer(c->headers[i], 0) : 0;
        if (n > 0 && !rows) return apc_fail("assertion failed!");
        if (!Group(c, rows, n)) return 0;
    }
    return 1;
}

static const Attachment* ByNumber(uint32_t number)
{
    uint64_t index;
    return apc_map_get(&g_byNumber, number, &index) ? &g_attachments[index] : NULL;
}

/* One weapon configuration's defaults: per slot kind 1..9 the configured attachment, else the kind's fallback when the
 * configuration allows the kind and the fallback fits it. */
/* The configured attachment per slot kind ({kind, number} pairs, until a kind outside 1..9), the first for a kind. */
static void Configured(const uint8_t* config, const Attachment** selected)
{
    for (int j = 0; j < 10; j++)
    {
        uint32_t kind = ApcU32(config, j * 8);
        if (kind < 1 || kind > 9) break;
        if (selected[kind] == NULL) selected[kind] = ByNumber(ApcU32(config, j * 8 + 4));
    }
}

/* The kinds the player may change (+80, until a 0). */
static void Allowed(const uint8_t* config, int* allowed)
{
    for (int j = 0; j < 10; j++)
    {
        uint32_t kind = ApcU32(config, 80 + j * 4);
        if (kind == 0) break;
        if (kind < 10) allowed[kind] = 1;
    }
}

static void Configuration(Defaults* d, const uint8_t* config, const uint8_t* fallback)
{
    const Attachment* selected[10] = {0};
    int allowed[10] = {0};
    Configured(config, selected);
    Allowed(config, allowed);
    for (int kind = 0; kind < 10; kind++)
    {
        if (selected[kind] != NULL || !allowed[kind]) continue;
        const Attachment* candidate = ByNumber(ApcU32(fallback, kind * 32));
        if (candidate != NULL && (candidate->kinds >> kind & 1u)) selected[kind] = candidate;
    }
    d->count = 0;
    for (int kind = 0; kind < 10; kind++)
        if (selected[kind] != NULL) d->ids[d->count++] = selected[kind]->id;
}

static int Configurations(const Catalogue* c, uint32_t* skipped)
{
    uint8_t fallback[320], config[120];
    if (!Read(c->definitions, g_buckets, sizeof g_buckets)) return 0;
    if (!vpm_game_read(APC_RVA_FALLBACK, fallback, sizeof fallback)) return apc_fail("Dependency memory unavailable");
    for (uint32_t i = 0; i < 648; i++)
    {
        uint64_t id = ApcU64(g_buckets, i * 16);
        if (id == 0) continue;
        uint32_t index = ApcU32(g_buckets, i * 16 + 8);
        if (index >= 324) { (*skipped)++; continue; } /* HellForge's own record for mod content: not ours to resolve */
        if (!Read(c->definitions + 10368 + (uintptr_t)index * 46600, config, sizeof config)) return 0;
        uint64_t at;
        if (!apc_map_get(&g_byWeapon, id, &at))
        {
            at = (uint64_t)g.default_count++;
            (void)apc_map_put(&g_byWeapon, id, at); /* 2048 slots for 648 rows */
        }
        g_defaults[at].weapon = id;
        Configuration(&g_defaults[at], config, fallback);
    }
    return 1;
}

/* Rebuilds the tables when the catalogue changed. A rebuild that fails leaves none (the next refresh builds them again;
 * the Lua kept the previous ones, which a rebuild of the same identity gives again). lint: per-frame (a policy step) */
int apc_deps_refresh(void)
{
    static Catalogue c;
    memset(&c, 0, sizeof c);
    if (!Identity(&c)) return 0;
    if (g.has_identity && g.identity_size == c.identity_size && memcmp(g_identity, g_next, c.identity_size) == 0) return 1;
    g.has_identity = 0;
    g.attachment_count = g.default_count = 0;
    apc_map_clear(&g_byNumber);
    apc_map_clear(&g_byHash);
    apc_map_clear(&g_byWeapon);
    uint32_t skipped = 0;
    if (!Attachments(&c) || !Configurations(&c, &skipped)) return 0;
    g.skipped = skipped;
    memcpy(g_identity, g_next, c.identity_size);
    g.identity_size = c.identity_size;
    g.has_identity = 1;
    return 1;
}

uint32_t apc_deps_skipped(void) { return g.skipped; }

static const Attachment* ByHash(uint64_t id)
{
    uint64_t index;
    return apc_map_get(&g_byHash, id, &index) ? &g_attachments[index] : NULL;
}

static int AddPackages(const uint64_t* ids, int count, uint64_t* packages, int n, int max)
{
    for (int i = 0; i < count && n < max; i++)
    {
        const Attachment* a = ByHash(ids[i]);
        int seen = 0;
        if (a == NULL || a->package == 0) continue;
        for (int j = 0; j < n; j++) seen |= packages[j] == a->package;
        if (!seen) packages[n++] = a->package;
    }
    return n;
}

int apc_deps_resolve(const ApcAssetItem* item, uint64_t* packages, int max)
{
    uint64_t at;
    int n = 0;
    if (apc_map_get(&g_byWeapon, item->id, &at)) n = AddPackages(g_defaults[at].ids, g_defaults[at].count, packages, n, max);
    if (item->has_attachments) n = AddPackages(item->attachments, item->attachment_count, packages, n, max);
    return n;
}

static void Queued(ApcAssetItem* items, int count, uint64_t weapon, const uint8_t* slots, uint32_t n)
{
    uint64_t attachments[APC_ATTACHMENTS] = {0};
    uint8_t found = 0;
    for (uint32_t j = 0; j < n; j++)
    {
        uint64_t a = ApcU64(slots, j * 8);
        int seen = 0;
        for (int k = 0; k < found; k++) seen |= attachments[k] == a;
        if (ByHash(a) != NULL && !seen) attachments[found++] = a;
    }
    uint64_t known;
    if (!apc_map_get(&g_byWeapon, weapon, &known)) return;
    for (int i = 0; i < count; i++)
    {
        if (items[i].id != weapon) continue;
        items[i].has_attachments = 1;
        items[i].attachment_count = found;
        memcpy(items[i].attachments, attachments, sizeof attachments);
    }
}

/* The weapons the preview queue holds and their configured attachments: each item's attachments (the queue's last row
 * for its weapon wins, as the Lua's table did). */
int apc_deps_queued(ApcAssetItem* items, int count)
{
    uintptr_t p = ApcGamePointer(APC_RVA_PREVIEW);
    if (!p) return apc_fail("Dependency pointer unavailable");
    if (!Read(p + 50448, g_ring, sizeof g_ring)) return 0;
    uint32_t head = ApcU32(g_ring, 0), tail = ApcU32(g_ring, 4);
    if (head >= 128 || tail >= 128) return apc_fail("Weapon queue bounds");
    for (; head != tail; head = (head + 1) % 128)
    {
        uint32_t o = 8 + head * 200, n = ApcU32(g_ring, o + 80);
        if (n > 10) return apc_fail("Weapon dependency count");
        Queued(items, count, ApcU64(g_ring, o + 64), g_ring + o + 88, n);
    }
    return 1;
}
