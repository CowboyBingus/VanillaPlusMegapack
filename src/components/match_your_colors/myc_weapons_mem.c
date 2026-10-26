/* Match Your Colors: the Helldiver's weapons in game memory (weapons.lua, Recolor Weapons v1.5), 1:1. Inventory
 * [game + 0x3326738]: the map +40 from an avatar's entity id to its row, rows [+80] of 48 bytes (+0 primary, +4 sidearm,
 * +8 support: entity ids; +28 the slot in hand), each row's entity [+64]. Entities [game + 0x346BF98]: the map
 * +0xF1AEB0 to records +0xF32F18 + 24 e (+0 resource, +12 unit). Weapon customization [game + 0x3326A38]: the map +632
 * to its record [+672] + 128 j (attachment units), the map +696 to the weapon's own copy [+760] + 4872 k (attachments'
 * unit names and the MaterialOverride). Weapon catalogue [entities + 0xF12558] (packages). The Armory's preview weapon
 * in UiPreviewSystem weapon slot 3. Reads only: on changes (game thread) and inside jobs (worker). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "myc_weapon_mem.h"

#define INVENTORY 0x3326738u
#define ENTITIES 0x346BF98u
#define CUSTOMIZATION 0x3326A38u
#define I_MAP 40
#define I_OWNERS 64
#define I_ROWS 80
#define CURRENT 28
#define I_HEAD 16
#define I_COUNT 20
#define E_MAP 0xF1AEB0u
#define E_RECORDS 0xF32F18u
#define E_CATALOGUE 0xF12558u
#define C_MAP 632
#define C_RECORDS 672
#define C_RECORD_BYTES 128
#define C_INSTANCES 696
#define C_COPIES 760
#define COPY_BYTES 4872
#define CATALOGUE_BUCKETS 1080
#define CATALOGUE_RECORDS 17280
#define ATTACHMENTS 0x78
#define OVERRIDE 200
#define KIND_ENTRY 408
#define KINDS 10
#define UNDERBARREL_ENTITY 100
#define MAX_ROWS 4096
#define UPS 0x347CE60u
#define PREVIEW_SLOT 3
#define UPS_WEAPONS 76056
#define UPS_WEAPON_BYTES 1560
#define SLOT_READ 232
#define CONFIG_COUNT 144
#define CONFIG_IDS 152
#define MAX_IDS 10
#define PAIRED 8
#define TYPE_BUCKETS 382
#define TYPES 0xF12CF0u
#define TYPE_BASE 0x17E0u
#define DELTAS 0xF12E98u
#define PAINT_TYPE 271u

static const int kMycSlots[4] = {0, 0, 4, 8};
static const int kMycRecordUnits[5] = {8, 12, 40, 68, 96};
static const uint32_t kMycRoleKind[5] = {0, 2, 5, 4, 1};
static const int kMycRoleNameAt[5] = {0, 0x78, 0x80, 0xA0, 0xC0};

static uint32_t MycWpLe32(const uint8_t* p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t MycWpLe64(const uint8_t* p) { return MycWpLe32(p) | (uint64_t)MycWpLe32(p + 4) << 32; }
static int MycWpUnitId(uint32_t v) { return v != 0 && v != 0xFFFFFFFFu; }

/* Avatar.reader's read (0x10000 .. 2^47, at most 256 bytes). */
static int MycWpRead(uintptr_t address, void* out, size_t size)
{
    if (address < 0x10000 || address >= 0x800000000000ull || size > 256) return 0;
    return vpm_read(address, out, size);
}

static uintptr_t MycWpPointer(uintptr_t address)
{
    uint8_t b[8];
    if (!MycWpRead(address, b, 8)) return 0;
    uint64_t v = MycWpLe64(b);
    return v < 0x10000 || v >= 0x800000000000ull ? 0 : (uintptr_t)v;
}

