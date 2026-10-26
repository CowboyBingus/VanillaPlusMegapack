/* Match Your Colors: the UI preview Helldivers (preview.lua), 1:1: the UiPreviewSystem [game + 0x347CE60] player slots
 * 0-3 (records +49160 + 160 s: +12 / +52 / +92 three arrays of 10 piece unit refs, +136 body, +140 armor, +144 helmet,
 * +148 cape shown), its occupied count +50440 and mask +50444, and the weapon preview ring's head +50448. The watch reads
 * the 16-byte gate alone while no player slot shows, else the span from slot 0's record to the ring (1,296 bytes) in one
 * read. Game thread; reads only; no allocation per call. */
#include <string.h>
#include "myc_runtime.h"

#define SLOTS 49160
#define GATE 50440
#define UNITS 12
#define UNITS_END (UNITS + 120)
#define BODY 136
#define ARMOR 140
#define HELMET 144
#define CAPE 148
#define KITS_END 152
#define MAX_OCCUPIED 8
#define GATE_OFFSET (GATE - SLOTS)
#define WORDS (MYC_PREVIEW_RECORD / 4)
#define PLAYER_BITS 15u

static uint32_t MycPvLe32(const uint8_t* p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

int myc_preview_locate(uint32_t ui_slot, int has_ui_slot, MycWhere* out)
{
    if (!has_ui_slot || ui_slot > 3) return 0;
    uint64_t system = vpm_game_u64(MYC_PREVIEW_SYSTEM);
    if (system < 0x10000 || system >= 0x800000000000ull) return 0;
    memset(out, 0, sizeof *out);
    out->system = (uintptr_t)system;
    out->first = (uintptr_t)system + SLOTS;
    myc_preview_retarget(out, (int)ui_slot);
    return 1;
}

void myc_preview_retarget(MycWhere* where, int slot)
{
    where->slot = slot;
    where->record = where->first + (uintptr_t)MYC_PREVIEW_RECORD * (uintptr_t)slot;
    where->bit = 1u << slot;
    where->units_at = where->record + UNITS;
}

void myc_preview_watch_init(MycPreviewWatch* w, MycWhere* where)
{
    memset(w, 0, sizeof *w);
    w->where = where;
    w->head = -1;
}

static int MycPvDiffers(const MycPreviewWatch* w, int s, int first, int last)
{
    const uint8_t* now = w->now + MYC_PREVIEW_RECORD * s;
    const uint8_t* kept = w->kept + MYC_PREVIEW_RECORD * s;
    return memcmp(now + first * 4, kept + first * 4, (size_t)(last - first) * 4) != 0;
}

/* lint: per-frame */
static int MycPvSlotStatus(MycPreviewWatch* w, int s, int shown)
{
    if (!shown)
    {
        if (w->present[s]) w->changes++;
        w->present[s] = 0;
        return MYC_STATUS_ABSENT;
    }
    int status = MYC_STATUS_SAME;
    if (!w->present[s] || MycPvDiffers(w, s, BODY / 4, KITS_END / 4)) status = MYC_STATUS_KITS;
    else if (MycPvDiffers(w, s, UNITS / 4, UNITS_END / 4)) status = MYC_STATUS_UNITS;
    if (status != MYC_STATUS_SAME)
    {
        memcpy(w->kept + MYC_PREVIEW_RECORD * s, w->now + MYC_PREVIEW_RECORD * s, MYC_PREVIEW_RECORD);
        w->changes++;
    }
    w->present[s] = 1;
    return status;
}

/* The occupied count, mask and ring at b: the mask (0 when the count is not believable). */
/* lint: per-frame */
static uint32_t MycPvGate(MycPreviewWatch* w, const uint8_t* b)
{
    int64_t ring = MycPvLe32(b + 8);
    w->moved = w->head >= 0 && ring != w->head;
    w->head = ring;
    return MycPvLe32(b) <= MAX_OCCUPIED ? MycPvLe32(b + 4) : 0;
}

/* lint: per-frame */
static int MycPvIdle(MycPreviewWatch* w)
{
    if (!vpm_read(w->where->first + GATE_OFFSET, w->gate, 16)) { w->moved = 0; return 1; }
    int64_t saved = w->head;
    if ((MycPvGate(w, w->gate) & PLAYER_BITS) == 0) return 1;
    w->head = saved;
    return 0;
}

/* lint: per-frame */
int myc_preview_poll(MycPreviewWatch* w)
{
    w->reads++;
    w->changes = 0;
    if (!(w->present[0] || w->present[1] || w->present[2] || w->present[3]) && MycPvIdle(w))
    {
        for (int s = 0; s < MYC_PREVIEW_SLOTS; s++) w->statuses[s] = MYC_STATUS_ABSENT;
        return w->statuses[w->where->slot];
    }
    uint32_t mask = 0;
    if (vpm_read(w->where->first, w->now, MYC_PREVIEW_SPAN)) mask = MycPvGate(w, w->now + GATE_OFFSET);
    else w->moved = 0;
    for (int s = 0; s < MYC_PREVIEW_SLOTS; s++) w->statuses[s] = MycPvSlotStatus(w, s, (mask & (1u << s)) != 0);
    return w->statuses[w->where->slot];
}

int myc_preview_status(const MycPreviewWatch* w, int s) { return w->statuses[s]; }

void myc_preview_slot_kits(const MycPreviewWatch* w, int s, uint32_t* helmet, uint32_t* armor, uint32_t* body, uint32_t* cape)
{
    const uint8_t* k = w->kept + MYC_PREVIEW_RECORD * s;
    *helmet = MycPvLe32(k + HELMET);
    *armor = MycPvLe32(k + ARMOR);
    *body = MycPvLe32(k + BODY);
    *cape = MycPvLe32(k + CAPE);
}

uintptr_t myc_preview_units_at(const MycPreviewWatch* w, int s)
{
    return w->where->first + (uintptr_t)MYC_PREVIEW_RECORD * (uintptr_t)s + UNITS;
}

void myc_preview_reset(MycPreviewWatch* w) { w->present[w->where->slot] = 0; }
