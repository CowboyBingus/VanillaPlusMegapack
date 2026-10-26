/* The fake HellForge and game (fake_hf.h). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "fake_hf.h"

#define HEAP_SIZE (256u * 1024u * 1024u)
#define MAX_HOLES 64
#define MAX_LOADS 256
#define MAX_LISTENERS 256
#define MAX_LIVE 4096
#define MAX_HOOKS 256
#define MAX_MODS 16
#define MAX_ROWS 1024
#define LOG_SIZE (1024 * 1024)

typedef struct FakeModStruct { const HfApi* api; } FakeModStruct;
typedef struct Hole { uintptr_t at; size_t size; } Hole;
typedef struct Load { HfEvent event; HfEventCallback callback; void* user; } Load;
typedef struct Listener { uint32_t kind; HfListener listener; void* user; int32_t priority; } Listener;
typedef struct Live { uint64_t target; char component[64]; uint16_t offset; HfValue now, base; int changed; uintptr_t memory; } Live;
typedef struct Original { uintptr_t target; void* original; } Original;
typedef struct Row { char table[32]; uint64_t id; uintptr_t row; uint32_t stride; } Row;

static uint8_t* g_game;
static uint8_t* g_exe;
static uint8_t* g_heap;
static size_t g_heapUsed;
static Hole g_holes[MAX_HOLES];
static int g_holeCount, g_refuseWrites;
static int g_fired[8];
static Load g_loads[MAX_LOADS];
static int g_loadCount;
static Listener g_listeners[MAX_LISTENERS];
static int g_listenerCount;
static HfTickCallback g_tick;
static void* g_tickUser;
static uint32_t g_state;
static char g_build[32] = "25480438";
static HfModInfo g_mods[MAX_MODS];
static char g_modIds[MAX_MODS][64];
static int g_modCount;
static FakeCounts g_counts;
static char g_log[LOG_SIZE];
static size_t g_logUsed;
static char g_lastLog[1024];
static int g_echo;
static Live g_live[MAX_LIVE];
static int g_liveCount;
static FakeHook g_hooks[MAX_HOOKS];
static int g_hookCount;
static Original g_originals[MAX_HOOKS];
static int g_originalCount;
static Row g_rows[MAX_ROWS];
static int g_rowCount;
static FakeModStruct g_modStruct;

/* ---- memory ------------------------------------------------------------------------------------------------------ */

static int Inside(uintptr_t at, size_t size, const uint8_t* base, size_t limit)
{
    uintptr_t b = (uintptr_t)base;
    return base != NULL && at >= b && size <= limit && at - b <= limit - size;
}

static int Mapped(uintptr_t at, size_t size)
{
    if (size == 0 || at + size < at) return 0;
    if (!Inside(at, size, g_game, FAKE_GAME_SIZE) && !Inside(at, size, g_exe, FAKE_EXE_SIZE) && !Inside(at, size, g_heap, HEAP_SIZE))
        return 0;
    for (int i = 0; i < g_holeCount; i++)
        if (at < g_holes[i].at + g_holes[i].size && g_holes[i].at < at + size) return 0;
    return 1;
}

/* fake_after_read's hook */
static uintptr_t g_afterAt;
static int g_afterLeft;
static void (*g_afterFn)(void*);
static void* g_afterUser;

void fake_after_read(uintptr_t address, int nth, void (*fn)(void*), void* user)
{
    g_afterAt = address;
    g_afterLeft = nth;
    g_afterFn = fn;
    g_afterUser = user;
}

static void AfterRead(uintptr_t address, size_t size)
{
    if (g_afterFn == NULL || g_afterAt < address || g_afterAt >= address + size || --g_afterLeft > 0) return;
    void (*fn)(void*) = g_afterFn;
    g_afterFn = NULL;
    fn(g_afterUser);
}

static int FakeRead(uintptr_t address, void* buffer, size_t size)
{
    g_counts.read++;
    if (!Mapped(address, size)) { AfterRead(address, size); return 1; }
    memcpy(buffer, (const void*)address, size);
    AfterRead(address, size);
    return 0;
}

/* As HellForge's write: the bytes are made writable for the write, then their protection is put back. */
static int FakeWrite(uintptr_t address, const void* data, size_t size)
{
    g_counts.write++;
    if (g_refuseWrites || !Mapped(address, size)) return 1;
    DWORD old;
    if (!VirtualProtect((void*)address, size, PAGE_EXECUTE_READWRITE, &old)) return 1; /* lint-ok: C3 the fake of HfApi.write */
    memcpy((void*)address, data, size);
    DWORD ignored;
    (void)VirtualProtect((void*)address, size, old, &ignored); /* lint-ok: C3 the fake of HfApi.write */
    return 0;
}

static int FakeWriteU32If(HfMod* mod, uintptr_t address, uint32_t expect, uint32_t value)
{
    uint32_t now;
    if (FakeRead(address, &now, 4) != 0) return 1;
    if (now == value) return 0;
    if (now != expect) return 1;
    return FakeWrite(address, &value, 4) == 0 ? 0 : 1;
}

