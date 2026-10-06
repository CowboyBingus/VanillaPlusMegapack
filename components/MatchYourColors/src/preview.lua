-- Match Your Colors: the local player's UI preview Helldiver: the Armory's big CHARACTER view and the other UI
-- previews of the local player (Steam build 25480438, static research).
--
-- UiPreviewSystem [game + 0x347CE60]: occupied-slot count +50440 and bitmask +50444 (bit s); slot records
-- +49160 + 160 * s (s 0-3: players, by the player's UI slot; 4-7: thumbnail temporaries, never used here):
-- +8 body unit, +12 / +52 / +92 three arrays of 10 piece unit refs (the avatar record's layout: slot 0 helmet,
-- 1-9 armor), +136 body type, +140 armor kit, +144 helmet kit, +148 cape kit shown (a hovered item included).
-- The local player's slot is u32 [player manager + 948 + 32 * index] (src/avatar.lua identity.ui_slot).
local ffi = require('ffi')
local band = require('bit').band

local Preview = {}

Preview.SYSTEM = 0x347CE60
Preview.MAX_SLOT = 3
Preview.RECORD_BYTES = 160
local SLOTS, GATE, UNITS = 49160, 50440, 12
local BODY, ARMOR, HELMET, KITS_END = 136, 140, 144, 148 -- the cape (+148) is never recolored
local MAX_OCCUPIED = 8

local function at(address) return ffi.cast('const uint8_t *', address) end
local function u32(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end

-- Where the local player's preview lives: {system, slot, gate (address of count and mask), record, units_at, bit},
-- or nil when there is no preview system or the player has no UI slot. read: Avatar.reader.
function Preview.locate(read, game, ui_slot)
    if type(ui_slot) ~= 'number' or ui_slot < 0 or ui_slot > Preview.MAX_SLOT then return nil end
    local b = read(game + Preview.SYSTEM, 8)
    if not b then return nil end
    local system = u32(b, 0) + u32(b, 4) * 4294967296
    if system < 0x10000 or system >= 0x800000000000 then return nil end
    local record = system + SLOTS + Preview.RECORD_BYTES * ui_slot
    return {system = system, slot = ui_slot, gate = system + GATE, record = record, units_at = record + UNITS,
            bit = 2 ^ ui_slot}
end

-- The watch over the slot: poll() reads the occupied mask (8 bytes) and, when the slot is occupied, its record
-- (160 bytes). It returns 'absent' (slot free or unreadable), 'kits' (the kits shown changed, or the slot
-- appeared), 'units' (only its units changed) or 'same'. kits() gives the helmet, armor and body shown at the
-- last poll. No allocation per call.
function Preview.watch(memory, where)
    local gate_at, record_at = at(where.gate), at(where.record)
    local gate = ffi.new('uint32_t[2]')
    local now, kept = ffi.new('uint8_t[?]', Preview.RECORD_BYTES), ffi.new('uint8_t[?]', Preview.RECORD_BYTES)
    local present = false
    local self = {reads = 0}

    local function differs(first, last)
        for i = first, last - 1 do if now[i] ~= kept[i] then return true end end
        return false
    end

    function self.poll()
        self.reads = self.reads + 1
        if not memory.read_into(gate_at, 8, gate) or gate[0] > MAX_OCCUPIED or band(gate[1], where.bit) == 0 then
            present = false
            return 'absent'
        end
        self.reads = self.reads + 1
        if not memory.read_into(record_at, Preview.RECORD_BYTES, now) then
            present = false
            return 'absent'
        end
        local status = 'same'
        if not present or differs(BODY, KITS_END) then
            status = 'kits'
        elseif differs(UNITS, BODY) then
            status = 'units'
        end
        ffi.copy(kept, now, Preview.RECORD_BYTES)
        present = true
        return status
    end

    function self.kits()
        return u32(kept, HELMET), u32(kept, ARMOR), u32(kept, BODY)
    end
    return self
end

-- Locating runs on few frames: interpreted. poll() is the per-frame check and stays compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    jit.off(Preview.locate, true)
end

return Preview
