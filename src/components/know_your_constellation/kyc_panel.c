/* Know Your Constellation's forecast panel (panel.lua): one screen GUI in the first non-main world (the only UI world
 * drawn on the war table), inked like the native normal font, with retained primitives: nothing is measured or drawn
 * again unless the report, the geometry or the font changes, except one text update per frame while a long headline
 * scrolls. Each show while it is up checks the world list and the window size again (a replaced or removed world
 * moves or hides the panel then). Drawn through kyc_gui.h: on HellForge the pack's Lua part (kyc_lua.c),
 * which calls show only on frames with a change, a scroll or a periodic check; with no route (kyc_gui.c) it draws
 * nothing and says so. Plans are cached per report, width, height limit, scale and mode (8 entries), as in the Lua. */
#include <math.h>
#include <string.h>
#include "kyc_panel.h"

#define MAX_WORLDS 64
#define MAX_RECTS 512
#define MAX_TEXTS 256
#define SLOTS 8
#define MEASURED 1024

/* The font material's slots the native normal-font setup sets (IdString64 of hash .. '00000000'). */
static const uint64_t kScalarSlots[4] = {0x8035C26600000000ull, 0x5E8455FE00000000ull, 0x309E778300000000ull,
    0x82B803A800000000ull};
#define RANGE_SLOT 0xE13777CE00000000ull
#define SHADOW_SLOT 0x7701209E00000000ull
#define ATLAS_SLOT 0x88BAC99B00000000ull

typedef struct Slot { int used, fits, cut; uint64_t signature, font; double width, limit, s; KycPlan plan; } Slot;
typedef struct Measured { uint32_t generation, length; uint64_t hash; double size, width; } Measured;

static struct
{
    KycRef gui, world;
    int inked;                 /* the GUI's font, material and atlas are set */
    uint64_t font, material, atlas;
    int has_model, has_signature, has_geometry, has_scroll;
    KycModel model;
    uint64_t signature;
    double ax, ay, aw, ah, as, rw, rh;
    KycPlace place;
    KycScroll scroll;
    int rects, texts;
    KycRef rect_ids[MAX_RECTS], text_ids[MAX_TEXTS];
    int empty;                 /* cleared until the next show: clearing again changes nothing */
    int order[SLOTS], orders;  /* the cache's slots, oldest first */
    uint32_t generation;       /* of the measurements below */
    KycPanelView view;
} p;

static Slot g_slots[SLOTS];
static KycPlan g_drawn;        /* the plan drawn now (a cache slot may be reused while it stays up) */
static KycModel g_pending;
static Measured g_measured[MEASURED];

void kyc_panel_reset(void)
{
    memset(&p, 0, sizeof p);
    memset(g_slots, 0, sizeof g_slots);
}

/* ---- the GUI ------------------------------------------------------------------------------------------------- */

static int Listed(const KycRef* list, int count, KycRef world)
{
    for (int i = 0; i < count; i++)
        if (list[i] == world) return 1;
    return 0;
}

/* Drops the GUI, destroying it only while its world is still listed (list: this frame's world list, or NULL to read
 * it). */
static int Destroy(const KycRef* list, int count)
{
    const KycGui* g = kyc_gui();
    KycRef worlds[MAX_WORLDS];
    if (p.gui != 0)
    {
        if (list == NULL)
        {
            count = g->worlds(worlds, MAX_WORLDS);
            if (count < 0) return kyc_pending("UI worlds unavailable");
            list = worlds;
        }
        if (Listed(list, count, p.world)) g->destroy_gui(p.world, p.gui);
    }
    p.gui = p.world = 0;
    p.inked = p.has_scroll = p.has_signature = 0;
    p.rects = p.texts = 0;
    return 1;
}

static int Clear(const KycRef* list, int count)
{
    if (!Destroy(list, count)) return 0;
    p.has_model = p.has_geometry = 0;
    memset(g_slots, 0, sizeof g_slots);
    p.orders = 0;
    p.empty = 1;
    return 1;
}

int kyc_panel_clear(void) { return p.empty ? 1 : Clear(NULL, 0); }

/* The native normal-font setup, mirrored on the GUI's material. */
static int Ink(const KycGui* g, const KycAnchor* anchor)
{
    KycRef material = g->material(p.gui, anchor->material);
    if (material == 0) return kyc_pending("Font material unavailable");
    for (int i = 0; i < 4; i++) g->set_scalar(material, kScalarSlots[i], 0);
    g->set_vector2(material, RANGE_SLOT, 1, -1);
    g->set_vector4(material, SHADOW_SLOT, (KycColour){0, 0, 0, 0});
    g->set_texture(material, ATLAS_SLOT, anchor->atlas);
    return 1;
}

