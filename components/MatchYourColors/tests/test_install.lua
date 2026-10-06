-- Match Your Colors: the startup path (Addon.install) against a fake loader, a fake memory api over a simulated
-- game, the engine's function tables at their expected executable offsets, Bingus Shared Runtime's guard and a
-- fake Mod Options Menu: install, refusals, the guard's update hook, option registration and callbacks. No
-- engine function is ever called here (no local player exists in the simulated game).
-- Usage: luajit tests/test_install.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_install.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Fake = dofile(root .. '/tests/fake_game.lua')
local modules = {}
for _, name in ipairs({'avatar', 'preview', 'recolor', 'engine', 'files', 'slim', 'texture', 'colour', 'transfer',
                       'matcher', 'kits', 'cache', 'addon'}) do
    modules[name] = require(name)
end
local Engine, Addon = modules.engine, modules.addon
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local T = dofile(root .. '/src/bingus_text.lua')
local locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local EXE = 0x7FF100000000
local HIGH = 4294967296

-- A simulated game whose script API and engine API tables hold the expected executable addresses (or, with
-- `changed`, one wrong address), and a get_engine_api stand-in.
local function game(changed)
    local space = Fake.world({players = 0})
    space.region(EXE + 0xa4e50, 16)
    local prefix = Engine.GET_ENGINE_API_PREFIX
    for i = 1, #prefix do space.byte(EXE + 0xa4e50 + i - 1, prefix:byte(i)) end
    local script, tables = 0x1A0000000, {unit = 0x1A1000000, mesh = 0x1A2000000, material = 0x1A3000000,
                                         buffers = 0x1A4000000, resources = 0x1A5000000}
    space.region(script, 0x100)
    space.u64(Fake.GAME + Engine.SCRIPT_API_RVA, script)
    space.u64(script + 24, tables.unit) space.u64(script + 232, tables.mesh) space.u64(script + 40, tables.material)
    for _, base in pairs(tables) do space.region(base, 0x800) end
    for name, spec in pairs(Engine.FUNCTIONS) do
        local value = EXE + spec[3]
        if name == changed then value = value + 16 end
        space.u64(tables[spec[1]] + spec[2], value)
    end
    local function get_api(id)
        if id == 26 then return tables.buffers end
        if id == 5 then return tables.resources end
        return 0
    end
    return space, get_api
end

-- bingus_memory's api over the space, with module bases, hashes and the clock.
local function memory_module(space, build_ok)
    local api = Fake.memory(space)
    function api.module(name)
        if name == 'game.dll' then return ffi.cast('uint8_t *', Fake.GAME) end
        if name == nil then return ffi.cast('uint8_t *', EXE) end
        return nil
    end
    function api.address(pointer)
        if type(pointer) == 'number' then return pointer end
        local cell = ffi.new('union { const void *p; struct { uint32_t low, high; }; }')
        cell.p = pointer
        return cell.low + cell.high * HIGH
    end
    function api.verify_build() if build_ok then return true end return false, 'unsupported game build' end
    return {new = function() return api end}
end

