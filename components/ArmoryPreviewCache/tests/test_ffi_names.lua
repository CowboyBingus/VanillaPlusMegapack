-- FFI name clashes. The game and every mod share one LuaJIT state, and ffi.cdef
-- keeps the first prototype declared for a function name in it and silently
-- ignores later ones. This mod builds its Windows adapter on its first update
-- frame, after every other mod has loaded, so another mod's declarations of the
-- same real names come first; a mod loading after it must still get its own
-- prototypes. The adapter therefore declares private names (__asm__ labels).
-- A declaration cannot be undone, so each mode needs a fresh Lua state:
--
--   luajit tests/test_ffi_names.lua <repo> hostile   wrong prototypes declared first
--   luajit tests/test_ffi_names.lua <repo> sdk       Windows SDK prototypes declared first: the same
--                                                    ABI, with named structs and STRICT module handles
--   luajit tests/test_ffi_names.lua <repo> after     the adapter first, SDK prototypes afterwards
local root, mode = assert(arg[1], 'usage: test_ffi_names.lua <repo> hostile|sdk|after'), arg[2]
assert(mode == 'hostile' or mode == 'sdk' or mode == 'after', 'mode must be hostile, sdk or after')
local ffi = require('ffi')
local kernel32, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')

-- Every Windows function of the adapter (read_api.lua, platform.lua) and of the
-- retired pixel_platform.lua, which stays in src but is not shipped.
local NAMES = {
    {kernel32, 'GetModuleHandleA'}, {kernel32, 'GetModuleFileNameW'}, {kernel32, 'GetCurrentProcess'},
    {kernel32, 'ReadProcessMemory'}, {kernel32, 'CreateFileW'}, {kernel32, 'ReadFile'}, {kernel32, 'CloseHandle'},
    {bcrypt, 'BCryptOpenAlgorithmProvider'}, {bcrypt, 'BCryptCloseAlgorithmProvider'}, {bcrypt, 'BCryptCreateHash'},
    {bcrypt, 'BCryptHashData'}, {bcrypt, 'BCryptFinishHash'}, {bcrypt, 'BCryptDestroyHash'},
    {kernel32, 'GetTickCount64'}, {kernel32, 'GetTickCount'}, {kernel32, 'GetCurrentThreadId'}, {kernel32, 'GetCurrentProcessId'},
    {kernel32, 'GetProcessTimes'}, {kernel32, 'GlobalMemoryStatusEx'}, {kernel32, 'K32GetProcessMemoryInfo'},
    {kernel32, 'FindFirstFileW'}, {kernel32, 'FindNextFileW'}, {kernel32, 'FindClose'}, {kernel32, 'GetLastError'},
}

-- hostile_vm.lua's clash prototype: calls through it fail with "wrong number of
-- arguments" or "cannot convert".
local HOSTILE = 'int %s(int32_t *a, int32_t *b, int32_t *c, int32_t *d, int32_t *e, int32_t *f);'

