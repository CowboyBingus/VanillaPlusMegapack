/* Armory Preview Cache v23.1 (Lua: components/ArmoryPreviewCache/src in the Megapack v42: install.lua, native.lua,
 * policy.lua, profile.lua, dependencies.lua, image_native.lua, images.lua and their signature lists), build 25480438.
 *
 * Speeds up equipment thumbnails in the Armory and the mission briefing. The game renders every thumbnail again on each
 * visit (six cards of up to 15 requests, into one working atlas the thumbnail manager owns). This component:
 *   - keeps package leases on the assets those thumbnails load (and on the ones the learned profile says come next, and
 *     their weapons' attachments), so a revisit finds them resident (apc_native.c, apc_deps.c, apc_policy.c);
 *   - retains completed atlases at a safe boundary (it hands the manager a fresh atlas the engine creates and keeps the
 *     completed one) and shows their crops on the tiles until the game renders the same requests again (apc_state.c,
 *     apc_decode.c, apc_present.c, apc_images.c).
 * Everything it changes it gives back: leases are released when the screen closes, the world changes or memory runs low,
 * and tiles go back to the native pipeline before a retained atlas is released.
 *
 * On HellForge. The Lua ran in the game's Lua `update`: its step (the binding check) before the Lua updates below it in
 * the chain, its frame (the image tick, then a policy step every 50 ms) after them, both before game.dll's frame update.
 * The core's tick runs at the start of that update, the same point (vpm.h), so one tick runs the step and then the frame
 * with the frame's dt: the handoffs and bindings land before game.dll's UI pass and the render, as in the Lua. (The Lua
 * updates below the mod, other mods' and the game's own, now come before the step too; the thumbnail pipeline the step
 * checks is game.dll's, which runs after.) The tick can start before
 * the game sets up its engine API (the Lua's first update came later): it waits for that pointer (one plain load per
 * frame, at most 600 s) before the checks the Lua made at its first update. The code-byte checks among them are the
 * core's wait (vpm_when_code_ready, from HF_EVENT_GAME_LOADED): game.dll's code is decoded in parts after that event,
 * and the first tick comes right after it; the tick does nothing until every signature reads as shipped (checked again
 * every 30 frames; the core stops the component, naming the instruction, if they do not within 60 s, before anything
 * was leased or bound). The Lua's profile and settings lived in
 * %LOCALAPPDATA%: the profile is now ArmoryPreviewCache.profile in the component's data folder (vpm_data_folder:
 * %LOCALAPPDATA%\CowboyBingus\VanillaPlusMegapack\armory_preview_cache, HellForge's LOCALAPPDATA), the settings (prewarm, images) are keys of
 * the pack's settings file ([armory_preview_cache]), "enabled" is the component's switch. verify_gate (a developer
 * check), the diagnostics log file, the shutdown cleanup (HellForge has no shutdown event) and the update-chain pause
 * (no update chain) are not ported. Memory telemetry reads GlobalMemoryStatusEx only (the Lua's process memory read fed
 * the diagnostics log only). The session clock is the sum of the frames' dt (the Lua read GetTickCount).
 *
 * Errors. Every check the Lua asserted fails the same way here: the frame's work stops, the error counts as the Lua's
 * update guard counted it (the first of a burst is logged; 8 without 3600 clean frames between them stop the component,
 * whose stop hands everything back), and a failed asset snapshot only waits ("waiting_for_ui"), as the Lua's pcall did.
 * That wait releases the leases and saves the profile as the Lua's cleanup did, but keeps the retained images: the
 * Lua's cleanup handed them back too, and the next frame retained the request again, an atlas created and destroyed
 * every 50 ms for as long as the snapshot failed. The image tick checks its own state every frame.
 *
 * Mod content (HellForge). HellForge keeps mod content's own records after the vanilla ones in its copies of the game's
 * tables: a loadout package record from 541, a weapon configuration from 325, past the Lua's bounds (540, 324). The
 * Lua failed its whole catalogue then, so no lease and no image survived while such content was loaded. Those rows are
 * skipped instead (apc_native.c, apc_deps.c): their items get no lease, as items the component does not know, and load as
 * the game loads them; every vanilla item keeps its lease, every thumbnail (mod content's too, the image side never
 * reads the catalogues) its cached image. The log says how many rows were skipped, once per count (a new count when
 * HellForge loads its data again). Skipping reads nothing more: the tables are read whole, as before.
 *
 * COST per frame (pinned by tests/components/armory_preview_cache_test.c; the Lua's pins are its
 * tests/test_frame_budget.lua, which counted a stand-in asset adapter without reads). A read is vpm_read, a guarded
 * plain load (no Windows call, unmeasured in game; the Lua's api.read was ReadProcessMemory, 1-2 us in game);
 * game.dll's statics are plain loads (the Lua read those through ReadProcessMemory too).
 *   Idle (ship or mission with nothing held; images held outside a menu between memory polls): 1 read (the state stack;
 *   the globals block is a plain load), no Windows call. The Lua: 2 reads.
 *   Armory grid, nothing changed: nothing bound 8 reads (the Lua: 10), crops bound 17 (the Lua: 21); weapon pre-select 10
 *   (the Lua: 12); each such frame 1 GetCurrentThreadId (the Lua's thread check). A 50 ms policy step adds 2 reads (the
 *   lease table's owner) and 1 GlobalMemoryStatusEx (the Lua: 2 reads, GlobalMemoryStatusEx and K32GetProcessMemoryInfo);
 *   a step that cannot reuse its snapshot reads it (ship 5; Armory 12 + 1 per attachment group: the lease table's owner 2,
 *   the stack, the UI world and busy flag, the manager, the catalogue key 4, the dependency identity 1 + groups, the
 *   preview ring); a lease taken or released 6 (the table before and after), the valid-lease check 3; the profile save
 *   after a menu closes (file I/O on that frame; 5 s throttle).
 *   A frame whose screen changed (a full image tick): the refresh, the decode (a grid: a column count per row, one read
 *   per tile), the setters for every tile with a crop; the next frame's binding check reads 7 per binding. The test's
 *   12-tile grid: 53 reads on the first Armory frame (a handoff included), 200 and 98 on the next two (the binding
 *   checks, a second full tick and the first step with its catalogue build), then 17.
 * Once per session: 20 code_matches (16 functions) at HF_EVENT_GAME_LOADED (again every 30 frames while the code is not
 * decoded, at most 60 s; the tick reads nothing meanwhile), 7 reads of the engine's application API, the profile read.
 * Per catalogue change: up to 1024 kit reads, the presets, the weapon table, the attachment rows and their package
 * lookups. */
