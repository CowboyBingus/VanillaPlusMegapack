/* Mod Bindings Menu's native tabs on the binding pages (the Lua's mods_title, claim_label, write_action_label,
 * release_labels, sections, mods_layout, ensure_mods_tab, rows_built, tab_layout, fill_tab and page_frame).
 *
 * MODS is the fourth native tab: the game draws it, its index and Q/E (LB/RB) cycling itself. The game's tab switch
 * leaves the previous tab's rows for tabs it does not know, so a mod tab rebuilds the list with the game's own builder
 * (0x1812940): one native section header per category, then its bindings' rows. Texts the game cannot know (section
 * names, row labels) borrow localization ids whose formatted-text cache slot the game only fills for argument-free
 * lookups (LABEL_POOL), only while a binding page is displayed; the action label table then names the borrowed id. While
 * extended bindings exist outside a mission (and the engine Gui is reachable) a fifth tab, MORE MODS, follows. */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "mbm.h"

#define MBM_POOL 59
#define MBM_POOL_FIRST 0x3327550u
#define MBM_POOL_END 0x3328490u
#define MBM_HEADER_GROUP 13u
#define MBM_ROW_KIND 24752u
#define MBM_ROW_LABEL (4264u + 272u)
#define MBM_ROW_CODE 24760u
#define MBM_ROWS_RECHECK 0.5f
#define MBM_MAX_ROWS (2 * MBM_MAX_RECORDS + 2)
#define MBM_LABELS_FIRST (MBM_ACTION_LABELS_RVA + 4u * MBM_GROUP_ACTIONS * 9u)
#define MBM_LABELS_SIZE (4u * (MBM_GROUP_ACTIONS * 3u + 18u))

/* Every id here is in all 15 of the game's language string sets (build 25480438): {localization id, cache slot RVA}. */
static const uint32_t kMbmLabelPool[MBM_POOL][2] = {
    {0x76AD93E3u, 0x3327550u},
    {0xA9CF13BBu, 0x3328230u}, {0x431DA596u, 0x3328238u}, {0xC80D6BD6u, 0x3328248u},
    {0x9845CD37u, 0x3328250u}, {0x9F020AF7u, 0x3328260u}, {0x766F7A90u, 0x3328268u},
    {0x3707C006u, 0x3328270u}, {0x57063E09u, 0x3328278u}, {0x039CDC47u, 0x3328280u},
    {0x8F515FD7u, 0x3328288u}, {0x9CD0B591u, 0x3328290u}, {0xC58BDFA4u, 0x3328298u},
    {0xC977F7ACu, 0x33282A0u}, {0xFA69C153u, 0x33282A8u}, {0xED823922u, 0x33282B0u},
    {0x8CC549FBu, 0x33282B8u}, {0x780B23DEu, 0x33282C0u}, {0x8296F00Fu, 0x33282C8u},
    {0x970548B1u, 0x33282D0u}, {0x019BB39Bu, 0x33282E0u}, {0xBFD44F9Fu, 0x33282E8u},
    {0x110EBFCAu, 0x33282F0u}, {0x1A8AE3C1u, 0x3328300u}, {0x34FC79A3u, 0x3328310u},
    {0xFC0DB519u, 0x3328318u}, {0x1AEF663Au, 0x3328320u}, {0x568A85ADu, 0x3328328u},
    {0xA1D192A5u, 0x3328340u}, {0xD4BB26A2u, 0x3328368u}, {0x1A416656u, 0x3328370u},
    {0x0B2F407Bu, 0x3328390u}, {0xDE392204u, 0x3328398u}, {0xB753331Cu, 0x33283B8u},
    {0xB4A59CEBu, 0x33283C0u}, {0xFD66D0D5u, 0x33283C8u}, {0x9F3CB7C9u, 0x33283D0u},
    {0x09976730u, 0x33283D8u}, {0x72B848BCu, 0x33283E0u}, {0x6E083332u, 0x33283E8u},
    {0xBB4D13E4u, 0x33283F0u}, {0x8C084330u, 0x33283F8u}, {0x480CCB51u, 0x3328400u},
    {0xE39EC311u, 0x3328408u}, {0xF4BFA80Du, 0x3328410u}, {0xCFFC99DDu, 0x3328418u},
    {0xCCD4045Fu, 0x3328428u}, {0x11F38DC4u, 0x3328430u}, {0xD8250934u, 0x3328438u},
    {0x43213F6Du, 0x3328440u}, {0x2EC24CB3u, 0x3328448u}, {0xF40BD215u, 0x3328450u},
    {0xAFBA9B8Bu, 0x3328458u}, {0x0944CE13u, 0x3328460u}, {0xDDC61CBFu, 0x3328468u},
    {0x61D0E824u, 0x3328470u}, {0xA95FD6A0u, 0x3328478u}, {0x7505BCBFu, 0x3328480u},
    {0x4777D7C3u, 0x3328488u},
};

