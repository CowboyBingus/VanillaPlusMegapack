/* Mod Bindings Menu: the Lua tests' scenarios (components/ModBindingsMenu/tests: test_keyboard_defaults, test_api,
 * test_sweep, test_mods_tab, test_extended, test_extended_store, test_capture, test_panel) on the fake game, with Ship
 * Station Hotkeys' six bindings registered through the pack's registry by a stand-in component. The game's list
 * functions are stand-ins reached through jumps written at their RVAs in the fake game.dll, so the component really calls
 * game.dll + RVA. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "harness/test.h"
#include "components.h"
#include "components/mod_bindings_menu/mbm.h"

TEST_GLOBALS;

#define OWNER_SIZE 878200u
#define MAP_BYTES (256u * 328u)
#define SCREEN_SIZE (338344u + 2411940u)
#define LISTING 338344u
#define BAR 1248u
#define KEYBOARD 3u
#define MOUSE 4u
#define XBOX 2u
#define DUALSHOCK 1u
#define HOLD 2u
#define LONG_PRESS 3u
#define REPEAT 8u
#define DT (1.0f / 60)

typedef struct World { uint8_t *owner, *live, *defaults, *ui, *menu, *screen, *mission; } World;
static World w;

static void Put32(void* at, uint32_t v) { memcpy(at, &v, 4); }
static void Put64(void* at, uint64_t v) { memcpy(at, &v, 8); }
static void PutF(void* at, float v) { memcpy(at, &v, 4); }
static uint32_t Get32(const void* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t Get64(const void* at) { uint64_t v; memcpy(&v, at, 8); return v; }
static uint8_t* Game(uint32_t rva) { return (uint8_t*)fake_game() + rva; }
static uint64_t Address(const void* p) { return (uint64_t)(uintptr_t)p; }

static void PutHex(uint8_t* at, const char* hex)
{
    for (; hex[0] != 0 && hex[1] != 0; hex += hex[2] == ' ' ? 3 : 2)
    {
        char pair[3] = {hex[0], hex[1], 0};
        *at++ = (uint8_t)strtoul(pair, NULL, 16);
    }
}

/* ---- the simulated game ---------------------------------------------------------------------------------------- */

typedef struct Prologue { uint32_t rva; const char* hex; } Prologue;
static const Prologue kCode[4] = {
    {MBM_BUILD_ROWS_RVA, "48 8B C4 53 41 56 48 81 EC D8 00 00 00"},
    {MBM_SET_TAB_LABELS_RVA, "48 89 54 24 10 53 56 48 83 EC 68 0F 29 74 24 30"},
    {MBM_LIST_RESET_RVA, "40 53 48 83 EC 20 48 8B D9 85 D2 74 30 83 EA 01"},
    {MBM_INPUT_CONSUME_RVA, "40 53 48 83 EC 20 4C 8B D1 4C 8B CA 48 8B CA E8 DC 7C 28 FF"},
};

static void PutCode(void)
{
    for (int i = 0; i < 4; i++) PutHex(Game(kCode[i].rva), kCode[i].hex);
}

static uint8_t* Record(uint8_t* map, int index) { return map + (10u + 7u * (uint32_t)index) * 328u; }
static uint8_t* Code(uint8_t* map, uint32_t code) { return Record(map, mbm_code_index(code)); }
static uint8_t* State(uint32_t group, uint32_t action) { return w.owner + 808u + 32u * (97u * group + action); }

static void Page(int open)
{
    Put32(w.ui + 0x429C + 20, 1);
    Put32(w.ui + 0x429C, open ? 26u : 1u);
}

/* The game image (code, tab labels, action labels, pointers), the input owner with both maps, the UI, the menu, the
 * binding page's screen and the mission record (as on the ship). */
static void MakeWorld(void)
{
    memset(&w, 0, sizeof w);
    w.owner = fake_heap(OWNER_SIZE);
    w.live = fake_heap(MAP_BYTES);
    w.defaults = fake_heap(MAP_BYTES);
    w.ui = fake_heap(0x429C + 24);
    w.menu = fake_heap(4096);
    w.screen = fake_heap(SCREEN_SIZE);
    w.mission = fake_heap(0x44);
    PutCode();
    PutHex(Game(MBM_TAB_LABELS_RVA), "51 F4 70 8D 60 5C 5E F1 EB 7F 84 00");
    Put64(Game(MBM_INPUT_OWNER_RVA), Address(w.owner));
    Put64(w.owner + MBM_BINDING_MAP, Address(w.live));
    Put32(w.owner + MBM_BINDING_MAP + 8, 256);
    Put64(w.owner + MBM_DEFAULTS_MAP, Address(w.defaults));
    Put32(w.owner + MBM_DEFAULTS_MAP + 8, 256);
    Put64(Game(MBM_UI_STATE_RVA), Address(w.ui));
    Put64(Game(MBM_MENU_SYSTEM_RVA), Address(w.menu));
    Put64(w.menu + 208, Address(w.screen));
    Put64(Game(MBM_MISSION_MODE_RVA), Address(w.mission));
    Put32(w.mission + 0x40, 2);
    for (int i = 0; i < MBM_ACTIONS; i++)
    {
        const MbmDormant* d = &mbm_dormant[i];
        Put32(Game(MBM_ACTION_LABELS_RVA + (d->group * 97u + d->action) * 4u), d->label);
        Put32(Record(w.live, i), mbm_code_at(i));
        Put32(Record(w.defaults, i), mbm_code_at(i));
    }
    Page(0);
}

/* A 20-byte mapping: flags (device, Button, any device slot, trigger, key), key, the trigger again. */
typedef struct Mapping { uint32_t words[5]; } Mapping;
static Mapping Map(uint32_t device, uint32_t key, uint32_t trigger, uint32_t padding)
{
    Mapping m = {{device + 0x40u + 0xFF00u + trigger * 0x10000u + key * 0x100000u, key | (padding << 16), trigger, 0, 0}};
    return m;
}

static void SetList(uint8_t* record, const Mapping* list, int count)
{
    Put32(record + 4, (uint32_t)count);
    memset(record + 8, 0, 320);
    memcpy(record + 8, list, sizeof *list * (size_t)count);
}

