/* Enemy Collision Synchronized: a poll's reads and guard lists (the Lua: corpse_data.lua read, fetch, cached, capture,
 * guard, same, and the shared runtime's api.pointer).
 *
 * Every heap read a poll's snapshot makes through EcsRead counts against the Lua's budget (4 MB and 18000 calls a poll);
 * EcsCached keeps a read for the rest of the poll (the registry header, actor pool rows 16 at a time, the physics world's
 * metadata), as the Lua's per-poll cache did. Statics inside game.dll's or the exe's image are plain loads (EcsImageRead),
 * which the Lua made as ReadProcessMemory calls. A guard list keeps bytes as read this poll; EcsSame compares them
 * again with one read per group of nearby heap guards, as the Lua's grouping plan did (within 128 bytes of the group's
 * end, 4096 bytes at most). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ecs_internal.h"

#define BUDGET_BYTES (4u * 1024u * 1024u)
#define BUDGET_CALLS 18000u
#define MAX_READ 32768u
#define CACHE_ITEMS 64u
#define CACHE_BYTES (256u * 1024u)
#define GROUP_SPAN 4096u
#define GROUP_GAP 128u
#define MAX_GUARDS 256u

typedef struct CacheItem { uintptr_t address; uint32_t size, at; int ok; } CacheItem;

static struct
{
    uint32_t used, calls;
    CacheItem items[CACHE_ITEMS];
    uint32_t count, arena;
    char why[256];
} s;

static uint8_t g_arena[CACHE_BYTES];     /* the poll's cached reads */
static uint8_t g_transient[MAX_READ];    /* a cached read that did not fit: valid until the next EcsCached call */
static uint8_t g_group[GROUP_SPAN];      /* one guard group as read now */
static uint32_t g_order[MAX_GUARDS];     /* heap guards by address */
static const EcsGuards* g_sorting;

uint32_t EcsU32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
uint64_t EcsU64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }
uintptr_t EcsPointer(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull ? (uintptr_t)value : 0; }

/* ---- raising ----------------------------------------------------------------------------------------------------- */

int EcsRaise(const char* why)
{
    snprintf(s.why, sizeof s.why, "%s", why);
    return 0;
}

int EcsRaisef(const char* format, ...)
{
    va_list args;
    va_start(args, format);
    vsnprintf(s.why, sizeof s.why, format, args);
    va_end(args);
    return 0;
}

const char* EcsWhy(void) { return s.why; }

/* ---- reads ------------------------------------------------------------------------------------------------------- */

void EcsReadsBegin(void)
{
    s.used = s.calls = 0;
    s.count = s.arena = 0;
}

void EcsReadTotals(uint32_t* bytes, uint32_t* calls)
{
    *bytes = s.used;
    *calls = s.calls;
}

static int Inside(uintptr_t address, size_t size, uintptr_t base, size_t limit)
{
    return base != 0 && address >= base && size <= limit && address - base <= limit - size;
}

int EcsImageRead(uintptr_t address, void* out, size_t size)
{
    if (!Inside(address, size, vpm_game(), vpm_game_size()) && !Inside(address, size, vpm_exe(), vpm_exe_size())) return 0;
    memcpy(out, (const void*)address, size);
    return 1;
}

int EcsRead(uintptr_t address, void* out, size_t size)
{
    if (size == 0 || size > MAX_READ) return EcsRaise("Read size outside bounds");
    s.used += (uint32_t)size;
    s.calls++;
    if (s.used > BUDGET_BYTES || s.calls > BUDGET_CALLS) return EcsRaise("Snapshot budget exceeded");
    if (!vpm_read(address, out, size)) return EcsRaise("Data unavailable");
    return 1;
}

int EcsCapture(uintptr_t address, void* out, size_t size) { return size > 0 && size <= MAX_READ && vpm_read(address, out, size); }

static const uint8_t* Remembered(uintptr_t address, uint32_t size, int optional, int* found)
{
    *found = 0;
    for (uint32_t i = 0; i < s.count; i++)
    {
        const CacheItem* item = &s.items[i];
        if (item->address != address || item->size != size) continue;
        *found = 1;
        if (item->ok) return g_arena + item->at;
        if (!optional) EcsRaise("Data unavailable");
        return NULL;
    }
    return NULL;
}

const uint8_t* EcsCached(uintptr_t address, uint32_t size, int optional)
{
    int found;
    const uint8_t* kept = Remembered(address, size, optional, &found);
    if (found) return kept;
    if (size == 0 || size > MAX_READ) { EcsRaise("Read size outside bounds"); return NULL; }
    int room = s.count < CACHE_ITEMS && size <= CACHE_BYTES - s.arena;
    uint8_t* into = room ? g_arena + s.arena : g_transient;
    int ok = EcsRead(address, into, size);
    if (room)
    {
        s.items[s.count++] = (CacheItem){address, size, s.arena, ok};
        if (ok) s.arena += (size + 15u) & ~15u;
    }
    return ok ? into : NULL;
}

