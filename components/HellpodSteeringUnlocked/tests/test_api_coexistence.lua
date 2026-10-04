-- Run each initialization order in a fresh LuaJIT process: FFI declarations are
-- global and cannot be reset by constructing another Lua environment.
local hellpod_source, bounce_source, order = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(order == 'hellpod-first' or order == 'bounce-first')
local ffi = require('ffi')
local runtime = assert(loadfile(hellpod_source .. '/bingus_runtime.lua'))()
local read_side = assert(loadfile(hellpod_source .. '/bingus_memory.lua'))()
local write_side = assert(loadfile(hellpod_source .. '/bingus_write.lua'))()
local create_runtime_api = assert(loadfile(hellpod_source .. '/windows_api.lua'))()
-- As the build does: each adapter gets a memory API, the read side extended by
-- the write side.
local function create_hellpod()
    return create_runtime_api(runtime, write_side.extend(read_side.new(runtime)))
end
-- Better Stratagem Bounce's adapter, called as its build calls it, by what its
-- source vendors: the split runtime (the core and a memory API), the single-file
-- runtime v1 (the runtime alone; that adapter calls runtime.memory()), or no
-- runtime (an older adapter that takes no argument). Loading a runtime declares
-- nothing, so the order below still decides which adapter declares its Windows
-- functions first.
local function vendored(name)
    local file = io.open(bounce_source .. '/' .. name, 'rb')
    if not file then return nil end
    file:close()
    return assert(loadfile(bounce_source .. '/' .. name))()
end
local function bounce_factory()
    local make = assert(loadfile(bounce_source .. '/windows_api.lua'))()
    local bounce_runtime = vendored('bingus_runtime.lua')
    if not bounce_runtime then return make end
    if type(bounce_runtime.memory) == 'function' then return function() return make(bounce_runtime) end end
    local bounce_read, bounce_write = assert(vendored('bingus_memory.lua')), assert(vendored('bingus_write.lua'))
    return function() return make(bounce_runtime, bounce_write.extend(bounce_read.new(bounce_runtime))) end
end
local create_bounce = bounce_factory()
local hellpod, bounce
if order == 'hellpod-first' then
    hellpod, bounce = create_hellpod(), create_bounce()
else
    bounce, hellpod = create_bounce(), create_hellpod()
end
local storage = ffi.new('uint8_t[2]')
local address = ffi.cast('uint8_t *', storage)
for index, api in ipairs({hellpod, bounce, create_hellpod(), create_bounce()}) do
    assert(api.writable_data(address, 2))
    assert(api.write(address + ((index - 1) % 2), string.char(index)))
    assert(not api.writable_data(api.module(nil), 1))
    assert(not api.write(api.module(nil), '\0'))
    assert(api.read(ffi.cast('uint8_t *', 1), 8) == nil)
end
assert(storage[0] == 3 and storage[1] == 4)
print('PASS: real Windows data APIs coexist in a fresh VM, ' .. order .. '; image writes still refused')
