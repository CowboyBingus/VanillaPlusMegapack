-- Match Your Colors: the Helldiver's weapons (Recolor Weapons, v1.5; user request 2026-10-15: weapon color matching
-- with the armor's, helmet's and cape's algorithms; KB match-your-colors-weapons). Steam build 25480438: the chain
-- from static research (research/scratch/weapons/re/NOTES.md), checked live on the ship and in a mission 2026-10-15
-- (research/live/live_weapon_probe.py).
--
-- Inventory [game + 0x3326738]: the map +40 from an avatar's entity id to its row, rows [+80] of 48 bytes: +0 the
-- primary, +4 the sidearm, +8 the support weapon (entity ids; a weapon picked up lands in its slot), +28 the slot in
-- hand (1-3; 0 on the ship, where no weapon is held); each row's entity [+64] (8-byte pointers to entity records, +8
-- the id); the row count +20. The rows move: an avatar removed (a death, a player leaving) has another row and its
-- entity moved into its index (0x9b2810 -> 0x9b15d0, static research 2026-10-16); a new one is added last (0x9b25c0).
-- Entities [game + 0x346BF98]: the map +0xF1AEB0 from an entity id to its record +0xF32F18 + 24 e (+0 its resource:
-- the weapon's id, its unit's name; +12 its unit). Weapon
-- customization [game + 0x3326A38]: the map +632 to its record [+672] + 128 j (attachment units at +8, +12, +40, +68
-- and +96, +100 the underbarrel's entity), and the map +696 to the weapon's own copy of its customization [+760] +
-- 4872 k (none: the weapon type's, no paint of its own): its attachments' unit names (+0x78 optic, +0x80/+0x90/+0x98
-- magazines, +0xA0 muzzle, +0xC0 underbarrel) and its paint, the game's MaterialOverride (+200: the weapon unit's 10
-- rows of 40 bytes {u32 material slot, u64 LUT, decal, pattern, masks}, then 10 entries of 408 bytes {u32 kind, pad, 10
-- rows}: kind 1 underbarrel, 2 optic, 4 muzzle, 5 magazines). A row's LUT 0 leaves the material's own. Weapon
-- catalogue [entities + 0xF12558]: 1080 buckets of 16 bytes (the 8-byte weapon id, +8 its index), records +17280 of 32
-- bytes (+8 its package: the archive holding the weapon's units and its default attachments').
--
-- The game binds a weapon's paint again whenever it reloads (every unit of the weapon in hand: the magazine is a new
-- unit; static research, 0x11c1be0 -> 0x749dd0): a recolor of the weapon in hand is checked on every frame (one 8-byte
-- read, Weapons.watch) and bound again the next frame. Nothing here writes game memory.
local ffi = require('ffi')

local Weapons = {}

Weapons.INVENTORY, Weapons.ENTITIES, Weapons.CUSTOMIZATION = 0x3326738, 0x346BF98, 0x3326A38
local I_MAP, I_OWNERS, I_ROWS, ROW_BYTES, CURRENT = 40, 64, 80, 48, 28
local I_HEAD, I_COUNT = 16, 20 -- Weapons.owned's read: the row count to the row array
local HEAD_BYTES = I_ROWS + 8 - I_HEAD
Weapons.ROW_BYTES = ROW_BYTES
local E_MAP, E_RECORDS, E_CATALOGUE = 0xF1AEB0, 0xF32F18, 0xF12558
local C_MAP, C_RECORDS, C_RECORD_BYTES, C_INSTANCES, C_COPIES, COPY_BYTES = 632, 672, 128, 696, 760, 4872
local CATALOGUE_BUCKETS, CATALOGUE_RECORDS = 1080, 17280
-- What a weapon's copy of its customization holds, read in one span from ATTACHMENTS: the attachments' unit names
-- and the MaterialOverride (+200: 400 bytes for the weapon unit, then 10 entries of 408).
local ATTACHMENTS, OVERRIDE, KIND_ENTRY, KINDS = 0x78, 200, 408, 10
local COPY_SPAN = OVERRIDE + 400 + KIND_ENTRY * KINDS - ATTACHMENTS
Weapons.COPY_SPAN = COPY_SPAN
-- The inventory row's weapon slots: 1 primary, 2 sidearm, 3 support (the slot in hand, +28, names them the same).
Weapons.SLOTS = {[1] = 0, [2] = 4, [3] = 8}
-- Attachment units in the customization record (the record's own unit ids; one that is no unit of the weapon binds
-- nothing: only materials holding a LUT its plan changes are bound).
local RECORD_UNITS = {8, 12, 40, 68, 96}
local UNDERBARREL_ENTITY = 100
-- Override kinds by piece role (src/kits.lua WEAPON_ROLES: 1 optic, 2 magazine, 3 muzzle, 4 underbarrel).
local ROLE_KIND = {[1] = 2, [2] = 5, [3] = 4, [4] = 1}
local ROLE_NAME_AT = {[1] = 0x78, [2] = 0x80, [3] = 0xA0, [4] = 0xC0}
local NO = '0000000000000000' -- src/kits.lua NO_LUT
local BODY_ANY, WEAPON = 3, 'Weapon' -- src/kits.lua BODY_ANY, WEAPON
local HIGH = 4294967296
local MAX_ROWS = 4096

