-- Mod Bindings Menu's panel for extended bindings: the binding pages' fifth
-- tab (MORE MODS), drawn with stingray.Gui inside the game's own list.
-- src/mod_bindings_menu.lua runs this file once as mbm_files.panel(mbm); it
-- adds panel_frame, panel_hide and panel_version to mbm.
--
-- Why a tab of its own: the game's list scrolls only over its own rows (97 at
-- most, each needing a native action), so an unlimited number of rows needs
-- scrolling of its own. The tab's native list holds one section header row;
-- the panel draws every extended binding below it, grouped under its mod's
-- header, and scrolls by whole rows (no clipping needed). Only visible rows
-- are drawn, with retained Gui primitives updated only when something shown
-- changes.
--
-- Geometry: the list viewport (listing+272) and the header row (listing+7856)
-- are native widgets whose solved screen rectangles the game keeps at +148
-- (x) and +156 (y, the bottom edge; y grows upward, as in a screen Gui), +36
-- and +40 (size in UI units) times the scale at +100 and +140, with +84 the
-- inherited opacity and flag 0x10 at +0 while visible (the game's hit test
-- 0x144d320 reads the same fields; Know Your Constellation draws from them).
-- The panel draws only while both are visible, opaque and sane, from the
-- header row's bottom edge to the viewport's, across the header row's width.
--
-- Input: the game's UI actions (group 0 of the input owner's action states:
-- 1 up and 2 down pressed, 5 and 6 up and down held with the game's repeat,
-- 10 select), so navigation follows the player's UI bindings on every device;
-- the cursor of the menu system (its widget at menu+1520, position at +620
-- while it is attached to the root, as the list's own hover test reads it);
-- wheel notches and the left button from stingray.Mouse. Select on a row (a
-- click selects the row under the cursor) starts a key capture
-- (src/capture.lua). While it runs, every active UI action is consumed each
-- frame through the game's consume routine (Clickable Scrollbars consumes
-- select the same way), so Back, tab switching and the rest of the page
-- ignore the keys being captured: Back cancels only the capture.
--
-- Cost: nothing off this tab. On it, per frame: 7 reads (the page kind, both
-- widgets, the menu pointer and the cursor, the input owner and 11 UI action
-- states) and one engine button read (the left button; two more for the wheel
-- while the cursor is over the panel); Gui calls only on a change. During a
-- capture instead: 5 reads (the page kind, both widgets, the input owner and
-- 97 UI action states), a consume call per active UI action and the capture's
-- own engine reads. Once a second the UI world is checked (one engine table).
-- Unmeasured in game.
local mbm = ...
local ffi = require('ffi')
local bit = require('bit')
local state, note, read_into = mbm.state, mbm.note, mbm.read_into

