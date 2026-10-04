-- The mod's Windows adapter over Bingus Shared Runtime v1: src/bingus_runtime.lua
-- (the core), src/bingus_memory.lua (reads) and src/bingus_write.lua (checked
-- writes), vendored byte-identical. The build embeds them and passes the core
-- and the memory api, the read side extended by the write side. The runtime
-- declares its Windows functions only under private, versioned FFI names, so
-- another mod's declarations cannot change them, and it reads each module's
-- SHA-256 once per session for every mod. Writes go only into committed private
-- read-write memory, checked with one protection query per region right before
-- the write. read_into reads into a buffer the caller keeps and allocates
-- nothing; the patch's checks use it.
return function(runtime, memory)
    assert(type(memory) == 'table' and type(memory.write_batch) == 'function',
        'bingus_memory.lua and bingus_write.lua v1 are required')
    return {
        module = memory.module, module_hash = memory.module_hash,
        read = memory.read, read_into = memory.read_into, pointer = memory.pointer, distance = memory.distance,
        writable_data = memory.writable_data, write = memory.write, write_batch = memory.write_batch,
    }
end
