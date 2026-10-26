/* Match Your Colors: the engine calls that recolor (engine.lua), 1:1. Script C API [game + 0x3326308]: Unit (+24),
 * Mesh (+232), Material (+40); get_engine_api (exe 0xa4e50): 26 RenderBufferApi, 5 ResourceManagerApi. Every function
 * address is compared with its expected executable offset once per session, before any call. Runtime textures are made
 * updatable and kept in a pool that refills them (making one waits for the render thread, refilling one does not).
 * Game thread only; nothing here runs on an idle frame. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_runtime.h"

#define MAX_MESHES 64
#define MAX_MATERIALS 64
#define MAX_BINDINGS 64

typedef uint64_t (*MycGetEngineApi)(uint32_t id);

typedef struct MycFunction { const char* name; int table; uint32_t offset, expected; } MycFunction;
#define T_UNIT 0
#define T_MESH 1
#define T_MATERIAL 2
#define T_BUFFERS 3
#define T_RESOURCES 4
static const MycFunction kMycFunctions[] = {
    {"alive", T_UNIT, 1824, 0x1feeb0}, {"meshes", T_UNIT, 424, 0x200cd0}, {"mesh", T_UNIT, 440, 0x200d20},
    {"visibility", T_UNIT, 1624, 0x205680}, {"materials", T_MESH, 8, 0x344300}, {"material", T_MESH, 24, 0x344350},
    {"commit", T_MESH, 32, 0x344360}, {"set_resource", T_MATERIAL, 128, 0x30f2b0},
    {"create", T_BUFFERS, 0x60, 0x1c7cc0}, {"update", T_BUFFERS, 0x68, 0x1c8090}, {"destroy", T_BUFFERS, 0x70, 0x1c81a0},
    {"resource", T_BUFFERS, 0x78, 0x1c8670}, {"can_get", T_RESOURCES, 0x30, 0xa0d30}, {"get", T_RESOURCES, 0x40, 0xa0df0},
};

static uint64_t MycEngineU64(uintptr_t address)
{
    uint64_t v = 0;
    return vpm_read_u64(address, &v) ? v : 0;
}

/* The function pointer of entry i into out (MycNative's fields in kMycFunctions order). */
static void MycEngineSet(MycNative* out, int i, uintptr_t address)
{
    void* fn = (void*)address;
    void** fields[] = {(void**)&out->alive, (void**)&out->meshes, (void**)&out->mesh, (void**)&out->visibility,
                       (void**)&out->materials, (void**)&out->material, (void**)&out->commit, (void**)&out->set_resource,
                       (void**)&out->create, (void**)&out->update, (void**)&out->destroy, (void**)&out->resource,
                       (void**)&out->can_get, (void**)&out->get};
    *fields[i] = fn;
}

int myc_engine_open(MycNative* out, const char** why)
{
    memset(out, 0, sizeof *out);
    uintptr_t exe = vpm_exe();
    if (exe == 0 || vpm_game() == 0) { *why = "game modules unavailable"; return 0; }
    if (!vpm_exe_code_matches(MYC_GET_ENGINE_API_RVA, MYC_GET_ENGINE_API_PREFIX)) { *why = "get_engine_api changed"; return 0; }
    uint64_t script = vpm_game_u64(MYC_SCRIPT_API_RVA);
    if (script < 0x10000) { *why = "script API unavailable"; return -1; }
    uint64_t tables[5];
    tables[T_UNIT] = MycEngineU64(script + 24);
    tables[T_MESH] = MycEngineU64(script + 232);
    tables[T_MATERIAL] = MycEngineU64(script + 40);
    MycGetEngineApi get_api = (MycGetEngineApi)(exe + MYC_GET_ENGINE_API_RVA);
    tables[T_BUFFERS] = get_api(26);
    tables[T_RESOURCES] = get_api(5);
    for (int t = 0; t < 5; t++)
        if (tables[t] == 0) { *why = "script API tables not filled yet"; return -1; }
    for (int i = 0; i < (int)(sizeof kMycFunctions / sizeof kMycFunctions[0]); i++)
    {
        const MycFunction* f = &kMycFunctions[i];
        uint64_t base = tables[f->table];
        uint64_t address = base != 0 ? MycEngineU64(base + f->offset) : 0;
        if (address != exe + f->expected)
        {
            static char text[96];
            snprintf(text, sizeof text, "engine function changed: %s", f->name);
            *why = text;
            return 0;
        }
        MycEngineSet(out, i, (uintptr_t)address);
    }
    return 1;
}

