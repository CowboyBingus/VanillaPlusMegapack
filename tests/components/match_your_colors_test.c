/* Match Your Colors: the Lua tests' scenarios (components/MatchYourColors/tests/test_addon.lua, test_sync.lua and
 * test_cache.lua) on the fake game. The world is tests/fake_game.lua's: a local player (entity 5, peer
 * 0x00c0ffee5eed0001, unit 0x96, avatar 0xe5) and a remote one (entity 6, peer 0x1234, unit 0x97, avatar 0xe6) in the
 * player, customization, entity and avatar managers; the engine's units, meshes and materials (two per unit, their LUT
 * slot bound to the vanilla texture) and runtime textures behind its script API tables and get_engine_api (stand-ins
 * at the executable offsets the component checks); the squad's PlayFab lobby behind fake_export stand-ins. The job is a
 * canned one (myc_g.worker.job, as the Lua tests' TestRecolor.job: the real job reads the game's files, which the
 * offline parity tool covers), run inside the step (myc_g.worker.synchronous) except in the worker thread's own test.
 * Calls per frame are pinned with fake_counts and the fake engine's counts, as the Lua pinned them with frame_budget. */
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "harness/test.h"
#include "components.h"
#include "components/match_your_colors/myc_addon.h"
#include "components/match_your_colors/myc_job.h"

TEST_GLOBALS;

static const VpmComponentDef* const kDefs[] = {&vpm_component_match_your_colors};

#define DT (1.0f / 60.0f)
#define PLAYERS_RVA 0x3326468u
#define CUSTOMIZATION_RVA 0x33264F8u
#define ENTITIES_RVA 0x346BF98u
#define AVATARS_RVA 0x3326D20u
#define SCRIPT_RVA 0x3326308u
#define CONTEXT_RVA 0x347CEF0u
#define AVATAR_LOW 0x294dfa97u
#define AVATAR_HIGH 0x4d1c334du
#define LOCAL_UNIT 0x96u
#define REMOTE_UNIT 0x97u
#define HELMET 0xa5574ac2u
#define ARMOR 0x0ade6719u
#define CAPE 0x72492837u
#define REMOTE_HELMET 0x11111111u
#define REMOTE_ARMOR 0x22222222u
#define SET_HELMET 0x5e7e7e7eu
#define FAIL_HELMET 0x0f0f0f0fu
#define HELMET_LUT 0x962a946e964ebc40ull
#define ARMOR_LUT 0xa007a73e4082430eull
#define CAPE_LUT 0xd4cb1423c8d2a2c8ull
#define LUT_SLOT 0x7e662968u
#define SHIPPED "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC"
#define GET_API_SHIPPED "48 83 EC 28 83 F9 01 0F 85 11 22 33 44 55"
#define LOCAL_ID "C0FFEE5EED0001"
#define REMOTE_ID "1234"
#define SHARED "v=1;m=2;f=3;s=0;"
#define LEGACY "1|2|3|0"

static void Put32(uintptr_t at, uint32_t v) { memcpy((void*)at, &v, 4); }
static void Put64(uintptr_t at, uint64_t v) { memcpy((void*)at, &v, 8); }
static uint32_t Get32(uintptr_t at) { uint32_t v; memcpy(&v, (const void*)at, 4); return v; }
static uint64_t Get64(uintptr_t at) { uint64_t v; memcpy(&v, (const void*)at, 8); return v; }
static uintptr_t Heap(size_t size) { return (uintptr_t)fake_heap(size); }

static uintptr_t Text(const char* text)
{
    uintptr_t at = Heap(strlen(text) + 1);
    memcpy((void*)at, text, strlen(text) + 1);
    return at;
}

/* ---- the world (fake_game.lua Fake.world) -------------------------------------------------------------------------- */

static struct
{
    uintptr_t players, customization, entities, avatars, records;
} W;

/* A game map (avatar.lua lookup's layout): its header at header, rows {key, value} probed from key % capacity. */
static void MapPut(uintptr_t header, uint32_t key, uint32_t value)
{
    uintptr_t rows = (uintptr_t)Get64(header);
    uint32_t capacity = Get32(header + 8), at = key % capacity;
    while (Get32(rows + 8 * at) != 0xFFFFFFFFu && Get32(rows + 8 * at) != key) at = (at + 1) % capacity;
    Put32(rows + 8 * at, key);
    Put32(rows + 8 * at + 4, value);
}

static void Map(uintptr_t header, uint32_t capacity, int n, const uint32_t* keys, const uint32_t* values)
{
    uintptr_t rows = Heap(8 * capacity);
    for (uint32_t i = 0; i < capacity; i++) Put32(rows + 8 * i, 0xFFFFFFFFu);
    Put64(header, rows);
    Put32(header + 8, capacity);
    Put32(header + 12, 0xFFFFFFFFu);
    Put32(header + 16, 1);
    for (int k = 0; k < n; k++) MapPut(header, keys[k], values[k]);
}

static uintptr_t UnitsOf(int index) { return W.avatars + 5532272 + 440 * (uintptr_t)index + 220; }
static void LocalUnit(int type, int slot, uint32_t unit) { Put32(UnitsOf(0) + 40 * type + 4 * slot, unit); }
static void Kits(int record, uint32_t helmet, uint32_t cape, uint32_t armor)
{
    uintptr_t at = W.customization + 2412 + 68 * (uintptr_t)record;
    Put32(at, 0);
    Put32(at + 4, helmet);
    Put32(at + 8, cape);
    Put32(at + 12, armor);
}

/* The local avatar's entity record as an avatar, or (made 0) another entity: the player's kits read while its
 * Helldiver is not made yet, as on a loading screen. */
static void AvatarMade(int made)
{
    uintptr_t at = W.entities + 0xF32F18 + 24 * 194;
    Put32(at, made ? AVATAR_LOW : 0);
    Put32(at + 4, made ? AVATAR_HIGH : 0);
}

static void MakeWorld(int manager, int players, uint32_t helmet)
{
    uintptr_t game = fake_game();
    W.players = Heap(0x1000);
    Put64(game + PLAYERS_RVA, manager ? W.players : 0);
    Put32(W.players + 132, (uint32_t)players);
    W.records = Heap(0x100);
    for (int i = 0; i < 2; i++)
    {
        uintptr_t record = W.records + 32 * (uintptr_t)i;
        Put32(record + 8, 5u + (uint32_t)i);
        *(uint8_t*)(record + 20) = i == 0;
        if (i == 0) Put64(W.players + 232, record);
        Put32(W.players + 712 + 56 * i, i == 0 ? 0x5eed0001u : 0x1234u);
        Put32(W.players + 716 + 56 * i, i == 0 ? 0x00c0ffeeu : 0);
        Put32(W.players + 936 + 32 * i, i == 0 ? LOCAL_UNIT : REMOTE_UNIT);
        Put32(W.players + 948 + 32 * i, i == 0 ? 1 : 3);
    }
    const uint32_t entity_keys[2] = {5, 6}, indexes[2] = {0, 1};
    Map(W.players + 208, 8, players > 0 ? 2 : 0, entity_keys, indexes);
    W.customization = Heap(0x1000);
    Put64(game + CUSTOMIZATION_RVA, W.customization);
    Map(W.customization + 2352, 8, 2, entity_keys, indexes);
    Kits(0, helmet, CAPE, ARMOR);
    Kits(1, REMOTE_HELMET, 0, REMOTE_ARMOR);
    W.entities = Heap(0xF32F18 + 24 * 256);
    Put64(game + ENTITIES_RVA, W.entities);
    const uint32_t units[2] = {LOCAL_UNIT, REMOTE_UNIT}, entities[2] = {194, 195};
    Map(W.entities + 0xF22EC8, 16, 2, units, entities);
    for (int k = 0; k < 2; k++)
    {
        uintptr_t at = W.entities + 0xF32F18 + 24 * (194 + (uintptr_t)k);
        Put32(at, AVATAR_LOW);
        Put32(at + 4, AVATAR_HIGH);
        Put32(at + 8, 0xe5u + (uint32_t)k);
        *(uint8_t*)(at + 20) = k == 0;
    }
    W.avatars = Heap(5532272 + 440 * 4);
    Put64(game + AVATARS_RVA, W.avatars);
    Put32(W.avatars + 0x6c, 2);
    const uint32_t avatars[2] = {0xe5, 0xe6};
    Map(W.avatars + 248, 8, 2, avatars, indexes);
    LocalUnit(0, 0, 0x100);
    LocalUnit(0, 1, 0x106);
    LocalUnit(0, 2, 0x101);
    LocalUnit(1, 3, 0x102);
    LocalUnit(0, 4, 0x103);
    Put32(UnitsOf(1), 0x200);
}

