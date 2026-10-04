-- The MODS view: the idle gate (is the escape menu open on top?), entering,
-- keeping and leaving the MODS tab, the description following the selection,
-- and applying or discarding edits as the OPTIONS tab does.
local mom = ...
local ffi, bit = require('ffi'), require('bit')
local state, note, translation = mom.state, mom.note, mom.translation
local fill, valid_pointer, read_pointer = mom.fill, mom.valid_pointer, mom.read_pointer
local get8, get32, get64, put8, put32 = mom.get8, mom.get32, mom.get64, mom.put8, mom.put32
local apply_pending, drop_pending, save_values = mom.apply_pending, mom.drop_pending, mom.save_values
local label_categories, restore_categories = mom.label_categories, mom.restore_categories
local describe, release_description = mom.describe, mom.release_description
local build_page, page_intact, poll_page = mom.build_page, mom.page_intact, mom.poll_page
local selected_entry, apply_value, descriptor = mom.selected_entry, mom.apply_value, mom.descriptor
local CATEGORIES, MOD_BUTTONS, OPTIONS_TAB = mom.CATEGORIES, mom.MOD_BUTTONS, mom.OPTIONS_TAB
local TEXT_TEMPLATE, MAX_CHOICES = mom.TEXT_TEMPLATE, mom.MAX_CHOICES

local MENU_SYSTEM_PTR_RVA, UI_STATE_PTR_RVA = 0x347ce38, 0x347ce28
local UI_STACK, UI_STACK_ENTRIES = 0x429c, 5 -- five screen types, then their count
local ESCAPE_MENU_SCREEN, ESCAPE_MENU_TYPE = 200, 1
-- Escape menu: one tab bar over the GAME, SOCIAL and OPTIONS contents; the
-- screen's shown content is a tab index.
local SHOWN_CONTENT = 8
-- OPTIONS content: a column of nine category buttons and one panel per category.
local OPTIONS_CONTENT = 3010456
local CURRENT_CATEGORY, PREVIOUS_CATEGORY = 1318488, 1318492
-- Apply, as on the OPTIONS tab: player edits stay pending until the game's
-- apply action. The unapplied-changes flag makes the game show APPLY (hint 2)
-- and meet tab switches and back with its UNAPPLIED CHANGES dialog (mode 0),
-- whose confirm discards the edits. Native settings never change on MODS, so
-- the game's own apply (which also needs its pending settings to differ) and
-- RESET TO DEFAULT never run there.
local UNAPPLIED = 1319449
local DIALOG, DIALOG_MODE, DIALOG_STATE, DIALOG_CONFIRM, DIALOG_CONFIRM_ACTION = 1296040, 19748, 19752, 4608, 12072
local DIALOG_CANCEL, DIALOG_CANCEL_ACTION = 12160, 19624
local DIALOG_OPEN, UNAPPLIED_MODE, VISIBLE_FLAG = 2, 0, 0x10
-- The game's own confirm of mode 0 reloads the shown panel from the live
-- settings, and the DISPLAY panel's reload then rewrites rows 8 and 11 as its
-- resolution lists. Once open (texts and buttons set), the dialog is switched
-- to a mode the game's confirm ignores, and MOM discards instead.
local NEUTRAL_MODE = 2
-- Input actions evaluated this frame: byte 0 of owner + 808 + 32 * (97 *
-- group + action). Apply is Menu.ExtraOption1 (Tab), group 0.
local INPUT_OWNER_PTR_RVA, ACTION_STATES, ACTION_STRIDE, GROUP_ACTIONS, ACTION_GROUPS = 0x347cf18, 808, 32, 97, 13
local MENU_GROUP, APPLY_ACTION, APPLY_SOUND = 0, 12, 1183616600
-- Pages: with more mods than MOD_BUTTONS, the buttons show PAGE_MODS mods at a
-- time and the last button the page control. Its row is a selector whose
-- choices are the pages, so there are at most MAX_CHOICES (16, the game's
-- selector limit) pages and MAX_MODS mods.
local PAGE_MODS = MOD_BUTTONS - 1
local MAX_MODS = PAGE_MODS * MAX_CHOICES

-- Mods and the MODS view -----------------------------------------------------

