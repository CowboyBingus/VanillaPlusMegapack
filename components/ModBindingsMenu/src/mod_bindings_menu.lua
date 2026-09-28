-- HD2-Addon: mods/cowboybingus/mod_bindings_menu
-- Native bindings-page extension for Steam build 25480438.
if rawget(_G, 'ModBindingsMenu') then return end
local ffi = require('ffi')
local bit = require('bit')

ffi.cdef [[
typedef unsigned char MBM_u8;
typedef unsigned short MBM_u16;
typedef unsigned int MBM_u32;
typedef unsigned long long MBM_u64;
void *GetModuleHandleA(const char *name);
MBM_u32 GetModuleFileNameW(void *module, MBM_u16 *path, MBM_u32 capacity);
void *GetCurrentProcess(void);
int ReadProcessMemory(void *process, const void *address, void *buffer,
                      size_t size, size_t *received);
int VirtualProtect(void *address, size_t size, MBM_u32 protection, MBM_u32 *old);
typedef struct {
    void *BaseAddress; void *AllocationBase; MBM_u32 AllocationProtect;
    MBM_u16 PartitionId; size_t RegionSize; MBM_u32 State; MBM_u32 Protect; MBM_u32 Type;
} MBM_MEMORY_BASIC_INFORMATION;
size_t VirtualQuery(const void *address, MBM_MEMORY_BASIC_INFORMATION *info, size_t length);
MBM_u32 GetLastError(void);
void *CreateFileW(const MBM_u16 *path, MBM_u32 access, MBM_u32 share,
                  void *security, MBM_u32 disposition, MBM_u32 flags, void *template_file);
int ReadFile(void *file, void *buffer, MBM_u32 size, MBM_u32 *received, void *overlapped);
int CloseHandle(void *handle);
int BCryptOpenAlgorithmProvider(void **algorithm, const MBM_u16 *name,
                                const MBM_u16 *provider, MBM_u32 flags);
int BCryptCloseAlgorithmProvider(void *algorithm, MBM_u32 flags);
int BCryptCreateHash(void *algorithm, void **hash, void *object, MBM_u32 object_size,
                     const void *secret, MBM_u32 secret_size, MBM_u32 flags);
int BCryptHashData(void *hash, const void *data, MBM_u32 size, MBM_u32 flags);
int BCryptFinishHash(void *hash, void *digest, MBM_u32 size, MBM_u32 flags);
int BCryptDestroyHash(void *hash);
]]

local kernel32, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
local process = kernel32.GetCurrentProcess()
local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('ModBindingsMenu.log') end)
end
local function note(message)
    if log_file then pcall(function() log_file:write(message .. '\n'); log_file:flush() end) end
end

local GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
local EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
local INPUT_OWNER_PTR_RVA = 0x347cf18
local MENU_SYSTEM_PTR_RVA = 0x347ce38
local UI_STATE_PTR_RVA = 0x347ce28
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
-- Fixed slots whose keyboard default is Mod Bindings Menu's own (input.config).
local SHIPPED_KEYBOARD_DEFAULT = {
    [12 * 65536 + 1] = true, [10 * 65536 + 1] = true, [10 * 65536 + 4] = true,
    [10 * 65536 + 8] = true, [10 * 65536 + 14] = true, [10 * 65536 + 9] = true,
}
local KEYBOARD_DEVICE = 3
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
local DEFAULT_CATEGORY = 'MODS'
local EMPTY_TEXT = 'NO MOD BINDINGS INSTALLED'
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
               registry = {}, order = {}, errors = 0, input_logged = false,
               buckets = {}, title_active = false,
               set_tab_labels = nil, reset_list = nil, tab_labels = nil,
               last_tab = nil,
               claims = {}, pooled = {}, action_labels = {},
               default_buckets = {}, clear_pending = {}, assignments = nil,
               auto_codes = {}, code_order = {}, sweep_timer = 0, swept_counts = {},
               mods_text = ffi.new('char[5]', 'MODS')}
