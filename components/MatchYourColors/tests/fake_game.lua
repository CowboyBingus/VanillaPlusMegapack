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
Fake.AVATAR = {0x294dfa97, 0x4d1c334d}

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

-- A game map at header address `at` (data placed at `data`): keys -> values, multiplier 1, capacity 64.
local function map(space, at, data, entries)
    space.region(data, 64 * 8)
    space.u64(at, data) space.u32(at + 8, 64) space.u32(at + 12, 0xFFFFFFFF) space.u32(at + 16, 1)
    for slot = 0, 63 do space.u32(data + 8 * slot, 0xFFFFFFFF) end
    for key, value in pairs(entries) do
        local slot = key % 64
        while space.get32(data + 8 * slot) ~= 0xFFFFFFFF do slot = (slot + 1) % 64 end
        space.u32(data + 8 * slot, key) space.u32(data + 8 * slot + 4, value)
    end
end

-- The world: two players (index 0 local, entity 5; index 1 remote, entity 6), their customization records,
-- avatar entities (0xe5 local, 0xe6 remote) and avatar records with unit arrays, the preview manager and the UI
-- preview system (UI slots 1 local, 3 remote; nothing shown until Fake.show_ui).
-- options: {local_units = {[{type, slot}] = unit}, remote_units = ..., helmet, armor, body, previews = bool,
-- ui = bool}
function Fake.world(options)
    local s = Fake.space()
    local g = Fake.GAME
    s.region(g + 0x3326000, 0x200000) -- the game.dll globals the mod reads
    s.u64(g + 0x3326468, Fake.PLAYERS) s.u64(g + 0x33264F8, Fake.CUSTOMIZATION)
    s.u64(g + 0x3326D20, Fake.AVATARS) s.u64(g + 0x346BF98, Fake.ENTITIES)
    s.u64(g + 0x346D580, options.previews and Fake.PREVIEWS or 0)
    s.u64(g + 0x347CE60, options.ui and Fake.UI or 0)
    if options.ui then s.region(Fake.UI + 49160, 160 * 8 + 16) end
    -- players
    local P = Fake.PLAYERS
    s.region(P, 0x1000)
    s.u32(P + 132, options.players or 2)
    local records = 0x150000000
    s.region(records, 0x100)
    for i, entity in ipairs({5, 6}) do
        local record = records + 32 * (i - 1)
        s.u32(record + 8, entity)
        s.byte(record + 20, i == 1 and 1 or 0)
        s.u64(P + 232 + 8 * (i - 1), record)
        s.u64(P + 712 + 56 * (i - 1), i == 1 and 0x00c0ffee5eed0001 or 0x1234)
        s.u32(P + 936 + 32 * (i - 1), i == 1 and 0x96 or 0x97)
        s.u32(P + 948 + 32 * (i - 1), Fake.UI_SLOTS[i])
    end
    map(s, P + 208, 0x151000000, {[5] = 0, [6] = 1})
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
        s.u64(Fake.PREVIEWS + 2080 + 2184, 0x00c0ffee5eed0001) -- slot 1: the local player's
    end
    return s
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
    for key, unit in pairs(units or {}) do space.u32(record + 12 + 40 * key[1] + 4 * key[2], unit) end
end

-- Address of the local avatar's unit (type, slot), and of a preview entry's.
function Fake.local_unit_at(t, slot) return Fake.AVATARS + 5532272 + 220 + 40 * t + 4 * slot end
function Fake.preview_entry_at(slot_index, n) return Fake.PREVIEWS + 2080 + 2184 * slot_index + 68 + 132 * n end

-- The engine: units {unit -> {alive, materials = {{mesh, material}}}}, material binding arrays in the space
-- ({slot, object} entries of 16 bytes: the LUT, then the pattern when the unit has one), textures. vanilla:
-- {lut or pattern hex -> texture object address}.
function Fake.engine(space, vanilla)
    local native = {}
    local units, created, objects = {}, {}, {}
    local next_material, next_texture, next_handle = 0x160000000, 0x170000000, 1
    local self = {units = units, created = created, vanilla = vanilla, native = native, commits = {}}

    -- A unit whose materials are bound to the vanilla object of `lut` and, when given, of `pattern` (one mesh per
    -- unit, `count` materials).
    function self.unit(unit, lut, count, pattern)
        local list = {}
        local mesh = 0x180000000 + unit * 16
        for _ = 1, count or 2 do
            local material = next_material
            next_material = next_material + 0x100
            space.region(material, 0x60)
            local array = material + 0x40 -- the binding array lives right after the header (fake layout)
            space.u32(material + 24, pattern and 2 or 1) space.u64(material + 32, array)
            space.u32(array, Fake.LUT_SLOT) space.u64(array + 8, vanilla[lut])
            if pattern then space.u32(array + 16, Fake.PATTERN_SLOT) space.u64(array + 24, vanilla[pattern]) end
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
        assert(slot == Fake.LUT_SLOT or slot == Fake.PATTERN_SLOT, 'LUT or pattern slot')
        space.u64(entry(material, slot) + 8, object)
    end
    -- Textures are made updatable (validity 1); update() refills one of the same size.
    function native.create(size, validity, view_type, view, data)
        assert(validity == 1 and view_type == 3 and view[0] == 0x80820820 and size == view[2] * view[3] * 16)
        local handle = next_handle
        next_handle = next_handle + 1
        local object = next_texture
        next_texture = next_texture + 0x100
        space.region(object, 16)
        space.u32(object, 0x3800 + handle)
        created[handle] = {object = object, data = data, alive = true, size = size, updates = 0}
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
