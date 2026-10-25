/* Sticky Grenade Handles v1.0.1 (Lua: components/StickyGrenadeHandles/src/sticky_grenade_handles.lua), build 25480438.
 *
 * The G-123 Thermite and the sticky stun grenade bounce off when their handle touches first. The handle is a separate
 * capsule with its own physics material, sticky_grenade_handle, and the game sticks a throwable only on contacts whose
 * material tag equals the throwable's sticky material (ThrowableComponent +0x164, the "throwable" material). This gives
 * the handle material the throwable tag: one 4-byte store per session into the engine's material library (the userData
 * of one hknpMaterial). Friction, restitution and every other value stay vanilla, and nothing else uses that material.
 *
 * On HellForge: the two grenades' ThrowableComponent records are found by identity (HfApi.component_record, after
 * HF_EVENT_ENTITIES_READY), since HellForge may rebuild the component tables when mods add entities. Each session checks
 * that both still stick, by the throwable material, before the store (a data-only game update could change that).
 *
 * Cost: once per session, at HF_EVENT_ENTITIES_READY: 2 record reads, the library's header and entries (2 reads), a
 * name read per name compared (3: the throwable entry is compared with both names, as in the Lua), one page check
 * (VirtualQuery) and the store, one read-back: 8 reads (the Lua: 13).
 * If the engine is not ready, a tick tries again every frame (the material library pointer is a plain load; 0 reads
 * until it exists), for at most 600 s. Nothing per frame afterwards. */
#include <stdio.h>
#include <string.h>
#include "../../core/vpm.h"

#define LIBRARY_RVA 0x27C5CF0u        /* helldivers2.exe: the hknpMaterialLibrary that tags each contact (poster 0x78BFC0) */
#define LIBRARY_VTABLE_RVA 0x148BA78u /* helldivers2.exe: hknpMaterialLibrary's vtable (RTTI) */
#define HEADER_SIZE 0x58u
#define AT_ENTRIES 0x48u              /* its entry array (hkArray: data, count, capacity with flags in the top 2 bits) */
#define AT_COUNT 0x50u
#define AT_CAPACITY 0x54u
#define MAX_ENTRIES 1024u
#define ENTRY_SIZE 80u                /* hknpMaterial: name (hkStringPtr, bit 0 an ownership flag) +0, userData +0x48 */
#define AT_NAME 0x00u
#define AT_TAG 0x48u
#define AT_STICKY 0x54u               /* ThrowableComponent: sticky, the material it sticks with */
#define AT_STICKY_MATERIAL 0x164u
#define THROWABLE_SIZE 360u
#define THROWABLE 0xC4692706u         /* thin hash of the material name "throwable" */
#define HANDLE 0x9A056E1Cu            /* thin hash of "sticky_grenade_handle" */
#define WAIT_SECONDS 600.0f

typedef struct Grenade { const char* name; uint64_t resource; } Grenade;
static const Grenade kGrenades[] = {
    {"G-123 Thermite", 0xC5C05FCB5747C799ull},
    {"sticky stun grenade", 0x3FA94F58F596BC0Bull},
};

static struct
{
    uintptr_t tag;   /* the handle material's tag, once found */
    int index;
    int wrote;       /* this session gave it the throwable tag */
    float waited;
    char status[160];
} s;

static uint8_t g_entries[MAX_ENTRIES * ENTRY_SIZE]; /* the library's entries as read (static: 80 KB) */

static uint32_t U32(const uint8_t* at) { uint32_t v; memcpy(&v, at, 4); return v; }
static uint64_t U64(const uint8_t* at) { uint64_t v; memcpy(&v, at, 8); return v; }

/* 0 wait (*why says for what), 1 checked, -1 failed (vpm_fail called). */
#define WAIT 0
#define DONE 1
#define FAILED (-1)

static int CheckGrenades(VpmComponent* self, const char** why)
{
    uintptr_t records[2];
    for (int i = 0; i < 2; i++)
    {
        uint32_t stride = 0;
        records[i] = vpm_hf()->component_record("ThrowableComponentData", kGrenades[i].resource, &stride);
        if (records[i] == 0) { *why = "the throwable settings are not loaded yet"; return WAIT; }
    }
    for (int i = 0; i < 2; i++)
    {
        uint8_t record[THROWABLE_SIZE];
        if (!vpm_read(records[i], record, sizeof record)) { vpm_fail(self, "Throwable settings unreadable"); return FAILED; }
        if (record[AT_STICKY] != 1 || U32(record + AT_STICKY_MATERIAL) != THROWABLE)
        {
            vpm_fail(self, "The %s no longer sticks by the throwable material", kGrenades[i].name);
            return FAILED;
        }
    }
    return DONE;
}

/* The library's entries into g_entries; WAIT while it does not exist. */
static int ReadLibrary(VpmComponent* self, uintptr_t* entries, uint32_t* count, const char** why)
{
    uintptr_t library = (uintptr_t)vpm_exe_u64(LIBRARY_RVA);
    if (library == 0) { *why = "the material library does not exist yet"; return WAIT; }
    uint8_t header[HEADER_SIZE];
    if (!vpm_read(library, header, sizeof header)) { vpm_fail(self, "Material library unreadable"); return FAILED; }
    if (U64(header) != vpm_exe() + LIBRARY_VTABLE_RVA) { vpm_fail(self, "Unexpected material library"); return FAILED; }
    *entries = (uintptr_t)U64(header + AT_ENTRIES);
    *count = U32(header + AT_COUNT);
    uint32_t capacity = U32(header + AT_CAPACITY) & 0x3FFFFFFFu;
    if (*entries == 0) { vpm_fail(self, "Material entries unavailable"); return FAILED; }
    if (*count == 0 || *count > MAX_ENTRIES || *count > capacity) { vpm_fail(self, "Unexpected material count"); return FAILED; }
    if (!vpm_read(*entries, g_entries, (size_t)*count * ENTRY_SIZE)) { vpm_fail(self, "Material entries unreadable"); return FAILED; }
    return DONE;
}

