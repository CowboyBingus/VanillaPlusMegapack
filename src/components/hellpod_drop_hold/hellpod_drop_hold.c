/* Hellpod Drop Hold v1.2.1 (Lua: components/HellpodDropHold/src/drop_hold.lua and archive_loader.lua), build 25480438.
 *
 * Holds the local player's own drop pod in the sky while the player cannot see the world, and lets it fall as a normal
 * drop in the frame they can. The host spawns a joining player's drop as soon as that player's record exists, and the
 * player's own machine creates, owns (entity flag bit 0) and simulates the pod; on a slow PC it falls, even lands, behind
 * the loading screen or the join cutscene. The owning machine moves a pod down by
 * ((1 - t) * braking_velocity + t * initial_velocity) * dt every frame, t being the float at its local state +32: 1 at
 * spawn, decaying toward 0 only while braking and only while above 0. Holding is one store of
 * t_hold = (0.5 - braking) / (initial - braking), so the pod sinks at 0.5 m/s; releasing stores the saved t back.
 *
 * The signals (every 0.25 s while idle; every frame while a loading period or a hold lasts):
 * - a loading screen: the game state [[game + 0x3326340] + 0xAC21C] is 5 or 6 (preparing the ship or a mission), or
 *   menu presenter 2 or 4 (LoadingMission, LoadingTutorial) is current or anywhere on the menu stack (the PresenterManager
 *   [game + 0x347CE28] + 0x4288: HUD, menu and popup presenter at +8, +12, +16, five stack ids at +20, depth at +40);
 * - in the mission (4) or its preparation (6), once a loading screen started the period: a cutscene playing or queued
 *   ([game + 0x346D530] + 6412, then +6416), or the session's is_hotjoining ([game + 0x347CEF0] + 92135) at 1. Both end
 *   in the client's synchronized-tasks-done (0xAD4520). Only a loading screen starts a loading period.
 * While one lasts, the HellpodComponent manager ([game + 0x3326D58]) is scanned when its active count changes and every
 * 0.25 s for a pod this machine owns, of type InitialSpawn or Reinforce, falling or braking, placed at its index by the
 * manager's own id map, and not handled in this period. Its type's speeds come from the HellpodComponent settings
 * ([[game + 0x346BF98] + 0xF12AE0]: 16 hash slots, then 104-byte records at +256). The release comes in the first frame
 * without a signal, after 120 s in any case, only over the component's own value and at the pod's index then (the
 * manager compacts its arrays). A manager unreadable at the release keeps the hold and retries 4 times a second; a pod
 * that is gone is forgotten without a store. For 30 s after a loading period or a hold, the log follows the signals and
 * the own pods: the timeline of a join.
 *
 * On HellForge: the Lua's reads, checks, stores and log lines, with plain loads for the six game.dll globals.
 * - The game state is read where the Lua read it, with the presenters, not taken from HF_ON_STATE. HellForge polls the
 *   same field in the same frame (its events tick runs just before the pack's tick), but it reports no state it cannot
 *   read or above 8 and no change to 0, where the Lua's check answers "unknown" or "not preparing"; the saving would be
 *   one read per poll.
 * - The pods are found by the Lua's manager scan, not by HF_ON_SPAWN: the scan also finds a pod spawned before the
 *   loading screen came up, and checks what the event does not report (the owned bit, the phase, the id map's index);
 *   whether hellpods pass SpawnEntity 0xFDC140 is not verified.
 * - The settings are reached through the table pointer the game reads now (component 205's), so a HellForge copy of
 *   that table (an add_entity entity with records of its own) is followed; the pod types are looked up by their hash.
 * - Each store is a plain 4-byte store after one page check (vpm_writable) right before it, as the Lua's write_batch
 *   checked the page before each write.
 * - Dropped: the test builds' forced hold (test_hold_seconds, never published), the pause after an error in an update
 *   below (no Lua update chain; the core's guard stops the component at a fault and stop() releases the pod, as the
 *   Lua's stop did), the shutdown check, the event log's seconds column (HellForge stamps each line) and the LuaJIT notes.
 *
 * Cost (reads through HfApi.read, ReadProcessMemory; the Lua's frame_budget pins in brackets, counting the globals):
 * - idle (ship, menus, a mission without a loading screen): 2 reads every 0.25 s (state, presenters) [4], nothing between;
 * - a loading period, every frame: 6 (state, presenters, client state, hotjoin flags, scenes, manager header) [11]; when
 *   the count changed and every 0.25 s, two scans (sighting and hold) of 1 read per 256 pods and 1 per pod, with the
 *   phase, map and height of each own pod [the same];
 * - the hold, once: 10 more (settings 4, t 1, recheck 3, read-back 1, height 1) [11], 1 page check, 1 store [1, 1];
 * - holding: 5 every frame, 9 every 0.25 s (manager 1, the pod 3) [9, 14];
 * - the release, once: 5 + 7 (manager 1, the pod 3, t 1, read-back 1, height 1) [9 + 8], 1 page check, 1 store [1, 1];
 * - the 30 s watch after a loading period or a hold: every 0.25 s 5 + 1 + a sighting scan [9 + 2 + the scan].
 * No other Windows call, no allocation, and log lines only on frames that act (a loading screen up or gone, a hold, a
 * release, a signal that changed or an own pod first seen while the log follows them). Once-only work: none. */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"
