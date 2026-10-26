/* Match Your Colors: the bindings controller (bindings.lua), 1:1. A plan (a job's result) is applied in one frame:
 * pooled runtime textures bound to the target units' materials whose LUT (or pattern, cape LUT, decal sheet, albedo)
 * is one the plan changes, meshes committed; bindings are tracked {unit, mesh, material, slot, vanilla texture} so they
 * can be put back. A plan's textures live until the plan changes or the component pauses; then the vanilla textures go
 * back and the textures go back to the pool RETIRE_FRAMES frames later. Game thread only. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_runtime.h"

#define MAX_SLOTS 6

static uint64_t myc_ctl_meshes[MYC_MAX_UNIT_MATERIALS], myc_ctl_materials[MYC_MAX_UNIT_MATERIALS];
static uint8_t myc_ctl_big[64 * 16];
static MycUnitRef myc_ctl_units[MYC_MAX_UNITS];

/* A plan's vanilla texture objects by the LUT (or pattern) entry they name. */
typedef struct MycVanillaEntry { uint64_t object; int index; } MycVanillaEntry;
typedef struct MycVanillaMap { MycVanillaEntry* items; int n; } MycVanillaMap;
typedef struct MycPlanObjects
{
    MycVanillaMap luts, attached, patterns;
    int any_pattern, any_tint, any_sheet, any_albedo, any_decal;
} MycPlanObjects;
/* One slot to bind on a unit's materials: the slot, which specs (0 LUTs, 1 patterns) and the vanilla maps to look in
 * (attached first on an attachment unit). */
typedef struct MycSlotSpec { uint32_t slot; int patterns, attachment; } MycSlotSpec;

typedef struct MycMeshes { uint64_t* list; int n, capacity; } MycMeshes;

void myc_controller_init(MycController* c, const MycNative* native, MycPool* pool)
{
    memset(c, 0, sizeof *c);
    c->native = native;
    c->pool = pool;
}

void myc_controller_free(MycController* c)
{
    free(c->bindings); /* lint-ok: C5 a squadmate's or card's controller freed once its textures retired */
    free(c->textures); /* lint-ok: C5 as above */
    free(c->retired); /* lint-ok: C5 as above */
    free(c->probe_list); /* lint-ok: C5 as above */
    free(c->waiting); /* lint-ok: C5 as above */
    myc_result_drop(c->result);
    memset(c, 0, sizeof *c);
}

static int MycCtlGrow(void** items, int* capacity, int need, size_t size)
{
    if (need <= *capacity) return 1;
    int grown = *capacity < 16 ? 16 : *capacity * 2;
    while (grown < need) grown *= 2;
    void* p = realloc(*items, size * (size_t)grown); /* lint-ok: C5 an apply's or restore's lists, on the frame a plan is applied or put back */
    if (p == NULL) return 0;
    *items = p;
    *capacity = grown;
    return 1;
}

static void MycCtlProbes(MycController* c)
{
    c->probes = 0;
    if (!MycCtlGrow((void**)&c->probe_list, &c->probes_capacity, c->nbindings + 1, sizeof(int))) return;
    for (int i = 0; i < c->nbindings; i++)
    {
        int seen = 0;
        for (int k = 0; k < c->probes && !seen; k++) seen = c->bindings[c->probe_list[k]].texture == c->bindings[i].texture;
        if (!seen) c->probe_list[c->probes++] = i;
    }
}

int myc_controller_check(MycController* c)
{
    if (c->probes == 0) return 1;
    c->turn = c->turn % c->probes + 1;
    const MycBinding* b = &c->bindings[c->probe_list[c->turn - 1]];
    uint64_t bound = myc_binding(b->material, b->slot);
    return !(bound == b->vanilla && c->native->alive(b->unit) != 0);
}

static void MycCtlMesh(MycMeshes* m, uint64_t mesh)
{
    for (int i = 0; i < m->n; i++)
        if (m->list[i] == mesh) return;
    if (MycCtlGrow((void**)&m->list, &m->capacity, m->n + 1, sizeof(uint64_t))) m->list[m->n++] = mesh;
}

