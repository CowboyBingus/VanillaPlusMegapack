/* Foliage Pass-Through v1.0 (Lua: components/FoliagePassThrough/src/foliage_pass_through.lua), for build 25480438.
 *
 * Rockets, launcher rounds and stratagem ordnance explode in tree canopies and bushes. Every projectile casts its flight
 * ray with the collision query its ProjectileInfo row names (raycast_template, +0xF4; the simulation game.dll 0x13AB0E0
 * reads it every step). Template 0 is damage_query, which collides with the 'foliage' layer; template 2 is
 * damage_no_foliage_query, the same query without it. The game already gives plasma bolts and lasers template 2. This
 * gives it to the player-side projectiles that explode on impact (foliage_targets.h): one 4-byte store per row, once per
 * session, in the loaded projectile settings (committed private read-write memory). Trunks and limbs, terrain,
 * buildings and every unit still stop them. Enemy projectiles stay vanilla.
 *
 * On HellForge: rows are found through the projectile list the game reads now. HellForge moves that list when mods add
 * projectile types and rewrites every instruction that reads it, so the list is taken from the displacement of one of
 * them (game.dll 0x75A391, `mov rax, [rcx + rax*8 + list]`), not from the vanilla address. HellForge's live edits cannot
 * name raycast_template (not a reviewed field), hence the direct store. Each row is checked first (type, name hash,
 * impact explosion, a template of 0 or 2), as the Lua did; anything unexpected changes nothing. The reader's code is
 * checked with vpm_when_code_ready, from HF_EVENT_GAME_LOADED: game.dll's code is decoded in parts after that event, and
 * HF_EVENT_PROJECTILES_READY can come before this part is (HellForge gives its own projectile pins 20 s once the list
 * has loaded), so the list is not taken before the reader's bytes read as shipped. The core stops the component if they
 * never do within 60 s ("the projectile list's reader changed (game.dll 0x75A391)"), with nothing changed.
 *
 * Cost: once per session, at HF_EVENT_GAME_LOADED: 1 code check (code_matches; the core repeats it every 30 frames while
 * the code is not decoded yet, for at most 60 s). At HF_EVENT_PROJECTILES_READY (or when the code is decoded, if that
 * comes later): 1 read of the list (2808 bytes), 1 read per target row, one page check (VirtualQuery) of the span holding
 * every changed template, a store per changed row and a read-back per row: 199 reads and 1 VirtualQuery for 99 rows (the
 * Lua: 200 reads and 1 page check). Nothing per frame afterwards. If the settings are not loaded yet, a tick waits with
 * one plain load per frame (no Windows call), for at most 600 s. */
#include <string.h>
#include "../../core/vpm.h"
#include "foliage_targets.h"

#define BUFFER_RVA 0x348E2F8u  /* the loaded generated_projectile_settings buffer (loader 0x11EC5A0) */
#define LIST_SITE 0x75A391u    /* mov rax, qword ptr [rcx + rax*8 + 0x37C7670]: the list's reader in 0x75A0D0 */
#define VANILLA_LIST 0x37C7670u
#define SLOTS 351u             /* the game's types 0 .. 350 */
#define ROW_SIZE 0x110u        /* ProjectileInfo */
#define AT_TYPE 0x00u
#define AT_NAME 0x08u
#define AT_EXPLOSION 0x90u
#define AT_TEMPLATE 0xF4u
#define VANILLA 0u             /* RaycastTemplate_Damage */
#define NO_FOLIAGE 2u          /* RaycastTemplate_DamageNoFoliage */
#define WAIT_SECONDS 600.0f

static struct
{
    uintptr_t rows[FOLIAGE_TARGET_COUNT];
    uint8_t changed[FOLIAGE_TARGET_COUNT]; /* this session set it from 0 to 2 */
    float waited;
    int applied;
    int code_ready;        /* the reader's bytes read as shipped (CodeReady) */
    int projectiles_ready; /* HF_EVENT_PROJECTILES_READY came first: CodeReady takes it up */
} s;

static const VpmCodePin kPins[] = {
    {LIST_SITE, "48 8B 84 C1", "the projectile list's reader", 0},
};

static uint64_t g_list[SLOTS]; /* the list as read at the apply (static: 2808 bytes, off the game thread's stack) */

static uint32_t U32(const uint8_t* row, uint32_t at)
{
    uint32_t value;
    memcpy(&value, row + at, 4);
    return value;
}

/* The list the game reads now, from its reader's displacement (relative to game.dll's base), or 0. The reader's code
 * was checked before (CodeReady). */
static uintptr_t CurrentList(VpmComponent* self)
{
    int32_t displacement;
    if (!vpm_game_read(LIST_SITE + 4, &displacement, 4))
    {
        vpm_fail(self, "the projectile list's reader at game.dll 0x%X is not the reviewed one", LIST_SITE);
        return 0;
    }
    if ((uint32_t)displacement != VANILLA_LIST) vpm_log(self, "the projectile list was moved by HellForge (game.dll %+d)", displacement);
    return vpm_game() + (uintptr_t)(intptr_t)displacement;
}

/* Checks one target's row; 1 with s.rows[i] set, or 0 after vpm_fail. */
static int CheckRow(VpmComponent* self, int i, uint32_t* template)
{
    const FoliageTarget* t = &kFoliageTargets[i];
    uint8_t row[ROW_SIZE];
    uintptr_t at = t->type < SLOTS ? (uintptr_t)g_list[t->type] : 0;
    if (at == 0) { vpm_fail(self, "No projectile settings for %s", t->label); return 0; }
    if (!vpm_read(at, row, sizeof row)) { vpm_fail(self, "Projectile settings unreadable: %s", t->label); return 0; }
    if (U32(row, AT_TYPE) != t->type || U32(row, AT_NAME) != t->name || U32(row, AT_EXPLOSION) != t->explosion)
    {
        vpm_fail(self, "Unexpected projectile settings for %s (type %u)", t->label, t->type);
        return 0;
    }
    *template = U32(row, AT_TEMPLATE);
    if (*template != VANILLA && *template != NO_FOLIAGE)
    {
        vpm_fail(self, "Unexpected raycast template %u for %s", *template, t->label);
        return 0;
    }
    s.rows[i] = at;
    return 1;
}

