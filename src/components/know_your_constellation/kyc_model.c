/* Know Your Constellation's display model (model.lua) and texts (locales/en.lua): the headline, the listed enemies with
 * their meters, the captions, and a signature of every drawn text so that equal content never redraws. Texts come
 * through vpm_text with the Lua's keys (English until the pack has translations). Made when the report, the mission
 * key, the screen or the tags change, never per frame. */
#include <stdio.h>
#include <string.h>
#include "kyc.h"

typedef struct Title { const char* key; const char* english; int base; } Title;

/* Authored tag ids (kyc_from_native) to their titles. Subfactions, strains and operation modifiers use their in-game
 * names; the base constellations (base 1) keep the mod's names and follow them in the headline. */
static const Title kTitles[32] = {
    {NULL, NULL, 0},
    {"title.bile_bugs", "BILE BUGS", 1}, {"title.armored_bugs", "ARMORED BUGS", 1},
    {"title.hunter_swarms", "HUNTER SWARMS", 1}, {"title.flyer_composition", "FLYER COMPOSITION", 1},
    {"title.light_bugs", "LIGHT BUGS", 1}, {"title.bug_nursery", "BUG NURSERY", 1},
    {"title.balanced_terminids", "BALANCED TERMINIDS", 1}, {"title.predator_strain", "PREDATOR STRAIN", 0},
    {"title.spore_burst_strain", "SPORE BURST STRAIN", 0}, {"title.rupture_strain", "RUPTURE STRAIN", 0},
    {"title.dragonroach_activity", "DRAGONROACH ACTIVITY", 0}, {"title.roving_shriekers", "ROVING SHRIEKERS", 0},
    {"title.assault_forces", "ASSAULT FORCES", 1}, {"title.phalanx_forces", "PHALANX FORCES", 1},
    {"title.artillery_forces", "ARTILLERY FORCES", 1}, {"title.air_composition", "AIR COMPOSITION", 1},
    {"title.armored_column", "ARMORED COLUMN", 1}, {"title.balanced_automatons", "BALANCED AUTOMATONS", 1},
    {"title.jet_brigade", "JET BRIGADE", 0}, {"title.cyborg_legion", "CYBORG LEGION", 0},
    {"title.gunship_patrols", "GUNSHIP PATROLS", 0}, {"title.incineration_corps", "INCINERATION CORPS", 0},
    {"title.hive_world", "HIVE WORLD", 0}, {"title.illuminate_stragglers", "ILLUMINATE STRAGGLERS", 1},
    {"title.leviathan_blockade", "LEVIATHAN BLOCKADE", 0}, {"title.appropriators", "APPROPRIATORS", 0},
    {"title.invasion_fleet", "INVASION FLEET", 0}, {"title.mindless_masses", "MINDLESS MASSES", 0},
    {"title.vote_snatchers", "VOTE SNATCHERS", 0}, {"title.seaf_support", "SEAF SUPPORT", 0},
    {"title.horde", "HORDE", 0},
};

const char* kyc_title_key(int tag) { return tag >= 1 && tag <= 31 ? kTitles[tag].key : NULL; }

const char* kyc_title_text(const VpmComponent* self, int tag)
{
    return tag >= 1 && tag <= 31 ? vpm_text(self, kTitles[tag].key, kTitles[tag].english) : NULL;
}

static int Append(char* out, size_t size, size_t* used, const char* text)
{
    size_t n = strlen(text);
    if (*used + n + 1 > size) return kyc_fail("Forecast headline too long");
    memcpy(out + *used, text, n + 1);
    *used += n;
    return 1;
}

/* One pass of the headline: the tags that are (base 1) or are not (base 0) base constellations. */
static int HeadlinePass(const VpmComponent* self, const KycTags* tags, int base, char* out, size_t size, size_t* used,
    int* parts)
{
    const char* separator = vpm_text(self, "headline.separator", " // ");
    for (int i = 0; i < tags->count; i++)
    {
        int tag = tags->tag[i];
        if (tag < 1 || tag > 31 || kTitles[tag].base != base) continue;
        if (*parts > 0 && !Append(out, size, used, separator)) return 0;
        if (!Append(out, size, used, kyc_title_text(self, tag))) return 0;
        (*parts)++;
    }
    return 1;
}

