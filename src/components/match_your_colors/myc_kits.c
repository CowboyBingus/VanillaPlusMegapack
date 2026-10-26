/* Match Your Colors: a kit's color rows, built from the game's own files at runtime (kits.lua), 1:1. A kit lists pieces
 * {unit path, slot, type, body, material LUT override, tone variations}. Each piece's unit names its materials; each
 * material names its default LUT and ID mask. Row area = piece weight x ID-mask coverage / materials of the piece;
 * pattern area = piece weight x mask coverage / materials of the piece, per pattern texture. Runs on the worker inside
 * a job. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_albedo.h"
#include "myc_kits.h"
#include "myc_weapons.h"

static uint32_t MycKitU32(const uint8_t* p, uint64_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }
static uint64_t MycKitU64(const uint8_t* p, uint64_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }

const char* myc_kit_type_name(int type)
{
    static const char* const names[4] = {"Armor", "Helmet", "Cape", "Weapon"};
    return type >= 0 && type < 4 ? names[type] : "?";
}

MycLut* myc_analysis_lut(const MycAnalysis* a, uint64_t name)
{
    for (int i = 0; i < a->nluts; i++)
        if (a->luts[i].name == name) return a->luts[i].lut;
    return NULL;
}

int myc_analysis_add_lut(MycArena* arena, MycAnalysis* a, uint64_t name, MycLut* lut)
{
    for (int i = 0; i < a->nluts; i++)
        if (a->luts[i].name == name) { a->luts[i].lut = lut; return 1; }
    if (a->nluts >= a->luts_capacity)
    {
        int capacity = a->luts_capacity < 8 ? 8 : a->luts_capacity * 2;
        MycNamedLut* grown = myc_alloc(arena, sizeof(MycNamedLut) * (size_t)capacity);
        if (grown == NULL) return 0;
        if (a->nluts > 0) memcpy(grown, a->luts, sizeof(MycNamedLut) * (size_t)a->nluts);
        a->luts = grown;
        a->luts_capacity = capacity;
    }
    a->luts[a->nluts++] = (MycNamedLut){name, lut};
    return 1;
}

/* ---- weights ---------------------------------------------------------------------------------------------------- */

double myc_kit_weight(int kit_type, const MycPiece* piece, int body)
{
    static const double armor_slot[10] = {0.0, 0.0, 0.30, 0.12, 0.10, 0.10, 0.06, 0.06, 0.05, 0.05};
    static const double armor_type[3] = {1.0, 0.5, 0.4};
    static const double weapon[5] = {1.0, 0.2, 0.12, 0.05, 0.1};
    if (kit_type == MYC_HELMET)
    {
        if (piece->slot == 0 && piece->type == 0) return 1.0;
        return piece->slot == 0 && piece->type == 2 ? 0.3 : 0.0;
    }
    if (kit_type == MYC_WEAPON) return piece->slot < 5 ? weapon[piece->slot] : 0.0;
    if (piece->body != (uint32_t)body && piece->body != MYC_BODY_ANY) return 0.0;
    return (piece->slot < 10 ? armor_slot[piece->slot] : 0.0) * (piece->type < 3 ? armor_type[piece->type] : 0.0);
}

/* ---- finding and loading textures ---------------------------------------------------------------------------- */

int myc_find(MycFind* find, uint64_t name, uint64_t type, uint64_t* archive, const MycRecord** record, MycErr* err)
{
    for (int i = 0; i < find->count; i++)
    {
        const MycRecord* r = myc_reader_locate(find->reader, find->archives[i], name, type, err);
        if (err->failed) return 0;
        if (r == NULL) continue;
        if (r->patch >= 0 && !myc_reader_touch(find->reader, find->archives[i], name, type, r))
            return myc_fail(err, "out of memory for a patched resource");
        *archive = find->archives[i];
        *record = r;
        return 1;
    }
    return 0;
}

static int MycKitFound(MycFind* find, uint64_t name, uint64_t type, MycErr* err)
{
    uint64_t archive;
    const MycRecord* record;
    return myc_find(find, name, type, &archive, &record, err);
}

/* A texture error with its name and, when a mod's patch served it, the patch file. */
static int MycKitTexError(MycFind* find, uint64_t name, const MycRecord* record, const char* why, MycErr* err)
{
    char hex[17];
    myc_hex(hex, name);
    if (record->patch >= 0)
        return myc_fail(err, "texture %s (from %s): %s", hex, myc_patch_file(find->reader->index, record->patch), why);
    return myc_fail(err, "texture %s: %s", hex, why);
}

