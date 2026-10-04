-- FFI name clashes: another mod declares the Windows functions and types this
-- mod calls under their real names before this mod's reader and the shared
-- runtime's read side (src/bingus_memory.lua, which hashes the game modules)
-- are built, or after them. ffi.cdef keeps the first prototype declared for a
-- name and the first layout of a type name in the whole game and ignores a
-- later one without an error, so the mod must call only private names and
-- leave the real ones to other mods. Orders, each in a fresh Lua state
-- (declarations cannot be undone):
--   sdk-first  the Windows SDK's prototypes and type names were declared first;
--   mod-first  this mod comes first; the SDK declarations follow, the real names
--              and type names still free until then;
--   hostile    the same names were declared first with wrong prototypes
--              (tests/hostile_vm.lua H.clash: six int32_t pointers).
-- Module handles and ReadProcessMemory's address and buffer are integers in
-- the SDK declarations, as in a mod that addresses memory by numbers.
--   luajit tests/test_ffi_names.lua src sdk-first|mod-first|hostile
local ffi = require('ffi')
local source, order = arg[1], arg[2]
assert(source and (order == 'sdk-first' or order == 'mod-first' or order == 'hostile'),
       'usage: test_ffi_names.lua <src> sdk-first|mod-first|hostile')

-- The reader's functions, then the runtime read side's.
local REAL_NAMES = {
    kernel32 = {'GetModuleHandleA', 'GetCurrentProcess', 'ReadProcessMemory', 'GetModuleFileNameW', 'VirtualQuery',
                'QueryPerformanceCounter', 'QueryPerformanceFrequency', 'CreateFileW', 'ReadFile', 'CloseHandle'},
    bcrypt = {'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash', 'BCryptHashData',
              'BCryptFinishHash', 'BCryptDestroyHash'},
}
local SDK = {
    'typedef void *HANDLE;',
    'typedef int BOOL;',
    'typedef unsigned long DWORD;',
    'typedef unsigned long ULONG;',
    'typedef unsigned long long ULONG_PTR;',
    'typedef unsigned long long SIZE_T;',
    'typedef long NTSTATUS;',
    'typedef unsigned char UCHAR;',
    'typedef wchar_t WCHAR;',
    'typedef const char *LPCSTR;',
    'typedef WCHAR *LPWSTR;',
    'typedef const WCHAR *LPCWSTR;',
    'typedef DWORD *LPDWORD;',
    'typedef void *LPVOID;',
    'typedef void *BCRYPT_HANDLE;',
    'typedef struct _SECURITY_ATTRIBUTES { DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle; }'
        .. ' SECURITY_ATTRIBUTES;',
    'typedef struct _OVERLAPPED OVERLAPPED;',
    'ULONG_PTR GetModuleHandleA(LPCSTR lpModuleName);',
    'DWORD GetModuleFileNameW(ULONG_PTR hModule, LPWSTR lpFilename, DWORD nSize);',
    'HANDLE GetCurrentProcess(void);',
    'BOOL ReadProcessMemory(HANDLE hProcess, ULONG_PTR lpBaseAddress, ULONG_PTR lpBuffer, SIZE_T nSize,'
        .. ' SIZE_T *lpNumberOfBytesRead);',
    'HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,'
        .. ' SECURITY_ATTRIBUTES *lpSecurityAttributes, DWORD dwCreationDisposition,'
        .. ' DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);',
    'BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead,'
        .. ' OVERLAPPED *lpOverlapped);',
    'BOOL CloseHandle(HANDLE hObject);',
    'NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_HANDLE *phAlgorithm, LPCWSTR pszAlgId,'
        .. ' LPCWSTR pszImplementation, ULONG dwFlags);',
    'NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_HANDLE hAlgorithm, ULONG dwFlags);',
    'NTSTATUS BCryptCreateHash(BCRYPT_HANDLE hAlgorithm, BCRYPT_HANDLE *phHash, UCHAR *pbHashObject,'
        .. ' ULONG cbHashObject, UCHAR *pbSecret, ULONG cbSecret, ULONG dwFlags);',
    'NTSTATUS BCryptHashData(BCRYPT_HANDLE hHash, UCHAR *pbInput, ULONG cbInput, ULONG dwFlags);',
    'NTSTATUS BCryptFinishHash(BCRYPT_HANDLE hHash, UCHAR *pbOutput, ULONG cbOutput, ULONG dwFlags);',
    'NTSTATUS BCryptDestroyHash(BCRYPT_HANDLE hHash);',
}
local libraries = {kernel32 = ffi.load('kernel32'), bcrypt = ffi.load('bcrypt')}
local kernel32 = libraries.kernel32

