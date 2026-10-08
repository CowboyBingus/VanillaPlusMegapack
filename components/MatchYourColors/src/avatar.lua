-- Match Your Colors: the local player's Helldiver in game memory (Steam build 25480438; chain verified live
-- on the ship).
--
-- Player manager [game + 0x3326468]: player count +132, player entity records +232 + 8 * i (24 bytes: id +8,
-- flags +20 with bit 0 = owned by this machine), the map +208 from a player's entity id to its index, the
-- player's peer id +712 + 56 * index, its Helldiver's unit +936 + 32 * index and its UI preview slot
-- +948 + 32 * index (src/preview.lua). Customization manager
-- [game + 0x33264F8]: the map +2352 from the player's entity id to its record, applied kits +2412 + 68 * r
-- (+0 body, +4 helmet, +8 cape, +12 armor). Entities [game + 0x346BF98]: the map +0xF22EC8 from a unit to its
-- entity, entity records +0xF32F18 + 24 * e (avatar resource 0x4d1c334d294dfa97, id +8, flags +20). Avatars
-- [game + 0x3326D20]: the map +248 from an avatar's entity id to its index, records +5532272 + 440 * index with
-- three arrays of 10 unit refs (+220 piece type armor, +260 undergarment, +300 accessory; slot 0 helmet,
-- slots 1-9 armor). Previews [game + 0x346D580]: per-player slots +2080 + 2184 * s (peer id +0, entry count
-- +64, 132-byte entries from +68 with the same arrays at +12/+52/+92).
--
-- The local player's records drive the recolor; other players' records are read only for Sync With Mod Users
-- (Avatar.players, Avatar.resolve_remote; src/remote.lua). Other players' preview slots are never touched.
-- Maps are open-addressing u32 tables {data +0, capacity +8, empty key +12, multiplier +16} probed at
-- (capacity - 1) & (key * multiplier + i), as the game probes them.
local ffi = require('ffi')

local Avatar = {}

Avatar.PLAYERS, Avatar.CUSTOMIZATION, Avatar.ENTITIES, Avatar.AVATARS, Avatar.PREVIEWS =
    0x3326468, 0x33264F8, 0x346BF98, 0x3326D20, 0x346D580
local P_COUNT, P_ENTITIES, P_MAP, P_PEERS, P_UNITS, P_UI_SLOT = 132, 232, 208, 712, 936, 948
local C_MAP, C_APPLIED, C_APPLIED_SIZE = 2352, 2412, 68
local E_MAP, E_RECORDS = 0xF22EC8, 0xF32F18
local A_MAP, A_COUNT, A_RECORDS, A_RECORD_SIZE, A_UNITS = 248, 0x6c, 5532272, 440, 220
local V_SLOTS, V_SLOT_SIZE, V_SLOT_COUNT, V_COUNT, V_ENTRIES, V_ENTRY_SIZE, V_UNITS = 2080, 2184, 5, 64, 68, 132, 12
Avatar.UNIT_BYTES = 120 -- three arrays of 10 unit refs
Avatar.MAX_PREVIEWS = 16
local AVATAR_LOW, AVATAR_HIGH = 0x294dfa97, 0x4d1c334d
local MAX_PLAYERS, MAX_PROBES = 8, 64
local HIGH = 4294967296

