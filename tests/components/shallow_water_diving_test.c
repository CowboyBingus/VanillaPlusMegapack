/* Shallow Water Diving: the Lua tests' scenarios (components/ShallowWaterDiving/tests/test_dive.lua, test_loader.lua and
 * test_idle_equivalence.lua) on the fake game: the same fixture layout (a remote avatar at index 0, the local one at
 * index 1), the same checks, and the calls per check and per frame pinned with the harness's counts.
 *
 * The full check is called directly as the Lua tests called patch.apply (swd_apply), the frames go through the pack's
 * tick. A wrapper around the fake API's read gives the Lua fixture's change_guard (data changed after a given number of
 * reads of an address: the coherence checks, and torn writes, since the C writes are plain stores) and unreadable
 * regions that become readable again. */
#include <math.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/shallow_water_diving/dive_data.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_shallow_water_diving};
static const uint8_t kAvatar[8] = {0x97, 0xFA, 0x4D, 0x29, 0x4D, 0x33, 0x1C, 0x4D};

#define OWNER_SIZE (0xF32F18u + 48u)
#define AM_SIZE 0x550000u
#define LOCAL_CTL (0x53D900u + 0x1238u)
#define OTHER_CTL 0x53D900u
#define ROOT_Z (-1.5967556476593018)

typedef struct World
{
    uint8_t *game, *players, *mission, *player, *owner, *avatars, *drown, *stances, *motion;
    uint8_t *owner_rows, *entities, *entityptrs, *waters, *enables, *stance, *pos, *resource, *constants;
    uint8_t *water, *position, *ctl;
} World;
static World w;

/* ---- the fake API's read, with the Lua fixture's change_guard and unreadable regions --------------------------- */

static HfApi g_api;
static struct { uintptr_t address; int count; void (*change)(void); } g_change;
static uintptr_t g_unreadable;
static size_t g_unreadableSize;

static int WrappedRead(uintptr_t address, void* buffer, size_t size)
{
    if (g_change.change != NULL && address == g_change.address && --g_change.count < 0)
    {
        void (*change)(void) = g_change.change;
        g_change.change = NULL;
        change();
    }
    int result = fake_api()->read(address, buffer, size);
    if (g_unreadableSize != 0 && address < g_unreadable + g_unreadableSize && g_unreadable < address + size) return 1;
    return result;
}

/* After count reads of address, change() alters the game data before the next read of it returns. */
static void ChangeAfter(const void* address, int count, void (*change)(void))
{
    g_change.address = (uintptr_t)address;
    g_change.count = count;
    g_change.change = change;
}

/* ---- the fixture (test_dive.lua's layout) ---------------------------------------------------------------------- */

static uint64_t Ptr(const void* p) { return (uint64_t)(uintptr_t)p; }
static void Put32(uint8_t* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(uint8_t* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutF(uint8_t* at, float v) { memcpy(at, &v, 4); }
static float GetF(const uint8_t* at) { float v; memcpy(&v, at, 4); return v; }
static uint32_t Get32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static int Near(float a, double b) { double d = (double)a - b; return d < 1e-6 && d > -1e-6; }

/* Memory alone on its pages (a page check, or a page made read-only, touches nothing else). */
static uint8_t* PageRegion(size_t size)
{
    uint8_t* raw = fake_heap(size + 2 * 4096);
    return (uint8_t*)(((uintptr_t)raw + 4095) & ~(uintptr_t)4095);
}

/* A 16-slot map (multiplier 1) at header holding key -> index for each pair. */
static uint8_t* Map(uint8_t* header, const uint32_t* keys, const uint32_t* indexes, int n)
{
    uint8_t* rows = fake_heap(128);
    Put64(header, Ptr(rows));
    Put32(header + 8, 16);
    Put32(header + 12, 0xFFFFFFFFu);
    Put32(header + 16, 1);
    for (int i = 0; i < 16; i++) Put32(rows + 8 * i, 0xFFFFFFFFu);
    for (int i = 0; i < n; i++)
    {
        Put32(rows + keys[i] % 16 * 8, keys[i]);
        Put32(rows + keys[i] % 16 * 8 + 4, indexes[i]);
    }
    return rows;
}

static void Global(uint32_t rva, const void* p) { Put64(w.game + rva, Ptr(p)); }

/* test_dive.lua's reset(): a dive just accepted in 20 cm of water, with the first prone frame's startup debt. */
static void Reset(void)
{
    Put32(w.players + 0x3A8, 9);
    Put32(w.mission + 0x40, 1);
    Put32(w.entities + 24 + 8, 222);
    Put32(w.ctl + 0xF88, 0);
    Put32(w.ctl + 0xF8C, 0x20);
    PutF(w.ctl + 0xB84 + 8, 0);
    PutF(w.ctl + 0xB84 + 12, 0);
    w.enables[2] = 1;
    w.enables[3] = 1;
    PutF(w.water + 8, -0.3999999761581421f);
    PutF(w.water + 16, 0.011f);
    PutF(w.water + 20, 4.989f);
    PutF(w.water + 24, -1.3967556476593018f);
    w.water[0] = 1;
    w.water[1] = 0;
    Put32(w.water + 4, 0);
    Put32(w.stance + 56 + 28, 2);
    PutF(w.position + 8, (float)ROOT_Z);
    w.position[32] = 1;
    PutF(w.waters + 8, -9);
    PutF(w.waters + 16, 7);
}

static void MakeEntities(void)
{
    w.entities = w.owner + 0xF32F18;
    for (int i = 0; i < 2; i++)
    {
        memcpy(w.entities + i * 24, kAvatar, 8);
        Put32(w.entities + i * 24 + 8, i == 0 ? 111 : 222);
        Put32(w.entities + i * 24 + 12, i == 0 ? 333 : 444);
        w.entities[i * 24 + 20] = 1;
        Put64(w.avatars + 0x110 + i * 8, Ptr(w.entities + i * 24));
    }
}

/* both: the remote avatar (id 111) has Drownable, stance and movement records too (test_idle_equivalence.lua). */
static void MakeWorld(int both)
{
    static const uint32_t ids[2] = {222, 111}, indexes[2] = {1, 0}, unit[1] = {9}, one[1] = {1};
    int n = both ? 2 : 1;
    w.game = (uint8_t*)fake_game();
    w.players = fake_heap(0x400);
    w.mission = fake_heap(0x44);
    w.owner = fake_heap(OWNER_SIZE);
    w.avatars = fake_heap(AM_SIZE);
    w.drown = fake_heap(80);
    w.stances = fake_heap(72);
    w.motion = fake_heap(0x48E0);
    Global(0x3326468, w.players);
    Global(0x33266A0, w.mission);
    Global(0x346BF98, w.owner);
    Global(0x3326D20, w.avatars);
    Global(0x3326A80, w.drown);
    Global(0x3326598, w.stances);
    Global(0x3326558, w.motion);
    PutF(w.game + 0x23C6CCC, 0.9f);
    PutF(w.game + 0x23C69F8, 0.4f);
    /* Build 25480438's layout: the 2.0 dive timeout sits 0x10 above its old address, another value at the old one. */
    w.constants = w.game + 0x23C7080;
    PutF(w.constants + 0x90, 2);
    PutF(w.constants + 0x80, 1.5f);
    w.player = fake_heap(24);
    Put64(w.players + 0xE8, Ptr(w.player));
    w.player[20] = 1;
    Put32(w.players + 0x3A8, 9);
    Put32(w.players + 0x84, 2);
    Put32(w.players + 0x88, 2);
    Put32(w.mission + 8, 1);
    Put32(w.mission + 0x40, 1);
    w.owner_rows = Map(w.owner + 0xF22EC8, unit, one, 1);
    MakeEntities();
    Map(w.avatars + 0xF8, ids, indexes, 2);
    Put32(w.avatars + 0x6C, 2);
    Map(w.drown + 32, ids, indexes, n);
    Put32(w.drown + 8, 2);
    w.entityptrs = fake_heap(16);
    Put64(w.entityptrs, Ptr(w.entities));
    Put64(w.entityptrs + 8, Ptr(w.entities + 24));
    Put64(w.drown + 56, Ptr(w.entityptrs));
    w.waters = PageRegion(56);
    Put64(w.drown + 64, Ptr(w.waters));
    w.enables = fake_heap(4);
    Put64(w.drown + 72, Ptr(w.enables));
    Map(w.stances + 24, ids, indexes, n);
    w.stance = fake_heap(112);
    Put64(w.stances + 56, Ptr(w.stance));
    Map(w.motion + 0x48A0, ids, indexes, n);
    w.pos = fake_heap(88);
    Put64(w.motion + 0x48D8, Ptr(w.pos));
    w.resource = fake_heap(122 * 16 + 6 * 64);
    Put64(w.owner + 0xF12E20, Ptr(w.resource));
    memcpy(w.resource, kAvatar, 8);
    Put32(w.resource + 8, 5);
    Put32(w.resource + 122 * 16 + 5 * 64, 0x4A182741u);
    PutF(w.resource + 122 * 16 + 5 * 64 + 4, -1.3f);
    w.ctl = w.avatars + LOCAL_CTL;
    Put32(w.ctl + 0xB84, 222);
    w.water = w.waters + 28;
    w.position = w.pos + 44;
    Reset();
}

/* ---- frames: the engine's, through the core's hook of game.dll's update ----------------------------------------- *
 * A frame is the tick, the game's update (InsideTheUpdate: it notes the tick's status and reads, then runs a test's
 * step inside the update), then the post-update check. A session started without the hook (the core's fallback:
 * game.dll's code not decoded) runs both checks inside HellForge's callback, before the update's step. */

static int g_hooked;            /* the session has the core's hook of game.dll's update */
static void (*g_inside)(void);  /* a step inside the next frame's game update, between the two checks */
static char g_tickStatus[64];   /* the status and the reads right after the frame's tick */
static uint32_t g_tickReads;

static void InsideTheUpdate(float dt)
{
    snprintf(g_tickStatus, sizeof g_tickStatus, "%s", vpm_status(fake_component(0)));
    g_tickReads = fake_counts().read;
    void (*step)(void) = g_inside;
    g_inside = NULL;
    if (step != NULL) step();
}

static void Frames(int n) { fake_engine_frames(n, 1.0f / 60); }

static void StartedOn(int hooked)
{
    memset(&g_change, 0, sizeof g_change);
    g_unreadableSize = 0;
    g_hooked = hooked;
    g_inside = NULL;
    if (hooked) fake_frame_update(1);
    fake_after_tick(InsideTheUpdate);
    g_api = *fake_api();
    g_api.read = WrappedRead;
    CHECK_EQ(vpm_core_init(&g_api, fake_mod(), kDefs, 1), 0);
    fake_fire(HF_EVENT_GAME_LOADED);
}

static void Started(void) { StartedOn(1); }

/* A fresh game, fixture and component: the Lua tests' reset() with a new state. */
static void FreshOn(int hooked)
{
    fake_setup();
    MakeWorld(0);
    StartedOn(hooked);
}

static void Fresh(void) { FreshOn(1); }

static const char* g_reason;
static int g_active;
/* patch.apply: 1 accepted, 0 refused, -1 an error (the Lua raised). */
static int Apply(void)
{
    g_reason = NULL;
    g_active = 0;
    return swd_apply(&g_reason, &g_active);
}
static int Restore(void) { const char* why = NULL; return swd_restore(0, &why); }
static int Reason(const char* expected) { return g_reason != NULL && strcmp(g_reason, expected) == 0; }
static int Dive(int on) { Put32(w.ctl + 0xF8C, on ? 0x20u : 0); return 1; }

/* ---- test_dive.lua -------------------------------------------------------------------------------------------- */

static void MissionModes(void)
{
    for (uint32_t mode = 1; mode <= 7; mode++)
    {
        Fresh();
        Put32(w.mission + 0x40, mode);
        CHECK_EQ(Apply(), 1);
        CHECK_EQ(swd.protected, 1);
        CHECK(Restore());
    }
    const uint32_t others[] = {0, 8, 0xFFFFFFFFu};
    for (int i = 0; i < 3; i++)
    {
        Fresh();
        Put32(w.mission + 0x40, others[i]);
        CHECK_EQ(Apply(), 1);
        CHECK_EQ(swd.writes, 0);
    }
    Fresh();
    Put32(w.mission + 0x40, 2);
    Put32(w.mission + 8, 0);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.writes, 0);
}

/* The first-prone-frame startup debt with a synthetic 20 cm water surface; the historical 60 cm failure keeps the
 * game's own restrictions. */
static void DepthLimit(void)
{
    const double depths[] = {-0.1, 0, 0.01, 0.15, 0.199, 0.20, 0.201, 0.25, 0.30, 0.301, 0.45, 0.8};
    for (int i = 0; i < (int)(sizeof depths / sizeof depths[0]); i++)
    {
        Fresh();
        PutF(w.water + 24, (float)((double)GetF(w.position + 8) + depths[i]));
        CHECK_EQ(Apply(), 1);
        int allowed = depths[i] > 0 && depths[i] <= 0.20;
        CHECK_EQ(swd.protected == 1, allowed);
        if (allowed) CHECK(Restore());
        else CHECK_EQ(swd.writes, 0);
    }
    Fresh();
    PutF(w.water + 24, -0.9994804859161377f);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.writes, 0);
}

