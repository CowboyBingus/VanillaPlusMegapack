/* Sentry Aim Retention: the sentries this machine controls, found and read (aim_data.lua's snapshot, its layout cache
 * and the idle gate M.idle), for build 25480438.
 *
 * The targeting registry ([game.dll + 0x3326D30]) lists every targeting entity; its pointer chunks are read whole, and
 * an entry is classified again only when its pointer changes and on every 30th check. A sentry this machine controls (one
 * of the seven sentry resources, entity record byte 20 & 3 == 1) is located once: its three map entries (targeting,
 * behavior, turret) must agree, its components must name the same entity, and a Gatling or machine gun also gets its
 * weapon, trigger and clock. The layout keeps every address and the guards (bytes that must still be where they were);
 * each check verifies them from what it read anyway (the windows) and refreshes the sentry's row in place.
 *
 * Reads at addresses inside game.dll's and the exe's images (the managers' roots, the clock root, the mission record's
 * pointer) are plain loads here (sar_load), where the Lua made a ReadProcessMemory each. */
#include <string.h>
#include "sentry_aim.h"

#define RVA_TARGETING 0x3326D30u /* the targeting manager */
#define RVA_BEHAVIOR 0x3326740u  /* the behavior manager */
#define RVA_TURRET 0x3326D70u    /* the turret manager */
#define RVA_WEAPON 0x3326CE0u    /* the weapon data manager */
#define RVA_TRIGGER 0x3326660u   /* the weapon trigger manager */
#define RVA_FACTION 0x3326CB8u   /* the faction manager: a target's unit */
#define RVA_CLOCK 0x3326348u     /* the native microsecond clock: its pointee + 24 */
#define RVA_MODE 0x33266A0u      /* the mission mode record (68 bytes) */
#define WRITABLE_RANGES 256
#define NO_INDEX 0xFFFFFFFFu

SarCache sar_cache;
SarEntries sar_entries;
SarLayout sar_layouts[SAR_MAX_SENTRIES];

/* Resource identity and BehaviorComponent defaults from this build's data; the angles are the fire gate's (degrees). */
const SarProfile sar_profiles[] = {
    {HF_ENTITY_GATLING_SENTRY, "Gatling", 213, 1, 16, 4},
    {HF_ENTITY_AMG43_MACHINE_GUN_SENTRY, "Machine gun", 312, 1, 14, 3},
    {HF_ENTITY_ALAS98_LASER_SENTRY, "Laser cannon", 308, 0, 0, 0},
    {HF_ENTITY_AMLS4X_ROCKET_SENTRY, "Rocket", 611, 0, 0, 0},
    {HF_ENTITY_AFLAM40_FLAME_SENTRY, "Flamethrower", 207, 0, 0, 0},
    {HF_ENTITY_AM12_MORTAR_SENTRY, "Mortar", 319, 0, 0, 0},
    {HF_ENTITY_AM23_EMS_MORTAR_SENTRY, "EMS mortar", 323, 0, 0, 0},
};
const int sar_profile_count = (int)(sizeof sar_profiles / sizeof sar_profiles[0]);

/* Ranges vpm_writable accepted since the targeting registry last changed. */
static struct { uintptr_t at[WRITABLE_RANGES]; size_t size[WRITABLE_RANGES]; int count, next; uint32_t queries; } g_writable;

/* ---- reads, guards and windows --------------------------------------------------------------------------------- */

uint32_t sar_u32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t U64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }
float sar_f32(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }
int sar_finite(double value) { return value == value && value < 100000.0 && value > -100000.0; }
int sar_same_bytes(const void* a, const void* b, size_t size) { return memcmp(a, b, size) == 0; }
static int Fail(const char** why, const char* text) { *why = text; return -1; }

static int Inside(uintptr_t base, size_t image, uintptr_t address, size_t size)
{
    return base != 0 && address >= base && size <= image && address - base <= image - size;
}

int sar_load(uintptr_t address, void* out, size_t size)
{
    if (Inside(vpm_game(), vpm_game_size(), address, size)) return vpm_game_read((uint32_t)(address - vpm_game()), out, size);
    if (Inside(vpm_exe(), vpm_exe_size(), address, size)) return vpm_exe_read((uint32_t)(address - vpm_exe()), out, size);
    return vpm_read(address, out, size);
}

uintptr_t sar_user_pointer(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull ? (uintptr_t)value : 0; }

void sar_guard_set(SarGuard* guard, uintptr_t at, const void* bytes, uint32_t size)
{
    guard->at = at;
    guard->size = size;
    memcpy(guard->bytes, bytes, size);
}

static void AddGuard(SarGuard* list, int* count, int max, uintptr_t at, const void* bytes, uint32_t size)
{
    if (*count < max) sar_guard_set(&list[(*count)++], at, bytes, size);
}

static int ReadHolds(const SarGuard* guard)
{
    uint8_t now[20];
    return sar_load(guard->at, now, guard->size) && memcmp(now, guard->bytes, guard->size) == 0;
}