static int Named(uint32_t index, const char* expected)
{
    char name[32];
    size_t n = strlen(expected) + 1;
    uintptr_t pointer = (uintptr_t)U64(g_entries + index * ENTRY_SIZE + AT_NAME);
    if (pointer == 0 || n > sizeof name) return 0;
    return vpm_read(pointer & ~(uintptr_t)1, name, n) && memcmp(name, expected, n) == 0;
}

/* The handle and throwable materials' indexes (-1 when absent); FAILED when a name occurs twice. */
static int FindMaterials(VpmComponent* self, uint32_t count, int* handle, int* throwable)
{
    *handle = *throwable = -1;
    for (uint32_t i = 0; i < count; i++)
    {
        uint32_t tag = U32(g_entries + i * ENTRY_SIZE + AT_TAG);
        if ((tag == HANDLE || tag == THROWABLE) && Named(i, "sticky_grenade_handle"))
        {
            if (*handle >= 0) { vpm_fail(self, "Two sticky_grenade_handle materials"); return FAILED; }
            *handle = (int)i;
        }
        else if (tag == THROWABLE && Named(i, "throwable"))
        {
            if (*throwable >= 0) { vpm_fail(self, "Two throwable materials"); return FAILED; }
            *throwable = (int)i;
        }
    }
    return DONE;
}

/* One attempt: DONE (applied or already applied), WAIT with *why, or FAILED. Nothing is written unless every check
 * passed. */
static int Attempt(VpmComponent* self, const char** why)
{
    int result = CheckGrenades(self, why);
    uintptr_t entries = 0;
    uint32_t count = 0;
    if (result == DONE) result = ReadLibrary(self, &entries, &count, why);
    int handle = -1, throwable = -1;
    if (result == DONE) result = FindMaterials(self, count, &handle, &throwable);
    if (result != DONE) return result;
    if (handle < 0 && throwable < 0) { *why = "the materials are not loaded yet"; return WAIT; }
    if (handle < 0) { vpm_fail(self, "No sticky_grenade_handle material"); return FAILED; }
    if (throwable < 0) { vpm_fail(self, "No throwable material"); return FAILED; }
    s.tag = entries + (uintptr_t)handle * ENTRY_SIZE + AT_TAG;
    s.index = handle;
    if (U32(g_entries + (uint32_t)handle * ENTRY_SIZE + AT_TAG) == THROWABLE)
    {
        snprintf(s.status, sizeof s.status, "already applied");
        return DONE;
    }
    const uint32_t value = THROWABLE;
    uint32_t now = 0;
    if (!vpm_writable(s.tag, 4)) { vpm_fail(self, "Material write refused or failed"); return FAILED; }
    memcpy((void*)s.tag, &value, 4);
    s.wrote = 1;
    if (!vpm_read_u32(s.tag, &now) || now != THROWABLE) { vpm_fail(self, "Material write did not hold"); return FAILED; }
    snprintf(s.status, sizeof s.status, "applied");
    return DONE;
}

static void Done(VpmComponent* self, const char* when)
{
    vpm_set_status(self, s.status);
    vpm_log(self, "%s (material %d tagged throwable: the handles of the G-123 Thermite and the sticky stun grenade stick), %s.",
        s.status, s.index, when);
}

static void Wait(VpmComponent* self, float dt)
{
    const char* why = "";
    int result = Attempt(self, &why);
    if (result == FAILED) return;
    if (result == DONE)
    {
        vpm_tick_stop(self);
        char when[48];
        snprintf(when, sizeof when, "after %.1f s", s.waited);
        Done(self, when);
        return;
    }
    s.waited += dt;
    if (s.waited >= WAIT_SECONDS) vpm_fail(self, "gave up after %.0f s: waiting: %s", WAIT_SECONDS, why);
}

static void EntitiesReady(VpmComponent* self, HfEvent event)
{
    if (s.tag != 0) return;
    const char* why = "";
    int result = Attempt(self, &why);
    if (result == DONE) { Done(self, "at load"); return; }
    if (result == FAILED) return;
    char status[160];
    snprintf(status, sizeof status, "waiting: %s", why);
    vpm_set_status(self, status);
    vpm_log(self, "Waiting for the game: %s.", why);
    vpm_tick_start(self, Wait);
}

/* Puts the handle material's own tag back if this session changed it. */
static void Stop(VpmComponent* self)
{
    uint32_t now = 0;
    const uint32_t value = HANDLE;
    if (s.wrote && vpm_read_u32(s.tag, &now) && now == THROWABLE && vpm_writable(s.tag, 4)) memcpy((void*)s.tag, &value, 4);
    s.wrote = 0;
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    return vpm_on_load(self, HF_EVENT_ENTITIES_READY, EntitiesReady) ? 0 : 1;
}

const VpmComponentDef vpm_component_sticky_grenade_handles = {"sticky_grenade_handles", "Sticky Grenade Handles", "1.0.1", 0, Start, Stop};
