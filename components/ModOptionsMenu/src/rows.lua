-- Option rows and category pages: a mod's options built into the game's own
-- rows on the shown category's panel, then checked and polled every frame.
local mom = ...
local ffi = require('ffi')
local state = mom.state
local get32, getf, get64, put8, put32, putf = mom.get32, mom.getf, mom.get64, mom.put8, mom.put32, mom.putf
local valid_pointer, PIVOT, vector, aligned = mom.valid_pointer, mom.PIVOT, mom.vector, mom.aligned
local INERT_SETTING = mom.INERT_SETTING -- setting 139: src/native.lua
local show_text, shows_text, TEXT_TEMPLATE = mom.show_text, mom.shows_text, mom.TEXT_TEMPLATE
local snap, set_pending, shown_value = mom.snap, mom.set_pending, mom.shown_value

local ROW_ARRAY, MAX_ROWS = 144000, 32
-- Category panels, in category order. Each family keeps its row count, layout
-- and settings pointer at its own offsets; all panels share the row array.
local PANELS = {
    [0] = {offset = 1150848, family = 'simple', selected = 2872}, -- GAMEPLAY
    [1] = {offset = 1179528, family = 'large', selected = 33296}, -- DISPLAY
    [2] = {offset = 1253248, family = 'large', selected = 33296}, -- GRAPHICS
    [3] = {offset = 1287376, family = 'simple', selected = 2872}, -- AUDIO
    [4] = {offset = 1153728, family = 'simple', selected = 2872}, -- HUD
    [5] = {offset = 1156616, family = 'access', selected = 22392}, -- ACCESSIBILITY
    [6] = {offset = 1290256, family = 'simple', selected = 2880}, -- CONTROLLER
    [7] = {offset = 1293152, family = 'simple', selected = 2872}, -- MOUSE & KEYBOARD
}
local FAMILIES = {
    simple = {count = 2832, x = 2836, gap = 2840, height = 2844, settings = 2856, scrolls = 2830},
    large = {count = 33256, x = 33260, gap = 33264, height = 33268, settings = 33280, scrolls = 33254},
    access = {count = 22352, x = 22356, gap = 22360, settings = 22376, scrolls = 22350},
}
local PANEL_ROWS, PANEL_CONTAINER, PANEL_SCROLL, SCROLL_POSITION = 2816, 544, 816, 1976
local VIEW_HEIGHT, ROW_HEIGHT, GAP_HEIGHT = 806, 64, 32
-- Option rows (31464 bytes each).
local ROW_STRIDE, ROW_TEXT, ROW_SELECTOR, ROW_VALUE_TEXT = 31464, 3992, 16016, 16832
local ROW_INDEX, ROW_SLIDER, ROW_SLIDER_VALUE, ROW_SETTING = 29068, 29176, 31408, 31428
local ROW_CHOICE_COUNT, ROW_CHOICES = 29072, 29080 -- selector choice count and label IDs
local DESCRIPTOR_SIZE = 216
local WIDGET_INT_SLIDER, WIDGET_FLOAT_SLIDER, WIDGET_SELECTOR = 0, 1, 2

-- Native rows ----------------------------------------------------------------

-- The same layout as the game's descriptors (a float slider of 0.01 steps
-- there uses +48 = 6, +52 = 1, format 0x6220), 16-byte aligned like theirs.
-- Returns the descriptor and the block that keeps it alive.
local function descriptor(option)
    local blob, block = aligned(DESCRIPTOR_SIZE)
    local words, floats = ffi.cast('MOM_u32 *', blob), ffi.cast('float *', blob)
    words[0], words[1], words[3], words[4] = INERT_SETTING, 10, 0, TEXT_TEMPLATE
    if option.kind == 'slider' then
        words[2] = option.decimals == 0 and WIDGET_INT_SLIDER or WIDGET_FLOAT_SLIDER
        floats[9], floats[10], floats[11] = option.min, option.max, option.step
        floats[12], floats[13] = option.decimals == 0 and 20 or 6, 1
        -- Float values: two integer digits and the option's decimal places.
        words[14] = option.decimals == 0 and 0 or 0x6200 + option.decimals * 16
    else
        words[2], words[16] = WIDGET_SELECTOR, #option.labels
        for index, label in ipairs(option.labels) do words[16 + index] = label end
    end
    return blob, block