void* fake_heap(size_t size)
{
    size_t at = (g_heapUsed + 15u) & ~(size_t)15u;
    if (size > HEAP_SIZE - at) { fprintf(stderr, "fake_heap: the arena is full\n"); exit(2); }
    g_heapUsed = at + size;
    return g_heap + at;
}

void fake_hole(uintptr_t address, size_t size)
{
    if (g_holeCount < MAX_HOLES) g_holes[g_holeCount++] = (Hole){address, size};
}

void fake_unhole(uintptr_t address)
{
    for (int i = 0; i < g_holeCount; i++)
        if (g_holes[i].at == address) { g_holes[i--] = g_holes[--g_holeCount]; }
}

void fake_refuse_writes(int refuse) { g_refuseWrites = refuse; }
uintptr_t fake_game(void) { return (uintptr_t)g_game; }
uintptr_t fake_exe(void) { return (uintptr_t)g_exe; }

static uintptr_t FakeModuleBase(const char* module, size_t* size)
{
    if (_stricmp(module, "game.dll") == 0) { if (size) *size = FAKE_GAME_SIZE; return (uintptr_t)g_game; }
    if (_stricmp(module, "helldivers2.exe") == 0) { if (size) *size = FAKE_EXE_SIZE; return (uintptr_t)g_exe; }
    if (size) *size = 0;
    return 0;
}

/* An IDA-style pattern ("48 8B ?? 24") into bytes and a mask; its length, or -1. */
static int ParsePattern(const char* pattern, uint8_t* bytes, uint8_t* mask, int capacity)
{
    int n = 0;
    for (const char* p = pattern; *p;)
    {
        if (*p == ' ') { p++; continue; }
        if (n >= capacity) return -1;
        if (p[0] == '?') { mask[n] = 0; bytes[n++] = 0; p += p[1] == '?' ? 2 : 1; continue; }
        char hex[3] = {p[0], p[1], 0};
        char* end = NULL;
        long value = strtol(hex, &end, 16);
        if (end != hex + 2) return -1;
        mask[n] = 1;
        bytes[n++] = (uint8_t)value;
        p += 2;
    }
    return n;
}

static int MatchAt(const uint8_t* at, const uint8_t* bytes, const uint8_t* mask, int n)
{
    for (int i = 0; i < n; i++)
        if (mask[i] && at[i] != bytes[i]) return 0;
    return 1;
}

static uintptr_t FakeFindPattern(const char* module, const char* pattern)
{
    g_counts.find_pattern++;
    size_t size = 0;
    const uint8_t* base = (const uint8_t*)FakeModuleBase(module, &size);
    uint8_t bytes[512], mask[512];
    int n = ParsePattern(pattern, bytes, mask, 512);
    if (base == NULL || n <= 0) return 0;
    for (size_t i = 0; i + (size_t)n <= size; i++)
        if (MatchAt(base + i, bytes, mask, n)) return (uintptr_t)(base + i);
    return 0;
}

/* fake_stand_in's functions: their bytes as shipped, which code_matches and read_code see. */
#define MAX_STAND_INS 64
typedef struct StandIn { uintptr_t at; uint8_t shipped[64]; int size; } StandIn;
static StandIn g_standIns[MAX_STAND_INS];
static int g_standInCount;

/* The code bytes at [address, address + size) as the game shipped them: a stand-in's, else the image's. */
static void ShippedBytes(uintptr_t address, uint8_t* out, size_t size)
{
    memcpy(out, (const void*)address, size);
    for (int i = 0; i < g_standInCount; i++)
        for (size_t k = 0; k < size; k++)
        {
            uintptr_t at = address + k;
            if (at >= g_standIns[i].at && at < g_standIns[i].at + (uintptr_t)g_standIns[i].size) out[k] = g_standIns[i].shipped[at - g_standIns[i].at];
        }
}

static int FakeCodeMatches(uintptr_t address, const char* pattern)
{
    g_counts.code_matches++;
    uint8_t bytes[512], mask[512], code[512];
    int n = ParsePattern(pattern, bytes, mask, 512);
    if (n <= 0 || !Mapped(address, (size_t)n)) return 0;
    ShippedBytes(address, code, (size_t)n);
    return MatchAt(code, bytes, mask, n);
}

static int FakeReadCode(uintptr_t address, void* buffer, size_t size)
{
    g_counts.read++;
    if (!Mapped(address, size)) return 1;
    ShippedBytes(address, buffer, size);
    return 0;
}

static void StandInAt(uint8_t* image, uint32_t rva, const char* shipped, void* fn);

void fake_stand_in(uint32_t rva, const char* shipped, void* fn) { StandInAt(g_game, rva, shipped, fn); }
void fake_stand_in_exe(uint32_t rva, const char* shipped, void* fn) { StandInAt(g_exe, rva, shipped, fn); }