-- What a mod written from the Windows SDK headers declares: the same ABI as the
-- adapter's prototypes, but typed buffers and handles.
local SDK = [[
    typedef unsigned char UCHAR, *PUCHAR;
    typedef unsigned long DWORD, ULONG, *LPDWORD;
    typedef long NTSTATUS;
    typedef int BOOL;
    typedef unsigned long long ULONGLONG, DWORDLONG, ULONG_PTR, SIZE_T;
    typedef void *HANDLE, *LPVOID, *BCRYPT_ALG_HANDLE, *BCRYPT_HASH_HANDLE;
    typedef const void *LPCVOID;
    typedef const char *LPCSTR;
    typedef wchar_t WCHAR, *LPWSTR;
    typedef const wchar_t *LPCWSTR;
    struct HINSTANCE__ { int unused; };
    typedef struct HINSTANCE__ *HINSTANCE, *HMODULE;
    typedef struct _FILETIME { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME, *LPFILETIME;
    typedef struct _MEMORYSTATUSEX {
        DWORD dwLength; DWORD dwMemoryLoad; DWORDLONG ullTotalPhys; DWORDLONG ullAvailPhys;
        DWORDLONG ullTotalPageFile; DWORDLONG ullAvailPageFile; DWORDLONG ullTotalVirtual;
        DWORDLONG ullAvailVirtual; DWORDLONG ullAvailExtendedVirtual;
    } MEMORYSTATUSEX, *LPMEMORYSTATUSEX;
    typedef struct _PROCESS_MEMORY_COUNTERS {
        DWORD cb; DWORD PageFaultCount; SIZE_T PeakWorkingSetSize; SIZE_T WorkingSetSize;
        SIZE_T QuotaPeakPagedPoolUsage; SIZE_T QuotaPagedPoolUsage; SIZE_T QuotaPeakNonPagedPoolUsage;
        SIZE_T QuotaNonPagedPoolUsage; SIZE_T PagefileUsage; SIZE_T PeakPagefileUsage;
    } PROCESS_MEMORY_COUNTERS, *PPROCESS_MEMORY_COUNTERS;
    typedef struct _SECURITY_ATTRIBUTES {
        DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle;
    } SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;
    typedef struct _OVERLAPPED {
        ULONG_PTR Internal; ULONG_PTR InternalHigh; DWORD Offset; DWORD OffsetHigh; HANDLE hEvent;
    } OVERLAPPED, *LPOVERLAPPED;
    typedef struct _WIN32_FIND_DATAW {
        DWORD dwFileAttributes; FILETIME ftCreationTime; FILETIME ftLastAccessTime; FILETIME ftLastWriteTime;
        DWORD nFileSizeHigh; DWORD nFileSizeLow; DWORD dwReserved0; DWORD dwReserved1;
        WCHAR cFileName[260]; WCHAR cAlternateFileName[14];
    } WIN32_FIND_DATAW, *LPWIN32_FIND_DATAW;
    HMODULE GetModuleHandleA(LPCSTR lpModuleName);
    DWORD GetModuleFileNameW(HMODULE hModule, LPWSTR lpFilename, DWORD nSize);
    HANDLE GetCurrentProcess(void);
    BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer, SIZE_T nSize,
                           SIZE_T *lpNumberOfBytesRead);
    HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                       LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition,
                       DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead,
                  LPOVERLAPPED lpOverlapped);
    BOOL CloseHandle(HANDLE hObject);
    NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *phAlgorithm, LPCWSTR pszAlgId,
                                         LPCWSTR pszImplementation, ULONG dwFlags);
    NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, ULONG dwFlags);
    NTSTATUS BCryptCreateHash(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_HASH_HANDLE *phHash, PUCHAR pbHashObject,
                              ULONG cbHashObject, PUCHAR pbSecret, ULONG cbSecret, ULONG dwFlags);
    NTSTATUS BCryptHashData(BCRYPT_HASH_HANDLE hHash, PUCHAR pbInput, ULONG cbInput, ULONG dwFlags);
    NTSTATUS BCryptFinishHash(BCRYPT_HASH_HANDLE hHash, PUCHAR pbOutput, ULONG cbOutput, ULONG dwFlags);
    NTSTATUS BCryptDestroyHash(BCRYPT_HASH_HANDLE hHash);
    ULONGLONG GetTickCount64(void);
    DWORD GetTickCount(void);
    DWORD GetCurrentThreadId(void);
    DWORD GetCurrentProcessId(void);
    BOOL GetProcessTimes(HANDLE hProcess, LPFILETIME lpCreationTime, LPFILETIME lpExitTime,
                         LPFILETIME lpKernelTime, LPFILETIME lpUserTime);
    BOOL GlobalMemoryStatusEx(LPMEMORYSTATUSEX lpBuffer);
    BOOL K32GetProcessMemoryInfo(HANDLE Process, PPROCESS_MEMORY_COUNTERS ppsmemCounters, DWORD cb);
    HANDLE FindFirstFileW(LPCWSTR lpFileName, LPWIN32_FIND_DATAW lpFindFileData);
    BOOL FindNextFileW(HANDLE hFindFile, LPWIN32_FIND_DATAW lpFindFileData);
    BOOL FindClose(HANDLE hFindFile);
    DWORD GetLastError(void);
]]

local SHA256_ABC = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'

