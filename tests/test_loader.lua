-- Run real compiled bundle and loader in an isolated, non-game environment.
local build, loader = assert(arg[1]), assert(arg[2])
local discovery_only = arg[3] == 'discovery'
-- Scenarios represent separate game starts but share this LuaJIT process.
-- Declare each exact FFI block once: repeated typedefs otherwise exhaust its
-- process-wide CType table after thousands of synthetic addon installations.
-- The first use still executes the real declaration and validates its types.
local ffi = require('ffi')
local declarations = {}
local scenario_ffi = setmetatable({cdef = function(body)
    if not declarations[body] then
        ffi.cdef(body)
        declarations[body] = true
    end
end}, {__index = ffi})
local pack = 'mods/cowboybingus/vanilla_plus_megapack'
local wwise = 'core/wwise/lua/wwise_flow_callbacks'
local names = {pack, 'mods/cowboybingus/better_stratagem_bounce',
    'mods/cowboybingus/hellpod_steering_unlocked', 'mods/cowboybingus/reinforcement_beacon_fix_data',
    'mods/cowboybingus/consistent_vaulting', 'mods/cowboybingus/shallow_water_dive',
    'mods/cowboybingus/sentry_aim_retention', 'mods/cowboybingus/corpse_collision_repair', 'mods/cowboybingus/hover_pack_cancel', 'mods/cowboybingus/enemy_intelligence', 'mods/cowboybingus/armory_preview_cache',
    'mods/cowboybingus/clickable_scrollbars', 'mods/cowboybingus/arc_thrower_auto', 'mods/cowboybingus/galactic_menu_hotkey'}
local folders = {'', 'BetterStratagemBounce', 'HellpodSteeringUnlocked', 'ReinforcementBeaconsFixed',
    'ConsistentVaulting', 'ShallowWaterDiving', 'SentryAimRetention', 'EnemyCollisionSynchronized', 'ControllableHoverPack', 'KnowYourConstellation', 'ArmoryPreviewCache',
    'ClickableScrollbars', 'ArcThrowerRevamped', 'GalacticMenuHotkey'}
-- The shared loader build carries a built-in registry written before this
-- component existed, so the registry path cannot see it: in game it is loaded
-- through declared-entry discovery, which the 'discovery' pass below proves by
-- running with that registry emptied. Both paths are asserted separately here
-- instead of pretending the older registry knows the new module.
local registry_cannot_see = {['mods/cowboybingus/clickable_scrollbars'] = true, ['mods/cowboybingus/arc_thrower_auto'] = true, ['mods/cowboybingus/galactic_menu_hotkey'] = true}
local function read(path)
    local file = assert(io.open(path, 'rb'))
    local bytes = file:read('*a'); file:close(); return bytes
end
local sources = {}
for i, name in ipairs(names) do sources[name] = read(build .. '/' .. folders[i] .. '/entry.lua.main'):sub(9) end
local startup = read(loader .. '/callbacks.ljbc')
if discovery_only then
    local wrapper, replacements = read(loader .. '/callbacks.wrapper.lua'):gsub('local names = {%s*.-\n}', 'local names = {}', 1)
    assert(replacements == 1, 'Expected exactly one legacy registry to remove for discovery proof')
    startup = string.dump(assert(loadstring(wrapper)), true)