#include <windows.h>
#include <stdio.h>
#include "apc.h"

#define SECTION "armory_preview_cache"
#define PROFILE L"ArmoryPreviewCache.profile"
#define STEP_SECONDS 0.05
#define MEMORY_IDLE_POLL 2.0
#define ERRORS_STOP 8
#define CLEAN_FRAMES 3600
#define WAIT_SECONDS 600.0

static struct
{
    VpmComponent* self;
    int prewarm, images;                 /* the settings */
    int code_ready;                      /* every signature read as shipped (the core's wait) */
    int started, ready, policy_ready, profile_loaded;
    double waited;                       /* for the engine API */
    unsigned long thread;
    double clock;
    int thread_checked;
    double elapsed, memory_wait;
    int has_last;                        /* the Lua's last_s */
    uint64_t policy_version, lease_version;
    int pressure_reason, policy_pressure;
    ApcGuard guard;
    int has_gate;
    uintptr_t gate_tm;
    int startup_closed;
    int has_folder;
    wchar_t folder[MAX_PATH];
    int has_last_save, profile_error;
    double last_save;
    int has_last_profile;
    size_t last_profile_size;
    int errors, clean_run, failed;
    char burst[192], logged[192];
    const char* status;
    int was_open;
    uint32_t skipped_weapons, skipped_configurations; /* the last counts logged */
} s;

