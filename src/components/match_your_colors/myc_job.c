/* Match Your Colors: the job (recolor.lua Recolor.job), 1:1: from a request (mode, options, kits) to a result (restore,
 * or apply: LUTs, patterns, the slot range, the target analyses and the kit signatures). Reads the kits from game memory,
 * analyses them (kept for the session, the disk cache), plans the match, builds the new LUT data. Each plan is made once
 * and kept (PLANS_KEPT). Runs on the worker thread; a request the game thread marked obsolete ends at the next stage
 * boundary. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_job.h"

/* ---- results ------------------------------------------------------------------------------------------------------ */

MycResult* myc_result_new(void) { return calloc(1, sizeof(MycResult)); }

MycResult* myc_result_hold(MycResult* r)
{
    if (r != NULL) r->refs++;
    return r;
}

void myc_result_drop(MycResult* r)
{
    if (r == NULL || --r->refs > 0) return;
    myc_specs_drop(&r->luts);
    myc_specs_drop(&r->patterns);
    myc_arena_free(&r->arena);
    free(r);
}

int myc_job_obsolete(const MycJob* j) { return j->request->obsolete != 0; }

void myc_result_restore(MycResult* r, const MycJob* j, const char* reason)
{
    r->action = j != NULL && myc_job_obsolete(j) ? MYC_OBSOLETE : MYC_RESTORE;
    snprintf(r->reason, sizeof r->reason, "%s", reason);
}

/* ---- keys --------------------------------------------------------------------------------------------------------- */

/* A kit's part of records_sum: its signature's byte sum s, the sum of its running sums t and its length n. */
static void MycJobSumPart(MycKit* kit, uint32_t* s, uint32_t* t, uint32_t* n)
{
    if (!kit->has_sum)
    {
        const char* text = kit->signature != NULL ? kit->signature : "";
        uint32_t a = 0, b = 0;
        size_t len = strlen(text);
        for (size_t i = 0; i < len; i++)
        {
            a = (a + (uint8_t)text[i]) % 65521;
            b = (b + a) % 65521;
        }
        kit->sum_s = a;
        kit->sum_t = b;
        kit->sum_n = (uint32_t)len;
        kit->has_sum = 1;
    }
    *s = kit->sum_s;
    *t = kit->sum_t;
    *n = kit->sum_n;
}

void myc_records_sum(MycKit* const* kits, int n, char out[9])
{
    uint64_t a = 1, b = 0;
    for (int i = 0; i < n; i++)
    {
        uint32_t s, t, len;
        MycJobSumPart(kits[i], &s, &t, &len);
        uint64_t old = a;
        a = (old + s) % 65521;
        b = (b + (uint64_t)len * old + t) % 65521;
    }
    snprintf(out, 9, "%08x", (uint32_t)(b * 65536 + a));
}

static void MycJobRecords(MycKit* kit, char out[9])
{
    MycKit* list[1] = {kit};
    myc_records_sum(list, 1, out);
}

/* The options part of a plan's key, and the plan key (options and the records). */
static void MycJobPlanKey(const MycJob* j, char* out, size_t size)
{
    const MycRequest* r = j->request;
    snprintf(out, size, "%u:%u:%u:%d:%d:%s", r->helmet, r->armor, r->body, r->keep_hoods ? 1 : 0, r->materials ? 1 : 0, j->records);
}

void myc_job_item_key(MycJob* j, const char* source, MycKit* kit, char* out, size_t size)
{
    char sum[9];
    MycJobRecords(kit, sum);
    snprintf(out, size, "%s:%08x:%s:%u:%d:%d", source, kit->id, sum, j->request->body, j->request->keep_hoods ? 1 : 0,
        j->request->materials ? 1 : 0);
}

MycAnalysis* myc_job_analysis(MycJob* j, MycKit* kit)
{
    return myc_pipeline_analysis(j->p, kit, (int)j->request->body, j->err);
}

/* ---- the source item and one target's plan ------------------------------------------------------------------------ */

