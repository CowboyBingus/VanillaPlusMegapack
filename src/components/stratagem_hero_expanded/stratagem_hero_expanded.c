/* Stratagem Hero Expanded v1.0 (Lua: components/StratagemHeroExpanded/src/stratagem_hero_expanded.lua), for build
 * 25480438.
 *
 * The ship's Stratagem Hero arcade draws its stratagems from two fixed tables in game.dll's writable data section: 9
 * round tiers, each a weighted list of up to 8 groups (0x263CCC0, 68 bytes each), and 10 groups of up to 16 stratagem
 * types (0x263CF70, 64 bytes each). The picker is game.dll 0x598370, called by the arcade's round logic 0x5970D0.
 * Vanilla reaches 27 launch-era stratagems. This rewrites both tables once per session so the arcade draws from every
 * stratagem a loadout can hold plus the 12 mission stratagems every squad calls (108), grouped by the class each
 * stratagem's settings give it (arcade_pool.h). The four themed rounds keep their banners and their theme's share of
 * the picks; the other rounds give every stratagem the same odds. The game's own picker, widget and input check read the
 * new tables.
 *
 * Before writing, as the Lua did: every pool stratagem's settings row must name its own type, have a code of 1 to 10
 * inputs with a pointer, and a HUD type of 0-4 (a stratagem without settings would crash the arcade's widget, and a
 * data-only game update can change the rows without changing the binaries). Both tables must hold build 25480438's
 * exact bytes (the expanded bytes mean already applied; anything else refuses). Their pages must be committed image
 * pages of game.dll that can be written (read-write or copy-on-write, or their executable forms), checked with one
 * VirtualQuery per region; protection is never changed. Then two stores (612 and 640 bytes; the 76 bytes between the
 * tables belong to other code and are never written) and a read back.
 *
 * On HellForge:
 * - The rows are found through the stratagem list the game reads now, never the vanilla list 0x37CB600, which HellForge
 *   moves when mods add stratagems (it rewrites every instruction that reads the list). The list is the displacement of
 *   the arcade widget's own row lookup, game.dll 0x17EF922 (`mov r14, [rcx + rax*8 + list]` in 0x17EED90, the widget
 *   that shows the current stratagem's icon, colour and code). HellForge's get_live could read type, code_length and
 *   hud_type, but not the code pointer (it reads 1- and 4-byte fields only), and would make three lookups per
 *   stratagem where one row read does.
 * - Plain loads where the Lua read through ReadProcessMemory: the reader's displacement, the tables, and the list while
 *   it lies in game.dll's image (the game's own; HellForge's moved copy lies outside it and is read with vpm_read). The
 *   rows are heap memory: vpm_read.
 * - The tables lie in game.dll's .data section (section 3, RVA 0x263C000, flags 0xC0000040: initialised read-write
 *   data), and the Lua's live log saw PAGE_READWRITE pages ("pages 0x04, 0x04"). So plain stores do what the Lua's
 *   WriteProcessMemory did; vpm_write, which changes protection, is not needed, and pages that fail the check refuse as
 *   in the Lua.
 * - When: the attempt runs at HF_EVENT_GAME_LOADED (the Lua's install), once the reader's code reads as shipped:
 *   game.dll's code is decoded in parts after that event, so the reader is checked with vpm_when_code_ready, at the
 *   event and then every 30 frames until it matches; the core stops the component if it never does within 60 s
 *   ("the stratagem list's reader changed (game.dll 0x17EF922)"), with nothing written. While the game has not loaded
 *   its stratagem settings (the Reinforce row's pointer is unset), a tick waits, as the Lua's self-removing update hook
 *   did.
 * - Dropped: the shutdown report (no shutdown event), the build hash check (the core checks the build), the Lua
 *   loader's checks and its update-chain handling (the core's tick replaces them).
 *
 * Cost (the Lua's frame_budget pins in brackets):
 * - Once, at HF_EVENT_GAME_LOADED: one check of the reader's code bytes (HfApi.code_matches, which reads them with one
 *   ReadProcessMemory) [the Lua: the build check instead]; while game.dll's code there is not decoded yet, the same
 *   check every 30 frames (at most 60 s), and the attempt on the frame it matches.
 * - The applying attempt, once: the probe slot and the list (1,200 bytes) as plain loads, 108 row reads (vpm_read, 192
 *   bytes each), the tables (1,328 bytes) as a plain load, 2 VirtualQuery (one per table), 2 stores of 612 and 640
 *   bytes, the read back as a plain load: 108 reads, 2 page queries [112 reads, 2 page queries, 2 WriteProcessMemory].
 *   With HellForge's moved list, the probe and the list are 2 reads more (110). Already applied: 108 reads [111].
 * - Waiting, only if the settings load after HF_EVENT_GAME_LOADED: 2 plain loads per frame (the reader's displacement
 *   and the probe slot), no API or Windows call [1 ReadProcessMemory per frame], for at most 600 s of game time.
 *   HellForge moves the list only once the settings are loaded, so the waiting list is the game's own.
 * - Nothing per frame afterwards: the tick stops. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "../../core/vpm.h"
#include "arcade_pool.h"
#include "stratagem_hero_expanded.h"

#define TIERS_RVA 0x263CCC0u    /* game.dll: 9 tiers of 68 bytes {u32 banner, 8 x {u32 group, f32 weight}} */
#define GROUPS_RVA 0x263CF70u   /* game.dll: 10 groups of 64 bytes, up to 16 u32 stratagem types, 0 ends a group */
#define TIER_SIZE 68u
#define GROUP_SIZE 64u
#define SPAN (GROUPS_RVA + GROUPS * GROUP_SIZE - TIERS_RVA) /* both tables and the 76 bytes between them */
#define AT_GROUPS (GROUPS_RVA - TIERS_RVA)
#define LIST_SITE 0x17EF922u    /* mov r14, qword ptr [rcx + rax*8 + 0x37CB600]: the arcade widget's row lookup */
#define VANILLA_LIST 0x37CB600u /* StratagemInfo pointers by stratagem type, 8 bytes each */
#define TYPES 150u              /* StratagemType values of this build, None (0) included */
#define PROBE 124u              /* Reinforce: once its settings pointer is set, the stratagem settings are loaded */
#define INFO_SIZE 0xC0u         /* StratagemInfo: its type, its code (pointer, count) and its HUD type (icon colour) */
#define INFO_TYPE 0x00u
#define INFO_CODE 0x40u
#define INFO_CODE_LENGTH 0x48u
#define INFO_HUD 0xB8u
#define MAX_CODE 10u            /* the arcade's widget lays out at most 10 arrows */
#define MAX_HUD 4u              /* 5 icon colours */
#define WAIT_SECONDS 600.0f

