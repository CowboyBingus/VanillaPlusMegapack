/* Match Your Colors: other mod users' Helldivers (remote.lua), 1:1. From each sync poll, every other player who shares
 * valid settings gets an entry: their player record and kits, a watch of their 120 bytes of unit refs and a controller of
 * their own. Recolor Squadmates: players who share nothing take this player's settings (mine), or every player does
 * (everyone). An entry whose player has no Helldiver here (dead) is kept, its textures with it. Their jobs run in the
 * component's single job slot after the local avatar and preview. Game thread. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_squad.h"

void myc_remote_init(MycRemote* r, const MycNative* native, MycPool* pool, void (*note)(const char* line),
    MycRecordsSame records_same, void* ctx, int weapons)
{
    memset(r, 0, sizeof *r);
    r->native = native;
    r->pool = pool;
    r->note = note;
    r->records_same = records_same;
    r->records_ctx = ctx;
    r->weapons = weapons;
}

static void MycRemKey(const MycMember* m, char* out) { snprintf(out, MYC_PEER_KEY, "%08x%08x", m->peer_high, m->peer_low); }

static MycRemoteEntry* MycRemFind(MycRemote* r, const char* key)
{
    for (int i = 0; i < r->nentries; i++)
        if (strcmp(r->entries[i]->key, key) == 0) return r->entries[i];
    return NULL;
}

void myc_remote_request_of(int target, const char* key, const MycSettings* s, uint32_t helmet, uint32_t armor, uint32_t body,
    uint32_t cape, MycRequest* out)
{
    memset(out, 0, sizeof *out);
    out->target = target;
    snprintf(out->key, sizeof out->key, "%s", key);
    out->mode = s->mode;
    out->keep_sets = s->keep_sets;
    out->keep_hoods = !s->recolor_hoods;
    out->materials = s->match_materials;
    out->scheme = s->scheme;
    out->capes = s->recolor_cape;
    out->has_kits = 1;
    out->helmet = helmet;
    out->armor = armor;
    out->body = body;
    out->cape = s->source_cape != 0 ? s->source_cape : cape;
    out->source_kit = s->source_kit;
    out->source_cape = s->source_cape;
}

static MycRemoteEntry* MycRemAdd(MycRemote* r, const char* key)
{
    if (r->nentries >= MYC_REMOTE_ENTRIES) return NULL;
    MycRemoteEntry* e = calloc(1, sizeof *e);
    MycController* c = calloc(1, sizeof *c);
    if (e == NULL || c == NULL) { free(e); free(c); return NULL; }
    snprintf(e->key, sizeof e->key, "%s", key);
    myc_controller_init(c, r->native, r->pool);
    e->controller = c;
    r->entries[r->nentries++] = e;
    return e;
}

static void MycRemRetire(MycRemote* r, void* block, MycController* a, MycController* b)
{
    if (r->nretiring < 64) r->retiring[r->nretiring++] = (MycRetiring){block, a, b};
    else { myc_controller_free(a); if (b != NULL) myc_controller_free(b); free(block); }
}

static void MycRemDropLoadout(MycRemote* r, MycRemoteEntry* e, uint32_t frame)
{
    myc_loadout_clear(e->loadout, frame);
    MycRemRetire(r, e->loadout, &e->loadout->controller, &e->loadout->shown);
    e->loadout = NULL;
}

/* An entry's weapons: a loadout of its own while its settings recolor them (weapons_of). */
static void MycRemWeapons(MycRemote* r, MycRemoteEntry* e, uint32_t frame)
{
    int want = r->weapons && e->has_settings && e->settings.recolor_weapons && (e->settings.mode != MYC_OFF || e->settings.scheme != 0);
    if (!want) { if (e->loadout != NULL) MycRemDropLoadout(r, e, frame); return; }
    if (e->loadout == NULL)
    {
        char follow[64];
        snprintf(follow, sizeof follow, "Sync: %s", e->key);
        e->loadout = malloc(sizeof(MycLoadout));
        if (e->loadout == NULL) return;
        myc_loadout_init(e->loadout, r->native, r->pool, r->note, follow);
    }
    if (!e->has_identity) return;
    myc_loadout_adopt(e->loadout, e->identity.avatar);
    myc_loadout_replan(e->loadout);
    r->pending = 1;
}

