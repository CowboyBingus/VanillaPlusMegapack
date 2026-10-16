-- A simulated game for Match Your Colors' tests: the memory the mod reads (player, customization, entity,
-- avatar and preview managers with a local and a remote player) and the engine calls it makes (units, meshes,
-- materials with LUT and pattern bindings, runtime textures, resource lookups). Addresses and layouts follow
-- src/avatar.lua and src/engine.lua (Steam build 25480438).
local ffi = require('ffi')

local Fake = {}
local HIGH = 4294967296
Fake.GAME = 0x7FF000000000
Fake.PLAYERS, Fake.CUSTOMIZATION, Fake.ENTITIES = 0x100000000, 0x110000000, 0x120000000
Fake.AVATARS, Fake.PREVIEWS = 0x130000000, 0x140000000
Fake.UI = 0x160000000 -- the UiPreviewSystem (src/preview.lua)
Fake.UI_SLOTS = {1, 3} -- the UI preview slots of player 0 (local) and player 1 (remote)
Fake.LUT_SLOT = 0x7e662968
Fake.PATTERN_SLOT = 0x81d4c49d
Fake.CAPE_LUT_SLOT = 0x0e494183
Fake.DECAL_SLOT = 0x632a8b80
Fake.BC3 = 0x10000002 -- a cape's decal sheet copy (src/engine.lua)
Fake.BC1, Fake.ALBEDO_SLOT = 0x10000000, 0xac652e43 -- a mod's recolored albedo (src/albedo.lua) and its slot
Fake.AVATAR = {0x294dfa97, 0x4d1c334d}
Fake.MESH_VISIBILITY = 0xDC -- a mesh's visibility mask (src/engine.lua Engine.MESH_VISIBILITY; Hide Cape)

