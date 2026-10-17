-- HD2-Addon: mods/cowboybingus/holster_your_shield
-- Holster Your Shield v1.0 for Helldivers 2 Steam build 25480438.
--
-- With a one-handed weapon in hand the game puts a shield backpack (the SH-20 Ballistic Shield or the SH-51
-- Directional Shield: equipment type 25) into the left hand. The shield in hand is the Helldiver's "held
-- carryable" in carry mode 2 (inventory row +20 and +32); on the back nothing is held. The game moves it with two
-- calls, 0x9ABC30 (the held carryable) and 0x9AC8E0 (the carry mode), and tells the other players with
-- rpc_set_held_carryable (0xBE20B0). Switching to a two-handed weapon stows it that way (0xA95910), wielding a
-- one-handed weapon draws it that way (0xA95A90).
--
-- This addon makes the same calls when the player presses Backpack Function (Avatar action 37, after rebinding
-- and controller processing) while wearing a shield backpack:
--   - shield in hand: it goes on the back, and stays there: when the game draws it again (a weapon switch, a
--     dropped objective, the re-wield after an action), the addon stows it again on the next frame;
--   - pressed again: it comes back to the hand if the weapon in hand is one-handed and nothing else is held
--     (the game's own conditions); otherwise the game draws it at the next one-handed wield.
-- It writes no memory. Other backpacks, other players' Helldivers and every other shield are left alone.
--
-- Cost per frame, while the game runs: one read of the local Helldiver's inventory row (24 bytes), plus one read
-- of action 37's held time while a shield backpack is worn. Every 30th frame about 6 more reads check that the
-- kept addresses still belong to the local Helldiver. A press or a re-stow first finds everything again from the
-- game's registries (about 25 reads), then makes the three calls. No page query, no write, no allocation per
-- frame.
local Holster = {VERSION = '1.0'}
Holster.REVISION = 'v' .. Holster.VERSION

local ffi = require('ffi')
local bit = require('bit')
local band, format = bit.band, string.format

Holster.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
Holster.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'

-- Build 25480438 (KB shield-holster-feasibility; the chain to the inventory row was read live on the ship).
Holster.LAYOUT = {
    players = 0x3326468,   -- player manager: +0x84 counts, +0xE8 local player record, +0x3A8 avatar network id
    owner = 0x346BF98,     -- entities: network-id map +0xF22EC8, entity-id map +0xF1AEB0, records +0xF32F18
    avatars = 0x3326D20,   -- avatar manager: map +0xF8, count +0x6C, entity pointers +0x110, input slots +0x150
    inventory = 0x3326738, -- map +40 by avatar entity id, identity pointers +64, 48-byte rows +80
    equipment = 0x3326DC0, -- per-entity EquipmentComponent copies: map +80, 232-byte records at +144
    none_item = 0x3483C4C, -- the game's "nothing held" id (0 in this build)
    none_slot = 0x3483C5C, -- the id 0xA95A90 compares an empty held carryable with (0 in this build)
    set_item = 0x9ABC30,   -- (inventory, avatar entity, item): sets the held carryable
    set_mode = 0x9AC8E0,   -- (inventory, avatar entity, mode): 2 held, 1 put away
    send_held = 0xBE20B0,  -- (peer, avatar entity, item, mode): rpc_set_held_carryable, peer -2 = everyone
}
-- The first 16 bytes of each function, checked once per session before anything is called.
Holster.PROLOGUES = {set_item = '48895c241848894c2408555657415441', set_mode = '48895c24204489442418555657415441',
                     send_held = '48895c241044894c2420574883ec6048'}
local OWNER_NETWORK_MAP, OWNER_ENTITY_MAP, OWNER_RECORDS, OWNER_SETTINGS = 0xF22EC8, 0xF1AEB0, 0xF32F18, 0xF12BC0
local AVATAR_TYPE_LOW, AVATAR_TYPE_HIGH = 0x294DFA97, 0x4D1C334D -- content/fac_helldivers/cha_avatar/avatar_helldiver
local INPUT_SLOTS, INPUT_STRIDE, BACKPACK_FUNCTION = 0x150 + 0x1B68, 0xA7AEC, 37
local ROW_SIZE, SETTINGS_SLOTS, SETTINGS_SIZE = 48, 688, 232
local TYPE_OFFSET, ONE_HANDED_OFFSET = 0x80, 0xC4
Holster.SHIELD_TYPE = 25        -- EquipmentType_BackpackShield
Holster.CHECK_FRAMES = 30       -- the kept addresses are checked on every 30th frame
Holster.RESTOW_LIMIT = 6        -- re-stows within RESTOW_WINDOW frames before the addon gives up the toggle
Holster.RESTOW_WINDOW = 120
local MODE_HELD, MODE_AWAY = 2, 1
local HIGH = 4294967296
local POSITIVE_INFINITY_BITS = 0x7F800000

-- assert without the file:line prefix: these messages go to the user's log.
local function need(value, message)
    if not value then error(message, 0) end
    return value
end

-- (a * b) mod 2^32 for 32-bit a and b without losing bits in a double.
local function mul32(a, b)
    local high, low = math.floor(a / 65536), a % 65536
    return (high * b % 65536 * 65536 + low * b) % HIGH
end

local function valid_pointer(value)
    return value ~= nil and value >= 0x10000 and value < 0x800000000000
end

-- The row index of key in the game's open-addressed map whose 20-byte header {data, capacity, empty key,
-- multiplier} is at header, or nil. Reads the header and one 8-byte bucket per probe.
local function lookup(api, header, key, capacity_limit)
    if not api.view(header, 20) then return nil end
    local w = api.words
    local data, capacity, empty, multiplier = w[0] + w[1] * HIGH, w[2], w[3], w[4]
    if not valid_pointer(data) or capacity == 0 or capacity > capacity_limit or band(capacity, capacity - 1) ~= 0 then
        return nil
    end
    local product = mul32(key, multiplier)
    for probe = 0, math.min(capacity, 64) - 1 do
        if not api.view(data + 8 * band(product + probe, capacity - 1), 8) then return nil end
        if w[0] == key then return w[1] ~= 0xFFFFFFFF and w[1] or nil end
        if w[0] == empty then return nil end
    end
    return nil