local function declare_sdk()
    for _, declaration in ipairs(SDK) do ffi.cdef(declaration) end -- lint-ok: R1 the SDK-style clash under test
end
-- Whether the real name has a declaration in this Lua state.
local function declared(library, name)
    return (pcall(function() return libraries[library][name] end))
end
-- This mod's reader and the runtime read side it hashes the modules with.
local function build_mod()
    local runtime = dofile(source .. '/bingus_runtime.lua')
    return dofile(source .. '/read_api.lua')(), dofile(source .. '/bingus_memory.lua').new(runtime)
end

local api, memory
if order == 'sdk-first' then
    declare_sdk()
    api, memory = build_mod()
elseif order == 'hostile' then
    local H = dofile(source .. '/../tests/hostile_vm.lua')
    local names = {}
    for _, list in pairs(REAL_NAMES) do
        for _, name in ipairs(list) do names[#names + 1] = name end
    end
    for name, status in pairs(H.clash(names)) do assert(status == 'clashed', name .. ': ' .. status) end
    api, memory = build_mod()
else
    api, memory = build_mod()
    for library, names in pairs(REAL_NAMES) do
        for _, name in ipairs(names) do
            assert(not declared(library, name), name .. ' must stay free: the mod calls it by a private name')
        end
    end
    for _, declaration in ipairs(SDK) do
        local name = declaration:match('^typedef .-([%w_]+);$')
        if name then assert(not pcall(ffi.typeof, name), name .. ' must stay free: the mod declares no shared type') end
    end
    declare_sdk()
end

-- The SDK prototypes are the live ones for the real names, in both SDK orders.
local block = ffi.new('uint8_t[8]', {1, 2, 3, 4, 5, 6, 7, 8})
if order ~= 'hostile' then
    local exe = kernel32.GetModuleHandleA(nil)
    assert(ffi.istype('ULONG_PTR', exe), 'the SDK GetModuleHandleA must stay live')
    local copied, count = ffi.new('UCHAR[4]'), ffi.new('SIZE_T[1]')
    assert(kernel32.ReadProcessMemory(kernel32.GetCurrentProcess(), ffi.cast('uintptr_t', block) + 2,
           ffi.cast('uintptr_t', copied), 4, count) ~= 0 and copied[0] == 3 and copied[3] == 6,
           'the SDK ReadProcessMemory (integer addresses) must stay live')
end

-- The mod's reader: module handles and reads at number addresses, as strings
-- and into a caller buffer (an unreadable address and a range outside the
-- buffer too).
local game_exe, kernel = api.module(nil), api.module('kernel32.dll')
assert(type(game_exe) == 'number' and type(kernel) == 'number' and api.module('kyc-not-loaded.dll') == nil,
       'module handles')
local at = tonumber(ffi.cast('uintptr_t', block))
assert(api.read(at + 2, 4) == '\3\4\5\6', 'the mod reads memory')
local data = ffi.new('uint8_t[8]')
local into = {data = data, address = tonumber(ffi.cast('uintptr_t', data)), size = 8}
assert(api.read(at + 4, 4, into, 2) == true and data[1] == 0 and data[2] == 5 and data[5] == 8 and data[6] == 0,
       'the mod reads into a buffer')
assert(api.read(at, 8, into, 1) == nil and api.read(at, 0, into, 0) == nil, 'a read outside the buffer is refused')
assert(api.read(1, 8) == nil and api.read(1, 8, into, 0) == nil, 'an unreadable address reads nothing')
-- The runtime read side: a module file is hashed once per session, and the
-- build check answers (no game module in a test process).
local hash = memory.module_hash(memory.module('kernel32.dll'))
local reads = BingusRuntime.hash_reads
assert(#hash == 64 and hash:match('^[0-9A-F]+$') and memory.module_hash(memory.module('kernel32.dll')) == hash
       and BingusRuntime.hash_reads == reads, 'module hashing, once per session')
local supported, why = memory.verify_build({exe_sha256 = hash, game_sha256 = hash})
assert(supported == false and why == 'game modules unavailable', 'the build check')

print('PASS: Windows calls under private names, ' ..
      (order == 'sdk-first' and 'SDK-style declarations made first'
       or order == 'mod-first' and 'SDK-style declarations made after the reader was built, with the real names and type names free until then'
       or 'every name declared first with a wrong prototype') ..
      ': module handles, memory reads into strings and buffers and module hashing (shared runtime) work'
      .. (order == 'hostile' and '' or ', and the SDK prototypes stay live'))