-- Mods in button order: alphabetical, mods with the same shown name in the
-- order they registered. Registration admits MAX_MODS (api.register_option).
local function before(a, b)
    if a.title ~= b.title then return a.title < b.title end
    return a.sequence < b.sequence
end
local function mod_list()
    local list = {}
    for index, mod in ipairs(state.mods) do list[index] = mod end
    table.sort(list, before)
    return list
end

-- What each category button shows: with up to MOD_BUTTONS mods, view.mods
-- itself. With more, page state.mods_page of PAGE_MODS mods (false where a
-- last page runs out) and the page control on the last button.
local function button_list(view)
    local mods = view.mods
    if #mods <= MOD_BUTTONS then return mods end
    local buttons, first = {}, state.mods_page * PAGE_MODS
    for index = 1, PAGE_MODS do buttons[index] = mods[first + index] or false end
    buttons[MOD_BUTTONS] = view.control
    return buttons
end

-- Whether category button `index` shows a mod or the page control. Button 0
-- shows the empty text when no mod has registered.
local function shows(view, index)
    return index == 0 or view.buttons[index + 1]
end

-- The player turned the page control's row to page `value`: only the category
-- buttons change. The shown category stays the page control's.
local function turn_page(view, value)
    local control = view.control
    state.mods_page = value - 1
    control.order[1].value = value
    control.title = translation.tr('category.page', {page = value, pages = control.pages})
    view.buttons = button_list(view)
    label_categories(view)
    note('Showing mods page ' .. value .. ' of ' .. control.pages .. '.')
end

-- The page control: a category of one choice row naming the pages. The row
-- has no option id, so it is never an edit; turning it calls turn_page.
local function page_control(count)
    local pages = math.ceil(count / PAGE_MODS)
    state.mods_page = math.min(state.mods_page, pages - 1)
    local tr, page = translation.tr, state.mods_page + 1
    local option = {kind = 'choice', label = tr('page.label'), description = tr('page.description'), choices = {},
                    labels = {}, gap = false, value = page, turn = turn_page}
    for index = 1, pages do
        option.choices[index] = tr('page.value', {page = index, pages = pages})
        option.labels[index] = TEXT_TEMPLATE
    end
    option.descriptor, option.descriptor_block = descriptor(option)
    return {title = tr('category.page', {page = page, pages = pages}), order = {option}, pages = pages}
end

-- view.mods, view.control (the page control, when needed) and view.buttons
-- for the mods registered now.
local function list_mods(view)
    view.mods = mod_list()
    view.control = #view.mods > MOD_BUTTONS and page_control(#view.mods) or nil
    view.buttons = button_list(view)
end

-- The idle gate, run every frame: one read of the UI stack (its entries and
-- their count) answers whether the escape menu is open; only then is its
-- screen pointer read.
local ui_stack = ffi.new('MOM_u32[?]', UI_STACK_ENTRIES + 1)
local function escape_menu()
    local base = state.base
    local ui = get64(base + UI_STATE_PTR_RVA)
    if not valid_pointer(ui) or not fill(ui_stack, ui + UI_STACK, 4 * (UI_STACK_ENTRIES + 1)) then
        return nil, 'closed'
    end
    local depth = ui_stack[UI_STACK_ENTRIES]
    if depth > UI_STACK_ENTRIES then return nil, 'closed' end
    local open = false
    for index = 0, depth - 1 do
        if ui_stack[index] == ESCAPE_MENU_TYPE then open = true end
    end
    if not open then return nil, 'closed' end
    if ui_stack[depth - 1] ~= ESCAPE_MENU_TYPE then return nil, 'covered' end
    local menu = get64(base + MENU_SYSTEM_PTR_RVA)
    local screen = valid_pointer(menu) and read_pointer(menu + ESCAPE_MENU_SCREEN)
    if not screen or screen % 8 ~= 0 then return nil, 'closed' end
    return screen, 'open'
end

-- Switches the shown panel through the game's own category selection, which
-- deactivates the previous panel and builds the next one. The selection keeps
-- no previous index itself, so it is written first; reselecting the shown
-- category goes through another panel to force a fresh build.
local function select_category(content, shown, target)
    local native = state.native
    if shown == target then
        local other = target == 0 and 3 or 0
        put32(content + PREVIOUS_CATEGORY, shown)
        native.select_category(content, other)
        shown = other
    end
    put32(content + PREVIOUS_CATEGORY, shown)
    native.select_category(content, target)
