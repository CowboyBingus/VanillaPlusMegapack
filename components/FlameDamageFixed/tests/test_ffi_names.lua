-- FFI name clashes in the game's one shared Lua state. ffi.cdef keeps the first prototype declared for a function
-- name and the first layout of a type name for the whole game, and a later declaration of the same name raises
-- nothing. Flame Damage Fixed declares every Windows function under a private name (an __asm__ label naming the
-- real export) and only a private type name, so in every load order:
--   sdk      another mod declared the Windows SDK's names first, with the SDK's types (DWORD, HANDLE, SIZE_T,
--            wchar_t strings, MEMORY_BASIC_INFORMATION): the adapter and the module hash still work, and that
--            mod's calls with its own types still work after this mod loaded;
--   hostile  another mod declared the same names first with wrong prototypes (tests/hostile_vm.lua H.clash):
--            the adapter and the module hash still work (v1.1 failed here: wrong number of arguments);
--   reverse  this mod loads first, then another mod declares the real names with its own prototypes (integer
--            addresses and counts): that mod's calls get its own prototypes (v1.1's declarations took their
--            place and its calls raised "cannot convert").
-- Usage: luajit tests/test_ffi_names.lua <project root> sdk|hostile|reverse   (also in the game's lua51.dll)
local root, mode = assert(arg[1], 'project root required'), assert(arg[2], 'mode required: sdk, hostile or reverse')
local ffi = require('ffi')
local H = dofile(root .. '/tests/hostile_vm.lua')

-- The Windows functions this mod's adapter declares (module files are hashed by bingus_memory.lua now, so the
-- adapter no longer declares CreateFileW/ReadFile/CloseHandle/BCrypt*; those names are the runtime's own test).
local NAMES = {'GetModuleHandleA', 'GetCurrentProcess', 'ReadProcessMemory', 'WriteProcessMemory', 'VirtualQuery'}

-- What a mod written from the Windows SDK headers declares (structurally equivalent prototypes, SDK type names).
local SDK = [[
typedef unsigned long DWORD; typedef int BOOL; typedef unsigned short WORD; typedef unsigned long ULONG; /* -- lint-ok: R1 the deliberate clash under test */
typedef unsigned char UCHAR; typedef UCHAR *PUCHAR; typedef long NTSTATUS; typedef unsigned long long ULONG_PTR; /* -- lint-ok: R1 the deliberate clash under test */
typedef ULONG_PTR SIZE_T; typedef void *HANDLE; typedef void *HMODULE; typedef void *LPVOID; typedef const void *LPCVOID; /* -- lint-ok: R1 the deliberate clash under test */
typedef const char *LPCSTR; typedef wchar_t WCHAR; typedef WCHAR *LPWSTR; typedef const WCHAR *LPCWSTR; /* -- lint-ok: R1 the deliberate clash under test */
typedef void *BCRYPT_ALG_HANDLE; typedef void *BCRYPT_HASH_HANDLE; /* -- lint-ok: R1 the deliberate clash under test */
typedef struct _MEMORY_BASIC_INFORMATION { LPVOID BaseAddress; LPVOID AllocationBase; DWORD AllocationProtect; WORD PartitionId; SIZE_T RegionSize; DWORD State; DWORD Protect; DWORD Type; } MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION; /* -- lint-ok: R1 the deliberate clash under test */
typedef struct _SECURITY_ATTRIBUTES { DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle; } SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES; /* -- lint-ok: R1 the deliberate clash under test */
typedef struct _OVERLAPPED { ULONG_PTR Internal; ULONG_PTR InternalHigh; DWORD Offset; DWORD OffsetHigh; HANDLE hEvent; } OVERLAPPED, *LPOVERLAPPED; /* -- lint-ok: R1 the deliberate clash under test */
HMODULE GetModuleHandleA(LPCSTR lpModuleName); /* -- lint-ok: R1 the deliberate clash under test */
DWORD GetModuleFileNameW(HMODULE hModule, LPWSTR lpFilename, DWORD nSize); /* -- lint-ok: R1 the deliberate clash under test */
HANDLE GetCurrentProcess(void); /* -- lint-ok: R1 the deliberate clash under test */
BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesRead); /* -- lint-ok: R1 the deliberate clash under test */
BOOL WriteProcessMemory(HANDLE hProcess, LPVOID lpBaseAddress, LPCVOID lpBuffer, SIZE_T nSize, SIZE_T *lpNumberOfBytesWritten); /* -- lint-ok: R1 the deliberate clash under test */
SIZE_T VirtualQuery(LPCVOID lpAddress, PMEMORY_BASIC_INFORMATION lpBuffer, SIZE_T dwLength); /* -- lint-ok: R1 the deliberate clash under test */
HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile); /* -- lint-ok: R1 the deliberate clash under test */
BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, DWORD *lpNumberOfBytesRead, LPOVERLAPPED lpOverlapped); /* -- lint-ok: R1 the deliberate clash under test */
BOOL CloseHandle(HANDLE hObject); /* -- lint-ok: R1 the deliberate clash under test */
NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *phAlgorithm, LPCWSTR pszAlgId, LPCWSTR pszImplementation, ULONG dwFlags); /* -- lint-ok: R1 the deliberate clash under test */
NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, ULONG dwFlags); /* -- lint-ok: R1 the deliberate clash under test */
NTSTATUS BCryptCreateHash(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_HASH_HANDLE *phHash, PUCHAR pbHashObject, ULONG cbHashObject, PUCHAR pbSecret, ULONG cbSecret, ULONG dwFlags); /* -- lint-ok: R1 the deliberate clash under test */
NTSTATUS BCryptHashData(BCRYPT_HASH_HANDLE hHash, PUCHAR pbInput, ULONG cbInput, ULONG dwFlags); /* -- lint-ok: R1 the deliberate clash under test */
NTSTATUS BCryptFinishHash(BCRYPT_HASH_HANDLE hHash, PUCHAR pbOutput, ULONG cbOutput, ULONG dwFlags); /* -- lint-ok: R1 the deliberate clash under test */
NTSTATUS BCryptDestroyHash(BCRYPT_HASH_HANDLE hHash); /* -- lint-ok: R1 the deliberate clash under test */
]]

