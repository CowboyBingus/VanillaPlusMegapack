/* Consistent Vaulting: the game functions (windows_api.lua api.native), called on the game thread through C function
 * pointers. The binding is checked once per session before any call, as the Lua did: three of the game's own function
 * tables (game.dll globals pointing into the exe) must hold the reviewed entries, and three routines must start with
 * the reviewed bytes (vpm_game_code_matches: the bytes as shipped). Every buffer a game function writes is private and
 * 16-byte aligned (the game's SIMD loads); every output it fills is read back from those buffers only. */
#include <math.h>
#include <string.h>
#include "cv.h"
#include "cv_native.h"

typedef struct Binding { uint32_t global, table, offsets[3], functions[3]; } Binding;
static const Binding kBindings[] = {
    {0x3326338u, 0x27CD910u, {0x18u, 0x38u, 0xA8u}, {0x7972F0u, 0x7993D0u, 0x799540u}},
    {0x3326388u, 0x27CDC30u, {0x00u, 0x28u, 0x68u}, {0x7CE220u, 0x7CF050u, 0x7CFE10u}},
    {0x3326328u, 0x27CDB40u, {0x00u, 0x68u, 0x80u}, {0x79F860u, 0x77DEC0u, 0x7F9070u}},
};

static CvNativeFns g_fns;
static int g_bound;
#ifdef VPM_TEST
static const CvNativeFns* g_test;
void cv_native_test(const CvNativeFns* fns) { g_test = fns; }
#endif

/* Private, aligned buffers the game functions write into (the Lua's aligned() allocations, reused). */
static _Alignas(16) float g_matrix[16];
static _Alignas(16) float g_quaternion[4];
static _Alignas(16) uint8_t g_copy[CV_CONTROLLER_SIZE];
static _Alignas(16) uint8_t g_record[CV_RECORD_SIZE];
static _Alignas(16) uint8_t g_out[48];
static _Alignas(16) uint64_t g_descriptor[7];
static uint8_t g_probe[20];

void cv_native_reset(void)
{
    memset(&g_fns, 0, sizeof g_fns);
    g_bound = 0;
}

static int PointerAt(uintptr_t address, uintptr_t* out)
{
    uint8_t bytes[8];
    return cv_load(address, bytes, 8) && cv_pointer(bytes, out) ? 1 : cv_raise("Native binding unavailable");
}

/* The game's function tables: each global points at the reviewed table in the exe, each entry at the reviewed function. */
static int CheckTables(void)
{
    for (size_t b = 0; b < sizeof kBindings / sizeof kBindings[0]; b++)
    {
        const Binding* binding = &kBindings[b];
        uintptr_t table, function;
        CV_TRY(PointerAt(vpm_game() + binding->global, &table));
        if (table - vpm_exe() != binding->table) return cv_raise("Unsupported native table");
        for (int e = 0; e < 3; e++)
        {
            CV_TRY(PointerAt(table + binding->offsets[e], &function));
            if (function - vpm_exe() != binding->functions[e]) return cv_raise("Unsupported native function");
        }
    }
    return 1;
}

static void Resolve(void)
{
    uintptr_t exe = vpm_exe(), game = vpm_game();
    g_fns.valid = (uint64_t (*)(uint32_t))(exe + 0x7972F0u);
    g_fns.flags = (uint32_t (*)(uint32_t))(exe + 0x7993D0u);
    g_fns.motion = (void (*)(uint32_t, float*, float*))(exe + 0x799540u);
    g_fns.mover = (uint32_t (*)(uint32_t, uint32_t))(exe + 0x7CE220u);
    g_fns.dimensions = (void* (*)(uint32_t))(exe + 0x7CFE10u);
    g_fns.position = (void (*)(uint32_t, float*))(exe + 0x7CF050u);
    g_fns.basis = (void* (*)(void*, const float*, const float*))(game + 0x173F150u);
    g_fns.rotation = (void (*)(float*, const void*))(game + 0x173A750u);
    g_fns.classify = (int32_t (*)(void*, const void*, const float*, const float*))(game + 0xA9D560u);
    g_fns.world_id = (uint32_t (*)(const void*))(exe + 0x79F860u);
    g_fns.query = (uint32_t (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, const void*, void*, uint32_t))(exe + 0x7F9070u);
    g_fns.drive = (void (*)(void*, float))(game + 0xA9A0C0u);
    g_fns.detect = (uint32_t (*)(void*, float))(game + 0xA9C3E0u);
    g_fns.approach = (uint8_t (*)(void*, const void*, float*, float*, float*, float*))(game + 0xA9DD90u);
    g_fns.override = (void (*)(void*, const void*, const void*))(game + 0x83C420u);
#ifdef VPM_TEST
    if (g_test != NULL) g_fns = *g_test;
#endif
}