-- A fake loader (open_log, after_startup) and Mod Options Menu, installed as the globals the addon reads.
local function globals()
    local log, after = {}, {}
    local loader = {api = 1, jit = {}, capabilities = {after_startup = true},
                    open_log = function() return {write = function(_, line) log[#log + 1] = line end, flush = function() end} end,
                    after_startup = function(fn) after[#after + 1] = fn return true end}
    local menu = {api = 1, version = 3, registered = {}, values = {}, callbacks = {}}
    function menu.register_option(id, spec)
        menu.registered[id] = spec
        if menu.values[id] == nil then menu.values[id] = spec.default end
        return true
    end
    function menu.get(id) return menu.values[id] end
    function menu.on_change(id, fn) menu.callbacks[id] = fn end
    rawset(_G, 'CowboyBingusModLoader', loader) -- lint-ok: R8 test process only
    rawset(_G, 'ModOptionsMenu', menu) -- lint-ok: R8 test process only
    return loader, menu, log, after
end

local function install(options)
    options = options or {}
    rawset(_G, 'BingusRuntime', nil) -- lint-ok: R8 test process only: a fresh shared table, one guard per install
    local space, get_api = game(options.changed)
    local _, menu, log, after = globals()
    local env = {update = function() end, shutdown = function() end}
    local m = {runtime = runtime, memory = memory_module(space, options.build_ok ~= false), T = T, locales = locales,
               env = env, get_engine_api = get_api}
    for name, module in pairs({Avatar = 'avatar', Preview = 'preview', Recolor = 'recolor', Engine = 'engine',
                               Files = 'files', Slim = 'slim', Texture = 'texture', Colour = 'colour', Transfer = 'transfer',
                               Matcher = 'matcher', Kits = 'kits', Cache = 'cache'}) do
        m[name] = modules[module]
    end
    local instance = Addon.install(m)
    return instance, {env = env, menu = menu, log = log, after = after}
end

local function logged(log, pattern)
    for _, line in ipairs(log) do if line:find(pattern) then return true end end
    return false
end

check('install: engine functions verified, guard on the update chain, options registered', function()
    local instance, w = install()
    assert(instance, 'installed: ' .. table.concat(w.log, ' | '))
    assert(logged(w.log, 'initialized'), 'initialized line')
    assert(rawget(w.env, 'MatchYourColorsInstalled') == true, 're-entry guard set')
    for _, fn in ipairs(w.after) do fn() end -- the loader's after_startup event
    local mode, sets = w.menu.registered[Addon.OPTION_MODE], w.menu.registered[Addon.OPTION_SETS]
    assert(mode and mode.type == 'choice' and #mode.choices == 3 and mode.default == 2, 'mode choice')
    assert(mode.mod_id == Addon.MOD_ID and type(mode.label) == 'function' and mode.choices[1] == 'Off', 'texts')
    assert(mode.label() == 'Color Matching' and mode.choices[2]() == 'Helmet Matches Armor', 'English texts')
    assert(sets and sets.type == 'toggle' and sets.default == true, 'complete-set toggle')
    w.menu.callbacks[Addon.OPTION_MODE](3)
    assert(instance.state.options.mode == 3, 'on_change applies the mode')
    w.menu.callbacks[Addon.OPTION_SETS](false)
    assert(instance.state.options.keep_sets == false, 'on_change applies the toggle')
    for _ = 1, 30 do w.env.update(0.016) end -- no local Helldiver: resolves only, no engine call
    assert(instance.state.frame == 30 and instance.state.status == 'starting', 'stepping through the guard')
end)

check('without the after_startup event the options register on an early frame', function()
    local instance, w = install()
    rawset(w.menu, 'registered', {})
    instance.options = nil
    w.env.update(0.016) -- frame 1 is a registration frame
    assert(w.menu.registered[Addon.OPTION_MODE], 'registered on frame 1')
end)

check('refusals: another game build, a changed engine function', function()
    local instance, w = install({build_ok = false})
    assert(not instance and logged(w.log, 'Disabled: unsupported game build'), 'build refused')
    instance, w = install({changed = 'set_resource'})
    assert(not instance and logged(w.log, 'engine function changed: set_resource'), 'changed function refused')
    instance, w = install({changed = 'can_get'})
    assert(not instance and logged(w.log, 'engine function changed: can_get'), 'changed lookup refused')
end)

rawset(_G, 'CowboyBingusModLoader', nil) -- lint-ok: R8 test process only
rawset(_G, 'ModOptionsMenu', nil) -- lint-ok: R8 test process only
rawset(_G, 'BingusRuntime', nil) -- lint-ok: R8 test process only
print('PASS test_install (' .. passed .. ' checks)')
