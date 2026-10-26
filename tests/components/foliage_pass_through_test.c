/* Foliage Pass-Through: the Lua tests' scenarios (components/FoliagePassThrough/tests/test_mod.lua) on the fake game,
 * plus HellForge's moved projectile list. */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/foliage_pass_through/foliage_targets.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_foliage_pass_through};

#define BUFFER_RVA 0x348E2F8u
#define LIST_SITE 0x75A391u
#define VANILLA_LIST 0x37C7670u
#define MOVED_LIST 0x4000000u /* inside the fake image, as HellForge's block lies within 2 GB of game.dll */
#define ROW 0x110u
#define OTHER_TYPE 300u      /* an enemy row: never touched */

typedef struct World { uint8_t* buffer; uint8_t* rows[351]; uint32_t list; } World;
static World w;

static void Put32(uint8_t* at, uint32_t value) { memcpy(at, &value, 4); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }

/* The loaded settings: a buffer of rows in type order, the list, the buffer pointer and the list's reader. */
static void MakeWorld(uint32_t list, uint32_t template, int loaded)
{
    memset(&w, 0, sizeof w);
    w.list = list;
    w.buffer = fake_heap((FOLIAGE_TARGET_COUNT + 1) * ROW + 64);
    uint8_t* game = (uint8_t*)fake_game();
    for (int i = 0; i <= FOLIAGE_TARGET_COUNT; i++)
    {
        uint8_t* row = w.buffer + 64 + i * ROW;
        uint32_t type = i < FOLIAGE_TARGET_COUNT ? kFoliageTargets[i].type : OTHER_TYPE;
        Put32(row + 0x00, type);
        Put32(row + 0x08, i < FOLIAGE_TARGET_COUNT ? kFoliageTargets[i].name : 0x12345678u);
        Put32(row + 0x90, i < FOLIAGE_TARGET_COUNT ? kFoliageTargets[i].explosion : 77u);
        Put32(row + 0xF4, i < FOLIAGE_TARGET_COUNT ? template : 0);
        uint64_t at = (uint64_t)(uintptr_t)row;
        memcpy(game + list + type * 8, &at, 8);
        w.rows[type] = row;
    }
    static const uint8_t site[] = {0x48, 0x8B, 0x84, 0xC1};
    memcpy(game + LIST_SITE, site, 4);
    Put32(game + LIST_SITE + 4, list);
    if (loaded) { uint64_t at = (uint64_t)(uintptr_t)w.buffer; memcpy(game + BUFFER_RVA, &at, 8); }
}

static void Load(void) { uint64_t at = (uint64_t)(uintptr_t)w.buffer; memcpy((uint8_t*)fake_game() + BUFFER_RVA, &at, 8); }
static uint32_t Template(uint32_t type) { return Get32(w.rows[type] + 0xF4); }
static int Count(uint32_t value)
{
    int n = 0;
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++) n += Template(kFoliageTargets[i].type) == value;
    return n;
}

static int IsTarget(uint32_t type)
{
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
        if (kFoliageTargets[i].type == type) return 1;
    return 0;
}

/* The real targets: player-side rows only, each type once, all with an impact explosion. */
static void TargetsAreThePlayersOnly(void)
{
    CHECK_EQ(FOLIAGE_TARGET_COUNT, 99);
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
    {
        CHECK(kFoliageTargets[i].type > 0 && kFoliageTargets[i].type < 351 && kFoliageTargets[i].explosion > 0);
        for (int j = 0; j < i; j++) CHECK(kFoliageTargets[i].type != kFoliageTargets[j].type);
    }
    static const uint32_t enemies[] = {112, 9, 87, 88, 316}; /* Automaton artillery, Obelisk, meteor, Outcast beam, volcano */
    static const uint32_t players[] = {239, 151, 293, 110, 132, 31}; /* 500kg bombs, the three 75 mm HEAT rounds */
    for (int i = 0; i < 5; i++) CHECK(!IsTarget(enemies[i]));
    for (int i = 0; i < 6; i++) CHECK(IsTarget(players[i]));
}

static void Started(void)
{
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
}

/* Applies at the event: every target to the no-foliage query, the enemy row untouched; then nothing per frame. */
static void AppliesWhenTheProjectilesAreReady(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    Started();
    fake_counts_reset();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(Count(2), 99);
    CHECK_EQ(Template(OTHER_TYPE), 0);
    CHECK_LOG("applied: 99 projectile types use the no-foliage query (99 changed now, 0 already changed)");
    /* Reads: the list, 99 rows and 99 read-backs (the Lua: 200 with the buffer pointer, which is a plain load here). */
    CHECK_EQ(fake_counts().read, 199);
    CHECK_EQ(fake_counts().write, 0);
    CHECK_EQ(fake_counts().writable, 1);
    CHECK_EQ(fake_counts().code_matches, 0); /* the reader's code was checked at HF_EVENT_GAME_LOADED */
    CHECK(!vpm_ticking(fake_component(0)));
    fake_counts_reset();
    fake_frames(10, 1.0f / 60);
    FakeCounts frame = fake_counts();
    CHECK_EQ(frame.read + frame.write + frame.log, 0);
}

