-- Local synthetic allocations and loader environments only; no game access.
local source, build, executable_hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local runtime = assert(loadfile(source .. '/bingus_runtime.lua'))()
local create_api = assert(loadfile(source .. '/windows_api.lua'))()
local patch = assert(loadfile(source .. '/steering_patch.lua'))()
-- The real adapter over the vendored runtime, given the memory API as the build
-- gives it: the read side extended by the write side. The memory API is kept so
-- the budget below can count the protection query made inside write_batch.
local read_side = assert(loadfile(source .. '/bingus_memory.lua'))()
local memory = assert(loadfile(source .. '/bingus_write.lua'))().extend(read_side.new(runtime))
local real = create_api(runtime, memory)
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
assert(not pcall(create_api) and not pcall(create_api, runtime), 'the adapter needs the memory API')
assert(not pcall(create_api, runtime, read_side.new(runtime)), 'the adapter needs the write side')
assert(real.module_hash(real.module(nil)) == executable_hash)
local hash_reads = rawget(_G, 'BingusRuntime').hash_reads
assert(real.module_hash(real.module(nil)) == executable_hash and rawget(_G, 'BingusRuntime').hash_reads == hash_reads)
assert(real.read(ffi.cast('void *', 1), 8) == nil)
assert(not real.read_into(ffi.cast('void *', 1), 8, ffi.new('uint8_t[8]')))
assert(not real.writable_data(real.module(nil), 1))
assert(not real.write(real.module(nil), '\0'))
assert(not real.write_batch(real.module(nil), 1, {{0, '\0'}}))
pass('runtime-backed adapter hashes each module once per session and refuses module pages')

-- The owner sits owner_offset bytes below the manager. One allocation holds
-- both, so the owner is always a valid user-mode address: in the game's
-- non-GC64 VM a manager allocated alone can land in the low megabytes, which
-- put the owner below 0x10000 and made the first mission check wait.
local storage = ffi.new('uint8_t[?]', patch.owner_offset + patch.size)
local owner = ffi.cast('uint8_t *', storage)
local manager = owner + patch.owner_offset
local game_storage = ffi.new('uint8_t[1]')
local game = ffi.cast('uint8_t *', game_storage)
local function pointer(value) return ffi.string(ffi.new('void *[1]', value), 8) end
local function u32(offset, value) ffi.copy(manager + offset, ffi.new('uint32_t[1]', value), 4) end
local function float(offset, value) ffi.copy(manager + offset, ffi.new('float[1]', value), 4) end
local writes, restores = 0, 0
local api = setmetatable({}, {__index = real})
-- The two globals live in the game module; here they answer with the fixture's
-- pointers. The patch reads with read_into into its own buffers; the slot
-- addresses and pointer bytes are made once, so a fixture read allocates nothing.
local manager_slot, owner_slot = game + patch.manager_rva, game + patch.owner_rva
local manager_bytes, owner_bytes = pointer(manager), pointer(owner)
api.read = function(address, size)
    if address == manager_slot then assert(size == 8); return manager_bytes end
    if address == owner_slot then assert(size == 8); return owner_bytes end
    return real.read(address, size)
end
api.read_into = function(address, size, buffer)
    if address == manager_slot then assert(size == 8); ffi.copy(buffer, manager_bytes, 8); return true end
    if address == owner_slot then assert(size == 8); ffi.copy(buffer, owner_bytes, 8); return true end
    return real.read_into(address, size, buffer)
