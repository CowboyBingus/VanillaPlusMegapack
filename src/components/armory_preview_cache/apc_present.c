/* Armory Preview Cache: textures, handoffs and bindings (image_native.lua M.new, v23.1), build 25480438.
 *
 * The build-locked UI presentation and render-texture ownership adapter. It never edits code, card states, avatar work or
 * generation completion flags. A handoff (freeze) gives the thumbnail manager a fresh atlas the engine creates through
 * its own application API (create, then register, as the native atlas creator does), keeps the completed original and
 * rebinds every registered consumer to the fresh one; apply binds the retained crops to the screen's tiles with the
 * native texture, UV, size and opacity setters, initializing a tile's private material through the native material
 * contract first. Bindings are checked before every game update (prune) and released through the same setters.
 *
 * Calls into the game and the engine (function pointers at their build 25480438 addresses, checked by their code bytes
 * before start, by the core's wait for decoded code): game.dll set_texture 0x14499E0, set_uv 0x143EEF0, set_size
 * 0x1447160, set_alpha 0x1448AD0, material 0x144F800, register_image 0x1392680; helldivers2.exe create 0x31AF50,
 * destroy 0x31B360, register 0x31E030. Stores into game memory (plain stores, as the Lua's FFI stores): the manager's
 * working atlas pointer (+11112), a widget's bound byte (+2005) and a record's invalidation byte (+68). */
#include "apc.h"

#define BINDINGS 256
#define IMAGE_MATERIAL 0x27EF06435506E446ull /* the named thumbnail template */

typedef void (*SetTextureFn)(void* element, uint32_t slot, void* texture);
typedef void (*SetUvFn)(void* element, uint64_t low, uint64_t high);
typedef void (*SetSizeFn)(void* element, uint64_t size);
typedef void (*SetAlphaFn)(void* element, float alpha);
typedef void (*MaterialFn)(void* element, uint64_t material, uint8_t flag);
typedef void (*RegisterImageFn)(void* manager, void* element);
typedef void* (*CreateFn)(int width, int height, int a, int b, uint32_t name, uint8_t flag);
typedef void (*DestroyFn)(void* texture);
typedef void (*RegisterFn)(uint32_t name, void* texture);

static const ApcSignature kSignatures[] = {
    {0, 0x14499E0u, "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 49 8B D8 8B FA 48 8B F1 E8 E4 5C 00 00 48 8B D0 E8"},
    {0, 0x143EEF0u, "4C 89 44 24 18 48 89 54 24 10 48 83 EC 28 F3 0F 10 81 14 01 00 00 0F 2E 44 24 38 7A 35 75 33 F3"},
    {0, 0x1447160u, "48 89 5C 24 18 48 89 6C 24 20 48 89 54 24 10 56 57 41 57 48 83 EC 20 F3 0F 10 41 0C 48 8B DA 0F"},
    {0, 0x1448AD0u, "40 57 48 83 EC 20 F3 0F 10 41 44 48 8B F9 0F 2E C1 7A 23 75 21 F7 01 00 00 00 08 0F 84 77 01 00"},
    {0, 0x144F800u, "48 89 5C 24 08 57 48 83 EC 20 41 0F B6 F8 48 8B D9 48 85 D2 75 0F 48 8B 5C 24 30 48 83 C4 20 5F"},
    {0, 0x1392680u, "40 53 48 83 EC 20 45 33 C9 48 8B DA 48 8B 15 ED A6 0E 02 41 8B C9 44 8B 82 80 2B 00 00 45 85 C0"},
};
static const ApcSignature kExeSignatures[] = {
    {1, 0x31AF50u, "48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 40 48 8B 05 9E 52 6F 01 45 8B F9 41 8B F0"},
    {1, 0x31B360u, "48 89 5C 24 08 57 48 83 EC 20 48 8B 1D 97 4E 6F 01 48 8B F9 48 8B 83 38 03 00 00 80 B8 80 14 00"},
    {1, 0x31E030u, "4C 8B C2 8B D1 48 8B 0D CC 21 6F 01 48 8B 89 38 03 00 00 E9 48 B0 DE FF CC CC CC CC CC CC CC CC"},
};

