/* Match Your Colors: Recolor Weapons' job (recolor.lua Recolor.weapons_job and weapons.lua Weapons.kit), 1:1. A weapon
 * is recolored as a paint scheme of its own: its material classes are analysed through a template scheme's LUTs
 * (DESERT's rows, or DESERT CAMO's when the source has a camo of WEAPON_CAMO_SHARE; a weapon paint scheme as the source
 * is that scheme itself, unplanned) and those rows are planned against the source (the scheme, the cape or the mode's
 * source item). One plan per weapon, kept as an item's plan is. Runs on the worker thread. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_job.h"
#include "myc_weapons.h"

#define WEAPON_CAMO_SHARE 0.15
#define TEMPLATE "desert"
#define CAMO_TEMPLATE "desert_camo"

typedef struct MycTemplate
{
    const char* id;
    uint64_t archive;
    int native;
    MycGroup* camo;
} MycTemplate;

/* ---- the weapon's kit (Weapons.kit) ------------------------------------------------------------------------------- */

static int MycWjLess(const void* x, const void* y) { return strcmp(*(const char* const*)x, *(const char* const*)y); }

static uint64_t MycWjDecal(const char* scheme, const char* key)
{
    for (int i = 0; i < myc_wd_decals_count; i++)
        if (strcmp(myc_wd_decals[i].scheme, scheme) == 0 && strcmp(myc_wd_decals[i].key, key) == 0) return myc_wd_decals[i].lut;
    return 0;
}

static int MycWjFind(const MycOverride* out, int n, uint32_t slot)
{
    for (int i = 0; i < n; i++)
        if (out[i].slot == slot) return i;
    return -1;
}

/* The template's classes of prefix p into out, for slots not taken yet (take_classes). */
static int MycWjTake(MycOverride* out, int n, uint8_t* taken, const MycWeaponPaint* rows, const char* scheme, char p)
{
    for (int i = 0; i < myc_wd_schemes_count && n < 64; i++)
    {
        const MycWdClass* c = &myc_wd_schemes[i];
        if (strcmp(c->scheme, scheme) != 0 || c->key[0] != p) continue;
        uint32_t slot = (uint32_t)strtoul(c->key + 1, NULL, 16);
        int k = MycWjFind(out, n, slot);
        if (k >= 0 && taken[k]) continue;
        uint64_t own = 0;
        for (int r = 0; rows != NULL && rows->has && r < rows->nrows; r++)
            if (rows->rows[r].slot == slot) own = rows->rows[r].lut;
        if (k < 0) k = n++;
        out[k] = (MycOverride){slot, c->lut, 0, own, MycWjDecal(scheme, c->key), 1};
        taken[k] = 1;
    }
    return n;
}

/* A piece's per-slot paint with a template scheme (templated): its rows and their text into the piece. */
static int MycWjTemplated(MycArena* arena, const MycWeaponPaint* rows, const char* scheme, char prefix, char fallback, MycPiece* piece)
{
    MycOverride* out = myc_alloc(arena, sizeof(MycOverride) * 64);
    uint8_t taken[64] = {0};
    if (out == NULL) return 0;
    int n = 0;
    for (int r = 0; rows != NULL && rows->has && r < rows->nrows; r++)
    {
        int k = MycWjFind(out, n, rows->rows[r].slot);
        if (k < 0) k = n++;
        out[k] = (MycOverride){rows->rows[r].slot, rows->rows[r].lut, rows->rows[r].pattern, rows->rows[r].lut, 0, 1};
    }
    n = MycWjTake(out, n, taken, rows, scheme, prefix);
    if (fallback != 0) n = MycWjTake(out, n, taken, rows, scheme, fallback);
    char* parts[64];
    char text[64 * 80];
    size_t at = 0;
    for (int i = 0; i < n; i++)
    {
        char part[80];
        snprintf(part, sizeof part, "%08x=%016llx/%016llx/%016llx/%016llx", out[i].slot, (unsigned long long)out[i].lut,
            (unsigned long long)out[i].pattern, (unsigned long long)out[i].bound, (unsigned long long)out[i].decal);
        parts[i] = myc_strdup(arena, part);
        if (parts[i] == NULL) return 0;
    }
    qsort(parts, (size_t)n, sizeof parts[0], MycWjLess);
    text[0] = 0;
    for (int i = 0; i < n; i++) at += (size_t)snprintf(text + at, sizeof text - at, "%s%s", i ? " " : "", parts[i]);
    piece->overrides = out;
    piece->noverrides = n;
    piece->has_overrides = 1;
    piece->overrides_text = myc_strdup(arena, text);
    return piece->overrides_text != NULL;
}

