-- The kick-crash test build (src/diag.lua, the hold in src/lobby.lua and the
-- Kick Test option) with the real modules over the simulated game and engine
-- (Fake.install_engine): the recorder's startup checks and per-frame calls,
-- the timeline it logs at the mod's kick and at the game's KICK, and the crash
-- mechanism itself: a plain kick lets the engine unload a package while the
-- kicked player's Helldiver still uses it (the simulated engine crashes, as
-- the game did in v0.3), the hold keeps unloads paused until it is gone.
-- Usage: test_diag.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local L = dofile(source .. '/lobby.lua')
local R = dofile(source .. '/region.lua')
local M = dofile(source .. '/menu.lua')
local D = dofile(source .. '/diag.lua')
local C = dofile(source .. '/chat.lua')
local S = dofile(source .. '/scanner.lua')
local B = dofile(source .. '/sos.lua')
local Text = dofile(source .. '/bingus_text.lua')
local Runtime = dofile(source .. '/bingus_runtime.lua')
local LOCALES = {en = dofile(source .. '/../locales/en.lua'), bundled = {}}
local BUILD = {version = 'v-diag', game_sha256 = 'GAME', exe_sha256 = 'EXE', diag = true, runtime = Runtime}
local TANGO, CHARLIE = Fake.peer(0x01000000, 0x00000005), Fake.peer(0x0a000000, 0x00000007)
local DT = 1 / 60

-- Tango's loadout: two packages, the first holding nothing the Helldiver
-- uses, the second the muzzle on its gun (the order of the v0.3 crash).
local MUZZLE, BODY = 0x3000001000, 0x3000002000
local function tango_gear()
    return {packages = {{lo = 0x11111111, hi = 0xaaaaaaaa, resources = {}},
                        {lo = 0x0b17285c, hi = 0xbf2250de, resources = {MUZZLE}}},
            units = {[MUZZLE] = true, [BODY] = true}}
end