/* The slider raises the limit up to the standing reference, 1.30; values outside 0.20-1.30 clamp, NaN is refused. */
static void RaisedDepthLimit(void)
{
    const double limits[] = {0.45, 1.30};
    const double depths[] = {0.1, 0.21, 0.44, 0.45, 0.46, 0.8, 1.29, 1.31, 1.6};
    for (int l = 0; l < 2; l++)
        for (int i = 0; i < (int)(sizeof depths / sizeof depths[0]); i++)
        {
            Fresh();
            CHECK(swd.max_water_depth == SWD_MIN_WATER_DEPTH);
            CHECK(swd_set_max_water_depth(limits[l]));
            PutF(w.water + 24, (float)((double)GetF(w.position + 8) + depths[i]));
            CHECK_EQ(Apply(), 1);
            int allowed = depths[i] <= limits[l] && depths[i] < 1.30;
            CHECK_EQ(swd.protected == 1, allowed);
            if (allowed) CHECK(Restore());
            else CHECK_EQ(swd.writes, 0);
        }
    Fresh();
    CHECK(swd_set_max_water_depth(1.30));
    PutF(w.water + 24, -0.9994804859161377f);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1); /* 60 cm water within a raised limit */
    CHECK(Restore());
    CHECK(swd_set_max_water_depth(5) && swd.max_water_depth == 1.30);
    CHECK(swd_set_max_water_depth(0) && swd.max_water_depth == 0.20);
    volatile double zero = 0;
    CHECK(!swd_set_max_water_depth(zero / zero) && swd.max_water_depth == 0.20);
}

/* The game's submersion test on the record, as it runs after the lease. */
static int NativeWaterUpdate(void)
{
    int submerged = (double)GetF(w.water + 24) > (double)GetF(w.position + 8) - (double)GetF(w.water + 8);
    w.water[0] = (uint8_t)submerged;
    PutF(w.water + 16, submerged ? 0.011f : 0);
    return submerged;
}

/* Dry landing restores prone without triggering water; a wet landing restores the original water decision at the native
 * landing timer, not a guessed delay. */
static void StartupDebtAndLandings(void)
{
    Fresh();
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -1.3));
    CHECK(Near(GetF(w.water + 16), 0));
    CHECK_EQ(swd.protected, 1);
    CHECK_EQ(swd.startup_clears, 1);
    CHECK_EQ(swd.writes, 2);
    CHECK(Reason("airborne_reference") && g_active);
    CHECK(!(w.enables[2] != 0 && w.enables[3] != 0 && GetF(w.water + 16) > 0)); /* startup would still enter swimming */
    CHECK(!NativeWaterUpdate()); /* the protected reference no longer classifies the launch as submerged */
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.writes, 2);     /* an active lease never rewrites native data */
    CHECK(Near(GetF(w.waters + 8), -9) && Near(GetF(w.waters + 16), 7));
    PutF(w.water + 24, -3);
    PutF(w.ctl + 0xB84 + 12, 0.5f);
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -0.4));
    CHECK(!NativeWaterUpdate());
    CHECK(!swd.pending.valid);

    Fresh();
    CHECK_EQ(Apply(), 1);
    PutF(w.water + 24, -0.9994804859161377f);
    PutF(w.ctl + 0xB84 + 12, 0.5f);
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -0.4));
    CHECK(NativeWaterUpdate()); /* a wet landing permits native swimming */

    Fresh();
    CHECK_EQ(Apply(), 1);
    PutF(w.water + 24, 1);
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -0.4));
    CHECK(NativeWaterUpdate());
}

