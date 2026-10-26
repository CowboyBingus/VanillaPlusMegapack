/* Controllable Hover Pack's duration lease (Lua: settings.lua), build 25480438.
 *
 * The native lift test keeps a hover pack lifting while its duration is above its airborne time, or while the landing
 * assistance is on (desired_lift = duration > airborne || landing). An early descent sets the pack's own duration to
 * 1/1024 s: the next update takes the same expired-duration branch as a natural timeout, and the landing assistance
 * still brakes near the ground. Zero would select hold-to-hover, so it is never used.
 *
 * The duration lives in the pack's per-pack JumppackComponentData record (280 bytes, duration +0x9C), which the
 * jump-pack manager keeps in its override array: +4 capacity, +0x98 count, +0xA0 records, +0x60 pack -> index and +0x80
 * index -> pack maps. A pack without one gets one in the next free slot: a copy of the shared hover resource's record
 * (component table 264, the entity owner's +0xF12CB8: six 16-byte rows, then the records at +96; other mods' edits to it
 * included), published through the reverse map, the count and the forward map, all four destinations checked before
 * anything is stored. No allocation, no native call; the pack's destruction removes the record natively. Shared
 * settings are only read, so other players' packs keep their duration.
 *
 * Every inspection follows both maps afresh from the manager (the engine compacts and moves the array), records every
 * read it made, and is read again (Current) right before anything is stored. The restoration writes only while the
 * duration is still the cut-off this lease wrote, and only to the same pack (resource, id, unit and generation): a later
 * edit by the engine or another mod wins, a recycled id gets nothing.
 *
 * On HellForge: plain stores into records vpm_writable validated when this call found them (the Lua: a protection query
 * and WriteProcessMemory per write). A plain store cannot fail halfway, so the Lua's rollback of a partial write has
 * nothing to undo; the duration store after a creation needs no second query (the record was validated in the same
 * call). The jump-pack manager and the entity owner are plain loads where the Lua read them; they stay in the guard list
 * (read again with plain loads). */
#include <string.h>
#include "../../core/vpm.h"
#include "hover.h"

#define RECORD_SIZE 280u
#define AT_MODE 153u              /* 1: a timed hover */
#define AT_DURATION 156u          /* hover.duration (+0x9C) */
#define JM_CAPACITY 4u
#define JM_TOTAL 12u              /* registered packs */
#define JM_LOOKUP 32u             /* pack id -> registry index */
#define JM_ENTRIES 56u
#define JM_FORWARD 96u            /* pack id -> record index */
#define JM_REVERSE 128u           /* record index -> pack id */
#define JM_COUNT 152u             /* records in use */
#define JM_DATA 160u              /* the records */
#define OWNER_RESOURCES 0xF12CB8u /* the entity owner's component table 264 (JumppackComponentData) */
#define RESOURCE_ROWS 6u
#define MAX_GUARDS 800            /* three maps of at most 256 rows, and 12 other reads */
#define GUARD_BYTES 8192u

typedef struct Guard { uintptr_t address; uint32_t size, at; int image; } Guard;
typedef struct Slot { uintptr_t address; uint8_t bytes[8]; int has_index; uint32_t index; } Slot;
typedef struct Settings
{
    int create;                     /* the pack has no record yet: index is the free slot */
    uint32_t index;
    uintptr_t address;              /* the record */
    uint8_t bytes[RECORD_SIZE];     /* the record, or (create) the shared resource's record to copy */
    uint8_t previous[RECORD_SIZE];  /* create: the free slot as it is */
    Slot forward, reverse;
    uintptr_t count_address;
} Settings;

static Guard g_guards[MAX_GUARDS];
static uint8_t g_guardBytes[GUARD_BYTES];
static int g_guardCount;
static uint32_t g_guardUsed;
static Settings g_s;
static const char* g_error;
static struct
{
    int held;
    ChpTarget target;
    uint8_t original[4];
    int created;
    int restorations;
} g_lease;
static const float kCutoff = 1.0f / 1024.0f;

#ifdef VPM_TEST
int chp_test_queries;
#endif

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }

static int Err(const char* error)
{
    g_error = error;
    return -1;
}

