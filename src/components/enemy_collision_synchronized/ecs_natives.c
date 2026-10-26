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
 * 256 bytes a call, so the long routines are compared in parts). The Lua bound when the game's Lua started, by which time
 * the physics API is set up; the pack starts earlier, so EcsBind waits (a plain load on poll frames) until the table
 * pointer is set, then checks everything once. */
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

const char EcsSetterCode[] = "48 89 5C 24 08 48 89 6C";
const char EcsStopCode[] =
    "48895c2408574883ec60488b4138448bc24969d8b82b00004a8b3cc048035948488bcfe86822d5ff80b8c40600000074558b4f08e807e0"
    "82004885c07448f64014017442448b480c33d2c6442450000f57c0f30f11442448448bc1488b0d9e17cc02895424408954243888542430"
    "488d542478f30f11442428c744242001000000e8ba3dc100c683a42b000000488b5c24704883c4605fc3";
const char EcsCompletionCode[] =
    "48895c24184889542410564883ec70488bf1418bd8418bc8e8d399c1ff4885c00f8472010000f64014014889bc24800000000f84f20000"
    "008b501081faff7f0000742e488b05febb0a02488b4808e8eddfc1ff84c0741a488b0d42cb0b028bd3488b89a8b30000e8340c82ffe91f"
    "010000488b0dc062f6018bd3e8816c56ff84c00f840901000033ff488d461c8bcf9039180f84f8000000ffc14883c04083f92072ed8bcf"
    "488d86240800000f1f400039180f84d8000000ffc14883c04081f98000000072ea8bcbe82399c1ff4885c00f84ba000000f64014010f84"
    "b0000000448b480c488d94248800000040887c24500f57c0f30f11442448448bc3f30f100507630001488bce897c2440897c2438c64424"
    "3001f30f11442428c744242001000000e8c8f6ffffeb668b701081feff7f0000750433ffeb23488b0d785ef601488b4140488bb8600100"
    "00488b4138ff5008488bc88bd6ffd7488bf88bcbe88d95c1ff41b901000000c7442460010000004c8d442460c744246404000000488bd7"
    "4889442468b9326c6621e850df81ff488bbc2480000000488b9c24900000004883c4705ec3";

static struct
{
    EcsNatives natives;
    double frequency;
} s;

static const EcsNatives* g_replacement;

void EcsUseNatives(const EcsNatives* replacement) { g_replacement = replacement; }

static double PerformanceClock(void)
{
    LARGE_INTEGER now;
    if (s.frequency <= 0 || !QueryPerformanceCounter(&now)) return 0; /* lint-ok: C4 the poll's work budget, read only on frames that inspect a unit (as the Lua's api.clock) */
    return (double)now.QuadPart / s.frequency;
}

/* A routine's whole bytes (contiguous hex, as the Lua kept them), compared in parts of CHUNK_BYTES. */
static int CodeMatches(uintptr_t address, const char* hex)
{
    size_t length = strlen(hex);
    for (size_t at = 0; at < length; at += CHUNK_BYTES * 2u)
    {
        char part[CHUNK_BYTES * 2u + 1u];
        size_t n = length - at < CHUNK_BYTES * 2u ? length - at : CHUNK_BYTES * 2u;
        memcpy(part, hex + at, n);
        part[n] = 0;
        if (!vpm_hf()->code_matches(address + at / 2u, part)) return 0;
    }
    return 1;
}

/* The table entry at +offset must be the exe's function at rva: NULL, or why not. */
static const char* Entry(uint32_t offset, uint32_t rva)
{
    uint64_t value = 0;
    if (!vpm_exe_read(PHYSICS_API_RVA + offset, &value, 8) || EcsPointer(value) == 0) return "Physics binding unavailable";
    if (value - vpm_exe() != rva) return "Unsupported physics function";
    return NULL;
}

/* The Lua's checks, in its order: NULL when every one passes, or the first failure's text. */
static const char* Checks(uint64_t binding)
{
    const char* why = NULL;
    if (EcsPointer(binding) == 0) return "Physics binding unavailable";
    if (binding - vpm_exe() != PHYSICS_API_RVA) return "Unsupported physics API";
    if ((why = Entry(8, ENABLED_RVA)) != NULL || (why = Entry(0x60, POSITION_RVA)) != NULL ||
        (why = Entry(0x68, ROTATION_RVA)) != NULL)
        return why;
    if (!vpm_hf()->code_matches(vpm_exe() + POSITION_RVA, EcsSetterCode)) return "Position setter changed";
    if (!vpm_hf()->code_matches(vpm_exe() + ROTATION_RVA, EcsSetterCode)) return "Rotation setter changed";
    if (!CodeMatches(vpm_game() + STOP_RVA, EcsStopCode)) return "Ragdoll stop routine changed";
    if (!CodeMatches(vpm_game() + COMPLETION_RVA, EcsCompletionCode)) return "Corpse completion request changed";
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
    if (vpm_game() == 0 || vpm_exe() == 0) return 0;
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