static int Same(const uint8_t* record, const Mapping* list, int count)
{
    return Get32(record + 4) == (uint32_t)count && memcmp(record + 8, list, sizeof *list * (size_t)count) == 0;
}

/* ---- the game's list functions: stand-ins reached by a jump at their RVA --------------------------------------- */

static int g_builds, g_resets, g_labelCount, g_consumed[16], g_consumedCount;
static uint32_t g_labels[8];

static void StandInSetTabLabels(void* bar, const uint32_t* labels, int count)
{
    g_labelCount = count;
    memcpy(g_labels, labels, sizeof *labels * (size_t)count);
    Put32((uint8_t*)bar + 57448, (uint32_t)count);
    for (int i = 0; i < 8; i++) Put32((uint8_t*)bar + 11004 + 3400 * i, i < count ? 1u : 0u);
}

static void StandInBuildRows(void* listing, const uint32_t* rows)
{
    uint8_t* l = listing;
    uint32_t count = Get32(l + 2411928);
    g_builds++;
    Put32(l + 2411916, count);
    for (uint32_t i = 0; i < count; i++)
    {
        uint8_t* row = l + 7856 + 24784 * i;
        uint32_t header = rows[3 * i + 2];
        Put32(row + 24752, header != 0 ? 4u : 1u);
        Put32(row + 4264 + 272, header);
        Put32(row + 24760, header != 0 ? 0xFFFFFFFFu : rows[3 * i] * 65536u + rows[3 * i + 1]);
    }
}

static void StandInResetList(void* listing, int tab) { g_resets++; }

static void StandInConsume(void* owner, uint64_t action, float seconds)
{
    uint32_t index = (uint32_t)(action >> 32);
    if (g_consumedCount < 16) g_consumed[g_consumedCount++] = (int)index;
    ((uint8_t*)owner)[808 + 32 * index] = 0;
}

/* jmp [rip + 0] to the stand-in, written over the checked prologue once the build check passed. */
static void Jump(uint32_t rva, void* target)
{
    uint8_t* at = Game(rva);
    DWORD old;
    VirtualProtect(at, 14, PAGE_EXECUTE_READWRITE, &old); /* lint-ok: C1,C3 the test makes its stand-in jump executable */
    PutHex(at, "FF 25 00 00 00 00");
    Put64(at + 6, Address(target));
}

static void InstallStandIns(void)
{
    Jump(MBM_BUILD_ROWS_RVA, (void*)StandInBuildRows);
    Jump(MBM_SET_TAB_LABELS_RVA, (void*)StandInSetTabLabels);
    Jump(MBM_LIST_RESET_RVA, (void*)StandInResetList);
    Jump(MBM_INPUT_CONSUME_RVA, (void*)StandInConsume);
}

/* ---- the binding user (Ship Station Hotkeys' registrations) and the sessions ---------------------------------- */

static VpmBindingDef g_defs[48];
static VpmBinding* g_bindings[48];
static char g_names[48][2][40];
static int g_defCount;

static int UserStart(VpmComponent* self)
{
    for (int i = 0; i < g_defCount; i++) g_bindings[i] = vpm_binding(self, &g_defs[i]);
    return 0;
}

static const VpmComponentDef kUser = {"ship_station_hotkeys", "Ship Station Hotkeys", "1.9.1", 0, UserStart, NULL};
static const VpmComponentDef* const kDefs[] = {&kUser, &vpm_component_mod_bindings_menu};

static void Def(const char* id, const char* label, const char* category, uint32_t slot)
{
    int i = g_defCount++;
    snprintf(g_names[i][0], 40, "%s", id);
    snprintf(g_names[i][1], 40, "%s", label);
    g_defs[i] = (VpmBindingDef){g_names[i][0], g_names[i][1], category, slot, 0};
}

static void Ship(void)
{
    static const char* const ids[6] = {"cowboybingus.galactic_menu", "cowboybingus.armory", "cowboybingus.control_center",
        "cowboybingus.ship_management", "cowboybingus.stratagem_hero", "cowboybingus.hellpod"};
    static const char* const labels[6] = {"Galactic Map", "Armory", "Control Center", "Ship Management", "Stratagem Hero",
        "Hellpod Deployment"};
    static const uint32_t slots[6] = {1, 3, 4, 5, 6, 7};
    for (int i = 0; i < 6; i++) Def(ids[i], labels[i], NULL, slots[i]);
}

static MbmRecord* Rec(int i) { return (MbmRecord*)vpm_binding_data(g_bindings[i]); }
static VpmComponent* Menu(void) { return fake_component(1); }

/* A game session on the same game memory: the settings saved, the core and components started again, its first
 * frame (the build check). */
static void Session(void)
{
    vpm_settings_flush();
    vpm_core_reset();
    PutCode();
    fake_start(kDefs, 2);
    fake_frames(1, DT);
}

static void Start(void)
{
    MakeWorld();
    fake_start(kDefs, 2);
}

/* ---- the fixed slots' lists (build 25480438, read live: the game's stock lists and v2.3's replacement) --------- */