#include "hellpod_drop_hold.h"

#define GAME_RVA 0x3326340u        /* the game object: its state at +0xAC21C */
#define STATE_AT 0xAC21Cu
#define UI_RVA 0x347CE28u          /* the UI state: the presenters at +0x4290 */
#define PRESENTERS_AT 0x4290u      /* HUD, menu, popup presenter, the menu stack's five ids, its depth: 9 u32 */
#define MAX_DEPTH 5u
#define CUTSCENE_RVA 0x346D530u    /* the cutscene manager: the current scene, then the queued one */
#define SCENE_AT 6412u
#define SESSION_RVA 0x347CEF0u     /* the session object: the client state and is_hotjoining, has_hotjoined */
#define CLIENT_STATE_AT 91288u
#define HOTJOIN_AT 92135u
#define MANAGER_RVA 0x3326D58u     /* the HellpodComponent manager: an 84-byte header at +36 */
#define HEADER_AT 36u
#define HEADER_SIZE 84u
#define MAX_CAPACITY 4096u
#define SETTINGS_RVA 0x346BF98u    /* the entity state: component table 205 (HellpodComponent) at +0xF12AE0 */
#define SETTINGS_TABLE_AT 15805152u
#define SETTINGS_SLOTS 16u
#define SETTINGS_RECORDS 256u
#define SETTINGS_SIZE 104u
#define SETTINGS_COUNT 64u
#define RECORD_SIZE 24u            /* type hash low, high, entity id, unit, network id, flags (bit 0: owned) */
#define LOCAL_SIZE 160u
#define NET_SIZE 20u               /* phase (0 falling, 1 braking, 2 landed), then the position */
#define FACTOR_AT 32u              /* t in the local state */
#define HEIGHT_AT 12u              /* position z in the networked state */
#define MAP_PROBES 64u
#define SCAN_CHUNK 256u
#define POLL 0.25                  /* seconds: the idle and pod-check poll */
#define CAP 120.0                  /* seconds: the longest hold */
#define WATCH 30.0                 /* seconds the log follows the signals after a loading period or a hold */
/* The held pod still sinks this fast (m/s): a zero step would give the game's look rotation and landing ray a zero
 * direction. */
#define HOLD_SPEED 0.5
#define SEEN 64                    /* entity ids kept per loading period (handled, sighted) */

#define UNKNOWN (-1)
#define PRESENT 0                  /* Locate, FindHeld */
#define GONE 1
#define MANAGER_OK 0               /* ReadManager */
#define NO_MANAGER 1
#define MANAGER_LAYOUT 2
#define HELD 1                     /* StartHold */
#define LEFT_ALONE 0
#define REFUSED (-1)

/* The player drop pod types: entity hash halves and HellpodComponent variant. */
typedef struct PodKind { uint32_t low, high, variant; const char* name; } PodKind;
static const PodKind kKinds[] = {
    {0x1928D3E2u, 0xE58163E7u, 2u, "initial spawn"}, /* 0xE58163E71928D3E2 */
    {0xA9D6D849u, 0xEF9EB729u, 1u, "reinforce"},     /* 0xEF9EB729A9D6D849 */
};

/* Names for the log (game.dll's presenter name tables 0x21DD450 and 0x21DC810, the cutscene names 0x117E950). */
static const char* const kHudNames[] = {"none", "intro", "ship", "mission", "tutorial"};
static const char* const kMenuNames[] = {[0] = "none", [1] = "main", [2] = "loading mission", [3] = "loading ship",
    [4] = "loading tutorial", [5] = "armory", [13] = "mission end", [14] = "loadout", [15] = "hologram",
    [23] = "mission summary", [24] = "load", [25] = "join"};
