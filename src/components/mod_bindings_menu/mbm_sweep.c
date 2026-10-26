/* Mod Bindings Menu's binding sweep and the fixed slots' keyboard defaults (the Lua's src/sweep.lua, unchanged).
 *
 * The dormant actions ship with developer defaults (controller buttons, the mouse, Enter, Escape...). They must never
 * fire a mod binding, and a mapping the player chose must never be deleted, even one equal to a developer default:
 *   - Only actions a binding uses this session are swept.
 *   - The first time a binding uses an action, its mappings equal to one of the action's shipped defaults (the fixed
 *     slots' own keyboard default aside) are cleared, once; the action's mark records the session and fingerprints of
 *     the list found and the list left.
 *   - Afterwards only a list that is exactly the shipped defaults, or exactly the list found then, is cleaned again (the
 *     game restored it). After a binding page closed, one action changed into a single mapping a capture can make is
 *     the player's choice even then, unless other actions were restored with it.
 *   - An action handed over from an expired binding is cleared entirely.
 *   - RepeatInterval button mappings become Press (the page has no selector for it).
 *   - Native Revert copies the current page's devices from the defaults map: that map is kept free of developer
 *     defaults too, the untouched records kept here so old saved lists are still recognised.
 * The six fixed slots' keyboard defaults (slot 1 Tab, slots 3-7 F1, F5, F6, F7, F8) are added while the game runs:
 * where a map holds the game's stock list, its first keyboard mapping becomes the slot's key.
 * Cost: per sweep two reads per registered action (its defaults and live records), a write only when a list changes. */
#include <string.h>
#include "mbm.h"

#define MBM_WORDS (MBM_RECORD_SIZE / 4u)
#define MBM_KEYBOARD_DEVICE 3u
#define MBM_BUTTON_INPUT 4u
#define MBM_REPEAT_INTERVAL 8u
#define MBM_TRIGGER_PRESS 0u
#define MBM_FIXED 6
#define MBM_STEP_CLEAR 1
#define MBM_STEP_FIRST 2
#define MBM_STEP_RESTORED 3
#define MBM_STEP_CHANGED 4

/* {code, flags (Keyboard, Button, any device slot, Press, virtual key in bits 20-31), key word (49 + virtual key)} */
static const uint32_t kMbmKeyboardDefaults[MBM_FIXED][3] = {
    {12u * 65536u + 1u, 0x0090FF43u, 0x3Au}, {10u * 65536u + 1u, 0x0700FF43u, 0xA1u},
    {10u * 65536u + 4u, 0x0740FF43u, 0xA5u}, {10u * 65536u + 8u, 0x0750FF43u, 0xA6u},
    {10u * 65536u + 14u, 0x0760FF43u, 0xA7u}, {10u * 65536u + 9u, 0x0770FF43u, 0xA8u},
};

typedef struct MbmAdded
{
    int present, placed, ready;
    uint32_t stock, added;          /* fingerprints of the game's stock list and of the list added */
    uint32_t record[MBM_WORDS];
} MbmAdded;

typedef struct MbmOriginal
{
    int present;
    uint32_t fingerprint, cleaned;  /* the record found, and the same once cleaned */
    uint32_t words[MBM_WORDS];
} MbmOriginal;

static struct
{
    MbmAdded added[MBM_FIXED];
    MbmOriginal originals[MBM_ACTIONS];
    uint32_t writes;
} s_sweep;

/* The live record and the shipped defaults' record, read in place (static: 328 bytes each). */
static uint32_t g_mbmLive[MBM_WORDS], g_mbmShipped[MBM_WORDS];

void mbm_sweep_reset(void)
{
    memset(&s_sweep, 0, sizeof s_sweep);
    memset(g_mbmLive, 0, sizeof g_mbmLive);
    memset(g_mbmShipped, 0, sizeof g_mbmShipped);
}

static uint32_t MbmAt(uint32_t index) { return 2u + index * 5u; }
static uint32_t MbmMix(uint32_t hash, uint32_t value) { return (hash ^ value) * 16777619u; }

/* FNV-1a over a record's mapping count and every mapping's words, bytes 6-7 aside: equal lists, equal fingerprints. */
uint32_t mbm_fingerprint(const uint32_t* words)
{
    uint32_t hash = MbmMix(2166136261u, words[1]);
    for (uint32_t i = 0; i < words[1] && i < MBM_MAX_MAPPINGS; i++)
    {
        const uint32_t* m = words + MbmAt(i);
        hash = MbmMix(MbmMix(MbmMix(MbmMix(MbmMix(hash, m[0]), m[1] & 0xFFFFu), m[2]), m[3]), m[4]);
    }
    return hash;
}

