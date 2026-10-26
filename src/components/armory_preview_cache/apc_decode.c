/* Armory Preview Cache: the image snapshot (image_native.lua decode, v23.1), build 25480438.
 *
 * Decodes the screen shown from the state view's buffers (apc_state.c) instead of a read per field: the thumbnail
 * manager's six cards of up to 15 requests, the grid's records and widgets (or the weapon/cosmetic pre-select, or the
 * briefing loadout), the request keys the crops are cached under and the handoff boundaries the image cache may use.
 * It checks the same fields as the Lua; a buffer whose refresh read failed is read again at the size the ungated
 * snapshot read, so a failure raises the same error at the same point. Grid widgets are read per tile (one 2008-byte
 * read each, two when that fails), and the registry's hidden consumers when a handoff could be accepted.
 *
 * Request keys. A key is the layout (manager +16..+32, +11100, descriptor +8..+36), a screen variant (grid kind, record
 * visual and style; "preselect" + mode; "briefing_loadout" + slot) and the request's stable identity (+24..+40,
 * +48..+56, +64..+72, +88..+104): not the camera fields the generator rewrites (+8, +84). */
#include "apc.h"

#define PREVIEWS 1024
typedef struct Preview { uint64_t id; uint8_t size; uint8_t slots[APC_PREVIEW_MAX]; } Preview;
static Preview g_previews[PREVIEWS];
static int g_previewCount;
APC_MAP(g_previewIndex, 2048);

/* Native state 8 describes a request, not pixels in a newly allocated replacement: completed card regions a handoff
 * left blank in the working atlas. */
static struct
{
    int present;
    uintptr_t atlas, context, manager;
    uint64_t id;
    int card[6];
    uint16_t stamp_size[6];
    uint8_t stamp[6][APC_STAMP_MAX];
} g_blank;

static uint32_t g_widget[2008 / 4];  /* one widget's fields (+0..+704, +1984..+2008) */
static uint32_t g_element[22];       /* a registry consumer's first 88 bytes */

static const uint8_t kBriefingKinds[6] = {2, 3, 4, 0, 0, 1};

void apc_decode_reset(void)
{
    memset(&g_blank, 0, sizeof g_blank);
    g_previewCount = 0;
    apc_map_clear(&g_previewIndex);
}

const uint8_t* apc_preview_slots(int16_t preview, uint8_t* size)
{
    if (preview < 0 || preview >= g_previewCount) return NULL;
    *size = g_previews[preview].size;
    return g_previews[preview].slots;
}

void apc_blank_clear(void) { g_blank.present = 0; }

void apc_blank_set(const ApcImageSnap* s, uintptr_t fresh, uint64_t id)
{
    memset(&g_blank, 0, sizeof g_blank);
    g_blank.present = 1;
    g_blank.atlas = fresh;
    g_blank.id = id;
    g_blank.context = s->context;
    g_blank.manager = s->manager;
    for (int c = 0; c < 6; c++)
    {
        const ApcCardSource* source = &s->source[c];
        if (!source->present || source->state != 8) continue;
        g_blank.card[c] = 1;
        g_blank.stamp_size[c] = source->stamp_size;
        memcpy(g_blank.stamp[c], source->stamp, source->stamp_size);
    }
}

void apc_key_hash(ApcKey* key)
{
    uint64_t h = 14695981039346656037ull;
    for (size_t i = 0; i < key->size; i++) h = (h ^ key->bytes[i]) * 1099511628211ull;
    key->hash = h;
}

int apc_key_equal(const ApcKey* a, const ApcKey* b)
{
    return a->hash == b->hash && a->size == b->size && memcmp(a->bytes, b->bytes, a->size) == 0;
}

/* Grid request identity, not the working camera pose: layout, variant, then the request's stable fields. */
static void MakeKey(ApcKey* key, const uint8_t* layout, const uint8_t* input, const uint8_t* variant, size_t variantSize)
{
    size_t at = 0;
    if (layout != NULL) { memcpy(key->bytes, layout, APC_LAYOUT); at = APC_LAYOUT; }
    memcpy(key->bytes + at, variant, variantSize);
    at += variantSize;
    memcpy(key->bytes + at, input + 24, 16);
    memcpy(key->bytes + at + 16, input + 48, 8);
    memcpy(key->bytes + at + 24, input + 64, 8);
    memcpy(key->bytes + at + 32, input + 88, 16);
    key->size = (uint16_t)(at + 48);
    apc_key_hash(key);
}

