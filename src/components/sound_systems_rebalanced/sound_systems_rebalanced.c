/* Sound Systems Rebalanced v1.0 (Lua: components/SoundSystemsRebalanced/src/sound_systems_rebalanced.lua), build 25480438.
 *
 * The Super Destroyer's rooms set the Wwise state environment_shiphub_room as the player walks through them, and the
 * war-table area's value, shiphub_view, lowers the music bus by 6 dB. Nothing resets that state when the player leaves
 * the ship, so a mission's music played 6 dB louder when they deployed from anywhere but the war table, most often when
 * joining a mission already in progress. This sets shiphub_view whenever a mission starts, so every mission plays its
 * music at the war-table level most players hear. In missions that state changes only the music bus; back on the ship
 * its own triggers set the room again as the player walks between rooms.
 *
 * How, as the Lua: the game state is a u32 at [game.dll + 0x3326340] + 0xAC21C (1 splash, 2 title, 5 preparing the ship,
 * 3 ship, 6 preparing a mission, 4 mission). When the state enters 6 or 4 from any other value (or is 6 or 4 at the
 * first read), it sets the room state once and logs one line. The Lua read the state every 0.25 s of game time (the frame
 * times added up, no clock), keeping the game object's address while the state read back as a number up to 64.
 *
 * On HellForge: the Lua called the engine's Lua binding stingray.Wwise.set_state('environment_shiphub_room',
 * 'shiphub_view'). A C mod has no game Lua, so this calls Wwise directly: AK::SoundEngine::SetState(0xEC643124,
 * 0x08EEC31C), the same state by id (Wwise's FNV-1 ids of those two names), exported by the game's Wwise plugin
 * wwise_pluginw64_release.dll, after AK::SoundEngine::IsInitialized, as HellForge's examples/mods/more-voices reaches
 * the plugin (the research's live A/B set this state through the same export). Both exports are found once, by their
 * mangled names, at HF_EVENT_ENTITIES_READY (the plugin is loaded by then); without them the component stays off, as
 * the Lua did without the binding, and the watch starts only once they are found.
 *
 * The state's changes come from HellForge's HF_ON_STATE instead of the Lua's poll. HellForge's state source
 * (mod-loader/event_sources.c, EventSourcesTick, run from its game-thread hook before the game-thread callbacks) reads
 * the same u32 every game update, through the pointer each time, and delivers HF_ON_STATE on the update a state other
 * than none (0) differs from the last it delivered; a missing game object, a failed read or a value above 8 count as
 * none. The component applies the Lua's own rule to each delivered state (6 or 4 after anything else sets the room),
 * so it sets the room on the same changes as the Lua, never in a later frame (the Lua saw a change at its next 0.25 s
 * check, the event on the update it happens), and also on changes the Lua's checks could miss (a state shorter than a
 * check). It
 * follows a moved game object at once, where the Lua kept reading the old one while it held a value up to 64.
 * What the event cannot express is kept the Lua's way:
 *   - the first state: the watch's first frame reads it itself, with the Lua's rules (an unreadable or missing game
 *     object, or a value above 64, is read again 0.25 s later); the Lua's poll goes on until a state is known and
 *     HellForge has delivered one, so its state source is known to run (an event after the first check, or a read that
 *     succeeds after an event);
 *   - an unreadable game object or a value above 64 later: the Lua left its mission flag as it was, and no event comes,
 *     so the flag stays too;
 *   - the values 0 and 9 to 64, which cleared the Lua's mission flag (so 4, 0, 4 set the room twice): HellForge does not
 *     report them. game.dll never stores them once the game is set up: the game object is allocated zeroed once
 *     (0x4EE160, the only store of the 0x3326340 pointer), its state's only stores are 1 at the game's init (0xAB499B)
 *     and ChangeState's (0xAB309C), whose ten callers pass 2 to 6; the state names (0x2147F30) end at 8, and 7 and 8
 *     (the test level and debug mission) are reported. So 0 is seen only before the first state, when the flag is
 *     clear anyway, and the difference cannot arise on 25480438;
 *   - when HF_ON_STATE cannot be subscribed (HellForge refuses it), or HellForge never delivers a state (its game-thread
 *     hook is off), the Lua's poll runs for the whole session, as the 1:1 port did.
 * The Lua pack's other half, a patched music_init sound bank (music no longer silent on seven biomes), is game data:
 * this component does not carry it (the pack ships no game bytes, and a HellForge data spec cannot replace a bank in
 * place yet).
 *
 * Cost per frame, with the event (once HellForge has delivered a state change): no tick at all, so every frame makes no
 * call and no read; a state change runs the listener (no read); a mission start adds IsInitialized and SetState (the
 * plugin's own; unmeasured in game) and one log line. HellForge's state source reads the state every update (2
 * ReadProcessMemory calls in the loader) whenever a mod listens to a state event, which the core already does
 * (HF_ON_MISSION_START/END), so listening adds nothing to it. Until the event takes over, and for the whole session
 * without it: the Lua's poll, idle frames (all but one each 0.25 s) a double add and a compare, a check frame 1 read
 * (finding the game object again adds a plain load). The Lua's frame_budget pins: 2 reads on a check that finds the game
 * object (the first, and after a stale value), 1 on the others, 0 between. Once per session: the subscription at start;
 * at HF_EVENT_ENTITIES_READY GetModuleHandleW, 2 GetProcAddress and one log line; the first state read (1 read), and
 * one log line when the event takes over. Nothing is written to game memory. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "../../core/vpm.h"
#include "sound_systems_rebalanced.h"

#define GAME_RVA 0x3326340u           /* the game object's static pointer (Hellpod Drop Hold reads it too) */
#define STATE_AT 0xAC21Cu             /* its game state (HF_STATE_...; HellForge's event source reads the same u32) */
#define MAX_STATE 64u                 /* a larger value means the game object moved: find its pointer again */
#define LOWEST_OBJECT 0x10000ull      /* the Lua's plausible game object: [0x10000, 0x800000000000) */
#define OBJECT_LIMIT 0x800000000000ull
#define CHECK_SECONDS 0.25            /* game time between two reads of the game state */
#define GROUP 0xEC643124u             /* environment_shiphub_room */
#define ROOM 0x08EEC31Cu              /* shiphub_view */
#define AK_SUCCESS 1
#define PLUGIN L"wwise_pluginw64_release.dll"
/* The plugin's exports (Wwise 2024.1.9; its export table lists them at RVA 0xDD5A0 and 0xD56F0). SetState also has
 * by-name overloads (const char*, const wchar_t*); this is the one taking ids. */