/* The GUI is up with the anchor's font, material and atlas. */
static int Inked(const KycAnchor* a)
{
    return p.gui != 0 && p.inked && p.font == a->font && p.material == a->material && p.atlas == a->atlas;
}

/* A new GUI in the target world, inked like the native normal font. */
static int Create(const KycGui* g, const KycRef* list, int count, KycRef target, const KycAnchor* anchor)
{
    if (!Destroy(list, count)) return 0;
    p.gui = g->create_screen_gui(target);
    if (p.gui == 0) return kyc_pending("Could not create forecast panel");
    p.world = target;
    p.empty = 0; /* a world change cleared the panel above: the GUI made now is up, so a later clear removes it */
    if (!Ink(g, anchor)) return 0;
    p.inked = 1;
    p.font = anchor->font;
    p.material = anchor->material;
    p.atlas = anchor->atlas;
    return 1;
}

/* The UI world to draw in (the first non-main one), the GUI created there with the anchor's font: 1 with *ready, or
 * 0 after an error. */
static int Prepare(const KycGui* g, const KycAnchor* anchor, int* ready)
{
    KycRef list[MAX_WORLDS], target = 0;
    *ready = 0;
    KycRef main = g->main_world();
    int count = g->worlds(list, MAX_WORLDS);
    if (count < 0) return kyc_pending("UI worlds unavailable");
    for (int i = 0; i < count && target == 0; i++)
        if (list[i] != main) target = list[i];
    if (target == 0) return Clear(list, count);
    if (p.world != 0 && p.world != target && !Clear(list, count)) return 0;
    if (!Inked(anchor) && !Create(g, list, count, target, anchor)) return 0;
    *ready = 1;
    return 1;
}

/* ---- measuring ------------------------------------------------------------------------------------------------ */

static uint64_t Hash(const char* text, size_t length, double size)
{
    uint64_t h = 0xCBF29CE484222325ull, bits;
    memcpy(&bits, &size, 8);
    for (size_t i = 0; i < length; i++) h = (h ^ (uint8_t)text[i]) * 0x100000001B3ull;
    return (h ^ bits) * 0x100000001B3ull;
}

/* The drawn width of text at size (Gui.text_extents), remembered while one plan is made. */
static int EngineMeasure(void* context, const char* text, size_t length, double size, double* width)
{
    const KycGui* g = kyc_gui();
    uint64_t h = Hash(text, length, size);
    Measured* m = &g_measured[h & (MEASURED - 1)];
    for (int probe = 0; probe < 8 && m->generation == p.generation; probe++)
    {
        if (m->hash == h && m->length == length && m->size == size) { *width = m->width; return 1; }
        m = &g_measured[(h + (uint64_t)probe + 1) & (MEASURED - 1)];
    }
    double out[3] = {0, 0, 0};
    int got = g->text_extents(p.gui, text, length, p.font, size, out);
    if ((got & 7) != 7) return kyc_pending("Font metrics unavailable");
    *width = (out[1] > out[2] ? out[1] : out[2]) - (out[0] < 0 ? out[0] : 0);
    if (m->generation != p.generation) *m = (Measured){p.generation, (uint32_t)length, h, size, *width};
    return 1;
}

/* The plan for a report at a width, height limit, scale and mode: from the cache, or made and cached. *plan NULL when
 * it does not fit. */
static int Planned(const KycModel* model, double width, double limit, double s, int cut, KycPlan** plan)
{
    *plan = NULL;
    for (int i = 0; i < SLOTS; i++)
    {
        Slot* slot = &g_slots[i];
        if (slot->used && slot->signature == model->signature && slot->font == p.font && slot->width == width &&
            slot->limit == limit && slot->s == s && slot->cut == cut)
        {
            *plan = slot->fits ? &slot->plan : NULL;
            return 1;
        }
    }
    int index = 0;
    if (p.orders == SLOTS)
    {
        index = p.order[0];
        memmove(p.order, p.order + 1, sizeof p.order[0] * (SLOTS - 1));
        p.orders--;
    }
    else
        while (g_slots[index].used) index++;
    Slot* slot = &g_slots[index];
    slot->used = 0;
    p.generation++;
    KycPlanArgs args = {model, EngineMeasure, NULL, width, limit, s};
    if (!kyc_fit(&args, cut, &slot->plan, &slot->fits)) return 0;
    slot->used = 1;
    slot->cut = cut;
    slot->signature = model->signature;
    slot->font = p.font;
    slot->width = width;
    slot->limit = limit;
    slot->s = s;
    p.order[p.orders++] = index;
    *plan = slot->fits ? &slot->plan : NULL;
    return 1;
}

