/* Armory Preview Cache: bounded leases, foreground lookahead and learned startup prewarming (policy.lua and profile.lua,
 * v23.1).
 *
 * The policy holds at most 128 package leases for the thumbnails the Armory or the briefing asks for, the ones it will
 * ask for next (the learned profile, newest first) and their weapons' attachment packages, takes at most 4 new ones per
 * 50 ms step and evicts the least recently used unprotected one when full. It releases them all when the screen closes,
 * the UI world changes or memory runs low, and never releases against a package system that replaced the one it leased
 * from (those references went with it). A startup window of 60 s prewarms the learned items before the first menu.
 *
 * The profile keeps the last 192 items seen ("ArmoryPreviewCache2 <build>", then "kind:id|attachment,..." per item, oldest
 * first); the version-1 format (no attachments) is still read. */
#include <stdio.h>
#include "apc.h"

#define WANTED 2048
#define GIB (1024ull * 1024 * 1024)

typedef struct Request { uint64_t id; uint8_t prewarm, dependency; } Request;

static ApcPolicy g_policy;
static Request g_wanted[WANTED];
static int g_wantedCount;
APC_MAP(g_protected, 4096);              /* id -> its index in g_wanted */

ApcPolicy* apc_policy(void) { return &g_policy; }

void apc_policy_reset(int prewarm)
{
    memset(&g_policy, 0, sizeof g_policy);
    g_policy.prewarm = prewarm;
    g_policy.profile_changed = -1;
    g_policy.status = "starting";
}

/* ---- the memory guard ---------------------------------------------------------------------------------------------- */

int apc_guard_tick(ApcGuard* guard, double now, uint64_t free, uint64_t commit)
{
    int reason = free < 2 * GIB ? APC_PRESSURE_LOW_PHYSICAL : commit < 2 * GIB ? APC_PRESSURE_LOW_COMMIT : APC_PRESSURE_NONE;
    if (reason != APC_PRESSURE_NONE)
    {
        if (!guard->active) { guard->trips++; guard->last_reason = reason; }
        guard->active = 1;
        guard->last_low = now;
        guard->has_healthy = 0;
        return reason;
    }
    if (!guard->active) return APC_PRESSURE_NONE;
    if (free >= 4 * GIB && commit >= 4 * GIB)
    {
        if (!guard->has_healthy) { guard->has_healthy = 1; guard->healthy_since = now; }
        if (now - guard->last_low >= 30 && now - guard->healthy_since >= 5)
        {
            guard->active = 0;
            guard->has_healthy = 0;
            return APC_PRESSURE_NONE;
        }
    }
    else
        guard->has_healthy = 0;
    return APC_PRESSURE_RECOVERY;
}

const char* apc_pressure_text(int reason)
{
    static const char* const kTexts[] = {"none", "low_physical_memory", "low_commit_headroom", "memory_recovery_cooldown"};
    return reason >= 0 && reason <= 3 ? kTexts[reason] : "none";
}

/* ---- learned items --------------------------------------------------------------------------------------------- */

static int Learned(uint32_t kind, uint64_t id)
{
    for (int i = 0; i < g_policy.learned_count; i++)
        if (g_policy.learned[i].kind == kind && g_policy.learned[i].id == id) return i;
    return -1;
}

/* Background and startup prewarming traverse the list newest first: a revisit refreshes an item's priority even when it
 * was learned long ago. */
void apc_policy_remember(const ApcAssetItem* item)
{
    ApcPolicy* p = &g_policy;
    p->profile_changed = 1;
    int at = Learned(item->kind, item->id);
    if (at < 0)
    {
        ApcAssetItem* added = &p->learned[p->learned_count++];
        memset(added, 0, sizeof *added);
        added->kind = item->kind;
        added->id = item->id;
        if (p->learned_count > APC_LEARNED)
        {
            memmove(&p->learned[0], &p->learned[1], (size_t)(p->learned_count - 1) * sizeof p->learned[0]);
            p->learned_count--;
        }
        at = p->learned_count - 1;
    }
    else if (at != p->learned_count - 1)
    {
        ApcAssetItem moved = p->learned[at];
        memmove(&p->learned[at], &p->learned[at + 1], (size_t)(p->learned_count - 1 - at) * sizeof p->learned[0]);
        p->learned[p->learned_count - 1] = moved;
        at = p->learned_count - 1;
    }
    if (!item->has_attachments) return;
    ApcAssetItem* learned = &p->learned[at];
    learned->has_attachments = 1;
    learned->attachment_count = item->attachment_count < APC_ATTACHMENTS ? item->attachment_count : APC_ATTACHMENTS;
    memcpy(learned->attachments, item->attachments, sizeof learned->attachments);
}