static void StandInAt(uint8_t* image, uint32_t rva, const char* shipped, void* fn)
{
    uint8_t bytes[64], mask[64];
    int n = ParsePattern(shipped, bytes, mask, 64);
    if (n < 14 || g_standInCount >= MAX_STAND_INS) { fprintf(stderr, "fake_stand_in: %d bytes (14 to 64)\n", n); exit(2); }
    StandIn* s = &g_standIns[g_standInCount++];
    s->at = (uintptr_t)image + rva;
    s->size = n;
    memcpy(s->shipped, bytes, (size_t)n);
    uint8_t jump[14] = {0xFF, 0x25, 0, 0, 0, 0};
    uint64_t target = (uint64_t)(uintptr_t)fn;
    memcpy(jump + 6, &target, 8);
    memcpy((void*)s->at, jump, sizeof jump);
    DWORD old;
    if (!VirtualProtect((void*)s->at, sizeof jump, PAGE_EXECUTE_READWRITE, &old)) /* lint-ok: C3 the test's stand-in page */
    {
        fprintf(stderr, "fake_stand_in: the page could not be made executable\n");
        exit(2);
    }
}

/* fake_export's table */
#define MAX_EXPORTS 32
typedef struct Export { char module[64], name[128]; void* fn; } Export;
static Export g_exports[MAX_EXPORTS];
static int g_exportCount;

void fake_export(const char* module, const char* name, void* fn)
{
    if (g_exportCount >= MAX_EXPORTS) return;
    snprintf(g_exports[g_exportCount].module, 64, "%s", module);
    snprintf(g_exports[g_exportCount].name, 128, "%s", name);
    g_exports[g_exportCount++].fn = fn;
}

static void* FakeModuleExport(const char* module, const char* name)
{
    g_counts.exports++;
    for (int i = 0; i < g_exportCount; i++)
        if (_stricmp(g_exports[i].module, module) == 0 && strcmp(g_exports[i].name, name) == 0) return g_exports[i].fn;
    return NULL;
}

static void FakeWritableQuery(void) { g_counts.writable++; }

/* vpm_read in tests: the read of the API the core was started with (the fake's, or a test's copy of it wrapping it), so
 * the fake's regions, holes and counts apply. */
static int FakeCoreRead(uintptr_t address, void* out, size_t size) { return vpm_core_hf()->read(address, out, size) == 0; }

/* ---- logging ----------------------------------------------------------------------------------------------------- */

static void FakeLog(HfMod* mod, const char* format, ...)
{
    g_counts.log++;
    va_list args;
    va_start(args, format);
    vsnprintf(g_lastLog, sizeof g_lastLog, format, args);
    va_end(args);
    if (g_echo) printf("    log: %s\n", g_lastLog);
    size_t n = strlen(g_lastLog);
    if (g_logUsed + n + 2 < LOG_SIZE)
    {
        memcpy(g_log + g_logUsed, g_lastLog, n);
        g_logUsed += n;
        g_log[g_logUsed++] = '\n';
        g_log[g_logUsed] = 0;
    }
}

int fake_log_has(const char* text) { return strstr(g_log, text) != NULL; }

int fake_log_count(const char* text)
{
    int n = 0;
    for (const char* at = strstr(g_log, text); at != NULL; at = strstr(at + 1, text)) n++;
    return n;
}
const char* fake_log_text(void) { return g_log; }
void fake_log_clear(void) { g_logUsed = 0; g_log[0] = 0; }
void fake_log_echo(int echo) { g_echo = echo; }
static const char* FakeLastLog(HfMod* mod) { return g_lastLog; }
static const char* FakeLogsFolder(HfMod* mod) { return ""; }

/* ---- identity ---------------------------------------------------------------------------------------------------- */

static const char* FakeBuildId(void) { return g_build; }
static const char* FakeModId(HfMod* mod) { return VPM_PACK_ID; }
static const char* FakeModFolder(HfMod* mod) { return "."; }
void fake_set_build(const char* build) { snprintf(g_build, sizeof g_build, "%s", build); }

void fake_clear_mods(void) { g_modCount = 0; }

void fake_add_mod(const char* id, uint32_t kind)
{
    if (g_modCount >= MAX_MODS) return;
    snprintf(g_modIds[g_modCount], sizeof g_modIds[0], "%s", id);
    g_mods[g_modCount] = (HfModInfo){sizeof(HfModInfo), kind, g_modIds[g_modCount], "", "", 1};
    g_modCount++;
}

static int FakeMods(HfMod* mod, uint32_t index, HfModInfo* out)
{
    if (index >= (uint32_t)g_modCount) return 0;
    *out = g_mods[index];
    return 1;
}

/* ---- events and ticks -------------------------------------------------------------------------------------------- */

static int FakeOn(HfMod* mod, HfEvent event, HfEventCallback callback, void* user)
{
    g_counts.on++;
    if ((int)event < 1 || (int)event > 7 || g_loadCount >= MAX_LOADS) return 1;
    g_loads[g_loadCount++] = (Load){event, callback, user};
    if (g_fired[event]) callback(mod, event, user);
    return 0;
}

void fake_fire(HfEvent event)
{
    g_fired[event] = 1;
    int count = g_loadCount; /* callbacks registered by these run at once in FakeOn */
    for (int i = 0; i < count; i++)
        if (g_loads[i].event == event) g_loads[i].callback(fake_mod(), event, g_loads[i].user);
}

static int FakeOnGameThread(HfMod* mod, HfTickCallback callback, void* user)
{
    g_tick = callback;
    g_tickUser = user;
    return 1;
}

static void (*g_afterTick)(float dt);
void fake_after_tick(void (*fn)(float dt)) { g_afterTick = fn; }