local function at(address) return ffi.cast('const uint8_t *', address) end
local function u32(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
Avatar.u32 = u32

-- The low 32 bits of a * b for 32-bit a and b, exact in doubles.
local function low32_product(a, b)
    local lo = a % 65536
    return (lo * b + (((a - lo) / 65536 * b) % 65536) * 65536) % HIGH
end
Avatar.low32_product = low32_product

-- Reads through bingus_memory's read_into into one reused buffer: read(address, size) -> buffer or nil
-- (valid until the next read). Make one per session and pass it to resolve and preview_slot. The api takes
-- pointers: one pointer object per address is made once and kept (the chain's addresses are stable; the
-- cache starts over at 1024), so repeated checks allocate nothing (as Consistent Vaulting does).
local POINTER = ffi.typeof('const uint8_t *')
function Avatar.reader(memory)
    local buffer = ffi.new('uint8_t[256]')
    local pointers, cached = {}, 0
    return function(address, size)
        if address < 0x10000 or address >= 0x800000000000 then return nil end
        local p = pointers[address]
        if not p then
            if cached >= 1024 then pointers, cached = {}, 0 end
            p = ffi.cast(POINTER, address)
            pointers[address], cached = p, cached + 1
        end
        if memory.read_into(p, size, buffer) then return buffer end
        return nil
    end
end

local function pointer(read, address)
    local b = read(address, 8)
    if not b then return nil end
    local value = u32(b, 0) + u32(b, 4) * HIGH
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end

local function word(read, address)
    local b = read(address, 4)
    return b and u32(b, 0) or nil
end

-- The value stored for key in the game map at `address`, or nil.
function Avatar.lookup(read, address, key)
    local b = read(address, 20)
    if not b then return nil end
    local data = u32(b, 0) + u32(b, 4) * HIGH
    local capacity, empty, multiplier = u32(b, 8), u32(b, 12), u32(b, 16)
    if capacity == 0 or capacity > 4194304 or data < 0x10000 then return nil end
    local start = low32_product(key, multiplier)
    for i = 0, math.min(capacity, MAX_PROBES) - 1 do
        local slot = read(data + 8 * ((start + i) % capacity), 8)
        if not slot then return nil end
        local found = u32(slot, 0)
        if found == key then return u32(slot, 4) end
        if found == empty then return nil end
    end
    return nil
end

-- The player owned by this machine: its entity id, peer and Helldiver unit into out; true or nil and why.
local function local_player(read, game, out)
    local players = pointer(read, game + Avatar.PLAYERS)
    if not players then return nil, 'no player manager' end
    local count = word(read, players + P_COUNT)
    if not count or count == 0 or count > MAX_PLAYERS then return nil, 'no players' end
    local entity_id
    for i = 0, count - 1 do
        local entity = pointer(read, players + P_ENTITIES + 8 * i)
        local b = entity and read(entity, 24)
        if b and b[20] % 2 == 1 then entity_id = u32(b, 8) break end
    end
    if not entity_id then return nil, 'no local player' end
    local index = Avatar.lookup(read, players + P_MAP, entity_id)
    if not index or index >= MAX_PLAYERS then return nil, 'local player not indexed' end
    local peer = read(players + P_PEERS + 56 * index, 8)
    out.peer_low, out.peer_high = peer and u32(peer, 0), peer and u32(peer, 4)
    local unit = word(read, players + P_UNITS + 32 * index)
    if not unit or unit == 0 then return nil, 'no local Helldiver' end
    out.player, out.unit, out.ui_slot = entity_id, unit, word(read, players + P_UI_SLOT + 32 * index)
    return true
end

-- The player's applied kits (body, helmet, cape, armor) into out; true or nil and why.
local function applied_kits(read, game, out)
    local customization = pointer(read, game + Avatar.CUSTOMIZATION)
    local record = customization and Avatar.lookup(read, customization + C_MAP, out.player)
    if not record then return nil, 'no customization record' end
    local kits = read(customization + C_APPLIED + C_APPLIED_SIZE * record, 16)
    if not kits then return nil, 'customization record unreadable' end
    out.record, out.body, out.helmet, out.cape, out.armor = record, u32(kits, 0), u32(kits, 4), u32(kits, 8), u32(kits, 12)
    return true
end

-- The Helldiver's avatar record (an avatar entity owned by this machine, or with remote any player's) into out;
-- true or nil and why.
local function avatar_record(read, game, out, remote)
    local entities = pointer(read, game + Avatar.ENTITIES)
    local entity_index = entities and Avatar.lookup(read, entities + E_MAP, out.unit)
    if not entity_index then return nil, 'Helldiver entity not found' end
    local entity = read(entities + E_RECORDS + 24 * entity_index, 24)
    if not entity or u32(entity, 0) ~= AVATAR_LOW or u32(entity, 4) ~= AVATAR_HIGH then
        return nil, 'not an avatar entity'
    end
    if not remote and entity[20] % 2 == 0 then return nil, 'Helldiver not owned by this machine' end
    local avatar_id = u32(entity, 8)
    local avatars = pointer(read, game + Avatar.AVATARS)
    local index = avatars and Avatar.lookup(read, avatars + A_MAP, avatar_id)
    local count = avatars and word(read, avatars + A_COUNT)
    if not index or not count or index >= count then return nil, 'avatar not indexed' end
    out.avatar, out.avatar_index = avatar_id, index
    out.units_at = avatars + A_RECORDS + A_RECORD_SIZE * index + A_UNITS
    return true