/* Ordinary prone, existing swimming, ragdoll, already deep water and older dives never acquire a lease. */
static void OrdinaryStatesNeverLease(void)
{
    for (int kind = 0; kind < 9; kind++)
    {
        Fresh();
        if (kind == 0) Put32(w.ctl + 0xF8C, 0);                      /* prone */
        if (kind == 1) Put32(w.ctl + 0xF88, 0x80000000u);            /* swimming */
        if (kind == 2) Put32(w.ctl + 0xF8C, 0x30);                   /* ragdoll */
        if (kind == 3) PutF(w.water + 24, 1);                        /* deep */
        if (kind == 4) PutF(w.ctl + 0xB84 + 8, 0.2f);                /* an old dive */
        if (kind == 5) PutF(w.ctl + 0xB84 + 12, 0.5f);               /* landing */
        if (kind == 6) PutF(w.water + 20, 0);                        /* drowned */
        if (kind == 7) w.enables[2] = 0;                             /* disabled */
        if (kind == 8) PutF(w.water + 8, -0.8f);                     /* another reference owner */
        CHECK_EQ(Apply(), 1);
        CHECK_EQ(swd.writes, 0);
    }
    Fresh();
    w.enables[3] = 0;
    PutF(w.water + 24, 0);
    PutF(w.water + 16, 0);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.writes, 0);
    CHECK(Reason("water_surface_unavailable"));
    /* A lease given back: the surface gate goes off, the water gets too deep, the 2 s timeout. */
    Fresh();
    CHECK_EQ(Apply(), 1);
    w.enables[3] = 0;
    CHECK_EQ(Apply(), 1);
    CHECK(!swd.pending.valid && Near(GetF(w.water + 8), -0.4));
    Fresh();
    CHECK_EQ(Apply(), 1);
    PutF(w.water + 24, (float)((double)GetF(w.position + 8) + 0.21));
    CHECK_EQ(Apply(), 1);
    CHECK(!swd.pending.valid && Near(GetF(w.water + 8), -0.4));
    Fresh();
    CHECK_EQ(Apply(), 1);
    PutF(w.ctl + 0xB84 + 8, 2);
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("native_timeout") && Near(GetF(w.water + 8), -0.4));
}

/* Engine transitions, restores, record reuse and local-player changes never put old prone bytes on a standing or new
 * avatar. */
static void EngineTransitionsAndOwnership(void)
{
    Fresh();
    CHECK_EQ(Apply(), 1);
    Put32(w.ctl + 0xF8C, 0);
    Put32(w.stance + 56 + 28, 0);
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -1.3)); /* standing: its own reference is already there */
    Fresh();
    CHECK_EQ(Apply(), 1);
    PutF(w.water + 8, -0.8f);
    CHECK(Restore());
    CHECK(Near(GetF(w.water + 8), -0.8f));
    Fresh();
    CHECK_EQ(Apply(), 1);
    Put32(w.entities + 24 + 8, 999);
    CHECK(Restore());
    CHECK_EQ(swd.writes, 2); /* a retired identity is not written */
    Fresh();
    CHECK_EQ(Apply(), 1);
    Put32(w.players + 0x3A8, 0x7FFF);
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -0.4));
    Fresh();
    CHECK_EQ(Apply(), 1);
    Put32(w.mission + 0x40, 0);
    CHECK_EQ(Apply(), 1);
    CHECK(Near(GetF(w.water + 8), -0.4));
}

static void SurfaceMoves(void) { PutF(w.water + 24, -0.8f); }
static void UnitChanges(void) { Put32(w.players + 0x3A8, 10); }
static void CountChanges(void) { Put32(w.avatars + 0x6C, 3); }
static void RegistryMoves(void) { Put64(w.avatars + 0x118, Ptr(w.entities + 48)); }
static void FlagsChange(void) { Put32(w.ctl + 0xF8C, 0x30); }
static void CapacityChanges(void) { Put32(w.drown + 8, 3); }
static void EnablesMove(void) { Put64(w.drown + 72, Ptr(w.enables) + 8); }
static void StancesMove(void) { Put64(w.stances + 56, Ptr(w.stance) + 8); }
static void PositionsMove(void) { Put64(w.motion + 0x48D8, Ptr(w.pos) + 8); }
static void SettingsChange(void) { PutF(w.resource + 122 * 16 + 5 * 64 + 8, 1); }

/* A record changed before the coherence check stops the acquisition; records that share one bulk read keep their own
 * guards. The check reads each record at its own address (count 0), except records that start a bulk read, which the
 * snapshot read there first (count 1). */
static void CoherenceGuards(void)
{
    Fresh();
    ChangeAfter(w.water, 1, SurfaceMoves);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.writes, 0);
    typedef struct Case { int what; int count; void (*change)(void); } Case;
    const Case cases[] = {{0, 0, UnitChanges}, {1, 1, CountChanges}, {2, 0, RegistryMoves}, {3, 0, FlagsChange},
        {4, 1, CapacityChanges}, {5, 0, EnablesMove}, {6, 0, StancesMove}, {7, 0, PositionsMove}, {8, 0, SettingsChange}};
    for (int i = 0; i < 9; i++)
    {
        Fresh();
        const uint8_t* at[] = {w.players + 0x3A8, w.avatars + 0x6C, w.avatars + 0x118, w.ctl + 0xF80, w.drown + 8,
            w.drown + 72, w.stances + 56, w.motion + 0x48D8, w.resource + 122 * 16 + 5 * 64};
        ChangeAfter(at[cases[i].what], cases[i].count, cases[i].change);
        CHECK_EQ(Apply(), 1);
        CHECK(Reason("snapshot_changed"));
        CHECK_EQ(swd.writes, 0);
        CHECK(swd.retry_start);
    }
}

static uint32_t BitsOf(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }
/* The first two bytes of after over before: what a torn 4-byte write leaves. */
static uint32_t Torn(float before, float after) { return (BitsOf(after) & 0xFFFFu) | (BitsOf(before) & 0xFFFF0000u); }
static float Standing(void) { return -1.3f; }
static float Prone(void) { return (float)((double)-1.3f + (double)0.9f); } /* the game's -0.3999999761581421 */

static void TearOffset(void) { Put32(w.water + 8, Torn(Prone(), Standing())); }   /* the lease's store */
static void TearElapsed(void) { Put32(w.water + 16, Torn(0.011f, 0)); }           /* the startup debt's clear */
static void TearRestore(void) { Put32(w.water + 8, Torn(Standing(), Prone())); }  /* a restore's store */

/* The engine replacing the offset during a lease ends it without a write; refused pages and writes that do not hold
 * stop the component with the record put back. */
static void EngineOffsetAndWriteFailures(void)
{
    Fresh();
    CHECK_EQ(Apply(), 1);
    PutF(w.water + 8, -0.8f);
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("offset_changed_by_engine") && !swd.pending.valid && swd.writes == 2);
    CHECK(Near(GetF(w.water + 8), -0.8f));

    Fresh();
    DWORD old;
    VirtualProtect(w.waters, 4096, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the record table read-only */
    CHECK_EQ(Apply(), 0);
    VirtualProtect(w.waters, 4096, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(Reason("reference_write_failed"));
    CHECK_EQ(swd.writes, 0);

    CHECK(BitsOf(Prone()) == Get32((const uint8_t*)&(float){-0.3999999761581421f}));
    for (int at = 1; at <= 2; at++)
    {
        Fresh();
        if (at == 1) ChangeAfter(w.water + 8, 0, TearOffset);   /* the read-back of the offset's store */
        else ChangeAfter(w.water + 16, 1, TearElapsed);         /* after the timer's own check, its read-back */
        CHECK_EQ(Apply(), 0);
        CHECK(Reason(at == 1 ? "reference_write_failed" : "startup_write_failed"));
        CHECK(Near(GetF(w.water + 8), -0.4));
        CHECK(Near(GetF(w.water + 16), 0.011));
        CHECK(!swd.pending.valid);
    }
    Fresh();
    CHECK_EQ(Apply(), 1);
    CHECK(Restore());
    CHECK(Near(GetF(w.water + 8), -0.4));
    Fresh();
    CHECK_EQ(Apply(), 1);
    ChangeAfter(w.water + 8, 1, TearRestore);
    CHECK(!Restore());
    CHECK(Restore()); /* the torn value is recognised as the restore's own */
    CHECK(Near(GetF(w.water + 8), -0.4));
    Fresh();
    w.water[1] = 1;
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.writes, 0);
    Fresh();
    PutF(w.water + 16, 0.1f);
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("existing_submersion"));
    CHECK_EQ(swd.writes, 0);
}

/* Start-up can run checks before the managers and players exist: every null pointer waits, then a later dive is
 * assisted. The first five come before the local avatar's dive controller (polled every 30th frame). */
static void WaitsRecover(void)
{
    for (int n = 0; n < 14; n++)
    {
        Fresh();
        uint8_t* at[] = {w.game + 0x33266A0, w.game + 0x3326468, w.players + 0xE8, w.game + 0x346BF98, w.game + 0x3326D20,
            w.game + 0x3326A80, w.drown + 56, w.drown + 64, w.drown + 72, w.game + 0x3326598, w.stances + 56,
            w.game + 0x3326558, w.motion + 0x48D8, w.owner + 0xF12E20};
        uint64_t kept;
        memcpy(&kept, at[n], 8);
        Put64(at[n], 0);
        for (int i = 0; i < 3; i++)
        {
            CHECK_EQ(Apply(), 1);
            CHECK(g_reason != NULL && strncmp(g_reason, "waiting_for_", 12) == 0);
            CHECK_EQ(swd.writes, 0);
            CHECK_EQ(swd_no_avatar(g_reason), n < 5);
        }
        Put64(at[n], kept);
        CHECK_EQ(Apply(), 1);
        CHECK_EQ(swd.protected, 1);
    }
    CHECK(strcmp(g_reason, "airborne_reference") == 0);
    Fresh();
    Put32(w.drown + 40, 0); /* an empty Drownable map */
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("waiting_for_water_record") && swd.writes == 0);
    Put32(w.drown + 40, 16);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1);
    Fresh();
    Put32(w.stance + 56 + 28, 3);
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("waiting_for_stance") && swd.writes == 0);
    Put32(w.stance + 56 + 28, 2);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1);
    Fresh();
    w.position[32] = 0;
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("waiting_for_movement_reference") && swd.writes == 0);
    w.position[32] = 1;
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1);
    Fresh();
    CHECK_EQ(Apply(), 1);
    Put64(w.players + 0xE8, 0);
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("waiting_for_local_player_pointer"));
    CHECK(Near(GetF(w.water + 8), -0.4));
}

