-- FFI name clashes with the other mods in the game's shared Lua state. LuaJIT
-- keeps the first prototype declared for a name for the whole state (a later
-- ffi.cdef of the same name raises nothing), so windows_api.lua and the shared
-- runtime's read side it hashes modules with (bingus_memory.lua) must work
-- whatever another mod declared first under the real Windows names, and must
-- leave those names to the mods that declare them after it.
-- Usage: test_ffi_names.lua <src directory> <sdk|hostile|mod-first> [SHA-256 of the loaded lua51.dll]
--   sdk        another mod declared all 17 functions first as the Windows headers do
--   hostile    another mod declared all 17 real names first with unusable prototypes
--              (H.clash from tests/hostile_vm.lua, Bingus Shared Runtime's test helper)
--   mod-first  this mod first: the real names stay undeclared, and a mod declaring them
--              later as the headers do gets its own prototypes
local source = assert(arg[1], 'source directory required')
local mode = assert(arg[2], 'mode required: sdk, hostile or mod-first')
local lua51_sha256 = arg[3]
local tests = (arg[0]:match('^(.*[/\\])') or './')
local ffi = require('ffi')
local H = dofile(tests .. 'hostile_vm.lua')

-- windows_api.lua's five, then the runtime's (module hashes and its clock).
local NAMES = {'GetModuleHandleA', 'GetProcAddress', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
    'GetModuleFileNameW', 'CreateFileW', 'ReadFile', 'CloseHandle', 'QueryPerformanceCounter',
    'QueryPerformanceFrequency', 'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash',
    'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'}

-- What a mod written against the Windows headers declares (typedef names and all).
local SDK = [[
    typedef void *HANDLE; /* -- lint-ok: R1 headers under test */
    typedef void *HMODULE; /* -- lint-ok: R1 headers under test */
    typedef void *LPVOID; /* -- lint-ok: R1 headers under test */
    typedef const void *LPCVOID; /* -- lint-ok: R1 headers under test */
    typedef const char *LPCSTR; /* -- lint-ok: R1 headers under test */
    typedef unsigned long DWORD; /* -- lint-ok: R1 headers under test */
    typedef DWORD *LPDWORD; /* -- lint-ok: R1 headers under test */
    typedef int BOOL; /* -- lint-ok: R1 headers under test */
    typedef size_t SIZE_T; /* -- lint-ok: R1 headers under test */
    typedef wchar_t WCHAR; /* -- lint-ok: R1 headers under test */
    typedef WCHAR *LPWSTR; /* -- lint-ok: R1 headers under test */
    typedef const WCHAR *LPCWSTR; /* -- lint-ok: R1 headers under test */
    typedef long NTSTATUS; /* -- lint-ok: R1 headers under test */
    typedef unsigned long ULONG; /* -- lint-ok: R1 headers under test */
    typedef unsigned char UCHAR; /* -- lint-ok: R1 headers under test */
    typedef UCHAR *PUCHAR; /* -- lint-ok: R1 headers under test */
    typedef void *BCRYPT_ALG_HANDLE; /* -- lint-ok: R1 headers under test */
    typedef void *BCRYPT_HASH_HANDLE; /* -- lint-ok: R1 headers under test */
    typedef intptr_t (*FARPROC)(void); /* -- lint-ok: R1 headers under test */
    typedef union _LARGE_INTEGER { /* -- lint-ok: R1 headers under test */
        struct { DWORD LowPart; long HighPart; }; long long QuadPart;
    } LARGE_INTEGER; /* -- lint-ok: R1 headers under test */
    typedef struct _SECURITY_ATTRIBUTES { /* -- lint-ok: R1 headers under test */
        DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle;
    } SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES; /* -- lint-ok: R1 headers under test */
    typedef struct _OVERLAPPED { /* -- lint-ok: R1 headers under test */
        uintptr_t Internal; uintptr_t InternalHigh; DWORD Offset; DWORD OffsetHigh; HANDLE hEvent;
    } OVERLAPPED, *LPOVERLAPPED; /* -- lint-ok: R1 headers under test */
    typedef struct _MEMORY_BASIC_INFORMATION { /* -- lint-ok: R1 headers under test */
        LPVOID BaseAddress; LPVOID AllocationBase; DWORD AllocationProtect; unsigned short PartitionId;
        SIZE_T RegionSize; DWORD State; DWORD Protect; DWORD Type;
    } MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION; /* -- lint-ok: R1 headers under test */
    HMODULE GetModuleHandleA(LPCSTR lpModuleName); /* -- lint-ok: R1 headers under test */
    FARPROC GetProcAddress(HMODULE hModule, LPCSTR lpProcName); /* -- lint-ok: R1 headers under test */
    DWORD GetModuleFileNameW(HMODULE hModule, LPWSTR lpFilename, DWORD nSize); /* -- lint-ok: R1 headers under test */
    HANDLE GetCurrentProcess(void); /* -- lint-ok: R1 headers under test */
    BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesRead); /* -- lint-ok: R1 headers under test */
    SIZE_T VirtualQuery(LPCVOID lpAddress, PMEMORY_BASIC_INFORMATION lpBuffer, SIZE_T dwLength); /* -- lint-ok: R1 headers under test */
    HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile); /* -- lint-ok: R1 headers under test */
    BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead, LPOVERLAPPED lpOverlapped); /* -- lint-ok: R1 headers under test */
    BOOL CloseHandle(HANDLE hObject); /* -- lint-ok: R1 headers under test */
    BOOL QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount); /* -- lint-ok: R1 headers under test */
    BOOL QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency); /* -- lint-ok: R1 headers under test */
    NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *phAlgorithm, LPCWSTR pszAlgId, LPCWSTR pszImplementation, ULONG dwFlags); /* -- lint-ok: R1 headers under test */
    NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, ULONG dwFlags); /* -- lint-ok: R1 headers under test */
    NTSTATUS BCryptCreateHash(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_HASH_HANDLE *phHash, PUCHAR pbHashObject, ULONG cbHashObject, PUCHAR pbSecret, ULONG cbSecret, ULONG dwFlags); /* -- lint-ok: R1 headers under test */
    NTSTATUS BCryptHashData(BCRYPT_HASH_HANDLE hHash, PUCHAR pbInput, ULONG cbInput, ULONG dwFlags); /* -- lint-ok: R1 headers under test */
    NTSTATUS BCryptFinishHash(BCRYPT_HASH_HANDLE hHash, PUCHAR pbOutput, ULONG cbOutput, ULONG dwFlags); /* -- lint-ok: R1 headers under test */
    NTSTATUS BCryptDestroyHash(BCRYPT_HASH_HANDLE hHash); /* -- lint-ok: R1 headers under test */
]]

