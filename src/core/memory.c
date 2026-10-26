/* Memory access for components (vpm.h "memory"), the game's hash lookup and the local player's resolution. */
#include <string.h>
#include "vpm_core.h"

static uintptr_t g_game, g_exe;
static size_t g_gameSize, g_exeSize;

/* The tests' stand-ins (vpm_core_test_hooks): none in the pack's DLL. */
static VpmTestHooks g_hooks;
void vpm_core_test_hooks(const VpmTestHooks* hooks) { g_hooks = hooks != NULL ? *hooks : (VpmTestHooks){0}; }
int vpm_test_tick_refused(int post) { return g_hooks.tick_refused != NULL && g_hooks.tick_refused(post); }

uintptr_t vpm_game(void) { return g_game; }
size_t vpm_game_size(void) { return g_gameSize; }
uintptr_t vpm_exe(void) { return g_exe; }
size_t vpm_exe_size(void) { return g_exeSize; }

void vpm_memory_init(void)
{
    const HfApi* hf = vpm_core_hf();
    g_exe = hf->module_base("helldivers2.exe", &g_exeSize);
    g_game = hf->module_base("game.dll", &g_gameSize);
}

void vpm_memory_game_loaded(void)
{
    if (g_game == 0) g_game = vpm_core_hf()->module_base("game.dll", &g_gameSize);
}

static int ImageRead(uintptr_t base, size_t size, uint32_t rva, void* out, size_t n)
{
    if (base == 0 || n > size || rva > size - n) return 0;
    memcpy(out, (const void*)(base + rva), n);
    return 1;
}

int vpm_game_read(uint32_t rva, void* out, size_t size) { return ImageRead(g_game, g_gameSize, rva, out, size); }
int vpm_exe_read(uint32_t rva, void* out, size_t size) { return ImageRead(g_exe, g_exeSize, rva, out, size); }

uint64_t vpm_game_u64(uint32_t rva)
{
    uint64_t value = 0;
    return vpm_game_read(rva, &value, sizeof value) ? value : 0;
}

uint32_t vpm_game_u32(uint32_t rva)
{
    uint32_t value = 0;
    return vpm_game_read(rva, &value, sizeof value) ? value : 0;
}

uint64_t vpm_exe_u64(uint32_t rva)
{
    uint64_t value = 0;
    return vpm_exe_read(rva, &value, sizeof value) ? value : 0;
}

/* The heap read every component uses: plain loads under the core's guard (vpm_guard_copy), where the Lua's api.read was a
 * ReadProcessMemory. An address outside the user-mode range fails at once, as ReadProcessMemory does, without a fault.
 * Without the guard (it could not be installed) it reads through HfApi.read. Components gate it: each header states its
 * reads per frame, and its test pins them (the harness answers them through VpmTestHooks.read). */
int vpm_read(uintptr_t address, void* out, size_t size)
{
    if (size == 0 || !vpm_plausible(address) || address + size < address || !vpm_plausible(address + size - 1)) return 0;
    if (g_hooks.read != NULL) return g_hooks.read(address, out, size); /* lint-ok: C4 the tests' stand-in; never set in the DLL */
    int copied = vpm_guard_copy(out, address, size);
    if (copied >= 0) return copied;
    return vpm_core_hf()->read(address, out, size) == 0; /* lint-ok: C4 only without the guard; callers count and gate it */
}
int vpm_read_u8(uintptr_t address, uint8_t* out) { return vpm_read(address, out, sizeof *out); }
int vpm_read_u16(uintptr_t address, uint16_t* out) { return vpm_read(address, out, sizeof *out); }
int vpm_read_u32(uintptr_t address, uint32_t* out) { return vpm_read(address, out, sizeof *out); }
int vpm_read_u64(uintptr_t address, uint64_t* out) { return vpm_read(address, out, sizeof *out); }
int vpm_read_f32(uintptr_t address, float* out) { return vpm_read(address, out, sizeof *out); }

uintptr_t vpm_ptr(uintptr_t address)
{
    uint64_t value = 0;
    return vpm_read(address, &value, sizeof value) && vpm_plausible((uintptr_t)value) ? (uintptr_t)value : 0;
}

int vpm_plausible(uintptr_t pointer) { return pointer >= 0x10000 && pointer < 0x800000000000ull; }


int vpm_write(uintptr_t address, const void* data, size_t size)
{
    return address != 0 && vpm_core_hf()->write(address, data, size) == 0; /* lint-ok: C4 writes only on frames that act; callers state them */
}