uint64_t myc_texture_object(const MycNative* native, uint64_t name)
{
    if (native->can_get(MYC_TEXTURE_TYPE, name) == 0) return 0;
    return native->get(MYC_TEXTURE_TYPE, name);
}

int myc_unit_materials(const MycNative* native, uint32_t unit, uint64_t* meshes, uint64_t* materials)
{
    int n = 0;
    if (native->alive(unit) == 0) return 0;
    uint32_t count = native->meshes(unit);
    for (uint32_t m = 0; m < (count < MAX_MESHES ? count : MAX_MESHES); m++)
    {
        uint64_t mesh = native->mesh(unit, m);
        if (mesh == 0) continue;
        uint32_t k = native->materials(mesh);
        for (uint32_t j = 0; j < (k < MAX_MATERIALS ? k : MAX_MATERIALS); j++)
        {
            uint64_t material = native->material(mesh, j);
            if (material == 0 || n >= MYC_MAX_UNIT_MATERIALS) continue;
            meshes[n] = mesh;
            materials[n] = material;
            n++;
        }
    }
    return n;
}

static uint32_t MycEngineLe32(const uint8_t* p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
/* A binding array entry's 48-bit address (u32 low, u16 high). */
static uint64_t MycEngineLe48(const uint8_t* p) { return MycEngineLe32(p) + ((uint64_t)(p[4] | p[5] << 8) << 32); }

int myc_bindings(uint64_t material, uint8_t* big, uint64_t* array)
{
    uint8_t head[16];
    if (!vpm_read(material + 24, head, 16)) return 0;
    uint32_t count = MycEngineLe32(head);
    *array = MycEngineLe48(head + 8);
    if (count == 0 || count > MAX_BINDINGS || *array < 0x10000) return 0;
    if (!vpm_read(*array, big, count * 16)) return 0;
    return (int)count;
}

uint64_t myc_binding_in(const uint8_t* big, int count, uint32_t slot)
{
    uint8_t low = (uint8_t)(slot & 0xFF);
    for (int i = 0; i < count; i++)
    {
        const uint8_t* e = big + i * 16;
        if (e[0] == low && MycEngineLe32(e) == slot) return MycEngineLe48(e + 8);
    }
    return 0;
}

uint64_t myc_binding(uint64_t material, uint32_t slot)
{
    static uint8_t big[MAX_BINDINGS * 16];
    uint64_t array;
    int count = myc_bindings(material, big, &array);
    return count > 0 ? myc_binding_in(big, count, slot) : 0;
}

uint64_t myc_binding_entry(uint64_t material, uint32_t slot)
{
    static uint8_t big[MAX_BINDINGS * 16];
    uint64_t array;
    int count = myc_bindings(material, big, &array);
    for (int i = 0; i < count; i++)
        if (MycEngineLe32(big + i * 16) == slot) return array + (uint64_t)i * 16 + 8;
    return 0;
}

/* ---- textures ----------------------------------------------------------------------------------------------------- */

/* A runtime texture for spec, updatable; NULL with why (the engine gives no render handle). Waits for the renderer. */
static MycTexture* MycEngineCreate(const MycNative* native, MycSpec* spec, const char** why)
{
    MycTexture* t = calloc(1, sizeof(MycTexture) + sizeof(uint32_t) * 14); /* lint-ok: C5 a texture made, on the frame an apply or the stock needs one */
    if (t == NULL) { *why = "out of memory"; return NULL; }
    uint32_t* view = (uint32_t*)(t + 1);
    int block = spec->kind == MYC_SPEC_SHEET || spec->kind == MYC_SPEC_ALBEDO;
    t->format = block ? (spec->bc1 ? MYC_BC1 : MYC_BC3) : MYC_RGBA32F;
    t->mips = block ? spec->mips : 1;
    t->size = block ? spec->size : (size_t)spec->width * (size_t)spec->height * 16;
    t->width = spec->width;
    t->height = spec->height;
    t->kind = spec->kind;
    t->bc1 = spec->bc1;
    view[0] = t->format;
    view[2] = (uint32_t)t->width;
    view[3] = (uint32_t)t->height;
    view[4] = 1;
    view[5] = 1;
    view[6] = (uint32_t)t->mips;
    t->handle = native->create((uint32_t)t->size, MYC_UPDATABLE, MYC_TEXTURE_VIEW, view, spec->data);
    t->object = native->resource(t->handle);
    uint8_t render[4];
    if (t->object == 0 || !vpm_read(t->object, render, 4)) { *why = "no texture object"; native->destroy(t->handle); free(t); return NULL; } /* lint-ok: C5 as above */
    if ((render[0] | render[1] << 8 | render[2] << 16) == 0xFFFFFF) { *why = "no render handle"; native->destroy(t->handle); free(t); return NULL; } /* lint-ok: C5 as above */
    t->spec = myc_spec_hold(spec);
    return t;
}

static void MycEngineUpdate(const MycNative* native, MycTexture* t, MycSpec* spec)
{
    native->update(t->handle, (uint32_t)t->size, spec->data);
    myc_spec_drop(t->previous);
    t->previous = t->spec;
    t->spec = myc_spec_hold(spec);
}

/* ---- the pool ----------------------------------------------------------------------------------------------------- */

void myc_pool_init(MycPool* pool, const MycNative* native)
{
    memset(pool, 0, sizeof *pool);
    pool->native = native;
}

/* What a free texture's list is keyed by: a cape LUT copy is a LUT of its size. */
typedef struct MycShape { int kind, bc1, width, height, mips; size_t size; } MycShape;

static MycShape MycShapeOf(const MycSpec* spec)
{
    return (MycShape){spec->kind == MYC_SPEC_CAPE ? MYC_SPEC_LUT : spec->kind, spec->bc1, spec->width, spec->height, spec->mips,
                      spec->size};
}

static void MycPoolKey(const MycShape* s, char* out, size_t n)
{
    if (s->kind == MYC_SPEC_SHEET) snprintf(out, n, "sheet:%dx%d:%d:%zu", s->width, s->height, s->mips, s->size);
    else if (s->kind == MYC_SPEC_ALBEDO) snprintf(out, n, "albedo:%s%dx%d:%zu", s->bc1 ? "bc1:" : "bc3:", s->width, s->height, s->size);
    else snprintf(out, n, "%d", s->width * 65536 + s->height);
}

static MycPoolList* MycPoolListFor(MycPool* pool, const MycShape* shape)
{
    char key[64];
    MycPoolKey(shape, key, sizeof key);
    for (int i = 0; i < pool->nlists; i++)
        if (strcmp(pool->lists[i].key, key) == 0) return &pool->lists[i];
    if (pool->nlists >= MYC_POOL_LISTS) return NULL;
    MycPoolList* list = &pool->lists[pool->nlists++];
    snprintf(list->key, sizeof list->key, "%s", key);
    return list;
}

void myc_pool_key(const MycSpec* spec, char* out, size_t size)
{
    MycShape shape = MycShapeOf(spec);
    MycPoolKey(&shape, out, size);
}

static MycPoolList* MycPoolSpecList(MycPool* pool, const MycSpec* spec)
{
    MycShape shape = MycShapeOf(spec);
    return MycPoolListFor(pool, &shape);
}

void myc_sizes_add(MycSizes* sizes, MycSpec* spec)
{
    char key[64];
    myc_pool_key(spec, key, sizeof key);
    int at = 0;
    while (at < sizes->n && strcmp(sizes->keys[at], key) != 0) at++;
    if (at == sizes->n && sizes->n < MYC_SIZES)
    {
        sizes->specs[at] = spec;
        memcpy(sizes->keys[at], key, sizeof key);
        sizes->counts[sizes->n++] = 0;
    }
    if (at < sizes->n) sizes->counts[at]++;
}

static void MycPoolSheetNote(MycPool* pool, MycTexture* t, const MycSpec* spec, int refilled)
{
    if (refilled) pool->sheets_refilled++;
    else pool->sheets_made++;
    if (pool->nsheet_notes >= MYC_SHEET_NOTES)
    {
        memmove(pool->sheet_notes[0], pool->sheet_notes[1], sizeof pool->sheet_notes[0] * (MYC_SHEET_NOTES - 1));
        pool->nsheet_notes--;
    }
    char over[64] = "";
    if (refilled) snprintf(over, sizeof over, " over %016llx r%08x", (unsigned long long)t->sheet_name, t->sheet_sum);
    snprintf(pool->sheet_notes[pool->nsheet_notes++], sizeof pool->sheet_notes[0], "Cape sheet %016llx r%08x d%08x (%d mips, %zu bytes): %s%s",
        (unsigned long long)spec->name, spec->recipe_sum, spec->sample, spec->mips, spec->size, refilled ? "refilled" : "made", over);
    t->sheet_name = spec->name;
    t->sheet_sum = spec->recipe_sum;
}

static MycTexture* MycPoolMake(MycPool* pool, MycSpec* spec, const char** why)
{
    MycTexture* t = MycEngineCreate(pool->native, spec, why);
    if (t == NULL) return NULL;
    if (spec->kind == MYC_SPEC_SHEET) MycPoolSheetNote(pool, t, spec, 0);
    pool->made++;
    return t;
}

static void MycPoolPush(MycPoolList* list, MycTexture* t)
{
    t->next = list->first;
    list->first = t;
    list->count++;
}

static MycTexture* MycPoolPop(MycPoolList* list)
{
    MycTexture* t = list->first;
    if (t == NULL) return NULL;
    list->first = t->next;
    t->next = NULL;
    list->count--;
    return t;
}

static int MycPoolBlock(const MycSpec* spec) { return spec->kind == MYC_SPEC_SHEET || spec->kind == MYC_SPEC_ALBEDO; }

MycTexture* myc_pool_take(MycPool* pool, MycSpec* spec, const char** why)
{
    MycPoolList* list = MycPoolSpecList(pool, spec);
    MycTexture* t = list != NULL ? MycPoolPop(list) : NULL;
    if (t != NULL)
    {
        if (t->spec != spec)
        {
            MycEngineUpdate(pool->native, t, spec);
            pool->refilled++;
            if (spec->kind == MYC_SPEC_SHEET) MycPoolSheetNote(pool, t, spec, 1);
        }
        return t;
    }
    t = MycPoolMake(pool, spec, why);
    if (t == NULL || list == NULL || MycPoolBlock(spec)) return t;
    for (int i = 0; i < MYC_POOL_SPARES; i++)
    {
        const char* ignored;
        MycTexture* spare = MycPoolMake(pool, spec, &ignored);
        if (spare == NULL) break;
        MycPoolPush(list, spare);
    }
    return t;
}

void myc_pool_reserve(MycPool* pool, MycSpec* spec, int count)
{
    MycPoolList* list = MycPoolSpecList(pool, spec);
    if (list == NULL || list->count >= count) return;
    int spares = MycPoolBlock(spec) ? 0 : (count > MYC_POOL_SPARES ? count : MYC_POOL_SPARES);
    int want = count - list->count + spares;
    MycTexture* made[256];
    int n = 0;
    for (int i = 0; i < want && n < 256; i++)
    {
        const char* ignored;
        MycTexture* t = MycPoolMake(pool, spec, &ignored);
        if (t == NULL) break;
        made[n++] = t;
    }
    for (int i = n - 1; i >= 0; i--) MycPoolPush(list, made[i]);
}

static void MycPoolDestroy(MycPool* pool, MycTexture* t)
{
    pool->native->destroy(t->handle);
    myc_spec_drop(t->spec);
    myc_spec_drop(t->previous);
    free(t); /* lint-ok: C5 a texture destroyed when the pool holds too many free, RETIRE_FRAMES after its plan changed */
}

void myc_pool_give(MycPool* pool, MycTexture* t)
{
    myc_spec_drop(t->previous);
    t->previous = NULL;
    MycShape shape = {t->kind == MYC_SPEC_CAPE ? MYC_SPEC_LUT : t->kind, t->bc1, t->width, t->height, t->mips, t->size};
    MycPoolList* list = MycPoolListFor(pool, &shape);
    int max = t->kind == MYC_SPEC_SHEET ? MYC_POOL_MAX_FREE_SHEETS : (t->kind == MYC_SPEC_ALBEDO ? MYC_POOL_MAX_FREE_ALBEDOS : MYC_POOL_MAX_FREE);
    if (list == NULL || list->count >= max)
    {
        MycPoolDestroy(pool, t);
        pool->destroyed++;
        return;
    }
    MycPoolPush(list, t);
}

int myc_pool_free_count(const MycPool* pool)
{
    int n = 0;
    for (int i = 0; i < pool->nlists; i++) n += pool->lists[i].count;
    return n;
}

void myc_pool_clear(MycPool* pool)
{
    for (int i = 0; i < pool->nlists; i++)
    {
        MycTexture* t;
        while ((t = MycPoolPop(&pool->lists[i])) != NULL) MycPoolDestroy(pool, t);
    }
    pool->nlists = 0;
}

/* Up to want free textures of spec's size (made with spec's data). */
static void MycPoolFill(MycPool* pool, MycSpec* spec, int want)
{
    MycPoolList* list = MycPoolSpecList(pool, spec);
    while (list != NULL && list->count < want)
    {
        const char* ignored;
        MycTexture* t = MycPoolMake(pool, spec, &ignored);
        if (t == NULL) return;
        MycPoolPush(list, t);
    }
}

static const int kMycPoolSizes[10][2] = {{23, 8}, {23, 7}, {23, 6}, {23, 5}, {23, 4}, {16, 8}, {16, 5}, {16, 3}, {16, 1}, {3, 1}};

/* How many free textures of a size the stock keeps: a sheet's or albedo's as many as the plan has, a LUT size's
 * POOL_STOCK times (at most POOL_MAX_FREE). */
static int MycPoolWant(const MycSpec* spec, int count)
{
    if (MycPoolBlock(spec)) return count;
    return count * MYC_POOL_STOCK < MYC_POOL_MAX_FREE ? count * MYC_POOL_STOCK : MYC_POOL_MAX_FREE;
}

/* Every other LUT size of the game POOL_SPARES + 1 times, made with zeros. */
static void MycPoolSpareSizes(MycPool* pool)
{
    for (int i = 0; i < 10; i++)
    {
        int w = kMycPoolSizes[i][0], h = kMycPoolSizes[i][1];
        MycShape shape = {MYC_SPEC_LUT, 0, w, h, 1, (size_t)w * (size_t)h * 16};
        MycPoolList* list = MycPoolListFor(pool, &shape);
        if (list == NULL || list->count > MYC_POOL_SPARES) continue;
        MycSpec* zeros = myc_spec_new(MYC_SPEC_LUT, w, h, shape.size);
        if (zeros == NULL) continue;
        MycPoolFill(pool, zeros, MYC_POOL_SPARES + 1);
        myc_spec_drop(zeros);
    }
}

int myc_pool_stock(MycPool* pool, const MycSpecs* luts, const MycSpecs* patterns)
{
    static MycSizes sizes;
    int before = pool->made;
    const MycSpecs* kinds[2] = {luts, patterns};
    sizes.n = 0;
    for (int k = 0; k < 2; k++)
        for (int i = 0; i < kinds[k]->n; i++)
            if (kinds[k]->items[i].spec->kind != MYC_SPEC_DIRECT) myc_sizes_add(&sizes, kinds[k]->items[i].spec);
    for (int i = 0; i < sizes.n; i++) MycPoolFill(pool, sizes.specs[i], MycPoolWant(sizes.specs[i], sizes.counts[i]));
    MycPoolSpareSizes(pool);
    return pool->made - before;
}
