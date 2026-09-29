-- The generated addon entry (build/better_lobby_management.lua), loaded as the loader
-- would, in a process without game.dll: it must stay inactive, leave the
-- update chain alone, log why, and load only once.
-- Usage: test_entry.lua <build/better_lobby_management.lua> <version, e.g. v0.4>
local path = assert(arg[1], 'entry path required')
local version = assert(arg[2], 'version required')
local file = assert(io.open(path, 'rb'))
local text = file:read('*a')
file:close()
local declaration = '-- HD2-Addon: mods/cowboybingus/better_lobby_management\n'
assert(text:sub(1, #declaration) == declaration, 'discovery declaration must be the first line')
assert(not text:find('\r', 1, true) and not text:find('^\239\187\191'), 'LF, no BOM')

local lines = {}
rawset(_G, 'BetterLobbyManagement', nil)
rawset(_G, 'CowboyBingusModLoader', {api = 1, version = 17, open_log = function(name)
    assert(name == 'BetterLobbyManagement.log')
    return {write = function(_, line) lines[#lines + 1] = line end, flush = function() end}
end})
local function game_update(dt) return 'game', dt end
local function game_shutdown() return 'bye' end
rawset(_G, 'update', game_update)
rawset(_G, 'shutdown', game_shutdown)
dofile(path)
local state = assert(rawget(_G, 'BetterLobbyManagement'))
assert(state.version == version, tostring(state.version))
assert(state.status == 'unsupported: game modules unavailable', state.status)
assert(rawget(_G, 'update') == game_update and rawget(_G, 'shutdown') == game_shutdown,
    'update and shutdown stay untouched when inactive')
assert(#lines == 1 and lines[1]:find('Better Lobby Management ' .. version .. ' inactive: game modules unavailable\n', 1, true),
    table.concat(lines))
dofile(path)
assert(#lines == 1 and rawget(_G, 'BetterLobbyManagement') == state, 'a second load must do nothing')
print('PASS: generated entry loads in the game VM; without game.dll it stays inactive, logs once and loads once')
