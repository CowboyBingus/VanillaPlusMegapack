/* Match Your Colors: the per-frame step (addon.lua Addon.new step), 1:1: the local Helldiver found and watched, the UI
 * preview polled, the binding checks, Hide Cape's local cape, the squad's lobby poll and the other players' watches, and
 * option changes. One heavy periodic piece per frame, as the Lua: a resolve, a chain check, a job, a save or a lobby
 * poll. Jobs and their results are in myc_addon_jobs.c. Game thread. */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "myc_addon.h"

MycAddon myc_g;
#define g myc_g

void myc_note(const char* line) { vpm_log(g.self, "%s", line); }

void myc_notef(const char* format, ...)
{
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    myc_note(line);
}

/* ---- requests and options ----------------------------------------------------------------------------------------- */

int myc_cape_counts(int mode, int scheme, int capes) { return capes || (mode == MYC_CAPE_SOURCE && scheme == 0); }

/* The mode and paint scheme of a request for target (the loopback leaves the avatar to the sync path). */
void myc_mode_of(int target, int* mode, int* scheme)
{
    int loop = (target == MYC_TARGET_AVATAR || target == MYC_TARGET_PREPARE) && g.loopback;
    *mode = loop ? MYC_OFF : g.options.mode;
    *scheme = loop ? 0 : g.options.scheme;
}

/* cape_counts for the options' requests for target. */
int myc_options_cape_counts(int target)
{
    int mode, scheme;
    myc_mode_of(target, &mode, &scheme);
    return myc_cape_counts(mode, scheme, g.options.recolor_cape);
}

void myc_request_key(const MycRequest* r, char* out, size_t size)
{
    snprintf(out, size, "%d:%d:%d:%d:%d:%u:%u:%u:%u", r->mode, r->scheme, r->keep_sets ? 1 : 0, r->keep_hoods ? 1 : 0,
        r->materials ? 1 : 0, r->helmet, r->armor, r->body, myc_cape_counts(r->mode, r->scheme, r->capes) ? r->cape : 0);
}

int myc_options_changed(const MycRequest* r)
{
    const MycOptions* o = &g.options;
    int mode, scheme;
    myc_mode_of(r->target, &mode, &scheme);
    return mode != r->mode || scheme != r->scheme || o->keep_sets != r->keep_sets || (!o->recolor_hoods) != r->keep_hoods
        || o->match_materials != r->materials || o->recolor_cape != r->capes;
}

int myc_kits_changed(const MycRequest* r, uint32_t helmet, uint32_t armor, uint32_t body, uint32_t cape)
{
    return helmet != r->helmet || armor != r->armor || body != r->body || (myc_cape_counts(r->mode, r->scheme, r->capes) && cape != r->cape);
}

/* Whether a result was made of the kit records as they read now (signatures): a transmog mod recomposes a record at
 * runtime under the same id, and the new units then show other pieces. Read through the job's catalogue (its lock: the
 * worker may be scanning it); without one, false. */
static int MycAdRecordSame(const MycResult* result, uint32_t id)
{
    if (id == 0) return 1;
    for (int i = 0; i < result->nsignatures; i++)
    {
        if (result->signatures[i].id != id) continue;
        const char* now = myc_catalogue_signature(g.kits, id);
        return now != NULL && result->signatures[i].signature != NULL && strcmp(result->signatures[i].signature, now) == 0;
    }
    return 0;
}

int myc_records_same(void* ctx, const MycResult* result, uint32_t helmet, uint32_t armor, uint32_t cape, int has_cape)
{
    if (g.kits == NULL || result->nsignatures == 0) return 0;
    return MycAdRecordSame(result, helmet) && MycAdRecordSame(result, armor) && (!has_cape || MycAdRecordSame(result, cape));
}

int myc_weapons_on(void) { return g.has_loadout && g.options.recolor_weapons && g.active && !g.loopback; }

/* ---- the local Helldiver ------------------------------------------------------------------------------------------ */

