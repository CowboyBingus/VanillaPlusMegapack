-- The addon wiring (src/addon.lua) with the real modules and the fake game:
-- startup refusals, the escape-menu buttons (the successor from the player
-- menu the host opened), the idle gate's exact calls (no page checks while
-- idle), actions confirmed in the dialog, the Lobby Region option, error
-- containment and the shutdown hook.
-- Usage: test_addon.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local L = dofile(source .. '/lobby.lua')
local R = dofile(source .. '/region.lua')
local M = dofile(source .. '/menu.lua')
local C = dofile(source .. '/chat.lua')
local S = dofile(source .. '/scanner.lua')
local B = dofile(source .. '/sos.lua')
local Text = dofile(source .. '/bingus_text.lua')
local ENGLISH = dofile(source .. '/../locales/en.lua')
local function english(key, values) return Text.format(assert(ENGLISH.strings[key], key), values or {}) end
local BUILD = {version = 'v-test', game_sha256 = 'GAME', exe_sha256 = 'EXE'}
local TANGO, CHARLIE = Fake.peer(0x01000000, 0x00000005), Fake.peer(0x0a000000, 0x00000007)

local function options_menu(saved, behaviour, version)
    local menu = {api = 1, version = version, registered = {}, callbacks = {}}
    function menu.register_option(id, spec)
        if behaviour == 'refuse' then return false, 'too many mods' end
        if behaviour == 'error' then error('menu broke', 0) end
        menu.registered[#menu.registered + 1] = {id = id, spec = spec}
        return true
    end
    function menu.get(id) return (saved or {})[id] end
    function menu.on_change(id, fn) menu.callbacks[id] = fn; return true end
    return menu
end

-- Loads src/addon.lua into a fresh global table over a fresh fake game.
-- setup.language: the Steam language the game would report (default English);
-- setup.packs: translation packs registered before the addon, as pack add-ons are.
local function install(setup)
    setup = setup or {}
    rawset(_G, 'BingusTranslations', nil)
    Text.registry().steam_language = setup.language or 'en'
    for _, pack in ipairs(setup.packs or {}) do Text.register(pack) end
    local world = Fake.new({G = G, R = R})
    Fake.install_config(world, R, setup.config)
    Fake.install_menu(world, M, setup.menu)
    Fake.install_chat(world, C, G)
    Fake.install_scanner(world, S)
    Fake.install_sos(world, B, G)
    -- Squad messages are unavailable unless asked for: the chat send's code differs.
    if not setup.chat then world.code[Fake.GAME + C.SEND.rva] = ('x'):rep(#C.SEND.bytes) end
    world.names[Fake.key(TANGO)], world.names[Fake.key(CHARLIE)] = 'Tango', 'Charlie'
    if setup.world then setup.world(world) end
    world.sync()
    local env = setmetatable({}, {__index = _G}); env._G = env
    local lines, updates, shutdowns = {}, {}, 0
    env.CowboyBingusModLoader = {api = 1, version = 17, open_log = function(name)
        assert(name == 'BetterLobbyManagement.log')
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}
    env.ModOptionsMenu = setup.options
    env.update = function(dt) updates[#updates + 1] = dt; return 'ret1', nil, 'ret3' end
    env.shutdown = function(...) shutdowns = shutdowns + 1; return select('#', ...), ... end
    local original_update = env.update
    local installer = setfenv(assert(loadfile(source .. '/addon.lua')), env)()
    installer(function() if setup.api_error then error('no api', 0) end return world.api end, G, L, R, M, C, S, B,
        Text, {en = ENGLISH, bundled = setup.bundled or {}}, BUILD)
    return {env = env, world = world, lines = lines, updates = updates, original_update = original_update,
            state = env.BetterLobbyManagement, shutdowns = function() return shutdowns end}
end
local function logged(t, text)
    for _, line in ipairs(t.lines) do if line:find(text, 1, true) then return true end end
    return false
end
-- One frame: the mod's update, then the game's update of the escape menu's
-- tab (where the player menu's KICK fires).
local function frames(t, n)
    for _ = 1, n do
        t.world.sync()
        t.env.update(0.016)
        if t.world.menu_update then t.world.menu_update() end
    end
end
local function squad(world, peers)
    world.session = {world.local_peer}
    for _, peer in ipairs(peers) do world.session[#world.session + 1] = peer end
    world.host = world.local_peer
    world.sync()
end

-- Startup refusals: nothing hooked, the reason logged once.
for _, case in ipairs({{{world = function(w) w.game_sha = 'OTHER' end}, 'unsupported game.dll build'},
                       {{world = function(w) w.exe_sha = 'OTHER' end}, 'unsupported helldivers2.exe build'},
                       {{world = function(w) w.no_game = true end}, 'game modules unavailable'},
                       {{world = function(w) w.changed = Fake.GAME + G.CODE[2].rva end}, 'host-left check changed'},
                       {{api_error = true}, 'no api'}}) do
    local t = install(case[1])
    assert(t.env.update == t.original_update, 'update hooked on ' .. case[2])
    assert(t.state.status == 'unsupported: ' .. case[2], t.state.status)
    assert(#t.lines == 1 and t.lines[1]:find('Better Lobby Management v-test inactive: ' .. case[2], 1, true), t.lines[1])
end
-- Changed menu code or natives: the mod runs (Lobby Region), the menu stays off.
do
    for _, address in ipairs({Fake.GAME + M.CODE[3].rva, Fake.GAME + M.NATIVES.dialog_setup.rva}) do
        local t = install({world = function(w) w.changed = address end})
        assert(t.state.status == 'ready' and t.state.menu:find('^disabled: '), t.state.menu)
        assert(logged(t, 'menu disabled: '))
        squad(t.world, {TANGO})
        t.world.open_menu()
        frames(t, 3)
        assert(t.world.our_buttons() == '', 'no buttons without verified code')
    end
end
print('PASS: another game.dll or EXE, changed code, missing modules or PlayFab, and api failures leave the game '
    .. 'alone; changed menu code disables only the menu')

-- The idle gate: exact calls per frame, never a page check, no log lines. Every
-- frame includes the scanner's own check (a load64 and a load32) once it has
-- settled; its first write, in the first frame, is the only page check.
do
    local t = install({options = options_menu()})
    local world, state = t.world, t.state
    frames(t, 1)
    assert(state.options == 'registered' and state.menu == 'ready' and state.sos == 'ready', state.sos)
    assert(state.scanner.status == 'active' and world.get32(Fake.SCANNER_CONFIG + S.RECHARGE) == 5, state.scanner.status)
    local counts = budget.wrap(world.api)
    local lines, queries = #t.lines, world.api.queries
    local function idle(label, limits, n)
        for i = 1, n or 300 do budget.check(budget.frame(counts, t.env.update, 0.016), limits, label .. ' ' .. i) end
    end
    -- Alone, CANCEL SOS is the only action: the mode is looked at (2 loads
    -- since v1.1), the escape menu only in a mission, the SOS only while the
    -- menu is open.
    idle('alone on the ship', {load32 = 3, load64 = 3})
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    idle('no session', {load32 = 1, load64 = 2})
    world.put64(Fake.GAME + G.CONTEXT_PTR, Fake.CTX)
    budget.check(budget.frame(counts, t.env.update, 0.016), {load32 = 3, load64 = 4, read32 = 2}, 'new session')
    world.session, world.host = {TANGO, world.local_peer}, TANGO
    world.sync()
    idle('client of another host', {load32 = 4, load64 = 2})
    squad(world, {TANGO})
    budget.check(budget.frame(counts, t.env.update, 0.016), {load32 = 6, load64 = 4, read64 = 1},
        'first hosting frame: the menu system confirmed once')
    idle('hosting a squad, menu closed', {load32 = 6, load64 = 4})
    squad(world, {})
    world.mode = G.MODE_MISSION
    world.sync()
    world.sos_beacon()
    idle('alone in a mission, SOS on, menu closed', {load32 = 3, load64 = 5})
    world.sos.active, world.sos.enabled = 0, 0
    world.sync()
    world.open_menu()
    t.env.update(0.016) -- the new screen and the SOS object, each confirmed once
    idle('alone in a mission, escape menu open, no SOS', {load32 = 3, load64 = 6, load8 = 1})
    world.close_menu()
    assert(#t.lines == lines, 'idle updates log nothing')
    assert(world.api.queries == queries, 'no page checks while idle')
end
print('PASS: idle frames cost 3 loads with no session, 6 alone on the ship, 6 as a client, 10 hosting a squad with the '
    .. 'menu closed and 8 alone in a mission (10 with the menu open; 2 of them the scanner\'s); no page checks')

-- The escape menu while hosting a squad on the ship.
do
    local t = install({options = options_menu()})
    local world, state = t.world, t.state
    squad(world, {TANGO, CHARLIE})
    frames(t, 1)
    world.open_menu()
    frames(t, 1)
    assert(world.our_buttons() == 'disband=DISBAND SQUAD promote=PROMOTE TANGO', world.our_buttons())
    -- Opening Charlie's player menu makes Charlie the successor, and it stays after the popup closes.
    world.open_popup(2, CHARLIE)
    frames(t, 1)
    world.open_popup(2, nil)
    frames(t, 2)
    assert(world.our_buttons() == 'disband=DISBAND SQUAD promote=PROMOTE CHARLIE', world.our_buttons())
    -- The menu open with nothing to do: direct loads only, no native calls.
    local counts = budget.wrap(world.api)
    local calls = #world.calls
    local f
    for _ = 1, 60 do f = budget.frame(counts, t.env.update, 0.016) end
    assert(#world.calls == calls and (f.writable_data or 0) == 0 and (f.read32 or 0) == 0, budget.describe(f))
    budget.check(f, {load8 = 10, load32 = 29, load64 = 6}, 'hosting a squad, menu open, nothing to do')
    -- Promote Charlie: focus, select, confirm (hold) in the game's dialog.
    world.focus(4 + 3)
    frames(t, 1)
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'PROMOTE CHARLIE')
    assert(world.texts[world.dialog + M.DIALOG_BODY]:find('^Charlie hosts from their own ship'))
    assert(not world.texts[world.dialog + M.DIALOG_BODY]:find('Picked automatically', 1, true), 'picked, not automatic')
    assert(#world.texts[world.dialog + M.DIALOG_BODY] <= 120, 'short enough for the dialog box')
    world.select(); frames(t, 1)
    world.answer(true); frames(t, 1)
    assert(world.count('game_popup_kick') == 1 and world.last('game_popup_kick')[1] == Fake.key(CHARLIE),
        'the chosen player, through their player menu KICK')
    assert(world.count('kick_peer') == 0, 'the mod calls no kick itself')
    assert(state.lobby == 'promote: Charlie returns to their ship', state.lobby)
    world.game_rebuild() -- the game rebuilds the list after a removal
    frames(t, 3)
    assert(world.our_buttons() == '', 'no buttons while an action runs')
    t.env.BetterLobbyManagement.cancel()
end
-- Disband from the dialog kicks everyone, one per frame.
do
    local t = install({})
    local world, state = t.world, t.state
    squad(world, {TANGO, CHARLIE})
    world.open_menu()
    frames(t, 2)
    world.focus(4 + 2)
    frames(t, 1)
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'DISBAND SQUAD')
    world.select(); frames(t, 1)
    world.answer(false); frames(t, 1)
    assert(world.count('game_popup_kick') == 0, 'cancelled')
    world.hide_dialog(); frames(t, 1)
    world.select(); frames(t, 1)
    world.answer(true); frames(t, 10)
    assert(world.count('game_popup_kick') == 2 and #world.session == 1 and state.lobby == 'disbanded (2 players)',
        state.lobby)
    assert(logged(t, 'menu: disband confirmed') and logged(t, 'disband: kicked Tango'))
end
-- In a mission without an SOS nothing is offered: the game's own buttons stay as they are.
do
    local t = install({})
    local world = t.world
    squad(world, {TANGO})
    world.mode = G.MODE_MISSION
    world.sync()
    world.native_types = {0, 2, 3}
    frames(t, 1) -- the scanner's first write
    local queries = world.api.queries
    world.open_menu()
    frames(t, 2)
    assert(world.our_buttons() == '' and world.bytes[world.content + M.COUNT] == 3, world.our_buttons())
    assert(world.api.queries == queries, 'no page checks')
end
print('PASS: hosting a squad on the ship, the escape menu gets DISBAND SQUAD and PROMOTE (the player menu opened last '
    .. 'picks who); confirmed dialogs kick with the game\'s own kick; missions without an SOS get nothing')

-- CANCEL SOS, alone in a mission: after the game's two buttons; a confirm
-- stops the SOS with the game's own function, the lobby posts in the same
-- frame and the button goes again.
do
    local t = install({})
    local world = t.world
    world.mode = G.MODE_MISSION
    world.native_types = {2, 3}
    world.sync()
    frames(t, 1) -- the scanner's first write
    world.sos_beacon()
    world.open_menu()
    frames(t, 1)
    assert(world.our_buttons() == 'cancel_sos=CANCEL SOS', world.our_buttons())
    assert(world.bytes[world.content + M.COUNT] == 3 and world.bytes[world.content + M.TYPES] == 2
        and world.bytes[world.content + M.TYPES + 1] == 3, 'the game\'s own two buttons kept')
    local counts = budget.wrap(world.api)
    local calls, f = #world.calls, nil
    for _ = 1, 60 do f = budget.frame(counts, t.env.update, 0.016) end
    assert(#world.calls == calls and (f.writable_data or 0) == 0 and (f.read32 or 0) == 0, budget.describe(f))
    budget.check(f, {load8 = 10, load32 = 25, load64 = 9}, 'alone in a mission, SOS on, menu open, nothing to do')
    world.focus(4 + 2)
    frames(t, 1)
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == 'CANCEL SOS')
    assert(world.texts[world.dialog + M.DIALOG_BODY] == B.body(1, english), world.texts[world.dialog + M.DIALOG_BODY])
    world.select(); frames(t, 1)
    world.answer(true); frames(t, 1)
    assert(world.count('sos_deactivate') == 1 and world.key(B.KEY_SOS) == '0' and world.key(B.KEY_PRIVACY) == '1')
    assert(world.api.loadf(world.lobby + B.COUNTDOWN) == 0, 'the lobby posts in the game\'s update of this frame')
    assert(world.sos_uses() == 1, 'the SOS Beacon can be called in again')
    assert(logged(t, 'menu: cancel_sos confirmed')
        and logged(t, 'SOS cancelled: lobby SOS flag 1, privacy 0 -> SOS flag 0, privacy 1')
        and logged(t, 'SOS Beacon uses 0 -> 1'))
    frames(t, 1)
    assert(world.count('rebuild') == 1 and world.our_buttons() == '', 'the button goes: the game rebuilt its list')
    -- Kept off, the menu closed: the cancel's 6 loads a frame on top of the alone path.
    world.hide_dialog()
    world.close_menu()
    frames(t, 2)
    for _ = 1, 60 do f = budget.frame(counts, t.env.update, 0.016) end
    budget.check(f, {load8 = 1, load32 = 5, load64 = 8}, 'alone in a mission, SOS cancelled, menu closed')
    -- The host changes their mind: a new SOS Beacon lists the mission again,
    -- the mod lets it, and the escape menu offers CANCEL SOS again.
    world.sos_beacon()
    frames(t, 1)
    assert(world.sos_uses() == 0 and world.sos.active == 1 and world.key(B.KEY_SOS) == '1')
    assert(logged(t, '(a new SOS beacon was called in)'))
    world.open_menu()
    frames(t, 1)
    assert(world.our_buttons() == 'cancel_sos=CANCEL SOS' and world.count('sos_deactivate') == 1, world.our_buttons())
end
-- CANCEL SOS with a squad in a mission: after the game's three buttons; the
-- dialog follows the privacy setting; a player leaving re-arms the SOS in the
-- game's update and the mod turns it off in the next frame.
do
    local t = install({})
    local world = t.world
    squad(world, {TANGO, CHARLIE})
    world.mode = G.MODE_MISSION
    world.native_types = {0, 2, 3}
    world.sync()
    frames(t, 1)
    world.sos_beacon()
    world.open_menu()
    frames(t, 1)
    assert(world.our_buttons() == 'cancel_sos=CANCEL SOS' and world.bytes[world.content + M.COUNT] == 4,
        world.our_buttons())
    local counts = budget.wrap(world.api)
    local f
    for _ = 1, 60 do f = budget.frame(counts, t.env.update, 0.016) end
    -- The ship's 45 loads with a squad of three, + the SOS (2) and the privacy setting (2).
    budget.check(f, {load8 = 11, load32 = 30, load64 = 8}, 'hosting a squad in a mission, SOS on, menu open')
    world.privacy = 0
    frames(t, 1)
    world.focus(4 + 3)
    frames(t, 1)
    assert(world.texts[world.dialog + M.DIALOG_BODY] == B.body(0, english), world.texts[world.dialog + M.DIALOG_BODY])
    world.select(); frames(t, 1)
    world.answer(true); frames(t, 1)
    assert(world.count('sos_deactivate') == 1)
    world.lobby_update()
    assert(world.playfab[B.KEY_SOS] == '0' and world.playfab[B.KEY_PRIVACY] == '0', 'Public stays Public')
    world.player_leaves(CHARLIE) -- the game's re-arm
    frames(t, 1)
    assert(world.count('sos_deactivate') == 2 and world.key(B.KEY_SOS) == '0' and world.our_buttons() == '')
    assert(logged(t, 'SOS: the game listed it again (a player left or a new host); cancelled again'))
    t.env.shutdown()
    assert(t.lines[#t.lines]:find('SOS cancels 1, re-arms caught 1 (0 already posted)', 1, true), t.lines[#t.lines])
end
-- Changed SOS code: CANCEL SOS stays off; everything else runs.
do
    local t = install({world = function(w) w.changed = Fake.GAME + B.CODE[1].rva end})
    local world, state = t.world, t.state
    assert(state.status == 'ready' and state.menu == 'ready' and state.sos == 'unavailable: SOS activate changed',
        state.sos)
    assert(logged(t, 'CANCEL SOS unavailable: SOS activate changed'))
    world.mode = G.MODE_MISSION
    world.native_types = {2, 3}
    world.sync()
    frames(t, 1)
    world.sos_beacon()
    world.open_menu()
    frames(t, 2)
    assert(world.our_buttons() == '' and world.count('sos_deactivate') == 0)
    local ok, why = state.cancel_sos()
    assert(ok == false and why == 'unavailable: SOS activate changed', why)
end
print('PASS: CANCEL SOS shows in a mission with an SOS on (alone or with a squad), its dialog names the privacy the '
    .. 'lobby returns to, a confirm stops the SOS and posts the lobby at once, the button goes, and a re-arm after a '
    .. 'player leaves is turned off in the next frame; changed SOS code disables only CANCEL SOS')

-- Lua entry points.
do
    local t = install({})
    local world, state = t.world, t.state
    squad(world, {TANGO})
    world.open_menu()
    assert(state.disband())
    frames(t, 3)
    assert(world.last('game_popup_kick')[1] == Fake.key(TANGO) and #world.session == 1)
    squad(world, {TANGO})
    assert(state.promote({lo = TANGO.lo, hi = TANGO.hi}))
    assert(state.lobby == 'promote: Tango returns to their ship', state.lobby)
    assert(state.hand_over_and_leave == nil, 'HAND OVER is gone')
    assert(state.cancel())
    squad(world, {})
    local ok, why = state.promote()
    assert(ok == false and why == 'no other players' and logged(t, 'promote refused: no other players'))
    ok, why = state.cancel_sos()
    assert(ok == false and why == 'not in a mission' and logged(t, 'cancel SOS refused: not in a mission'), why)
    world.mode = G.MODE_MISSION
    world.sync()
    ok, why = state.cancel_sos()
    assert(ok == false and why == 'no SOS is on', why)
    world.sos_beacon()
    assert(state.cancel_sos() and world.count('sos_deactivate') == 1 and world.key(B.KEY_SOS) == '0')
end
print('PASS: Lua entry points (disband, promote, cancel, cancel_sos) work and refuse cleanly')

-- Squad messages: on by default, a chat line before the kick; the option switches it off.
do
    local mom = options_menu()
    local t = install({chat = true, options = mom})
    local world, state = t.world, t.state
    frames(t, 1)
    assert(state.chat == 'ready' and logged(t, 'squad messages ready'), state.chat)
    squad(world, {TANGO})
    world.open_menu()
    assert(state.disband())
    local sent = world.last('chat_send')
    assert(sent and sent[3] == 'The host disbanded the squad.' and world.count('chat_rpc') == 1, 'the chat line')
    frames(t, 3)
    assert(world.count('game_popup_kick') == 0, 'the kick waits for the message')
    frames(t, 70)
    assert(world.count('game_popup_kick') == 1 and #world.session == 1)
    mom.callbacks['better_lobby_management.messages'](2)
    squad(world, {TANGO})
    world.open_menu()
    frames(t, 1)
    assert(state.disband())
    frames(t, 3)
    assert(world.count('chat_send') == 1 and world.count('game_popup_kick') == 2, 'off: no line, no wait')
    -- Unavailable (the chat send changed): the actions still run, and the log says why once.
    local u = install({})
    assert(u.state.chat == 'unavailable: chat send changed', u.state.chat)
end
print('PASS: squad messages go out before the kick by default, the option turns them off, and without the chat the '
    .. 'actions run silently')

-- Promote (release build): the game's new squad leader notice, the game's
-- kick 0.5 s later, then the escape menu closed as Esc does.
do
    local t = install({chat = true})
    local world, state = t.world, t.state
    frames(t, 1)
    squad(world, {TANGO})
    world.successor = TANGO
    world.open_menu()
    frames(t, 1)
    assert(state.promote())
    local sent = world.last('rpc_send')
    assert(sent and sent[1] == C.NEW_HOST and sent[6] == Fake.key(TANGO), 'the notice names Tango')
    assert(world.count('chat_send') == 0 and logged(t, 'squad leader notice sent to 1 player(s): Tango'))
    frames(t, 3)
    assert(world.count('game_popup_kick') == 0, 'the kick waits for the notice')
    frames(t, 60)
    assert(world.count('game_popup_kick') == 1 and world.count('escape_closed') == 1, 'menu closed after the kick')
    assert(logged(t, 'promote: escape menu closed'))
    -- The update hook runs the arrival check 15 s after the move (world.tick advances the search and join).
    world.arrivals = {TANGO, world.local_peer}
    for _ = 1, math.ceil((L.FIRST_SEARCH + 2 + L.ARRIVAL_CHECK) / 0.016) do world.tick(); frames(t, 1) end
    assert(logged(t, "promote: 2 of 2 players in Tango's session 15 s after the move"), table.concat(t.lines))
end
print('PASS: promote sends the game\'s new squad leader notice, kicks with the game\'s KICK and then closes the '
    .. 'escape menu as Esc does')

-- Lobby Region: on and off from Mod Options Menu, restored at shutdown.
do
    local mom = options_menu()
    local t = install({options = mom})
    local world = t.world
    frames(t, 1)
    assert(#mom.registered == 3 and mom.registered[1].id == 'better_lobby_management.region'
        and mom.registered[2].id == 'better_lobby_management.messages'
        and mom.registered[3].id == 'better_lobby_management.scanner_seconds')
    local spec = mom.registered[1].spec
    assert(spec.type == 'choice' and #spec.choices == 2 and spec.default == 1 and #spec.description <= 400)
    local all = 'AF AN AS EU OC SA'
    mom.callbacks['better_lobby_management.region'](2)
    assert(world.excluded('NA') == all and t.state.region == 'my continent only (NA)')
    mom.callbacks['better_lobby_management.region'](1)
    assert(world.excluded('NA') == 'AF AS OC')
    mom.callbacks['better_lobby_management.region'](2)
    local n, x, y = t.env.shutdown('p', 'q')
    assert(n == 2 and x == 'p' and y == 'q' and t.shutdowns() == 1, 'shutdown chain')
    assert(world.excluded('NA') == 'AF AS OC', 'shutdown restores the table')
    assert(t.lines[#t.lines]:find('region flags restored 3', 1, true), t.lines[#t.lines])
    local saved = install({options = options_menu({['better_lobby_management.region'] = 2})})
    saved.env.update(0.016)
    assert(saved.world.excluded('NA') == all)
    for _, behaviour in ipairs({'refuse', 'error'}) do
        local other = install({options = options_menu(nil, behaviour)})
        other.env.update(0.016)
        assert(other.state.options == (behaviour == 'refuse' and 'not registered: too many mods' or 'failed: menu broke'))
    end
    local none = install({})
    none.env.update(0.016)
    assert(none.state.options == 'not installed (defaults in use)')
end
print('PASS: Lobby Region follows Mod Options Menu (saved or changed) and is restored at shutdown')

-- The Galactic Map scanner: 5 s by default, the slider, the game's rewrites re-applied, a saved setting;
-- changed scanner code disables only the scanner.
do
    local mom = options_menu()
    local t = install({options = mom})
    local world, state = t.world, t.state
    frames(t, 1)
    local option = mom.registered[3]
    assert(option.id == 'better_lobby_management.scanner_seconds' and option.spec.type == 'slider'
        and option.spec.min == 5 and option.spec.max == 20 and option.spec.default == 5
        and option.spec.step == 1 and #option.spec.description <= 400)
    local field = Fake.SCANNER_CONFIG + S.RECHARGE
    assert(world.get32(field) == 5 and state.scanner.status == 'active', state.scanner.status)
    assert(logged(t, 'scanner active: setting 5 s, game 20 s, field 5 s'), table.concat(t.lines))
    mom.callbacks['better_lobby_management.scanner_seconds'](12)
    frames(t, 1)
    assert(world.get32(field) == 12)
    world.put32(field, 20) -- the game's configuration download
    frames(t, 1)
    assert(world.get32(field) == 12 and state.scanner.refreshes == 1)
    t.env.shutdown()
    assert(t.lines[#t.lines]:find('scanner active: setting 12 s, game 20 s, field 12 s', 1, true), t.lines[#t.lines])
    local saved = install({options = options_menu({['better_lobby_management.scanner_seconds'] = 8})})
    frames(saved, 1)
    assert(saved.world.get32(field) == 8)
    local changed = install({world = function(w) w.changed = Fake.GAME + S.CODE[1].rva end})
    frames(changed, 1)
    assert(changed.state.status == 'ready' and changed.world.get32(field) == 20, 'only the scanner is off')
    assert(logged(changed, 'scanner disabled: recharge reader changed'), table.concat(changed.lines))
end
print('PASS: the scanner recharges in 5 s by default, follows the slider (saved or changed), re-applies after the '
    .. 'game\'s rewrite and logs its counts at shutdown; changed scanner code disables only the scanner')

-- A second copy does nothing; an error stops the mod and cleans up.
do
    local t = install({})
    local update = t.env.update
    setfenv(assert(loadfile(source .. '/addon.lua')), t.env)()(function() error('second copy built an api') end,
        G, L, R, M, C, S, B, Text, {en = ENGLISH, bundled = {}}, BUILD)
    assert(t.env.update == update)
    local e = install({options = options_menu()})
    e.env.update(0.016)
    e.env.ModOptionsMenu.callbacks['better_lobby_management.region'](2)
    squad(e.world, {TANGO})
    assert(e.state.promote())
    local load32 = e.world.api.load32
    local calls = 0
    e.world.api.load32 = function(address)
        if address == Fake.CTX + G.PEER_COUNT then calls = calls + 1; error('exploded', 0) end
        return load32(address)
    end
    for _ = 1, 10 do assert(e.env.update(0.016) == 'ret1') end
    assert(e.state.errors == 1 and e.state.status == 'stopped after error' and calls == 1)
    assert(e.state.lobby == 'promote failed: cancelled: error', e.state.lobby)
    assert(e.world.excluded('NA') == 'AF AS OC', 'region restored')
    assert(e.world.get32(Fake.SCANNER_CONFIG + S.RECHARGE) == 20, 'the scanner\'s field restored')
    assert(#e.updates == 11 and logged(e, 'Better Lobby Management stopped for this session; region flags restored'))
end
print('PASS: a second copy does nothing; an error stops the mod for the session, cancels the action, restores the '
    .. 'region flags and the scanner\'s field and keeps the game update running')

-- Translations: a Chinese pack is installed and the game's Text Language is
-- Chinese (read from game memory; Steam still says English). Buttons, dialogs,
-- the chat line and the Mod Options Menu texts follow; player names are
-- upper-cased beyond a-z; Mod Options Menu v1.0 gets byte-capped strings,
-- later versions get functions.
do
    local n = 0
    local function cjk(count)
        local parts = {}
        for k = 1, count do n = n + 1; parts[k] = Text.encode(0x4E00 + (n * 37) % 20000) end
        return table.concat(parts)
    end
    local zh = {}
    for key, value in pairs(ENGLISH.strings) do
        local names = {}
        for name in value:gmatch('{[%a_]+}') do names[#names + 1] = name end
        zh[key] = cjk(4) .. table.concat(names, cjk(1))
    end
    zh['option.scanner.description'] = cjk(150) -- 450 bytes: too long for v1.0's 400-byte cap
    local pack = {language = 'zh-Hans', name = 'test pack', mods = {better_lobby_management = zh}}
    local function chinese_game(world)
        local settings = world.get64(Fake.GAME + G.GAME_STATE_PTR)
        world.put32(settings + Text.GAME.index, 11)
        world.put64(Fake.GAME + Text.GAME.table + 8 * 11, 0x2f000000000)
        world.put64(0x2f000000000 + 8, 0x2f000000100)
        world.put_string(0x2f000000100, 'zh-CN')
    end
    local mom = options_menu(nil, nil, 2)
    local t = install({chat = true, options = mom, packs = {pack}, world = chinese_game})
    local world, state = t.world, t.state
    frames(t, 1)
    assert(logged(t, 'text language: zh-Hans (game setting zh-CN)'), table.concat(t.lines))
    local total = 0
    for _ in pairs(ENGLISH.strings) do total = total + 1 end
    -- Mod Options Menu v1.1+: functions, read when the menu builds its page
    -- (nothing is resolved before that).
    local spec = mom.registered[1].spec
    assert(type(spec.label) == 'function' and spec.label() == zh['option.region.label'])
    assert(logged(t, 'language zh-Hans: ' .. total .. ' of ' .. total .. ' texts translated'), table.concat(t.lines))
    assert(spec.mod() == zh['option.mod'] and spec.choices[2]() == zh['option.region.continent'])
    assert(mom.registered[2].spec.choices[1] == 'On', 'ON and OFF stay the game\'s own words')
    assert(mom.registered[3].spec.description() == zh['option.scanner.description'])
    -- Buttons and dialogs; a Cyrillic name upper-cased.
    world.names[Fake.key(TANGO)] = '\208\154\208\176\209\130\209\143' -- Katya
    squad(world, {TANGO})
    world.open_menu()
    frames(t, 1)
    local promote = Text.format(zh['button.promote'], {name = '\208\154\208\144\208\162\208\175'})
    assert(world.our_buttons() == 'disband=' .. zh['button.disband'] .. ' promote=' .. promote, world.our_buttons())
    world.focus(4 + 2)
    frames(t, 1)
    assert(world.texts[world.dialog + M.DIALOG_TITLE] == zh['dialog.disband.title'])
    assert(world.texts[world.dialog + M.DIALOG_BODY] == zh['dialog.disband.body'])
    -- The chat line goes out in the host's language.
    assert(state.disband())
    assert(world.last('chat_send')[3] == zh['chat.disband'], 'the translated chat line')
    frames(t, 80)
    -- Mod Options Menu v1.0: strings, and a translation over its byte cap stays English.
    local old = options_menu()
    local u = install({options = old, packs = {pack}, world = chinese_game})
    frames(u, 1)
    local v1 = old.registered[1].spec
    assert(v1.label == zh['option.region.label'] and v1.choices[2] == zh['option.region.continent'])
    assert(old.registered[3].spec.description == ENGLISH.strings['option.scanner.description'], 'over 400 bytes')
    -- A bad translation entry is refused alone, logged, and English shows.
    local broken = {language = 'zh-Hans', name = 'broken', mods = {better_lobby_management = {
        ['button.promote'] = 'no placeholder'}}}
    local b = install({packs = {pack, broken}, world = chinese_game})
    squad(b.world, {TANGO})
    b.world.open_menu()
    frames(b, 2)
    assert(logged(b, 'button.promote: placeholders differ from English'), table.concat(b.lines))
    assert(b.world.our_buttons():find('promote=' .. Text.format(zh['button.promote'], {name = 'TANGO'}), 1, true),
        b.world.our_buttons())
    -- The player switches the game to Chinese between two openings of the
    -- escape menu: the next opening reads the setting and rebuilds the buttons.
    local s = install({packs = {pack}})
    squad(s.world, {TANGO})
    s.world.open_menu()
    frames(s, 2)
    assert(s.world.our_buttons() == 'disband=DISBAND SQUAD promote=PROMOTE TANGO', s.world.our_buttons())
    s.world.close_menu()
    frames(s, 1)
    chinese_game(s.world)
    s.world.open_menu()
    frames(s, 2)
    assert(s.world.our_buttons():find('disband=' .. zh['button.disband'], 1, true), s.world.our_buttons())
    assert(logged(s, 'text language: zh-Hans (game setting zh-CN)'), table.concat(s.lines))
    -- No pack and a Chinese game: English, and the log says nothing is translated.
    local e = install({world = chinese_game})
    squad(e.world, {TANGO})
    e.world.open_menu()
    frames(e, 2)
    assert(e.world.our_buttons() == 'disband=DISBAND SQUAD promote=PROMOTE TANGO', e.world.our_buttons())
    assert(logged(e, 'language zh-Hans: 0 of'), table.concat(e.lines))
end
rawset(_G, 'BingusTranslations', nil)
print('PASS: translations: the game\'s Text Language picks the pack\'s texts for buttons, dialogs, the chat line and '
    .. 'Mod Options Menu (functions for v1.1+, byte-capped strings for v1.0); names upper-cased beyond a-z; bad '
    .. 'entries and missing packs fall back to English')