/* ---- drawing ---------------------------------------------------------------------------------------------------- */

typedef struct Drawer { const KycGui* g; int rects, texts; uint64_t font, material; } Drawer;

static int Rect(Drawer* w, double x, double y, double width, double height, double z, KycColour fill)
{
    KycBox box = {x, y, z, width, height};
    if (w->rects < p.rects) { w->g->update_rect(p.gui, p.rect_ids[w->rects++], &box, fill); return 1; }
    if (w->rects >= MAX_RECTS) return kyc_fail("Forecast has too many rectangles");
    KycRef id = w->g->rect(p.gui, &box, fill);
    if (id == 0) return kyc_pending("Retained rectangle unavailable");
    p.rect_ids[w->rects++] = id;
    p.rects = w->rects;
    return 1;
}

/* A text of the panel's font at a place on the content layer. */
static KycLabel Text(const Drawer* w, const char* text, size_t length, double size, double x, double y, KycColour fill)
{
    KycLabel label = {text, length, w->font, w->material, size, x, y, KYC_LAYER_CONTENT, fill};
    return label;
}

static int Label(Drawer* w, const KycLabel* label, KycRef* id)
{
    size_t bad;
    const char* why;
    if (!kyc_text_check(label->text, label->length, &bad, &why))
        return kyc_fail("Unsupported display text: %s at byte %u", why, (unsigned)bad);
    if (w->texts < p.texts)
    {
        *id = p.text_ids[w->texts++];
        w->g->update_text(p.gui, *id, label);
        return 1;
    }
    if (w->texts >= MAX_TEXTS) return kyc_fail("Forecast has too many texts");
    *id = w->g->text(p.gui, label);
    if (*id == 0) return kyc_pending("Retained text unavailable");
    p.text_ids[w->texts++] = *id;
    p.texts = w->texts;
    return 1;
}

/* The frame: a shade, the body 7 units in, and the 3-unit gold outline. */
static int Frame(Drawer* w, const KycPlace* place, double s)
{
    double x = place->x, y = place->y, wd = place->w, h = place->h, b = KYC_BORDER * s, i = KYC_INSET * s;
    return Rect(w, x, y, wd, h, KYC_LAYER_SHADE, kKycShade) &&
        Rect(w, x + i, y + i, wd - 2 * i, h - 2 * i, KYC_LAYER_BODY, kKycBody) &&
        Rect(w, x, y + h - b, wd, b, KYC_LAYER_BORDER, kKycGold) && Rect(w, x, y, wd, b, KYC_LAYER_BORDER, kKycGold) &&
        Rect(w, x, y, b, h, KYC_LAYER_BORDER, kKycGold) && Rect(w, x + wd - b, y, b, h, KYC_LAYER_BORDER, kKycGold);
}

/* Whole-pixel ticks: every tick and gap renders the same width. */
static int Meter(Drawer* w, const KycItem* item, double cx, double top, double s)
{
    double tick, gap;
    kyc_tick_pixels(s, &tick, &gap);
    double left = floor(cx + item->x + 0.5), bottom = floor(top - item->d + 0.5), tall = floor(item->h + 0.5);
    if (tall < 1) tall = 1;
    for (int t = 1; t <= KYC_TICKS; t++)
        if (!Rect(w, left + (t - 1) * (tick + gap), bottom, tick, tall, KYC_LAYER_CONTENT, t <= item->ticks ? kKycBodyInk : kKycSlate))
            return 0;
    return 1;
}

/* Moves a scroll state to its time: 1 with the visible bytes and their x, 0 when nothing moved. */
static int Advance(KycScroll* m, size_t* at, size_t* length, double* x)
{
    double period, offset = kyc_scroll_offset(m->time, m->travel, m->scale, &period);
    if (m->time >= period) m->time -= period;
    if (m->has_offset && offset == m->offset) return 0;
    if (!m->has_offset || offset < m->offset) m->first = m->last = 0;
    m->has_offset = 1;
    m->offset = offset;
    kyc_scroll_window(m->edge, m->count, offset, m->width, m->margin, &m->first, &m->last);
    *at = m->bound[m->first - 1];
    *length = (size_t)(m->bound[m->last - 1] - m->bound[m->first - 1]);
    *x = m->x + m->edge[m->first] - offset;
    return 1;
}

