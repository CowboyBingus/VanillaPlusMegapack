/* Ship Station Hotkeys v1.9.1 (Lua: components/GalacticMenuHotkey/src/galactic_menu_hotkey.lua), build 25480438.
 *
 * Shortcuts aboard the Super Destroyer: Tab opens the Galactic Map, F1 the Armory, F5 the Control Center and F6 Ship
 * Management; F7 starts Stratagem Hero while the player stands beside the cabinet; F8 enters the Hellpod at once (the
 * briefing opens, then the avatar is seated behind it). Each calls the game's own entry for its station, with every
 * check the Lua made (stations.c). The six are Mod Bindings Menu bindings on its fixed native slots 1 and 3-7 (the Lua's
 * ids, labels, section and slots); while no bindings backend answers, each uses its fixed key, as the Lua did without
 * Mod Bindings Menu.
 *
 * A frame, as the Lua's step:
 *   - Context. Until the ship is found the context is read every 15 frames, and nothing else runs. Aboard and in a
 *     mission, the mission check (the mission record at [game.dll + 0x33266A0]: flag +8 set, type +0x40 in 1 .. 7) runs
 *     every 60 frames instead: a mission leaves the ship, its end starts the search again. The context is also read on
 *     every frame that acts (a newly pressed shortcut, a Hellpod wait or seat), so nothing acts on an older answer.
 *     Aboard, the context read checks the window focus too (GetForegroundWindow, GetWindowThreadProcessId).
 *   - The idle gate. The six slots' native actions have one 32-byte state entry each in the input owner
 *     ([game.dll + 0x347CF18] + 808 + 32 * (97 * group + action)), byte 0 set while a mapping fires: the same byte the
 *     bindings backend reads. While the backend answers, an idle frame aboard reads the stretch holding all six (6209
 *     bytes) and stops there; the backend is asked only while one of the bytes is set, or on the frame after.
 *   - Otherwise (no backend, or it does not answer yet, or a binding was refused) every focused frame aboard asks each
 *     shortcut: its binding's answer, else its fixed key. Unfocused, the shortcuts are up and only the focus is checked.
 *   - A shortcut acts on the frame it is first seen down, after a fresh context read.
 *
 * On HellForge, what differs from the Lua:
 *   - The ship check. The Lua looked for the galaxy table unit (resource 3b9bcf29e38da0a6) in the engine's worlds
 *     (stingray World.units_by_resource), an engine Lua API a C mod has no route to. HellForge's game state stands in:
 *     aboard is game_state == HF_STATE_SHIP (Game::change_state's state 3, StateShip). It is not proven equivalent: the
 *     Lua could also find the table while the ship loads (state 5, prepare-ship) and while it is left (state 6,
 *     prepare-mission, until the mission check sees the mission); this port treats both as not aboard, so a shortcut
 *     never acts during a launch. The mission check is the Lua's own.
 *   - Bindings go to the pack's registry at start (vpm_binding); the Mod Bindings Menu component attaches to them
 *     whenever it starts. The Lua's registration retries, its after-startup registration and its poll/is_down choice
 *     have no counterpart: registration cannot fail later, and vpm_binding_down is the one answer. A binding the
 *     registry refuses keeps its fixed key, and the gate stays off, as in the Lua.
 *   - The gate's layout check: the Lua gated only a Mod Bindings Menu table of API version 3 or 4 with 36 actions and a
 *     ready() function. The pack's only backend is its Mod Bindings Menu component, a port of v2.3 (fixed slots on the
 *     same native actions), so the layout holds by construction; ready() is a binding answering (vpm_binding_down >= 0),
 *     asked once per frame until it does and again at each 60-frame check aboard (so a backend that stopped is noticed
 *     within 60 frames).
 *   - Labels: the Lua passed the game's own localization ids for the map, Armory, Ship Management and Hellpod labels
 *     (the game translated them); VpmBindingDef takes text, so these are English. The section and the other two go
 *     through vpm_text, as the Lua's translations did.
 *   - Dropped: the update guard (error bursts, the pause after an error below this mod, the shutdown status), the
 *     build hash check (the core checks the build) and the Lua's world-detection log lines; the core's crash guard
 *     covers faults.
 *
 * COST per frame (calls; "read" is vpm_read, a guarded plain load; tests/components/ship_station_hotkeys_test.c pins
 * them). The game.dll statics the Lua read with ReadProcessMemory (the mission record and input owner pointers, the
 * UI state, the station globals) are plain loads here.
 *   - Before the ship: nothing; every 15 frames one game_state (HellForge: GetModuleHandleA and 2 reads). Lua: an engine
 *     world lookup (from_hex, main_world, worlds, units_by_resource per world, allocating) every 15 frames.
 *   - In a mission: nothing; every 60 frames 1 read (68 bytes). Lua: 2 reads.
 *   - Aboard, idle, backend answering: 1 read (the gate, 6209 bytes). Lua: 1 read. Every 60 frames 1 more read (the
 *     mission check) and one backend answer (ready). Lua: 3 reads (mission check 2, input owner 1).
 *   - Aboard, idle, no backend: 6 GetAsyncKeyState while focused, 1 GetForegroundWindow while not. Lua: the same.
 *   - A shortcut down (gate open): the gate's read and 6 backend answers. Lua: the gate's read and Mod Bindings Menu's
 *     poll (8 reads) or 6 is_down calls.
 *   - A new press: also game_state, 2 focus calls, then its action. A presenter: 2 reads and the call (Lua: 4 reads).
 *     Stratagem Hero: 17 reads, 2 world-position calls and the call. The Hellpod with the pod open: 16 reads and the
 *     briefing call; with the pod opening, 5 reads.
 *   - A Hellpod wait (at most 10 s) or seat (at most 3 s): game_state, 2 focus calls, 6 answers or keys, and 5 reads
 *     (wait; Lua: 16 reads and the engine lookup) or 2-4 reads (seat); the seat's own frame 20 reads and the call.
 *   - Once per session, when the ship is first found: 5 code checks (HfApi.code_matches) and 2 reads. Lua: 9 reads and
 *     the build hash (cached per session).
 *   No allocation, and no log line on an idle frame. */