typedef void (*MbmBuildRows)(void* listing, const uint32_t* rows);
typedef void (*MbmSetTabLabels)(void* bar, const uint32_t* labels, int count);
typedef void (*MbmResetList)(void* listing, int tab);
typedef void (*MbmConsumeAction)(void* input, uint64_t action, float seconds);

typedef struct MbmLayout { uint32_t rows[MBM_MAX_ROWS][3]; int count; uint32_t generation; } MbmLayout;
typedef struct MbmSection { const char* name; MbmRecord* records[MBM_MAX_RECORDS]; int count; } MbmSection;

static struct
{
    MbmBuildRows build_rows;
    MbmSetTabLabels set_tab_labels;
    MbmResetList reset_list;
    MbmConsumeAction consume;
    int claimed[MBM_POOL];
    uint32_t action_labels[MBM_ACTIONS]; /* the label each row shows while borrowed */
    uint8_t labeled[MBM_ACTIONS];
    uint32_t tab_labels[5];              /* the tab bar's labels (static: the game may keep the pointer) */
    MbmLayout mods, more;
    int mods_valid, more_valid;
    uint32_t mods_revision, generation;
    uintptr_t built_listing;
    uint32_t built_generation;
    float built_age;
    uintptr_t checked_screen;
    int screen_writable, title_logged, tab_known;
    uint32_t last_tab;
    uint32_t row_request[MBM_MAX_ROWS * 3];
    MbmSection sections[MBM_MAX_RECORDS];
} s_tab;

/* The texts the borrowed slots point at (static: the game reads them while a page shows them, and after a stop). */
static char g_mbmClaimText[MBM_POOL][MBM_TEXT_SIZE];
static char g_mbmModsText[16] = "MODS";

void mbm_tab_reset(void)
{
    memset(&s_tab, 0, sizeof s_tab);
    memset(g_mbmClaimText, 0, sizeof g_mbmClaimText);
}

static void MbmPagesNote(VpmComponent* self, int writable, uint32_t first, uint32_t end, const char* what)
{
    if (!writable) vpm_log(self, "Writes at game.dll+0x%X .. +0x%X skipped: %s not writable.", first, end, what);
}

int mbm_image_data_writable(uintptr_t address, size_t size)
{
    uintptr_t at = address, end = address + size;
    if (address == 0 || size == 0 || end < address) return 0;
    while (at < end)
    {
        MEMORY_BASIC_INFORMATION info;
        if (VirtualQuery((const void*)at, &info, sizeof info) != sizeof info) return 0; /* lint-ok: C4 once per session, when native input is ready */
        DWORD page = info.Protect & 0xFFu;
        int writable = page == PAGE_READWRITE || page == PAGE_WRITECOPY || page == PAGE_EXECUTE_READWRITE ||
            page == PAGE_EXECUTE_WRITECOPY;
        if (info.State != MEM_COMMIT || !writable || (info.Protect & PAGE_GUARD) != 0) return 0;
        uintptr_t regionEnd = (uintptr_t)info.BaseAddress + info.RegionSize;
        if (regionEnd <= at) return 0;
        at = regionEnd;
    }
    return 1;
}

