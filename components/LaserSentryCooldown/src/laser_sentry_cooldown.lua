-- HD2-Addon: mods/cowboybingus/laser_sentry_cooldown
-- Laser Sentry Cooldown v1.1 for Helldivers 2 Steam build 25480438.
--
-- The A/LAS-98 Laser Sentry builds heat while it fires. At max heat the base game loses it, through two
-- entries of its heat record:
--   - needs_reload_after_overheat = 1 with 0 spare heat sinks: the engine never cools an overheated sentry or
--     lets it recover (WeaponHeat update 0x762F60), so its weapon reads as empty for good;
--   - overheat_ability = 2866: when the sentry overheats, the WeaponHeat presentation (0x763780) plays that
--     ability on it, on every machine in the match. The ability's script (0x1150660, case 2866 of 0x11509E0)
--     starts an effect, then about 0.8 s later queues explosion type 190 at the sentry's own sound node with the
--     sentry as its source (0x11AD240 -> 0x13C0A80). That explosion is what destroys the sentry.
-- The engine already has the other rules. With needs_reload_after_overheat = 0, the Quasar Cannon's rule, an
-- overheated weapon cools at temp_loss_per_second_overheated and fires again once its temperature is back at
-- overheat_temperature_recover (0). An overheat_ability of 0 plays no ability: 0x763780 skips it.
--
-- This addon makes those changes to the Laser Sentry's record, once per session, and adds no number of its own:
-- an overheated Laser Sentry does not explode, cools at the rate it already cools at when idle (its own
-- temp_loss_per_second, 5 heat/s in this build: about 50 s from max heat at normal planet temperature) and
-- fires again once cold. Overheating still plays the overheat sounds and voice line the record names. The same
-- engine rule also cools it at that rate while its beam powers up or winds down (about 0.7 s around a burst; the
-- base game does not cool it then). Heat gain while firing, idle cooling, damage and targeting are untouched,
-- and no other weapon is changed. There are no options.
--
-- The turret's AI also switches itself off for good when it overheats (state 6, see the turret watch below), so
-- once a Laser Sentry this machine runs has cooled down, the addon asks the game, through the AI's own pending
-- state request, to power its turret up again.
--
-- The record lives in the game's weapon data library, which the game keeps read-only. The addon checks the
-- page, makes the record writable for the writes only (9 bytes in two places), restores the protection at once
-- and reads the bytes back. After that it only counts frames, and looks once every 120 frames for Laser Sentries
-- cooling down: 1 to 3 reads while none is, no allocation. A pause (an update below this addon failed) or a stop puts the original bytes back; a
-- resume writes them again.
local Cooldown = {VERSION = '1.1'}
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

-- The change, two ranges of the record written together:
--   1. temp_loss_per_second_overheated (f32 at 0x8C) and needs_reload_after_overheat (u8 at 0x90). Vanilla:
--      400.0 (never used, because the reload flag stops all cooling) and 1. The mod's bytes: the record's own
--      temp_loss_per_second (f32 at 0x80, the cooling rate when idle), then 0. 400 would make an overheat cost
--      about 0.6 s; the sentry's own idle rate keeps the game's cooling speed.
--   2. overheat_ability (u32 at 0x248). Vanilla: 2866, the ability that blows the sentry up. The mod's value: 0.
Cooldown.COOLING_OFFSET = 0x8C
Cooldown.IDLE_COOLING_OFFSET = 0x80
Cooldown.COOLING_VANILLA = '\0\0\200\67\1' -- 400.0f (0x43C80000) little-endian, then 1
Cooldown.ABILITY_OFFSET = 0x248
Cooldown.ABILITY_VANILLA = '\50\11\0\0'    -- 2866 (0xB32) little-endian
Cooldown.ABILITY_NONE = '\0\0\0\0'
-- The vanilla bytes of both ranges, in address order: {offset, bytes}. restore writes these.
Cooldown.VANILLA_EDITS = {{Cooldown.COOLING_OFFSET, Cooldown.COOLING_VANILLA},
                          {Cooldown.ABILITY_OFFSET, Cooldown.ABILITY_VANILLA}}
