/* Better Stratagem Bounce: the Lua tests' scenarios (components/BetterStratagemBounce/tests/test_archive.lua) on the
 * fake game, plus HellForge's moved stratagem list and its live edits.
 *
 * The harness's get_live and set_live keep their values apart from memory, where HellForge's change the row the game
 * reads. So the core runs here with a copy of the fake API whose two live calls work on the rows as HellForge's do for a
 * settings table (fields.c TableRowOf, ApplyEdit, RestoreLive): the row through the list the game reads now, found by
 * the type at its +0, the byte written, and a NULL value putting back the byte from before where the row still holds
 * the change. */
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/better_stratagem_bounce/navigation_flags.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_better_stratagem_bounce};

#define BUFFER_RVA 0x348E8F8u
#define DATA_SIZE 80280u
#define LIST_SITE 0x62F087u
#define VANILLA_LIST 0x37CB600u
#define MOVED_LIST 0x4000000u /* inside the fake image, as HellForge's block lies within 2 GB of game.dll */
#define AT_FLAGS 0x170u
#define OWNED NAVIGATION_OWNED_BIT

/* The Lua test's settings: eleven groups of these sizes and record counts, the 149 types shuffled across them. */
static const uint32_t kGroupSizes[11] = {7204, 1184, 5860, 5228, 19152, 7040, 3832, 18344, 4884, 1104, 6444};
static const uint32_t kGroupCounts[11] = {13, 2, 11, 9, 36, 13, 7, 34, 9, 2, 13};

typedef struct World
{
    uint8_t* data;                     /* the settings */
    uint32_t list;                     /* the list the game reads (game.dll + list) */
    uint32_t at[NAVIGATION_TYPES + 1]; /* each type's record, as an offset in data */
} World;
static World w;
static uint8_t g_original[DATA_SIZE], g_expected[DATA_SIZE], g_neighbour[DATA_SIZE];

typedef struct LiveEdit { int held; uint8_t original, value; } LiveEdit;
static struct
{
    HfApi api;
    int ready;    /* HellForge can read the stratagem rows */
    int refuseAt; /* set_live with a value refused from this call on (1-based), 0 never */
    int dropAt;   /* this set_live is taken but not written (an edit left waiting for its table), 0 never */
    int touchAt;  /* at this set_live another writer sets 0x80 in the 10th changed row's byte, 0 never */
    int gets, sets, undos;
    uint32_t order[256]; /* the types set_live took, in order */
    LiveEdit edits[256];
} t;