static ApcAssetSnap g_last;
static char g_profile[APC_PROFILE_MAX];
static char g_lastProfile[APC_PROFILE_MAX];
static char g_error[192];
static ApcMemoryFn g_memory;

/* ---- what the component's files share --------------------------------------------------------------------------- */

int apc_fail(const char* message)
{
    if (g_error[0] == 0) snprintf(g_error, sizeof g_error, "%s", message);
    return 0;
}

const char* apc_error(void) { return g_error; }
void apc_error_clear(void) { g_error[0] = 0; }

int apc_read(uintptr_t address, void* out, size_t size) { return size >= 1 && size <= 32768 && vpm_read(address, out, size); }

int apc_need(uintptr_t address, void* out, size_t size, const char* message)
{
    return apc_read(address, out, size) ? 1 : apc_fail(message);
}

static uint32_t Slot(const ApcMap* map, uint64_t key)
{
    return (uint32_t)((key * 0x9E3779B97F4A7C15ull) >> 32) & (map->capacity - 1);
}

void apc_map_clear(ApcMap* map)
{
    memset(map->used, 0, map->capacity);
    map->count = 0;
}

int apc_map_put(ApcMap* map, uint64_t key, uint64_t value)
{
    for (uint32_t i = Slot(map, key), n = 0; n < map->capacity; i = (i + 1) & (map->capacity - 1), n++)
    {
        if (map->used[i] && map->keys[i] == key) { map->values[i] = value; return 1; }
        if (map->used[i]) continue;
        if (map->count + 1 >= map->capacity) return 0;
        map->used[i] = 1;
        map->keys[i] = key;
        map->values[i] = value;
        map->count++;
        return 1;
    }
    return 0;
}

int apc_map_get(const ApcMap* map, uint64_t key, uint64_t* value)
{
    for (uint32_t i = Slot(map, key), n = 0; n < map->capacity && map->used[i]; i = (i + 1) & (map->capacity - 1), n++)
        if (map->keys[i] == key) { *value = map->values[i]; return 1; }
    return 0;
}

/* The next at most 128 bytes of an IDA-style pattern ("45 85 C0 ..."), as a pattern of their own; how many it took. */
static uint32_t Chunk(const char* hex, size_t* at, char* out)
{
    uint32_t bytes = 0;
    size_t n = 0;
    while (hex[*at] != 0 && bytes < 128)
    {
        if (hex[*at] == ' ') { (*at)++; continue; }
        if (n > 0) out[n++] = ' ';
        out[n++] = hex[*at];
        out[n++] = hex[*at + 1] != 0 ? hex[*at + 1] : '?';
        *at += hex[*at + 1] != 0 ? 2 : 1;
        bytes++;
    }
    out[n] = 0;
    return bytes;
}

/* The signatures as the core's wait checks them: each in patterns of at most 128 bytes (HellForge's code_matches takes
 * 256), in the Lua's order, named for the refusal ("Native instruction changed (game.dll 0x12FE361)"). */
#define MAX_PINS 32
static VpmCodePin g_pins[MAX_PINS];
static char g_pinText[MAX_PINS][3 * 128 + 1];
static int g_pinCount;

/* 1, or 0 when they do not fit (not with the pack's lists). */
static int AddPins(const ApcSignature* signatures, int count, const char* name)
{
    for (int i = 0; i < count; i++)
    {
        size_t at = 0;
        for (uint32_t offset = 0;;)
        {
            if (g_pinCount >= MAX_PINS) return 0;
            char* pattern = g_pinText[g_pinCount];
            uint32_t bytes = Chunk(signatures[i].hex, &at, pattern);
            if (bytes == 0) break;
            uint32_t flags = signatures[i].exe ? VPM_PIN_EXE : 0u;
            g_pins[g_pinCount] = (VpmCodePin){signatures[i].rva + offset, pattern, name, flags};
            g_pinCount++;
            offset += bytes;
        }
    }
    return 1;
}