const ApcSignature* apc_present_signatures(int exe, int* count)
{
    *count = exe ? (int)(sizeof kExeSignatures / sizeof kExeSignatures[0])
                 : (int)(sizeof kSignatures / sizeof kSignatures[0]);
    return exe ? kExeSignatures : kSignatures;
}

static struct
{
    SetTextureFn set_texture;
    SetUvFn set_uv;
    SetSizeFn set_size;
    SetAlphaFn set_alpha;
    MaterialFn material;
    RegisterImageFn register_image;
    CreateFn create;
    DestroyFn destroy;
    RegisterFn register_texture;
    int binding_count;
    int has_reference, verified, dropped;
    uint64_t reference;
    int shown_count;
    int shown[APC_TEXTURES];
    int has_backup, backup_texture;
    uintptr_t backup_context, backup_manager;
    size_t backup_request_size;
    uint8_t backup_layout[APC_LAYOUT];
} g;

static ApcTexture g_textures[APC_TEXTURES];
static ApcWidget g_bindings[BINDINGS];
static ApcWidget g_keep[BINDINGS];          /* reconcile's kept bindings, committed when it completes */
static uint8_t g_backupRequest[APC_CAPTURE_MAX];
static ApcImageSnap g_restoreSnap;          /* restore_working's own snapshot (the caller's stays as it was) */

ApcTexture* apc_texture(int index) { return index >= 0 && index < APC_TEXTURES ? &g_textures[index] : NULL; }

void apc_present_reset(void)
{
    memset(&g, 0, sizeof g);
    memset(g_textures, 0, sizeof g_textures);
}

static int AppPointer(uintptr_t app, uint32_t offset, uint32_t rva)
{
    uint64_t value = 0;
    if (!apc_need(app + offset, &value, 8, "Image memory unavailable")) return 0;
    return ApcPlausible(value) && value == vpm_exe() + rva ? 1 : apc_fail("Image application API mismatch");
}

/* image_native.lua M.new's checks after its code bytes (the core's wait): the engine API root, the application API's
 * three slots and the texture format size. */
int apc_present_init(void)
{
    uintptr_t root = ApcGamePointer(APC_RVA_ROOT_API);
    if (!root) return apc_fail("assertion failed!");
    if (root != vpm_exe() + APC_EXE_ROOT_API) return apc_fail("Image API root mismatch");
    uint64_t app = 0;
    if (!apc_need(root + 16, &app, 8, "Image memory unavailable")) return 0;
    if (!ApcPlausible(app)) return apc_fail("assertion failed!");
    if (!AppPointer((uintptr_t)app, 368, APC_EXE_CREATE) || !AppPointer((uintptr_t)app, 400, APC_EXE_DESTROY) ||
        !AppPointer((uintptr_t)app, 528, APC_EXE_REGISTER))
        return 0;
    uint32_t format = 0;
    if (!vpm_exe_read(APC_EXE_FORMAT_SIZE, &format, 4)) return apc_fail("Image memory unavailable");
    if (format != 32) return apc_fail("Unexpected texture format size");
    uintptr_t game = vpm_game(), exe = vpm_exe();
    g.set_texture = (SetTextureFn)(game + APC_RVA_SET_TEXTURE);
    g.set_uv = (SetUvFn)(game + APC_RVA_SET_UV);
    g.set_size = (SetSizeFn)(game + APC_RVA_SET_SIZE);
    g.set_alpha = (SetAlphaFn)(game + APC_RVA_SET_ALPHA);
    g.material = (MaterialFn)(game + APC_RVA_MATERIAL);
    g.register_image = (RegisterImageFn)(game + APC_RVA_REGISTER_IMAGE);
    g.create = (CreateFn)(exe + APC_EXE_CREATE);
    g.destroy = (DestroyFn)(exe + APC_EXE_DESTROY);
    g.register_texture = (RegisterFn)(exe + APC_EXE_REGISTER);
    return 1;
}

/* ---- small reads ------------------------------------------------------------------------------------------------ */

static int Read64(uintptr_t address, uint64_t* value) { return apc_need(address, value, 8, "Image memory unavailable"); }

static int ReadByte(uintptr_t address, uint8_t* value) { return apc_need(address, value, 1, "Image memory unavailable"); }

