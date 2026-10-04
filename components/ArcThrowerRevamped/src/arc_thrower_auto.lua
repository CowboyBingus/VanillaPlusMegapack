-- HD2-Addon: mods/cowboybingus/arc_thrower_auto

-- ARC-3 Arc Thrower: hold the fire button and the weapon keeps firing.
-- Vanilla fires once per press and release; this addon lets the engine's own
-- charge -> fire cycle repeat while the button stays down. Nothing else is
-- changed: charge times, cadence, damage and arc settings stay stock.

-- Re-entry guard: deploying the standalone addon and a pack that bundles it
-- together must not install the assist twice.
if rawget(_G, 'ArcThrowerRevampedInstalled') then return end
rawset(_G, 'ArcThrowerRevampedInstalled', true)

local module = {revision = 'v1.7'}

local ffi = require('ffi')
local bit = require('bit')


-- Resolved on first use, so the addon loads inert in any environment
-- and a failed binding only leaves the assist idle.
local kernel

-- Build 25480438 anchors. The charge manager holds one 40-byte entry per
-- weapon; entry + 4 is the charge, + 8 its full-charge time, + 12 the flag the
-- engine's charge updater advances while set.
local CHARGE_MANAGER = 0x3326c20
local TRIGGER_MANAGER = 0x3326660
local FIRE_MODE_SETTER = 0x755f90
local FIRE_MODE_SIGNATURE = '\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
local ARC_FINGERPRINT = '\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41'
local ARC_RESOURCE = '\xe6\x06\x73\x0f\xd5\x9c\xde\x96'
local AUTO_FIRE_FLAG = 184
local ENTRY_SIZE = 40
local POINTER_SIZE = 8
local RECOVERY_WINDOW = 0.25
local TRIGGER_BATCH, TRIGGER_LIMIT = 64, 4096
local MEM_COMMIT, MEM_PRIVATE, PAGE_READONLY, PAGE_READWRITE = 0x1000, 0x20000, 0x02, 0x04
-- Every CHECK_FRAMES updates (0.25 s at 60 FPS) a check frame revalidates the
-- charge record and runs the full Fire check, which also keeps the gate's
-- slot current after a respawn.
local CHECK_FRAMES = 15

local state = {armed = false, patched = false, record = nil, scans = 0,
               checked = false, supported = false, resolved = nil,
               previous = nil, shots = {}, last_shot = nil, status = nil,
               status_charge = nil, reason = nil, reason_log = nil,
               reason_time = nil, drove_since = nil, drove_peak = 0, rescans = 0,
               frames = CHECK_FRAMES - 1} -- the first ready frame is a check frame

-- Record flags this addon set, by address: the byte it found there. Put back
-- when the addon pauses, stops or the game shuts down.
local owned = {}

-- The performance counter lands in two 32-bit halves: reading a 64-bit
-- integer from Lua boxes a new cdata on every call.
local performance_counter = ffi.new('uint32_t[2]')
local performance_frequency = 0 -- counts per second, read once when binding

-- Every Windows function has a private name (an __asm__ label naming the real
-- export) and the region record a private type name: ffi.cdef keeps the first
-- declaration of a name for the whole game, so another mod's prototypes of the
-- real names, or its layout of MEMORY_BASIC_INFORMATION, can no longer change
-- the calls this addon makes. The integer types are LuaJIT's built-in ones.
-- Addresses are plain numbers (uint64_t: the same register as a pointer on
-- x64) and the byte counts and 64-bit results the calls write land in two
-- 32-bit words, so a call creates no pointer or 64-bit cdata.
local DECLARATIONS = [[
typedef struct atr1_region {
    void *base; void *allocation_base; uint32_t allocation_protection;
    uint16_t partition; uint16_t reserved; size_t size;
    uint32_t state; uint32_t protection; uint32_t type; uint32_t reserved2;
} atr1_region;
void *atr1_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
void *atr1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
int atr1_ReadProcessMemory(void *process, uint64_t address, void *buffer, size_t size,
                           uint32_t *done) __asm__("ReadProcessMemory");
int atr1_WriteProcessMemory(void *process, uint64_t address, const void *buffer, size_t size,
                            uint32_t *done) __asm__("WriteProcessMemory");
int atr1_VirtualProtectEx(void *process, uint64_t address, size_t size, uint32_t protect,
                          uint32_t *previous) __asm__("VirtualProtectEx");
size_t atr1_VirtualQueryEx(void *process, uint64_t address, atr1_region *region,
                           size_t length) __asm__("VirtualQueryEx");
uint64_t atr1_GetTickCount64(void) __asm__("GetTickCount64");
int atr1_QueryPerformanceCounter(uint32_t *count) __asm__("QueryPerformanceCounter");
int atr1_QueryPerformanceFrequency(uint32_t *frequency) __asm__("QueryPerformanceFrequency");
]]

local function bind()
    if state.bound then return true end
    if state.bind_error then return false end
    local ok, problem = pcall(function()
        -- Declared once per process, on first use rather than at load:
        -- parsing the declarations again would add C types every time.
        if not pcall(ffi.typeof, 'atr1_region') then ffi.cdef(DECLARATIONS) end
        kernel = ffi.load('kernel32')
        local game = kernel.atr1_GetModuleHandleA('game.dll')
        if game == nil then error('game.dll not loaded') end
        state.game = tonumber(ffi.cast('uint64_t', game))
        state.process = kernel.atr1_GetCurrentProcess()
        state.page = ffi.new('atr1_region') -- reused by every protection query before a write
        local frequency = ffi.new('uint32_t[2]')
        kernel.atr1_QueryPerformanceFrequency(frequency)
        performance_frequency = frequency[0] + frequency[1] * 4294967296
    end)
    if not ok then
        state.bind_error = tostring(problem)
        return false
    end
    state.bound = true
    return true
end