static void MycCtlCommit(MycController* c, MycMeshes* m)
{
    for (int i = 0; i < m->n; i++) c->native->commit(m->list[i]);
    free(m->list); /* lint-ok: C5 an apply's or restore's meshes, on that frame */
    memset(m, 0, sizeof *m);
}

/* The vanilla texture back on each binding not taken over whose material, on a live unit, still holds its texture. */
static void MycCtlPutBack(MycController* c, MycBinding* bindings, int n)
{
    MycMeshes meshes = {0};
    for (int i = 0; i < n; i++)
    {
        const MycBinding* b = &bindings[i];
        if (b->taken || c->native->alive(b->unit) == 0 || myc_binding(b->material, b->slot) != b->texture) continue;
        c->native->set_resource(b->material, b->slot, b->vanilla);
        MycCtlMesh(&meshes, b->mesh);
        c->restored++;
    }
    MycCtlCommit(c, &meshes);
}

/* Every current texture retired; the bindings forgotten and returned (the caller frees them). */
static MycBinding* MycCtlRetire(MycController* c, uint32_t frame, int* n)
{
    for (int i = 0; i < c->ntextures; i++)
    {
        MycTexture* t = c->textures[i].texture;
        t->retired_at = frame;
        if (MycCtlGrow((void**)&c->retired, &c->retired_capacity, c->nretired + 1, sizeof(MycTexture*))) c->retired[c->nretired++] = t;
    }
    MycBinding* old = c->bindings;
    *n = c->nbindings;
    c->bindings = NULL;
    c->nbindings = c->bindings_capacity = 0;
    c->ntextures = 0;
    c->has_key = 0;
    c->key[0] = 0;
    myc_result_drop(c->result);
    c->result = NULL;
    MycCtlProbes(c);
    return old;
}

void myc_controller_restore(MycController* c, uint32_t frame)
{
    int n;
    MycBinding* old = MycCtlRetire(c, frame, &n);
    MycCtlPutBack(c, old, n);
    free(old); /* lint-ok: C5 a restore's bindings, on the frame it puts them back */
}

int myc_controller_collect(MycController* c, uint32_t frame)
{
    int keep = 0;
    for (int i = 0; i < c->nretired; i++)
    {
        MycTexture* t = c->retired[i];
        if (frame - t->retired_at >= MYC_RETIRE_FRAMES)
        {
            if (t->direct) free(t); /* lint-ok: C5 a retired direct texture, RETIRE_FRAMES after its plan changed */
            else myc_pool_give(c->pool, t);
            c->released++;
        }
        else c->retired[keep++] = t;
    }
    c->nretired = keep;
    return keep;
}

void myc_controller_prune(MycController* c)
{
    int dead = 0, keep = 0;
    uint32_t* units = calloc((size_t)c->nbindings + 1, sizeof(uint32_t) * 2); /* lint-ok: C5 a prune after new units (a chain check that saw a change), never on an idle frame */
    int nunits = 0;
    if (units == NULL) return;
    for (int i = 0; i < c->nbindings; i++)
    {
        int k = 0;
        while (k < nunits && units[2 * k] != c->bindings[i].unit) k++;
        if (k == nunits)
        {
            units[2 * k] = c->bindings[i].unit;
            units[2 * k + 1] = c->native->alive(c->bindings[i].unit) != 0;
            dead |= !units[2 * k + 1];
            nunits++;
        }
    }
    for (int i = 0; dead && i < c->nbindings; i++)
    {
        int k = 0;
        while (units[2 * k] != c->bindings[i].unit) k++;
        if (units[2 * k + 1]) c->bindings[keep++] = c->bindings[i];
    }
    free(units); /* lint-ok: C5 as above */
    if (!dead) return;
    c->nbindings = keep;
    MycCtlProbes(c);
}

