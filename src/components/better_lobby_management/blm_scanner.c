/* Better Lobby Management: the Galactic Map lobby scanner's recharge (scanner.lua, formerly Fast Lobby Scanner).
 *
 * The scanner copies the online config's recharge seconds into its countdown each time a scan's results arrive
 * (game.dll 0x1337FA8). This keeps that one config field at the player's setting, never above the game's own value,
 * and writes again whenever the game rewrites it (its online config arrives at login and then about every 15 minutes).
 *
 * On HellForge: the live 20 s came from the backend's config response; HellForge's local backend leaves the live game's
 * matchmaking and polling settings out (game-client-config.json), so the field probably keeps its compiled default,
 * 10 s (game.dll 0x12B43E0 from 0x21D01C0; KB galactic-map-scanner-recharge-research): the default 5 s still shortens
 * the wait, and settings above 10 keep 10 (never longer than the game's value). Unverified in game. Each scan is a
 * lobby.find on the backend's lobby directory. */
#include <math.h>
#include <stdio.h>
#include "blm.h"

#define CONFIG_PTR 0x347CEE0u      /* online config object */
#define RECHARGE 0x3CE4Cu          /* int32 seconds; read only by the scanner */
#define MATCHMAKING_PTR 0x347CE80u
#define COUNTDOWN 0x10BD74u        /* float seconds left ("SCANNER RECHARGING... N") */
#define GAME_VALUE_MIN 1u          /* game values outside this range are not seconds */
#define GAME_VALUE_LIMIT 3600u
#define REWRITE_LIMIT 500          /* far more rewrites than one every 15 minutes: something else keeps writing it */

static struct
{
    const char* status;
    uint32_t revision;             /* moves for a new status, a new game value or a new setting */
    int writes, refreshes, shortened;
    int setting;
    int hasGameValue, hasApplied, hasSettled;
    uint32_t gameValue, applied, settled;
    uintptr_t config, field, owner;
    int dirty, stopped;
    uintptr_t fieldChecked, countdownChecked; /* the page checks passed, once per object */
} s;

static void SetStatus(const char* status)
{
    if (s.status == NULL || strcmp(s.status, status) != 0) { s.status = status; s.revision++; }
}

void blm_scanner_reset(void)
{
    memset(&s, 0, sizeof s);
    s.status = "waiting_for_config";
    s.setting = BLM_SCANNER_DEFAULT;
}

int blm_scanner_verify(const char** why) { return blm_game_code_ok(blm_scanner_code, blm_scanner_code_count, why); }
uint32_t blm_scanner_revision(void) { return s.revision; }
const char* blm_scanner_state(void) { return s.status; }

static int Plausible(uintptr_t value) { return value >= 0x10000 && value < 0x800000000000ull && value % 8 == 0; }

/* A store with its page checked once per target. */
static int Store(uintptr_t at, uintptr_t* checked, const void* value)
{
    if (*checked != at)
    {
        if (!blm_writable(at, 4)) return 0;
        *checked = at;
    }
    memcpy((void*)at, value, 4);
    return 1;
}

/* Shortens the running countdown to seconds when it is longer; a failure only leaves one recharge at the old length. */
static void Shorten(uint32_t seconds)
{
    uintptr_t matchmaking = (uintptr_t)blm_global(MATCHMAKING_PTR);
    float left;
    if (!Plausible(matchmaking) || !vpm_read_f32(matchmaking + COUNTDOWN, &left)) return;
    if (isnan(left) || left <= (float)seconds || left > (float)GAME_VALUE_LIMIT) return;
    const float value = (float)seconds;
    if (Store(matchmaking + COUNTDOWN, &s.countdownChecked, &value)) s.shortened++;
}

/* The field holds a value the game wrote (or this is the first look): 1, or 0 after stopping. */
static int Followed(uint32_t current)
{
    if (s.hasSettled && current == s.settled) return 1;
    if (s.hasSettled && ++s.refreshes > REWRITE_LIMIT)
    {
        s.stopped = 1;
        SetStatus("field_contended");
        return 0;
    }
    if (!s.hasGameValue || current != s.gameValue)
    {
        s.gameValue = current;
        s.hasGameValue = 1;
        s.revision++;
    }
    return 1;
}

