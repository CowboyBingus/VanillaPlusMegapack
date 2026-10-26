/* Match Your Colors: jobs (addon.lua's requests, plan_ahead, start_job, finish and its log lines, the cache save and the
 * reader's release), 1:1 but for where a job runs: whole, on the worker thread (myc_worker.c), where the Lua sliced its
 * coroutine BUDGET (1.5 ms) per frame. The game thread gives the worker a request, reads its busy flag (a plain load) on
 * the frames after, and applies the result on the first frame it is done: a job started on frame f is applied on f + 1
 * at the earliest. The worker's time goes into the log in place of the Lua's slices. Game thread. */
#include <stdio.h>
#include <string.h>
#include "myc_addon.h"

#define g myc_g

static const char* const kModeNames[] = {"", "off", "helmet matches armor", "armor matches helmet",
                                         "helmet and armor match the cape"};

/* ---- failures (state.failures, by request key) -------------------------------------------------------------------- */

static MycFailure* MycAjFailure(const char* key, int add)
{
    for (int i = 0; i < g.nfailures; i++)
        if (strcmp(g.failures[i].key, key) == 0) return &g.failures[i];
    if (!add) return NULL;
    int at = g.nfailures;
    if (at == MYC_FAILURES) /* full: the entry with the fewest failures makes room */
    {
        at = 0;
        for (int i = 1; i < MYC_FAILURES; i++)
            if (g.failures[i].count < g.failures[at].count) at = i;
    }
    else g.nfailures++;
    snprintf(g.failures[at].key, sizeof g.failures[at].key, "%s", key);
    g.failures[at].count = 0;
    return &g.failures[at];
}

static int MycAjFailures(const char* key)
{
    const MycFailure* f = MycAjFailure(key, 0);
    return f != NULL ? f->count : 0;
}

static int MycAjFailed(const char* key) { return ++MycAjFailure(key, 1)->count; }

static uint64_t MycAjHash(const char* text)
{
    uint64_t h = 1469598103934665603ull;
    for (; *text != 0; text++) h = (h ^ (uint8_t)*text) * 1099511628211ull;
    return h;
}

/* ---- requests ----------------------------------------------------------------------------------------------------- */

/* A request for target with the options, without kits (options_request). */
static void MycAjOptionsRequest(int target, MycRequest* r)
{
    const MycOptions* o = &g.options;
    memset(r, 0, sizeof *r);
    r->target = target;
    myc_mode_of(target, &r->mode, &r->scheme);
    r->keep_sets = o->keep_sets;
    r->keep_hoods = !o->recolor_hoods;
    r->materials = o->match_materials;
    r->capes = o->recolor_cape;
    r->slot = -1;
}

static void MycAjWithKits(MycRequest* r, uint32_t helmet, uint32_t armor, uint32_t body, uint32_t cape)
{
    r->has_kits = 1;
    r->helmet = helmet;
    r->armor = armor;
    r->body = body;
    r->cape = cape;
}

/* The weapons' request: their job's key holds the weapons' signature (a hash of it here: the failures' key). */
static int MycAjWeaponsRequest(int target, MycRequest* r)
{
    MycAjOptionsRequest(target, r);
    int due = target == MYC_TARGET_WEAPONS ? myc_loadout_request(&g.loadout, r) : myc_loadout_preview_request(&g.loadout, r);
    if (!due || !g.has_identity) return 0;
    MycAjWithKits(r, g.identity.helmet, g.identity.armor, g.identity.body, g.identity.cape);
    char key[128];
    myc_request_key(r, key, sizeof key);
    snprintf(r->key, sizeof r->key, "%s:%s:%016llx", target == MYC_TARGET_WEAPONS ? "weapons" : "ui_weapon", key,
        (unsigned long long)MycAjHash(r->sig));
    return 1;
}

