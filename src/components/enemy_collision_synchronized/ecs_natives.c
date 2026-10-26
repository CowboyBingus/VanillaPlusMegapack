/* Enemy Collision Synchronized: the game's routines the commands use, checked once (the Lua: windows_api.lua api.bind).
 *
 * The physics API table game.dll [0x3326338] must be the exe's table at 0x27CD910, with its enable (+8, exe 0x77F4F0),
 * position (+0x60, exe 0x799880) and rotation (+0x68, exe 0x799BA0) entries; both setters must start as reviewed; the
 * ragdoll stop routine (game.dll 0x7ABD00, 152 bytes, its ownership gate and final update-byte store included) and the
 * owner-routed corpse completion request (game.dll 0x13C0350, 422 bytes, every chained fragment) must match whole. These
 * engine wrappers validate the actor handle and enqueue native physics commands: they never write a body pose or a
 * broad-phase record directly, and the queue owns copies of the input vectors.
 *
 * On HellForge the code is compared with HfApi.code_matches (the bytes as shipped, through any hook another mod placed;
 * 256 bytes a call, so the long routines are compared in parts), by the core's wait (vpm_when_code_ready, EcsCodePins):
 * game.dll's code is decoded in parts after HF_EVENT_GAME_LOADED, and the physics API can be set up before the part
 * these routines are in. The wait checks them at that event and every 30 frames until they read as shipped; the core
 * stops the component if they never do within 60 s ("Position setter changed (helldivers2.exe 0x799880)"). The Lua
 * bound when the game's Lua started, by which time the physics API is set up; the pack starts earlier, so EcsBind waits
 * (nothing while the code is not decoded, then a plain load on poll frames) until the table pointer is set, then checks
 * the table once. */
#include <string.h>
#include <windows.h>
#include "ecs_internal.h"

#define BINDING_RVA 0x3326338u      /* game.dll: the physics API table the game uses */
#define PHYSICS_API_RVA 0x27CD910u  /* exe: that table */
#define ENABLED_RVA 0x77F4F0u       /* exe: actors' collision on or off (ids, count, enabled) */
#define POSITION_RVA 0x799880u      /* exe: queue an actor's position */
#define ROTATION_RVA 0x799BA0u      /* exe: queue an actor's rotation */
#define STOP_RVA 0x7ABD00u          /* game.dll: RagdollSync's stop (manager, index) */
#define COMPLETION_RVA 0x13C0350u   /* game.dll: ask a corpse's owner to complete it (service, 0, entity) */
#define SERVICE_RVA 0x346D500u      /* game.dll: the completion service, resolved on each request */
#define CHUNK_BYTES 128u

/* The reviewed bytes, as the core's wait checks them (vpm_when_code_ready): both setters' first 8, the whole stop and
 * completion routines in parts of at most CHUNK_BYTES (HfApi.code_matches takes 256), in the Lua's order. */