/* ---- the engine (fake_game.lua Fake.engine) ------------------------------------------------------------------------ */

#define MAX_UNITS 32
static struct
{
    struct { uint32_t unit; int alive; uintptr_t mesh, materials[2]; } units[MAX_UNITS];
    int nunits;
    struct { uint64_t name; uintptr_t object; } vanilla[16];
    int nvanilla;
    uintptr_t textures[512];
    int ntextures;
    int set_resource, create, update, destroy, commit, alive, visibility;
    uintptr_t script, unit_table, buffers, resources;
} E;

static int FindUnit(uint32_t unit)
{
    for (int i = 0; i < E.nunits; i++)
        if (E.units[i].unit == unit) return i;
    return -1;
}

static uintptr_t VanillaOf(uint64_t name)
{
    for (int i = 0; i < E.nvanilla; i++)
        if (E.vanilla[i].name == name) return E.vanilla[i].object;
    return 0;
}

static uintptr_t Vanilla(uint64_t name)
{
    uintptr_t object = VanillaOf(name);
    if (object != 0) return object;
    object = Heap(16);
    Put32(object, 0x2000u + (uint32_t)E.nvanilla);
    E.vanilla[E.nvanilla].name = name;
    E.vanilla[E.nvanilla++].object = object;
    return object;
}

/* A unit whose two materials hold the vanilla texture of lut in their LUT slot (one mesh). */
static void Unit(uint32_t unit, uint64_t lut)
{
    int i = E.nunits++;
    E.units[i].unit = unit;
    E.units[i].alive = 1;
    E.units[i].mesh = Heap(0x100);
    *(uint8_t*)(E.units[i].mesh + 0xDC) = 0xFF;
    for (int m = 0; m < 2; m++)
    {
        uintptr_t material = Heap(0x70), array = material + 0x40;
        Put32(material + 24, 1);
        Put64(material + 32, array);
        Put32(array, LUT_SLOT);
        Put64(array + 8, Vanilla(lut));
        E.units[i].materials[m] = material;
    }
}

static uintptr_t Entry(uintptr_t material) { return material + 0x40; }
static uintptr_t Bound(uint32_t unit, int m) { return (uintptr_t)Get64(Entry(E.units[FindUnit(unit)].materials[m]) + 8); }

static int Ours(uintptr_t object)
{
    for (int i = 0; i < E.ntextures; i++)
        if (E.textures[i] == object) return 1;
    return 0;
}

/* Both materials of a unit hold one of the runtime textures (1), the vanilla texture of lut (0), or something else. */
static int Recolored(uint32_t unit, uint64_t lut)
{
    int ours = Ours(Bound(unit, 0)) && Ours(Bound(unit, 1)), vanilla = Bound(unit, 0) == VanillaOf(lut) && Bound(unit, 1) == VanillaOf(lut);
    return ours ? 1 : vanilla ? 0 : -1;
}

static uint8_t Alive(uint32_t unit)
{
    E.alive++;
    int i = FindUnit(unit);
    return i >= 0 && E.units[i].alive;
}
static uint32_t Meshes(uint32_t unit) { return FindUnit(unit) >= 0 ? 1 : 0; }
static uint64_t Mesh(uint32_t unit, uint32_t index)
{
    int i = FindUnit(unit);
    return i >= 0 ? E.units[i].mesh : 0;
}
static uint32_t Materials(uint64_t mesh)
{
    for (int i = 0; i < E.nunits; i++)
        if (E.units[i].mesh == mesh) return 2;
    return 0;
}
static uint64_t Material(uint64_t mesh, uint32_t index)
{
    for (int i = 0; i < E.nunits; i++)
        if (E.units[i].mesh == mesh && index < 2) return E.units[i].materials[index];
    return 0;
}
static void Commit(uint64_t mesh) { E.commit++; }
static void Visibility(uint32_t unit, uint32_t visible, uint8_t children)
{
    E.visibility++;
    int i = FindUnit(unit);
    if (i >= 0) *(uint8_t*)(E.units[i].mesh + 0xDC) = visible ? 0xFF : 0;
}
static void SetResource(uint64_t material, uint32_t slot, uint64_t resource)
{
    E.set_resource++;
    if (Get32(Entry((uintptr_t)material)) == slot) Put64(Entry((uintptr_t)material) + 8, resource);
}
static uint32_t Create(uint32_t size, uint32_t validity, uint32_t view_type, const void* view, const void* data)
{
    E.create++;
    uintptr_t object = Heap(16);
    Put32(object, 0x3800u + (uint32_t)E.ntextures);
    E.textures[E.ntextures++] = object;
    return (uint32_t)E.ntextures;
}
static void Update(uint32_t handle, uint32_t size, const void* data) { E.update++; }
static void Destroy(uint32_t handle) { E.destroy++; }
static uint64_t Resource(uint32_t handle) { return handle >= 1 && (int)handle <= E.ntextures ? E.textures[handle - 1] : 0; }
static uint8_t CanGet(uint64_t type, uint64_t name) { return VanillaOf(name) != 0; }
static uint64_t Get(uint64_t type, uint64_t name) { return VanillaOf(name); }
static uint64_t GetApi(uint32_t id) { return id == 26 ? E.buffers : id == 5 ? E.resources : 0; }

/* The script API's tables and get_engine_api (ready: the engine filled the script API's pointer). */
static void MakeEngine(int ready)
{
    E.script = Heap(256);
    E.unit_table = Heap(2048);
    uintptr_t mesh = Heap(64), material = Heap(256);
    E.buffers = Heap(256);
    E.resources = Heap(128);
    if (ready) Put64(fake_game() + SCRIPT_RVA, E.script);
    Put64(E.script + 24, E.unit_table);
    Put64(E.script + 232, mesh);
    Put64(E.script + 40, material);
    const struct { uintptr_t table; uint32_t offset, rva; void* fn; } f[] = {
        {E.unit_table, 1824, 0x1feeb0, (void*)Alive}, {E.unit_table, 424, 0x200cd0, (void*)Meshes},
        {E.unit_table, 440, 0x200d20, (void*)Mesh}, {E.unit_table, 1624, 0x205680, (void*)Visibility},
        {mesh, 8, 0x344300, (void*)Materials}, {mesh, 24, 0x344350, (void*)Material}, {mesh, 32, 0x344360, (void*)Commit},
        {material, 128, 0x30f2b0, (void*)SetResource}, {E.buffers, 0x60, 0x1c7cc0, (void*)Create},
        {E.buffers, 0x68, 0x1c8090, (void*)Update}, {E.buffers, 0x70, 0x1c81a0, (void*)Destroy},
        {E.buffers, 0x78, 0x1c8670, (void*)Resource}, {E.resources, 0x30, 0xa0d30, (void*)CanGet},
        {E.resources, 0x40, 0xa0df0, (void*)Get}};
    for (size_t i = 0; i < sizeof f / sizeof f[0]; i++)
    {
        fake_stand_in_exe(f[i].rva, SHIPPED, f[i].fn);
        Put64(f[i].table + f[i].offset, fake_exe() + f[i].rva);
    }
    fake_stand_in_exe(0xa4e50, GET_API_SHIPPED, (void*)GetApi);
    Unit(0x100, HELMET_LUT);
    Unit(0x101, ARMOR_LUT);
    Unit(0x102, ARMOR_LUT);
    Unit(0x103, ARMOR_LUT);
    Unit(0x106, CAPE_LUT);
    Unit(0x200, HELMET_LUT);
}

/* ---- the canned job (test_addon.lua fake_job) ----------------------------------------------------------------------- */

static struct
{
    int jobs;
    MycRequest last;
    DWORD thread;
    uint32_t recomposed;            /* a kit record whose signature reads otherwise now (a transmog's) */
    int dirty;                      /* the job made new analyses */
} C;