-- What another mod written with integer addresses and counts declares (and calls with plain numbers).
local INTEGER = [[
int ReadProcessMemory(void *process, uint64_t address, void *buffer, uint64_t size, uint64_t *done); /* -- lint-ok: R1 the deliberate clash under test */
int WriteProcessMemory(void *process, uint64_t address, const void *buffer, uint64_t size, uint64_t *done); /* -- lint-ok: R1 the deliberate clash under test */
uint64_t VirtualQuery(uint64_t address, void *region, uint64_t size); /* -- lint-ok: R1 the deliberate clash under test */
uint64_t GetModuleHandleA(const char *name); /* -- lint-ok: R1 the deliberate clash under test */
uint64_t GetCurrentProcess(void); /* -- lint-ok: R1 the deliberate clash under test */
uint32_t GetModuleFileNameW(uint64_t module, uint16_t *path, uint32_t size); /* -- lint-ok: R1 the deliberate clash under test */
]]

local function load_adapter()
    _G.FLAME_DAMAGE_FIXED_ADAPTER_TEST = true
    local ok, api, module = pcall(dofile, root .. '/src/flame_damage_fixed.lua')
    _G.FLAME_DAMAGE_FIXED_ADAPTER_TEST = nil
    assert(ok, mode .. ': the adapter must build despite the earlier declarations: ' .. tostring(api))
    return api, module
end

-- Every adapter call on this process's own memory and the module lookup. (Module hashing moved to
-- bingus_memory.lua's shared cache, so the adapter no longer declares the file/BCrypt functions.)
local function exercise(api, module)
    local buffer = ffi.new('uint32_t[16]', {0x11223344, 0xa5a5a5a5})
    local address = tonumber(ffi.cast('uintptr_t', buffer))
    assert(api.u32(address) == 0x11223344 and api.u32(address + 4) == 0xa5a5a5a5, mode .. ': u32')
    assert(api.read(address, 4) == '\68\51\34\17', mode .. ': bulk read')
    local words = api.load(address, 16)
    assert(words and words[0] == 0x11223344 and words[1] == 0xa5a5a5a5, mode .. ': block read')
    assert(api.writable_data(address, 64), mode .. ': protection query')
    local base, size = api.writable_region(address)
    assert(base and size and base <= address and address + 64 <= base + size, mode .. ': region query')
    assert(api.write_raw(address + 8, '\1\2\3\4') and buffer[2] == 0x04030201, mode .. ': raw write')
    assert(api.write_u32(address + 12, 0xffe0000b) and buffer[3] == 0xffe0000b, mode .. ': u32 write')
    local kernel32 = module('kernel32.dll')
    assert(kernel32 ~= nil and module('fdf-not-loaded.dll') == nil, mode .. ': module lookup')
    local image = tonumber(ffi.cast('uintptr_t', kernel32))
    assert(not api.writable_data(image, 16) and api.writable_region(image) == nil, mode .. ': image refused')
    return true
