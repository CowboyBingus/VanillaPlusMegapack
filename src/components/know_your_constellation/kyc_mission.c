/* Know Your Constellation's mission reader (mission.lua, with kyc_campaign.c): the forecast screen on top of the UI
 * stack, the highlighted mission's identity (a hosted operation, a joinable mission's advertisement, the briefing's
 * loaded mission) and the full forecast inputs, read the way the game resolves them. Every read lands in a buffer this
 * reader keeps (static), so neither the per-frame checks nor the 0.5 s sample allocate.
 *
 * On HellForge: game.dll's statics (the RVA globals and tables) are plain loads, which the Lua read with
 * ReadProcessMemory; heap records go through vpm_read (guarded plain loads). The difficulty settings row comes from
 * HellForge's moved table when it has one (HfApi.difficulty_row, once level 11 is added), else from the game's own table
 * at 0x328D2A0, as the Lua read it; either way the row's level (+4) must be the mission's. A mission at level 11 is
 * accepted once HellForge has added that level (the Lua refused every difficulty above 10). */
#include <stdio.h>
#include "kyc_mission.h"

#define NOT_READY "Mission descriptor not ready"
#define NO_MISSION "No highlighted mission"
#define NO_BRIEFING "Briefing descriptor unavailable"
#define NO_OWNER "Briefing owner unavailable"
#define UI_STACK 0x429Cu
#define ROOT_CONTROLLER 0xAE288u
#define ROOT_PACKET 713400u           /* the single preview slot's canonical packet (512 bytes) */
#define BOARD_SELECTION 1548964u      /* the hovered joinable mission: id, group */
#define BOARD_PREVIEW_GATE 2064401u
#define BOARD_JOINABLE_COUNT 2053224u
#define BOARD_JOINABLE_ROWS 2044424u  /* 20-byte rows: kind, index, group, id */
#define BOARD_PREVIEW_SLOT 4286668u
#define FALLBACK_SELECTION 5633600u
#define MENU_BRIEFINGS 26184u         /* the menu manager's owner rows: count, then 16-byte rows {pointer, kind} */
#define BRIEFING_KIND 235u
#define SETTINGS_SIZE 816u
#define MISSION_SIZE 896u
#define DESCRIPTOR_SIZE 200u

/* The advertised missions' three lists: {first record, count, capacity}, records of 1560 bytes. */
static const uint32_t kLayouts[4][3] = {{0, 0, 0}, {1097440, 1253440, 100}, {1253448, 1409448, 100}, {1409456, 1487456, 50}};
/* Descriptor bytes that make up a mission's identity: seed, secondary seed, faction, difficulty, planet, mission. */
static const uint8_t kIdentity[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 26, 27};
/* The settings row's candidate rows and fallbacks per faction (2 .. 4). */
static const uint32_t kCandidates[5] = {0, 0, 276, 372, 468};
static const uint32_t kFallbacks[5] = {0, 0, 564, 600, 636};
/* The HordeOnly tag's marker in a mission record (+0x360). */
static const uint8_t kHordeMarker[8] = {73, 120, 130, 127, 209, 44, 124, 133};

static struct
{
    uintptr_t kept_manager;    /* the UI manager the last screen() found: the idle gate reads its stack alone */
    KycKey key;                /* the key text is built again only when the identity changes */
    int has_key;
    uint32_t highest;          /* 11 once HellForge has added level 11 */
} s;

static uint8_t g_scratch[128], g_bulk[53248];
static uint8_t g_descriptor[DESCRIPTOR_SIZE], g_loaded[DESCRIPTOR_SIZE], g_recheck[DESCRIPTOR_SIZE];
static uint8_t g_advertised[512], g_packet[512], g_settings[SETTINGS_SIZE], g_config[MISSION_SIZE];

void kyc_mission_reset(void)
{
    memset(&s, 0, sizeof s);
    kyc_campaign_reset();
}