static const char* const kFixedHex[MBM_SLOTS][2] = {
    {"41ff60000000000000000000000000000000000042ffc0001000000000000000000000000000000043ffd0003e00000000000000000000000000000044ff000020000000000000000000000000000000",
     "41ff60000000000000000000000000000000000042ffc0001000000000000000000000000000000043ff90003a00000000000000000000000000000044ff000020000000000000000000000000000000"},
    {"", ""},
    {"41ff00000a0000000000000000000000cdcc4c3e42ffa0001b0000000000000000000000cdcc4c3e43ff8006990000000000000000000000cdcc4c3e",
     "41ff00000a0000000000000000000000cdcc4c3e42ffa0001b0000000000000000000000cdcc4c3e43ff0007a10000000000000000000000cdcc4c3e"},
    {"41ff8800040000000800000000000000cdcc4c3e42ff0800140000000800000000000000cdcc4c3e43ff7806980000000800000000000000cdcc4c3e",
     "41ff8800040000000800000000000000cdcc4c3e42ff0800140000000800000000000000cdcc4c3e43ff4007a50000000000000000000000cdcc4c3e"},
    {"41ffd800090000000800000000000000cdcc4c3e42fff800130000000800000000000000cdcc4c3e43ff98069a0000000800000000000000cdcc4c3e",
     "41ffd800090000000800000000000000cdcc4c3e42fff800130000000800000000000000cdcc4c3e43ff5007a60000000000000000000000cdcc4c3e"},
    {"41ff7800020000000800000000000000cdcc4c3e42ffe800120000000800000000000000cdcc4c3e43ff0006910000000000000000000000cdcc4c3e",
     "41ff7800020000000800000000000000cdcc4c3e42ffe800120000000800000000000000cdcc4c3e43ff6007a70000000000000000000000cdcc4c3e"},
    {"41ff5800010000000800000000000000cdcc4c3e42ffd800110000000800000000000000cdcc4c3e43ff6806970000000800000000000000cdcc4c3e",
     "41ff5800010000000800000000000000cdcc4c3e42ffd800110000000800000000000000cdcc4c3e43ff7007a80000000000000000000000cdcc4c3e"},
};

/* A record's list from hex (40 digits per mapping). */
static void SetHex(uint8_t* record, const char* hex)
{
    uint32_t count = (uint32_t)strlen(hex) / 40u;
    Put32(record + 4, count);
    memset(record + 8, 0, 320);
    PutHex(record + 8, hex);
}

static int SameHex(const uint8_t* record, const char* hex)
{
    uint8_t expected[328];
    memcpy(expected, record, 8);
    SetHex(expected, hex);
    return memcmp(expected + 4, record + 4, 4 + strlen(hex) / 2) == 0;
}

static void StockLists(int replaced)
{
    for (int i = 0; i < MBM_SLOTS; i++)
    {
        if (i == 1) continue;
        SetHex(Record(w.live, i), kFixedHex[i][replaced]);
        SetHex(Record(w.defaults, i), kFixedHex[i][replaced]);
    }
}

/* ---- 1. the build check and the keyboard defaults (test_keyboard_defaults.lua, test_api.lua) ------------------- */

static void AddsTheKeyboardDefaultsOnce(void)
{
    Start();
    StockLists(0);
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_LOG("[Mod Bindings Menu] Native binding layout verified for current game build.");
    CHECK_LOG("Mod input actions loaded; native keyboard and controller bindings ready.");
    CHECK_LOG("Added Mod Bindings Menu's keyboard defaults to 12 binding records.");
    CHECK_LOG("Slot 1 native mappings: 41FF6000");
    /* Once per session: the live map indexed (9), the defaults map indexed and each fixed slot's two records (21), the
     * slot 1 probe (2), the screen stack (1). The Lua: 40. */
    CHECK_EQ(fake_counts().read, 33);
    CHECK_EQ(fake_counts().code_matches, 4);
    for (int i = 0; i < MBM_SLOTS; i++)
    {
        if (i == 1) continue;
        CHECK(SameHex(Record(w.live, i), kFixedHex[i][1]));
        CHECK(SameHex(Record(w.defaults, i), kFixedHex[i][1]));
    }
    CHECK_EQ(Get32(Record(w.live, 7) + 4), 0);
    fake_counts_reset();
    fake_frames(3, DT);
    CHECK_EQ(fake_counts().read, 3); /* idle: the screen stack only (Lua: 1) */
    CHECK_EQ(fake_counts().log, 0);
    /* An old replacement already deployed: nothing written. */
    fake_setup();
    Start();
    StockLists(1);
    fake_frames(1, DT);
    CHECK_NO_LOG("keyboard defaults to");
}

static void RefusesAnUnreviewedLayout(void)
{
    static const char* const why[] = {"disabled: binding list builder changed", "disabled: binding tab labels changed",
        "disabled: input action label table changed at 10:1"};
    for (int c = 0; c < 3; c++)
    {
        fake_setup();
        Start();
        StockLists(0);
        if (c == 0) Game(MBM_BUILD_ROWS_RVA)[3] = 0x90;
        if (c == 1) Game(MBM_TAB_LABELS_RVA)[0] = 0;
        if (c == 2) Put32(Game(MBM_ACTION_LABELS_RVA + (10u * 97u + 1u) * 4u), 1);
        fake_counts_reset();
        fake_frames(5, DT);
        CHECK_LOG(why[c]);
        CHECK_LOG("inactive on this game build: it changes nothing in the game");
        CHECK(!vpm_running(Menu()));
        CHECK_EQ(fake_counts().read, 0);
        CHECK(SameHex(Record(w.live, 0), kFixedHex[0][0]));
    }
}

/* ---- 2. registration and reservations (test_api.lua) ----------------------------------------------------------- */

static void RegistersFixedSlotsAndAutomaticActions(void)
{
    Ship();
    Def("external", "Toggle HUD", "Arc Tools", 2);
    Def("other", "Other", "Arc Tools", 2);
    Def("auto_a", "Auto A", NULL, 0);
    Def("bad", "Bad", NULL, 8);
    Def("tab\tid", "Bad", NULL, 0);
    Start();
    CHECK_LOG("Registered ship_station_hotkeys.cowboybingus.galactic_menu on native action 12:1 (slot 1) under SHIP STATION HOTKEYS.");
    CHECK_LOG("Registered ship_station_hotkeys.cowboybingus.hellpod on native action 10:9 (slot 7) under SHIP STATION HOTKEYS.");
    CHECK_LOG("Registered ship_station_hotkeys.external on native action 12:0 (slot 2) under ARC TOOLS.");
    CHECK_LOG("Registered ship_station_hotkeys.other on native action 10:0 under ARC TOOLS.");
    CHECK_LOG("Registered ship_station_hotkeys.auto_a on native action 10:2 under SHIP STATION HOTKEYS.");
    CHECK_LOG("Cannot register ship_station_hotkeys.bad: invalid binding registration.");
    CHECK(Rec(9) == NULL && Rec(10) == NULL);
    CHECK_EQ(vpm_binding_down(g_bindings[0]), -1); /* before native input is ready */
    CHECK_EQ(vpm_binding_down(g_bindings[9]), -1); /* refused: the caller's fixed key */
    CHECK(strcmp(Rec(2)->text, "CONTROL CENTER") == 0 && Rec(6)->slot == 2 && Rec(7)->slot == 0);
    fake_frames(1, DT);
    vpm_settings_flush();
    CHECK(strcmp(vpm_setting(MBM_SECTION, "session"), "1") == 0);
    CHECK(strcmp(vpm_setting(MBM_SECTION, "auto.10:0"), "1 ship_station_hotkeys.other") == 0);
    CHECK(strcmp(vpm_setting(MBM_SECTION, "slot.2"), "1 ship_station_hotkeys.external") == 0);
}