#include <string.h>
#include <windows.h>
#include "ship_station_hotkeys.h"
#include "locale_data.h"

#define SHORTCUTS 6
#define CONTEXT_FRAMES 15            /* the context's interval until the ship is found */
#define WATCH_FRAMES 60              /* the mission check's interval aboard and in a mission */
#define MODE_RVA 0x33266A0u          /* the mission record's pointer */
#define MODE_RECORD_SIZE 68u
#define MODE_FLAG_WORD 2u
#define MODE_TYPE_WORD 16u
#define INPUT_OWNER_RVA 0x347CF18u
#define ACTION_STATE_OFFSET 808u
#define ACTION_STATE_STRIDE 32u
#define ACTIONS_PER_GROUP 97u
#define GATE_FIRST 971u              /* entry 97 * 10 + 1, the lowest of the six (Armory) */
#define GATE_LAST 1165u              /* entry 97 * 12 + 1, the highest (Galactic Map) */
#define GATE_SIZE (ACTION_STATE_STRIDE * (GATE_LAST - GATE_FIRST) + 1u) /* 6209 bytes */

typedef struct Shortcut
{
    const char* id;    /* the Lua's binding id */
    const char* name;  /* in the log */
    const char* text;  /* the label's text key (locales/en.lua), or NULL */
    const char* label; /* the label in English */
    uint32_t slot;     /* Mod Bindings Menu's fixed v1 slot */
    uint32_t key;      /* the fixed key */
    int station;
    uint32_t presenter;
} Shortcut;