/* ---- reads --------------------------------------------------------------------------------------------------- */

int kyc_read(uintptr_t address, void* out, size_t capacity, size_t size)
{
    if (size == 0 || size > capacity) return kyc_fail("Mission read bound exceeded");
    return vpm_read(address, out, size) ? 1 : kyc_pending(KYC_DATA_UNAVAILABLE);
}

int kyc_static(uint32_t rva, void* out, size_t size)
{
    return vpm_game_read(rva, out, size) ? 1 : kyc_pending(KYC_DATA_UNAVAILABLE);
}

int kyc_ptr(uintptr_t address, uintptr_t* out)
{
    uint8_t b[8];
    if (!kyc_read(address, b, sizeof b, 8)) return 0;
    *out = kyc_pointer_at(b);
    return *out != 0 ? 1 : kyc_pending(KYC_POINTER_UNAVAILABLE);
}

int kyc_static_ptr(uint32_t rva, uintptr_t* out)
{
    uint8_t b[8];
    if (!kyc_static(rva, b, 8)) return 0;
    *out = kyc_pointer_at(b);
    return *out != 0 ? 1 : kyc_pending(KYC_POINTER_UNAVAILABLE);
}

int kyc_count(uintptr_t address, uint32_t maximum, uint32_t* out)
{
    uint8_t b[4];
    if (!kyc_read(address, b, sizeof b, 4)) return 0;
    *out = kyc_u32(b);
    return *out <= maximum ? 1 : kyc_fail("Mission array bound exceeded");
}

static int ReadU32(uintptr_t address, uint32_t* out)
{
    uint8_t b[4];
    if (!kyc_read(address, b, sizeof b, 4)) return 0;
    *out = kyc_u32(b);
    return 1;
}

static int ReadU8(uintptr_t address, uint8_t* out) { return kyc_read(address, out, 1, 1); }

/* ---- the screen ---------------------------------------------------------------------------------------------- */

/* The war table or the briefing when one is on top of the UI screen stack (15, 14), else none. */
static int TopScreen(const uint8_t* stack)
{
    uint32_t n = kyc_u32(stack + 20);
    if (n < 1 || n > 5) return KYC_SCREEN_NONE;
    uint32_t top = kyc_u32(stack + 4 * (n - 1));
    return top == 15 ? KYC_SCREEN_MAP : top == 14 ? KYC_SCREEN_BRIEFING : KYC_SCREEN_NONE;
}

/* No UI state yet (while the game starts) is no forecast screen, not an error. lint: per-frame */
static int Screen(int* screen)
{
    uint8_t b[8];
    *screen = KYC_SCREEN_NONE;
    if (!kyc_static(KYC_RVA_UI_MANAGER, b, 8)) return 0;
    uintptr_t manager = kyc_pointer_at(b);
    s.kept_manager = manager;
    if (manager == 0) return 1;
    if (!kyc_read(manager + UI_STACK, g_scratch, sizeof g_scratch, 24)) return 0;
    *screen = TopScreen(g_scratch);
    return 1;
}

/* The idle gate's one read: 1 when the kept manager's stack shows neither screen; 0 (the caller runs the full frame)
 * when no manager is kept, the read fails or a forecast screen is on top. Never an error. lint: per-frame */
static int Quiet(void)
{
    uint8_t stack[24];
    if (s.kept_manager == 0 || !vpm_read(s.kept_manager + UI_STACK, stack, sizeof stack)) return 0;
    return TopScreen(stack) == KYC_SCREEN_NONE;
}

/* ---- the identity -------------------------------------------------------------------------------------------- */

uint32_t kyc_highest_level(void)
{
    if (s.highest != 11) s.highest = vpm_hf()->difficulty_row(11) != 0 ? 11 : 10;
    return s.highest;
}