/* ---- binding -------------------------------------------------------------------------------------------------------- */

static int MycCtlOwned(const MycController* c, uint64_t object)
{
    for (int i = 0; i < c->ntextures; i++)
        if (c->textures[i].texture->object == object) return 1;
    for (int i = 0; i < c->nretired; i++)
        if (c->retired[i]->object == object) return 1;
    return 0;
}

static const MycSpecs* MycCtlSpecs(const MycController* c, int patterns)
{
    return patterns ? &c->result->patterns : &c->result->luts;
}

/* The entry of specs a vanilla object names (attached first for an attachment unit's LUT slots), or -1. */
static int MycCtlNamed(const MycPlanObjects* v, int patterns, int attachment, uint64_t object)
{
    const MycVanillaMap* maps[2] = {patterns ? &v->patterns : (attachment ? &v->attached : &v->luts), patterns || !attachment ? NULL : &v->luts};
    for (int m = 0; m < 2; m++)
        for (int i = 0; maps[m] != NULL && i < maps[m]->n; i++)
            if (maps[m]->items[i].object == object) return maps[m]->items[i].index;
    return -1;
}

/* The runtime texture for entry index of specs (from the pool on first use; a direct one the game's own, NULL while
 * it is not loaded); NULL with why on an error. */
static MycTexture* MycCtlTexture(MycController* c, int patterns, int index, char* why, size_t size)
{
    const MycNamedSpec* e = &MycCtlSpecs(c, patterns)->items[index];
    for (int i = 0; i < c->ntextures; i++)
        if (c->textures[i].name == e->name && c->textures[i].attachment == e->attachment) return c->textures[i].texture;
    MycTexture* t;
    if (e->spec->kind == MYC_SPEC_DIRECT)
    {
        uint64_t object = myc_texture_object(c->native, e->spec->name);
        if (object == 0) return NULL;
        t = calloc(1, sizeof *t); /* lint-ok: C5 an apply's direct texture (a weapon scheme's decal sheet), on the frame it binds */
        if (t == NULL) { snprintf(why, size, "out of memory"); return NULL; }
        t->object = object;
        t->direct = 1;
    }
    else
    {
        const char* reason = NULL;
        t = myc_pool_take(c->pool, e->spec, &reason);
        if (t == NULL) { snprintf(why, size, "texture for %016llx: %s", (unsigned long long)e->name, reason); return NULL; }
    }
    if (!MycCtlGrow((void**)&c->textures, &c->textures_capacity, c->ntextures + 1, sizeof(MycNamedTexture)))
    {
        snprintf(why, size, "out of memory");
        return NULL;
    }
    c->textures[c->ntextures++] = (MycNamedTexture){e->name, e->attachment, t};
    return t;
}

static int MycCtlAdd(MycController* c, const MycBinding* b)
{
    if (!MycCtlGrow((void**)&c->bindings, &c->bindings_capacity, c->nbindings + 1, sizeof(MycBinding))) return 0;
    c->bindings[c->nbindings++] = *b;
    return 1;
}

/* The bindings of the plan before (an apply's), by material and slot. */
typedef struct MycBefore { MycBinding* list; int n; } MycBefore;

static MycBinding* MycCtlOld(const MycBefore* before, uint64_t material, uint32_t slot)
{
    MycBinding* found = NULL;
    for (int i = 0; before != NULL && i < before->n; i++)
        if (before->list[i].material == material && before->list[i].slot == slot) found = &before->list[i];
    return found;
}

typedef struct MycBindCtx
{
    MycController* c;
    const MycPlanObjects* v;
    const MycBefore* before;
    MycMeshes meshes;
    MycWaiting* waiting;
    int nwaiting, waiting_capacity, error;
    char* why;
    size_t why_size;
} MycBindCtx;

