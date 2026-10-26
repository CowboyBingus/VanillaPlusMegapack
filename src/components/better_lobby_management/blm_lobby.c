/* Better Lobby Management: host-side squad actions on the ship (lobby.lua): DISBAND SQUAD, and PROMOTE a squad member
 * to host.
 *
 * Players are only ever removed with the game's own kick: the escape menu's player-menu KICK (blm_menu.c game_kick),
 * so the game kicks in its own update (the Lua's other kick modes were test builds; a mod-side kick crashed the host on
 * an in-use package unload). PROMOTE kicks the successor (it returns to its ship and hosts a fresh lobby), finds that
 * lobby through the game's lobby browser by the host id it publishes (string_key2), and moves the squad with the game's
 * own squad-Quickplay party join, so no other player needs the mod.
 *
 * On HellForge: the lobby browser's search goes to HellForge's local backend (lobby.find), which answers from its lobby
 * directory. The directory lists a lobby only while it is Public, its host's "List my Public lobbies" switch is on and
 * Play with strangers is on (docs/multiplayer.md); a successor whose lobby is not listed is not found, and PROMOTE fails
 * after 60 s ("<name>'s lobby was not found") with the squad already back on their ships. DISBAND needs nothing of the
 * backend. */
#include <stdarg.h>
#include <stdio.h>
#include "blm.h"

#define FIRST_SEARCH 0.5         /* seconds after the successor left before the first search */
#define SEARCH_INTERVAL 0.5       /* from one search's results to the next, for FAST_SEARCHES seconds */
#define FAST_SEARCHES 15.0
#define SLOW_SEARCH_INTERVAL 4.0  /* after that */
#define SEARCH_TIMEOUT 60.0       /* give up finding the successor's new lobby */
#define RESULT_TIMEOUT 8.0        /* one search */
#define GONE_TIMEOUT 10.0         /* the successor leaves the session after the kick */
#define DISBAND_TIMEOUT 10.0      /* every kicked player has left the session */
#define JOIN_TIMEOUT 60.0         /* the party join completes */
#define JOIN_GRACE 2.0            /* before a returned-to-hosting state counts as a refusal */
#define GAME_KICK_WAIT 5.0        /* the player menu's KICK: for the menu to take input, then for the player to go */
#define CHAT_LEAD 0.5             /* between the squad message and the first kick (so it shows first) */
#define ARRIVAL_CHECK 15.0        /* after a move: how many of the squad reached the new host's session */
#define INFO 0u                   /* in the scratch block: a lobby browser result, then the search value */
#define INFO_SIZE 256u
#define INFO_CONNECTION 72u
#define SEARCH_VALUE 256u
#define MAX_KICKS 8
#define NAME_SIZE (BLM_NAME_SIZE + 24)

enum { STEP_KICK, STEP_START, STEP_ANNOUNCE, STEP_GONE, STEP_SEARCH, STEP_RESULTS, STEP_JOINING };
static const char* const kSteps[] = {"kick", "start", "announce", "gone", "search", "results", "joining"};

typedef struct Queued { uint64_t id; char name[NAME_SIZE]; } Queued;

typedef struct Job
{
    int kind, step;
    double since, deadline, started, kickAt; /* deadline: since + the step's timeout (gone, results, joining) */
    Queued queue[BLM_MAX_PEERS];  /* disband: the players still to kick */
    int queueAt, queueCount, kicked;
    uintptr_t ctx;
    uint64_t target;              /* promote: the successor */
    char name[NAME_SIZE];
    uint32_t squad;
    double goneAt, foundAt, movedAt, searchUntil, nextSearch;
    int hasGone, hasFound;
    int searches;
} Job;

typedef struct UiKick { uint64_t id; double since, started; int hasStarted; const char* status; } UiKick;
typedef struct Arrival { double due; uint32_t squad; char name[NAME_SIZE]; uint64_t id; } Arrival;