/* 1 or 0 when a window holds the guard's range, SAR_UNKNOWN otherwise. */
static int Covered(const SarWindow* windows, int count, const SarGuard* guard)
{
    for (int k = 0; k < count; k++)
    {
        if (guard->at < windows[k].at) continue;
        uintptr_t offset = guard->at - windows[k].at;
        if (offset + guard->size <= windows[k].size) return memcmp(windows[k].bytes + offset, guard->bytes, guard->size) == 0;
    }
    return SAR_UNKNOWN;
}

int sar_verified(const SarGuard* guards, int count, const SarWindow* windows, int window_count)
{
    for (int k = 0; k < count; k++)
    {
        int same = Covered(windows, window_count, &guards[k]);
        if (same == SAR_UNKNOWN) same = ReadHolds(&guards[k]);
        if (!same) return 0;
    }
    return 1;
}

int sar_matches(const SarGuard* guards, int count)
{
    for (int k = 0; k < count; k++)
        if (!ReadHolds(&guards[k])) return 0;
    return 1;
}

/* Bytes this check read at an address. copy: they live in a buffer the check may reuse, so the window keeps its own. */
static void AddWindow(uintptr_t at, const uint8_t* bytes, uint32_t size, int copy)
{
    SarWindows* w = &sar_cache.windows;
    if (w->count >= SAR_MAX_WINDOWS) return; /* a guard outside every window is read instead */
    if (copy)
    {
        if (size > SAR_ARENA - w->used) return;
        memcpy(w->arena + w->used, bytes, size);
        bytes = w->arena + w->used;
        w->used += size;
    }
    w->at[w->count++] = (SarWindow){at, size, bytes};
}

/* ---- writable ranges ------------------------------------------------------------------------------------------- */

int sar_writable(uintptr_t at, size_t size)
{
    for (int i = 0; i < g_writable.count; i++)
        if (at >= g_writable.at[i] && size <= g_writable.size[i] && at - g_writable.at[i] <= g_writable.size[i] - size) return 1;
    g_writable.queries++;
    if (!vpm_writable(at, size)) return 0;
    g_writable.at[g_writable.next] = at;
    g_writable.size[g_writable.next] = size;
    g_writable.next = (g_writable.next + 1) % WRITABLE_RANGES;
    if (g_writable.count < WRITABLE_RANGES) g_writable.count++;
    return 1;
}

void sar_writable_forget(void) { g_writable.count = g_writable.next = 0; }
uint32_t sar_writable_queries(void) { return g_writable.queries; }

/* ---- the cache --------------------------------------------------------------------------------------------------- */

static void FreeLayout(uint32_t i)
{
    if (sar_entries.layout[i] != 0) sar_layouts[sar_entries.layout[i] - 1].used = 0;
    sar_entries.layout[i] = 0;
}

/* forget(c, from): entries from `from` on are new. All of them: a new mission, so its memory is checked again too. */
static void Forget(uint32_t from)
{
    for (uint32_t i = from; i < sar_cache.active; i++)
    {
        FreeLayout(i);
        sar_entries.known[i] = 0;
        sar_entries.klass[i] = SAR_CLASS_UNKNOWN;
        sar_entries.pointer[i] = 0;
        sar_entries.address[i] = 0;
    }
    sar_cache.active = from;
    if (from == 0) sar_writable_forget();
}

void sar_cache_reset(void)
{
    Forget(0);
    memset(&sar_cache, 0, sizeof sar_cache);
}

void sar_layout_start(void)
{
    memset(&sar_cache, 0, sizeof sar_cache);
    memset(&sar_entries, 0, sizeof sar_entries);
    memset(sar_layouts, 0, sizeof sar_layouts);
    memset(&g_writable, 0, sizeof g_writable);
}

static void NewCache(void)
{
    memset(&sar_cache, 0, sizeof sar_cache);
    sar_cache.exists = 1;
    sar_cache.outside = SAR_UNKNOWN;
}

/* A pointer kept while its bytes are unchanged: 1, or -1 when new bytes are no user-mode pointer. */
static int Keep(int* have, uint64_t* word, uintptr_t* kept, uint64_t value, const char** why)
{
    if (*have && *word == value) return 1;
    uintptr_t pointer = sar_user_pointer(value);
    if (pointer == 0) return Fail(why, "Runtime pointer unavailable");
    *have = 1;
    *word = value;
    *kept = pointer;
    return 1;
}

/* ---- the registries of one check -------------------------------------------------------------------------------- */

/* The pointer chunks of this check, read in place: chunk n holds entries n*256 .. n*256+255. */
static int ReadChunks(SarCache* c, uint32_t active, const char** why)
{
    c->chunks = (active - 1) / 256;
    for (uint32_t n = 0; n <= c->chunks; n++)
    {
        uint32_t first = n * 256, entries = active - first < 256 ? active - first : 256;
        c->chunk_size[n] = entries * 8;
        if (!sar_load(c->ep + 8u * first, c->chunk[n], c->chunk_size[n])) return Fail(why, "Runtime read unavailable");
    }
    return 1;
}