end

-- The screen runs the OPTIONS content's visual pass (layout, category button
-- states, row animation, description box) only while OPTIONS is the current
-- tab, so the MODS tab runs it once per frame itself: without it a menu opened
-- on another tab is never laid out. The description then follows the selection.
local function update_visuals(view, dt)
    state.native.options_visual(view.content, dt)
    local entry = selected_entry(view)
    if entry ~= view.described then describe(view, entry) end
end

-- Whether an input action triggered this frame, on any device or binding.
-- The input owner is live whenever the menu is: the visual pass reads it.
local function action_triggered(group, action)
    local owner = get64(state.base + INPUT_OWNER_PTR_RVA)
    if not valid_pointer(owner) or group >= ACTION_GROUPS or action >= GROUP_ACTIONS then return false end
    return get8(owner + ACTION_STATES + ACTION_STRIDE * (GROUP_ACTIONS * group + action)) ~= 0
end

-- Whether a dialog button's action (u32 group, u32 action at key) triggered.
local function key_triggered(dialog, key)
    return action_triggered(get32(dialog + key), get32(dialog + key + 4))
end

local function button_triggered(dialog, button, key)
    return bit.band(get32(dialog + button), VISIBLE_FLAG) ~= 0 and key_triggered(dialog, key)
end

-- The UNAPPLIED CHANGES dialog, decided as the game decides it (0x199ce60):
-- confirmed when its shown confirm button's action triggers, cancelled when
-- its cancel button's does. When the game's input update runs before this one
-- it has already closed the dialog and cleared the confirm action (Menu.Select)
-- but not the cancel action (Menu.Back), so a dialog seen open and closed
-- since was confirmed unless its cancel action triggered. view.dialog: 'open'
-- once seen open, 'decided' once decided while still open (its closing then
-- decides nothing again). Nil when no dialog is involved.
local function unapplied_dialog(view)
    local dialog = view.content + DIALOG
    local mode = get32(dialog + DIALOG_MODE)
    local open = get32(dialog + DIALOG_STATE) == DIALOG_OPEN and (mode == UNAPPLIED_MODE or mode == NEUTRAL_MODE)
    local seen = view.dialog
    if not open then
        view.dialog = nil
        if seen ~= 'open' then return nil end
        return key_triggered(dialog, DIALOG_CANCEL_ACTION) and 'cancelled' or 'confirmed'
    end
    if seen == 'decided' then return 'open' end
    view.dialog = 'decided'
    if button_triggered(dialog, DIALOG_CONFIRM, DIALOG_CONFIRM_ACTION) then return 'confirmed' end
    if button_triggered(dialog, DIALOG_CANCEL, DIALOG_CANCEL_ACTION) then return 'cancelled' end
    view.dialog = 'open'
    return 'open'
end

-- Drops the pending edits and shows the applied values on the page's rows; the
-- page control's row (no option id) keeps its page.
local NO_ENTRIES = {}
local function discard_pending(view)
    drop_pending()
    for _, entry in ipairs(view.page and view.page.entries or NO_ENTRIES) do
        local id = entry.option.id
        if id then apply_value(entry, state.values[id]) end
    end
    note('Discarded unapplied option changes.')
end

-- Applies the pending edits on the apply action, discards them when the
-- UNAPPLIED CHANGES dialog is confirmed, and keeps the game's unapplied flag
-- in step with them. Nothing runs while no edit is pending.
local function update_apply(view)
    if state.pending_count > 0 then
        local dialog = unapplied_dialog(view)
        if dialog == 'confirmed' then
            discard_pending(view)
        elseif not dialog and action_triggered(MENU_GROUP, APPLY_ACTION) then
            note('Applied ' .. apply_pending() .. ' option changes.')
            state.native.play_sound(0, APPLY_SOUND)
        end
    else
        view.dialog = nil
    end
    local unapplied = state.pending_count > 0 and 1 or 0
    if unapplied ~= view.unapplied then
        put8(view.content + UNAPPLIED, unapplied)
        view.unapplied = unapplied
    end
end