local kernel32, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
local function declared(name)
    local library = name:find('^BCrypt') and bcrypt or kernel32
    return pcall(function() return library[name] end)
end

-- The other mod's own calls, through its header prototypes, after this mod built its api.
local function neighbour_calls()
    local info, probe = ffi.new('MEMORY_BASIC_INFORMATION'), ffi.new('uint8_t[64]')
    assert(kernel32.VirtualQuery(probe, info, ffi.sizeof(info)) == ffi.sizeof(info) and info.State == 0x1000,
        'the other mod\'s VirtualQuery')
    local from, value, count = ffi.new('uint32_t[1]', 0x5eed), ffi.new('uint32_t[1]'), ffi.new('SIZE_T[1]')
    assert(kernel32.ReadProcessMemory(kernel32.GetCurrentProcess(), from, value, 4, count) ~= 0 and value[0] == 0x5eed
        and count[0] == 4, 'the other mod\'s ReadProcessMemory')
    local path = ffi.new('WCHAR[260]')
    assert(kernel32.GetModuleFileNameW(kernel32.GetModuleHandleA('kernel32.dll'), path, 260) > 0,
        'the other mod\'s GetModuleFileNameW')
    assert(kernel32.GetProcAddress(kernel32.GetModuleHandleA('kernel32.dll'), 'ReadFile') ~= nil,
        'the other mod\'s GetProcAddress')
    local ticks = ffi.new('LARGE_INTEGER[1]')
    assert(kernel32.QueryPerformanceCounter(ticks) ~= 0 and ticks[0].QuadPart > 0, 'the other mod\'s clock')