static void CodeReady(VpmComponent* self, HfEvent event) { s.code_ready = 1; }

/* Every signature the Lua checked (the image ones with images on) handed to the core's wait. 1, or 0 refused. */
static int WaitForCode(VpmComponent* self)
{
    int native = 0, game = 0, exe = 0;
    const ApcSignature* nativeSignatures = apc_native_signatures(&native);
    const ApcSignature* gameSignatures = apc_present_signatures(0, &game);
    const ApcSignature* exeSignatures = apc_present_signatures(1, &exe);
    g_pinCount = 0;
    if (!AddPins(nativeSignatures, native, "Native instruction")) return 0;
    if (s.images && !AddPins(gameSignatures, game, "Image instruction")) return 0;
    if (s.images && !AddPins(exeSignatures, exe, "Image instruction")) return 0;
    return vpm_when_code_ready(self, g_pins, g_pinCount, CodeReady);
}

void apc_set_memory_source(ApcMemoryFn fn) { g_memory = fn; }

static int Memory(uint64_t* free, uint64_t* commit)
{
    if (g_memory != NULL) return g_memory(free, commit);
    MEMORYSTATUSEX status;
    status.dwLength = sizeof status;
    if (!GlobalMemoryStatusEx(&status)) return 0; /* lint-ok: C4 a memory poll: a policy step in a menu, or every 2 s */
    *free = status.ullAvailPhys;
    *commit = status.ullAvailPageFile;
    return 1;
}

/* ---- status and log ------------------------------------------------------------------------------------------------ */

static void SetStatus(const char* status)
{
    if (s.status != NULL && strcmp(s.status, status) == 0) return;
    s.status = status;
    vpm_set_status(s.self, status);
}

/* A menu visit's end: the session's lease and image counts, once per visit. */
static void VisitOver(void)
{
    const ApcPolicy* p = apc_policy();
    const ApcImageStats* st = apc_images_stats();
    vpm_log(s.self, "menu closed: leases %u taken, %u released, %u reused; images %u retained, %u shown from the cache, %u held",
        p->acquires, p->releases, p->hits, st->retained, st->hits, st->textures);
}

static void NoteStatus(const char* status)
{
    int open = strcmp(status, "resident") == 0 || strcmp(status, "thumbnail_ui_busy") == 0 ||
        strcmp(status, "foreground_lookahead") == 0;
    if (s.was_open && strcmp(status, "outside_ship_ui") == 0) VisitOver();
    s.was_open = open;
    SetStatus(status);
}

/* A message logged once per distinct text (a snapshot that keeps failing, a save that keeps failing). */
static void LogOnce(const char* what, const char* text)
{
    char line[192];
    snprintf(line, sizeof line, "%s: %s", what, text);
    if (strcmp(line, s.logged) == 0) return;
    snprintf(s.logged, sizeof s.logged, "%s", line);
    vpm_log(s.self, "%s", line);
}

/* ---- the profile file -------------------------------------------------------------------------------------------- */

static void ProfilePath(wchar_t* out, size_t size, const wchar_t* suffix)
{
    _snwprintf(out, size, L"%ls\\%ls%ls", s.folder, PROFILE, suffix);
    out[size - 1] = 0;
}

/* The file's text (at most limit + 1 bytes, so an oversized file reads as invalid), or 0 bytes when absent. */
static size_t ReadProfile(const wchar_t* suffix, char* text, size_t limit)
{
    wchar_t path[MAX_PATH + 32];
    ProfilePath(path, MAX_PATH + 32, suffix);
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL); /* lint-ok: C4 once, when the component initializes */
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD got = 0;
    BOOL ok = ReadFile(file, text, (DWORD)limit, &got, NULL); /* lint-ok: C4 once, when the component initializes */
    CloseHandle(file); /* lint-ok: C4 once, when the component initializes */
    return ok ? got : 0;
}

