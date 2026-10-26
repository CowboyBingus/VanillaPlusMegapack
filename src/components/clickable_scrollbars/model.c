/* Clickable Scrollbars: the owner's scroll model, read in blocks, and the track on screen (Lua: model.lua, and the
 * arithmetic of native.lua: native_value_at_grab, native_moved).
 *
 * Each route's fields are grouped in blocks read with one vpm_read each (the Lua's read_block): an equipment grid 4
 * (its bar and value; the first row's columns; the row table with the counts, scroll and content; the visible range),
 * Career 2 (its list container; its bar), an options list 1. A block that cannot be read leaves its fields unset, as
 * in the Lua. A model that does not look like this build's (counts, pixel sizes, a 0..1 value) is refused, never
 * written to. Scrollbar widgets: +12 width, +16 height, +100 and +140 UI scale, +148 left, +156 bottom (the thumb's
 * rendered position). Arithmetic is in doubles over the floats read, as the Lua's numbers were. */
#include <string.h>
#include "clickable_scrollbars.h"

#define BLOCK_BYTES 4352u    /* the largest block (the grid's row table) */
/* grid fields (native.lua GRID) */
#define GRID_ROWS 597772u    /* int, visible row slots */
#define GRID_SELECTED 600308u
#define GRID_CONTENT 600424u /* float px, laid-out content height */
#define GRID_ITEMS 600452u   /* int, items in the open category */
#define GRID_KIND 602052u    /* int, category/layout type */
#define GRID_ANCHOR 602096u  /* int, the centre index the solver last published */
#define GRID_FIRST 622656u   /* int, first and last visible item */
#define GRID_LAST 622660u
#define GRID_COLUMNS 47540u  /* int, the first visible row's item count */
#define GRID_SPAN 0x8C0u     /* float px, content - viewport */
#define GRID_VALUE 0x8C8u    /* float 0..1, the scrollbar's own value */
#define MAX_ROWS 16u
#define MAX_COLUMNS 8u
#define MAX_ITEMS 100000u
/* options list fields (native.lua OPTIONS_LIST) */
#define OPTIONS_SCROLL 552u
#define OPTIONS_SPAN 2784u
#define OPTIONS_VALUE 2792u

/* A block: its first byte from the route's base object and its size (model.lua's sealed field groups). */
typedef struct Block { uint32_t first, size; } Block;
static const Block kGridBar = {284u, 1968u};       /* bar and thumb widgets, span, value */
static const Block kGridColumns = {47540u, 4u};
static const Block kGridTable = {597772u, 4328u}; /* rows .. anchor */
static const Block kGridRange = {622656u, 8u};     /* first, last */
static const Block kCareerList = {2492u, 32u};     /* the list container's x, y, height, scale */
static const Block kCareerBar = {195268u, 700u};
static const Block kOptions = {552u, 2244u};

/* The widget fields as read (model.lua's raw). */
typedef struct Widget
{
    int read;
    double width, height, sx, sy, left, bottom, thumb, rendered_thumb;
} Widget;

static uint8_t g_block[BLOCK_BYTES]; /* one block at a time, decoded before the next read */

