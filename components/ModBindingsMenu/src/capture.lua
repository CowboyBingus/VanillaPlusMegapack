-- Mod Bindings Menu's key capture for extended bindings on the MODS tab:
-- choosing a binding's key the way a native row's capture widget does.
-- src/mod_bindings_menu.lua runs this file once as mbm_files.capture(mbm); it
-- adds begin_capture, update_capture, cancel_capture and capture_phase to mbm.
--
-- A capture belongs to a page: the keyboard page captures keyboard keys and
-- mouse buttons, the controller page controller buttons. It replaces the
-- binding's alternatives of that page's devices and keeps the others, so a
-- binding can have a keyboard key and a controller button.
--
-- Phases: idle -> arming -> capturing -> releasing -> idle.
-- - arming: the row was activated; wait until the click, key or button that
--   activated it is released, so that input is never captured.
-- - capturing: the first newly pressed input decides:
--     Back (Escape; B on a controller, from either page) cancels;
--     Delete or Backspace (X on the controller page) clears the page's keys;
--     a modifier (Ctrl, Shift, Alt; a shoulder button or trigger on the
--       controller page) waits: another input pressed while it is held makes a
--       chord with it, releasing it alone binds the modifier;
--     anything else becomes the binding, with the modifiers held at that moment.
--   Back and clear are reserved: they cannot be bound by capture (authors can
--   give them in a default or with set_binding). The keyboard's own entries
--   for mouse buttons (names ending in **) and mouse double clicks are ignored.
-- - releasing: wait until every input of the capture is released, so the new
--   binding does not fire from the press that chose it.
-- From arming to the end every mod binding reads false (state.suppressed), and
-- the page's Back guard is held (hooks.hold_back), so Back cancels the capture
-- instead of closing the page. Focus loss (after the window was seen focused:
-- an engine that never reports focus cannot cancel every capture), a page or
-- world change, an error, or TIMEOUT seconds without a choice cancel. Every
-- exit restores the guard (hooks.release_back) and starts a new input epoch,
-- so a key held through the capture fires no press afterwards.
-- Cost: nothing while idle; while capturing, on the page only, one any_pressed
-- per device (per connected pad), the window focus and one read per held
-- modifier per frame.
local mbm = ...
local state, note = mbm.state, mbm.note
local engine_source, store_alternatives = mbm.engine_source, mbm.store_alternatives
local engine_down, engine_any_pressed, window_focused = mbm.engine_down, mbm.engine_any_pressed, mbm.window_focused
local current_alternatives, binding_info = mbm.current_alternatives, mbm.binding_info

local IDLE, ARMING, CAPTURING, RELEASING = 'idle', 'arming', 'capturing', 'releasing'
local TIMEOUT = 10
local PAGES = {keyboard = {k = true, m = true}, controller = {p = true}}
local DEVICES = {'k', 'm', 'p'}
-- Engine button names (looked up when a capture first begins; a name the
-- engine does not know is left out). Controllers use the engine's Xbox names.
local ACTIVATORS = {k = {'enter', 'numpad enter', 'space'}, m = {'left'}, p = {'a'}}
local BACK = {k = {'esc', 'escape'}, p = {'b'}}
local CLEAR = {k = {'delete', 'backspace'}, p = {'x'}}
local MODIFIERS = {k = {'left ctrl', 'right ctrl', 'left shift', 'right shift', 'left alt', 'right alt'},
                   p = {'left_shoulder', 'right_shoulder', 'left_trigger', 'right_trigger'}}
-- The device whose modifiers go with a main input.
local MODIFIER_OF = {k = 'k', m = 'k', p = 'p'}

local capture = {phase = IDLE, id = nil, page = nil, hooks = nil, timer = 0, held = {}, pending = nil,
                 trigger = 'press', focused_seen = false, names = nil}