/* This check's targeting registry: 1 (*active entries), 0 none (or empty), -1 failed. */
static int Targeting(SarCache* c, uint32_t* active, const char** why)
{
    c->windows.count = 0;
    c->windows.used = 0;
    c->strings = 0;
    c->reg = SAR_UNKNOWN;
    if (!vpm_game_read(RVA_TARGETING, c->root, 8)) return Fail(why, "Runtime read unavailable");
    if (U64(c->root) == 0) return 0;
    if (Keep(&c->have_tm, &c->tm_word, &c->tm, U64(c->root), why) < 0) return -1;
    c->th = c->tm + 308;
    if (!sar_load(c->th, c->head, 84)) return Fail(why, "Runtime read unavailable");
    uint32_t cap = sar_u32(c->head), total = sar_u32(c->head + 12);
    *active = sar_u32(c->head + 16);
    if (!(*active <= total && total <= cap && cap <= SAR_MAX_ENTRIES)) return Fail(why, "Unsupported targeting registry");
    if (*active == 0) return 0;
    if (Keep(&c->have_ep, &c->ep_word, &c->ep, U64(c->head + 52), why) < 0) return -1;
    return ReadChunks(c, *active, why);
}

/* The targeting root, header and chunks as windows, once per check, when the first sentry needs them. */
static void Materialize(SarCache* c)
{
    if (c->strings) return;
    c->strings = 1;
    AddWindow(vpm_game() + RVA_TARGETING, c->root, 8, 0);
    AddWindow(c->th, c->head, 84, 0);
    for (uint32_t n = 0; n <= c->chunks; n++) AddWindow(c->ep + 2048u * n, (const uint8_t*)c->chunk[n], c->chunk_size[n], 0);
}

static int CheckRegistries(SarCache* c, const char** why)
{
    if (!(sar_u32(c->rh_bytes + 16) <= sar_u32(c->rh_bytes + 12) && sar_u32(c->rh_bytes + 12) <= sar_u32(c->rh_bytes) &&
            sar_u32(c->rh_bytes) <= 4096))
        return Fail(why, "Unsupported turret registry");
    if (sar_u32(c->bh_bytes) > 16384) return Fail(why, "Unsupported behavior registry");
    if (Keep(&c->have_rt, &c->rt_word, &c->rt, U64(c->head + 68), why) < 0) return -1;
    return Keep(&c->have_nt, &c->nt_word, &c->nt, U64(c->head + 76), why);
}

/* The behavior and turret registries of this check, read once, when a sentry needs them: 1, 0 a root is empty, -1. */
static int Components(SarCache* c, const char** why)
{
    Materialize(c);
    if (c->reg != SAR_UNKNOWN) return c->reg;
    if (!vpm_game_read(RVA_BEHAVIOR, c->bm_root, 8) || !vpm_game_read(RVA_TURRET, c->rm_root, 8))
        return Fail(why, "Runtime read unavailable");
    AddWindow(vpm_game() + RVA_BEHAVIOR, c->bm_root, 8, 0);
    AddWindow(vpm_game() + RVA_TURRET, c->rm_root, 8, 0);
    if (U64(c->bm_root) == 0 || U64(c->rm_root) == 0) return c->reg = 0;
    if (Keep(&c->have_bm, &c->bm_word, &c->bm, U64(c->bm_root), why) < 0) return -1;
    if (Keep(&c->have_rm, &c->rm_word, &c->rm, U64(c->rm_root), why) < 0) return -1;
    c->bh = c->bm + 32;
    c->rh = c->rm + 8;
    if (!sar_load(c->rh, c->rh_bytes, 88)) return Fail(why, "Runtime read unavailable");
    AddWindow(c->rh, c->rh_bytes, 88, 0);
    if (!sar_load(c->bh, c->bh_bytes, 80)) return Fail(why, "Runtime read unavailable");
    AddWindow(c->bh, c->bh_bytes, 80, 0);
    if (CheckRegistries(c, why) < 0) return -1;
    return c->reg = 1;
}

/* ---- locating a sentry ------------------------------------------------------------------------------------------- */

typedef struct GuardList { SarGuard* at; int* count; int max; } GuardList;

/* An entity's index in a native hash map: 1 (*index), 0 absent, -1 failed. On a hit the header and the slot become
 * guards. */
