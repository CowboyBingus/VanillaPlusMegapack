-- Drive the MODS tab against fake escape-menu memory and emulated native calls.
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_options_menu.lua')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
os.remove(directory .. '/ModOptionsMenu.values')
_G.CowboyBingusModLoader = {log_directory = directory}
_G.ModOptionsMenu, _G.update = nil, nil
dofile(source)
local ffi = require('ffi')
local bit = require('bit')
local menu = assert(ModOptionsMenu)

local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local state = upvalue(menu.register_option, 'state')
local step = upvalue(update, 'step')
local function set_upvalue(fn, wanted, value)
    for index = 1, 80 do
        local name = debug.getupvalue(fn, index)
        if name == wanted then debug.setupvalue(fn, index, value); return end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
-- ReadProcessMemory calls per frame and KB allocated over `frames` updates
-- after one settling update, whose long frame also writes any pending value
-- save. The interpreter runs them, so compiled-trace allocation sinking cannot
-- hide garbage; existing traces are flushed first because they embed
-- read_memory as a constant.
local function measure(frames)
    local fill = upvalue(upvalue(step, 'escape_menu'), 'fill')
    local real, reads = upvalue(fill, 'read_memory'), 0
    jit.off()
    jit.flush()
    set_upvalue(fill, 'read_memory', function(...) reads = reads + 1; return real(...) end)
    update(2)
    assert(not state.dirty, 'value save still pending')
    collectgarbage('collect')
    collectgarbage('stop')
    reads = 0
    local before = collectgarbage('count')
    for _ = 1, frames do update(0.016) end
    local garbage = collectgarbage('count') - before
    collectgarbage('restart')
    jit.on()
    set_upvalue(fill, 'read_memory', real)
    return reads / frames, garbage
end

local function address(pointer) return tonumber(ffi.cast('uint64_t', pointer)) end
local function put32(at, value) ffi.cast('uint32_t *', at)[0] = value end
local function get32(at) return tonumber(ffi.cast('uint32_t *', at)[0]) end
local function putf(at, value) ffi.cast('float *', at)[0] = value end
local function getf(at) return tonumber(ffi.cast('float *', at)[0]) end
local function put64(at, value) ffi.cast('uint64_t *', at)[0] = value end
local function get64(at) return tonumber(ffi.cast('uint64_t *', at)[0]) end
local function get8(at) return tonumber(ffi.cast('uint8_t *', at)[0]) end
local function put8(at, value) ffi.cast('uint8_t *', at)[0] = value end