-- What inspect reads: the record from its start through the overheat ability (588 bytes, one read).
Cooldown.INSPECT_SIZE = Cooldown.ABILITY_OFFSET + #Cooldown.ABILITY_VANILLA

-- The number an f32 stored little-endian in 4 bytes holds (x64 only).
local f32_cell = ffi.new('float[1]')
local function f32_value(bytes)
    ffi.copy(f32_cell, bytes, 4)
    return tonumber(f32_cell[0])
end
Cooldown.f32_value = f32_value

-- How often a frame looks for the heat table while the game has not built it yet (boot only), and how often the
-- turret watch below looks once the change is in place. An overheat lasts about 50 s, so a look every 120
-- frames (2 s at 60 frames per second) sees every one; a cooled turret powers up within one interval.
Cooldown.POLL_FRAMES = 30
Cooldown.WATCH_FRAMES = 120

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

-- Whether bytes (read from offset 0 of the record) hold every edit's bytes at its offset.
local function holds(bytes, edits)
    for _, edit in ipairs(edits) do
        local offset, value = edit[1], edit[2]
        if bytes:sub(offset + 1, offset + #value) ~= value then return false end
    end
    return true
end

-- Checks the record holds the vanilla values the change relies on. Returns 'vanilla' or 'patched' (the whole
-- change is already there), the change as edits in address order ({offset, bytes}: the record's own idle
-- cooling rate then 0 at 0x8C, and 0 at 0x248) and that rate; or nil and why. Both ranges must be vanilla or
-- both changed: anything else was written by something else. One read.
function Cooldown.inspect(api, record)
    local bytes = api.read(record, Cooldown.INSPECT_SIZE)
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
    local edits = {{Cooldown.COOLING_OFFSET, idle .. '\0'}, {Cooldown.ABILITY_OFFSET, Cooldown.ABILITY_NONE}}
    if holds(bytes, Cooldown.VANILLA_EDITS) then return 'vanilla', edits, rate end
    if holds(bytes, edits) then return 'patched', edits, rate end
    return nil, 'Laser Sentry heat record already changed by something else'
end

-- The span edits cover, from the first one's start to the last one's end: its address and length.
local function span(base, edits)
    local first, last = edits[1], edits[#edits]
    return base + first[1], last[1] + #last[2] - first[1]
end

-- The protection of the region holding [address, address + length) when that range lies inside one committed
-- private region, else nil and why. One VirtualQuery.
local function private_protection(api, address, length)
    local state, protection, kind, base, size = api.page(address)
    if not state then return nil, 'page query failed' end
    if state ~= MEM_COMMIT or kind ~= MEM_PRIVATE then
        return nil, format('not committed private memory (state %#x, type %#x)', state, kind)
    end
    if address < base or address + length > base + size then return nil, 'write would leave the region' end
    return protection
end

-- Writes the edits in order and stops at the first that fails. Returns whether all landed and whether any did.
local function write_edits(api, base, edits)
    local landed = false
    for _, edit in ipairs(edits) do
        if not api.write(base + edit[1], edit[2]) then return false, landed end
        landed = true
    end
    return true, landed
end

-- The edits through a read-only span: read-write for the writes only, then the previous protection back.
-- Returns true, or false, why, whether the protection is lost and whether any write landed.
local function write_read_only(api, base, edits)
    local address, length = span(base, edits)
    local previous = api.protect(address, length, PAGE_READWRITE)
    if not previous then return false, 'page protection change refused' end
    local written, landed = write_edits(api, base, edits)
    if not api.protect(address, length, previous) then
        return false, 'page protection could not be restored', true, landed
    end
    if not written then return false, 'write failed', false, landed end
    return true
end

-- Whether every edit reads back, in one read of their span into the view buffer (no allocation).
local function reads_back(api, base, edits)
    local address, length = span(base, edits)
    if not api.view(address, length) then return false end
    local bytes, start = api.bytes, edits[1][1]
    for _, edit in ipairs(edits) do
        local from, value = edit[1] - start, edit[2]
        for i = 1, #value do
            if bytes[from + i - 1] ~= value:byte(i) then return false end
        end
    end
    return true
end

-- Writes edits ({offset, bytes} from base, in address order) into the weapon data library: committed private
-- memory that the game keeps read-only. The span they cover is checked right before the writes (one
-- VirtualQuery), made writable for the writes only and given its protection back at once (one VirtualProtectEx
-- each way, whatever the number of edits); a span that is already private read-write is written directly. The
-- edits are read back in one read. Returns true, or false, why, whether the original protection could not be
-- restored and whether any write landed (then the caller must put the old bytes back).
function Cooldown.protected_write(api, base, edits)
    local address, length = span(base, edits)
    local protection, why = private_protection(api, address, length)
    if not protection then return false, why end
    if protection == PAGE_READWRITE then
        local written, landed = write_edits(api, base, edits)
        if not written then return false, 'write failed', false, landed end
    elseif protection == PAGE_READONLY then
        local written, problem, lost, landed = write_read_only(api, base, edits)
        if not written then return false, problem, lost, landed end
    else
        return false, format('unexpected page protection %#x', protection)
    end
    if not reads_back(api, base, edits) then return false, 'write did not read back', false, true end
    return true
end

-- After an overheat, the turret itself. The Laser Sentry's AI behavior (behavior 308 in this build, per-frame
-- update 0x472F60) leaves its firing state (13, 0x32A3D0) for state 6 the moment its weapon reports overheated,
-- and has no update for state 6: in the base game the overheat ability's explosion follows, so nothing ever
-- needed to leave it. With the cooling rule above the weapon recovers, but the turret would stay switched off.
-- So once an overheated Laser Sentry whose behavior runs on this machine (the machine that owns it, 0x843930)
-- has cooled down, the addon asks the game to move its behavior from state 6 to state 7: the state the game
-- enters to power the turret up after it deploys and from idle, whose update hands over through the game's own
-- state changes (7 -> 8, 9 or 10, a look-around, -> 2 or 3, idle or aware). The ask is the behavior's pending
-- state request (state block +4, -1 when none): before each behavior update the behavior manager applies a
-- pending request through set_state when the behavior allows it (0x843040 -> 0x4962C0, which refuses only state
-- 12 for this behavior -> 0x48EE50 -> 0x32B6B0), so the game itself makes the change, enter action and
-- replication included, and clears the request.
Cooldown.HEAT_MANAGER_RVA = 0x3326D48     -- WeaponHeat manager: +20 instances, +64 records, +88 states (12 bytes, +8 overheated)
Cooldown.BEHAVIOR_MANAGER_RVA = 0x3326740 -- behavior manager (world + 0xEEBA08, set by 0x568230), layout below
Cooldown.BEHAVIOR_ID, Cooldown.BEHAVIOR_SIZE = 308, 504
Cooldown.STATE_STUCK = 6
Cooldown.POWER_UP = '\7\0\0\0' -- state 7, as the pending request at block +12
Cooldown.NO_REQUEST = 0xFFFFFFFF
Cooldown.MAX_INSTANCES = 160 -- heat instances one look covers (their 12-byte states fit the 2 KB view)
Cooldown.MAX_PROBES = 64
local POWER_UP_EDITS = {{12, Cooldown.POWER_UP}}
local MAX_MAP = 67108864 -- 2^26: slot arithmetic stays exact in doubles

-- The 64-bit value in words (a uint32 view) at word index (two halves).
local function qword(words, index)
    return words[index] + words[index + 1] * HIGH
end

local function power_of_two(value)
    if value < 1 or value > MAX_MAP then return false end
    while value % 2 == 0 do value = value / 2 end
    return value == 1
end

-- The slot index of entity id in an open-addressing map of {u32 key, u32 value} entries, probed as the engine
-- does: (k + id * multiplier) & (capacity - 1), stopping at the empty key. One view per probe. The value, or nil.
local function map_value(api, entries, capacity, empty, multiplier, id)
    local start = (id % capacity) * (multiplier % capacity) % capacity
    for k = 0, math.min(capacity, Cooldown.MAX_PROBES) - 1 do
        if not api.view(entries + 8 * ((start + k) % capacity), 8) then return nil end
        local key, value = api.words[0], api.words[1]
        if key == empty then return nil end
        if key == id then return value end
    end
    return nil
end

-- The behavior manager, read at +48 (56 bytes): +52 instances, +64 entity id map (entries, then capacity, empty
-- key and multiplier at +72/+76/+80), +88 entity record pointers, +96 504-byte instance blocks (+0 behavior id,
-- +8 state, +12 pending state request, -1 when none, +16 last state set). The block of the behavior that runs
-- the entity id whose record is at record, or nil and why.
function Cooldown.behavior_block(api, game, id, record)
    local manager = api.u64(game + Cooldown.BEHAVIOR_MANAGER_RVA)
    if not valid_address(manager) or not api.view(manager + 48, 56) then return nil, 'behavior manager unreadable' end
    local words = api.words
    local count, entries, capacity, empty, multiplier = words[1], qword(words, 4), words[6], words[7], words[8]
    local records, blocks = qword(words, 10), qword(words, 12)
    if not (power_of_two(capacity) and valid_address(entries) and valid_address(records) and valid_address(blocks)) then
        return nil, 'unexpected behavior manager'
    end
    local index = map_value(api, entries, capacity, empty, multiplier, id)
    if not index or index >= count then return nil, 'no behavior' end
    if api.u64(records + 8 * index) ~= record then return nil, 'behavior of another entity' end
    return blocks + Cooldown.BEHAVIOR_SIZE * index
end

-- Asks the game to move the Laser Sentry behavior of entity id (record at record) from state 6 to state 7: the
-- pending state request, written only while none is pending. True, or false and why.
function Cooldown.power_up(api, game, id, record)
    local block, why = Cooldown.behavior_block(api, game, id, record)
    if not block then return false, why end
    if not api.view(block, 20) then return false, 'behavior unreadable' end
    local behavior, state, pending = api.words[0], api.words[2], api.words[3]
    if behavior ~= Cooldown.BEHAVIOR_ID then return false, format('unexpected behavior %d', behavior) end
    if state ~= Cooldown.STATE_STUCK then return false, format('turret in state %d', state) end
    if pending ~= Cooldown.NO_REQUEST then return false, format('turret state %d already requested', pending) end
    local written, problem = Cooldown.protected_write(api, block, POWER_UP_EDITS)
    if not written then return false, problem end
    return true
end

-- The turret watch, one look every WATCH_FRAMES frames while the change is in place. The cheapest reads come
-- first: the WeaponHeat manager and its 96-byte header (the instance count), then one read of every instance's
-- 12-byte replicated state. With nothing overheated and no Laser Sentry cooling down, that is the whole look.
-- Otherwise one read of the entity record pointers; a record read for each newly overheated instance (a Laser
-- Sentry this machine runs is watched, anything else is skipped while it stays overheated); and for each
-- watched sentry that has cooled down, power_up (a 4-byte request the game applies on its next update). No
-- allocation per look once its tables have grown.
function Cooldown.watcher(api, game, note)
    local self = {watched = {}, by_pointer = {}, others = {}, others_count = 0, generation = 0, flags = {},
                  pointers = {}, repairs = 0}

    local function forget(id)
        local pointer = self.watched[id]
        self.watched[id] = nil
        if pointer then self.by_pointer[pointer] = nil end
    end

    local function clear()
        for id in pairs(self.watched) do forget(id) end
    end

    local function remember_other(pointer)
        if self.others_count >= 256 then
            for key in pairs(self.others) do self.others[key] = nil end
            self.others_count = 0
        end
        self.others[pointer] = self.generation
        self.others_count = self.others_count + 1
    end

    -- The instance count, entity record array and state array of the WeaponHeat manager, or nil (2 reads).
    local function heat_instances()
        local heat = api.u64(game + Cooldown.HEAT_MANAGER_RVA)
        if not valid_address(heat) or not api.view(heat, 96) then return nil end
        local words = api.words
        local count = words[5]
        if count == 0 or count > Cooldown.MAX_INSTANCES then return nil end
        return count, qword(words, 16), qword(words, 22)
    end

    -- Every instance's overheated flag into self.flags; the number set, or nil (1 read).
    local function read_flags(states, count)
        if not valid_address(states) or not api.view(states, 12 * count) then return nil end
        local bytes, flags, hot = api.bytes, self.flags, 0
        for index = 0, count - 1 do
            local value = bytes[12 * index + 8]
            flags[index] = value
            if value ~= 0 then hot = hot + 1 end
        end
        return hot
    end

    -- Every instance's entity record pointer into self.pointers (1 read).
    local function read_pointers(records, count)
        if not valid_address(records) or not api.view(records, 8 * count) then return false end
        local words, pointers = api.words, self.pointers
        for index = 0, count - 1 do pointers[index] = qword(words, 2 * index) end
        return true
    end

    -- The entity id when the record at pointer is a Laser Sentry whose behavior runs here (owned, bit 0, and
    -- simulated here, bit 1 clear), else nil (1 read).
    local function owned_sentry(pointer)
        if not valid_address(pointer) or not api.view(pointer, 24) then return nil end
        local words = api.words
        if words[0] ~= Cooldown.RESOURCE_LOW or words[1] ~= Cooldown.RESOURCE_HIGH then return nil end
        if api.bytes[20] % 4 ~= 1 then return nil end
        return words[2]
    end

    -- Newly overheated instances: a Laser Sentry this machine runs is watched; anything else is skipped while
    -- it stays overheated (its record is read again once it has cooled and overheats anew).
    local function track(count)
        local flags, pointers, others, generation = self.flags, self.pointers, self.others, self.generation
        for index = 0, count - 1 do
            local pointer = pointers[index]
            if flags[index] ~= 0 and not self.by_pointer[pointer] then
                local seen = others[pointer]
                if seen and seen >= generation - 1 then
                    others[pointer] = generation
                else
                    local id = owned_sentry(pointer)
                    if id then
                        self.watched[id], self.by_pointer[pointer] = pointer, id
                    else
                        remember_other(pointer)
                    end
                end
            end
        end
    end

    local function index_of(pointer, count)
        local pointers = self.pointers
        for index = 0, count - 1 do
            if pointers[index] == pointer then return index end
        end
        return nil
    end

    local function repair(id, pointer)
        local ok, why = Cooldown.power_up(api, game, id, pointer)
        if ok then
            self.repairs = self.repairs + 1
            note(format('Laser Sentry %d cooled down: its turret powers up again.', id))
        else
            note(format('Laser Sentry %d cooled down; its turret was left as it is (%s).', id, why))
        end
    end

    -- Watched sentries: gone ones are dropped; cooled ones (overheated flag clear) get their turret back.
    local function recover(count)
        for id, pointer in pairs(self.watched) do
            local index = index_of(pointer, count)
            if not index then
                forget(id)
            elseif self.flags[index] == 0 then
                forget(id)
                if owned_sentry(pointer) == id then repair(id, pointer) end
            end
        end
    end

    function self.poll()
        self.generation = self.generation + 1
        local count, records, states = heat_instances()
        if not count then return clear() end
        local hot = read_flags(states, count)
        if not hot or (hot == 0 and next(self.watched) == nil) then return end
        if not read_pointers(records, count) then return end
        if hot > 0 then track(count) end
        if next(self.watched) ~= nil then recover(count) end
    end

    return self
end

-- One instance per session. api: the adapter below (or a test double); game: game.dll's base as a number;
-- note(line): the log. The instance's step runs every frame through the shared runtime's guard.
function Cooldown.new(api, game, note)
    local self = {status = 'waiting for the weapon data', patched = false, record = nil, writes = 0,
                  polls = 0, frames = 0, interval = Cooldown.POLL_FRAMES, failure = nil}
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
        local found, edits, rate = Cooldown.inspect(api, record)
        if not found then return refuse(edits) end
        self.record, self.edits = record, edits
        if found == 'vanilla' then
            local written, problem, lost, landed = Cooldown.protected_write(api, record, edits)
            if not written then
                if lost then self.protection_lost = true end
                -- Bytes that landed are put back by the stop that follows (restore), whatever else failed.
                if landed then self.patched = true end
                return refuse(problem)
            end
            self.writes = self.writes + 1
        end
        self.patched, self.interval = true, Cooldown.WATCH_FRAMES
        self.status = 'active'
        note(format('Laser Sentry heat record %s: an overheated Laser Sentry no longer explodes, cools at its own '
                    .. 'idle rate (%g heat/s, %g s from max heat %d at normal planet temperature) and fires again.',
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

    local watch = Cooldown.watcher(api, game, note)
    self.watch = watch

    -- Every frame, before the game's update: a frame counter, and one look every interval frames. While the
    -- game has not built its weapon data (boot) the look is for the heat table, every POLL_FRAMES; once the
    -- change is in place it is the turret watch, every WATCH_FRAMES.
    function self.step()
        local frames = self.frames + 1
        if frames < self.interval then self.frames = frames; return end
        self.frames = 0
        if self.failure then return end
        if self.patched then watch.poll() else self.try() end
    end

    -- Puts the vanilla bytes back. Raises when that fails, so the guard stops the addon (pause) or keeps
    -- the failure (stop).
    function self.restore()
        if not self.patched then return end
        local written, problem = Cooldown.protected_write(api, self.record, Cooldown.VANILLA_EDITS)
        if not written then error('restore failed: ' .. problem, 0) end
        self.writes = self.writes + 1
        self.patched, self.interval = false, Cooldown.POLL_FRAMES
        if not self.failure then self.status = 'restored' end
    end

    -- The guard's pause: restore and start afresh; the next step after the resume looks again at once.
    function self.pause(reason)
        self.restore()
        self.frames = self.interval - 1
        self.status = 'paused: ' .. tostring(reason)
        note('Paused (' .. tostring(reason) .. '); the vanilla heat rules are back until the addon resumes.')
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
-- view, page and protect allocate nothing; read allocates only the string it returns.
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
    local view_size = 2048
    local view = ffi.new('uint8_t[?]', view_size)
    -- The turret watch decodes what api.view read straight from these (bytes, and 32-bit words at multiples of 4).
    local api = {bytes = view, words = ffi.cast('uint32_t *', view)}

    -- Reads size bytes at address into the view buffer, replacing what it held: true when every byte was read.
    -- One ReadProcessMemory and no allocation.
    function api.view(address, size)
        if size < 1 or size > view_size then return false end
        return read_memory(process, address, view, size, done) ~= 0 and done[0] == size and done[1] == 0
    end

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

-- Everything but the per-frame step runs on one frame in WATCH_FRAMES at most (the turret watch) or on a few
-- frames only (startup, a pause, a stop, a turret repair). All of it stays interpreted: the functions defined
-- inside it, the helpers it calls and the adapter's calls included. Otherwise a helper the interpreted look
-- calls would turn hot over a session and become a trace of its own in the LuaJIT code cache the game and every
-- mod share. Only the step, a frame counter, is left to the compiler.
local HELPERS = {f32_value, u32, unsigned, valid_address, holds, span, private_protection, write_edits,
                 write_read_only, reads_back, qword, power_of_two, map_value}
local function interpreted(functions)
    if type(jit) ~= 'table' or type(jit.off) ~= 'function' then return end
    for _, fn in pairs(functions) do
        if type(fn) == 'function' then pcall(jit.off, fn, true) end
    end
end
interpreted({interpreted})
-- The whole module but the instance's step: every function above, the instance's (Cooldown.new, recursively,
-- then the step back on its own) and the adapter's.
local function interpreted_but_step(instance, note)
    interpreted(HELPERS)
    interpreted(Cooldown)
    interpreted(instance.api)
    interpreted({note})
    if type(jit) == 'table' and type(jit.on) == 'function' then pcall(jit.on, instance.step) end
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
    interpreted_but_step(instance, note)
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