int vpm_writable(uintptr_t address, size_t size)
{
    uintptr_t at = address, end = address + size;
    if (address == 0 || size == 0 || end < address) return 0;
    while (at < end)
    {
        MEMORY_BASIC_INFORMATION info;
        if (g_hooks.writable_query != NULL) g_hooks.writable_query();
        if (VirtualQuery((const void*)at, &info, sizeof info) != sizeof info) return 0; /* lint-ok: C4 validation only, when a target is found */
        if (info.State != MEM_COMMIT || info.Type != MEM_PRIVATE || info.Protect != PAGE_READWRITE) return 0;
        uintptr_t regionEnd = (uintptr_t)info.BaseAddress + info.RegionSize;
        if (regionEnd <= at) return 0;
        at = regionEnd;
    }
    return 1;
}

/* ---- hooks -------------------------------------------------------------------------------------------------------- */

typedef struct Image { const char* name; uintptr_t base; size_t size; } Image;

/* The pack's hooks (vpm_hook): one record per target and detour while it is in, so a start after a switch-off does not
 * hook twice (HellForge refuses the same detour on the same function twice, and the old *original stays valid). With
 * HellForge's live mods a switched-off component's hooks are taken out (unhook); without them they stay, and their
 * detours only call the original while the component is not running. */
#define MAX_PACK_HOOKS 32
typedef struct PackHook
{
    VpmComponent* component;
    uintptr_t target;
    void* detour;
    void** original;   /* the component's variable HellForge keeps up to date */
    void* first;       /* what hook_ex wrote there: put back if a start reset the variable while the hook stayed in */
    int in;
} PackHook;
static PackHook g_packHooks[MAX_PACK_HOOKS];

int vpm_hooks_in(void)
{
    int n = 0;
    for (int i = 0; i < MAX_PACK_HOOKS; i++) n += g_packHooks[i].in;
    return n;
}

/* The pack's hook of target with this detour while it is in, or NULL. */
static PackHook* HookIn(uintptr_t target, void* detour)
{
    for (int i = 0; i < MAX_PACK_HOOKS; i++)
        if (g_packHooks[i].in && g_packHooks[i].target == target && g_packHooks[i].detour == detour) return &g_packHooks[i];
    return NULL;
}

static void HookNote(VpmComponent* self, uintptr_t target, void* detour, void** original)
{
    for (int i = 0; i < MAX_PACK_HOOKS; i++)
        if (!g_packHooks[i].in) { g_packHooks[i] = (PackHook){self, target, detour, original, *original, 1}; return; }
    vpm_log(self, "core: more than %d hooks in the pack: this one stays for the session", MAX_PACK_HOOKS);
}

/* Another component's hook in at the same target (the pack's unhook takes the pack's whole link there out). */
static int SharedTarget(const PackHook* hook)
{
    for (int i = 0; i < MAX_PACK_HOOKS; i++)
    {
        const PackHook* other = &g_packHooks[i];
        if (other != hook && other->in && other->target == hook->target && other->component != hook->component) return 1;
    }
    return 0;
}

void vpm_hooks_component_off(VpmComponent* component)
{
    const VpmLive* live = vpm_core_live();
    if (!live->present) return; /* SDK 15: hooks stay; their detours check vpm_running */
    for (int i = 0; i < MAX_PACK_HOOKS; i++)
    {
        PackHook* hook = &g_packHooks[i];
        if (!hook->in || hook->component != component || SharedTarget(hook)) continue;
        hook->in = 0;
        if (live->unhook(vpm_mod(), hook->target) != 0) vpm_log(component, "core: HellForge had no hook of 0x%llX to take out", (unsigned long long)hook->target);
    }
}

void vpm_hooks_unload(void)
{
    const VpmLive* live = vpm_core_live();
    for (int i = 0; i < MAX_PACK_HOOKS; i++)
    {
        PackHook* hook = &g_packHooks[i];
        if (hook->in && live->present && live->unhook != NULL) (void)live->unhook(vpm_mod(), hook->target); /* 1: HellForge took it out already */
        hook->in = 0;
    }
}