const VpmCodePin EcsCodePins[] = {
    {POSITION_RVA, "48 89 5C 24 08 48 89 6C", "Position setter", VPM_PIN_EXE},
    {ROTATION_RVA, "48 89 5C 24 08 48 89 6C", "Rotation setter", VPM_PIN_EXE},
    {STOP_RVA,
        "48 89 5C 24 08 57 48 83 EC 60 48 8B 41 38 44 8B C2 49 69 D8 B8 2B 00 00 4A 8B 3C C0 48 03 59 48 "
        "48 8B CF E8 68 22 D5 FF 80 B8 C4 06 00 00 00 74 55 8B 4F 08 E8 07 E0 82 00 48 85 C0 74 48 F6 40 "
        "14 01 74 42 44 8B 48 0C 33 D2 C6 44 24 50 00 0F 57 C0 F3 0F 11 44 24 48 44 8B C1 48 8B 0D 9E 17 "
        "CC 02 89 54 24 40 89 54 24 38 88 54 24 30 48 8D 54 24 78 F3 0F 11 44 24 28 C7 44 24 20 01 00 00",
        "Ragdoll stop routine", 0},
    {0x7ABD80u, /* STOP_RVA + 128 */
        "00 E8 BA 3D C1 00 C6 83 A4 2B 00 00 00 48 8B 5C 24 70 48 83 C4 60 5F C3",
        "Ragdoll stop routine", 0},
    {COMPLETION_RVA,
        "48 89 5C 24 18 48 89 54 24 10 56 48 83 EC 70 48 8B F1 41 8B D8 41 8B C8 E8 D3 99 C1 FF 48 85 C0 "
        "0F 84 72 01 00 00 F6 40 14 01 48 89 BC 24 80 00 00 00 0F 84 F2 00 00 00 8B 50 10 81 FA FF 7F 00 "
        "00 74 2E 48 8B 05 FE BB 0A 02 48 8B 48 08 E8 ED DF C1 FF 84 C0 74 1A 48 8B 0D 42 CB 0B 02 8B D3 "
        "48 8B 89 A8 B3 00 00 E8 34 0C 82 FF E9 1F 01 00 00 48 8B 0D C0 62 F6 01 8B D3 E8 81 6C 56 FF 84",
        "Corpse completion request", 0},
    {0x13C03D0u, /* COMPLETION_RVA + 128 */
        "C0 0F 84 09 01 00 00 33 FF 48 8D 46 1C 8B CF 90 39 18 0F 84 F8 00 00 00 FF C1 48 83 C0 40 83 F9 "
        "20 72 ED 8B CF 48 8D 86 24 08 00 00 0F 1F 40 00 39 18 0F 84 D8 00 00 00 FF C1 48 83 C0 40 81 F9 "
        "80 00 00 00 72 EA 8B CB E8 23 99 C1 FF 48 85 C0 0F 84 BA 00 00 00 F6 40 14 01 0F 84 B0 00 00 00 "
        "44 8B 48 0C 48 8D 94 24 88 00 00 00 40 88 7C 24 50 0F 57 C0 F3 0F 11 44 24 48 44 8B C3 F3 0F 10",
        "Corpse completion request", 0},
    {0x13C0450u, /* COMPLETION_RVA + 256 */
        "05 07 63 00 01 48 8B CE 89 7C 24 40 89 7C 24 38 C6 44 24 30 01 F3 0F 11 44 24 28 C7 44 24 20 01 "
        "00 00 00 E8 C8 F6 FF FF EB 66 8B 70 10 81 FE FF 7F 00 00 75 04 33 FF EB 23 48 8B 0D 78 5E F6 01 "
        "48 8B 41 40 48 8B B8 60 01 00 00 48 8B 41 38 FF 50 08 48 8B C8 8B D6 FF D7 48 8B F8 8B CB E8 8D "
        "95 C1 FF 41 B9 01 00 00 00 C7 44 24 60 01 00 00 00 4C 8D 44 24 60 C7 44 24 64 04 00 00 00 48 8B",
        "Corpse completion request", 0},
    {0x13C04D0u, /* COMPLETION_RVA + 384 */
        "D7 48 89 44 24 68 B9 32 6C 66 21 E8 50 DF 81 FF 48 8B BC 24 80 00 00 00 48 8B 9C 24 90 00 00 00 "
        "48 83 C4 70 5E C3",
        "Corpse completion request", 0},
};
const int EcsCodePinCount = (int)(sizeof EcsCodePins / sizeof EcsCodePins[0]);

static struct
{
    EcsNatives natives;
    double frequency;
} s;

static const EcsNatives* g_replacement;
static int g_codeReady; /* every pin read as shipped (the core's wait) */

void EcsUseNatives(const EcsNatives* replacement) { g_replacement = replacement; }

static double PerformanceClock(void)
{
    LARGE_INTEGER now;
    if (s.frequency <= 0 || !QueryPerformanceCounter(&now)) return 0; /* lint-ok: C4 the poll's work budget, read only on frames that inspect a unit (as the Lua's api.clock) */
    return (double)now.QuadPart / s.frequency;
}

static void CodeReady(VpmComponent* self, HfEvent event) { g_codeReady = 1; }

