-- Laser Sentry Cooldown: resolution, checks, the write, every refusal, the update guard (pause, resume,
-- stop, shutdown) and the exact Windows calls per frame, in a simulated address space seeded with the live
-- heat-table bytes of Steam build 25480438 (tests/fake_game.lua, tests/heat_fixture.lua). Runs in a LuaJIT 2.1
-- and in the game's lua51.dll (tests/game_lua.py).
-- Usage: luajit tests/test_cooldown.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_cooldown.lua <repository root>')
local G = dofile(root .. '/tests/fake_game.lua')(root)
local budget, H, fixture, Cooldown = G.budget, G.H, G.fixture, G.Cooldown
local format = string.format
local MEM_IMAGE = G.MEM_IMAGE
local PAGE_READONLY, PAGE_READWRITE, PAGE_EXECUTE_READ = G.PAGE_READONLY, G.PAGE_READWRITE, G.PAGE_EXECUTE_READ
local GAME, ROOT, HEAT = G.GAME, G.ROOT, G.HEAT
local HEADER, SLOTS, RECORD, RECORD_ADDRESS = G.HEADER, G.SLOTS, G.RECORD, G.RECORD_ADDRESS
local le32, le64, u32 = G.le32, G.le64, G.u32
local world, fake_api, session, quiet = G.world, G.fake_api, G.session, G.quiet
-- The change's bytes, both ranges joined as session.record_change() returns them: the record's own idle cooling
-- rate (f32 at 0x80) then needs_reload_after_overheat 0 at 0x8C; overheat_ability 0 at 0x248.
local COOLING = RECORD:sub(Cooldown.IDLE_COOLING_OFFSET + 1, Cooldown.IDLE_COOLING_OFFSET + 4) .. '\0'
local PATCHED = COOLING .. Cooldown.ABILITY_NONE
local VANILLA = G.VANILLA
-- The record with the whole change in place.
local PATCHED_RECORD = RECORD:sub(1, 0x8C) .. COOLING .. RECORD:sub(0x92, 0x248) .. Cooldown.ABILITY_NONE
    .. RECORD:sub(0x24D)
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

-- The writes a patch makes, in order: one page query, protection to read-write and back over the span of both
-- ranges, and a write per range inside it.
local PATCH_CALLS = {'page', 'protect 4', 'write', 'write', 'protect 2'}
-- Calls of a frame that finds the table and writes: root and table pointers, header, slots and record, the
-- writes, and one read-back of both. write = 2 (v1.0: 1): v1.1 also writes the overheat ability, a second range
-- of the record 444 bytes after the first, in the same read-write window. The read-back is a view (v1.0: a
-- read): one ReadProcessMemory either way, into the reused view buffer instead of a new string. Patch frames
-- only (once per session, and after a resume).
local PATCH_FRAME = {u64 = 2, read = 3, view = 1, page = 1, protect = 2, write = 2}

-- Runs count frames once the change is in place, each with exactly the calls an idle frame makes: none, except
-- on the turret watch's look (every WATCH_FRAMES frames), its first read: the WeaponHeat manager pointer, which
-- this world does not have, so the look stops there. view = 0, u64 = 1 per look (tests/test_turret.lua covers
-- the watch itself).
local function idle_frames(s, count, label)
    for frame = 1, count do
        local looks = s.instance.frames + 1 >= s.instance.interval
        expect_counts(s.frame(), looks and {u64 = 1} or {}, label .. ' frame ' .. frame)
    end
end

