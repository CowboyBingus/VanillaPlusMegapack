/* Enemy Collision Synchronized: the listing (the Lua: corpse_data.lua listing_of, key_of, relist, verify, classify,
 * prune). Which entries of a manager hold a listed resource, kept across polls so an idle poll reads no entry header.
 *
 * It is a hint for where to look, never data to act on: an entry it names has its header read afresh before an
 * inspection, and everything a command depends on is read and guarded in that poll. Entities are classified by address
 * (the header's resource; the unit word is kept for the motion history and the corpse backoff). The whole pointer array
 * is compared with the one the listing was built from; only a changed array is walked, and only addresses not seen
 * before cost a header read (at most 128 a poll; the rest wait, and the poll counts as yielded). An entity can be freed
 * and another allocated at the same address with the array unchanged: a rolling verification re-reads ceil(count/16)
 * known headers of the manager scanned first in each poll, so every entry is checked again within 32 polls. */
#include <string.h>
#include "ecs_internal.h"

#define RAGDOLL_SLOTS 16384u  /* a listing holds at most 2 * 2048 + 64 + 2048 addresses before it is pruned */
#define CORPSE_SLOTS 4096u
#define SWEEP_POLLS 16u
#define UNREADABLE (-3)

static EcsEntry g_ragdollTable[RAGDOLL_SLOTS], g_corpseTable[CORPSE_SLOTS];
static uint16_t g_ragdollListed[ECS_MAX_RAGDOLLS], g_corpseListed[ECS_MAX_CORPSES];
static uint64_t g_ragdollKept[ECS_MAX_RAGDOLLS], g_corpseKept[ECS_MAX_CORPSES];
static EcsEntry g_survivors[ECS_MAX_RAGDOLLS];
static EcsListing g_listings[2];

static void Fresh(EcsListing* listing, int corpse)
{
    if (listing->table != NULL && listing->size > 0) memset(listing->table, 0, sizeof(EcsEntry) * listing->capacity);
    memset(listing, 0, sizeof *listing);
    listing->table = corpse ? g_corpseTable : g_ragdollTable;
    listing->capacity = corpse ? CORPSE_SLOTS : RAGDOLL_SLOTS;
    listing->listed = corpse ? g_corpseListed : g_ragdollListed;
    listing->kept = corpse ? g_corpseKept : g_ragdollKept;
}

void EcsListingsReset(void)
{
    for (int corpse = 0; corpse < 2; corpse++) Fresh(&g_listings[corpse], corpse);
}

EcsListing* EcsListingOf(int corpse)
{
    EcsListing* listing = &g_listings[corpse ? 1 : 0];
    if (listing->table == NULL) Fresh(listing, corpse ? 1 : 0);
    return listing;
}

static uint32_t Home(const EcsListing* listing, uint64_t address)
{
    return (uint32_t)((address * 0x9E3779B97F4A7C15ull) >> 40) & (listing->capacity - 1u);
}

EcsEntry* EcsListingFind(EcsListing* listing, uint64_t address)
{
    uint32_t mask = listing->capacity - 1u;
    for (uint32_t i = Home(listing, address), probes = 0; probes < listing->capacity; i = (i + 1u) & mask, probes++)
    {
        if (!listing->table[i].used) return NULL;
        if (listing->table[i].address == address) return &listing->table[i];
    }
    return NULL;
}

/* A new, unclassified entry; NULL when the table is three quarters full (it cannot be: see RAGDOLL_SLOTS). */
static EcsEntry* Insert(EcsListing* listing, uint64_t address)
{
    if (listing->size >= listing->capacity / 4u * 3u) return NULL;
    uint32_t mask = listing->capacity - 1u, i = Home(listing, address);
    while (listing->table[i].used) i = (i + 1u) & mask;
    listing->table[i] = (EcsEntry){address, 0, 0, ECS_UNKNOWN, 0, 1};
    listing->size++;
    return &listing->table[i];
}

uint64_t EcsAddressAt(const uint64_t* pointers, uint32_t index)
{
    uint64_t value = pointers[index];
    return value < 0x10000u || value >= 0x800000000000ull ? 0 : value;
}

/* A fresh header's profile (*unit its unit word), ECS_UNLISTED, or UNREADABLE. */
static int Classify(uint64_t address, uint32_t* unit)
{
    uint8_t header[24];
    if (!vpm_read((uintptr_t)address, header, sizeof header)) return UNREADABLE;
    int profile = EcsProfileOf(EcsU64(header));
    if (profile < 0) return ECS_UNLISTED;
    *unit = EcsU32(header + 12);
    return profile;
}

