-- HD2-Addon: mods/cowboybingus/mod_bindings_menu
-- Native bindings-page extension for Steam build 25480438.
if rawget(_G, 'ModBindingsMenu') then return end
local ffi = require('ffi')
local bit = require('bit')
-- Texts and translations: mbm_text = {module = src/bingus_text.lua, locales =
-- locales/}; the other source files: mbm_files.<name> = src/<name>.lua as a
-- function, each run once below: Mod Bindings Menu's own with the shared table
-- mbm, Bingus Shared Runtime's vendored copies (bingus_runtime.lua,
-- bingus_memory.lua) without arguments, returning their tables. The build
-- places both ahead of this file as locals (tests provide them as globals).
local translation = {T = mbm_text.module}
-- Bingus Shared Runtime: the update guard (the family's update-chain policy) and
-- the module hashes every mod shares, read once per session.
local runtime = mbm_files.bingus_runtime()
local memory = mbm_files.bingus_memory().new(runtime)
local guard -- The update guard, installed at the end of this file.

-- Windows functions under private names: ffi.cdef keeps the first prototype
-- declared for a name in the whole game and silently ignores later ones, so a
-- plain name would bind to whatever another mod declared first (a textbook
-- VirtualQuery with its own MEMORY_BASIC_INFORMATION made every page write
-- raise). The __asm__ label names the real export; types are private too.
ffi.cdef [[
typedef unsigned char MBM_u8;
typedef unsigned short MBM_u16;
typedef unsigned int MBM_u32;
typedef unsigned long long MBM_u64;
typedef struct {
    void *BaseAddress; void *AllocationBase; MBM_u32 AllocationProtect;
    MBM_u16 PartitionId; size_t RegionSize; MBM_u32 State; MBM_u32 Protect; MBM_u32 Type;
} MBM_MEMORY_BASIC_INFORMATION;
void *MBM_GetCurrentProcess(void) __asm__("GetCurrentProcess");
int MBM_ReadProcessMemory(void *process, const void *address, void *buffer,
                          size_t size, size_t *received) __asm__("ReadProcessMemory");
int MBM_read_at(void *process, MBM_u64 address, void *buffer, size_t size,
                size_t *received) __asm__("ReadProcessMemory");
int MBM_VirtualProtect(void *address, size_t size, MBM_u32 protection, MBM_u32 *old) __asm__("VirtualProtect");
size_t MBM_VirtualQuery(const void *address, MBM_MEMORY_BASIC_INFORMATION *info,
                        size_t length) __asm__("VirtualQuery");
MBM_u32 MBM_GetLastError(void) __asm__("GetLastError");
]]

local kernel32 = ffi.load('kernel32')
local process = kernel32.MBM_GetCurrentProcess()
local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('ModBindingsMenu.log') end)
end
local function note(message)
    if log_file then pcall(function() log_file:write(message .. '\n'); log_file:flush() end) end
end
-- MBM's own texts, in the game's language when a translation has them.
translation.tr = translation.T.new(mbm_text.locales.en, mbm_text.locales.bundled,
                                   function(message) note('Text: ' .. message) end)

local GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
local EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
local INPUT_OWNER_PTR_RVA = 0x347cf18
local MENU_SYSTEM_PTR_RVA = 0x347ce38
local UI_STATE_PTR_RVA = 0x347ce28
-- The menu system pointer's first 32-bit word in a read at the UI state pointer.
local MENU_WORD = (MENU_SYSTEM_PTR_RVA - UI_STATE_PTR_RVA) / 4
local ACTION_LABELS_RVA = 0x26438a0
local BUILD_ROWS_RVA = 0x1812940
local ACTION_STATE_OFFSET, ACTION_STATE_STRIDE = 808, 32
local MODS_TITLE_PTR_RVA = 0x3328420
local MODS_TITLE_ID = 0x781e104c
-- Native actions of developer-only input groups (Debugmenu 12, CinematicCamera
-- 10, DebugAvatar 11, Freeflight 9). They are in the game's 235-action list, so
-- the game evaluates every trigger type for them on any device and saves their
-- user bindings by name, but nothing in retail play listens to them. Each entry
-- is {group, action, original label ID}; the native action order differs from
-- input.config's descriptor order.
local DORMANT_ACTIONS = {
    -- Fixed v1 slots 1-7: the map, the third-party slot, five ship stations.
    {12, 1, 0x62ea38bf}, {12, 0, 0x82fbdcb2}, {10, 1, 0x6218a8ba}, {10, 4, 0xd46660e4},
    {10, 8, 0xc60e3a71}, {10, 14, 0x45c3ce49}, {10, 9, 0x54041145},
    -- Automatically assigned (version 2).
    {10, 0, 0x4a681770}, {10, 2, 0x03f7407e}, {10, 3, 0x533ad91f}, {10, 5, 0xc9d1babc},
    {10, 6, 0xeb8a3b7a}, {10, 7, 0x5daaa6c3}, {10, 10, 0xf0a84860}, {10, 11, 0xaac2b10e},
    {10, 12, 0xf884272d}, {10, 13, 0x6a566af0}, {10, 15, 0x3a0b904c}, {10, 16, 0x484bb4c1},
    {10, 17, 0x5556ae64}, {11, 0, 0x2bf059b1}, {11, 1, 0x5f892216}, {11, 2, 0x0bf38a13},
    {11, 3, 0x5b786e6b}, {9, 0, 0x5d7d7666}, {9, 1, 0x020ae5fc}, {9, 2, 0x04ee429e},
    {9, 3, 0x71d71525}, {9, 4, 0x026199fa}, {9, 5, 0x62407e28}, {9, 6, 0x2a05009f},
    {9, 7, 0x6479f954}, {9, 8, 0x6306672a}, {9, 9, 0x8e53ce97}, {9, 10, 0x6e43f1c5},
    {9, 11, 0xae71f7a9},
}
local SLOTS = 7
local SLOT_CODES, ORIGINAL_LABELS = {}, {}
for index, entry in ipairs(DORMANT_ACTIONS) do
    if index <= SLOTS then SLOT_CODES[index] = {entry[1], entry[2]} end
    ORIGINAL_LABELS[entry[1] * 65536 + entry[2]] = entry[3]