static void MycCtlWait(MycBindCtx* x, const MycUnitRef* u, uint64_t mesh, uint64_t material, const MycSlotSpec* s)
{
    if (!MycCtlGrow((void**)&x->waiting, &x->waiting_capacity, x->nwaiting + 1, sizeof(MycWaiting))) return;
    x->waiting[x->nwaiting++] = (MycWaiting){u->unit, mesh, material, s->slot, s->patterns, s->attachment};
}

/* Binds the planned texture to one slot of a material when its vanilla texture is one the plan changes (bind_slot). */
static int MycCtlBindSlot(MycBindCtx* x, const MycUnitRef* u, uint64_t mesh, uint64_t material, int held, const MycSlotSpec* s)
{
    MycController* c = x->c;
    uint64_t bound = myc_binding_in(myc_ctl_big, held, s->slot);
    MycBinding* old = bound != 0 ? MycCtlOld(x->before, material, s->slot) : NULL;
    if (old != NULL && old->texture != bound) old = NULL;
    uint64_t original = old != NULL ? old->vanilla : bound;
    int index = original != 0 ? MycCtlNamed(x->v, s->patterns, s->attachment, original) : -1;
    if (index < 0)
    {
        if (bound != 0 && !MycCtlOwned(c, bound)) MycCtlWait(x, u, mesh, material, s);
        return 0;
    }
    MycTexture* t = MycCtlTexture(c, s->patterns, index, x->why, x->why_size);
    if (t == NULL) { x->error |= x->why[0] != 0; return 0; }
    c->native->set_resource(material, s->slot, t->object);
    if (old != NULL) old->taken = 1;
    MycBinding b = {u->unit, mesh, material, s->slot, original, t->object, 0};
    return MycCtlAdd(c, &b);
}

/* The slots a unit's materials take (bind_unit's list). */
static int MycCtlSlots(const MycPlanObjects* v, const MycUnitRef* u, MycSlotSpec* out)
{
    int n = 0;
    out[n++] = (MycSlotSpec){MYC_LUT_SLOT, 0, u->attachment};
    if (v->any_pattern) out[n++] = (MycSlotSpec){MYC_PATTERN_SLOT, 1, 0};
    if (u->any && v->any_decal) out[n++] = (MycSlotSpec){MYC_DECAL_SLOT, 0, u->attachment};
    if (!u->any && u->slot == 1)
    {
        if (v->any_tint) out[n++] = (MycSlotSpec){MYC_CAPE_LUT_SLOT, 0, 0};
        if (v->any_sheet) out[n++] = (MycSlotSpec){MYC_DECAL_SLOT, 0, 0};
    }
    if (v->any_albedo) out[n++] = (MycSlotSpec){MYC_ALBEDO_SLOT, 0, 0};
    return n;
}

/* One unit's materials bound; *materials how many it has. */
static int MycCtlBindUnit(MycBindCtx* x, const MycUnitRef* u, int* materials)
{
    MycSlotSpec slots[MAX_SLOTS];
    int nslots = MycCtlSlots(x->v, u, slots), count = 0;
    *materials = myc_unit_materials(x->c->native, u->unit, myc_ctl_meshes, myc_ctl_materials);
    for (int m = 0; m < *materials && !x->error; m++)
    {
        uint64_t array;
        int held = myc_bindings(myc_ctl_materials[m], myc_ctl_big, &array);
        if (held == 0) continue;
        int bound = 0;
        for (int s = 0; s < nslots && !x->error; s++) bound += MycCtlBindSlot(x, u, myc_ctl_meshes[m], myc_ctl_materials[m], held, &slots[s]);
        if (bound > 0) MycCtlMesh(&x->meshes, myc_ctl_meshes[m]);
        count += bound;
    }
    return count;
}

/* ---- the plan's vanilla textures ------------------------------------------------------------------------------------ */

static void MycCtlVanillaFree(MycPlanObjects* v)
{
    free(v->luts.items); /* lint-ok: C5 an apply's plan objects, on that frame */
    free(v->attached.items); /* lint-ok: C5 as above */
    free(v->patterns.items); /* lint-ok: C5 as above */
}

