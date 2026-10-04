-- The escape-menu buttons (src/menu.lua) on a simulated GAME tab: cost while
-- closed and open, adding buttons with one checked write, labels through the
-- #COUNT template, the dialog filled while hidden when our button has the
-- focus, the action run only on a confirmed answer, our text taken off the
-- dialog, re-adding after the game's rebuild, and refusals.
-- Usage: test_menu.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local M = dofile(source .. '/menu.lua')

local OFFER = {disband = 'DISBAND SQUAD', promote = 'PROMOTE TANGO'}
local ORDER = {'disband', 'promote'}
local DIALOGS = {disband = {title = 'DISBAND SQUAD', body = 'Kick every other player.'},
                 promote = {title = 'PROMOTE TANGO', body = 'Tango hosts; the squad follows.'}}

local function setup(options)
    local world = Fake.new({G = G})
    Fake.install_menu(world, M, options)
    local natives = {}
    for name, native in pairs(M.NATIVES) do natives[name] = world.api.native(native.type, Fake.GAME + native.rva) end
    local status, lines = {}, {}
    local menu = M.new(world.api, Fake.GAME, natives, status, function(line) lines[#lines + 1] = line end)
    local ran = {}
    local function frame(offer, order, dialogs)
        local screen = menu.screen()
        if screen == 0 then return nil end
        return menu.step(screen, world.local_peer.lo, world.local_peer.hi, offer or OFFER, order or ORDER,
            dialogs or DIALOGS, function(action) ran[#ran + 1] = action end)
    end
    return world, menu, frame, ran, status, lines
end

-- Closed menu: two direct loads a frame after the menu system is confirmed once.
do
    local world, menu, frame = setup()
    assert(menu.verify())
    local counts = budget.wrap(world.api)
    budget.check(budget.frame(counts, frame), {load64 = 2, read64 = 1}, 'first frame: menu system confirmed')
    for i = 1, 300 do budget.check(budget.frame(counts, frame), {load64 = 2}, 'menu closed ' .. i) end
    world.put64(Fake.GAME + M.MENU_SYSTEM_PTR, 0)
    budget.check(budget.frame(counts, frame), {load64 = 1}, 'no menu system')
end
print('PASS: with the escape menu closed a frame costs two direct loads (one guarded read ever, for the menu system)')

-- Open on the GAME tab: two buttons added after the game's two, one page check.
do
    local world, menu, frame, ran = setup()
    world.open_menu()
    local counts = budget.wrap(world.api)
    local calls = #world.calls
    local f = budget.frame(counts, frame)
    assert(f.writable_data == 1, 'one page check for every button: ' .. budget.describe(f))
    assert(world.bytes[world.content + M.COUNT] == 4)
    assert(world.bytes[world.content + M.TYPES] == 1 and world.bytes[world.content + M.TYPES + 1] == 3, 'native buttons kept')
    assert(world.our_buttons() == 'disband=DISBAND SQUAD promote=PROMOTE TANGO', world.our_buttons())
    for i = 2, 3 do
        assert(world.parents[world.button(i)] == world.content + M.BUTTON_LIST, 'attached to the list')
        assert(math.floor(world.get32(world.button(i)) / 16) % 2 == 1, 'enabled')
    end
    assert(world.shown(world.button(0) + M.BUTTON_TEXT) == M.NATIVE_LABELS[1], 'native labels untouched')
    assert(world.count('add_child') == 2 and world.count('set_enabled') == 2 and world.count('set_string_arg') == 2)
    -- The next frames change nothing and call nothing.
    calls = #world.calls
    for i = 1, 120 do
        f = budget.frame(counts, frame)
        budget.check(f, {load8 = 9, load32 = 5, load64 = 2}, 'menu open, nothing to do ' .. i)
    end
    assert(#world.calls == calls, 'no native calls while nothing changes')
    print('INFO: open menu, idle frame: ' .. budget.describe(f))
    -- A new label (another successor) is written once.
    local offer = {disband = OFFER.disband, promote = 'PROMOTE ECHO'}
    frame(offer)
    assert(world.our_buttons() == 'disband=DISBAND SQUAD promote=PROMOTE ECHO')
    calls = #world.calls
    frame(offer)
    assert(#world.calls == calls)
    assert(#ran == 0)
end
print('PASS: an open GAME tab gets our two buttons after the game\'s two with one page check; labels update once')

-- Focus, dialog and answer.
do
    local world, menu, frame, ran, status, lines = setup()
    world.open_menu()
    frame()
    world.focus(4 + 3) -- promote
    local counts = budget.wrap(world.api)
    local f = budget.frame(counts, frame)
    assert(world.count('dialog_setup') == 1, 'dialog filled while hidden')
    local setup_call = world.last('dialog_setup')
    assert(setup_call[1] == world.dialog and setup_call[2] == M.TEXT_TEMPLATE and setup_call[3] == M.TEXT_TEMPLATE)
    assert(setup_call[4] == M.CONFIRM_LABEL and setup_call[5] == M.CANCEL_LABEL and setup_call[6] == 1 and setup_call[7] == 0,
        'the game\'s own confirm/cancel labels and hold-to-confirm')
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'PROMOTE TANGO')
    assert(world.texts[world.dialog + M.DIALOG_BODY] == 'Tango hosts; the squad follows.')
    assert(world.count('measure_text') == 2)
    assert((f.writable_data or 0) == 0, 'filling the dialog writes nothing: ' .. budget.describe(f))
    frame(); frame()
    assert(world.count('dialog_setup') == 1, 'filled once while the focus stays')
    -- The game opens the dialog from our button; confirmed runs the action once.
    world.select()
    frame()
    assert(#ran == 0)
    world.answer(true)
    frame()
    assert(#ran == 1 and ran[1] == 'promote' and lines[#lines] == 'menu: promote confirmed')
    frame(); frame()
    assert(#ran == 1, 'runs once')
    world.hide_dialog()
    frame()
    -- Cancelled: nothing runs.
    world.focus(4 + 2) -- disband
    frame()
    assert(world.count('dialog_setup') == 2 and world.texts[world.dialog + M.DIALOG_TITLE] == 'DISBAND SQUAD')
    world.select(); frame()
    world.answer(false); frame()
    assert(#ran == 1 and lines[#lines] == 'menu: disband cancelled')
    world.hide_dialog(); frame()
    -- Focus on a native button: our text leaves the dialog before any native dialog.
    world.focus(4 + 1)
    frame()
    assert(world.count('clear_args') == 2 and world.texts[world.dialog + M.DIALOG_TITLE] == nil
        and world.texts[world.dialog + M.DIALOG_BODY] == nil)
    world.select(); frame()
    world.answer(true); frame()
    assert(#ran == 1, 'a native button\'s dialog never runs our action')
    world.hide_dialog(); frame()
    -- A dialog that is still showing is never refilled (the setup would queue).
    world.focus(4 + 3)
    world.put32(world.dialog + M.DIALOG_STATE, 2)
    local setups = world.count('dialog_setup')
    frame()
    assert(world.count('dialog_setup') == setups)
    world.put32(world.dialog + M.DIALOG_STATE, 0)
    frame()
    assert(world.count('dialog_setup') == setups + 1 and world.texts[world.dialog + M.DIALOG_TITLE] == 'PROMOTE TANGO')
end
print('PASS: the dialog is filled once while hidden when our button has the focus; only a confirmed answer runs '
    .. 'the action; our text leaves the dialog before a native one')

-- The addon's fresh start (a pause after an error below it): a dialog opened
-- before it and answered while the mod did not run runs nothing; the focus
-- sets the dialog up again and the next confirm runs the action.
do
    local world, menu, frame, ran = setup()
    world.open_menu()
    frame()
    world.focus(4 + 3) -- promote
    frame()
    world.select(); frame() -- the game opened the dialog from our button
    local counts = budget.wrap(world.api)
    assert(next(budget.frame(counts, menu.reset)) == nil, 'reset reads nothing')
    world.answer(true) -- confirmed during the pause
    frame()
    assert(#ran == 0, 'an answer given while the mod was paused runs nothing')
    local setups = world.count('dialog_setup')
    world.hide_dialog(); frame()
    assert(world.count('dialog_setup') == setups + 1, 'the dialog is set up again for the focused button')
    world.select(); frame()
    world.answer(true); frame()
    assert(#ran == 1 and ran[1] == 'promote', 'the next confirm runs the action')
end
print('PASS: after reset an answer given meanwhile runs nothing; the next confirm runs the action')

-- Real-game timing: the dialog hides in the frame it is answered and fades out
-- (state 3); a click can land on another of our buttons meanwhile, or in the
-- same frame as the focus change. The dialog always shows the clicked button's
-- text, and a confirm runs that button's action.
do
    local world, menu, frame, ran, status, lines = setup()
    world.open_menu()
    frame()
    world.focus(4 + 2) -- disband
    frame()
    world.select(); frame()
    world.answer(false); frame() -- hidden at once, fading out
    assert(#ran == 0 and lines[#lines] == 'menu: disband cancelled', lines[#lines])
    local setups = world.count('dialog_setup')
    world.focus(4 + 3) -- promote, while the dialog still fades out
    frame()
    assert(world.count('dialog_setup') == setups, 'no setup while the dialog fades out (it would queue)')
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'PROMOTE TANGO', 'the text follows at once')
    world.select(); frame()
    world.answer(true); frame()
    assert(#ran == 1 and ran[1] == 'promote', 'the clicked button runs: ' .. tostring(ran[1]))
    world.hide_dialog(); frame()
    assert(world.count('dialog_setup') == setups + 1, 'the full setup follows once the dialog is idle')
    -- Focus change and click in one frame: the dialog is rewritten for the clicked button.
    world.focus(4 + 3); frame() -- promote prepared
    world.focus(4 + 2) -- disband, clicked before our update ran
    world.select(); frame()
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'DISBAND SQUAD', world.texts[world.dialog + M.DIALOG_TITLE])
    assert(world.texts[world.dialog + M.DIALOG_BODY] == 'Kick every other player.')
    world.answer(true); frame()
    assert(#ran == 2 and ran[2] == 'disband')
    -- The dialog closed by another way (no answer): nothing runs.
    world.hide_dialog(); frame()
    world.focus(4 + 2); frame()
    world.select(); frame()
    world.hide_dialog(); frame()
    assert(#ran == 2)
end
print('PASS: with the game\'s timing (hidden when answered, fading out) the dialog shows the clicked button\'s text '
    .. 'and a confirm runs that button\'s action')

-- A mission's list (the host's types 2 and 3): a third action, type 7, gets
-- its slot, its dialog and its confirm like the others; an offer without it
-- has the game rebuild the list.
do
    local world, menu, frame, ran = setup({native_types = {2, 3}})
    local offer, order = {cancel_sos = 'CANCEL SOS'}, {'cancel_sos'}
    local dialogs = {cancel_sos = {title = 'CANCEL SOS', body = 'No more players join through your SOS.'}}
    world.open_menu()
    frame(offer, order, dialogs)
    assert(world.our_buttons() == 'cancel_sos=CANCEL SOS' and world.bytes[world.content + M.TYPES + 2] == 7,
        world.our_buttons())
    world.focus(4 + 2)
    frame(offer, order, dialogs)
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'CANCEL SOS')
    world.select(); frame(offer, order, dialogs)
    world.answer(true); frame(offer, order, dialogs)
    assert(#ran == 1 and ran[1] == 'cancel_sos' and world.last_select == 7)
    frame({}, {}, {})
    assert(world.count('rebuild') == 1 and world.our_buttons() == '' and world.bytes[world.content + M.COUNT] == 2)
end
print('PASS: a mission\'s list takes a third action (type 7) after the game\'s two: slot, dialog and confirm; an offer '
    .. 'without it has the game rebuild the list')

-- Long labels scroll inside the button: the game's marquee at the button's width less the text inset.
do
    local world, menu, frame = setup({button_width = 420})
    world.open_menu()
    frame()
    for i = 2, 3 do
        assert(world.marquees[world.button(i) + M.BUTTON_TEXT] == 388, 'marquee width ' .. tostring(world.marquees[world.button(i) + M.BUTTON_TEXT]))
    end
    assert(world.marquees[world.button(0) + M.BUTTON_TEXT] == nil, 'native buttons untouched')
    local marquees = world.count('set_marquee')
    frame()
    assert(world.count('set_marquee') == marquees, 'set once per label')
    world, menu, frame = setup({button_width = 0})
    world.open_menu()
    frame()
    assert(world.marquees[world.button(2) + M.BUTTON_TEXT] == M.TEXT_LIMIT, 'unreadable width: the default')
end
print('PASS: our labels use the game\'s marquee at the button\'s text width (388 px for a 420 px button)')

-- The game's rebuild, offers that shrink, a full list, a refused write, a new screen, other tabs.
do
    local world, menu, frame = setup()
    world.open_menu()
    frame()
    world.game_rebuild({0, 1, 2, 3}) -- e.g. the host changed: the game rebuilds the list
    assert(world.our_buttons() == '')
    frame()
    assert(world.our_buttons() == 'disband=DISBAND SQUAD', 'as many as fit, in order')
    -- An offer that shrinks: the game rebuilds, then what is left comes back.
    world.game_rebuild({1, 3})
    frame()
    local shrunk = {promote = OFFER.promote}
    frame(shrunk, {'promote'})
    assert(world.count('rebuild') == 1 and world.our_buttons() == '')
    frame(shrunk, {'promote'})
    assert(world.our_buttons() == 'promote=PROMOTE TANGO')
    -- Full list: nothing added.
    world.game_rebuild({0, 1, 2, 3, 4})
    local calls = #world.calls
    frame()
    assert(world.our_buttons() == '' and #world.calls == calls)
    -- Refused write: nothing attached, reported.
    world.game_rebuild({1, 3})
    world.readonly = true
    local attached = world.count('add_child')
    local counts = budget.wrap(world.api)
    local page_checks = 0
    for _ = 1, 10 do page_checks = page_checks + (budget.frame(counts, frame).writable_data or 0) end
    assert(page_checks == 1, 'a refused write is not retried on the same screen')
    assert(world.our_buttons() == '' and world.count('add_child') == attached, 'nothing attached after a refused write')
    world.readonly = false
    frame()
    assert(world.our_buttons() == '')
    world.close_menu(); frame() -- the menu closes and opens again: retried
    world.open_menu()
    frame()
    assert(world.our_buttons() ~= '')
    -- Another tab, or hidden content: no sync.
    world.game_rebuild({1, 3})
    world.put32(Fake.SCREEN + M.SHOWN, 2)
    frame()
    assert(world.our_buttons() == '')
    world.put32(Fake.SCREEN + M.SHOWN, 0)
    world.bytes[world.content + M.HIDDEN] = 1
    frame()
    assert(world.our_buttons() == '')
    world.bytes[world.content + M.HIDDEN] = 0
    frame()
    assert(world.our_buttons() ~= '')
    -- Menu closed and opened again (a new screen object): confirmed once, labels written again.
    world.close_menu()
    assert(frame() == nil)
    world.open_menu()
    local counts = budget.wrap(world.api)
    local f = budget.frame(counts, frame)
    assert(f.read32 == 2 and world.our_buttons() ~= '', 'a new screen is confirmed with two guarded reads')
end
print('PASS: after the game\'s rebuild ours come back (as many as fit); an offer that shrinks rebuilds; a full list, '
    .. 'a refused write, other tabs and hidden content add nothing; a reopened menu is confirmed again')

-- The squad member whose player menu is open is reported; the host's own card is not.
do
    local world, menu, frame = setup()
    world.open_menu()
    local tango = Fake.peer(0x0a000001, 0x2a1b3c4d)
    assert(frame() == nil)
    world.open_popup(2, tango)
    local lo, hi = frame()
    assert(lo == tango.lo and hi == tango.hi)
    world.open_popup(2, nil)
    world.open_popup(0, world.local_peer)
    assert(frame() == nil, 'the host\'s own card is never a successor')
end
print('PASS: the squad member whose player menu is open is reported as the choice')

-- The player menu's own KICK: the kicked player's card focused, its menu
-- opened and its hold timer past 3 s, only while the tab takes input.
do
    local TANGO = Fake.peer(0x01000000, 0x00000005)
    local world, menu = setup()
    world.session = {world.local_peer, TANGO}
    assert(menu.game_kick(0, TANGO.lo, TANGO.hi) == 'menu closed')
    world.open_menu(1)
    assert(menu.game_kick(menu.screen(), TANGO.lo, TANGO.hi) == 'other tab')
    world.open_menu()
    local screen, content = menu.screen(), world.content
    local function busy(set, value, putf)
        if putf then world.putf(content + set, value) else world.bytes[content + set] = value end
        assert(menu.game_kick(screen, TANGO.lo, TANGO.hi) == 'busy', 'busy with +' .. set)
        world.open_menu()
    end
    busy(M.DIALOG_INACTIVE, 0)
    busy(M.DIALOG_OPENING, 1)
    busy(M.DIALOG_FADE, 0.25, true)
    world.put32(content + M.PANEL_STATE, 1)
    assert(menu.game_kick(screen, TANGO.lo, TANGO.hi) == 'busy', 'busy while the panel takes no input')
    world.open_menu()
    assert(menu.game_kick(screen, 7, 7) == 'no card')
    world.put64(world.card(1) + M.CARD_POPUP, 0)
    assert(menu.game_kick(screen, TANGO.lo, TANGO.hi) == 'no player menu')
    world.open_menu()
    world.readonly = true
    assert(menu.game_kick(screen, TANGO.lo, TANGO.hi) == 'refused')
    world.readonly = false
    world.open_menu()
    local calls = #world.calls
    local status, card = menu.game_kick(screen, TANGO.lo, TANGO.hi)
    assert(status == 'started' and card == 1, tostring(status))
    assert(world.calls[calls + 1].name == 'focus' and world.calls[calls + 1][2] == 1)
    assert(world.calls[calls + 2].name == 'card_state' and world.calls[calls + 2][1] == world.card(1)
        and world.calls[calls + 2][2] == M.POPUP_OPEN)
    assert(world.bytes[content + M.FOCUS] == 1 and world.get32(world.card(1) + M.CARD_STATE) == M.POPUP_OPEN)
    assert(world.api.loadf(world.card(1) + M.CARD_KICK_HOLD) == 100, 'the hold timer past 3 s')
    -- The game's next tab update kicks Tango and resets the card.
    world.menu_update()
    assert(world.last('game_popup_kick')[1] == Fake.key(TANGO) and world.get32(world.card(1) + M.CARD_PEER) == 0)
end
print('PASS: game_kick focuses the kicked player\'s card, opens its player menu and completes the KICK hold, only '
    .. 'while the GAME tab takes input; it reports why otherwise')

-- close: the escape menu's pending close, as Esc sets it; the game closes the menu in its next update.
do
    local world, menu = setup()
    local ok, why = menu.close()
    assert(ok == false and why == 'closed' and world.count('escape_closed') == 0, why)
    world.open_menu()
    local counts = budget.wrap(world.api)
    local frame
    frame, ok, why = budget.frame(counts, menu.close)
    assert(ok == true, tostring(why))
    budget.check(frame, {load32 = 1, load64 = 1, read32 = 1, read64 = 1, write_words = 1, writable_data = 1}, 'close')
    assert(world.bytes[Fake.MAIN + M.PENDING_CLOSE] == 1 and menu.screen() ~= 0, 'open until the game\'s update')
    world.menu_update()
    assert(world.count('escape_closed') == 1 and menu.screen() == 0, 'closed by the game')
    ok, why = menu.close()
    assert(ok == false and why == 'closed', why)
    world.open_menu()
    world.readonly = true
    ok, why = menu.close()
    assert(ok == false and why == 'refused', why)
    world.readonly = false
    world.unmapped[Fake.PRESENTERS + M.MAIN_PRESENTER] = true
    ok, why = menu.close()
    assert(ok == false and why == 'unreadable', why)
end
print('PASS: close sets the escape menu\'s pending close with one page check and the game closes it in its next '
    .. 'update; a closed menu, a refused write and unreadable memory are reported')

-- Diagnostic trace: one line per change of the dialog and focus state.
do
    local world, menu, frame, _, _, lines = setup()
    menu.trace(0)
    world.open_menu()
    menu.trace(menu.screen())
    menu.trace(menu.screen())
    world.focus(5)
    menu.trace(menu.screen())
    assert(#lines == 3 and lines[1] == 'menu trace: closed' and lines[3]:find('focus 5 type 3', 1, true), lines[3])
end
print('PASS: the diagnostic menu trace logs the dialog and focus state once per change')

-- Changed code disables the menu.
do
    for _, code in ipairs(M.CODE) do
        local world, menu = setup()
        world.changed = Fake.GAME + code.rva
        local ok, why = menu.verify()
        assert(ok == false and why == code.name .. ' changed', why)
    end
end
print('PASS: each of the ' .. #M.CODE .. ' code signatures disables the menu when changed')
