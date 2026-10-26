/* Enemy Collision Synchronized: the records kept across polls (the Lua's state.fling_history, fling_stopped, reposed and
 * corpse_checks tables), as fixed open-addressing tables: no allocation. Each table refuses a new key once it is half
 * full (the count goes to Ecs.records_full; the Lua's tables had no bound): a refused history or cooldown only means
 * no stop or no wait for that unit, never a command.
 *
 * Bounds: a motion history lives about a second without a sample and at most 4 units are inspected per poll (21 polls a
 * second), so at most about 90 exist (room for 128); stops last 256 polls; cooldowns a second; corpse re-check records
 * at most 256 polls after their corpse's last inspection (room for 2048). */
#include <string.h>
#include "ecs_internal.h"

#define HISTORY_SLOTS 256u
#define STOP_SLOTS 256u
#define REPOSE_SLOTS 4096u
#define CHECK_SLOTS 4096u

static uint64_t g_historyKeys[HISTORY_SLOTS], g_stopKeys[STOP_SLOTS], g_reposeKeys[REPOSE_SLOTS], g_checkKeys[CHECK_SLOTS];
static uint8_t g_historyUsed[HISTORY_SLOTS], g_stopUsed[STOP_SLOTS], g_reposeUsed[REPOSE_SLOTS], g_checkUsed[CHECK_SLOTS];
static EcsHistory g_histories[HISTORY_SLOTS];
static EcsStop g_stops[STOP_SLOTS];
static EcsRepose g_reposes[REPOSE_SLOTS];
static EcsCheck g_checks[CHECK_SLOTS];

EcsTable EcsHistories = {g_historyKeys, g_historyUsed, (uint8_t*)g_histories, sizeof(EcsHistory), HISTORY_SLOTS, 0};
EcsTable EcsStops = {g_stopKeys, g_stopUsed, (uint8_t*)g_stops, sizeof(EcsStop), STOP_SLOTS, 0};
EcsTable EcsReposes = {g_reposeKeys, g_reposeUsed, (uint8_t*)g_reposes, sizeof(EcsRepose), REPOSE_SLOTS, 0};
EcsTable EcsChecks = {g_checkKeys, g_checkUsed, (uint8_t*)g_checks, sizeof(EcsCheck), CHECK_SLOTS, 0};

static uint32_t Home(const EcsTable* table, uint64_t key)
{
    return (uint32_t)((key * 0x9E3779B97F4A7C15ull) >> 32) & (table->capacity - 1u);
}

static void* RecordAt(const EcsTable* table, uint32_t slot) { return table->records + (size_t)slot * table->record_size; }

static int SlotOf(const EcsTable* table, uint64_t key, uint32_t* slot)
{
    uint32_t mask = table->capacity - 1u;
    for (uint32_t i = Home(table, key), probes = 0; probes < table->capacity; i = (i + 1u) & mask, probes++)
    {
        if (!table->used[i]) { *slot = i; return 0; }
        if (table->keys[i] == key) { *slot = i; return 1; }
    }
    return 0;
}

void* EcsTableFind(const EcsTable* table, uint64_t key)
{
    uint32_t slot;
    return SlotOf(table, key, &slot) ? RecordAt(table, slot) : NULL;
}

void* EcsTablePut(EcsTable* table, uint64_t key, int* added)
{
    uint32_t slot = 0;
    *added = 0;
    if (SlotOf(table, key, &slot)) return RecordAt(table, slot);
    if (table->count >= table->capacity / 2u) { Ecs.records_full++; return NULL; }
    table->used[slot] = 1;
    table->keys[slot] = key;
    table->count++;
    memset(RecordAt(table, slot), 0, table->record_size);
    *added = 1;
    return RecordAt(table, slot);
}

/* Whether home lies cyclically in (hole, at]: the record at `at` may not move to the hole. */
static int Between(uint32_t hole, uint32_t home, uint32_t at)
{
    return hole <= at ? hole < home && home <= at : hole < home || home <= at;
}

/* Backward-shift deletion: later records of the run move up, so no lookup ever stops at a hole. */
void EcsTableRemoveSlot(EcsTable* table, uint32_t slot)
{
    uint32_t mask = table->capacity - 1u, hole = slot;
    if (!table->used[slot]) return;
    table->used[hole] = 0;
    table->count--;
    for (uint32_t at = (hole + 1u) & mask; table->used[at]; at = (at + 1u) & mask)
    {
        if (Between(hole, Home(table, table->keys[at]), at)) continue;
        table->keys[hole] = table->keys[at];
        memcpy(RecordAt(table, hole), RecordAt(table, at), table->record_size);
        table->used[hole] = 1;
        table->used[at] = 0;
        hole = at;
    }
}

void EcsTableRemove(EcsTable* table, uint64_t key)
{
    uint32_t slot;
    if (SlotOf(table, key, &slot)) EcsTableRemoveSlot(table, slot);
}

void* EcsTableSlot(const EcsTable* table, uint32_t slot, uint64_t* key)
{
    if (slot >= table->capacity || !table->used[slot]) return NULL;
    if (key != NULL) *key = table->keys[slot];
    return RecordAt(table, slot);
}

void EcsTableClear(EcsTable* table)
{
    if (table->count == 0) return;
    memset(table->used, 0, table->capacity);
    table->count = 0;
}

void EcsTablesReset(void)
{
    EcsTableClear(&EcsHistories);
    EcsTableClear(&EcsStops);
    EcsTableClear(&EcsReposes);
    EcsTableClear(&EcsChecks);
}
