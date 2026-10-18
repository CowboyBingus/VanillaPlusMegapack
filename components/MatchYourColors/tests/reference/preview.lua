-- Match Your Colors: the UI preview Helldivers: the local player's (the Armory's big CHARACTER view and the other UI
-- previews of the local player) and the squad cards of the loadout screen (src/lineup.lua), in the UiPreviewSystem's
-- player slots (Steam build 25480438, static research).
--
-- UiPreviewSystem [game + 0x347CE60]: occupied-slot count +50440 and bitmask +50444 (bit s); slot records
-- +49160 + 160 * s (s 0-3: players, by the player's UI slot; 4-7: thumbnail temporaries, never used here):
-- +8 body unit, +12 / +52 / +92 three arrays of 10 piece unit refs (the avatar record's layout: slot 0 helmet,
-- 1-9 armor), +132 animation, +136 body type, +140 armor kit, +144 helmet kit, +148 cape kit shown (a hovered item
-- included; KB ui-preview-system-armory-units). The Armory's slot is u32 [player manager + 948 + 32 * index]
-- (src/avatar.lua identity.ui_slot); a squad card's is its player's session slot (src/lineup.lua; KB
-- match-your-colors-squad-cards).
local ffi = require('ffi')
local band = require('bit').band

local Preview = {}

Preview.SYSTEM = 0x347CE60
Preview.MAX_SLOT = 3
Preview.RECORD_BYTES = 160
local SLOTS, GATE, UNITS = 49160, 50440, 12
-- The units compared: the 120 bytes of unit refs the recolor binds (src/avatar.lua Avatar.units), not the animation
-- word after them (v1.3 compared +12 to +135: a new animation alone rebound the preview's materials).
local UNITS_END = UNITS + 120
local BODY, ARMOR, HELMET, CAPE, KITS_END = 136, 140, 144, 148, 152
local MAX_OCCUPIED = 8
-- The read: slot 0's record to the weapon ring's tail; the compares run over 32-bit words of a record.
local GATE_OFFSET = GATE - SLOTS
local SPAN = GATE_OFFSET + 16
local WORDS = Preview.RECORD_BYTES / 4
local UNITS_W, UNITS_END_W, BODY_W, KITS_END_W = UNITS / 4, UNITS_END / 4, BODY / 4, KITS_END / 4
local BITS = {[0] = 1, 2, 4, 8}

local function at(address) return ffi.cast('const uint8_t *', address) end
local function u32(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end

-- Where the local player's preview lives: {system, slot, first (slot 0's record), record, units_at, bit}, or nil when
-- there is no preview system or the player has no UI slot. read: Avatar.reader.
function Preview.locate(read, game, ui_slot)
    if type(ui_slot) ~= 'number' or ui_slot < 0 or ui_slot > Preview.MAX_SLOT then return nil end
    local b = read(game + Preview.SYSTEM, 8)
    if not b then return nil end
    local system = u32(b, 0) + u32(b, 4) * 4294967296
    if system < 0x10000 or system >= 0x800000000000 then return nil end
    local where = {system = system, first = system + SLOTS}
    return Preview.retarget(where, ui_slot)
end

-- where moved to player slot `slot` (the local player's preview found in another slot: src/lineup.lua); where.
function Preview.retarget(where, slot)
    where.slot, where.record, where.bit = slot, where.first + Preview.RECORD_BYTES * slot, 2 ^ slot
    where.units_at = where.record + UNITS
    return where
end

-- The watch over the player slots: poll() reads the records of slots 0-3 and 4-7, the occupied count and mask and the
-- weapon preview ring's head and tail (16 bytes) in one read: the records end where the count begins, so the span
-- from slot 0's record to the ring's tail is contiguous (1,296 bytes; until the squad cards it read from the local
-- player's slot, as many bytes for slot 0). It returns the status of where.slot: 'absent' (slot free or unreadable),
-- 'kits' (the kits shown changed, or the slot appeared), 'units' (only its units changed) or 'same'; status(s) gives
-- each player slot's, changes how many slots showed, changed or went at this poll. kits() gives the helmet, armor, body
-- and cape where.slot showed at the last poll, slot_kits(s) any player slot's; ring_moved() whether the weapon ring's
-- head moved since the poll before (the game spawned or updated a preview weapon: src/weapons.lua Weapons.preview),
-- whatever the slot shows. No allocation per call.
function Preview.watch(memory, where)
    local first_at = at(where.first)
    local players = Preview.RECORD_BYTES * (Preview.MAX_SLOT + 1)
    local now, kept = ffi.new('uint8_t[?]', SPAN), ffi.new('uint8_t[?]', players)
    local now32, kept32 = ffi.cast('const uint32_t *', now), ffi.cast('const uint32_t *', kept)
    local present, statuses = {}, {}
    for s = 0, Preview.MAX_SLOT do present[s], statuses[s] = false, 'absent' end
    local head, moved = -1, false
    local self = {reads = 0, changes = 0}

    local function differs(base, first, last)
        for i = base + first, base + last - 1 do if now32[i] ~= kept32[i] then return true end end
        return false
    end

    -- Slot s at this poll (shown: its bit set): its status, its record kept when it changed.
    local function slot_status(s, shown)
        if not shown then
            if present[s] then self.changes = self.changes + 1 end
            present[s] = false
            return 'absent'
        end
        local base = WORDS * s
        local status = 'same'
        if not present[s] or differs(base, BODY_W, KITS_END_W) then
            status = 'kits'
        elseif differs(base, UNITS_W, UNITS_END_W) then
            status = 'units'
        end
        if status ~= 'same' then
            local offset = Preview.RECORD_BYTES * s
            ffi.copy(kept + offset, now + offset, Preview.RECORD_BYTES)
            self.changes = self.changes + 1
        end
        present[s] = true
        return status
    end

    function self.poll()
        self.reads, self.changes = self.reads + 1, 0
        local ok = memory.read_into(first_at, SPAN, now)
        local mask = 0
        if ok then
            local ring = u32(now, GATE_OFFSET + 8)
            moved, head = head >= 0 and ring ~= head, ring
            if u32(now, GATE_OFFSET) <= MAX_OCCUPIED then mask = u32(now, GATE_OFFSET + 4) end
        else
            moved = false
        end
        for s = 0, Preview.MAX_SLOT do statuses[s] = slot_status(s, band(mask, BITS[s]) ~= 0) end
        return statuses[where.slot]
    end

    function self.status(s) return statuses[s] end

    function self.slot_kits(s)
        local o = Preview.RECORD_BYTES * s
        return u32(kept, o + HELMET), u32(kept, o + ARMOR), u32(kept, o + BODY), u32(kept, o + CAPE)
    end

    function self.kits() return self.slot_kits(where.slot) end

    function self.units_at(s) return where.first + Preview.RECORD_BYTES * s + UNITS end

    function self.ring_moved() return moved end

    -- The next poll reports 'kits' while where.slot is shown, as if it had just appeared (after it went unwatched).
    function self.reset() present[where.slot] = false end
    return self
end

-- Locating runs on few frames: interpreted. poll() is the per-frame check and stays compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    jit.off(Preview.locate, true)
    jit.off(Preview.retarget, true)
end

return Preview