/* The configured weapon slots in the native preview queue, by request identity: a weapon's pattern and attachments live
 * there, not in the thumbnail request, so this is the only appearance signal. The queue holds work only while a preview
 * generates, so the last observation per identity is kept for the session (at most PREVIEWS identities; the Lua's table
 * had no bound). Errors are ignored, as the Lua's pcall did: a transient queue read never fails the snapshot. */
static void RecordPreview(uint64_t id, const uint8_t* slots, uint8_t size)
{
    uint64_t index;
    if (!apc_map_get(&g_previewIndex, id, &index))
    {
        if (g_previewCount >= PREVIEWS || !apc_map_put(&g_previewIndex, id, (uint64_t)g_previewCount)) return;
        index = (uint64_t)g_previewCount++;
    }
    g_previews[index].id = id;
    g_previews[index].size = size;
    memcpy(g_previews[index].slots, slots, size);
}

static void ObservePreviews(ApcState* st)
{
    uintptr_t preview = ApcWordPointer(st->G, 56);
    if (!preview) return;
    if (!st->qh_ok && !apc_read(preview + 50448, st->QH, 8)) return;
    uint32_t head = st->QH[0], tail = st->QH[1];
    if (head >= 128 || tail >= 128) return;
    const uint8_t* rows = (const uint8_t*)st->QROWS;
    for (uint32_t index = head, jobs = 0; index != tail && jobs < 16; index = (index + 1) & 127u, jobs++)
    {
        if (!st->qrows_ok && !apc_read(preview + 50456 + index * 200u, (uint8_t*)st->QROWS + jobs * 200u, 200)) return;
        uint32_t count = ApcU32(rows, jobs * 200u + 80);
        if (count > 10) return;
        RecordPreview(ApcU64(rows, jobs * 200u + 64), rows + jobs * 200u + 88, (uint8_t)(count * 8));
    }
}

static int16_t PreviewOf(uint64_t id)
{
    uint64_t index;
    return apc_map_get(&g_previewIndex, id, &index) ? (int16_t)index : (int16_t)-1;
}

/* The dispatch rows, read at the ungated size when the refresh's read failed. */
static int Rows(ApcState* st, uintptr_t d)
{
    if (st->rows_ok) return 1;
    if (!apc_need(d + 5740, st->DROWS, 4, "Image memory unavailable")) return 0;
    if (st->DROWS[0] > 64) return apc_fail("Image dispatch bounds");
    return st->DROWS[0] == 0 || apc_need(d + 5744, (uint8_t*)st->DROWS + 4, st->DROWS[0] * 16u, "Image memory unavailable");
}

/* The screen's owner from the state's dispatch rows. */
static int OwnerOf(ApcState* st, uint32_t kind, uintptr_t* owner)
{
    *owner = 0;
    if (!st->dptr_ok && !vpm_game_read(APC_RVA_DISPATCH, st->DPTR, 8)) return apc_fail("Image memory unavailable");
    uintptr_t d = ApcWordPointer(st->DPTR, 0);
    if (!d) return 1;
    if (!Rows(st, d)) return 0;
    uint32_t n = st->DROWS[0];
    if (n > 64) return apc_fail("Image dispatch bounds");
    for (uint32_t i = 0; i < n; i++)
    {
        if (st->DROWS[i * 4 + 3] != kind) continue;
        if (*owner) return apc_fail("Ambiguous image controller");
        *owner = ApcWordPointer(st->DROWS, 1 + i * 4);
    }
    return 1;
}

static int Descriptor(ApcState* st, uintptr_t atlas, ApcImageSnap* r)
{
    if (!st->desc_ok && !apc_need(atlas, st->DESC, 104, "Image memory unavailable")) return 0;
    const uint32_t* d = st->DESC;
    if (d[2] != 0 || d[3] != 0 || d[7] != 1 || d[8] != 1 || ((const uint8_t*)d)[99] != 1)
        return apc_fail("Unsupported thumbnail texture descriptor");
    uint32_t w = d[5], h = d[6];
    if (w < 64 || h < 64 || w > 4096 || h > 16384) return apc_fail("Thumbnail dimensions exceed bounds");
    r->atlas = atlas;
    r->width = w;
    r->height = h;
    r->bytes = (uint64_t)w * h * 4;
    r->descriptor_id = ApcU64(d, 0);
    memcpy(r->layout, (const uint8_t*)st->MB + 16, 16);
    memcpy(r->layout + 16, (const uint8_t*)st->MB + 11100, 8);
    memcpy(r->layout + 24, (const uint8_t*)d + 8, 28);
    return 1;
}

