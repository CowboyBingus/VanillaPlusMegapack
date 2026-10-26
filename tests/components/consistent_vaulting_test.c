/* Consistent Vaulting: the Lua tests' scenarios (components/ConsistentVaulting/tests/test_vault.lua, test_slope.lua,
 * test_geometry.lua, test_raised_approach.lua, test_loader.lua) on the fake game. The game functions are faked at their
 * own signatures (cv_native.h) behind the real binding checks, so the C natives (windows_api.lua's api.native) are
 * tested too; the Lua tests faked api.native itself. Writes are counted at the component's one store function. */
#include <math.h>
#include <string.h>
#include <windows.h>
#include "harness/test.h"
#include "components.h"
#include "components/consistent_vaulting/cv.h"
#include "components/consistent_vaulting/cv_native.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_consistent_vaulting};

#define INVALID 0xFFFFFFFFu
#define CONTROL_AT (0x53E1B8u + 0x1238u)
#define REMOTE_AT 0x53E1B8u
#define FLAGS_AT (0x53E880u + 0x1238u)
#define DIRECTION_AT (0x53E134u + 0x1238u)
#define INPUT_AT (0x150u + 0xA7AECu + 0x1B68u + 14u * 32u)
#define SETTINGS_AT (0x547D24u + 852u)
#define PI 3.14159265358979323846

/* ---- the fake game ----------------------------------------------------------------------------------------------- */

typedef struct World
{
    uint8_t *game, *exe, *pm, *mode, *player, *owner, *entities, *avatars, *queries, *movement, *camera, *worldobj;
    uint8_t *unitrows, *avatarrows, *overrides, *move, *mover, *pool, *records, *definition, *object, *component, *shape;
    uint8_t *control, *remote, *settings, *flags, *input, *cap;
    uintptr_t controller, entity;
    uint8_t remote_before[0x1238];
} World;
static World w;

static void P64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static void P32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void P16(uint8_t* at, uint16_t v) { memcpy(at, &v, 2); }
static void PF(uint8_t* at, double v) { float f = (float)v; memcpy(at, &f, 4); }
static void PV(uint8_t* at, double x, double y, double z) { PF(at, x); PF(at + 4, y); PF(at + 8, z); }
static uint32_t G32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static double GF(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }
static uintptr_t A(const void* p) { return (uintptr_t)p; }
static void Global(uint32_t rva, const void* p) { P64(w.game + rva, A(p)); }

/* A game hash map with 16 rows, multiplier 1 and the empty key 0xFFFFFFFF, holding key -> index. */
static uint8_t* Map(uint8_t* header, uint32_t key, uint32_t index)
{
    uint8_t* rows = fake_heap(128);
    P64(header, A(rows));
    P32(header + 8, 16);
    P32(header + 12, INVALID);
    P32(header + 16, 1);
    for (int i = 0; i < 16; i++) P32(rows + 8 * i, INVALID);
    P32(rows + key % 16 * 8, key);
    P32(rows + key % 16 * 8 + 4, index);
    return rows;
}

typedef struct Binding { uint32_t global, table, offsets[3], functions[3]; } Binding;
static const Binding kBindings[3] = {
    {0x3326338u, 0x27CD910u, {0x18u, 0x38u, 0xA8u}, {0x7972F0u, 0x7993D0u, 0x799540u}},
    {0x3326388u, 0x27CDC30u, {0x00u, 0x28u, 0x68u}, {0x7CE220u, 0x7CF050u, 0x7CFE10u}},
    {0x3326328u, 0x27CDB40u, {0x00u, 0x68u, 0x80u}, {0x79F860u, 0x77DEC0u, 0x7F9070u}},
};
static const uint8_t kExitCode[] = {0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x08, 0x48, 0x89, 0x68, 0x20, 0x56};
static const uint8_t kDriverCode[] = {0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x54, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8D, 0x6C, 0x24, 0xD0};
static const uint8_t kApproachCode[] = {0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x08, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56};
static const uint8_t kOverrideCode[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57};

/* The game's function tables and the checked code bytes, as build 25480438 has them. */
static void BindTables(void)
{
    for (int b = 0; b < 3; b++)
    {
        P64(w.game + kBindings[b].global, A(w.exe + kBindings[b].table));
        for (int e = 0; e < 3; e++) P64(w.exe + kBindings[b].table + kBindings[b].offsets[e], A(w.exe + kBindings[b].functions[e]));
    }
    memcpy(w.game + 0xA9D560u, kExitCode, sizeof kExitCode);
    memcpy(w.game + 0xA9A0C0u, kDriverCode, sizeof kDriverCode);
    memcpy(w.game + 0xA9DD90u, kApproachCode, sizeof kApproachCode);
    memcpy(w.game + 0x83C420u, kOverrideCode, sizeof kOverrideCode);
}

static void MakeIdentity(void)
{
    static const uint8_t resource[8] = {0x97, 0xFA, 0x4D, 0x29, 0x4D, 0x33, 0x1C, 0x4D};
    P32(w.mode + 8, 1);
    P32(w.mode + 0x40, 1);
    P32(w.pm + 0x84, 2);
    P32(w.pm + 0x88, 2);
    P64(w.pm + 0xE8, A(w.player));
    P32(w.pm + 0x3A8, 9);
    w.player[20] = 1;
    for (int i = 0; i < 2; i++)
    {
        memcpy(w.entities + i * 24, resource, 8);
        P32(w.entities + i * 24 + 8, i == 0 ? 111 : 222);
        P32(w.entities + i * 24 + 12, i == 0 ? 333 : 444);
        w.entities[i * 24 + 20] = 1;
        P64(w.avatars + 0x110 + i * 8, A(w.entities + i * 24));
    }
    w.entity = A(w.entities + 24);
    w.unitrows = Map(w.owner + 0xF22EC8u, 9, 1);
    w.avatarrows = Map(w.avatars + 0xF8, 222, 1);
    P32(w.avatarrows + 111 % 16 * 8, 111);
    P32(w.avatarrows + 111 % 16 * 8 + 4, 0);
    P32(w.avatars + 0x6C, 2);
}

/* The effective settings: the override record at index 1 and the shared component record. */
static void MakeSettings(void)
{
    w.overrides = Map(w.avatars + 0x547C70u, 222, 1);
    w.settings = w.avatars + SETTINGS_AT;
    w.component = fake_heap(1736);
    P64(w.owner + 0xF12BB8u, A(w.component));
    memcpy(w.component, w.entities + 24, 8);
    P32(w.component + 8, 0);
    uint8_t* records[2] = {w.settings, w.component + 32};
    for (int i = 0; i < 2; i++)
    {
        PF(records[i] + 12, 2);      /* walking speed */
        PF(records[i] + 0x98, 45);   /* surface angle, slide entry */
        PF(records[i] + 172, 40);    /* slide exit */
        PF(records[i] + 0x104, 1.95);/* ground climb height */
        PF(records[i] + 0x108, 1.4); /* air climb height */
        PF(records[i] + 0x10C, 0.6); /* ground reach */
    }
    P32(w.avatars + 0x547D20u, 2);
}

/* The movement records and the mover's handle pool, record, definition and character controller object. */
static void MakeMover(void)
{
    Map(w.movement + 0x48A0, 222, 0);
    w.move = fake_heap(132);
    w.mover = fake_heap(164);
    P64(w.movement + 0x48C8, A(w.move));
    P64(w.movement + 0x48D0, A(w.mover));
    P32(w.mover + 76, 123);
    P32(w.mover + 88, 0x80000001u);
    w.pool = fake_heap(56);
    w.records = fake_heap(128);
    P64(w.exe + 0x27C3298u + 2 * 0x810u, A(w.pool));
    P64(w.pool, A(w.records));
    P32(w.pool + 28, 0x40);
    P32(w.pool + 36, 2);
    P32(w.pool + 40, 0xFFFF);
    P32(w.pool + 52, 0x80000000u);
    w.definition = fake_heap(28);
    w.object = fake_heap(104);
    P32(w.records + 64, 0x80000001u);
    P32(w.records + 72, 444);
    P64(w.records + 80, A(w.definition));
    P64(w.records + 88, A(w.object));
    P32(w.definition, 123);
    PF(w.definition + 8, 1.9);
    PF(w.definition + 12, 0.5);
    PF(w.definition + 16, 0.5);
    PF(w.definition + 20, 50 * PI / 180);
    PF(w.definition + 24, 70 * PI / 180);
    P64(w.object, A(w.exe + 0x16A16D8u));
    PF(w.object + 88, 1);
    PF(w.object + 96, cos(50 * PI / 180));
    PF(w.object + 100, cos(70 * PI / 180));
    w.shape = fake_heap(20);
    PF(w.shape + 8, 1.8);
    PF(w.shape + 12, 0.3);
    PF(w.shape + 16, 0.5);
}

static void MakeWorld(void)
{
    memset(&w, 0, sizeof w);
    w.game = (uint8_t*)fake_game();
    w.exe = (uint8_t*)fake_exe();
    w.pm = fake_heap(0x440);
    w.mode = fake_heap(0x44);
    w.player = fake_heap(24);
    w.owner = fake_heap(0xF32F18u + 96);
    w.entities = w.owner + 0xF32F18u;
    w.avatars = fake_heap(0x550000);
    w.queries = fake_heap(0x40070);
    w.movement = fake_heap(0x48E0);
    w.camera = fake_heap(0x40);
    w.worldobj = fake_heap(16);
    Global(CV_RVA_MODE, w.mode);
    Global(VPM_RVA_PLAYER_MANAGER, w.pm);
    Global(VPM_RVA_ENTITY_OWNER, w.owner);
    Global(VPM_RVA_AVATAR_MANAGER, w.avatars);
    Global(CV_RVA_MOVEMENT, w.movement);
    Global(CV_RVA_CAMERA, w.camera);
    Global(CV_RVA_WORLD, w.worldobj);
    MakeIdentity();
    MakeSettings();
    MakeMover();
    P64(w.avatars + 0x28, A(w.queries));
    w.control = w.avatars + CONTROL_AT;
    w.controller = A(w.control);
    w.remote = w.avatars + REMOTE_AT;
    P32(w.control + 0x2AC, 222);
    P32(w.remote + 0x2AC, 111);
    w.input = w.avatars + INPUT_AT;
    w.flags = w.avatars + FLAGS_AT;
    w.cap = w.avatars + DIRECTION_AT + 8;
    P32(w.avatars + DIRECTION_AT + 40, 222);
    PF(w.cap, -1);
    PV(w.camera + 0x1C, 0, 1, 0);
    BindTables();
    memcpy(w.remote_before, w.remote, sizeof w.remote_before);
}

/* ---- the game functions ------------------------------------------------------------------------------------------ */

enum { DETECT_MATCH, DETECT_BLOCK, DETECT_FRESH, DETECT_FRESH_THEN_BLOCK };

static struct
{
    uint32_t flags[8];
    float speed[8];
    int exit_calls, refreshes, retries, approach_calls, overrides, detects, bad;
    int miss, reject, exit_value, detect, no_ledge, basis_zero;
    int fault;             /* the next mover position call faults (once) */
    double root[3];
    uint8_t fresh[0x2B0];
    float ledge[8];        /* the raised search's first, last, span, width */
    float moved_first_x;   /* the second raised search's first x (NaN: unchanged) */
    uint8_t approach_args[52];
    uint32_t (*cast)(const uint8_t* record, uint8_t* out);
    void (*after_cast)(void);
    void (*after_exit)(void);
    float cast_z[16];      /* the source z of each cast (record + 72) */
} n;