static int MycCtlVanillaOf(const MycController* c, const MycResult* r, MycPlanObjects* v)
{
    memset(v, 0, sizeof *v);
    v->luts.items = calloc((size_t)r->luts.n + 1, sizeof(MycVanillaEntry)); /* lint-ok: C5 as above */
    v->attached.items = calloc((size_t)r->luts.n + 1, sizeof(MycVanillaEntry)); /* lint-ok: C5 as above */
    v->patterns.items = calloc((size_t)r->patterns.n + 1, sizeof(MycVanillaEntry)); /* lint-ok: C5 as above */
    if (v->luts.items == NULL || v->attached.items == NULL || v->patterns.items == NULL) return 0;
    for (int i = 0; i < r->luts.n; i++)
    {
        const MycNamedSpec* e = &r->luts.items[i];
        uint64_t object = myc_texture_object(c->native, e->name);
        MycVanillaMap* map = e->attachment ? &v->attached : &v->luts;
        if (object != 0) map->items[map->n++] = (MycVanillaEntry){object, i};
        int kind = e->spec->kind;
        v->any_tint |= kind == MYC_SPEC_CAPE;
        v->any_sheet |= kind == MYC_SPEC_SHEET;
        v->any_albedo |= kind == MYC_SPEC_ALBEDO;
        v->any_decal |= kind == MYC_SPEC_DIRECT;
    }
    for (int i = 0; i < r->patterns.n; i++)
    {
        uint64_t object = myc_texture_object(c->native, r->patterns.items[i].name);
        if (object != 0) v->patterns.items[v->patterns.n++] = (MycVanillaEntry){object, i};
    }
    v->any_pattern = v->patterns.n > 0;
    return 1;
}

/* Whether the controller holds a texture for a plan entry already. */
static int MycCtlHeld(const MycController* c, const MycNamedSpec* e)
{
    for (int k = 0; k < c->ntextures; k++)
        if (c->textures[k].name == e->name && c->textures[k].attachment == e->attachment) return 1;
    return 0;
}

/* Room in the pool for the textures this apply can take, per size (reserve). */
static void MycCtlReserve(MycController* c, const MycResult* r, const MycPlanObjects* v)
{
    const MycVanillaMap* maps[3] = {&v->luts, &v->patterns, &v->attached};
    static MycSizes sizes;
    sizes.n = 0;
    for (int m = 0; m < 3; m++)
        for (int i = 0; i < maps[m]->n; i++)
        {
            const MycNamedSpec* e = &(m == 1 ? &r->patterns : &r->luts)->items[maps[m]->items[i].index];
            if (!MycCtlHeld(c, e) && e->spec->kind != MYC_SPEC_DIRECT) myc_sizes_add(&sizes, e->spec);
        }
    for (int k = 0; k < sizes.n; k++) myc_pool_reserve(c->pool, sizes.specs[k], sizes.counts[k]);
}

/* ---- apply ----------------------------------------------------------------------------------------------------------- */

static int MycCtlPieceKey(const MycResult* r, int type, int slot, uint32_t body)
{
    for (int t = 0; t < r->ntargets; t++)
    {
        const MycAnalysis* a = r->targets[t];
        for (int i = 0; i < a->npieces; i++)
        {
            const MycPiece* p = &a->pieces[i].piece;
            int spawned = p->body == body || p->body == MYC_BODY_ANY || a->kit->type == MYC_HELMET;
            if ((int)p->type == type && (int)p->slot == slot && spawned && a->pieces[i].nmaterials > 0) return 1;
        }
    }
    return 0;
}

static int MycCtlUnits(const MycResult* r, const MycApplyTo* to, MycUnitRef* out)
{
    if (to->fixed)
    {
        memcpy(out, to->units, sizeof(MycUnitRef) * (size_t)to->nunits);
        return to->nunits;
    }
    MycIdentity id;
    memset(&id, 0, sizeof id);
    id.units_at = to->units_at;
    return myc_avatar_units(&id, to->slot, r->first, r->last, out, MYC_MAX_UNITS);
}