static const char* const kSceneNames[] = {"none", "mission extraction", "ship bridge hellpod launch", "ship bridge intro",
    "ship clan station reveal", "ship cryogenic intro", "ship hellpod launch", "ship intro", "ship mission return failure",
    "ship mission return success", "ship name resource loading", "ship planet arrival", "ship planet departure",
    "ship teleporter arrival", "ship teleporter deeplink join", "ship teleporter network join", "tutorial avatar respawn",
    "tutorial cape ceremony", "tutorial intro", "tutorial outro", "tutorial outro to ship"};
#define NAMES(table) table, (uint32_t)(sizeof(table) / sizeof((table)[0]))

/* The manager as read at one check. */
typedef struct View { uintptr_t records, locals, nets, map; uint32_t active, map_capacity, map_empty, map_multiplier; } View;
typedef struct Pod { uint32_t index, id; uintptr_t record; const PodKind* kind; } Pod;
typedef struct Held { int active; Pod pod; float saved, value; double held_for; const char* retry; } Held;
/* Entity ids (the Lua's done and sighted tables): the oldest gives way when full. */
typedef struct IdSet { uint32_t ids[SEEN]; int count, next; } IdSet;

static struct
{
    uint32_t state, signals[9], scenes[2], client; /* the signals as last read */
    uint8_t joining[2];                            /* is_hotjoining, has_hotjoined */
    uint32_t seen[10], seen_extended[5];           /* the signals the log saw last */
    int seen_valid, seen_extended_valid;
    int loading;
    double since_poll, scan_wait, watch;
    int64_t last_active;
    IdSet done, sighted;
    Held held;
} s;

static uint64_t g_pointers[SCAN_CHUNK]; /* a chunk of the manager's record pointers (static: 2 KB) */

static uintptr_t Valid(uint64_t value) { return vpm_plausible((uintptr_t)value) ? (uintptr_t)value : 0; }
static uintptr_t Global(uint32_t rva) { return Valid(vpm_game_u64(rva)); }
static uint64_t Pair(const uint32_t* words, int at) { return words[at] | (uint64_t)words[at + 1] << 32; }

static int Has(const IdSet* set, uint32_t id)
{
    for (int i = 0; i < set->count; i++)
        if (set->ids[i] == id) return 1;
    return 0;
}

static void Add(IdSet* set, uint32_t id)
{
    if (Has(set, id)) return;
    set->ids[set->next] = id;
    set->next = (set->next + 1) % SEEN;
    if (set->count < SEEN) set->count++;
}

/* ---- the signals ------------------------------------------------------------------------------------------------- */

static int Preparing(uint32_t state) { return state == 5u || state == 6u; }
static int LoadingPresenter(uint32_t id) { return id == 2u || id == 4u; }
static int SceneState(uint32_t state) { return state == 4u || state == 6u; }

/* The game state and the presenters into s.state and s.signals: 1 while the player cannot see the world (a preparing
 * state, or a loading presenter current or anywhere on the menu stack), 0 when they can, UNKNOWN when either cannot be
 * read or makes no sense. */
static int LoadingScreen(void)
{
    uintptr_t object = Global(GAME_RVA);
    if (object == 0 || !vpm_read_u32(object + STATE_AT, &s.state)) return UNKNOWN;
    uintptr_t ui = Global(UI_RVA);
    if (ui == 0 || !vpm_read(ui + PRESENTERS_AT, s.signals, sizeof s.signals)) return UNKNOWN;
    uint32_t depth = s.signals[8];
    if (depth > MAX_DEPTH) return UNKNOWN;
    if (Preparing(s.state) || LoadingPresenter(s.signals[1])) return 1;
    for (uint32_t i = 0; i < depth; i++)
        if (LoadingPresenter(s.signals[3 + i])) return 1;
    return 0;
}

/* The join flags and the cutscene manager into s.client, s.joining and s.scenes (255 and 9999 when unreadable, which
 * never count), after LoadingScreen read the state: 1 while, in the mission or its preparation, a join is still
 * finishing (is_hotjoining) or a cutscene plays or waits; 0 when not; UNKNOWN when neither can be read. */
