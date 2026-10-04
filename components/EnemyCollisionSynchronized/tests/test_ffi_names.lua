-- FFI name clashes: a mod that loaded first has already declared the Windows
-- functions this mod calls, under their real names and with other prototypes.
-- LuaJIT keeps the first prototype declared for a name in the whole shared
-- state (a later ffi.cdef of the same name raises nothing), so neither the
-- memory adapter (windows_api.lua) nor the runtime's read side
-- (bingus_memory.lua, which hashes the modules) may depend on declarations of
-- those names. hostile_vm.lua's H.clash declares each one first.
local source = assert(arg[1])
local H = dofile(arg[0]:gsub('[%w_]+%.lua$', '') .. 'hostile_vm.lua')
local ffi = require('ffi')

local names = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'GetTickCount64',
    'GetCurrentThread', 'QueryThreadCycleTime', 'QueryPerformanceCounter', 'QueryPerformanceFrequency',
    'ReadProcessMemory', 'VirtualQuery', 'CreateFileW', 'ReadFile', 'CloseHandle',
    'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash', 'BCryptHashData',
    'BCryptFinishHash', 'BCryptDestroyHash'}
local status = H.clash(names)
for _, name in ipairs(names) do assert(status[name] == 'clashed', name .. ': ' .. tostring(status[name])) end

local created, api = pcall(dofile(source .. '/windows_api.lua'))
assert(created, 'The memory adapter must build despite clashing declarations: ' .. tostring(api))
local block = ffi.new('uint8_t[16]', {1, 2, 3, 4, 5, 6, 7, 8})
assert(api.read(block, 4) == '\1\2\3\4' and api.read(block, 0) == nil, 'read')
local view = api.view(block + 4, 4)
assert(view ~= nil and view[0] == 5 and view[3] == 8, 'view')
assert(type(api.time()) == 'number' and api.time() > 0, 'time')
local before = api.clock()
assert(type(before) == 'number' and api.clock() >= before, 'clock')
local cycles = api.thread_cycles and api.thread_cycles()
assert(cycles == nil or api.thread_cycles() >= cycles, 'thread cycles')
local exe, kernel = api.module(nil), api.module('kernel32.dll')
assert(exe ~= nil and kernel ~= nil and api.module('ecs-not-loaded.dll') == nil, 'module handles')

-- The build check: module hashes from the runtime's session cache, read once
-- per module file and session for every mod.
local runtime = dofile(source .. '/bingus_runtime.lua')
local made, memory = pcall(dofile(source .. '/bingus_memory.lua').new, runtime)
assert(made, 'The runtime read side must build despite clashing declarations: ' .. tostring(memory))
local reads = BingusRuntime.hash_reads
local hash = memory.module_hash(kernel)
assert(type(hash) == 'string' and #hash == 64 and hash:match('^%x+$'), 'module hash')
assert(dofile(source .. '/bingus_memory.lua').new(runtime).module_hash(kernel) == hash, 'another copy')
assert(BingusRuntime.hash_reads == reads + 1, 'one file read per module and session')
local verified, why = memory.verify_build({exe_sha256 = 'exe', game_sha256 = 'game'})
assert(verified == false and why == 'game modules unavailable', 'no game.dll in a test process: ' .. tostring(why))

print('PASS: Windows functions under private names: read, view, clocks, modules, the shared module hash and the build check work after ' .. #names .. ' clashing declarations')