/* Attempt's results */
#define ATTEMPT_WAIT 0
#define ATTEMPT_DONE 1
#define ATTEMPT_FAILED (-1)

typedef struct Tables { uint8_t tiers[TIERS * TIER_SIZE]; uint8_t groups[GROUPS * GROUP_SIZE]; } Tables;
typedef enum Holding { HOLDS_UNREADABLE, HOLDS_OTHER, HOLDS_VANILLA, HOLDS_EXPANDED } Holding;

const StratagemHeroNative* stratagem_hero_expanded_native;

static struct
{
    Tables vanilla, expanded; /* build 25480438's tables and the expanded ones, encoded at start */
    int pool;                 /* stratagems in the expanded pool (108) */
    float waited;
    int wrote;                /* this session stored the expanded tables */
    int done;                 /* applied, or found already applied */
    char status[160];
} s;

static uint64_t g_list[TYPES]; /* the list as read at the attempt (static: 1,200 bytes) */
static uint8_t g_span[SPAN];   /* the tables as read */

static void Put32(uint8_t* at, uint32_t value) { memcpy(at, &value, 4); }
static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t U64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }

/* ---- the tables ------------------------------------------------------------------------------------------------- */

static void EncodeTiers(const ArcadeTier* tiers, uint8_t* out)
{
    for (int t = 0; t < TIERS; t++)
    {
        uint8_t* record = out + t * TIER_SIZE;
        Put32(record, tiers[t].banner);
        for (int e = 0; e < TIER_ENTRIES && tiers[t].picks[e].group != 0; e++)
        {
            float weight = (float)tiers[t].picks[e].weight;
            Put32(record + 4 + e * 8, tiers[t].picks[e].group);
            memcpy(record + 8 + e * 8, &weight, 4);
        }
    }
}

/* Groups 1 .. count from lists (0 ends one); group 0 and the groups after them stay empty. */
static void EncodeGroups(const uint32_t (*groups)[GROUP_SLOTS], int count, uint8_t* out)
{
    for (int g = 0; g < count; g++)
        for (int i = 0; i < GROUP_SLOTS && groups[g][i] != 0; i++) Put32(out + (g + 1) * GROUP_SIZE + i * 4, groups[g][i]);
}

static int GroupSize(const uint32_t* group)
{
    int n = 0;
    while (n < GROUP_SLOTS && group[n] != 0) n++;
    return n;
}

