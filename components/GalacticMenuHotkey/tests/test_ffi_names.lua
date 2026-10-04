-- FFI name clashes: another mod declares the Windows functions and types this
-- mod and its vendored Bingus Shared Runtime call under their real names, as a
-- Windows SDK header has them, before this mod loads (sdk-first) or after it
-- (mod-first), or with prototypes that fit nothing (hostile-first:
-- hostile_vm.lua's H.clash). ffi.cdef keeps the first prototype declared for a
-- name and the first layout of a type name in the whole game and ignores a
-- later one without an error, so the mod must call only private names and
-- leave the real ones to other mods. Two of the SDK declarations take integer
-- addresses, as a third-party mod's did when it disabled Clickable Scrollbars
-- v2.14. Declarations cannot be undone, so each order runs in a fresh Lua state:
--   luajit tests/test_ffi_names.lua src/galactic_menu_hotkey.lua sdk-first|mod-first|hostile-first
local ffi = require('ffi')
local bit = require('bit')
local source, order = arg[1], arg[2]
assert(source and (order == 'sdk-first' or order == 'mod-first' or order == 'hostile-first'),
       'usage: test_ffi_names.lua <src/galactic_menu_hotkey.lua> sdk-first|mod-first|hostile-first')

-- The real names the mod and the runtime (bingus_memory.lua) call, by library.
local REAL_NAMES = {
    kernel32 = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'GetCurrentProcessId',
                'ReadProcessMemory', 'CreateFileW', 'ReadFile', 'CloseHandle', 'VirtualQuery',
                'QueryPerformanceCounter', 'QueryPerformanceFrequency'},
    user32 = {'GetAsyncKeyState', 'GetForegroundWindow', 'GetWindowThreadProcessId'},
    bcrypt = {'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash',
              'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'},
}
local SDK = {
    'typedef void *HANDLE;',
    'typedef struct HINSTANCE__ *HMODULE;',
    'typedef struct HWND__ *HWND;',
    'typedef int BOOL;',
    'typedef short SHORT;',
    'typedef unsigned long DWORD;',
    'typedef unsigned long ULONG;',
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
    'uintptr_t GetModuleHandleA(LPCSTR lpModuleName);',
    'DWORD GetModuleFileNameW(HMODULE hModule, LPWSTR lpFilename, DWORD nSize);',
    'HANDLE GetCurrentProcess(void);',
    'DWORD GetCurrentProcessId(void);',
    'BOOL ReadProcessMemory(HANDLE hProcess, uintptr_t lpBaseAddress, LPVOID lpBuffer, size_t nSize,'
        .. ' size_t *lpNumberOfBytesRead);',
    'HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,'
        .. ' SECURITY_ATTRIBUTES *lpSecurityAttributes, DWORD dwCreationDisposition,'
        .. ' DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);',
    'BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead,'
        .. ' OVERLAPPED *lpOverlapped);',
    'BOOL CloseHandle(HANDLE hObject);',
    'SHORT GetAsyncKeyState(int vKey);',
    'HWND GetForegroundWindow(void);',
    'DWORD GetWindowThreadProcessId(HWND hWnd, LPDWORD lpdwProcessId);',
    'NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_HANDLE *phAlgorithm, LPCWSTR pszAlgId,'
        .. ' LPCWSTR pszImplementation, ULONG dwFlags);',
    'NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_HANDLE hAlgorithm, ULONG dwFlags);',
    'NTSTATUS BCryptCreateHash(BCRYPT_HANDLE hAlgorithm, BCRYPT_HANDLE *phHash, UCHAR *pbHashObject,'
        .. ' ULONG cbHashObject, UCHAR *pbSecret, ULONG cbSecret, ULONG dwFlags);',
    'NTSTATUS BCryptHashData(BCRYPT_HANDLE hHash, UCHAR *pbInput, ULONG cbInput, ULONG dwFlags);',
    'NTSTATUS BCryptFinishHash(BCRYPT_HANDLE hHash, UCHAR *pbOutput, ULONG cbOutput, ULONG dwFlags);',
    'NTSTATUS BCryptDestroyHash(BCRYPT_HANDLE hHash);',
}
local libraries = {kernel32 = ffi.load('kernel32'), user32 = ffi.load('user32'), bcrypt = ffi.load('bcrypt')}
local kernel32, user32 = libraries.kernel32, libraries.user32

local function declare_sdk()
    for _, declaration in ipairs(SDK) do ffi.cdef(declaration) end -- lint-ok: R1 the SDK-style clash under test
end
-- Whether the real name has a declaration in this Lua state.
local function declared(library, name)
    return (pcall(function() return libraries[library][name] end))
end

