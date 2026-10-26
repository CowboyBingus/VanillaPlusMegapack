/* Match Your Colors: the game's kit catalogue (kits.lua Kits.catalogue) and a kit's signature, 1:1. Customization
 * manager [game + 0x33264F8]: kit pointers at +0, count at +8. A kit record: id +0, name +12, archive +32, type +40
 * (0 armor, 1 helmet, 2 cape), bodies +48 (24 bytes each, count +56), each body's pieces (96 bytes each). The record is
 * read again on every lookup (a transmog mod recomposes a record at runtime under the same id): a record whose bytes
 * read as before gives the kit kept. Kits are never changed once read and live for the session. Used by the worker's
 * jobs and by the game thread's record checks (records_same), so every call holds the catalogue's lock. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "myc_kits.h"

#define CATALOGUE_RVA 0x33264F8u
#define MAX_BODIES 8u
#define MAX_PIECES 32u
#define BODY_RECORD 24u
#define PIECE_RECORD 96u

static uint32_t MycCatU32(const uint8_t* p, uint64_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }
static uint64_t MycCatU64(const uint8_t* p, uint64_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
/* The Lua's u64 of a record: the low 48 bits (an address). */
static uint64_t MycCatAddress(const uint8_t* p, uint64_t o) { return MycCatU64(p, o) & 0xFFFFFFFFFFFFull; }

typedef struct MycKnown { uint32_t id; uintptr_t address; MycKit* kit; uint8_t* bytes; uint32_t size; } MycKnown;

struct MycCatalogue
{
    SRWLOCK lock;
    MycArena arena;         /* kits and their signatures, for the session */
    MycKnown* known;
    int count, capacity;
    int scanned;
    uint8_t record[MYC_RECORD_BYTES];
};

MycCatalogue* myc_catalogue_new(void)
{
    MycCatalogue* c = calloc(1, sizeof *c);
    if (c != NULL) InitializeSRWLock(&c->lock);
    return c;
}

void myc_catalogue_free(MycCatalogue* c)
{
    if (c == NULL) return;
    for (int i = 0; i < c->count; i++) free(c->known[i].bytes);
    free(c->known);
    myc_arena_free(&c->arena);
    free(c);
}

static MycKnown* MycCatKnown(MycCatalogue* c, uint32_t id)
{
    for (int i = 0; i < c->count; i++)
        if (c->known[i].id == id) return &c->known[i];
    return NULL;
}

/* Every kit's id and address (one read each); a miss reads them again once. */
static int MycCatScan(MycCatalogue* c, MycErr* err)
{
    uintptr_t manager = (uintptr_t)vpm_game_u64(CATALOGUE_RVA);
    uint8_t head[16];
    if (manager == 0 || !vpm_read(manager, head, 16)) return myc_fail(err, "kit catalogue unreadable");
    uintptr_t pointers = (uintptr_t)MycCatAddress(head, 0);
    uint32_t count = MycCatU32(head, 8);
    if (count == 0 || count > 4096) return myc_fail(err, "unexpected kit catalogue");
    static uint8_t list[4096 * 8];
    if (!vpm_read(pointers, list, (size_t)count * 8)) return myc_fail(err, "kit catalogue unreadable");
    for (int i = 0; i < c->count; i++) c->known[i].address = 0;
    for (uint32_t i = 0; i < count; i++)
    {
        uintptr_t address = (uintptr_t)MycCatAddress(list, (uint64_t)i * 8);
        uint32_t id;
        if (!vpm_read_u32(address, &id)) continue;
        MycKnown* k = MycCatKnown(c, id);
        if (k == NULL)
        {
            if (c->count >= c->capacity)
            {
                int capacity = c->capacity < 64 ? 64 : c->capacity * 2;
                MycKnown* grown = realloc(c->known, sizeof(MycKnown) * (size_t)capacity);
                if (grown == NULL) return myc_fail(err, "out of memory for the kit catalogue");
                c->known = grown;
                c->capacity = capacity;
            }
            k = &c->known[c->count++];
            memset(k, 0, sizeof *k);
            k->id = id;
        }
        k->address = address;
    }
    c->scanned = 1;
    return 1;
}

