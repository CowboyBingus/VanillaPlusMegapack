/* Hellpod Steering Unlocked: the Lua tests' scenarios (components/HellpodSteeringUnlocked/tests/test_data.lua and
 * test_idle_gate.lua) on the fake game, through the component's tick.
 *
 * The world is the Lua tests' fixture: one heap allocation holding the owner and, owner_offset bytes above it, the
 * manager (twice, for a manager that moves), the two game.dll slots pointing at them, and Ready() writing what mission
 * initialization writes. The tests run on a copy of the fake API whose read can run a step of the test after a chosen
 * read (an identity change in the middle of a check, a failed read-back): the reads themselves and their counts are the
 * fake's. */
#include <math.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_hellpod_steering_unlocked};

#define MANAGER_RVA 0x346D578u
#define OWNER_RVA 0x347CF18u
#define OWNER_OFFSET 0x7C8C90u
#define SIZE 69688u
#define DT (1.0f / 60)

typedef struct Place { uint8_t* owner; uint8_t* manager; } Place;
static Place g_places[2];
static Place* g_place;
static uint8_t g_snapshot[SIZE]; /* the manager as a test saved it (static: 68 KB) */

/* ---- the world -------------------------------------------------------------------------------------------------- */

static void Put32(uint8_t* at, uint32_t value) { memcpy(at, &value, 4); }
static void Put64(uint8_t* at, uint64_t value) { memcpy(at, &value, 8); }
static void PutFloat(uint8_t* at, float value) { memcpy(at, &value, 4); }
static void PutSlot(uint32_t rva, uintptr_t value) { Put64((uint8_t*)fake_game() + rva, (uint64_t)value); }

static void MakeWorld(void)
{
    uint8_t* storage = fake_heap(OWNER_OFFSET + 2 * SIZE);
    g_places[0] = (Place){storage, storage + OWNER_OFFSET};
    g_places[1] = (Place){storage + SIZE, storage + OWNER_OFFSET + SIZE};
    g_place = &g_places[0];
}

static void Pointers(void)
{
    PutSlot(MANAGER_RVA, (uintptr_t)g_place->manager);
    PutSlot(OWNER_RVA, (uintptr_t)g_place->owner);
}

static void BlankManager(void) { memset(g_place->manager, 0, SIZE); }

/* What mission initialization writes (the Lua tests' ready()). */
static void Ready(void)
{
    uint8_t* m = g_place->manager;
    memset(m, 0, SIZE);
    m[0] = 1;
    memset(m + 2, 255, 8192);
    Put32(m + 32772, 3);
    Put32(m + 65544, 8);
    Put64(m + 65552, (uint64_t)(uintptr_t)(m + 65576));
    Put32(m + 65560, 1024);
    Put32(m + 65568, 3);
    PutFloat(m + 69672, 1024);
    PutFloat(m + 69676, 512);
    PutFloat(m + 69680, 1024.0f / 64);
    PutFloat(m + 69684, 64.0f / 1024);
}

/* The world of most tests: pointers set, the manager initialized. */
static void ReadyWorld(void)
{
    MakeWorld();
    Pointers();
    Ready();
}

static uint8_t Flag(void) { return g_place->manager[0]; }
static void Snapshot(void) { memcpy(g_snapshot, g_place->manager, SIZE); }
static int Unchanged(void) { return memcmp(g_snapshot, g_place->manager, SIZE) == 0; }
/* Only the flag differs from the snapshot, and it holds value. */
static int OnlyFlagIs(uint8_t value) { return Flag() == value && memcmp(g_snapshot + 1, g_place->manager + 1, SIZE - 1) == 0; }

/* Makes the manager's first page read-only, execute-read-write or read-write again. */
static void Protect(DWORD protection)
{
    DWORD old;
    CHECK(VirtualProtect(g_place->manager, 1, protection, &old)); /* lint-ok: C3 the test changes the fake memory's protection */
}

/* ---- the API with a step after a chosen read ------------------------------------------------------------------- */

static HfApi g_api;
static int (*g_read)(uintptr_t address, void* buffer, size_t size);
static uintptr_t g_stepAt;   /* the address whose nth read runs the step (0: none) */
static int g_stepNth, g_stepSeen, g_stepFails;
static void (*g_step)(void);

