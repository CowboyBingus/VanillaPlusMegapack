-- Resolve overlapping resources under either manager priority, then exercise
-- the real compiled modules and their independent re-entry guards off-game.
local root, build, loader = assert(arg[1]), assert(arg[2]), assert(arg[3])
local function read(path)
    local file = assert(io.open(path, 'rb'))
    local bytes = file:read('*a'); file:close(); return bytes
end
local components = {}
-- Most components ship compiled gameplay modules behind an archive loader.
-- Clickable Scrollbars ships the standalone plaintext addon itself, so its
-- source file and its re-entry guard are named directly.
local entries = {KnowYourConstellation = 'install.lua', ArmoryPreviewCache = 'install.lua',
                 ClickableScrollbars = 'clickable_scrollbars.lua',
                 ArcThrowerRevamped = 'arc_thrower_auto.lua',
                 GalacticMenuHotkey = 'galactic_menu_hotkey.lua'}
local guards = {ClickableScrollbars = 'ClickableScrollbars',
                ArcThrowerRevamped = 'ArcThrowerRevampedInstalled',
                GalacticMenuHotkey = 'GalacticMenuHotkeyInstalled'}
for i = 4, #arg, 2 do
    local module, slug = arg[i], assert(arg[i + 1])
    local entry = entries[slug] or 'archive_loader.lua'
    local source = read(root .. '/components/' .. slug .. '/src/' .. entry)
    local guard = guards[slug] or source:match("rawget%(_G,%s*'(%w+)'%)")
        or source:match('_G%.(%w+) then return end')
    components[#components + 1] = {module = module, guard = assert(guard),
        bytes = read(build .. '/' .. slug .. '/mod.lua.main'):sub(9),
        entry = read(build .. '/' .. slug .. '/entry.lua.main'):sub(9)}
end
local pack = 'mods/cowboybingus/vanilla_plus_megapack'
-- The shared loader build's registry predates Clickable Scrollbars, so the
-- registry path never asks for it: declared-entry discovery installs it in game
-- (proved by test_loader.lua's discovery pass) and its own suite proves the
-- re-entry guard. This test therefore only asserts that the registry leaves it
-- alone, and excludes it from the registry-driven re-entry phase.
local registry_cannot_see = {['mods/cowboybingus/clickable_scrollbars'] = true,
                             ['mods/cowboybingus/arc_thrower_auto'] = true,
                             ['mods/cowboybingus/galactic_menu_hotkey'] = true}
local cases = 0
for mask = 0, 2 ^ #components - 1 do
  for _, pack_wins in ipairs({false, true}) do
    local env = {}; for key, value in pairs(_G) do env[key] = value end
    env._G, env.print = env, function() end
    env.os = {getenv = function() end, clock = os.clock}
    env.io = {open = function() return nil end}
    local available = {[pack] = {bytes = read(build .. '/entry.lua.main'):sub(9)}}
    local loaded, calls, owners = {}, {}, {}
    local function execute(bytes)
        return setfenv(assert(loadstring(bytes)), env)()
    end
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    for i, component in ipairs(components) do
        local bundled = {bytes = component.entry, owner = 'pack'}
        local standalone = {bytes = component.bytes, owner = 'standalone'}
        local installed = math.floor(mask / 2 ^ (i - 1)) % 2 == 1
        -- A Lua resource has one winning value, regardless of archive name.
        available[component.module] = installed and not pack_wins and standalone or bundled
        owners[component.module] = installed and not pack_wins and 'standalone' or 'pack'
    end
    local updates, shutdowns = 0, 0
    env.update = function() updates = updates + 1; return 1, nil, 3 end
    env.shutdown = function() shutdowns = shutdowns + 1; return 4, nil, 6 end
    env.stingray = {Application = {build = function() return 'release' end,
        can_get = function(kind, name) assert(kind == 'lua'); return available[name] ~= nil end}}
    env.require = function(name)
        if name == 'ffi' or name == 'bit' then return require(name) end
        if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then return {} end
        if loaded[name] ~= nil then return loaded[name] end
        local resource = assert(available[name], 'Missing resource reached require')
        assert(resource.owner == owners[name])
        calls[name] = (calls[name] or 0) + 1
        loaded[name] = execute(resource.bytes) or true
        return loaded[name]
    end
    execute(read(loader .. '/callbacks.ljbc'))
    local coordinator = assert(env.CowboyBingusModLoader)
    local states = {}
    for _, component in ipairs(components) do
        if registry_cannot_see[component.module] then
            assert((calls[component.module] or 0) == 0)
            assert(coordinator.modules[component.module] == nil)
            assert(env[component.guard] == nil)
        else
            assert(calls[component.module] == 1)
            assert(coordinator.modules[component.module] == 'loaded')
            states[component.guard] = assert(env[component.guard])
        end
    end
    local update, shutdown = env.update, env.shutdown
    -- Bypass require caching to prove a second archive's entry point cannot
    -- install another callback or replace the first version's state.
    for i = #components, 1, -1 do
        if not registry_cannot_see[components[i].module] then execute(components[i].bytes) end
    end
    execute(read(loader .. '/callbacks.ljbc'))
    assert(env.CowboyBingusModLoader == coordinator)
    assert(env.update == update and env.shutdown == shutdown)
    for _, component in ipairs(components) do
        if registry_cannot_see[component.module] then
            assert(env[component.guard] == nil)
        else
            assert(env[component.guard] == states[component.guard])
        end
        assert((calls[component.module] or 0) == (registry_cannot_see[component.module] and 0 or 1))
    end
    local a, b, c = env.update(0.1)
    assert(a == 1 and b == nil and c == 3 and updates == 1)
    local x, y, z = env.shutdown()
    assert(x == 4 and y == nil and z == 6 and shutdowns == 1)
    cases = cases + 1
  end
end
print('PASS: ' .. cases .. ' duplicate-install combinations; both priorities, one module state, no stacked callbacks, original return tuples preserved')
