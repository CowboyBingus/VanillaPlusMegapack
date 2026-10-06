-- Offline tests on synthetic memory in this process; no game access.
-- luajit tests/test_hold.lua <src folder> <SHA-256 of this LuaJIT executable>
local source, executable_hash = assert(arg[1]), assert(arg[2])
local tests = arg[0]:match('^(.*)[/\\]') or '.'
local ffi = require('ffi')
local budget = dofile(tests .. '/frame_budget.lua')
local runtime = assert(loadfile(source .. '/bingus_runtime.lua'))()
local read_side = assert(loadfile(source .. '/bingus_memory.lua'))()
local memory = assert(loadfile(source .. '/bingus_write.lua'))().extend(read_side.new(runtime))
local create_api = assert(loadfile(source .. '/windows_api.lua'))()
local hold = assert(loadfile(source .. '/drop_hold.lua'))()
local install_loader = assert(loadfile(source .. '/archive_loader.lua'))()
local real = create_api(runtime, memory)
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

assert(not pcall(create_api) and not pcall(create_api, runtime), 'the adapter needs the memory api')
assert(not pcall(create_api, runtime, read_side.new(runtime)), 'the adapter needs the write side')
assert(real.module_hash(real.module(nil)) == executable_hash)
do
    local probe = ffi.new('uint32_t[2]', 0x12345678, 0x9abcdef0)
    local into = ffi.new('uint32_t[2]')
    local at, to = tonumber(ffi.cast('uintptr_t', probe)), tonumber(ffi.cast('uintptr_t', into))
    assert(real.read_to(at, 8, to) and into[0] == 0x12345678 and into[1] == 0x9abcdef0)
    assert(not real.read_to(1, 8, to) and not real.read_to(at, 8, 1))
    assert(not real.write_batch(real.address(real.module(nil)), 1, {{0, '\0'}}), 'module pages are refused')
end
pass('adapter: plain-number reads, module pages refused, module hash')

-- Synthetic memory ------------------------------------------------------------------