static uint64_t FValid(uint32_t actor) { return actor != INVALID; }
static uint32_t FFlags(uint32_t actor) { return actor < 8 ? n.flags[actor] : 0; }
static void FMotion(uint32_t actor, float* first, float* second)
{
    first[0] = actor < 8 ? sqrtf(n.speed[actor]) : 0;
    first[1] = first[2] = 0;
}
static uint32_t FMover(uint32_t unit, uint32_t name)
{
    if (unit != 444 || name != 123) n.bad++;
    return 456;
}
static void* FDimensions(uint32_t mover) { return mover == 456 ? w.shape : NULL; }
static int* volatile g_nowhere; /* NULL: a store through it faults */
static void FPosition(uint32_t mover, float* out)
{
    if (n.fault)
    {
        n.fault = 0;
        *g_nowhere = 1;
    }
    for (int i = 0; i < 3; i++) out[i] = (float)n.root[i];
}
/* The horizontal forward/up basis (an offline stand-in for the native one). */
static void* FBasis(void* matrix, const float* forward, const float* up)
{
    const float d0 = forward[0], d1 = forward[1];
    const float m[16] = {d1, -d0, 0, 0, d0, d1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    if (n.basis_zero) memset(matrix, 0, 64);
    else memcpy(matrix, m, 64);
    return matrix;
}
static void FRotation(float* quaternion, const void* matrix) { quaternion[3] = 1; }
static int32_t FClassify(void* unused, const void* entity, const float* point, const float* quaternion)
{
    n.exit_calls++;
    if (unused != NULL || A(entity) != w.entity) n.bad++;
    if (n.after_exit) n.after_exit();
    if (n.exit_value) return n.exit_value;
    return point[0] == 13 ? 5 : 3;
}
static uint32_t FWorldId(const void* world)
{
    if (A(world) != A(w.worldobj)) n.bad++;
    return 77;
}
/* The default cast: the hit the query's output points at, as retained; one result unless missed. */
static uint32_t HitCast(const uint8_t* record, uint8_t* out)
{
    uintptr_t address;
    memcpy(&address, record, 8);
    if (address < w.controller + 0x30 || address > w.controller + 0x30 + 9 * 44) { n.bad++; return 0; }
    memcpy(out, (const void*)address, 44);
    return n.miss ? 0 : 1;
}
static uint32_t FQuery(uint32_t world, uint32_t a, uint32_t b, uint32_t c, uint32_t filter, const void* descriptor, void* out, uint32_t capacity)
{
    const uint64_t* d = descriptor;
    const uint8_t* record = (const uint8_t*)(uintptr_t)(d[2] - 16);
    if (world != 77 || a != 2 || b != 1 || c != 5 || filter != 0x05A5271Au || capacity != 1) n.bad++;
    if (d[3] != d[2] + 64 || d[4] != d[2] + 76 || d[5] != *(const uint64_t*)(record + 8)) n.bad++;
    if (n.refreshes < 16) n.cast_z[n.refreshes] = (float)GF(record + 72);
    n.refreshes++;
    uint32_t count = n.cast ? n.cast(record, out) : HitCast(record, out);
    if (n.after_cast) n.after_cast();
    return count;
}
static void FDrive(void* controller, float dt)
{
    if (A(controller) != w.controller || G32(w.control + 4) != 2 || G32(w.queries + 0x40000) != 0 || dt != 0) n.bad++;
    n.retries++;
    P32(w.control + 4, 3);
    if (!n.reject) P32(w.flags + 12, 0x200);
}
static int SameExceptPhase(const uint8_t* a, const uint8_t* b) { return memcmp(a, b, 4) == 0 && memcmp(a + 8, b + 8, 0x2B0 - 8) == 0; }
static uint32_t FDetect(void* copy, float dt)
{
    uint8_t* c = copy;
    n.detects++;
    if (n.detect == DETECT_BLOCK) return 4;
    if (n.detect == DETECT_MATCH) { P32(c + 4, 1); return 1; }
    if (SameExceptPhase(c, n.fresh))
    {
        if (n.detect == DETECT_FRESH_THEN_BLOCK) return 4;
        P32(c + 4, 1);
        return 1;
    }
    memcpy(c, n.fresh, 0x2B0);
    return 1;
}
static uint8_t FApproach(void* unused, const void* args, float* first, float* last, float* span, float* width)
{
    n.approach_calls++;
    memcpy(n.approach_args, args, sizeof n.approach_args);
    if (n.no_ledge) return 0;
    memcpy(first, n.ledge, 12);
    memcpy(last, n.ledge + 3, 12);
    *span = n.ledge[6];
    *width = n.ledge[7];
    if (n.approach_calls == 2 && n.moved_first_x == n.moved_first_x) first[0] = n.moved_first_x;
    return 1;
}
/* The original zero-count modifier: an unchanged copy of the base record and the local mapping. */
static void FOverride(void* manager, const void* entity, const void* modifier)
{
    n.overrides++;
    if (A(manager) != A(w.avatars) || A(entity) != w.entity) n.bad++;
    memcpy(w.settings, w.component + 32, 852);
    P32(w.overrides + 222 % 16 * 8, 222);
    P32(w.overrides + 222 % 16 * 8 + 4, 1);
    P32(w.avatars + 0x547D20u, 2);
}

static const CvNativeFns kFakes = {FValid, FFlags, FMotion, FMover, FDimensions, FPosition, FBasis, FRotation, FClassify,
    FWorldId, FQuery, FDrive, FDetect, FApproach, FOverride};

static void ResetNatives(void)
{
    memset(&n, 0, sizeof n);
    n.moved_first_x = NAN;
    n.no_ledge = 1;
}

/* ---- the component ----------------------------------------------------------------------------------------------- */

static CvState* St(void) { return cv_test_state(); }
static uint32_t Stores(void) { return cv_test_counts()->stores; }
static uint32_t Queries(void) { return cv_test_counts()->queries; }

static void Started(void)
{
    MakeWorld();
    ResetNatives();
    cv_native_test(&kFakes);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    cv_test_candidate(NULL);
}

/* A fresh state, as the Lua tests' state = {}. */
static void Fresh(void) { cv_state_reset(St()); }

static int g_accepted;

/* The Lua's patch.apply without the slope assistance: the vault check alone. */
static const char* Run(void)
{
    const char* reason = NULL;
    const CvPending* held = cv_held_writes(St());
    g_accepted = cv_vault_apply(St(), held, NULL, 0, &reason);
    return reason != NULL ? reason : "";
}

static int Is(const char* reason, const char* text) { return reason != NULL && strcmp(reason, text) == 0; }
static int Starts(const char* reason, const char* text) { return reason != NULL && strncmp(reason, text, strlen(text)) == 0; }
static uint32_t Unit(int slot) { return G32(w.control + 0x30 + slot * 44 + 28); }
static uint32_t Actor(int slot) { return G32(w.control + 0x30 + slot * 44 + 32); }
static int RemoteUnchanged(void) { return memcmp(w.remote, w.remote_before, sizeof w.remote_before) == 0; }

/* ---- the vault fixture (test_vault.lua's reset and late) --------------------------------------------------------- */

typedef struct Hit { int present; double x, height, normal; uint32_t actor; } Hit;
static Hit H(uint32_t actor) { Hit h = {1, 0, 1, 1, actor}; return h; }
static Hit HX(double x, uint32_t actor) { Hit h = {1, x, 1, 1, actor}; return h; }
static Hit HH(double height) { Hit h = {1, 0, height, 1, 1}; return h; }
static Hit HN(double normal) { Hit h = {1, 0, 1, normal, 1}; return h; }

static void ResetHits(const Hit* hits, int count)
{
    memset(w.control, 0, 0x2B0);
    P32(w.control + 0x2AC, 222);
    P32(w.control + 4, 2);
    memset(w.queries, 0, 0x40070);
    P32(w.queries + 0x40000, 10);
    P32(w.queries + 0x40008, 10);
    for (int i = 0; i < 8; i++) P32(w.queries + 0x4000C + 12 * i, 1);
    for (int slot = 0; slot < 10; slot++)
    {
        uint8_t* q = w.queries + slot * 128;
        P32(w.control + 8 + slot * 4, slot + 1);
        P64(q, w.controller + 0x30 + slot * 44);
        P32(q + 0x68, 0x05A5271Au);
        P32(q + 0x70, 444);
        PF(q + 16, 1);
        PF(q + 36, 1);
        PF(q + 56, 1);
        PV(q + 80, 0.25, 0.03, 0.05);
        P16(q + 0x74, 1);
        q[0x7A] = 2;
        q[0x7B] = 1;
        q[0x7C] = 5;
        if (slot >= count || !hits[slot].present) continue;
        uint8_t* data = w.control + 0x30 + slot * 44;
        P16(q + 0x76, 1);
        PV(data, hits[slot].x, 0, hits[slot].height);
        PV(data + 12, 0, 0, hits[slot].normal);
        P32(data + 28, 444);
        P32(data + 32, hits[slot].actor);
    }
    w.input[0] = 1;
    w.move[15] = 0;
    w.move[12] = 0;
    P32(w.mode + 0x40, 1);
    CHECK_EQ(n.bad, 0); /* the previous scenario called every game function as the game expects */
    ResetNatives();
    cv_test_counts()->stores = 0;
}

/* A consumed batch (stage 3) with an idle scheduler and an eligible avatar; the clock moves on by a second. */
static void Late(const Hit* hits, int count)
{
    ResetHits(hits, count);
    memset(w.flags, 0, 24);
    P32(w.flags, 2);
    P32(w.control + 4, 3);
    P32(w.queries + 0x40000, 0);
    St()->now += 1;
}

#define RESET(...) do { const Hit hits_[] = {__VA_ARGS__}; ResetHits(hits_, (int)(sizeof hits_ / sizeof hits_[0])); } while (0)
#define LATE(...) do { const Hit hits_[] = {__VA_ARGS__}; Late(hits_, (int)(sizeof hits_ / sizeof hits_[0])); } while (0)

/* ---- vault: stage 2 ---------------------------------------------------------------------------------------------- */

static void VaultMissionModes(void)
{
    Started();
    for (uint32_t mode = 1; mode <= 7; mode++)
    {
        RESET(H(2), H(1));
        n.flags[2] = 0x100000;
        P32(w.mode + 0x40, mode);
        Fresh();
        Run();
        CHECK(St()->has_pending);
        CHECK(RemoteUnchanged());
    }
    const uint32_t outside[3] = {0, 8, INVALID};
    for (int i = 0; i < 3; i++)
    {
        RESET(H(2), H(1));
        n.flags[2] = 0x100000;
        P32(w.mode + 0x40, outside[i]);
        Fresh();
        CHECK(Is(Run(), "waiting_for_mission"));
        CHECK_EQ(Stores(), 0);
    }
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P32(w.mode + 0x40, 2);
    P32(w.mode + 8, 0);
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0);
    CHECK(n.bad == 0);
}

static void VaultAlternatives(void)
{
    Started();
    RESET(H(1), H(2));
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0); /* a working first candidate is left alone */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    CHECK(Is(Run(), "local_manual_alternative_prepared"));
    CHECK(St()->has_pending);
    CHECK_EQ(Unit(0), 0);
    CHECK_EQ(Unit(1), 444);
    CHECK_EQ(St()->counters.metadata_fallbacks, 0);
    w.input[0] = 0;
    CHECK(Is(Run(), "waiting_for_manual_vault"));
    CHECK_EQ(Unit(0), 444);
    CHECK(!St()->has_pending);
    RESET(H(2));
    n.flags[2] = 0x100000;
    Fresh();
    CHECK(Is(Run(), "local_manual_metadata_fallback_prepared"));
    CHECK_EQ(St()->counters.metadata_fallbacks, 1);
    CHECK_EQ(Actor(0), INVALID);
    CHECK_EQ(n.flags[2], 0x100000); /* shared obstacle flags are unchanged */
    RESET(H(2));
    n.flags[2] = 0x100000;
    w.input[0] = 0;
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0);
    CHECK_EQ(n.exit_calls, 0);
    RESET(H(2));
    n.flags[2] = 0x200000;
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0);
    CHECK(RemoteUnchanged());
}

/* The checks of a hit: actor motion, height (ground and air), the native exit and the surface angle. */
static void VaultHitChecks(void)
{
    Started();
    RESET(H(2), H(1));
    n.speed[2] = 1.01f;
    Fresh();
    Run();
    CHECK_EQ(Unit(0), 0);
    RESET(H(2));
    n.speed[2] = 1;
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0);
    RESET(HH(2), H(1));
    Fresh();
    Run();
    CHECK_EQ(Unit(0), 0);
    RESET(HH(1.6), HH(1.2));
    w.move[15] = 1;
    Fresh();
    Run();
    CHECK_EQ(Unit(0), 0);
    RESET(HX(13, 1), H(1));
    Fresh();
    Run();
    CHECK_EQ(Unit(0), 0);
    CHECK_EQ(n.exit_calls, 2);
    RESET(HX(13, 2));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0);
    RESET(HN(0.5), H(1));
    Fresh();
    Run();
    CHECK_EQ(Unit(0), 0);
    RESET(HN(0.5));
    Fresh();
    Run();
    CHECK_EQ(Stores(), 0);
    CHECK(RemoteUnchanged());
}

/* Workers, ownership, identity and transitions: nothing is written. */
static void VaultRefusesForeignData(void)
{
    Started();
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P32(w.queries + 0x4000C, 0);
    Fresh();
    CHECK(Is(Run(), "waiting_for_query_workers"));
    CHECK_EQ(Stores(), 0);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P64(w.queries, A(w.remote + 0x30));
    Fresh();
    CHECK(Is(Run(), "waiting_for_game_data: Query output is not local controller data"));
    CHECK_EQ(Stores(), 0);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P32(w.control + 0x2AC, 111);
    Fresh();
    CHECK(Is(Run(), "waiting_for_game_data: Controller identity mismatch"));
    CHECK_EQ(Stores(), 0);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P64(w.pm + 0xE8, 0); /* the player record unreadable */
    Fresh();
    CHECK(Starts(Run(), "waiting_for_game_data"));
    CHECK_EQ(Stores(), 0);
    P64(w.pm + 0xE8, A(w.player));
    Run();
    CHECK(St()->has_pending);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P32(w.mode + 0x40, 0);
    Fresh();
    CHECK(Is(Run(), "waiting_for_mission"));
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    w.entities[24] = 0;
    Fresh();
    CHECK(Is(Run(), "waiting_for_game_data: Unsupported avatar resource"));
    CHECK_EQ(Stores(), 0);
    w.entities[24] = 0x97;
    CHECK(RemoteUnchanged());
}

/* Held writes: dropped unwritten when their epoch changed, kept while the plan is the same, replaced when it changes. */
static void VaultHeldWrites(void)
{
    Started();
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    P32(w.control + 4, 3);
    uint32_t before = Stores();
    Run();
    CHECK_EQ(Stores(), before);
    CHECK(!St()->has_pending);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    P32(w.control + 8, 20);
    before = Stores();
    CHECK(cv_restore(&St()->pending));
    CHECK_EQ(Stores(), before);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    before = Stores();
    P32(w.control + 0x2AC, 999);
    CHECK(cv_restore(&St()->pending));
    CHECK_EQ(Stores(), before);
    /* kept: no restore, no new write */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    before = Stores();
    for (int i = 0; i < 3; i++)
    {
        CHECK(Is(Run(), "local_manual_alternative_prepared"));
        CHECK_EQ(Stores(), before);
        CHECK_EQ(Unit(0), 0);
        CHECK_EQ(Unit(1), 444);
    }
    n.flags[2] = 0;
    CHECK(Is(Run(), "native_vault_checks_retained"));
    CHECK_EQ(Unit(0), 444);
    CHECK(!St()->has_pending);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    n.speed[1] = 2;
    CHECK(Is(Run(), "local_manual_metadata_fallback_prepared"));
    CHECK_EQ(Stores(), 3);
    CHECK_EQ(Unit(0), 444);
    CHECK_EQ(Actor(0), INVALID);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    P32(w.control + 0x30 + 28, 555); /* the game replaced the pair: never restored */
    CHECK(Is(Run(), "local_manual_alternative_prepared"));
    CHECK_EQ(Stores(), 2);
    CHECK_EQ(Unit(0), 0);
    /* The game put the original pair back: the same plan is not kept but written again. */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    P32(w.control + 0x30 + 28, 444);
    CHECK(Is(Run(), "local_manual_alternative_prepared"));
    CHECK_EQ(Stores(), 2);
    CHECK_EQ(Unit(0), 0);
    CHECK(RemoteUnchanged());
}

static void ReleaseInput(void) { w.input[0] = 0; }