static int Identity(const uint8_t* b, KycKey* key)
{
    uint8_t faction = b[8], difficulty = b[9];
    if (faction < 2 || faction > 4 || difficulty < 1) return kyc_pending(NOT_READY);
    if (difficulty > 10 && (difficulty > 11 || kyc_highest_level() < 11)) return kyc_pending(NOT_READY);
    uint16_t mission = kyc_u16(b + 26);
    if (mission >= 256) return kyc_fail("Unknown mission type");
    uint32_t seed = kyc_u32(b), secondary = kyc_u32(b + 4), planet = kyc_u32(b + 12);
    KycKey* k = &s.key;
    if (!s.has_key || k->seed != seed || k->secondary != secondary || k->faction != faction || k->difficulty != difficulty ||
        k->planet != planet || k->mission != mission)
    {
        k->seed = seed;
        k->secondary = secondary;
        k->faction = faction;
        k->difficulty = difficulty;
        k->planet = planet;
        k->mission = mission;
        snprintf(k->text, sizeof k->text, "%u:%u:%u:%u:%u:%u", seed, secondary, faction, difficulty, planet, mission);
        s.has_key = 1;
    }
    *key = *k;
    return 1;
}

/* A loaded descriptor matches when its identity bytes equal the selection's. */
static int SameIdentity(const uint8_t* a, const uint8_t* b)
{
    for (int i = 0; i < 16; i++)
        if (a[kIdentity[i]] != b[kIdentity[i]]) return 0;
    return 1;
}

/* Whether a and b hold the same NUL-terminated text at their start (an empty or unterminated text never matches). */
static int SameText(const uint8_t* a, const uint8_t* b, size_t size)
{
    const uint8_t* end = memchr(a, 0, size);
    if (end == NULL || end == a) return 0;
    size_t n = (size_t)(end - a);
    return memchr(b, 0, size) == b + n && memcmp(a, b, n) == 0;
}

/* ---- the war table's selection -------------------------------------------------------------------------------- */

/* The hovered joinable mission: the native map lookup (0x1036670 / 0x1036710), with the controller's fallback. */
static int JoinableSelection(uintptr_t board, uint32_t* id, uint32_t* group)
{
    uint8_t selection[8];
    if (!kyc_read(board + BOARD_SELECTION, selection, sizeof selection, 8)) return 0;
    *id = kyc_u32(selection);
    *group = kyc_u32(selection + 4);
    if (*id < 0x80000000u && *group != 0) return 1;
    uintptr_t session;
    uint8_t fallback[12];
    if (!kyc_static_ptr(KYC_RVA_FALLBACK, &session) ||
        !kyc_read(session + FALLBACK_SELECTION, fallback, sizeof fallback, 12))
        return 0;
    if (*id >= 0x80000000u) *id = kyc_u32(fallback);
    if (*group == 0) *group = kyc_u32(fallback + 8);
    return 1;
}

/* The joinable list's row of a mission: its kind (the advertisement list) and index, or kind 0. */
static int JoinableRow(uintptr_t board, uint32_t total, uint32_t id, uint32_t group, uint32_t* kind, uint32_t* index)
{
    if (!kyc_read(board + BOARD_JOINABLE_ROWS, g_bulk, sizeof g_bulk, (size_t)total * 20)) return 0;
    *kind = *index = 0;
    int found = 0;
    for (uint32_t i = 0; i < total; i++)
    {
        const uint8_t* row = g_bulk + i * 20;
        if (kyc_u32(row + 8) != group || kyc_u32(row + 12) != id) continue;
        if (found) return kyc_fail("Ambiguous joinable mission");
        found = 1;
        *kind = kyc_u32(row);
        *index = kyc_u32(row + 4);
    }
    return 1;
}