/* Once native input is ready: the game's list functions, and the pages of every game.dll address this component writes
 * (the Lua checked each write; one check per region here). Both regions are in game.dll's read-write data section, an
 * image's pages (copy-on-write until first written): the Lua's own rule (write_memory: committed, read-write or
 * write-copy, no guard), not vpm_writable's, which takes only private memory. */
void mbm_set_functions(uintptr_t base)
{
    s_tab.build_rows = (MbmBuildRows)(base + MBM_BUILD_ROWS_RVA);
    s_tab.set_tab_labels = (MbmSetTabLabels)(base + MBM_SET_TAB_LABELS_RVA);
    s_tab.reset_list = (MbmResetList)(base + MBM_LIST_RESET_RVA);
    s_tab.consume = (MbmConsumeAction)(base + MBM_INPUT_CONSUME_RVA);
    mbm.labels_writable = mbm_image_data_writable(base + MBM_LABELS_FIRST, MBM_LABELS_SIZE);
    mbm.slots_writable = mbm_image_data_writable(base + MBM_POOL_FIRST, MBM_POOL_END - MBM_POOL_FIRST);
    MbmPagesNote(mbm.self, mbm.labels_writable, MBM_LABELS_FIRST, MBM_LABELS_FIRST + MBM_LABELS_SIZE, "the action label table is");
    MbmPagesNote(mbm.self, mbm.slots_writable, MBM_POOL_FIRST, MBM_POOL_END, "the text slots are");
}

/* The game's consume routine: the action consumed until released, as the game's buttons do. */
void mbm_consume(uintptr_t owner, uint32_t action)
{
    if (s_tab.consume != NULL) s_tab.consume((void*)owner, (uint64_t)action << 32, -1.0f);
}

static uint64_t* MbmSlot(uint32_t rva) { return (uint64_t*)(mbm.base + rva); }

/* The MODS title: a game slot pointing at "MODS" while a page shows the tab. */
void mbm_mods_title(int active)
{
    if (mbm.base == 0 || active == mbm.title_active) return;
    uint64_t current = vpm_game_u64(MBM_MODS_TITLE_RVA);
    uint64_t ours = (uint64_t)(uintptr_t)g_mbmModsText;
    if (active)
    {
        if (current != 0)
        {
            if (!s_tab.title_logged) vpm_log(mbm.self, "MODS title slot is already in use; leaving localization unchanged.");
            s_tab.title_logged = 1;
            return;
        }
        if (!mbm.slots_writable) return;
        *MbmSlot(MBM_MODS_TITLE_RVA) = ours;
        mbm.title_active = 1;
        return;
    }
    /* A slot that cannot be cleared stays tracked and is retried; the buffer lives as long as the DLL. */
    if (current == ours && !mbm.slots_writable) return;
    if (current == ours) *MbmSlot(MBM_MODS_TITLE_RVA) = 0;
    mbm.title_active = 0;
}

/* A localization id that displays text, borrowing an empty pooled slot; 0 when none is free or writable. */
uint32_t mbm_claim_label(const char* text)
{
    for (int i = 0; i < MBM_POOL; i++)
        if (s_tab.claimed[i] && strcmp(g_mbmClaimText[i], text) == 0) return kMbmLabelPool[i][0];
    for (int i = 0; i < MBM_POOL; i++)
    {
        if (s_tab.claimed[i] || vpm_game_u64(kMbmLabelPool[i][1]) != 0) continue;
        if (!mbm.slots_writable) return 0;
        snprintf(g_mbmClaimText[i], MBM_TEXT_SIZE, "%s", text);
        *MbmSlot(kMbmLabelPool[i][1]) = (uint64_t)(uintptr_t)g_mbmClaimText[i];
        s_tab.claimed[i] = 1;
        return kMbmLabelPool[i][0];
    }
    vpm_log(mbm.self, "No free localization slot for \"%s\".", text);
    return 0;
}