static void VaultCommitChecks(void)
{
    Started();
    /* The native exit validator releasing the input: the commit sees it and writes nothing. */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    n.after_exit = ReleaseInput;
    Fresh();
    CHECK(Is(Run(), "query_changed_before_commit"));
    CHECK_EQ(Stores(), 0);
    /* An invalid native result refuses (the component stops). */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    n.speed[2] = NAN;
    Fresh();
    CHECK(Is(Run(), "validation_failed: Invalid actor motion"));
    CHECK_EQ(g_accepted, 0);
    CHECK_EQ(Stores(), 0);
    /* No override row: the shared component record. */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P32(w.overrides + 222 % 16 * 8, INVALID);
    Fresh();
    Run();
    CHECK_EQ(Unit(0), 0);
    P32(w.overrides + 222 % 16 * 8, 222);
    /* Any nonzero input byte is a press. */
    RESET(H(2));
    n.flags[2] = 0x100000;
    w.input[0] = 3;
    Fresh();
    Run();
    CHECK_EQ(Actor(0), INVALID);
    /* A controller that is not writable now: refused before any store, reported as data that changed. */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    cv_memory_reset();
    DWORD old;
    VirtualProtect(w.control, 0x2B0, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake controller read-only */
    const char* reason = Run();
    VirtualProtect(w.control, 0x2B0, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(Is(reason, "query_changed_before_commit"));
    CHECK_EQ(Stores(), 0);
    CHECK_EQ(Queries(), 1);
    CHECK(!St()->has_pending);
    CHECK(RemoteUnchanged());
}

/* ---- vault: stage 3, the late native retry ----------------------------------------------------------------------- */

static void LateRetry(void)
{
    Started();
    LATE(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    uint8_t hits[440], scheduler[1280];
    memcpy(hits, w.control + 0x30, sizeof hits);
    memcpy(scheduler, w.queries, sizeof scheduler);
    CHECK(Is(Run(), "native_local_vault_started"));
    CHECK_EQ(n.retries, 1);
    CHECK_EQ(n.refreshes, 2);
    CHECK_EQ(St()->counters.native_starts, 1);
    CHECK(memcmp(hits, w.control + 0x30, sizeof hits) == 0);
    CHECK_EQ(G32(w.control + 4), 3);
    CHECK(!St()->has_pending);
    CHECK(memcmp(scheduler, w.queries, sizeof scheduler) == 0);
    CHECK_EQ(n.flags[2], 0x100000);
    LATE(H(2));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    CHECK_EQ(St()->counters.metadata_fallbacks, 1);
    CHECK_EQ(n.retries, 1);
    CHECK_EQ(Actor(0), 2);
    LATE(H(2));
    n.flags[2] = 0x100000;
    n.miss = 1;
    Fresh();
    Run();
    CHECK_EQ(n.refreshes, 1);
    CHECK_EQ(n.retries, 0);
    CHECK_EQ(Stores(), 0);
    CHECK_EQ(St()->counters.native_starts, 0);
    LATE(HX(13, 2));
    n.flags[2] = 0x100000;
    Fresh();
    Run();
    CHECK_EQ(n.retries + (int)Stores(), 0);
    LATE(HH(3));
    Fresh();
    Run();
    CHECK_EQ(n.retries + (int)Stores(), 0);
    CHECK(n.bad == 0);
    CHECK(RemoteUnchanged());
}

/* The driver's own refusals and the scheduler's state stop a retry before any cast. */
static void LateRetryGates(void)
{
    Started();
    LATE(H(2));
    P32(w.queries + 0x40000, 1);
    Fresh();
    CHECK(Is(Run(), "waiting_for_idle_query_scheduler"));
    CHECK_EQ(n.refreshes, 0);
    LATE(H(2));
    P32(w.queries + 0x4000C, 0);
    Fresh();
    CHECK(Is(Run(), "waiting_for_query_workers"));
    LATE(H(2));
    w.input[0] = 0;
    Fresh();
    CHECK(Is(Run(), "waiting_for_manual_vault"));
    LATE(H(2));
    P32(w.flags + 12, 0x200);
    Fresh();
    CHECK(Is(Run(), "native_vault_state_retained"));
    LATE(H(2));
    P32(w.flags, 0);
    Fresh();
    CHECK(Is(Run(), "native_vault_state_retained"));
    LATE(H(2));
    w.control[0x214] = 1;
    Fresh();
    CHECK(Is(Run(), "native_vault_state_retained"));
    LATE(H(2));
    PF(w.queries + 64, 20);
    Fresh();
    CHECK(Is(Run(), "retained_query_out_of_reach"));
    LATE(H(2));
    n.detect = DETECT_BLOCK;
    Fresh();
    CHECK(Is(Run(), "native_approach_blocked"));
    CHECK_EQ(n.refreshes + n.retries + (int)Stores(), 0);
    LATE(H(2));
    n.flags[2] = 0x100000;
    n.reject = 1;
    Fresh();
    CHECK(Is(Run(), "native_local_retry_rejected"));
    CHECK_EQ(n.retries, 1);
    CHECK_EQ(St()->counters.native_starts, 0);
    CHECK(Is(Run(), "waiting_for_retry_interval"));
    CHECK_EQ(n.retries, 1);
    CHECK_EQ(G32(w.control + 4), 3);
    LATE(H(2));
    n.flags[2] = 0x100000;
    n.after_cast = ReleaseInput;
    Fresh();
    Run();
    CHECK_EQ(n.retries + (int)Stores(), 0);
    CHECK(n.bad == 0);
}

/* The fresh approach whose geometry changed: the batch's private queries are rebuilt from it. */
static void FreshApproach(void)
{
    memcpy(n.fresh, w.control, 0x2B0);
    P32(n.fresh + 4, 1);
    PV(n.fresh + 488, 0, 0.4, 1.9);
    PV(n.fresh + 500, 0, 1, 1.9);
    PF(n.fresh + 512, 1.3);
    PF(n.fresh + 516, 0.5);
    PV(n.fresh + 520, 0, 1, 0);
}

/* The changed-geometry cast: its source is the new approach's first slice; the hit moves there. */
static uint32_t ReprojectedCast(const uint8_t* record, uint8_t* out)
{
    if (fabs(GF(record + 68) - 0.43) > 0.000001) n.bad++;
    uint32_t count = HitCast(record, out);
    PV(out, 0, 0.43, 1);
    return count;
}

static void LateReprojected(void)
{
    Started();
    LATE(H(2));
    n.flags[2] = 0x100000;
    FreshApproach();
    n.detect = DETECT_FRESH;
    n.cast = ReprojectedCast;
    Fresh();
    uint8_t scheduler[1280], controller[0x2B0];
    memcpy(scheduler, w.queries, sizeof scheduler);
    memcpy(controller, w.control, sizeof controller);
    CHECK(Is(Run(), "native_local_vault_started"));
    CHECK_EQ(n.retries, 1);
    const CvCounters* c = &St()->counters;
    CHECK_EQ(c->context_reprojections, 1);
    CHECK_EQ(c->metadata_fallbacks, 1);
    CHECK_EQ(c->reprojected_retries, 1);
    CHECK_EQ(c->reprojected_starts, 1);
    CHECK(memcmp(scheduler, w.queries, sizeof scheduler) == 0);
    CHECK(memcmp(controller, w.control, sizeof controller) == 0);
    CHECK_EQ(n.refreshes, 1); /* originally empty slots are not cast */
    CHECK(n.bad == 0);
    const double normals[2] = {1, 0.314};
    for (int i = 0; i < 3; i++)
    {
        LATE(i == 1 ? HN(normals[1]) : H(2));
        n.flags[2] = 0x100000;
        FreshApproach();
        n.detect = DETECT_FRESH;
        n.miss = i == 0;
        n.exit_value = i == 2 ? 5 : 0;
        Fresh();
        Run();
        CHECK_EQ(n.refreshes, 1);
        CHECK_EQ(n.retries + (int)Stores(), 0);
    }
    LATE(H(2));
    n.flags[2] = 0x100000;
    FreshApproach();
    n.detect = DETECT_FRESH_THEN_BLOCK;
    Fresh();
    CHECK(Is(Run(), "native_context_changed_before_commit"));
    CHECK_EQ(n.refreshes, 1);
    CHECK_EQ(n.retries + (int)Stores(), 0);
}

static void LateUnsupportedApproach(void)
{
    Started();
    for (int edit = 0; edit < 5; edit++)
    {
        LATE(H(2));
        n.flags[2] = 0x100000;
        FreshApproach();
        if (edit == 0) P32(n.fresh + 684, 111); /* another avatar */
        if (edit == 1) PF(n.fresh + 512, 0);
        if (edit == 2) PF(n.fresh + 516, 3);
        if (edit == 3) PF(n.fresh + 524, NAN);
        if (edit == 4) PF(n.fresh + 528, 1);
        n.detect = DETECT_FRESH;
        Fresh();
        CHECK(Is(Run(), "unsupported_fresh_approach"));
        CHECK_EQ(n.refreshes + n.retries + (int)Stores(), 0);
    }
    LATE(H(2));
    n.flags[2] = 0x100000;
    FreshApproach();
    n.detect = DETECT_FRESH;
    n.basis_zero = 1;
    Fresh();
    CHECK(Is(Run(), "unsupported_query_basis"));
    CHECK_EQ(n.refreshes + n.retries + (int)Stores(), 0);
}

/* A8A710 leaves the automatic-step report (+533) set when the next lower selector finds nothing; A88160 does not veto
 * on it, and it is never cleared. */
static void LateStepReport(void)
{
    Started();
    LATE(H(2));
    n.flags[2] = 0x100000;
    w.control[533] = 1;
    Fresh();
    uint8_t controller[0x2B0];
    memcpy(controller, w.control, sizeof controller);
    CHECK(Is(Run(), "native_local_vault_started"));
    CHECK_EQ(n.retries, 1);
    CHECK(memcmp(controller, w.control, sizeof controller) == 0);
    CHECK_EQ(w.control[533], 1);
    CHECK_EQ(St()->counters.step_report_retries, 1);
    CHECK_EQ(St()->counters.step_report_starts, 1);
    LATE(H(2));
    n.flags[2] = 0x100000;
    w.control[533] = 1;
    n.miss = 1;
    Fresh();
    Run();
    CHECK_EQ(n.refreshes, 1);
    CHECK_EQ(n.retries + (int)Stores(), 0);
    LATE(H(2));
    n.flags[2] = 0x100000;
    w.control[533] = 1;
    w.control[532] = 1;
    Fresh();
    Run();
    CHECK_EQ(n.refreshes + n.retries, 0);
    LATE(H(2));
    n.flags[2] = 0x100000;
    w.control[533] = 1;
    FreshApproach();
    n.fresh[533] = 1;
    n.detect = DETECT_FRESH;
    Fresh();
    CHECK(Is(Run(), "native_local_vault_started"));
    CHECK_EQ(St()->counters.reprojected_starts, 1);
    CHECK_EQ(St()->counters.step_report_starts, 1);
    CHECK_EQ(w.control[533], 1);
}

/* ---- the assisted candidate search -------------------------------------------------------------------------------- */

static CvSlope g_owner; /* the slope snapshot that verified the avatar: only its entity is used */

/* M.assist_candidate: the kind (0 none, -1 raised) and *reason. */
static int Candidate(const char** reason)
{
    int kind = 0;
    const char* why = NULL;
    if (g_owner.entity == 0) g_owner.entity = w.entity;
    int found = cv_assist_candidate(St(), &g_owner, &kind, &why);
    if (reason != NULL) *reason = why;
    return found == 1 ? kind : found;
}

/* A consumed scheduler slot reused while the controller keeps its IDs: private discovery must rebuild every slot. */
static void Reused(void)
{
    LATE(HN(0.5));
    memset(w.queries, 0, 1280);
    P64(w.queries, A(w.remote + 0x30));
    P32(w.queries + 0x68, 0x393D9518u);
    P16(w.queries + 0x74, 64);
    P16(w.queries + 0x76, 64);
    FreshApproach();
    n.detect = DETECT_FRESH;
}

/* The native template of a rebuilt slot, cast: slot 7 finds a steep face. */
static uint32_t RebuiltCast(const uint8_t* record, uint8_t* out)
{
    static const uint8_t zeros[8];
    uintptr_t address;
    memcpy(&address, record, 8);
    if (G32(record + 0x68) != 0x05A5271Au || G32(record + 0x70) != 444 || record[0x74] != 1 || record[0x7A] != 2 ||
        record[0x7B] != 1 || record[0x7C] != 5 || memcmp(record + 8, zeros, 8) != 0 || G32(record + 108) != 0)
        n.bad++;
    memset(out, 0, 44);
    if ((address - w.controller - 0x30) / 44 != 7) return 0;
    PV(out, 0, 0.7, 1);
    PV(out + 12, 0, 0, 0.5);
    P32(out + 28, 555);
    P32(out + 32, 1);
    return 1;
}

static void ChangeId(void) { P32(w.control + 684, 999); }
static void ReuseUnrelated(void) { P32(w.queries + 0x68, 123); }
static uint32_t EmptyCast(const uint8_t* record, uint8_t* out) { memset(out, 0, 44); return 0; }

static void DiscoveryRebuildsReusedSlots(void)
{
    const char* why = NULL;
    Started();
    Reused();
    n.cast = RebuiltCast;
    Fresh();
    uint8_t scheduler[1280], controller[0x2B0];
    memcpy(scheduler, w.queries, sizeof scheduler);
    memcpy(controller, w.control, sizeof controller);
    CHECK_EQ(Candidate(&why), CV_KIND_SLOPE);
    CHECK(Is(why, "validated_steep_candidate"));
    CHECK_EQ(n.refreshes, 10);
    CHECK_EQ(St()->counters.query_rebuilds, 1);
    CHECK_EQ(St()->counters.context_reprojections, 1);
    CHECK_EQ(Stores() + (uint32_t)n.retries, 0);
    CHECK(memcmp(scheduler, w.queries, sizeof scheduler) == 0);
    CHECK(memcmp(controller, w.control, sizeof controller) == 0);
    /* The driver itself still uses the shared counts: never retried with reused records. */
    Reused();
    CHECK(Is(Run(), "retained_query_reused"));
    CHECK_EQ(Stores() + (uint32_t)(n.refreshes + n.retries), 0);
    Reused();
    n.cast = RebuiltCast;
    n.after_cast = ReuseUnrelated; /* unrelated scheduler reuse during the private casts */
    CHECK_EQ(Candidate(NULL), CV_KIND_SLOPE);
    Reused();
    n.cast = RebuiltCast;
    n.after_cast = ReleaseInput;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "candidate_changed"));
    Reused();
    n.cast = RebuiltCast;
    n.after_cast = ChangeId;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "candidate_changed"));
    CHECK_EQ(Stores() + (uint32_t)n.retries, 0);
    CHECK(n.bad == 0);
}