static void Put32(uint8_t* at, uint32_t value) { memcpy(at, &value, 4); }
static void Put64(uint8_t* at, uint64_t value) { memcpy(at, &value, 8); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint8_t* Game(void) { return (uint8_t*)fake_game(); }
static uint8_t Flag(uint32_t kind) { return w.data[w.at[kind] + AT_FLAGS]; }
static void SetFlag(uint32_t kind, uint8_t value) { w.data[w.at[kind] + AT_FLAGS] = value; }
static int Owned(uint32_t kind) { return (kNavigationFlags[kind - 1] & OWNED) != 0; }

/* ---- HellForge's live edits of a settings row ------------------------------------------------------------------ */

static uint8_t* Row(uint64_t type)
{
    uint32_t slots = w.list == VANILLA_LIST ? 150u : 198u;
    uint64_t row;
    if (type == 0 || type >= slots) return NULL;
    memcpy(&row, Game() + w.list + type * 8, 8);
    return row != 0 && Get32((const uint8_t*)(uintptr_t)row) == type ? (uint8_t*)(uintptr_t)row : NULL;
}

static int IsFlags(const HfField* field)
{
    return strcmp(field->component, "StratagemDefinition") == 0 && field->layout == 25480438u && field->offset == AT_FLAGS &&
        field->size == 1 && field->type == HF_TYPE_U8;
}

static int TestGetLive(HfMod* mod, HfRef target, const HfField* field, HfLiveValue* out)
{
    t.gets++;
    memset(out, 0, sizeof *out);
    uint8_t* row = t.ready && IsFlags(field) ? Row(target) : NULL;
    if (row == NULL) return 0;
    out->now = (HfValue)HF_U8(row[AT_FLAGS]);
    out->base = target < 256 && t.edits[target].held ? (HfValue)HF_U8(t.edits[target].original) : out->now;
    return HF_APPLIES_MISSION;
}

/* value NULL: the byte from before, where the row still holds the edit; the edit is gone either way. */
static int TestUndo(LiveEdit* e, uint8_t* row)
{
    t.undos++;
    if (e->held && row != NULL && row[AT_FLAGS] == e->value) row[AT_FLAGS] = e->original;
    e->held = 0;
    return HF_APPLIES_MISSION;
}

static int TestSetLive(HfMod* mod, HfRef target, const HfField* field, const HfValue* value, uint32_t flags)
{
    if (!IsFlags(field) || target >= 256) return 0;
    LiveEdit* e = &t.edits[target];
    uint8_t* row = t.ready ? Row(target) : NULL;
    if (value == NULL) return TestUndo(e, row);
    int call = ++t.sets;
    if (call == t.touchAt) Row(t.order[9])[AT_FLAGS] |= 0x80;
    if ((t.refuseAt != 0 && call >= t.refuseAt) || row == NULL || value->type != HF_TYPE_U8 || value->number < 0 || value->number > 255)
        return 0;
    if (!e->held) e->original = row[AT_FLAGS];
    e->held = 1;
    e->value = (uint8_t)value->number;
    t.order[call - 1] = (uint32_t)target;
    if (call != t.dropAt) row[AT_FLAGS] = e->value;
    return HF_APPLIES_MISSION;
}

/* ---- the game ---------------------------------------------------------------------------------------------------- */

static void MakeGroup(int group, uint32_t offset, uint32_t* n)
{
    Put32(w.data + offset, 0x444C444Cu);
    Put32(w.data + offset + 4, 1);
    Put32(w.data + offset + 8, 0x30EB6399u);
    Put32(w.data + offset + 12, kGroupSizes[group] - 24);
    Put32(w.data + offset + 16, 1);
    Put32(w.data + offset + 20, 0);
    Put64(w.data + offset + 24, (uint64_t)(uintptr_t)(w.data + offset + 40));
    Put32(w.data + offset + 32, kGroupCounts[group]);
    for (uint32_t i = 0; i < kGroupCounts[group]; i++, (*n)++)
    {
        uint32_t record = offset + 40 + i * 400, kind = (*n * 5) % 149 + 1;
        Put32(w.data + record, kind);
        Put64(Game() + w.list + kind * 8, (uint64_t)(uintptr_t)(w.data + record));
        w.data[record + AT_FLAGS] = kNavigationFlags[kind - 1];
        w.at[kind] = record;
    }
}

/* The loaded settings (the rest of each record 0xA5), the list the game reads, its reader and the buffer pointer; and
 * the test's HellForge, which can read the rows. */
static void MakeWorld(uint32_t list)
{
    memset(&w, 0, sizeof w);
    memset(&t, 0, sizeof t);
    t.api = *fake_api();
    t.api.get_live = TestGetLive;
    t.api.set_live = TestSetLive;
    t.ready = 1;
    w.list = list;
    w.data = fake_heap(DATA_SIZE);
    memset(w.data, 0xA5, DATA_SIZE);
    Put32(w.data, 11);
    uint32_t offset = 4, n = 0;
    for (int group = 0; group < 11; group++)
    {
        MakeGroup(group, offset, &n);
        offset += kGroupSizes[group];
    }
    CHECK_EQ(offset, DATA_SIZE);
    CHECK_EQ(n, NAVIGATION_TYPES);
    static const uint8_t site[] = {0x48, 0x8B, 0x84, 0xD1};
    memcpy(Game() + LIST_SITE, site, 4);
    Put32(Game() + LIST_SITE + 4, list);
    Put64(Game() + BUFFER_RVA, (uint64_t)(uintptr_t)w.data);
    memcpy(g_original, w.data, DATA_SIZE);
}

static void Reset(void)
{
    fake_counts_reset();
    t.gets = t.sets = t.undos = 0;
}

static void Started(void)
{
    CHECK_EQ(vpm_core_init(&t.api, fake_mod(), kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
    Reset();
}

/* settings with this component's bit cleared in every owned row */
static void OwnedCleared(const uint8_t* settings, uint8_t* out)
{
    memcpy(out, settings, DATA_SIZE);
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES; kind++)
        if (Owned(kind)) out[w.at[kind] + AT_FLAGS] = (uint8_t)(settings[w.at[kind] + AT_FLAGS] & ~OWNED);
}

/* The index-th owned type in the settings' order (the order of the changes). */
static uint32_t NthOwned(int index)
{
    for (uint32_t n = 0; n < NAVIGATION_TYPES; n++)
    {
        uint32_t kind = (n * 5) % 149 + 1;
        if (Owned(kind) && index-- == 0) return kind;
    }
    return 0;
}

/* ---- the tests --------------------------------------------------------------------------------------------------- */

static void FlagsAreTheReviewedOnes(void)
{
    int owned = 0;
    for (int i = 0; i < NAVIGATION_TYPES; i++)
    {
        CHECK(kNavigationFlags[i] <= 3);
        owned += (kNavigationFlags[i] & OWNED) != 0;
    }
    CHECK_EQ(sizeof kNavigationFlags, 149);
    CHECK_EQ(owned, NAVIGATION_OWNED);
}

/* 103 navigation bits change across 149 shuffled records; every other data and code byte survives. Then nothing per
 * frame, and nothing when the game reloads its data (HellForge renews the edits). */
static void ClearsTheOwnedBitOnce(void)
{
    MakeWorld(VANILLA_LIST);
    static uint8_t list[150 * 8];
    memcpy(list, Game() + VANILLA_LIST, sizeof list);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    int changed = 0;
    memcpy(g_expected, g_original, DATA_SIZE);
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES; kind++)
    {
        uint8_t before = kNavigationFlags[kind - 1], after = (uint8_t)(before & ~OWNED);
        CHECK_EQ(Flag(kind), after);
        g_expected[w.at[kind] + AT_FLAGS] = after;
        changed += before != after;
    }
    CHECK_EQ(changed, 103);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
    CHECK(memcmp(Game() + VANILLA_LIST, list, sizeof list) == 0);
    CHECK_EQ(Game()[LIST_SITE + 3], 0xD1);
    CHECK_LOG("[Better Stratagem Bounce] navigation_settings_ready: 103 flags; executable code unchanged");
    CHECK(strcmp(vpm_status(fake_component(0)), "navigation_settings_ready: 103 flags; executable code unchanged") == 0);
    /* The once-only work. Reads: the settings, the list, the settings before and after the changes (the Lua's 6 also
     * read the buffer pointer twice: plain loads here). */
    FakeCounts once = fake_counts();
    CHECK_EQ(once.read, 4);
    CHECK_EQ(once.code_matches, 0); /* the reader's code check came at HF_EVENT_GAME_LOADED (TheReaderIsCheckedAtLoad) */
    CHECK_EQ(once.write + once.find_pattern + once.hook + once.other, 0);
    CHECK_EQ(once.log, 1);
    CHECK_EQ(t.gets, 1);
    CHECK_EQ(t.sets, 103);
    CHECK_EQ(t.undos, 0);
    CHECK(!vpm_ticking(fake_component(0)));
    Reset();
    fake_frames(1000, 1.0f / 60);
    fake_fire(HF_EVENT_ENTITIES_READY);
    FakeCounts idle = fake_counts();
    CHECK_EQ(idle.read + idle.write + idle.log + idle.code_matches + idle.other, 0);
    CHECK_EQ(t.gets + t.sets + t.undos, 0);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
}

/* HellForge moved the list (mods added stratagems): the records are checked against the moved one, the stale list at
 * the vanilla address is never read, and the stratagems mods added keep their own flags. */
static void FollowsHellForgesMovedList(void)
{
    MakeWorld(MOVED_LIST);
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES; kind++) /* each slot one record off */
        Put64(Game() + VANILLA_LIST + kind * 8, (uint64_t)(uintptr_t)(w.data + w.at[kind % 149 + 1]));
    uint8_t* added[2];
    for (uint32_t i = 0; i < 2; i++)
    {
        added[i] = fake_heap(400);
        Put32(added[i], 150 + i);
        added[i][AT_FLAGS] = OWNED;
        Put64(Game() + MOVED_LIST + (150 + i) * 8, (uint64_t)(uintptr_t)added[i]);
    }
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    OwnedCleared(g_original, g_expected);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
    CHECK_EQ(added[0][AT_FLAGS], OWNED);
    CHECK_EQ(added[1][AT_FLAGS], OWNED);
    CHECK_LOG("the stratagem list was moved by HellForge (game.dll +67108864): 2 stratagem(s) mods added (types 150 and up) "
        "keep the beacon flags of the stratagem each copies");
    CHECK_LOG("navigation_settings_ready: 103 flags; executable code unchanged");
    CHECK_EQ(fake_counts().read, 4);
    CHECK_EQ(t.sets, 103);
}

