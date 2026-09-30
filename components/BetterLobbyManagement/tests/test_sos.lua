-- CANCEL SOS (src/sos.lua) against a simulated SOS system and lobby wrapper:
-- refusals on changed code; the offer's cost (nothing on the ship); the
-- cancel's gates, its one native call and the lobby posted in the same frame;
-- the cancel kept through the game's re-arms (a player leaving), including a
-- re-arm that already reached PlayFab; a new beacon, the beacon gone, the
-- mission's end, a new SOS object and a lost host end it. Exact calls per frame.
-- Usage: test_sos.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local B = dofile(source .. '/sos.lua')
local Text = dofile(source .. '/bingus_text.lua')
Text.registry().game_language = 'en'
local tr = Text.new(dofile(source .. '/../locales/en.lua'))
local TANGO, CHARLIE = Fake.peer(0x01000000, 0x00000005), Fake.peer(0x0a000000, 0x00000007)

local function setup(configure)
    local world = Fake.new({G = G})
    Fake.install_sos(world, B, G)
    world.mode = G.MODE_MISSION
    world.sync()
    if configure then configure(world) end
    local status, lines = {}, {}
    local sos = B.new(world.api, Fake.GAME, G, status, function(line) lines[#lines + 1] = line end)
    return world, sos, status, lines
end
local function snapshot(world)
    return G.read_session(world.api, Fake.GAME, Fake.CTX, G.new_snapshot())
end
local function logged(lines, text)
    for _, line in ipairs(lines) do if line:find(text, 1, true) then return true end end
    return false
end

-- Startup refusals: the native and every code check.
do
    local world, sos = setup(function(w) w.changed = Fake.GAME + B.DEACTIVATE.rva end)
    local ok, why = sos.verify()
    assert(ok == false and why == 'SOS deactivate changed', why)
    world, sos = setup(function(w) w.changed = Fake.GAME + B.SET_KEY.rva end)
    ok, why = sos.verify()
    assert(ok == false and why == 'lobby number setter changed', why)
    for _, code in ipairs(B.CODE) do
        world, sos = setup(function(w) w.changed = Fake.GAME + code.rva end)
        ok, why = sos.verify()
        assert(ok == false and why == code.name .. ' changed', why)
    end
    world, sos = setup()
    assert(sos.verify())
    ok, why = sos.cancel(0)
    assert(ok == false and why == 'no SOS is on', why)
end
print('PASS: CANCEL SOS refuses to start when the game\'s SOS off, its key setter or any of the ' .. #B.CODE
    .. ' code checks changed')

-- The dialog text for each privacy setting: short enough for the dialog box.
do
    assert(B.body(0, tr) == 'Stops your SOS, also when a slot opens. Quickplay still finds your Public lobby. You can '
        .. 'call in the SOS Beacon again.', B.body(0, tr))
    assert(B.body(1, tr):find('returns to Friends Only. You can', 1, true)
        and B.body(2, tr):find('returns to Invite Only.', 1, true)
        and B.body(3, tr):find('returns to Friends and Clan.', 1, true)
        and B.body(9, tr):find('returns to its privacy setting.', 1, true))
    for privacy = 0, 9 do assert(#B.body(privacy, tr) <= 120, #B.body(privacy, tr)) end
end
print('PASS: the dialog names the privacy setting the lobby returns to (Public: Quickplay still finds it) and says the '
    .. 'SOS Beacon can be called in again, within 120 bytes')

-- The offer: nothing on the ship or as a client; two loads while no SOS is on;
-- the privacy setting while one is.
do
    local world, sos = setup()
    assert(sos.verify())
    local counts = budget.wrap(world.api)
    local snap = snapshot(world)
    local f, offered = budget.frame(counts, sos.offer, snap)
    assert(offered == false)
    budget.check(f, {load64 = 1, load8 = 1, read32 = 1}, 'first look: the SOS object confirmed once')
    f, offered = budget.frame(counts, sos.offer, snap)
    assert(offered == false)
    budget.check(f, {load64 = 1, load8 = 1}, 'mission, no SOS')
    world.sos_beacon()
    f, offered = budget.frame(counts, sos.offer, snapshot(world))
    assert(offered == 1, tostring(offered))
    budget.check(f, {load64 = 2, load8 = 1, load32 = 1}, 'mission, SOS on: the privacy setting')
    world.privacy = 0
    world.sync()
    assert(sos.offer(snapshot(world)) == 0, 'Public is offered too (0 is a value)')
    world.mode = G.MODE_SHIP
    world.sync()
    f, offered = budget.frame(counts, sos.offer, snapshot(world))
    assert(offered == false and next(f) == nil, 'the ship: no loads at all ' .. budget.describe(f))
    world.mode = G.MODE_MISSION
    world.host = TANGO
    world.sync()
    f, offered = budget.frame(counts, sos.offer, snapshot(world))
    assert(offered == false and next(f) == nil, 'a client: no loads at all')
    world.host = world.local_peer
    world.transition = 2
    world.sync()
    assert(sos.offer(snapshot(world)) == false, 'not during a transition')
    world.transition = 0
    world.put64(Fake.GAME + B.SOS_PTR, 0)
    world.sync()
    assert(sos.offer(snapshot(world)) == false, 'no SOS system')
    assert(world.count('sos_deactivate') == 0)
end
print('PASS: CANCEL SOS is offered only to a host in a mission with an SOS on: no loads on the ship or as a client, '
    .. 'two while no SOS is on')

-- Why the mod sets key 19 itself: the game's own SOS off (here, the squad
-- filling up) keeps the lobby Public while PlayFab still shows the SOS.
do
    local world = setup()
    world.session = {world.local_peer, TANGO, CHARLIE}
    world.sync()
    world.sos_beacon()
    for _ = 1, 2000 do world.lobby_update() end
    world.player_joins(Fake.peer(0x0b000000, 9)) -- four players: the game switches the SOS off
    assert(world.sos.active == 0 and world.key(B.KEY_SOS) == '0' and world.key(B.KEY_PRIVACY) == '0',
        'SOS off, the lobby still Public')
end
print('PASS: the game\'s own SOS off leaves the lobby Public while PlayFab still shows the SOS (vanilla, a full squad)')

-- Cancel: the game's own SOS off, and the lobby posted in this frame's update.
do
    local world, sos, status, lines = setup()
    assert(sos.verify())
    world.session = {world.local_peer, TANGO}
    world.sync()
    world.sos_beacon()
    assert(world.sos_uses() == 0, 'the call-in spent the SOS Beacon\'s one use')
    for _ = 1, 2000 do world.lobby_update() end -- the SOS reached PlayFab (a post every 30 s)
    assert(world.playfab[B.KEY_SOS] == '1' and world.playfab[B.KEY_PRIVACY] == '0', 'SOS lobbies are Public')
    local counts = budget.wrap(world.api)
    local f, ok = budget.frame(counts, sos.cancel, 12)
    assert(ok == true)
    print('INFO: cancel frame: ' .. budget.describe(f))
    -- The first use: the session, the SOS object, the stratagem settings and
    -- the player records are confirmed with guarded reads.
    budget.check(f, {load64 = 7, load32 = 23, load8 = 2, read32 = 8, cstring = 4, writable_data = 2, write32 = 1,
        write_f32 = 1}, 'the cancel frame: two native calls, two checked writes')
    assert(world.count('sos_deactivate') == 1 and world.last('sos_deactivate')[1] == Fake.SOS)
    local set = world.last('lobby_set')
    assert(set and set[1] == B.KEY_PRIVACY and set[2] == 1, 'then key 19 = Friends Only, with the game\'s key setter')
    assert(world.key(B.KEY_SOS) == '0' and world.key(B.KEY_PRIVACY) == '1', 'the lobby is Friends Only again')
    assert(world.api.loadf(world.lobby + B.COUNTDOWN) == 0, 'the lobby posts in this frame\'s update')
    assert(world.sos_uses() == 1, 'the SOS Beacon has its use back')
    world.lobby_update()
    assert(world.playfab[B.KEY_SOS] == '0' and world.playfab[B.KEY_PRIVACY] == '1', 'PlayFab has it at once')
    assert(sos.cancelled() and status.sos_cancels == 1)
    assert(logged(lines, 'SOS cancelled: lobby SOS flag 1, privacy 0 -> SOS flag 0, privacy 1 (privacy setting Friends '
        .. 'Only); posted in this frame; SOS Beacon uses 0 -> 1'), lines[#lines])
    -- A refused write still cancels; the post then comes with the next lobby update.
    world, sos, status, lines = setup()
    assert(sos.verify())
    world.sos_beacon()
    world.readonly = true
    assert(sos.cancel(1))
    assert(world.key(B.KEY_SOS) == '0' and logged(lines, 'the write was refused; posted at the next lobby update; '
        .. 'SOS Beacon use: the write was refused') and world.sos_uses() == 0, lines[#lines])
end
print('PASS: the cancel calls the game\'s own SOS off and its key setter once each (key 8 off, the privacy setting '
    .. 'back), has the game post the lobby in the same frame and gives the SOS Beacon its use back, with two checked '
    .. 'writes')

-- The use comes back only as the stratagem allows: never above its uses per
-- mission, not for a limitless or shared stratagem, only in the host's own
-- record and slot; the cancel works either way.
do
    local function cancelled_with(configure)
        local world, sos, _, lines = setup()
        assert(sos.verify())
        world.sos_beacon()
        configure(world)
        local queries = world.api.queries
        assert(sos.cancel(3))
        return world, lines[#lines], world.api.queries - queries
    end
    local world, line, writes = cancelled_with(function(w) w.put32(w.sos_slot + B.SLOT_USES, 1) end)
    assert(line:find('; SOS Beacon uses already 1$') and world.sos_uses() == 1 and writes == 1, line)
    world, line, writes = cancelled_with(function(w) w.put32(Fake.SOS_SETTINGS + B.STRATAGEM_USES, B.NO_LIMIT) end)
    assert(line:find('; the SOS Beacon has no use limit$') and world.sos_uses() == 0 and writes == 1, line)
    world, line = cancelled_with(function(w) w.put32(Fake.SOS_SETTINGS + B.STRATAGEM_SHARED, 1) end)
    assert(line:find('uses are shared; not restored$') and world.sos_uses() == 0, line)
    world, line = cancelled_with(function(w) w.put32(Fake.SOS_SETTINGS, 0x92) end)
    assert(line:find('; SOS Beacon settings unreadable$') and world.sos_uses() == 0, line)
    world, line = cancelled_with(function(w) w.put32(w.sos_slot, 0x92) end)
    assert(line:find('; no SOS Beacon slot$'), line)
    world, line = cancelled_with(function(w) w.put32(Fake.PLAYERS, 7) end)
    assert(line:find('; no player record of yours$') and world.sos_uses() == 0, line)
    world, line = cancelled_with(function(w) w.unmapped[Fake.PLAYERS + B.PLAYER_COUNT] = true end)
    assert(line:find('; player records unreadable$'), line)
    -- A limit of 3 with none left: one back, not all three.
    world, line = cancelled_with(function(w)
        w.put32(Fake.SOS_SETTINGS + B.STRATAGEM_USES, 3)
        w.put32(w.sos_slot + B.SLOT_USES, 0)
    end)
    assert(line:sub(-24) == '; SOS Beacon uses 0 -> 1' and world.sos_uses() == 1, line)
end
print('PASS: the SOS Beacon\'s use comes back only up to its uses per mission, never for a limitless or shared '
    .. 'stratagem or another player\'s record, and the cancel works whatever the stratagem data says')

-- Calling the SOS Beacon in again after a cancel: the game spends the use,
-- lists the lobby again, and the mod no longer keeps the SOS off.
do
    local world, sos, _, lines = setup()
    assert(sos.verify())
    world.session = {world.local_peer, TANGO}
    world.sync()
    world.sos_beacon()
    assert(sos.cancel(0) and world.sos_uses() == 1)
    world.sos_beacon() -- a second beacon: the use spent again, the SOS on
    assert(world.sos_uses() == 0 and world.sos.enabled == 2 and world.sos.active == 1 and world.key(B.KEY_SOS) == '1')
    sos.keep(40)
    assert(not sos.cancelled() and world.count('sos_deactivate') == 1, 'the new SOS stays on')
    assert(logged(lines, 'SOS: no longer kept off after 40 s (a new SOS beacon was called in)'))
    -- And it can be cancelled again, which gives the use back again.
    assert(sos.cancel(50) and world.sos.active == 0 and world.sos_uses() == 1 and sos.cancelled())
end
print('PASS: after a cancel the SOS Beacon can be called in again: the new SOS lists, the mod lets it, and a second '
    .. 'cancel stops it and gives the use back again')

-- Gates: each refusal calls nothing and writes nothing.
do
    local cases = {
        {'not hosting', function(w) w.host = TANGO; w.session = {TANGO, w.local_peer} end},
        {'not hosting', function(w) w.hosting = 2 end},
        {'not in a mission', function(w) w.mode = G.MODE_SHIP end},
        {'a transition is running', function(w) w.transition = 1 end},
        {'no network session', function(w) w.put64(Fake.GAME + G.CONTEXT_PTR, 0) end},
    }
    for _, case in ipairs(cases) do
        local world, sos, _, lines = setup()
        assert(sos.verify())
        world.sos_beacon()
        case[2](world)
        world.sync()
        if case[1] == 'no network session' then world.put64(Fake.GAME + G.CONTEXT_PTR, 0) end
        local ok, why = sos.cancel(0)
        assert(ok == false and why == case[1], tostring(why))
        assert(world.count('sos_deactivate') == 0 and world.api.queries == 0 and not sos.cancelled())
        assert(lines[#lines] == 'cancel SOS refused: ' .. case[1], lines[#lines])
    end
end
print('PASS: the cancel refuses, calling and writing nothing, when not hosting, not in a mission, during a transition, '
    .. 'without a session or without an SOS')

-- Kept off: the game re-arms it when a player leaves; the mod turns it off
-- again in the next frame, before the lobby posts it.
do
    local world, sos, status, lines = setup()
    assert(sos.verify())
    world.session = {world.local_peer, TANGO, CHARLIE}
    world.sync()
    world.sos_beacon()
    assert(sos.cancel(0))
    world.lobby_update() -- the cancel's post
    local counts = budget.wrap(world.api)
    for i = 1, 300 do
        local f = budget.frame(counts, sos.keep, i)
        budget.check(f, {load64 = 3, load32 = 2, load8 = 1}, 'kept, nothing changing ' .. i)
    end
    local posts = world.count('lobby_post')
    world.player_leaves(CHARLIE) -- the game's re-arm, in the game's update
    assert(world.sos.active == 1 and world.key(B.KEY_SOS) == '1', 're-armed')
    world.lobby_update() -- the rest of that update: the countdown is far from 0, nothing posted
    local f = budget.frame(counts, sos.keep, 400)
    budget.check(f, {load64 = 4, load32 = 8, load8 = 1}, 'a re-arm caught: loads only')
    assert(world.count('sos_deactivate') == 2 and world.key(B.KEY_SOS) == '0' and world.sos.active == 0)
    for _ = 1, 2000 do world.lobby_update() end
    assert(world.count('lobby_post') == posts + 1 and world.playfab[B.KEY_SOS] == '0',
        'the next post carries the cancel again: PlayFab never saw the re-arm')
    assert(status.sos_rearms == 1 and status.sos_leaks == 0 and world.api.queries == 2,
        'the cancel\'s two checked writes, none for a caught re-arm')
    assert(logged(lines, 'SOS: the game listed it again (a player left or a new host); cancelled again'))
    -- A re-arm that the lobby posted in the same update: corrected in the next frame.
    world.player_joins(CHARLIE)
    world.player_leaves(CHARLIE)
    world.putf(world.lobby + B.COUNTDOWN, 0.001)
    world.lobby_update()
    assert(world.playfab[B.KEY_SOS] == '1', 'the leak: PlayFab has the re-arm')
    f = budget.frame(counts, sos.keep, 500)
    budget.check(f, {load64 = 4, load32 = 8, load8 = 1, writable_data = 1, write_f32 = 1}, 'a posted re-arm')
    world.lobby_update()
    assert(world.playfab[B.KEY_SOS] == '0' and world.playfab[B.KEY_PRIVACY] == '1', 'corrected in the same frame')
    assert(status.sos_rearms == 2 and status.sos_leaks == 1)
    assert(logged(lines, 'the lobby had already posted it, posted again in this frame'))
end
print('PASS: a cancel is kept for 6 loads a frame; the game\'s re-arm after a leave is turned off in the next frame, '
    .. 'before the lobby posts it, and a re-arm the lobby already posted is posted again at once')

-- What ends a kept cancel.
do
    local function kept(configure)
        local world, sos, status, lines = setup()
        assert(sos.verify())
        world.session = {world.local_peer, TANGO}
        world.sync()
        world.sos_beacon()
        assert(sos.cancel(0) and sos.cancelled())
        configure(world)
        world.sync()
        sos.keep(5)
        return world, sos, lines
    end
    local world, sos, lines = kept(function(w) w.sos_beacon() end)
    assert(not sos.cancelled() and world.sos.active == 1 and world.count('sos_deactivate') == 1,
        'a new beacon lists again')
    assert(logged(lines, 'SOS: no longer kept off after 5 s (a new SOS beacon was called in)'), lines[#lines])
    world, sos, lines = kept(function(w) w.sos.enabled = 0 end)
    assert(not sos.cancelled() and logged(lines, '(no SOS beacon left)'))
    world, sos, lines = kept(function(w) w.mode = G.MODE_SHIP end)
    assert(not sos.cancelled() and logged(lines, '(the mission ended)'))
    world, sos, lines = kept(function(w) w.put64(Fake.GAME + B.SOS_PTR, Fake.SOS + 0x1000) end)
    assert(not sos.cancelled() and logged(lines, '(new session or mission)'))
    world, sos, lines = kept(function(w) w.put64(Fake.GAME + G.CONTEXT_PTR, 0) end)
    assert(not sos.cancelled() and logged(lines, '(new session or mission)'))
    world, sos, lines = kept(function(w) w.host = TANGO; w.sos.active = 1 end)
    assert(not sos.cancelled() and logged(lines, '(no longer the host)') and world.count('sos_deactivate') == 1)
    -- One of two beacons gone: the lower count is remembered, and a re-arm is still caught.
    world, sos = setup()
    assert(sos.verify())
    world.sos_beacon(); world.sos_beacon()
    assert(sos.cancel(0))
    world.sos.enabled = 1
    world.sync()
    sos.keep(1)
    assert(sos.cancelled(), 'a beacon gone, one left: still kept')
    world.sos_on() -- the game's re-arm
    sos.keep(2)
    assert(sos.cancelled() and world.count('sos_deactivate') == 2 and world.sos.active == 0)
end
print('PASS: a kept cancel ends with a new beacon (it lists again), no beacon left, the mission\'s end, a new session '
    .. 'or SOS object and a lost host; one of two beacons gone keeps it')