static int StillCovered(void)
{
    uintptr_t session = Global(SESSION_RVA), manager = Global(CUTSCENE_RVA);
    int flags = session != 0 && vpm_read_u32(session + CLIENT_STATE_AT, &s.client) &&
        vpm_read(session + HOTJOIN_AT, s.joining, sizeof s.joining);
    if (!flags)
    {
        s.client = 255;
        s.joining[0] = s.joining[1] = 255;
    }
    int scenes = manager != 0 && vpm_read(manager + SCENE_AT, s.scenes, sizeof s.scenes);
    if (!scenes) s.scenes[0] = s.scenes[1] = 9999;
    if (!flags && !scenes) return UNKNOWN;
    int scene = scenes && (s.scenes[0] != 0 || s.scenes[1] != 0);
    int joining = flags && s.joining[0] == 1;
    return SceneState(s.state) && (scene || joining);
}

/* Whether the state or a presenter (and, when extended, the cutscene or a join flag) changed since the last call. */
static int SignalsChanged(int extended)
{
    uint32_t now[10], more[5] = {s.scenes[0], s.scenes[1], s.client, s.joining[0], s.joining[1]};
    now[0] = s.state;
    memcpy(now + 1, s.signals, sizeof s.signals);
    int changed = !s.seen_valid || memcmp(s.seen, now, sizeof now) != 0;
    memcpy(s.seen, now, sizeof now);
    s.seen_valid = 1;
    if (!extended || (s.seen_extended_valid && memcmp(s.seen_extended, more, sizeof more) == 0)) return changed;
    memcpy(s.seen_extended, more, sizeof more);
    s.seen_extended_valid = 1;
    return 1;
}

/* A table's name for id, or the number in scratch. */
static const char* Named(const char* const* names, uint32_t count, uint32_t id, char scratch[12])
{
    if (id < count && names[id] != NULL) return names[id];
    snprintf(scratch, 12, "%u", id);
    return scratch;
}

/* The signals just read, in words (the Lua's describe_signals). */
static void LogSignals(VpmComponent* self, int extended)
{
    char line[512], stack[160] = "", a[12], b[12];
    size_t used = 0;
    for (uint32_t i = 0; i < s.signals[8] && i < MAX_DEPTH && used < sizeof stack; i++)
    {
        int n = snprintf(stack + used, sizeof stack - used, "%s%s", i > 0 ? ", " : "", Named(NAMES(kMenuNames), s.signals[3 + i], a));
        used += n > 0 ? (size_t)n : 0;
    }
    int n = snprintf(line, sizeof line, "game state %u, hud %s, menu %s, popup %u, menu stack [%s]", s.state,
        Named(NAMES(kHudNames), s.signals[0], a), Named(NAMES(kMenuNames), s.signals[1], b), s.signals[2], stack);
    if (extended && n > 0 && (size_t)n < sizeof line)
        snprintf(line + n, sizeof line - (size_t)n, ", cutscene %s (next %s), client state %u, hotjoining %u, hotjoined %u",
            Named(NAMES(kSceneNames), s.scenes[0], a), Named(NAMES(kSceneNames), s.scenes[1], b), s.client,
            (unsigned)s.joining[0], (unsigned)s.joining[1]);
    vpm_log(self, "%s", line);
}

/* One check of the signals: the loading screen (1, 0 or UNKNOWN) and, when extended, *scene (a cutscene or a join still
 * covering the mission or its preparation). Logs a change while the log follows the signals. */
static int Observe(VpmComponent* self, int extended, int* scene)
{
    *scene = 0;
    int up = LoadingScreen();
    if (up == UNKNOWN) return UNKNOWN;
    if (extended) *scene = StillCovered() == 1;
    if (s.watch > 0 && SignalsChanged(extended)) LogSignals(self, extended);
    return up;
}

/* ---- the HellpodComponent manager -------------------------------------------------------------------------------- */

static int PowerOfTwo(uint32_t value) { return value != 0 && (value & (value - 1)) == 0; }

/* The manager's active count and arrays into *v: MANAGER_OK, NO_MANAGER before it exists, MANAGER_LAYOUT when its
 * header makes no sense. */
