-- Game layout (src/game.lua): binding the natives refuses on any changed
-- code, missing engine table, slot, DLL or export; the context is confirmed
-- once with guarded reads and then read with direct loads; the session reader,
-- names, PlayFab lobby and matchmaking checks read what the game holds.
-- Usage: test_game.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')

local function refusal(world)
    local ok, why = pcall(G.bind, world.api, Fake.GAME, Fake.EXE)
    assert(not ok, 'bind must refuse')
    return why
end

-- Binding: every native, engine slot and export.
do
    local world = Fake.new({G = G})
    local natives = G.bind(world.api, Fake.GAME, Fake.EXE)
    local expected = {'kick_peer', 'send_kick', 'start_join', 'filter_string', 'browser_start', 'browser_busy',
                      'browser_count', 'browser_result', 'is_friend', 'clear_filters', 'continent', 'unload_paused',
                      'pause_unloads'}
    for _, name in ipairs(expected) do assert(type(natives[name]) == 'function', name) end
    assert(natives.remove_peer == nil and G.NATIVES.remove_peer == nil, 'remove_peer is never bound')
    assert(natives.leave == nil and G.PLAYFAB_EXPORTS == nil, 'no leave, no PlayFab exports (HAND OVER is gone)')
    assert(natives.lobby_api == Fake.LOBBY_API)
    local count = 0
    for _ in pairs(natives) do count = count + 1 end
    assert(count == #expected + 1, 'nothing else is bound')
end
-- Refusals, each with its reason.
do
    for _, code in ipairs(G.CODE) do
        local world = Fake.new({G = G})
        world.changed = Fake.GAME + code.rva
        assert(refusal(world) == code.name .. ' changed')
    end
    for _, code in ipairs(G.EXE_CODE) do
        local world = Fake.new({G = G})
        world.changed = Fake.EXE + code.rva
        assert(refusal(world) == code.name .. ' changed')
    end
    for name, native in pairs(G.NATIVES) do
        local world = Fake.new({G = G})
        world.changed = Fake.GAME + native.rva
        assert(refusal(world) == name .. ' changed')
    end
    local world = Fake.new({G = G})
    world.put64(Fake.GAME + G.ENGINE_API_PTR, 0)
    assert(refusal(world) == 'engine API unavailable')
    world = Fake.new({G = G})
    world.put64(Fake.TABLES + G.LOBBY_API, 0)
    assert(refusal(world) == 'engine lobby API unavailable')
    for name, slot in pairs(G.ENGINE_SLOTS) do
        world = Fake.new({G = G})
        world.changed = world.get64(Fake.LOBBY_API + slot.slot)
        assert(refusal(world) == 'engine ' .. name .. ' changed')
        world = Fake.new({G = G})
        world.put64(Fake.LOBBY_API + slot.slot, 0)
        assert(refusal(world) == 'engine ' .. name .. ' changed')
    end
    world = Fake.new({G = G})
    world.put64(Fake.TABLES + G.PACKAGE_API, 0)
    assert(refusal(world) == 'engine package API unavailable')
    for name, slot in pairs(G.PACKAGE_SLOTS) do
        world = Fake.new({G = G})
        world.changed = world.get64(Fake.PACKAGE_API + slot.slot)
        assert(refusal(world) == 'engine ' .. name .. ' changed')
        world = Fake.new({G = G})
        world.put64(Fake.PACKAGE_API + slot.slot, 0)
        assert(refusal(world) == 'engine ' .. name .. ' changed')
    end
    world = Fake.new({G = G})
    world.no_playfab = true
    assert(G.bind(world.api, Fake.GAME, Fake.EXE), 'the PlayFab DLL is not needed')
end
print('PASS: binding checks ' .. #G.CODE .. ' game.dll and ' .. #G.EXE_CODE .. ' exe signatures, every native, both '
    .. 'engine lobby slots and both package-unload slots, refusing with a plain reason')

-- Context: confirmed once with guarded reads, then direct loads only.
do
    local world = Fake.new({G = G})
    local counts = budget.wrap(world.api)
    local cache = {ctx = 0}
    local frame, ctx = budget.frame(counts, G.context, world.api, Fake.GAME, cache)
    assert(ctx == Fake.CTX and cache.ctx == Fake.CTX)
    budget.check(frame, {load64 = 2, read32 = 2}, 'first sight of a context')
    frame, ctx = budget.frame(counts, G.context, world.api, Fake.GAME, cache)
    assert(ctx == Fake.CTX)
    budget.check(frame, {load64 = 1}, 'known context')
    -- No context, then an unreadable, misaligned or stateless one.
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    frame, ctx = budget.frame(counts, G.context, world.api, Fake.GAME, cache)
    assert(ctx == 0 and cache.ctx == 0)
    budget.check(frame, {load64 = 1}, 'no context')
    world.put64(Fake.GAME + G.CONTEXT_PTR, Fake.CTX)
    world.unmapped[Fake.CTX + G.PEER_COUNT] = true
    assert(G.context(world.api, Fake.GAME, cache) == 0 and cache.ctx == 0)
    world.unmapped[Fake.CTX + G.PEER_COUNT] = nil
    world.put64(Fake.GAME + G.CONTEXT_PTR, Fake.CTX + 4)
    assert(G.context(world.api, Fake.GAME, cache) == 0)
    world.put64(Fake.GAME + G.CONTEXT_PTR, Fake.CTX)
    world.put64(Fake.GAME + G.GAME_STATE_PTR, 0)
    assert(G.context(world.api, Fake.GAME, cache) == 0)
    world.put64(Fake.GAME + G.GAME_STATE_PTR, Fake.STATE)
    assert(G.context(world.api, Fake.GAME, cache) == Fake.CTX)
end
print('PASS: the context is confirmed once with two guarded reads, then costs one load; bad contexts read as none')

-- Session reader.
do
    local world = Fake.new({G = G})
    local other, third = Fake.peer(0x0a000001, 0x2a1b3c4d), Fake.peer(0x0a000001, 0x00000007)
    world.session = {world.local_peer, other, third}
    world.host = other
    world.mode, world.hosting, world.transition, world.join_state, world.party_join = G.MODE_MISSION, 0, 2, 1, 1
    world.sync()
    local counts = budget.wrap(world.api)
    local snap = G.new_snapshot()
    local frame = budget.frame(counts, G.read_session, world.api, Fake.GAME, Fake.CTX, snap)
    budget.check(frame, {load8 = 1, load32 = 18, load64 = 1}, 'read_session, 3 peers')
    assert(snap.ctx == Fake.CTX and snap.peer_count == 3 and not snap.is_host)
    assert(snap.local_lo == world.local_peer.lo and snap.local_hi == world.local_peer.hi)
    assert(snap.host_lo == other.lo and snap.host_hi == other.hi)
    assert(snap.peers[2].lo == other.lo and snap.peers[2].hi == other.hi and snap.peers[3].index == 2)
    assert(snap.mode == G.MODE_MISSION and snap.hosting == 0 and snap.transition == 2)
    assert(snap.join_state == 1 and snap.party_join == 1)
    assert(G.has_peer(snap, third.lo, third.hi) and not G.has_peer(snap, 1, 2))
    -- The snapshot is reused: the same tables, no new ones.
    local peers = snap.peers
    world.session, world.host = {world.local_peer}, world.local_peer
    world.sync()
    G.read_session(world.api, Fake.GAME, Fake.CTX, snap)
    assert(snap.peers == peers and snap.peer_count == 1 and snap.is_host)
    assert(not G.has_peer(snap, other.lo, other.hi), 'stale entries past the count are ignored')
    -- A corrupt count is clamped to four.
    world.put32(Fake.CTX + G.PEER_COUNT, 1000)
    G.read_session(world.api, Fake.GAME, Fake.CTX, snap)
    assert(snap.peer_count == G.MAX_PEERS)
end
print('PASS: the session reader fills a reused snapshot (peers, host, mode, sync and join state) with direct loads')

-- Names, the PlayFab lobby and matchmaking.
do
    local world = Fake.new({G = G})
    local other = Fake.peer(0x0a000001, 0x2a1b3c4d)
    world.session = {world.local_peer, other}
    world.names[Fake.key(other)] = 'Tango'
    world.sync()
    local names = G.names(world.api, Fake.GAME)
    assert(names[G.peer_key(other.lo, other.hi)] == 'Tango' and names[Fake.key(world.local_peer)] == 'Diver1')
    assert(G.peer_key(0x2a1b3c4d, 0x0a000001) == '0A0000012A1B3C4D')
    world.unmapped[Fake.ROSTER] = true
    assert(next(G.names(world.api, Fake.GAME)) == nil, 'an unreadable roster gives no names')
    world.put64(Fake.GAME + G.ROSTER_PTR, 0)
    assert(next(G.names(world.api, Fake.GAME)) == nil)

    assert(G.playfab_lobby(world.api, Fake.CTX) == Fake.PLAYFAB_LOBBY)
    world.unmapped[Fake.PLAYFAB_LOBBY + G.PL_STATE] = true
    assert(G.playfab_lobby(world.api, Fake.CTX) == nil)
    world.put64(Fake.CTX + G.LOBBY, 0)
    assert(G.playfab_lobby(world.api, Fake.CTX) == nil)

    assert(G.game_searching(world.api, Fake.GAME) == false)
    world.requests = {G.REQUEST_SEARCHING, 0}
    world.sync()
    assert(G.game_searching(world.api, Fake.GAME) == true, 'quickplay searching')
    world.requests = {0, G.REQUEST_SEARCHING}
    world.sync()
    assert(G.game_searching(world.api, Fake.GAME) == true, 'scanner searching')
    world.requests = {0, 0}
    world.sync()
    world.unmapped[Fake.MATCH + G.REQUESTS[2] + 4] = true
    assert(G.game_searching(world.api, Fake.GAME) == true, 'an unreadable request counts as searching')
    world.put64(Fake.GAME + G.MATCHMAKING_PTR, 0)
    assert(G.game_searching(world.api, Fake.GAME) == false)
end
print('PASS: roster names by peer id, the PlayFab lobby behind the wrapper, and matchmaking state (unreadable = busy)')
