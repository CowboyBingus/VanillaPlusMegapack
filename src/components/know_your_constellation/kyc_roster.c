/* Know Your Constellation's roster (roster.lua): the enemies a mission can spawn and their spawn-rate levels, from the
 * offline tables of kyc_roster_data.h. Mirrors native build 25480438: group builder 0x94be10, group weight 0x94a0a0
 * with the war-effect clamp 0x12e3c00, tag predicate 0x177e3c0 and replacement chain 0x949b80. Runs once per change
 * of the mission inputs (a one-entry cache), never per frame.
 *
 * Sums over a source's units are taken in names-index order; the Lua's took them in its hash order, so a share can
 * differ from the Lua's in its last bit (never enough to change a tick or the order, except at an exact tie). */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "kyc.h"
#include "kyc_roster_data.h"

#define PATROL 2
#define GARRISON 4
#define REINFORCEMENT 5
#define TRAVEL 6
#define AIR 9
#define AIR_RATE 0.25        /* air support fires every 300-600 s against 65-200 s patrol timers */
#define FULL 0.16            /* a unit at 16% of all spawns fills the meter */
#define STEP 1.5             /* each halving removes 1.5 ticks */
#define TICKS 10
#define PLACEHOLDER 0.1      /* garrison groups below it are disabled (build 25480438 raised two from 0 to 0.01) */
#define MAX_FAMILY 40
#define MAX_MEMBERS 64
#define NAMES (KYC_NAME_COUNT + 1)

/* One family's eligible units: displayed name (names index, 0 none), weight and weight share. */
typedef struct Family { int ready, count; uint8_t name[MAX_MEMBERS]; double weight[MAX_MEMBERS], share[MAX_MEMBERS]; } Family;
typedef struct Context
{
    const KycFaction* faction;
    uint32_t tags;
    int difficulty;
    const KycWeights* zone; /* NULL when none apply */
    const KycWeights* war;
    int travel;
    Family families[MAX_FAMILY];
} Context;
typedef struct Counts { uint8_t present[NAMES]; double value[NAMES]; } Counts;
typedef struct Eligible { int count; double weight[160]; const KycGroup* group[160]; } Eligible;

static Context g_context;
static Eligible g_eligible;

int kyc_name_count(void) { return KYC_NAME_COUNT; }
const char* kyc_name_text(int index) { return index >= 1 && index <= KYC_NAME_COUNT ? kKycNames[index].text : ""; }
const char* kyc_name_key(int index) { return index >= 1 && index <= KYC_NAME_COUNT ? kKycNames[index].key : ""; }
int kyc_name_size(int index) { return index >= 1 && index <= KYC_NAME_COUNT ? kKycNames[index].size : 0; }

int kyc_name_find(const char* text)
{
    for (int i = 1; i <= KYC_NAME_COUNT; i++)
        if (strcmp(kKycNames[i].text, text) == 0) return i;
    return 0;
}

static int Accepts(uint32_t tags, uint32_t required, uint32_t excluded)
{
    return (tags & excluded) == 0 && (required == 0 || (tags & required) != 0);
}

/* The highest-priority matching rule wins; a later step may not lower the priority. */
static int Replace(const Context* c, int resource)
{
    int priority = -1;
    for (int step = 0; step < 5; step++)
    {
        const KycSwap* best = NULL;
        for (int i = 0; i < c->faction->swap_count; i++)
        {
            const KycSwap* rule = &c->faction->swaps[i];
            if (rule->source == resource && (c->tags & (1u << rule->tag)) && c->difficulty >= rule->low &&
                c->difficulty <= rule->high && (best == NULL || rule->priority > best->priority))
                best = rule;
        }
        if (best == NULL || best->priority < priority) break;
        resource = best->target;
        priority = best->priority;
    }
    return resource;
}

/* The eligible units of one family with their displayed name and weight share (cached per computation). */
static const Family* MembersOf(Context* c, int family)
{
    Family* f = &c->families[family];
    if (f->ready) return f;
    f->ready = 1;
    f->count = 0;
    double total = 0;
    for (int i = 0; i < c->faction->unit_count; i++)
    {
        const KycUnitRow* unit = &c->faction->units[i];
        double weight = unit->family == family ? kKycWeights[unit->weights][c->difficulty - 1] : 0;
        if (!(weight > 0) || !Accepts(c->tags, unit->required, unit->excluded) || f->count >= MAX_MEMBERS) continue;
        f->name[f->count] = c->faction->resources[Replace(c, unit->resource)];
        f->weight[f->count++] = weight;
        total += weight;
    }
    for (int i = 0; i < f->count; i++) f->share[i] = f->weight[i] / total;
    return f;
}