/* The advertisement's packet is the one the native preview builder loaded into the single preview slot. */
static int PreviewLoaded(uintptr_t board, uintptr_t root, uintptr_t record, int* loaded)
{
    uint8_t valid;
    uint32_t slot;
    *loaded = 0;
    if (!ReadU8(record + 1456, &valid)) return 0;
    if (valid == 0) return 1;
    if (!kyc_read(record + 944, g_advertised, sizeof g_advertised, 512) || !ReadU32(board + BOARD_PREVIEW_SLOT, &slot)) return 0;
    if (slot != 0) return 1;
    if (!kyc_read(root + ROOT_PACKET, g_packet, sizeof g_packet, 512)) return 0;
    *loaded = SameText(g_advertised, g_packet, 512);
    return 1;
}

/* A joinable mission's preview: its planet when the advertisement, the cached preview and the selection agree.
 * *hovered tells an ended hover (0) from a selected mission whose packet or preview is still loading (1). */
static int JoinablePreview(uintptr_t board, uintptr_t root, int* found, uint32_t* planet, int* hovered)
{
    uint8_t gate;
    uint32_t id, group, total, kind, index, count;
    *found = 0;
    *hovered = 0;
    if (!ReadU32(board + KYC_BOARD_PREVIEW_PLANET, planet)) return 0;
    if (*planet >= 0x80000000u) return 1;
    if (!ReadU8(board + BOARD_PREVIEW_GATE, &gate)) return 0;
    if (gate == 0) return 1;
    if (!JoinableSelection(board, &id, &group)) return 0;
    if (id >= 0x80000000u || group == 0) return 1;
    *hovered = 1;
    if (!kyc_count(board + BOARD_JOINABLE_COUNT, 440, &total)) return 0;
    if (total == 0) return 1;
    if (!JoinableRow(board, total, id, group, &kind, &index)) return 0;
    if (kind < 1 || kind > 3) return 1;
    uintptr_t manager;
    if (!kyc_static_ptr(KYC_RVA_REMOTE, &manager) || !kyc_count(manager + kLayouts[kind][1], kLayouts[kind][2], &count)) return 0;
    if (index >= count) return 1;
    return PreviewLoaded(board, root, manager + kLayouts[kind][0] + (uintptr_t)index * 1560u, found);
}

/* The war table: the highlighted local operation, or the hovered joinable mission. */
static int MapSelection(KycDescriptor* d, int* found, int* hovered)
{
    uint32_t index;
    *found = 0;
    *hovered = KYC_HOVER_UNKNOWN;
    if (!ReadU32(d->board + KYC_BOARD_OPERATION, &index)) return 0;
    if (index == 0xFFFFFFFFu)
    {
        if (!JoinablePreview(d->board, d->root, found, &d->preview_planet, hovered)) return 0;
        d->has_preview = *found;
        return 1;
    }
    if (index >= 110) return kyc_pending(NO_MISSION);
    uint8_t selected[92];
    if (!kyc_read(d->board + KYC_BOARD_OPERATIONS + (uintptr_t)index * 92u, selected, sizeof selected, 92)) return 0;
    if (selected[52] == 0) return kyc_pending(NO_MISSION);
    d->has_operation = 1;
    d->operation_planet = kyc_u16(selected + 16);
    d->operation_index = index;
    *found = 1;
    return 1;
}

/* The briefing: the owner record of the loaded mission. */
static int BriefingAddress(uintptr_t* address)
{
    uintptr_t manager, selected = 0;
    uint32_t n;
    if (!kyc_static_ptr(KYC_RVA_MENU, &manager) || !kyc_count(manager + MENU_BRIEFINGS, 1024, &n)) return 0;
    if (n == 0) return kyc_pending(NO_BRIEFING);
    if (!kyc_read(manager + MENU_BRIEFINGS + 8, g_bulk, sizeof g_bulk, (size_t)n * 16)) return 0;
    int found = 0;
    for (uint32_t i = 0; i < n; i++)
    {
        if (kyc_u32(g_bulk + 16 * i + 8) != BRIEFING_KIND) continue;
        if (found) return kyc_fail("Ambiguous briefing owner");
        found = 1;
        selected = kyc_pointer_at(g_bulk + 16 * i);
        if (selected == 0) return kyc_pending(NO_OWNER);
    }
    if (!found) return kyc_pending(NO_OWNER);
    *address = selected + 1072;
    return 1;
}