static int ReadManager(View* v)
{
    uintptr_t manager = Global(MANAGER_RVA);
    uint32_t w[HEADER_SIZE / 4]; /* w[i] holds manager + 36 + 4 * i */
    if (manager == 0) return NO_MANAGER;
    if (!vpm_read(manager + HEADER_AT, w, sizeof w)) return MANAGER_LAYOUT;
    uint32_t capacity = w[0], total = w[2];
    v->active = w[3];
    if (capacity > MAX_CAPACITY || total > capacity || v->active > total) return MANAGER_LAYOUT;
    v->records = Valid(Pair(w, 13));
    v->locals = Valid(Pair(w, 17));
    v->nets = Valid(Pair(w, 19));
    /* The entity-id map: +64 slots, +72 capacity (a power of two), +76 empty key, +80 multiplier. */
    v->map = Valid(Pair(w, 7));
    v->map_capacity = w[9];
    v->map_empty = w[10];
    v->map_multiplier = w[11];
    int arrays = v->records != 0 && v->locals != 0 && v->nets != 0 && v->map != 0;
    if (v->active > 0 && !(arrays && v->map_capacity <= 65536u && PowerOfTwo(v->map_capacity))) return MANAGER_LAYOUT;
    return MANAGER_OK;
}

/* The index the manager's own entity-id map gives for id: 1 with *index, 0 when absent or unreadable. The game probes
 * slot (id * multiplier + probe) & (capacity - 1) until the key or the empty key. */
static int MapIndex(const View* v, uint32_t id, uint32_t* index)
{
    uint32_t start = id * v->map_multiplier, probes = v->map_capacity < MAP_PROBES ? v->map_capacity : MAP_PROBES;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        uint32_t slot[2];
        uintptr_t at = v->map + (uintptr_t)((start + probe) % v->map_capacity) * 8u;
        if (!vpm_read(at, slot, sizeof slot) || slot[0] == v->map_empty) return 0;
        if (slot[0] == id)
        {
            *index = slot[1];
            return 1;
        }
    }
    return 0;
}

/* The entity record at address into record: its pod type when it is a player drop pod this machine owns, else NULL. */
static const PodKind* OwnDropPod(uintptr_t address, uint32_t record[6])
{
    if (address == 0 || !vpm_read(address, record, RECORD_SIZE) || (record[5] & 1u) != 1u) return NULL;
    for (size_t i = 0; i < sizeof kKinds / sizeof kKinds[0]; i++)
        if (record[0] == kKinds[i].low && record[1] == kKinds[i].high) return &kKinds[i];
    return NULL;
}

static int PhaseOf(const View* v, uint32_t index, uint32_t* phase)
{
    return vpm_read_u32(v->nets + (uintptr_t)index * NET_SIZE, phase);
}

/* The pod's height (networked position z) for the log, or -1. */
static float HeightOf(const View* v, uint32_t index)
{
    float z;
    return vpm_read_f32(v->nets + (uintptr_t)index * NET_SIZE + HEIGHT_AT, &z) ? z : -1.0f;
}

static uintptr_t FactorAddress(const View* v, uint32_t index) { return v->locals + (uintptr_t)index * LOCAL_SIZE + FACTOR_AT; }

/* The record pointers from first on into g_pointers, at most SCAN_CHUNK: how many, or 0 when unreadable. */
static uint32_t ReadChunk(const View* v, uint32_t first)
{
    uint32_t count = v->active - first < SCAN_CHUNK ? v->active - first : SCAN_CHUNK;
    return vpm_read(v->records + (uintptr_t)first * 8u, g_pointers, (size_t)count * 8u) ? count : 0;
}

/* The pod at index: 1 with *found when it is this machine's own drop pod, falling or braking, not handled already, and
 * the manager's own id map places it at this index. */
static int Candidate(const View* v, uint32_t index, uintptr_t address, Pod* found)
{
    uint32_t record[6], phase, at;
    const PodKind* kind = OwnDropPod(address, record);
    if (kind == NULL || Has(&s.done, record[2])) return 0;
    if (!PhaseOf(v, index, &phase) || (phase != 0 && phase != 1)) return 0;
    if (!MapIndex(v, record[2], &at) || at != index) return 0;
    *found = (Pod){index, record[2], address, kind};
    return 1;
}

/* The first own drop pod still falling or braking and not handled in this loading period. */
static int FindPod(const View* v, Pod* found)
{
    for (uint32_t first = 0; first < v->active;)
    {
        uint32_t count = ReadChunk(v, first);
        if (count == 0) return 0;
        for (uint32_t slot = 0; slot < count; slot++)
            if (Candidate(v, first + slot, Valid(g_pointers[slot]), found)) return 1;
        first += count;
    }
    return 0;
}

/* The pod at index still has the held pod's record, entity id, type and owner. The manager compacts its arrays when a
 * pod goes, so an index can change. */
