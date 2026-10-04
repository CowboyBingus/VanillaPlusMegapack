-- FFI name clashes. In the game every mod shares one LuaJIT state: ffi.cdef
-- keeps the first prototype declared for a function name in the whole process
-- (a later cdef of the name raises nothing and changes nothing) and the first
-- layout of a type name. Another mod may declare the Windows functions Mod
-- Bindings Menu and its vendored Bingus Shared Runtime call, before or after it
-- loads: with textbook SDK prototypes and their own named structs (a real
-- third-party mod declares VirtualQuery(const void *, MEMORY_BASIC_INFORMATION *,
-- size_t)), or with prototypes that do not fit at all (hostile_vm.lua's
-- H.clash). Mod Bindings Menu must read, write, hash its modules and check the
-- game build through private names in every order, and leave the plain names
-- (and their types) to the other mod.
--
-- One order per fresh VM: sdk-first (this file), hostile-first and mbm-first
-- (tests/test_ffi_names_<order>.lua set MBM_FFI_ORDER and run this file).
local order = rawget(_G, 'MBM_FFI_ORDER') or 'sdk-first'
assert(order == 'sdk-first' or order == 'hostile-first' or order == 'mbm-first', order)
local here = arg[0]:match('^(.*[/\\])') or './'
local root = here .. '..'
local ffi = require('ffi')
local bit = require('bit')

-- The names Mod Bindings Menu and the runtime (bingus_memory.lua) call.
local WINDOWS_NAMES = {
    'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualProtect',
    'VirtualQuery', 'GetLastError', 'CreateFileW', 'ReadFile', 'CloseHandle', 'BCryptOpenAlgorithmProvider',
    'BCryptCloseAlgorithmProvider', 'BCryptCreateHash', 'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash',
    'QueryPerformanceCounter', 'QueryPerformanceFrequency',
}
-- The other mod, written from the Windows SDK headers: named structs and the
-- SDK's own type names, structurally equivalent to Mod Bindings Menu's.
local SDK = [[
typedef unsigned long DWORD;
typedef unsigned short WORD;
typedef int BOOL;
typedef void *HANDLE;
typedef void *HMODULE;
typedef void *PVOID;
typedef void *LPVOID;
typedef const void *LPCVOID;
typedef size_t SIZE_T;
typedef long NTSTATUS;
typedef unsigned long ULONG;
typedef unsigned char UCHAR;
typedef void *BCRYPT_ALG_HANDLE;
typedef long long LARGE_INTEGER;
typedef void *BCRYPT_HASH_HANDLE;
typedef struct _MEMORY_BASIC_INFORMATION {
    PVOID BaseAddress; PVOID AllocationBase; DWORD AllocationProtect; WORD PartitionId;
    SIZE_T RegionSize; DWORD State; DWORD Protect; DWORD Type;
} MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION;
HMODULE GetModuleHandleA(const char *lpModuleName);
DWORD GetModuleFileNameW(HMODULE hModule, wchar_t *lpFilename, DWORD nSize);
HANDLE GetCurrentProcess(void);
BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize,
                       SIZE_T *lpNumberOfBytesRead);
BOOL VirtualProtect(LPVOID lpAddress, SIZE_T dwSize, DWORD flNewProtect, DWORD *lpflOldProtect);
SIZE_T VirtualQuery(LPCVOID lpAddress, PMEMORY_BASIC_INFORMATION lpBuffer, SIZE_T dwLength);
DWORD GetLastError(void);
HANDLE CreateFileW(const wchar_t *lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                   void *lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes,
                   HANDLE hTemplateFile);
BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, DWORD *lpNumberOfBytesRead,
              void *lpOverlapped);
BOOL CloseHandle(HANDLE hObject);
NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *phAlgorithm, const wchar_t *pszAlgId,
                                     const wchar_t *pszImplementation, ULONG dwFlags);
NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, ULONG dwFlags);
NTSTATUS BCryptCreateHash(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_HASH_HANDLE *phHash, UCHAR *pbHashObject,
                          ULONG cbHashObject, UCHAR *pbSecret, ULONG cbSecret, ULONG dwFlags);