/* Every target's row checked (templates[] filled); the number still to change, with the span of their templates, or
 * -1 after vpm_fail. */
static int CheckAll(VpmComponent* self, uint32_t* templates, uintptr_t* low, uintptr_t* high)
{
    int pending = 0;
    *low = UINTPTR_MAX;
    *high = 0;
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
    {
        if (!CheckRow(self, i, &templates[i])) return -1;
        if (templates[i] == NO_FOLIAGE) continue;
        pending++;
        if (s.rows[i] < *low) *low = s.rows[i];
        if (s.rows[i] > *high) *high = s.rows[i];
    }
    return pending;
}

/* The stores, then a read-back of every row's template: 1, or 0 after vpm_fail. */
static int StoreAll(VpmComponent* self, const uint32_t* templates)
{
    const uint32_t value = NO_FOLIAGE;
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
    {
        if (templates[i] == NO_FOLIAGE) continue;
        memcpy((void*)(s.rows[i] + AT_TEMPLATE), &value, 4);
        s.changed[i] = 1;
    }
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
    {
        uint32_t now;
        if (!vpm_read_u32(s.rows[i] + AT_TEMPLATE, &now) || now != NO_FOLIAGE)
        {
            vpm_fail(self, "Projectile settings write did not hold");
            return 0;
        }
    }
    return 1;
}

/* Every row checked, then one page check over the span of the templates to change, the stores and their read-backs. */
static void Apply(VpmComponent* self)
{
    uintptr_t list = CurrentList(self);
    if (list == 0) return;
    if (!vpm_read(list, g_list, sizeof g_list)) { vpm_fail(self, "Projectile index unreadable"); return; }
    uint32_t templates[FOLIAGE_TARGET_COUNT];
    uintptr_t low, high;
    int pending = CheckAll(self, templates, &low, &high);
    if (pending < 0) return;
    if (pending > 0 && !vpm_writable(low + AT_TEMPLATE, high - low + 4))
    {
        vpm_fail(self, "Projectile settings write refused or failed");
        return;
    }
    if (!StoreAll(self, templates)) return;
    s.applied = 1;
    vpm_set_status(self, "applied");
    vpm_log(self, "applied: %d projectile types use the no-foliage query (%d changed now, %d already changed)",
        FOLIAGE_TARGET_COUNT, pending, FOLIAGE_TARGET_COUNT - pending);
}

static int SettingsLoaded(void) { return vpm_game_u64(BUFFER_RVA) != 0; }

/* The fallback while the settings are not loaded yet: one plain load per frame. lint: per-frame */
static void Wait(VpmComponent* self, float dt)
{
    if (!SettingsLoaded())
    {
        s.waited += dt;
        if (s.waited >= WAIT_SECONDS) vpm_fail(self, "gave up after %.0f s: the projectile settings are not loaded yet", WAIT_SECONDS);
        return;
    }
    vpm_tick_stop(self);
    Apply(self);
    if (s.applied) vpm_log(self, "applied after %.1f s of waiting", s.waited);
}

static void ProjectilesReady(VpmComponent* self, HfEvent event)
{
    if (s.applied) return;
    if (!s.code_ready) { s.projectiles_ready = 1; return; }
    if (SettingsLoaded()) { Apply(self); return; }
    vpm_log(self, "Waiting for the game: the projectile settings are not loaded yet.");
    vpm_set_status(self, "waiting: the projectile settings are not loaded yet");
    vpm_tick_start(self, Wait);
}

/* Puts the vanilla template back on the rows this start changed (a switch-off, or the core stopping the component):
 * every changed row that still holds the no-foliage template, after one page check over their span, as Apply's (a
 * switch-off runs on a game frame: one VirtualQuery per row would be up to 99). */
static void Stop(VpmComponent* self)
{
    const uint32_t value = VANILLA;
    int back[FOLIAGE_TARGET_COUNT];
    uintptr_t low = UINTPTR_MAX, high = 0;
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
    {
        uint32_t now;
        back[i] = s.changed[i] && vpm_read_u32(s.rows[i] + AT_TEMPLATE, &now) && now == NO_FOLIAGE;
        s.changed[i] = 0;
        if (!back[i]) continue;
        if (s.rows[i] < low) low = s.rows[i];
        if (s.rows[i] > high) high = s.rows[i];
    }
    if (high == 0 || !vpm_writable(low + AT_TEMPLATE, high - low + 4)) return;
    for (int i = 0; i < FOLIAGE_TARGET_COUNT; i++)
        if (back[i]) memcpy((void*)(s.rows[i] + AT_TEMPLATE), &value, 4);
}

/* The reader's bytes read as shipped: the event's work, if it came first. */
static void CodeReady(VpmComponent* self, HfEvent event)
{
    s.code_ready = 1;
    if (s.projectiles_ready) ProjectilesReady(self, HF_EVENT_PROJECTILES_READY);
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    if (!vpm_when_code_ready(self, kPins, 1, CodeReady)) return 1;
    return vpm_on_load(self, HF_EVENT_PROJECTILES_READY, ProjectilesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_foliage_pass_through = {"foliage_pass_through", "Foliage Pass-Through", "1.0", 0, Start, Stop};