/* Slot 2's owner keeps it in any load order; an automatic reservation stays its holder's. */
static void KeepsReservationsAcrossSessions(void)
{
    Def("legacy.a", "A", NULL, 2);
    Def("legacy.b", "B", NULL, 2);
    Start();
    fake_frames(1, DT);
    CHECK_EQ(Rec(0)->code, 12u * 65536u);
    CHECK_EQ(Rec(1)->code, 10u * 65536u);
    g_defs[0] = (VpmBindingDef){"legacy.b", "B", NULL, 2, 0};
    g_defs[1] = (VpmBindingDef){"legacy.a", "A", NULL, 2, 0};
    Session();
    CHECK_EQ(Rec(0)->code, 10u * 65536u); /* b keeps its automatic action */
    CHECK_EQ(Rec(1)->code, 12u * 65536u); /* a keeps slot 2 */
    CHECK_EQ(mbm_session(), 2);
}

/* 29 automatic actions; the absent binding's reservation lasts 30 counted sessions, then a new id gets its action and
 * the old keys are cleared. Beyond the pool a registration is extended. */
static void ReservationsExpireAfterThirtySessions(void)
{
    char ids[30][16];
    for (int i = 0; i < 29; i++)
    {
        snprintf(ids[i], sizeof ids[i], "repro_%d", i + 1);
        Def(ids[i], "Repro", NULL, 0);
    }
    Start();
    fake_frames(1, DT);
    uint32_t held = Rec(28)->code;
    CHECK_EQ(held, mbm_code_at(35));
    Def("replacement", "Replacement", NULL, 0);
    vpm_binding(fake_component(0), &g_defs[29]);
    CHECK_LOG("Registered ship_station_hotkeys.replacement as an extended binding (every native action is held) under SHIP STATION HOTKEYS.");
    g_defs[28] = (VpmBindingDef){"heir", "Heir", NULL, 0, 0}; /* repro_29 is gone from now on */
    g_defCount = 28;
    for (int session = 2; session <= 31; session++) Session();
    CHECK_EQ(mbm_session(), 31);
    g_defCount = 29;
    fake_log_clear();
    SetList(Code(w.live, held), (Mapping[]){Map(KEYBOARD, 30, 0, 0)}, 1);
    Session();
    CHECK_EQ(Rec(28)->code, held);
    CHECK_LOG("Native action 9:11 goes to ship_station_hotkeys.heir: ship_station_hotkeys.repro_29 has not registered for 30 sessions; its keys are cleared.");
    CHECK_EQ(Get32(Code(w.live, held) + 4), 0); /* the handed-over action is cleared entirely */
    fake_frames(1, DT);
    vpm_settings_flush();
    CHECK(strncmp(vpm_setting(MBM_SECTION, "action.9:11"), "cleared 32 found", 16) == 0);
}

/* ---- 3. the sweep (test_sweep.lua) ----------------------------------------------------------------------------- */

static Mapping g_def0[4], g_def2[3], g_def3[1];

/* Slot 2 and the automatic actions 10:0 (auto.1), 10:2 (auto.2) and 10:3 (auto.3) with developer defaults. */
static void SweepWorld(void)
{
    g_def0[0] = Map(DUALSHOCK, 12, LONG_PRESS, 0); g_def0[1] = Map(XBOX, 12, LONG_PRESS, 0);
    g_def0[2] = Map(KEYBOARD, 77, 0, 0); g_def0[3] = Map(KEYBOARD, 1, LONG_PRESS, 0);
    g_def2[0] = Map(DUALSHOCK, 4, REPEAT, 0); g_def2[1] = Map(XBOX, 4, REPEAT, 0); g_def2[2] = Map(KEYBOARD, 80, REPEAT, 0);
    g_def3[0] = Map(KEYBOARD, 79, 0, 0);
    uint8_t* maps[2] = {w.live, w.defaults};
    for (int m = 0; m < 2; m++)
    {
        SetList(Code(maps[m], 12u * 65536u), g_def0, 4);
        SetList(Code(maps[m], 10u * 65536u + 2u), g_def2, 3);
        SetList(Code(maps[m], 10u * 65536u + 3u), g_def3, 1);
        SetList(Code(maps[m], 9u * 65536u), g_def3, 1);
    }
    Def("slot2", "Slot 2", NULL, 2);
    for (int i = 1; i <= 3; i++) Def(i == 1 ? "auto.1" : i == 2 ? "auto.2" : "auto.3", "Auto", NULL, 0);
}

