/* Know Your Constellation's native panel reader (presentation.lua): the solved screen rectangle and opacity of the
 * native operation, briefing or planet panel the forecast hangs below, and the active locale's body font, its
 * material and glyph atlas. It never changes native widgets. Reads land in buffers it keeps; the font, material and
 * atlas are resource hashes (the Lua formatted them as hex text for IdString64.from_hex). On HellForge the statics are
 * plain loads (the Lua read them with ReadProcessMemory). */
#include <math.h>
#include "kyc_mission.h"

#define DATA_UNAVAILABLE "Presentation data unavailable"
#define OWNER_UNAVAILABLE "Presentation owner unavailable"
#define FONT_NOT_READY "Native font is not ready"
#define RVA_FONT 0x3772268u       /* the active locale's body face (the native font initializer 0xf553c0 fills these) */
#define RVA_MATERIAL 0x37C5478u   /* its normal material: the hash at +24 */
#define RVA_ATLAS 0x3772EE8u
#define MAP_REGISTRY 25224u       /* the menu manager's event registries: one inline subscriber {count, _, owner, kind} */
#define BRIEFING_REGISTRY 25272u
#define MAP_KIND 226u
#define BRIEFING_KIND 229u
#define MAP_FRAME 349072u         /* the owner's widgets: the operation frame (map), the briefing frame */
#define BRIEFING_FRAME 31232u
#define PLANET_FRAME 280528u      /* the planet frame of a remote hover */
#define CARD 526048u              /* the joinable mission's card */

static uint8_t g_widget[164];

static int Read(uintptr_t address, void* out, size_t size)
{
    return vpm_read(address, out, size) ? 1 : kyc_pending(DATA_UNAVAILABLE);
}

static int Out(double v) { return v != v || v < 0 || v > 32768; }

/* The widget's solved rectangle, when it is fully visible. +84 is the inherited opacity (the pod entry animation
 * included); +68 alone is local and can stay 1 while its parent is hidden. */
static int Rectangle(uintptr_t owner, uint32_t offset, KycAnchor* box, int* visible)
{
    *visible = 0;
    if (!Read(owner + offset, g_widget, sizeof g_widget)) return 0;
    double opacity = kyc_f32(g_widget + 84);
    if ((kyc_u32(g_widget) & 0x10u) == 0 || !(opacity >= 0.995 && opacity <= 1.01)) return 1;
    double sx = kyc_f32(g_widget + 100), sy = kyc_f32(g_widget + 140);
    double x = kyc_f32(g_widget + 148), y = kyc_f32(g_widget + 156);
    double w = (double)kyc_f32(g_widget + 36) * sx, h = (double)kyc_f32(g_widget + 40) * sy;
    if (Out(x) || Out(y) || Out(w) || Out(h) || Out(sx)) return 1;
    if (sx < 0.3 || sx > 4 || fabs(sx - sy) > 0.01 || w < 200 || h < 40) return 1;
    box->x = x;
    box->y = y;
    box->w = w;
    box->h = h;
    box->scale = sx;
    *visible = 1;
    return 1;
}

/* The operation or briefing frame; on the map, else the planet frame of a remote hover. The planet frame stays fixed
 * while joinable cards move and fade between hovers; its card's activity tells a hover from a dismissed one. */
static int Frame(uintptr_t owner, int screen, KycAnchor* box, int* visible)
{
    box->client = box->active = 0;
    if (!Rectangle(owner, screen == KYC_SCREEN_MAP ? MAP_FRAME : BRIEFING_FRAME, box, visible)) return 0;
    if (*visible || screen != KYC_SCREEN_MAP) return 1;
    if (!Rectangle(owner, PLANET_FRAME, box, visible)) return 0;
    if (!*visible) return 1;
    uint8_t card[88];
    if (!Read(owner + CARD, card, sizeof card)) return 0;
    double opacity = kyc_f32(card + 84);
    box->client = 1;
    box->active = (kyc_u32(card) & 0x10u) != 0 && opacity > 0.001 && opacity <= 1.01;
    return 1;
}

/* A resource hash; none yet hides the panel at once (the font table is not ready). */
static int Hash(uintptr_t address, int image, uint64_t* out)
{
    uint8_t b[8];
    if (image ? !vpm_game_read((uint32_t)address, b, 8) : !vpm_read(address, b, 8)) return kyc_pending(DATA_UNAVAILABLE);
    memcpy(out, b, 8);
    return *out != 0 ? 1 : kyc_pending(FONT_NOT_READY);
}

/* The menu manager's subscriber for this screen: the owner of the native panel, or 0. These registries have one
 * inline subscriber; a zero count can leave a stale pointer behind, so it is never followed without the count. */
static int Owner(int screen, uintptr_t* owner)
{
    uint8_t b[8], entry[24];
    *owner = 0;
    if (!vpm_game_read(KYC_RVA_MENU, b, 8)) return kyc_pending(DATA_UNAVAILABLE);
    uintptr_t manager = kyc_pointer_at(b);
    if (manager == 0) return kyc_pending(OWNER_UNAVAILABLE);
    if (!Read(manager + (screen == KYC_SCREEN_MAP ? MAP_REGISTRY : BRIEFING_REGISTRY), entry, sizeof entry)) return 0;
    if (kyc_u32(entry) != 1 || kyc_u32(entry + 16) != (screen == KYC_SCREEN_MAP ? MAP_KIND : BRIEFING_KIND)) return 1;
    *owner = kyc_pointer_at(entry + 8);
    if (*owner == 0 || screen != KYC_SCREEN_BRIEFING) return 1;
    uint8_t tab[4];
    if (!Read(*owner + 8, tab, sizeof tab)) return 0;
    if (kyc_u32(tab) != 0) *owner = 0; /* the loadout (or another tab) is up */
    return 1;
}

/* The native panel's anchor for the screen, *found 0 when it is absent or mid-layout. lint: per-frame */
int kyc_presentation_sample(int screen, KycAnchor* out, int* found)
{
    uintptr_t owner, material;
    int visible;
    KycAnchor box;
    *found = 0;
    if (screen != KYC_SCREEN_MAP && screen != KYC_SCREEN_BRIEFING) return 1;
    if (!Owner(screen, &owner)) return 0;
    if (owner == 0) return 1;
    if (!Frame(owner, screen, &box, &visible)) return 0;
    if (!visible) return 1;
    uint8_t b[8];
    if (!Hash(RVA_FONT, 1, &box.font)) return 0;
    if (!vpm_game_read(RVA_MATERIAL, b, 8)) return kyc_pending(DATA_UNAVAILABLE);
    material = kyc_pointer_at(b);
    if (material == 0) return kyc_pending(OWNER_UNAVAILABLE);
    if (!Hash(material + 24, 0, &box.material) || !Hash(RVA_ATLAS, 1, &box.atlas)) return 0;
    box.screen = screen;
    *out = box;
    *found = 1;
    return 1;
}
