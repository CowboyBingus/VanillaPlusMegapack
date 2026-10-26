/* Match Your Colors: Recolor Weapons for one Helldiver (loadout.lua, v1.5), 1:1: its weapons (primary, sidearm, support
 * and their attachments) are a target of their own with a controller of their own, planned against the mode's source.
 * Checks while on: every frame while a weapon in hand is recolored, one 8-byte read of its LUT binding (the game binds
 * the weapon's paint again on every reload); 1 frame in ROW_FRAMES one 48-byte read of the inventory row; on a change the
 * weapons resolved again. The Armory's preview weapon has a controller of its own. Another mod user's weapons (follow)
 * have their row checked to be still theirs. Game thread; no allocation on frames without a change. */
#include <stdio.h>
#include <string.h>
#include "myc_squad.h"

void myc_loadout_init(MycLoadout* l, const MycNative* native, MycPool* pool, void (*note)(const char* line), const char* follow)
{
    memset(l, 0, sizeof *l);
    l->native = native;
    l->note = note;
    snprintf(l->follow, sizeof l->follow, "%s", follow != NULL ? follow : "");
    myc_controller_init(&l->controller, native, pool);
    myc_controller_init(&l->shown, native, pool);
}

void myc_loadout_free(MycLoadout* l)
{
    myc_controller_free(&l->controller);
    myc_controller_free(&l->shown);
}

void myc_loadout_signature(const MycResolved* resolved, char* out, size_t size)
{
    size_t at = 0;
    out[0] = 0;
    for (int slot = 1; resolved != NULL && slot <= 3 && at < size; slot++)
    {
        if (!resolved->has[slot]) continue;
        const MycWeapon* w = &resolved->list[slot];
        at += (size_t)snprintf(out + at, size - at, "%s%d:%016llx:", at > 0 ? "|" : "", slot, (unsigned long long)w->name);
        for (int role = 0; role <= 4 && at < size; role++)
        {
            char name[17] = "";
            if (w->attachments[role] != 0) snprintf(name, sizeof name, "%016llx", (unsigned long long)w->attachments[role]);
            at += (size_t)snprintf(out + at, size - at, "%s%s=%s", role ? ";" : "", name, w->overrides[role].has ? w->overrides[role].text : "");
        }
    }
}

/* The resolved weapons as a controller's fixed units. */
static void MycLoTo(const MycLoadout* l, const MycWeapon* single, MycApplyTo* to)
{
    const MycWeapon* list[4] = {NULL, NULL, NULL, NULL};
    if (single != NULL) list[1] = single;
    else
        for (int slot = 1; slot <= 3; slot++) list[slot] = l->resolved.has[slot] ? &l->resolved.list[slot] : NULL;
    memset(to, 0, sizeof *to);
    to->fixed = 1;
    to->nunits = myc_weapons_units(list, to->units, MYC_FIXED_UNITS);
}

/* The weapon in hand's LUT binding to watch (its main unit's first bound LUT slot). */
static void MycLoWatchEntry(MycLoadout* l)
{
    l->has_entry = 0;
    uint32_t held = l->resolved.held;
    if (!l->has_resolved || held < 1 || held > 3 || !l->resolved.has[held]) return;
    const MycWeapon* w = &l->resolved.list[held];
    for (int i = 0; i < l->controller.nbindings; i++)
    {
        const MycBinding* b = &l->controller.bindings[i];
        if (b->unit != w->unit || b->slot != MYC_LUT_SLOT) continue;
        uint64_t entry = myc_binding_entry(b->material, MYC_LUT_SLOT);
        if (entry != 0) { l->entry = entry; l->texture = b->texture; l->has_entry = 1; }
        return;
    }
}

static int MycLoRebind(MycLoadout* l, uint32_t frame)
{
    MycApplyTo to;
    char why[160];
    MycLoTo(l, NULL, &to);
    int count = myc_controller_apply(&l->controller, l->controller.result, &to, frame, why, sizeof why);
    l->rebinds++;
    MycLoWatchEntry(l);
    return count;
}

void myc_loadout_adopt(MycLoadout* l, uint32_t avatar)
{
    l->has_where = myc_weapons_locate(avatar, l->follow[0] != 0, &l->where);
    l->has_watch = l->has_where;
    if (l->has_watch) myc_inventory_watch_init(&l->watch, &l->where);
    l->has_entry = 0;
    l->changed = l->has_watch;
    myc_controller_prune(&l->controller);
}

