-- HD2-Addon: mods/cowboybingus/laser_sentry_cooldown
-- Laser Sentry Cooldown v1.0 for Helldivers 2 Steam build 25480438.
--
-- The A/LAS-98 Laser Sentry builds heat while it fires. In the game's data its heat record says
-- needs_reload_after_overheat = 1 with 0 spare heat sinks, so once it reaches max heat the engine never
-- cools it or lets it recover (WeaponHeat update 0x762F60), its weapon reads as empty for good and the
-- sentry is lost. The engine already has the other rule, which the Quasar Cannon uses: with
-- needs_reload_after_overheat = 0 an overheated weapon cools at temp_loss_per_second_overheated and fires
-- again once its temperature is back at overheat_temperature_recover (0).
--
-- This addon makes that one change to the Laser Sentry's record, once per session, and adds no number of its
-- own: an overheated Laser Sentry cools at the rate it already cools at when idle (its own
-- temp_loss_per_second, 5 heat/s in this build: about 50 s from max heat at normal planet temperature) and
-- fires again once cold. Overheating itself plays the game's own sounds and effects. The same engine rule
-- also cools it at that rate while its beam powers up or winds down (about 0.7 s around a burst; the base game
-- does not cool it then). Heat gain while firing, idle cooling, damage and targeting are untouched, and no
-- other weapon is changed. There are no options.
--
-- The record lives in the game's weapon data library, which the game keeps read-only. The addon checks the
-- page, makes those 5 bytes writable for the write only, restores the protection at once and reads the
-- bytes back. Once written it does no work per frame. A pause (an update below this addon failed) or a stop
-- puts the original bytes back; a resume writes them again.
local Cooldown = {VERSION = '1.0'}
Cooldown.REVISION = 'v' .. Cooldown.VERSION

local ffi = require('ffi')
local format = string.format

-- Build 25480438 anchors (EXE 1.8.46015.0). The heat settings lookup 0x50DD30 reads
-- [[game + ROOT_RVA] + TABLE_OFFSET]: 58 slots of {u64 resource, u32 index, u32 pad} probed linearly from
-- resource % 58, then 592-byte WeaponHeatComponent records at table + 928 + 592 * index. The block starts
-- 24 bytes before the table with 'LDLD', version 1, the WeaponHeatComponentData type hash and its size.
Cooldown.ROOT_RVA = 0x346BF98
Cooldown.TABLE_OFFSET = 0xF12CC8
Cooldown.SLOTS, Cooldown.SLOT_SIZE = 58, 16
Cooldown.RECORDS_OFFSET, Cooldown.RECORD_SIZE = 928, 592
Cooldown.HEADER_SIZE = 24
Cooldown.HEADER_MAGIC, Cooldown.HEADER_VERSION, Cooldown.HEADER_TYPE = 0x444C444C, 1, 0x4C981CD9
-- content/fac_helldivers/hellpod/laser_cannon_turret/laser_cannon_turret, as two 32-bit halves.
Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH = 0xCFFFA8A8, 0x56070F36

-- Every record value the change relies on, with its vanilla value: {offset, size, value}.
Cooldown.EXPECTED = {
    {0x50, 1, 1},          -- overheating is enabled for this weapon
    {0x54, 4, 0},          -- magazines (spare heat sinks at deployment)
    {0x5C, 4, 0},          -- magazines_max
    {0x60, 4, 0x437A0000}, -- overheat_temperature 250.0
    {0x64, 4, 0},          -- overheat_temperature_recover 0.0: the sentry cools all the way down
}
Cooldown.OVERHEAT_TEMPERATURE = 250

-- The change: temp_loss_per_second_overheated (f32 at 0x8C) and needs_reload_after_overheat (u8 at 0x90),
-- written as one 5-byte range. Vanilla: 400.0 (never used, because the reload flag stops all cooling) and 1.
-- The mod's bytes: the record's own temp_loss_per_second (f32 at 0x80, the cooling rate when idle), then 0.
-- 400 would make an overheat cost about 0.6 s; the sentry's own idle rate keeps the game's cooling speed.
Cooldown.CHANGE_OFFSET = 0x8C
Cooldown.IDLE_COOLING_OFFSET = 0x80
Cooldown.VANILLA = '\0\0\200\67\1' -- 400.0f (0x43C80000) little-endian, then 1

