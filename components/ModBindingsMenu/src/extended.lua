-- Mod Bindings Menu's extended bindings: bindings without a native action. A
-- registration gets one when the 36 native actions are all held (or with
-- options.backend = 'extended'), so the number of bindings has no fixed limit.
-- src/mod_bindings_menu.lua runs this file once as mbm_files.extended(mbm); it
-- adds register_extended, extended_known, extended_down, set_binding, binding,
-- binding_info, EXTENDED_DEVICES and EXTENDED_TRIGGERS to mbm.
--
-- Native bindings are unchanged: the game evaluates them on every device with
-- its own activation types. Extended bindings read the engine's input instead
-- (stingray.Keyboard, Mouse and Pad1 to Pad4, never Windows polling) and
-- support what this file evaluates, listed in EXTENDED_DEVICES and
-- EXTENDED_TRIGGERS:
-- - press: true on the frame its inputs become held, release: on the frame they
--   stop being held, hold: while they are held;
-- - alternatives: any one of a binding's alternatives satisfies it;
-- - modifiers: an alternative's later inputs must be held with its first one.
--   Holding more keys than an alternative names does not stop it;
-- - controller buttons (Xbox names: a, b, x, y, left_shoulder...) count on any
--   connected pad, checked each frame one is read, so a pad plugged in or
--   removed during play is followed.
-- A binding never changes backend: src/extended_store.lua keeps a line for
-- every extended id.
--
-- Cost. Nothing per frame by itself: a binding is evaluated when a mod asks for
-- it (is_down, poll), at most once per frame, and each physical input is read
-- from the engine at most once per frame however many bindings use it; a
-- controller input reads each connected pad, after one connected check per pad
-- per frame. One engine button read cost about 0.1 us in game (gate 1, ship,
-- 2026-10-13: 10000 Keyboard.button calls); the connected check is unmeasured in
-- game.
local mbm = ...
local state, note = mbm.state, mbm.note
local load_extended, MAX_ALTERNATIVES, MAX_INPUTS = mbm.load_extended, mbm.MAX_ALTERNATIVES, mbm.MAX_INPUTS

-- Device codes as in the bindings file, the engine's input tables, and the
-- names authors use.
local ENGINE_DEVICES = {k = 'Keyboard', m = 'Mouse'}
local ENGINE_PADS = {'Pad1', 'Pad2', 'Pad3', 'Pad4'}
local DEVICE_CODES = {keyboard = 'k', mouse = 'm', controller = 'p'}
local DEVICE_NAMES = {k = 'keyboard', m = 'mouse', p = 'controller'}
local DEVICE_KEYS = {k = 1, m = 2, p = 3}
-- Modifiers are keyboard keys for keyboard and mouse bindings, controller
-- buttons for controller bindings.
local MODIFIER_DEVICE = {k = 'k', m = 'k', p = 'p'}
local TRIGGERS = {press = true, release = true, hold = true}
-- What extended bindings support (ModBindingsMenu.extended).
local EXTENDED_DEVICES = {'keyboard', 'mouse', 'controller'}
local EXTENDED_TRIGGERS = {'press', 'release', 'hold'}
local SUPPORTED_DEVICE = {k = true, m = true, p = true}

-- The engine's input tables, found once stingray has them. devices.p is the
-- first pad, for button names and ids (every pad uses the same); pads lists
-- them all; connected holds the connected ones, checked once per frame.
local source = {ready = false, devices = {}, pads = {}, connected = {}, connected_count = 0, connected_frame = nil}
local function usable(device)
    return type(device) == 'table' and type(device.button) == 'function' and type(device.button_id) == 'function'
