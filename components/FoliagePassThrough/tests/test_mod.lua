-- Offline tests for Foliage Pass-Through's change: the real Bingus Shared Runtime (reads, page checks and writes on
-- this test process) against synthetic projectile settings in FFI memory, with exact per-scenario call budgets.
-- Usage: luajit tests/test_mod.lua <project root>   (also run in the game's lua51.dll by scripts/build.py)
local root = assert(arg[1], 'project root required')
local H = dofile(root .. '/tests/hostile_vm.lua')
-- A mod that loaded first declared the plain Windows names with a wrong prototype; the runtime's private names must
-- keep working.
local clash = H.clash({'GetModuleHandleA', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
                       'WriteProcessMemory'})
local ffi = require('ffi')
local budget = dofile(root .. '/tests/frame_budget.lua')
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local memory = dofile(root .. '/src/bingus_memory.lua')
local writes = dofile(root .. '/src/bingus_write.lua')
local Mod = dofile(root .. '/src/foliage_pass_through.lua')
local TARGETS = dofile(root .. '/src/foliage_targets.lua')
local PRINT_BUDGETS = os.getenv('FPT_PRINT_BUDGETS') ~= nil
local passed = 0

local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function le64(v) return le32(v % 4294967296) .. le32(math.floor(v / 4294967296)) end

local function pin(frame, limits, label)
    if PRINT_BUDGETS then print(label .. ': ' .. budget.describe(frame)) end
    budget.check(frame, limits, label)
    for name, limit in pairs(limits) do
        assert((frame[name] or 0) == limit, label .. ': api.' .. name .. ' ' .. tostring(frame[name])
            .. ' calls, pinned ' .. limit)
    end
end

-- Synthetic game ----------------------------------------------------------------------------------------------

local LAYOUT = {buffer_rva = 0x10, index_rva = 0x40, slots = 351, row_size = 0x110}
local ROW = LAYOUT.row_size
local OTHER = {type = 300, name = 0x12345678, explosion = 77, template = 0} -- an enemy row: never touched

local keep = {}
local function block(size)
    local bytes = ffi.new('uint8_t[?]', size)
    keep[#keep + 1] = bytes
    return ffi.cast('uint8_t *', bytes)
end
local function address(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end
local function put(pointer, offset, bytes) ffi.copy(pointer + offset, bytes, #bytes) end
local function get32(pointer, offset)
    local s = ffi.string(pointer + offset, 4)
    local a, b, c, d = s:byte(1, 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- The loaded settings: one buffer of rows in type order, the index, and the buffer pointer. options change one
-- thing at a time: template (every target's), mismatch = {type, field}, not_loaded, missing (a target type).
local function World(targets, options)
    options = options or {}
    local w = {game = block(0x40 + LAYOUT.slots * 8 + 0x100), rows = {}, targets = targets}
    local all = {}
    for _, t in ipairs(targets) do all[#all + 1] = {type = t[1], name = t[2], explosion = t[3]} end
    all[#all + 1] = OTHER
    w.buffer = block(#all * ROW + 64)
    for i, r in ipairs(all) do
        local row = w.buffer + 64 + (i - 1) * ROW
        put(row, 0x00, le32(r.type))
        put(row, 0x08, le32(r.name))
        put(row, 0x90, le32(r.explosion))
        put(row, 0xF4, le32(r.template or options.template or 0))
        if options.mismatch and options.mismatch.type == r.type then
            put(row, options.mismatch.field, le32(options.mismatch.value or 0xDEAD))
        end
        if r.type ~= options.missing then put(w.game, LAYOUT.index_rva + r.type * 8, le64(address(row))) end
        w.rows[r.type] = row
    end
    if not options.not_loaded then put(w.game, LAYOUT.buffer_rva, le64(address(w.buffer))) end
    function w.load() put(w.game, LAYOUT.buffer_rva, le64(address(w.buffer))) end
    function w.template(ptype) return get32(w.rows[ptype], 0xF4) end
    function w.count(value)
        local n = 0
        for _, t in ipairs(targets) do if w.template(t[1]) == value then n = n + 1 end end
        return n
    end
    return w
end

local function Api(w, build_ok)
    local api = writes.extend(memory.new(runtime))
    function api.module(name) if name == 'game.dll' then return w.game end end
    function api.verify_build()
        if build_ok == false then return false, 'unsupported game build' end
        return true
    end
    return api
end

local function Loader()
    local loader = {api = 1, lines = {}}
    function loader.open_log()
        return {write = function(_, text) loader.lines[#loader.lines + 1] = text end, flush = function() end}
    end
    function loader.text() return table.concat(loader.lines) end
    return loader
end

local function vanilla_update() return 'game' end

local function install(w, options)
    options = options or {}
    local api = Api(w, options.build_ok)
    local counts = budget.wrap(api)
    local env = {update = vanilla_update}
    local loader = Loader()
    Mod.TARGETS = w.targets
    local state = Mod.install(api, {env = env, layout = LAYOUT, loader = loader, diagnostics = options.diagnostics})
    return {api = api, counts = counts, env = env, loader = loader, state = state}
end

local quiet = print
local function silent(fn, ...)
    print = function() end
    local results = {pcall(fn, ...)}
    print = quiet
    assert(results[1], tostring(results[2]))
    return unpack(results, 2)
end

-- Tests -------------------------------------------------------------------------------------------------------

-- The real targets: player-side rows only, each type once, all on the vanilla template with an impact explosion.
do
    local seen = {}
    assert(#TARGETS == 99, 'expected 99 targets, got ' .. #TARGETS)
    for _, t in ipairs(TARGETS) do
        assert(not seen[t[1]], 'type listed twice: ' .. t[1])
        seen[t[1]] = true
        assert(t[1] > 0 and t[1] < 351 and t[3] > 0 and type(t[4]) == 'string', 'bad target ' .. t[1])
    end
    for _, enemy in ipairs({112, 9, 87, 88, 316}) do -- Automaton artillery, Obelisk, meteor, Outcast beam, volcano
        assert(not seen[enemy], 'enemy type ' .. enemy .. ' is a target')
    end
    for _, player in ipairs({239, 151, 293, 110, 132, 31}) do -- 500kg bombs, the three 75 mm HEAT rounds
        assert(seen[player], 'player type ' .. player .. ' is not a target')
    end
    passed = passed + 1
end

-- Applies at load: every target to the no-foliage query, the enemy row untouched, one batch write; afterwards the
-- game's update is the vanilla one again (no hook) and frames make no api calls.
do
    local w = World(TARGETS)
    local api_counts
    local m = silent(install, w)
    assert(m.state.applied and m.state.patched, m.state.status)
    assert(w.count(2) == #TARGETS and w.template(OTHER.type) == 0, 'rows not changed as expected')
    assert(m.loader.text():find('applied: 99 projectile types use the no-foliage query (99 changed now, 0 already',
        1, true), m.loader.text())
    assert(m.env.update == vanilla_update, 'a hook stayed installed after the load-time apply')
    api_counts = budget.frame(m.counts, m.env.update, 1 / 60)
    pin(api_counts, {}, 'release frame after apply')
    passed = passed + 1
end

-- Call budget of the load-time apply itself.
do
    local w = World(TARGETS)
    local api = Api(w)
    local counts = budget.wrap(api)
    Mod.TARGETS = TARGETS
    local frame, result, rows, changed = budget.frame(counts, Mod.attempt, api, w.game, LAYOUT, TARGETS)
    assert(result == 'applied' and changed == 99 and #rows.list == 99)
    -- Reads: 1 buffer pointer + 1 index + 99 rows + 99 read-backs; one page check for the whole span. pointer and
    -- address make no system call.
    pin(frame, {read = 200, pointer = 100, address = 199, write_batch = 1, writable_data = 1}, 'apply')
    passed = passed + 1
end

-- Waits while the settings are not loaded (1 read per frame), applies on the frame they appear, then removes itself.
do
    local w = World(TARGETS, {not_loaded = true})
    local m = silent(install, w)
    assert(not m.state.applied and m.state.status:find('^waiting: the projectile settings are not loaded yet'),
        m.state.status)
    assert(m.env.update ~= vanilla_update, 'no wait hook')
    local frame, result = budget.frame(m.counts, m.env.update, 1 / 60)
    assert(result == 'game', 'the game update result was lost')
    pin(frame, {read = 1, pointer = 1}, 'waiting frame')
    w.load()
    silent(m.env.update, 1 / 60)
    assert(m.state.applied and w.count(2) == #TARGETS, m.state.status)
    assert(m.env.update == vanilla_update, 'the hook did not remove itself')
    passed = passed + 1
end

-- Already changed (another copy or an earlier session in the same process): nothing written.
do
    local w = World(TARGETS, {template = 2})
    local api = Api(w)
    local counts = budget.wrap(api)
    local frame, result, _, changed = budget.frame(counts, Mod.attempt, api, w.game, LAYOUT, TARGETS)
    assert(result == 'applied' and changed == 0)
    assert((frame.write_batch or 0) == 0 and (frame.writable_data or 0) == 0, budget.describe(frame))
    passed = passed + 1
end

-- Anything unexpected refuses the whole change: no row written.
do
    local cases = {
        {mismatch = {type = 110, field = 0x08}, text = 'Unexpected projectile settings for 75mm HEAT Grenade'},
        {mismatch = {type = 239, field = 0x90}, text = 'Unexpected projectile settings for 500kg Bomb'},
        {mismatch = {type = 239, field = 0x00, value = 238}, text = 'Unexpected projectile settings for 500kg Bomb'},
        {mismatch = {type = 151, field = 0xF4, value = 1}, text = 'Unexpected raycast template 1 for 500kg Bomb Mk2'},
        {missing = 293, text = 'No projectile settings for 500kg Bomb Mk3'},
    }
    for _, case in ipairs(cases) do
        local w = World(TARGETS, case)
        local m = silent(install, w)
        assert(not m.state.applied and m.state.status:find(case.text, 1, true), m.state.status)
        assert(w.count(2) == 0, 'a refused change wrote rows')
        assert(m.env.update == vanilla_update, 'a refused change left a hook')
    end
    passed = passed + 1
end

-- A refused write puts back the writes that landed and disables the mod.
do
    local w = World(TARGETS)
    local api = Api(w)
    local real = api.write_batch
    local calls = {}
    function api.write_batch(base, size, changes)
        calls[#calls + 1] = #changes
        if #calls == 1 then
            local ok = real(base, size, {changes[1], changes[2]})
            assert(ok)
            return false, 2
        end
        return real(base, size, changes)
    end
    local ok, err = pcall(Mod.attempt, api, w.game, LAYOUT, TARGETS)
    assert(not ok and tostring(err):find('write refused or failed', 1, true), tostring(err))
    assert(#calls == 2 and calls[2] == 2, 'no undo of the landed writes')
    assert(w.count(2) == 0, 'landed writes were not put back')
    passed = passed + 1
end

-- An unsupported build or a missing loader does nothing.
do
    local w = World(TARGETS)
    local m = silent(install, w, {build_ok = false})
    assert(m.state.status:find('Unsupported game build', 1, true) and w.count(2) == 0)
    assert(m.env.update == vanilla_update and m.env.shutdown == nil, 'a refused build hooked the game')
    passed = passed + 1
end

-- Shutdown logs whether the change held; the A/B control switches every row both ways.
do
    local w = World(TARGETS)
    local m = silent(install, w)
    local api = Api(w)
    local rows = m.state.rows
    assert(Mod.set_template(api, rows, Mod.VANILLA) == 99 and w.count(0) == 99)
    assert(Mod.set_template(api, rows, Mod.NO_FOLIAGE) == 99 and w.count(2) == 99)
    local changed, vanilla, other = Mod.verify(api, rows)
    assert(changed == 99 and vanilla == 0 and other == 0)
    silent(m.env.shutdown)
    assert(m.loader.text():find('At shutdown: 99 of 99 projectile types use the no-foliage query', 1, true),
        m.loader.text())
    passed = passed + 1
end

-- Diagnostics get the control once applied, and a failing diagnostics install is logged, not fatal.
do
    local w = World(TARGETS)
    local got
    local diag = {install = function(_, control, note)
        got = control
        assert(control.state.patched)
        local ok = control.set(false)
        assert(ok and w.count(0) == 99 and not control.state.patched)
        assert(control.set(true) and w.count(2) == 99)
        note('diag installed')
    end}
    local m = silent(install, w, {diagnostics = diag})
    assert(got and m.loader.text():find('diag installed', 1, true))
    local broken = silent(install, World(TARGETS), {diagnostics = {install = function() error('boom', 0) end}})
    assert(broken.state.applied and broken.loader.text():find('Shot log disabled: boom', 1, true))
    passed = passed + 1
end

for name, status in pairs(clash) do
    assert(status == 'clashed' or status == 'already declared', name .. ': ' .. status)
end
print(('PASS: %d foliage pass-through tests (%s)'):format(passed, jit and jit.version or _VERSION))
