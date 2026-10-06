-- Laser Sentry Cooldown: the live test build's hooks (src/test_hooks.lua) on the simulated game. The sampler's log
-- of a Laser Sentry that heats up, overheats, cools down and fires again (a RESULT line), overheats again and is
-- removed while overheated (a RESULT line), beside another heat weapon it must ignore; and the record check.
-- The hooks register no option and change nothing.
-- Usage: luajit tests/test_hooks.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_hooks.lua <repository root>')
local ffi = require('ffi')
local G = dofile(root .. '/tests/fake_game.lua')(root)
local Cooldown = G.Cooldown
local hooks = dofile(root .. '/src/test_hooks.lua')
local le32, le64 = G.le32, G.le64
local cell = ffi.new('float[1]')
local function f32(value) cell[0] = value; return ffi.string(cell, 4) end

local MANAGER_RVA = 0x3326D48
local MANAGER, ENTITIES, REPLICATED, RECORDS = 0x40000000000, 0x40000001000, 0x40000002000, 0x40000003000
local SENTRY_ID, OTHER_ID = 0x1234, 0x777

local s = G.session()
assert(s.instance.patched, 'the change is in place')
local memory = s.memory
memory.map(MANAGER, 0x10000, G.PAGE_READWRITE, G.MEM_PRIVATE)
memory.poke(G.GAME + MANAGER_RVA, le64(MANAGER))

-- Entity records: resource (lo, hi), id, two words, flags (bit 0: owned here).
local function entity(address, low, high, id, owned)
    memory.poke(address, le32(low) .. le32(high) .. le32(id) .. le32(0) .. le32(0) .. le32(owned and 1 or 0))
end
entity(RECORDS, Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH, SENTRY_ID, true)
entity(RECORDS + 64, 0x11111111, 0x22222222, OTHER_ID, true)
local function instances(count)
    local header = string.rep('\0', 20) .. le32(count) .. le32(count) .. le32(count) .. string.rep('\0', 32)
        .. le64(ENTITIES) .. string.rep('\0', 16) .. le64(REPLICATED)
    memory.poke(MANAGER, header .. string.rep('\0', 96 - #header))
end
memory.poke(ENTITIES, le64(RECORDS) .. le64(RECORDS + 64))
local function heat(index, temperature, overheated, firing, magazines)
    memory.poke(REPLICATED + 12 * index, le32(magazines or 0) .. f32(temperature) .. string.char(overheated, firing)
        .. '\0\0')
end
instances(2)
heat(0, 0, 0, 0)
heat(1, 999, 1, 1, 6) -- the other heat weapon: overheated, never logged

local saved_print = print
print = G.quiet
hooks(Cooldown, s.instance, s.runtime, s.fake_memory)
print = saved_print
assert(s.logged('test hooks installed'), 'installed')
assert(rawget(_G, 'ModOptionsMenu') == nil, 'no menu needed')

local function frames(count) for _ = 1, count do s.frame() end end
frames(6)
assert(s.logged('heat instances total/active/owned 2/2/2'), 'counts logged')
assert(s.logged(string.format('sentry %d appeared at index 0 (owned 1, heat sinks 0)', SENTRY_ID)), 'appeared')
assert(not s.logged(string.format('sentry %d', OTHER_ID)), 'the other heat weapon is ignored')
heat(0, 120, 0, 1)
frames(6)
assert(s.logged('temperature 120.0, overheated 0, firing 1'), 'heating logged')
heat(0, 124, 0, 1)
frames(6)
assert(not s.logged('temperature 124.0'), 'no line within the same 25-heat band')
heat(0, 250, 1, 0)
frames(6)
assert(s.logged('temperature 250.0, overheated 1, firing 0, heat sinks 0, turret state ?, 0.00 s after overheat'),
       'overheat (no behavior manager in this world: turret state ?)')
heat(0, 100, 1, 0)
frames(6)
assert(s.logged('temperature 100.0, overheated 1, firing 0, heat sinks 0, turret state ?, 0.10 s after overheat'),
       'cooling')
heat(0, 0, 0, 0)
frames(6)
assert(s.logged(string.format('RESULT sentry %d recovered: overheated for 0.2 s, temperature now 0.0', SENTRY_ID)),
       'recovery result')
heat(0, 250, 1, 0)
frames(6)
memory.poke(ENTITIES, le64(RECORDS + 64))
instances(1)
heat(0, 999, 1, 1, 6)
frames(6)
assert(s.logged(string.format('RESULT sentry %d disappeared while overheated, 0.10 s after the overheat', SENTRY_ID)),
       'lost-while-overheated result')
assert(s.logged(string.format('sentry %d disappeared 0.10 s after its last overheat', SENTRY_ID)), 'disappeared')
assert(s.logged('heat instances total/active/owned 1/1/1'), 'new counts')

-- The record check: both ranges in place, then something else puts the vanilla overheat ability back.
frames(300)
assert(s.logged('record check: changed bytes in place'), 'record check ok')
memory.poke(G.ABILITY, Cooldown.ABILITY_VANILLA)
frames(300)
assert(s.logged('record check: UNEXPECTED bytes 0000a04000320b0000 (expected 0000a0400000000000)'),
       'reverted overheat ability reported')

rawset(_G, 'CowboyBingusModLoader', nil)
print(string.format('PASS: test_hooks.lua (%s)', jit and jit.version or _VERSION))