end
local function engine_source()
    if source.ready then return source end
    local engine = rawget(_G, 'stingray')
    if type(engine) ~= 'table' then return nil end
    for code, name in pairs(ENGINE_DEVICES) do
        if usable(engine[name]) then source.devices[code] = engine[name] end
    end
    local pads = {}
    for _, name in ipairs(ENGINE_PADS) do
        if usable(engine[name]) then pads[#pads + 1] = engine[name] end
    end
    source.pads, source.devices.p = pads, pads[1]
    source.ready = source.devices.k ~= nil
    return source.ready and source or nil
end
mbm.engine_source = engine_source

-- The pads connected this frame (a pad without a connected function counts as
-- connected): the list and its length, checked at most once per frame.
local function connected_pads()
    if source.connected_frame == state.frame then return source.connected, source.connected_count end
    local pads, connected, count = source.pads, source.connected, 0
    for n = 1, #pads do
        local pad, ok, yes = pads[n], true, true
        if type(pad.connected) == 'function' then ok, yes = pcall(pad.connected) end
        if ok and yes then
            count = count + 1
            connected[count] = pad
        end
    end
    source.connected_frame, source.connected_count = state.frame, count
    return connected, count
end

local function button_down(device, index)
    local ok, value = pcall(device.button, index)
    return ok and (value == true or type(value) == 'number' and value > 0.5)
end

-- Whether an input is held now, read from the engine: a controller button on
-- any connected pad.
local function engine_down(device_code, index)
    if device_code == 'p' then
        local pads, count = connected_pads()
        for n = 1, count do
            if button_down(pads[n], index) then return true end
        end
        return false
    end
    local device = source.devices[device_code]
    return device ~= nil and button_down(device, index)
end

-- The button first pressed this frame on a device (any connected pad for 'p'),
-- or nil.
local function device_any_pressed(device)
    if not device or type(device.any_pressed) ~= 'function' then return nil end
    local ok, index = pcall(device.any_pressed)
    if ok and type(index) == 'number' then return index end
    return nil
end
local function engine_any_pressed(device_code)
    if device_code ~= 'p' then return device_any_pressed(source.devices[device_code]) end
    local pads, count = connected_pads()
    for n = 1, count do
        local index = device_any_pressed(pads[n])
        if index then return index end
    end
    return nil
end

-- Whether the game window has focus: true, false, or nil when the engine does
-- not say.
local function window_focused()
    local engine = rawget(_G, 'stingray')
    local window = type(engine) == 'table' and engine.Window
    if type(window) ~= 'table' or type(window.has_focus) ~= 'function' then return nil end
    local ok, focused = pcall(window.has_focus)
    if ok and type(focused) == 'boolean' then return focused end
    return nil
end

-- One physical input's state, read from the engine at most once per frame:
-- sample_frame[key] is the frame it was read in, sample_down[key] its state.
local sample_frame, sample_down = {}, {}
local function input_down(input)
    local key = input.key
    if sample_frame[key] == state.frame then return sample_down[key] end
    local down = engine_down(input.device, input.index)
    sample_frame[key], sample_down[key] = state.frame, down
    return down
end

-- An author's binding spec: nil (none), a button name, or a list of
-- alternatives, each a button name or {button = name, device = 'keyboard' |
-- 'mouse' | 'controller', modifiers = {names}, trigger = 'press' | 'release' |
-- 'hold'}. {} means no keys. Returns {{device, names = {main, modifiers...},
-- trigger}...}, or nil when spec is not one.
-- {button, modifiers...}, or nil when modifiers is not a list of names that fits.
local function spec_names(button, modifiers)
    local names = {button}
    if modifiers == nil then return names end
    if type(modifiers) ~= 'table' then return nil end
    for m = 1, #modifiers do
        if type(modifiers[m]) ~= 'string' or modifiers[m] == '' or #names >= MAX_INPUTS then return nil end
        names[#names + 1] = modifiers[m]
    end
    return names
end

-- One alternative of a spec as {device, names, trigger}, or nil.
local function spec_alternative(alternative)
    if type(alternative) == 'string' then alternative = {button = alternative} end
    if type(alternative) ~= 'table' or type(alternative.button) ~= 'string' or alternative.button == '' then
        return nil
    end
    local device = DEVICE_CODES[alternative.device or 'keyboard']
    local trigger = alternative.trigger or 'press'
    if not device or not SUPPORTED_DEVICE[device] or not TRIGGERS[trigger] then return nil end
    local names = spec_names(alternative.button, alternative.modifiers)
    return names and {device = device, names = names, trigger = trigger}
end

local function parse_spec(spec)
    if type(spec) == 'string' then spec = {spec} end
    if type(spec) ~= 'table' or #spec > MAX_ALTERNATIVES then return nil end
    local alternatives = {}
    for index = 1, #spec do
        alternatives[index] = spec_alternative(spec[index])
        if not alternatives[index] then return nil end
    end
    return alternatives
end
mbm.parse_spec = parse_spec

-- An input the evaluator reads: {device, index, key}.
local function make_input(device, index)
    return {device = device, index = index, key = DEVICE_KEYS[device] * 65536 + index}
end

-- A parsed spec's alternatives as file alternatives ({inputs = {{device, index}},
-- trigger}), the names looked up through the engine; nil and the first name
-- the engine does not know (or 'input not ready').
local function resolve_spec(alternatives)
    local engine = engine_source()
    if not engine then return nil, 'input not ready' end
    local resolved = {}
    for index, alternative in ipairs(alternatives) do
        local inputs = {}
        for position, name in ipairs(alternative.names) do
            local device = position == 1 and alternative.device or MODIFIER_DEVICE[alternative.device]
            local table_ = engine.devices[device]
            local ok, id = false, nil
            if table_ then ok, id = pcall(table_.button_id, name) end
            if not ok or type(id) ~= 'number' or id < 0 or id > 65535 or id % 1 ~= 0 then return nil, name end
            inputs[position] = {device = device, index = id}
        end
        resolved[index] = {inputs = inputs, trigger = alternative.trigger}
    end
    return resolved