int myc_job_source_item(MycJob* j)
{
    if (j->s != NULL) return 1;
    MycPipeline* p = j->p;
    if (!myc_pipeline_model(p, j->err)) return 0;
    if (j->scheme != NULL)
    {
        const MycLut* lut = myc_pipeline_scheme_lut(p, j->scheme, j->err);
        if (lut == NULL) return 0;
        j->s = myc_scheme_item(&j->arena, p->model, j->scheme, lut);
        j->source_luts = (MycSourceLuts){NULL, lut, j->scheme->lut, 0};
    }
    else if (j->cape_source != NULL)
    {
        const MycAnalysis* cape = j->cape_source;
        MycRow* rows = myc_alloc(&j->arena, sizeof(MycRow) * (size_t)(cape->nrows + 1));
        MycPatternIn* emblems = myc_alloc(&j->arena, sizeof(MycPatternIn) * (size_t)(cape->nemblems + 1));
        if (rows == NULL || emblems == NULL) return myc_fail(j->err, "out of memory (cape source)");
        MycLook look;
        int has = myc_analysis_look(cape, 1, &look);
        j->s = myc_item(&j->arena, rows, myc_capes_source_rows(cape, rows), 0, emblems, myc_capes_emblem_patterns(cape, emblems),
            has ? &look : NULL, 0);
        if (j->s != NULL) { j->s->part_guard = 1; j->s->cape_source = 1; }
        j->source_luts = (MycSourceLuts){cape, NULL, 0, 1};
    }
    else
    {
        const MycAnalysis* source = j->source;
        MycPatternIn* patterns = myc_alloc(&j->arena, sizeof(MycPatternIn) * (size_t)(source->npatterns + 1));
        if (patterns == NULL) return myc_fail(j->err, "out of memory (source)");
        MycLook look;
        int has = myc_analysis_look(source, 0, &look);
        j->s = myc_item(&j->arena, source->rows, source->nrows, source->kit->type == MYC_ARMOR, patterns,
            myc_patterns_of(source, patterns), has ? &look : NULL, 0);
        j->source_luts = (MycSourceLuts){source, NULL, 0, 0};
    }
    return j->s != NULL || myc_fail(j->err, "out of memory (source item)");
}

/* A weapon's camo template: its camo rows copy the source's camo group (camo_copies). */
static int MycJobCamoCopies(MycPlan* plan, const MycRow* rows, int n, const MycGroup* camo)
{
    for (int i = 0; i < n; i++)
    {
        if (!rows[i].camo) continue;
        MycGoal* goal = myc_plan_set(plan, rows[i].key);
        if (goal == NULL) return 0;
        memcpy(goal->source, camo->rep_key, MYC_KEY);
        memcpy(goal->copy, camo->rep_key, MYC_KEY);
        goal->kind = MYC_KIND_PAIR;
    }
    return 1;
}

/* A cape's design zones and emblem-sheet layers into the plan and made (cape_parts). */
static int MycJobCapeParts(MycJob* j, MycPlan* plan, MycItem* t, const MycAnalysis* target, MycMade* made)
{
    if (target->zones != NULL)
    {
        if (!myc_cape_zones(plan, t, j->s, target, &made->zones)) return myc_fail(j->err, "out of memory (zones)");
        made->has_zones = 1;
    }
    if (target->nemblems == 0) return 1;
    MycEmblemPick* picks = myc_alloc(&j->arena, sizeof(MycEmblemPick) * (size_t)target->nemblems);
    if (picks == NULL || !myc_cape_emblems(plan, t, j->s, target, picks, &made->emblems)) return myc_fail(j->err, "out of memory (emblems)");
    made->has_emblems = 1;
    made->has_sheet = myc_sheet_recipe(target, picks, &made->sheet);
    return 1;
}

/* The pipeline's chain for a mod albedo (Albedo.plan_specs' chain). */
static MycSpec* MycJobChain(void* ctx, uint64_t name, uint64_t archive, MycTexInfo* info, MycErr* err)
{
    return myc_pipeline_chain(ctx, name, archive, info, err);
}

/* The target item: a weapon's paint rows (not its bare metal) or every row; its patterns and look. */
static MycItem* MycJobTargetItem(MycJob* j, const MycAnalysis* target, MycRow** rows_out, int* nrows_out)
{
    int weapon = target->kit->type == MYC_WEAPON, n = 0;
    MycRow* rows = target->rows;
    if (weapon)
    {
        rows = myc_alloc(&j->arena, sizeof(MycRow) * (size_t)(target->nrows + 1));
        if (rows == NULL) return NULL;
        for (int i = 0; i < target->nrows; i++)
            if (!target->rows[i].metal) rows[n++] = target->rows[i];
    }
    else n = target->nrows;
    MycPatternIn* patterns = myc_alloc(&j->arena, sizeof(MycPatternIn) * (size_t)(target->npatterns + 1));
    if (patterns == NULL) return NULL;
    MycLook look;
    int has = myc_analysis_look(target, 0, &look);
    MycItem* t = myc_item(&j->arena, rows, n, target->kit->type == MYC_ARMOR, patterns, myc_patterns_of(target, patterns),
        has ? &look : NULL, j->request->keep_hoods);
    if (t != NULL) t->weapon = weapon;
    *rows_out = rows;
    *nrows_out = n;
    return t;
}