int cv_native_bind(void)
{
    if (g_bound) return 1;
    CV_TRY(CheckTables());
    if (!vpm_game_code_matches(0xA9D560u, "48 8B C4 48 89 58 08 48 89 68 20 56")) return cv_raise("Native exit validator changed");
    if (!vpm_game_code_matches(0xA9A0C0u, "40 55 53 56 57 41 54 41 56 41 57 48 8D 6C 24 D0"))
        return cv_raise("Native vault driver changed");
    if (!vpm_game_code_matches(0xA9DD90u, "48 8B C4 48 89 58 08 55 56 57 41 54 41 55 41 56"))
        return cv_raise("Native approach geometry routine changed");
    Resolve();
    g_bound = 1;
    return 1;
}

static void ToFloats(const double* in, float* out)
{
    out[0] = (float)in[0];
    out[1] = (float)in[1];
    out[2] = (float)in[2];
    out[3] = 0;
}

int cv_native_actor(uint32_t id, CvActor* out)
{
    memset(out, 0, sizeof *out);
    if (id == CV_INVALID || g_fns.valid(id) == 0) return 1;
    _Alignas(16) float first[4] = {0}, second[4] = {0};
    uint32_t bits = g_fns.flags(id);
    g_fns.motion(id, first, second);
    if (g_fns.valid(id) == 0) return 0;
    double x = first[0], y = first[1], z = first[2];
    out->valid = 1;
    out->flags = bits;
    out->motion_squared = cv_f32(cv_f32(cv_f32(y * y) + cv_f32(x * x)) + cv_f32(z * z));
    return 1;
}

/* The mover's dimensions need only be readable: one read into a reused buffer. */
int cv_native_mover_position(uint32_t unit, uint32_t name, double* out)
{
    uint32_t id = g_fns.mover(unit, name);
    void* data = g_fns.dimensions(id);
    if (data == NULL || !vpm_read((uintptr_t)data, g_probe, sizeof g_probe)) return cv_raise("Local mover unavailable");
    _Alignas(16) float position[4] = {0};
    g_fns.position(id, position);
    for (int i = 0; i < 3; i++) out[i] = position[i];
    return 1;
}

/* RCX is unused in this build; RDX is the validated avatar entity. */
int32_t cv_native_exit(uintptr_t entity, const double* target, const double* direction)
{
    _Alignas(16) float forward[4], up[4] = {0, 0, 1, 0}, point[4];
    ToFloats(direction, forward);
    ToFloats(target, point);
    memset(g_matrix, 0, sizeof g_matrix);
    memset(g_quaternion, 0, sizeof g_quaternion);
    (void)g_fns.basis(g_matrix, forward, up);
    g_fns.rotation(g_quaternion, g_matrix);
    return g_fns.classify(NULL, (const void*)entity, point, g_quaternion);
}

/* Stage zero only runs the original approach search on a private copy and writes its geometry there; it cannot start a
 * vault. */
int cv_native_context(const uint8_t* controller, uint8_t* fresh)
{
    memcpy(g_copy, controller, CV_CONTROLLER_SIZE);
    cv_put_u32(g_copy + 4, 0);
    (void)g_fns.detect(g_copy, 0.0f);
    if (cv_u32(g_copy + 4) != 1) return CV_APPROACH_BLOCKED;
    memcpy(fresh, g_copy, CV_CONTROLLER_SIZE);
    for (uint32_t offset = 0x1E8u; offset <= 0x210u; offset += 4)
    {
        double delta = fabs(cv_num(g_copy + offset) - cv_num(controller + offset));
        if (delta != delta || delta > 0.02) return CV_APPROACH_CHANGED;
    }
    return CV_APPROACH_MATCHED;
}

static const char* RaisedInputs(const CvRaisedArgs* args)
{
    double reach = args->reach, norm = 0;
    if (reach != reach || reach <= 0 || reach > 1.5) return "unsupported_raised_reach";
    for (int i = 0; i < 3; i++)
    {
        double v = args->direction[i];
        if (v != v || fabs(v) > 1.001) return "unsupported_raised_direction";
        norm += v * v;
    }
    if (fabs(norm - 1) > 0.001 || fabs(args->direction[2]) > 0.001) return "unsupported_raised_direction";
    return NULL;
}