static void MycRemDrop(MycRemote* r, const char* key, uint32_t frame)
{
    MycRemoteEntry* e = MycRemFind(r, key);
    if (e == NULL) return;
    char line[256];
    myc_controller_restore(e->controller, frame);
    if (e->controller->nretired > 0) MycRemRetire(r, e->controller, e->controller, NULL);
    else { myc_controller_free(e->controller); free(e->controller); }
    if (e->loadout != NULL)
    {
        const MycLoadout* l = e->loadout;
        snprintf(line, sizeof line, "Sync: %s weapons: %d jobs, bound again %d times (%d reloads); their row moved %d times, found "
            "for a new Helldiver %d times.", e->key, l->jobs, l->rebinds, l->reloads, l->moves, e->found);
        r->note(line);
        MycRemDropLoadout(r, e, frame);
    }
    snprintf(line, sizeof line, "Sync: %s restored.", e->key);
    int at = 0;
    while (r->entries[at] != e) at++;
    memmove(&r->entries[at], &r->entries[at + 1], sizeof r->entries[0] * (size_t)(r->nentries - at - 1));
    r->nentries--;
    free(e);
    r->note(line);
}

static void MycRemIdentityOf(const MycPlayer* p, MycIdentity* out)
{
    memset(out, 0, sizeof *out);
    out->player = p->player;
    out->unit = p->unit;
    out->peer_low = p->peer_low;
    out->peer_high = p->peer_high;
}

/* Their weapons on a new avatar (a respawn): its own inventory row. */
static void MycRemFollowWeapons(MycRemote* r, MycRemoteEntry* e)
{
    MycLoadout* l = e->loadout;
    if (l == NULL || (l->has_where && l->where.avatar == e->identity.avatar)) return;
    myc_loadout_adopt(l, e->identity.avatar);
    e->found++;
    char line[160];
    if (l->has_where) snprintf(line, sizeof line, "Sync: %s new Helldiver: their weapons' row found (%u).", e->key, l->where.index);
    else snprintf(line, sizeof line, "Sync: %s new Helldiver: no weapons row of theirs yet.", e->key);
    r->note(line);
}

static MycApplyTo MycRemTo(const MycIdentity* id)
{
    MycApplyTo to;
    memset(&to, 0, sizeof to);
    to.units_at = id->units_at;
    to.body = id->body;
    return to;
}

/* New units of a player whose kits and records are the applied result's: bound at once (rebind). */
static int MycRemRebind(MycRemote* r, MycRemoteEntry* e, const MycPlayer* player, uint32_t frame)
{
    const MycRequest* a = &e->applied;
    MycResult* result = e->controller->result;
    if (e->dirty || !e->has_applied || result == NULL || r->records_same == NULL) return 0;
    MycIdentity p, identity;
    const char* why;
    MycRemIdentityOf(player, &p);
    int found = myc_avatar_resolve_remote(&p, &identity, &why);
    int capes = a->capes || (a->mode == MYC_CAPE_SOURCE && a->scheme == 0);
    uint32_t cape = a->source_cape != 0 ? a->source_cape : (found ? identity.cape : 0);
    if (!found || identity.helmet != a->helmet || identity.armor != a->armor || identity.body != a->body || (capes && cape != a->cape)
        || !r->records_same(r->records_ctx, result, identity.helmet, identity.armor, cape, capes))
        return 0;
    e->identity = identity;
    e->has_identity = 1;
    e->player = *player;
    myc_watch_init(&e->watch, &identity, 0);
    myc_watch_changed(&e->watch, 0);
    MycApplyTo to = MycRemTo(&identity);
    char text[160];
    myc_controller_apply(e->controller, result, &to, frame, text, sizeof text);
    r->rebinds++;
    MycRemFollowWeapons(r, e);
    return 1;
}

static int MycRemMemo(char (*list)[MYC_PEER_KEY], int n, const char* key)
{
    for (int i = 0; i < n; i++)
        if (strcmp(list[i], key) == 0) return i;
    return -1;
}