/* A target's LUTs and patterns planned against the job's source item, into made (plan_target). */
static int MycJobPlanTarget(MycJob* j, MycAnalysis* target, MycMade* made)
{
    MycPipeline* p = j->p;
    if (!myc_job_source_item(j)) return 0;
    MycRow* rows;
    int nrows;
    MycItem* t = MycJobTargetItem(j, target, &rows, &nrows);
    if (t == NULL) return myc_fail(j->err, "out of memory (target item)");
    p->stage = "color transfer";
    MycPlan plan;
    myc_plan_init(&plan, &j->arena);
    int cape = target->kit->type == MYC_CAPE;
    if (!myc_scheme_plan(&plan, j->scheme, t, j->s, j->request->materials, cape)) return myc_fail(j->err, "out of memory (plan)");
    if (t->weapon && j->camo != NULL && !MycJobCamoCopies(&plan, rows, nrows, j->camo)) return myc_fail(j->err, "out of memory (plan)");
    if (!MycJobCapeParts(j, &plan, t, target, made)) return 0;
    if (!myc_build_luts(&made->arena, target, &plan, p->transfer, &j->source_luts, &made->fits, &made->luts, j->err)) return 0;
    MycPlan patterns;
    myc_plan_init(&patterns, &j->arena);
    if (!myc_pattern_plan(&patterns, t, j->s, &plan)) return myc_fail(j->err, "out of memory (pattern plan)");
    if (!myc_build_patterns(&made->arena, target, &patterns, &made->patterns, j->err)) return 0;
    if (target->nalbedos == 0 && target->nunread == 0) return 1;
    char report[2048];
    if (!myc_albedo_plan_specs(&made->arena, target, &plan, &made->luts, MycJobChain, p, report, sizeof report, j->err)) return 0;
    made->albedo_report = report[0] != 0 ? myc_strdup(&made->arena, report) : NULL;
    return 1;
}

MycMade* myc_job_planned(MycJob* j, const char* key, MycAnalysis* const* targets, int n)
{
    j->p->stage = "plan";
    MycMade* made = myc_pipeline_plan(j->p, key);
    if (made != NULL) return made;
    made = myc_made_new(key);
    if (made == NULL) { myc_fail(j->err, "out of memory (plan)"); return NULL; }
    for (int i = 0; i < n; i++)
        if (!MycJobPlanTarget(j, targets[i], made)) { myc_made_free(made); return NULL; }
    myc_pipeline_keep(j->p, made);
    return made;
}

/* ---- capes, sources and sets -------------------------------------------------------------------------------------- */

static MycKit* MycJobFind(MycJob* j, uint32_t id)
{
    return myc_catalogue_find(j->p->kits, id, j->err);
}

int myc_job_cape_source(MycJob* j)
{
    const MycRequest* r = j->request;
    if (r->cape == 0) return 0;
    MycKit* kit = MycJobFind(j, r->cape);
    if (kit == NULL) return MYC_JOB_FAILED;
    if (myc_job_obsolete(j)) return 0;
    j->cape_source_kit = kit;
    j->cape_source = myc_job_analysis(j, kit);
    if (j->err->failed) return MYC_JOB_FAILED;
    char sum[9];
    MycJobRecords(kit, sum);
    snprintf(j->cape_source_key, sizeof j->cape_source_key, "capesrc:%08x:%s", r->cape, sum);
    return j->cape_source != NULL;
}