static int SamePod(const View* v, const Pod* held, uint32_t index)
{
    uint64_t pointer;
    uint32_t record[6], at;
    if (index >= v->active || !vpm_read_u64(v->records + (uintptr_t)index * 8u, &pointer) || pointer != held->record) return 0;
    return OwnDropPod(held->record, record) == held->kind && record[2] == held->id && MapIndex(v, held->id, &at) && at == index;
}

/* The held pod's index now into *index: PRESENT, GONE when the manager no longer has it, UNKNOWN when the manager could
 * not be read (the hold is kept and checked again). */
static int Locate(const View* v, const Pod* held, uint32_t* index)
{
    if (SamePod(v, held, held->index))
    {
        *index = held->index;
        return PRESENT;
    }
    for (uint32_t first = 0; first < v->active;)
    {
        uint32_t count = ReadChunk(v, first);
        if (count == 0) return UNKNOWN;
        for (uint32_t slot = 0; slot < count; slot++)
        {
            if (g_pointers[slot] != held->record || !SamePod(v, held, first + slot)) continue;
            *index = first + slot;
            return PRESENT;
        }
        first += count;
    }
    return GONE;
}

/* The manager and the held pod's index, as Locate; GONE when the manager no longer exists, UNKNOWN when it cannot be
 * read. */
static int FindHeld(View* v, uint32_t* index)
{
    int problem = ReadManager(v);
    if (problem != MANAGER_OK) return problem == NO_MANAGER ? GONE : UNKNOWN;
    return Locate(v, &s.held.pod, index);
}

/* Logs an own drop pod the first time it is seen in a loading period or the watch after it: when it appeared, against
 * the signals, is the timing evidence. */
static void Sight(VpmComponent* self, const View* v, uint32_t index, uintptr_t address)
{
    uint32_t record[6], phase;
    char text[12] = "nil";
    const PodKind* kind = OwnDropPod(address, record);
    if (kind == NULL || Has(&s.sighted, record[2])) return;
    Add(&s.sighted, record[2]);
    float height = HeightOf(v, index);
    if (PhaseOf(v, index, &phase)) snprintf(text, sizeof text, "%u", phase);
    vpm_log(self, "own %s pod %u seen at %.0f m, phase %s", kind->name, record[2], height, text);
}

static void SightPods(VpmComponent* self, const View* v)
{
    for (uint32_t first = 0; first < v->active;)
    {
        uint32_t count = ReadChunk(v, first);
        if (count == 0) return;
        for (uint32_t slot = 0; slot < count; slot++) Sight(self, v, first + slot, Valid(g_pointers[slot]));
        first += count;
    }
}

/* ---- the pod settings -------------------------------------------------------------------------------------------- */

/* A settings record's initial and braking velocity: 1, or 0 when it is not the type's or its speeds make no sense. */
static int SettingsRecord(uintptr_t table, uint32_t index, const PodKind* kind, float* initial, float* braking)
{
    uint32_t variant;
    float speeds[4]; /* initial velocity, braking height, braking velocity, braking time */
    if (index >= SETTINGS_COUNT) return 0;
    uintptr_t at = table + SETTINGS_RECORDS + (uintptr_t)index * SETTINGS_SIZE;
    if (!vpm_read_u32(at, &variant) || !vpm_read(at + 20, speeds, sizeof speeds)) return 0;
    if (variant != kind->variant || !(speeds[3] > 0)) return 0;
    if (!(speeds[2] > HOLD_SPEED && speeds[0] > speeds[2] && speeds[0] <= 5000)) return 0;
    *initial = speeds[0];
    *braking = speeds[2];
    return 1;
}

/* The pod type's velocities from its HellpodComponent settings, through the table the game reads now (16 open-addressed
 * slots from the hash's low 4 bits, then the records): 1, or 0 when the table or the record make no sense. */
static int Velocities(const PodKind* kind, float* initial, float* braking)
{
    uint32_t slots[SETTINGS_SLOTS * 4]; /* hash low, high, record index, padding */
    uintptr_t owner = Global(SETTINGS_RVA), table = owner != 0 ? Valid(vpm_ptr(owner + SETTINGS_TABLE_AT)) : 0;
    if (table == 0 || !vpm_read(table, slots, sizeof slots)) return 0;
    uint32_t slot = kind->low % SETTINGS_SLOTS;
    for (uint32_t probe = 0; probe < SETTINGS_SLOTS; probe++, slot = (slot + 1) % SETTINGS_SLOTS)
    {
        uint32_t low = slots[slot * 4], high = slots[slot * 4 + 1];
        if (low == kind->low && high == kind->high) return SettingsRecord(table, slots[slot * 4 + 2], kind, initial, braking);
        if (low == 0 && high == 0) return 0;
    }
    return 0;
}