/* One card: its stamp (count, then per request its identity and rectangle) and its requests of kinds 0..4. */
static void Card(const ApcState* st, ApcImageSnap* r, uint32_t c, uint32_t state, uint32_t n)
{
    const uint8_t* m = (const uint8_t*)st->MB;
    ApcCardSource* source = &r->source[c];
    source->present = 1;
    source->state = state;
    source->stamp[0] = (uint8_t)n;
    size_t at = 1;
    for (uint32_t i = 0; i < n; i++)
    {
        const uint8_t* input = m + c * 1816 + 32 + i * 120;
        ApcKey identity;
        MakeKey(&identity, NULL, input, NULL, 0);
        memcpy(source->stamp + at, identity.bytes, 48);
        memcpy(source->stamp + at + 48, input + 56, 16);
        at += 64;
        if (ApcU32(input, 100) > 4) continue;
        ApcItem* item = &r->slots[c * 15 + i];
        item->present = 1;
        memcpy(item->input, input, 104);
        item->card = (uint8_t)c;
        item->index = (uint8_t)i;
        item->ready = state == 8;
        item->preview = PreviewOf(ApcU64(input, 24));
    }
    source->stamp_size = (uint16_t)at;
}

static int BlankStill(const ApcCardSource* source, uint32_t c)
{
    return source->present && source->state == 8 && source->stamp_size == g_blank.stamp_size[c] &&
        memcmp(source->stamp, g_blank.stamp[c], source->stamp_size) == 0;
}

/* The blank cards: none once the replacement atlas is another atlas, generation, context or manager. */
static void BlankAtlas(const ApcImageSnap* r)
{
    if (g_blank.present && (g_blank.atlas != r->atlas || g_blank.id != r->descriptor_id || g_blank.context != r->context ||
        g_blank.manager != r->manager))
        g_blank.present = 0;
}

/* A card stays blank while it holds the same completed requests. */
static void BlankCard(ApcImageSnap* r, uint32_t c)
{
    if (!g_blank.present || !g_blank.card[c]) return;
    if (BlankStill(&r->source[c], c)) r->blank_cards++;
    else g_blank.card[c] = 0;
}

static void PixelsReady(ApcImageSnap* r)
{
    for (int i = 0; i < APC_ITEMS; i++)
    {
        ApcItem* item = &r->slots[i];
        if (item->present) item->pixels_ready = item->ready && !(g_blank.present && g_blank.card[item->card]);
    }
}

/* The cards' states, items and stamps; the blank cards a handoff left; completion and freeze. */
static int Cards(const ApcState* st, ApcImageSnap* r, int* nonemptyCards)
{
    const uint32_t* m = st->MB;
    BlankAtlas(r);
    uint32_t active = m[2766], phase = m[2774];
    int allComplete = 1, safe = 1, nonempty = 0;
    for (uint32_t c = 0; c < 6; c++)
    {
        uint32_t state = m[c * 454 + 458], n = m[c * 454 + 459];
        if (state > 8 || n > 15) return apc_fail("Image card bounds");
        if (state != 0)
        {
            r->expected_count += n;
            nonempty++;
            allComplete &= state == 8;
            safe &= state == 3 || state == 4 || state == 5;
            Card(st, r, c, state, n);
        }
        BlankCard(r, c);
    }
    PixelsReady(r);
    r->complete = nonempty > 0 && allComplete && active == 0xFFFFFFFFu;
    r->can_freeze = nonempty > 0 && safe && active < 6 && (phase == 4 || phase == 5);
    *nonemptyCards = nonempty;
    return 1;
}

/* Nothing is composing into the working atlas: every nonempty card is queued/preparing (3/4/5) or complete (8), and the
 * single active card, if any, is still preparing. States 6/7 finalize into the atlas. */