static void GroupCount(void) { Put32(w.data, 12); }
static void Magic(void) { Put32(w.data + 4, 0); }
static void GroupSize(void) { Put32(w.data + 16, DATA_SIZE * 2); }
static void Items(void) { Put64(w.data + 28, (uint64_t)(uintptr_t)(w.data + DATA_SIZE)); }
static void Duplicate(void) { Put32(w.data + w.at[2], 1); }
static void Identity(void) { Put64(Game() + w.list + 8, (uint64_t)(uintptr_t)(w.data + w.at[2])); }
static void NoBuffer(void) { Put64(Game() + BUFFER_RVA, 0); }
static void NoRecords(void) { Put32(w.data + 4 + 32, 0); }
static void ShortLastGroup(void) { Put32(w.data + DATA_SIZE - 6444 + 12, 6444 - 24 - 400); }
static void SettingsUnreadable(void) { fake_hole((uintptr_t)w.data + 1000, 4); }
static void ListUnreadable(void) { fake_hole((uintptr_t)Game() + VANILLA_LIST + 600, 8); }
static void AnotherReader(void) { Game()[LIST_SITE] = 0x90; }

/* Malformed groups, counts, pointers, identities, an unreadable buffer and another reader: refused before any change. */
static void RefusesMalformedSettings(void)
{
    static const struct { void (*corrupt)(void); const char* text; } cases[] = {
        {GroupCount, "disabled: Unexpected settings group count"},
        {Magic, "disabled: Unexpected settings header"},
        {GroupSize, "disabled: Settings group out of bounds"},
        {Items, "disabled: Settings records out of bounds"},
        {Duplicate, "disabled: Unexpected or duplicate stratagem"},
        {Identity, "disabled: Settings table identity mismatch"},
        {NoBuffer, "disabled: Settings buffer unavailable"},
        {NoRecords, "disabled: Invalid record count"},
        {ShortLastGroup, "disabled: Incomplete stratagem settings"},
        {SettingsUnreadable, "disabled: Cannot read settings"},
        {ListUnreadable, "disabled: Cannot read settings table"},
    };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++)
    {
        fake_setup();
        MakeWorld(VANILLA_LIST);
        cases[c].corrupt();
        memcpy(g_expected, w.data, DATA_SIZE);
        Started();
        fake_fire(HF_EVENT_ENTITIES_READY);
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG(cases[c].text);
        CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
        CHECK_EQ(t.sets + t.undos, 0);
    }
}

