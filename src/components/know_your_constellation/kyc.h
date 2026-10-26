/* Know Your Constellation's parts, shared between its files (know_your_constellation.c is the component and has the
 * full description). Each part ports one Lua file of v4.1.1:
 *   kyc_mission.c       mission.lua       the highlighted mission's inputs, read the way the game resolves them
 *   kyc_presentation.c  presentation.lua  the native panel's rectangle, opacity and font
 *   kyc_resolve.c       resolve.lua       the constellation draw and the tag rules
 *   kyc_roster.c        roster.lua        eligible enemies and spawn-rate levels (data: kyc_roster_data.h)
 *   kyc_model.c         model.lua         the panel's texts (locales/en.lua)
 *   kyc_text.c          bingus_text.lua   UTF-8 checks, character boundaries, line wrapping
 *   kyc_panel.c         panel.lua         the forecast panel, drawn through kyc_gui.h
 *
 * Errors. The Lua raised two kinds: expected transient states ({pending = reason}: memory being rebuilt, no mission
 * highlighted, the font not loaded yet), which hide the forecast and retry on the next frame without counting, and
 * genuine errors (a failed check), which count toward stopping the component. Here a function that can fail returns 0
 * (or KYC_ERROR) after kyc_pending or kyc_fail recorded which. */
#ifndef KYC_H
#define KYC_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"

#define KYC_SCREEN_NONE 0
#define KYC_SCREEN_MAP 1      /* the war table (UI screen 15) */
#define KYC_SCREEN_BRIEFING 2 /* the briefing (UI screen 14) */
const char* kyc_screen_name(int screen);

/* ---- errors -------------------------------------------------------------------------------------------------- */

typedef struct KycError
{
    const char* pending; /* the transient state's reason (a constant), or NULL */
    char failure[192];   /* a genuine error's text, or "" */
} KycError;
extern KycError kyc_error;
int kyc_pending(const char* reason);                                    /* records it; returns 0 */
int kyc_fail(const char* format, ...) __attribute__((format(printf, 1, 2))); /* records it; returns 0 */
void kyc_error_clear(void);
/* The recorded error's text (describe() in the Lua): the reason, or the failure. */
const char* kyc_error_text(void);

/* ---- the component (install.lua) ---------------------------------------------------------------------------- */

/* What the component reports (the Lua's EnemyIntelligence table), for the tests. */
typedef struct KycState
{
    const char* status;
    uint32_t frames, refreshes, failures, pending; /* refreshes: the Lua's reads (samples taken) */
    int burst_errors;                              /* genuine errors in the current burst (8 stop it) */
    int has_key;
    const char* key;
    int screen;
    int complete;
} KycState;
const KycState* kyc_state(void);
struct KycReaders;
/* The readers the frame uses: NULL for the game's (kyc_mission.c, kyc_presentation.c). For the tests. */
void kyc_use_readers(const struct KycReaders* readers);

/* ---- the mission (mission.lua) ------------------------------------------------------------------------------- */

#define KYC_MAX_TAGS 16
#define KYC_MAX_WEIGHTS 64

typedef struct KycKey
{
    uint32_t seed, secondary, planet;
    uint8_t faction, difficulty;
    uint16_t mission;
    char text[72]; /* "seed:secondary:faction:difficulty:planet:mission", as the Lua's key */
} KycKey;

/* The highlighted mission's identity and the records a sample reads (descriptor() in the Lua). */
typedef struct KycDescriptor
{
    KycKey key;
    int screen;
    int controller_matches;  /* the loaded controller holds the same mission */
    uintptr_t address, controller, board, root;
    int has_preview;         /* a joinable mission's advertised planet (a remote hover) */
    uint32_t preview_planet;
    int has_operation;       /* the highlighted local operation */
    uint32_t operation_planet, operation_index;
} KycDescriptor;

/* Spawn-weight multipliers by enemy family hash (the Lua's zone and war tables). */
typedef struct KycWeights
{
    int count;
    uint32_t family[KYC_MAX_WEIGHTS];
    double value[KYC_MAX_WEIGHTS];
} KycWeights;

/* The full forecast inputs (sample() in the Lua). */
typedef struct KycSnapshot
{
    KycDescriptor d;
    int tag_count;
    uint8_t tags[KYC_MAX_TAGS]; /* authored tag ids, in order */
    int complete;
    KycWeights zone;            /* campaign spawn weights (none: count 0) */
    KycWeights war;             /* war effects (none: count 0) */
    int unresolved;             /* reasons the sample is not complete */
    char first_unresolved[128];
} KycSnapshot;

/* The readers the frame uses (the real ones, or a test's). Each returns 1, or 0 after an error. */
typedef struct KycAnchor
{
    double x, y, w, h, scale; /* the native panel's solved rectangle (y up) and UI scale */
    int client;               /* 1: a client's planet frame (a joinable hover); then active says whether its card is */
    int active;
    uint64_t font, material, atlas; /* the native body font, its material and glyph atlas (resource hashes) */
    int screen;
} KycAnchor;

#define KYC_HOVER_UNKNOWN (-1)
typedef struct KycReaders
{
    int (*screen)(int* screen);  /* the forecast screen on top of the UI stack, or KYC_SCREEN_NONE */
    int (*quiet)(void);          /* the idle gate: 1 when the kept stack shows neither screen; never an error */
    /* *found 0 when no mission is selected; *hovered 1, 0 or KYC_HOVER_UNKNOWN */
    int (*descriptor)(int screen, KycDescriptor* out, int* found, int* hovered);
    int (*sample)(int screen, KycSnapshot* out, int* found);
    int (*anchor)(int screen, KycAnchor* out, int* found);
} KycReaders;

