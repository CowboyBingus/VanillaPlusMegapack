/* Consistent Vaulting: numbers, reads, guards, the game's hash map and checked stores (cv.h; consistent_vaulting.c has
 * the overview). */
#include <math.h>
#include <string.h>
#include "cv.h"

const CvTexts cv_vault_texts = {"Game data unavailable", "Game pointer unavailable", "Unsupported map",
    "Movement record unavailable"};
const CvTexts cv_slope_texts = {"Slope data unavailable", "Slope pointer unavailable", "Unsupported slope map",
    "Movement unavailable"};

static const char* g_error = "";

int cv_raise(const char* text)
{
    g_error = text;
    return CV_RAISED;
}

const char* cv_error(void) { return g_error; }

uint16_t cv_u16(const uint8_t* at) { uint16_t v; memcpy(&v, at, 2); return v; }
uint32_t cv_u32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
uint64_t cv_u64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }
void cv_put_u32(uint8_t* at, uint32_t value) { memcpy(at, &value, 4); }

double cv_num(const uint8_t* at)
{
    float v;
    memcpy(&v, at, 4);
    return (double)v;
}

double cv_f32(double value) { return (double)(float)value; }

void cv_put_f32(uint8_t* at, double value)
{
    float v = (float)value;
    memcpy(at, &v, 4);
}

int cv_finite(double value) { return value == value && fabs(value) < 100000.0; }
int cv_finite3(const double* v) { return cv_finite(v[0]) && cv_finite(v[1]) && cv_finite(v[2]); }

int cv_vector(const uint8_t* at, double* out)
{
    for (int i = 0; i < 3; i++) out[i] = cv_num(at + i * 4);
    return cv_finite3(out) ? 1 : cv_raise("Invalid vector");
}

int cv_pointer(const uint8_t* at, uintptr_t* out)
{
    uint64_t value = cv_u64(at);
    if (value < 0x10000u || value >= 0x800000000000ull) return 0;
    *out = (uintptr_t)value;
    return 1;
}

void cv_pair(uint8_t* at, uint32_t unit, uint32_t actor)
{
    cv_put_u32(at, unit);
    cv_put_u32(at + 4, actor);
}

/* ---- reads ------------------------------------------------------------------------------------------------------- */

static int Inside(uintptr_t address, size_t size, uintptr_t base, size_t limit)
{
    return base != 0 && address >= base && size <= limit && address - base <= limit - size;
}

int cv_load(uintptr_t address, void* out, size_t size)
{
    if (Inside(address, size, vpm_game(), vpm_game_size())) return vpm_game_read((uint32_t)(address - vpm_game()), out, size);
    if (Inside(address, size, vpm_exe(), vpm_exe_size())) return vpm_exe_read((uint32_t)(address - vpm_exe()), out, size);
    return vpm_read(address, out, size);
}

static uint8_t g_scratch[1024]; /* a guard's bytes as read now (the largest is an 852-byte settings record) */

int cv_matches(uintptr_t address, const void* bytes, size_t size)
{
    return size <= sizeof g_scratch && cv_load(address, g_scratch, size) && memcmp(g_scratch, bytes, size) == 0;
}

uintptr_t cv_input_address(uintptr_t manager, uint32_t ai)
{
    VpmAvatar avatar;
    memset(&avatar, 0, sizeof avatar);
    avatar.manager = manager;
    avatar.index = ai;
    return vpm_action_slot(&avatar, CV_ACTION_CLIMB);
}

/* ---- stores ------------------------------------------------------------------------------------------------------ */

#define WRITABLE_SPANS 8
static struct { uintptr_t address; size_t size; } g_writable[WRITABLE_SPANS];
static int g_writableNext;
#ifdef VPM_TEST
static CvTestCounts g_testCounts;
CvTestCounts* cv_test_counts(void) { return &g_testCounts; }
#endif

void cv_memory_reset(void)
{
    memset(g_writable, 0, sizeof g_writable);
    g_writableNext = 0;
    g_error = "";
#ifdef VPM_TEST
    memset(&g_testCounts, 0, sizeof g_testCounts);
#endif
}

int cv_writable(uintptr_t address, size_t size)
{
    for (int i = 0; i < WRITABLE_SPANS; i++)
        if (g_writable[i].size != 0 && address >= g_writable[i].address &&
            address + size <= g_writable[i].address + g_writable[i].size)
            return 1;
#ifdef VPM_TEST
    g_testCounts.queries++;
#endif
    if (!vpm_writable(address, size)) return 0;
    g_writable[g_writableNext].address = address;
    g_writable[g_writableNext].size = size;
    g_writableNext = (g_writableNext + 1) % WRITABLE_SPANS;
    return 1;
}

void cv_store(uintptr_t address, const void* bytes, size_t size)
{
#ifdef VPM_TEST
    g_testCounts.stores++;
#endif
    memcpy((void*)address, bytes, size);
}

int cv_write(uintptr_t address, const void* bytes, size_t size)
{
    if (!cv_writable(address, size)) return 0;
    cv_store(address, bytes, size);
    return 1;
}