static void SetKey(EcsEntry* entry, int key, uint32_t unit)
{
    entry->key = (int16_t)key;
    entry->has_unit = key >= 0;
    entry->unit = key >= 0 ? unit : 0;
}

/* The listing's key for a valid address, classifying it while the poll may still (*left > 0); stamps it. An unreadable
 * header counts as unlisted: the rolling verification reads it again within 32 polls. */
static int KeyOf(EcsListing* listing, uint64_t address, uint32_t* left)
{
    EcsEntry* entry = EcsListingFind(listing, address);
    if (entry == NULL && (entry = Insert(listing, address)) == NULL) return ECS_UNLISTED;
    if (entry->key == ECS_UNKNOWN && *left > 0)
    {
        (*left)--;
        uint32_t unit = 0;
        int key = Classify(address, &unit);
        if (key == UNREADABLE) { key = ECS_UNLISTED; Ecs.listing_unreadable++; }
        SetKey(entry, key, unit);
        Ecs.listing_classified++;
    }
    entry->stamp = listing->stamp;
    return entry->key;
}

/* Forgets addresses the array no longer holds, once they outnumber it. */
static void Prune(EcsListing* listing, uint32_t count)
{
    if (listing->size <= 2u * count + 64u) return;
    uint32_t kept = 0;
    for (uint32_t i = 0; i < listing->capacity; i++)
        if (listing->table[i].used && listing->table[i].stamp == listing->stamp && kept < ECS_MAX_RAGDOLLS)
            g_survivors[kept++] = listing->table[i];
    memset(listing->table, 0, sizeof(EcsEntry) * listing->capacity);
    listing->size = 0;
    for (uint32_t i = 0; i < kept; i++)
    {
        EcsEntry* entry = Insert(listing, g_survivors[i].address);
        if (entry != NULL) *entry = g_survivors[i];
    }
}

/* Rebuilds the listed entry indices from this poll's pointer array. */
static void Relist(EcsListing* listing, const uint64_t* pointers, uint32_t count)
{
    listing->stamp++;
    uint32_t n = 0, left = ECS_MAX_ENTITIES;
    int complete = 1;
    for (uint32_t index = 0; index < count; index++)
    {
        uint64_t address = EcsAddressAt(pointers, index);
        int key = address != 0 ? KeyOf(listing, address, &left) : ECS_UNLISTED;
        if (key == ECS_UNKNOWN) complete = 0;
        else if (key >= 0) listing->listed[n++] = (uint16_t)index;
    }
    listing->n = n;
    listing->count = count;
    listing->complete = complete;
    listing->kept_valid = complete;
    listing->kept_count = complete ? count : 0;
    if (complete) memcpy(listing->kept, pointers, (size_t)count * 8u);
    Prune(listing, count);
    if (!complete) Ecs.budget.yielded = 1;
}

/* Re-reads a few known entries' headers; a changed one is reclassified and the listing rebuilt. */
static void Verify(EcsListing* listing, const uint64_t* pointers, uint32_t count)
{
    for (uint32_t i = 0; i < (count + SWEEP_POLLS - 1u) / SWEEP_POLLS; i++)
    {
        uint32_t index = listing->sweep % count;
        listing->sweep = index + 1u;
        uint64_t address = EcsAddressAt(pointers, index);
        EcsEntry* entry = address != 0 ? EcsListingFind(listing, address) : NULL;
        if (entry == NULL || entry->key == ECS_UNKNOWN) continue;
        uint32_t unit = 0;
        int fresh = Classify(address, &unit);
        if (fresh == UNREADABLE) continue;
        if (fresh == entry->key && (fresh < 0 || (entry->has_unit && entry->unit == unit))) continue;
        SetKey(entry, fresh, unit);
        listing->kept_valid = 0;
        Ecs.listing_changes++;
    }
}

static int Kept(const EcsListing* listing, const uint64_t* pointers, uint32_t count)
{
    return listing->kept_valid && listing->kept_count == count && memcmp(listing->kept, pointers, (size_t)count * 8u) == 0;
}

void EcsListingRefresh(EcsListing* listing, const uint64_t* pointers, uint32_t count, int first)
{
    if (first) Verify(listing, pointers, count);
    if (!Kept(listing, pointers, count)) Relist(listing, pointers, count);
}
