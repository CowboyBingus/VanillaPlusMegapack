-- The game's shared Lua state made hostile (tests/hostile_vm.lua, a byte-identical
-- copy from Bingus Shared Runtime). Another mod declared every Windows function
-- MOM and its runtime call first, with wrong prototypes (H.clash), and a
-- failing update sits below MOM in the update chain (H.chain 'throw_below').
-- MOM and the runtime declare only private names, so MOM's guarded reads, the
-- runtime's module hash and clock, and the update keep working; the error from
-- below reaches the caller as the same table, and MOM pauses on the next frame.
-- Run it in a fresh Lua state: H.clash must declare its names first.
-- Usage: <lua> tests/test_hostile.lua [path to src/mod_options_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_options_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local H = dofile(root .. '/tests/hostile_vm.lua')
local NAMES = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
               'QueryPerformanceCounter', 'QueryPerformanceFrequency', 'CreateFileW', 'ReadFile', 'CloseHandle',
               'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash', 'BCryptHashData',
               'BCryptFinishHash', 'BCryptDestroyHash'}
local clashed = H.clash(NAMES)
for _, name in ipairs(NAMES) do
    assert(clashed[name] == 'clashed', name .. ': ' .. tostring(clashed[name]))
end

local ffi = require('ffi')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP')) .. '/mom-hostile-test-no-folder'
local lines = {}
_G.CowboyBingusModLoader = {log_directory = directory, open_log = function()
    return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
end}
local Text = dofile(root .. '/src/bingus_text.lua')
Text.registry().steam_language = 'en'
_G.mom_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
_G.mom_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})
local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end

-- The game's update, and a neighbour below MOM that raises on its 3rd frame.
_G.update = function() return 'game' end
local neighbour = H.chain(_G, 'throw_below', {raise_on = 3})
dofile(source)
local menu = assert(ModOptionsMenu)
local status = BingusRuntime.statuses.ModOptionsMenu
assert(status and status.state == 'running', 'the guard installed')
local step = upvalue(update, 'step')
local escape_menu, initialize = upvalue(step, 'escape_menu'), upvalue(step, 'initialize')
local fill, read_pointer = upvalue(escape_menu, 'fill'), upvalue(escape_menu, 'read_pointer')

-- MOM's guarded read, through its private name.
local cell = ffi.new('uint64_t[2]', 0x123456789a, 0)
assert(read_pointer(tonumber(ffi.cast('uint64_t', cell))) == 0x123456789a, 'read_pointer')
assert(read_pointer(16) == nil and not fill(ffi.new('uint32_t[2]'), 16, 8), 'a bad address fails the read')
-- The runtime: module hash (once per session) and clock, through its private names.
local memory = upvalue(initialize, 'memory')
local kernel = memory.module('kernel32.dll')
local hash = memory.module_hash(kernel)
assert(type(hash) == 'string' and #hash == 64 and memory.module_hash(kernel) == hash, 'module hash')
assert(BingusRuntime.hash_reads == 1, 'one module file read this session')
local first = memory.time()
assert(type(first) == 'number' and first > 0 and memory.time() >= first, 'time')
print('PASS: after another mod declared all 16 Windows names with wrong prototypes, MOM reads memory and the runtime '
      .. 'hashes a module and reads the clock through private names')

-- The update: the game's results pass through; the 3rd frame's error from
-- below reaches the caller as the same table, without a log line from MOM;
-- MOM pauses on the next frame and resumes after 60 clean frames.
assert(update(1 / 60) == 'game' and update(1 / 60) == 'game')
assert(status.state == 'running' and menu.ready() == false, 'no game.dll here: the integration stays off')
local before = #lines
local ok, problem = pcall(update, 1 / 60)
assert(not ok and problem == neighbour.last_error and problem.hostile_vm == 'throw_below', 'the error passes unchanged')
assert(#lines == before, 'an error below is not logged as MOM\'s')
assert(update(1 / 60) == 'game' and status.state == 'paused: the previous update failed' and status.lower_errors == 1)
assert(lines[#lines]:find('Options update paused: the previous update failed', 1, true))
for _ = 1, 59 do assert(update(1 / 60) == 'game') end
assert(status.state:find('^paused'), 'paused for 60 clean frames')
assert(update(1 / 60) == 'game' and status.state == 'running' and status.errors == 0)
assert(lines[#lines]:find('Options update resumed after 60 clean frames', 1, true))
print('PASS: with a failing update below, its error reaches the caller unchanged and MOM pauses, then resumes after '
      .. '60 clean frames')