/* ---- guards ------------------------------------------------------------------------------------------------------ */

void cv_guards_reset(CvGuards* guards, const CvTexts* texts)
{
    guards->texts = texts;
    guards->count = 0;
    guards->used = 0;
}

uint8_t* cv_guard_add(CvGuards* guards, uintptr_t address, const void* bytes, size_t size, int epoch)
{
    if (guards->count >= CV_GUARDS || size > CV_GUARD_BYTES - guards->used) return NULL;
    CvGuard* guard = &guards->list[guards->count++];
    guard->address = address;
    guard->at = (uint16_t)guards->used;
    guard->size = (uint16_t)size;
    guard->epoch = (uint8_t)(epoch != 0);
    uint8_t* at = guards->bytes + guards->used;
    if (bytes != NULL) memcpy(at, bytes, size);
    guards->used += (uint32_t)size;
    return at;
}

int cv_guard_read(CvGuards* guards, uintptr_t address, size_t size, int epoch, uint8_t** bytes)
{
    uint8_t* at = cv_guard_add(guards, address, NULL, size, epoch);
    if (at == NULL) return cv_raise("Snapshot read budget exceeded");
    if (!cv_load(address, at, size)) return cv_raise(guards->texts->unavailable);
    *bytes = at;
    return 1;
}

int cv_guard_pointer(CvGuards* guards, uintptr_t address, int epoch, uintptr_t* out)
{
    uint8_t* bytes;
    CV_TRY(cv_guard_read(guards, address, 8, epoch, &bytes));
    return cv_pointer(bytes, out) ? 1 : cv_raise(guards->texts->pointer);
}

int cv_guards_hold(const CvGuards* guards, int epoch_only)
{
    for (int i = 0; i < guards->count; i++)
    {
        const CvGuard* guard = &guards->list[i];
        if (epoch_only && !guard->epoch) continue;
        if (!cv_matches(guard->address, guards->bytes + guard->at, guard->size)) return 0;
    }
    return 1;
}

/* ---- the game's hash map ----------------------------------------------------------------------------------------- */

int cv_probe(const CvMap* map, const uint8_t* header, uint32_t* value)
{
    uint32_t capacity = cv_u32(header + 8), empty = cv_u32(header + 12), multiplier = cv_u32(header + 16);
    if (capacity == 0 || capacity > map->limit || (capacity & (capacity - 1)) != 0) return cv_raise(map->texts->map);
    uintptr_t data;
    if (!cv_pointer(header, &data)) return cv_raise(map->texts->pointer);
    uint32_t low = map->key * multiplier; /* the low 32 bits, as the game hashes */
    uint32_t probes = capacity < 128 ? capacity : 128;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        uint32_t row[2];
        CV_TRY(map->read_row(map->context, data + (uintptr_t)((low + probe) & (capacity - 1)) * 8u, row));
        if (row[0] == map->key) { *value = row[1]; return 1; }
        if (row[0] == empty) return 0;
    }
    return 0;
}

static int GuardRow(void* context, uintptr_t address, uint32_t* row)
{
    uint8_t* bytes;
    CV_TRY(cv_guard_read(context, address, 8, 0, &bytes));
    memcpy(row, bytes, 8);
    return 1;
}

int cv_lookup(CvGuards* guards, uintptr_t header, uint32_t key, uint32_t limit, uint32_t* value)
{
    uint8_t* bytes;
    CV_TRY(cv_guard_read(guards, header, 20, 0, &bytes));
    CvMap map = {key, limit, GuardRow, guards, guards->texts};
    return cv_probe(&map, bytes, value);
}

/* A record read as a guard (guarded) or plainly, into out. */
static int ReadRecord(CvGuards* guards, uintptr_t address, size_t size, int guarded, uint8_t* out)
{
    uint8_t* bytes = NULL;
    if (!guarded) return cv_load(address, out, size) ? 1 : cv_raise(guards->texts->unavailable);
    CV_TRY(cv_guard_read(guards, address, size, 0, &bytes));
    memcpy(out, bytes, size);
    return 1;
}

int cv_movement(CvGuards* guards, uint32_t id, int records_guarded, CvMovement* out)
{
    uintptr_t movement, moves, movers;
    uint32_t mi = 0;
    CV_TRY(cv_guard_pointer(guards, vpm_game() + CV_RVA_MOVEMENT, 0, &movement));
    int found = cv_lookup(guards, movement + 0x48A0, id, 1048576u, &mi);
    if (found < 0) return found;
    if (found == 0 || mi == CV_INVALID || mi >= 8192u) return cv_raise(guards->texts->movement);
    CV_TRY(cv_guard_pointer(guards, movement + 0x48C8, 0, &moves));
    CV_TRY(ReadRecord(guards, moves + (uintptr_t)mi * 132u, 132, records_guarded, out->move));
    CV_TRY(cv_guard_pointer(guards, movement + 0x48D0, 0, &movers));
    out->mover_address = movers + (uintptr_t)mi * 164u;
    return ReadRecord(guards, out->mover_address, 164, records_guarded, out->mover);
}