static MycPipeline g_pipeline;      /* the canned job's: a catalogue stand-in for records_same */
static MycKit kHelmetKit = {.type = MYC_HELMET}, kArmorKit = {.type = MYC_ARMOR};
static MycMaterial kMaterial;
static MycAPiece kHelmetPieces[1] = {{.piece = {.slot = 0, .type = 0, .body = 3}, .materials = &kMaterial, .nmaterials = 1}};
static MycAPiece kArmorPieces[3] = {{.piece = {.slot = 2, .type = 0, .body = 0}, .materials = &kMaterial, .nmaterials = 1},
                                    {.piece = {.slot = 3, .type = 1, .body = 3}, .materials = &kMaterial, .nmaterials = 1},
                                    {.piece = {.slot = 4, .type = 0, .body = 0}, .materials = &kMaterial, .nmaterials = 1}};
static MycAnalysis kHelmet = {.kit = &kHelmetKit, .pieces = kHelmetPieces, .npieces = 1};
static MycAnalysis kArmor = {.kit = &kArmorKit, .pieces = kArmorPieces, .npieces = 3};

static const char* Signature(MycCatalogue* kits, uint32_t id)
{
    static char text[32];
    snprintf(text, sizeof text, id == C.recomposed ? "recomposed %08x" : "record %08x", id);
    return text;
}

static void Lut(MycResult* out, uint64_t name)
{
    MycSpec* spec = myc_spec_new(MYC_SPEC_LUT, 23, 8, 23 * 8 * 16);
    myc_specs_put(&out->arena, &out->luts, name, spec);
}

static void Sign(MycResult* out, uint32_t id)
{
    char text[32];
    snprintf(text, sizeof text, "record %08x", id);
    out->signatures[out->nsignatures++] = (MycSigned){id, myc_strdup(&out->arena, text)};
}

static int Canned(MycPipeline** p, const wchar_t* data, const wchar_t* cache, MycRequest* r, MycResult* out, MycErr* err)
{
    C.jobs++;
    C.last = *r;
    C.thread = GetCurrentThreadId();
    if (*p == NULL) *p = &g_pipeline;
    (*p)->open = 1; /* as a job's first read opens the game-data reader */
    if (C.dirty) (*p)->dirty = 1; /* a new analysis made: the cache is due */
    if (!r->has_kits && r->nweapons == 0) { out->action = MYC_PREPARED; return 1; }
    if (r->helmet == FAIL_HELMET) return myc_fail(err, "canned failure");
    int scheme = r->scheme > 0;
    if (r->mode == MYC_OFF && !scheme) { myc_result_restore(out, NULL, "off"); return 1; }
    if (!scheme && r->keep_sets && r->helmet == SET_HELMET) { myc_result_restore(out, NULL, "complete set"); return 1; }
    int helmet = scheme || r->mode == MYC_HELMET_FROM_ARMOR;
    out->action = MYC_APPLY;
    snprintf(out->key, sizeof out->key, "%d:%d:%u:%u:%u:%d:%d", r->mode, r->scheme, r->helmet, r->armor, r->body,
        r->keep_hoods ? 1 : 0, r->materials ? 1 : 0);
    if (helmet) Lut(out, HELMET_LUT);
    if (!helmet || scheme) Lut(out, ARMOR_LUT);
    out->first = helmet ? 0 : 1;
    out->last = helmet && !scheme ? 0 : 9;
    out->target = helmet ? &kHelmet : &kArmor;
    out->targets[out->ntargets++] = out->target;
    if (scheme) out->targets[out->ntargets++] = &kArmor;
    Sign(out, r->helmet);
    Sign(out, r->armor);
    return 1;
}

/* ---- the component ------------------------------------------------------------------------------------------------- */

typedef struct Calls { uint32_t reads, logs, writable, exports, code; int set_resource, create, update, alive; } Calls;

static Calls Frame(void)
{
    fake_counts_reset();
    int set = E.set_resource, create = E.create, update = E.update, alive = E.alive;
    fake_frames(1, DT);
    FakeCounts c = fake_counts();
    return (Calls){c.read, c.log, c.writable, c.exports, c.code_matches, E.set_resource - set, E.create - create,
                   E.update - update, E.alive - alive};
}

static void Frames(int n)
{
    for (int i = 0; i < n; i++) Frame();
}

/* A fresh session: the world (manager: a player manager; players: its count), the engine (ready: its script API filled),
 * the component started with the canned job, the game loaded and (ready) the engine opened on the first frame. */
static void Boot(int manager, int players, uint32_t helmet, int ready)
{
    fake_setup();
    memset(&E, 0, sizeof E);
    memset(&C, 0, sizeof C);
    memset(&g_pipeline, 0, sizeof g_pipeline);
    g_pipeline.kits = (MycCatalogue*)&g_pipeline;
    MakeWorld(manager, players, helmet);
    MakeEngine(ready);
    fake_start(kDefs, 1);
    myc_g.worker.synchronous = 1;
    myc_g.worker.job = Canned;
    myc_g.signature = Signature;
    fake_fire(HF_EVENT_GAME_LOADED);
    fake_frames(1, DT);
}

static VpmOption* OptionNamed(const char* id)
{
    for (int i = 0; i < vpm_option_count(); i++)
        if (strcmp(vpm_option_def(vpm_option_at(i))->id, id) == 0) return vpm_option_at(i);
    return NULL;
}

static void SetOption(const char* id, double value) { CHECK(vpm_option_apply(OptionNamed(id), value)); }

/* ---- tests: start, options and the engine --------------------------------------------------------------------------- */

static void RegistersTheLuaOptions(void)
{
    Boot(1, 1, HELMET, 1);
    static const char* const ids[] = {"mode", "paint_scheme", "recolor_squadmates", "squadmates_colors", "hide_cape",
                                      "keep_sets", "recolor_hoods", "match_materials", "recolor_cape", "recolor_weapons"};
    static const double values[] = {2, 1, 1, 1, 1, 1, 1, 0, 0, 0};
    CHECK_EQ(vpm_option_count(), 10);
    for (int i = 0; i < 10 && i < vpm_option_count(); i++)
    {
        const VpmOptionDef* d = vpm_option_def(vpm_option_at(i));
        CHECK(strcmp(d->id, ids[i]) == 0);
        CHECK(d->kind == (i < 5 ? VPM_CHOICE : VPM_TOGGLE));
        CHECK(d->value == values[i]);
        CHECK(strlen(d->description) <= VPM_OPTION_DESCRIPTION);
    }
    const VpmOptionDef* mode = vpm_option_def(OptionNamed("mode"));
    CHECK(strcmp(mode->label, "Color Matching") == 0 && strcmp(mode->choices[0], "Off") == 0
          && strcmp(mode->choices[3], "Helmet and Armor Match Cape") == 0 && mode->choices[4] == NULL);
    const VpmOptionDef* scheme = vpm_option_def(OptionNamed("paint_scheme"));
    CHECK(strcmp(scheme->choices[0], "Off") == 0 && strcmp(scheme->choices[1], "Helldiver") == 0
          && strcmp(scheme->choices[12], "SEAF") == 0 && scheme->choices[13] == NULL);
    CHECK(strncmp(vpm_option_def(OptionNamed("recolor_weapons"))->description, "Experimental.", 13) == 0);
    CHECK_LOG("[Match Your Colors] Match Your Colors v1.5 initialized.");
    CHECK_LOG("[Match Your Colors] Options: mode 2, paint scheme 0, keep sets true, recolor hoods true, match materials "
              "false, recolor cape false, recolor weapons false, recolor squadmates 1, squadmates colors 1, hide cape 1.");
    CHECK_NO_LOG("Option mode =");
}

static void SavedOptionsAreLoggedAsChanges(void)
{
    Boot(1, 1, HELMET, 0);
    SetOption("mode", 3);
    SetOption("paint_scheme", 6);
    SetOption("recolor_cape", 1);
    Put64(fake_game() + SCRIPT_RVA, E.script);
    Frames(31);
    CHECK_LOG("Option mode = 3.");
    CHECK_LOG("Option scheme = 5.");
    CHECK_LOG("Option recolor_cape = true.");
    CHECK_LOG("Options: mode 3, paint scheme 5, keep sets true, recolor hoods true, match materials false, recolor cape true");
}

static void WaitsForTheEngineScriptApi(void)
{
    Boot(1, 1, HELMET, 0);
    fake_counts_reset();
    fake_frames(60, DT);
    CHECK_EQ(fake_log_count("Waiting for the engine (script API unavailable)."), 1);
    CHECK_EQ(fake_counts().code_matches, 2); /* one get_engine_api check every 30 frames */
    CHECK(strcmp(vpm_status(fake_component(0)), "waiting for the engine (script API unavailable)") == 0);
    Put64(fake_game() + SCRIPT_RVA, E.script);
    Frames(30);
    CHECK_LOG("[Match Your Colors] Match Your Colors v1.5 initialized.");
    Frames(4);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
}