static void SweepClearsInheritedDefaultsOnce(void)
{
    SweepWorld();
    Start();
    fake_frames(2, DT);
    CHECK_LOG("Removed 8 inherited developer mappings.");
    CHECK_EQ(Get32(Code(w.live, 12u * 65536u) + 4), 0);
    CHECK_EQ(Get32(Code(w.live, 10u * 65536u + 2u) + 4), 0);
    CHECK_EQ(Get32(Code(w.defaults, 10u * 65536u + 3u) + 4), 0);
    CHECK(Same(Code(w.live, 9u * 65536u), g_def3, 1)); /* no binding uses it: untouched */
    vpm_settings_flush();
    CHECK(strncmp(vpm_setting(MBM_SECTION, "action.10:2"), "cleared 1 found ", 16) == 0);
    CHECK(vpm_setting(MBM_SECTION, "action.9:0") == NULL);
    /* The player's mappings stay, also one equal to a developer default; RepeatInterval becomes Press. */
    Mapping mine[2] = {Map(KEYBOARD, 44, 0, 0), Map(XBOX, 4, REPEAT, 0)}, pressed = Map(XBOX, 4, 0, 0);
    SetList(Code(w.live, 10u * 65536u + 2u), mine, 2);
    SetList(Code(w.live, 12u * 65536u), &g_def0[2], 1);
    fake_frames(1, 2.0f);
    CHECK(Same(Code(w.live, 12u * 65536u), &g_def0[2], 1));
    CHECK_EQ(Get32(Code(w.live, 10u * 65536u + 2u) + 4), 2);
    CHECK(memcmp(Code(w.live, 10u * 65536u + 2u) + 8, &mine[0], 20) == 0);
    CHECK(memcmp(Code(w.live, 10u * 65536u + 2u) + 28, &pressed, 20) == 0);
    /* A sweep reads each registered action's defaults and live records, plus the screen stack (Lua: 14 for six). */
    fake_counts_reset();
    fake_frames(1, 2.0f);
    CHECK_EQ(fake_counts().read, 9);
    /* A restored list off the page is cleaned again; down sweeps first and reads up. */
    SetList(Code(w.live, 10u * 65536u + 3u), g_def3, 1);
    CHECK_EQ(vpm_binding_down(g_bindings[3]), 0);
    CHECK_EQ(Get32(Code(w.live, 10u * 65536u + 3u) + 4), 0);
    *State(10, 3) = 1;
    CHECK_EQ(vpm_binding_down(g_bindings[3]), 1);
}

/* After a binding page, one action set to a single mapping equal to its only default is the player's choice. */
static void KeepsASingleCaptureAfterAPage(void)
{
    SweepWorld();
    Start();
    fake_frames(1, DT);
    InstallStandIns();
    Page(1);
    fake_frames(1, DT);
    SetList(Code(w.live, 10u * 65536u + 3u), g_def3, 1);
    Page(0);
    fake_frames(1, DT);
    CHECK(Same(Code(w.live, 10u * 65536u + 3u), g_def3, 1));
    CHECK_LOG("Kept the single mapping chosen for ship_station_hotkeys.auto.3 on a binding page, although it equals a developer default.");
    fake_frames(1, DT);
    /* The next session (the game parses its defaults again): the list the sweep left is remembered; returning
     * defaults elsewhere are cleaned again. */
    SetList(Code(w.live, 10u * 65536u + 2u), g_def2, 3);
    SetList(Code(w.defaults, 10u * 65536u + 2u), g_def2, 3);
    SetList(Code(w.defaults, 10u * 65536u + 3u), g_def3, 1);
    Session();
    CHECK(Same(Code(w.live, 10u * 65536u + 3u), g_def3, 1));
    CHECK_EQ(Get32(Code(w.live, 10u * 65536u + 2u) + 4), 0);
}

/* ---- 4. down, the idle gate and the MODS tab (test_mods_tab.lua) --------------------------------------------- */

static void DownReadsTheActionState(void)
{
    Ship();
    Start();
    StockLists(0);
    fake_frames(3, DT);
    CHECK_EQ(vpm_binding_down(g_bindings[0]), 0);
    *State(12, 1) = 1;
    fake_counts_reset();
    CHECK_EQ(vpm_binding_down(g_bindings[0]), 1);
    CHECK_EQ(vpm_binding_down(g_bindings[1]), 0);
    CHECK_EQ(fake_counts().read, 4); /* the record header and the state byte each (Lua: 3) */
    /* A config re-parse restores the stock list: the sweep runs first, the frame reads up. */
    SetHex(Record(w.live, 0), kFixedHex[0][0]);
    CHECK_EQ(vpm_binding_down(g_bindings[0]), 0);
    CHECK_LOG("Added the keyboard default of 12:1 again: the game restored its stock list (live).");
    CHECK(SameHex(Record(w.live, 0), "43ff90003a000000000000000000000000000000"));
    CHECK_EQ(vpm_binding_down(g_bindings[0]), 1);
    fake_counts_reset();
    fake_frames(200, 0);
    CHECK_EQ(fake_counts().read, 200);
    fake_frames(1, 2.0f);
    CHECK_EQ(fake_counts().read, 213); /* a sweep frame: the stack and 12 records (Lua: 14) */
    Put64(Game(MBM_INPUT_OWNER_RVA), 0);
    CHECK_EQ(vpm_binding_down(g_bindings[1]), -1);
}

static uint32_t HeaderLabel(int row) { return Get32(w.screen + LISTING + 7856 + 24784 * row + 4264 + 272); }
static const char* SlotText(uint32_t rva)
{
    uint64_t pointer = Get64(Game(rva));
    return pointer != 0 ? (const char*)(uintptr_t)pointer : NULL;
}

static void OpenPage(uint32_t tab)
{
    Put32(w.screen + BAR + 57448, 3);
    Put32(w.screen + BAR + 57452, 1);
    Put32(w.screen + 8, tab);
    Page(1);
}