NTSTATUS BCryptHashData(BCRYPT_HASH_HANDLE hHash, UCHAR *pbInput, ULONG cbInput, ULONG dwFlags);
NTSTATUS BCryptFinishHash(BCRYPT_HASH_HANDLE hHash, UCHAR *pbOutput, ULONG cbOutput, ULONG dwFlags);
NTSTATUS BCryptDestroyHash(BCRYPT_HASH_HANDLE hHash);
BOOL QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount);
BOOL QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency);
]]
-- A careless mod: ReadProcessMemory with an integer address (a common idiom),
-- every other name with H.clash's prototype that fits nothing.
local H = dofile(here .. 'hostile_vm.lua')
local function hostile()
    ffi.cdef('int ReadProcessMemory(void *process, uintptr_t address, void *buffer, size_t size, size_t *read);')
    local others = {}
    for _, name in ipairs(WINDOWS_NAMES) do
        if name ~= 'ReadProcessMemory' then others[#others + 1] = name end
    end
    for name, status in pairs(H.clash(others)) do assert(status == 'clashed', name .. ': ' .. status) end
end
local function declare_other_mod()
    if order == 'hostile-first' then hostile() else ffi.cdef(SDK) end
end

-- The test's own helpers, under test-private names.
ffi.cdef [[
typedef struct {
    void *base; void *allocation; uint32_t allocation_protection; uint16_t partition;
    size_t size; uint32_t state; uint32_t protection; uint32_t type;
} mbm_test_region;
void *mbm_test_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
int mbm_test_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
size_t mbm_test_VirtualQuery(const void *address, mbm_test_region *region, size_t size) __asm__("VirtualQuery");
]]
local test_kernel = ffi.load('kernel32')

if order ~= 'mbm-first' then declare_other_mod() end

-- Mod Bindings Menu loads (its log captured), as the build assembles it.
local lines = {}
local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
_G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
local Text = dofile(root .. '/src/bingus_text.lua')
_G.BingusTranslations = nil
Text.registry().steam_language = 'en'
_G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
-- The other source files: the build places them ahead of the main file as
-- the functions in the local mbm_files; here mbm_files loads src/<name>.lua.
_G.mbm_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})
_G.update = function() end
dofile(root .. '/src/mod_bindings_menu.lua')
assert(rawget(_G, 'ModBindingsMenu'), 'Mod Bindings Menu loaded')

if order == 'mbm-first' then
    -- Mod Bindings Menu declared none of the plain names, so the other mod's
    -- declarations, struct tags and type names all go through and win.
    for _, name in ipairs(WINDOWS_NAMES) do
        local found, problem = pcall(function() return ffi.C[name] end)
        assert(not found and tostring(problem):find('missing declaration', 1, true),
               name .. ' was declared by Mod Bindings Menu')
    end
    declare_other_mod()
end