/* Another mod user's row no longer theirs: located again (moved). */
static int MycLoMoved(MycLoadout* l)
{
    if (l->follow[0] == 0 || !l->has_where || myc_weapons_owned(&l->where)) return 0;
    MycInventoryWhere before = l->where;
    l->moves++;
    myc_loadout_adopt(l, before.avatar);
    char line[256];
    if (!l->has_where)
        snprintf(line, sizeof line, "%s weapons: their row is another Helldiver's now and they have none (dead or gone); "
            "found again when they are back.", l->follow);
    else if (l->where.row == before.row && l->where.owner == before.owner)
    {
        l->where.owner = 0;
        snprintf(line, sizeof line, "%s weapons: their row read as moved but was not (the inventory reads differently); "
            "it is no longer checked.", l->follow);
    }
    else snprintf(line, sizeof line, "%s weapons: the game moved their row (%u -> %u); found again.", l->follow, before.index, l->where.index);
    l->note(line);
    return 1;
}

void myc_loadout_clear(MycLoadout* l, uint32_t frame)
{
    myc_controller_restore(&l->controller, frame);
    myc_controller_restore(&l->shown, frame);
    l->has_where = l->has_watch = l->has_resolved = l->has_entry = l->has_sig = 0;
    l->dirty = l->changed = l->reload = l->has_preview = l->preview_dirty = 0;
}

void myc_loadout_replan(MycLoadout* l)
{
    if (l->has_watch) { l->dirty = 1; l->changed = 1; }
    if (l->has_preview) l->preview_dirty = 1;
}

/* The resolve after a change: the same weapons and paints bound again at once, others a job. */
static void MycLoSettle(MycLoadout* l, uint32_t frame)
{
    if (l->changed && MycLoMoved(l)) return;
    static MycResolved resolved;
    if (!l->has_where || !myc_weapons_resolve(&l->where, l->copy, &resolved)) return;
    static char sig[MYC_WEAPONS_SIG];
    myc_loadout_signature(&resolved, sig, sizeof sig);
    l->resolved = resolved;
    l->has_resolved = 1;
    if (l->reload) l->reloads++;
    l->changed = l->reload = 0;
    if (sig[0] == 0) { l->has_entry = 0; return; }
    if (!l->has_sig || strcmp(sig, l->sig) != 0 || l->controller.result == NULL || l->dirty)
    {
        l->dirty = 1;
        snprintf(l->pending_sig, sizeof l->pending_sig, "%s", sig);
        l->has_pending_sig = 1;
        return;
    }
    MycLoRebind(l, frame);
}

/* lint: per-frame */
int myc_loadout_step(MycLoadout* l, uint32_t frame, int busy, int every)
{
    if (!l->has_watch) return 0;
    if (l->has_entry && !myc_inventory_bound(&l->watch, l->entry, l->texture)) l->reload = 1;
    if ((every || frame % MYC_ROW_FRAMES == MYC_ROW_PHASE) && myc_inventory_row_changed(&l->watch)) l->changed = 1;
    if (busy || !(l->changed || l->reload)) return 0;
    MycLoSettle(l, frame);
    return 1;
}

int myc_loadout_request(MycLoadout* l, MycRequest* r)
{
    if (!l->dirty || !l->has_resolved) return 0;
    l->dirty = 0;
    r->nweapons = 0;
    for (int slot = 1; slot <= 3; slot++)
        if (l->resolved.has[slot]) r->weapons[r->nweapons++] = l->resolved.list[slot];
    if (r->nweapons == 0) return 0;
    if (l->has_pending_sig) snprintf(r->sig, sizeof r->sig, "%s", l->pending_sig);
    else myc_loadout_signature(&l->resolved, r->sig, sizeof r->sig);
    return 1;
}

/* A weapons plan that could not be bound (a texture not made): the line the Lua's guard wrote for the error. */
static void MycLoError(MycLoadout* l, const char* why)
{
    char line[200];
    snprintf(line, sizeof line, "Weapons: error: %s", why);
    l->note(line);
}