static void DiscoveryNeedsAFreshApproach(void)
{
    const char* why = NULL;
    Started();
    Reused();
    n.cast = RebuiltCast;
    n.detect = DETECT_BLOCK; /* the raised search then runs; it finds no ledge here */
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "raised_approach_no_ledge"));
    CHECK_EQ(n.refreshes, 0);
    Reused();
    n.cast = RebuiltCast;
    n.detect = DETECT_MATCH; /* the controller's own (empty) geometry */
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "unsupported_fresh_approach"));
    for (int edit = 0; edit < 4; edit++)
    {
        Reused();
        n.cast = RebuiltCast;
        if (edit == 0) P32(n.fresh + 684, 111);
        if (edit == 1) PF(n.fresh + 512, 0);
        if (edit == 2) PF(n.fresh + 516, 3);
        if (edit == 3) PF(n.fresh + 524, NAN);
        CHECK_EQ(Candidate(&why), 0);
        CHECK(Is(why, "unsupported_fresh_approach"));
        CHECK_EQ(n.refreshes, 0);
    }
    Reused();
    n.cast = RebuiltCast;
    n.detect = DETECT_FRESH_THEN_BLOCK;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "native_context_changed_before_commit"));
    Reused();
    n.cast = EmptyCast;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "no_usable_assisted_candidate"));
    CHECK_EQ(n.refreshes, 20);
    Reused();
    n.cast = RebuiltCast;
    n.exit_value = 5;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "no_usable_assisted_candidate"));
    CHECK_EQ(Stores() + (uint32_t)n.retries, 0);
}

static double g_topHeight, g_topNormal;
static int g_noHit;

/* The raised search's casts: a top at g_topHeight (the template checked as rebuilt). */
static uint32_t HigherCast(const uint8_t* record, uint8_t* out)
{
    (void)RebuiltCast(record, out);
    PV(out, 0, 0.7, g_topHeight);
    PV(out + 12, 0, 0, g_topNormal);
    P32(out + 28, 555);
    P32(out + 32, 1);
    return g_noHit ? 0 : 1;
}

/* v8.5's live failure: reused slots and a blocked ordinary-height approach kept every higher-top cast from running.
 * The native raised search is independent of that approach and may only authorize a private ledge candidate. */
static void Higher(double top, double normal)
{
    Reused();
    n.detect = DETECT_BLOCK;
    n.no_ledge = 0;
    const float ledge[8] = {0, 0.4f, 2.4f, 0, 1, 2.4f, 2, 0.5f};
    memcpy(n.ledge, ledge, sizeof ledge);
    n.cast = HigherCast;
    g_topHeight = top;
    g_topNormal = normal;
    g_noHit = 0;
}

static void RaisedSearchFindsHigherTops(void)
{
    const char* why = NULL;
    Started();
    Higher(2.2, 0.9);
    Fresh();
    uint8_t scheduler[1280], controller[0x2B0];
    memcpy(scheduler, w.queries, sizeof scheduler);
    memcpy(controller, w.control, sizeof controller);
    CHECK_EQ(Candidate(&why), CV_KIND_LEDGE);
    CHECK(Is(why, "validated_raised_top"));
    CHECK_EQ(n.approach_calls, 2);
    CHECK_EQ(n.refreshes, 10);
    CHECK_EQ(St()->counters.raised_approach_rebuilds, 1);
    CHECK_EQ(St()->counters.raised_context_fallbacks, 1);
    CHECK_EQ(Stores() + (uint32_t)n.retries, 0);
    CHECK(memcmp(scheduler, w.queries, sizeof scheduler) == 0);
    CHECK(memcmp(controller, w.control, sizeof controller) == 0);
    for (int variant = 0; variant < 5; variant++)
    {
        Higher(variant == 0 ? 2.51 : 2.2, variant == 1 ? 0.5 : 0.9);
        g_noHit = variant == 2;
        if (variant == 3) n.speed[1] = 2;
        if (variant == 4) n.exit_value = 5;
        CHECK_EQ(Candidate(&why), 0);
        CHECK(Is(why, "no_usable_assisted_candidate"));
    }
    Higher(2.5, 0.9);
    CHECK_EQ(Candidate(NULL), CV_KIND_LEDGE);
    Higher(2.2, 0.9);
    n.after_cast = ReleaseInput;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "candidate_changed"));
    Higher(2.2, 0.9);
    n.after_cast = ChangeId;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "candidate_changed"));
    Higher(2.2, 0.9);
    n.moved_first_x = 0.05f;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "raised_context_changed_before_commit"));
    Higher(2.2, 0.9);
    n.no_ledge = 1;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "raised_approach_no_ledge"));
    CHECK_EQ(n.refreshes, 0);
    Higher(2.2, 0.9);
    w.move[15] = 1; /* in the air: no higher-top search */
    CHECK_EQ(Candidate(NULL), 0);
    CHECK_EQ(n.approach_calls, 0);
    Higher(2.2, 0.9);
    CHECK(Is(Run(), "retained_query_reused"));
    CHECK_EQ(n.approach_calls + n.retries + (int)Stores(), 0);
    CHECK(n.bad == 0);
}

/* The ordinary candidates of a retained batch: a steep face is offered only when no ordinary candidate exists. */
static void OrdinaryCandidates(void)
{
    const char* why = NULL;
    Started();
    uint8_t controller[0x2B0];
    static const double normals[7] = {0.9, 0.5, 0.314, 0.5, 0.5, 0.5, 0.5};
    static const int expected[7] = {0, CV_KIND_SLOPE, 0, 0, 0, 0, 0};
    for (int i = 0; i < 7; i++)
    {
        LATE(HN(normals[i]));
        n.miss = i == 3;
        if (i == 4) n.speed[1] = 2;
        if (i == 5) n.exit_value = 5;
        g_owner.entity = i == 6 ? w.entity + 24 : w.entity;
        memcpy(controller, w.control, sizeof controller);
        CHECK_EQ(Candidate(&why), expected[i]);
        CHECK_EQ(Stores() + (uint32_t)n.retries, 0);
        CHECK(memcmp(controller, w.control, sizeof controller) == 0);
    }
    CHECK(Is(why, "candidate_identity_changed"));
    g_owner.entity = w.entity;
    LATE(HN(0.9));
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "ordinary_candidate_retained"));
    LATE(HN(0.5));
    n.speed[1] = NAN;
    CHECK_EQ(Candidate(NULL), CV_RAISED); /* an invalid native result raises: the check's error restores and starts fresh */
    CHECK_EQ(Stores(), 0);
    LATE(HN(0.5));
    w.input[0] = 0;
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "waiting_for_manual_vault"));
    LATE(HN(0.5));
    P64(w.pm + 0xE8, 0);
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "candidate_snapshot_unavailable"));
    P64(w.pm + 0xE8, A(w.player));
    CHECK_EQ(Candidate(NULL), CV_KIND_SLOPE);
    /* An expired query (a foreign output) without a fresh approach: skipped, and found again on a valid batch. */
    LATE(HN(0.5));
    P64(w.queries, A(w.remote + 0x30));
    CHECK_EQ(Candidate(&why), 0);
    CHECK(Is(why, "unsupported_fresh_approach"));
    P64(w.queries, w.controller + 0x30);
    CHECK_EQ(Candidate(NULL), CV_KIND_SLOPE);
    CHECK(n.bad == 0);
}

/* The raised casts of a retained batch's hits: g_topHeight once the source was raised (z >= g_raisedFrom). */
static double g_raisedFrom;
static uint32_t RaisedCast(const uint8_t* record, uint8_t* out)
{
    double z = GF(record + 72);
    if (z < g_raisedFrom) return HitCast(record, out);
    uintptr_t address;
    memcpy(&address, record, 8);
    const uint8_t* original = w.queries + (address - w.controller - 0x30) / 44 * 128;
    if (memcmp(record, original, 72) != 0 || memcmp(record + 76, original + 76, 52) != 0) n.bad++;
    memcpy(out, (const void*)address, 44);
    PV(out, 0, 0, g_topHeight);
    PV(out + 12, 0, 0, g_topNormal);
    P32(out + 28, 555);
    P32(out + 32, 1);
    return 1;
}

static void RaisedFrom(double from, double top, double normal)
{
    LATE(HN(0.314));
    n.cast = RaisedCast;
    g_raisedFrom = from;
    g_topHeight = top;
    g_topNormal = normal;
}

static void LedgeCandidates(void)
{
    const char* why = NULL;
    Started();
    RaisedFrom(0.29, 2.2, 0.7852);
    CHECK_EQ(Candidate(&why), CV_KIND_LEDGE);
    CHECK(Is(why, "validated_raised_top"));
    CHECK_EQ(n.refreshes, 11); /* the ordinary recast of slot 0, then the ten raised casts */
    CHECK(fabs(n.cast_z[1] - 2.84) < 0.000001); /* the mover-relative ceiling plus the box's clearance */
    static const double tops[5] = {2.5, 0.1, 2.51, 2.2, 2.2};
    static const double topNormals[5] = {0.7852, 0.7852, 0.7852, 0.45, 0.7852};
    static const int kinds[5] = {CV_KIND_LEDGE, 0, 0, 0, 0};
    for (int i = 0; i < 5; i++)
    {
        RaisedFrom(0.29, tops[i], topNormals[i]);
        if (i == 4) n.exit_value = 5;
        CHECK_EQ(Candidate(NULL), kinds[i]);
    }
    RaisedFrom(0.29, 2.2, 0.7852);
    w.move[15] = 1;
    CHECK_EQ(Candidate(NULL), 0);
    CHECK_EQ(n.refreshes, 1);
    LATE(H(1)); /* overwritten below: no hits at all */
    memset(w.control + 0x30, 0, 440);
    for (int slot = 0; slot < 10; slot++) P16(w.queries + slot * 128 + 0x76, 0);
    n.cast = RaisedCast;
    g_raisedFrom = 0.29;
    g_topHeight = 2.2;
    g_topNormal = 0.7852;
    CHECK_EQ(Candidate(NULL), CV_KIND_LEDGE); /* a previously empty slot can reveal a top higher up */
    RaisedFrom(0.29, 2.2, 0.7852);
    n.after_cast = ReleaseInput;
    CHECK_EQ(Candidate(NULL), 0);
    /* The live search ceiling was about 1.93 above the mover; a fixed lift still touched the face below a 2.45-2.50
     * top. The whole query box must start clear: the ceiling is the mover's height + 2.5 + the box's clearance. */
    RaisedFrom(2.75, 2.48, 0.7852);
    for (int slot = 0; slot < 10; slot++) PF(w.queries + slot * 128 + 72, 1.928206);
    CHECK_EQ(Candidate(NULL), CV_KIND_LEDGE);
    RaisedFrom(2.75, 2.48, 0.7852);
    for (int slot = 0; slot < 10; slot++) PF(w.queries + slot * 128 + 72, 0.52);
    CHECK_EQ(Candidate(NULL), CV_KIND_LEDGE);
    CHECK(fabs(n.cast_z[1] - 2.84) < 0.000001);
    RaisedFrom(2.75, 2.48, 0.7852);
    n.root[2] = 0.125;
    for (int slot = 0; slot < 10; slot++) PF(w.queries + slot * 128 + 72, 0.125);
    CHECK_EQ(Candidate(NULL), CV_KIND_LEDGE);
    CHECK(fabs(n.cast_z[1] - (0.125 + 2.84)) < 0.000001);
    LATE(HN(0.314));
    PF(w.queries + 64, 20);
    CHECK_EQ(Candidate(NULL), 0);
    CHECK_EQ(n.refreshes, 0);
    /* The relaxed context of private discovery never reaches controller consumption. */
    LATE(HN(0.9));
    n.detect = DETECT_BLOCK;
    PF(w.settings + 0x104, 2.5);
    CHECK(Is(Run(), "native_approach_blocked"));
    CHECK_EQ(n.refreshes + n.retries + (int)Stores(), 0);
    PF(w.settings + 0x104, 1.95);
    CHECK(n.bad == 0);
}

/* ---- geometry: the native producer's descriptors (test_geometry.lua) ---------------------------------------------- *
 * Captured from the original A8A140 producer: four fresh approaches (first, last, span, width, direction) and the ten
 * descriptors it emitted for each. Ownership addresses and the unit are synthetic. The basis stand-in models the
 * horizontal forward/up basis; this is not native ABI testing. */