static int Writable(uintptr_t address, size_t size)
{
#ifdef VPM_TEST
    chp_test_queries++;
#endif
    return vpm_writable(address, size);
}

/* ---- the inspection: 1 found (g_s), 0 not this pack any more, -1 error (g_error) ------------------------------ */

/* A read the inspection depends on: kept, so Current can read it again. image: a game.dll RVA (a plain load). */
static int Guarded(uintptr_t address, uint32_t size, int image, void* out)
{
    if (g_guardCount >= MAX_GUARDS || size > GUARD_BYTES - g_guardUsed) return Err("Too many hover settings reads");
    int ok = image ? vpm_game_read((uint32_t)address, out, size) : vpm_read(address, out, size);
    if (!ok) return Err("Hover settings unreadable");
    Guard* g = &g_guards[g_guardCount++];
    *g = (Guard){address, size, g_guardUsed, image};
    memcpy(g_guardBytes + g_guardUsed, out, size);
    g_guardUsed += size;
    return 1;
}

static int GRead(uintptr_t address, uint32_t size, void* out) { return Guarded(address, size, 0, out); }

static int GPointer(const uint8_t* bytes, uintptr_t* out)
{
    uint64_t value;
    memcpy(&value, bytes, 8);
    if (value < 0x10000u || value >= 0x800000000000ull) return Err("Hover settings pointer unavailable");
    *out = (uintptr_t)value;
    return 1;
}

static int GReadPointer(uintptr_t address, uintptr_t* out)
{
    uint8_t bytes[8];
    return GRead(address, 8, bytes) < 0 ? -1 : GPointer(bytes, out);
}

/* The row of key in one of the manager's maps, or the empty row where it would go. */
static int ReadSlot(uintptr_t jm, uint32_t offset, uint32_t key, Slot* out)
{
    uint8_t header[20];
    uintptr_t rows;
    if (GRead(jm + offset, 20, header) < 0) return -1;
    uint32_t capacity = U32(header + 8), empty = U32(header + 12), multiplier = U32(header + 16);
    if (capacity == 0 || capacity > 256 || (capacity & (capacity - 1)) != 0) return Err("Unsupported settings map");
    if (key == empty) return Err("Invalid settings key");
    if (GPointer(header, &rows) < 0) return -1;
    uint32_t product = key * multiplier;
    for (uint32_t probe = 0; probe < capacity; probe++)
    {
        uintptr_t address = rows + 8u * ((product + probe) & (capacity - 1));
        if (GRead(address, 8, out->bytes) < 0) return -1;
        uint32_t row = U32(out->bytes);
        if (row != key && row != empty) continue;
        out->address = address;
        out->has_index = row == key;
        out->index = U32(out->bytes + 4);
        return 1;
    }
    return Err("Hover settings map full");
}

/* The pack's registry row: still the same pack (its first 20 bytes)? */
static int InspectEntity(const ChpTarget* t)
{
    Slot entity;
    uint8_t word[4], record[20];
    uintptr_t entries, address;
    if (ReadSlot(t->manager, JM_LOOKUP, t->pack, &entity) < 0) return -1;
    if (!entity.has_index || entity.index == 0xFFFFFFFFu) return 0;
    if (GRead(t->manager + JM_TOTAL, 4, word) < 0) return -1;
    if (U32(word) > 64 || entity.index >= U32(word)) return Err("Invalid pack registry index");
    if (GReadPointer(t->manager + JM_ENTRIES, &entries) < 0) return -1;
    if (GReadPointer(entries + 8u * (uintptr_t)entity.index, &address) < 0) return -1;
    if (GRead(address, 20, record) < 0) return -1;
    return memcmp(record, t->identity, 20) == 0 ? 1 : 0;
}

