-- Test the native-presenter dispatch guards without invoking game code.
local ffi = require('ffi')
local messages = {}
CowboyBingusModLoader = {open_log = function()
    return {
        write = function(_, message) messages[#messages + 1] = message end,
        flush = function() end,
    }
end}
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/galactic_menu_hotkey.lua')
dofile(source)

local function upvalue(fn, wanted)
    for index = 1, 50 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then return value end
    end
    error('missing upvalue ' .. wanted)
end

local step = upvalue(update, 'step')
local state = upvalue(step, 'state')
local shortcut_down = upvalue(step, 'shortcut_down')
local map_shortcut = upvalue(step, 'MAP_SHORTCUT')
local menu_shortcuts = upvalue(step, 'MENU_SHORTCUTS')
local expected_shortcuts = {
    {0x70, 5, 3}, {0x74, 6, 4}, {0x75, 8, 5},
    {0x76, 'arcade', 6}, {0x77, 'hellpod', 7},
}
assert(#menu_shortcuts == #expected_shortcuts)
for index, expected in ipairs(expected_shortcuts) do
    assert(menu_shortcuts[index].key == expected[1] and
           (menu_shortcuts[index].presenter or
            (menu_shortcuts[index].arcade and 'arcade') or 'hellpod') == expected[2]
           and menu_shortcuts[index].slot == expected[3],
           'wrong ship menu shortcut ' .. index)
end
local fallback_calls = 0
for index = 1, 50 do
    local name = debug.getupvalue(shortcut_down, index)
    if name == 'key_down' then
        debug.setupvalue(shortcut_down, index, function(key)
            assert(key == 0x09, 'fallback must use Tab')
            fallback_calls = fallback_calls + 1
            return true
        end)
        break
    end
end
assert(shortcut_down(map_shortcut) == true and fallback_calls == 1,
       'missing host must use Tab')
local registrations, binding_down = {}, false
ModBindingsMenu = {
    register_binding = function(id, label, slot, options)
        assert(type(id) == 'string' and
               (type(label) == 'number' or type(label) == 'string') and
               slot >= 1 and slot <= 7)
        assert(options.category == 'Ship Station Hotkeys', 'MODS tab section name')
        registrations[id] = slot
        return true
    end,
    is_down = function(id)
        assert(id == 'cowboybingus.galactic_menu')
        return binding_down
    end,
}
assert(shortcut_down(map_shortcut) == false and fallback_calls == 1,
       'saved unpressed binding must suppress Tab')
binding_down = true
assert(shortcut_down(map_shortcut) == true and
       registrations['cowboybingus.galactic_menu'] == 1 and
       registrations['cowboybingus.hellpod'] == 7,
       'all saved bindings must register once')
binding_down = nil
assert(shortcut_down(map_shortcut) == true and fallback_calls == 2,
       'unavailable binding must retain fallback')
ModBindingsMenu = {register_binding = function() return false end, is_down = function() error('must not poll rejected slot') end}
assert(shortcut_down(map_shortcut) == true and fallback_calls == 3,
       'rejected registration must retain fallback')
ModBindingsMenu = nil
state.binding_host = nil
local activate = upvalue(step, 'activate')
local activate_arcade = upvalue(step, 'activate_arcade')
local arcade_context = upvalue(activate_arcade, 'arcade_context')
local arcade_nearby = upvalue(activate_arcade, 'arcade_nearby')
local initialize_native = upvalue(step, 'initialize_native')
local prefix = upvalue(initialize_native, 'PRESENTER_PREFIX')
local arcade_prefix = upvalue(initialize_native, 'ARCADE_PREFIX')
local seat_prefix = upvalue(initialize_native, 'INSTANT_SEAT_PREFIX')
local briefing_prefix = upvalue(initialize_native, 'BRIEFING_PREFIX')
local capture = os.getenv('HD2_GAME_CAPTURE')
if capture then
    local game = assert(io.open(capture, 'rb'))
    assert(game:seek('set', 0x14c0350))
    assert(game:read(#prefix) == prefix, 'presenter function changed from captured build')
    assert(game:seek('set', 0x997800))
    assert(game:read(#arcade_prefix) == arcade_prefix,
           'arcade interaction function changed from captured build')
    assert(game:seek('set', 0x639830))
    assert(game:read(#seat_prefix) == seat_prefix,
           'instant seat entry changed from captured build')
    assert(game:seek('set', 0x661cf0))
    assert(game:read(#briefing_prefix) == briefing_prefix,
           'Hellpod briefing entry changed from captured build')
    game:close()
end
local hash_module = upvalue(initialize_native, 'module_sha256')
local kernel32 = upvalue(hash_module, 'kernel32')
assert(#hash_module(kernel32.GetModuleHandleA(nil)) == 64,
       'native SHA-256 hashing failed')

local global_offset, presenter_offset = 0x347ce28, 17032
local module = ffi.new('GMH_u8[?]', global_offset + 24)
local ui = ffi.new('GMH_u8[?]', presenter_offset + 64)
local ui_address = ffi.cast('GMH_u64', ui)
ffi.copy(module + global_offset, ffi.new('GMH_u64[1]', ui_address), 8)
local presenter = ui + presenter_offset
local current = ffi.cast('GMH_u32 *', presenter + 12)
local depth = ffi.cast('GMH_u32 *', presenter + 40)
state.game_base = tonumber(ffi.cast('GMH_u64', module))
current[0], depth[0] = 0, 0

local calls = 0
state.open_presenter = function(manager, kind, data)
    assert(tonumber(ffi.cast('GMH_u64', manager)) ==
        tonumber(ffi.cast('GMH_u64', presenter)), 'wrong presenter manager')
    assert(data == nil, 'ship presenters must not receive interaction data')
    calls = calls + 1
    current[0], depth[0] = kind, 1
end
activate('Galactic Map', 15)
assert(calls == 1 and current[0] == 15, 'Tab did not enter Hologram presenter')
activate('Galactic Map', 15)
assert(calls == 1, 'already-open Hologram must not be reopened')
current[0], depth[0] = 2, 1
activate('Armory', 5)
assert(calls == 1, 'other menu must not be interrupted')
current[0], depth[0] = 1, 1
activate('Ship Management', 8)
assert(calls == 1, 'Main menu must not be interrupted')
current[0], depth[0] = 0, 1
activate('Control Center', 6)
assert(calls == 1, 'inconsistent menu stack must not be interrupted')
for _, shortcut in ipairs(menu_shortcuts) do
    if shortcut.presenter then
        current[0], depth[0] = 0, 0
        activate(shortcut.name, shortcut.presenter)
        assert(current[0] == shortcut.presenter, shortcut.name .. ' presenter did not open')
    end
end
assert(calls == 4, 'expected map and three ship menu presenter calls')
local activate_hellpod = upvalue(step, 'activate_hellpod')
local service_hellpod = upvalue(step, 'service_hellpod')
local service_hellpod_seat = upvalue(step, 'service_hellpod_seat')
local enter_hellpod = upvalue(activate_hellpod, 'enter_hellpod')
local function ptr(value) return ffi.new('GMH_u64[1]', ffi.cast('GMH_u64', value)) end
local function set32(buffer, offset, value) ffi.cast('GMH_u32 *', buffer + offset)[0] = value end
-- Replay the live solo ship layout: deployment slot 0 holds pod 60, which is
-- Hellpod index 0, and the avatar 232 is the only seater.
local pod_system = ffi.new('GMH_u8[72988]')
local pod_manager = ffi.new('GMH_u8[280]')
local pod = ffi.new('GMH_u8[24]')
ffi.copy(module + 0x33265f0, ptr(pod_system), 8)
ffi.copy(module + 0x3326428, ptr(pod_manager), 8)
set32(pod_system, 32, 1)
set32(pod_system, 36, 1)
set32(pod_system, 72984, 60)
set32(pod_manager, 8, 1)
ffi.copy(pod_manager + 104, ptr(pod), 8)
set32(pod, 8, 60)
pod[20] = 1
local function pod_state(mode, pod_current, pod_target)
    set32(pod_manager, 136, mode)
    set32(pod_manager, 184, pod_current)
    set32(pod_manager, 264, pod_target)
end
local seaters = ffi.new('GMH_u8[80]')
local seater_buckets = ffi.new('GMH_u8[64]')
local seater_entities = ffi.new('GMH_u64[1]')
local avatar_entity = ffi.new('GMH_u8[24]')
local seater_record = ffi.new('GMH_u8[64]')
ffi.copy(module + 0x3326d78, ptr(seaters), 8)
set32(seaters, 12, 1)
ffi.copy(seaters + 32, ptr(seater_buckets), 8)
set32(seaters, 40, 8)
set32(seaters, 48, 1)
set32(seater_buckets, 0, 232)
seater_entities[0] = ffi.cast('GMH_u64', avatar_entity)
ffi.copy(seaters + 56, ptr(seater_entities), 8)
ffi.copy(seaters + 72, ptr(seater_record), 8)
set32(avatar_entity, 8, 232)
local free_seater = upvalue(enter_hellpod, 'free_seater')
-- Screen stack with the loadout screen (type 11) object at +176.
local screen_stack = ffi.new('GMH_u8[184]')
local loadout = ffi.new('GMH_u8[2570640]')
ffi.copy(module + 0x347ce38, ptr(screen_stack), 8)
ffi.copy(screen_stack + 176, ptr(loadout), 8)
local intro_timer = ffi.cast('float *', loadout + 2570632)
local function show_loadout(phase, timer)
    set32(screen_stack, 0, 11)
    set32(loadout, 2570636, phase)
    intro_timer[0] = timer
end
local real_local_avatar
for index = 1, 50 do
    local name, value = debug.getupvalue(free_seater, index)
    if name == 'local_avatar' then
        real_local_avatar = value
        debug.setupvalue(free_seater, index, function() return 232, 2116 end)
        break
    end
end
assert(real_local_avatar, 'Hellpod entry must resolve the local avatar')
local briefings, seat_entries = 0, 0
state.open_briefing = function(context, slot)
    assert(context == nil and slot == 0, 'wrong Hellpod briefing request')
    briefings = briefings + 1
    current[0], depth[0] = 14, 1
end
state.enter_seat = function(context, entity, request)
    assert(context == nil, 'instant seat entry must not receive a context')
    assert(tonumber(ffi.cast('GMH_u64', entity)) ==
           tonumber(ffi.cast('GMH_u64', avatar_entity)), 'wrong seater entity')
    local bytes = ffi.cast('GMH_u8 *', request)
    assert(bytes[0] == 1, 'instant placement must be enabled')
    local placement = ffi.cast('GMH_u32 **', bytes + 72)[0]
    assert(placement[406] == 60 and placement[407] == 0 and placement[408] == 0,
           'wrong Hellpod placement')
    assert(current[0] == 14, 'seat must happen behind the open briefing')
    seat_entries = seat_entries + 1
    set32(seater_record, 0, 60)
end
local function reset_ship()
    current[0], depth[0] = 0, 0
    set32(seater_record, 0, 0)
    pod_state(2, 3, 3)
end
current[0], depth[0] = 0, 0
pod_state(0, 0, 0)
activate_hellpod()
assert(briefings == 0 and not state.hellpod_wait, 'F8 without a mission must not enter')
pod_state(2, 4, 4)
activate_hellpod()
assert(briefings == 0 and not state.hellpod_wait, 'occupied Hellpod must reject F8')
set32(pod_system, 32, 2)
pod_state(2, 3, 3)
activate_hellpod()
assert(briefings == 0, 'shared ship sessions must reject F8')
set32(pod_system, 32, 1)
current[0], depth[0] = 5, 1
activate_hellpod()
assert(briefings == 0, 'F8 must not interrupt another presenter')
current[0], depth[0] = 0, 0
activate_hellpod()
assert(briefings == 1 and seat_entries == 0 and state.hellpod_seat,
       'open Hellpod must show the briefing before seating')
show_loadout(0, -1)
service_hellpod_seat(0.1)
assert(seat_entries == 0, 'stale finished intro must not seat before the skip')
show_loadout(1, 2)
service_hellpod_seat(0.1)
assert(seat_entries == 0 and intro_timer[0] == 0,
       'briefing intro timer must be expired without seating')
service_hellpod_seat(0.1)
assert(seat_entries == 0, 'seat must wait for the briefing UI')
show_loadout(0, -1)
service_hellpod_seat(0.1)
assert(seat_entries == 1 and not state.hellpod_seat,
       'avatar must be seated on the frame the briefing UI appears')
set32(screen_stack, 0, 0)

current[0], depth[0] = 0, 0
activate_hellpod()
assert(briefings == 1, 'seated avatar must not open another briefing')
set32(seater_record, 0, 0)
seater_record[48] = 1
activate_hellpod()
assert(briefings == 1, 'moving seater must not open the briefing')
seater_record[48] = 0

activate_hellpod()
current[0], depth[0] = 0, 0
service_hellpod_seat(1)
assert(briefings == 2 and seat_entries == 1 and not state.hellpod_seat,
       'closing the briefing must cancel the pending seat')
current[0], depth[0] = 14, 1
state.hellpod_seat = {pod = 60, delay = 0}
pod_state(0, 0, 0)
service_hellpod_seat(0)
assert(seat_entries == 1 and not state.hellpod_seat,
       'cleared mission must skip the pending seat')

reset_ship()
pod_state(2, 1, 1)
activate_hellpod()
assert(briefings == 2 and state.hellpod_wait == 10,
       'F8 during the ready animation must wait for the Hellpod')
service_hellpod(4)
assert(briefings == 2 and state.hellpod_wait == 6, 'closed Hellpod must keep waiting')
pod_state(2, 3, 3)
service_hellpod(0.5)
service_hellpod_seat(2)
assert(seat_entries == 1, 'fallback seat must wait for the delay')
service_hellpod_seat(1)
assert(briefings == 3 and seat_entries == 2 and not state.hellpod_wait,
       'waiting shortcut must enter once the Hellpod opens')

reset_ship()
pod_state(2, 1, 1)
activate_hellpod()
service_hellpod(11)
assert(briefings == 3 and not state.hellpod_wait, 'expired wait must cancel')
activate_hellpod()
current[0], depth[0] = 15, 1
service_hellpod(0)
assert(briefings == 3 and not state.hellpod_wait, 'opening a menu must cancel the wait')
current[0], depth[0] = 0, 0
activate_hellpod()
pod_state(0, 0, 0)
service_hellpod(0)
assert(briefings == 3 and not state.hellpod_wait,
       'cancelled mission must cancel the wait')
for index = 1, 50 do
    if debug.getupvalue(free_seater, index) == 'local_avatar' then
        debug.setupvalue(free_seater, index, real_local_avatar)
        break
    end
end
local arcade_pool = ffi.new('GMH_u8[5232]')
local arcade_system = ffi.new('GMH_u8[8]')
local pool_address = tonumber(ffi.cast('GMH_u64', arcade_pool))
local system_address = tonumber(ffi.cast('GMH_u64', arcade_system))
local cabinet_position = ffi.new('float[3]', {0, 0, 0})
local avatar_position = ffi.new('float[3]', {10, 0, 0})
state.unit_position = function(unit)
    if unit == 1020 then return tonumber(ffi.cast('GMH_u64', cabinet_position)) end
    if unit == 2116 then return tonumber(ffi.cast('GMH_u64', avatar_position)) end
    return 0
end
local started = 0
for index = 1, 50 do
    local name = debug.getupvalue(activate_arcade, index)
    if name == 'arcade_context' then
        debug.setupvalue(activate_arcade, index, function()
            return system_address, 70, 232, pool_address, 1020, 2116
        end)
        break
    end
end
state.start_arcade = function(system, data, entity, avatar)
    assert(tonumber(ffi.cast('GMH_u64', system)) == system_address and
           data == nil and entity == 70 and avatar == 232,
           'wrong arcade interaction request')
    started = started + 1
    ffi.cast('GMH_u32 *', arcade_pool + 5208)[0] = avatar
end
current[0], depth[0] = 2, 1
activate_arcade()
assert(started == 0, 'arcade must not interrupt another presenter')
current[0], depth[0] = 0, 0
activate_arcade()
assert(started == 0, 'distant F7 must not enter arcade')
avatar_position[0] = 1
activate_arcade()
assert(started == 1 and ffi.cast('GMH_u32 *', arcade_pool + 5208)[0] == 232,
       'nearby F7 did not start native arcade interaction')
state.unit_position = nil
assert(not arcade_nearby(1020, 2116), 'missing position function must fail closed')

-- Replay the cabinet, ECS and local-avatar layout observed in the live ship.
-- In the idle state field 5208 is zero. Field 5212 can retain the previous
-- player ID. This guard must accept idle and reject active play.
local addresses = {
    base = 0x100000, cabinet = 0x200000, buckets = 0x210000,
    pool = 0x220000, systems = 0x230000, arcade_system = 0x240000,
    players = 0x250000, player = 0x260000, entities = 0x270000,
    entity_map = 0x280000,
}
local memory = {}
local function put(address, blob)
    memory[address .. ':' .. #blob] = blob
end
local function value32(value)
    return ffi.string(ffi.new('GMH_u32[1]', value), 4)
end
local function value64(value)
    return ffi.string(ffi.new('GMH_u64[1]', value), 8)
end
local function record(size, fields)
    local bytes = ffi.new('GMH_u8[?]', size)
    for _, field in ipairs(fields) do
        ffi.copy(bytes + field[1], field[2], #field[2])
    end
    return ffi.string(bytes, size)
end
put(addresses.base + 0x3326700, value64(addresses.cabinet))
put(addresses.cabinet + 24, value32(1))
put(addresses.cabinet + 48, value64(addresses.buckets))
put(addresses.cabinet + 56, value32(128))
put(addresses.cabinet + 60, value32(0))
put(addresses.cabinet + 88, value64(addresses.pool))
put(addresses.buckets, record(128 * 8, {{12 * 8, value32(70)}}))
put(addresses.pool + 5208, value32(0))
put(addresses.pool + 5212, value32(232))
put(addresses.base + 0x3326e68, value64(addresses.systems))
put(addresses.systems + 19512, value32(1))
put(addresses.systems + 19520, record(16,
    {{0, value64(addresses.arcade_system)}, {8, value32(67)}}))
put(addresses.base + 0x3326468, value64(addresses.players))
put(addresses.players + 0x84, value32(1))
put(addresses.players + 0x88, value32(1))
put(addresses.players + 0xe8, value64(addresses.player))
put(addresses.player, record(24, {{20, '\1'}}))
put(addresses.players + 0x3a8, value32(154))
put(addresses.base + 0x346bf98, value64(addresses.entities))
put(addresses.entities + 0xf22ec8, record(20,
    {{0, value64(addresses.entity_map)}, {8, value32(8)},
     {12, value32(0)}, {16, value32(1)}}))
put(addresses.entity_map + 2 * 8, value32(154) .. value32(0))
put(addresses.entity_map + 6 * 8, value32(70) .. value32(1))
put(addresses.entities + 0xf32f18, record(24,
    {{0, '\x97\xfa\x4d\x29\x4d\x33\x1c\x4d'},
     {8, value32(232)}, {12, value32(2116)}, {20, '\1'}}))
put(addresses.entities + 0xf32f18 + 24, record(24,
    {{8, value32(118)}, {12, value32(1020)}, {20, '\1'}}))
for index = 1, 50 do
    local name = debug.getupvalue(arcade_context, index)
    if name == 'read' then
        debug.setupvalue(arcade_context, index, function(address, size)
            return memory[address .. ':' .. size]
        end)
        break
    end
end
state.game_base = addresses.base
local system, arcade_id, avatar_id, _, cabinet_unit, avatar_unit = arcade_context()
assert(system == addresses.arcade_system and arcade_id == 70 and avatar_id == 232
       and cabinet_unit == 1020 and avatar_unit == 2116,
       'idle cabinet must resolve the local arcade interaction')
put(addresses.pool + 5208, value32(232))
assert(arcade_context() == nil, 'active arcade must reject a second start')
for _, message in ipairs(messages) do
    assert(not message:find('Update error:', 1, true), message)
end
print('Native ship menu dispatch, menu guards and saved map binding integration OK')
