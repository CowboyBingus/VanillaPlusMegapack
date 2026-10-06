-- Laser Sentry Cooldown: the in-game adapter's real Windows calls, on memory laid out like the game's.
-- A reserved "game image" holds the root pointer at ROOT_RVA, a reserved "root object" holds the table pointer at
-- TABLE_OFFSET, and a private block holds the live heat-table bytes (tests/heat_fixture.lua) behind a 24-byte
-- header at an address that is not 8-byte aligned, made PAGE_READONLY as the game keeps it. The instance then
-- finds the record, writes the change through VirtualProtectEx and WriteProcessMemory, and the test checks the
-- bytes, the page's protection afterwards, the refusals on image and executable pages, and that no call creates
-- C types or garbage. Modes (each in a fresh Lua state):
--   plain    nothing else declared;
--   hostile  another mod declared the real Windows names first with a wrong prototype (hostile_vm H.clash);
--   sdk      another mod declared the real names first with the Windows SDK prototypes.
-- Usage: luajit tests/test_adapter.lua <repository root> <plain|hostile|sdk>
local root, mode = assert(arg and arg[1], 'repository root required'), arg[2] or 'plain'
local ffi = require('ffi')
local H = dofile(root .. '/tests/hostile_vm.lua')
local fixture = dofile(root .. '/tests/heat_fixture.lua')
local NAMES = {'GetCurrentProcess', 'ReadProcessMemory', 'WriteProcessMemory', 'VirtualQuery', 'VirtualProtectEx'}

if mode == 'hostile' then
    local status = H.clash(NAMES)
    for _, name in ipairs(NAMES) do assert(status[name] == 'clashed', name .. ': ' .. tostring(status[name])) end
elseif mode == 'sdk' then
    -- Another mod that declared the real names first, with the Windows SDK prototypes.
    ffi.cdef([[
void *GetCurrentProcess(void); /* -- lint-ok: R1 imitates another mod's declaration */
int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *done); /* -- lint-ok: R1 imitates another mod's declaration */
int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *done); /* -- lint-ok: R1 imitates another mod's declaration */
size_t VirtualQuery(const void *address, void *information, size_t length); /* -- lint-ok: R1 imitates another mod's declaration */
int VirtualProtectEx(void *process, void *address, size_t size, uint32_t protection, uint32_t *previous); /* -- lint-ok: R1 imitates another mod's declaration */
]])
else
    assert(mode == 'plain', 'unknown mode ' .. tostring(mode))
end

local Cooldown = dofile(root .. '/src/laser_sentry_cooldown.lua')

-- Test-only Windows calls, under private names.
ffi.cdef([[
void *lsct1_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
int lsct1_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
int lsct1_VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *previous) __asm__("VirtualProtect");
void *lsct1_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
]])
local kernel = ffi.load('kernel32')
local MEM_COMMIT, MEM_RESERVE, MEM_RELEASE, MEM_PRIVATE, MEM_IMAGE = 0x1000, 0x2000, 0x8000, 0x20000, 0x1000000
local PAGE_READONLY, PAGE_READWRITE, PAGE_EXECUTE_READ = 0x02, 0x04, 0x20
local PAGE = 4096