for index, entry in ipairs(DORMANT_ACTIONS) do
    local code = entry[1] * 65536 + entry[2]
    state.code_order[code] = index
    if index > SLOTS then state.auto_codes[code] = true end
end

local function read(address, size)
    local buffer, received = ffi.new('MBM_u8[?]', size), ffi.new('size_t[1]')
    if kernel32.ReadProcessMemory(process, ffi.cast('const void *', address),
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
local function pointer(blob)
    local value = u64(blob)
    if not value then return nil end
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end
local function module_sha256(module)
    local path = ffi.new('MBM_u16[32768]')
    local length = kernel32.GetModuleFileNameW(module, path, 32768)
    assert(length > 0 and length < 32768, 'cannot resolve module path')
    local file = kernel32.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
    assert(file ~= ffi.NULL and file ~= ffi.cast('void *', -1), 'cannot read module file')
    local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
    local ok, result = pcall(function()
        local name = ffi.new('MBM_u16[7]', {83, 72, 65, 50, 53, 54, 0})
        assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0)
        assert(bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0)
        local buffer, received = ffi.new('MBM_u8[1048576]'), ffi.new('MBM_u32[1]')
        while true do
            assert(kernel32.ReadFile(file, buffer, 1048576, received, nil) ~= 0)
            if received[0] == 0 then break end
            assert(bcrypt.BCryptHashData(hash[0], buffer, received[0], 0) == 0)
        end
        local digest, parts = ffi.new('MBM_u8[32]'), {}
        assert(bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) == 0)
        for i = 0, 31 do parts[#parts + 1] = string.format('%02X', digest[i]) end
        return table.concat(parts)
    end)
    if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
    if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
    kernel32.CloseHandle(file)
    if not ok then error(result) end
    return result
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
    if kernel32.VirtualQuery(pointer_value, info, ffi.sizeof(info)) == 0
       or info.State ~= MEM_COMMIT then return false end
    local region_end = tonumber(ffi.cast('MBM_u64', info.BaseAddress)) + tonumber(info.RegionSize)
    if WRITABLE_PAGES[bit.band(info.Protect, 0xff)] and bit.band(info.Protect, PAGE_GUARD) == 0
       and address + size <= region_end then
        fn()
        return true
    end
    local old = ffi.new('MBM_u32[1]')
    if kernel32.VirtualProtect(ffi.cast('void *', address), size, 0x04, old) == 0 then
        if refusals_logged < 4 then
            refusals_logged = refusals_logged + 1
            note(string.format('Write refused at game.dll+0x%x (protection 0x%x, error %d).',
                               address - (state.base or 0), info.Protect, kernel32.GetLastError()))
        end
        return false
    end
    local ok, result = pcall(fn)
    local ignored = ffi.new('MBM_u32[1]')
    kernel32.VirtualProtect(ffi.cast('void *', address), size, old[0], ignored)
    if not ok then error(result) end
    return true
end

-- Binding records live in fixed 256-entry hash maps on the input owner: the
-- live bindings (+686800) and the shipped defaults (+686968). Each 328-byte
-- record is {u32 code, u32 count, 16 x 20-byte mappings}.
local function map_bucket(map_offset, code, cache)
    if not state.base then return nil end
    local cached = cache[code]
    if cached and u32(read(cached, 4)) == code then return cached end
    local owner = pointer(read(state.base + INPUT_OWNER_PTR_RVA, 8))
    if not owner then return nil end
    local buckets = pointer(read(owner + map_offset, 8))
    local capacity = u32(read(owner + map_offset + 8, 4))
    if not buckets or capacity ~= 256 then return nil end
    for index = 0, capacity - 1 do
        local bucket = buckets + index * 328
        if u32(read(bucket, 4)) == code then
            cache[code] = bucket
            return bucket
        end
    end
    return nil
end
local function action_bucket(group, action)
    return map_bucket(BINDING_MAP, group * 65536 + action, state.buckets)
