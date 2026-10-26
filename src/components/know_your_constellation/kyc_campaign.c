/* Know Your Constellation's campaign inputs (mission.lua, with kyc_mission.c): the hovered planet's campaign
 * modifiers (enemy tags and spawn-weight scales), the highlighted local operation's template modifiers, the global
 * modifiers and war effects in scope, the level's explicit and stamped tags, and the backend configuration's disabled
 * tags. Run on the 0.5 s sample only; each part that fails leaves the sample incomplete (its reason counted), as the
 * Lua's pcall around it did. */
#include <stdio.h>
#include "kyc_mission.h"

#define DEFS_COUNT 53248u              /* the definitions' count, after 1024 rows of 52 bytes */
#define CATEGORY_TAG 40u               /* a definition naming an enemy tag */
#define CATEGORY_WEIGHT 72u            /* one enemy family's groups' spawn weight (native group weight 0x94a0a0) */
#define CAMPAIGN_PLANETS 1197132u      /* board: planets with campaign data */
#define DATA_PLANET 495200u            /* campaign data: the active planet */
#define DATA_STATIC 280u               /* 280-byte static planet rows at data + 280 * planet */
#define DATA_DYNAMIC 286752u           /* 304-byte dynamic rows at data + 304 * planet + this */
#define DATA_MODIFIERS 286952u         /* the planet's modifier ids: 32, count at +128 */
#define DATA_ENVIRONMENTS 494696u      /* 44-byte rows */
#define DATA_ENVIRONMENT_COUNT 494868u
#define DATA_EVENTS 470104u            /* 2496-byte rows */
#define DATA_EVENT_COUNT 490072u
#define DATA_OPERATIONS 143384u        /* 24-byte rows {planet, id, template} */
#define DATA_OPERATION_COUNT 155672u
#define BOARD_TEMPLATES 0x1F8908u      /* operation templates: {values, keys, ..., count at +16} */
#define SESSION_GATE 92134u            /* read as a flag in six places on build 25480438 (92102 was an older build's) */
#define ROOT_GATE 4205u
#define ROOT_GATE_2 4217u
#define CONTROLLER_LEVEL 648u
#define LEVEL_EXPLICIT 9160276u
#define LEVEL_STAMPS 18510124u
#define LEVEL_SELECTION 9017008u
#define STAMP_TABLE 2915250090u

static uint32_t g_hashes[32];       /* the native tags' hashes, by native index */
static uint32_t g_hash_by_tag[32];  /* the hash of each authored tag */
static uint8_t g_rows[53248], g_static[280], g_dynamic[304], g_mods[1024], g_header[24], g_selection[168];

/* The modifier definitions: enemy tags by id (the last row of an id counts), spawn-weight scales by id (the last
 * counts) and the first id of each hash. */
static struct
{
    int tags, weights, hashes;
    uint32_t tag_id[1024];
    uint8_t tag[1024];
    uint32_t weight_id[1024], weight_family[1024];
    double weight_factor[1024];
    uint32_t hash[1024], hash_id[1024];
} g_defs;

/* One campaign read: the tags it adds, the spawn weights it scales (each modifier id once). */
typedef struct Campaign
{
    KycTags* initial;
    KycWeights zone;
    int applied_count;
    uint32_t applied[256];
} Campaign;

void kyc_campaign_reset(void) { memset(&g_defs, 0, sizeof g_defs); }

void kyc_unresolved(KycSnapshot* snapshot, const char* reason)
{
    if (snapshot->unresolved++ == 0) snprintf(snapshot->first_unresolved, sizeof snapshot->first_unresolved, "%s", reason);
    kyc_error_clear();
}

int kyc_tag_hashes(void)
{
    uint8_t b[128];
    if (!kyc_static(KYC_RVA_TAG_HASHES, b, sizeof b)) return 0;
    for (uint32_t i = 0; i < 32; i++)
    {
        uint8_t tag;
        g_hashes[i] = kyc_u32(b + 4 * i);
        if (!kyc_from_native(i, &tag)) return 0;
        g_hash_by_tag[tag] = g_hashes[i];
    }
    return 1;
}

