/* Armory Preview Cache: the image cache (images.lua, v23.1), build 25480438.
 *
 * Retains complete atlases before native layout changes destroy them, and shows their crops on the screen's tiles until
 * the native pipeline renders the same requests again. Native requests continue normally; cached images replace the
 * presentation only. At most 8 retained atlases and 128 MB; the least recently used one goes first.
 *
 * A retained crop describes one native render. Cards stop being complete when the native pipeline re-queues them (a
 * screen rebuild, a scroll, an appearance change such as a weapon pattern), and what they render next supersedes the
 * crop captured before it: such a crop is marked (ApcCrop.rendered) until a capture adopts its new pixels.
 *
 * The gate: a tick whose refresh shows nothing changed since the last full tick, with nothing pending, no tile waiting
 * for a retry and no memory pressure then or now, would only repeat that tick (re-send the same texture, UV, size and
 * opacity to bound widgets, add the same counts). It adds those counts, marks the same textures used and repeats the
 * texture ownership check (one read per texture shown), and decodes nothing. */
#include "apc.h"

#define TEXTURES 8
#define BUDGET (128ull * 1024 * 1024)
#define CROPS 1024
#define CROP_INDEX 2048

static struct
{
    int enabled;
    ApcImageStats st;
    int textures[TEXTURES];
    int texture_count;
    uintptr_t context;                  /* the last snapshot's thumbnail manager (0: none, the Lua's nil) */
    uint8_t view_size;                  /* 0: none yet */
    uint8_t view[17];
    int has_last_capture;
    size_t last_capture_size;
    int touched[TEXTURES];
    int touched_count;
    int applied, retry, pressured;
} g;

static ApcImageSnap g_snap;
static ApcCandidate g_pending;
static ApcCandidate g_capturing;        /* a capture in progress: it replaces the pending one only when it succeeds */
static ApcCrop g_crops[CROPS];
static uint8_t g_live[CROPS];
static uint16_t g_index[CROP_INDEX];   /* crop + 1, 0 empty */
static int g_indexDirty;
static uint8_t g_lastCapture[APC_CAPTURE_MAX * 2];
static uint8_t g_capture[APC_CAPTURE_MAX * 2];

/* ---- the crops (images.lua entries) ------------------------------------------------------------------------------- */

static void IndexInsert(int i)
{
    uint32_t at = (uint32_t)g_crops[i].key.hash & (CROP_INDEX - 1);
    while (g_index[at] != 0) at = (at + 1) & (CROP_INDEX - 1);
    g_index[at] = (uint16_t)(i + 1);
}

static void IndexRebuild(void)
{
    memset(g_index, 0, sizeof g_index);
    for (int i = 0; i < CROPS; i++)
        if (g_live[i]) IndexInsert(i);
    g_indexDirty = 0;
}

/* lint: per-frame */
ApcCrop* apc_crop_find(const ApcKey* key)
{
    if (g_indexDirty) IndexRebuild();
    for (uint32_t at = (uint32_t)key->hash & (CROP_INDEX - 1); g_index[at] != 0; at = (at + 1) & (CROP_INDEX - 1))
    {
        ApcCrop* crop = &g_crops[g_index[at] - 1];
        if (apc_key_equal(&crop->key, key)) return crop;
    }
    return NULL;
}

static void CropRemove(ApcCrop* crop)
{
    g_live[crop - g_crops] = 0;
    g_indexDirty = 1;
}

static void CropsClear(void)
{
    memset(g_live, 0, sizeof g_live);
    memset(g_index, 0, sizeof g_index);
    g_indexDirty = 0;
}

/* Stores a crop under its key (replacing the one it had); 0 when the table is full. */
static int CropPut(const ApcCrop* value)
{
    ApcCrop* crop = apc_crop_find(&value->key);
    if (crop != NULL) { *crop = *value; return 1; }
    for (int i = 0; i < CROPS; i++)
    {
        if (g_live[i]) continue;
        g_crops[i] = *value;
        g_live[i] = 1;
        IndexInsert(i);
        return 1;
    }
    return 0;
}

/* ---- state ------------------------------------------------------------------------------------------------------- */

void apc_images_reset(int enabled)
{
    memset(&g, 0, sizeof g);
    g.enabled = enabled;
    g.st.status = "learning_images";
    g_pending.present = 0;
    CropsClear();
}

int apc_images_enabled(void) { return g.enabled; }
const ApcImageStats* apc_images_stats(void)
{
    g.st.textures = (uint32_t)g.texture_count;
    return &g.st;
}
int apc_images_texture_count(void) { return g.texture_count; }