static double Clamp(double value) { return value < 0 ? 0 : value > 10000 ? 10000 : value; }

/* A family's multiplier in a weight table, 1 when it has none. */
static double Factor(const KycWeights* weights, uint32_t family)
{
    for (int i = 0; i < weights->count; i++)
        if (weights->family[i] == family) return weights->value[i];
    return 1;
}

static double WeightOf(const Context* c, const KycGroup* group)
{
    double weight = group->weight;
    const uint32_t* families = c->faction->families;
    const KycMember* members = c->faction->members + group->first;
    if (c->zone != NULL || c->war != NULL)
    {
        double product = 1;
        for (int i = 0; c->zone != NULL && i < group->members; i++) product *= Factor(c->zone, families[members[i].family]);
        for (int i = 0; i < group->members; i++)
        {
            if (c->war != NULL) product *= Factor(c->war, families[members[i].family]);
            product = Clamp(product);
        }
        weight *= Clamp(product);
    }
    if (group->pool == 8 && weight < 0.1) weight = 0.1;
    return weight;
}

static int GroupAllowed(const Context* c, const KycGroup* group, int pool, int category)
{
    return group->pool == pool && (category == 0 || group->category == category) && c->difficulty >= group->low &&
        c->difficulty <= group->high && group->fewest <= 4 && group->most >= 1 &&
        (group->required == 0 || (c->tags & group->required) != 0);
}

/* The groups the native builder keeps for one pool (category 0: any), into g_eligible. */
static const Eligible* EligibleGroups(Context* c, int pool, int category)
{
    Eligible* e = &g_eligible;
    e->count = 0;
    for (int i = 0; i < c->faction->group_count; i++)
    {
        const KycGroup* group = &c->faction->groups[i];
        if (!GroupAllowed(c, group, pool, category)) continue;
        double weight = WeightOf(c, group);
        int complete = weight > 0;
        for (int m = 0; complete && m < group->members; m++)
            if (MembersOf(c, c->faction->members[group->first + m].family)->count == 0) complete = 0;
        if (complete && e->count < 160) { e->weight[e->count] = weight; e->group[e->count++] = group; }
    }
    return e;
}

static void Add(Counts* counts, int name, double value)
{
    if (!counts->present[name]) { counts->present[name] = 1; counts->value[name] = 0; }
    counts->value[name] += value;
}

/* Expected units of each name per weighted draw from a list of groups. */
static void Draws(Context* c, const Eligible* groups, Counts* counts, double rate)
{
    double total = 0;
    for (int i = 0; i < groups->count; i++) total += groups->weight[i];
    for (int i = 0; i < groups->count; i++)
    {
        const KycGroup* group = groups->group[i];
        for (int m = 0; m < group->members; m++)
        {
            const KycMember* member = &c->faction->members[group->first + m];
            double count = member->count >= 999 ? 1 : member->count;
            const Family* f = MembersOf(c, member->family);
            for (int k = 0; k < f->count; k++)
                if (f->name[k] > 0) Add(counts, f->name[k], rate * groups->weight[i] / total * count * f->share[k]);
        }
    }
}

/* Each name's share of a source, in place; 0 when the source is empty (the Lua's nil). */
static int Shares(Counts* counts)
{
    double total = 0;
    for (int n = 1; n < NAMES; n++)
        if (counts->present[n]) total += counts->value[n];
    if (total <= 0) return 0;
    for (int n = 1; n < NAMES; n++)
        if (counts->present[n]) counts->value[n] /= total;
    return 1;
}

/* Patrols: one equal-rate stream per patrol category, gated border travelers at the same rate and Illuminate air
 * support at a quarter. */
static int Patrols(Context* c, Counts* counts)
{
    for (int category = 1; category <= 4; category++)
    {
        const Eligible* groups = EligibleGroups(c, PATROL, category);
        if (groups->count > 0) Draws(c, groups, counts, 1);
    }
    if (c->travel)
    {
        const Eligible* groups = EligibleGroups(c, TRAVEL, 0);
        if (groups->count > 0) Draws(c, groups, counts, 1);
    }
    const Eligible* air = EligibleGroups(c, AIR, 0);
    if (air->count > 0) Draws(c, air, counts, AIR_RATE);
    return Shares(counts);
}