/* A kit record's bytes into c->record; how many it holds, or 0 and why. */
static uint32_t MycCatRecord(MycCatalogue* c, uintptr_t address, const char** why)
{
    uint8_t* r = c->record;
    if (!vpm_read(address, r, 64)) { *why = "kit unreadable"; return 0; }
    uint32_t bodies = MycCatU32(r, 56);
    if (MycCatU32(r, 40) > 2 || bodies > MAX_BODIES) { *why = "unexpected kit record"; return 0; }
    uint32_t at = 64 + bodies * BODY_RECORD;
    if (bodies > 0 && !vpm_read((uintptr_t)(MycCatU32(r, 48) + (uint64_t)MycCatU32(r, 52) * 4294967296ull), r + 64, at - 64))
    {
        *why = "kit body unreadable";
        return 0;
    }
    for (uint32_t b = 0; b < bodies; b++)
    {
        uint32_t o = 64 + BODY_RECORD * b, count = MycCatU32(r, o + 16);
        if (count > MAX_PIECES) { *why = "unexpected kit body"; return 0; }
        uintptr_t pieces = (uintptr_t)(MycCatU32(r, o + 8) + (uint64_t)MycCatU32(r, o + 12) * 4294967296ull);
        if (count > 0 && !vpm_read(pieces, r + at, (size_t)count * PIECE_RECORD)) { *why = "kit piece unreadable"; return 0; }
        at += count * PIECE_RECORD;
    }
    return at;
}

static void MycCatPiece(const uint8_t* b, uint32_t o, uint32_t body, int cape, MycPiece* p)
{
    memset(p, 0, sizeof *p);
    p->path = MycCatU64(b, o);
    p->slot = MycCatU32(b, o + 8);
    p->type = MycCatU32(b, o + 12);
    p->body = body;
    p->lut = MycCatU64(b, o + 24);
    p->pattern = MycCatU64(b, o + 32);
    p->tone = b[o + 88];
    if (!cape) return;
    p->is_cape = 1;
    p->cape_lut = MycCatU64(b, o + 40);
    p->gradient = MycCatU64(b, o + 48);
    p->fields = MycCatU64(b, o + 64);
    p->decal = MycCatU64(b, o + 80);
}

static MycKit* MycCatKitOf(MycCatalogue* c, const uint8_t* r)
{
    static const int types[3] = {MYC_ARMOR, MYC_HELMET, MYC_CAPE};
    MycKit* kit = myc_alloc(&c->arena, sizeof *kit);
    if (kit == NULL) return NULL;
    kit->id = MycCatU32(r, 0);
    kit->name_upper = MycCatU32(r, 12);
    kit->archive = MycCatU64(r, 32);
    kit->type = types[MycCatU32(r, 40)];
    uint32_t bodies = MycCatU32(r, 56), at = 64 + bodies * BODY_RECORD, total = 0;
    for (uint32_t b = 0; b < bodies; b++) total += MycCatU32(r, 64 + BODY_RECORD * b + 16);
    kit->pieces = myc_alloc(&c->arena, sizeof(MycPiece) * (total > 0 ? total : 1));
    if (kit->pieces == NULL) return NULL;
    for (uint32_t b = 0; b < bodies; b++)
    {
        uint32_t o = 64 + BODY_RECORD * b, body = MycCatU32(r, o), count = MycCatU32(r, o + 16);
        for (uint32_t p = 0; p < count; p++)
            MycCatPiece(r, at + p * PIECE_RECORD, body, kit->type == MYC_CAPE, &kit->pieces[kit->npieces++]);
        at += count * PIECE_RECORD;
    }
    return kit;
}

/* ---- signatures ------------------------------------------------------------------------------------------------------ */

/* A number as Lua's tostring prints an integer-valued double. */
static int MycCatNumber(char* out, size_t size, uint64_t v) { return snprintf(out, size, "%llu", (unsigned long long)v); }