int myc_weapons_locate(uint32_t avatar, int owned, MycInventoryWhere* out)
{
    memset(out, 0, sizeof *out);
    uintptr_t inventory = MycWpPointer(vpm_game() + INVENTORY);
    uint32_t index;
    if (inventory == 0 || !myc_avatar_lookup(inventory + I_MAP, avatar, &index) || index >= MAX_ROWS) return 0;
    uintptr_t rows = MycWpPointer(inventory + I_ROWS);
    if (rows == 0) return 0;
    out->inventory = inventory;
    out->rows = rows;
    out->row = rows + (uintptr_t)MYC_INVENTORY_ROW * index;
    out->avatar = avatar;
    out->index = index;
    out->owners = owned ? MycWpPointer(inventory + I_OWNERS) : 0;
    out->owner = out->owners != 0 ? MycWpPointer(out->owners + 8 * (uintptr_t)index) : 0;
    return 1;
}

int myc_weapons_owned(const MycInventoryWhere* where)
{
    if (where->owner == 0) return 1;
    uint8_t head[I_ROWS + 8 - I_HEAD];
    if (!vpm_read(where->inventory + I_HEAD, head, sizeof head) || where->index >= MycWpLe32(head + I_COUNT - I_HEAD)
        || MycWpLe64(head + I_OWNERS - I_HEAD) != where->owners || MycWpLe64(head + I_ROWS - I_HEAD) != where->rows)
        return 0;
    uint64_t owner;
    return vpm_read_u64(where->owners + 8 * (uintptr_t)where->index, &owner) && owner == where->owner;
}

/* ---- one weapon --------------------------------------------------------------------------------------------------- */

static int MycWpEntity(uintptr_t entities, uint32_t id, uint8_t out[24])
{
    uint32_t e;
    return myc_avatar_lookup(entities + E_MAP, id, &e) && MycWpRead(entities + E_RECORDS + 24 * (uintptr_t)e, out, 24)
        && MycWpLe32(out + 8) == id;
}

static void MycWpAddUnit(MycWeapon* w, uint32_t unit)
{
    if (w->nunits < MYC_WEAPON_UNITS) w->units[w->nunits++] = unit;
}

static void MycWpAttachmentUnits(uintptr_t entities, MycWeapon* w, const uint8_t* r)
{
    for (int i = 0; i < 5; i++)
    {
        uint32_t unit = MycWpLe32(r + kMycRecordUnits[i]);
        if (MycWpUnitId(unit) && unit != w->unit) MycWpAddUnit(w, unit);
    }
    uint32_t under = MycWpLe32(r + UNDERBARREL_ENTITY);
    uint8_t ub[24];
    if (MycWpUnitId(under) && MycWpEntity(entities, under, ub) && MycWpUnitId(MycWpLe32(ub + 12))) MycWpAddUnit(w, MycWpLe32(ub + 12));
}

static int MycWpRowLess(const void* x, const void* y) { return strcmp((const char*)x, (const char*)y); }

/* One block of 10 MaterialOverride rows at o of the copy span into paint (rows with a LUT or pattern of their own). */
static void MycWpOverrideRows(const uint8_t* big, int o, MycWeaponPaint* paint)
{
    char parts[MYC_OVERRIDE_ROWS][44];
    int nparts = 0;
    memset(paint, 0, sizeof *paint);
    paint->has = 1;
    for (int r = 0; r < MYC_OVERRIDE_ROWS; r++)
    {
        const uint8_t* p = big + o + 40 * r;
        uint32_t slot = MycWpLe32(p);
        uint64_t lut = MycWpLe64(p + 8), pattern = MycWpLe64(p + 24);
        if (slot == 0 || (lut == 0 && pattern == 0)) continue;
        int k = 0;
        while (k < paint->nrows && paint->rows[k].slot != slot) k++;
        if (k == paint->nrows) paint->nrows++;
        paint->rows[k] = (MycOverrideRow){slot, lut, pattern};
        snprintf(parts[nparts++], sizeof parts[0], "%08x=%016llx/%016llx", slot, (unsigned long long)lut, (unsigned long long)pattern);
    }
    qsort(parts, (size_t)nparts, sizeof parts[0], MycWpRowLess);
    size_t at = 0;
    for (int i = 0; i < nparts; i++) at += (size_t)snprintf(paint->text + at, sizeof paint->text - at, "%s%s", i ? " " : "", parts[i]);
}

