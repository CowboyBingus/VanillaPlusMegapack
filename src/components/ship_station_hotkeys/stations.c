/* Ship Station Hotkeys: the stations (Lua: galactic_menu_hotkey.lua, initialize_native to service_hellpod), build
 * 25480438. Each shortcut calls the game's own entry for its station, on the game thread, through a C function pointer
 * at game.dll + its RVA, after every check the Lua made:
 *   - the menu presenters: PresenterManager::open 0x14C0350 (manager, presenter, NULL) with presenter 15 Hologram
 *     (Galactic Map), 5 Armory, 6 Control Center, 8 Ship Management, only while no presenter is open (current 0, depth 0);
 *   - Stratagem Hero: the arcade interaction start 0x997800 (system, NULL, cabinet entity, avatar entity), only with the
 *     one cabinet idle and the local avatar within 3 world units of it (the unit world-position function from the
 *     engine's unit interface);
 *   - the Hellpod: the briefing entry 0x661CF0 (NULL, 0) at once, then the instant seat entry 0x639830 (NULL, avatar
 *     entity, placement request) once the briefing's intro is skipped and its UI is up, solo sessions only; pressed during
 *     the pod's opening animation, it waits up to 10 s for the pod to open.
 * The checks and log lines are the Lua's; its reads of game.dll's statics are plain loads here, and adjacent heap fields
 * the Lua read one by one come in one read (the presenter's state, the arcade component, the player manager, the Hellpod
 * manager's per-pod arrays, the seater component). The intro timer's expiry is a plain store into the loadout screen,
 * as the Lua's (no page check: a fault there is taken by the pack's crash guard). */
#include <stdio.h>
#include <string.h>
#include "ship_station_hotkeys.h"

#define ENTER_PRESENTER_RVA 0x14C0350u
#define START_ARCADE_RVA 0x997800u
#define INSTANT_SEAT_RVA 0x639830u     /* the seater's instant entry (a player spawning inside a seat) */
#define OPEN_BRIEFING_RVA 0x661CF0u    /* the deployment setup and presenter 14 request the seat completion makes */
#define UI_STATE_RVA 0x347CE28u        /* the top-level UI state; its presenter manager at +17032 */
#define ARCADE_COMPONENT_RVA 0x3326700u
#define ARCADE_SYSTEM_RVA 0x3326E68u
#define PLAYER_MANAGER_RVA 0x3326468u
#define ENTITY_MANAGER_RVA 0x346BF98u
#define UNIT_INTERFACE_RVA 0x3326308u
#define HELLPOD_SYSTEM_RVA 0x33265F0u
#define HELLPOD_MANAGER_RVA 0x3326428u
#define SEATER_COMPONENT_RVA 0x3326D78u
#define SCREEN_STACK_RVA 0x347CE38u

#define PRESENTER_CODE "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 8B"
#define ARCADE_CODE "48 8B C4 48 89 50 10 48 89 48 08 53 55 57 48 83"
#define INSTANT_SEAT_CODE "48 89 5C 24 20 48 89 54 24 10 56 57 41 54 41 55"
#define BRIEFING_CODE "48 89 4C 24 08 57 48 83 EC 40 4C 8B 0D"
#define UNIT_POSITION_CODE "40 53 48 83 EC 20"

#define PRESENTER_OFFSET 17032u
#define IDLE_MENU_PRESENTER 0u
#define BRIEFING_PRESENTER 14u
#define LOADOUT_SCREEN 11u             /* MenuScreenType 11, its object at screen stack +176 */
#define LOADOUT_SCREEN_SLOT 176u
#define INTRO_TIMER_OFFSET 2570632u    /* a 2.0 s timer while the intro waits (phase 1) */
#define INTRO_PHASE_OFFSET 2570636u
#define INTRO_WAITING 1u
#define INTRO_DONE 0u
#define SEAT_FALLBACK_SECONDS 3.0
#define ARCADE_MAX_DISTANCE_SQUARED 9.0 /* three world units from the cabinet's root */
#define POD_MISSION_READY 2u           /* Hellpod manager pod mode 2: a mission is selected */
#define POD_OPEN 3u                    /* pod state 3: open for entry; 4: occupied */
#define POD_OCCUPIED 4u
#define HELLPOD_OPEN_WAIT_SECONDS 10.0
#define ENTITY_LOOKUP 0xF22EC8u        /* entity manager: entity id -> record index */
#define ENTITY_RECORDS 0xF32F18u       /* entity manager: 24-byte records, the owned bit in byte 20 */
#define PLAYERS_FROM 0x84u             /* player manager: local count +0x84, active +0x88, record +0xE8, unit +0x3A8 */
#define PLAYERS_TO 0x3ACu

