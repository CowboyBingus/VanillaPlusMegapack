/* Sound Systems Rebalanced v1.0 (Lua: components/SoundSystemsRebalanced/src/sound_systems_rebalanced.lua), build 25480438.
 *
 * The Super Destroyer's rooms set the Wwise state environment_shiphub_room as the player walks through them, and the
 * war-table area's value, shiphub_view, lowers the music bus by 6 dB. Nothing resets that state when the player leaves
 * the ship, so a mission's music played 6 dB louder when they deployed from anywhere but the war table, most often when
 * joining a mission already in progress. This sets shiphub_view whenever a mission starts, so every mission plays its
 * music at the war-table level most players hear. In missions that state changes only the music bus; back on the ship
 * its own triggers set the room again as the player walks between rooms.
 *
 * How, as the Lua: every 0.25 s of game time (the frame times added up, no clock) it reads the game state, a u32 at
 * [game.dll + 0x3326340] + 0xAC21C (1 splash, 2 title, 5 preparing the ship, 3 ship, 6 preparing a mission, 4 mission).
 * When the state enters 6 or 4 from any other value (or is 6 or 4 at the first read), it sets the room state once and
 * logs one line. The game object's address is kept while the state reads back as a number up to 64, and found again at
 * the next check otherwise.
 *
 * On HellForge: the Lua called the engine's Lua binding stingray.Wwise.set_state('environment_shiphub_room',
 * 'shiphub_view'). A C mod has no game Lua, so this calls Wwise directly: AK::SoundEngine::SetState(0xEC643124,
 * 0x08EEC31C), the same state by id (Wwise's FNV-1 ids of those two names), exported by the game's Wwise plugin
 * wwise_pluginw64_release.dll, after AK::SoundEngine::IsInitialized, as HellForge's examples/mods/more-voices reaches
 * the plugin (the research's live A/B set this state through the same export). Both exports are found once, by their
 * mangled names, at HF_EVENT_ENTITIES_READY (the plugin is loaded by then); without them the component stays off, as
 * the Lua did without the binding, and the watch starts only once they are found. The game object pointer is a
 * game.dll static, read with a plain load (the Lua: a ReadProcessMemory). The state stays polled at the Lua's cadence:
 * HellForge's HF_ON_STATE comes on the frame of each change and skips the values 0 and 9 to 64, which clear the Lua's
 * mission flag, and HF_ON_MISSION_START comes at state 4 only, after the loading (6) the Lua sets the room at.
 * The Lua pack's other half, a patched music_init sound bank (music no longer silent on seven biomes), is game data:
 * this component does not carry it (the pack ships no game bytes, and a HellForge data spec cannot replace a bank in
 * place yet).
 *
 * Cost per frame: idle frames (all but one each 0.25 s): a double add and a compare, no call. A check frame: 1 heap read
 * (4 bytes, ReadProcessMemory); finding the game object again adds a plain load, no call. A mission start adds
 * IsInitialized and SetState (the plugin's own; unmeasured in game) and one log line. The Lua's frame_budget pins: 2
 * reads on a check that finds the game object (the first, and after a stale value), 1 on the others, 0 between; here
 * 1, 1 and 0. Once per session, at HF_EVENT_ENTITIES_READY: GetModuleHandleW, 2 GetProcAddress and one log line.
 * Nothing is written to game memory. */
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
    int inMission;      /* the last state read was 6 or 4 */
    int missions;       /* mission starts that set the room */
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

/* The watch: the frame time is the idle gate; a check every 0.25 s reads the state. lint: per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.elapsed += dt;
    if (s.elapsed < CHECK_SECONDS) return;
    s.elapsed = 0;
    uint32_t state = 0;
    if (!GameState(&state)) return;
    int mission = state == HF_STATE_PREPARE_MISSION || state == HF_STATE_MISSION;
    if (mission && !s.inMission) EnterMission(self, state);
    s.inMission = mission;
}

/* Finds the plugin's exports and starts the watch; again after a reload of the entity data, nothing. */
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
    return vpm_on_load(self, HF_EVENT_ENTITIES_READY, EntitiesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_sound_systems_rebalanced = {"sound_systems_rebalanced", "Sound Systems Rebalanced", "1.0", 0, Start, NULL};