local keep = {}
local function alloc(size)
    local data = ffi.new('uint8_t[?]', size)
    keep[#keep + 1] = data
    return tonumber(ffi.cast('uintptr_t', data))
end
-- Stores into the test's own allocations only.
local function put_u32(address, value) ffi.cast('uint32_t *', address)[0] = value end  -- lint-ok: R3 test memory only
local function put_f32(address, value) ffi.cast('float *', address)[0] = value end  -- lint-ok: R3 test memory only
local function get_u32(address) return ffi.cast('uint32_t *', address)[0] end
local function get_f32(address) return ffi.cast('float *', address)[0] end
local function put_pointer(address, value)
    put_u32(address, value % 4294967296); put_u32(address + 4, math.floor(value / 4294967296))
end
local function bytes_of(address, size) return ffi.string(ffi.cast('void *', address), size) end
local function copy(to, from, size) ffi.copy(ffi.cast('void *', to), ffi.cast('void *', from), size) end

local CAPACITY = 32
local INITIAL = {low = 0x1928D3E2, high = 0xE58163E7}
local REINFORCE = {low = 0xA9D6D849, high = 0xEF9EB729}
local PAYLOAD = {low = 0x4E7C9A50, high = 0xFBE75EC4}

-- The world: the three game.dll globals answer through slots, everything else is real memory.
local world = {}
local function new_world()
    local w = {slots = {}, next_id = 100}
    -- A global's value lives in an 8-byte buffer, so answering a read allocates nothing.
    function w.slot(address, value)
        local cell = alloc(8)
        put_pointer(cell, value)
        w.slots[address] = value ~= 0 and cell or false
    end
    w.game = alloc(16)
    w.object = alloc(hold.state_offset + 4)                    -- the game object, with the game state at +0xAC21C
    w.scenes = alloc(hold.scene_offset + 8)                    -- the cutscene manager: current and queued scene
    w.session = alloc(hold.hotjoin_offset + 2)                 -- the session object: client state, hotjoin flags
    w.ui = alloc(0x429C + 32)
    w.manager = alloc(128)
    w.records = alloc(8 * CAPACITY)
    w.locals = alloc(160 * CAPACITY)
    w.nets = alloc(20 * CAPACITY)
    w.owner = alloc(16)
    w.table = alloc(256 + 104 * 8)
    w.slot(w.game + hold.game_rva, w.object)
    w.slot(w.game + hold.cutscene_rva, w.scenes)
    w.slot(w.game + hold.session_rva, w.session)
    w.slot(w.game + hold.ui_state_rva, w.ui)
    w.slot(w.game + hold.manager_rva, w.manager)
    put_u32(w.object + hold.state_offset, 4)                    -- in a mission
    w.slot(w.game + hold.settings_rva, w.owner)
    w.slot(w.owner + hold.settings_table_offset, w.table)
    put_u32(w.manager + 36, 128)                                -- capacity
    w.map = alloc(8 * 64)                                       -- the entity-id map: 64 slots of key, index
    put_pointer(w.manager + 64, w.map)
    put_u32(w.manager + 72, 64); put_u32(w.manager + 76, 0xFFFFFFFF); put_u32(w.manager + 80, 2654435761)
    for slot = 0, 63 do put_u32(w.map + slot * 8, 0xFFFFFFFF) end
    put_pointer(w.manager + 88, w.records)
    put_pointer(w.manager + 104, w.locals)
    put_pointer(w.manager + 112, w.nets)
    -- Settings: payload in slot 0 (index 0), initial spawn in slot 2 (index 3), reinforce in slot 9 (index 5).
    local function setting(slot, kind, index, variant, initial, braking)
        put_u32(w.table + slot * 16, kind.low); put_u32(w.table + slot * 16 + 4, kind.high)
        put_u32(w.table + slot * 16 + 8, index)
        local record = w.table + 256 + index * 104
        put_u32(record, variant); put_f32(record + 8, 1000)
        put_f32(record + 20, initial); put_f32(record + 24, 500); put_f32(record + 28, braking); put_f32(record + 32, 1)
    end
    setting(0, PAYLOAD, 0, 0, 400, 100)
    setting(2, INITIAL, 3, 2, 400, 100)
    setting(9, REINFORCE, 5, 1, 350, 100)
    return w
end
-- The menu stack (and the current menu presenter, its top), and the HUD presenter.
local function screens(w, ids, hud)
    for i = 0, 4 do put_u32(w.ui + hold.stack_offset + i * 4, ids[i + 1] or 0) end
    put_u32(w.ui + hold.stack_offset + 20, #ids)
    put_u32(w.ui + hold.presenters_offset + 4, ids[#ids] or 0)
    put_u32(w.ui + hold.presenters_offset, hud or 0)
end
local function game_state(w, value) put_u32(w.object + hold.state_offset, value) end
local function cutscene(w, current, queued)
    put_u32(w.scenes + hold.scene_offset, current or 0); put_u32(w.scenes + hold.scene_offset + 4, queued or 0)
end
local function join_flags(w, hotjoining, hotjoined, client_state)
    ffi.cast('uint8_t *', w.session + hold.hotjoin_offset)[0] = hotjoining  -- lint-ok: R3 test memory only
    ffi.cast('uint8_t *', w.session + hold.hotjoin_offset)[1] = hotjoined  -- lint-ok: R3 test memory only
    put_u32(w.session + hold.client_state_offset, client_state)
end
local function active(w) return get_u32(w.manager + 48) end
-- Rebuilds the id map from the active records the way the game probes it: slot
-- (probe + id * multiplier) & 63, with 32-bit wrapping (exact through a uint32 cdata).
local function rebuild_map(w, count)
    for slot = 0, 63 do put_u32(w.map + slot * 8, 0xFFFFFFFF) end
    for index = 0, count - 1 do
        local record = get_u32(w.records + index * 8) + get_u32(w.records + index * 8 + 4) * 4294967296
        local id = get_u32(record + 8)
        local start = tonumber(ffi.cast('uint32_t', ffi.cast('uint32_t', id) * 2654435761))
        for probe = 0, 63 do
            local slot = (start + probe) % 64
            if get_u32(w.map + slot * 8) == 0xFFFFFFFF then
                put_u32(w.map + slot * 8, id); put_u32(w.map + slot * 8 + 4, index)
                break
            end
        end
    end
end
local function set_active(w, n)
    put_u32(w.manager + 44, n); put_u32(w.manager + 48, n)
    rebuild_map(w, n)
end
-- Adds a pod at the end of the active range; returns its index and entity id.
local function add_pod(w, options)
    local index, kind = active(w), options.kind or INITIAL
    local record = alloc(24)
    w.next_id = w.next_id + 1
    put_u32(record, kind.low); put_u32(record + 4, kind.high); put_u32(record + 8, w.next_id)
    put_u32(record + 12, 7); put_u32(record + 16, 0x7FFF); put_u32(record + 20, options.owned == false and 0 or 1)
    put_pointer(w.records + index * 8, record)
    ffi.fill(ffi.cast('void *', w.locals + index * 160), 160, 0)
    put_f32(w.locals + index * 160 + 32, options.t or 1)
    put_u32(w.nets + index * 20, options.phase or 0)
    put_f32(w.nets + index * 20 + 12, options.z or 1500)
    set_active(w, index + 1)
    return index, w.next_id
end
-- Removes the pod at index the way the game does: the last pod moves into its place.
local function remove_pod(w, index)
    local last = active(w) - 1
    if index ~= last then
        copy(w.records + index * 8, w.records + last * 8, 8)
        copy(w.locals + index * 160, w.locals + last * 160, 160)
        copy(w.nets + index * 20, w.nets + last * 20, 20)
    end
    set_active(w, last)
end
local function factor_of(w, index) return get_f32(w.locals + index * 160 + 32) end

-- The api the hold gets: real reads, except the redirected globals; failures on demand.
local function world_api(w)
    local api = setmetatable({}, {__index = real})
    api.read_to = function(address, size, destination)
        if w.fail_reads and w.fail_reads(address) then return false end
        local slot = w.slots[address]
        if slot ~= nil then
            if not slot then return false end
            return real.read_to(slot, size, destination)
        end
        return real.read_to(address, size, destination)
    end
    api.write_batch = function(base, size, changes)
        w.writes = (w.writes or 0) + 1
        return real.write_batch(base, size, changes)
    end
    return api
end

-- One run of hold.update per frame; dt defaults to 1/60.
local function frames(api, w, session, n, dt)
    for _ = 1, n do
        local ok, why = hold.update(api, w.game, session, dt or 1 / 60)
        if not ok then return ok, why end
    end
    return true
end

local T_HOLD = (0.5 - 100) / (400 - 100)
local function close(a, b) return math.abs(a - b) < 1e-6 end

-- Scenarios ------------------------------------------------------------------------

do  -- Ship and menus: no loading screen, no manager.
    local w = new_world(); screens(w, {1}); w.slot(w.game + hold.manager_rva, 0)
    local api = world_api(w)
    local session = hold.session()
    local counts = budget.wrap(api)
    local first = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
    budget.check(first, {read_to = 4}, 'first idle frame')
    assert(first.read_to == 4)
    -- 600 frames at 60 FPS: a poll of exactly 4 reads (game object pointer, state, UI pointer, presenters) every 15 or 16 frames
    -- (dt sums drift), nothing at all on the frames between.
    local polls, last_poll = 0, 0
    for frame_number = 1, 600 do
        local frame = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
        budget.check(frame, {read_to = 4}, 'idle frame')
        if frame.read_to then
            assert(frame.read_to == 4 and frame_number - last_poll >= 15 and frame_number - last_poll <= 16)
            polls, last_poll = polls + 1, frame_number
        else
            assert(next(frame) == nil, 'idle frame between polls: ' .. budget.describe(frame))
        end
    end
    assert(polls >= 37 and polls <= 40, polls)
    assert(not session.loading and not session.held and (w.writes or 0) == 0)
    pass('idle: 4 reads every 0.25 s, nothing between polls, no page check, no write')
end

do  -- A mission in progress without a loading screen: pods are never looked at.
    local w = new_world(); screens(w, {})
    add_pod(w, {}); add_pod(w, {kind = REINFORCE})
    local api = world_api(w)
    local session = hold.session()
    assert(frames(api, w, session, 600))
    assert(not session.held and (w.writes or 0) == 0 and factor_of(w, 0) == 1 and factor_of(w, 1) == 1)
    pass('in a mission with no loading screen, drops and reinforcements are never held')
end

do  -- Join in progress: loading screen, then the own pod spawns, then the screen leaves.
    local w = new_world(); screens(w, {2})
    add_pod(w, {kind = PAYLOAD}); add_pod(w, {owned = false})   -- a payload pod and a teammate's drop
    local api = world_api(w)
    local session = hold.session()
    local events = {}
    session.note = function(text) events[#events + 1] = text end
    local counts = budget.wrap(api)
    -- Exact counts (the frame budget rule: limits equal today's counts).
    local function exactly(frame, limits, label)
        budget.check(frame, limits, label)
        for name, limit in pairs(limits) do
            assert((frame[name] or 0) == limit, label .. ': ' .. budget.describe(frame))
        end
    end
    local queries = memory.queries
    local first = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
    assert(session.loading and not session.held)
    -- The idle poll (4: state and presenters); the loading frame's signals (9: the same 4, then
    -- the session pointer, client state, hotjoin flags, cutscene pointer, scenes); the manager
    -- pointer and header 2; the sighting scan (pointers 1, records 2) and the hold scan (the same 3).
    exactly(first, {read_to = 4 + 9 + 2 + 3 + 3}, 'loading screen appears')
    local quiet = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
    exactly(quiet, {read_to = 9 + 2}, 'loading frame, no new pod')
    local index = add_pod(w, {z = 1500})
    local spawn = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
    -- Signals 9, manager 2; sighting (pointers 1, records 3, height 1, phase 1); hold scan (pointers 1,
    -- records 3, phase 1, map 1); settings (owner, table, slots, variant, speeds) 5; factor 1; recheck
    -- (pointer, record, map) 3; read back 1; the height for the log 1.
    exactly(spawn, {read_to = 9 + 2 + 6 + 6 + 5 + 1 + 3 + 1 + 1, write_batch = 1}, 'own pod appears')
    assert(memory.queries == queries + 1, 'one page check for the hold')
    assert(w.writes == 1 and session.held and close(factor_of(w, index), T_HOLD), factor_of(w, index))
    assert(factor_of(w, 0) == 1 and factor_of(w, 1) == 1, 'other pods untouched')
    local polls = 0
    for _ = 1, 60 do
        local frame = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
        if frame.read_to == 9 + 5 then
            polls = polls + 1                                  -- signals 9, then manager 2 and the pod 3
        else
            exactly(frame, {read_to = 9}, 'holding frame')    -- the cover (signals 9), every frame
        end
        assert(not frame.write_batch)
    end
    assert(polls == 3 or polls == 4, polls)
    screens(w, {})
    local release_frame = budget.frame(counts, hold.update, api, w.game, session, 1 / 60)
    -- The first frame without the cover releases: signals 9; manager 2, the pod (pointer, record, map) 3,
    -- factor 1, read back 1, height 1.
    exactly(release_frame, {read_to = 9 + 8, write_batch = 1}, 'release in the frame the cover ends')
    assert(not session.held and factor_of(w, index) == 1, 'released to exactly 1.0')
    assert(memory.queries == queries + 2, 'one page check for the release')
    assert(frames(api, w, session, 120) and w.writes == 2, 'never held again')
    local log = table.concat(events, '\n')
    assert(log:find('loading screen up') and log:find('holding initial spawn pod') and log:find('released pod'), log)
    pass('join in progress: held at spawn while loading (1 write), released 1.5 s after the screen (1 write)')
end

do  -- Preparing a mission (game state 6) counts as loading, with or without a loading presenter.
    local w = new_world(); screens(w, {}); game_state(w, 6)
    local api = world_api(w)
    local session = hold.session()
    local events = {}
    session.note = function(text) events[#events + 1] = text end
    assert(frames(api, w, session, 20) and session.loading)
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held)
    game_state(w, 4); screens(w, {}, 3)                   -- the mission begins, with the mission HUD
    assert(frames(api, w, session, 1) and not session.held and factor_of(w, index) == 1, 'released at once')
    local log = table.concat(events, '\n')
    assert(log:find('game state 6, hud none', 1, true) and log:find('game state 4, hud mission', 1, true), log)
    local ship = new_world(); screens(ship, {}); game_state(ship, 5)
    local ship_session = hold.session()
    assert(frames(world_api(ship), ship, ship_session, 20) and ship_session.loading)
    pass('preparing a mission or the ship counts as loading; the event log follows the state and the HUD')
end

do  -- The join seen live on 2026-10-05: preparing ended before the pod existed, while the join cutscene went on.
    local w = new_world(); screens(w, {}); game_state(w, 3)
    cutscene(w, 15, 0); join_flags(w, 1, 1, 3)                 -- on the ship: the network-join cutscene plays
    local api = world_api(w)
    local session = hold.session()
    local events = {}
    session.note = function(text) events[#events + 1] = text end
    assert(frames(api, w, session, 30) and not session.loading, 'a cutscene alone never starts a loading period')
    game_state(w, 6)                                           -- preparing the mission (7 s in the live join)
    assert(frames(api, w, session, 30) and session.loading)
    game_state(w, 4)                                           -- the mission: no pod yet, the cutscene goes on
    assert(frames(api, w, session, 30) and session.loading and not session.held)
    local index = add_pod(w, {z = 1500})                       -- the host's drop arrives behind the cutscene
    assert(frames(api, w, session, 2) and session.held)
    assert(frames(api, w, session, 120) and session.held, 'held while the cutscene plays')
    cutscene(w, 0, 0); join_flags(w, 0, 1, 3)                  -- synchronized tasks done: the cutscene is interrupted
    assert(frames(api, w, session, 1) and not session.held and factor_of(w, index) == 1, 'released at once')
    local log = table.concat(events, '\n')
    assert(log:find('cutscene ship teleporter network join', 1, true) and log:find('own initial spawn pod', 1, true)
        and log:find('hotjoining 1', 1, true) and log:find('hotjoining 0', 1, true), log)
    -- A cutscene on the ship never keeps a loading period going, and one in a mission without a loading screen
    -- before it never starts one.
    local ship = new_world(); screens(ship, {}); game_state(ship, 5); cutscene(ship, 9, 0)
    local ship_api, ship_session = world_api(ship), hold.session()
    assert(frames(ship_api, ship, ship_session, 20) and ship_session.loading)
    game_state(ship, 3)
    assert(frames(ship_api, ship, ship_session, 20) and not ship_session.loading)
    local mission = new_world(); screens(mission, {}); cutscene(mission, 1, 0)
    local mission_session = hold.session()
    add_pod(mission, {kind = REINFORCE})
    assert(frames(world_api(mission), mission, mission_session, 60) and not mission_session.held)
    pass('a join cutscene that outlasts preparing keeps the pod held; a cutscene alone never holds one')
end

do  -- is_hotjoining alone also keeps a loading period going in the mission (a join without the cutscene).
    local w = new_world(); screens(w, {}); game_state(w, 6); join_flags(w, 1, 1, 3)
    local api = world_api(w)
    local session = hold.session()
    assert(frames(api, w, session, 20) and session.loading)
    game_state(w, 4)
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held)
    assert(frames(api, w, session, 300) and session.held, 'held while the join is still finishing')
    join_flags(w, 0, 1, 3)                                     -- synchronized tasks done
    assert(frames(api, w, session, 120) and not session.held and factor_of(w, index) == 1)
    -- Unreadable join flags never count; neither do the flags on the ship.
    local unreadable = new_world(); screens(unreadable, {}); game_state(unreadable, 6)
    unreadable.slot(unreadable.game + hold.session_rva, 0)
    local unreadable_session = hold.session()
    assert(frames(world_api(unreadable), unreadable, unreadable_session, 20) and unreadable_session.loading)
    game_state(unreadable, 4)
    assert(frames(world_api(unreadable), unreadable, unreadable_session, 20) and not unreadable_session.loading)
    local ship = new_world(); screens(ship, {}); game_state(ship, 3); join_flags(ship, 1, 1, 3)
    local ship_session = hold.session()
    assert(frames(world_api(ship), ship, ship_session, 40) and not ship_session.loading)
    pass('a join still finishing (is_hotjoining) keeps the pod held in the mission; unreadable or ship flags never do')
end

do  -- A slow load at mission start, a second loading screen later, a reinforce-type pod.
    local w = new_world(); screens(w, {14, 2})          -- loading below another screen still counts
    local api = world_api(w)
    local session = hold.session()
    assert(frames(api, w, session, 3))
    local index = add_pod(w, {kind = REINFORCE})
    assert(frames(api, w, session, 1) and session.held)
    assert(close(factor_of(w, index), (0.5 - 100) / (350 - 100)))
    screens(w, {4})                                       -- the tutorial screen counts too
    assert(frames(api, w, session, 200) and session.held)
    screens(w, {3})                                       -- the ship loading screen does not
    assert(frames(api, w, session, 200) and not session.held and factor_of(w, index) == 1)
    pass('loading screens 2 and 4 at any depth hold; screen 3 does not; reinforce-type pods use their own speeds')
end

do  -- Phases and ownership.
    local w = new_world(); screens(w, {2})
    local api = world_api(w)
    local session = hold.session()
    local landed = add_pod(w, {phase = 2})
    local remote = add_pod(w, {owned = false})
    local payload = add_pod(w, {kind = PAYLOAD})
    assert(frames(api, w, session, 30) and not session.held)
    local braking = add_pod(w, {phase = 1, t = 0.4})
    assert(frames(api, w, session, 1) and session.held)
    assert(factor_of(w, landed) == 1 and factor_of(w, remote) == 1 and factor_of(w, payload) == 1)
    assert(close(factor_of(w, braking), T_HOLD))
    screens(w, {})
    assert(frames(api, w, session, 200) and close(factor_of(w, braking), 0.4), 'released to the saved 0.4')
    -- A record the manager's own id map does not place at that index is never held.
    local other = new_world(); screens(other, {2})
    local other_api = world_api(other)
    local other_session = hold.session()
    local stray = add_pod(other, {})
    for slot = 0, 63 do put_u32(other.map + slot * 8, 0xFFFFFFFF) end
    assert(frames(other_api, other, other_session, 30) and not other_session.held and factor_of(other, stray) == 1)
    pass('only own falling or braking drop pods that the id map confirms are held; the saved factor comes back')
end

do  -- The pod moves to another index, then another pod goes.
    local w = new_world(); screens(w, {2})
    local api = world_api(w)
    local session = hold.session()
    add_pod(w, {kind = PAYLOAD}); add_pod(w, {kind = PAYLOAD})
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held and session.held.index == index)
    remove_pod(w, 0)                                     -- the game moves our pod into index 0
    assert(frames(api, w, session, 20) and session.held.index == 0, 'located at its new index')
    screens(w, {})
    assert(frames(api, w, session, 200) and not session.held)
    assert(factor_of(w, 0) == 1 and w.writes == 2)
    pass('a held pod that the manager moves is found again and released at its new index')
end

do  -- The pod disappears while held: nothing is written.
    local w = new_world(); screens(w, {2})
    local api = world_api(w)
    local session = hold.session()
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held)
    remove_pod(w, index)
    assert(frames(api, w, session, 20) and not session.held and w.writes == 1)
    screens(w, {})
    assert(frames(api, w, session, 200) and w.writes == 1)
    pass('a held pod that disappears is forgotten without a write')
end

do  -- Someone else changes the factor while held: it is left alone.
    local w = new_world(); screens(w, {2})
    local api = world_api(w)
    local session = hold.session()
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held)
    put_f32(w.locals + index * 160 + 32, 0.25)
    screens(w, {})
    assert(frames(api, w, session, 200) and not session.held and w.writes == 1 and factor_of(w, index) == 0.25)
    local other = new_world(); screens(other, {2})
    local other_api = world_api(other)
    local fresh = hold.session()
    local odd = add_pod(other, {t = 7})
    assert(frames(other_api, other, fresh, 30) and not fresh.held and factor_of(other, odd) == 7)
    pass('a factor changed by someone else is never overwritten, at hold or at release')
end

do  -- The longest hold, and a released pod is not held again under the same screen.
    local w = new_world(); screens(w, {2})
    local api = world_api(w)
    local session = hold.session()
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held)
    assert(frames(api, w, session, 119 * 10, 0.1) and session.held)
    assert(frames(api, w, session, 20, 0.1) and not session.held and factor_of(w, index) == 1)
    assert(frames(api, w, session, 300, 0.1) and not session.held and w.writes == 2)
    pass('the longest hold ends at 120 s, and that pod is not held again')
end

do  -- An unreadable manager at release keeps the hold and retries at the next poll.
    local w = new_world(); screens(w, {2})
    local api = world_api(w)
    local session = hold.session()
    local index = add_pod(w, {})
    assert(frames(api, w, session, 2) and session.held)
    screens(w, {})
    w.fail_reads = function(address) return address == w.manager + hold.header_offset end
    assert(frames(api, w, session, 200) and session.held and session.held.retry, 'kept')
    assert(close(factor_of(w, index), T_HOLD))
    w.fail_reads = nil
    assert(frames(api, w, session, 16) and not session.held and factor_of(w, index) == 1)
    pass('a release that cannot read the manager is kept and retried 4 times a second')
end

do  -- Refusals stop the mod; nothing is written.
    local cases = {
        {'manager_layout', function(w) put_u32(w.manager + 36, 5000) end},
        {'manager_layout', function(w) put_u32(w.manager + 48, 99) end},
        {'drop_pod_settings_unrecognized', function(w) put_f32(w.table + 256 + 3 * 104 + 28, 600) end},
        {'drop_pod_settings_unrecognized', function(w) put_u32(w.table + 256 + 3 * 104, 0) end},
        {'drop_pod_settings_unrecognized', function(w) put_u32(w.table + 2 * 16, 0) end},
    }
    for _, case in ipairs(cases) do
        local w = new_world(); screens(w, {2})
        local api = world_api(w)
        local session = hold.session()
        local index = add_pod(w, {})
        case[2](w)
        local ok, why = frames(api, w, session, 30)
        assert(ok == false and why == case[1], tostring(why))
        assert((w.writes or 0) == 0 and factor_of(w, index) == 1)
    end
    local w = new_world(); screens(w, {2}); w.slot(w.game + hold.manager_rva, 0)
    assert(frames(world_api(w), w, hold.session(), 60), 'no manager yet: keep waiting')
    local junk = new_world(); put_u32(junk.ui + hold.stack_offset + 20, 9)
    local junk_session = hold.session()
    assert(frames(world_api(junk), junk, junk_session, 60) and not junk_session.loading)
    pass('a manager or setting that makes no sense stops the mod before any write; a missing manager waits')
end

do  -- Test builds: every own drop pod is held for the given time, loading screen or not.
    local w = new_world(); screens(w, {})
    local api = world_api(w)
    local session = hold.session(5)
    local first = add_pod(w, {})
    assert(frames(api, w, session, 20) and session.held)
    assert(frames(api, w, session, 280) and session.held)
    assert(frames(api, w, session, 30) and not session.held and factor_of(w, first) == 1)
    local second = add_pod(w, {kind = REINFORCE})
    assert(frames(api, w, session, 20) and session.held and session.held.index == second)
    assert(frames(api, w, session, 320) and not session.held and factor_of(w, second) == 1)
    assert(w.writes == 4)
    pass('test builds hold every own drop pod for the set time, once each')
end

do  -- No garbage per frame: idle, loading and holding.
    local w = new_world(); screens(w, {})
    local api = world_api(w)
    local session = hold.session()
    -- Test process only: the GC is stopped around the frames to count their allocation.
    local function garbage(n)
        collectgarbage('collect')  -- lint-ok: R4 test process only, measures allocation per frame
        collectgarbage('stop')  -- lint-ok: R4 test process only, measures allocation per frame
        local before = collectgarbage('count')
        frames(api, w, session, n)
        local after = collectgarbage('count')
        collectgarbage('restart')  -- lint-ok: R4 test process only, measures allocation per frame
        return (after - before) * 1024
    end
    garbage(30)
    local idle = garbage(600)
    screens(w, {2}); frames(api, w, session, 30); assert(session.loading)
    local loading = garbage(600)
    add_pod(w, {}); frames(api, w, session, 5); assert(session.held)
    local holding = garbage(600)
    assert(idle == 0 and loading == 0 and holding == 0, string.format('garbage idle %d, loading %d, holding %d bytes',
        idle, loading, holding))
    pass('no Lua garbage per frame: idle, loading screen, holding')
end

-- The loader: build check, guard, pause and stop -------------------------------------

do
    local w = new_world(); screens(w, {2})
    local logs = {}
    local previous = {update = rawget(_G, 'update'), shutdown = rawget(_G, 'shutdown'),
                      loader = rawget(_G, 'CowboyBingusModLoader')}
    local below_error
    _G.update = function() if below_error then below_error = nil; error('below', 0) end end
    _G.shutdown = function() end
    _G.CowboyBingusModLoader = {open_log = function(name)
        local lines = {}
        logs[name] = lines
        return {write = function(_, text) lines[#lines + 1] = text end, close = function() end}
    end}
    -- The test process has no game.dll: the fake answers for it with the world's base.
    local function fake_api(exe_hash)
        return function()
            local api = world_api(w)
            api.module = function(name) return name and ffi.cast('uint8_t *', w.game) or real.module(nil) end
            api.verify_build = function(build)
                if exe_hash ~= build.exe_sha256 or build.game_sha256 ~= 'GAME' then
                    return false, 'unsupported game build'
                end
                return true
            end
            return api
        end
    end
    install_loader(fake_api('WRONG'), hold, {revision = 'test', exe_sha256 = 'EXE', game_sha256 = 'GAME'}, runtime)
    assert(_G.HellpodDropHold.status == 'unsupported game build; no change applied', _G.HellpodDropHold.status)
    assert(not _G.HellpodDropHold.active)
    _G.HellpodDropHold = nil
    install_loader(fake_api('EXE'), hold, {revision = 'test', exe_sha256 = 'EXE', game_sha256 = 'GAME'}, runtime)
    local state = _G.HellpodDropHold
    assert(state.active and state.status == 'waiting_for_loading_screen', state.status)
    local index = add_pod(w, {})
    for _ = 1, 5 do update(1 / 60) end
    assert(close(factor_of(w, index), T_HOLD), 'held through the guard')
    below_error = true
    assert(not pcall(update, 1 / 60), 'an error below reaches the game unchanged')
    update(1 / 60)
    assert(factor_of(w, index) == 1, 'paused: released')
    for _ = 1, 59 do update(1 / 60) end
    assert(factor_of(w, index) == 1, 'paused: nothing runs')
    for _ = 1, 30 do update(1 / 60) end
    assert(close(factor_of(w, index), T_HOLD), 'resumed afresh: held again while the screen is up')
    shutdown()
    assert(close(factor_of(w, index), T_HOLD), 'shutdown writes nothing')
    local log = table.concat(logs['HellpodDropHold.log'] or {}, '')
    assert(log:find('test\n') and log:find('holding initial spawn pod'), log)
    _G.HellpodDropHold = nil
    _G.update, _G.shutdown, _G.CowboyBingusModLoader = previous.update, previous.shutdown, previous.loader
    pass('loader: refuses other builds, holds through the guard, releases on pause, writes nothing at shutdown')
end

print(count .. ' offline checks passed')
