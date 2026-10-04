-- Windows and native-call layer for Better Lobby Management. Addresses are plain Lua
-- numbers (user-mode addresses stay below 2^53); 64-bit peer ids never are
-- (see u64). Nothing here allocates per call except the u64 helpers, which run
-- only on action frames. memory: the read side of Bingus Shared Runtime
-- (src/bingus_memory.lua, new(runtime)), used for module hashes only: each
-- module file is hashed once per session for every mod on the runtime.
return function(memory)
    if type(memory) ~= 'table' or type(memory.module_hash) ~= 'function' then
        error('the memory api of the shared runtime is required', 0)
    end
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Named types are declared once: a type written out in a string adds a C
    -- type on every evaluation.
    if not pcall(ffi.typeof, 'LmMemoryRegion') then
        ffi.cdef [[
            typedef struct {
                uint64_t base; uint64_t allocation_base; uint32_t allocation_protection;
                uint16_t partition; uint16_t reserved; uint64_t size;
                uint32_t state; uint32_t protection; uint32_t type;
            } LmMemoryRegion;
            typedef void (*LmKickPeer)(uint64_t host_sync, uint64_t peer);
            typedef uint8_t (*LmStartJoin)(uint64_t join, uint64_t info, int32_t type, uint64_t unused, int32_t reason);
            typedef void (*LmFilterString)(uint64_t field, int32_t key, uint64_t value, uint32_t op);
            typedef uint64_t (*LmBrowserStart)(uint64_t field);
            typedef uint8_t (*LmBrowserBusy)(uint64_t field);
            typedef int32_t (*LmBrowserCount)(uint64_t field);
            typedef uint64_t (*LmBrowserResult)(uint64_t field, uint64_t out, uint32_t index);
            typedef void (*LmHandleCall)(uint64_t handle);
            typedef uint64_t (*LmSelfCall)(uint64_t self);
            typedef uint8_t (*LmIsFriend)(uint64_t unused, uint64_t peer);
            typedef void (*LmAddChild)(uint64_t parent, uint64_t child);
            typedef void (*LmSetLabel)(uint64_t widget, uint32_t label);
            typedef void (*LmSetStringArg)(uint64_t widget, uint32_t key, uint64_t text);
            typedef uint8_t (*LmClearArgs)(uint64_t label);
            typedef void (*LmWidgetCall)(uint64_t widget);
            typedef void (*LmSetEnabled)(uint64_t widget, uint8_t enabled);
            typedef uint8_t (*LmDialogSetup)(uint64_t dialog, uint32_t title, uint32_t text, uint32_t confirm,
                                             uint32_t cancel, uint8_t hold, uint8_t flag);
            typedef void (*LmRebuild)(uint64_t content, uint64_t unused);
            typedef void (*LmSetMarquee)(uint64_t text, float width);
            typedef uint32_t (*LmGetFlag)(void);
            typedef void (*LmSetFlag)(int32_t value);
            typedef void (*LmSendKick)(uint64_t peer);
            typedef void (*LmFocus)(uint64_t content, uint8_t index);
            typedef void (*LmCardState)(uint64_t card, int32_t state);
            typedef int32_t (*LmGetKeys)(uint64_t lobby, uint64_t count_out, uint64_t keys_out);
            typedef int32_t (*LmGetProperty)(uint64_t lobby, uint64_t key, uint64_t value_out);
            typedef int32_t (*LmGetAccess)(uint64_t lobby, uint64_t policy_out);
            typedef void (*LmChatSend)(uint64_t chat, uint64_t unused, uint64_t text);
            typedef void (*LmRpcSend)(uint32_t hash, uint64_t target, uint64_t args, uint32_t count);
            typedef void (*LmSosCall)(uint64_t sos);
            typedef void (*LmLobbySetInt)(uint64_t lobby, uint32_t key, int32_t value);
        ]]
    end
    -- Every Windows function has a private name, an __asm__ label naming the
    -- real export: LuaJIT keeps the first prototype declared for a name in the
    -- state the game and every mod share, so a mod that declared the real names
    -- first, with other prototypes, would change how this mod calls them, and
    -- a mod declaring them later would get this mod's. Declaring a private name
    -- again (a second api) changes nothing. The memory query and read take
    -- addresses and the buffer as numbers, so a call creates no pointer.
    ffi.cdef [[
        void *blm_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *blm_GetProcAddress(void *module, const char *name) __asm__("GetProcAddress");
        void *blm_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int blm_ReadProcessMemory(void *process, uint64_t address, uint64_t buffer, size_t size, uint32_t *count)
            __asm__("ReadProcessMemory");
        size_t blm_VirtualQuery(uint64_t address, LmMemoryRegion *region, size_t size) __asm__("VirtualQuery");
    ]]
    local kernel = ffi.load('kernel32')
    local query_region = kernel.blm_VirtualQuery
    local read_memory = kernel.blm_ReadProcessMemory
    local process = kernel.blm_GetCurrentProcess()
    local api = {}

    -- Direct loads through typed pointers based at address 0: an address
    -- becomes an index, a load returns a plain number, and nothing calls into
    -- Windows. Only for memory known to be mapped: game.dll's image, and objects
    -- a guarded read has confirmed.
    local BYTES, WORDS, FLOATS = ffi.cast('uint8_t *', 0), ffi.cast('uint32_t *', 0), ffi.cast('float *', 0)
    function api.load8(address) return BYTES[address] end
    function api.load32(address) return WORDS[address / 4] end
    function api.loadf(address) return FLOATS[address / 4] end
    function api.load64(address) return WORDS[address / 4] + WORDS[address / 4 + 1] * 4294967296 end

    -- ReadProcessMemory on this process: a stale address fails the call
    -- instead of faulting the game. One reused buffer receives the value; the
    -- count's two halves land in count (it is a size_t).
    local cell, count = ffi.new('uint32_t[2]'), ffi.new('uint32_t[2]')
    local cell_address = tonumber(ffi.cast('uintptr_t', cell))
    local function fill(address, size)
        return read_memory(process, address, cell_address, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    function api.read32(address)
        if not fill(address, 4) then return nil end
        return cell[0]
    end
    function api.read64(address)
        if not fill(address, 8) then return nil end
        return cell[0] + cell[1] * 4294967296
    end
    local cell_float = ffi.cast('float *', cell)
    function api.read_f32(address)
        if not fill(address, 4) then return nil end
        return cell_float[0]
    end

    -- A reusable buffer (kept alive by api; allocate once, at startup) and, for
    -- diagnostic builds, one ReadProcessMemory copying size bytes into it; a
    -- stale address fails the call. Returns the buffer's address; its contents
    -- are read with loads.
    local blocks = {}
    function api.buffer(size)
        local block = ffi.new('uint8_t[?]', size)
        blocks[#blocks + 1] = block
        return tonumber(ffi.cast('uintptr_t', block))
    end
    local function read_block(address, buffer, size)
        return read_memory(process, address, buffer, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    api.read_block = read_block
    -- Up to 16 bytes as a string through ReadProcessMemory (a stale address
    -- fails, never faults): the reads of the game's Text Language, which
    -- bingus_text makes when the escape menu opens.
    local small = ffi.new('uint8_t[16]')
    local small_address = tonumber(ffi.cast('uintptr_t', small))
    function api.read_bytes(address, size)
        if size > 16 or not read_block(address, small_address, size) then return nil end
        return ffi.string(small, size)
    end

    -- True when every byte of [address, address + size) is committed private
    -- read/write memory. One VirtualQuery each, about 0.29 ms in game.
    local region = ffi.new('LmMemoryRegion')
    local region_size = ffi.sizeof('LmMemoryRegion')
    api.queries = 0
    function api.writable_data(address, size)
        api.queries = api.queries + 1
        if query_region(address, region, region_size) ~= region_size then return false end
        if region.state ~= 0x1000 or region.type ~= 0x20000 or region.protection ~= 4 then return false end
        local base = tonumber(region.base)
        return address >= base and address + size <= base + tonumber(region.size)
    end

    -- Writes check their range first (through api, so a call budget counts the
    -- check); committed private read/write memory cannot fault, so the values
    -- are then stored directly. write_words stores several 32-bit words under
    -- one check: words = {offset, value, offset, value, ...}.
    function api.write32(address, value)
        if not api.writable_data(address, 4) then return false end
        WORDS[address / 4] = value
        return true
    end
    function api.write_f32(address, value)
        if not api.writable_data(address, 4) then return false end
        FLOATS[address / 4] = value
        return true
    end
    function api.write_words(address, size, words)
        if not api.writable_data(address, size) then return false end
        for i = 1, #words, 2 do WORDS[(address + words[i]) / 4] = words[i + 1] end
        return true
    end

    function api.module(name)
        local handle = kernel.blm_GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end

    -- An exported function's address (startup only).
    function api.export(module, name)
        local address = kernel.blm_GetProcAddress(ffi.cast('void *', module), name)
        if address == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', address))
    end

    -- A native function at address as one of the Lm* pointer types above.
    function api.native(type_name, address)
        return ffi.cast(type_name, address)
    end

    -- Bytes of mapped image memory (startup verification only).
    function api.bytes(address, size)
        return ffi.string(ffi.cast('const char *', address), size)
    end

    -- A C string at address (at most limit bytes, never reading past its
    -- terminator), or nil for a null pointer. Action frames only.
    function api.cstring(address, limit)
        if address == 0 then return nil end
        local length = 0
        while length < limit and BYTES[address + length] ~= 0 do length = length + 1 end
        return ffi.string(ffi.cast('const char *', address), length)
    end

    -- One 16-byte aligned scratch block for the structures handed to native
    -- code (some game functions load caller buffers with aligned SSE moves).
    -- Kept alive by api; offsets are fixed by the callers.
    local block = ffi.new('uint8_t[?]', 1024 + 16)
    api.scratch_block = block
    api.scratch = math.floor((tonumber(ffi.cast('uintptr_t', block)) + 15) / 16) * 16
    api.SCRATCH_SIZE = 1024
    function api.zero(address, size) ffi.fill(ffi.cast('void *', address), size, 0) end
    function api.put_string(address, text, capacity)
        assert(#text < capacity, 'string too long for its buffer')
        ffi.copy(ffi.cast('void *', address), text, #text + 1)
    end
    function api.put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
    function api.put32(address, value) WORDS[address / 4] = value end

    -- Peer ids are 64-bit values above 2^53, so they travel as two 32-bit
    -- halves (lo, hi) and become a uint64_t only for a native call.
    function api.u64(lo, hi) return ffi.cast('uint64_t', hi) * 4294967296ULL + lo end
    -- Decimal by long division in base 10^6 on the two halves (every step is
    -- exact in a double). Not tostring: the game replaces it, and its version
    -- prints 64-bit cdata as '[cdata (deleted)]' (the v0.4-diag4 search value).
    function api.u64_decimal(lo, hi)
        local chunks = {}
        repeat
            local high = hi % 1000000
            hi = (hi - high) / 1000000
            local current = high * 4294967296 + lo
            local chunk = current % 1000000
            lo = (current - chunk) / 1000000
            table.insert(chunks, 1, string.format((hi > 0 or lo > 0) and '%06d' or '%d', chunk))
        until hi == 0 and lo == 0
        return table.concat(chunks)
    end
    function api.u64_hex(lo, hi)
        if hi == 0 then return string.format('%X', lo) end
        return string.format('%X%08X', hi, lo)
    end

    -- The SHA-256 (uppercase hex) of a loaded module's file, from the shared
    -- session cache: read and hashed at most once per session for every mod on
    -- the runtime (startup only).
    function api.module_sha256(module)
        return memory.module_hash(ffi.cast('void *', module))
    end
    return api
end