static int MycCtlOnly(const uint32_t* only, int n, uint32_t unit)
{
    for (int i = 0; i < n; i++)
        if (only[i] == unit) return 1;
    return 0;
}

/* The plan's target units bound (bind_units): bindings made; units without materials into pending; -1 on an error. */
static int MycCtlBindUnits(MycBindCtx* x, const MycApplyTo* to, const uint32_t* only, int nonly, uint32_t* pending, int* npending)
{
    const MycResult* r = x->c->result;
    MycCtlReserve(x->c, r, x->v);
    int n = MycCtlUnits(r, to, myc_ctl_units), count = 0;
    *npending = 0;
    for (int i = 0; i < n && !x->error; i++)
    {
        const MycUnitRef* u = &myc_ctl_units[i];
        if (!(u->any || MycCtlPieceKey(r, u->type, u->slot, to->body)) || (only != NULL && !MycCtlOnly(only, nonly, u->unit))) continue;
        int materials;
        count += MycCtlBindUnit(x, u, &materials);
        if (materials == 0 && *npending < MYC_MAX_UNITS) pending[(*npending)++] = u->unit;
    }
    MycCtlCommit(x->c, &x->meshes);
    return x->error ? -1 : count;
}

static void MycCtlPending(MycController* c, const MycApplyTo* to, uint32_t frame, const uint32_t* pending, int npending,
    MycWaiting* waiting, int nwaiting)
{
    free(c->waiting); /* lint-ok: C5 an apply's waiting slots, on that frame */
    c->waiting = waiting;
    c->nwaiting = c->waiting_capacity = nwaiting;
    memcpy(c->pending_units, pending, sizeof(uint32_t) * (size_t)npending);
    c->npending_units = npending;
    c->has_pending = npending > 0 || nwaiting > 0;
    c->pending_to = *to;
    c->pending_since = frame;
}

int myc_controller_apply(MycController* c, MycResult* result, const MycApplyTo* to, uint32_t frame, char* why, size_t size)
{
    why[0] = 0;
    if (result->action == MYC_RESTORE) { myc_controller_restore(c, frame); return 0; }
    MycBefore before = {NULL, 0};
    int replaced = !c->has_key || strcmp(c->key, result->key) != 0;
    if (replaced) before.list = MycCtlRetire(c, frame, &before.n);
    snprintf(c->key, sizeof c->key, "%s", result->key);
    c->has_key = 1;
    MycResult* held = myc_result_hold(result);
    myc_result_drop(c->result);
    c->result = held;
    MycPlanObjects v;
    MycBindCtx x;
    memset(&x, 0, sizeof x);
    x.c = c;
    x.v = &v;
    x.before = replaced ? &before : NULL;
    x.why = why;
    x.why_size = size;
    static uint32_t pending[MYC_MAX_UNITS];
    int npending = 0;
    int count = MycCtlVanillaOf(c, result, &v) ? MycCtlBindUnits(&x, to, NULL, 0, pending, &npending) : -1;
    if (count < 0 && why[0] == 0) snprintf(why, size, "out of memory");
    MycCtlVanillaFree(&v);
    if (replaced) { MycCtlPutBack(c, before.list, before.n); free(before.list); } /* lint-ok: C5 an apply, on that frame */
    if (count < 0) { free(x.waiting); return -1; } /* lint-ok: C5 as above */
    MycCtlPending(c, to, frame, pending, npending, x.waiting, x.nwaiting);
    myc_controller_prune(c);
    MycCtlProbes(c);
    c->applied += count;
    return count;
}

/* ---- settle ---------------------------------------------------------------------------------------------------------- */