local function options_menu(saved)
    local menu = {api = 1, registered = {}, callbacks = {}}
    function menu.register_option(id, spec) menu.registered[#menu.registered + 1] = {id = id, spec = spec}; return true end
    function menu.get(id) return (saved or {})[id] end
    function menu.on_change(id, fn) menu.callbacks[id] = fn; return true end
    return menu
end

local function install(setup)
    setup = setup or {}
    local world = Fake.new({G = G, R = R})
    Fake.install_config(world, R)
    Fake.install_menu(world, M)
    -- Before the engine: both fakes own the player records, and the engine's are the ones read here.
    Fake.install_sos(world, B, G)
    Fake.install_engine(world, D)
    Fake.install_chat(world, C, G)
    Fake.install_scanner(world, S)
    if not setup.chat then world.code[Fake.GAME + C.SEND.rva] = ('x'):rep(#C.SEND.bytes) end
    world.names[Fake.key(TANGO)], world.names[Fake.key(CHARLIE)] = 'Tango', 'Charlie'
    if setup.world then setup.world(world) end
    world.sync()
    local env = setmetatable({}, {__index = _G}); env._G = env
    local lines = {}
    env.CowboyBingusModLoader = {api = 1, version = 17, open_log = function()
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}
    env.ModOptionsMenu = setup.options
    env.update = function() end
    env.shutdown = function() end
    local installer = setfenv(assert(loadfile(source .. '/addon.lua')), env)()
    installer(function() return world.api end, G, L, R, M, C, S, B, Text, LOCALES, setup.build or BUILD, D)
    return {env = env, world = world, lines = lines, state = env.BetterLobbyManagement}
end
-- One game frame: the Lua update (the mod), then the game update and the
-- package queue step, then the render callback; during(t) runs inside the
-- update after the mod's hook.
local function frame(t, game_update, during)
    t.world.tick()
    t.env.update(DT)
    if during then during(t) end
    t.world.engine_frame(game_update)
    if t.env.render then t.env.render() end
end
local function frames(t, n) for _ = 1, n do frame(t) end end
local function logged(t, text)
    for _, line in ipairs(t.lines) do if line:find(text, 1, true) then return line end end
end
local function log_text(t) return table.concat(t.lines) end
local function squad(world, peers)
    world.session = {world.local_peer}
    for _, peer in ipairs(peers) do world.session[#world.session + 1] = peer end
    world.host = world.local_peer
    world.sync()
end

-- Startup: the recorder checks its engine and game code; release builds never build it.
do
    local t = install()
    assert(t.state.diag == 'recording', t.state.diag)
    assert(logged(t, 'diag: recorder ready; in-use table 64 slots, strict 1; package queue head 0 tail 0; unload '
        .. 'pause 0'))
    assert(logged(t, 'diagnostics recording'))
    for _, code in ipairs(D.EXE_CODE) do
        local u = install({world = function(w) w.changed = Fake.EXE + code.rva end})
        assert(u.state.diag == 'disabled: ' .. code.name .. ' changed', u.state.diag)
        assert(u.state.status == 'ready', 'the mod itself still runs')
    end
    local u = install({world = function(w) w.changed = Fake.GAME + D.GAME_CODE[1].rva end})
    assert(u.state.diag == 'disabled: player history changed', u.state.diag)
    u = install({world = function(w) w.put64(Fake.APP + D.PACKAGE_MANAGER, 0) end})
    assert(u.state.diag == 'disabled: engine managers unavailable', u.state.diag)
    u = install({world = function(w) w.put32(Fake.RM + D.IN_USE_SLOTS, 0) end})
    assert(u.state.diag == 'disabled: engine tables unreadable', u.state.diag)
    local release = install({build = {version = 'v-rel', game_sha256 = 'GAME', exe_sha256 = 'EXE', runtime = Runtime}})
    assert(release.state.diag == nil and not logged(release, 'diag'), 'release builds have no recorder')
    local unused = install({build = {version = 'v-rel', game_sha256 = 'GAME', exe_sha256 = 'EXE', runtime = Runtime},
                            options = options_menu()})
    frames(unused, 1)
    local ids = {}
    for _, option in ipairs(unused.env.ModOptionsMenu.registered) do ids[#ids + 1] = option.id end
    assert(table.concat(ids, ' ') == 'better_lobby_management.region better_lobby_management.messages '
        .. 'better_lobby_management.scanner_seconds', 'Kick Test exists in test builds only')
end
print('PASS: the recorder verifies ' .. #D.EXE_CODE .. ' exe and ' .. #D.GAME_CODE .. ' game.dll signatures and the '
    .. 'engine tables, disables itself alone on any mismatch, and exists in test builds only')

-- Per-frame calls in the test build: idle frames add only the gate's loads;
-- an armed frame (hosting a squad on the ship) copies the in-use table once.
-- Every frame includes the scanner's idle check (a load64 and a load32).
do
    local t = install({options = options_menu()})
    local world = t.world
    frames(t, 1)
    local counts = budget.wrap(world.api)
    local function pinned(label, limits, n)
        for i = 1, n or 30 do
            local f = budget.frame(counts, function() frame(t) end)
            budget.check(f, limits, label .. ' ' .. i)
            assert((f.writable_data or 0) == 0, label .. ': no page checks')
        end
    end
    -- Since v1.1 alone includes the mode's two loads (CANCEL SOS).
    pinned('alone on the ship', {load32 = 4, load64 = 4})
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    pinned('no session', {load32 = 1, load64 = 3})
    world.put64(Fake.GAME + G.CONTEXT_PTR, Fake.CTX)
    frame(t)
    world.session, world.host = {TANGO, world.local_peer}, TANGO
    world.sync()
    pinned('client of another host', {load32 = 7, load64 = 3})
    squad(world, {TANGO})
    world.mode = G.MODE_MISSION
    world.sync()
    frame(t)
    -- The recorder's gate and session read (release build: load32 6, load64 4).
    pinned('hosting a squad in a mission', {load8 = 1, load32 = 26, load64 = 7})
    world.mode = G.MODE_SHIP
    world.sync()
    frame(t)
    -- Plus the table copy (slot count, entries, one block read) and the queue head, tail and pause flag.
    pinned('armed: hosting a squad on the ship', {load8 = 2, load32 = 29, load64 = 8, read_block = 1})
end
print('PASS: test-build idle frames cost only the gate\'s loads; an armed frame adds one block read of the in-use table; '
    .. 'no page checks')

-- Kick Test choices, in the option's order.
local GAME_KICK, KICK_FROM_RENDER, MESSAGE_FIRST, HOLD_UNLOADS, PLAIN_KICK = 1, 2, 3, 4, 5
local function kick_test(n) return options_menu({['better_lobby_management.kick_test'] = n}) end

-- Game Kick (the test build's default): DISBAND from the mod's button; once
-- the confirm dialog has faded out, the mod opens Tango's player menu and
-- completes its KICK hold, and the game kicks in its own update. Its removal
-- takes the Helldiver with it (test 2's recording of the game's KICK), so the
-- unloads that follow find nothing in use.
do
    local t = install({options = kick_test(GAME_KICK)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    world.open_menu()
    frames(t, 3)
    assert(logged(t, 'kick test: Game Kick'))
    world.focus(4 + 2)
    frames(t, 1)
    world.select(); frames(t, 1)
    world.answer(true)
    world.putf(world.content + M.DIALOG_FADE, 0.2)
    frames(t, 3)
    assert(logged(t, 'menu: disband confirmed') and logged(t, 'game kick: waiting for the escape menu (busy)'),
        log_text(t))
    assert(world.count('game_popup_kick') == 0, 'no kick while the dialog fades out')
    world.putf(world.content + M.DIALOG_FADE, 0)
    world.hide_dialog()
    frames(t, 2)
    assert(world.count('game_popup_kick') == 1 and world.last('game_popup_kick')[1] == Fake.key(TANGO))
    frames(t, 30)
    assert(not world.crashed, 'the game kicked; the Helldiver went with it')
    assert(world.count('kick_peer') == 0 and world.count('send_kick') == 0, 'the mod itself kicked nobody')
    assert(logged(t, 'game kick: KICK set on 100000000000005\'s player menu (card 1)'), log_text(t))
    assert(logged(t, 'game kick: 100000000000005 left the session'), log_text(t))
    assert(logged(t, 'diag: capture start: mod game of 100000000000005'), log_text(t))
    assert(logged(t, 'in-use gone 2 ['), log_text(t))
    assert(logged(t, 'disband: disbanded (1 players)'))
    assert(logged(t, 'menu trace: '), 'the dialog and focus states are traced')
end
print('PASS: Game Kick waits for the dialog to fade, then the game\'s own player-menu KICK removes the player and '
    .. 'the Helldiver; nothing is unloaded while in use')

-- Promote with Game Kick: once the game has kicked the successor, the
-- recorder reports the host's own lobby (access policy and search
-- properties, the continent withheld) and every search is logged, the first
-- for the host's own lobby.
do
    local t = install({options = kick_test(GAME_KICK)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    world.successor = TANGO
    world.open_menu()
    frames(t, 3)
    world.focus(4 + 3)
    frames(t, 1)
    world.select(); frames(t, 1)
    world.answer(true)
    world.hide_dialog()
    frames(t, 3)
    assert(world.count('game_popup_kick') == 1 and logged(t, 'menu: promote confirmed'), log_text(t))
    frames(t, math.ceil((L.FIRST_SEARCH + 2) / DT))
    local report = logged(t, 'diag: own lobby: access policy 0; string_key1=1.8.46015; string_key2='
        .. world.api.u64_decimal(world.local_peer.lo, world.local_peer.hi))
    assert(report and report:find('string_key6=(continent, not logged); number_key6=0', 1, true), log_text(t))
    assert(not report:find('=NA', 1, true), 'the continent is not logged')
    assert(not logged(t, 'control search'), 'the control search is off: it delayed the successor\'s search')
    assert(logged(t, 'promote: search 1 for Tango\'s lobby'), log_text(t))
end
print('PASS: promote with Game Kick logs the host\'s own lobby properties (no continent) and every search, with no '
    .. 'control search')

-- Promote Notice (test builds only): Squad Leader Line by default, the game's
-- new-host RPC naming Tango and no chat line; Chat Line from the option.
-- Either way the escape menu is closed once Tango has left.
do
    local mom = options_menu()
    local t = install({chat = true, options = mom})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    world.successor = TANGO
    world.open_menu()
    frames(t, 3)
    local ids = {}
    for _, option in ipairs(mom.registered) do ids[#ids + 1] = option.id end
    assert(table.concat(ids, ' ') == 'better_lobby_management.region better_lobby_management.messages '
        .. 'better_lobby_management.scanner_seconds better_lobby_management.kick_test '
        .. 'better_lobby_management.promote_notice', table.concat(ids, ' '))
    assert(t.state.promote())
    local sent = world.last('rpc_send')
    assert(sent and sent[1] == C.NEW_HOST and sent[6] == Fake.key(TANGO) and world.count('chat_send') == 0)
    assert(logged(t, 'squad leader notice for 0100000000000005 sent to 0100000000000005'), log_text(t))
    frames(t, 60)
    assert(world.count('game_popup_kick') == 1 and world.count('escape_closed') == 1, log_text(t))
    local chat = install({chat = true, options = options_menu({['better_lobby_management.promote_notice'] = 2})})
    world = chat.world
    squad(world, {TANGO})
    world.successor = TANGO
    world.open_menu()
    frames(chat, 3)
    assert(logged(chat, 'promote notice: Chat Line') and chat.state.promote())
    assert(world.count('rpc_send') == 0 and world.last('chat_send')[3] == 'Tango is the new host. The squad is moving '
        .. 'to their ship.')
end
print('PASS: test builds send the game\'s new squad leader notice before PROMOTE\'s kick by default (Chat Line from '
    .. 'the option) and close the escape menu once the new host has left')

-- A plain kick (v0.3): the kick queues Tango's loadout unloads, the engine
-- unloads one per frame, and the second meets the muzzle still on Tango's gun.
do
    local t = install({options = kick_test(PLAIN_KICK)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 3)
    assert(logged(t, 'kick test: Plain Kick (v0.3)'))
    frame(t, nil, function() assert(t.state.disband()) end)
    assert(not world.crashed, 'the first unload holds nothing in use')
    frame(t)
    assert(world.crashed and world.crashed.resource == MUZZLE and world.crashed.hi == 0xbf2250de,
        'the simulated engine crashes on the second unload, as the game did')
    assert(logged(t, 'diag: capture start: mod kick of 100000000000005; in-use entries 4; package queue head 0 tail 0; '
        .. 'unload pause 0; lobby members 2'), log_text(t))
    assert(logged(t, 'before the kick: history inactive 0 kicked 0 loadout 1 type 1; package queue head 0 tail 0; '
        .. 'unload pause 0'))
    assert(logged(t, 'after the kick: history inactive 1 kicked 1 loadout 0 type 1; queued during it 2: unload '
        .. 'aaaaaaaa11111111, unload bf2250de0b17285c'), log_text(t))
    assert(logged(t, 'processed 1 [unload aaaaaaaa11111111]'))
    assert(not logged(t, 'package unloads paused'))
    assert(logged(t, 'disband: kicked Tango') and logged(t, 'disband: disbanded (1 players)'))
end
print('PASS: a plain kick reproduces the v0.3 crash on the simulated engine; the log shows the kick queuing the '
    .. 'loadout unloads and the unload order')

-- Hold Unloads with a client that leaves: unloads wait while Tango's
-- Helldiver despawns and run after the hold, with nothing left in use.
do
    local t = install({options = kick_test(HOLD_UNLOADS)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 3)
    frame(t, nil, function() assert(t.state.disband()) end)
    local kicked_at = world.frame
    frames(t, math.ceil(L.UNLOAD_HOLD / DT) + 10)
    assert(not world.crashed, 'no unload while the Helldiver held its gear')
    assert(#world.processed == 2 and world.processed[1].frame > kicked_at + world.despawn_frames,
        'both unloads ran after the hold')
    assert(logged(t, 'kick: package unloads paused'))
    assert(logged(t, 'unload pause 0>1'), log_text(t))
    assert(logged(t, 'in-use gone 2 ['), log_text(t))
    assert(logged(t, 'package unloads resumed after 10.0 s'), log_text(t))
    assert(logged(t, 'unload pause 1>0'))
    assert(logged(t, 'processed 1 [unload bf2250de0b17285c]'))
    frames(t, math.ceil(D.CAPTURE_AFTER / DT) + 2)
    assert(logged(t, 'diag: capture end after'))
    local calls = #world.calls
    frames(t, 30)
    assert(#world.calls == calls, 'alone again: no native calls')
end
print('PASS: Hold Unloads keeps the engine from unloading the kicked player\'s packages until ' .. L.UNLOAD_HOLD
    .. ' s after the kick; the log shows the despawn, the release and the unloads, then the capture ends')

-- Test 1's failure: the kick message never reaches the client, which stays in
-- the lobby with its Helldiver. The hold now waits for it to leave the lobby;
-- at the cap the simulated engine crashes as the game did.
do
    local t = install({options = kick_test(HOLD_UNLOADS), world = function(w) w.kick_message_lost = true end})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 3)
    frame(t, nil, function() assert(t.state.disband()) end)
    frames(t, math.ceil(L.UNLOAD_HOLD / DT) + 30)
    assert(not world.crashed and world.bytes[world.pause_flag] == 1, 'held while the client lingers in the lobby')
    frames(t, math.ceil((L.UNLOAD_HOLD_CAP - L.UNLOAD_HOLD) / DT) + 10)
    assert(world.crashed and world.crashed.resource == MUZZLE, 'released at the cap: the gear is still in use')
    assert(logged(t, string.format('package unloads resumed after %.1f s (cap)', L.UNLOAD_HOLD_CAP)), log_text(t))
    assert(not logged(t, 'lobby members 2>1'), 'the client never left the lobby')
end
print('PASS: a kick whose message is lost (the v0.4-diag1 result) keeps the client in the lobby; the hold waits for '
    .. 'it and the recorder shows the lobby never shrinking')

-- Message First (the test build's default): only the kick message; the
-- client leaves by itself and the game's own leave handling removes it.
do
    local t = install({options = kick_test(MESSAGE_FIRST)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    world.despawn_frames = 0
    frames(t, 3)
    assert(logged(t, 'kick test: Message First'))
    frame(t, nil, function() assert(t.state.disband()) end)
    assert(world.count('send_kick') == 1 and world.count('kick_peer') == 0 and world.count('pause_unloads') == 0)
    frames(t, 10)
    assert(not world.crashed and #world.session == 1)
    assert(logged(t, 'diag: capture start: mod message of 100000000000005'), log_text(t))
    assert(logged(t, 'after the message: history inactive 0 kicked 0 loadout 1 type 1; queued during it 0'),
        log_text(t))
    assert(logged(t, 'event: the kicked player 100000000000005 left the session'), log_text(t))
    assert(logged(t, 'lobby members 2>1'), log_text(t))
    assert(logged(t, 'disband: disbanded (1 players)'))
    -- A client that ignores the message stays; nothing else is tried.
    local u = install({options = kick_test(MESSAGE_FIRST), world = function(w) w.message_ignored = true end})
    squad(u.world, {TANGO})
    frames(u, 2)
    frame(u, nil, function() assert(u.state.disband()) end)
    frames(u, math.ceil((L.DISBAND_TIMEOUT + 1) / DT))
    assert(logged(u, 'disband: disbanded (1 players; 1 still leaving)') and u.world.count('kick_peer') == 0)
end
print('PASS: Message First sends only the kick message; a client that obeys leaves by itself (lobby and session '
    .. 'shrink), one that ignores it is reported as still leaving')

-- Kick From Render: the update queues the kick; the render callback, after
-- the game's own update, kicks with the hold.
do
    local t = install({options = kick_test(KICK_FROM_RENDER)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 3)
    local kicked_in_update
    frame(t, nil, function()
        assert(t.state.disband())
        kicked_in_update = world.count('kick_peer')
    end)
    assert(kicked_in_update == 0 and world.count('kick_peer') == 1, 'kicked in the render callback, not the update')
    frames(t, math.ceil(L.UNLOAD_HOLD / DT) + 10)
    assert(not world.crashed)
    assert(logged(t, 'diag: capture start: mod render of 100000000000005'), log_text(t))
    assert(logged(t, 'after the render: history inactive 1 kicked 1 loadout 0 type 1; queued during it 2'),
        log_text(t))
    assert(logged(t, 'package unloads resumed after 10.0 s'), log_text(t))
end
print('PASS: Kick From Render kicks in the render callback with the unload hold')

-- An error in the render kicks: the running action is cancelled at once (the
-- hold released), and the error goes to the shared runtime's guard at the end
-- of the next update, as one of the mod's own errors (one log line per burst).
do
    local t = install({options = kick_test(KICK_FROM_RENDER)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 3)
    local u64, raised = world.api.u64, 0
    world.api.u64 = function(...)
        if raised == 0 then raised = 1; error('render broke', 0) end
        return u64(...)
    end
    frame(t, nil, function() assert(t.state.disband()) end)
    assert(raised == 1 and t.state.errors == 1 and t.state.lobby == 'disband failed: cancelled: error'
        and world.count('kick_peer') == 0, t.state.lobby)
    assert(logged(t, 'package unloads resumed: error') and t.state.guard.errors == 0, 'counted on the next update')
    frame(t)
    assert(t.state.guard.errors == 1 and logged(t, 'BetterLobbyManagement error: render broke')
        and t.state.status == 'ready', log_text(t))
    frames(t, 3)
    assert(t.state.guard.errors == 1 and t.state.errors == 1, 'counted once')
end
print('PASS: an error in the render kicks cancels the action at once and counts as an own error on the next update')

-- The game's own KICK in a two-player squad: the recorder still sees the
-- departure although the squad is down to the host (missed in test 1).
do
    local t = install()
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    world.despawn_frames = 0
    frames(t, 3)
    frame(t, function() world.game_kick(TANGO) end)
    frames(t, 2)
    assert(not world.crashed)
    assert(logged(t, 'diag: capture start: player 100000000000005 left the session (history inactive 1 kicked 1 '
        .. 'loadout 0 type 1)'), log_text(t))
    local line = logged(t, 'queued 2 [unload aaaaaaaa11111111 unload bf2250de0b17285c]')
    assert(line and line:find('processed 1 [unload aaaaaaaa11111111]', 1, true), log_text(t))
    assert(logged(t, 'in-use gone 2 ['), log_text(t))
    -- The fake's lobby shrinks with the session; the capture's first line has the count.
    assert(logged(t, 'loadout 0 type 1); in-use entries 4; package queue head 0 tail 0; unload pause 0; lobby members 1'),
        log_text(t))
    frames(t, math.ceil(D.CAPTURE_AFTER / DT) + 2)
    assert(logged(t, 'diag: capture end after'))
    -- In a bigger squad a voluntary leave (kicked 0) is recorded too.
    local u = install()
    squad(u.world, {TANGO, CHARLIE})
    u.world.give_gear(CHARLIE, {packages = {}, units = {}})
    frames(u, 3)
    frame(u, function() u.world.leave(CHARLIE) end)
    frames(u, 2)
    assert(logged(u, 'player A00000000000007 left the session (history inactive 1 kicked 0 loadout 0 type 1)'),
        log_text(u))
end
print('PASS: the game\'s KICK in a two-player squad and voluntary leaves start a capture with the player\'s history '
    .. 'flags, the queued and processed packages, the in-use changes and the lobby members')

-- A failed table copy is reported and compares nothing; diffs resume against the last good copy.
do
    local t = install({options = kick_test(HOLD_UNLOADS)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 2)
    frame(t, nil, function() assert(t.state.disband()) end)
    world.unmapped[Fake.IN_USE] = true
    frame(t)
    assert(logged(t, 'in-use table unreadable'), log_text(t))
    assert(not logged(t, 'in-use gone'), 'no false departures of every entry')
    world.unmapped[Fake.IN_USE] = nil
    frames(t, 5)
    assert(logged(t, 'in-use gone 2 ['), log_text(t))
end
print('PASS: a failed in-use table copy is reported and never read as every entry gone')

-- Shutdown releases a hold the mod holds.
do
    local t = install({options = kick_test(HOLD_UNLOADS)})
    local world = t.world
    squad(world, {TANGO})
    world.give_gear(TANGO, tango_gear())
    frames(t, 2)
    frame(t, nil, function() assert(t.state.disband()) end)
    assert(world.bytes[world.pause_flag] == 1)
    t.env.shutdown()
    assert(world.bytes[world.pause_flag] == 0 and logged(t, 'package unloads resumed: shutdown'))
end
print('PASS: shutdown resumes the package unloads the mod paused')
