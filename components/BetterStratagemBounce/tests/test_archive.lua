local directory, compiled, executable_hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
-- Before the runtime binds them: another mod that loaded first declared every
-- Windows name the runtime binds with a wrong prototype (tests/hostile_vm.lua,
-- H.clash). ffi.cdef keeps the first prototype of a name for the whole game, so
-- every check below runs against those declarations. In a fresh process every
-- name clashes; run by test_windows_interop.lua, after a Hellpod adapter that
-- declared some of them itself, those count as already declared.
local clashed = 0
do
    local H = dofile(directory .. '/../tests/hostile_vm.lua')
    local names = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory',
        'WriteProcessMemory', 'VirtualQuery', 'QueryPerformanceCounter', 'QueryPerformanceFrequency', 'CreateFileW',
        'ReadFile', 'CloseHandle', 'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash',
        'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'}
    local fresh = rawget(_G, 'BingusRuntime') == nil
    local status = H.clash(names)
    for _, name in ipairs(names) do
        local state = status[name]
        assert(state == 'clashed' or (not fresh and state == 'already declared'), name .. ': ' .. tostring(state))
        if state == 'clashed' then clashed = clashed + 1 end
    end
end
local runtime = assert(loadfile(directory .. '/bingus_runtime.lua'))()
local memory_file = assert(loadfile(directory .. '/bingus_memory.lua'))()
local write_file = assert(loadfile(directory .. '/bingus_write.lua'))()
local make_api = assert(loadfile(directory .. '/windows_api.lua'))()
local patch = assert(loadfile(directory .. '/navigation_patch.lua'))()
-- The real adapter over the vendored runtime, as the build makes it: the core,
-- and bingus_memory.lua's api extended by bingus_write.lua. The last memory api
-- made is kept so the budget below can count the protection query made inside
-- the runtime's writes.
local memory
local function create_api()
    memory = write_file.extend(memory_file.new(runtime))
    return make_api(runtime, memory)
end
local ffi = require('ffi')
ffi.cdef [[
    void *VirtualAlloc(void *address, size_t size, uint32_t allocation, uint32_t protection);
    int VirtualFree(void *address, size_t size, uint32_t operation);
    int VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *previous);
]]
local kernel, api = ffi.load('kernel32'), create_api()
local cases = 0
local function pass(name) cases = cases + 1; print('PASS: ' .. name) end
local function allocate(size)
    local result = kernel.VirtualAlloc(nil, size, 0x3000, 4)
    assert(result ~= nil)
    return ffi.cast('uint8_t *', result)
end
local function protect(address, size, protection)
    assert(kernel.VirtualProtect(address, size, protection, ffi.new('uint32_t[1]')) ~= 0)