/* One expanded tier: every group weighted by its size, so each stratagem is equally likely, except that a theme's
 * groups (listed first, as in vanilla) together get the theme's share of the picks. The Lua's tier_entries, with its
 * arithmetic in the same order. */
static void ExpandedTier(int tier, const int* sizes, int total, ArcadeTier* out)
{
    const ArcadeTheme* theme = tier < THEMED_TIERS ? &kThemes[tier] : NULL;
    int themed[POOL_GROUPS + 1] = {0}, themeTotal = 0, n = 0;
    for (int i = 0; theme != NULL && i < 2 && theme->groups[i] != 0; i++)
    {
        themed[theme->groups[i]] = 1;
        themeTotal += sizes[theme->groups[i] - 1];
    }
    double scale = 1;
    if (theme != NULL) scale = theme->share / (1 - theme->share) * (double)(total - themeTotal) / (double)themeTotal;
    out->banner = kVanillaTiers[tier].banner;
    for (int i = 0; theme != NULL && i < 2 && theme->groups[i] != 0; i++)
        out->picks[n++] = (ArcadePick){theme->groups[i], (double)sizes[theme->groups[i] - 1] * scale};
    for (uint32_t g = 1; g <= POOL_GROUPS; g++)
        if (!themed[g]) out->picks[n++] = (ArcadePick){g, (double)sizes[g - 1]};
}

/* Build 25480438's tables and the expanded ones, as bytes. */
static void EncodeAll(void)
{
    ArcadeTier tiers[TIERS];
    int sizes[POOL_GROUPS], total = 0;
    memset(tiers, 0, sizeof tiers);
    for (int g = 0; g < POOL_GROUPS; g++)
    {
        sizes[g] = GroupSize(kPool[g]);
        total += sizes[g];
    }
    for (int t = 0; t < TIERS; t++) ExpandedTier(t, sizes, total, &tiers[t]);
    EncodeTiers(kVanillaTiers, s.vanilla.tiers);
    EncodeGroups(kVanillaGroups, GROUPS - 1, s.vanilla.groups);
    EncodeTiers(tiers, s.expanded.tiers);
    EncodeGroups(kPool, POOL_GROUPS, s.expanded.groups);
    s.pool = total;
}

/* What the arcade's tables hold: one plain load of both. */
static Holding Holds(void)
{
    if (!vpm_game_read(TIERS_RVA, g_span, SPAN)) return HOLDS_UNREADABLE;
    const Tables* known[2] = {&s.vanilla, &s.expanded};
    for (int i = 0; i < 2; i++)
        if (memcmp(g_span, known[i]->tiers, sizeof known[i]->tiers) == 0 &&
            memcmp(g_span + AT_GROUPS, known[i]->groups, sizeof known[i]->groups) == 0)
            return i == 0 ? HOLDS_VANILLA : HOLDS_EXPANDED;
    return HOLDS_OTHER;
}

/* ---- the stratagem settings ------------------------------------------------------------------------------------- */

/* The list the game reads now: game.dll plus the widget reader's displacement, which HellForge rewrites when it moves
 * the list. One plain load; 0 when unreadable. */
static uintptr_t CurrentList(void)
{
    int32_t displacement = 0;
    if (!vpm_game_read(LIST_SITE + 4, &displacement, 4)) return 0;
    return vpm_game() + (uintptr_t)(intptr_t)displacement;
}

/* Bytes of the list: plain loads while it lies in game.dll's image (the game's own list), vpm_read otherwise
 * (HellForge's moved copy). */
static int ListRead(uintptr_t list, size_t offset, void* out, size_t size)
{
    uintptr_t at = list + offset, game = vpm_game();
    if (game != 0 && at >= game && at - game < vpm_game_size()) return vpm_game_read((uint32_t)(at - game), out, size);
    return vpm_read(at, out, size);
}

/* Whether the game has loaded its stratagem settings: the probe stratagem's pointer is set. */
static int SettingsLoaded(uintptr_t list)
{
    uint64_t probe = 0;
    return list != 0 && ListRead(list, PROBE * 8, &probe, sizeof probe) && vpm_plausible((uintptr_t)probe);
}