end

-- The local player's avatar record: {address, words (6), entity}, or nil and why.
local function local_avatar(api, game)
    local L = Holster.LAYOUT
    local players, owner = api.u64(game + L.players), api.u64(game + L.owner)
    if not valid_pointer(players) or not valid_pointer(owner) then return nil, 'player manager not ready' end
    if not api.view(players + 0x84, 8) then return nil, 'player counts unreadable' end
    local total, here = api.words[0], api.words[1]
    if total < 1 or total > 4 or here < 1 or here > 4 then return nil, 'no local player' end
    if not api.view(players + 0x3A8, 4) or api.words[0] == 0x7FFF then return nil, 'no local avatar' end
    local network_id = api.words[0]
    local player = api.u64(players + 0xE8)
    if not valid_pointer(player) or not api.view(player, 24) or band(api.words[5], 1) == 0 then
        return nil, 'local player record not owned here'
    end
    local index = lookup(api, owner + OWNER_NETWORK_MAP, network_id, 1048576)
    if not index or index >= 262144 then return nil, 'avatar not in the entity map' end
    local address = owner + OWNER_RECORDS + 24 * index
    if not api.view(address, 24) then return nil, 'avatar record unreadable' end
    local w = api.words
    if w[0] ~= AVATAR_TYPE_LOW or w[1] ~= AVATAR_TYPE_HIGH or band(w[5], 1) == 0 then
        return nil, 'not an owned Helldiver avatar'
    end
    return {address = address, words = {w[0], w[1], w[2], w[3], w[4], w[5]}, entity = w[2]}
end

local function same_record(api, words)
    local w = api.words
    return w[0] == words[1] and w[1] == words[2] and w[2] == words[3] and w[3] == words[4] and w[4] == words[5]
        and w[5] == words[6]
end

-- Where the avatar sits in the avatar manager: {manager, index, entity pointer}, or nil and why.
local function avatar_slot(api, game, avatar)
    local manager = api.u64(game + Holster.LAYOUT.avatars)
    if not valid_pointer(manager) then return nil, 'avatar manager not ready' end
    local index = lookup(api, manager + 0xF8, avatar.entity, 64)
    if not index or not api.view(manager + 0x6C, 4) or api.words[0] > 8 or index >= api.words[0] then
        return nil, 'avatar not in the avatar manager'
    end
    local pointer = api.u64(manager + 0x110 + 8 * index)
    if not valid_pointer(pointer) or not api.view(pointer, 24) or not same_record(api, avatar.words) then
        return nil, 'avatar manager entry holds another entity'
    end
    return {manager = manager, index = index, pointer = pointer}