/* ---- hold and release -------------------------------------------------------------------------------------------- */

/* Stores value as the pod's t after one page check right before the store, and reads it back. */
static int Store(uintptr_t address, float value)
{
    float now;
    if (!vpm_writable(address, sizeof value)) return 0;
    memcpy((void*)address, &value, sizeof value);
    return vpm_read_f32(address, &now) && now == value;
}

/* Holds the found pod: HELD, LEFT_ALONE (*why: this pod is not held) or REFUSED (*why: the component must stop). */
static int StartHold(VpmComponent* self, const View* v, const Pod* pod, const char** why)
{
    float initial, braking, saved;
    if (!Velocities(pod->kind, &initial, &braking)) { *why = "drop_pod_settings_unrecognized"; return REFUSED; }
    uintptr_t address = FactorAddress(v, pod->index);
    if (!vpm_read_f32(address, &saved)) { *why = "drop_pod_unreadable"; return REFUSED; }
    if (!(saved >= 0 && saved <= 1)) /* outside the game's own 0 .. 1: written by someone else */
    {
        Add(&s.done, pod->id);
        *why = "drop_pod_speed_set_elsewhere";
        return LEFT_ALONE;
    }
    float value = (float)((HOLD_SPEED - braking) / ((double)initial - braking));
    if (!SamePod(v, pod, pod->index)) { *why = "drop_pod_moved"; return LEFT_ALONE; }
    if (!Store(address, value)) { *why = "drop_pod_not_writable"; return REFUSED; }
    s.held = (Held){1, *pod, saved, value, 0, NULL};
    vpm_log(self, "holding %s pod %u at %.0f m (speed factor %.3f -> %.3f)", pod->kind->name, pod->id,
        HeightOf(v, pod->index), saved, value);
    return HELD;
}

/* Puts the saved t back on the held pod, only over the component's own value: NULL, or why the component must stop (a
 * failed store). The hold is forgotten unless the manager could not be read: then it is kept and released at a later
 * poll. */
static const char* Release(VpmComponent* self, const char* reason)
{
    View v;
    uint32_t index = 0;
    float now;
    if (!s.held.active) return NULL;
    int where = FindHeld(&v, &index);
    if (where == UNKNOWN)
    {
        s.held.retry = reason;
        return NULL;
    }
    Held held = s.held;
    s.held.active = 0;
    Add(&s.done, held.pod.id);
    if (where == GONE)
    {
        vpm_log(self, "released pod %u (%s): the pod is gone", held.pod.id, reason);
        return NULL;
    }
    uintptr_t address = FactorAddress(&v, index);
    if (!vpm_read_f32(address, &now) || now != held.value)
    {
        vpm_log(self, "released pod %u (%s): left unchanged, its speed changed elsewhere", held.pod.id, reason);
        return NULL;
    }
    if (!Store(address, held.saved)) return "drop_pod_release_failed";
    vpm_log(self, "released pod %u (%s) after %.1f s at %.0f m", held.pod.id, reason, held.held_for, HeightOf(&v, index));
    return NULL;
}

/* ---- the frame --------------------------------------------------------------------------------------------------- */

/* No loading period: a poll every 0.25 s, nothing between. Only a loading screen starts a loading period, never a
 * cutscene alone. For 30 s after one, the log keeps following the signals and the own pods. 1 while idle, 0 when a
 * loading period began. lint: per-frame */
static int Idle(VpmComponent* self, double dt)
{
    View v;
    int scene;
    int watching = s.watch > 0;
    if (watching) s.watch -= dt;
    s.since_poll += dt;
    if (s.since_poll < POLL) return 1;
    s.since_poll = 0;
    int up = Observe(self, watching, &scene);
    if (watching && ReadManager(&v) == MANAGER_OK) SightPods(self, &v);
    if (up != 1) return 1;
    s.loading = 1;
    s.last_active = -1;
    s.scan_wait = 0;
    memset(&s.done, 0, sizeof s.done);
    memset(&s.sighted, 0, sizeof s.sighted);
    vpm_log(self, "loading screen up");
    return 0;
}