void fake_frames(int n, float dt)
{
    for (int i = 0; i < n && g_tick != NULL; i++)
    {
        g_tick(fake_mod(), dt, g_tickUser);
        if (g_afterTick != NULL) g_afterTick(dt);
    }
}

void fake_user32(const VpmUser32* table) { vpm_user32_set(table); }

/* ---- the engine's frame: game.dll's whole update, with HellForge's game-thread callback inside it ------------------ */

static int g_doubleTick;
static uint8_t g_gameObject[64];
static void* g_lastGame;
static float g_lastDt;
static int g_gameUpdates;

void fake_double_tick(int twice) { g_doubleTick = twice; }
int fake_game_updates(void) { return g_gameUpdates; }

/* game.dll's frame update as the fake runs it: HellForge's callback (once, or twice as with the late update's second
 * caller), then the game's own update (fake_after_tick). */
static void FakeFrameUpdate(void* game, float dt)
{
    g_lastGame = game;
    g_lastDt = dt;
    g_gameUpdates++;
    if (g_tick != NULL) g_tick(fake_mod(), dt, g_tickUser);
    if (g_tick != NULL && g_doubleTick) g_tick(fake_mod(), dt, g_tickUser);
    if (g_afterTick != NULL) g_afterTick(dt);
}

void fake_frame_update(int decoded)
{
    static const uint8_t shipped[] = VPM_FRAME_UPDATE_BYTES;
    if (decoded) memcpy(g_game + VPM_FRAME_UPDATE, shipped, sizeof shipped);
    else memset(g_game + VPM_FRAME_UPDATE, 0xCC, sizeof shipped);
}

void fake_engine_frames(int n, float dt)
{
    for (int i = 0; i < n; i++)
    {
        void (*detour)(void*, float) = (void (*)(void*, float))fake_hook_detour((uintptr_t)g_game + VPM_FRAME_UPDATE);
        if (detour != NULL) detour(g_gameObject, dt);
        else FakeFrameUpdate(g_gameObject, dt);
        if (g_lastGame != g_gameObject || g_lastDt != dt) { fprintf(stderr, "fake: the frame update got other arguments\n"); exit(2); }
    }
}

void* fake_hook_detour(uintptr_t target)
{
    for (int i = g_hookCount - 1; i >= 0; i--)
        if (g_hooks[i].target == target) return g_hooks[i].detour;
    return NULL;
}

static uint32_t g_refusedKind;

void fake_refuse_subscribe(uint32_t kind) { g_refusedKind = kind; }

static int FakeSubscribe(HfMod* mod, uint32_t kind, HfListener listener, void* user, int32_t priority)
{
    g_counts.subscribe++;
    if (kind < 1 || kind > 15 || g_listenerCount >= MAX_LISTENERS || (g_refusedKind != 0 && kind == g_refusedKind))
        return 0;
    g_listeners[g_listenerCount++] = (Listener){kind, listener, user, priority};
    return 1;
}

void fake_emit(const HfEventInfo* event)
{
    for (int32_t priority = 1000; priority >= -1000; priority--) /* highest priority first */
        for (int i = 0; i < g_listenerCount; i++)
            if (g_listeners[i].kind == event->kind && g_listeners[i].priority == priority)
                g_listeners[i].listener(fake_mod(), event, g_listeners[i].user);
}

static uint32_t FakeGameState(HfMod* mod) { return g_state; }
void fake_set_state(uint32_t state) { g_state = state; }

/* ---- live fields ------------------------------------------------------------------------------------------------- */

static Live* FindLive(uint64_t target, const char* component, uint16_t offset)
{
    for (int i = 0; i < g_liveCount; i++)
        if (g_live[i].target == target && g_live[i].offset == offset && strcmp(g_live[i].component, component) == 0)
            return &g_live[i];
    return NULL;
}

void fake_live_put(uint64_t target, const char* component, uint16_t offset, HfValue value)
{
    Live* live = FindLive(target, component, offset);
    if (live == NULL && g_liveCount < MAX_LIVE)
    {
        live = &g_live[g_liveCount++];
        memset(live, 0, sizeof *live);
        live->target = target;
        snprintf(live->component, sizeof live->component, "%s", component);
        live->offset = offset;
    }
    if (live != NULL) live->now = live->base = value;
}

int fake_live_now(uint64_t target, const char* component, uint16_t offset, HfValue* out)
{
    Live* live = FindLive(target, component, offset);
    if (live == NULL) return 0;
    *out = live->now;
    return 1;
}

/* A live field bound to memory (fake_live_bind): set_live stores its value there too, as HellForge's edit does. */
static void StoreLive(const Live* live)
{
    if (live->memory == 0) return;
    const HfValue* v = &live->now;
    uint8_t bytes[8];
    size_t size = v->type == HF_TYPE_U8 ? 1 : v->type == HF_TYPE_U16 ? 2 : v->type == HF_TYPE_U64 ? 8 : 4;
    if (v->type == HF_TYPE_F32) { float f = (float)v->number; memcpy(bytes, &f, 4); }
    else if (v->type == HF_TYPE_I32) { int32_t i = (int32_t)v->number; memcpy(bytes, &i, 4); }
    else if (v->type == HF_TYPE_U64) memcpy(bytes, &v->u64, 8);
    else { uint64_t u = (uint64_t)v->number; memcpy(bytes, &u, size); }
    (void)FakeWrite(live->memory, bytes, size);
    g_counts.write--; /* HellForge's own store, not the component's call */
}

