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
-- The build puts the text module and the locales ahead of the main file as
-- the local ssh_text; here it is a global.
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local Text = dofile(root .. '/src/bingus_text.lua')
_G.BingusTranslations = nil
Text.registry().steam_language = 'en'
local ENGLISH = dofile(root .. '/locales/en.lua')
_G.ssh_text = {module = Text, locales = {en = ENGLISH, bundled = {}}}
-- Bingus Shared Runtime's files, which the build places ahead of the main file
-- as the functions of the local ssh_runtime; here they are loaded from src/.
_G.ssh_runtime = {core = assert(loadfile(root .. '/src/bingus_runtime.lua')),
                  memory = assert(loadfile(root .. '/src/bingus_memory.lua'))}
-- The game's update, which the shortcuts' guard wraps.
_G.update = function() end
dofile(source)

-- The function holding the upvalue wanted, searched from fn through every
-- function it reaches, with the upvalue's index and value.
local function holder(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 60 do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == wanted then return fn, index, value end
        if type(value) == 'function' then nested[#nested + 1] = value end
    end
    for _, inner in ipairs(nested) do
        local found, index, value = holder(inner, wanted, seen)
        if found then return found, index, value end
    end
    return nil
end
-- An upvalue of fn or of a helper it calls (the step is split into helpers).
local function upvalue(fn, wanted)
    local found, _, value = holder(fn, wanted)
    if not found then error('missing upvalue ' .. wanted) end
    return value
end

local step = upvalue(update, 'step')
local state = upvalue(step, 'state')
local shortcut_down = upvalue(step, 'shortcut_down')
local binding_host = upvalue(step, 'binding_host')
-- Every shortcut in polling order: the map first, then the ship menus.
local shortcuts = upvalue(step, 'SHORTCUTS')
local map_shortcut, menu_shortcuts = shortcuts[1], {unpack(shortcuts, 2)}
assert(map_shortcut.key == 0x09 and map_shortcut.presenter == 15 and map_shortcut.slot == 1, 'the map shortcut')
-- One frame's Mod Bindings Menu check, then the map shortcut polled as a frame does.
local function poll_map() return shortcut_down(map_shortcut, binding_host()) end
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
assert(poll_map() == true and fallback_calls == 1,
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
assert(poll_map() == false and fallback_calls == 1,
       'saved unpressed binding must suppress Tab')
binding_down = true
assert(poll_map() == true and
       registrations['cowboybingus.galactic_menu'] == 1 and
       registrations['cowboybingus.hellpod'] == 7,
       'all saved bindings must register once')
binding_down = nil
assert(poll_map() == true and fallback_calls == 2,
       'unavailable binding must retain fallback')
ModBindingsMenu = {register_binding = function() return false end, is_down = function() error('must not poll rejected slot') end}
assert(poll_map() == true and fallback_calls == 3,
       'rejected registration must retain fallback')
ModBindingsMenu = nil
state.binding_host, state.binding_retry = nil, false
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
-- Module hashes come from Bingus Shared Runtime's session cache: each module
-- file is read once per session for every mod.
local memory = upvalue(initialize_native, 'memory')
local reads = BingusRuntime.hash_reads
assert(#memory.module_hash(memory.module(nil)) == 64 and BingusRuntime.hash_reads == reads + 1,
       'native SHA-256 hashing failed')
assert(#memory.module_hash(memory.module(nil)) == 64 and BingusRuntime.hash_reads == reads + 1, 'hashed once')
-- The window prototypes against the real user32: the foreground window's
-- handle, a 32-bit number, finds its process (skipped without a desktop).
do
    local user32 = upvalue(update, 'user32')
    local window, process = user32.GMH_GetForegroundWindow(), ffi.new('GMH_u32[1]')
    assert(type(window) == 'number', 'window handles are plain numbers')
    if window ~= 0 then
        assert(user32.GMH_GetWindowThreadProcessId(window, process) ~= 0 and process[0] ~= 0,
               'the foreground window handle must find its process')
    end
end

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

-- Translations: with Mod Bindings Menu version 3 the section and the two text
-- labels are functions (the same function on every registration) that follow
-- the game's language; the game's own IDs stay numbers.
do
    local zh_section, zh_control = Text.encode(0x8230) .. Text.encode(0x822a), Text.encode(0x63a7) .. Text.encode(0x5236)
    Text.register({language = 'zh-Hans', name = 'test', mods = {ship_station_hotkeys = {
        ['binding.section'] = zh_section, ['binding.control_center'] = zh_control}}})
    local seen = {}
    ModBindingsMenu = {
        version = 3,
        register_binding = function(id, label, slot, options)
            assert(type(options.category) == 'function' and (type(label) == 'number' or type(label) == 'function'))
            seen[id] = {label = label, category = options.category}
            return true
        end,
        is_down = function() return false end,
    }
    poll_map()
    local control, hero = seen['cowboybingus.control_center'], seen['cowboybingus.stratagem_hero']
    assert(control.category() == 'Ship Station Hotkeys' and control.label() == 'CONTROL CENTER')
    assert(seen['cowboybingus.armory'].label == 0x19e97f02, 'the game translates its own names')
    Text.registry().game_language = 'zh-Hans'
    assert(control.category() == zh_section and control.label() == zh_control, 'the functions follow the language')
    assert(hero.label() == 'STRATAGEM HERO', 'untranslated texts stay English')
    assert(control.category == hero.category, 'one function per text')
    -- Version 2: strings in the current language, English when over its byte limits.
    Text.registry().game_language = 'en'
    local strings = {}
    ModBindingsMenu = {
        version = 2,
        register_binding = function(id, label, slot, options)
            assert(type(options.category) == 'string')
            strings[id] = label
            return true
        end,
        is_down = function() return false end,
    }
    poll_map()
    assert(strings['cowboybingus.control_center'] == 'CONTROL CENTER')
end
print('Translations: binding names as functions for Mod Bindings Menu v2.1, strings for v2.0 OK')

-- Step errors and the update chain, through Bingus Shared Runtime's guard, on
-- fresh instances chained after a previous update (outside a ship, so the real
-- step returns early, unless a test puts the instance aboard). The step's errors
-- count in bursts: 8 errors with fewer than 3600 error-free frames between each
-- and the next stop the step for the session (no log line and no allocation per
-- frame after), and 3600 error-free frames start a count again. A burst gets
-- one log line and a stop one more; no traceback is ever built. An error in the
-- update below reaches the caller unchanged and pauses the shortcuts on the next
-- frame: every shortcut counts as held until it is released, so a key held
-- through the pause needs a fresh press; a pending Hellpod wait is cancelled;
-- the context is read again. The step resumes once the update below has
-- returned on 60 frames in a row, and the 8th such error in a burst stops it.
-- Every argument and every return value pass through to the previous update,
-- error or not; the first failure survives shutdown.
do
    local function set_upvalue(fn, wanted, value)
        for index = 1, 50 do
            local name = debug.getupvalue(fn, index)
            if not name then break end
            if name == wanted then debug.setupvalue(fn, index, value); return end
        end
        error('missing upvalue ' .. wanted)
    end
    local tracebacks, recording, passed = 0, true, {}
    local real_traceback = debug.traceback
    debug.traceback = function(...) tracebacks = tracebacks + 1; return real_traceback(...) end
    -- The update below: returns 1, nil, 3, or raises while below.fail is set.
    local below, shutdowns = {fail = false}, 0
    local function previous(...)
        if recording then passed[#passed + 1] = {n = select('#', ...), ...} end
        if below.fail then error('the update below failed', 0) end
        return 1, nil, 3
    end
    local function previous_shutdown() shutdowns = shutdowns + 1 end
    local function pack(...) return {n = select('#', ...), ...} end
    local function count(text, from)
        local found = 0
        for index = from, #messages do
            if messages[index]:find(text, 1, true) then found = found + 1 end
        end
        return found
    end
    local function frames(wrapper, n)
        for _ = 1, n do
            local results = pack(wrapper(0.016, 'marker', nil))
            local got = passed[#passed]
            assert(got.n == 3 and got[1] == 0.016 and got[2] == 'marker', 'arguments pass through')
            assert(results.n == 3 and results[1] == 1 and results[2] == nil and results[3] == 3, 'results pass through')
            passed[#passed] = nil
        end
    end
    -- A frame whose update below raises: the error reaches the caller unchanged.
    local function failing_frame(wrapper)
        below.fail = true
        local ok, problem = pcall(wrapper, 0.016, 'marker', nil)
        below.fail = false
        assert(not ok and problem == 'the update below failed', 'the error below passes unchanged')
        passed[#passed] = nil
    end
    ModBindingsMenu = nil
    local function fresh()
        _G.GalacticMenuHotkeyInstalled, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
        Text.registry().steam_language = 'en'
        _G.update, _G.shutdown = previous, previous_shutdown
        dofile(source)
        return upvalue(update, 'state'), update, BingusRuntime.statuses.ShipStationHotkeys, shutdown
    end
    -- The step raises on the calls failing(call) names and otherwise runs as usual.
    local function scripted(wrapper, failing)
        local real_step, script = upvalue(wrapper, 'step'), {calls = 0}
        set_upvalue(wrapper, 'step', function(dt)
            script.calls = script.calls + 1
            if failing(script.calls) then error('scripted failure at call ' .. script.calls .. '.', 0) end
            return real_step(dt)
        end)
        return script
    end

    -- A burst that ends with fewer than 8 errors leaves the step running; the
    -- 8th error with fewer than 3600 error-free frames between stops it.
    local _, update6, status6 = fresh()
    local script6 = scripted(update6, function(call) return (call >= 2 and call <= 4) or (call >= 7 and call <= 11) end)
    local from = #messages + 1
    frames(update6, 6)
    assert(script6.calls == 6 and status6.errors == 3 and status6.state == 'running', 'a step that recovers keeps running')
    assert(count('ShipStationHotkeys error: ', from) == 1 and count('stopped', from) == 0, 'one log line per burst')
    frames(update6, 5)
    local stop_lines = #messages
    frames(update6, 5)
    assert(script6.calls == 11 and status6.errors == 8, 'the 8th error of a burst stops the step')
    assert(status6.state == 'stopped: stopped after 8 errors: scripted failure at call 2.', status6.state)
    assert(#messages == stop_lines and count('ShipStationHotkeys error: ', from) == 1 and count('stopped', from) == 1)
    assert(messages[stop_lines] == 'ShipStationHotkeys stopped: stopped after 8 errors: scripted failure at call 2.\n',
           'the stop line names the burst\'s first error')

    -- Bursts 3600 error-free frames apart never add up: 7 errors, 3600 clean
    -- frames, 7 errors again keep the step running with a log line each;
    -- then 3599 clean frames are not enough and the next error is the 8th.
    local _, update8, status8 = fresh()
    local script8 = scripted(update8, function(call)
        return call <= 7 or (call >= 3608 and call <= 3614) or call == 7214
    end)
    from = #messages + 1
    frames(update8, 7)
    assert(status8.errors == 7 and count('ShipStationHotkeys error: ', from) == 1, 'a burst of 7')
    frames(update8, 3599)
    assert(status8.errors == 7, '3599 error-free frames do not end a burst')
    frames(update8, 1)
    assert(status8.errors == 0 and status8.state == 'running', '3600 error-free frames end it')
    frames(update8, 7)
    assert(status8.errors == 7 and status8.state == 'running' and count('ShipStationHotkeys error: ', from) == 2
           and count('at call 3608.', from) == 1, 'a new burst gets its own log line')
    frames(update8, 3599 + 1)
    assert(script8.calls == 7214 and status8.state:find('^stopped') and count('stopped', from) == 1
           and messages[#messages]:find('at call 3608.', 1, true), 'the 8th error of the second burst stops the step')
    frames(update8, 10)
    assert(script8.calls == 7214, 'a stopped step stays stopped')

    -- A step that always raises runs 8 times; a stopped frame only passes on.
    local _, update7, status7 = fresh()
    local script7 = scripted(update7, function() return true end)
    from = #messages + 1
    frames(update7, 8)
    stop_lines = #messages
    frames(update7, 12)
    assert(script7.calls == 8 and status7.errors == 8 and status7.state:find('^stopped'), 'the 8th error stops the step')
    assert(#messages == stop_lines and count('ShipStationHotkeys error: ', from) == 1 and count('stopped', from) == 1)
    assert(messages[stop_lines]:find('at call 1.', 1, true), 'the stop line names the first error')
    -- No allocation once stopped (interpreted, so that compiled-trace
    -- allocation sinking cannot hide garbage).
    recording = false
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 200 do update7(0.016, 'marker') end
    local garbage = (collectgarbage('count') - before) * 1024
    collectgarbage('restart')
    jit.on()
    recording = true
    assert(garbage == 0, string.format('stopped frames allocated %d bytes', garbage))
    assert(script7.calls == 8 and #messages == stop_lines and tracebacks == 0, 'pcall builds no traceback')

    -- Aboard, focused, with the fixed keys (no Mod Bindings Menu). Tab held
    -- opens the map; an error below pauses the shortcuts with Tab still held
    -- and an F8 wait pending: the wait is cancelled, and Tab, held through the
    -- pause, does not act when the step resumes 60 clean frames later. Released
    -- and pressed again, it acts.
    local SHIP_WORLD = {}
    _G.stingray = {
        Application = {main_world = function() return SHIP_WORLD end, worlds = function() return {SHIP_WORLD} end},
        World = {units_by_resource = function(world) return world == SHIP_WORLD and {1} or {} end},
        IdString64 = {from_hex = function() return 'galaxy table resource' end},
    }
    local st9, update9, status9, shutdown9 = fresh()
    st9.initialized = true -- the native layer is the test's own (st9.open_presenter below)
    local keys, opened = {}, {}
    local user32_holder, user32_index, real_user32 = holder(update9, 'user32')
    local process_id9 = upvalue(update9, 'process_id')
    debug.setupvalue(user32_holder, user32_index, setmetatable({
        GMH_GetForegroundWindow = function() return 0x1234 end,
        GMH_GetWindowThreadProcessId = function(_, process) process[0] = process_id9; return 1 end,
        GMH_GetAsyncKeyState = function(key) return keys[key] and -32768 or 0 end,
    }, {__index = real_user32}))
    st9.game_base = tonumber(ffi.cast('GMH_u64', module))
    st9.open_presenter = function(_, kind)
        opened[#opened + 1] = kind
        current[0], depth[0] = kind, 1
    end
    current[0], depth[0] = 0, 0
    local script9 = scripted(update9, function() return false end)
    keys[0x09] = true
    frames(update9, 1)
    assert(st9.world == SHIP_WORLD and st9.focused and #opened == 1 and opened[1] == 15, 'Tab opens the map')
    current[0], depth[0] = 0, 0
    frames(update9, 3)
    assert(#opened == 1, 'held, Tab does not act again')
    from = #messages + 1
    failing_frame(update9)
    st9.hellpod_wait = 10
    local calls = script9.calls
    frames(update9, 1)
    assert(status9.state == 'paused: the previous update failed' and status9.pauses == 1, status9.state)
    assert(script9.calls == calls and st9.hellpod_wait == nil and st9.context_frames == 0, 'the pause resets')
    for _, shortcut in ipairs(shortcuts) do assert(st9.keys_down[shortcut.id] == true, shortcut.id .. ' held') end
    assert(count('ShipStationHotkeys paused: the previous update failed', from) == 1
           and count('Hellpod shortcut cancelled; the update paused.', from) == 1)
    -- No allocation per paused frame (interpreted).
    recording = false
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')
    before = collectgarbage('count')
    for _ = 1, 58 do update9(0.016, 'marker') end
    garbage = (collectgarbage('count') - before) * 1024
    collectgarbage('restart')
    jit.on()
    recording = true
    assert(garbage == 0, string.format('paused frames allocated %d bytes', garbage))
    frames(update9, 1)
    assert(script9.calls == calls and count('resumed', from) == 0, 'paused for 60 frames')
    frames(update9, 1)
    assert(script9.calls == calls + 1 and status9.state == 'running', 'the step resumes on the 61st frame')
    assert(count('ShipStationHotkeys resumed after 60 clean frames', from) == 1)
    assert(#opened == 1, 'Tab held through the pause does not act')
    keys[0x09] = nil
    frames(update9, 1)
    keys[0x09] = true
    frames(update9, 1)
    assert(#opened == 2 and opened[2] == 15, 'a fresh press acts')
    keys[0x09] = nil
    current[0], depth[0] = 0, 0
    -- Errors below 61 frames apart each pause and resume; the 8th of a burst
    -- stops the shortcuts. The game's shutdown keeps the first failure.
    from = #messages + 1
    for pause = 2, 7 do
        failing_frame(update9)
        frames(update9, 61)
        assert(status9.state == 'running' and status9.pauses == pause, 'pause ' .. pause .. ' resumed')
    end
    failing_frame(update9)
    frames(update9, 1)
    assert(status9.state == 'stopped: stopped after 8 failed updates below this mod', status9.state)
    assert(messages[#messages] == 'ShipStationHotkeys stopped: stopped after 8 failed updates below this mod\n')
    assert(status9.lower_errors == 8 and status9.errors == 0)
    shutdown9('closing')
    assert(shutdowns == 1 and status9.state == 'stopped after: stopped after 8 failed updates below this mod')
    _G.stingray = nil
    -- A running instance at shutdown: the status says stopped; the shutdown below runs.
    local _, update10, status10, shutdown10 = fresh()
    frames(update10, 2)
    shutdown10()
    assert(shutdowns == 2 and status10.state == 'stopped', status10.state)
    frames(update10, 2)
    debug.traceback = real_traceback
    _G.shutdown = nil
end
print('Update errors, through the runtime guard: 8 errors less than 3600 error-free frames apart stop the step, '
      .. 'bursts further apart never add up, one log line per burst, no log line or allocation per frame once '
      .. 'stopped; an error below pauses the shortcuts (a key held through the pause needs a fresh press, a Hellpod '
      .. 'wait is cancelled, no allocation per paused frame) until 60 clean frames, and 8 errors below stop them; '
      .. 'shutdown keeps the first failure; every argument and return value pass through OK')

-- An unsupported game build: the test process's own executable stands in for
-- game.dll, so the real build check hashes the module files and finds no
-- match. On the frame the ship is first found the native check stops the
-- update for the session, the family's refusal: BingusRuntime.statuses shows
-- "stopped: unsupported game build" and the log has that one stop line. That
-- frame ends there, aboard no ship: no focus check, no key read and no action,
-- though Tab is held. No step runs afterwards: no engine, window or key call and
-- no log line per frame. In a plain test process, without game.dll, the reason
-- is "game modules unavailable".
do
    local SHIP_WORLD, engine_calls, user32_calls = {}, 0, 0
    _G.stingray = {
        Application = {
            main_world = function() engine_calls = engine_calls + 1; return SHIP_WORLD end,
            worlds = function() engine_calls = engine_calls + 1; return {SHIP_WORLD} end,
        },
        World = {units_by_resource = function(world)
            engine_calls = engine_calls + 1
            return world == SHIP_WORLD and {1} or {}
        end},
        IdString64 = {from_hex = function() engine_calls = engine_calls + 1; return 'galaxy table resource' end},
    }
    ModBindingsMenu = nil
    local function fresh()
        _G.GalacticMenuHotkeyInstalled, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
        Text.registry().steam_language = 'en'
        _G.update = function() end
        dofile(source)
        return update, BingusRuntime.statuses.ShipStationHotkeys
    end
    local function stop_lines(from)
        local found = {}
        for index = from, #messages do
            if messages[index]:find('stopped', 1, true) then found[#found + 1] = messages[index] end
        end
        return found
    end
    local wrapper, status = fresh()
    -- The step's runs, and the window and key calls, counted; Tab is held.
    local steps = 0
    local step_holder, step_index, real_step = holder(wrapper, 'step')
    debug.setupvalue(step_holder, step_index, function(...)
        steps = steps + 1
        return real_step(...)
    end)
    local process_id = upvalue(wrapper, 'process_id')
    local user32_holder, user32_index, real_user32 = holder(wrapper, 'user32')
    debug.setupvalue(user32_holder, user32_index, setmetatable({
        GMH_GetForegroundWindow = function() user32_calls = user32_calls + 1; return 0x1234 end,
        GMH_GetWindowThreadProcessId = function(_, process)
            user32_calls = user32_calls + 1
            process[0] = process_id
            return 1
        end,
        GMH_GetAsyncKeyState = function(key) user32_calls = user32_calls + 1; return key == 0x09 and -32768 or 0 end,
    }, {__index = real_user32}))
    local memory = upvalue(wrapper, 'memory')
    local module = memory.module
    memory.module = function() return module(nil) end
    local from = #messages + 1
    wrapper(0.016)
    memory.module = module
    local stops = stop_lines(from)
    assert(status.state == 'stopped: unsupported game build' and status.errors == 0, status.state)
    assert(#stops == 1 and stops[1] == 'ShipStationHotkeys stopped: unsupported game build\n'
           and messages[#messages] == stops[1], 'one stop line, the frame\'s last')
    assert(steps == 1 and engine_calls > 0 and user32_calls == 0, 'the frame ends at the refusal: no focus or key call')
    for index = from, #messages do
        assert(not messages[index]:find('shortcut detected', 1, true), messages[index])
    end
    local lines, engine = #messages, engine_calls
    for _ = 1, 30 do wrapper(0.016) end
    assert(steps == 1 and engine_calls == engine and user32_calls == 0 and #messages == lines,
           'no step, engine, window or key call, or log line after the refusal')
    -- Without game.dll.
    local plain, plain_status = fresh()
    from = #messages + 1
    plain(0.016)
    stops = stop_lines(from)
    assert(plain_status.state == 'stopped: game modules unavailable' and #stops == 1
           and stops[1] == 'ShipStationHotkeys stopped: game modules unavailable\n', plain_status.state)
    _G.stingray = nil
end
print('An unsupported game build stops the update, the guard\'s refusal: one stop line, that frame ends without a '
      .. 'focus or key call, and no step, call or log line afterwards OK')

-- Registration with Mod Bindings Menu, on fresh instances outside a ship (a
-- frame checks the bindings and, every 15 frames, the context), with stand-ins
-- for its v2.1 API: version 3, register_binding returning true, or false and a
-- reason, and is_down. A registration that failed keeps the fixed key and is
-- tried again at most 8 times per table: 60 frames after the first try, then
-- twice as long after each further one, or sooner once the table's revision
-- changes, but never within 60 frames of the last try. While every shortcut is
-- registered, and once the tries are used up, a frame makes no registration
-- call and reads no revision. Every frame's calls are pinned with
-- tests/frame_budget.lua.
do
    local budget = dofile((arg[0]:match('^(.*[/\\])') or './') .. 'frame_budget.lua')
    local frame_no = 0
    -- answer(id, try) answers each registration; reads of the revision field
    -- (host.current_revision, nil as in v2.1) are counted.
    local function stand_in(answer, revision)
        local host = {version = 3, tries = {}, revision_reads = 0, current_revision = revision}
        local api = {
            register_binding = function(id)
                host.tries[id] = (host.tries[id] or 0) + 1
                return answer(id, host.tries[id])
            end,
            is_down = function() return false end,
        }
        host.counts = budget.wrap(api)
        host.register_binding, host.is_down = api.register_binding, api.is_down
        return setmetatable(host, {__index = function(_, key)
            if key == 'revision' then
                host.revision_reads = host.revision_reads + 1
                return host.current_revision
            end
        end})
    end
    local function fresh(host)
        _G.GalacticMenuHotkeyInstalled, _G.BingusTranslations, _G.stingray, _G.BingusRuntime = nil, nil, nil, nil
        Text.registry().steam_language = 'en'
        _G.ModBindingsMenu = host
        _G.update = function() end
        dofile(source)
        frame_no = 0
        return upvalue(update, 'state'), update
    end
    -- Runs frames; each makes exactly the registrations expected[frame] (none
    -- when absent) and no other call.
    local function run(wrapper, host, frames, expected)
        for _ = 1, frames do
            frame_no = frame_no + 1
            local counts = budget.frame(host.counts, wrapper, 1 / 64)
            local want = expected[frame_no]
            budget.check(counts, want and {register_binding = want} or {}, 'registration frame ' .. frame_no)
            assert((counts.register_binding or 0) == (want or 0),
                   'frame ' .. frame_no .. ': ' .. budget.describe(counts))
        end
    end
    local function count(text, from)
        local found = 0
        for index = from, #messages do
            if messages[index]:find(text, 1, true) then found = found + 1 end
        end
        return found
    end
    local ARMORY, CONTROL, HELLPOD = 'cowboybingus.armory', 'cowboybingus.control_center', 'cowboybingus.hellpod'
    local first_line = #messages + 1
    local from = first_line

    -- Refused once (another addon held the slot, say): tried again 60 frames
    -- later; once all six are in, nothing more, not even a revision read.
    local host = stand_in(function(id, try)
        if id == ARMORY and try == 1 then return false, 'slot already in use' end
        return true
    end)
    local st, wrapper = fresh(host)
    run(wrapper, host, 20000, {[1] = 6, [61] = 1})
    assert(st.binding_slots[ARMORY] and not st.binding_retry and host.revision_reads == 2, 'registered after one retry')
    assert(count('Mod binding registration failed for Armory: slot already in use', from) == 1
           and count('Using Mod Bindings Menu slot 3 for Armory (try 2).', from) == 1, 'one line each')

    -- Always refused: 8 more tries, 60, 120, 240, ... frames apart, one line
    -- when they are used up, then nothing; the fixed key stays in use.
    host = stand_in(function(id)
        if id == HELLPOD then return false, 'all 36 binding actions in use' end
        return true
    end)
    st, wrapper = fresh(host)
    from = #messages + 1
    run(wrapper, host, 30000, {[1] = 6, [61] = 1, [181] = 1, [421] = 1, [901] = 1, [1861] = 1, [3781] = 1,
                               [7621] = 1, [15301] = 1})
    assert(not st.binding_slots[HELLPOD] and not st.binding_retry, 'bounded tries')
    -- The revision is read at each try and, while a try is pending, on each
    -- frame from 60 frames after the last one; never once the tries are used up.
    local reads = 9
    for retry = 0, 7 do reads = reads + 60 * 2 ^ retry - 60 end
    assert(host.revision_reads == reads, 'revision reads ' .. host.revision_reads .. ', expected ' .. reads)
    run(wrapper, host, 10000, {})
    assert(host.revision_reads == reads, 'no revision read once the tries are used up')
    assert(count('Mod binding registration failed for Hellpod Deployment', from) == 1
           and count('Mod binding registration still failing after 8 retries for Hellpod Deployment;', from) == 1
           and count('Hellpod Deployment (try', from) == 0, 'a failure line and a final line')
    -- A new Mod Bindings Menu table registers all six again; the same table
    -- back after an absence does not.
    local replacement = stand_in(function() return true end)
    _G.ModBindingsMenu = replacement
    run(wrapper, replacement, 100, {[40001] = 6})
    assert(st.binding_host == replacement and st.binding_slots[HELLPOD] and not st.binding_retry, 'a new table')
    _G.ModBindingsMenu = nil
    run(wrapper, replacement, 30, {})
    _G.ModBindingsMenu = replacement
    run(wrapper, replacement, 30, {})
    -- Not a table: the fixed keys, no error.
    _G.ModBindingsMenu = true
    run(wrapper, replacement, 30, {})

    -- A revision change brings the next try forward, but never within 60
    -- frames of the last: changed before frame 71, tried at 121 (not 71, and
    -- not 181 as timed); changed again before frame 200, tried at once.
    local open = false
    host = stand_in(function(id)
        if id == ARMORY and not open then return false, 'slot already in use' end
        return true
    end, 1)
    st, wrapper = fresh(host)
    run(wrapper, host, 70, {[1] = 6, [61] = 1})
    host.current_revision = 2
    run(wrapper, host, 129, {[121] = 1})
    open, host.current_revision = true, 3
    run(wrapper, host, 1000, {[200] = 1})
    assert(st.binding_slots[ARMORY] and not st.binding_retry, 'registered after the revision changed')

    -- A registration that raises is tried again too, and the others register
    -- on the same frame.
    host = stand_in(function(id, try)
        if id == CONTROL and try == 1 then error('registry busy', 0) end
        return true
    end)
    st, wrapper = fresh(host)
    from = #messages + 1
    run(wrapper, host, 100, {[1] = 6, [61] = 1})
    assert(st.binding_slots[CONTROL] and st.binding_slots[ARMORY] and not st.binding_retry, 'retried after an error')
    assert(count('Mod binding registration failed for Control Center: registry busy', from) == 1)

    for index = first_line, #messages do
        assert(not messages[index]:find('Update error', 1, true), messages[index])
    end
    _G.ModBindingsMenu = nil
end
print('Mod Bindings Menu registration: a refused or failing registration is tried again at most 8 times, 60 frames '
      .. 'after the last try and doubling, sooner after a revision change but never within 60 frames; nothing per '
      .. 'frame once registered or out of tries; a new table registers again OK')

-- Registration once every mod has started: with Bingus Shared Loader v19's
-- after_startup (feature-tested through loader.capabilities.after_startup) the
-- six shortcuts register in the callback, before the first frame, and the first
-- frame makes no registration call. Mod Bindings Menu's native input is not
-- ready then: is_down answers nil and the fixed keys stay in use until it
-- answers. A registration refused in the callback is tried again on the
-- bounded schedule (60 frames after the try); with Mod Bindings Menu absent the
-- callback registers nothing and a menu found later registers on that frame; a
-- callback the loader runs at once (startup over) registers at once. Without the
-- capability (loader v18, whatever its version field) or when after_startup
-- refuses (logged), the first frame registers, as before.
do
    local budget = dofile((arg[0]:match('^(.*[/\\])') or './') .. 'frame_budget.lua')
    local base_loader = CowboyBingusModLoader
    -- A loader: capabilities.after_startup (read-only, through a metatable, as
    -- v19's), after_startup queueing, running at once, or refusing.
    local function loader(capability, mode)
        local new = {open_log = base_loader.open_log, version = 19, queue = {}}
        if capability ~= nil then
            new.capabilities = setmetatable({}, {
                __index = function(_, key) if key == 'after_startup' then return capability end end,
                __newindex = function() error('capabilities are read-only') end})
        end
        function new.after_startup(fn)
            if mode == 'refuse' then return false, 'after_startup: 256 callbacks already registered' end
            if mode == 'now' then fn() else new.queue[#new.queue + 1] = fn end
            return true
        end
        return new
    end
    -- A Mod Bindings Menu stand-in: register_binding refuses the ids in refused
    -- (true, false or a number of tries); is_down answers nil until ready.
    local function menu(refused)
        local host = {version = 3, tries = {}, ready = false, down = {}}
        local api = {
            register_binding = function(id)
                host.tries[id] = (host.tries[id] or 0) + 1
                local refusal = refused and refused[id]
                if refusal == true or (type(refusal) == 'number' and host.tries[id] <= refusal) then
                    return false, 'slot already in use'
                end
                return true
            end,
            is_down = function(id)
                if not host.ready then return nil end
                return host.down[id] == true
            end,
        }
        host.counts = budget.wrap(api)
        host.register_binding, host.is_down = api.register_binding, api.is_down
        return host
    end
    local function registrations(host)
        local total = 0
        for _, tries in pairs(host.tries) do total = total + tries end
        return total
    end
    local function fresh(new_loader, host)
        _G.GalacticMenuHotkeyInstalled, _G.BingusTranslations, _G.BingusRuntime, _G.stingray = nil, nil, nil, nil
        Text.registry().steam_language = 'en'
        _G.CowboyBingusModLoader, _G.ModBindingsMenu = new_loader, host
        _G.update = function() end
        dofile(source)
        return upvalue(update, 'state'), update
    end
    local function run_queue(new_loader)
        for _, fn in ipairs(new_loader.queue) do fn() end
        new_loader.queue = {}
    end
    -- Frames outside a ship; each makes exactly the registrations expected[frame].
    local function run(wrapper, host, first, last, expected)
        for frame = first, last do
            local counts = budget.frame(host.counts, wrapper, 1 / 64)
            local want = expected[frame]
            budget.check(counts, want and {register_binding = want} or {}, 'frame ' .. frame)
            assert((counts.register_binding or 0) == (want or 0), 'frame ' .. frame .. ': ' .. budget.describe(counts))
        end
    end
    local ARMORY = 'cowboybingus.armory'

    -- The callback registers all six before the first frame; native input is
    -- not ready, so a shortcut answers with its fixed key until it is.
    local v19, host = loader(true), menu()
    local st, wrapper = fresh(v19, host)
    assert(#v19.queue == 1 and registrations(host) == 0, 'one callback queued at load, no registration yet')
    run_queue(v19)
    assert(registrations(host) == 6 and st.binding_host == host and not st.binding_retry, 'six registered after startup')
    run(wrapper, host, 1, 200, {})
    local shortcut_down = upvalue(wrapper, 'shortcut_down')
    local key_calls = 0
    local key_holder, key_index = holder(shortcut_down, 'key_down')
    local real_key_down = select(3, holder(shortcut_down, 'key_down'))
    debug.setupvalue(key_holder, key_index, function() key_calls = key_calls + 1; return true end)
    local map = upvalue(wrapper, 'SHORTCUTS')[1]
    assert(shortcut_down(map, host) == true and key_calls == 1, 'not ready: the fixed key answers')
    host.ready = true
    assert(shortcut_down(map, host) == false and key_calls == 1, 'ready: the binding answers')
    host.down[map.id] = true
    assert(shortcut_down(map, host) == true and key_calls == 1)
    debug.setupvalue(key_holder, key_index, real_key_down)

    -- Refused in the callback: tried again 60 frames after that try, then nothing.
    v19, host = loader(true), menu({[ARMORY] = 1})
    st, wrapper = fresh(v19, host)
    run_queue(v19)
    assert(registrations(host) == 6 and not st.binding_slots[ARMORY] and st.binding_retry, 'armory refused once')
    run(wrapper, host, 1, 400, {[60] = 1})
    assert(st.binding_slots[ARMORY] and not st.binding_retry, 'registered on the retry')

    -- Mod Bindings Menu absent when the callback runs: nothing registers; a menu
    -- that appears later registers on the frame it is first seen.
    v19 = loader(true)
    st, wrapper = fresh(v19, nil)
    run_queue(v19)
    host = menu()
    run(wrapper, host, 1, 10, {})
    _G.ModBindingsMenu = host
    run(wrapper, host, 11, 20, {[11] = 6})

    -- Startup already over: after_startup runs the callback at once, during the load.
    v19, host = loader(true, 'now'), menu()
    st, wrapper = fresh(v19, host)
    assert(registrations(host) == 6 and st.binding_host == host, 'registered while loading')
    run(wrapper, host, 1, 10, {})
    -- A callback that only runs after a frame already registered with the same
    -- table registers nothing again.
    v19, host = loader(true), menu()
    st, wrapper = fresh(v19, host)
    run(wrapper, host, 1, 3, {[1] = 6})
    run_queue(v19)
    assert(registrations(host) == 6, 'no second registration')

    -- Without the capability, the first frame registers: a v18 loader (no
    -- capabilities table) whatever its version, and a capability that is not true.
    for _, capability in ipairs({false, 'yes'}) do
        local old_loader = loader(capability)
        host = menu()
        st, wrapper = fresh(old_loader, host)
        assert(#old_loader.queue == 0 and registrations(host) == 0, 'no callback without the capability')
        run(wrapper, host, 1, 10, {[1] = 6})
    end
    local v18 = loader(nil)
    host = menu()
    st, wrapper = fresh(v18, host)
    assert(#v18.queue == 0 and registrations(host) == 0)
    run(wrapper, host, 1, 10, {[1] = 6})

    -- after_startup refuses: one log line, and the first frame registers.
    local from = #messages + 1
    local full = loader(true, 'refuse')
    host = menu()
    st, wrapper = fresh(full, host)
    run(wrapper, host, 1, 10, {[1] = 6})
    local refused_lines = 0
    for index = from, #messages do
        if messages[index]:find('Registration after startup refused (after_startup: 256 callbacks already registered); '
                                .. 'registering on the first frame.', 1, true) then refused_lines = refused_lines + 1 end
    end
    assert(refused_lines == 1, 'the refusal is logged once')
    for index = from, #messages do assert(not messages[index]:find('error', 1, true), messages[index]) end

    _G.CowboyBingusModLoader, _G.ModBindingsMenu = base_loader, nil
end
print('Registration after startup: with the loader\'s after_startup the six shortcuts register before the first '
      .. 'frame (the fixed keys answer until Mod Bindings Menu is ready), a refusal there is retried 60 frames later, '
      .. 'a menu absent then registers when it appears, a callback run at once registers at load; without the '
      .. 'capability, or when after_startup refuses (logged once), the first frame registers OK')

-- Per-frame calls, pinned with tests/frame_budget.lua (canonical copy:
-- PerformanceBaseline/frame_budget.lua). A fresh instance runs whole frames on a
-- fake engine, fake windows and keys, a fake Mod Bindings Menu and the fake
-- game memory above; its engine calls, Windows calls, binding calls, reads and
-- native calls are counted through one api table. In game a ReadProcessMemory
-- costs about 1-2 us; the engine calls and the window and key calls are
-- unmeasured in game. Twice: with a Mod Bindings Menu that offers only is_down
-- (v2.1 and older), which makes 3 reads per call (v2.1: 4), 18 per focused
-- frame; and with one that offers poll, which answers all six in one call of 8
-- reads (Mod Bindings Menu's tests/test_mods_tab.lua pins both).
local function per_frame_calls(with_poll)
    local budget = dofile((arg[0]:match('^(.*[/\\])') or './') .. 'frame_budget.lua')
    -- A mission lists its main world again among all worlds, as does the ship.
    local SHIP_WORLD, MISSION_WORLD, UI_WORLD, GALAXY = {}, {}, {}, {1}
    -- The game's window and another program's.
    local GAME_WINDOW, OTHER_WINDOW = 0x1234, 0x5678
    local game = {main = MISSION_WORLD, list = {MISSION_WORLD, UI_WORLD}, window = GAME_WINDOW, process = 0,
                  keys = {}, down = {}}
    local api = {
        from_hex = function() return 'galaxy table resource' end,
        main_world = function() return game.main end,
        worlds = function() return game.list end,
        units_by_resource = function(world) return world == SHIP_WORLD and GALAXY or {} end,
        GetForegroundWindow = function() return game.window end,
        GetWindowThreadProcessId = function(window, process)
            process[0] = window == GAME_WINDOW and game.process or game.process + 1
            return 1
        end,
        GetAsyncKeyState = function(key) return game.keys[key] and -32768 or 0 end,
        register_binding = function() return true end,
        is_down = function(id) return game.down[id] == true end,
        -- The same answers for every id, in the caller's table.
        poll = function(ids, out)
            out.down = out.down or {}
            for index = 1, #ids do out.down[index] = game.down[ids[index]] == true end
            return true
        end,
        open_presenter = function(_, kind) current[0], depth[0] = kind, 1 end,
    }
    _G.stingray = {
        Application = {main_world = function() return api.main_world() end, worlds = function() return api.worlds() end},
        World = {units_by_resource = function(world, id) return api.units_by_resource(world, id) end},
        IdString64 = {from_hex = function(hex) return api.from_hex(hex) end},
    }
    local host = {version = 3, register_binding = function(...) return api.register_binding(...) end,
                  is_down = function(id) return api.is_down(id) end}
    if with_poll then host.poll = function(...) return api.poll(...) end end
    _G.ModBindingsMenu = host
    _G.GalacticMenuHotkeyInstalled, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.update = function() end
    dofile(source)
    local wrapper = update
    local st = upvalue(wrapper, 'state')
    -- The native layer is the test's own (st.open_presenter below): the native
    -- check, which refuses outside the game, is marked done.
    st.initialized = true
    local CONTEXT_FRAMES = upvalue(wrapper, 'CONTEXT_FRAMES')
    -- The Windows calls go by their private names in the mod (GMH_ and the real
    -- name) and are counted under the real one.
    local function windows_api(real)
        return setmetatable({}, {__index = function(_, name)
            return api[name:match('^GMH_(.+)$') or name] or real[name]
        end})
    end
    local user32_holder, user32_index, real_user32 = holder(wrapper, 'user32')
    debug.setupvalue(user32_holder, user32_index, windows_api(real_user32))
    local kernel_holder, kernel_index, real_kernel = holder(wrapper, 'kernel32')
    api.ReadProcessMemory = function(...) return real_kernel.GMH_ReadProcessMemory(...) end
    debug.setupvalue(kernel_holder, kernel_index, windows_api(real_kernel))
    game.process = upvalue(wrapper, 'process_id')
    local counts = budget.wrap(api)
    local function frame(label, limits)
        budget.check((budget.frame(counts, wrapper, 1 / 64)), limits, label)
    end
    -- Frames that do not read the context.
    local function between(label, frames, limits)
        for index = 1, frames do
            assert(st.context_frames > 1, label .. ' ' .. index .. ' must not read the context')
            frame(label .. ' ' .. index, limits)
        end
    end
    local function check(label, limits)
        assert(st.context_frames <= 1, label .. ' must read the context')
        frame(label, limits)
    end
    local function with(...)
        local limits = {}
        for _, part in ipairs({...}) do
            for name, limit in pairs(part) do limits[name] = (limits[name] or 0) + limit end
        end
        return limits
    end
    local from = #messages + 1
    -- The context: the galaxy table looked up in every world, and aboard the
    -- window focus (two Windows calls). It is read once every CONTEXT_FRAMES
    -- frames (v1.8: on every frame) and on every frame that acts.
    local MISSION = {from_hex = 1, main_world = 1, worlds = 1, units_by_resource = 3}
    local SHIP = {from_hex = 1, main_world = 1, worlds = 1, units_by_resource = 1}
    local FOCUS = {GetForegroundWindow = 1, GetWindowThreadProcessId = 1}
    -- Aboard with the game focused, all six shortcuts are polled on every frame:
    -- six is_down calls, or one poll.
    local POLL, NONE = with_poll and {poll = 1} or {is_down = 6}, {}
    local PRESS = {ReadProcessMemory = 4, open_presenter = 1}

    -- In a mission. The first frame also registers the six bindings.
    check('first frame, in a mission', with(MISSION, {register_binding = 6}))
    between('in a mission', CONTEXT_FRAMES - 1, NONE)
    check('in a mission, context check', MISSION)
    between('in a mission', 4, NONE)
    -- The ship's world is found at the next context check.
    game.main, game.list = SHIP_WORLD, {SHIP_WORLD, UI_WORLD}
    between('ship loaded, before the next context check', CONTEXT_FRAMES - 5, NONE)
    check('arrival on the ship', with(SHIP, FOCUS, POLL))
    st.game_base = tonumber(ffi.cast('GMH_u64', module))
    st.open_presenter = function(...) return api.open_presenter(...) end
    current[0], depth[0] = 0, 0
    between('ship, focused', CONTEXT_FRAMES - 1, POLL)
    check('ship, focused, context check', with(SHIP, FOCUS, POLL))
    -- Another window comes to the front: until the next context check the
    -- shortcuts are still polled (a press would read the context first, below).
    game.window = OTHER_WINDOW
    between('ship, another window in front, before the context check', CONTEXT_FRAMES - 1, POLL)
    check('ship, not focused, context check', with(SHIP, FOCUS))
    -- Not focused: the focus on every frame, one call while the same window
    -- stays in front.
    between('ship, not focused', 3, {GetForegroundWindow = 1})
    -- Back to the game: seen on that frame, and the shortcuts are polled at once.
    game.window = GAME_WINDOW
    between('ship, focused again', 1, with(FOCUS, POLL))
    between('ship, focused', 2, POLL)
    -- A press reads the context, then acts on the frame it is first seen down:
    -- the presenter check (3 reads), the native call and the log line's read.
    game.down['cowboybingus.galactic_menu'] = true
    between('ship, Tab pressed', 1, with(POLL, SHIP, FOCUS, PRESS))
    assert(current[0] == 15, 'Tab opens the Galactic Map')
    between('ship, Tab held', 2, POLL)
    game.down['cowboybingus.galactic_menu'] = nil
    current[0], depth[0] = 0, 0
    -- A press while another window is already in front reads the context and
    -- does not act; held as the game comes back, it acts then, as in v1.8.
    -- That frame reads the focus twice (v1.8: once): when the game comes back,
    -- then with the whole context before the shortcut acts.
    between('ship, focused', 1, POLL)
    game.window, game.down['cowboybingus.galactic_menu'] = OTHER_WINDOW, true
    between('ship, Tab pressed in another window', 1, with(POLL, SHIP, FOCUS))
    assert(current[0] == 0 and not st.focused, 'no shortcut acts without focus')
    game.window = GAME_WINDOW
    between('ship, Tab held as the game comes back', 1, with(FOCUS, POLL, SHIP, FOCUS, PRESS))
    assert(current[0] == 15, 'a held Tab opens the map once the game is focused')
    game.down['cowboybingus.galactic_menu'] = nil
    current[0], depth[0] = 0, 0
    -- Without Mod Bindings Menu the fixed keys are polled instead.
    _G.ModBindingsMenu = nil
    between('ship, focused, without Mod Bindings Menu', CONTEXT_FRAMES - 1, {GetAsyncKeyState = 6})
    check('ship, focused, without Mod Bindings Menu, context check', with(SHIP, FOCUS, {GetAsyncKeyState = 6}))
    _G.ModBindingsMenu = host
    -- F8 pressed during the Hellpod's ready animation: until it opens, every
    -- frame reads the context and checks the presenter (3 reads) and the
    -- Hellpod (13 reads).
    pod_state(2, 1, 1)
    st.hellpod_wait = 10
    for index = 1, 2 do frame('ship, Hellpod wait ' .. index, with(SHIP, FOCUS, POLL, {ReadProcessMemory = 16})) end
    assert(st.hellpod_wait == 10 - 2 / 64, 'the Hellpod wait continues')
    st.hellpod_wait = nil
    between('ship, focused', 2, POLL)
    -- Leaving the ship: until the next context check the shortcuts are still
    -- polled, and a press reads the context first, so it does not act.
    game.main, game.list = MISSION_WORLD, {MISSION_WORLD, UI_WORLD}
    between('ship gone, before the context check', 2, POLL)
    game.down['cowboybingus.galactic_menu'] = true
    between('Tab pressed as the ship is gone', 1, with(POLL, MISSION))
    assert(current[0] == 0 and st.world == nil, 'no shortcut acts off the ship')
    game.down['cowboybingus.galactic_menu'] = nil
    between('in a mission', CONTEXT_FRAMES - 1, NONE)
    check('in a mission, context check', MISSION)
    for index = from, #messages do
        assert(not messages[index]:find('Update error:', 1, true), messages[index])
    end

    -- Context checks and the frames between them allocate nothing of their own
    -- aboard, focused or not (the fakes return kept tables), interpreted, so
    -- that compiled-trace allocation sinking cannot hide garbage. One context
    -- period runs first: a full collection shrinks LuaJIT's temporary string
    -- buffer, which the first status text after it grows again.
    local function garbage(periods)
        jit.off()
        jit.flush()
        collectgarbage('collect')
        collectgarbage('stop')
        for _ = 1, CONTEXT_FRAMES do wrapper(1 / 64) end
        local before = collectgarbage('count')
        for _ = 1, CONTEXT_FRAMES * periods do wrapper(1 / 64) end
        local bytes = (collectgarbage('count') - before) * 1024
        collectgarbage('restart')
        jit.on()
        return bytes
    end
    game.main, game.list = SHIP_WORLD, {SHIP_WORLD, UI_WORLD}
    local focused = garbage(4)
    assert(st.world == SHIP_WORLD and st.focused)
    game.window = OTHER_WINDOW
    local unfocused = garbage(4)
    assert(st.world == SHIP_WORLD and not st.focused)
    game.window = GAME_WINDOW
    assert(focused == 0 and unfocused == 0,
           string.format('ship frames allocated %d bytes (focused) and %d (not focused)', focused, unfocused))
end
per_frame_calls(false)
per_frame_calls(true)
print('Per-frame calls, with is_down and with poll: the context read every 15 frames and on frames that act, '
      .. 'missions, the ship focused and not, presses on an older context, fixed keys and a Hellpod wait within their '
      .. 'pinned budgets, and ship frames without allocation OK')