end

local STEPS = {local_player, applied_kits, avatar_record}

-- The local player: {player, unit, peer, record and applied kits, avatar id and index, the avatar record's
-- unit address, the preview manager} or nil and why. One call is about 20 reads. out: a table to fill
-- (reused; default new).
function Avatar.resolve(memory, game, read, out)
    read = read or Avatar.reader(memory)
    out = out or {}
    for _, step in ipairs(STEPS) do
        local ok, why = step(read, game, out)
        if not ok then return nil, why end
    end
    out.previews = pointer(read, game + Avatar.PREVIEWS)
    return out
end

-- One player record (player manager entity record i) as {player = entity id, index, local (bool), peer_low,
-- peer_high, unit}, or nil when it has no Helldiver.
local function player_at(read, players, i)
    local entity = pointer(read, players + P_ENTITIES + 8 * i)
    local b = entity and read(entity, 24)
    if not b then return nil end
    local entity_id, owned = u32(b, 8), b[20] % 2 == 1
    local index = Avatar.lookup(read, players + P_MAP, entity_id)
    if not index or index >= MAX_PLAYERS then return nil end
    local peer = read(players + P_PEERS + 56 * index, 8)
    if not peer then return nil end
    local peer_low, peer_high = u32(peer, 0), u32(peer, 4)
    local unit = word(read, players + P_UNITS + 32 * index)
    if not unit or unit == 0 then return nil end
    return {player = entity_id, index = index, ['local'] = owned, peer_low = peer_low, peer_high = peer_high, unit = unit}
end

-- Every player with a Helldiver (the local one marked local): a list of player_at records. About 6 reads each.
function Avatar.players(read, game)
    local out = {}
    local players = pointer(read, game + Avatar.PLAYERS)
    local count = players and word(read, players + P_COUNT)
    if not count or count == 0 or count > MAX_PLAYERS then return out end
    for i = 0, count - 1 do
        local found = player_at(read, players, i)
        if found then out[#out + 1] = found end
    end
    return out
end

-- Another player's Helldiver (a player record from Avatar.players): its applied kits and avatar record as resolve
-- gives them for the local player, or nil and why. Its avatar entity is not owned by this machine.
function Avatar.resolve_remote(read, game, player, out)
    out = out or {}
    out.player, out.unit, out.peer_low, out.peer_high = player.player, player.unit, player.peer_low, player.peer_high
    local ok, why = applied_kits(read, game, out)
    if not ok then return nil, why end
    ok, why = avatar_record(read, game, out, true)
    if not ok then return nil, why end
    return out
end

-- A copy of an identity (resolve may refill the table it was given).
function Avatar.copy(identity)
    local out = {}
    for k, v in pairs(identity) do out[k] = v end
    return out
end

-- The local player's preview slot address, or nil (the slot whose peer id is the player's).
function Avatar.preview_slot(memory, identity, read)
    read = read or Avatar.reader(memory)
    if not identity.previews or not identity.peer_low then return nil end
    for s = 0, V_SLOT_COUNT - 1 do
        local slot = identity.previews + V_SLOTS + V_SLOT_SIZE * s
        local b = read(slot, 8)
        if b and u32(b, 0) == identity.peer_low and u32(b, 4) == identity.peer_high
            and (identity.peer_low ~= 0 or identity.peer_high ~= 0) then
            return slot
        end
    end
    return nil