static struct
{
    BlmContextCache cache;
    BlmSession snap;
    int busy;
    Job job;
    UiKick ui[MAX_KICKS];         /* the player menu's KICKs, one at a time */
    int uiCount;
    int arrival;
    Arrival arrivalInfo;
    int messages, menu;
    char status[256];
    char why[96];
    int actions;
} s;

/* The structures handed to the game's natives (16-byte aligned: some load caller buffers with aligned moves). */
static _Alignas(16) uint8_t g_scratch[1024];

static const char* Kind(int kind) { return kind == BLM_DISBAND ? "disband" : "promote"; }

static void SetStatus(const char* format, ...) __attribute__((format(printf, 1, 2)));
static void SetStatus(const char* format, ...)
{
    va_list args;
    va_start(args, format);
    vsnprintf(s.status, sizeof s.status, format, args);
    va_end(args);
}

void blm_lobby_reset_state(void)
{
    memset(&s, 0, sizeof s);
    SetStatus("idle");
}

void blm_lobby_use(int messages, int menu)
{
    s.messages = messages;
    s.menu = menu;
}

const char* blm_lobby_status(void) { return s.status; }
int blm_lobby_actions(void) { return s.actions; }
int blm_lobby_busy(void) { return s.busy; }
int blm_lobby_ui_pending(void) { return s.uiCount > 0; }
int blm_lobby_arrival_pending(void) { return s.arrival; }

int blm_lobby_snapshot(BlmSession* out)
{
    uintptr_t ctx = blm_context(&s.cache);
    if (ctx == 0) return 0;
    blm_read_session(ctx, out);
    return 1;
}

static void NameOf(const BlmNames* names, uint64_t peer, char* out, size_t size)
{
    const char* name = blm_name_of(names, peer);
    if (name != NULL) snprintf(out, size, "%s", name);
    else snprintf(out, size, "player %llX", (unsigned long long)peer);
}

/* Remote session peers (not the local player). */
static int RemotePeers(const BlmSession* snap, BlmPeer* out)
{
    int count = 0;
    for (uint32_t i = 0; i < snap->peer_count; i++)
        if (snap->peers[i].id != snap->local && snap->peers[i].id != 0) out[count++] = snap->peers[i];
    return count;
}

/* The automatic choice: a friend of the host first (every peer is asked), then the lowest peer id. */
static BlmPeer Automatic(const BlmPeer* peers, int count, int* friend)
{
    int best = -1, bestFriend = -1;
    for (int i = 0; i < count; i++)
    {
        if (best < 0 || peers[i].id < peers[best].id) best = i;
        if (blm_native.is_friend(0, peers[i].id) != 0 && (bestFriend < 0 || peers[i].id < peers[bestFriend].id)) bestFriend = i;
    }
    *friend = bestFriend >= 0;
    return peers[bestFriend >= 0 ? bestFriend : best];
}

/* target: the squad member the host picked in the menu, or NULL for the automatic choice (a friend of the host first,
 * then the lowest peer id, the rule the game's lobby uses when an owner disappears). */
int blm_choose_successor(const BlmSession* snap, const uint64_t* target, BlmPeer* out, int* friend, const char** why)
{
    BlmPeer peers[BLM_MAX_PEERS];
    int count = RemotePeers(snap, peers);
    *friend = 0;
    if (count == 0) { *why = "no other players"; return 0; }
    if (target != NULL)
    {
        for (int i = 0; i < count; i++)
            if (peers[i].id == *target) { *out = peers[i]; return 1; }
        *why = "that player is no longer in the squad";
        return 0;
    }
    *out = Automatic(peers, count, friend);
    return 1;
}

static int Refuse(const char* action, const char* why, const char** out)
{
    vpm_log(blm_component, "%s refused: %s", action, why);
    SetStatus("%s refused: %s", action, why);
    *out = why;
    return 0;
}