static uint32_t MbmLabelRva(const MbmRecord* r) { return MBM_ACTION_LABELS_RVA + (r->group * MBM_GROUP_ACTIONS + r->action) * 4u; }

/* Whether the row now shows label; else it keeps its own label. */
static int MbmWriteActionLabel(MbmRecord* r, uint32_t label)
{
    int index = mbm_code_index(r->code);
    uint32_t previous = vpm_game_u32(MbmLabelRva(r));
    if (previous != mbm_dormant[index].label && previous != label && !(s_tab.labeled[index] && previous == s_tab.action_labels[index]))
    {
        vpm_log(mbm.self, "Action label for %s is in use by another mod; leaving it.", r->id);
        return 0;
    }
    if (previous != label && !mbm.labels_writable) return 0;
    if (previous != label) *(uint32_t*)(mbm.base + MbmLabelRva(r)) = label;
    s_tab.action_labels[index] = label;
    s_tab.labeled[index] = 1;
    return 1;
}

static int MbmReleaseRows(void)
{
    int left = 0;
    for (int i = 0; i < mbm.order_count; i++)
    {
        MbmRecord* r = mbm.order[i];
        int index = mbm_code_index(r->code);
        if (!s_tab.labeled[index]) continue;
        int ours = vpm_game_u32(MbmLabelRva(r)) == s_tab.action_labels[index];
        if (!ours || !mbm.labels_writable) { left = 1; continue; }
        *(uint32_t*)(mbm.base + MbmLabelRva(r)) = mbm_dormant[index].label;
        s_tab.labeled[index] = 0;
    }
    return left;
}

static int MbmReleaseSlots(void)
{
    int left = 0;
    for (int i = 0; i < MBM_POOL; i++)
    {
        if (!s_tab.claimed[i]) continue;
        int ours = vpm_game_u64(kMbmLabelPool[i][1]) == (uint64_t)(uintptr_t)g_mbmClaimText[i];
        if (ours && !mbm.slots_writable) { left = 1; continue; }
        if (ours) *MbmSlot(kMbmLabelPool[i][1]) = 0;
        s_tab.claimed[i] = 0;
    }
    return left;
}

/* Gives back every borrowed row label and text slot; returns whether something is still borrowed (a later call reads
 * and writes again). A slot that still points at our text but cannot be cleared keeps its claim: freeing it would
 * leave the game a pointer to text reused for something else. */
int mbm_release_labels(void)
{
    if (mbm.base == 0) return 0;
    int rows = MbmReleaseRows();
    return MbmReleaseSlots() || rows;
}

/* ---- layouts --------------------------------------------------------------------------------------------------- */

/* Sections in display order: categories by name (bytes), bindings by slot. Returns how many. */
static int MbmSections(void)
{
    int count = 0;
    for (int i = 0; i < mbm.order_count; i++)
    {
        MbmRecord* r = mbm.order[i];
        int at = 0;
        while (at < count && strcmp(s_tab.sections[at].name, r->category) != 0) at++;
        if (at == count) s_tab.sections[count++] = (MbmSection){r->category, {0}, 0};
        s_tab.sections[at].records[s_tab.sections[at].count++] = r;
    }
    for (int i = 1; i < count; i++)
        for (int j = i; j > 0 && strcmp(s_tab.sections[j - 1].name, s_tab.sections[j].name) > 0; j--)
        {
            MbmSection swap = s_tab.sections[j];
            s_tab.sections[j] = s_tab.sections[j - 1];
            s_tab.sections[j - 1] = swap;
        }
    return count;
}

static void MbmAddRow(MbmLayout* layout, uint32_t group, uint32_t action, uint32_t header)
{
    if (layout->count >= MBM_MAX_ROWS) return;
    uint32_t* row = layout->rows[layout->count++];
    row[0] = group;
    row[1] = action;
    row[2] = header;
}