void fake_live_bind(uint64_t target, const char* component, uint16_t offset, uintptr_t memory)
{
    Live* live = FindLive(target, component, offset);
    if (live != NULL) live->memory = memory;
}

static int FakeGetLive(HfMod* mod, HfRef target, const HfField* field, HfLiveValue* out)
{
    g_counts.get_live++;
    Live* live = FindLive(target, field->component, field->offset);
    if (live == NULL) return 0;
    out->now = live->now;
    out->base = live->base;
    out->mod = NULL;
    return HF_APPLIES_NOW;
}

static int FakeSetLive(HfMod* mod, HfRef target, const HfField* field, const HfValue* value, uint32_t flags)
{
    g_counts.set_live++;
    Live* live = FindLive(target, field->component, field->offset);
    if (live == NULL) { snprintf(g_lastLog, sizeof g_lastLog, "fake: no such field"); return 0; }
    if (value == NULL) { live->now = live->base; StoreLive(live); return HF_APPLIES_NOW; }
    if (value->type != field->type) { snprintf(g_lastLog, sizeof g_lastLog, "fake: the value's type is not the field's"); return 0; }
    live->now = *value;
    live->changed = 1;
    StoreLive(live);
    return HF_APPLIES_NOW;
}

/* ---- hooks ------------------------------------------------------------------------------------------------------- */

void fake_set_original(uintptr_t target, void* original)
{
    if (g_originalCount < MAX_HOOKS) g_originals[g_originalCount++] = (Original){target, original};
}

static int FakeHookEx(HfMod* mod, uintptr_t target, void* detour, void** original, int32_t priority)
{
    g_counts.hook++;
    if (g_hookCount >= MAX_HOOKS) return 1;
    g_hooks[g_hookCount++] = (FakeHook){target, detour, priority};
    /* The function itself goes on, unless the test named another original: a stand-in's jump reaches the test's
     * function, as HellForge's chain would reach the game's. */
    *original = (void*)target;
    for (int i = 0; i < g_originalCount; i++)
        if (g_originals[i].target == target) *original = g_originals[i].original;
    return 0;
}

static int FakeHookPlain(HfMod* mod, uintptr_t target, void* detour, void** original) { return FakeHookEx(mod, target, detour, original, 0); }

/* SDK 16 unhook: the latest hook of target out of the list. */
static int FakeUnhook(HfMod* mod, uintptr_t target)
{
    g_counts.unhook++;
    for (int i = g_hookCount - 1; i >= 0; i--)
    {
        if (g_hooks[i].target != target) continue;
        memmove(&g_hooks[i], &g_hooks[i + 1], sizeof g_hooks[0] * (size_t)(g_hookCount - i - 1));
        g_hookCount--;
        return 0;
    }
    return 1;
}
int fake_hook_count(void) { return g_hookCount; }
FakeHook fake_hook_at(int index) { return g_hooks[index]; }

/* ---- rows and records -------------------------------------------------------------------------------------------- */

static uintptr_t FindRow(const char* table, uint64_t id)
{
    for (int i = 0; i < g_rowCount; i++)
        if (g_rows[i].id == id && strcmp(g_rows[i].table, table) == 0) return g_rows[i].row;
    return 0;
}

void fake_set_record(const char* table, uint64_t id, uintptr_t row, uint32_t stride)
{
    if (g_rowCount >= MAX_ROWS) return;
    snprintf(g_rows[g_rowCount].table, 32, "%s", table);
    g_rows[g_rowCount].id = id;
    g_rows[g_rowCount].stride = stride;
    g_rows[g_rowCount++].row = row;
}

void fake_set_row(const char* table, uint64_t id, uintptr_t row) { fake_set_record(table, id, row, 0); }

static uintptr_t FakeComponentRecord(const char* component, uint64_t resource, uint32_t* stride)
{
    if (stride) *stride = 0;
    for (int i = 0; i < g_rowCount; i++)
        if (g_rows[i].id == resource && strcmp(g_rows[i].table, component) == 0)
        {
            if (stride) *stride = g_rows[i].stride;
            return g_rows[i].row;
        }
    return 0;
}
static uintptr_t FakeProjectileRow(uint32_t type) { return FindRow("projectile", type); }
static uintptr_t FakeDamageRow(uint32_t id) { return FindRow("damage", id); }
static uintptr_t FakeStratagemRow(uint32_t type) { return FindRow("stratagem", type); }
static uintptr_t FakeDifficultyRow(uint32_t level) { return FindRow("difficulty", level); }

