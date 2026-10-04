-- Escape-menu integration: Better Lobby Management's actions as native buttons on the
-- escape menu's GAME tab (the squad view), each confirmed with the game's own
-- confirm dialog.
--
-- The tab keeps a list of up to five native buttons and one type byte per
-- button; the game uses types 0-4, and a host uses two slots on the ship and
-- two (alone) or three in a mission. The mod adds its buttons with types 5+
-- in the free slots. The game's select handler and its dialog result
-- dispatch act only on types 0-4, but the select handler still shows the
-- shared confirm dialog for any type, so the mod fills that dialog while it is
-- hidden, as soon as the focus lands on one of its buttons, and runs the
-- action when the dialog comes back confirmed. The escape screen, and with it
-- every button, is freed when the menu closes; the buttons are added again
-- whenever they are missing.
local M = {}

M.MENU_SYSTEM_PTR = 0x347ce38
M.SCREEN = 200                  -- menu system -> escape screen (0 while the menu is closed)
M.SHOWN = 8                     -- screen: shown content (0 GAME, 1 SOCIAL, 2 OPTIONS)
M.CONTENT = 281480              -- screen -> GAME content
-- GAME content
M.CARDS, M.CARD_SIZE, M.CARD_PEER, M.CARD_STATE = 1371024, 85552, 85504, 85512
M.POPUP_OPEN = 2
M.BUTTONS, M.BUTTON_SIZE, M.BUTTON_TEXT = 1714544, 14920, 1928
M.BUTTON_LIST = 1714272         -- the container the game attaches the buttons to
M.COUNT, M.TYPES, M.MAX_BUTTONS = 1789912, 1789913, 5
M.FOCUS = 1970000               -- 0-3 cards, 4 + i button i, 255 none
M.DIALOG = 1970288
M.DIALOG_INACTIVE, M.DIALOG_ANSWERED, M.DIALOG_CONFIRMED = 1989648, 1989650, 1989651
M.HIDDEN = 1989808              -- content hidden (another tab)
-- The confirm dialog's text widgets and state (0 while hidden; the setup queues otherwise).
M.DIALOG_TITLE, M.DIALOG_BODY, M.DIALOG_STATE = 1496, 2192, 19372
-- Text widgets: label id at +272, arguments from +280. '#COUNT' is a pure tag
-- template, so a string COUNT argument shows any text (Mod Options Menu's method).
M.LABEL = 272
M.KIND_WRAPPED = 8              -- widget flags bits 18-21
M.WIDGET_X, M.WIDGET_WIDTH = 4, 12  -- widget position x and width (floats)
M.TEXT_LIMIT = 388              -- a 420-wide button less the text inset on both sides (used if unreadable)
M.TEXT_TEMPLATE, M.TEXT_KEY = 0xc67c7faf, 0xab2a7b35
-- Native button labels by type, and the confirm and cancel labels of the game's own dialogs.
M.NATIVE_LABELS = {[0] = 0x42d7cf06, [1] = 0x65e0947b, [2] = 0x801ec7e7, [3] = 0x1f6ff863, [4] = 0xcc934148}
M.CONFIRM_LABEL, M.CANCEL_LABEL = 0xd94b7608, 0x8a36d40a
M.FIRST_TYPE = 5
M.ACTIONS = {'disband', 'promote', 'cancel_sos'}
-- The player menu's own KICK (game_kick). The tab update takes input only
-- while the dialog fade is 0, the dialog is inactive and not opening and the
-- squad panel is in state 2; then it runs the focused card's popup (state 2),
-- whose KICK fires, inside the game's own update, once its hold timer
-- passes 3 s: the kick message, remove_peer, the card reset.
M.DIALOG_OPENING, M.DIALOG_FADE, M.PANEL_STATE = 1989649, 1989812, 1832636
M.CARD_POPUP = 7144             -- the popup runs only while this is set
M.CARD_KICK_HOLD = 85520        -- float seconds KICK has been held
M.KICK_HOLD_BITS = 0x42c80000   -- 100.0: past the 3 s, whatever the frame time
-- Closing the escape menu the way Esc does (the GAME tab's update, 0x18FA514):
-- the presenter manager's Main presenter (the escape menu; 0 while it is
-- closed) gets its pending-close byte, and the game closes the menu, ending
-- the menu's player pose, in its next update.
M.PRESENTERS_PTR = 0x347ce28
M.MAIN_PRESENTER, M.PENDING_CLOSE = 0x4388, 16

-- Native entry points (the start of each function must match).
M.NATIVES = {
    add_child = {rva = 0x144c5c0, type = 'LmAddChild', bytes =
        '\64\83\72\131\236\32\76\139\202\72\139\217\72\139\145\224'},
    set_label = {rva = 0x143bf90, type = 'LmSetLabel', bytes =
        '\72\131\236\40\76\139\217\57\145\16\1\0\0\15\132\128'},
    -- The same for kind-8 (wrapped) text widgets.
    set_label_wrapped = {rva = 0x1441720, type = 'LmSetLabel', bytes =
        '\72\131\236\40\76\139\217\57\145\16\1\0\0\15\132\128\0\0\0\137\145\16\1\0\0\72\139\145\112\2\0\0'},
    set_string_arg = {rva = 0x143c950, type = 'LmSetStringArg', bytes =
        '\64\83\72\131\236\32\72\139\217\72\129\193\16\1\0\0'},
    clear_args = {rva = 0x143a0f0, type = 'LmClearArgs', bytes =
        '\128\185\88\1\0\0\0\198\129\88\1\0\0\0\15\151'},
    measure_text = {rva = 0x144e1a0, type = 'LmWidgetCall', bytes =
        '\64\83\72\131\236\112\72\139\217\139\9\139\193\193\232\18'},
    set_enabled = {rva = 0x14508e0, type = 'LmSetEnabled', bytes =
        '\72\131\236\40\68\139\1\76\139\209\65\139\192\69\139\200'},
    dialog_setup = {rva = 0x179fdf0, type = 'LmDialogSetup', bytes =
        '\64\85\86\87\72\139\236\72\131\236\80\131\185\172\75\0\0\0'},
    rebuild = {rva = 0x18fbf50, type = 'LmRebuild', bytes =
        '\72\137\92\36\16\86\72\131\236\32\50\219\72\139\241\56\153\216\79\27\0'},
    -- Marquee: text wider than the given width scrolls, as the game's own long labels do.
    set_marquee = {rva = 0x143c400, type = 'LmSetMarquee', bytes =
        '\72\131\236\40\128\137\160\2\0\0\32\76\139\201\243\15\17\137\140\2\0\0'},
    -- Focus a card or button, and open a card's player menu, as a click does.
    focus = {rva = 0x18fb240, type = 'LmFocus', bytes =
        '\72\137\92\36\16\87\72\131\236\32\15\182\129\80\15\30\0\72\139\249\15\182\218\58'},
    card_state = {rva = 0x18f7e00, type = 'LmCardState', bytes =
        '\72\137\92\36\32\85\72\139\236\72\131\236\64\72\139\5\252\65\212\0\72\51\196\72'},
}

-- game.dll code that fixes the layout above.
M.CODE = {
    -- Escape screen update: the GAME content at screen+281480.
    {rva = 0x147476e, name = 'GAME tab dispatch', bytes = '\72\141\143\136\75\4\0\232\86\94\72\0'},
    -- Select handler: type byte at +1789913, 14920-byte buttons, types 0-4 only.
    {rva = 0x18fad76, name = 'GAME tab select', bytes =
        '\131\250\4\15\130\162\2\0\0\141\66\252\72\137\188\36\160\0\0\0\15\182\188\8\217\79\27\0\139\208\76'
        .. '\105\194\72\58\0\0'},
    {rva = 0x18fade7, name = 'GAME tab select types', bytes =
        '\139\207\64\132\255\116\115\131\233\1\116\71\131\233\1\116\53\131\233\1\116\35\131\249\1'},
    -- Its dialog: confirm and cancel labels, hold to confirm.
    {rva = 0x18fae6c, name = 'GAME tab dialog', bytes =
        '\198\68\36\48\0\72\141\139\112\16\30\0\198\68\36\40\1\65\185\8\118\75\217\199\68\36\32\10\212\54\138'
        .. '\232\96\79\234\255'},
    -- Dialog result: focus at +1970000, count +1789912, types 0, 2, 3, 4 only.
    {rva = 0x18fac55, name = 'GAME tab dialog result', bytes =
        '\68\56\179\19\92\30\0\15\132\171\0\0\0\15\182\131\80\15\30\0\44\4\58\131\216\79\27\0\15\131\150\0'
        .. '\0\0\15\182\192\15\182\140\24\217\79\27\0\133\201\116\113\131\233\2\116\98\131\233\1\116\21\131'
        .. '\249\1\117\120'},
    -- Button list: label table, types, buttons, list container.
    {rva = 0x18fb4be, name = 'GAME tab buttons', bytes =
        '\199\68\36\32\6\207\215\66\199\68\36\36\123\148\224\101\72\141\169\217\79\27\0\199\68\36\40\231\199'
        .. '\30\128\72\141\177\248\48\26\0\199\68\36\44\99\248\111\31\51\219\199\68\36\48\72\65\147\204'},
    {rva = 0x18fb500, name = 'GAME tab attach', bytes =
        '\15\182\135\216\79\27\0\59\216\15\141\152\0\0\0\72\99\195\72\141\151\112\41\26\0\72\105\200\72\58\0'
        .. '\0\72\3\209\72\141\143\96\40\26\0\232\145\16\181\255'},
    -- Content update: hidden flag +1989808 and dialog flags +1989648/+1989649.
    {rva = 0x18fa613, name = 'GAME tab dialog gate', bytes =
        '\128\185\176\92\30\0\0\15\133\6\7\0\0\73\137\123\24\72\129\193\112\16\30\0\77\137\115\32\69\50\246'
        .. '\68\56\179\16\92\30\0'},
    -- game_kick: the dialog fade +1989812, the panel state +1832636, the focused card's popup.
    {rva = 0x18fa5f0, name = 'GAME tab fade gate', bytes =
        '\243\15\16\129\180\92\30\0\15\87\246\15\46\198\77\139\225\76\139\250\72\139\217\15\138\25\7\0\0\15'
        .. '\133\19\7\0\0'},
    {rva = 0x18fa64c, name = 'GAME tab panel gate', bytes = '\131\187\188\246\27\0\2\116\93'},
    {rva = 0x18fa6b2, name = 'GAME tab player menu', bytes =
        '\15\182\131\80\15\30\0\60\4\15\131\249\0\0\0\72\105\200\48\78\1\0\131\188\25\152\57\22\0\2\15\133'
        .. '\228\0\0\0\72\129\193\144\235\20\0\77\139\196\72\3\203\232\24\201\255\255'},
    -- The player menu's KICK: its hold timer +85520, then the kick of the card's peer +85504.
    {rva = 0x18f78b9, name = 'player menu kick hold', bytes = '\243\15\88\134\16\78\1\0'},
    {rva = 0x18f7992, name = 'player menu kick', bytes =
        '\72\139\158\0\78\1\0\72\141\21\0\195\150\0\72\139\61\73\85\184\1\72\141\13\202\186\150\0\76\139\195'
        .. '\232\74\9\228\255\69\51\201\69\51\192\72\139\211\185\45\55\134\247\232\103\106\46\255\69\51\201\72'
        .. '\141\143\176\89\1\0\72\139\211\69\141\65\1\232\177\87\121\255'},
    -- Esc: the presenter manager global, then its Main presenter +0x4388 and pending close +16.
    {rva = 0x18fa514, name = 'escape menu close', bytes = '\72\139\29\13\41\184\1\76\141\5\90\248\156\0\69\51'},
    {rva = 0x18fa53f, name = 'escape menu pending close', bytes = '\72\139\131\136\67\0\0\72\133\192\116\16\198\64\16\1'},
}

function M.new(api, game, natives, status, note)
    local self = {}
    local ffi = require('ffi')
    local menu_cache, screen_cache = 0, 0
    local prepared = nil            -- {action, title, body} the hidden dialog holds
    local pending = nil             -- action whose dialog is open
    local release = false           -- our text is on the dialog; clear it once hidden
    local last_answered = 0
    local refused = false           -- a write was refused: no retry until the menu opens again
    local labels = {}               -- button index -> text our button there shows
    local texts, text_addresses = {}, {}

    -- Text buffers live as long as the addon: a widget may still point at one
    -- after the screen that showed it is gone.
    local function text_address(text)
        local address = text_addresses[text]
        if not address then
            local buffer = ffi.new('char[?]', #text + 1, text)
            texts[text] = buffer
            address = tonumber(ffi.cast('uintptr_t', buffer))
            text_addresses[text] = address
        end
        return address
    end

    local function show_text(widget, text)
        local kind = math.floor(api.load32(widget) / 262144) % 16
        if kind == M.KIND_WRAPPED then
            natives.set_label_wrapped(widget, M.TEXT_TEMPLATE)
        else
            natives.set_label(widget, M.TEXT_TEMPLATE)
        end
        natives.set_string_arg(widget, M.TEXT_KEY, text_address(text))
    end

    -- The width a button's text may use: the button's width less the text's
    -- inset on both sides, so longer text scrolls inside the button.
    local function text_limit(button)
        local width = api.loadf(button + M.WIDGET_WIDTH) - 2 * api.loadf(button + M.BUTTON_TEXT + M.WIDGET_X)
        if width ~= width or width < 64 or width > 4096 then return M.TEXT_LIMIT end
        return width
    end

    -- Writes bytes {offset, value, ...} relative to a 4-aligned base with one
    -- page check: the words holding them are read, changed and written back
    -- (main thread only, like every writer of these fields).
    local function put_bytes(base, changes)
        local words, first, last = {}, nil, nil
        for i = 1, #changes, 2 do
            local offset, value = changes[i], changes[i + 1]
            local word_offset = offset - offset % 4
            local word = words[word_offset] or api.load32(base + word_offset)
            local scale = 256 ^ (offset % 4)
            word = word + (value - math.floor(word / scale) % 256) * scale
            words[word_offset] = word
            first = math.min(first or word_offset, word_offset)
            last = math.max(last or word_offset, word_offset)
        end
        local flat = {}
        for word_offset, word in pairs(words) do
            flat[#flat + 1] = word_offset - first
            flat[#flat + 1] = word
        end
        return api.write_words(base + first, last - first + 4, flat)
    end

    -- The open escape screen, or 0. The menu system and a new screen are each
    -- confirmed once with a guarded read; later frames use direct loads.
    local function open_screen()
        local menu = api.load64(game + M.MENU_SYSTEM_PTR)
        if menu == 0 or menu % 8 ~= 0 then return 0 end
        if menu ~= menu_cache then
            if not api.read64(menu + M.SCREEN) then return 0 end
            menu_cache = menu
        end
        local screen = api.load64(menu + M.SCREEN)
        if screen == 0 or screen % 8 ~= 0 then screen_cache, refused = 0, false; return 0 end
        if screen ~= screen_cache then
            if not api.read32(screen + M.SHOWN) or not api.read32(screen + M.CONTENT + M.COUNT) then return 0 end
            screen_cache, prepared, pending, release, labels, last_answered = screen, nil, nil, false, {}, 0
            refused = false
        end
        return screen
    end

    local ACTION_TYPES = {}
    for index, action in ipairs(M.ACTIONS) do ACTION_TYPES[action] = M.FIRST_TYPE + index - 1 end
    local function our_action(type_byte)
        return M.ACTIONS[type_byte - M.FIRST_TYPE + 1]
    end

    -- Adds the offered actions that are missing (one checked write for all of
    -- them), relabels ours when their text changed, and has the game rebuild
    -- the list when one of ours is no longer offered. offer: action -> label;
    -- order: action names in priority order. Returns false when the write was
    -- refused.
    local function sync_buttons(content, offer, order)
        local count = api.load8(content + M.COUNT)
        if count > M.MAX_BUTTONS then return true end
        local present = {}
        for i = 0, count - 1 do
            local action = our_action(api.load8(content + M.TYPES + i))
            if action then
                if not offer[action] then
                    natives.rebuild(content, 0)
                    labels = {}
                    note('menu: buttons rebuilt (' .. action .. ' no longer offered)')
                    return true
                end
                present[action] = i
            end
        end
        local added, changes = nil, nil
        for _, action in ipairs(order) do
            if offer[action] and not present[action] and count < M.MAX_BUTTONS then
                changes, added = changes or {}, added or {}
                changes[#changes + 1] = 1 + count
                changes[#changes + 1] = ACTION_TYPES[action]
                present[action] = count
                added[#added + 1] = count
                count = count + 1
            end
        end
        if changes then
            if refused then return false end
            changes[#changes + 1] = 0
            changes[#changes + 1] = count
            if not put_bytes(content + M.COUNT, changes) then
                refused = true
                note('menu: button write refused; retried when the menu opens again')
                return false
            end
            for _, index in ipairs(added) do
                local button = content + M.BUTTONS + index * M.BUTTON_SIZE
                natives.add_child(content + M.BUTTON_LIST, button)
                labels[index] = nil
                natives.set_enabled(button, 1)
            end
        end
        for action, index in pairs(present) do
            local text = offer[action]
            if labels[index] ~= text then
                local button = content + M.BUTTONS + index * M.BUTTON_SIZE
                show_text(button + M.BUTTON_TEXT, text)
                natives.set_marquee(button + M.BUTTON_TEXT, text_limit(button))
                labels[index] = text
            end
        end
        return true
    end

    -- Puts an action's title and body on the dialog. Allowed at any time (a
    -- label change, not the queued setup).
    local function retext(content, dialog_text)
        local dialog = content + M.DIALOG
        show_text(dialog + M.DIALOG_TITLE, dialog_text.title)
        show_text(dialog + M.DIALOG_BODY, dialog_text.body)
        natives.measure_text(dialog + M.DIALOG_TITLE)
        natives.measure_text(dialog + M.DIALOG_BODY)
        release = true
    end

    -- Sets the hidden dialog up as the game does before its own dialogs (the
    -- confirm and cancel labels and the hold-to-confirm are the game's), with
    -- the action's title and body. Only while the dialog is idle: the setup
    -- queues otherwise.
    local function prepare(content, dialog_text)
        natives.dialog_setup(content + M.DIALOG, M.TEXT_TEMPLATE, M.TEXT_TEMPLATE, M.CONFIRM_LABEL, M.CANCEL_LABEL, 1, 0)
        retext(content, dialog_text)
    end

    -- Takes our text off the hidden dialog, so no COUNT argument of ours stays
    -- on a native dialog.
    local function release_dialog(content)
        local dialog = content + M.DIALOG
        natives.clear_args(dialog + M.DIALOG_TITLE + M.LABEL)
        natives.clear_args(dialog + M.DIALOG_BODY + M.LABEL)
        release, prepared = false, nil
    end

    -- The addon's fresh start (a pause after an error below it): the dialog in
    -- progress is forgotten, so an answer given meanwhile runs nothing, and the
    -- focus sets the dialog up again. Our buttons and texts stay as they are.
    function self.reset()
        prepared, pending, last_answered = nil, nil, 0
    end

    -- The open escape screen, or 0 (two direct loads while the menu is closed).
    function self.screen()
        local screen = open_screen()
        if screen == 0 then prepared, pending, release = nil, nil, false end
        return screen
    end

    -- One frame on an open escape screen while the host has a squad.
    -- offer/order: see sync_buttons; dialogs: action -> {title, body};
    -- run(action) when its dialog is confirmed. Returns the peer (lo, hi) of
    -- the squad member whose player menu is open, or nil.
    function self.step(screen, local_lo, local_hi, offer, order, dialogs, run)
        local content = screen + M.CONTENT
        local selected_lo, selected_hi
        for i = 0, 3 do
            local card = content + M.CARDS + i * M.CARD_SIZE
            if api.load32(card + M.CARD_STATE) == M.POPUP_OPEN then
                local lo, hi = api.load32(card + M.CARD_PEER), api.load32(card + M.CARD_PEER + 4)
                if (lo ~= 0 or hi ~= 0) and not (lo == local_lo and hi == local_hi) then
                    selected_lo, selected_hi = lo, hi
                end
            end
        end
        if api.load32(screen + M.SHOWN) ~= 0 or api.load8(content + M.HIDDEN) ~= 0 then
            return selected_lo, selected_hi
        end
        if not sync_buttons(content, offer, order) then
            status.menu = 'write refused'
            return selected_lo, selected_hi
        end

        local count = api.load8(content + M.COUNT)
        local focus = api.load8(content + M.FOCUS)
        local action = nil
        if focus >= 4 and focus - 4 < count then action = our_action(api.load8(content + M.TYPES + focus - 4)) end
        local inactive = api.load8(content + M.DIALOG_INACTIVE) ~= 0
        -- The answer first: the game hides the dialog in the very frame it is
        -- answered (0x13FB1A0), so it is already inactive by now.
        if pending then
            local answered = api.load8(content + M.DIALOG_ANSWERED)
            if answered ~= 0 and last_answered == 0 then
                local confirmed = api.load8(content + M.DIALOG_CONFIRMED) ~= 0
                local done = pending
                pending = nil
                note('menu: ' .. done .. (confirmed and ' confirmed' or ' cancelled'))
                if confirmed then run(done) end
            elseif inactive then
                pending = nil -- closed without an answer
            else
                last_answered = answered
            end
        end
        local dialog_text = action and dialogs[action]
        local same = dialog_text and prepared and prepared.action == action and prepared.title == dialog_text.title
            and prepared.body == dialog_text.body
        if inactive then
            if dialog_text then
                -- Our button has the focus: set the hidden dialog up for it. While
                -- it is still fading out the setup would queue, so only the text
                -- changes then; the full setup follows once it is idle.
                if api.load32(content + M.DIALOG + M.DIALOG_STATE) == 0 then
                    if not (same and prepared.full) then
                        prepare(content, dialog_text)
                        prepared = {action = action, title = dialog_text.title, body = dialog_text.body, full = true}
                    end
                elseif not same then
                    retext(content, dialog_text)
                    prepared = {action = action, title = dialog_text.title, body = dialog_text.body, full = false}
                end
            elseif release then
                release_dialog(content)
            end
        elseif not pending and dialog_text then
            -- The game opened the dialog from our button: make sure it shows this
            -- button's title and body, whatever was prepared before.
            if not same then
                retext(content, dialog_text)
                prepared = {action = action, title = dialog_text.title, body = dialog_text.body, full = false}
            end
            pending, last_answered = action, api.load8(content + M.DIALOG_ANSWERED)
        end
        return selected_lo, selected_hi
    end

    -- The player menu's own KICK for peer (lo, hi), as a click on their card
    -- and a completed hold would do: the game kicks in its next update of the
    -- tab, which follows the mod's update in the same frame. Returns
    -- 'started' and the card index, or why not now: 'menu closed', 'other
    -- tab', 'busy' (dialog or panel not taking input), 'no card', 'no player
    -- menu', 'refused' (the timer write).
    function self.game_kick(screen, lo, hi)
        if screen == 0 then return 'menu closed' end
        local content = screen + M.CONTENT
        if api.load32(screen + M.SHOWN) ~= 0 or api.load8(content + M.HIDDEN) ~= 0 then return 'other tab' end
        if api.load8(content + M.DIALOG_INACTIVE) == 0 or api.load8(content + M.DIALOG_OPENING) ~= 0
            or api.loadf(content + M.DIALOG_FADE) ~= 0 or api.load32(content + M.PANEL_STATE) ~= 2 then
            return 'busy'
        end
        for i = 0, 3 do
            local card = content + M.CARDS + i * M.CARD_SIZE
            if api.load32(card + M.CARD_PEER) == lo and api.load32(card + M.CARD_PEER + 4) == hi then
                if api.load64(card + M.CARD_POPUP) == 0 then return 'no player menu' end
                natives.focus(content, i)
                natives.card_state(card, M.POPUP_OPEN)
                -- After opening: hiding a popup is what clears the timers.
                if not api.write_words(card + M.CARD_KICK_HOLD, 4, {0, M.KICK_HOLD_BITS}) then return 'refused' end
                return 'started', i
            end
        end
        return 'no card'
    end

    -- Closes the escape menu as Esc does. The squad moving to another ship
    -- while the menu was open left the old host's Helldiver in the menu pose
    -- (v0.4-diag7). Returns true, or false and why: 'closed' (not open),
    -- 'unreadable', 'refused' (the write).
    function self.close()
        local manager = api.load64(game + M.PRESENTERS_PTR)
        if manager == 0 then return false, 'closed' end
        local main = api.read64(manager + M.MAIN_PRESENTER)
        if not main then return false, 'unreadable' end
        if main == 0 then return false, 'closed' end
        if not api.read32(main + M.PENDING_CLOSE) then return false, 'unreadable' end
        if not put_bytes(main, {M.PENDING_CLOSE, 1}) then return false, 'refused' end
        return true
    end

    -- Diagnostic builds: the dialog and focus state, logged when it changes
    -- (to explain a confirm the mod did not see).
    local traced = nil
    function self.trace(screen)
        local text = 'closed'
        if screen ~= 0 then
            local content = screen + M.CONTENT
            local focus = api.load8(content + M.FOCUS)
            local count = api.load8(content + M.COUNT)
            text = string.format('tab %d hidden %d focus %d type %s dialog inactive %d opening %d answered %d '
                .. 'confirmed %d state %d fading %d panel %d pending %s prepared %s', api.load32(screen + M.SHOWN),
                api.load8(content + M.HIDDEN), focus,
                (focus >= 4 and focus - 4 < count) and tostring(api.load8(content + M.TYPES + focus - 4)) or '-',
                api.load8(content + M.DIALOG_INACTIVE), api.load8(content + M.DIALOG_OPENING),
                api.load8(content + M.DIALOG_ANSWERED), api.load8(content + M.DIALOG_CONFIRMED),
                api.load32(content + M.DIALOG + M.DIALOG_STATE), api.loadf(content + M.DIALOG_FADE) ~= 0 and 1 or 0,
                api.load32(content + M.PANEL_STATE), tostring(pending), prepared and prepared.action or '-')
        end
        if text ~= traced then
            traced = text
            note('menu trace: ' .. text)
        end
    end

    -- Once per session: the code the layout above depends on.
    function self.verify()
        for _, code in ipairs(M.CODE) do
            if api.bytes(game + code.rva, #code.bytes) ~= code.bytes then return false, code.name .. ' changed' end
        end
        return true
    end

    return self
end

return M
