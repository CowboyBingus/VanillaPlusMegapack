-- The idle gate against v2.3: the published step (tests/reference/
-- mod_bindings_menu_v2.3.lua, origin/main's src/mod_bindings_menu.lua at
-- 39a6da8; the other src files are unchanged since then and shared) and the
-- gated step run side by side, each on its own simulated game and its own
-- settings folder, with one simulated engine (keyboard, mouse, two pads), over
-- 3,000 scripted frames: idle stretches, key presses on native and extended
-- bindings, binding pages opening and closing on every tab (MORE MODS
-- included), other screens on top, missions starting and ending, native and
-- extended registrations (on an open page too), restored and changed binding
-- lists, device changes (the game re-parses its input configuration into the
-- live map: the fixed slots' keyboard defaults must be added again; a
-- controller plugged in or out: extended bindings follow it), settings resets
-- (the defaults map re-parsed), extended bindings set by another mod, a key
-- capture started away from the page, the UI state moving and its old memory
-- freed, an update below raising (pause and resume), a row label taken by
-- another mod, an occupied MODS title slot and every kind of dt. After each
-- frame both binding maps, every native write and call, log line, is_down and
-- poll answer, the revision, the guard's state and the extended bindings'
-- state must be equal; every 100 frames the assignments and bindings files too.
-- Then, timed: after a device change the keyboard defaults come back on the
-- same frame in both, by the sweep within 2 seconds (the gate never delays
-- it) or at once when a mod reads the binding; a settings reset likewise; a
-- controller plugged in while the gate answers is read on the next frame; a
-- binding page opened on the frame the UI state moves is seen on that frame.
-- Last: idle frames allocate nothing (interpreted and compiled), and no trace
-- in the mod aborts on idle frames (control: v2.3 aborts there).
local here = arg[0]:match('^(.*[/\\])') or './'
local root = here .. '..'
local NEW, OLD = root .. '/src/mod_bindings_menu.lua', here .. 'reference/mod_bindings_menu_v2.3.lua'
local ffi = require('ffi')
ffi.cdef [[
void *mbm_gate_VirtualAlloc(void *address, size_t size, unsigned int type, unsigned int protect) __asm__("VirtualAlloc");
int mbm_gate_VirtualFree(void *address, size_t size, unsigned int type) __asm__("VirtualFree");
int mbm_gate_memcmp(const void *a, const void *b, size_t size) __asm__("memcmp");
int mbm_gate_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
]]
local kernel = ffi.load('kernel32')
local temp = assert(os.getenv('TEMP') or os.getenv('TMP'))
local FILES = {'ModBindingsMenu.assignments', 'ModBindingsMenu.bindings'}
local function remove_files(directory)
    for _, name in ipairs(FILES) do
        for _, suffix in ipairs({'', '.bak', '.tmp', '.damaged'}) do os.remove(directory .. '/' .. name .. suffix) end
    end
end

local Text = dofile(root .. '/src/bingus_text.lua')
local function load_files()
    _G.mbm_files = setmetatable({}, {__index = function(files, name)
        local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
        rawset(files, name, chunk)
        return chunk
    end})