end

-- The evaluator's copy of file alternatives: inputs with their keys, and per
-- alternative whether it was held when last evaluated.
local function runtime_alternatives(alternatives)
    local copies = {}
    for index, alternative in ipairs(alternatives) do
        local inputs = {}
        for position, input in ipairs(alternative.inputs) do inputs[position] = make_input(input.device, input.index) end
        copies[index] = {inputs = inputs, trigger = alternative.trigger, hold = alternative.trigger == 'hold',
                         press = alternative.trigger == 'press', was = false}
    end
    return copies
end

local unresolved_logged = {}
-- The author's default as the evaluator's alternatives; nil while the engine
-- has no input tables. A default naming a button the engine does not know
-- starts without keys (logged once).
local function default_alternatives(record)
    if not record.spec then return {} end
    local resolved, problem = resolve_spec(record.spec)
    if resolved then return runtime_alternatives(resolved) end
    if problem == 'input not ready' then return nil end
    if not unresolved_logged[record.id] then
        unresolved_logged[record.id] = true
        note('Default of ' .. record.id .. ' names a button the engine does not know ("' .. problem ..
             '"); the binding starts without keys.')
    end
    return {}
end

-- Sets record.alternatives from the saved binding or the author's default.
-- False while the engine has no input tables yet: saved alternatives are read
-- through them too.
local function resolve(record)
    if not engine_source() then return false end
    local store = load_extended()
    local saved = store.records[record.id]
    record.inactive = store.newer or saved ~= nil and saved.kind == 'unknown'
    local alternatives
    if record.inactive or saved and saved.kind == 'cleared' then
        alternatives = {}
    elseif saved and saved.kind == 'set' then
        alternatives = runtime_alternatives(saved.alternatives)
    else
        alternatives = default_alternatives(record)
    end
    record.alternatives = alternatives
    return alternatives ~= nil
end