/* Another reader reads as code not decoded yet: the core waits for it, then stops the component, nothing changed. */
static void RefusesAnotherReader(void)
{
    MakeWorld(VANILLA_LIST);
    AnotherReader();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(60, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: the stratagem list's reader changed (game.dll 0x62F087)");
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    CHECK_EQ(t.gets + t.sets + t.undos, 0);
}

/* Settings memory that is not writable: refused before any change (the Lua's one page check, then no write). */
static void RefusesReadOnlySettings(void)
{
    MakeWorld(VANILLA_LIST);
    Started();
    DWORD old;
    VirtualProtect(w.data, DATA_SIZE, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the fake memory read-only */
    fake_fire(HF_EVENT_ENTITIES_READY);
    VirtualProtect(w.data, DATA_SIZE, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK_LOG("disabled: Settings write refused or failed after 0 of 103 flags; partial-edit recovery=true");
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    CHECK_EQ(t.sets + t.undos, 0);
}

/* The 50th of the 103 changes is refused: the 49 made are taken back. */
static void PartialWriteRecovers(void)
{
    MakeWorld(VANILLA_LIST);
    t.refuseAt = 50;
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: Settings write refused or failed after 49 of 103 flags; partial-edit recovery=true");
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    CHECK_EQ(t.sets, 50);
    CHECK_EQ(t.undos, 49);
    CHECK_EQ(fake_counts().read, 4); /* the settings, the list, the settings before the changes, and after the undo */
}

/* A change HellForge took but did not make (an edit left waiting for its table): the read-back sees it, and all 103
 * are taken back. */
static void VerificationFailureRecovers(void)
{
    MakeWorld(VANILLA_LIST);
    t.dropAt = 103;
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_LOG("disabled: Settings verification failed; partial-edit recovery=true");
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    CHECK_EQ(t.sets, 103);
    CHECK_EQ(t.undos, 103);
}

/* A neighbour's other flag bits, and its bit in a row this component does not own, survive the apply and the undo. */
static void NeighbourBitsSurvive(void)
{
    MakeWorld(VANILLA_LIST);
    uint32_t unowned = 0;
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES; kind++)
    {
        uint8_t value = kNavigationFlags[kind - 1];
        if (kind % 3 == 0) value ^= 0x01;
        if (kind % 4 == 0) value |= 0x40;
        if (!Owned(kind) && unowned == 0) { unowned = kind; value |= OWNED; }
        SetFlag(kind, value);
    }
    memcpy(g_neighbour, w.data, DATA_SIZE);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(strcmp(vpm_status(fake_component(0)), "navigation_settings_ready: 103 flags; executable code unchanged") == 0);
    CHECK_EQ(t.sets, 103);
    CHECK(Flag(unowned) & OWNED);
    OwnedCleared(g_neighbour, g_expected);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
    Reset();
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(t.undos, 103);
    CHECK(memcmp(w.data, g_neighbour, DATA_SIZE) == 0);
    CHECK_NO_LOG("could be put back");
}

/* Bits a neighbour already cleared are accepted, never written and never taken back; all clear writes nothing. */
static void AlreadyClearIsAccepted(void)
{
    MakeWorld(VANILLA_LIST);
    uint32_t cleared[10];
    int n = 0;
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES && n < 10; kind++)
        if (Owned(kind) && kind % 2 == 1) { cleared[n++] = kind; SetFlag(kind, (uint8_t)(Flag(kind) & ~OWNED)); }
    memcpy(g_neighbour, w.data, DATA_SIZE);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_LOG("navigation_settings_ready: 103 flags (10 already clear); executable code unchanged");
    CHECK_EQ(t.sets, 93);
    OwnedCleared(g_neighbour, g_expected);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
    Reset();
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(t.undos, 93);
    CHECK(memcmp(w.data, g_neighbour, DATA_SIZE) == 0);
    for (int i = 0; i < 10; i++) CHECK(!(Flag(cleared[i]) & OWNED));
}

static void AllClearWritesNothing(void)
{
    MakeWorld(VANILLA_LIST);
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES; kind++)
        if (Owned(kind)) SetFlag(kind, (uint8_t)(Flag(kind) & ~OWNED));
    memcpy(g_neighbour, w.data, DATA_SIZE);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_LOG("navigation_settings_ready: 103 flags (103 already clear); executable code unchanged");
    CHECK_EQ(fake_counts().read, 2); /* the settings and the list: no read before or after changes, no page check */
    CHECK_EQ(t.gets + t.sets, 0);     /* nothing to change: HellForge is not asked */
    CHECK(memcmp(w.data, g_neighbour, DATA_SIZE) == 0);
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(t.undos, 0);
    CHECK(memcmp(w.data, g_neighbour, DATA_SIZE) == 0);
}