static void StopsWhenAnEngineFunctionChanged(void)
{
    MakeWorld(1, 1, HELMET);
    memset(&E, 0, sizeof E);
    MakeEngine(1);
    Put64(E.unit_table + 1824, fake_exe() + 0x1feeb4);
    fake_start(kDefs, 1);
    fake_fire(HF_EVENT_GAME_LOADED);
    Frames(1);
    CHECK_LOG("disabled: engine function changed: alive");
    CHECK(!vpm_running(fake_component(0)));
}

/* ---- tests: the local Helldiver (test_addon.lua) -------------------------------------------------------------------- */

static void TitleScreenResolvesEvery15Frames(void)
{
    Boot(0, 1, HELMET, 1);
    Calls first = Frame();
    CHECK_EQ(first.reads, 1); /* the resolve stops at the player manager */
    int quiet = 1;
    for (int i = 2; i <= 15; i++) quiet &= Frame().reads == 0;
    CHECK(quiet);
    CHECK_EQ(Frame().reads, 1);
    CHECK_EQ(E.create, 0);
    CHECK_EQ(C.jobs, 0);
    CHECK_LOG("Waiting for the local Helldiver (no player manager).");
}

static void ALoadingWorldPreparesThePipelineOnce(void)
{
    Boot(1, 0, HELMET, 1);
    Calls first = Frame();
    CHECK(first.reads >= 1 && first.reads <= 3);
    Frame();
    CHECK_EQ(C.jobs, 1);
    CHECK(C.last.target == MYC_TARGET_PREPARE && !C.last.has_kits);
    Frames(60);
    CHECK_EQ(C.jobs, 1);
    CHECK_EQ(E.create, 0);
    CHECK_LOG("Prepared ahead of the Helldiver: analysis cache and game data");
}

static void KitsKnownBeforeTheHelldiverArePrepared(void)
{
    Boot(1, 1, HELMET, 1);
    AvatarMade(0);
    Frames(2);
    CHECK_EQ(C.jobs, 1);
    CHECK(C.last.target == MYC_TARGET_PREPARE && C.last.helmet == HELMET && C.last.armor == ARMOR
          && C.last.mode == MYC_HELMET_FROM_ARMOR);
    Frames(29);
    int stock = MYC_POOL_STOCK + 9 * (MYC_POOL_SPARES + 1); /* its LUT's size, then every other LUT size of the game */
    CHECK_EQ(C.jobs, 1);
    CHECK_EQ(E.create, stock);
    CHECK_EQ(myc_pool_free_count(&myc_g.pool), stock);
    CHECK_LOG("Prepared ahead of the Helldiver: plans of helmet a5574ac2, armor 0ade6719");
    CHECK_LOG("33 textures made ahead");
    AvatarMade(1);
    Frames(15); /* frame 46 finds the Helldiver */
    CHECK(myc_g.has_identity);
    Calls job = Frame(), apply = Frame();
    CHECK_EQ(C.jobs, 2);
    CHECK(C.last.target == MYC_TARGET_AVATAR);
    CHECK_EQ(job.create + apply.create, 0); /* no texture made on the Helldiver's frames: refilled */
    CHECK_EQ(apply.update, 1);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
    CHECK_LOG("2 frames after the Helldiver was found");
}

static void NothingAheadWhileNothingIsRecolored(void)
{
    Boot(1, 0, HELMET, 1);
    SetOption("mode", 1);
    Frames(31);
    CHECK_EQ(C.jobs, 0);
    Boot(1, 1, FAIL_HELMET, 1);
    AvatarMade(0);
    Frames(46);
    CHECK_EQ(C.jobs, 1);
    CHECK_EQ(fake_log_count("Preparing ahead of the Helldiver failed: canned failure"), 1);
    CHECK_EQ(myc_g.nfailures, 0);
}

static void StandInKitsAreNotPrepared(void)
{
    Boot(1, 1, HELMET, 1);
    SetOption("recolor_cape", 1);
    AvatarMade(0);
    Kits(0, HELMET, CAPE, MYC_STAND_IN);
    Frames(16);
    CHECK(C.jobs == 0 || !C.last.has_kits);
    Kits(0, HELMET, MYC_STAND_IN, ARMOR);
    Frames(16);
    CHECK(C.jobs == 0 || !C.last.has_kits); /* a stand-in cape counts with Recolor Cape on */
    Kits(0, HELMET, CAPE, ARMOR);
    Frames(15);
    CHECK(C.last.target == MYC_TARGET_PREPARE && C.last.has_kits && C.last.armor == ARMOR && C.last.cape == CAPE);
    CHECK_NO_LOG("Preparing ahead of the Helldiver failed");
}

static void TheLocalHelmetTakesThePlan(void)
{
    Boot(1, 1, HELMET, 1);
    Calls resolve = Frame();
    CHECK(resolve.reads > 10);
    CHECK_LOG("Local Helldiver: avatar 0, helmet a5574ac2, armor 0ade6719, body 0.");
    Frame();
    CHECK_EQ(C.jobs, 1);
    CHECK(C.last.target == MYC_TARGET_AVATAR && C.last.helmet == HELMET && C.last.armor == ARMOR && C.last.keep_sets
          && !C.last.keep_hoods && !C.last.materials && !C.last.capes && C.last.scheme == 0);
    Calls apply = Frame();
    CHECK_EQ(apply.set_resource, 2);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
    CHECK_EQ(Recolored(0x200, HELMET_LUT), 0); /* the remote helmet untouched */
    CHECK_EQ(Recolored(0x101, ARMOR_LUT), 0);  /* the armor untouched */
    CHECK_EQ(E.create, 1 + MYC_POOL_SPARES);   /* one texture bound, the spares made in the same frame are free */
    CHECK_EQ(myc_pool_free_count(&myc_g.pool), MYC_POOL_SPARES);
    CHECK_LOG("Recolored 2 materials (helmet matches armor, 1 LUTs; job ");
    CHECK_LOG("; 2 frames after the Helldiver was found).");
    CHECK(strcmp(vpm_status(fake_component(0)), "active") == 0);
}

/* Over count frames: frames of exactly idle reads, exactly check reads, and other (the 2-second chain check). */
static void Classify(int count, uint32_t idle, uint32_t check, int* n_idle, int* n_check, int* n_other, int* quiet)
{
    *n_idle = *n_check = *n_other = 0;
    *quiet = 1;
    for (int i = 0; i < count; i++)
    {
        Calls f = Frame();
        if (f.reads == idle && f.alive == 0) (*n_idle)++;
        else if (f.reads == check) (*n_check)++;
        else (*n_other)++;
        *quiet &= f.logs == 0 && f.writable == 0 && f.exports == 0 && f.set_resource == 0 && f.create == 0 && f.update == 0;
    }
}

static void IdleFramesReadOnce(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    int idle, checks, other, quiet;
    Classify(240, 1, 3, &idle, &checks, &other, &quiet); /* the units; +2 every 30 frames (one binding probe) */
    CHECK_EQ(idle + checks + other, 240);
    CHECK_EQ(other, 2);
    CHECK(checks >= 7 && checks <= 8);
    CHECK(quiet); /* no log line, no page check, no export lookup, no engine call */
}

static void OffReadsTheUnitsOnly(void)
{
    Boot(1, 1, HELMET, 1);
    SetOption("mode", 1);
    Frames(4);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 0);
    CHECK_LOG("Original colors (off).");
    int idle, checks, other, quiet;
    Classify(240, 1, 1, &idle, &checks, &other, &quiet);
    CHECK_EQ(other, 2);
    CHECK_EQ(idle + checks, 238);
    CHECK(quiet);
}

static void AReEquipStartsAJob(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    Unit(0x111, ARMOR_LUT);
    Kits(0, HELMET, CAPE, 0x0b0b0b0bu);
    LocalUnit(0, 2, 0x111);
    Frames(3);
    CHECK_EQ(C.jobs, 2);
    CHECK(C.last.armor == 0x0b0b0b0bu);
    CHECK_LOG("Local Helldiver: avatar 0, helmet a5574ac2, armor 0b0b0b0b, body 0.");
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
}