local function u32(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
local function hex64(p, o) return string.format('%08x%08x', u32(p, o + 4), u32(p, o)) end
local function pointer(read, address)
    local b = read(address, 8)
    if not b then return nil end
    local value = u32(b, 0) + u32(b, 4) * HIGH
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end

-- A unit id that can be live (0 and 0xffffffff are none).
local function unit_id(v) return v ~= 0 and v ~= 0xFFFFFFFF end

-- The inventory row of an avatar (its entity id): {inventory, rows (the row array; it moves only when the inventory
-- grows), row (address), avatar, index}, or nil; with owned, also owners (the entity array [+64]) and owner (the row's
-- entity there, Weapons.owned; 2 reads more). read: Avatar.reader; lookup: Avatar.lookup.
function Weapons.locate(read, lookup, game, avatar, owned)
    local inventory = pointer(read, game + Weapons.INVENTORY)
    local index = inventory and lookup(read, inventory + I_MAP, avatar)
    local rows = index and index < MAX_ROWS and pointer(read, inventory + I_ROWS)
    if not rows then return nil end
    local where = {inventory = inventory, rows = rows, row = rows + ROW_BYTES * index, avatar = avatar, index = index}
    where.owners = owned and pointer(read, inventory + I_OWNERS) or nil
    where.owner = where.owners and pointer(read, where.owners + 8 * index) or nil
    if where.owner then -- the addresses Weapons.owned reads, made once
        where.head_at = ffi.cast('const uint8_t *', inventory + I_HEAD)
        where.owner_at = ffi.cast('const uint8_t *', where.owners + 8 * index)
    end
    return where
end

local function u64(p, o) return u32(p, o) + u32(p, o + 4) * HIGH end

-- Whether where (Weapons.locate with owned) is still the row of the avatar it was found for: in one read of the
-- inventory's head (+16 to +87) its index under the row count (+20: a row moved away leaves its old bytes and entity
-- past it, 0x9b15d0 clears nothing) and the entity and row arrays where they were (they move only when it grows); then
-- the row's entity the same (one 8-byte read). False when anything differs or cannot be read; true when where has no
-- entity to compare. scratch: a buffer of HEAD_BYTES or more. No allocation.
Weapons.HEAD_BYTES = HEAD_BYTES
function Weapons.owned(memory, where, scratch)
    if not where.owner then return true end
    if not memory.read_into(where.head_at, HEAD_BYTES, scratch) or where.index >= u32(scratch, I_COUNT - I_HEAD)
        or u64(scratch, I_OWNERS - I_HEAD) ~= where.owners or u64(scratch, I_ROWS - I_HEAD) ~= where.rows then
        return false
    end
    return memory.read_into(where.owner_at, 8, scratch) and u64(scratch, 0) == where.owner or false
end