/* image_native.lua ptr(p): the pointer stored at p (the read must work), 0 when not plausible. */
static int ReadPointer(uintptr_t address, uintptr_t* pointer)
{
    uint64_t value = 0;
    if (!Read64(address, &value)) return 0;
    *pointer = ApcPlausible(value) ? (uintptr_t)value : 0;
    return 1;
}

static void Store8(uintptr_t address, uint8_t value) { *(volatile uint8_t*)address = value; }

static void SetTexture(uintptr_t element, uintptr_t texture) { g.set_texture((void*)element, APC_TEXTURE_SLOT, (void*)texture); }

/* The working atlas: [thumbnail manager + 11112], 0 when there is no manager or no atlas. */
static int WorkingAtlas(uintptr_t* atlas)
{
    uintptr_t tm = ApcGamePointer(APC_RVA_GLOBALS);
    *atlas = 0;
    return tm == 0 || ReadPointer(tm + APC_AT_ATLAS, atlas);
}

/* ---- bindings ----------------------------------------------------------------------------------------------------- */

static int FindBinding(uintptr_t widget)
{
    for (int i = 0; i < g.binding_count; i++)
        if (g_bindings[i].widget == widget) return i;
    return -1;
}

/* The controller the dispatch registers for kind (0 none); two are an error. */
static int Dispatched(uintptr_t d, uint32_t kind, uintptr_t* owner)
{
    static uint8_t rows[64 * 16];
    uint32_t n = 0;
    if (!apc_need(d + 5740, &n, 4, "Image memory unavailable")) return 0;
    if (n > 64) return apc_fail("Image dispatch bounds");
    if (n > 0 && !apc_need(d + 5744, rows, n * 16u, "Image memory unavailable")) return 0;
    for (uint32_t i = 0; i < n; i++)
    {
        if (ApcU32(rows, i * 16 + 8) != kind) continue;
        if (*owner) return apc_fail("Ambiguous image controller");
        *owner = ApcPointer(rows, i * 16);
    }
    return 1;
}

/* The screen's controller as the stack and the dispatch show it now: owner (0 none) and kind (0 none). */
static int Controller(uintptr_t* owner, uint32_t* kind)
{
    *owner = 0;
    *kind = 0;
    uintptr_t sm = ApcGamePointer(APC_RVA_STATE_MACHINE);
    if (!sm) return 1;
    uint32_t stack[6];
    if (!apc_need(sm + 0x429C, stack, 24, "Image memory unavailable")) return 0;
    uint32_t depth = stack[5], top = depth >= 1 && depth <= 5 ? stack[depth - 1] : 0;
    uint32_t found = top == 5 ? 224 : top == 14 ? 229 : 0;
    uintptr_t d = ApcGamePointer(APC_RVA_DISPATCH);
    if (!found || !d) return 1;
    if (!Dispatched(d, found, owner)) return 0;
    *kind = found;
    return 1;
}

/* Whether the binding's widget still shows its record, and that record is still ours: 1 checked (*owned, *record set),
 * 0 error. */
static int Owned(const ApcWidget* b, uint64_t current, int* owned, uintptr_t* record)
{
    uint64_t visual = 0, indices = 0;
    uint8_t invalidated = 1, bound = 0;
    *owned = 0;
    *record = ApcPlausible(current) ? (uintptr_t)current : 0;
    if (current != b->record_pointer || !*record) return 1;
    if (!Read64(*record, &visual)) return 0;
    if (visual != b->visual) return 1;
    if (!Read64(*record + 60, &indices)) return 0;
    if (indices != b->indices) return 1;
    if (!ReadByte(*record + 68, &invalidated)) return 0;
    if (invalidated != 0) return 1;
    if (!ReadByte(b->widget + 2005, &bound)) return 0;
    *owned = bound != 0;
    return 1;
}

/* One binding: 1 kept or released (*kept), 0 error. Fixed embedded widget offsets are valid only while this exact
 * controller remains registered: a departed UI is never dereferenced. */