static int MycAdSameIdentity(const MycIdentity* a, const MycIdentity* b)
{
    return a->units_at == b->units_at && a->avatar == b->avatar && a->helmet == b->helmet && a->armor == b->armor
        && a->body == b->body && a->peer_low == b->peer_low && a->peer_high == b->peer_high && a->has_peer == b->has_peer
        && a->has_ui_slot == b->has_ui_slot && (!a->has_ui_slot || a->ui_slot == b->ui_slot);
}

/* Recolor Squadmates: the settings squadmates take, or none (squad_settings). */
static void MycAdSquadSettings(void)
{
    const MycOptions* o = &g.options;
    if (o->squad == MYC_SQUAD_OFF || (o->mode == MYC_OFF && o->scheme == 0)) { g.has_squad_mine = 0; return; }
    MycSettings* mine = &g.squad_mine;
    memset(mine, 0, sizeof *mine);
    mine->mode = o->mode;
    mine->keep_sets = o->keep_sets;
    mine->recolor_hoods = o->recolor_hoods;
    mine->match_materials = o->match_materials;
    mine->recolor_cape = o->recolor_cape;
    mine->recolor_weapons = o->recolor_weapons;
    mine->scheme = o->scheme;
    if (o->squad_colors == MYC_SQUAD_YOURS && o->scheme == 0 && g.has_identity)
    {
        mine->source_cape = o->mode == MYC_CAPE_SOURCE ? g.identity.cape : 0;
        mine->source_kit = o->mode == MYC_ARMOR_FROM_HELMET ? g.identity.helmet : (o->mode == MYC_HELMET_FROM_ARMOR ? g.identity.armor : 0);
    }
    g.has_squad_mine = 1;
}

void myc_addon_cloak_local(void)
{
    if (!g.has_cloak) return;
    if (g.options.hide_cape == MYC_HIDE_OFF) { myc_cloak_drop(&g.cloak, "local", 1); return; }
    if (g.has_identity) myc_cloak_wear(&g.cloak, "local", g.watch.kept, 0, g.frame);
}

/* The local player's UI preview, located with the identity; kept while it is the same slot record (locate_ui). */
static void MycAdLocateUi(const MycIdentity* identity, uint32_t frame)
{
    MycWhere where;
    int found = myc_preview_locate(identity->ui_slot, identity->has_ui_slot, &where);
    if (g.has_ui && found && (g.ui.where.record == where.record || (g.has_lineup && g.ui.where.system == where.system))) return;
    if (g.has_ui)
    {
        myc_controller_restore(&g.ui_controller, frame);
        if (g.has_lineup) myc_lineup_clear(&g.lineup, frame);
    }
    g.has_ui = found;
    if (!found) return;
    memset(&g.ui, 0, sizeof g.ui);
    g.ui.where = where;
    myc_preview_watch_init(&g.ui.watch, &g.ui.where);
}

void myc_addon_adopt(const MycIdentity* identity, uint32_t frame)
{
    g.identity = *identity;
    g.has_identity = 1;
    g.slot = myc_avatar_preview_slot(&g.identity);
    MycAdSquadSettings();
    myc_watch_init(&g.watch, &g.identity, g.slot);
    myc_watch_changed(&g.watch, 1);
    g.next_verify = frame + MYC_VERIFY_FRAMES;
    g.dirty = 1;
    g.found_at = frame;
    g.has_found_at = 1;
    myc_addon_cloak_local();
    MycAdLocateUi(&g.identity, frame);
    if (myc_weapons_on())
    {
        myc_loadout_adopt(&g.loadout, g.identity.avatar);
        myc_loadout_replan(&g.loadout);
    }
    char ui[48] = "";
    if (g.has_ui) snprintf(ui, sizeof ui, ", UI preview slot %d", g.ui.where.slot);
    myc_notef("Local Helldiver: avatar %u, helmet %08x, armor %08x, body %u%s%s.", g.identity.avatar_index, g.identity.helmet,
        g.identity.armor, g.identity.body, g.slot != 0 ? ", preview slot found" : "", ui);
}

/* A kept game-data reader (release_reader) closed: when the UI preview closes, the Helldiver is lost or no job came for
 * KEEP_FRAMES frames; never under a running job (its finish keeps or closes it). The worker closes it (its files'
 * handles: about 0.09 ms each in game, which the Lua spread over binding checks, CLOSES_PER_CHECK at a time). */