/* ---- leases ---------------------------------------------------------------------------------------------------- */

static int Lease(uint64_t id)
{
    for (int i = 0; i < g_policy.lease_count; i++)
        if (g_policy.leases[i].id == id) return i;
    return -1;
}

static void Unlease(int at)
{
    g_policy.leases[at] = g_policy.leases[--g_policy.lease_count];
}

static int Evict(int at)
{
    int released;
    if (!apc_native_release(g_policy.leases[at].id, g_policy.leases[at].owner, &released)) return 0;
    Unlease(at);
    g_policy.releases++;
    return 1;
}

/* The package system that replaced the one leased from owns the teardown: never release against its successor. */
static void Retire(void)
{
    g_policy.retired += (uint32_t)g_policy.lease_count;
    g_policy.lease_count = 0;
}

static int ValidLeases(int* valid)
{
    uint64_t ids[APC_LEASE_LIMIT + 1];
    for (int i = 0; i < g_policy.lease_count; i++) ids[i] = g_policy.leases[i].id;
    return apc_native_valid_leases(ids, g_policy.lease_count, g_policy.owner, valid);
}

int apc_policy_clear(void)
{
    int valid = 1;
    if (g_policy.lease_count > 0 && !ValidLeases(&valid)) return 0;
    if (!valid)
    {
        Retire();
        g_policy.quarantined = 1;
        return 1;
    }
    while (g_policy.lease_count > 0)
        if (!Evict(g_policy.lease_count - 1)) return 0;
    return 1;
}

/* ---- the step ---------------------------------------------------------------------------------------------------- */

static int Protected(uint64_t id, int* index)
{
    uint64_t at;
    if (!apc_map_get(&g_protected, id, &at)) return 0;
    *index = (int)at;
    return 1;
}

static int Add(const ApcAssetItem* item, int background)
{
    uint64_t ids[APC_ATTACHMENTS * 2 + 1];
    int count, index;
    if (!apc_native_resolve_all(item, ids, (int)(sizeof ids / sizeof ids[0]), &count)) return 0;
    if (count == 0) g_policy.unresolved++;
    for (int i = 0; i < count; i++)
    {
        if (Protected(ids[i], &index) || g_wantedCount >= WANTED) continue;
        (void)apc_map_put(&g_protected, ids[i], (uint64_t)g_wantedCount); /* 4096 slots for 2048 requests */
        g_wanted[g_wantedCount++] = (Request){ids[i], (uint8_t)background, (uint8_t)(i > 0)};
    }
    return 1;
}

/* The screen's requests: unfinished cards first, then finished ones. The current group is touched in reverse, so
 * newest-first prewarming keeps the foreground's order; repeated identical snapshots end with identical profile bytes. */
static int Foreground(const ApcAssetSnap* s)
{
    for (int i = s->item_count - 1; i >= 0; i--) apc_policy_remember(&s->items[i]);
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < s->item_count; i++)
        {
            int at = s->items[i].finished == pass ? Learned(s->items[i].kind, s->items[i].id) : -1;
            if (at >= 0 && !Add(&g_policy.learned[at], 0)) return 0;
        }
    return 1;
}

/* Foreground first, then (background learning helps before a menu opens, but foreground generation owns priority) the
 * learned items newest first while they fit. */
static int Wanted(const ApcAssetSnap* s)
{
    g_wantedCount = 0;
    apc_map_clear(&g_protected);
    if (!Foreground(s)) return 0;
    if (!g_policy.prewarm || s->active || s->blocked) return 1;
    for (int i = g_policy.learned_count - 1; i >= 0; i--)
    {
        if (!Add(&g_policy.learned[i], 1)) return 0;
        if (g_wantedCount >= APC_LEASE_LIMIT) break; /* after the add, as the Lua: one more when the foreground fills it */
    }
    return 1;
}