static int HookAt(VpmComponent* self, Image image, uint32_t rva, const char* shipped, void* detour, void** original)
{
    const HfApi* hf = vpm_core_hf();
    if (image.base == 0 || rva >= image.size) { vpm_log(self, "hook refused: %s+0x%X is not in the image", image.name, rva); return 0; }
    PackHook* kept = HookIn(image.base + rva, detour);
    if (kept != NULL)
    {
        /* Still in from an earlier start (SDK 15 keeps hooks): nothing to hook. A start that reset *original gets back
         * what HellForge first wrote there (vpm.h: keep it outside the state start() resets). */
        kept->component = self;
        if (kept->original != original || *original == NULL)
        {
            vpm_log(self, "core: the hook of %s+0x%X was already in; its original was reset by start() and is put back", image.name, rva);
            *original = kept->original != original && *kept->original != NULL ? *kept->original : kept->first;
        }
        return 1;
    }
    if (!hf->code_matches(image.base + rva, shipped))
    {
        vpm_log(self, "hook refused: %s+0x%X is not the reviewed function", image.name, rva);
        return 0;
    }
    if (hf->hook_ex(vpm_mod(), image.base + rva, detour, original, 0) != 0)
    {
        vpm_log(self, "hook refused at %s+0x%X: %s", image.name, rva, hf->last_log(vpm_mod()));
        return 0;
    }
    HookNote(self, image.base + rva, detour, original);
    return 1;
}

int vpm_hook(VpmComponent* self, uint32_t rva, const char* shipped, void* detour, void** original)
{
    return HookAt(self, (Image){"game.dll", g_game, g_gameSize}, rva, shipped, detour, original);
}

int vpm_hook_exe(VpmComponent* self, uint32_t rva, const char* shipped, void* detour, void** original)
{
    return HookAt(self, (Image){"helldivers2.exe", g_exe, g_exeSize}, rva, shipped, detour, original);
}

void* vpm_module_export(const char* module, const char* name)
{
    if (g_hooks.module_export != NULL) return g_hooks.module_export(module, name);
    HMODULE handle = GetModuleHandleA(module); /* lint-ok: C4 looked up once, never per frame */
    return handle != NULL ? (void*)GetProcAddress(handle, name) : NULL; /* lint-ok: C4 looked up once, never per frame */
}

int vpm_game_code_matches(uint32_t rva, const char* pattern)
{
    return g_game != 0 && rva < g_gameSize && vpm_core_hf()->code_matches(g_game + rva, pattern);
}

int vpm_exe_code_matches(uint32_t rva, const char* pattern)
{
    return g_exe != 0 && rva < g_exeSize && vpm_core_hf()->code_matches(g_exe + rva, pattern);
}

/* ---- the game's hash lookup ------------------------------------------------------------------------------------- */

typedef struct LookupHeader { uint64_t rows; uint32_t capacity, empty, multiplier; } LookupHeader;

int vpm_lookup(uintptr_t header, uint32_t key, uint32_t limit, uint32_t* index)
{
    LookupHeader h;
    if (!vpm_read(header, &h, 20)) return 0;
    if (!vpm_plausible((uintptr_t)h.rows) || h.capacity == 0 || h.capacity > limit || (h.capacity & (h.capacity - 1)) != 0) return 0;
    uint32_t product = key * h.multiplier;
    uint32_t probes = h.capacity < 64 ? h.capacity : 64;
    for (uint32_t probe = 0; probe < probes; probe++)
    {
        uint32_t row[2];
        if (!vpm_read((uintptr_t)h.rows + 8ull * ((product + probe) & (h.capacity - 1)), row, sizeof row)) return 0;
        if (row[0] == key)
        {
            if (row[1] == 0xFFFFFFFFu) return 0;
            *index = row[1];
            return 1;
        }
        if (row[0] == h.empty) return 0;
    }
    return 0;
}

/* ---- the local player -------------------------------------------------------------------------------------------- *
 * Arc Thrower Revamped v1.7.1 (arc_thrower_auto.lua local_avatar, fire_slot, kept_slot), unchanged. */

#define AVATAR_TYPE_LOW 0x294DFA97u  /* the avatar entity type, '\x97\xfa\x4d\x29\x4d\x33\x1c\x4d' */
#define AVATAR_TYPE_HIGH 0x4D1C334Du
#define PM_COUNTS 0x84u              /* player manager: two counts, each 1 .. 4 with a local player */
#define PM_UNIT 0x3A8u               /* the local player's unit id (0x7FFF: none) */
#define PM_PLAYER 0xE8u              /* the local player's record pointer (24 bytes, owned bit) */
#define OWNER_LOOKUP 0xF22EC8u       /* entity owner: unit id -> entity index */
#define OWNER_RECORDS 0xF32F18u      /* entity owner: 24-byte entity records */
#define AM_LOOKUP 0xF8u              /* avatar manager: avatar id -> avatar index */
#define AM_COUNT 0x6Cu
#define AM_ENTITIES 0x110u
#define AM_SLOTS 0x150u
#define AM_STRIDE 0xA7AECu
#define AM_ACTIONS 0x1B68u

