/* Better Lobby Management: CANCEL SOS (sos.lua). Stops the SOS Beacon the host called in, keeps it stopped, and gives
 * the SOS Beacon its use back so it can be called in again.
 *
 * The game's SOS system lists a mission for SOS joins. While its active byte is set, the host's lobby carries the SOS
 * flag (lobby key 8) and is forced Public (key 19), whatever the host's privacy setting. The game switches it off only
 * when the squad is full or the beacon is gone (0x67AA20), and on again whenever a player leaves or a new host takes
 * over while a beacon stands (0xB5F140, 0x1087010). Its SOS off puts the privacy setting back only when PlayFab already
 * shows the SOS flag off; so this calls that same function, then sets key 19 to the privacy setting with the game's key
 * setter (0x10925D0), and lets the game post both in this frame's update (the post countdown at 0). It does the same
 * after each re-arm, until the mission ends or the host calls in a new beacon. The cancelled beacon spent the SOS
 * Beacon's one use per mission; the use goes back into the host's own stratagem slot.
 *
 * On HellForge: the SOS Beacon's settings row is found through the stratagem list the game reads now. HellForge moves
 * the list (0x37CB600) when mods add stratagems and rewrites the instruction the "stratagem uses" check covers
 * (0x66D3D7, lea r10, [rip + list]): that check leaves its displacement out, and the list is taken from it. */
#include <stdio.h>
#include "blm.h"

#define SOS_PTR 0x3326BF0u       /* the SOS system */
#define ACTIVE 8u                /* byte: the SOS is on */
#define ENABLED 24u              /* u32: enabled SOS beacon components (the re-arms need one) */
#define PRIVACY 0xAC550u         /* game state -> the host's privacy setting */
#define KEYS 56u                 /* the lobby wrapper: its keys as text, 257 bytes each */
#define KEY_SIZE 257u
#define KEY_SOS 8u
#define KEY_PRIVACY 19u
#define PENDING 0x20u            /* the keys the next post sends */
#define COUNTDOWN 0x1B80u        /* float seconds to the next post (the game posts at <= 0, then waits 30 s) */
#define PLAYERS_PTR 0x347CE50u   /* per-player stratagem records: 32 of them, then their count */
#define PLAYER_SIZE 0x1690u
#define PLAYER_COUNT 0x2D200u
#define MAX_PLAYERS 32u
#define SLOTS 0x1C0u             /* up to 16 stratagem slots {type +0, uses left +4} */
#define SLOT_SIZE 0x30u
#define SLOT_COUNT 0x7C0u
#define MAX_SLOTS 16u
#define SLOT_USES 4u
#define STRATAGEMS 0x37CB600u    /* the vanilla stratagem list: StratagemType -> settings row */
#define STRATAGEM_USES 0x50u     /* uses per mission (0xFFFFFFFF: no limit) */
#define STRATAGEM_SHARED 0x94u   /* shared by the squad */
#define SOS_STRATAGEM 0x91u
#define NO_LIMIT 0xFFFFFFFFu
#define LIST_SITE 0x66D3D7u      /* lea r10, [rip + list] in the uses reader 0x66D3D0 */
#define LIST_DISPLACEMENT 3u
#define LIST_SITE_SIZE 7u

typedef void (*BlmSosCall)(uint64_t sos);
typedef void (*BlmLobbySetInt)(uint64_t lobby, uint32_t key, int32_t value);

typedef struct Kept { uintptr_t ctx, sos; uint32_t enabled; double since; } Kept;

static struct
{
    BlmSosCall deactivate;
    BlmLobbySetInt set_key;
    BlmContextCache cache;
    uintptr_t confirmed;         /* the SOS object a guarded read confirmed */
    uintptr_t countdownChecked;  /* the post countdown a page check passed */
    int kept;                    /* a cancel is kept: */
    Kept keep;
    int cancels, rearms, leaks;
    int movedLogged;
} s;

static const char* const kPrivacyNames[4] = {"Public", "Friends Only", "Invite Only", "Friends and Clan"};

void blm_sos_reset(void) { memset(&s, 0, sizeof s); }

