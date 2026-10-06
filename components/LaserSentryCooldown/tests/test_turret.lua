-- Laser Sentry Cooldown: the turret watch. An overheated Laser Sentry's AI switches itself off for good (behavior
-- state 6; in the base game the overheat ability's explosion follows). With the cooling rule the weapon recovers,
-- so once it has cooled the watch must ask the game to power the turret up again (a pending request for state 7,
-- which the game applies at the sentry's next behavior update), and only then, and only for sentries whose
-- behavior runs on this machine. On simulated WeaponHeat and behavior managers (tests/fake_game.lua
-- G.scene): the reported case, the exact calls of every kind of look, every refusal, zero allocation, and the
-- live test build's turret log. Runs in a LuaJIT 2.1 and in the game's lua51.dll (tests/game_lua.py).
-- Usage: luajit tests/test_turret.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_turret.lua <repository root>')
local G = dofile(root .. '/tests/fake_game.lua')(root)
local budget, H, Cooldown = G.budget, G.H, G.Cooldown
local format = string.format
local WATCH = Cooldown.WATCH_FRAMES
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local function same(a, b)
    for name, n in pairs(a) do if b[name] ~= n then return false end end
    for name, n in pairs(b) do if a[name] ~= n then return false end end
    return true
end
local function expect_counts(frame, expected, label)
    budget.check(frame, expected, label)
    assert(same(frame, expected), label .. ': calls ' .. budget.describe(frame) .. ', expected '
        .. budget.describe(expected))
end

-- The calls of each kind of look, one every WATCH_FRAMES frames; the frames between make none. view and u64 are
-- one ReadProcessMemory each (about 1-2 us in game); no look but the repair makes a page query or a write.
local LOOK = {
    menus = {u64 = 1},              -- no WeaponHeat manager: its pointer only
    ship = {u64 = 1, view = 1},     -- a manager without instances: + its header
    idle = {u64 = 1, view = 2},     -- instances, none overheated, none watched: + their states (one read)
    seen = {u64 = 1, view = 4},     -- a newly overheated instance: + every record pointer + its record
    cooling = {u64 = 1, view = 3},  -- a watched sentry still hot, or another weapon already known
    -- A watched sentry has cooled: its record again, the behavior manager (pointer, header), one map probe, the
    -- record check, the block, then the 4-byte request: one page query, one write, one read-back. Once per
    -- overheat.
    repair = {u64 = 3, view = 8, page = 1, write = 1},
}

local function mission(build, options)
    local memory = G.world()
    local scene = G.scene(memory, options)
    build(scene)
    scene.sync()
    local s = G.session({world = memory})
    assert(s.instance and s.instance.patched, 'patched at install')
    for i = #s.calls, 1, -1 do s.calls[i] = nil end -- the record's write at install; the watch's calls from here
    return s, scene
end

-- The heap growth of 20 looks in steady state: the smallest of up to five windows. Every look takes the same
-- path, so an allocation of the addon's would show in every window; what LuaJIT does once per session (a trace
-- of the guard, the stub that leaves the look branch to the interpreter, scheduled with a random backoff) can
-- land in one window only.
local function steady_heap(frames)
    local smallest = math.huge
    for _ = 1, 5 do
        smallest = math.min(smallest, (H.heap_peak(frames, 20 * WATCH)))
        if smallest == 0 then break end
    end
    return smallest
end

-- One watch interval: WATCH - 1 frames without a call, then the look. Returns the look's calls.
local function look(s, label)
    for frame = 1, WATCH - 1 do expect_counts(s.frame(), {}, label .. ' frame ' .. frame) end
    return (s.frame())
end