/* After the apply another writer sets another bit in one changed row and this bit again in a second; a third record
 * stops being the same stratagem. The undo goes by HellForge's whole-byte rule: the first row keeps this change with
 * the other bit (the Lua set this bit back alone), the second keeps its value, the third is not found by identity. */
static void UndoKeepsLaterChanges(void)
{
    MakeWorld(VANILLA_LIST);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    uint32_t first = NthOwned(0), second = NthOwned(1), third = NthOwned(2);
    SetFlag(first, (uint8_t)(Flag(first) | 0x04));
    SetFlag(second, (uint8_t)(Flag(second) | OWNED));
    Put32(w.data + w.at[third], 0);
    Reset();
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(t.undos, 103);
    CHECK_EQ(Flag(first), (kNavigationFlags[first - 1] & ~OWNED) | 0x04);
    CHECK_EQ(Flag(second), kNavigationFlags[second - 1]);
    CHECK(!(Flag(third) & OWNED));
    for (uint32_t kind = 1; kind <= NAVIGATION_TYPES; kind++)
        if (kind != first && kind != third) CHECK_EQ(Flag(kind), kNavigationFlags[kind - 1]);
    CHECK_LOG("stopped: not every one of the 103 beacon flags changed could be put back (a row changed since)");
}

/* A failed write while another writer changes another bit of a row already changed: that row keeps this change, and the
 * log says the recovery is incomplete (the Lua set the bit back alone and reported true). */