end

-- The avatar's inventory row: {inventory, index, address}, or nil and why. Its identity pointer must be the
-- avatar's own entity record (live on the ship, 2026-10-16).
local function inventory_row(api, game, avatar)
    local inventory = api.u64(game + Holster.LAYOUT.inventory)
    if not valid_pointer(inventory) then return nil, 'inventory not ready' end
    local index = lookup(api, inventory + 40, avatar.entity, 65536)
    if not index then return nil, 'no inventory row' end
    local identities, rows = api.u64(inventory + 64), api.u64(inventory + 80)
    if not valid_pointer(identities) or not valid_pointer(rows) then return nil, 'inventory arrays missing' end
    if api.u64(identities + 8 * index) ~= avatar.address then return nil, 'inventory row of another entity' end
    return {inventory = inventory, index = index, address = rows + ROW_SIZE * index}
end

-- Everything the addon keeps about the local Helldiver, found from the registry roots, or nil and why.
function Holster.resolve(api, game)
    local avatar, why = local_avatar(api, game)
    if not avatar then return nil, why end
    local slot, slot_why = avatar_slot(api, game, avatar)
    if not slot then return nil, slot_why end
    local row, row_why = inventory_row(api, game, avatar)
    if not row then return nil, row_why end
    return {avatar = avatar, manager = slot.manager, index = slot.index, pointer = slot.pointer,
            inventory = row.inventory, row_index = row.index, row = row.address,
            key = slot.manager + INPUT_SLOTS + INPUT_STRIDE * slot.index + BACKPACK_FUNCTION * 32 + 8}
end

-- Whether the kept resolution still holds: the same avatar entry and record, and the same inventory row.
function Holster.still_valid(api, game, kept)
    if api.u64(game + Holster.LAYOUT.avatars) ~= kept.manager then return false end
    if api.u64(kept.manager + 0x110 + 8 * kept.index) ~= kept.pointer then return false end
    if not api.view(kept.pointer, 24) or not same_record(api, kept.avatar.words) then return false end
    if api.u64(game + Holster.LAYOUT.inventory) ~= kept.inventory then return false end
    return lookup(api, kept.inventory + 40, kept.avatar.entity, 65536) == kept.row_index
end

-- The shared EquipmentComponent of a resource (0x508E90): 688 slots of {resource u64, index u32, pad} probed
-- linearly from resource % 688, then 232-byte records. Returns the record's address, or nil and why.
local function shared_settings(api, owner, low, high)
    local table_address = api.u64(owner + OWNER_SETTINGS)
    if not valid_pointer(table_address) then return nil, 'equipment settings not loaded' end
    local slot = (high * (HIGH % SETTINGS_SLOTS) + low) % SETTINGS_SLOTS
    for _ = 1, SETTINGS_SLOTS do
        if not api.view(table_address + 16 * slot, 12) then return nil, 'equipment settings unreadable' end
        local w = api.words
        if w[0] == low and w[1] == high then return table_address + 16 * SETTINGS_SLOTS + SETTINGS_SIZE * w[2] end
        if w[0] == 0 and w[1] == 0 then return nil, 'no equipment settings' end
        slot = (slot + 1) % SETTINGS_SLOTS
    end
    return nil, 'no equipment settings'
end

-- The 232-byte EquipmentComponent the game's getter (0x5092B0) uses for an entity: its per-entity copy, else the
-- shared settings of its resource. Returns the record's address, or nil and why.
local function equipment_record(api, game, entity)
    local L = Holster.LAYOUT
    local copies = api.u64(game + L.equipment)
    if valid_pointer(copies) then
        local index = lookup(api, copies + 80, entity, 65536)
        local records = index and api.u64(copies + 144)
        if valid_pointer(records) then return records + SETTINGS_SIZE * index end
    end
    local owner = api.u64(game + L.owner)
    if not valid_pointer(owner) then return nil, 'entities not ready' end
    local record = lookup(api, owner + OWNER_ENTITY_MAP, entity, 1048576)
    if not record or not api.view(owner + OWNER_RECORDS + 24 * record, 24) or api.words[2] ~= entity then
        return nil, 'entity ' .. entity .. ' not found'
    end
    return shared_settings(api, owner, api.words[0], api.words[1])
