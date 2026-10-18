-- Key capture for extended bindings (src/capture.lua): the opening input is
-- never captured, Back cancels, Delete clears, modifiers make chords or bind
-- alone, the captured keys never fire the binding, focus loss and the timeout
-- cancel, every exit restores the page's Back guard, and mod bindings read
-- false during the capture. The controller page captures controller buttons
-- and keeps the keyboard's keys. A simulated keyboard, mouse and two pads.
-- Usage: luajit test_capture.lua [path to src/mod_bindings_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local function remove_files()
    for _, name in ipairs({'ModBindingsMenu.assignments', 'ModBindingsMenu.bindings'}) do
        for _, suffix in ipairs({'', '.bak', '.tmp'}) do os.remove(directory .. '/' .. name .. suffix) end
    end
end
remove_files()
_G.CowboyBingusModLoader = {log_directory = directory}
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local Text = dofile(root .. '/src/bingus_text.lua')
_G.BingusTranslations = nil
Text.registry().steam_language = 'en'
_G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
_G.mbm_files = setmetatable({}, {__index = function(loaded, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(loaded, name, chunk)
    return chunk
end})

-- A simulated keyboard, mouse and two pads: held buttons, and the buttons
-- pressed this frame, which any_pressed reports one at a time. The keyboard
-- has an entry for the left mouse button, as the game's does (VK codes).
local KEYS = {g = 1, h = 2, ['left ctrl'] = 3, ['right ctrl'] = 4, ['left shift'] = 5, ['right shift'] = 6,
              ['left alt'] = 7, ['right alt'] = 8, esc = 9, delete = 10, backspace = 11, enter = 12, space = 13,
              ['numpad enter'] = 14, f9 = 15, ['left button **'] = 16}
local MOUSE = {left = 0, right = 1, left_double = 5}
local PAD = {d_up = 0, start = 4, left_shoulder = 8, right_shoulder = 9, left_trigger = 10, a = 12, b = 13, x = 14,
             y = 15}
local IDS = {k = KEYS, m = MOUSE, p1 = PAD, p2 = PAD}
local held, fresh = {k = {}, m = {}, p1 = {}, p2 = {}}, {k = {}, m = {}, p1 = {}, p2 = {}}
local plugged = {p1 = false, p2 = true}
local function device(code)
    local ids = IDS[code]
    return {
        button = function(index) return held[code][index] and 1 or 0 end,
        button_id = function(name) return ids[name] end,
        button_name = function(index)
            for name, id in pairs(ids) do if id == index then return name end end
        end,
        any_pressed = function()
            local index = table.remove(fresh[code], 1)
            return index
        end,
        connected = plugged[code] ~= nil and function() return plugged[code] end or nil,
    }
end
local function press(name, code)
    code = code or 'k'
    local index = IDS[code][name]
    held[code][index] = true
    fresh[code][#fresh[code] + 1] = index
end
local function release(name, code)
    code = code or 'k'
    held[code][IDS[code][name]] = nil
end

_G.update = function() end
dofile(source)
local host = assert(ModBindingsMenu)
-- An upvalue of fn or of a function it reaches through its upvalues.
local function upvalue(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == wanted then return value end
        if type(value) == 'function' then nested[#nested + 1] = value end
    end
    for _, inner in ipairs(nested) do
        local found = upvalue(inner, wanted, seen)
        if found ~= nil then return found end
    end
    return nil
end
local state = assert(upvalue(host.register_binding, 'state'))
local mbm = assert(upvalue(host.register_binding, 'mbm'), 'missing upvalue mbm')
local begin_capture, update_capture, cancel_capture = mbm.begin_capture, mbm.update_capture, mbm.cancel_capture
local function phase() return (mbm.capture_phase()) end
-- One frame: the frame number, the capture's update, then the frame's presses
-- are no longer fresh.
local function frame(seconds, focused)
    state.frame = state.frame + 1
    update_capture(seconds or 0.016, focused)
    for code in pairs(fresh) do fresh[code] = {} end
end
-- The page's Back guard, counted.
local guard = {held = 0, released = 0}
local hooks = {hold_back = function() guard.held = guard.held + 1 end,
               release_back = function() guard.released = guard.released + 1 end}
local function keys(id)
    local list = host.binding(id)
    local parts = {}
    for _, alternative in ipairs(list) do
        local text = alternative.button
        for _, modifier in ipairs(alternative.modifiers) do text = modifier .. '+' .. text end
        parts[#parts + 1] = text .. '@' .. alternative.trigger
    end
    return table.concat(parts, '|')
end

assert(host.register_binding('ext.a', 'A', nil, {backend = 'extended', default = 'f9'}))
assert(host.register_binding('ext.hold', 'Hold', nil,
                             {backend = 'extended', default = {{button = 'h', trigger = 'hold'}}}))
assert(host.register_binding('native.a', 'Native'))
assert(select(2, begin_capture('ext.a', hooks)) == 'input not ready', 'no engine input yet')
_G.stingray = {Keyboard = device('k'), Mouse = device('m'), Pad1 = device('p1'), Pad2 = device('p2')}
assert(select(2, begin_capture('native.a', hooks)) == 'not an extended binding')
assert(select(2, begin_capture('nobody', hooks)) == 'not an extended binding')
assert(phase() == 'idle' and guard.held == 0 and not state.suppressed)

-- 1. The Enter that activated the row is held: arming until it is released;
-- then G is captured; while G is held the binding does not fire; on release
-- the capture ends, the guard goes back and mod bindings read again.
frame()
host.is_down('ext.a')
press('enter')
assert(begin_capture('ext.a', hooks) and phase() == 'arming' and guard.held == 1 and state.suppressed)
assert(select(2, begin_capture('ext.hold', hooks)) == 'a capture is running')
frame()
assert(phase() == 'arming', 'Enter still held: not listening yet')
release('enter')
frame()
assert(phase() == 'capturing')
local epoch = state.input_epoch
press('g')
frame()
assert(phase() == 'releasing' and keys('ext.a') == 'g@press')
assert(host.is_down('ext.a') == false, 'suppressed while the chosen key is held')
frame()
assert(phase() == 'releasing')
release('g')
frame()
assert(phase() == 'idle' and guard.released == 1 and not state.suppressed and state.input_epoch == epoch + 1)
frame()
assert(host.is_down('ext.a') == false)
press('g')
frame()
assert(host.is_down('ext.a') == true, 'the captured G works afterwards')
release('g')
print('Capture: the opening Enter is not captured, G is, and does not fire while held; the guard goes back OK')

-- 2. Chords: Ctrl held, then G: Ctrl+G. A modifier pressed and released alone
-- binds the modifier. A mouse button with Shift held.
assert(begin_capture('ext.a', hooks))
frame()
press('left ctrl')
frame()
assert(phase() == 'capturing', 'a modifier alone waits')
press('g')
frame()
assert(keys('ext.a') == 'left ctrl+g@press', keys('ext.a'))
release('g')
release('left ctrl')
frame()
assert(phase() == 'idle')
assert(begin_capture('ext.a', hooks))
frame()
press('right shift')
frame()
release('right shift')
frame()
assert(keys('ext.a') == 'right shift@press' and phase() == 'idle', keys('ext.a'))
assert(begin_capture('ext.a', hooks))
frame()
press('left shift')
frame()
press('right', 'm')
frame()
assert(keys('ext.a') == 'left shift+right@press' and phase() == 'releasing')
release('right', 'm')
release('left shift')
frame()
assert(phase() == 'idle' and host.binding('ext.a')[1].device == 'mouse')
print('Chords with Ctrl and Shift, a modifier alone, a mouse button OK')

-- 3. Back cancels: the binding is unchanged, the guard goes back. Delete
-- clears: no keys, and the author's default no longer applies.
local before = keys('ext.a')
assert(begin_capture('ext.a', hooks))
frame()
press('esc')
frame()
assert(phase() == 'idle' and keys('ext.a') == before and guard.released == guard.held)
release('esc')
assert(begin_capture('ext.a', hooks))
frame()
press('delete')
frame()
assert(keys('ext.a') == '' and host.binding_info('ext.a').state == 'cleared' and phase() == 'releasing')
release('delete')
frame()
assert(phase() == 'idle')
print('Back cancels without a change; Delete clears the binding OK')

-- 4. A Hold binding keeps Hold when a new key is captured.
assert(begin_capture('ext.hold', hooks))
frame()
press('g')
frame()
release('g')
frame()
assert(keys('ext.hold') == 'g@hold', keys('ext.hold'))
print('A captured key keeps the binding\'s trigger OK')

-- 5. Focus loss, the timeout and a cancel from the page (tab or page change)
-- end the capture with the guard restored and nothing changed.
before = keys('ext.hold')
for _, ending in ipairs({'focus', 'timeout', 'page'}) do
    local released = guard.released
    assert(begin_capture('ext.hold', hooks))
    frame(0.016, true)
    if ending == 'focus' then
        frame(0.016, false)
    elseif ending == 'timeout' then
        for _ = 1, 3 do frame(4) end
    else
        cancel_capture('tab changed')
    end
    assert(phase() == 'idle' and guard.released == released + 1 and not state.suppressed, ending)
    assert(keys('ext.hold') == before, ending)
end
-- A guard that cannot be held: no capture, nothing suppressed.
local ok, why = begin_capture('ext.hold', {hold_back = function() error('no page') end})
assert(not ok and why == 'back guard unavailable' and phase() == 'idle' and not state.suppressed)
-- A guard that fails to go back does not keep the capture alive.
assert(begin_capture('ext.hold', {release_back = function() error('gone') end}))
cancel_capture('page closed')
assert(phase() == 'idle' and not state.suppressed)
print('Focus loss, the timeout and page changes cancel; guard failures never leave a capture running OK')

-- 6. A key held through a capture fires no press afterwards (a new input
-- epoch): H is pressed while capturing and still held when the capture is
-- cancelled. A hold binding reads keys held at that moment at once.
assert(host.set_binding('ext.a', {'h'}))
frame()
host.is_down('ext.a')
assert(begin_capture('ext.hold', hooks))
frame(0.016, true)
press('h')
frame(0.016, false)
assert(phase() == 'idle' and keys('ext.hold') == 'g@hold')
frame()
assert(host.is_down('ext.a') == false, 'H held through the capture: no press')
release('h')
press('g')
frame()
assert(host.is_down('ext.hold') == true, 'hold reads held keys at once')
release('g')
print('No phantom press after a capture; hold reads at once OK')

-- 7. Focus from the engine (stingray.Window.has_focus). A window never
-- reported focused does not cancel: an engine that always answers false would
-- otherwise end every capture. Focused, then not: cancelled.
local focus = false
stingray.Window = {has_focus = function() return focus end}
assert(begin_capture('ext.hold', hooks))
for _ = 1, 5 do frame() end
assert(phase() == 'capturing', 'never seen focused: no cancel')
focus = true
frame()
assert(phase() == 'capturing')
focus = false
frame()
assert(phase() == 'idle' and keys('ext.hold') == 'g@hold')
stingray.Window = nil
print('Focus from the engine: cancels only after the window was seen focused OK')

-- 8. The keyboard's entry for the left mouse button and a mouse double click
-- are not captured; the mouse's own button is.
assert(begin_capture('ext.hold', hooks))
frame()
press('left button **')
press('left_double', 'm')
frame()
assert(phase() == 'capturing', 'ignored inputs')
release('left button **')
release('left_double', 'm')
press('right', 'm')
frame()
assert(keys('ext.hold') == 'right@hold' and host.binding('ext.hold')[1].device == 'mouse')
release('right', 'm')
frame()
assert(phase() == 'idle')
print('The keyboard\'s mouse entries and double clicks are ignored OK')

-- 9. The controller page: controller buttons from any connected pad, chords
-- with a shoulder button, the keyboard's keys kept; X clears only the
-- controller's; B and Escape cancel; the keyboard page keeps the controller's.
local function all_keys(id)
    local parts = {}
    for _, alternative in ipairs(host.binding(id)) do
        local text = alternative.button
        for _, modifier in ipairs(alternative.modifiers) do text = modifier .. '+' .. text end
        parts[#parts + 1] = alternative.device:sub(1, 1) .. ':' .. text .. '@' .. alternative.trigger
    end
    return table.concat(parts, '|')
end
assert(all_keys('ext.a') == 'k:h@press', all_keys('ext.a'))
assert(select(2, begin_capture('ext.a', hooks, 'touch')) == 'unknown page')
press('a', 'p2')
assert(begin_capture('ext.a', hooks, 'controller') and select(3, mbm.capture_phase()) == 'controller')
frame()
assert(phase() == 'arming', 'A on the connected pad still held')
release('a', 'p2')
frame()
assert(phase() == 'capturing')
press('y', 'p1')
press('g')
frame()
assert(phase() == 'capturing', 'a pad that is not connected and the keyboard are not captured')
release('y', 'p1')
release('g')
press('left_shoulder', 'p2')
frame()
assert(phase() == 'capturing', 'a shoulder button alone waits')
press('y', 'p2')
frame()
assert(all_keys('ext.a') == 'k:h@press|c:left_shoulder+y@press', all_keys('ext.a'))
release('y', 'p2')
release('left_shoulder', 'p2')
frame()
assert(phase() == 'idle')
-- The chord reads on any connected pad; a pad plugged in or removed is followed.
frame()
host.is_down('ext.a')
press('left_shoulder', 'p2')
press('y', 'p2')
frame()
assert(host.is_down('ext.a') == true, 'LB+Y on the second pad')
release('left_shoulder', 'p2')
release('y', 'p2')
frame()
assert(host.is_down('ext.a') == false)
plugged.p1, plugged.p2 = true, false
press('left_shoulder', 'p2')
press('y', 'p2')
frame()
assert(host.is_down('ext.a') == false, 'a removed pad does not count')
release('left_shoulder', 'p2')
release('y', 'p2')
press('left_shoulder', 'p1')
press('y', 'p1')
frame()
assert(host.is_down('ext.a') == true, 'the pad plugged in counts')
release('left_shoulder', 'p1')
release('y', 'p1')
plugged.p1, plugged.p2 = false, true
-- Escape and B cancel on the controller page.
for _, back in ipairs({{'esc', 'k'}, {'b', 'p2'}}) do
    assert(begin_capture('ext.a', hooks, 'controller'))
    frame()
    press(back[1], back[2])
    frame()
    assert(phase() == 'idle' and all_keys('ext.a') == 'k:h@press|c:left_shoulder+y@press', back[1])
    release(back[1], back[2])
end
-- The keyboard page replaces the keyboard's key in place and keeps the controller's.
assert(begin_capture('ext.a', hooks))
frame()
press('g')
frame()
release('g')
frame()
assert(all_keys('ext.a') == 'k:g@press|c:left_shoulder+y@press', all_keys('ext.a'))
-- X clears only the controller's buttons.
assert(begin_capture('ext.a', hooks, 'controller'))
frame()
press('x', 'p2')
frame()
release('x', 'p2')
frame()
assert(phase() == 'idle' and all_keys('ext.a') == 'k:g@press' and host.binding_info('ext.a').state == 'set')
print('Controller page: any connected pad, hot-plug, shoulder chords, keyboard keys kept, X clears its own, '
      .. 'B and Escape cancel OK')
remove_files()