typedef void (*OpenPresenterFn)(void* manager, int32_t presenter, void* data);
typedef void (*StartArcadeFn)(void* system, void* data, uint32_t entity, uint32_t avatar);
typedef void (*EnterSeatFn)(void* context, void* entity, void* request);
typedef void (*OpenBriefingFn)(void* context, uint32_t slot);
typedef uint64_t (*UnitPositionFn)(uint32_t unit, int32_t index);

static const uint8_t kAvatarType[8] = {0x97, 0xFA, 0x4D, 0x29, 0x4D, 0x33, 0x1C, 0x4D};

static struct
{
    int initialized;
    OpenPresenterFn open_presenter;
    StartArcadeFn start_arcade;
    EnterSeatFn enter_seat;
    OpenBriefingFn open_briefing;
    UnitPositionFn unit_position;  /* NULL: the arcade's distance check fails closed */
    int waiting;                   /* a Hellpod wait: seconds left */
    double wait;
    int seating;                   /* a seat behind the briefing: the pod, the fallback delay, the intro skipped */
    uint32_t seat_pod;
    double seat_delay;
    int seat_skipped;
} n;

/* The seat request and its placement, passed to the instant seat entry (static: the game reads them during the call). */
static uint32_t g_placement[409];
static uint8_t g_request[80];
static uint8_t g_rows[256 * 16]; /* the arcade system's rows */

static uint32_t U32At(const uint8_t* bytes, size_t at) { uint32_t v; memcpy(&v, bytes + at, 4); return v; }
static uint64_t U64At(const uint8_t* bytes, size_t at) { uint64_t v; memcpy(&v, bytes + at, 8); return v; }
/* The Lua's pointer(): a user-mode address, or 0. */
static uintptr_t Plausible(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull ? (uintptr_t)value : 0; }
static uintptr_t PointerAt(uintptr_t address) { uint64_t v = 0; return vpm_read_u64(address, &v) ? Plausible(v) : 0; }

/* A number for the log, or "nil" when it was unreadable (the Lua's tostring). */
static const char* Number(char* text, size_t size, int known, uint32_t value)
{
    if (!known) return "nil";
    snprintf(text, size, "%u", value);
    return text;
}

void ssh_stations_reset(void)
{
    memset(&n, 0, sizeof n);
}

/* ---- the native check -------------------------------------------------------------------------------------------- */

/* The refusal's reason, or NULL when the four entries and the UI state are as reviewed. */
static const char* NativeRefusal(void)
{
    if (vpm_game() == 0) return "game modules unavailable";
    if (!vpm_game_code_matches(ENTER_PRESENTER_RVA, PRESENTER_CODE)) return "native presenter changed in memory";
    if (!vpm_game_code_matches(START_ARCADE_RVA, ARCADE_CODE)) return "native arcade start changed in memory";
    if (!vpm_game_code_matches(INSTANT_SEAT_RVA, INSTANT_SEAT_CODE)) return "native instant seat entry changed in memory";
    if (!vpm_game_code_matches(OPEN_BRIEFING_RVA, BRIEFING_CODE)) return "native Hellpod briefing entry changed in memory";
    if (Plausible(vpm_game_u64(UI_STATE_RVA)) == 0) return "UI state unavailable";
    return NULL;
}

