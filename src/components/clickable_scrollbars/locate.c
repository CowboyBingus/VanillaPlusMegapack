/* Clickable Scrollbars: which scrollbar is visible and who owns it, and whether that still holds (Lua: locate.lua, and
 * the read tape of memory.lua's native_reader).
 *
 * The equipment grids are found through the game's dispatch table ([game + 0x3326E68]): its rows name each registered
 * screen controller by kind, 224 the Armory and 229 the mission loadout picker (whose controller can stay registered
 * under another screen, so the UI screen stack decides which one is on top). The Armory's Career panel owns its own
 * bar. The Settings and Controls pages are not registered: the screen stack's top id (1, 26) and the page's own pointer
 * in the menu ([game + 0x347CE38]) gate them. A bar counts only while its resolved alpha (+84) is above 0.95.
 *
 * Every read the resolution makes goes on the bridge's tape with the bytes it returned. A held drag repeats the tape
 * instead of resolving again: while every read returns the same bytes, the resolution would find the same owner. The
 * game.dll globals are plain loads (the Lua read them with ReadProcessMemory); the heap goes through vpm_read.
 *
 * Reads (vpm_read) per resolution: Armory grid 4, loadout grid 4, Career 3, Controls and Settings 6, nothing visible in
 * play 2-3 (the Lua: 5, 6, 4, 9, 9 and a GetModuleHandleA). A repeat costs the same reads. */
#include <string.h>
#include "clickable_scrollbars.h"

#define DISPATCH_RVA 0x3326E68u /* the dispatch table */
#define STACK_RVA 0x347CE28u    /* the UI screen stack's owner */
#define MENU_RVA 0x347CE38u     /* the options menu */
#define AT_COUNT 5740u          /* dispatch: registered rows */
#define AT_ROWS 5744u           /* dispatch: 16-byte rows {controller, kind, 0} */
#define ROW_SIZE 16u
#define MAX_ROWS 64u
#define AT_STACK 0x429Cu        /* stack owner: five screen ids, then the depth at +20 */
#define STACK_SIZE 24u
#define KIND_ARMORY 224u
#define KIND_LOADOUT 229u
#define TOP_ARMORY 5u           /* the screen ids of the two equipment screens */
#define TOP_LOADOUT 14u
#define AT_ALPHA 84u            /* a widget's resolved alpha (parent visibility included) */
#define VISIBLE 0.95
#define AT_OPEN 12u             /* an options screen: 1 while open */

/* The routine reported a final answer (found or refused) or goes on to the options pages. */
#define FOUND 1
#define REFUSED 0
#define NEXT 2

typedef struct Page { uint32_t screen, menu, list, route; } Page;
static const Page kPages[] = {
    {1u, 200u, 4189984u, CS_ROUTE_SETTINGS},
    {26u, 208u, 338344u, CS_ROUTE_BINDINGS},
};

static CsTape* g_tape;                  /* the tape the reads go on (cs_resolve only) */
static uint8_t g_rows[MAX_ROWS * ROW_SIZE]; /* the registry as read (static: off the game thread's stack) */
static uint8_t g_again[MAX_ROWS * ROW_SIZE]; /* a repeated read (cs_unchanged) */

uintptr_t cs_pointer(uint64_t value) { return value >= 0x10000u && value < 0x800000000000ull ? (uintptr_t)value : 0; }

int cs_same_key(const CsKey* a, const CsKey* b) { return a->owner == b->owner && a->kind == b->kind && a->route == b->route; }

static uint32_t Word(const uint8_t* bytes, uint32_t at)
{
    uint32_t value;
    memcpy(&value, bytes + at, 4);
    return value;
}

static void Record(uintptr_t address, const void* bytes, size_t size, int ok, int image)
{
    CsTape* tape = g_tape;
    if (tape->full) return;
    if (tape->count >= CS_TAPE_READS || tape->used + size > CS_TAPE_BYTES) { tape->full = 1; return; }
    CsTapeRead* read = &tape->reads[tape->count++];
    read->address = address;
    read->at = tape->used;
    read->size = (uint16_t)size;
    read->image = (uint8_t)image;
    read->ok = (uint8_t)ok;
    if (ok) memcpy(tape->bytes + tape->used, bytes, size);
    tape->used += (uint32_t)size;
}

