-- Squad actions (src/lobby.lua) against the simulated game: disband and
-- promote on the ship, successor choice, retries, timeouts and refusals, with
-- the api calls of each frame pinned by tests/frame_budget.lua.
-- Usage: test_lobby.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local L = dofile(source .. '/lobby.lua')

local DT = 1 / 60
local T = Fake.peer(0x01000000, 0x00000005)    -- successor candidate (lowest id)
local C = Fake.peer(0x0a000000, 0x00000007)    -- another client
local D = Fake.peer(0x0b000000, 0x00000009)
local function api_hex(peer) return string.format('%X%08X', peer.hi, peer.lo) end

local function setup(configure)
    local world = Fake.new({G = G})
    world.session = {world.local_peer, T, C}
    world.names[Fake.key(T)], world.names[Fake.key(C)] = 'Tango', 'Charlie'
    if configure then configure(world) end
    world.sync()
    local natives = G.bind(world.api, Fake.GAME, Fake.EXE)
    local status, lines = {}, {}
    local lobby = L.new(world.api, Fake.GAME, G, natives, status, function(message) lines[#lines + 1] = message end)
    return world, lobby, status, lines
end

-- Runs frames until done(world) or max frames; returns the clock.
local function run(world, lobby, now, frames, done)
    for _ = 1, frames do
        world.tick()
        now = now + DT
        lobby.step(now)
        if done and done(world) then break end
    end
    return now
end
local function idle(lobby) return function() return not lobby.busy() end end
local function joined(lines) return table.concat(lines, '\n') end

-- Disband: every other player kicked with the game's own kick, one per frame.
do
    local world, lobby, status, lines = setup()
    local counts = budget.wrap(world.api)
    local frame, ok = budget.frame(counts, lobby.disband, 0)
    assert(ok == true, 'disband')
    assert(world.count('kick_peer') == 1 and world.last('kick_peer')[1] == Fake.CTX + G.HOST_SYNC
        and world.last('kick_peer')[2] == Fake.key(T), 'the first kick in the confirming frame')
    assert((frame.writable_data or 0) == 0, 'disband writes no game memory')
    -- Exact counts today: two session snapshots (context confirmed once), roster names, one id.
    budget.check(frame, {cstring = 3, load8 = 2, load32 = 44, load64 = 6, read32 = 3, u64 = 1}, 'disband first frame')
    world.tick(); lobby.step(DT)
    assert(world.count('kick_peer') == 2 and world.last('kick_peer')[2] == Fake.key(C), 'one kick per frame')
    world.tick(); lobby.step(2 * DT)
    assert(not lobby.busy() and #world.session == 1 and status.lobby == 'disbanded (2 players)', status.lobby)
    assert(joined(lines):find('disband: kicked Tango') and joined(lines):find('disband: kicked Charlie'))
end
do
    -- A kicked player still in the session is not kicked twice; the job ends at its deadline.
    local world, lobby, status = setup(function(w) w.keep_removed = true end)
    lobby.disband(0)
    run(world, lobby, 0, math.ceil((L.DISBAND_TIMEOUT + 1) / DT), idle(lobby))
    assert(world.count('kick_peer') == 2 and status.lobby == 'disbanded (2 players; 2 still leaving)', status.lobby)
    -- A player who left before their turn is skipped.
    world, lobby, status = setup()
    lobby.disband(0)
    world.session = {world.local_peer}
    world.sync()
    world.tick(); lobby.step(DT)
    assert(world.count('kick_peer') == 1 and status.lobby == 'disbanded (1 players)', status.lobby)
end
print('PASS: disband kicks every other player with the game\'s own kick, one per frame, skipping those who left')

-- Disband refusals leave the session alone.
for _, case in ipairs({
        {function(w) w.mode = G.MODE_MISSION end, 'only on the ship'},
        {function(w) w.host = C end, 'not hosting'},
        {function(w) w.hosting = 2 end, 'not hosting'},
        {function(w) w.session = {w.local_peer} end, 'no other players'},
        {function(w) w.transition = 1 end, 'a transition is running'},
        {function(w) w.join_state = 1 end, 'a join is running'},
        {function(w) w.party_join = 1 end, 'a join is running'}}) do
    local world, lobby, status = setup(case[1])
    local ok, why = lobby.disband(0)
    assert(ok == false and why == case[2], tostring(why))
    assert(world.count('kick_peer') == 0)
    assert(status.lobby == 'disband refused: ' .. case[2])
end
do
    local world, lobby = setup()
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    local ok, why = lobby.disband(0)
    assert(ok == false and why == 'no network session')
end
print('PASS: disband refuses in a mission, as a client, alone, during transitions or joins, and without a session')

-- Squad messages: one chat line before the first kick, the kick L.CHAT_LEAD later.
do
    local world, lobby, status, lines = setup()
    local said = {}
    lobby.announcer = function(text) said[#said + 1] = text; return true, 2 end
    lobby.disband(0)
    assert(said[1] == 'The host disbanded the squad.' and world.count('kick_peer') == 0, said[1])
    lobby.step(L.CHAT_LEAD - 0.01)
    assert(world.count('kick_peer') == 0, 'the message goes first')
    lobby.step(L.CHAT_LEAD)
    assert(world.count('kick_peer') == 1 and #said == 1)
    assert(joined(lines):find('squad message sent to 2 player(s): The host disbanded the squad.', 1,
        true), joined(lines))
    -- Promote with the test builds' Chat Line: the message, then the kick of the successor.
    world, lobby, status = setup(function(w) w.successor = T end)
    said = {}
    lobby.notice_mode = 'chat'
    lobby.announcer = function(text) said[#said + 1] = text; return true, 2 end
    lobby.promote(nil, 100)
    assert(said[1] == 'Tango is the new host. The squad is moving to their ship.', said[1])
    assert(status.lobby == 'promote: telling the squad' and world.count('kick_peer') == 0, status.lobby)
    world.tick(); lobby.step(100 + L.CHAT_LEAD)
    assert(world.count('kick_peer') == 1 and status.lobby == 'promote: Tango returns to their ship', status.lobby)
    -- The successor left meanwhile: nothing to kick.
    world, lobby, status = setup(function(w) w.successor = T end)
    lobby.leader_notice = function() return true, 2 end
    lobby.promote(nil, 0)
    world.session = {world.local_peer, C}
    world.sync()
    lobby.step(L.CHAT_LEAD)
    assert(world.count('kick_peer') == 0 and status.lobby == 'promote failed: Tango left the squad meanwhile', status.lobby)
    -- A message that could not go out never holds the kick up.
    world, lobby, _, lines = setup()
    lobby.announcer = function() return false, 'nobody else in the session' end
    lobby.disband(0)
    assert(world.count('kick_peer') == 1 and joined(lines):find('squad message not sent: nobody else in the session', 1,
        true), joined(lines))
end
print('PASS: squad messages go out before the first kick, which follows ' .. L.CHAT_LEAD .. ' s later; a failed '
    .. 'message never holds the kick up')

-- Notice mode 'leader' (test builds): the game's new squad leader notice instead of the chat line.
do
    local world, lobby, status, lines = setup(function(w) w.successor = T end)
    local said, named = {}, {}
    lobby.announcer = function(text) said[#said + 1] = text; return true, 2 end
    lobby.leader_notice = function(lo, hi) named[#named + 1] = {lo, hi}; return true, 2 end
    lobby.notice_mode = 'leader'
    lobby.promote(nil, 100)
    assert(#said == 0 and #named == 1 and named[1][1] == T.lo and named[1][2] == T.hi, 'the notice names Tango')
    assert(status.lobby == 'promote: telling the squad' and world.count('kick_peer') == 0, status.lobby)
    assert(joined(lines):find('squad leader notice sent to 2 player(s): Tango', 1, true), joined(lines))
    world.tick(); lobby.step(100 + L.CHAT_LEAD)
    assert(world.count('kick_peer') == 1, 'the kick follows L.CHAT_LEAD later')
    -- Squad messages off (no leader_notice): nothing is sent and the kick is immediate.
    world, lobby = setup(function(w) w.successor = T end)
    lobby.notice_mode = 'leader'
    lobby.promote(nil, 0)
    assert(world.count('kick_peer') == 1)
    -- A notice that could not go out never holds the kick up.
    world, lobby, _, lines = setup(function(w) w.successor = T end)
    lobby.notice_mode = 'leader'
    lobby.leader_notice = function() return false, 'nobody else in the session' end
    lobby.promote(nil, 0)
    assert(world.count('kick_peer') == 1 and joined(lines):find('squad leader notice not sent: nobody else in the '
        .. 'session', 1, true), joined(lines))
end
print('PASS: notice mode leader sends the game\'s new squad leader notice before PROMOTE\'s kick; off or '
    .. 'failed, the kick is not held up')

-- The escape menu is closed, as Esc does, once PROMOTE no longer needs it.
do
    local world, lobby, status, lines = setup(function(w) w.successor = T end)
    local closes = 0
    lobby.menu_closer = function() closes = closes + 1; return true end
    lobby.promote(nil, 0)
    assert(closes == 0, 'open while the kick needs it')
    world.tick(); lobby.step(DT)
    assert(lobby.job().step == 'search' and closes == 1, 'closed once the successor left')
    assert(joined(lines):find('promote: escape menu closed', 1, true), joined(lines))
    run(world, lobby, DT, 400, idle(lobby))
    assert(closes == 1 and status.lobby:find('^squad moved to Tango\'s ship'), status.lobby)
    -- Already closed by the player: logged, nothing else.
    world, lobby, _, lines = setup(function(w) w.successor = T end)
    lobby.menu_closer = function() return false, 'closed' end
    lobby.promote(nil, 0)
    world.tick(); lobby.step(DT)
    assert(joined(lines):find('promote: escape menu not closed: closed', 1, true), joined(lines))
    -- Disband keeps it open: the host stays on the ship.
    world, lobby = setup()
    closes = 0
    lobby.menu_closer = function() closes = closes + 1; return true end
    lobby.disband(0)
    run(world, lobby, 0, 10, idle(lobby))
    assert(closes == 0)
end
print('PASS: promote closes the escape menu once the successor has left; disband never does')

-- The engine's package unloads are paused before the first kick and resumed
-- L.UNLOAD_HOLD after the last one, once the session is stable.
local function call_names(world)
    local names = {}
    for _, call in ipairs(world.calls) do names[#names + 1] = call.name end
    return table.concat(names, ' ')
end
do
    local world, lobby, status, lines = setup()
    lobby.disband(0)
    assert(call_names(world) == 'unload_paused pause_unloads kick_peer', call_names(world))
    assert(world.last('pause_unloads')[1] == 1 and world.unload_paused == 1 and lobby.holding())
    world.tick(); lobby.step(DT)
    assert(world.count('kick_peer') == 2 and world.count('pause_unloads') == 1 and world.count('unload_paused') == 1,
        'one pause for the whole disband')
    world.tick(); lobby.step(2 * DT)
    assert(not lobby.busy() and lobby.holding(), 'the hold outlives the action')
    lobby.tick(DT + L.UNLOAD_HOLD - 0.01)
    assert(world.unload_paused == 1 and lobby.holding(), 'held until L.UNLOAD_HOLD after the last kick')
    lobby.tick(DT + L.UNLOAD_HOLD)
    assert(world.unload_paused == 0 and not lobby.holding() and world.last('pause_unloads')[1] == 0)
    assert(joined(lines):find('kick: package unloads paused', 1, true)
        and joined(lines):find('package unloads resumed after 10.0 s', 1, true), joined(lines))
end
do
    -- Promote holds too.
    local world, lobby = setup(function(w) w.successor = T end)
    lobby.promote(nil, 100)
    assert(call_names(world) == 'unload_paused pause_unloads kick_peer', call_names(world))
end
do
    -- The game had paused unloads already (its world teardown): the mod leaves the flag to the game.
    local world, lobby, _, lines = setup(function(w) w.unload_paused = 1 end)
    lobby.disband(0)
    assert(call_names(world) == 'unload_paused kick_peer', call_names(world))
    lobby.tick(L.UNLOAD_HOLD + 1)
    assert(world.unload_paused == 1 and not lobby.holding() and world.count('pause_unloads') == 0)
    assert(joined(lines):find('package unloads already paused by the game', 1, true))
    -- The game cleared the flag during the mod's hold: nothing left to resume.
    world, lobby, _, lines = setup()
    lobby.disband(0)
    world.unload_paused = 0
    lobby.tick(L.UNLOAD_HOLD + 1)
    assert(world.count('pause_unloads') == 1 and not lobby.holding())
    assert(joined(lines):find('package unloads resumed by the game after', 1, true))
end
do
    -- A transition (or no session) keeps the hold until the cap; the game's teardown owns the flag meanwhile.
    local world, lobby, _, lines = setup()
    lobby.disband(0)
    world.transition = 1
    world.sync()
    lobby.tick(L.UNLOAD_HOLD + 1)
    assert(world.unload_paused == 1 and lobby.holding(), 'not resumed during a transition')
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    lobby.tick(L.UNLOAD_HOLD_CAP - 0.1)
    assert(world.unload_paused == 1 and lobby.holding(), 'not resumed without a session')
    lobby.tick(L.UNLOAD_HOLD_CAP)
    assert(world.unload_paused == 0 and not lobby.holding())
    assert(joined(lines):find(string.format('package unloads resumed after %.1f s (cap)', L.UNLOAD_HOLD_CAP), 1, true),
        joined(lines))
    -- The transition ends before the cap: resumed then.
    world, lobby = setup()
    lobby.disband(0)
    world.transition = 1
    world.sync()
    lobby.tick(L.UNLOAD_HOLD + 1)
    world.transition = 0
    world.sync()
    lobby.tick(L.UNLOAD_HOLD + 2)
    assert(world.unload_paused == 0 and not lobby.holding())
end
do
    -- An error or shutdown resumes unloads the mod paused, and only those.
    local world, lobby, _, lines = setup()
    lobby.disband(0)
    lobby.release_hold('error')
    assert(world.unload_paused == 0 and not lobby.holding() and joined(lines):find('package unloads resumed: error', 1, true))
    lobby.release_hold('shutdown')
    assert(world.count('pause_unloads') == 2, 'nothing to release twice')
    world, lobby = setup(function(w) w.unload_paused = 1 end)
    lobby.disband(0)
    lobby.release_hold('shutdown')
    assert(world.unload_paused == 1 and world.count('pause_unloads') == 0, 'the game\'s pause stays')
end
do
    -- Plain kicks (diagnostic builds): no pause.
    local world, lobby = setup()
    lobby.kick_mode = 'plain'
    lobby.disband(0)
    assert(call_names(world) == 'kick_peer' and not lobby.holding(), call_names(world))
end
do
    -- A kicked client still in the PlayFab lobby (its kick message lost) keeps the hold.
    local world, lobby = setup(function(w) w.kick_message_lost = true end)
    lobby.disband(0)
    world.tick(); lobby.step(DT)
    lobby.tick(DT + L.UNLOAD_HOLD + 1)
    assert(world.unload_paused == 1 and lobby.holding(), 'held while kicked clients linger in the lobby')
    world.lingering = {}
    world.sync()
    lobby.tick(DT + L.UNLOAD_HOLD + 2)
    assert(world.unload_paused == 0 and not lobby.holding(), 'resumed once they left')
end
do
    -- Message First (diagnostic builds): the kick message alone; the clients leave by themselves.
    local world, lobby, status = setup()
    lobby.kick_mode = 'message'
    lobby.disband(0)
    assert(call_names(world) == 'send_kick' and world.last('send_kick')[1] == Fake.key(T) and not lobby.holding(),
        call_names(world))
    world.tick(); lobby.step(DT)
    assert(world.count('send_kick') == 2 and world.count('kick_peer') == 0)
    run(world, lobby, DT, 10, idle(lobby))
    assert(status.lobby == 'disbanded (2 players)' and #world.session == 1, status.lobby)
    -- Clients that ignore the message are still there at the deadline; nothing else is tried.
    world, lobby, status = setup(function(w) w.message_ignored = true end)
    lobby.kick_mode = 'message'
    lobby.disband(0)
    run(world, lobby, 0, math.ceil((L.DISBAND_TIMEOUT + 1) / DT), idle(lobby))
    assert(status.lobby == 'disbanded (2 players; 2 still leaving)' and world.count('kick_peer') == 0, status.lobby)
end
do
    -- Kick From Render (diagnostic builds): the update queues, the render callback kicks with the hold.
    local world, lobby = setup()
    lobby.kick_mode = 'render'
    lobby.disband(0)
    assert(world.count('kick_peer') == 0 and not lobby.holding(), 'nothing kicked in the update')
    lobby.render_step(0)
    assert(call_names(world) == 'unload_paused pause_unloads kick_peer' and lobby.holding(), call_names(world))
    lobby.render_step(0)
    assert(world.count('kick_peer') == 1, 'each queued kick runs once')
end
do
    -- Game Kick (test builds): the player menu's KICK through the escape menu,
    -- one player at a time, each waiting for the menu and then for the player to go.
    local world, lobby, status, lines = setup()
    lobby.kick_mode = 'game'
    local asked = {}
    lobby.game_kicker = function(lo, hi)
        asked[#asked + 1] = G.peer_key(lo, hi)
        if #asked == 1 then return 'busy' end
        for i, peer in ipairs(world.session) do
            if peer.lo == lo and peer.hi == hi then table.remove(world.session, i); break end
        end
        return 'started', #asked
    end
    lobby.disband(0)
    assert(world.count('kick_peer') == 0 and lobby.ui_pending())
    lobby.ui_step(0)
    assert(joined(lines):find('game kick: waiting for the escape menu (busy)', 1, true))
    lobby.ui_step(DT)
    assert(joined(lines):find('game kick: KICK set on ' .. api_hex(T) .. '\'s player menu (card 2)', 1, true), joined(lines))
    world.tick(); lobby.step(DT)       -- the disband queues Charlie
    lobby.ui_step(2 * DT)              -- Tango is gone: done with Tango
    assert(joined(lines):find('game kick: ' .. api_hex(T) .. ' left the session', 1, true), joined(lines))
    lobby.ui_step(3 * DT)
    world.sync()
    lobby.ui_step(4 * DT)
    assert(not lobby.ui_pending() and #asked == 3 and asked[3] == Fake.key(C), table.concat(asked, ' '))
    run(world, lobby, 4 * DT, 5, idle(lobby))
    assert(status.lobby == 'disbanded (2 players)' and world.count('kick_peer') == 0, status.lobby)
    -- A menu that never takes input: given up after the wait.
    world, lobby, _, lines = setup()
    lobby.kick_mode = 'game'
    lobby.game_kicker = function() return 'menu closed' end
    lobby.disband(0)
    lobby.ui_step(0)
    lobby.ui_step(L.GAME_KICK_WAIT)
    assert(joined(lines):find('game kick: gave up on ' .. api_hex(T) .. ' (menu closed)', 1, true), joined(lines))
    -- A KICK that never runs: reported after the wait.
    world, lobby, _, lines = setup()
    lobby.kick_mode = 'game'
    lobby.game_kicker = function() return 'started', 1 end
    lobby.disband(0)
    lobby.ui_step(0)
    lobby.ui_step(L.GAME_KICK_WAIT)
    assert(joined(lines):find('still in the session; the player menu\'s KICK did not run', 1, true), joined(lines))
    assert(not lobby.ui_pending())
end
print('PASS: package unloads are paused before the first kick and resumed at least ' .. L.UNLOAD_HOLD .. ' s after the '
    .. 'last once the session is stable and no kicked client lingers in the lobby (cap ' .. L.UNLOAD_HOLD_CAP .. ' s); '
    .. 'the game\'s own pause is left alone; errors and shutdown resume; the Message First, Kick From Render and Plain '
    .. 'Kick test modes')

-- Successor choice: the player picked in the menu, else a friend first, then the lowest peer id.
do
    local world, lobby = setup()
    local snap = lobby.snapshot()
    local pick = lobby.choose_successor(snap)
    assert(pick.lo == T.lo and pick.hi == T.hi, 'lowest peer id without friends')
    world.friends[Fake.key(C)] = true
    pick = lobby.choose_successor(snap)
    assert(pick.lo == C.lo and pick.friend == true, 'a friend wins over a lower id')
    pick = lobby.choose_successor(snap, {lo = T.lo, hi = T.hi})
    assert(pick.lo == T.lo and pick.hi == T.hi, 'the picked player')
    local none, why = lobby.choose_successor(snap, {lo = D.lo, hi = D.hi})
    assert(none == nil and why == 'that player is no longer in the squad')
    local _, solo = setup(function(w) w.session = {w.local_peer} end)
    local _, alone = solo.choose_successor(solo.snapshot())
    assert(alone == 'no other players')
end
print('PASS: successor choice takes the picked player, else prefers friends, then the lowest peer id')

-- Promote: the successor kicked home, its lobby found, the squad party-joins it.
do
    local world, lobby, status, lines = setup(function(w) w.successor = T; w.arrivals = {T, w.local_peer, C} end)
    local counts = budget.wrap(world.api)
    local now = 100
    assert(lobby.promote(nil, now) == true)
    assert(world.count('kick_peer') == 1 and world.last('kick_peer')[2] == Fake.key(T), 'the game kick')
    assert(status.lobby == 'promote: Tango returns to their ship', status.lobby)
    -- Waiting for the successor's lobby: direct loads only, no searches before FIRST_SEARCH.
    world.tick(); now = now + DT; lobby.step(now)
    assert(lobby.job().step == 'search')
    local frame = budget.frame(counts, function() world.tick(); now = now + DT; return lobby.step(now) end)
    budget.check(frame, {load8 = 1, load32 = 15, load64 = 2}, 'promote waiting frame')
    assert(world.count('browser_start') == 0)
    now = run(world, lobby, now, math.ceil(L.FIRST_SEARCH / DT) + 1, function(w) return w.count('browser_start') > 0 end)
    local filter = world.last('filter_string')
    assert(world.count('clear_filters') == 1 and filter[2] == G.KEY_HOST_PEER and filter[4] == G.OP_EQUAL)
    assert(filter[3] == '72057594037927941', 'successor id in decimal: ' .. tostring(filter[3]))
    now = run(world, lobby, now, 20, function(w) return w.count('start_join') > 0 end)
    local join = world.last('start_join')
    assert(join[1] == Fake.CTX + G.JOIN and join[2] == 'connection-string-of-successor' and join[3] == G.JOIN_PARTY
        and join[4] == 0 and join[5] == G.JOIN_REASON_QUICKPLAY, 'party join with the result info')
    assert(status.lobby == 'promote: moving the squad to Tango')
    now = run(world, lobby, now, 30, idle(lobby))
    assert(not lobby.busy() and status.lobby:find('^squad moved to Tango\'s ship %(kicked in 0%.0 s, lobby found 0%.[5-7] s '
        .. 'later, joined in 0%.%d s%)$'), status.lobby)
    assert(status.actions == 1)
    assert(joined(lines):find('promote: successor Tango (100000000000005, player 2)\n', 1, true), joined(lines))
    -- ARRIVAL_CHECK s after the move, once: how many of the squad are in Tango's session. Nothing is
    -- read before it is due.
    local moved = now
    assert(lobby.arrival and lobby.arrival.due > moved, 'the check is scheduled')
    frame = budget.frame(counts, lobby.check_arrival, moved + L.ARRIVAL_CHECK - 1)
    budget.check(frame, {}, 'before the arrival check')
    assert(lobby.arrival, 'still pending')
    frame = budget.frame(counts, lobby.check_arrival, moved + L.ARRIVAL_CHECK)
    budget.check(frame, {load8 = 1, load32 = 18, load64 = 2}, 'the arrival check (a snapshot of 3 players)')
    assert(lobby.arrival == nil and joined(lines):find("promote: 3 of 3 players in Tango's session 15 s after the "
        .. 'move', 1, true), joined(lines))
    lobby.check_arrival(moved + 100)
    assert(not joined(lines):find('move\n.*move$'), 'logged once')
end
do -- A member who stayed behind is counted; a host who left the new session is told so.
    local world, lobby, _, lines = setup(function(w) w.successor = T; w.arrivals = {T, w.local_peer} end)
    local now = run(world, lobby, 0, 1)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, 600, idle(lobby))
    lobby.check_arrival(now + L.ARRIVAL_CHECK)
    assert(joined(lines):find("promote: 2 of 3 players in Tango's session", 1, true), joined(lines))
    world, lobby, _, lines = setup(function(w) w.successor = T end)
    now = run(world, lobby, 0, 1)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, 600, idle(lobby))
    world.host = world.local_peer
    world.sync()
    lobby.check_arrival(now + L.ARRIVAL_CHECK)
    assert(joined(lines):find("promote: no longer in Tango's session 15 s after the move", 1, true), joined(lines))
end
print('PASS: ship promote kicks the successor home, finds its lobby by host id, party-joins it and stays; 15 s after '
    .. 'the move one log line says how many of the squad arrived, with no reads before then')

-- Diagnostic builds: every search is logged, with why one waits; the first
-- looks for the host's own lobby (a control that never joins).
do
    local world, lobby, _, lines = setup(function(w) w.successor = T end)
    lobby.verbose, lobby.control_search = true, true
    local now = 100
    lobby.promote(nil, now)
    world.requests = {G.REQUEST_SEARCHING, 0}
    world.sync()
    now = run(world, lobby, now, math.ceil((L.FIRST_SEARCH + 1) / DT))
    assert(world.count('browser_start') == 0 and joined(lines):find('promote: search waits (a game search is running)',
        1, true), joined(lines))
    world.requests = {0, 0}
    world.sync()
    now = run(world, lobby, now, 60, function(w) return w.count('start_join') > 0 end)
    local text = joined(lines)
    local own = world.api.u64_decimal(world.local_peer.lo, world.local_peer.hi)
    assert(text:find('promote: search for your own lobby (control) (string_key2 eq ' .. own .. ')', 1, true), text)
    assert(text:find('promote: control search: 1 result(s), first lobby own-lobby (has a connection string)', 1, true),
        text)
    assert(text:find('promote: search 1 for Tango\'s lobby (string_key2 eq 72057594037927941)', 1, true), text)
    assert(text:find('promote: successor search: 1 result(s), first lobby lobby-0', 1, true), text)
    assert(world.count('start_join') == 1 and world.count('browser_start') == 2, 'the control search never joins')
    -- An unlisted own lobby reads 0 results.
    world, lobby, _, lines = setup(function(w) w.successor = T; w.own_lobby_unlisted = true end)
    lobby.verbose, lobby.control_search = true, true
    lobby.promote(nil, 0)
    run(world, lobby, 0, math.ceil((L.FIRST_SEARCH + 2) / DT), function(w) return w.count('start_join') > 0 end)
    assert(joined(lines):find('promote: control search: 0 result(s)', 1, true), joined(lines))
end
print('PASS: diagnostic builds log every successor search, why it waits and what it returned, after a control search '
    .. 'for the host\'s own lobby')

-- Retries: the lobby appears on the third search, searches spaced by SEARCH_INTERVAL.
do
    local world, lobby = setup(function(w) w.successor = T; w.lobby_after = 3 end)
    local now = 0
    assert(lobby.promote(nil, now))
    local starts = {}
    for _ = 1, math.ceil((L.FIRST_SEARCH + 4 * L.SEARCH_INTERVAL) / DT) do
        local before = world.count('browser_start')
        world.tick(); now = now + DT; lobby.step(now)
        if world.count('browser_start') > before then starts[#starts + 1] = now end
        if world.count('start_join') > 0 then break end
    end
    assert(#starts == 3 and world.count('start_join') == 1, #starts)
    assert(math.abs((starts[2] - starts[1]) - L.SEARCH_INTERVAL) < 0.2 and math.abs((starts[3] - starts[2]) - L.SEARCH_INTERVAL) < 0.2)
end
-- Never found: fails after SEARCH_TIMEOUT with a bounded number of searches.
do
    local world, lobby, status = setup(function(w) w.successor = T; w.lobby_after = 1e9 end)
    local now = run(world, lobby, 0, 0)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, math.ceil((L.SEARCH_TIMEOUT + 20) / DT), idle(lobby))
    assert(status.lobby == 'promote failed: Tango\'s lobby was not found', status.lobby)
    -- Once a second for the first L.FAST_SEARCHES seconds, then every L.SLOW_SEARCH_INTERVAL.
    local fast = math.ceil((L.FAST_SEARCHES - L.FIRST_SEARCH) / L.SEARCH_INTERVAL)
    local limit = fast + math.ceil((L.SEARCH_TIMEOUT - L.FAST_SEARCHES) / L.SLOW_SEARCH_INTERVAL) + 1
    local count = world.count('browser_start')
    assert(count <= limit and count >= limit - 4 and world.count('start_join') == 0, count .. ' of at most ' .. limit)
end
print('PASS: lobby searches start ' .. L.FIRST_SEARCH .. ' s after the successor left, retry every '
    .. L.SEARCH_INTERVAL .. ' s for ' .. L.FAST_SEARCHES .. ' s, then every ' .. L.SLOW_SEARCH_INTERVAL
    .. ' s, and give up after ' .. L.SEARCH_TIMEOUT .. ' s')

-- The game's own searches come first: no search while a request searches or the browser is busy.
do
    local world, lobby = setup(function(w) w.successor = T; w.requests = {0, 1} end)
    local now = 0
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, math.ceil((L.FIRST_SEARCH + 3) / DT))
    assert(world.count('browser_start') == 0 and world.count('clear_filters') == 0, 'waits for the scanner')
    world.requests = {0, 0}
    world.browser.busy = 1e9
    now = run(world, lobby, now, 60)
    assert(world.count('browser_start') == 0, 'waits for a busy browser')
    world.browser.busy = 0
    now = run(world, lobby, now, 60, function(w) return w.count('browser_start') > 0 end)
    assert(world.count('browser_start') == 1)
end
print('PASS: the successor search never overlaps a game search (quickplay, scanner or a busy browser)')

-- Failures: refused party join, a successor that stays, an empty result, a refused start, a lost session.
do
    local world, lobby, status = setup(function(w) w.successor = T; w.join_outcome = 'refused' end)
    local now = run(world, lobby, 0, 0)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, 3000, idle(lobby))
    assert(status.lobby == 'promote failed: Tango\'s game refused the squad (privacy or room)', status.lobby)
end
do
    local world, lobby, status = setup(function(w) w.keep_removed = true end)
    local now = run(world, lobby, 0, 0)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, math.ceil((L.GONE_TIMEOUT + 1) / DT), idle(lobby))
    assert(status.lobby == 'promote failed: Tango is still in the session', status.lobby)
end
do
    local world, lobby, status = setup(function(w) w.successor = T; w.empty_connection = true; w.lobby_after = 1 end)
    local now = run(world, lobby, 0, 0)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, math.ceil((L.FIRST_SEARCH + 2 * L.SEARCH_INTERVAL + 1) / DT))
    assert(world.count('start_join') == 0 and world.count('browser_start') >= 2, 'a result without a connection string is skipped')
end
do
    local world, lobby, status = setup(function(w) w.successor = T; w.join_refuses_start = true end)
    local now = run(world, lobby, 0, 0)
    assert(lobby.promote(nil, now))
    now = run(world, lobby, now, 2000, idle(lobby))
    assert(status.lobby == 'promote failed: the game refused to start the party join', status.lobby)
end
do
    local world, lobby, status = setup(function(w) w.successor = T end)
    local now = run(world, lobby, 0, 0)
    assert(lobby.promote(nil, now))
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    lobby.step(now + DT)
    assert(not lobby.busy() and status.lobby == 'promote failed: network session lost', status.lobby)
end
do
    local world, lobby, status = setup(function(w) w.successor = T end)
    assert(lobby.promote(nil, 0))
    local ok, why = lobby.disband('remove')
    assert(ok == false and why == 'another action is running (promote)')
    assert(lobby.cancel('test') == true and not lobby.busy() and status.lobby == 'promote failed: cancelled: test')
    assert(lobby.cancel('again') == false, 'nothing left to cancel')
end
print('PASS: refused joins, successors that stay, empty results, refused starts, lost sessions and overlaps fail cleanly')

-- Off the ship: promote is refused; nothing is kicked.
do
    for _, mode in ipairs({G.MODE_MISSION, 7}) do
        local world, lobby, status = setup(function(w) w.mode = mode end)
        local ok, why = lobby.promote(nil, 0)
        assert(ok == false and why == 'only on the ship' and world.count('kick_peer') == 0, tostring(why))
        assert(status.lobby == 'promote refused: only on the ship', status.lobby)
    end
end
print('PASS: promote is refused in a mission or any other mode')