/* Only requests that fit are protected: an oversized profile must not make every held package unevictable. */
static int Fits(uint64_t id)
{
    int index;
    return Protected(id, &index) && index < APC_LEASE_LIMIT;
}

static int Oldest(void)
{
    int victim = -1;
    double oldest = 1e300;
    for (int i = 0; i < g_policy.lease_count; i++)
        if (!Fits(g_policy.leases[i].id) && g_policy.leases[i].used < oldest) { victim = i; oldest = g_policy.leases[i].used; }
    return victim;
}

/* One new lease for a protected request, evicting the oldest unprotected lease when full. */
static int Take(const Request* request, double now, int startup, int* added)
{
    int victim = Oldest();
    if (g_policy.lease_count >= APC_LEASE_LIMIT && victim >= 0 && !Evict(victim)) return 0;
    int acquired = 0;
    if (g_policy.lease_count >= APC_LEASE_LIMIT) return 1;
    if (!apc_native_acquire(request->id, g_policy.owner, &acquired)) return 0;
    if (!acquired) return 1;
    ApcLease* lease = &g_policy.leases[g_policy.lease_count++];
    lease->id = request->id;
    lease->owner[0] = g_policy.owner[0];
    lease->owner[1] = g_policy.owner[1];
    lease->used = now;
    (*added)++;
    g_policy.acquires++;
    g_policy.prewarms += request->prewarm;
    g_policy.dependency_acquires += request->dependency;
    g_policy.startup_acquires += (uint32_t)startup;
    return 1;
}

static int Lookahead(double now, int startup, int* added)
{
    *added = 0;
    g_policy.foreground_pending = 0;
    for (int i = 0; i < g_wantedCount; i++)
    {
        const Request* request = &g_wanted[i];
        int at = Lease(request->id);
        if (at >= 0)
        {
            g_policy.leases[at].used = now;
            g_policy.hits++;
        }
        else if (*added < 4 && Fits(request->id) && !Take(request, now, startup, added))
            return 0;
        if (!request->prewarm && Lease(request->id) < 0) g_policy.foreground_pending++;
    }
    return 1;
}

/* Settled only at a fixed point: this tick acquired nothing (a lease it added is a hit next tick) and every protected
 * request is leased (one that is not is retried next tick, and whether that works depends on the game's table). */
static int Settled(int startup, int added)
{
    if (startup || added > 0) return 0;
    for (int i = 0; i < g_wantedCount && i < APC_LEASE_LIMIT; i++)
        if (Lease(g_wanted[i].id) < 0) return 0;
    return 1;
}

/* The owner and world checks before any lease work: 1 go on, 2 settled here, 0 error. */
static int Ownership(const ApcAssetSnap* s, double now)
{
    ApcPolicy* p = &g_policy;
    if (p->has_owner && (p->owner[0] != s->owner[0] || p->owner[1] != s->owner[1])) Retire();
    p->has_owner = 1;
    p->owner[0] = s->owner[0];
    p->owner[1] = s->owner[1];
    int valid = 1;
    if (p->lease_count > 0 && !ValidLeases(&valid)) return 0;
    if (!valid)
    {
        Retire();
        p->quarantined = 1;
    }
    if (p->quarantined) { p->status = "lease_ownership_lost_restart_required"; return 2; }
    if (!p->has_started) { p->has_started = 1; p->started = now; }
    return 1;
}

static int Closed(const char* status, int pressure, int settledValue, int* settled)
{
    if (!apc_policy_clear()) return 0;
    g_policy.pressure = pressure;
    g_policy.status = status;
    *settled = settledValue;
    return 2;
}

/* The world and the window: a new UI world clears the leases (not the first menu's, which inherits the startup ones);
 * outside the menu and the startup window, or under memory pressure, everything is released. 1 go on, 2 done, 0 error.
 * Outside the menu a closed startup window never reopens for the same snapshot; an open one closes with the clock alone,
 * so a tick inside it is never settled. */