int myc_tex_open(MycFind* find, uint64_t name, MycPixels* out, MycErr* err)
{
    uint64_t archive;
    const MycRecord* record;
    if (!myc_find(find, name, MYC_TYPE_TEXTURE, &archive, &record, err)) return err->failed ? -1 : 0;
    uint32_t size = record->size[MYC_MAIN];
    uint8_t* main = myc_scratch(MYC_SCRATCH_MAIN, size);
    if (main == NULL) { myc_fail(err, "out of memory for a texture"); return -1; }
    if (!myc_reader_part(find->reader, record, MYC_MAIN, 0, size, main, err)) return -1;
    MycTexInfo info;
    MycErr why = {0};
    if (myc_tex_describe(main, size, &info, &why) && myc_pixels_init(out, find->reader, record, &info, &why)) return 1;
    MycKitTexError(find, name, record, why.why, err);
    return -1;
}

/* A cached texture entry: 1 known (*value, NULL for a missing one), 0 not known yet. */
static int MycKitKnown(const MycMap* map, uint64_t name, void** value)
{
    void* known = myc_map_get(map, name);
    *value = known == MYC_MISSING ? NULL : known;
    return known != NULL;
}

static int MycKitKeep(MycTextures* t, MycMap* map, uint64_t name, void* value, MycErr* err)
{
    if (!myc_map_put(t->arena, map, name, value != NULL ? value : MYC_MISSING)) return myc_fail(err, "out of memory");
    return 1;
}

MycLut* myc_textures_lut(MycTextures* t, MycFind* find, uint64_t name, MycErr* err)
{
    void* known;
    if (MycKitKnown(&t->luts, name, &known)) return known;
    MycPixels p;
    int got = myc_tex_open(find, name, &p, err);
    if (got < 0) return NULL;
    MycLut* lut = got > 0 ? myc_alloc(t->arena, sizeof *lut) : NULL;
    if (got > 0 && lut == NULL) { myc_fail(err, "out of memory for a LUT"); return NULL; }
    MycErr why = {0};
    if (lut != NULL && !myc_tex_lut(&p, t->arena, lut, &why)) { MycKitTexError(find, name, p.record, why.why, err); return NULL; }
    return MycKitKeep(t, &t->luts, name, lut, err) ? lut : NULL;
}

typedef struct MycCoverage { double values[64]; int channels; } MycCoverage;

const double* myc_textures_coverage(MycTextures* t, MycFind* find, uint64_t name, int* channels, MycErr* err)
{
    void* known;
    MycCoverage* c = NULL;
    *channels = 0;
    if (!MycKitKnown(&t->coverages, name, &known))
    {
        MycPixels p;
        int got = myc_tex_open(find, name, &p, err);
        if (got < 0) return NULL;
        c = got > 0 ? myc_alloc(t->arena, sizeof *c) : NULL;
        const char* why = NULL;
        if (c != NULL) c->channels = myc_tex_coverage(&p, c->values, err, &why);
        if (err->failed) return NULL;
        if (c != NULL && c->channels == 0) c = NULL; /* another format: uniform rows */
        if (!MycKitKeep(t, &t->coverages, name, c, err)) return NULL;
        known = c;
    }
    c = known;
    if (c == NULL) return NULL;
    *channels = c->channels;
    return c->values;
}

MycLut* myc_textures_pattern(MycTextures* t, MycFind* find, uint64_t name, MycErr* err)
{
    void* known;
    if (MycKitKnown(&t->patterns, name, &known)) return known;
    MycPixels p;
    MycErr quiet = {0}; /* a pattern this file cannot describe counts as none */
    int got = myc_tex_open(find, name, &p, &quiet);
    int pattern = got > 0 && (p.info.format == MYC_FMT_RGBA16F || p.info.format == MYC_FMT_RGBA32F) && p.info.width == 3 &&
                  p.info.height == 1;
    MycLut* lut = pattern ? myc_alloc(t->arena, sizeof *lut) : NULL;
    if (pattern && lut == NULL) { myc_fail(err, "out of memory"); return NULL; }
    if (lut != NULL && !myc_tex_lut(&p, t->arena, lut, err)) return NULL;
    return MycKitKeep(t, &t->patterns, name, lut, err) ? lut : NULL;
}