end

-- The entity's equipment type and one-handed flag, or nil and why.
function Holster.equipment(api, game, entity)
    local address, why = equipment_record(api, game, entity)
    if not address then return nil, nil, why end
    if not api.view(address + TYPE_OFFSET, 4) then return nil, nil, 'equipment type unreadable' end
    local kind = api.words[0]
    if not api.view(address + ONE_HANDED_OFFSET, 1) then return nil, nil, 'equipment flags unreadable' end
    return kind, api.bytes[0] ~= 0
end

-- The row's words the addon uses: backpack (+12), held carryable (+20), slot in hand (+28), carry mode (+32).
function Holster.read_row(api, address)
    if not api.view(address + 12, 24) then return nil end
    local w = api.words
    return w[0], w[2], w[4], w[5]
end

-- The entity id of the weapon in the slot in hand (1 primary, 2 sidearm, 3 support), or nil.
local function weapon_in_hand(api, row_address, slot)
    if slot < 1 or slot > 3 or not api.view(row_address + 4 * (slot - 1), 4) then return nil end
    return api.words[0]
end

local Instance = {}
Instance.__index = Instance

-- api: view/u64 reads (bytes, words) and the three native calls; game: game.dll's base; note(line): the log.
function Holster.new(api, game, note)
    local self = setmetatable({api = api, game = game, note = note, frame = 0, kept = nil, backpack = nil,
                               shield = false, toggled = false, toggled_for = nil, key_bits = 0, pending = nil,
                               restows = {}, nones = {}, counts = {presses = 0, holsters = 0, draws = 0,
                               restows = 0, checked = 0, failed = 0, refused = 0}}, Instance)
    self.step = function() return self:frame_step() end
    return self
end

function Instance:read_nones()
    local L, api = Holster.LAYOUT, self.api
    local item = api.view(self.game + L.none_item, 4) and api.words[0] or 0
    local slot = api.view(self.game + L.none_slot, 4) and api.words[0] or 0
    self.nones = {[0] = true, [item] = true, [slot] = true}
    self.none_item = item
end

function Instance:is_none(id) return self.nones[id] == true end

function Instance:forget(reason)
    if self.toggled then self:untoggle(reason) end
    self.kept, self.backpack, self.shield, self.key_bits, self.pending = nil, nil, false, 0, nil
end

function Instance:untoggle(reason)
    self.toggled, self.toggled_for = false, nil
    if reason then self.note('Shield toggle off: ' .. reason .. '.') end
end

-- A full resolution from the registry roots; keeps it. Returns it, or nil and why.
function Instance:resolve()
    local kept, why = Holster.resolve(self.api, self.game)
    if not kept then return nil, why end
    if self.kept == nil or self.kept.avatar.entity ~= kept.avatar.entity then
        if self.toggled then self:untoggle('a new Helldiver') end
        self.backpack, self.shield, self.key_bits = nil, false, 0
        if kept.avatar.entity ~= self.last_avatar then
            self.last_avatar = kept.avatar.entity
            self.note(format('Found your Helldiver (avatar %d, inventory row %d).', kept.avatar.entity, kept.row_index))
        end
    end
    self.kept = kept
    return kept
end

-- The backpack changed: is the new one a shield? (its settings, read once per backpack id)
function Instance:backpack_changed(backpack)
    if self.toggled then self:untoggle('the backpack changed') end
    self.backpack, self.shield, self.key_bits = backpack, false, 0
    if self:is_none(backpack) then return end
    local kind = Holster.equipment(self.api, self.game, backpack)
    self.shield = kind == Holster.SHIELD_TYPE
    if self.shield then self.note(format('Shield backpack %d worn: Backpack Function toggles it.', backpack)) end
end

-- The three calls of one move, exactly as the game makes them, then the check on the next frame.
function Instance:move(kept, shield, mode, label)
    local api, avatar = self.api, kept.avatar.entity
    api.set_item(kept.inventory, avatar, mode == MODE_HELD and shield or self.none_item)
    api.set_mode(kept.inventory, avatar, mode)
    api.send_held(-2, avatar, shield, mode)
    self.pending = {mode = mode, shield = shield, label = label}
    local count = mode == MODE_HELD and 'draws' or 'holsters'
    self.counts[count] = self.counts[count] + 1