/* Shared checks: hosting a squad, nothing else in progress. 1 with s.snap, or 0 after Refuse. */
static int Ready(const char* action, const char** why)
{
    const BlmSession* snap = &s.snap;
    if (s.busy)
    {
        snprintf(s.why, sizeof s.why, "another action is running (%s)", Kind(s.job.kind));
        return Refuse(action, s.why, why);
    }
    if (!blm_lobby_snapshot(&s.snap)) return Refuse(action, "no network session", why);
    if (!snap->is_host || snap->hosting != 1) return Refuse(action, "not hosting", why);
    if (snap->peer_count < 2) return Refuse(action, "no other players", why);
    if (snap->transition != 0) return Refuse(action, "a transition is running", why);
    if (snap->join_state != 0 || snap->party_join != 0) return Refuse(action, "a join is running", why);
    if (snap->mode != BLM_MODE_SHIP) return Refuse(action, "only on the ship", why);
    if (!s.menu) return Refuse(action, "the escape menu integration is unavailable", why);
    return 1;
}

/* A squad message before the kicks: when the first kick may start (CHAT_LEAD later once a line went out). */
static double Announce(const char* text, double now)
{
    uint32_t sent;
    const char* why = "";
    if (!s.messages) return now;
    if (blm_chat_send(text, &sent, &why))
    {
        vpm_log(blm_component, "squad message sent to %u player(s): %s", sent, text);
        return now + CHAT_LEAD;
    }
    vpm_log(blm_component, "squad message not sent: %s", why);
    return now;
}

/* PROMOTE's message: the game's own new squad leader notice. */
static double TellNewHost(double now)
{
    uint32_t sent;
    const char* why = "";
    if (!s.messages) return now;
    if (blm_chat_new_leader(s.job.target, &sent, &why))
    {
        vpm_log(blm_component, "squad leader notice sent to %u player(s): %s", sent, s.job.name);
        return now + CHAT_LEAD;
    }
    vpm_log(blm_component, "squad leader notice not sent: %s", why);
    return now;
}

/* The player menu's own KICK, queued (ui_step drives it). */
static void Kick(uint64_t peer, double now)
{
    if (s.uiCount < MAX_KICKS) s.ui[s.uiCount++] = (UiKick){peer, now, 0, 0, NULL};
}

static void Goto(int step, double now, double timeout)
{
    s.job.step = step;
    s.job.since = now;
    s.job.deadline = now + timeout;
}

static int Fail(const char* format, ...) __attribute__((format(printf, 1, 2)));
static int Fail(const char* format, ...)
{
    char why[256];
    va_list args;
    va_start(args, format);
    vsnprintf(why, sizeof why, format, args);
    va_end(args);
    vpm_log(blm_component, "%s failed at %s: %s", Kind(s.job.kind), kSteps[s.job.step], why);
    SetStatus("%s failed: %s", Kind(s.job.kind), why);
    s.busy = 0;
    return 0;
}

static int Finish(const char* text)
{
    vpm_log(blm_component, "%s: %s", Kind(s.job.kind), text);
    SetStatus("%s", text);
    s.actions++;
    s.busy = 0;
    return 1;
}

/* Kicks every other player with the game's own kick, one per frame (the first in this frame); the job ends when they
 * have all left the session. */
int blm_lobby_disband(double now, const char** why)
{
    if (!Ready("disband", why)) return 0;
    BlmNames names;
    BlmPeer peers[BLM_MAX_PEERS];
    blm_names(&names);
    int count = RemotePeers(&s.snap, peers);
    memset(&s.job, 0, sizeof s.job);
    s.job.kind = BLM_DISBAND;
    s.job.step = STEP_KICK;
    s.job.ctx = s.snap.ctx;
    s.job.since = s.job.started = now;
    for (int i = 0; i < count; i++)
    {
        s.job.queue[i].id = peers[i].id;
        NameOf(&names, peers[i].id, s.job.queue[i].name, NAME_SIZE);
    }
    s.job.queueCount = count;
    s.busy = 1;
    vpm_log(blm_component, "disband: kicking %d player(s)", count);
    SetStatus("disband: kicking %d player(s)", count);
    s.job.kickAt = Announce(blm_tr("chat.disband", "The host disbanded the squad."), now);
    return blm_lobby_step(now);
}