/* The job's cape: with Helmet and Armor Match Cape its source, else Recolor Cape's target (job_capes). */
static int MycJobCapes(MycJob* j, MycResult* out)
{
    const MycRequest* r = j->request;
    j->cape_mode = r->mode == MYC_CAPE_SOURCE && j->scheme == NULL;
    if (j->cape_mode)
    {
        int got = myc_job_cape_source(j);
        if (got < 0) return MYC_JOB_FAILED;
        if (got == 0) { myc_result_restore(out, j, "no cape"); return MYC_JOB_DONE; }
        return MYC_JOB_OK;
    }
    if (!(r->capes && r->cape != 0)) return MYC_JOB_OK;
    j->cape_kit = MycJobFind(j, r->cape);
    if (j->cape_kit == NULL) return MYC_JOB_FAILED;
    if (!myc_job_obsolete(j)) j->cape = myc_job_analysis(j, j->cape_kit);
    return j->err->failed ? MYC_JOB_FAILED : MYC_JOB_OK;
}

/* Squadmates' Colors on Your Colors: this player's helmet or armor as the source of both items (kit_source_of). */
static int MycJobKitSource(MycJob* j, MycResult* out)
{
    const MycRequest* r = j->request;
    if (r->source_kit == 0 || j->scheme != NULL || j->cape_mode) return MYC_JOB_OK;
    MycErr local = {0};
    MycKit* kit = myc_catalogue_find(j->p->kits, r->source_kit, &local);
    MycAnalysis* made = kit != NULL && !myc_job_obsolete(j) ? myc_job_analysis(j, kit) : NULL;
    if (j->err->failed) return MYC_JOB_FAILED;
    if (made == NULL) { myc_result_restore(out, j, "no source kit"); return MYC_JOB_DONE; }
    j->source_kit = kit;
    j->kit_source = made;
    char sum[9];
    MycJobRecords(kit, sum);
    snprintf(j->kit_source_key, sizeof j->kit_source_key, "kitsrc:%08x:%s", kit->id, sum);
    return MYC_JOB_OK;
}

static int MycJobSet(MycJob* j, MycResult* out)
{
    const MycRequest* r = j->request;
    j->set = j->scheme == NULL && !j->cape_mode && j->kit_source == NULL && r->keep_sets
        && j->helmet_kit->name_upper == j->armor_kit->name_upper;
    if (j->set && j->cape == NULL && !myc_job_obsolete(j)) { myc_result_restore(out, j, "complete set"); return MYC_JOB_DONE; }
    return MYC_JOB_OK;
}

/* ---- results of plans --------------------------------------------------------------------------------------------- */

static int MycJobAddMade(MycResult* out, const MycMade* made)
{
    return myc_specs_merge(&out->arena, &out->luts, &made->luts) && myc_specs_merge(&out->arena, &out->patterns, &made->patterns);
}

static void MycJobTargets(MycResult* out, const MycAnalysis* const* list, int n)
{
    for (int i = 0; i < n && out->ntargets < MYC_MAX_TARGETS; i++) out->targets[out->ntargets++] = list[i];
}

/* Helmet and armor each planned against the job's source item (both_job). */
static int MycJobBoth(MycJob* j, const char* source, MycAnalysis* h, MycAnalysis* a, MycResult* out)
{
    char key[MYC_PLAN_KEY], plan_key[256];
    MycJobPlanKey(j, plan_key, sizeof plan_key);
    snprintf(out->key, sizeof out->key, "%s:%s", source, plan_key);
    MycAnalysis* items[2] = {h, a};
    MycKit* kits[2] = {j->helmet_kit, j->armor_kit};
    for (int i = 0; i < 2; i++)
    {
        myc_job_item_key(j, source, kits[i], key, sizeof key);
        MycMade* made = myc_job_planned(j, key, &items[i], 1);
        if (made == NULL || !MycJobAddMade(out, made)) return myc_fail(j->err, "%s", j->err->failed ? j->err->why : "out of memory");
    }
    out->action = MYC_APPLY;
    out->first = 0;
    out->last = 9;
    out->target = h;
    const MycAnalysis* targets[2] = {h, a};
    MycJobTargets(out, targets, 2);
    return 1;
}