/* The engine's unit world-position function (unit interface +24, its table +136), when its first bytes are reviewed. */
static UnitPositionFn UnitPosition(void)
{
    uintptr_t unit_interface = Plausible(vpm_game_u64(UNIT_INTERFACE_RVA));
    uintptr_t table = unit_interface != 0 ? PointerAt(unit_interface + 24) : 0;
    uintptr_t position = table != 0 ? PointerAt(table + 136) : 0;
    if (position == 0 || !vpm_hf()->code_matches(position, UNIT_POSITION_CODE)) return NULL;
    return (UnitPositionFn)position;
}

int ssh_stations_check(VpmComponent* self)
{
    if (n.initialized) return 1;
    n.initialized = 1;
    const char* refused = NativeRefusal();
    if (refused != NULL)
    {
        vpm_fail(self, "%s", refused);
        return 0;
    }
    uintptr_t game = vpm_game();
    n.open_presenter = (OpenPresenterFn)(game + ENTER_PRESENTER_RVA);
    n.start_arcade = (StartArcadeFn)(game + START_ARCADE_RVA);
    n.enter_seat = (EnterSeatFn)(game + INSTANT_SEAT_RVA);
    n.open_briefing = (OpenBriefingFn)(game + OPEN_BRIEFING_RVA);
    n.unit_position = UnitPosition();
    if (n.unit_position == NULL) vpm_log(self, "Arcade proximity check unavailable: world-position function changed.");
    vpm_log(self, "Native ship menu presenters ready for current game build.");
    return 1;
}

/* ---- the presenters ---------------------------------------------------------------------------------------------- */

/* The presenter manager and its state (current presenter +12, depth +40: one read), known 0 when unreadable. */
typedef struct Presenter { uintptr_t manager; int known; uint32_t current, depth; } Presenter;

static Presenter PresenterStatus(void)
{
    Presenter p = {0, 0, 0, 0};
    uintptr_t ui = Plausible(vpm_game_u64(UI_STATE_RVA));
    if (ui == 0) return p;
    p.manager = ui + PRESENTER_OFFSET;
    uint8_t state[32];
    if (!vpm_read(p.manager + 12, state, sizeof state)) return p;
    p.known = 1;
    p.current = U32At(state, 0);
    p.depth = U32At(state, 28);
    return p;
}

static int PresenterIs(const Presenter* p, uint32_t presenter) { return p->known && p->current == presenter; }
static int PresenterIdle(const Presenter* p) { return PresenterIs(p, IDLE_MENU_PRESENTER) && p->depth == 0; }

/* The presenter manager when no presenter is open, else 0 after the log line saying why. presenter: the one this
 * shortcut opens, 0 for none. */
static uintptr_t IdleManager(VpmComponent* self, const char* name, uint32_t presenter)
{
    if (n.open_presenter == NULL)
    {
        vpm_log(self, "%s shortcut detected, but the native presenter is unavailable.", name);
        return 0;
    }
    Presenter p = PresenterStatus();
    if (p.manager == 0)
    {
        vpm_log(self, "%s shortcut detected, but UI state is unavailable.", name);
        return 0;
    }
    if (presenter != 0 && PresenterIs(&p, presenter))
    {
        vpm_log(self, "%s shortcut detected; presenter already open.", name);
        return 0;
    }
    if (!PresenterIdle(&p))
    {
        char current[16], depth[16];
        vpm_log(self, "%s shortcut detected; presenter is busy (%s, depth %s).", name,
            Number(current, sizeof current, p.known, p.current), Number(depth, sizeof depth, p.known, p.depth));
        return 0;
    }
    return p.manager;
}

static void OpenPresenter(VpmComponent* self, const char* name, uint32_t presenter)
{
    uintptr_t manager = IdleManager(self, name, presenter);
    if (manager == 0) return;
    vpm_log(self, "%s shortcut detected; entering native presenter %u.", name, presenter);
    n.open_presenter((void*)manager, (int32_t)presenter, NULL);
    uint32_t current = 0;
    char text[16];
    int known = vpm_read_u32(manager + 12, &current);
    vpm_log(self, "%s presenter call returned; current=%s.", name, Number(text, sizeof text, known, current));
}