static int Window(const ApcAssetSnap* s, int startup, int pressure, int* settled)
{
    ApcPolicy* p = &g_policy;
    int changed = p->has_world && (!s->has_world || s->world != p->world);
    if (changed && !(!p->seen_menu && s->menu))
    {
        if (!apc_policy_clear()) return 0;
        p->pressure = 0;
    }
    p->has_world = s->has_world;
    p->world = s->world;
    if (s->menu) p->seen_menu = 1;
    if (!s->menu && !startup) return Closed("outside_ship_ui", 0, 1, settled);
    if (pressure) return Closed("memory_pressure", 1, !startup, settled);
    p->pressure = 0;
    return 1;
}

static const char* Status(const ApcAssetSnap* s, int startup)
{
    if (startup) return "startup_dependency_prewarm";
    if (s->blocked) return "thumbnail_ui_busy";
    return s->active ? "foreground_lookahead" : "resident";
}

/* One step: 1 with settled set, 0 error (settled unchanged). */
static int Step(const ApcAssetSnap* s, double now, int pressure, int* settled)
{
    ApcPolicy* p = &g_policy;
    *settled = 1;
    int owned = Ownership(s, now);
    if (owned != 1) return owned == 2;
    int startup = p->prewarm && !s->menu && !p->seen_menu && now - p->started < 60 && s->prefetch;
    int open = Window(s, startup, pressure, settled);
    if (open != 1) return open == 2;
    int added = 0;
    if (!Wanted(s) || !Lookahead(now, startup, &added)) return 0;
    p->status = Status(s, startup);
    *settled = Settled(startup, added);
    return 1;
}

/* lint: per-frame (a policy step) */
int apc_policy_tick(const ApcAssetSnap* s, double now, int pressure)
{
    uint32_t hits = g_policy.hits, unresolved = g_policy.unresolved;
    int settled;
    if (!Step(s, now, pressure, &settled)) return 0;
    g_policy.settled = settled;
    g_policy.tick_hits = g_policy.hits - hits;
    g_policy.tick_unresolved = g_policy.unresolved - unresolved;
    return 1;
}

/* A settled step repeated with the same snapshot and pressure would only add the same hit and unresolved counts. */
void apc_policy_replay(void)
{
    g_policy.hits += g_policy.tick_hits;
    g_policy.unresolved += g_policy.tick_unresolved;
}

/* ---- the profile ------------------------------------------------------------------------------------------------- */

static size_t Append(char* out, size_t at, size_t capacity, int written)
{
    size_t next = at + (written > 0 ? (size_t)written : 0);
    return next < capacity ? next : capacity;
}

static size_t EncodeItem(char* out, size_t at, size_t capacity, const ApcAssetItem* item)
{
    at = Append(out, at, capacity, snprintf(out + at, capacity - at, "%u:%016llx|", item->kind, (unsigned long long)item->id));
    for (int j = 0; item->has_attachments && j < item->attachment_count && at < capacity; j++)
        at = Append(out, at, capacity,
            snprintf(out + at, capacity - at, j > 0 ? ",%016llx" : "%016llx", (unsigned long long)item->attachments[j]));
    if (at < capacity) out[at++] = '\n';
    return at;
}

size_t apc_profile_encode(char* out, size_t capacity, const char* build)
{
    size_t at = Append(out, 0, capacity, snprintf(out, capacity, "ArmoryPreviewCache2 %s\n", build));
    for (int i = 0; i < g_policy.learned_count && at < capacity; i++) at = EncodeItem(out, at, capacity, &g_policy.learned[i]);
    return at;
}

static ApcAssetItem g_decoded[APC_LEARNED];

static int Hex(char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }

static int HexValue(const char* text, size_t size, uint64_t* value)
{
    *value = 0;
    if (size != 16) return 0;
    for (size_t i = 0; i < 16; i++)
    {
        if (!Hex(text[i])) return 0;
        *value = *value << 4 | (uint64_t)(text[i] <= '9' ? text[i] - '0' : text[i] - 'a' + 10);
    }
    return 1;
}

/* An extra field "a,b,...": every value 16 lowercase hex digits, not zero, unique, at most 10. */
static int Duplicate(const ApcAssetItem* item, uint64_t value)
{
    for (int k = 0; k < item->attachment_count; k++)
        if (item->attachments[k] == value) return 1;
    return 0;
}

