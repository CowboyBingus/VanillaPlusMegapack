-- Exercise the first callbacks with real Windows FFI, outside the game.
local path, scenario = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
assert(ffi.os == 'Windows' and ffi.arch == 'x64', 'Windows x64 LuaJIT required')
assert(scenario == 'clean' or scenario == 'predeclared' or scenario == 'game-present'
       or scenario == 'sdk-declared' or scenario == 'other-build')
-- clean, predeclared: this process has no game.dll, so the build gate stops
-- the addon before anything else. game-present, sdk-declared: a synthetic
-- game.dll whose file the session's hash table lists as build 25480438's, so
-- the gate passes and the addon's own signature check decides. other-build:
-- the same synthetic game.dll, whose file is this process's executable: the
-- gate hashes both files for real and finds another build.
if scenario == 'predeclared' then
    ffi.cdef [[void *GetModuleHandleA(const char *name);]] -- lint-ok: R1 a neighbour's declaration under test
    local kernel = ffi.load('kernel32')
    assert(type(kernel.GetModuleHandleA) == 'cdata')
    assert(kernel.GetModuleHandleA(nil) ~= nil, 'native binding must be callable')
end
if scenario == 'sdk-declared' then
    -- What a Windows SDK header gives, declared first under the real names as
    -- a mod loaded earlier could: LuaJIT keeps the first declaration of a name
    -- for the whole process, so the addon must not depend on its own.
    ffi.cdef [[
    typedef unsigned long DWORD; typedef unsigned short WORD; typedef int BOOL;
    typedef void *HANDLE; typedef void *HMODULE; typedef void *PVOID; typedef void *LPVOID;
    typedef const void *LPCVOID; typedef const char *LPCSTR; typedef size_t SIZE_T;
    typedef DWORD *PDWORD; typedef unsigned long long ULONGLONG; typedef long long LONGLONG;
    typedef union _LARGE_INTEGER {
        struct { DWORD LowPart; long HighPart; }; LONGLONG QuadPart;
    } LARGE_INTEGER;
    typedef struct _MEMORY_BASIC_INFORMATION {
        PVOID BaseAddress; PVOID AllocationBase; DWORD AllocationProtect; WORD PartitionId;
        SIZE_T RegionSize; DWORD State; DWORD Protect; DWORD Type;
    } MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION; /* -- lint-ok: R1 the clash under test */
    HMODULE GetModuleHandleA(LPCSTR lpModuleName); /* -- lint-ok: R1 the clash under test */
    HANDLE GetCurrentProcess(void); /* -- lint-ok: R1 the clash under test */
    BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesRead); /* -- lint-ok: R1 the clash under test */
    BOOL WriteProcessMemory(HANDLE hProcess, LPVOID lpBaseAddress, LPCVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesWritten); /* -- lint-ok: R1 the clash under test */
    BOOL VirtualProtectEx(HANDLE hProcess, LPVOID lpAddress, SIZE_T dwSize, DWORD flNewProtect, PDWORD lpflOldProtect); /* -- lint-ok: R1 the clash under test */
    SIZE_T VirtualQueryEx(HANDLE hProcess, LPCVOID lpAddress, PMEMORY_BASIC_INFORMATION lpBuffer, SIZE_T dwLength); /* -- lint-ok: R1 the clash under test */
    ULONGLONG GetTickCount64(void); /* -- lint-ok: R1 the clash under test */
    BOOL QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount); /* -- lint-ok: R1 the clash under test */
    BOOL QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency); /* -- lint-ok: R1 the clash under test */
    ]]
end

-- The test's own Windows calls, under names of its own.
ffi.cdef [[
void *atrtest_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect) __asm__("VirtualAlloc");
int atrtest_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
int atrtest_VirtualProtect(void *address, size_t size, uint32_t protect, uint32_t *old) __asm__("VirtualProtect");
size_t atrtest_VirtualQuery(const void *address, void *region, size_t size) __asm__("VirtualQuery");
uint32_t atrtest_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity) __asm__("GetModuleFileNameW");
]]
local system = ffi.load('kernel32')
local MEM_COMMIT_RESERVE, MEM_RELEASE, PAGE_READONLY, PAGE_READWRITE = 0x3000, 0x8000, 0x02, 0x04

local function allocate(size)
    local base = system.atrtest_VirtualAlloc(nil, size, MEM_COMMIT_RESERVE, PAGE_READWRITE)
    assert(base ~= nil, 'VirtualAlloc failed')
    return ffi.cast('uint8_t *', base)
