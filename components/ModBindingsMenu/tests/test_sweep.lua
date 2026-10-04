-- The binding sweep against simulated binding maps: inherited developer
-- defaults are cleared once per action, with provenance in the assignments
-- file; afterwards the player's mappings are kept, also ones equal to a
-- developer default, and only a list the game restored is cleaned again.
-- Actions no binding uses this session are never touched.
local here = arg[0]:match('^(.*[/\\])') or './'
local root = here .. '..'
local source = root .. '/src/mod_bindings_menu.lua'
local ffi = require('ffi')
ffi.cdef [[int mbm_test_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");]]
local directory = assert(os.getenv('TEMP') or os.getenv('TMP')) .. '/mbm-test-sweep'
ffi.load('kernel32').mbm_test_CreateDirectoryA(directory, nil)
local path = directory .. '/ModBindingsMenu.assignments'
local function remove_files()
    for _, suffix in ipairs({'', '.bak', '.tmp'}) do os.remove(path .. suffix) end
end
local function read_file(name)
    local file = io.open(name, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end
local function write_file(name, text)
    local file = assert(io.open(name, 'wb'))
    assert(file:write(text))
    assert(file:close())
end

-- Simulated game: the image (labels, UI pointers), the input owner and its two
-- binding maps of 256 records {code, count, 16 x 20-byte mappings}.
local image = ffi.new('uint8_t[?]', 0x3480000)
local base = tonumber(ffi.cast('uint64_t', image))
local function put32(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function get32(address) return tonumber(ffi.cast('uint32_t *', address)[0]) end
local function put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
local owner = ffi.new('uint8_t[?]', 687000)
local live_map, default_map = ffi.new('uint8_t[?]', 256 * 328), ffi.new('uint8_t[?]', 256 * 328)
local owner_address = tonumber(ffi.cast('uint64_t', owner))
put64(base + 0x347cf18, owner_address)
put64(owner_address + 686800, ffi.cast('uint64_t', live_map))
put32(owner_address + 686808, 256)
put64(owner_address + 686968, ffi.cast('uint64_t', default_map))
put32(owner_address + 686976, 256)
-- The UI: the binding page (screen type 26) on top of the stack, or not. Its
-- tab bar never has the three native tabs here, so the MODS tab is not built.
local ui_memory, menu_memory, screen_memory = ffi.new('uint8_t[?]', 0x429c + 24), ffi.new('uint8_t[?]', 216),
                                              ffi.new('uint8_t[?]', 60000)
local ui = tonumber(ffi.cast('uint64_t', ui_memory))
put64(base + 0x347ce28, ui)
put64(base + 0x347ce38, tonumber(ffi.cast('uint64_t', menu_memory)))
put64(tonumber(ffi.cast('uint64_t', menu_memory)) + 208, tonumber(ffi.cast('uint64_t', screen_memory)))
put32(ui + 0x429c + 20, 1)
local function page(open) put32(ui + 0x429c, open and 26 or 1) end
page(false)

local Text = dofile(root .. '/src/bingus_text.lua')
-- The other source files: the build places them ahead of the main file as
-- the functions in the local mbm_files; here mbm_files loads src/<name>.lua.
_G.mbm_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})
-- Records: the 36 dormant actions at scattered buckets of both maps.
local position = {}
local function record(map, group, action)
    return tonumber(ffi.cast('uint64_t', map)) + position[group * 65536 + action] * 328
end
local function set_mappings(address, list)
    put32(address + 4, #list)
    ffi.fill(ffi.cast('uint8_t *', address + 8), 320)
    for index, blob in ipairs(list) do ffi.copy(ffi.cast('uint8_t *', address + 8 + (index - 1) * 20), blob, 20) end
end
local function get_mappings(address)
    local list = {}
    for index = 0, get32(address + 4) - 1 do
        list[#list + 1] = ffi.string(ffi.cast('uint8_t *', address + 8 + index * 20), 20)
    end
    return list
end
local function same(list, expected)
    if #list ~= #expected then return false end
    for index = 1, #list do
        if list[index] ~= expected[index] then return false end
    end
    return true
end
-- A 20-byte mapping: flags (device, Button, any device slot, trigger), key,
-- two unset bytes, the trigger again, combine, threshold.
local PRESS, HOLD, LONG_PRESS, REPEAT = 0, 2, 3, 8
local function mapping(device, key, trigger, padding)
    trigger = trigger or PRESS
    local cell = ffi.new('uint8_t[20]')
    ffi.cast('uint32_t *', cell)[0] = device + 0x40 + 0xff00 + trigger * 0x10000 + key * 0x100000
    ffi.cast('uint16_t *', cell + 4)[0] = key
    cell[6] = padding or 0
    ffi.cast('uint32_t *', cell + 8)[0] = trigger
    return ffi.string(cell, 20)
end
local KEYBOARD, MOUSE, XBOX, DUALSHOCK = 3, 2, 5, 6
-- Shipped defaults like input.config's (Mod Bindings Menu's own Tab on slot 1).
local tab, left_click = mapping(KEYBOARD, 76), mapping(MOUSE, 1)
local cross, xbox_a = mapping(DUALSHOCK, 9), mapping(XBOX, 9)
local DEFAULTS = {
    [12 * 65536 + 1] = {cross, xbox_a, tab, left_click},                                    -- slot 1
    [12 * 65536 + 0] = {mapping(DUALSHOCK, 12, LONG_PRESS), mapping(XBOX, 12, LONG_PRESS),
                        mapping(KEYBOARD, 77), mapping(KEYBOARD, 1, LONG_PRESS)},           -- slot 2
    [10 * 65536 + 0] = {mapping(DUALSHOCK, 3, HOLD), mapping(XBOX, 3, HOLD), mapping(KEYBOARD, 81, HOLD)},
    [10 * 65536 + 2] = {mapping(DUALSHOCK, 4, REPEAT), mapping(XBOX, 4, REPEAT), mapping(KEYBOARD, 80, REPEAT)},
    [10 * 65536 + 3] = {mapping(KEYBOARD, 79)},                                             -- numpad 1
    [9 * 65536 + 0] = {mapping(KEYBOARD, 17, HOLD), mapping(KEYBOARD, 72, HOLD)},          -- W, Up
}
-- Both maps with every dormant action's shipped defaults, as a fresh install.
local function reset_maps(dormant)
    local used, seed = {}, 7
    for _, entry in ipairs(dormant) do
        local code = entry[1] * 65536 + entry[2]
        repeat seed = (seed * 37 + 11) % 256 until not used[seed]
        used[seed], position[code] = true, seed
        for _, map in ipairs({live_map, default_map}) do
            put32(record(map, entry[1], entry[2]), code)
            set_mappings(record(map, entry[1], entry[2]), DEFAULTS[code] or {})
        end
    end
end

-- A fresh Mod Bindings Menu on the simulated game, its log captured, the
-- native list calls stubbed. Its update runs one frame.
local lines = {}
local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local function session()
    _G.ModBindingsMenu, _G.BingusTranslations = nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
    _G.update, _G.BingusRuntime = function() end, nil
    dofile(source)
    local menu = ModBindingsMenu
    local st = upvalue(menu.register_binding, 'state')
    st.initialized, st.base = true, base
    st.build_rows, st.set_tab_labels, st.reset_list = function() end, function() end, function() end
    return menu, st, update
end
local function logged(text, from)
    local found = 0
    for index = from or 1, #lines do
        if lines[index]:find(text, 1, true) then found = found + 1 end
    end
    return found
end
local function live(group, action) return get_mappings(record(live_map, group, action)) end
local function set_live(group, action, list) set_mappings(record(live_map, group, action), list) end
local SWEEP = 2 -- a frame time that makes the sweep due

remove_files()
local menu, st, frame = session()
reset_maps(upvalue(upvalue(upvalue(frame, 'step'), 'initialize'), 'DORMANT_ACTIONS'))
assert(menu.register_binding('map', 0xb46c8096, 1))
for index = 1, 3 do assert(menu.register_binding('auto.' .. index, 'Auto ' .. index)) end
assert(st.registry['auto.1'].code == 10 * 65536 and st.registry['auto.3'].code == 10 * 65536 + 3)

-- First use (a fresh install: every list is the shipped defaults). The
-- inherited developer defaults go, Mod Bindings Menu's own Tab stays, and the
-- assignments file records each action's provenance (saved on the next frame).
local from = #lines + 1
frame(SWEEP)
assert(same(live(12, 1), {tab}) and #live(10, 0) == 0 and #live(10, 2) == 0 and #live(10, 3) == 0)
assert(logged('Removed 10 inherited developer mappings.', from) == 1)
frame(0)
local saved = read_file(path)
for _, action in ipairs({'12:1', '10:0', '10:2', '10:3'}) do
    assert(saved:find('\naction ' .. action .. ' cleared 1 found %x+ left %x+\n'), action .. ' provenance')
end
-- Actions no binding uses are never touched: Freeflight's W and Up stay (a
-- free-cam mod may read them), as does slot 2 with nothing registered on it.
assert(same(live(9, 0), DEFAULTS[9 * 65536]) and same(live(12, 0), DEFAULTS[12 * 65536]))
assert(not saved:find('action 9:0', 1, true) and not saved:find('action 12:0', 1, true))
print('First use: inherited developer defaults cleared once, provenance saved, unused actions untouched OK')

-- The audit's reproduction (2026-10-03): a keyboard mapping equal to the
-- action's shipped default, chosen on a binding page, was deleted. Now the
-- player's mappings stay: left click beside Tab on slot 1, Hold numpad 5 on
-- auto.1 (one of its developer defaults), and a new key set off the page.
page(true)
frame(0.016)
set_live(12, 1, {tab, left_click})
set_live(10, 0, {mapping(KEYBOARD, 81, HOLD)})
frame(0.016)
page(false)
frame(SWEEP)
assert(same(live(12, 1), {tab, left_click}) and same(live(10, 0), {mapping(KEYBOARD, 81, HOLD)}))
set_live(10, 2, {mapping(KEYBOARD, 44)})
frame(SWEEP)
assert(same(live(10, 2), {mapping(KEYBOARD, 44)}))
-- A RepeatInterval button the page cannot produce still becomes Press.
set_live(10, 2, {mapping(KEYBOARD, 44), mapping(XBOX, 4, REPEAT)})
frame(SWEEP)
assert(same(live(10, 2), {mapping(KEYBOARD, 44), mapping(XBOX, 4, PRESS)}))
-- Later sweeps change nothing more and write nothing.
frame(0)
local text = read_file(path)
for _ = 1, 3 do frame(SWEEP) end
assert(read_file(path) == text and same(live(12, 1), {tab, left_click}))
print('The audit\'s reproduction: the player\'s mappings stay, also ones equal to a developer default OK')

-- One action changed on a binding page into a single mapping a capture can
-- make, equal to its only default (numpad 1 on auto.3): the player's choice.
page(true)
frame(0.016)
set_live(10, 3, DEFAULTS[10 * 65536 + 3])
page(false)
from = #lines + 1
frame(SWEEP)
assert(same(live(10, 3), DEFAULTS[10 * 65536 + 3]) and logged('Kept the single mapping chosen for auto.3', from) == 1)
frame(0)
print('A single capture equal to the only default, after a binding page: the player\'s choice OK')

-- The next session. The game's saved settings bring the player's lists back,
-- but auto.1's shipped defaults return: cleaned again. Numpad 1 on auto.3 is
-- the list the sweep left: kept.
local menu2, st2, frame2 = session()
assert(menu2.register_binding('map', 0xb46c8096, 1))
for index = 1, 3 do assert(menu2.register_binding('auto.' .. index, 'Auto ' .. index)) end
set_live(10, 0, DEFAULTS[10 * 65536])
frame2(SWEEP)
assert(#live(10, 0) == 0 and same(live(10, 3), DEFAULTS[10 * 65536 + 3]) and same(live(12, 1), {tab, left_click}))
assert(st2.assignments.session == 2)
print('Next session: the lists the sweep left are remembered; returning defaults are cleaned again OK')

-- A Revert on a binding page restores every action's shipped defaults at once:
-- they are cleaned again, Tab stays. auto.3 is back at numpad 1, its default
-- and the list the player chose: unchanged, so it stays.
page(true)
frame2(0.016)
for _, code in ipairs({12 * 65536 + 1, 10 * 65536, 10 * 65536 + 2, 10 * 65536 + 3}) do
    set_live(math.floor(code / 65536), code % 65536, DEFAULTS[code])
end
page(false)
frame2(SWEEP)
assert(same(live(12, 1), {tab}) and #live(10, 0) == 0 and #live(10, 2) == 0)
assert(same(live(10, 3), DEFAULTS[10 * 65536 + 3]))
-- A config re-parse off the page restores slot 1's defaults: is_down has them
-- swept before it answers.
set_live(12, 1, DEFAULTS[12 * 65536 + 1])
assert(menu2.is_down('map') == false and same(live(12, 1), {tab}))
print('A Revert and a config re-parse: restored defaults are cleaned again OK')

-- A saved settings file from v1 kept slot 1's developer extras next to the
-- player's F2. The first use clears the extras; when the old file restores the
-- same list in a later session, it is cleaned again.
remove_files()
local f2, click_saved = mapping(KEYBOARD, 60), mapping(MOUSE, 1, PRESS, 0x7f)
set_live(12, 1, {xbox_a, f2, click_saved})
local menu3, _, frame3 = session()
assert(menu3.register_binding('map', 0xb46c8096, 1))
frame3(SWEEP)
frame3(0)
assert(same(live(12, 1), {f2}))
set_live(12, 1, {xbox_a, f2, click_saved})
local menu4, _, frame4 = session()
assert(menu4.register_binding('map', 0xb46c8096, 1))
frame4(SWEEP)
assert(same(live(12, 1), {f2}), 'the old saved list restored again is cleaned again')
-- The player adds left click: kept.
set_live(12, 1, {f2, left_click})
frame4(SWEEP)
assert(same(live(12, 1), {f2, left_click}))
print('An old saved settings list: cleaned at first use and whenever it comes back OK')

-- A binding absent this session keeps its action and its keys: nobody sweeps
-- them. When it registers late, its list is as it left it.
remove_files()
local menu5, st5, frame5 = session()
assert(menu5.register_binding('late.a', 'Late A') and st5.registry['late.a'].code == 10 * 65536)
frame5(SWEEP)
set_live(10, 0, {mapping(KEYBOARD, 30), mapping(KEYBOARD, 81, HOLD)})
frame5(SWEEP)
frame5(0)
local menu6, st6, frame6 = session()
assert(menu6.register_binding('other.b', 'Other B') and st6.registry['other.b'].code == 10 * 65536 + 2)
for _ = 1, 3 do frame6(SWEEP) end
assert(same(live(10, 0), {mapping(KEYBOARD, 30), mapping(KEYBOARD, 81, HOLD)}), 'an absent binding\'s keys stay')
assert(menu6.register_binding('late.a', 'Late A') and st6.registry['late.a'].code == 10 * 65536)
frame6(SWEEP)
assert(same(live(10, 0), {mapping(KEYBOARD, 30), mapping(KEYBOARD, 81, HOLD)}), 'and stay once it registers late')
print('A binding absent or late this session keeps its action and its keys OK')

-- An action handed over from an expired binding is cleared entirely, also
-- when the game quit before the sweep: the mark is in the assignments file.
remove_files()
write_file(path, 'format 2\nsession 41\nheir\t10\t0\t41\naction 10:0 clear\nend\n')
local menu7, st7, frame7 = session()
assert(menu7.register_binding('heir', 'Heir') and st7.registry.heir.code == 10 * 65536)
assert(st7.assignments.actions[10 * 65536].clear)
frame7(SWEEP)
assert(#live(10, 0) == 0 and not st7.assignments.actions[10 * 65536].clear)
frame7(0)
assert(read_file(path):find('\naction 10:0 cleared 42 found %x+ left %x+\n'))
print('An action handed over from an expired binding is cleared entirely, also after a restart OK')

-- revision grows once when native input becomes ready (ready() turns true).
local menu8, st8, frame8 = session()
st8.build_rows, st8.set_tab_labels, st8.reset_list = nil, nil, nil
local revision = menu8.revision
assert(not menu8.ready() and revision == 0)
frame8(0)
assert(menu8.ready() and menu8.revision == revision + 1)
frame8(0)
assert(menu8.revision == revision + 1, 'once')
print('revision grows when native input becomes ready OK')
remove_files()