/* Promotes a squad member: tells the squad, kicks the successor home, finds their new lobby and moves the squad
 * there. Ship only. */
int blm_lobby_promote(const uint64_t* target, double now, const char** why)
{
    if (!Ready("promote", why)) return 0;
    BlmPeer chosen;
    int friend;
    const char* reason = "";
    if (!blm_choose_successor(&s.snap, target, &chosen, &friend, &reason)) return Refuse("promote", reason, why);
    BlmNames names;
    blm_names(&names);
    memset(&s.job, 0, sizeof s.job);
    s.job.kind = BLM_PROMOTE;
    s.job.target = chosen.id;
    NameOf(&names, chosen.id, s.job.name, NAME_SIZE);
    s.job.started = s.job.since = now;
    s.job.ctx = s.snap.ctx;
    s.job.step = STEP_START;
    s.job.squad = s.snap.peer_count;
    s.busy = 1;
    vpm_log(blm_component, "promote: successor %s (%llX, player %u%s)", s.job.name, (unsigned long long)chosen.id,
        chosen.index + 1, friend ? ", friend" : "");
    s.job.kickAt = TellNewHost(now);
    if (s.job.kickAt > now)
    {
        Goto(STEP_ANNOUNCE, now, 0);
        SetStatus("promote: telling the squad");
        return 1;
    }
    Kick(chosen.id, now);
    Goto(STEP_GONE, now, GONE_TIMEOUT);
    SetStatus("promote: %s returns to their ship", s.job.name);
    return 1;
}

static int DisbandStep(const BlmSession* snap, double now)
{
    if (now < s.job.kickAt) return 1; /* the squad message goes first */
    while (s.job.queueAt < s.job.queueCount)
    {
        const Queued* peer = &s.job.queue[s.job.queueAt++];
        if (!blm_has_peer(snap, peer->id)) continue;
        Kick(peer->id, now);
        s.job.kicked++;
        vpm_log(blm_component, "disband: kicked %s", peer->name);
        return 1;
    }
    char text[96];
    if (snap->peer_count <= 1)
    {
        snprintf(text, sizeof text, "disbanded (%d players)", s.job.kicked);
        return Finish(text);
    }
    if (now - s.job.started >= DISBAND_TIMEOUT)
    {
        snprintf(text, sizeof text, "disbanded (%d players; %u still leaving)", s.job.kicked, snap->peer_count - 1);
        return Finish(text);
    }
    return 1;
}

/* PROMOTE closes the escape menu once it no longer needs it. */
static void CloseMenu(void)
{
    const char* why = "";
    if (!s.menu) return;
    if (blm_menu_close(&why)) vpm_log(blm_component, "%s: escape menu closed", Kind(s.job.kind));
    else vpm_log(blm_component, "%s: escape menu not closed: %s", Kind(s.job.kind), why);
}

static int StartSearch(const BlmSession* snap, double now)
{
    uintptr_t field = snap->ctx + BLM_BROWSER;
    uint64_t handle = blm_load64(field);
    if (handle == 0) return Fail("no lobby browser");
    if (blm_game_searching() || blm_native.browser_busy(field) != 0)
    {
        s.job.nextSearch = now + 0.5;
        return 1;
    }
    blm_native.clear_filters(handle);
    char* value = (char*)(g_scratch + SEARCH_VALUE);
    snprintf(value, 32, "%llu", (unsigned long long)s.job.target);
    blm_native.filter_string(field, BLM_KEY_HOST_PEER, (uint64_t)(uintptr_t)value, BLM_OP_EQUAL);
    (void)blm_native.browser_start(field);
    s.job.searches++;
    Goto(STEP_RESULTS, now, RESULT_TIMEOUT);
    return 1;
}