-- Whether an extended binding is satisfied this frame (see the top of this
-- file), at most one evaluation per frame. state.suppressed (a key capture on
-- a binding page) makes it false, inputs still read so a key held through the
-- capture fires no press afterwards. After a change (record.epoch behind
-- state.input_epoch) the first evaluation only records which inputs are held.
-- Whether one alternative fires this frame, its held state recorded for the
-- next; after a change (resync) press and release only record it.
local function alternative_fires(alternative, resync)
    local inputs, held = alternative.inputs, true
    for i = 1, #inputs do
        if not input_down(inputs[i]) then
            held = false
            break
        end
    end
    local was = alternative.was
    alternative.was = held
    if alternative.hold then return held end
    if resync then return false end
    if alternative.press then return held and not was end
    return was and not held
end

local function extended_down(record)
    if record.frame == state.frame then return record.down end
    record.frame = state.frame
    if not record.alternatives and not resolve(record) then
        record.down = false
        return false
    end
    local resync = record.epoch ~= state.input_epoch
    record.epoch = state.input_epoch
    local alternatives, down = record.alternatives, false
    -- Every alternative is evaluated, so each records its held state.
    for a = 1, #alternatives do
        if alternative_fires(alternatives[a], resync) then down = true end
    end
    record.down = down and not state.suppressed
    return record.down
end

local function sort_extended()
    table.sort(state.extended_order, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.position < b.position
    end)
end

-- Registers id as an extended binding. spec: parse_spec's result or nil.
local function register_extended(record_fields, spec, reason)
    local store = load_extended()
    local id = record_fields.id
    if not store.records[id] and not store.newer then
        store.records[id], store.dirty = {kind = 'default'}, true
    end
    local record = record_fields
    record.extended, record.spec = true, spec
    state.extended_count = state.extended_count + 1
    record.position = state.extended_count
    state.registry[id] = record
    state.extended_order[#state.extended_order + 1] = record
    sort_extended()
    note('Registered ' .. id .. ' as an extended binding (' .. reason .. ') under ' .. record.category .. '.')
    return true
end

local function extended_known(id)
    return load_extended().records[id] ~= nil
end

-- ModBindingsMenu.set_binding(id, spec): the keys of an extended binding, as a
-- player would choose them on the MODS tab. spec as parse_spec; {} removes
-- every key (the author's default no longer applies), nil restores the
-- author's default. Returns true, or false and a reason. Saved from the step.
local function set_binding(id, spec)
    local record = state.registry[id]
    if not record or not record.extended then return false, 'not an extended binding' end
    local store = load_extended()
    if store.newer then return false, 'the bindings file is from a newer version' end
    local entry
    if spec == nil then
        entry = {kind = 'default'}
    else
        local parsed = parse_spec(spec)
        if not parsed then return false, 'invalid binding' end
        local resolved, problem = resolve_spec(parsed)
        if not resolved then
            return false, problem == 'input not ready' and problem or 'unknown button: ' .. problem
        end
        entry = #resolved == 0 and {kind = 'cleared'} or {kind = 'set', alternatives = resolved}
    end
    store.records[id], store.dirty = entry, true
    state.bindings_version = state.bindings_version + 1
    record.alternatives, record.frame, record.epoch = nil, nil, nil
    return true
end

-- Stores file alternatives captured on the page: the same as set_binding with
-- inputs that are already engine indices.
local function store_alternatives(id, alternatives)
    local record = state.registry[id]
    local store = load_extended()
    if not record or not record.extended or store.newer then return false end
    store.records[id] = #alternatives == 0 and {kind = 'cleared'} or {kind = 'set', alternatives = alternatives}
    store.dirty, state.bindings_version = true, state.bindings_version + 1
    record.alternatives, record.frame, record.epoch = nil, nil, nil
    return true
end

-- An extended binding's current keys as file alternatives ({inputs = {{device,
-- index}...}, trigger}), new tables; nil before engine input exists.
local function current_alternatives(id)
    local record = state.registry[id]
    if not record or not record.extended then return nil end
    if not record.alternatives and not resolve(record) then return nil end
    local list = {}
    for index, alternative in ipairs(record.alternatives) do
        local inputs = {}
        for position, input in ipairs(alternative.inputs) do
            inputs[position] = {device = input.device, index = input.index}
        end
        list[index] = {inputs = inputs, trigger = alternative.trigger}
    end
    return list
