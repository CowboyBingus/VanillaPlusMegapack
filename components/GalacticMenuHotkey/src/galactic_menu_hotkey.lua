-- HD2-Addon: mods/cowboybingus/galactic_menu_hotkey
-- Open the ship's menu presenters directly. The arcade shortcut requires
-- the local avatar to be beside the cabinet before starting its interaction.
-- The Hellpod shortcut seats the avatar through the native instant seat entry,
-- so the game opens the briefing and later runs its normal exit sequence.
if rawget(_G, 'GalacticMenuHotkeyInstalled') then return end
local ffi = require('ffi')
local bit = require('bit')
-- Texts and translations: ssh_text = {module = src/bingus_text.lua, locales =
-- locales/}, which the build places ahead of this file as a local (tests
-- provide it as a global). functions: one text function per key, so repeated
-- registrations pass the same function.
local translation = {T = ssh_text.module, functions = {}}
-- Bingus Shared Runtime's vendored src/bingus_runtime.lua and
-- src/bingus_memory.lua, which the build places ahead of this file as the
-- functions in the local ssh_runtime (tests provide it as a global): the update
-- guard (the family's update-chain policy) and the module hashes every mod
-- shares, read once per session.
local runtime = ssh_runtime.core()
local memory = ssh_runtime.memory().new(runtime)
local guard -- The update guard, installed at the end of this file.

-- Every Windows function goes by a private name, an __asm__ label naming the
-- real export, and every type name is this mod's own. ffi.cdef keeps the first
-- prototype declared for a name and the first layout declared for a type name
-- in the whole game, and ignores a later one without an error: another mod's
-- declarations of the real names can no longer change how this mod calls them,
-- and this mod's leave those names to the mods that declare them.
ffi.cdef [[
typedef unsigned short GMH_u16;
typedef unsigned int GMH_u32;
typedef unsigned long long GMH_u64;
typedef unsigned char GMH_u8;
void *GMH_GetCurrentProcess(void) __asm__("GetCurrentProcess");
GMH_u32 GMH_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
int GMH_ReadProcessMemory(void *process, const void *address, void *buffer,
                          size_t size, size_t *received) __asm__("ReadProcessMemory");
short GMH_GetAsyncKeyState(int key) __asm__("GetAsyncKeyState");
int32_t GMH_GetForegroundWindow(void) __asm__("GetForegroundWindow");
GMH_u32 GMH_GetWindowThreadProcessId(int64_t window, GMH_u32 *process) __asm__("GetWindowThreadProcessId");
]]

local kernel32, user32 = ffi.load('kernel32'), ffi.load('user32')
local process = kernel32.GMH_GetCurrentProcess()
local process_id = tonumber(kernel32.GMH_GetCurrentProcessId())
-- label: the game's own localization ID (translated by the game), or text:
-- a key in locales/en.lua.
local MAP_SHORTCUT = {name = 'Galactic Map', id = 'cowboybingus.galactic_menu',
                      label = 0xb46c8096, slot = 1, key = 0x09, presenter = 15} -- Hologram
local MENU_SHORTCUTS = {
    {name = 'Armory', id = 'cowboybingus.armory', label = 0x19e97f02,
     slot = 3, key = 0x70, presenter = 5}, -- F1
    {name = 'Control Center', id = 'cowboybingus.control_center',
     text = 'binding.control_center', slot = 4, key = 0x74, presenter = 6}, -- F5
    {name = 'Ship Management', id = 'cowboybingus.ship_management',
     label = 0x2716885e, slot = 5, key = 0x75, presenter = 8}, -- F6
    {name = 'Stratagem Hero', id = 'cowboybingus.stratagem_hero',
     text = 'binding.stratagem_hero', slot = 6, key = 0x76, arcade = true}, -- F7
    {name = 'Hellpod Deployment', id = 'cowboybingus.hellpod',
     label = 0xe89a91ef, slot = 7, key = 0x77, hellpod = true}, -- F8
}
-- Every shortcut in the order they are polled and acted on: the map first.
local SHORTCUTS = {MAP_SHORTCUT, unpack(MENU_SHORTCUTS)}
-- Context checks: the galaxy table lookup makes engine calls for every world
-- and the focus check two Windows calls, all unmeasured in game, so they do
-- not run on every frame. The context is read again every CONTEXT_FRAMES
-- frames and on every frame that acts (a newly pressed shortcut, or a Hellpod
-- wait or seat in progress), so nothing acts on an older answer. While the
-- game is not focused aboard the ship, its focus is checked on every frame, so
-- a shortcut pressed right after switching back acts on that frame as before.
local CONTEXT_FRAMES = 15
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
local IDLE_MENU_PRESENTER = 0
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
    -- keys_down: each shortcut's state on the last frame, by id; now: this
    -- frame's, in SHORTCUTS order.
    world = nil, world_status = nil, keys_down = {}, now = {},
    -- context_frames: frames until the context is read again; focused: the
    -- game window was in the foreground then; other_window: a foreground
    -- window already found to belong to another process.
    context_frames = 0, focused = false, other_window = nil,
    initialized = false,
    open_presenter = nil, start_arcade = nil, enter_seat = nil, open_briefing = nil,
    unit_position = nil, game_base = nil, hellpod_wait = nil, hellpod_seat = nil,
    update_logged = false,
    -- binding_host: the Mod Bindings Menu table registered with; binding_slots:
    -- the shortcuts it accepted, by id; binding_retry: another try is due
    -- (binding_retries made, binding_since frames ago, binding_revision then);
    -- binding_poll: that table's poll answers the shortcuts (see poll_bindings).
    binding_host = nil, binding_slots = {}, binding_retry = false, binding_retries = 0, binding_since = 0,
    binding_revision = nil, binding_poll = false,
}

