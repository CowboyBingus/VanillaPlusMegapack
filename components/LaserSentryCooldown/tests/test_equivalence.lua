-- Laser Sentry Cooldown: the published v1.1 code (tests/reference/laser_sentry_cooldown.lua, origin/main at
-- c23099b) and the current code side by side over 3,200 scripted frames on the simulated game
-- (tests/fake_game.lua): menus, the ship, a mission with Laser Sentries overheating, cooling and powering up again,
-- a sentry run on another machine, another heat weapon, a sentry removed while it cools, a refused power-up, an
-- update below that fails (pause, restore, resume), then back to the ship and the menus. Every frame compares the
-- calls of each kind, every page query, protection change and write in order, every log line, the error that
-- reaches the game, the heat record's bytes and protection, and every turret's state and pending request.
-- The current code differs only in that its per-frame step is interpreted (jit.off) instead of left to the
-- compiler; what it does must be identical.
-- Usage: luajit tests/test_equivalence.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_equivalence.lua <repository root>')
local fake_game = dofile(root .. '/tests/fake_game.lua')
local sides = {
    {name = 'v1.1', G = fake_game(root, root .. '/tests/reference/laser_sentry_cooldown.lua')},
    {name = 'current', G = fake_game(root)},
}
-- The start line of the log names the release (v1.1 in the reference): compared under the current one.
sides[1].G.Cooldown.REVISION = sides[2].G.Cooldown.REVISION
local format = string.format
local FRAMES = 3200
local BELOW = 2500 -- the env frame on which the update below raises once

-- Each side's world, scene and session; the scene is created when the script reaches the ship.
for _, side in ipairs(sides) do
    local G = side.G
    side.memory = G.world()
    -- Menus: no WeaponHeat manager yet.
    side.session = G.session({world = side.memory, below = BELOW})
    assert(side.session.instance and side.session.instance.patched, side.name .. ': patched at install')
    side.instances = {}
end

-- The script: what changes in the game on a frame, applied to both sides alike.
local function add(side, key, instance)
    side.instances[key] = side.scene.add(instance)
end
local function set(side, key, fields)
    for name, value in pairs(fields) do side.instances[key][name] = value end
end
local EVENTS = {
    [300] = function(side) side.scene = side.G.scene(side.memory) end, -- the ship: a manager without instances
    [600] = function(side) -- a mission: a sentry run here, one run on another machine, a rifle
        add(side, 'a', {id = 721, sentry = true})
        add(side, 'b', {id = 722, sentry = true, flags = 0})
        add(side, 'rifle', {id = 50, sentry = false})
    end,
    [900] = function(side)
        set(side, 'a', {overheated = 1, state = 6})
        set(side, 'rifle', {overheated = 1})
    end,
    [1300] = function(side) set(side, 'rifle', {overheated = 0}) end,
    [1500] = function(side) set(side, 'a', {overheated = 0}) end, -- cooled: the next look requests state 7
    [1700] = function(side) side.scene.apply_requests() end,     -- the game's behavior update applies it
    [1800] = function(side)
        set(side, 'a', {overheated = 1, state = 6})
        set(side, 'b', {overheated = 1, state = 6})
    end,
    [2000] = function(side) side.scene.remove(side.instances.a); side.instances.a = nil end, -- gone while it cools
    [2100] = function(side) add(side, 'c', {id = 723, sentry = true, overheated = 1, state = 6}) end,
    [2300] = function(side) set(side, 'c', {overheated = 0, request = 3}) end, -- another request pending: refused
    [2400] = function(side) set(side, 'b', {overheated = 0}) end,
    [2700] = function(side) -- back to the ship: no instances
        for key, instance in pairs(side.instances) do side.scene.remove(instance); side.instances[key] = nil end
    end,
    [2900] = function(side) -- the menus: the manager pointer cleared
        side.memory.poke(side.G.GAME + side.G.Cooldown.HEAT_MANAGER_RVA, side.G.le64(0))
    end,
}

-- Everything observable on one side after a frame, as one string.
local function observe(side, counts, ok, problem)
    local s, G = side.session, side.G
    local parts = {G.budget.describe(counts), tostring(ok), type(problem) == 'table' and tostring(problem.hostile_vm)
                   or tostring(problem)}
    parts[#parts + 1] = table.concat(s.calls, ',')
    parts[#parts + 1] = table.concat(s.lines, '|')
    parts[#parts + 1] = tostring(s.record_change()) .. '/' .. tostring(s.memory.block.protection)
    local keys = {}
    for key in pairs(side.instances) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local instance = side.instances[key]
        if instance.block then
            local state, request, last = side.scene.turret(instance)
            parts[#parts + 1] = format('%s:%d/%d/%d', key, state, request, last)
        end
    end
    local instance = s.instance
    parts[#parts + 1] = format('%s/%s/%d/%d', instance.status, tostring(instance.patched), instance.writes,
                               instance.watch.repairs)
    return table.concat(parts, ' ; ')
end

local saved_print = print
local looks_with_calls = 0
for frame = 1, FRAMES do
    local seen = {}
    for i, side in ipairs(sides) do
        local event = EVENTS[frame]
        if event then
            event(side)
            if side.scene then side.scene.sync() end
        end
        local ok, counts = pcall(side.session.frame)
        print = saved_print
        local problem
        if not ok then problem, counts = counts, {} end
        seen[i] = observe(side, counts, ok, problem)
    end
    assert(seen[1] == seen[2], format('frame %d differs:\n  %s: %s\n  %s: %s', frame, sides[1].name, seen[1],
                                      sides[2].name, seen[2]))
    if not seen[2]:find('^no api calls') then looks_with_calls = looks_with_calls + 1 end
end

-- The script reached what it is for: a repair, a refused power-up, a pause with its resume, the menus again.
local s = sides[2].session
local repairs = s.instance.watch.repairs
assert(repairs == 1, 'one repair: ' .. repairs)
assert(s.logged('Laser Sentry 721 cooled down: its turret powers up again.'), 'repair logged')
assert(s.logged('Laser Sentry 723 cooled down; its turret was left as it is (turret state 3 already requested'),
       'refusal logged')
assert(s.logged('Paused ('), 'paused')
assert(s.instance.patched and s.instance.status == 'active', 'resumed: ' .. s.instance.status)
assert(looks_with_calls > 20, 'frames with calls: ' .. looks_with_calls)

rawset(_G, 'CowboyBingusModLoader', nil)
print(format('PASS: test_equivalence.lua (%d frames, %d with calls, %s)', FRAMES, looks_with_calls,
             jit and jit.version or _VERSION))