end
local function integer(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function pointer(address, value) ffi.cast('uintptr_t *', address)[0] = ffi.cast('uintptr_t', value) end

assert(not pcall(make_api) and not pcall(make_api, runtime), 'the adapter needs the runtime and its memory api')
assert(not pcall(make_api, runtime, memory_file.new(runtime)), 'the adapter needs the write side')
assert(api.module_hash(api.module(nil)) == executable_hash)
local hash_reads = rawget(_G, 'BingusRuntime').hash_reads
assert(api.module_hash(api.module(nil)) == executable_hash and rawget(_G, 'BingusRuntime').hash_reads == hash_reads)
assert(api.read(ffi.cast('void *', 1), 14) == nil)
pass('runtime-backed SHA256 matches independent hash once per session; invalid memory reads are contained; the adapter refuses a missing runtime or write side; ' .. clashed .. ' of the runtime\'s 17 Windows names declared first with wrong prototypes (H.clash)')

local code = allocate(4096)
ffi.copy(code, '\x41\xF6\x87\x70\1\0\0\2\x0F\x84\x88\0\0\0', 14)
local code_before = api.read(code, 4096)
for _, protection in ipairs({2, 0x20, 0x40}) do
    protect(code, 4096, protection)
    assert(not api.writable_data(code, 1) and not api.write(code, '\0'))
    assert(api.read(code, 4096) == code_before)
end
assert(not api.write(api.module(nil), '\0'))
assert(not api.writable_data(ffi.cast('void *', 1), 1))
pass('adapter refuses executable, read-only, image and unmapped write targets')

local module = allocate(patch.table_rva + 150 * 8)
local data = allocate(patch.data_size)
ffi.fill(data, patch.data_size, 0xA5)
pointer(module + patch.buffer_rva, data)
integer(data, 11)
local group_sizes = {7204,1184,5860,5228,19152,7040,3832,18344,4884,1104,6444}
local group_counts = {13,2,11,9,36,13,7,34,9,2,13}
local offset, record_count, locations = 4, 0, {}
for group, size in ipairs(group_sizes) do
    integer(data + offset, 0x444C444C)
    integer(data + offset + 4, 1)
    integer(data + offset + 8, 0x30EB6399)
    integer(data + offset + 12, size - 24)
    integer(data + offset + 16, 1)
    integer(data + offset + 20, 0)
    pointer(data + offset + 24, data + offset + 40)
    integer(data + offset + 32, group_counts[group])
    for index = 0, group_counts[group] - 1 do
        local record = offset + 40 + index * 400
        local kind = (record_count * 5) % 149 + 1
        record_count = record_count + 1
        integer(data + record, kind)
        pointer(module + patch.table_rva + kind * 8, data + record)
        data[record + patch.flag_offset] = patch.vanilla_flags[kind]
        locations[kind] = record
    end
    offset = offset + size
end
assert(offset == patch.data_size and record_count == 149 and #patch.vanilla_flags == 149)
local original = api.read(data, patch.data_size)
local module_table = api.read(module + patch.table_rva, 150 * 8)
-- The Lua heap must stay small in game (non-GC64, little room below 2 GB): the
-- apply builds one verification buffer, not one 80 KB copy per changed byte.
collectgarbage('collect')
collectgarbage('stop')
local heap_before = collectgarbage('count')
assert(patch.apply(api, module))
local heap_kb = collectgarbage('count') - heap_before
collectgarbage('restart')
assert(heap_kb < 2048, 'patch.apply allocated ' .. heap_kb .. ' KB')
pass('first apply allocates ' .. math.floor(heap_kb) .. ' KB of Lua heap (under 2 MB)')
local expected = original
local changed = 0
for kind, record in ipairs(locations) do
    local before = patch.vanilla_flags[kind]
    local after = bit.band(before, 0xFD)
    local position = record + patch.flag_offset
    assert(data[position] == after)
    expected = expected:sub(1, position) .. string.char(after) .. expected:sub(position + 2)
    if before ~= after then changed = changed + 1 end
end
assert(changed == 103 and api.read(data, patch.data_size) == expected)
assert(api.read(module + patch.table_rva, 150 * 8) == module_table)
assert(api.read(code, 4096) == code_before)
pass('103 navigation bits change across 149 shuffled records; every other data and code byte survives')

local function reset()
    protect(data, patch.data_size, 4)
    ffi.copy(data, original, #original)
    ffi.copy(module + patch.table_rva, module_table, #module_table)
    pointer(module + patch.buffer_rva, data)
end
local corruptions = {
    function() integer(data, 12) end,
    function() integer(data + 4, 0) end,
    function() integer(data + 16, patch.data_size * 2) end,
    function() pointer(data + 28, data + patch.data_size) end,
    function() integer(data + locations[2], 1) end,
    function() pointer(module + patch.table_rva + 8, data + locations[2]) end,
    function() pointer(module + patch.buffer_rva, nil) end,
}
for _, corrupt in ipairs(corruptions) do
    reset(); corrupt()
    local before = api.read(data, patch.data_size)
    assert(not patch.apply(api, module))
    assert(api.read(data, patch.data_size) == before)
end
reset(); protect(data, patch.data_size, 2)
assert(not patch.apply(api, module))
assert(api.read(data, patch.data_size) == original)
reset()
pass('malformed groups, counts, pointers, identities and read-only data fail before writes')

for _, failure in ipairs({'write', 'verify'}) do
    reset()
    local faulty = setmetatable({}, {__index = api})
    local batches = 0
    -- The 50th of the 103 writes fails: 49 landed.
    faulty.write_batch = function(base, size, changes)
        batches = batches + 1
        if failure == 'write' and batches == 1 then
            local landed = {}
            for index = 1, 49 do landed[index] = changes[index] end
            assert(#changes == 103 and api.write_batch(base, size, landed))
            return false, 49
        end
        return api.write_batch(base, size, changes)
    end
    local rejected = false
    faulty.read = function(address, size)
        if failure == 'verify' and batches == 1 and address == data and size == patch.data_size and not rejected then
            rejected = true; return nil
        end
        return api.read(address, size)
    end
    local queries = memory.queries
    assert(not patch.apply(faulty, module))
    assert(api.read(data, patch.data_size) == original)
    -- One protection query for the writes and one for the recovery.
    assert(batches == 2 and memory.queries - queries == 2)
end
pass('partial-write and verification failures recover the original settings with one query each way')

-- Only the bit this mod owns is validated, written and restored. A neighbour mod
-- may have changed other flag bits, already cleared this one (this mod's target
-- state: accepted, never written and never restored) or set it in a record whose
-- supported-build flags do not.
local OWNED = patch.owned_bit
local function flag_at(kind) return data[locations[kind] + patch.flag_offset] end
local function set_flag(kind, value) data[locations[kind] + patch.flag_offset] = value end
local function owned(kind) return bit.band(patch.vanilla_flags[kind], OWNED) ~= 0 end
local function clear_owned(kind) set_flag(kind, bit.band(flag_at(kind), bit.bnot(OWNED))) end
-- The settings as they were, with this mod's bit cleared in every owned record.
local function owned_cleared(settings)
    local positions, parts, last = {}, {}, 0
    for kind = 1, 149 do
        if owned(kind) then positions[#positions + 1] = locations[kind] + patch.flag_offset end
    end
    table.sort(positions)
    for _, position in ipairs(positions) do
        parts[#parts + 1] = settings:sub(last + 1, position)
        parts[#parts + 1] = string.char(bit.band(settings:byte(position + 1), bit.bnot(OWNED)))
        last = position + 1
    end
    parts[#parts + 1] = settings:sub(last + 1)
    return table.concat(parts)
end
local written = 0
local counting = setmetatable({write_batch = function(base, size, changes)
    written = written + #changes
    return api.write_batch(base, size, changes)
end}, {__index = api})

reset()
local unowned
for kind = 1, 149 do
    local value = patch.vanilla_flags[kind]
    if kind % 3 == 0 then value = bit.bxor(value, 0x01) end
    if kind % 4 == 0 then value = bit.bor(value, 0x40) end
    if not owned(kind) and not unowned then unowned, value = kind, bit.bor(value, OWNED) end
    set_flag(kind, value)
end
local neighbour = api.read(data, patch.data_size)
written = 0
local ok, status, plan = patch.apply(counting, module)
assert(ok and status == 'navigation_settings_ready: 103 flags; executable code unchanged', status)
assert(written == 103 and #plan.changes == 103 and bit.band(flag_at(unowned), OWNED) ~= 0)
assert(api.read(data, patch.data_size) == owned_cleared(neighbour))
written = 0
assert(patch.restore(counting, module, plan) and written == 103)
assert(api.read(data, patch.data_size) == neighbour)
pass("a neighbour's other flag bits and its bit in an unowned record survive the apply and the restore")

reset()
local cleared = {}
for kind = 1, 149 do
    if owned(kind) and kind % 2 == 1 and #cleared < 10 then cleared[#cleared + 1] = kind; clear_owned(kind) end
end
neighbour = api.read(data, patch.data_size)
written = 0
ok, status, plan = patch.apply(counting, module)
assert(ok and status == 'navigation_settings_ready: 103 flags (10 already clear); executable code unchanged', status)
assert(written == 93 and api.read(data, patch.data_size) == owned_cleared(neighbour))
written = 0
assert(patch.restore(counting, module, plan) and written == 93)
-- The bits the neighbour cleared stay clear: they were never this mod's.
assert(api.read(data, patch.data_size) == neighbour)
for _, kind in ipairs(cleared) do assert(bit.band(flag_at(kind), OWNED) == 0) end

reset()
for kind = 1, 149 do if owned(kind) then clear_owned(kind) end end
neighbour = api.read(data, patch.data_size)
local queries = memory.queries
ok, status, plan = patch.apply(api, module)
assert(ok and status == 'navigation_settings_ready: 103 flags (103 already clear); executable code unchanged', status)
assert(#plan.changes == 0 and memory.queries == queries and api.read(data, patch.data_size) == neighbour)
assert(patch.restore(api, module, plan) and memory.queries == queries and api.read(data, patch.data_size) == neighbour)
pass('bits a neighbour already cleared are accepted, never written and never restored; all clear makes no query')

-- After the apply a neighbour sets another bit in one changed record and sets
-- this mod's bit again in another; a third record stops being the same stratagem.
reset()
ok, status, plan = patch.apply(api, module)
local first, second, third = plan.changes[1], plan.changes[2], plan.changes[3]
data[first[1]] = bit.bor(data[first[1]], 0x04)
data[second[1]] = bit.bor(data[second[1]], OWNED)
integer(data + third.record, 0)
written = 0
assert(patch.restore(counting, module, plan) == false and written == 101)
assert(data[first[1]] == bit.bor(original:byte(first[1] + 1), 0x04) and data[second[1]] == original:byte(second[1] + 1))
assert(bit.band(data[third[1]], OWNED) == 0)
for index = 4, #plan.changes do
    local change = plan.changes[index]
    assert(data[change[1]] == original:byte(change[1] + 1))
end

-- A failed write is recovered bit by bit: a neighbour's change to another bit of a
-- record that landed no longer stops the recovery.
reset()
local faulty = setmetatable({}, {__index = api})
local touched
faulty.write_batch = function(base, size, changes)
    if #changes ~= 103 then return api.write_batch(base, size, changes) end
    local landed = {}
    for index = 1, 49 do landed[index] = changes[index] end
    assert(api.write_batch(base, size, landed))
    touched = changes[10][1]
    data[touched] = bit.bor(data[touched], 0x80)
    return false, 49
end
ok, status = patch.apply(faulty, module)
assert(not ok and status:find('partial-edit recovery=true', 1, true), status)
assert(data[touched] == bit.bor(original:byte(touched + 1), 0x80))
data[touched] = original:byte(touched + 1)
assert(api.read(data, patch.data_size) == original)
reset()
pass("the restore puts back only this mod's bit, keeps later neighbour changes and skips moved records")

-- Per-frame call budget through the real loader, patch and adapter: the settings
-- change is made once, on the first update after the earlier update returned; no
-- later frame makes an API call. Test-process timings hide the in-game costs: one
-- protection query (writable_data, also inside every write and write_batch)
-- costs about 0.29 ms and one read about 1-2 us. The query inside the writes is
-- counted as writable_data too. Limits are the exact counts (pinned both ways).
do
    reset()
    local budget = dofile(directory .. '/../tests/frame_budget.lua')
    local frame_api, exe = create_api(), {}
    frame_api.module = function(name) if name == nil then return exe end; return name == 'game.dll' and module or nil end
    frame_api.module_hash = function(handle) return handle == module and 'game' or 'exe' end
    local counts = budget.wrap(frame_api)
    -- The runtime's writes check protection through its own writable_data: count
    -- that query too. The runtime's query counter cross-checks the count.
    local query = memory.writable_data
    memory.writable_data = frame_api.writable_data
    local function check(update, label, limits)
        local queries = memory.queries
        local frame = budget.frame(counts, update, 0.016)
        budget.check(frame, limits, label)
        assert(budget.describe(frame) == budget.describe(limits),
            label .. ': ' .. budget.describe(frame) .. '; pinned ' .. budget.describe(limits))
        assert(memory.queries - queries == (frame.writable_data or 0), label .. ': uncounted query')
    end
    -- Outermost (the loader drops its hook) and below a later mod's update (it stays
    -- in the chain); last, with every owned bit already cleared by another mod.
    for _, case in ipairs({{wrapped = false}, {wrapped = true}, {wrapped = true, cleared = true}}) do
        local wrapped = case.wrapped
        reset()
        if case.cleared then for kind = 1, 149 do if owned(kind) then clear_owned(kind) end end end
        local settings = api.read(data, patch.data_size)
        local env = setmetatable({print = function() end, os = {getenv = function() end},
            update = function() end}, {__index = _G})
        env._G = env
        local chunk = assert(loadfile(directory .. '/archive_loader.lua')); setfenv(chunk, env)
        local loader = chunk(); setfenv(loader, env)
        loader(function() return frame_api end, patch, {revision = 'budget', exe_sha256 = 'exe', game_sha256 = 'game'})
        local below = env.update
        if wrapped then env.update = function(...) return below(...) end end
        local function update(...) return env.update(...) end
        -- The first apply: one write_batch with one protection query for the whole
        -- settings buffer right before its 103 one-byte writes (about 0.29 ms in game,
        -- once per session). write_batch replaces write, which made 103 checked
        -- writes after a separate check: 104 queries, about 30 ms.
        if case.cleared then
            -- Nothing to write: validation only, no protection query.
            check(update, 'first frame, all bits already clear', {module = 2, module_hash = 2, read = 3,
                pointer = 161, distance = 11})
        else
            check(update, 'first frame', {module = 2, module_hash = 2, read = 6, pointer = 161, distance = 11,
                writable_data = 1, write_batch = 1})
        end
        assert(env.BetterStratagemBounce.active and api.read(data, patch.data_size) == owned_cleared(settings))
        for _ = 1, 3 do check(update, 'idle frame', {}) end
        -- An idle frame allocates nothing, interpreted or compiled. One loop
        -- serves the warm-up and the windows, so the windows record no trace.
        local function frames(n) for _ = 1, n do update(0.016) end end
        for _, compiled in ipairs({false, true}) do
            if compiled then jit.on(); jit.flush() else jit.off() end
            frames(1000)
            for window = 1, 3 do
                collectgarbage('collect'); collectgarbage('stop')
                local before = collectgarbage('count')
                frames(100)
                local bytes = (collectgarbage('count') - before) * 1024
                collectgarbage('restart')
                assert(bytes == 0, string.format('idle frames (%s, %s): %d bytes in 100 frames, window %d',
                    wrapped and 'below a later mod' or 'outermost', compiled and 'compiled' or 'interpreted', bytes, window))
            end
            jit.on()
        end
    end
    memory.writable_data = query
    reset()
end
pass('first-frame and idle call budgets: one apply per session, no calls and no garbage (interpreted or compiled) on later frames')
assert(kernel.VirtualFree(module, 0, 0x8000) ~= 0)
assert(kernel.VirtualFree(data, 0, 0x8000) ~= 0)
assert(kernel.VirtualFree(code, 0, 0x8000) ~= 0)

for _, mode in ipairs({'success', 'ffi', 'exe', 'game', 'missing', 'patch'}) do
    local updates, attempts, applied = 0, 0, 0
    local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
    env._G = env
    env.update = function(dt, marker) assert(dt == 0.016 and marker == 123); updates = updates + 1 end
    local previous = env.update
    local loader = assert(loadfile(directory .. '/archive_loader.lua'))
    setfenv(loader, env)
    setfenv(loader(), env)(function()
        attempts = attempts + 1
        if mode == 'ffi' then error('No ffi') end
        return {
            module = function(name) if mode == 'missing' then return nil end; return name or 'exe' end,
            module_hash = function(name)
                if (mode == 'exe' and name == 'exe') or (mode == 'game' and name == 'game.dll') then return 'wrong' end
                return name
            end
        }
    end, {apply = function() applied = applied + 1; return mode ~= 'patch', 'test result' end},
    {revision = 'test', exe_sha256 = 'exe', game_sha256 = 'game.dll'})
    for _ = 1, 5 do env.update(0.016, 123) end
    assert(updates == 5 and attempts == 1 and env.update == previous)
    assert(applied == ((mode == 'success' or mode == 'patch') and 1 or 0))
    assert(env.BetterStratagemBounce.active == (mode == 'success'))
end
pass('loader preserves updates, verifies both modules, contains failures and removes its update hook')

local env = setmetatable({print = function() end, os = {getenv = function() end},
    update = function() return 1, nil, 3 end}, {__index = _G})
env._G = env
setfenv(assert(loadfile(compiled)), env)()
local first = env.update
setfenv(assert(loadfile(compiled)), env)()
assert(env.update == first and env.BetterStratagemBounce.status == 'pending')
local a, b, c = env.update(0.1)
assert(a == 1 and b == nil and c == 3 and select('#', env.update(0.1)) == 3)
assert(env.BetterStratagemBounce.active == false)
-- The embedded runtime's memory API ran and looked for the game modules.
assert(env.BetterStratagemBounce.status:find('Required game modules unavailable', 1, true),
    env.BetterStratagemBounce.status)
pass('compiled module initializes once, preserves update returns and rejects the non-game host')
print(cases .. ' runtime checks passed; no game process was accessed.')