-- A sparse address space of byte regions.
function Fake.space()
    local regions = {}
    local self = {reads = 0}
    function self.region(base, size)
        local buffer = ffi.new('uint8_t[?]', size)
        regions[#regions + 1] = {base = base, size = size, buffer = buffer}
        return buffer
    end
    local function find(address, size)
        for _, r in ipairs(regions) do
            if address >= r.base and address + size <= r.base + r.size then return r end
        end
        return nil
    end
    local sources, sources_region = {}, {}
    -- A pointer becomes a number through one union (no allocation, as in bingus_memory).
    local cell = ffi.new('union { const void *pointer; struct { uint32_t low, high; }; }')
    function self.read_into(pointer, size, out)
        local address = pointer
        if type(pointer) ~= 'number' then
            cell.pointer = pointer
            address = cell.low + cell.high * HIGH
        end
        local r = find(address, size)
        if not r then return false end
        -- Pointer arithmetic boxes a new pointer: one per address is made once (no allocation per read).
        local source = sources[address]
        if not source or sources_region[address] ~= r then
            source = r.buffer + (address - r.base)
            sources[address], sources_region[address] = source, r
        end
        ffi.copy(out, source, size)
        return true
    end
    function self.u32(address, value)
        local r = assert(find(address, 4), string.format('no region at %x', address))
        local o = address - r.base
        for k = 0, 3 do r.buffer[o + k] = math.floor(value / 256 ^ k) % 256 end
    end
    function self.u64(address, value)
        self.u32(address, value % HIGH)
        self.u32(address + 4, math.floor(value / HIGH))
    end
    function self.byte(address, value)
        local r = assert(find(address, 1))
        r.buffer[address - r.base] = value
    end
    function self.get32(address)
        local b = ffi.new('uint8_t[4]')
        assert(self.read_into(address, 4, b))
        return b[0] + b[1] * 256 + b[2] * 65536 + b[3] * 16777216
    end
    return self
end

-- A game map at header address `at` (data placed at `data`): keys -> values, multiplier 1, capacity 64 (or capacity).
local function map(space, at, data, entries, capacity)
    capacity = capacity or 64
    space.region(data, capacity * 8)
    space.u64(at, data) space.u32(at + 8, capacity) space.u32(at + 12, 0xFFFFFFFF) space.u32(at + 16, 1)
    for slot = 0, capacity - 1 do space.u32(data + 8 * slot, 0xFFFFFFFF) end
    for key, value in pairs(entries) do
        local slot = key % capacity
        while space.get32(data + 8 * slot) ~= 0xFFFFFFFF do slot = (slot + 1) % capacity end
        space.u32(data + 8 * slot, key) space.u32(data + 8 * slot + 4, value)
    end
end

-- The world: two players (index 0 local, entity 5; index 1 remote, entity 6), their customization records,
-- avatar entities (0xe5 local, 0xe6 remote) and avatar records with unit arrays, the preview manager and the UI
-- preview system (UI slots 1 local, 3 remote; nothing shown until Fake.show_ui). As in the game (live dump
-- 2026-10-16), the player manager's entity records +232 (count +132) hold only this machine's player; the map +208
-- (capacity 8) holds both.
-- options: {local_units = {[{type, slot}] = unit}, remote_units = ..., helmet, armor, body, previews = bool,
-- ui = bool, players (0: no players, a world loading), no_manager = bool (no player manager: the title screen)}
function Fake.world(options)
    local s = Fake.space()
    local g = Fake.GAME
    s.region(g + 0x3326000, 0x200000) -- the game.dll globals the mod reads
    s.u64(g + 0x3326468, options.no_manager and 0 or Fake.PLAYERS) s.u64(g + 0x33264F8, Fake.CUSTOMIZATION)
    s.u64(g + 0x3326D20, Fake.AVATARS) s.u64(g + 0x346BF98, Fake.ENTITIES)
    s.u64(g + 0x346D580, options.previews and Fake.PREVIEWS or 0)
    s.u64(g + 0x347CE60, options.ui and Fake.UI or 0)
    if options.ui then s.region(Fake.UI + 49160, 160 * 8 + 16) end
    -- players
    local P = Fake.PLAYERS
    s.region(P, 0x1000)
    local none = options.players == 0
    s.u32(P + 132, none and 0 or 1)
    local records = 0x150000000
    s.region(records, 0x100)
    for i, entity in ipairs({5, 6}) do
        local record = records + 32 * (i - 1)
        s.u32(record + 8, entity)
        s.byte(record + 20, i == 1 and 1 or 0)
        if i == 1 then s.u64(P + 232, record) end -- this machine's player only
        -- peers as exact halves (0x00c0ffee5eed0001 is above 2^53: a Lua number would round it)
        s.u32(P + 712 + 56 * (i - 1), i == 1 and 0x5eed0001 or 0x1234)
        s.u32(P + 716 + 56 * (i - 1), i == 1 and 0x00c0ffee or 0)
        s.u32(P + 936 + 32 * (i - 1), i == 1 and 0x96 or 0x97)
        s.u32(P + 948 + 32 * (i - 1), Fake.UI_SLOTS[i])
    end
    map(s, P + 208, 0x151000000, none and {} or {[5] = 0, [6] = 1}, 8)
    -- customization: records 0 (local) and 1 (remote)
    local C = Fake.CUSTOMIZATION
    s.region(C, 0x1000)
    map(s, C + 2352, 0x152000000, {[5] = 0, [6] = 1})
    s.u32(C + 2412, options.body or 0) s.u32(C + 2416, options.helmet or 0xa5574ac2)
    s.u32(C + 2420, 0x72492837) s.u32(C + 2424, options.armor or 0x0ade6719)
    s.u32(C + 2412 + 68, 0) s.u32(C + 2416 + 68, 0x11111111) s.u32(C + 2424 + 68, 0x22222222)
    -- entities: unit 0x96 -> entity 194 (avatar 0xe5, local), unit 0x97 -> entity 195 (avatar 0xe6, remote)
    local E = Fake.ENTITIES
    s.region(E + 0xF22EC8, 32)
    map(s, E + 0xF22EC8, 0x153000000, {[0x96] = 194, [0x97] = 195})
    s.region(E + 0xF32F18 + 24 * 194, 48)
    for k, id in ipairs({0xe5, 0xe6}) do
        local at = E + 0xF32F18 + 24 * (193 + k)
        s.u32(at, Fake.AVATAR[1]) s.u32(at + 4, Fake.AVATAR[2]) s.u32(at + 8, id)
        s.byte(at + 20, k == 1 and 1 or 0)
    end
    -- avatars: index 0 local, 1 remote
    local A = Fake.AVATARS
    s.region(A, 0x200)
    s.u32(A + 0x6c, 2)
    map(s, A + 248, 0x154000000, {[0xe5] = 0, [0xe6] = 1})
    s.region(A + 5532272, 440 * 2)
    for key, unit in pairs(options.local_units or {}) do s.u32(A + 5532272 + 220 + 40 * key[1] + 4 * key[2], unit) end
    for key, unit in pairs(options.remote_units or {}) do
        s.u32(A + 5532272 + 440 + 220 + 40 * key[1] + 4 * key[2], unit)
    end
    if options.previews then
        s.region(Fake.PREVIEWS + 2080, 2184 * 5)
        s.u64(Fake.PREVIEWS + 2080, 0x1234) -- slot 0: the remote player's
        s.u32(Fake.PREVIEWS + 2080 + 2184, 0x5eed0001) -- slot 1: the local player's
        s.u32(Fake.PREVIEWS + 2080 + 2184 + 4, 0x00c0ffee)
    end
    return s
end

-- One more entry (or a new value) in the game map whose header is at `at` (made by map above): key -> value.
function Fake.put(space, at, key, value)
    local data, capacity = space.get32(at) + space.get32(at + 4) * HIGH, space.get32(at + 8)
    local slot = key % capacity
    while space.get32(data + 8 * slot) ~= 0xFFFFFFFF and space.get32(data + 8 * slot) ~= key do
        slot = (slot + 1) % capacity
    end
    space.u32(data + 8 * slot, key) space.u32(data + 8 * slot + 4, value)
end

-- A byte region at `at` (size: 440 or less) unless one holds it already.
local probe = ffi.new('uint8_t[440]')
local function ensure(space, at, size)
    if not space.read_into(at, size, probe) then space.region(at, size) end
end

-- Another player's Helldiver (a squad of three, a respawn): h = {unit (the player's), entity (its entity index: 194
-- and 195 are Fake.world's), avatar (its entity id), index (its avatar index), units = {[{type, slot}] = unit}}: the
-- unit's entity record as an avatar not owned here, the avatar map and record. Returns its entity record's address
-- (an inventory row's entity, Fake.weapons add).
function Fake.helldiver(space, h)
    local E, A = Fake.ENTITIES, Fake.AVATARS
    Fake.put(space, E + 0xF22EC8, h.unit, h.entity)
    local at = E + 0xF32F18 + 24 * h.entity
    ensure(space, at, 24)
    space.u32(at, Fake.AVATAR[1]) space.u32(at + 4, Fake.AVATAR[2]) space.u32(at + 8, h.avatar) space.byte(at + 20, 0)
    Fake.put(space, A + 248, h.avatar, h.index)
    if space.get32(A + 0x6c) <= h.index then space.u32(A + 0x6c, h.index + 1) end
    local record = A + 5532272 + 440 * h.index
    ensure(space, record, 440)
    for o = 0, 116, 4 do space.u32(record + 220 + o, 0) end
    for key, unit in pairs(h.units or {}) do space.u32(record + 220 + 40 * key[1] + 4 * key[2], unit) end
    return at
end

-- A third player: p = {entity (its player entity id), index (player manager), peer (low half), record
-- (customization), helmet, armor, helldiver (Fake.helldiver's h)}. Returns its avatar's entity record address.
function Fake.player(space, p)
    local P, C = Fake.PLAYERS, Fake.CUSTOMIZATION
    Fake.put(space, P + 208, p.entity, p.index)
    space.u32(P + 712 + 56 * p.index, p.peer) space.u32(P + 716 + 56 * p.index, 0)
    Fake.put(space, C + 2352, p.entity, p.record)
    local kits = C + 2412 + 68 * p.record
    space.u32(kits, 0) space.u32(kits + 4, p.helmet) space.u32(kits + 8, 0) space.u32(kits + 12, p.armor)
    return Fake.respawn(space, p.index, p.helldiver)
end

-- Player `index`'s new Helldiver (Fake.helldiver's h): the player manager names its unit. Returns its avatar's entity
-- record address.
function Fake.respawn(space, index, h)
    space.u32(Fake.PLAYERS + 936 + 32 * index, h.unit)
    return Fake.helldiver(space, h)
end

-- Shows (or with kits nil, hides) UI preview slot `slot`: kits {helmet, armor, body}, units {[{type, slot}] = unit}.
function Fake.show_ui(space, slot, kits, units)
    local record = Fake.UI + 49160 + 160 * slot
    local mask = space.get32(Fake.UI + 50444)
    local shown = math.floor(mask / 2 ^ slot) % 2 == 1
    if kits and not shown then mask = mask + 2 ^ slot elseif not kits and shown then mask = mask - 2 ^ slot end
    space.u32(Fake.UI + 50444, mask)
    local count = 0
    for s = 0, 7 do if math.floor(mask / 2 ^ s) % 2 == 1 then count = count + 1 end end
    space.u32(Fake.UI + 50440, count)
    for o = 12, 128, 4 do space.u32(record + o, 0) end
    if not kits then return end
    space.u32(record + 136, kits.body or 0) space.u32(record + 140, kits.armor) space.u32(record + 144, kits.helmet)
    space.u32(record + 148, kits.cape or 0x72492837)
    for key, unit in pairs(units or {}) do space.u32(record + 12 + 40 * key[1] + 4 * key[2], unit) end
end

-- The squad session (src/lineup.lua; after Fake.lobby, which places the network context): the local peer {low, high}
-- and the session peers {{low, high, UI slot}, ...}.
function Fake.session(space, local_peer, entries)
    space.region(Fake.CONTEXT + 0xB398, 8)
    space.region(Fake.CONTEXT + 0x16390, 136)
    space.u32(Fake.CONTEXT + 0xB398, local_peer[1]) space.u32(Fake.CONTEXT + 0xB39C, local_peer[2])
    space.u32(Fake.CONTEXT + 0x16390, #entries)
    for i, e in ipairs(entries) do
        local at = Fake.CONTEXT + 0x16398 + 32 * (i - 1)
        space.u32(at, e[1]) space.u32(at + 4, e[2]) space.u32(at + 20, e[3])
    end
end

-- A player's desired kits (customization record r: 0 the local player's, 1 the remote's), the ones a squad card shows:
-- {helmet, armor, cape}.
function Fake.desired(space, r, kits)
    local at = Fake.CUSTOMIZATION + 2684 + 64 * r
    space.u32(at + 4, kits.helmet) space.u32(at + 8, kits.cape or 0x72492837) space.u32(at + 12, kits.armor)
end

-- Address of the local avatar's unit (type, slot), and of a preview entry's.
function Fake.local_unit_at(t, slot) return Fake.AVATARS + 5532272 + 220 + 40 * t + 4 * slot end
function Fake.preview_entry_at(slot_index, n) return Fake.PREVIEWS + 2080 + 2184 * slot_index + 68 + 132 * n end

-- The engine: units {unit -> {alive, materials = {{mesh, material}}}}, material binding arrays in the space
-- ({slot, object} entries of 16 bytes: the LUT, then the pattern when the unit has one, then a cape's cape LUT),
-- textures. vanilla: {lut, pattern or cape LUT hex -> texture object address}.
function Fake.engine(space, vanilla)
    local native = {}
    local units, created, objects = {}, {}, {}
    local next_material, next_texture, next_handle = 0x160000000, 0x170000000, 1
    local self = {units = units, created = created, vanilla = vanilla, native = native, commits = {}}

    -- A unit whose materials are bound to the vanilla object of `lut` (none: a mod's material without a color table)
    -- and, when given, of `pattern`, of `cape_lut` (a cape's tint LUT), of `decal` (its decal sheet) and of `albedo`
    -- (one mesh per unit, `count` materials).
    function self.unit(unit, lut, count, pattern, cape_lut, decal, albedo)
        local list = {}
        local mesh = 0x180000000 + unit * 16
        space.region(mesh + Fake.MESH_VISIBILITY, 4) -- the mesh's visibility mask: shown everywhere
        space.byte(mesh + Fake.MESH_VISIBILITY, 0xFF)
        for _ = 1, count or 2 do
            local material = next_material
            next_material = next_material + 0x100
            space.region(material, 0x70)
            local array = material + 0x40 -- the binding array lives right after the header (fake layout)
            local slots = lut and {{Fake.LUT_SLOT, lut}} or {}
            if pattern then slots[#slots + 1] = {Fake.PATTERN_SLOT, pattern} end
            if cape_lut then slots[#slots + 1] = {Fake.CAPE_LUT_SLOT, cape_lut} end
            if decal then slots[#slots + 1] = {Fake.DECAL_SLOT, decal} end
            if albedo then slots[#slots + 1] = {Fake.ALBEDO_SLOT, albedo} end
            space.u32(material + 24, #slots) space.u64(material + 32, array)
            for i, s in ipairs(slots) do
                space.u32(array + 16 * (i - 1), s[1]) space.u64(array + 16 * (i - 1) + 8, vanilla[s[2]])
            end
            list[#list + 1] = {mesh = mesh, material = material}
        end
        units[unit] = {alive = true, materials = list, mesh = mesh}
        return list
    end
    -- The address of a material's binding entry for `slot` (the LUT slot when nil).
    local function entry(material, slot)
        local array = material + 0x40
        for i = 0, space.get32(material + 24) - 1 do
            if space.get32(array + 16 * i) == (slot or Fake.LUT_SLOT) then return array + 16 * i end
        end
        error(string.format('material %x has no slot %x', material, slot or Fake.LUT_SLOT))
    end
    self.entry = entry
    function self.binding(material, slot)
        local at = entry(material, slot)
        return space.get32(at + 8) + space.get32(at + 12) * HIGH
    end

    -- set_unit_visibility as the unit's world runs it (here at once): the mesh mask 0 hidden, 0xFF shown; calls kept.
    self.visibility = {}
    function native.visibility(unit, visible, children)
        local u = units[unit]
        assert(u and u.alive and children == 1, 'visibility of a live unit, its children included')
        space.byte(u.mesh + Fake.MESH_VISIBILITY, visible ~= 0 and 0xFF or 0)
        self.visibility[#self.visibility + 1] = {unit = unit, visible = visible}
    end
    function self.hidden(unit)
        local b = ffi.new('uint8_t[1]')
        assert(space.read_into(units[unit].mesh + Fake.MESH_VISIBILITY, 1, b))
        return b[0] == 0
    end
    function native.alive(unit) return units[unit] and units[unit].alive and 1 or 0 end
    function native.meshes(unit) return units[unit] and 1 or 0 end
    function native.mesh(unit) return units[unit].mesh end
    function native.materials(mesh)
        for _, u in pairs(units) do if u.mesh == mesh then return #u.materials end end
        return 0
    end
    function native.material(mesh, j)
        for _, u in pairs(units) do if u.mesh == mesh then return u.materials[j + 1].material end end
        return 0
    end
    function native.commit(mesh) self.commits[#self.commits + 1] = mesh end
    function native.set_resource(material, slot, object)
        assert(slot == Fake.LUT_SLOT or slot == Fake.PATTERN_SLOT or slot == Fake.CAPE_LUT_SLOT
               or slot == Fake.DECAL_SLOT or slot == Fake.ALBEDO_SLOT, 'LUT, pattern, cape LUT, decal sheet or albedo slot')
        space.u64(entry(material, slot) + 8, object)
    end
    -- Textures are made updatable (validity 1); update() refills one of the same size. A LUT is RGBA32F of one mip,
    -- a decal sheet copy BC3 with its mips (view[6]), a mod's albedo BC1 or BC3 with its mips.
    function native.create(size, validity, view_type, view, data)
        assert(validity == 1 and view_type == 3)
        assert((view[0] == 0x80820820 and view[6] == 1 and size == view[2] * view[3] * 16)
               or ((view[0] == Fake.BC3 or view[0] == Fake.BC1) and view[6] > 1 and size > 0),
               'an RGBA32F LUT, a BC3 sheet or a BC1 or BC3 albedo')
        local handle = next_handle
        next_handle = next_handle + 1
        local object = next_texture
        next_texture = next_texture + 0x100
        space.region(object, 16)
        space.u32(object, 0x3800 + handle)
        created[handle] = {object = object, data = data, alive = true, size = size, updates = 0, format = view[0],
                           mips = view[6]}
        objects[handle] = object
        return handle
    end
    function native.update(handle, size, data)
        local texture = created[handle]
        assert(texture and texture.alive and size == texture.size and data ~= nil, 'refilling a live texture')
        texture.data, texture.updates = data, texture.updates + 1
    end
    function native.resource(handle) return objects[handle] or 0 end
    function native.destroy(handle)
        assert(created[handle] and created[handle].alive, 'destroying a texture twice')
        created[handle].alive = false
    end
    local by_name = {}
    for lut, object in pairs(vanilla) do by_name[lut] = object end
    local function hex(name)
        local high = tonumber(name / 4294967296ULL)
        local low = tonumber(name % 4294967296ULL)
        return string.format('%08x%08x', high, low)
    end
    function native.can_get(_, name) return by_name[hex(name)] and 1 or 0 end
    function native.get(_, name) return by_name[hex(name)] or 0 end
    return self
end

-- Recolor Weapons (src/weapons.lua): the inventory [game + 0x3326738] (map +40 from the avatars 0xe5 local and 0xe6
-- remote to rows [+80] of 48 bytes, each row's entity [+64] (the avatar's entity record), the count +20), the weapon
-- entities (map entities + 0xF1AEB0, records from index 300), the weapon customization manager [game + 0x3326A38] (map
-- +632 to records [+672] of 128 bytes, map +696 to copies [+760] of 4872 bytes: attachment names +0x78.., the
-- MaterialOverride +200) and the Armory's weapon preview (UiPreviewSystem weapon slot 3, the ring head +50448: with the
-- world's ui option). Returns {set(slot, weapon or nil, row index), hold(slot, row index), preview(weapon or nil),
-- row(row index), index(avatar) (its row index or nil), add(avatar, entity record address) (a new avatar's row, last),
-- remove(avatar) (as the game's 0x9b2810 -> 0x9b15d0: the last row and its entity moved into the freed index, the map
-- updated, the last row's bytes left as they were)}; weapon: {id, name (16 hex digits), unit, units = {attachment
-- units}, attachments = {[role 1-4] = name}, paint = {[slot key] = lut}, ids (preview: its customization ids)}.
Fake.INVENTORY, Fake.WCM = 0x1A0000000, 0x1A1000000
local WEAPON_RECORDS, WEAPON_COPIES, INVENTORY_ROWS, INVENTORY_OWNERS = 0x1A4000000, 0x1A5000000, 0x1A3000000,
    0x1A9000000
local INVENTORY_CAPACITY = 8
function Fake.weapons(space)
    local g, E = Fake.GAME, Fake.ENTITIES
    space.u64(g + 0x3326738, Fake.INVENTORY) space.u64(g + 0x3326A38, Fake.WCM)
    space.region(Fake.INVENTORY, 0x100)
    map(space, Fake.INVENTORY + 40, 0x1A2000000, {[0xe5] = 0, [0xe6] = 1})
    space.region(INVENTORY_ROWS, 48 * INVENTORY_CAPACITY)
    space.region(INVENTORY_OWNERS, 8 * INVENTORY_CAPACITY)
    space.u64(Fake.INVENTORY + 80, INVENTORY_ROWS) space.u64(Fake.INVENTORY + 64, INVENTORY_OWNERS)
    local rows = {[0] = 0xe5, 0xe6} -- the avatar of each row
    local records = {[0xe5] = E + 0xF32F18 + 24 * 194, [0xe6] = E + 0xF32F18 + 24 * 195}
    local count = 2
    space.region(E + 0xF1AEB0, 32)
    space.region(E + 0xF32F18 + 24 * 300, 24 * 32)
    space.region(Fake.WCM, 0x400)
    space.region(WEAPON_RECORDS, 128 * 32)
    space.region(WEAPON_COPIES, 4872 * 32)
    space.u64(Fake.WCM + 672, WEAPON_RECORDS) space.u64(Fake.WCM + 760, WEAPON_COPIES)
    local ids, next_index = {}, 0 -- entity id -> its index (entity record, customization record and copy)
    local self = {}
    map(space, E + 0xF1AEB0, 0x1A6000000, {})
    map(space, Fake.WCM + 632, 0x1A7000000, {})
    map(space, Fake.WCM + 696, 0x1A8000000, {})
    -- A map's data (made by map above) filled again with entries.
    local function refill(data, entries)
        for slot = 0, 63 do space.u32(data + 8 * slot, 0xFFFFFFFF) end
        for key, value in pairs(entries) do
            local slot = key % 64
            while space.get32(data + 8 * slot) ~= 0xFFFFFFFF do slot = (slot + 1) % 64 end
            space.u32(data + 8 * slot, key) space.u32(data + 8 * slot + 4, value)
        end
    end
    local function maps()
        local entities = {}
        for id, i in pairs(ids) do entities[id] = 300 + i end
        refill(0x1A6000000, entities)
        refill(0x1A7000000, ids)
        refill(0x1A8000000, ids)
    end
    -- The inventory's map, entities and count from rows (a row past the count keeps its bytes and entity).
    local function inventory()
        local index = {}
        for i = 0, count - 1 do
            index[rows[i]] = i
            space.u64(INVENTORY_OWNERS + 8 * i, records[rows[i]])
        end
        refill(0x1A2000000, index)
        space.u32(Fake.INVENTORY + 20, count)
    end
    inventory()
    local function name_at(at, name)
        space.u32(at, tonumber(name:sub(9, 16), 16)) space.u32(at + 4, tonumber(name:sub(1, 8), 16))
    end
    -- One weapon's entity record, customization record and copy (paint rows: slot key, LUT name).
    local function write_weapon(w)
        local i = ids[w.id]
        if not i then
            i, next_index = next_index, next_index + 1
            ids[w.id] = i
            maps()
        end
        local record = E + 0xF32F18 + 24 * (300 + i)
        name_at(record, w.name) space.u32(record + 8, w.id) space.u32(record + 12, w.unit)
        local r = WEAPON_RECORDS + 128 * i
        for k, unit in ipairs(w.units or {}) do space.u32(r + ({8, 12, 40, 68, 96})[k], unit) end
        local c = WEAPON_COPIES + 4872 * i
        local at = {0x78, 0x80, 0xA0, 0xC0}
        for role, name in pairs(w.attachments or {}) do name_at(c + at[role], name) end
        local row = 0
        for key, lut in pairs(w.paint or {}) do
            space.u32(c + 200 + 40 * row, key)
            name_at(c + 200 + 40 * row + 8, lut)
            row = row + 1
        end
    end
    -- Puts weapon (nil: none) in the inventory slot (1 primary, 2 sidearm, 3 support) of avatar index a (0 local).
    function self.set(slot, w, a)
        if w then write_weapon(w) end
        space.u32(INVENTORY_ROWS + 48 * (a or 0) + 4 * (slot - 1), w and w.id or 0)
    end
    function self.hold(slot, a) space.u32(INVENTORY_ROWS + 48 * (a or 0) + 28, slot) end
    function self.row(a) return INVENTORY_ROWS + 48 * (a or 0) end
    function self.index(avatar)
        for i = 0, count - 1 do if rows[i] == avatar then return i end end
        return nil
    end
    function self.add(avatar, record)
        assert(count < INVENTORY_CAPACITY, 'inventory full')
        rows[count], records[avatar], count = avatar, record, count + 1
        for o = 0, 44, 4 do space.u32(self.row(count - 1) + o, 0) end
        inventory()
        return count - 1
    end
    function self.remove(avatar)
        local i, last = assert(self.index(avatar)), count - 1
        if i ~= last then
            for o = 0, 44, 4 do space.u32(self.row(i) + o, space.get32(self.row(last) + o)) end
            rows[i] = rows[last]
        end
        rows[last], count = nil, last
        inventory()
    end
    -- The Armory's weapon preview: slot 3 shows w (nil: none), the ring head moves.
    local preview_at = Fake.UI + 76056 + 1560 * 3
    local paired_at = preview_at + 1560 * 8 -- an underbarrel weapon's slot (src/weapons.lua paired_units)
    space.region(preview_at, 232)
    space.region(paired_at, 232)
    function self.preview(w)
        for o = 0, 228, 4 do space.u32(preview_at + o, 0) space.u32(paired_at + o, 0) end
        if w then
            space.u32(preview_at, w.unit)
            if w.paired then space.u32(paired_at, w.paired) end
            for k, unit in ipairs(w.units or {}) do space.u32(preview_at + 4 * k, unit) end
            name_at(preview_at + 128, w.name)
            space.u32(preview_at + 144, #(w.ids or {}))
            for k, id in ipairs(w.ids or {}) do name_at(preview_at + 152 + 8 * (k - 1), id) end
        end
        space.u32(Fake.UI + 50448, space.get32(Fake.UI + 50448) + 1)
    end
    return self
end

-- The squad's PlayFab lobby as src/sync.lua reads it, and PlayFab's lobby calls over it. members: {{id = entity id
-- text, value = the 'cbmyc2' property text or nil, legacy = the 'cbmyc' property text or nil (an older copy's)},
-- ...}; the local member is the one whose id is local_id. Returns {members, natives (Sync.natives' stand-in), posts =
-- {{handle (low, high), user, text, legacy}, ...}, post_result, reads = {cbmyc2 = n, cbmyc = n} (property calls by
-- key), set_joined(bool), set_handle(low, high), sync()}: change members or values, then sync() writes them into the
-- space. A successful post sets the local member's values, as PlayFab would.
Fake.CONTEXT, Fake.ENGINE_LOBBY, Fake.PLAYFAB_LOBBY = 0x1C0000000, 0x1C1000000, 0x1C2000000
local LOBBY_TEXTS, LOBBY_MEMBERS = 0x1C3000000, 0x1C4000000
-- The member list's arrays of entity keys {id, type}, 16 bytes each: PlayFab's array is valid until its next call,
-- so the fake hands out the two in turn and wipes the one it leaves (Fake.LOBBY_MEMBERS + 0 or + 0x800).
Fake.LOBBY_MEMBERS = LOBBY_MEMBERS
function Fake.lobby(space, local_id, members)
    local ffi_u64 = ffi.typeof('uint64_t')
    local self = {members = members, posts = {}, post_result = 0, reads = {cbmyc2 = 0, cbmyc = 0}}
    space.u64(Fake.GAME + 0x347CEF0, Fake.CONTEXT)
    space.region(Fake.CONTEXT + 0x1D470, 8)
    space.u64(Fake.CONTEXT + 0x1D470, Fake.ENGINE_LOBBY)
    space.region(Fake.ENGINE_LOBBY, 0x20)
    space.u64(Fake.ENGINE_LOBBY + 0x10, Fake.PLAYFAB_LOBBY)
    space.region(Fake.PLAYFAB_LOBBY, 0x200)
    local texts = space.region(LOBBY_TEXTS, 0x10000)
    local arrays = space.region(LOBBY_MEMBERS, 0x1000)
    self.array = LOBBY_MEMBERS
    local function text_at(slot, text) -- slot: 0-63 ids, 64-127 values; 256 bytes each
        local at = LOBBY_TEXTS + 256 * slot
        ffi.fill(texts + 256 * slot, 256)
        ffi.copy(texts + 256 * slot, text)
        return at
    end
    space.u64(Fake.PLAYFAB_LOBBY + 0x130, text_at(63, local_id))
    space.u64(Fake.PLAYFAB_LOBBY + 0x138, text_at(62, 'title_player_account'))
    function self.set_joined(joined) space.u32(Fake.PLAYFAB_LOBBY + 0x118, joined and 3 or 2) end
    function self.set_handle(low, high)
        space.u32(Fake.PLAYFAB_LOBBY + 0x120, low) space.u32(Fake.PLAYFAB_LOBBY + 0x124, high)
        self.handle = {low = low, high = high}
    end
    function self.sync()
        for i, member in ipairs(self.members) do
            space.u64(self.array + 16 * (i - 1), text_at(i - 1, member.id))
            space.u64(self.array + 16 * (i - 1) + 8, LOBBY_TEXTS + 256 * 62)
        end
    end
    self.set_joined(true)
    self.set_handle(0x89abcdef, 0xfedcba98) -- above 2^53: only exact as uint64
    self.sync()
    local function halves(handle)
        local value = ffi.cast(ffi_u64, handle)
        return tonumber(value % 4294967296ULL), tonumber(value / 4294967296ULL)
    end
    -- PlayFab reads both strings of the key a post names (PFLobbyPostUpdate: a bad pointer there crashed the game,
    -- 2026-10-07): an unreadable one raises here.
    local key_bytes, byte = ffi.new('uint8_t[16]'), ffi.new('uint8_t[1]')
    local function check_key(user)
        assert(space.read_into(user, 16, key_bytes), 'PlayFab read the key: unreadable')
        local words = ffi.cast('uint64_t *', key_bytes)
        for i = 0, 1 do
            local at = tonumber(words[i])
            assert(at ~= 0 and space.read_into(at, 1, byte), 'PlayFab read a bad string pointer through the key')
        end
    end
    local api = {}
    function api.post(handle, user, text, legacy)
        check_key(user)
        local low, high = halves(handle)
        self.posts[#self.posts + 1] = {low = low, high = high, user = user, text = text, legacy = legacy,
                                       array = self.array}
        if self.post_result ~= 0 then return self.post_result end
        for _, member in ipairs(self.members) do
            if member.id == local_id then member.value, member.legacy = text, legacy end
        end
        return 0
    end
    function api.members(handle)
        local low, high = halves(handle)
        assert(low == self.handle.low and high == self.handle.high, 'the lobby handle, exact')
        ffi.fill(arrays + (self.array - LOBBY_MEMBERS), 0x800) -- the previous array: no longer valid
        self.array = self.array == LOBBY_MEMBERS and LOBBY_MEMBERS + 0x800 or LOBBY_MEMBERS
        self.sync()
        return #self.members, self.array, 0
    end
    function api.property(handle, member_at, legacy)
        local low, high = halves(handle)
        assert(low == self.handle.low and high == self.handle.high, 'the lobby handle, exact')
        local i = (member_at - self.array) / 16 + 1
        local member = assert(self.members[i], 'a member key from the member list')
        local key = legacy and 'cbmyc' or 'cbmyc2'
        self.reads[key] = self.reads[key] + 1
        if member.fail then return nil, 0x80004005 end -- a failed read (member.fail), not a missing value
        local value = legacy and member.legacy or (not legacy and member.value) or nil
        if value == nil then return nil, 0 end
        return text_at((legacy and 127 or 63) + i, value), 0
    end
    -- The game's update processes PlayFab's lobby state changes every frame: the member array a call returned is no
    -- longer valid after it (a key kept from an earlier poll reads as zeros).
    function self.tick() ffi.fill(arrays + (self.array - LOBBY_MEMBERS), 0x800) end
    self.api = api
    self.natives = function() return api end
    return self
end

-- bingus_memory's api over the space: read_into, read, time (advances 0.1 ms per call), module, address.
function Fake.memory(space)
    local api = {clock = 0}
    function api.read_into(pointer, size, out) return space.read_into(pointer, size, out) end
    function api.read(pointer, size)
        local out = ffi.new('uint8_t[?]', size)
        if not space.read_into(pointer, size, out) then return nil end
        return ffi.string(out, size)
    end
    function api.time()
        api.clock = api.clock + 0.0001
        return api.clock
    end
    return api
end

return Fake