static void MbmAddSection(MbmLayout* layout, const MbmSection* section, uint32_t fallback, int* fallback_shown)
{
    uint32_t header = mbm_claim_label(section->name);
    if (header != 0) MbmAddRow(layout, MBM_HEADER_GROUP, 0, header);
    else if (fallback != 0 && !*fallback_shown)
    {
        *fallback_shown = 1; /* sections without their own header share one MODS header */
        MbmAddRow(layout, MBM_HEADER_GROUP, 0, fallback);
    }
    for (int i = 0; i < section->count; i++)
    {
        MbmRecord* r = section->records[i];
        if (mbm_map_bucket(MBM_BINDING_MAP, r->code) == 0)
        {
            vpm_log(mbm.self, "Native action for %s is not loaded; row omitted.", r->id);
            continue;
        }
        uint32_t label = mbm_claim_label(r->text);
        if (label != 0) (void)MbmWriteActionLabel(r, label); /* refused: the row keeps its native label */
        MbmAddRow(layout, r->group, r->action, 0);
    }
}

/* The MODS tab's rows. Always rows when possible: without them the game would keep the previous tab's rows. A header
 * that cannot be written falls back to the MODS title (or none); every binding stays visible and rebindable. */
static int MbmModsLayout(MbmLayout* layout)
{
    layout->count = 0;
    uint32_t fallback = mbm.title_active ? MBM_MODS_TITLE_ID : 0;
    int sections = MbmSections(), fallback_shown = 0;
    if (sections == 0)
    {
        uint32_t empty = mbm_claim_label(mbm.empty_text);
        if (empty == 0) empty = fallback;
        if (empty != 0) MbmAddRow(layout, MBM_HEADER_GROUP, 0, empty);
        return layout->count > 0;
    }
    for (int i = 0; i < sections; i++) MbmAddSection(layout, &s_tab.sections[i], fallback, &fallback_shown);
    return layout->count > 0;
}

static const MbmLayout* MbmTabLayout(uint32_t tab)
{
    if (tab == MBM_MODS_TAB)
    {
        if (!s_tab.mods_valid || s_tab.mods_revision != mbm.revision)
        {
            s_tab.mods_valid = MbmModsLayout(&s_tab.mods);
            s_tab.mods.generation = ++s_tab.generation;
            s_tab.mods_revision = mbm.revision;
        }
        return s_tab.mods_valid ? &s_tab.mods : NULL;
    }
    if (!s_tab.more_valid)
    {
        uint32_t header = mbm_claim_label(mbm.more_header_text);
        if (header == 0 && mbm.title_active) header = MBM_MODS_TITLE_ID;
        s_tab.more.count = 0;
        if (header != 0) MbmAddRow(&s_tab.more, MBM_HEADER_GROUP, 0, header);
        s_tab.more.generation = ++s_tab.generation;
        s_tab.more_valid = header != 0;
    }
    return s_tab.more_valid ? &s_tab.more : NULL;
}

/* ---- the tab bar and the rows ---------------------------------------------------------------------------------- */

static uint32_t MbmWantedTabs(void)
{
    int more = mbm.extended_count > 0 && !mbm.in_mission && mbm_panel_available();
    return more ? MBM_MORE_TAB + 1 : MBM_MODS_TAB + 1;
}

static int MbmOwnTabCount(uint32_t count)
{
    return count == MBM_NATIVE_TABS || count == MBM_MODS_TAB + 1 || (count == MBM_MORE_TAB + 1 && mbm.extended_count > 0);
}