static int Lookup(uintptr_t manager, uint32_t offset, uint32_t id, uint32_t limit, GuardList guards, uint32_t* index,
    const char** why)
{
    uint8_t h[20], row[8];
    if (!sar_load(manager + offset, h, 20)) return Fail(why, "Runtime read unavailable");
    uint32_t cap = sar_u32(h + 8);
    if (cap == 0) return 0;
    if (cap > limit || (cap & (cap - 1)) != 0) return Fail(why, "Unsupported entity map");
    uintptr_t data = sar_user_pointer(U64(h));
    if (data == 0) return Fail(why, "Runtime pointer unavailable");
    uint32_t empty = sar_u32(h + 12), product = id * sar_u32(h + 16), probes = cap < 128 ? cap : 128;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        uintptr_t at = data + 8u * ((product + probe) & (cap - 1));
        if (!sar_load(at, row, 8)) return Fail(why, "Runtime read unavailable");
        if (sar_u32(row) == id)
        {
            AddGuard(guards.at, guards.count, guards.max, manager + offset, h, 20);
            AddGuard(guards.at, guards.count, guards.max, at, row, 8);
            *index = sar_u32(row + 4);
            return 1;
        }
        if (sar_u32(row) == empty) return 0;
    }
    return Fail(why, "Entity map probe bound exceeded");
}

/* A component's address in a native array of stride-byte entries, and its first size bytes; the array pointer becomes a
 * guard. 1, or -1. */
typedef struct Array { uintptr_t manager; uint32_t offset, index, stride; } Array;
static int Component(Array a, uint32_t size, GuardList guards, uintptr_t* address, uint8_t* bytes, const char** why)
{
    uint8_t b[8];
    if (!sar_load(a.manager + a.offset, b, 8)) return Fail(why, "Runtime read unavailable");
    uintptr_t array = sar_user_pointer(U64(b));
    if (array == 0) return Fail(why, "Runtime pointer unavailable");
    AddGuard(guards.at, guards.count, guards.max, a.manager + a.offset, b, 8);
    *address = array + (uintptr_t)a.index * a.stride;
    return sar_load(*address, bytes, size) ? 1 : Fail(why, "Runtime read unavailable");
}

/* The roots, the registry's array pointers, the entity pointer and the entity's identity bytes. */
static void EntityGuards(const SarCache* c, SarRow* s, uint32_t index, uint64_t pointer)
{
    GuardList g = {s->guards, &s->guard_count, SAR_ROW_GUARDS};
    uintptr_t game = vpm_game();
    AddGuard(g.at, g.count, g.max, game + RVA_TARGETING, c->root, 8);
    AddGuard(g.at, g.count, g.max, game + RVA_BEHAVIOR, c->bm_root, 8);
    AddGuard(g.at, g.count, g.max, game + RVA_TURRET, c->rm_root, 8);
    AddGuard(g.at, g.count, g.max, c->tm + 360, c->head + 52, 8);
    AddGuard(g.at, g.count, g.max, c->tm + 376, c->head + 68, 8);
    AddGuard(g.at, g.count, g.max, c->tm + 384, c->head + 76, 8);
    AddGuard(g.at, g.count, g.max, c->ep + 8u * index, &pointer, 8);
    AddGuard(g.at, g.count, g.max, s->entity, s->key, 20);
}

/* The weapon, trigger and clock of a Gatling or machine gun (locate_fire). 1, or -1. */
static int FireNodes(SarLayout* L, GuardList g, uintptr_t wm, const char** why)
{
    SarRow* s = &L->row;
    uint32_t wi;
    uint8_t we[8], record[228], mode[12];
    uintptr_t at, wr;
    int r = Lookup(wm, 48, s->id, 32768, g, &wi, why);
    if (r < 0) return -1;
    if (r == 0 || wi == NO_INDEX || wi >= 16384) return Fail(why, "Weapon data unavailable");
    if (Component((Array){wm, 72, wi, 8}, 8, g, &at, we, why) < 0) return -1;
    if (U64(we) != L->pointer) return Fail(why, "Weapon identity mismatch");
    if (Component((Array){wm, 88, wi, 1008}, 228, g, &wr, record, why) < 0) return -1;
    if (Component((Array){wm, 96, wi, 12}, 12, g, &s->fire.mode_address, mode, why) < 0) return -1;
    L->fire.count = sar_u32(record + 216);
    if (L->fire.count == 0 || L->fire.count > 24) return Fail(why, "Invalid sentry fire nodes");
    for (uint32_t i = 0; i < L->fire.count; i++) L->fire.nodes[i] = sar_u32(record + 120 + 4 * i);
    L->fire.node_address = wr + 216;
    s->fire.manager = wm;
    L->fire.wm_header = wm + 48;
    return 1;
}

static int FireTrigger(SarLayout* L, GuardList g, const char** why)
{
    SarRow* s = &L->row;
    uint64_t wm = vpm_game_u64(RVA_WEAPON), cmb = vpm_game_u64(RVA_TRIGGER);
    AddGuard(g.at, g.count, g.max, vpm_game() + RVA_WEAPON, &wm, 8);
    uintptr_t cm = sar_user_pointer(cmb);
    if (cm == 0) return Fail(why, "Runtime pointer unavailable");
    AddGuard(g.at, g.count, g.max, vpm_game() + RVA_TRIGGER, &cmb, 8);
    uint32_t ci;
    uint8_t triggers[8];
    int r = Lookup(cm, 40, s->id, 32768, g, &ci, why);
    if (r < 0) return -1;
    if (r == 0 || ci == NO_INDEX || ci >= 16384) return Fail(why, "Weapon trigger unavailable");
    if (!sar_load(cm + 88, triggers, 8)) return Fail(why, "Runtime read unavailable");
    AddGuard(g.at, g.count, g.max, cm + 88, triggers, 8);
    L->fire.cm_header = cm + 40;
    uintptr_t clock = sar_user_pointer(L->fire.clock_root), array = sar_user_pointer(U64(triggers));
    if (clock == 0 || array == 0) return Fail(why, "Runtime pointer unavailable");
    L->fire.clock_address = clock + 24;
    L->fire.trigger_address = array + ci;
    return 1;
}

