/* Armory Preview Cache: the state view (image_native.lua M.state, v23.1), build 25480438.
 *
 * Each refresh reads what the image snapshot and the asset policy consume into reused buffers and copies the words they
 * use into a signature with one fixed region per component. A component whose words differ from the previous refresh
 * gets a new version: the image tick runs in full only when the image version moved (apc_images.c), the asset step
 * reuses its last snapshot while the policy and lease versions stand (armory_preview_cache.c). Nothing is allocated.
 *
 * Reads per refresh (the globals block and the dispatch pointer are plain loads in game.dll's image; the Lua read them
 * with ReadProcessMemory): outside a thumbnail screen 2 (state stack, UI block); on one, the dispatch rows, the manager,
 * the atlas descriptor, the preview queue header (+1-2 while previews are queued) and the screen block (grid: the
 * pre-select block and the grid block; pre-select: its block + 3 widget record pointers; briefing: 1 + 6, + the grid
 * block when no loadout is shown). The Lua made 2 more on each (the globals block and the dispatch pointer). */
#include "apc.h"

#define REGION_UI 0
#define REGION_CONTROLLER 1
#define REGION_MANAGER 2
#define REGION_DESCRIPTOR 3
#define REGION_QUEUE 4
#define REGION_SCREEN 5
#define REGION_POLICY 6
#define WORDS 7760u

static const uint32_t kRegion[7] = {0, 32, 48, 1648, 1680, 4624, 7632};
/* Item words the snapshot and the policy read: request identity (+24..+40, +48..+56, +64..+72, +88..+104), crop rectangle
 * (+56..+72) and kind (+100); status (+104) goes to POLICY. The generator rewrites the camera fields +8 and +84. */
static const uint32_t kItemWords[14] = {6, 7, 8, 9, 12, 13, 14, 15, 16, 17, 22, 23, 24, 25};
/* Record words: visual (+0), type (+8), card/slot (+60), invalidation (+68) and style (+72). */
static const uint32_t kRecordWords[7] = {0, 1, 2, 15, 16, 17, 18};
static const uint32_t kBriefingKinds[6] = {2, 3, 4, 0, 0, 1};

static ApcState g_st;
static uint32_t g_words[2][WORDS];
static int32_t g_lengths[2][7];
static int g_current;
static uint32_t g_leaseWords[12], g_leasePrevious[12];

#define CUR (g_words[g_current])
#define LEN (g_lengths[g_current])

ApcState* apc_state(void) { return &g_st; }

void apc_state_reset(void)
{
    memset(&g_st, 0, sizeof g_st);
    memset(g_words, 0, sizeof g_words);
    memset(g_leaseWords, 0, sizeof g_leaseWords);
    memset(g_leasePrevious, 0, sizeof g_leasePrevious);
    for (int k = 0; k < 7; k++) g_lengths[0][k] = g_lengths[1][k] = -1; /* the first refresh reports every component */
    g_current = 0;
}

static uint32_t Words(const uint32_t* source, uint32_t first, uint32_t count, uint32_t w)
{
    for (uint32_t i = 0; i < count; i++) CUR[w + i] = source[first + i];
    return w + count;
}

static uint32_t Records(const uint32_t* source, uint32_t first, uint32_t count, uint32_t w)
{
    for (uint32_t r = 0; r < count; r++)
        for (int j = 0; j < 7; j++) CUR[w++] = source[first + r * 20 + kRecordWords[j]];
    return w;
}

static uint32_t Flag(uint32_t w, int ok)
{
    CUR[w] = ok ? 1u : 2u;
    return w + 1;
}

/* The globals block: the thumbnail manager, UI, state machine, preview queue and lease table pointers. */
static void ReadGlobals(uint32_t* w, uint32_t* p)
{
    int ok = g_st.probed || vpm_game_read(APC_RVA_GLOBALS, g_st.G, sizeof g_st.G);
    g_st.g_ok = ok;
    *w = Flag(*w, ok);
    g_st.tm = g_st.ui = g_st.sm = g_st.preview = g_st.lease = 0;
    if (!ok) return;
    *w = Words(g_st.G, 0, 2, *w);
    *w = Words(g_st.G, 4, 2, *w);
    *w = Words(g_st.G, 42, 2, *w);
    *w = Words(g_st.G, 56, 2, *w);
    *p = Words(g_st.G, 76, 2, *p);
    g_st.tm = ApcWordPointer(g_st.G, 0);
    g_st.ui = ApcWordPointer(g_st.G, 4);
    g_st.sm = ApcWordPointer(g_st.G, 42);
    g_st.preview = ApcWordPointer(g_st.G, 56);
    g_st.lease = ApcWordPointer(g_st.G, 76);
}