/* ---- the game's entity maps and the local avatar ----------------------------------------------------------------- */

/* One of the game's open-addressed maps: 8-byte buckets (key, value), a power-of-two capacity, an empty key and a
 * multiplier (a 20-byte header). */
typedef struct HashMap { uintptr_t buckets; uint32_t capacity, empty, multiplier; } HashMap;

static int MapLayout(const uint8_t* header, HashMap* map)
{
    map->buckets = Plausible(U64At(header, 0));
    map->capacity = U32At(header, 8);
    map->empty = U32At(header, 12);
    map->multiplier = U32At(header, 16);
    return map->buckets != 0 && map->capacity >= 1 && map->capacity <= 1048576u && (map->capacity & (map->capacity - 1)) == 0;
}

/* The value under key, probed linearly from key * multiplier, at most 128 probes (the Lua's hashed_value). */
static int HashedValue(const HashMap* map, uint32_t key, uint32_t* value)
{
    uint32_t product = key * map->multiplier;
    uint32_t probes = map->capacity < 128u ? map->capacity : 128u;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        uint32_t entry[2];
        if (!vpm_read(map->buckets + 8u * ((product + probe) & (map->capacity - 1)), entry, sizeof entry)) return 0;
        if (entry[0] == key)
        {
            *value = entry[1];
            return 1;
        }
        if (entry[0] == map->empty) return 0;
    }
    return 0;
}

/* An entity's 24-byte record in the entity manager. */
static int EntityRecord(uintptr_t entities, uint32_t entity, uint8_t* record)
{
    uint8_t header[20];
    HashMap map;
    uint32_t index = 0;
    if (!vpm_read(entities + ENTITY_LOOKUP, header, sizeof header) || !MapLayout(header, &map)) return 0;
    if (!HashedValue(&map, entity, &index) || index == 0xFFFFFFFFu || index >= 262144u) return 0;
    return vpm_read(entities + ENTITY_RECORDS + 24u * (uintptr_t)index, record, 24);
}

/* The local player's avatar: entity id, unit, and the entity manager (the Lua's local_avatar). */
typedef struct Avatar { uint32_t id, unit; uintptr_t entities; } Avatar;

static int LocalAvatar(Avatar* out)
{
    uintptr_t players = Plausible(vpm_game_u64(PLAYER_MANAGER_RVA));
    uintptr_t entities = Plausible(vpm_game_u64(ENTITY_MANAGER_RVA));
    uint8_t pm[PLAYERS_TO - PLAYERS_FROM];
    if (players == 0 || entities == 0 || !vpm_read(players + PLAYERS_FROM, pm, sizeof pm)) return 0;
    uint32_t count = U32At(pm, 0x84u - PLAYERS_FROM), active = U32At(pm, 0x88u - PLAYERS_FROM);
    if (count < 1 || count > 4 || active < 1 || active > 4) return 0;
    uintptr_t record = Plausible(U64At(pm, 0xE8u - PLAYERS_FROM));
    uint8_t player[24], avatar[24];
    if (record == 0 || !vpm_read(record, player, sizeof player) || (player[20] & 1u) == 0) return 0;
    uint32_t unit = U32At(pm, 0x3A8u - PLAYERS_FROM);
    if (unit == 0x7FFFu || !EntityRecord(entities, unit, avatar)) return 0;
    if (memcmp(avatar, kAvatarType, sizeof kAvatarType) != 0 || (avatar[20] & 1u) == 0) return 0;
    out->id = U32At(avatar, 8);
    out->unit = U32At(avatar, 12);
    out->entities = entities;
    return out->id != 0 && out->id != 0xFFFFFFFFu && out->unit != 0;
}

/* ---- Stratagem Hero ---------------------------------------------------------------------------------------------- */

typedef struct Arcade { uintptr_t system, pool; uint32_t cabinet, avatar, cabinet_unit, avatar_unit; } Arcade;

/* The ship's one arcade minigame record: its cabinet entity and pool. Any other layout, or several candidates, is
 * refused rather than choosing one. */