static void ShowsTheModsTab(void)
{
    Ship();
    Def("external", "Toggle HUD", "Arc Tools", 2);
    Start();
    StockLists(0);
    fake_frames(3, DT);
    InstallStandIns();
    OpenPage(0);
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(g_labelCount, 4);
    CHECK(g_labels[0] == 0x8D70F451u && g_labels[2] == 0x00847FEBu && g_labels[3] == MBM_MODS_TITLE_ID);
    CHECK(Get32(w.screen + BAR + 11004 + 3400) == 3 && w.screen[BAR + 11021 + 3400] == 1);
    CHECK(strcmp(SlotText(MBM_MODS_TITLE_RVA), "MODS") == 0);
    CHECK_LOG("Added native MODS tab (current tab 1).");
    CHECK_EQ(fake_counts().read, 14); /* the gate, the page, 7 reset sources, the mission, the tab, the bar (Lua: 20) */
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(fake_counts().read, 11); /* a native tab: the page, 7 reset sources, the tab, the bar (Lua: 11) */
    Put32(w.screen + 8, 3);
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(g_builds, 1);
    CHECK_EQ(g_resets, 1);
    CHECK_EQ(fake_counts().read, 19); /* and each row's action, the row count (Lua: 36 and 7 VirtualQuery) */
    /* Sections by name: ARC TOOLS, then SHIP STATION HOTKEYS; text slots from the pool. */
    CHECK_EQ(Get32(w.screen + LISTING + 2411916), 9);
    CHECK(HeaderLabel(0) == 0x76AD93E3u && strcmp(SlotText(0x3327550), "ARC TOOLS") == 0);
    CHECK(strcmp(SlotText(0x3328230), "TOGGLE HUD") == 0 && HeaderLabel(2) == 0x431DA596u);
    CHECK(strcmp(SlotText(0x3328238), "SHIP STATION HOTKEYS") == 0);
    CHECK_EQ(Get32(Game(MBM_ACTION_LABELS_RVA + (12u * 97u) * 4u)), 0xA9CF13BBu);
    CHECK_EQ(Get32(w.screen + LISTING + 7856 + 24784 * 3 + 24760), 12u * 65536u + 1u);
    CHECK_LOG("Filled MODS tab: 7 bindings in 2 sections.");
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(fake_counts().read, 23); /* every row checked once (Lua: 20) */
    fake_counts_reset();
    fake_frames(2, DT);
    CHECK_EQ(fake_counts().read, 24); /* the row count only (Lua: 12 each) */
    CHECK_EQ(g_builds, 1);
    /* Rows of another tab left in place: rebuilt. */
    Put32(w.screen + LISTING + 7856 + 4264 + 272, 0x12345678);
    fake_frames(1, 0.5f);
    CHECK_EQ(g_builds, 2);
    /* Closing the page gives back the title, the slots and the row labels. */
    Page(0);
    fake_frames(1, DT);
    CHECK(SlotText(MBM_MODS_TITLE_RVA) == NULL && SlotText(0x3327550) == NULL && SlotText(0x3328238) == NULL);
    CHECK_EQ(Get32(Game(MBM_ACTION_LABELS_RVA + (12u * 97u) * 4u)), 0x82FBDCB2u);
    fake_counts_reset();
    fake_frames(2, DT);
    CHECK_EQ(fake_counts().read, 2);
}

/* Unwritable game.dll pages: nothing is written there, and no tab is added (its title cannot be shown). */
static void UnwritablePagesChangeNothing(void)
{
    Ship();
    Start();
    DWORD old;
    VirtualProtect(Game(0x3327550), 0x1000, PAGE_READONLY, &old); /* lint-ok: C1,C3 the test makes the text slots read-only */
    fake_frames(1, DT);
    InstallStandIns();
    OpenPage(3);
    fake_frames(3, DT);
    VirtualProtect(Game(0x3327550), 0x1000, PAGE_READWRITE, &old); /* lint-ok: C1,C3 and writable again */
    CHECK_LOG("Writes at game.dll+0x3327550 .. +0x3328490 skipped: the text slots are not writable.");
    CHECK_EQ(g_labelCount, 0);
    CHECK_EQ(g_builds, 0);
    CHECK(SlotText(MBM_MODS_TITLE_RVA) == NULL);
}

/* ---- 5. extended bindings, the capture and the panel (test_extended, test_capture, test_panel) -------------- */

typedef struct FakeDevice { const char* names[16]; uint8_t held[16]; int pressed; int connected; } FakeDevice;
static FakeDevice g_kb = {{"", "esc", "g", "h", "enter", "delete", "left ctrl", "f9", "left**"}, {0}, -1, 1};
static FakeDevice g_mouse = {{"left", "wheel_up", "wheel_down"}, {0}, -1, 1};
static FakeDevice g_pad = {{"a", "b", "x", "y", "left_shoulder"}, {0}, -1, 0};
static int g_guiCalls, g_guiOpen;
static char g_texts[256][64];

static int DevId(FakeDevice* d, const char* name, uint32_t* index)
{
    for (uint32_t i = 0; i < 16; i++)
        if (d->names[i] != NULL && strcmp(d->names[i], name) == 0) { *index = i; return 1; }
    return 0;
}
static int DevAny(FakeDevice* d, uint32_t* index) { if (d->pressed < 0) return 0; *index = (uint32_t)d->pressed; return 1; }
#define FAKE_DEVICE(N, D) \
    static int N##Button(uint32_t i) { return i < 16 && D.held[i]; } \
    static int N##Any(uint32_t* i) { return DevAny(&D, i); } \
    static int N##Pressed(uint32_t i) { return D.pressed == (int)i; } \
    static int N##Id(const char* n, uint32_t* i) { return DevId(&D, n, i); } \
    static const char* N##Name(uint32_t i) { return i < 16 ? D.names[i] : NULL; } \
    static int N##Connected(void) { return D.connected; } \
    static const MbmDevice k##N = {N##Button, N##Any, N##Pressed, N##Id, N##Name, NULL, N##Connected};
FAKE_DEVICE(Kb, g_kb)
FAKE_DEVICE(Mouse, g_mouse)
FAKE_DEVICE(Pad, g_pad)
static const MbmEngineInput kInput = {&kKb, &kMouse, {&kPad, NULL, NULL, NULL}, NULL};

static int GuiOpen(uint64_t font, uint64_t material, uint64_t atlas) { g_guiOpen = font == 0xF0000001u && material == 0xF0000002u; return g_guiOpen; }
static void GuiClose(void) { g_guiOpen = 0; }
static int GuiAlive(void) { return g_guiOpen; }
static uint32_t GuiHandle(uint32_t handle) { g_guiCalls++; return handle != 0 ? handle : (uint32_t)(g_guiCalls % 255) + 1; }
static uint32_t GuiRect(uint32_t h, float x, float y, float l, float w_, float h_, const uint8_t c[4]) { return GuiHandle(h); }
static uint32_t GuiText(uint32_t h, const char* text, float x, float y, float l, float size, const uint8_t c[4])
{
    h = GuiHandle(h);
    snprintf(g_texts[h], sizeof g_texts[h], "%s", text);
    return h;
}
static int GuiWidth(const char* text, float size, float* width)
{
    *width = (float)vpm_utf8_length(text, strlen(text)) * size / 2;
    return 1;
}
static const MbmGui kGui = {GuiOpen, GuiClose, GuiAlive, GuiRect, GuiText, GuiWidth};