/* The state stack: depth and top. Returns the controller kind of a thumbnail screen (Armory 224, briefing 229), 0 none. */
static uint32_t ReadStack(uint32_t* w)
{
    g_st.stack_ok = 0;
    g_st.has_depth = 0;
    if (!g_st.sm) return 0;
    int ok = g_st.probed || apc_read(g_st.sm + 0x429C, g_st.STACK, 24);
    g_st.stack_ok = ok;
    *w = Flag(*w, ok);
    if (!ok) return 0;
    uint32_t depth = g_st.STACK[5];
    int hasTop = depth >= 1 && depth <= 5;
    uint32_t top = hasTop ? g_st.STACK[depth - 1] : 0;
    CUR[*w] = depth;
    CUR[*w + 1] = hasTop ? top : 0xFFFFFFFFu;
    *w += 2;
    g_st.has_depth = 1;
    g_st.depth = depth;
    if (hasTop && top == 5) return 224;
    return hasTop && top == 14 ? 229 : 0;
}

/* The UI block: the UI world, and the blocked flag for the policy. */
static uintptr_t ReadUi(uint32_t* w, uint32_t* p)
{
    g_st.ui_ok = 0;
    if (!g_st.ui) return 0;
    int ok = apc_read(g_st.ui + 15432, g_st.UIB, 464);
    g_st.ui_ok = ok;
    *w = Flag(*w, ok);
    if (!ok) return 0;
    *w = Words(g_st.UIB, 0, 2, *w);
    *p = Words(g_st.UIB, 115, 1, *p);
    return ApcWordPointer(g_st.UIB, 0);
}

static void ResetScreen(void)
{
    g_st.dptr_ok = g_st.rows_ok = g_st.mb_ok = g_st.desc_ok = g_st.qh_ok = g_st.qrows_ok = 0;
    g_st.small_ok = g_st.meta_ok = 0;
    g_st.jobs = 0;
    for (int i = 0; i < 6; i++) g_st.tails_ok[i] = 0;
}

/* The dispatch rows are a fixed 64-row array after their count: one read, or the count and the rows when the array cannot
 * be read whole. */
static int ReadRows(uintptr_t d)
{
    if (apc_read(d + 5740, g_st.DROWS, 4 + 64 * 16)) return 1;
    int ok = apc_read(d + 5740, g_st.DROWS, 4);
    uint32_t n = ok ? g_st.DROWS[0] : 0;
    if (ok && n > 0 && n <= 64) ok = apc_read(d + 5744, (uint8_t*)g_st.DROWS + 4, n * 16u);
    return ok;
}

/* The controller registered for kind (the last such row), whether several are, and how many briefing controllers are. */
static uintptr_t FindOwner(uint32_t kind, uint32_t n, uint32_t* ambiguous, uint32_t* briefing)
{
    uintptr_t found = 0;
    *ambiguous = *briefing = 0;
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t row = 1 + i * 4, k = g_st.DROWS[row + 2];
        uintptr_t pointer = ApcWordPointer(g_st.DROWS, row);
        if (k == kind)
        {
            if (found) *ambiguous = 1;
            found = pointer;
        }
        if (k == 229 && pointer) (*briefing)++;
    }
    return found;
}

static uint32_t RowWords(uintptr_t d, uint32_t kind, uint32_t w, uintptr_t* owner)
{
    int rok = ReadRows(d);
    g_st.rows_ok = rok;
    w = Flag(w, rok);
    if (!rok) return w;
    uint32_t n = g_st.DROWS[0];
    CUR[w++] = n;
    if (n > 64) return w;
    uint32_t ambiguous, briefing;
    uintptr_t found = FindOwner(kind, n, &ambiguous, &briefing);
    CUR[w] = (uint32_t)found;
    CUR[w + 1] = (uint32_t)((uint64_t)found >> 32);
    CUR[w + 2] = ambiguous;
    CUR[w + 3] = briefing;
    *owner = found;
    return w + 4;
}

/* CONTROLLER: the dispatch pointer and rows. Returns the screen's owner. */
static uintptr_t ReadController(uint32_t kind)
{
    uint32_t w = kRegion[REGION_CONTROLLER];
    int ok = vpm_game_read(APC_RVA_DISPATCH, g_st.DPTR, 8);
    g_st.dptr_ok = ok;
    w = Flag(w, ok);
    uintptr_t d = ok ? ApcWordPointer(g_st.DPTR, 0) : 0, owner = 0;
    if (ok) w = Words(g_st.DPTR, 0, 2, w);
    if (d) w = RowWords(d, kind, w, &owner);
    LEN[REGION_CONTROLLER] = (int32_t)(w - kRegion[REGION_CONTROLLER]);
    g_st.owner = owner;
    return owner;
}