end
local BINDING_MAP, DEFAULTS_MAP = 686800, 686968
local MAPPINGS_OFFSET, MAPPING_SIZE, MAX_MAPPINGS = 8, 20, 16
local ASSIGNMENTS_FILE = 'ModBindingsMenu.assignments'
-- Localization IDs whose formatted-text cache slot the game only fills for
-- argument-free lookups. The pooled IDs are English templates the game always
-- formats with arguments, so they bypass the cache elsewhere. Category
-- headers and string row labels borrow empty slots only while the bindings
-- page is displayed. Each entry is {localization ID, cache slot RVA}.
local LABEL_POOL = {
    {0x77bf158a, 0x3327800}, {0x76ad93e3, 0x3327550},
    {0xa9cf13bb, 0x3328230}, {0x431da596, 0x3328238}, {0xc80d6bd6, 0x3328248},
    {0x9845cd37, 0x3328250}, {0x9f020af7, 0x3328260}, {0x766f7a90, 0x3328268},
    {0x3707c006, 0x3328270}, {0x57063e09, 0x3328278}, {0x039cdc47, 0x3328280},
    {0x8f515fd7, 0x3328288}, {0x9cd0b591, 0x3328290}, {0xc58bdfa4, 0x3328298},
    {0xc977f7ac, 0x33282a0}, {0xfa69c153, 0x33282a8}, {0xed823922, 0x33282b0},
    {0x8cc549fb, 0x33282b8}, {0x780b23de, 0x33282c0}, {0x8296f00f, 0x33282c8},
    {0x970548b1, 0x33282d0}, {0x019bb39b, 0x33282e0}, {0xbfd44f9f, 0x33282e8},
    {0x110ebfca, 0x33282f0}, {0x1a8ae3c1, 0x3328300}, {0x34fc79a3, 0x3328310},
    {0xfc0db519, 0x3328318}, {0x1aef663a, 0x3328320}, {0x568a85ad, 0x3328328},
    {0xa1d192a5, 0x3328340}, {0xd4bb26a2, 0x3328368}, {0x1a416656, 0x3328370},
    {0x0b2f407b, 0x3328390}, {0xde392204, 0x3328398}, {0xb753331c, 0x33283b8},
    {0xb4a59ceb, 0x33283c0}, {0xfd66d0d5, 0x33283c8}, {0x9f3cb7c9, 0x33283d0},
    {0x09976730, 0x33283d8}, {0x72b848bc, 0x33283e0}, {0x6e083332, 0x33283e8},
    {0xbb4d13e4, 0x33283f0}, {0x8c084330, 0x33283f8}, {0x480ccb51, 0x3328400},
    {0xe39ec311, 0x3328408}, {0xf4bfa80d, 0x3328410}, {0xcffc99dd, 0x3328418},
    {0xccd4045f, 0x3328428}, {0x11f38dc4, 0x3328430}, {0xd8250934, 0x3328438},
    {0x43213f6d, 0x3328440}, {0x2ec24cb3, 0x3328448}, {0xf40bd215, 0x3328450},
    {0xafba9b8b, 0x3328458}, {0x0944ce13, 0x3328460}, {0xddc61cbf, 0x3328468},
    {0x61d0e824, 0x3328470}, {0xa95fd6a0, 0x3328478}, {0x7505bcbf, 0x3328480},
    {0x4777d7c3, 0x3328488}, {0x4b7ce100, 0x3328490}, {0x74f55d93, 0x3328498},
    {0x59500445, 0x33284b8}, {0x8bc421a5, 0x33284c0}, {0xacf702d0, 0x3328500},
}
local ROW_LIST_OFFSET = 338344
local ROW_STRIDE, ROW_START = 24784, 7856
-- Native tab bar shared by the keyboard and controller binding pages. The
-- widget has eight tab buttons; the page asks for three at initialisation.
local SET_TAB_LABELS_RVA = 0x17aac50
local LIST_RESET_RVA = 0x1813dd0
local TAB_LABELS_RVA = 0x3310210
local SELECTED_TAB_OFFSET = 8
local TAB_BAR_OFFSET = 1248
local TAB_COUNT, TAB_CURRENT = 57448, 57452
local TAB_BUTTON_STATE, TAB_BUTTON_ACTIVE, TAB_BUTTON_STRIDE = 11004, 11021, 3400
local NATIVE_TABS, MODS_TAB = 3, 3
local state = {initialized = false, base = nil, build_rows = nil,
               screen = nil, last_action = nil,
               registry = {}, order = {}, input_logged = false,
               buckets = {}, title_active = false,
               set_tab_labels = nil, reset_list = nil, tab_labels = nil,
               last_tab = nil,
               claims = {}, pooled = {}, action_labels = {},
               default_buckets = {}, assignments = nil, page_visited = false,
               auto_codes = {}, code_order = {}, sweep_timer = 0, swept_counts = {},
               used = {}, refused = {}, revision = 0,
               -- The MODS title's buffer, pointed at by a game slot while the
               -- page shows the tab; replaced only while no slot points at it.
               -- Earlier buffers stay referenced in titles.
               mods_text = ffi.new('char[5]', 'MODS'), titles = {},
               empty_text = 'NO MOD BINDINGS INSTALLED', page_open = false, language = nil}