local function hex(bytes)
    return (bytes:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

-- True when this state has a declaration for the name, whoever made it.
local function declared(library, name)
    local ok, problem = pcall(function() return library[name] end)
    return ok or not tostring(problem):find('missing declaration', 1, true)
end

local function undeclared_names()
    local names = {}
    for _, entry in ipairs(NAMES) do
        if not declared(entry[1], entry[2]) then names[#names + 1] = entry[2] end
    end
    return names
end

-- Another mod's declarations of the real names: the clash under test.
local function declare_foreign(text) ffi.cdef(text) end -- lint-ok: R1 another mod's declarations of the real names

local function declare_first(text)
    assert(#undeclared_names() == #NAMES, 'the real names must be undeclared before the other mod')
    declare_foreign(text)
    local missing = undeclared_names()
    assert(#missing == 0, 'the other mod did not declare: ' .. table.concat(missing, ', '))
end

-- The adapter as the mod composes it (scripts/module.py: platform(base)), with
-- every function called for real.
local function build_adapter()
    local ok, api = pcall(function()
        return dofile(root .. '/src/platform.lua')(dofile(root .. '/src/read_api.lua'))
    end)
    assert(ok, 'the adapter must build: ' .. tostring(api))
    return api
end

local function exercise_adapter(api)
    local exe, kernel = api.module(nil), api.module('kernel32.dll')
    assert(exe ~= nil and kernel ~= nil and api.module('hd2apc-not-loaded.dll') == nil, 'module handles')
    local block = ffi.new('uint8_t[16]', {1, 2, 3, 4, 5, 6, 7, 8})
    local at = ffi.cast('uint8_t *', block)
    assert(api.read(at, 4) == '\1\2\3\4' and api.read(at + 4, 4) == '\5\6\7\8', 'read')
    assert(api.read(at, 0) == nil and api.read(at, 32769) == nil and api.read(at, 1.5) == nil, 'bounded read')
    assert(api.read(ffi.cast('uint8_t *', 0x10), 4) == nil, 'unreadable memory')
    local buffer = ffi.new('uint8_t[8]')
    local into = {data = buffer, address = tonumber(ffi.cast('uintptr_t', buffer)), size = 8}
    assert(api.read(tonumber(ffi.cast('uintptr_t', at)) + 2, 4, into, 4) == true
        and buffer[3] == 0 and buffer[4] == 3 and buffer[7] == 6, 'read into a caller buffer')
    assert(api.read(0x10, 4, into, 0) == nil, 'unreadable memory into a caller buffer')
    local address = ffi.string(ffi.new('uintptr_t[1]', ffi.cast('uintptr_t', at)), 8)
    assert(api.pointer(address, 0) == at and api.pointer(string.rep('\0', 8), 0) == nil, 'pointer decoding')
    local hash = api.module_hash(kernel)
    assert(#hash == 64 and hash:match('^%x+$') and api.module_hash(kernel) == hash, 'module file hash')
    local now = api.time()
    assert(type(now) == 'number' and now > 0 and api.time() >= now, 'clock')
    api.assert_thread()
    assert(type(api.process_id) == 'number' and api.process_id > 0, 'process id')
    local created = api.process_created_filetime_hex
    assert(#created == 16 and created:match('^%x+$') and created ~= string.rep('0', 16), 'process creation time')
    local free, private, commit = api.memory()
    assert(free > 0 and private > 0 and commit > 0, 'memory telemetry')
    return {kernel = kernel, hash = hash}
end

-- The retired archive hasher: a known answer, and the module hash above equals
-- the digest of the module file's bytes. Outside the game there is no deployed
-- data folder, so the archive enumeration has to stop at its own check.
local function exercise_retired(result)
    local retired = dofile(root .. '/src/pixel_platform.lua')({})
    local hasher = retired.hasher()
    hasher:update('abc')
    assert(hex(hasher:finish()) == SHA256_ABC, 'archive hasher')
    local file = assert(io.open(assert(os.getenv('SystemRoot')) .. '\\System32\\kernel32.dll', 'rb'))
    local data = file:read('*a')
    file:close()
    hasher = retired.hasher()
    hasher:update(data)
    assert(hex(hasher:finish()) == result.hash, 'the module hash covers the whole file')
    local ok, problem = pcall(retired.archive_fingerprint)
    problem = tostring(problem)
    assert(ok or problem:find('Cannot enumerate deployed archives', 1, true)
        or problem:find('Incomplete archive manifest', 1, true), 'archive enumeration: ' .. problem)
end

-- The other mod's own calls through its SDK prototypes, checked against the adapter.
local function exercise_sdk_mod(api, result)
    local process = kernel32.GetCurrentProcess()
    local module = kernel32.GetModuleHandleA('kernel32.dll')
    assert(ffi.istype('HMODULE', module), 'the other mod gets its own module handle type')
    assert(ffi.cast('uintptr_t', module) == ffi.cast('uintptr_t', result.kernel), 'same module')
    local path = ffi.new('WCHAR[260]')
    local length = kernel32.GetModuleFileNameW(module, path, 260)
    assert(length > 0 and length < 260, 'module file name')
    local file = kernel32.CreateFileW(path, 0x80000000, 7, nil, 3, 0, nil)
    assert(file ~= ffi.cast('HANDLE', -1), 'module file opens')
    local head, count = ffi.new('UCHAR[2]'), ffi.new('DWORD[1]')
    local read = kernel32.ReadFile(file, head, 2, count, nil)
    kernel32.CloseHandle(file)
    assert(read ~= 0 and count[0] == 2 and head[0] == 77 and head[1] == 90, 'module file reads')
    local found = ffi.new('WIN32_FIND_DATAW')
    local search = kernel32.FindFirstFileW(path, found)
    assert(search ~= ffi.cast('HANDLE', -1) and found.nFileSizeLow > 0, 'module file found')
    assert(kernel32.FindNextFileW(search, found) == 0 and type(kernel32.GetLastError()) == 'number', 'one match')
    kernel32.FindClose(search)
    local times = ffi.new('FILETIME[4]')
    assert(kernel32.GetProcessTimes(process, times, times + 1, times + 2, times + 3) ~= 0, 'process times')
    assert(string.format('%08x%08x', times[0].dwHighDateTime, times[0].dwLowDateTime)
        == api.process_created_filetime_hex, 'same process creation time')
    assert(kernel32.GetCurrentProcessId() == api.process_id, 'same process id')
    assert(type(kernel32.GetCurrentThreadId()) == 'number' and tonumber(kernel32.GetTickCount64()) > 0
        and type(kernel32.GetTickCount()) == 'number', 'thread, clock')
    local status = ffi.new('MEMORYSTATUSEX')
    status.dwLength = ffi.sizeof(status)
    assert(kernel32.GlobalMemoryStatusEx(status) ~= 0 and status.ullTotalPhys > 0, 'memory status')
    local counters = ffi.new('PROCESS_MEMORY_COUNTERS')
    assert(kernel32.K32GetProcessMemoryInfo(process, counters, ffi.sizeof(counters)) ~= 0
        and counters.WorkingSetSize > 0, 'process memory')
    local source, copy, copied = ffi.new('UCHAR[4]', {9, 8, 7, 6}), ffi.new('UCHAR[4]'), ffi.new('SIZE_T[1]')
    assert(kernel32.ReadProcessMemory(process, source, copy, 4, copied) ~= 0 and copied[0] == 4
        and copy[0] == 9 and copy[3] == 6, 'memory read')
    local algorithm, hash = ffi.new('BCRYPT_ALG_HANDLE[1]'), ffi.new('BCRYPT_HASH_HANDLE[1]')
    local input, digest = ffi.new('UCHAR[3]', {97, 98, 99}), ffi.new('UCHAR[32]')
    assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, ffi.new('WCHAR[7]', {83, 72, 65, 50, 53, 54, 0}), nil, 0) == 0
        and bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0
        and bcrypt.BCryptHashData(hash[0], input, 3, 0) == 0
        and bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) == 0, 'SHA256')
    assert(bcrypt.BCryptDestroyHash(hash[0]) == 0 and bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) == 0)
    assert(hex(ffi.string(digest, 32)) == SHA256_ABC, 'SHA256 answer')
end

if mode == 'hostile' then
    local prototypes = {}
    for _, entry in ipairs(NAMES) do prototypes[#prototypes + 1] = string.format(HOSTILE, entry[2]) end
    declare_first(table.concat(prototypes, '\n'))
    exercise_retired(exercise_adapter(build_adapter()))
    print('PASS: FFI names, hostile prototypes first: module handles, bounded reads, pointer decoding, '
        .. 'module file hash, clock, thread check, process identity, memory telemetry and the retired '
        .. 'archive hasher work after ' .. #NAMES .. ' clashing declarations of the real names')
elseif mode == 'sdk' then
    declare_first(SDK)
    local api = build_adapter()
    local result = exercise_adapter(api)
    exercise_retired(result)
    exercise_sdk_mod(api, result)
    print('PASS: FFI names, Windows SDK prototypes first: the adapter and the retired archive hasher work '
        .. 'after ' .. #NAMES .. ' declarations with named structs and STRICT module handles, and so do the '
        .. 'other mod\'s own calls')
else
    local api = build_adapter()
    local result = exercise_adapter(api)
    exercise_retired(result)
    local claimed = #NAMES - #undeclared_names()
    assert(claimed == 0, 'the adapter declared ' .. claimed .. ' real Windows names')
    declare_first(SDK)
    exercise_sdk_mod(api, result)
    exercise_adapter(api)
    exercise_sdk_mod(api, exercise_adapter(build_adapter()))
    print('PASS: FFI names, adapter first: it declares none of the ' .. #NAMES .. ' real names, so a later '
        .. 'mod\'s SDK prototypes take effect and work, and the adapter keeps working, rebuilt or not')
end