static int MbmFixedIndex(uint32_t code)
{
    for (int k = 0; k < MBM_FIXED; k++)
        if (kMbmKeyboardDefaults[k][0] == code) return k;
    return -1;
}

/* The added record for a fixed slot, from its stock record: the first keyboard mapping replaced by the slot's key, any
 * other keyboard mapping dropped. */
static void MbmDerive(MbmAdded* entry, int k, const uint32_t* words)
{
    entry->stock = mbm_fingerprint(words);
    memset(entry->record, 0, sizeof entry->record);
    entry->record[0] = words[0];
    uint32_t count = 0;
    for (uint32_t i = 0; i < words[1]; i++)
    {
        const uint32_t* from = words + MbmAt(i);
        int keyboard = (from[0] & 0xFu) == MBM_KEYBOARD_DEVICE;
        if (keyboard && entry->placed) continue;
        uint32_t* to = entry->record + MbmAt(count++);
        memcpy(to, from, MBM_MAPPING_SIZE);
        if (!keyboard) continue;
        to[0] = kMbmKeyboardDefaults[k][1];
        to[1] = kMbmKeyboardDefaults[k][2];
        to[2] = MBM_TRIGGER_PRESS;
        entry->placed = 1;
    }
    entry->record[1] = count;
    entry->added = mbm_fingerprint(entry->record);
}

/* Writes the added list over the game's record at bucket, and over words read from it, when the record holds the stock
 * list. which: the map, for the log (NULL while the default is first added). */
static int MbmRestoreAdded(int k, uintptr_t bucket, uint32_t* words, const char* which)
{
    MbmAdded* entry = &s_sweep.added[k];
    if (!entry->placed || entry->stock == entry->added || mbm_fingerprint(words) != entry->stock) return 0;
    if (!mbm_maps_writable(bucket)) return 0;
    memcpy(words + 1, entry->record + 1, MBM_RECORD_SIZE - 4u);
    memcpy((void*)(bucket + 4u), entry->record + 1, MBM_RECORD_SIZE - 4u);
    s_sweep.writes++;
    if (entry->ready && which != NULL)
        vpm_log(mbm.self, "Added the keyboard default of %u:%u again: the game restored its stock list (%s).",
            kMbmKeyboardDefaults[k][0] >> 16, kMbmKeyboardDefaults[k][0] & 0xFFFFu, which);
    return 1;
}

/* Reads code's record from a map into words, whole: its cached address (1 read), else the map indexed again. A fixed
 * slot's record holding the stock list gets the added list first. Returns the record's address, or 0. */
static uintptr_t MbmReadRecord(uint32_t map, uint32_t code, uint32_t* words)
{
    uintptr_t bucket = mbm_map_cached(map, code);
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (bucket != 0 && vpm_read(bucket, words, MBM_RECORD_SIZE) && words[0] == code && words[1] <= MBM_MAX_MAPPINGS)
        {
            int k = MbmFixedIndex(code);
            if (k >= 0 && s_sweep.added[k].present)
                (void)MbmRestoreAdded(k, bucket, words, map == MBM_DEFAULTS_MAP ? "reset defaults" : "live");
            return bucket;
        }
        mbm_map_forget(map, code);
        bucket = mbm_map_bucket(map, code);
    }
    return 0;
}

/* Once per session when native input is ready, and by the sweep for a slot not readable then: each fixed slot's stock
 * list from the defaults map, then both maps get the added list where they hold the stock one. 2 reads per slot. */
void mbm_add_keyboard_defaults(void)
{
    int pending = 0;
    uint32_t before = s_sweep.writes;
    for (int k = 0; k < MBM_FIXED; k++)
    {
        MbmAdded* entry = &s_sweep.added[k];
        if (entry->present) continue;
        uintptr_t bucket = MbmReadRecord(MBM_DEFAULTS_MAP, kMbmKeyboardDefaults[k][0], g_mbmLive);
        if (bucket == 0) { pending = 1; continue; }
        MbmDerive(entry, k, g_mbmLive);
        entry->present = 1;
        if (!entry->placed)
            vpm_log(mbm.self, "Fixed slot action %u:%u has no keyboard mapping; its default is not added.",
                kMbmKeyboardDefaults[k][0] >> 16, kMbmKeyboardDefaults[k][0] & 0xFFFFu);
        (void)MbmRestoreAdded(k, bucket, g_mbmLive, NULL);
        (void)MbmReadRecord(MBM_BINDING_MAP, kMbmKeyboardDefaults[k][0], g_mbmShipped); /* writes it if stock */
        entry->ready = 1;
    }
    mbm.keyboard_pending = pending;
    if (s_sweep.writes > before)
        vpm_log(mbm.self, "Added Mod Bindings Menu's keyboard defaults to %u binding records.", s_sweep.writes - before);
}