-- The number an f32 stored little-endian in 4 bytes holds (x64 only).
local f32_cell = ffi.new('float[1]')
local function f32_value(bytes)
    ffi.copy(f32_cell, bytes, 4)
    return tonumber(f32_cell[0])
end
Cooldown.f32_value = f32_value

-- How often a frame looks for the heat table while the game has not built it yet (boot only).
Cooldown.POLL_FRAMES = 30

local MEM_COMMIT, MEM_PRIVATE = 0x1000, 0x20000
local PAGE_READONLY, PAGE_READWRITE = 0x02, 0x04
local HIGH = 4294967296

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function unsigned(bytes, offset, size)
    if size == 1 then return bytes:byte(offset + 1) end
    return u32(bytes, offset)
end

local function valid_address(value)
    return type(value) == 'number' and value >= 0x10000 and value < 0x800000000000
end

-- The first slot the engine probes for a 64-bit resource: resource % SLOTS, exact from the two halves.
function Cooldown.first_slot(low, high)
    local slots = Cooldown.SLOTS
    return ((high % slots) * (HIGH % slots) + low % slots) % slots
end

-- The record's index in the slot table (928 bytes as a string), probed as 0x50DD30 does: linearly from
-- resource % 58, stopping at an empty slot. nil when the resource is not there.
function Cooldown.find_index(slots, low, high)
    local count, size = Cooldown.SLOTS, Cooldown.SLOT_SIZE
    local slot = Cooldown.first_slot(low, high)
    for _ = 1, count do
        local base = slot * size
        local entry_low, entry_high = u32(slots, base), u32(slots, base + 4)
        if entry_low == low and entry_high == high then return u32(slots, base + 8) end
        if entry_low == 0 and entry_high == 0 then return nil end
        slot = (slot + 1) % count
    end
    return nil
end

-- The heat table's address, or nil while the game has not built it (2 reads, no allocation).
function Cooldown.table_address(api, game)
    local root = api.u64(game + Cooldown.ROOT_RVA)
    if not valid_address(root) then return nil end
    local heat = api.u64(root + Cooldown.TABLE_OFFSET)
    if not valid_address(heat) then return nil end
    return heat
end

-- The Laser Sentry's record address from the heat table, or nil and why (3 reads).
function Cooldown.locate(api, heat)
    local header = api.read(heat - Cooldown.HEADER_SIZE, Cooldown.HEADER_SIZE)
    if not header then return nil, 'heat table header unreadable' end
    local size = u32(header, 12)
    if u32(header, 0) ~= Cooldown.HEADER_MAGIC or u32(header, 4) ~= Cooldown.HEADER_VERSION
        or u32(header, 8) ~= Cooldown.HEADER_TYPE then
        return nil, 'unexpected heat table header'
    end
    local slots = api.read(heat, Cooldown.SLOTS * Cooldown.SLOT_SIZE)
    if not slots then return nil, 'heat table unreadable' end
    local index = Cooldown.find_index(slots, Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH)
    if not index then return nil, 'Laser Sentry heat record not found' end
    local offset = Cooldown.RECORDS_OFFSET + Cooldown.RECORD_SIZE * index
    if offset + Cooldown.RECORD_SIZE > size then return nil, 'Laser Sentry heat record outside the table' end
    return heat + offset
end