-- Fake game image, UI state, menu system and escape menu screen.
local image = ffi.new('uint8_t[?]', 0x3480000)
local ui_memory = ffi.new('uint8_t[?]', 0x4400)
local menu_memory = ffi.new('uint8_t[?]', 512)
local screen_memory = ffi.new('uint8_t[?]', 3010456 + 1319500)
local base, ui = address(image), address(ui_memory)
local screen = address(screen_memory)
local bar, content = screen + 1248, screen + 3010456
local rows = content + 144000
put64(base + 0x347ce28, ui)
put64(base + 0x347ce38, address(menu_memory))
put64(address(menu_memory) + 200, screen)
local function set_stack(list)
    for index = 0, 4 do put32(ui + 0x429c + 4 * index, list[index + 1] or 0) end
    put32(ui + 0x429c + 20, #list)
end
-- Input owner: this frame's action states, 32 bytes per action (group 0 here).
local input_memory = ffi.new('uint8_t[?]', 808 + 32 * 97)
put64(base + 0x347cf18, address(input_memory))
local APPLY, SELECT, BACK = 12, 10, 9 -- Menu.ExtraOption1 (Tab), Menu.Select, Menu.Back
local function press(action) put8(address(input_memory) + 808 + 32 * action, 1) end
local function release_keys() ffi.fill(input_memory + 808, 32 * 97) end

local TEMPLATE, KEY = 0xc67c7faf, 0xab2a7b35
local TAB_LABELS = {0xd876b36e, 0x78934e12, 0x8c02bd80}
local CATEGORY_LABELS = {0x396f27d7, 0x196248d0, 0xa522d2d0, 0x15cecac1, 0x9a688238,
                         0x07e3b100, 0x5db3b764, 0xa7c345ef, 0x9bb47b92}
local PANELS = {[0] = 1150848, 1179528, 1253248, 1287376, 1153728, 1156616, 1290256, 1293152}
local COUNT_FIELD = {[0] = 2832, 33256, 33256, 2832, 2832, 22352, 2832, 2832}
local SELECTED_FIELD = {[0] = 2872, 33296, 33296, 2872, 2872, 22392, 2880, 2872}
local NATIVE_ROWS = {[0] = 11, 19, 19, 9, 26, 11, 27, 11}
local function row(index) return rows + 31464 * index end
local function panel(index) return content + PANELS[index] end
for index = 0, 7 do put64(panel(index) + 2816, rows) end
-- Description box: frame, title and body; setting caches (requested, shown).
local box = content + 1315800
local frame, title, body = box + 272, box + 936, box + 1632
local DESCRIBED, SHOWN = content + 1318500, content + 1318476
-- The game's unapplied-changes flag and its UNAPPLIED CHANGES dialog (mode 0):
-- state 1 is opening, 2 open, 3 closing; the confirm button (visible flag 0x10)
-- uses Menu.Select, the cancel button Menu.Back.
local UNAPPLIED, dialog = content + 1319449, content + 1296040
local function set_dialog(dialog_state)
    put32(dialog + 19748, 0); put32(dialog + 19752, dialog_state)
    put32(dialog + 4608, 0x10); put32(dialog + 12072, 0); put32(dialog + 12076, SELECT)
    put32(dialog + 12160, 0x10); put32(dialog + 19624, 0); put32(dialog + 19628, BACK)
end
-- The game's input update answering the open dialog before this frame's Lua
-- update (0x1998e00): it closes the dialog, then clears Menu.Select's action
-- state (0x12fde90) whichever button was used; Menu.Back stays set.
local function game_answers(action)
    put32(dialog + 19752, 3)
    if action == BACK then press(BACK) end
end

-- Widgets: children list at +224 sorted by address, sibling at +232.
local function children(parent)
    local list, node = {}, get64(parent + 224)
    while node ~= 0 do list[#list + 1] = node; node = get64(node + 232) end
    return list
end
local function add_child(parent, child)
    local previous, node = nil, get64(parent + 224)
    while node ~= 0 and node < child do previous, node = node, get64(node + 232) end
    put64(child + 240, parent)
    if node == child then return end
    put64(child + 232, node)
    put64(previous and previous + 232 or parent + 224, child)
end
-- Releasing a row detaches it from its parent's list, as the game's own
-- pre-build does for all 32 rows before every panel build.
local function release(child)
    local parent = get64(child + 240)
    if parent ~= 0 then
        local previous, node = nil, get64(parent + 224)
        while node ~= 0 and node ~= child do previous, node = node, get64(node + 232) end
        if node == child then put64(previous and previous + 232 or parent + 224, get64(child + 232)) end
    end
    put64(child + 232, 0)
    put64(child + 240, 0)
end
local function visible(widget) return bit.band(get32(widget), 0x10) ~= 0 end
local function set_visible(widget, on)
    local flags = get32(widget)
    put32(widget, on and bit.bor(flags, 0x10) or bit.band(flags, bit.bnot(0x10)))
end
local function text_init(widget) put32(widget + 272, 0); put8(widget + 616, 0) end
local function argument(widget)
    for index = 0, get8(widget + 616) - 1 do
        local record = widget + 280 + 24 * index
        if get32(record) == KEY and get32(record + 4) == 1 then
            return ffi.string(ffi.cast('const char *', get64(record + 8)))
        end
    end
    return nil
end
local function shown(widget)
    return get32(widget + 272) == TEMPLATE and argument(widget) or get32(widget + 272)
end

-- The game's panel builds: real rows for a category, each re-initialised.
local function native_build(category)
    for index = 31, 0, -1 do release(row(index)) end
    for index = 0, NATIVE_ROWS[category] - 1 do
        local target = row(index)
        put32(target + 31428, category * 100 + index)
        put32(target + 31424, 2)
        text_init(target + 3992)
        put32(target + 3992 + 272, 0x1000 + category * 100 + index)
        text_init(target + 16832)
        set_visible(target, true)
        add_child(panel(category) + 544, target)
    end
    put32(panel(category) + COUNT_FIELD[category], NATIVE_ROWS[category])
end
local calls = {select = {}, finish = {}, hidden = {}, visual = {}, box = {}, sound = {}}
-- MOM passes object addresses as integers and positions as {x, y} structs.
local native = {}
function native.play_sound(unused, event) calls.sound[#calls.sound + 1] = event end
function native.hide_description(target, hidden, animate)
    assert(address(target) == box)
    calls.box[#calls.box + 1] = {hidden, animate}
    put8(box + 2672, hidden)
end
-- The OPTIONS visual pass, as far as MOM depends on it: set_description for
-- the current panel's selected row. Setting 139 (MOM rows) and 156 (none)
-- have no description; other settings show their own labels.
function native.options_visual(target, dt)
    assert(address(target) == content and get8(content + 1319445) == 0)
    calls.visual[#calls.visual + 1] = dt
    -- An opening dialog finishes opening inside the pass.
    if get32(dialog + 19752) == 1 then put32(dialog + 19752, 2) end
    local category, setting = get32(content + 1318488), 156
    if category <= 7 then
        local index = get32(panel(category) + SELECTED_FIELD[category])
        if index ~= 0x7fffffff then setting = get32(row(index) + 31428) end
    end
    if get32(DESCRIBED) == setting then return end
    put32(DESCRIBED, setting)
    if get32(SHOWN) == setting then return end
    put32(SHOWN, setting)
    if setting == 156 or setting == 139 then native.hide_description(ffi.cast('void *', box), 1, 1); return end
    put32(title + 272, 0x2000 + setting)
    put32(body + 272, 0x3000 + setting)
    native.hide_description(ffi.cast('void *', box), 0, 1)
end
-- Text measure: one 20-unit line per 40 characters of the shown argument.
function native.measure_text(widget)
    local at = address(widget)
    putf(at + 16, 20 * math.max(1, math.ceil(#(argument(at) or '') / 40)))
    putf(at + 32, 1)
end
function native.set_position(widget, position)
    putf(address(widget) + 4, position.x); putf(address(widget) + 8, position.y)
end
function native.set_size(widget, size)
    putf(address(widget) + 12, size.x); putf(address(widget) + 16, size.y)
end
function native.set_tab_labels(target, labels, count)
    assert(address(target) == bar)
    put32(bar + 57448, count)
    for index = 0, count - 1 do
        put32(bar + 57320 + 4 * index, labels[index])
        put32(bar + 8296 + 3400 * index + 272, labels[index])
        put32(bar + 11004 + 3400 * index, 1)
    end
end
function native.select_category(target, category)
    assert(address(target) == content)
    calls.select[#calls.select + 1] = category
    put32(content + 1318488, category)
    local previous = get32(content + 1318492)
    if previous ~= category and category <= 7 then native_build(category) end
end
function native.set_content_hidden(target, hidden)
    assert(address(target) == content)
    calls.hidden[#calls.hidden + 1] = hidden
    put8(content + 1319445, hidden)
end
function native.row_init(target, position, pivot, anchor, layer, settings, descriptor, flag)
    local at, words = address(target), ffi.cast('uint32_t *', descriptor)
    local floats = ffi.cast('float *', descriptor)
    assert(address(descriptor) % 16 == 0, 'descriptors are 16-byte aligned like the game\'s')
    assert(layer == 10 and flag == 1 and position.x == 0 and settings == 0)
    assert(pivot.x == 0.5 and pivot.y == 1 and anchor.x == 0.5 and anchor.y == 1)
    assert(get64(at + 240) == 0, 'row_init on an attached row')
    put32(at + 31428, words[0])
    put32(at + 31424, words[2] == 2 and 2 or words[2])
    text_init(at + 3992)
    put32(at + 3992 + 272, words[4])
    set_visible(at, true)
    putf(at + 20000, position.y) -- test bookkeeping: row position
    if words[2] == 2 then
        put32(at + 29072, words[16])
        for index = 0, words[16] - 1 do put32(at + 29080 + 4 * index, words[17 + index]) end
        put32(at + 29068, 0)
        text_init(at + 16832)
        put32(at + 16832 + 272, words[17])
    else
        putf(at + 31396, floats[9]); putf(at + 31400, floats[10]); putf(at + 31408, floats[9])
        put32(at + 20004, words[14]) -- test bookkeeping: slider format
    end
end
local released = 0
-- The game loads both rectangles with movaps, which faults unless the address
-- is 16-byte aligned (the v1.0 crash on opening MODS); LuaJIT's ffi.new only
-- guarantees 8.
function native.row_reset(target, first, second)
    assert(first == second and address(first) % 16 == 0, 'row_reset rectangles must be 16-byte aligned')
end
function native.row_release(target) released = released + 1; release(address(target)) end
function native.add_child(parent, child) add_child(address(parent), address(child)) end
function native.set_visible(widget, on) set_visible(address(widget), on ~= 0) end
function native.set_label(widget, label) put32(address(widget) + 272, label) end
function native.set_string_arg(widget, key, text)
    local at = address(widget)
    local count = get8(at + 616)
    local slot = count
    for index = 0, count - 1 do if get32(at + 280 + 24 * index) == key then slot = index end end
    local record = at + 280 + 24 * slot
    put32(record, key); put32(record + 4, 1); put64(record + 8, address(text))
    if slot == count then put8(at + 616, count + 1) end
end
function native.clear_args(label) put8(address(label) + 344, 0); return 1 end
function native.set_choice(selector, index)
    local at = address(selector) - 16016
    put32(at + 29068, index)
    put32(at + 16832 + 272, get32(at + 29080 + 4 * index))
end
function native.set_slider(slider, value) putf(address(slider) - 29176 + 31408, value) end
function native.finish_simple(target) calls.finish[#calls.finish + 1] = address(target) end
function native.finish_access(target) calls.finish[#calls.finish + 1] = address(target) end
function native.scroll_thumb() end
function native.scroll_extent() end
function native.set_opacity(widget, value) putf(address(widget) + 68, value) end
function native.scroll_reset() end
state.initialized, state.base, state.native = true, base, native

-- Aligned buffers: whatever the heap looks like, the carved pointer is 16-byte
-- aligned and lies inside its block; the reset rectangle's block is kept.
do
    local aligned = upvalue(upvalue(menu.register_option, 'descriptor'), 'aligned')
    local keep = {}
    for size = 1, 64 do
        keep[#keep + 1] = ffi.new('uint8_t[?]', size) -- shifts the next allocation
        local pointer, block = aligned(size * 3)
        local at, start = address(pointer), address(block)
        assert(at % 16 == 0 and at >= start and at + size * 3 <= start + size * 3 + 15, 'misaligned: ' .. size)
        for index = 0, size * 3 - 1 do assert(pointer[index] == 0) end
    end
    local release_rows = upvalue(upvalue(upvalue(step, 'enter_view'), 'build_page'), 'release_rows')
    local rect, block = address(upvalue(release_rows, 'ZERO_RECT')), address(state.zero_rect_block)
    assert(rect % 16 == 0 and rect >= block and rect + 16 <= block + 31, 'reset rectangle not 16-byte aligned inside its kept block')
end

-- Registration contract.
local changes = {}
assert(menu.api == 1 and menu.version == 1 and menu.ready())
assert(not menu.register_option('bad', {type = 'toggle'}))
assert(not menu.register_option('bad', {type = 'dial', label = 'Dial'}))
assert(not menu.register_option('bad', {type = 'choice', label = 'One', choices = {'A'}}))
assert(not menu.register_option('bad', {type = 'slider', label = 'S', min = 2, max = 1}))
assert(not menu.register_option('bad', {type = 'toggle', label = 'T', default = 1}))
assert(not menu.register_option('bad\tid', {type = 'toggle', label = 'T'}))
assert(not menu.register_option('bad', {type = 'toggle', label = 'T', description = 5}))
assert(not menu.register_option('bad', {type = 'toggle', label = 'T', description = ' \n '}))
assert(not menu.register_option('bad', {type = 'toggle', label = 'T', description = string.rep('x', 401)}))
local HINTS = 'Shows button hints.'
local MODE = 'Picks how the weapon fires while the trigger is held down.'
assert(menu.register_option('alpha.hints', {type = 'toggle', label = 'Show Hints', mod = 'Alpha Mod', default = true,
                                            description = HINTS}))
assert(menu.register_option('alpha.hints', {type = 'toggle', label = 'Show Hints', mod = 'Alpha Mod', default = true,
                                            description = HINTS}))
assert(not menu.register_option('alpha.hints', {type = 'toggle', label = 'Other', mod = 'Alpha Mod'}))
assert(not menu.register_option('alpha.hints', {type = 'toggle', label = 'Show Hints', mod = 'Alpha Mod', default = true,
                                                description = 'Other text.'}))
assert(menu.register_option('alpha.mode', {type = 'choice', label = 'Fire Mode', mod = 'Alpha Mod',
                                           choices = {'Single', 'Burst', 'Auto'}, default = 2,
                                           description = '  Picks how the weapon fires\nwhile the trigger is held down.'}))
assert(menu.register_option('alpha.level', {type = 'choice', label = 'Level', mod = 'Alpha Mod',
                                            choices = {'low', 'High'}}))
assert(menu.register_option('alpha.volume', {type = 'slider', label = 'Volume', mod = 'Alpha Mod',
                                             min = 0, max = 1, step = 0.05, default = 0.5, gap = true}))
assert(menu.register_option('alpha.count', {type = 'slider', label = 'Count', mod = 'Alpha Mod',
                                            min = 1, max = 10, default = 3}))
for index = 1, 10 do
    assert(menu.register_option('alpha.extra' .. index, {type = 'toggle', label = 'Extra ' .. index,
                                                         mod = 'Alpha Mod'}))
end
assert(menu.register_option('beta.enabled', {type = 'toggle', label = 'Enabled', mod = 'Beta'}))
for index = 1, 3 do
    assert(menu.register_option('zulu.' .. index, {type = 'toggle', label = 'Zulu ' .. index, mod = 'Zulu'}))
end
assert(menu.get('alpha.hints') == true and menu.get('alpha.mode') == 2 and menu.get('alpha.volume') == 0.5)
assert(menu.get('alpha.count') == 3 and menu.get('beta.enabled') == false and menu.get('alpha.level') == 1)
assert(menu.on_change('alpha.hints', function(value, id) changes[#changes + 1] = {id, value} end))
assert(menu.on_change('alpha.mode', function(value, id) changes[#changes + 1] = {id, value} end))
assert(menu.on_change('alpha.volume', function(value, id) changes[#changes + 1] = {id, value} end))
assert(not menu.set('alpha.mode', 4) and not menu.set('nope', true))

-- Escape menu open on OPTIONS, last on MOUSE & KEYBOARD.
set_stack({1})
put32(bar + 57448, 3)
put32(bar + 57452, 2)
for index = 1, 3 do put32(bar + 57320 + 4 * (index - 1), TAB_LABELS[index]) end
put32(screen + 8, 2)
for index = 0, 8 do
    local button = content + 816 + 14920 * index
    set_visible(button, true)
    put32(button + 1928 + 272, CATEGORY_LABELS[index + 1])
end
put32(content + 1318488, 7)
native_build(7)
step(0.016)
assert(get32(bar + 57448) == 4 and get32(bar + 57320 + 12) == TEMPLATE)
assert(shown(bar + 8296 + 3400 * 3) == 'MODS')
assert(get32(bar + 11004 + 3400 * 2) == 3 and get8(bar + 11021 + 3400 * 2) == 1)
assert(not state.view and #calls.visual == 0) -- the screen runs OPTIONS' visual pass itself

-- Selecting MODS: the game hides every content and shows nothing for tab 3.
put32(bar + 57452, 3)
put32(screen + 8, 3)
put8(content + 1319445, 1)
step(0.016)
local view = assert(state.view)
assert(get32(screen + 8) == 2 and get8(content + 1319445) == 0)
assert(shown(content + 816 + 1928) == 'ALPHA MOD' and shown(content + 816 + 14920 + 1928) == 'BETA')
assert(shown(content + 816 + 14920 * 2 + 1928) == 'ZULU')
for index = 3, 8 do assert(not visible(content + 816 + 14920 * index)) end
assert(calls.select[#calls.select] == 0 and get32(content + 1318488) == 0)
-- Page 0: fifteen Alpha options on the GAMEPLAY panel, which natively lists 11 rows.
assert(get32(panel(0) + 2832) == 15)
local expected = {'Show Hints', 'Fire Mode', 'Level', 'Volume', 'Count'}
for index, label in ipairs(expected) do
    local target = row(index - 1)
    assert(get32(target + 31428) == 139 and shown(target + 3992) == label, label)
end
assert(get32(row(0) + 29068) == 1 and get32(row(0) + 29080) == 0xa090be2e)
assert(get32(row(1) + 29068) == 1 and shown(row(1) + 16832) == 'BURST')
assert(get32(row(2) + 29080) == 0xe1f9ab36 and get32(row(2) + 29084) == 0x208f9597) -- LOW/HIGH native
assert(math.abs(getf(row(3) + 31408) - 0.5) < 1e-6 and get32(row(3) + 20004) == 0x6220)
assert(getf(row(3) + 20000) == -3 * 64 - 32 and getf(row(4) + 20000) == -4 * 64 - 32)
assert(get32(row(4) + 20004) == 0 and getf(row(4) + 31408) == 3)
assert(math.abs(getf(panel(0) + 2840) + 32) < 1e-6 and calls.finish[#calls.finish] == panel(0))
assert(#children(panel(0) + 544) == 15 and released == 32)
-- The screen skips the OPTIONS visual pass on tab 3, so MOM runs it with the
-- frame time in the step that built the page: the first MODS frame is laid
-- out. The game hides the box for setting 139; row 0 is selected, so MOM
-- then shows its description with the game's layout.
assert(#calls.visual == 1 and math.abs(calls.visual[1] - 0.016) < 1e-6)
assert(#calls.box == 2 and calls.box[1][1] == 1 and calls.box[2][1] == 0 and calls.box[2][2] == 1)
assert(get8(box + 2672) == 0 and shown(title) == 'Show Hints' and shown(body) == HINTS)
assert(getf(body + 4) == 14 and getf(body + 8) == -20 - 24 and getf(body + 68) == 1)
assert(getf(frame + 12) == 450 and getf(frame + 16) == 20 + 20 + 7 + 72)

-- Player changes: toggle off, next fire mode, volume slider. As on the OPTIONS
-- tab they stay pending: the game's unapplied flag shows APPLY and guards
-- leaving, while get() and the callbacks keep the applied values.
put32(row(0) + 29068, 0)
put32(row(1) + 29068, 2)
put32(row(1) + 16832 + 272, TEMPLATE)
putf(row(3) + 31408, 0.7500001)
step(0.016)
assert(menu.get('alpha.hints') == true and menu.get('alpha.mode') == 2 and menu.get('alpha.volume') == 0.5)
assert(#changes == 0 and shown(row(1) + 16832) == 'AUTO' and get8(UNAPPLIED) == 1)
assert(#calls.visual == 2 and #calls.box == 2) -- same selection: no description work
-- The apply action (Tab) applies them in registration order, saves at once
-- and plays the game's apply sound.
press(APPLY); step(0.016); release_keys()
assert(menu.get('alpha.hints') == false and menu.get('alpha.mode') == 3 and menu.get('alpha.volume') == 0.75)
assert(#changes == 3 and changes[1][1] == 'alpha.hints' and changes[2][1] == 'alpha.mode')
assert(changes[3][1] == 'alpha.volume' and changes[3][2] == 0.75)
assert(get8(UNAPPLIED) == 0 and #calls.sound == 1 and calls.sound[1] == 1183616600)
local file = assert(io.open(directory .. '/ModOptionsMenu.values', 'rb'))
local saved = file:read('*a'); file:close()
assert(saved:find('alpha.hints\tfalse', 1, true) and saved:find('alpha.mode\t3', 1, true))
assert(saved:find('alpha.volume\t0.75', 1, true))
-- Editing back to the applied value withdraws the edit.
put32(row(0) + 29068, 1); step(0.016); assert(get8(UNAPPLIED) == 1)
put32(row(0) + 29068, 0); step(0.016); assert(get8(UNAPPLIED) == 0)
-- Leaving with an edit meets the game's UNAPPLIED CHANGES dialog. Its confirm
-- discards: the row shows the applied value again, and the unapplied flag is
-- clear, so the next Back leaves instead of asking again. The game may answer
-- the dialog before this update: it is already closing and the confirm's
-- Menu.Select has been cleared (the v1.0 build missed that confirm, so every
-- Back reopened the dialog) ...
put32(row(0) + 29068, 1); step(0.016)
set_dialog(2); step(0.016); assert(get8(UNAPPLIED) == 1)
-- Once open, the dialog is switched to a mode the game's own confirm ignores
-- (its mode-0 reload would rewrite DISPLAY rows 8 and 11); MOM discards.
assert(get32(dialog + 19748) == 2)
game_answers(SELECT); step(0.016); release_keys(); set_dialog(0)
assert(get8(UNAPPLIED) == 0 and get32(row(0) + 29068) == 0 and menu.get('alpha.hints') == false)
-- Without an edit pending, the game's dialog is left alone.
set_dialog(2); step(0.016); assert(get32(dialog + 19748) == 0); set_dialog(0); step(0.016)
-- A cancel answered before this update keeps the edit, as does its closing.
put32(row(0) + 29068, 1); step(0.016)
set_dialog(2); step(0.016); game_answers(BACK); step(0.016); release_keys()
step(0.016); set_dialog(0); step(0.016)
assert(get8(UNAPPLIED) == 1 and get32(row(0) + 29068) == 1)
-- A dialog that finishes opening inside the visual pass counts from there: the
-- game's next input update may already answer it.
set_dialog(1); step(0.016); assert(get32(dialog + 19752) == 2 and get32(dialog + 19748) == 2)
game_answers(SELECT); step(0.016); set_dialog(0)
assert(get8(UNAPPLIED) == 0 and get32(row(0) + 29068) == 0)
-- ... or after it (the dialog is still open). Tab does nothing while the
-- dialog is open, and a cancel keeps the edit even once the dialog closes.
put32(row(0) + 29068, 1); step(0.016)
set_dialog(2); press(APPLY); step(0.016); release_keys(); assert(get8(UNAPPLIED) == 1)
press(BACK); step(0.016); release_keys(); set_dialog(3); step(0.016); set_dialog(0); step(0.016)
assert(get8(UNAPPLIED) == 1 and get32(row(0) + 29068) == 1)
set_dialog(2); step(0.016); press(SELECT); step(0.016); release_keys()
assert(get8(UNAPPLIED) == 0 and get32(row(0) + 29068) == 0) -- decided while still open
set_dialog(3); step(0.016); set_dialog(0)
assert(get8(UNAPPLIED) == 0 and get32(row(0) + 29068) == 0 and #changes == 3 and #calls.sound == 1)

-- Code changes update the visible row without callbacks, replacing any
-- unapplied edit of that option.
putf(row(4) + 31408, 9); step(0.016); assert(get8(UNAPPLIED) == 1)
assert(menu.set('alpha.count', 7.4))
assert(menu.get('alpha.count') == 7 and getf(row(4) + 31408) == 7 and #changes == 3)
step(0.016)
assert(#changes == 3 and get8(UNAPPLIED) == 0)

-- Hovering Fire Mode shows its two-line description; Level has none, so the
-- box hides, and an unchanged selection costs nothing.
local box_calls = #calls.box
put32(panel(0) + 2872, 1)
step(0.016)
assert(#calls.box == box_calls + 1 and get8(box + 2672) == 0)
assert(shown(title) == 'Fire Mode' and shown(body) == MODE)
assert(getf(body + 8) == -20 - 24 and getf(frame + 16) == 40 + 20 + 7 + 72)
put32(panel(0) + 2872, 2)
step(0.016)
assert(#calls.box == box_calls + 2 and get8(box + 2672) == 1 and calls.box[#calls.box][2] == 1)
step(0.016)
assert(#calls.box == box_calls + 2)
-- No row selected: the game's own pass hides the box (setting 156); selecting
-- Fire Mode again brings MOM's text back over the game's hide.
put32(panel(0) + 2872, 0x7fffffff)
step(0.016)
assert(get32(DESCRIBED) == 156 and get8(box + 2672) == 1)
put32(panel(0) + 2872, 1)
step(0.016)
assert(get32(DESCRIBED) == 139 and get8(box + 2672) == 0 and shown(body) == MODE)

-- The player edits Extra 1, then picks BETA: the game deactivates GAMEPLAY and
-- builds DISPLAY.
put32(row(5) + 29068, 1); step(0.016)
put32(content + 1318492, 0)
native.select_category(ffi.cast('void *', content), 1)
step(0.016)
assert(state.view.page.index == 1 and get32(panel(1) + 33256) == 1)
assert(shown(row(0) + 3992) == 'Enabled' and get32(row(0) + 31428) == 139)
-- Only the page's row is listed; GAMEPLAY lists nothing once released.
assert(#children(panel(1) + 544) == 1 and #children(panel(0) + 544) == 0)
-- The new page selects Enabled, which has no description: the box hides.
assert(get8(box + 2672) == 1 and calls.box[#calls.box][1] == 1)
-- The edit survives the page switch, and Tab on this page applies it.
assert(get8(UNAPPLIED) == 1 and menu.get('alpha.extra1') == false)
press(APPLY); step(0.016); release_keys()
assert(get8(UNAPPLIED) == 0 and menu.get('alpha.extra1') == true and #calls.sound == 2)
-- The DISPLAY panel's settings reload rewrites a row's choice list in place;
-- the page check sees the choice count or first label change and rebuilds.
local rebuilds = released
put32(row(0) + 29072, 10); step(0.016)
assert(released == rebuilds + 32 and get32(row(0) + 29072) == 2 and shown(row(0) + 3992) == 'Enabled')
put32(row(0) + 29080, 0x12345678); step(0.016)
assert(released == rebuilds + 64 and get32(row(0) + 29080) == 0xa090be2e and #children(panel(1) + 544) == 1)

-- A native rebuild of the shown panel (revert, device change) is replaced.
native_build(1)
step(0.016)
assert(get32(panel(1) + 33256) == 1 and shown(row(0) + 3992) == 'Enabled')
assert(#children(panel(1) + 544) == 1)

-- New registrations while open refresh the buttons and page.
assert(menu.register_option('beta.speed', {type = 'slider', label = 'Speed', mod = 'Beta', min = 1, max = 5,
                                           description = 'Sets the speed.'}))
step(0.016)
assert(get32(panel(1) + 33256) == 2 and shown(row(1) + 3992) == 'Speed')

-- Per-frame budget with the MODS tab open and nothing changing: two reads
-- (UI stack, screen pointer); the tab, page check, value polls and selection
-- are direct loads. One native visual pass, no description work, no
-- allocation. The visual pass is counted without the game's emulation here,
-- which allocates in this test.
do
    local visual, passes, description_calls = native.options_visual, 0, #calls.box
    native.options_visual = function() passes = passes + 1 end
    local reads, garbage = measure(200)
    native.options_visual = visual
    assert(reads == 2, 'MODS frame reads: ' .. reads)
    assert(garbage < 0.5, string.format('MODS frames allocated %.2f KB', garbage))
    assert(passes == 201 and #calls.box == description_calls)
    -- With an edit pending, the dialog and apply-action checks are direct
    -- loads too: still two reads and no allocation.
    putf(row(1) + 31408, 4)
    native.options_visual = function() passes = passes + 1 end
    reads, garbage = measure(200)
    native.options_visual = visual
    assert(reads == 2, 'MODS frame reads with an edit pending: ' .. reads)
    assert(garbage < 0.5, string.format('MODS frames with an edit pending allocated %.2f KB', garbage))
    assert(get8(UNAPPLIED) == 1 and menu.get('beta.speed') == 1)
    putf(row(1) + 31408, 1); step(0.016); assert(get8(UNAPPLIED) == 0)
end

-- Q back to OPTIONS with Speed's description shown: the game's tab switch
-- keeps the shown content (still 2).
put32(panel(1) + 33296, 1)
step(0.016)
assert(get8(box + 2672) == 0 and shown(title) == 'Speed' and shown(body) == 'Sets the speed.')
local visual_calls = #calls.visual
put32(bar + 57452, 2)
step(0.016)
assert(not state.view and #calls.visual == visual_calls)
-- The box goes back to the game: hidden at once, MOM's text arguments gone,
-- both setting caches cleared so OPTIONS fills it again.
assert(get8(box + 2672) == 1 and calls.box[#calls.box][1] == 1 and calls.box[#calls.box][2] == 0)
assert(get8(title + 616) == 0 and get8(body + 616) == 0)
assert(get32(DESCRIBED) == 156 and get32(SHOWN) == 156 and get8(UNAPPLIED) == 0)
for index = 0, 8 do
    local button = content + 816 + 14920 * index
    assert(visible(button) and get32(button + 1928 + 272) == CATEGORY_LABELS[index + 1])
    assert(get8(button + 1928 + 616) == 0)
end
assert(get32(content + 1318488) == 7 and get32(panel(7) + 2832) == 11)
assert(get32(row(0) + 31428) == 700 and visible(row(10)) and #children(panel(7) + 544) == 11)
-- Per-frame budget with the escape menu open on another tab: the same two
-- reads, the MODS tab check as direct loads, no visual pass, no allocation.
do
    local reads, garbage = measure(200)
    assert(reads == 2, 'OPTIONS frame reads: ' .. reads)
    assert(garbage < 0.5, string.format('OPTIONS frames allocated %.2f KB', garbage))
    assert(#calls.visual == visual_calls)
end

-- Reopening MODS from GAMEPLAY (the same panel as page 0) forces a fresh build.
put32(content + 1318492, 7)
native.select_category(ffi.cast('void *', content), 0)
put32(bar + 57452, 3)
put32(screen + 8, 3)
step(0.016)
assert(state.view and state.view.page.index == 0 and get32(panel(0) + 2832) == 15)
assert(#calls.visual == visual_calls + 1 and get8(box + 2672) == 0 and shown(body) == MODE)
assert(get32(row(5) + 29068) == 1) -- the applied Extra 1
-- Closing the escape menu drops the view and any unapplied edit with it;
-- reopening re-initialises widgets.
put32(row(6) + 29068, 1); step(0.016)
assert(get8(UNAPPLIED) == 1 and state.pending_count == 1)
set_stack({})
step(0.016)
assert(not state.view and #calls.visual == visual_calls + 2)
assert(state.pending_count == 0 and menu.get('alpha.extra2') == false)

-- Per-frame budget with the escape menu closed (most of every session): one
-- read (the UI stack block; the UI state pointer is a direct load from
-- game.dll) and no allocation.
do
    local reads, garbage = measure(200)
    assert(reads == 1, 'idle frame reads: ' .. reads)
    assert(garbage < 0.5, string.format('idle frames allocated %.2f KB', garbage))
    assert(#calls.visual == visual_calls + 2, 'idle frames ran the visual pass')
end

-- A second instance reads the saved values.
_G.ModOptionsMenu, _G.update = nil, nil
dofile(source)
assert(ModOptionsMenu.register_option('alpha.hints', {type = 'toggle', label = 'Show Hints', mod = 'Alpha Mod', default = true}))
assert(ModOptionsMenu.register_option('alpha.volume', {type = 'slider', label = 'Volume', mod = 'Alpha Mod',
                                                        min = 0, max = 1, step = 0.05, default = 0.5}))
assert(ModOptionsMenu.get('alpha.hints') == false and ModOptionsMenu.get('alpha.volume') == 0.75)

-- A toggle registered once all addons have loaded gets its own category.
local late_option = 'example_loader.cache_toggle'
assert(ModOptionsMenu.register_option(late_option,
    {type = 'toggle', label = 'Expanded Cache', mod = 'Example Loader', default = true,
     description = "Registered after every addon has loaded, under a category of its own."}))
assert(ModOptionsMenu.get(late_option) == true and ModOptionsMenu.on_change(late_option, function() end))
assert(upvalue(ModOptionsMenu.register_option, 'state').mods['EXAMPLE LOADER'])
-- Shallow Water Diving v3.8 registers this exact slider: two decimals (0.05
-- steps from 0.20), shown as a float slider, defaulting to its old fixed limit.
local depth_option = 'shallow_water_diving.max_water_depth'
assert(ModOptionsMenu.register_option(depth_option,
    {type = 'slider', label = 'Max Dive Water Depth', mod = 'Shallow Water Diving', min = 0.20, max = 1.30,
     step = 0.05, default = 0.20,
     description = 'Deepest water, measured up from your feet, that a dive can start in: from 0.20 '
                   .. '(lower shin, the original limit) up to 1.30, where your Helldiver starts swimming. Deeper '
                   .. "water always keeps the game's normal behavior."}))
do
    local option = upvalue(ModOptionsMenu.register_option, 'state').options[depth_option]
    local words = ffi.cast('uint32_t *', option.descriptor)
    assert(option.decimals == 2 and words[2] == 1 and words[14] == 0x6220 and ModOptionsMenu.get(depth_option) == 0.2)
    assert(ModOptionsMenu.set(depth_option, 1.3) and ModOptionsMenu.get(depth_option) == 1.3)
    assert(ModOptionsMenu.set(depth_option, 0.62) and ModOptionsMenu.get(depth_option) == 0.6)
end
print('MODS tab, pages, layout pass, descriptions, apply and unapplied-changes discard, value persistence '
      .. 'and restoration, idle, open and MODS frame budgets and a late registration OK')