static const double kGeometry[4][11] = {
    {-180.12643432617188, -46.622737884521484, 4.967824935913086, -180.57806396484375, -47.01774597167969, 4.967824935913086, 1.1150000095367432, 0.5, -0.7527146935462952, -0.658346951007843, 0},
    {-180.88314819335938, -45.612300872802734, 5.077669620513916, -180.9506072998047, -46.20849609375, 5.077669620513916, 0.39000001549720764, 0.5, -0.11242987215518951, -0.9936596751213074, 0},
    {-180.13983154296875, -45.95630645751953, 4.956434726715088, -180.67596435546875, -46.22565841674805, 4.956434726715088, 1.1150000095367432, 0.5, -0.8935732841491699, -0.4489173889160156, 0},
    {-180.45347595214844, -46.12472152709961, 4.966745853424072, -180.77516174316406, -46.631195068359375, 4.966745853424072, 1.1150000095367432, 0.5, -0.5361417531967163, -0.8441280126571655, 0},
};
static const char* const kRecords[4][10] = {
    {
        "300000600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000262634c3e8913ac2d25e9d400000803f0000803ea0c2f53ccdcc4c3d262634c3e8913ac2e1c779401a27a50500000000bc010000010001000100020105000000",
        "5c0000600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000b63134c35bba3ac2d25e9d400000803f0000803ea0c2f53ccdcc4c3db63134c35bba3ac2e1c779401a27a50500000000bc010000010001000100020105000000",
        "880000600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000463d34c3cee23ac2d25e9d400000803f0000803ea0c2f53ccdcc4c3d463d34c3cee23ac2e1c779401a27a50500000000bc010000010001000100020105000000",
        "b40000600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000d54834c3410b3bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3dd54834c3410b3bc2e1c779401a27a50500000000bc010000010001000100020105000000",
        "e00000600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000665434c3b4333bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3d665434c3b4333bc2e1c779401a27a50500000000bc010000010001000100020105000000",
        "0c0100600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000f55f34c3275c3bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3df55f34c3275c3bc2e1c779401a27a50500000000bc010000010001000100020105000000",
        "380100600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000846b34c39a843bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3d846b34c39a843bc2e1c779401a27a50500000000bc010000010001000100020105000000",
        "640100600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000147734c30cad3bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3d147734c30cad3bc2e1c779401a27a50500000000bc010000010001000100020105000000",
        "900100600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000a48234c380d53bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3da48234c380d53bc2e1c779401a27a50500000000bc010000010001000100020105000000",
        "bc0100600000000000000000000000006e8928bfe9b1403f0000000000000000e9b140bf6e8928bf000000000000000000000000000000000000803f00000000348e34c3f3fd3bc2d25e9d400000803f0000803ea0c2f53ccdcc4c3d348e34c3f3fd3bc2e1c779401a27a50500000000bc010000010001000100020105000000",
    },
    {
        "300000600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f00000000f3e234c3859136c2abe2a0400000803f0000803e83c2f53ccdcc4c3df3e234c3859136c2fd9a97401a27a50500000000bc010000010000000000020105000000",
        "5c0000600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f00000000aee434c392ce36c2abe2a0400000803f0000803e83c2f53ccdcc4c3daee434c392ce36c2fd9a97401a27a50500000000bc010000010000000000020105000000",
        "880000600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f0000000067e634c3a00b37c2abe2a0400000803f0000803e83c2f53ccdcc4c3d67e634c3a00b37c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "b40000600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f0000000021e834c3ac4837c2abe2a0400000803f0000803e83c2f53ccdcc4c3d21e834c3ac4837c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "e00000600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f00000000dce934c3b98537c2abe2a0400000803f0000803e83c2f53ccdcc4c3ddce934c3b98537c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "0c0100600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f0000000096eb34c3c6c237c2abe2a0400000803f0000803e83c2f53ccdcc4c3d96eb34c3c6c237c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "380100600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f0000000050ed34c3d3ff37c2abe2a0400000803f0000803e83c2f53ccdcc4c3d50ed34c3d3ff37c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "640100600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f000000000aef34c3e03c38c2abe2a0400000803f0000803e83c2f53ccdcc4c3d0aef34c3e03c38c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "900100600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f00000000c4f034c3ed7938c2abe2a0400000803f0000803e83c2f53ccdcc4c3dc4f034c3ed7938c2fd9a97401a27a50500000000bc010000010001000100020105000000",
        "bc0100600000000000000000000000007c607ebfa141e63d0000000000000000a141e6bd7c607ebf000000000000000000000000000000000000803f000000007ef234c3fab638c2abe2a0400000803f0000803e83c2f53ccdcc4c3d7ef234c3fab638c2fd9a97401a27a50500000000bc010000010001000100020105000000",
    },
    {
        "3000006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000a92a34c30ce137c283019d400000803f0000803e96c1f53ccdcc4c3da92a34c30ce137c2430d79401a27a50500000000bc010000010000000000020105000000",
        "5c00006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000633834c3a1fc37c283019d400000803f0000803e96c1f53ccdcc4c3d633834c3a1fc37c2430d79401a27a50500000000bc010000010000000000020105000000",
        "8800006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f000000001c4634c3361838c283019d400000803f0000803e96c1f53ccdcc4c3d1c4634c3361838c2430d79401a27a50500000000bc010000010000000000020105000000",
        "b400006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000d55334c3ca3338c283019d400000803f0000803e96c1f53ccdcc4c3dd55334c3ca3338c2430d79401a27a50500000000bc010000010000000000020105000000",
        "e000006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000906134c3604f38c284019d400000803f0000803e96c1f53ccdcc4c3d906134c3604f38c2450d79401a27a50500000000bc010000010000000000020105000000",
        "0c01006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000496f34c3f56a38c283019d400000803f0000803e96c1f53ccdcc4c3d496f34c3f56a38c2430d79401a27a50500000000bc010000010001000100020105000000",
        "3801006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000027d34c38a8638c283019d400000803f0000803e96c1f53ccdcc4c3d027d34c38a8638c2430d79401a27a50500000000bc010000010001000100020105000000",
        "6401006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000bc8a34c31fa238c283019d400000803f0000803e96c1f53ccdcc4c3dbc8a34c31fa238c2430d79401a27a50500000000bc010000010001000100020105000000",
        "9001006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f00000000759834c3b4bd38c283019d400000803f0000803e96c1f53ccdcc4c3d759834c3b4bd38c2430d79401a27a50500000000bc010000010001000100020105000000",
        "bc01006000000000000000000000000080d8e5be38c1643f000000000000000038c164bf80d8e5be000000800000000000000080000000000000803f000000002fa634c349d938c283019d400000803f0000803e96c1f53ccdcc4c3d2fa634c349d938c2430d79401a27a50500000000bc010000010001000100020105000000",
    },
    {
        "30000060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f00000000357834c3a59938c2fb559d400000803f0000803e50c2f53ccdcc4c3d357834c3a59938c233b679401a27a50500000000bc010000010001000100020105000000",
        "5c000060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f00000000728034c382cd38c2fb559d400000803f0000803e50c2f53ccdcc4c3d728034c382cd38c233b679401a27a50500000000bc010000010001000100020105000000",
        "88000060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f00000000ae8834c35f0139c2fb559d400000803f0000803e50c2f53ccdcc4c3dae8834c35f0139c233b679401a27a50500000000bc010000010001000100020105000000",
        "b4000060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f00000000ea9034c33c3539c2fb559d400000803f0000803e50c2f53ccdcc4c3dea9034c33c3539c233b679401a27a50500000000bc010000010001000100020105000000",
        "e0000060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f00000000269934c31a6939c2fb559d400000803f0000803e50c2f53ccdcc4c3d269934c31a6939c233b679401a27a50500000000bc010000010001000100020105000000",
        "0c010060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f0000000062a134c3f69c39c2fb559d400000803f0000803e50c2f53ccdcc4c3d62a134c3f69c39c233b679401a27a50500000000bc010000010001000100020105000000",
        "38010060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f000000009ea934c3d3d039c2fb559d400000803f0000803e50c2f53ccdcc4c3d9ea934c3d3d039c233b679401a27a50500000000bc010000010001000100020105000000",
        "64010060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f00000000dab134c3b0043ac2fb559d400000803f0000803e50c2f53ccdcc4c3ddab134c3b0043ac233b679401a27a50500000000bc010000010001000100020105000000",
        "90010060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f0000000017ba34c38d383ac2fb559d400000803f0000803e50c2f53ccdcc4c3d17ba34c38d383ac233b679401a27a50500000000bc010000010001000100020105000000",
        "bc010060000000000000000000000000c41858bf9640093f0000000000000000964009bfc41858bf000000000000000000000000000000000000803f0000000053c234c36a6c3ac2fb559d400000803f0000803e50c2f53ccdcc4c3d53c234c36a6c3ac233b679401a27a50500000000bc010000010001000100020105000000",
    },
};

static void Hex(const char* hex, uint8_t* out, size_t size)
{
    for (size_t i = 0; i < size; i++)
    {
        unsigned value = 0;
        for (int j = 0; j < 2; j++)
        {
            char c = hex[i * 2 + j];
            value = value * 16 + (unsigned)(c <= '9' ? c - '0' : c - 'a' + 10);
        }
        out[i] = (uint8_t)value;
    }
}

/* Every geometry field poisoned, only ownership and the query options kept: the reprojection rebuilds the native
 * producer's floats (within 1e-6; the basis within the quaternion round trip's difference). */
static void ReprojectionMatchesTheNativeProducer(void)
{
    static CvVault s;
    static uint8_t fresh[0x2B0];
    Started();
    CHECK_EQ(cv_native_bind(), 1);
    double worst = 0;
    for (int c = 0; c < 4; c++)
    {
        uint8_t originals[10][128];
        const char* why = NULL;
        memset(&s, 0, sizeof s);
        memset(fresh, 0, sizeof fresh);
        P32(fresh + 4, 1);
        P32(fresh + 684, 222);
        for (int i = 0; i < 11; i++) PF(fresh + 488 + i * 4, kGeometry[c][i]);
        memcpy(s.controller_bytes, fresh, sizeof fresh);
        s.hit_count = 10;
        for (int i = 0; i < 10; i++)
        {
            Hex(kRecords[c][i], originals[i], 128);
            s.hits[i].slot = i;
            memcpy(s.hits[i].record, originals[i], 128);
            memset(s.hits[i].record + 16, 0xFF, 88);
        }
        CHECK_EQ(cv_reproject(&s, fresh, &why), 1);
        for (int i = 0; i < 10; i++)
        {
            const uint8_t* r = s.hits[i].record;
            CHECK(memcmp(r, originals[i], 16) == 0 && memcmp(r + 104, originals[i] + 104, 24) == 0);
            for (int o = 16; o <= 100; o += 4)
            {
                double error = fabs(GF(r + o) - GF(originals[i] + o));
                if (error > worst) worst = error;
                if (error >= 0.000001) printf("  slot %d offset %d: %.9g\n", i, o, error);
                CHECK(error < 0.000001);
            }
        }
    }
    printf("  40 captured native descriptors, worst error %.9g\n", worst);
}

/* ---- natives ------------------------------------------------------------------------------------------------------ */

/* windows_api.lua's raised_approach: the native parameter block, the current mover's refresh, private outputs, and
 * invalid geometry that never reaches the native search (test_raised_approach.lua). */
static void RaisedApproachLayout(void)
{
    static uint8_t controller[0x2B0], fresh[0x2B0], before[0x2B0];
    Started();
    CHECK_EQ(cv_native_bind(), 1);
    n.no_ledge = 0;
    const float ledge[8] = {10, 20.4f, 32.4f, 10, 21, 32.4f, 2, 0.3f};
    memcpy(n.ledge, ledge, sizeof ledge);
    n.root[0] = 10;
    n.root[1] = 20;
    n.root[2] = 30;
    P32(controller + 684, 222);
    memcpy(before, controller, sizeof before);
    const double up[3] = {0, 1, 0};
    CvRaisedArgs args = {controller, 444, 123, up, 0.6};
    CHECK(cv_native_raised(&args, fresh) == NULL);
    const uint8_t* block = n.approach_args;
    CHECK_EQ(G32(block), 444);
    CHECK(GF(block + 4) == 10 && GF(block + 8) == 20 && GF(block + 12) == 30);
    CHECK(fabs(GF(block + 16) - 0.3) < 0.00001 && fabs(GF(block + 20) - 1.8) < 0.00001);
    CHECK(GF(block + 24) == 0 && GF(block + 28) == 1 && GF(block + 32) == 0);
    CHECK(GF(block + 36) == 0.5 && GF(block + 40) == 2.5 && fabs(GF(block + 44) - 0.6) < 0.00001);
    CHECK_EQ(G32(fresh + 4), 1);
    CHECK_EQ(G32(fresh + 684), 222);
    CHECK(GF(fresh + 512) == 2 && GF(fresh + 524) == 1);
    CHECK(memcmp(controller, before, sizeof before) == 0);
    n.root[0] = 11;
    CHECK(cv_native_raised(&args, fresh) == NULL);
    CHECK(GF(n.approach_args + 4) == 11);
    n.no_ledge = 1;
    CHECK(Is(cv_native_raised(&args, fresh), "raised_approach_no_ledge"));
    CHECK_EQ(n.approach_calls, 3);
    n.no_ledge = 0;
    const double reaches[4] = {0, -1, 1.6, NAN};
    for (int i = 0; i < 4; i++)
    {
        CvRaisedArgs bad = args;
        bad.reach = reaches[i];
        CHECK(Is(cv_native_raised(&bad, fresh), "unsupported_raised_reach"));
    }
    const double directions[3][3] = {{0, 0, 0}, {0, 1, 0.1}, {0, NAN, 0}};
    for (int i = 0; i < 3; i++)
    {
        CvRaisedArgs bad = args;
        bad.direction = directions[i];
        CHECK(Is(cv_native_raised(&bad, fresh), "unsupported_raised_direction"));
    }
    PF(w.shape + 12, 0.6);
    CHECK(Is(cv_native_raised(&args, fresh), "unsupported_raised_mover"));
    PF(w.shape + 12, 0.3);
    PF(w.shape + 16, 2.5);
    CHECK(Is(cv_native_raised(&args, fresh), "unsupported_raised_mover"));
    CHECK_EQ(n.approach_calls, 3);
}

/* The binding is checked before any call: a table or routine that is not the reviewed one leaves the check waiting. */
static void NativeBindingChecks(void)
{
    static const char* const texts[5] = {"Unsupported native table", "Unsupported native function",
        "Native exit validator changed", "Native vault driver changed", "Native approach geometry routine changed"};
    for (int c = 0; c < 5; c++)
    {
        fake_setup();
        Started();
        if (c == 0) P64(w.game + 0x3326388u, A(w.exe + 0x1000));
        if (c == 1) P64(w.exe + 0x27CDB40u + 0x80, A(w.exe + 0x1000));
        if (c == 2) w.game[0xA9D560u] = 0xCC;
        if (c == 3) w.game[0xA9A0C0u + 15] = 0xCC;
        if (c == 4) w.game[0xA9DD90u] = 0xCC;
        LATE(H(2));
        Fresh();
        const char* reason = Run();
        CHECK(Starts(reason, "waiting_for_game_data: "));
        CHECK(strstr(reason, texts[c]) != NULL);
        CHECK_EQ(n.retries + n.refreshes + n.exit_calls + (int)Stores(), 0);
    }
}

/* ---- the slope assist (test_slope.lua) ---------------------------------------------------------------------------- */

static int g_candidateKind;
static int StubCandidate(int* kind)
{
    *kind = g_candidateKind;
    return g_candidateKind != 0;
}
static int RaisingCandidate(int* kind) { return cv_raise("candidate fixture failure"); }

static uint8_t* Cell(int cell)
{
    if (cell == CV_CAP) return w.cap;
    if (cell == CV_SLOPE) return w.object + 96;
    return w.settings + (cell == CV_ENTER ? 152 : cell == CV_EXIT ? 172 : 260);
}