local function seconds()
    if not state.bound then return 0 end
    kernel.atr1_QueryPerformanceCounter(performance_counter)
    return (performance_counter[0] + performance_counter[1] * 4294967296) / performance_frequency
end

local loader = rawget(_G, 'CowboyBingusModLoader')
local log = nil
if loader and type(loader.open_log) == 'function' then
    log = loader.open_log('ArcThrowerAuto.log')
end

local function note(message)
    if log then log:write(message .. '\n'); log:flush() end
end

local function log_line(message)
    if not rawget(_G, 'ArcThrowerDiagnostics') then return end
    if not kernel then return note(message) end
    note(string.format('[%8.3f] %s', tonumber(kernel.atr1_GetTickCount64()) / 1000 % 100000,
                       message))
end

-- Reads land in reused buffers: read_into and pointer allocate nothing, read
-- only the string it returns.
local done = ffi.new('uint32_t[2]') -- the byte count a read or write reports
local scratch, scratch_size = nil, 0
local pointer_words = ffi.new('uint32_t[2]')

local function read_into(address, size, buffer)
    return kernel.atr1_ReadProcessMemory(state.process, address, buffer, size, done) ~= 0
        and done[0] == size and done[1] == 0
end

local function read(address, size)
    if not state.bound then return nil end
    if size > scratch_size then
        scratch_size = math.max(size, scratch_size * 2, 256)
        scratch = ffi.new('uint8_t[?]', scratch_size)
    end
    if not read_into(address, size, scratch) then return nil end
    return ffi.string(scratch, size)
end

local function write(address, data)
    if not state.bound then return false end
    return kernel.atr1_WriteProcessMemory(state.process, address, data, #data, done) ~= 0
        and done[0] == #data and done[1] == 0
end

-- The protection of the page holding address when that page is committed
-- private memory, else nil. One VirtualQueryEx (about 0.29 ms in game), made
-- only right before a write. The answer stays in state.page for the log
-- (state.page_known is false when the query itself failed).
local function private_protection(address)
    local page = state.page
    state.page_known = kernel.atr1_VirtualQueryEx(state.process, address, page, ffi.sizeof(page)) ~= 0
    if not state.page_known then return nil end
    if page.state ~= MEM_COMMIT or page.type ~= MEM_PRIVATE then return nil end
    return page.protection
end

-- The last queried page as a refusal logs it: why the write was refused.
local function page_text()
    if not state.page_known then return 'protection query failed' end
    local page = state.page
    return string.format('state %#x, protection %#x, type %#x', page.state, page.protection, page.type)
end

-- Writes bytes of the weapon data library: committed private memory the game
-- keeps read-only (WriteProcessMemory alone fails there). The page is checked
-- right before the write, made writable for the write only and given its
-- original protection back right after; every call is checked. A page that is
-- already private read-write is written directly. Returns true, or false and
-- why; state.protection_lost holds the address when the original protection
-- could not be restored.
local previous_protection, restored_protection = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
local function write_data(address, data)
    if not state.bound then return false, 'bindings unavailable' end
    local protection = private_protection(address)
    if protection == PAGE_READWRITE then
        if write(address, data) then return true end
        return false, 'record write failed'
    end
    if protection ~= PAGE_READONLY then
        return false, 'record page is not private read-only memory (' .. page_text() .. ')'
    end
    if kernel.atr1_VirtualProtectEx(state.process, address, #data, PAGE_READWRITE,
                                    previous_protection) == 0 then
        return false, 'record page protection could not be changed'
    end
    local ok = write(address, data)
    if kernel.atr1_VirtualProtectEx(state.process, address, #data, previous_protection[0],
                                    restored_protection) == 0 then
        if not state.protection_lost then
            note(string.format('Weapon data page at %#x could not be made read-only again.', address))
        end
        state.protection_lost = address
        return false, 'record page protection could not be restored'
    end
    if ok then return true end
    return false, 'record write failed'
end

-- Little-endian fields decoded in place from a read's string, without a cdata
-- or substring per field. A float decodes exactly (every float is a double).
local function u32(blob, offset)
    local a, b, c, d = blob:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function u64(blob, offset)
    return u32(blob, offset) + u32(blob, offset + 4) * 4294967296
end
local function f32(blob, offset)
    local a, b, c, d = blob:byte(offset + 1, offset + 4)
    local sign = d >= 128 and -1 or 1
    local exponent = d % 128 * 2 + math.floor(c / 128)
    local mantissa = c % 128 * 65536 + b * 256 + a
    if exponent == 255 then return mantissa == 0 and sign / 0 or 0 / 0 end
    if exponent == 0 then return sign * math.ldexp(mantissa, -149) end
    return sign * math.ldexp(mantissa + 8388608, exponent - 150)
end

local function pointer(address)
    if not state.bound or not read_into(address, POINTER_SIZE, pointer_words) then return nil end
    return pointer_words[0] + pointer_words[1] * 4294967296
end

-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles: b times each 16-bit
-- half of a stays below 2^48.
local function mul32(a, b)
    local high, low = math.floor(a / 65536), a % 65536
    return (high * b % 65536 * 65536 + low * b) % 4294967296
end

-- A float from its 32 bits, as f32 decodes it from bytes. The idle gate and
-- the per-frame checks read uint32 words, never a float cdata: in this
-- NaN-tagged LuaJIT a NaN loaded through a float cdata may not be a number.
local function float_bits(bits)
    local sign = bits >= 2147483648 and -1 or 1
    local exponent = bit.band(bit.rshift(bits, 23), 0xff)
    local mantissa = bit.band(bits, 0x7fffff)
    if exponent == 255 then return mantissa == 0 and sign / 0 or 0 / 0 end
    if exponent == 0 then return sign * math.ldexp(mantissa, -149) end
    return sign * math.ldexp(mantissa + 8388608, exponent - 150)
end

-- Per-frame reads land in these words, kept for the session, and are decoded
-- in place: no string per read. A 24-byte entity record is six words; two
-- records are the same entity when all six match.
local function words(count) return ffi.new('uint32_t[?]', count) end
local LOOKUP_HEADER, LOOKUP_ROW = words(5), words(2)
local PLAYER_COUNTS, PLAYER_UNIT, PLAYER_RECORD, AVATAR_COUNT = words(2), words(1), words(6), words(1)
local AVATAR, KEPT_AVATAR, ENTITY_RECORD, CANDIDATE = words(6), words(6), words(6), words(6)
local FIRE_INPUT, HOLDER, CHARGE_HEADER, CHARGE_ENTRY = words(8), words(1), words(14), words(10)
local function same_record(a, b)
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4] and a[5] == b[5]
end
-- A record copy a binding keeps (made when it arms, not per frame).
local function copy_record(record)
    local copy = words(6)
    ffi.copy(copy, record, 24)
    return copy