void myc_addon_close_kept(void)
{
    if (!g.has_reader_kept || g.job) return;
    g.has_reader_kept = 0;
    g.close_due = 1;
    myc_addon_close_step();
}

static void MycAdWhy(const char* prefix, const char* why)
{
    if (g.has_why && strcmp(g.why, why) == 0) return;
    snprintf(g.why, sizeof g.why, "%s", why);
    g.has_why = 1;
    myc_notef("%s (%s).", prefix, why);
}

void myc_addon_lose(uint32_t frame, const char* why)
{
    g.has_identity = 0;
    g.has_found_at = 0;
    g.slot = 0;
    g.next_resolve = frame + MYC_RESOLVE_FRAMES;
    myc_controller_prune(&g.controller);
    if (g.has_cloak) myc_cloak_drop(&g.cloak, "local", 0);
    if (g.has_loadout) myc_loadout_clear(&g.loadout, frame);
    if (g.has_ui)
    {
        myc_controller_restore(&g.ui_controller, frame);
        if (g.has_lineup) myc_lineup_clear(&g.lineup, frame);
        g.has_ui = 0;
    }
    myc_addon_close_kept();
    MycAdWhy("No local Helldiver", why);
}

static void MycAdResolve(uint32_t frame)
{
    g.next_resolve = frame + MYC_RESOLVE_FRAMES;
    const char* why;
    int found;
    if (myc_avatar_resolve(&g.probe, &why, &found))
    {
        g.has_why = 0;
        myc_addon_adopt(&g.probe, frame);
        return;
    }
    MycAdWhy("Waiting for the local Helldiver", why);
    myc_addon_plan_ahead(found);
}

MycApplyTo myc_apply_to(uintptr_t units_at, uint32_t body, uintptr_t slot)
{
    MycApplyTo to;
    memset(&to, 0, sizeof to);
    to.units_at = units_at;
    to.body = body;
    to.slot = slot;
    return to;
}

/* New units of the same Helldiver, kits and options: the applied result bound to them at once (rebind). */
static int MycAdRebind(uint32_t frame)
{
    MycResult* result = g.controller.result;
    const MycRequest* r = &g.applied;
    const MycIdentity* id = &g.identity;
    if (result == NULL || !g.has_applied || g.dirty || myc_options_changed(r) || myc_kits_changed(r, id->helmet, id->armor, id->body, id->cape))
        return 0;
    int capes = myc_cape_counts(r->mode, r->scheme, r->capes);
    if (!myc_records_same(NULL, result, id->helmet, id->armor, id->cape, capes)) return 0;
    MycApplyTo to = myc_apply_to(id->units_at, id->body, g.slot);
    char why[160];
    myc_controller_apply(&g.controller, result, &to, frame, why, sizeof why);
    return 1;
}

/* Resolves the local player again (verify): another Helldiver, kits or preview slot adopted. */
static void MycAdVerify(uint32_t frame, int changed)
{
    g.next_verify = frame + MYC_VERIFY_FRAMES;
    const char* why;
    int found;
    if (!myc_avatar_resolve(&g.probe, &why, &found)) { myc_addon_lose(frame, why); return; }
    uintptr_t slot = myc_avatar_preview_slot(&g.probe);
    int rebound = 0;
    if (!MycAdSameIdentity(&g.probe, &g.identity) || slot != g.slot) myc_addon_adopt(&g.probe, frame);
    else if (g.active && myc_options_cape_counts(MYC_TARGET_AVATAR) && g.probe.cape != g.identity.cape)
    {
        g.dirty = 1;
        if (myc_weapons_on()) myc_loadout_replan(&g.loadout);
    }
    else if (changed && g.active)
    {
        rebound = MycAdRebind(frame);
        g.dirty = g.dirty || !rebound;
    }
    g.identity.cape = g.probe.cape;
    if (changed && !rebound && g.controller.nbindings > 0) myc_controller_prune(&g.controller);
    if (changed) myc_addon_cloak_local();
}

