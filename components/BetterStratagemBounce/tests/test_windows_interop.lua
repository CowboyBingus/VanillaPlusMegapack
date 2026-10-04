local source, peer_source, order = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local function exists(path)
    local file = io.open(path, 'rb')
    if file then file:close() end
    return file ~= nil
end
-- The memory api a build makes from a source's split runtime: bingus_memory.lua's
-- api, extended by bingus_write.lua.
local function split_memory(directory)
    local memory_file = assert(loadfile(directory .. '/bingus_memory.lua'))()
    local write_file = assert(loadfile(directory .. '/bingus_write.lua'))()
    return function(runtime) return write_file.extend(memory_file.new(runtime)) end
end
-- A Hellpod source's adapter gets what its own build passes: nothing (no
-- vendored runtime, the published releases), the monolithic bingus_runtime.lua
-- (adapter(runtime)), or the split runtime (adapter(runtime, memory)).
local peer_kind
local function hellpod_factory()
    local make = assert(loadfile(peer_source .. '/windows_api.lua'))()
    peer_kind = 'no shared runtime'
    if not exists(peer_source .. '/bingus_runtime.lua') then return make end
    local runtime = assert(loadfile(peer_source .. '/bingus_runtime.lua'))()
    peer_kind = 'monolithic runtime'
    if not exists(peer_source .. '/bingus_memory.lua') then return function() return make(runtime) end end
    peer_kind = 'split runtime'
    local memory = split_memory(peer_source)
    return function() return make(runtime, memory(runtime)) end
end
-- This mod's adapter takes its memory api from its own vendored runtime, as its
-- build passes it.
local function ball_factory()
    local make = assert(loadfile(source .. '/windows_api.lua'))()
    local runtime = assert(loadfile(source .. '/bingus_runtime.lua'))()
    local memory = split_memory(source)
    return function() return make(runtime, memory(runtime)) end
end
local factories = {
    ball = ball_factory(),
    hellpod = hellpod_factory(),
}
local first, second = order:match('^(%a+)%-(%a+)$')
assert(factories[first] and factories[second] and first ~= second)
local apis = {[first] = factories[first]()}
apis[second] = factories[second]()
ffi.cdef [[
    void *VirtualAlloc(void *address, size_t size, uint32_t allocation, uint32_t protection);
    int VirtualFree(void *address, size_t size, uint32_t operation);
    int VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *previous);
]]
local kernel = ffi.load('kernel32')
local allocation = kernel.VirtualAlloc(nil, 8192, 0x3000, 4)
assert(allocation ~= nil)
local data = ffi.cast('uint8_t *', allocation)
local function verify()
    for _, name in ipairs({first, second}) do
        local api = apis[name]
        assert(api.writable_data(data, 8192), name .. ' rejected writable private data')
        assert(api.write(data + 4095, '\x12\x34'))
        assert(api.read(data + 4095, 2) == '\x12\x34')
        assert(not api.write(api.module(nil), '\0'))
    end
end
verify()
-- Repeated initialization must preserve the shared Windows declarations.
apis.ball = factories.ball()
verify()
local previous = ffi.new('uint32_t[1]')
for _, protection in ipairs({2, 0x20, 0x40}) do
    assert(kernel.VirtualProtect(data + 4096, 4096, protection, previous) ~= 0)
    for _, name in ipairs({first, second}) do
        local api = apis[name]
        assert(not api.writable_data(data, 8192))
        assert(not api.write(data + 4095, '\x56\x78'))
        assert(api.read(data + 4095, 2) == '\x12\x34')
    end
end
assert(kernel.VirtualFree(data, 0, 0x8000) ~= 0)
for _, name in ipairs({first, second}) do
    assert(not apis[name].writable_data(data, 1))
    assert(not apis[name].write(data, '\0'))
end
print('PASS: real Windows adapters share one Lua VM in ' .. order .. ' order (Hellpod adapter on ' .. peer_kind .. '); repeated ball initialization and write guards survive')
if arg[4] then
    arg = {source, arg[4], assert(arg[5])}
    assert(loadfile(source .. '/../tests/test_archive.lua'))()
end