/* In the order they are polled and acted on: the map first. */
static const Shortcut kShortcuts[SHORTCUTS] = {
    {"cowboybingus.galactic_menu", "Galactic Map", NULL, "GALACTIC MAP", 1, 0x09, SSH_PRESENTER, 15},             /* Tab, Hologram */
    {"cowboybingus.armory", "Armory", NULL, "ARMORY", 3, 0x70, SSH_PRESENTER, 5},                                  /* F1 */
    {"cowboybingus.control_center", "Control Center", "binding.control_center", "CONTROL CENTER", 4, 0x74, SSH_PRESENTER, 6}, /* F5 */
    {"cowboybingus.ship_management", "Ship Management", NULL, "SHIP MANAGEMENT", 5, 0x75, SSH_PRESENTER, 8},       /* F6 */
    {"cowboybingus.stratagem_hero", "Stratagem Hero", "binding.stratagem_hero", "STRATAGEM HERO", 6, 0x76, SSH_ARCADE, 0}, /* F7 */
    {"cowboybingus.hellpod", "Hellpod Deployment", NULL, "HELLPOD DEPLOYMENT", 7, 0x77, SSH_HELLPOD, 0},          /* F8 */
};

/* Mod Bindings Menu's fixed v1 slots' native actions {group, action}, slots 1 .. 7 (players' saved bindings belong to
 * them). */
static const uint8_t kSlotActions[7][2] = {{12, 1}, {12, 0}, {10, 1}, {10, 4}, {10, 8}, {10, 14}, {10, 9}};

static struct
{
    VpmBindingDef defs[SHORTCUTS];
    VpmBinding* bindings[SHORTCUTS]; /* NULL: refused, the fixed key answers */
    uint32_t gate_offsets[SHORTCUTS]; /* each shortcut's state byte in the gate's stretch */
    int gate;                 /* all six registered: the gate may stand in for the backend */
    int gate_ready;           /* the backend answered since the last check aboard */
    uintptr_t owner;          /* the input owner, read at each check aboard while gate */
    unsigned long process_id;
    int context_frames;       /* frames until the next check (the context, or the mission check) */
    int native;               /* the native check passed */
    int aboard, in_mission;
    int focused;              /* the game window was in front at the last context read or focus check */
    void* other_window;       /* a foreground window already found to belong to another process */
    uint8_t keys_down[SHORTCUTS]; /* each shortcut on the last frame that read them */
    uint8_t now[SHORTCUTS];       /* and on this frame */
    int held;                 /* a shortcut was down on the last frame that read them */
    int update_logged;
} s;

static uint8_t g_span[GATE_SIZE]; /* the gate's stretch of state entries */

/* ---- the window and the keys ------------------------------------------------------------------------------------- */

/* Whether the game's window is in front. Unless full, a window already found to be another process's is not looked up
 * again. */
static int FocusedGame(int full)
{
    const VpmUser32* user32 = vpm_user32();
    void* window = user32->GetForegroundWindow(); /* lint-ok: C4 on context reads and while unfocused aboard, as the Lua */
    if (window == NULL || (!full && window == s.other_window)) return 0;
    unsigned long process = 0;
    (void)user32->GetWindowThreadProcessId(window, &process); /* lint-ok: C4 only for a window not yet seen; process stays 0 on failure */
    int ours = process == s.process_id;
    s.other_window = ours ? NULL : window;
    return ours;
}

static int KeyDown(uint32_t key)
{
    return (vpm_user32()->GetAsyncKeyState((int)key) & 0x8000) != 0; /* lint-ok: C4 the fixed keys, focused aboard, as the Lua without Mod Bindings Menu */
}

/* A shortcut's state: its binding's answer, else its fixed key. */
static int ShortcutDown(int index)
{
    int down = vpm_binding_down(s.bindings[index]);
    return down >= 0 ? down != 0 : KeyDown(kShortcuts[index].key);
}

/* ---- the context ------------------------------------------------------------------------------------------------- */

/* Arriving on the ship (the native check the first time) or leaving it: the shortcuts start afresh. */
static void EnterShip(VpmComponent* self, int aboard)
{
    s.aboard = aboard;
    memset(s.keys_down, 0, sizeof s.keys_down);
    s.held = 0;
    ssh_hellpod_forget();
    if (!aboard) return;
    vpm_log(self, "Super Destroyer detected.");
    if (ssh_stations_check(self)) s.native = 1;
    if (!vpm_running(self)) s.aboard = 0; /* refused: this frame ends here, aboard no ship */
}