/* The scrolling headline's character starts and carets, once per plan (one measurement per character). */
static int Carets(Drawer* w, KycPlan* plan, const KycItem* item)
{
    const char* text = plan->text + item->at;
    if (plan->bounds == 0)
    {
        int n = kyc_text_boundaries(text, item->length, plan->bound, KYC_MAX_BOUNDS);
        if (n < 0) return kyc_fail("Headline too long");
        plan->bounds = n;
    }
    if (plan->edges_ready) return 1;
    plan->edge[1] = 0;
    for (int k = 2; k <= plan->bounds; k++)
    {
        double out[3] = {0, 0, 0};
        if (!(w->g->text_extents(p.gui, text, plan->bound[k - 1], w->font, item->size, out) & KYC_EXTENT_CARET))
            return kyc_pending("Font caret unavailable");
        plan->edge[k] = out[2] > plan->edge[k - 1] ? out[2] : plan->edge[k - 1];
    }
    plan->edges_ready = 1;
    return 1;
}

typedef struct Column { double x, i, w, cx, cw, top, s; } Column;

/* A headline wider than the column: its window of characters, with panel-coloured masks over the side padding. The
 * same headline keeps its place in the cycle when the panel moves. */
static int Scroll(Drawer* w, KycPlan* plan, const KycItem* item, const Column* c, const KycScroll* previous)
{
    if (!Carets(w, plan, item)) return 0;
    const char* text = plan->text + item->at;
    int same = previous != NULL && previous->bound[previous->count] == item->length &&
        memcmp(previous->text, text, item->length) == 0 && previous->size == item->size;
    KycScroll m = {text, plan->bound, plan->edge, plan->bounds - 1, item->size, c->cx, c->top - item->d, c->cw,
        (KYC_PAD - KYC_INSET) * c->s, item->travel, c->s, same ? previous->time : 0, 0, 0, 0, 0, 0};
    size_t at, length;
    double x;
    (void)Advance(&m, &at, &length, &x); /* a fresh state always has a window */
    KycLabel label = Text(w, text + at, length, item->size, x, m.y, kKycBodyInk);
    if (!Label(w, &label, &m.id)) return 0;
    double line_y = m.y - item->size * 0.35, line_h = item->size * 1.5;
    if (!Rect(w, c->x + c->i, line_y, c->cx - (c->x + c->i), line_h, KYC_LAYER_MASK, kKycBody) ||
        !Rect(w, c->cx + c->cw, line_y, (c->x + c->w - c->i) - (c->cx + c->cw), line_h, KYC_LAYER_MASK, kKycBody))
        return 0;
    p.scroll = m;
    p.has_scroll = 1;
    return 1;
}

static int Item(Drawer* w, KycPlan* plan, const KycItem* item, const Column* c, const KycScroll* previous)
{
    static const KycColour* const kInk[3] = {&kKycLabelInk, &kKycBodyInk, &kKycMutedInk};
    KycRef id;
    KycLabel label;
    switch (item->kind)
    {
    case KYC_ITEM_TEXT:
        label = Text(w, plan->text + item->at, item->length, item->size, c->cx + item->x, c->top - item->d, *kInk[item->role]);
        return Label(w, &label, &id);
    case KYC_ITEM_SCROLL: return Scroll(w, plan, item, c, previous);
    case KYC_ITEM_RULE: return Rect(w, c->cx, c->top - item->d, c->cw, item->h, KYC_LAYER_RULE, kKycSlate);
    default: return Meter(w, item, c->cx, c->top, c->s);
    }
}

static int Draw(const KycGui* g, KycPlan* plan, const KycPlace* place, const KycAnchor* anchor)
{
    static KycScroll previous;
    double s = anchor->scale;
    Drawer w = {g, 0, 0, anchor->font, anchor->material};
    int had_scroll = p.has_scroll;
    previous = p.scroll;
    p.has_scroll = 0;
    if (!Frame(&w, place, s)) return 0;
    Column c = {place->x, KYC_INSET * s, place->w, place->x + KYC_PAD * s, place->w - 2 * KYC_PAD * s,
        place->y + place->h - (KYC_BORDER + KYC_INSET + KYC_EDGE) * s, s};
    for (int i = 0; i < plan->count; i++)
        if (!Item(&w, plan, &plan->items[i], &c, had_scroll ? &previous : NULL)) return 0;
    /* Clear the primitives a longer report used. */
    KycBox none = {0, 0, 0, 0, 0};
    for (int i = w.rects; i < p.rects; i++) g->update_rect(p.gui, p.rect_ids[i], &none, kKycBody);
    KycLabel empty = {"", 0, anchor->font, anchor->material, KYC_CAPTION * s, 0, 0, 0, kKycBody};
    for (int i = w.texts; i < p.texts; i++) g->update_text(p.gui, p.text_ids[i], &empty);
    return 1;
}