end

-- The check of the last move: the row must show it. A draw holds the shield in mode 2. A stow leaves nothing
-- held, and with nothing held 0x9AC8E0 writes carry mode 0 whatever mode it was given.
function Instance:check_move(held, mode)
    local pending = self.pending
    self.pending = nil
    local ok
    if pending.mode == MODE_HELD then
        ok = held == pending.shield and mode == MODE_HELD
    else
        ok = self:is_none(held)
    end
    self.counts[ok and 'checked' or 'failed'] = self.counts[ok and 'checked' or 'failed'] + 1
    self.note(format('%s: %s (held %d, mode %d).', pending.label, ok and 'done' or 'FAILED, the game did not take it',
                     held, mode))
end

-- Before any move: everything found again from the roots, the backpack still a shield. Returns the fresh
-- resolution and the row's words, or nil and why.
function Instance:verified(shield)
    local kept, why = self:resolve()
    if not kept then return nil, why end
    local backpack, held, slot, mode = Holster.read_row(self.api, kept.row)
    if backpack == nil then return nil, 'inventory row unreadable' end
    if backpack ~= shield then return nil, 'the backpack changed' end
    local kind, _, kind_why = Holster.equipment(self.api, self.game, backpack)
    if kind ~= Holster.SHIELD_TYPE then return nil, kind_why or 'the backpack is not a shield' end
    return kept, held, slot, mode
end

function Instance:refuse(what, why)
    self.counts.refused = self.counts.refused + 1
    self.note(what .. ' refused: ' .. tostring(why) .. '.')
end

-- A press of Backpack Function while a shield backpack is worn.
function Instance:press(shield)
    self.counts.presses = self.counts.presses + 1
    local kept, held, slot, mode = self:verified(shield)
    if not kept then return self:refuse('Press', held) end
    if held == shield then
        self.toggled, self.toggled_for = true, kept.avatar.entity
        return self:move(kept, shield, MODE_AWAY, 'Shield to the back')
    end
    if not self:is_none(held) then
        self.toggled = not self.toggled
        self.toggled_for = self.toggled and kept.avatar.entity or nil
        return self.note(format('Press while carrying something else: the shield %s.',
                                self.toggled and 'stays on the back' or 'returns with the next one-handed weapon'))
    end
    if not self.toggled then
        self.toggled, self.toggled_for = true, kept.avatar.entity
        return self.note('Press with the shield on the back: it stays there.')
    end
    self:untoggle()
    local weapon = weapon_in_hand(self.api, kept.row, slot)
    local one_handed = weapon and select(2, Holster.equipment(self.api, self.game, weapon))
    if one_handed then return self:move(kept, shield, MODE_HELD, 'Shield to the hand') end
    self.note('Shield toggle off: it returns with the next one-handed weapon.')
end

-- The game drew the shield while the toggle is on: stow it again, unless that keeps happening.
function Instance:restow(shield)
    local restows, frame = self.restows, self.frame
    while restows[1] and frame - restows[1] >= Holster.RESTOW_WINDOW do table.remove(restows, 1) end
    if #restows >= Holster.RESTOW_LIMIT then
        self.restows = {}
        return self:untoggle(format('the game drew the shield %d times in %d frames, so it stays in hand',
                                    Holster.RESTOW_LIMIT + 1, Holster.RESTOW_WINDOW))
    end
    local kept, held = self:verified(shield)
    if not kept then return self:refuse('Re-stow', held) end
    if kept.avatar.entity ~= self.toggled_for then return self:untoggle('a new Helldiver') end
    if held ~= shield then return end
    restows[#restows + 1] = frame
    self.counts.restows = self.counts.restows + 1
    self:move(kept, shield, MODE_AWAY, 'Shield back to the back after the game drew it')
end

-- Action 37's held time, as its float bits: 0 when released, positive below infinity while held.
function Instance:key_pressed()
    if not self.api.view(self.kept.key, 4) then return false end
    local bits, before = self.api.words[0], self.key_bits
    self.key_bits = bits
    return before == 0 and bits > 0 and bits < POSITIVE_INFINITY_BITS
end

-- Every 30th frame: the kept addresses must still be the local Helldiver's, else find them again (the game moves
-- inventory rows when a Helldiver dies; resolve keeps the toggle while the avatar entity is the same).
function Instance:check()
    if self.kept and Holster.still_valid(self.api, self.game, self.kept) then return end
    local _, why = self:resolve()
    if why and self.kept then self:forget('the Helldiver is gone (' .. why .. ')') end