static void LoadProfile(void)
{
    static char text[APC_PROFILE_MAX + 1];
    s.profile_loaded = 1;
    if (!s.has_folder) return;
    size_t size = ReadProfile(L"", text, sizeof text);
    if (apc_profile_decode(size ? text : NULL, size, VPM_GAME_BUILD, 1)) return;
    size = ReadProfile(L".bak", text, sizeof text);
    (void)apc_profile_decode(size ? text : NULL, size, VPM_GAME_BUILD, 1);
}

/* Written to .tmp; the old file kept as .bak while it is replaced (a truncated file never decodes). */
static int WriteProfile(const char* text, size_t size)
{
    wchar_t temporary[MAX_PATH + 32], backup[MAX_PATH + 32], path[MAX_PATH + 32];
    ProfilePath(temporary, MAX_PATH + 32, L".tmp");
    ProfilePath(backup, MAX_PATH + 32, L".bak");
    ProfilePath(path, MAX_PATH + 32, L"");
    if (!vpm_data_folder(s.self, s.folder, MAX_PATH)) return 0; /* made again if it went missing */
    HANDLE file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL); /* lint-ok: C4 a profile save, after a menu closes */
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD wrote = 0;
    BOOL ok = WriteFile(file, text, (DWORD)size, &wrote, NULL) && wrote == size; /* lint-ok: C4 a profile save */
    ok = CloseHandle(file) && ok; /* lint-ok: C4 a profile save */
    if (!ok) return 0;
    (void)DeleteFileW(backup); /* lint-ok: C4 a profile save */
    (void)MoveFileW(path, backup); /* lint-ok: C4 a profile save */
    if (!MoveFileW(temporary, path)) return 0; /* lint-ok: C4 a profile save */
    (void)DeleteFileW(backup); /* lint-ok: C4 a profile save */
    return 1;
}

/* Only remembering changes the learned list: without it the encoding equals the saved text, so the throttled save
 * skips encoding it. A failed save is retried every 5 s; the idle gate stops waiting for it. */
static void Save(int force)
{
    ApcPolicy* p = apc_policy();
    if (!s.policy_ready || !s.profile_loaded || !s.has_folder) return;
    if (!force && s.has_last_save && s.clock - s.last_save < 5) return;
    s.last_save = s.clock;
    s.has_last_save = 1;
    if (!force && p->profile_changed == 0) return;
    size_t size = apc_profile_encode(g_profile, sizeof g_profile, VPM_GAME_BUILD);
    if (s.has_last_profile && size == s.last_profile_size && memcmp(g_profile, g_lastProfile, size) == 0)
    {
        p->profile_changed = 0;
        return;
    }
    if (!WriteProfile(g_profile, size))
    {
        s.profile_error = 1;
        LogOnce("the profile could not be saved", "the file or its folder is not writable");
        return;
    }
    memcpy(g_lastProfile, g_profile, size);
    s.last_profile_size = size;
    s.has_last_profile = 1;
    p->profile_changed = 0;
}

/* ---- start-up, cleanup ------------------------------------------------------------------------------------------- */

/* The profile saved, every lease released (only through revalidated ownership). */
static void ReleaseLeases(void)
{
    if (!s.policy_ready) return;
    Save(1);
    if (!apc_policy_clear()) LogOnce("cleanup", apc_error());
    apc_error_clear();
}

/* Every tile back to the native pipeline, every retained atlas and lease released, the profile saved. */
static void Cleanup(void)
{
    if (s.images && s.ready && !apc_images_clear("cleanup")) LogOnce("image cleanup", apc_error());
    apc_error_clear();
    ReleaseLeases();
}