/* test_slope.lua's reset(): no vault query, the input released, eligible on flat ground, the default settings. */
static void SlopeReset(void)
{
    g_candidateKind = CV_KIND_SLOPE;
    cv_test_candidate(StubCandidate);
    CHECK_EQ(n.bad, 0);
    ResetNatives();
    cv_test_counts()->stores = 0;
    St()->now = 0;
    P32(w.mode + 8, 1);
    P32(w.mode + 0x40, 1);
    P32(w.pm + 0x3A8, 9);
    w.input[0] = 0;
    P32(w.control + 4, 0);
    memset(w.flags, 0, 24);
    P32(w.flags, 2);
    w.move[12] = w.move[15] = 0;
    PV(w.move + 20, 0, 0, 1);
    PF(w.cap, -1);
    uint8_t* records[2] = {w.settings, w.component + 32};
    for (int i = 0; i < 2; i++)
    {
        PF(records[i] + 12, 2);
        PF(records[i] + 152, 45);
        PF(records[i] + 172, 40);
        PF(records[i] + 260, 1.95);
    }
    PF(w.object + 96, cos(50 * PI / 180));
    P64(w.object, A(w.exe + 0x16A16D8u));
    P32(w.overrides + 222 % 16 * 8, 222);
    P32(w.overrides + 222 % 16 * 8 + 4, 1);
    P32(w.avatars + 0x547D20u, 2);
    P32(w.records + 64, 0x80000001u);
    P32(w.records + 72, 444);
    P32(w.entities + 32, 222);
}

static int Step(void)
{
    const char* reason = NULL;
    int accepted = cv_slope_step(St(), &reason);
    CHECK_EQ(accepted, 1);
    return accepted;
}

static void Arm(void)
{
    Step();
    w.input[0] = 1;
    Step();
    CHECK(St()->has_lease);
}

static int Baseline(void)
{
    return GF(Cell(CV_ENTER)) == 45 && GF(Cell(CV_EXIT)) == 40 && GF(Cell(CV_CAP)) == -1 &&
        fabs(GF(Cell(CV_SLOPE)) - cos(50 * PI / 180)) < 0.000001 && fabs(GF(Cell(CV_HEIGHT)) - 1.95) < 0.000001;
}

/* The other avatar, the shared mover definition and the shared settings never change. */
static int SharedUnchanged(void)
{
    return memcmp(w.remote, w.remote_before, sizeof w.remote_before) == 0 && GF(w.component + 32 + 152) == 45 &&
        G32(w.definition) == 123 && fabs(GF(w.definition + 24) - 70 * PI / 180) < 0.000001;
}

static void SlopeLeaseArmsAndRestores(void)
{
    Started();
    for (uint32_t mode = 1; mode <= 7; mode++)
    {
        SlopeReset();
        P32(w.mode + 0x40, mode);
        Fresh();
        Arm();
        CHECK(cv_slope_stop(St()));
        CHECK(Baseline());
    }
    const uint32_t outside[3] = {0, 8, INVALID};
    for (int i = 0; i < 3; i++)
    {
        SlopeReset();
        P32(w.mode + 0x40, outside[i]);
        Fresh();
        Step();
        w.input[0] = 1;
        Step();
        CHECK(!St()->has_lease);
        CHECK_EQ(Stores(), 0);
    }
    SlopeReset();
    Fresh();
    Step();
    CHECK_EQ(Stores(), 0);
    SlopeReset();
    Fresh();
    w.input[0] = 1;
    Step(); /* a press with no release seen first is not a fresh press */
    CHECK(!St()->has_lease);
    CHECK_EQ(Stores(), 0);
    SlopeReset();
    Fresh();
    Arm();
    CHECK(GF(Cell(CV_ENTER)) == 65 && GF(Cell(CV_EXIT)) == 60 && GF(Cell(CV_CAP)) == -1); /* the attempt does not slow */
    CHECK(fabs(GF(Cell(CV_SLOPE)) - cos(65 * PI / 180)) < 0.000001);
    CHECK_EQ(St()->counters.slope_arms, 1);
    CHECK(cv_slope_stop(St()));
    CHECK(Baseline());
    CHECK(SharedUnchanged());
}

static void SlopeLeaseLifecycle(void)
{
    Started();
    SlopeReset();
    Fresh();
    Arm();
    St()->now = 1.26;
    Step();
    CHECK(!St()->has_lease);
    CHECK(Baseline());
    St()->now = 2;
    Step();
    CHECK_EQ(St()->counters.slope_arms, 1); /* the held input does not arm again */
    w.input[0] = 0;
    Step();
    w.input[0] = 1;
    Step();
    CHECK_EQ(St()->counters.slope_arms, 2);
    CHECK(cv_slope_stop(St()));
    /* Climbing: the walking cap; landing on a steep face: support, with no timer; flat ground ends it. */
    SlopeReset();
    Fresh();
    Arm();
    P32(w.flags + 12, 0x200);
    St()->now = 0.5;
    Step();
    CHECK_EQ(St()->counters.slope_climbs, 1);
    CHECK(GF(Cell(CV_CAP)) == 2);
    P32(w.flags + 12, 0);
    PV(w.move + 20, sin(62 * PI / 180), 0, cos(62 * PI / 180));
    St()->now = 1;
    n.root[1] = n.root[2] = 1;
    Step();
    CHECK(Is(St()->slope_status, "support"));
    CHECK_EQ(St()->counters.slope_landings, 1);
    St()->now = 300;
    Step();
    CHECK(St()->has_lease);
    PV(w.move + 20, 0, 0, 1);
    Step();
    St()->now = 300.36;
    Step();
    CHECK(!St()->has_lease);
    CHECK(Baseline());
    /* Past 65 degrees there is no support: unsupported for 0.25 s ends it. */
    SlopeReset();
    Fresh();
    Arm();
    P32(w.flags + 12, 0x200);
    St()->now = 0.5;
    Step();
    P32(w.flags + 12, 0);
    PV(w.move + 20, sin(66 * PI / 180), 0, cos(66 * PI / 180));
    St()->now = 1;
    Step();
    St()->now = 1.26;
    Step();
    CHECK(!St()->has_lease);
    CHECK(Baseline());
    CHECK(SharedUnchanged());
}

static void SlopeLeaseEnds(void)
{
    Started();
    static const char* const releases[7] = {"left_area", "left_area", "climb_timeout", "ineligible", "waiting_for_avatar",
        "waiting_for_avatar", "unsupported"};
    for (int c = 0; c < 7; c++)
    {
        SlopeReset();
        Fresh();
        Arm();
        if (c == 0) n.root[0] = 3.01;
        if (c == 1) n.root[2] = 3.01;
        if (c == 2) { P32(w.flags + 12, 0x200); St()->now = 9; }
        if (c == 3) P32(w.flags, 0x4002);
        if (c == 4) P32(w.mode + 0x40, 0);
        if (c == 5) P32(w.pm + 0x3A8, 0x7FFF);
        if (c == 6)
        {
            /* a stale ground normal does not extend an unsupported lease */
            P32(w.flags + 12, 0x200);
            Step();
            P32(w.flags + 12, 0);
            w.move[12] = 1;
            Step();
            St()->now = 0.26;
        }
        Step();
        CHECK(!St()->has_lease);
        CHECK(Is(St()->slope_last_release, releases[c]));
        CHECK(Baseline());
    }
    /* A lower cap the game already has is respected and left as it was. */
    SlopeReset();
    PF(w.cap, 0.75);
    Fresh();
    Arm();
    CHECK(GF(Cell(CV_CAP)) == 0.75f);
    CHECK(cv_slope_stop(St()));
    CHECK(GF(Cell(CV_CAP)) == 0.75f);
    /* The game changed the cap after it was capped: the lease ends and the game's value stays. */
    SlopeReset();
    Fresh();
    Arm();
    P32(w.flags + 12, 0x200);
    Step();
    PF(w.cap, 0.25);
    Step();
    CHECK(!St()->has_lease);
    CHECK(GF(Cell(CV_CAP)) == 0.25f && GF(Cell(CV_ENTER)) == 45);
    /* The cleanup never writes into a reused entity. */
    SlopeReset();
    Fresh();
    Arm();
    P32(w.entities + 32, 999);
    uint32_t before = Stores();
    CHECK(cv_slope_stop(St()));
    CHECK_EQ(Stores(), before);
    P32(w.entities + 32, 222);
    CHECK(SharedUnchanged());
}

static void SlopeSettingsAndOverride(void)
{
    Started();
    SlopeReset();
    PF(w.settings + 152, 55); /* custom slide settings are left alone */
    Fresh();
    Step();
    w.input[0] = 1;
    Step();
    CHECK(!St()->has_lease);
    CHECK_EQ(Stores(), 0);
    /* No settings record of its own: the game's modifier routine creates one. */
    SlopeReset();
    P32(w.overrides + 222 % 16 * 8, INVALID);
    P32(w.avatars + 0x547D20u, 0);
    Fresh();
    Arm();
    CHECK_EQ(n.overrides, 1);
    CHECK_EQ(St()->counters.slope_overrides, 1);
    CHECK(cv_slope_stop(St()));
    CHECK(Baseline());
    SlopeReset();
    P32(w.overrides + 222 % 16 * 8, INVALID);
    P32(w.avatars + 0x547D20u, 8); /* the game's fixed eight-record capacity */
    Fresh();
    Step();
    w.input[0] = 1;
    Step();
    CHECK_EQ(n.overrides, 0);
    CHECK_EQ(Stores(), 0);
    CHECK(!St()->has_lease);
    for (int c = 0; c < 3; c++)
    {
        SlopeReset();
        if (c == 0) P64(w.object, A(w.exe + 0x16A5010u)); /* another character controller */
        if (c == 1) P32(w.records + 72, 333);            /* the mover of another unit */
        if (c == 2) P32(w.records + 64, 0x80000002u);    /* a reused handle */
        Fresh();
        Step();
        w.input[0] = 1;
        Step();
        CHECK_EQ(Stores(), 0);
    }
    /* Open-space presses and failed searches write nothing, create no override and never slow movement. */
    SlopeReset();
    g_candidateKind = 0;
    P32(w.overrides + 222 % 16 * 8, INVALID);
    P32(w.avatars + 0x547D20u, 0);
    Fresh();
    Step();
    for (int i = 1; i <= 5; i++)
    {
        w.input[0] = 1;
        St()->now = i * 2;
        Step();
        w.input[0] = 0;
        Step();
    }
    CHECK_EQ(Stores() + (uint32_t)n.overrides, 0);
    CHECK(!St()->has_lease);
    CHECK(Baseline());
    /* The window: a candidate found within 1.25 s of the press arms; after it, nothing. */
    SlopeReset();
    g_candidateKind = 0;
    Fresh();
    Step();
    w.input[0] = 1;
    Step();
    St()->now = 0.15;
    g_candidateKind = CV_KIND_SLOPE;
    Step();
    CHECK(St()->has_lease);
    CHECK(GF(Cell(CV_CAP)) == -1);
    CHECK(cv_slope_stop(St()));
    SlopeReset();
    g_candidateKind = 0;
    Fresh();
    Step();
    w.input[0] = 1;
    Step();
    St()->now = 1.3;
    g_candidateKind = CV_KIND_SLOPE;
    Step();
    CHECK_EQ(Stores(), 0);
    CHECK(!St()->has_lease);
    CHECK(SharedUnchanged());
}

/* The ledge assist changes only the ground climb height, and ends once its native climb finishes. */
static void LedgeLease(void)
{
    Started();
    SlopeReset();
    g_candidateKind = CV_KIND_LEDGE;
    Fresh();
    Arm();
    CHECK(GF(Cell(CV_HEIGHT)) == 2.5f && GF(Cell(CV_ENTER)) == 45 && GF(Cell(CV_CAP)) == -1);
    CHECK_EQ(Stores(), 1);
    P32(w.flags + 12, 0x200);
    Step();
    Step();
    CHECK(GF(Cell(CV_CAP)) == -1);
    CHECK_EQ(St()->counters.ledge_climbs, 1);
    P32(w.flags + 12, 0);
    Step();
    CHECK(!St()->has_lease);
    CHECK_EQ(St()->counters.ledge_arms, 1);
    CHECK(Baseline());
    SlopeReset();
    g_candidateKind = CV_KIND_LEDGE;
    Fresh();
    Arm();
    St()->now = 1.3;
    Step();
    CHECK_EQ(St()->counters.ledge_attempt_expiries, 1);
    CHECK_EQ(St()->counters.ledge_climbs, 0);
    CHECK(!St()->has_lease);
    CHECK(Baseline());
    for (int c = 0; c < 2; c++)
    {
        SlopeReset();
        g_candidateKind = CV_KIND_LEDGE;
        if (c == 0) PF(w.settings + 260, 2);
        if (c == 1) w.move[12] = 1;
        Fresh();
        Step();
        w.input[0] = 1;
        Step();
        CHECK_EQ(Stores(), 0);
        CHECK(!St()->has_lease);
    }
}

/* Protection refused: before any store of a region the assist is "changed before commit"; the cap's refusal after
 * native climbing started refuses (and restores every other cell). */