static ApcTexture* Texture(int i) { return apc_texture(g.textures[i]); }

static void CountSurface(int screen, int hits)
{
    if (screen == APC_SCREEN_GRID) g.st.grid_hits += (uint32_t)hits;
    else if (screen == APC_SCREEN_WEAPON_PRESELECT || screen == APC_SCREEN_COSMETIC_PRESELECT) g.st.preselect_hits += (uint32_t)hits;
    else if (screen == APC_SCREEN_BRIEFING_GRID || screen == APC_SCREEN_BRIEFING_LOADOUT) g.st.briefing_hits += (uint32_t)hits;
}

static void ResetRequest(void)
{
    g_pending.present = 0;
    g.has_last_capture = 0;
    g.st.pending_items = g.st.ready_items = g.st.missing_ready_items = g.st.blank_ready_items = 0;
    g.st.rendered_items = g.st.changed_items = 0;
    g.st.last_hits = g.st.last_misses = g.st.last_early_hits = 0;
}

/* lint: per-frame */
int apc_images_bound(void) { return apc_present_bound(); }

/* lint: per-frame */
int apc_images_before(void) { return apc_present_prune(); }

/* The idle gate: the last full tick saw no thumbnail screen and bound nothing, nothing is pending or waiting for a retry,
 * it ran without memory pressure and no binding is left. lint: per-frame */
int apc_images_quiet(void)
{
    if (!g.enabled) return 1;
    return g.st.screen == APC_SCREEN_NONE && !g_pending.present && !g.retry && !g.pressured && !g.applied && apc_present_quiet();
}

static void Unlist(int i)
{
    Texture(i)->listed = 0;
    g.st.bytes -= Texture(i)->bytes;
    g.st.released++;
    for (int j = i; j + 1 < g.texture_count; j++) g.textures[j] = g.textures[j + 1];
    g.texture_count--;
}

/* Every binding back to the native pipeline, every retained atlas released (each removed only after its release
 * succeeds, so a failed cleanup can be retried). */
int apc_images_clear(const char* reason)
{
    if (g.texture_count > 0) g.st.clear_count++;
    (void)reason;
    if (!apc_present_restore(1)) return 0;
    CropsClear();
    ResetRequest();
    while (g.texture_count > 0)
    {
        if (!apc_present_destroy(g.textures[g.texture_count - 1])) return 0;
        Unlist(g.texture_count - 1);
    }
    g.st.status = "learning_images";
    return 1;
}

/* A more complete atlas can replace earlier partial copies: cached UI references are unbound before any now-unreferenced
 * texture is released. 1 released some (*released), 0 error. */
static int ReleaseSuperseded(int* released)
{
    uint8_t used[APC_TEXTURES] = {0};
    int unused = 0;
    *released = 0;
    for (int i = 0; i < CROPS; i++)
        if (g_live[i] && g_crops[i].texture >= 0) used[(int)g_crops[i].texture] = 1;
    for (int i = 0; i < g.texture_count; i++) unused |= !used[g.textures[i]];
    if (!unused) return 1;
    if (!apc_present_restore(0)) return 0;
    for (int i = g.texture_count - 1; i >= 0; i--)
    {
        if (used[g.textures[i]]) continue;
        if (!apc_present_destroy(g.textures[i])) return 0;
        Unlist(i);
    }
    *released = 1;
    return 1;
}

/* The textures the screen's items are shown from: never evicted for the candidate (taken once, before evicting). */
static void Protect(const ApcImageSnap* s, uint8_t* protectedTextures)
{
    memset(protectedTextures, 0, APC_TEXTURES);
    for (int i = 0; i < s->item_count; i++)
    {
        const ApcCrop* crop = apc_crop_find(&s->slots[s->items[i]].key);
        if (crop != NULL) protectedTextures[(int)crop->texture] = 1;
    }
}

static int Victim(const uint8_t* protectedTextures)
{
    int victim = -1;
    for (int i = 0; i < g.texture_count; i++)
        if (!protectedTextures[g.textures[i]] && (victim < 0 || Texture(i)->used < Texture(victim)->used)) victim = i;
    return victim;
}

static void DropCrops(int texture)
{
    for (int i = 0; i < CROPS; i++)
        if (g_live[i] && g_crops[i].texture == texture) CropRemove(&g_crops[i]);
}