-- name -> index sets per device, looked up once per session through the engine.
local function lookup(engine)
    if capture.names then return capture.names end
    local names = {activators = {}, back = {}, clear = {}, modifiers = {}}
    local function fill(target, lists)
        for device, list in pairs(lists) do
            local tbl = engine.devices[device]
            target[device] = {}
            for _, name in ipairs(list) do
                local ok, index = false, nil
                if tbl then ok, index = pcall(tbl.button_id, name) end
                if ok and type(index) == 'number' then target[device][index] = true end
            end
        end
    end
    fill(names.activators, ACTIVATORS)
    fill(names.back, BACK)
    fill(names.clear, CLEAR)
    fill(names.modifiers, MODIFIERS)
    capture.names = names
    return names
end

local function any_down(set_by_device)
    for device, set in pairs(set_by_device) do
        for index in pairs(set) do
            if engine_down(device, index) then return true end
        end
    end
    return false
end

local function member(set_by_device, device, index)
    return set_by_device[device] ~= nil and set_by_device[device][index] == true
end

-- Ends the capture whatever its phase: the guard goes back, mod bindings read
-- again from a new input epoch.
local function finish(reason)
    local hooks = capture.hooks
    capture.phase, capture.id, capture.page, capture.hooks, capture.pending = IDLE, nil, nil, nil, nil
    capture.focused_seen = false
    for key in pairs(capture.held) do capture.held[key] = nil end
    state.suppressed = false
    state.input_epoch = state.input_epoch + 1
    if hooks and hooks.release_back then
        local ok, problem = pcall(hooks.release_back)
        if not ok then note('Restoring the page\'s Back guard failed: ' .. tostring(problem)) end
    end
    if reason then note('Key capture ended: ' .. reason .. '.') end
end

-- The trigger a captured key keeps: the first of the page's alternatives',
-- else the binding's first alternative's, else press.
local function current_trigger(alternatives, page)
    for _, alternative in ipairs(alternatives) do
        if PAGES[page][alternative.inputs[1].device] then return alternative.trigger end
    end
    return alternatives[1] and alternatives[1].trigger or 'press'
end

-- Starts a capture for extended binding id on page 'keyboard' (the default) or
-- 'controller'. hooks (optional): {hold_back = fn, release_back = fn} for the
-- page's Back guard. Returns true, or false and a reason.
local function begin_capture(id, hooks, page)
    page = page or 'keyboard'
    local record = state.registry[id]
    if capture.phase ~= IDLE then return false, 'a capture is running' end
    if not PAGES[page] then return false, 'unknown page' end
    if not record or not record.extended then return false, 'not an extended binding' end
    if binding_info(id).state == 'inactive' then return false, 'the binding was saved by a newer version' end
    local engine = engine_source()
    local alternatives = engine and current_alternatives(id)
    if not alternatives then return false, 'input not ready' end
    lookup(engine)
    capture.phase, capture.id, capture.page, capture.hooks, capture.timer = ARMING, id, page, hooks, 0
    capture.trigger, capture.focused_seen = current_trigger(alternatives, page), false
    state.suppressed = true
    if hooks and hooks.hold_back then
        local ok, problem = pcall(hooks.hold_back)
        if not ok then
            finish('the page\'s Back guard could not be held (' .. tostring(problem) .. ')')
            return false, 'back guard unavailable'
        end
    end
    return true
end

