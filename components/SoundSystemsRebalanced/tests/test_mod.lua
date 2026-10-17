-- Offline tests for Sound Systems Rebalanced: the real Bingus Shared Runtime reading a synthetic game object in this
-- process's FFI memory, with exact per-scenario call budgets (tests/frame_budget.lua), no garbage or C types per
-- frame, and the install paths under a hostile VM (name clashes, a failing update below).
-- Usage: luajit tests/test_mod.lua <project root>   (also run in the game's lua51.dll by scripts/build.py)
local root = assert(arg[1], 'project root required')
local H = dofile(root .. '/tests/hostile_vm.lua')
-- A mod that loaded first declared the plain Windows names with a wrong prototype; the runtime's private names
-- must keep working.
H.clash({'GetModuleHandleA', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery'})
local ffi = require('ffi')
local budget = dofile(root .. '/tests/frame_budget.lua')
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local memory = dofile(root .. '/src/bingus_memory.lua')
local Mod = dofile(root .. '/src/sound_systems_rebalanced.lua')
local passed = 0

local LAYOUT = {game_rva = 0x100, state_offset = 0x40}
local DT = 0.0625                 -- exact in binary: 4 frames make one 0.25 s check period
local ROOM = 'environment_shiphub_room=shiphub_view'

-- A synthetic game.dll (its static game-object pointer at game_rva) and game object (the state at state_offset).
local function fake_game(state)
    local g = {module = ffi.new('uint8_t[?]', 0x200), object = ffi.new('uint8_t[?]', 0x80)}
    function g.point(pointer) ffi.cast('uint64_t *', g.module + LAYOUT.game_rva)[0] = pointer end
    function g.point_at_object() g.point(ffi.cast('uint64_t', ffi.cast('uintptr_t', g.object))) end
    function g.state(value) ffi.cast('uint32_t *', g.object + LAYOUT.state_offset)[0] = value end
    g.point_at_object()
    g.state(state or 3)
    return g
end

local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function expect(frame, expected, label)
    budget.check(frame, expected, label)
    assert(same(frame, expected), label .. ': calls ' .. budget.describe(frame) .. ', expected '
        .. budget.describe(expected))
end

local function setup(initial)
    local t = {g = fake_game(initial), calls = {}, lines = {}, state = {missions = 0, status = 'test'}}
    t.api = memory.new(runtime)
    t.counts = budget.wrap(t.api)
    local function set_state(group, value) t.calls[#t.calls + 1] = group .. '=' .. value end
    local function note(line) t.lines[#t.lines + 1] = line end
    t.instance = Mod.new(t.api, t.g.module, set_state, note, t.state, LAYOUT)
    return t
end

local function frame(t, dt)
    return (budget.frame(t.counts, t.instance.step, dt == nil and DT or dt))
end

-- Runs one check period (3 frames without a call, then the check) and returns the check frame's calls.
local function period(t, label)
    for i = 1, 3 do expect(frame(t), {}, label .. ': frame ' .. i .. ' of the period') end
    return frame(t)
end

local function test(name, fn)
    fn()
    passed = passed + 1
end

test('first frame resolves the game object and reads the state; ship idle frames make no call', function()
    local t = setup(3)
    expect(frame(t), {read_into = 2}, 'first frame on the ship')
    expect(period(t, 'ship idle'), {read_into = 1}, 'ship check frame')
    assert(#t.calls == 0 and #t.lines == 0, 'the ship state set something')
end)

test('entering a mission sets the room once; the mission and the loading before it never repeat it', function()
    local t = setup(3)
    frame(t)
    t.g.state(6)                                     -- preparing a mission (loading)
    expect(period(t, 'loading'), {read_into = 1}, 'mission start check frame')
    assert(#t.calls == 1 and t.calls[1] == ROOM, table.concat(t.calls, ','))
    assert(#t.lines == 1 and t.lines[1]:find('Mission start (game state 6)', 1, true), t.lines[1])
    assert(t.state.missions == 1 and t.state.status:find('1 time', 1, true), t.state.status)
    t.g.state(4)                                     -- the mission itself
    for i = 1, 5 do expect(period(t, 'mission'), {read_into = 1}, 'mission check frame ' .. i) end
    assert(#t.calls == 1, 'set again during the mission')
end)

test('back on the ship, the next mission sets it again', function()
    local t = setup(4)
    expect(frame(t), {read_into = 2}, 'first frame inside a mission')
    assert(#t.calls == 1, 'a mission already running at the first read was not handled')
    for _, value in ipairs({5, 3, 3}) do
        t.g.state(value)
        expect(period(t, 'ship ' .. value), {read_into = 1}, 'ship check frame')
    end
    assert(#t.calls == 1, 'the ship set something')
    t.g.state(6)
    period(t, 'second mission')
    t.g.state(4)
    period(t, 'second mission')
    assert(#t.calls == 2 and t.state.missions == 2, 'second mission: ' .. #t.calls .. ' calls')
end)

test('a moved game object is resolved again; one not created yet is retried without a call', function()
    local t = setup(3)
    frame(t)
    t.g.state(0xFFFFFFFF)                            -- not a game state: the cached address is stale
    expect(period(t, 'stale'), {read_into = 1}, 'stale value check frame')
    t.g.state(3)
    expect(period(t, 'stale'), {read_into = 2}, 'resolve again after a stale value')
    assert(#t.calls == 0, 'a stale value made a call')
    local early = setup(6)
    early.g.point(0)                                 -- the game has not created its game object yet
    expect(frame(early), {read_into = 1}, 'first frame without the game object')
    expect(period(early, 'missing'), {read_into = 1}, 'missing object check frame')
    expect(period(early, 'missing'), {read_into = 1}, 'missing object check frame again')
    assert(#early.calls == 0, 'a missing object made a call')
    early.g.point_at_object()
    expect(period(early, 'created'), {read_into = 2}, 'object created: resolve and read')
    assert(#early.calls == 1, 'the mission state after the object appeared made ' .. #early.calls .. ' calls')
end)

test('an update chain that passes no dt still checks about every 0.25 s', function()
    local t = setup(3)
    frame(t)
    local reads = 0
    for _ = 1, 32 do reads = reads + (frame(t, false).read_into or 0) end  -- false: tonumber gives nil
    assert(reads == 2, 'expected 2 checks in 32 frames at the 1/60 s fallback, got ' .. reads)
end)

test('no garbage and no C types per frame, idle and in a mission', function()
    local g = fake_game(3)
    local state = {missions = 0, status = 'test'}
    local instance = Mod.new(memory.new(runtime), g.module, function() end, function() end, state, LAYOUT)
    for _ = 1, 8 do instance.step(DT) end           -- warm up: first resolve, interned array types
    local function run(n) for _ = 1, n do instance.step(DT) end end
    assert(H.ctype_growth(run, 40) == 0, 'C types created per frame on the ship')
    g.state(4)
    run(8)                                           -- the mission start (allocates its log line)
    assert(H.ctype_growth(run, 40) == 0, 'C types created per frame in a mission')
    -- Garbage, interpreted and compiled. Trace objects live in the GC heap too, and the JIT can add a side trace
    -- in any window (about 1.6 KB once, seen in the game's lua51.dll), so a window may grow once; per-frame
    -- garbage would grow every window. Up to 4 windows of 400 frames: one must stay at 0.
    local function garbage(label)
        run(2000)
        local grown
        for _ = 1, 4 do
            collectgarbage('collect')
            collectgarbage('stop')
            local before = collectgarbage('count')
            run(400)
            grown = collectgarbage('count') - before
            collectgarbage('restart')
            if grown == 0 then return end
        end
        error(string.format('%s: %.3f KB of garbage in each of 4 windows of 400 frames', label, grown))
    end
    for _, value in ipairs({3, 4}) do
        g.state(value)
        garbage('state ' .. value .. ', compiled')
        if jit and jit.off then
            jit.off()
            garbage('state ' .. value .. ', interpreted')
            jit.on()
        end
    end
end)

-- A memory api whose build check passes and whose game.dll is the synthetic one.
local function game_api(g)
    local api = memory.new(runtime)
    api.verify_build = function() return true end
    api.module = function(name) return name == 'game.dll' and g.module or nil end
    return api
end

local function fake_loader()
    local lines = {}
    return {api = 1, open_log = function()
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}, lines
end

local quiet = print
print = function() end                               -- the mod's console lines

test('install: a refused build, a missing loader or binding hook nothing', function()
    local function vanilla() return 'vanilla' end
    local loader, lines = fake_loader()
    local env = {update = vanilla}
    local state = Mod.install(runtime, memory.new(runtime), {env = env, loader = loader,
                                                              set_state = function() end})
    -- Outside the game the real check finds no game modules; in a wrong build it says 'unsupported game build'.
    assert(state.status:find('^disabled: game modules unavailable') or
           state.status:find('^disabled: unsupported game build'), state.status)
    assert(env.update == vanilla and env.shutdown == nil, 'a refused build hooked the game')
    assert(#lines == 1 and lines[1]:find('disabled', 1, true), table.concat(lines))
    state = Mod.install(runtime, game_api(fake_game()), {env = {update = vanilla}, loader = {},
                                                         set_state = function() end})
    assert(state.status:find('Bingus Shared Loader', 1, true), state.status)
    env = {update = vanilla}
    state = Mod.install(runtime, game_api(fake_game()), {env = env, loader = fake_loader()})
    assert(state.status:find('stingray.Wwise.set_state is unavailable', 1, true), state.status)
    assert(env.update == vanilla, 'a missing binding hooked the game')
end)

test("install: the engine's binding drives a guarded update; a failing update below passes through", function()
    local g = fake_game(3)
    local calls = {}
    local env = {stingray = {Wwise = {set_state = function(group, value) calls[#calls + 1] = group .. '=' .. value
        end}}}
    env.update = function() return 'below' end
    local neighbour = H.chain(env, 'throw_below', {raise_on = 3})
    local loader, lines = fake_loader()
    local state = Mod.install(runtime, game_api(g), {env = env, loader = loader, layout = LAYOUT})
    assert(state.status == 'watching for mission starts', state.status)
    assert(env.update(DT) == 'below' and env.update(DT) == 'below', 'the update chain lost a return value')
    local ok, err = pcall(env.update, DT)
    assert(not ok and type(err) == 'table' and err.hostile_vm == 'throw_below', 'the error below was changed')
    assert(neighbour.raised == 1, 'the neighbour did not raise once')
    g.state(6)
    for _ = 1, 70 do env.update(DT) end              -- paused, then resumed after 60 clean frames
    assert(#calls == 1 and calls[1] == ROOM, 'after the pause: ' .. table.concat(calls, ','))
    assert(state.missions == 1, 'missions ' .. state.missions)
    env.shutdown()
    assert(lines[#lines]:find('Stopped (shutdown) after 1 mission(s).', 1, true), lines[#lines])
    local guard = rawget(env, 'BingusRuntime').statuses.SoundSystemsRebalanced  -- the guard's shared table lives in env
    assert(guard and guard.pauses == 1, 'pauses ' .. tostring(guard and guard.pauses))
    H.chain_restore(env)
end)

test('the binding lookup survives a hostile stingray table', function()
    assert(Mod.engine_set_state({}) == nil, 'no stingray')
    local hostile = setmetatable({}, {__index = function() error('no such field') end})
    assert(Mod.engine_set_state({stingray = hostile}) == nil, 'an indexing error escaped')
    local fn = function() end
    assert(Mod.engine_set_state({stingray = {Wwise = {set_state = fn}}}) == fn, 'binding not found')
end)

print = quiet
print(string.format('PASS: %d Sound Systems Rebalanced tests (%s)', passed, jit and jit.version or _VERSION))