/* The authored tag of a native tag hash (the last native tag with it), or 0 when unknown. */
static int TagOfHash(uint32_t hash, uint8_t* tag)
{
    for (int i = 31; i >= 0; i--)
        if (g_hashes[i] == hash) return kyc_from_native((uint32_t)i, tag);
    return 0;
}

static int Definition(const uint8_t* row)
{
    uint32_t id = kyc_u32(row), category = kyc_u32(row + 4), kind = kyc_u32(row + 24);
    if (category == CATEGORY_TAG && kind == 13)
    {
        uint8_t tag;
        if (!TagOfHash(kyc_u32(row + 28), &tag)) return kyc_fail("Unknown campaign enemy tag");
        g_defs.tag_id[g_defs.tags] = id;
        g_defs.tag[g_defs.tags++] = tag;
    }
    if (category == CATEGORY_WEIGHT && kind == 13 && kyc_u32(row + 36) == 2)
    {
        g_defs.weight_id[g_defs.weights] = id;
        g_defs.weight_family[g_defs.weights] = kyc_u32(row + 28);
        g_defs.weight_factor[g_defs.weights++] = kyc_f32(row + 44);
    }
    g_defs.hash[g_defs.hashes] = kyc_u32(row + 8);
    g_defs.hash_id[g_defs.hashes++] = id;
    return 1;
}

static int Definitions(void)
{
    uintptr_t defs;
    uint32_t n;
    g_defs.tags = g_defs.weights = g_defs.hashes = 0;
    if (!kyc_static_ptr(KYC_RVA_DEFINITIONS, &defs) || !kyc_count(defs + DEFS_COUNT, 1024, &n)) return 0;
    if (n == 0) return 1;
    if (!kyc_read(defs, g_rows, sizeof g_rows, (size_t)n * 52)) return 0;
    for (uint32_t i = 0; i < n; i++)
        if (!Definition(g_rows + i * 52)) return 0;
    return 1;
}

static int IdByHash(uint32_t hash, uint32_t* id)
{
    for (int i = 0; i < g_defs.hashes; i++)
        if (g_defs.hash[i] == hash) { *id = g_defs.hash_id[i]; return 1; }
    return 0;
}

/* (family, value) * factor in a weight table, a family it lacks starting at 1. */
static int Scale(KycWeights* weights, uint32_t family, double factor)
{
    for (int i = 0; i < weights->count; i++)
        if (weights->family[i] == family) { weights->value[i] *= factor; return 1; }
    if (weights->count >= KYC_MAX_WEIGHTS) return kyc_fail("Too many spawn weight families");
    weights->family[weights->count] = family;
    weights->value[weights->count++] = 1 * factor;
    return 1;
}

static int Applied(Campaign* c, uint32_t id)
{
    for (int i = 0; i < c->applied_count; i++)
        if (c->applied[i] == id) return 1;
    return 0;
}

/* One campaign modifier: its enemy tag, and its spawn weight once per id. */
static int Apply(Campaign* c, uint32_t id)
{
    for (int i = g_defs.tags - 1; i >= 0; i--)
    {
        if (g_defs.tag_id[i] != id) continue;
        if (!kyc_tag_add(c->initial, g_defs.tag[i])) return 0;
        break;
    }
    for (int i = g_defs.weights - 1; i >= 0; i--)
    {
        if (g_defs.weight_id[i] != id) continue;
        if (Applied(c, id)) break;
        if (c->applied_count >= 256) return kyc_fail("Too many campaign modifiers");
        c->applied[c->applied_count++] = id;
        return Scale(&c->zone, g_defs.weight_family[i], g_defs.weight_factor[i]);
    }
    return 1;
}