void myc_weapons_decode_copy(MycWeapon* w, const uint8_t* big)
{
    for (int role = 1; role <= 4; role++)
    {
        uint64_t name = MycWpLe64(big + kMycRoleNameAt[role] - ATTACHMENTS);
        if (name != 0) w->attachments[role] = name;
    }
    MycWpOverrideRows(big, OVERRIDE - ATTACHMENTS, &w->overrides[0]);
    for (int e = 0; e < KINDS; e++)
    {
        int o = OVERRIDE + 400 + KIND_ENTRY * e - ATTACHMENTS;
        uint32_t kind = MycWpLe32(big + o);
        for (int role = 1; role <= 4; role++)
            if (kind == kMycRoleKind[role]) MycWpOverrideRows(big, o + 8, &w->overrides[role]);
    }
}

/* weapon_of: 1 with w, 0 when its entity is not found. big: COPY_SPAN bytes. */
static int MycWpWeaponOf(uint32_t id, uint8_t* big, MycWeapon* w)
{
    uintptr_t entities = MycWpPointer(vpm_game() + ENTITIES);
    uint8_t b[24];
    if (entities == 0 || !MycWpEntity(entities, id, b)) return 0;
    memset(w, 0, sizeof *w);
    w->id = id;
    w->name = MycWpLe64(b);
    w->unit = MycWpLe32(b + 12);
    uintptr_t wcm = MycWpPointer(vpm_game() + CUSTOMIZATION);
    uint32_t j, k;
    uint8_t r[C_RECORD_BYTES];
    uintptr_t records = wcm != 0 && myc_avatar_lookup(wcm + C_MAP, id, &j) ? MycWpPointer(wcm + C_RECORDS) : 0;
    if (records != 0 && MycWpRead(records + C_RECORD_BYTES * (uintptr_t)j, r, C_RECORD_BYTES)) MycWpAttachmentUnits(entities, w, r);
    uintptr_t copies = wcm != 0 && myc_avatar_lookup(wcm + C_INSTANCES, id, &k) ? MycWpPointer(wcm + C_COPIES) : 0;
    if (copies != 0 && vpm_read(copies + COPY_BYTES * (uintptr_t)k + ATTACHMENTS, big, MYC_COPY_SPAN))
    {
        w->copy = 1;
        myc_weapons_decode_copy(w, big);
    }
    return 1;
}

int myc_weapons_resolve(const MycInventoryWhere* where, uint8_t* big, MycResolved* out)
{
    uint8_t b[MYC_INVENTORY_ROW];
    if (!MycWpRead(where->row, b, MYC_INVENTORY_ROW)) return 0;
    memset(out, 0, sizeof *out);
    out->held = MycWpLe32(b + CURRENT);
    for (int slot = 1; slot <= 3; slot++)
    {
        uint32_t id = MycWpLe32(b + kMycSlots[slot]);
        out->ids[slot] = id;
        if (MycWpUnitId(id)) out->has[slot] = MycWpWeaponOf(id, big, &out->list[slot]);
    }
    return 1;
}

/* ---- packages, composition, kits ---------------------------------------------------------------------------------- */

uint64_t myc_weapons_package(uint64_t name, uint8_t* buffer)
{
    uintptr_t entities = MycWpPointer(vpm_game() + ENTITIES);
    uintptr_t table = entities != 0 ? MycWpPointer(entities + E_CATALOGUE) : 0;
    if (table == 0 || !vpm_read(table, buffer, CATALOGUE_RECORDS)) return 0;
    for (int i = 0; i < CATALOGUE_BUCKETS; i++)
    {
        const uint8_t* e = buffer + i * 16;
        if ((e[0] == 0 && e[7] == 0) || MycWpLe64(e) != name) continue;
        uint32_t index = MycWpLe32(e + 8);
        uint8_t r[32];
        if (index >= 540 || !MycWpRead(table + CATALOGUE_RECORDS + 32 * (uintptr_t)index, r, 32)) return 0;
        return MycWpLe64(r + 8);
    }
    return 0;
}