-- Checks the record holds the vanilla values the change relies on. Returns 'vanilla' or 'patched' (this
-- change is already there), the 5 bytes the change writes (the record's own idle cooling rate, then 0) and
-- that rate; or nil and why. One read.
function Cooldown.inspect(api, record)
    local length = Cooldown.CHANGE_OFFSET + #Cooldown.VANILLA
    local bytes = api.read(record, length)
    if not bytes then return nil, 'Laser Sentry heat record unreadable' end
    for _, expected in ipairs(Cooldown.EXPECTED) do
        local offset, size, value = expected[1], expected[2], expected[3]
        if unsigned(bytes, offset, size) ~= value then
            return nil, format('unexpected Laser Sentry heat record (offset %#x)', offset)
        end
    end
    local idle = bytes:sub(Cooldown.IDLE_COOLING_OFFSET + 1, Cooldown.IDLE_COOLING_OFFSET + 4)
    local rate = f32_value(idle)
    if not (rate > 0 and rate < 1000) then return nil, 'unexpected Laser Sentry cooling rate' end
    local patched = idle .. '\0'
    local current = bytes:sub(Cooldown.CHANGE_OFFSET + 1, length)
    if current == Cooldown.VANILLA then return 'vanilla', patched, rate end
    if current == patched then return 'patched', patched, rate end
    return nil, 'Laser Sentry heat record already changed by something else'
end

-- The protection of the region holding [address, address + #bytes) when that range lies inside one committed
-- private region, else nil and why. One VirtualQuery.
local function private_protection(api, address, bytes)
    local state, protection, kind, base, size = api.page(address)
    if not state then return nil, 'page query failed' end
    if state ~= MEM_COMMIT or kind ~= MEM_PRIVATE then
        return nil, format('not committed private memory (state %#x, type %#x)', state, kind)
    end
    if address < base or address + #bytes > base + size then return nil, 'write would leave the region' end
    return protection
end

-- A write through a read-only page: read-write for the write only, then the previous protection back.
-- Returns true, or false, why, whether the protection is lost and whether the write landed.
local function write_read_only(api, address, bytes)
    local previous = api.protect(address, #bytes, PAGE_READWRITE)
    if not previous then return false, 'page protection change refused' end
    local written = api.write(address, bytes)
    if not api.protect(address, #bytes, previous) then
        return false, 'page protection could not be restored', true, written
    end
    if not written then return false, 'write failed' end
    return true
end

-- Writes bytes into the weapon data library: committed private memory that the game keeps read-only.
-- The page is checked right before the write (one VirtualQuery), made writable for the write only and given
-- its protection back at once; a page that is already private read-write is written directly. The bytes are
-- read back. Returns true, or false, why, whether the original protection could not be restored and whether
-- the write itself landed (then the caller must put the old bytes back).
function Cooldown.protected_write(api, address, bytes)
    local protection, why = private_protection(api, address, bytes)
    if not protection then return false, why end
    if protection == PAGE_READWRITE then
        if not api.write(address, bytes) then return false, 'write failed' end
    elseif protection == PAGE_READONLY then
        local written, problem, lost, landed = write_read_only(api, address, bytes)
        if not written then return false, problem, lost, landed end
    else
        return false, format('unexpected page protection %#x', protection)
    end
    if api.read(address, #bytes) ~= bytes then return false, 'write did not read back', false, true end
    return true
end

-- One instance per session. api: the adapter below (or a test double); game: game.dll's base as a number;
-- note(line): the log. The instance's step runs every frame through the shared runtime's guard.
function Cooldown.new(api, game, note)
    local self = {status = 'waiting for the weapon data', patched = false, record = nil, writes = 0,
                  polls = 0, frames = 0, failure = nil}
    self.api, self.note = api, note
    local stop -- set by attach: stops the guard with a reason

    local function refuse(reason)
        self.failure = reason
        self.status = 'stopped: ' .. reason
        note('Disabled: ' .. reason)
        if stop then stop(reason) end
        return false
    end

    -- Writes the change, or confirms it is there. True when the record holds the change.
    local function patch(record)
        local found, bytes, rate = Cooldown.inspect(api, record)
        if not found then return refuse(bytes) end
        self.record, self.patched_bytes = record, bytes
        if found == 'vanilla' then
            local written, problem, lost, landed = Cooldown.protected_write(api, record + Cooldown.CHANGE_OFFSET, bytes)
            if not written then
                if lost then self.protection_lost = true end
                -- Bytes that landed are put back by the stop that follows (restore), whatever else failed.
                if landed then self.patched = true end
                return refuse(problem)
            end
            self.writes = self.writes + 1
        end
        self.patched = true
        self.status = 'active'
        note(format('Laser Sentry heat record %s: an overheated Laser Sentry cools at its own idle rate '
                    .. '(%g heat/s, %g s from max heat %d at normal planet temperature) and fires again.',
                    found == 'vanilla' and 'changed' or 'already changed', rate,
                    Cooldown.OVERHEAT_TEMPERATURE / rate, Cooldown.OVERHEAT_TEMPERATURE))
        return true
    end

    -- Looks for the heat table and writes the change once it exists. Returns true when patched.
    function self.try()
        self.polls = self.polls + 1
        local heat = Cooldown.table_address(api, game)
        if not heat then return false end
        local record, why = Cooldown.locate(api, heat)
        if not record then return refuse(why) end
        return patch(record)
    end

    -- Every frame, before the game's update. Patched (or stopped by the guard): nothing at all. Waiting for
    -- the game to build its weapon data (boot): one look every POLL_FRAMES frames.
    function self.step()
        if self.patched or self.failure then return end
        local frames = self.frames + 1
        if frames < Cooldown.POLL_FRAMES then self.frames = frames; return end
        self.frames = 0
        self.try()
    end

    -- Puts the vanilla bytes back. Raises when that fails, so the guard stops the addon (pause) or keeps
    -- the failure (stop).
    function self.restore()
        if not self.patched then return end
        local written, problem = Cooldown.protected_write(api, self.record + Cooldown.CHANGE_OFFSET, Cooldown.VANILLA)
        if not written then error('restore failed: ' .. problem, 0) end
        self.writes = self.writes + 1
        self.patched = false
        if not self.failure then self.status = 'restored' end
    end

    -- The guard's pause: restore and start afresh; the next step after the resume looks again at once.
    function self.pause(reason)
        self.restore()
        self.frames = Cooldown.POLL_FRAMES - 1
        self.status = 'paused: ' .. tostring(reason)
        note('Paused (' .. tostring(reason) .. '); the vanilla heat rule is back until the addon resumes.')
    end

    -- The guard's stop: restore, except at shutdown (the game is closing and its data with it).
    function self.stopped(reason)
        if reason == 'shutdown' then
            note('Shutdown: ' .. (self.failure and ('stopped after: ' .. self.failure) or self.status))
            return
        end
        local ok, problem = pcall(self.restore)
        note('Stopped (' .. tostring(reason) .. ')' .. (ok and '' or ('; ' .. tostring(problem))))
    end

    function self.attach(stopper) stop = stopper end
    return self
end

-- The in-game adapter: the Windows calls the instance makes, declared under private names (an __asm__ label
-- naming the real export) and private type names, so another mod's declarations of the real names neither
-- change these calls nor are changed by them. Addresses go in as uint64_t numbers. 64-bit results are read
-- as two 32-bit halves into reused buffers (interpreted code boxes every 64-bit value it reads), so u64,
-- page and protect allocate nothing; read allocates only the string it returns.
local DECLARATIONS = [[
typedef struct lsc1_region {
    uint32_t base_low, base_high, allocation_low, allocation_high;
    uint32_t allocation_protection; uint16_t partition, reserved;
    uint32_t size_low, size_high, state, protection, type, padding;
} lsc1_region;
void *lsc1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
int lsc1_ReadProcessMemory(void *process, uint64_t address, void *buffer, size_t size, uint32_t *done) __asm__("ReadProcessMemory");
int lsc1_WriteProcessMemory(void *process, uint64_t address, const void *buffer, size_t size, uint32_t *done) __asm__("WriteProcessMemory");
uint32_t lsc1_VirtualQuery(uint64_t address, lsc1_region *region, size_t size) __asm__("VirtualQuery");
int lsc1_VirtualProtectEx(void *process, uint64_t address, size_t size, uint32_t protection, uint32_t *previous) __asm__("VirtualProtectEx");
]]

function Cooldown.adapter()
    if not ffi.abi('64bit') then error('Windows x64 is required', 0) end
    if not pcall(ffi.typeof, 'lsc1_region') then ffi.cdef(DECLARATIONS) end
    local kernel = ffi.load('kernel32')
    local process = kernel.lsc1_GetCurrentProcess()
    local read_memory, write_memory = kernel.lsc1_ReadProcessMemory, kernel.lsc1_WriteProcessMemory
    local query, protect = kernel.lsc1_VirtualQuery, kernel.lsc1_VirtualProtectEx
    local done = ffi.new('uint32_t[2]') -- a SIZE_T count, as two halves
    local words = ffi.new('uint32_t[2]')
    local region, region_size = ffi.new('lsc1_region'), ffi.sizeof('lsc1_region')
    local previous = ffi.new('uint32_t[1]')
    local scratch_size = 1024
    local scratch = ffi.new('uint8_t[?]', scratch_size)
    local api = {}

    -- The 8 bytes at address as a number (exact below 2^53), or nil.
    function api.u64(address)
        if read_memory(process, address, words, 8, done) == 0 or done[0] ~= 8 or done[1] ~= 0 then return nil end
        return words[0] + words[1] * HIGH
    end

    -- The bytes at address as a string, or nil when they cannot all be read.
    function api.read(address, size)
        if size < 1 or size > scratch_size then return nil end
        if read_memory(process, address, scratch, size, done) == 0 or done[0] ~= size or done[1] ~= 0 then
            return nil
        end
        return ffi.string(scratch, size)
    end

    -- The memory region holding address: state, protection, type, base and size, or nil (one VirtualQuery).
    function api.page(address)
        if query(address, region, region_size) ~= region_size then return nil end
        return region.state, region.protection, region.type, region.base_low + region.base_high * HIGH,
               region.size_low + region.size_high * HIGH
    end

    -- Changes the protection of [address, address + size): the previous protection, or nil.
    function api.protect(address, size, protection)
        if protect(process, address, size, protection, previous) == 0 then return nil end
        return previous[0]
    end

    -- Writes a string at address: true when every byte landed.
    function api.write(address, bytes)
        return write_memory(process, address, bytes, #bytes, done) ~= 0 and done[0] == #bytes and done[1] == 0
    end

    return api
end

-- Build 25480438 module hashes, verified through bingus_memory.lua (each file hashed once per session for
-- every mod that asks).
Cooldown.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
Cooldown.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'

-- Bingus Shared Loader v18+ with API 1, recognized by what it offers, never by its internal version.
function Cooldown.loader_ok(loader)
    return type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function'
        and type(loader.jit) == 'table'
end

-- Everything but the per-frame step runs on a few frames at most (startup, a pause, a stop) and stays
-- interpreted, so the addon adds next to nothing to the LuaJIT code cache the game and every mod share.
local function interpreted(functions)
    if type(jit) ~= 'table' or type(jit.off) ~= 'function' then return end
    for _, fn in ipairs(functions) do jit.off(fn) end
end

-- Builds the instance and installs Bingus Shared Runtime's update guard (bingus_runtime.lua, bundled by the
-- build): the previous update runs outside pcall, 8 errors in a burst stop the addon, an error below pauses
-- it (restore) until the updates below run cleanly for 60 frames, and the first failure survives shutdown.
-- options.adapter replaces the in-game adapter (tests). Returns the instance, or nil when disabled.
function Cooldown.install(runtime, memory, options)
    options = options or {}
    local loader = rawget(_G, 'CowboyBingusModLoader')
    local log_file
    if loader and type(loader.open_log) == 'function' then
        pcall(function() log_file = loader.open_log('LaserSentryCooldown.log') end)
    end
    local function note(line)
        print('[LaserSentryCooldown] ' .. line)
        if log_file then pcall(function() log_file:write(line .. '\n'); log_file:flush() end) end
    end
    -- Raises reason without a source position, so the log line reads as the reason.
    local function require_that(condition, reason)
        if not condition then error(reason, 0) end
    end
    local ready, instance = pcall(function()
        require_that(Cooldown.loader_ok(loader), 'Bingus Shared Loader v18+ / API 1 required')
        local game = memory.module('game.dll')
        require_that(game ~= nil and memory.module(nil) ~= nil, 'game modules unavailable')
        local ok, why = memory.verify_build({exe_sha256 = Cooldown.EXE_SHA256, game_sha256 = Cooldown.GAME_SHA256})
        require_that(ok, why == 'unsupported game build' and 'unsupported game build (needs Steam build 25480438)'
                     or tostring(why))
        local api = (options.adapter or Cooldown.adapter)()
        return Cooldown.new(api, memory.address(game), note)
    end)
    if not ready then
        note('Disabled: ' .. tostring(instance))
        return nil
    end
    interpreted({instance.try, instance.restore, instance.pause, instance.stopped, note})
    local env = options.env or _G
    local guard = runtime.guard({name = 'LaserSentryCooldown', step = instance.step, stop = instance.stopped,
                                 pause = instance.pause, log = note, env = env}).install()
    instance.guard, instance.env = guard, env
    instance.attach(guard.stop)
    rawset(env, 'LaserSentryCooldownInstalled', true)
    note('Laser Sentry Cooldown ' .. Cooldown.REVISION .. ' initialized (loader API ' .. tostring(loader.api) .. ').')
    -- The weapon data is usually built before addons start: write now, else look every POLL_FRAMES frames.
    if not instance.try() and not instance.failure then note('Waiting for the weapon data.') end
    return instance
end

return Cooldown
