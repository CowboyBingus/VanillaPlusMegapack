/* Match Your Colors: the measured appearance (appearance.lua), 1:1: for a measured kit, which LUT rows and patterns
 * show and how many screen pixels each covers; for a seen LUT row, how its paint looks there (perceived = s + g x
 * mean albedo per channel). Parsed on demand from myc_appearance_data.c's texts and kept for the session; the
 * worker's jobs read it (one job at a time). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_appearance.h"

#define MAX_ROWS 64

typedef struct MycAppRows { int count; int rows[MAX_ROWS]; double cal[MAX_ROWS][6]; } MycAppRows;
typedef struct MycAppSeen { double share[MAX_ROWS]; } MycAppSeen;

static struct
{
    MycArena arena;
    MycMap index;           /* LUT -> index + 1 */
    MycAppRows** rows;      /* per LUT index, parsed */
    MycAppKit** kits;       /* per kit index, parsed */
    MycSMap by_luts;        /* sorted LUT list -> kit index + 1, or MYC_MISSING when two kits share it */
    int by_luts_made;
    MycMap seen;            /* LUT -> MycAppSeen */
    int seen_made;
} g_app;

void myc_app_free(void)
{
    myc_arena_free(&g_app.arena);
    memset(&g_app, 0, sizeof g_app);
}

static int MycAppIndex(uint64_t lut)
{
    if (g_app.index.count == 0)
    {
        for (int i = 0; i < myc_app_lut_count; i++)
            if (!myc_map_put(&g_app.arena, &g_app.index, myc_app_luts[i], (void*)(intptr_t)(i + 1))) return -1;
        g_app.rows = myc_alloc(&g_app.arena, sizeof(MycAppRows*) * (size_t)myc_app_lut_count);
        g_app.kits = myc_alloc(&g_app.arena, sizeof(MycAppKit*) * (size_t)myc_app_kit_count);
        if (g_app.rows == NULL || g_app.kits == NULL) return -1;
    }
    void* i = myc_map_get(&g_app.index, lut);
    return i != NULL ? (int)((intptr_t)i - 1) : -1;
}

/* One 'row s0 s1 s2 g0 g1 g2' entry of a LUT's text at *at, up to and past its '|': how many numbers it holds. */
static int MycAppCalEntry(const char** at, double v[7])
{
    const char* p = *at;
    int n = 0;
    while (*p && *p != '|' && n < 7)
    {
        char* end = NULL;
        v[n] = strtod(p, &end);
        if (end == p) break;
        n++;
        p = end;
        while (*p == ' ') p++;
    }
    while (*p && *p != '|') p++;
    if (*p == '|') p++;
    *at = p;
    return n;
}

/* LUT index i's measured rows, parsed once. */
static MycAppRows* MycAppRowsOf(int i)
{
    if (g_app.rows[i] != NULL) return g_app.rows[i];
    MycAppRows* rows = myc_alloc(&g_app.arena, sizeof *rows);
    if (rows == NULL) return NULL;
    for (const char* p = myc_app_rows[i]; *p && rows->count < MAX_ROWS;)
    {
        double v[7];
        if (MycAppCalEntry(&p, v) < 7) continue;
        rows->rows[rows->count] = (int)v[0];
        memcpy(rows->cal[rows->count], v + 1, sizeof(double) * 6);
        rows->count++;
    }
    g_app.rows[i] = rows;
    return rows;
}

const double* myc_app_row(uint64_t lut, int r)
{
    int i = MycAppIndex(lut);
    if (i < 0 || myc_app_rows[i] == NULL) return NULL;
    MycAppRows* rows = MycAppRowsOf(i);
    if (rows == NULL) return NULL;
    /* a row listed twice keeps its last values (rows[v[1]] = ... in the Lua) */
    for (int k = rows->count - 1; k >= 0; k--)
        if (rows->rows[k] == r) return rows->cal[k];
    return NULL;
}

/* ---- kits -------------------------------------------------------------------------------------------------------- */