end
-- An entity record's owned bit: byte 20, the low byte of word 5.
local function owned_bit(record) return bit.band(record[5], 1) == 1 end

-- Resolve the local avatar through both registries, including its generation.
-- Slot 9 is the native Fire action (pair 2,9), after input rebinding/controller
-- processing; +8 is held time. Aim is slot 8 and must not drive this assist.
-- The row index of key in the lookup whose 20-byte header is at address, or nil.
local function lookup(address, key, limit)
        if not read_into(address, 20, LOOKUP_HEADER) then return nil end
        local data=LOOKUP_HEADER[0]+LOOKUP_HEADER[1]*4294967296
        local cap,empty,mult=LOOKUP_HEADER[2],LOOKUP_HEADER[3],LOOKUP_HEADER[4]
        if data==0 or cap==0 or cap>limit or bit.band(cap,cap-1)~=0 then return nil end
        local product=mul32(key,mult)
        for probe=0,math.min(cap,64)-1 do
            if not read_into(data+8*bit.band(product+probe,cap-1),8,LOOKUP_ROW) then return nil end
            if LOOKUP_ROW[0]==key then local index=LOOKUP_ROW[1];if index~=0xffffffff then return index end;return nil end
            if LOOKUP_ROW[0]==empty then return nil end
        end
end
local AVATAR_TYPE='\x97\xfa\x4d\x29\x4d\x33\x1c\x4d'
local AVATAR_TYPE_LOW, AVATAR_TYPE_HIGH = u32(AVATAR_TYPE, 0), u32(AVATAR_TYPE, 4)
-- The local player's avatar record (24 bytes, in AVATAR) and the avatar
-- manager, or nil.
local function local_avatar()
    local pm,owner,am=pointer(state.game+0x3326468),pointer(state.game+0x346bf98),pointer(state.game+0x3326d20)
    if not pm or pm==0 or not owner or owner==0 or not am or am==0 then return nil end
    local counts,unit=read_into(pm+0x84,8,PLAYER_COUNTS),read_into(pm+0x3a8,4,PLAYER_UNIT)
    if not counts or not unit or PLAYER_COUNTS[0]<1 or PLAYER_COUNTS[0]>4
        or PLAYER_COUNTS[1]<1 or PLAYER_COUNTS[1]>4 or PLAYER_UNIT[0]==0x7fff then return nil end
    local player=pointer(pm+0xe8)
    if not player or player==0 or not read_into(player,24,PLAYER_RECORD) or not owned_bit(PLAYER_RECORD) then
        return nil
    end
    local ei=lookup(owner+0xf22ec8,PLAYER_UNIT[0],1048576)
    if not ei or ei>=262144 then return nil end
    if not read_into(owner+0xf32f18+ei*24,24,AVATAR) or AVATAR[0]~=AVATAR_TYPE_LOW or AVATAR[1]~=AVATAR_TYPE_HIGH
        or not owned_bit(AVATAR) then return nil end
    return AVATAR,am
end
-- The address of that avatar's native Fire slot in the avatar manager, its
-- index and entity there, or nil.
local function fire_slot(am,avatar)
    local ai=lookup(am+0xf8,avatar[2],64)
    local count=read_into(am+0x6c,4,AVATAR_COUNT)
    if not ai or not count or AVATAR_COUNT[0]>8 or ai>=AVATAR_COUNT[0] then return nil end
    local entity=pointer(am+0x110+ai*8)
    if not entity or entity==0 or not read_into(entity,24,ENTITY_RECORD) or not same_record(ENTITY_RECORD,avatar) then
        return nil
    end
    return am+0x150+ai*0xa7aec+0x1b68+9*32,ai,entity
end

-- The last full resolution of the local Fire slot: the avatar manager, the
-- avatar's index and entity there, its record (KEPT_AVATAR) and the slot.
-- Kept while those still hold, so a held Fire does not walk both registries
-- on every frame.
local kept = {am = nil, ai = nil, entity = nil, slot = nil}
local function forget_slot() kept.slot = nil end

-- The full resolution from the registry roots (16 reads with the input);
-- keeps what it found.
local function resolve_slot()
    kept.slot = nil
    local avatar,am=local_avatar()
    if not avatar then return nil end
    local slot,ai,entity=fire_slot(am,avatar)
    if not slot then return nil end
    ffi.copy(KEPT_AVATAR,avatar,24)
    kept.am,kept.ai,kept.entity,kept.slot=am,ai,entity,slot
    return slot
end