/* Every CHECK_FRAMES frames: one recolored material per runtime texture still holds its texture (check_bindings). */
static void MycAdCheckBindings(uint32_t frame)
{
    g.next_check = frame + MYC_CHECK_FRAMES;
    if (g.controller.probes > 0 && !myc_controller_check(&g.controller))
    {
        g.dirty = 1;
        myc_note("The game put an original color texture back on a recolored material; applying again.");
    }
    if (g.has_ui && g.ui_controller.probes > 0 && !myc_controller_check(&g.ui_controller)) g.ui.dirty = 1;
    if (g.has_lineup && myc_lineup_any(&g.lineup)) myc_lineup_check(&g.lineup);
    if (myc_weapons_on()) myc_loadout_check(&g.loadout, frame);
    if (g.has_cloak && g.cloak.ntargets > 0) myc_cloak_check(&g.cloak, frame);
    if (g.has_reader_kept && frame - g.reader_kept >= MYC_KEEP_FRAMES) myc_addon_close_kept();
    if (g.close_due) myc_addon_close_step(); /* the worker was busy when it was due */
}

/* ---- the UI preview ----------------------------------------------------------------------------------------------- */

void myc_addon_ui_hidden(uint32_t frame)
{
    MycUi* ui = &g.ui;
    if (!ui->shown) return;
    ui->shown = ui->dirty = ui->has_kits = 0;
    myc_controller_restore(&g.ui_controller, frame);
    myc_addon_close_kept();
}

static void MycAdUiKits(MycUi* ui)
{
    uint32_t helmet, armor, body, cape;
    myc_preview_slot_kits(&ui->watch, ui->where.slot, &helmet, &armor, &body, &cape);
    if (!ui->has_kits || helmet != ui->helmet || armor != ui->armor || body != ui->body
        || (myc_options_cape_counts(MYC_TARGET_UI) && cape != ui->cape))
        ui->dirty = 1;
    ui->helmet = helmet;
    ui->armor = armor;
    ui->body = body;
    ui->cape = cape;
    ui->has_kits = 1;
}

static void MycAdUiUnits(MycUi* ui, uint32_t frame)
{
    const MycRequest* r = &ui->applied;
    MycResult* result = g.ui_controller.result;
    int stale = ui->dirty || result == NULL || !ui->has_applied || myc_options_changed(r)
        || myc_kits_changed(r, ui->helmet, ui->armor, ui->body, ui->cape)
        || !myc_records_same(NULL, result, ui->helmet, ui->armor, ui->cape, myc_cape_counts(r->mode, r->scheme, r->capes));
    if (stale) { ui->dirty = 1; return; }
    MycApplyTo to = myc_apply_to(ui->where.units_at, r->body, 0);
    char why[160];
    myc_controller_apply(&g.ui_controller, result, &to, frame, why, sizeof why);
}

/* The preview's status as the player's own among the squad cards (own_status); -1: nothing more this poll. */
static int MycAdOwnStatus(MycUi* ui, int status, uint32_t frame)
{
    if (ui->watch.changes > 0 || g.lineup.stale || g.lineup.remap)
        g.lineup.own = myc_lineup_observe(&g.lineup, frame, &ui->watch, &g.identity, g.loopback);
    int own = g.lineup.own;
    if (own >= 0 && own != ui->where.slot)
    {
        myc_addon_ui_hidden(frame);
        myc_preview_retarget(&ui->where, own);
        myc_preview_reset(&ui->watch);
        return -1;
    }
    if (own < 0) return MYC_STATUS_ABSENT;
    return !ui->shown && status != MYC_STATUS_ABSENT ? MYC_STATUS_KITS : status;
}

/* lint: per-frame */
void myc_addon_poll_ui(uint32_t frame)
{
    MycUi* ui = &g.ui;
    int status = myc_preview_poll(&ui->watch);
    if (g.has_loadout && ui->watch.moved && myc_weapons_on()) myc_loadout_preview_changed(&g.loadout, frame);
    if (g.has_lineup) status = MycAdOwnStatus(ui, status, frame);
    if (status < 0) return;
    if (status == MYC_STATUS_ABSENT) { myc_addon_ui_hidden(frame); return; }
    ui->shown = 1;
    if (status == MYC_STATUS_KITS) MycAdUiKits(ui);
    else if (status == MYC_STATUS_UNITS) MycAdUiUnits(ui, frame);
}