static int ArcadeCabinet(Arcade* a)
{
    uintptr_t manager = Plausible(vpm_game_u64(ARCADE_COMPONENT_RVA));
    uint8_t m[72]; /* manager +24 .. +96: count +24, buckets +48, capacity +56, empty +60, pool +88 */
    if (manager == 0 || !vpm_read(manager + 24, m, sizeof m)) return 0;
    uint32_t capacity = U32At(m, 32), empty = U32At(m, 36);
    uintptr_t buckets = Plausible(U64At(m, 24));
    a->pool = Plausible(U64At(m, 64));
    uint8_t entries[128 * 8];
    if (U32At(m, 0) != 1 || capacity != 128 || empty != 0 || buckets == 0 || a->pool == 0) return 0;
    if (!vpm_read(buckets, entries, sizeof entries)) return 0;
    int found = 0;
    for (uint32_t i = 0; i < capacity; i++)
    {
        uint32_t entity = U32At(entries, i * 8), slot = U32At(entries, i * 8 + 4);
        if (entity == empty) continue;
        if (found || entity == 0xFFFFFFFFu || slot != 0) return 0;
        a->cabinet = entity;
        found = 1;
    }
    return found;
}

/* The arcade interaction system: the one row of type 67 among the systems' rows. */
static uintptr_t ArcadeSystem(void)
{
    uintptr_t systems = Plausible(vpm_game_u64(ARCADE_SYSTEM_RVA));
    uint32_t count = 0;
    if (systems == 0 || !vpm_read_u32(systems + 19512, &count) || count < 1 || count > 256) return 0;
    if (!vpm_read(systems + 19520, g_rows, (size_t)count * 16)) return 0;
    uintptr_t system = 0;
    for (uint32_t i = 0; i < count; i++)
    {
        if (U32At(g_rows, i * 16 + 8) != 67) continue;
        if (system != 0) return 0;
        system = Plausible(U64At(g_rows, i * 16));
    }
    return system;
}

/* Everything the arcade start takes, with the cabinet idle (pool +5208 is 0 while nobody plays; +5212 keeps the last
 * player, so it cannot be the guard). */
static int ArcadeContext(Arcade* a)
{
    Avatar avatar;
    uint8_t cabinet[24];
    uint32_t active = 0;
    if (!ArcadeCabinet(a)) return 0;
    a->system = ArcadeSystem();
    if (a->system == 0 || !LocalAvatar(&avatar)) return 0;
    if (!EntityRecord(avatar.entities, a->cabinet, cabinet) || (cabinet[20] & 1u) == 0) return 0;
    a->cabinet_unit = U32At(cabinet, 12);
    if (a->cabinet_unit == 0 || !vpm_read_u32(a->pool + 5208, &active) || active != 0) return 0;
    a->avatar = avatar.id;
    a->avatar_unit = avatar.unit;
    return 1;
}

static int Far(double value) { return value > 10000.0 || value < -10000.0; }

/* Whether the avatar stands within three world units of the cabinet's root. */
static int ArcadeNearby(VpmComponent* self, uint32_t cabinet_unit, uint32_t avatar_unit)
{
    if (n.unit_position == NULL) return 0;
    uintptr_t cabinet_at = (uintptr_t)n.unit_position(cabinet_unit, 0);
    uintptr_t avatar_at = (uintptr_t)n.unit_position(avatar_unit, 0);
    float cabinet[3], avatar[3];
    if (!vpm_read(cabinet_at, cabinet, sizeof cabinet) || !vpm_read(avatar_at, avatar, sizeof avatar)) return 0;
    double distance_squared = 0;
    for (int axis = 0; axis < 3; axis++)
    {
        if (Far(cabinet[axis]) || Far(avatar[axis])) return 0;
        double delta = (double)cabinet[axis] - (double)avatar[axis];
        distance_squared += delta * delta;
    }
    if (distance_squared != distance_squared) return 0;
    vpm_log(self, "Stratagem Hero distance squared: %.2f", distance_squared);
    return distance_squared <= ARCADE_MAX_DISTANCE_SQUARED;
}