end

local function row_value(entry)
    if entry.option.kind == 'slider' then return getf(entry.row + ROW_SLIDER_VALUE) end
    return get32(entry.row + ROW_INDEX)
end

-- The value a row holds, or nil when the option cannot take it: a slider at
-- NaN or an infinity (snap), or a selector index past the option's choices.
-- The player's input never makes one; the game or another mod could.
local function decode_row(option, raw)
    if option.kind == 'toggle' then return raw == 1 end
    if option.kind == 'choice' then return raw < #option.choices and raw + 1 or nil end
    return snap(option, raw)
end

-- Custom choice words share the '#COUNT' template, so the shown word is the
-- value widget's argument.
local function show_choice(entry)
    local option = entry.option
    if option.kind ~= 'choice' then return end
    local index = get32(entry.row + ROW_INDEX)
    local text = option.choices[index + 1]
    if text and option.labels[index + 1] == TEXT_TEMPLATE then
        show_text(entry.row + ROW_VALUE_TEXT, text)
    end
end

local function apply_value(entry, value)
    local option, native = entry.option, state.native
    if option.kind == 'slider' then
        native.set_slider(entry.row + ROW_SLIDER, value)
    else
        local index = option.kind == 'toggle' and (value and 1 or 0) or value - 1
        native.set_choice(entry.row + ROW_SELECTOR, index)
        show_choice(entry)
    end
    entry.raw = row_value(entry)
end

local function finish_panel(panel, family, name)
    local native = state.native
    local count = get32(panel + family.count)
    local height = count * ROW_HEIGHT - getf(panel + family.gap)
    if family.height then putf(panel + family.height, height) end
    if name == 'simple' then native.finish_simple(panel); return end
    if name == 'access' then native.finish_access(panel); return end
    -- The large panels finish inline in their builders; this is the same sequence.
    local scroll = panel + PANEL_SCROLL
    if count == 0 then
        native.set_opacity(scroll, 0)
        put8(panel + family.scrolls, 0)
        return
    end
    native.scroll_thumb(scroll, math.min(1, VIEW_HEIGHT / height))
    native.scroll_extent(scroll, height - VIEW_HEIGHT)
    if height > VIEW_HEIGHT then
        native.set_opacity(scroll, 1)
        put8(panel + family.scrolls, 1)
    else
        native.set_opacity(scroll, 0)
        if getf(scroll + SCROLL_POSITION) ~= 0 then
            putf(scroll + SCROLL_POSITION, 0)
            native.scroll_reset(scroll)
        end
        put8(panel + family.scrolls, 0)
    end
end

-- Category pages -------------------------------------------------------------

-- Every panel build first releases all rows, last to first, which detaches
-- them from whichever panel listed them. The reset loads both rectangles with
-- movaps, so they must be 16-byte aligned.
local ZERO_RECT
ZERO_RECT, state.zero_rect_block = aligned(16) -- the block stays referenced, so it is never collected
ZERO_RECT = ffi.cast('const float *', ZERO_RECT)
local function release_rows(rows)
    for index = MAX_ROWS - 1, 0, -1 do
        local row = rows + ROW_STRIDE * index
        state.native.row_reset(row, ZERO_RECT, ZERO_RECT)
        state.native.row_release(row)
    end
end

-- What a row shows: the page control (src/view.lua) its page, an option its
-- pending edit or applied value.
local function row_shown(option) return option.value or shown_value(option) end