int myc_textures_pattern_coverage(MycTextures* t, MycFind* find, uint64_t name, int layer, double* out, MycErr* err)
{
    char key[40];
    snprintf(key, sizeof key, "%016llx:%d", (unsigned long long)name, layer);
    void* known = myc_smap_get(&t->pattern_coverages, key);
    if (known == MYC_MISSING) return 0;
    if (known != NULL) { *out = *(double*)known; return 1; }
    MycPixels p;
    MycErr quiet = {0};
    int ok = 0;
    double value = myc_tex_open(find, name, &p, &quiet) > 0 ? myc_tex_mask_coverage(&p, layer, MYC_PATTERN_MIP, &ok, err) : 0;
    if (err->failed) return 0;
    double* kept = ok ? myc_alloc(t->arena, sizeof(double)) : NULL;
    if (kept != NULL) *kept = value;
    if (!myc_smap_put(t->arena, &t->pattern_coverages, key, kept != NULL ? (void*)kept : MYC_MISSING))
        return myc_fail(err, "out of memory");
    *out = value;
    return ok;
}

/* ---- units and materials ---------------------------------------------------------------------------------------- */

/* key's place among keys[0..count-1], or -1. */
static int MycKitKeyAt(const uint32_t* keys, int count, uint32_t key)
{
    for (int k = 0; k < count; k++)
        if (keys[k] == key) return k;
    return -1;
}

/* The material hashes of a unit's main part in file order and their slot keys (a repeated key keeps its first
 * position and its last value); how many, -1 after myc_fail. */
static int MycKitUnitMaterials(MycReader* r, const MycRecord* record, uint64_t* materials, uint32_t* keys, MycErr* err)
{
    uint8_t head[116], count_bytes[4];
    if (!myc_reader_part(r, record, MYC_MAIN, 0, 116, head, err)) return -1;
    uint32_t at = MycKitU32(head, 112);
    if (at == 0) return 0;
    if (!myc_reader_part(r, record, MYC_MAIN, at, 4, count_bytes, err)) return -1;
    uint32_t n = MycKitU32(count_bytes, 0);
    uint8_t* map = n <= 4096 ? myc_scratch(MYC_SCRATCH_MAIN, 4 + 12u * n) : NULL;
    if (map == NULL) { myc_fail(err, n > 4096 ? "read outside a resource part" : "out of memory"); return -1; }
    if (!myc_reader_part(r, record, MYC_MAIN, at, 4 + 12 * n, map, err)) return -1;
    int count = 0;
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t key = MycKitU32(map, 4 + 4 * i);
        int seen = MycKitKeyAt(keys, count, key);
        if (seen < 0 && count >= 256) { myc_fail(err, "a unit of more than 256 materials"); return -1; }
        if (seen < 0) { keys[count] = key; seen = count++; }
        materials[seen] = MycKitU64(map, 4 + 4 * n + 8 * i);
    }
    return count;
}

/* slot's place among the material's slots, or -1. */
static int MycKitSlotAt(const MycTexSlots* t, uint32_t slot)
{
    for (int k = 0; k < t->count; k++)
        if (t->slots[k].slot == slot) return k;
    return -1;
}

/* A material's texture slots and its parent (its shader template, +24). */
static int MycKitMaterialTextures(MycReader* r, const MycRecord* record, MycArena* arena, MycTexSlots* out, MycErr* err)
{
    uint8_t head[136];
    if (!myc_reader_part(r, record, MYC_MAIN, 0, 136, head, err)) return 0;
    uint32_t n = MycKitU32(head, 64);
    uint8_t* data = n <= 4096 ? myc_scratch(MYC_SCRATCH_MAIN, 136 + 12u * n) : NULL;
    if (data == NULL) return myc_fail(err, n > 4096 ? "read outside a resource part" : "out of memory");
    if (!myc_reader_part(r, record, MYC_MAIN, 0, 136 + 12 * n, data, err)) return 0;
    out->slots = myc_alloc(arena, sizeof(MycTexSlot) * (n > 0 ? n : 1));
    if (out->slots == NULL) return myc_fail(err, "out of memory");
    out->count = 0;
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t slot = MycKitU32(data, 136 + 4 * i);
        int seen = MycKitSlotAt(out, slot);
        if (seen < 0) { seen = out->count++; out->slots[seen].slot = slot; }
        out->slots[seen].name = MycKitU64(data, 136 + 4 * n + 8 * i);
    }
    out->parent = MycKitU64(head, 24);
    return 1;
}

int myc_tex_slot(const MycTexSlots* t, uint32_t slot, uint64_t* name)
{
    int at = MycKitSlotAt(t, slot);
    if (at < 0) return 0;
    *name = t->slots[at].name;
    return 1;
}

static const MycOverride* MycKitOverride(const MycPiece* piece, uint32_t key)
{
    for (int i = 0; piece->has_overrides && i < piece->noverrides; i++)
        if (piece->overrides[i].slot == key) return &piece->overrides[i];
    return NULL;
}

/* What a material's entry is made of. */
typedef struct MycMatCtx
{
    MycKitDeps* deps;
    const MycPiece* piece;
    const MycRecord* record;
    MycTexSlots t;
    const MycOverride* o;
} MycMatCtx;