-- Reported 2026-10-05 (v1.1 test build, in a mission): "the explosion stop worked but the turret never came back
-- online". The log showed the sentry overheat at 250, cool at 5/s and recover after 50.0 s, then never fire again:
-- its behavior had stayed in state 6. Agreed outcome: nothing is written while it cools; the first look after
-- its overheated flag clears requests state 7 (power up), once, and the game's next update applies it.
check('reported 2026-10-05: a cooled Laser Sentry never came back online (v1.1)', function()
    local sentry
    local s, scene = mission(function(scene) sentry = scene.add({id = 721, sentry = true}) end)
    expect_counts(look(s, 'firing'), LOOK.idle, 'firing look')
    sentry.overheated, sentry.state = 1, Cooldown.STATE_STUCK -- what the firing state does at the overheat
    scene.sync()
    expect_counts(look(s, 'overheat'), LOOK.seen, 'overheat look')
    for i = 1, 24 do expect_counts(look(s, 'cooling'), LOOK.cooling, 'cooling look ' .. i) end -- 50 s at 60 fps
    assert(scene.turret(sentry) == Cooldown.STATE_STUCK and #s.calls == 0, 'off and untouched while it cools')
    sentry.overheated = 0 -- cooled: the heat rule cleared the flag; the behavior is still in state 6
    scene.sync()
    expect_counts(look(s, 'cooled'), LOOK.repair, 'repair look')
    local state, request = scene.turret(sentry)
    assert(state == Cooldown.STATE_STUCK and request == 7, format('state 7 requested: %d %#x', state, request))
    scene.apply_requests() -- the game's next behavior update
    local applied, cleared, last = scene.turret(sentry)
    assert(applied == 7 and cleared == 0xFFFFFFFF and last == 7,
           format('the game powers it up: %d %#x %d', applied, cleared, last))
    assert(table.concat(s.calls, ',') == 'page,write', 'one page query, one write: ' .. table.concat(s.calls, ','))
    assert(s.logged('Laser Sentry 721 cooled down: its turret powers up again.'), 'logged')
    assert(s.instance.watch.repairs == 1, 'one repair')
    for i = 1, 3 do expect_counts(look(s, 'after'), LOOK.idle, 'after look ' .. i) end
    assert(#s.calls == 2, 'nothing more written')
end)

check('looks outside a mission: the manager pointer, then its header', function()
    expect_counts(look(G.session(), 'menus'), LOOK.menus, 'menus look')
    local memory = G.world()
    G.scene(memory).sync()
    expect_counts(look(G.session({world = memory}), 'ship'), LOOK.ship, 'ship look')
end)

check('a Laser Sentry whose behavior runs on another machine is left alone', function()
    for _, flags in ipairs({0, 2, 3}) do -- not owned; not owned, remote; owned but simulated elsewhere
        local sentry
        local s, scene = mission(function(scene) sentry = scene.add({id = 900, sentry = true, flags = flags}) end)
        sentry.overheated, sentry.state = 1, Cooldown.STATE_STUCK
        scene.sync()
        expect_counts(look(s, 'overheat'), LOOK.seen, 'overheat look, flags ' .. flags)
        expect_counts(look(s, 'known'), LOOK.cooling, 'known, not read again, flags ' .. flags)
        sentry.overheated = 0
        scene.sync()
        expect_counts(look(s, 'cooled'), LOOK.idle, 'cooled look, flags ' .. flags)
        assert(scene.turret(sentry) == Cooldown.STATE_STUCK and #s.calls == 0, 'untouched, flags ' .. flags)
    end
end)

check('another heat weapon: its record is read once per overheat, then skipped', function()
    local rifle
    local s, scene = mission(function(scene) rifle = scene.add({id = 50, sentry = false}) end)
    rifle.overheated = 1
    scene.sync()
    expect_counts(look(s, 'overheat'), LOOK.seen, 'first look')
    for i = 1, 5 do expect_counts(look(s, 'still'), LOOK.cooling, 'still overheated ' .. i) end
    rifle.overheated = 0
    scene.sync()
    expect_counts(look(s, 'cooled'), LOOK.idle, 'cooled')
    rifle.overheated = 1
    scene.sync()
    expect_counts(look(s, 'again'), LOOK.seen, 'overheats again: its record is read again')
    assert(#s.calls == 0, 'nothing written')
end)

check('a sentry removed while it cools is forgotten', function()
    local sentry
    local s, scene = mission(function(scene)
        sentry = scene.add({id = 721, sentry = true})
        scene.add({id = 50, sentry = false})
    end)
    sentry.overheated, sentry.state = 1, Cooldown.STATE_STUCK
    scene.sync()
    expect_counts(look(s, 'overheat'), LOOK.seen, 'overheat look')
    scene.remove(sentry)
    scene.sync()
    expect_counts(look(s, 'gone'), LOOK.cooling, 'gone: its pointer is not there any more')
    expect_counts(look(s, 'after'), LOOK.idle, 'forgotten')
    assert(next(s.instance.watch.watched) == nil and #s.calls == 0, 'nothing watched, nothing written')
end)

check('a cooled sentry whose turret is not as expected is left as it is', function()
    local cases = {
        {'turret in state 2', function(sentry) sentry.state = 2 end},        -- something else moved it on
        {'turret state 3 already requested', function(sentry) sentry.request = 3 end}, -- another request pending
        {'unexpected behavior 300', function(sentry) sentry.behavior = 300 end},
        {'unexpected behavior manager', nil, {capacity = 12}},              -- not a power of two
        {'behavior of another entity', nil, {wrong_record = true}},
        {'not committed private memory', nil, {kind = G.MEM_IMAGE}},
    }
    for _, case in ipairs(cases) do
        local reason, change, options = case[1], case[2], case[3]
        local sentry
        local s, scene = mission(function(scene)
            sentry = scene.add({id = 721, sentry = true})
            scene.add({id = 722, sentry = true, flags = 0}) -- a second behavior block
        end, options)
        sentry.overheated, sentry.state = 1, Cooldown.STATE_STUCK
        if change then change(sentry) end
        scene.sync()
        look(s, reason)
        sentry.overheated = 0
        scene.sync()
        look(s, reason)
        assert(s.logged('Laser Sentry 721 cooled down; its turret was left as it is (' .. reason), reason .. ': logged')
        local writes = 0
        for _, call in ipairs(s.calls) do if call == 'write' then writes = writes + 1 end end
        assert(writes == 0, reason .. ': nothing written')
        local state, request = scene.turret(sentry)
        assert(state ~= 7 and request ~= 7, reason .. ': not powered up')
        assert(s.instance.guard.running(), reason .. ': the addon keeps running')
    end
end)

check('looks allocate nothing and create no C types: idle in a mission, and while a sentry cools', function()
    local sentry
    local s, scene = mission(function(scene)
        sentry = scene.add({id = 721, sentry = true})
        for id = 1, 6 do scene.add({id = 100 + id, sentry = false}) end
    end)
    local function frames(count) for _ = 1, count do s.env.update(1 / 60) end end
    -- Warm up past LuaJIT's one-time handling of the step's look branch: it tries to compile that exit four
    -- times (every 10 looks), then leaves it to the interpreter for good with a small stub trace. Measured
    -- from there on, as a long session runs.
    frames(100 * WATCH)
    local kb = steady_heap(frames)
    assert(kb == 0, format('idle looks allocated %.3f KB', kb))
    sentry.overheated, sentry.state = 1, Cooldown.STATE_STUCK
    scene.sync()
    frames(4 * WATCH) -- the watch's tables grow on the first of these looks
    kb = steady_heap(frames)
    assert(kb == 0, format('looks while it cools allocated %.3f KB', kb))
    local types = H.ctype_growth(function() frames(5 * WATCH) end)
    assert(types == 0, types .. ' C types created by looks')
end)

check('the live test build logs the turret state: 13 firing, 6 off, 7 powering up', function()
    local hooks = dofile(root .. '/src/test_hooks.lua')
    local sentry
    local s, scene = mission(function(scene) sentry = scene.add({id = 721, sentry = true}) end)
    local saved = print
    print = G.quiet
    hooks(Cooldown, s.instance, s.runtime, s.fake_memory)
    for _ = 1, 12 do s.frame() end
    assert(s.logged('sentry 721 appeared') and s.logged('turret state 13'), 'firing')
    sentry.overheated, sentry.state = 1, Cooldown.STATE_STUCK
    scene.sync()
    for _ = 1, WATCH do s.frame() end -- an overheat lasts about 25 looks; the watch sees it on its next one
    assert(s.logged('overheated 1, firing 0, heat sinks 0, turret state 6'), 'switched off')
    sentry.overheated = 0
    scene.sync()
    for _ = 1, WATCH do s.frame() end -- the watch's look requests state 7
    scene.apply_requests()            -- the game's next behavior update applies it
    for _ = 1, 12 do s.frame() end
    print = saved
    assert(s.logged('turret state 7'), 'powering up')
end)

rawset(_G, 'CowboyBingusModLoader', nil)
print(format('PASS: test_turret.lua (%d checks, %s)', passed, jit and jit.version or _VERSION))