static void FailedWriteKeepsALaterChange(void)
{
    MakeWorld(VANILLA_LIST);
    t.refuseAt = 50;
    t.touchAt = 50;
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    uint32_t touched = t.order[9];
    CHECK_LOG("disabled: Settings write refused or failed after 49 of 103 flags; partial-edit recovery=false");
    CHECK_EQ(Flag(touched), (kNavigationFlags[touched - 1] & ~OWNED) | 0x80);
    SetFlag(touched, kNavigationFlags[touched - 1]);
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
}

/* HellForge cannot read the rows yet: checked, then a countdown per frame and one get_live every 30 frames; the whole
 * attempt again on the frame they can be read. */
static void WaitsForHellForge(void)
{
    MakeWorld(VANILLA_LIST);
    t.ready = 0;
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_LOG("Waiting for HellForge: the stratagem rows cannot be read yet.");
    CHECK(strcmp(vpm_status(fake_component(0)), "waiting: HellForge cannot read the stratagem rows yet") == 0);
    CHECK_EQ(fake_counts().read, 2);
    CHECK_EQ(t.gets, 1);
    CHECK_EQ(t.sets, 0);
    Reset();
    fake_frames(29, 1.0f / 60);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches + fake_counts().log, 0);
    CHECK_EQ(t.gets, 0);
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(t.gets, 1);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches + fake_counts().log, 0);
    t.ready = 1;
    Reset();
    fake_frames(30, 1.0f / 60);
    OwnedCleared(g_original, g_expected);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
    CHECK_EQ(t.gets, 2); /* the wait's question, then the attempt's own */
    CHECK_EQ(fake_counts().read, 4);
    CHECK_EQ(t.sets, 103);
    CHECK_LOG("navigation_settings_ready: 103 flags; executable code unchanged");
    CHECK_LOG("applied after 1.0 s of waiting");
    CHECK(!vpm_ticking(fake_component(0)));
}