/* Non-null invalid pointers and unsupported settings remain errors. */
static void InvalidDataIsAnError(void)
{
    Fresh();
    Put64(w.game + 0x33266A0, 123);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Invalid mission pointer") == 0);
    CHECK_EQ(swd.writes, 0);
    Fresh();
    PutF(w.resource + 122 * 16 + 5 * 64 + 4, -1.1f);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Drownable settings changed") == 0);
    CHECK_EQ(swd.writes, 0);
    Fresh();
    Put32(w.players + 0x84, 5);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Unsupported player count") == 0);
    Fresh();
    Put32(w.resource + 8, 4);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Unsupported Drownable resource") == 0);
    Fresh();
    Put64(w.entityptrs + 8, Ptr(w.entities)); /* the local record's owner is the remote avatar */
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Drownable identity mismatch") == 0);
    Fresh();
    PutF(w.game + 0x23C6CCC, 0.8f);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Stance offsets changed") == 0);
}

/* The timeout constant: the old address still works as a fallback; when 2.0 is at neither address the check stops and
 * names where 2.0 was seen nearby. */
static void TimeoutConstant(void)
{
    Fresh();
    PutF(w.constants + 0x90, 0);
    PutF(w.constants + 0x80, 2);
    CHECK_EQ(Apply(), 1); /* the old address */
    CHECK(swd.constants_verified);
    Fresh();
    PutF(w.constants + 0x90, 0);
    PutF(w.constants + 0x80, 0);
    PutF(w.constants + 0x20, 2);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Native dive timeout changed (2.0 near expected block at: 0x23c70a0)") == 0);
    CHECK(!swd.constants_verified);
    PutF(w.constants + 0x20, 0);
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Native dive timeout changed (2.0 near expected block at: none)") == 0);
    Fresh();
    CHECK_EQ(Apply(), 1); /* build 25480438's layout */
    CHECK(swd.constants_verified);
}

/* The idle gate answers 1 only for the same avatar id with no dive flag and finite timers. A full check follows a
 * change of local avatar, and the gate then watches the new avatar's controller. */
static void IdleGate(void)
{
    Fresh();
    Dive(0);
    CHECK_EQ(Apply(), 1);
    CHECK(swd.gate && swd.gate_controller == (uintptr_t)w.ctl);
    CHECK(swd_idle(swd.gate_controller, swd.gate_id));
    Put32(w.avatars + OTHER_CTL + 0xB84, 111);
    Put32(w.owner_rows + 9 % 16 * 8 + 4, 0);
    CHECK(swd_idle(swd.gate_controller, swd.gate_id) && swd.gate_controller == (uintptr_t)w.ctl); /* until a full check */
    CHECK_EQ(Apply(), 1);
    CHECK(swd.gate_controller == (uintptr_t)(w.avatars + OTHER_CTL) && swd.key == (uintptr_t)w.entities);
    CHECK(swd_idle(swd.gate_controller, swd.gate_id));
    Put32(w.avatars + OTHER_CTL + 0xF8C, 0x20);
    CHECK(!swd_idle(swd.gate_controller, swd.gate_id)); /* a dive */
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("waiting_for_water_record") && !swd.gate && swd.writes == 0);

    Fresh();
    Dive(0);
    CHECK_EQ(Apply(), 1);
    Put32(w.ctl + 0xB84, 999);
    CHECK(!swd_idle(swd.gate_controller, swd.gate_id)); /* another avatar id */
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Dive controller identity mismatch") == 0);
    Fresh();
    Dive(0);
    CHECK_EQ(Apply(), 1);
    PutF(w.ctl + 0xB84 + 8, NAN);
    CHECK(!swd_idle(swd.gate_controller, swd.gate_id)); /* a NaN dive timer */
    CHECK_EQ(Apply(), -1);
    CHECK(strcmp(swd_error(), "Invalid movement or water value") == 0);
}

/* Map lookups use the low 32 bits of key * multiplier as the game does: the local entity through a 2^20-slot map with a
 * unit id above 16 bits and real multipliers. */
static void HashLookups(void)
{
    const uint32_t multipliers[] = {0x9E3779B1u, 0xFFFFFFFFu, 0x10001u, 0x7FFFFFFFu, 3, 0xDEADBEEFu};
    const uint32_t unit = 0x12345;
    for (int n = 0; n < 6; n++)
    {
        Fresh();
        uint8_t* header = w.owner + 0xF22EC8;
        uint8_t* rows = fake_heap(0x100000u * 8u);
        uint32_t slot = (unit * multipliers[n]) & 0xFFFFFu;
        Put32(rows + slot * 8u, unit);
        Put32(rows + slot * 8u + 4, 1);
        Put32(w.players + 0x3A8, unit);
        Put64(header, Ptr(rows));
        Put32(header + 8, 0x100000u);
        Put32(header + 16, multipliers[n]);
        CHECK_EQ(Apply(), 1);
        CHECK_EQ(swd.protected, 1);
        CHECK(Restore());
    }
    /* Up to 128 probes, as the Lua (the core's vpm_lookup stops at 64): the unit 100 rows after its slot. */
    Fresh();
    uint8_t* header = w.owner + 0xF22EC8;
    uint8_t* rows = fake_heap(256 * 8);
    for (uint32_t i = 0; i < 100; i++) Put32(rows + ((unit + i) & 255u) * 8u, 0x50000u + i);
    Put32(rows + ((unit + 100) & 255u) * 8u, unit);
    Put32(rows + ((unit + 100) & 255u) * 8u + 4, 1);
    Put32(w.players + 0x3A8, unit);
    Put64(header, Ptr(rows));
    Put32(header + 8, 256);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1);
}

/* Reads per check (the Lua's in brackets: it read game.dll's globals and constants through ReadProcessMemory too). */
static void CheckBudget(void)
{
    Fresh();
    Put32(w.mission + 8, 0);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("waiting_for_mission"));
    CHECK_EQ(fake_counts().read, 1); /* [2] */
    Put32(w.mission + 8, 1);
    Dive(0);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("dive_ended"));
    CHECK_EQ(fake_counts().read, 10); /* idle in a mission, full check [14] */
    fake_counts_reset();
    CHECK(swd_idle(swd.gate_controller, swd.gate_id));
    CHECK_EQ(fake_counts().read, 1); /* the gate [1] */
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(fake_counts().read, 10);
    Dive(1);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("airborne_reference"));
    CHECK_EQ(fake_counts().read, 75); /* the first dive start [98]: one page check covers both writes */
    CHECK_EQ(swd.queries, 1);
    CHECK_EQ(swd.writes, 2);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("airborne_reference"));
    CHECK_EQ(fake_counts().read, 24); /* a dive held [31] */
    Dive(0);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("dive_ended"));
    CHECK_EQ(fake_counts().read, 37); /* the dive's end [49]: the landing write reuses its dive's page check */
    CHECK_EQ(swd.queries, 1);
    CHECK_EQ(swd.writes, 3);
    fake_counts_reset();
    CHECK(swd_idle(swd.gate_controller, swd.gate_id));
    CHECK_EQ(fake_counts().read, 1);
    PutF(w.water + 16, 0.011f);
    Dive(1);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(fake_counts().read, 75); /* a later dive start [93] reuses the kept check */
    CHECK_EQ(swd.queries, 1);
    CHECK_EQ(swd.writes, 5);
    /* A restore outside a normal landing (a stop) checks the page again. */
    CHECK(Restore());
    CHECK_EQ(swd.queries, 2);
    CHECK_EQ(swd.writes, 6);
}

/* One dive and its end in record (both checks); the page checks they made. */
static uint32_t DiveIn(uint8_t* record)
{
    uint32_t before = swd.queries;
    PutF(record + 16, 0.011f);
    Dive(1);
    CHECK_EQ(Apply(), 1);
    CHECK(swd.pending.valid); /* assisted */
    Dive(0);
    CHECK_EQ(Apply(), 1);
    CHECK(!swd.pending.valid); /* released */
    return swd.queries - before;
}

/* Page checks follow the table: kept across dives while the same Drownable manager, table and avatar are in use;
 * dropped by any wait, avatar change, table move or failed write. */
