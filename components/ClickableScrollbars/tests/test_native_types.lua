-- Native calls must not create C types per call. The C type table is shared by
-- every mod in the game and never frees an entry (65536 in all); v2.14 cast type
-- strings on every native call and could fill it after minutes of dragging, after
-- which every mod's FFI type creation fails. This test runs the real native layer
-- against stub functions (a single `ret`) placed at the game RVAs inside one
-- executable allocation, then counts the C types created across thousands of calls.

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local ffi = require('ffi')
local module = assert(loadfile(arg[2]))()

ffi.cdef [[
    void *hd2cs_test_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect) __asm__("VirtualAlloc");
    int hd2cs_test_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail and (' (' .. tostring(detail) .. ')') or ''), 0) end
    passed = passed + 1
end

-- Game RVAs the native layer calls: grid solver, scroll setter, position setter,
-- animation stop, input consume. One allocation spans them all; each gets `ret`.
local RVAS = {0x18d2b60, 0x1794530, 0x14476a0, 0x1439d40, 0x12fde90}
local SIZE = 0x18d2b60 + 0x1000
local base = kernel.hd2cs_test_VirtualAlloc(nil, SIZE, 0x3000, 0x40)
check('executable stub area allocated', base ~= nil)
local code = ffi.cast('uint8_t *', base)
for _, rva in ipairs(RVAS) do code[rva] = 0xC3 end

local function game() return ffi.cast('uint8_t *', base) end  -- a new pointer object each time, like api.module
local grid_block = ffi.new('uint8_t[?]', 700000)
grid_block[600322] = 1  -- an animation is running, so calls.stop reaches the native stop
local grid = ffi.cast('uint8_t *', grid_block)
local panel_block, bar_block, input_block = ffi.new('uint8_t[8192]'), ffi.new('uint8_t[1024]'), ffi.new('uint8_t[64]')
local writes = 0
local memory = {write_f32 = function() writes = writes + 1; return true end}
local input_bytes = ffi.string(ffi.new('uint64_t[1]', ffi.cast('uintptr_t', input_block)), 8)
local api = {
    read = function() return input_bytes end,
    pointer = function(bytes) local v = ffi.new('uint64_t[1]'); ffi.copy(v, bytes, 8); return ffi.cast('uint8_t *', v[0]) end,
}
local model = {span = 1000, value = 0.1, list_x = 12}

local grid_bridge = {memory = memory, game = game(), grid = grid}
local settings_bridge = {memory = memory, game = game(), grid = grid, bar = ffi.cast('uint8_t *', bar_block),
                         route = 'settings', api = api}
local career_bridge = {memory = memory, game = game(), panel = ffi.cast('uint8_t *', panel_block), route = 'career'}

check('calls are cached per module address', module.native_calls(grid_bridge) == module.native_calls({game = game()}))

local function next_type_id() return tonumber(ffi.typeof('struct { int hd2cs_probe; }')) end

-- Probe sanity: a function-pointer type string does create new types.
local a = next_type_id()
ffi.cast('void (*)(void *, float)', game())
check('the probe sees type creation', next_type_id() - a > 2, next_type_id() - a)

local function frame(i)
    check('grid route call', module.native_apply(grid_bridge, model, (i % 100) / 100) ~= nil)
    check('career route call', module.native_apply(career_bridge, model, 0.5) ~= nil)
    check('settings route call', module.native_apply(settings_bridge, model, 0.25) ~= nil)
    check('settings input consume', module.native_settings_input(settings_bridge) == true)
end

frame(0)  -- first use declares the named types and casts once
local before = next_type_id()
for i = 1, 5000 do frame(i) end
local created = next_type_id() - before - 2  -- the probe itself takes two ids
check('no C type created across 20000 native calls', created == 0, created)
check('the grid route wrote its scroll offset every time', writes == 5001, writes)

-- Each new bridge for the same module reuses the cached calls: still no growth.
before = next_type_id()
for _ = 1, 1000 do module.native_apply({memory = memory, game = game(), grid = grid}, model, 0.3) end
created = next_type_id() - before - 2
check('new bridges for the same module create no types', created == 0, created)

kernel.hd2cs_test_VirtualFree(base, 0, 0x8000)
print('test_native_types.lua: ' .. passed .. ' passed (' .. (jit and jit.version or _VERSION) .. ')')