/* The mode's target item planned against the other (pair_job). */
static int MycJobPair(MycJob* j, MycAnalysis* h, MycAnalysis* a, MycResult* out)
{
    MycAnalysis* target = j->request->mode == MYC_ARMOR_FROM_HELMET ? a : h;
    char plan_key[256];
    MycJobPlanKey(j, plan_key, sizeof plan_key);
    snprintf(out->key, sizeof out->key, "%d:%s", j->request->mode, plan_key);
    MycMade* made = myc_job_planned(j, out->key, &target, 1);
    if (made == NULL || !MycJobAddMade(out, made)) return myc_fail(j->err, "%s", j->err->failed ? j->err->why : "out of memory");
    out->action = MYC_APPLY;
    out->first = j->request->mode == MYC_ARMOR_FROM_HELMET ? 1 : 0;
    out->last = j->request->mode == MYC_ARMOR_FROM_HELMET ? 9 : 0;
    out->target = target;
    MycJobTargets(out, (const MycAnalysis* const*)&target, 1);
    out->albedo_report = made->albedo_report != NULL ? myc_strdup(&out->arena, made->albedo_report) : NULL;
    return 1;
}

static int MycJobItems(MycJob* j, MycAnalysis* h, MycAnalysis* a, MycResult* out)
{
    if (j->set)
    {
        char plan_key[256];
        MycJobPlanKey(j, plan_key, sizeof plan_key);
        snprintf(out->key, sizeof out->key, "set:%d:%s", j->request->mode, plan_key);
        out->action = MYC_APPLY;
        out->first = 1;
        out->last = 1;
        return 1;
    }
    if (j->scheme != NULL)
    {
        char source[64];
        snprintf(source, sizeof source, "scheme:%s", j->scheme->id);
        return MycJobBoth(j, source, h, a, out);
    }
    if (j->cape_source != NULL) return MycJobBoth(j, j->cape_source_key, h, a, out);
    if (j->kit_source != NULL) return MycJobBoth(j, j->kit_source_key, h, a, out);
    return MycJobPair(j, h, a, out);
}

/* The sheet's original bytes for a recipe (the pipeline's last sheet kept). */
static const uint8_t* MycJobSheet(void* ctx, const MycSheetRecipe* recipe, char* why, size_t size)
{
    MycJob* j = ctx;
    MycPipeline* p = j->p;
    if (p->kept_sheet_data != NULL && p->kept_sheet == recipe->name) return p->kept_sheet_data->data;
    MycTexInfo info;
    MycSpec* data = myc_pipeline_chain(p, recipe->name, j->cape_kit->archive, &info, j->err);
    if (data == NULL) { snprintf(why, size, "decal sheet %016llx not found", (unsigned long long)recipe->name); return NULL; }
    if (info.format != MYC_SHEET_FORMAT || info.width != recipe->width || info.height != recipe->height || info.mips != recipe->mips
        || info.total != recipe->size)
    {
        myc_spec_drop(data);
        snprintf(why, size, "decal sheet %016llx is not the sheet analysed", (unsigned long long)recipe->name);
        return NULL;
    }
    myc_spec_drop(p->kept_sheet_data);
    p->kept_sheet_data = data;
    p->kept_sheet = recipe->name;
    return data->data;
}

/* Recolor Cape: the cape planned against the job's source item; its LUTs join the result (with_cape). */
static int MycJobWithCape(MycJob* j, MycResult* out)
{
    if (j->cape == NULL) return 1;
    char sum[9], source[96], key[MYC_PLAN_KEY];
    MycJobRecords(j->cape_kit, sum);
    size_t at = strlen(out->key);
    snprintf(out->key + at, sizeof out->key - at, ":cape:%08x:%s", j->request->cape, sum);
    if (j->scheme != NULL) snprintf(source, sizeof source, "cape:scheme:%s", j->scheme->id);
    else
    {
        MycJobRecords(j->source_kit, sum);
        snprintf(source, sizeof source, "cape:%d:%08x:%s", j->request->mode, j->source_kit->id, sum);
    }
    myc_job_item_key(j, source, j->cape_kit, key, sizeof key);
    MycMade* made = myc_job_planned(j, key, &j->cape, 1);
    if (made == NULL || !myc_specs_merge(&out->arena, &out->luts, &made->luts)) return myc_fail(j->err, "%s", j->err->failed ? j->err->why : "out of memory");
    if (made->has_sheet)
    {
        j->p->stage = "emblem sheet";
        MycSpec* spec = myc_sheet_spec(&made->sheet, MycJobSheet, j, made->sheet_note, sizeof made->sheet_note, j->err);
        if (j->err->failed) return 0;
        if (spec != NULL && !myc_specs_put(&out->arena, &out->luts, made->sheet.name, spec)) return myc_fail(j->err, "out of memory");
    }
    if (made->report == NULL)
    {
        char report[1024];
        myc_capes_report(j->cape, made->has_zones ? &made->zones : NULL, made->has_emblems ? &made->emblems : NULL,
            made->sheet_note, made->fits.rows, made->fits.err, report, sizeof report);
        made->report = myc_strdup(&made->arena, report);
    }
    if (out->ntargets == 0 && out->target != NULL) MycJobTargets(out, &out->target, 1);
    MycJobTargets(out, (const MycAnalysis* const*)&j->cape, 1);
    if (out->target == NULL) out->target = j->cape;
    out->first = out->first < 1 ? out->first : 1;
    out->last = out->last > 1 ? out->last : 1;
    out->cape_report = made->report != NULL ? myc_strdup(&out->arena, made->report) : NULL;
    return 1;
}

