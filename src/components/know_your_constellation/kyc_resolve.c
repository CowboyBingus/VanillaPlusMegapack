/* Know Your Constellation's constellation draw and tag rules (resolve.lua), as the game resolves them: the 64-bit
 * linear congruential generator, float32 weight sums, the blocker and fallback rule, the backend exclusion key and the
 * authored tag numbering. The Lua kept the generator's state as two 32-bit words in doubles (no 64-bit cdata); C has
 * uint64_t. Float32 rounding is the Lua's: each sum and product is taken in double and rounded to float. Runs on the
 * 0.5 s refresh only. */
#include <math.h>
#include "kyc.h"

#define MULTIPLIER 0x5851F42D4C957F2Dull
#define INCREMENT 0x14057B7EF767814Full
#define MIX 1540483477u

uint64_t kyc_draw_step(uint64_t state) { return state * MULTIPLIER + INCREMENT; }

static float F32(double value) { return (float)value; }

int kyc_tag_add(KycTags* tags, uint32_t tag)
{
    if (tag == 0) return 1;
    if (tag > 31) return kyc_fail("Unknown enemy tag");
    for (int i = 0; i < tags->count; i++)
        if (tags->tag[i] == tag) return 1;
    if (tags->count >= KYC_MAX_TAGS) return kyc_fail("Too many enemy tags");
    tags->tag[tags->count++] = (uint8_t)tag;
    return 1;
}

/* Keeps the authored catalogue ids after native tag 1 (HordeOnly) was inserted in build 25480438. */
int kyc_from_native(uint32_t tag, uint8_t* out)
{
    if (tag > 31) return kyc_fail("Unknown native enemy tag");
    *out = tag == 1 ? 31 : tag > 1 ? (uint8_t)(tag - 1) : 0;
    return 1;
}

/* A candidate takes part when it names a tag and, if it is only for missions without tags, none came before. */
static int Drawable(const KycCandidate* row, int empty) { return row->id != 0 && (!row->only_when_empty || empty); }

/* The drawable rows' count and their float32 weight total; every row's weight is checked. */
static int Weights(const KycSettings* settings, int empty, int* count, float* total)
{
    *count = 0;
    *total = 0;
    for (int i = 0; i < 8; i++)
    {
        const KycCandidate* row = &settings->candidates[i];
        if (!(row->weight >= 0 && row->weight < INFINITY)) return kyc_fail("Invalid constellation weight");
        if (!Drawable(row, empty)) continue;
        (*count)++;
        *total = F32((double)*total + (double)row->weight);
    }
    return 1;
}

/* The first drawable row whose float32 running weight reaches target, or 0. */
static uint8_t Pick(const KycSettings* settings, int empty, float target)
{
    float cumulative = 0;
    for (int i = 0; i < 8; i++)
    {
        const KycCandidate* row = &settings->candidates[i];
        if (!Drawable(row, empty)) continue;
        cumulative = F32((double)cumulative + (double)row->weight);
        if (cumulative >= target) return row->id;
    }
    return 0;
}

/* Whether one of the blockers before the first 0 is among the tags. */
static int Blocked(const KycTags* tags, const KycSettings* settings)
{
    for (int i = 0; i < settings->blocker_count; i++)
    {
        uint8_t blocker = settings->blockers[i];
        if (blocker == 0) return 0;
        for (int k = 0; k < tags->count; k++)
            if (tags->tag[k] == blocker) return 1;
    }
    return 0;
}

int kyc_draw_base(uint32_t seed, const KycSettings* settings, const KycTags* initial, KycTags* out)
{
    out->count = 0;
    for (int i = 0; initial != NULL && i < initial->count; i++)
        if (!kyc_tag_add(out, initial->tag[i])) return 0;
    int empty = out->count == 0, count;
    float total;
    if (!Weights(settings, empty, &count, &total)) return 0;
    if (settings->draws > 16) return kyc_fail("Invalid draw count");
    uint64_t state = seed;
    for (uint32_t i = 0; i < settings->draws; i++)
    {
        if (count == 0 || total <= 0) break;
        state = kyc_draw_step(state);
        float unit = F32((double)F32((double)(uint32_t)(state >> 32)) * 0x1p-32);
        if (!kyc_tag_add(out, Pick(settings, empty, F32((double)unit * (double)total)))) return 0;
    }
    if (!Blocked(out, settings) && !kyc_tag_add(out, settings->fallback)) return 0;
    return 1;
}

int kyc_tag_filter(const KycTags* tags, uint32_t excluded, uint32_t disabled, KycTags* out)
{
    out->count = 0;
    for (int i = 0; i < tags->count; i++)
    {
        uint32_t bit = 1u << tags->tag[i];
        if (!(excluded & bit) && !(disabled & bit) && !kyc_tag_add(out, tags->tag[i])) return 0;
    }
    return 1;
}

static uint32_t Mix(uint32_t value, uint32_t word)
{
    uint32_t mixed = word * MIX;
    mixed = (mixed ^ (mixed >> 24)) * MIX;
    return mixed ^ (value * MIX);
}

/* The backend configuration's key of an enemy tag's hash. Without a hash only the fixed word is mixed in. */
uint32_t kyc_exclusion_key(int has_hash, uint32_t hash)
{
    uint32_t value = Mix(3781555287u, 3964548889u);
    return has_hash ? Mix(value, hash) : value;
}