static void ARespawnBindsTheSamePlanWithoutAJob(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    Unit(0x120, HELMET_LUT);
    E.units[FindUnit(0x100)].alive = 0;
    LocalUnit(0, 0, 0x120);
    Calls f = Frame();
    CHECK_EQ(C.jobs, 1);
    CHECK_EQ(f.set_resource, 2);
    CHECK_EQ(Recolored(0x120, HELMET_LUT), 1);
    CHECK_EQ(myc_g.controller.nbindings, 2); /* the dead unit's bindings dropped */
}

static void ARecomposedRecordStartsAJob(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    C.recomposed = HELMET; /* a transmog mod recomposed the helmet's record under the same id */
    Unit(0x120, HELMET_LUT);
    LocalUnit(0, 0, 0x120);
    Frames(3);
    CHECK_EQ(C.jobs, 2);
    CHECK_EQ(Recolored(0x120, HELMET_LUT), 1);
}

static void OptionsStartJobs(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    SetOption("mode", 3);
    CHECK_LOG("Option mode = 3.");
    Frames(3);
    CHECK_EQ(C.jobs, 2);
    CHECK(C.last.mode == MYC_ARMOR_FROM_HELMET);
    CHECK_EQ(Recolored(0x101, ARMOR_LUT), 1);
    CHECK_EQ(Recolored(0x102, ARMOR_LUT), 1);
    CHECK_EQ(Recolored(0x103, ARMOR_LUT), 1);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 0);
    CHECK_EQ(Recolored(0x106, CAPE_LUT), 0);
    SetOption("mode", 3); /* the same value: nothing */
    Frames(3);
    CHECK_EQ(C.jobs, 2);
    SetOption("paint_scheme", 2);
    Frames(3);
    CHECK(C.last.scheme == 1);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
    CHECK_EQ(Recolored(0x101, ARMOR_LUT), 1);
    SetOption("paint_scheme", 1);
    SetOption("mode", 1);
    Frames(3);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 0);
    CHECK_EQ(Recolored(0x101, ARMOR_LUT), 0);
    CHECK_LOG("Original colors (off).");
    CHECK(strcmp(vpm_status(fake_component(0)), "vanilla: off") == 0);
}

static void CompleteSetsKeepTheirColors(void)
{
    Boot(1, 1, SET_HELMET, 1);
    Frames(4);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 0);
    CHECK_LOG("Original colors (complete set).");
    SetOption("keep_sets", 0);
    Frames(3);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
}

static void FailuresAreCountedToThree(void)
{
    Boot(1, 1, FAIL_HELMET, 1);
    Frames(4);
    CHECK_LOG("Recolor failed (1/3): canned failure");
    CHECK(strcmp(vpm_status(fake_component(0)), "failed: canned failure") == 0);
    for (int i = 0; i < 3; i++)
    {
        myc_g.dirty = 1;
        Frames(2);
    }
    CHECK_LOG("Recolor failed (3/3): canned failure");
    CHECK_EQ(C.jobs, 3);
    CHECK(vpm_running(fake_component(0)));
}

static void TheGamePuttingTheOriginalBackIsSeen(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    Put64(Entry(E.units[FindUnit(0x100)].materials[0]) + 8, VanillaOf(HELMET_LUT));
    Put64(Entry(E.units[FindUnit(0x100)].materials[1]) + 8, VanillaOf(HELMET_LUT));
    Frames(33);
    CHECK_LOG("The game put an original color texture back on a recolored material; applying again.");
    CHECK_EQ(C.jobs, 2);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
}

static void StopPutsTheOriginalsBack(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
    vpm_fail(fake_component(0), "test stop");
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 0);
    CHECK_LOG("[Match Your Colors] Stopped (test stop).");
    fake_counts_reset();
    fake_frames(30, DT);
    CHECK_EQ(fake_counts().read, 0);
}

static void JobsRunOnTheWorkerThread(void)
{
    Boot(1, 1, HELMET, 1);
    myc_g.worker.synchronous = 0;
    Frames(2);
    for (int i = 0; i < 2000 && Recolored(0x100, HELMET_LUT) != 1; i++)
    {
        Sleep(1);
        Frames(1);
    }
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
    CHECK(C.thread != 0 && C.thread != GetCurrentThreadId());
    CHECK(myc_g.worker.thread != NULL);
    SetOption("mode", 3);
    for (int i = 0; i < 2000 && Recolored(0x101, ARMOR_LUT) != 1; i++)
    {
        Sleep(1);
        Frames(1);
    }
    CHECK_EQ(Recolored(0x101, ARMOR_LUT), 1);
    vpm_fail(fake_component(0), "test stop");
    CHECK(myc_g.worker.thread == NULL); /* joined */
    CHECK_EQ(Recolored(0x101, ARMOR_LUT), 0);
}

static void TheReaderClosesOnTheNextCheckWithoutAJob(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    CHECK(g_pipeline.open && myc_g.has_reader_kept); /* not closed on the frame of the apply: due */
    SetOption("match_materials", 1); /* a job before the binding check takes the reader as it is */
    Frames(4);
    CHECK_EQ(C.jobs, 2);
    CHECK(g_pipeline.open && myc_g.has_reader_kept && !myc_g.job);
    Frames(MYC_CHECK_FRAMES);
    CHECK(!g_pipeline.open && !myc_g.has_reader_kept); /* closed by the next binding check without a job (on the worker) */
}

static uintptr_t g_ui;

/* The UiPreviewSystem (preview.lua; Fake.show_ui): player slot `slot` showing helmet and armor on unit `unit`, or none. */
static void ShowUi(int slot, int shown, uint32_t helmet, uint32_t armor, uint32_t unit)
{
    if (g_ui == 0)
    {
        g_ui = Heap(50456 + 64);
        Put64(fake_game() + 0x347CE60u, g_ui);
    }
    uintptr_t record = g_ui + 49160 + 160 * (uintptr_t)slot;
    uint32_t mask = Get32(g_ui + 50444);
    mask = shown ? mask | 1u << slot : mask & ~(1u << slot);
    Put32(g_ui + 50444, mask);
    uint32_t count = 0;
    for (int b = 0; b < 8; b++) count += (mask >> b) & 1u;
    Put32(g_ui + 50440, count);
    for (int o = 12; o <= 128; o += 4) Put32(record + (uintptr_t)o, 0);
    if (!shown) return;
    Put32(record + 136, 0);
    Put32(record + 140, armor);
    Put32(record + 144, helmet);
    Put32(record + 148, CAPE);
    Put32(record + 12, unit);
}

static void TheUiPreviewTakesItsOwnPlan(void)
{
    Boot(1, 1, HELMET, 1);
    g_ui = 0;
    ShowUi(1, 0, 0, 0, 0);
    Frames(4);
    CHECK_LOG("Local Helldiver: avatar 0, helmet a5574ac2, armor 0ade6719, body 0, UI preview slot 1.");
    int gate = 0, others = 0;
    for (int i = 0; i < 40; i++)
    {
        Calls f = Frame();
        uint32_t base = f.reads; /* the units, +2 on a check frame, +1 on a UI gate frame */
        if (base == 2 || base == 4) gate++;
        else if (base != 1 && base != 3) others++;
    }
    CHECK(gate >= 9 && gate <= 11 && others == 0); /* the preview's 16-byte gate on 1 frame in 4 while it is hidden */
    Unit(0x300, HELMET_LUT);
    ShowUi(1, 1, 0x0b0b0b0bu, ARMOR, 0x300);
    Frames(8);
    CHECK(C.last.target == MYC_TARGET_UI && C.last.helmet == 0x0b0b0b0bu && C.last.armor == ARMOR);
    CHECK_EQ(Recolored(0x300, HELMET_LUT), 1);
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1); /* the Helldiver keeps its own */
    CHECK(Bound(0x300, 0) != Bound(0x100, 0));
    CHECK_LOG("Preview recolored: 2 materials (helmet 0b0b0b0b, armor 0ade6719; job ");
    CHECK(g_pipeline.open && myc_g.has_reader_kept);
    Frames(MYC_CHECK_FRAMES + 1);
    CHECK(g_pipeline.open); /* kept past a binding check while the preview is shown */
    int jobs = C.jobs;
    Unit(0x301, HELMET_LUT);
    Put32(g_ui + 49160 + 160 + 12, 0x301); /* new units of the same pair: the same plan, no job */
    Frames(2);
    CHECK_EQ(C.jobs, jobs);
    CHECK_EQ(Recolored(0x301, HELMET_LUT), 1);
    ShowUi(1, 0, 0, 0, 0);
    Frames(4);
    CHECK_EQ(Recolored(0x300, HELMET_LUT), 0);
    CHECK_EQ(Recolored(0x301, HELMET_LUT), 0);
    CHECK(!g_pipeline.open && !myc_g.has_reader_kept); /* closed with the preview */
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
}