/* The shared hover resource's record, the copy a new per-pack record starts from. */
static int SharedRecord(const ChpTarget* t)
{
    uint8_t word[8], headers[RESOURCE_ROWS * 16u];
    uintptr_t owner, resources;
    if (Guarded(VPM_RVA_ENTITY_OWNER, 8, 1, word) < 0 || GPointer(word, &owner) < 0) return -1;
    if (GReadPointer(owner + OWNER_RESOURCES, &resources) < 0) return -1;
    if (GRead(resources, sizeof headers, headers) < 0) return -1;
    for (uint32_t i = 0; i < RESOURCE_ROWS; i++)
    {
        if (memcmp(headers + i * 16u, t->identity, 8) != 0) continue;
        uint32_t index = U32(headers + i * 16u + 8);
        if (index >= 3) return Err("Invalid hover resource index");
        return GRead(resources + RESOURCE_ROWS * 16u + RECORD_SIZE * (uintptr_t)index, RECORD_SIZE, g_s.bytes) < 0 ? -1 : 1;
    }
    return Err("Hover resource unavailable");
}

static int InspectOwned(const ChpTarget* t, uintptr_t data, uint32_t n)
{
    g_s.create = 0;
    g_s.index = g_s.forward.index;
    if (g_s.index >= n) return Err("Invalid settings index");
    if (ReadSlot(t->manager, JM_REVERSE, g_s.index, &g_s.reverse) < 0) return -1;
    if (!g_s.reverse.has_index || g_s.reverse.index != t->pack) return Err("Settings owner mismatch");
    g_s.address = data + RECORD_SIZE * (uintptr_t)g_s.index;
    return GRead(g_s.address, RECORD_SIZE, g_s.bytes) < 0 ? -1 : 1;
}

static int InspectFree(const ChpTarget* t, uintptr_t data, uint32_t n, uint32_t capacity)
{
    if (n >= capacity) return Err("No free hover settings slot");
    g_s.create = 1;
    g_s.index = n;
    g_s.address = data + RECORD_SIZE * (uintptr_t)n;
    if (GRead(g_s.address, RECORD_SIZE, g_s.previous) < 0) return -1;
    if (ReadSlot(t->manager, JM_REVERSE, n, &g_s.reverse) < 0) return -1;
    if (g_s.reverse.has_index && g_s.reverse.index != 0xFFFFFFFFu) return Err("Settings slot already owned");
    g_s.count_address = t->manager + JM_COUNT;
    return SharedRecord(t);
}

static int Inspect(const ChpTarget* t)
{
    uint8_t word[8];
    uint64_t manager;
    uintptr_t data;
    g_guardCount = 0;
    g_guardUsed = 0;
    if (Guarded(CHP_RVA_JUMP_PACKS, 8, 1, word) < 0) return -1;
    memcpy(&manager, word, 8);
    if (manager < 0x10000u || manager >= 0x800000000000ull || (uintptr_t)manager != t->manager) return 0;
    int r = InspectEntity(t);
    if (r <= 0) return r;
    if (GRead(t->manager + JM_CAPACITY, 4, word) < 0) return -1;
    uint32_t capacity = U32(word);
    if (GRead(t->manager + JM_COUNT, 4, word) < 0) return -1;
    uint32_t n = U32(word);
    if (capacity == 0 || capacity > 256 || n > capacity) return Err("Invalid settings count");
    if (ReadSlot(t->manager, JM_FORWARD, t->pack, &g_s.forward) < 0) return -1;
    if (GReadPointer(t->manager + JM_DATA, &data) < 0) return -1;
    if (g_s.forward.has_index && g_s.forward.index != 0xFFFFFFFFu) return InspectOwned(t, data, n);
    return InspectFree(t, data, n, capacity);
}

/* Every read of the last inspection, read again: 1 when each still holds the same bytes. */
static int Current(void)
{
    uint8_t now[RECORD_SIZE];
    for (int i = 0; i < g_guardCount; i++)
    {
        const Guard* g = &g_guards[i];
        int ok = g->image ? vpm_game_read((uint32_t)g->address, now, g->size) : vpm_read(g->address, now, g->size);
        if (!ok || memcmp(now, g_guardBytes + g->at, g->size) != 0) return 0;
    }
    return 1;
}

/* ---- creation, cancellation, restoration ---------------------------------------------------------------------- */

/* Publishes the pack's own record in the free slot: every destination checked (one VirtualQuery each) before anything is
 * stored; then the record is inspected again. 1, or -1 (g_error). */