end

-- One frame with a kept resolution: the row read, then the key read while a shield backpack is worn. Another
-- backpack at the kept row may only mean the game moved the rows (it does when a Helldiver dies): the row is
-- found again from the registries before the change counts.
function Instance:watch(kept)
    local backpack, held, _, mode = Holster.read_row(self.api, kept.row)
    if backpack ~= self.backpack and self.backpack ~= nil then
        kept = self:resolve()
        if not kept then return self:forget('the Helldiver is gone') end
        backpack, held, _, mode = Holster.read_row(self.api, kept.row)
    end
    if backpack == nil then return self:forget('the inventory row went away') end
    if self.pending then self:check_move(held, mode) end
    if backpack ~= self.backpack then self:backpack_changed(backpack) end
    if not self.shield then return end
    if self:key_pressed() then return self:press(backpack) end
    if self.toggled and held == backpack then self:restow(backpack) end
end

-- The per-frame step: one row read; a key read while a shield is worn; the rest only when something happens.
function Instance:frame_step()
    local frame = self.frame + 1
    self.frame = frame
    if self.kept then self:watch(self.kept) end
    if frame % Holster.CHECK_FRAMES == 0 then self:check() end
end

function Instance:summary()
    local c = self.counts
    return format('presses %d, to the back %d (re-stows %d), to the hand %d, checks done %d, failed %d, refused %d',
                  c.presses, c.holsters, c.restows, c.draws, c.checked, c.failed, c.refused)
end

-- The guard's pause (an update below failed): start afresh; the shield stays where the game has it.
function Instance:pause(reason)
    self:forget()
    self.note('Paused (' .. tostring(reason) .. ').')
end

function Instance:stopped(reason)
    self.note('Stopped (' .. tostring(reason) .. '): ' .. self:summary() .. '.')
end

-- The in-game adapter: the Windows calls and the game's functions, declared under private names (an __asm__
-- label naming the real export, private typedefs for the game's function pointers), so another mod's
-- declarations neither change these calls nor are changed by them. Addresses go in as uint64_t numbers. view
-- reads into one reused buffer (bytes and 32-bit words), u64 into two reused words: no allocation per read.
local DECLARATIONS = [[
void *hys1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
int hys1_ReadProcessMemory(void *process, uint64_t address, void *buffer, size_t size, uint32_t *done) __asm__("ReadProcessMemory");
typedef void (*hys1_set_item)(uint64_t inventory, uint32_t avatar, uint32_t item);
typedef uint64_t (*hys1_set_mode)(uint64_t inventory, uint32_t avatar, uint32_t mode);
typedef void (*hys1_send_held)(int64_t peer, uint32_t avatar, uint32_t item, uint32_t mode);
]]