uint64_t fake_murmur64(const void* data, size_t size)
{
    const uint64_t m = 0xc6a4a7935bd1e995ull;
    const int r = 47;
    uint64_t h = 0 ^ (size * m);
    const uint8_t* p = data;
    size_t blocks = size / 8;
    for (size_t i = 0; i < blocks; i++)
    {
        uint64_t k;
        memcpy(&k, p + i * 8, 8);
        k *= m; k ^= k >> r; k *= m;
        h ^= k; h *= m;
    }
    const uint8_t* tail = p + blocks * 8;
    switch (size & 7)
    {
    case 7: h ^= (uint64_t)tail[6] << 48; /* fall through */
    case 6: h ^= (uint64_t)tail[5] << 40; /* fall through */
    case 5: h ^= (uint64_t)tail[4] << 32; /* fall through */
    case 4: h ^= (uint64_t)tail[3] << 24; /* fall through */
    case 3: h ^= (uint64_t)tail[2] << 16; /* fall through */
    case 2: h ^= (uint64_t)tail[1] << 8; /* fall through */
    case 1: h ^= (uint64_t)tail[0]; h *= m;
    }
    h ^= h >> r; h *= m; h ^= h >> r;
    return h;
}

static uint64_t FakeResourceHash(const char* name) { return fake_murmur64(name, strlen(name)); }

/* ---- what the tests do not use yet: refused, counted --------------------------------------------------------- */

#define REFUSE(name) do { g_counts.other++; snprintf(g_lastLog, sizeof g_lastLog, "fake: %s is not part of the fake", name); } while (0)
static int FakeNetworkFieldType(const char* name, HfFieldType* type) { REFUSE("network_field_type"); return 1; }
static int FakeSetNetworkFieldBits(HfMod* mod, const char* name, HfFieldType expect, int32_t bits) { REFUSE("set_network_field_bits"); return 1; }
static uint32_t FakeAddWeapon(HfMod* mod, const HfWeapon* weapon) { REFUSE("add_weapon"); return 0; }
static uint64_t FakeWeaponEntity(uint32_t weapon) { return 0; }
static uint32_t FakeAddProjectile(HfMod* mod, const HfProjectile* projectile) { REFUSE("add_projectile"); return 0; }
static uint32_t FakeAddDamage(HfMod* mod, const HfDamage* damage) { REFUSE("add_damage"); return 0; }
static uint32_t FakeAddStratagem(HfMod* mod, const HfStratagem* stratagem) { REFUSE("add_stratagem"); return 0; }
static uint64_t FakeAddEntity(HfMod* mod, const HfEntity* entity) { REFUSE("add_entity"); return 0; }
static uint32_t FakeAddBehaviour(HfMod* mod, const HfBehaviour* behaviour) { REFUSE("add_behaviour"); return 0; }
static uint32_t FakeAddDifficulty(HfMod* mod, const HfDifficulty* difficulty) { REFUSE("add_difficulty"); return 0; }
static HfRef FakeRegisterEntity(HfMod* mod, const HfEntityDef* entity) { REFUSE("register_entity"); return 0; }
static int FakeCopyField(HfMod* mod, HfRef entity, HfRef from, const HfField* field) { REFUSE("copy_field"); return 1; }
static int FakeSetField(HfMod* mod, HfRef entity, const HfField* field, const HfValue* value) { REFUSE("set_field"); return 1; }
static int FakeSetTag(HfMod* mod, HfRef entity, uint64_t tag, int present) { REFUSE("set_tag"); return 1; }
static int FakeMount(HfMod* mod, HfRef entity, uint32_t slot, HfRef carried) { REFUSE("mount"); return 1; }
static void* FakeRecord(HfMod* mod, HfRef entity, const char* component, uint32_t layout, uint32_t size) { return (void*)FindRow(component, entity); }
static uint64_t FakeFind(uint32_t kind, const char* name) { return 0; }
static int FakeEditEntity(HfMod* mod, const HfEditDef* edit) { REFUSE("edit_entity"); return 1; }
static int FakeSetPassives(HfMod* mod, uint32_t armor, uint32_t second) { REFUSE("set_passives"); return 0; }
static int FakeGetPassives(HfMod* mod, HfPassives* out) { REFUSE("get_passives"); return 0; }
static int FakeLoadPackage(HfMod* mod, uint64_t package) { return HF_PACKAGE_RESIDENT; }
static int FakeGetStat(HfMod* mod, const HfStat* stat, HfLiveValue* out) { return 0; }
static void FakeSession(HfMod* mod, HfSession* out) { memset(out, 0, sizeof *out); }
static int FakeContent(HfMod* mod, uint32_t index, HfContent* out) { return 0; }
static uint32_t FakeAddAbility(HfMod* mod, const HfAbility* ability) { REFUSE("add_ability"); return 0; }
static uint32_t FakeAddStratagemCategory(HfMod* mod, const HfStratagemCategory* category) { REFUSE("add_stratagem_category"); return 0; }
static int FakeSetStat(HfMod* mod, const HfStat* stat, const HfValue* value, uint32_t flags) { REFUSE("set_stat"); return 0; }
static int FakeCopyRow(HfMod* mod, const char* table, uint64_t row, uint64_t from, uint32_t offset, uint32_t size) { REFUSE("copy_row"); return 0; }
static int FakeHeal(HfMod* mod, float amount) { REFUSE("heal"); return 0; }
static int FakeHealLimb(HfMod* mod, uint32_t limb) { REFUSE("heal_limb"); return 0; }
static int FakeInjure(HfMod* mod, uint32_t limb, int32_t damage) { REFUSE("injure"); return 0; }
static int FakeLimbState(HfMod* mod, uint32_t entity, uint32_t limb, HfLimbState* out) { REFUSE("limb_state"); return 0; }
static int FakeApplyStatus(HfMod* mod, uint32_t entity, uint32_t status, float buildup) { REFUSE("apply_status"); return 0; }
static int FakeAddVelocity(HfMod* mod, const float delta[3]) { REFUSE("add_velocity"); return 0; }
static int FakeResupply(HfMod* mod) { REFUSE("resupply_from_pack"); return 0; }
static int FakeSpawnExplosion(HfMod* mod, uint32_t type, const float position[3]) { REFUSE("spawn_explosion"); return 0; }
static int FakeSpawnProjectile(HfMod* mod, uint32_t type, const float position[3], const float direction[3]) { REFUSE("spawn_projectile"); return 0; }
static int FakeCredit(HfMod* mod, uint32_t entity) { REFUSE("credit_to_player"); return 0; }
static int FakeFreezeTimer(HfMod* mod, int frozen) { REFUSE("freeze_mission_timer"); return 0; }
static int FakeSpawnPelican(HfMod* mod, const HfPelicanCall* call, uint32_t* entity) { REFUSE("spawn_pelican"); return 0; }
static uint32_t FakeModifyShots(HfMod* mod, const HfShotRule* rule) { REFUSE("modify_shots"); return 0; }
static uint32_t FakeHoming(HfMod* mod, const HfHoming* rule) { REFUSE("homing"); return 0; }
static int FakeStopShots(HfMod* mod, uint32_t id) { REFUSE("stop_shots"); return 0; }
static void FakeNotice(HfMod* mod, HfNotice* out) { memset(out, 0, sizeof *out); }
static int FakeSyncState(HfMod* mod, HfSyncState* out) { return 0; }
static int FakeSyncMod(HfMod* mod, uint32_t index, HfSyncMod* out) { return 0; }
static int FakeSyncAnswer(HfMod* mod, uint32_t version, uint32_t answer, const char* mod_id) { return 0; }
static uint32_t FakeStatsSource(HfMod* mod) { return HF_STATS_OWN; }