static void TheCacheIsSavedAfterTheDelay(void)
{
    Boot(1, 1, HELMET, 1);
    C.dirty = 1;
    g_pipeline.has_header = 1;
    snprintf(g_pipeline.header, sizeof g_pipeline.header, "MYCCACHE test");
    wcscpy(g_pipeline.cache_path, L"test-save.cache");
    DeleteFileW(L"test-save.cache");
    Frames(4);
    CHECK(myc_g.has_save_at);
    Frames(MYC_SAVE_DELAY_FRAMES - 10);
    CHECK_NO_LOG("Analysis cache saved");
    Frames(20);
    CHECK_LOG("Analysis cache saved (");
    CHECK(!myc_g.has_save_at && !g_pipeline.dirty);
    uint8_t* text = NULL;
    size_t size = 0;
    CHECK(myc_cache_read(L"test-save.cache", &text, &size) && size > 0 && memcmp(text, "MYCCACHE test\n", 14) == 0);
    free(text);
    DeleteFileW(L"test-save.cache");
}

static void HideCapeHidesYourCape(void)
{
    Boot(1, 1, HELMET, 1);
    Frames(4);
    uintptr_t mesh = E.units[FindUnit(0x106)].mesh;
    CHECK_EQ(*(uint8_t*)(mesh + 0xDC), 0xFF);
    SetOption("hide_cape", 2);
    CHECK_LOG("Option hide_cape = 2.");
    Frames(2);
    CHECK_EQ(*(uint8_t*)(mesh + 0xDC), 0);
    CHECK(strcmp(myc_g.sync_text, "v=1;m=2;f=35;s=0;") == 0); /* shared: squadmates with the mod hide it too */
    SetOption("hide_cape", 1);
    Frames(2);
    CHECK_EQ(*(uint8_t*)(mesh + 0xDC), 0xFF);
    CHECK(strcmp(myc_g.sync_text, SHARED) == 0);
}

/* ---- tests: Sync With Mod Users (test_sync.lua) ---------------------------------------------------------------------- */

static struct
{
    uintptr_t array, remote_value, legacy_value;
    int members, properties, posts, fail_post;
    uintptr_t post_user;
    uint64_t post_lobby;
    char posted[2][128];
} L;

static int32_t LobbyMembers(uint64_t lobby, uint32_t* count, const MycEntityKey** members)
{
    L.members++;
    *count = 2;
    *members = (const MycEntityKey*)L.array;
    return 0;
}

static int32_t LobbyProperty(uint64_t lobby, const MycEntityKey* member, const char* key, const char** value)
{
    L.properties++;
    int remote = (uintptr_t)member == L.array + 16;
    uintptr_t text = !remote ? 0 : strcmp(key, MYC_SYNC_KEY2) == 0 ? L.remote_value : L.legacy_value;
    *value = (const char*)text;
    return 0;
}

static int32_t LobbyPost(uint64_t lobby, const MycEntityKey* user, const void* lobby_update, const MycMemberUpdate* update, void* context)
{
    L.posts++;
    L.post_user = (uintptr_t)user;
    L.post_lobby = lobby;
    for (uint32_t i = 0; i < 2 && i < update->count; i++)
        snprintf(L.posted[i], sizeof L.posted[i], "%s", update->values[i] != NULL ? update->values[i] : "");
    return L.fail_post ? (int32_t)0x80004005 : 0;
}

/* The squad's PlayFab lobby (Fake.lobby): joined, handle 0xfedcba9889abcdef, the local member and the remote one. */
static void MakeLobby(const char* remote_value, const char* legacy_value)
{
    memset(&L, 0, sizeof L);
    uintptr_t context = Heap(0x1D480), engine = Heap(0x20), playfab = Heap(0x200);
    Put64(fake_game() + CONTEXT_RVA, context);
    Put64(context + 0x1D470, engine);
    Put64(engine + 0x10, playfab);
    Put32(playfab + 0x118, 3);
    Put32(playfab + 0x120, 0x89abcdefu);
    Put32(playfab + 0x124, 0xfedcba98u);
    uintptr_t type = Text("title_player_account");
    Put64(playfab + 0x130, Text(LOCAL_ID));
    Put64(playfab + 0x138, type);
    L.array = Heap(32);
    Put64(L.array, Text(LOCAL_ID));
    Put64(L.array + 8, type);
    Put64(L.array + 16, Text(REMOTE_ID));
    Put64(L.array + 24, type);
    L.remote_value = remote_value != NULL ? Text(remote_value) : 0;
    L.legacy_value = legacy_value != NULL ? Text(legacy_value) : 0;
    fake_export("PlayFabMultiplayerWin.dll", "PFLobbyPostUpdate", (void*)LobbyPost);
    fake_export("PlayFabMultiplayerWin.dll", "PFLobbyGetMembers", (void*)LobbyMembers);
    fake_export("PlayFabMultiplayerWin.dll", "PFLobbyGetMemberProperty", (void*)LobbyProperty);
}

static void SyncValuesRoundTrip(void)
{
    for (int mode = 1; mode <= 4; mode++)
        for (int flags = 0; flags < 64; flags++)
        {
            static const int schemes[] = {0, 1, 5, 12};
            for (int k = 0; k < 4; k++)
            {
                MycSettings o, back;
                memset(&o, 0, sizeof o);
                o.mode = mode;
                o.scheme = schemes[k];
                o.keep_sets = flags & 1;
                o.recolor_hoods = (flags >> 1) & 1;
                o.match_materials = (flags >> 2) & 1;
                o.recolor_cape = (flags >> 3) & 1;
                o.recolor_weapons = (flags >> 4) & 1;
                o.cape_hidden = (flags >> 5) & 1;
                char text[128], expected[128], legacy[64], expected_legacy[64];
                myc_sync_encode(&o, text, sizeof text);
                snprintf(expected, sizeof expected, "v=1;m=%d;f=%d;s=%d;", mode, flags, o.scheme);
                CHECK(strcmp(text, expected) == 0);
                CHECK(myc_sync_decode(text, &back) && back.mode == mode && back.scheme == o.scheme && back.keep_sets == o.keep_sets
                      && back.recolor_hoods == o.recolor_hoods && back.match_materials == o.match_materials
                      && back.recolor_cape == o.recolor_cape && back.recolor_weapons == o.recolor_weapons && back.cape_hidden == o.cape_hidden);
                myc_sync_legacy(&o, legacy, sizeof legacy);
                snprintf(expected_legacy, sizeof expected_legacy, "1|%d|%d|%d", mode, flags % 16, o.scheme);
                CHECK(strcmp(legacy, expected_legacy) == 0);
                CHECK(myc_sync_decode(legacy, &back) && back.mode == mode && !back.recolor_weapons && !back.cape_hidden
                      && back.keep_sets == o.keep_sets && back.recolor_cape == o.recolor_cape);
            }
        }
    MycSettings o;
    CHECK(myc_sync_decode("s=5;x=hello;f=1104;m=3;v=1;zz_9=;", &o) && o.mode == 3 && o.scheme == 5 && o.recolor_weapons
          && !o.keep_sets && !o.recolor_cape);
    CHECK(myc_sync_decode("v=1;m=2;", &o) && o.mode == 2 && o.scheme == 0 && !o.recolor_weapons && !o.keep_sets);
    static const char* const bad[] = {"v=2;m=2;f=3;s=0;", "m=2;f=3;s=0;", "v=1;f=3;s=0;", "v=1;m=5;f=3;s=0;", "v=1;m=0;",
        "v=1;m=2;f=3;s=65;", "v=1;m=2;f=-1;", "v=1;m=2;f=3.5;", "v=1;m=2;f=x;", "v=1;m=2;f=3;s=0", "v=1;m=2;f=3;s",
        "v=1;m=2;;", "v=1;m=2;f==3;", "=1;m=2;", " v=1;m=2;", "v=1;m=2.5;", "v=1;m=2;f=4294967296;", "", "v=1|m=2",
        "2|2|3|0", "1|0|3|0", "1|5|3|0", "1|2|16|0", "1|2|3|65", "1|2|3", "1|2|3|0|9", " 1|2|3|0", "1|2|3|x", "1|-2|3|0"};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
        if (myc_sync_decode(bad[i], &o)) { CHECK(!"refused"); printf("    accepted: %s\n", bad[i]); }
    char repeated[160] = "";
    for (int i = 0; i < 32; i++) strcat(repeated, "v=1;");
    CHECK(!myc_sync_decode(repeated, &o));
    uint32_t low, high;
    CHECK(myc_sync_peer_of(LOCAL_ID, &low, &high) && low == 0x5eed0001u && high == 0x00c0ffeeu);
    CHECK(myc_sync_peer_of(REMOTE_ID, &low, &high) && low == 0x1234u && high == 0);
    CHECK(!myc_sync_peer_of("xyz", &low, &high) && !myc_sync_peer_of("12345678901234567", &low, &high));
}