end
local function action_present(group, action)
    return action_bucket(group, action) ~= nil
end

-- Mapping identity without bytes 6-7, which the config parser leaves unset.
local function mapping_key(blob)
    return blob:sub(1, 6) .. blob:sub(9, MAPPING_SIZE)
end

-- v1.2.2 cloned some developer defaults with the RepeatInterval trigger, which
-- repeats while held and has no type selector on the bindings page. Button
-- mappings on mod actions use Press instead. The trigger is stored twice: in
-- flag bits 16-19 and in bytes 8-11.
local BUTTON_INPUT, REPEAT_INTERVAL, PRESS = 4, 8, 0
local function press_trigger(blob)
    local flags = u32(blob:sub(1, 4))
    if bit.band(bit.rshift(flags, 4), 0xf) ~= BUTTON_INPUT
       or u32(blob:sub(9, 12)) ~= REPEAT_INTERVAL then return blob end
    local value = bit.bor(bit.band(flags, bit.bnot(0xf0000)), bit.lshift(PRESS, 16))
    if value < 0 then value = value + 0x100000000 end -- bit ops are signed 32-bit.
    local cleared = ffi.new('MBM_u32[1]', value)
    return ffi.string(cleared, 4) .. blob:sub(5, 8) .. string.rep('\0', 4) .. blob:sub(13)
end

