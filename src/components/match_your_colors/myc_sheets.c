/* Match Your Colors: the emblem-sheet copies (sheets.lua), 1:1. A cape emblem that would no longer read is recolored
 * in a copy of the cape's decal sheet (BC3 with its mip chain, bound on its materials' decal sheet slot). A plan keeps
 * only the recipe; a job turns it into the sheet's data, SHEETS_KEPT recipes kept and every copy still referenced found
 * again (Lua: a weak table; here a registry whose copies only it holds are let go). About 5.6 MB per sheet; runs on the
 * worker inside a job. */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "myc_capes.h"

#define SHIFT_STEP (1.0 / 1024)
#define REGISTRY 16
#define KEY_SIZE 4096

typedef struct MycSheetEntry { char key[KEY_SIZE]; MycSpec* spec; unsigned long used; } MycSheetEntry;
static MycSheetEntry myc_sheets[REGISTRY];
static unsigned long myc_sheets_clock;

size_t myc_bc3_bytes(uint32_t width, uint32_t height, uint32_t mips)
{
    size_t total = 0;
    for (uint32_t m = 0; m < mips; m++)
    {
        uint32_t w = width >> m > 0 ? width >> m : 1, h = height >> m > 0 ? height >> m : 1;
        size_t bw = (w + 3) / 4 > 0 ? (w + 3) / 4 : 1, bh = (h + 3) / 4 > 0 ? (h + 3) / 4 : 1;
        total += bw * bh * 16;
    }
    return total;
}

static double MycSheetStep(double x) { return floor(x / SHIFT_STEP + 0.5) * SHIFT_STEP; }

static int MycSheetOverlaps(const MycSheetRecipe* r, const int rect[4])
{
    for (int i = 0; i < r->ncells; i++)
    {
        const int* c = r->cells[i].rect;
        if (rect[0] < c[2] && c[0] < rect[2] && rect[1] < c[3] && c[1] < rect[3]) return 1;
    }
    return 0;
}

int myc_sheet_recipe(const MycAnalysis* target, const MycEmblemPick* picks, MycSheetRecipe* out)
{
    int has = 0;
    memset(out, 0, sizeof *out);
    for (int i = 0; i < target->nemblems; i++)
    {
        const MycEmblem* e = &target->emblems[i];
        const MycEmblemPick* pick = &picks[i];
        if (!pick->has || !e->has_rect || e->sheet_format != MYC_SHEET_FORMAT || (has && out->name != e->sheet)) continue;
        if (!has)
        {
            out->name = e->sheet;
            out->width = e->sheet_width;
            out->height = e->sheet_height;
            out->mips = e->sheet_mips;
            out->size = myc_bc3_bytes(e->sheet_width, e->sheet_height, e->sheet_mips);
            has = 1;
        }
        if (MycSheetOverlaps(out, e->rect) || out->ncells >= MYC_SHEET_CELLS) continue;
        MycSheetCell* cell = &out->cells[out->ncells++];
        memcpy(cell->rect, e->rect, sizeof cell->rect);
        cell->shift[0] = MycSheetStep(pick->L - e->L);
        cell->shift[1] = MycSheetStep(pick->a - e->a);
        cell->shift[2] = MycSheetStep(pick->b - e->b);
    }
    return has;
}

void myc_sheet_key(const MycSheetRecipe* recipe, char* out, size_t size)
{
    size_t at = (size_t)snprintf(out, size, "%016llx", (unsigned long long)recipe->name);
    for (int i = 0; i < recipe->ncells && at < size; i++)
    {
        const MycSheetCell* c = &recipe->cells[i];
        at += (size_t)snprintf(out + at, size - at, ";%d,%d,%d,%d:%.9g,%.9g,%.9g", c->rect[0], c->rect[1], c->rect[2],
            c->rect[3], c->shift[0], c->shift[1], c->shift[2]);
    }
}

/* Lets go of the copies only the registry holds that are not among the SHEETS_KEPT most recently used. */
static void MycSheetsSweep(void)
{
    for (int i = 0; i < REGISTRY; i++)
    {
        MycSheetEntry* e = &myc_sheets[i];
        if (e->spec == NULL || e->spec->refs > 1) continue;
        int newer = 0;
        for (int j = 0; j < REGISTRY; j++) newer += myc_sheets[j].spec != NULL && myc_sheets[j].used > e->used;
        if (newer >= MYC_SHEETS_KEPT) { myc_spec_drop(e->spec); e->spec = NULL; }
    }
}

static MycSheetEntry* MycSheetsFind(const char* key)
{
    for (int i = 0; i < REGISTRY; i++)
        if (myc_sheets[i].spec != NULL && strcmp(myc_sheets[i].key, key) == 0) return &myc_sheets[i];
    return NULL;
}

/* A free registry slot (the least recently used copy only it holds is let go when full); NULL when every copy is
 * still referenced. */
static MycSheetEntry* MycSheetsSlot(void)
{
    MycSheetEntry* oldest = NULL;
    for (int i = 0; i < REGISTRY; i++)
    {
        if (myc_sheets[i].spec == NULL) return &myc_sheets[i];
        if (myc_sheets[i].spec->refs == 1 && (oldest == NULL || myc_sheets[i].used < oldest->used)) oldest = &myc_sheets[i];
    }
    if (oldest != NULL) { myc_spec_drop(oldest->spec); oldest->spec = NULL; }
    return oldest;
}

MycSpec* myc_sheet_spec(const MycSheetRecipe* recipe, MycSheetOriginal original, void* ctx, char* why, size_t why_size,
    MycErr* err)
{
    static char key[KEY_SIZE];
    myc_sheet_key(recipe, key, sizeof key);
    MycSheetEntry* known = MycSheetsFind(key);
    if (known != NULL)
    {
        known->used = ++myc_sheets_clock;
        MycSheetsSweep();
        return myc_spec_hold(known->spec);
    }
    const uint8_t* bytes = original(ctx, recipe, why, why_size);
    if (bytes == NULL) return NULL;
    MycSpec* spec = myc_spec_new(MYC_SPEC_SHEET, (int)recipe->width, (int)recipe->height, recipe->size);
    if (spec == NULL) { myc_fail(err, "no memory for a %zu-byte sheet", recipe->size); return NULL; }
    memcpy(spec->data, bytes, recipe->size);
    for (int i = 0; i < recipe->ncells; i++)
        myc_cape_recolor_sheet(spec->data, recipe->width, recipe->height, recipe->mips, recipe->cells[i].rect, recipe->cells[i].shift);
    spec->mips = (int)recipe->mips;
    spec->format = MYC_SHEET_FORMAT;
    spec->name = recipe->name;
    myc_capes_sheet_sums(key, spec->data, recipe->size, &spec->recipe_sum, &spec->sample);
    MycSheetEntry* slot = MycSheetsSlot();
    if (slot != NULL)
    {
        snprintf(slot->key, sizeof slot->key, "%s", key);
        slot->spec = myc_spec_hold(spec);
        slot->used = ++myc_sheets_clock;
    }
    MycSheetsSweep();
    return spec;
}

void myc_sheets_free(void)
{
    for (int i = 0; i < REGISTRY; i++)
    {
        myc_spec_drop(myc_sheets[i].spec);
        myc_sheets[i].spec = NULL;
    }
    myc_sheets_clock = 0;
}