/* The request for a target into r, or 0 (a preview not showing two kits yet, no other mod user's Helldiver waiting). */
static int MycAjRequestFor(int target, MycRequest* r)
{
    if (target == MYC_TARGET_REMOTE) return myc_remote_request(&g.remote, r);
    if (target == MYC_TARGET_CARD) return myc_lineup_request(&g.lineup, r);
    if (target == MYC_TARGET_WEAPONS || target == MYC_TARGET_UI_WEAPON) return MycAjWeaponsRequest(target, r);
    if (target == MYC_TARGET_UI)
    {
        MycUi* ui = &g.ui;
        ui->dirty = 0;
        if (!ui->has_kits || ui->helmet == 0 || ui->armor == 0) return 0;
        MycAjOptionsRequest(target, r);
        MycAjWithKits(r, ui->helmet, ui->armor, ui->body, ui->cape);
        return 1;
    }
    g.dirty = 0;
    MycAjOptionsRequest(target, r);
    MycAjWithKits(r, g.identity.helmet, g.identity.armor, g.identity.body, g.identity.cape);
    return 1;
}

/* Whether a loading Helldiver's applied kits are real: its record shows stand-ins (0xffffffff) first (real_kits). */
static int MycAjRealKits(const MycIdentity* k, int capes)
{
    return k->helmet != 0 && k->armor != 0 && k->helmet != MYC_STAND_IN && k->armor != MYC_STAND_IN
        && !(capes && k->cape == MYC_STAND_IN);
}

/* Work ahead of the Helldiver (plan_ahead): a resolve that found a world loading asks for the pipeline, once; one that
 * found the local player's real kits before the Helldiver asks for their analyses and plans, once per request. */
void myc_addon_plan_ahead(int found)
{
    if (!g.active || found == MYC_FOUND_NOTHING) return;
    if (found == MYC_FOUND_KITS && MycAjRealKits(&g.probe, myc_options_cape_counts(MYC_TARGET_PREPARE)))
    {
        MycRequest* r = &g.warm;
        MycAjOptionsRequest(MYC_TARGET_PREPARE, r);
        MycAjWithKits(r, g.probe.helmet, g.probe.armor, g.probe.body, g.probe.cape);
        char key[MYC_REQUEST_KEY], applied[MYC_REQUEST_KEY];
        myc_request_key(r, key, sizeof key);
        if (g.has_applied) myc_request_key(&g.applied, applied, sizeof applied);
        if ((g.has_prepared && strcmp(key, g.prepared) == 0) || (g.has_applied && strcmp(applied, key) == 0)) return;
        snprintf(g.prepared, sizeof g.prepared, "%s", key);
        g.has_prepared = g.has_warm = 1;
    }
    else if (g.kits == NULL && !g.pipeline_asked)
    {
        g.pipeline_asked = g.has_warm = 1;
        MycAjOptionsRequest(MYC_TARGET_PREPARE, &g.warm);
    }
}

int myc_addon_start_job(uint32_t frame, int target, const MycRequest* given)
{
    if (myc_worker_busy(&g.worker)) return 0; /* a save or a close still on the worker: asked again next frame */
    MycRequest* r = &g.request;
    if (given != NULL) *r = *given;
    else if (!MycAjRequestFor(target, r)) return 0;
    int own = target != MYC_TARGET_REMOTE && target != MYC_TARGET_CARD;
    char key[MYC_REQUEST_KEY];
    key[0] = 0;
    if (own && r->nweapons > 0) snprintf(key, sizeof key, "%s", r->key);
    else if (own && r->has_kits) myc_request_key(r, key, sizeof key);
    if (key[0] != 0 && MycAjFailures(key) >= MYC_FAILURE_LIMIT) return 0;
    r->obsolete = 0;
    g.close_due = 0; /* the job takes the kept reader as it is */
    g.job = 1;
    g.job_frame = frame;
    if (myc_worker_give(&g.worker, MYC_TASK_JOB, r)) return 1;
    g.job = 0;
    vpm_fail(g.self, "the worker thread could not start (error %lu)", g.worker.start_error);
    return 0;
}

/* ---- log lines ---------------------------------------------------------------------------------------------------- */