/* The context: the ship, then (aboard) the window focus. */
static void RefreshContext(VpmComponent* self)
{
    int aboard = vpm_hf()->game_state(vpm_mod()) == HF_STATE_SHIP;
    if (aboard != s.aboard) EnterShip(self, aboard);
    s.focused = s.aboard && FocusedGame(1);
}

/* The mission record shows a mission: 1 read. An unreadable record counts as none. */
static int MissionNow(void)
{
    uint64_t mode = vpm_game_u64(MODE_RVA);
    uint32_t words[MODE_RECORD_SIZE / 4];
    if (mode < 0x10000u || mode >= 0x800000000000ull || !vpm_read((uintptr_t)mode, words, MODE_RECORD_SIZE)) return 0;
    return words[MODE_FLAG_WORD] != 0 && words[MODE_TYPE_WORD] >= 1 && words[MODE_TYPE_WORD] <= 7;
}

static void SetMission(VpmComponent* self, int mission)
{
    if (mission == s.in_mission) return;
    s.in_mission = mission;
    vpm_log(self, mission ? "Mission detected; the shortcuts wait until it ends." : "Mission over; looking for the ship.");
}

static uintptr_t InputOwner(void)
{
    uint64_t owner = vpm_game_u64(INPUT_OWNER_RVA);
    return owner >= 0x10000u && owner < 0x800000000000ull ? (uintptr_t)owner : 0;
}

/* A check that is due; returns whether aboard. Once the native check has passed: in a mission nothing more until the
 * next check; aboard, the input owner again and the backend asked again (the gate's ready), next check in 60 frames.
 * Otherwise the context, again in 15 frames. */
static int CheckContext(VpmComponent* self)
{
    if (s.native)
    {
        SetMission(self, MissionNow());
        if (s.in_mission)
        {
            if (s.aboard) EnterShip(self, 0);
            s.context_frames = WATCH_FRAMES;
            return 0;
        }
    }
    if (!(s.native && s.aboard)) RefreshContext(self);
    if (s.aboard && s.native)
    {
        s.owner = s.gate ? InputOwner() : 0;
        s.gate_ready = 0;
        s.context_frames = WATCH_FRAMES;
    }
    else s.context_frames = CONTEXT_FRAMES;
    return s.aboard;
}

/* Runs first on every frame; returns whether aboard. */
static int Watch(VpmComponent* self)
{
    s.context_frames--;
    if (s.context_frames <= 0) return CheckContext(self);
    return s.aboard;
}

/* ---- the gate and the shortcuts ---------------------------------------------------------------------------------- */

/* Whether the gate answers for the backend on this frame: all six registered, the input owner known and the backend
 * answering (asked until it does). */
static int Gated(void)
{
    if (!s.gate || s.owner == 0) return 0;
    if (!s.gate_ready) s.gate_ready = vpm_binding_down(s.bindings[0]) >= 0;
    return s.gate_ready;
}

/* Whether a state byte of the six shortcuts' actions is set: one read. An unreadable stretch counts as set, so the
 * backend answers. */
static int GateOpen(void)
{
    if (!vpm_read(s.owner + ACTION_STATE_OFFSET + ACTION_STATE_STRIDE * GATE_FIRST, g_span, sizeof g_span)) return 1;
    for (int i = 0; i < SHORTCUTS; i++)
        if (g_span[s.gate_offsets[i]] != 0) return 1;
    return 0;
}

/* Whether this frame reads the shortcuts: not on an idle frame the gate answered (all up; a frame after one was down
 * marks them up). Otherwise the focus is checked first while it was lost. */
static int ShortcutsDue(void)
{
    if (Gated() && !GateOpen())
    {
        if (s.held)
        {
            memset(s.keys_down, 0, sizeof s.keys_down);
            s.held = 0;
        }
        return 0;
    }
    if (!s.focused) s.focused = FocusedGame(0);
    return 1;
}