-- Replaces the rows the game built for category `index` with the options of
-- the mod on that button (or the page control's row), following the panel
-- builders: released rows, native row initialisation from a descriptor, the
-- same positions and gaps, then the panel's own finishing layout.
local function build_page(view, index)
    local native = state.native
    local spec = PANELS[index]
    local family = FAMILIES[spec.family]
    local panel = view.content + spec.offset
    local rows = get64(panel + PANEL_ROWS)
    if rows ~= view.content + ROW_ARRAY then return false end
    local settings = get64(panel + family.settings)
    if not valid_pointer(settings) then settings = 0 end
    local mod = view.buttons[index + 1]
    local options = mod and mod.order or {}
    local count = math.min(#options, MAX_ROWS)
    local page = {index = index, entries = {}}
    release_rows(rows)
    local gap = 0
    for position = 1, count do
        local option = options[position]
        if option.gap and position > 1 then gap = gap - GAP_HEIGHT end
        local row = rows + ROW_STRIDE * (position - 1)
        native.row_init(row, vector(0, (position - 1) * -ROW_HEIGHT + gap), PIVOT, PIVOT, 10,
                        settings, option.descriptor, 1)
        native.add_child(panel + PANEL_CONTAINER, row)
        show_text(row + ROW_TEXT, option.label)
        local entry = {row = row, option = option}
        apply_value(entry, row_shown(option))
        page.entries[position] = entry
    end
    put32(panel + family.count, count)
    putf(panel + family.x, 0)
    putf(panel + family.gap, gap)
    if get32(panel + spec.selected) >= count then put32(panel + spec.selected, 0) end
    finish_panel(panel, family, spec.family)
    view.page = page
    return true
end

-- The page is intact while the panel lists exactly its rows and each still
-- shows its option; a revert or device change rebuilds the panel natively,
-- and the DISPLAY panel's settings reload rewrites rows 8 and 11 in place
-- (their choice lists), so selectors check their choices too.
local function page_intact(view)
    local page = view.page
    local family = FAMILIES[PANELS[page.index].family]
    local panel = view.content + PANELS[page.index].offset
    if get32(panel + family.count) ~= #page.entries then return false end
    for _, entry in ipairs(page.entries) do
        local row, option = entry.row, entry.option
        if get32(row + ROW_SETTING) ~= INERT_SETTING or not shows_text(row + ROW_TEXT, option.label) then
            return false
        end
        if option.kind ~= 'slider' and (get32(row + ROW_CHOICE_COUNT) ~= #option.labels
                                        or get32(row + ROW_CHOICES) ~= option.labels[1]) then
            return false
        end
    end
    return true
end

-- A row the player changed: the page control's row turns the page
-- (option.turn), an option's row becomes a pending edit.
local function take_row(view, entry, raw, value)
    entry.raw = raw
    show_choice(entry)
    local option = entry.option
    if option.turn then option.turn(view, value) else set_pending(option.id, value) end
end

-- A row value the option cannot take (decode_row) is refused: the row is set
-- back to the value it showed, once. A row that stays at NaN after that
-- compares unequal to itself on every frame, so it is left alone instead of
-- written again each frame.
local function poll_page(view)
    for _, entry in ipairs(view.page.entries) do
        local raw = row_value(entry)
        if raw ~= entry.raw then
            local value = decode_row(entry.option, raw)
            if value ~= nil then
                take_row(view, entry, raw, value)
            elseif raw == raw or entry.raw == entry.raw then
                apply_value(entry, row_shown(entry.option))
            end
        end
    end
end

-- The page entry on the row the panel has selected (hovered with the mouse),
-- the same row the game's own description follows.
local function selected_entry(view)
    local page = view.page
    if not page then return nil end
    local spec = PANELS[page.index]
    return page.entries[get32(view.content + spec.offset + spec.selected) + 1]
end

-- For the other files.
mom.descriptor, mom.apply_value, mom.build_page = descriptor, apply_value, build_page
mom.page_intact, mom.poll_page, mom.selected_entry = page_intact, poll_page, selected_entry
mom.MAX_ROWS = MAX_ROWS
