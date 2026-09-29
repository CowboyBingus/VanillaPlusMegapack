-- Scanner logic against fake game memory, with exact per-frame call budgets.
-- Usage: test_scanner.lua <src directory> [scanner source to test instead]
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')

-- Fake memory. Direct loads (load32/load64) must only touch mapped memory:
-- the game image, or an object read32 has confirmed. Anything else is a
-- fault the real game would take, so the test fails.
local GAME, IMAGE_SIZE = 0x7ff600000000, 0x4744000
local CONFIG_PTR, MATCHMAKING_PTR = GAME + 0x347cee0, GAME + 0x347ce80
local FIELD, COUNTDOWN = 0x3ce4c, 0x10bd74
local CONFIG, OTHER_CONFIG, MATCHMAKING, UNMAPPED = 0x1bebe929838, 0x1bec0000008, 0x1bebeed4cd0, 0x1bf00000000

local function new_world()
    local w = {u32 = {}, f32 = {}, u64 = {}, objects = {}, writable = {}, confirmed = {},
               fail_write = false, fail_read = false, direct_faults = 0}
    function w.map(base, size, writable)
        w.objects[#w.objects + 1] = {base = base, size = size, writable = writable ~= false}
    end
    function w.object_at(address)
        for _, o in ipairs(w.objects) do
            if address >= o.base and address < o.base + o.size then return o end
        end
    end
    w.map(CONFIG, 0x40000); w.map(OTHER_CONFIG, 0x40000); w.map(MATCHMAKING, 0x110000)
    w.u32[CONFIG + FIELD] = 20; w.u32[OTHER_CONFIG + FIELD] = 20; w.f32[MATCHMAKING + COUNTDOWN] = 0
    w.u64[CONFIG_PTR] = CONFIG; w.u64[MATCHMAKING_PTR] = MATCHMAKING
    return w
end

local world
local api = {}
local function direct(address)
    if address >= GAME and address < GAME + IMAGE_SIZE then return end
    local o = world.object_at(address)
    if not (o and world.confirmed[o]) then error(string.format('direct load of unconfirmed memory %x', address)) end
end
function api.load32(address) direct(address); assert(address % 4 == 0); return world.u32[address] or 0 end
function api.load64(address) direct(address); assert(address % 8 == 0); return world.u64[address] or 0 end
function api.read32(address)
    local o = world.object_at(address)
    if world.fail_read or not o then return nil end
    world.confirmed[o] = true
    return world.u32[address] or 0
end
function api.read_f32(address)
    local o = world.object_at(address)
    if world.fail_read or not o then return nil end
    return world.f32[address] or 0
end
function api.writable_data(address, size)
    api.queries = api.queries + 1
    local o = world.object_at(address)
    return o ~= nil and o.writable and address + size <= o.base + o.size
end
function api.write32(address, value)
    if not api.writable_data(address, 4) then return false end
    if world.fail_write then return false end
    if not world.lose_write then world.u32[address] = value end
    return true
end
function api.write_f32(address, value)
    if not api.writable_data(address, 4) then return false end
    if world.fail_write then return false end
    world.f32[address] = value
    return true
end
api.queries = 0
local counts = budget.wrap(api)

local function load_scanner(path)
    local chunk = assert(loadfile(path))
    return chunk()
end
local Scanner

-- One scanner per scenario; frame(limits, label) runs one check and pins its calls.
local function start()
    world = new_world()
    local s = {}
    return Scanner.new(api, GAME, s), s
end
local function frame(scanner, limits, label)
    local calls, result = budget.frame(counts, scanner.check)
    local ok, err = pcall(budget.check, calls, limits, label)
    if not ok then error(err .. ' (' .. budget.describe(calls) .. ')', 0) end
    for name, limit in pairs(limits) do
        assert((calls[name] or 0) == limit, label .. ': expected ' .. name .. '=' .. limit .. ', got '
            .. budget.describe(calls))
    end
    return result
end

local IDLE = {load64 = 1, load32 = 1}
local FIRST = {load64 = 2, read32 = 1, load32 = 2, write32 = 1, writable_data = 1, read_f32 = 1}
local REWRITE = {load64 = 2, load32 = 2, write32 = 1, writable_data = 1, read_f32 = 1}
local SHORTEN = {load64 = 2, load32 = 2, write32 = 1, writable_data = 2, read_f32 = 1, write_f32 = 1}

local function suite()
    -- Boot: no config object yet; one direct load of game.dll's global.
    local scanner, s = start()
    world.u64[CONFIG_PTR] = 0
    frame(scanner, {load64 = 1}, 'boot')
    assert(s.status == 'waiting_for_config' and s.writes == 0)
    frame(scanner, {load64 = 1}, 'boot again')

    -- First sight: confirm the object once, write the default (5 s), look at the countdown.
    world.u64[CONFIG_PTR] = CONFIG
    local revision = s.revision
    frame(scanner, FIRST, 'first sight')
    assert(world.u32[CONFIG + FIELD] == 5 and s.status == 'active' and s.game_value == 20 and s.applied == 5)
    assert(s.writes == 1 and s.refreshes == 0 and s.shortened == 0 and s.revision > revision)

    -- Idle: two direct loads, nothing else, for as long as nothing changes.
    revision = s.revision
    for i = 1, 5 do frame(scanner, IDLE, 'idle ' .. i) end
    assert(s.revision == revision, 'idle checks must not move the revision')

    -- The game's config response rewrites its usual 20: write 5 again. Routine,
    -- so the revision (what the addon logs on) stays where it was.
    world.u32[CONFIG + FIELD] = 20
    frame(scanner, REWRITE, 'game rewrite')
    assert(world.u32[CONFIG + FIELD] == 5 and s.refreshes == 1 and s.writes == 2 and s.revision == revision)
    frame(scanner, IDLE, 'idle after rewrite')

    -- A rewrite that raced a scan result: the countdown already holds 20.
    world.u32[CONFIG + FIELD] = 20; world.f32[MATCHMAKING + COUNTDOWN] = 19.5
    frame(scanner, SHORTEN, 'rewrite with a long countdown')
    assert(world.f32[MATCHMAKING + COUNTDOWN] == 5 and s.shortened == 1)

    -- The server changes its value: the mod follows the new game value (logged).
    world.u32[CONFIG + FIELD] = 12; world.f32[MATCHMAKING + COUNTDOWN] = 0.4
    revision = s.revision
    frame(scanner, REWRITE, 'new server value')
    assert(s.game_value == 12 and world.u32[CONFIG + FIELD] == 5 and s.revision > revision)

    -- Setting change: applied on the next check, and a longer countdown is shortened.
    revision = s.revision
    assert(scanner.set_setting(8) and s.revision > revision)
    world.f32[MATCHMAKING + COUNTDOWN] = 9.25
    frame(scanner, SHORTEN, 'setting 8')
    assert(world.u32[CONFIG + FIELD] == 8 and world.f32[MATCHMAKING + COUNTDOWN] == 8 and s.setting == 8)
    frame(scanner, IDLE, 'idle at 8')
    -- A countdown already shorter than the setting is left alone.
    assert(scanner.set_setting(6)); world.f32[MATCHMAKING + COUNTDOWN] = 2.5
    frame(scanner, REWRITE, 'setting 6, short countdown')
    assert(world.f32[MATCHMAKING + COUNTDOWN] == 2.5 and world.u32[CONFIG + FIELD] == 6)
    world.f32[MATCHMAKING + COUNTDOWN] = 0 -- a scan started
    -- The same setting again changes nothing.
    revision = s.revision
    assert(scanner.set_setting(6) and s.revision == revision)
    frame(scanner, IDLE, 'same setting')

    -- A setting at or above the game's value restores the game's value; never longer.
    assert(scanner.set_setting(20))
    frame(scanner, {load64 = 1, load32 = 2, write32 = 1, writable_data = 1}, 'setting above game value')
    assert(world.u32[CONFIG + FIELD] == 12 and s.status == 'game_value_kept' and s.applied == 12)
    frame(scanner, IDLE, 'idle at game value')
    world.u32[CONFIG + FIELD] = 20 -- server back to 20: the setting 20 matches it, no write
    frame(scanner, {load64 = 1, load32 = 1}, 'server back to 20')
    assert(world.u32[CONFIG + FIELD] == 20 and s.game_value == 20 and s.status == 'game_value_kept')
    assert(scanner.set_setting(5))
    frame(scanner, REWRITE, 'back to 5')
    assert(world.u32[CONFIG + FIELD] == 5)

    -- Settings are whole seconds in 5..20; nonsense is refused.
    assert(scanner.set_setting(0.2) and s.setting == 5)
    assert(scanner.set_setting(1) and s.setting == 5)
    assert(scanner.set_setting(4.4) and s.setting == 5)
    assert(scanner.set_setting(7.6) and s.setting == 8)
    assert(scanner.set_setting(99) and s.setting == 20)
    assert(not scanner.set_setting(0 / 0) and not scanner.set_setting('5') and not scanner.set_setting(nil))
    assert(scanner.set_setting(5))
    frame(scanner, {load64 = 1, load32 = 1}, 'net setting unchanged')

    -- A server value below the shortest setting is the game's choice: kept, not flagged.
    world.u32[CONFIG + FIELD] = 3
    frame(scanner, {load64 = 1, load32 = 1}, 'server value 3')
    assert(world.u32[CONFIG + FIELD] == 3 and s.game_value == 3 and s.status == 'game_value_kept' and s.applied == 3)
    frame(scanner, IDLE, 'idle at server value 3')

    -- Implausible game values are left alone, then idle; a sane value resumes.
    for _, bad in ipairs({0, 3601, 0xffffffff}) do
        world.u32[CONFIG + FIELD] = bad
        frame(scanner, {load64 = 1, load32 = 1}, 'bad game value ' .. bad)
        local expected = bad == 0 and 'waiting_for_game_value' or 'unexpected_game_value'
        assert(world.u32[CONFIG + FIELD] == bad and s.status == expected and s.applied == nil, s.status)
        frame(scanner, IDLE, 'idle on bad value ' .. bad)
    end
    world.u32[CONFIG + FIELD] = 20
    frame(scanner, REWRITE, 'sane value again')
    assert(world.u32[CONFIG + FIELD] == 5 and s.status == 'active')

    -- A new config object: confirmed once, its own value is the game's (a
    -- switch is not a rewrite), then the same idle path.
    local refreshes = s.refreshes
    world.u64[CONFIG_PTR] = OTHER_CONFIG
    frame(scanner, FIRST, 'new config object')
    assert(world.u32[OTHER_CONFIG + FIELD] == 5 and s.refreshes == refreshes and s.game_value == 20)
    frame(scanner, IDLE, 'idle on new object')

    -- Object gone and back: confirmed again, still the mod's value, nothing to write.
    world.u64[CONFIG_PTR] = 0
    frame(scanner, {load64 = 1}, 'object gone')
    assert(s.status == 'waiting_for_config')
    revision = s.revision
    frame(scanner, {load64 = 1}, 'still gone')
    assert(s.revision == revision, 'waiting frames must not move the revision')
    world.u64[CONFIG_PTR] = OTHER_CONFIG
    frame(scanner, {load64 = 1, read32 = 1, load32 = 1}, 'same object back')
    assert(s.status == 'active' and s.applied == 5 and s.game_value == 20 and s.writes == 10)
    frame(scanner, IDLE, 'idle on returned object')
    -- An unreadable pointer is never loaded directly and is asked again next frame.
    world.u64[CONFIG_PTR] = UNMAPPED
    frame(scanner, {load64 = 1, read32 = 1}, 'unreadable object')
    assert(s.status == 'waiting_for_config_read')
    frame(scanner, {load64 = 1, read32 = 1}, 'unreadable object again')
    world.u64[CONFIG_PTR] = 0x1234 -- not a heap pointer: not even read
    frame(scanner, {load64 = 1}, 'implausible pointer')
    world.u64[CONFIG_PTR] = CONFIG + 4 -- misaligned
    frame(scanner, {load64 = 1}, 'misaligned pointer')
    world.u64[CONFIG_PTR] = OTHER_CONFIG
    frame(scanner, {load64 = 1, read32 = 1, load32 = 1}, 'readable again')
    assert(s.status == 'active' and s.writes == 10)

    -- Another writer fighting over the field: the mod stops instead of writing every frame.
    local limit = Scanner.REWRITE_LIMIT
    Scanner.REWRITE_LIMIT = s.refreshes + 3
    for i = 1, 3 do
        world.u32[OTHER_CONFIG + FIELD] = 7
        frame(scanner, REWRITE, 'contended ' .. i)
    end
    world.u32[OTHER_CONFIG + FIELD] = 7
    assert(frame(scanner, {load64 = 1, load32 = 1}, 'contention limit') == false)
    assert(s.status == 'field_contended' and world.u32[OTHER_CONFIG + FIELD] == 7)
    assert(frame(scanner, {}, 'stopped after contention') == false)
    Scanner.REWRITE_LIMIT = limit

    -- A new object whose own value (5) equals what the mod wrote to the old
    -- one: that is the game's value now, so a setting of 8 must not lengthen it.
    local fresh, fs = start()
    frame(fresh, FIRST, 'before the third object')
    local THIRD = 0x1bec1000000
    world.map(THIRD, 0x40000); world.u32[THIRD + FIELD] = 5
    world.u64[CONFIG_PTR] = THIRD
    frame(fresh, {load64 = 1, read32 = 1, load32 = 1}, 'third object')
    assert(fs.game_value == 5 and fs.status == 'game_value_kept' and fs.refreshes == 0)
    assert(fresh.set_setting(8))
    frame(fresh, {load64 = 1, load32 = 1}, 'setting above the third object value')
    assert(world.u32[THIRD + FIELD] == 5 and fs.applied == 5 and fs.writes == 1)

    -- No matchmaking object yet: the countdown is not touched.
    fresh, fs = start()
    world.u64[MATCHMAKING_PTR] = 0
    frame(fresh, {load64 = 2, read32 = 1, load32 = 2, write32 = 1, writable_data = 1}, 'no matchmaking object')
    assert(fs.status == 'active')
    -- Unreadable countdown: left alone, still active.
    fresh, fs = start()
    world.f32[MATCHMAKING + COUNTDOWN] = 15; world.objects[3].base = UNMAPPED
    world.u64[MATCHMAKING_PTR] = MATCHMAKING
    frame(fresh, FIRST, 'unreadable countdown')
    assert(fs.status == 'active' and fs.shortened == 0)
    -- A countdown the page check refuses: one recharge stays long, the mod stays active.
    fresh, fs = start()
    world.f32[MATCHMAKING + COUNTDOWN] = 15; world.objects[3].writable = false
    frame(fresh, {load64 = 2, read32 = 1, load32 = 2, write32 = 1, writable_data = 2, read_f32 = 1, write_f32 = 1},
        'countdown not writable')
    assert(fs.status == 'active' and fs.shortened == 0 and world.f32[MATCHMAKING + COUNTDOWN] == 15)
    -- NaN and absurd countdowns are left alone.
    for _, value in ipairs({0 / 0, 5000, -3}) do
        fresh, fs = start()
        world.f32[MATCHMAKING + COUNTDOWN] = value
        frame(fresh, FIRST, 'countdown ' .. tostring(value))
        assert(fs.shortened == 0)
    end

    -- A refused config write stops the mod: nothing more is read or written.
    fresh, fs = start()
    world.fail_write = true
    assert(frame(fresh, {load64 = 1, read32 = 1, load32 = 1, write32 = 1, writable_data = 1}, 'refused write') == false)
    assert(fs.status == 'config_write_failed' and world.u32[CONFIG + FIELD] == 20)
    world.fail_write = false
    assert(frame(fresh, {}, 'stopped') == false)
    -- A write the read-back does not confirm also stops it.
    fresh, fs = start()
    world.lose_write = true
    frame(fresh, {load64 = 1, read32 = 1, load32 = 2, write32 = 1, writable_data = 1}, 'lost write')
    assert(fs.status == 'config_write_failed' and world.u32[CONFIG + FIELD] == 20)

    -- stop() puts the game's value back only while the field holds the mod's value.
    fresh, fs = start()
    frame(fresh, FIRST, 'before stop')
    assert(fresh.stop('stopped_after_error') and world.u32[CONFIG + FIELD] == 20)
    assert(fs.status == 'stopped_after_error' and fresh.check() == false)
    fresh, fs = start()
    frame(fresh, FIRST, 'before stop 2')
    world.u32[CONFIG + FIELD] = 25 -- the game wrote meanwhile: its value stays
    assert(fresh.stop('x') and world.u32[CONFIG + FIELD] == 25)
    fresh, fs = start()
    world.u64[CONFIG_PTR] = 0
    frame(fresh, {load64 = 1}, 'stop before config')
    assert(fresh.stop('x'))
    fresh, fs = start()
    assert(fresh.set_setting(20))
    frame(fresh, {load64 = 1, read32 = 1, load32 = 1}, 'setting equals game value')
    assert(fs.status == 'game_value_kept' and fs.applied == 20 and fs.writes == 0)
    assert(fresh.stop('x') and world.u32[CONFIG + FIELD] == 20)
end

-- Garbage: 100,000 idle checks allocate nothing.
local function garbage()
    local scanner = start()
    scanner.check()
    for _ = 1, 1000 do scanner.check() end
    collectgarbage('collect'); collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 100000 do scanner.check() end
    local used = collectgarbage('count') - before
    collectgarbage('restart')
    return used
end

local chosen = arg[2]
Scanner = load_scanner(chosen or (source .. '/scanner.lua'))
if chosen then
    -- Mutation run: report whether the suite notices.
    local ok = pcall(suite)
    print(ok and 'SURVIVED' or 'CAUGHT')
    return
end
suite()
print('PASS: boot, first sight, idle, game rewrites, raced countdowns, server value changes, settings, '
    .. 'bad values, object changes, unreadable memory, refused writes and stop/restore, with exact call budgets')
local used = garbage()
assert(used < 1, 'idle checks allocated ' .. used .. ' KB')
print(string.format('PASS: 100,000 idle checks allocated %.3f KB', used))