/* entry.pattern: the kit piece's pattern texture (a weapon's: its paint's for the material's slot), else the material's
 * default, when found; entry.pattern_mask: the material's pattern mask, when found too. */
static int MycKitPatternTextures(MycMatCtx* m, MycMaterial* e, MycErr* err)
{
    MycFind* find = m->deps->find;
    uint64_t own = (m->o != NULL && m->o->pattern != MYC_NO_NAME) ? m->o->pattern : m->piece->pattern, pattern = own, mask = 0;
    int has = own != MYC_NO_NAME || myc_tex_slot(&m->t, MYC_SLOT_PATTERN, &pattern);
    if (!has || pattern == MYC_NO_NAME) return 1;
    if (!MycKitFound(find, pattern, MYC_TYPE_TEXTURE, err)) return !err->failed;
    e->pattern = pattern;
    e->has_pattern = 1;
    if (!myc_tex_slot(&m->t, MYC_SLOT_PATTERN_MASK, &mask) || mask == MYC_NO_NAME) return 1;
    e->has_pattern_mask = MycKitFound(find, mask, MYC_TYPE_TEXTURE, err);
    e->pattern_mask = mask;
    return !err->failed;
}

/* A mod's material without a LUT: its albedo entry (1), or none (0, why for a mod's material). */
static int MycKitAlbedoEntry(MycMatCtx* m, MycMaterial* e, char* why, MycErr* err)
{
    MycAlbedoEntry a;
    char reason[96];
    int got = myc_albedo_eligible(m->record, &m->t, m->deps->find, &a, reason, sizeof reason, err);
    if (got == 0 && m->record->patch >= 0) snprintf(why, 96, "%s", reason);
    if (got <= 0) return got;
    e->is_albedo = 1;
    e->albedo = a.albedo;
    e->mra = a.mra;
    e->has_mra = a.has_mra;
    return 1;
}

/* The LUT a material is analysed through (the override's, the piece's, else its own) and the one the game binds. */
static uint64_t MycKitEntryLut(const MycMatCtx* m, uint64_t def, MycMaterial* e)
{
    uint64_t lut = m->piece->lut != MYC_NO_NAME ? m->piece->lut : def;
    if (m->o == NULL) return lut;
    if (m->o->lut != MYC_NO_NAME) lut = m->o->lut;
    uint64_t bound = m->o->bound != MYC_NO_NAME ? m->o->bound : def;
    if (m->o->has_bound && bound != lut) { e->bound = bound; e->has_bound = 1; }
    return lut;
}

/* A material's entry: with a LUT 1; a mod's albedo entry 1 (is_albedo); none 0; -1 after myc_fail. */
static int MycKitMaterialEntry(MycMatCtx* m, uint64_t material, MycMaterial* e, char* why, MycErr* err)
{
    memset(e, 0, sizeof *e);
    e->material = material;
    why[0] = 0;
    uint64_t def, own_decal;
    if (!myc_tex_slot(&m->t, MYC_SLOT_LUT, &def)) return MycKitAlbedoEntry(m, e, why, err);
    uint64_t lut = MycKitEntryLut(m, def, e);
    if (!MycKitFound(m->deps->find, lut, MYC_TYPE_TEXTURE, err)) return err->failed ? -1 : 0;
    e->lut = lut;
    e->has_mask = myc_tex_slot(&m->t, MYC_SLOT_MASK, &e->mask);
    int decal = m->o != NULL && m->o->decal != MYC_NO_NAME && myc_tex_slot(&m->t, MYC_SLOT_DECAL, &own_decal);
    if (decal && own_decal != m->o->decal)
    {
        e->decal_from = own_decal;
        e->decal_to = m->o->decal;
        e->has_decal = 1;
    }
    return MycKitPatternTextures(m, e, err) ? 1 : -1;
}

static int MycKitNoteUnread(MycAnalysis* out, MycArena* arena, uint64_t material, const char* file, const char* why)
{
    MycUnread* u = NULL;
    for (int i = 0; i < out->nunread && u == NULL; i++)
        if (out->unread[i].material == material) u = &out->unread[i];
    if (u == NULL)
    {
        MycUnread* grown = myc_alloc(arena, sizeof(MycUnread) * (size_t)(out->nunread + 1));
        if (grown == NULL) return 0;
        if (out->nunread > 0) memcpy(grown, out->unread, sizeof(MycUnread) * (size_t)out->nunread);
        out->unread = grown;
        u = &grown[out->nunread++];
    }
    u->material = material;
    snprintf(u->file, sizeof u->file, "%s", file);
    snprintf(u->why, sizeof u->why, "%s", why);
    return 1;
}