double cs_clamp(double value, double low, double high)
{
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

double cs_abs(double value) { return value < 0 ? -value : value; }

/* lint: per-frame */
static int ReadBlock(uintptr_t base, const Block* block) { return vpm_read(base + block->first, g_block, block->size); }

static double F32(const Block* block, uint32_t offset)
{
    float value;
    memcpy(&value, g_block + (offset - block->first), sizeof value);
    return (double)value;
}

static uint32_t U32(const Block* block, uint32_t offset)
{
    uint32_t value;
    memcpy(&value, g_block + (offset - block->first), sizeof value);
    return value;
}

static void ReadWidget(Widget* w, const Block* block, uint32_t bar, uint32_t thumb)
{
    w->read = 1;
    w->width = F32(block, bar + 12);
    w->height = F32(block, bar + 16);
    w->sx = F32(block, bar + 100);
    w->sy = F32(block, bar + 140);
    w->left = F32(block, bar + 148);
    w->bottom = F32(block, bar + 156);
    w->thumb = F32(block, thumb + 16);
    w->rendered_thumb = F32(block, thumb + 156);
}

static int OffScale(double number) { return number != number || cs_abs(number) > CS_MAX_PIXELS; }

/* native_geometry: the scrollbar's track and thumb. */
static int Geometry(CsModel* m, const Widget* w, const char** reason)
{
    if (!w->read) { *reason = "scrollbar geometry unreadable"; return 0; }
    if (OffScale(w->height) || OffScale(w->width) || OffScale(w->sx) || OffScale(w->sy) || OffScale(w->left) ||
        OffScale(w->bottom) || OffScale(w->thumb))
    {
        *reason = "scrollbar geometry out of range";
        return 0;
    }
    if (w->height <= 0 || w->width <= 0 || w->sx <= 0 || w->sy <= 0 || w->thumb <= 0 || w->thumb >= w->height)
    {
        *reason = "scrollbar not scrollable";
        return 0;
    }
    m->thumb_ratio = w->thumb / w->height;
    m->left = w->left;
    m->bottom = w->bottom;
    m->width = w->width * w->sx;
    m->length = w->height * w->sy;
    m->thumb = w->thumb * w->sy;
    m->rendered_thumb = w->rendered_thumb;
    return 1;
}

/* grid_refusal: the reason a grid's counts or pixel sizes do not fit this build, or NULL. columns: its block read. */
static const char* GridRefusal(const CsModel* m, int counts, int bar)
{
    if (!counts) return "grid state unreadable";
    if (m->columns < 1 || m->columns > MAX_COLUMNS) return "grid columns out of range";
    if (m->rows < 1 || m->rows > MAX_ROWS) return "grid rows out of range";
    if (m->items < 1 || m->items > MAX_ITEMS) return "grid item count out of range";
    if (m->content != m->content || m->content <= 0 || m->content > CS_MAX_PIXELS) return "grid content out of range";
    if (!bar || m->value != m->value || m->value < -0.001 || m->value > 1.001) return "grid value out of range";
    if (m->span != m->span || m->span <= 0 || m->span > CS_MAX_PIXELS) return "grid span out of range";
    return NULL;
}

static void GridTable(CsModel* m)
{
    m->rows = U32(&kGridTable, GRID_ROWS);
    m->selected = U32(&kGridTable, GRID_SELECTED);
    m->scroll = F32(&kGridTable, CS_GRID_SCROLL);
    m->content = F32(&kGridTable, GRID_CONTENT);
    m->items = U32(&kGridTable, GRID_ITEMS);
    m->kind = U32(&kGridTable, GRID_KIND);
    m->anchor = U32(&kGridTable, GRID_ANCHOR);
}

/* lint: per-frame */
static int GridState(uintptr_t grid, CsModel* m, const char** reason)
{
    Widget w = {0};
    int bar = ReadBlock(grid, &kGridBar);
    if (bar)
    {
        ReadWidget(&w, &kGridBar, CS_GRID_BAR, CS_GRID_THUMB);
        m->span = F32(&kGridBar, GRID_SPAN);
        m->value = F32(&kGridBar, GRID_VALUE);
    }
    int columns = ReadBlock(grid, &kGridColumns);
    if (columns) m->columns = U32(&kGridColumns, GRID_COLUMNS);
    int table = ReadBlock(grid, &kGridTable);
    if (table) GridTable(m);
    m->has_range = ReadBlock(grid, &kGridRange);
    if (m->has_range)
    {
        m->first = U32(&kGridRange, GRID_FIRST);
        m->last = U32(&kGridRange, GRID_LAST);
    }
    const char* refusal = GridRefusal(m, columns && table, bar);
    if (refusal != NULL) { *reason = refusal; return 0; }
    m->value = cs_clamp(m->value, 0, 1);
    m->viewport = m->content - m->span;
    if (m->viewport <= 0) { *reason = "grid not scrollable"; return 0; }
    return Geometry(m, &w, reason);
}

/* Career scrolls a container; its bar's height is the viewport. */
/* lint: per-frame */
static int CareerState(uintptr_t panel, CsModel* m, const char** reason)
{
    Widget w = {0};
    double x = 0, y = 0, height = 0, scale = 0;
    int list = ReadBlock(panel, &kCareerList);
    if (list)
    {
        x = F32(&kCareerList, CS_CAREER_LIST + 4);
        y = F32(&kCareerList, CS_CAREER_LIST + 8);
        height = F32(&kCareerList, CS_CAREER_LIST + 16);
        scale = F32(&kCareerList, CS_CAREER_LIST + 32);
    }
    if (ReadBlock(panel, &kCareerBar)) ReadWidget(&w, &kCareerBar, CS_CAREER_TRACK, CS_CAREER_THUMB);
    if (!list || !w.read) { *reason = "career unreadable"; return 0; }
    double content = height * scale, span = height * scale - w.height;
    if (content != content || content > CS_MAX_PIXELS || span != span || span <= 0 || y != y || cs_abs(y) > CS_MAX_PIXELS ||
        x != x)
    {
        *reason = "career out of range";
        return 0;
    }
    m->content = content;
    m->span = span;
    m->viewport = w.height;
    m->scroll = y + CS_CAREER_PADDING;
    m->list_x = x;
    m->value = cs_clamp((y + CS_CAREER_PADDING) / span, 0, 1);
    return Geometry(m, &w, reason);
}

static int OptionsRefused(double span, double value, double scroll, double viewport)
{
    return span != span || value != value || scroll != scroll || span <= 0 || span > CS_MAX_PIXELS || value < -0.001 ||
           value > 1.001 || viewport <= 0 || viewport > CS_MAX_PIXELS || scroll < -1 || scroll > span + 1;
}

/* lint: per-frame */
static int OptionsState(uintptr_t list, CsModel* m, const char** reason)
{
    Widget w = {0};
    if (!ReadBlock(list, &kOptions)) { *reason = "bindings list out of range"; return 0; }
    ReadWidget(&w, &kOptions, CS_OPTIONS_BAR, CS_OPTIONS_THUMB);
    double span = F32(&kOptions, OPTIONS_SPAN), value = F32(&kOptions, OPTIONS_VALUE);
    double scroll = F32(&kOptions, OPTIONS_SCROLL), viewport = w.height;
    if (OptionsRefused(span, value, scroll, viewport)) { *reason = "bindings list out of range"; return 0; }
    m->content = span + viewport;
    m->span = span;
    m->viewport = viewport;
    m->value = cs_clamp(value, 0, 1);
    m->scroll = scroll;
    return Geometry(m, &w, reason);
}

/* lint: per-frame */
int cs_state(const CsBridge* bridge, CsModel* out, const char** reason)
{
    memset(out, 0, sizeof *out);
    out->route = bridge->route;
    if (bridge->route == CS_ROUTE_CAREER) return CareerState(bridge->panel, out, reason);
    if (bridge->route == CS_ROUTE_BINDINGS || bridge->route == CS_ROUTE_SETTINGS) return OptionsState(bridge->grid, out, reason);
    return GridState(bridge->grid, out, reason);
}

/* The game's bottom-left origin to desktop pointer coordinates. */
void cs_screen_track(const CsModel* model, double x, double y, double height, CsTrack* out)
{
    out->left = x + model->left;
    out->right = x + model->left + model->width;
    out->top = y + height - model->bottom - model->length;
    out->length = model->length;
    out->thumb = model->thumb;
    out->span = model->length - model->thumb;
}

int cs_value_at_grab(const CsModel* model, const CsTrack* track, double press_y, double cursor_y, double* out)
{
    if (track->span <= 0) return 0;
    double value = model->value + (cursor_y - press_y) / track->span;
    if (value != value) return 0;
    *out = cs_clamp(value, 0, 1);
    return 1;
}

/* Only fields the game derives count: the value and the pixel offset are what this component writes, so reading them
 * back would take a write for a success. The options route never writes its content offset directly, so that moving is
 * the game's position setter answering. */
int cs_moved(const CsModel* before, const CsModel* after)
{
    if (before->route == CS_ROUTE_BINDINGS || before->route == CS_ROUTE_SETTINGS)
        return after->route == before->route && cs_abs(before->scroll - after->scroll) > 0.1;
    if (before->has_range && after->has_range && (after->first != before->first || after->last != before->last)) return 1;
    if (before->route == CS_ROUTE_GRID && after->route == CS_ROUTE_GRID && after->anchor != before->anchor) return 1;
    return cs_abs(before->rendered_thumb - after->rendered_thumb) > 0.1;
}