/* One card's state and count and, while it is busy, per item the words the snapshot reads and its status (POLICY). */
static uint32_t CardWords(uint32_t c, uint32_t w, uint32_t* p)
{
    const uint32_t* m = g_st.MB;
    uint32_t at = c * 454, state = m[at + 458], n = m[at + 459];
    CUR[w] = state;
    CUR[w + 1] = n;
    w += 2;
    if (state == 0 || n > 15) return w;
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t item = at + 8 + i * 30;
        for (int j = 0; j < 14; j++) CUR[w++] = m[item + kItemWords[j]];
        CUR[(*p)++] = m[item + 26];
    }
    return w;
}

/* MANAGER: one read of the thumbnail manager. Returns the working atlas. */
static uintptr_t ReadManager(uint32_t* p)
{
    uint32_t w = kRegion[REGION_MANAGER];
    int ok = apc_read(g_st.tm, g_st.MB, APC_MANAGER_SIZE);
    g_st.mb_ok = ok;
    w = Flag(w, ok);
    uintptr_t atlas = 0;
    if (ok)
    {
        const uint32_t* m = g_st.MB;
        CUR[w++] = m[2763];                  /* +11052 */
        w = Words(m, 4, 4, w);               /* +16..+32: layout, tile size */
        for (uint32_t c = 0; c < 6; c++) w = CardWords(c, w, p);
        CUR[w] = m[2766];                    /* active +11064 */
        CUR[w + 1] = m[2774];                /* phase +11096 */
        w += 2;
        w = Words(m, 2775, 2, w);            /* +11100 layout */
        w = Words(m, 2778, 2, w);            /* atlas +11112 */
        uint32_t count = m[2784];            /* registry +11136 */
        CUR[w++] = count;
        if (count <= 128) w = Words(m, 2786, count * 2, w);
        atlas = ApcWordPointer(m, 2778);
    }
    LEN[REGION_MANAGER] = (int32_t)(w - kRegion[REGION_MANAGER]);
    g_st.atlas = atlas;
    return atlas;
}

static void ReadDescriptor(uintptr_t atlas)
{
    uint32_t w = kRegion[REGION_DESCRIPTOR];
    if (atlas)
    {
        int ok = apc_read(atlas, g_st.DESC, 104);
        g_st.desc_ok = ok;
        w = Flag(w, ok);
        if (ok) w = Words(g_st.DESC, 0, 26, w);
    }
    LEN[REGION_DESCRIPTOR] = (int32_t)(w - kRegion[REGION_DESCRIPTOR]);
}

/* The occupied preview rows, oldest first, in at most two reads. */
static int ReadJobs(uintptr_t preview, uint32_t head, uint32_t tail, uint32_t* jobs)
{
    *jobs = (tail - head) & 127u;
    uint32_t first = *jobs < 128 - head ? *jobs : 128 - head;
    int ok = *jobs == 0 || apc_read(preview + 50456 + head * 200u, g_st.QROWS, first * 200u);
    if (ok && *jobs > first) ok = apc_read(preview + 50456, (uint8_t*)g_st.QROWS + first * 200u, (*jobs - first) * 200u);
    return ok;
}

/* Per queued job: identity, slot count and slots. */
static uint32_t JobWords(uint32_t jobs, uint32_t w)
{
    for (uint32_t r = 0; r < jobs; r++)
    {
        uint32_t row = r * 50, n = g_st.QROWS[row + 20];   /* +80 slot count */
        w = Words(g_st.QROWS, row + 16, 2, w);             /* +64 identity */
        CUR[w++] = n;
        if (n > 10) break;
        w = Words(g_st.QROWS, row + 22, n * 2, w);         /* +88 slots */
    }
    return w;
}

static uint32_t QueueWords(uintptr_t preview, uint32_t w)
{
    int ok = apc_read(preview + 50448, g_st.QH, 8);
    g_st.qh_ok = ok;
    w = Flag(w, ok);
    if (!ok) return w;
    uint32_t head = g_st.QH[0], tail = g_st.QH[1];
    CUR[w] = head;
    CUR[w + 1] = tail;
    w += 2;
    if (head >= 128 || tail >= 128) return w;
    uint32_t jobs;
    int rok = ReadJobs(preview, head, tail, &jobs);
    g_st.qrows_ok = rok;
    w = Flag(w, rok);
    if (!rok) return w;
    g_st.jobs = jobs;
    return JobWords(jobs, w);
}