static const HfApi g_api = {
    .version = 15, .size = sizeof(HfApi), .log = FakeLog, .build_id = FakeBuildId, .mod_id = FakeModId,
    .mod_folder = FakeModFolder, .on = FakeOn, .module_base = FakeModuleBase, .find_pattern = FakeFindPattern,
    .read = FakeRead, .write = FakeWrite, .write_u32_if = FakeWriteU32If, .hook = FakeHookPlain,
    .network_field_type = FakeNetworkFieldType, .set_network_field_bits = FakeSetNetworkFieldBits,
    .component_record = FakeComponentRecord, .add_weapon = FakeAddWeapon, .weapon_entity = FakeWeaponEntity,
    .add_projectile = FakeAddProjectile, .projectile_row = FakeProjectileRow, .add_damage = FakeAddDamage,
    .damage_row = FakeDamageRow, .resource_hash = FakeResourceHash, .add_stratagem = FakeAddStratagem,
    .stratagem_row = FakeStratagemRow, .add_entity = FakeAddEntity, .add_behaviour = FakeAddBehaviour,
    .add_difficulty = FakeAddDifficulty, .difficulty_row = FakeDifficultyRow, .register_entity = FakeRegisterEntity,
    .copy_field = FakeCopyField, .set_field = FakeSetField, .set_tag = FakeSetTag, .mount = FakeMount,
    .record = FakeRecord, .find = FakeFind, .edit_entity = FakeEditEntity, .set_live = FakeSetLive,
    .get_live = FakeGetLive, .set_passives = FakeSetPassives, .get_passives = FakeGetPassives,
    .on_game_thread = FakeOnGameThread, .load_package = FakeLoadPackage, .last_log = FakeLastLog,
    .logs_folder = FakeLogsFolder, .get_stat = FakeGetStat, .session = FakeSession, .subscribe = FakeSubscribe,
    .game_state = FakeGameState, .content = FakeContent, .add_ability = FakeAddAbility,
    .add_stratagem_category = FakeAddStratagemCategory, .set_stat = FakeSetStat, .copy_row = FakeCopyRow,
    .mods = FakeMods, .heal = FakeHeal, .heal_limb = FakeHealLimb, .injure = FakeInjure, .limb_state = FakeLimbState,
    .apply_status = FakeApplyStatus, .add_velocity = FakeAddVelocity, .resupply_from_pack = FakeResupply,
    .spawn_explosion = FakeSpawnExplosion, .spawn_projectile = FakeSpawnProjectile, .credit_to_player = FakeCredit,
    .freeze_mission_timer = FakeFreezeTimer, .spawn_pelican = FakeSpawnPelican, .modify_shots = FakeModifyShots,
    .homing = FakeHoming, .stop_shots = FakeStopShots, .notice = FakeNotice, .hook_ex = FakeHookEx,
    .code_matches = FakeCodeMatches, .read_code = FakeReadCode, .sync_state = FakeSyncState, .sync_mod = FakeSyncMod,
    .sync_answer = FakeSyncAnswer, .stats_source = FakeStatsSource,
};

const HfApi* fake_api(void) { return &g_api; }