static int Quiescent(const ApcState* st, const ApcImageSnap* r, int nonempty)
{
    uint32_t active = st->MB[2766], phase = st->MB[2774];
    int quiet = nonempty > 0;
    for (int c = 0; c < 6; c++)
    {
        uint32_t state = r->source[c].state;
        if (r->source[c].present && state != 3 && state != 4 && state != 5 && state != 8) quiet = 0;
    }
    if (active == 0xFFFFFFFFu) return quiet;
    const ApcCardSource* source = active < 6 && r->source[active].present ? &r->source[active] : NULL;
    if (source == NULL || source->state < 3 || source->state > 5 || (phase != 4 && phase != 5)) quiet = 0;
    return quiet;
}

/* Widget fields at +0..+704 and +1984..+2008 in one read; the two reads the ungated snapshot made, and their failure, if
 * that read fails. */
static int LoadWidget(uintptr_t address)
{
    if (apc_read(address, g_widget, 2008)) return 1;
    return apc_need(address, g_widget, 704, "Image memory unavailable") &&
        apc_need(address + 1984, (uint8_t*)g_widget + 1984, 24, "Image memory unavailable");
}

/* An initialized private material, or the named thumbnail template. */
static int Supported(const uint32_t* a)
{
    uint32_t lo = a[152], hi = a[153];
    return (lo == 0 && hi == 0 && ApcWordPointer(a, 150) != 0) || (lo == 0x5506E446u && hi == 0x27EF0643u);
}

static int ImageElement(const uint32_t* a) { return (a[68] & 0x3C0000u) == 0xC0000u; }

/* A widget's row: a is the widget read, record the 80-byte record. */
static void WidgetRow(ApcImageSnap* r, uintptr_t address, const uint8_t* record, const ApcItem* item)
{
    if (r->widget_count >= APC_WIDGETS) return;
    const uint8_t* a = (const uint8_t*)g_widget;
    ApcWidget* w = &r->widgets[r->widget_count++];
    memset(w, 0, sizeof *w);
    w->key = item->key;
    w->owner = r->owner;
    w->world = r->world;
    w->controller_kind = r->controller_kind;
    w->widget = address;
    w->element = address + 272;
    w->record_pointer = ApcU64(a, 1984);
    w->visual = ApcU64(record, 0);
    w->bound = a[2005] != 0;
    w->invalidated = record[68] != 0;
    w->named_material = g_widget[152] == 0x5506E446u && g_widget[153] == 0x27EF0643u;
    w->native_ready = item->ready;
    w->pixels_ready = item->pixels_ready;
    w->indices = ApcU64(record, 60);
    memcpy(w->uv, a + 548, 16);
    memcpy(w->size, a + 284, 8);
    w->box_width = (double)ApcF32(a, 12) * (double)ApcF32(a, 28);
    w->box_height = (double)ApcF32(a, 16) * (double)ApcF32(a, 32);
    w->fit = g_widget[500];
}

static int Widget(ApcImageSnap* r, uintptr_t address, const uint8_t* record, const ApcItem* item)
{
    if (!LoadWidget(address)) return 0;
    if (ImageElement(g_widget) && Supported(g_widget)) WidgetRow(r, address, record, item);
    return 1;
}

static void AddCapture(ApcImageSnap* r, const ApcItem* item)
{
    if (r->capture_size + 2 + item->key.size > sizeof r->capture) return;
    r->capture[r->capture_size] = item->card;
    r->capture[r->capture_size + 1] = item->index;
    memcpy(r->capture + r->capture_size + 2, item->key.bytes, item->key.size);
    r->capture_size += 2 + item->key.size;
}

static void StartCapture(ApcImageSnap* r)
{
    uint64_t atlas = r->atlas;
    memcpy(r->capture, &atlas, 8);
    r->capture_size = 8;
}

static void AddItem(ApcImageSnap* r, int slot)
{
    if (r->item_count < (int)sizeof r->items) r->items[r->item_count++] = (uint8_t)slot;
}

static ApcItem* ItemAt(ApcImageSnap* r, uint32_t card, uint32_t slot)
{
    if (card >= 6 || slot >= 15 || !r->slots[card * 15 + slot].present) return NULL;
    return &r->slots[card * 15 + slot];
}