/* The index stored for an 8-byte id in a bucket table (16-byte buckets, n of them, probed from id % n). */
static int MycWpBucket(uintptr_t at, uint32_t n, uint64_t name, uint32_t* index)
{
    if (n == 0 || n > 65536) return 0;
    uint64_t start = name % n;
    for (uint32_t i = 0; i < (n < 256 ? n : 256); i++)
    {
        uint8_t b[16];
        if (!MycWpRead(at + 16 * (uintptr_t)((start + i) % n), b, 16)) return 0;
        uint64_t id = MycWpLe64(b);
        if (id == name) { *index = MycWpLe32(b + 8); return 1; }
        if (id == 0) return 0;
    }
    return 0;
}

typedef struct MycDeltas { uint64_t buckets, starts, ops, patches, data; uint32_t count; } MycDeltas;

static int MycWpPatch(const MycDeltas* t, uint32_t dest, uint32_t size, uint32_t src, uint8_t* big)
{
    uint64_t first = dest > ATTACHMENTS ? dest : ATTACHMENTS;
    uint64_t last = (uint64_t)dest + size < ATTACHMENTS + MYC_COPY_SPAN ? (uint64_t)dest + size : ATTACHMENTS + MYC_COPY_SPAN;
    if (first >= last) return 1;
    return vpm_read((uintptr_t)(t->data + src + (first - dest)), big + (first - ATTACHMENTS), (size_t)(last - first));
}

static int MycWpOp(const MycDeltas* t, const uint8_t* o, uint8_t* big)
{
    if (MycWpLe32(o) != PAINT_TYPE) return 1;
    uint32_t first = MycWpLe32(o + 4), count = MycWpLe32(o + 8);
    for (uint32_t p = first; p < first + (count < 256 ? count : 256); p++)
    {
        uint8_t q[12];
        if (!MycWpRead((uintptr_t)(t->patches + 12 * (uint64_t)p), q, 12)) return 0;
        if (!MycWpPatch(t, MycWpLe32(q), MycWpLe32(q + 4), MycWpLe32(q + 8), big)) return 0;
    }
    return 1;
}

static int MycWpId(const MycDeltas* t, uint64_t id, uint8_t* big)
{
    uint32_t i;
    uint8_t d[8];
    if (!MycWpBucket((uintptr_t)t->buckets, t->count, id, &i) || !MycWpRead((uintptr_t)(t->starts + 8 * (uint64_t)i), d, 8)) return 1;
    uint32_t first = MycWpLe32(d + 4), count = MycWpLe32(d);
    for (uint32_t op = first; op < first + (count < 64 ? count : 64); op++)
    {
        uint8_t o[12];
        if (MycWpRead((uintptr_t)(t->ops + 12 * (uint64_t)op), o, 12) && !MycWpOp(t, o, big)) return 0;
    }
    return 1;
}

int myc_weapons_compose(MycWeapon* w, uint8_t* big, const char** why)
{
    uintptr_t entities = MycWpPointer(vpm_game() + ENTITIES);
    uintptr_t types = entities != 0 ? MycWpPointer(entities + TYPES) : 0;
    uint32_t index;
    if (types == 0 || !MycWpBucket(types, TYPE_BUCKETS, w->name, &index)) { *why = "weapon type not found"; return 0; }
    if (!vpm_read(types + TYPE_BASE + COPY_BYTES * (uintptr_t)index + ATTACHMENTS, big, MYC_COPY_SPAN)) { *why = "weapon type unreadable"; return 0; }
    uintptr_t deltas = MycWpPointer(entities + DELTAS);
    uint8_t head[72];
    if (deltas == 0 || !MycWpRead(deltas, head, 72)) { *why = "customization deltas unreadable"; return 0; }
    MycDeltas t = {MycWpLe64(head), MycWpLe64(head + 16), MycWpLe64(head + 32), MycWpLe64(head + 48), MycWpLe64(head + 64),
                   MycWpLe32(head + 8)};
    for (int i = 0; i < w->nids; i++)
        if (!MycWpId(&t, w->ids[i], big)) { *why = "customization patch unreadable"; return 0; }
    w->copy = 1;
    myc_weapons_decode_copy(w, big);
    return 1;
}