/* A piece's materials being listed. */
typedef struct MycMatList { MycKitDeps* deps; const MycPiece* piece; MycAnalysis* out; MycMaterial* entries; int count; } MycMatList;

/* One material of a piece's unit into the list (counted when it has a LUT or an albedo). */
static int MycKitOneMaterial(MycMatList* l, uint64_t material, uint32_t key, MycErr* err)
{
    uint64_t m_archive, mask_archive;
    const MycRecord* mask_record = NULL;
    MycKitDeps* deps = l->deps;
    MycMatCtx m = {deps, l->piece, NULL, {0}, MycKitOverride(l->piece, key)};
    if (!myc_find(deps->find, material, MYC_TYPE_MATERIAL, &m_archive, &m.record, err)) return !err->failed;
    if (!MycKitMaterialTextures(deps->find->reader, m.record, deps->arena, &m.t, err)) return 0;
    char why[96];
    MycMaterial* e = &l->entries[l->count];
    int got = MycKitMaterialEntry(&m, material, e, why, err);
    if (got < 0) return 0;
    if (got > 0 && !e->is_albedo && e->has_mask)
    {
        int found = myc_find(deps->find, e->mask, MYC_TYPE_TEXTURE, &mask_archive, &mask_record, err);
        e->patched = m.record->patch >= 0 || (found && mask_record->patch >= 0);
    }
    if (got > 0) l->count++;
    const char* file = myc_patch_file(deps->find->reader->index, m.record->patch);
    if (why[0] != 0 && !MycKitNoteUnread(l->out, deps->arena, material, file, why)) return myc_fail(err, "out of memory");
    return !err->failed;
}

/* The materials of one piece that carry a material LUT (or an albedo with the colors), in the unit's order: their
 * count, -2 when the piece's unit is in none of the searched archives, -1 after myc_fail. */
static int MycKitPieceMaterials(MycKitDeps* deps, const MycPiece* piece, MycAnalysis* out, MycMaterial** list,
    int* patched, MycErr* err)
{
    uint64_t archive;
    const MycRecord* record;
    *list = NULL;
    if (!myc_find(deps->find, piece->path, MYC_TYPE_UNIT, &archive, &record, err)) return err->failed ? -1 : -2;
    *patched = record->patch >= 0;
    uint64_t materials[256];
    uint32_t keys[256];
    int n = MycKitUnitMaterials(deps->find->reader, record, materials, keys, err);
    MycMatList l = {deps, piece, out, NULL, 0};
    if (n >= 0) l.entries = myc_alloc(deps->arena, sizeof(MycMaterial) * (size_t)(n > 0 ? n : 1));
    if (n >= 0 && l.entries == NULL) myc_fail(err, "out of memory");
    if (l.entries == NULL) return -1;
    for (int i = 0; i < n; i++)
        if (!MycKitOneMaterial(&l, materials[i], keys[i], err)) return -1;
    *list = l.entries;
    return l.count;
}

/* ---- rows ----------------------------------------------------------------------------------------------------------- */

typedef struct MycAcc
{
    MycSMap index;      /* key -> row index + 1 */
    MycVec rows;        /* MycAccRow */
    MycVec patterns;    /* MycPatternArea, first-seen order */
} MycAcc;
typedef struct MycAccRow { char key[MYC_KEY]; uint64_t lut; int row; double area, under; } MycAccRow;

/* One weighted piece being added: its accumulators, analysis and weight over its materials. */
typedef struct MycPieceCtx
{
    MycAcc* acc;
    MycAnalysis* out;
    MycKitDeps* deps;
    const MycPiece* piece;
    double weight, count;
} MycPieceCtx;

static MycAccRow* MycKitAccRow(MycArena* arena, MycAcc* acc, uint64_t lut, int r)
{
    char key[MYC_KEY];
    myc_row_key(key, lut, r);
    void* known = myc_smap_get(&acc->index, key);
    if (known != NULL) return &MYC_AT(acc->rows, MycAccRow, (intptr_t)known - 1);
    MycAccRow* row = myc_vec_push(arena, &acc->rows, sizeof(MycAccRow));
    if (row == NULL || !myc_smap_put(arena, &acc->index, key, (void*)(intptr_t)acc->rows.count)) return NULL;
    memcpy(row->key, key, MYC_KEY);
    row->lut = lut;
    row->row = r;
    return row;
}