/* After applying: the cache status and the mods' patches once; new analyses are written later by the save (note_cache). */
static void MycAjNoteCache(uint32_t frame)
{
    const MycPipeline* p = g.worker.pipeline;
    if (p == NULL) return;
    if (p->cache_status[0] != 0 && !g.cache_logged)
    {
        g.cache_logged = 1;
        myc_notef("Analysis cache: %s.", p->cache_status);
    }
    if (p->patch_status[0] != 0 && !g.patches_logged)
    {
        g.patches_logged = 1;
        myc_notef("Mods: %s.", p->patch_status);
    }
    if (p->dirty)
    {
        g.save_at = frame + MYC_SAVE_DELAY_FRAMES;
        g.has_save_at = 1;
    }
}

/* The pool's decal sheet lines since the last ones logged (note_sheets). */
static void MycAjNoteSheets(void)
{
    for (int i = 0; i < g.pool.nsheet_notes; i++) myc_notef("%s.", g.pool.sheet_notes[i]);
    g.pool.nsheet_notes = 0;
}

/* A report line once per plan (note_albedo, note_cape): last holds the hash of the one logged before. */
static void MycAjNoteReport(const char* report, uint64_t* last)
{
    if (report == NULL || report[0] == 0) return;
    uint64_t h = MycAjHash(report);
    if (h == *last) return;
    myc_note(report);
    *last = h;
}

static void MycAjNoteCape(const MycResult* result)
{
    MycAjNoteReport(result->cape_report, &g.cape_report);
    MycAjNoteReport(result->albedo_report, &g.albedo_report);
}

static void MycAjNoteReads(void)
{
    const MycPipeline* p = g.worker.pipeline;
    if (p == NULL) return;
    uint64_t reads = p->reads + (p->open ? p->files.reads : 0), bytes = p->bytes + (p->open ? p->files.bytes : 0);
    double longest = p->longest;
    uint32_t size = p->longest_size;
    if (p->open && p->files.longest > longest) { longest = p->files.longest; size = p->files.longest_size; }
    if (reads == 0) return;
    myc_notef("Game data read so far: %llu reads, %.1f MB, longest read %.1f ms (%u KB).", (unsigned long long)reads,
        (double)bytes / 1048576.0, longest * 1000.0, size / 1024u);
}

/* The log lines of an applied result (log_result); after: frames since the Helldiver was found, or -1. */
static void MycAjLogResult(const MycResult* result, const MycRequest* request, int count, int made, int refilled, int after)
{
    if (result->action != MYC_APPLY)
    {
        if (!g.has_last_reason || strcmp(result->reason, g.last_reason) != 0) myc_notef("Original colors (%s).", result->reason);
        return;
    }
    char how[96], scheme[24], after_text[64] = "";
    snprintf(scheme, sizeof scheme, "paint scheme %d", request->scheme);
    snprintf(how, sizeof how, "%s%s%s%s", request->scheme > 0 ? scheme : kModeNames[request->mode],
        request->keep_hoods ? ", hoods kept" : "", request->materials ? ", materials matched" : "", request->capes ? ", cape" : "");
    if (after >= 0)
        snprintf(after_text, sizeof after_text, "; %d %s after the Helldiver was found", after, after == 1 ? "frame" : "frames");
    myc_notef("Recolored %d materials (%s, %d LUTs; job %.1f ms of work on the worker thread over %u frames; %d new, %d "
        "refilled textures%s).", count, how, result->luts.n, g.last_job_seconds * 1000.0, g.last_job_frames, made, refilled,
        after_text);
    MycAjNoteCape(result);
    MycAjNoteSheets();
    MycAjNoteReads();
}

/* ---- finishing a job ---------------------------------------------------------------------------------------------- */

/* A UI preview job's result, applied when the preview still shows its kits with the same options, read again now
 * (finish_ui). Else, or when the job ended early as obsolete, a new job follows for what is shown. */