static void StartArcade(VpmComponent* self)
{
    if (IdleManager(self, "Stratagem Hero", 0) == 0 || n.start_arcade == NULL) return;
    Arcade a;
    memset(&a, 0, sizeof a);
    if (!ArcadeContext(&a))
    {
        vpm_log(self, "Stratagem Hero shortcut detected; arcade or local avatar is unavailable.");
        return;
    }
    if (!ArcadeNearby(self, a.cabinet_unit, a.avatar_unit))
    {
        vpm_log(self, "Stratagem Hero shortcut detected; move beside the cabinet first.");
        return;
    }
    vpm_log(self, "Stratagem Hero shortcut detected; starting native arcade interaction.");
    n.start_arcade((void*)a.system, NULL, a.cabinet, a.avatar);
    uint32_t active = 0;
    char text[16];
    int known = vpm_read_u32(a.pool + 5208, &active);
    vpm_log(self, "Native arcade start returned; active avatar=%s.", Number(text, sizeof text, known, active));
}

/* ---- the Hellpod ------------------------------------------------------------------------------------------------- */

/* The local player's Hellpod: the deployment system's slot 0 pod, Hellpod index 0 in the manager, whose parallel per-pod
 * arrays hold entity pointers at +104, mode at +136, state at +184, index at +188 and target state at +264. */
typedef struct Pod { uint32_t pod, mode, current, target; } Pod;

static int HellpodContext(Pod* pod, const char** why)
{
    uintptr_t system = Plausible(vpm_game_u64(HELLPOD_SYSTEM_RVA)), manager = Plausible(vpm_game_u64(HELLPOD_MANAGER_RVA));
    uint32_t players[2], slot_pod = 0;
    uint8_t m[272]; /* manager +8 .. +280 */
    *why = "deployment system is unavailable";
    if (system == 0 || manager == 0) return 0;
    /* Slot 0 belongs to the local player only when they are alone; pod ownership with other players is unverified. */
    *why = "only solo ship sessions are supported";
    if (!vpm_read(system + 32, players, sizeof players) || players[0] != 1 || players[1] != 1) return 0;
    *why = "Hellpod layout is unavailable";
    if (!vpm_read_u32(system + 72984, &slot_pod) || slot_pod == 0 || !vpm_read(manager + 8, m, sizeof m)) return 0;
    uint32_t count = U32At(m, 0);
    if (count < 1 || count > 4) return 0;
    for (uint32_t i = 0; i < count; i++)
    {
        uintptr_t entity = Plausible(U64At(m, 96 + 8 * i));
        uint8_t e[13]; /* entity +8 .. +21: its id, and the owned bit in byte 20 */
        if (entity == 0 || !vpm_read(entity + 8, e, sizeof e) || U32At(e, 0) != slot_pod) continue;
        if (U32At(m, 180 + 20 * i) != 0 || (e[12] & 1u) == 0) return 0;
        pod->pod = slot_pod;
        pod->mode = U32At(m, 128 + 12 * i);
        pod->current = U32At(m, 176 + 20 * i);
        pod->target = U32At(m, 256 + 4 * i);
        return 1;
    }
    return 0;
}

static int PodOpen(const Pod* pod) { return pod->current == POD_OPEN && pod->target == POD_OPEN; }

/* The avatar's seater: its entity pointer and its 64-byte record (+0 seat collection, +48 transition in progress). */
static int AvatarSeater(uint32_t avatar, uintptr_t* entity, uintptr_t* seater)
{
    uintptr_t component = Plausible(vpm_game_u64(SEATER_COMPONENT_RVA));
    uint8_t c[68]; /* component +12 .. +80: count +12, map +32, entities +56, records +72 */
    HashMap map;
    uint32_t index = 0, id = 0;
    if (component == 0 || !vpm_read(component + 12, c, sizeof c) || !MapLayout(c + 20, &map)) return 0;
    if (!HashedValue(&map, avatar, &index) || index >= U32At(c, 0)) return 0;
    uintptr_t entities = Plausible(U64At(c, 44)), records = Plausible(U64At(c, 60));
    *entity = entities != 0 ? PointerAt(entities + 8u * (uintptr_t)index) : 0;
    if (*entity == 0 || records == 0 || !vpm_read_u32(*entity + 8, &id) || id != avatar) return 0;
    *seater = records + 64u * (uintptr_t)index;
    return 1;
}