function Holster.adapter()
    need(ffi.abi('64bit'), 'Windows x64 is required')
    if not pcall(ffi.typeof, 'hys1_set_item') then ffi.cdef(DECLARATIONS) end
    local kernel = ffi.load('kernel32')
    local process, read_memory = kernel.hys1_GetCurrentProcess(), kernel.hys1_ReadProcessMemory
    local done, pair = ffi.new('uint32_t[2]'), ffi.new('uint32_t[2]')
    local view_size = 64
    local view = ffi.new('uint8_t[?]', view_size)
    local api = {bytes = view, words = ffi.cast('uint32_t *', view)}

    function api.view(address, size)
        if size < 1 or size > view_size then return false end
        return read_memory(process, address, view, size, done) ~= 0 and done[0] == size and done[1] == 0
    end

    function api.u64(address)
        if read_memory(process, address, pair, 8, done) == 0 or done[0] ~= 8 or done[1] ~= 0 then return nil end
        return pair[0] + pair[1] * HIGH
    end

    -- Binds the game's three functions after checking their first bytes; raises when one differs.
    function api.bind(game)
        local L = Holster.LAYOUT
        for name, expected in pairs(Holster.PROLOGUES) do
            need(api.view(game + L[name], 16), 'game function unreadable: ' .. name)
            local got = {}
            for i = 0, 15 do got[#got + 1] = format('%02x', view[i]) end
            need(table.concat(got) == expected, 'game function differs: ' .. name)
        end
        local set_item = ffi.cast('hys1_set_item', game + L.set_item)
        local set_mode = ffi.cast('hys1_set_mode', game + L.set_mode)
        local send_held = ffi.cast('hys1_send_held', game + L.send_held)
        api.set_item = function(inventory, avatar, item) set_item(inventory, avatar, item) end
        api.set_mode = function(inventory, avatar, mode) set_mode(inventory, avatar, mode) end
        api.send_held = function(peer, avatar, item, mode) send_held(peer, avatar, item, mode) end
    end

    return api
end

-- Bingus Shared Loader v18+ with API 1, recognized by what it offers, never by its internal version.
function Holster.loader_ok(loader)
    return type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function'
        and type(loader.jit) == 'table'
end

-- Everything stays interpreted, the per-frame row and key reads included: they are two calls and a few
-- comparisons, and kept out of the compiler they add no trace to the LuaJIT code cache the game and every mod
-- share (512 KB and 1000 traces unless the loader raises them). Only the step's entry is left on, as in Laser
-- Sentry Cooldown; a trace through it stops at the first interpreted call.
local HELPERS = {need, mul32, valid_pointer, lookup, local_avatar, same_record, avatar_slot, inventory_row,
                 shared_settings, equipment_record, weapon_in_hand}
local function interpreted(functions)
    if type(jit) ~= 'table' or type(jit.off) ~= 'function' then return end
    for _, fn in pairs(functions) do
        if type(fn) == 'function' then pcall(jit.off, fn, true) end
    end
end
interpreted({interpreted})
function Holster.interpreted_but_step(instance)
    interpreted(HELPERS)
    interpreted(Holster)
    interpreted(Instance)
    interpreted(instance.api)
    interpreted({instance.note})
    if type(jit) == 'table' and type(jit.on) == 'function' then pcall(jit.on, instance.step) end
end

-- Builds the instance and installs Bingus Shared Runtime's update guard (bingus_runtime.lua, bundled by the
-- build): the previous update runs outside pcall, 8 errors in a burst stop the addon, an error below pauses it
-- until the updates below run cleanly for 60 frames, and the first failure survives shutdown. options.adapter
-- replaces the in-game adapter and options.env the global table (tests). Returns the instance, or nil when
-- disabled.
function Holster.install(runtime, memory, options)
    options = options or {}
    local loader = rawget(_G, 'CowboyBingusModLoader')
    local log_file
    if loader and type(loader.open_log) == 'function' then
        pcall(function() log_file = loader.open_log('HolsterYourShield.log') end)
    end
    local function note(line)
        print('[HolsterYourShield] ' .. line)
        if log_file then pcall(function() log_file:write(line .. '\n'); log_file:flush() end) end
    end
    local ready, instance = pcall(function()
        need(Holster.loader_ok(loader), 'Bingus Shared Loader v18+ / API 1 required')
        local game = memory.module('game.dll')
        need(game ~= nil and memory.module(nil) ~= nil, 'game modules unavailable')
        local ok, why = memory.verify_build({exe_sha256 = Holster.EXE_SHA256, game_sha256 = Holster.GAME_SHA256})
        need(ok, why == 'unsupported game build' and 'unsupported game build (needs Steam build 25480438)'
             or tostring(why))
        local api = (options.adapter or Holster.adapter)()
        local base = memory.address(game)
        api.bind(base)
        local made = Holster.new(api, base, note)
        made:read_nones()
        return made
    end)
    if not ready then
        note('Disabled: ' .. tostring(instance))
        return nil
    end
    Holster.interpreted_but_step(instance)
    local env = options.env or _G
    local guard = runtime.guard({name = 'HolsterYourShield', step = instance.step,
                                 stop = function(reason) instance:stopped(reason) end,
                                 pause = function(reason) instance:pause(reason) end,
                                 log = note, env = env}).install()
    instance.guard, instance.env = guard, env
    rawset(env, 'HolsterYourShieldInstalled', true)
    note('Holster Your Shield ' .. Holster.REVISION .. ' initialized (loader API ' .. tostring(loader.api) .. ').')
    return instance
end

return Holster