static void AnotherModUserIsRecoloredAndTheValueShared(void)
{
    Boot(1, 1, HELMET, 1);
    MakeLobby(SHARED, LEGACY);
    Frames(8);
    CHECK_LOG("Sync: 0000000000001234 recolored, 2 materials (shared settings).");
    CHECK(C.last.target == MYC_TARGET_REMOTE && strcmp(C.last.key, "0000000000001234") == 0 && C.last.helmet == REMOTE_HELMET
          && C.last.armor == REMOTE_ARMOR && C.last.body == 0 && C.last.mode == MYC_HELMET_FROM_ARMOR && C.last.keep_sets
          && !C.last.keep_hoods && !C.last.materials);
    CHECK_EQ(Recolored(0x200, HELMET_LUT), 1);
    CHECK(Bound(0x200, 0) != Bound(0x100, 0)); /* a texture of its own; the local helmet keeps its own */
    CHECK_EQ(Recolored(0x100, HELMET_LUT), 1);
    int polls = 0, quiet = 1;
    for (int i = 0; i < 1200; i++)
    {
        int members = L.members;
        Calls f = Frame();
        if (L.members != members) polls++;
        else quiet &= f.exports == 0;
    }
    CHECK(polls >= 9 && polls <= 10);
    CHECK(quiet);
    CHECK_EQ(L.posts, 1);
    CHECK(strcmp(L.posted[0], SHARED) == 0 && strcmp(L.posted[1], LEGACY) == 0);
    CHECK(L.post_user == L.array && L.post_lobby == 0xfedcba9889abcdefull);
    CHECK_LOG("Sync: shared " SHARED ".");
    SetOption("match_materials", 1);
    Frames(100);
    SetOption("paint_scheme", 6);
    Frames(600);
    CHECK_EQ(L.posts, 2);
    CHECK(strcmp(L.posted[0], "v=1;m=2;f=7;s=5;") == 0 && strcmp(L.posted[1], "1|2|7|5") == 0);
}

static void APlayerWithoutTheModKeepsTheirColors(void)
{
    Boot(1, 1, HELMET, 1);
    MakeLobby(NULL, NULL);
    Frames(8);
    int before = L.properties;
    Frames(120);
    CHECK_EQ(L.properties - before, 2); /* two lookups a poll: cbmyc2, then cbmyc */
    CHECK_EQ(Recolored(0x200, HELMET_LUT), 0);
    Boot(1, 1, HELMET, 1);
    MakeLobby(NULL, "1|2|5|0");
    Frames(8);
    CHECK_EQ(Recolored(0x200, HELMET_LUT), 1); /* a v1.3-v1.4 squadmate, with its older copy's settings */
    CHECK(C.last.target == MYC_TARGET_REMOTE && C.last.keep_sets && C.last.keep_hoods && C.last.materials);
}

static void RecolorSquadmatesGivesYourSettings(void)
{
    Boot(1, 1, HELMET, 1);
    MakeLobby(NULL, NULL);
    SetOption("recolor_squadmates", 2);
    SetOption("mode", 3);
    Frames(12);
    CHECK_EQ(Recolored(0x200, HELMET_LUT), 0); /* Armor Matches Helmet: their armor is the target, their helmet kept */
    CHECK(C.last.target == MYC_TARGET_REMOTE && C.last.mode == MYC_ARMOR_FROM_HELMET && C.last.helmet == REMOTE_HELMET);
    CHECK_LOG("Sync: 0000000000001234 recolored");
}

/* ---- tests: the disk cache (test_cache.lua) --------------------------------------------------------------------------- */

static MycPiece kCachePieces[2];
static MycAPiece kCacheAPieces[2];
static MycMaterial kCacheMaterials[3];
static MycRow kCacheRow;
static float kLutValues[23 * 8 * 4];
static float kPatternValues[12] = {0.668f, 0.625f, 0.195f, 0, 0, 0, 0, 1, 0, 0, 0, 0.3f};
static MycLut kLuts[2] = {{kLutValues, 23, 8}, {kPatternValues, 3, 1}};
static MycNamedLut kNamedLuts[2];
static MycPatternArea kPatternArea = {0xddddddddddddddddull, 0.012345678901234567};

static void CacheKit(MycKit* kit, MycAnalysis* a, uint32_t id, float fill)
{
    memset(kit, 0, sizeof *kit);
    memset(a, 0, sizeof *a);
    kCachePieces[0] = (MycPiece){.path = 0xaaaaaaaaaaaaaaaaull, .slot = 0, .type = 0, .body = 3, .lut = 0, .tone = 0};
    kCachePieces[1] = (MycPiece){.path = 0xbbbbbbbbbbbbbbbbull, .slot = 2, .type = 1, .body = 0, .lut = 0xccccccccccccccccull, .tone = 2};
    kit->id = id;
    kit->type = MYC_ARMOR;
    kit->archive = 0x0123456789abcdefull;
    kit->pieces = kCachePieces;
    kit->npieces = 2;
    for (int i = 0; i < 23 * 8 * 4; i++) kLutValues[i] = fill + (float)i / 3.0f;
    kCacheRow = (MycRow){.key = "cccccccccccccccc:3", .lut = 0xccccccccccccccccull, .row = 3, .area = 0.1 / 3, .under = 1.0 / 7,
                         .L = 42.123456789012345, .a = -3.25e-7, .b = 17.5, .metal = 1, .camo = 0, .mode = 2.5, .full = 1,
                         .ar = 0.123456789012345, .ag = 1.0 / 3, .ab = 2.5e-5, .emissive = 0.0099945068359375};
    kCacheAPieces[0] = (MycAPiece){.piece = kCachePieces[0], .skin = 0, .materials = kCacheMaterials, .nmaterials = 2};
    kCacheAPieces[1] = (MycAPiece){.piece = kCachePieces[1], .skin = 1, .materials = kCacheMaterials + 2, .nmaterials = 1};
    kNamedLuts[0] = (MycNamedLut){0xccccccccccccccccull, &kLuts[0]};
    kNamedLuts[1] = (MycNamedLut){0xddddddddddddddddull, &kLuts[1]};
    a->kit = kit;
    a->body = 0;
    a->rows = &kCacheRow;
    a->nrows = 1;
    a->pieces = kCacheAPieces;
    a->npieces = 2;
    a->luts = kNamedLuts;
    a->nluts = 2;
    a->patterns = &kPatternArea;
    a->npatterns = 1;
}

