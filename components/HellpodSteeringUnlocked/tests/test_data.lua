-- Local synthetic allocations and loader environments only; no game access.
local source, build, executable_hash = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local create_api = assert(loadfile(source .. '/windows_api.lua'))()
local patch = assert(loadfile(source .. '/steering_patch.lua'))()
local real = create_api()
local count = 0
local function pass(name) count = count + 1; print('PASS: ' .. name) end
assert(real.module_hash(real.module(nil)) == executable_hash)
assert(real.read(ffi.cast('void *', 1), 8) == nil)
assert(not real.writable_data(real.module(nil), 1))
assert(not real.write(real.module(nil), '\0'))
pass('copied restricted writer hashes modules and refuses module pages')

local storage = ffi.new('uint8_t[?]', patch.size)
local manager = ffi.cast('uint8_t *', storage)
local game_storage = ffi.new('uint8_t[1]')
local game = ffi.cast('uint8_t *', game_storage)
local owner = manager - patch.owner_offset
local function pointer(value) return ffi.string(ffi.new('void *[1]', value), 8) end
local function u32(offset, value) ffi.copy(manager + offset, ffi.new('uint32_t[1]', value), 4) end
local function float(offset, value) ffi.copy(manager + offset, ffi.new('float[1]', value), 4) end
local writes = 0
local api = setmetatable({}, {__index = real})
api.read = function(address, size)
    if address == game + patch.manager_rva then assert(size == 8); return pointer(manager) end
    if address == game + patch.owner_rva then assert(size == 8); return pointer(owner) end
    return real.read(address, size)
end
api.write = function(address, bytes)
    assert(address == manager and bytes == '\0')
    writes = writes + 1
    return real.write(address, bytes)
end
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
local ok, reason, active = patch.apply(api, game)
assert(ok and reason == 'waiting_for_mission' and not active and writes == 0)
ready()
local before = ffi.string(manager, patch.size)
ok, reason, active = patch.apply(api, game)
assert(ok and active and reason == 'avoidance_settings_ready' and writes == 1)
assert(ffi.string(manager, patch.size) == '\0' .. before:sub(2))
assert(patch.apply(api, game) and writes == 1)
ready(); assert(patch.apply(api, game) and writes == 2)
pass('ship initialization waits; exactly one data byte changes; mission reset reapplies')

for _, defect in ipairs({
    function() manager[0] = 2 end,
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
    assert(not patch.apply(api, game))
    assert(writes == old_writes and ffi.string(manager, patch.size) == unchanged)
end
ready()
for _, kind in ipairs({'owner', 'permissions', 'unreadable', 'write_failure', 'identity_changed'}) do
    local altered = setmetatable({}, {__index = api})
    local reads = 0
    altered.read = function(address, size)
        if address == game + patch.manager_rva then
            reads = reads + 1
            if kind == 'identity_changed' and reads == 2 then return pointer(manager + 16) end
        end
        if kind == 'owner' and address == game + patch.owner_rva then return pointer(owner + 8) end
        if kind == 'unreadable' and address == manager + 32772 then return nil end
        return api.read(address, size)
    end
    if kind == 'permissions' then altered.writable_data = function() return false end end
    if kind == 'write_failure' then altered.write = function() return false end end
    local accepted, status = patch.apply(altered, game)
    assert(not accepted or (kind == 'identity_changed' and status == 'waiting_for_stable_mission'))
    assert(ffi.string(manager, patch.size) == before)
end
pass('layout, pointer, page, read, write and reset-race failures leave data unchanged')

local bounce_source = arg[4]
local identity = {revision = 'fixture', exe_sha256 = 'exe', game_sha256 = 'game'}
for _, mode in ipairs({'success', 'bounce_failure', 'hellpod_failure', 'exe', 'game', 'ffi'}) do
    local updates, checks, bounce_checks, factories = 0, 0, 0, 0
    local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
    env._G = env
    local shutdown = function() end
    env.shutdown = shutdown
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
    local function initialize(path, make_api, probe)
        local chunk = assert(loadfile(path)); setfenv(chunk, env)
        local loader = chunk(); setfenv(loader, env)
        loader(make_api, probe, identity)
    end
    if bounce_source then
        initialize(bounce_source .. '/archive_loader.lua', function()
            return {module = function(name) return name and 'game' or 'exe' end,
                    module_hash = function(module) return module end}
        end, {apply = function() bounce_checks = bounce_checks + 1; return mode ~= 'bounce_failure', 'bounce result' end})
    end
    local probe = {apply = function()
        checks = checks + 1
        return mode ~= 'hellpod_failure', checks == 1 and 'waiting_for_mission' or 'avoidance_settings_ready', checks > 1
    end}
    initialize(source .. '/archive_loader.lua', factory, probe)
    initialize(source .. '/archive_loader.lua', factory, probe)
    for _ = 1, 5 do env.update(0.1, 123) end
    assert(updates == 5 and factories == 1 and bounce_checks == (bounce_source and 1 or 0) and env.shutdown == shutdown)
    assert(checks == ((mode == 'ffi' or mode == 'exe' or mode == 'game') and 0 or mode == 'hellpod_failure' and 1 or 5))
    assert(env.HellpodSteeringUnlocked.active == (mode == 'success' or mode == 'bounce_failure'))
    if bounce_source then assert(env.BetterStratagemBounce.active == (mode ~= 'bounce_failure')) end
end
pass('loader handles failures, duplicate initialization and existing update callbacks')

-- The standalone wrapper preserves return values and nil holes of update.
local env = setmetatable({print = function() end, os = {getenv = function() end}}, {__index = _G})
env._G = env
env.update = function() return 1, nil, 3 end
local chunk = assert(loadfile(source .. '/archive_loader.lua')); setfenv(chunk, env)
local loader = chunk(); setfenv(loader, env)
loader(function() return {module = function(name) return name and 'game' or 'exe' end,
    module_hash = function(module) return module end} end,
    {apply = function() return true, 'waiting_for_mission', false end}, identity)
local results = {env.update(0.1)}
assert(results[1] == 1 and results[2] == nil and results[3] == 3 and select('#', env.update(0.1)) == 3)
pass('standalone update forwards return values unchanged')

local env = setmetatable({print = function() end, os = {getenv = function() end},
    update = function() end}, {__index = _G})
env._G = env
local previous = env.update
setfenv(assert(loadfile(build .. '/mod.ljbc')), env)()
assert(env.update == previous and env.HellpodSteeringUnlocked.active == false)
pass('compiled module rejects the non-game test host')
print(count .. ' data-only hellpod checks passed; no game process was accessed.')