int blm_sos_verify(const char** why)
{
    if (!vpm_game_code_matches(blm_sos_deactivate.rva, blm_sos_deactivate.pattern)) { *why = "SOS deactivate changed"; return 0; }
    if (!vpm_game_code_matches(blm_sos_set_key.rva, blm_sos_set_key.pattern)) { *why = "lobby number setter changed"; return 0; }
    if (!blm_game_code_ok(blm_sos_code, blm_sos_code_count, why)) return 0;
    s.deactivate = (BlmSosCall)(vpm_game() + blm_sos_deactivate.rva);
    s.set_key = (BlmLobbySetInt)(vpm_game() + blm_sos_set_key.rva);
    return 1;
}

/* The SOS system, or 0: a new object is confirmed once with a guarded read, later frames use direct loads. */
static uintptr_t Object(void)
{
    uintptr_t sos = (uintptr_t)blm_global(SOS_PTR);
    if (sos == 0) return 0;
    if (sos != s.confirmed)
    {
        uint32_t enabled;
        if (sos % 8 != 0 || !vpm_read_u32(sos + ENABLED, &enabled)) return 0;
        s.confirmed = sos;
    }
    return sos;
}

int blm_sos_active(void)
{
    uintptr_t sos = Object();
    return sos != 0 && blm_load8(sos + ACTIVE) != 0;
}

/* The host's privacy setting, or 0 when there is no game state. */
static int Privacy(uint32_t* out)
{
    uintptr_t state = (uintptr_t)blm_global(BLM_GAME_STATE_PTR);
    if (state == 0) return 0;
    *out = blm_load32(state + PRIVACY);
    return 1;
}

int blm_sos_offer(const BlmSession* snap, uint32_t* privacy)
{
    if (snap->mode != BLM_MODE_MISSION || !snap->is_host || snap->hosting != 1 || snap->transition != 0) return 0;
    if (!blm_sos_active()) return 0;
    return Privacy(privacy);
}

void blm_sos_body(uint32_t privacy, char* out, size_t size)
{
    static const char* const keys[4] = {NULL, "privacy.friends", "privacy.invite", "privacy.clan"};
    if (privacy == 0)
    {
        snprintf(out, size, "%s", blm_tr("dialog.cancel_sos.public", "Stops your SOS, also when a slot opens. Quickplay "
            "still finds your Public lobby. You can call in the SOS Beacon again."));
        return;
    }
    const char* name = privacy < 4 ? blm_tr(keys[privacy], kPrivacyNames[privacy]) : blm_tr("privacy.other", "its privacy setting");
    blm_format(out, size, blm_tr("dialog.cancel_sos.private", "Stops your SOS, also when a slot opens. Your lobby returns "
        "to {privacy}. You can call in the SOS Beacon again."), "{privacy}", name);
}

/* "SOS flag 1, privacy 0": the lobby keys from the game's cache (direct loads). */
static void Keys(uintptr_t ctx, char* out, size_t size)
{
    char sosKey[17], privacyKey[17];
    uintptr_t keys = ctx + BLM_LOBBY + KEYS;
    for (int k = 0; k < 2; k++)
    {
        char* text = k == 0 ? sosKey : privacyKey;
        uintptr_t at = keys + (k == 0 ? KEY_SOS : KEY_PRIVACY) * KEY_SIZE;
        size_t n = 0;
        while (n < 16 && blm_load8(at + n) != 0) { text[n] = (char)blm_load8(at + n); n++; }
        text[n] = 0;
    }
    snprintf(out, size, "SOS flag %s, privacy %s", sosKey, privacyKey);
}

/* The game's SOS off, then the privacy setting on key 19. 1 with *setting when there was a setting to put back. */
static int SwitchOff(uintptr_t ctx, uintptr_t sos, uint32_t* setting)
{
    s.deactivate(sos);
    if (!Privacy(setting)) return 0;
    s.set_key(ctx + BLM_LOBBY, KEY_PRIVACY, (int32_t)*setting);
    return 1;
}

/* The game posts the lobby in this frame's update instead of up to 30 s later: one store, its page checked once. */
static int Publish(uintptr_t ctx)
{
    uintptr_t at = ctx + BLM_LOBBY + COUNTDOWN;
    if (s.countdownChecked != at)
    {
        if (!blm_writable(at, 4)) return 0;
        s.countdownChecked = at;
    }
    const float zero = 0.0f;
    memcpy((void*)at, &zero, 4);
    return 1;
}