/* QUEUE: the preview queue header and its occupied rows. */
static void ReadQueue(void)
{
    uint32_t w = kRegion[REGION_QUEUE];
    if (g_st.preview) w = QueueWords(g_st.preview, w);
    LEN[REGION_QUEUE] = (int32_t)(w - kRegion[REGION_QUEUE]);
}

/* One widget's record pointer (the screen's tails). */
static uint32_t Tail(int i, uintptr_t address, uint32_t w)
{
    int ok = apc_read(address, &g_st.TAILS[i * 2], 8);
    g_st.tails_ok[i] = ok;
    CUR[w] = ok ? 1u : 2u;
    if (!ok) return w + 1;
    CUR[w + 1] = g_st.TAILS[i * 2];
    CUR[w + 2] = g_st.TAILS[i * 2 + 1];
    return w + 3;
}

/* A grid's rows, row heights and index table, scroll position, item count, grid kind, columns and anchor (+597772 ..
 * +602104), every record's identity, type, card/slot, invalidation and style, then row ranges, owned cards and the
 * visible window (+622584 .. +622664). Scrolling remaps widgets to other records without any manager change; these
 * fields move with it. */
static uint32_t Grid(uintptr_t address, uint32_t w)
{
    int ok = apc_read(address + 597772, g_st.META, 24892);
    g_st.meta_ok = ok;
    g_st.meta_address = address;
    w = Flag(w, ok);
    if (!ok) return w;
    w = Words(g_st.META, 0, 1083, w);
    w = Records(g_st.META, 1083, 256, w);
    return Words(g_st.META, 6203, 20, w);
}

/* A briefing loadout is shown when all six records hold their slot's request (the manager item exists, has the expected
 * kind) and each widget still points at its record: as in the snapshot. */
static int Loadout(uintptr_t owner)
{
    const uint32_t* m = g_st.MB;
    const uint32_t* r = g_st.SMALL;
    for (uint32_t index = 0; index < 6; index++)
    {
        uint32_t card = r[index * 20 + 15], slot = r[index * 20 + 16];
        if (card >= 6 || slot >= 15) return 0;
        uint32_t state = m[card * 454 + 458], n = m[card * 454 + 459];
        if (state == 0 || slot >= n) return 0;
        uint32_t kind = m[card * 454 + 8 + slot * 30 + 25];
        if (kind > 4 || r[index * 20 + 2] != 3 || kind != kBriefingKinds[index] || !g_st.tails_ok[index] ||
            ApcWordPointer(g_st.TAILS, index * 2) != owner + 454728 + index * 80)
            return 0;
    }
    return 1;
}

/* Briefing: the six loadout records and their widgets' record pointers; the picker grid when they do not form a loadout. */
static uint32_t BriefingWords(uintptr_t owner, uint32_t w)
{
    int ok = apc_read(owner + 454728, g_st.SMALL, 480);
    g_st.small_ok = ok;
    w = Flag(w, ok);
    if (ok)
    {
        w = Records(g_st.SMALL, 0, 6, w);
        for (int index = 0; index < 6; index++) w = Tail(index, owner + 422768 + (uintptr_t)index * 5464 + 1984, w);
    }
    if (ok && g_st.mb_ok && Loadout(owner)) return w;
    return Grid(owner + 864032, w);
}

/* Armory: the pre-select records and mode block (one read) and its three widgets' record pointers; the grid when no
 * pre-select is shown. */
static uint32_t ArmoryWords(uintptr_t owner, uint32_t w)
{
    uintptr_t control = owner + 280216;
    int ok = apc_read(control + 37728, g_st.SMALL, 256);
    g_st.small_ok = ok;
    w = Flag(w, ok);
    if (ok)
    {
        w = Words(g_st.SMALL, 60, 4, w);     /* the mode block (+37968) */
        w = Records(g_st.SMALL, 0, 3, w);
    }
    if (ok && ((const uint8_t*)g_st.SMALL)[244] == 0 && g_st.SMALL[60] < 6)
    {
        for (int index = 0; index < 3; index++) w = Tail(index, control + 5256 + (uintptr_t)index * 12304 + 1984, w);
        return w;
    }
    return Grid(owner + 523752, w);
}

/* SCREEN: the block of the screen shown. */
static void ReadScreen(uint32_t kind, uintptr_t owner, uintptr_t atlas)
{
    uint32_t w = kRegion[REGION_SCREEN];
    if (atlas && owner)
    {
        CUR[w++] = kind;
        w = kind == 229 ? BriefingWords(owner, w) : ArmoryWords(owner, w);
    }
    LEN[REGION_SCREEN] = (int32_t)(w - kRegion[REGION_SCREEN]);
}

