-- Equivalence of the idle gate: the v7.5 loader and patch (tests/reference/, copied
-- from origin/main) and the current ones run side by side, each through the
-- real update guard over its own synthetic memory, which one script changes
-- identically on the same frames. Every frame compares the enable byte (the
-- mod's only write), the write and restore counts and the status lines.
--
-- The only allowed differences are the stated delays of the gate: a change the
-- flag byte alone cannot show (the manager going blank after a mission, the
-- manager moving, a layout change) is noticed at the next full check, at most
-- 10 polls (1 s) after the last one, instead of at the next poll. Every flag change
-- (a mission reset, another writer) is acted on on the same frame as v7.5.
-- Local synthetic allocations only; no game access.
local source, reference = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local runtime = assert(loadfile(source .. '/bingus_runtime.lua'))()
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end

local identity = {revision = 'fixture', exe_sha256 = 'exe', game_sha256 = 'game'}
local game_storage = ffi.new('uint8_t[1]')
local game = ffi.cast('uint8_t *', game_storage)
local function pointer(value) return ffi.string(ffi.new('void *[1]', value), 8) end
local NULL = string.rep('\0', 8)

-- One world: memory with room for two managers (the second one is where a
-- manager that moves goes), the two globals' answers, and the mod installed
-- through the guard with the given loader and patch.
local function world(folder)
    local patch = assert(loadfile(folder .. '/steering_patch.lua'))()
    local size, offset = patch.size, patch.owner_offset
    local w = {patch = patch, writes = 0, restores = 0, reads = 0, lines = {}}
    w.storage = ffi.new('uint8_t[?]', offset + 2 * size)
    local owner = ffi.cast('uint8_t *', w.storage)
    w.places = {{manager = owner + offset, owner = owner}, {manager = owner + offset + size, owner = owner + size}}
    w.place = w.places[1]
    w.manager_bytes, w.owner_bytes = NULL, NULL
    local manager_slot, owner_slot = game + patch.manager_rva, game + patch.owner_rva
    local api = {}
    api.module = function(name) return name and game or 'exe' end
    api.module_hash = function(module) return type(module) == 'string' and 'exe' or 'game' end
    api.read_into = function(address, n, buffer)
        w.reads = w.reads + 1
        if address == manager_slot then ffi.copy(buffer, w.manager_bytes, 8); return true end
        if address == owner_slot then ffi.copy(buffer, w.owner_bytes, 8); return true end
        ffi.copy(buffer, ffi.cast('uint8_t *', address), n)
        return true
    end
    api.writable_data = function() return true end
    api.write_batch = function(base, n, changes)
        assert(n == size and #changes == 1 and changes[1][1] == 0)
        local value = changes[1][2]
        if value == '\0' then w.writes = w.writes + 1 else w.restores = w.restores + 1 end
        ffi.copy(ffi.cast('uint8_t *', base), value, 1)
        return true
    end
    api.write = function() error('the patch writes only through write_batch') end
    local env = setmetatable({os = {getenv = function() end}, failing = false}, {__index = _G})
    env._G = env
    env.print = function(line) w.lines[#w.lines + 1] = line end
    env.update = function() if env.failing then error('update below failed', 0) end end
    env.shutdown = function() end
    local chunk = assert(loadfile(folder .. '/archive_loader.lua')); setfenv(chunk, env)
    local loader = chunk(); setfenv(loader, env)
    loader(function() return api end, patch, identity, runtime)
    w.env = env
    return w
end

local function u32(m, offset, value) ffi.copy(m + offset, ffi.new('uint32_t[1]', value), 4) end
local function float(m, offset, value) ffi.copy(m + offset, ffi.new('float[1]', value), 4) end
-- The memory changes the script makes, applied to one world.
local edits = {}
function edits.pointers(w)
    w.manager_bytes, w.owner_bytes = pointer(w.place.manager), pointer(w.place.owner)
end
function edits.null(w) w.manager_bytes, w.owner_bytes = NULL, NULL end
function edits.blank(w) ffi.fill(w.place.manager, w.patch.size, 0) end
function edits.ready(w)
    local m = w.place.manager
    ffi.fill(m, w.patch.size, 0)
    m[0] = 1
    ffi.fill(m + 2, 8192, 255)
    u32(m, 32772, 3); u32(m, 65544, 8)
    ffi.copy(m + 65552, pointer(m + 65576), 8)
    u32(m, 65560, 1024); u32(m, 65568, 3)
    float(m, 69672, 1024); float(m, 69676, 512)
    float(m, 69680, 1024 / 64); float(m, 69684, 64 / 1024)
end
function edits.reset(w) w.place.manager[0] = 1 end
function edits.other(w) w.place.manager[0] = 2 end
function edits.zero(w) w.place.manager[0] = 0 end
function edits.records(w) u32(w.place.manager, 32772, 7) end
-- The manager moves: the old storage is left blank, the new one initialized.
function edits.move(w)
    edits.blank(w)
    w.place = w.place == w.places[1] and w.places[2] or w.places[1]
    edits.pointers(w)
    edits.ready(w)
end
function edits.corrupt(w) u32(w.place.manager, 32772, 1025) end
function edits.fail(w) w.env.failing = true end

-- Changes the flag byte cannot show: the gate notices them at its next full check.
local hidden = {blank = true, move = true, records = true, corrupt = true}

-- The script: {frame, edit}. Frames run with a dt from the list below, in turn.
local script = {
    {1, 'null'}, {40, 'pointers'}, {41, 'blank'},
    {400, 'ready'}, {700, 'reset'}, {703, 'reset'}, {950, 'other'}, {1050, 'zero'}, {1100, 'reset'},
    {1250, 'records'}, {1500, 'blank'}, {1800, 'ready'}, {2000, 'fail'}, {2300, 'reset'},
    {2500, 'move'}, {2800, 'other'}, {2820, 'reset'}, {3000, 'blank'}, {3010, 'null'}, {3100, 'pointers'},
    {3101, 'ready'}, {3400, 'fail'}, {3402, 'fail'}, {3700, 'corrupt'},
}
local DT = {1 / 60, 1 / 60, 1 / 30, 1 / 144, 0, 1 / 60, 0 / 0, 1 / 45, -1, 1 / 60, 0.25, 1 / 60}
local FRAMES = 4000

local old, new = world(reference), world(source)
local at, mismatches, worst = 1, 0, 0
local clock, hidden_at = 0, nil
for frame = 1, FRAMES do
    while script[at] and script[at][1] == frame do
        local edit = script[at][2]
        edits[edit](old); edits[edit](new)
        if hidden[edit] then hidden_at = clock end
        at = at + 1
    end
    local dt = DT[(frame - 1) % #DT + 1]
    pcall(old.env.update, dt); pcall(new.env.update, dt)
    old.env.failing, new.env.failing = false, false
    if dt == dt and dt > 0 then clock = clock + dt end
    local same = old.place.manager[0] == new.place.manager[0] and old.writes == new.writes
        and old.restores == new.restores and (old.place == old.places[2]) == (new.place == new.places[2])
    if not same then
        mismatches = mismatches + 1
        -- At most 10 polls after the last full check: 1 s of frame time plus the
        -- poll in progress (the largest dt in the list).
        assert(hidden_at and clock - hidden_at <= 1.0 + 0.1 + 0.25,
            'frame ' .. frame .. ': the gate changed a write outside its stated delay')
        worst = math.max(worst, clock - hidden_at)
    end
end
assert(at > #script, 'the whole script ran')
assert(old.writes == new.writes and old.restores == new.restores, 'the same writes and restores')
assert(old.writes >= 8 and old.restores >= 2, 'the script exercised clears and restores')
-- The same status lines in the same order (a hidden change's line comes up to
-- 1 s later).
assert(#old.lines == #new.lines, #old.lines .. ' lines against ' .. #new.lines)
for i = 1, #old.lines do assert(old.lines[i] == new.lines[i], 'line ' .. i .. ': ' .. old.lines[i] .. ' / ' .. new.lines[i]) end
assert(old.lines[#old.lines]:find('stopped: avoidance_layout_mismatch', 1, true), old.lines[#old.lines])
print(string.format('%d frames: %d status lines, %d clears, %d restores; reads %d (v7.5) -> %d; ' ..
    '%d frames differed, at most %.2f s after a hidden change', FRAMES, #old.lines, old.writes, old.restores,
    old.reads, new.reads, mismatches, worst))
assert(new.reads * 3 < old.reads, 'the gate reads less')
pass('the idle gate makes the same writes and status lines as v7.5; only hidden changes wait for a full check')

-- Every flag change is acted on on the same poll as v7.5: a mission reset at any
-- point of the gate's window is cleared on the frame v7.5 clears it.
do
    for offset = 0, 12 do
        local a, b = world(reference), world(source)
        for _, w in ipairs({a, b}) do edits.pointers(w); edits.ready(w) end
        for frame = 1, 60 + offset * 6 do
            a.env.update(1 / 60); b.env.update(1 / 60)
            if frame == 30 + offset * 6 then edits.reset(a); edits.reset(b) end
            assert(a.place.manager[0] == b.place.manager[0] and a.writes == b.writes, 'reset at offset ' .. offset)
        end
        assert(a.writes == 2 and b.writes == 2)
    end
end
pass('a mission reset is cleared on the same frame as v7.5 at every point of the window')

-- The guard calls step and poll under pcall, so a trace started at either's entry
-- aborts where it returns ("NYI: return to lower frame"). Both run interpreted
-- now: no aborts, ship or mission. Control: v7.5's loader, with both compiled,
-- aborts. Each run loads fresh prototypes (no earlier penalties); the game calls
-- update from C, here an interpreted driver.
if jit and jit.attach and jit.off and jit.status() then
    local function aborts(folder)
        local w = world(folder)
        edits.pointers(w)
        local function drive(frames) for _ = 1, frames do w.env.update(1 / 60) end end
        jit.off(drive)
        local n = 0
        local function on_trace(what) if what == 'abort' then n = n + 1 end end
        jit.attach(on_trace, 'trace')
        edits.blank(w)
        local ok, err = pcall(drive, 1500)
        if ok then edits.ready(w); ok, err = pcall(drive, 1500) end
        jit.attach(on_trace)
        assert(ok, err)
        return n
    end
    local control, now = aborts(reference), aborts(source)
    assert(control > 0, 'control: v7.5 did not abort, so this check proves nothing')
    assert(now == 0, now .. ' trace aborts from the guarded step and poll (v7.5: ' .. control .. ')')
    print('trace aborts over 3000 frames: v7.5 ' .. control .. ', now ' .. now)
    pass('the guarded step and poll start no trace that aborts')
end
print(count .. ' idle gate checks passed; no game process was accessed.')