static void PageChecksFollowTheTable(void)
{
    Fresh();
    Dive(0);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(w.water), 1);
    CHECK_EQ(DiveIn(w.water), 0);
    CHECK_EQ(DiveIn(w.water), 0);
    Put32(w.mission + 8, 0);
    CHECK_EQ(Apply(), 1);
    Put32(w.mission + 8, 1);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(w.water), 1); /* a wait drops it */
    Put32(w.entities + 24 + 12, 555);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(w.water), 1); /* an avatar change */
    Put32(w.entities + 24 + 12, 444);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(w.water), 1);
    uint8_t* moved = PageRegion(56);
    memcpy(moved, w.waters, 56);
    Put64(w.drown + 64, Ptr(moved));
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(moved + 28), 1); /* a moved table */
    CHECK_EQ(swd.table_moves, 1);
    CHECK_EQ(DiveIn(moved + 28), 0);
    Put64(w.drown + 64, Ptr(w.waters));
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(w.water), 1);
    CHECK_EQ(swd.table_moves, 2);
    uint8_t* manager = fake_heap(80);
    memcpy(manager, w.drown, 80);
    Global(0x3326A80, manager);
    CHECK_EQ(DiveIn(w.water), 1); /* a new Drownable manager object (same table) */
    CHECK_EQ(swd.table_moves, 3);
    Global(0x3326A80, w.drown);
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(DiveIn(w.water), 1);
    swd.write_check.high = swd.write_check.low + 28 + 8;
    CHECK_EQ(DiveIn(w.water), 1); /* a record outside the approved span */
    PutF(w.water + 16, 0.011f);
    Dive(1);
    ChangeAfter(w.water + 8, 0, TearOffset);
    CHECK_EQ(Apply(), 0);
    CHECK(!swd.write_check.valid); /* a failed write drops it */
}

/* A dive the component does not assist (deep water) is read in full on each check; the gate runs again after it. */
static void UnassistedDiveBudget(void)
{
    Fresh();
    Dive(0);
    CHECK_EQ(Apply(), 1);
    PutF(w.water + 24, 1);
    Dive(1);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("deep_water"));
    CHECK_EQ(fake_counts().read, 24); /* [34, with the constants] */
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("deep_water"));
    CHECK_EQ(fake_counts().read, 24); /* [31] */
    Dive(0);
    fake_counts_reset();
    CHECK_EQ(Apply(), 1);
    CHECK(Reason("dive_ended"));
    CHECK_EQ(fake_counts().read, 10); /* [14] */
    fake_counts_reset();
    CHECK(swd_idle(swd.gate_controller, swd.gate_id));
    CHECK_EQ(fake_counts().read, 1);
    CHECK_EQ(swd.writes + swd.queries, 0);
}

/* ---- the whole per-frame path (test_dive.lua's guarded update, test_loader.lua's cadence) ---------------------- */

static const char* Status(void) { return vpm_status(fake_component(0)); }
static int StatusIs(const char* expected) { return strcmp(Status(), expected) == 0; }

static int Posting(void) { return vpm_post_ticking(fake_component(0)); }

/* One frame: its reads, and nothing else (no write, no log of the component's; the core's status line, rate-limited,
 * is the core's). */
static uint32_t Frame(void)
{
    int statusLines = fake_log_count("[core] Shallow Water Diving status:");
    fake_counts_reset();
    Frames(1);
    FakeCounts c = fake_counts();
    CHECK_EQ(c.write + c.log - (uint32_t)(fake_log_count("[core] Shallow Water Diving status:") - statusLines) + c.other, 0);
    return c.read;
}

/* One frame's reads: the tick's (the 1:1 port's one check) and the post-update check's. Without the hook the two run
 * back to back and only their sum is seen. */
#define PIN(tick, post) do { uint32_t total_ = Frame(); \
    if (g_hooked) { CHECK_EQ(g_tickReads, tick); CHECK_EQ(total_ - g_tickReads, post); } \
    else CHECK_EQ(total_, (tick) + (post)); } while (0)

/* The calls per frame, tick + post (the Lua's whole update in brackets: its step and its after-update check). */
static void FrameBudgetOn(int hooked)
{
    MakeWorld(0);
    Put32(w.mission + 8, 0);
    fake_counts_reset();
    Frames(5);
    CHECK_EQ(fake_counts().read, 0); /* nothing ticks before game.dll is loaded */
    StartedOn(hooked);
    CHECK_EQ(fake_counts().read + fake_counts().write, 0); /* start and the load event: the option, the tick */
    CHECK(vpm_ticking(fake_component(0)) && !Posting());
    CHECK_LOG("[Shallow Water Diving] waiting_for_mission (max dive water depth 0.20; depth option registered)");
    /* Outside a mission (the ship, loading screens) every 30th frame checks (1 read [2]); the frames between make no
     * call; no post check (no local avatar). */
    PIN(1, 0);
    CHECK(StatusIs("waiting_for_mission") && !Posting());
    for (int i = 0; i < 29; i++) PIN(0, 0);
    PIN(1, 0);
    /* A mission is seen at the next poll. */
    Put32(w.mission + 8, 1);
    Dive(0);
    for (int i = 0; i < 29; i++) PIN(0, 0);
    CHECK(StatusIs("waiting_for_mission") && !Posting());
    /* Idle in a mission: a full check (10 reads) on every 120th frame, the gate (1) on the others, then the gate after
     * the update (1) [15 and 2]. */
    int full = 0;
    for (int i = 1; i <= 240; i++)
    {
        uint32_t reads = Frame();
        CHECK(reads == 2 || reads == 11);
        if (g_hooked) CHECK_EQ(reads - g_tickReads, 1);
        if (reads == 11) { full++; CHECK_EQ(i % 120, 1); }
        CHECK(StatusIs("dive_ended") && Posting());
    }
    CHECK_EQ(full, 2);
    /* A dive start (the 240 idle frames used up the gate, so the frame starts with the full check): the session's first
     * dive, one page check, then the held check [129 reads, 1 page check, 2 writes]; held [62]; its end, then the gate
     * [50, 1 write]. */
    Dive(1);
    PIN(75, 24);
    CHECK_EQ(swd.queries, 1);
    CHECK_EQ(swd.writes, 2);
    CHECK(StatusIs("airborne_reference"));
    PIN(24, 24);
    Dive(0);
    PIN(37, 1);
    CHECK_EQ(swd.writes, 3);
    CHECK(StatusIs("dive_ended"));
    PIN(1, 1);
    /* A dead local player (no unit): both gates keep answering for the old controller until the next full check (at
     * most 120 frames), which waits and stops the post check; then every 30th frame checks (3 reads [5]) until a unit
     * exists again. */
    Put32(w.players + 0x3A8, 0x7FFF);
    int dead = 0;
    while (StatusIs("dive_ended") && dead <= 120) { dead++; Frames(1); }
    CHECK(dead <= 120);
    CHECK(StatusIs("waiting_for_local_avatar") && !Posting());
    for (int i = 0; i < 29; i++) PIN(0, 0);
    PIN(3, 0);
    Put32(w.players + 0x3A8, 9);
    for (int i = 0; i < 29; i++) PIN(0, 0);
    CHECK(StatusIs("waiting_for_local_avatar"));
    PIN(10, 1); /* respawned [15] */
    CHECK(StatusIs("dive_ended") && Posting());
    PIN(1, 1);
    /* A dive held: two checks every frame. */
    PutF(w.water + 16, 0.011f);
    Dive(1);
    Frames(1);
    CHECK(StatusIs("airborne_reference") && swd.pending.valid);
    for (int i = 0; i < 10; i++) PIN(24, 24);
    Dive(0);
    Frames(1);
    CHECK(StatusIs("dive_ended") && !swd.pending.valid);
    CHECK(Near(GetF(w.water + 8), -0.4));
}

static void FrameBudget(void) { FrameBudgetOn(1); }
/* Without the core's hook the post check runs right after the tick: the same calls, both before the game's update. */
static void FrameBudgetWithoutTheHook(void) { FrameBudgetOn(0); }

/* ---- test_idle_equivalence.lua's script, on both check points of a frame --------------------------------------- */

static int g_slot = 1;
static int g_diving;
static uint8_t* Controller(void) { return w.avatars + (g_slot == 1 ? LOCAL_CTL : OTHER_CTL); }
static uint8_t* WaterOf(void) { return w.waters + 28 * g_slot; }
static void SetDepth(double depth)
{
    PutF(WaterOf() + 24, (float)(ROOT_Z + depth));
    PutF(w.pos + 44 * g_slot + 8, (float)ROOT_Z);
}
/* A dive starts: the dive flag, fresh timers, prone, the prone reference and the first prone frame's startup debt. */
static void DiveStart(void)
{
    PutF(Controller() + 0xB84 + 8, 0);
    PutF(Controller() + 0xB84 + 12, 0);
    PutF(WaterOf() + 8, -0.3999999761581421f);
    PutF(WaterOf() + 16, 0.011f);
    Put32(w.stance + 56 * g_slot + 28, 2);
    Put32(Controller() + 0xF8C, 0x20);
    g_diving = 1;
}
static void DiveOver(void) { Put32(Controller() + 0xF8C, 0); g_diving = 0; }

