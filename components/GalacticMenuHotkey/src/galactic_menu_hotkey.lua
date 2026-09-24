-- HD2-Addon: mods/cowboybingus/galactic_menu_hotkey
-- Open the ship's menu presenters directly. The arcade shortcut requires
-- the local avatar to be beside the cabinet before starting its interaction.
-- The Hellpod shortcut seats the avatar through the native instant seat entry,
-- so the game opens the briefing and later runs its normal exit sequence.
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
local BINDING_OPTIONS = {category = 'Ship Station Hotkeys'}
local MAP_SHORTCUT = {name = 'Galactic Map', id = 'cowboybingus.galactic_menu',
                      label = 0xb46c8096, slot = 1, key = 0x09, presenter = 15}
local MENU_SHORTCUTS = {
    {name = 'Armory', id = 'cowboybingus.armory', label = 0x19e97f02,
     slot = 3, key = 0x70, presenter = 5}, -- F1
    {name = 'Control Center', id = 'cowboybingus.control_center',
     label = 'CONTROL CENTER', slot = 4, key = 0x74, presenter = 6}, -- F5
    {name = 'Ship Management', id = 'cowboybingus.ship_management',
     label = 0x2716885e, slot = 5, key = 0x75, presenter = 8}, -- F6
    {name = 'Stratagem Hero', id = 'cowboybingus.stratagem_hero',
     label = 'STRATAGEM HERO', slot = 6, key = 0x76, arcade = true}, -- F7
    {name = 'Hellpod Deployment', id = 'cowboybingus.hellpod',
     label = 0xe89a91ef, slot = 7, key = 0x77, hellpod = true}, -- F8
}
local SHIP_TABLE_HASH = '3b9bcf29e38da0a6'
local GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
local EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'

-- Steam build 25480438: PresenterManager::open presenter, and the game's
-- pointer to its top-level UI state. Presenter 15 is Hologram; that presenter
-- pushes MenuScreenType 24. Its screen initialization ignores extra data.
local ENTER_PRESENTER_RVA = 0x14c0350
local START_ARCADE_RVA = 0x997800
local UI_STATE_PTR_RVA = 0x347ce28
local ARCADE_COMPONENT_PTR_RVA = 0x3326700
local ARCADE_SYSTEM_PTR_RVA = 0x3326e68
local PLAYER_MANAGER_PTR_RVA = 0x3326468
local ENTITY_MANAGER_PTR_RVA = 0x346bf98
local UNIT_INTERFACE_PTR_RVA = 0x3326308
local HELLPOD_SYSTEM_PTR_RVA = 0x33265f0
local HELLPOD_MANAGER_PTR_RVA = 0x3326428
local SEATER_COMPONENT_PTR_RVA = 0x3326d78
-- Seater instant-entry routine used when a player spawns inside a seat. It
-- validates a free seat slot, runs set_entering with the instant flag,
-- reserves the slot, replicates both steps and ticks the seater, so the
-- Hellpod enter action completes without its 3.13 second transition.
local INSTANT_SEAT_RVA = 0x639830
-- Hellpod briefing entry: the same deployment setup and presenter 14 request
-- the seat completion makes. Opening it first hides the seat behind the
-- briefing; the completion then sees presenter 14 on the stack and skips it.
local OPEN_BRIEFING_RVA = 0x661cf0
local BRIEFING_PRESENTER = 14
-- The loadout screen (MenuScreenType 11, pointer at screen stack +176) waits
-- in intro phase 1 for a 2.0 second timer before building the briefing UI.
-- The shortcut expires that timer, then seats the avatar once the UI is up
-- (phase 0). If the intro is never seen, it seats after the fallback delay.
local SCREEN_STACK_PTR_RVA = 0x347ce38
local LOADOUT_SCREEN, LOADOUT_SCREEN_SLOT = 11, 176
local INTRO_TIMER_OFFSET, INTRO_PHASE_OFFSET = 2570632, 2570636
local INTRO_WAITING, INTRO_DONE = 1, 0
-- Seat on the frame the briefing UI appears. The briefing sets its map camera
-- then; seating later lets the pod entry camera replace it (live test).
local SEAT_FALLBACK_SECONDS = 3
local PRESENTER_OFFSET = 17032
local ARCADE_MAX_DISTANCE_SQUARED = 9 -- Three world units from cabinet root.
local IDLE_MENU_PRESENTER, HOLOGRAM_PRESENTER = 0, 15
-- Hellpod manager pod mode 2 means a mission is selected. Pod state 3 is
-- open for entry; 4 is occupied. States 0-2 precede the opening animation.
local POD_MISSION_READY, POD_OPEN, POD_OCCUPIED = 2, 3, 4
local HELLPOD_OPEN_WAIT_SECONDS = 10
local PRESENTER_PREFIX =
    '\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20\x8b'