static int SteppedRead(uintptr_t address, void* buffer, size_t size)
{
    int result = g_read(address, buffer, size);
    if (g_stepAt != 0 && address == g_stepAt && ++g_stepSeen == g_stepNth)
    {
        if (g_stepFails) result = 1;
        if (g_step != NULL) g_step();
    }
    return result;
}

/* From now on the nth read of address fails (fails) and/or runs step. */
static void AfterRead(uintptr_t address, int nth, int fails, void (*step)(void))
{
    g_stepAt = address;
    g_stepNth = nth;
    g_stepSeen = 0;
    g_stepFails = fails;
    g_step = step;
}

static int NoGameThread(HfMod* mod, HfTickCallback callback, void* user) { return 0; }

/* The component started on the stepped API (with the game thread refused when gameThread is 0). */
static void StartedOn(int gameThread)
{
    g_api = *fake_api();
    g_read = g_api.read;
    g_api.read = SteppedRead;
    if (!gameThread) g_api.on_game_thread = NoGameThread;
    AfterRead(0, 0, 0, NULL);
    CHECK_EQ(vpm_core_init(&g_api, fake_mod(), kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
}

static void Started(void) { StartedOn(1); }

/* Identity changes the tests make in the middle of a check. */
static void ManagerMovesBy16(void) { PutSlot(MANAGER_RVA, (uintptr_t)g_place->manager + 16); }

/* ---- helpers ---------------------------------------------------------------------------------------------------- */

static FakeCounts Frame(float dt)
{
    fake_counts_reset();
    fake_frames(1, dt);
    return fake_counts();
}

static int Running(void) { return vpm_running(fake_component(0)); }
static int StatusIs(const char* status) { return strcmp(vpm_status(fake_component(0)), status) == 0; }

static int Occurrences(const char* text)
{
    int n = 0;
    for (const char* at = strstr(fake_log_text(), text); at != NULL; at = strstr(at + 1, text)) n++;
    return n;
}

/* ---- the Lua's test_data.lua -------------------------------------------------------------------------------------- */

/* Ship initialization waits; exactly one data byte changes; a mission reset is cleared again. */
static void ClearsOneByteEachMission(void)
{
    MakeWorld();
    Pointers();
    BlankManager();
    Started();
    CHECK_LOG("[Hellpod Steering Unlocked] waiting_for_mission");
    fake_frames(1, 0.1f);
    CHECK(StatusIs("waiting_for_mission"));
    CHECK_EQ(Flag(), 0);
    Ready();
    Snapshot();
    fake_frames(1, 0.1f);
    CHECK(OnlyFlagIs(0));
    CHECK(StatusIs("avoidance_settings_ready"));
    CHECK_LOG("[Hellpod Steering Unlocked] avoidance_settings_ready");
    fake_frames(5, 0.1f);
    CHECK(OnlyFlagIs(0));
    Ready();
    fake_frames(1, 0.1f);
    CHECK(OnlyFlagIs(0));
    CHECK_EQ(Occurrences("avoidance_settings_ready"), 1); /* a status line only when the status changes */
    CHECK(Running());
}

/* A flag value that is neither the game's 1 nor this component's 0 comes from another writer: it is left alone on every
 * poll, never fought and never a stop. A 0 needs nothing. Once mission initialization sets the game's 1 again, it is
 * cleared again. */
static void LeavesAnotherWritersValue(void)
{
    static const uint8_t values[] = {2, 255};
    for (int i = 0; i < 2; i++)
    {
        fake_setup();
        ReadyWorld();
        Started();
        fake_frames(1, 0.1f);
        CHECK_EQ(Flag(), 0);
        g_place->manager[0] = values[i];
        Snapshot();
        for (int poll = 0; poll < 29; poll++) /* the next poll is an idle one: it sees the flag change */
        {
            fake_frames(1, 0.1f);
            CHECK(Unchanged());
        }
        CHECK(StatusIs("avoidance_flag_set_by_another_writer"));
        CHECK_EQ(Occurrences("avoidance_flag_set_by_another_writer"), 1);
        CHECK(Running());
        g_place->manager[0] = 0;
        FakeCounts zero = Frame(0.1f);
        CHECK_EQ(zero.read, 6); /* the flag, then the full check: no store, no read-back */
        CHECK(StatusIs("avoidance_settings_ready"));
        Ready();
        fake_frames(1, 0.1f);
        CHECK_EQ(Flag(), 0);
    }
}

typedef void (*Defect)(uint8_t* m);
static void TooManyRecords(uint8_t* m) { Put32(m + 32772, 1025); }
static void TooManyLinks(uint8_t* m) { Put32(m + 65544, 8193); }
static void SetCapacity(uint8_t* m) { Put32(m + 65560, 512); }
static void SetCount(uint8_t* m) { Put32(m + 65564, 1025); }
static void SetKind(uint8_t* m) { Put32(m + 65568, 7); }
static void SetPointer(uint8_t* m) { Put64(m + 65552, (uint64_t)(uintptr_t)(m + 16)); }
static void WidthNaN(uint8_t* m) { PutFloat(m + 69672, NAN); }
static void HalfWidth(uint8_t* m) { PutFloat(m + 69676, 42); }
static void Cell(uint8_t* m) { PutFloat(m + 69680, 42); }
static void Reciprocal(uint8_t* m) { PutFloat(m + 69684, 42); }

/* A layout it cannot verify stops the component at once and changes nothing. */
static void RefusesLayoutsItCannotVerify(void)
{
    static const Defect defects[] = {TooManyRecords, TooManyLinks, SetCapacity, SetCount, SetKind, SetPointer, WidthNaN,
        HalfWidth, Cell, Reciprocal};
    for (int i = 0; i < 10; i++)
    {
        fake_setup();
        ReadyWorld();
        defects[i](g_place->manager);
        Snapshot();
        Started();
        fake_frames(3, 0.1f);
        CHECK(!Running());
        CHECK_LOG("[Hellpod Steering Unlocked] disabled: avoidance_layout_mismatch");
        CHECK(Unchanged());
    }
}

/* Another owner, protection, an unreadable field: the component stops and the data stays as it was. */
static void RefusesOwnersPagesAndReads(void)
{
    static const char* const reasons[] = {"disabled: avoidance_owner_mismatch", "disabled: avoidance_is_not_writable_private_data",
        "disabled: avoidance_is_not_writable_private_data", "disabled: avoidance_fields_unreadable"};
    for (int c = 0; c < 4; c++)
    {
        fake_setup();
        ReadyWorld();
        Snapshot();
        if (c == 0) PutSlot(OWNER_RVA, (uintptr_t)g_place->owner + 8);
        if (c == 1) Protect(PAGE_READONLY);
        if (c == 2) Protect(PAGE_EXECUTE_READWRITE); /* vpm_writable would accept it; the Lua's rule does not */
        if (c == 3) fake_hole((uintptr_t)g_place->manager + 32772, 4);
        Started();
        fake_frames(1, 0.1f);
        if (c == 1 || c == 2) Protect(PAGE_READWRITE);
        CHECK(!Running());
        CHECK(StatusIs(reasons[c]));
        CHECK(Unchanged());
    }
}

/* The read-back fails: the component stops. The store landed and is left (no write of its own was recorded), as the
 * Lua left it when its read-back failed. */
static void StopsWhenTheWriteDoesNotHold(void)
{
    ReadyWorld();
    Snapshot();
    Started();
    AfterRead((uintptr_t)g_place->manager, 3, 1, NULL); /* the flag's reads: the check, the recheck, the read-back */
    fake_frames(1, 0.1f);
    CHECK(StatusIs("disabled: avoidance_data_write_failed"));
    CHECK(OnlyFlagIs(0));
    CHECK_NO_LOG("; avoidance");
}

/* Mission initialization moves the manager between the check and the store: nothing is written, polling goes on, and
 * the next poll checks afresh. */
static void WaitsWhenTheManagerChangesDuringTheCheck(void)
{
    ReadyWorld();
    Snapshot();
    Started();
    AfterRead((uintptr_t)g_place->manager + 69672, 1, 0, ManagerMovesBy16); /* after the check's last read */
    fake_frames(1, 0.1f);
    CHECK(Running());
    CHECK(StatusIs("waiting_for_stable_mission"));
    CHECK(Unchanged());
    AfterRead(0, 0, 0, NULL);
    Pointers();
    fake_frames(1, 0.1f);
    CHECK(OnlyFlagIs(0));
    CHECK(StatusIs("avoidance_settings_ready"));
}

/* stop() puts the game's 1 back over its own 0: exactly the flag byte. */
static void StopPutsTheGameValueBack(void)
{
    ReadyWorld();
    Snapshot();
    Started();
    fake_frames(1, 0.1f);
    CHECK(OnlyFlagIs(0));
    fake_counts_reset();
    vpm_core_stop(fake_component(0), "test");
    CHECK(OnlyFlagIs(1));
    CHECK_EQ(fake_counts().read, 9); /* the check 5, the recheck 3, the read-back 1 (the Lua: 13) */
    CHECK_LOG("[Hellpod Steering Unlocked] disabled: test; avoidance_restored");
}

/* Nothing of its own to put back: stop() writes nothing and logs no outcome. */
static void StopWithNothingToRestore(void)
{
    MakeWorld();
    Pointers();
    BlankManager();
    Started();
    fake_frames(1, 0.1f);
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(Flag(), 0);
    CHECK_NO_LOG("; avoidance");
    CHECK_NO_LOG("nothing_to_restore");
}

typedef void (*Change)(void);
static void AnotherWriter(void) { g_place->manager[0] = 2; }
static void GameReset(void) { g_place->manager[0] = 1; }
static void NewMap(void)
{
    uint8_t* m = g_place->manager;
    PutFloat(m + 69672, 2048);
    PutFloat(m + 69676, 1024);
    PutFloat(m + 69680, 2048.0f / 64);
    PutFloat(m + 69684, 64.0f / 2048);
}
static void BadLayout(void) { Put32(g_place->manager + 32772, 1025); }
static void AnotherOwner(void) { PutSlot(OWNER_RVA, (uintptr_t)g_place->owner + 8); }
static void MovesBeforeTheWrite(void) { AfterRead((uintptr_t)g_place->manager + 69672, 1, 0, ManagerMovesBy16); }

/* stop() leaves anything that is not exactly its own write. */
static void StopLeavesWhatIsNotItsOwn(void)
{
    static const Change changes[] = {AnotherWriter, GameReset, NewMap, BadLayout, AnotherOwner, MovesBeforeTheWrite};
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        ReadyWorld();
        Started();
        fake_frames(1, 0.1f);
        CHECK_EQ(Flag(), 0);
        changes[c]();
        Snapshot();
        vpm_core_stop(fake_component(0), "test");
        CHECK(Unchanged());
        CHECK_LOG("disabled: test; avoidance_left_unchanged");
    }
}

/* A refused page leaves its 0, and the log says why. */
static void StopRefusedByThePage(void)
{
    ReadyWorld();
    Started();
    fake_frames(1, 0.1f);
    Protect(PAGE_READONLY);
    vpm_core_stop(fake_component(0), "test");
    Protect(PAGE_READWRITE);
    CHECK_EQ(Flag(), 0);
    CHECK_LOG("disabled: test; avoidance_is_not_writable_private_data");
}

/* The idle window: 9 polls read the flag byte only, the 10th is a full check; frames between polls make no call. */
static void IdleWindow(const char* status, int line)
{
    for (int i = 0; i < 9; i++)
    {
        FakeCounts poll = Frame(0.05f), between = Frame(0.05f);
        if (poll.read != 1 || poll.log != 0 || between.read + between.log != 0) printf("  (idle window from line %d)\n", line);
        CHECK_EQ(poll.read, 1);
        CHECK_EQ(poll.log + between.read + between.log, 0);
    }
    FakeCounts full = Frame(0.05f), between = Frame(0.05f);
    if (full.read != 5) printf("  (idle window from line %d)\n", line);
    CHECK_EQ(full.read, 5);
    CHECK_EQ(full.log + between.read + between.log, 0);
    CHECK(StatusIs(status));
}

/* The Lua's per-frame call budget, at 20 FPS-equivalent steps (a poll every second frame). No HfApi.write ever. */
static void PinsTheCallsPerFrame(void)
{
    MakeWorld();
    Pointers();
    BlankManager();
    Started();
    FakeCounts ship = Frame(0.05f);
    CHECK_EQ(ship.read, 5);  /* the Lua: 7 (its two slot reads are plain loads here) */
    CHECK_EQ(Frame(0.05f).read, 0);
    IdleWindow("waiting_for_mission", __LINE__);
    IdleWindow("waiting_for_mission", __LINE__);
    Ready();
    FakeCounts first = Frame(0.05f);
    CHECK_EQ(first.read, 10); /* the flag 1, the check 5, the recheck 3, the read-back 1 (the Lua: 14) */
    CHECK_EQ(first.write, 0);
    CHECK_EQ(first.log, 1);
    CHECK_EQ(Flag(), 0);
    CHECK_EQ(Frame(0.05f).read, 0);
    IdleWindow("avoidance_settings_ready", __LINE__);
    IdleWindow("avoidance_settings_ready", __LINE__);
    g_place->manager[0] = 2;
    FakeCounts other = Frame(0.05f);
    CHECK_EQ(other.read, 6); /* the flag 1, the check 5 (the Lua: 8) */
    CHECK_EQ(other.log, 1);
    CHECK_EQ(Frame(0.05f).read, 0);
    CHECK_EQ(Frame(0.05f).read, 1);
    CHECK_EQ(Frame(0.05f).read, 0);
    Ready();
    FakeCounts reset = Frame(0.05f);
    CHECK_EQ(reset.read, 10);
    CHECK_EQ(reset.write, 0);
    CHECK_EQ(Flag(), 0);
    CHECK_EQ(Frame(0.05f).read, 0);
}

/* Before the pointers exist: no read at all (the Lua: 2 per poll). */
static void NoPointersNoReads(void)
{
    MakeWorld();
    Started();
    for (int i = 0; i < 20; i++) CHECK_EQ(Frame(0.1f).read, 0);
    CHECK(StatusIs("waiting_for_mission"));
    Pointers();
    BlankManager();
    CHECK_EQ(Frame(0.1f).read, 5);
}

/* Through the tick: another writer's value is reported once however long it stays and never written; polling goes on,
 * so the game's own value is cleared once mission initialization sets it again. */
static void AnotherWriterReportedOnce(void)
{
    ReadyWorld();
    Started();
    fake_frames(1, 0.1f);
    CHECK(StatusIs("avoidance_settings_ready"));
    g_place->manager[0] = 2;
    fake_frames(50, 0.1f);
    CHECK_EQ(Occurrences("avoidance_flag_set_by_another_writer"), 1);
    CHECK_EQ(Flag(), 2);
    Ready();
    fake_frames(1, 0.1f);
    CHECK_EQ(Flag(), 0);
    CHECK(StatusIs("avoidance_settings_ready"));
}

/* A layout that breaks while the flag holds 0 is noticed at the next full check (the 10th poll), which stops the
 * component; a write it cannot verify is not put back, and a stopped component never checks again. */
static void RefusalAtTheNextFullCheck(void)
{
    ReadyWorld();
    Started();
    fake_frames(1, 0.1f);
    Put32(g_place->manager + 32772, 1025);
    fake_frames(9, 0.1f);
    CHECK(Running());
    fake_frames(1, 0.1f);
    CHECK(!Running());
    CHECK(StatusIs("disabled: avoidance_layout_mismatch"));
    CHECK_NO_LOG("; avoidance");
    Ready();
    fake_counts_reset();
    fake_frames(10, 0.1f);
    CHECK_EQ(Flag(), 1);
    CHECK_EQ(fake_counts().read, 0);
}

/* ---- the Lua's test_idle_gate.lua --------------------------------------------------------------------------------- */

/* Every flag change is acted on at the next poll: a mission reset at any point of the gate's window (and any frame
 * between polls) is cleared on the first poll after it, as v7.5 cleared it with a full check every poll. At 1/60 s per
 * frame the polls are frames 1, 7, 13... */
static void MissionResetClearedAtTheNextPoll(void)
{
    for (int offset = 0; offset <= 12; offset++)
    {
        fake_setup();
        ReadyWorld();
        Started();
        int reset = 30 + offset * 7, clears = 0;
        for (int frame = 1; frame <= reset + 14; frame++)
        {
            uint8_t before = Flag();
            fake_frames(1, DT);
            int polled = (frame - 1) % 6 == 0;
            if (before == 1 && Flag() == 0) clears++;
            CHECK(Flag() == (before == 1 && !polled ? 1 : 0));
            if (frame == reset) g_place->manager[0] = 1;
        }
        CHECK_EQ(clears, 2);
        CHECK(Running());
    }
}

/* What the flag alone cannot show is noticed at the next full check, at most 10 polls after the last one: the manager
 * going blank after a mission, and the manager moving (the old storage left blank, the new one initialized). */
static void HiddenChangesWaitForTheFullCheck(void)
{
    ReadyWorld();
    Started();
    fake_frames(1, 0.1f);
    BlankManager();
    int polls = 0;
    while (StatusIs("avoidance_settings_ready") && polls < 20) { fake_frames(1, 0.1f); polls++; }
    CHECK(polls >= 1 && polls <= 10);
    CHECK(StatusIs("waiting_for_mission"));

    fake_setup();
    ReadyWorld();
    Started();
    fake_frames(1, 0.1f);
    BlankManager();
    g_place = &g_places[1];
    Pointers();
    Ready();
    polls = 0;
    while (Flag() == 1 && polls < 20) { fake_frames(1, 0.1f); polls++; }
    CHECK(polls >= 1 && polls <= 10);
    CHECK_EQ(Flag(), 0);
    CHECK_EQ(g_places[0].manager[0], 0);
    CHECK(StatusIs("avoidance_settings_ready"));
}

/* The poll's timing: the first frame checks at once; a zero, negative or NaN dt adds no time. */
static void PollsEveryTenthOfASecond(void)
{
    ReadyWorld();
    Started();
    fake_frames(1, 0.0f);
    CHECK_EQ(Flag(), 0);
    Ready();
    fake_counts_reset();
    fake_frames(5, 0.0f);
    fake_frames(5, -1.0f);
    fake_frames(5, NAN);
    fake_frames(1, 0.05f);
    CHECK_EQ(fake_counts().read, 0);
    CHECK_EQ(Flag(), 1);
    fake_frames(1, 0.05f);
    CHECK_EQ(Flag(), 0);
}

/* ---- HellForge ---------------------------------------------------------------------------------------------------- */

/* With HellForge's bundled Vanilla Plus in the session (its own, narrower steering patch) the component stays off. */
static void OffWithHellForgesVanillaPlus(void)
{
    fake_add_mod("skyeshade.vanilla-plus", HF_MOD_CODE);
    ReadyWorld();
    Started();
    CHECK(!Running());
    CHECK(strstr(vpm_status(fake_component(0)), "HellForge's Vanilla Plus is on") != NULL);
    fake_counts_reset();
    fake_frames(10, 0.1f);
    CHECK_EQ(fake_counts().read, 0);
    CHECK_EQ(Flag(), 1);
}

/* Without the game thread there is no poll: the component stops at start, as the Lua refused without update. */
static void RefusesWithoutTheGameThread(void)
{
    ReadyWorld();
    StartedOn(0);
    CHECK(!Running());
    CHECK(StatusIs("disabled: Game update unavailable; no change applied"));
    CHECK_EQ(Flag(), 1);
}

int main(void)
{
    RUN(ClearsOneByteEachMission);
    RUN(LeavesAnotherWritersValue);
    RUN(RefusesLayoutsItCannotVerify);
    RUN(RefusesOwnersPagesAndReads);
    RUN(StopsWhenTheWriteDoesNotHold);
    RUN(WaitsWhenTheManagerChangesDuringTheCheck);
    RUN(StopPutsTheGameValueBack);
    RUN(StopWithNothingToRestore);
    RUN(StopLeavesWhatIsNotItsOwn);
    RUN(StopRefusedByThePage);
    RUN(PinsTheCallsPerFrame);
    RUN(NoPointersNoReads);
    RUN(AnotherWriterReportedOnce);
    RUN(RefusalAtTheNextFullCheck);
    RUN(MissionResetClearedAtTheNextPoll);
    RUN(HiddenChangesWaitForTheFullCheck);
    RUN(PollsEveryTenthOfASecond);
    RUN(OffWithHellForgesVanillaPlus);
    RUN(RefusesWithoutTheGameThread);
    TEST_END();
}
