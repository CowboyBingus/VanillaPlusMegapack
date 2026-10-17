-- Holster Your Shield in a hostile shared Lua state (tests/hostile_vm.lua): another mod declared the Windows names
-- first with wrong prototypes, an update below raises, a neighbour calls the chain twice per frame. The addon is
-- installed through Holster.install with the real runtime guard (src/bingus_runtime.lua) on the simulated game.
-- Runs in a LuaJIT 2.1 and in the game's lua51.dll (tests/game_lua.py).
-- Usage: luajit tests/test_hostile.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_hostile.lua <repository root>')
local H = dofile(root .. '/tests/hostile_vm.lua')
-- Before anything declares them: the names a careless neighbour would take.
local clashed = H.clash({'ReadProcessMemory', 'GetCurrentProcess', 'memcpy'})
local G = dofile(root .. '/tests/fake_game.lua')(root)
local Holster = G.Holster
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local ffi = G.ffi
local passed = 0
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ': ' .. tostring(err), 0) end
    passed = passed + 1
end

-- Installs the addon on a world with the shield in hand; returns the env, the instance, the world, the log lines.
local function installed(neighbour, options)
    local w = G.world()
    w.set_row({backpack = G.SHIELD, held = G.SHIELD, slot = 2, mode = 2})
    local lines = {}
    _G.CowboyBingusModLoader = {api = 1, jit = {}, open_log = function()
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}
    local env = {update = function() end}
    if neighbour then H.chain(env, neighbour, options) end
    local api = G.api(w)
    api.bind = function() end
    local memory = {module = function() return G.GAME end, address = function(v) return v end,
                    verify_build = function() return true end}
    local quiet = print
    print = function() end
    local instance = Holster.install(runtime, memory, {env = env, adapter = function() return api end})
    print = quiet
    _G.CowboyBingusModLoader = nil
    assert(instance, 'not installed: ' .. table.concat(lines, ' | '))
    return env, instance, w, lines, api
end

check('the adapter keeps working after a neighbour declared its Windows names', function()
    for name, status in pairs(clashed) do
        assert(status == 'clashed' or status == 'already declared', name .. ': ' .. status)
    end
    local api = Holster.adapter()
    local cell = ffi.new('uint32_t[2]', 0x11223344, 0x55)
    local address = tonumber(ffi.cast('uintptr_t', cell))
    assert(api.view(address, 4) and api.words[0] == 0x11223344, 'view')
    assert(api.u64(address) == 0x11223344 + 0x55 * 4294967296, 'u64')
end)

check('an update below that raises pauses the addon: the toggle ends, the error passes unchanged', function()
    local env, instance, w, lines = installed('throw_below', {raise_on = 60})
    for _ = 1, Holster.CHECK_FRAMES + 1 do env.update(1 / 60) end
    w.press()
    env.update(1 / 60)
    w.release()
    assert(instance.toggled, 'no toggle: ' .. table.concat(lines, ' | '))
    local raised
    for _ = 1, 40 do
        local ok, err = pcall(env.update, 1 / 60)
        if not ok then raised = err; break end
    end
    assert(type(raised) == 'table' and raised.hostile_vm == 'throw_below', 'the error below changed: '
        .. tostring(raised))
    env.update(1 / 60) -- the guard sees the failure and pauses the addon
    assert(not instance.toggled and instance.kept == nil, 'not reset by the pause')
    local found
    for _, line in ipairs(lines) do if line:find('^Paused') then found = true end end
    assert(found, table.concat(lines, ' | '))
    -- after 60 clean frames the guard resumes and the next check frame finds the Helldiver again
    for _ = 1, 60 + Holster.CHECK_FRAMES + 1 do env.update(1 / 60) end
    assert(instance.kept, 'not resolved after the resume: ' .. table.concat(lines, ' | '))
end)

check('a neighbour that calls the chain twice per frame: one press is still one press', function()
    local env, instance, w = installed('double_call')
    for _ = 1, Holster.CHECK_FRAMES + 1 do env.update(1 / 60) end
    w.press()
    env.update(1 / 60)
    w.release()
    env.update(1 / 60)
    assert(instance.counts.presses == 1 and instance.counts.holsters == 1, instance:summary())
end)

check('shutdown logs the session summary', function()
    local env, instance, _, lines = installed()
    env.update(1 / 60)
    env.shutdown()
    assert(lines[#lines]:find('^Stopped %(shutdown%): presses 0'), lines[#lines])
    assert(instance.guard.status.state:find('^stopped'), instance.guard.status.state)
end)

print(string.format('PASS: %d Holster Your Shield hostile-state checks (%s)', passed,
                    jit and jit.version or _VERSION))