local ARCADE_PREFIX =
    '\x48\x8b\xc4\x48\x89\x50\x10\x48\x89\x48\x08\x53\x55\x57\x48\x83'
local UNIT_POSITION_PREFIX = '\x40\x53\x48\x83\xec\x20'
local INSTANT_SEAT_PREFIX =
    '\x48\x89\x5c\x24\x20\x48\x89\x54\x24\x10\x56\x57\x41\x54\x41\x55'
local BRIEFING_PREFIX =
    '\x48\x89\x4c\x24\x08\x57\x48\x83\xec\x40\x4c\x8b\x0d'

local state = {
    world = nil, world_status = nil, hotkey_down = false, menu_keys_down = {},
    initialized = false,
    open_presenter = nil, start_arcade = nil, enter_seat = nil, open_briefing = nil,
    unit_position = nil, game_base = nil, hellpod_wait = nil, hellpod_seat = nil,
    update_logged = false, errors = 0,
    binding_host = nil, binding_slots = {},
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
        assert(read(base + START_ARCADE_RVA, #ARCADE_PREFIX) ==
               ARCADE_PREFIX, 'native arcade start changed in memory')
        assert(read(base + INSTANT_SEAT_RVA, #INSTANT_SEAT_PREFIX) ==
               INSTANT_SEAT_PREFIX, 'native instant seat entry changed in memory')
        assert(read(base + OPEN_BRIEFING_RVA, #BRIEFING_PREFIX) ==
               BRIEFING_PREFIX, 'native Hellpod briefing entry changed in memory')
        assert(pointer(read(base + UI_STATE_PTR_RVA, 8)), 'UI state unavailable')
        state.game_base = base
        state.open_presenter = ffi.cast('void (__fastcall *)(void *, int, void *)',
            base + ENTER_PRESENTER_RVA)
        state.start_arcade = ffi.cast(
            'void (__fastcall *)(void *, void *, GMH_u32, GMH_u32)',
            base + START_ARCADE_RVA)
        state.enter_seat = ffi.cast(
            'void (__fastcall *)(void *, void *, void *)', base + INSTANT_SEAT_RVA)
        state.open_briefing = ffi.cast(
            'void (__fastcall *)(void *, GMH_u32)', base + OPEN_BRIEFING_RVA)
        local unit_interface = pointer(read(base + UNIT_INTERFACE_PTR_RVA, 8))
        local unit_vtable = unit_interface and pointer(read(unit_interface + 24, 8))
        local position_address = unit_vtable and pointer(read(unit_vtable + 136, 8))
        if position_address and read(position_address, #UNIT_POSITION_PREFIX) ==
                UNIT_POSITION_PREFIX then
            state.unit_position = ffi.cast(
                'GMH_u64 (__fastcall *)(GMH_u32, int)', position_address)
        else
            note('Arcade proximity check unavailable: world-position function changed.')
        end
    end)
    if ok then
        note('Native ship menu presenters ready for current game build.')
    else
        note('Shortcut unavailable: ' .. tostring(result))
    end
end

local function presenter_status()
    local ui = pointer(read(state.game_base + UI_STATE_PTR_RVA, 8))
    if not ui then return nil end
    local manager = ui + PRESENTER_OFFSET
    return manager, u32(read(manager + 12, 4)), u32(read(manager + 40, 4))
end

local function idle_manager(name, presenter)
    if not state.open_presenter then
        note(name .. ' shortcut detected, but the native presenter is unavailable.')
        return nil
    end
    local manager, current, depth = presenter_status()
    if not manager then note(name .. ' shortcut detected, but UI state is unavailable.'); return nil end
    if presenter and current == presenter then
        note(name .. ' shortcut detected; presenter already open.')
        return nil
    end
    if current ~= IDLE_MENU_PRESENTER or depth ~= 0 then
        note(name .. ' shortcut detected; presenter is busy (' ..
            tostring(current) .. ', depth ' .. tostring(depth) .. ').')
        return nil
    end
    return manager
end

local function activate(name, presenter)
    local manager = idle_manager(name, presenter)
    if not manager then return end
    note(name .. ' shortcut detected; entering native presenter ' .. presenter .. '.')
    state.open_presenter(ffi.cast('void *', manager), presenter, nil)
    note(name .. ' presenter call returned; current=' ..
        tostring(u32(read(manager + 12, 4))) .. '.')
end

local function u32_at(blob, offset)
    return u32(blob and blob:sub(offset + 1, offset + 4))
end

-- Probe one of the game's open-addressed entity maps: 8-byte buckets holding
-- (key, value), a power-of-two capacity, an empty key and a multiplier.
local function hashed_value(buckets, capacity, empty, multiplier, key)
    local product = tonumber(ffi.cast('GMH_u32',
        ffi.new('GMH_u64', key) * ffi.new('GMH_u64', multiplier)))
    for probe = 0, math.min(capacity, 128) - 1 do
        local entry = read(buckets + 8 * bit.band(product + probe, capacity - 1), 8)
        if not entry then return nil end
        local found = u32_at(entry, 0)
        if found == key then return u32_at(entry, 4) end
        if found == empty then return nil end
    end
    return nil
end

local function map_layout(blob)
    local buckets = pointer(blob and blob:sub(1, 8))
    local capacity, empty, multiplier = u32_at(blob, 8), u32_at(blob, 12), u32_at(blob, 16)
    if not buckets or not capacity or capacity < 1 or capacity > 1048576 or
       bit.band(capacity, capacity - 1) ~= 0 or not empty or not multiplier then
        return nil
    end
    return buckets, capacity, empty, multiplier
end

local function entity_record(entities, entity_ref)
    local buckets, capacity, empty, multiplier = map_layout(read(entities + 0xf22ec8, 20))
    if not buckets then return nil end
    local index = hashed_value(buckets, capacity, empty, multiplier, entity_ref)
    if not index or index == 0xffffffff or index >= 262144 then return nil end
    return read(entities + 0xf32f18 + 24 * index, 24)
end

-- The local player's avatar entity ID and unit, plus the entity manager.
local function local_avatar()
    local base = state.game_base
    local players = pointer(read(base + PLAYER_MANAGER_PTR_RVA, 8))
    local entities = pointer(read(base + ENTITY_MANAGER_PTR_RVA, 8))
    if not players or not entities then return nil end
    local local_count = u32(read(players + 0x84, 4))
    local local_active = u32(read(players + 0x88, 4))
    if not local_count or local_count < 1 or local_count > 4 or
       not local_active or local_active < 1 or local_active > 4 then return nil end
    local player_record = pointer(read(players + 0xe8, 8))
    local player = player_record and read(player_record, 24)
    if not player or bit.band(player:byte(21), 1) == 0 then return nil end
    local ref = u32(read(players + 0x3a8, 4))
    if not ref or ref == 0x7fff then return nil end
    local avatar = entity_record(entities, ref)
    if not avatar or avatar:sub(1, 8) ~= '\x97\xfa\x4d\x29\x4d\x33\x1c\x4d'
       or bit.band(avatar:byte(21), 1) == 0 then return nil end
    local avatar_id, avatar_unit = u32_at(avatar, 8), u32_at(avatar, 12)
    if not avatar_id or avatar_id == 0 or avatar_id == 0xffffffff or
       not avatar_unit or avatar_unit == 0 then return nil end
    return avatar_id, avatar_unit, entities
end

local function arcade_context()
    local base = state.game_base
    local manager = pointer(read(base + ARCADE_COMPONENT_PTR_RVA, 8))
    if not manager then return nil end
    -- This ship has one arcade minigame record. Reject any other component
    -- layout or multiple candidates rather than choosing an arbitrary unit.
    local count = u32(read(manager + 24, 4))
    local capacity = u32(read(manager + 56, 4))
    local empty = u32(read(manager + 60, 4))
    local buckets = pointer(read(manager + 48, 8))
    local pool = pointer(read(manager + 88, 8))
    if count ~= 1 or capacity ~= 128 or empty ~= 0 or not buckets or not pool then
        return nil
    end
    local entries = read(buckets, capacity * 8)
    if not entries then return nil end
    local arcade_id
    for index = 0, capacity - 1 do
        local entity, slot = u32_at(entries, index * 8), u32_at(entries, index * 8 + 4)
        if entity ~= empty then
            if arcade_id or not entity or entity == 0xffffffff or slot ~= 0 then
                return nil
            end
            arcade_id = entity
        end
    end
    if not arcade_id then return nil end

    local systems = pointer(read(base + ARCADE_SYSTEM_PTR_RVA, 8))
    if not systems then return nil end
    local system_count = u32(read(systems + 19512, 4))
    if not system_count or system_count < 1 or system_count > 256 then return nil end
    local rows = read(systems + 19520, system_count * 16)
    if not rows then return nil end
    local system
    for index = 0, system_count - 1 do
        if u32_at(rows, index * 16 + 8) == 67 then
            if system then return nil end
            system = pointer(rows:sub(index * 16 + 1, index * 16 + 8))
        end
    end
    if not system then return nil end

    local avatar_id, avatar_unit, entities = local_avatar()
    if not avatar_id then return nil end
    local cabinet = entity_record(entities, arcade_id)
    if not cabinet or bit.band(cabinet:byte(21), 1) == 0 then return nil end
    local cabinet_unit = u32_at(cabinet, 12)
    if not cabinet_unit or cabinet_unit == 0 then return nil end
    -- Field 5208 is zero while the cabinet is idle. Field 5212 retains the
    -- last player after they leave, so it cannot be used as an idle guard.
    if u32(read(pool + 5208, 4)) ~= 0 then return nil end
    return system, arcade_id, avatar_id, pool, cabinet_unit, avatar_unit
end

local function arcade_nearby(cabinet_unit, avatar_unit)
    if not state.unit_position then return false end
    local cabinet_address = tonumber(state.unit_position(cabinet_unit, 0))
    local avatar_address = tonumber(state.unit_position(avatar_unit, 0))
    if not cabinet_address or not avatar_address then return false end
    local cabinet_blob, avatar_blob = read(cabinet_address, 12), read(avatar_address, 12)
    if not cabinet_blob or not avatar_blob then return false end
    local cabinet, avatar = ffi.new('float[3]'), ffi.new('float[3]')
    ffi.copy(cabinet, cabinet_blob, 12)
    ffi.copy(avatar, avatar_blob, 12)
    local distance_squared = 0
    for axis = 0, 2 do
        if math.abs(cabinet[axis]) > 10000 or math.abs(avatar[axis]) > 10000 then
            return false
        end
        local delta = cabinet[axis] - avatar[axis]
        distance_squared = distance_squared + delta * delta
    end
    if distance_squared ~= distance_squared then return false end
    note(string.format('Stratagem Hero distance squared: %.2f', distance_squared))
    return distance_squared <= ARCADE_MAX_DISTANCE_SQUARED
end

local function activate_arcade()
    if not idle_manager('Stratagem Hero') then return end
    if not state.start_arcade then return end
    local system, arcade_id, avatar_id, pool, cabinet_unit, avatar_unit = arcade_context()
    if not system then
        note('Stratagem Hero shortcut detected; arcade or local avatar is unavailable.')
        return
    end
    if not arcade_nearby(cabinet_unit, avatar_unit) then
        note('Stratagem Hero shortcut detected; move beside the cabinet first.')
        return
    end
    note('Stratagem Hero shortcut detected; starting native arcade interaction.')
    state.start_arcade(ffi.cast('void *', system), nil, arcade_id, avatar_id)
    note('Native arcade start returned; active avatar=' ..
         tostring(u32(read(pool + 5208, 4))) .. '.')
end

-- The local player's Hellpod: the deployment system's slot 0 pod, which is
-- Hellpod index 0 in the manager. The manager keeps parallel per-pod arrays:
-- entity pointers at +104, mode at +136, state at +184, index at +188 and
-- target state at +264.
local function hellpod_context()
    local base = state.game_base
    local system = pointer(read(base + HELLPOD_SYSTEM_PTR_RVA, 8))
    local manager = pointer(read(base + HELLPOD_MANAGER_PTR_RVA, 8))
    if not system or not manager then return nil, 'deployment system is unavailable' end
    -- Slot 0 belongs to the local player only when they are alone. Pod
    -- ownership and seat replication with other players are unverified.
    if u32(read(system + 32, 4)) ~= 1 or u32(read(system + 36, 4)) ~= 1 then
        return nil, 'only solo ship sessions are supported'
    end
    local slot_pod = u32(read(system + 72984, 4))
    local count = u32(read(manager + 8, 4))
    if not slot_pod or slot_pod == 0 or not count or count < 1 or count > 4 then
        return nil, 'Hellpod layout is unavailable'
    end
    for index = 0, count - 1 do
        local entity = pointer(read(manager + 104 + 8 * index, 8))
        if entity and u32(read(entity + 8, 4)) == slot_pod then
            if u32(read(manager + 188 + 20 * index, 4)) ~= 0 or
               bit.band((read(entity + 20, 1) or '\0'):byte(), 1) == 0 then
                break
            end
            return {
                pod = slot_pod,
                mode = u32(read(manager + 136 + 12 * index, 4)),
                current = u32(read(manager + 184 + 20 * index, 4)),
                target = u32(read(manager + 264 + 4 * index, 4)),
            }
        end
    end
    return nil, 'Hellpod layout is unavailable'
end

-- The avatar's entity pointer and 64-byte seater record: +0 seat collection,
-- +20 current node, +24 target node, +48 transition in progress.
local function avatar_seater(avatar_id)
    local component = pointer(read(state.game_base + SEATER_COMPONENT_PTR_RVA, 8))
    if not component then return nil end
    local buckets, capacity, empty, multiplier = map_layout(read(component + 32, 20))
    local count = u32(read(component + 12, 4))
    if not buckets or not count then return nil end
    local index = hashed_value(buckets, capacity, empty, multiplier, avatar_id)
    if not index or index >= count then return nil end
    local entities = pointer(read(component + 56, 8))
    local records = pointer(read(component + 72, 8))
    local entity = entities and pointer(read(entities + 8 * index, 8))
    if not entity or not records or u32(read(entity + 8, 4)) ~= avatar_id then
        return nil
    end
    return entity, records + 64 * index
end

-- The avatar's seater when it is free to enter a seat, or nil and a reason.
local function free_seater()
    local avatar_id = local_avatar()
    if not avatar_id then return nil, 'local avatar is unavailable' end
    local entity, seater = avatar_seater(avatar_id)
    local record = seater and read(seater, 64)
    if not entity or not record then return nil, 'local seater is unavailable' end
    if u32_at(record, 0) ~= 0 or record:byte(49) ~= 0 then
        return nil, 'your character is already seated or moving'
    end
    return entity, seater
end

local function pod_open(context)
    return context.current == POD_OPEN and context.target == POD_OPEN
end

local function seat_in_hellpod(pod)
    local entity, seater = free_seater()
    if not entity then
        note('Hellpod seat skipped; ' .. seater .. '.')
        return
    end
    -- Placement read by the instant entry: byte 0 enables it, and the pointer
    -- at +72 holds the seat collection at [406], an entrance hash at [407]
    -- (0 selects by index) and the entrance index at [408].
    local placement = ffi.new('GMH_u32[409]')
    placement[406] = pod
    local request = ffi.new('GMH_u8[80]')
    request[0] = 1
    ffi.cast('GMH_u32 **', request + 72)[0] = placement
    state.enter_seat(nil, ffi.cast('void *', entity), request)
    local after = read(seater, 64)
    local _, current = presenter_status()
    note('Native Hellpod seat returned behind the briefing; seat=' ..
         tostring(u32_at(after, 0)) .. ', presenter=' .. tostring(current) .. '.')
end

-- Open the briefing at once, then seat the avatar once the briefing UI covers
-- the ship so the move into the pod is not visible.
local function enter_hellpod(context)
    local entity, reason = free_seater()
    if not entity then
        note('Hellpod shortcut detected; ' .. reason .. '.')
        return
    end
    note('Hellpod shortcut detected; opening the briefing.')
    state.open_briefing(nil, 0)
    local _, current = presenter_status()
    if current ~= BRIEFING_PRESENTER then
        note('Hellpod briefing did not open; presenter=' .. tostring(current) .. '.')
        return
    end
    state.hellpod_seat = {pod = context.pod, delay = SEAT_FALLBACK_SECONDS}
end

local function loadout_screen()
    local stack = pointer(read(state.game_base + SCREEN_STACK_PTR_RVA, 8))
    if not stack or u32(read(stack, 4)) ~= LOADOUT_SCREEN then return nil end
    return pointer(read(stack + LOADOUT_SCREEN_SLOT, 8))
end

-- Skip the briefing intro, then seat the avatar once the briefing UI is up.
local function service_hellpod_seat(dt)
    local pending = state.hellpod_seat
    local _, current = presenter_status()
    if current ~= BRIEFING_PRESENTER then
        state.hellpod_seat = nil
        note('Hellpod seat cancelled; the briefing closed before seating.')
        return
    end
    pending.delay = pending.delay - dt
    local screen = loadout_screen()
    local phase = screen and u32(read(screen + INTRO_PHASE_OFFSET, 4))
    if phase == INTRO_WAITING and not pending.skipped then
        ffi.cast('float *', screen + INTRO_TIMER_OFFSET)[0] = 0
        pending.skipped = true
        note('Briefing intro skipped.')
        return
    end
    if not (pending.skipped and phase == INTRO_DONE) then
        if pending.delay > 0 then return end
        note('Briefing intro was not observed; seating after the fallback delay.')
    end
    state.hellpod_seat = nil
    local context = hellpod_context()
    if not context or context.mode ~= POD_MISSION_READY or not pod_open(context)
       or context.pod ~= pending.pod then
        note('Hellpod seat skipped; the Hellpod is no longer open.')
        return
    end
    seat_in_hellpod(pending.pod)
end

local function cancel_hellpod_wait(reason)
    state.hellpod_wait = nil
    note('Hellpod shortcut cancelled; ' .. reason .. '.')
end

local function activate_hellpod()
    if not idle_manager('Hellpod Deployment') or not state.enter_seat
       or not state.open_briefing then return end
    local context, reason = hellpod_context()
    if not context then
        note('Hellpod shortcut detected; ' .. reason .. '.')
        return
    end
    if context.mode ~= POD_MISSION_READY then
        note('Hellpod shortcut detected; select a mission first.')
        return
    end
    if context.current == POD_OCCUPIED or context.target == POD_OCCUPIED then
        note('Hellpod shortcut detected; the Hellpod is already occupied.')
        return
    end
    if pod_open(context) then
        state.hellpod_wait = nil
        enter_hellpod(context)
        return
    end
    state.hellpod_wait = HELLPOD_OPEN_WAIT_SECONDS
    note('Hellpod shortcut detected; entering when the Hellpod opens.')
end

-- A shortcut pressed during the ready animation enters as soon as it opens.
local function service_hellpod(dt)
    state.hellpod_wait = state.hellpod_wait - dt
    local _, current, depth = presenter_status()
    if current ~= IDLE_MENU_PRESENTER or depth ~= 0 then
        cancel_hellpod_wait('another menu opened')
        return
    end
    local context = hellpod_context()
    if not context or context.mode ~= POD_MISSION_READY then
        cancel_hellpod_wait('the mission is no longer selected')
    elseif pod_open(context) then
        state.hellpod_wait = nil
        enter_hellpod(context)
    elseif state.hellpod_wait <= 0 then
        cancel_hellpod_wait('the Hellpod did not open in time')
    end
end

local function binding_host()
    local host = rawget(_G, 'ModBindingsMenu')
    if host and type(host.register_binding) == 'function' and
       type(host.is_down) == 'function' then
        if state.binding_host ~= host then
            state.binding_host = host
            state.binding_slots = {}
            local shortcuts = {MAP_SHORTCUT}
            for _, shortcut in ipairs(MENU_SHORTCUTS) do
                shortcuts[#shortcuts + 1] = shortcut
            end
            for _, shortcut in ipairs(shortcuts) do
                -- Mod Bindings Menu v2 groups rows under this header; v1 ignores it.
                local called, result, reason = pcall(host.register_binding,
                    shortcut.id, shortcut.label, shortcut.slot, BINDING_OPTIONS)
                if called and result then
                    state.binding_slots[shortcut.id] = true
                    note('Using Mod Bindings Menu slot ' .. shortcut.slot ..
                         ' for ' .. shortcut.name .. '.')
                else
                    note('Mod binding registration failed for ' ..
                         shortcut.name .. ': ' .. tostring(reason or result))
                end
            end
        end
        return host
    end
    return nil
end

local function shortcut_down(shortcut)
    local host = binding_host()
    if host and state.binding_slots[shortcut.id] then
        local ok, down = pcall(host.is_down, shortcut.id)
        if ok and down ~= nil then return down end
    end
    return key_down(shortcut.key)
end

local function step(dt)
    if not state.update_logged then
        state.update_logged = true
        note('Update callback is running.')
    end
    binding_host()
    local world = ship_world(rawget(_G, 'stingray'))
    if state.world ~= world then
        state.world = world
        state.hotkey_down = false
        state.menu_keys_down = {}
        state.hellpod_wait = nil
        state.hellpod_seat = nil
        if world then
            note('Super Destroyer detected.')
            initialize_native()
        end
    end
    if not world then return end
    if state.hellpod_wait then service_hellpod(tonumber(dt) or 0) end
    if state.hellpod_seat then service_hellpod_seat(tonumber(dt) or 0) end
    local focused = focused_game()
    local down = focused and shortcut_down(MAP_SHORTCUT)
    local pressed = down and not state.hotkey_down
    state.hotkey_down = down
    if pressed then activate('Galactic Map', HOLOGRAM_PRESENTER) end
    for _, shortcut in ipairs(MENU_SHORTCUTS) do
        local key_is_down = focused and shortcut_down(shortcut)
        local key_pressed = key_is_down and not state.menu_keys_down[shortcut.id]
        state.menu_keys_down[shortcut.id] = key_is_down
        if key_pressed then
            if shortcut.arcade then activate_arcade()
            elseif shortcut.hellpod then activate_hellpod()
            else activate(shortcut.name, shortcut.presenter) end
        end
    end
end

local previous_update = rawget(_G, 'update')
local function wrapped_update(dt)
    local ok, err = pcall(step, dt)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= 8 then note('Update error: ' .. tostring(err)) end
    end
    if type(previous_update) == 'function' then return previous_update(dt) end
end

_G.GalacticMenuHotkeyInstalled = true
update = wrapped_update
note('Ship menu hotkeys initialized (Tab, F1, F5-F8).')
