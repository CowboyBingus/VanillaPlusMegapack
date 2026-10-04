-- The mod's Windows adapter over Bingus Shared Runtime v1: the memory api of
-- src/bingus_memory.lua extended by src/bingus_write.lua (vendored
-- byte-identical; the build embeds them and passes the api in). The runtime
-- declares its Windows functions only under private, versioned FFI names, so
-- another mod's declarations cannot change them, and it reads each module's
-- SHA-256 once per session for every mod. Writes go only into committed private
-- read-write memory, checked with one protection query per region right before
-- the write.
local ffi = require('ffi')
local HIGH = 4294967296

-- The user-mode pointer stored little-endian at buffer[offset .. offset + 7]
-- of a byte buffer the mod keeps (filled by read_into), as uint8_t *, or nil:
-- memory.pointer's rules for a string, without first copying the bytes into one.
local function pointer_at(buffer, offset)
    if buffer[offset + 6] ~= 0 or buffer[offset + 7] ~= 0 then return nil end
    local value = buffer[offset] + buffer[offset + 1] * 256 + buffer[offset + 2] * 65536
        + buffer[offset + 3] * 16777216 + (buffer[offset + 4] + buffer[offset + 5] * 256) * HIGH
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return ffi.cast('uint8_t *', value)
end

return function(runtime, memory)
    assert(type(runtime) == 'table' and type(runtime.guard) == 'function', 'bingus_runtime.lua v1 is required')
    assert(type(memory) == 'table' and type(memory.write) == 'function', 'bingus_memory.lua and bingus_write.lua are required')
    return {
        module = memory.module, module_hash = memory.module_hash,
        read = memory.read, read_into = memory.read_into, pointer = memory.pointer, pointer_at = pointer_at,
        distance = memory.distance, writable_data = memory.writable_data, write = memory.write,
    }
end