static int Join(const BlmSession* snap, double now)
{
    s.job.foundAt = now;
    s.job.hasFound = 1;
    vpm_log(blm_component, "%s: found %s's lobby after %d search(es), %.1f s after they left", Kind(s.job.kind), s.job.name,
        s.job.searches, now - s.job.goneAt);
    uint8_t started = blm_native.start_join(snap->ctx + BLM_JOIN, (uint64_t)(uintptr_t)(g_scratch + INFO), BLM_JOIN_PARTY, 0,
        BLM_JOIN_REASON_QUICKPLAY);
    if (started == 0) return Fail("the game refused to start the party join");
    Goto(STEP_JOINING, now, JOIN_TIMEOUT);
    SetStatus("%s: moving the squad to %s", Kind(s.job.kind), s.job.name);
    return 1;
}

static int ReadResults(const BlmSession* snap, double now)
{
    uintptr_t field = snap->ctx + BLM_BROWSER;
    if (blm_native.browser_busy(field) != 0)
    {
        if (now >= s.job.deadline)
        {
            Goto(STEP_SEARCH, now, 0);
            s.job.nextSearch = now;
        }
        return 1;
    }
    int32_t count = blm_native.browser_count(field);
    int joinable = 0;
    if (count > 0)
    {
        memset(g_scratch + INFO, 0, INFO_SIZE);
        (void)blm_native.browser_result(field, (uint64_t)(uintptr_t)(g_scratch + INFO), 0);
        joinable = g_scratch[INFO + INFO_CONNECTION] != 0;
    }
    if (count > 0 && joinable) return Join(snap, now);
    Goto(STEP_SEARCH, now, 0);
    s.job.nextSearch = now + (now - s.job.goneAt < FAST_SEARCHES ? SEARCH_INTERVAL : SLOW_SEARCH_INTERVAL);
    return 1;
}

static int Gone(const BlmSession* snap, double now)
{
    if (blm_has_peer(snap, s.job.target))
    {
        if (now >= s.job.deadline) return Fail("%s is still in the session", s.job.name);
        return 1;
    }
    Goto(STEP_SEARCH, now, 0);
    s.job.goneAt = now;
    s.job.hasGone = 1;
    CloseMenu();
    s.job.searchUntil = now + SEARCH_TIMEOUT;
    s.job.nextSearch = now + FIRST_SEARCH;
    SetStatus("%s: waiting for %s's lobby", Kind(s.job.kind), s.job.name);
    return 1;
}

static int Joining(const BlmSession* snap, double now)
{
    if (snap->host == s.job.target)
    {
        char text[256];
        s.job.movedAt = now;
        s.arrival = 1;
        s.arrivalInfo = (Arrival){now + ARRIVAL_CHECK, s.job.squad, "", s.job.target};
        snprintf(s.arrivalInfo.name, NAME_SIZE, "%s", s.job.name);
        if (s.job.hasGone && s.job.hasFound)
            snprintf(text, sizeof text, "squad moved to %s's ship (kicked in %.1f s, lobby found %.1f s later, joined in %.1f s)",
                s.job.name, s.job.goneAt - s.job.started, s.job.foundAt - s.job.goneAt, s.job.movedAt - s.job.foundAt);
        else snprintf(text, sizeof text, "squad moved to %s's ship", s.job.name);
        return Finish(text);
    }
    if (snap->is_host && snap->join_state == 0 && now - s.job.since >= JOIN_GRACE)
        return Fail("%s's game refused the squad (privacy or room)", s.job.name);
    if (now >= s.job.deadline) return Fail("the party join did not complete");
    return 1;
}

static int Announced(const BlmSession* snap, double now)
{
    if (now < s.job.kickAt) return 1;
    if (!blm_has_peer(snap, s.job.target)) return Fail("%s left the squad meanwhile", s.job.name);
    Kick(s.job.target, now);
    Goto(STEP_GONE, now, GONE_TIMEOUT);
    SetStatus("%s: %s returns to their ship", Kind(s.job.kind), s.job.name);
    return 1;
}

