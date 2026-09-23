-- HD2-Addon: mods/cowboybingus/galactic_menu_hotkey
-- Open the ship's Hologram presenter directly. The normal interaction's
-- targeting, prompt, approach movement, and synthetic E key are not used.
if rawget(_G, 'GalacticMenuHotkeyInstalled') then return end
local ffi = require('ffi')
local bit = require('bit')

ffi.cdef [[
typedef unsigned short GMH_u16;
typedef unsigned int GMH_u32;
typedef unsigned long long GMH_u64;
typedef unsigned char GMH_u8;
void *GetModuleHandleA(const char *name);
GMH_u32 GetModuleFileNameW(void *module, GMH_u16 *path, GMH_u32 capacity);
void *GetCurrentProcess(void);
GMH_u32 GetCurrentProcessId(void);
int ReadProcessMemory(void *process, const void *address, void *buffer,
                      size_t size, size_t *received);
void *CreateFileW(const GMH_u16 *path, GMH_u32 access, GMH_u32 share,
                  void *security, GMH_u32 disposition, GMH_u32 flags, void *template_file);
int ReadFile(void *file, void *buffer, GMH_u32 size, GMH_u32 *received, void *overlapped);
int CloseHandle(void *handle);
short GetAsyncKeyState(int key);
void *GetForegroundWindow(void);
GMH_u32 GetWindowThreadProcessId(void *window, GMH_u32 *process);
int BCryptOpenAlgorithmProvider(void **algorithm, const GMH_u16 *name,
                                const GMH_u16 *provider, GMH_u32 flags);
int BCryptCloseAlgorithmProvider(void *algorithm, GMH_u32 flags);
int BCryptCreateHash(void *algorithm, void **hash, void *object, GMH_u32 object_size,
                     const void *secret, GMH_u32 secret_size, GMH_u32 flags);
int BCryptHashData(void *hash, const void *data, GMH_u32 size, GMH_u32 flags);
int BCryptFinishHash(void *hash, void *digest, GMH_u32 size, GMH_u32 flags);
int BCryptDestroyHash(void *hash);
]]

local kernel32, user32, bcrypt =
    ffi.load('kernel32'), ffi.load('user32'), ffi.load('bcrypt')
local process = kernel32.GetCurrentProcess()
local process_id = tonumber(kernel32.GetCurrentProcessId())
local HOTKEY = 0x09 -- VK_TAB
local BINDING_ID = 'cowboybingus.galactic_menu'
local BINDING_LABEL = 0xb46c8096 -- Game-localized "OPEN MAP"
local SHIP_TABLE_HASH = '3b9bcf29e38da0a6'
local GAME_SHA256 = '73374BD4E38386BEB9A23BEF480082B67D457EBC77485FBEC5F488B4E95E201F'
local EXE_SHA256 = 'D8E23968D1412B07E06785321727D63EDF74E711214D6F6ADEB3BFCA95CA6827'

-- Steam build 25327279: PresenterManager::open presenter, and the game's
-- pointer to its top-level UI state. Presenter 15 is Hologram; that presenter
-- pushes MenuScreenType 24. Its screen initialization ignores extra data.
local ENTER_PRESENTER_RVA = 0x14c02c0
local UI_STATE_PTR_RVA = 0x347ce28
local PRESENTER_OFFSET = 17032
local IDLE_MENU_PRESENTER, HOLOGRAM_PRESENTER = 0, 15
local PRESENTER_PREFIX =
    '\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20\x8b'

local state = {
    world = nil, world_status = nil, hotkey_down = false, initialized = false,
    open_presenter = nil, game_base = nil, update_logged = false, errors = 0,
    binding_host = nil,
}

local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('GalacticMenuHotkey.log') end)
end
local function note(message)
    if log_file then
        pcall(function()
            log_file:write(message .. '\n')
            log_file:flush()
        end)
    end
end
local function world_status(message)
    if state.world_status ~= message then
        state.world_status = message
        note('World detection: ' .. message)
    end
end