static int Reconcile1(const ApcWidget* b, int clear, uintptr_t owner, uint32_t kind, uintptr_t world, uintptr_t atlas, int* kept)
{
    *kept = 0;
    if (owner != b->owner || kind != b->controller_kind || world != b->world || !atlas) return 1;
    uint64_t current = 0, material = 0;
    uint32_t flags = 0;
    if (!Read64(b->widget + 1984, &current) || !apc_need(b->element, &flags, 4, "Image memory unavailable") ||
        !Read64(b->element + 328, &material))
        return 0;
    /* Briefing keeps its controller and widgets while retiring their materials on picker entry. The texture setter clones
     * this material unconditionally: a cleared pointer crashes natively. A replacement material ends our ownership. */
    if ((flags & 0x3C0000u) != 0xC0000u || !ApcPlausible(material) || material != b->material_pointer) return 1;
    int owned;
    uintptr_t record;
    if (!Owned(b, current, &owned, &record)) return 0;
    if (!clear && owned) { *kept = 1; return 1; }
    /* Our texture comes off before any detached atlas is freed; an old transparent snapshot is never restored. */
    SetTexture(b->element, atlas);
    if (clear && owned)
    {
        Store8(record + 68, 1);
        g.set_alpha((void*)b->element, 0.0f);
        g.set_alpha((void*)(b->widget + 616), 1.0f);
    }
    return 1;
}

/* Releases the bindings that are no longer ours (all of them with clear): how many, or -1 on error. */
static int Reconcile(int clear)
{
    if (g.binding_count == 0) return 0;
    uintptr_t owner, world = 0, atlas = 0;
    uint32_t kind;
    if (!Controller(&owner, &kind)) return -1;
    uintptr_t ui = ApcGamePointer(APC_RVA_UI);
    if (ui && !ReadPointer(ui + 15432, &world)) return -1;
    if (!WorkingAtlas(&atlas)) return -1;
    int keep = 0, released = 0;
    for (int i = 0; i < g.binding_count; i++)
    {
        int kept;
        if (!Reconcile1(&g_bindings[i], clear, owner, kind, world, atlas, &kept)) return -1;
        if (kept) g_keep[keep++] = g_bindings[i];
        else released++;
    }
    memcpy(g_bindings, g_keep, (size_t)keep * sizeof g_bindings[0]);
    g.binding_count = keep;
    return released;
}

int apc_present_bound(void) { return g.binding_count > 0; }

/* The idle gate: no binding to check and no released binding the next tick must follow up. */
int apc_present_quiet(void) { return g.binding_count == 0 && !g.dropped; }

/* Before the game update. The bindings depend only on state the refresh covers, so they are checked on the first prune
 * after a full snapshot and whenever the refresh sees a change since that snapshot; otherwise the per-binding reads are
 * skipped. This is the frame's second state check (the first is the image tick's); it runs only while images are bound.
 * lint: per-frame */
int apc_present_prune(void)
{
    if (g.binding_count == 0) return 1;
    if (g.verified && g.has_reference)
    {
        apc_state_refresh();
        if (apc_state()->image_version == g.reference) return 1;
    }
    int released = Reconcile(0);
    if (released < 0) return 0;
    if (released > 0) g.dropped = 1;
    g.verified = 1;
    return 1;
}

/* After the game update: one refresh; 1 when nothing the last full snapshot decoded has changed and no binding was
 * released since. lint: per-frame */
int apc_present_unchanged(void)
{
    apc_state_refresh();
    return g.has_reference && apc_state()->image_version == g.reference && !g.dropped;
}

/* fresh: decode what unchanged() just read (nothing ran in between); otherwise the state is read again, which also
 * records the component's own writes since. */
int apc_present_snapshot(int fresh, ApcImageSnap* out)
{
    if (!fresh) apc_state_refresh();
    if (!apc_decode(out)) return 0;
    g.reference = apc_state()->image_version;
    g.has_reference = 1;
    g.verified = g.dropped = 0;
    return 1;
}

/* ---- textures ------------------------------------------------------------------------------------------------------ */

static int InShown(int index)
{
    for (int i = 0; i < g.shown_count; i++)
        if (g.shown[i] == index) return 1;
    return 0;
}

/* A texture record nothing refers to any more (the image cache, the idle backup, the last apply's ownership list). */
static int FreeTexture(void)
{
    for (int i = 0; i < APC_TEXTURES; i++)
        if (!g_textures[i].listed && !(g.has_backup && g.backup_texture == i) && !InShown(i)) return i;
    return -1;
}