/* Every shortcut's state on this frame (none is read while the game is not focused); whether one is newly pressed. */
static int PollShortcuts(void)
{
    int pressed = 0;
    for (int i = 0; i < SHORTCUTS; i++)
    {
        s.now[i] = (uint8_t)(s.focused && ShortcutDown(i));
        pressed |= s.now[i] && !s.keys_down[i];
    }
    return pressed;
}

/* Records this frame's states and acts on each newly pressed shortcut, in order. Nothing is down while not focused. */
static void ActOnShortcuts(VpmComponent* self)
{
    int held = 0;
    for (int i = 0; i < SHORTCUTS; i++)
    {
        int down = s.focused && s.now[i];
        int pressed = down && !s.keys_down[i];
        s.keys_down[i] = (uint8_t)down;
        held |= down;
        if (pressed) ssh_station_act(self, kShortcuts[i].station, kShortcuts[i].name, kShortcuts[i].presenter);
    }
    s.held = held;
}

/* A Hellpod wait or seat in progress: the context, then its step. Returns whether still aboard. */
static int ServicePending(VpmComponent* self, float dt)
{
    RefreshContext(self);
    if (!s.aboard) return 0;
    ssh_hellpod_service(self, dt);
    return 1;
}

/* lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    if (!s.update_logged)
    {
        s.update_logged = 1;
        vpm_log(self, "Update callback is running."); /* once, on the first frame */
    }
    if (!Watch(self)) return;
    int fresh = ssh_hellpod_pending();
    if (fresh)
    {
        if (!ServicePending(self, dt)) return;
    }
    else if (!ShortcutsDue()) return;
    /* A newly pressed shortcut acts only on a context read on this frame. */
    if (PollShortcuts() && !fresh)
    {
        RefreshContext(self);
        if (!s.aboard) return;
    }
    ActOnShortcuts(self);
}

/* ---- start ------------------------------------------------------------------------------------------------------- */

/* The six bindings, with the Lua's ids, labels, section and slots, and the fixed keys. */
static void RegisterBindings(VpmComponent* self)
{
    const char* section = vpm_text(self, "binding.section", "Ship Station Hotkeys");
    int registered = 0;
    for (int i = 0; i < SHORTCUTS; i++)
    {
        const Shortcut* k = &kShortcuts[i];
        const uint8_t* action = kSlotActions[k->slot - 1];
        s.gate_offsets[i] = ACTION_STATE_STRIDE * (ACTIONS_PER_GROUP * action[0] + action[1] - GATE_FIRST);
        s.defs[i] = (VpmBindingDef){k->id, k->text != NULL ? vpm_text(self, k->text, k->label) : k->label, section, k->slot, k->key};
        s.bindings[i] = vpm_binding(self, &s.defs[i]);
        if (s.bindings[i] != NULL) registered++;
        else vpm_log(self, "Mod binding registration failed for %s; its fixed key stays in use for this session.", k->name);
    }
    s.gate = registered == SHORTCUTS;
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    ssh_stations_reset();
    const VpmUser32* user32 = vpm_user32();
    if (user32->GetAsyncKeyState == NULL || user32->GetForegroundWindow == NULL || user32->GetWindowThreadProcessId == NULL)
        return vpm_fail(self, "user32's key and window functions are unavailable");
    s.process_id = GetCurrentProcessId();
    vpm_text_table(self, &vpm_texts_ship_station_hotkeys);
    RegisterBindings(self);
    if (!vpm_tick_start(self, Tick)) return vpm_fail(self, "the game thread could not be reached");
    vpm_log(self, "Ship menu hotkeys initialized (Tab, F1, F5-F8).");
    return 0;
}

/* Nothing to put back: the shortcuts call the game's own presenter, arcade, briefing and seat entries. */
const VpmComponentDef vpm_component_ship_station_hotkeys = {"ship_station_hotkeys", "Ship Station Hotkeys", "1.9.1", 0, Start, NULL};