end
-- A fixture read of one global that answers with other pointer bytes.
local function answer(buffer, value) ffi.copy(buffer, pointer(value), 8); return true end
-- The only writes: the enable byte, checked with the whole manager. 0 clears
-- it (counted in writes); 1 puts the game's value back (counted in restores).
api.write_batch = function(base, size, changes)
    assert(base == manager and size == patch.size and #changes == 1 and changes[1][1] == 0)
    local value = changes[1][2]
    assert(value == '\0' or value == '\1')
    if value == '\0' then writes = writes + 1 else restores = restores + 1 end
    return real.write_batch(base, size, changes)
end
api.write = function() error('the patch writes only through write_batch') end
local function ready()
    ffi.fill(manager, patch.size, 0)
    manager[0] = 1
    ffi.fill(manager + 2, 8192, 255)
    u32(32772, 3); u32(65544, 8)
    ffi.copy(manager + 65552, pointer(manager + 65576), 8)
    u32(65560, 1024); u32(65568, 3)
    float(69672, 1024); float(69676, 512)
    float(69680, 1024 / 64); float(69684, 64 / 1024)
end
-- own: the caller's record of this mod's write (the loader keeps one).
local own = {}
local ok, reason, active = patch.apply(api, game, own)
assert(ok and reason == 'waiting_for_mission' and not active and writes == 0)
ready()
local before = ffi.string(manager, patch.size)
ok, reason, active = patch.apply(api, game, own)
assert(ok and active and reason == 'avoidance_settings_ready' and writes == 1)
assert(ffi.string(manager, patch.size) == '\0' .. before:sub(2))
assert(patch.apply(api, game, own) and writes == 1)
ready(); assert(patch.apply(api, game, own) and writes == 2)
pass('ship initialization waits; exactly one data byte changes; mission reset reapplies')

-- A flag value that is neither the game's own 1 nor this mod's 0, in an
-- otherwise valid manager, comes from another writer: it is left alone on every
-- poll, never fought and never a stop. Once mission initialization sets the
-- game's value again, it is cleared again.
for _, value in ipairs({2, 255}) do
    ready()
    local old_writes = writes
    assert(patch.apply(api, game, own) and writes == old_writes + 1 and manager[0] == 0)
    manager[0] = value
    local unchanged = ffi.string(manager, patch.size)
    for _ = 1, 3 do
        ok, reason, active = patch.apply(api, game, own)
        assert(ok and reason == 'avoidance_flag_set_by_another_writer' and not active, reason)
        assert(writes == old_writes + 1 and ffi.string(manager, patch.size) == unchanged)
    end
    manager[0] = 0
    ok, reason, active = patch.apply(api, game, own)
    assert(ok and active and reason == 'avoidance_settings_ready' and writes == old_writes + 1)
    ready()
    assert(patch.apply(api, game, own) and writes == old_writes + 2 and manager[0] == 0)
end
ready(); manager[0] = 2
local foreign, foreign_writes = ffi.string(manager, patch.size), writes
ok, reason = patch.apply(api, game, own)
assert(ok and reason == 'avoidance_flag_set_by_another_writer' and writes == foreign_writes
    and ffi.string(manager, patch.size) == foreign)
pass('a flag value from another writer is left alone and never stops the mod; the game value is cleared again')

for _, defect in ipairs({
    function() u32(32772, 1025) end,
    function() u32(65544, 8193) end,
    function() u32(65560, 512) end,
    function() u32(65564, 1025) end,
    function() u32(65568, 7) end,
    function() ffi.copy(manager + 65552, pointer(manager + 16), 8) end,
    function() float(69672, 0/0) end,
    function() float(69676, 42) end,
    function() float(69680, 42) end,
    function() float(69684, 42) end,
}) do
    ready(); defect()
    local unchanged, old_writes = ffi.string(manager, patch.size), writes
    assert(not patch.apply(api, game, own))
    assert(writes == old_writes and ffi.string(manager, patch.size) == unchanged)
end
ready()
for _, kind in ipairs({'owner', 'permissions', 'unreadable', 'write_failure', 'identity_changed'}) do
    local altered = setmetatable({}, {__index = api})
    local reads = 0
    altered.read_into = function(address, size, buffer)
        if address == manager_slot then
            reads = reads + 1
            if kind == 'identity_changed' and reads == 2 then return answer(buffer, manager + 16) end
        end
        if kind == 'owner' and address == owner_slot then return answer(buffer, owner + 8) end
        if kind == 'unreadable' and address == manager + 32772 then return false end
        return api.read_into(address, size, buffer)
    end
    -- A protection refusal: the checked write and the check both refuse.
    if kind == 'permissions' then
        altered.writable_data = function() return false end
        altered.write_batch = function() return false, 0 end
    end
    if kind == 'write_failure' then altered.write_batch = function() return false, 0 end end
    local accepted, status = patch.apply(altered, game, {})
    assert(not accepted or (kind == 'identity_changed' and status == 'waiting_for_stable_mission'))
    assert(kind ~= 'permissions' or status == 'avoidance_is_not_writable_private_data', status)
    assert(kind ~= 'write_failure' or status == 'avoidance_data_write_failed', status)
    assert(ffi.string(manager, patch.size) == before)
end
pass('layout, pointer, page, read, write and reset-race failures leave data unchanged')

-- restore puts the game's value back only over this mod's own write: the same
-- manager, owner, set and dimensions, the flag still 0 and the layout valid,
-- rechecked right before the one-byte store. Anything else is left alone, and
-- the write is forgotten either way.
do
    local function cleared()
        ready()
        local mine = {}
        assert(patch.apply(api, game, mine) and manager[0] == 0)
        return mine, ffi.string(manager, patch.size)
    end
    local mine, after_clear = cleared()
    local old_restores = restores
    local restored, outcome = patch.restore(api, game, mine)
    assert(restored and outcome == 'avoidance_restored' and restores == old_restores + 1, outcome)
    assert(ffi.string(manager, patch.size) == '\1' .. after_clear:sub(2))
    restored, outcome = patch.restore(api, game, mine)
    assert(restored and outcome == 'nothing_to_restore' and restores == old_restores + 1)
    assert(select(2, patch.restore(api, game, {})) == 'nothing_to_restore')
    local moved = setmetatable({}, {__index = api})
    moved.read_into = function(address, size, buffer)
        if address == owner_slot then return answer(buffer, owner + 8) end
        return api.read_into(address, size, buffer)
    end
    local reads, racing = 0, setmetatable({}, {__index = api})
    racing.read_into = function(address, size, buffer)
        if address == manager_slot then
            reads = reads + 1
            if reads == 2 then return answer(buffer, manager + 16) end
        end
        return api.read_into(address, size, buffer)
    end
    for name, case in pairs({
        ['another writer'] = function() manager[0] = 2; return api end,
        ['the game reset the flag'] = function() manager[0] = 1; return api end,
        ['a new map'] = function()
            float(69672, 2048); float(69676, 1024); float(69680, 2048 / 64); float(69684, 64 / 2048)
            return api
        end,
        ['a layout it cannot verify'] = function() u32(32772, 1025); return api end,
        ['another owner'] = function() return moved end,
        ['identity changed before the write'] = function() reads = 0; return racing end,
    }) do
        mine = cleared()
        local view_api = case()
        local unchanged = ffi.string(manager, patch.size)
        old_restores = restores
        restored, outcome = patch.restore(view_api, game, mine)
        assert(restored and outcome == 'avoidance_left_unchanged', name .. ': ' .. tostring(outcome))
        assert(restores == old_restores and ffi.string(manager, patch.size) == unchanged, name)
        assert(select(2, patch.restore(api, game, mine)) == 'nothing_to_restore', name)
    end
    mine = cleared()
    local refusing = setmetatable({}, {__index = api})
    refusing.write_batch = function() return false, 0 end
    refusing.writable_data = function() return false end
    restored, outcome = patch.restore(refusing, game, mine)
    assert(not restored and outcome == 'avoidance_is_not_writable_private_data' and manager[0] == 0, outcome)
end
pass('restore puts the game value back only over its own write, rechecked right before the store')

local bounce_source = arg[4]
local identity = {revision = 'fixture', exe_sha256 = 'exe', game_sha256 = 'game'}
-- Each build hands its loader the runtime it vendors as the fourth argument.
-- A Bounce source that vendors bingus_runtime.lua gets its own copy; an older
-- Bounce loader ignores the argument.
local bounce_runtime = runtime
if bounce_source then
    local vendored = io.open(bounce_source .. '/bingus_runtime.lua', 'rb')
    if vendored then
        vendored:close()
        bounce_runtime = assert(loadfile(bounce_source .. '/bingus_runtime.lua'))()
    end
end
for _, mode in ipairs({'success', 'bounce_failure', 'hellpod_failure', 'exe', 'game', 'ffi'}) do
    local updates, checks, bounce_checks, factories, shutdowns = 0, 0, 0, 0, 0
    local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
    env._G = env
    env.shutdown = function() shutdowns = shutdowns + 1 end
    env.update = function(dt, marker)
        assert(dt == 0.1 and marker == 123); updates = updates + 1
        return 'result', nil, marker
    end
    local function factory()
        factories = factories + 1
        if mode == 'ffi' then error('ffi unavailable') end
        return {
            module = function(name) return name and 'game' or 'exe' end,
            module_hash = function(module) return module == mode and 'mismatch' or module end,
        }
    end
    local function initialize(path, make_api, probe, loader_runtime)
        local chunk = assert(loadfile(path)); setfenv(chunk, env)
        local loader = chunk(); setfenv(loader, env)
        loader(make_api, probe, identity, loader_runtime)
    end
    if bounce_source then
        -- Module hashes that match the identity, and verify_build for a Bounce
        -- loader that checks the build through the runtime's session cache.
        initialize(bounce_source .. '/archive_loader.lua', function()
            return {module = function(name) return name and 'game' or 'exe' end,
                    module_hash = function(module) return module end,
                    verify_build = function() return true end}
        end, {apply = function() bounce_checks = bounce_checks + 1; return mode ~= 'bounce_failure', 'bounce result' end},
            bounce_runtime)
    end
    local probe = {apply = function()
        checks = checks + 1
        return mode ~= 'hellpod_failure', checks == 1 and 'waiting_for_mission' or 'avoidance_settings_ready', checks > 1
    end, restore = function() return true, 'nothing_to_restore' end}
    initialize(source .. '/archive_loader.lua', factory, probe, runtime)
    initialize(source .. '/archive_loader.lua', factory, probe, runtime)
    for _ = 1, 5 do env.update(0.1, 123) end
    assert(updates == 5 and factories == 1 and bounce_checks == (bounce_source and 1 or 0))
    -- Whoever wraps shutdown, the game's own shutdown still runs once.
    env.shutdown()
    assert(shutdowns == 1)
    assert(checks == ((mode == 'ffi' or mode == 'exe' or mode == 'game') and 0 or mode == 'hellpod_failure' and 1 or 5))
    assert(env.HellpodSteeringUnlocked.active == (mode == 'success' or mode == 'bounce_failure'))
    if bounce_source then assert(env.BetterStratagemBounce.active == (mode ~= 'bounce_failure')) end
end
pass('loader handles failures, duplicate initialization and existing update callbacks')

-- The standalone wrapper preserves return values and nil holes of update. A
-- build that passes no runtime installs nothing and says why.
local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
env._G = env
env.update = function() return 1, nil, 3 end
local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
local loader = chunk(); setfenv(loader, env)
loader(function() return {module = function(name) return name and 'game' or 'exe' end,
    module_hash = function(module) return module end} end,
    {apply = function() return true, 'waiting_for_mission', false end}, identity, runtime)
local results = {env.update(0.1)}
assert(results[1] == 1 and results[2] == nil and results[3] == 3 and select('#', env.update(0.1)) == 3)
local bare = setmetatable({print = function() end, update = function() end}, {__index = _G})
bare._G = bare
local unguarded = bare.update
local bare_chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(bare_chunk, bare)
local bare_loader = bare_chunk(); setfenv(bare_loader, bare)
bare_loader(function() error('not reached') end, patch, identity)
assert(bare.update == unguarded and bare.HellpodSteeringUnlocked.status:find('bingus_runtime.lua v1 is required', 1, true))
pass('standalone update forwards return values unchanged; no runtime, no wrapper')

-- Per-frame call budget through the real loader and patch: the 10 Hz poll runs
-- one check, frames between polls make no calls. Only the poll that applies the
-- settings queries memory protection, once (about 0.29 ms in game). The checks
-- read with read_into: the same ReadProcessMemory per field as read, into the
-- patch's reused buffers, so no string is made; pointers and distances are
-- decoded from those buffers as numbers, with no api call.
do
    local budget = dofile(arg[0]:gsub('[%w_]+%.lua$', '') .. 'frame_budget.lua')
    local frame_api = {module = function(name) return name and game or 'exe' end,
        module_hash = function(module) return type(module) == 'string' and 'exe' or 'game' end}
    for _, name in ipairs({'read', 'read_into', 'write', 'write_batch', 'pointer', 'distance', 'writable_data'}) do
        frame_api[name] = api[name]
    end
    local counts = budget.wrap(frame_api)
    -- write_batch checks protection through the runtime's writable_data: count
    -- that query too. The runtime's own query counter cross-checks the count.
    local query = memory.writable_data
    memory.writable_data = frame_api.writable_data
    local failing = false
    local env = setmetatable({print = function() end, os = {getenv = function() end},
        update = function() if failing then error('update below failed', 0) end end}, {__index = _G})
    env._G = env
    local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
    local loader = chunk(); setfenv(loader, env)
    loader(function() return frame_api end, patch, identity, runtime)
    local function check(label, limits, status, written, restored)
        local old_writes, old_restores, old_queries = writes, restores, memory.queries
        local frame = budget.frame(counts, env.update, 0.05)
        assert(env.HellpodSteeringUnlocked.status == status and writes == old_writes + (written or 0)
            and restores == old_restores + (restored or 0), label .. ': ' .. env.HellpodSteeringUnlocked.status)
        assert((memory.queries > old_queries) == ((frame.writable_data or 0) > 0), label .. ': uncounted query')
        budget.check(frame, limits, label)
    end
    ffi.fill(manager, patch.size, 0)
    check('ship poll', {read_into = 7}, 'waiting_for_mission')
    check('between polls', {}, 'waiting_for_mission')
    ready()
    -- One protection query on this one poll, inside write_batch: it covers the
    -- whole manager right before the one-byte write (about 0.29 ms in game, once
    -- per mission). write_batch replaces write, which repeated the query after
    -- a separate check of the manager: two queries, about 0.6 ms.
    check('first mission poll', {read_into = 13, writable_data = 1, write_batch = 1}, 'avoidance_settings_ready', 1)
    check('between polls', {}, 'avoidance_settings_ready')
    check('later poll', {read_into = 7}, 'avoidance_settings_ready')
    check('between polls', {}, 'avoidance_settings_ready')
    check('later poll', {read_into = 7}, 'avoidance_settings_ready')
    check('between polls', {}, 'avoidance_settings_ready')
    -- Another writer's value: the same reads as a later poll, no write, no query.
    manager[0] = 2
    check('another writer', {read_into = 7}, 'avoidance_flag_set_by_another_writer')
    check('between polls', {}, 'avoidance_flag_set_by_another_writer')
    check('another writer, later poll', {read_into = 7}, 'avoidance_flag_set_by_another_writer')
    check('between polls', {}, 'avoidance_flag_set_by_another_writer')
    ready()
    check('mission reset after another writer', {read_into = 13, writable_data = 1, write_batch = 1},
        'avoidance_settings_ready', 1)
    check('between polls', {}, 'avoidance_settings_ready')
    -- An update below raises. Its error reaches the caller; the next frame pauses
    -- the mod and puts the game's value back over its write, checked like the
    -- clear (one query, once per pause). Paused frames make no calls; the frame
    -- after 60 clean updates below checks at once and clears again.
    failing = true
    assert(not pcall(env.update, 0.05))
    failing = false
    local paused = 'paused: the previous update failed; avoidance_restored'
    check('pause: the game value back', {read_into = 13, writable_data = 1, write_batch = 1}, paused, 0, 1)
    for _ = 1, 59 do check('paused', {}, paused) end
    check('resumed: first check', {read_into = 13, writable_data = 1, write_batch = 1}, 'avoidance_settings_ready', 1)
    memory.writable_data = query
end
pass('per-frame call budget: no protection query after settings are applied; frames between polls make no calls')

-- The real loader, patch and adapter over the fixture, in a fresh environment
-- whose game update raises while env.failing is set and whose shutdown counts.
local loader_api = setmetatable({module = function(name) return name and game or 'exe' end,
    module_hash = function(module) return type(module) == 'string' and 'exe' or 'game' end}, {__index = api})
local function install(options)
    options = options or {}
    local env = setmetatable({os = {getenv = function() end}, lines = {}, failing = false, shutdowns = 0},
        {__index = _G})
    env._G = env
    env.print = function(line) env.lines[#env.lines + 1] = line end
    env.update = function() if env.failing then error('update below failed', 0) end end
    env.shutdown = function() env.shutdowns = env.shutdowns + 1 end
    local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
    local loader = chunk(); setfenv(loader, env)
    loader(function() return options.api or loader_api end, options.patch or patch, identity, runtime)
    return env, env.BingusRuntime.statuses.HellpodSteeringUnlocked
end
local function fail_below(env)
    env.failing = true
    assert(not pcall(env.update, 0.1), 'the error below reaches the caller')
    env.failing = false
end

-- Through the real loader: another writer's value is reported once however long
-- it stays, it is never written, and polling goes on, so the game's own value is
-- cleared once mission initialization sets it again.
do
    local env = install()
    ready()
    env.update(0.1)
    assert(env.HellpodSteeringUnlocked.status == 'avoidance_settings_ready' and manager[0] == 0)
    manager[0] = 2
    local old_lines, old_writes = #env.lines, writes
    for _ = 1, 50 do env.update(0.1) end
    assert(#env.lines == old_lines + 1 and env.lines[#env.lines]:find('avoidance_flag_set_by_another_writer', 1, true))
    assert(manager[0] == 2 and writes == old_writes and not env.HellpodSteeringUnlocked.active)
    ready()
    env.update(0.1)
    assert(manager[0] == 0 and writes == old_writes + 1 and env.HellpodSteeringUnlocked.active)
end
pass('through the loader: another writer is reported once and never fought; polling continues')

-- Allocation: a check reads into the patch's reused buffers and decodes them in
-- place, so neither frames between polls nor polled frames allocate anything,
-- interpreted or compiled: in a mission with the flag cleared, on the ship, and
-- with another writer's value. The collector is stopped for each window of 1,200
-- frames, after a warm-up in which every status change and trace has happened.
-- The frames come from an interpreted loop, as the game calls update from C.
do
    local env = install()
    local function drive(frames, dt) for _ = 1, frames do env.update(dt) end end
    jit.off(drive)
    local function garbage(frames, dt)
        collectgarbage('collect'); collectgarbage('stop') -- lint-ok: R4 test only: counts garbage with the collector stopped
        local before = collectgarbage('count')
        drive(frames, dt)
        local grown = (collectgarbage('count') - before) * 1024
        collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped
        return grown
    end
    local scenes = {
        {'mission, between polls', function() ready(); env.update(0.1) end, 0},
        {'mission, every frame polls', function() ready(); env.update(0.1) end, 0.1},
        {'ship, every frame polls', function() ffi.fill(manager, patch.size, 0) end, 0.1},
        {'another writer, every frame polls', function() ready(); env.update(0.1); manager[0] = 2 end, 0.1},
    }
    for _, compiled in ipairs({false, true}) do
        if compiled then jit.on() else jit.off(); jit.flush() end -- lint-ok: R5 test only: the interpreter, then compiled code
        for _, scene in ipairs(scenes) do
            scene[2]()
            drive(compiled and 3000 or 20, scene[3])
            local grown = garbage(1200, scene[3])
            assert(grown == 0, scene[1] .. (compiled and ', compiled: ' or ', interpreted: ') .. grown .. ' bytes')
        end
    end
    jit.on() -- lint-ok: R5 test only: restores the JIT
end
pass('no allocation on frames between polls or on polled frames, interpreted and compiled')

-- Pause: an update below raises; the next frame puts the game's value back over
-- this mod's write and skips the mod until 60 updates below have returned, then
-- it starts afresh and clears the flag again at once.
do
    local env, status = install()
    ready()
    env.update(0.1)
    assert(manager[0] == 0 and status.state == 'running')
    fail_below(env)
    local old_writes, old_restores = writes, restores
    env.update(0.1)
    assert(manager[0] == 1 and restores == old_restores + 1 and not env.HellpodSteeringUnlocked.active)
    assert(env.HellpodSteeringUnlocked.status == 'paused: the previous update failed; avoidance_restored')
    assert(status.state == 'paused: the previous update failed' and status.pauses == 1 and status.lower_errors == 1)
    for _ = 1, 59 do env.update(0.1) end
    assert(manager[0] == 1 and writes == old_writes, 'no check while paused')
    env.update(0.1)
    assert(status.state == 'running' and manager[0] == 0 and writes == old_writes + 1)
    assert(env.HellpodSteeringUnlocked.status == 'avoidance_settings_ready' and env.HellpodSteeringUnlocked.active)
    -- A pause with nothing of this mod's to restore writes nothing.
    manager[0] = 2
    env.update(0.1)
    fail_below(env)
    old_restores = restores
    env.update(0.1)
    assert(manager[0] == 2 and restores == old_restores and status.pauses == 2)
    assert(env.HellpodSteeringUnlocked.status == 'paused: the previous update failed')
end
pass('an error below pauses the mod with the game value restored; 60 clean updates resume it afresh')

-- Errors below that keep coming stop the mod after 8; the pause restored once.
do
    local env, status = install()
    ready()
    env.update(0.1)
    local old_restores = restores
    for frame = 1, 40 do
        env.failing = frame % 2 == 1
        pcall(env.update, 0.1)
    end
    env.failing = false
    assert(status.state == 'stopped: stopped after 8 failed updates below this mod', status.state)
    assert(status.lower_errors == 8 and status.pauses == 1 and manager[0] == 1 and restores == old_restores + 1)
    ready()
    local old_writes = writes
    for _ = 1, 30 do env.update(0.1) end
    assert(writes == old_writes and manager[0] == 1, 'a stopped mod never checks again')
    assert(env.HellpodSteeringUnlocked.status == 'stopped: stopped after 8 failed updates below this mod')
    env.shutdown()
    assert(env.shutdowns == 1 and status.state == 'stopped after: stopped after 8 failed updates below this mod')
end
pass('8 failed updates below stop the mod; the first failure survives shutdown')

-- Bursts: the mod's own errors (apply raising) and errors below are counted
-- apart; a minute of clean frames (3600) ends a burst, so rare errors never add
-- up; the 8th error of one burst stops the mod and restores its write.
do
    local failing = true
    local flaky = setmetatable({apply = function(...)
        if failing then error('apply failed', 0) end
        return patch.apply(...)
    end}, {__index = patch})
    local env, status = install({patch = flaky})
    ready()
    for _ = 1, 7 do env.update(0.1) end
    assert(status.errors == 7 and status.state == 'running' and env.HellpodSteeringUnlocked.status == 'error: apply failed')
    failing = false
    for _ = 1, 3600 do env.update(0.1) end
    assert(status.errors == 0 and manager[0] == 0 and env.HellpodSteeringUnlocked.active)
    failing = true
    for _ = 1, 7 do env.update(0.1) end
    assert(status.errors == 7 and status.state == 'running')
    env.update(0.1)
    assert(status.state == 'stopped: stopped after 8 errors: apply failed', status.state)
    assert(manager[0] == 1, 'the write is restored when the mod stops')
    local error_lines = 0
    for _, line in ipairs(env.lines) do
        if line:find('error: apply failed', 1, true) then error_lines = error_lines + 1 end
    end
    assert(error_lines == 2, 'one line per burst')
end
do
    local env, status = install()
    ready()
    env.update(0.01)
    -- Ten errors below, one every 3700 frames, then the pause after the tenth
    -- and its 60 frames until the resume.
    for frame = 1, 3700 * 10 + 61 do
        env.failing = frame % 3700 == 0 and frame <= 3700 * 10
        pcall(env.update, 0.01)
    end
    env.failing = false
    assert(status.pauses == 10 and status.state == 'running' and status.lower_errors <= 1, status.state)
    assert(manager[0] == 0, 'cleared again after every pause')
end
pass('own errors and errors below are counted per burst: rare ones never stop the mod, 8 in a burst do')

-- A refusal stops the mod at once; a write it cannot verify is not restored.
-- A pause whose restore is refused stops the mod. Shutdown writes nothing.
do
    local env, status = install()
    ready()
    env.update(0.1)
    u32(32772, 1025)
    local old_writes, old_restores = writes, restores
    env.update(0.1)
    assert(status.state == 'stopped: avoidance_layout_mismatch' and not env.HellpodSteeringUnlocked.active)
    assert(env.HellpodSteeringUnlocked.status == 'stopped: avoidance_layout_mismatch')
    ready()
    for _ = 1, 10 do env.update(0.1) end
    assert(writes == old_writes and restores == old_restores and manager[0] == 1)

    local refusing = setmetatable({}, {__index = loader_api})
    env, status = install({api = refusing})
    ready()
    env.update(0.1)
    refusing.write_batch = function() return false, 0 end
    refusing.writable_data = function() return false end
    fail_below(env)
    env.update(0.1)
    assert(status.state == 'stopped: pause failed: avoidance_is_not_writable_private_data', status.state)
    assert(manager[0] == 0)

    env, status = install()
    ready()
    env.update(0.1)
    old_restores = restores
    env.shutdown()
    assert(env.shutdowns == 1 and manager[0] == 0 and restores == old_restores and status.state == 'stopped')
end
pass('a refusal stops at once; a refused restore stops the mod; shutdown writes nothing')

local env = setmetatable({print = function() end, os = {getenv = function() end},
    update = function() end}, {__index = _G})
env._G = env
local previous = env.update
setfenv(assert(loadfile(build .. '/mod.ljbc')), env)()
assert(env.update == previous and env.HellpodSteeringUnlocked.active == false)
-- The embedded runtime's memory API ran and looked for the game modules.
assert(env.HellpodSteeringUnlocked.status:find('Required game modules unavailable', 1, true),
    env.HellpodSteeringUnlocked.status)
pass('compiled module rejects the non-game test host')
print(count .. ' data-only hellpod checks passed; no game process was accessed.')