static int Owned(const uint32_t* record) { return (record[5] & 1u) == 1u; }

/* The local player's avatar record in the entity owner: 1 with a->record, record_at and owner_index set, or 0 and why. */
static int LocalRecord(VpmAvatar* a, const char** why)
{
    uintptr_t pm = (uintptr_t)vpm_game_u64(VPM_RVA_PLAYER_MANAGER), owner = (uintptr_t)vpm_game_u64(VPM_RVA_ENTITY_OWNER);
    if (pm == 0 || owner == 0) { *why = "no player manager or entity owner"; return 0; }
    uint32_t counts[2], unit;
    if (!vpm_read(pm + PM_COUNTS, counts, sizeof counts) || !vpm_read_u32(pm + PM_UNIT, &unit)) { *why = "player manager unreadable"; return 0; }
    if (counts[0] < 1 || counts[0] > 4 || counts[1] < 1 || counts[1] > 4 || unit == 0x7FFFu) { *why = "no local player"; return 0; }
    uint32_t player[6];
    uintptr_t playerRecord = vpm_ptr(pm + PM_PLAYER);
    if (playerRecord == 0 || !vpm_read(playerRecord, player, sizeof player) || !Owned(player)) { *why = "no owned local player record"; return 0; }
    uint32_t ei;
    if (!vpm_lookup(owner + OWNER_LOOKUP, unit, 1048576u, &ei) || ei >= 262144u) { *why = "the player's unit has no entity"; return 0; }
    a->record_at = owner + OWNER_RECORDS + (uintptr_t)ei * 24u;
    a->owner_index = ei;
    if (!vpm_read(a->record_at, a->record, 24) || a->record[0] != AVATAR_TYPE_LOW || a->record[1] != AVATAR_TYPE_HIGH || !Owned(a->record))
    {
        *why = "not an owned Helldiver avatar";
        return 0;
    }
    return 1;
}

int vpm_local_avatar_why(VpmAvatar* out, const char** why)
{
    const char* reason = "";
    VpmAvatar a;
    memset(&a, 0, sizeof a);
    int found = LocalRecord(&a, &reason);
    uint32_t ai = 0, count = 0, entity[6];
    if (found) a.manager = (uintptr_t)vpm_game_u64(VPM_RVA_AVATAR_MANAGER);
    if (found && a.manager == 0) { reason = "no avatar manager"; found = 0; }
    if (found && (!vpm_lookup(a.manager + AM_LOOKUP, a.record[2], 64u, &ai) || !vpm_read_u32(a.manager + AM_COUNT, &count) ||
            count > 8 || ai >= count))
    {
        reason = "the avatar is not in the avatar manager";
        found = 0;
    }
    if (found)
    {
        a.index = ai;
        a.entity = vpm_ptr(a.manager + AM_ENTITIES + (uintptr_t)ai * 8u);
        if (a.entity == 0 || !vpm_read(a.entity, entity, sizeof entity) || memcmp(entity, a.record, 24) != 0)
        {
            reason = "the avatar manager's entity is another";
            found = 0;
        }
    }
    if (why != NULL) *why = found ? "" : reason;
    if (found) *out = a;
    return found;
}

int vpm_local_avatar(VpmAvatar* out) { return vpm_local_avatar_why(out, NULL); }

int vpm_avatar_still(const VpmAvatar* avatar)
{
    if (avatar->manager == 0 || (uintptr_t)vpm_game_u64(VPM_RVA_AVATAR_MANAGER) != avatar->manager) return 0;
    uintptr_t entity = vpm_ptr(avatar->manager + AM_ENTITIES + (uintptr_t)avatar->index * 8u);
    uint32_t record[6];
    return entity == avatar->entity && vpm_read(entity, record, sizeof record) && memcmp(record, avatar->record, 24) == 0;
}

uintptr_t vpm_action_slot(const VpmAvatar* avatar, uint32_t slot)
{
    return avatar->manager + AM_SLOTS + (uintptr_t)avatar->index * AM_STRIDE + AM_ACTIONS + (uintptr_t)slot * 32u;
}