for index, entry in ipairs(DORMANT_ACTIONS) do
    local code = entry[1] * 65536 + entry[2]
    state.code_order[code] = index
    if index > SLOTS then state.auto_codes[code] = true end
end

-- The API other mods use, published as the global ModBindingsMenu below.
-- revision grows by one whenever something other mods can see changes: a
-- binding registered, native input became ready, or the bindings' texts
-- changed. A mod that retries a failed registration can retry when it changed.
local api = {api = 1, version = 3, capacity = #DORMANT_ACTIONS, revision = 0}
local function revise()
    state.revision = state.revision + 1
    api.revision = state.revision
end

local function read(address, size)
    local buffer, received = ffi.new('MBM_u8[?]', size), ffi.new('size_t[1]')
    if kernel32.MBM_ReadProcessMemory(process, ffi.cast('const void *', address),
            buffer, size, received) == 0 or tonumber(received[0]) ~= size then return nil end
    return ffi.string(buffer, size)
end
local function u32(blob)
    if not blob or #blob ~= 4 then return nil end
    local number = ffi.new('MBM_u32[1]')
    ffi.copy(number, blob, 4)
    return tonumber(number[0])
end
local function u64(blob)
    if not blob or #blob ~= 8 then return nil end
    local number = ffi.new('MBM_u64[1]')
    ffi.copy(number, blob, 8)
    return tonumber(number[0])
end
-- Per-frame reads (is_down and the binding page check) allocate nothing:
-- ReadProcessMemory under a private name that takes the address as a number,
-- so no pointer cdata is made per call, into one reused 24-byte buffer that is
-- decoded in place. read() stays for the binding page and the sweep.
local words = ffi.new('MBM_u32[6]')
local words_read = ffi.new('size_t[1]')
local words_read_low = ffi.cast('MBM_u32 *', words_read)
-- Reads size bytes (at most 24) at address into words; false unless all were read.
local function read_words(address, size)
    return kernel32.MBM_read_at(process, address, words, size, words_read) ~= 0
        and words_read_low[0] == size
end
-- The u32 at address, read into words, or nil. words is shared: the value is
-- returned as a number before the next read replaces it.
local function word_at(address)
    if not read_words(address, 4) then return nil end
    return words[0]
end
-- The user-mode pointer in words[index] and words[index + 1], or nil.
local function word_pointer(index)
    local value = words[index] + words[index + 1] * 4294967296
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end
-- Every address this addon writes lies in game.dll's read-write data section,
-- so pages are normally writable as they are. Changing page protection is only
-- a fallback: the game's protection layer can start refusing VirtualProtect
-- mid-session. Returns false (never raises) when the write is not possible, so
-- callers degrade instead of leaving the bindings page half built.
local MEM_COMMIT, PAGE_GUARD = 0x1000, 0x100
local WRITABLE_PAGES = {[0x04] = true, [0x08] = true, [0x40] = true, [0x80] = true}
local refusals_logged = 0
local function write_memory(address, size, fn)
    local info = ffi.new('MBM_MEMORY_BASIC_INFORMATION')
    local pointer_value = ffi.cast('const void *', address)
    if kernel32.MBM_VirtualQuery(pointer_value, info, ffi.sizeof(info)) == 0
       or info.State ~= MEM_COMMIT then return false end
    local region_end = tonumber(ffi.cast('MBM_u64', info.BaseAddress)) + tonumber(info.RegionSize)
    if WRITABLE_PAGES[bit.band(info.Protect, 0xff)] and bit.band(info.Protect, PAGE_GUARD) == 0
       and address + size <= region_end then
        fn()
        return true
    end
    local old = ffi.new('MBM_u32[1]')
    if kernel32.MBM_VirtualProtect(ffi.cast('void *', address), size, 0x04, old) == 0 then
        if refusals_logged < 4 then
            refusals_logged = refusals_logged + 1
            note(string.format('Write refused at game.dll+0x%x (protection 0x%x, error %d).',
                               address - (state.base or 0), info.Protect, kernel32.MBM_GetLastError()))
        end
        return false
    end
    local ok, result = pcall(fn)
    local ignored = ffi.new('MBM_u32[1]')
    kernel32.MBM_VirtualProtect(ffi.cast('void *', address), size, old[0], ignored)
    if not ok then error(result) end
    return true
end

-- Binding records live in fixed 256-entry hash maps on the input owner: the
-- live bindings (+686800) and the shipped defaults (+686968). Each 328-byte
-- record is {u32 code, u32 count, 16 x 20-byte mappings}.
local RECORD_SIZE = MAPPINGS_OFFSET + MAX_MAPPINGS * MAPPING_SIZE
local MAP_RECORDS, SCAN_RECORDS = 256, 32
local scan, scan_words -- 32 records, allocated on the first scan and reused.
-- Reads size bytes at address into buffer, in place; false unless all were read.
local function read_into(address, buffer, size)
    return kernel32.MBM_read_at(process, address, buffer, size, words_read) ~= 0
        and words_read_low[0] == size
end
-- Finds the record of every dormant action in a binding map, 32 records per
-- read, and caches their addresses. False when the map cannot be read.
local function index_map(map_offset, cache)
    if not read_words(state.base + INPUT_OWNER_PTR_RVA, 8) then return false end
    local owner = word_pointer(0)
    if not owner or not read_words(owner + map_offset, 12) then return false end
    local buckets = word_pointer(0)
    if not buckets or words[2] ~= MAP_RECORDS then return false end
    if not scan then
        scan = ffi.new('MBM_u8[?]', SCAN_RECORDS * RECORD_SIZE)
        scan_words = ffi.cast('MBM_u32 *', scan)
    end
    for code in pairs(cache) do cache[code] = nil end
    for first = 0, MAP_RECORDS - 1, SCAN_RECORDS do
        local address = buckets + first * RECORD_SIZE
        if not read_into(address, scan, SCAN_RECORDS * RECORD_SIZE) then return false end
        for index = 0, SCAN_RECORDS - 1 do
            local code = scan_words[index * RECORD_SIZE / 4]
            if state.code_order[code] then cache[code] = address + index * RECORD_SIZE end
        end
    end
    return true
end
-- The record of code in a binding map: the cached address while it still
-- holds the code (one read), else the map is indexed again.
local function map_bucket(map_offset, code, cache)
    if not state.base then return nil end
    local cached = cache[code]
    if cached and read_words(cached, 4) and words[0] == code then return cached end
    if not index_map(map_offset, cache) then return nil end
    return cache[code]
end
local function action_bucket(group, action)
    return map_bucket(BINDING_MAP, group * 65536 + action, state.buckets)
end
local function action_present(group, action)
    return action_bucket(group, action) ~= nil
end

-- The assignments file and the automatic actions (src/assignments.lua).
local mbm = {state = state, note = note, DORMANT_ACTIONS = DORMANT_ACTIONS, SLOTS = SLOTS,
             ASSIGNMENTS_FILE = ASSIGNMENTS_FILE}
mbm_files.assignments(mbm)
local flush_assignments, assign_action = mbm.flush_assignments, mbm.assign_action
-- The sweep of the bindings' native actions (src/sweep.lua).
mbm.read_into, mbm.map_bucket = read_into, map_bucket
mbm.BINDING_MAP, mbm.DEFAULTS_MAP, mbm.RECORD_SIZE = BINDING_MAP, DEFAULTS_MAP, RECORD_SIZE
mbm.MAPPINGS_OFFSET, mbm.MAPPING_SIZE, mbm.MAX_MAPPINGS = MAPPINGS_OFFSET, MAPPING_SIZE, MAX_MAPPINGS
mbm_files.sweep(mbm)
local sweep_bindings = mbm.sweep_bindings

local function log_input_probe()
    if state.input_logged then return end
    state.input_logged = true
    local bucket = action_bucket(12, 1)
    if bucket then
        local count = u32(read(bucket + 4, 4)) or 0
        local mappings = {}
        for index = 0, math.min(count, 8) - 1 do
            local bytes = read(bucket + 8 + index * 20, 20)
            if bytes then
                local hex = bytes:gsub('.', function(c) return string.format('%02X', c:byte()) end)
                mappings[#mappings + 1] = hex
            end
        end
        note('Slot 1 native mappings: ' .. table.concat(mappings, ' '))
    end
    local engine = rawget(_G, 'stingray')
    local keyboard = engine and engine.Keyboard
    if keyboard then
        for _, name in ipairs({'tab', 'enter'}) do
            local ok, id = pcall(keyboard.button_id, name)
            if ok then note('Keyboard button ID ' .. name .. ': ' .. tostring(id)) end
        end
        if type(keyboard.button_name) == 'function' then
            for _, id in ipairs({76, 88}) do
                local ok, name = pcall(keyboard.button_name, id)
                if ok then note('Keyboard button name ' .. id .. ': ' .. tostring(name)) end
            end
        end
    end
end

-- The addon ships a whole-file content/input.config replacement beside this
-- code, pinned to one game build. When the build check fails the bindings go
-- inert, but the game keeps loading that file in place of its own.
local INPUT_CONFIG_WARNING = 'WARNING: Mod Bindings Menu is inactive, but its input.config replacement ' ..
    'is still deployed with it and replaces the input configuration the game ships, which can break or reset ' ..
    'key bindings on this game build. Remove Mod Bindings Menu (or its Vanilla Plus Megapack option), or update ' ..
    'it to a release for this game build.'
-- Raises reason as it is, without a position, for the guard's stop line.
local function check(condition, reason)
    if not condition then error(reason, 0) end
end
-- The build check, on the first frame. A build this release does not support
-- stops the update for the session, the family's refusal: BingusRuntime.statuses
-- shows "stopped: unsupported game build" (or the native change found), the log
-- has that stop line and the input.config warning, and no step runs again. The
-- bindings stay inert: is_down and poll answer nil.
local function initialize()
    if state.initialized then return end
    state.initialized = true
    local ok, err = pcall(function()
        -- Each module file is hashed at most once per session for every mod
        -- (Bingus Shared Runtime's cache); 'game modules unavailable' or
        -- 'unsupported game build' when they do not match.
        check(memory.verify_build({exe_sha256 = EXE_SHA256, game_sha256 = GAME_SHA256}))
        state.base = memory.address(memory.module('game.dll'))
        check(read(state.base + BUILD_ROWS_RVA, 13) ==
              '\x48\x8b\xc4\x53\x41\x56\x48\x81\xec\xd8\x00\x00\x00',
              'binding list builder changed')
        check(read(state.base + SET_TAB_LABELS_RVA, 16) ==
              '\x48\x89\x54\x24\x10\x53\x56\x48\x83\xec\x68\x0f\x29\x74\x24\x30',
              'tab bar label setter changed')
        check(read(state.base + LIST_RESET_RVA, 16) ==
              '\x40\x53\x48\x83\xec\x20\x48\x8b\xd9\x85\xd2\x74\x30\x83\xea\x01',
              'binding list reset changed')
        check(read(state.base + TAB_LABELS_RVA, 12) ==
              '\x51\xf4\x70\x8d\x60\x5c\x5e\xf1\xeb\x7f\x84\x00',
              'binding tab labels changed')
        for _, entry in ipairs(DORMANT_ACTIONS) do
            check(u32(read(state.base + ACTION_LABELS_RVA +
                  (entry[1] * 97 + entry[2]) * 4, 4)) == entry[3],
                  'input action label table changed at ' .. entry[1] .. ':' .. entry[2])
        end
    end)
    if ok then
        note('Native binding layout verified for current game build.')
        return
    end
    state.base = nil
    guard.stop(tostring(err))
    note(INPUT_CONFIG_WARNING)
end

local function activate_actions()
    if state.build_rows or not action_present(12, 1) then return end
    state.build_rows = ffi.cast('void (__fastcall *)(void *, const void *)',
                                state.base + BUILD_ROWS_RVA)
    state.set_tab_labels = ffi.cast('void (__fastcall *)(void *, const void *, int)',
                                    state.base + SET_TAB_LABELS_RVA)
    state.reset_list = ffi.cast('void (__fastcall *)(void *, int)',
                                state.base + LIST_RESET_RVA)
    note('Mod input actions loaded; native keyboard and controller bindings ready.')
    revise()
    log_input_probe()
end

local function mods_title(active)
    -- Nothing to change (every frame outside a binding page): no read.
    if not state.base or active == state.title_active then return end
    local address = state.base + MODS_TITLE_PTR_RVA
    local current = read(address, 8)
    if not current then return end
    local ours = ffi.cast('MBM_u64', state.mods_text)
    if active and not state.title_active then
        if current ~= string.rep('\0', 8) then
            note('MODS title slot is already in use; leaving localization unchanged.')
            return
        end
        state.title_active = write_memory(address, 8, function()
            ffi.cast('MBM_u64 *', address)[0] = ours
        end)
    elseif not active and state.title_active then
        -- If the slot cannot be cleared, keep tracking it and retry later; the
        -- text buffer lives as long as the addon, so the pointer stays valid.
        if u64(current) == tonumber(ours) and not write_memory(address, 8, function()
                ffi.cast('MBM_u64 *', address)[0] = 0
            end) then
            return
        end
        state.title_active = false
    end
end

-- Upper case in every script the game's fonts carry (string.upper: a to z only).
local function display_text(text)
    return translation.T.upper((text:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')))
end

-- A registered text: a string, or (API version 3) a function returning one,
-- which is called now and again whenever a binding page opens, so the text
-- can follow the game's language. Limits count characters. Returns the text
-- to show (upper case), or nil when the value is not a usable text.
function translation.resolve(value, limit)
    if type(value) == 'function' then
        local ok, result = pcall(value)
        if not ok then return nil end
        value = result
    end
    if type(value) ~= 'string' or translation.T.length(value) > limit then return nil end
    local text = display_text(value)
    if text == '' or not translation.T.check(text) then return nil end
    return text
end

-- The game's Text Language (5 guarded reads), then the registered texts given
-- as functions, MBM's own texts and the MODS title: refreshed each time a
-- binding page opens, never per frame. A function that fails keeps the text
-- shown before. The title buffer changes only while no game slot points at it.
function translation.refresh()
    local tag, code = translation.T.observe(read, state.base)
    local seen = tag and (tag .. ' (game setting ' .. code .. ')') or (translation.T.language() .. ' (Steam)')
    if seen ~= state.language then
        state.language = seen
        note('Text language: ' .. seen .. '.')
    end
    local tr = translation.tr
    tr:refresh()
    local changed = false
    for _, record in ipairs(state.order) do
        if type(record.label) == 'function' then
            local text = translation.resolve(record.label, 127)
            if text and text ~= record.text then record.text, changed = text, true end
        end
        if type(record.category_source) == 'function' then
            local text = translation.resolve(record.category_source, 64)
            if text and text ~= record.category then record.category, changed = text, true end
        end
    end
    local empty = display_text(tr('section.none'))
    if empty ~= state.empty_text then state.empty_text, changed = empty, true end
    local title = display_text(tr('tab.mods'))
    if not state.title_active and title ~= ffi.string(state.mods_text) then
        state.titles[#state.titles + 1] = state.mods_text
        state.mods_text = ffi.new('char[?]', #title + 1, title)
    end
    if changed then revise() end
end

-- Names a caller's section after its addon entry, e.g.
-- 'mods/example/toggle_hud' -> 'TOGGLE HUD', for authors who pass no category.
local function caller_category()
    local sources = {}
    for level = 3, 8 do
        local info = debug.getinfo(level, 'S')
        if not info then break end
        local entry = info.source and info.source:match('mods/[%w_]+/([%w_/]+)')
        if entry then
            local name = display_text((entry:match('([%w_]+)$') or entry):gsub('_', ' '))
            if name ~= '' then return name end
        end
        sources[#sources + 1] = tostring(info.source):sub(1, 80)
    end
    note('No addon entry on the registration stack (' .. table.concat(sources, ', ') ..
         '); using the unnamed section.')
    return display_text(translation.tr('section.unnamed'))
end

local active_screen -- Defined with the page code below.

-- slot: 1-7 selects a fixed v1 slot; nil or 0 (version 2) assigns a free native
-- action automatically and keeps it for this id in later sessions. A slot 2
-- request that another addon already holds is assigned automatically too.
-- options (optional, version 2): {category = 'Mod display name'}. Bindings are
-- grouped under one native section header per category on the MODS tab.
-- label: a game localization ID (number) or text; text and category are UTF-8
-- in any script, limited in characters (127 and 64) and shown upper-cased.
-- Version 3: both may be functions returning the text in the current
-- language, called now and whenever a binding page opens.
function api.register_binding(id, label, slot, options)
    if slot == 0 then slot = nil end
    local text = type(label) ~= 'number' and translation.resolve(label, 127) or nil
    if type(id) ~= 'string' or id == '' or id:find('[\t\r\n]')
       or not (type(label) == 'number' and label >= 1 and label < 0x100000000 or text)
       or slot ~= nil and (type(slot) ~= 'number' or slot < 1 or slot > SLOTS
                           or slot % 1 ~= 0)
       or options ~= nil and type(options) ~= 'table' then
        return false, 'invalid binding registration'
    end
    local category = options and options.category
    local category_text = category ~= nil and translation.resolve(category, 64) or nil
    if category ~= nil and not category_text then
        return false, 'invalid binding category'
    end
    local existing = state.registry[id]
    if existing then
        -- A text given as a function may differ between registrations (another language).
        if existing.requested == slot and (existing.label == label or type(existing.label) == 'function'
                                           or type(label) == 'function') then
            return true
        end
        return false, 'binding already registered differently'
    end
    local code
    if slot then
        local taken = false
        for _, record in ipairs(state.order) do
            if record.slot == slot then taken = true end
        end
        if not taken then
            code = SLOT_CODES[slot][1] * 65536 + SLOT_CODES[slot][2]
        elseif slot ~= 2 then
            return false, 'slot already in use'
        end
    end
    if not code then
        local reason
        code, reason = assign_action(id)
        if not code then return false, reason end
    end
    local record = {id = id, label = label, requested = slot,
                    slot = not state.auto_codes[code] and slot or nil, code = code,
                    group = math.floor(code / 65536), action = code % 65536,
                    category = category_text or caller_category(), category_source = category}
    record.text = text
    state.registry[id] = record
    state.order[#state.order + 1] = record
    state.used[code] = record
    table.sort(state.order, function(a, b)
        return state.code_order[a.code] < state.code_order[b.code]
    end)
    revise()
    note('Registered ' .. id .. ' on native action ' .. record.group .. ':' .. record.action ..
         (record.slot and ' (slot ' .. record.slot .. ')' or '') .. ' under ' ..
         record.category .. '.')
    return true
end
-- A registered action's live binding record and its mapping count, from one
-- 8-byte read of the record's {code, count} header. A record that no longer
-- holds the action is searched for again, as before.
local function live_header(record)
    local bucket = state.buckets[record.code]
    if not (bucket and read_words(bucket, 8) and words[0] == record.code) then
        state.buckets[record.code] = nil
        bucket = action_bucket(record.group, record.action)
        if not (bucket and read_words(bucket, 8)) then return nil end
    end
    return bucket, words[1]
end

-- The game evaluates every action once per frame into a 32-byte state entry
-- at owner + 808 + 32 * (97 * group + action); byte 0 is set while any of the
-- action's mappings satisfies its own trigger (Press, Hold, Tap, DoubleTap,
-- LongPress, ...) on keyboard, mouse or controller. Three reads (the record
-- header, the input owner, the state byte) and no allocation per call.
function api.is_down(id)
    local record = state.registry[id]
    if not record or not state.build_rows then return nil end
    local bucket, count = live_header(record)
    if not bucket then return nil end
    -- A config re-parse (device change) or a Revert can restore inherited
    -- defaults; the sweep cleans them up before this frame's state is trusted.
    if count ~= state.swept_counts[record.code] and not active_screen() then
        sweep_bindings()
        return false
    end
    local owner = read_words(state.base + INPUT_OWNER_PTR_RVA, 8) and word_pointer(0)
    if not owner or not read_words(owner + ACTION_STATE_OFFSET +
            ACTION_STATE_STRIDE * (record.group * 97 + record.action), 1) then
        return nil
    end
    return bit.band(words[0], 0xff) ~= 0
end
function api.ready() return state.build_rows ~= nil end
_G.ModBindingsMenu = api

-- The binding page's screen object while a binding page is on top of the UI,
-- else nil. Two reads on every frame, without allocation: the UI state and menu
-- system pointers (16 bytes apart in game.dll), then the UI's screen stack
-- (five screen types, then the depth); a third for the screen while a page is open.
active_screen = function()
    if not read_words(state.base + UI_STATE_PTR_RVA, 24) then return nil end
    local ui, menu = word_pointer(0), word_pointer(MENU_WORD)
    if not ui or not read_words(ui + 0x429c, 24) then return nil end
    local depth = words[5]
    if depth < 1 or depth > 5 or words[depth - 1] ~= 26 then return nil end
    if not menu or not read_words(menu + 208, 8) then return nil end
    return word_pointer(0)
end

-- Polling several bindings in one call (src/poll.lua): ModBindingsMenu.poll.
mbm.live_header, mbm.active_screen, mbm.words, mbm.read_words, mbm.word_pointer =
    live_header, active_screen, words, read_words, word_pointer
mbm.INPUT_OWNER_PTR_RVA, mbm.ACTION_STATE_OFFSET, mbm.ACTION_STATE_STRIDE =
    INPUT_OWNER_PTR_RVA, ACTION_STATE_OFFSET, ACTION_STATE_STRIDE
mbm_files.poll(mbm)
api.poll = mbm.poll

local function write_u64(address, value)
    return write_memory(address, 8, function() ffi.cast('MBM_u64 *', address)[0] = value end)
end
local function write_u32(address, value)
    return write_memory(address, 4, function() ffi.cast('MBM_u32 *', address)[0] = value end)
end

-- Returns a localization ID that displays text, borrowing an empty pooled
-- cache slot. Claims last until release_labels runs on leaving the page.
local function claim_label(text)
    local claim = state.claims[text]
    if claim then return claim.id end
    for index, entry in ipairs(LABEL_POOL) do
        if not state.pooled[index] then
            local address = state.base + entry[2]
            if u64(read(address, 8)) == 0 then
                local buffer = ffi.new('char[?]', #text + 1, text)
                if not write_u64(address, ffi.cast('MBM_u64', buffer)) then return nil end
                state.pooled[index] = true
                state.claims[text] = {id = entry[1], address = address, buffer = buffer, index = index}
                return entry[1]
            end
        end
    end
    note('No free localization slot for "' .. text .. '".')
    return nil
end

-- Returns whether the row now shows label_id; on false it keeps its own label.
local function write_action_label(record, label_id)
    local address = state.base + ACTION_LABELS_RVA + (record.group * 97 + record.action) * 4
    local previous = u32(read(address, 4))
    if previous ~= ORIGINAL_LABELS[record.code] and previous ~= label_id
       and previous ~= state.action_labels[address] then
        note('Action label for ' .. record.id .. ' is in use by another mod; leaving it.')
        return false
    end
    if previous ~= label_id and not write_u32(address, label_id) then return false end
    state.action_labels[address] = label_id
    return true
end

local function release_labels()
    if not state.base then return end
    -- Pooled row labels only make sense while their slots are borrowed.
    for _, record in ipairs(state.order) do
        local address = state.base + ACTION_LABELS_RVA + (record.group * 97 + record.action) * 4
        if record.text and state.action_labels[address]
           and u32(read(address, 4)) == state.action_labels[address]
           and write_u32(address, ORIGINAL_LABELS[record.code]) then
            state.action_labels[address] = nil
        end
    end
    for text, claim in pairs(state.claims) do
        local ours = u64(read(claim.address, 8)) == tonumber(ffi.cast('MBM_u64', claim.buffer))
        -- A slot that still points at our text keeps the claim (and its buffer)
        -- alive until it can be cleared; freeing it would leave the game a
        -- dangling pointer.
        if not ours or write_u64(claim.address, 0) then
            state.pooled[claim.index] = nil
            state.claims[text] = nil
        end
    end
end

-- Sections in display order: categories alphabetically, bindings by slot.
local function sections()
    local by_name, list = {}, {}
    for _, record in ipairs(state.order) do
        local section = by_name[record.category]
        if not section then
            section = {name = record.category, records = {}}
            by_name[record.category] = section
            list[#list + 1] = section
        end
        section.records[#section.records + 1] = record
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Native row descriptors {group, action, header label} for the MODS tab.
-- The layout always yields rows: without it the game would keep showing the
-- previous tab's rows under MODS. If a header or text label cannot be written,
-- the section falls back to the MODS title (or no header) and the row keeps
-- its native label, but every binding stays visible and rebindable.
local function mods_layout()
    local rows = {}
    local fallback_header = state.title_active and MODS_TITLE_ID or nil
    local list = sections()
    if #list == 0 then
        local empty = claim_label(state.empty_text) or fallback_header
        if not empty then return nil end
        rows[1] = {13, 0, empty}
        return rows
    end
    local fallback_shown = false
    for _, section in ipairs(list) do
        local header = claim_label(section.name)
        if header then
            rows[#rows + 1] = {13, 0, header}
        elseif fallback_header and not fallback_shown then
            -- Sections without their own header share one MODS header.
            fallback_shown = true
            rows[#rows + 1] = {13, 0, fallback_header}
        end
        for _, record in ipairs(section.records) do
            if action_present(record.group, record.action) then
                local label_id = record.text and claim_label(record.text) or record.label
                if type(label_id) == 'number' then write_action_label(record, label_id) end
                rows[#rows + 1] = {record.group, record.action, 0}
            else
                note('Native action for ' .. record.id .. ' is not loaded; row omitted.')
            end
        end
    end
    if #rows == 0 then return nil end
    return rows
end
-- Adds MODS as the fourth native tab. The game draws the tab, its index and
-- Q/E (LB/RB) cycling itself; relabelling resets every button's state, so
-- the current tab's selected state is restored as the page's opener does.
local function ensure_mods_tab(screen)
    local bar = screen + TAB_BAR_OFFSET
    local count = word_at(bar + TAB_COUNT)
    if count == NATIVE_TABS + 1 then return true end
    if count ~= NATIVE_TABS then return false end
    local current = word_at(bar + TAB_CURRENT)
    if not current or current >= NATIVE_TABS then return false end
    mods_title(true)
    if not state.title_active then return false end
    local labels = ffi.new('MBM_u32[?]', NATIVE_TABS + 1)
    for index = 0, NATIVE_TABS - 1 do
        labels[index] = assert(u32(read(state.base + TAB_LABELS_RVA + index * 4, 4)))
    end
    labels[NATIVE_TABS] = MODS_TITLE_ID
    state.tab_labels = labels
    state.set_tab_labels(ffi.cast('void *', bar), labels, NATIVE_TABS + 1)
    local button = bar + TAB_BUTTON_STRIDE * current
    ffi.cast('MBM_u32 *', button + TAB_BUTTON_STATE)[0] = 3
    ffi.cast('MBM_u8 *', button + TAB_BUTTON_ACTIVE)[0] = 1
    note('Added native MODS tab (current tab ' .. current .. ').')
    return true
end

local ROW_COUNT = 2411916
local function mods_tab_built(listing, layout)
    if word_at(listing + ROW_COUNT) ~= #layout then return false end
    for index, descriptor in ipairs(layout) do
        local row = listing + ROW_START + ROW_STRIDE * (index - 1)
        if descriptor[3] ~= 0 then
            if word_at(row + 24752) ~= 4
               or word_at(row + 4264 + 272) ~= descriptor[3] then return false end
        elseif word_at(row + 24760) ~= descriptor[1] * 65536 + descriptor[2] then
            return false
        end
    end
    return true
end

-- The listing and layout whose rows were last found built, and the seconds
-- since every row was checked. While the MODS tab stays selected the game
-- leaves the rows alone, so a frame re-reads only the row count; every row is
-- checked again when the count, the layout or the listing changes, after
-- another tab was selected, and every ROWS_RECHECK seconds.
local ROWS_RECHECK = 0.5
local built_listing, built_layout, built_age = nil, nil, 0
local function forget_rows() built_listing, built_layout = nil, nil end
local function rows_built(listing, layout, seconds)
    built_age = built_age + seconds
    if listing == built_listing and layout == built_layout and built_age < ROWS_RECHECK
       and word_at(listing + ROW_COUNT) == #layout then
        return true
    end
    forget_rows()
    if not mods_tab_built(listing, layout) then return false end
    built_listing, built_layout, built_age = listing, layout, 0
    return true
end

-- The game's tab switch leaves the previous tab's rows in place for tabs it
-- does not know, so the MODS tab rebuilds the list with the native builder:
-- one native section header per mod, followed by that mod's bindings.
local function fill_mods_tab(screen, seconds)
    if not state.layout or state.layout_revision ~= state.revision then
        state.layout = mods_layout()
        state.layout_revision = state.revision
        if not state.layout then return end
    end
    local layout = state.layout
    local listing = screen + ROW_LIST_OFFSET
    if rows_built(listing, layout, seconds) then return end
    local rows = ffi.new('MBM_u32[?]', #layout * 3)
    for index, descriptor in ipairs(layout) do
        for field = 1, 3 do rows[(index - 1) * 3 + field - 1] = descriptor[field] end
    end
    -- The game's own list constructor clears, rebuilds and lays out rows;
    -- the reset then returns focus and scrolling to the top, as a tab switch does.
    ffi.cast('MBM_u32 *', listing + 2411928)[0] = #layout
    state.build_rows(ffi.cast('void *', listing), rows)
    state.reset_list(ffi.cast('void *', listing), MODS_TAB)
    state.screen = screen
    note('Filled MODS tab: ' .. #state.order .. ' bindings in ' .. #sections() .. ' sections.')
end

local SWEEP_INTERVAL = 2

-- A frame with a binding page on top of the UI: the MODS tab. The selected tab
-- is read once; adding the MODS tab relabels the tab bar but does not select
-- a tab.
local function page_frame(screen, seconds)
    local tab = word_at(screen + SELECTED_TAB_OFFSET)
    if ensure_mods_tab(screen) and tab == MODS_TAB then
        fill_mods_tab(screen, seconds)
    else
        forget_rows()
    end
    if tab ~= state.last_tab then
        state.last_tab = tab
        note('Bindings tab ' .. tostring(tab) .. ' selected.')
    end
end

-- A frame without a binding page: the sweep when it is due (never while a page
-- is open, so the page's rows are left alone), and whatever the page borrowed
-- goes back.
local function away_frame()
    if state.page_open then state.page_open, state.page_visited = false, true end
    if state.sweep_timer <= 0 then
        state.sweep_timer = SWEEP_INTERVAL
        sweep_bindings()
    end
    state.last_tab = nil
    state.layout = nil
    forget_rows()
    mods_title(false)
    release_labels()
end

local function step(dt)
    if not state.initialized then initialize() end
    if not state.base then return end
    local seconds = type(dt) == 'number' and dt or 0
    local book = state.assignments
    if book and book.dirty then flush_assignments(seconds) end
    activate_actions()
    if not state.build_rows then return end
    local screen = active_screen()
    if screen and not state.page_open then
        -- A binding page just opened: the game's Text Language may have changed
        -- since the last one, so the texts are refreshed here, once.
        state.page_open = true
        translation.refresh()
    end
    state.sweep_timer = state.sweep_timer - seconds
    if screen then page_frame(screen, seconds) else away_frame() end
end

-- The update stops (the 8th error of a burst) or the game shuts down: the MODS
-- title and the borrowed text slots go back to the game, as when a binding page
-- closes. While a page is open they stay borrowed for the session, and their
-- buffers with them, since the page may still show them.
local function shut_down()
    if not state.base then return end
    if active_screen() then
        note('A binding page is open; its borrowed text slots stay borrowed.')
        return
    end
    mods_title(false)
    release_labels()
end

-- An update below this mod raised: the menu pauses, and its next step starts
-- afresh. A binding page that was open counts as visited, so the next sweep
-- treats the player's changes on it as after any page; the page's own state
-- goes, and so do the MODS title and the borrowed text slots unless a page is
-- open. The binding maps (the player's mappings), the registrations, the
-- reservations and the assignments file stay as they are; nothing is swept here.
local function pause_menu()
    if state.page_open then state.page_open, state.page_visited = false, true end
    state.last_tab, state.layout = nil, nil
    forget_rows()
    shut_down()
end

-- The update chain, through Bingus Shared Runtime's guard: the previous update
-- runs outside pcall, so its errors reach the game unchanged; the step's errors
-- count in bursts (the 8th of a burst stops it for the session, 3600 error-free
-- frames end a burst); after an error below this mod the menu pauses
-- (pause_menu) and resumes once the updates below have returned on 60 frames in
-- a row, and 8 such errors in a burst stop it; a stop or the game's shutdown
-- runs shut_down; the first failure survives shutdown in
-- BingusRuntime.statuses.ModBindingsMenu. Every argument and return value pass
-- through. Per frame: the step under pcall and a few tests and stores, no
-- allocation (pinned in tests/test_mods_tab.lua).
guard = runtime.guard({name = 'ModBindingsMenu', step = step, stop = shut_down, pause = pause_menu, log = note,
                       env = _G}).install()
note('Mod Bindings Menu initialized; waiting for native input actions.')
