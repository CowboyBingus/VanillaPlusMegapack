-- Match Your Colors: read-only access to the game's data files through kernel32, straight into the caller's
-- buffers (no Lua strings), with UTF-16 paths so any install folder works.
--
-- Used only while a recolor job runs, never on an idle frame. Each read is one ReadFile at an explicit offset
-- (an OVERLAPPED offset on a synchronous handle). Every Windows function goes by a private name with an
-- __asm__ label naming the real export, and every type name is this mod's own (ffi.cdef keeps the first
-- declaration of a name for the whole game).
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

local GENERIC_READ, SHARE_ALL, OPEN_EXISTING, RANDOM_ACCESS = 0x80000000, 7, 3, 0x10000000
local CP_UTF8 = 65001
local HIGH = 4294967296
local MAX_PATH_UNITS = 32768

local kernel
local function bind()
    if kernel then return kernel end
    if not ffi.abi('64bit') then error('Windows x64 is required', 0) end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    kernel = ffi.load('kernel32')
    return kernel
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
-- clock (optional): seconds, to keep the longest single read (self.longest, self.longest_size).
function Files.new(folder, count, clock)
    local k = bind()
    if type(folder) == 'string' then
        folder, count = join(nil, 0, folder), nil
        count = 0
        while folder[count] ~= 0 do count = count + 1 end
    end
    local overlapped = ffi.new(SENTINEL)
    local done = ffi.new('uint32_t[1]')
    local self = {reads = 0, bytes = 0, opened = 0, longest = 0, longest_size = 0}

    function self.open(name)
        local path = join(folder, count, name)
        local handle = k.myc1_CreateFileW(path, GENERIC_READ, SHARE_ALL, nil, OPEN_EXISTING, RANDOM_ACCESS, nil)
        if ffi.cast('intptr_t', handle) == -1 then error('cannot open game file ' .. name, 0) end
        self.opened = self.opened + 1
        return handle
    end

    function self.read(handle, at, size, buffer)
        if size == 0 then return end
        overlapped.offset = at % HIGH
        overlapped.offset_high = (at - at % HIGH) / HIGH
        overlapped.event = nil
        local started = clock and clock()
        if k.myc1_ReadFile(handle, buffer, size, done, overlapped) == 0 or done[0] ~= size then
            error('game file read failed', 0)
        end
        if started then
            local took = clock() - started
            if took > self.longest then self.longest, self.longest_size = took, size end
        end
        self.reads, self.bytes = self.reads + 1, self.bytes + size
    end

    function self.close(handle)
        k.myc1_CloseHandle(handle)
    end
    return self
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({join, Files.game_data_folder, Files.new}) do
        jit.off(fn, true)
    end
end

return Files
