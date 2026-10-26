/* Better Lobby Management: nearby lobbies, the Lobby Region option (region.lua). Limits the game's own lobby searches
 * (Galactic Map scanner and quickplay) to the player's continent.
 *
 * The search builder adds "string_key6 ne <continent>" for every continent whose pair flag (own continent, other
 * continent) is a false bool in the override config (lookup 0x12E7990: the peer-synced table first, then
 * OnlineOverrideData). The server ships 16 false pairs; this makes the rest of the player's own row false in
 * OnlineOverrideData, in one write, and puts the table back byte for byte when switched off or when the component stops.
 * No extra search requests are made. The game replaces OnlineOverrideData only whole, when a config download's checksum
 * (stored after the entries) differs; the stored checksum is never changed, so the flags survive identical downloads and
 * a new table shows up as a new checksum. The peer-synced table (the host sends it to its clients) is never written.
 *
 * On HellForge: the local backend serves the live game's override config (game-client-config.json), so the flags are
 * written as in the Lua; but HellForge's lobby directory leaves the continent exclusions (string_key6 ne) out of every
 * search on purpose (LobbyDirectory.cs), so the option changes no search result there. */
#include <stdio.h>
#include "blm.h"

#define CONFIG_PTR 0x347CDF8u          /* override config object */
#define SYNCED_TABLE 0x12078u          /* OnlineOverrideDataPeerSynced (read only) */
#define TABLE 0xC050u                  /* OnlineOverrideData (the continent pairs) */
#define ENTRIES 0x20u                  /* +0 entries, +8 capacity, +12 empty key, +16 multiplier, +24 entry count */
#define COUNT 24u
#define CHECKSUM 0x6020u
#define CAPACITY 512u
#define ENTRY_SIZE 48u                 /* +0 key, +8 name, +12 parent, +16 key, +20 type, +24 value, +40 weight */
#define SPAN (ENTRIES + CAPACITY * ENTRY_SIZE) /* header and entries, checksum excluded */
#define TYPE_BOOL 7u
#define WEIGHT 0x42C80000u
#define KEY_A 0x673BC524u
#define KEY_B 0x5DF5D36Bu
#define CONTINENT_IDS_RVA 0x21D45B0u   /* the game's own copy of the ids */
#define VERIFY_FRAMES 120
#define K 0x5BD1E995u
#define CONTINENTS 7
#define MAX_MANAGED 48
#define MAX_WORDS (MAX_MANAGED * 12 + 1) /* a restore of every managed entry: 12 words each, then the count */

typedef struct ContinentId { const char* code; uint32_t id; } ContinentId;
static const ContinentId kContinents[CONTINENTS] = {{"AF", 0x9061BF63u}, {"AN", 0xC59A4447u}, {"AS", 0x617288E9u},
    {"EU", 0x0FAB5B27u}, {"NA", 0x29CE1E3Fu}, {"OC", 0xCCC7BF91u}, {"SA", 0xD044AF30u}};

typedef struct Pair { uint32_t key, id; const char* name; } Pair;
typedef struct Row { uint32_t key; const char* name; char status[40]; Pair pairs[CONTINENTS - 1]; } Row;
typedef struct Change { uintptr_t address; uint32_t key, original; int has_original; } Change;
typedef struct Word { uint32_t at, value; } Word;
typedef struct Plan { Word words[MAX_WORDS]; int words_count; Change changes[CONTINENTS]; int changes_count; int skipped[CONTINENTS]; int skipped_count; } Plan;

static Row g_rows[CONTINENTS];

static struct
{
    int mode, frames;
    Change managed[MAX_MANAGED];   /* entries written into the applied table */
    int managedCount;
    Change watch[MAX_MANAGED];     /* the periodic check's copy */
    int watchCount;
    uintptr_t appliedConfig;       /* what the last attempt saw */
    uint32_t appliedChecksum, appliedSynced;
    int appliedOwn;
    uintptr_t checkedConfig, badConfig, writableConfig;
    char lastWait[64];
    char status[64];
} s;

uint32_t blm_region_combine(const uint32_t* words, int count)
{
    uint32_t h = words[0];
    for (int i = 1; i < count; i++)
    {
        uint32_t a = K * words[i];
        uint32_t mixed = a ^ (a >> 24);
        h = (K * mixed) ^ (K * h);
    }
    return h;
}

static void BuildRows(void)
{
    for (int own = 0; own < CONTINENTS; own++)
    {
        Row* row = &g_rows[own];
        uint32_t rowWords[3] = {KEY_A, KEY_B, kContinents[own].id};
        row->key = blm_region_combine(rowWords, 3);
        row->name = kContinents[own].code;
        snprintf(row->status, sizeof row->status, "my continent only (%s)", row->name);
        int n = 0;
        for (int other = 0; other < CONTINENTS; other++)
        {
            if (other == own) continue;
            uint32_t pairWords[4] = {KEY_A, KEY_B, kContinents[own].id, kContinents[other].id};
            row->pairs[n++] = (Pair){blm_region_combine(pairWords, 4), kContinents[other].id, kContinents[other].code};
        }
    }
}