local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('GalacticMenuHotkey.log') end)
end
-- Texts for Mod Bindings Menu. Version 3 and later take functions and call
-- them whenever a binding page opens, so the texts follow the game's
-- language; version 2 takes strings with byte limits, where a translation
-- that does not fit stays English.
function translation.binding_text(host, key, bytes)
    local tr = translation.tr
    if (tonumber(host.version) or 1) >= 3 then
        local fn = translation.functions[key]
        if not fn then
            fn = function() return tr(key) end
            translation.functions[key] = fn
        end
        return fn
    end
    local text = tr(key)
    return #text <= bytes and text or tr.english[key]
end
local function note(message)
    if log_file then
        pcall(function()
            log_file:write(message .. '\n')
            log_file:flush()
        end)
    end
end
-- The binding names, in the game's language when a translation has them.
translation.tr = translation.T.new(ssh_text.locales.en, ssh_text.locales.bundled,
                                   function(message) note('Text: ' .. message) end)
local function world_status(message)
    if state.world_status ~= message then
        state.world_status = message
        note('World detection: ' .. message)
    end
end

local function lookup_api_ready(engine)
    return type(engine) == 'table' and type(engine.Application) == 'table'
       and type(engine.World) == 'table' and type(engine.IdString64) == 'table'
       and type(engine.Application.main_world) == 'function'
       and type(engine.World.units_by_resource) == 'function'
       and type(engine.IdString64.from_hex) == 'function'
end

-- The worlds to search, in order: the main world, then every listed world.
-- One reused list, emptied before and after each lookup.
local world_list = {}
local function clear_worlds()
    for index = #world_list, 1, -1 do world_list[index] = nil end