end
local function put32(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function get32(address) return tonumber(ffi.cast('uint32_t *', address)[0]) end
local function put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
local function get64(address) return ffi.cast('uint64_t *', address)[0] end
local function addr(cdata) return tonumber(ffi.cast('uint64_t', cdata)) end
local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local function internal(fn, wanted, seen)
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
        local value = internal(inner, wanted, seen)
        if value ~= nil then return value end
    end
    return nil
end

-- The simulated engine, shared by both instances (the same physical input):
-- held buttons per device, and whether each pad is connected.
local KEYS = {g = 71, h = 72, j = 74, f9 = 120, ['left ctrl'] = 162, tab = 9, enter = 13, esc = 27, delete = 46,
              space = 32}
local MOUSE = {left = 0, right = 1}
local PAD = {a = 12, b = 13, x = 14, left_shoulder = 8}
local held = {k = {}, m = {}, p1 = {}, p2 = {}}
local plugged = {p1 = true, p2 = false}
local function device(code, ids)
    return {
        button = function(index) return held[code][index] and 1 or 0 end,
        button_id = function(name) return ids[name] end,
        button_name = function(index)
            for name, id in pairs(ids) do if id == index then return name end end
            return nil
        end,
        any_pressed = function() return nil end,
        pressed = function() return false end,
        connected = plugged[code] ~= nil and function() return plugged[code] end or nil,
    }
end
_G.stingray = {Keyboard = device('k', KEYS), Mouse = device('m', MOUSE), Pad1 = device('p1', PAD),
               Pad2 = device('p2', PAD)}

-- 20-byte mappings: device in the low nibble of the flags.
local function mapping(device_code, key)
    return string.char(device_code + 0x40, 0xff, 0x00, 0x10) .. string.char(key, 0, 0, 0) .. string.rep('\0', 12)
end
local CLICK, PAD_A, PAD_B, F5 = mapping(4, 1), mapping(2, 9), mapping(2, 10), mapping(3, 63)
local H_KEY = mapping(3, 0x48)
-- The six fixed slots' stock lists, as the game parses them from its own
-- content/input (build 25480438, read live; tests/test_keyboard_defaults.lua).
local function hex(text)
    return (text:gsub('%x%x', function(byte) return string.char(tonumber(byte, 16)) end))
end
local function hex_list(text)
    local out = {}
    for index = 1, #text / 40 do out[index] = hex(text:sub(index * 40 - 39, index * 40)) end
    return out
end
local STOCK = {
    [12 * 65536 + 1] = hex_list('41ff60000000000000000000000000000000000042ffc00010000000000000000000000000000000' ..
                                '43ffd0003e00000000000000000000000000000044ff000020000000000000000000000000000000'),
    [10 * 65536 + 1] = hex_list('41ff00000a0000000000000000000000cdcc4c3e42ffa0001b0000000000000000000000cdcc4c3e' ..
                                '43ff8006990000000000000000000000cdcc4c3e'),
    [10 * 65536 + 4] = hex_list('41ff8800040000000800000000000000cdcc4c3e42ff0800140000000800000000000000cdcc4c3e' ..
                                '43ff7806980000000800000000000000cdcc4c3e'),
    [10 * 65536 + 8] = hex_list('41ffd800090000000800000000000000cdcc4c3e42fff800130000000800000000000000cdcc4c3e' ..
                                '43ff98069a0000000800000000000000cdcc4c3e'),
    [10 * 65536 + 9] = hex_list('41ff5800010000000800000000000000cdcc4c3e42ffd800110000000800000000000000cdcc4c3e' ..
                                '43ff6806970000000800000000000000cdcc4c3e'),
    [10 * 65536 + 14] = hex_list('41ff7800020000000800000000000000cdcc4c3e42ffe800120000000800000000000000cdcc4c3e' ..
                                 '43ff0006910000000000000000000000cdcc4c3e'),
}
local FIXED_CODES = {12 * 65536 + 1, 10 * 65536 + 1, 10 * 65536 + 4, 10 * 65536 + 8, 10 * 65536 + 9, 10 * 65536 + 14}
-- The list the game's configuration gives an action: the stock list on the
-- fixed slots, developer defaults (a pad button and a click) elsewhere.
local function shipped(code) return STOCK[code] or {PAD_A, CLICK} end
local DORMANT -- {group, action, label} of every dormant action, from the module.

-- One simulated game: image (labels, UI pointers, slots), input owner, binding
-- maps, a UI state block (VirtualAlloc, so it can be freed), menu, screen and
-- the mission-mode record.
local SCREEN_SIZE = 338344 + 2411940
local function new_game()
    local g = {image = ffi.new('uint8_t[?]', 0x3480000), owner = ffi.new('uint8_t[?]', 687000),
               live = ffi.new('uint8_t[?]', 256 * 328), defaults = ffi.new('uint8_t[?]', 256 * 328),
               menu = ffi.new('uint8_t[?]', 216), screen = ffi.new('uint8_t[?]', SCREEN_SIZE),
               mission = ffi.new('uint8_t[?]', 0x44), calls = {}, record = {}, blocks = {}}
    g.base = addr(g.image)
    g.screen_address = addr(g.screen)
    g.bar, g.listing = g.screen_address + 1248, g.screen_address + 338344
    put32(g.base + 0x3310210, 0x8d70f451); put32(g.base + 0x3310214, 0xf15e5c60); put32(g.base + 0x3310218, 0x00847feb)
    local owner = addr(g.owner)
    put64(g.base + 0x347cf18, owner)
    put64(owner + 686800, addr(g.live)); put32(owner + 686808, 256)
    put64(owner + 686968, addr(g.defaults)); put32(owner + 686976, 256)
    for index, entry in ipairs(DORMANT) do
        local code = entry[1] * 65536 + entry[2]
        g.record[code] = (index + 10) * 328
        put32(g.base + 0x26438a0 + (entry[1] * 97 + entry[2]) * 4, entry[3])
        put32(addr(g.live) + g.record[code], code)
        put32(addr(g.defaults) + g.record[code], code)
    end
    put64(g.base + 0x347ce38, addr(g.menu))
    put64(addr(g.menu) + 208, g.screen_address)
    put32(g.bar + 57448, 3); put32(g.bar + 57452, 1)
    -- On the ship: the record's +8 is zero, +0x40 keeps the last mission's mode.
    put64(g.base + 0x33266a0, addr(g.mission))
    put32(addr(g.mission) + 0x40, 2)
    return g
end
-- The UI state block: a fresh one (copying the stack of the last), made current.
local function move_ui(g)
    local block = kernel.mbm_gate_VirtualAlloc(nil, 0x5000, 0x3000, 4)
    assert(block ~= nil, 'VirtualAlloc failed')
    local address = addr(block)
    if g.ui then ffi.copy(ffi.cast('uint8_t *', address + 0x429c), ffi.cast('uint8_t *', g.ui + 0x429c), 24) end
    g.blocks[#g.blocks + 1] = block
    g.ui = address
    put64(g.base + 0x347ce28, address)
end
local function free_old_ui(g)
    for index = #g.blocks - 1, 1, -1 do
        if g.blocks[index] then
            assert(kernel.mbm_gate_VirtualFree(g.blocks[index], 0, 0x8000) ~= 0)
            g.blocks[index] = false
        end
    end
end
-- The screen stack: types bottom to top.
local function stack(g, types)
    for index = 0, 4 do put32(g.ui + 0x429c + index * 4, types[index + 1] or 0) end
    put32(g.ui + 0x429c + 20, #types)
end
local function record_address(g, map, code) return addr(map == 'live' and g.live or g.defaults) + g.record[code] end
local function set_mappings(g, map, code, list)
    local record = record_address(g, map, code)
    put32(record + 4, #list)
    ffi.fill(ffi.cast('uint8_t *', record + 8), 320)
    for index, blob in ipairs(list) do ffi.copy(ffi.cast('uint8_t *', record + 8 + (index - 1) * 20), blob, 20) end
end
local function mapping_count(g, map, code) return get32(record_address(g, map, code) + 4) end
local function mission(g, on) put32(addr(g.mission) + 8, on and 1 or 0); put32(addr(g.mission) + 0x40, on and 1 or 2) end
-- The game re-parses its input configuration into a map.
local function reparse(g, map, codes)
    for _, code in ipairs(codes) do set_mappings(g, map, code, shipped(code)) end
end

-- One instance of a source on its own game, with its own log, settings folder
-- and update chain. below.raise makes the update below it raise once. The
-- loader's log folder is always set while an instance runs, so no settings
-- file outside the test's folders is ever read or written.
local function use(inst) _G.CowboyBingusModLoader = inst.loader end
local function load_instance(path, name, g)
    _G.ModBindingsMenu, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    load_files()
    local inst = {lines = {}, game = g, below = {}, name = name}
    inst.directory = temp .. '/mbm-test-idle-gate-' .. name
    kernel.mbm_gate_CreateDirectoryA(inst.directory, nil)
    remove_files(inst.directory)
    inst.loader = {log_directory = inst.directory, open_log = function()
        return {write = function(_, text) inst.lines[#inst.lines + 1] = text end, flush = function() end}
    end}
    use(inst)
    _G.update = function()
        if inst.below.raise then
            inst.below.raise = false
            error('below')
        end
    end
    dofile(path)
    inst.api, inst.update = _G.ModBindingsMenu, _G.update
    inst.status = _G.BingusRuntime.statuses.ModBindingsMenu
    local st = upvalue(inst.api.register_binding, 'state')
    inst.state, inst.mbm = st, assert(internal(inst.api.register_binding, 'mbm'), 'missing upvalue mbm')
    -- The build check passes; native input activates on the first frame (its
    -- function pointers, then the keyboard defaults), and the native list
    -- functions are replaced by recorders after it (install_natives).
    st.initialized, st.base = true, g.base
    -- Counted reads.
    local function find(fn, seen)
        seen = seen or {}
        if seen[fn] then return nil end
        seen[fn] = true
        for index = 1, 80 do
            local n, value = debug.getupvalue(fn, index)
            if n == nil then break end
            if n == 'kernel32' then return fn, index, value end
            if type(value) == 'function' then
                local f, i, v = find(value, seen)
                if f then return f, i, v end
            end
        end
    end
    local holder_fn, holder_index, real = find(inst.update)
    if not holder_fn then holder_fn, holder_index, real = find(inst.api.is_down) end
    inst.reads = 0
    -- Counting wrappers made once (a closure per call would allocate).
    local wrapped = {}
    for _, key in ipairs({'MBM_read_at', 'MBM_ReadProcessMemory'}) do
        local fn = real[key]
        wrapped[key] = function(...) inst.reads = inst.reads + 1 return fn(...) end
    end
    debug.setupvalue(holder_fn, holder_index, setmetatable(wrapped, {__index = function(_, key) return real[key] end}))
    return inst
end
-- The native list functions as recorders on the simulated game.
local function install_natives(inst)
    local st, g = inst.state, inst.game
    assert(type(st.build_rows) == 'cdata', 'native input activated')
    st.build_rows = function(target, rows)
        local listing = addr(target)
        assert(listing == g.listing)
        local count = get32(listing + 2411928)
        local list = {}
        put32(listing + 2411916, count)
        for index = 0, count - 1 do
            local row = listing + 7856 + 24784 * index
            local group, action, header = rows[index * 3], rows[index * 3 + 1], rows[index * 3 + 2]
            put32(row + 24752, header ~= 0 and 4 or 1)
            put32(row + 4264 + 272, header)
            put32(row + 24760, header ~= 0 and 0xffffffff or group * 65536 + action)
            list[#list + 1] = group .. ':' .. action .. ':' .. header
        end
        g.calls[#g.calls + 1] = 'build ' .. table.concat(list, ',')
    end
    st.set_tab_labels = function(target, labels, count)
        assert(addr(target) == g.bar)
        local list = {}
        for index = 0, count - 1 do list[#list + 1] = labels[index] end
        put32(g.bar + 57448, count)
        for index = 0, 7 do put32(g.bar + 11004 + 3400 * index, index < count and 1 or 0) end
        g.calls[#g.calls + 1] = 'tabs ' .. table.concat(list, ',')
    end
    st.reset_list = function(_, tab) g.calls[#g.calls + 1] = 'reset ' .. tab end
    inst.mbm.consume_action = function(_, code) g.calls[#g.calls + 1] = 'consume ' .. tostring(code) end
end

-- The dormant action table, from a throwaway load (labels per action).
do
    _G.ModBindingsMenu, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    load_files()
    _G.CowboyBingusModLoader = {log_directory = temp}
    _G.update = function() end
    dofile(NEW)
    local step = upvalue(_G.update, 'step')
    DORMANT = upvalue(upvalue(step, 'initialize'), 'DORMANT_ACTIONS')
end

-- Registrations: Ship Station Hotkeys' six fixed slots, two automatic ones
-- (one with a text function), one that registers later on an open page, and
-- extended bindings (press, hold with a modifier, a controller button, release;
-- one registers later, away from the page).
local SHIP = {{'cowboybingus.galactic_menu', 0xb46c8096, 1}, {'cowboybingus.armory', 0x19e97f02, 3},
              {'cowboybingus.control_center', 'Control Center', 4}, {'cowboybingus.ship_management', 0x2716885e, 5},
              {'cowboybingus.stratagem_hero', 'Stratagem Hero', 6}, {'cowboybingus.hellpod', 0xe89a91ef, 7}}
local AUTO = {{'test.auto_one', 'Auto One'}, {'test.auto_two', function() return 'Auto Two' end}}
local LATE = {'test.late', 'Late Binding'}
local EXTENDED = {
    {'ext.press', 'Ext Press', {backend = 'extended', category = 'Extra', default = 'g'}},
    {'ext.hold', function() return 'Ext Hold' end,
     {backend = 'extended', category = 'Extra', default = {{button = 'h', trigger = 'hold', modifiers = {'left ctrl'}}}}},
    {'ext.pad', 'Ext Pad', {backend = 'extended', category = 'Extra', default = {{button = 'a', device = 'controller'}}}},
    {'ext.release', 'Ext Release', {backend = 'extended', category = 'Other', default = {{button = 'f9', trigger = 'release'}}}},
}
local EXT_LATE = {'ext.late', 'Ext Late', {backend = 'extended', category = 'Late', default = 'j'}}

local old_game, new_game_ = new_game(), new_game()
local games = {old_game, new_game_}
for _, g in ipairs(games) do move_ui(g); stack(g, {1}) end
-- The game parsed its configuration into both maps at startup.
for _, g in ipairs(games) do
    for _, entry in ipairs(DORMANT) do
        local code = entry[1] * 65536 + entry[2]
        set_mappings(g, 'live', code, shipped(code))
        set_mappings(g, 'defaults', code, shipped(code))
    end
end
local old = load_instance(OLD, 'old', old_game)
local new = load_instance(NEW, 'new', new_game_)
local instances = {old, new}
local ids = {}
for _, inst in ipairs(instances) do
    use(inst)
    for _, binding in ipairs(SHIP) do
        assert(inst.api.register_binding(binding[1], binding[2], binding[3], {category = 'Ship Station Hotkeys'}))
    end
    for _, binding in ipairs(AUTO) do assert(inst.api.register_binding(binding[1], binding[2])) end
    for _, binding in ipairs(EXTENDED) do assert(inst.api.register_binding(binding[1], binding[2], nil, binding[3])) end
    inst.polled = {}
end
for _, binding in ipairs(SHIP) do ids[#ids + 1] = binding[1] end
for _, binding in ipairs(AUTO) do ids[#ids + 1] = binding[1] end
for _, binding in ipairs(EXTENDED) do ids[#ids + 1] = binding[1] end
local USED = {}
for _, id in ipairs(ids) do
    local record = old.state.registry[id]
    if not record.extended then USED[#USED + 1] = record.code end
end

-- What one instance shows after a frame: compared field by field.
local function slot_text(g, rva)
    local pointer = get64(g.base + rva)
    if pointer == 0 then return '0' end
    if pointer < 0x10000 then return 'raw ' .. tostring(pointer) end
    return ffi.string(ffi.cast('const char *', pointer))
end
local SLOT_RVAS = {0x3327550}
for rva = 0x3328230, 0x3328488, 8 do SLOT_RVAS[#SLOT_RVAS + 1] = rva end
local function same_memory(a, b, size, what)
    assert(ffi.C.mbm_gate_memcmp(ffi.cast('const void *', a), ffi.cast('const void *', b), size) == 0, what)
end
local STATE_FIELDS = {'page_open', 'page_visited', 'sweep_timer', 'last_tab', 'title_active', 'revision',
                      'defaults_pending', 'language', 'empty_text', 'frame', 'input_epoch', 'suppressed',
                      'extended_count', 'bindings_version', 'in_mission', 'mission_check', 'save_problem',
                      'keyboard_pending', 'more_text', 'more_header_text'}
local function compare(frame, results)
    local a, b = old_game, new_game_
    same_memory(a.base + 0x26438a0, b.base + 0x26438a0, 13 * 97 * 4, frame .. ': action label table')
    same_memory(a.live, b.live, 256 * 328, frame .. ': live binding map')
    same_memory(a.defaults, b.defaults, 256 * 328, frame .. ': defaults map')
    same_memory(a.screen, b.screen, SCREEN_SIZE, frame .. ': binding page memory')
    for _, rva in ipairs(SLOT_RVAS) do
        assert(slot_text(a, rva) == slot_text(b, rva), frame .. ': text slot ' .. string.format('%x', rva))
    end
    assert(#a.calls == #b.calls, frame .. ': native calls')
    for index = 1, #a.calls do assert(a.calls[index] == b.calls[index], frame .. ': native call ' .. index) end
    assert(#old.lines == #new.lines, frame .. ': log lines ' .. #old.lines .. ' vs ' .. #new.lines ..
           ' (' .. tostring(new.lines[#new.lines]) .. ' / ' .. tostring(old.lines[#old.lines]) .. ')')
    for index = 1, #old.lines do assert(old.lines[index] == new.lines[index], frame .. ': log line ' .. index) end
    if results then
        for key, value in pairs(results[1]) do
            assert(results[2][key] == value, frame .. ': answer ' .. key .. ' ' .. tostring(value) .. ' vs ' ..
                   tostring(results[2][key]))
        end
    end
    local s, t = old.state, new.state
    for _, field in ipairs(STATE_FIELDS) do
        assert(s[field] == t[field], frame .. ': state.' .. field .. ' ' .. tostring(s[field]) .. ' vs ' ..
               tostring(t[field]))
    end
    for _, code in ipairs(USED) do
        assert(s.swept_counts[code] == t.swept_counts[code], frame .. ': swept count')
    end
    local phase_a, id_a = old.mbm.capture_phase()
    local phase_b, id_b = new.mbm.capture_phase()
    assert(phase_a == phase_b and id_a == id_b, frame .. ': key capture ' .. phase_a .. ' vs ' .. phase_b)
    assert(old.status.state == new.status.state and old.status.pauses == new.status.pauses
           and old.status.errors == new.status.errors, frame .. ': guard ' .. old.status.state .. ' vs ' .. new.status.state)
end
local function read_file(name)
    local file = io.open(name, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end
local function compare_files(frame)
    for _, name in ipairs(FILES) do
        local a = read_file(old.directory .. '/' .. name)
        local b = read_file(new.directory .. '/' .. name)
        assert(a == b, frame .. ': ' .. name)
    end
end

-- One frame for both: the game's events, then each instance's update (and an
-- update below that may raise), then (unless quiet) Ship Station Hotkeys'
-- is_down calls and a poll of every binding, as mods read them each frame.
local covered = {moves = 0, frees = 0, pages = 0, hijacks = 0, released = 0, late = 0, device_changes = 0,
                 resets = 0, plugs = 0, sets = 0, captures = 0, missions = 0, extended_down = 0, more = 0}
local function run_frame(frame, dt, event, quiet)
    if event then for _, g in ipairs(games) do event(g) end end
    local results = {}
    for index, inst in ipairs(instances) do
        use(inst)
        local r = {}
        local before = inst.reads
        local ok, err = pcall(inst.update, dt)
        inst.frame_reads = inst.reads - before
        inst.update_reads = (inst.update_reads or 0) + inst.frame_reads
        if inst.frame_reads == 1 then inst.one_read_frames = (inst.one_read_frames or 0) + 1 end
        if type(inst.state.build_rows) == 'cdata' then install_natives(inst) end
        r.update = ok and 'ok' or tostring(err):match('below') and 'below' or tostring(err)
        if not quiet then
            for i, id in ipairs(ids) do r['is_down ' .. i] = tostring(inst.api.is_down(id)) end
            local done = inst.api.poll(ids, inst.polled)
            r.poll = tostring(done)
            for i = 1, #ids do
                for _, field in ipairs({'down', 'pressed', 'released', 'last'}) do
                    r[field .. i] = tostring(inst.polled[field][i])
                end
            end
            for i, id in ipairs(ids) do
                if inst.state.registry[id].extended then
                    local info = inst.api.binding_info(id)
                    r['info ' .. i] = info and info.state or 'nil'
                    if index == 1 and inst.polled.down[i] == true then covered.extended_down = covered.extended_down + 1 end
                end
            end
        end
        r.revision, r.ready, r.count = inst.api.revision, tostring(inst.api.ready()), inst.api.extended.count
        results[index] = r
    end
    compare(frame, results)
end
-- An API call another mod makes between frames, on both instances: the same answer.
local function call_both(label, fn)
    local answers = {}
    for index, inst in ipairs(instances) do
        use(inst)
        local ok, problem = fn(inst)
        answers[index] = tostring(ok) .. ' ' .. tostring(problem)
    end
    assert(answers[1] == answers[2], label .. ': ' .. answers[1] .. ' vs ' .. answers[2])
    return answers[1]
end

-- The script: a seeded generator picks events; some are fixed.
local seed = 12345
local function random(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return math.floor(seed / 65536) % n + 1 -- the high bits: an LCG's low bits repeat quickly
end
local FRAMES = 3000
local RAISE_FRAMES = {[700] = true, [1650] = true, [2400] = true}
local page_open, page_frames, closed_frames = false, 0, 0
local OTHER_SCREENS = {1, 5, 14, 15, 3}
local hijacked = nil
local late_registered, ext_late_registered = false, false
local KEY_NAMES = {'g', 'h', 'left ctrl', 'f9', 'j'}
local SPECS = {'j', {}, false, {{button = 'b', device = 'controller'}}, {{button = 'g', modifiers = {'left ctrl'}}}}
-- Engine and API events happen once per frame (both instances see them).
local function engine_event()
    local roll = random(12)
    if roll == 1 then
        local name = KEY_NAMES[random(#KEY_NAMES)]
        held.k[KEYS[name]] = not held.k[KEYS[name]] or nil
    elseif roll == 2 then
        local pad = random(2) == 1 and 'p1' or 'p2'
        held[pad][PAD.a] = not held[pad][PAD.a] or nil
    end
end
local function device_change(codes)
    covered.device_changes = covered.device_changes + 1
    -- A controller plugged in or out: the game re-parses its configuration
    -- into the live map (the defaults map stays).
    plugged.p2 = not plugged.p2
    covered.plugs = covered.plugs + 1
    return function(g) reparse(g, 'live', codes) end
end
local function some_codes()
    local codes = {}
    for _, code in ipairs(USED) do if random(2) == 1 then codes[#codes + 1] = code end end
    if #codes == 0 then codes[1] = FIXED_CODES[random(#FIXED_CODES)] end
    return codes
end
for frame = 1, FRAMES do
    local events, dt = {}, 0.016
    local roll = random(100)
    if roll <= 3 then dt = 0 elseif roll <= 5 then dt = 0.033 elseif roll == 6 then dt = 0.5
    elseif roll == 7 then dt = 2 elseif roll == 8 then dt = nil end
    engine_event()
    -- Key presses on the native bindings' state bytes.
    if random(20) == 1 then
        local code = USED[random(#USED)]
        local value = random(2) - 1
        events[#events + 1] = function(g)
            g.owner[808 + 32 * (97 * math.floor(code / 65536) + code % 65536)] = value
        end
    end
    -- Another mod sets an extended binding's keys (saved from the next step).
    if random(150) == 1 then
        local spec = SPECS[random(#SPECS)]
        covered.sets = covered.sets + 1
        call_both('set_binding', function(inst)
            return inst.api.set_binding('ext.press', spec ~= false and spec or nil)
        end)
    end
    -- A key capture started without a page frame (only the MORE MODS panel
    -- starts one in game): the next step ends it, gated or not.
    if random(400) == 1 then
        covered.captures = covered.captures + 1
        call_both('begin_capture', function(inst) return inst.mbm.begin_capture('ext.hold', nil, 'keyboard') end)
    end
    if page_open then
        page_frames = page_frames + 1
        local r = random(100)
        if page_frames > 30 and r <= 4 then
            page_open, closed_frames = false, 0
            local types = {}
            for i = 1, random(3) do types[i] = OTHER_SCREENS[random(#OTHER_SCREENS)] end
            events[#events + 1] = function(g) stack(g, types) end
        elseif r <= 12 then
            local tab = random(5) - 1
            if tab == 4 then covered.more = covered.more + 1 end
            events[#events + 1] = function(g) put32(g.screen_address + 8, tab) end
        elseif r == 13 then
            -- Another screen on top of the page for a moment, then gone.
            events[#events + 1] = function(g)
                local depth = get32(g.ui + 0x429c + 20)
                if depth < 5 then put32(g.ui + 0x429c + depth * 4, 5); put32(g.ui + 0x429c + 20, depth + 1) end
            end
        elseif r == 14 then
            events[#events + 1] = function(g)
                local depth = get32(g.ui + 0x429c + 20)
                if depth > 1 and get32(g.ui + 0x429c + (depth - 1) * 4) == 5 then put32(g.ui + 0x429c + 20, depth - 1) end
            end
        elseif r == 15 and not late_registered then
            late_registered, covered.late = true, covered.late + 1
            for _, inst in ipairs(instances) do
                use(inst)
                assert(inst.api.register_binding(LATE[1], LATE[2]))
            end
            ids[#ids + 1] = LATE[1]
            USED[#USED + 1] = old.state.registry[LATE[1]].code
        elseif r == 16 and not hijacked then
            -- Another mod takes a row label the MODS tab borrowed.
            local code = USED[3]
            hijacked, covered.hijacks = 0x8badf00d, covered.hijacks + 1
            events[#events + 1] = function(g)
                put32(g.base + 0x26438a0 + (math.floor(code / 65536) * 97 + code % 65536) * 4, 0x8badf00d)
            end
        elseif r == 17 then
            -- A device change with a page open: the live lists wait for the
            -- page to close; the defaults (Revert's source) are checked each page frame.
            events[#events + 1] = device_change(some_codes())
        elseif r == 18 then
            covered.resets = covered.resets + 1
            local codes = some_codes()
            events[#events + 1] = function(g) reparse(g, 'defaults', codes) end
        end
    else
        closed_frames = closed_frames + 1
        local r = random(1000)
        if closed_frames > 20 and r <= 12 then
            page_open, page_frames, covered.pages = true, 0, covered.pages + 1
            local depth = random(3)
            local below = {}
            for i = 1, depth - 1 do below[i] = OTHER_SCREENS[random(#OTHER_SCREENS)] end
            below[depth] = 26
            local tab = random(5) - 1
            if tab == 4 then covered.more = covered.more + 1 end
            events[#events + 1] = function(g) stack(g, below); put32(g.screen_address + 8, tab) end
        elseif r <= 20 then
            -- The game restores one list (its count changes).
            local code = USED[random(#USED)]
            events[#events + 1] = function(g) set_mappings(g, 'live', code, shipped(code)) end
        elseif r <= 26 then
            -- The player's list changes without a page (same count as before).
            local code = USED[random(#USED)]
            events[#events + 1] = function(g) set_mappings(g, 'live', code, {F5}) end
        elseif r <= 29 then
            -- A settings reset: the defaults map re-parsed.
            covered.resets = covered.resets + 1
            local codes = some_codes()
            events[#events + 1] = function(g) reparse(g, 'defaults', codes) end
        elseif r <= 31 then
            -- Another developer list in the defaults map.
            local code = USED[random(#USED)]
            events[#events + 1] = function(g) set_mappings(g, 'defaults', code, {PAD_B, CLICK}) end
        elseif r <= 35 then
            -- The UI state moves; sometimes its old memory goes at once.
            local free = random(2) == 1
            covered.moves = covered.moves + 1
            events[#events + 1] = function(g) move_ui(g); if free then free_old_ui(g) end end
        elseif r <= 38 then
            covered.frees = covered.frees + 1
            events[#events + 1] = function(g) free_old_ui(g) end
        elseif r <= 42 then
            -- Other screens come and go.
            local types = {OTHER_SCREENS[random(#OTHER_SCREENS)]}
            if random(2) == 1 then types[2] = OTHER_SCREENS[random(#OTHER_SCREENS)] end
            events[#events + 1] = function(g) stack(g, types) end
        elseif r <= 44 and hijacked then
            -- The other mod lets the label go again.
            local code = USED[3]
            hijacked = nil; covered.released = covered.released + 1
            events[#events + 1] = function(g)
                local entry
                for _, e in ipairs(DORMANT) do if e[1] * 65536 + e[2] == code then entry = e end end
                put32(g.base + 0x26438a0 + (entry[1] * 97 + entry[2]) * 4, entry[3])
            end
        elseif r == 45 then
            -- The MODS title slot taken by someone else, or freed again.
            local value = random(2) == 1 and 1234 or 0
            events[#events + 1] = function(g)
                if not (value == 0 and get64(g.base + 0x3328420) > 0x10000) then put64(g.base + 0x3328420, value) end
            end
        elseif r <= 50 then
            -- A device change: the game re-parses its configuration into the
            -- live map (the six fixed slots get their stock lists back), and a
            -- controller is plugged in or out.
            events[#events + 1] = device_change(some_codes())
        elseif r <= 52 then
            -- A mission starts or ends (read when a binding page opens).
            covered.missions = covered.missions + 1
            local on = random(2) == 1
            events[#events + 1] = function(g) mission(g, on) end
        elseif r == 53 and not ext_late_registered then
            ext_late_registered = true
            for _, inst in ipairs(instances) do
                use(inst)
                assert(inst.api.register_binding(EXT_LATE[1], EXT_LATE[2], nil, EXT_LATE[3]))
            end
            ids[#ids + 1] = EXT_LATE[1]
        end
    end
    -- An update below raises (the menu pauses, resumes after 60 clean frames).
    -- (fixed frames: the eighth such error of a burst would stop the menu)
    if RAISE_FRAMES[frame] then for _, inst in ipairs(instances) do inst.below.raise = true end end
    run_frame(frame, dt, #events > 0 and function(g) for _, event in ipairs(events) do event(g) end end or nil)
    if frame % 100 == 0 then compare_files(frame) end
end
-- The run must have covered every kind of frame.
local function count(lines, text)
    local n = 0
    for _, line in ipairs(lines) do if line:find(text, 1, true) then n = n + 1 end end
    return n
end
assert(count(old.lines, "Filled MODS tab") > 0 and count(old.lines, 'Added native MODS tab') > 0, 'pages opened')
assert(count(old.lines, 'Filled MORE MODS tab') > 0, 'MORE MODS shown')
assert(count(old.lines, 'Removed') > 0, 'sweeps removed restored defaults')
assert(count(old.lines, "Added Mod Bindings Menu's keyboard defaults to 12 binding records.") == 1, 'defaults added')
local again_live = count(old.lines, 'again: the game restored its stock list (live)')
local again_defaults = count(old.lines, 'again: the game restored its stock list (reset defaults)')
assert(again_live > 0 and again_defaults > 0, 'keyboard defaults added again after re-parses')
assert(count(old.lines, 'Key capture ended: page closed.') > 0, 'a capture away from the page ended')
assert(count(old.lines, 'In a mission: MORE MODS not offered.') > 0, 'a page in a mission')
assert(old.status.pauses == 3 and old.status.state == 'running', 'updates below raised; the menu resumed')
assert(covered.pages >= 5 and covered.moves >= 3 and covered.frees >= 2 and covered.hijacks >= 1
       and covered.released >= 1 and covered.late == 1 and covered.device_changes >= 5 and covered.resets >= 3
       and covered.sets >= 5 and covered.captures >= 2 and covered.more >= 2 and covered.extended_down >= 20
       and ext_late_registered, 'scenario coverage')
assert(count(old.lines, 'Registered ' .. LATE[1]) == 1, 'a binding registered on an open page')
-- A row label another mod holds keeps the full step running, as in v2.3, until
-- a page visit takes it back (in this script frames 600-2600 or so), so a
-- quarter of the frames is the floor here.
assert(new.one_read_frames > FRAMES / 4, 'frames gated: ' .. tostring(new.one_read_frames))
compare_files('end')
print(string.format('Equivalence with v2.3 over %d frames (%d binding pages, %d device changes with %d keyboard ' ..
                    'defaults added again in the live map and %d in the defaults map, %d settings resets, %d ' ..
                    'extended bindings set, %d UI moves): maps, writes, native calls, log lines, is_down, poll, ' ..
                    'extended state, revision, guard and both files equal OK (update reads: v2.3 %d, gated %d; ' ..
                    '%d one-read frames)', FRAMES, covered.pages, covered.device_changes, again_live, again_defaults,
                    covered.resets, covered.sets, covered.moves, old.update_reads, new.update_reads,
                    new.one_read_frames))

-- Timed: the keyboard defaults' re-apply after a device change. Nothing else
-- happens on these frames and no mod reads a binding, so only the sweep can
-- re-apply them: the gate answers every frame until the sweep is due and runs
-- it on the very frame v2.3 does, at most 2 seconds of frame time after the
-- change. Then the same with Ship Station Hotkeys reading its bindings: at
-- once, on the frame of the change. A settings reset (the defaults map):
-- at the next sweep, the same frame in both.
local DT = 0.016
local BOUND = math.ceil(2 / DT) + 1
-- Back to quiet: no key held, the MODS title slot free, row labels another mod
-- took given back and a short visit to the MODS tab (the menu takes its labels
-- again and returns them on closing: a label left in another mod's hands keeps
-- the full step running, in both), then frames without a page.
local function settle(frames, quiet)
    for _, inst in ipairs(instances) do inst.below.raise = false end
    held.k, held.p1, held.p2 = {}, {}, {}
    for _, g in ipairs(games) do
        for _, entry in ipairs(DORMANT) do
            local address = g.base + 0x26438a0 + (entry[1] * 97 + entry[2]) * 4
            if get32(address) == 0x8badf00d then put32(address, entry[3]) end
        end
        if get64(g.base + 0x3328420) < 0x10000 then put64(g.base + 0x3328420, 0) end
        stack(g, {1, 26})
        put32(g.screen_address + 8, 3)
    end
    for frame = 1, 5 do run_frame('settle, MODS tab ' .. frame, DT, nil, quiet) end
    for _, g in ipairs(games) do stack(g, {1}) end
    for frame = 1, frames do run_frame('settle ' .. frame, DT, nil, quiet) end
end
-- Whether any fixed slot's record in map still holds the stock list exactly
-- (once the default is added again, its keyboard mapping differs).
local function fixed_stock(g, map)
    for _, code in ipairs(FIXED_CODES) do
        local record = record_address(g, map, code)
        if mapping_count(g, map, code) == #STOCK[code]
           and ffi.string(ffi.cast('const char *', record + 8), 20 * #STOCK[code]) == table.concat(STOCK[code]) then
            return true
        end
    end
    return false
end
-- Waits for a sweep frame (the gated instance reads more than once) and then
-- for the gate to answer again (after the assignments are saved), so the next
-- change meets an almost full two-second timer.
local function after_sweep()
    local swept = false
    for frame = 1, BOUND + 10 do
        run_frame('waiting for a sweep ' .. frame, DT, nil, true)
        if new.frame_reads > 1 then swept = true elseif swept then return end
    end
    error('no sweep within 2 seconds')
end
local function timed(map, label)
    after_sweep()
    assert(upvalue(upvalue(new.update, 'step'), 'idle_armed'), 'the gate is armed')
    local codes = map == 'live' and FIXED_CODES or {10 * 65536 + 8}
    for _, g in ipairs(games) do reparse(g, map, codes) end
    local gated = 0
    for frame = 1, BOUND + 10 do
        run_frame(label .. ' ' .. frame, DT, nil, true)
        if not fixed_stock(new_game_, map) then
            assert(not fixed_stock(old_game, map), label .. ': both re-applied on the same frame')
            assert(frame <= BOUND, label .. ': re-applied after ' .. frame .. ' frames')
            assert(gated == frame - 1, label .. ': the gate answered every frame before the sweep (' .. gated .. ')')
            return frame
        end
        assert(fixed_stock(old_game, map), label .. ': v2.3 re-applied first')
        if new.frame_reads == 1 then gated = gated + 1 end
    end
    error(label .. ': not re-applied')
end
settle(200, false)
local live_frames = timed('live', 'device change, sweep')
local defaults_frames = timed('defaults', 'settings reset, sweep')
-- With Ship Station Hotkeys reading its bindings each frame: is_down sees the
-- changed mapping count and sweeps at once, on the frame of the change.
for _, g in ipairs(games) do reparse(g, 'live', FIXED_CODES) end
run_frame('device change, bindings read', DT)
assert(not fixed_stock(old_game, 'live') and not fixed_stock(new_game_, 'live'), 'added again on the frame of the change')
print(string.format('Keyboard defaults after a device change: added again on the same frame as v2.3, by the sweep ' ..
                    'after %d frames of %.3f s (bound: 2 s of frame time, %d frames), at once when a mod reads ' ..
                    'its binding; after a settings reset by the sweep after %d frames OK', live_frames, DT, BOUND,
                    defaults_frames))

-- A controller plugged in while the gate answers: an extended binding on its
-- button reads it on the next frame (the frame number grows on idle frames
-- too, so the connected pads are read again), and unplugged, it lets go.
local pad_index
for i, id in ipairs(ids) do if id == 'ext.pad' then pad_index = i end end
call_both('restore ext.pad', function(inst) return inst.api.set_binding('ext.pad', nil) end)
settle(30, false)
plugged.p1, plugged.p2 = false, false
settle(5, false)
assert(new.frame_reads == 1, 'the gate answers')
plugged.p2, held.p2[PAD.a] = true, true
run_frame('controller plugged in, A held', DT)
assert(new.frame_reads == 1, 'gated frame')
for _, inst in ipairs(instances) do
    assert(inst.polled.down[pad_index] == true and inst.polled.pressed[pad_index] == true, inst.name .. ': pad press read')
end
plugged.p2 = false
run_frame('controller unplugged', DT)
for _, inst in ipairs(instances) do
    assert(inst.polled.down[pad_index] == false and inst.polled.released[pad_index] == true, inst.name .. ': pad gone')
end
plugged.p1, held.p2 = true, {}
print('A controller plugged in and out while the gate answers: extended bindings follow it on the next frame, as in v2.3 OK')

-- The UI state moves (its old memory still readable, showing no page) and a
-- binding page is on top of the new one on that same frame: both see it at
-- once, since the gate loads the UI state pointer on every frame.
settle(200, false)
assert(upvalue(upvalue(new.update, 'step'), 'idle_armed'), 'the gate is armed')
run_frame('UI state moved, a binding page on top', 0, function(g)
    move_ui(g) -- the old block keeps its stack (no page)
    stack(g, {1, 26})
    put32(g.screen_address + 8, 0)
end)
assert(old.state.page_open and new.state.page_open, 'both see the page on the frame it opens')
for frame = 1, 30 do run_frame('page after the move ' .. frame, 0.016) end
print('UI state moved with a binding page on top: seen on that frame, as in v2.3 OK')

-- Idle frames of the gated step allocate nothing, interpreted and compiled,
-- and the step's own code starts no trace that aborts (v2.3: the MODS title
-- check's closures (UCLO) and the step under pcall abort on every idle frame).
local util = require('jit.util')
-- No page and nothing left to give back: a row label another mod still holds
-- keeps the full step running (and its reads allocating, as in v2.3), so it
-- is let go first.
local function quiet_settle(inst)
    use(inst)
    stack(inst.game, {1})
    for _, entry in ipairs(DORMANT) do
        local address = inst.game.base + 0x26438a0 + (entry[1] * 97 + entry[2]) * 4
        if get32(address) == 0x8badf00d then put32(address, entry[3]) end
    end
    for _ = 1, 300 do inst.update(0.016) end
end
local function garbage(inst, compiled)
    quiet_settle(inst)
    if not compiled then jit.off() end
    jit.flush()
    for _ = 1, 2000 do inst.update(0) end -- warm-up (traces, one state table rehash)
    -- Trace objects live in the GC heap too, and a side trace may form in any
    -- window (once); per-frame garbage would grow every window. Up to 4
    -- windows of 600 frames: one must stay at 0.
    local bytes
    for _ = 1, 4 do
        collectgarbage('collect')
        collectgarbage('stop')
        local start = collectgarbage('count')
        for _ = 1, 600 do inst.update(0) end
        bytes = (collectgarbage('count') - start) * 1024
        collectgarbage('restart')
        if bytes == 0 then break end
    end
    jit.on()
    return bytes
end
assert(garbage(new, false) == 0, 'idle frames allocated (interpreted)')
assert(garbage(new, true) == 0, 'idle frames allocated (compiled)')
local new_step = upvalue(new.update, 'step')
for _, name in ipairs({'idle', 'mods_title', 'away_frame'}) do
    local fn = internal(new_step, name)
    assert(fn and not util.funcinfo(fn).children, name .. ' creates a closure')
end
assert(not util.funcinfo(new_step).children, 'step creates a closure')
-- Trace aborts in the mod's own files over 3000 frames of dt; abort sites by
-- line and reason code.
local OWN = {'mod_bindings_menu', 'sweep.lua', 'poll.lua', 'assignments.lua', 'extended.lua', 'extended_store.lua',
             'capture.lua', 'panel.lua'}
local function own(source)
    for _, name in ipairs(OWN) do if source:find(name, 1, true) then return true end end
    return false
end
local function aborts(inst, dt)
    quiet_settle(inst)
    jit.flush()
    local n, sites = 0, {}
    local function on_trace(what, _, fn, pc, code)
        if what == 'abort' and own(util.funcinfo(fn).source or '') then
            n = n + 1
            local key = util.funcinfo(fn, pc).currentline .. ':' .. tostring(code)
            sites[key] = (sites[key] or 0) + 1
        end
    end
    -- The guard's update runs from an interpreted loop here, as the game calls it from C.
    local update = inst.update
    local function drive() for _ = 1, 3000 do update(dt) end end
    jit.off(drive)
    jit.attach(on_trace, 'trace')
    local ok, err = pcall(drive)
    jit.attach(on_trace)
    assert(ok, tostring(err))
    local list = {}
    for key, k in pairs(sites) do list[#list + 1] = key .. ' x' .. k end
    table.sort(list)
    return n, table.concat(list, ', ')
end
if jit and jit.attach and jit.status() then
    -- Idle frames without a sweep (dt 0): none may abort; v2.3 aborts there
    -- (the MODS title check's UCLO, the step returning into pcall).
    local control, control_sites = aborts(old, 0)
    local n, sites = aborts(new, 0)
    assert(control > 0, 'control: v2.3 idle frames did not abort, so this check proves nothing')
    assert(n == 0, n .. ' trace aborts in gated idle frames: ' .. sites .. ' (v2.3: ' .. control_sites .. ')')
    -- With a sweep every 2 s (dt 1/60), for the record.
    local old_sweeps, old_sites = aborts(old, 1 / 60)
    local new_sweeps, new_sites = aborts(new, 1 / 60)
    print('Idle frames: no allocation (interpreted and compiled), no closures; trace aborts in 3000 idle frames: ' ..
          'gated 0, v2.3 ' .. control .. ' (' .. control_sites .. '); with sweeps: gated ' .. new_sweeps .. ' (' ..
          new_sites .. '), v2.3 ' .. old_sweeps .. ' (' .. old_sites .. ') OK')
end
for _, inst in ipairs(instances) do remove_files(inst.directory) end