/* A weapon's own paint rows (no template) into the piece. */
static int MycWjOwn(MycArena* arena, const MycWeaponPaint* rows, MycPiece* piece)
{
    if (rows == NULL || !rows->has) return 1;
    MycOverride* out = myc_alloc(arena, sizeof(MycOverride) * (MYC_OVERRIDE_ROWS + 1));
    if (out == NULL) return 0;
    for (int r = 0; r < rows->nrows; r++) out[r] = (MycOverride){rows->rows[r].slot, rows->rows[r].lut, rows->rows[r].pattern, 0, 0, 0};
    piece->overrides = out;
    piece->noverrides = rows->nrows;
    piece->has_overrides = 1;
    piece->overrides_text = rows->text[0] != 0 ? myc_strdup(arena, rows->text) : NULL;
    return 1;
}

static int MycWjAdd(MycArena* arena, MycKit* kit, const MycWeapon* w, int role, uint64_t path, const MycTemplate* template)
{
    MycPiece* piece = &kit->pieces[kit->npieces++];
    memset(piece, 0, sizeof *piece);
    piece->path = path;
    piece->slot = (uint32_t)role;
    piece->body = MYC_BODY_ANY;
    const MycWeaponPaint* rows = w->overrides[role].has ? &w->overrides[role] : NULL;
    if (template == NULL) return MycWjOwn(arena, rows, piece);
    return MycWjTemplated(arena, rows, template->id, role == 0 ? 'w' : 'a', role == 4 ? 'w' : 0, piece);
}

static MycKit* MycWjKit(MycArena* arena, const MycWeapon* w, uint64_t archive, const MycTemplate* template, uint64_t unit,
    const uint64_t* extra, int nextra)
{
    MycKit* kit = myc_alloc(arena, sizeof(MycKit));
    if (kit == NULL) return NULL;
    kit->pieces = myc_alloc(arena, sizeof(MycPiece) * 5);
    if (kit->pieces == NULL) return NULL;
    if (!MycWjAdd(arena, kit, w, 0, unit != 0 ? unit : w->name, template)) return NULL;
    for (int role = 1; role <= 4; role++)
        if (w->attachments[role] != 0 && !MycWjAdd(arena, kit, w, role, w->attachments[role], template)) return NULL;
    kit->id = (uint32_t)(w->name & 0xFFFFFFFFu);
    kit->archive = archive;
    kit->type = MYC_WEAPON;
    kit->name = w->name;
    for (int i = 0; i < nextra && i < 8; i++) kit->extra[kit->nextra++] = extra[i];
    if (template != NULL) snprintf(kit->template_id, sizeof kit->template_id, "%s", template->id);
    myc_kits_signature(arena, kit);
    return kit;
}

/* ---- the weapons job ---------------------------------------------------------------------------------------------- */

/* The weapons' source: the scheme, the cape or the mode's source item; its key part, or "" with why (none). */
static int MycWjSource(MycJob* j, char* out, size_t size, const char** why)
{
    const MycRequest* r = j->request;
    if (j->scheme != NULL) { snprintf(out, size, "scheme:%s", j->scheme->id); return 1; }
    if (r->mode == MYC_CAPE_SOURCE)
    {
        int got = myc_job_cape_source(j);
        if (got < 0) return -1;
        if (got == 0) { *why = "no cape"; return 0; }
        snprintf(out, size, "%s", j->cape_source_key);
        return 1;
    }
    uint32_t id = r->source_kit != 0 ? r->source_kit : (r->mode == MYC_ARMOR_FROM_HELMET ? r->helmet : r->armor);
    MycKit* kit = myc_catalogue_find(j->p->kits, id, j->err);
    if (kit == NULL) return -1;
    j->source_kit = kit;
    j->source = !myc_job_obsolete(j) ? myc_job_analysis(j, kit) : NULL;
    if (j->err->failed) return -1;
    if (j->source == NULL) { *why = "no source"; return 0; }
    char sum[9];
    myc_records_sum(&kit, 1, sum);
    snprintf(out, size, "%d:%08x:%s", r->mode, kit->id, sum);
    return 1;
}