static void ScriptWorld(void)
{
    MakeWorld(1);
    Put32(w.mission + 8, 0);
    for (int slot = 0; slot < 2; slot++)
    {
        uint8_t* water = w.waters + 28 * slot;
        uint8_t* ctl = w.avatars + (slot == 1 ? LOCAL_CTL : OTHER_CTL);
        Put32(ctl + 0xB84, slot == 0 ? 111 : 222);
        Put32(ctl + 0xF88, 0);
        Put32(ctl + 0xF8C, 0);
        PutF(ctl + 0xB84 + 8, 0);
        PutF(ctl + 0xB84 + 12, 0);
        w.enables[2 * slot] = 1;
        w.enables[2 * slot + 1] = 1;
        PutF(water + 8, -0.3999999761581421f);
        PutF(water + 16, 0.011f);
        PutF(water + 20, 4.989f);
        PutF(water + 24, (float)(ROOT_Z - 2));
        water[0] = 1;
        water[1] = 0;
        Put32(water + 4, 0);
        Put32(w.stance + 56 * slot + 28, 2);
        PutF(w.pos + 44 * slot + 8, (float)ROOT_Z);
        w.pos[44 * slot + 32] = 1;
    }
    g_slot = 1;
    g_diving = 0;
}

/* Every change of status: the frame and the new status. */
#define CHANGES 256
static int g_frame;
static char g_last[64];
static int g_changes[CHANGES];
static char g_changed[CHANGES][64];
static int g_changeCount;

/* The game's update: the frame's step (the Lua's "during"), then the dive timer runs while diving. */
static void (*g_scriptStep)(void);
static void ScriptUpdate(void)
{
    void (*step)(void) = g_scriptStep;
    g_scriptStep = NULL;
    if (step != NULL) step();
    if (g_diving) PutF(Controller() + 0xB84 + 8, GetF(Controller() + 0xB84 + 8) + 1.0f / 60);
}

/* A frame: the tick, the game's update, the check after it; the status it leaves is recorded when it changed. */
static void ScriptFrame(void)
{
    g_frame++;
    g_inside = ScriptUpdate;
    Frames(1);
    if (strcmp(g_last, Status()) == 0) return;
    snprintf(g_last, sizeof g_last, "%s", Status());
    if (g_changeCount >= CHANGES) return;
    g_changes[g_changeCount] = g_frame;
    snprintf(g_changed[g_changeCount++], sizeof g_changed[0], "%s", g_last);
}

/* The first frame at or after from at which the status became status, or -1. */
static int SeenAt(const char* status, int from)
{
    for (int i = 0; i < g_changeCount; i++)
        if (g_changes[i] >= from && strcmp(g_changed[i], status) == 0) return g_changes[i];
    return -1;
}

static void Landing(void) { PutF(Controller() + 0xB84 + 12, 0.5f); }

/* Runs the frames before frame t: a change made next happens before frame t's tick (the Lua's "before" step). */
static void Until(int t) { while (g_frame < t - 1) ScriptFrame(); }
/* Frame t's tick, then a change inside its game update (the Lua's "during" step), then the rest of the update and the
 * check after it. */
static void During(int t, void (*step)(void))
{
    Until(t);
    g_scriptStep = step;
    ScriptFrame();
}

/* test_idle_equivalence.lua's script. With the core's hook, a change inside the game's update (450, 600) is seen by the
 * check after it, in the same frame, as the Lua's after-update boundary saw its "during" steps; without the hook both
 * checks run before the update, so it is seen at the next frame's tick, as in the 1:1 port. Everything else is the same
 * either way. */
static void PlayScript(int hooked)
{
    int late = !hooked;
    ScriptWorld();
    StartedOn(hooked);
    g_frame = 0;
    g_last[0] = 0;
    g_changeCount = 0;
    Until(125); Put32(w.mission + 8, 1);                       /* a mission starts (poll) */
    Until(200); SetDepth(0.15);                                /* approaching shallow water */
    Until(420); DiveStart();                                   /* an assisted dive with the startup debt */
    During(450, Landing);                                      /* landing, inside the game update */
    Until(455); DiveOver();
    CHECK(Near(GetF(WaterOf() + 8), -0.4));
    During(600, DiveStart);                                    /* a dive starts inside the game update */
    Until(640); DiveOver();
    Until(760); WaterOf()[1] = 1; DiveStart();                 /* deep water */
    Until(790); DiveOver(); WaterOf()[1] = 0;
    Until(830); SetDepth(0.5); DiveStart();                    /* too deep */
    Until(850); DiveOver();
    Until(900); SetDepth(-0.5); DiveStart();                   /* dry land */
    Until(920); DiveOver();
    Until(1000); w.enables[2 * g_slot + 1] = 0;                /* leaving the water (no surface) */
    Until(1010); DiveStart();
    Until(1030); DiveOver(); w.enables[2 * g_slot + 1] = 1; SetDepth(0.15);
    CHECK_EQ(swd.protected, 2);
    CHECK_EQ(swd.observed, 6);
    Until(1100); g_unreadable = (uintptr_t)w.avatars; g_unreadableSize = AM_SIZE; /* avatar data unreadable */
    Until(1163); g_unreadableSize = 0;
    Until(1280); SetDepth(-0.5); DiveStart();
    Until(1290); DiveOver();
    /* After a dive's end (a full check) a death on the next frame is seen at the 120th frame (1410), and a respawn
     * right after that check at the next poll (1440). */
    Until(1291); Put32(w.players + 0x3A8, 0x7FFF);
    Until(1411); Put32(w.owner_rows + 9 % 16 * 8 + 4, 0); Put32(w.players + 0x3A8, 9); g_slot = 0; SetDepth(0.15);
    Until(1520); DiveStart();                                  /* an assisted dive as the new avatar */
    Until(1550); DiveOver();
    Until(1551);
    CHECK(Near(GetF(WaterOf() + 8), -0.4));
    Until(1650); PutF(Controller() + 0xB84 + 8, NAN);          /* a non-finite dive timer: four errors */
    Until(1652); PutF(Controller() + 0xB84 + 8, 0);
    Until(1700); DiveStart();
    Until(1720); DiveOver();
    Until(1880); SetDepth(-0.5); DiveStart();
    Until(1890); DiveOver();
    Until(1891); Put32(w.mission + 8, 0);                      /* the mission ends while idle */
    Until(2011); Put32(w.mission + 8, 1); SetDepth(0.15);      /* a mission starts, in shallow water */
    Until(2200); DiveStart();
    Until(2210); Put32(w.mission + 8, 0);                      /* the mission ends during the dive */
    Until(2215); DiveOver();
    Until(2216);
    CHECK(Near(GetF(WaterOf() + 8), -0.4));
    Until(2306); Put32(w.mission + 8, 1);
    CHECK(vpm_running(fake_component(0)));
    Until(2450); Put32(w.players + 0x84, 5);                   /* an unsupported player count */
    Until(2651);
    CHECK_EQ(SeenAt("waiting_for_local_avatar", 1291), 1410);
    CHECK_EQ(SeenAt("dive_ended", 1411), 1440);
    CHECK_EQ(SeenAt("waiting_for_mission", 1891), 2010);
    CHECK_EQ(SeenAt("dive_ended", 2011), 2040);
    CHECK_EQ(SeenAt("waiting_for_mission", 1), 1);
    CHECK_EQ(SeenAt("dive_ended", 2), 151);                    /* the mission seen at the poll after 125 */
    CHECK_EQ(SeenAt("waiting_for_local_avatar_read", 1100), 1100);
    CHECK_EQ(SeenAt("dive_ended", 1101), 1190);
    CHECK_EQ(SeenAt("airborne_reference", 600), 600 + late);   /* after the update, or the next frame's tick */
    CHECK_EQ(SeenAt("landing", 450), 450 + late);
    CHECK_EQ(SeenAt("deep_water", 700), 760);
    CHECK_EQ(SeenAt("water_too_deep", 800), 830);
    CHECK_EQ(SeenAt("not_in_shallow_water", 850), 900);
    CHECK_EQ(SeenAt("water_surface_unavailable", 1001), 1010);
    CHECK_EQ(swd.protected, 5);
    CHECK_EQ(swd.startup_clears, 5);
    CHECK_EQ(swd.observed, 11);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Shallow Water Diving] error: Invalid movement or water value");
    CHECK_LOG("[Shallow Water Diving] disabled: stopped after 8 errors: Invalid movement or water value");
    CHECK_LOG("[Shallow Water Diving] stopped: ");
    CHECK(!Posting());
}

static void FrameScript(void) { PlayScript(1); }
static void FrameScriptWithoutTheHook(void) { PlayScript(0); }

/* ---- test_loader.lua: the depth slider ------------------------------------------------------------------------ */

static VpmOption* DepthOption(void)
{
    for (int i = 0; i < vpm_option_count(); i++)
        if (strcmp(vpm_option_def(vpm_option_at(i))->id, "max_water_depth") == 0) return vpm_option_at(i);
    return NULL;
}