static int LocateFire(SarLayout* L, const char** why)
{
    SarRow* s = &L->row;
    GuardList g = {s->fire.guards, &s->fire.guard_count, SAR_FIRE_GUARDS};
    L->fire.clock_root = vpm_game_u64(RVA_CLOCK);
    sar_guard_set(&s->selection.guard, vpm_game() + RVA_CLOCK, &L->fire.clock_root, 8);
    uintptr_t wm = sar_user_pointer(vpm_game_u64(RVA_WEAPON));
    if (wm == 0) return Fail(why, "Runtime pointer unavailable");
    if (FireNodes(L, g, wm, why) < 0 || FireTrigger(L, g, why) < 0) return -1;
    s->has_fire = 1;
    s->fire.unit = sar_u32(s->key + 12);
    s->fire.pause = s->profile->pause;
    s->fire.resume = s->profile->resume;
    s->fire.terrain_blocked = SAR_UNKNOWN;
    s->selection.address = s->behavior_address + 152;
    return 1;
}

/* The row's fixed fields, from the located components. */
static void RowAddresses(const SarCache* c, SarLayout* L, uintptr_t ba, uintptr_t ca)
{
    static const uint8_t zero[4] = {0};
    SarRow* s = &L->row;
    L->runtime_address = c->rt + 208u * L->index;
    L->network_address = c->nt + 24u * L->index;
    s->behavior_address = ba;
    s->transition_address = ba + 8;
    s->authority_address = s->entity + 20;
    s->raw_address = L->runtime_address + 8;
    s->computed_address = L->runtime_address + 20;
    s->flags_address = L->network_address + 16;
    s->control_address = ca;
    s->transition_count = 4;
    sar_guard_set(&s->transition[0], ba + 8, zero, 4);
    sar_guard_set(&s->transition[1], ba + 24, zero, 4);
    sar_guard_set(&s->transition[2], ba + 96, zero, 4);
    sar_guard_set(&s->transition[3], ba + 120, zero, 1);
}

/* The three map entries: 1 they agree, 0 not (the sentry is not located), -1 failed. */
static int MapEntries(const SarCache* c, SarLayout* L, uint32_t* bi, uint32_t* ri, const char** why)
{
    SarRow* s = &L->row;
    GuardList g = {s->guards, &s->guard_count, SAR_ROW_GUARDS};
    uint32_t ti = NO_INDEX;
    int ht = Lookup(c->tm, 336, s->id, 16384, g, &ti, why);
    if (ht < 0) return -1;
    int hb = Lookup(c->bm, 64, s->id, 32768, g, bi, why);
    if (hb < 0) return -1;
    int hr = Lookup(c->rm, 40, s->id, 8192, g, ri, why);
    if (hr < 0) return -1;
    if (!ht || ti != L->index || !hb || !hr || *bi == NO_INDEX || *ri == NO_INDEX) return 0;
    if (!(*bi < sar_u32(c->bh_bytes) && *ri < sar_u32(c->rh_bytes + 12))) return Fail(why, "Component index out of range");
    return 1;
}

static int LocateComponents(const SarCache* c, SarLayout* L, const char** why)
{
    SarRow* s = &L->row;
    GuardList g = {s->guards, &s->guard_count, SAR_ROW_GUARDS};
    uint32_t bi = 0, ri = 0;
    uint8_t be[8], re[8];
    uintptr_t at, ba, ca;
    int r = MapEntries(c, L, &bi, &ri, why);
    if (r <= 0) return r;
    if (Component((Array){c->bm, 88, bi, 8}, 8, g, &at, be, why) < 0) return -1;
    if (Component((Array){c->rm, 64, ri, 8}, 8, g, &at, re, why) < 0) return -1;
    if (U64(be) != L->pointer || U64(re) != L->pointer) return Fail(why, "Component identity mismatch");
    if (Component((Array){c->bm, 96, bi, 504}, 160, g, &ba, L->behavior, why) < 0) return -1;
    if (Component((Array){c->rm, 88, ri, 16}, 16, g, &ca, L->control, why) < 0) return -1;
    RowAddresses(c, L, ba, ca);
    return 1;
}

static int FreeSlot(void)
{
    for (int k = 0; k < SAR_MAX_SENTRIES; k++)
        if (!sar_layouts[k].used) return k;
    return -1;
}