local function read_mappings(bucket)
    local count = u32(read(bucket + 4, 4))
    if not count or count > MAX_MAPPINGS then return nil end
    local mappings = {}
    for index = 0, count - 1 do
        local blob = read(bucket + MAPPINGS_OFFSET + index * MAPPING_SIZE, MAPPING_SIZE)
        if not blob then return nil end
        mappings[#mappings + 1] = blob
    end
    return mappings
end

local function write_mappings(bucket, mappings)
    local records = ffi.cast('MBM_u8 *', bucket + MAPPINGS_OFFSET)
    ffi.fill(records, MAX_MAPPINGS * MAPPING_SIZE)
    for index, blob in ipairs(mappings) do
        ffi.copy(records + (index - 1) * MAPPING_SIZE, blob, MAPPING_SIZE)
    end
    ffi.cast('MBM_u32 *', bucket + 4)[0] = #mappings
end

-- The dormant actions keep their developer defaults (controller buttons, the
-- mouse, Enter, Escape...) in input.config and in saved settings from v1. They
-- must never fire a mod binding, so every live mapping identical to one of the
-- action's shipped defaults is removed, except Mod Bindings Menu's own
-- keyboard default on the fixed slots. Reclaimed actions are cleared entirely.
local function sweep_inherited_mappings()
    local removed = 0
    for _, entry in ipairs(DORMANT_ACTIONS) do
        local code = entry[1] * 65536 + entry[2]
        local live = action_bucket(entry[1], entry[2])
        local defaults = map_bucket(DEFAULTS_MAP, code, state.default_buckets)
        local current = live and read_mappings(live)
        local shipped = defaults and read_mappings(defaults)
        if current and shipped then
            local inherited = {}
            for _, blob in ipairs(shipped) do
                local own = SHIPPED_KEYBOARD_DEFAULT[code] and
                            bit.band(blob:byte(1), 0xf) == KEYBOARD_DEVICE
                if not own then inherited[mapping_key(blob)] = true end
            end
            local kept, changed = {}, false
            if not state.clear_pending[code] then
                for _, blob in ipairs(current) do
                    if not inherited[mapping_key(blob)] then
                        local press = press_trigger(blob)
                        changed = changed or press ~= blob
                        kept[#kept + 1] = press
                    end
                end
            end
            state.clear_pending[code] = nil
            if changed or #kept ~= #current then
                write_mappings(live, kept)
                removed = removed + #current - #kept
            end
            state.swept_counts[code] = #kept
        end
    end
    if removed > 0 then note('Removed ' .. removed .. ' inherited developer mappings.') end
end

local function assignments_path()
    local loader_api = rawget(_G, 'CowboyBingusModLoader')
    local directory = type(loader_api) == 'table' and loader_api.log_directory
    if type(directory) ~= 'string' or directory == '' then
        local local_app_data = os.getenv('LOCALAPPDATA')
        if not local_app_data then return nil end
        directory = local_app_data .. '/CowboyBingus/Helldivers2'
    end
    return directory .. '/' .. ASSIGNMENTS_FILE
end

-- Automatic bindings keep their native action across sessions, because the
-- game saves each action's keys under the action's name.
local function load_assignments()
    if state.assignments then return state.assignments end
    state.assignments = {}
    local path = assignments_path()
    local file = path and io.open(path, 'rb')
    if not file then return state.assignments end
    local text = file:read('*a') or ''
    file:close()
    for id, group, action in text:gmatch('([^\t\r\n]+)\t(%d+)\t(%d+)') do
        local code = tonumber(group) * 65536 + tonumber(action)
        if state.auto_codes[code] then state.assignments[id] = code end
    end
    return state.assignments
end

local function save_assignments()
    local path = assignments_path()
    if not path then return end
    local lines = {}
    for id, code in pairs(state.assignments) do
        lines[#lines + 1] = id .. '\t' .. math.floor(code / 65536) .. '\t' .. code % 65536
    end
    table.sort(lines)
    local file, reason = io.open(path, 'wb')
    if not file then note('Cannot save binding assignments: ' .. tostring(reason)); return end
    file:write(table.concat(lines, '\n'), '\n')
    file:close()
end

local function assign_action(id)
    local assignments = load_assignments()
    local used, reserved = {}, {}
    for _, record in ipairs(state.order) do used[record.code] = true end
    for owner, code in pairs(assignments) do reserved[code] = owner end
    local previous = assignments[id]
    if previous and not used[previous] then return previous end
    for index = SLOTS + 1, #DORMANT_ACTIONS do
        local entry = DORMANT_ACTIONS[index]
        local code = entry[1] * 65536 + entry[2]
        if not used[code] and not reserved[code] then
            assignments[id] = code
            save_assignments()
            return code
        end
    end
    -- Reuse an action reserved by an addon that did not register this session;
    -- its old keys are cleared so they do not carry over to the new binding.
    for index = SLOTS + 1, #DORMANT_ACTIONS do
        local entry = DORMANT_ACTIONS[index]
        local code = entry[1] * 65536 + entry[2]
        local owner = reserved[code]
        if not used[code] and owner and not state.registry[owner] then
            assignments[owner] = nil
            assignments[id] = code
            state.clear_pending[code] = true
            save_assignments()
            note('Reassigned native action ' .. entry[1] .. ':' .. entry[2] ..
                 ' from ' .. owner .. ' to ' .. id .. '.')
            return code
        end
    end
    return nil
end

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

local function initialize()
    if state.initialized then return end
    state.initialized = true
    local ok, err = pcall(function()
        local game, exe = kernel32.GetModuleHandleA('game.dll'), kernel32.GetModuleHandleA(nil)
        assert(game ~= nil and game ~= ffi.NULL and exe ~= nil and exe ~= ffi.NULL)
        assert(module_sha256(game) == GAME_SHA256, 'unsupported game.dll build')
        assert(module_sha256(exe) == EXE_SHA256, 'unsupported helldivers2.exe build')
        state.base = tonumber(ffi.cast('MBM_u64', game))
        assert(read(state.base + BUILD_ROWS_RVA, 13) ==
               '\x48\x8b\xc4\x53\x41\x56\x48\x81\xec\xd8\x00\x00\x00',
               'binding list builder changed')
        assert(read(state.base + SET_TAB_LABELS_RVA, 16) ==
               '\x48\x89\x54\x24\x10\x53\x56\x48\x83\xec\x68\x0f\x29\x74\x24\x30',
               'tab bar label setter changed')
        assert(read(state.base + LIST_RESET_RVA, 16) ==
               '\x40\x53\x48\x83\xec\x20\x48\x8b\xd9\x85\xd2\x74\x30\x83\xea\x01',
               'binding list reset changed')
        assert(read(state.base + TAB_LABELS_RVA, 12) ==
               '\x51\xf4\x70\x8d\x60\x5c\x5e\xf1\xeb\x7f\x84\x00',
               'binding tab labels changed')
        for _, entry in ipairs(DORMANT_ACTIONS) do
            assert(u32(read(state.base + ACTION_LABELS_RVA +
                   (entry[1] * 97 + entry[2]) * 4, 4)) == entry[3],
                   'input action label table changed at ' .. entry[1] .. ':' .. entry[2])
        end
    end)
    if ok then note('Native binding layout verified for current game build.')
    else state.base = nil; note('Mod binding integration unavailable: ' .. tostring(err)) end
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
    log_input_probe()
end

local function mods_title(active)
    if not state.base then return end
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

local function display_text(text)
    return (text:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', ''):upper())
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
         '); using ' .. DEFAULT_CATEGORY .. '.')
    return DEFAULT_CATEGORY
end

local active_screen -- Defined with the page code below.

local api = {api = 1, version = 2, capacity = #DORMANT_ACTIONS}
-- slot: 1-7 selects a fixed v1 slot; nil or 0 (version 2) assigns a free native
-- action automatically and keeps it for this id in later sessions. A slot 2
-- request that another addon already holds is assigned automatically too.
-- options (optional, version 2): {category = 'Mod display name'}. Bindings are
-- grouped under one native section header per category on the MODS tab.
function api.register_binding(id, label, slot, options)
    if slot == 0 then slot = nil end
    if type(id) ~= 'string' or id == '' or id:find('[\t\r\n]')
       or not (type(label) == 'number' and label >= 1 and label < 0x100000000
               or type(label) == 'string' and label ~= '' and #label < 128)
       or slot ~= nil and (type(slot) ~= 'number' or slot < 1 or slot > SLOTS
                           or slot % 1 ~= 0)
       or options ~= nil and type(options) ~= 'table' then
        return false, 'invalid binding registration'
    end
    local category = options and options.category
    if category ~= nil and (type(category) ~= 'string' or #category > 64
                            or display_text(category) == '') then
        return false, 'invalid binding category'
    end
    local existing = state.registry[id]
    if existing then
        if existing.requested == slot and existing.label == label then return true end
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
        code = assign_action(id)
        if not code then return false, 'all ' .. api.capacity .. ' binding actions in use' end
    end
    local record = {id = id, label = label, requested = slot,
                    slot = not state.auto_codes[code] and slot or nil, code = code,
                    group = math.floor(code / 65536), action = code % 65536,
                    category = category and display_text(category) or caller_category()}
    if type(label) == 'string' then record.text = display_text(label) end
    state.registry[id] = record
    state.order[#state.order + 1] = record
    table.sort(state.order, function(a, b)
        return state.code_order[a.code] < state.code_order[b.code]
    end)
    state.revision = (state.revision or 0) + 1
    note('Registered ' .. id .. ' on native action ' .. record.group .. ':' .. record.action ..
         (record.slot and ' (slot ' .. record.slot .. ')' or '') .. ' under ' ..
         record.category .. '.')
    return true
end
-- The game evaluates every action once per frame into a 32-byte state entry
-- at owner + 808 + 32 * (97 * group + action); byte 0 is set while any of the
-- action's mappings satisfies its own trigger (Press, Hold, Tap, DoubleTap,
-- LongPress, ...) on keyboard, mouse or controller.
function api.is_down(id)
    local record = state.registry[id]
    if not record or not state.build_rows then return nil end
    local bucket = action_bucket(record.group, record.action)
    if not bucket then return nil end
    -- A config re-parse (device change) or Revert restores inherited defaults;
    -- clean them up before trusting this frame's state.
    if u32(read(bucket + 4, 4)) ~= state.swept_counts[record.code] and not active_screen() then
        sweep_inherited_mappings()
        return false
    end
    local owner = pointer(read(state.base + INPUT_OWNER_PTR_RVA, 8))
    if not owner then return nil end
    local triggered = read(owner + ACTION_STATE_OFFSET +
                           ACTION_STATE_STRIDE * (record.group * 97 + record.action), 1)
    if not triggered then return nil end
    return triggered ~= '\0'
end
function api.ready() return state.build_rows ~= nil end
_G.ModBindingsMenu = api

active_screen = function()
    local ui = pointer(read(state.base + UI_STATE_PTR_RVA, 8))
    if not ui then return nil end
    local depth = u32(read(ui + 0x429c + 20, 4))
    if not depth or depth < 1 or depth > 5
       or u32(read(ui + 0x429c + 4 * (depth - 1), 4)) ~= 26 then return nil end
    local menu = pointer(read(state.base + MENU_SYSTEM_PTR_RVA, 8))
    if not menu then return nil end
    return pointer(read(menu + 208, 8))
end

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
        local empty = claim_label(EMPTY_TEXT) or fallback_header
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
    local count = u32(read(bar + TAB_COUNT, 4))
    if count == NATIVE_TABS + 1 then return true end
    if count ~= NATIVE_TABS then return false end
    local current = u32(read(bar + TAB_CURRENT, 4))
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

local function mods_tab_built(listing, layout)
    if u32(read(listing + 2411916, 4)) ~= #layout then return false end
    for index, descriptor in ipairs(layout) do
        local row = listing + ROW_START + ROW_STRIDE * (index - 1)
        if descriptor[3] ~= 0 then
            if u32(read(row + 24752, 4)) ~= 4
               or u32(read(row + 4264 + 272, 4)) ~= descriptor[3] then return false end
        elseif u32(read(row + 24760, 4)) ~= descriptor[1] * 65536 + descriptor[2] then
            return false
        end
    end
    return true
end

-- The game's tab switch leaves the previous tab's rows in place for tabs it
-- does not know, so the MODS tab rebuilds the list with the native builder:
-- one native section header per mod, followed by that mod's bindings.
local function fill_mods_tab(screen)
    if u32(read(screen + SELECTED_TAB_OFFSET, 4)) ~= MODS_TAB then return end
    if not state.layout or state.layout_revision ~= state.revision then
        state.layout = mods_layout()
        state.layout_revision = state.revision
        if not state.layout then return end
    end
    local layout = state.layout
    local listing = screen + ROW_LIST_OFFSET
    if mods_tab_built(listing, layout) then return end
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

local function step(dt)
    if not state.initialized then initialize() end
    if not state.base then return end
    activate_actions()
    if not state.build_rows then return end
    local screen = active_screen()
    -- Leave the bindings page's rows alone while it is open; sweep after.
    state.sweep_timer = state.sweep_timer - (type(dt) == 'number' and dt or 0)
    if not screen and state.sweep_timer <= 0 then
        state.sweep_timer = SWEEP_INTERVAL
        sweep_inherited_mappings()
    end
    if screen then
        if ensure_mods_tab(screen) then fill_mods_tab(screen) end
        local tab = u32(read(screen + SELECTED_TAB_OFFSET, 4))
        if tab ~= state.last_tab then
            state.last_tab = tab
            note('Bindings tab ' .. tostring(tab) .. ' selected.')
        end
    else
        state.last_tab = nil
        state.layout = nil
        mods_title(false)
        release_labels()
    end
end
local previous_update = rawget(_G, 'update')
update = function(dt)
    local ok, err = xpcall(function() return step(dt) end, debug.traceback)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= 8 then note('Menu update error: ' .. tostring(err)) end
    end
    if type(previous_update) == 'function' then return previous_update(dt) end
end
note('Mod Bindings Menu initialized; waiting for native input actions.')
