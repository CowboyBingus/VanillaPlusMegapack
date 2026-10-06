-- The memory API the hold and the loader use, on top of Bingus Shared Runtime v1:
-- runtime is the core (src/bingus_runtime.lua) and memory the api of
-- src/bingus_memory.lua extended by src/bingus_write.lua, byte-identical copies
-- that the build embeds and passes in. The runtime declares its Windows
-- functions under private, versioned FFI names, checks pages and hashes each
-- game module once per session for every mod.
--
-- This adapter adds reads at plain-number addresses into a buffer the caller
-- keeps, also given by its number address: read_to(address, size, destination).
-- The runtime's read_into takes pointer cdata, which a number address would have
-- to be cast to on every read (16 bytes of garbage each). The hold follows game
-- pointers it reads as numbers, so it reads only through read_to and allocates
-- nothing per read. Writes go through the runtime's checked write_batch, which
-- takes a number base and queries the page right before the write.
return function(runtime, memory)
    assert(type(runtime) == 'table' and type(memory) == 'table' and type(memory.write_batch) == 'function',
        'bingus_memory.lua and bingus_write.lua v1 are required')
    local native = memory.windows
    local ffi, kernel = native.ffi, native.kernel32
    -- A private name, declared once per process: ffi.cdef keeps the first
    -- declaration of a name for the whole game. The cast below uses this named
    -- type, because a function-pointer type written out in a string adds C types
    -- to the table every mod shares each time it is used.
    if not pcall(ffi.typeof, 'hellpod_drop_hold1_read_memory') then
        ffi.cdef [[
            typedef int (*hellpod_drop_hold1_read_memory)(void *process, uint64_t address, uint64_t buffer,
                                                          size_t size, uint32_t *read);
        ]]
    end
    -- The runtime's bound ReadProcessMemory, taking the address and the
    -- destination as uint64_t (the same register as a pointer on x64) and the
    -- byte count as two 32-bit words: a call creates no cdata.
    local read_memory = ffi.cast('hellpod_drop_hold1_read_memory', kernel.ReadProcessMemory)
    local process = kernel.GetCurrentProcess()
    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    return {
        module = memory.module, module_hash = memory.module_hash, verify_build = memory.verify_build,
        address = memory.address, read_to = read_to, writable_data = memory.writable_data,
        write_batch = memory.write_batch,
    }
end
