/* Know Your Constellation's mission reader, between its two files: kyc_mission.c (the screen, the selected mission's
 * identity, the sample) and kyc_campaign.c (campaign and operation modifiers, war effects, level tags, the backend's
 * exclusions). Addresses are game.dll RVAs and record offsets of build 25480438, as mission.lua names them. */
#ifndef KYC_MISSION_H
#define KYC_MISSION_H

#include <string.h>
#include "kyc.h"

/* game.dll statics (plain loads) */
#define KYC_RVA_UI_MANAGER 0x347CE28u   /* the UI manager: its screen stack at +0x429C */
#define KYC_RVA_ROOT 0x3326340u         /* the root record: the loaded controller at +0xAE288 */
#define KYC_RVA_BOARD 0x347CEE8u        /* the war table's mission board */
#define KYC_RVA_REMOTE 0x347CE80u       /* the advertised (joinable) missions */
#define KYC_RVA_FALLBACK 0x3326AA0u     /* the session record holding the controller's fallback selection */
#define KYC_RVA_MENU 0x3326E68u         /* the menu manager: briefing owners, the native panels' registries */
#define KYC_RVA_DEFINITIONS 0x347CD98u  /* campaign modifier definitions */
#define KYC_RVA_CATEGORIES 0x32E98E0u   /* operation categories (168-byte rows) */
#define KYC_RVA_GLOBALS 0x346D518u      /* global modifiers (32 rows of 356 bytes) */
#define KYC_RVA_SESSION 0x347CEF0u      /* the session: the campaign-modifier gate at +92134 */
#define KYC_RVA_CONFIG 0x347CDF8u       /* the backend configuration: its exclusion maps */
#define KYC_RVA_TAG_HASHES 0x21E1920u   /* the 32 native enemy tags' hashes */
#define KYC_RVA_MISSIONS 0x3773420u     /* mission records (896 bytes each) */
#define KYC_RVA_DIFFICULTY 0x328D2A0u   /* the game's own difficulty table (10 rows of 816 bytes) */

/* the board's fields */
#define KYC_BOARD_DESCRIPTOR 0x4168D0u
#define KYC_BOARD_OPERATIONS 1012352u   /* 110 highlighted-operation records of 92 bytes */
#define KYC_BOARD_ACTIVE_PLANET 1548952u
#define KYC_BOARD_PREVIEW_PLANET 1548956u
#define KYC_BOARD_OPERATION 1548960u    /* the highlighted operation's index, 0xFFFFFFFF none */
#define KYC_BOARD_CAMPAIGN 1053752u     /* the campaign data */

#define KYC_DATA_UNAVAILABLE "Mission data unavailable"
#define KYC_POINTER_UNAVAILABLE "Mission pointer unavailable"

static inline uint32_t kyc_u32(const uint8_t* b) { uint32_t v; memcpy(&v, b, 4); return v; }
static inline uint16_t kyc_u16(const uint8_t* b) { uint16_t v; memcpy(&v, b, 2); return v; }
static inline float kyc_f32(const uint8_t* b) { float v; memcpy(&v, b, 4); return v; }

/* The user-mode pointer stored at b (little-endian), or 0: below 0x10000 or at 0x800000000000 and above. */
static inline uintptr_t kyc_pointer_at(const uint8_t* b)
{
    uint64_t v;
    memcpy(&v, b, 8);
    return v >= 0x10000u && v < 0x800000000000ull ? (uintptr_t)v : 0;
}

/* Heap reads (vpm_read) into out, capacity bytes: 1, or 0 pending ("Mission data unavailable"; a size of 0 or over
 * the capacity fails instead). */
int kyc_read(uintptr_t address, void* out, size_t capacity, size_t size);
/* A game.dll static (a plain load): 1, or 0 pending. */
int kyc_static(uint32_t rva, void* out, size_t size);
/* The pointer at a heap address or a static: 1, or 0 pending ("Mission pointer unavailable" when not a pointer). */
int kyc_ptr(uintptr_t address, uintptr_t* out);
int kyc_static_ptr(uint32_t rva, uintptr_t* out);
/* A u32 count, checked against its bound ("Mission array bound exceeded"). */
int kyc_count(uintptr_t address, uint32_t maximum, uint32_t* out);

/* kyc_campaign.c: the campaign and level tags into *initial; zone and war weights into the snapshot. 1 complete; 0 not
 * (each reason counted in the snapshot's unresolved). */
int kyc_initial_tags(KycSnapshot* snapshot, KycTags* initial);
/* The backend's disabled tags among tags (a mask); 1 complete, 0 when a lookup failed (counted as unresolved). */
int kyc_disabled_tags(KycSnapshot* snapshot, const KycTags* tags, uint32_t* disabled);
/* The 32 native tag hashes, read once per sample. */
int kyc_tag_hashes(void);
void kyc_campaign_reset(void);
/* Records an error that a sample continues past (the Lua's pcall): counted as unresolved, then cleared. */
void kyc_unresolved(KycSnapshot* snapshot, const char* reason);

#endif