end

if mode == 'sdk' then
    ffi.cdef(SDK)
    local api, module = load_adapter()
    exercise(api, module)
    -- The SDK mod's own calls, with its own types, still work after this mod loaded.
    local mbi = ffi.new('MEMORY_BASIC_INFORMATION[1]')
    local probe = ffi.new('uint8_t[64]')
    assert(ffi.C.VirtualQuery(probe, mbi, ffi.sizeof(mbi)) == ffi.sizeof(mbi) and mbi[0].State == 0x1000,
        'sdk: the other mod\'s VirtualQuery with MEMORY_BASIC_INFORMATION')
    local name = ffi.new('WCHAR[260]')
    assert(ffi.C.GetModuleFileNameW(ffi.C.GetModuleHandleA('kernel32.dll'), name, 260) > 0, 'sdk: WCHAR file name')
    local done = ffi.new('SIZE_T[1]')
    local source, target = ffi.new('uint32_t[1]', 7), ffi.new('uint32_t[1]')
    assert(ffi.C.ReadProcessMemory(ffi.C.GetCurrentProcess(), source, target, 4, done) ~= 0 and target[0] == 7,
        'sdk: the other mod\'s ReadProcessMemory with SIZE_T')
elseif mode == 'hostile' then
    local status = H.clash(NAMES)
    for _, name in ipairs(NAMES) do assert(status[name] == 'clashed', name .. ': ' .. tostring(status[name])) end
    local api, module = load_adapter()
    exercise(api, module)
elseif mode == 'reverse' then
    local api, module = load_adapter()
    exercise(api, module)
    ffi.cdef(INTEGER)
    local process = ffi.C.GetCurrentProcess()
    assert(type(process) == 'cdata' and tonumber(process) ~= 0, 'reverse: the other mod\'s GetCurrentProcess')
    local source, target, done = ffi.new('uint32_t[1]', 0x5a5a1234), ffi.new('uint32_t[1]'), ffi.new('uint64_t[1]')
    local address = tonumber(ffi.cast('uintptr_t', source))
    local ok, why = pcall(ffi.C.ReadProcessMemory, ffi.cast('void *', process), address, target, 4, done)
    assert(ok and why ~= 0 and target[0] == 0x5a5a1234 and done[0] == 4,
        'reverse: the other mod\'s integer-address ReadProcessMemory: ' .. tostring(why))
    local region = ffi.new('uint8_t[48]')
    ok, why = pcall(ffi.C.VirtualQuery, address, region, 48)
    assert(ok and why == 48, 'reverse: the other mod\'s integer-address VirtualQuery: ' .. tostring(why))
    local module_address = ffi.C.GetModuleHandleA('kernel32.dll')
    local path = ffi.new('uint16_t[260]')
    ok, why = pcall(ffi.C.GetModuleFileNameW, module_address, path, 260)
    assert(ok and why > 0, 'reverse: the other mod\'s integer-handle GetModuleFileNameW: ' .. tostring(why))
    -- And this mod keeps working after the other mod's declarations.
    assert(exercise(api, module), 'reverse: the adapter after the other mod loaded')
else
    error('unknown mode ' .. tostring(mode))
end
print('PASS: Windows functions under private names (' .. mode .. '): reads, block reads, protection and region '
    .. 'queries, raw and u32 writes, module lookup work'
    .. (mode == 'sdk' and ' after SDK-style declarations of the Windows names, which keep working too'
        or mode == 'hostile' and ' after wrong earlier declarations of all 5 names'
        or ' and another mod\'s later integer-address declarations of the same names keep their own prototypes'))