static void SetStatus(const char* text) { snprintf(s.status, sizeof s.status, "%s", text); }

void blm_region_reset(void)
{
    memset(&s, 0, sizeof s);
    s.mode = 1;
    SetStatus("game default");
    BuildRows();
}

const char* blm_region_status(void) { return s.status; }

int blm_region_verify(const char** why)
{
    for (int i = 0; i < CONTINENTS; i++)
        if (vpm_game_u32(CONTINENT_IDS_RVA + (uint32_t)i * 4u) != kContinents[i].id) { *why = "continent table changed"; return 0; }
    return blm_game_code_ok(blm_region_code, blm_region_code_count, why);
}

/* The entry for key (1 with *entry), or 0 with *empty the first empty slot on its probe path (0: none). taken: planned
 * slots that count as occupied. The game's probe order (empty checked before the key). Direct loads. */
static int Lookup(uintptr_t table, uint32_t key, const Plan* taken, uintptr_t* entry, uintptr_t* empty)
{
    uintptr_t entries = (uintptr_t)blm_load64(table);
    uint32_t capacity = blm_load32(table + 8), emptyKey = blm_load32(table + 12), multiplier = blm_load32(table + 16);
    uint32_t start = key * multiplier;
    *empty = 0;
    for (uint32_t i = 0; i < capacity; i++)
    {
        uintptr_t at = entries + (uintptr_t)((start + i) & (capacity - 1)) * ENTRY_SIZE;
        uint32_t found = blm_load32(at);
        int planned = 0;
        for (int c = 0; taken != NULL && c < taken->changes_count; c++) planned |= taken->changes[c].address == at;
        if (found == emptyKey && !planned) { *empty = at; return 0; }
        if (found != emptyKey && found == key) { *entry = at; return 1; }
    }
    return 0;
}

static int IsFalseBool(uintptr_t entry) { return blm_load32(entry + 20) == TYPE_BOOL && blm_load8(entry + 24) == 0; }

/* A table with the layout the game's code uses (inline 512-slot entries): guarded reads. */
static int TableOk(uintptr_t address)
{
    uint64_t entries;
    uint32_t capacity, multiplier, checksum;
    return vpm_read_u64(address, &entries) && entries == address + ENTRIES && vpm_read_u32(address + 8, &capacity) &&
        capacity == CAPACITY && vpm_read_u32(address + 16, &multiplier) && multiplier != 0 &&
        vpm_read_u32(address + CHECKSUM, &checksum);
}

/* The config object, or 0 with *why. A new object is checked once with guarded reads; later calls use direct loads. */
static uintptr_t ConfigObject(const char** why)
{
    uintptr_t config = (uintptr_t)blm_global(CONFIG_PTR);
    if (config == 0 || config % 8 != 0) { *why = "override data unavailable"; return 0; }
    if (config != s.checkedConfig)
    {
        if (config == s.badConfig || !TableOk(config + TABLE) || !TableOk(config + SYNCED_TABLE))
        {
            s.badConfig = config;
            *why = "override table layout changed";
            return 0;
        }
        s.checkedConfig = config;
    }
    if (blm_load32(config + TABLE + COUNT) == 0) { *why = "override data not loaded"; return 0; }
    return config;
}

/* The player's continent (1 .. 7), or 0 when not known (before sign-in): the engine returns its two-letter code. */
static int OwnContinent(void)
{
    uintptr_t text = (uintptr_t)blm_native.continent(blm_native.lobby_api);
    if (text == 0 || blm_load8(text + 2) != 0) return 0;
    for (int i = 0; i < CONTINENTS; i++)
        if (blm_load8(text) == (uint8_t)kContinents[i].code[0] && blm_load8(text + 1) == (uint8_t)kContinents[i].code[1]) return i + 1;
    return 0;
}

/* No pair of the row needs a write. Direct loads only. */
static int Settled(uintptr_t main, uintptr_t synced, const Row* row)
{
    for (int i = 0; i < CONTINENTS - 1; i++)
    {
        uintptr_t entry, empty;
        if (Lookup(synced, row->pairs[i].key, NULL, &entry, &empty)) continue;
        if (!Lookup(main, row->pairs[i].key, NULL, &entry, &empty)) return 0;
        if (blm_load32(entry + 20) == TYPE_BOOL && blm_load8(entry + 24) != 0) return 0;
    }
    return 1;
}

static void Push(Plan* plan, uint32_t at, uint32_t value)
{
    if (plan->words_count < MAX_WORDS) plan->words[plan->words_count++] = (Word){at, value};
}