int kyc_headline(const VpmComponent* self, const KycTags* tags, char* out, size_t size)
{
    size_t used = 0;
    int parts = 0;
    out[0] = 0;
    if (!HeadlinePass(self, tags, 0, out, size, &used, &parts) || !HeadlinePass(self, tags, 1, out, size, &used, &parts))
        return 0;
    return parts > 0 || Append(out, size, &used, vpm_text(self, "headline.standard", "STANDARD FORCES"));
}

/* FNV-1a over the drawn texts, each followed by a separator byte. */
static uint64_t Mix(uint64_t h, const char* text, uint8_t separator)
{
    for (const char* p = text; *p; p++) h = (h ^ (uint8_t)*p) * 0x100000001B3ull;
    return (h ^ separator) * 0x100000001B3ull;
}

static uint64_t Signature(const KycModel* m)
{
    uint64_t h = 0xCBF29CE484222325ull;
    const char* captions[9] = {m->headline, m->label, m->footer, m->more, m->separator, m->large_caption,
        m->rate_caption, m->small_caption, m->order_caption};
    for (int i = 0; i < 9; i++) h = Mix(h, captions[i], 2);
    for (int i = 0; i < m->large_count; i++)
    {
        char ticks[8];
        snprintf(ticks, sizeof ticks, "=%u", m->ticks[i]);
        h = Mix(Mix(h, m->large[i], 0), ticks, 1);
    }
    for (int i = 0; i < m->small_count; i++) h = Mix(h, m->small[i], 1);
    return h <= KYC_PENDING_SIGNATURE ? h + 2 : h;
}

int kyc_model_make(const VpmComponent* self, const KycSnapshot* snapshot, const KycReport* report, KycModel* out)
{
    KycModel* m = out;
    KycTags tags;
    memset(m, 0, sizeof *m);
    m->key = snapshot->d.key;
    m->screen = snapshot->d.screen;
    tags.count = snapshot->tag_count;
    memcpy(tags.tag, snapshot->tags, sizeof tags.tag);
    if (!kyc_headline(self, &tags, m->headline, sizeof m->headline)) return 0;
    m->has_headline = 1;
    for (int i = 0; i < report->large_count; i++)
    {
        m->large[i] = vpm_text(self, kyc_name_key(report->large[i]), kyc_name_text(report->large[i]));
        m->ticks[i] = report->large_ticks[i];
    }
    m->large_count = report->large_count;
    for (int i = 0; i < report->small_count; i++)
        m->small[i] = vpm_text(self, kyc_name_key(report->small[i]), kyc_name_text(report->small[i]));
    m->small_count = report->small_count;
    m->label = vpm_text(self, "panel.label", "FORECAST // INTEL AND RECON");
    m->footer = vpm_text(self, "panel.footer", "Possible encounters. Spawns are not guaranteed.");
    m->more = vpm_text(self, "panel.more", "and {count} more");
    m->separator = vpm_text(self, "panel.list_separator", ", ");
    m->large_caption = vpm_text(self, "panel.large", "LARGE ENEMIES");
    m->rate_caption = vpm_text(self, "panel.rate", "SPAWN RATE");
    m->small_caption = vpm_text(self, "panel.small", "SMALL AND MEDIUM ENEMIES");
    m->order_caption = vpm_text(self, "panel.order", "MOST COMMON FIRST");
    m->signature = Signature(m);
    return 1;
}

void kyc_model_pending(const KycModel* drawn, KycModel* out)
{
    memset(out, 0, sizeof *out);
    out->key = drawn->key;
    out->screen = drawn->screen;
    out->pending = 1;
    out->label = drawn->label;
    out->footer = drawn->footer;
    out->signature = KYC_PENDING_SIGNATURE;
}