static void MycRemForget(MycRemote* r, const char* key)
{
    int i = MycRemMemo(r->unmatched, r->nunmatched, key);
    if (i >= 0) { memmove(r->unmatched[i], r->unmatched[i + 1], sizeof r->unmatched[0] * (size_t)(r->nunmatched - i - 1)); r->nunmatched--; }
    i = MycRemMemo(r->missing, r->nmissing, key);
    if (i >= 0)
    {
        memmove(r->missing[i], r->missing[i + 1], sizeof r->missing[0] * (size_t)(r->nmissing - i - 1));
        memmove(&r->missing_count[i], &r->missing_count[i + 1], sizeof r->missing_count[0] * (size_t)(r->nmissing - i - 1));
        r->nmissing--;
    }
}

/* A member whose peer id names none of the players here: noted once (and with the players' ids per player count). */
static void MycRemNotFound(MycRemote* r, const char* key, int nplayers, int mine)
{
    char line[1024];
    if (MycRemMemo(r->unmatched, r->nunmatched, key) < 0 && r->nunmatched < MYC_SYNC_MAX_MEMBERS)
    {
        snprintf(r->unmatched[r->nunmatched++], MYC_PEER_KEY, "%s", key);
        snprintf(line, sizeof line, "Sync: %s %s; no Helldiver of theirs found here yet.", key, mine ? "takes your settings" : "shares settings");
        r->note(line);
    }
    int i = MycRemMemo(r->missing, r->nmissing, key);
    if (nplayers <= 1 || (i >= 0 && r->missing_count[i] == nplayers)) return;
    if (i < 0 && r->nmissing < MYC_SYNC_MAX_MEMBERS) { i = r->nmissing++; snprintf(r->missing[i], MYC_PEER_KEY, "%s", key); }
    if (i >= 0) r->missing_count[i] = nplayers;
    char players[512], session[256] = "";
    myc_avatar_players_text(players, sizeof players);
    if (r->session_text != NULL)
    {
        char text[240];
        r->session_text(text, sizeof text);
        snprintf(session, sizeof session, "; session: %s", text);
    }
    snprintf(line, sizeof line, "Sync: %s is none of the players here: %s%s.", key, players, session);
    r->note(line);
}

/* An entry for key kept current with player and settings: a job when they changed, else new units rebound (keep). */
static void MycRemKeep(MycRemote* r, const char* key, const MycPlayer* player, const MycSettings* settings, uint32_t frame, int mine)
{
    MycRemoteEntry* e = MycRemFind(r, key);
    if (e == NULL) e = MycRemAdd(r, key);
    if (e == NULL) return;
    e->mine = mine;
    e->absent = 0;
    int new_settings = !e->has_settings || !myc_settings_same(&e->settings, settings);
    if (new_settings || (e->player.unit != player->unit && !MycRemRebind(r, e, player, frame)))
    {
        e->settings = *settings;
        e->has_settings = 1;
        e->player = *player;
        e->dirty = 1;
        e->failures = 0;
        r->pending = 1;
    }
}

/* The poll's state (update's seen, matched, players). */
typedef struct MycRemPoll
{
    char seen[MYC_REMOTE_ENTRIES + MYC_MAX_PLAYERS][MYC_PEER_KEY];
    int nseen;
    uint32_t matched[MYC_MAX_PLAYERS];
    int nmatched;
    MycPlayer players[MYC_MAX_PLAYERS];
    int nplayers, has_players, sharing;
    MycWanted spare[MYC_SYNC_MAX_MEMBERS];
    int nspare;
} MycRemPoll;

static void MycRemPlayers(MycRemPoll* poll)
{
    if (!poll->has_players) { poll->nplayers = myc_avatar_players(poll->players); poll->has_players = 1; }
}

/* A member's settings: 1 with *out (theirs, or mine for them), 0 none. */
static int MycRemSettingsFor(const MycMember* m, const MycSettings* mine, int everyone, MycSettings* out, int* is_mine)
{
    MycSettings own;
    int has_own = m->has_text && myc_sync_decode(m->text, &own);
    *is_mine = 0;
    if (mine != NULL && (everyone || !has_own)) { *out = *mine; *is_mine = 1; return 1; }
    if (has_own) *out = own;
    return has_own;
}

