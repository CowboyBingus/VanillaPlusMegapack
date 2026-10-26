/* Match Your Colors: the squad cards of the loadout screen (lineup.lua, v1.5), 1:1. Each player's Helldiver shows in a
 * UiPreviewSystem player slot placed by the player's session slot. Owners, read again only when a slot shows, changes
 * or goes: the network context [game + 0x347CEF0], its session peers (count +0x16390, 32-byte entries from +0x16398:
 * u64 peer, u32 UI slot +20) and the local peer (+0xB398). A slot of another peer that shows a squadmate's desired kits is
 * that peer's card; the player's own preview stays the component's. Every other card takes its player's settings from
 * the last lobby poll, a controller of its own; its job runs in the single job slot after the local ones. Game thread. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_squad.h"

#define CONTEXT 0x347CEF0u
#define SESSION 0x16390u
#define SESSION_BYTES 136
#define ENTRY_BYTES 32
#define ENTRY_SLOT 20
#define MAX_ENTRIES 4
#define LOCAL_PEER 0xB398u
#define SLOTS MYC_PREVIEW_SLOTS

static uint32_t MycLuLe32(const uint8_t* p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

void myc_lineup_init(MycLineup* l, const MycNative* native, MycPool* pool, void (*note)(const char* line), MycRemote* remote,
    MycRecordsSame records_same, void* ctx)
{
    memset(l, 0, sizeof *l);
    l->native = native;
    l->pool = pool;
    l->note = note;
    l->remote = remote;
    l->records_same = records_same;
    l->records_ctx = ctx;
    l->remap = 1;
    l->served = SLOTS - 1;
    l->own = -1;
    remote->session_text = myc_lineup_session_text;
}

/* The session's peers by UI slot (has[s]) and the local peer; 0 without a network context. */
static int MycLuPeers(uint32_t lows[SLOTS], uint32_t highs[SLOTS], int has[SLOTS], uint32_t* low, uint32_t* high)
{
    for (int s = 0; s < SLOTS; s++) has[s] = 0;
    uint64_t context = vpm_game_u64(CONTEXT);
    uint8_t b[SESSION_BYTES];
    if (context < 0x10000 || context >= 0x800000000000ull || !vpm_read((uintptr_t)context + LOCAL_PEER, b, 8)) return 0;
    *low = MycLuLe32(b);
    *high = MycLuLe32(b + 4);
    if (!vpm_read((uintptr_t)context + SESSION, b, SESSION_BYTES)) return 1;
    uint32_t count = MycLuLe32(b);
    for (uint32_t i = 0; i < (count < MAX_ENTRIES ? count : MAX_ENTRIES); i++)
    {
        const uint8_t* e = b + 8 + ENTRY_BYTES * i;
        uint32_t slot = MycLuLe32(e + ENTRY_SLOT), pl = MycLuLe32(e), ph = MycLuLe32(e + 4);
        if (slot < SLOTS && (pl != 0 || ph != 0)) { lows[slot] = pl; highs[slot] = ph; has[slot] = 1; }
    }
    return 1;
}

void myc_lineup_session_text(char* out, size_t size)
{
    uint32_t lows[SLOTS], highs[SLOTS], low, high;
    int has[SLOTS];
    if (!MycLuPeers(lows, highs, has, &low, &high)) { snprintf(out, size, "no session"); return; }
    size_t at = 0;
    out[0] = 0;
    for (int s = 0; s < SLOTS && at < size; s++)
        if (has[s])
            at += (size_t)snprintf(out + at, size - at, "%s%08x%08x slot %d%s", at ? ", " : "", highs[s], lows[s], s,
                lows[s] == low && highs[s] == high ? " (this machine's)" : "");
    if (at == 0) snprintf(out, size, "no session peers");
}

static int MycLuFree(const MycLineup* l, int s)
{
    return s >= 0 && s < SLOTS && l->owner_kind[s] == MYC_OWNER_NONE && myc_preview_status(l->watch, s) != MYC_STATUS_ABSENT;
}

static int MycLuShows(const MycLineup* l, int s, uint32_t helmet, uint32_t armor, uint32_t cape)
{
    uint32_t h, a, b, c;
    myc_preview_slot_kits(l->watch, s, &h, &a, &b, &c);
    return h == helmet && a == armor && c == cape;
}