static int Commas(const char* extra, size_t size)
{
    if (extra[0] == ',' || extra[size - 1] == ',') return 0;
    for (size_t i = 0; i < size; i++)
        if (!(Hex(extra[i]) || extra[i] == ',') || (extra[i] == ',' && i + 1 < size && extra[i + 1] == ',')) return 0;
    return 1;
}

static int Attachments(const char* extra, size_t size, ApcAssetItem* item)
{
    if (size == 0) return 1;
    if (!Commas(extra, size)) return 0;
    for (size_t at = 0; at < size;)
    {
        size_t end = at;
        while (end < size && extra[end] != ',') end++;
        uint64_t value;
        if (!HexValue(extra + at, end - at, &value) || value == 0 || item->attachment_count >= APC_ATTACHMENTS ||
            Duplicate(item, value))
            return 0;
        item->attachments[item->attachment_count++] = value;
        at = end + 1;
    }
    return 1;
}

static int Seen(int count, uint32_t kind, uint64_t id)
{
    for (int i = 0; i < count; i++)
        if (g_decoded[i].kind == kind && g_decoded[i].id == id) return 1;
    return 0;
}

/* One line: "kind:id" (kind 0..4, id 16 lowercase hex digits, not zero), "|" and the attachments (version 2). */
static int Line(const char* line, size_t size, int legacy, int count, ApcAssetItem* item)
{
    size_t base = 0;
    while (base < size && line[base] != '|') base++;
    if (base == 0) return 0;
    const char* extra = line + base + (base < size ? 1 : 0);
    size_t extraSize = size - base - (base < size ? 1 : 0);
    if (base < 3 || line[0] < '0' || line[0] > '4' || line[1] != ':') return 0;
    for (size_t i = 2; i < base; i++)
        if (!Hex(line[i])) return 0;
    memset(item, 0, sizeof *item);
    item->kind = (uint32_t)(line[0] - '0');
    if (!HexValue(line + 2, base - 2, &item->id) || Seen(count, item->kind, item->id) || item->id == 0) return 0;
    if (legacy) return extraSize == 0;
    item->has_attachments = 1;
    return Attachments(extra, extraSize, item);
}

/* The header line ("ArmoryPreviewCache<version> <build>"): 1 version 1, 2 version 2, 0 neither; *body after it. */
static int Header(const char* text, size_t size, const char* build, size_t* body)
{
    size_t end = 0;
    while (end < size && text[end] != '\r' && text[end] != '\n') end++;
    size_t at = end;
    if (end == 0 || at >= size) return 0;
    if (text[at] == '\r') at++;
    if (at >= size || text[at] != '\n') return 0;
    *body = at + 1;
    char v1[96], v2[96];
    snprintf(v1, sizeof v1, "ArmoryPreviewCache1 %s", build);
    snprintf(v2, sizeof v2, "ArmoryPreviewCache2 %s", build);
    if (end == strlen(v1) && memcmp(text, v1, end) == 0) return 1;
    return end == strlen(v2) && memcmp(text, v2, end) == 0 ? 2 : 0;
}

/* The next line: *at moved past line breaks, its end returned. */
static size_t NextLine(const char* text, size_t size, size_t* at)
{
    while (*at < size && (text[*at] == '\r' || text[*at] == '\n')) (*at)++;
    size_t end = *at;
    while (end < size && text[end] != '\r' && text[end] != '\n') end++;
    return end;
}

int apc_profile_decode(const char* text, size_t size, const char* build, int remember)
{
    size_t at;
    if (text == NULL || size == 0 || size > APC_PROFILE_MAX || text[size - 1] != '\n') return 0;
    int version = Header(text, size, build, &at);
    if (version == 0) return 0;
    int count = 0;
    while (at < size && count < APC_LEARNED)
    {
        size_t end = NextLine(text, size, &at);
        if (end > at && Line(text + at, end - at, version == 1, count, &g_decoded[count])) count++;
        at = end;
    }
    for (int i = 0; remember && i < count; i++) apc_policy_remember(&g_decoded[i]);
    return 1;
}