/* While a loading period lasts, every frame: a new own pod is held at once. The pods are scanned when the active count
 * changed, and every 0.25 s. NULL, or why the component must stop. lint: per-frame */
static const char* Loading(VpmComponent* self, double dt)
{
    View v;
    Pod pod;
    int scene;
    const char* why = NULL;
    s.watch = WATCH;
    int up = Observe(self, 1, &scene);
    if (up == UNKNOWN) return NULL;
    if (up == 0 && !scene)
    {
        s.loading = 0;
        s.since_poll = 0;
        vpm_log(self, "loading screen gone");
        return NULL;
    }
    int problem = ReadManager(&v);
    if (problem != MANAGER_OK) return problem == MANAGER_LAYOUT ? "manager_layout" : NULL;
    s.scan_wait -= dt;
    if ((int64_t)v.active == s.last_active && s.scan_wait > 0) return NULL;
    s.last_active = v.active;
    s.scan_wait = POLL;
    SightPods(self, &v);
    if (!FindPod(&v, &pod)) return NULL;
    int held = StartHold(self, &v, &pod, &why);
    if (held == LEFT_ALONE) vpm_log(self, "pod %u left alone: %s", pod.id, why);
    return held == REFUSED ? why : NULL;
}

/* The reason to release now, other than the end of the cover, if any. */
static const char* Due(const Held* held)
{
    if (held->retry != NULL) return held->retry;
    return held->held_for >= CAP ? "longest hold" : NULL;
}

/* While holding, every frame: the cover is checked, and its end releases the pod in that frame, so the player sees it
 * already falling (v1.1 waited 1.5 s, and the pod looked stuck in the air). 4 times a second, the pod is checked to
 * still be there. NULL, or why the component must stop. lint: per-frame */
static const char* Holding(VpmComponent* self, double dt)
{
    View v;
    uint32_t index = 0;
    int scene;
    s.held.held_for += dt;
    s.since_poll += dt;
    const char* reason = Due(&s.held);
    /* A retry waits for the next poll, so an unreadable manager costs reads only 4 times a second. */
    if (reason != NULL && (s.held.retry == NULL || s.since_poll >= POLL))
    {
        s.since_poll = 0;
        return Release(self, reason);
    }
    s.watch = WATCH;
    if (Observe(self, 1, &scene) == 0 && !scene && s.held.retry == NULL)
    {
        s.loading = 0;
        vpm_log(self, "loading screen and cutscene gone");
        return Release(self, "loading screen gone");
    }
    if (s.since_poll < POLL) return NULL;
    s.since_poll = 0;
    int where = FindHeld(&v, &index);
    if (where == PRESENT) s.held.pod.index = index;
    if (where != GONE) return NULL;
    s.held.active = 0;
    Add(&s.done, s.held.pod.id);
    vpm_log(self, "pod %u is gone", s.held.pod.id);
    return NULL;
}

/* One frame: NULL, or why the component must stop. lint: per-frame */
static const char* Update(VpmComponent* self, double dt)
{
    if (s.held.active) return Holding(self, dt);
    if (s.loading) return Loading(self, dt);
    if (Idle(self, dt)) return NULL;
    return Loading(self, 0);
}

/* The game-thread tick: a refusal (a layout or setting the component cannot verify) stops it at once. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    const char* why = Update(self, dt > 0 && dt < 10 ? (double)dt : 0);
    if (why != NULL) vpm_fail(self, "%s", why);
}

/* The core stopping the component (a refusal or a fault): the held pod is released, as the Lua's stop did. */
static void Stop(VpmComponent* self) { (void)Release(self, "stopped"); }

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.since_poll = POLL; /* a fresh session polls at once */
    s.last_active = -1;
    if (!vpm_tick_start(self, Tick)) return vpm_fail(self, "game update unavailable; no change applied");
    vpm_set_status(self, "waiting_for_loading_screen");
    return 0;
}

#ifdef VPM_TEST
void hellpod_drop_hold_test_view(HdhTestView* out)
{
    out->loading = s.loading;
    out->held = s.held.active;
    out->retrying = s.held.active && s.held.retry != NULL;
    out->index = s.held.pod.index;
    out->id = s.held.pod.id;
}
#endif

const VpmComponentDef vpm_component_hellpod_drop_hold = {"hellpod_drop_hold", "Hellpod Drop Hold", "1.2.1", 0, Start, Stop};
