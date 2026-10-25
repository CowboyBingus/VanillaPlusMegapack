/* Sticky Grenade Handles: the Lua tests' scenarios (components/StickyGrenadeHandles/tests/test_mod.lua) on the fake
 * game. */
#include <string.h>
#include "harness/test.h"

TEST_GLOBALS;

extern const VpmComponentDef vpm_component_sticky_grenade_handles;
static const VpmComponentDef* const kDefs[] = {&vpm_component_sticky_grenade_handles};

#define LIBRARY_RVA 0x27C5CF0u
#define LIBRARY_VTABLE_RVA 0x148BA78u
#define THROWABLE 0xC4692706u
#define HANDLE 0x9A056E1Cu
#define THERMITE 0xC5C05FCB5747C799ull
#define STICKY_STUN 0x3FA94F58F596BC0Bull
#define ENTRY 80u

static uint8_t* g_library;
static uint8_t* g_entries;
static uint8_t* g_records[2];

static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }

static char* Text(const char* text)
{
    char* copy = fake_heap(strlen(text) + 1);
    memcpy(copy, text, strlen(text) + 1);
    return copy;
}

/* Six materials, the handle at 3 (its name pointer with the ownership bit set) and the throwable at 5. */
static void PutEntry(int index, const char* name, uint32_t tag, int owned)
{
    Put64(g_entries + index * ENTRY, (uint64_t)(uintptr_t)Text(name) | (uint64_t)(owned ? 1 : 0));
    Put32(g_entries + index * ENTRY + 0x48, tag);
}

static void MakeLibrary(void)
{
    g_library = fake_heap(0x58);
    g_entries = fake_heap(6 * ENTRY);
    Put64(g_library, fake_exe() + LIBRARY_VTABLE_RVA);
    Put64(g_library + 0x48, (uint64_t)(uintptr_t)g_entries);
    Put32(g_library + 0x50, 6);
    Put32(g_library + 0x54, 8 | 0x80000000u);
    PutEntry(0, "default", 0x11111111u, 0);
    PutEntry(1, "ice", 0x22222222u, 0);
    PutEntry(2, "metal", 0x33333333u, 1);
    PutEntry(3, "sticky_grenade_handle", HANDLE, 1);
    PutEntry(4, "flesh", 0x44444444u, 0);
    PutEntry(5, "throwable", THROWABLE, 0);
    Put64((uint8_t*)fake_exe() + LIBRARY_RVA, (uint64_t)(uintptr_t)g_library);
}

static void MakeGrenades(void)
{
    const uint64_t resources[2] = {THERMITE, STICKY_STUN};
    for (int i = 0; i < 2; i++)
    {
        g_records[i] = fake_heap(360);
        g_records[i][0x54] = 1;
        Put32(g_records[i] + 0x164, THROWABLE);
        fake_set_row("ThrowableComponentData", resources[i], (uintptr_t)g_records[i]);
    }
}

static uint32_t HandleTag(void) { return Get32(g_entries + 3 * ENTRY + 0x48); }

static void Started(void)
{
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
}

static void AppliesWhenTheEntitiesAreReady(void)
{
    MakeLibrary();
    MakeGrenades();
    Started();
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(HandleTag(), THROWABLE);
    CHECK_LOG("applied (material 3 tagged throwable: the handles of the G-123 Thermite and the sticky stun grenade stick), at load.");
    /* 2 records, header, entries, 3 names (the throwable entry is checked against both names, as the Lua did), the
     * read-back: 8 (the Lua: 13). */
    CHECK_EQ(fake_counts().read, 8);
    CHECK(!vpm_ticking(fake_component(0)));
    fake_counts_reset();
    fake_frames(10, 1.0f / 60);
    CHECK_EQ(fake_counts().read + fake_counts().log, 0);
}

static void AlreadyAppliedWritesNothing(void)
{
    MakeLibrary();
    MakeGrenades();
    Put32(g_entries + 3 * ENTRY + 0x48, THROWABLE);
    Started();
    fake_counts_reset();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_LOG("already applied (material 3");
    CHECK_EQ(fake_counts().read, 7);
}

/* Waits for the library (0 reads per frame while its pointer is unset), applies on the frame it appears. */
static void WaitsForTheEngine(void)
{
    MakeGrenades();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_LOG("Waiting for the game: the material library does not exist yet.");
    CHECK(vpm_ticking(fake_component(0)));
    fake_counts_reset();
    fake_frames(90, 1.0f / 60);
    CHECK_EQ(fake_counts().read, 2 * 90); /* the two grenade records, checked first, as the Lua did */
    MakeLibrary();
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(HandleTag(), THROWABLE);
    CHECK_LOG("applied (material 3");
    CHECK_LOG("after 1.5 s.");
    CHECK(!vpm_ticking(fake_component(0)));
}

static void WaitsForTheThrowableSettings(void)
{
    MakeLibrary();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_LOG("Waiting for the game: the throwable settings are not loaded yet.");
    fake_counts_reset();
    fake_frames(1, 1.0f / 60);
    CHECK_EQ(fake_counts().read, 0);
    fake_frames(36100, 1.0f / 60);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("gave up after 600 s: waiting: the throwable settings are not loaded yet");
    CHECK_EQ(HandleTag(), HANDLE);
}

static void RefusesWhatIsNotAsReviewed(void)
{
    static const char* const texts[] = {
        "Unexpected material library",
        "The sticky stun grenade no longer sticks by the throwable material",
        "The G-123 Thermite no longer sticks by the throwable material",
        "Two sticky_grenade_handle materials",
        "No throwable material",
        "Unexpected material count",
    };
    for (int c = 0; c < 6; c++)
    {
        fake_setup();
        MakeLibrary();
        MakeGrenades();
        if (c == 0) Put64(g_library, fake_exe() + 0x1000);
        if (c == 1) g_records[1][0x54] = 0;
        if (c == 2) Put32(g_records[0] + 0x164, 0x12345678u);
        if (c == 3) PutEntry(1, "sticky_grenade_handle", HANDLE, 0);
        if (c == 4) Put32(g_entries + 5 * ENTRY + 0x48, 0x55555555u);
        if (c == 5) Put32(g_library + 0x50, 9);
        Started();
        fake_fire(HF_EVENT_ENTITIES_READY);
        CHECK(!vpm_running(fake_component(0)));
        CHECK_LOG(texts[c]);
        CHECK_EQ(HandleTag(), HANDLE);
    }
}

static void RefusesReadOnlyMaterials(void)
{
    MakeLibrary();
    MakeGrenades();
    DWORD old;
    VirtualProtect(g_entries, 6 * ENTRY, PAGE_READONLY, &old);
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    VirtualProtect(g_entries, 6 * ENTRY, PAGE_READWRITE, &old);
    CHECK_LOG("Material write refused or failed");
    CHECK_EQ(HandleTag(), HANDLE);
}

static void StopPutsTheTagBack(void)
{
    MakeLibrary();
    MakeGrenades();
    Started();
    fake_fire(HF_EVENT_ENTITIES_READY);
    CHECK_EQ(HandleTag(), THROWABLE);
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(HandleTag(), HANDLE);
}

int main(void)
{
    RUN(AppliesWhenTheEntitiesAreReady);
    RUN(AlreadyAppliedWritesNothing);
    RUN(WaitsForTheEngine);
    RUN(WaitsForTheThrowableSettings);
    RUN(RefusesWhatIsNotAsReviewed);
    RUN(RefusesReadOnlyMaterials);
    RUN(StopPutsTheTagBack);
    TEST_END();
}