static int Shown(const char* text)
{
    for (int i = 0; i < 256; i++)
        if (strcmp(g_texts[i], text) == 0) return 1;
    return 0;
}

static void Press(FakeDevice* d, uint32_t i) { d->held[i] = 1; d->pressed = (int)i; }
static void Release(FakeDevice* d, uint32_t i) { d->held[i] = 0; }
/* One capture frame without the panel: the frame number, the capture's update, then no press is fresh. */
static void Step(void)
{
    mbm.frame++;
    mbm_update_capture(DT);
    g_kb.pressed = g_mouse.pressed = g_pad.pressed = -1;
}

/* Seven fixed slots and 29 automatic actions held: the next registrations are extended. */
static void Pool(void)
{
    static char ids[29][12];
    for (int i = 0; i < 7; i++) Def(i == 0 ? "s1" : i == 1 ? "s2" : i == 2 ? "s3" : i == 3 ? "s4" : i == 4 ? "s5" : i == 5 ? "s6" : "s7", "Slot", NULL, (uint32_t)i + 1);
    for (int i = 0; i < 29; i++)
    {
        snprintf(ids[i], sizeof ids[i], "auto%d", i);
        Def(ids[i], "Auto", NULL, 0);
    }
    Def("ext.a", "Toggle HUD", "Extra Mod", 0);
    Def("ext.b", "Other", "Another Mod", 0);
}

static void ExtendedBindingsBeyondThePool(void)
{
    Pool();
    Start();
    fake_frames(1, DT);
    CHECK(Rec(36)->extended && Rec(37)->extended);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), -1); /* no engine input: the caller's fixed key */
    CHECK(strstr(vpm_status(Menu()), "the MORE MODS page is off") != NULL);
    vpm_settings_flush();
    CHECK(strcmp(vpm_setting(MBM_EXTENDED_SECTION, "ship_station_hotkeys.ext.a"), "default") == 0);
    InstallStandIns();
    OpenPage(0);
    fake_frames(1, DT);
    CHECK_EQ(g_labelCount, 4); /* no MORE MODS tab without the engine's Gui */
    Page(0);
    /* With engine input: none bound (false, never -1); a stored key fires once per press, after a resync frame. */
    mbm_engine_set(&kInput, NULL);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), 0);
    MbmAlternative g = {{{MBM_KEYBOARD, 2}, {MBM_KEYBOARD, 6}}, 2, MBM_PRESS, 0};
    CHECK(mbm_store_alternatives(Rec(36), &g, 1));
    Press(&g_kb, 2);
    Press(&g_kb, 6);
    fake_frames(1, DT);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), 0); /* held through the change: no press */
    Release(&g_kb, 2);
    fake_frames(1, DT);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), 0);
    Press(&g_kb, 2);
    fake_frames(1, DT);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), 1);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), 1); /* once per frame */
    fake_frames(1, DT);
    CHECK_EQ(vpm_binding_down(g_bindings[36]), 0);
    /* Saved, and extended again in the next session with its keys. */
    Session();
    vpm_settings_flush();
    CHECK(strcmp(vpm_setting(MBM_EXTENDED_SECTION, "ship_station_hotkeys.ext.a"), "set k:2+k:6@press") == 0);
    CHECK(Rec(36)->extended && Rec(36)->alternative_count == 1);
    /* A value this version cannot read: kept as it is, the binding inactive. */
    vpm_setting_put(MBM_EXTENDED_SECTION, "ship_station_hotkeys.ext.b", "set q:1@press");
    Session();
    CHECK(mbm_extended_inactive(Rec(37)));
    CHECK_EQ(vpm_binding_down(g_bindings[37]), 0);
    mbm_engine_set(NULL, NULL);
}

static int g_held, g_released;
static int HoldBack(void) { g_held++; return 1; }
static void ReleaseBack(void) { g_released++; }

static void CapturesAKey(void)
{
    Pool();
    Start();
    mbm_engine_set(&kInput, NULL);
    fake_frames(1, DT);
    const char* why = NULL;
    MbmRecord* r = Rec(36);
    Press(&g_kb, 4);
    CHECK(mbm_begin_capture(r, 0, HoldBack, ReleaseBack, &why) && g_held == 1 && mbm.suppressed);
    CHECK(!mbm_begin_capture(Rec(37), 0, NULL, NULL, &why) && strcmp(why, "a capture is running") == 0);
    Step();
    CHECK_EQ(mbm_capture_phase(NULL, NULL), MBM_ARMING); /* the Enter that opened it is held */
    Release(&g_kb, 4);
    Step();
    CHECK_EQ(mbm_capture_phase(NULL, NULL), MBM_CAPTURING);
    Press(&g_kb, 6);
    Step();
    Press(&g_kb, 2);
    Step();
    CHECK(r->alternative_count == 1 && r->alternatives[0].count == 2 && r->alternatives[0].inputs[1].index == 6);
    CHECK_EQ(mbm_capture_phase(NULL, NULL), MBM_RELEASING);
    Release(&g_kb, 2);
    Release(&g_kb, 6);
    Step();
    CHECK(mbm_capture_phase(NULL, NULL) == MBM_IDLE && g_released == 1 && !mbm.suppressed);
    /* Escape cancels without a change; Delete clears; the keyboard's mouse entry is ignored. */
    CHECK(mbm_begin_capture(r, 0, HoldBack, ReleaseBack, &why));
    Step();
    Press(&g_kb, 8);
    Step();
    Press(&g_kb, 1);
    Step();
    CHECK(mbm_capture_phase(NULL, NULL) == MBM_IDLE && r->alternative_count == 1);
    CHECK_LOG("Key capture ended: cancelled.");
    Release(&g_kb, 1);
    CHECK(mbm_begin_capture(r, 0, NULL, NULL, &why));
    Step();
    Press(&g_kb, 5);
    Step();
    CHECK(r->alternative_count == 0 && r->kind == MBM_KIND_CLEARED);
    for (int i = 0; i < 700; i++) Step();
    CHECK_EQ(mbm_capture_phase(NULL, NULL), MBM_RELEASING); /* Delete still held */
    Release(&g_kb, 5);
    Step();
    CHECK(mbm_begin_capture(r, 0, NULL, NULL, &why));
    for (int i = 0; i < 620; i++) Step();
    CHECK_LOG("Key capture ended: no key chosen in 10 seconds.");
    mbm_engine_set(NULL, NULL);
}