static int AddIds(Campaign* c, const uint8_t* b, uint32_t length, uint32_t maximum)
{
    if (length > maximum) return kyc_fail("Too many campaign modifiers");
    for (uint32_t i = 0; i < length; i++)
        if (!Apply(c, kyc_u32(b + 4 * i))) return 0;
    return 1;
}

static int EventModifiers(Campaign* c, uintptr_t data, uint32_t planet, uint32_t index)
{
    const uint8_t* event = g_rows;
    if (!kyc_read(data + DATA_EVENTS + 2496u * index, g_rows, sizeof g_rows, 2496)) return 0;
    uint32_t pn = kyc_u32(event + 2480);
    if (pn > 32) return kyc_fail("Too many event planets");
    int applies = pn == 0;
    for (uint32_t j = 0; j < pn; j++) applies |= kyc_u32(event + 2352 + 4 * j) == planet;
    return applies ? AddIds(c, event + 2336, kyc_u32(event + 2348), 3) : 1;
}

static int PlanetModifiers(Campaign* c, uintptr_t data, uint32_t planet)
{
    uint32_t environments, events;
    if (!kyc_read(data + 304u * planet + DATA_MODIFIERS, g_rows, sizeof g_rows, 132) ||
        !AddIds(c, g_rows, kyc_u32(g_rows + 128), 32) || !AddIds(c, g_static + 184, kyc_u32(g_static + 200), 4) ||
        !kyc_count(data + DATA_ENVIRONMENT_COUNT, 4, &environments))
        return 0;
    for (uint32_t i = 0; i < environments; i++)
    {
        uint8_t env[44];
        if (!kyc_read(data + DATA_ENVIRONMENTS + i * 44u, env, sizeof env, 44)) return 0;
        if (kyc_u32(env) == planet && !AddIds(c, env + 4, kyc_u32(env + 36), 8)) return 0;
    }
    if (!kyc_count(data + DATA_EVENT_COUNT, 8, &events)) return 0;
    for (uint32_t i = 0; i < events; i++)
        if (!EventModifiers(c, data, planet, i)) return 0;
    return 1;
}

/* ---- the highlighted local operation's template modifiers ----------------------------------------------------- */

static int FindOperation(uintptr_t data, uint32_t planet, uint32_t id, uint8_t* found, int* has)
{
    uint32_t n;
    *has = 0;
    if (!kyc_count(data + DATA_OPERATION_COUNT, 512, &n)) return 0;
    for (uint32_t i = 0; i < n; i++)
    {
        if (!kyc_read(data + DATA_OPERATIONS + 24u * i, found, 24, 24)) return 0;
        if (kyc_u32(found) == planet && kyc_u32(found + 4) == id) { *has = 1; return 1; }
    }
    return 1;
}

static int ApplyTemplate(Campaign* c, uintptr_t slot)
{
    uintptr_t template, list;
    uint32_t total;
    if (!kyc_ptr(slot, &template) || !kyc_count(template + 96, 256, &total)) return 0;
    if (total == 0) return 1;
    if (!kyc_ptr(template + 88, &list) || !kyc_read(list, g_mods, sizeof g_mods, (size_t)total * 4)) return 0;
    for (uint32_t j = 0; j < total; j++)
    {
        uint32_t id;
        if (IdByHash(kyc_u32(g_mods + 4 * j), &id) && !Apply(c, id)) return 0;
    }
    return 1;
}

static int TemplateModifiers(Campaign* c, uintptr_t board, uint32_t template_id)
{
    if (!kyc_read(board + BOARD_TEMPLATES, g_header, sizeof g_header, 24)) return 0;
    uintptr_t values = kyc_pointer_at(g_header), keys = kyc_pointer_at(g_header + 8);
    uint32_t total = kyc_u32(g_header + 16);
    if (total > 4096) return kyc_fail("Too many operation templates");
    if (values == 0 || total == 0) return 1;
    if (keys == 0) return kyc_fail("Operation template keys unavailable");
    if (!kyc_read(keys, g_rows, sizeof g_rows, (size_t)total * 4)) return 0;
    for (uint32_t i = 0; i < total; i++)
        if (kyc_u32(g_rows + 4 * i) == template_id) return ApplyTemplate(c, values + 8u * i);
    return 1;
}