end
-- State, protection and type of the page holding address (MEMORY_BASIC_INFORMATION words 8-10).
local function page(address)
    local words = ffi.new('uint32_t[12]')
    assert(system.atrtest_VirtualQuery(address, words, 48) == 48, 'VirtualQuery failed')
    return words[8], words[9], words[10]
end

local bindings, lookups, gate_lookups = ffi, {}, 0
local fixture, module_handle, record
-- The session's module hashes (BingusRuntime.hashes), keyed by file path.
local hashes = {}
local function file_name(module)
    local path = ffi.new('uint16_t[32768]')
    local length = system.atrtest_GetModuleFileNameW(module, path, 32768)
    assert(length > 0 and length < 32768, 'GetModuleFileNameW failed')
    return path, length
end
local exe_path, exe_length = file_name(nil)
local FIXTURE_FILE = 'C:\\Fixture\\data\\game\\game.dll'
local fixture_path = ffi.new('uint16_t[?]', #FIXTURE_FILE + 1)
for index = 1, #FIXTURE_FILE do fixture_path[index - 1] = FIXTURE_FILE:byte(index) end
if scenario == 'game-present' or scenario == 'sdk-declared' then
    hashes['sha256:' .. ffi.string(exe_path, exe_length * 2)] =
        'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
    hashes['sha256:' .. ffi.string(fixture_path, #FIXTURE_FILE * 2)] =
        '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
end
if scenario == 'game-present' or scenario == 'sdk-declared' or scenario == 'other-build' then
    -- Only the game handle is synthetic. Native process, timer and memory
    -- calls operate on this process: a zero-filled image (unsupported) or one
    -- carrying the build signature (sdk-declared, so the addon scans this
    -- process and patches a charge record in a real read-only region).
    if scenario ~= 'sdk-declared' then
        fixture = ffi.new('uint8_t[?]', 0x755f90 + 16)
    else
        fixture = allocate(0x3470000) -- covers every global the addon reads
        local signature = '\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
        ffi.copy(fixture + 0x755f90, signature, #signature)
        local region = allocate(0x200000)
        record = region + 0x10000
        for offset, value in pairs({[0] = 1.0, [24] = 1.1, [48] = 1.2, [72] = 0.7, [76] = 1.4}) do
            ffi.cast('float *', record + offset)[0] = value
        end
        ffi.copy(record + 168, '\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41', 16)
        local old = ffi.new('uint32_t[1]')
        assert(system.atrtest_VirtualProtect(region, 0x200000, PAGE_READONLY, old) ~= 0)
    end
    module_handle = ffi.cast('void *(*)(const char *)', function(name)
        assert(ffi.string(name) == 'game.dll')
        return fixture
    end)
    -- The build gate's copy of the runtime (bingus_memory1_* names): game.dll
    -- is the fixture, whose file name is FIXTURE_FILE, or for other-build this
    -- process's executable. Every other function is the real one.
    local function gate_function(native, symbol, real)
        gate_lookups = gate_lookups + 1
        local resolved = native[symbol]
        if real == 'GetModuleHandleA' then
            return function(name)
                if name ~= nil and ffi.string(name) == 'game.dll' then return ffi.cast('void *', fixture) end
                return resolved(name)
            end
        elseif real == 'GetModuleFileNameW' then
            return function(module, path, capacity)
                if module ~= ffi.cast('void *', fixture) then return resolved(module, path, capacity) end
                if scenario == 'other-build' then return resolved(nil, path, capacity) end
                ffi.copy(path, fixture_path, (#FIXTURE_FILE + 1) * 2)
                return #FIXTURE_FILE
            end
        end
        return resolved
    end
    bindings = setmetatable({load = function(name)
        local native = ffi.load(name)
        if name ~= 'kernel32' then return native end
        return setmetatable({}, {__index = function(_, symbol)
            local gate = symbol:match('^bingus_memory1_(.+)$')
            if gate then return gate_function(native, symbol, gate) end
            local real = symbol:match('^atr1_(.+)$')
            assert(real, 'kernel32 used without a private name: ' .. tostring(symbol))
            local resolved = native[symbol] -- Requires a real declaration.
            lookups[real] = (lookups[real] or 0) + 1
            if real == 'GetModuleHandleA' then
                assert(type(resolved) == 'cdata' and resolved(nil) ~= nil)
                assert(resolved('game.dll') == nil, 'run outside the game')
                return module_handle
            end
            return resolved
        end})
    end}, {__index = ffi})
end

local lines, updates, renders = {}, 0, 0
local env = setmetatable({}, {__index = _G})
env._G = env
env.BingusRuntime = {hashes = hashes}
env.require = function(name)
    if name == 'ffi' then return bindings end
    return require(name)
end
env.CowboyBingusModLoader = {api = 1, open_log = function(name)
    assert(name == 'ArcThrowerAuto.log')
    return {write = function(_, text) lines[#lines + 1] = text end,
            flush = function() end}
end}
env.update = function(dt)
    assert(dt == 0.016); updates = updates + 1
    return 1, nil, 3
end
env.render = function(value)
    assert(value == 'frame'); renders = renders + 1
    return 'rendered', nil, 7
end
local function load_addon() setfenv(assert(loadfile(path)), env)() end
local game_update, game_render = env.update, env.render
load_addon()
local gated = scenario == 'clean' or scenario == 'predeclared' or scenario == 'other-build'
if gated then
    -- The gate stopped the addon: one log line, nothing of its own bound and
    -- no hook, so the game's callbacks run directly.
    local why = scenario == 'other-build' and 'unsupported game build (needs Steam build 25480438)'
        or 'game modules unavailable'
    assert(#lines == 1 and lines[1] == 'Disabled: ' .. why .. '; the addon does nothing this session.\n',
           table.concat(lines))
    assert(next(lookups) == nil, 'no binding of the addon on another build')
    assert(env.update == game_update and env.render == game_render and env.shutdown == nil, 'no hook')
    assert(scenario ~= 'other-build' or gate_lookups > 0, 'the gate bound its own functions')
else
    assert(#lines == 1 and lines[1]:find('initialised on game build 25480438', 1, true), table.concat(lines))
end
for _ = 1, 2 do
    local a, b, c = env.update(0.016)
    assert(a == 1 and b == nil and c == 3)
    local x, y, z = env.render('frame')
    assert(x == 'rendered' and y == nil and z == 7)
end
assert(updates == 2 and renders == 2)
if scenario == 'sdk-declared' then
    -- The bounded scan walks this whole process; stop once the record is patched.
    local frames = 2
    while record[184] ~= 1 and frames < 100000 and #lines == 1 do
        env.update(0.016); frames = frames + 1
    end
    assert(record[184] == 1, 'charge record not patched after ' .. frames .. ' updates: '
           .. table.concat(lines, ' | '))
    assert(#lines == 2 and lines[2]:find('Charge record ready.', 1, true), table.concat(lines, ' | '))
    local state, protection, kind = page(record + 184)
    assert(state == 0x1000 and kind == 0x20000 and protection == PAGE_READONLY,
           'the weapon data page must be read-only again after the patch')
    for _ = 1, 40 do env.update(0.016) end -- record checks every 0.25 s
    assert(#lines == 2, table.concat(lines, ' | '))
    assert(lookups.VirtualProtectEx and lookups.WriteProcessMemory and lookups.VirtualQueryEx)
elseif scenario == 'game-present' then
    -- The gate passed; the game.dll signature check after it still refuses.
    assert(#lines == 2, table.concat(lines))
    assert(lines[2]:find('Unsupported game build; the addon is disabled.', 1, true), table.concat(lines))
else
    assert(#lines == 1, table.concat(lines))
end
for _, line in ipairs(lines) do
    assert(not line:find('kernel32 bindings unavailable', 1, true))
    assert(not line:find('missing declaration', 1, true))
end
if scenario == 'game-present' then
    assert(lookups.GetCurrentProcess == 1, 'initialize process once')
    assert(lookups.QueryPerformanceFrequency == 1, 'initialize timer once')
    assert(lookups.ReadProcessMemory == 1, 'retain the native game-build check')
    assert(not lookups.WriteProcessMemory and not lookups.VirtualProtectEx,
           'unsupported image must not be patched')
end
local update, render = env.update, env.render
local count = #lines
load_addon()
assert(env.update == update and env.render == render and #lines == count,
       'standalone and megapack copies must share the re-entry guard')
if scenario == 'sdk-declared' then
    -- Shutdown puts the record flag back through the same checked path, and
    -- the page is read-only again.
    env.shutdown()
    local state, protection = page(record + 184)
    assert(record[184] == 0 and protection == PAGE_READONLY, 'shutdown must put the record back, read-only')
    assert(lines[#lines]:find('Shutdown: stopped', 1, true), table.concat(lines, ' | '))
end
if module_handle then module_handle:free() end
print('PASS: arc thrower native bindings (' .. scenario .. '), callbacks and duplicate guard')