/* The preview's check when due, then a job when one is needed, the avatar's first (preview_and_jobs). */
/* lint: per-frame */
static void MycAdPreviewAndJobs(uint32_t frame)
{
    if (g.has_ui && g.active && (g.ui.shown || frame % MYC_UI_GATE_FRAMES == 0)) myc_addon_poll_ui(frame);
    if (g.dirty && g.has_identity) myc_addon_start_job(frame, MYC_TARGET_AVATAR, NULL);
    else if (g.has_ui && g.ui.dirty) myc_addon_start_job(frame, MYC_TARGET_UI, NULL);
    else if (g.has_lineup && g.lineup.pending) myc_addon_start_job(frame, MYC_TARGET_CARD, NULL);
    else if (g.has_loadout && g.loadout.dirty && myc_weapons_on()) myc_addon_start_job(frame, MYC_TARGET_WEAPONS, NULL);
    else if (g.has_loadout && g.loadout.preview_dirty && myc_weapons_on()) myc_addon_start_job(frame, MYC_TARGET_UI_WEAPON, NULL);
}

/* ---- the squad ---------------------------------------------------------------------------------------------------- */

static void MycAdPollSync(uint32_t frame)
{
    g.next_sync = frame + MYC_SYNC_POLL_FRAMES;
    int n = myc_sync_poll(&g.session, frame, g.sync_text, g.loopback);
    myc_remote_update(&g.remote, frame, g.session.list, n, g.has_squad_mine ? &g.squad_mine : NULL, g.options.squad == MYC_SQUAD_EVERYONE);
    if (g.has_lineup) g.lineup.stale = 1;
    int everyone = g.options.hide_cape == MYC_HIDE_EVERYONE;
    if (g.has_cloak && myc_cloak_needed(&g.cloak, g.session.list, n > 0 ? n : 0, everyone))
    {
        g.ncloak_members = n > 0 ? n : 0;
        memcpy(g.cloak_members, g.session.list, sizeof g.cloak_members[0] * (size_t)g.ncloak_members);
        g.cloak_due = 1;
    }
}

/* The lobby poll, the capes of other players, one squadmate's watch or check, or a squadmate's job (sync_step). */
/* lint: per-frame */
static void MycAdSyncStep(uint32_t frame)
{
    if (frame >= g.next_sync && !(g.has_verified && g.verified_at == frame)) { MycAdPollSync(frame); return; }
    if (g.cloak_due)
    {
        g.cloak_due = 0;
        myc_cloak_update(&g.cloak, g.cloak_members, g.ncloak_members, g.options.hide_cape == MYC_HIDE_EVERYONE, frame);
        return;
    }
    if (g.has_cloak && frame % MYC_REMOTE_WATCH_FRAMES == 2 && myc_cloak_others(&g.cloak) > 0) { myc_cloak_step(&g.cloak, frame); return; }
    if (g.remote.nentries == 0 && g.remote.nretiring == 0) return;
    if (frame % MYC_REMOTE_WATCH_FRAMES == 0) { myc_remote_step(&g.remote, frame); return; }
    if (frame % MYC_CHECK_FRAMES == 1) { myc_remote_check(&g.remote); return; }
    if (g.remote.pending) myc_addon_start_job(frame, MYC_TARGET_REMOTE, NULL);
}

/* ---- the step ----------------------------------------------------------------------------------------------------- */