end

-- The units to recolor: {{unit, type, slot, preview (bool)}, ...} from the avatar's arrays and the local
-- preview slot's entries; slots: {from, to} (0 helmet, 1-9 armor).
function Avatar.units(memory, identity, slot, first, last)
    local out = {}
    local buffer = ffi.new('uint8_t[?]', Avatar.UNIT_BYTES)
    local function collect(address, preview)
        if not memory.read_into(at(address), Avatar.UNIT_BYTES, buffer) then return end
        for t = 0, 2 do
            for s = first, last do
                local unit = u32(buffer, 40 * t + 4 * s)
                if unit ~= 0 and unit ~= 0xFFFFFFFF then
                    out[#out + 1] = {unit = unit, type = t, slot = s, preview = preview}
                end
            end
        end
    end
    collect(identity.units_at, false)
    if slot then
        local count_bytes = ffi.new('uint8_t[4]')
        if memory.read_into(at(slot + V_COUNT), 4, count_bytes) then
            local count = math.min(u32(count_bytes, 0), Avatar.MAX_PREVIEWS)
            for n = 0, count - 1 do collect(slot + V_ENTRIES + V_ENTRY_SIZE * n + V_UNITS, true) end
        end
    end
    return out
end

-- The idle check: one read of the avatar's 120 unit bytes and, with a preview slot, one of its entry count
-- (plus its entries while it has any). watch(identity, slot) builds it; changed() is true when anything
-- differs from the last call (the first call reports a change). No allocation per call.
function Avatar.watch(memory, identity, slot)
    local units_at, copies_at = at(identity.units_at), slot and at(slot + V_COUNT) or nil
    local now, kept = ffi.new('uint32_t[30]'), ffi.new('uint32_t[30]')
    -- The body-copy slot's entry count (+64) and its entries (+68, 132 bytes each) are adjacent: one read of both.
    local copies_size = 4 + V_ENTRY_SIZE * Avatar.MAX_PREVIEWS
    local copies_now, copies_kept = ffi.new('uint8_t[?]', copies_size), ffi.new('uint8_t[?]', copies_size)
    local primed, copies_primed = false, false
    local self = {reads = 0}

    local function same_units()
        for i = 0, 29 do if now[i] ~= kept[i] then return false end end
        return true
    end
    -- The count and the entries in use, against the last read.
    local function same_copies()
        local count = math.min(copies_now[0] + copies_now[1] * 256 + copies_now[2] * 65536 + copies_now[3] * 16777216,
                                Avatar.MAX_PREVIEWS)
        for i = 0, 3 + V_ENTRY_SIZE * count do if copies_now[i] ~= copies_kept[i] then return false end end
        return true
    end

    -- The body-copy slot's count and entries: true when they changed (or cannot be read) since its last read.
    local function copies_changed()
        self.reads = self.reads + 1
        if not memory.read_into(copies_at, copies_size, copies_now) then return true end
        if copies_primed and same_copies() then return false end
        ffi.copy(copies_kept, copies_now, copies_size)
        copies_primed = true
        return true
    end

    -- True when the units changed (or cannot be read) since the last call, or, when `copies` is true, the body-copy
    -- slot did since its last read. The caller reads the slot on every other frame: the game moves the avatar's
    -- (recolored) units into it at death, or spawns new units there; one more frame before those are recolored.
    function self.changed(copies)
        self.reads = self.reads + 1
        local ok = memory.read_into(units_at, 120, now)
        local changed = not ok or not primed or not same_units()
        if changed and ok then ffi.copy(kept, now, 120) end
        primed = true
        if copies and copies_at and copies_changed() then changed = true end
        return changed
    end
    return self
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({low32_product, Avatar.reader, pointer, word, Avatar.lookup, local_player, applied_kits, avatar_record,
        Avatar.resolve, player_at, Avatar.players, Avatar.resolve_remote, Avatar.copy, Avatar.preview_slot,
        Avatar.units}) do
        jit.off(fn, true)
    end
end

return Avatar