local VIEWPORT, HEADER_ROW, CONTROLLER_PAGE = 272, 7856, 2411904
local WIDGET_BYTES = 164
local CURSOR, CURSOR_PARENT, CURSOR_BYTES, ROOT_A, ROOT_B = 1520, 512, 116, 352, 648
local UI_ACTIONS, UI_GROUP_ACTIONS, STATE_STRIDE = 11, 97, 32
local UP, DOWN, UP_HELD, DOWN_HELD, SELECT = 1, 2, 5, 6, 10
local FONT_RVA, MATERIAL_PTR_RVA, ATLAS_RVA = 0x3772268, 0x37c5478, 0x3772ee8
local WORLD_CHECK = 1
-- UI units at scale 1 (the game's rows are 62 apart).
local PITCH, GAP, PAD, TEXT, ACCENT, BAR, KEY_COLUMN = 62, 3, 24, 22, 4, 6, 0.56
local WHEEL_ROWS = 3
-- Layers sort across every Gui in a world, 0-1023 only (KB war-table-gui-rendering).
local LAYER = {row = 1011, mark = 1012, text = 1013}
-- {alpha, red, green, blue}
local COLOUR = {row = {150, 14, 18, 26}, focus = {225, 44, 52, 64}, header = {210, 6, 8, 12},
                accent = {255, 255, 232, 0}, text = {255, 240, 243, 245}, muted = {255, 128, 136, 144},
                heading = {255, 255, 232, 0}, capture = {255, 255, 232, 0}, track = {120, 60, 68, 80},
                thumb = {220, 200, 206, 212}}
local PAGE_DEVICES = {keyboard = {k = true, m = true}, controller = {p = true}}

local viewport_buffer, row_buffer = ffi.new('MBM_u8[?]', WIDGET_BYTES), ffi.new('MBM_u8[?]', WIDGET_BYTES)
local viewport_f32, viewport_u32 = ffi.cast('float *', viewport_buffer), ffi.cast('MBM_u32 *', viewport_buffer)
local row_f32, row_u32 = ffi.cast('float *', row_buffer), ffi.cast('MBM_u32 *', row_buffer)
local scratch = ffi.new('MBM_u8[?]', CURSOR_BYTES)
local scratch_f32, scratch_u32 = ffi.cast('float *', scratch), ffi.cast('MBM_u32 *', scratch)
local actions = ffi.new('MBM_u8[?]', UI_GROUP_ACTIONS * STATE_STRIDE)
local actions_f32 = ffi.cast('float *', actions)

-- focus is a row index; focus_id the binding it shows, which keeps the focus
-- when rows are added above it.
local panel = {gui = nil, world = nil, font = nil, material = nil, slots = {}, rows = {}, model = nil,
               first = 1, focus = nil, focus_id = nil, hover = nil, cursor_x = nil, cursor_y = nil,
               select_was = false, repeat_last = {0, 0}, world_timer = 0, open_wait = 0, dirty = true,
               page = 'keyboard', left = 0, right = 0, top = 0, bottom = 0, scale = 1, count = 0,
               drawn_phase = nil, drawn_id = nil, drawn_bindings = nil, mouse_ids = nil, fitted = {}}

local function pointer_at(u32, index)
    local value = u32[index] + u32[index + 1] * 4294967296
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end

-- A widget's solved rectangle (y up) and scale, or nil unless it is visible,
-- opaque and sane.
local function solved(f32, u32)
    if bit.band(u32[0], 0x10) == 0 then return nil end
    local opacity, sx, sy = f32[21], f32[25], f32[35]
    if not (opacity >= 0.995 and opacity <= 1.01) or not (sx >= 0.3 and sx <= 4) or math.abs(sx - sy) > 0.01 then
        return nil
    end
    local x, y, w, h = f32[37], f32[39], f32[9] * sx, f32[10] * sy
    if not (x >= -16384 and x <= 32768 and y >= -16384 and y <= 32768 and w > 0 and w <= 32768
            and h > 0 and h <= 32768) then
        return nil
    end
    return x, y, x + w, y + h, sx
end

-- The panel's area from the native widgets; false when it cannot be drawn.
-- Marks the panel dirty when the area, the scale or the page kind changed.
local function read_geometry(listing)
    if not read_into(listing + CONTROLLER_PAGE, scratch, 4) then return false end
    local page = scratch_u32[0] ~= 0 and 'controller' or 'keyboard'
    if not read_into(listing + VIEWPORT, viewport_buffer, WIDGET_BYTES)
       or not read_into(listing + HEADER_ROW, row_buffer, WIDGET_BYTES) then
        return false
    end
    local _, bottom, _, _, scale = solved(viewport_f32, viewport_u32)
    local left, top, right = solved(row_f32, row_u32)
    if not bottom or not left or top - bottom < PITCH * scale then return false end
    if left ~= panel.left or right ~= panel.right or top ~= panel.top or bottom ~= panel.bottom
       or scale ~= panel.scale or page ~= panel.page then
        panel.left, panel.right, panel.top, panel.bottom, panel.scale = left, right, top, bottom, scale
        panel.page, panel.dirty = page, true
        panel.count = math.floor((top - bottom) / (PITCH * scale))
        return 'moved'
    end
    return true
end

local function binding_row(index)
    local row = panel.rows[index]
    return row ~= nil and row.record ~= nil
end

local function last_first()
    return math.max(1, #panel.rows - panel.count + 1)
end

local function scroll_to(first)
    first = math.max(1, math.min(last_first(), first))
    if first ~= panel.first then panel.first, panel.dirty = first, true end
end

local function show_focus()
    local focus = panel.focus
    if not focus then return end
    if focus < panel.first then
        -- Keep the section header above the first binding in view.
        scroll_to(binding_row(focus - 1) and focus or focus - 1)
    elseif focus > panel.first + panel.count - 1 then
        scroll_to(focus - panel.count + 1)
    end
end

-- The rows changed or the area did: the scroll stays within the rows, the focus in view.
local function settle()
    scroll_to(panel.first)
    show_focus()
end

local function set_focus(index)
    if index == panel.focus then return end
    panel.focus, panel.dirty = index, true
    panel.focus_id = index and panel.rows[index].record.id or nil
end

-- Rows: a header per category, then its bindings (state.extended_order is
-- sorted by category, then registration). The focus follows its binding.
local function build_model()
    local rows, last, focus = {}, nil, nil
    for _, record in ipairs(state.extended_order) do
        if record.category ~= last then
            rows[#rows + 1] = {header = true, text = record.category}
            last = record.category
        end
        rows[#rows + 1] = {record = record}
        if record.id == panel.focus_id then focus = #rows end
    end
    panel.rows, panel.model, panel.dirty, panel.focus = rows, state.revision, true, focus
    if not focus then panel.focus_id = nil end
    settle()
end

-- Moves the focus to the next binding row in direction step (1 or -1).
local function move_focus(step)
    local index = panel.focus or (step > 0 and 0 or #panel.rows + 1)
    repeat index = index + step until index < 1 or index > #panel.rows or binding_row(index)
    if index >= 1 and index <= #panel.rows then
        set_focus(index)
        show_focus()
    end
end

-- The input owner pointer, and its first count UI action states read into
-- actions; nil when either cannot be read.
local function read_actions(count)
    if not read_into(state.base + mbm.INPUT_OWNER_PTR_RVA, scratch, 8) then return nil end
    local owner = pointer_at(scratch_u32, 0)
    if not owner or not read_into(owner + mbm.ACTION_STATE_OFFSET, actions, count * STATE_STRIDE) then
        return nil
    end
    return owner
end

local function active(index) return actions[index * STATE_STRIDE] ~= 0 end

-- The game's held repeat (0x178dc50): fires on the press, then after half a
-- second held every 0.1 s (an analog stick part-way: up to every second).
local function repeated(index, slot)
    local held = actions_f32[index * 8 + 2]
    if active(index) then
        panel.repeat_last[slot] = held
        return true
    end
    if held <= 0.5 then return false end
    local magnitude = math.min(1, math.abs(actions_f32[index * 8 + 1]))
    if held - panel.repeat_last[slot] <= magnitude * 0.1 + (1 - magnitude) then return false end
    panel.repeat_last[slot] = held
    return true
end

local function navigate()
    if active(UP) or repeated(UP_HELD, 1) then move_focus(-1) end
    if active(DOWN) or repeated(DOWN_HELD, 2) then move_focus(1) end
end

-- The cursor position (y up), or nil while it is not attached to the root.
local function cursor()
    if not read_into(state.base + mbm.MENU_SYSTEM_PTR_RVA, scratch, 8) then return nil end
    local menu = pointer_at(scratch_u32, 0)
    if not menu or not read_into(menu + CURSOR + CURSOR_PARENT, scratch, CURSOR_BYTES) then return nil end
    local parent = pointer_at(scratch_u32, 0)
    if parent ~= menu + ROOT_A and parent ~= menu + ROOT_B then return nil end
    return scratch_f32[27], scratch_f32[28]
end

-- The binding row under the cursor, or nil.
local function row_at(x, y)
    if not x or x < panel.left or x > panel.right or y > panel.top or y < panel.bottom then return nil end
    local index = panel.first + math.floor((panel.top - y) / (PITCH * panel.scale))
    if index > panel.first + panel.count - 1 or not binding_row(index) then return nil end
    return index
end

-- The cursor: whether it is over the panel, the binding row under it (which
-- takes the focus when the cursor moves onto it).
local function track_cursor()
    local x, y = cursor()
    local moved = x ~= panel.cursor_x or y ~= panel.cursor_y
    panel.cursor_x, panel.cursor_y = x, y
    panel.inside = x ~= nil and x >= panel.left and x <= panel.right and y <= panel.top and y >= panel.bottom
    local hover = row_at(x, y)
    if hover ~= panel.hover then panel.hover, panel.dirty = hover, true end
    if moved and hover then set_focus(hover) end
end

local function mouse_ids(mouse)
    if panel.mouse_ids == nil then
        local ids = {}
        for _, name in ipairs({'left', 'wheel_up', 'wheel_down'}) do
            local ok, id = pcall(mouse.button_id, name)
            ids[name] = ok and type(id) == 'number' and id or false
        end
        panel.mouse_ids = ids
    end
    return panel.mouse_ids
end

local function mouse_pressed(mouse, id)
    if not id or type(mouse.pressed) ~= 'function' then return false end
    local ok, pressed = pcall(mouse.pressed, id)
    return ok and pressed == true
end

-- The capture's hooks: while it runs, the panel consumes UI actions.
local hooks = {hold_back = function() panel.guarding = true end,
               release_back = function() panel.guarding = false end}

local function start_capture(index)
    local row = panel.rows[index]
    if not row or not row.record then return end
    set_focus(index)
    local ok, why = mbm.begin_capture(row.record.id, hooks, panel.page)
    if not ok then note('Key capture for ' .. row.record.id .. ' not started: ' .. tostring(why) .. '.') end
end

-- One frame of the panel's own input, without a capture running. A click
-- starts a capture on the row under the cursor (a click elsewhere does
-- nothing); select from the keyboard or a controller, on the focused row.
local function handle_input(mouse)
    navigate()
    track_cursor()
    local ids = type(mouse) == 'table' and mouse_ids(mouse)
    if ids and panel.inside then
        if mouse_pressed(mouse, ids.wheel_up) then scroll_to(panel.first - WHEEL_ROWS) end
        if mouse_pressed(mouse, ids.wheel_down) then scroll_to(panel.first + WHEEL_ROWS) end
    end
    local select = active(SELECT)
    local rising = select and not panel.select_was
    panel.select_was = select
    if ids and mouse_pressed(mouse, ids.left) then
        if panel.hover then start_capture(panel.hover) end
    elseif rising and panel.focus then
        start_capture(panel.focus)
    end
end

-- While a capture runs: every active UI action of the frame is consumed, so
-- the page does not act on the keys being captured.
local function guard_page()
    local owner = read_actions(UI_GROUP_ACTIONS)
    if not owner or not mbm.consume_action then return end
    for index = 0, UI_GROUP_ACTIONS - 1 do
        if active(index) then
            local ok, problem = pcall(mbm.consume_action, owner, index * 4294967296)
            if not ok then note('Consuming UI action ' .. index .. ' failed: ' .. tostring(problem)) end
        end
    end
end

-- Texts ----------------------------------------------------------------------

local function row_label(record)
    if record.text then return record.text end
    -- A game localization ID cannot be shown outside the native rows: the
    -- binding's id stands in, e.g. 'example.toggle_hud' -> 'TOGGLE HUD'.
    local name = record.id:match('([^%.:/]+)$') or record.id
    return mbm.upper((name:gsub('[_%-]+', ' ')))
end

local function alternative_text(alternative)
    local names = {}
    for position = #alternative.inputs, 1, -1 do
        names[#names + 1] = mbm.input_label(alternative.inputs[position])
    end
    return table.concat(names, ' + ')
end

-- A binding's keys on this page, and the colour to show them in.
local function keys_text(record)
    local info = mbm.binding_info(record.id)
    if info and info.state == 'inactive' then return mbm.text('binding.inactive'), COLOUR.muted end
    local parts, devices = {}, PAGE_DEVICES[panel.page]
    for _, alternative in ipairs(mbm.current_alternatives(record.id) or {}) do
        if devices[alternative.inputs[1].device] then parts[#parts + 1] = alternative_text(alternative) end
    end
    if #parts == 0 then return mbm.text('binding.none'), COLOUR.muted end
    return mbm.upper(table.concat(parts, ' / ')), COLOUR.text
end

-- A binding row's texts and colours: its label and keys, or while its key is
-- being chosen the page's hint and prompt.
local function row_texts(record)
    local phase, id = mbm.capture_phase()
    if phase ~= 'idle' and id == record.id then
        local pad = panel.page == 'controller' and '_pad' or ''
        return mbm.text('binding.capture_hint' .. pad), COLOUR.muted, mbm.text('binding.capture' .. pad),
               COLOUR.capture
    end
    local keys, keys_colour = keys_text(record)
    return row_label(record), COLOUR.text, keys, keys_colour
end

-- Gui ------------------------------------------------------------------------

local function engine() return rawget(_G, 'stingray') end

local function ui_world(application)
    local main = application.main_world()
    for _, world in ipairs(application.worlds()) do
        if world ~= main then return world end
    end
    return nil
end

local function world_alive(application, world)
    for _, candidate in ipairs(application.worlds()) do
        if candidate == world then return true end
    end
    return false
end

local function hash_at(address)
    if not read_into(address, scratch, 8) then return nil end
    if scratch_u32[0] == 0 and scratch_u32[1] == 0 then return nil end
    return string.format('%08x%08x', scratch_u32[1], scratch_u32[0])
end

-- The active language's body font, its normal material and atlas (the native
-- font initializer keeps them there; Know Your Constellation reads the same).
local function font_hashes()
    local font, atlas = hash_at(state.base + FONT_RVA), hash_at(state.base + ATLAS_RVA)
    if not read_into(state.base + MATERIAL_PTR_RVA, scratch, 8) then return nil end
    local material_owner = pointer_at(scratch_u32, 0)
    local material = material_owner and hash_at(material_owner + 24)
    if not (font and atlas and material) then return nil end
    return font, material, atlas
end

-- Mirrors the native normal-font setup on the Gui's material.
local function ink(e, gui, material_hash, atlas_hash)
    local material = assert(e.Gui.material(gui, e.IdString64.from_hex(material_hash)), 'font material unavailable')
    local function slot(hash) return e.IdString64.from_hex(hash .. '00000000') end
    for _, hash in ipairs({'8035c266', '5e8455fe', '309e7783', '82b803a8'}) do
        e.Material.set_scalar(material, slot(hash), 0)
    end
    e.Material.set_vector2(material, slot('e13777ce'), e.Vector2(1, -1))
    e.Material.set_vector4(material, slot('7701209e'), e.Color(0, 0, 0, 0))
    e.Material.set_texture(material, slot('88bac99b'), e.IdString64.from_hex(atlas_hash))
end

-- Creates the Gui; after a failure the next try waits WORLD_CHECK seconds.
local function open_gui(e, seconds)
    panel.open_wait = panel.open_wait - seconds
    if panel.open_wait > 0 then return false end
    panel.open_wait = WORLD_CHECK
    local font, material, atlas = font_hashes()
    local world = font and ui_world(e.Application)
    if not world then return false end
    local ok, gui = pcall(e.World.create_screen_gui, world, 'scale', 1, 1)
    if not ok or not gui then
        note('Panel: no screen Gui (' .. tostring(gui) .. ').')
        return false
    end
    panel.gui, panel.world, panel.font, panel.material, panel.slots = gui, world, font, material, {}
    panel.world_timer, panel.open_wait, panel.dirty, panel.fitted = 0, 0, true, {}
    local inked, problem = pcall(ink, e, gui, material, atlas)
    if not inked then note('Panel: font material not set (' .. tostring(problem) .. ').') end
    return true
end

local function close_gui()
    local gui, world = panel.gui, panel.world
    panel.gui, panel.world, panel.slots, panel.dirty = nil, nil, {}, true
    panel.drawn_phase, panel.drawn_id, panel.drawn_bindings = nil, nil, nil
    if not gui then return end
    local e = engine()
    local ok, problem = pcall(function()
        if world_alive(e.Application, world) then e.World.destroy_gui(world, gui) end
    end)
    if not ok then note('Panel: destroying its Gui failed (' .. tostring(problem) .. ').') end
end

-- The engine while drawing (draw sets it), and each shape's {layer, colour}.
local E
local STYLE = {row = {LAYER.row, COLOUR.row}, focus = {LAYER.row, COLOUR.focus}, header = {LAYER.row, COLOUR.header},
               accent = {LAYER.mark, COLOUR.accent}, track = {LAYER.row, COLOUR.track},
               thumb = {LAYER.mark, COLOUR.thumb}}

local function colour(c) return E.Color(c[1], c[2], c[3], c[4]) end

-- One retained rectangle: created on first use, updated after; a zero size hides it.
local function rect(slot, key, x, y, w, h, style)
    local position, size = E.Vector3(x, y, style[1]), E.Vector2(w, h)
    if slot[key] then
        E.Gui.update_rect(panel.gui, slot[key], position, size, colour(style[2]))
    else
        slot[key] = E.Gui.rect(panel.gui, position, size, colour(style[2]))
    end
end

-- One retained text: created on first use (an empty one as a space), updated after.
local function text(slot, key, value, x, y, size, c)
    local font, material = E.IdString64.from_hex(panel.font), E.IdString64.from_hex(panel.material)
    local position = E.Vector3(x, y, LAYER.text)
    if slot[key] then
        E.Gui.update_text(panel.gui, slot[key], value, font, size, material, position, colour(c))
    else
        slot[key] = E.Gui.text(panel.gui, value == '' and ' ' or value, font, size, material, position, colour(c))
    end
end

-- Whether value is wider than width at size in the Gui's font (the same
-- measure as Know Your Constellation's).
local function too_wide(value, size, width)
    local lo, hi, caret = E.Gui.text_extents(panel.gui, value, E.IdString64.from_hex(panel.font), size)
    local x = E.Vector2.x
    return math.max(x(hi), x(caret)) - math.min(0, x(lo)) > width
end

-- The longest start of value, whole characters and '...', that fits width;
-- value itself when it fits or the engine cannot measure. Cached per text,
-- size and width (measured on redraws only).
local function fit(value, size, width)
    if value == '' or type(E.Gui.text_extents) ~= 'function' then return value end
    local key = value .. '\0' .. size .. '\0' .. width
    local cached = panel.fitted[key]
    if cached then return cached end
    local ok, wide = pcall(too_wide, value, size, width)
    local result = value
    if ok and wide then
        local starts = {}
        for position in value:gmatch('()[^\128-\191]') do starts[#starts + 1] = position end
        local low, high = 0, #starts - 1
        while low < high do
            local middle = math.ceil((low + high) / 2)
            local fits, wider = pcall(too_wide, value:sub(1, starts[middle + 1] - 1) .. '...', size, width)
            if fits and not wider then low = middle else high = middle - 1 end
        end
        result = value:sub(1, (starts[low + 1] or #value + 1) - 1) .. '...'
    end
    panel.fitted[key] = result
    return result
end

local function hide_slot(slot)
    if not slot.bg then return end
    for _, key in ipairs({'bg', 'mark'}) do rect(slot, key, 0, 0, 0, 0, STYLE.row) end
    for _, key in ipairs({'label', 'keys'}) do text(slot, key, '', 0, 0, 1, COLOUR.text) end
end

-- Draws row index into slot n (0 at the top).
local function draw_slot(slot, n, index)
    local s, row = panel.scale, panel.rows[index]
    local pitch = PITCH * s
    local top = panel.top - n * pitch
    local x, width = panel.left, panel.right - panel.left - (BAR + GAP) * s
    local bottom, height = top - pitch + GAP * s, pitch - 2 * GAP * s
    local baseline, size = top - pitch / 2 - TEXT * s * 0.35, TEXT * s
    if row.header then
        rect(slot, 'bg', x, bottom, width, height, STYLE.header)
        rect(slot, 'mark', 0, 0, 0, 0, STYLE.accent)
        text(slot, 'label', fit(row.text, size, width - 2 * PAD * s), x + PAD * s, baseline, size, COLOUR.heading)
        text(slot, 'keys', '', 0, 0, size, COLOUR.text)
        return
    end
    local focused = index == panel.focus or index == panel.hover
    local column = width * KEY_COLUMN
    rect(slot, 'bg', x, bottom, width, height, focused and STYLE.focus or STYLE.row)
    rect(slot, 'mark', x, bottom, focused and ACCENT * s or 0, height, STYLE.accent)
    local label, label_colour, keys, keys_colour = row_texts(row.record)
    text(slot, 'label', fit(label, size, column - 2 * PAD * s), x + PAD * s, baseline, size, label_colour)
    text(slot, 'keys', fit(keys, size, width - column - PAD * s), x + column, baseline, size, keys_colour)
end

local function draw_scrollbar()
    local slot = panel.slots.bar or {}
    panel.slots.bar = slot
    local s, total = panel.scale, #panel.rows
    if total <= panel.count then
        rect(slot, 'bg', 0, 0, 0, 0, STYLE.track)
        rect(slot, 'mark', 0, 0, 0, 0, STYLE.thumb)
        return
    end
    local x, height = panel.right - BAR * s, panel.top - panel.bottom
    local thumb = math.max(PITCH * s / 2, height * panel.count / total)
    local offset = (height - thumb) * (panel.first - 1) / (total - panel.count)
    rect(slot, 'bg', x, panel.bottom, BAR * s, height, STYLE.track)
    rect(slot, 'mark', x, panel.top - offset - thumb, BAR * s, thumb, STYLE.thumb)
end

local function draw(e)
    E = e
    for n = 0, panel.count - 1 do
        local slot = panel.slots[n + 1] or {}
        panel.slots[n + 1] = slot
        local index = panel.first + n
        if panel.rows[index] then draw_slot(slot, n, index) else hide_slot(slot) end
    end
    for n = panel.count + 1, #panel.slots do hide_slot(panel.slots[n]) end
    draw_scrollbar()
    panel.dirty = false
end

-- Frame ----------------------------------------------------------------------

local function changed_capture()
    local phase, id = mbm.capture_phase()
    if phase ~= panel.drawn_phase or id ~= panel.drawn_id or state.bindings_version ~= panel.drawn_bindings then
        panel.drawn_phase, panel.drawn_id, panel.drawn_bindings, panel.dirty = phase, id, state.bindings_version, true
    end
    return phase ~= 'idle'
end

-- The UI world still exists (checked once a second): a world change closes the Gui.
local function world_ok(e, seconds)
    panel.world_timer = panel.world_timer + seconds
    if panel.world_timer < WORLD_CHECK then return true end
    panel.world_timer = 0
    if world_alive(e.Application, panel.world) then return true end
    panel.gui, panel.world = nil, nil
    return false
end

-- Closes the panel (tab left, page closed, layout unusable, pause or stop):
-- any capture ends with reason, the Gui goes.
local function panel_hide(reason)
    if mbm.capture_phase() ~= 'idle' then mbm.cancel_capture(reason) end
    panel.guarding, panel.select_was = false, false
    if panel.gui then close_gui() end
end

-- The frame's input: a running capture (the page guarded, then its update),
-- else the panel's own navigation, cursor and select.
local function frame_input(e, seconds)
    if changed_capture() then
        -- Consumed actions read as released until they are: select counts
        -- again from its next press.
        panel.select_was = false
        if panel.guarding then guard_page() end
        mbm.update_capture(seconds)
    elseif read_actions(UI_ACTIONS) then
        handle_input(e.Mouse)
    end
    changed_capture()
end

-- One frame with the MORE MODS tab shown and its native list built.
local function panel_frame(listing, seconds)
    local e = engine()
    if type(e) ~= 'table' or type(e.Gui) ~= 'table' or not state.base then return end
    local geometry = read_geometry(listing)
    if not geometry then
        panel_hide('the page layout changed')
        return
    end
    if panel.model ~= state.revision then
        build_model()
    elseif geometry == 'moved' then
        settle()
    end
    frame_input(e, seconds)
    if panel.gui and not world_ok(e, seconds) then return end
    if not panel.gui and not open_gui(e, seconds) then return end
    if panel.dirty then
        local ok, problem = pcall(draw, e)
        if not ok then
            note('Panel: drawing failed (' .. tostring(problem) .. ').')
            panel_hide('drawing failed')
        end
    end
end

mbm.panel_frame, mbm.panel_hide = panel_frame, panel_hide
function mbm.panel_state() return panel end

-- Machine code: the panel runs only on its tab; nothing here is compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({pointer_at, solved, read_geometry, build_model, binding_row, last_first, scroll_to,
                         show_focus, settle, set_focus, move_focus, read_actions, active, repeated, navigate,
                         cursor, row_at, track_cursor, mouse_ids, mouse_pressed, start_capture, handle_input,
                         guard_page, row_label, alternative_text, keys_text, row_texts, engine, ui_world,
                         world_alive, hash_at, font_hashes, ink, open_gui, close_gui, colour, rect, text,
                         too_wide, fit, hide_slot, draw_slot, draw_scrollbar, draw, changed_capture,
                         frame_input, world_ok, panel_hide, panel_frame, hooks.hold_back, hooks.release_back,
                         mbm.panel_state}) do
        jit.off(fn)
    end
end