/* lint: per-frame */
static int TapeRead(uintptr_t address, void* out, size_t size)
{
    int ok = vpm_read(address, out, size);
    Record(address, out, size, ok, 0);
    return ok;
}

/* The pointer stored at a game.dll global, decoded (0 when implausible). */
static uintptr_t TapeGlobal(uint32_t rva)
{
    uint64_t value = 0;
    int ok = vpm_game_read(rva, &value, sizeof value);
    Record(rva, &value, sizeof value, ok, 1);
    return ok ? cs_pointer(value) : 0;
}

/* lint: per-frame */
static int Visible(uintptr_t widget)
{
    float alpha = 0;
    return TapeRead(widget + AT_ALPHA, &alpha, sizeof alpha) && (double)alpha > VISIBLE;
}

/* The screen id on top of the UI stack: 1 with *top, 0 for a depth out of 1 .. 5, -1 when the stack is unreadable. */
static int TopScreen(uint32_t* top)
{
    uint8_t stack[STACK_SIZE];
    uintptr_t owner = TapeGlobal(STACK_RVA);
    if (owner == 0 || !TapeRead(owner + AT_STACK, stack, sizeof stack)) return -1;
    uint32_t depth = Word(stack, 20);
    if (depth < 1 || depth > 5) return 0;
    *top = Word(stack, (depth - 1) * 4);
    return 1;
}

/* With the loadout controller registered: the equipment kind on top (*kind 0 when the stack cannot say, so any
 * registered kind may own the bar). 0 when another screen is on top. */
static int ActiveKind(uint32_t* kind)
{
    uint32_t top = 0;
    int known = TopScreen(&top);
    *kind = 0;
    if (known < 0) return 1;
    if (known == 0) return 0;
    if (top == TOP_ARMORY) *kind = KIND_ARMORY;
    else if (top == TOP_LOADOUT) *kind = KIND_LOADOUT;
    else return 0;
    return 1;
}

/* An equipment controller's visible bar: the Career panel's when it shows (the grid stays allocated behind it and must
 * never own its gestures), else the grid's. 0 when neither shows. */
static int EquipmentOwner(CsBridge* out, uintptr_t controller, uint32_t kind)
{
    out->controller = controller;
    out->kind = kind;
    out->grid = controller + (kind == KIND_ARMORY ? CS_GRID_OFFSET : CS_LOADOUT_GRID_OFFSET);
    out->panel = kind == KIND_ARMORY ? controller + CS_CAREER_OFFSET : 0;
    if (out->panel != 0 && Visible(out->panel + CS_CAREER_TRACK))
    {
        out->route = CS_ROUTE_CAREER;
        out->bar = out->panel + CS_CAREER_TRACK;
        out->thumb = out->panel + CS_CAREER_THUMB;
    }
    else if (Visible(out->grid + CS_GRID_BAR))
    {
        out->route = CS_ROUTE_GRID;
        out->bar = out->grid + CS_GRID_BAR;
        out->thumb = out->grid + CS_GRID_THUMB;
    }
    else return 0;
    out->key = (CsKey){controller, kind, out->route};
    return 1;
}

/* The registered equipment controllers in registry order. A stale or hidden one may come before the visible owner, so
 * the search goes on, unless the screen stack named the kind. */
static int Equipment(CsBridge* out, uint32_t count, uint32_t active, const char** reason)
{
    for (uint32_t i = 0; i < count; i++)
    {
        uint32_t kind = Word(g_rows, i * ROW_SIZE + 8);
        if ((kind != KIND_ARMORY && kind != KIND_LOADOUT) || (active != 0 && kind != active)) continue;
        uint64_t raw;
        memcpy(&raw, g_rows + i * ROW_SIZE, sizeof raw);
        uintptr_t controller = cs_pointer(raw);
        if (controller == 0) { *reason = "equipment controller unavailable"; return REFUSED; }
        if (EquipmentOwner(out, controller, kind)) return FOUND;
        if (active != 0) { *reason = "no visible equipment scrollbar"; return REFUSED; }
    }
    return NEXT;
}

