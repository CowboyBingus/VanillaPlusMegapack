-- The MORE MODS tab and its panel (src/panel.lua) against simulated game
-- memory (the bindings page, its list widgets, the menu cursor and the UI
-- action states) and a simulated engine (Gui, worlds, mouse and keyboard):
-- the fifth tab, geometry from the native widgets, visible rows only, redraws
-- only on a change, navigation, hover, clicks, the wheel, key capture with
-- the page's UI actions consumed, the keys shown per page, teardown, per-frame
-- reads pinned and no allocation on idle frames.
-- Usage: luajit test_panel.lua [path to src/mod_bindings_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local function remove_files()
    for _, name in ipairs({'ModBindingsMenu.assignments', 'ModBindingsMenu.bindings'}) do
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
local ffi = require('ffi')
local budget = dofile((arg[0]:match('^(.*[/\\])') or './') .. 'frame_budget.lua')

-- The simulated engine. Gui primitives are kept per Gui; every Gui call is
-- counted.
local gui_calls = {create = 0, rect = 0, text = 0, update_rect = 0, update_text = 0, destroy = 0}
local guis, worlds = {}, {main = {name = 'main'}, ui = {name = 'ui'}, other = {name = 'other'}}
local world_list = {worlds.main, worlds.ui, worlds.other}
local function new_gui(world)
    local gui = {world = world, prims = {}, alive = true}
    guis[#guis + 1] = gui
    return gui
end
local function prim(gui, kind, fields)
    gui.prims[#gui.prims + 1] = fields
    fields.kind = kind
    return #gui.prims
end
local KEYS = {g = 71, h = 72, ['left ctrl'] = 162, esc = 27, delete = 46, enter = 13, space = 32,
              ['numpad enter'] = 256, ['left button **'] = 1}
local MOUSE = {left = 0, right = 1, wheel_up = 10, wheel_down = 11}
local PAD = {a = 12, b = 13, x = 14, y = 15, left_shoulder = 8}
local held, fresh = {k = {}, m = {}, p = {}}, {k = {}, m = {}, p = {}}
local function device(code, ids)
    return {
        button = function(index) return held[code][index] and 1 or 0 end,
        button_id = function(name) return ids[name] end,
        button_name = function(index)
            for name, id in pairs(ids) do if id == index then return name end end
        end,
        any_pressed = function() return table.remove(fresh[code], 1) end,
        pressed = function(index)
            for _, value in ipairs(fresh[code]) do if value == index then return true end end
            return false
        end,
        connected = code == 'p' and function() return true end or nil,
    }
end
local function press(name, code)
    code = code or 'k'
    local ids = code == 'k' and KEYS or code == 'm' and MOUSE or PAD
    held[code][ids[name]] = true
    fresh[code][#fresh[code] + 1] = ids[name]
end
local function release(name, code)
    code = code or 'k'
    local ids = code == 'k' and KEYS or code == 'm' and MOUSE or PAD
    held[code][ids[name]] = nil
end
local engine = {
    Keyboard = device('k', KEYS), Mouse = device('m', MOUSE), Pad1 = device('p', PAD),
    Application = {worlds = function() return world_list end, main_world = function() return worlds.main end},
    World = {
        create_screen_gui = function(world, flag, x, y)
            assert(flag == 'scale' and x == 1 and y == 1)
            gui_calls.create = gui_calls.create + 1
            return new_gui(world)
        end,
        destroy_gui = function(world, gui)
            assert(gui.world == world and gui.alive)
            gui.alive = false
            gui_calls.destroy = gui_calls.destroy + 1
        end,
    },
    Gui = {
        rect = function(gui, position, size, colour)
            assert(gui.alive)
            gui_calls.rect = gui_calls.rect + 1
            return prim(gui, 'rect', {position = position, size = size, colour = colour})
        end,
        update_rect = function(gui, id, position, size, colour)
            assert(gui.alive and gui.prims[id].kind == 'rect')
            gui_calls.update_rect = gui_calls.update_rect + 1
            gui.prims[id].position, gui.prims[id].size, gui.prims[id].colour = position, size, colour
        end,
        text = function(gui, value, font, size, material, position, colour)
            assert(gui.alive and font == 'id:00000000f0000001' and material == 'id:00000000f0000002')
            gui_calls.text = gui_calls.text + 1
            return prim(gui, 'text', {value = value, size = size, position = position, colour = colour})
        end,
        update_text = function(gui, id, value, font, size, material, position, colour)
            assert(gui.alive and gui.prims[id].kind == 'text')
            gui_calls.update_text = gui_calls.update_text + 1
            local p = gui.prims[id]
            p.value, p.size, p.position, p.colour = value, size, position, colour
        end,
        material = function(gui, id) return {gui = gui, id = id} end,
        -- Every character is half the size wide.
        text_extents = function(gui, value, font, size)
            assert(gui.alive and font == 'id:00000000f0000001')
            local width = 0
            for _ in value:gmatch('[^\128-\191]') do width = width + size / 2 end
            return {0, 0}, {width, size}, {width, 0}
        end,
    },
    Material = {set_scalar = function() end, set_vector2 = function() end, set_vector4 = function() end,
                set_texture = function() end},
    IdString64 = {from_hex = function(hex) return 'id:' .. hex end},
    Vector3 = function(x, y, z) return {x, y, z} end,
    Vector2 = setmetatable({x = function(v) return v[1] end}, {__call = function(_, x, y) return {x, y} end}),
    Color = function(a, r, g, b) return {a, r, g, b} end,
}

_G.update = function() end
dofile(source)
local host = assert(ModBindingsMenu)
local wrapper = update
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
local mbm = assert(upvalue(host.register_binding, 'mbm'))
local panel = mbm.panel_state()

-- Simulated game memory: the image (text slots, tab labels, font hashes), the
-- input owner (UI action states), the UI stack, the menu system (the bindings
-- screen and the cursor) and the screen with its list.
local image = ffi.new('uint8_t[?]', 0x3800000)
local base = tonumber(ffi.cast('uint64_t', image))
-- The input owner holds the UI action states and the live and default binding
-- maps (256 records of 328 bytes, the dormant actions' records filled in), which
-- the binding page's reset-source check reads (src/sweep.lua).
local owner_memory = ffi.new('uint8_t[?]', 687000)
local owner = tonumber(ffi.cast('uint64_t', owner_memory))
local binding_maps = {ffi.new('uint8_t[?]', 256 * 328), ffi.new('uint8_t[?]', 256 * 328)}
for map_index, offset in ipairs({686800, 686968}) do
    local map = tonumber(ffi.cast('uint64_t', binding_maps[map_index]))
    ffi.cast('uint64_t *', owner + offset)[0] = map
    ffi.cast('uint32_t *', owner + offset + 8)[0] = 256
    for index, entry in ipairs(mbm.DORMANT_ACTIONS) do
        ffi.cast('uint32_t *', map + (index + 10) * 328)[0] = entry[1] * 65536 + entry[2]
    end
end
local ui_memory, menu_memory = ffi.new('uint8_t[?]', 0x429c + 24), ffi.new('uint8_t[?]', 4096)
local ui, menu = tonumber(ffi.cast('uint64_t', ui_memory)), tonumber(ffi.cast('uint64_t', menu_memory))
local screen_memory = ffi.new('uint8_t[?]', 338344 + 2411940)
local screen = tonumber(ffi.cast('uint64_t', screen_memory))
local material_memory = ffi.new('uint8_t[?]', 64)
local function put32(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function get32(address) return tonumber(ffi.cast('uint32_t *', address)[0]) end
local function put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
local function putf(address, value) ffi.cast('float *', address)[0] = value end
put32(base + 0x3310210, 0x8d70f451); put32(base + 0x3310214, 0xf15e5c60); put32(base + 0x3310218, 0x00847feb)
put64(base + 0x347cf18, owner)
put64(base + 0x347ce28, ui)
put64(base + 0x347ce38, menu)
put64(menu + 208, screen)
-- The mission-mode record as on the ship (+8 zero; +0x40 keeps the last
-- mission's mode); section 12 starts a mission.
local mission_memory = ffi.new('uint8_t[?]', 0x44)
local mission_address = tonumber(ffi.cast('uint64_t', mission_memory))
put64(base + 0x33266a0, mission_address)
put32(mission_address + 0x40, 2)
-- Font, material and atlas hashes.
put64(base + 0x3772268, 0xf0000001)
put64(base + 0x37c5478, tonumber(ffi.cast('uint64_t', material_memory)))
put64(tonumber(ffi.cast('uint64_t', material_memory)) + 24, 0xf0000002)
put64(base + 0x3772ee8, 0xf0000003)
-- The cursor: attached to the root; its position (y up).
put64(menu + 1520 + 512, menu + 352)
local function cursor(x, y) putf(menu + 1520 + 620, x); putf(menu + 1520 + 624, y) end
cursor(-100, -100)
local function page(open)
    put32(ui + 0x429c + 20, 1)
    put32(ui + 0x429c, open and 26 or 1)
end
state.initialized, state.base = true, base
local bar, listing = screen + 1248, screen + 338344
local calls = {labels = {}, builds = 0}
state.set_tab_labels = function(_, labels, count)
    calls.labels = {}
    for index = 0, count - 1 do calls.labels[index + 1] = labels[index] end
    put32(bar + 57448, count)
end
state.build_rows = function(_, rows)
    calls.builds = calls.builds + 1
    local count = get32(listing + 2411928)
    put32(listing + 2411916, count)
    for index = 0, count - 1 do
        local row = listing + 7856 + 24784 * index
        local header = rows[index * 3 + 2]
        put32(row + 24752, header ~= 0 and 4 or 1)
        put32(row + 4264 + 272, header)
        put32(row + 24760, header ~= 0 and 0xffffffff or rows[index * 3] * 65536 + rows[index * 3 + 1])
    end
end
state.reset_list = function() end
-- The game's consume routine clears an action's state.
local consumed = {}
mbm.consume_action = function(target, code)
    assert(target == owner)
    local action = code / 4294967296
    consumed[#consumed + 1] = action
    owner_memory[808 + 32 * action] = 0
end
-- A solved widget: visible, opaque, scale s, bottom-left (x, y), size (w, h) in UI units.
local function widget(address, x, y, w, h, s, opacity)
    put32(address, 0x10)
    putf(address + 36, w); putf(address + 40, h)
    putf(address + 84, opacity or 1)
    putf(address + 100, s); putf(address + 140, s)
    putf(address + 148, x); putf(address + 156, y)
end
-- Scale 1: the header row 844 wide at the top (y 900 to 962), the viewport's
-- bottom at y 280: room for 10 rows of 62.
local function layout(s)
    widget(listing + 272, 100, 280, 1920, 806, s)
    widget(listing + 7856, 100, 900, 844, 62, s)
end
layout(1)
-- A UI action's state: active this frame, seconds held, and its magnitude
-- (1 while a key or button is down).
local function ui_action(index, on, held_seconds)
    owner_memory[808 + 32 * index] = on and 1 or 0
    putf(owner + 808 + 32 * index + 8, held_seconds or 0)
    putf(owner + 808 + 32 * index + 4, (on or (held_seconds or 0) > 0) and 1 or 0)
end

_G.stingray = engine
local function frame(dt)
    wrapper(dt or 0.016)
    for code in pairs(fresh) do fresh[code] = {} end
end
local function texts(gui)
    local list = {}
    for _, p in ipairs(gui.prims) do
        if p.kind == 'text' and p.value ~= '' and p.value ~= ' ' then list[#list + 1] = p.value end
    end
    return list
end
local function shown(value)
    for _, item in ipairs(texts(guis[#guis])) do if item == value then return true end end
    return false
end
local function total_gui_calls()
    return gui_calls.rect + gui_calls.text + gui_calls.update_rect + gui_calls.update_text
end

-- 1. Native bindings only: four tabs, as before. The first extended binding
-- adds MORE MODS to the page that is open.
-- The 29 automatic actions and fixed slot 2 held: later registrations are extended.
for index = 1, 29 do assert(host.register_binding('native.' .. index, 'Native ' .. index)) end
assert(host.register_binding('slot2.holder', 'Holder', 2) and not state.registry['slot2.holder'].extended)
assert(state.extended_count == 0)
put32(bar + 57448, 3); put32(bar + 57452, 0); put32(screen + 8, 0)
page(true)
frame()
assert(get32(bar + 57448) == 4 and #calls.labels == 4)
assert(host.register_binding('ext.toggle', 'Toggle HUD', nil, {category = 'Extra Mod', default = 'g'}))
frame()
assert(get32(bar + 57448) == 5 and #calls.labels == 5, 'MORE MODS added to the open page')
local more_label = calls.labels[5]
local function label_text(id)
    for _, entry in ipairs(assert(upvalue(wrapper, 'LABEL_POOL'))) do
        if entry[1] == id then
            local pointer = ffi.cast('uint64_t *', base + entry[2])[0]
            return pointer ~= 0 and ffi.string(ffi.cast('const char *', pointer)) or nil
        end
    end
end
assert(label_text(more_label) == 'MORE MODS', tostring(label_text(more_label)))
print('MORE MODS: a fifth tab once an extended binding exists, also on an open page OK')

-- 2. The MORE MODS tab: one native header row, then the panel below it.
for index = 1, 3 do
    assert(host.register_binding('ext.extra.' .. index, 'Extra ' .. index, nil, {category = 'Extra Mod'}))
end
assert(host.register_binding('ext.other', 'Other', nil, {category = 'Another Mod', default = {{button = 'h',
                             modifiers = {'left ctrl'}}}}))
assert(host.register_binding('ext.legacy', 0x3ef7f7ad, 2), 'a v1.1 slot-2 request beyond the pool')
assert(state.registry['ext.legacy'].extended)
put32(screen + 8, 4)
frame()
assert(calls.builds >= 1 and get32(listing + 2411916) == 1 and get32(listing + 7856 + 24752) == 4)
assert(label_text(get32(listing + 7856 + 4264 + 272)) == 'MORE MOD BINDINGS')
assert(#guis == 0, 'nothing drawn on the frame the native rows are built')
frame()
assert(#guis == 1 and guis[1].world == worlds.ui, 'the Gui is in the first non-main world')
assert(panel.count == 10 and panel.top == 900 and panel.bottom == 280 and panel.left == 100 and panel.right == 944)
-- Sections sorted by name: ANOTHER MOD, EXTRA MOD; then the unnamed v1.1 one.
assert(shown('ANOTHER MOD') and shown('EXTRA MOD') and shown('OTHER') and shown('TOGGLE HUD'))
assert(shown('LEFT CTRL + H') and shown('G') and shown('NOT BOUND'))
-- A label given as a game localization ID shows the binding's id instead.
assert(shown('LEGACY'), 'numeric label: the id stands in')
print('MORE MODS tab: one native header, the panel below it in the UI world, sections, labels and keys OK')

-- 3. Redraws only on a change: idle frames make no Gui calls.
local before = total_gui_calls()
for _ = 1, 5 do frame() end
assert(total_gui_calls() == before, 'idle frames redraw nothing')
-- The layout moves (another resolution): everything is redrawn at the new place.
layout(1.5)
frame()
assert(total_gui_calls() > before and panel.scale == 1.5)
layout(1)
frame()
-- Mid-animation (opacity below 1): the panel closes; afterwards it opens again.
widget(listing + 7856, 100, 900, 844, 62, 1, 0.5)
frame()
assert(not guis[1].alive and gui_calls.destroy == 1 and panel.gui == nil)
layout(1)
frame()
assert(#guis == 2 and guis[2].alive)
print('Redraws only on a change; a moved layout redraws; an unusable layout closes the panel OK')

-- 4. Navigation with the game's UI actions: down moves to the next binding
-- row (headers skipped); the held repeat after half a second.
assert(panel.focus == nil)
ui_action(2, true)
frame()
ui_action(2, false)
assert(panel.focus == 2 and panel.rows[2].record.id == 'ext.other', tostring(panel.focus))
ui_action(2, true)
frame()
ui_action(2, false)
assert(panel.focus == 4, 'the EXTRA MOD header is skipped: ' .. tostring(panel.focus))
local focus = panel.focus
ui_action(6, false, 0.3)
frame()
assert(panel.focus == focus, 'held under half a second: no repeat')
ui_action(6, false, 0.6)
frame()
assert(panel.focus == focus + 1, 'held: repeat')
ui_action(6, false, 0.65)
frame()
assert(panel.focus == focus + 1, 'repeat every 0.1 s')
ui_action(6, false, 0.75)
frame()
assert(panel.focus == focus + 2)
ui_action(6, false, 0)
ui_action(1, true)
frame()
ui_action(1, false)
assert(panel.focus == focus + 1, 'up')
print('Navigation follows the UI actions, skips headers and repeats like the game OK')

-- 5. The cursor: hovering a row focuses it; a click starts a capture on the
-- row under the cursor; a click outside does nothing.
cursor(300, 900 - 62 * 1 - 30)
frame()
assert(panel.hover == 2 and panel.focus == 2)
cursor(2000, 500)
press('left', 'm')
frame()
release('left', 'm')
assert(mbm.capture_phase() == 'idle', 'a click outside the panel')
cursor(300, 900 - 62 * 1 - 30)
press('left', 'm')
ui_action(10, true)
frame()
local phase, id, capture_page = mbm.capture_phase()
assert(phase == 'arming' and id == 'ext.other' and capture_page == 'keyboard')
assert(shown('PRESS A KEY') and shown('ESC: CANCEL, DELETE: CLEAR'))
-- While capturing every active UI action is consumed: select, still held.
frame()
assert(#consumed == 1 and consumed[1] == 10, 'select consumed')
release('left', 'm')
ui_action(10, false)
frame()
assert(mbm.capture_phase() == 'capturing')
-- Escape: the page's Back (UI action 9) is consumed, the capture cancelled,
-- the page stays.
press('esc')
ui_action(9, true)
frame()
assert(consumed[#consumed] == 9 and owner_memory[808 + 32 * 9] == 0, 'Back consumed')
assert(mbm.capture_phase() == 'idle' and shown('LEFT CTRL + H'), 'cancelled, binding unchanged')
release('esc')
ui_action(9, false)
print('Hover focuses, clicks capture the row under the cursor, the page\'s UI actions are consumed, Escape '
      .. 'cancels only the capture OK')

-- 6. Select from the keyboard on the focused row; a key replaces the keys.
ui_action(10, true)
frame()
ui_action(10, false)
assert(mbm.capture_phase() == 'arming')
frame()
assert(mbm.capture_phase() == 'capturing')
press('g')
frame()
release('g')
frame()
assert(mbm.capture_phase() == 'idle' and shown('G'))
assert(host.binding('ext.other')[1].button == 'g')
print('Select captures the focused row; the new key is shown OK')

-- 7. The controller page shows controller buttons and captures them.
put32(listing + 2411904, 1)
frame()
assert(panel.page == 'controller' and shown('NOT BOUND'))
ui_action(10, true)
frame()
ui_action(10, false)
assert(select(3, mbm.capture_phase()) == 'controller' and shown('PRESS A BUTTON') and shown('B: CANCEL, X: CLEAR'))
frame()
press('y', 'p')
frame()
release('y', 'p')
frame()
assert(shown('Y'))
put32(listing + 2411904, 0)
frame()
assert(shown('G'), 'the keyboard page keeps the keyboard key')
print('Controller page: controller buttons shown and captured, the keyboard key kept OK')

-- 8. The wheel scrolls; focus keeps in view; only visible rows are drawn.
for index = 1, 40 do assert(host.register_binding('bulk.' .. index, 'Bulk ' .. index, nil, {category = 'Bulk'})) end
frame()
assert(#panel.rows == 50 and panel.first == 1, #panel.rows .. ' rows')
cursor(300, 600)
press('wheel_down', 'm')
frame()
assert(panel.first == 4, 'three rows per notch')
press('wheel_up', 'm')
frame()
assert(panel.first == 1)
for _ = 1, 60 do ui_action(2, true); frame(); ui_action(2, false); frame() end
assert(panel.focus == #panel.rows and panel.first == #panel.rows - panel.count + 1, 'focus kept in view')
local texts_drawn = 0
for _, p in ipairs(guis[#guis].prims) do if p.kind == 'text' then texts_drawn = texts_drawn + 1 end end
assert(texts_drawn == 2 * panel.count, 'primitives for the visible rows only: ' .. texts_drawn)
print('The wheel scrolls, the focus stays in view, only visible rows have primitives OK')

-- 8b. A long label is cut to its column with '...' (whole characters; the
-- label column is 0.56 of the row less padding: 467.6 - 48 = 419.6 units, 38
-- characters of 11, so 35 and '...'); a binding registered above the focus
-- keeps the focus on its binding.
local focused_id = panel.rows[panel.focus].record.id
assert(host.register_binding('aaa.long', string.rep('Ä', 60), nil, {category = 'AAA'}))
frame()
assert(panel.rows[panel.focus].record.id == focused_id, 'the focus follows its binding')
for _ = 1, 60 do ui_action(1, true); frame(); ui_action(1, false); frame() end
assert(panel.first == 1 and panel.rows[2].record.id == 'aaa.long')
local cut = string.rep('Ä', 35) .. '...'
assert(shown(cut), 'cut label')
print('Long labels cut to their column; the focus follows its binding when rows are added above OK')

-- 9. Per-frame calls on the MORE MODS tab, pinned with tests/frame_budget.lua
-- (canonical copy: PerformanceBaseline/frame_budget.lua): Mod Bindings
-- Menu's private Windows names counted under the Windows names, the game's
-- consume routine as consume. In game a ReadProcessMemory costs about 1-2 us.
-- The function holding the upvalue wanted, and its index.
local function holder(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 80 do
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
local kernel_holder, kernel_index, real_kernel = holder(wrapper, 'kernel32')
local real_consume = mbm.consume_action
local api = {
    ReadProcessMemory = function(process, address, ...)
        if type(address) == 'number' then return real_kernel.MBM_read_at(process, address, ...) end
        return real_kernel.MBM_ReadProcessMemory(process, address, ...)
    end,
    VirtualQuery = function(...) return real_kernel.MBM_VirtualQuery(...) end,
    consume = real_consume,
}
local counts = budget.wrap(api)
local counted = {MBM_read_at = 'ReadProcessMemory', MBM_ReadProcessMemory = 'ReadProcessMemory',
                 MBM_VirtualQuery = 'VirtualQuery'}
debug.setupvalue(kernel_holder, kernel_index, setmetatable({}, {__index = function(_, name)
    if name:find('VirtualProtect', 1, true) then error('kernel32.' .. name) end
    return counted[name] and api[counted[name]] or real_kernel[name]
end}))
mbm.consume_action = function(...) return api.consume(...) end
local function frame_calls(label, limits, dt)
    local calls_made = budget.frame(counts, wrapper, dt or 0.016)
    for code in pairs(fresh) do fresh[code] = {} end
    budget.check(calls_made, limits, label)
    return calls_made
end
-- Every binding page frame also checks the reset source (the defaults record)
-- of each registered native action, one read each (v2.2.1's Revert fix,
-- src/sweep.lua): 30 natives here, so every page frame below is 30 reads
-- more than the panel's own (raised when the panel met that fix).
-- Every 0.5 s the native rows are checked again: the row count, then the
-- header row's kind and label (2 more reads than other frames).
frame_calls('MORE MODS tab, rows checked again after 0.5 s', {ReadProcessMemory = 45}, 0.5)
-- Idle on the tab: the page check (3), the tab bar and the selected tab (2),
-- the row count (1); the panel: the page kind, both widgets, the menu and the
-- cursor, the input owner and 11 UI action states (7). Was nothing: the tab is new.
frame_calls('MORE MODS tab, idle', {ReadProcessMemory = 43})
assert(counts.ReadProcessMemory == 43, budget.describe(counts))
-- A capture: the panel reads the page kind, both widgets, the input owner and
-- the 97 UI action states (5, no cursor or 11-state read), and consumes each
-- active UI action (select, held here).
ui_action(10, true)
frame_calls('select starts a capture', {ReadProcessMemory = 43})
frame_calls('capture, select held', {ReadProcessMemory = 41, consume = 1})
ui_action(10, false)
frame_calls('capture', {ReadProcessMemory = 41})
press('esc')
frame_calls('capture ends with Escape', {ReadProcessMemory = 41})
release('esc')
frame_calls('MORE MODS tab, idle after a capture', {ReadProcessMemory = 43})
-- Another tab: the panel reads nothing.
put32(screen + 8, 0)
frame_calls('native tab, panel closed', {ReadProcessMemory = 35})
put32(screen + 8, 4)
frame()
frame()
print('Per-frame calls on the MORE MODS tab within their pinned budgets OK')

-- 10. No allocation on idle panel frames (interpreted).
jit.off()
jit.flush()
collectgarbage('collect')
collectgarbage('stop')
local start = collectgarbage('count')
for _ = 1, 30 do wrapper(0.016) end
local bytes = (collectgarbage('count') - start) * 1024
collectgarbage('restart')
jit.on()
assert(bytes == 0, string.format('idle MORE MODS frames allocated %d bytes', bytes))
print('No allocation on idle MORE MODS frames OK')

-- 11. Leaving the tab closes the panel and cancels a capture; so does closing
-- the page; a vanished UI world drops the Gui without touching it.
ui_action(10, true)
frame()
ui_action(10, false)
assert(mbm.capture_phase() == 'arming' and state.suppressed)
put32(screen + 8, 3)
frame()
assert(mbm.capture_phase() == 'idle' and not state.suppressed and panel.gui == nil and not guis[#guis].alive)
put32(screen + 8, 4)
frame()
frame()
assert(guis[#guis].alive)
page(false)
frame()
assert(panel.gui == nil and not guis[#guis].alive)
page(true)
frame()
frame()
frame()
local count_before = #guis
world_list = {worlds.main, worlds.other}
for _ = 1, 70 do frame() end
assert(#guis > count_before and guis[#guis].world == worlds.other, 'a new Gui in the new UI world')
print('Tab change, page close and a vanished world close the panel and cancel captures OK')

-- 12. Missions: Gui text with the game's body font has crashed missions, so
-- MORE MODS is offered only outside them. In a mission the page has the native
-- tabs and MODS, the panel makes no Gui call, and extended bindings still
-- answer. The check reads the mission-mode record when a page opens and every
-- 60 page frames, never on frames without a binding page.
local function mission(on, mode)
    put32(mission_address + 8, on and 1 or 0)
    put32(mission_address + 0x40, mode or (on and 1 or 2))
end
local function open_page(selected)
    page(false)
    frame()
    put32(bar + 57448, 3); put32(bar + 57452, selected); put32(screen + 8, selected)
    page(true)
    frame()
end
local function gui_total() return #guis + gui_calls.create + gui_calls.destroy + total_gui_calls() end
-- On the ship: the fifth tab is offered.
mission(false)
open_page(0)
assert(not state.in_mission and get32(bar + 57448) == 5 and #calls.labels == 5)
-- In a mission: MODS but not MORE MODS. Tab 4 forced selected, navigation and
-- the cursor over the rows, across several mission checks: no Gui call.
assert(host.register_binding('ext.mission', 'Mission Key', nil, {category = 'Extra Mod', default = 'h'}))
mission(true)
open_page(0)
assert(state.in_mission and get32(bar + 57448) == 4 and #calls.labels == 4, 'no MORE MODS tab in a mission')
local before = gui_total()
put32(screen + 8, 4)
cursor(300, 880)
for index = 1, 200 do
    ui_action(index % 2 == 0 and 2 or 10, index % 20 == 0)
    if index % 50 == 0 then press('left', 'm') end
    frame()
    release('left', 'm')
end
ui_action(2, false); ui_action(10, false)
cursor(-100, -100)
assert(gui_total() == before and panel.gui == nil and mbm.capture_phase() == 'idle', 'a Gui call in a mission')
-- Extended bindings work in a mission, on the page and away from it (a press
-- binding: true on the frame the key goes down; the first evaluation only
-- records which inputs are held).
assert(host.is_down('ext.mission') == false)
for _, on_page in ipairs({true, false}) do
    page(on_page)
    frame()
    assert(host.is_down('ext.mission') == false)
    press('h')
    frame()
    assert(host.is_down('ext.mission') == true, 'extended binding pressed in a mission, page ' .. tostring(on_page))
    frame()
    assert(host.is_down('ext.mission') == false, 'a press fires once')
    release('h')
    frame()
    assert(host.is_down('ext.mission') == false)
end
assert(gui_total() == before, 'a Gui call in a mission')
-- The other gameplay modes count; mode 0 or a mode above 7 does not.
for _, case in ipairs({{7, true}, {0, false}, {8, false}}) do
    mission(true, case[1])
    open_page(0)
    assert(state.in_mission == case[2], 'mode ' .. case[1])
end
-- An unreadable record counts as a mission; no record at all (null) does not.
mission(false)
put64(base + 0x33266a0, 0x900000000000)
open_page(0)
assert(state.in_mission and get32(bar + 57448) == 4, 'an unreadable record counts as a mission')
put64(base + 0x33266a0, 0)
open_page(0)
assert(not state.in_mission and get32(bar + 57448) == 5)
put64(base + 0x33266a0, mission_address)
print('MORE MODS only outside missions: four tabs and no Gui call in one, extended bindings still answer OK')

-- A mission starting while MORE MODS is open (a page cannot stay open into a
-- mission; the gate is safe anyway): the next check closes the panel without
-- drawing, the selected tab stays until another is chosen, then it goes.
mission(false)
open_page(0)
put32(screen + 8, 4); put32(bar + 57452, 4)
for _ = 1, 3 do frame() end
assert(panel.gui ~= nil and guis[#guis].alive, 'the panel draws on the ship')
mission(true)
local frames = 0
while not state.in_mission do
    frame()
    frames = frames + 1
    assert(frames <= 60, 'the mission check runs within 60 page frames')
end
assert(panel.gui == nil and not guis[#guis].alive, 'the panel closes on the check frame')
before = gui_total()
for _ = 1, 120 do frame() end
assert(gui_total() == before and get32(bar + 57448) == 5, 'MORE MODS stays while selected, undrawn')
put32(screen + 8, 0); put32(bar + 57452, 0)
frame()
assert(get32(bar + 57448) == 4 and gui_total() == before, 'MORE MODS removed once another tab is selected')
-- Back on the ship: the next page offers MORE MODS again.
mission(false)
open_page(0)
assert(not state.in_mission and get32(bar + 57448) == 5)
put32(screen + 8, 4); put32(bar + 57452, 4)
for _ = 1, 3 do frame() end
assert(panel.gui ~= nil, 'the panel draws again on the ship')
print('A mission starting with MORE MODS open closes the panel without drawing; the ship offers it again OK')

-- The check's cost: on the page's first frame and every 60 page frames, the
-- record's pointer and the record (2 reads); none on other frames, none away
-- from the page.
put32(screen + 8, 0); put32(bar + 57452, 0)
open_page(0)
frame()
-- A native tab: 35 reads, as in section 9 (the 30 reset sources, the page,
-- the tab bar and the selected tab).
local steady = frame_calls('mission check: steady page frame', {ReadProcessMemory = 35}).ReadProcessMemory
assert(steady == 35)
local checks = 0
for index = 1, 120 do
    local reads = frame_calls('mission check: page frame ' .. index, {ReadProcessMemory = steady + 2})
    if reads.ReadProcessMemory == steady + 2 then checks = checks + 1
    else assert(reads.ReadProcessMemory == steady, budget.describe(reads)) end
end
assert(checks == 2, 'two mission checks in 120 page frames, got ' .. checks)
page(false)
frame()
-- Away from the page: the UI stack check only (2 reads, as before v2.3).
local away = frame_calls('mission check: away from the page', {ReadProcessMemory = 2}).ReadProcessMemory
assert(away == 2)
for index = 1, 100 do
    local reads = frame_calls('mission check: away from the page ' .. index, {ReadProcessMemory = away})
    assert((reads.ReadProcessMemory or 0) == (away or 0), budget.describe(reads))
end
print('Mission check: 2 reads per page visit and per 60 page frames, none away from the page OK')
remove_files()