/* The selected mission's identity and the records a sample reads. lint: per-frame */
static int Descriptor(int screen, KycDescriptor* out, int* found, int* hovered)
{
    KycDescriptor d;
    memset(&d, 0, sizeof d);
    *found = 0;
    *hovered = KYC_HOVER_UNKNOWN;
    if (!kyc_static_ptr(KYC_RVA_ROOT, &d.root) || !kyc_ptr(d.root + ROOT_CONTROLLER, &d.controller) ||
        !kyc_static_ptr(KYC_RVA_BOARD, &d.board))
        return 0;
    d.address = d.board + KYC_BOARD_DESCRIPTOR;
    if (screen == KYC_SCREEN_BRIEFING)
    {
        if (!BriefingAddress(&d.address)) return 0;
    }
    else
    {
        int selected;
        if (!MapSelection(&d, &selected, hovered)) return 0;
        if (!selected) return 1;
    }
    if (!kyc_read(d.address, g_descriptor, sizeof g_descriptor, DESCRIPTOR_SIZE) || !Identity(g_descriptor, &d.key)) return 0;
    /* The native modifier and stamp path consumes the loaded controller: a stale one cannot authorize a forecast. */
    if (!kyc_read(d.controller + 8, g_loaded, sizeof g_loaded, DESCRIPTOR_SIZE)) return 0;
    d.controller_matches = SameIdentity(g_descriptor, g_loaded);
    d.screen = screen;
    *out = d;
    *found = 1;
    return 1;
}

/* ---- settings and the mission record ----------------------------------------------------------------------- */

int kyc_difficulty_row(uint32_t level, uint8_t* row)
{
    uintptr_t moved = level >= 1 && level <= 11 ? vpm_hf()->difficulty_row(level) : 0;
    if (moved != 0)
    {
        if (!kyc_read(moved, row, SETTINGS_SIZE, SETTINGS_SIZE)) return 0;
    }
    else if (level < 1 || level > 10) return kyc_fail("No settings row for difficulty %u", level);
    else if (!kyc_static(KYC_RVA_DIFFICULTY + (level - 1) * SETTINGS_SIZE, row, SETTINGS_SIZE)) return 0;
    return kyc_u32(row + 4) == level ? 1 : kyc_fail("Unexpected settings row for difficulty %u", level);
}

/* The constellation draw's settings: draws, eight weighted candidates, the fallback and its blockers. */
static int Settings(const KycDescriptor* d, KycSettings* out)
{
    const uint8_t* b = g_settings;
    if (!kyc_difficulty_row(d->key.difficulty, g_settings)) return 0;
    uint32_t start = kCandidates[d->key.faction], fallback = kFallbacks[d->key.faction];
    memset(out, 0, sizeof *out);
    out->draws = kyc_u32(b + 272);
    if (!kyc_from_native(kyc_u32(b + fallback + 32), &out->fallback)) return 0;
    for (int i = 0; i < 8; i++)
    {
        uint32_t at = start + (uint32_t)i * 12;
        KycCandidate* row = &out->candidates[i];
        if (!kyc_from_native(kyc_u32(b + at), &row->id)) return 0;
        row->weight = kyc_f32(b + at + 4);
        row->only_when_empty = b[at + 8] != 0;
        if (!kyc_from_native(kyc_u32(b + fallback + (uint32_t)i * 4), &out->blockers[i])) return 0;
    }
    out->blocker_count = 8;
    return 1;
}

/* Build 25480438's mission records: a conditional additional tag (HordeOnly) and eight exclusions. */
static int HordeMode(const uint8_t* config)
{
    return config[0x34] == 2 && memcmp(config + 0x360, kHordeMarker, sizeof kHordeMarker) == 0;
}