/* One waiting slot read again: done (bound, its unit gone, or one of ours there); *bound whether it bound. */
static int MycCtlRetrySlot(MycBindCtx* x, const MycWaiting* e, int* bound)
{
    MycController* c = x->c;
    *bound = 0;
    if (c->native->alive(e->unit) == 0) return 1;
    uint64_t array;
    int held = myc_bindings(e->material, myc_ctl_big, &array);
    uint64_t object = held > 0 ? myc_binding_in(myc_ctl_big, held, e->slot) : 0;
    int index = object != 0 ? MycCtlNamed(x->v, e->patterns, e->attachment, object) : -1;
    if (index < 0) return object != 0 && MycCtlOwned(c, object);
    MycTexture* t = MycCtlTexture(c, e->patterns, index, x->why, x->why_size);
    if (t == NULL) { x->error |= x->why[0] != 0; return 0; }
    c->native->set_resource(e->material, e->slot, t->object);
    MycBinding b = {e->unit, e->mesh, e->material, e->slot, object, t->object, 0};
    MycCtlAdd(c, &b);
    MycCtlMesh(&x->meshes, e->mesh);
    *bound = 1;
    return 1;
}

/* The old waiting slots tried again after the units' new ones (in x->waiting); bindings made. */
static int MycCtlRetrySlots(MycBindCtx* x, const MycWaiting* old, int nold)
{
    int count = 0;
    for (int i = 0; i < nold && !x->error; i++)
    {
        int bound = 0;
        int done = MycCtlRetrySlot(x, &old[i], &bound);
        if (!done && MycCtlGrow((void**)&x->waiting, &x->waiting_capacity, x->nwaiting + 1, sizeof(MycWaiting)))
            x->waiting[x->nwaiting++] = old[i];
        count += bound;
    }
    MycCtlCommit(x->c, &x->meshes);
    return count;
}

/* The pending units and the waiting slots tried again now (settle's turn): bindings made, or -1 with why. */
static int MycCtlSettleTurn(MycController* c, int* outcome, char* why, size_t size)
{
    MycPlanObjects v;
    MycBindCtx x;
    memset(&x, 0, sizeof x);
    x.c = c;
    x.v = &v;
    x.why = why;
    x.why_size = size;
    static uint32_t still[MYC_MAX_UNITS], only[MYC_MAX_UNITS];
    int nstill = 0, nonly = c->npending_units;
    memcpy(only, c->pending_units, sizeof(uint32_t) * (size_t)nonly);
    int count = MycCtlVanillaOf(c, c->result, &v) ? 0 : -1;
    if (count == 0 && nonly > 0) count = MycCtlBindUnits(&x, &c->pending_to, only, nonly, still, &nstill);
    MycWaiting* old = c->waiting;
    int nold = c->nwaiting;
    if (count >= 0) count += MycCtlRetrySlots(&x, old, nold);
    MycCtlVanillaFree(&v);
    free(old); /* lint-ok: C5 a settle's retried slots, every 4th frame while units are pending after an apply */
    c->waiting = x.waiting;
    c->nwaiting = x.nwaiting;
    c->waiting_capacity = x.waiting_capacity;
    if (count < 0 || x.error) { c->has_pending = 0; if (why[0] == 0) snprintf(why, size, "out of memory"); return -1; }
    memcpy(c->pending_units, still, sizeof(uint32_t) * (size_t)nstill);
    c->npending_units = nstill;
    c->has_pending = nstill > 0 || c->nwaiting > 0;
    if (count > 0) { MycCtlProbes(c); c->applied += count; }
    *outcome = c->has_pending ? 1 : 0;
    return count;
}

int myc_controller_settle(MycController* c, uint32_t frame, int* outcome, char* why, size_t size)
{
    why[0] = 0;
    uint32_t age = frame - c->pending_since;
    *outcome = 1;
    if (age % MYC_PENDING_EVERY != 0) return 0;
    if (age > MYC_PENDING_FRAMES || c->result == NULL)
    {
        *outcome = c->npending_units > 0 ? 2 : 0;
        c->has_pending = 0;
        return 0;
    }
    return MycCtlSettleTurn(c, outcome, why, size);
}
