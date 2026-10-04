-- The game's widgets MOM writes besides option rows (src/rows.lua): text
-- widgets, the MODS tab, the category buttons and the description box.
local mom = ...
local ffi = require('ffi')
local state, note = mom.state, mom.note
local get8, get32, getf, get64, put8, put32 = mom.get8, mom.get32, mom.getf, mom.get64, mom.put8, mom.put32
local vector, NATIVE_LABELS = mom.vector, mom.NATIVE_LABELS

-- Escape menu: one tab bar over the GAME, SOCIAL and OPTIONS contents. The
-- widget has eight tab buttons; the screen asks for three at initialisation.
local TAB_BAR, TAB_COUNT, TAB_CURRENT, TAB_LABELS = 1248, 57448, 57452, 57320
local TAB_BUTTON_STATE, TAB_BUTTON_ACTIVE, TAB_TEXT, TAB_STRIDE = 11004, 11021, 8296, 3400
local NATIVE_TABS, OPTIONS_TAB, MODS_TAB = 3, 2, 3
-- OPTIONS content: a column of nine category buttons and one panel per category.
local CATEGORY_BUTTON, CATEGORY_STRIDE, CATEGORY_TEXT = 816, 14920, 1928
local CATEGORIES, MOD_BUTTONS = 9, 8 -- the ninth (ACCOUNT) opens another screen
-- Description box beside the rows: a frame, a title and a body text. The game
-- fills it from the selected row's setting descriptor and caches that setting
-- (requested, shown); 156 means none. Heights are size.y x scale.y.
local DESCRIPTION_BOX, DESCRIPTION_FRAME, DESCRIPTION_TITLE, DESCRIPTION_BODY = 1315800, 272, 936, 1632
local DESCRIBED_SETTING, SHOWN_SETTING, NO_SETTING = 1318500, 1318476, 156
local WIDGET_HEIGHT, WIDGET_SCALE_Y = 16, 32
-- Text widgets hold a label ID at +272 and up to 14 format arguments
-- {key, type, value} of 24 bytes from +280, with their count at +616.
local LABEL, ARGUMENTS, ARGUMENT_COUNT = 272, 280, 616
-- '#COUNT' is a pure tag template, so a string COUNT argument shows any text
-- without borrowing a localization slot. The key is MurmurHash64A("COUNT") >> 32.
local TEXT_TEMPLATE, TEXT_KEY, STRING_ARGUMENT = 0xc67c7faf, 0xab2a7b35, 1

-- Text widgets ---------------------------------------------------------------