/* Makes room for the candidate: 1 room made, 0 none (the budget is full of protected atlases), -1 error. */
static int Evict(ApcImageSnap* s, uint64_t bytes)
{
    uint8_t protectedTextures[APC_TEXTURES];
    Protect(s, protectedTextures);
    while (g.texture_count >= TEXTURES || g.st.bytes + bytes > BUDGET)
    {
        int victim = Victim(protectedTextures);
        if (victim < 0) return 0;
        if (!apc_present_restore(0)) return -1;
        int texture = g.textures[victim];
        DropCrops(texture);
        if (!apc_present_destroy(texture)) return -1;
        Unlist(victim);
        g.st.evicted++;
        if (!apc_present_snapshot(0, s)) return -1;
    }
    return 1;
}

static void Adopt(const ApcCandidate* candidate, int texture)
{
    for (int i = 0; i < candidate->crop_count; i++)
    {
        ApcCrop crop = candidate->crops[i];
        const ApcCrop* existing = apc_crop_find(&crop.key);
        /* Only crops that replace an existing crop count; a first capture of a re-rendered item is a miss. */
        if (existing != NULL && existing->rendered) g.st.refreshed++;
        crop.texture = (int8_t)texture;
        crop.rendered = 0;
        if (!CropPut(&crop)) break;
    }
}

/* Retains the candidate's atlas (the handoff): 1 done (*kept), 0 error. s may be decoded again. */
static int Retain(ApcImageSnap* s, const ApcCandidate* candidate, int idle, int* kept)
{
    *kept = 0;
    if (candidate->bytes > BUDGET) { g.st.status = "image_budget_full"; return 1; }
    int room = Evict(s, candidate->bytes);
    if (room < 0) return 0;
    if (room == 0) { g.st.status = "image_budget_full"; return 1; }
    int texture;
    if (!apc_present_freeze(s, candidate, &texture)) return 0;
    if (texture < 0) return 1;
    ApcTexture* t = apc_texture(texture);
    t->used = g.st.ticks;
    g.textures[g.texture_count++] = texture;
    g.st.bytes += t->bytes;
    g.st.retained++;
    if (idle) g.st.idle_retained++;
    if (!candidate->all_complete) g.st.partial_retained++;
    Adopt(candidate, texture);
    s->atlas = t->replacement;
    int released;
    if (!ReleaseSuperseded(&released)) return 0;
    if (released && !apc_present_snapshot(0, s)) return 0;
    *kept = 1;
    return 1;
}

/* A same-request handoff: 1 idle, 2 visible, 0 none. A visible handoff runs only while a visible tile has no crop at all,
 * so warm visits keep the single whole-request refresh and never allocate an extra replacement atlas. A rebind handoff
 * follows it once the offscreen cards finish; tiles over the regions it left blank must already be served from crops. */
static int HandoffMode(const ApcImageSnap* s)
{
    if (s->can_freeze_idle) return 1;
    if (s->can_freeze_rebind)
    {
        for (int i = 0; i < s->widget_count; i++)
            if (!s->widgets[i].pixels_ready && apc_crop_find(&s->widgets[i].key) == NULL) return 0;
        return 1;
    }
    if (!s->can_freeze_visible) return 0;
    for (int i = 0; i < s->widget_count; i++)
        if (apc_crop_find(&s->widgets[i].key) == NULL) return 2;
    return 0;
}

static int SameRequest(const ApcCandidate* p, const ApcImageSnap* s)
{
    return p->request_size == s->capture_size && memcmp(p->request, s->capture, s->capture_size) == 0;
}

/* The pending capture against this snapshot: dropped when the atlas or layout changed, handed off (or counted as a late
 * switch) when the request changed. */
static int SwitchPending(ApcImageSnap* s)
{
    if (g_pending.present && (g_pending.atlas != s->atlas || memcmp(g_pending.layout, s->layout, APC_LAYOUT) != 0))
    {
        g_pending.present = 0;
        g.st.pending_items = 0;
        g.st.pending_drops++;
    }
    if (!g_pending.present || SameRequest(&g_pending, s)) return 1;
    g_pending.present = 0;
    g.st.pending_items = 0;
    if (!s->can_freeze) { g.st.late_switches++; return 1; }
    int kept;
    return Retain(s, &g_pending, 0, &kept);
}

static int PreviewDiffers(const ApcCrop* crop, const ApcItem* item)
{
    uint8_t size = 0;
    const uint8_t* slots = apc_preview_slots(item->preview, &size);
    return crop->has_preview && slots != NULL && (size != crop->preview_size || memcmp(slots, crop->preview, size) != 0);
}

/* A weapon's pattern or attachment change never alters the request identity, so it is detected from the configured slots
 * the preview queue reports. The superseded crop goes at once: the tile returns to the native pipeline, which shows the
 * re-render as soon as it composes, and a later capture keeps it. */