local messages = {}
CowboyBingusModLoader = {open_log = function()
    return {write = function(_, message) messages[#messages + 1] = message end, flush = function() end}
end}
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local Text = dofile(root .. '/src/bingus_text.lua')
Text.registry().steam_language = 'en'
_G.ssh_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
_G.ssh_runtime = {core = assert(loadfile(root .. '/src/bingus_runtime.lua')),
                  memory = assert(loadfile(root .. '/src/bingus_memory.lua'))}
_G.update = function() end

if order == 'sdk-first' then
    declare_sdk()
    dofile(source)
elseif order == 'hostile-first' then
    -- A mod that loaded first declared every real name with a prototype that
    -- fits nothing.
    local H = dofile((arg[0]:match('^(.*[/\\])') or './') .. 'hostile_vm.lua')
    local names = {}
    for _, list in pairs(REAL_NAMES) do
        for _, name in ipairs(list) do names[#names + 1] = name end
    end
    for name, status in pairs(H.clash(names)) do assert(status == 'clashed', name .. ': ' .. status) end
    dofile(source)
else
    dofile(source)
    for library, names in pairs(REAL_NAMES) do
        for _, name in ipairs(names) do
            assert(not declared(library, name), name .. ' must stay free: the mod calls it by a private name')
        end
    end
    for _, declaration in ipairs(SDK) do
        local name = declaration:match('^typedef .-([%w_]+);$')
        if name then assert(not pcall(ffi.typeof, name), name .. ' must stay free: the mod has its own type names') end
    end
    declare_sdk()
end

-- The mod's functions, found through the update's upvalues.
local function holder(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 60 do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == wanted then return fn, index, value end
        if type(value) == 'function' then nested[#nested + 1] = value end
    end
    for _, inner in ipairs(nested) do
        local found, index, value = holder(inner, wanted, seen)
        if found then return found, index, value end
    end
    return nil
end
local function upvalue(wanted)
    local found, _, value = holder(update, wanted)
    return assert(found and value, 'missing upvalue ' .. wanted)
end

local sdk = order ~= 'hostile-first'
local block = ffi.new('GMH_u8[8]', {1, 2, 3, 4, 5, 6, 7, 8})
local process_id = upvalue('process_id')
if sdk then
    -- The SDK prototypes are the live ones for the real names, in both SDK orders.
    local exe = kernel32.GetModuleHandleA(nil)
    assert(ffi.istype('uintptr_t', exe), 'the SDK GetModuleHandleA must stay live')
    local copied, count = ffi.new('UCHAR[4]'), ffi.new('size_t[1]')
    assert(kernel32.ReadProcessMemory(kernel32.GetCurrentProcess(), ffi.cast('uintptr_t', block) + 2, copied, 4, count)
           ~= 0 and copied[0] == 3 and copied[3] == 6, 'the SDK ReadProcessMemory (integer address) must stay live')
    -- Window calls: the mod's focus check agrees with the SDK calls.
    assert(process_id == tonumber(kernel32.GetCurrentProcessId()), 'process id')
    local window, owner = user32.GetForegroundWindow(), ffi.new('DWORD[1]')
    assert(window == nil or ffi.istype('HWND', window), 'the SDK GetForegroundWindow must stay live')
    local ours = window ~= nil and user32.GetWindowThreadProcessId(window, owner) ~= 0 and owner[0] == process_id
    assert(upvalue('focused_game')(true) == ours, 'the focus check must agree with the SDK calls')
else
    assert(type(upvalue('focused_game')(true)) == 'boolean', 'the focus check works')
end
-- The thread and process query answers for the desktop window, which always exists.
ffi.cdef('int32_t ssh_test_GetDesktopWindow(void) __asm__("GetDesktopWindow");')
local desktop_owner = ffi.new('GMH_u32[1]')
local mod_user32 = upvalue('user32')
assert(mod_user32.GMH_GetWindowThreadProcessId(user32.ssh_test_GetDesktopWindow(), desktop_owner) ~= 0
       and desktop_owner[0] ~= 0, 'the window owner query must work')

-- Key calls: F24, which nobody holds, reads up (in the SDK prototype too).
local key_down = upvalue('key_down')
assert(key_down(0x87) == false and (not sdk or bit.band(user32.GetAsyncKeyState(0x87), 0x8000) == 0), 'key state')

-- Memory calls: reads, a refused read, module hashing through the runtime (once
-- per session for every mod), and the native check failing closed for the
-- reason a test process has (no game.dll).
local read = upvalue('read')
assert(read(tonumber(ffi.cast('uintptr_t', block)) + 2, 4) == '\3\4\5\6', 'the mod reads memory')
assert(read(1, 8) == nil, 'an unreadable address reads nothing')
local memory = upvalue('memory')
local hash = memory.module_hash(memory.module(nil))
assert(#hash == 64 and hash:match('^[0-9A-F]+$'), 'the mod hashes a module file')
upvalue('initialize_native')()
local unavailable = false
for _, message in ipairs(messages) do
    assert(not message:find('Update error', 1, true), message)
    unavailable = unavailable or message == 'ShipStationHotkeys stopped: game modules unavailable\n'
end
assert(unavailable, 'outside the game the native check must fail closed: ' .. table.concat(messages, ' | '))

local how = {['sdk-first'] = 'SDK-style declarations made first',
             ['mod-first'] = 'SDK-style declarations made after the mod loaded, with the real names and type names free '
                             .. 'until then',
             ['hostile-first'] = 'every real name declared first with a prototype that fits nothing (H.clash)'}
print('PASS: Windows calls under private names, ' .. how[order] .. ': window focus, key state, memory reads and module '
      .. 'hashing work' .. (sdk and ', and the SDK prototypes stay live' or ''))