const KycReaders* kyc_game_readers(void);
/* The native panel's anchor (kyc_presentation.c): the game's KycReaders.anchor. */
int kyc_presentation_sample(int screen, KycAnchor* out, int* found);
void kyc_mission_reset(void);
/* The settings row of a difficulty level (816 bytes): HellForge's moved table when it has one (difficulty_row: level
 * 11 added), else the game's own at game.dll 0x328D2A0. Checked by its level (+4). 1, or 0 after an error. */
int kyc_difficulty_row(uint32_t level, uint8_t* row);
/* The highest level a mission may have: 11 once HellForge has added level 11, else 10. */
uint32_t kyc_highest_level(void);

/* ---- the constellation draw (resolve.lua) ------------------------------------------------------------------- */

typedef struct KycCandidate { uint8_t id; float weight; uint8_t only_when_empty; } KycCandidate;
typedef struct KycSettings
{
    uint32_t draws;
    uint8_t fallback;
    KycCandidate candidates[8];
    int blocker_count;
    uint8_t blockers[8];
} KycSettings;
typedef struct KycTags { int count; uint8_t tag[KYC_MAX_TAGS]; } KycTags;

int kyc_tag_add(KycTags* tags, uint32_t tag);
int kyc_from_native(uint32_t tag, uint8_t* out);
/* The tags a mission's seed draws (resolve.base). */
int kyc_draw_base(uint32_t seed, const KycSettings* settings, const KycTags* initial, KycTags* out);
/* The tags neither excluded nor disabled (bit t of each mask: tag t), in order. */
int kyc_tag_filter(const KycTags* tags, uint32_t excluded, uint32_t disabled, KycTags* out);
uint32_t kyc_exclusion_key(int has_hash, uint32_t hash);
/* One step of the game's 64-bit generator. */
uint64_t kyc_draw_step(uint64_t state);

/* ---- the roster (roster.lua) -------------------------------------------------------------------------------- */

#define KYC_MAX_LISTED 80
typedef struct KycReport
{
    int large_count, small_count;
    uint8_t large[KYC_MAX_LISTED];        /* names indexes, most common first */
    uint8_t large_ticks[KYC_MAX_LISTED];
    uint8_t small[KYC_MAX_LISTED];
} KycReport;

/* faction 2 .. 4, difficulty 1 .. 10; zone and war may be NULL or empty. */
int kyc_roster_compute(int faction, int difficulty, const KycTags* tags, const KycWeights* zone, const KycWeights* war,
    KycReport* out);
/* The one-entry cache: the report for these inputs, computed again only when they change. */
int kyc_roster_report(int faction, int difficulty, const KycTags* tags, const KycWeights* zone, const KycWeights* war,
    const KycReport** out);
void kyc_roster_reset(void);
uint32_t kyc_roster_computed(void);
int kyc_roster_ticks(double share);
int kyc_name_count(void);
const char* kyc_name_text(int index);
const char* kyc_name_key(int index);
int kyc_name_size(int index);
int kyc_name_find(const char* text); /* the index of a display name, 0 none */

/* ---- the model (model.lua) ---------------------------------------------------------------------------------- */

#define KYC_HEADLINE_SIZE 640
typedef struct KycModel
{
    KycKey key;
    int screen;
    int pending;              /* the pending model: frame and captions only */
    char headline[KYC_HEADLINE_SIZE];
    int has_headline;
    int large_count, small_count;
    const char* large[KYC_MAX_LISTED];
    uint8_t ticks[KYC_MAX_LISTED];
    const char* small[KYC_MAX_LISTED];
    const char *label, *footer, *more, *separator, *large_caption, *rate_caption, *small_caption, *order_caption;
    uint64_t signature;       /* every drawn text: equal signatures draw the same */
} KycModel;

#define KYC_PENDING_SIGNATURE 1ull
const char* kyc_title_key(int tag);
const char* kyc_title_text(const VpmComponent* self, int tag);
/* The headline: subfactions, strains and operation modifiers first, then the base constellations. */
int kyc_headline(const VpmComponent* self, const KycTags* tags, char* out, size_t size);
int kyc_model_make(const VpmComponent* self, const KycSnapshot* snapshot, const KycReport* report, KycModel* out);
/* The pending model of a drawn one: key, screen, label and footer. */
void kyc_model_pending(const KycModel* drawn, KycModel* out);

/* ---- text (bingus_text.lua) --------------------------------------------------------------------------------- */

/* The first length bytes of text are valid UTF-8 without control characters: 1, or 0 with *bad the 1-based byte and
 * *why ("invalid UTF-8"...). Code points and lengths in characters: the core's vpm_utf8_decode and vpm_utf8_length. */
int kyc_text_check(const char* text, size_t length, size_t* bad, const char** why);
/* Byte offsets (0-based) where each character starts, then length: their count (characters + 1), or -1 when there is
 * no room for them in out. */
int kyc_text_boundaries(const char* text, size_t length, uint16_t* out, int capacity);
typedef int (*KycMeasureFn)(void* context, const char* text, size_t length, double* width); /* 1, or 0 after an error */
typedef struct KycLine { size_t at, length; } KycLine;
/* Lines no wider than width (offsets into text): their count, or -1 after an error ("Text column too narrow"). */
int kyc_text_wrap(const char* text, size_t length, double width, KycMeasureFn measure, void* context, KycLine* lines,
    int capacity);

#endif