static void MycRemSeen(MycRemPoll* poll, const char* key)
{
    if (poll->nseen < (int)(sizeof poll->seen / sizeof poll->seen[0])) snprintf(poll->seen[poll->nseen++], MYC_PEER_KEY, "%s", key);
}

/* One member into wanted (want) and its entry (visit/take). */
static void MycRemMember(MycRemote* r, MycRemPoll* poll, const MycMember* m, const MycSettings* mine, int everyone, uint32_t frame)
{
    char key[MYC_PEER_KEY];
    MycRemKey(m, key);
    if (m->is_local) snprintf(r->local_key, sizeof r->local_key, "%s", key);
    MycSettings own, s;
    int is_mine;
    poll->sharing |= !m->is_local && (m->failed || (m->has_text && myc_sync_decode(m->text, &own)));
    int has = MycRemSettingsFor(m, mine, everyone, &s, &is_mine);
    int kept_wanted = 0;
    const MycSettings* old = m->failed ? myc_remote_wanted(r, key, &kept_wanted) : NULL;
    if (old != NULL) { s = *old; has = 1; is_mine = kept_wanted; }
    if (has && poll->nspare < MYC_SYNC_MAX_MEMBERS)
    {
        MycWanted* w = &poll->spare[poll->nspare++];
        snprintf(w->key, sizeof w->key, "%s", key);
        w->settings = s;
        w->is_mine = is_mine;
    }
    MycRemoteEntry* kept = m->failed ? MycRemFind(r, key) : NULL;
    if (kept != NULL)
    {
        if (kept->has_settings && poll->nmatched < MYC_MAX_PLAYERS) poll->matched[poll->nmatched++] = kept->player.player;
        MycRemSeen(poll, key);
        return;
    }
    if (!MycRemSettingsFor(m, mine, everyone, &s, &is_mine)) return;
    MycRemPlayers(poll);
    const MycPlayer* player = NULL;
    for (int i = 0; i < poll->nplayers && player == NULL; i++)
        if (poll->players[i].peer_low == m->peer_low && poll->players[i].peer_high == m->peer_high && (!poll->players[i].is_local || m->is_local))
            player = &poll->players[i];
    MycRemoteEntry* e = MycRemFind(r, key);
    if (player == NULL)
    {
        if (e != NULL) { e->absent = 1; MycRemSeen(poll, key); }
        else MycRemNotFound(r, key, poll->nplayers, is_mine);
        return;
    }
    MycRemForget(r, key);
    if (poll->nmatched < MYC_MAX_PLAYERS) poll->matched[poll->nmatched++] = player->player;
    MycRemKeep(r, key, player, &s, frame, is_mine);
    MycRemSeen(poll, key);
}

/* The other players whom no member names take an unknown squadmate's settings, keyed 'player <entity id>'. */
static void MycRemStrays(MycRemote* r, MycRemPoll* poll, uint32_t frame)
{
    if (!r->has_unknown) return;
    MycRemPlayers(poll);
    for (int i = 0; i < poll->nplayers; i++)
    {
        const MycPlayer* p = &poll->players[i];
        int matched = 0;
        for (int k = 0; k < poll->nmatched; k++) matched |= poll->matched[k] == p->player;
        if (p->is_local || matched) continue;
        char key[MYC_PEER_KEY];
        snprintf(key, sizeof key, "player %u", p->player);
        MycRemSeen(poll, key);
        MycRemKeep(r, key, p, &r->unknown, frame, 1);
    }
}

void myc_remote_update(MycRemote* r, uint32_t frame, const MycMember* members, int n, const MycSettings* mine, int everyone)
{
    static MycRemPoll poll;
    memset(&poll, 0, sizeof poll);
    r->frame = frame;
    r->has_mine = mine != NULL;
    if (mine != NULL) r->mine = *mine;
    for (int i = 0; i < n; i++) MycRemMember(r, &poll, &members[i], mine, everyone, frame);
    memcpy(r->wanted, poll.spare, sizeof poll.spare[0] * (size_t)poll.nspare);
    r->nwanted = poll.nspare;
    r->has_unknown = mine != NULL && (everyone || !poll.sharing);
    if (r->has_unknown) r->unknown = *mine;
    MycRemStrays(r, &poll, frame);
    for (int i = r->nentries - 1; i >= 0; i--)
    {
        int seen = 0;
        for (int k = 0; k < poll.nseen; k++) seen |= strcmp(poll.seen[k], r->entries[i]->key) == 0;
        if (!seen) MycRemDrop(r, r->entries[i]->key, frame);
    }
}