-- Neutralises the UNAPPLIED CHANGES dialog once it is open. It finishes
-- opening inside the visual pass, which runs after update_apply, so this runs
-- after that pass: no frame leaves the game's own confirm armed. A dialog that
-- opened in that pass is watched from here, so a confirm on the game's next
-- input update counts even though update_apply never saw the dialog open.
local function neutralize_dialog(view)
    if state.pending_count == 0 then return end
    local dialog = view.content + DIALOG
    if get32(dialog + DIALOG_STATE) ~= DIALOG_OPEN then return end
    local mode = get32(dialog + DIALOG_MODE)
    if mode == UNAPPLIED_MODE then
        put32(dialog + DIALOG_MODE, NEUTRAL_MODE)
        mode = NEUTRAL_MODE
    end
    if mode == NEUTRAL_MODE and not view.dialog then view.dialog = 'open' end
end

-- Values set from code (api.set) since the last step, by option id.
local function clear_queued()
    for id in pairs(state.queued) do state.queued[id] = nil end
    state.queued_any = false
end

-- Shows the values set from code on the page's rows. Runs in the step, once the
-- view and its page have been checked this frame.
local function apply_queued(view)
    local queued = state.queued
    for _, entry in ipairs(view.page.entries) do
        local id = entry.option.id
        if queued[id] then apply_value(entry, state.values[id]) end
    end
    clear_queued()
end

local function enter_view(screen)
    local native = state.native
    local content = screen + OPTIONS_CONTENT
    local shown = get32(content + CURRENT_CATEGORY)
    -- described: the entry the description box shows; false until first set.
    -- unapplied: the game's unapplied-changes flag as last written.
    -- dialog: the UNAPPLIED CHANGES dialog as watched (unapplied_dialog).
    local view = {screen = screen, content = content, revision = state.revision,
                  saved = shown < MOD_BUTTONS and shown or 0, described = false,
                  unapplied = 0, dialog = nil}
    list_mods(view)
    -- The game's tab switch hid every content; MODS shows the OPTIONS content,
    -- which the screen feeds input while its shown content is OPTIONS (its
    -- visual pass follows the tab instead: update_visuals).
    put32(screen + SHOWN_CONTENT, OPTIONS_TAB)
    native.set_content_hidden(content, 0, 1)
    label_categories(view)
    if shown ~= 0 then select_category(content, shown, 0) end
    state.view = view
    clear_queued() -- the new page shows every value
    build_page(view, 0)
    note('Opened MODS tab: ' .. #view.mods .. ' mods.')
end

local function leave_view(view)
    local content = view.content
    local shown = view.page and view.page.index or get32(content + CURRENT_CATEGORY)
    view.page = nil
    -- The game lets the view go only once the edits are applied or discarded.
    drop_pending()
    put8(content + UNAPPLIED, 0)
    release_description(content)
    restore_categories(content)
    if shown >= MOD_BUTTONS then shown = CATEGORIES end -- no panel to deactivate
    select_category(content, shown, view.saved)
    state.view = nil
    if state.dirty then save_values() end
    note('Closed MODS tab.')
end

local function refresh_view(view)
    list_mods(view)
    view.revision = state.revision
    label_categories(view)
    local current = view.page and view.page.index or 0
    view.page = nil
    if not shows(view, current) then
        select_category(view.content, current, 0)
        current = 0
    end
    build_page(view, current)
end

local function maintain_view(view)
    local current = get32(view.content + CURRENT_CATEGORY)
    local page = view.page
    if view.revision ~= state.revision then
        refresh_view(view)
    elseif current ~= (page and page.index) then
        view.page = nil
        if shows(view, current) then
            -- The game already switched panels; replace its rows.
            build_page(view, current)
        else
            select_category(view.content, current, 0)
            build_page(view, 0)
        end
    elseif page and not page_intact(view) then
        build_page(view, current)
    end
    if view.page then
        if state.queued_any then apply_queued(view) end
        poll_page(view)
    end
end

-- For the other files and the update.
mom.escape_menu, mom.enter_view, mom.leave_view, mom.maintain_view = escape_menu, enter_view, leave_view, maintain_view
mom.update_apply, mom.update_visuals, mom.neutralize_dialog = update_apply, update_visuals, neutralize_dialog
mom.NO_ENTRIES, mom.MAX_MODS = NO_ENTRIES, MAX_MODS