static int Create(const ChpTarget* t, const uint8_t* original)
{
    uint8_t reverse[8], count[4], forward[8];
    Put32(reverse, g_s.index);
    Put32(reverse + 4, t->pack);
    Put32(count, g_s.index + 1);
    Put32(forward, t->pack);
    Put32(forward + 4, g_s.index);
    const struct { uintptr_t at; const void* bytes; size_t size; } writes[4] = {
        {g_s.address, g_s.bytes, RECORD_SIZE},
        {g_s.reverse.address, reverse, sizeof reverse},
        {g_s.count_address, count, sizeof count},
        {g_s.forward.address, forward, sizeof forward},
    };
    for (int i = 0; i < 4; i++)
        if (!Writable(writes[i].at, writes[i].size)) return Err("Settings storage is not writable data");
    for (int i = 0; i < 4; i++) memcpy((void*)writes[i].at, writes[i].bytes, writes[i].size);
    int r = Inspect(t);
    if (r < 0) return -1;
    if (r == 0) return Err("New hover override unavailable");
    if (g_s.create || memcmp(g_s.bytes + AT_DURATION, original, 4) != 0) return Err("New hover override mismatch");
    return 1;
}

static int Raise(const char** error, const char* text)
{
    *error = text;
    return -1;
}

/* lint: per-frame */
int chp_settings_cancel(const ChpTarget* target, const char** error)
{
    uint8_t original[4], now[4];
    float duration;
    /* A mission transition can change the data after the snapshot: an inspection that fails only waits. */
    if (Inspect(target) <= 0) return 0;
    memcpy(original, g_s.bytes + AT_DURATION, 4);
    memcpy(&duration, original, 4);
    if (!(duration > kCutoff && duration < 86400.0f) || g_s.bytes[AT_MODE] != 1)
        return Raise(error, "Unsupported hover duration mode");
    if (!Current()) return 0;
    int created = g_s.create;
    uintptr_t validated = created ? g_s.address : 0; /* a record this call validated before storing to it */
    if (created && Create(target, original) < 0) return Raise(error, g_error);
    if (!Current()) return 0;
    g_lease.held = 1;
    g_lease.target = *target;
    memcpy(g_lease.original, original, 4);
    g_lease.created = created;
    uintptr_t at = g_s.address + AT_DURATION;
    if (g_s.address != validated && !Writable(at, 4))
    {
        g_lease.held = 0;
        return Raise(error, "Could not shorten hover duration");
    }
    memcpy((void*)at, &kCutoff, 4);
    if (!vpm_read(at, now, 4) || memcmp(now, &kCutoff, 4) != 0) return Raise(error, "Hover duration write not retained");
    return 1;
}

/* lint: per-frame */
int chp_settings_restore(const char** why)
{
    uint8_t now[4];
    if (!g_lease.held) return 1;
    int r = Inspect(&g_lease.target);
    if (r < 0)
    {
        *why = g_error; /* retried: a temporarily unreadable record never ends the lease */
        return 0;
    }
    if (r == 0 || g_s.create)
    {
        g_lease.held = 0; /* the pack is gone, or another pack holds its id */
        return 1;
    }
    if (!Current())
    {
        *why = "Hover settings changed";
        return 0;
    }
    uintptr_t at = g_s.address + AT_DURATION;
    if (memcmp(g_s.bytes + AT_DURATION, &kCutoff, 4) == 0)
    {
        if (!Writable(at, 4)) return Raise(why, "Could not restore hover duration");
        memcpy((void*)at, g_lease.original, 4);
        if (!vpm_read(at, now, 4) || memcmp(now, g_lease.original, 4) != 0) return Raise(why, "Hover restoration not retained");
        g_lease.restorations++;
    }
    g_lease.held = 0;
    return 1;
}

int chp_lease_held(void) { return g_lease.held; }
const ChpKey* chp_lease_key(void) { return &g_lease.target.key; }
int chp_settings_created(void) { return g_lease.created; }
int chp_settings_restorations(void) { return g_lease.restorations; }

float chp_lease_original(void)
{
    float value;
    memcpy(&value, g_lease.original, 4);
    return value;
}

void chp_settings_reset(void)
{
    memset(&g_lease, 0, sizeof g_lease);
    memset(&g_s, 0, sizeof g_s);
    g_guardCount = 0;
    g_guardUsed = 0;
    g_error = NULL;
}
