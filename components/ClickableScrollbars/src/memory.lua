-- Memory views over the game's objects, and the reader the addon ships with.
local module, cs = ...
local GRID, BLOCK_BYTES = cs.GRID, cs.BLOCK_BYTES

-- One block buffer serves every memory view: native_state decodes a block
-- before it reads the next one and is never re-entered.
local block_buffer
local function shared_block(ffi)
    if not block_buffer then
        local bytes = ffi.new('uint8_t[?]', BLOCK_BYTES)
        block_buffer = {bytes = bytes, u32 = ffi.cast('uint32_t *', bytes), f32 = ffi.cast('float *', bytes)}
    end
    return block_buffer
end

-- A memory view is the only thing the native layer needs, so the code that runs
-- in game is the code the offline model exercises. With a reader that fills
-- caller buffers (read_into: the shipped reader) a field read allocates nothing;
-- other readers return strings.
function module.native_memory(api)
    if type(api) ~= 'table' or type(api.read) ~= 'function' then return nil, 'no reader' end
    local ok, ffi = pcall(require, 'ffi')
    if not ok then return nil, 'ffi unavailable' end
    local word, real = ffi.new('uint32_t[1]'), ffi.new('float[1]')
    local memory = {api = api, float = real, word = word}
    local function read4(address, buffer)
        if api.read_into then return api.read_into(address, buffer, 4) end
        local bytes = api.read(address, 4)
        if type(bytes) ~= 'string' or #bytes < 4 then return false end
        ffi.copy(buffer, bytes, 4)
        return true
    end
    function memory.read_u32(address)
        if not read4(address, word) then return nil end
        return tonumber(word[0])
    end
    function memory.read_f32(address)
        if not read4(address, real) then return nil end
        return tonumber(real[0])
    end
    -- native_state's block reads: one read of up to BLOCK_BYTES into the shared
    -- block, decoded through its two typed views (only the reader writes it).
    if api.read_into then
        local block = shared_block(ffi)
        memory.block_u32, memory.block_f32 = block.u32, block.f32
        function memory.read_block(address, size)
            return size <= BLOCK_BYTES and api.read_into(address, block.bytes, size) == true
        end
    end
    -- A direct store (the build keeps the process-memory write API loader-only). pcall
    -- turns a malformed address into false; it cannot catch an access violation, so
    -- callers only pass addresses of objects re-validated in the same frame.
    local floats = ffi.typeof('float *')
    local function store_f32(address, value)
        ffi.cast(floats, address)[0] = value -- lint-ok: R3 the direct store described above
    end
    function memory.write_f32(address, value)
        if type(value) ~= 'number' or value ~= value or math.abs(value) > GRID.max_pixels then return false end
        return (pcall(store_f32, address, value))
    end
    return memory
end

-- The reader the addon ships with: a module handle plus a bounded read of this
-- process. Its Windows functions have private names (__asm__ labels): LuaJIT
-- keeps the first prototype declared for a name in the whole process, so
-- another mod's declaration of the real names cannot change these calls.
function module.native_reader()
    local ok, ffi = pcall(require, 'ffi')
    if not ok or not ffi.abi('64bit') then return nil, 'ffi unavailable' end
    pcall(ffi.cdef, [[
        void *hd2cs_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *hd2cs_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int hd2cs_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                    size_t *read) __asm__("ReadProcessMemory");
    ]])
    local kernel32 = ffi.load('kernel32')
    local process = kernel32.hd2cs_GetCurrentProcess()
    -- ReadProcessMemory reports the bytes it copied through a SIZE_T, kept here
    -- as two words read as numbers (a size_t element is boxed on every read).
    local copied_words = ffi.new('uint32_t[2]')
    local copied = ffi.cast('size_t *', copied_words)
    local scratch, scratch_size = nil, 0
    local function valid_size(size)
        return type(size) == 'number' and size >= 1 and size <= 32768 and size % 1 == 0
    end
    -- True only when all size bytes at address were copied into buffer.
    local function copy(address, buffer, size)
        if kernel32.hd2cs_ReadProcessMemory(process, address, buffer, size, copied) == 0 then return false end
        return copied_words[0] == size and copied_words[1] == 0
    end
    local api = {}
    -- While api.tape is set (native_resolve), every read is appended to it as
    -- address, size and the bytes read (false when unreadable).
    local function record(address, size, bytes)
        local tape = api.tape
        local slot = tape.n * 3
        tape[slot + 1], tape[slot + 2], tape[slot + 3] = address, size, bytes or false
        tape.n = tape.n + 1
    end
    function api.module(name)
        local handle = kernel32.hd2cs_GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end
    -- Fills a caller's buffer: no allocation.
    function api.read_into(address, buffer, size)
        local read = valid_size(size) and copy(address, buffer, size)
        if api.tape then record(address, size, read and ffi.string(buffer, size)) end
        return read
    end
    -- One scratch buffer serves every string read; bytes that did not change
    -- come back as the same interned string, so a repeated read allocates nothing.
    function api.read(address, size)
        local bytes = nil
        if valid_size(size) then
            if size > scratch_size then scratch, scratch_size = ffi.new('uint8_t[?]', size), size end
            if copy(address, scratch, size) then bytes = ffi.string(scratch, size) end
        end
        if api.tape then record(address, size, bytes) end
        return bytes
    end
    function api.pointer(bytes, offset)
        offset = offset or 0
        if type(bytes) ~= 'string' or offset < 0 or offset + 8 > #bytes then return nil end
        local value = ffi.new('uintptr_t[1]')
        ffi.copy(value, bytes:sub(offset + 1, offset + 8), 8)
        if value[0] < 0x10000 or value[0] >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value[0])
    end
    return api
end

function module.native_api()
    local api, reason = module.native_reader()
    if not api then return nil, reason end
    -- Refuse all native scrolling if any called routine differs from this build.
    local game = api.module('game.dll')
    for _, entry in ipairs(module.native_signatures) do
        local bytes = entry[2]:gsub('..', function(hex) return string.char(tonumber(hex, 16)) end)
        if not game or api.read(game + entry[1], #bytes) ~= bytes then
            return nil, 'unsupported native scroll routine'
        end
    end
    return api
end

cs.keep_interpreted({module.native_reader, module.native_memory})