/* A widget's record pointer from the state's tails (read when the refresh did not). */
static int WidgetPointer(ApcState* st, int index, uintptr_t address, uintptr_t* pointer)
{
    if (!st->tails_ok[index] && !apc_need(address, &st->TAILS[index * 2], 8, "Image memory unavailable")) return 0;
    *pointer = ApcWordPointer(st->TAILS, (size_t)index * 2);
    return 1;
}

/* The registry includes hidden widgets from the screen just left. An idle detach is allowed only when every visible
 * consumer can be rebound in this tick; hidden consumers are moved to fresh too. */
static int Mapped(const ApcImageSnap* r, uintptr_t element)
{
    for (int i = 0; i < r->widget_count; i++)
        if (r->widgets[i].element == element) return 1;
    return 0;
}

static int WidgetsUsable(const ApcImageSnap* r, int* visibleReady)
{
    int ok = 1;
    *visibleReady = 1;
    for (int i = 0; i < r->widget_count; i++)
    {
        const ApcWidget* w = &r->widgets[i];
        if (w->fit < 1 || w->fit > 3 || !ApcFinite(w->box_width) || !ApcFinite(w->box_height) || w->box_width <= 0 ||
            w->box_height <= 0)
            ok = 0;
        if (!w->pixels_ready) *visibleReady = 0;
    }
    return ok;
}

static int Registry(ApcImageSnap* r, const uint32_t* m, int* ok)
{
    uint32_t n = m[2784];
    if (n > 128) return apc_fail("Image registry bounds");
    for (uint32_t i = 0; i < n; i++)
    {
        uintptr_t element = ApcWordPointer(m, 2786 + i * 2);
        if (!element) return apc_fail("assertion failed!");
        r->registry[r->registry_count++] = element;
        if (!*ok || Mapped(r, element)) continue;
        if (!apc_need(element, g_element, 88, "Image memory unavailable")) return 0;
        if (!ImageElement(g_element) || ApcF32(g_element, 84) != 0.0f) *ok = 0;
    }
    return 1;
}

/* Every nonempty card belongs to the screen and every request has a key. */
static int Covered(ApcImageSnap* r, const uint32_t* m, const int* owned)
{
    int ok = r->widget_count > 0 && (uint32_t)r->item_count == r->expected_count;
    for (int c = 0; c < 6; c++)
        if (m[c * 454 + 458] != 0 && !owned[c]) { r->can_freeze = 0; ok = 0; }
    for (int i = 0; i < APC_ITEMS; i++)
        if (r->slots[i].present && !r->slots[i].has_key) ok = 0;
    return ok;
}

/* Handoff boundaries that keep the current request (can_freeze, the switch boundary, is set by Cards):
 *   idle:    every card complete, so the whole request is retained.
 *   rebind:  every card complete, but an earlier visible handoff left some completed regions blank in the working
 *            atlas; the image cache detaches only when those regions' visible tiles hold crops.
 *   visible: every card backing a visible tile is complete and no card is composing, so a short visit keeps what the
 *            player saw. */
static int IdleGate(ApcImageSnap* r, const uint32_t* m, const int* owned)
{
    int ok = Covered(r, m, owned);
    int visibleReady;
    if (!WidgetsUsable(r, &visibleReady)) ok = 0;
    int visible = ok && !r->complete && r->quiescent && r->blank_cards == 0 && visibleReady;
    /* Registry reads cost one read per consumer: skipped on generation ticks where no handoff could be accepted; a
     * complete request always lists them because restoring the working atlas rebinds them. */
    if ((r->can_freeze || r->complete || visible) && !Registry(r, m, &ok)) return 0;
    r->can_freeze_idle = ok && r->complete && r->blank_cards == 0;
    r->can_freeze_rebind = ok && r->complete && r->blank_cards > 0;
    r->can_freeze_visible = ok && visible;
    return 1;
}

static void SetKey(ApcItem* item, const ApcImageSnap* r, const uint8_t* variant, size_t size)
{
    MakeKey(&item->key, r->layout, item->input, variant, size);
    item->has_key = 1;
}

/* The briefing loadout: six records holding their slot's request, each widget pointing at its record. 1 shown (decoded),
 * 0 not, -1 error. */