-- Records the choice: inputs (main first) replace the page's alternatives, {}
-- removes them; the other page's alternatives stay. Then waits for release.
local function choose(inputs)
    local devices, kept, at = PAGES[capture.page], {}, nil
    for _, alternative in ipairs(current_alternatives(capture.id) or {}) do
        if devices[alternative.inputs[1].device] then
            at = at or #kept + 1
        elseif #kept < mbm.MAX_ALTERNATIVES - 1 then
            kept[#kept + 1] = alternative
        end
    end
    if #inputs > 0 then table.insert(kept, at or #kept + 1, {inputs = inputs, trigger = capture.trigger}) end
    store_alternatives(capture.id, kept)
    for _, input in ipairs(inputs) do capture.held[input.device .. ':' .. input.index] = input end
    capture.phase = RELEASING
end

local function held_modifiers(names, device)
    local inputs = {}
    for index in pairs(names.modifiers[device] or {}) do
        if engine_down(device, index) then inputs[#inputs + 1] = {device = device, index = index} end
    end
    table.sort(inputs, function(a, b) return a.index < b.index end)
    return inputs
end

-- The keyboard's entries for mouse buttons (the mouse reports those) and mouse
-- double clicks are not inputs to capture.
local function ignored(engine, device, index)
    local tbl = engine.devices[device]
    if device == 'p' or not tbl or type(tbl.button_name) ~= 'function' then return false end
    local ok, name = pcall(tbl.button_name, index)
    if not ok or type(name) ~= 'string' then return false end
    return device == 'k' and name:find('%*%*$') ~= nil or device == 'm' and name:find('double', 1, true) ~= nil
end

-- One newly pressed input on a device of the capture's page, decided as
-- described at the top.
local function decide(engine, names, device, index)
    if ignored(engine, device, index) then return end
    if member(names.clear, device, index) then
        choose({})
        capture.held[device .. ':' .. index] = {device = device, index = index}
        return
    end
    if member(names.modifiers, device, index) then
        capture.pending = capture.pending or {device = device, index = index}
        return
    end
    local inputs = {{device = device, index = index}}
    for _, modifier in ipairs(held_modifiers(names, MODIFIER_OF[device])) do
        if #inputs < mbm.MAX_INPUTS then inputs[#inputs + 1] = modifier end
    end
    choose(inputs)
end

-- The input first pressed this frame on device, if any: Back cancels from
-- either page; on the page's devices it is decided. Returns whether the
-- capture left the capturing phase.
local function pressed_on(engine, names, device)
    local index = engine_any_pressed(device)
    if not index then return false end
    if member(names.back, device, index) then
        finish('cancelled')
        return true
    end
    if PAGES[capture.page][device] then decide(engine, names, device, index) end
    return capture.phase ~= CAPTURING
end

local function capturing(engine, names)
    for _, device in ipairs(DEVICES) do
        if pressed_on(engine, names, device) then return end
    end
    -- A modifier pressed alone and released alone becomes the binding.
    local pending = capture.pending
    if pending and not engine_down(pending.device, pending.index) then
        capture.pending = nil
        choose({pending})
        for key in pairs(capture.held) do capture.held[key] = nil end
    end
end

-- Whether the capture may go on as far as focus goes: focused (true, false,
-- or nil to ask the engine) is only lost after the window was seen focused.
local function focus_kept(focused)
    if focused == nil then focused = window_focused() end
    if focused == true then capture.focused_seen = true end
    return focused ~= false or not capture.focused_seen
end

-- Releasing: ends the capture once every input it chose is released.
local function releasing()
    for _, input in pairs(capture.held) do
        if engine_down(input.device, input.index) then return end
    end
    finish(nil)
end

-- One frame of the capture, from the page's frame. focused: whether the game
-- window has focus; nil asks the engine (stingray.Window.has_focus).
local function update_capture(seconds, focused)
    if capture.phase == IDLE then return end
    local engine = engine_source()
    if not engine then
        finish('input unavailable')
        return
    end
    if not focus_kept(focused) then
        finish('the game lost focus')
        return
    end
    capture.timer = capture.timer + (seconds or 0)
    if capture.phase == ARMING then
        if not any_down(capture.names.activators) then capture.phase = CAPTURING end
    elseif capture.phase == CAPTURING then
        if capture.timer > TIMEOUT then
            finish('no key chosen in ' .. TIMEOUT .. ' seconds')
            return
        end
        capturing(engine, capture.names)
    end
    if capture.phase == RELEASING then releasing() end
end

local function cancel_capture(reason)
    if capture.phase ~= IDLE then finish(reason or 'cancelled') end
end

mbm.begin_capture, mbm.update_capture, mbm.cancel_capture = begin_capture, update_capture, cancel_capture
function mbm.capture_phase() return capture.phase, capture.id, capture.page end

if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({lookup, any_down, member, finish, current_trigger, begin_capture, choose, held_modifiers,
                         ignored, decide, pressed_on, capturing, focus_kept, releasing, update_capture,
                         cancel_capture, mbm.capture_phase}) do
        jit.off(fn)
    end
end
