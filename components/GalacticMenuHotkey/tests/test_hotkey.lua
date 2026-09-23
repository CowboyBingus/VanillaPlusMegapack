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
assert(shortcut_down() == true and fallback_calls == 1, 'missing host must use Tab')
local registrations, binding_down = 0, false
ModBindingsMenu = {
    register_binding = function(id, label, slot)
        assert(id == 'cowboybingus.galactic_menu' and type(label) == 'number' and slot == 1)
        registrations = registrations + 1
        return true
    end,
    is_down = function(id)
        assert(id == 'cowboybingus.galactic_menu')
        return binding_down
    end,
}
assert(shortcut_down() == false and fallback_calls == 1, 'saved unpressed binding must suppress Tab')
binding_down = true
assert(shortcut_down() == true and registrations == 1, 'saved binding must activate without re-registering')
binding_down = nil
assert(shortcut_down() == true and fallback_calls == 2, 'unavailable binding must retain fallback')
ModBindingsMenu = {register_binding = function() return false end, is_down = function() error('must not poll rejected slot') end}
assert(shortcut_down() == true and fallback_calls == 3, 'rejected registration must retain fallback')
ModBindingsMenu = nil
state.binding_host = nil
local activate = upvalue(step, 'activate')
local initialize_native = upvalue(step, 'initialize_native')
local prefix = upvalue(initialize_native, 'PRESENTER_PREFIX')
local capture = os.getenv('HD2_GAME_CAPTURE')
if capture then
    local game = assert(io.open(capture, 'rb'))
    assert(game:seek('set', 0x14c02c0))
    assert(game:read(#prefix) == prefix, 'presenter function changed from captured build')
    game:close()
end
local hash_module = upvalue(initialize_native, 'module_sha256')
local kernel32 = upvalue(hash_module, 'kernel32')
assert(#hash_module(kernel32.GetModuleHandleA(nil)) == 64,
       'native SHA-256 hashing failed')

local global_offset, presenter_offset = 0x347ce28, 17032
local module = ffi.new('GMH_u8[?]', global_offset + 8)
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
    assert(kind == 15 and data == nil, 'wrong native presenter request')
    calls = calls + 1
    current[0], depth[0] = 15, 1
end
activate()
assert(calls == 1 and current[0] == 15, 'Tab did not enter Hologram presenter')
activate()
assert(calls == 1, 'already-open Hologram must not be reopened')
current[0], depth[0] = 2, 1
activate()
assert(calls == 1, 'other menu must not be interrupted')
current[0], depth[0] = 1, 1
activate()
assert(calls == 1, 'Main menu must not be interrupted')
current[0], depth[0] = 0, 1
activate()
assert(calls == 1, 'inconsistent menu stack must not be interrupted')
for _, message in ipairs(messages) do
    assert(not message:find('Update error:', 1, true), message)
end
print('Native Hologram dispatch, menu guards and saved keyboard binding integration OK')
