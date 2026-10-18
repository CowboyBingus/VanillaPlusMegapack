-- Extended bindings (version 4): registrations beyond the 36 native actions,
-- their evaluation from engine input (a simulated stingray.Keyboard and Mouse,
-- every call counted), the nil/false contract, set_binding, binding,
-- binding_info, poll, and backend stability across sessions.
-- Usage: luajit test_extended.lua [path to src/mod_bindings_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local files = {'ModBindingsMenu.assignments', 'ModBindingsMenu.bindings'}
local function remove_files()
    for _, name in ipairs(files) do
        for _, suffix in ipairs({'', '.bak', '.tmp', '.damaged'}) do os.remove(directory .. '/' .. name .. suffix) end
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

-- A simulated engine: buttons by name, which are held, and every call counted.
-- Four pads, two connected; localized names for the keyboard.
local KEYS = {f9 = 1, f10 = 2, g = 3, ['left ctrl'] = 4, ['left shift'] = 5, tab = 6}
local MOUSE = {['left'] = 0, ['right'] = 1}
local PAD = {a = 12, b = 13, left_shoulder = 8}
local LOCALIZED = {[KEYS.g] = 'G-Taste'}
local held = {k = {}, m = {}, p1 = {}, p2 = {}, p3 = {}, p4 = {}}
local calls = {button = 0, button_id = 0, button_name = 0, connected = 0}
local plugged = {p1 = true, p2 = false, p3 = true, p4 = false}
local function device(code, ids)
    local names = {}
    for name, id in pairs(ids) do names[id] = name end
    return {
        button = function(index)
            calls.button = calls.button + 1
            return held[code][index] and 1 or 0
        end,
        button_id = function(name)
            calls.button_id = calls.button_id + 1
            return ids[name]
        end,
        button_name = function(index)
            calls.button_name = calls.button_name + 1
            return names[index]
        end,
        button_locale_name = code == 'k' and function(index) return LOCALIZED[index] end or nil,
        connected = plugged[code] ~= nil and function()
            calls.connected = calls.connected + 1
            return plugged[code]
        end or nil,
    }
end
local engine = {Keyboard = device('k', KEYS), Mouse = device('m', MOUSE), Pad1 = device('p1', PAD),
                Pad2 = device('p2', PAD), Pad3 = device('p3', PAD), Pad4 = device('p4', PAD)}
local function press(name) held.k[KEYS[name]] = true end
local function release(name) held.k[KEYS[name]] = nil end

_G.update = function() end
dofile(source)
local host = assert(ModBindingsMenu)
local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
-- An upvalue of fn or of a function it reaches through its upvalues.
local function deep_upvalue(fn, wanted, seen)
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
        local found = deep_upvalue(inner, wanted, seen)
        if found ~= nil then return found end
    end
    return nil
end
local state = upvalue(host.register_binding, 'state')
local step = upvalue(update, 'step')
local flush_assignments, flush_extended = upvalue(step, 'flush_assignments'), upvalue(step, 'flush_extended')
-- The step's frame number advances once per frame (the build check would stop
-- the update in a test process, so frames are counted here).
local function frame() state.frame = state.frame + 1 end
local function save()
    if state.assignments and state.assignments.dirty then flush_assignments(0) end
    if state.extended_store and state.extended_store.dirty then flush_extended(0) end
end
local function new_session()
    save()
    for _, field in ipairs({'registry', 'used', 'refused'}) do
        for key in pairs(state[field]) do state[field][key] = nil end
    end
    for _, list in ipairs({state.order, state.extended_order}) do
        for index = #list, 1, -1 do list[index] = nil end
    end
    state.assignments, state.extended_store, state.extended_count = nil, nil, 0
    host.extended.count = 0