/* The source's largest camo group of WEAPON_CAMO_SHARE or more, or NULL. */
static MycGroup* MycWjCamo(const MycItem* s)
{
    MycGroup* camo = NULL;
    for (int i = 0; s != NULL && i < s->ngroups; i++)
    {
        MycGroup* g = s->groups[i];
        if (g->camo && g->share >= WEAPON_CAMO_SHARE && (camo == NULL || g->share > camo->share)) camo = g;
    }
    return camo;
}

static int MycWjHasScheme(const char* id)
{
    for (int i = 0; i < myc_wd_schemes_count; i++)
        if (strcmp(myc_wd_schemes[i].scheme, id) == 0) return 1;
    return 0;
}

static int MycWjTemplate(MycJob* j, MycTemplate* out)
{
    const char* id = TEMPLATE;
    memset(out, 0, sizeof *out);
    if (j->scheme != NULL && MycWjHasScheme(j->scheme->id)) { id = j->scheme->id; out->native = 1; }
    else
    {
        out->camo = MycWjCamo(j->s);
        if (out->camo != NULL) id = CAMO_TEMPLATE;
    }
    for (int i = 1; i <= MYC_SCHEMES; i++)
    {
        const MycScheme* scheme = myc_scheme_get(i);
        if (strcmp(scheme->id, id) != 0) continue;
        out->id = scheme->id;
        out->archive = scheme->archive;
        return 1;
    }
    return 0;
}

/* The weapon's package (archive), read once per weapon name and session; 0 none. */
static uint64_t MycWjPackage(MycJob* j, uint64_t name)
{
    MycPipeline* p = j->p;
    void* known = myc_map_get(&p->packages, name);
    if (known != NULL) return (uint64_t)(uintptr_t)known - 1;
    if (p->catalogue_buffer == NULL) p->catalogue_buffer = malloc(MYC_CATALOGUE_BYTES);
    uint64_t package = p->catalogue_buffer != NULL ? myc_weapons_package(name, p->catalogue_buffer) : 0;
    (void)myc_map_put(&p->arena, &p->packages, name, (void*)(uintptr_t)(package + 1));
    return package;
}

/* A weapon's kit in its package (weapon_kit), its preview customization composed first; NULL when it has none. */
static MycKit* MycWjWeaponKit(MycJob* j, MycWeapon* w, const MycTemplate* template)
{
    if (w->has_ids && !w->copy)
    {
        if (j->p->compose_buffer == NULL) j->p->compose_buffer = malloc(MYC_COPY_SPAN);
        const char* why;
        if (j->p->compose_buffer == NULL || !myc_weapons_compose(w, j->p->compose_buffer, &why)) return NULL;
    }
    uint64_t package = MycWjPackage(j, w->name);
    if (package == 0) return NULL;
    uint64_t unit = 0, extra[5];
    int nextra = 0;
    myc_weapon_unit_of(w->name, &unit);
    if (template != NULL) extra[nextra++] = template->archive;
    for (int role = 1; role <= 4; role++)
    {
        uint64_t archive;
        if (w->attachments[role] != 0 && myc_weapon_attachment_archive(w->attachments[role], &archive)) extra[nextra++] = archive;
    }
    MycKit* kit = MycWjKit(&j->arena, w, package, template, unit, extra, nextra);
    if (kit == NULL) myc_fail(j->err, "out of memory (weapon kit)");
    return kit;
}

/* A copy of an analysis LUT as a spec (template_copy). */
static MycSpec* MycWjCopy(const MycLut* lut)
{
    size_t size = (size_t)lut->width * (size_t)lut->height * 16;
    MycSpec* spec = myc_spec_new(MYC_SPEC_LUT, lut->width, lut->height, size);
    if (spec != NULL) memcpy(spec->data, lut->values, size);
    return spec;
}