-- The kept slot while the avatar manager global, the entity at the kept
-- index and its 24-byte record are unchanged (3 reads), else nil. A respawn,
-- a new mission or another avatar at that index changes one of them. What
-- this skips (player counts, the player's unit and the owner registry) is
-- read again on every check frame.
local function kept_slot()
    if not kept.slot then return nil end
    if pointer(state.game+0x3326d20)~=kept.am then return nil end
    local entity=pointer(kept.am+0x110+kept.ai*8)
    if entity~=kept.entity or not read_into(entity,24,ENTITY_RECORD) or not same_record(ENTITY_RECORD,KEPT_AVATAR) then
        return nil
    end
    return kept.slot
end

-- The Fire check: whether the local avatar's Fire is held, the avatar
-- record, the held time and the slot address (kept for the idle gate). A
-- check frame always resolves from the registry roots; other frames use the
-- kept slot and resolve again on any mismatch.
local function local_fire(check)
    local slot=not check and kept_slot() or resolve_slot()
    if not slot then return nil end
    if not read_into(slot,32,FIRE_INPUT) then forget_slot();return nil end
    local held=float_bits(FIRE_INPUT[2])
    if held~=held or held<0 or held>=86400 then forget_slot();return nil end
    return held>0,KEPT_AVATAR,held,slot
end

-- The idle gate: one 4-byte read of the Fire slot kept from the last full
-- check answers "could the assist act now?". Zero (either sign) means Fire is
-- up there; an unreadable slot or any other value sends this frame to the
-- full check, which decides and keeps the slot again. Without a kept slot (no
-- local avatar at the last full check) nothing is read until the next check
-- frame. The held time is tested as its bits: no float load.
local held_bits = ffi.new('uint32_t[1]')
local function fire_may_be_held()
    local slot = state.fire_slot
    if not slot then return false end
    if not read_into(slot + 8, 4, held_bits) then return true end
    return bit.band(held_bits[0], 0x7fffffff) ~= 0
end

-- The last weapon-holder row that showed the local avatar holding a weapon:
-- the manager, its rows and the row index, for that weapon and avatar id.
local holder = {manager = nil, rows = nil, index = nil, weapon = nil, avatar = nil}

-- Whether the weapon with this id is held by the avatar with this id; nil when
-- unknown. With cached (a held Fire between check frames) a kept row for the
-- same weapon and avatar is verified instead: the manager global, its rows
-- pointer and that row's holder (3 reads instead of 5). The rows pointer is
-- read too so a reallocated array is never read through its old address. Any
-- mismatch, and every check frame, runs the full lookup.
local function local_weapon(weapon, avatar, cached)
    local manager=pointer(state.game+0x3326dc0)
    if not manager or manager==0 then return nil end
    if cached and holder.index and holder.manager==manager and holder.weapon==weapon and holder.avatar==avatar
        and pointer(manager+64)==holder.rows and read_into(holder.rows+holder.index*48+4,4,HOLDER)
        and HOLDER[0]==avatar then
        return true
    end
    holder.index=nil
    local index=lookup(manager+32,weapon,8192)
    if not index or index>=4096 then return nil end
    local rows=pointer(manager+64)
    if not rows or rows==0 or not read_into(rows+index*48+4,4,HOLDER) then return nil end
    if HOLDER[0]~=avatar then return false end
    holder.manager,holder.rows,holder.index,holder.weapon,holder.avatar=manager,rows,index,weapon,avatar
    return true
end

-- Entry arrays can move or compact while fire stays held. Check the slot every
-- update; only search the bounded pointer array when its binding changed.
local function charge_entry(chosen)
    local manager=pointer(state.game+CHARGE_MANAGER)
    if not manager or manager==0 then return nil end
    if not read_into(manager+16,56,CHARGE_HEADER) then return nil end
    local count=CHARGE_HEADER[0]
    local entities=CHARGE_HEADER[10]+CHARGE_HEADER[11]*4294967296
    local entries=CHARGE_HEADER[12]+CHARGE_HEADER[13]*4294967296
    if count<1 or count>512 or entities==0 or entries==0 then return nil end
    if chosen.index and chosen.index<count and pointer(entities+chosen.index*8)==chosen.entity then
        return entries+chosen.index*ENTRY_SIZE
    end
    local pointers=read(entities,count*8)
    if not pointers then return nil end
    for index=0,count-1 do
        if u64(pointers,index*8)==chosen.entity then
            chosen.index=index
            return entries+index*ENTRY_SIZE
        end
    end
    return false -- readable table confirms this weapon is no longer charged
end

local function supported_build()
    if state.checked then return state.supported end
    state.checked = true
    local game = kernel.atr1_GetModuleHandleA('game.dll')
    if game == nil then return false end
    local base = tonumber(ffi.cast('uint64_t', game))
    state.supported = read(base + FIRE_MODE_SETTER, #FIRE_MODE_SIGNATURE)
        == FIRE_MODE_SIGNATURE
    return state.supported
end

-- The weapon data library is one large read-only private allocation. The arc
-- thrower's charge record is located by its animation-variable fingerprint;
-- auto_fire_in_safety tells the engine it may complete the shot itself.
local function valid_charge_record(charge)
    return charge and charge:sub(169,184)==ARC_FINGERPRINT
        and math.abs(f32(charge,0)-1.0)<1e-3
        and math.abs(f32(charge,24)-1.1)<1e-3
        and math.abs(f32(charge,48)-1.2)<1e-3
        and math.abs(f32(charge,72)-0.7)<1e-3
        and math.abs(f32(charge,76)-1.4)<1e-3
end

local function ensure_auto_fire(record, charge)
    local found=charge:byte(AUTO_FIRE_FLAG+1)
    if found==1 then return true end
    local address=record+AUTO_FIRE_FLAG
    local written,problem=write_data(address,'\x01')
    local set=read(address,1)=='\x01'
    if set and owned[address]==nil then owned[address]=found end -- put back later
    local ok=written and set
    state.write_problem=not ok and (problem or 'record flag did not read back') or nil
    if ok then log_line(string.format('auto-fire flag restored at %#x',record)) end
    return ok
end

-- The scan's steps run inside its coroutine; each yield ends a work slice.
-- Each returns nil to keep scanning, or the scan's result: true, or false and
-- why.

-- One candidate: the record whose fingerprint lies 168 bytes into it, patched
-- when it is a valid charge record.
local function patch_candidate(record)
    local charge = read(record, 216)
    -- A recovery scan must pass already-patched copies to
    -- find a replacement, even if the old allocation lives on.
    if valid_charge_record(charge)
       and (not state.patched or charge:byte(AUTO_FIRE_FLAG+1)~=1) then
        state.record = record
        state.patched=ensure_auto_fire(record,charge)
        if state.patched then
            return true
        end
        return false, 'charge record write failed: '..tostring(state.write_problem)
    end
    return nil
end

-- Every fingerprint in one chunk, read at address chunk, in order.
local function search_chunk(blob, chunk)
    local start = 1
    while true do
        local found = blob:find(ARC_FINGERPRINT, start, true)
        if not found then return nil end
        local done, why = patch_candidate(chunk + found - 1 - 168)
        if done ~= nil then return done, why end
        start = found + 1
        coroutine.yield(0) -- malformed candidates also consume a work slice
    end
end

-- One region that can hold the weapon data library, read in chunks of up to
-- 64 KiB; each chunk read is a work slice.
local function scan_region(base, size)
    local offset = 0
    while offset < size do
        local span = math.min(65536, size - offset)
        local blob = read(base + offset, span)
        coroutine.yield(span)
        if blob then
            local done, why = search_chunk(blob, base + offset)
            if done ~= nil then return done, why end
        end
        -- Overlap keeps a fingerprint crossing a chunk boundary visible.
        offset = offset + (offset + span < size and span - #ARC_FINGERPRINT + 1 or span)
    end
    return nil
end

-- Every region of the address space in order: the committed private
-- read-only regions of at least 1 MiB are searched.
local function scan_charge_record()
    local information = ffi.new('atr1_region')
    local address = 0
    local limit = 0x7FFFFFFFFFFF
    while address < limit do
        coroutine.yield(0) -- bound region queries as well as data reads
        if kernel.atr1_VirtualQueryEx(state.process, address, information,
                                      ffi.sizeof(information)) == 0 then
            return false, 'VirtualQueryEx failed'
        end
        local base = tonumber(ffi.cast('uint64_t', information.base))
        local size = tonumber(information.size)
        if information.state == MEM_COMMIT and information.protection == PAGE_READONLY
           and information.type == MEM_PRIVATE and size >= 0x100000 then
            local done, why = scan_region(base, size)
            if done ~= nil then return done, why end
        end
        address = base + size
        if address <= 0 then break end
    end
    return false, 'charge record not found'
end

-- One update may examine at most 16 scan steps / 256 KiB, with a soft
-- one-millisecond deadline. A native read already in flight is not preemptible.
local scan_thread, next_scan = nil, 0
local function patch_charge_record(now)
    if now < next_scan then return false, 'waiting' end
    if not scan_thread then
        state.rescan_requested = nil
        scan_thread = coroutine.create(scan_charge_record)
        state.scans = state.scans + 1
    end
    local bytes, deadline = 0, seconds() + 0.001
    for _ = 1, 16 do
        local ok, result, reason = coroutine.resume(scan_thread)
        if not ok then
            scan_thread, next_scan = nil, now + 5
            return false, 'scan failed'
        end
        if coroutine.status(scan_thread) == 'dead' then
            scan_thread, next_scan = nil, now + (result and 1 or 5)
            return result, reason
        end
        bytes = bytes + (result or 0)
        if bytes >= 262144 or seconds() >= deadline then break end
    end
    return false, 'pending'
end

-- Revalidates the patched record (one 216-byte read) and repairs its flag.
local function check_record(now)
    local charge=read(state.record,216)
    if valid_charge_record(charge) then
        state.patched=ensure_auto_fire(state.record,charge)
        if not state.patched then
            log_line('charge record repair failed ('..tostring(state.write_problem)..'); retrying')
        end
    else
        -- Never write through an expired/reused record address.
        state.record=nil;state.patched=false
        scan_thread=nil;next_scan=now
        log_line('charge record unavailable or changed; rediscovering')
    end
end

-- check: this is a check frame (every CHECK_FRAMES updates), which
-- revalidates the record; the scan runs on every frame that calls this while
-- it is in progress, requested or still needed.
local function maintain_charge_record(now, check)
    if state.record and (check or state.check_record_now) then
        state.check_record_now = nil -- after a pause: re-patch the kept record first
        check_record(now)
    end
    if not state.patched or state.rescan_requested or scan_thread then
        local ok,reason=patch_charge_record(now)
        if ok then
            if not state.patch_logged then note('Charge record ready.');state.patch_logged=true end
        elseif not state.patched and reason~='pending' and reason~='waiting' and not state.scan_logged then
            state.scan_logged=true
            note('Charge record not ready yet: '..tostring(reason))
        end
    end
end

-- The record of the local player's Arc Thrower at entity (a copy the
-- binding keeps), or nil.
local ARC_RESOURCE_LOW, ARC_RESOURCE_HIGH = u32(ARC_RESOURCE, 0), u32(ARC_RESOURCE, 4)
local function arc_record(entity, avatar)
    if entity and entity ~= 0 and read_into(entity, 24, CANDIDATE) and CANDIDATE[0] == ARC_RESOURCE_LOW
        and CANDIDATE[1] == ARC_RESOURCE_HIGH and owned_bit(CANDIDATE) and local_weapon(CANDIDATE[2], avatar[2]) then
        return copy_record(CANDIDATE)
    end
    return nil
end

-- The first flagged entry from index first on that holds the local player's
-- Arc Thrower, as {entity, identity}, or nil. At most TRIGGER_BATCH flagged
-- entries are inspected; the next discovery continues after the last one.
local function flagged_arc(avatar, count, entities, flags, first)
    local examined = 0
    for offset = 0, count - 1 do
        local index=(first+offset)%count
        if flags:byte(index + 1) ~= 0 then
            local entity = pointer(entities+index*POINTER_SIZE)
            local record = arc_record(entity, avatar)
            if record then return {entity=entity,identity=record} end
            examined=examined+1
            if examined>=TRIGGER_BATCH then
                state.discovery_index=(index+1)%count
                return nil
            end
        end
    end
    return nil
end

-- Inspect the small fire-command table first. Ordinary weapons never trigger
-- a walk of every charged weapon. Charge-table lookup is needed only to arm
-- an Arc Thrower that the engine is actually firing.
local function active_arc(avatar)
    local manager = pointer(state.game + TRIGGER_MANAGER)
    if not manager or manager == 0 then return nil end
    local header = read(manager + 24, 72)
    if not header then return nil end
    local count, entities, held = u32(header, 0), u64(header, 40), u64(header, 64)
    state.trigger_count=count
    if count < 1 or count > TRIGGER_LIMIT or entities == 0 or held == 0 then
        return nil,'invalid trigger table (count '..tostring(count)..')'
    end
    -- Read the small flag array first so a sparse table's last slot is found
    -- before the first shot clears its command. Inspect at most 64 active
    -- candidates per discovery; dense tables continue in the next batch.
    if state.discovery_entities~=entities or state.discovery_count~=count then
        state.discovery_index=0
        state.discovery_entities=entities;state.discovery_count=count
    end
    local first=state.discovery_index or 0
    local flags=read(held,count)
    if not flags then return nil end
    state.discovery_index=0
    local chosen=flagged_arc(avatar,count,entities,flags,first)
    if not chosen then return nil end
    chosen.entry=charge_entry(chosen)
    if chosen.entry then return chosen end
end

local failure_logged = false
local resolved = nil

local function clear_hold(reason)
    state.armed=false;resolved=nil;state.previous=nil
    state.next_discovery=nil;state.discovery_index=0
    state.suspended_since=nil;state.held_time=nil
    state.progress_time=nil;state.drove_since=nil;state.drove_peak=0
    if #state.shots>0 then state.shots={} end -- an empty list is kept, not replaced
    state.last_shot=nil;state.reason=reason
end

-- A press the assist is following: armed, or retrying discovery while Fire
-- stays held. Such frames always run the full check.
local function holding()
    return state.armed or resolved~=nil or state.next_discovery~=nil
end

local function suspend_hold(now,reason)
    state.suspended_since=state.suspended_since or now
    state.previous=nil
    state.reason=reason
    if now-state.suspended_since>=RECOVERY_WINDOW then clear_hold(reason..'; hold expired') end
end

-- Update-chain policy: Bingus Shared Runtime's update guard, the family's
-- policy (src/bingus_runtime.lua, vendored byte-identical; scripts/entry.py
-- embeds it ahead of this addon). The previous update runs outside pcall, so
-- its errors reach the game unchanged; one that raised is seen on the next
-- frame. This addon can put back what it changed, so an error below it
-- pauses it: it restores, starts afresh and skips its work until the updates
-- below have returned on 60 frames in a row. 8 errors in a burst stop it, its
-- own counted apart from those below it; each count starts again after 3600
-- error-free frames (about a minute at 60 FPS), and each burst gets one log
-- line. A refusal stops it too. The first failure is kept for the shutdown
-- status.
local guard -- installed at the end of this chunk
local first_failure -- a startup failure (bindings, build), for the shutdown status

-- Puts each record flag this addon set back to the byte it found, while the
-- record is still a valid Arc Thrower charge record holding the addon's 1.
-- True, or false and why.
local function restore_records()
    local restored, why = true, nil
    for address, found in pairs(owned) do
        local charge = read(address - AUTO_FIRE_FLAG, 216)
        if valid_charge_record(charge) and charge:byte(AUTO_FIRE_FLAG + 1) == 1 then
            local byte = string.char(found)
            local written, problem = write_data(address, byte)
            if written and read(address, 1) == byte then owned[address] = nil
            else restored, why = false, problem or 'the restored flag did not read back' end
        else
            owned[address] = nil -- replaced or changed by the game: no longer this addon's
        end
    end
    return restored, why
end

-- Ends the hold (the engine clears the charging flag itself on its next
-- frame) and puts the records back.
local function restore_game(reason)
    clear_hold(reason)
    local restored, why = restore_records()
    state.patched = false
    return restored, why
end

local function restore_note(ok, restored, why)
    if not ok then return '; restore raised: ' .. tostring(restored) end
    if not restored then return '; restore failed: ' .. tostring(why) end
    return ''
end

-- Stops the addon for the session (a refusal); the guard puts the records
-- back through stopped below.
local function stop(reason)
    if guard then guard.stop(reason) end
end

-- The guard stopped the addon, or the game shuts down: put the records back.
-- The shutdown status line is written once the shutdown has run.
local restore_status = ''
local function stopped(reason)
    local ok, restored, why = pcall(restore_game, reason == 'shutdown' and 'shutdown' or 'stopped')
    restore_status = restore_note(ok, restored, why)
    if reason ~= 'shutdown' and restore_status ~= '' then note('Stopped' .. restore_status) end
end

-- After an error below: restore and start afresh. The record address stays as
-- a hint, revalidated (and patched again) on the first frame after resuming.
local function fresh_start()
    local restored, why = restore_game('paused')
    if not restored then error(why, 0) end
    scan_thread, next_scan = nil, 0
    state.rescan_requested = nil
    state.fire_slot = nil
    forget_slot()
    state.frames = CHECK_FRAMES - 1
    state.check_record_now = state.record ~= nil
end

-- Bindings and the build check, each failure logged once and kept as the
-- first failure. False: stay idle.
local function ready()
    if not bind() then
        if not state.bind_logged then
            state.bind_logged = true
            first_failure = first_failure or 'bindings unavailable'
            note('Engine bindings unavailable; the addon stays idle: '
                 .. tostring(state.bind_error))
        end
        return false
    end
    if not supported_build() then
        if not failure_logged then
            failure_logged = true
            first_failure = first_failure or 'unsupported game build'
            note('Unsupported game build; the addon is disabled.')
        end
        return false
    end
    return true
end

-- Diagnostics only: the shot intervals of the hold that just ended.
local function log_release()
    local intervals = {}
    for index = 2, #state.shots do
        local interval = state.shots[index]
        if interval then intervals[#intervals + 1] = interval end
    end
    local summary = 'released after ' .. tostring(#state.shots) .. ' shot(s)'
    if #intervals > 0 then
        local total, minimum, maximum = 0, intervals[1], intervals[1]
        for _, interval in ipairs(intervals) do
            total = total + interval
            minimum = math.min(minimum, interval)
            maximum = math.max(maximum, interval)
        end
        summary = summary .. string.format(
            '; interval min %.3f mean %.3f max %.3f (%d)',
            minimum, total / #intervals, maximum, #intervals)
    end
    log_line(summary)
end

-- The armed weapon must still be the same entity, held by the same local
-- avatar, with a readable charge binding. False: the hold was suspended or
-- cleared and this frame writes nothing.
-- check: a check frame, which looks the weapon holder up afresh.
local function revalidate(now, avatar, check)
    if not read_into(resolved.entity, 24, ENTITY_RECORD) then
        suspend_hold(now,'weapon identity unreadable');return false
    end
    if not same_record(ENTITY_RECORD, resolved.identity) or not same_record(avatar, resolved.avatar) then
        clear_hold('weapon entity changed')
        return false
    end
    local owned=local_weapon(resolved.identity[2],avatar[2],not check)
    if owned==nil then suspend_hold(now,'weapon holder unavailable');return false end
    if not owned then
        clear_hold('weapon holder changed')
        return false
    end
    local entry=charge_entry(resolved)
    if entry==nil then suspend_hold(now,'charge binding unavailable');return false end
    if entry==false then
        clear_hold('charge binding changed')
        return false
    end
    if entry~=resolved.entry then
        resolved.entry=entry;state.previous=nil;state.drove_since=nil;state.drove_peak=0
    end
    return true
end

-- Only assist after the engine issued a fire command for an arc thrower, so
-- holding the button for another weapon stays untouched. Discovery runs at most
-- ten times a second. False while waiting for that command.
local function arm(now, avatar)
    if now < (state.next_discovery or 0) then return false end
    state.next_discovery = now + 0.1
    local chosen,reason = active_arc(avatar)
    if not chosen then
        state.reason = reason or 'waiting for the engine fire command'
        return false
    end
    resolved = chosen
    resolved.avatar = copy_record(avatar) -- avatar is the per-frame buffer
    state.armed = true
    state.shots = {}
    state.last_shot = nil
    state.reason = nil
    state.drove_since = nil
    state.drove_peak = 0
    state.progress_time=now
    log_line(string.format('assist armed entity=%#x entry=%#x',
                           chosen.entity, chosen.entry))
    return true
end

-- Recheck a stalled cycle for a replacement weapon. The engine's original
-- one-shot fire command may already be cleared: that alone must not cancel
-- a still-held, identity- and slot-validated Arc during a reload or pause.
-- True when the hold moved to another weapon: this frame writes nothing.
local function recheck_stall(now, avatar, value, full)
    if not state.drove_since then
        state.drove_since = now
        state.drove_peak = value
    end
    state.drove_peak = math.max(state.drove_peak or 0, value)
    if (now - state.drove_since) > 1.2 and state.drove_peak < full * 0.25 then
        state.rescans = state.rescans + 1
        log_line(string.format(
            'entry %#x stalled (peak %.3f) - checking the current binding (#%d)',
            resolved.entry, state.drove_peak, state.rescans))
        local chosen=active_arc(avatar)
        state.drove_since=now;state.drove_peak=value
        if chosen and (chosen.entity~=resolved.entity or not same_record(chosen.identity,resolved.identity)
                       or chosen.entry~=resolved.entry) then
            chosen.avatar=copy_record(avatar);resolved=chosen;state.previous=nil
            return true
        end
    end
    return false
end

-- Charge progress of this cycle.
local function track_progress(now, value, full)
    local previous = state.previous
    state.previous = value
    -- A missing auto-fire patch can also leave charge stuck at full, which the
    -- low-charge stall check above cannot detect. Search for another matching
    -- data record only after sustained lack of progress, within the scan budget.
    if not previous or math.abs(value-previous)>1e-4 then state.progress_time=now end
    if now-(state.progress_time or now)>math.max(1.2,full*1.5) then
        state.rescan_requested=true;state.progress_time=now
    end
    -- Progress belongs to this charge cycle, not the best charge since press.
    -- Otherwise a completed first shot disables stall recovery for the hold.
    if previous and value < previous - 0.01 then
        state.drove_since=now;state.drove_peak=value
    end
    if rawget(_G, 'ArcThrowerDiagnostics') and previous and previous > full * 0.5 and value < full * 0.05 then
        local interval = state.last_shot and (now - state.last_shot) or nil
        state.last_shot = now
        state.shots[#state.shots + 1] = interval or false
        log_line(string.format('shot %d (charge %.3f -> %.3f, interval %s)',
                               #state.shots, previous, value,
                               interval and string.format('%.3f', interval) or 'n/a'))
    end
end

-- Diagnostics only: the hold's charge rate, every 0.25 s.
local function log_status(now, value, full, flag)
    if not rawget(_G, 'ArcThrowerDiagnostics') then return end
    if state.status and now - state.status < 0.25 then return end
    local window = now - (state.status or now)
    local delta = value - (state.status_charge or value)
    state.status = now
    state.status_charge = value
    log_line(string.format(
        'hold entry=%#x charge=%.3f full=%.3f flag=%d rate=%.2f/s',
        resolved.entry, value, full, flag, window > 0 and delta / window or 0))
end

-- The charging flag lives in the charge manager's entry array, private
-- read-write game memory. It is written only when it is not already set (the
-- engine copies the fire command into it every frame, and clears it once the
-- shot has fired). The entry's page is checked right before the first write
-- of a binding, one protection query; the answer is kept with the binding,
-- whose entry address is re-read from the live manager on every frame, and
-- dropped when the binding changes or a write fails. A page that is not
-- committed private read-write memory is refused: nothing is written and the
-- addon stops (restoring the record).
local function set_charging_flag()
    local address = resolved.entry + 12
    local page = address - address % 4096
    if resolved.checked_page ~= page then
        if private_protection(address) ~= PAGE_READWRITE then
            stop(string.format('charge entry %#x is not private read-write memory (%s)', resolved.entry,
                               page_text()))
            return false
        end
        resolved.checked_page = page
    end
    if not write(address, '\x01') then
        resolved.checked_page = nil
        state.reason = 'charge flag write failed'
        return false
    end
    return true
end

-- The engine's charge updater advances the charge by the frame delta while
-- the charging flag is set and fires when it crosses the full-charge time,
-- so keeping that flag asserted is the whole job.
local function drive_charge(now, avatar, held)
    state.suspended_since=nil;state.held_time=held
    if not read_into(resolved.entry, ENTRY_SIZE, CHARGE_ENTRY) then
        state.reason = 'charge entry unreadable'
        return
    end
    local value = float_bits(CHARGE_ENTRY[1])
    local full = float_bits(CHARGE_ENTRY[2])
    local flag = bit.band(CHARGE_ENTRY[3], 0xff)
    if full~=full or value~=value or full <= 0.1 or value<0 then
        state.reason = 'invalid full-charge time'
        return
    end
    if recheck_stall(now, avatar, value, full) then return end
    track_progress(now, value, full)
    if flag ~= 1 and not set_charging_flag() then return end
    log_status(now, value, full, flag)
end

-- Fire is held: end an interrupted hold, keep or arm the binding, then drive
-- the charge.
local function follow_press(now, avatar, held, check)
    if state.suspended_since and (now-state.suspended_since>=RECOVERY_WINDOW
        or (state.held_time and held<state.held_time)) then
        clear_hold('interrupted hold requires a new fire command')
    end
    if resolved and not revalidate(now, avatar, check) then return end
    if not state.armed and not arm(now, avatar) then return end
    drive_charge(now, avatar, held)
end

-- The full check of the local Fire input and the hold it drives.
local function follow_input(now, check)
    local down,avatar,held,slot = local_fire(check)
    state.fire_slot = slot
    if down==nil then
        -- Unknown input is not proof of release. Retain only a short-lived
        -- binding, with no charge writes until all validation succeeds again.
        suspend_hold(now,'native Fire input unavailable')
        return
    end
    if not down then
        if state.armed and rawget(_G, 'ArcThrowerDiagnostics') then log_release() end
        clear_hold(nil)
        return
    end
    follow_press(now, avatar, held, check)
end

-- One update. Returns true when it ran the full Fire check. An idle frame
-- (no check frame, no press being followed, no scan in progress, Fire up)
-- stops after the gate's single read and takes no timestamp.
local function step()
    state.reason=nil -- diagnostics must describe this frame, not a past failure
    if not ready() then return false end
    state.frames = (state.frames + 1) % CHECK_FRAMES
    local check = state.frames == 0
    local input = check or holding() or fire_may_be_held()
    if not input and not scan_thread and not state.check_record_now then return false end
    local now = seconds()
    state.now = now
    maintain_charge_record(now, check)
    if state.protection_lost then
        stop('weapon data protection could not be restored')
        return false
    end
    if input then follow_input(now, check) end
    return input
end

-- Diagnostics only: this frame's reason the assist is idle, at most every 2 s
-- unless it changed.
local function log_reason()
    if not state.reason then state.reason_log = nil; return end
    local now = state.now
    if state.reason_log ~= state.reason or (now - (state.reason_time or 0) > 2) then
        state.reason_log = state.reason
        state.reason_time = now
        log_line('idle: ' .. state.reason)
    end
end

-- This addon's part of one update, before the updates below it run; the
-- guard runs it under pcall. Frames without the full check leave the reasons
-- logged before.
local function guarded_step()
    if step() then log_reason() end
end

-- At shutdown the guard puts the records back (unless the addon stopped and
-- did so already); then this addon logs "stopped" or "stopped after: <first
-- failure>". The previous shutdown runs outside pcall.
local function shutdown_status(...)
    local state_text = guard.status.state
    if state_text == 'stopped' and first_failure then state_text = 'stopped after: ' .. first_failure end
    note('Shutdown: ' .. state_text .. restore_status)
    return ...
end

local installed, problem = pcall(function()
    guard = runtime.guard({name = 'ArcThrowerRevamped', step = guarded_step, stop = stopped, pause = fresh_start,
                           log = note, env = _G}).install()
    local guarded_shutdown = rawget(_G, 'shutdown')
    rawset(_G, 'shutdown', function(...) return shutdown_status(guarded_shutdown(...)) end)
end)
if not installed then note('Update guard unavailable; the addon stays idle: ' .. tostring(problem)) end

-- Update owns the assist. Render remains untouched so discovery and native
-- writes run once per game update, regardless of how often the engine renders.

-- The LuaJIT code cache is shared by the game and every mod. Only the idle
-- path, which runs on every update, and the read and decode helpers compile;
-- the rest runs on few updates (check frames, a held Fire, the scan, writes,
-- restores, diagnostics) and stays interpreted. Measured offline in the
-- game's lua51.dll: about 5 KB of machine code instead of 67 KB, for about
-- 2 us more per update while the Arc Thrower fires.
if jit and jit.off then
    jit.off(true, true) -- this chunk and every function in it
    for _, f in ipairs({guarded_step, step, ready, holding, fire_may_be_held, read_into, read, pointer, u32, u64,
                        f32, mul32, write, seconds}) do
        jit.on(f)
    end
end

note('Arc Thrower Revamped ' .. module.revision .. ' initialised (loader API ' ..
     tostring(loader and loader.api or '?') .. ')')
