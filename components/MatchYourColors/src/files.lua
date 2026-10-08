-- Match Your Colors: read-only access to the game's data files through kernel32, straight into the caller's
-- buffers (no Lua strings), with UTF-16 paths so any install folder works, and the listing of its patch files.
--
-- Used only while a recolor job runs, never on an idle frame. Each read is one ReadFile at an explicit offset (an
-- OVERLAPPED offset). Inside a job (Files.new with wait) the handles are overlapped: a read the disk does not answer
-- at once (a cold read: 62.5 and 141.9 ms in single reads in real play v1.2) is polled once per frame and wait()
-- yields the job meanwhile, instead of stalling the game's frame. Its buffer stays referenced until it completes;
-- close() and Files.settle() (a job abandoned at a pause or stop) cancel it and wait it out, so the kernel never
-- writes into a buffer the job has dropped. Without wait (tests, tools) reads block as plain synchronous reads.
-- Every Windows function goes by a private name with an __asm__ label naming the real export, and every type name
-- is this mod's own (ffi.cdef keeps the first declaration of a name for the whole game).
local ffi = require('ffi')

local Files = {}

local SENTINEL = 'myc1_overlapped'
local DECLARATIONS = [[
    typedef struct myc1_overlapped {
        uint64_t internal, internal_high;
        uint32_t offset, offset_high;
        void *event;
    } myc1_overlapped;
    void *myc1_CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                           uint32_t disposition, uint32_t flags, void *template_file) __asm__("CreateFileW");
    int myc1_ReadFile(void *file, void *buffer, uint32_t size, uint32_t *done,
                      myc1_overlapped *overlapped) __asm__("ReadFile");
    int myc1_CloseHandle(void *handle) __asm__("CloseHandle");
    uint32_t myc1_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity) __asm__("GetModuleFileNameW");
    int myc1_MultiByteToWideChar(uint32_t page, uint32_t flags, const char *text, int size, uint16_t *out,
                                 int capacity) __asm__("MultiByteToWideChar");
]]
-- Listing (v1.3: the mods' patch files, src/patches.lua), declared apart so a session that declared the block above
-- without it still gets it.
local FIND_SENTINEL = 'myc1_find_data'
local FIND_DECLARATIONS = [[
    typedef struct myc1_find_data {
        uint32_t attributes;
        uint32_t times[6];
        uint32_t size_high, size_low, reserved0, reserved1;
        uint16_t name[260];
        uint16_t alternate[14];
    } myc1_find_data;
    void *myc1_FindFirstFileW(const uint16_t *pattern, myc1_find_data *data) __asm__("FindFirstFileW");
    int myc1_FindNextFileW(void *handle, myc1_find_data *data) __asm__("FindNextFileW");
    int myc1_FindClose(void *handle) __asm__("FindClose");
]]

local GENERIC_READ, SHARE_ALL, OPEN_EXISTING, RANDOM_ACCESS = 0x80000000, 7, 3, 0x10000000
local CP_UTF8 = 65001
local HIGH = 4294967296
local MAX_PATH_UNITS = 32768

-- The batched listing (v1.3 performance pass), declared apart: a session where an older copy of this mod declared
-- the blocks above first still gets it. Basic info (no short names) and large fetches: the data folder's patch files
-- are listed in about 0.08 ms instead of 1.5 ms (each FindNextFileW of the plain call went to the file system).
local FIND_EX_DECLARATION = [[
    void *myc1_FindFirstFileExW(const uint16_t *pattern, int level, myc1_find_data *data, int search, void *filter,
                                uint32_t flags) __asm__("FindFirstFileExW");
]]
local FIND_EX_INFO_BASIC, FIND_EX_SEARCH_NAME_MATCH, FIND_FIRST_EX_LARGE_FETCH = 1, 0, 2
-- Overlapped reads (v1.3 performance pass), declared apart for the same reason. LuaJIT keeps GetLastError's value
-- across its own work between two FFI calls.
local OVERLAPPED_DECLARATION = [[
    int myc1_GetOverlappedResult(void *file, myc1_overlapped *overlapped, uint32_t *done, int wait)
        __asm__("GetOverlappedResult");
    int myc1_CancelIoEx(void *file, myc1_overlapped *overlapped) __asm__("CancelIoEx");
    uint32_t myc1_GetLastError(void) __asm__("GetLastError");
]]
local FILE_FLAG_OVERLAPPED, ERROR_IO_PENDING, ERROR_IO_INCOMPLETE = 0x40000000, 997, 996

local kernel
local function bind()
    if kernel then return kernel end
    if not ffi.abi('64bit') then error('Windows x64 is required', 0) end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    if not pcall(ffi.typeof, FIND_SENTINEL) then ffi.cdef(FIND_DECLARATIONS) end
    local k = ffi.load('kernel32')
    if not pcall(function() return k.myc1_FindFirstFileExW end) then ffi.cdef(FIND_EX_DECLARATION) end
    if not pcall(function() return k.myc1_GetOverlappedResult end) then ffi.cdef(OVERLAPPED_DECLARATION) end
    kernel = k
    return kernel
end

-- Adapters with a read in flight (kept referenced, with their buffers, until it completes or is settled).
local in_flight = {}

-- Cancels every read still in flight and waits each out (a job abandoned at a pause or stop). Blocks only then.
function Files.settle()
    local adapters = {}
    for adapter in pairs(in_flight) do adapters[#adapters + 1] = adapter end
    for _, adapter in ipairs(adapters) do adapter.settle() end
end

-- A UTF-16 path array holding `prefix` (UTF-16 units, count units) followed by the UTF-8 string `name`, and
-- a terminating 0.
local function join(prefix, count, name)
    local k = bind()
    local extra = k.myc1_MultiByteToWideChar(CP_UTF8, 0, name, #name, nil, 0)
    if #name > 0 and extra <= 0 then error('file name not UTF-8: ' .. name, 0) end
    local path = ffi.new('uint16_t[?]', count + extra + 1)
    if count > 0 then ffi.copy(path, prefix, count * 2) end
    if extra > 0 then k.myc1_MultiByteToWideChar(CP_UTF8, 0, name, #name, path + count, extra) end
    path[count + extra] = 0
    return path
end

-- A find record's file name (its name array, taken once per listing: every data.name makes a new reference) as a
-- Lua string, or nil when it is not ASCII (no patch file name is).
local name_bytes = ffi.new('uint8_t[260]')
local function ascii_name(name)
    local n = 0
    while n < 260 do
        local unit = name[n]
        if unit == 0 then break end
        if unit > 127 then return nil end
        name_bytes[n] = unit
        n = n + 1
    end
    return ffi.string(name_bytes, n)
end

-- The game's data folder as UTF-16 units: the executable's folder (bin) replaced by its sibling data folder.
-- Returns the units and their count, or raises.
function Files.game_data_folder()
    local k = bind()
    local path = ffi.new('uint16_t[?]', MAX_PATH_UNITS)
    local length = k.myc1_GetModuleFileNameW(nil, path, MAX_PATH_UNITS)
    if length == 0 or length >= MAX_PATH_UNITS then error('executable path unavailable', 0) end
    local separators, cut = 0, nil
    for i = length - 1, 0, -1 do
        if path[i] == 92 or path[i] == 47 then -- \ or /
            separators = separators + 1
            if separators == 2 then cut = i break end
        end
    end
    if not cut then error('executable path has no parent folder', 0) end
    local data = join(path, cut + 1, 'data\\')
    return data, cut + 1 + 5
end

-- The adapter Slim.open expects: open(name) -> handle, read(handle, at, size, buffer), close(handle).
-- folder: UTF-16 units and their count (Files.game_data_folder) or a UTF-8 string ending in a separator;
-- clock (optional): seconds, to keep the longest single call (self.longest, self.longest_size); wait (optional,
-- inside a job): yields to the next frame while a read is in flight (self.waits counts them). kernel: tests only.
function Files.new(folder, count, clock, wait, kernel_override)
    local k = kernel_override or bind()
    if type(folder) == 'string' then
        folder, count = join(nil, 0, folder), nil
        count = 0
        while folder[count] ~= 0 do count = count + 1 end
    end
    local overlapped = ffi.new(SENTINEL)
    local done = ffi.new('uint32_t[1]')
    local flags = RANDOM_ACCESS + (wait and FILE_FLAG_OVERLAPPED or 0)
    local self = {reads = 0, bytes = 0, opened = 0, longest = 0, longest_size = 0, waits = 0}
    local pending_handle, pending_buffer = nil, nil

    function self.open(name)
        local path = join(folder, count, name)
        local handle = k.myc1_CreateFileW(path, GENERIC_READ, SHARE_ALL, nil, OPEN_EXISTING, flags, nil)
        if ffi.cast('intptr_t', handle) == -1 then error('cannot open game file ' .. name, 0) end
        self.opened = self.opened + 1
        return handle
    end

    -- An overlapped read: started, then polled (no waiting) with wait() between polls until it completes. True
    -- when all `size` bytes arrived.
    local function read_overlapped(handle, size, buffer)
        pending_handle, pending_buffer, in_flight[self] = handle, buffer, true
        local ok = k.myc1_ReadFile(handle, buffer, size, nil, overlapped) ~= 0
            or k.myc1_GetLastError() == ERROR_IO_PENDING
        while ok and k.myc1_GetOverlappedResult(handle, overlapped, done, 0) == 0 do
            ok = k.myc1_GetLastError() == ERROR_IO_INCOMPLETE
            if ok then
                self.waits = self.waits + 1
                wait()
            end
        end
        pending_handle, pending_buffer, in_flight[self] = nil, nil, nil
        return ok and done[0] == size
    end

    function self.read(handle, at, size, buffer)
        if size == 0 then return end
        overlapped.internal, overlapped.internal_high = 0, 0
        overlapped.offset = at % HIGH
        overlapped.offset_high = (at - at % HIGH) / HIGH
        overlapped.event = nil
        local started, waits = clock and clock(), self.waits
        local ok
        if wait then
            ok = read_overlapped(handle, size, buffer)
        else
            ok = k.myc1_ReadFile(handle, buffer, size, done, overlapped) ~= 0 and done[0] == size
        end
        if not ok then error('game file read failed', 0) end
        if started and self.waits == waits then -- the longest read that held its frame (a waited one did not)
            local took = clock() - started
            if took > self.longest then self.longest, self.longest_size = took, size end
        end
        self.reads, self.bytes = self.reads + 1, self.bytes + size
    end

    -- A read still in flight (its job was abandoned): cancelled, then waited out.
    function self.settle()
        if not pending_handle then return end
        k.myc1_CancelIoEx(pending_handle, overlapped)
        k.myc1_GetOverlappedResult(pending_handle, overlapped, done, 1)
        pending_handle, pending_buffer, in_flight[self] = nil, nil, nil
    end

    function self.close(handle)
        if handle == pending_handle then self.settle() end
        k.myc1_CloseHandle(handle)
    end

    -- The names of the files in the folder matching pattern (FindFirstFileW wildcards), ASCII names only; {} when
    -- none match.
    function self.list(pattern)
        local data = ffi.new(FIND_SENTINEL)
        local handle = k.myc1_FindFirstFileExW(join(folder, count, pattern), FIND_EX_INFO_BASIC, data,
                                               FIND_EX_SEARCH_NAME_MATCH, nil, FIND_FIRST_EX_LARGE_FETCH)
        if ffi.cast('intptr_t', handle) == -1 then return {} end
        local names, units = {}, data.name
        repeat
            local name = data.attributes % 32 < 16 and ascii_name(units) -- folders and other names left out
            if name then names[#names + 1] = name end
        until k.myc1_FindNextFileW(handle, data) == 0
        k.myc1_FindClose(handle)
        return names
    end
    return self
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({join, ascii_name, Files.settle, Files.game_data_folder, Files.new}) do
        jit.off(fn, true)
    end
end

return Files