/* A material's rows: area = weight x coverage / count (row 0 always; area 0 where its coverage is 0). */
static int MycKitAddRows(const MycPieceCtx* p, double weight, double count, uint64_t lut_name, const MycLut* lut,
    const double* coverage, int channels)
{
    int n = lut->height;
    int limit = coverage != NULL ? (n < channels ? n : channels) : n;
    for (int r = 0; r < limit; r++)
    {
        double area = weight * (coverage != NULL ? coverage[r] : 1.0 / n) / count;
        if (!(area > 1e-6 || r == 0)) continue;
        MycAccRow* row = MycKitAccRow(p->deps->arena, p->acc, lut_name, r);
        if (row == NULL) return 0;
        row->area = row->area + area;
        if (p->piece->type == MYC_UNDERGARMENT) row->under = row->under + area;
    }
    return 1;
}

static MycPatternArea* MycKitPatternEntry(MycPieceCtx* p, uint64_t pattern, MycLut* lut)
{
    for (int i = 0; i < p->acc->patterns.count; i++)
        if (MYC_AT(p->acc->patterns, MycPatternArea, i).pattern == pattern) return &MYC_AT(p->acc->patterns, MycPatternArea, i);
    MycPatternArea* entry = myc_vec_push(p->deps->arena, &p->acc->patterns, sizeof(MycPatternArea));
    if (entry == NULL || !myc_analysis_add_lut(p->deps->arena, p->out, pattern, lut)) return NULL;
    entry->pattern = pattern;
    return entry;
}

/* One material's pattern area when its pattern is drawn (texel 0 w is a mask layer, not -1). */
static int MycKitAddPattern(MycPieceCtx* p, const MycMaterial* m, MycErr* err)
{
    if (!m->has_pattern || !m->has_pattern_mask) return 1;
    MycLut* pattern = myc_textures_pattern(p->deps->textures, p->deps->find, m->pattern, err);
    if (err->failed || pattern == NULL || pattern->values[3] == -1) return !err->failed;
    double w = pattern->values[3], coverage;
    int layer = (int)(w >= 0 ? floor(w) : ceil(w));
    if (!myc_textures_pattern_coverage(p->deps->textures, p->deps->find, m->pattern_mask, layer, &coverage, err))
        return !err->failed;
    MycPatternArea* entry = MycKitPatternEntry(p, m->pattern, pattern);
    if (entry == NULL) return myc_fail(err, "out of memory");
    entry->area = entry->area + p->weight * coverage / p->count;
    return 1;
}

static MycAlbedo* MycKitAlbedoOf(const MycAnalysis* out, uint64_t name, int* known)
{
    for (int i = 0; i < out->nalbedos; i++)
        if (out->albedos[i].name == name) { *known = 1; return out->albedos[i].albedo; }
    *known = 0;
    return NULL;
}

static MycAlbedo* MycKitReadAlbedo(MycPieceCtx* p, const MycMaterial* m, MycErr* err)
{
    MycAlbedoEntry entry = {m->albedo, m->mra, m->has_mra};
    char why[96];
    MycAlbedo* albedo = myc_albedo_read(p->deps->find, &entry, p->deps->arena, why, sizeof why, err);
    if (err->failed) return NULL;
    MycNamedAlbedo* grown = myc_alloc(p->deps->arena, sizeof(MycNamedAlbedo) * (size_t)(p->out->nalbedos + 1));
    if (grown == NULL) { myc_fail(err, "out of memory"); return NULL; }
    if (p->out->nalbedos > 0) memcpy(grown, p->out->albedos, sizeof(MycNamedAlbedo) * (size_t)p->out->nalbedos);
    grown[p->out->nalbedos++] = (MycNamedAlbedo){m->albedo, albedo};
    p->out->albedos = grown;
    return albedo;
}

/* A material whose albedo holds its colors: its clusters read once per analysis, each a row of area weight x its
 * share / materials (key '<albedo>:<cluster - 1>'). */
static int MycKitAddAlbedo(MycPieceCtx* p, const MycMaterial* m, MycErr* err)
{
    int known;
    MycAlbedo* albedo = MycKitAlbedoOf(p->out, m->albedo, &known);
    if (!known) albedo = MycKitReadAlbedo(p, m, err);
    if (err->failed) return 0;
    for (int k = 0; albedo != NULL && k < albedo->nclusters; k++)
    {
        MycAccRow* row = MycKitAccRow(p->deps->arena, p->acc, m->albedo, k);
        if (row == NULL) return myc_fail(err, "out of memory");
        double area = p->weight * albedo->clusters[k].share / p->count;
        row->area = row->area + area;
        if (p->piece->type == MYC_UNDERGARMENT) row->under = row->under + area;
    }
    return 1;
}

/* A weapon piece's materials as the game draws them (weapon_data.c): per material its share of the piece and its
 * rows' shares; 0 when the table lacks one or a material came from a patch. */