int myc_weapons_preview(MycWeapon* out)
{
    uintptr_t ups = MycWpPointer(vpm_game() + UPS);
    uint8_t b[SLOT_READ];
    if (ups == 0 || !MycWpRead(ups + UPS_WEAPONS + UPS_WEAPON_BYTES * PREVIEW_SLOT, b, SLOT_READ) || !MycWpUnitId(MycWpLe32(b))) return 0;
    memset(out, 0, sizeof *out);
    out->unit = MycWpLe32(b);
    out->name = MycWpLe64(b + 128);
    out->has_ids = 1;
    for (int o = 4; o <= 120; o += 4)
        if (MycWpUnitId(MycWpLe32(b + o))) MycWpAddUnit(out, MycWpLe32(b + o));
    uint32_t count = MycWpLe32(b + CONFIG_COUNT);
    for (uint32_t i = 0; i < (count < MAX_IDS ? count : MAX_IDS); i++) out->ids[out->nids++] = MycWpLe64(b + CONFIG_IDS + 8 * i);
    if (MycWpRead(ups + UPS_WEAPONS + UPS_WEAPON_BYTES * (PREVIEW_SLOT + PAIRED), b, SLOT_READ))
        for (int o = 0; o <= 120; o += 4)
            if (MycWpUnitId(MycWpLe32(b + o))) MycWpAddUnit(out, MycWpLe32(b + o));
    return 1;
}

void myc_weapons_preview_key(const MycWeapon* w, char* out, size_t size)
{
    size_t at = (size_t)snprintf(out, size, "%016llx:", (unsigned long long)w->name);
    for (int i = 0; i < w->nids && at < size; i++)
        at += (size_t)snprintf(out + at, size - at, "%s%016llx", i ? "," : "", (unsigned long long)w->ids[i]);
}

int myc_weapons_units(const MycWeapon* const* list, MycUnitRef* out, int max)
{
    int n = 0;
    for (int slot = 1; slot <= 3; slot++)
    {
        const MycWeapon* w = list[slot];
        if (w == NULL) continue;
        if (MycWpUnitId(w->unit) && n < max) out[n++] = (MycUnitRef){w->unit, 0, 0, 0, 1, 0, slot};
        for (int i = 0; i < w->nunits && n < max; i++) out[n++] = (MycUnitRef){w->units[i], 0, 0, 0, 1, 1, slot};
    }
    return n;
}

/* ---- the watch ---------------------------------------------------------------------------------------------------- */

void myc_inventory_watch_init(MycInventoryWatch* w, const MycInventoryWhere* where)
{
    memset(w, 0, sizeof *w);
    w->row = where->row;
}

/* lint: per-frame */
int myc_inventory_row_changed(MycInventoryWatch* w)
{
    w->reads++;
    if (!vpm_read(w->row, w->now, MYC_INVENTORY_ROW)) return 1;
    int same = w->primed && memcmp(w->now, w->kept, 12) == 0 && memcmp(w->now + CURRENT, w->kept + CURRENT, 4) == 0;
    if (same) return 0;
    memcpy(w->kept, w->now, MYC_INVENTORY_ROW);
    w->primed = 1;
    return 1;
}

uint32_t myc_inventory_held(const MycInventoryWatch* w) { return MycWpLe32(w->kept + CURRENT); }

/* lint: per-frame */
int myc_inventory_bound(MycInventoryWatch* w, uint64_t entry, uint64_t texture)
{
    w->reads++;
    uint64_t cell;
    return vpm_read_u64((uintptr_t)entry, &cell) && cell == texture;
}
