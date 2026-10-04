-- The mod's Windows adapter over Bingus Shared Runtime v1: runtime is the core
-- (src/bingus_runtime.lua) and memory the api of src/bingus_memory.lua extended
-- by src/bingus_write.lua, byte-identical copies that the build embeds and
-- passes in. The runtime declares its Windows functions only under private,
-- versioned FFI names, so another mod's declarations cannot change them, and it
-- reads each module's SHA-256 once per session for every mod. Writes go only
-- into committed private read-write memory, checked with one protection query
-- per region right before the write.
return function(runtime, memory)
    assert(type(runtime) == 'table' and type(memory) == 'table' and type(memory.write_batch) == 'function',
        'Bingus Shared Runtime v1 memory api with writes is required')
    return {
        module = memory.module, module_hash = memory.module_hash,
        read = memory.read, pointer = memory.pointer, distance = memory.distance,
        writable_data = memory.writable_data, write = memory.write, write_batch = memory.write_batch,
    }
end