const char* myc_kits_signature(MycArena* arena, MycKit* kit)
{
    if (kit->signature != NULL) return kit->signature;
    size_t capacity = 128 + (size_t)kit->npieces * 160;
    for (int i = 0; i < kit->npieces; i++)
        if (kit->pieces[i].overrides_text != NULL) capacity += strlen(kit->pieces[i].overrides_text) + 2;
    char* s = myc_alloc(arena, capacity);
    if (s == NULL) return "";
    size_t n = (size_t)snprintf(s, capacity, "%08x;", kit->id);
    n += (size_t)MycCatNumber(s + n, capacity - n, kit->name_upper);
    n += (size_t)snprintf(s + n, capacity - n, ";%016llx;%s", (unsigned long long)kit->archive, myc_kit_type_name(kit->type));
    for (int i = 0; i < kit->npieces && n < capacity; i++)
    {
        const MycPiece* p = &kit->pieces[i];
        n += (size_t)snprintf(s + n, capacity - n, ";%016llx,%u,%u,%u,%016llx,%016llx,%u,", (unsigned long long)p->path,
            p->slot, p->type, p->body, (unsigned long long)p->lut, (unsigned long long)p->pattern, p->tone);
        if (p->is_cape)
            n += (size_t)snprintf(s + n, capacity - n, "%016llx,%016llx,%016llx,%016llx", (unsigned long long)p->fields,
                (unsigned long long)p->cape_lut, (unsigned long long)p->gradient, (unsigned long long)p->decal);
        if (p->overrides_text != NULL) n += (size_t)snprintf(s + n, capacity - n, ",%s", p->overrides_text);
    }
    kit->signature = s;
    return s;
}

/* ---- lookups ----------------------------------------------------------------------------------------------------------- */

/* The kit at k's address as its record reads now (the kit kept while its bytes are the same, or one with the same
 * signature), or NULL and why. */
static MycKit* MycCatCurrent(MycCatalogue* c, MycKnown* k, const char** why)
{
    uint32_t size = MycCatRecord(c, k->address, why);
    if (size == 0) return NULL;
    if (k->kit != NULL && k->bytes != NULL && k->size == size && memcmp(k->bytes, c->record, size) == 0) return k->kit;
    MycKit* kit = MycCatKitOf(c, c->record);
    if (kit == NULL) { *why = "out of memory for a kit"; return NULL; }
    if (!(k->kit != NULL && strcmp(myc_kits_signature(&c->arena, k->kit), myc_kits_signature(&c->arena, kit)) == 0)) k->kit = kit;
    uint8_t* bytes = realloc(k->bytes, size);
    if (bytes != NULL) { memcpy(bytes, c->record, size); k->bytes = bytes; k->size = size; }
    return k->kit;
}

MycKit* myc_catalogue_find(MycCatalogue* c, uint32_t id, MycErr* err)
{
    AcquireSRWLockExclusive(&c->lock);
    MycKit* kit = NULL;
    MycKnown* k = MycCatKnown(c, id);
    if ((k == NULL || k->address == 0) && MycCatScan(c, err)) k = MycCatKnown(c, id);
    if (!err->failed)
    {
        if (k == NULL || k->address == 0) myc_fail(err, "kit %08x not in the catalogue", id);
        else
        {
            const char* why = NULL;
            kit = MycCatCurrent(c, k, &why);
            if (kit == NULL) myc_fail(err, "%s", why);
        }
    }
    ReleaseSRWLockExclusive(&c->lock);
    return kit;
}

const char* myc_catalogue_signature(MycCatalogue* c, uint32_t id)
{
    AcquireSRWLockExclusive(&c->lock);
    MycKnown* k = c->scanned ? MycCatKnown(c, id) : NULL;
    const char* why = NULL;
    MycKit* kit = k != NULL && k->address != 0 ? MycCatCurrent(c, k, &why) : NULL;
    const char* s = kit != NULL ? myc_kits_signature(&c->arena, kit) : NULL;
    ReleaseSRWLockExclusive(&c->lock);
    return s;
}