/* lint: per-frame (while an action runs). One step per frame. now: seconds (the component's clock). */
int blm_lobby_step(double now)
{
    if (!s.busy) return 0;
    if (!blm_lobby_snapshot(&s.snap)) return Fail("network session lost");
    const BlmSession* snap = &s.snap;
    if (s.job.kind == BLM_DISBAND) return DisbandStep(snap, now);
    switch (s.job.step)
    {
    case STEP_ANNOUNCE: return Announced(snap, now);
    case STEP_GONE: return Gone(snap, now);
    case STEP_SEARCH:
        if (now >= s.job.searchUntil) return Fail("%s's lobby was not found", s.job.name);
        return now >= s.job.nextSearch ? StartSearch(snap, now) : 1;
    case STEP_RESULTS: return ReadResults(snap, now);
    case STEP_JOINING: return Joining(snap, now);
    default: return 1;
    }
}

/* The kick under way: done with it once its player left or its wait ran out. */
static void UiStarted(UiKick* target, double now)
{
    BlmSession snap;
    if (!blm_lobby_snapshot(&snap) || !blm_has_peer(&snap, target->id))
        vpm_log(blm_component, "game kick: %llX left the session %.2f s after its KICK", (unsigned long long)target->id,
            now - target->started);
    else if (now - target->started >= GAME_KICK_WAIT)
        vpm_log(blm_component, "game kick: %llX is still in the session; the player menu's KICK did not run",
            (unsigned long long)target->id);
    else return;
    s.uiCount--;
    memmove(&s.ui[0], &s.ui[1], (size_t)s.uiCount * sizeof s.ui[0]);
}

/* lint: per-frame (while kicks are queued). One at a time: the player menu's KICK is set up (the game kicks later in
 * this frame); the next kick waits until that player has left. */
void blm_lobby_ui_step(double now)
{
    if (s.uiCount == 0) return;
    UiKick* target = &s.ui[0];
    if (target->hasStarted) { UiStarted(target, now); return; }
    int card = -1;
    const char* status = s.menu ? blm_menu_game_kick(blm_menu_screen(), target->id, &card) : "no escape menu";
    if (strcmp(status, "started") == 0)
    {
        target->started = now;
        target->hasStarted = 1;
        vpm_log(blm_component, "game kick: KICK set on %llX's player menu (card %d)", (unsigned long long)target->id, card);
    }
    else if (now - target->since >= GAME_KICK_WAIT)
    {
        vpm_log(blm_component, "game kick: gave up on %llX (%s)", (unsigned long long)target->id, status);
        s.uiCount--;
        memmove(&s.ui[0], &s.ui[1], (size_t)s.uiCount * sizeof s.ui[0]);
    }
    else if (target->status == NULL || strcmp(status, target->status) != 0)
    {
        target->status = status;
        vpm_log(blm_component, "game kick: waiting for the escape menu (%s)", status);
    }
}

/* lint: per-frame (once a move is done: nothing is read before it is due). */
void blm_lobby_check_arrival(double now)
{
    if (!s.arrival || now < s.arrivalInfo.due) return;
    s.arrival = 0;
    BlmSession snap;
    if (!blm_lobby_snapshot(&snap) || snap.host != s.arrivalInfo.id)
    {
        vpm_log(blm_component, "promote: no longer in %s's session %d s after the move", s.arrivalInfo.name, (int)ARRIVAL_CHECK);
        return;
    }
    vpm_log(blm_component, "promote: %u of %u players in %s's session %d s after the move", snap.peer_count, s.arrivalInfo.squad,
        s.arrivalInfo.name, (int)ARRIVAL_CHECK);
}

int blm_lobby_cancel(const char* reason)
{
    if (!s.busy) return 0;
    (void)Fail("cancelled: %s", reason);
    return 1;
}

/* A fresh start (the component stopping): the running action is cancelled, queued kicks and the arrival check are
 * dropped. */
int blm_lobby_reset(const char* reason)
{
    int cancelled = blm_lobby_cancel(reason);
    s.uiCount = 0;
    s.arrival = 0;
    return cancelled;
}