static void MycAjFinishUi(MycResult* result, const MycRequest* request, uint32_t frame)
{
    MycUi* ui = &g.ui;
    if (g.has_ui && ui->shown) myc_addon_poll_ui(frame);
    if (!g.has_ui || !ui->shown) return;
    if (result->action == MYC_OBSOLETE || myc_kits_changed(request, ui->helmet, ui->armor, ui->body, ui->cape)
        || myc_options_changed(request))
    {
        ui->dirty = 1;
        return;
    }
    int same_key = g.ui_controller.has_key && strcmp(g.ui_controller.key, result->key) == 0;
    int made = g.pool.made, refilled = g.pool.refilled;
    MycApplyTo to = myc_apply_to(ui->where.units_at, request->body, 0);
    char why[160];
    int count = myc_controller_apply(&g.ui_controller, result, &to, frame, why, sizeof why);
    if (count < 0) { myc_addon_error(why); return; }
    ui->applied = *request;
    ui->has_applied = 1;
    ui->dirty = 0;
    MycAjNoteCache(frame);
    if (result->action == MYC_APPLY && (count > 0 || !same_key))
    {
        char cape[24] = "";
        if (myc_cape_counts(request->mode, request->scheme, request->capes)) snprintf(cape, sizeof cape, ", cape %08x", request->cape);
        myc_notef("Preview recolored: %d materials (helmet %08x, armor %08x%s; job %.1f ms of work on the worker thread over %u "
            "frames; %d new, %d refilled textures).", count, request->helmet, request->armor, cape, g.last_job_seconds * 1000.0,
            g.last_job_frames, g.pool.made - made, g.pool.refilled - refilled);
        MycAjNoteReport(result->albedo_report, &g.albedo_report);
    }
    MycAjNoteSheets();
}

/* The local player resolved again for a finished job: 0 when the result no longer applies (the kits or the options
 * changed while it ran; a new job follows), else 1 with now (still_current). */
int myc_addon_still_current(const MycRequest* request, uint32_t frame, MycIdentity* now)
{
    const char* why;
    int found;
    if (!myc_avatar_resolve(now, &why, &found)) { myc_addon_lose(frame, why); return 0; }
    if (myc_kits_changed(request, now->helmet, now->armor, now->body, now->cape)) { myc_addon_adopt(now, frame); return 0; }
    if (myc_options_changed(request)) { g.dirty = 1; return 0; }
    return 1;
}

/* A job done ahead of the Helldiver (finish_ahead): its plan's textures made now, while the game loads (pool.stock). */
static void MycAjFinishAhead(int ok, const char* failure, const MycResult* result, const MycRequest* request, uint32_t frame)
{
    if (!ok) { myc_notef("Preparing ahead of the Helldiver failed: %s", failure); return; }
    MycAjNoteCache(frame);
    int made = 0;
    if (request->has_kits && result->action == MYC_APPLY) made = myc_pool_stock(&g.pool, &result->luts, &result->patterns);
    char what[64];
    if (request->has_kits) snprintf(what, sizeof what, "plans of helmet %08x, armor %08x", request->helmet, request->armor);
    else snprintf(what, sizeof what, "analysis cache and game data");
    myc_notef("Prepared ahead of the Helldiver: %s (%.1f ms of work on the worker thread over %u frames; %d textures made "
        "ahead).", what, g.last_job_seconds * 1000.0, g.last_job_frames, made);
}

/* Whether a weapons result is no longer wanted (the option off, other options or kits, or obsolete); a wanted weapons
 * plan is asked for again (weapons_stale). */
static int MycAjWeaponsStale(const MycRequest* request, const MycResult* result, int preview, uint32_t frame)
{
    const MycIdentity* id = &g.identity;
    int stale = !g.has_identity || myc_options_changed(request) || myc_kits_changed(request, id->helmet, id->armor, id->body, id->cape);
    if (myc_weapons_on() && !stale && result->action != MYC_OBSOLETE) return 0;
    if (myc_weapons_on() && preview) myc_loadout_preview_changed(&g.loadout, frame);
    else if (myc_weapons_on()) myc_loadout_replan(&g.loadout);
    return 1;
}