static void DepthOption_(void)
{
    Fresh();
    VpmOption* option = DepthOption();
    CHECK(option != NULL);
    if (option == NULL) return;
    const VpmOptionDef* def = vpm_option_def(option);
    CHECK(vpm_option_owner(option) == fake_component(0));
    CHECK_EQ(def->kind, VPM_SLIDER);
    CHECK(strcmp(def->label, "Max Dive Water Depth") == 0);
    CHECK(def->description != NULL && strncmp(def->description, "Deepest water, measured up from your feet", 41) == 0);
    CHECK(def->min == 0.20 && def->max == 1.30 && def->step == 0.05 && def->value == 0.20);
    CHECK(vpm_option_value(option) == 0.20 && swd.max_water_depth == 0.20);
    /* Applied changes reach the dive check. */
    CHECK(vpm_option_apply(option, 0.9));
    CHECK(Near((float)swd.max_water_depth, 0.9));
    CHECK(vpm_option_apply(option, 5)); /* clamped to the slider's end, as Mod Options Menu's snap */
    CHECK(swd.max_water_depth == 1.30);
    /* A saved value applies at start. */
    fake_setup();
    HANDLE file = CreateFileW(L"vpm-test-settings.ini", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    const char text[] = "[options]\nshallow_water_diving.max_water_depth = 0.45\n";
    DWORD wrote;
    WriteFile(file, text, sizeof text - 1, &wrote, NULL);
    CloseHandle(file);
    MakeWorld(0);
    Started();
    CHECK(Near((float)swd.max_water_depth, 0.45));
    CHECK_LOG("max dive water depth 0.45; depth option registered");
    PutF(w.water + 24, (float)((double)GetF(w.position + 8) + 0.44));
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1);
}

/* ---- HellForge's own -------------------------------------------------------------------------------------------- */

/* HellForge replaces the entity owner's component tables with larger copies when a mod's entity owns records of them
 * (registry.c OwnRecord): the Drownable settings (table 309) are read through the pointer the game reads, so a copy is
 * followed. */
static void SettingsTableCopy(void)
{
    Fresh();
    uint8_t* copy = fake_heap(122 * 16 + 70 * 64);
    memcpy(copy, w.resource, 122 * 16 + 6 * 64);
    memset(w.resource, 0, 122 * 16 + 6 * 64);
    Put64(w.owner + 0xF12E20, Ptr(copy));
    CHECK_EQ(Apply(), 1);
    CHECK_EQ(swd.protected, 1);
    CHECK(Near(GetF(w.water + 8), -1.3));
}

/* The core stopping the component (a fault, or a refusal) puts a held lease back, checking the page again. */
static void StopRestores(void)
{
    Fresh();
    Frames(1);
    CHECK(StatusIs("airborne_reference") && swd.pending.valid);
    fake_counts_reset();
    vpm_core_stop(fake_component(0), "test");
    CHECK_EQ(fake_counts().read, 27); /* the identity guards twice (12 each), the offset, the stance, the read-back */
    CHECK(Near(GetF(w.water + 8), -0.4));
    CHECK(!swd.pending.valid);
    CHECK_EQ(swd.queries, 2);
    CHECK_LOG("[Shallow Water Diving] stopped: airborne_reference; observed=1 protected=1 restored=0 startup_clears=1 "
        "short_ends=0 table_moves=0 protection_queries=2");
    /* The post-update check stops with it: later frames read nothing. */
    CHECK(!Posting() && !vpm_ticking(fake_component(0)));
    fake_counts_reset();
    Frames(3);
    CHECK_EQ(fake_counts().read, 0);
    /* A refusal stops it at once and restores: a write that did not hold. */
    Fresh();
    ChangeAfter(w.water + 8, 0, TearOffset);
    Frames(1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Shallow Water Diving] disabled: reference_write_failed");
    CHECK(Near(GetF(w.water + 8), -0.4));
}

/* Errors are counted per burst: a few never stop it, and 3600 clean frames clear the count; the 8th of a burst stops it
 * (with the lease put back), with one log line per burst. Both checks of a frame count, as the Lua's guard counted its
 * step and its after-update check: an error that stays makes two per frame. */
static void ErrorsInABurst(void)
{
    Fresh();
    Dive(0);
    Frames(1);
    PutF(w.ctl + 0xB84 + 8, NAN);
    fake_counts_reset();
    Frames(2);
    CHECK_EQ(fake_counts().log, 1);
    CHECK_LOG("[Shallow Water Diving] error: Invalid movement or water value");
    PutF(w.ctl + 0xB84 + 8, 0);
    Frames(3600);
    CHECK(vpm_running(fake_component(0)) && StatusIs("dive_ended"));
    fake_log_clear();
    PutF(w.ctl + 0xB84 + 8, NAN);
    Frames(3);
    CHECK(vpm_running(fake_component(0)));
    CHECK_LOG("[Shallow Water Diving] error: Invalid movement or water value"); /* a new burst */
    Frames(1);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: stopped after 8 errors: Invalid movement or water value");
    /* With a lease held. */
    Fresh();
    Frames(1);
    CHECK(swd.pending.valid);
    Put32(w.players + 0x84, 5);
    Frames(8);
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("disabled: stopped after 8 errors: Unsupported player count");
    CHECK(Near(GetF(w.water + 8), -0.4));
}

/* ---- the check after the game's update (the core's post-update tick) ------------------------------------------- */

static void DiveInTheUpdate(void) { Dive(1); }
static void TimerNanInTheUpdate(void) { PutF(w.ctl + 0xB84 + 8, NAN); }

/* A dive the game's update starts (the avatar idle at the tick) gets its lease from the check after that update, in the
 * same frame: before the next frame's update, where swimming would consume the prone reference. The Lua saw it at the
 * next frame's first check at the earliest; the 1:1 port at the next frame's tick. */
static void DiveStartingInsideTheUpdate(void)
{
    Fresh();
    Dive(0);
    Frames(1);
    CHECK(StatusIs("dive_ended") && Posting());
    g_inside = DiveInTheUpdate;
    uint32_t reads = Frame();
    CHECK(strcmp(g_tickStatus, "dive_ended") == 0); /* the tick saw the avatar idle */
    CHECK(StatusIs("airborne_reference") && swd.pending.valid);
    CHECK(Near(GetF(w.water + 8), -1.3) && Near(GetF(w.water + 16), 0));
    CHECK(!NativeWaterUpdate()); /* the next update's water test no longer finds the launch submerged */
    CHECK_EQ(g_tickReads, 1);         /* the gate */
    CHECK_EQ(reads - g_tickReads, 76); /* the gate, then the full check that takes the lease */
    CHECK_EQ(swd.protected, 1);
    CHECK_EQ(swd.startup_clears, 1);
    PIN(24, 24);
    Dive(0);
    PIN(37, 1);
    CHECK(Near(GetF(w.water + 8), -0.4) && !swd.pending.valid);
}

/* Without the core's hook both checks run before the game's update: the dive it starts is seen at the next frame's
 * tick, as in the 1:1 port (still inside the 0.05 s the acquisition allows). */
static void DiveStartingInsideTheUpdateWithoutTheHook(void)
{
    FreshOn(0);
    Dive(0);
    Frames(1);
    CHECK(StatusIs("dive_ended") && Posting()); /* it runs, right after the tick */
    g_inside = DiveInTheUpdate;
    CHECK_EQ(Frame(), 1 + 1);
    CHECK(StatusIs("dive_ended") && !swd.pending.valid);
    CHECK_EQ(Frame(), 76 + 24); /* the tick takes the lease, the check after it holds it */
    CHECK(StatusIs("airborne_reference") && Near(GetF(w.water + 8), -1.3));
}

/* An error the check after the update finds counts as one of the burst, and its frame is not clean: the frame is
 * counted at its end, after both checks, as the Lua's guard counted it. Errors met only there stop the component at the
 * 8th. */
static void ErrorsAfterTheUpdate(void)
{
    Fresh();
    Dive(0);
    Frames(1);
    g_inside = TimerNanInTheUpdate;
    Frames(1);
    PutF(w.ctl + 0xB84 + 8, 0); /* gone before the next frame's tick */
    CHECK_EQ(fake_log_count("[Shallow Water Diving] error: "), 1);
    Frames(3599);
    /* The 3600th frame since the error ends in an error after the update: still the same burst (no new line). */
    g_inside = TimerNanInTheUpdate;
    Frames(1);
    PutF(w.ctl + 0xB84 + 8, 0);
    CHECK_EQ(fake_log_count("[Shallow Water Diving] error: "), 1);
    for (int i = 3; i <= 8; i++)
    {
        CHECK(vpm_running(fake_component(0)) && StatusIs("dive_ended"));
        g_inside = TimerNanInTheUpdate;
        Frames(1);
        PutF(w.ctl + 0xB84 + 8, 0);
    }
    CHECK(!vpm_running(fake_component(0)) && !Posting());
    CHECK_LOG("[Shallow Water Diving] disabled: stopped after 8 errors: Invalid movement or water value");
    CHECK_EQ(fake_log_count("[Shallow Water Diving] error: "), 1);
}