/* A new entry like the server's own; the key goes in last. */
static void PlanAdd(Plan* plan, uintptr_t main, uintptr_t slot, const Row* row, const Pair* pair)
{
    uint32_t o = (uint32_t)(slot - main);
    const uint32_t fields[11] = {0, pair->id, row->key, pair->key, TYPE_BOOL, 0, 0, 0, 0, WEIGHT, 0};
    for (int f = 0; f < 11; f++) Push(plan, o + 4u + 4u * (uint32_t)f, fields[f]);
    Push(plan, o, pair->key);
    plan->changes[plan->changes_count++] = (Change){slot, pair->key, 0, 0};
}

/* One pair's part of the plan: 1, or 0 when the table is full. */
static int PlanPair(Plan* plan, uintptr_t main, uintptr_t synced, const Row* row, int i)
{
    const Pair* pair = &row->pairs[i];
    uintptr_t entry, slot;
    if (Lookup(synced, pair->key, NULL, &entry, &slot))
    {
        if (!IsFalseBool(entry)) plan->skipped[plan->skipped_count++] = i; /* the peer-synced table answers first */
        return 1;
    }
    if (Lookup(main, pair->key, plan, &entry, &slot))
    {
        if (blm_load32(entry + 20) != TYPE_BOOL) plan->skipped[plan->skipped_count++] = i;
        else if (blm_load8(entry + 24) != 0)
        {
            Push(plan, (uint32_t)(entry - main) + 24u, 0);
            plan->changes[plan->changes_count++] = (Change){entry, pair->key, blm_load32(entry + 24), 1};
        }
        return 1;
    }
    if (slot == 0) return 0;
    PlanAdd(plan, main, slot, row, pair);
    return 1;
}

/* The stores that make every pair of the row a false bool: 1, or 0 with *why. Direct loads only. */
static int MakePlan(Plan* plan, uintptr_t main, uintptr_t synced, const Row* row, const char** why)
{
    memset(plan, 0, sizeof *plan);
    int added = 0;
    for (int i = 0; i < CONTINENTS - 1; i++)
    {
        int before = plan->changes_count;
        if (!PlanPair(plan, main, synced, row, i)) { *why = "override table full"; return 0; }
        if (plan->changes_count > before && !plan->changes[plan->changes_count - 1].has_original) added++;
    }
    if (added > 0) Push(plan, COUNT, blm_load32(main + COUNT) + (uint32_t)added);
    return 1;
}

/* The table's stores, its page checked once per config object (the Lua checked before every write). */
static int Store(uintptr_t config, const Word* words, int count)
{
    uintptr_t main = config + TABLE;
    if (s.writableConfig != config)
    {
        if (!blm_writable(main, SPAN)) return 0;
        s.writableConfig = config;
    }
    for (int i = 0; i < count; i++) memcpy((void*)(main + words[i].at), &words[i].value, 4);
    return 1;
}

static void Manage(const Change* change)
{
    for (int i = 0; i < s.managedCount; i++)
        if (s.managed[i].address == change->address) { s.managed[i] = *change; return; }
    if (s.managedCount < MAX_MANAGED) s.managed[s.managedCount++] = *change;
}

static void NoteSkipped(const Row* row, const Plan* plan)
{
    char text[160];
    size_t n = 0;
    for (int i = 0; i < plan->skipped_count && n < sizeof text; i++)
        n += (size_t)snprintf(text + n, sizeof text - n, "%s%s->%s", i > 0 ? ", " : "", row->name, row->pairs[plan->skipped[i]].name);
    vpm_log(blm_component, "nearby lobbies: %s set by the peer-synced config; left unchanged", text);
}

/* Makes the player's row false: the entries written (0 when in place), or -1 with *why. */
static int WriteRow(uintptr_t config, int own, const char** why)
{
    static Plan plan; /* 5 KB, off the game thread's stack */
    uintptr_t main = config + TABLE, synced = config + SYNCED_TABLE;
    const Row* row = &g_rows[own - 1];
    if (Settled(main, synced, row)) return 0;
    if (!MakePlan(&plan, main, synced, row, why)) return -1;
    if (!Store(config, plan.words, plan.words_count)) { *why = "write refused"; return -1; }
    for (int i = 0; i < plan.changes_count; i++) Manage(&plan.changes[i]);
    if (plan.skipped_count > 0) NoteSkipped(row, &plan);
    return plan.changes_count;
}