/* HellForge's records for mod content the catalogues skipped: said once per count. */
static void NoteSkipped(void)
{
    uint32_t weapons = apc_native_skipped(), configurations = apc_deps_skipped();
    if (weapons == s.skipped_weapons && configurations == s.skipped_configurations) return;
    s.skipped_weapons = weapons;
    s.skipped_configurations = configurations;
    if (weapons + configurations == 0) return;
    vpm_log(s.self, "mod content: %u loadout package records and %u weapon configurations past the Lua's bounds (HellForge's records for mod content) skipped: those items load as the game loads them, without leases",
        weapons, configurations);
}

static int Initialize(void)
{
    s.started = 1;
    s.thread = GetCurrentThreadId(); /* lint-ok: C4 once, when the component initializes */
    if (!apc_native_init()) return 0;
    apc_policy_reset(s.prewarm);
    s.policy_ready = 1;
    apc_state_reset();
    if (s.images && !apc_present_init()) return 0;
    apc_images_reset(s.images);
    s.ready = 1;
    LoadProfile();
    vpm_log(s.self, "running: package leases (prewarm %s) and rendered-image retention %s; %d learned items from the profile",
        s.prewarm ? "on" : "off", s.images ? "on" : "off", apc_policy()->learned_count);
    return 1;
}

/* The engine API's root and the application table it points at: set up by the game, maybe after the first tick; and
 * the code checked (the core's wait). 1 initialized, 0 waiting, -1 stopped. */
static int StartWhenReady(double dt)
{
    if (!s.code_ready) return 0;
    uintptr_t root = ApcGamePointer(APC_RVA_ROOT_API);
    int waiting = root == 0 || (root == vpm_exe() + APC_EXE_ROOT_API && vpm_exe_u64(APC_EXE_ROOT_API + 16) == 0);
    if (waiting)
    {
        s.waited += dt;
        if (s.waited >= WAIT_SECONDS) vpm_fail(s.self, "gave up after %.0f s: the engine API is not set up yet", WAIT_SECONDS);
        return 0;
    }
    if (Initialize()) return 1;
    vpm_fail(s.self, "%s", apc_error());
    return -1;
}

/* ---- the frame ------------------------------------------------------------------------------------------------- */

static int AssertThread(void)
{
    return GetCurrentThreadId() == s.thread ? 1 : apc_fail("Wrong update thread"); /* lint-ok: C4 a frame that acts (the Lua's thread check) */
}

/* The idle gate's conditions without a read: no lease, no memory pressure or guard, no profile save pending, the image
 * cache quiet. */
static int Quiet(void)
{
    const ApcPolicy* p = apc_policy();
    if (!s.has_last || p->lease_count > 0 || s.guard.active || s.pressure_reason != APC_PRESSURE_NONE) return 0;
    if (s.has_folder && p->profile_changed == 1 && !s.profile_error) return 0;
    return !s.images || apc_images_quiet();
}

/* A frame is idle when neither the image tick nor the asset step could do anything but repeat itself: no Armory or
 * briefing on the state stack, the startup window closed (or the stack not empty, which it needs), the thumbnail manager
 * the last working frame saw. With rendered images held, memory is still polled every 2 s (a working frame), so
 * pressure keeps releasing them. The 50 ms step clock runs on as if each step had found nothing to do. lint: per-frame */
static int Idle(double seconds)
{
    uintptr_t tm;
    uint32_t depth;
    int32_t top;
    if (!Quiet()) return 0;
    if (s.images && apc_images_texture_count() > 0 && s.memory_wait <= 0) return 0;
    if (!apc_state_probe(&tm, &depth, &top) || !s.has_gate || tm != s.gate_tm || top == 5 || top == 14 ||
        (depth == 0 && !s.startup_closed))
        return 0;
    s.elapsed += seconds;
    if (s.elapsed >= STEP_SECONDS)
    {
        s.memory_wait -= s.elapsed;
        s.elapsed = 0;
    }
    return 1;
}