end
local function add_world(world)
    if world and world ~= ffi.NULL then world_list[#world_list + 1] = world end
end
local function list_worlds(application)
    clear_worlds()
    local main_ok, main = pcall(application.main_world)
    if main_ok then add_world(main) end
    if type(application.worlds) == 'function' then
        local list_ok, list = pcall(application.worlds)
        if list_ok and type(list) == 'table' then
            for _, world in ipairs(list) do add_world(world) end
        end
    end
    return #world_list
end

-- The first listed world that holds the galaxy table, or nil.
local function galaxy_world(units_by_resource, table_id)
    for _, world in ipairs(world_list) do
        local listed, units = pcall(units_by_resource, world, table_id)
        if listed and type(units) == 'table' and next(units) ~= nil then return world end
    end
    return nil
end

local function ship_world(engine)
    if not lookup_api_ready(engine) then
        world_status('Stingray world lookup API unavailable')
        return nil
    end
    local hashed, table_id = pcall(engine.IdString64.from_hex, SHIP_TABLE_HASH)
    if not hashed or not table_id then
        world_status('could not convert galaxy table resource ID')
        return nil
    end
    local count = list_worlds(engine.Application)
    if count == 0 then
        world_status('no active Stingray worlds')
        return nil
    end
    local world = galaxy_world(engine.World.units_by_resource, table_id)
    clear_worlds()
    world_status('galaxy table ' .. (world and 'present' or 'absent') .. ' (' .. count .. ' worlds checked)')
    return world
end

-- The foreground window's process, read into one reused buffer.
local window_process = ffi.new('GMH_u32[1]')
-- Whether the game window is in the foreground. Windows keeps window handles
-- to 32 bits, sign-extended to 64, so they pass as plain numbers: no cdata per
-- call. Unless full, a foreground window already found to belong to another
-- process is not looked up again.
local function focused_game(full)
    local window = user32.GMH_GetForegroundWindow()
    if window == 0 or (not full and window == state.other_window) then return false end
    window_process[0] = 0
    user32.GMH_GetWindowThreadProcessId(window, window_process)
    local ours = window_process[0] == process_id
    state.other_window = not ours and window or nil
    return ours
end
local function key_down(key)
    return bit.band(user32.GMH_GetAsyncKeyState(key), 0x8000) ~= 0
end
local function read(address, size)
    local buffer, received = ffi.new('GMH_u8[?]', size), ffi.new('size_t[1]')
    if kernel32.GMH_ReadProcessMemory(process, ffi.cast('const void *', address),
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
-- Raises reason as it is, without a position, for the guard's stop line.
local function check(condition, reason)
    if not condition then error(reason, 0) end
end
-- The native check, when the ship is first found. A build this release does not
-- support stops the update for the session, the family's refusal:
-- BingusRuntime.statuses shows "stopped: unsupported game build" (or the native
-- change found), the log has that one stop line, that frame ends there (see
-- enter_world), and no step runs again.
local function initialize_native()
    if state.initialized then return end
    state.initialized = true
    local ok, result = pcall(function()
        check(ffi.abi('64bit'), 'Windows x64 required')
        -- Each module file is hashed at most once per session for every mod
        -- (Bingus Shared Runtime's cache); 'game modules unavailable' or
        -- 'unsupported game build' when they do not match.
        check(memory.verify_build({exe_sha256 = EXE_SHA256, game_sha256 = GAME_SHA256}))
        local base = memory.address(memory.module('game.dll'))
        check(read(base + ENTER_PRESENTER_RVA, #PRESENTER_PREFIX) ==
              PRESENTER_PREFIX, 'native presenter changed in memory')
        check(read(base + START_ARCADE_RVA, #ARCADE_PREFIX) ==
              ARCADE_PREFIX, 'native arcade start changed in memory')
        check(read(base + INSTANT_SEAT_RVA, #INSTANT_SEAT_PREFIX) ==
              INSTANT_SEAT_PREFIX, 'native instant seat entry changed in memory')
        check(read(base + OPEN_BRIEFING_RVA, #BRIEFING_PREFIX) ==
              BRIEFING_PREFIX, 'native Hellpod briefing entry changed in memory')
        check(pointer(read(base + UI_STATE_PTR_RVA, 8)), 'UI state unavailable')
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
        guard.stop(tostring(result))
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

-- Registration with Mod Bindings Menu. Every shortcut registers once per Mod
-- Bindings Menu table: a new table means a new registration. One that failed
-- (returned false or raised) keeps its fixed key and is tried again, at most
-- BINDING_RETRIES times per table: BINDING_RETRY_FRAMES frames after the last
-- try and twice as long after each further one, or sooner once the table's
-- revision changes (versions that publish one), but never twice within
-- BINDING_RETRY_FRAMES frames. While every shortcut is registered, and once
-- the tries are used up, a frame only compares the table's identity.
local BINDING_RETRIES, BINDING_RETRY_FRAMES = 8, 60

-- One registration, its texts included: a text lookup can raise.
local function call_register(host, shortcut)
    local label = shortcut.label or translation.binding_text(host, shortcut.text, 127)
    -- Mod Bindings Menu v2 groups rows under this header; v1 ignores it.
    local options = {category = translation.binding_text(host, 'binding.section', 64)}
    return host.register_binding(shortcut.id, label, shortcut.slot, options)
end

-- Registers one shortcut (try 0 is the first); a failure is logged on the
-- first try only. Returns whether Mod Bindings Menu accepted it.
local function register_shortcut(host, shortcut, try)
    local called, result, reason = pcall(call_register, host, shortcut)
    if called and result then
        state.binding_slots[shortcut.id] = true
        local retried = try > 0 and ' (try ' .. (try + 1) .. ')' or ''
        note('Using Mod Bindings Menu slot ' .. shortcut.slot .. ' for ' .. shortcut.name .. retried .. '.')
        return true
    end
    if try == 0 then
        note('Mod binding registration failed for ' .. shortcut.name .. ': ' .. tostring(reason or result))
    end
    return false
end

-- Tries every shortcut not yet registered; returns the names still missing,
-- or nil when none is.
local function register_missing(host, try)
    local missing
    for _, shortcut in ipairs(SHORTCUTS) do
        if not state.binding_slots[shortcut.id] and not register_shortcut(host, shortcut, try) then
            missing = (missing and missing .. ', ' or '') .. shortcut.name
        end
    end
    return missing
end

-- After a try: another one is due while a shortcut is missing and tries are left.
local function schedule_retry(host, missing)
    state.binding_since, state.binding_revision = 0, host.revision
    state.binding_retry = missing ~= nil and state.binding_retries < BINDING_RETRIES
    if missing and not state.binding_retry then
        note('Mod binding registration still failing after ' .. BINDING_RETRIES .. ' retries for ' .. missing ..
             '; the fixed keys stay in use for this session.')
    end
end

-- A Mod Bindings Menu table seen for the first time: every shortcut registers.
-- A table that offers poll (its field, never its version) answers them all in
-- one call per frame.
local function register_all(host)
    state.binding_host, state.binding_slots, state.binding_retries = host, {}, 0
    state.binding_poll = type(host.poll) == 'function'
    schedule_retry(host, register_missing(host, 0))
end

-- A frame while a shortcut is missing: tries again once it is due.
local function retry_bindings(host)
    local since = state.binding_since + 1
    state.binding_since = since
    if since < BINDING_RETRY_FRAMES * 2 ^ state.binding_retries
       and (since < BINDING_RETRY_FRAMES or host.revision == state.binding_revision) then
        return
    end
    state.binding_retries = state.binding_retries + 1
    schedule_retry(host, register_missing(host, state.binding_retries))
end

-- Whether host is a Mod Bindings Menu table this mod can register with.
local function usable(host)
    return type(host) == 'table' and type(host.register_binding) == 'function' and type(host.is_down) == 'function'
end

-- Once per frame: the Mod Bindings Menu to poll, or nil for the fixed keys.
local function binding_host()
    local host = rawget(_G, 'ModBindingsMenu')
    if host == state.binding_host then
        if state.binding_retry then retry_bindings(host) end
        return host
    end
    if not usable(host) then return nil end
    register_all(host)
    return host
end

-- Bingus Shared Loader's after_startup (v19, capabilities.after_startup) runs
-- this once every mod has started, before the first frame, whatever order the
-- mods load in: every shortcut registers then. Mod Bindings Menu's native
-- input may not be ready yet; registering does not need it, and until it is,
-- is_down and poll answer nil and the fixed keys stay in use. With older
-- loaders binding_host registers on the first frame instead. Either way
-- binding_host keeps the bounded retry for a registration that failed, and
-- registers again with a new Mod Bindings Menu table.
local function register_after_startup()
    local host = rawget(_G, 'ModBindingsMenu')
    if host ~= state.binding_host and usable(host) then register_all(host) end
end

-- Mod Bindings Menu's poll, where it offers one, answers every shortcut in one
-- call per focused frame: each record header, then all six states in one read
-- (8 reads, where six is_down calls make 18). Only its down array is used, in
-- place of is_down's answers: the edges stay this mod's own, so the fixed keys
-- and the window focus count as before. POLL_IDS holds every shortcut's id in
-- SHORTCUTS order, so polled.down is by SHORTCUTS index.
local POLL_IDS, polled = {}, {}
for index, shortcut in ipairs(SHORTCUTS) do POLL_IDS[index] = shortcut.id end

-- Once per focused frame: whether polled.down holds this frame's answers. A
-- poll that raises or refuses is logged once, and is_down answers for the rest
-- of the session with that table, starting with this frame.
local function poll_bindings(host)
    if not (host and state.binding_poll and next(state.binding_slots)) then return false end
    local called, done, reason = pcall(host.poll, POLL_IDS, polled)
    if called and done == true then return true end
    state.binding_poll = false
    note('Mod Bindings Menu poll failed (' .. tostring(called and reason or done) ..
         '); asking for each shortcut instead.')
    return false
end

-- A shortcut's state: its binding's answer (from this frame's poll when
-- batch, else from is_down), or its fixed key when there is none.
local function shortcut_down(shortcut, host, index, batch)
    if host and state.binding_slots[shortcut.id] then
        local ok, down = true, nil
        if batch then
            down = polled.down[index]
        else
            ok, down = pcall(host.is_down, shortcut.id)
        end
        if ok and down ~= nil then return down end
    end
    return key_down(shortcut.key)
end

local function enter_world(world)
    state.world = world
    state.keys_down = {}
    state.hellpod_wait = nil
    state.hellpod_seat = nil
    if world then
        note('Super Destroyer detected.')
        initialize_native()
        -- A refused build has stopped the update: this frame ends here, aboard
        -- no ship, without a focus check, a key read or an action.
        if not guard.running() then state.world = nil end
    end
end

-- Reads the context: the ship's world, then (aboard) the window focus.
local function refresh_context()
    state.context_frames = CONTEXT_FRAMES
    local world = ship_world(rawget(_G, 'stingray'))
    if state.world ~= world then enter_world(world) end
    state.focused = state.world ~= nil and focused_game(true)
end

-- Runs once per frame before anything acts; returns whether it read the context.
local function advance_context()
    state.context_frames = state.context_frames - 1
    if state.context_frames <= 0 or state.hellpod_wait or state.hellpod_seat then
        refresh_context()
        return true
    end
    if state.world and not state.focused then state.focused = focused_game(false) end
    return false
end

-- Every shortcut's state on this frame, in order (none is polled while the game
-- is not focused); returns whether one is newly pressed.
local function poll_shortcuts(host)
    local pressed, batch = false, state.focused and poll_bindings(host)
    for index, shortcut in ipairs(SHORTCUTS) do
        local down = state.focused and shortcut_down(shortcut, host, index, batch) or false
        state.now[index] = down
        pressed = pressed or (down and not state.keys_down[shortcut.id])
    end
    return pressed
end

local function act(shortcut)
    if shortcut.arcade then activate_arcade()
    elseif shortcut.hellpod then activate_hellpod()
    else activate(shortcut.name, shortcut.presenter) end
end

-- Records this frame's states and acts on each newly pressed shortcut, in
-- order. Nothing is down while the game is not focused.
local function act_on_shortcuts()
    for index, shortcut in ipairs(SHORTCUTS) do
        local down = state.focused and state.now[index]
        local pressed = down and not state.keys_down[shortcut.id]
        state.keys_down[shortcut.id] = down
        if pressed then act(shortcut) end
    end
end

-- Shortcuts are polled on every frame aboard while the game is focused, and a
-- shortcut acts on the frame it is first seen down, as before; only the
-- context checks are spaced out (see CONTEXT_FRAMES).
local function step(dt)
    if not state.update_logged then
        state.update_logged = true
        note('Update callback is running.')
    end
    local host = binding_host()
    local fresh = advance_context()
    if not state.world then return end
    if state.hellpod_wait then service_hellpod(tonumber(dt) or 0) end
    if state.hellpod_seat then service_hellpod_seat(tonumber(dt) or 0) end
    -- A newly pressed shortcut acts only on a context read on this frame.
    if poll_shortcuts(host) and not fresh then
        refresh_context()
        if not state.world then return end
    end
    act_on_shortcuts()
end

-- An update below this mod raised: the shortcuts pause, and start afresh when
-- they resume. Every shortcut counts as held until it is released, so a key
-- held through the pause needs a fresh press; a Hellpod wait or seat still
-- pending is cancelled; the context is read again on the next frame. The
-- registrations with Mod Bindings Menu stay.
local function pause_shortcuts()
    for _, shortcut in ipairs(SHORTCUTS) do state.keys_down[shortcut.id] = true end
    if state.hellpod_wait or state.hellpod_seat then
        state.hellpod_wait, state.hellpod_seat = nil, nil
        note('Hellpod shortcut cancelled; the update paused.')
    end
    state.context_frames = 0
end

-- The update chain, through Bingus Shared Runtime's guard: the previous update
-- runs outside pcall, so its errors reach the game unchanged; the step's errors
-- count in bursts (the 8th of a burst stops it for the session, 3600 error-free
-- frames end a burst); after an error below this mod the shortcuts pause
-- (pause_shortcuts) and resume once the updates below have returned on 60
-- frames in a row, and 8 such errors in a burst stop them. A stop and the
-- game's shutdown have no game state to restore: the shortcuts call the game's
-- own presenter, arcade and seat entries. The first failure survives shutdown
-- in BingusRuntime.statuses.ShipStationHotkeys. Every argument and return value
-- pass through. Per frame: the step under pcall and a few tests and stores, no
-- allocation (pinned in tests/test_hotkey.lua).
_G.GalacticMenuHotkeyInstalled = true
guard = runtime.guard({name = 'ShipStationHotkeys', step = step, pause = pause_shortcuts, log = note, env = _G}).install()
if type(loader) == 'table' and type(loader.capabilities) == 'table' and loader.capabilities.after_startup == true
   and type(loader.after_startup) == 'function' then
    local accepted, reason = loader.after_startup(register_after_startup)
    if not accepted then note('Registration after startup refused (' .. tostring(reason) .. '); registering on the first frame.') end
end
note('Ship menu hotkeys initialized (Tab, F1, F5-F8).')