const MycSettings* myc_remote_wanted(const MycRemote* r, const char* key, int* is_mine)
{
    for (int i = 0; i < r->nwanted; i++)
        if (strcmp(r->wanted[i].key, key) == 0) { if (is_mine != NULL) *is_mine = r->wanted[i].is_mine; return &r->wanted[i].settings; }
    return NULL;
}

/* ---- jobs --------------------------------------------------------------------------------------------------------- */

int myc_remote_request(MycRemote* r, MycRequest* out)
{
    int n = r->nentries;
    for (int step = 1; step <= n; step++)
    {
        int i = (r->served + step - 1) % n;
        MycRemoteEntry* e = r->entries[i];
        if (!e->dirty || e->absent || e->failures >= MYC_REMOTE_FAILURE_LIMIT) continue;
        e->dirty = 0;
        MycIdentity p;
        const char* why;
        MycRemIdentityOf(&e->player, &p);
        if (myc_avatar_resolve_remote(&p, &e->identity, &why))
        {
            e->has_identity = 1;
            myc_watch_init(&e->watch, &e->identity, 0);
            myc_watch_changed(&e->watch, 0);
            MycRemWeapons(r, e, r->frame);
            r->served = i + 1;
            myc_remote_request_of(MYC_TARGET_REMOTE, e->key, &e->settings, e->identity.helmet, e->identity.armor, e->identity.body,
                e->identity.cape, out);
            return 1;
        }
        e->failures++;
        char line[160];
        snprintf(line, sizeof line, "Sync: %s not resolved (%s).", e->key, why);
        r->note(line);
    }
    for (int step = 1; step <= n; step++)
    {
        int i = (r->served + step - 1) % n;
        MycRemoteEntry* e = r->entries[i];
        if (e->absent || e->loadout == NULL || !e->has_identity || e->failures >= MYC_REMOTE_FAILURE_LIMIT) continue;
        static MycRequest w;
        memset(&w, 0, sizeof w);
        if (!myc_loadout_request(e->loadout, &w)) continue;
        r->served = i + 1;
        myc_remote_request_of(MYC_TARGET_REMOTE, e->key, &e->settings, e->identity.helmet, e->identity.armor, e->identity.body,
            e->identity.cape, out);
        memcpy(out->weapons, w.weapons, sizeof w.weapons);
        out->nweapons = w.nweapons;
        snprintf(out->sig, sizeof out->sig, "%s", w.sig);
        return 1;
    }
    r->pending = 0;
    return 0;
}

static void MycRemFinishWeapons(MycRemote* r, MycRemoteEntry* e, int ok, MycResult* result, const MycRequest* request, const char* why,
    uint32_t frame)
{
    char line[256];
    if (!ok || e->loadout == NULL)
    {
        snprintf(line, sizeof line, "Sync: weapons of %s not recolored: %s", request->key, ok ? "off" : why);
        r->note(line);
        return;
    }
    int count = myc_loadout_finish(e->loadout, result, request, frame);
    r->pending |= e->loadout->dirty;
    if (count < 0) return;
    if (result->action == MYC_APPLY)
    {
        snprintf(line, sizeof line, "Sync: %s weapons recolored, %d materials.", request->key, count);
        r->note(line);
    }
    else if (!e->has_weapons_reason || strcmp(e->weapons_reason, result->reason) != 0)
    {
        snprintf(line, sizeof line, "Sync: %s weapons keep their colors (%s).", request->key, result->reason);
        r->note(line);
    }
    snprintf(e->weapons_reason, sizeof e->weapons_reason, "%s", result->reason);
    e->has_weapons_reason = 1;
}