static int Loadout(ApcState* st, ApcImageSnap* r, uintptr_t owner)
{
    const uint8_t* small = (const uint8_t*)st->SMALL;
    if (!st->small_ok && !apc_need(owner + 454728, st->SMALL, 480, "Image memory unavailable")) return -1;
    ApcItem* items[6];
    for (int index = 0; index < 6; index++)
    {
        const uint8_t* rec = small + index * 80;
        ApcItem* item = ItemAt(r, ApcU32(rec, 60), ApcU32(rec, 64));
        uintptr_t address = owner + 422768 + (uintptr_t)index * 5464, pointer = 0;
        if (item == NULL || ApcU32(rec, 8) != 3 || ApcU32(item->input, 100) != kBriefingKinds[index]) return 0;
        if (!WidgetPointer(st, index, address + 1984, &pointer)) return -1;
        if (pointer != owner + 454728 + (uintptr_t)index * 80) return 0;
        items[index] = item;
    }
    r->screen = APC_SCREEN_BRIEFING_LOADOUT;
    int owned[6] = {0};
    StartCapture(r);
    for (int index = 0; index < 6; index++)
    {
        const uint8_t* rec = small + index * 80;
        uint8_t variant[29];
        memcpy(variant, "briefing_loadout", 16);
        variant[16] = (uint8_t)index;
        memcpy(variant + 17, rec, 8);
        memcpy(variant + 25, rec + 72, 4);
        SetKey(items[index], r, variant, sizeof variant);
        AddItem(r, (int)(items[index] - r->slots));
        owned[items[index]->card] = 1;
        AddCapture(r, items[index]);
        if (!Widget(r, owner + 422768 + (uintptr_t)index * 5464, rec, items[index])) return -1;
    }
    return IdleGate(r, st->MB, owned) ? 1 : -1;
}

/* One pre-select record: its item keyed and listed, its widget read when it points at the record. */
static int PreselectRecord(ApcState* st, ApcImageSnap* r, uintptr_t control, int index, uint32_t selected)
{
    const uint8_t* small = (const uint8_t*)st->SMALL;
    const uint8_t* rec = small + index * 80;
    uint32_t card = ApcU32(rec, 60);
    ApcItem* item = ItemAt(r, card, ApcU32(rec, 64));
    if (item == NULL || card != selected || ApcU32(rec, 8) != 3) return 1;
    uint8_t variant[25];
    memcpy(variant, "preselect", 9);
    memcpy(variant + 9, small + 252, 4);
    memcpy(variant + 13, rec, 8);
    memcpy(variant + 21, rec + 72, 4);
    SetKey(item, r, variant, sizeof variant);
    AddItem(r, (int)(item - r->slots));
    if (r->capture_size == 0) StartCapture(r);
    AddCapture(r, item);
    uintptr_t address = control + 5256 + (uintptr_t)index * 12304, pointer = 0;
    if (!WidgetPointer(st, index, address + 1984, &pointer)) return 0;
    return pointer != control + 37728 + (uintptr_t)index * 80 || Widget(r, address, rec, item);
}

/* The Armory pre-select: three records of the selected card (weapon mode 0, cosmetic 1 or 2). */
static int Preselect(ApcState* st, ApcImageSnap* r, uintptr_t control)
{
    uint32_t mode = st->SMALL[63];
    if (mode > 2) return apc_fail("Pre-select mode bounds");
    r->screen = mode == 0 ? APC_SCREEN_WEAPON_PRESELECT : APC_SCREEN_COSMETIC_PRESELECT;
    if (!st->small_ok && !apc_need(control + 37728, st->SMALL, 240, "Image memory unavailable")) return 0;
    int owned[6] = {0};
    uint32_t selected = st->SMALL[60];
    if (selected < 6) owned[selected] = 1;
    for (int index = 0; index < 3; index++)
        if (!PreselectRecord(st, r, control, index, selected)) return 0;
    return IdleGate(r, st->MB, owned);
}

/* Every requested item through its grid record, offscreen cards included; the record style distinguishes alternate
 * camera presets. */