static int DestroyOwned(ApcTexture* t)
{
    if (t->destroyed || t->returned) return 1;
    uintptr_t tm = ApcGamePointer(APC_RVA_GLOBALS), atlas = 0;
    if (tm && !ReadPointer(tm + APC_AT_ATLAS, &atlas)) return 0;
    if (tm && atlas == t->handle) return apc_fail("Refusing to release the game working atlas");
    uint64_t id = 0;
    if (!Read64(t->handle, &id)) return 0;
    if (id != t->id) return apc_fail("Retained texture identity changed");
    g.destroy((void*)t->handle);
    t->destroyed = 1;
    return 1;
}

/* Idle retention leaves a blank replacement behind native state-8 cards. If those exact requests are still current during
 * disable or pressure cleanup, the real pixels go back to native ownership first. A different request, manager or layout
 * already owns its own generation. */
static int RestoreWorking(void)
{
    if (!g.has_backup) return 1;
    ApcTexture* t = &g_textures[g.backup_texture];
    if (t->destroyed || t->returned) return 1;
    ApcImageSnap* s = &g_restoreSnap;
    if (!apc_present_snapshot(0, s)) return 0;
    if (s->atlas != t->replacement || s->context != g.backup_context || s->manager != g.backup_manager ||
        s->capture_size != g.backup_request_size || memcmp(s->capture, g_backupRequest, s->capture_size) != 0 ||
        memcmp(s->layout, g.backup_layout, APC_LAYOUT) != 0 || !s->complete)
    {
        g.has_backup = 0;
        return 1;
    }
    uint64_t id = 0;
    if (!Read64(t->handle, &id)) return 0;
    if (id != t->id) return apc_fail("Idle backup texture identity changed");
    g.register_texture(APC_ATLAS_NAME, (void*)t->handle);
    *(volatile uint64_t*)(s->manager + APC_AT_ATLAS) = (uint64_t)t->handle;
    for (int i = 0; i < s->registry_count; i++) SetTexture(s->registry[i], t->handle);
    t->returned = 1;
    g.destroy((void*)t->replacement);
    apc_blank_clear();
    g.has_backup = 0;
    return 1;
}

int apc_present_restore(int returnWorking)
{
    if (returnWorking && !RestoreWorking()) return 0;
    return Reconcile(1) >= 0;
}

int apc_present_destroy(int index)
{
    ApcTexture* t = apc_texture(index);
    if (t == NULL || t->retired || t->destroyed) return 1;
    if (!DestroyOwned(t)) return 0;
    t->retired = 1;
    return 1;
}

/* The textures the last apply checked. A tick the gate skips checks them again (one 8-byte read each), as apply did
 * every frame. lint: per-frame */
int apc_present_check_textures(void)
{
    for (int i = 0; i < g.shown_count; i++)
    {
        const ApcTexture* t = &g_textures[g.shown[i]];
        uint64_t id = 0;
        if (!t->destroyed && !t->returned && !Read64(t->handle, &id)) return 0;
        if (t->destroyed || t->returned || id != t->id) return apc_fail("Cached texture ownership changed");
    }
    return 1;
}

/* ---- capture and freeze ------------------------------------------------------------------------------------------- */

static int Descriptor(uintptr_t atlas, uint64_t* id, uint32_t* w, uint32_t* h)
{
    static uint32_t d[26];
    if (!apc_need(atlas, d, 104, "Image memory unavailable")) return 0;
    if (d[2] != 0 || d[3] != 0 || d[7] != 1 || d[8] != 1 || ((const uint8_t*)d)[99] != 1)
        return apc_fail("Unsupported thumbnail texture descriptor");
    *w = d[5];
    *h = d[6];
    if (*w < 64 || *h < 64 || *w > 4096 || *h > 16384) return apc_fail("Thumbnail dimensions exceed bounds");
    *id = ApcU64(d, 0);
    return 1;
}

static ApcCrop* CandidateCrop(ApcCandidate* p, const ApcKey* key)
{
    for (int i = 0; i < p->crop_count; i++)
        if (apc_key_equal(&p->crops[i].key, key)) return &p->crops[i];
    return p->crop_count < APC_CANDIDATE_CROPS ? &p->crops[p->crop_count++] : NULL;
}