static int OperationModifiers(Campaign* c, uintptr_t board, uintptr_t data, uint32_t planet, uint32_t index)
{
    uint8_t selected[92], operation[24], flag;
    int has;
    if (!kyc_read(board + KYC_BOARD_OPERATIONS + 92u * index, selected, sizeof selected, 92)) return 0;
    if (kyc_u16(selected + 16) != planet) return kyc_fail("Operation planet does not match this mission");
    uint32_t category = kyc_u32(selected + 28);
    if (selected[52] == 0 || category >= 14) return 1;
    if (!kyc_static(KYC_RVA_CATEGORIES + 168u * category + 9, &flag, 1)) return 0;
    if (flag == 0) return 1;
    if (!FindOperation(data, kyc_u16(selected + 16), selected[24], operation, &has)) return 0;
    if (!has) return 1;
    if (!FindOperation(data, planet, kyc_u32(operation + 4), operation, &has)) return 0;
    return has ? TemplateModifiers(c, board, kyc_u32(operation + 8)) : 1;
}

static int LocalOperation(Campaign* c, const KycSnapshot* snapshot, uintptr_t data, uint32_t planet)
{
    uintptr_t board = snapshot->d.board;
    uint8_t b[4];
    if (!kyc_read(board + KYC_BOARD_OPERATION, b, sizeof b, 4)) return 0;
    uint32_t index = kyc_u32(b);
    if (index > 110 && index != 0xFFFFFFFFu) return kyc_fail("Invalid operation selection");
    if (snapshot->d.has_operation && index != snapshot->d.operation_index) return kyc_fail("Operation changed during read");
    return !snapshot->d.has_preview && index < 110 ? OperationModifiers(c, board, data, planet, index) : 1;
}

/* ---- global modifiers in scope: type 17 adds an enemy tag; type 15 war effects scale one family's group weights
 * (native 0x12e3c00) ---------------------------------------------------------------------------------------------- */

static int GlobalEntry(Campaign* c, KycWeights* war, const uint8_t* entry)
{
    uint32_t total = kyc_u32(entry + 80);
    if (total > 5) return kyc_fail("Too many global modifier entries");
    for (uint32_t j = 0; j < total; j++)
    {
        const uint8_t* e = entry + 16 * j;
        uint8_t tag;
        if (e[0] == 17 && (!kyc_from_native(kyc_u32(e + 4), &tag) || !kyc_tag_add(c->initial, tag))) return 0;
        if (e[0] == 15 && !Scale(war, kyc_u32(e + 4), kyc_f32(e + 8))) return 0;
    }
    return 1;
}

static int WarEffects(Campaign* c, uint32_t planet, KycWeights* war)
{
    uintptr_t globals;
    uint32_t faction = kyc_u32(g_dynamic + 36), region = kyc_u32(g_dynamic + 64);
    war->count = 0;
    if (!kyc_static_ptr(KYC_RVA_GLOBALS, &globals) || !kyc_read(globals, g_rows, sizeof g_rows, 32 * 356)) return 0;
    for (int i = 0; i < 32; i++)
    {
        const uint8_t* entry = g_rows + i * 356;
        uint8_t scope = entry[84];
        uint32_t value = kyc_u32(entry + 88), filter = kyc_u32(entry + 92);
        int applies = scope == 3 || (scope == 0 && value == planet) || (scope == 1 && value == region) ||
            (scope == 2 && value == faction);
        if (applies && (filter == 0 || filter == faction) && !GlobalEntry(c, war, entry)) return 0;
    }
    return 1;
}

/* ---- the campaign ------------------------------------------------------------------------------------------- */

/* The planet whose campaign inputs apply: a remote hover's advertised planet, the highlighted local operation's or the
 * ship's active planet, checked against the planet data. */