/* HellForge moved the list (a mod added projectile types): the rows are found through the moved one. */
static void FollowsHellForgesMovedList(void)
{
    MakeWorld(MOVED_LIST, 0, 1);
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(Count(2), 99);
    CHECK_LOG("the projectile list was moved by HellForge");
}

/* Waits while the settings are not loaded (one plain load per frame, no API call), applies on the frame they appear. */
static void WaitsForTheSettings(void)
{
    MakeWorld(VANILLA_LIST, 0, 0);
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK(strstr(vpm_status(fake_component(0)), "waiting: the projectile settings are not loaded yet") != NULL);
    fake_counts_reset();
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(fake_counts().read, 0);
    CHECK_EQ(Count(2), 0);
    Load();
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(Count(2), 99);
    CHECK(!vpm_ticking(fake_component(0)));
    CHECK_LOG("applied after");
}

static void GivesUpAfterTenMinutes(void)
{
    MakeWorld(VANILLA_LIST, 0, 0);
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    fake_frames(601, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("gave up after 600 s");
}

/* Already changed: nothing stored, and the log says so. */
static void AlreadyChangedWritesNothing(void)
{
    MakeWorld(VANILLA_LIST, 2, 1);
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_LOG("(0 changed now, 99 already changed)");
    CHECK(vpm_running(fake_component(0)));
}

/* Anything unexpected refuses the whole change: no row written. */
static void RefusesUnexpectedRows(void)
{
    static const struct { uint32_t type, at, value; const char* text; } cases[] = {
        {110, 0x08, 0xDEAD, "Unexpected projectile settings for 75mm HEAT Grenade"},
        {239, 0x90, 0xDEAD, "Unexpected projectile settings for 500kg Bomb"},
        {239, 0x00, 238, "Unexpected projectile settings for 500kg Bomb"},
        {151, 0xF4, 1, "Unexpected raycast template 1 for 500kg Bomb Mk2"},
    };
    for (int c = 0; c < 4; c++)
    {
        fake_setup();
        MakeWorld(VANILLA_LIST, 0, 1);
        Put32(w.rows[cases[c].type] + cases[c].at, cases[c].value);
        Started();
        fake_fire(HF_EVENT_PROJECTILES_READY);
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG(cases[c].text);
        CHECK_EQ(Count(2), 0);
    }
    fake_setup();
    MakeWorld(VANILLA_LIST, 0, 1);
    memset((uint8_t*)fake_game() + VANILLA_LIST + 293 * 8, 0, 8); /* type 293 missing */
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_LOG("No projectile settings for 500kg Bomb Mk3");
    CHECK_EQ(Count(2), 0);
}

/* Another reader reads as code not decoded yet: the core waits for it, then stops the component, nothing changed. */
static void RefusesAnotherReader(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    ((uint8_t*)fake_game())[LIST_SITE] = 0x90;
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(Count(2), 0);
    fake_frames(60, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Foliage Pass-Through] disabled: the projectile list's reader changed (game.dll 0x75A391)");
    CHECK_EQ(Count(2), 0);
}

/* ---- game.dll's code decoded in parts after HF_EVENT_GAME_LOADED (vpm_when_code_ready) ------------------------- */

/* The reader as the game holds it before its part of game.dll is decoded, and once it is. */
static void Encode(void) { memset((uint8_t*)fake_game() + LIST_SITE, 0xCC, 8); }
static void Decode(void)
{
    static const uint8_t site[] = {0x48, 0x8B, 0x84, 0xC1};
    memcpy((uint8_t*)fake_game() + LIST_SITE, site, 4);
    Put32((uint8_t*)fake_game() + LIST_SITE + 4, w.list);
}

/* Decoded at the event: the one code check there, and HF_EVENT_PROJECTILES_READY's work as before. */
static void TheReaderDecodedAtTheEventIsCheckedThere(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    fake_start(kDefs, 1);
    fake_counts_reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    FakeCounts loaded = fake_counts();
    CHECK_EQ(loaded.code_matches, 1);
    CHECK_EQ(loaded.read + loaded.write + loaded.writable + loaded.log, 0);
    fake_counts_reset();
    fake_frames(60, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches + fake_counts().read, 0);
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(fake_counts().read, 199);
    CHECK_EQ(Count(2), 99);
}

/* Still encoded at both events, decoded two seconds later: nothing is read or changed before, the change on the next
 * look (every 30 frames), then nothing. */
static void TheReaderDecodedLaterAppliesThen(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    Encode();
    Started();
    fake_counts_reset();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(fake_counts().read + fake_counts().writable + fake_counts().code_matches + fake_counts().log, 0);
    fake_frames(120, 1.0f / 60);
    FakeCounts waiting = fake_counts();
    CHECK_EQ(waiting.code_matches, 4); /* one look every 30 frames */
    CHECK_EQ(waiting.read + waiting.writable + waiting.log, 0);
    CHECK_EQ(Count(2), 0);
    CHECK(vpm_running(fake_component(0)));
    Decode();
    fake_counts_reset();
    fake_frames(30, 1.0f / 60);
    CHECK_EQ(Count(2), 99);
    CHECK_EQ(Template(OTHER_TYPE), 0);
    CHECK_LOG("applied: 99 projectile types use the no-foliage query (99 changed now, 0 already changed)");
    CHECK_EQ(fake_counts().code_matches, 1);
    CHECK_EQ(fake_counts().read, 199);
    CHECK_EQ(fake_counts().writable, 1);
    fake_counts_reset();
    fake_frames(300, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches + fake_counts().read + fake_counts().log, 0);
}

/* Decoded after HF_EVENT_GAME_LOADED but before the projectile settings load: the wait for them as before. */
static void TheReaderDecodedBeforeTheSettingsWaitsForThem(void)
{
    MakeWorld(VANILLA_LIST, 0, 0);
    Encode();
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK(!vpm_ticking(fake_component(0)));
    Decode();
    fake_frames(30, 1.0f / 60);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_LOG("Waiting for the game: the projectile settings are not loaded yet.");
    Load();
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(Count(2), 99);
    CHECK(!vpm_ticking(fake_component(0)));
}

/* Never decoded: stopped after 60 s naming the reader, nothing read, nothing changed. */
static void TheReaderNeverDecodedStopsItAfterAMinute(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    Encode();
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    fake_counts_reset();
    fake_frames(59, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(1, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Foliage Pass-Through] disabled: the projectile list's reader changed (game.dll 0x75A391)");
    CHECK_EQ(fake_counts().read + fake_counts().writable + fake_counts().write, 0);
    CHECK_EQ(Count(0), 99);
    fake_counts_reset();
    fake_frames(60, 1.0f);
    CHECK_EQ(fake_counts().code_matches + fake_counts().read, 0);
}

/* Settings memory that is not writable: refused before any store. */
static void RefusesReadOnlySettings(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    DWORD old;
    VirtualProtect(w.buffer, (FOLIAGE_TARGET_COUNT + 1) * ROW + 64, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    VirtualProtect(w.buffer, (FOLIAGE_TARGET_COUNT + 1) * ROW + 64, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK_LOG("Projectile settings write refused or failed");
    CHECK_EQ(Count(2), 0);
}

/* The core stopping it puts the vanilla template back on the rows it changed, and only those. */
static void StopPutsTheRowsBack(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    Put32(w.rows[239] + 0xF4, 2); /* already changed before: left as it was */
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(Count(2), 99);
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(Count(0), 98);
    CHECK_EQ(Template(239), 2);
}

/* A live switch-off puts the rows back with one page check (not one per row), a switch-on applies again at once (the
 * code check and HF_EVENT_PROJECTILES_READY replayed after its start), and so on many times. */
static void ALiveSwitchPutsBackAndAppliesAgain(void)
{
    MakeWorld(VANILLA_LIST, 0, 1);
    Started();
    fake_fire(HF_EVENT_PROJECTILES_READY);
    CHECK_EQ(Count(2), 99);
    for (int i = 0; i < 20; i++)
    {
        fake_counts_reset();
        vpm_component_switch(fake_component(0), 0);
        fake_frames(1, 1.0f / 60);
        CHECK(!vpm_running(fake_component(0)));
        CHECK_EQ(Count(0), 99);
        CHECK_EQ(fake_counts().writable, 1);
        vpm_component_switch(fake_component(0), 1);
        fake_frames(1, 1.0f / 60);
        CHECK(vpm_running(fake_component(0)));
        CHECK_EQ(Count(2), 99);
        CHECK_EQ(Template(OTHER_TYPE), 0);
    }
    CHECK_EQ(fake_log_count("applied: 99 projectile types use the no-foliage query (99 changed now, 0 already changed)"), 21);
    fake_counts_reset();
    fake_frames(100, 1.0f / 60);
    CHECK_EQ(fake_counts().read + fake_counts().writable + fake_counts().log, 0);
}

int main(void)
{
    RUN(TargetsAreThePlayersOnly);
    RUN(AppliesWhenTheProjectilesAreReady);
    RUN(FollowsHellForgesMovedList);
    RUN(WaitsForTheSettings);
    RUN(GivesUpAfterTenMinutes);
    RUN(AlreadyChangedWritesNothing);
    RUN(RefusesUnexpectedRows);
    RUN(RefusesAnotherReader);
    RUN(RefusesReadOnlySettings);
    RUN(StopPutsTheRowsBack);
    RUN(ALiveSwitchPutsBackAndAppliesAgain);
    RUN(TheReaderDecodedAtTheEventIsCheckedThere);
    RUN(TheReaderDecodedLaterAppliesThen);
    RUN(TheReaderDecodedBeforeTheSettingsWaitsForThem);
    RUN(TheReaderNeverDecodedStopsItAfterAMinute);
    TEST_END();
}