/* The water records' page made read-only inside the update, after the first dive's page check was kept: the lease's
 * store in the check after the update faults. The core's guard stops the component there; its stop finds the record as
 * it was (the store never happened) and leaves it; the game goes on and nothing of the component runs again. */
static void PageReadOnly(void)
{
    Dive(1);
    DWORD old;
    VirtualProtect(w.waters, 4096, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the record table read-only */
}

static void FaultAfterTheUpdate(void)
{
    Fresh();
    Frames(1);
    Dive(0);
    Frames(1);
    CHECK(StatusIs("dive_ended") && swd.write_check.valid && swd.queries == 1);
    PutF(w.water + 16, 0.011f);
    g_inside = PageReadOnly;
    Frames(1);
    DWORD old;
    VirtualProtect(w.waters, 4096, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK(!vpm_running(fake_component(0)) && !Posting() && !vpm_ticking(fake_component(0)));
    CHECK_LOG("[Shallow Water Diving] disabled: ");
    CHECK_LOG("[Shallow Water Diving] stopped: ");
    CHECK(Near(GetF(w.water + 8), -0.4) && !swd.pending.valid);
    CHECK_EQ(swd.queries, 1); /* the kept check: no page check before the store */
    fake_counts_reset();
    Frames(3);
    CHECK_EQ(fake_counts().read, 0);
}

/* ---- a refused post-update tick: one check per frame for the session ----------------------------------------------- */

static const char kRefused[] =
    "[Shallow Water Diving] no check after the game's update (its tick was refused): one check per frame";
static void TimerNan(void) { PutF(w.ctl + 0xB84 + 8, NAN); }
static void TimerFinite(void) { PutF(w.ctl + 0xB84 + 8, 0); }
/* One frame whose check meets a non-finite dive timer (an error), the timer finite again before the next one. */
static void ErrorFrame(void) { TimerNan(); Frames(1); TimerFinite(); }

/* Refused at the first start (Reset's dive, at once): one log line, and from then on the 1:1 port's one check per frame,
 * also once the refusal is lifted. Idle frames make the tick's reads alone; a dive the update starts waits for the
 * next frame's tick. */
static void RefusedPostTick(void)
{
    Fresh();
    fake_refuse_ticks(0, 1);
    fake_counts_reset();
    Frames(1);
    CHECK_EQ(fake_counts().read, 75); /* the lease, and no check after the update */
    CHECK(StatusIs("airborne_reference") && !Posting());
    CHECK_EQ(fake_log_count(kRefused), 1);
    fake_refuse_ticks(0, 0);
    PIN(24, 0);
    Dive(0);
    PIN(37, 0);
    for (int i = 0; i < 5; i++) PIN(1, 0); /* idle in a mission: the gate once */
    PutF(w.water + 16, 0.011f);
    g_inside = DiveInTheUpdate;
    PIN(1, 0);
    CHECK(StatusIs("dive_ended"));
    PIN(76, 0);
    CHECK(StatusIs("airborne_reference") && !Posting());
    CHECK_EQ(fake_log_count(kRefused), 1);
}

/* On that branch a frame is counted where its one check runs: an error, 3599 clean frames and another error are one
 * burst; 3600 clean frames end it, and the 8th error of a burst stops the component. */
static void RefusedPostTickCountsErrors(void)
{
    Fresh();
    Dive(0);
    fake_refuse_ticks(0, 1);
    Frames(1);
    fake_refuse_ticks(0, 0);
    CHECK(StatusIs("dive_ended") && !Posting());
    ErrorFrame();
    Frames(3599);
    ErrorFrame();
    CHECK_EQ(fake_log_count("[Shallow Water Diving] error: "), 1);
    Frames(3600);
    ErrorFrame();
    CHECK_EQ(fake_log_count("[Shallow Water Diving] error: "), 2); /* a new burst */
    for (int i = 2; i <= 7; i++) ErrorFrame();
    CHECK(vpm_running(fake_component(0)) && !Posting());
    ErrorFrame();
    CHECK(!vpm_running(fake_component(0)));
    CHECK_LOG("[Shallow Water Diving] disabled: stopped after 8 errors: Invalid movement or water value");
}

/* A start refused later, after an earlier one worked and was stopped (the mission ended): logged once, one check per
 * frame from then on. */
static void RefusedPostTickLater(void)
{
    Fresh();
    Dive(0);
    Frames(1);
    PIN(1, 1);
    Put32(w.mission + 8, 0);
    for (int i = 0; i <= 120 && Posting(); i++) Frames(1);
    CHECK(StatusIs("waiting_for_mission") && !Posting());
    fake_refuse_ticks(0, 1);
    Put32(w.mission + 8, 1);
    for (int i = 0; i <= 30 && !StatusIs("dive_ended"); i++) Frames(1);
    CHECK(StatusIs("dive_ended") && !Posting());
    CHECK_EQ(fake_log_count(kRefused), 1);
    fake_refuse_ticks(0, 0);
    PIN(1, 0);
    Dive(1);
    PIN(76, 0);
    CHECK(StatusIs("airborne_reference") && !Posting());
    CHECK_EQ(fake_log_count(kRefused), 1);
}

/* ---- game.dll's decoding --------------------------------------------------------------------------------------------
 * No code bytes are checked, and the game.dll read-only constants are read on the first dive of a session in a mission
 * only: wrong (still encoded) at HF_EVENT_GAME_LOADED and for more than the core's 60 s wait, outside a mission and idle
 * in one, they stop nothing; right by the first dive, it is assisted. */
static void Constants(int decoded)
{
    if (!decoded)
    {
        memset(w.game + 0x23C6CCC, 0xCC, 4);
        memset(w.game + 0x23C69F8, 0xCC, 4);
        memset(w.constants, 0xCC, 0xA0);
        return;
    }
    memset(w.constants, 0, 0xA0);
    PutF(w.game + 0x23C6CCC, 0.9f);
    PutF(w.game + 0x23C69F8, 0.4f);
    PutF(w.constants + 0x90, 2);
    PutF(w.constants + 0x80, 1.5f);
}

static void ConstantsWaitForTheFirstDive(void)
{
    MakeWorld(0);
    Put32(w.mission + 8, 0);
    Constants(0);
    Started();
    Frames(1800);
    Put32(w.mission + 8, 1);
    Dive(0);
    Frames(1900);
    CHECK(vpm_running(fake_component(0)) && StatusIs("dive_ended"));
    CHECK_EQ(fake_log_count("[Shallow Water Diving] error: "), 0);
    Constants(1);
    Dive(1);
    Frames(1);
    CHECK(StatusIs("airborne_reference") && swd.constants_verified && swd.protected == 1);
    CHECK_EQ(fake_counts().code_matches + fake_counts().find_pattern, 0);
}

/* The session's counters at each mission's end (the Lua wrote them to its log file). */
static void MissionEndCounters(void)
{
    Fresh();
    Frames(1);
    Dive(0);
    Frames(1);
    HfStateEvent end;
    memset(&end, 0, sizeof end);
    end.info.size = sizeof end;
    end.info.kind = HF_ON_MISSION_END;
    fake_counts_reset();
    fake_emit(&end.info);
    CHECK_EQ(fake_counts().read, 0);
    /* The dive timer never ran here: a dive that ends within 0.02 s counts as a short end. */
    CHECK_LOG("[Shallow Water Diving] mission end: dive_ended; observed=1 protected=1 restored=1 startup_clears=1 "
        "short_ends=1 table_moves=0 protection_queries=1");
}

int main(void)
{
    RUN(MissionModes);
    RUN(DepthLimit);
    RUN(RaisedDepthLimit);
    RUN(StartupDebtAndLandings);
    RUN(OrdinaryStatesNeverLease);
    RUN(EngineTransitionsAndOwnership);
    RUN(CoherenceGuards);
    RUN(EngineOffsetAndWriteFailures);
    RUN(WaitsRecover);
    RUN(InvalidDataIsAnError);
    RUN(TimeoutConstant);
    RUN(IdleGate);
    RUN(HashLookups);
    RUN(CheckBudget);
    RUN(PageChecksFollowTheTable);
    RUN(UnassistedDiveBudget);
    RUN(FrameBudget);
    RUN(FrameBudgetWithoutTheHook);
    RUN(FrameScript);
    RUN(FrameScriptWithoutTheHook);
    RUN(DepthOption_);
    RUN(SettingsTableCopy);
    RUN(StopRestores);
    RUN(ErrorsInABurst);
    RUN(DiveStartingInsideTheUpdate);
    RUN(DiveStartingInsideTheUpdateWithoutTheHook);
    RUN(ErrorsAfterTheUpdate);
    RUN(FaultAfterTheUpdate);
    RUN(RefusedPostTick);
    RUN(RefusedPostTickCountsErrors);
    RUN(RefusedPostTickLater);
    RUN(ConstantsWaitForTheFirstDive);
    RUN(MissionEndCounters);
    TEST_END();
}