static int CampaignPlanet(const KycSnapshot* snapshot, uintptr_t data, uint32_t* planet)
{
    uintptr_t board = snapshot->d.board;
    uint32_t n, active;
    if (snapshot->d.has_preview) *planet = snapshot->d.preview_planet;
    else if (snapshot->d.has_operation) *planet = snapshot->d.operation_planet;
    else if (!kyc_count(board + KYC_BOARD_ACTIVE_PLANET, 511, planet)) return 0;
    if (!kyc_count(board + CAMPAIGN_PLANETS, 512, &n)) return 0;
    if (*planet >= n) return kyc_fail("Planet data changed");
    if (snapshot->d.has_preview || snapshot->d.has_operation) return 1;
    uint8_t b[4];
    if (!kyc_read(data + DATA_PLANET, b, sizeof b, 4)) return 0;
    active = kyc_u32(b);
    return active == *planet ? 1 : kyc_fail("Planet data changed");
}

/* The campaign modifiers are gated off by three flags (the session's and two of the root's), read until one is set. */
static int Gated(uintptr_t root, int* gated)
{
    uintptr_t session;
    uint8_t flag;
    *gated = 1;
    if (!kyc_static_ptr(KYC_RVA_SESSION, &session) || !kyc_read(session + SESSION_GATE, &flag, 1, 1)) return 0;
    if (flag != 0) return 1;
    if (!kyc_read(root + ROOT_GATE, &flag, 1, 1)) return 0;
    if (flag != 0) return 1;
    if (!kyc_read(root + ROOT_GATE_2, &flag, 1, 1)) return 0;
    *gated = flag != 0;
    return 1;
}

static int CampaignTags(KycSnapshot* snapshot, Campaign* c)
{
    uintptr_t data = snapshot->d.board + KYC_BOARD_CAMPAIGN;
    uint32_t planet;
    int gated;
    static KycWeights war;
    if (!CampaignPlanet(snapshot, data, &planet) || !kyc_read(data + DATA_STATIC * planet, g_static, sizeof g_static, 280))
        return 0;
    if (kyc_u32(g_static + 24) != snapshot->d.key.planet) return kyc_fail("Selected planet does not match this mission");
    if (!kyc_read(data + 304u * planet + DATA_DYNAMIC, g_dynamic, sizeof g_dynamic, 304) || !Gated(snapshot->d.root, &gated) ||
        !Definitions())
        return 0;
    if (!gated && (!PlanetModifiers(c, data, planet) || !LocalOperation(c, snapshot, data, planet))) return 0;
    if (!WarEffects(c, planet, &war)) return 0;
    snapshot->zone = c->zone;
    snapshot->war = war;
    return 1;
}

/* ---- level tags ---------------------------------------------------------------------------------------------- */

static int StampAddress(const uint8_t* selection, uintptr_t* address)
{
    uint8_t index = selection[162], variant = selection[161];
    uintptr_t owner = kyc_pointer_at(selection), table;
    *address = 0;
    if (index == 255) return 1;
    if (owner == 0) return kyc_fail("Stamp owner unavailable");
    if (kyc_u32(selection + 8) != STAMP_TABLE) return kyc_ptr(owner, address);
    if (variant == 255) return 1;
    if (!kyc_ptr(owner + 40, &table) || !kyc_ptr(table + 24u * variant + 8, address)) return 0;
    *address += 456u * index;
    return 1;
}