void myc_remote_finish(MycRemote* r, int ok, MycResult* result, const MycRequest* request, const char* why, uint32_t frame)
{
    MycRemoteEntry* e = MycRemFind(r, request->key);
    if (e == NULL) return;
    if (request->nweapons > 0) { MycRemFinishWeapons(r, e, ok, result, request, why, frame); return; }
    char line[256];
    if (!ok)
    {
        e->failures++;
        e->dirty = e->failures < MYC_REMOTE_FAILURE_LIMIT;
        r->pending |= e->dirty;
        snprintf(line, sizeof line, "Sync: recolor of %s failed (%d/%d): %s", request->key, e->failures, MYC_REMOTE_FAILURE_LIMIT, why);
        r->note(line);
        return;
    }
    if (e->dirty) return;
    MycApplyTo to = MycRemTo(&e->identity);
    char text[160];
    int count = myc_controller_apply(e->controller, result, &to, frame, text, sizeof text);
    if (count < 0)
    {
        snprintf(line, sizeof line, "Sync: %s: error: %s", request->key, text);
        r->note(line);
        return;
    }
    e->applied = *request;
    e->has_applied = 1;
    r->jobs++;
    snprintf(line, sizeof line, "Sync: %s recolored, %d materials (%s).", request->key, count,
        result->action == MYC_APPLY ? (e->mine ? "your settings" : "shared settings") : result->reason);
    r->note(line);
}

/* lint: per-frame */
void myc_remote_step(MycRemote* r, uint32_t frame)
{
    r->frame = frame;
    int keep = 0;
    for (int i = 0; i < r->nretiring; i++)
    {
        MycRetiring* t = &r->retiring[i];
        int left = myc_controller_collect(t->a, frame) + (t->b != NULL ? myc_controller_collect(t->b, frame) : 0);
        if (left > 0) { r->retiring[keep++] = *t; continue; }
        myc_controller_free(t->a);
        if (t->b != NULL) myc_controller_free(t->b);
        free(t->block);
    }
    r->nretiring = keep;
    if (r->nentries == 0) return;
    r->cursor = r->cursor % r->nentries + 1;
    MycRemoteEntry* e = r->entries[r->cursor - 1];
    if (e->controller->nretired > 0) myc_controller_collect(e->controller, frame);
    if (e->loadout != NULL) myc_loadout_collect(e->loadout, frame);
    if (e->absent) return;
    if (e->has_identity && myc_watch_changed(&e->watch, 0) && !MycRemRebind(r, e, &e->player, frame)) { e->dirty = 1; r->pending = 1; }
    if (e->loadout == NULL) return;
    myc_loadout_step(e->loadout, frame, 0, 1);
    if (e->loadout->dirty) r->pending = 1;
}

void myc_remote_check(MycRemote* r)
{
    if (r->nentries == 0) return;
    MycRemoteEntry* e = r->entries[r->cursor % r->nentries];
    if (!e->absent && e->controller->probes > 0 && !myc_controller_check(e->controller)) { e->dirty = 1; r->pending = 1; }
    if (!e->absent && e->loadout != NULL) myc_loadout_check(e->loadout, r->frame);
}

void myc_remote_clear(MycRemote* r, uint32_t frame)
{
    while (r->nentries > 0)
    {
        char key[MYC_PEER_KEY];
        snprintf(key, sizeof key, "%s", r->entries[0]->key);
        MycRemDrop(r, key, frame);
    }
    r->nwanted = 0;
    r->has_unknown = 0;
    r->pending = 0;
}

void myc_remote_free(MycRemote* r)
{
    for (int i = 0; i < r->nentries; i++)
    {
        myc_controller_free(r->entries[i]->controller);
        free(r->entries[i]->controller);
        if (r->entries[i]->loadout != NULL) { myc_loadout_free(r->entries[i]->loadout); free(r->entries[i]->loadout); }
        free(r->entries[i]);
    }
    r->nentries = 0;
    for (int i = 0; i < r->nretiring; i++)
    {
        myc_controller_free(r->retiring[i].a);
        if (r->retiring[i].b != NULL) myc_controller_free(r->retiring[i].b);
        free(r->retiring[i].block);
    }
    r->nretiring = 0;
}