/* The screen object's fields this component stores into, checked writable once per screen object. */
static int MbmScreenWritable(uintptr_t screen)
{
    if (screen == s_tab.checked_screen) return s_tab.screen_writable;
    s_tab.checked_screen = screen;
    s_tab.screen_writable = vpm_writable(screen + MBM_TAB_BAR, MBM_ROW_LIST + MBM_ROW_REQUEST + 4u - MBM_TAB_BAR);
    if (!s_tab.screen_writable) vpm_log(mbm.self, "The binding page is not writable; its tabs are left as they are.");
    return s_tab.screen_writable;
}

static void MbmRelabel(uintptr_t bar, uint32_t count, uint32_t wanted, uint32_t current)
{
    for (uint32_t i = 0; i < MBM_NATIVE_TABS; i++) s_tab.tab_labels[i] = vpm_game_u32(MBM_TAB_LABELS_RVA + i * 4u);
    s_tab.tab_labels[MBM_MODS_TAB] = MBM_MODS_TITLE_ID;
    if (wanted > MBM_MORE_TAB)
    {
        uint32_t more = mbm_claim_label(mbm.more_text);
        s_tab.tab_labels[MBM_MORE_TAB] = more != 0 ? more : MBM_MODS_TITLE_ID;
    }
    s_tab.set_tab_labels((void*)bar, s_tab.tab_labels, (int)wanted);
    /* Relabelling resets every button's state: the current tab's selected state goes back, as the page's opener does. */
    uintptr_t button = bar + MBM_TAB_BUTTON_STRIDE * current;
    *(uint32_t*)(button + MBM_TAB_BUTTON_STATE) = 3;
    *(uint8_t*)(button + MBM_TAB_BUTTON_ACTIVE) = 1;
    const char* change = count > wanted ? "Removed MORE MODS tab"
        : wanted > MBM_MORE_TAB ? "Added native MODS tab and MORE MODS tab" : "Added native MODS tab";
    vpm_log(mbm.self, "%s (current tab %u).", change, current);
}

/* Adds MODS (and MORE MODS while wanted) to the native tab bar. 1 when the bar shows the tabs it should. */
static int MbmEnsureModsTab(uintptr_t screen)
{
    uintptr_t bar = screen + MBM_TAB_BAR;
    uint32_t count = 0, current = 0, wanted = MbmWantedTabs();
    if (!vpm_read_u32(bar + MBM_TAB_COUNT, &count)) return 0;
    if (count == wanted) return 1;
    if (!MbmOwnTabCount(count)) return 0;
    if (!vpm_read_u32(bar + MBM_TAB_CURRENT, &current) || current >= count) return 0;
    if (current >= wanted) return 1;
    mbm_mods_title(1);
    if (!mbm.title_active || !MbmScreenWritable(screen)) return 0;
    MbmRelabel(bar, count, wanted, current);
    return 1;
}

static int MbmRowsMatch(uintptr_t listing, const MbmLayout* layout)
{
    uint32_t count = 0;
    if (!vpm_read_u32(listing + MBM_ROW_COUNT, &count) || count != (uint32_t)layout->count) return 0;
    for (int i = 0; i < layout->count; i++)
    {
        uintptr_t row = listing + MBM_ROW_START + MBM_ROW_STRIDE * (uintptr_t)i;
        const uint32_t* d = layout->rows[i];
        uint32_t kind = 0, value = 0;
        if (d[2] != 0)
        {
            if (!vpm_read_u32(row + MBM_ROW_KIND, &kind) || kind != 4 || !vpm_read_u32(row + MBM_ROW_LABEL, &value) || value != d[2])
                return 0;
        }
        else if (!vpm_read_u32(row + MBM_ROW_CODE, &value) || value != d[0] * 65536u + d[1]) return 0;
    }
    return 1;
}

static void MbmForgetRows(void)
{
    s_tab.built_listing = 0;
    s_tab.built_generation = 0;
}

/* While a tab stays selected the game leaves the rows alone: a frame reads the row count only, every row again when the
 * count, the layout or the listing changed, after another tab, and every 0.5 s. lint: per-frame */