/* The local Helldiver's checks and jobs: 1 when this frame resolved it, ran a job or a save (local_step). */
/* lint: per-frame */
static int MycAdLocalStep(uint32_t frame)
{
    if (!g.has_identity)
    {
        if (g.has_warm) /* work ahead first; a resolve due now waits for the frame after the job */
        {
            if (myc_worker_busy(&g.worker)) return 1; /* a save or a close still on the worker: the next frame */
            g.has_warm = 0;
            myc_addon_start_job(frame, MYC_TARGET_PREPARE, &g.warm);
            return 1;
        }
        if (frame < g.next_resolve) return 0;
        MycAdResolve(frame);
        return 1;
    }
    int changed = myc_watch_changed(&g.watch, g.active && frame % 2 == 1);
    int verified = changed || frame >= g.next_verify;
    if (verified)
    {
        MycAdVerify(frame, changed);
        g.verified_at = frame;
        g.has_verified = 1;
    }
    else if (frame >= g.next_check) MycAdCheckBindings(frame);
    if (g.has_identity && myc_weapons_on()) myc_loadout_step(&g.loadout, frame, verified, 0);
    MycAdPreviewAndJobs(frame);
    if (g.job_frame == frame) return 1; /* a recolor job started this frame */
    if (verified || !g.has_save_at || frame < g.save_at) return 0;
    myc_addon_save_step(frame);
    return 1;
}

void myc_addon_settle(void* ctx, MycController* c, uint32_t frame, const char* what)
{
    int outcome;
    char why[160];
    int count = myc_controller_settle(c, frame, &outcome, why, sizeof why);
    if (count < 0) { myc_notef("%s: binding units that were not ready failed: %s", what, why); return; }
    if (count > 0) myc_notef("%s: %d textures bound late (their materials were not ready at the apply).", what, count);
    if (outcome == 2 && !g.expired_noted)
    {
        g.expired_noted = 1;
        myc_notef("%s: a unit of the plan still had no materials 2 s after the apply; it keeps its own colors.", what);
    }
}

/* Every frame, at the start of game.dll's frame update (where the Lua's update ran). */
/* lint: per-frame */
void myc_addon_step(void)
{
    uint32_t frame = ++g.frame;
    if (g.errors > 0 && ++g.clean_run == MYC_CLEAN_FRAMES) g.errors = 0;
    if (g.controller.nretired > 0) myc_controller_collect(&g.controller, frame);
    if (g.ui_controller.nretired > 0) myc_controller_collect(&g.ui_controller, frame);
    if (g.has_loadout && g.loadout.controller.nretired > 0) myc_loadout_collect(&g.loadout, frame);
    if (g.controller.has_pending) myc_addon_settle(NULL, &g.controller, frame, "Helldiver");
    if (g.ui_controller.has_pending) myc_addon_settle(NULL, &g.ui_controller, frame, "Preview");
    if (g.has_lineup && g.lineup.busy) myc_lineup_step(&g.lineup, frame, myc_addon_settle, NULL);
    if (g.has_cloak && frame <= g.cloak.young_until) myc_cloak_young(&g.cloak, frame);
    if (g.job) { myc_addon_job_step(frame); return; }
    if (MycAdLocalStep(frame) || !g.syncing || !g.has_identity) return;
    MycAdSyncStep(frame);
}

void myc_addon_error(const char* why)
{
    g.clean_run = 0;
    if (++g.errors == 1)
    {
        snprintf(g.error_burst, sizeof g.error_burst, "%s", why);
        myc_notef("error: %s", why);
    }
    if (g.errors >= MYC_ERROR_LIMIT) vpm_fail(g.self, "stopped after %d errors: %s", MYC_ERROR_LIMIT, g.error_burst);
}

/* ---- options ------------------------------------------------------------------------------------------------------ */

static void MycAdWeaponsOption(int recolor_hoods)
{
    if (!g.has_loadout) return;
    if (!myc_weapons_on()) { myc_loadout_clear(&g.loadout, g.frame); return; }
    if (!g.has_identity || recolor_hoods) return;
    if (!g.loadout.has_watch) myc_loadout_adopt(&g.loadout, g.identity.avatar);
    myc_loadout_replan(&g.loadout);
    if (!g.loadout.has_preview) myc_loadout_preview_changed(&g.loadout, g.frame);
}

