-- The addon wiring (src/addon.lua) with the real modules and the fake game:
-- startup refusals, the escape-menu buttons (the successor from the player
-- menu the host opened), the idle gate's exact calls (no page checks while
-- idle), actions confirmed in the dialog, the Lobby Region option, the Mod
-- Options Menu registration (loader v19's after_startup event and loader v18's
-- first update), error containment through the shared runtime's guard and
-- the shutdown hook.
-- Usage: test_addon.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local H = dofile(tests .. 'hostile_vm.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local Runtime = dofile(source .. '/bingus_runtime.lua')
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
local BUILD = {version = 'v-test', game_sha256 = 'GAME', exe_sha256 = 'EXE', runtime = Runtime}
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
-- setup.update: the game's update below the mod (default: records dt, returns three values; false: none).
-- setup.loader(loader): adds to the loader table (default: loader v18's fields only).
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
    if setup.loader then setup.loader(env.CowboyBingusModLoader) end
    env.ModOptionsMenu = setup.options
    env.update = setup.update or function(dt) updates[#updates + 1] = dt; return 'ret1', nil, 'ret3' end
    if setup.update == false then env.update = nil end
    env.shutdown = function(...) shutdowns = shutdowns + 1; return select('#', ...), ... end
    if setup.below then setup.below(env) end -- a neighbour below the mod (tests/hostile_vm.lua)
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
local function count_logged(t, text)
    local n = 0
    for _, line in ipairs(t.lines) do if line:find(text, 1, true) then n = n + 1 end end
    return n
end
local ALL_BUT_NA = 'AF AN AS EU OC SA' -- the region table with My Continent Only, for NA
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
                       {{api_error = true}, 'no api'}, {{update = false}, 'game update unavailable'}}) do
    local t = install(case[1])
    assert(t.env.update == t.original_update, 'update hooked on ' .. case[2])
    assert(t.state.status == 'unsupported: ' .. case[2], t.state.status)
    assert(#t.lines == 1 and t.lines[1]:find('Better Lobby Management v-test inactive: ' .. case[2], 1, true), t.lines[1])
    assert(t.state.disband == nil and t.state.guard == nil, 'no entry points and no guard when inactive')
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
print('PASS: another game.dll or EXE, changed code, missing modules or PlayFab, api failures and no game update leave '
    .. 'the game alone; changed menu code disables only the menu')

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

-- Mod Options Menu registration retries, bounded: a menu installed after the
-- first update, a refusal, an error and a replaced menu table are handled at
-- the next check (1, 3, 7 ... 255 s after the first update), each option
-- registered and given its callback once per menu table; a menu that always
-- refuses gets 8 retries and one last log line; registered, or out of checks,
-- nothing is looked at any more.
local function scripted_menu(answers, saved)
    local menu = options_menu(saved)
    local register, on_change = menu.register_option, menu.on_change
    menu.calls, menu.changes = {}, 0
    function menu.register_option(id, spec)
        menu.calls[#menu.calls + 1] = id
        local answer = answers[#menu.calls]
        if answer == 'refuse' then return false, 'busy' end
        if answer == 'error' then error('menu broke', 0) end
        return register(id, spec)
    end
    function menu.on_change(id, fn) menu.changes = menu.changes + 1; return on_change(id, fn) end
    return menu
end
local function seconds(t, s) frames(t, math.floor(s / 0.016 + 0.5)) end
local REGION_ID = 'better_lobby_management.region'
do
    -- No menu at the first update: the menu installs its table while the addons load, so
    -- none is coming; nothing is retried, and a table that appears later is not looked at.
    local late = scripted_menu({}, {[REGION_ID] = 2})
    local t = install({})
    frames(t, 1)
    assert(t.state.options == 'not installed (defaults in use)', t.state.options)
    t.env.ModOptionsMenu = late
    seconds(t, 300)
    assert(#late.calls == 0 and t.state.options == 'not installed (defaults in use)', 'nothing retried without a menu')
    -- Registered on the first update, the saved setting applied: nothing is looked at any more.
    local first = scripted_menu({}, {[REGION_ID] = 2})
    local r = install({options = first})
    frames(r, 1)
    assert(r.state.options == 'registered' and #first.registered == 3 and first.changes == 3, r.state.options)
    assert(r.world.excluded('NA') == ALL_BUT_NA and logged(r, 'Mod Options Menu: registered'))
    r.env.ModOptionsMenu = scripted_menu({})
    seconds(r, 300)
    assert(#r.env.ModOptionsMenu.calls == 0, 'registered: nothing is looked at any more')
    -- The second option refused once: the first is not registered again, the rest follow at the check.
    local menu = scripted_menu({true, 'refuse'})
    local u = install({options = menu})
    frames(u, 1)
    assert(u.state.options == 'not registered: busy' and #menu.registered == 1, u.state.options)
    seconds(u, 1.1)
    assert(u.state.options == 'registered' and table.concat(menu.calls, ' ') == REGION_ID .. ' '
        .. 'better_lobby_management.messages better_lobby_management.messages better_lobby_management.scanner_seconds',
        table.concat(menu.calls, ' '))
    assert(#menu.registered == 3 and menu.changes == 3, 'each option and callback once')
    -- An error, then registered.
    menu = scripted_menu({'error'})
    local v = install({options = menu})
    frames(v, 1)
    assert(v.state.options == 'failed: menu broke', v.state.options)
    seconds(v, 1.1)
    assert(v.state.options == 'registered' and #menu.registered == 3)
    -- The menu accepted an option but raised when its value was read: that option is
    -- registered again, read and given its callback at the check.
    menu = scripted_menu({})
    local get, raised = menu.get, false
    function menu.get(id)
        if not raised and id == REGION_ID then raised = true; error('get broke', 0) end
        return get(id)
    end
    local x = install({options = menu})
    frames(x, 1)
    assert(x.state.options == 'failed: get broke' and menu.changes == 0, x.state.options)
    seconds(x, 1.1)
    assert(x.state.options == 'registered' and menu.changes == 3 and menu.calls[1] == REGION_ID
        and menu.calls[2] == REGION_ID and #menu.calls == 4, table.concat(menu.calls, ' '))
    -- A refusing menu replaced by another one: everything registers with the new table.
    local refusing, replacement = scripted_menu({'refuse', 'refuse'}), scripted_menu({})
    local w = install({options = refusing})
    frames(w, 1)
    w.env.ModOptionsMenu = replacement
    seconds(w, 1.1)
    assert(w.state.options == 'registered' and #replacement.registered == 3 and replacement.changes == 3)
    assert(#refusing.registered == 0 and refusing.changes == 0)
end
do
    -- Always refused: the first attempt and 8 retries at 1, 3, 7 ... 255 s, then nothing more.
    local refuse = {}
    for i = 1, 20 do refuse[i] = 'refuse' end
    local menu = scripted_menu(refuse)
    local t = install({options = menu})
    frames(t, 1)
    local attempts = {}
    for _, at in ipairs({0.9, 1.1, 2.9, 3.1, 6.9, 7.1, 254.9, 255.1, 600}) do
        seconds(t, at - (t.seconds or 0.016))
        t.seconds = at
        attempts[#attempts + 1] = #menu.calls
    end
    assert(table.concat(attempts, ' ') == '1 2 2 3 3 4 8 9 9', table.concat(attempts, ' '))
    assert(t.state.options == 'not registered: busy' and #menu.registered == 0)
    assert(count_logged(t, 'Mod Options Menu: not registered: busy') == 2, 'the outcome once, then the last line')
    assert(logged(t, 'Mod Options Menu: not registered: busy; no more retries this session'))
    t.env.ModOptionsMenu = scripted_menu({})
    seconds(t, 300)
    assert(#t.env.ModOptionsMenu.calls == 0, 'out of checks: nothing is looked at any more')
    -- No menu at all: checks find nothing to do, and nothing is logged after the first update.
    local none = install({})
    frames(none, 1)
    local lines = #none.lines
    seconds(none, 300)
    assert(none.state.options == 'not installed (defaults in use)' and #none.lines == lines)
end
print('PASS: loader v18 (no after_startup): Mod Options Menu registration is retried 1, 3, 7 ... 255 s after the first '
    .. 'update while the installed menu leaves anything unregistered (a refusal, an error, a replaced table), each '
    .. 'option once per table; 8 retries at most; with no menu at the first update, once registered or out of checks '
    .. 'nothing is looked at')

-- Loader v19's after_startup event: the options are registered once in it,
-- after every mod of this startup has started and before the first update,
-- whatever the order the mods load in; nothing is retried and nothing runs per
-- frame for them. The loader's capability is tested, never its version.
-- Without the event, when the loader refuses the callback, or when it never
-- runs it, the first update registers as on loader v18.
local function v19_loader(queue, finished)
    return function(loader)
        loader.capabilities = setmetatable({}, {__index = {api = 1, logs = true, after_startup = true},
            __newindex = function() error('read-only', 2) end})
        function loader.after_startup(fn)
            if type(fn) ~= 'function' then return false, 'after_startup needs a function' end
            if finished then fn() else queue[#queue + 1] = fn end
            return true
        end
    end
end
local function startup_finishes(queue)
    for _, fn in ipairs(queue) do fn() end
end
local function line_index(t, text)
    for i, line in ipairs(t.lines) do if line:find(text, 1, true) then return i end end
end
do
    -- Registered in the event, before the first update: the menu's saved setting applies then.
    local queue, menu = {}, scripted_menu({}, {[REGION_ID] = 2})
    local t = install({options = menu, loader = v19_loader(queue)})
    assert(#queue == 1 and #menu.calls == 0 and t.state.options == 'pending', 'queued until startup finishes')
    startup_finishes(queue)
    assert(t.state.options == 'registered' and #menu.registered == 3 and menu.changes == 3, t.state.options)
    assert(t.world.excluded('NA') == ALL_BUT_NA and #t.updates == 0, 'the saved setting applied before any update')
    assert(logged(t, 'text language: en (Steam)') and line_index(t, 'ready: ') < line_index(t, 'Mod Options Menu: '))
    frames(t, 1)
    assert(#menu.calls == 3 and #menu.registered == 3, 'the first update registers nothing again')
    t.env.ModOptionsMenu = scripted_menu({})
    seconds(t, 300)
    assert(#t.env.ModOptionsMenu.calls == 0, 'nothing is looked at afterwards')
    -- Refused in the event: that one attempt, never retried, logged once.
    local refuse = {}
    for i = 1, 20 do refuse[i] = 'refuse' end
    local refusing, later = scripted_menu(refuse), {}
    local u = install({options = refusing, loader = v19_loader(later)})
    startup_finishes(later)
    frames(u, 1)
    seconds(u, 300)
    assert(u.state.options == 'not registered: busy' and #refusing.calls == 1, table.concat(refusing.calls, ' '))
    assert(count_logged(u, 'Mod Options Menu: ') == 1, 'one line, no retries')
    -- An error in the event: also once.
    local broken, queued = scripted_menu({'error'}), {}
    local v = install({options = broken, loader = v19_loader(queued)})
    startup_finishes(queued)
    seconds(v, 300)
    assert(v.state.options == 'failed: menu broke' and #broken.calls == 1, v.state.options)
    -- Startup already finished (a mod started late): the callback runs at once, during the install.
    local late = scripted_menu({})
    local w = install({options = late, loader = v19_loader({}, true)})
    assert(w.state.options == 'registered' and #late.registered == 3 and #w.updates == 0, w.state.options)
end
do
    -- The capability decides, never the version: version 19 without it registers on the first update,
    -- version 17 with it registers in the event.
    local menu = scripted_menu({})
    local t = install({options = menu, loader = function(loader) loader.version = 19 end})
    assert(#menu.calls == 0)
    frames(t, 1)
    assert(t.state.options == 'registered' and #menu.calls == 3, t.state.options)
    local queue, flagged = {}, scripted_menu({})
    install({options = flagged, loader = function(loader)
        v19_loader(queue)(loader)
        loader.version = 17
    end})
    startup_finishes(queue)
    assert(#flagged.registered == 3, 'registered in the event')
    -- capabilities.after_startup false, or no after_startup function: the first update.
    for _, broken in ipairs({function(loader) v19_loader({})(loader); loader.capabilities = {after_startup = false} end,
                             function(loader) v19_loader({})(loader); loader.after_startup = nil end}) do
        local other = scripted_menu({})
        local u = install({options = other, loader = broken})
        frames(u, 1)
        assert(u.state.options == 'registered' and #other.calls == 3, u.state.options)
    end
    -- The loader refuses the callback (its limit): logged, then the first update registers and a
    -- refusal is retried as on loader v18.
    local refusing = scripted_menu({'refuse'})
    local v = install({options = refusing, loader = function(loader)
        v19_loader({})(loader)
        function loader.after_startup() return false, 'after_startup: 256 callbacks already registered' end
    end})
    assert(logged(v, 'Mod Options Menu: after_startup refused (after_startup: 256 callbacks already registered); '
        .. 'registering on the first update'))
    frames(v, 1)
    assert(v.state.options == 'not registered: busy', v.state.options)
    seconds(v, 1.1)
    assert(v.state.options == 'registered' and #refusing.registered == 3, 'retried at the first check')
    -- Accepted but never run before the first update: the first update registers.
    local waiting = scripted_menu({})
    local w = install({options = waiting, loader = v19_loader({})})
    frames(w, 1)
    assert(w.state.options == 'registered' and #waiting.registered == 3, w.state.options)
end
print('PASS: loader v19 (after_startup): Mod Options Menu options registered once in the event, before the first '
    .. 'update (or at once after startup), a refusal or an error never retried and nothing looked at per frame; the '
    .. 'capability is tested, not the version; a refused or unrun callback falls back to the first update')

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

-- A second copy does nothing. The mod's own errors go to the shared runtime's
-- guard, which counts them and logs the first of a burst; the next frame first
-- cancels the running action and counts the error in
-- BetterLobbyManagement.errors (the session's count); the 8th in a burst stops
-- the mod, which puts the region flags and the scanner's field back, while the
-- game's update keeps running; the guard's status keeps the stop through
-- shutdown.
local function failing_load(t, address)
    local load32, calls = t.world.api.load32, {n = 0, on = true}
    t.world.api.load32 = function(at)
        if calls.on and at == address then calls.n = calls.n + 1; error('exploded', 0) end
        return load32(at)
    end
    return calls
end
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
    local calls = failing_load(e, Fake.CTX + G.PEER_COUNT)
    local running = e.state.lobby
    assert(e.env.update(0.016) == 'ret1')
    assert(e.state.guard.errors == 1 and e.state.errors == 0 and e.state.lobby == running,
        'the failed frame: counted by the guard, the action cancelled on the next frame')
    for _ = 2, 7 do assert(e.env.update(0.016) == 'ret1') end
    assert(e.state.guard.errors == 7 and e.state.errors == 6 and e.state.status == 'ready' and calls.n == 7,
        e.state.status)
    assert(e.state.lobby == 'promote failed: cancelled: error', e.state.lobby)
    assert(e.world.excluded('NA') == ALL_BUT_NA, 'the region flags stay until a stop')
    assert(count_logged(e, 'BetterLobbyManagement error: exploded') == 1, 'one log line for the burst')
    for _ = 1, 3 do assert(e.env.update(0.016) == 'ret1') end
    assert(e.state.errors == 8 and calls.n == 8 and e.state.status == 'stopped: stopped after 8 errors: exploded',
        e.state.status)
    assert(e.world.excluded('NA') == 'AF AS OC', 'region restored')
    assert(e.world.get32(Fake.SCANNER_CONFIG + S.RECHARGE) == 20, 'the scanner\'s field restored')
    assert(#e.updates == 11 and logged(e, 'BetterLobbyManagement stopped: stopped after 8 errors: exploded')
        and logged(e, 'Better Lobby Management stopped for this session; region flags restored'))
    e.env.shutdown()
    assert(e.state.status == 'stopped: stopped after 8 errors: exploded'
        and e.state.guard.state == 'stopped after: stopped after 8 errors: exploded', e.state.guard.state)
end
-- Errors apart: each count starts again after 3600 frames without one, so rare
-- errors never stop the mod (one log line each); 8 within a burst do, even
-- with clean frames between them.
do
    local t = install({})
    local calls = failing_load(t, Fake.CTX + G.PEER_COUNT)
    for _ = 1, 9 do
        calls.on = true
        t.env.update(0.016)
        calls.on = false
        for _ = 1, 3600 do t.env.update(0.016) end
    end
    assert(t.state.status == 'ready' and t.state.errors == 9
        and count_logged(t, 'BetterLobbyManagement error: exploded') == 9, t.state.status)
    local u = install({})
    calls = failing_load(u, Fake.CTX + G.PEER_COUNT)
    for i = 1, 800 do
        calls.on = i % 100 == 0
        u.env.update(0.016)
    end
    assert(u.state.status == 'stopped: stopped after 8 errors: exploded' and u.state.errors == 8, u.state.status)
    assert(count_logged(u, 'BetterLobbyManagement error: exploded') == 1)
end
print('PASS: a second copy does nothing; the mod\'s own errors go to the guard (one log line per burst), the next '
    .. 'frame cancels the running action and counts them; 8 in a burst stop it (region flags and the scanner\'s '
    .. 'field restored), rare ones never add up')

-- An error below this mod reaches the game unchanged (the same error object,
-- never caught here) and pauses the mod on the next frame: the action is
-- cancelled, the region flags and the scanner's field go back, and nothing is
-- read until the updates below have returned on 60 frames in a row. Then it
-- resumes and applies its settings again. 8 failed updates below in a burst
-- stop it; the first failure survives shutdown. Every argument and return
-- value passes through.
local function game_below()
    local below = {fail = false, failure = {below = 'the game update failed'}}
    function below.update(...)
        below.args = {n = select('#', ...), ...}
        if below.fail then error(below.failure) end
        return 'r1', nil, 'r3'
    end
    function below.raise(t)
        below.fail = true
        local ok, err = pcall(t.env.update, 0.016)
        below.fail = false
        return ok, err
    end
    return below
end
do
    local below = game_below()
    local t = install({options = options_menu(), update = below.update})
    local world, state = t.world, t.state
    frames(t, 1)
    t.env.ModOptionsMenu.callbacks['better_lobby_management.region'](2)
    local field = Fake.SCANNER_CONFIG + S.RECHARGE
    assert(world.excluded('NA') == ALL_BUT_NA and world.get32(field) == 5)
    local results = {n = 0}
    local function keep(...) results = {n = select('#', ...), ...} end
    keep(t.env.update(0.016, 'x', nil, 'z'))
    assert(results.n == 3 and results[1] == 'r1' and results[2] == nil and results[3] == 'r3', 'returns pass through')
    assert(below.args.n == 4 and below.args[2] == 'x' and below.args[3] == nil and below.args[4] == 'z',
        'arguments pass through')
    squad(world, {TANGO})
    assert(state.promote())
    local ok, err = below.raise(t)
    assert(not ok and err == below.failure, 'the error reaches the game unchanged')
    local queries = world.api.queries
    t.env.update(0.016)
    assert(state.status == 'paused: the previous update failed' and state.guard.pauses == 1
        and state.guard.lower_errors == 1, state.status)
    assert(state.lobby == 'promote failed: cancelled: paused', state.lobby)
    assert(world.excluded('NA') == 'AF AS OC' and world.get32(field) == 20, 'game state restored')
    assert(world.api.queries == queries + 2, 'two page checks: the region table and the scanner\'s field')
    assert(count_logged(t, 'BetterLobbyManagement paused: the previous update failed') == 1 and state.errors == 0)
    -- Paused: nothing is read; the game's update keeps running.
    local counts = budget.wrap(world.api)
    for i = 2, 60 do budget.check(budget.frame(counts, t.env.update, 0.016), {}, 'paused frame ' .. i) end
    assert(state.status == 'paused: the previous update failed')
    queries = world.api.queries
    t.env.update(0.016)
    assert(state.status == 'ready' and logged(t, 'BetterLobbyManagement resumed after 60 clean frames'), state.status)
    assert(world.excluded('NA') == ALL_BUT_NA and world.get32(field) == 5, 'settings applied again')
    assert(world.api.queries == queries + 2, 'two page checks to apply them')
    assert(state.promote(), 'actions run again')
    -- 8 failed updates below within a burst: paused again (logged once), then stopped.
    for _ = 1, 7 do
        below.raise(t)
        t.env.update(0.016)
    end
    assert(state.status == 'stopped: stopped after 8 failed updates below this mod' and state.guard.lower_errors == 8,
        state.status)
    assert(count_logged(t, 'BetterLobbyManagement paused: ') == 2 and world.excluded('NA') == 'AF AS OC'
        and world.get32(field) == 20)
    t.env.shutdown()
    assert(state.status == 'stopped: stopped after 8 failed updates below this mod'
        and state.guard.state == 'stopped after: stopped after 8 failed updates below this mod', state.guard.state)
    -- A failure in the last frame before shutdown is kept; nothing failed: 'stopped'.
    local last = install({update = below.update})
    below.raise(last)
    last.env.shutdown()
    assert(last.state.status == 'stopped after: the previous update failed', last.state.status)
    local clean = install({})
    frames(clean, 2)
    clean.env.shutdown()
    assert(clean.state.status == 'stopped', clean.state.status)
end
-- A pause keeps a kept SOS cancel: it is the player's choice. Nothing keeps it
-- up while paused (the paused frames read nothing); the first frame after the
-- pause checks the session, the mission and the beacons again from fresh
-- reads before it acts, so a re-arm is turned off again and a cancel gone
-- stale ends with its usual reason.
do
    local function paused_with_a_kept_cancel()
        local below = game_below()
        local t = install({update = below.update})
        local world, state = t.world, t.state
        world.mode = G.MODE_MISSION
        world.native_types = {2, 3}
        world.sync()
        frames(t, 1)
        world.sos_beacon()
        assert(state.cancel_sos() and world.count('sos_deactivate') == 1)
        frames(t, 1)
        local counts = budget.wrap(world.api)
        below.raise(t)
        -- The pause frame: only the scanner's field goes back (Lobby Region is off here).
        local f = budget.frame(counts, t.env.update, 0.016)
        budget.check(f, {read32 = 1, writable_data = 1, write32 = 1}, 'pause frame, a cancel kept')
        assert(f.read32 == 1 and f.writable_data == 1 and f.write32 == 1, budget.describe(f))
        assert(state.status == 'paused: the previous update failed' and not logged(t, 'no longer kept off'))
        return t, world, state, counts
    end
    -- A re-arm while paused stays on until the pause ends; the first frame after it
    -- turns it off again, and so does a re-arm after that.
    local t, world, state, counts = paused_with_a_kept_cancel()
    world.sos_on() -- the game's re-arm (a player left)
    for i = 2, 60 do budget.check(budget.frame(counts, t.env.update, 0.016), {}, 'paused, a cancel kept ' .. i) end
    assert(world.count('sos_deactivate') == 1 and world.sos.active == 1, 'nothing is kept up while paused')
    t.env.update(0.016)
    assert(state.status == 'ready' and world.count('sos_deactivate') == 2 and world.sos.active == 0,
        'turned off again on the first frame after the pause')
    assert(count_logged(t, 'SOS: the game listed it again (a player left or a new host); cancelled again') == 1)
    world.sos_on()
    frames(t, 1)
    assert(world.count('sos_deactivate') == 3 and world.sos.active == 0, 'and after it')
    -- The mission ended during the pause: the first frame after it ends the kept cancel.
    t, world, state = paused_with_a_kept_cancel()
    world.mode = G.MODE_SHIP
    world.sync()
    for _ = 1, 60 do t.env.update(0.016) end
    assert(state.status == 'ready' and logged(t, '(the mission ended)') and world.count('sos_deactivate') == 1,
        state.status)
    -- A new SOS Beacon called in during the pause: the first frame after it lets the new SOS list.
    t, world, state = paused_with_a_kept_cancel()
    world.sos_beacon()
    for _ = 1, 60 do t.env.update(0.016) end
    assert(state.status == 'ready' and logged(t, '(a new SOS beacon was called in)')
        and world.count('sos_deactivate') == 1 and world.sos.active == 1, state.status)
end
print('PASS: an error below passes through unchanged and pauses the mod (action cancelled, region flags and scanner '
    .. 'field put back, a kept SOS cancel kept and checked again after it), which reads nothing until 60 clean '
    .. 'frames, then applies its settings again; 8 in a burst stop it; the first failure survives shutdown; '
    .. 'arguments and returns pass through')

-- Hostile neighbours (tests/hostile_vm.lua): below the mod one that raises a
-- table error object, above it one that re-hooks itself every frame and one
-- that calls the mod twice a frame. The error object reaches the caller
-- unchanged, the mod pauses (60 paused frames allocate nothing) and resumes,
-- and it keeps running under the others.
do
    local below
    local t = install({update = function() return 'r1' end, options = options_menu(),
        below = function(env) below = H.chain(env, 'throw_below', {raise_on = 3}) end})
    for _ = 1, 2 do assert(t.env.update(0.016) == 'r1') end
    local ok, err = pcall(t.env.update, 0.016)
    assert(not ok and err == below.last_error and err.hostile_vm == 'throw_below' and err.frame == 3,
        'the neighbour\'s table error object reaches the caller unchanged')
    t.env.update(0.016)
    assert(t.state.status == 'paused: the previous update failed' and t.state.guard.lower_errors == 1)
    -- Measured interpreted: a trace recorded inside the window (the paused path's
    -- first side exits) would count as heap growth too.
    jit.off()
    local kb = H.heap_peak(function() for _ = 1, 58 do t.env.update(0.016) end end)
    jit.on()
    assert(kb == 0, string.format('paused frames allocated %.3f KB', kb))
    t.env.update(0.016)
    assert(t.state.status == 'paused: the previous update failed', 'the 60th paused frame')
    t.env.update(0.016)
    assert(t.state.status == 'ready' and t.state.guard.state == 'running' and below.raised == 1, t.state.status)
    -- Above the mod: a neighbour that re-hooks every frame, then one that calls the mod twice a frame.
    local rehook = H.chain(t.env, 'rehook')
    for _ = 1, 200 do assert(t.env.update(0.016) == 'r1') end
    local double = H.chain(t.env, 'double_call')
    for _ = 1, 200 do assert(t.env.update(0.016) == 'r1') end
    assert(rehook.layers == 200 + 2 * 200 and double.calls == 2 * 200 and below.frames == 3 + 60 + 1 + 200 + 2 * 200,
        below.frames)
    assert(t.state.status == 'ready' and t.state.guard.errors == 0 and t.state.guard.pauses == 1, t.state.status)
    assert(H.chain_restore(t.env) and t.env.update == below.inner, 'the chain unwinds to the game update')
end
print('PASS: hostile neighbours: a table error object from below passes unchanged and pauses the mod (paused frames '
    .. 'allocate nothing), which resumes; neighbours above that re-hook every frame or call it twice do not disturb it')

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
