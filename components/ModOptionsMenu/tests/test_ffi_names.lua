-- FFI name clashes: other mods declare the Windows functions MOM and its
-- runtime (src/bingus_memory.lua) call under their real names, with Windows SDK
-- prototypes and types, before or after MOM loads. LuaJIT keeps the first
-- prototype declared for a name in the whole game and raises nothing on a later
-- one, so neither declares a real name: every declaration has a private name
-- with an __asm__ label (tests/test_hostile.lua: wrong prototypes first).
-- Usage: <lua> tests/test_ffi_names.lua [path to src/mod_options_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_options_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local ffi = require('ffi')
_G.CowboyBingusModLoader = {log_directory = directory}
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
local function load_menu()
    _G.ModOptionsMenu, _G.update, _G.BingusTranslations, _G.BingusRuntime = nil, function() end, nil, nil
    dofile(source)
    return assert(ModOptionsMenu)
end

local NAMES = {
    kernel32 = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory', 'CreateFileW',
                'ReadFile', 'CloseHandle', 'VirtualQuery', 'QueryPerformanceCounter', 'QueryPerformanceFrequency'},
    bcrypt = {'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash', 'BCryptHashData',
              'BCryptFinishHash', 'BCryptDestroyHash'},
}
local function declared(library, name)
    return (pcall(function() return ffi.load(library)[name] end))
end

-- MOM first: it leaves every real name undeclared, so another mod's own
-- declarations made afterwards are the ones that count.
load_menu()
for library, names in pairs(NAMES) do
    for _, name in ipairs(names) do
        assert(not declared(library, name), 'Mod Options Menu declared the real name ' .. name)
    end
end

-- Windows SDK declarations, as another mod might make them: SDK type names,
-- STRICT module handles (a pointer to a struct), struct-typed parameters.
ffi.cdef [[
typedef int BOOL;
typedef unsigned long DWORD, ULONG;
typedef DWORD *LPDWORD;
typedef long NTSTATUS;
typedef unsigned char UCHAR, *PUCHAR;
typedef void *HANDLE, *PVOID, *LPVOID;
typedef const void *LPCVOID;
typedef const char *LPCSTR;
typedef wchar_t WCHAR, *LPWSTR;
typedef const wchar_t *LPCWSTR;
typedef unsigned long long SIZE_T;
typedef struct HINSTANCE__ { int unused; } *HMODULE;
typedef struct _SECURITY_ATTRIBUTES { DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle; }
    SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;
typedef struct _OVERLAPPED { SIZE_T Internal, InternalHigh; DWORD Offset, OffsetHigh; HANDLE hEvent; }
    OVERLAPPED, *LPOVERLAPPED;
typedef struct _MEMORY_BASIC_INFORMATION { PVOID BaseAddress; PVOID AllocationBase; DWORD AllocationProtect;
    unsigned short PartitionId; SIZE_T RegionSize; DWORD State; DWORD Protect; DWORD Type; }
    MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION;
typedef union _LARGE_INTEGER { struct { DWORD LowPart; long HighPart; }; long long QuadPart; } LARGE_INTEGER;
typedef PVOID BCRYPT_ALG_HANDLE, BCRYPT_HASH_HANDLE;
HMODULE GetModuleHandleA(LPCSTR lpModuleName); /* -- lint-ok: R1 the clash under test */
DWORD GetModuleFileNameW(HMODULE hModule, LPWSTR lpFilename, DWORD nSize); /* -- lint-ok: R1 */
HANDLE GetCurrentProcess(void); /* -- lint-ok: R1 */
BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize,
                       SIZE_T *lpNumberOfBytesRead); /* -- lint-ok: R1 */
HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                   LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition,
                   DWORD dwFlagsAndAttributes, HANDLE hTemplateFile); /* -- lint-ok: R1 */
BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead,
              LPOVERLAPPED lpOverlapped); /* -- lint-ok: R1 */
BOOL CloseHandle(HANDLE hObject); /* -- lint-ok: R1 */
SIZE_T VirtualQuery(LPCVOID lpAddress, PMEMORY_BASIC_INFORMATION lpBuffer, SIZE_T dwLength); /* -- lint-ok: R1 */
BOOL QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount); /* -- lint-ok: R1 */
BOOL QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency); /* -- lint-ok: R1 */
NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *phAlgorithm, LPCWSTR pszAlgId, LPCWSTR pszImplementation,
                                     ULONG dwFlags); /* -- lint-ok: R1 */
NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, ULONG dwFlags); /* -- lint-ok: R1 */
NTSTATUS BCryptCreateHash(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_HASH_HANDLE *phHash, PUCHAR pbHashObject,
                          ULONG cbHashObject, PUCHAR pbSecret, ULONG cbSecret, ULONG dwFlags); /* -- lint-ok: R1 */