/* The MORE MODS tab: one native header row, the panel below it; select starts a capture, whose frames consume the
 * page's UI actions; the Gui is used only when something shown changes. */
static void ShowsTheMoreModsPanel(void)
{
    Pool();
    Start();
    mbm_engine_set(&kInput, &kGui);
    fake_frames(1, DT);
    InstallStandIns();
    Put64(Game(0x3772268), 0xF0000001u);
    Put64(Game(0x3772EE8), 0xF0000003u);
    uint8_t* material = fake_heap(64);
    Put64(Game(0x37C5478), Address(material));
    Put64(material + 24, 0xF0000002u);
    uint8_t* listing = w.screen + LISTING;
    uint8_t* widgets[2] = {listing + 272, listing + 7856};
    const float geometry[2][4] = {{100, 280, 1920, 806}, {100, 900, 844, 62}};
    for (int i = 0; i < 2; i++)
    {
        Put32(widgets[i], 0x10);
        PutF(widgets[i] + 36, geometry[i][2]); PutF(widgets[i] + 40, geometry[i][3]); PutF(widgets[i] + 84, 1);
        PutF(widgets[i] + 100, 1); PutF(widgets[i] + 140, 1); PutF(widgets[i] + 148, geometry[i][0]); PutF(widgets[i] + 156, geometry[i][1]);
    }
    OpenPage(4);
    fake_frames(3, DT);
    CHECK_EQ(g_labelCount, 5);
    CHECK_LOG("Added native MODS tab and MORE MODS tab (current tab 1).");
    CHECK_LOG("Filled MORE MODS tab: 2 extended bindings.");
    CHECK(g_guiOpen && Shown("ANOTHER MOD") && Shown("EXTRA MOD") && Shown("TOGGLE HUD") && Shown("NOT BOUND"));
    int calls = g_guiCalls;
    fake_frames(4, DT);
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK_EQ(g_guiCalls, calls); /* nothing changed: no Gui call */
    /* The page (36 reset sources here, the tab, the bar, the row count: 41) and the panel: the page kind, both widgets,
     * the cursor and 11 UI action states (5; Lua: 7). */
    CHECK_EQ(fake_counts().read, 46);
    *State(0, 2) = 1; /* down: the first binding row */
    fake_frames(1, DT);
    *State(0, 2) = 0;
    *State(0, 10) = 1; /* select */
    fake_frames(1, DT);
    CHECK(mbm_capture_phase(NULL, NULL) == MBM_ARMING && Shown("PRESS A KEY") && Shown("ESC: CANCEL, DELETE: CLEAR"));
    fake_counts_reset();
    fake_frames(1, DT);
    CHECK(g_consumedCount == 1 && g_consumed[0] == 10); /* select, still held, consumed */
    CHECK_EQ(fake_counts().read, 45); /* a capture: the page kind, both widgets, 97 UI action states (Lua: 5) */
    Press(&g_kb, 3);
    fake_frames(2, DT);
    Release(&g_kb, 3);
    fake_frames(1, DT);
    CHECK(mbm_capture_phase(NULL, NULL) == MBM_IDLE && Shown("H"));
    g_kb.pressed = -1;
    /* Another tab: the panel closes. A mission starts: MORE MODS goes at the next check. */
    Put32(w.screen + 8, 0);
    fake_frames(1, DT);
    CHECK(!g_guiOpen);
    Put32(w.mission + 8, 1);
    fake_frames(60, DT);
    CHECK_LOG("In a mission: MORE MODS not offered.");
    CHECK_LOG("Removed MORE MODS tab (current tab 1).");
    CHECK_EQ(g_labelCount, 4);
    mbm_engine_set(NULL, NULL);
}

static void StopGivesBackWhatAPageBorrowed(void)
{
    Ship();
    Start();
    fake_frames(1, DT);
    InstallStandIns();
    OpenPage(3);
    fake_frames(2, DT);
    CHECK(SlotText(MBM_MODS_TITLE_RVA) != NULL);
    Page(0);
    vpm_core_stop(Menu(), "test");
    CHECK(SlotText(MBM_MODS_TITLE_RVA) == NULL && SlotText(0x3327550) == NULL);
    CHECK_EQ(vpm_binding_down(g_bindings[0]), -1);
}

static void Reset(void)
{
    g_defCount = g_builds = g_resets = g_labelCount = g_consumedCount = g_guiCalls = g_guiOpen = g_held = g_released = 0;
    memset(g_bindings, 0, sizeof g_bindings);
    memset(g_texts, 0, sizeof g_texts);
}

#define CASE(test) do { Reset(); RUN(test); } while (0)

int main(void)
{
    CASE(AddsTheKeyboardDefaultsOnce);
    CASE(RefusesAnUnreviewedLayout);
    CASE(RegistersFixedSlotsAndAutomaticActions);
    CASE(KeepsReservationsAcrossSessions);
    CASE(ReservationsExpireAfterThirtySessions);
    CASE(SweepClearsInheritedDefaultsOnce);
    CASE(KeepsASingleCaptureAfterAPage);
    CASE(DownReadsTheActionState);
    CASE(ShowsTheModsTab);
    CASE(UnwritablePagesChangeNothing);
    CASE(ExtendedBindingsBeyondThePool);
    CASE(CapturesAKey);
    CASE(ShowsTheMoreModsPanel);
    CASE(StopGivesBackWhatAPageBorrowed);
    TEST_END();
}
