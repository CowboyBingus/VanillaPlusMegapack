-- Real Windows adapter of Flame Damage Fixed against this process's own memory (run inside the game's
-- lua51.dll via PerformanceBaseline/game_lua.py, or any Windows LuaJIT). Usage: test_fix_adapter.lua <root>
local root = assert(arg[1], 'project root required')
local ffi = require('ffi')
_G.FLAME_DAMAGE_FIXED_ADAPTER_TEST = true
local api, module = dofile(root .. '/src/flame_damage_fixed.lua')
_G.FLAME_DAMAGE_FIXED_ADAPTER_TEST = nil
assert(type(api) == 'table' and api.u32 and api.write_raw and api.writable_region and api.load and api.write_u32,
    'adapter returned')
assert(module ~= nil, 'module lookup returned')  -- a bound cdata function (GetModuleHandleA)

local buffer = ffi.new('uint32_t[16]', {0x11223344, 0xa5a5a5a5})
local address = tonumber(ffi.cast('uintptr_t', buffer))
assert(api.u32(address) == 0x11223344, 'u32 reads through the numeric-address cast')
assert(api.u32(address + 4) == 0xa5a5a5a5, 'u32 keeps the full unsigned range')
assert(api.read(address, 4) == '\68\51\34\17', 'bulk read returns the bytes')
assert(api.read(address, 4096) == nil, 'bulk reads larger than the scratch buffer are refused')
assert(api.writable_data(address, 64), 'LuaJIT heap is committed private read-write data')
local base, size = api.writable_region(address)
assert(base and size and base <= address and address + 64 <= base + size, 'region covers the buffer')
assert(api.write_raw(address + 8, '\1\2\3\4') and buffer[2] == 0x04030201, 'raw write lands in place')
local words = api.load(address, 16)
assert(words and words[0] == 0x11223344 and words[1] == 0xa5a5a5a5 and words[2] == 0x04030201, 'block read: u32 view')
assert(api.load(address, 65537) == nil and api.load(address, 2) == nil, 'block reads outside 4 B..64 KB are refused')
assert(api.load(16, 16) == nil, 'unmapped block reads fail cleanly')
assert(api.write_u32(address + 12, 0xffe0000b) and buffer[3] == 0xffe0000b, 'u32 write keeps the full unsigned range')
assert(api.u32(16) == nil, 'unmapped address reads fail cleanly')
-- The loaded lua51.dll image is never writable private data.
local image = module('lua51.dll')
if image == nil then image = module(nil) end
image = tonumber(ffi.cast('uintptr_t', image))
assert(not api.writable_data(image, 16) and api.writable_region(image) == nil, 'module image refused')
assert(module('kernel32.dll') ~= nil and module('fdf-not-loaded.dll') == nil, 'module lookup resolves a real module only')
assert(not api.writable_data(16, 16) and api.writable_region(16) == nil, 'unmapped memory refused')

-- No garbage per read or region query, even interpreted: in game, cold paths (the weapon scan, burst
-- starts) run in the interpreter, where reading back any 64-bit value boxes a cdata (was 16 B per read).
local function garbage_per_call(call, n)
    collectgarbage('collect'); collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, n do call() end
    local bytes = (collectgarbage('count') - before) * 1024
    collectgarbage('restart')
    return bytes / n
end
jit.off(); jit.flush() -- test only: no earlier trace runs, so every call below is interpreted
local read_bytes = garbage_per_call(function() return api.u32(address) end, 10000)
local region_bytes = garbage_per_call(function() return api.writable_region(address) end, 2000)
local load_bytes = garbage_per_call(function() local w = api.load(address, 64); return w[3] end, 10000)
local write_bytes = garbage_per_call(function() return api.write_u32(address + 12, 0x0000000b) end, 10000)
jit.on()
assert(read_bytes < 1 and region_bytes < 1 and load_bytes < 1 and write_bytes < 1, string.format(
    'interpreted garbage: %.1f B per u32, %.1f B per region query, %.1f B per block read, %.1f B per u32 write',
    read_bytes, region_bytes, load_bytes, write_bytes))
print('PASS: real adapter reads, bulk and block reads, raw and u32 writes, region query, module lookup; image and unmapped pages refused; no garbage per read, block read, u32 write or '
    .. 'region query when interpreted')