/* The player's own preview among the shown slots no card took (own_slot), or -1. */
static int MycLuOwnSlot(const MycLineup* l, const MycIdentity* identity, int session_slot)
{
    uint32_t helmet, armor, cape;
    int has = myc_avatar_desired_kits(identity->player, &helmet, &armor, &cape);
    int ui = identity->has_ui_slot ? (int)identity->ui_slot : -1;
    int order[6] = {session_slot, ui, 0, 1, 2, 3};
    for (int i = 0; has && i < 6; i++)
        if (MycLuFree(l, order[i]) && MycLuShows(l, order[i], helmet, armor, cape)) return order[i];
    if (MycLuFree(l, session_slot)) return session_slot;
    if (MycLuFree(l, ui)) return ui;
    return -1;
}

/* The owner of each shown player slot (Lineup.owners). */
static void MycLuOwners(MycLineup* l, const MycIdentity* identity)
{
    uint32_t lows[SLOTS], highs[SLOTS], low = 0, high = 0;
    int has[SLOTS], shown = 0, session_slot = -1, have_desired = 0, ndesired = 0;
    MycDesired desired[MYC_MAX_PLAYERS];
    int context = MycLuPeers(lows, highs, has, &low, &high);
    for (int s = 0; s < SLOTS; s++)
    {
        if (context && has[s] && lows[s] == low && highs[s] == high) session_slot = s;
        if (myc_preview_status(l->watch, s) != MYC_STATUS_ABSENT) shown++;
        l->owner_kind[s] = MYC_OWNER_NONE;
        if (!context || !has[s] || (lows[s] == low && highs[s] == high) || myc_preview_status(l->watch, s) == MYC_STATUS_ABSENT) continue;
        if (!have_desired) { ndesired = myc_avatar_others_desired(desired); have_desired = 1; }
        for (int i = 0; i < ndesired; i++)
            if (MycLuShows(l, s, desired[i].helmet, desired[i].armor, desired[i].cape))
            {
                l->owner_kind[s] = MYC_OWNER_PEER;
                snprintf(l->owner_key[s], MYC_PEER_KEY, "%08x%08x", highs[s], lows[s]);
                break;
            }
    }
    int own = MycLuOwnSlot(l, identity, session_slot);
    if (own >= 0) l->owner_kind[own] = MYC_OWNER_LOCAL;
    for (int s = 0; s < SLOTS; s++)
        if (shown > 1 && MycLuFree(l, s)) l->owner_kind[s] = MYC_OWNER_SQUAD;
}

/* The settings a card's owner takes: a squadmate's from the last poll, an unknown squadmate's this player's when given. */
static const MycSettings* MycLuSettings(const MycLineup* l, int kind, const char* key, int* is_mine)
{
    *is_mine = 0;
    if (kind == MYC_OWNER_SQUAD)
    {
        *is_mine = 1;
        return l->remote->has_unknown ? &l->remote->unknown : NULL;
    }
    return kind == MYC_OWNER_PEER ? myc_remote_wanted(l->remote, key, is_mine) : NULL;
}

static void MycLuOwnersText(const MycLineup* l, char* out, size_t size)
{
    size_t at = 0;
    int others = 0;
    out[0] = 0;
    for (int s = 0; s < SLOTS && at < size; s++)
    {
        int kind = l->owner_kind[s], mine;
        if (kind == MYC_OWNER_LOCAL) { at += (size_t)snprintf(out + at, size - at, "%sslot %d you", at ? ", " : "", s); continue; }
        if (kind == MYC_OWNER_NONE) continue;
        const MycSettings* settings = MycLuSettings(l, kind, l->owner_key[s], &mine);
        at += (size_t)snprintf(out + at, size - at, "%sslot %d %s (%s)", at ? ", " : "", s, kind == MYC_OWNER_SQUAD ? "a squadmate" : l->owner_key[s],
            settings == NULL ? "keeps its colors" : (mine ? "your settings" : "shared settings"));
        others = 1;
    }
    if (!others) out[0] = 0;
}

static void MycLuDrop(MycLineup* l, int s, uint32_t frame)
{
    MycCard* card = l->cards[s];
    if (card == NULL) return;
    myc_controller_restore(card->controller, frame);
    if (card->controller->nretired > 0 && l->nretiring < 8)
    {
        l->retiring[l->nretiring++] = (MycRetiring){card->controller, card->controller, NULL};
        l->busy = 1;
    }
    else { myc_controller_free(card->controller); free(card->controller); }
    free(card);
    l->cards[s] = NULL;
}

static int MycLuCapeCounts(const MycSettings* s) { return s->recolor_cape || (s->mode == MYC_CAPE_SOURCE && s->scheme == 0); }