/* One pool stratagem's settings: its own type, a code the arcade can show, a HUD colour. 1, or 0 after vpm_fail. */
static int CheckStratagem(VpmComponent* self, uint32_t type)
{
    uint8_t row[INFO_SIZE];
    uintptr_t info = type > 0 && type < TYPES ? (uintptr_t)g_list[type] : 0;
    if (!vpm_plausible(info)) { vpm_fail(self, "No settings for stratagem %u", type); return 0; }
    if (!vpm_read(info, row, sizeof row)) { vpm_fail(self, "Settings of stratagem %u unreadable", type); return 0; }
    if (U32(row + INFO_TYPE) != type) { vpm_fail(self, "The settings of stratagem %u belong to another stratagem", type); return 0; }
    uint32_t length = U32(row + INFO_CODE_LENGTH);
    if (length < 1 || length > MAX_CODE || !vpm_plausible((uintptr_t)U64(row + INFO_CODE)))
    {
        vpm_fail(self, "The code of stratagem %u does not fit the arcade", type);
        return 0;
    }
    if (U32(row + INFO_HUD) > MAX_HUD) { vpm_fail(self, "Unexpected HUD type for stratagem %u", type); return 0; }
    return 1;
}

/* Every stratagem of the pool (and only those: rows outside it are not read). 1, or 0 after vpm_fail. */
static int CheckPool(VpmComponent* self)
{
    for (int g = 0; g < POOL_GROUPS; g++)
        for (int i = 0; i < GROUP_SLOTS && kPool[g][i] != 0; i++)
            if (!CheckStratagem(self, kPool[g][i])) return 0;
    return 1;
}

/* ---- the pages and the write ------------------------------------------------------------------------------------ */

static SIZE_T Query(uintptr_t address, MEMORY_BASIC_INFORMATION* region)
{
    if (stratagem_hero_expanded_native != NULL) return stratagem_hero_expanded_native->query(address, region);
    return VirtualQuery((const void*)address, region, sizeof *region); /* lint-ok: C4 once per session, on the frame that writes */
}

static int Store(uintptr_t address, const void* data, size_t size)
{
    if (stratagem_hero_expanded_native != NULL) return stratagem_hero_expanded_native->store(address, data, size);
    memcpy((void*)address, data, size);
    return 1;
}

static int WritableProtection(DWORD protection)
{
    return protection == PAGE_READWRITE || protection == PAGE_WRITECOPY || protection == PAGE_EXECUTE_READWRITE ||
        protection == PAGE_EXECUTE_WRITECOPY;
}

int stratagem_hero_expanded_image_writable(uintptr_t module, uintptr_t address, size_t size, char* seen, size_t seen_size)
{
    uintptr_t cursor = address, finish = address + size;
    seen[0] = 0;
    while (cursor < finish)
    {
        MEMORY_BASIC_INFORMATION region;
        if (Query(cursor, &region) != sizeof region) return 0;
        uintptr_t end = (uintptr_t)region.BaseAddress + region.RegionSize;
        if (region.State != MEM_COMMIT || region.Type != MEM_IMAGE || (uintptr_t)region.AllocationBase != module ||
            !WritableProtection(region.Protect) || end <= cursor)
            return 0;
        size_t used = strlen(seen);
        if (used + 1 < seen_size) snprintf(seen + used, seen_size - used, "%s0x%02lX", used ? ", " : "", (unsigned long)region.Protect);
        cursor = end;
    }
    return 1;
}

/* Both tables' pages checked, both stores, the read back: 1 with the pages seen, or 0 after vpm_fail. */
static int WriteTables(VpmComponent* self, char* pages, size_t size)
{
    uintptr_t game = vpm_game(), tiers = game + TIERS_RVA, groups = game + GROUPS_RVA;
    char seen[2][64];
    int tiersOk = stratagem_hero_expanded_image_writable(game, tiers, sizeof s.expanded.tiers, seen[0], sizeof seen[0]);
    int groupsOk = stratagem_hero_expanded_image_writable(game, groups, sizeof s.expanded.groups, seen[1], sizeof seen[1]);
    if (!tiersOk || !groupsOk) { vpm_fail(self, "Arcade tables are not in writable game.dll data pages"); return 0; }
    s.wrote = 1;
    if (!Store(tiers, s.expanded.tiers, sizeof s.expanded.tiers) || !Store(groups, s.expanded.groups, sizeof s.expanded.groups))
    {
        vpm_fail(self, "Arcade table write failed");
        return 0;
    }
    if (Holds() != HOLDS_EXPANDED) { vpm_fail(self, "Arcade table write did not hold"); return 0; }
    snprintf(pages, size, "%s, %s", seen[0], seen[1]);
    return 1;
}

/* ---- the attempt ------------------------------------------------------------------------------------------------ */

/* One attempt: ATTEMPT_DONE (applied, or already applied; s.status says which), ATTEMPT_WAIT while the stratagem
 * settings are not loaded (two plain loads), or ATTEMPT_FAILED after vpm_fail. Nothing is written unless every check
 * passed. */