NTSTATUS BCryptHashData(BCRYPT_HASH_HANDLE hHash, PUCHAR pbInput, ULONG cbInput, ULONG dwFlags); /* -- lint-ok: R1 */
NTSTATUS BCryptFinishHash(BCRYPT_HASH_HANDLE hHash, PUCHAR pbOutput, ULONG cbOutput, ULONG dwFlags); /* -- lint-ok: R1 */
NTSTATUS BCryptDestroyHash(BCRYPT_HASH_HANDLE hHash); /* -- lint-ok: R1 */
]]
-- The other mod's calls get its own prototypes and work.
local k32, crypt = ffi.load('kernel32'), ffi.load('bcrypt')
local kernel_module = k32.GetModuleHandleA('kernel32.dll')
assert(ffi.istype('HMODULE', kernel_module) and kernel_module ~= nil, 'the SDK prototype of GetModuleHandleA')
local path = ffi.new('WCHAR[260]')
assert(k32.GetModuleFileNameW(kernel_module, path, 260) > 0)
local value, copy, copied = ffi.new('DWORD[1]', 0x1234abcd), ffi.new('DWORD[1]'), ffi.new('SIZE_T[1]')
assert(k32.ReadProcessMemory(k32.GetCurrentProcess(), value, copy, 4, copied) ~= 0)
assert(copy[0] == 0x1234abcd and copied[0] == 4, 'the SDK prototype of ReadProcessMemory')
local algorithm = ffi.new('BCRYPT_ALG_HANDLE[1]')
local sha256 = ffi.new('WCHAR[7]', {83, 72, 65, 50, 53, 54, 0})
assert(crypt.BCryptOpenAlgorithmProvider(algorithm, sha256, nil, 0) == 0)
assert(crypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) == 0)
local region = ffi.new('MEMORY_BASIC_INFORMATION')
assert(k32.VirtualQuery(value, region, ffi.sizeof(region)) == ffi.sizeof(region), 'the SDK prototype of VirtualQuery')
local count = ffi.new('LARGE_INTEGER')
assert(k32.QueryPerformanceCounter(count) ~= 0 and count.QuadPart > 0, 'the SDK prototype of QueryPerformanceCounter')
print('PASS: loaded first, Mod Options Menu and its runtime declare none of their 16 Windows functions under the '
      .. 'real name, and Windows SDK declarations made afterwards work')

-- SDK declarations first: a new instance works through its private names.
-- Its build check goes through the runtime's verify_build, which hashes each
-- module file once per session for every mod (audit P2-11): a spy on the
-- vendored read side records the calls.
local verify_calls = {}
local memory_chunk = mom_files.bingus_memory
rawset(mom_files, 'bingus_memory', function(...)
    local module = memory_chunk(...)
    local new_api = module.new
    module.new = function(runtime)
        local api = new_api(runtime)
        local verify = api.verify_build
        api.verify_build = function(build)
            verify_calls[#verify_calls + 1] = build
            return verify(build)
        end
        return api
    end
    return module
end)
local menu = load_menu()
local step = upvalue(update, 'step')
local escape_menu, initialize = upvalue(step, 'escape_menu'), upvalue(step, 'initialize')
local fill, read_pointer = upvalue(escape_menu, 'fill'), upvalue(escape_menu, 'read_pointer')
local translation, state = upvalue(menu.register_option, 'translation'), upvalue(menu.register_option, 'state')
-- Guarded reads: a pointer and bytes from this process, a refused bad address.
local cell = ffi.new('uint64_t[2]', 0x123456789a, 0)
local at = tonumber(ffi.cast('uint64_t', cell))
assert(read_pointer(at) == 0x123456789a, 'read_pointer')
assert(read_pointer(16) == nil and not fill(ffi.new('uint32_t[2]'), 16, 8), 'a bad address fails the read')
local bytes = ffi.new('uint8_t[4]', {77, 79, 77, 0})
assert(translation.read(tonumber(ffi.cast('uint64_t', bytes)), 3) == 'MOM', 'translation.read')
-- The module hash through the runtime: the module's file is read once per
-- session for every mod (BingusRuntime.hashes), so another mod's copy of the
-- runtime reads no file for it again. The runtime's clock works too.
local memory = upvalue(initialize, 'memory')
local reads = BingusRuntime.hash_reads
local hash = memory.module_hash(kernel_module)
assert(type(hash) == 'string' and hash:match('^%x+$') and #hash == 64, 'module hash')
assert(memory.module_hash(kernel_module) == hash and BingusRuntime.hash_reads == reads + 1, 'read once, then cached')
local other_runtime = assert(loadfile(root .. '/src/bingus_runtime.lua'))()
local other = assert(loadfile(root .. '/src/bingus_memory.lua'))().new(other_runtime)
assert(other.module_hash(kernel_module) == hash and BingusRuntime.hash_reads == reads + 1, 'another mod reads no file')
assert(memory.module_hash(k32.GetModuleHandleA('ntdll.dll')) ~= hash, 'another module, another hash')
local first = memory.time()
assert(type(first) == 'number' and first > 0 and memory.time() >= first, 'time')
-- The build check: game.dll is not loaded here, so the integration stays off.
initialize()
assert(state.initialized and state.native == nil and not menu.ready())
assert(#verify_calls == 1 and verify_calls[1].game_sha256 == '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
       and verify_calls[1].exe_sha256 == 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06',
       'the build check goes through the runtime, once')
initialize()
assert(#verify_calls == 1, 'once per session')
print('PASS: after Windows SDK declarations of the same 16 names, a new instance reads memory, hashes a module once '
      .. 'per session for every mod and checks for game.dll through private names')