static int MbmSameMapping(const uint32_t* a, uint32_t ai, const uint32_t* b, uint32_t bi)
{
    const uint32_t* x = a + MbmAt(ai);
    const uint32_t* y = b + MbmAt(bi);
    return x[0] == y[0] && (x[1] & 0xFFFFu) == (y[1] & 0xFFFFu) && x[2] == y[2] && x[3] == y[3] && x[4] == y[4];
}

/* Whether live mapping index is one of the action's shipped developer defaults. */
static int MbmInherited(uint32_t code, uint32_t index)
{
    int fixed = MbmFixedIndex(code) >= 0;
    for (uint32_t other = 0; other < g_mbmShipped[1] && other < MBM_MAX_MAPPINGS; other++)
    {
        int own = fixed && (g_mbmShipped[MbmAt(other)] & 0xFu) == MBM_KEYBOARD_DEVICE;
        if (!own && MbmSameMapping(g_mbmLive, index, g_mbmShipped, other)) return 1;
    }
    return 0;
}

/* A RepeatInterval button mapping becomes Press, in both places the trigger is stored. */
static int MbmPress(uint32_t index)
{
    uint32_t* m = g_mbmLive + MbmAt(index);
    if (((m[0] >> 4) & 0xFu) != MBM_BUTTON_INPUT || m[2] != MBM_REPEAT_INTERVAL) return 0;
    m[0] = (m[0] & ~0xF0000u) | (MBM_TRIGGER_PRESS << 16);
    m[2] = 0;
    return 1;
}

/* Writes the live record's first count mappings, the rest zeroed, and the count over the game's record. */
static int MbmWriteRecord(uintptr_t bucket, uint32_t count)
{
    if (!mbm_maps_writable(bucket)) return 0;
    memset(g_mbmLive + MbmAt(count), 0, (MBM_MAX_MAPPINGS - count) * MBM_MAPPING_SIZE);
    g_mbmLive[1] = count;
    memcpy((void*)(bucket + MBM_MAPPINGS), g_mbmLive + 2, MBM_MAX_MAPPINGS * MBM_MAPPING_SIZE);
    memcpy((void*)(bucket + 4u), g_mbmLive + 1, 4);
    return 1;
}

/* Keeps the live mappings (all, or all but the inherited ones when clean), RepeatInterval buttons made Press, and
 * writes the record back if anything changed. Returns how many it removed, -1 when the record could not be written. */
static int MbmCompact(uintptr_t bucket, uint32_t code, int clean)
{
    uint32_t count = g_mbmLive[1], kept = 0;
    int changed = 0;
    for (uint32_t i = 0; i < count; i++)
    {
        if (clean && MbmInherited(code, i)) continue;
        if (kept < i) memmove(g_mbmLive + MbmAt(kept), g_mbmLive + MbmAt(i), MBM_MAPPING_SIZE);
        if (MbmPress(kept)) changed = 1;
        kept++;
    }
    if ((changed || kept < count) && !MbmWriteRecord(bucket, kept)) return -1;
    return (int)(count - kept);
}

/* The defaults record of a registered action: kept as found before it is cleaned, so a re-parse gives a fresh copy. */
static int MbmPrepareDefaults(uint32_t code)
{
    int index = mbm_code_index(code);
    uintptr_t bucket = MbmReadRecord(MBM_DEFAULTS_MAP, code, g_mbmLive);
    if (index < 0 || bucket == 0) return 0;
    MbmOriginal* saved = &s_sweep.originals[index];
    uint32_t found = mbm_fingerprint(g_mbmLive);
    if (saved->present && found == saved->cleaned) return 1;
    saved->present = 1;
    memcpy(saved->words, g_mbmLive, MBM_RECORD_SIZE);
    saved->fingerprint = found;
    memcpy(g_mbmShipped, g_mbmLive, MBM_RECORD_SIZE);
    (void)MbmCompact(bucket, code, 1); /* an unwritable map keeps its record; the next check finds it again */
    saved->cleaned = mbm_fingerprint(g_mbmLive);
    return 1;
}

/* Safe while a binding page is open: only the reset source changes. 1 when every registered action's is ready.
 * lint: per-frame */
int mbm_sanitize_defaults(void)
{
    mbm.defaults_pending = 0;
    int ready = 1;
    for (int i = 0; i < mbm.order_count; i++)
    {
        MbmRecord* record = mbm.order[i];
        record->defaults_ready = (uint8_t)MbmPrepareDefaults(record->code);
        ready = record->defaults_ready && ready;
    }
    return ready;
}