local function number(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end
local function hex(text) return (text:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)) end
local function le64(value)
    local low, high = value % 4294967296, math.floor(value / 4294967296)
    local out = {}
    for _, word in ipairs({low, high}) do
        for _ = 1, 4 do out[#out + 1] = string.char(word % 256); word = math.floor(word / 256) end
    end
    return table.concat(out)
end
local function poke(address, bytes) ffi.copy(ffi.cast('uint8_t *', address), bytes, #bytes) end
local function fixture_word(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function peek(address, size) return ffi.string(ffi.cast('uint8_t *', address), size) end
local function protect(address, size, protection)
    local previous = ffi.new('uint32_t[1]')
    assert(kernel.lsct1_VirtualProtect(ffi.cast('void *', address), size, protection, previous) ~= 0, 'VirtualProtect')
    return previous[0]
end

-- Reserves size bytes and commits the page holding offset: returns the base and the committed address.
local allocations = {}
local function reserve_with(size, offset)
    local base = kernel.lsct1_VirtualAlloc(nil, size, MEM_RESERVE, PAGE_READWRITE)
    assert(base ~= nil, 'reserve')
    allocations[#allocations + 1] = base
    local at = number(base) + offset
    local page = at - at % PAGE
    assert(kernel.lsct1_VirtualAlloc(ffi.cast('void *', page), PAGE * 2, MEM_COMMIT, PAGE_READWRITE) ~= nil, 'commit')
    return number(base), at
end

local game, root_slot = reserve_with(Cooldown.ROOT_RVA + 2 * PAGE, Cooldown.ROOT_RVA)
local root_object, table_slot = reserve_with(Cooldown.TABLE_OFFSET + 2 * PAGE, Cooldown.TABLE_OFFSET)
local header, slots, record = hex(fixture.header), hex(fixture.slots), hex(fixture.record)
local block_size = 24 + Cooldown.RECORDS_OFFSET + Cooldown.RECORD_SIZE * 30
local block = kernel.lsct1_VirtualAlloc(nil, block_size + 2 * PAGE, MEM_COMMIT + MEM_RESERVE, PAGE_READWRITE)
assert(block ~= nil, 'block')
allocations[#allocations + 1] = block
local heat = number(block) + 0x57C -- not 8-byte aligned, like the live table
poke(heat - 24, header)
poke(heat, slots)
local record_address = heat + Cooldown.RECORDS_OFFSET + Cooldown.RECORD_SIZE * fixture.index
poke(record_address, record)
poke(root_slot, le64(root_object))
poke(table_slot, le64(heat))
protect(number(block), block_size + 2 * PAGE, PAGE_READONLY)

local api = Cooldown.adapter()
assert(api.u64(root_slot) == root_object and api.u64(table_slot) == heat, 'u64 reads')
assert(api.read(record_address, Cooldown.RECORD_SIZE) == record, 'read')
assert(api.read(0x10, 8) == nil and api.u64(0x10) == nil, 'unreadable memory reads as nil')
-- view: one read into the reused buffer, decoded in place (the turret watch's reads).
assert(api.view(record_address, 24) and api.bytes[0] == record:byte(1) and api.words[1] == fixture_word(record, 4),
       'view reads into api.bytes / api.words')
assert(api.view(0x10, 8) == false and api.view(record_address, 0) == false and api.view(record_address, 4096) == false,
       'view refuses unreadable memory and sizes outside 1..2048')
local state, protection, kind, base, size = api.page(record_address)
assert(state == MEM_COMMIT and protection == PAGE_READONLY and kind == MEM_PRIVATE, 'page attributes')
-- VirtualQuery describes the region from the queried page onward (the live game reports the same).
assert(base == record_address - record_address % PAGE and base + size >= number(block) + block_size, 'page region')

-- The instance on real memory: one try finds the record and writes the change.
local lines = {}
local instance = Cooldown.new(api, game, function(line) lines[#lines + 1] = line end)
assert(instance.try() and instance.patched, 'patched: ' .. table.concat(lines, ' | '))
local cooling = record_address + Cooldown.COOLING_OFFSET
local ability = record_address + Cooldown.ABILITY_OFFSET
local patched = record:sub(Cooldown.IDLE_COOLING_OFFSET + 1, Cooldown.IDLE_COOLING_OFFSET + 4) .. '\0'
assert(patched == '\0\0\160\64\0' and peek(cooling, 5) == patched, 'cooling written: the idle cooling rate, then 0')
assert(peek(ability, 4) == '\0\0\0\0', 'overheat ability written: none')
-- Every other byte of the record is as it was: before, between and after the two ranges.
local function untouched(from, to) return peek(record_address + from, to - from) == record:sub(from + 1, to) end
assert(untouched(0, Cooldown.COOLING_OFFSET), 'bytes before untouched')
assert(untouched(Cooldown.COOLING_OFFSET + 5, Cooldown.ABILITY_OFFSET), 'bytes between untouched')
assert(untouched(Cooldown.ABILITY_OFFSET + 4, Cooldown.RECORD_SIZE), 'bytes after untouched')
assert(select(2, api.page(record_address)) == PAGE_READONLY, 'read-only again after the write')
instance.restore()
assert(peek(cooling, 5) == Cooldown.COOLING_VANILLA and peek(ability, 4) == Cooldown.ABILITY_VANILLA
       and peek(record_address, Cooldown.RECORD_SIZE) == record, 'restored')
assert(select(2, api.page(record_address)) == PAGE_READONLY, 'read-only again after the restore')

-- Refusals on real pages: an image page (this process's kernel32) and an executable private page.
local image = number(kernel.lsct1_GetModuleHandleA('kernel32.dll'))
local ok, why = Cooldown.protected_write(api, image, {{0x40, '\0'}})
assert(not ok and why:find('not committed private memory', 1, true), 'image page refused: ' .. tostring(why))
local code = kernel.lsct1_VirtualAlloc(nil, PAGE, MEM_COMMIT + MEM_RESERVE, PAGE_EXECUTE_READ)
allocations[#allocations + 1] = code
ok, why = Cooldown.protected_write(api, number(code), {{0, '\0'}})
assert(not ok and why == 'unexpected page protection 0x20', 'executable page refused: ' .. tostring(why))
assert(select(2, api.page(number(code))) == PAGE_EXECUTE_READ, 'executable page untouched')

-- No call creates C types once warm, and the per-frame ones allocate nothing.
local function calls()
    api.u64(root_slot); api.view(record_address, 96); api.page(record_address)
    api.protect(record_address, 5, PAGE_READONLY)
end
calls()
local types = H.ctype_growth(function() for _ = 1, 50 do calls() end end)
assert(types == 0, types .. ' C types created by adapter calls')
local function polls(count)
    for _ = 1, count do api.u64(root_slot); api.u64(table_slot); api.view(record_address, 96) end
end
polls(1000); polls(1000)
local kb = H.heap_peak(polls, 1000)
assert(kb == 0, string.format('pointer reads and views allocated %.3f KB', kb))

for _, allocation in ipairs(allocations) do kernel.lsct1_VirtualFree(allocation, 0, MEM_RELEASE) end
print(string.format('PASS: test_adapter.lua %s (%s)', mode, jit and jit.version or _VERSION))