/* The options pages: no registry row; the screen stack's top id and the page's own pointer and open flag gate them. */
static int OptionsOwner(CsBridge* out)
{
    uint32_t screen_id = 0;
    if (TopScreen(&screen_id) != 1) return 0;
    const Page* page = NULL;
    for (size_t i = 0; i < sizeof kPages / sizeof kPages[0]; i++)
        if (kPages[i].screen == screen_id) page = &kPages[i];
    if (page == NULL) return 0;
    uintptr_t menu = TapeGlobal(MENU_RVA);
    uint64_t raw = 0;
    uintptr_t screen = menu != 0 && TapeRead(menu + page->menu, &raw, sizeof raw) ? cs_pointer(raw) : 0;
    uint8_t open = 0;
    if (screen == 0 || !TapeRead(screen + AT_OPEN, &open, 1) || open != 1) return 0;
    uintptr_t list = screen + page->list;
    if (!Visible(list + CS_OPTIONS_BAR)) return 0;
    out->route = page->route;
    out->kind = screen_id;
    out->controller = screen;
    out->grid = list;
    out->panel = 0;
    out->bar = list + CS_OPTIONS_BAR;
    out->thumb = list + CS_OPTIONS_THUMB;
    out->key = (CsKey){screen, screen_id, page->route};
    return 1;
}

static void Registered(uint32_t count, int* armory, int* loadout)
{
    for (uint32_t i = 0; i < count; i++)
    {
        uint32_t kind = Word(g_rows, i * ROW_SIZE + 8);
        if (kind == KIND_ARMORY) *armory = 1;
        else if (kind == KIND_LOADOUT) *loadout = 1;
    }
}

/* native_locate */
static int Locate(CsBridge* out, const char** reason)
{
    uintptr_t dispatch = TapeGlobal(DISPATCH_RVA);
    if (dispatch == 0) { *reason = "dispatch table unavailable"; return 0; }
    uint32_t count = 0;
    if (!TapeRead(dispatch + AT_COUNT, &count, sizeof count) || count < 1 || count > MAX_ROWS)
    {
        *reason = "dispatch bounds changed";
        return 0;
    }
    /* the bounded registry in one read, not a read per row */
    if (!TapeRead(dispatch + AT_ROWS, g_rows, count * ROW_SIZE)) { *reason = "dispatch rows unreadable"; return 0; }
    int armory = 0, loadout = 0;
    Registered(count, &armory, &loadout);
    uint32_t active = 0;
    if (loadout && !ActiveKind(&active)) { *reason = "unsupported UI screen"; return 0; }
    int found = Equipment(out, count, active, reason);
    if (found != NEXT) return found == FOUND;
    if (OptionsOwner(out)) return 1;
    *reason = armory || loadout ? "no visible equipment scrollbar" : "equipment grid not registered";
    return 0;
}

/* lint: per-frame */
int cs_resolve(CsBridge* out, const char** reason)
{
    memset(out, 0, offsetof(CsBridge, tape));
    out->tape.count = 0;
    out->tape.full = 0;
    out->tape.used = 0;
    g_tape = &out->tape;
    int found = Locate(out, reason);
    g_tape = NULL;
    return found;
}

/* lint: per-frame */
int cs_unchanged(const CsTape* tape)
{
    if (tape->count == 0 || tape->full) return 0;
    for (int i = 0; i < tape->count; i++)
    {
        const CsTapeRead* read = &tape->reads[i];
        int ok = read->image ? vpm_game_read((uint32_t)read->address, g_again, read->size)
                             : vpm_read(read->address, g_again, read->size);
        if (ok != read->ok || (ok && memcmp(g_again, tape->bytes + read->at, read->size) != 0)) return 0;
    }
    return 1;
}