static void MycJobSign(MycJob* j, MycKit* kit, MycResult* out)
{
    if (kit == NULL || out->nsignatures >= 5) return;
    out->signatures[out->nsignatures++] = (MycSigned){kit->id, kit->signature != NULL ? myc_strdup(&out->arena, kit->signature) : ""};
}

static void MycJobSigned(MycJob* j, MycResult* out)
{
    MycJobSign(j, j->helmet_kit, out);
    MycJobSign(j, j->armor_kit, out);
    if (j->cape != NULL) MycJobSign(j, j->cape_kit, out);
    if (j->cape_source != NULL) MycJobSign(j, j->cape_source_kit, out);
    if (j->kit_source != NULL) MycJobSign(j, j->source_kit, out);
}

/* The helmet's and armor's parts after the kits are found (Recolor.job's body). */
static int MycJobKits(MycJob* j, MycResult* out)
{
    const MycRequest* r = j->request;
    j->p->stage = "kit catalogue";
    j->helmet_kit = MycJobFind(j, r->helmet);
    j->armor_kit = j->helmet_kit != NULL ? MycJobFind(j, r->armor) : NULL;
    if (j->armor_kit == NULL) return 0;
    MycKit* both[2] = {j->helmet_kit, j->armor_kit};
    myc_records_sum(both, 2, j->records);
    j->source_kit = r->mode == MYC_ARMOR_FROM_HELMET ? j->helmet_kit : j->armor_kit;
    int step = MycJobCapes(j, out);
    if (step == MYC_JOB_OK) step = MycJobKitSource(j, out);
    if (step == MYC_JOB_OK) step = MycJobSet(j, out);
    if (step != MYC_JOB_OK) return step == MYC_JOB_DONE;
    MycAnalysis* h = !myc_job_obsolete(j) ? myc_job_analysis(j, j->helmet_kit) : NULL;
    MycAnalysis* a = h != NULL && !myc_job_obsolete(j) ? myc_job_analysis(j, j->armor_kit) : NULL;
    if (j->err->failed) return 0;
    j->source = j->kit_source != NULL ? j->kit_source : (r->mode == MYC_ARMOR_FROM_HELMET ? h : a);
    if (a == NULL || myc_job_obsolete(j)) { out->action = MYC_OBSOLETE; return 1; }
    if (!MycJobItems(j, h, a, out)) return 0;
    if (myc_job_obsolete(j)) { out->action = MYC_OBSOLETE; return 1; }
    if (!MycJobWithCape(j, out)) return 0;
    MycJobSigned(j, out);
    return 1;
}

int myc_job_run(MycPipeline** pp, const wchar_t* data_folder, const wchar_t* cache_path, MycRequest* request, MycResult* out,
    MycErr* err)
{
    MycJob j;
    memset(&j, 0, sizeof j);
    j.request = request;
    j.err = err;
    j.scheme = myc_scheme_get(request->scheme);
    if (request->mode == MYC_OFF && j.scheme == NULL) { myc_result_restore(out, NULL, "off"); return 1; }
    if (*pp == NULL) *pp = myc_pipeline_new(data_folder, cache_path, err);
    if (*pp == NULL) return 0;
    j.p = *pp;
    j.p->stage = "starting";
    int ok;
    if (request->nweapons > 0) ok = myc_weapons_job(&j, out);
    else if (!request->has_kits) { out->action = MYC_PREPARED; ok = 1; }
    else ok = MycJobKits(&j, out);
    myc_arena_free(&j.arena);
    return ok;
}