static void MycAjFinishWeapons(int ok, const char* failure, MycResult* result, const MycRequest* request, uint32_t frame)
{
    if (!ok)
    {
        int n = MycAjFailed(request->key);
        myc_notef("Weapons recolor failed (%d/%d): %s", n, MYC_FAILURE_LIMIT, failure);
        return;
    }
    MycAjNoteCache(frame);
    int preview = request->target == MYC_TARGET_UI_WEAPON;
    if (MycAjWeaponsStale(request, result, preview, frame)) return;
    int made = g.pool.made;
    int count = preview ? myc_loadout_finish_preview(&g.loadout, result, request, frame)
                        : myc_loadout_finish(&g.loadout, result, request, frame);
    if (count < 0) return; /* the weapons changed while it ran: planned again (or its error logged) */
    if (result->action == MYC_APPLY)
        myc_notef("%s: %d materials (%d weapons, %d LUTs; job %.1f ms of work on the worker thread over %u frames; %d new "
            "textures).", preview ? "Weapon preview recolored" : "Weapons recolored", count, result->ntargets, result->luts.n,
            g.last_job_seconds * 1000.0, g.last_job_frames, g.pool.made - made);
    else if (!g.has_weapons_reason || strcmp(result->reason, g.weapons_reason) != 0)
        myc_notef("Weapons keep their colors (%s).", result->reason);
    snprintf(g.weapons_reason, sizeof g.weapons_reason, "%s", result->reason);
    g.has_weapons_reason = 1;
}

/* A failed job of the local Helldiver: counted per request (FAILURE_LIMIT) and noted (job_failed). */
static void MycAjJobFailed(const MycRequest* request, const char* failure)
{
    char key[MYC_REQUEST_KEY], status[160];
    myc_request_key(request, key, sizeof key);
    int n = MycAjFailed(key);
    snprintf(status, sizeof status, "failed: %s", failure);
    vpm_set_status(g.self, status);
    myc_notef("Recolor failed (%d/%d): %s", n, MYC_FAILURE_LIMIT, failure);
}

/* Another mod user's Helldiver (or weapons), or a squad card (the preview polled first: a card that changed meanwhile
 * wants a new job): its entry or card counts its own failures (finish_remote). */
static void MycAjFinishRemote(int ok, const char* failure, MycResult* result, const MycRequest* request, uint32_t frame)
{
    if (request->target == MYC_TARGET_CARD && g.has_ui) myc_addon_poll_ui(frame);
    if (request->target == MYC_TARGET_REMOTE) myc_remote_finish(&g.remote, ok, result, request, failure, frame);
    else myc_lineup_finish(&g.lineup, ok, result, request, failure, frame);
    MycAjNoteSheets();
    if (ok) MycAjNoteCache(frame);
}

/* The local Helldiver's plan, applied while its request is still current, and logged (finish_local). */
static void MycAjFinishLocal(MycResult* result, const MycRequest* request, uint32_t frame)
{
    static MycIdentity now;
    if (!myc_addon_still_current(request, frame, &now)) return;
    int made = g.pool.made, refilled = g.pool.refilled;
    MycApplyTo to = myc_apply_to(now.units_at, now.body, myc_avatar_preview_slot(&now));
    char why[160];
    int count = myc_controller_apply(&g.controller, result, &to, frame, why, sizeof why);
    if (count < 0) { myc_addon_error(why); return; }
    g.applied = *request;
    g.has_applied = 1;
    MycAjNoteCache(frame);
    if (result->action == MYC_APPLY) vpm_set_status(g.self, "active");
    else
    {
        char status[96];
        snprintf(status, sizeof status, "vanilla: %s", result->reason);
        vpm_set_status(g.self, status);
    }
    int after = g.has_found_at ? (int)(frame - g.found_at) : -1;
    g.has_found_at = 0;
    MycAjLogResult(result, request, count, g.pool.made - made, g.pool.refilled - refilled, after);
    snprintf(g.last_reason, sizeof g.last_reason, "%s", result->reason);
    g.has_last_reason = 1;
}

/* The game-data reader after a job: kept while the UI preview is shown, for the next item's job, else closed on the
 * next binding check without a job (release_reader). */
static void MycAjReleaseReader(uint32_t frame)
{
    g.has_reader_kept = 1;
    g.reader_kept = g.has_ui && g.ui.shown ? frame : frame - MYC_KEEP_FRAMES;
}