end

-- Every Windows call windows_api.lua makes: guarded reads (ReadProcessMemory),
-- page checks and checked writes (VirtualQuery), module handles and exports,
-- and a module's SHA-256 through the runtime (GetModuleFileNameW, CreateFileW,
-- ReadFile, CloseHandle and the BCrypt calls; building its api reads the
-- performance counter's frequency).
local function exercise(api)
    local block = ffi.new('uint32_t[4]', {7, 8, 9, 10})
    local a = tonumber(ffi.cast('uintptr_t', block))
    assert(api.read32(a + 4) == 8 and api.read64(a) == 8 * 4294967296 + 7 and api.read32(16) == nil, 'guarded reads')
    assert(api.read_f32(a) ~= nil and api.read_bytes(a, 4) == '\7\0\0\0', 'guarded float and string reads')
    assert(api.writable_data(a, 16) and not api.writable_data(16, 4), 'page checks')
    assert(api.write32(a + 8, 99) and block[2] == 99, 'a checked write')
    local kernel = api.module('kernel32.dll')
    assert(kernel and api.module(nil) and api.module('blm-not-loaded.dll') == nil, 'module handles')
    assert(api.export(kernel, 'GetCurrentProcess') and api.export(kernel, 'NoSuchExport') == nil, 'exports')
    local lua51 = api.module('lua51.dll')
    local hash = api.module_sha256(lua51 or kernel)
    assert(#hash == 64 and hash:match('^[0-9A-F]+$') and api.module_sha256(lua51 or kernel) == hash, 'module hash')
    if lua51 and lua51_sha256 then assert(hash == lua51_sha256:upper(), 'lua51.dll hash mismatch') end
end

if mode == 'sdk' then
    ffi.cdef(SDK) -- lint-ok: R1 the other mod's header declarations under test
elseif mode == 'hostile' then
    local status = H.clash(NAMES)
    for _, name in ipairs(NAMES) do assert(status[name] == 'clashed', name .. ': ' .. tostring(status[name])) end
else
    assert(mode == 'mod-first', 'unknown mode ' .. mode)
end

local Runtime = dofile(source .. '/bingus_runtime.lua')
local Memory = dofile(source .. '/bingus_memory.lua')
local function build() return dofile(source .. '/windows_api.lua')(Memory.new(Runtime)) end
local created, api = pcall(build)
assert(created, 'the api must build after the other declarations: ' .. tostring(api))
exercise(api)
if mode == 'mod-first' then
    for _, name in ipairs(NAMES) do
        assert(not declared(name), name .. ' was declared under its real name: another mod would get this prototype')
    end
    ffi.cdef(SDK) -- lint-ok: R1 a later mod's header declarations under test
    exercise(api)
end
if mode ~= 'hostile' then neighbour_calls() end
assert(build() ~= api, 'a second api builds too')

local done = {
    sdk = 'after another mod declared the 17 functions as the Windows headers do; its own calls still work',
    hostile = 'after another mod declared the 17 real names with unusable prototypes (H.clash)',
    ['mod-first'] = 'before any other mod: the 17 real names stay undeclared, and a mod declaring them later as the '
        .. 'Windows headers do gets its own prototypes',
}
print('PASS: Windows functions under private names (this mod\'s and the shared runtime\'s): reads, page checks, a '
    .. 'write, module handles, exports and the SHA-256 work ' .. done[mode])