/* One completed item's crop: the recovered 0x10F0CB0 crop formula. */
static int Crop(const ApcImageSnap* s, const ApcItem* item, ApcCrop* c)
{
    const uint8_t* r = item->input + 56;
    double tw = s->tile_width, th = s->tile_height;
    double x = (double)ApcF32(r, 0) + 1 / tw;
    double y = (1 - (double)ApcF32(r, 4) - (double)ApcF32(r, 12)) / 6 + (double)item->card / 6 + 1 / th;
    double w = (double)ApcF32(r, 8) - 2 / tw;
    double h = (double)ApcF32(r, 12) / 6 - 2 / th;
    if (!(ApcFinite(x) && ApcFinite(y) && w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= 1.001 && y + h <= 1.001))
        return apc_fail("Invalid completed image rectangle");
    float uv[4] = {(float)x, (float)y, (float)(x + w), (float)(y + h)};
    memset(c, 0, sizeof *c);
    c->key = item->key;
    memcpy(c->uv, uv, 16);
    c->width = w * tw;
    c->height = h * th * 6;
    c->texture = -1;
    uint8_t size = 0;
    const uint8_t* slots = apc_preview_slots(item->preview, &size);
    if (slots != NULL)
    {
        c->has_preview = 1;
        c->preview_size = size;
        memcpy(c->preview, slots, size);
    }
    return 1;
}

/* The completed cards' crops of the screen's items (state 8 is the native per-card completion contract; other cards can
 * still be generating, so their pixels never enter it). p->present 0 when there is nothing to keep. */
int apc_present_capture(const ApcImageSnap* s, ApcCandidate* p)
{
    p->present = 0;
    if (s->widget_count == 0 || s->item_count == 0) return 1;
    p->atlas = s->atlas;
    memcpy(p->layout, s->layout, APC_LAYOUT);
    p->bytes = s->bytes;
    p->descriptor_id = s->descriptor_id;
    p->crop_count = 0;
    for (int i = 0; i < s->item_count; i++)
    {
        const ApcItem* item = &s->slots[s->items[i]];
        if (!item->ready || !item->pixels_ready) continue;
        ApcCrop crop;
        if (!Crop(s, item, &crop)) return 0;
        ApcCrop* slot = CandidateCrop(p, &item->key);
        if (slot != NULL) *slot = crop;
    }
    p->present = p->crop_count > 0;
    return 1;
}

static int Handoff(const ApcImageSnap* s, const ApcCandidate* p)
{
    int same = (s->can_freeze_idle || s->can_freeze_rebind || s->can_freeze_visible) && p->request_size == s->capture_size &&
        memcmp(p->request, s->capture, s->capture_size) == 0;
    if (!(s->can_freeze || same) || s->atlas != p->atlas || memcmp(s->layout, p->layout, APC_LAYOUT) != 0)
        return apc_fail("Unsafe atlas handoff");
    uintptr_t atlas = 0;
    if (ApcGamePointer(APC_RVA_GLOBALS) != s->manager) return apc_fail("Atlas owner changed");
    if (!ReadPointer(s->manager + APC_AT_ATLAS, &atlas)) return 0;
    return atlas == p->atlas ? 1 : apc_fail("Atlas owner changed");
}

static void KeepBackup(const ApcImageSnap* s, int index, uintptr_t fresh)
{
    uint64_t f = fresh;
    g.has_backup = 1;
    g.backup_texture = index;
    g.backup_context = s->context;
    g.backup_manager = s->manager;
    memcpy(g_backupRequest, &f, 8);
    memcpy(g_backupRequest + 8, s->capture + 8, s->capture_size - 8);
    g.backup_request_size = s->capture_size;
    memcpy(g.backup_layout, s->layout, APC_LAYOUT);
}

/* The handoff: the same API and six arguments as the native atlas creator. Command 14 creates the replacement before
 * command 31 registers it for later draws. Every registered consumer, hidden leftovers included, is rebound before the
 * old atlas can become independently releasable; apply restores the retained crops in this same tick. The game owns
 * fresh and destroys it normally; only the detached original is ours, never returned to the working slot. */