/* The live table: SDK 15's HfApi with PR 65's two functions after it (built with PR 65's header, they are its fields). */
static uint32_t g_livePhase;
static uint32_t FakeLoadPhase(HfMod* mod) { return g_livePhase; }
#ifdef HF_LOAD_LIVE
static HfApi g_liveApi;
#else
typedef struct FakeLiveApi { HfApi api; uint32_t (*load_phase)(HfMod* mod); int (*unhook)(HfMod* mod, uintptr_t target); } FakeLiveApi;
static FakeLiveApi g_liveApi;
#endif

void fake_live_phase(uint32_t phase) { g_livePhase = phase; }

const HfApi* fake_live_api(void)
{
#ifdef HF_LOAD_LIVE
    g_liveApi = g_api;
    g_liveApi.load_phase = FakeLoadPhase;
    g_liveApi.unhook = FakeUnhook;
    g_liveApi.version = 16;
    return &g_liveApi;
#else
    g_liveApi.api = g_api;
    g_liveApi.api.version = 16;
    g_liveApi.api.size = sizeof g_liveApi;
    g_liveApi.load_phase = FakeLoadPhase;
    g_liveApi.unhook = FakeUnhook;
    return &g_liveApi.api;
#endif
}

int fake_start_live(const VpmComponentDef* const* defs, int count) { return vpm_core_init(fake_live_api(), fake_mod(), defs, count); }

void fake_take_out(void)
{
    g_loadCount = g_listenerCount = g_hookCount = 0;
    g_tick = NULL;
    g_tickUser = NULL;
}
HfMod* fake_mod(void) { return (HfMod*)&g_modStruct; }

/* ---- set-up ------------------------------------------------------------------------------------------------------ */

static uint8_t* Region(uint8_t* region, size_t size)
{
    if (region == NULL)
    {
        region = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (region == NULL) { fprintf(stderr, "fake: no memory for a %zu-byte region\n", size); exit(2); }
        return region;
    }
    /* Decommitting and committing again gives zeroed pages without touching the untouched ones. */
    (void)VirtualFree(region, size, MEM_DECOMMIT); /* the commit below fails loudly if this did */
    if (VirtualAlloc(region, size, MEM_COMMIT, PAGE_READWRITE) == NULL) { fprintf(stderr, "fake: recommit failed\n"); exit(2); }
    return region;
}

static int g_refuseTicks[2];

void fake_refuse_ticks(int pre, int post)
{
    g_refuseTicks[0] = pre;
    g_refuseTicks[1] = post;
}

static int FakeTickRefused(int post) { return g_refuseTicks[post != 0]; }

void fake_setup(void)
{
    /* A crash ends the test process with its exit code and the build reports it: no error dialog, no window. */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    g_game = Region(g_game, FAKE_GAME_SIZE);
    g_exe = Region(g_exe, FAKE_EXE_SIZE);
    g_heap = Region(g_heap, HEAP_SIZE);
    g_heapUsed = 0;
    g_holeCount = g_refuseWrites = 0;
    g_refuseTicks[0] = g_refuseTicks[1] = 0;
    g_refusedKind = 0;
    memset(g_fired, 0, sizeof g_fired);
    g_loadCount = g_listenerCount = g_liveCount = g_hookCount = g_originalCount = g_rowCount = g_modCount = 0;
    g_tick = NULL;
    g_tickUser = NULL;
    g_afterTick = NULL;
    g_doubleTick = 0;
    g_gameUpdates = 0;
    g_lastGame = NULL;
    g_state = HF_STATE_NONE;
    snprintf(g_build, sizeof g_build, "25480438");
    memset(&g_counts, 0, sizeof g_counts);
    fake_log_clear();
    g_lastLog[0] = 0;
    g_modStruct.api = &g_api;
    g_standInCount = g_exportCount = 0;
    g_afterFn = NULL;
    g_livePhase = 0; /* PR 65's HF_LOAD_BOOT */
    static const VpmTestHooks hooks = {FakeWritableQuery, FakeModuleExport, FakeCoreRead, FakeTickRefused};
    vpm_core_test_hooks(&hooks);
    /* A hook of the frame update goes on to the fake's frame update. */
    fake_set_original((uintptr_t)g_game + VPM_FRAME_UPDATE, (void*)FakeFrameUpdate);
    vpm_core_reset();
    DeleteFileW(L"vpm-test-settings.ini");
    vpm_settings_path_override(L"vpm-test-settings.ini");
}

void fake_next_session(void)
{
    g_loadCount = g_listenerCount = g_hookCount = 0;
    g_tick = NULL;
    g_tickUser = NULL;
    g_afterTick = NULL;
    memset(g_fired, 0, sizeof g_fired);
    memset(&g_counts, 0, sizeof g_counts);
    fake_log_clear();
    vpm_core_reset();
    vpm_settings_path_override(L"vpm-test-settings.ini");
}

int fake_start(const VpmComponentDef* const* defs, int count)
{
    return vpm_core_init(&g_api, fake_mod(), defs, count);
}

VpmComponent* fake_component(int index) { return vpm_component_at(index); }
FakeCounts fake_counts(void) { return g_counts; }
void fake_counts_reset(void) { memset(&g_counts, 0, sizeof g_counts); }