static void CacheRoundTrip(void)
{
    MycKit kit;
    MycAnalysis a;
    CacheKit(&kit, &a, 0x0ade6719u, 0.25f);
    char header[512], key[MYC_ENTRY_KEY];
    myc_cache_header("56:14545923", header, sizeof header);
    myc_cache_key(&kit, 0, key, sizeof key);
    MycCacheEntry entry;
    snprintf(entry.key, sizeof entry.key, "%s", key);
    entry.analysis = &a;
    MycBuf text = {0};
    CHECK(myc_cache_encode(&text, header, &entry, 1, NULL));
    MycArena arena = {0};
    MycSamples samples;
    MycCacheDecoded d = {NULL, 0, &samples, 1};
    char why[128] = "";
    CHECK(myc_cache_decode((const uint8_t*)text.data, text.size, header, &arena, &d, why, sizeof why));
    CHECK(d.n == 1 && strcmp(d.entries[0].key, key) == 0 && !d.has_samples);
    const MycAnalysis* b = d.n == 1 ? d.entries[0].analysis : NULL;
    CHECK(b != NULL && b->kit->id == 0x0ade6719u && b->kit->type == MYC_ARMOR && b->kit->archive == 0x0123456789abcdefull && b->body == 0);
    if (b != NULL && b->nrows == 1)
    {
        const MycRow* r = &a.rows[0];
        const MycRow* s = &b->rows[0];
        CHECK(strcmp(r->key, s->key) == 0 && r->lut == s->lut && r->row == s->row && r->area == s->area && r->under == s->under
              && r->L == s->L && r->a == s->a && r->b == s->b && r->metal == s->metal && r->camo == s->camo && r->mode == s->mode
              && r->full == s->full && r->ar == s->ar && r->ag == s->ag && r->ab == s->ab && r->emissive == s->emissive);
    }
    else CHECK(!"one row");
    if (b != NULL)
    {
        CHECK(b->npieces == 2 && b->pieces[0].piece.slot == 0 && b->pieces[1].piece.type == 1 && b->pieces[1].skin
              && b->pieces[0].nmaterials == 2);
        const MycLut* lut = myc_analysis_lut(b, 0xccccccccccccccccull);
        CHECK(lut != NULL && lut->width == 23 && lut->height == 8 && memcmp(lut->values, kLutValues, sizeof kLutValues) == 0);
        const MycLut* texture = myc_analysis_lut(b, 0xddddddddddddddddull);
        CHECK(texture != NULL && texture->width == 3 && texture->height == 1 && memcmp(texture->values, kPatternValues, sizeof kPatternValues) == 0);
        CHECK(b->npatterns == 1 && b->patterns[0].pattern == 0xddddddddddddddddull && b->patterns[0].area == kPatternArea.area);
    }
    /* another build or data, a damaged file, an unknown record, a bad number, a format 12 file, no file */
    char other[512];
    myc_cache_header("57:14545923", other, sizeof other);
    MycArena scratch = {0};
    CHECK(!myc_cache_decode((const uint8_t*)text.data, text.size, other, &scratch, &d, why, sizeof why));
    CHECK(!myc_cache_decode((const uint8_t*)text.data, text.size - 100, header, &scratch, &d, why, sizeof why));
    char* copy = malloc(text.size + 1);
    memcpy(copy, text.data, text.size);
    copy[text.size] = 0;
    char* record = strstr(copy, "\nR ");
    if (record != NULL) record[1] = 'X';
    CHECK(record != NULL && !myc_cache_decode((const uint8_t*)copy, text.size, header, &scratch, &d, why, sizeof why));
    memcpy(copy, text.data, text.size);
    char* old = strstr(copy, "MYCCACHE 13 ");
    if (old != NULL) memcpy(old, "MYCCACHE 12 ", 12);
    CHECK(old != NULL && !myc_cache_decode((const uint8_t*)copy, text.size, header, &scratch, &d, why, sizeof why));
    CHECK(!myc_cache_decode((const uint8_t*)"", 0, header, &scratch, &d, why, sizeof why));
    free(copy);
    myc_buf_free(&text);
    myc_arena_free(&arena);
    myc_arena_free(&scratch);
}

static void CacheKeepsTheMostRecentEntries(void)
{
    static MycKit kits[MYC_CACHE_MAX_ENTRIES + 5];
    static MycAnalysis analyses[MYC_CACHE_MAX_ENTRIES + 5];
    static MycCacheEntry entries[MYC_CACHE_MAX_ENTRIES + 5];
    char header[512];
    myc_cache_header("56:14545923", header, sizeof header);
    for (int i = 0; i < MYC_CACHE_MAX_ENTRIES + 5; i++)
    {
        CacheKit(&kits[i], &analyses[i], (uint32_t)i + 1, 0);
        kits[i].pieces_sum[0] = 0;
        myc_cache_key(&kits[i], 0, entries[i].key, sizeof entries[i].key);
        entries[i].analysis = &analyses[i];
    }
    MycBuf text = {0};
    CHECK(myc_cache_encode(&text, header, entries, MYC_CACHE_MAX_ENTRIES + 5, NULL));
    MycArena arena = {0};
    MycSamples samples;
    MycCacheDecoded back = {NULL, 0, &samples, 0};
    char why[128];
    CHECK(myc_cache_decode((const uint8_t*)text.data, text.size, header, &arena, &back, why, sizeof why));
    CHECK(back.n == MYC_CACHE_MAX_ENTRIES && strcmp(back.entries[0].key, entries[0].key) == 0);
    myc_buf_free(&text);
    myc_arena_free(&arena);
}

static void CacheKeys(void)
{
    MycKit kit;
    MycAnalysis a;
    CacheKit(&kit, &a, 7, 0);
    char key[MYC_ENTRY_KEY], body[MYC_ENTRY_KEY], again[MYC_ENTRY_KEY], changed[MYC_ENTRY_KEY];
    myc_cache_key(&kit, 0, key, sizeof key);
    myc_cache_key(&kit, 1, body, sizeof body);
    CHECK(strcmp(key, body) != 0);
    MycKit same = kit;
    same.pieces_sum[0] = 0;
    myc_cache_key(&same, 0, again, sizeof again);
    CHECK(strcmp(key, again) == 0);
    MycPiece pieces[2] = {kCachePieces[0], kCachePieces[1]};
    pieces[1].lut = 0xddddddddddddddddull;
    MycKit other = kit;
    other.pieces = pieces;
    other.pieces_sum[0] = 0;
    myc_cache_key(&other, 0, changed, sizeof changed);
    CHECK(strcmp(key, changed) != 0);
    /* made once per kit: a kit's pieces never change once read */
    pieces[1].lut = 0xeeeeeeeeeeeeeeeeull;
    myc_cache_key(&other, 0, again, sizeof again);
    CHECK(strcmp(changed, again) == 0);
}

static void CacheWritesThroughATemporaryFile(void)
{
    const wchar_t* path = L"test-cache.tmpfile";
    char why[128];
    CHECK(myc_cache_write(path, (const uint8_t*)"abc\n", 4, why, sizeof why));
    uint8_t* text = NULL;
    size_t size = 0;
    CHECK(myc_cache_read(path, &text, &size) && size == 4 && memcmp(text, "abc\n", 4) == 0);
    free(text);
    CHECK(myc_cache_write(path, (const uint8_t*)"second\n", 7, why, sizeof why));
    CHECK(myc_cache_read(path, &text, &size) && size == 7 && memcmp(text, "second\n", 7) == 0);
    free(text);
    DeleteFileW(path);
    CHECK(!myc_cache_read(path, &text, &size));
}

int main(void)
{
    RUN(RegistersTheLuaOptions);
    RUN(SavedOptionsAreLoggedAsChanges);
    RUN(WaitsForTheEngineScriptApi);
    RUN(StopsWhenAnEngineFunctionChanged);
    RUN(TitleScreenResolvesEvery15Frames);
    RUN(ALoadingWorldPreparesThePipelineOnce);
    RUN(KitsKnownBeforeTheHelldiverArePrepared);
    RUN(NothingAheadWhileNothingIsRecolored);
    RUN(StandInKitsAreNotPrepared);
    RUN(TheLocalHelmetTakesThePlan);
    RUN(IdleFramesReadOnce);
    RUN(OffReadsTheUnitsOnly);
    RUN(AReEquipStartsAJob);
    RUN(ARespawnBindsTheSamePlanWithoutAJob);
    RUN(ARecomposedRecordStartsAJob);
    RUN(OptionsStartJobs);
    RUN(CompleteSetsKeepTheirColors);
    RUN(FailuresAreCountedToThree);
    RUN(TheGamePuttingTheOriginalBackIsSeen);
    RUN(StopPutsTheOriginalsBack);
    RUN(JobsRunOnTheWorkerThread);
    RUN(TheReaderClosesOnTheNextCheckWithoutAJob);
    RUN(TheUiPreviewTakesItsOwnPlan);
    RUN(TheCacheIsSavedAfterTheDelay);
    RUN(HideCapeHidesYourCape);
    RUN(SyncValuesRoundTrip);
    RUN(AnotherModUserIsRecoloredAndTheValueShared);
    RUN(APlayerWithoutTheModKeepsTheirColors);
    RUN(RecolorSquadmatesGivesYourSettings);
    RUN(CacheRoundTrip);
    RUN(CacheKeepsTheMostRecentEntries);
    RUN(CacheKeys);
    RUN(CacheWritesThroughATemporaryFile);
    TEST_END();
}