static int MbmRowsBuilt(uintptr_t listing, const MbmLayout* layout, float seconds)
{
    s_tab.built_age += seconds;
    uint32_t count = 0;
    if (listing == s_tab.built_listing && layout->generation == s_tab.built_generation && s_tab.built_age < MBM_ROWS_RECHECK &&
        vpm_read_u32(listing + MBM_ROW_COUNT, &count) && count == (uint32_t)layout->count)
        return 1;
    MbmForgetRows();
    if (!MbmRowsMatch(listing, layout)) return 0;
    s_tab.built_listing = listing;
    s_tab.built_generation = layout->generation;
    s_tab.built_age = 0;
    return 1;
}

/* Rebuilds a mod tab's rows with the game's builder, then resets focus and scrolling as a tab switch does. Returns the
 * listing once its rows are built (not on the frame it builds them, before the game laid them out), else 0. */
static uintptr_t MbmFillTab(uintptr_t screen, uint32_t tab, float seconds)
{
    const MbmLayout* layout = MbmTabLayout(tab);
    if (layout == NULL) return 0;
    uintptr_t listing = screen + MBM_ROW_LIST;
    if (MbmRowsBuilt(listing, layout, seconds)) return listing;
    if (!MbmScreenWritable(screen)) return 0;
    for (int i = 0; i < layout->count; i++) memcpy(s_tab.row_request + 3 * i, layout->rows[i], 12);
    *(uint32_t*)(listing + MBM_ROW_REQUEST) = (uint32_t)layout->count;
    s_tab.build_rows((void*)listing, s_tab.row_request);
    s_tab.reset_list((void*)listing, (int)MBM_MODS_TAB);
    if (tab == MBM_MODS_TAB) vpm_log(mbm.self, "Filled MODS tab: %d bindings in %d sections.", mbm.order_count, MbmSections());
    else vpm_log(mbm.self, "Filled MORE MODS tab: %d extended bindings.", mbm.extended_count);
    return 0;
}

static void MbmMissionCheck(void)
{
    if (--mbm.mission_check > 0) return;
    mbm.mission_check = 60;
    int mission = mbm_in_mission();
    if (mission == mbm.in_mission) return;
    mbm.in_mission = mission;
    if (mbm_panel_available())
        vpm_log(mbm.self, "%s", mission ? "In a mission: MORE MODS not offered." : "Outside missions: MORE MODS offered.");
}

/* A frame with a binding page on top of the UI: the MODS tab, and MORE MODS with its panel. lint: per-frame */
void mbm_page_frame(uintptr_t screen, float seconds)
{
    mbm.release_pending = 1;
    MbmMissionCheck();
    uint32_t tab = 0;
    int known = vpm_read_u32(screen + MBM_SELECTED_TAB, &tab);
    int more = known && tab == MBM_MORE_TAB && mbm.extended_count > 0 && !mbm.in_mission && mbm_panel_available();
    uintptr_t listing = 0;
    if (MbmEnsureModsTab(screen) && known && (tab == MBM_MODS_TAB || more)) listing = MbmFillTab(screen, tab, seconds);
    else MbmForgetRows();
    if (more && listing != 0) mbm_panel_frame(listing, seconds);
    else mbm_panel_hide("tab changed");
    if (known == s_tab.tab_known && (!known || tab == s_tab.last_tab)) return;
    s_tab.tab_known = known;
    s_tab.last_tab = tab;
    if (known) vpm_log(mbm.self, "Bindings tab %u selected.", tab);
    else vpm_log(mbm.self, "Bindings tab nil selected.");
}

/* A frame without a binding page: the page's own state goes (the borrowed labels separately). lint: per-frame */
void mbm_tab_away(void)
{
    s_tab.tab_known = 0;
    s_tab.last_tab = 0;
    s_tab.mods_valid = s_tab.more_valid = 0;
    s_tab.title_logged = 0;
    MbmForgetRows();
    mbm_panel_hide("page closed");
    mbm_mods_title(0);
}