static void MycAdSyncText(void)
{
    MycSettings o;
    memset(&o, 0, sizeof o);
    o.mode = g.options.mode;
    o.scheme = g.options.scheme;
    o.keep_sets = g.options.keep_sets;
    o.recolor_hoods = g.options.recolor_hoods;
    o.match_materials = g.options.match_materials;
    o.recolor_cape = g.options.recolor_cape;
    o.recolor_weapons = g.options.recolor_weapons;
    o.cape_hidden = g.options.cape_hidden;
    myc_sync_encode(&o, g.sync_text, sizeof g.sync_text);
}

void myc_addon_options_text(char* out, size_t size)
{
    const MycOptions* o = &g.options;
    snprintf(out, size, "mode %d, paint scheme %d, keep sets %s, recolor hoods %s, match materials %s, recolor cape %s, recolor "
        "weapons %s, recolor squadmates %d, squadmates colors %d, hide cape %d", o->mode, o->scheme, o->keep_sets ? "true" : "false",
        o->recolor_hoods ? "true" : "false", o->match_materials ? "true" : "false", o->recolor_cape ? "true" : "false",
        o->recolor_weapons ? "true" : "false", o->squad, o->squad_colors, o->hide_cape);
}

void myc_addon_init_sync_text(void)
{
    g.options.cape_hidden = g.options.hide_cape != MYC_HIDE_OFF;
    MycAdSyncText();
}

/* An option's new value (set_option): name as the Lua's, value a toggle's 0/1 or a choice's. */
void myc_addon_set_option(const char* name, int value, int toggle)
{
    MycOptions* o = &g.options;
    int* field = strcmp(name, "mode") == 0 ? &o->mode : strcmp(name, "scheme") == 0 ? &o->scheme
        : strcmp(name, "keep_sets") == 0 ? &o->keep_sets : strcmp(name, "recolor_hoods") == 0 ? &o->recolor_hoods
        : strcmp(name, "match_materials") == 0 ? &o->match_materials : strcmp(name, "recolor_cape") == 0 ? &o->recolor_cape
        : strcmp(name, "recolor_weapons") == 0 ? &o->recolor_weapons : strcmp(name, "squad") == 0 ? &o->squad
        : strcmp(name, "squad_colors") == 0 ? &o->squad_colors : strcmp(name, "hide_cape") == 0 ? &o->hide_cape : NULL;
    if (field == NULL || *field == value) return;
    *field = value;
    if (toggle) myc_notef("Option %s = %s.", name, value ? "true" : "false");
    else myc_notef("Option %s = %d.", name, value);
    if (strcmp(name, "hide_cape") == 0)
    {
        o->cape_hidden = o->hide_cape != MYC_HIDE_OFF;
        if (g.syncing) MycAdSyncText();
        if (g.has_identity) myc_addon_cloak_local();
        g.cloak_due = g.has_cloak && g.syncing;
        return;
    }
    MycAdSquadSettings();
    if (strcmp(name, "squad") == 0 || o->squad != MYC_SQUAD_OFF) g.next_sync = g.frame + 1;
    if (strcmp(name, "squad") == 0 || strcmp(name, "squad_colors") == 0) return;
    if (g.syncing) MycAdSyncText();
    int was_active = g.active;
    g.active = o->mode != MYC_OFF || o->scheme != 0;
    MycAdWeaponsOption(strcmp(name, "recolor_hoods") == 0);
    if (strcmp(name, "recolor_weapons") == 0) return;
    g.dirty = 1;
    if (!g.has_ui) return;
    if (g.active && !was_active)
    {
        myc_preview_reset(&g.ui.watch);
        g.ui.shown = g.ui.dirty = g.ui.has_kits = 0;
    }
    else if (g.ui.shown) g.ui.dirty = 1;
}

/* Every recolor put back: the local Helldiver's, the preview's, the other players', the weapons', the capes'. */
void myc_addon_restore_all(void)
{
    myc_controller_restore(&g.controller, g.frame);
    myc_controller_restore(&g.ui_controller, g.frame);
    if (g.has_sync) myc_remote_clear(&g.remote, g.frame);
    if (g.has_loadout) myc_loadout_clear(&g.loadout, g.frame);
    if (g.has_lineup) myc_lineup_clear(&g.lineup, g.frame);
    if (g.has_cloak) myc_cloak_clear(&g.cloak);
}
