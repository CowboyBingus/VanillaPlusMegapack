/* Match Your Colors: the local player's Helldiver in game memory (avatar.lua, Steam build 25480438), 1:1. Player
 * manager [game + 0x3326468]: count +132, entity records +232 + 8 i (id +8, flags +20 bit 0 owned here), the map +208
 * from a player's entity id to its index, peer +712 + 56 i, Helldiver unit +936 + 32 i, UI slot +948 + 32 i.
 * Customization [game + 0x33264F8]: the map +2352 to its record, applied kits +2412 + 68 r (body, helmet, cape, armor),
 * desired +2684 + 64 r. Entities [game + 0x346BF98]: the map +0xF22EC8 from a unit to its entity, records +0xF32F18 +
 * 24 e. Avatars [game + 0x3326D20]: the map +248, count +0x6c, records +5532272 + 440 i with three arrays of 10 unit
 * refs at +220. Previews [game + 0x346D580]: player slots +2080 + 2184 s (peer +0, entry count +64, 132-byte entries
 * from +68, their unit arrays at +12). Game thread; reads only. */
#include <stdio.h>
#include <string.h>
#include "myc_runtime.h"

#define PLAYERS 0x3326468u
#define CUSTOMIZATION 0x33264F8u
#define ENTITIES 0x346BF98u
#define AVATARS 0x3326D20u
#define PREVIEWS 0x346D580u
#define P_COUNT 132
#define P_ENTITIES 232
#define P_MAP 208
#define P_PEERS 712
#define P_UNITS 936
#define P_UI_SLOT 948
#define C_MAP 2352
#define C_APPLIED 2412
#define C_APPLIED_SIZE 68
#define C_DESIRED 2684
#define C_DESIRED_SIZE 64
#define E_MAP 0xF22EC8u
#define E_RECORDS 0xF32F18u
#define A_MAP 248
#define A_COUNT 0x6c
#define A_RECORDS 5532272u
#define A_RECORD_SIZE 440
#define A_UNITS 220
#define V_SLOTS 2080
#define V_SLOT_SIZE 2184
#define V_SLOT_COUNT 5
#define V_COUNT 64
#define V_ENTRIES 68
#define V_UNITS 12
#define AVATAR_LOW 0x294dfa97u
#define AVATAR_HIGH 0x4d1c334du
#define MAX_PLAYERS 8
#define MAX_PROBES 64
#define READ_MAX 256