/* Whether this step can reuse the last asset snapshot: everything it read is in the state view and unchanged since. With
 * an empty state stack or no world the snapshot still reads the manager, so those steps read afresh. */
static int Reusable(uint64_t refreshes)
{
    if (!s.has_last) return 0;
    ApcState* st = apc_state();
    if (st->refreshes == refreshes) apc_state_refresh();
    apc_state_refresh_lease();
    if (!(st->g_ok && st->stack_ok && st->ui_ok) || (st->has_depth && st->depth == 0) || (st->kind && !st->world)) return 0;
    return st->policy_version == s.policy_version && st->lease_version == s.lease_version;
}

static int MemoryMatters(const ApcAssetSnap* snap)
{
    return snap->menu || snap->prefetch || s.guard.active || apc_policy()->lease_count > 0 ||
        (s.images && apc_images_texture_count() > 0);
}

/* Memory telemetry feeds the guard. It changes what a step does only in a menu, in the startup window, while leases or
 * images are held, or while the guard is tripped: then memory is polled every step. Otherwise every 2 s. */
static int PollMemory(const ApcAssetSnap* snap, double seconds)
{
    s.memory_wait -= seconds;
    if (s.memory_wait > 0 && !MemoryMatters(snap)) return 1;
    s.memory_wait = MEMORY_IDLE_POLL;
    uint64_t free = 0, commit = 0;
    if (!Memory(&free, &commit)) return apc_fail("Memory telemetry unavailable");
    uint32_t trips = s.guard.trips;
    int was = s.guard.active;
    s.pressure_reason = apc_guard_tick(&s.guard, s.clock, free, commit);
    if (s.guard.trips != trips)
        vpm_log(s.self, "memory low (%s, %llu MiB free, %llu MiB commit headroom): leases and retained images released until it recovers",
            apc_pressure_text(s.pressure_reason), (unsigned long long)(free >> 20), (unsigned long long)(commit >> 20));
    else if (was && !s.guard.active)
        vpm_log(s.self, "memory recovered");
    return 1;
}

/* After a full policy step: the startup window never reopens once a menu was seen or 60 s passed since the first. */
static void NoteStartup(double now)
{
    const ApcPolicy* p = apc_policy();
    if (s.startup_closed) return;
    s.startup_closed = !p->prewarm || p->seen_menu || (p->has_started && now - p->started >= 60);
}

/* The 50 ms asset step. Loading screens can remove managers: a snapshot that fails holds nothing new and releases the
 * leases, only through revalidated ownership (as the Lua). The retained images stay: the image tick checks its own
 * state every frame (the manager, the atlas owner, each texture's identity), and the Lua's handing them back here made
 * the next frame retain the request again, an atlas created and destroyed every 50 ms while the snapshot failed.
 * lint: per-frame */
static int PolicyStep(double seconds, uint64_t refreshes)
{
    int reuse = Reusable(refreshes);
    if (!reuse)
    {
        if (!apc_native_snapshot(&g_last))
        {
            char why[192];
            snprintf(why, sizeof why, "%s", apc_error());
            apc_error_clear();
            s.has_last = 0;
            ReleaseLeases();
            NoteStatus("waiting_for_ui");
            LogOnce("waiting for the UI", why);
            return 1;
        }
        s.has_last = 1;
        s.policy_version = apc_state()->policy_version;
        s.lease_version = apc_state()->lease_version;
        NoteSkipped();
    }
    if (!PollMemory(&g_last, seconds)) return 0;
    if (reuse && apc_policy()->settled && s.pressure_reason == s.policy_pressure) apc_policy_replay();
    else
    {
        if (!apc_policy_tick(&g_last, s.clock, s.pressure_reason != APC_PRESSURE_NONE)) return 0;
        NoteStartup(s.clock);
        s.policy_pressure = s.pressure_reason;
    }
    NoteStatus(apc_policy()->status);
    /* Learned entries are saved after a menu closes. */
    if (!g_last.menu && !g_last.active) Save(0);
    return 1;
}