/* One attempt: the entries written, or -1 with *why. */
static int Apply(const char** why)
{
    uintptr_t config = ConfigObject(why);
    if (config == 0) return -1;
    int own = OwnContinent();
    if (own == 0) { *why = "continent unknown"; return -1; }
    uint32_t checksum = blm_load32(config + TABLE + CHECKSUM);
    if (config != s.appliedConfig || checksum != s.appliedChecksum) s.managedCount = 0; /* the game replaced the table */
    s.appliedConfig = config;
    s.appliedChecksum = checksum;
    s.appliedOwn = own;
    s.appliedSynced = blm_load32(config + SYNCED_TABLE + CHECKSUM);
    int written = WriteRow(config, own, why);
    memcpy(s.watch, s.managed, sizeof s.managed);
    s.watchCount = s.managedCount;
    if (written < 0) return -1;
    if (strcmp(s.status, g_rows[own - 1].status) != 0) SetStatus(g_rows[own - 1].status);
    s.lastWait[0] = 0;
    return written;
}

/* Nothing changed since the last attempt: the same tables, the same continent and every written entry in place. Direct
 * loads only; a refused write or a full table is not tried again until this changes. */
static int Unchanged(void)
{
    uintptr_t config = (uintptr_t)blm_global(CONFIG_PTR);
    if (config == 0 || config != s.appliedConfig || blm_load32(config + TABLE + CHECKSUM) != s.appliedChecksum ||
        blm_load32(config + SYNCED_TABLE + CHECKSUM) != s.appliedSynced)
        return 0;
    int own = OwnContinent();
    if (own == 0 || own != s.appliedOwn) return 0;
    for (int i = 0; i < s.watchCount; i++)
        if (blm_load32(s.watch[i].address) != s.watch[i].key || blm_load8(s.watch[i].address + 24) != 0) return 0;
    return 1;
}

/* One managed entry back: flipped flags get their value again, added entries are removed. 1 restored, 0 not ours. */
static int RestoreEntry(const Change* change, uintptr_t main, uint32_t emptyKey, Plan* plan, int* removed)
{
    if (blm_load32(change->address) != change->key || blm_load8(change->address + 24) != 0) return 0;
    uint32_t o = (uint32_t)(change->address - main);
    if (change->has_original)
    {
        Push(plan, o + 24u, change->original);
        return 1;
    }
    Push(plan, o, emptyKey);
    for (uint32_t field = 4; field <= ENTRY_SIZE - 4; field += 4) Push(plan, o + field, 0);
    (*removed)++;
    return 1;
}

int blm_region_restore(void)
{
    static Plan plan;
    int restored = 0, removed = 0;
    uintptr_t config = (uintptr_t)blm_global(CONFIG_PTR), main = config + TABLE;
    if (s.managedCount > 0 && config != 0 && config == s.appliedConfig && blm_load32(main + CHECKSUM) == s.appliedChecksum)
    {
        memset(&plan, 0, sizeof plan);
        uint32_t emptyKey = blm_load32(main + 12);
        for (int i = 0; i < s.managedCount; i++) restored += RestoreEntry(&s.managed[i], main, emptyKey, &plan, &removed);
        if (removed > 0) Push(&plan, COUNT, blm_load32(main + COUNT) - (uint32_t)removed);
        if (plan.words_count > 0 && !Store(config, plan.words, plan.words_count)) restored = 0;
    }
    s.managedCount = s.watchCount = 0;
    s.appliedConfig = 0;
    s.appliedChecksum = s.appliedSynced = 0;
    s.appliedOwn = 0;
    SetStatus("game default");
    return restored;
}

/* A reason is reported once; the next check tries again. */
static void Wait(const char* why)
{
    if (strcmp(s.lastWait, why) == 0) return;
    snprintf(s.lastWait, sizeof s.lastWait, "%s", why);
    char text[96];
    snprintf(text, sizeof text, "my continent only: waiting (%s)", why);
    SetStatus(text);
    vpm_log(blm_component, "nearby lobbies: waiting (%s)", why);
}

/* 1: game default, 2: own continent only. */
int blm_region_set_mode(int mode)
{
    if (mode == s.mode) return 1;
    s.mode = mode;
    if (mode == 2)
    {
        s.frames = 0;
        s.lastWait[0] = 0;
        const char* why = "";
        int written = Apply(&why);
        if (written < 0) { Wait(why); return 0; }
        vpm_log(blm_component, "nearby lobbies: own continent only, %d flags written", written);
        return 1;
    }
    vpm_log(blm_component, "nearby lobbies: game default, %d flags restored", blm_region_restore());
    return 1;
}

/* lint: per-frame. Every VERIFY_FRAMES frames while the option is on: write again after the game replaced the table
 * (or when the first attempt had to wait). */
void blm_region_step(void)
{
    if (s.mode != 2) return;
    if (++s.frames < VERIFY_FRAMES) return;
    s.frames = 0;
    if (Unchanged()) return;
    const char* why = "";
    int written = Apply(&why);
    if (written < 0) Wait(why);
    else if (written > 0)
    {
        s.lastWait[0] = 0;
        vpm_log(blm_component, "nearby lobbies: re-applied, %d flags written", written);
    }
}