static int Attempt(VpmComponent* self)
{
    uintptr_t list = CurrentList();
    if (!SettingsLoaded(list)) return ATTEMPT_WAIT;
    if (!ListRead(list, 0, g_list, sizeof g_list)) { vpm_fail(self, "Stratagem settings unreadable"); return ATTEMPT_FAILED; }
    if (list != vpm_game() + VANILLA_LIST)
        vpm_log(self, "the stratagem list was moved by HellForge (game.dll %+lld)", (long long)(intptr_t)(list - vpm_game()));
    if (!CheckPool(self)) return ATTEMPT_FAILED;
    Holding holds = Holds();
    if (holds == HOLDS_UNREADABLE) { vpm_fail(self, "Arcade tables unreadable"); return ATTEMPT_FAILED; }
    if (holds == HOLDS_EXPANDED)
    {
        snprintf(s.status, sizeof s.status, "already applied (%d stratagems in %d groups)", s.pool, POOL_GROUPS);
        return ATTEMPT_DONE;
    }
    if (holds != HOLDS_VANILLA) { vpm_fail(self, "The arcade's tables differ from build 25480438's"); return ATTEMPT_FAILED; }
    char pages[96];
    if (!WriteTables(self, pages, sizeof pages)) return ATTEMPT_FAILED;
    snprintf(s.status, sizeof s.status, "applied (%d stratagems in %d groups; pages %s)", s.pool, POOL_GROUPS, pages);
    return ATTEMPT_DONE;
}

static void Done(VpmComponent* self, const char* when)
{
    s.done = 1;
    vpm_set_status(self, s.status);
    vpm_log(self, "%s, %s.", s.status, when);
}

/* While the game has not loaded its stratagem settings: the attempt's probe, two plain loads per frame. lint: per-frame */
static void Wait(VpmComponent* self, float dt)
{
    int result = Attempt(self);
    if (result == ATTEMPT_FAILED) return;
    if (result == ATTEMPT_DONE)
    {
        vpm_tick_stop(self);
        char when[48];
        snprintf(when, sizeof when, "after %.1f s", s.waited);
        Done(self, when);
        return;
    }
    s.waited += dt;
    if (s.waited >= WAIT_SECONDS)
        vpm_fail(self, "gave up after %.0f s: waiting: the stratagem settings are not loaded yet", WAIT_SECONDS);
}

/* The reader's code, as vpm_when_code_ready checks it before the attempt. */
static const VpmCodePin kPins[] = {
    {LIST_SITE, "4C 8B B4 C1", "the stratagem list's reader", 0},
};

/* The reader's bytes read as shipped (at HF_EVENT_GAME_LOADED, or on the frame they first do): the attempt. */
static void CodeReady(VpmComponent* self, HfEvent event)
{
    if (s.done || vpm_ticking(self)) return;
    if (vpm_game() == 0) { vpm_fail(self, "game.dll not loaded"); return; }
    int result = Attempt(self);
    if (result == ATTEMPT_DONE) { Done(self, "at load"); return; }
    if (result == ATTEMPT_FAILED) return;
    vpm_set_status(self, "waiting: the stratagem settings are not loaded yet");
    vpm_log(self, "Waiting for the game: the stratagem settings are not loaded yet.");
    if (!vpm_tick_start(self, Wait)) vpm_fail(self, "the game thread could not be reached to wait for the stratagem settings");
}

/* Puts build 25480438's tables back where this session stored the expanded ones and they still hold them (the core
 * stopping the component). */
static void Stop(VpmComponent* self)
{
    if (!s.wrote || !vpm_game_read(TIERS_RVA, g_span, SPAN)) return;
    s.wrote = 0;
    uintptr_t game = vpm_game();
    if (memcmp(g_span, s.expanded.tiers, sizeof s.expanded.tiers) == 0 &&
        !Store(game + TIERS_RVA, s.vanilla.tiers, sizeof s.vanilla.tiers))
        vpm_log(self, "could not put the arcade's tier table back");
    if (memcmp(g_span + AT_GROUPS, s.expanded.groups, sizeof s.expanded.groups) == 0 &&
        !Store(game + GROUPS_RVA, s.vanilla.groups, sizeof s.vanilla.groups))
        vpm_log(self, "could not put the arcade's group table back");
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    EncodeAll();
    return vpm_when_code_ready(self, kPins, 1, CodeReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_stratagem_hero_expanded = {"stratagem_hero_expanded", "Stratagem Hero Expanded", "1.0", 0, Start, Stop};