/* The Lua's frame (after the game's update): the idle gate, the image tick every frame, the asset step every 50 ms.
 * lint: per-frame */
static int Frame(double dt)
{
    if (!s.started && StartWhenReady(dt) <= 0) return 1;
    double seconds = dt < 0 ? 0 : dt > 0.25 ? 0.25 : dt;
    if (Idle(seconds)) return 1;
    if (!s.thread_checked && !AssertThread()) return 0;
    uint64_t refreshes = apc_state()->refreshes;
    /* Presentation runs every frame, independent of the slower asset step: a 50 ms image poll would itself delay. */
    if (s.images && !apc_images_tick(s.pressure_reason != APC_PRESSURE_NONE)) return 0;
    s.has_gate = 1;
    s.gate_tm = apc_state()->tm;
    s.elapsed += seconds;
    if (s.elapsed < STEP_SECONDS) return 1;
    seconds = s.elapsed;
    s.elapsed = 0;
    return PolicyStep(seconds, refreshes);
}

/* The Lua's step (before the game's update): the thread check and the image bindings' check when bindings exist; the
 * last frame's probe is not this frame's state. lint: per-frame */
static int Step(void)
{
    if (!s.ready) return 1;
    apc_state_unprobe();
    s.thread_checked = s.images && apc_images_bound();
    return !s.thread_checked || (AssertThread() && apc_images_before());
}

/* An error: the first of a burst is logged; 8 without 3600 clean frames between them stop the component. */
static void Failed(void)
{
    s.failed = 1;
    s.clean_run = 0;
    s.errors++;
    if (s.errors == 1)
    {
        snprintf(s.burst, sizeof s.burst, "%s", apc_error());
        vpm_log(s.self, "error: %s", s.burst);
    }
    apc_error_clear();
    if (s.errors >= ERRORS_STOP) vpm_fail(s.self, "stopped after %d errors: %s", ERRORS_STOP, s.burst);
}

/* The Lua's update: its step, then (after the Lua updates below it, which came before this point too) its frame. lint:
 * per-frame */
static void Tick(VpmComponent* self, float dt)
{
    s.clock += dt;
    s.failed = 0;
    apc_error_clear();
    if (!Step()) Failed();
    if (!vpm_running(self)) return;
    if (!Frame(dt)) Failed();
    if (!vpm_running(self) || s.failed) return;
    if (++s.clean_run == CLEAN_FRAMES) s.errors = 0;
}

/* The core stopping the component (8 errors, a fault, a failed start): everything handed back. */
static void Stop(VpmComponent* self)
{
    apc_error_clear();
    Cleanup();
}

static int Setting(const char* key)
{
    const char* value = vpm_setting(SECTION, key);
    return value == NULL || (value[0] != '0' && value[0] != '1') ? 1 : value[0] == '1';
}

static int Start(VpmComponent* self)
{
    memset(&s, 0, sizeof s);
    s.self = self;
    s.prewarm = Setting("prewarm");
    s.images = Setting("images");
    s.has_folder = vpm_data_folder(self, s.folder, MAX_PATH); /* once, at start-up */
    apc_error_clear();
    apc_state_reset();
    apc_decode_reset();
    apc_present_reset();
    apc_images_reset(0);
    apc_deps_reset();
    apc_policy_reset(s.prewarm);
    vpm_set_status(self, "starting");
    s.status = "starting";
    if (!WaitForCode(self)) return vpm_fail(self, "game.dll's code checks refused");
    return vpm_tick_start(self, Tick) ? 0 : vpm_fail(self, "the game thread could not be reached");
}

const VpmComponentDef vpm_component_armory_preview_cache = {"armory_preview_cache", "Armory Preview Cache", "23.1", 0, Start, Stop};