local function ship_world(engine)
    if type(engine) ~= 'table' or type(engine.Application) ~= 'table'
       or type(engine.World) ~= 'table' or type(engine.IdString64) ~= 'table'
       or type(engine.Application.main_world) ~= 'function'
       or type(engine.World.units_by_resource) ~= 'function'
       or type(engine.IdString64.from_hex) ~= 'function' then
        world_status('Stingray world lookup API unavailable')
        return nil
    end
    local hashed, table_id = pcall(engine.IdString64.from_hex, SHIP_TABLE_HASH)
    if not hashed or not table_id then
        world_status('could not convert galaxy table resource ID')
        return nil
    end
    local worlds = {}
    local function add_world(world)
        if world and world ~= ffi.NULL then worlds[#worlds + 1] = world end
    end
    local main_ok, main = pcall(engine.Application.main_world)
    if main_ok then add_world(main) end
    if type(engine.Application.worlds) == 'function' then
        local list_ok, list = pcall(engine.Application.worlds)
        if list_ok and type(list) == 'table' then
            for _, world in ipairs(list) do add_world(world) end
        end
    end
    if #worlds == 0 then
        world_status('no active Stingray worlds')
        return nil
    end
    for _, world in ipairs(worlds) do
        local listed, units = pcall(engine.World.units_by_resource, world, table_id)
        if listed and type(units) == 'table' and next(units) ~= nil then
            world_status('galaxy table present (' .. #worlds .. ' worlds checked)')
            return world
        end
    end
    world_status('galaxy table absent (' .. #worlds .. ' worlds checked)')
    return nil
end

local function focused_game()
    local window = user32.GetForegroundWindow()
    if not window or window == ffi.NULL then return false end
    local window_pid = ffi.new('GMH_u32[1]')
    user32.GetWindowThreadProcessId(window, window_pid)
    return tonumber(window_pid[0]) == process_id
end
local function key_down(key)
    return bit.band(user32.GetAsyncKeyState(key), 0x8000) ~= 0
end
local function read(address, size)
    local buffer, received = ffi.new('GMH_u8[?]', size), ffi.new('size_t[1]')
    if kernel32.ReadProcessMemory(process, ffi.cast('const void *', address),
            buffer, size, received) == 0 or tonumber(received[0]) ~= size then
        return nil
    end
    return ffi.string(buffer, size)
end
local function u32(blob)
    if not blob or #blob ~= 4 then return nil end
    local value = ffi.new('GMH_u32[1]')
    ffi.copy(value, blob, 4)
    return tonumber(value[0])
end
local function pointer(blob)
    if not blob or #blob ~= 8 then return nil end
    local value = ffi.new('GMH_u64[1]')
    ffi.copy(value, blob, 8)
    local address = tonumber(value[0])
    if address < 0x10000 or address >= 0x800000000000 then return nil end
    return address
end
local function module_sha256(module)
    local path = ffi.new('GMH_u16[32768]')
    local length = kernel32.GetModuleFileNameW(module, path, 32768)
    assert(length > 0 and length < 32768, 'cannot resolve module path')
    local file = kernel32.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
    assert(file ~= ffi.NULL and file ~= ffi.cast('void *', -1), 'cannot read module file')
    local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
    local ok, result = pcall(function()
        local name = ffi.new('GMH_u16[7]', {83, 72, 65, 50, 53, 54, 0})
        assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0,
               'SHA256 unavailable')
        assert(bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0,
               'SHA256 creation failed')
        local buffer, received = ffi.new('GMH_u8[1048576]'), ffi.new('GMH_u32[1]')
        while true do
            assert(kernel32.ReadFile(file, buffer, 1048576, received, nil) ~= 0,
                   'module read failed')
            if received[0] == 0 then break end
            assert(bcrypt.BCryptHashData(hash[0], buffer, received[0], 0) == 0,
                   'SHA256 update failed')
        end
        local digest, hex = ffi.new('GMH_u8[32]'), {}
        assert(bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) == 0,
               'SHA256 finish failed')
        for i = 0, 31 do hex[#hex + 1] = string.format('%02X', digest[i]) end
        return table.concat(hex)
    end)
    if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
    if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
    kernel32.CloseHandle(file)
    if not ok then error(result) end
    return result
end

local function initialize_native()
    if state.initialized then return end
    state.initialized = true
    local ok, result = pcall(function()
        assert(ffi.abi('64bit'), 'Windows x64 required')
        local game = kernel32.GetModuleHandleA('game.dll')
        local exe = kernel32.GetModuleHandleA(nil)
        assert(game ~= nil and game ~= ffi.NULL and exe ~= nil and
               exe ~= ffi.NULL, 'game modules unavailable')
        assert(module_sha256(game) == GAME_SHA256, 'unsupported game.dll build')
        assert(module_sha256(exe) == EXE_SHA256, 'unsupported helldivers2.exe build')
        local base = tonumber(ffi.cast('GMH_u64', game))
        assert(read(base + ENTER_PRESENTER_RVA, #PRESENTER_PREFIX) ==
               PRESENTER_PREFIX, 'native presenter changed in memory')
        assert(pointer(read(base + UI_STATE_PTR_RVA, 8)), 'UI state unavailable')
        state.game_base = base
        state.open_presenter = ffi.cast('void (__fastcall *)(void *, int, void *)',
            base + ENTER_PRESENTER_RVA)
    end)
    if ok then
        note('Native Hologram presenter ready for current game build.')
    else
        note('Shortcut unavailable: ' .. tostring(result))
    end
end

local function activate()
    if not state.open_presenter then
        note('Shortcut detected, but the native Hologram presenter is unavailable.')
        return
    end
    local ui = pointer(read(state.game_base + UI_STATE_PTR_RVA, 8))
    if not ui then note('Shortcut detected, but UI state is unavailable.'); return end
    local manager = ui + PRESENTER_OFFSET
    local current = u32(read(manager + 12, 4))
    local depth = u32(read(manager + 40, 4))
    if current == HOLOGRAM_PRESENTER then
        note('Shortcut detected; Hologram already open.')
        return
    end
    if current ~= IDLE_MENU_PRESENTER or depth ~= 0 then
        note('Shortcut detected; presenter is busy (' ..
            tostring(current) .. ', depth ' .. tostring(depth) .. ').')
        return
    end
    note('Shortcut detected; entering native Hologram presenter.')
    state.open_presenter(ffi.cast('void *', manager), HOLOGRAM_PRESENTER, nil)
    note('Native Hologram presenter call returned; current=' ..
        tostring(u32(read(manager + 12, 4))) .. '.')
end

local function binding_host()
    local host = rawget(_G, 'ModBindingsMenu')
    if host and type(host.register_binding) == 'function' and
       type(host.is_down) == 'function' then
        if state.binding_host ~= host then
            local registered, result, reason = pcall(host.register_binding,
                BINDING_ID, BINDING_LABEL, 1)
            if registered and result then
                state.binding_host = host
                note('Using Mod Bindings Menu slot 1.')
            else
                note('Mod Bindings Menu registration failed: ' .. tostring(reason or result))
            end
        end
        if state.binding_host == host then return host end
    end
    return nil
end

local function shortcut_down()
    local host = binding_host()
    if host then
        local ok, down = pcall(host.is_down, BINDING_ID)
        if ok and down ~= nil then return down end
    end
    return key_down(HOTKEY)
end

local function step()
    if not state.update_logged then
        state.update_logged = true
        note('Update callback is running.')
    end
    binding_host()
    local world = ship_world(rawget(_G, 'stingray'))
    if state.world ~= world then
        state.world = world
        state.hotkey_down = false
        if world then
            note('Super Destroyer detected.')
            initialize_native()
        end
    end
    if not world then return end
    local down = focused_game() and shortcut_down()
    local pressed = down and not state.hotkey_down
    state.hotkey_down = down
    if pressed then activate() end
end

local previous_update = rawget(_G, 'update')
local function wrapped_update(dt)
    local ok, err = pcall(step)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= 8 then note('Update error: ' .. tostring(err)) end
    end
    if type(previous_update) == 'function' then return previous_update(dt) end
end

_G.GalacticMenuHotkeyInstalled = true
update = wrapped_update
note('Galactic Menu Hotkey initialized (Tab, native Hologram presenter).')