/* The layout of a sentry this machine controls whose three map entries agree: 1 (*out), 0 not located, -1 failed. */
static int Locate(const SarCache* c, uint32_t i, const SarProfile* profile, uintptr_t address, SarLayout** out,
    const char** why)
{
    int slot = FreeSlot();
    if (slot < 0) return 0; /* more sentries than slots: this one stays vanilla until one frees */
    SarLayout* L = &sar_layouts[slot];
    memset(L, 0, sizeof *L);
    L->index = i;
    L->pointer = sar_entries.pointer[i];
    L->address = address;
    SarRow* s = &L->row;
    s->id = sar_u32(c->entity + 8);
    memcpy(s->key, c->entity, 20);
    s->profile = profile;
    s->entity = address;
    s->fire.terrain_blocked = SAR_UNKNOWN;
    EntityGuards(c, s, i, L->pointer);
    int r = LocateComponents(c, L, why);
    if (r > 0 && profile->fire_gate) r = LocateFire(L, why);
    if (r <= 0) return r;
    L->used = 1;
    sar_entries.layout[i] = (uint8_t)(slot + 1);
    *out = L;
    vpm_log_detail(sar_state.self, "located %s sentry %u (targeting entry %u): entity 0x%llX, behavior 0x%llX, aim 0x%llX, "
        "runtime 0x%llX, weapon manager 0x%llX", profile->name, s->id, i, (unsigned long long)s->entity,
        (unsigned long long)s->behavior_address, (unsigned long long)s->raw_address, (unsigned long long)L->runtime_address,
        (unsigned long long)s->fire.manager);
    return 1;
}

/* ---- refreshing a located sentry --------------------------------------------------------------------------------- */

static int CheckComponents(const SarLayout* L, const char** why)
{
    if (sar_u32(L->behavior) != L->row.profile->behavior) return Fail(why, "Unsupported sentry behavior");
    if (L->behavior[120] > 1 || L->control[0] > 1) return Fail(why, "Unsupported component flags");
    for (int k = 2; k <= 7; k++)
        if (!sar_finite(sar_f32(L->runtime + 4 * k))) return Fail(why, "Invalid aim vector");
    for (int k = 7; k <= 9; k++)
        if (!sar_finite(sar_f32(L->behavior + 4 * k))) return Fail(why, "Invalid aim vector");
    for (int k = 2; k <= 3; k++)
    {
        double speed = sar_f32(L->control + 4 * k);
        if (!sar_finite(speed) || speed < 0 || speed > 1000) return Fail(why, "Invalid turret speeds");
    }
    return 1;
}

static void Decode(SarLayout* L)
{
    SarRow* s = &L->row;
    s->node = sar_u32(L->behavior + 8);
    s->target = sar_u32(L->behavior + 24);
    s->source_flags = sar_u32(L->behavior + 96);
    s->has = L->behavior[120] == 1;
    memcpy(s->point, L->behavior + 28, 12);
    s->runtime_target = sar_u32(L->runtime);
    memcpy(s->raw, L->runtime + 8, 12);
    memcpy(s->computed, L->runtime + 20, 12);
    s->flags = sar_u32(L->network + 16);
    memcpy(s->horizontal, L->control + 8, 4);
    memcpy(s->vertical, L->control + 12, 4);
    s->enabled = L->control[0] == 1;
    memcpy(s->transition[0].bytes, L->behavior + 8, 4);
    memcpy(s->transition[1].bytes, L->behavior + 24, 4);
    memcpy(s->transition[2].bytes, L->behavior + 96, 4);
    s->transition[3].bytes[0] = L->behavior[120];
}

/* The target's unit, so its collision surface is not mistaken for terrain (locate_target): 1, 0 none, -1. */
static int LocateTarget(SarLayout* L, uint32_t id, const char** why)
{
    SarGuard scratch[2];
    int n = 0;
    GuardList g = {scratch, &n, 2};
    uint32_t fi = NO_INDEX;
    uint8_t b[8], target[20];
    uintptr_t fm = sar_user_pointer(vpm_game_u64(RVA_FACTION));
    if (fm == 0) return Fail(why, "Runtime pointer unavailable");
    int r = Lookup(fm, 73808, id, 131072, g, &fi, why);
    if (r <= 0 || fi == NO_INDEX) return r < 0 ? -1 : 0;
    if (fi >= 16384) return Fail(why, "Target faction index out of range");
    if (!sar_load(fm + 73832, b, 8)) return Fail(why, "Runtime read unavailable");
    uintptr_t slots = sar_user_pointer(U64(b));
    if (slots == 0) return Fail(why, "Runtime pointer unavailable");
    if (!sar_load(slots + 8u * fi, b, 8)) return Fail(why, "Runtime read unavailable");
    uintptr_t address = sar_user_pointer(U64(b));
    if (address == 0) return Fail(why, "Runtime pointer unavailable");
    if (!sar_load(address, target, 20)) return Fail(why, "Runtime read unavailable");
    if (sar_u32(target + 8) != id) return Fail(why, "Target identity changed");
    L->has_target = 1;
    L->target_id = id;
    L->target_unit = sar_u32(target + 12);
    sar_guard_set(&L->target_guard, address, target, 20);
    return 1;
}