int myc_loadout_finish(MycLoadout* l, MycResult* result, const MycRequest* request, uint32_t frame)
{
    l->jobs++;
    static char sig[MYC_WEAPONS_SIG];
    myc_loadout_signature(l->has_resolved ? &l->resolved : NULL, sig, sizeof sig);
    if (strcmp(request->sig, sig) != 0) { l->dirty = 1; return -1; }
    MycApplyTo to;
    char why[160];
    MycLoTo(l, NULL, &to);
    int count = myc_controller_apply(&l->controller, result, &to, frame, why, sizeof why);
    if (count < 0) { MycLoError(l, why); return -1; }
    l->has_sig = result->action == MYC_APPLY;
    if (l->has_sig) snprintf(l->sig, sizeof l->sig, "%s", request->sig);
    MycLoWatchEntry(l);
    return count;
}

static void MycLoCheckShown(MycLoadout* l, uint32_t frame)
{
    if (l->shown.nbindings > 0 && l->native->alive(l->shown.bindings[0].unit) == 0)
    {
        myc_controller_restore(&l->shown, frame);
        l->has_preview = 0;
    }
}

void myc_loadout_check(MycLoadout* l, uint32_t frame)
{
    if (l->controller.probes > 0 && !myc_controller_check(&l->controller) && l->controller.result != NULL && l->has_resolved)
        MycLoRebind(l, frame);
    if (l->shown.probes > 0) MycLoCheckShown(l, frame);
    MycLoMoved(l);
}

void myc_loadout_collect(MycLoadout* l, uint32_t frame)
{
    if (l->controller.nretired > 0) myc_controller_collect(&l->controller, frame);
    if (l->shown.nretired > 0) myc_controller_collect(&l->shown, frame);
}

void myc_loadout_preview_changed(MycLoadout* l, uint32_t frame)
{
    MycWeapon now;
    int has = myc_weapons_preview(&now) && l->native->alive(now.unit) != 0;
    if (!has)
    {
        if (l->has_preview) myc_controller_restore(&l->shown, frame);
        l->has_preview = l->preview_dirty = 0;
        return;
    }
    int applied = l->has_preview && l->has_applied;
    l->preview = now;
    l->has_preview = 1;
    myc_weapons_preview_key(&now, l->preview_key, sizeof l->preview_key);
    if (applied && strcmp(l->preview_applied, l->preview_key) == 0 && l->shown.result != NULL)
    {
        MycApplyTo to;
        char why[160];
        MycLoTo(l, &l->preview, &to);
        myc_controller_apply(&l->shown, l->shown.result, &to, frame, why, sizeof why);
    }
    else
    {
        l->has_applied = applied;
        l->preview_dirty = 1;
    }
}

int myc_loadout_preview_request(MycLoadout* l, MycRequest* r)
{
    if (!l->preview_dirty || !l->has_preview) return 0;
    l->preview_dirty = 0;
    MycWeapon* w = &r->weapons[0];
    memset(w, 0, sizeof *w);
    w->name = l->preview.name;
    w->unit = l->preview.unit;
    memcpy(w->units, l->preview.units, sizeof w->units);
    w->nunits = l->preview.nunits;
    memcpy(w->ids, l->preview.ids, sizeof w->ids);
    w->nids = l->preview.nids;
    w->has_ids = 1;
    r->nweapons = 1;
    snprintf(r->sig, sizeof r->sig, "%s", l->preview_key);
    return 1;
}

int myc_loadout_finish_preview(MycLoadout* l, MycResult* result, const MycRequest* request, uint32_t frame)
{
    MycWeapon now;
    char key[256];
    if (!myc_weapons_preview(&now) || (myc_weapons_preview_key(&now, key, sizeof key), strcmp(key, request->sig) != 0))
    {
        myc_loadout_preview_changed(l, frame);
        return 0;
    }
    l->previews++;
    l->preview = now;
    l->has_preview = 1;
    snprintf(l->preview_key, sizeof l->preview_key, "%s", key);
    MycApplyTo to;
    char why[160];
    MycLoTo(l, &l->preview, &to);
    int count = myc_controller_apply(&l->shown, result, &to, frame, why, sizeof why);
    if (count < 0) { MycLoError(l, why); return -1; }
    l->has_applied = result->action == MYC_APPLY;
    snprintf(l->preview_applied, sizeof l->preview_applied, "%s", l->has_applied ? key : "");
    return count;
}