/* The stratagem list the game reads now: from the uses reader's displacement (HellForge rewrites it when it moves the
 * list). */
static uintptr_t StratagemList(void)
{
    int32_t displacement;
    if (!vpm_game_read(LIST_SITE + LIST_DISPLACEMENT, &displacement, 4)) return 0;
    uintptr_t list = vpm_game() + LIST_SITE + LIST_SITE_SIZE + (uintptr_t)(intptr_t)displacement;
    if (list != vpm_game() + STRATAGEMS && !s.movedLogged)
    {
        s.movedLogged = 1;
        vpm_log(blm_component, "the stratagem list was moved by HellForge (game.dll %+lld): the SOS Beacon's settings are read there",
            (long long)(list - vpm_game()));
    }
    return list;
}

/* The SOS Beacon's settings row through the list, or 0. */
static uintptr_t SosSettings(void)
{
    uintptr_t list = StratagemList(), slot;
    if (list == 0) return 0;
    slot = list + 8u * SOS_STRATAGEM;
    if (slot >= vpm_game() && slot + 8 <= vpm_game() + vpm_game_size()) return (uintptr_t)blm_load64(slot);
    return vpm_ptr(slot);
}

/* The host's own SOS Beacon slot in the player records: its address, or 0 with *why. */
static uintptr_t OwnSlot(uint64_t local, const char** why)
{
    uintptr_t players = (uintptr_t)blm_global(PLAYERS_PTR);
    uint32_t first, count;
    if (players == 0 || !vpm_read_u32(players, &first) || !vpm_read_u32(players + PLAYER_COUNT, &count))
    {
        *why = "player records unreadable";
        return 0;
    }
    for (uint32_t r = 0; r < count && r < MAX_PLAYERS; r++)
    {
        uintptr_t record = players + r * PLAYER_SIZE;
        if (blm_load64(record) != local) continue;
        uint32_t slots = blm_load32(record + SLOT_COUNT);
        for (uint32_t i = 0; i < slots && i < MAX_SLOTS; i++)
            if (blm_load32(record + SLOTS + i * SLOT_SIZE) == SOS_STRATAGEM) return record + SLOTS + i * SLOT_SIZE;
        *why = "no SOS Beacon slot";
        return 0;
    }
    *why = "no player record of yours";
    return 0;
}

/* Gives the host's SOS Beacon back the use its beacon spent, up to the stratagem's uses per mission (one checked
 * store). The text for the log. */
static void RestoreUse(uint64_t local, char* out, size_t size)
{
    uintptr_t settings = SosSettings();
    uint32_t type = 0, limit = 0, shared = 1;
    if (settings == 0 || !vpm_read_u32(settings, &type) || type != SOS_STRATAGEM) { snprintf(out, size, "SOS Beacon settings unreadable"); return; }
    int limitRead = vpm_read_u32(settings + STRATAGEM_USES, &limit), sharedRead = vpm_read_u32(settings + STRATAGEM_SHARED, &shared);
    if (!limitRead || limit == NO_LIMIT) { snprintf(out, size, "the SOS Beacon has no use limit"); return; }
    if (!sharedRead || shared != 0)
    {
        snprintf(out, size, "the SOS Beacon's uses are shared; not restored");
        return;
    }
    const char* why = "";
    uintptr_t slot = OwnSlot(local, &why);
    if (slot == 0) { snprintf(out, size, "%s", why); return; }
    uint32_t uses = blm_load32(slot + SLOT_USES), more = uses + 1;
    if (uses >= limit) { snprintf(out, size, "SOS Beacon uses already %u", uses); return; }
    if (!blm_writable(slot + SLOT_USES, 4)) { snprintf(out, size, "SOS Beacon use: the write was refused"); return; }
    memcpy((void*)(slot + SLOT_USES), &more, 4);
    snprintf(out, size, "SOS Beacon uses %u -> %u", uses, more);
}

static int Refuse(const char* why, const char** out)
{
    vpm_log(blm_component, "cancel SOS refused: %s", why);
    *out = why;
    return 0;
}