-- Mod Bindings Menu's internals, found through the update's upvalues.
local function holder(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == wanted then return value end
        if type(value) == 'function' then nested[#nested + 1] = value end
    end
    for _, inner in ipairs(nested) do
        local value = holder(inner, wanted, seen)
        if value ~= nil then return value end
    end
    return nil
end
local function internal(name) return assert(holder(update, name), 'missing ' .. name) end
local read, read_words, words = internal('read'), internal('read_words'), internal('words')
local write_memory, memory = internal('write_memory'), internal('memory')
local initialize = internal('initialize')

-- Reads: a string per read() and in place for the per-frame reads; an
-- unreadable address returns nil, never raises.
local buffer = ffi.new('uint8_t[16]', {1, 2, 3, 4, 5, 6, 7, 8})
local address = tonumber(ffi.cast('uintptr_t', buffer))
assert(read(address, 4) == '\1\2\3\4' and read(1, 4) == nil, 'read')
assert(read_words(address, 8) and words[0] == 0x04030201 and words[1] == 0x08070605, 'read_words')
assert(not read_words(1, 8), 'read_words refuses an unreadable address')

-- Writes: directly into writable memory; through the protection fallback on a
-- read-only page, whose protection comes back; refused (false, never raised)
-- on reserved memory and when the fallback fails.
local target = ffi.new('uint32_t[2]')
assert(write_memory(tonumber(ffi.cast('uintptr_t', target)), 4, function() target[0] = 0x11223344 end) == true
       and target[0] == 0x11223344, 'direct write')
local PAGE = 4096
local region = test_kernel.mbm_test_VirtualAlloc(nil, 2 * PAGE, 0x2000, 0x01) -- reserved, no access
assert(region ~= nil and test_kernel.mbm_test_VirtualAlloc(region, PAGE, 0x1000, 0x02) ~= nil) -- page 0 read-only
local page = tonumber(ffi.cast('uintptr_t', region))
local cells = ffi.cast('uint32_t *', region)
assert(write_memory(page + 16, 4, function() cells[4] = 0x55667788 end) == true and cells[4] == 0x55667788,
       'write through the protection fallback')
local info = ffi.new('mbm_test_region')
assert(test_kernel.mbm_test_VirtualQuery(region, info, ffi.sizeof(info)) ~= 0 and info.protection == 0x02,
       'page protection restored')
local called = false
assert(write_memory(page + PAGE, 4, function() called = true end) == false and not called, 'reserved memory refused')
local before = #lines
assert(write_memory(page + PAGE - 2, 4, function() called = true end) == false and not called,
       'a write the fallback cannot cover is refused')
assert(#lines == before + 1 and lines[#lines]:find('Write refused', 1, true)
       and lines[#lines]:find('error 487', 1, true), 'the refusal names the Windows error: ' .. tostring(lines[#lines]))
assert(test_kernel.mbm_test_VirtualFree(region, 0, 0x8000) ~= 0)

-- Module hashing through the runtime (GetModuleFileNameW, CreateFileW,
-- ReadFile, BCrypt*), once per session for every mod: the second answer comes
-- from the shared cache.
local exe = memory.module(nil)
local digest = memory.module_hash(exe)
local reads = BingusRuntime.hash_reads
assert(#digest == 64 and digest:match('^[0-9A-F]+$') and memory.module_hash(exe) == digest, 'module SHA-256')
assert(reads == 1 and BingusRuntime.hash_reads == 1, 'the module file is read once per session')

-- The build check runs to its verdict: game.dll is not loaded in a test
-- process, so the update stops with that reason (the guard's refusal), never
-- with an FFI conversion error.
before = #lines
initialize()
local verdict = table.concat(lines, '\n', before + 1)
-- The runtime's build check (shared module hashes) gives the reason.
assert(verdict:find('ModBindingsMenu stopped: game modules unavailable', 1, true), verdict)
for _, symptom in ipairs({'cannot convert', 'bad argument', 'wrong number of arguments'}) do
    assert(not verdict:find(symptom, 1, true), verdict)
end

-- The other mod's own calls work too, through the declarations it made.
if order ~= 'hostile-first' then
    local k, crypto = ffi.C, ffi.load('bcrypt')
    local region_info = ffi.new('MEMORY_BASIC_INFORMATION')
    assert(k.VirtualQuery(buffer, region_info, ffi.sizeof(region_info)) == ffi.sizeof(region_info)
           and region_info.State == 0x1000, 'the other mod queries memory')
    local out, got = ffi.new('UCHAR[4]'), ffi.new('SIZE_T[1]')
    assert(k.ReadProcessMemory(k.GetCurrentProcess(), buffer, out, 4, got) ~= 0 and out[3] == 4, 'the other mod reads')
    local path = ffi.new('wchar_t[32768]')
    assert(k.GetModuleFileNameW(k.GetModuleHandleA(nil), path, 32768) > 0)
    local file = k.CreateFileW(path, 0x80000000, 7, nil, 3, 0, nil)
    assert(file ~= ffi.cast('HANDLE', -1))
    local algorithm, hash = ffi.new('BCRYPT_ALG_HANDLE[1]'), ffi.new('BCRYPT_HASH_HANDLE[1]')
    local name = ffi.new('wchar_t[7]', {83, 72, 65, 50, 53, 54, 0})
    assert(crypto.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0)
    assert(crypto.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0)
    local chunk, count = ffi.new('UCHAR[65536]'), ffi.new('DWORD[1]')
    while k.ReadFile(file, chunk, 65536, count, nil) ~= 0 and count[0] > 0 do
        assert(crypto.BCryptHashData(hash[0], chunk, count[0], 0) == 0)
    end
    local result, parts = ffi.new('UCHAR[32]'), {}
    assert(crypto.BCryptFinishHash(hash[0], result, 32, 0) == 0)
    crypto.BCryptDestroyHash(hash[0])
    crypto.BCryptCloseAlgorithmProvider(algorithm[0], 0)
    k.CloseHandle(file)
    for index = 0, 31 do parts[#parts + 1] = string.format('%02X', result[index]) end
    assert(table.concat(parts) == digest, 'both mods hash the same file alike')
    local previous = ffi.new('DWORD[1]')
    assert(k.VirtualProtect(target, 4, 0x04, previous) ~= 0 and bit.band(previous[0], 0xff) == 0x04)
end
print('PASS: FFI names, ' .. order .. ': reads, writes (direct, protection fallback, refusals), module hashing and '
      .. 'the build check work through private names' .. (order == 'hostile-first' and '' or
      ', and the other mod\'s SDK declarations keep working'))