static void RetireChanged(const ApcImageSnap* s)
{
    uint32_t changed = 0;
    for (int i = 0; i < s->item_count; i++)
    {
        const ApcItem* item = &s->slots[s->items[i]];
        ApcCrop* crop = apc_crop_find(&item->key);
        if (crop == NULL || !PreviewDiffers(crop, item)) continue;
        CropRemove(crop);
        changed++;
        for (int j = 0; g_pending.present && j < g_pending.crop_count; j++)
            if (apc_key_equal(&g_pending.crops[j].key, &item->key)) g_pending.crops[j] = g_pending.crops[--g_pending.crop_count];
    }
    g.st.changed_items = changed;
    g.st.reappeared += changed;
}

static void Counted(const ApcImageSnap* s, const ApcApplied* a)
{
    g.st.last_early_hits = (uint32_t)a->early;
    g.st.early_hits += (uint32_t)a->early;
    g.st.hits += (uint32_t)a->hits;
    g.st.misses += (uint32_t)a->misses;
    g.st.last_hits = (uint32_t)a->hits;
    g.st.last_misses = (uint32_t)a->misses;
    CountSurface(s->screen, a->hits);
    for (int i = 0; i < s->item_count; i++)
    {
        const ApcCrop* crop = apc_crop_find(&s->slots[s->items[i]].key);
        if (crop != NULL) apc_texture(crop->texture)->used = g.st.ticks;
    }
}

static size_t AppendKey(size_t at, const ApcKey* key)
{
    if (at + key->size <= sizeof g_capture) memcpy(g_capture + at, key->bytes, key->size);
    return at + key->size;
}

/* The items whose pixels are ready, and the ones without a current crop: the capture id (request + ready keys) and how
 * many are missing. A card that is not complete has been re-queued: its next completion supersedes the crop. */
static uint32_t Readiness(const ApcImageSnap* s, size_t* captureSize)
{
    uint32_t ready = 0, missing = 0, superseded = 0;
    size_t at = s->capture_size;
    memcpy(g_capture, s->capture, s->capture_size);
    g.st.blank_ready_items = 0;
    for (int i = 0; i < s->item_count; i++)
    {
        const ApcItem* item = &s->slots[s->items[i]];
        ApcCrop* crop = apc_crop_find(&item->key);
        if (!item->ready && crop != NULL) crop->rendered = 1;
        if (item->ready && !item->pixels_ready) g.st.blank_ready_items++;
        if (!item->ready || !item->pixels_ready) continue;
        ready++;
        at = AppendKey(at, &item->key);
        missing += crop == NULL || crop->rendered;
        superseded += crop != NULL && crop->rendered;
    }
    g.st.ready_items = ready;
    g.st.missing_ready_items = missing;
    g.st.rendered_items = superseded;
    *captureSize = at < sizeof g_capture ? at : sizeof g_capture;
    return missing;
}

/* Refreshes partial capture metadata as cards finish, or drops it when native generation restarts: this never detaches
 * the active work. */
static int UpdatePending(const ApcImageSnap* s)
{
    size_t size;
    uint32_t missing = Readiness(s, &size);
    if (g.has_last_capture && size == g.last_capture_size && memcmp(g_capture, g_lastCapture, size) == 0) return 1;
    g.has_last_capture = 1;
    g.last_capture_size = size;
    memcpy(g_lastCapture, g_capture, size);
    g_capturing.present = 0;
    if (missing > 0 && !apc_present_capture(s, &g_capturing)) return 0;
    g_pending.present = 0;
    g.st.pending_items = 0;
    if (!g_capturing.present) return 1;
    g_pending = g_capturing;
    memcpy(g_pending.request, s->capture, s->capture_size);
    g_pending.request_size = s->capture_size;
    g_pending.all_complete = s->complete;
    g.st.pending_items = (uint32_t)g_pending.crop_count;
    return 1;
}

/* The idle working replacement has no pixels yet: the completed original is bound before this tick returns to the UI. */
static int Rebind(ApcImageSnap* s, ApcApplied* a)
{
    ApcApplied again;
    if (!apc_present_apply(s, &again)) return 0;
    g.retry = again.unresolved > 0 || a->initialized + again.initialized > 0;
    g.st.hits += (uint32_t)(again.hits - a->hits);
    g.st.misses += (uint32_t)(again.misses - a->misses);
    g.st.early_hits += (uint32_t)(again.early - a->early);
    CountSurface(s->screen, again.hits - a->hits);
    a->hits = again.hits;
    a->misses = again.misses;
    a->early = again.early;
    g.st.last_hits = (uint32_t)again.hits;
    g.st.last_misses = (uint32_t)again.misses;
    g.st.last_early_hits = (uint32_t)again.early;
    g.st.missing_ready_items = 0;
    g.st.rendered_items = 0;
    return 1;
}