/* Garrisons pick a member family by its summed unit weight, then a unit by weight. Groups at a placeholder weight are
 * disabled: garrison spawn points also filter by unit masks that are not modelled. */
static int Garrisons(Context* c, Counts* counts)
{
    const Eligible* groups = EligibleGroups(c, GARRISON, 0);
    for (int i = 0; i < groups->count; i++)
    {
        if (!(groups->weight[i] >= PLACEHOLDER)) continue;
        const KycGroup* group = groups->group[i];
        for (int m = 0; m < group->members; m++)
        {
            const Family* f = MembersOf(c, c->faction->members[group->first + m].family);
            for (int k = 0; k < f->count; k++)
                if (f->name[k] > 0) Add(counts, f->name[k], f->weight[k]);
        }
    }
    return Shares(counts);
}

static int Reinforcements(Context* c, Counts* counts)
{
    const Eligible* groups = EligibleGroups(c, REINFORCEMENT, 0);
    if (groups->count > 0) Draws(c, groups, counts, 1);
    return Shares(counts);
}

int kyc_roster_ticks(double share)
{
    if (!(share > 0)) return 0;
    double value = floor(TICKS + STEP * log(share / FULL) / log(2.0) + 0.5);
    if (value < 1) return 1;
    if (value > TICKS) return TICKS;
    return (int)value;
}

static const double* g_order; /* the shares qsort compares by */

/* Most common first, then by name. */
static int Order(const void* a, const void* b)
{
    int x = *(const uint8_t*)a, y = *(const uint8_t*)b;
    if (g_order[x] != g_order[y]) return g_order[x] > g_order[y] ? -1 : 1;
    return strcmp(kKycNames[x].text, kKycNames[y].text);
}

static int Hidden(int name)
{
    for (size_t i = 0; i < sizeof kKycHidden; i++)
        if (kKycHidden[i] == name) return 1;
    return 0;
}

/* The share of every name over the three sources (patrols, reinforcements, garrisons): present[] says which have one. */
static void Combine(Context* c, Counts* share)
{
    static Counts source;
    int (*const sources[3])(Context*, Counts*) = {Patrols, Reinforcements, Garrisons};
    int used = 0;
    memset(share, 0, sizeof *share);
    for (int s = 0; s < 3; s++)
    {
        memset(&source, 0, sizeof source);
        if (!sources[s](c, &source)) continue;
        used++;
        for (int n = 1; n < NAMES; n++)
            if (source.present[n]) Add(share, n, source.value[n]);
    }
    for (int n = 1; n < NAMES; n++)
        if (share->present[n]) share->value[n] /= used;
}

/* The units commanders summon, listed (without a share) when a commander is. */
static void Summoned(Context* c, const Counts* share, uint8_t* extra)
{
    int commanded = 0;
    if (!c->faction->summoned) return;
    for (size_t i = 0; i < sizeof kKycCommanders; i++)
        commanded |= share->present[kKycCommanders[i]] && share->value[kKycCommanders[i]] > 0;
    if (!commanded) return;
    const Family* f = MembersOf(c, c->faction->summoned);
    for (int k = 0; k < f->count; k++)
        if (f->name[k] > 0 && !share->present[f->name[k]]) extra[f->name[k]] = 1;
}

/* The names listed: those with a share (but the hidden ones), the summoned units and Hive Lords on Hive Worlds,
 * most common first. */
static int Listed(Context* c, const Counts* share, uint8_t* listed)
{
    static double order[NAMES];
    uint8_t extra[NAMES];
    int count = 0;
    memset(extra, 0, sizeof extra);
    Summoned(c, share, extra);
    if ((c->tags & (1u << KYC_HIVE_LORD_TAG)) && c->difficulty >= (int)KYC_HIVE_LORD_DIFFICULTY &&
        !share->present[KYC_HIVE_LORD_NAME])
        extra[KYC_HIVE_LORD_NAME] = 1;
    for (int n = 1; n < NAMES; n++)
        if ((share->present[n] && !Hidden(n)) || extra[n]) listed[count++] = (uint8_t)n;
    for (int n = 0; n < NAMES; n++) order[n] = share->present[n] ? share->value[n] : 0;
    g_order = order;
    qsort(listed, (size_t)count, 1, Order);
    return count;
}