static int Stamp(const KycSnapshot* snapshot, KycTags* initial)
{
    uintptr_t controller = snapshot->d.controller, level, address;
    uint8_t explicit[16], tag, b[8];
    uint32_t stamps;
    if (!kyc_ptr(controller + CONTROLLER_LEVEL, &level) || !kyc_read(level + LEVEL_EXPLICIT, explicit, sizeof explicit, 16)) return 0;
    uint32_t n = kyc_u32(explicit + 12);
    if (n > 3) return kyc_fail("Too many explicit tags");
    for (uint32_t i = 0; i < n; i++)
        if (!kyc_from_native(kyc_u32(explicit + 4 * i), &tag) || !kyc_tag_add(initial, tag)) return 0;
    if (!kyc_read(controller, b, sizeof b, 8)) return 0;
    if (kyc_pointer_at(b) == 0) return 1;
    if (!kyc_count(level + LEVEL_STAMPS, 100000, &stamps)) return 0;
    if (stamps == 0) return 1;
    if (!kyc_read(level + LEVEL_SELECTION, g_selection, sizeof g_selection, 168) || !StampAddress(g_selection, &address)) return 0;
    if (address == 0) return 1;
    uint8_t stamped[4];
    return kyc_read(address + 208, stamped, sizeof stamped, 4) && kyc_from_native(kyc_u32(stamped), &tag) &&
        kyc_tag_add(initial, tag);
}

int kyc_initial_tags(KycSnapshot* snapshot, KycTags* initial)
{
    static Campaign c;
    memset(&c, 0, sizeof c);
    initial->count = 0;
    c.initial = initial;
    int ok = CampaignTags(snapshot, &c);
    if (!ok)
    {
        initial->count = 0;
        kyc_unresolved(snapshot, kyc_error_text());
    }
    int complete = ok && snapshot->d.controller_matches;
    if (!snapshot->d.controller_matches)
    {
        kyc_unresolved(snapshot, "Hovered mission differs from the loaded mission");
        return complete;
    }
    if (!Stamp(snapshot, initial))
    {
        kyc_unresolved(snapshot, kyc_error_text());
        complete = 0;
    }
    return complete;
}

/* ---- the backend configuration's disabled tags -------------------------------------------------------------- */

static int ExcludedIn(uintptr_t map, uint32_t key, int* excluded)
{
    uint8_t header[24];
    *excluded = 0;
    if (!kyc_read(map, header, sizeof header, 24)) return 0;
    uint32_t capacity = kyc_u32(header + 8), empty = kyc_u32(header + 12), multiplier = kyc_u32(header + 16);
    if (capacity > 65536 || (capacity != 0 && (capacity & (capacity - 1)) != 0)) return kyc_fail("Unexpected configuration map");
    if (capacity == 0) return 1;
    uintptr_t data = kyc_pointer_at(header);
    if (data == 0) return kyc_fail("Configuration map data unavailable");
    uint32_t product = key * multiplier, probes = capacity < 128 ? capacity : 128;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        uint8_t b[4];
        uint32_t slot = (product + probe) & (capacity - 1);
        if (!kyc_read(data + 48u * slot, b, sizeof b, 4)) return 0;
        if (kyc_u32(b) == key) { *excluded = 1; return 1; }
        if (kyc_u32(b) == empty) return 1;
    }
    return capacity <= 128 ? 1 : kyc_fail("Configuration lookup bound exceeded");
}

static int ExcludedByConfig(uint32_t hash, int* excluded)
{
    static const uint32_t kMaps[2] = {73848, 49232};
    uintptr_t manager;
    uint32_t key = kyc_exclusion_key(1, hash);
    *excluded = 0;
    if (!kyc_static_ptr(KYC_RVA_CONFIG, &manager)) return 0;
    for (int i = 0; i < 2; i++)
    {
        if (!ExcludedIn(manager + kMaps[i], key, excluded)) return 0;
        if (*excluded) return 1;
    }
    return 1;
}

int kyc_disabled_tags(KycSnapshot* snapshot, const KycTags* tags, uint32_t* disabled)
{
    int complete = 1;
    *disabled = 0;
    for (int i = 0; i < tags->count; i++)
    {
        int excluded;
        if (ExcludedByConfig(g_hash_by_tag[tags->tag[i]], &excluded)) { if (excluded) *disabled |= 1u << tags->tag[i]; continue; }
        complete = 0;
        kyc_unresolved(snapshot, kyc_error_text());
    }
    return complete;
}