/* The worker is done with the job: its result to its target (finish). */
static void MycAjFinish(uint32_t frame)
{
    static MycResult none; /* a failed job's when the worker had none */
    MycWorker* w = &g.worker;
    int ok = w->ok && w->result != NULL;
    MycResult* result = w->result != NULL ? myc_result_hold(w->result) : NULL;
    w->result = NULL;
    MycResult* given = result != NULL ? result : &none;
    const char* failure = w->err.why[0] != 0 ? w->err.why : "the job did not finish";
    MycRequest* request = &g.request;
    g.job = 0;
    if (w->pipeline != NULL)
    {
        g.kits = w->pipeline->kits;
        MycAjReleaseReader(frame);
    }
    g.last_job_seconds = w->seconds;
    g.last_job_frames = frame - g.job_frame + 1;
    if (request->target == MYC_TARGET_REMOTE || request->target == MYC_TARGET_CARD) MycAjFinishRemote(ok, failure, given, request, frame);
    else if (request->nweapons > 0) MycAjFinishWeapons(ok, failure, given, request, frame);
    else if (request->target == MYC_TARGET_PREPARE) MycAjFinishAhead(ok, failure, given, request, frame);
    else if (!ok) MycAjJobFailed(request, failure);
    else if (request->target == MYC_TARGET_UI) MycAjFinishUi(given, request, frame);
    else MycAjFinishLocal(given, request, frame);
    if (result != NULL) myc_result_drop(result);
}

/* While a UI preview job runs: the preview read on 1 frame in UI_GATE_FRAMES; when it shows other kits or closed, the
 * request is obsolete and the job ends at its next stage boundary (watch_ui_job). */
static void MycAjWatchUiJob(uint32_t frame, MycRequest* request)
{
    MycUi* ui = &g.ui;
    if (g.has_ui) myc_addon_poll_ui(frame);
    if (!(g.has_ui && ui->shown) || myc_kits_changed(request, ui->helmet, ui->armor, ui->body, ui->cape)
        || myc_options_changed(request))
        request->obsolete = 1;
}

/* A frame with a recolor job: one load of the worker's flag; while it is the UI preview's, the preview read on 1 frame
 * in UI_GATE_FRAMES (job_step). */
/* lint: per-frame */
void myc_addon_job_step(uint32_t frame)
{
    MycRequest* request = &g.request;
    if (!myc_worker_busy(&g.worker)) { MycAjFinish(frame); return; }
    if (frame % MYC_UI_GATE_FRAMES == 0 && request->target == MYC_TARGET_UI && !request->obsolete) MycAjWatchUiJob(frame, request);
}

/* ---- the cache save and the reader's close ------------------------------------------------------------------------- */

static void MycAjSaveDone(uint32_t frame)
{
    const MycWorker* w = &g.worker;
    g.saving = 0;
    g.has_save_at = w->pipeline != NULL && w->pipeline->dirty;
    g.save_at = frame + MYC_SAVE_DELAY_FRAMES;
    if (w->ok) myc_notef("Analysis cache saved (%.1f ms of work on the worker thread).", w->seconds * 1000.0);
    else myc_notef("Analysis cache not saved: %s", w->save_why);
}

/* The disk cache's save, due SAVE_DELAY_FRAMES frames after a recolor job made new analyses: it waits while the UI
 * preview is shown, starts only on frames without a recolor job, and runs on the worker (save_step). */
void myc_addon_save_step(uint32_t frame)
{
    if (g.saving)
    {
        if (!myc_worker_busy(&g.worker)) MycAjSaveDone(frame);
        return;
    }
    if (g.worker.pipeline == NULL) { g.has_save_at = 0; return; }
    if (g.has_ui && g.ui.shown) { g.save_at = frame + MYC_SAVE_DELAY_FRAMES; return; }
    if (myc_worker_busy(&g.worker)) return;
    g.saving = 1;
    if (!myc_worker_give(&g.worker, MYC_TASK_SAVE, NULL)) g.saving = 0;
}

void myc_addon_close_step(void)
{
    if (!g.close_due || myc_worker_busy(&g.worker)) return;
    g.close_due = 0;
    const MycPipeline* p = g.worker.pipeline;
    if (p != NULL && p->open) myc_worker_give(&g.worker, MYC_TASK_CLOSE, NULL);
}