/* Large and massive enemies get a meter (at least one tick); the others are listed. */
static void Sections(const uint8_t* listed, int count, KycReport* out)
{
    out->large_count = out->small_count = 0;
    for (int i = 0; i < count; i++)
    {
        int name = listed[i];
        if (kKycNames[name].size < 3) { out->small[out->small_count++] = (uint8_t)name; continue; }
        int ticks = kyc_roster_ticks(g_order[name]);
        out->large_ticks[out->large_count] = (uint8_t)(ticks < 1 ? 1 : ticks);
        out->large[out->large_count++] = (uint8_t)name;
    }
}

int kyc_roster_compute(int faction, int difficulty, const KycTags* tags, const KycWeights* zone, const KycWeights* war,
    KycReport* out)
{
    static Counts share;
    uint8_t listed[NAMES];
    if (faction < 2 || faction > 4) return kyc_fail("Unknown faction");
    if (difficulty < 1 || difficulty > 10) return kyc_fail("Invalid difficulty");
    Context* c = &g_context;
    memset(c, 0, sizeof *c);
    c->faction = &kKycFactions[faction - 2];
    for (int i = 0; i < tags->count; i++) c->tags |= 1u << tags->tag[i];
    c->difficulty = difficulty;
    c->zone = zone != NULL && zone->count > 0 ? zone : NULL;
    c->war = war != NULL && war->count > 0 ? war : NULL;
    c->travel = (c->tags & c->faction->travel) != 0;
    Combine(c, &share);
    Sections(listed, Listed(c, &share, listed), out);
    return 1;
}

/* ---- the one-entry cache ------------------------------------------------------------------------------------- */

typedef struct RosterKey
{
    int faction, difficulty, tag_count, zone_count, war_count;
    uint8_t tags[KYC_MAX_TAGS];
    uint32_t zone_family[KYC_MAX_WEIGHTS], war_family[KYC_MAX_WEIGHTS];
    double zone[KYC_MAX_WEIGHTS], war[KYC_MAX_WEIGHTS];
} RosterKey;

static struct
{
    int valid;
    uint32_t computed;
    RosterKey key;
    KycReport report;
} g_cache;

static int ByTag(const void* a, const void* b) { return (int)*(const uint8_t*)a - (int)*(const uint8_t*)b; }

/* A weight table sorted by family, into the key (its order does not matter, as in the Lua's sorted key). */
static int SortedWeights(const KycWeights* weights, uint32_t* family, double* value)
{
    int n = weights != NULL ? weights->count : 0;
    for (int i = 0; i < n; i++) { family[i] = weights->family[i]; value[i] = weights->value[i]; }
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0 && family[j - 1] > family[j]; j--)
        {
            uint32_t f = family[j]; family[j] = family[j - 1]; family[j - 1] = f;
            double v = value[j]; value[j] = value[j - 1]; value[j - 1] = v;
        }
    return n;
}

static void MakeKey(RosterKey* key, int faction, int difficulty, const KycTags* tags, const KycWeights* zone,
    const KycWeights* war)
{
    memset(key, 0, sizeof *key);
    key->faction = faction;
    key->difficulty = difficulty;
    key->tag_count = tags->count;
    memcpy(key->tags, tags->tag, (size_t)tags->count);
    qsort(key->tags, (size_t)key->tag_count, 1, ByTag);
    key->zone_count = SortedWeights(zone, key->zone_family, key->zone);
    key->war_count = SortedWeights(war, key->war_family, key->war);
}

int kyc_roster_report(int faction, int difficulty, const KycTags* tags, const KycWeights* zone, const KycWeights* war,
    const KycReport** out)
{
    static RosterKey key;
    MakeKey(&key, faction, difficulty, tags, zone, war);
    if (!g_cache.valid || memcmp(&key, &g_cache.key, sizeof key) != 0)
    {
        g_cache.valid = 0;
        if (!kyc_roster_compute(faction, difficulty, tags, zone, war, &g_cache.report)) return 0;
        memcpy(&g_cache.key, &key, sizeof key);
        g_cache.valid = 1;
        g_cache.computed++;
    }
    *out = &g_cache.report;
    return 1;
}

void kyc_roster_reset(void) { memset(&g_cache, 0, sizeof g_cache); }
uint32_t kyc_roster_computed(void) { return g_cache.computed; }