end

local function engine_text(input, field)
    local engine = engine_source()
    local device = engine and engine.devices[input.device]
    if device and type(device[field]) == 'function' then
        local ok, name = pcall(device[field], input.index)
        if ok and type(name) == 'string' and name ~= '' then return name end
    end
    return nil
end

-- The engine's name of an input (what set_binding takes).
local function input_name(input)
    return engine_text(input, 'button_name') or DEVICE_NAMES[input.device] .. ' ' .. input.index
end

-- The name the player reads: the engine's localized name, else its name.
local function input_label(input)
    return engine_text(input, 'button_locale_name') or input_name(input)
end

-- ModBindingsMenu.binding(id): an extended binding's keys as
-- {{device, button, modifiers = {...}, trigger}...} with the engine's button
-- names ({} without keys), nil for any other id or before engine input exists.
local function binding(id)
    local record = state.registry[id]
    if not record or not record.extended then return nil end
    if not record.alternatives and not resolve(record) then return nil end
    local list = {}
    for index, alternative in ipairs(record.alternatives) do
        local modifiers = {}
        for position = 2, #alternative.inputs do modifiers[position - 1] = input_name(alternative.inputs[position]) end
        list[index] = {device = DEVICE_NAMES[alternative.inputs[1].device], button = input_name(alternative.inputs[1]),
                       modifiers = modifiers, trigger = alternative.trigger}
    end
    return list
end

-- ModBindingsMenu.binding_info(id): nil when not registered, else
-- {backend = 'native', slot} or {backend = 'extended', state = 'default' |
-- 'set' | 'cleared' | 'inactive'}.
local function binding_info(id)
    local record = state.registry[id]
    if not record then return nil end
    if not record.extended then return {backend = 'native', slot = record.slot} end
    local store = load_extended()
    local saved = store.records[id]
    local status = 'default'
    if store.newer or saved and saved.kind == 'unknown' then status = 'inactive'
    elseif saved and saved.kind ~= 'default' then status = saved.kind end
    return {backend = 'extended', state = status}
end

mbm.register_extended, mbm.extended_known, mbm.extended_down = register_extended, extended_known, extended_down
mbm.set_binding, mbm.store_alternatives, mbm.binding, mbm.binding_info = set_binding, store_alternatives, binding,
                                                                         binding_info
mbm.input_name, mbm.input_label, mbm.make_input, mbm.input_down = input_name, input_label, make_input, input_down
mbm.engine_down, mbm.engine_any_pressed, mbm.window_focused = engine_down, engine_any_pressed, window_focused
mbm.current_alternatives = current_alternatives
mbm.EXTENDED_DEVICES, mbm.EXTENDED_TRIGGERS, mbm.DEVICE_KEYS = EXTENDED_DEVICES, EXTENDED_TRIGGERS, DEVICE_KEYS

-- Machine code: only the per-frame evaluation (extended_down,
-- alternative_fires, input_down, engine_down, button_down, connected_pads) may
-- be compiled; registration, lookups, the capture's reads and the file run
-- interpreted.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({usable, engine_source, device_any_pressed, engine_any_pressed, window_focused, spec_names,
                         spec_alternative, parse_spec, default_alternatives, make_input, resolve_spec,
                         runtime_alternatives, resolve, sort_extended, register_extended, extended_known,
                         set_binding, store_alternatives, current_alternatives, engine_text, input_name,
                         input_label, binding, binding_info}) do
        jit.off(fn)
    end
end