static uint32_t MycAvLe32(const uint8_t* p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

/* Avatar.reader's read: refused outside 0x10000 .. 2^47 or above READ_MAX bytes. */
static int MycAvRead(uintptr_t address, void* out, size_t size)
{
    if (address < 0x10000 || address >= 0x800000000000ull || size > READ_MAX) return 0;
    return vpm_read(address, out, size);
}

static uintptr_t MycAvPointer(uintptr_t address)
{
    uint8_t b[8];
    if (!MycAvRead(address, b, 8)) return 0;
    uint64_t v = MycAvLe32(b) | (uint64_t)MycAvLe32(b + 4) << 32;
    return v < 0x10000 || v >= 0x800000000000ull ? 0 : (uintptr_t)v;
}

static int MycAvWord(uintptr_t address, uint32_t* out)
{
    uint8_t b[4];
    if (!MycAvRead(address, b, 4)) return 0;
    *out = MycAvLe32(b);
    return 1;
}

int myc_avatar_lookup(uintptr_t address, uint32_t key, uint32_t* value)
{
    uint8_t b[20];
    if (!MycAvRead(address, b, 20)) return 0;
    uint64_t data = MycAvLe32(b) | (uint64_t)MycAvLe32(b + 4) << 32;
    uint32_t capacity = MycAvLe32(b + 8), empty = MycAvLe32(b + 12), multiplier = MycAvLe32(b + 16);
    if (capacity == 0 || capacity > 4194304 || data < 0x10000) return 0;
    uint32_t start = key * multiplier;
    for (uint32_t i = 0; i < (capacity < MAX_PROBES ? capacity : MAX_PROBES); i++)
    {
        uint8_t slot[8];
        if (!MycAvRead((uintptr_t)(data + 8 * (((uint64_t)start + i) % capacity)), slot, 8)) return 0;
        uint32_t found = MycAvLe32(slot);
        if (found == key) { *value = MycAvLe32(slot + 4); return 1; }
        if (found == empty) return 0;
    }
    return 0;
}

/* The player owned by this machine (local_player). */
static int MycAvLocalPlayer(MycIdentity* out, const char** why)
{
    uintptr_t players = MycAvPointer(vpm_game() + PLAYERS);
    out->players = players;
    if (players == 0) { *why = "no player manager"; return 0; }
    uint32_t count, entity_id = 0, index, unit;
    int found = 0;
    if (!MycAvWord(players + P_COUNT, &count) || count == 0 || count > MAX_PLAYERS) { *why = "no players"; return 0; }
    for (uint32_t i = 0; i < count && !found; i++)
    {
        uintptr_t entity = MycAvPointer(players + P_ENTITIES + 8 * i);
        uint8_t b[24];
        if (entity != 0 && MycAvRead(entity, b, 24) && b[20] % 2 == 1) { entity_id = MycAvLe32(b + 8); found = 1; }
    }
    if (!found) { *why = "no local player"; return 0; }
    if (!myc_avatar_lookup(players + P_MAP, entity_id, &index) || index >= MAX_PLAYERS) { *why = "local player not indexed"; return 0; }
    uint8_t peer[8];
    out->has_peer = MycAvRead(players + P_PEERS + 56 * index, peer, 8);
    out->peer_low = out->has_peer ? MycAvLe32(peer) : 0;
    out->peer_high = out->has_peer ? MycAvLe32(peer + 4) : 0;
    if (!MycAvWord(players + P_UNITS + 32 * index, &unit) || unit == 0) { *why = "no local Helldiver"; return 0; }
    out->player = entity_id;
    out->unit = unit;
    out->has_ui_slot = MycAvWord(players + P_UI_SLOT + 32 * index, &out->ui_slot);
    return 1;
}

static int MycAvAppliedKits(MycIdentity* out, const char** why)
{
    uintptr_t customization = MycAvPointer(vpm_game() + CUSTOMIZATION);
    uint32_t record;
    if (customization == 0 || !myc_avatar_lookup(customization + C_MAP, out->player, &record)) { *why = "no customization record"; return 0; }
    uint8_t kits[16];
    if (!MycAvRead(customization + C_APPLIED + (uintptr_t)C_APPLIED_SIZE * record, kits, 16)) { *why = "customization record unreadable"; return 0; }
    out->record = record;
    out->body = MycAvLe32(kits);
    out->helmet = MycAvLe32(kits + 4);
    out->cape = MycAvLe32(kits + 8);
    out->armor = MycAvLe32(kits + 12);
    return 1;
}

static int MycAvRecord(MycIdentity* out, int remote, const char** why)
{
    uintptr_t entities = MycAvPointer(vpm_game() + ENTITIES);
    uint32_t entity_index;
    if (entities == 0 || !myc_avatar_lookup(entities + E_MAP, out->unit, &entity_index)) { *why = "Helldiver entity not found"; return 0; }
    uint8_t e[24];
    if (!MycAvRead(entities + E_RECORDS + 24 * (uintptr_t)entity_index, e, 24) || MycAvLe32(e) != AVATAR_LOW
        || MycAvLe32(e + 4) != AVATAR_HIGH)
    {
        *why = "not an avatar entity";
        return 0;
    }
    if (!remote && e[20] % 2 == 0) { *why = "Helldiver not owned by this machine"; return 0; }
    uint32_t avatar_id = MycAvLe32(e + 8), index, count;
    uintptr_t avatars = MycAvPointer(vpm_game() + AVATARS);
    int ok = avatars != 0 && myc_avatar_lookup(avatars + A_MAP, avatar_id, &index);
    if (!ok || !MycAvWord(avatars + A_COUNT, &count) || index >= count) { *why = "avatar not indexed"; return 0; }
    out->avatar = avatar_id;
    out->avatar_index = index;
    out->units_at = avatars + A_RECORDS + (uintptr_t)A_RECORD_SIZE * index + A_UNITS;
    return 1;
}

int myc_avatar_resolve(MycIdentity* out, const char** why, int* found)
{
    memset(out, 0, sizeof *out);
    *found = MYC_FOUND_NOTHING;
    if (!MycAvLocalPlayer(out, why)) { *found = out->players != 0 ? MYC_FOUND_PLAYERS : MYC_FOUND_NOTHING; return 0; }
    if (!MycAvAppliedKits(out, why)) { *found = MYC_FOUND_PLAYERS; return 0; }
    if (!MycAvRecord(out, 0, why)) { *found = MYC_FOUND_KITS; return 0; }
    out->previews = MycAvPointer(vpm_game() + PREVIEWS);
    return 1;
}

int myc_avatar_resolve_remote(const MycIdentity* player, MycIdentity* out, const char** why)
{
    memset(out, 0, sizeof *out);
    out->player = player->player;
    out->unit = player->unit;
    out->peer_low = player->peer_low;
    out->peer_high = player->peer_high;
    out->has_peer = 1;
    return MycAvAppliedKits(out, why) && MycAvRecord(out, 1, why);
}

int myc_avatar_desired_kits(uint32_t player, uint32_t* helmet, uint32_t* armor, uint32_t* cape)
{
    uintptr_t customization = MycAvPointer(vpm_game() + CUSTOMIZATION);
    uint32_t record;
    uint8_t b[16];
    if (customization == 0 || !myc_avatar_lookup(customization + C_MAP, player, &record)
        || !MycAvRead(customization + C_DESIRED + (uintptr_t)C_DESIRED_SIZE * record, b, 16))
        return 0;
    *helmet = MycAvLe32(b + 4);
    *armor = MycAvLe32(b + 12);
    *cape = MycAvLe32(b + 8);
    return 1;
}

/* ---- every player ------------------------------------------------------------------------------------------------- */

typedef struct MycAvEntry { uint32_t entity, index; int is_local; } MycAvEntry;

/* This machine's players marked local among the n entries. */
static void MycAvMarkLocal(uintptr_t players, MycAvEntry* out, int n)
{
    uint32_t owned = 0;
    if (!MycAvWord(players + P_COUNT, &owned)) owned = 0;
    for (uint32_t k = 0; k < (owned < MAX_PLAYERS ? owned : MAX_PLAYERS); k++)
    {
        uintptr_t entity = MycAvPointer(players + P_ENTITIES + 8 * k);
        uint8_t b[24];
        if (entity == 0 || !MycAvRead(entity, b, 24) || b[20] % 2 != 1) continue;
        uint32_t id = MycAvLe32(b + 8);
        for (int i = 0; i < n; i++)
            if (out[i].entity == id) out[i].is_local = 1;
    }
}

/* Every player of the player manager's map (Avatar.player_entries); how many. */
static int MycAvEntries(uintptr_t players, MycAvEntry* out)
{
    uint8_t head[16];
    if (!MycAvRead(players + P_MAP, head, 16)) return 0;
    uint64_t data = MycAvLe32(head) | (uint64_t)MycAvLe32(head + 4) << 32;
    uint32_t capacity = MycAvLe32(head + 8), empty = MycAvLe32(head + 12);
    if (data < 0x10000 || capacity == 0 || capacity > 64) return 0;
    int n = 0;
    for (uint32_t first = 0; first < capacity; first += 32)
    {
        uint32_t count = capacity - first < 32 ? capacity - first : 32;
        uint8_t b[256];
        if (!MycAvRead((uintptr_t)(data + 8 * first), b, 8 * count)) return 0;
        for (uint32_t i = 0; i < count; i++)
        {
            uint32_t key = MycAvLe32(b + 8 * i), index = MycAvLe32(b + 8 * i + 4);
            if (key != empty && index < MAX_PLAYERS && n < MAX_PLAYERS) out[n++] = (MycAvEntry){key, index, 0};
        }
    }
    MycAvMarkLocal(players, out, n);
    return n;
}

int myc_avatar_players(MycPlayer* out)
{
    uintptr_t players = MycAvPointer(vpm_game() + PLAYERS);
    if (players == 0) return 0;
    MycAvEntry entries[MAX_PLAYERS];
    int n = MycAvEntries(players, entries), count = 0;
    for (int i = 0; i < n; i++)
    {
        uint8_t peer[8];
        uint32_t unit;
        if (!MycAvRead(players + P_PEERS + 56 * entries[i].index, peer, 8)) continue;
        if (!MycAvWord(players + P_UNITS + 32 * entries[i].index, &unit) || unit == 0) continue;
        out[count++] = (MycPlayer){entries[i].entity, entries[i].index, MycAvLe32(peer), MycAvLe32(peer + 4), unit, entries[i].is_local};
    }
    return count;
}

int myc_avatar_others_desired(MycDesired* out)
{
    uintptr_t players = MycAvPointer(vpm_game() + PLAYERS);
    if (players == 0) return 0;
    MycAvEntry entries[MAX_PLAYERS];
    int n = MycAvEntries(players, entries), count = 0;
    for (int i = 0; i < n; i++)
    {
        MycDesired d;
        if (!entries[i].is_local && myc_avatar_desired_kits(entries[i].entity, &d.helmet, &d.armor, &d.cape)) out[count++] = d;
    }
    return count;
}

void myc_avatar_players_text(char* out, size_t size)
{
    uintptr_t players = MycAvPointer(vpm_game() + PLAYERS);
    if (players == 0) { snprintf(out, size, "no player manager"); return; }
    MycAvEntry entries[MAX_PLAYERS];
    int n = MycAvEntries(players, entries);
    size_t at = 0;
    out[0] = 0;
    for (int i = 0; i < n && at < size; i++)
    {
        uint8_t peer[8] = {0};
        uint32_t unit = 0, slot = 0;
        int has_peer = MycAvRead(players + P_PEERS + 56 * entries[i].index, peer, 8);
        if (!MycAvWord(players + P_UNITS + 32 * entries[i].index, &unit)) unit = 0;
        int has_slot = MycAvWord(players + P_UI_SLOT + 32 * entries[i].index, &slot);
        at += (size_t)snprintf(out + at, size - at, "%sindex %u peer %08x%08x unit %x slot %d%s", i ? ", " : "", entries[i].index,
            has_peer ? MycAvLe32(peer + 4) : 0, has_peer ? MycAvLe32(peer) : 0, unit, has_slot ? (int)slot : -1,
            entries[i].is_local ? " (this machine's)" : "");
    }
    if (n == 0) snprintf(out, size, "no players");
}

/* ---- the preview slot, units and the watch ------------------------------------------------------------------------ */

uintptr_t myc_avatar_preview_slot(const MycIdentity* identity)
{
    if (identity->previews == 0 || !identity->has_peer) return 0;
    for (int s = 0; s < V_SLOT_COUNT; s++)
    {
        uintptr_t slot = identity->previews + V_SLOTS + (uintptr_t)V_SLOT_SIZE * s;
        uint8_t b[8];
        if (MycAvRead(slot, b, 8) && MycAvLe32(b) == identity->peer_low && MycAvLe32(b + 4) == identity->peer_high
            && (identity->peer_low != 0 || identity->peer_high != 0))
            return slot;
    }
    return 0;
}

static int MycAvCollect(uintptr_t address, int preview, int first, int last, MycUnitRef* out, int n, int max)
{
    uint8_t b[120];
    if (!vpm_read(address, b, 120)) return n;
    for (int t = 0; t < 3; t++)
        for (int s = first; s <= last; s++)
        {
            uint32_t unit = MycAvLe32(b + 40 * t + 4 * s);
            if (unit != 0 && unit != 0xFFFFFFFFu && n < max) out[n++] = (MycUnitRef){unit, t, s, preview, 0, 0, 0};
        }
    return n;
}

int myc_avatar_units(const MycIdentity* identity, uintptr_t slot, int first, int last, MycUnitRef* out, int max)
{
    int n = MycAvCollect(identity->units_at, 0, first, last, out, 0, max);
    uint32_t count;
    if (slot == 0 || !vpm_read_u32(slot + V_COUNT, &count)) return n;
    for (uint32_t k = 0; k < (count < MYC_MAX_PREVIEWS ? count : MYC_MAX_PREVIEWS); k++)
        n = MycAvCollect(slot + V_ENTRIES + MYC_PREVIEW_ENTRY * k + V_UNITS, 1, first, last, out, n, max);
    return n;
}

void myc_watch_init(MycWatch* w, const MycIdentity* identity, uintptr_t slot)
{
    memset(w, 0, sizeof *w);
    w->units_at = identity->units_at;
    w->copies_at = slot != 0 ? slot + V_COUNT : 0;
    w->copies_read = (int)sizeof w->copies_now;
}

static int MycWatchCount(const MycWatch* w)
{
    uint32_t count = MycAvLe32(w->copies_now);
    return (int)(count < MYC_MAX_PREVIEWS ? count : MYC_MAX_PREVIEWS);
}

/* The body-copy slot's count and entries: true when they changed (or cannot be read) since its last read. */
/* lint: per-frame */
static int MycWatchCopies(MycWatch* w)
{
    w->reads++;
    if (!vpm_read(w->copies_at, w->copies_now, (size_t)w->copies_read)) return 1;
    int count = MycWatchCount(w);
    int size = 4 + MYC_PREVIEW_ENTRY * count;
    if (size > w->copies_read)
    {
        w->reads++;
        if (!vpm_read(w->copies_at, w->copies_now, sizeof w->copies_now)) return 1;
        count = MycWatchCount(w);
        size = 4 + MYC_PREVIEW_ENTRY * count;
    }
    w->copies_read = size;
    if (w->copies_primed && memcmp(w->copies_now, w->copies_kept, (size_t)(4 + MYC_PREVIEW_ENTRY * count)) == 0) return 0;
    memcpy(w->copies_kept, w->copies_now, sizeof w->copies_kept);
    w->copies_primed = 1;
    return 1;
}

/* lint: per-frame */
int myc_watch_changed(MycWatch* w, int copies)
{
    w->reads++;
    int ok = vpm_read(w->units_at, w->now, 120);
    int changed = !ok || !w->primed || memcmp(w->now, w->kept, 120) != 0;
    if (changed && ok) memcpy(w->kept, w->now, 120);
    w->primed = 1;
    if (copies && w->copies_at != 0 && MycWatchCopies(w)) changed = 1;
    return changed;
}

uint32_t myc_watch_ref(const MycWatch* w, int i) { return w->kept[i]; }