typedef struct MycDrawn { double fraction, shares[8]; } MycDrawn;
static int MycKitWeaponCover(const MycPiece* piece, const MycMaterial* m, int n, MycDrawn* out)
{
    double total = 0, triangles[256];
    if (n > 256) return 0;
    for (int i = 0; i < n; i++)
    {
        if (m[i].is_albedo || m[i].patched || !myc_weapon_rows(piece->path, m[i].material, &triangles[i], out[i].shares)) return 0;
        total += triangles[i];
    }
    if (total <= 0) return 0;
    for (int i = 0; i < n; i++) out[i].fraction = triangles[i] / total;
    return 1;
}

static int MycKitLutMaterial(MycPieceCtx* p, const MycMaterial* m, const MycDrawn* d, MycErr* err)
{
    MycLut* lut = myc_textures_lut(p->deps->textures, p->deps->find, m->lut, err);
    if (lut == NULL) return err->failed ? 0 : myc_fail(err, "material LUT %016llx not found", (unsigned long long)m->lut);
    if (!myc_analysis_add_lut(p->deps->arena, p->out, m->lut, lut)) return myc_fail(err, "out of memory");
    const double* coverage = NULL;
    int channels = 0, ok;
    if (d != NULL) ok = MycKitAddRows(p, p->weight * d->fraction, 1, m->lut, lut, d->shares, 8);
    else
    {
        if (m->has_mask && MycKitFound(p->deps->find, m->mask, MYC_TYPE_TEXTURE, err))
            coverage = myc_textures_coverage(p->deps->textures, p->deps->find, m->mask, &channels, err);
        if (err->failed) return 0;
        ok = MycKitAddRows(p, p->weight, p->count, m->lut, lut, coverage, channels);
    }
    if (!ok) return myc_fail(err, "out of memory");
    return MycKitAddPattern(p, m, err);
}

static int MycKitAddPiece(MycAcc* acc, MycAnalysis* out, MycKit* kit, const MycPiece* piece, MycKitDeps* deps, MycErr* err)
{
    MycAPiece* entry = &out->pieces[out->npieces++];
    entry->piece = *piece;
    entry->weight = myc_kit_weight(kit->type, piece, out->body);
    entry->skin = piece->tone > 0;
    if (!(piece->body == (uint32_t)out->body || piece->body == MYC_BODY_ANY || kit->type == MYC_HELMET)) return 1;
    int patched = 0;
    int n = MycKitPieceMaterials(deps, piece, out, &entry->materials, &patched, err);
    if (n == -2) out->dropped++;
    if (n < 0) return n == -2;
    entry->nmaterials = n;
    if (entry->weight <= 0) return 1;
    static MycDrawn drawn[256];
    int is_drawn = kit->type == MYC_WEAPON && !patched && MycKitWeaponCover(piece, entry->materials, n, drawn);
    MycPieceCtx p = {acc, out, deps, piece, entry->weight, n};
    for (int i = 0; i < n; i++)
    {
        const MycMaterial* m = &entry->materials[i];
        int ok = m->is_albedo ? MycKitAddAlbedo(&p, m, err) : MycKitLutMaterial(&p, m, is_drawn ? &drawn[i] : NULL, err);
        if (!ok) return 0;
    }
    if (is_drawn) out->drawn++;
    return 1;
}

double myc_kits_emissive(const MycLut* lut, int r)
{
    if (lut->width <= 13) return 0;
    return lut->values[((size_t)r * lut->width + 13) * 4];
}

int myc_kits_lut_row(MycModel* model, const MycLut* lut, int r, int weapon, MycRow* row, MycErr* err)
{
    if (lut->width < MYC_LUT_COLUMNS - 1) return myc_fail(err, "material LUT of %d columns", lut->width);
    const float* values = lut->values;
    int at = r;
    static float copy[MYC_MAX_COLUMNS * 4];
    int bias = weapon && lut->values[((size_t)r * lut->width + 6) * 4 + 3] > MYC_WEAPON_BIAS && lut->width <= MYC_MAX_COLUMNS;
    if (bias)
    {
        memcpy(copy, lut->values + (size_t)r * lut->width * 4, sizeof(float) * (size_t)lut->width * 4);
        copy[6 * 4 + 3] = 0;
        values = copy;
        at = 0;
    }
    MycRowInfo info = myc_row_info(model, values, lut->width, at);
    row->L = info.L;
    row->a = info.a;
    row->b = info.b;
    row->metal = info.metal;
    row->camo = info.camo;
    row->mode = info.mode;
    row->full = info.full;
    row->ar = info.ar;
    row->ag = info.ag;
    row->ab = info.ab;
    row->emissive = myc_kits_emissive(lut, r);
    return 1;
}