static int MissionExclusions(const uint8_t* config, uint32_t* excluded)
{
    *excluded = 0;
    for (int i = 0; i < 8; i++)
    {
        uint32_t native = kyc_u32(config + 0x14 + 4 * i);
        uint8_t tag;
        if (native == 0) continue;
        if (!kyc_from_native(native, &tag)) return 0;
        *excluded |= 1u << tag;
    }
    return 1;
}

/* The highlighted preview planet or local operation is still the one read. */
static int SameHighlight(const KycDescriptor* d, int* same)
{
    uint32_t value;
    uint8_t planet[2];
    *same = 0;
    if (d->has_preview)
    {
        if (!ReadU32(d->board + KYC_BOARD_PREVIEW_PLANET, &value)) return 0;
        if (value != d->preview_planet) return 1;
    }
    if (d->has_operation)
    {
        if (!ReadU32(d->board + KYC_BOARD_OPERATION, &value)) return 0;
        if (value != d->operation_index) return 1;
        if (!kyc_read(d->board + KYC_BOARD_OPERATIONS + 92u * d->operation_index + 16, planet, sizeof planet, 2)) return 0;
        if (kyc_u16(planet) != d->operation_planet) return 1;
    }
    *same = 1;
    return 1;
}

/* The selection, screen and highlighted operation are still the ones read. */
static int Unchanged(const KycDescriptor* d, int screen, int* same)
{
    int now;
    *same = 0;
    if (!kyc_read(d->address, g_recheck, sizeof g_recheck, DESCRIPTOR_SIZE)) return 0;
    if (memcmp(g_recheck, g_descriptor, DESCRIPTOR_SIZE) != 0) return 1;
    if (!Screen(&now)) return 0;
    return now == screen ? SameHighlight(d, same) : 1;
}

/* The tags of the sample: the draw, HordeOnly, the backend's disabled tags and the mission's exclusions. */
static int SampleTags(KycSnapshot* snap, const KycTags* initial, int* complete)
{
    KycSettings settings;
    KycTags drawn, tags;
    uint32_t disabled, excluded;
    if (!Settings(&snap->d, &settings) || !kyc_draw_base(snap->d.key.seed, &settings, initial, &drawn)) return 0;
    if (!kyc_static(KYC_RVA_MISSIONS + MISSION_SIZE * snap->d.key.mission, g_config, MISSION_SIZE)) return 0;
    if (HordeMode(g_config) && !kyc_tag_add(&drawn, 31)) return 0;
    *complete = kyc_disabled_tags(snap, &drawn, &disabled) && *complete;
    if (!MissionExclusions(g_config, &excluded) || !kyc_tag_filter(&drawn, excluded, disabled, &tags)) return 0;
    snap->tag_count = tags.count;
    memcpy(snap->tags, tags.tag, sizeof tags.tag);
    return 1;
}

/* The full forecast inputs. *found 0 when no mission is selected, or the selection changed while it was read. Runs
 * on the re-sample frames (every 0.5 s, 0.1 s while pending). lint: per-frame */
static int Sample(int screen, KycSnapshot* out, int* found)
{
    static KycTags initial;
    int hovered, same;
    KycSnapshot* snap = out;
    memset(snap, 0, sizeof *snap);
    if (!Descriptor(screen, &snap->d, found, &hovered)) return 0;
    if (!*found) return 1;
    *found = 0;
    if (!kyc_tag_hashes()) return 0;
    int complete = kyc_initial_tags(snap, &initial);
    if (!SampleTags(snap, &initial, &complete) || !Unchanged(&snap->d, screen, &same)) return 0;
    snap->complete = complete;
    *found = same;
    return 1;
}

static const KycReaders kReaders = {Screen, Quiet, Descriptor, Sample, kyc_presentation_sample};

const KycReaders* kyc_game_readers(void) { return &kReaders; }