static int FireFields(SarLayout* L, const char** why)
{
    SarRow* s = &L->row;
    uint32_t index[2], network[3], clock[2];
    uint8_t trigger;
    if (!sar_load(L->fire.node_address, index, 8)) return Fail(why, "Runtime read unavailable");
    if (!(index[0] == L->fire.count && index[1] < index[0])) return Fail(why, "Invalid sentry fire nodes");
    if (!sar_load(s->fire.mode_address, network, 12) || !sar_load(L->fire.trigger_address, &trigger, 1) ||
        !sar_load(L->fire.clock_address, clock, 8))
        return Fail(why, "Runtime read unavailable");
    uint32_t node = L->fire.nodes[index[1]];
    if (!(node < 1024 && network[0] <= 8)) return Fail(why, "Invalid sentry weapon state");
    if (trigger > 1) return Fail(why, "Invalid sentry trigger");
    s->fire.node = node;
    s->fire.mode = network[0];
    s->fire.trigger = trigger == 1;
    s->fire.has_target_unit = 0;
    s->fire.has_pose = 0;
    s->fire.terrain_blocked = SAR_UNKNOWN;
    memcpy(s->selection.deadline, L->behavior + 152, 8);
    s->selection.now = (double)clock[0] + (double)clock[1] * 4294967296.0;
    return 1;
}

/* The target is located once per target; prepare_fire checks its guard around the terrain query and marks it stale
 * when it no longer holds. 1, or -1. */
static int TargetUnit(SarLayout* L, const char** why)
{
    SarRow* s = &L->row;
    if (s->fire.target_stale) { L->has_target = 0; s->fire.target_stale = 0; }
    if (s->target == 0 || s->runtime_target != s->target) return 1;
    if (!(L->has_target && L->target_id == s->target))
    {
        L->has_target = 0;
        if (LocateTarget(L, s->target, why) < 0) return -1;
    }
    if (!L->has_target) return 1;
    s->fire.has_target_unit = 1;
    s->fire.target_unit = L->target_unit;
    s->fire.target_guard = L->target_guard;
    return 1;
}

/* The fire fields: 1, 0 the weapon or trigger moved (the sentry is located again), -1 failed. */
static int RefreshFire(SarCache* c, SarLayout* L, const char** why)
{
    SarRow* s = &L->row;
    int wh = sar_load(L->fire.wm_header, L->wm_header, 56), ch = sar_load(L->fire.cm_header, L->cm_header, 56);
    if (!wh || !ch) return 0;
    AddWindow(L->fire.wm_header, L->wm_header, 56, 1);
    AddWindow(L->fire.cm_header, L->cm_header, 56, 1);
    if (!sar_verified(s->fire.guards, s->fire.guard_count, c->windows.at, c->windows.count)) return 0;
    if (vpm_game_u64(RVA_CLOCK) != L->fire.clock_root) return 0;
    if (FireFields(L, why) < 0) return -1;
    return TargetUnit(L, why);
}

/* Reads the live components into the layout's buffers and decodes its row: 1, 0 moved, -1 failed. */
static int Refresh(SarCache* c, SarLayout* L, const char** why)
{
    SarRow* s = &L->row;
    if (!sar_load(s->behavior_address, L->behavior, 160) || !sar_load(s->control_address, L->control, 16) ||
        !sar_load(L->runtime_address, L->runtime, 32) || !sar_load(L->network_address, L->network, 24))
        return Fail(why, "Runtime read unavailable");
    if (CheckComponents(L, why) < 0) return -1;
    Decode(L);
    return s->has_fire ? RefreshFire(c, L, why) : 1;
}

/* ---- the check --------------------------------------------------------------------------------------------------- */

static const SarProfile* ProfileOf(const uint8_t* entity)
{
    uint64_t resource = U64(entity);
    for (int k = 0; k < sar_profile_count; k++)
        if (sar_profiles[k].resource == resource) return &sar_profiles[k];
    return NULL;
}

/* Entry i whose pointer changed (or a rescan): its class, and its layout when it is a sentry this machine controls. */
static int Classify(SarCache* c, uint32_t i, SarLayout** out, const char** why)
{
    *out = NULL;
    uintptr_t address = sar_entries.address[i];
    if (address == 0)
    {
        address = sar_user_pointer(sar_entries.pointer[i]);
        if (address == 0) return Fail(why, "Runtime pointer unavailable");
        sar_entries.address[i] = address;
    }
    if (!sar_load(address, c->entity, 24)) return Fail(why, "Runtime read unavailable");
    const SarProfile* profile = ProfileOf(c->entity);
    int ours = profile != NULL && (c->entity[20] & 3) == 1;
    sar_entries.klass[i] = ours ? SAR_CLASS_TRUE : SAR_CLASS_FALSE;
    if (!ours) return 0;
    int r = Components(c, why);
    return r <= 0 ? r : Locate(c, i, profile, address, out, why);
}