static void MycKitAlbedoRow(const MycAlbedo* albedo, int r, MycRow* row)
{
    const MycCluster* c = &albedo->clusters[r];
    row->L = c->seen[0];
    row->a = c->seen[1];
    row->b = c->seen[2];
    row->metal = c->metal > 0.5;
    row->camo = 0;
    row->mode = 0;
    row->full = c->metal >= 0.9;
    row->ar = c->lin[0];
    row->ag = c->lin[1];
    row->ab = c->lin[2];
    row->emissive = 0;
    row->albedo = 1;
}

static int MycKitRow(MycAnalysis* out, const MycAccRow* a, MycKitDeps* deps, MycErr* err)
{
    MycRow* row = &out->rows[out->nrows++];
    MycLut* lut = myc_analysis_lut(out, a->lut);
    int known;
    if (lut != NULL && !myc_kits_lut_row(deps->model, lut, a->row, out->kit->type == MYC_WEAPON, row, err)) return 0;
    if (lut == NULL) MycKitAlbedoRow(MycKitAlbedoOf(out, a->lut, &known), a->row, row);
    memcpy(row->key, a->key, MYC_KEY);
    row->lut = a->lut;
    row->row = a->row;
    row->area = a->area;
    row->under = a->under;
    row->finish_changed = -1;
    return 1;
}

MycAnalysis* myc_kits_analyse(MycKit* kit, int body, MycKitDeps* deps, MycErr* err)
{
    MycAnalysis* out = myc_alloc(deps->arena, sizeof *out);
    MycAcc acc;
    memset(&acc, 0, sizeof acc);
    if (out != NULL) out->pieces = myc_alloc(deps->arena, sizeof(MycAPiece) * (size_t)(kit->npieces > 0 ? kit->npieces : 1));
    if (out == NULL || out->pieces == NULL) { myc_fail(err, "out of memory"); return NULL; }
    out->kit = kit;
    out->body = body;
    for (int i = 0; i < kit->npieces; i++)
        if (!MycKitAddPiece(&acc, out, kit, &kit->pieces[i], deps, err)) return NULL;
    out->rows = myc_alloc(deps->arena, sizeof(MycRow) * (size_t)(acc.rows.count > 0 ? acc.rows.count : 1));
    if (out->rows == NULL) { myc_fail(err, "out of memory"); return NULL; }
    for (int i = 0; i < acc.rows.count; i++)
        if (!MycKitRow(out, &MYC_AT(acc.rows, MycAccRow, i), deps, err)) return NULL;
    out->patterns = acc.patterns.items;
    out->npatterns = acc.patterns.count;
    return out;
}

/* ---- the shared samples ------------------------------------------------------------------------------------------ */

static int MycKitSamplesOf(MycReader* reader, const MycRecord* record, uint32_t mip, MycArena* arena, double** layers,
    int* count, MycErr* err)
{
    uint32_t size = record->size[MYC_MAIN];
    uint8_t* main = myc_scratch(MYC_SCRATCH_MAIN, size);
    MycTexInfo info;
    MycPixels p;
    if (main == NULL) return myc_fail(err, "out of memory");
    if (!myc_reader_part(reader, record, MYC_MAIN, 0, size, main, err) || !myc_tex_describe(main, size, &info, err) ||
        !myc_pixels_init(&p, reader, record, &info, err))
        return 0;
    *count = myc_tex_samples(&p, mip, MYC_SAMPLES, arena, layers, MYC_MAX_LAYERS, err);
    return *count >= 0;
}

int myc_kits_shared_samples(MycReader* reader, MycArena* arena, MycSamples* out, MycErr* err)
{
    static const uint64_t shared[2] = {0x18235e0c9ec0e636ull, 0xee6b1ba7e22d71edull};
    for (int i = 0; i < 2; i++)
    {
        const MycRecord* detail = myc_reader_locate(reader, shared[i], MYC_DETAIL_TILER, MYC_TYPE_TEXTURE, err);
        const MycRecord* camo = err->failed ? NULL : myc_reader_locate(reader, shared[i], MYC_CAMO_TILER, MYC_TYPE_TEXTURE, err);
        if (err->failed) return -1;
        if (detail == NULL || camo == NULL) continue;
        memset(out, 0, sizeof *out);
        out->archive = shared[i];
        if (!MycKitSamplesOf(reader, detail, 4, arena, out->detail, &out->detail_layers, err) ||
            !MycKitSamplesOf(reader, camo, 2, arena, out->camo, &out->camo_layers, err))
            return -1;
        return 1;
    }
    return 0;
}