#define SET_STATE_EXPORT "?SetState@SoundEngine@AK@@YA?AW4AKRESULT@@II@Z"
#define IS_INITIALIZED_EXPORT "?IsInitialized@SoundEngine@AK@@YA_NXZ"

static struct
{
    SsrWwise wwise;     /* the plugin's exports, once found */
    uintptr_t stateAt;  /* the game state's address; 0 until found, and again after a failed or implausible read */
    double elapsed;     /* game time since the last check */
    int inMission;      /* the last state seen was 6 or 4 */
    int missions;       /* mission starts that set the room */
    int reported;       /* HellForge has delivered a state change: its state source runs */
    int watching;       /* the watch's first check has run (on the game thread): state changes count from then on */
} s;

/* The plugin's exports by their mangled names: SSR_WWISE_FOUND with both set, or why not. */
static int FindWwise(SsrWwise* out)
{
    HMODULE plugin = GetModuleHandleW(PLUGIN);
    if (plugin == NULL) return SSR_WWISE_NO_PLUGIN;
    out->set_state = (SsrSetStateFn)(void*)GetProcAddress(plugin, SET_STATE_EXPORT);
    out->is_initialized = (SsrIsInitializedFn)(void*)GetProcAddress(plugin, IS_INITIALIZED_EXPORT);
    return out->set_state != NULL && out->is_initialized != NULL ? SSR_WWISE_FOUND : SSR_WWISE_NO_EXPORT;
}

static int (*g_lookup)(SsrWwise* out) = FindWwise;

#ifdef VPM_TEST
void sound_systems_rebalanced_test_wwise(int (*lookup)(SsrWwise* out)) { g_lookup = lookup != NULL ? lookup : FindWwise; }
#endif

/* The game state's address from the game object's static pointer (a plain load): 1, or 0 while there is no plausible
 * game object. */
static int Resolve(void)
{
    s.stateAt = 0;
    uint64_t object = vpm_game_u64(GAME_RVA);
    if (object < LOWEST_OBJECT || object >= OBJECT_LIMIT) return 0;
    s.stateAt = (uintptr_t)object + STATE_AT;
    return 1;
}

/* The game state: 1 with *state set, or 0 while the game object is missing, unreadable or its value implausible (the
 * address is then found again at the next check). */