/* The avatar's seater when it is free to enter a seat, or 0 with *why. */
static int FreeSeater(uintptr_t* entity, uintptr_t* seater, const char** why)
{
    Avatar avatar;
    uint8_t record[64];
    *why = "local avatar is unavailable";
    if (!LocalAvatar(&avatar)) return 0;
    *why = "local seater is unavailable";
    if (!AvatarSeater(avatar.id, entity, seater) || !vpm_read(*seater, record, sizeof record)) return 0;
    *why = "your character is already seated or moving";
    return U32At(record, 0) == 0 && record[48] == 0;
}

static void SeatInHellpod(VpmComponent* self, uint32_t pod)
{
    uintptr_t entity = 0, seater = 0;
    const char* why = "";
    if (!FreeSeater(&entity, &seater, &why))
    {
        vpm_log(self, "Hellpod seat skipped; %s.", why);
        return;
    }
    /* The placement the instant entry reads: byte 0 enables it, and the pointer at +72 holds the seat collection at
     * [406], an entrance hash at [407] (0 selects by index) and the entrance index at [408]. */
    uint32_t* placement = g_placement;
    memset(g_placement, 0, sizeof g_placement);
    memset(g_request, 0, sizeof g_request);
    g_placement[406] = pod;
    g_request[0] = 1;
    memcpy(g_request + 72, &placement, sizeof placement);
    n.enter_seat(NULL, (void*)entity, g_request);
    uint32_t seat = 0;
    char seat_text[16], presenter_text[16];
    int known = vpm_read_u32(seater, &seat);
    Presenter p = PresenterStatus();
    vpm_log(self, "Native Hellpod seat returned behind the briefing; seat=%s, presenter=%s.",
        Number(seat_text, sizeof seat_text, known, seat), Number(presenter_text, sizeof presenter_text, p.known, p.current));
}

/* The briefing at once; the seat once its UI covers the ship, so the move into the pod is not seen. */
static void EnterHellpod(VpmComponent* self, const Pod* pod)
{
    uintptr_t entity = 0, seater = 0;
    const char* why = "";
    if (!FreeSeater(&entity, &seater, &why))
    {
        vpm_log(self, "Hellpod shortcut detected; %s.", why);
        return;
    }
    vpm_log(self, "Hellpod shortcut detected; opening the briefing.");
    n.open_briefing(NULL, 0);
    Presenter p = PresenterStatus();
    if (!PresenterIs(&p, BRIEFING_PRESENTER))
    {
        char text[16];
        vpm_log(self, "Hellpod briefing did not open; presenter=%s.", Number(text, sizeof text, p.known, p.current));
        return;
    }
    n.seating = 1;
    n.seat_pod = pod->pod;
    n.seat_delay = SEAT_FALLBACK_SECONDS;
    n.seat_skipped = 0;
}

/* The loadout screen (MenuScreenType 11) when it is the top screen, or 0. */
static uintptr_t LoadoutScreen(void)
{
    uintptr_t stack = Plausible(vpm_game_u64(SCREEN_STACK_RVA));
    uint32_t type = 0;
    if (stack == 0 || !vpm_read_u32(stack, &type) || type != LOADOUT_SCREEN) return 0;
    return PointerAt(stack + LOADOUT_SCREEN_SLOT);
}

/* The seat's step: the briefing intro's timer expired once it is seen waiting, then the seat on the frame the briefing UI
 * is up (phase 0), or after the fallback delay when the intro is never seen. Seating later lets the pod's entry camera
 * replace the briefing's map camera (live test). */