static void GivesUpAfterTenMinutes(void)
{
    MakeWorld(VANILLA_LIST);
    t.ready = 0;
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    fake_frames(601, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("gave up after 600 s: HellForge cannot read the stratagem rows yet");
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    CHECK_EQ(t.sets, 0);
}

/* ---- game.dll's code decoded in parts after HF_EVENT_GAME_LOADED (vpm_when_code_ready) ------------------------- */

/* The reader as the game holds it before its part of game.dll is decoded, and once it is. */
static void Encode(void) { memset(Game() + LIST_SITE, 0xCC, 8); }
static void Decode(void)
{
    static const uint8_t site[] = {0x48, 0x8B, 0x84, 0xD1};
    memcpy(Game() + LIST_SITE, site, 4);
    Put32(Game() + LIST_SITE + 4, w.list);
}

/* Decoded at load: the one code check at HF_EVENT_GAME_LOADED, nothing else there; the event's work as before. */
static void TheReaderIsCheckedAtLoad(void)
{
    MakeWorld(VANILLA_LIST);
    CHECK_EQ(vpm_core_init(&t.api, fake_mod(), kDefs, 1), 0);
    Reset();
    fake_fire(HF_EVENT_GAME_LOADED);
    FakeCounts loaded = fake_counts();
    CHECK_EQ(loaded.code_matches, 1);
    CHECK_EQ(loaded.read + loaded.write + loaded.log + loaded.other, 0);
    CHECK_EQ(t.gets + t.sets, 0);
    Reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(fake_counts().read, 4);
    CHECK_EQ(fake_counts().code_matches, 0);
    CHECK_EQ(t.sets, 103);
}

/* Still encoded at both events, decoded two seconds later: nothing read or changed before; the whole attempt on the
 * frame of the core's next look; then nothing. */
static void TheReaderDecodedLaterAppliesThen(void)
{
    MakeWorld(VANILLA_LIST);
    Encode();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches + fake_counts().log, 0);
    CHECK_EQ(t.gets + t.sets, 0);
    CHECK(vpm_running(fake_component(0)) && !vpm_ticking(fake_component(0)));
    fake_frames(120, 1.0f / 60);
    CHECK_EQ(fake_counts().code_matches, 4); /* one look every 30 frames */
    CHECK_EQ(fake_counts().read + fake_counts().log, 0);
    CHECK_EQ(t.gets + t.sets, 0);
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    Decode();
    Reset();
    fake_frames(30, 1.0f / 60);
    OwnedCleared(g_original, g_expected);
    CHECK(memcmp(w.data, g_expected, DATA_SIZE) == 0);
    CHECK_LOG("[Better Stratagem Bounce] navigation_settings_ready: 103 flags; executable code unchanged");
    CHECK_EQ(fake_counts().code_matches, 1);
    CHECK_EQ(fake_counts().read, 4);
    CHECK_EQ(t.gets, 1);
    CHECK_EQ(t.sets, 103);
    Reset();
    fake_frames(300, 1.0f / 60);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches + fake_counts().log, 0);
    CHECK_EQ(t.gets + t.sets, 0);
}

/* Decoded later while HellForge cannot read the rows yet: the wait for them as before. */
static void TheReaderDecodedLaterWaitsForHellForge(void)
{
    MakeWorld(VANILLA_LIST);
    t.ready = 0;
    Encode();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    Decode();
    fake_frames(30, 1.0f / 60);
    CHECK(vpm_ticking(fake_component(0)));
    CHECK_LOG("Waiting for HellForge: the stratagem rows cannot be read yet.");
    t.ready = 1;
    fake_frames(30, 1.0f / 60);
    CHECK_LOG("navigation_settings_ready: 103 flags; executable code unchanged");
    CHECK(!vpm_ticking(fake_component(0)));
}

/* Never decoded: stopped after 60 s naming the reader; nothing read, nothing changed. */
static void TheReaderNeverDecodedStopsItAfterAMinute(void)
{
    MakeWorld(VANILLA_LIST);
    Encode();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    fake_frames(59, 1.0f);
    CHECK(vpm_running(fake_component(0)));
    fake_frames(1, 1.0f);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Better Stratagem Bounce] disabled: the stratagem list's reader changed (game.dll 0x62F087)");
    CHECK_EQ(fake_counts().read, 0);
    CHECK_EQ(t.gets + t.sets + t.undos, 0);
    CHECK(memcmp(w.data, g_original, DATA_SIZE) == 0);
    Reset();
    fake_fire(HF_EVENT_ENTITIES_READY); /* a reload after the stop: nothing */
    fake_frames(60, 1.0f);
    CHECK_EQ(fake_counts().read + fake_counts().code_matches, 0);
}

int main(void)
{
    RUN(FlagsAreTheReviewedOnes);
    RUN(ClearsTheOwnedBitOnce);
    RUN(FollowsHellForgesMovedList);
    RUN(RefusesMalformedSettings);
    RUN(RefusesReadOnlySettings);
    RUN(PartialWriteRecovers);
    RUN(VerificationFailureRecovers);
    RUN(NeighbourBitsSurvive);
    RUN(AlreadyClearIsAccepted);
    RUN(AllClearWritesNothing);
    RUN(UndoKeepsLaterChanges);
    RUN(FailedWriteKeepsALaterChange);
    RUN(WaitsForHellForge);
    RUN(GivesUpAfterTenMinutes);
    RUN(RefusesAnotherReader);
    RUN(TheReaderIsCheckedAtLoad);
    RUN(TheReaderDecodedLaterAppliesThen);
    RUN(TheReaderDecodedLaterWaitsForHellForge);
    RUN(TheReaderNeverDecodedStopsItAfterAMinute);
    TEST_END();
}