static int ComponentChanged(int k)
{
    const uint32_t* previous = g_words[g_current ^ 1];
    int32_t length = LEN[k];
    if (length != g_lengths[g_current ^ 1][k]) return 1;
    uint32_t r = kRegion[k];
    for (uint32_t i = r; i < r + (uint32_t)length; i++)
        if (CUR[i] != previous[i]) return 1;
    return 0;
}

/* Versions: the image tick reads every component but POLICY; the asset policy reads neither the atlas descriptor nor the
 * screen block. */
static void CountVersions(void)
{
    int image = 0, policy = 0;
    for (int k = 0; k < 7; k++)
    {
        if (!ComponentChanged(k)) continue;
        if (k != REGION_POLICY) image = 1;
        if (k != REGION_DESCRIPTOR && k != REGION_SCREEN) policy = 1;
    }
    g_st.image_version += (uint64_t)image;
    g_st.policy_version += (uint64_t)policy;
}

/* lint: per-frame */
void apc_state_refresh(void)
{
    g_st.refreshes++;
    g_current ^= 1;
    for (int k = 0; k < 7; k++) LEN[k] = 0;
    uint32_t w = kRegion[REGION_UI], p = kRegion[REGION_POLICY];
    ReadGlobals(&w, &p);
    uint32_t kind = ReadStack(&w);
    g_st.probed = 0;
    uintptr_t world = ReadUi(&w, &p);
    LEN[REGION_UI] = (int32_t)(w - kRegion[REGION_UI]);
    g_st.kind = kind;
    g_st.world = world;
    ResetScreen();
    /* The rest only while a thumbnail screen can be shown, in the order the snapshot needs it. */
    if (g_st.tm && g_st.sm && g_st.ui && kind && world)
    {
        uintptr_t owner = ReadController(kind);
        uintptr_t atlas = ReadManager(&p);
        ReadDescriptor(atlas);
        ReadQueue();
        ReadScreen(kind, owner, atlas);
    }
    LEN[REGION_POLICY] = (int32_t)(p - kRegion[REGION_POLICY]);
    CountVersions();
}

/* The idle gate's check: the globals block (a plain load) and the state stack (1 read) into the view's buffers; the
 * signature stays as the last refresh left it. When the frame is not idle, the next refresh in the same tick uses these
 * instead of making them again; apc_state_unprobe (before the game update) drops them. lint: per-frame */
int apc_state_probe(uintptr_t* tm, uint32_t* depth, int32_t* top)
{
    g_st.probed = 0;
    if (!vpm_game_read(APC_RVA_GLOBALS, g_st.G, sizeof g_st.G)) return 0;
    uintptr_t sm = ApcWordPointer(g_st.G, 42);
    if (!sm || !apc_read(sm + 0x429C, g_st.STACK, 24)) return 0;
    g_st.probed = 1;
    *depth = g_st.STACK[5];
    *top = *depth >= 1 && *depth <= 5 ? (int32_t)g_st.STACK[*depth - 1] : -1;
    *tm = ApcWordPointer(g_st.G, 0);
    return 1;
}

/* lint: per-frame */
void apc_state_unprobe(void) { g_st.probed = 0; }

/* The lease table's owner (header and allocator), read by the policy step only: 2 reads, a version of its own. */
void apc_state_refresh_lease(void)
{
    uintptr_t lease = g_st.lease;
    memset(g_leaseWords, 0, sizeof g_leaseWords);
    if (lease)
    {
        g_leaseWords[0] = 1;
        g_leaseWords[1] = (uint32_t)lease;
        g_leaseWords[2] = (uint32_t)((uint64_t)lease >> 32);
        if (apc_read(lease, g_st.LEASE, 32))
        {
            static const int kHeader[6] = {0, 1, 2, 4, 5, 6}; /* the storage pointer, capacity, the sentinel, the mode */
            g_leaseWords[0] += 2;
            for (int i = 0; i < 6; i++) g_leaseWords[3 + i] = g_st.LEASE[kHeader[i]];
        }
        if (apc_read(lease + 16416, &g_st.LEASE[8], 8))
        {
            g_leaseWords[0] += 4;
            g_leaseWords[9] = g_st.LEASE[8];
            g_leaseWords[10] = g_st.LEASE[9];
        }
    }
    int same = g_st.lease_checked && memcmp(g_leaseWords, g_leasePrevious, sizeof g_leaseWords) == 0;
    memcpy(g_leasePrevious, g_leaseWords, sizeof g_leaseWords);
    g_st.lease_checked = 1;
    if (!same) g_st.lease_version++;
}