static void SlopeWritesRefused(void)
{
    DWORD old;
    Started();
    SlopeReset();
    Fresh();
    cv_memory_reset();
    VirtualProtect(w.object, 104, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake mover object read-only */
    Step();
    w.input[0] = 1;
    Step();
    VirtualProtect(w.object, 104, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(!St()->has_lease);
    CHECK(Is(St()->slope_last_release, "slope_changed_before_commit"));
    CHECK(Baseline());
    SlopeReset();
    Fresh();
    cv_memory_reset();
    Arm();
    P32(w.flags + 12, 0x200);
    VirtualProtect(w.cap, 4, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake speed cap read-only */
    const char* reason = NULL;
    int accepted = cv_slope_step(St(), &reason);
    VirtualProtect(w.cap, 4, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK_EQ(accepted, 0);
    CHECK(Is(reason, "speed_cap_write_failed"));
    CHECK(!St()->has_lease);
    CHECK(Baseline());
    /* An unreadable cell at the restore: the lease stays for the next try. */
    SlopeReset();
    Fresh();
    Arm();
    fake_hole(A(Cell(CV_SLOPE)), 4);
    CHECK(!cv_slope_stop(St()));
    CHECK(St()->has_lease);
}

/* The kept identity of released-input checks: a registry slot that no longer points at the avatar, or a changed
 * entity record, resolves the whole chain again in the same check; a press after kept checks still arms. */
static void KeptIdentity(void)
{
    Started();
    SlopeReset();
    Fresh();
    Step();
    Step();
    CHECK(Is(St()->slope_status, "waiting_for_manual_climb"));
    P64(w.avatars + 0x118, A(w.entities));
    Step();
    CHECK(Is(St()->slope_status, "waiting_for_slope_data"));
    P64(w.avatars + 0x118, A(w.entities + 24));
    Step();
    Step();
    CHECK(Is(St()->slope_status, "waiting_for_manual_climb"));
    P32(w.entities + 32, 999);
    Step();
    CHECK(Is(St()->slope_status, "waiting_for_avatar"));
    P32(w.entities + 32, 222);
    Step();
    Step();
    CHECK(Is(St()->slope_status, "waiting_for_manual_climb"));
    P32(w.pm + 0x3A8, 10); /* another unit reference */
    Step();
    CHECK(Is(St()->slope_status, "waiting_for_avatar"));
    P32(w.pm + 0x3A8, 9);
    Step();
    Step();
    w.input[0] = 1;
    Step();
    CHECK(St()->has_lease);
    CHECK(cv_slope_stop(St()));
    CHECK(Baseline());
    /* A new identity found while the input is held is not a fresh press; released and pressed again, it arms. */
    uint8_t* moved = w.entities + 48;
    SlopeReset();
    Fresh();
    Step();
    Step();
    memcpy(moved, w.entities + 24, 24);
    P32(w.unitrows + 9 % 16 * 8 + 4, 2);
    P64(w.avatars + 0x118, A(moved));
    w.input[0] = 1;
    Step();
    CHECK(!St()->has_lease);
    CHECK_EQ(St()->slope_down, 1);
    w.input[0] = 0;
    Step();
    w.input[0] = 1;
    Step();
    CHECK(St()->has_lease);
    CHECK(cv_slope_stop(St()));
    CHECK(Baseline());
    P32(w.unitrows + 9 % 16 * 8 + 4, 1);
    P64(w.avatars + 0x118, A(w.entities + 24));
    memset(moved, 0, 24);
    /* The same entity's override relocated: the restore finds its new row. */
    SlopeReset();
    Fresh();
    Arm();
    memcpy(w.avatars + 0x547D24u + 2 * 852, w.settings, 852);
    P32(w.overrides + 222 % 16 * 8 + 4, 2);
    CHECK(cv_slope_stop(St()));
    CHECK(GF(w.avatars + 0x547D24u + 2 * 852 + 152) == 45 && GF(w.avatars + 0x547D24u + 2 * 852 + 172) == 40);
    P32(w.overrides + 222 % 16 * 8 + 4, 1);
    CHECK(SharedUnchanged());
}

/* ---- per-check and per-frame calls (the Lua's frame_budget pins) ------------------------------------------------- */

typedef struct Pinned { uint32_t reads, queries, stores, code; const char* reason; } Pinned;

/* One check (M.apply with the slope assist) and its calls. */
static Pinned Check(void)
{
    Pinned p;
    fake_counts_reset();
    cv_test_counts()->queries = cv_test_counts()->stores = 0;
    p.reason = NULL;
    (void)cv_check(St(), &p.reason);
    p.reads = fake_counts().read;
    p.code = fake_counts().code_matches;
    p.queries = cv_test_counts()->queries;
    p.stores = cv_test_counts()->stores;
    return p;
}

/* The vault check alone (test_vault.lua's budget) and its calls. */
static Pinned VaultCheck(void)
{
    Pinned p;
    fake_counts_reset();
    cv_test_counts()->queries = cv_test_counts()->stores = 0;
    p.reason = Run();
    p.reads = fake_counts().read;
    p.code = fake_counts().code_matches;
    p.queries = cv_test_counts()->queries;
    p.stores = cv_test_counts()->stores;
    return p;
}

#define PIN(p, text, reads_, queries_) do { Pinned p_ = (p); CHECK(Is(p_.reason, text)); CHECK_EQ(p_.reads, reads_); \
    CHECK_EQ(p_.queries, queries_); } while (0)

/* Vault-only checks. The Lua (read + read_into, its ReadProcessMemory calls; writable_data) in each comment. */
static void VaultCallBudget(void)
{
    Started();
    RESET();
    P32(w.mode + 8, 0);
    Fresh();
    PIN(VaultCheck(), "waiting_for_mission", 1, 0); /* Lua 2 */
    P32(w.mode + 8, 1);
    RESET();
    P32(w.control + 4, 0);
    PIN(VaultCheck(), "waiting_for_vault_query", 15, 0); /* Lua 19 */
    RESET(H(2), H(1));
    w.input[0] = 0;
    PIN(VaultCheck(), "waiting_for_manual_vault", 18, 0); /* Lua 22 */
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    Fresh();
    PIN(VaultCheck(), "local_manual_alternative_prepared", 161, 1); /* Lua 178, 1 */
    PIN(VaultCheck(), "local_manual_alternative_prepared", 86, 0);  /* Lua 94: kept, no second guard read */
    w.input[0] = 0;
    PIN(VaultCheck(), "waiting_for_manual_vault", 41, 0); /* Lua 48, 1: restored (the controller is checked once) */
    CHECK(!St()->has_pending);
    LATE(H(2), H(1));
    n.flags[2] = 0x100000;
    Pinned late = VaultCheck();
    PIN(late, "native_local_vault_started", 203, 0); /* Lua 236, 2 */
    LATE(HN(0.5));
    fake_counts_reset();
    CHECK_EQ(Candidate(NULL), CV_KIND_SLOPE);
    CHECK_EQ(fake_counts().read, 113); /* Lua 127 */
}

static void SlopeCallBudget(void)
{
    Started();
    SlopeReset();
    P32(w.mode + 8, 0);
    Fresh();
    PIN(Check(), "waiting_for_mission", 1, 0); /* Lua 2 */
    P32(w.mode + 8, 1);
    SlopeReset();
    Fresh();
    (void)Check();
    /* The slope check verifies its kept identity (the input, the mission, the unit reference, the entity record and
     * the registry slot); the vault check reads only the phase word of that avatar. */
    PIN(Check(), "waiting_for_vault_query", 6, 0); /* Lua 7 */
    P32(w.control + 4, 3);
    PIN(Check(), "waiting_for_manual_vault", 6, 0); /* Lua 7 */
    P32(w.control + 4, 0);
    SlopeReset();
    w.input[0] = 1;
    Fresh();
    (void)Check();
    PIN(Check(), "waiting_for_vault_query", 40, 0); /* Lua 45: input held, no new press */
    P32(w.control + 4, 3);
    P64(w.avatars + 0x28, 0);
    PIN(Check(), "waiting_for_game_data: Game pointer unavailable", 47, 0); /* Lua 52: the vault snapshot reuses the chain */
    P64(w.avatars + 0x28, A(w.queries));
    P32(w.control + 4, 0);
    SlopeReset();
    Fresh();
    (void)Check();
    w.input[0] = 1;
    Pinned armed = Check();
    PIN(armed, "waiting_for_vault_query", 140, 2); /* Lua 163, 2 */
    CHECK_EQ(armed.stores, 3);
    CHECK(St()->has_lease);
    PIN(Check(), "waiting_for_vault_query", 39, 0); /* Lua 44: held */
    P32(w.flags + 12, 0x200);
    St()->now = 0.5;
    PIN(Check(), "waiting_for_vault_query", 70, 1); /* Lua 81, 1: climbing, the speed cap */
    PIN(Check(), "waiting_for_vault_query", 39, 0); /* Lua 44: climb held */
    P32(w.flags, 0x4002);
    Pinned released = Check();
    PIN(released, "waiting_for_vault_query", 101, 0); /* Lua 114, 3: released, every span already checked */
    CHECK_EQ(released.stores, 4);
    CHECK(!St()->has_lease);
    CHECK(Baseline());
}

/* Runs frames until one makes a full check; that frame's calls. */
static FakeCounts FullCheck(void)
{
    for (int i = 0; i < 60; i++)
    {
        uint32_t polls = St()->counters.polls;
        fake_counts_reset();
        fake_frames(1, 1.0f / 60);
        if (St()->counters.polls > polls) return fake_counts();
    }
    FakeCounts none;
    memset(&none, 0, sizeof none);
    CHECK(0); /* no full check within 60 frames */
    return none;
}

static uint32_t FrameReads(void)
{
    fake_counts_reset();
    fake_frames(1, 1.0f / 60);
    return fake_counts().read + fake_counts().log + fake_counts().code_matches;
}

/* The idle gate: one read on 9 of 10 idle mission frames (6 on the 10th), none on 59 of 60 frames outside a mission
 * (1 on the 60th); a press arms on the frame it is seen. */
static void FrameBudgetWithTheGate(void)
{
    Started();
    SlopeReset();
    P32(w.mode + 8, 0);
    FullCheck();
    FullCheck();
    int gated = 1;
    for (int i = 0; i < 59; i++) gated &= FrameReads() == 0;
    CHECK(gated);
    uint32_t polls = St()->counters.polls;
    CHECK_EQ(FrameReads(), 1); /* Lua 2 */
    CHECK_EQ(St()->counters.polls, polls + 1);
    P32(w.mode + 8, 1);
    FullCheck();
    FullCheck();
    gated = 1;
    for (int i = 0; i < 9; i++) gated &= FrameReads() == 1;
    CHECK(gated);
    CHECK_EQ(FrameReads(), 6); /* Lua 7 */
    /* A press on a gated frame: the gate's read, the check that arms, the check replayed now that work started, and the
     * second check (after the game's update; here, without the frame hook, right after the others). */
    FullCheck();
    CHECK_EQ(FrameReads(), 1);
    w.input[0] = 1;
    polls = St()->counters.polls;
    fake_counts_reset();
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(St()->counters.polls, polls + 3); /* Lua 3 */
    CHECK(St()->has_lease);
    CHECK_EQ(St()->counters.slope_arms, 1);
    CHECK_EQ(fake_counts().read, 219); /* Lua 252 over its three checks */
    w.input[0] = 0;
    St()->now += 2;
    fake_frames(3, 1.0f / 60);
    CHECK(!St()->has_lease);
    CHECK(Baseline());
}

/* The local avatar's index changes right after a full check: the gate reads the old index until the next full check,
 * so a tap that ends before it is missed, a held press is seen there (as a held press). */
static void Compact(int on)
{
    uint8_t* in0 = w.avatars + 0x150 + 0x1B68 + 14 * 32;
    P32(w.avatarrows + 222 % 16 * 8 + 4, on ? 0 : 1);
    P32(w.avatarrows + 111 % 16 * 8 + 4, on ? 1 : 0);
    P64(w.avatars + 0x110, A(w.entities + (on ? 24 : 0)));
    P64(w.avatars + 0x118, A(w.entities + (on ? 0 : 24)));
    P32(w.avatars + 0x53E1B8u + 0x2AC, on ? 222 : 0);
    P32(w.avatars + 0x53E134u + 40, on ? 222 : 0);
    if (!on) in0[0] = 0;
}

static void GateFollowsANewIndex(void)
{
    Started();
    SlopeReset();
    uint8_t* in0 = w.avatars + 0x150 + 0x1B68 + 14 * 32;
    FullCheck();
    FullCheck();
    Compact(1);
    uint32_t polls = St()->counters.polls;
    in0[0] = 1;
    fake_frames(3, 1.0f / 60);
    in0[0] = 0;
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(St()->counters.polls, polls);
    CHECK_EQ(St()->slope_down, 0);
    in0[0] = 1;
    int seen = 0;
    for (int i = 1; i <= 10 && !seen; i++)
    {
        fake_frames(1, 1.0f / 60);
        if (St()->slope_down == 1) seen = i;
    }
    CHECK_EQ(seen, 6);
    CHECK(!St()->has_lease);
    in0[0] = 0;
    FullCheck();
    fake_frames(1, 1.0f / 60);
    polls = St()->counters.polls;
    in0[0] = 1;
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(St()->counters.polls, polls + 1);
    CHECK_EQ(St()->slope_down, 1);
    Compact(0);
    w.input[0] = 0;
    fake_frames(20, 1.0f / 60);
    CHECK_EQ(St()->slope_down, 0);
    CHECK(!St()->has_lease);
    CHECK(Baseline());
}

/* ---- the tick (test_loader.lua) ------------------------------------------------------------------------------------ */

/* One check per idle frame; two per busy frame, the second after the game's update (without the frame hook, right after
 * the first, where the Lua made it); three on the frame work starts (the replayed one). test_loader.lua's counts. */
static void ChecksPerFrame(void)
{
    Started();
    SlopeReset();
    fake_frames(2, 1.0f / 60);
    uint32_t polls = St()->counters.polls;
    CHECK(!vpm_post_ticking(fake_component(0)));
    w.input[0] = 1;
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(St()->counters.polls, polls + 3); /* the replayed check on the frame work starts, and the second */
    CHECK(vpm_post_ticking(fake_component(0)));
    polls = St()->counters.polls;
    fake_frames(10, 1.0f / 60);
    CHECK(St()->has_lease);
    CHECK_EQ(St()->counters.polls, polls + 20);
    /* Released and the attempt over: the check that ends the lease leaves nothing in progress, so it is the frame's only
     * one and the post-update tick goes; the next frame's check arms the gate, which answers the frames after it. */
    w.input[0] = 0;
    St()->now += 2;
    polls = St()->counters.polls;
    fake_frames(1, 1.0f / 60);
    CHECK(!St()->has_lease && St()->busy == 0);
    CHECK_EQ(St()->counters.polls, polls + 1);
    CHECK(!vpm_post_ticking(fake_component(0)));
    fake_frames(9, 1.0f / 60);
    CHECK_EQ(St()->counters.polls, polls + 2);
    CHECK_LOG("[Consistent Vaulting] waiting_for_mission");
    CHECK(Is(vpm_status(fake_component(0)), "waiting_for_vault_query"));
    CHECK(Baseline());
}

/* ---- the second check after game.dll's update (the core's frame hook) ---------------------------------------------- */

static void (*g_inUpdate)(void); /* what the game's update changes, on the next engine frame only */
static uint32_t g_pollsInUpdate; /* the checks made when the game's update ran */
static float g_capInUpdate;      /* the speed cap the game's update saw */
static int g_hasPendingInUpdate;

/* The game's own update (fake_after_tick's step, inside game.dll's frame update): it notes what the frame's checks
 * before it had done, then makes the change the test put up. */
static void GameUpdate(float dt)
{
    g_pollsInUpdate = St()->counters.polls;
    g_capInUpdate = GF(Cell(CV_CAP));
    g_hasPendingInUpdate = St()->has_pending;
    void (*change)(void) = g_inUpdate;
    g_inUpdate = NULL;
    if (change != NULL) change();
}

/* hooked: game.dll's frame update decoded, so the core's frame hook goes in at the load and the post-update tick runs
 * after the game's update; otherwise the fallback, with both ticks in HellForge's callback before it. */
static void StartedEngine(int hooked)
{
    fake_frame_update(hooked);
    Started();
    CHECK_EQ(vpm_frame_hooked(), hooked ? 1 : 0);
    fake_after_tick(GameUpdate);
    g_inUpdate = NULL;
}

/* One engine frame whose game update makes this change; the checks it made. */
static uint32_t EngineFrame(void (*change)(void))
{
    uint32_t polls = St()->counters.polls;
    g_inUpdate = change;
    fake_engine_frames(1, 1.0f / 60);
    return St()->counters.polls - polls;
}

static void CompleteBatch(void) { P32(w.control + 4, 2); }
static void StartClimb(void) { P32(w.flags + 12, 0x200); }
static void FaultNext(void) { n.fault = 1; }

/* A press opens the assist's search window (work in progress, no assist found) while the vault's queries are still in
 * flight (stage 1); the batch whose first hit fails is ready. */
static void PressWithQueriesInFlight(void)
{
    SlopeReset();
    g_candidateKind = 0;
    fake_engine_frames(2, 1.0f / 60);
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    P32(w.control + 4, 1);
    CHECK_EQ(EngineFrame(NULL), 3); /* the press, the replay (work started), the second */
    CHECK(St()->has_intent && St()->busy == 1 && !St()->has_pending);
}

/* The game's update completes the batch (stage 2). Hooked, the second check sees it after that update and prepares
 * the alternative in the same frame; in the fallback it ran before the update, and the next frame's first check
 * prepares it, also before the next update. */
static void StageReachedInTheUpdate(void)
{
    for (int hooked = 1; hooked >= 0; hooked--)
    {
        fake_setup();
        StartedEngine(hooked);
        PressWithQueriesInFlight();
        CHECK_EQ(EngineFrame(CompleteBatch), 2);
        CHECK_EQ(St()->has_pending, hooked);
        CHECK_EQ(Unit(0), hooked ? 0u : 444u);
        CHECK(Is(vpm_status(fake_component(0)), hooked ? "local_manual_alternative_prepared" : "waiting_for_vault_query"));
        CHECK_EQ(EngineFrame(NULL), 2);
        CHECK(g_hasPendingInUpdate); /* in place when the next update consumes the batch, either way */
        CHECK(St()->has_pending && Unit(0) == 0 && Unit(1) == 444);
        CHECK(Is(vpm_status(fake_component(0)), "local_manual_alternative_prepared"));
        /* Released: the first check restores and leaves nothing in progress, so the post-update tick goes at once; the
         * gate answers the next frame. */
        w.input[0] = 0;
        CHECK_EQ(EngineFrame(NULL), 1);
        CHECK(!St()->has_pending && Unit(0) == 444 && St()->busy == 0);
        CHECK(!vpm_post_ticking(fake_component(0)));
        CHECK_EQ(EngineFrame(NULL), 0);
        CHECK(RemoteUnchanged());
    }
}

/* An armed slope lease; the game's update starts the native climb. Hooked, the second check caps the speed after that
 * update, in the same frame; in the fallback the next frame's first check caps it. Either way before the next update. */
static void ArmedLease(void)
{
    SlopeReset();
    fake_engine_frames(2, 1.0f / 60);
    w.input[0] = 1;
    CHECK_EQ(EngineFrame(NULL), 3);
    CHECK(St()->has_lease && GF(Cell(CV_ENTER)) == 65 && GF(Cell(CV_CAP)) == -1);
}

static void ClimbStartedInTheUpdate(void)
{
    for (int hooked = 1; hooked >= 0; hooked--)
    {
        fake_setup();
        StartedEngine(hooked);
        ArmedLease();
        CHECK_EQ(EngineFrame(StartClimb), 2);
        CHECK(g_capInUpdate == -1);
        CHECK(GF(Cell(CV_CAP)) == (hooked ? 2 : -1));
        CHECK_EQ(St()->counters.slope_climbs, (uint32_t)hooked);
        CHECK_EQ(EngineFrame(NULL), 2);
        CHECK(g_capInUpdate == 2);
        CHECK(GF(Cell(CV_CAP)) == 2 && St()->counters.slope_climbs == 1 && Is(St()->slope_status, "climb"));
        vpm_core_stop(fake_component(0), "test");
        CHECK(Baseline());
    }
}

/* The frame's own native retry starts the climb under the armed lease: the speed is capped by a second check at once,
 * before the game's update (where the Lua's second check capped it), and the post-update check still follows. */
static void ClimbFromTheChecksOwnRetry(void)
{
    StartedEngine(1);
    ArmedLease();
    LATE(H(2), H(1));
    n.flags[2] = 0x100000;
    CHECK_EQ(EngineFrame(NULL), 3);
    CHECK_EQ(St()->counters.native_starts, 1);
    CHECK(g_capInUpdate == 2);       /* capped before the game's update */
    CHECK_EQ(g_pollsInUpdate, St()->counters.polls - 1);
    CHECK(GF(Cell(CV_CAP)) == 2 && Is(St()->slope_status, "climb"));
    CHECK_EQ(EngineFrame(NULL), 2);  /* the climb held: two checks */
    /* A retry that starts no climb (rejected) is no reason for a check at once. */
    fake_setup();
    StartedEngine(1);
    ArmedLease();
    LATE(H(2), H(1));
    n.flags[2] = 0x100000;
    n.reject = 1;
    CHECK_EQ(EngineFrame(NULL), 2);
    CHECK_EQ(St()->counters.native_starts, 0);
    CHECK(GF(Cell(CV_CAP)) == -1);
    vpm_core_stop(fake_component(0), "test");
    CHECK(Baseline());
}

/* A check that raised restores and starts fresh; the frame's second check runs at once from that fresh start, before
 * the game's update, as the Lua's did, and that frame has no post-update check: two checks, as the Lua's. */
static void ARaisedCheckHasItsSecondAtOnce(void)
{
    StartedEngine(1);
    SlopeReset();
    g_candidateKind = 0;
    fake_engine_frames(2, 1.0f / 60);
    w.input[0] = 1;
    CHECK_EQ(EngineFrame(NULL), 3);
    CHECK(St()->has_intent && vpm_post_ticking(fake_component(0)));
    cv_test_candidate(RaisingCandidate);
    St()->now += 0.2; /* the search window's next candidate check is due */
    uint32_t polls = St()->counters.polls;
    CHECK_EQ(EngineFrame(NULL), 2);
    CHECK_EQ(g_pollsInUpdate, polls + 2); /* both before the game's update */
    CHECK_LOG("[Consistent Vaulting] error: candidate fixture failure");
    CHECK(vpm_running(fake_component(0)) && !vpm_post_ticking(fake_component(0)));
    CHECK(!St()->has_intent && St()->busy == 0 && Baseline());
    CHECK_EQ(EngineFrame(NULL), 1); /* nothing in progress: one check */
}

/* Idle frames with the frame hook are what they were: no post-update tick, the gate's reads only. */
static void IdleFramesHaveNoPostCheck(void)
{
    StartedEngine(1);
    SlopeReset();
    P32(w.mode + 8, 0);
    uint32_t hooks = (uint32_t)fake_hook_count();
    for (int i = 0; i < 3; i++) EngineFrame(NULL);
    int gated = 1, frames = 0;
    uint32_t polls = St()->counters.polls;
    for (int i = 0; i < 120; i++)
    {
        fake_counts_reset();
        fake_engine_frames(1, 1.0f / 60);
        uint32_t calls = fake_counts().read + fake_counts().log + fake_counts().code_matches + fake_counts().hook;
        frames += calls == 0;
        gated &= calls <= 1 && !vpm_post_ticking(fake_component(0));
    }
    CHECK(gated);
    CHECK_EQ(frames, 118);                     /* outside a mission: one frame in 60 reads the mission */
    CHECK_EQ(St()->counters.polls, polls + 2);
    P32(w.mode + 8, 1);
    for (int i = 0; i < 60; i++) EngineFrame(NULL);
    polls = St()->counters.polls;
    uint32_t reads = 0;
    for (int i = 0; i < 10; i++)
    {
        fake_counts_reset();
        fake_engine_frames(1, 1.0f / 60);
        reads += fake_counts().read;
        CHECK(!vpm_post_ticking(fake_component(0)));
    }
    CHECK_EQ(reads, 9 + 6);                    /* in a mission: 1 read on 9 frames, 6 on the 10th, as before */
    CHECK_EQ(St()->counters.polls, polls + 1);
    CHECK_EQ(fake_hook_count(), (int)hooks);   /* nothing hooked or registered beyond the frame hook */
}

/* The per-frame counts with the frame hook: a held lease makes two checks, 78 reads (one check before: 39; the Lua
 * 2 x 44 = 88); the post-update tick goes when the lease ends, and with the component. */
static void PostCheckCountsAndStops(void)
{
    StartedEngine(1);
    ArmedLease();
    fake_counts_reset();
    CHECK_EQ(EngineFrame(NULL), 2);
    CHECK_EQ(fake_counts().read, 78);
    CHECK_EQ(fake_counts().write + fake_counts().log, 0);
    CHECK(vpm_post_ticking(fake_component(0)));
    /* The attempt ends (timeout): that frame's first check ends the lease and leaves nothing in progress. */
    w.input[0] = 0;
    St()->now += 2;
    CHECK_EQ(EngineFrame(NULL), 1);
    CHECK(!St()->has_lease && Baseline() && !vpm_post_ticking(fake_component(0)));
    CHECK(Is(St()->slope_last_release, "attempt_timeout"));
    /* Stopped while busy: the post-update tick goes with the tick, and no check runs any more. */
    fake_setup();
    StartedEngine(1);
    ArmedLease();
    vpm_core_stop(fake_component(0), "test");
    CHECK(!vpm_post_ticking(fake_component(0)) && Baseline());
    CHECK_EQ(EngineFrame(StartClimb), 0);
    CHECK(GF(Cell(CV_CAP)) == -1);
}

/* A fault in the post-update check (a game function it calls) stops the component; its stop puts the lease back. The
 * frame's first check, before the update, ran clean. */
static void AFaultInThePostCheck(void)
{
    StartedEngine(1);
    ArmedLease();
    CHECK_EQ(EngineFrame(FaultNext), 2);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Consistent Vaulting] disabled: fault 0xC0000005");
    CHECK_NO_LOG("its stop did not finish");
    CHECK(!St()->has_lease && Baseline());
    CHECK_EQ(EngineFrame(StartClimb), 0);
    CHECK(SharedUnchanged());
}

/* The check's own errors restore and start fresh, one log line per burst; 8 in a burst stop the component, and a
 * burst ends after 3600 clean frames. */
static void OwnErrorsBurst(void)
{
    Started();
    SlopeReset();
    cv_test_candidate(RaisingCandidate);
    fake_frames(2, 1.0f / 60);
    for (int i = 0; i < 7; i++)
    {
        /* The check raises and starts fresh (state.busy unset), so the second check runs, from that fresh start, as the
         * Lua's after the update did: the held input is no fresh press there, and nothing is in progress after it. */
        w.input[0] = 1;
        uint32_t polls = St()->counters.polls;
        fake_frames(1, 1.0f / 60);
        CHECK_EQ(St()->counters.polls, polls + 2);
        CHECK_EQ(St()->busy, 0);
        CHECK(!St()->has_lease && !St()->has_intent);
        w.input[0] = 0;
        fake_frames(1, 1.0f / 60);
    }
    CHECK(vpm_running(fake_component(0)));
    CHECK_EQ(fake_log_count("error: candidate fixture failure"), 1); /* one line per burst */
    fake_frames(3600, 1.0f / 60);
    for (int i = 0; i < 7; i++)
    {
        w.input[0] = 1;
        fake_frames(1, 1.0f / 60);
        w.input[0] = 0;
        fake_frames(1, 1.0f / 60);
    }
    CHECK(vpm_running(fake_component(0)));
    w.input[0] = 1;
    fake_frames(1, 1.0f / 60);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: stopped after 8 errors: candidate fixture failure");
}

/* A refusal stops the component; the core's stop puts back an armed assist. */
static void RefusalAndStop(void)
{
    Started();
    SlopeReset();
    g_candidateKind = 0;
    RESET(H(2), H(1));
    n.flags[2] = 0x100000;
    n.speed[2] = NAN;
    w.input[0] = 1;
    fake_frames(3, 1.0f / 60);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: validation_failed: Invalid actor motion");
    fake_setup();
    Started();
    SlopeReset();
    fake_frames(2, 1.0f / 60);
    w.input[0] = 1;
    fake_frames(1, 1.0f / 60);
    CHECK(St()->has_lease);
    CHECK(GF(Cell(CV_ENTER)) == 65);
    vpm_core_stop(fake_component(0), "test");
    CHECK(Baseline());
    CHECK(!St()->has_lease);
}

int main(void)
{
    RUN(VaultMissionModes);
    RUN(VaultAlternatives);
    RUN(VaultHitChecks);
    RUN(VaultRefusesForeignData);
    RUN(VaultHeldWrites);
    RUN(VaultCommitChecks);
    RUN(LateRetry);
    RUN(LateRetryGates);
    RUN(LateReprojected);
    RUN(LateUnsupportedApproach);
    RUN(LateStepReport);
    RUN(DiscoveryRebuildsReusedSlots);
    RUN(DiscoveryNeedsAFreshApproach);
    RUN(RaisedSearchFindsHigherTops);
    RUN(OrdinaryCandidates);
    RUN(LedgeCandidates);
    RUN(ReprojectionMatchesTheNativeProducer);
    RUN(RaisedApproachLayout);
    RUN(NativeBindingChecks);
    RUN(SlopeLeaseArmsAndRestores);
    RUN(SlopeLeaseLifecycle);
    RUN(SlopeLeaseEnds);
    RUN(SlopeSettingsAndOverride);
    RUN(LedgeLease);
    RUN(SlopeWritesRefused);
    RUN(KeptIdentity);
    RUN(VaultCallBudget);
    RUN(SlopeCallBudget);
    RUN(FrameBudgetWithTheGate);
    RUN(GateFollowsANewIndex);
    RUN(ChecksPerFrame);
    RUN(StageReachedInTheUpdate);
    RUN(ClimbStartedInTheUpdate);
    RUN(ClimbFromTheChecksOwnRetry);
    RUN(ARaisedCheckHasItsSecondAtOnce);
    RUN(IdleFramesHaveNoPostCheck);
    RUN(PostCheckCountsAndStops);
    RUN(AFaultInThePostCheck);
    RUN(OwnErrorsBurst);
    RUN(RefusalAndStop);
    TEST_END();
}