int apc_present_freeze(const ApcImageSnap* s, const ApcCandidate* p, int* texture)
{
    *texture = -1;
    if (!Handoff(s, p)) return 0;
    uint64_t id;
    uint32_t w, h;
    if (!Descriptor(p->atlas, &id, &w, &h)) return 0;
    if (id != p->descriptor_id) return apc_fail("Atlas generation changed");
    int index = FreeTexture();
    if (index < 0) return apc_fail("No texture record free");
    void* created = g.create((int)w, (int)h, 1, 0, APC_ATLAS_NAME, 1);
    if (created == NULL) return 1;
    uintptr_t fresh = (uintptr_t)created;
    g.register_texture(APC_ATLAS_NAME, created);
    *(volatile uint64_t*)(s->manager + APC_AT_ATLAS) = (uint64_t)fresh;
    for (int i = 0; i < s->registry_count; i++) SetTexture(s->registry[i], fresh);
    uint64_t freshId = 0;
    if (!Read64(fresh, &freshId)) return 0;
    ApcTexture* t = &g_textures[index];
    memset(t, 0, sizeof *t);
    t->listed = 1;
    t->handle = p->atlas;
    t->replacement = fresh;
    t->bytes = p->bytes;
    t->id = p->descriptor_id;
    t->width = w;
    t->height = h;
    apc_blank_set(s, fresh, freshId);
    if (s->can_freeze_idle && p->request_size == s->capture_size && memcmp(p->request, s->capture, s->capture_size) == 0)
        KeepBackup(s, index, fresh);
    else
        g.has_backup = 0;
    *texture = index;
    return 1;
}

/* ---- apply ------------------------------------------------------------------------------------------------------- */

static int CheckOwnership(int index, uint8_t* checked)
{
    if (checked[index]) return 1;
    const ApcTexture* t = &g_textures[index];
    uint64_t id = 0;
    if (t->destroyed || t->returned) return apc_fail("Cached texture ownership changed");
    if (!Read64(t->handle, &id)) return 0;
    if (id != t->id) return apc_fail("Cached texture ownership changed");
    checked[index] = 1;
    g.shown[g.shown_count++] = index;
    return 1;
}

/* Freshly recreated widgets still reference the named thumbnail template: the private material is cloned through the
 * normal native contract before our texture is bound. A missing template may leave initialization without a material:
 * the native texture setter is not entered then. */
static int InitializeTile(const ApcWidget* w)
{
    uintptr_t tm = ApcGamePointer(APC_RVA_GLOBALS), material = 0;
    uint32_t registered = 0;
    if (!tm) return apc_fail("assertion failed!");
    if (!apc_need(tm + APC_AT_REGISTRY, &registered, 4, "Image memory unavailable")) return 0;
    if (registered >= 128) return apc_fail("Image registration full");
    g.material((void*)w->element, IMAGE_MATERIAL, 1);
    if (!ReadPointer(w->element + 328, &material)) return 0;
    if (!material) return 1;
    g.register_image((void*)tm, (void*)w->element);
    /* This byte means the UI has an image, not that the native card finished. Native destruction unregisters it; new
     * requests invalidate it through record + 68. */
    Store8(w->widget + 2005, 1);
    if (!ApcPlausible(w->record_pointer)) return apc_fail("assertion failed!");
    Store8((uintptr_t)w->record_pointer + 68, 0);
    return 1;
}

static int Bind(const ApcWidget* w, const ApcCrop* crop, double ratio, ApcApplied* r)
{
    uint64_t material = 0;
    if (!Read64(w->element + 328, &material)) return 0;
    int at = FindBinding(w->widget);
    if (!ApcPlausible(material) || (at < 0 && g.binding_count >= BINDINGS))
    {
        r->misses++;
        r->unresolved++;
        return 1;
    }
    SetTexture(w->element, g_textures[crop->texture].handle);
    /* The setter can privatize a shared material: the final instance is tracked, not the one from before the call. */
    ApcWidget binding = *w;
    if (!Read64(w->element + 328, &binding.material_pointer)) return 0;
    if (at < 0) at = g.binding_count++;
    g_bindings[at] = binding;
    uint64_t uv[2];
    memcpy(uv, crop->uv, 16);
    g.set_uv((void*)w->element, uv[0], uv[1]);
    float size[2] = {(float)(crop->width / ratio), (float)(crop->height / ratio)};
    uint64_t packed;
    memcpy(&packed, size, 8);
    g.set_size((void*)w->element, packed);
    g.set_alpha((void*)(w->widget + 616), 0.0f);
    g.set_alpha((void*)w->element, 1.0f);
    r->hits++;
    if (!w->native_ready) r->early++;
    return 1;
}