static void ServiceSeat(VpmComponent* self, float dt)
{
    Presenter p = PresenterStatus();
    if (!PresenterIs(&p, BRIEFING_PRESENTER))
    {
        n.seating = 0;
        vpm_log(self, "Hellpod seat cancelled; the briefing closed before seating.");
        return;
    }
    n.seat_delay -= dt;
    uintptr_t screen = LoadoutScreen();
    uint32_t phase = 0;
    int seen = screen != 0 && vpm_read_u32(screen + INTRO_PHASE_OFFSET, &phase);
    if (seen && phase == INTRO_WAITING && !n.seat_skipped)
    {
        const float expired = 0.0f;
        memcpy((void*)(screen + INTRO_TIMER_OFFSET), &expired, sizeof expired);
        n.seat_skipped = 1;
        vpm_log(self, "Briefing intro skipped.");
        return;
    }
    if (!(n.seat_skipped && seen && phase == INTRO_DONE))
    {
        if (n.seat_delay > 0) return;
        vpm_log(self, "Briefing intro was not observed; seating after the fallback delay.");
    }
    n.seating = 0;
    Pod pod;
    const char* why = "";
    if (!HellpodContext(&pod, &why) || pod.mode != POD_MISSION_READY || !PodOpen(&pod) || pod.pod != n.seat_pod)
    {
        vpm_log(self, "Hellpod seat skipped; the Hellpod is no longer open.");
        return;
    }
    SeatInHellpod(self, n.seat_pod);
}

static void CancelWait(VpmComponent* self, const char* reason)
{
    n.waiting = 0;
    vpm_log(self, "Hellpod shortcut cancelled; %s.", reason);
}

/* The wait's step: a shortcut pressed during the pod's ready animation enters as soon as it opens. */
static void ServiceWait(VpmComponent* self, float dt)
{
    n.wait -= dt;
    Presenter p = PresenterStatus();
    if (!PresenterIdle(&p))
    {
        CancelWait(self, "another menu opened");
        return;
    }
    Pod pod;
    const char* why = "";
    if (!HellpodContext(&pod, &why) || pod.mode != POD_MISSION_READY) CancelWait(self, "the mission is no longer selected");
    else if (PodOpen(&pod))
    {
        n.waiting = 0;
        EnterHellpod(self, &pod);
    }
    else if (n.wait <= 0) CancelWait(self, "the Hellpod did not open in time");
}

static void StartHellpod(VpmComponent* self)
{
    if (IdleManager(self, "Hellpod Deployment", 0) == 0 || n.enter_seat == NULL || n.open_briefing == NULL) return;
    Pod pod;
    const char* why = "";
    if (!HellpodContext(&pod, &why))
    {
        vpm_log(self, "Hellpod shortcut detected; %s.", why);
        return;
    }
    if (pod.mode != POD_MISSION_READY)
    {
        vpm_log(self, "Hellpod shortcut detected; select a mission first.");
        return;
    }
    if (pod.current == POD_OCCUPIED || pod.target == POD_OCCUPIED)
    {
        vpm_log(self, "Hellpod shortcut detected; the Hellpod is already occupied.");
        return;
    }
    if (PodOpen(&pod))
    {
        n.waiting = 0;
        EnterHellpod(self, &pod);
        return;
    }
    n.waiting = 1;
    n.wait = HELLPOD_OPEN_WAIT_SECONDS;
    vpm_log(self, "Hellpod shortcut detected; entering when the Hellpod opens.");
}

/* ---- the interface ----------------------------------------------------------------------------------------------- */

void ssh_station_act(VpmComponent* self, int station, const char* name, uint32_t presenter)
{
    if (station == SSH_ARCADE) StartArcade(self);
    else if (station == SSH_HELLPOD) StartHellpod(self);
    else OpenPresenter(self, name, presenter);
}

int ssh_hellpod_pending(void) { return n.waiting || n.seating; }

void ssh_hellpod_service(VpmComponent* self, float dt)
{
    if (n.waiting) ServiceWait(self, dt);
    if (n.seating) ServiceSeat(self, dt);
}

void ssh_hellpod_forget(void)
{
    n.waiting = 0;
    n.seating = 0;
}