end
local function read_file(name)
    local file = io.open(directory .. '/' .. name, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end
local function write_file(name, text)
    local file = assert(io.open(directory .. '/' .. name, 'wb'))
    assert(file:write(text))
    assert(file:close())
end

-- Capabilities: api stays 1; version 4 and the extended field describe what
-- extended bindings support.
assert(host.api == 1 and host.version == 4 and host.capacity == 36)
assert(type(host.extended) == 'table' and host.extended.count == 0)
local function listed(list, value)
    for _, item in ipairs(list) do if item == value then return true end end
    return false
end
assert(listed(host.extended.devices, 'keyboard') and listed(host.extended.devices, 'mouse')
       and listed(host.extended.devices, 'controller'))
assert(listed(host.extended.triggers, 'press') and listed(host.extended.triggers, 'hold')
       and listed(host.extended.triggers, 'release'))
print('Capabilities: api 1, version 4, extended devices and triggers OK')

-- Options are checked before anything is assigned.
assert(select(2, host.register_binding('bad.backend', 'Bad', nil, {backend = 'other'})) == 'invalid binding backend')
assert(select(2, host.register_binding('bad.fixed', 'Bad', 1, {backend = 'extended'})) == 'invalid binding backend')
assert(select(2, host.register_binding('bad.default', 'Bad', nil, {default = 12})) == 'invalid binding default')
assert(select(2, host.register_binding('bad.device', 'Bad', nil, {default = {{button = 'f9', device = 'pad'}}}))
       == 'invalid binding default')
assert(select(2, host.register_binding('bad.trigger', 'Bad', nil, {default = {{button = 'f9', trigger = 'tap'}}}))
       == 'invalid binding default')
assert(next(state.registry) == nil and state.assignments == nil, 'refused options assign nothing')
print('Invalid backend and default options are refused before assignment OK')

-- The pool: 7 fixed slots and 29 automatic actions. Beyond them a
-- registration gets an extended binding instead of the v2.2 refusal; with
-- backend 'native' the refusal stays.
for slot = 1, 7 do assert(host.register_binding('fixed.' .. slot, 0x3ef7f7ad, slot)) end
for index = 1, 29 do assert(host.register_binding('auto.' .. index, 'Auto ' .. index)) end
assert(#state.order == 36 and #state.extended_order == 0)
local revision = host.revision
assert(host.register_binding('more.1', 'More 1', nil, {default = 'f9', category = 'More'}))
assert(state.registry['more.1'].extended and #state.extended_order == 1 and host.extended.count == 1)
assert(host.revision == revision + 1, 'an extended registration grows revision')
local ok, why = host.register_binding('native.only', 'Native', nil, {backend = 'native'})
assert(not ok and why == 'all 29 automatic binding actions in use')
-- A v1.1 addon asking for slot 2 while it is held, with the pool full.
assert(host.register_binding('legacy.second', 0x3ef7f7ad, 2) and state.registry['legacy.second'].extended)
-- An explicit request, with the pool full or not.
assert(host.register_binding('explicit', 'Explicit', nil, {backend = 'extended', default = {'g'}}))
-- Identical re-registration is accepted; a different slot is not.
assert(host.register_binding('more.1', 'More 1', nil, {default = 'f9'}))
assert(select(2, host.register_binding('more.1', 'More 1', 3)) == 'binding already registered differently')
-- No limit: a thousand more.
for index = 1, 1000 do assert(host.register_binding('bulk.' .. index, 'Bulk ' .. index)) end
assert(host.extended.count == 1003 and #state.extended_order == 1003)
local info = host.binding_info('more.1')
assert(info.backend == 'extended' and info.state == 'default')
assert(host.binding_info('fixed.1').backend == 'native' and host.binding_info('fixed.1').slot == 1)
assert(host.binding_info('auto.1').backend == 'native' and host.binding_info('nobody') == nil)
print('Beyond 36 native actions registrations get extended bindings (1003 here); backend native keeps the refusal OK')

-- Evaluation. Before the engine has input tables, extended bindings read
-- false, never nil (nil would send Ship Station Hotkeys to its fixed keys).
frame()
assert(host.is_down('more.1') == false and host.is_down('nobody') == nil)
_G.stingray = engine
frame()
-- press: true on the frame F9 goes down, then false while held; release ends it.
assert(host.is_down('more.1') == false)
press('f9')
frame()
assert(host.is_down('more.1') == true)
assert(host.is_down('more.1') == true, 'a second call in the same frame gives the same answer')
frame()
assert(host.is_down('more.1') == false, 'press is one frame')
release('f9')
frame()
assert(host.is_down('more.1') == false)
-- One engine read per physical input per frame, however many bindings and
-- calls use it; nothing read in a frame without queries.
assert(host.set_binding('bulk.1', {'f9'}) and host.set_binding('bulk.2', {{button = 'f9', trigger = 'hold'}}))
frame()
host.is_down('bulk.1')
calls.button = 0
frame()
for _ = 1, 3 do host.is_down('more.1'); host.is_down('bulk.1'); host.is_down('bulk.2') end
assert(calls.button == 1, 'F9 read ' .. calls.button .. ' times')
calls.button = 0
frame()
assert(calls.button == 0, 'no queries, no engine reads')
print('Press is a one-frame pulse; one engine read per input per frame, none without queries OK')

-- hold, release, alternatives and modifiers.
assert(host.set_binding('bulk.3', {{button = 'g', trigger = 'release'}}))
assert(host.set_binding('bulk.4', {'tab', {button = 'g', modifiers = {'left ctrl'}}}))
frame()
for index = 2, 4 do host.is_down('bulk.' .. index) end -- the first look only records what is held
press('f9')
press('g')
frame()
assert(host.is_down('bulk.2') == true and host.is_down('bulk.3') == false)
assert(host.is_down('bulk.4') == false, 'G alone does not satisfy Ctrl+G')
frame()
assert(host.is_down('bulk.2') == true, 'hold stays true while held')
release('g')
frame()
assert(host.is_down('bulk.3') == true, 'release fires on the frame G is released')
press('left ctrl')
press('g')
frame()
assert(host.is_down('bulk.4') == true, 'Ctrl+G')
release('g')
release('left ctrl')
press('tab')
frame()
assert(host.is_down('bulk.4') == true, 'the Tab alternative')
release('tab')
release('f9')
frame()
assert(host.is_down('bulk.2') == false)
print('Hold, release, alternatives and Ctrl+ modifiers OK')

-- A change never produces a press from a key already held: after set_binding
-- the first evaluation only records what is held.
press('g')
frame()
assert(host.set_binding('more.1', {'g'}))
frame()
assert(host.is_down('more.1') == false, 'held through the change: no press')
release('g')
frame()
host.is_down('more.1')
press('g')
frame()
assert(host.is_down('more.1') == true)
release('g')
-- A key capture on a binding page suppresses every mod binding (false, never
-- nil); a key held through it fires no press when it ends.
frame()
host.is_down('more.1')
state.suppressed = true
press('g')
frame()
assert(host.is_down('more.1') == false)
state.suppressed, state.input_epoch = false, state.input_epoch + 1
frame()
assert(host.is_down('more.1') == false, 'held through the capture: no press afterwards')
release('g')
print('No press from a key held through a change or a key capture; suppression reads false OK')

-- set_binding: {} clears (false, not the default), nil restores the default,
-- unknown buttons and bad specs are refused, native ids are not extended.
assert(host.set_binding('explicit', {}) and host.binding_info('explicit').state == 'cleared')
press('g')
frame()
assert(host.is_down('explicit') == false, 'cleared: false, never the default')
release('g')
assert(host.set_binding('explicit', nil) and host.binding_info('explicit').state == 'default')
local listing = host.binding('explicit')
assert(#listing == 1 and listing[1].button == 'g' and listing[1].device == 'keyboard' and listing[1].trigger == 'press')
assert(#host.binding('bulk.4') == 2 and host.binding('bulk.4')[2].modifiers[1] == 'left ctrl')
assert(select(2, host.set_binding('explicit', {'nosuchkey'})) == 'unknown button: nosuchkey')
assert(select(2, host.set_binding('explicit', 5)) == 'invalid binding')
assert(select(2, host.set_binding('auto.1', {'g'})) == 'not an extended binding')
assert(host.binding('auto.1') == nil)
assert(host.set_binding('bulk.5', {{button = 'right', device = 'mouse', trigger = 'hold'}}))
held.m[MOUSE.right] = true
frame()
host.is_down('bulk.5')
assert(host.is_down('bulk.5') == true, 'mouse button')
held.m[MOUSE.right] = nil
print('set_binding clears, restores defaults, refuses unknown buttons and native ids; binding lists names OK')

-- Controller buttons: held on any connected pad (Pad1 and Pad3 here), never
-- on one that is not; each pad's connected check once per frame however many
-- controller inputs are read; a pad plugged in later counts.
assert(host.set_binding('bulk.6', {{button = 'a', device = 'controller', trigger = 'hold'}}))
assert(host.set_binding('bulk.7', {{button = 'b', device = 'controller', modifiers = {'left_shoulder'},
                                     trigger = 'hold'}}))
assert(host.binding('bulk.7')[1].device == 'controller' and host.binding('bulk.7')[1].modifiers[1] == 'left_shoulder')
assert(select(2, host.set_binding('bulk.6', {{button = 'g', device = 'controller'}})) == 'unknown button: g')
held.p2[PAD.a] = true
calls.button, calls.connected = 0, 0
frame()
assert(host.is_down('bulk.6') == false, 'A on a pad that is not connected')
assert(calls.connected == 4 and calls.button == 2, calls.connected .. ' ' .. calls.button)
held.p3[PAD.a], held.p3[PAD.left_shoulder], held.p1[PAD.b] = true, true, true
calls.button, calls.connected = 0, 0
frame()
assert(host.is_down('bulk.6') == true and host.is_down('bulk.7') == true, 'A on Pad3; LB on Pad3 and B on Pad1')
assert(calls.connected == 4, 'one connected check per pad per frame')
held.p3[PAD.a], held.p3[PAD.left_shoulder], held.p1[PAD.b] = nil, nil, nil
plugged.p2 = true
frame()
assert(host.is_down('bulk.6') == true, 'Pad2 plugged in: its held A counts')
held.p2[PAD.a], plugged.p2 = nil, false
frame()
assert(host.is_down('bulk.6') == false)
-- What the panel shows: the engine's localized name when it has one.
local mbm = deep_upvalue(host.register_binding, 'mbm')
assert(mbm.input_label({device = 'k', index = KEYS.g}) == 'G-Taste')
assert(mbm.input_label({device = 'k', index = KEYS.f9}) == 'f9' and mbm.input_label({device = 'p', index = PAD.a}) == 'a')
print('Controller buttons on any connected pad, one connected check per pad per frame, hot-plug OK')

-- poll answers extended bindings as is_down does, with edges.
local polled = {}
local IDS = {'more.1', 'nobody', 'bulk.2'}
frame()
assert(host.poll(IDS, polled))
assert(polled.down[1] == false and polled.down[2] == nil and polled.down[3] == false)
press('g')
press('f9')
frame()
assert(host.poll(IDS, polled))
assert(polled.down[1] == true and polled.pressed[1] and polled.down[3] == true and polled.pressed[3])
frame()
assert(host.poll(IDS, polled))
assert(polled.down[1] == false and polled.released[1] and polled.down[3] == true and not polled.pressed[3])
release('g')
release('f9')
print('poll: extended bindings with edges, unknown ids nil OK')

-- No allocation per frame once a binding is resolved: is_down and poll on
-- extended bindings with inputs changing, interpreted (every window empty) and
-- compiled (median window empty: a trace compiled in a window counts there).
do
    local ids, out, tick = {'more.1', 'bulk.2', 'bulk.4', 'nobody'}, {}, 0
    local ctrl, g, tab = KEYS['left ctrl'], KEYS.g, KEYS.tab
    local keyboard = held.k
    local function one_frame()
        tick = tick + 1
        keyboard[g] = tick % 3 == 0 or nil
        keyboard[ctrl] = tick % 5 < 2 or nil
        keyboard[tab] = tick % 7 == 0 or nil
        state.frame = state.frame + 1
        host.is_down('more.1')
        host.is_down('bulk.4')
        host.poll(ids, out)
    end
    local function run(frames) for _ = 1, frames do one_frame() end end
    local function windows(compiled)
        if compiled then jit.on() else jit.off() end
        jit.flush()
        run(5000)
        collectgarbage('collect')
        collectgarbage('stop')
        local bytes = {}
        for window = 1, 5 do
            local before = collectgarbage('count')
            run(1000)
            bytes[window] = (collectgarbage('count') - before) * 1024
        end
        collectgarbage('restart')
        jit.on()
        table.sort(bytes)
        return bytes
    end
    local interpreted, compiled = windows(false), windows(true)
    for _, index in ipairs({g, ctrl, tab}) do keyboard[index] = nil end
    assert(interpreted[5] == 0, string.format('interpreted frames allocated %d bytes per 1000', interpreted[5]))
    assert(compiled[3] == 0, string.format('compiled frames allocated %d bytes per 1000 (median)', compiled[3]))
end
print('No allocation per frame for extended bindings, interpreted and compiled OK')

-- Persistence and backend stability. In the next session an extended id stays
-- extended and keeps its keys; a native id stays native. The automatic actions
-- stay reserved for their ids, so a new id gets an extended binding where
-- v2.2.1 refused it ('no free binding action...').
new_session()
do
    local text = read_file('ModBindingsMenu.bindings')
    assert(text:find('^format 1\n') and text:find('\nend\n$'), text)
    assert(text:find('\nmore.1\tset\tk:3@press\n', 1, true), text)
    assert(text:find('\nexplicit\tdefault\n', 1, true) and text:find('\nbulk.999\tdefault\n', 1, true))
    assert(text:find('\nbulk.4\tset\tk:6@press|k:3+k:4@press\n', 1, true), text)
end
assert(host.register_binding('more.1', 'More 1', nil, {default = 'f9'}) and state.registry['more.1'].extended)
assert(host.register_binding('auto.1', 'Auto 1') and not state.registry['auto.1'].extended)
assert(host.register_binding('fresh', 'Fresh') and state.registry.fresh.extended, 'reserved pool: extended')
-- The first evaluation after registering only records what is held.
frame()
assert(host.is_down('more.1') == false)
press('g')
frame()
assert(host.is_down('more.1') == true, 'the saved G, not the default F9')
release('g')
-- With a free action a new id is native: a fresh assignments file frees them.
new_session()
remove_files()
assert(host.register_binding('more.1', 'More 1') and not state.registry['more.1'].extended,
       'no bindings file and a free pool: native')
print('Saved bindings persist; extended and native ids keep their backend across sessions OK')
remove_files()