/* What the sweep does with an action: nothing (0), clear, clean the first time, a restored list, a changed list; -1
 * unreadable. *single: a restored list one capture could have made (one mapping, not RepeatInterval). */
static int MbmPlan(MbmRecord* record, int* single)
{
    *single = 0;
    if (!record->defaults_ready || !MbmReadRecord(MBM_BINDING_MAP, record->code, g_mbmLive)) return -1;
    uint32_t found = 0, left = 0;
    int mark = mbm_mark(record->code, &found, &left);
    if (mark == 0) return MBM_STEP_FIRST;
    if (mark == 2) return MBM_STEP_CLEAR;
    uint32_t list = mbm_fingerprint(g_mbmLive);
    if (list == left)
    {
        record->swept_count = g_mbmLive[1];
        return 0;
    }
    if (list == found || list == s_sweep.originals[mbm_code_index(record->code)].fingerprint)
    {
        *single = g_mbmLive[1] == 1 && g_mbmLive[MbmAt(0) + 2] != MBM_REPEAT_INTERVAL;
        return MBM_STEP_RESTORED;
    }
    return MBM_STEP_CHANGED;
}

/* A clean (first use, or a restored list taken as a restore) or a keep of a binding's live list; how many mappings it
 * removed, -1 when its record could not be written. */
static int MbmTidy(MbmRecord* record, uintptr_t bucket, int step, int wholesale)
{
    int clean = step == MBM_STEP_FIRST || (step == MBM_STEP_RESTORED && wholesale);
    if (clean) memcpy(g_mbmShipped, s_sweep.originals[mbm_code_index(record->code)].words, MBM_RECORD_SIZE);
    if (step == MBM_STEP_RESTORED && !wholesale)
        vpm_log(mbm.self, "Kept the single mapping chosen for %s on a binding page, although it equals a developer default.",
            record->id);
    return MbmCompact(bucket, record->code, clean);
}

/* Carries out a binding's plan; wholesale: restored lists are restores. How many mappings it removed, -1 none read. */
static int MbmApply(MbmRecord* record, int wholesale)
{
    int step = record->plan;
    uintptr_t bucket = MbmReadRecord(MBM_BINDING_MAP, record->code, g_mbmLive);
    if (bucket == 0) return -1;
    uint32_t found = mbm_fingerprint(g_mbmLive);
    int removed = step == MBM_STEP_CLEAR ? (int)g_mbmLive[1] : MbmTidy(record, bucket, step, wholesale);
    if (removed < 0 || (step == MBM_STEP_CLEAR && !MbmWriteRecord(bucket, 0))) return -1;
    uint32_t left = mbm_fingerprint(g_mbmLive);
    if (step == MBM_STEP_FIRST || step == MBM_STEP_CLEAR) mbm_mark_set(record->code, 1, found, left);
    else mbm_mark_set(record->code, 3, 0, left);
    record->swept_count = g_mbmLive[1];
    return removed;
}

/* Every registered action's plan; whether restored lists are restores (1 or 0), or -1 when a record could not be read
 * (the sweep then changes nothing). */
static int MbmPlanAll(void)
{
    int restored = 0, wholesale = !mbm.page_visited;
    for (int i = 0; i < mbm.order_count; i++) mbm.order[i]->plan = 0;
    for (int i = 0; i < mbm.order_count; i++)
    {
        int single = 0, step = MbmPlan(mbm.order[i], &single);
        if (step < 0) return -1;
        mbm.order[i]->plan = (uint8_t)step;
        if (step != MBM_STEP_RESTORED) continue;
        restored++;
        wholesale = wholesale || !single;
    }
    return wholesale || restored > 1;
}

/* Sweeps the actions of the bindings registered this session. Restored lists are restores unless a binding page
 * closed since the last sweep and the only restored list is one a single capture can make. lint: per-frame */
void mbm_sweep(void)
{
    if (mbm.keyboard_pending) mbm_add_keyboard_defaults();
    /* A failed read cannot consume the page visit: it still explains a capture when the next sweep can read. */
    int wholesale = mbm_sanitize_defaults() ? MbmPlanAll() : -1;
    if (wholesale < 0) return;
    int removed = 0, complete = 1;
    for (int i = 0; i < mbm.order_count; i++)
    {
        MbmRecord* record = mbm.order[i];
        int count = record->plan != 0 ? MbmApply(record, wholesale) : 0;
        complete = count >= 0 && complete;
        if (count > 0) removed += count;
        record->plan = 0;
    }
    if (complete) mbm.page_visited = 0;
    if (removed > 0) vpm_log(mbm.self, "Removed %d inherited developer mappings.", removed);
}