static int GridItems(const ApcState* st, ApcImageSnap* r)
{
    const uint32_t* g = st->META;
    const uint8_t* meta = (const uint8_t*)st->META;
    for (uint32_t index = 0; index < 256; index++)
    {
        uint32_t at = 1083 + index * 20;     /* the record at +602104 */
        ApcItem* item = ItemAt(r, g[at + 15], g[at + 16]);
        if (item == NULL || g[at + 2] != 3) continue;
        uint8_t variant[16];
        memcpy(variant, meta + 4280, 4);     /* the grid kind (+602052) */
        memcpy(variant + 4, meta + at * 4, 8);
        memcpy(variant + 12, meta + at * 4 + 72, 4);
        ApcKey key;
        MakeKey(&key, r->layout, item->input, variant, sizeof variant);
        if (item->has_key && !apc_key_equal(&item->key, &key)) return apc_fail("Ambiguous grid request identity");
        if (item->has_key) continue;
        item->key = key;
        item->has_key = 1;
        AddItem(r, (int)(item - r->slots));
        AddCapture(r, item);                 /* slot moves are new atlas work even if the key stays the same */
    }
    return 1;
}

static int GridWidget(const ApcState* st, ApcImageSnap* r, uintptr_t grid, uintptr_t address)
{
    if (!LoadWidget(address)) return 0;
    uintptr_t record = ApcWordPointer(g_widget, 496);
    if (!record || record < grid + 602104) return 1;
    uintptr_t offset = record - (grid + 602104);
    if (offset >= 256 * 80 || offset % 80 != 0) return 1;
    uint32_t at = 1083 + (uint32_t)offset / 4;
    const uint32_t* g = st->META;
    ApcItem* item = ItemAt(r, g[at + 15], g[at + 16]);
    if (item != NULL && item->has_key && g[at + 2] == 3 && ImageElement(g_widget) && Supported(g_widget))
        WidgetRow(r, address, (const uint8_t*)st->META + at * 4, item);
    return 1;
}

static uint32_t g_columns[1];

static int GridWidgets(const ApcState* st, ApcImageSnap* r, uintptr_t grid, uint32_t count)
{
    for (uint32_t row = 0; row < count; row++)
    {
        uintptr_t rb = grid + 2816 + (uintptr_t)row * 44752;
        if (!apc_need(rb + 44724, g_columns, 4, "Image memory unavailable")) return 0;
        uint32_t columns = g_columns[0];
        if (columns > 4) return apc_fail("Image grid column bounds");
        for (uint32_t col = 0; col < columns; col++)
            if (!GridWidget(st, r, grid, rb + 9192 + (uintptr_t)col * 11112)) return 0;
    }
    return 1;
}

static int GridScreen(ApcState* st, ApcImageSnap* r, uint32_t kind, uintptr_t owner)
{
    r->screen = kind == 229 ? APC_SCREEN_BRIEFING_GRID : APC_SCREEN_GRID;
    uintptr_t grid = owner + (kind == 229 ? 864032u : 523752u);
    if (!(st->meta_ok && st->meta_address == grid) && !apc_need(grid + 597772, st->META, 24892, "Image memory unavailable")) return 0;
    const uint32_t* g = st->META;
    uint32_t count = g[0];
    if (count > 12) return apc_fail("Image grid row bounds");
    /* Every nonempty card must belong to this grid. Empty cards do not render, so small categories can hand over the
     * completed old atlas too. */
    int owned[6] = {0};
    for (int i = 0; i < 6; i++)
        if (g[6205 + i * 3] < 6) owned[g[6205 + i * 3]] = 1; /* +622592 */
    for (int c = 0; c < 6; c++)
        if (st->MB[c * 454 + 458] != 0 && !owned[c]) r->can_freeze = 0;
    StartCapture(r);
    if (!GridItems(st, r) || !GridWidgets(st, r, grid, count)) return 0;
    return IdleGate(r, st->MB, owned);
}

static int Screen(ApcState* st, ApcImageSnap* r, uint32_t kind, uintptr_t owner)
{
    if (kind == 229)
    {
        int shown = Loadout(st, r, owner); /* when it is not shown, it decoded nothing */
        if (shown != 0) return shown > 0;
    }
    uintptr_t control = owner + 280216;
    if (kind == 224)
    {
        /* The pre-select records (+37728) and mode block (+37968) are one read. */
        if (!st->small_ok && !apc_need(control + 37968, (uint8_t*)st->SMALL + 240, 16, "Image memory unavailable")) return 0;
        if (((const uint8_t*)st->SMALL)[244] == 0 && st->SMALL[60] < 6) return Preselect(st, r, control);
    }
    return GridScreen(st, r, kind, owner);
}