check('constants match the live data', function()
    assert(COOLING == '\0\0\160\64\0', 'the cooling change: the live idle cooling rate 5.0 (f32 0x40A00000), then 0')
    assert(Cooldown.f32_value(COOLING) == 5, 'idle cooling rate 5 heat/s: 50 s from max heat 250')
    local found, edits = Cooldown.inspect(fake_api(world()), RECORD_ADDRESS)
    assert(found == 'vanilla' and #edits == 2, 'inspect returns the change as two edits')
    assert(edits[1][1] == 0x8C and edits[1][2] == COOLING, 'edit 1: the cooling rule')
    assert(edits[2][1] == 0x248 and edits[2][2] == '\0\0\0\0', 'edit 2: no overheat ability')
    assert(RECORD:sub(Cooldown.COOLING_OFFSET + 1, Cooldown.COOLING_OFFSET + 5) == Cooldown.COOLING_VANILLA,
           'the live record holds the vanilla cooling bytes')
    assert(RECORD:sub(Cooldown.ABILITY_OFFSET + 1, Cooldown.ABILITY_OFFSET + 4) == Cooldown.ABILITY_VANILLA
           and u32(RECORD, Cooldown.ABILITY_OFFSET) == 2866, 'the live record names overheat ability 2866')
    assert(Cooldown.INSPECT_SIZE == 588 and #PATCHED_RECORD == Cooldown.RECORD_SIZE, 'sizes')
    assert(Cooldown.first_slot(Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH) == 10, 'first slot of the resource')
    assert(Cooldown.find_index(SLOTS, Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH) == fixture.index,
           'probing finds the live index')
    assert(u32(HEADER, 8) == Cooldown.HEADER_TYPE and u32(HEADER, 0) == Cooldown.HEADER_MAGIC, 'live header')
    assert(Cooldown.locate(fake_api(world()), HEAT) == RECORD_ADDRESS, 'record address')
    assert(Cooldown.inspect(fake_api(world()), RECORD_ADDRESS) == 'vanilla', 'live record is vanilla')
end)

-- Reported 2026-10-05 (v1.0, in a mission): "it overheated and exploded mid-match". The explosion is the record's
-- overheat ability (2866), which the game plays on the sentry the moment it overheats (0x763780); the cooling
-- rule cannot stop it. Agreed outcome: with the change in place the record names no overheat ability, so none
-- plays, and the overheated sentry cools at its own idle rate with no reload needed.
check('reported 2026-10-05: an overheated Laser Sentry exploded (v1.0)', function()
    local s = session()
    assert(s.instance.patched, 'patched at install')
    assert(u32(s.memory.peek(G.ABILITY, 4), 0) == 0, 'overheat ability 0: no explosion')
    assert(s.memory.peek(G.COOLING, 5) == COOLING, 'cools at its own idle rate (5/s), no reload needed')
end)

check('probing follows the engine: collisions, wrap-around, an empty slot ends the search', function()
    local entries = {}
    for slot = 0, Cooldown.SLOTS - 1 do entries[slot] = string.rep('\0', 16) end
    local function put(slot, low, high, index) entries[slot] = le32(low) .. le32(high) .. le32(index) .. le32(0) end
    -- The resource's first slot is 10: slots 10 and 11 hold others, so it sits in 12.
    put(10, 1, 2, 3); put(11, 4, 5, 6); put(12, Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH, 7)
    local function joined() local t = {} for slot = 0, Cooldown.SLOTS - 1 do t[#t + 1] = entries[slot] end return table.concat(t) end
    assert(Cooldown.find_index(joined(), Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH) == 7, 'collision chain')
    entries[11] = string.rep('\0', 16)
    assert(Cooldown.find_index(joined(), Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH) == nil, 'empty slot ends it')
    -- A first slot of 57 wraps to 0.
    for slot = 0, Cooldown.SLOTS - 1 do entries[slot] = string.rep('\0', 16) end
    local low, high = 57, 0
    assert(Cooldown.first_slot(low, high) == 57)
    put(57, 9, 9, 1); put(0, low, high, 2)
    assert(Cooldown.find_index(joined(), low, high) == 2, 'wrap-around')
end)

check('installed with the table ready: one write, protection back, then nothing per frame', function()
    local s = session()
    assert(s.instance and s.instance.patched, 'patched at install')
    assert(s.record_change() == PATCHED, 'record holds the change')
    assert(s.memory.block.protection == PAGE_READONLY, 'page read-only again')
    expect_counts(s.install_counts, PATCH_FRAME, 'install')
    assert(table.concat(s.calls, ',') == table.concat(PATCH_CALLS, ','), 'call order ' .. table.concat(s.calls, ','))
    assert(s.logged('heat record changed'), 'logged')
    local looks = 0
    for frame = 1, 300 do
        local counts, below, dt = s.frame()
        local expected = frame % Cooldown.WATCH_FRAMES == 0 and {u64 = 1} or {}
        if expected.u64 then looks = looks + 1 end
        expect_counts(counts, expected, 'patched frame ' .. frame)
        assert(below == 'below' and dt == 1 / 60, 'values pass through')
    end
    assert(looks == 2 and Cooldown.WATCH_FRAMES == 120, 'one look every 120 frames')
    assert(s.env.frames == 300, 'the update below ran every frame')
    assert(rawget(s.env, 'LaserSentryCooldownInstalled') == true, 're-entry flag set')
end)

check('patched frames allocate nothing and create no C types', function()
    local s = session()
    -- The same loop runs first to warm up: its own traces (GC objects) are recorded then, not while measured,
    -- and so is LuaJIT's one-time handling of the step's look branch (four compile attempts, one every 10
    -- looks, then a small stub that leaves the look to the interpreter for good).
    local function frames(count) for _ = 1, count do s.env.update(1 / 60) end end
    frames(100 * Cooldown.WATCH_FRAMES)
    -- The smallest of up to five windows: an allocation of the addon's shows in every one, LuaJIT's once-per-
    -- session work (random backoff) in one at most.
    local kb = math.huge
    for _ = 1, 5 do
        kb = math.min(kb, (H.heap_peak(frames, 2000)))
        if kb == 0 then break end
    end
    assert(kb == 0, format('idle frames allocated %.3f KB', kb))
    local types = H.ctype_growth(function() for _ = 1, 100 do s.env.update(1 / 60) end end)
    assert(types == 0, types .. ' C types per idle frames')
    local flush = H.jit_churn()
    flush()
    idle_frames(s, 250, 'after a JIT flush')
end)

check('boot: waits for the table, one look every 30 frames, then writes once', function()
    local memory = world({root = 0})
    local s = session({world = memory})
    assert(s.instance and not s.instance.patched, 'waiting')
    expect_counts(s.install_counts, {u64 = 1}, 'install without the root pointer')
    assert(s.logged('Waiting for the weapon data'), 'logged the wait')
    for frame = 1, Cooldown.POLL_FRAMES - 1 do expect_counts(s.frame(), {}, 'boot frame ' .. frame) end
    expect_counts(s.frame(), {u64 = 1}, 'poll without the root pointer')
    memory.poke(GAME + Cooldown.ROOT_RVA, le64(ROOT))
    memory.poke(ROOT + Cooldown.TABLE_OFFSET, le64(0))
    for frame = 1, Cooldown.POLL_FRAMES - 1 do expect_counts(s.frame(), {}, 'boot frame ' .. frame) end
    expect_counts(s.frame(), {u64 = 2}, 'poll without the table pointer')
    memory.poke(ROOT + Cooldown.TABLE_OFFSET, le64(HEAT))
    for frame = 1, Cooldown.POLL_FRAMES - 1 do expect_counts(s.frame(), {}, 'boot frame ' .. frame) end
    expect_counts(s.frame(), PATCH_FRAME, 'poll that finds the table')
    assert(s.instance.patched and s.record_change() == PATCHED, 'patched')
    for frame = 1, 100 do expect_counts(s.frame(), {}, 'patched frame ' .. frame) end
end)

-- Every refusal: the guard stopped, the game's update still runs, and (unless expected says otherwise) the
-- record and the page as they were.
local function refused(label, options, expected_calls, reason, expected)
    expected = expected or {}
    local s = session(options)
    -- patched stays true only when the vanilla bytes could not be put back: the record may hold the change.
    assert(s.instance and s.instance.patched == (expected.record_changed == true), label .. ': patched flag')
    assert(s.instance.failure and s.instance.failure:find(reason, 1, true),
           label .. ': failure ' .. tostring(s.instance.failure))
    assert(not s.instance.guard.running(), label .. ': guard stopped')
    assert(s.logged('Disabled: ' .. s.instance.failure), label .. ': logged')
    assert(table.concat(s.calls, ',') == table.concat(expected_calls, ','), label .. ': calls ' .. table.concat(s.calls, ','))
    assert(s.memory.block.protection == (expected.protection or options.protection or PAGE_READONLY),
           label .. ': protection ' .. s.memory.block.protection)
    if not expected.record_changed then
        local record = options.record or RECORD
        assert(s.memory.peek(RECORD_ADDRESS, Cooldown.RECORD_SIZE) == record, label .. ': record untouched')
    end
    for frame = 1, 40 do
        local counts, below = s.frame()
        expect_counts(counts, {}, label .. ' frame ' .. frame)
        assert(below == 'below', label .. ': values pass through')
    end
    return s
end

check('refusals leave the record and the page alone', function()
    local wrong_type = HEADER:sub(1, 8) .. le32(0x12345678) .. HEADER:sub(13)
    refused('header', {header = wrong_type}, {}, 'unexpected heat table header')
    refused('missing resource', {slots = string.rep('\0', #SLOTS)}, {}, 'Laser Sentry heat record not found')
    local small = HEADER:sub(1, 12) .. le32(Cooldown.RECORDS_OFFSET + Cooldown.RECORD_SIZE * fixture.index) .. HEADER:sub(17)
    refused('short table', {header = small}, {}, 'outside the table')
    local hotter = RECORD:sub(1, 0x60) .. le32(0x43960000) .. RECORD:sub(0x65) -- overheat 300
    refused('other overheat temperature', {record = hotter}, {}, 'unexpected Laser Sentry heat record (offset 0x60)')
    local spare = RECORD:sub(1, 0x54) .. le32(1) .. RECORD:sub(0x59)        -- a spare heat sink
    refused('spare heat sinks', {record = spare}, {}, 'offset 0x54')
    local frozen = RECORD:sub(1, 0x80) .. le32(0) .. RECORD:sub(0x85)      -- no idle cooling to copy
    refused('no idle cooling rate', {record = frozen}, {}, 'unexpected Laser Sentry cooling rate')
    local nan = RECORD:sub(1, 0x80) .. le32(0x7FC00000) .. RECORD:sub(0x85) -- NaN
    refused('NaN idle cooling rate', {record = nan}, {}, 'unexpected Laser Sentry cooling rate')
    local other = RECORD:sub(1, 0x8C) .. le32(0x3F800000) .. RECORD:sub(0x91) -- 1.0 heat/s from someone else
    refused('changed by something else', {record = other}, {}, 'already changed by something else')
    local ability = RECORD:sub(1, 0x248) .. le32(1234) .. RECORD:sub(0x24D)  -- another overheat ability
    refused('ability changed by something else', {record = ability}, {}, 'already changed by something else')
    -- One range changed and the other vanilla is not this addon's work (it writes both or neither).
    local half = RECORD:sub(1, 0x8C) .. COOLING .. RECORD:sub(0x92)
    refused('only the cooling range changed', {record = half}, {}, 'already changed by something else')
    local s = refused('image page', {kind = MEM_IMAGE}, {'page'}, 'not committed private memory')
    assert(s.record_change() == VANILLA, 'unchanged')
    refused('executable page', {protection = PAGE_EXECUTE_READ}, {'page'}, 'unexpected page protection 0x20')
    refused('page query', {failures = {query = true}}, {'page'}, 'page query failed')
    refused('protection refused', {failures = {protect = true}}, {'page', 'protect 4'}, 'page protection change refused')
    -- The first write fails: the second is not tried and nothing landed.
    s = refused('write fails', {failures = {write = true}}, {'page', 'protect 4', 'write', 'protect 2'}, 'write failed')
    assert(s.record_change() == VANILLA, 'unchanged after a failed write')
    -- The first range landed and the second write failed: the stop puts the vanilla bytes of both back.
    local landed_once = {'page', 'protect 4', 'write', 'write', 'protect 2', 'page', 'protect 4', 'write', 'write',
                         'protect 2'}
    s = refused('second write fails', {failures = {second_write = true}}, landed_once, 'write failed')
    assert(s.record_change() == VANILLA and s.memory.block.protection == PAGE_READONLY, 'vanilla again, read-only')
    -- The writes landed but the protection could not be put back: the stop writes the vanilla bytes again
    -- (the page is still read-write, so directly) and the page stays read-write.
    local after_lost = {'page', 'protect 4', 'write', 'write', 'protect 2', 'page', 'write', 'write'}
    s = refused('protection not restored', {failures = {restore = true}}, after_lost, 'could not be restored',
                {protection = PAGE_READWRITE})
    assert(s.instance.protection_lost and s.record_change() == VANILLA, 'flagged, vanilla again')
    -- The writes landed but read back wrong: the stop tries the vanilla bytes, which fail the same way here.
    local twice = {'page', 'protect 4', 'write', 'write', 'protect 2', 'page', 'protect 4', 'write', 'write',
                   'protect 2'}
    s = refused('no read-back', {failures = {garble = true}}, twice, 'did not read back', {record_changed = true})
    assert(s.logged('restore failed: write did not read back'), 'the failed restore is logged')
end)

check('a read-write page is written directly', function()
    local s = session({protection = PAGE_READWRITE})
    assert(s.instance.patched and s.record_change() == PATCHED)
    assert(table.concat(s.calls, ',') == 'page,write,write', table.concat(s.calls, ','))
    -- write = 2: both ranges; view = 1: the read-back (see PATCH_FRAME).
    expect_counts(s.install_counts, {u64 = 2, read = 3, view = 1, page = 1, write = 2}, 'read-write install')
end)

check('a record that already holds the change is kept without a write', function()
    local s = session({record = PATCHED_RECORD})
    assert(s.instance.patched and #s.calls == 0, 'no write')
    expect_counts(s.install_counts, {u64 = 2, read = 3}, 'already patched')
    assert(s.logged('already changed'), 'logged')
end)

check('an update below that fails pauses (vanilla back), resume writes again', function()
    local s = session({below = 5})
    for _ = 1, 4 do expect_counts(s.frame(), {}, 'before the failure') end
    local ok, problem = pcall(s.env.update, 1 / 60)
    assert(not ok and type(problem) == 'table' and problem.hostile_vm == 'throw_below', 'the error below reaches the game')
    for i = 1, #s.calls do s.calls[i] = nil end
    local counts = s.frame()
    expect_counts(counts, {page = 1, protect = 2, write = 2, view = 1}, 'pause restores both ranges')
    assert(s.record_change() == VANILLA and s.memory.block.protection == PAGE_READONLY, 'vanilla, read-only')
    assert(s.instance.guard.status.state:find('paused', 1, true), 'paused: ' .. s.instance.guard.status.state)
    local frames = 0
    repeat
        frames = frames + 1
        counts = s.frame()
        if not s.instance.patched then expect_counts(counts, {}, 'paused frame ' .. frames) end
    until s.instance.patched or frames > 200
    assert(s.instance.patched and s.record_change() == PATCHED, 'patched again after the resume')
    expect_counts(counts, PATCH_FRAME, 'the resume frame writes again')
    assert(frames <= 62, 'resumed after ' .. frames .. ' frames')
    for frame = 1, 50 do expect_counts(s.frame(), {}, 'resumed frame ' .. frame) end
end)

check('a stop restores the vanilla bytes; shutdown restores nothing', function()
    local s = session()
    local saved = print
    print = quiet
    s.instance.guard.stop('test stop')
    print = saved
    assert(s.record_change() == VANILLA and s.memory.block.protection == PAGE_READONLY, 'restored on stop')
    assert(s.logged('Stopped (test stop)'), 'logged')
    for frame = 1, 20 do expect_counts(s.frame(), {}, 'stopped frame ' .. frame) end
    local t = session()
    local saved_print = print
    print = quiet
    local value = t.env.shutdown()
    print = saved_print
    assert(value == 'closed' and t.env.shut, 'shutdown passes through')
    assert(t.record_change() == PATCHED, 'nothing restored at shutdown')
    assert(t.logged('Shutdown: active'), 'shutdown status logged')
end)

check('disabled without the right build, loader or modules: no guard, no read', function()
    for _, case in ipairs({{'bad build', {bad_build = true}, 'unsupported game build (needs Steam build 25480438)'},
                           {'no loader', {loader = false}, 'Bingus Shared Loader v18+ / API 1 required'},
                           {'old loader', {loader = {api = 1, open_log = function() end}}, 'Bingus Shared Loader v18+'},
                           {'no modules', {no_modules = true}, 'game modules unavailable'}}) do
        local s = session(case[2])
        assert(s.instance == nil, case[1] .. ': disabled')
        expect_counts(s.install_counts, {}, case[1])
        assert(not rawget(s.env, 'LaserSentryCooldownInstalled'), case[1] .. ': no flag')
        local _, below = s.frame()
        assert(below == 'below', case[1] .. ': update untouched')
        if case[2].loader == nil then assert(s.logged('Disabled: ' .. case[3]), case[1] .. ': logged') end
    end
end)

check('hostile update chain neighbours above the addon do not change its work', function()
    for _, kind in ipairs({'double_call', 'drop_args', 'skip_odd_frames', 'rehook'}) do
        local s = session()
        H.chain(s.env, kind)
        for frame = 1, 30 do
            local counts = s.frame()
            expect_counts(counts, {}, kind .. ' frame ' .. frame)
        end
        assert(s.instance.patched and s.record_change() == PATCHED, kind)
        H.chain_restore(s.env)
    end
end)

rawset(_G, 'CowboyBingusModLoader', nil)
print(format('PASS: test_cooldown.lua (%d checks, %s)', passed, jit and jit.version or _VERSION))