static int GameState(uint32_t* state)
{
    if (s.stateAt == 0 && !Resolve()) return 0;
    if (!vpm_read_u32(s.stateAt, state) || *state > MAX_STATE)
    {
        s.stateAt = 0;
        return 0;
    }
    return 1;
}

/* Sets the room state once, on the frame the game enters a mission state. */
static void EnterMission(VpmComponent* self, uint32_t state)
{
    if (!s.wwise.is_initialized())
    {
        vpm_log(self, "Mission start (game state %u): the sound engine is not initialised; the music level is unchanged.", state);
        return;
    }
    int32_t result = s.wwise.set_state(GROUP, ROOM);
    if (result != AK_SUCCESS)
    {
        vpm_log(self, "Mission start (game state %u): Wwise refused environment_shiphub_room = shiphub_view (AKRESULT %d).",
            state, (int)result);
        return;
    }
    s.missions++;
    char status[80];
    snprintf(status, sizeof status, "held mission music at the war-table level %d time(s)", s.missions);
    vpm_set_status(self, status);
    vpm_log(self, "Mission start (game state %u): music held at the war-table level (environment_shiphub_room = shiphub_view).", state);
}

/* The Lua's rule for one state seen: entering 6 or 4 from anything else sets the room. */
static void Observe(VpmComponent* self, uint32_t state)
{
    int mission = state == HF_STATE_PREPARE_MISSION || state == HF_STATE_MISSION;
    if (mission && !s.inMission) EnterMission(self, state);
    s.inMission = mission;
}

/* HellForge's state source delivers every change from now on: the poll ends (once per session). */
static void EventTakesOver(VpmComponent* self)
{
    vpm_tick_stop(self);
    vpm_log(self, "HellForge's state event reports the game state from now on; the 0.25 s poll stopped.");
}

/* The Lua's poll: the frame time is the idle gate; a check every 0.25 s reads the state. It runs until HellForge has
 * delivered a state change and a state is known, for the whole session without the event. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.elapsed += dt;
    if (s.elapsed < CHECK_SECONDS) return;
    s.elapsed = 0;
    s.watching = 1;
    uint32_t state = 0;
    if (!GameState(&state)) return;
    Observe(self, state);
    if (s.reported) EventTakesOver(self);
}

/* HF_ON_STATE, on the update the game's state changes (never for none: a missing or unreadable game object, or a value
 * above 8). Before the watch's first check it only notes that the event runs: that check reads the state itself.
 * lint: per-frame */
static void StateChanged(VpmComponent* self, const HfEventInfo* event)
{
    if (event->size < sizeof(HfStateEvent)) return;
    s.reported = 1;
    if (!s.watching) return;
    Observe(self, ((const HfStateEvent*)event)->to);
    if (vpm_ticking(self)) EventTakesOver(self);
}

/* Finds the plugin's exports and starts the watch; again after a reload of the entity data, nothing. This runs on
 * HellForge's watch thread: the first state is read and acted on in the watch's first tick, on the game thread. */
static void EntitiesReady(VpmComponent* self, HfEvent event)
{
    if (s.wwise.set_state != NULL) return;
    int found = g_lookup(&s.wwise);
    if (found != SSR_WWISE_FOUND)
    {
        memset(&s.wwise, 0, sizeof s.wwise);
        vpm_fail(self, "%s", found == SSR_WWISE_NO_PLUGIN ? "the game's Wwise plugin (wwise_pluginw64_release.dll) is not loaded"
            : "the game's Wwise plugin exports no AK::SoundEngine::SetState(AkStateGroupID, AkStateID) or IsInitialized()");
        return;
    }
    s.elapsed = CHECK_SECONDS; /* the first frame reads at once */
    if (!vpm_tick_start(self, Tick))
    {
        vpm_fail(self, "the game thread could not be reached");
        return;
    }
    vpm_set_status(self, "watching for mission starts");
    vpm_log(self, "watching for mission starts.");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    if (!vpm_listen(self, HF_ON_STATE, StateChanged, 0)) vpm_log(self, "HellForge's state event is unavailable: the game state is polled every 0.25 s, as the Lua did.");
    return vpm_on_load(self, HF_EVENT_ENTITIES_READY, EntitiesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_sound_systems_rebalanced = {"sound_systems_rebalanced", "Sound Systems Rebalanced", "1.0", 0, Start, NULL};