/* The cancel's gates: the session snapshot and the SOS object, or 0 after Refuse. */
static uintptr_t Gates(BlmSession* snap, const char** why)
{
    uintptr_t ctx = blm_context(&s.cache);
    if (ctx == 0) return Refuse("no network session", why);
    blm_read_session(ctx, snap);
    if (!snap->is_host || snap->hosting != 1) return Refuse("not hosting", why);
    if (snap->mode != BLM_MODE_MISSION) return Refuse("not in a mission", why);
    if (snap->transition != 0) return Refuse("a transition is running", why);
    uintptr_t sos = Object();
    if (sos == 0 || blm_load8(sos + ACTIVE) == 0) return Refuse("no SOS is on", why);
    return sos;
}

int blm_sos_cancel(double now, const char** why)
{
    if (s.deactivate == NULL) return Refuse("not verified", why);
    BlmSession snap;
    uintptr_t sos = Gates(&snap, why);
    if (sos == 0) return 0;
    char before[64], after[64], setting[16], restored[96];
    uint32_t privacy = 0;
    Keys(snap.ctx, before, sizeof before);
    int has = SwitchOff(snap.ctx, sos, &privacy);
    int published = Publish(snap.ctx);
    s.kept = 1;
    s.keep = (Kept){snap.ctx, sos, blm_load32(sos + ENABLED), now};
    s.cancels++;
    Keys(snap.ctx, after, sizeof after);
    if (!has) snprintf(setting, sizeof setting, "nil");
    else if (privacy < 4) snprintf(setting, sizeof setting, "%s", kPrivacyNames[privacy]);
    else snprintf(setting, sizeof setting, "%u", privacy);
    RestoreUse(snap.local, restored, sizeof restored);
    vpm_log(blm_component, "SOS cancelled: lobby %s -> %s (privacy setting %s); %s; %s", before, after, setting,
        published ? "posted in this frame" : "the write was refused; posted at the next lobby update", restored);
    return 1;
}

int blm_sos_cancelled(void) { return s.kept; }

static void Finish(const char* why, double now)
{
    vpm_log(blm_component, "SOS: no longer kept off after %.0f s (%s)", now - s.keep.since, why);
    s.kept = 0;
}

/* What ends a kept cancel (NULL: nothing); kept.enabled follows a beacon gone. */
static const char* Ended(uintptr_t ctx)
{
    if (ctx != s.keep.ctx || (uintptr_t)blm_global(SOS_PTR) != s.keep.sos) return "new session or mission";
    uintptr_t state = (uintptr_t)blm_global(BLM_GAME_STATE_PTR);
    if (state == 0 || blm_load32(state + BLM_MODE) != BLM_MODE_MISSION) return "the mission ended";
    uint32_t enabled = blm_load32(s.keep.sos + ENABLED);
    if (enabled == 0) return "no SOS beacon left";
    if (enabled > s.keep.enabled) return "a new SOS beacon was called in";
    s.keep.enabled = enabled;
    return NULL;
}

/* lint: per-frame (while a cancel is kept: 6 direct loads while nothing changes). The game re-arms in its own update,
 * after this one, so a re-arm is caught in the next frame; unless a post went out in between (key 8 no longer pending),
 * the pending post already carries the cancel again. */
void blm_sos_keep(double now)
{
    if (!s.kept) return;
    uintptr_t ctx = blm_context(&s.cache);
    const char* ended = Ended(ctx);
    if (ended != NULL) { Finish(ended, now); return; }
    if (blm_load8(s.keep.sos + ACTIVE) == 0) return;
    if (blm_load64(ctx + BLM_HOST) != blm_load64(ctx + BLM_LOCAL)) { Finish("no longer the host", now); return; }
    int posted = ((blm_load32(ctx + BLM_LOBBY + PENDING) >> KEY_SOS) & 1u) == 0;
    uint32_t setting;
    (void)SwitchOff(ctx, s.keep.sos, &setting);
    s.rearms++;
    if (!posted)
    {
        vpm_log(blm_component, "SOS: the game listed it again (a player left or a new host); cancelled again");
        return;
    }
    s.leaks++;
    vpm_log(blm_component, "SOS: the game listed it again (a player left or a new host); cancelled again; the lobby had "
        "already posted it, %s", Publish(ctx) ? "posted again in this frame" : "the write was refused; posted at the next lobby update");
}

void blm_sos_counts(int* cancels, int* rearms, int* leaks)
{
    *cancels = s.cancels;
    *rearms = s.rearms;
    *leaks = s.leaks;
}
