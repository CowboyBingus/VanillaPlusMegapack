/* The row types of Know Your Constellation's roster tables (kyc_roster_data.h, generated from roster_data.lua). */
#ifndef KYC_ROSTER_H
#define KYC_ROSTER_H

#include <stddef.h>
#include <stdint.h>

typedef struct KycName { const char* text; const char* key; uint8_t size; } KycName;
/* A unit row: its family and resource (1-based), the tags it needs (one of them) and excludes, its weights row. */
typedef struct KycUnitRow { uint8_t family, resource; uint32_t required, excluded; uint8_t weights; } KycUnitRow;
/* A replacement rule: under tag, source becomes target between two difficulties; the highest priority wins. */
typedef struct KycSwap { uint8_t tag, source, target, low, high, priority; } KycSwap;
typedef struct KycMember { uint8_t family; uint16_t count; } KycMember;
typedef struct KycGroup
{
    uint8_t pool, category;
    double weight;
    uint8_t low, high, fewest, most; /* difficulties and players it is drawn for */
    uint32_t required;               /* one of these tags, or none */
    uint16_t first, members;         /* its members in the faction's member table */
} KycGroup;
typedef struct KycFaction
{
    const uint32_t* families; int family_count;   /* family index -> its hash (the spawn-weight key) */
    const uint8_t* resources; int resource_count; /* resource index -> names index, 0 when not displayed */
    const KycUnitRow* units; int unit_count;
    const KycSwap* swaps; int swap_count;
    const KycGroup* groups; int group_count;
    const KycMember* members;
    uint32_t travel;                              /* the tags that bring border travelers */
    uint8_t summoned;                             /* the family commanders summon, 0 none */
} KycFaction;

#endif