/* A kept layout still valid this check: the same identity and authority, and every guard holds. 1, 0, -1. */
static int Current(SarCache* c, SarLayout* L, const char** why)
{
    if (!sar_load(L->address, L->entity, 24)) return 0;
    AddWindow(L->address, L->entity, 24, 1);
    if ((L->entity[20] & 3) != 1) { sar_entries.klass[L->index] = SAR_CLASS_FALSE; return 0; }
    int r = Components(c, why);
    if (r <= 0) return r;
    return sar_verified(L->row.guards, L->row.guard_count, c->windows.at, c->windows.count);
}

/* The row of entry i (*row, or NULL): a kept layout while it holds, otherwise the entry is classified again. */
static int EntryRow(SarCache* c, uint32_t i, int moved, SarRow** row, const char** why)
{
    *row = NULL;
    SarLayout* L = sar_entries.layout[i] ? &sar_layouts[sar_entries.layout[i] - 1] : NULL;
    if (L != NULL && !moved)
    {
        int r = Current(c, L, why);
        if (r > 0) r = Refresh(c, L, why);
        if (r < 0) return -1;
        if (r > 0) { *row = &L->row; return 1; }
    }
    FreeLayout(i);
    if (Classify(c, i, &L, why) < 0) return -1;
    if (L == NULL) return 0;
    int r = Refresh(c, L, why);
    if (r <= 0) return r < 0 ? -1 : Fail(why, "Sentry changed while located");
    *row = &L->row;
    return 1;
}

/* One targeting entry: 1 while it is not classified as something else (a sentry, or one not yet settled), 0 otherwise. */
static int Visit(SarCache* c, uint32_t i, int rescan, SarRow** rows, int* count, const char** why)
{
    uint64_t pointer = c->chunk[i / 256][i % 256];
    int moved = !sar_entries.known[i] || sar_entries.pointer[i] != pointer;
    sar_entries.known[i] = 1;
    sar_entries.pointer[i] = pointer;
    if (moved) sar_entries.address[i] = 0;
    if (!(moved || rescan || sar_entries.klass[i] != SAR_CLASS_FALSE)) return 0;
    SarRow* row;
    if (EntryRow(c, i, moved, &row, why) < 0) return -1;
    if (row != NULL && *count < SAR_MAX_SENTRIES) rows[(*count)++] = row;
    return sar_entries.klass[i] != SAR_CLASS_FALSE;
}

int sar_snapshot(SarRow** rows, int* count, const char** why)
{
    SarCache* c = &sar_cache;
    if (!c->exists) NewCache();
    c->checks++;
    c->idle = 0;
    *count = 0;
    uint32_t active = 0;
    int r = Targeting(c, &active, why);
    if (r < 0) return 0;
    if (r == 0) { Forget(0); c->idle = 1; return 1; }
    if (!c->have_tmb || c->tmb != c->tm_word) { Forget(0); c->have_tmb = 1; c->tmb = c->tm_word; }
    if (active < c->active) Forget(active);
    c->active = active;
    int rescan = c->checks % SAR_RESCAN == 0, unsettled = 0;
    for (uint32_t i = 0; i < active; i++)
    {
        int v = Visit(c, i, rescan, rows, count, why);
        if (v < 0) return 0;
        unsettled += v;
    }
    c->idle = unsettled == 0;
    return 1;
}

/* ---- the idle gate ----------------------------------------------------------------------------------------------- */

/* Whether a mission runs: the mode record's word +8 set and word +0x40 in 1..7. SAR_UNKNOWN when unreadable. One read
 * (the record); its pointer is a plain load, decoded again only when it changes. */
static int InMission(SarCache* c)
{
    uint64_t at = vpm_game_u64(RVA_MODE);
    uint32_t mode[17];
    if (at == 0) return 0;
    if (!c->have_mode || at != c->mode_word)
    {
        uintptr_t record = sar_user_pointer(at);
        if (record == 0) return SAR_UNKNOWN;
        c->have_mode = 1;
        c->mode_word = at;
        c->mode = record;
    }
    if (!vpm_read(c->mode, mode, sizeof mode)) return SAR_UNKNOWN;
    return mode[2] != 0 && mode[16] >= 1 && mode[16] <= 7;
}

/* While the last check found no sentry this machine controls, a frame only counts as a check. In a mission the next
 * full check is the next 30th, which classifies every entry again; outside a mission no rescan runs and the mission is
 * checked on every 60th frame. A mission record that cannot be read counts as a mission. lint: per-frame */
int sar_idle(void)
{
    SarCache* c = &sar_cache;
    if (!c->exists || !c->idle) return 0;
    uint32_t checks = c->checks + 1;
    if (checks % SAR_RESCAN == 0)
    {
        if (c->outside == SAR_UNKNOWN || checks % SAR_MISSION_EVERY == 0) c->outside = InMission(c) == 0;
        if (!c->outside) return 0;
    }
    c->checks = checks;
    return 1;
}