/* The current mover's shape and root: NULL, or why not. */
static const char* RaisedMover(const CvRaisedArgs* args, uint8_t* shape, float* root)
{
    uint32_t id = g_fns.mover(args->unit, args->name);
    void* data = g_fns.dimensions(id);
    if (data == NULL || !vpm_read((uintptr_t)data, shape, 20)) return "raised_mover_unavailable";
    double radius = cv_num(shape + 12), minimum = cv_num(shape + 16);
    if (radius != radius || minimum != minimum || radius <= 0 || radius > 0.5 || minimum < 0 || minimum >= 2.5)
        return "unsupported_raised_mover";
    g_fns.position(id, root);
    for (int i = 0; i < 3; i++)
        if (root[i] != root[i] || fabs(root[i]) >= 100000) return "raised_mover_unavailable";
    return NULL;
}

/* The native five-slice ledge search at the existing 2.5 allowance, without changing any real avatar setting. */
const char* cv_native_raised(const CvRaisedArgs* args, uint8_t* fresh)
{
    const char* why = RaisedInputs(args);
    uint8_t shape[20];
    _Alignas(16) float root[4] = {0};
    if (why == NULL) why = RaisedMover(args, shape, root);
    if (why != NULL) return why;
    _Alignas(16) uint8_t block[64] = {0};
    _Alignas(16) float direction[4], tail[3], out[8] = {0};
    ToFloats(args->direction, direction);
    tail[0] = (float)cv_num(shape + 16);
    tail[1] = 2.5f;
    tail[2] = (float)args->reach;
    cv_put_u32(block, args->unit);
    memcpy(block + 4, root, 12);
    memcpy(block + 16, shape + 12, 4);
    memcpy(block + 20, shape + 8, 4);
    memcpy(block + 24, direction, 12);
    memcpy(block + 36, tail, 12);
    if (g_fns.approach(NULL, block, out, out + 3, out + 6, out + 7) == 0) return "raised_approach_no_ledge";
    memcpy(fresh, args->controller, CV_CONTROLLER_SIZE);
    cv_put_u32(fresh + 4, 1);
    memcpy(fresh + 488, out, 32);
    memcpy(fresh + 520, block + 24, 12);
    return NULL;
}

void cv_native_basis(const double* direction, uint8_t* matrix)
{
    _Alignas(16) float forward[4], up[4] = {0, 0, 1, 0};
    ToFloats(direction, forward);
    memset(g_matrix, 0, sizeof g_matrix);
    (void)g_fns.basis(g_matrix, forward, up);
    memcpy(matrix, g_matrix, 64);
}

/* The existing worker's 56-byte descriptor over private copies and output storage: no scheduler record changes. */
uint32_t cv_native_refresh(const uint8_t* record, uintptr_t world, uint8_t* out)
{
    memcpy(g_record, record, CV_RECORD_SIZE);
    memset(g_out, 0, sizeof g_out);
    memset(g_descriptor, 0, sizeof g_descriptor);
    g_descriptor[2] = (uint64_t)(uintptr_t)(g_record + 16);
    g_descriptor[3] = (uint64_t)(uintptr_t)(g_record + 80);
    g_descriptor[4] = (uint64_t)(uintptr_t)(g_record + 92);
    g_descriptor[5] = cv_u64(g_record + 8);
    memcpy((uint8_t*)g_descriptor + 48, g_record + 112, 4);
    memcpy((uint8_t*)g_descriptor + 52, g_record + 108, 4);
    uint32_t count = g_fns.query(g_fns.world_id((const void*)world), 2, 1, 5, 0x05A5271Au, g_descriptor, g_out, 1);
    memcpy(out, g_out, CV_HIT_SIZE);
    return count < 1 ? count : 1;
}

/* The game's original eligibility, check and start routine; zero dt does not advance movement timers a second time. */
void cv_native_retry(uintptr_t controller) { g_fns.drive((void*)controller, 0.0f); }

/* An empty modifier leaves every field unchanged; the routine creates the entity-owned record if absent. */
int cv_native_ensure_override(uintptr_t manager, uintptr_t entity)
{
    static uint32_t empty[3];
    if (!vpm_game_code_matches(0x83C420u, "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57"))
        return cv_raise("Native avatar override routine changed");
    memset(empty, 0, sizeof empty);
    g_fns.override((void*)manager, (const void*)entity, empty);
    return 1;
}