-- Text buffers live as long as the addon: a hidden widget may still point at
-- one after the MODS view closes, until the game re-initialises that widget.
-- Their addresses are kept as numbers, so a check compares without allocating.
local function text_buffer(text)
    local buffer = state.texts[text]
    if not buffer then
        buffer = ffi.new('char[?]', #text + 1, text)
        state.texts[text] = buffer
        state.text_addresses[text] = tonumber(ffi.cast('MOM_u64', buffer))
    end
    return buffer
end

local function text_argument(widget)
    for index = 0, math.min(get8(widget + ARGUMENT_COUNT), 14) - 1 do
        local record = widget + ARGUMENTS + 24 * index
        if get32(record) == TEXT_KEY then return record end
    end
    return nil
end

local function shows_text(widget, text)
    if get32(widget + LABEL) ~= TEXT_TEMPLATE then return false end
    local record = text_argument(widget)
    if not record or get32(record + 4) ~= STRING_ARGUMENT then return false end
    text_buffer(text)
    return get64(record + 8) == state.text_addresses[text]
end

local function show_text(widget, text)
    state.native.set_label(widget, TEXT_TEMPLATE)
    state.native.set_string_arg(widget, TEXT_KEY, text_buffer(text))
end

local function show_label(widget, label)
    state.native.clear_args(widget + LABEL)
    state.native.set_label(widget, label)
end

-- MODS tab and category buttons ----------------------------------------------

-- Adds MODS as the fourth native tab. The game draws it, its index and Q/E
-- (LB/RB) cycling; relabelling resets every button's state, so the current
-- tab's selected state is restored as the screen's opener does.
local tab_labels = ffi.new('MOM_u32[?]', NATIVE_TABS + 1)
local function ensure_mods_tab(screen)
    local bar = screen + TAB_BAR
    local count = get32(bar + TAB_COUNT)
    local title = bar + TAB_TEXT + TAB_STRIDE * MODS_TAB
    if count == NATIVE_TABS + 1 then
        if get32(bar + TAB_LABELS + 4 * MODS_TAB) ~= TEXT_TEMPLATE then return false end
        if not shows_text(title, state.mods_title) then show_text(title, state.mods_title) end
        return true
    end
    if count ~= NATIVE_TABS then return false end
    local current = get32(bar + TAB_CURRENT)
    if current >= NATIVE_TABS then return false end
    for index = 0, NATIVE_TABS - 1 do
        tab_labels[index] = get32(bar + TAB_LABELS + 4 * index)
        if tab_labels[index] ~= NATIVE_LABELS.tabs[index + 1] then return false end
    end
    tab_labels[MODS_TAB] = TEXT_TEMPLATE
    state.native.set_tab_labels(bar, tab_labels, NATIVE_TABS + 1)
    local button = bar + TAB_STRIDE * current
    put32(button + TAB_BUTTON_STATE, 3)
    put8(button + TAB_BUTTON_ACTIVE, 1)
    show_text(title, state.mods_title)
    if not state.mods_tab_logged then
        state.mods_tab_logged = true
        note('Added native MODS tab (current tab ' .. current .. ').')
    end
    return true
end

local function category_button(content, index)
    return content + CATEGORY_BUTTON + CATEGORY_STRIDE * index
end

-- view.buttons: the mod (or page control) on each button, false when none.
local function label_categories(view)
    local native = state.native
    for index = 0, CATEGORIES - 1 do
        local button = category_button(view.content, index)
        local mod = index < MOD_BUTTONS and view.buttons[index + 1]
        if mod or (index == 0 and #view.mods == 0) then
            show_text(button + CATEGORY_TEXT, mod and mod.title or state.empty_text)
            native.set_visible(button, 1)
        else
            native.set_visible(button, 0)
        end
    end
end

local function restore_categories(content)
    for index = 0, CATEGORIES - 1 do
        local button = category_button(content, index)
        show_label(button + CATEGORY_TEXT, NATIVE_LABELS.categories[index + 1])
        state.native.set_visible(button, 1)
    end
end

-- Description box ------------------------------------------------------------

local function text_height(widget)
    return getf(widget + WIDGET_HEIGHT) * getf(widget + WIDGET_SCALE_Y)
end

-- Shows the entry's description the way the game's set_description lays out a
-- setting's: title over body, the frame fitted to both. MOM rows share one
-- setting without a description, so the game itself only ever hides the box.
local function describe(view, entry)
    local native, box = state.native, view.content + DESCRIPTION_BOX
    view.described = entry
    local text = entry and entry.option.description
    if not text then native.hide_description(box, 1, 1); return end
    local title, body = box + DESCRIPTION_TITLE, box + DESCRIPTION_BODY
    show_text(title, entry.option.label)
    show_text(body, text)
    native.measure_text(body)
    native.measure_text(title)
    local title_height, body_height = text_height(title), text_height(body)
    native.set_position(body, vector(14, -title_height - 24))
    native.set_opacity(body, 1)
    native.set_size(box + DESCRIPTION_FRAME, vector(450, body_height + title_height + 7 + 72))
    native.hide_description(box, 0, 1)
end

-- Hands the box back to the game: hidden at once, MOM's text arguments gone,
-- and both setting caches cleared so OPTIONS fills it again.
local function release_description(content)
    local native, box = state.native, content + DESCRIPTION_BOX
    native.hide_description(box, 1, 0)
    native.clear_args(box + DESCRIPTION_TITLE + LABEL)
    native.clear_args(box + DESCRIPTION_BODY + LABEL)
    put32(content + DESCRIBED_SETTING, NO_SETTING)
    put32(content + SHOWN_SETTING, NO_SETTING)
end

-- For the other files and the update.
mom.show_text, mom.shows_text, mom.ensure_mods_tab = show_text, shows_text, ensure_mods_tab
mom.label_categories, mom.restore_categories = label_categories, restore_categories
mom.describe, mom.release_description = describe, release_description
mom.TAB_BAR, mom.TAB_CURRENT, mom.MODS_TAB, mom.OPTIONS_TAB = TAB_BAR, TAB_CURRENT, MODS_TAB, OPTIONS_TAB
mom.CATEGORIES, mom.MOD_BUTTONS, mom.TEXT_TEMPLATE = CATEGORIES, MOD_BUTTONS, TEXT_TEMPLATE