/* ---- guard lists ------------------------------------------------------------------------------------------------- */

void EcsGuardsInit(EcsGuards* list, EcsGuard* items, uint32_t capacity, uint8_t* bytes, uint32_t room)
{
    list->items = items;
    list->bytes = bytes;
    list->capacity = capacity;
    list->room = room;
    list->count = list->used = 0;
}

void EcsGuardsClear(EcsGuards* list) { list->count = list->used = 0; }

int EcsGuardAdd(EcsGuards* list, uintptr_t address, const void* bytes, uint32_t size)
{
    if (list->count >= list->capacity || size > list->room - list->used) return EcsRaise("Too many guarded bytes");
    memcpy(list->bytes + list->used, bytes, size);
    list->items[list->count++] = (EcsGuard){address, size, list->used};
    list->used += size;
    return 1;
}

int EcsGuardAppend(EcsGuards* list, const EcsGuards* from)
{
    for (uint32_t i = 0; i < from->count; i++)
    {
        const EcsGuard* g = &from->items[i];
        if (!EcsGuardAdd(list, g->address, from->bytes + g->at, g->size)) return 0;
    }
    return 1;
}

int EcsGuardRead(EcsGuards* list, uintptr_t address, void* out, uint32_t size)
{
    return EcsRead(address, out, size) && EcsGuardAdd(list, address, out, size);
}

/* ---- comparing guards again (the Lua's same) ------------------------------------------------------------------- */

static int ImageGuard(const EcsGuard* g)
{
    return Inside(g->address, g->size, vpm_game(), vpm_game_size()) || Inside(g->address, g->size, vpm_exe(), vpm_exe_size());
}

/* One guard on its own: a plain load in an image, else a read of its span. */
static int Unchanged(const EcsGuards* list, const EcsGuard* g)
{
    if (g->size > GROUP_SPAN) return 0;
    if (ImageGuard(g)) return memcmp((const void*)g->address, list->bytes + g->at, g->size) == 0;
    return vpm_read(g->address, g_group, g->size) && memcmp(g_group, list->bytes + g->at, g->size) == 0;
}

static int ByAddress(const void* a, const void* b)
{
    uintptr_t x = g_sorting->items[*(const uint32_t*)a].address, y = g_sorting->items[*(const uint32_t*)b].address;
    return x < y ? -1 : x > y;
}

/* The guards g_order[first .. end) as one read of [start, start + size); each on its own when that read fails. */
static int GroupSame(const EcsGuards* list, uint32_t first, uint32_t end, uintptr_t start, uint32_t size)
{
    int whole = size <= GROUP_SPAN && vpm_read(start, g_group, size);
    for (uint32_t k = first; k < end; k++)
    {
        const EcsGuard* g = &list->items[g_order[k]];
        if (!whole && !Unchanged(list, g)) return 0;
        if (whole && memcmp(g_group + (g->address - start), list->bytes + g->at, g->size) != 0) return 0;
    }
    return 1;
}

/* The end of the group starting at sorted guard k (the Lua's plan: a guard joins while it starts within 128 bytes of the
 * group's end and the group stays within 4096 bytes), with the group's size. */
static uint32_t GroupEnd(const EcsGuards* list, uint32_t k, uint32_t heap, uint32_t* size)
{
    uintptr_t start = list->items[g_order[k]].address;
    uint64_t span = list->items[g_order[k]].size;
    for (k++; k < heap; k++)
    {
        const EcsGuard* g = &list->items[g_order[k]];
        if (g->address > start + span + GROUP_GAP || g->address + g->size - start > GROUP_SPAN) break;
        if (g->address + g->size - start > span) span = g->address + g->size - start;
    }
    *size = (uint32_t)span;
    return k;
}

int EcsSame(const EcsGuards* list)
{
    uint32_t heap = 0;
    for (uint32_t i = 0; i < list->count; i++)
    {
        const EcsGuard* g = &list->items[i];
        if (!ImageGuard(g) && heap < MAX_GUARDS) { g_order[heap++] = i; continue; }
        if (!Unchanged(list, g)) return 0; /* an image guard (or one past the sort's room): on its own */
    }
    g_sorting = list;
    if (heap > 1) qsort(g_order, heap, sizeof g_order[0], ByAddress);
    for (uint32_t k = 0, end = 0; k < heap; k = end)
    {
        uint32_t size = 0;
        end = GroupEnd(list, k, heap, &size);
        if (!GroupSame(list, k, end, list->items[g_order[k]].address, size)) return 0;
    }
    return 1;
}