static int MycLuRebind(MycLineup* l, MycCard* card, uint32_t frame)
{
    MycResult* result = card->controller->result;
    int capes = MycLuCapeCounts(&card->settings);
    uint32_t cape = card->settings.source_cape != 0 ? card->settings.source_cape : card->cape;
    if (card->dirty || !card->has_applied || result == NULL || l->records_same == NULL
        || !l->records_same(l->records_ctx, result, card->helmet, card->armor, cape, capes))
        return 0;
    MycApplyTo to;
    memset(&to, 0, sizeof to);
    to.units_at = myc_preview_units_at(l->watch, card->slot);
    to.body = card->body;
    char why[160];
    myc_controller_apply(card->controller, result, &to, frame, why, sizeof why);
    l->rebinds++;
    l->busy = 1;
    return 1;
}

static MycCard* MycLuCard(MycLineup* l, int s)
{
    if (l->cards[s] != NULL) return l->cards[s];
    MycCard* card = calloc(1, sizeof *card);
    MycController* c = calloc(1, sizeof *c);
    if (card == NULL || c == NULL) { free(card); free(c); return NULL; }
    card->slot = s;
    myc_controller_init(c, l->native, l->pool);
    card->controller = c;
    l->cards[s] = card;
    return card;
}

/* Slot s shown with its owner and status: its card made, kept, rebound, given a job or dropped (update). */
static void MycLuUpdate(MycLineup* l, int s, int kind, const char* key, int status, uint32_t frame)
{
    int mine;
    const MycSettings* settings = MycLuSettings(l, kind, key, &mine);
    uint32_t helmet, armor, body, cape;
    myc_preview_slot_kits(l->watch, s, &helmet, &armor, &body, &cape);
    if (settings == NULL || helmet == 0 || armor == 0) { MycLuDrop(l, s, frame); return; }
    MycCard* card = MycLuCard(l, s);
    if (card == NULL) return;
    const char* card_key = kind == MYC_OWNER_SQUAD ? "squad" : key;
    if (card->key_kind != kind || strcmp(card->key, card_key) != 0 || !card->has_settings || !myc_settings_same(&card->settings, settings)
        || helmet != card->helmet || armor != card->armor || body != card->body || cape != card->cape)
    {
        card->key_kind = kind;
        snprintf(card->key, sizeof card->key, "%s", card_key);
        card->settings = *settings;
        card->has_settings = 1;
        card->mine = mine;
        card->helmet = helmet;
        card->armor = armor;
        card->body = body;
        card->cape = cape;
        card->dirty = 1;
        card->failures = 0;
        card->has_applied = 0;
        l->pending = 1;
    }
    else if (status == MYC_STATUS_UNITS && !MycLuRebind(l, card, frame))
    {
        card->dirty = 1;
        l->pending = 1;
    }
}

static void MycLuRemap(MycLineup* l, const MycIdentity* identity)
{
    l->remap = 0;
    MycLuOwners(l, identity);
    char text[512];
    MycLuOwnersText(l, text, sizeof text);
    if (text[0] == 0) return;
    if (!l->has_logged || strcmp(text, l->logged) != 0)
    {
        char line[600];
        snprintf(line, sizeof line, "Squad cards: %s.", text);
        l->note(line);
    }
    snprintf(l->logged, sizeof l->logged, "%s", text);
    l->has_logged = 1;
}

int myc_lineup_observe(MycLineup* l, uint32_t frame, MycPreviewWatch* w, const MycIdentity* identity, int loopback)
{
    l->watch = w;
    if (w->changes > 0 || l->remap) MycLuRemap(l, identity);
    l->stale = 0;
    int mine = -1;
    for (int s = 0; s < SLOTS; s++)
    {
        int status = myc_preview_status(w, s), kind = l->owner_kind[s];
        const char* key = l->owner_key[s];
        if (kind == MYC_OWNER_LOCAL && loopback)
        {
            kind = l->remote->local_key[0] != 0 ? MYC_OWNER_PEER : MYC_OWNER_NONE;
            key = l->remote->local_key;
        }
        if (kind == MYC_OWNER_LOCAL && status != MYC_STATUS_ABSENT && mine < 0) mine = s;
        if (kind == MYC_OWNER_LOCAL || status == MYC_STATUS_ABSENT) MycLuDrop(l, s, frame);
        else MycLuUpdate(l, s, kind, key, status, frame);
    }
    return mine;
}