static uint32_t KindOf(const ApcState* st)
{
    uint32_t depth = st->STACK[5];
    if (depth < 1 || depth > 5) return 0;
    uint32_t top = st->STACK[depth - 1];
    return top == 5 ? 224 : top == 14 ? 229 : 0;
}

static void Reset(ApcImageSnap* r)
{
    r->context = r->manager = r->world = r->owner = r->atlas = 0;
    r->view_size = 0;
    r->controller_kind = r->width = r->height = r->expected_count = 0;
    r->bytes = r->descriptor_id = 0;
    r->blank_cards = r->complete = r->can_freeze = r->quiescent = 0;
    r->can_freeze_idle = r->can_freeze_rebind = r->can_freeze_visible = 0;
    r->tile_width = r->tile_height = 0;
    r->screen = APC_SCREEN_NONE;
    r->item_count = r->widget_count = r->registry_count = 0;
    r->capture_size = 0;
    for (int c = 0; c < 6; c++)
    {
        r->source[c].present = 0;
        r->source[c].state = 0;
    }
    for (int i = 0; i < APC_ITEMS; i++) r->slots[i].present = r->slots[i].has_key = 0;
}

/* The world, kind and owner the screen belongs to (the request's view). */
static void View(ApcImageSnap* r, uintptr_t world, uint32_t kind, uintptr_t owner)
{
    uint64_t w = world, o = owner;
    r->world = world;
    r->controller_kind = kind;
    r->owner = owner;
    memcpy(r->view, &w, 8);
    r->view[8] = (uint8_t)kind;
    if (owner) memcpy(r->view + 9, &o, 8);
    r->view_size = owner ? 17 : 9;
}

/* The managers and the screen's owner: 1 decoded so far (the rest follows), 2 stop here, 0 error. */
static int Context(ApcState* st, ApcImageSnap* r, uint32_t* kind, uintptr_t* owner)
{
    if (!st->g_ok && !vpm_game_read(APC_RVA_GLOBALS, st->G, sizeof st->G)) return apc_fail("Image memory unavailable");
    uintptr_t sm = ApcWordPointer(st->G, 42), ui = ApcWordPointer(st->G, 4), tm = ApcWordPointer(st->G, 0);
    if (!tm) return 2;
    /* The detached render texture is allocated through the engine application API, not owned by the transient UI
     * world: it is kept while the thumbnail manager survives, even with no menu open. */
    r->context = r->manager = tm;
    if (!sm || !ui) return 2;
    if (!st->stack_ok && !apc_need(sm + 0x429C, st->STACK, 24, "Image memory unavailable")) return 0;
    *kind = KindOf(st);
    if (!*kind) return 2;
    if (!st->ui_ok && !apc_need(ui + 15432, st->UIB, 8, "Image memory unavailable")) return 0;
    uintptr_t world = ApcWordPointer(st->UIB, 0);
    if (!world) return 2;
    if (!OwnerOf(st, *kind, owner)) return 0;
    View(r, world, *kind, *owner);
    if (!st->mb_ok && !apc_need(tm, st->MB, APC_MANAGER_SIZE, "Image memory unavailable")) return 0;
    return 1;
}

/* The ungated snapshot, decoded from the state's buffers (lint: per-frame: a full image tick). */
int apc_decode(ApcImageSnap* r)
{
    ApcState* st = apc_state();
    uint32_t kind = 0;
    uintptr_t owner = 0;
    Reset(r);
    int context = Context(st, r, &kind, &owner);
    if (context != 1) return context != 0;
    uintptr_t atlas = ApcWordPointer(st->MB, 2778);
    if (!atlas) return 1;
    if (!Descriptor(st, atlas, r)) return 0;
    ObservePreviews(st);
    int nonempty = 0;
    if (!Cards(st, r, &nonempty)) return 0;
    r->quiescent = Quiescent(st, r, nonempty);
    r->tile_width = ApcF32(st->MB, 24);
    r->tile_height = ApcF32(st->MB, 28);
    if (!owner) { r->can_freeze = 0; return 1; }
    return Screen(st, r, kind, owner);
}