end
local cases = 0
local scenarios = {}
for _, installed_loader in ipairs({false, true}) do
  for _, installed_pack in ipairs({false, true}) do
    for failure = 0, #names * 2 do
        scenarios[#scenarios + 1] = {installed_loader, installed_pack, failure}
    end
  end
  for mask = 0, 2 ^ (#names - 1) - 1 do
    scenarios[#scenarios + 1] = {installed_loader, mask ~= 0, 0, mask}
  end
end
for _, scenario in ipairs(scenarios) do
        local installed_loader, installed_pack, failure, mask = unpack(scenario)
        local env = {}; for key, value in pairs(_G) do env[key] = value end
        env._G, env.print = env, function() end
        env.os = {getenv = function() end, clock = os.clock}
        env.io = {open = function() return nil end}
        local available, count, loaded = {}, {}, {}
        for i, name in ipairs(names) do
            available[name] = installed_pack and failure ~= i
            if mask and i > 1 then
                available[name] = math.floor(mask / 2 ^ (i - 2)) % 2 == 1
            end
        end
        if discovery_only then
            local ffi, bit = require('ffi'), require('bit')
            local archives, index = {}, 0
            for i = 2, #names do
                if available[names[i]] then archives[#archives + 1] = build .. '/options/' .. folders[i] .. '/9ba626afa44a3aa3.patch_0' end
            end
            local function fill(buffer)
                ffi.fill(buffer, 320)
                ffi.copy(buffer + 44, '9ba626afa44a3aa3.patch_' .. index)
            end
            local kernel = {
                GetModuleFileNameA = function(_, buffer)
                    -- Fictional drive: the loader requires an absolute game path.
                    -- This fixture does not refer to a developer installation.
                    local path = 'T:/discovery-fixture/bin/helldivers2.exe'
                    ffi.copy(buffer, path); return #path
                end,
                FindFirstFileA = function(_, buffer)
                    index = 1
                    if #archives == 0 then return ffi.cast('void *', -1) end
                    fill(buffer); return ffi.cast('void *', 1)
                end,
                FindNextFileA = function(_, buffer)
                    index = index + 1
                    if index > #archives then return 0 end
                    fill(buffer); return 1
                end,
                GetLastError = function() return 18 end,
                FindClose = function() return 1 end,
            }
            -- Mocked Win32 calls need no declarations. Repeating cdef thousands
            -- of times exhausts the process-wide LuaJIT CType table; production
            -- discovery declares these once, and the loader's native test covers it.
            local scanner_ffi = setmetatable({cdef = function() end,
                load = function(name) assert(name == 'kernel32'); return kernel end}, {__index = ffi})
            env.package = {loaded = {ffi = scanner_ffi, bit = bit}, preload = {}}
            env.io = {open = function(path, mode)
                assert(mode == 'rb', 'Discovery must be read-only')
                local slot = assert(tonumber(path:match('^T:/discovery%-fixture/data/9ba626afa44a3aa3%.patch_(%d+)$')))
                return io.open(assert(archives[slot]), mode)
            end}
        end
        env.stingray = {Application = {build = function() return 'release' end,
            can_get = function(kind, name) assert(kind == 'lua'); return available[name] or false end}}
        local function execute(bytes)
            return setfenv(assert(loadstring(bytes)), env)()
        end
        env.loadstring = function(bytes, name)
            local chunk, reason = loadstring(bytes, name)
            if chunk then setfenv(chunk, env) end
            return chunk, reason
        end
        env.require = function(name)
            if loaded[name] ~= nil then return loaded[name] end
            if name == 'ffi' then return scenario_ffi end
            if name == 'bit' then return require(name) end
            if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then return {} end
            if name == wwise then
                return execute(installed_loader and startup or read(loader .. '/vanilla-callbacks.ljbc'))
            end
            assert(available[name], 'Missing resource reached require')
            count[name] = (count[name] or 0) + 1
            if name == names[failure - #names] then error('injected load failure') end
            loaded[name] = execute(assert(sources[name], name)) or true
            return loaded[name]
        end
        execute(read(loader .. '/vanilla-boot.ljbc'))
        local updates = 0
        env.update = function(dt) assert(dt == 0.1); updates = updates + 1; return 1, nil, 3 end
        env.shutdown = function() return 'shutdown', nil, 7 end
        env.init()
        if installed_loader then
            assert(env.CowboyBingusModLoader.version >= 16 and env.CowboyBingusModLoader.api == 1)
            execute(startup)
            for i, name in ipairs(names) do
                if not discovery_only and registry_cannot_see[name] then
                    -- The registry never asks for it, so nothing may load it.
                    assert((count[name] or 0) == 0, name)
                    assert(env.CowboyBingusModLoader.modules[name] == nil, name)
                else
                assert((count[name] or 0) == (available[name] and 1 or 0), name .. ': ' .. tostring(env.CowboyBingusModLoader.discovery) .. '; count=' .. tostring(count[name]) .. '; failure=' .. failure .. '; mask=' .. tostring(mask))
                local status = env.CowboyBingusModLoader.modules[name]
                if not available[name] then assert(status == 'not installed' or discovery_only and status == nil)
                elseif failure == i + #names then assert(status:find('load failed:', 1, true))
                else assert(status == 'loaded', name .. ': ' .. status) end
                end
            end
            local identity = env.CowboyBingusModLoader.megapack
            if installed_pack and failure ~= 1 and failure ~= #names + 1 then
                assert(identity.name == 'Vanilla Plus Megapack' and identity.revision == 'megapack-v31')
                -- A loader that manages the LuaJIT cache (v18+) sets loader.jit; the pack then leaves it alone.
                local managed = env.CowboyBingusModLoader.jit and env.CowboyBingusModLoader.jit.managed
                assert((identity.jit_fallback == nil) == (managed == true))
                assert(#identity.modules == #names - 1)
                for i = 2, #names do assert(identity.modules[i-1] == names[i]) end
            else assert(identity == nil) end
        else
            assert(env.CowboyBingusModLoader == nil and next(count) == nil)
        end
        local a, b, c = env.update(0.1)
        assert(a == 1 and b == nil and c == 3 and updates == 1)
        assert(select('#', env.update(0.1)) == 3 and updates == 2)
        local x, y, z = env.shutdown()
        assert(x == 'shutdown' and y == nil and z == 7)
        cases = cases + 1
end
-- Older loaders (no loader.jit) get the pack's one-time LuaJIT cache limits;
-- v18+ loaders keep ownership; a missing or failing jit library is ignored.
local function run_pack(loader_state, library)
    local env = {}; for key, value in pairs(_G) do env[key] = value end
    env._G, env.CowboyBingusModLoader, env.jit = env, loader_state, library
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    return setfenv(assert(loadstring(sources[pack])), env)()
end
local calls = {}
local recorder = {opt = {start = function(...) calls[#calls + 1] = table.concat({...}, ' ') end}}
local old = run_pack({version = 16, api = 1, modules = {}}, recorder)
assert(old.jit_fallback == 'maxmcode=16384 maxtrace=8000' and #calls == 1 and calls[1] == old.jit_fallback)
calls = {}
assert(run_pack({version = 17, api = 1, modules = {}, jit = {managed = true, expanded = false}}, recorder).jit_fallback == nil)
assert(#calls == 0, 'A managed cache stays with the loader, whatever its current limits')
assert(run_pack({version = 17, api = 1, modules = {}, jit = {managed = false}}, recorder).jit_fallback ~= nil and #calls == 1)
assert(run_pack({version = 16, api = 1, modules = {}}, nil).jit_fallback == nil)
local broken = {opt = {start = function() error('unknown or malformed optimization flag') end}}
assert(run_pack({version = 16, api = 1, modules = {}}, broken).jit_fallback == nil)
print('PASS: ' .. cases .. (discovery_only and ' discovery-only (legacy list removed)' or ' normal loader') .. ' bundle scenarios; all ' .. 2 ^ (#names - 1) .. ' option subsets with/without loader, failures isolated, one startup, callbacks preserved; LuaJIT cache fallback only for older loaders')