int myc_lineup_request(MycLineup* l, MycRequest* out)
{
    for (int step = 1; step <= SLOTS; step++)
    {
        int s = (l->served + step) % SLOTS;
        MycCard* card = l->cards[s];
        if (card == NULL || !card->dirty || card->failures >= MYC_LINEUP_FAILURE_LIMIT) continue;
        card->dirty = 0;
        l->served = s;
        myc_remote_request_of(MYC_TARGET_CARD, card->key, &card->settings, card->helmet, card->armor, card->body, card->cape, out);
        out->slot = s;
        return 1;
    }
    l->pending = 0;
    return 0;
}

void myc_lineup_finish(MycLineup* l, int ok, MycResult* result, const MycRequest* request, const char* why, uint32_t frame)
{
    MycCard* card = request->slot >= 0 && request->slot < SLOTS ? l->cards[request->slot] : NULL;
    if (card == NULL || strcmp(card->key, request->key) != 0) return;
    const char* who = strcmp(request->key, "squad") == 0 ? "of a squadmate" : request->key;
    char line[256];
    if (!ok)
    {
        card->failures++;
        card->dirty = card->failures < MYC_LINEUP_FAILURE_LIMIT;
        l->pending |= card->dirty;
        snprintf(line, sizeof line, "Squad card %s (slot %d): recolor failed (%d/%d): %s", who, request->slot, card->failures,
            MYC_LINEUP_FAILURE_LIMIT, why);
        l->note(line);
        return;
    }
    if (card->dirty || result->action == MYC_OBSOLETE) return;
    MycApplyTo to;
    memset(&to, 0, sizeof to);
    to.units_at = myc_preview_units_at(l->watch, card->slot);
    to.body = request->body;
    char text[160];
    int count = myc_controller_apply(card->controller, result, &to, frame, text, sizeof text);
    if (count < 0)
    {
        snprintf(line, sizeof line, "Squad card %s (slot %d): error: %s", who, request->slot, text);
        l->note(line);
        return;
    }
    card->has_applied = 1;
    l->jobs++;
    l->busy = 1;
    snprintf(line, sizeof line, "Squad card %s (slot %d): %d materials recolored (%s).", who, request->slot, count,
        result->action == MYC_APPLY ? (card->mine ? "your settings" : "shared settings") : result->reason);
    l->note(line);
}

void myc_lineup_check(MycLineup* l)
{
    for (int i = 0; i < SLOTS; i++)
    {
        l->cursor = l->cursor % SLOTS + 1;
        MycCard* card = l->cards[l->cursor - 1];
        if (card == NULL || !card->has_applied) continue;
        if (card->controller->probes > 0 && !myc_controller_check(card->controller)) { card->dirty = 1; l->pending = 1; }
        return;
    }
}

void myc_lineup_step(MycLineup* l, uint32_t frame, MycSettleFn settle, void* ctx)
{
    int busy = 0, keep = 0;
    for (int i = 0; i < l->nretiring; i++)
    {
        if (myc_controller_collect(l->retiring[i].a, frame) > 0) { l->retiring[keep++] = l->retiring[i]; continue; }
        myc_controller_free(l->retiring[i].a);
        free(l->retiring[i].block);
    }
    l->nretiring = keep;
    busy = keep > 0;
    for (int s = 0; s < SLOTS; s++)
    {
        MycCard* card = l->cards[s];
        if (card == NULL) continue;
        MycController* c = card->controller;
        if (c->nretired > 0) myc_controller_collect(c, frame);
        if (c->has_pending) settle(ctx, c, frame, "Squad card");
        busy |= c->nretired > 0 || c->has_pending;
    }
    l->busy = busy;
}

void myc_lineup_clear(MycLineup* l, uint32_t frame)
{
    for (int s = 0; s < SLOTS; s++) MycLuDrop(l, s, frame);
    l->pending = 0;
    l->remap = 1;
    l->has_logged = 0;
}

int myc_lineup_any(const MycLineup* l)
{
    for (int s = 0; s < SLOTS; s++)
        if (l->cards[s] != NULL) return 1;
    return 0;
}

void myc_lineup_free(MycLineup* l)
{
    for (int s = 0; s < SLOTS; s++)
        if (l->cards[s] != NULL) { myc_controller_free(l->cards[s]->controller); free(l->cards[s]->controller); free(l->cards[s]); l->cards[s] = NULL; }
    for (int i = 0; i < l->nretiring; i++) { myc_controller_free(l->retiring[i].a); free(l->retiring[i].block); }
    l->nretiring = 0;
}