/* The crop's scale on the tile's box: fit 1 contains, 2 fits the height, 3 the width. */
static double Ratio(const ApcCrop* crop, const ApcWidget* w)
{
    double a = crop->width / w->box_width, b = crop->height / w->box_height;
    if (w->fit == 1) return a > b ? a : b;
    return w->fit == 2 ? b : a;
}

static int ApplyWidget(const ApcWidget* w, ApcApplied* r, uint8_t* checked)
{
    const ApcCrop* crop = apc_crop_find(&w->key);
    if (crop == NULL || !(w->box_width > 0 && w->box_height > 0 && w->fit >= 1 && w->fit <= 3))
    {
        r->misses++;
        if (crop != NULL) r->unresolved++;
        return 1;
    }
    double ratio = Ratio(crop, w);
    if (!(ApcFinite(ratio) && ratio > 0)) { r->unresolved++; return 1; }
    if (!CheckOwnership(crop->texture, checked)) return 0;
    if (!w->bound || w->invalidated || w->named_material)
    {
        r->initialized++;
        if (!InitializeTile(w)) return 0;
    }
    return Bind(w, crop, ratio, r);
}

/* One binding whose crop the cache no longer holds (the weapon was re-configured, or the crop evicted): handed back to
 * the native pipeline, whose own render shows as soon as it is composed. The record is the one the widget showed before
 * the texture call; the checks after it read the widget again, as the Lua did. */
static int Unbind(const ApcWidget* b, uintptr_t atlas)
{
    uint64_t first = 0, material = 0, again = 0, visual = 0, indices = 0;
    uint8_t bound = 0;
    if (!Read64(b->widget + 1984, &first) || !Read64(b->element + 328, &material)) return 0;
    if (material != b->material_pointer) return 1;
    SetTexture(b->element, atlas);
    uintptr_t record = ApcPlausible(first) ? (uintptr_t)first : 0;
    if (!record) return 1;
    if (!Read64(b->widget + 1984, &again)) return 0;
    if (again != b->record_pointer) return 1;
    if (!Read64(record, &visual)) return 0;
    if (visual != b->visual) return 1;
    if (!Read64(record + 60, &indices)) return 0;
    if (indices != b->indices) return 1;
    if (!ReadByte(b->widget + 2005, &bound)) return 0;
    if (bound == 0) return 1;
    Store8(record + 68, 1);
    g.set_alpha((void*)b->element, 0.0f);
    g.set_alpha((void*)(b->widget + 616), 1.0f);
    return 1;
}

static int UnbindStale(const ApcImageSnap* s)
{
    uintptr_t atlas = 0;
    if (!WorkingAtlas(&atlas)) return 0;
    if (!atlas) return 1;
    for (int i = 0; i < g.binding_count;)
    {
        const ApcWidget* b = &g_bindings[i];
        if (apc_crop_find(&b->key) != NULL || b->world != s->world || b->owner != s->owner) { i++; continue; }
        if (!Unbind(b, atlas)) return 0;
        g_bindings[i] = g_bindings[--g.binding_count];
    }
    return 1;
}

/* Binds the cached crops to the screen's tiles. unresolved counts tiles with a crop that stayed unbound (fit, ratio or
 * material not usable yet; retried by the next full tick); initialized counts tiles whose material and registration this
 * apply made (those writes change what the next snapshot decodes). */
int apc_present_apply(const ApcImageSnap* s, ApcApplied* r)
{
    uint8_t checked[APC_TEXTURES] = {0};
    memset(r, 0, sizeof *r);
    g.shown_count = 0;
    for (int i = 0; i < s->widget_count; i++)
        if (!ApplyWidget(&s->widgets[i], r, checked)) return 0;
    return UnbindStale(s);
}
