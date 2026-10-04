-- The memory API the patch and the loader use, on top of Bingus Shared Runtime
-- v1: runtime is the core (src/bingus_runtime.lua) and memory the api of
-- src/bingus_memory.lua extended by src/bingus_write.lua, byte-identical copies
-- that the build embeds and passes in. The runtime declares the Windows
-- functions under private, versioned FFI names and provides the page check,
-- checked writes, module handles and module hashes (computed once per session
-- for every mod). This adapter adds what the patch needs beyond that: reads at
-- plain-number addresses that allocate nothing but a returned string, writes
-- whose page the caller already checked and the span a page check approved.
-- The log throttle's clock is the runtime's: memory.time(), seconds from the
-- performance counter, which allocates nothing.
return function(runtime, memory)
    assert(type(runtime) == 'table' and type(memory) == 'table' and type(memory.write) == 'function',
        'Bingus Shared Runtime v1 memory api with writes is required')
    local native = memory.windows
    local ffi, kernel = native.ffi, native.kernel32
    -- Private names, declared once per process: ffi.cdef keeps the first
    -- declaration of a name for the whole game. The casts below use these named
    -- types: a function pointer written out in a type string adds C types to the
    -- table all mods share on every use.
    if not pcall(ffi.typeof, 'swd_read_memory') then
        ffi.cdef [[
            typedef int (*swd_read_memory)(void *process, uint64_t address, uint64_t buffer, size_t size, uint32_t *read);
            typedef int (*swd_write_memory)(void *process, uint64_t address, const void *buffer, size_t size, uint32_t *written);
        ]]
    end
    -- Memory is addressed by plain numbers: these casts of the runtime's
    -- functions take the address and destination as uint64_t (the same register
    -- as a pointer on x64) and the byte count as two 32-bit words, so a call
    -- creates no pointer or 64-bit cdata. Neither call re-enters Lua before its
    -- count words are read. The runtime's read and read_into take pointers
    -- instead, which number addresses would have to be cast to on every read:
    -- 16 bytes of garbage per address (32 per read_into) wherever the code runs
    -- interpreted, which is always the snapshot and in practice the rarely run
    -- dive start, landing and restore.
    local read_memory = ffi.cast('swd_read_memory', kernel.ReadProcessMemory)
    local write_memory = ffi.cast('swd_write_memory', kernel.WriteProcessMemory)
    local process = kernel.GetCurrentProcess()
    local api = {queries = 0, module = memory.module, module_hash = memory.module_hash, distance = memory.distance,
        time = memory.time}

    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    -- read(address, size) returns the bytes as a string (one scratch buffer,
    -- grown on demand): a read allocates only the returned string.
    -- read(address, size, into, offset) copies them into a caller buffer
    -- {data, address, size} at offset and returns true: nothing is allocated,
    -- which is what the per-frame snapshot uses.
    local scratch_size, scratch = 4096, ffi.new('uint8_t[4096]')
    local scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if size <= 0 or offset < 0 or offset + size > into.size then return nil end
            return read_to(address, size, into.address + offset) or nil
        end
        if size < 0 or size > scratch_size then
            scratch, scratch_size = ffi.new('uint8_t[?]', size), size
            scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
        end
        if not read_to(address, size, scratch_address) then return nil end
        return ffi.string(scratch, size)
    end

    -- True, and the span [low, high) it approved, when every page of
    -- [address, address + size) is committed private read/write data: the
    -- runtime's check, one VirtualQuery per region (about 0.29 ms each in game;
    -- api.queries counts them). The runtime reports no region bounds, so the
    -- check covers the whole pages around the range and that is the span kept.
    -- Protection is set per page: the pages pass exactly when the range does.
    local PAGE = 4096
    function api.writable_data(address, size)
        if type(size) ~= 'number' or size <= 0 then return false end
        local low = memory.address(address)
        local high = low + size
        low, high = low - low % PAGE, high + (-high) % PAGE
        local ok = memory.writable_data(low, high - low)
        api.queries = memory.queries
        if not ok then return false end
        return true, low, high
    end

    -- checked: the caller verified this range with writable_data and decides
    -- how long that check stays valid, so the write makes no page check.
    -- Otherwise the runtime's write checks the range right before writing.
    local written = ffi.new('uint32_t[2]')
    function api.write(address, bytes, checked)
        if checked then
            return write_memory(process, address, bytes, #bytes, written) ~= 0
                and written[0] == #bytes and written[1] == 0
        end
        local ok = memory.write(ffi.cast('void *', address), bytes)
        api.queries = memory.queries
        return ok
    end
    return api
end