/* One frame of a scrolling headline: no GUI call while it holds still. lint: per-frame */
static void ScrollFrame(const KycGui* g, double dt)
{
    KycScroll* m = &p.scroll;
    m->time += dt < 0 ? 0 : dt > 0.1 ? 0.1 : dt;
    size_t at, length;
    double x;
    if (!Advance(m, &at, &length, &x)) return;
    KycLabel label = {m->text + at, length, p.font, p.material, m->size, x, m->y, KYC_LAYER_CONTENT, kKycBodyInk};
    g->update_text(p.gui, m->id, &label);
}

/* Keeps the drawn plan (and points the scroll state at it). */
static void KeepPlan(const KycPlan* plan)
{
    size_t text = p.has_scroll ? (size_t)(p.scroll.text - plan->text) : 0;
    memcpy(&g_drawn, plan, sizeof g_drawn);
    if (!p.has_scroll) return;
    p.scroll.text = g_drawn.text + text;
    p.scroll.bound = g_drawn.bound;
    p.scroll.edge = g_drawn.edge;
}

static int SameGeometry(const KycModel* model, const KycAnchor* a, double width, double height)
{
    return p.has_geometry && p.has_signature && model->signature == p.signature && a->x == p.ax && a->y == p.ay &&
        a->w == p.aw && a->h == p.ah && a->scale == p.as && width == p.rw && height == p.rh;
}

/* Lays the report out below the native panel, or beside it, and draws it. */
static int Layout(const KycGui* g, const KycModel* model, const KycAnchor* anchor, double width, double height)
{
    double s = anchor->scale, content = anchor->w - 2 * KYC_PAD * s;
    KycPlan *below, *side = NULL;
    KycPlace place;
    if (!Planned(model, content, kyc_below_limit(anchor), s, 0, &below)) return 0;
    if (below == NULL && !Planned(model, content, kyc_side_limit(anchor, height), s, 1, &side)) return 0;
    if (!kyc_place(anchor, width, height, below, side, &place)) return 0;
    KycPlan* plan = below != NULL ? below : side;
    if (!Draw(g, plan, &place, anchor)) return 0;
    KeepPlan(plan);
    if (model != &p.model) memcpy(&p.model, model, sizeof p.model);
    p.has_model = p.has_signature = p.has_geometry = 1;
    p.signature = model->signature;
    p.ax = anchor->x;
    p.ay = anchor->y;
    p.aw = anchor->w;
    p.ah = anchor->h;
    p.as = anchor->scale;
    p.rw = width;
    p.rh = height;
    p.place = place;
    return 1;
}

/* lint: per-frame */
int kyc_panel_show(const KycModel* model, double dt, const KycAnchor* anchor)
{
    const KycGui* g = kyc_gui();
    int ready;
    double width, height;
    p.empty = 0;
    if (g->unavailable() != NULL) return 0;
    if (!Prepare(g, anchor, &ready)) return KYC_ERROR;
    if (!ready) return 0;
    if (!g->resolution(&width, &height))
    {
        (void)kyc_fail("The window size is unavailable");
        return KYC_ERROR;
    }
    /* Unchanged report, geometry and font: only a long headline moves. */
    if (SameGeometry(model, anchor, width, height))
    {
        if (p.has_scroll) ScrollFrame(g, dt);
        return 1;
    }
    if (!(width >= 640 && height >= 480 && anchor->scale > 0))
    {
        (void)kyc_pending("Native panel unavailable");
        return KYC_ERROR;
    }
    return Layout(g, model, anchor, width, height) ? 1 : KYC_ERROR;
}

/* Pending reports keep the panel and its captions without enemy text. lint: per-frame */
int kyc_panel_suspend(const KycAnchor* anchor)
{
    if (p.gui == 0 || !p.has_model) return 0;
    if (!p.model.pending)
    {
        kyc_model_pending(&p.model, &g_pending);
        return kyc_panel_show(&g_pending, 0, anchor);
    }
    return kyc_panel_show(&p.model, 0, anchor);
}

const KycPanelView* kyc_panel_view(void)
{
    KycPanelView* v = &p.view;
    v->gui = p.gui;
    v->world = p.world;
    v->has_model = p.has_model;
    v->model = &p.model;
    v->has_geometry = p.has_geometry;
    v->place = p.place;
    v->plan = &g_drawn;
    v->has_scroll = p.has_scroll;
    v->scroll = &p.scroll;
    v->rects = p.rects;
    v->texts = p.texts;
    v->rect_ids = p.rect_ids;
    v->text_ids = p.text_ids;
    return v;
}