static int Handoff(ApcImageSnap* s, ApcApplied* a)
{
    int mode = g_pending.present && SameRequest(&g_pending, s) ? HandoffMode(s) : 0;
    if (mode == 0) return 1;
    int kept;
    if (!Retain(s, &g_pending, mode == 1, &kept)) return 0;
    if (kept && mode == 2) g.st.visible_retained++;
    if (!kept) return 1;
    g_pending.present = 0;
    g.st.pending_items = 0;
    return Rebind(s, a);
}

/* The textures an unchanged next tick marks used. */
static void Touched(const ApcImageSnap* s)
{
    for (int i = 0; i < s->item_count; i++)
    {
        const ApcCrop* crop = apc_crop_find(&s->slots[s->items[i]].key);
        int listed = 0;
        if (crop == NULL) continue;
        for (int j = 0; j < g.touched_count; j++) listed |= g.touched[j] == crop->texture;
        if (!listed && g.touched_count < TEXTURES) g.touched[g.touched_count++] = crop->texture;
    }
}


static int ViewChanged(const ApcImageSnap* s)
{
    return g.view_size != s->view_size || memcmp(g.view, s->view, s->view_size) != 0;
}

/* The snapshot's context and view against the last ones: a new manager (or pressure) clears the cache, a new view
 * drops the request's capture metadata. 1 the tick goes on, 2 it stops here, 0 error. */
static int Begin(ApcImageSnap* s, int pressure)
{
    g.st.screen = s->screen;
    if (g.context != s->context || pressure)
    {
        if (!apc_images_clear(pressure ? "memory_pressure" : "thumbnail_manager_changed")) return 0;
        g.context = s->context;
    }
    if (ViewChanged(s))
    {
        ResetRequest();
        g.view_size = s->view_size;
        memcpy(g.view, s->view, s->view_size);
    }
    if (pressure || !s->context || !s->atlas)
    {
        ResetRequest();
        g.st.status = pressure ? "image_memory_pressure" : s->context ? "waiting_for_thumbnail_screen" : "waiting_for_image_world";
        return 2;
    }
    if (s->capture_size == 0)
    {
        ResetRequest();
        g.st.status = "waiting_for_thumbnail_screen";
        return 2;
    }
    g.st.status = "learning_images";
    return 1;
}

/* A full tick: snapshot, handoffs, apply. lint: per-frame */
static int Full(int pressure)
{
    ApcImageSnap* s = &g_snap;
    if (!apc_present_snapshot(1, s)) return 0;
    int begun = Begin(s, pressure);
    if (begun != 1) return begun != 0;
    if (!SwitchPending(s)) return 0;
    RetireChanged(s);
    ApcApplied a;
    if (!apc_present_apply(s, &a)) return 0;
    g.applied = 1;
    g.retry = a.unresolved > 0 || a.initialized > 0;
    Counted(s, &a);
    if (!UpdatePending(s) || !Handoff(s, &a)) return 0;
    if (strcmp(g.st.status, "image_budget_full") != 0)
        g.st.status = a.hits > 0 ? "showing_retained_images" : g_pending.present ? "completed_cards_ready_to_retain" : "learning_images";
    Touched(s);
    return 1;
}

/* One refresh; a full tick when the gate says the last one would not repeat. lint: per-frame */
int apc_images_tick(int pressure)
{
    if (!g.enabled) { g.st.status = "images_disabled"; return 1; }
    g.st.ticks++;
    int unchanged = apc_present_unchanged();
    if (unchanged && !pressure && !g.pressured && !g_pending.present && !g.retry)
    {
        g.st.gated_ticks++;
        g.st.hits += g.st.last_hits;
        g.st.misses += g.st.last_misses;
        g.st.early_hits += g.st.last_early_hits;
        CountSurface(g.st.screen, (int)g.st.last_hits);
        for (int i = 0; i < g.touched_count; i++) apc_texture(g.touched[i])->used = g.st.ticks;
        g.st.changed_items = 0;
        return !g.applied || apc_present_check_textures();
    }
    g.touched_count = 0;
    g.applied = g.retry = 0;
    g.pressured = pressure != 0;
    return Full(pressure);
}