/* The slow path: the field, the setting or the config object changed. 1, or 0 after stopping. */
static int Settle(uint32_t current)
{
    s.dirty = 0;
    if (!Followed(current)) return 0;
    uint32_t gameValue = s.gameValue;
    if (gameValue < GAME_VALUE_MIN || gameValue > GAME_VALUE_LIMIT)
    {
        /* 0: the object exists but the game has not filled it in yet (boot). */
        s.settled = current;
        s.hasSettled = 1;
        s.hasApplied = 0;
        SetStatus(gameValue == 0 ? "waiting_for_game_value" : "unexpected_game_value");
        return 1;
    }
    uint32_t seconds = (uint32_t)s.setting < gameValue ? (uint32_t)s.setting : gameValue;
    if (seconds != current)
    {
        if (!Store(s.field, &s.fieldChecked, &seconds) || blm_load32(s.field) != seconds)
        {
            s.stopped = 1;
            SetStatus("config_write_failed");
            return 0;
        }
        s.writes++;
        if (seconds < gameValue) Shorten(seconds); /* a scan result may already have used the old value this frame */
    }
    s.settled = s.applied = seconds;
    s.hasSettled = s.hasApplied = 1;
    SetStatus(seconds < gameValue ? "active" : "game_value_kept");
    return 1;
}

/* A new config object (confirmed with one guarded read), or 0 while there is none to use. */
static int NewObject(uintptr_t object)
{
    uint32_t value;
    if (object == 0)
    {
        s.config = 0;
        SetStatus("waiting_for_config");
        return 0;
    }
    if (!Plausible(object) || !vpm_read_u32(object + RECHARGE, &value))
    {
        s.config = 0; /* not confirmed readable: asked again next frame */
        SetStatus("waiting_for_config_read");
        return 0;
    }
    if (object != s.owner)
    {
        s.owner = object;
        s.hasSettled = s.hasGameValue = s.hasApplied = 0;
    }
    s.config = object;
    s.field = object + RECHARGE;
    s.dirty = 1;
    return 1;
}

/* lint: per-frame. One check per frame. Idle (nothing changed): two direct loads. */
int blm_scanner_check(void)
{
    if (s.stopped) return 0;
    uintptr_t object = (uintptr_t)blm_global(CONFIG_PTR);
    if ((object != s.config || object == 0) && !NewObject(object)) return 1;
    uint32_t current = blm_load32(s.field);
    if (s.hasSettled && current == s.settled && !s.dirty) return 1;
    return Settle(current);
}

/* A setting from the option (or the default), whole seconds in 5 .. 20; the next check applies it. */
int blm_scanner_set_setting(double value)
{
    if (isnan(value)) return 0;
    double rounded = floor(value + 0.5);
    int seconds = rounded < BLM_SCANNER_MIN ? BLM_SCANNER_MIN : rounded > BLM_SCANNER_MAX ? BLM_SCANNER_MAX : (int)rounded;
    if (seconds != s.setting)
    {
        s.setting = seconds;
        s.dirty = 1;
        s.revision++;
    }
    return 1;
}

/* Puts the game's value back while the field still holds this one's. 0 only when that write failed. */
static int PutBack(void)
{
    uint32_t now;
    if (s.config == 0 || s.config != s.owner || !s.hasSettled || !s.hasGameValue || s.settled == s.gameValue) return 1;
    if (!vpm_read_u32(s.field, &now) || now != s.settled) return 1;
    if (!Store(s.field, &s.fieldChecked, &s.gameValue)) return 0;
    s.settled = s.gameValue; /* the field holds the game's value now: not a rewrite */
    return 1;
}

int blm_scanner_stop(const char* reason)
{
    s.stopped = 1;
    s.status = reason;
    s.revision++;
    return PutBack();
}

static void Seconds(char* out, size_t size, int has, uint32_t value)
{
    if (has) snprintf(out, size, "%u", value);
    else snprintf(out, size, "nil");
}

void blm_scanner_summary(char* out, size_t size)
{
    char game[16], applied[16];
    Seconds(game, sizeof game, s.hasGameValue, s.gameValue);
    Seconds(applied, sizeof applied, s.hasApplied, s.applied);
    snprintf(out, size, "scanner %s: setting %d s, game %s s, field %s s; writes %d, game rewrites %d, countdowns shortened %d",
        s.status, s.setting, game, applied, s.writes, s.refreshes, s.shortened);
}