/* One piece's materials into luts (piece_luts). */
static int MycWjPieceLuts(MycResult* out, const MycAnalysis* a, const MycAPiece* entry, const MycMade* made)
{
    int attachment = entry->piece.slot != 0;
    for (int i = 0; i < entry->nmaterials; i++)
    {
        const MycMaterial* m = &entry->materials[i];
        MycSpec* spec = made != NULL ? myc_spec_hold(myc_specs_get(&made->luts, m->lut)) : NULL;
        const MycLut* own = myc_analysis_lut(a, m->lut);
        if (spec == NULL && m->has_bound && own != NULL) spec = MycWjCopy(own);
        if (spec != NULL && m->lut != 0 && !myc_specs_set(&out->arena, &out->luts, m->has_bound ? m->bound : m->lut, attachment, spec)) return 0;
        if (spec != NULL && m->lut == 0) myc_spec_drop(spec);
        if (!m->has_decal) continue;
        MycSpec* direct = myc_spec_new(MYC_SPEC_DIRECT, 0, 0, 0);
        if (direct == NULL) return 0;
        direct->name = m->decal_to;
        if (!myc_specs_set(&out->arena, &out->luts, m->decal_from, attachment, direct)) return 0;
    }
    return 1;
}

/* One weapon planned into out (weapon_plan): its analysis, or NULL. */
static MycAnalysis* MycWjPlan(MycJob* j, MycWeapon* w, const char* source, const MycTemplate* template, MycResult* out, MycKit** kit_out)
{
    MycKit* kit = MycWjWeaponKit(j, w, template);
    if (kit == NULL) return NULL;
    MycAnalysis* a = myc_job_analysis(j, kit);
    if (a == NULL) return NULL;
    const MycMade* made = NULL;
    if (!(kit->template_id[0] != 0 && template->native))
    {
        char key[MYC_PLAN_KEY], weapon[160];
        snprintf(weapon, sizeof weapon, "weapon:%s", source);
        j->camo = kit->template_id[0] != 0 ? template->camo : NULL;
        myc_job_item_key(j, weapon, kit, key, sizeof key);
        made = myc_job_planned(j, key, &a, 1);
        j->camo = NULL;
        if (made == NULL || !myc_specs_merge(&out->arena, &out->patterns, &made->patterns)) { if (!j->err->failed) myc_fail(j->err, "out of memory"); return NULL; }
    }
    for (int i = 0; i < a->npieces; i++)
        if (!MycWjPieceLuts(out, a, &a->pieces[i], made)) { myc_fail(j->err, "out of memory (weapon LUTs)"); return NULL; }
    *kit_out = kit;
    return a;
}

int myc_weapons_job(MycJob* j, MycResult* out)
{
    MycRequest* r = j->request;
    j->p->stage = "kit catalogue";
    char source[128];
    const char* why = NULL;
    int got = MycWjSource(j, source, sizeof source, &why);
    if (got < 0) return 0;
    if (got == 0) { myc_result_restore(out, j, why); return 1; }
    if (!myc_job_source_item(j)) return 0;
    MycTemplate template;
    int has_template = MycWjTemplate(j, &template);
    size_t at = (size_t)snprintf(out->key, sizeof out->key, "weapons:%s:", source);
    int keys = 0;
    for (int i = 0; i < r->nweapons && !myc_job_obsolete(j); i++)
    {
        MycKit* kit = NULL;
        MycAnalysis* a = MycWjPlan(j, &r->weapons[i], source, has_template ? &template : NULL, out, &kit);
        if (j->err->failed) return 0;
        if (a == NULL) continue;
        if (out->ntargets < MYC_MAX_TARGETS) out->targets[out->ntargets++] = a;
        char sum[9];
        myc_records_sum(&kit, 1, sum);
        at += (size_t)snprintf(out->key + at, sizeof out->key - at, "%s%016llx/%s", keys++ ? "," : "", (unsigned long long)r->weapons[i].name, sum);
    }
    if (myc_job_obsolete(j)) { out->action = MYC_OBSOLETE; return 1; }
    if (out->ntargets == 0) { myc_result_restore(out, j, "no weapon analysed"); return 1; }
    out->action = MYC_APPLY;
    out->first = 0;
    out->last = 0;
    out->target = out->targets[0];
    return 1;
}