-- One weapon of an entity id: {id, name (its resource: the weapon's id and its unit's name), unit, units = {unit ids
-- of its attachments}, copy (whether it has a customization of its own)} plus, with one, its attachments' unit
-- names (attachments[role]) and paint (overrides[role] = {[slot key] = {lut, pattern}}), or nil when its entity is not
-- found. big: a buffer of COPY_SPAN bytes or more.
-- The entity record (24 bytes) of entity id, or nil.
local function entity_record(read, lookup, entities, id)
    local e = lookup(read, entities + E_MAP, id)
    local b = e and read(entities + E_RECORDS + 24 * e, 24)
    if not b or u32(b, 8) ~= id then return nil end
    return b
end

-- The attachment units of w's customization record (r) into w.units: the record's units and its underbarrel entity's.
local function attachment_units(read, lookup, entities, w, r)
    for _, o in ipairs(RECORD_UNITS) do
        local unit = u32(r, o)
        if unit_id(unit) and unit ~= w.unit then w.units[#w.units + 1] = unit end
    end
    local under = u32(r, UNDERBARREL_ENTITY)
    local ub = unit_id(under) and entity_record(read, lookup, entities, under)
    if ub and unit_id(u32(ub, 12)) then w.units[#w.units + 1] = u32(ub, 12) end
end

local function weapon_of(read, lookup, game, id, big, memory)
    local entities = pointer(read, game + Weapons.ENTITIES)
    local b = entities and entity_record(read, lookup, entities, id)
    if not b then return nil end
    local w = {id = id, name = hex64(b, 0), unit = u32(b, 12), units = {}, overrides = {}, attachments = {}}
    local wcm = pointer(read, game + Weapons.CUSTOMIZATION)
    local j = wcm and lookup(read, wcm + C_MAP, id)
    local records = j and pointer(read, wcm + C_RECORDS)
    local r = records and read(records + C_RECORD_BYTES * j, C_RECORD_BYTES)
    if r then attachment_units(read, lookup, entities, w, r) end
    local k = wcm and lookup(read, wcm + C_INSTANCES, id)
    local copies = k and pointer(read, wcm + C_COPIES)
    if copies and memory.read_into(ffi.cast('const uint8_t *', copies + COPY_BYTES * k + ATTACHMENTS), COPY_SPAN, big) then
        w.copy = true
        Weapons.decode_copy(w, big)
    end
    return w
end

-- One block of 10 MaterialOverride rows at o (in the copy span) as {[slot key] = {lut, pattern}} (rows with a LUT or
-- pattern of their own only), and a text of them for the kit's signature.
local function override_rows(big, o)
    local out, parts = {}, {}
    for r = 0, 9 do
        local p = o + 40 * r
        local slot = u32(big, p)
        local lut, pattern = hex64(big, p + 8), hex64(big, p + 24)
        if slot ~= 0 and (lut ~= NO or pattern ~= NO) then
            out[slot] = {lut = lut, pattern = pattern}
            parts[#parts + 1] = string.format('%08x=%s/%s', slot, lut, pattern)
        end
    end
    table.sort(parts)
    return out, table.concat(parts, ' ')
end

-- A weapon's copy of its customization (big: COPY_SPAN bytes from ATTACHMENTS) into w: attachments[role] (unit names)
-- and overrides[role] = {rows, text} (role 0 the weapon unit).
function Weapons.decode_copy(w, big)
    for role, at in pairs(ROLE_NAME_AT) do
        local name = hex64(big, at - ATTACHMENTS)
        if name ~= NO then w.attachments[role] = name end
    end
    local rows, text = override_rows(big, OVERRIDE - ATTACHMENTS)
    w.overrides[0] = {rows = rows, text = text}
    for e = 0, KINDS - 1 do
        local o = OVERRIDE + 400 + KIND_ENTRY * e - ATTACHMENTS
        local kind = u32(big, o)
        for role, k in pairs(ROLE_KIND) do
            if kind == k then
                local kind_rows, kind_text = override_rows(big, o + 8)
                w.overrides[role] = {rows = kind_rows, text = kind_text}
            end
        end
    end
end

-- The weapons of an inventory row (Weapons.locate): {row = {48 bytes as read}, held (the slot in hand, 0-3), list =
-- {weapon_of's, by slot: [1] primary, [2] sidearm, [3] support}} or nil when the row cannot be read. Up to about 15
-- reads per weapon (on a change, never per frame).
function Weapons.resolve(read, lookup, game, where, memory, big)
    local b = read(where.row, ROW_BYTES)
    if not b then return nil end
    local ids, held = {}, u32(b, CURRENT)
    for slot, o in pairs(Weapons.SLOTS) do ids[slot] = u32(b, o) end
    local out = {held = held, list = {}, ids = ids}
    for slot = 1, 3 do
        local id = ids[slot]
        if unit_id(id) then out.list[slot] = weapon_of(read, lookup, game, id, big, memory) end
    end
    return out
end

-- The weapon catalogue's package (archive) of a weapon id (its entity's resource, 16 hex digits), or nil. One read of
-- the buckets (17 KB) and one of the record; inside a job. buffer: CATALOGUE_RECORDS bytes or more.
function Weapons.package(memory, read, game, name, buffer)
    local entities = pointer(read, game + Weapons.ENTITIES)
    local table_at = entities and pointer(read, entities + E_CATALOGUE)
    if not table_at or not memory.read_into(ffi.cast('const uint8_t *', table_at), CATALOGUE_RECORDS, buffer) then
        return nil
    end
    for i = 0, CATALOGUE_BUCKETS - 1 do
        if buffer[i * 16] ~= 0 or buffer[i * 16 + 7] ~= 0 then
            if hex64(buffer, i * 16) == name then
                local index = u32(buffer, i * 16 + 8)
                local r = index < 540 and read(table_at + CATALOGUE_RECORDS + 32 * index, 32)
                local package = r and hex64(r, 8)
                return package ~= NO and package or nil
            end
        end
    end
    return nil
end

-- The template's classes of prefix p into out (templated), for slots not taken yet.
local function take_classes(out, taken, rows, classes, p, decals)
    for key, lut in pairs(classes) do
        local slot = key:sub(1, 1) == p and tonumber(key:sub(2), 16)
        if slot and not taken[slot] then
            local own = rows and rows[slot]
            out[slot] = {lut = lut, pattern = NO, bound = own and own.lut or NO, decal = decals and decals[key]}
            taken[slot] = true
        end
    end
end

-- A piece's per-slot paint with a template scheme: every material class the template paints takes the template's LUT
-- (lut) while the game binds its own paint's or the material's (bound: NO for the material's own); the weapon's own
-- paint rows for other classes as they are; decal: the template's decal sheet for the class (decals: src/weapon_data.lua
-- decals[id] or nil). Returns the rows and their text (the kit's signature).
-- fallback: a second prefix whose classes apply where the first's do not (an underbarrel: a weapon entity of its own,
-- painted with the weapon's rows; the AR-11 Arbitrator's under-barrel module kept its colors in the control check).
local function templated(rows, classes, prefix, decals, fallback)
    local out, parts = {}, {}
    for slot, o in pairs(rows or {}) do out[slot] = {lut = o.lut, pattern = o.pattern, bound = o.lut} end
    local taken = {}
    for _, p in ipairs({prefix, fallback}) do take_classes(out, taken, rows, classes, p, decals) end
    for slot, o in pairs(out) do
        parts[#parts + 1] = string.format('%08x=%s/%s/%s/%s', slot, o.lut, o.pattern, o.bound, o.decal or NO)
    end
    table.sort(parts)
    return out, table.concat(parts, ' ')
end

-- The kit src/kits.lua analyses for a weapon (weapon_of's) found in archive (its package): the weapon unit and its
-- attachments' units, each with its paint's LUTs and patterns per material slot (piece.overrides); nil without one.
-- template: {id, classes (src/weapon_data.lua schemes[id]), archive} or nil: a scheme whose LUTs its material classes
-- are analysed through (as the game paints a weapon with a scheme: the weapon's ID masks draw the scheme's rows) while
-- the game's own binding stays the one to replace (override.bound).
-- unit: the weapon's unit name when it is not the weapon's id (src/weapon_data.lua unit_of: 13 weapons, the R-63CS
-- Diligence Counter Sniper, the SG-20 Halt, the SG-8S Slugger...; looked up by its id, their bodies were never found
-- and only their attachments recolored: independent render review 2026-10-15, cases 5, 6 and 8).
-- extra: the archives searched beside the package (the template's and the attachments', src/recolor.lua weapon_kit),
-- else the template's.
function Weapons.kit(w, archive, template, unit, extra)
    local pieces = {}
    local function add(role, path)
        local o = w.overrides[role]
        local rows, text = o and o.rows or nil, o and o.text ~= '' and o.text or nil
        if template then
            -- an underbarrel (role 4) may be a weapon entity of its own: the weapon's classes where the attachments'
            -- do not apply
            rows, text = templated(rows, template.classes, role == 0 and 'w' or 'a', template.decals,
                                   role == 4 and 'w' or nil)
        end
        pieces[#pieces + 1] = {path = path, slot = role, type = 0, body = BODY_ANY, lut = NO, pattern = NO, tone = 0,
                               overrides = rows, overrides_text = text}
    end
    add(0, unit or w.name)
    for role = 1, 4 do
        if w.attachments[role] then add(role, w.attachments[role]) end
    end
    local low = tonumber(w.name:sub(9, 16), 16)
    return {id = low, name_upper = 0, archive = archive, kit_type = WEAPON, pieces = pieces, name = w.name,
            extra_archive = extra or (template and template.archive or nil),
            template = template and template.id or nil}
end

-- The Armory's weapon preview (the weapon panel and the WEAPON CUSTOMIZATION screen; static research, KB
-- match-your-colors-weapons): UiPreviewSystem [game + 0x347CE60] weapon slot 3 (+76056 + 1560 s, the slot every
-- weapon preview of the local player's Armory uses): +0 the weapon's unit, +4 + 12 kind + 4 k its attachments' units,
-- +128 the weapon id, +144 its customization ids (count, then up to 10 u64 at +152: attachments and paint scheme, in
-- the order applied). The ring head (+50448) moves when the game spawned or updated a preview weapon: src/preview.lua
-- reads it with the UI gate. The slot keeps no paint: Weapons.compose builds it as the game does.
Weapons.UPS, Weapons.PREVIEW_SLOT = 0x347CE60, 3
local UPS_WEAPONS, UPS_WEAPON_BYTES, SLOT_READ = 76056, 1560, 232
local CONFIG_COUNT, CONFIG_IDS, MAX_IDS = 144, 152, 10

-- An underbarrel that is a weapon entity of its own (the AR-11 Arbitrator's under-barrel module) is previewed in the
-- paired slot, PAIRED slots on (UiPreviewSystem +88536 + 1560 s: slot s + 8's record; live probe 2026-10-15, research/
-- live/live_underbarrel_probe.py): its unit and its attachments' units join the preview's (out.units). One read, on a
-- preview change only.
local PAIRED = 8
local function paired_units(read, ups, out)
    local b = read(ups + UPS_WEAPONS + UPS_WEAPON_BYTES * (Weapons.PREVIEW_SLOT + PAIRED), SLOT_READ)
    if not b then return end
    for o = 0, 120, 4 do
        local unit = u32(b, o)
        if unit_id(unit) then out.units[#out.units + 1] = unit end
    end
end

-- The preview weapon in slot 3: {unit, units (attachment units, the paired slot's too), name (the weapon id), ids (its
-- customization ids as 16 hex digits), key (name and ids)} or nil when the slot holds no weapon.
function Weapons.preview(read, game)
    local ups = pointer(read, game + Weapons.UPS)
    local b = ups and read(ups + UPS_WEAPONS + UPS_WEAPON_BYTES * Weapons.PREVIEW_SLOT, SLOT_READ)
    if not b or not unit_id(u32(b, 0)) then return nil end
    local out = {unit = u32(b, 0), units = {}, name = hex64(b, 128), ids = {}}
    for o = 4, 120, 4 do
        local unit = u32(b, o)
        if unit_id(unit) then out.units[#out.units + 1] = unit end
    end
    local count = math.min(u32(b, CONFIG_COUNT), MAX_IDS)
    for i = 0, count - 1 do out.ids[#out.ids + 1] = hex64(b, CONFIG_IDS + 8 * i) end
    out.key = out.name .. ':' .. table.concat(out.ids, ',')
    paired_units(read, ups, out) -- after b is read through: the reader reuses its buffer
    return out
end

-- An 8-byte id (16 hex digits) modulo n, exact (its halves in doubles).
local function hex_mod(name, n)
    local high, low = tonumber(name:sub(1, 8), 16), tonumber(name:sub(9, 16), 16)
    return ((high % n) * (HIGH % n) + low % n) % n
end

-- The index stored for an 8-byte id in a bucket table at `at` ({u64 id, u32 index} of 16 bytes, n buckets, probed
-- linearly from id % n until an empty id), or nil.
local function bucket_index(read, at, n, name)
    if n == 0 or n > 65536 then return nil end
    local start = hex_mod(name, n)
    for i = 0, math.min(n, 256) - 1 do
        local b = read(at + 16 * ((start + i) % n), 16)
        if not b then return nil end
        local id = hex64(b, 0)
        if id == name then return u32(b, 8) end
        if id == NO then return nil end
    end
    return nil
end

-- Copies the part of a patch (dest, size bytes from src) that falls in the span [ATTACHMENTS, ATTACHMENTS +
-- COPY_SPAN) of the component into big. read_into(address, size, buffer) reads game memory.
local function apply_patch(read_into, data, dest, size, src, big)
    local first, last = math.max(dest, ATTACHMENTS), math.min(dest + size, ATTACHMENTS + COPY_SPAN)
    if first >= last then return true end
    return read_into(data + src + (first - dest), last - first, big + (first - ATTACHMENTS))
end

-- A weapon's customization as the game composes it for a preview (static research 0x50eee0: the weapon type's
-- component, then every customization id's patches of component type 271 in order) into big (COPY_SPAN bytes from
-- ATTACHMENTS), then decoded into w (decode_copy); true, or nil and why. Entities [game + 0x346BF98]: the types'
-- components [+0xF12CF0] (382 buckets, each component at +0x17E0 + 4872 index); the customization deltas [+0xF12E98]:
-- buckets [+0] (count [+8]), deltas [+16] {u32 op count, u32 first op}, ops [+32] {u32 type, u32 first patch, u32
-- count}, patches [+48] {u32 destination, u32 size, u32 source}, data [+64]. Runs in a job (a few reads per id).
local TYPE_BUCKETS, TYPES, TYPE_BASE, DELTAS, PAINT_TYPE = 382, 0xF12CF0, 0x17E0, 0xF12E98, 271
-- The customization deltas' tables ({buckets, count, starts, ops, patches, data}), or nil.
local function delta_tables(read, entities)
    local deltas = pointer(read, entities + DELTAS)
    local head = deltas and read(deltas, 72)
    if not head then return nil end
    local function at(o) return u32(head, o) + u32(head, o + 4) * HIGH end
    return {buckets = at(0), count = u32(head, 8), starts = at(16), ops = at(32), patches = at(48), data = at(64)}
end

-- Applies one op's patches (o: its 12 bytes) when it is of the paint component; false when a patch is unreadable.
local function apply_op(read, read_into, t, o, big)
    if u32(o, 0) ~= PAINT_TYPE then return true end
    for p = u32(o, 4), u32(o, 4) + math.min(u32(o, 8), 256) - 1 do
        local q = read(t.patches + 12 * p, 12)
        if not q or not apply_patch(read_into, t.data, u32(q, 0), u32(q, 4), u32(q, 8), big) then return false end
    end
    return true
end

-- Applies one customization id's delta (its ops in order); false when a patch is unreadable.
local function apply_id(read, read_into, t, id, big)
    local i = bucket_index(read, t.buckets, t.count, id)
    local d = i and read(t.starts + 8 * i, 8)
    if not d then return true end
    for op = u32(d, 4), u32(d, 4) + math.min(u32(d, 0), 64) - 1 do
        local o = read(t.ops + 12 * op, 12)
        if o and not apply_op(read, read_into, t, o, big) then return false end
    end
    return true
end

function Weapons.compose(read, read_into, game, w, ids, big)
    local entities = pointer(read, game + Weapons.ENTITIES)
    local types = entities and pointer(read, entities + TYPES)
    local index = types and bucket_index(read, types, TYPE_BUCKETS, w.name)
    if not index then return nil, 'weapon type not found' end
    if not read_into(types + TYPE_BASE + COPY_BYTES * index + ATTACHMENTS, COPY_SPAN, big) then
        return nil, 'weapon type unreadable'
    end
    local t = delta_tables(read, entities)
    if not t then return nil, 'customization deltas unreadable' end
    for _, id in ipairs(ids) do
        if not apply_id(read, read_into, t, id, big) then return nil, 'customization patch unreadable' end
    end
    w.copy = true
    Weapons.decode_copy(w, big)
    return true
end

-- The live units of a resolved weapon (its own and its attachments'), as the controller's unit list ({unit, any =
-- true}: every material of them is bound where it holds a LUT the plan changes; attachment: an attachment's unit, which
-- takes the plan's attachment LUTs, Recolor.ATTACHMENT).
function Weapons.units(list, out)
    out = out or {}
    for slot = 1, 3 do
        local w = list[slot]
        if w then
            if unit_id(w.unit) then out[#out + 1] = {unit = w.unit, any = true, weapon = slot} end
            for _, unit in ipairs(w.units) do
                out[#out + 1] = {unit = unit, any = true, weapon = slot, attachment = true}
            end
        end
    end
    return out
end

-- The idle checks (allocation-free): row_changed() reads the inventory row (48 bytes) and is true when its weapon
-- slots or the slot in hand differ from the last read (the first read counts as a change); held() is the slot in hand at
-- the last read; bound(entry, low, high) reads the 8 bytes at a binding's texture field (Engine.binding_entry) and is
-- true while they hold the texture object (low and high halves) a recolor bound there.
function Weapons.watch(memory, where)
    local row_at = ffi.cast('const uint8_t *', where.row)
    local now, kept = ffi.new('uint8_t[?]', ROW_BYTES), ffi.new('uint8_t[?]', ROW_BYTES)
    local cell = ffi.new('uint32_t[2]') -- the binding's two halves, compared as read (no byte decoding per frame)
    local primed = false
    local self = {reads = 0}
    local entry_p, entry_at = nil, nil
    function self.row_changed()
        self.reads = self.reads + 1
        if not memory.read_into(row_at, ROW_BYTES, now) then return true end
        -- the three weapon slots (+0 to +11) and the slot in hand (+28), not the throwable or backpack fields (a grenade
        -- thrown changes them)
        local same = primed
        if same then
            for i = 0, 11 do
                if now[i] ~= kept[i] then same = false end
            end
            for i = CURRENT, CURRENT + 3 do
                if now[i] ~= kept[i] then same = false end
            end
        end
        if same then return false end
        ffi.copy(kept, now, ROW_BYTES)
        primed = true
        return true
    end
    function self.held() return u32(kept, CURRENT) end
    function self.bound(entry, low, high)
        if entry ~= entry_at then entry_p, entry_at = ffi.cast('const uint8_t *', entry), entry end
        self.reads = self.reads + 1
        if not memory.read_into(entry_p, 8, cell) then return false end
        return cell[0] == low and cell[1] == high
    end
    return self
end

-- Resolving and kits run on changes only: interpreted. The watch (its two checks are the per-frame step's) stays
-- compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({pointer, unit_id, Weapons.locate, u64, Weapons.owned, entity_record, attachment_units,
                         weapon_of, override_rows,
                         Weapons.decode_copy, Weapons.resolve, Weapons.package, Weapons.preview, hex_mod, bucket_index,
                         apply_patch, delta_tables, apply_op, apply_id, Weapons.compose, templated, Weapons.kit,
                         paired_units, take_classes,
                         Weapons.units}) do
        jit.off(fn, true)
    end
end

return Weapons