static int MycAppFindKit(uint32_t id)
{
    int lo = 0, hi = myc_app_kit_count - 1;
    while (lo <= hi)
    {
        int mid = (lo + hi) / 2;
        if (myc_app_kits[mid].id == id) return mid;
        if (myc_app_kits[mid].id < id) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

/* A run of digits as an integer (the Lua's (%d+)). */
static int MycAppInt(const char** p, double* out)
{
    const char* q = *p;
    double v = 0;
    while (*q >= '0' && *q <= '9') { v = v * 10 + (*q - '0'); q++; }
    if (q == *p) return 0;
    *out = v;
    *p = q;
    return 1;
}

static int MycAppNumber(const char** p, double* out)
{
    char* end = NULL;
    *out = strtod(*p, &end);
    if (end == *p) return 0;
    *p = end;
    return 1;
}

/* A rows entry after its index: '.row=px,light' at *at (on its '.'): 1 with v[1..3], else 0 (*at past what was read). */
static int MycAppRowTail(const char** at, double v[4])
{
    const char* p = *at + 1;
    int ok = 0;
    if (MycAppInt(&p, &v[1]) && *p == '=')
    {
        p++;
        if (MycAppInt(&p, &v[2]) && *p == ',')
        {
            p++;
            ok = MycAppInt(&p, &v[3]);
        }
    }
    *at = p;
    return ok;
}

/* One 'index.row=px,light' entry from *at (non-digits skipped first): 1 with its four numbers, else 0. */
static int MycAppRowEntry(const char** at, const char* stop, double v[4])
{
    const char* p = *at;
    while (p < stop && (*p < '0' || *p > '9')) p++;
    int ok = 0;
    if (p >= stop || !MycAppInt(&p, &v[0]) || *p != '.')
        while (p < stop && *p != ' ') p++;
    else ok = MycAppRowTail(&p, v);
    *at = p;
    return ok;
}

/* The rows part: 'index.row=px,light ...'. */
static void MycAppParseRows(const char* p, const char* stop, MycAppKit* kit, MycVec* rows)
{
    while (p < stop)
    {
        double v[4];
        if (!MycAppRowEntry(&p, stop, v)) continue;
        MycAppRow* row = myc_vec_push(&g_app.arena, rows, sizeof(MycAppRow));
        if (row == NULL) return;
        int i = (int)v[0];
        row->lut = i >= 1 && i <= myc_app_lut_count ? myc_app_luts[i - 1] : 0;
        row->row = (int)v[1];
        row->px = v[2];
        row->light = v[3];
    }
}

/* The patterns part: '<hex>=px,gr,gg,gb ...' (the gain only when measured). */
/* Up to max comma-separated numbers at *p: how many. */
static int MycAppNumbers(const char** p, double* v, int max)
{
    int n = 0;
    while (n < max && MycAppNumber(p, &v[n]))
    {
        n++;
        if (**p != ',') break;
        (*p)++;
    }
    return n;
}

/* One '<hex>=px[,gr,gg,gb]' entry at *at into out: 1 when it names a pattern and its pixels, else 0 (*at past it). */
static int MycAppPatternEntry(const char** at, MycAppPattern* out)
{
    const char* p = *at;
    char* end = NULL;
    unsigned long long name = strtoull(p, &end, 16);
    int n = 0;
    double v[4];
    if (end != p && *end == '=')
    {
        p = end + 1;
        n = MycAppNumbers(&p, v, 4);
    }
    while (*p && *p != ' ') p++;
    *at = p;
    if (n < 1) return 0;
    memset(out, 0, sizeof *out);
    out->pattern = name;
    out->px = v[0];
    if (n >= 4) { out->gain[0] = v[1]; out->gain[1] = v[2]; out->gain[2] = v[3]; out->has_gain = 1; }
    return 1;
}

static void MycAppParsePatterns(const char* p, MycVec* out)
{
    while (*p)
    {
        while (*p == ' ') p++;
        if (*p == 0) break;
        MycAppPattern entry;
        if (!MycAppPatternEntry(&p, &entry)) continue;
        MycAppPattern* pattern = myc_vec_push(&g_app.arena, out, sizeof(MycAppPattern));
        if (pattern != NULL) *pattern = entry;
    }
}

static MycAppKit* MycAppParseKit(int k)
{
    if (g_app.kits[k] != NULL) return g_app.kits[k];
    const char* text = myc_app_kits[k].text;
    const char* first = strchr(text, ';');
    const char* second = first != NULL ? strchr(first + 1, ';') : NULL;
    MycAppKit* kit = myc_alloc(&g_app.arena, sizeof *kit);
    if (kit == NULL || second == NULL) return NULL;
    kit->id = myc_app_kits[k].id;
    MycVec luts = {0}, rows = {0}, patterns = {0};
    for (const char* p = text; p < first;)
    {
        double i;
        if (!MycAppInt(&p, &i)) { p++; continue; }
        uint64_t* lut = myc_vec_push(&g_app.arena, &luts, sizeof(uint64_t));
        if (lut != NULL && (int)i >= 1 && (int)i <= myc_app_lut_count) *lut = myc_app_luts[(int)i - 1];
    }
    MycAppParseRows(first + 1, second, kit, &rows);
    MycAppParsePatterns(second + 1, &patterns);
    kit->luts = luts.items;
    kit->nluts = luts.count;
    kit->rows = rows.items;
    kit->nrows = rows.count;
    kit->patterns = patterns.items;
    kit->npatterns = patterns.count;
    g_app.kits[k] = kit;
    return kit;
}

const MycAppKit* myc_app_kit(uint32_t id)
{
    if (MycAppIndex(0) < -1) return NULL;
    int k = MycAppFindKit(id);
    return k >= 0 ? MycAppParseKit(k) : NULL;
}

int myc_app_kit_has_lut(const MycAppKit* kit, uint64_t lut)
{
    for (int i = 0; i < kit->nluts; i++)
        if (kit->luts[i] == lut) return 1;
    return 0;
}

const MycAppRow* myc_app_kit_row(const MycAppKit* kit, uint64_t lut, int row)
{
    for (int i = kit->nrows - 1; i >= 0; i--) /* a repeat keeps the last */
        if (kit->rows[i].lut == lut && kit->rows[i].row == row) return &kit->rows[i];
    return NULL;
}

const MycAppPattern* myc_app_kit_pattern(const MycAppKit* kit, uint64_t pattern)
{
    for (int i = kit->npatterns - 1; i >= 0; i--)
        if (kit->patterns[i].pattern == pattern) return &kit->patterns[i];
    return NULL;
}

static int MycAppU64Less(const void* x, const void* y, void* ctx) { return *(const uint64_t*)x < *(const uint64_t*)y; }

/* The sorted, comma-joined hex names of luts (unique) into out. */
static void MycAppKey(const uint64_t* luts, int count, char* out, size_t size)
{
    uint64_t* copy = malloc(sizeof(uint64_t) * (size_t)(count > 0 ? count : 1));
    void** order = malloc(sizeof(void*) * (size_t)(count > 0 ? count : 1));
    size_t at = 0;
    out[0] = 0;
    if (copy == NULL || order == NULL) { free(copy); free(order); return; }
    for (int i = 0; i < count; i++) { copy[i] = luts[i]; order[i] = &copy[i]; }
    myc_lua_sort(order, count, MycAppU64Less, NULL);
    for (int i = 0; i < count && at < size; i++)
        at += (size_t)snprintf(out + at, size - at, "%s%016llx", i > 0 ? "," : "", (unsigned long long)*(uint64_t*)order[i]);
    free(copy);
    free(order);
}

/* A kit's LUT list as a set (the list may repeat a LUT): how many. */
static int MycAppUniqueLuts(const MycAppKit* kit, uint64_t* unique, int max)
{
    int n = 0;
    for (int i = 0; i < kit->nluts && n < max; i++)
    {
        int seen = 0;
        for (int j = 0; j < n; j++) seen |= unique[j] == kit->luts[i];
        if (!seen) unique[n++] = kit->luts[i];
    }
    return n;
}

/* Every kit by its sorted LUT set, once (two kits with one set: MYC_MISSING). */
static void MycAppByLuts(char* key, size_t size)
{
    for (int k = 0; k < myc_app_kit_count; k++)
    {
        MycAppKit* kit = MycAppParseKit(k);
        if (kit == NULL) continue;
        uint64_t unique[256];
        MycAppKey(unique, MycAppUniqueLuts(kit, unique, 256), key, size);
        void* known = myc_smap_get(&g_app.by_luts, key);
        (void)myc_smap_put(&g_app.arena, &g_app.by_luts, key, known == NULL ? (void*)(intptr_t)(k + 1) : MYC_MISSING);
    }
    g_app.by_luts_made = 1;
}

const MycAppKit* myc_app_kit_for(const uint64_t* luts, int count)
{
    static char key[16384];
    if (MycAppIndex(0) < -1) return NULL;
    if (!g_app.by_luts_made) MycAppByLuts(key, sizeof key);
    MycAppKey(luts, count, key, sizeof key);
    void* found = myc_smap_get(&g_app.by_luts, key);
    if (found == NULL || found == MYC_MISSING) return NULL;
    return MycAppParseKit((int)((intptr_t)found - 1));
}

/* ---- seen shares --------------------------------------------------------------------------------------------------- */

static void MycAppIndexKit(const MycAppKit* kit)
{
    double total = 0;
    for (int i = 0; i < kit->nrows; i++) total += kit->rows[i].px;
    for (int i = 0; i < kit->npatterns; i++) total += kit->patterns[i].px;
    for (int i = 0; i < kit->nluts; i++)
        if (myc_map_get(&g_app.seen, kit->luts[i]) == NULL)
        {
            MycAppSeen* s = myc_alloc(&g_app.arena, sizeof *s);
            if (s == NULL || !myc_map_put(&g_app.arena, &g_app.seen, kit->luts[i], s)) return;
        }
    for (int i = 0; i < kit->nrows; i++)
    {
        MycAppSeen* s = myc_map_get(&g_app.seen, kit->rows[i].lut);
        int r = kit->rows[i].row;
        double share = total > 0 ? kit->rows[i].px / total : 0;
        if (s != NULL && r >= 0 && r < MAX_ROWS && share > s->share[r]) s->share[r] = share;
    }
}

double myc_app_seen_share(uint64_t lut, int r)
{
    if (!g_app.seen_made)
    {
        if (MycAppIndex(0) < -1) return -1;
        for (int k = 0; k < myc_app_kit_count; k++)
        {
            MycAppKit* kit = MycAppParseKit(k);
            if (kit != NULL) MycAppIndexKit(kit);
        }
        g_app.seen_made = 1;
    }
    MycAppSeen* s = myc_map_get(&g_app.seen, lut);
    if (s == NULL) return -1;
    return r >= 0 && r < MAX_ROWS ? s->share[r] : 0;
}

/* ---- hoods ------------------------------------------------------------------------------------------------------------ */

static const char* MycAppHoods(uint32_t id)
{
    for (int i = 0; i < myc_app_hood_count; i++)
        if (myc_app_hoods[i].id == id) return myc_app_hoods[i].text;
    return NULL;
}

int myc_app_has_hoods(uint32_t id) { return MycAppHoods(id) != NULL; }

int myc_app_is_hood(uint32_t id, uint64_t lut, int r)
{
    const char* p = MycAppHoods(id);
    while (p != NULL && *p)
    {
        double i, row;
        while (*p == ' ') p++;
        if (!MycAppInt(&p, &i) || *p != '.') break;
        p++;
        if (!MycAppInt(&p, &row)) break;
        if ((int)i >= 1 && (int)i <= myc_app_lut_count && myc_app_luts[(int)i - 1] == lut && (int)row == r) return 1;
    }
    return 0;
}