int EcsWaitForCode(VpmComponent* self)
{
    g_codeReady = 0;
    return vpm_when_code_ready(self, EcsCodePins, EcsCodePinCount, CodeReady);
}

/* The table entry at +offset must be the exe's function at rva: NULL, or why not. */
static const char* Entry(uint32_t offset, uint32_t rva)
{
    uint64_t value = 0;
    if (!vpm_exe_read(PHYSICS_API_RVA + offset, &value, 8) || EcsPointer(value) == 0) return "Physics binding unavailable";
    if (value - vpm_exe() != rva) return "Unsupported physics function";
    return NULL;
}

/* The Lua's checks of the physics API table, in its order (its code checks are the core's wait): NULL when every one
 * passes, or the first failure's text. */
static const char* Checks(uint64_t binding)
{
    const char* why = NULL;
    if (EcsPointer(binding) == 0) return "Physics binding unavailable";
    if (binding - vpm_exe() != PHYSICS_API_RVA) return "Unsupported physics API";
    if ((why = Entry(8, ENABLED_RVA)) != NULL || (why = Entry(0x60, POSITION_RVA)) != NULL ||
        (why = Entry(0x68, ROTATION_RVA)) != NULL)
        return why;
    return NULL;
}

static void GameNatives(void)
{
    s.natives.stop_sync = (void (*)(void*, uint32_t))(void*)(vpm_game() + STOP_RVA);
    s.natives.request_completion = (void (*)(void*, uintptr_t, uint32_t))(void*)(vpm_game() + COMPLETION_RVA);
    s.natives.set_position = (void (*)(uint32_t, const float*))(void*)(vpm_exe() + POSITION_RVA);
    s.natives.set_rotation = (void (*)(uint32_t, const float*))(void*)(vpm_exe() + ROTATION_RVA);
    s.natives.set_enabled = (void (*)(const uint32_t*, uint32_t, uint32_t))(void*)(vpm_exe() + ENABLED_RVA);
    s.natives.clock = PerformanceClock;
}

int EcsBind(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    if (!g_codeReady || vpm_game() == 0 || vpm_exe() == 0) return 0;
    uint64_t binding = vpm_game_u64(BINDING_RVA);
    if (binding == 0) return 0;
    const char* why = Checks(binding);
    LARGE_INTEGER frequency;
    frequency.QuadPart = 0;
    if (why == NULL && (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0)) /* lint-ok: C4 once, when the checks pass */
        why = "Performance clock unavailable";
    if (why != NULL)
    {
        vpm_fail(self, "%s", why);
        return -1;
    }
    s.frequency = (double)frequency.QuadPart;
    GameNatives();
    if (g_replacement != NULL) s.natives = *g_replacement;
    return 1;
}

double EcsClock(void) { return s.natives.clock != NULL ? s.natives.clock() : 0; }

void EcsStopSync(uintptr_t manager, uint32_t index) { s.natives.stop_sync((void*)manager, index); }

int EcsRequestCompletion(uint32_t entity)
{
    /* Resolved each time; no scene or service pointer is kept. */
    uintptr_t service = EcsPointer(vpm_game_u64(SERVICE_RVA));
    uint8_t probe[24];
    if (service == 0) return EcsRaise("Physics binding unavailable");
    if (!vpm_read(service, probe, sizeof probe)) return EcsRaise("Corpse completion service unavailable");
    s.natives.request_completion((void*)service, 0, entity);
    return 1;
}

void EcsSetPose(uint32_t actor, const double position[3], const double rotation[4])
{
    _Alignas(16) float p[4] = {(float)position[0], (float)position[1], (float)position[2], 0};
    _Alignas(16) float q[4] = {(float)rotation[0], (float)rotation[1], (float)rotation[2], (float)rotation[3]};
    s.natives.set_rotation(actor, q);
    s.natives.set_position(actor, p);
}

void EcsDisableActor(uint32_t actor)
{
    const uint32_t ids[1] = {actor};
    s.natives.set_enabled(ids, 1, 0);
}
