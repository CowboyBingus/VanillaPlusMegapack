-- Offline tests for Flame Damage Fixed against synthetic engine structures, with per-frame call budgets.
-- Usage: luajit tests/test_fix.lua <project root>   (also run in the game's lua51.dll by scripts/build.py)
local root = assert(arg[1], 'project root required')
local budget = dofile(root .. '/tests/frame_budget.lua')
_G.FLAME_DAMAGE_FIXED_TEST = true
local Fix = dofile(root .. '/src/flame_damage_fixed.lua')
_G.FLAME_DAMAGE_FIXED_TEST = nil
-- The mod installs the shared runtime's update guard; the guard tests build it the same way the mod does.
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local PRINT_BUDGETS = os.getenv('FDF_PRINT_BUDGETS') ~= nil

local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function le64(v) return le32(v % 4294967296) .. le32(math.floor(v / 4294967296)) end
local function word_at(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function pin(f, limits, label)
    if PRINT_BUDGETS then print(label .. ': ' .. budget.describe(f)) end
    budget.check(f, limits, label)
    for name, limit in pairs(limits) do
        assert((f[name] or 0) == limit, label .. ': api.' .. name .. ' ' .. tostring(f[name]) .. ' calls, pinned ' .. limit)
    end
end

-- Synthetic stand-in for the shipped flame effect (no game resources in source control): the header,
-- every system's size word and the 16 fixable words at their shipped values; tests/test_constants.py
-- checks those values against a locally extracted copy of the real effect.
local SHIPPED
do
    local words, keys = {}, {}
    for i, word in ipairs(Fix.HEADER) do words[4 * (i - 1)] = word end
    for _, system in ipairs(Fix.SYSTEMS) do words[system[1] + 0x100] = system[2] end
    for _, row in ipairs(Fix.PATCHES) do words[row.o] = row.v end
    for k in pairs(words) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts, offset = {}, 0
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.rep('\0', k - offset) .. le32(words[k])
        offset = k + 4
    end
    parts[#parts + 1] = string.rep('\0', Fix.EFFECT_SIZE - offset)
    SHIPPED = table.concat(parts)
    assert(#SHIPPED == Fix.EFFECT_SIZE)
end

-- Byte segments plus a word overlay: u32 writes land in the overlay (no string is rebuilt, so frames that
-- rewrite known words allocate nothing), byte writes rebuild their segment.
local function Memory()
    local m = {segments = {}, writable = true}
    local overlay = {}
    m.overlay = overlay
    function m.put(base, bytes) m.segments[#m.segments + 1] = {base = base, bytes = bytes} end
    local function find(address, size)
        local segments = m.segments
        for i = 1, #segments do
            local s = segments[i]
            if address >= s.base and address + size <= s.base + #s.bytes then return s end
        end
    end
    local function word(address)
        local v = overlay[address]
        if v then return v end
        local s = find(address, 4)
        if not s then return nil end
        return word_at(s.bytes, address - s.base)
    end
    m.word = word
    function m.poke(address, bytes)
        local s = assert(find(address, #bytes), 'poke outside memory')
        local o = address - s.base
        s.bytes = s.bytes:sub(1, o) .. bytes .. s.bytes:sub(o + #bytes + 1)
        for a = address - address % 4, address + #bytes - 1, 4 do overlay[a] = nil end
    end
    local api = {}
    function api.u32(address) return word(address) end
    function api.read(address, size)
        if not find(address, size) then return nil end
        local parts = {}
        for a = address, address + size - 1, 4 do parts[#parts + 1] = le32(word(a)) end
        return table.concat(parts):sub(1, size)
    end
    local view_base = 0
    local view = setmetatable({}, {__index = function(_, k) return word(view_base + 4 * k) end})
    function api.load(address, size)
        if size < 4 or size > 65536 or not find(address, size) then return nil end
        view_base = address
        return view
    end
    function api.writable_data(address, size) return m.writable and find(address, size) ~= nil end
    -- Segments stand in for heap regions: the region runs from the queried page's segment start.
    function api.writable_region(address)
        local s = m.writable and find(address, 4)
        if not s then return nil end
        return s.base, #s.bytes
    end
    function api.write_raw(address, bytes)
        if not find(address, #bytes) then return false end
        m.poke(address, bytes); return true
    end
    function api.write_u32(address, value)
        if not find(address, 4) then return false end
        overlay[address] = value
        return true
    end
    m.api = api
    return m
end

-- ---- synthetic engine layout -------------------------------------------------------------
local GAME, EXE = 0x7ff000000000, 0x7ff100000000
local ROOT_OBJ, RM, TYPES, NAMES, RECORDS, DATA = 0x10000000, 0x10001000, 0x10010000, 0x10020000, 0x10030000, 0x10100000
local SPRAY_MGR, ENTITY_PTRS, INSTANCES, ENT_ARM, ENT_SENTRY, ENT_OTHER =
    0x20000000, 0x20001000, 0x20002000, 0x20010000, 0x20010100, 0x20010200
local SENTRY_STATE, ARM_STATE = INSTANCES, INSTANCES + 0x218
local ARM_INSTANCE_ID, SENTRY_INSTANCE_ID = ARM_STATE + 0x24, SENTRY_STATE + 0x24
-- Units: slot = handle & 0x3fffff. The hull's children are the arm, the cannon and a seated pilot (whose
-- rifle hangs below the pilot); the Flame Sentry and a Charger stand alone.
local H = {hull = 0x400010, arm = 0x400011, cannon = 0x400012, pilot = 0x400013, rifle = 0x400014,
           sentry = 0x400015, charger = 0x400016}
local ID1, ID2 = 0x21512, 0x21544 -- flame instance ids (instance record +0x10)

local function world(options)
    options = options or {}
    local m = Memory()
    m.put(EXE + 0x23621a8, le64(ROOT_OBJ))
    m.put(ROOT_OBJ + 0x3f8, le64(RM))
    local buckets, particles_hi = 4, 0xa8193123
    m.put(RM, string.rep('\0', 0x2f0) .. le64(TYPES) .. string.rep('\0', 8) .. le32(2) .. le32(buckets))
    local types = {}
    for i = 0, buckets - 1 do types[i] = string.rep('\0', 0xc8) .. le32(0xfffffffe) .. string.rep('\0', 4) end
    -- A decoy type in the particles bucket chains to the particles entry.
    types[particles_hi % buckets] = le32(0x11111111) .. le32(particles_hi) .. string.rep('\0', 0xc0) .. le32(0) .. string.rep('\0', 4)
    local entry = le32(0x526fad64) .. le32(particles_hi) .. string.rep('\0', 8) .. le64(RECORDS) .. string.rep('\0', 8)
        .. le32(2048) .. le32(0) .. le64(NAMES) .. string.rep('\0', 8) .. le32(2) .. le32(8)
    types[0] = entry .. string.rep('\0', 0xc8 - #entry) .. le32(0x7fffffff) .. string.rep('\0', 4)
    local t = {}
    for i = 0, buckets - 1 do t[#t + 1] = types[i] end
    m.put(TYPES, table.concat(t))
    local names = {}
    for i = 0, 7 do names[i] = string.rep('\0', 16) .. le32(0xfffffffe) .. le32(0) end
    local effect_hi = 0xe3d15622
    if not options.effect_missing then
        names[effect_hi % 8] = le32(0xa42863c4) .. le32(effect_hi) .. le32(7) .. le32(0) .. le32(0x7fffffff) .. le32(0)
    end
    local n = {}
    for i = 0, 7 do n[#n + 1] = names[i] end
    m.put(NAMES, table.concat(n))
    m.put(RECORDS, string.rep('\0', 7 * 160) .. le64(DATA) .. string.rep('\0', 16) .. le64(Fix.EFFECT_SIZE) .. string.rep('\0', 128))
    m.put(DATA, options.effect or SHIPPED)
    -- Spray manager: Flame Sentry at index 0, Lumberer arm at index 1, an unrelated weapon at index 2.
    m.put(GAME + 0x3326bb0, le64(SPRAY_MGR))
    m.put(SPRAY_MGR, string.rep('\0', 0x38) .. le32(options.sprays or 3) .. string.rep('\0', 0x24) .. le64(ENTITY_PTRS)
        .. string.rep('\0', 8) .. le64(INSTANCES))
    m.put(ENTITY_PTRS, le64(ENT_SENTRY) .. le64(ENT_ARM) .. le64(ENT_OTHER))
    m.put(ENT_SENTRY, le32(0xfe962858) .. le32(0x820cc3ba) .. le32(7) .. le32(H.sentry) .. string.rep('\0', 16))
    m.put(ENT_ARM, le32(0xd6328726) .. le32(0x0736bee2) .. le32(8) .. le32(H.arm) .. string.rep('\0', 16))
    m.put(ENT_OTHER, le32(0x63a70795) .. le32(0x78a8185f) .. le32(9) .. le32(0x400099) .. string.rep('\0', 16)) -- the Cremator
    m.put(INSTANCES, string.rep('\0', 0x218 * 3))
    return m
end

-- ---- synthetic hknp physics: particle manager, flame instances, particle systems, filter, units, bodies --
local PM_OWNER, PM, PM_ENTRIES, PM_LISTS, INST_RECORDS, SIM1, SIM2, SYSTEMS1, SYSTEMS2 =
    0x30000000, 0x30001000, 0x30010000, 0x30020000, 0x30030000, 0x30040000, 0x30040100, 0x30050000, 0x30051000
local WORLD, PS_TABLE, PS_ARRAY, PS_HEAP, FILTER_OBJ = 0x31000000, 0x31001000, 0x31010000, 0x32000000, 0x33000000
local UNIT_REG, UNIT_OBJS, UNIT_HEAP, BODIES, ALLOC, BITMAP = 0x34000000, 0x34001000, 0x34100000, 0x35000000, 0x36000000, 0x36001000
local PS_SIZE = 0x2000
local function at(s, off, bytes) return s:sub(1, off) .. bytes .. s:sub(off + #bytes + 1) end
local function matrix_bytes(rows)
    local parts = {}
    for i = 0, 127 do
        local w = {0, 0, 0, 0}
        for j in pairs(rows[i]) do local k = math.floor(j / 32) + 1; w[k] = w[k] + 2 ^ (j % 32) end
        parts[#parts + 1] = le32(w[1]) .. le32(w[2]) .. le32(w[3]) .. le32(w[4])
    end
    return table.concat(parts)
end
local function ps_address(index) return PS_HEAP + PS_SIZE * index end
local function unit_address(handle) return UNIT_HEAP + 0x400 * (handle % 4194304) end
-- Instance 1 (SIM1) owns particle systems 1-6 (1-5 flame on layer 11, 6 another filter); instance 2 (SIM2)
-- owns 7-12. Handles: world 2, generation 9.
local function systems_block(first)
    local recs = {}
    for s = 0, 11 do
        recs[#recs + 1] = string.rep('\0', 52) .. le32(s <= 5 and 0x81090000 + first + s or 0) .. string.rep('\0', 24)
    end
    return table.concat(recs)
end
local function sim_block(data, systems)
    return at(at(string.rep('\0', 64), 32, le64(data)), 40, le32(12) .. le32(12) .. le64(systems))
end
-- Bodies (index: owner, filter info, flags): the hull's 13 layer-20 and 3 layer-54 hit-boxes, a ragdoll bone in
-- game group 44 (layer 52) and a layer-87 body; the arm's 3 and the cannon's 2 layer-20 hit-boxes; the pilot's
-- layer-2 hit-boxes carrying game data in their subsystem bits and a layer-83 body; a Charger's 4 layer-20
-- hit-boxes; the Flame Sentry's 3 layer-54 bodies and a layer-31 body with game data; a hull body that left
-- the world. Index 40+ are free slots.
local function body_table()
    local b = {}
    local function add(unit, filter, flags) b[#b + 1] = {unit = unit, filter = filter, flags = flags or 3} end
    for _ = 1, 13 do add(H.hull, 20) end
    for _ = 1, 3 do add(H.hull, 54) end
    add(H.hull, 52 + 1 * 128 + 44 * 2097152)
    add(H.hull, 87)
    for _ = 1, 3 do add(H.arm, 20) end
    for _ = 1, 2 do add(H.cannon, 20) end
    for _ = 1, 3 do add(H.pilot, 2 + 8 * 128 + 2 * 16384) end
    add(H.pilot, 83)
    for _ = 1, 4 do add(H.charger, 20) end
    for _ = 1, 3 do add(H.sentry, 54) end
    add(H.sentry, 31 + 3 * 128)
    add(H.hull, 20, 0)
    return b
end
local OWN_ARM = 21     -- hull 16 + arm 3 + cannon 2
local OWN_SENTRY = 3
local function physics(m, options)
    options = options or {}
    m.put(GAME + 0x346BFA0, le64(PM_OWNER))
    m.put(PM_OWNER + 0x230888, le64(PM))
    local buckets, effect_hi, slot = 8, 0xe3d15622, 5
    local entries = {}
    for i = 0, buckets - 1 do entries[i] = string.rep('\0', 16) .. le32(0xfffffffe) .. le32(0) end
    entries[effect_hi % buckets] = le32(0xa42863c4) .. le32(effect_hi) .. le32(slot) .. le32(0) .. le32(0x7fffffff) .. le32(0)
    local e = {}
    for i = 0, buckets - 1 do e[#e + 1] = entries[i] end
    m.put(PM_ENTRIES, table.concat(e))
    local pm = string.rep('\0', 0x280)
    pm = at(pm, 0x1b8, le64(PM_ENTRIES)); pm = at(pm, 0x1c8, le32(1)); pm = at(pm, 0x1cc, le32(buckets))
    pm = at(pm, 0x228, le32(0xff)); pm = at(pm, 0x278, le64(PM_LISTS))
    m.put(PM, pm)
    m.put(PM_LISTS, at(string.rep('\0', 24 * 8), 24 * slot, le32(options.instances or 1) .. le32(0) .. le64(INST_RECORDS)))
    local rec = string.rep('\0', 136)
    m.put(INST_RECORDS, at(at(rec, 8, le64(SIM1)), 16, le32(ID1)) .. at(at(rec, 8, le64(SIM2)), 16, le32(ID2)))
    m.put(SIM1, sim_block(options.foreign and 0x10200000 or DATA, SYSTEMS1))
    m.put(SIM2, sim_block(DATA, SYSTEMS2))
    m.put(SYSTEMS1, systems_block(1))
    m.put(SYSTEMS2, systems_block(7))
    -- The hknp world (world 2): vtable, body array (+0x38, size +0x40, index bound +0x50), particle systems.
    local bodies = options.bodies or body_table()
    local limit = options.limit or 48
    local w = string.rep('\0', 0x500)
    w = at(w, 0, le64(options.world_vtable or EXE + 0x14B3148))
    w = at(w, 0x38, le64(BODIES)); w = at(w, 0x40, le32(options.size or 4096)); w = at(w, 0x50, le32(limit))
    w = at(w, 32 + 1144, le64(PS_TABLE))
    m.put(WORLD, w)
    m.put(EXE + 0x27BA890 + 176 * 2, le64(WORLD))
    local recs = {}
    for index = 0, math.max(limit, 64) - 1 do
        local body = bodies[index + 1]
        local r = string.rep('\0', 160)
        if body then
            r = at(r, 68, le32(body.flags)); r = at(r, 108, le32(body.filter))
            r = at(r, 112, le32(index + 5 * 16777216)); r = at(r, 144, le32(0xb0000000 + index)); r = at(r, 148, le32(body.unit))
        end
        recs[#recs + 1] = r
    end
    m.put(BODIES, table.concat(recs))
    m.put(PS_TABLE + 8, le64(PS_ARRAY))
    local arr = {}
    for index = 0, 15 do
        local ps, tag = 0, 0
        if index >= 1 and index <= 12 then
            ps, tag = ps_address(index), index + 9 * 16777216
            if options.stale == index then tag = index + 8 * 16777216 end
        end
        arr[#arr + 1] = le64(ps) .. le32(tag) .. le32(0)
    end
    m.put(PS_ARRAY, table.concat(arr))
    -- All particle systems live in one heap region (one segment).
    local heap = {}
    for index = 0, 12 do
        local filter = (index == 6 or index == 12) and 0x4a or 11
        heap[#heap + 1] = string.rep('\0', 5764) .. le32(filter) .. string.rep('\0', PS_SIZE - 5768)
    end
    m.put(PS_HEAP, table.concat(heap))
    local rows = {}
    for i = 0, 127 do rows[i] = {} end
    local function link(i, j) rows[i][j] = true; rows[j][i] = true end
    for j = 0, 127 do link(0, j) end
    for _, j in ipairs(options.flame_row or Fix.FLAME_ROW) do link(11, j) end
    m.put(FILTER_OBJ, le64(options.vtable or EXE + 0x148B938) .. string.rep('\0', 32) .. matrix_bytes(rows) .. string.rep('\0', 8))
    m.put(EXE + 0x27C5E40, le64(FILTER_OBJ))
    -- Unit registry and tree (+8 handle, +0x1D0 parent, +0x1D8 first child, +0x1E0 next sibling, +0x358 resource).
    m.put(EXE + 0x1A100F0, le64(UNIT_REG))
    m.put(UNIT_REG + 0x88, le64(UNIT_OBJS))
    local tree = {
        {H.hull, 0, H.arm, 0}, {H.arm, H.hull, 0, H.cannon}, {H.cannon, H.hull, 0, H.pilot},
        {H.pilot, H.hull, H.rifle, 0, true}, {H.rifle, H.pilot, 0, 0}, {H.sentry, 0, 0, 0}, {H.charger, 0, 0, 0},
    }
    local objs = {}
    for slot = 0, 31 do objs[slot] = le64(0) end
    local heap_units = string.rep('\0', 0x400 * 32)
    for _, u in ipairs(tree) do
        local handle, parent, child, sibling, avatar = u[1], u[2], u[3], u[4], u[5]
        local slot = handle % 4194304
        objs[slot] = le64(unit_address(handle))
        local o = 0x400 * slot
        heap_units = at(heap_units, o + 8, le32(handle))
        if parent ~= 0 then heap_units = at(heap_units, o + 0x1D0, le64(unit_address(parent))) end
        if child ~= 0 then heap_units = at(heap_units, o + 0x1D8, le64(unit_address(child))) end
        if sibling ~= 0 then heap_units = at(heap_units, o + 0x1E0, le64(unit_address(sibling))) end
        heap_units = at(heap_units, o + 0x358, avatar and (le32(0x294dfa97) .. le32(0x4d1c334d)) or le64(0x1000 + slot))
    end
    local o = {}
    for slot = 0, 31 do o[#o + 1] = objs[slot] end
    m.put(UNIT_OBJS, table.concat(o))
    m.put(UNIT_HEAP, heap_units)
    -- System-group allocator: 2048 groups, one summary word, set bit = free; 0-2 in use (+ options.used).
    m.put(EXE + 0x27C5B88, le64(ALLOC))
    m.put(ALLOC, le32(2048) .. le32(1) .. le64(BITMAP))
    local used = {[0] = true, [1] = true, [2] = true}
    for _, g in ipairs(options.used or {}) do used[g] = true end
    local words = {}
    for k = 0, 63 do
        local w32 = 0
        for bitn = 0, 31 do if not used[32 * k + bitn] then w32 = w32 + 2 ^ bitn end end
        words[#words + 1] = le32(w32)
    end
    m.put(BITMAP, le64(0xffffffff) .. table.concat(words))
end

local function filter_of(m, index) return m.word(BODIES + 160 * index + 108) end
local function layer_of(m, index) return m.word(ps_address(index) + 5764) end
local function group_of(m, index) return math.floor(filter_of(m, index) / 2097152) end
local function fixed_effect(m)
    for _, row in ipairs(Fix.PATCHES) do
        if m.api.u32(DATA + row.o) ~= row.t then return false end
    end
    return true
end
-- Every body's filter info equals the original, except the listed indexes, which carry group g on top.
local function bodies_are(m, marked, g, label)
    local set = {}
    for _, i in ipairs(marked) do set[i] = true end
    for index, body in ipairs(body_table()) do
        local want = body.filter + (set[index - 1] and g * 2097152 or 0)
        assert(filter_of(m, index - 1) == want, string.format('%s: body %d filter %x, want %x', label, index - 1,
            filter_of(m, index - 1), want))
    end
end
local ARM_FAMILY_BODIES = {}
for i = 0, 15 do ARM_FAMILY_BODIES[#ARM_FAMILY_BODIES + 1] = i end -- hull 13 x 20 + 3 x 54
for i = 18, 22 do ARM_FAMILY_BODIES[#ARM_FAMILY_BODIES + 1] = i end -- arm 3, cannon 2
local SENTRY_BODIES = {31, 32, 33}
local FLAME_G = 11 + 2047 * 2097152

-- ---- patch table ---------------------------------------------------------------------------
do
    assert(#Fix.PATCHES == 18, 'spawn (8) + emitters (8) + hide (2) words')
    local ends = {}
    for i, system in ipairs(Fix.SYSTEMS) do
        ends[i] = system[1] + system[2]
        if i > 1 then assert(system[1] == ends[i - 1], 'systems are contiguous') end
    end
    assert(ends[#ends] == Fix.EFFECT_SIZE, 'systems end at the effect size')
    for _, row in ipairs(Fix.PATCHES) do
        assert(row.v ~= row.t and row.o % 4 == 0, 'patched word at ' .. row.o)
        for _, system in ipairs(Fix.SYSTEMS) do
            local rel = row.o - system[1]
            if rel >= 0 and rel < system[2] then
                -- The only header field written is the visualizer count of systems 0 and 3 (1 -> 0).
                local hide = rel == 0xf8 and row.v == 1 and row.t == 0
                    and (system[1] == Fix.SYSTEMS[1][1] or system[1] == Fix.SYSTEMS[4][1])
                assert(hide or not (rel >= 0xe0 and rel < 0x108), 'never a layout field: ' .. row.o)
            end
        end
    end
end

-- ---- effect: lookup, check, apply ----------------------------------------------------------
do
    local m = world()
    assert(Fix.resolve_effect(m.api, EXE) == DATA, 'resolves the shared effect through both hash chains')
    assert(select(2, Fix.resolve_effect(world({effect_missing = true}).api, EXE)):find('not loaded'), 'missing effect')
    local counts = budget.wrap(m.api)
    local f, ok, detail = budget.frame(counts, Fix.apply_effect, m.api, DATA)
    assert(ok and detail == 18 and fixed_effect(m), 'all 18 words fixed')
    pin(f, {u32 = 90, writable_data = 1, write_raw = 18}, 'first apply')
    local changed = 0
    local after = m.api.read(DATA, Fix.EFFECT_SIZE)
    for i = 1, #after do if after:byte(i) ~= SHIPPED:byte(i) then changed = changed + 1 end end
    assert(changed <= 72, 'only the 18 patched words differ from the shipped file')
    f, ok, detail = budget.frame(counts, Fix.apply_effect, m.api, DATA)
    assert(ok and detail == 0, 'second apply writes nothing')
    pin(f, {u32 = 54}, 'apply on a fixed effect: word checks only')
    local unknown = world(); unknown.poke(DATA + Fix.PATCHES[3].o, '\1\2\3\4')
    assert(select(2, Fix.apply_effect(unknown.api, DATA)):find('unknown value'), 'unknown value refused')
    local header = world({effect = 'X' .. SHIPPED:sub(2)})
    assert(select(2, Fix.apply_effect(header.api, DATA)):find('header'), 'changed header refused')
    local locked = world(); locked.writable = false
    assert(select(2, Fix.apply_effect(locked.api, DATA)):find('not writable') and not fixed_effect(locked), 'write guard')
end

-- ---- collision filter check ------------------------------------------------------------------
do
    local m = world(); physics(m)
    assert(Fix.check_filter(m.api, EXE) == FILTER_OBJ, 'group filter with the recorded flame row')
    local w = world(); physics(w, {vtable = EXE + 0x1000})
    assert(select(2, Fix.check_filter(w.api, EXE)):find('type changed'), 'wrong filter type refused')
    w = world(); physics(w, {flame_row = {0, 2, 20}})
    assert(select(2, Fix.check_filter(w.api, EXE)):find('row changed'), 'changed flame row refused')
    assert(select(2, Fix.check_filter(world().api, EXE)):find('unavailable'), 'no physics')
end

-- ---- family: parent, children, pilot excluded ------------------------------------------------
do
    local m = world(); physics(m)
    local out, stack = {set = {}}, {}
    local n = Fix.family(m.api, EXE, H.arm, out, stack)
    assert(n == 3 and out.set[H.hull] and out.set[H.arm] and out.set[H.cannon], 'hull, arm and cannon: ' .. tostring(n))
    assert(not out.set[H.pilot] and not out.set[H.rifle] and not out.set[H.charger], 'pilot subtree and others excluded')
    assert(Fix.family(m.api, EXE, H.cannon, out, stack) == 3, 'same family from the cannon')
    n = Fix.family(m.api, EXE, H.sentry, out, stack)
    assert(n == 1 and out.set[H.sentry] and not out.set[H.hull] and #out == 1, 'a unit without parent is its own family')
    assert(select(2, Fix.family(m.api, EXE, H.arm + 0x400000, out, stack)):find('not found'), 'stale handle refused')
    assert(select(2, Fix.family(world().api, EXE, H.arm, out, stack)):find('unavailable'), 'no unit registry')
    -- A parent with more than 16 descendants is refused.
    local big = world(); physics(big)
    for k = 0, 17 do
        local child = unit_address(H.sentry + 0x100 + k)
        big.put(child, string.rep('\0', 0x400))
        big.poke(child + 8, le32(H.sentry + 0x100 + k))
        big.poke(child + 0x1E0, le64(k < 17 and unit_address(H.sentry + 0x101 + k) or 0))
    end
    big.poke(unit_address(H.sentry) + 0x1D8, le64(unit_address(H.sentry + 0x100)))
    assert(select(2, Fix.family(big.api, EXE, H.sentry, out, stack)):find('too large'), 'family bound')
end

-- ---- body scan -------------------------------------------------------------------------------
local function new_job()
    return {bases = {}, limits = {}, base = {}, index = {}, layer = {}, actor = {}, unit = {}, marked = {},
            span_k = {}, span_base = {}, spans = 0, worlds = 0, w = 1, i = 0, n = 0, done = false}
end
local function scanned(m, handle, g)
    local out, stack, job = {set = {}}, {}, new_job()
    Fix.family(m.api, EXE, handle, out, stack)
    Fix.scan_begin(m.api, EXE, job)
    Fix.scan_step(m.api, job, out.set, 16, g)
    return job, out
end
do
    local m = world(); physics(m)
    local out, stack, job = {set = {}}, {}, new_job()
    Fix.family(m.api, EXE, H.arm, out, stack)
    local counts = budget.wrap(m.api)
    local f, ok = budget.frame(counts, Fix.scan_begin, m.api, EXE, job)
    assert(ok and job.worlds == 1 and job.bases[1] == BODIES and job.limits[1] == 48, 'one world, 48 bodies')
    pin(f, {u32 = 14}, 'scan begin (4 world slots)')
    local done
    f, done = budget.frame(counts, Fix.scan_step, m.api, job, out.set, 4)
    assert(done == true and job.n == OWN_ARM, 'the arm family keeps 21 bodies: ' .. job.n)
    pin(f, {load = 1}, 'scan step: one block')
    local kept = {}
    for k = 1, job.n do kept[#kept + 1] = job.index[k] end
    assert(table.concat(kept, ',') == table.concat(ARM_FAMILY_BODIES, ','), 'kept bodies ' .. table.concat(kept, ','))
    assert(job.spans == 1, 'bodies close together share one read: ' .. job.spans)
    -- A large body array is read in blocks of 409 bodies, 4 blocks per call.
    local big = world(); physics(big, {limit = 2000})
    local job2 = new_job()
    Fix.scan_begin(big.api, EXE, job2)
    counts = budget.wrap(big.api)
    f, done = budget.frame(counts, Fix.scan_step, big.api, job2, out.set, 4)
    assert(done == false and job2.i == 4 * 409, 'first call reads 4 blocks')
    pin(f, {load = 4}, 'scan step: four blocks')
    f, done = budget.frame(counts, Fix.scan_step, big.api, job2, out.set, 4)
    assert(done == true and job2.n == OWN_ARM, 'second call finishes')
    pin(f, {load = 1}, 'scan step: last block')
    local none = world(); physics(none, {world_vtable = EXE + 0x2000})
    assert(select(2, Fix.scan_begin(none.api, EXE, new_job())):find('no physics world'), 'unknown world refused')
end

-- Bodies far apart are read in separate spans (hull at 0-15, arm at 200-202, cannon at 700-701).
local function spread_bodies()
    local b, base = {}, body_table()
    for i = 1, 16 do b[i] = base[i] end
    for i = 0, 2 do b[201 + i] = base[19 + i] end
    for i = 0, 1 do b[701 + i] = base[22 + i] end
    return b
end
do
    local m = world(); physics(m, {bodies = spread_bodies(), limit = 800})
    local job = scanned(m, H.arm)
    assert(job.n == OWN_ARM and job.spans == 3, 'three spans: ' .. job.spans)
    local counts = budget.wrap(m.api)
    local f, marked = budget.frame(counts, Fix.mark, m.api, job, 2047, {})
    assert(marked == OWN_ARM, 'all grouped across spans')
    pin(f, {load = 3, writable_region = 1, write_u32 = OWN_ARM}, 'mark: one read per span')
    for _, index in ipairs({0, 15, 200, 202, 700, 701}) do assert(group_of(m, index) == 2047, 'spread body ' .. index) end
end

-- ---- group allocator ---------------------------------------------------------------------------
do
    local m = world(); physics(m)
    assert(Fix.group_free(m.api, EXE, 2047) and Fix.group_free(m.api, EXE, 2040), 'top groups free')
    assert(not Fix.group_free(m.api, EXE, 2) and not Fix.group_free(m.api, EXE, 0), 'game groups in use')
    local w = world(); physics(w, {used = {2047}})
    assert(not Fix.group_free(w.api, EXE, 2047) and Fix.group_free(w.api, EXE, 2046), 'allocated top group seen')
    local counts = budget.wrap(m.api)
    local f = budget.frame(counts, Fix.group_free, m.api, EXE, 2047)
    pin(f, {u32 = 7}, 'group check')
end

-- ---- verify / mark / unmark: only group bits of owned, group-free bodies ------------------------
do
    local m = world(); physics(m)
    local job = scanned(m, H.arm)
    local counts = budget.wrap(m.api)
    local region = {}
    local f, c = budget.frame(counts, Fix.verify, m.api, job, nil)
    assert(c.free == OWN_ARM and c.own == 0 and c.moved == 0 and c.stale == 0, 'all group-free before grouping')
    pin(f, {load = 1}, 'verify: one read per span')
    local marked
    f, marked = budget.frame(counts, Fix.mark, m.api, job, 2047, region)
    assert(marked == OWN_ARM, 'all 21 own bodies grouped: ' .. tostring(marked))
    pin(f, {load = 1, writable_region = 1, write_u32 = OWN_ARM}, 'mark')
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'marked')
    c = Fix.verify(m.api, job, 2047)
    assert(c.own == OWN_ARM and c.free == 0, 'all own once grouped')
    f, marked = budget.frame(counts, Fix.mark, m.api, job, 2047, region)
    assert(marked == OWN_ARM and not f.write_u32 and not f.writable_region, 'already grouped: reads only')
    local cleared
    f, cleared = budget.frame(counts, Fix.unmark, m.api, job, 2047, region)
    assert(cleared == OWN_ARM, 'unmark clears all: ' .. tostring(cleared))
    pin(f, {load = 1, writable_region = 1, write_u32 = OWN_ARM}, 'unmark')
    bodies_are(m, {}, 2047, 'restored')
    -- Classes: a slot recycled by another unit and a body the game gave another group are stale and never
    -- touched; a rebuilt body (new actor) is stale for grouping but still ours to clear; a grouped body the game
    -- switched to another layer (destruction) is 'moved' and is cleared with its new layer kept.
    Fix.mark(m.api, job, 2047, region)
    m.api.write_u32(BODIES + 160 * 3 + 148, H.charger)
    m.api.write_u32(BODIES + 160 * 4 + 108, 20 + 5 * 2097152)
    m.api.write_u32(BODIES + 160 * 5 + 144, 0xc0000123)
    m.api.write_u32(BODIES + 160 * 6 + 108, 48 + 2047 * 2097152)
    c = Fix.verify(m.api, job, 2047)
    assert(c.stale == 3 and c.moved == 1 and c.own == OWN_ARM - 4, string.format('stale %d moved %d own %d', c.stale, c.moved, c.own))
    cleared = Fix.unmark(m.api, job, 2047, region)
    assert(cleared == OWN_ARM - 2, 'recycled and regrouped bodies skipped: ' .. tostring(cleared))
    assert(group_of(m, 3) == 2047 and group_of(m, 4) == 5 and group_of(m, 5) == 0 and filter_of(m, 6) == 48,
        'only own-unit bodies cleared, new layer kept')
    -- Write guard: nothing written when the body memory is not private read-write.
    local locked = world(); physics(locked)
    local job2 = scanned(locked, H.arm)
    locked.writable = false
    assert(select(2, Fix.mark(locked.api, job2, 2047, {})):find('not writable'), 'body write guard')
    bodies_are(locked, {}, 2047, 'locked')
end

-- A scan that meets bodies already carrying the weapon's group keeps them as grouped.
do
    local m = world(); physics(m)
    m.api.write_u32(BODIES + 160 * 2 + 108, 20 + 2047 * 2097152)
    m.api.write_u32(BODIES + 160 * 19 + 108, 20 + 2046 * 2097152) -- another group: not ours
    local job = scanned(m, H.arm, 2047)
    assert(job.n == OWN_ARM - 1, 'own-group body kept, foreign-group body skipped: ' .. job.n)
    local marked = 0
    for k = 1, job.n do if job.marked[k] then marked = marked + 1 end end
    assert(marked == 1, 'the own-group body is kept as grouped')
    assert(Fix.unmark(m.api, job, 2047, {}) == 1 and group_of(m, 2) == 0 and group_of(m, 19) == 2046, 'released')
end

-- ---- flame instances: lookup by id and grouping ----------------------------------------------------
do
    local m = world(); physics(m, {instances = 2})
    local slot = Fix.flame_slot(m.api, GAME)
    assert(slot == PM_LISTS + 24 * 5, 'flame slot entry')
    assert(Fix.find_instance(m.api, slot, ID2) == INST_RECORDS + 136 and Fix.find_instance(m.api, slot, 0x999) == nil, 'by id')
    local counts = budget.wrap(m.api)
    local region = {}
    local f, moved = budget.frame(counts, Fix.retarget_instance, m.api, EXE, SIM1, DATA, region, FLAME_G)
    assert(moved == 5, 'five flame particle systems grouped: ' .. tostring(moved))
    pin(f, {u32 = 47, writable_region = 1, write_u32 = 5}, 'retarget one instance (particle-system array read once)')
    for index = 1, 5 do assert(layer_of(m, index) == FLAME_G, 'system ' .. index .. ' in the group, layer 11') end
    assert(layer_of(m, 6) == 0x4a and layer_of(m, 7) == 11, 'other filters and instances untouched')
    f, moved = budget.frame(counts, Fix.retarget_instance, m.api, EXE, SIM1, DATA, {}, FLAME_G)
    assert(moved == 0 and not f.write_u32 and not f.writable_region, 'already grouped: reads only')
    local foreign = world(); physics(foreign, {foreign = true})
    assert(Fix.retarget_instance(foreign.api, EXE, SIM1, DATA, {}, FLAME_G) == 0 and layer_of(foreign, 1) == 11, 'another effect untouched')
    local stale = world(); physics(stale, {stale = 3})
    assert(Fix.retarget_instance(stale.api, EXE, SIM1, DATA, {}, FLAME_G) == 4, 'generation mismatch skipped')
    local locked = world(); physics(locked); locked.writable = false
    local none, why = Fix.retarget_instance(locked.api, EXE, SIM1, DATA, {}, FLAME_G)
    assert(none == nil and why:find('not writable') and layer_of(locked, 1) == 11, 'particle write guard')
    assert(Fix.flame_slot(world().api, GAME) == nil, 'no physics: no slot')
end

-- ---- per-frame driver ----------------------------------------------------------------------
local dt = 1 / 60
local function step(fix, n) for _ = 1, n or 1 do fix.step(dt) end end
-- Steps until the next weapon scan has run (every SCAN_SECONDS) and returns that frame's calls.
local function next_scan_frame(fix, counts)
    for _ = 1, 40 do
        local before = fix.since_scan
        local f = budget.frame(counts, fix.step, dt)
        if fix.since_scan < before then return f end
    end
    error('no scan frame')
end
do
    local m = world(); physics(m)
    local lines = {}
    local counts = budget.wrap(m.api)
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    local f = budget.frame(counts, fix.step, dt)
    -- Weapon scan, then the first weapon's family lookup (the Flame Sentry: itself, no parent) in the same frame.
    pin(f, {u32 = 49}, 'scan frame + Flame Sentry family lookup')
    assert(#fix.tracked == 2 and fix.tracked[1] == SENTRY_STATE and fix.tracked[2] == ARM_STATE,
        'Flame Sentry and Lumberer arm tracked, the Cremator ignored')
    -- The next frames scan one family's bodies at a time, then look up the next family.
    f = budget.frame(counts, fix.step, dt)
    pin(f, {u32 = 2, load = 1}, 'body scan frame (Flame Sentry)')
    f = budget.frame(counts, fix.step, dt)
    pin(f, {u32 = 45}, 'family lookup frame (Lumberer: hull, arm, cannon; pilot skipped)')
    f = budget.frame(counts, fix.step, dt)
    pin(f, {u32 = 2, load = 1}, 'body scan frame (Lumberer)')
    local sentry, arm = fix.weapons[SENTRY_STATE], fix.weapons[ARM_STATE]
    assert(sentry.job_ok and sentry.job.n == OWN_SENTRY and arm.job_ok and arm.job.n == OWN_ARM, 'both families scanned')
    for _ = 1, 10 do
        f = budget.frame(counts, fix.step, dt)
        pin(f, {u32 = 2}, 'present frame: one state read per tracked weapon')
    end
    bodies_are(m, {}, 2047, 'nothing grouped before firing')
    -- First burst: effect fixed, the arm's own bodies grouped, its burst instance's flame systems grouped.
    m.poke(ARM_STATE, le32(1)); m.poke(ARM_INSTANCE_ID, le32(ID1))
    f = budget.frame(counts, fix.step, dt)
    -- Effect words (once per mission), filter check (once per session), group check, the own bodies (one read to
    -- confirm, one to group), the flame slot and the burst instance's 5 flame systems.
    pin(f, {u32 = 202, writable_data = 1, write_raw = 18, load = 2, writable_region = 2, write_u32 = OWN_ARM + 5},
        'first burst start')
    assert(fixed_effect(m), 'effect fixed')
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'first burst')
    for index = 1, 5 do assert(layer_of(m, index) == FLAME_G, 'burst instance system ' .. index .. ' grouped') end
    assert(lines[1]:find('Flame effect fixed %(18 words%)') and lines[2]:find('Self%-hit fix active for the Lumberer')
        and lines[2]:find('21/21 own bodies in group 2047'), table.concat(lines, ' | '))
    -- Firing: states + the arm's instance id, no writes.
    m.poke(ARM_STATE, le32(2))
    for _ = 1, 5 do
        f = budget.frame(counts, fix.step, dt)
        pin(f, {u32 = 3}, 'firing frame')
    end
    -- Firing stops: the bodies stay grouped and frames go straight back to the state reads.
    m.poke(ARM_STATE, le32(3))
    for _ = 1, 5 do
        f = budget.frame(counts, fix.step, dt)
        pin(f, {u32 = 2}, 'frame after a burst')
    end
    m.poke(PM_LISTS + 24 * 5, le32(0)) -- the burst's flame instance died
    step(fix, 5)
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'still grouped between bursts')
    -- The weapon scan confirms the group: one read per span, and the allocator (7 reads; was 22 reads: the group is
    -- checked at every use, since nothing reserves it).
    f = next_scan_frame(fix, counts)
    pin(f, {u32 = 29, load = 1}, 'scan frame with the group check')
    -- Second burst: the bodies are confirmed with one read and the group in the allocator (7 reads; was 99 reads in
    -- all: the group is checked at every use); only the new instance is written.
    local before = #lines
    m.poke(PM_LISTS + 24 * 5, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID2)); m.poke(ARM_STATE, le32(2))
    f = budget.frame(counts, fix.step, dt)
    pin(f, {u32 = 106, load = 1, writable_region = 1, write_u32 = 5}, 'second burst start')
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'second burst')
    for index = 7, 11 do assert(layer_of(m, index) == FLAME_G, 'second instance system ' .. index .. ' grouped') end
    assert(layer_of(m, 12) == 0x4a and #lines == before, 'other filter untouched, nothing logged')
    -- The Flame Sentry fires as well: its own bodies get the next free group.
    m.poke(SENTRY_STATE, le32(2)); m.poke(SENTRY_INSTANCE_ID, le32(ID1))
    step(fix)
    for _, index in ipairs(ARM_FAMILY_BODIES) do assert(group_of(m, index) == 2047, 'arm body ' .. index .. ' kept') end
    for _, index in ipairs(SENTRY_BODIES) do assert(group_of(m, index) == 2046, 'sentry body ' .. index .. ' in 2046') end
    assert(fix.weapons[SENTRY_STATE].group == 2046, 'distinct groups per weapon')
    for _, index in ipairs({16, 17, 23, 24, 25, 26, 27, 28, 29, 30, 34, 35}) do
        assert(filter_of(m, index) == body_table()[index + 1].filter, 'not an own group-free hittable body: ' .. index)
    end
    -- Weapons gone: their bodies leave the groups and frames go back to one scan per SCAN_SECONDS.
    m.poke(SENTRY_STATE, le32(0)); m.poke(ARM_STATE, le32(0))
    m.poke(SPRAY_MGR + 0x38, le32(0))
    f = next_scan_frame(fix, counts)
    pin(f, {u32 = 3, load = 2, writable_region = 2, write_u32 = OWN_ARM + OWN_SENTRY}, 'weapons gone: groups released')
    assert(#fix.tracked == 0 and next(fix.weapons) == nil, 'weapons dropped after the rescan')
    for index = 0, 47 do assert(group_of(m, index) == (index == 16 and 44 or 0), 'body ' .. index .. ' released') end
    local calls, scans = 0, 0
    for _ = 1, 30 do
        f = budget.frame(counts, fix.step, dt)
        assert(not f.writable_data and not f.writable_region and not f.write_raw and not f.write_u32 and not f.load,
            'idle frame: ' .. budget.describe(f))
        if (f.u32 or 0) > 0 then
            scans = scans + 1
            assert(f.u32 <= 3, 'idle scan reads the manager pointer and count only: ' .. budget.describe(f))
        end
        calls = calls + (f.u32 or 0)
    end
    assert(scans <= 1 and calls <= 3, 'idle: at most one manager check per scan period: ' .. calls)
end

-- Lifecycle: a hit-box the game rebuilds starts a new scan (grouped bodies stay grouped); one found group-free
-- again is grouped at the next burst; a grouped body switched to another layer means the vehicle was destroyed,
-- so its bodies leave the group and are not grouped again.
do
    local m = world(); physics(m)
    local lines = {}
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    step(fix, 6)
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    m.poke(ARM_STATE, le32(0)); step(fix, 2)
    local arm = fix.weapons[ARM_STATE]
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'grouped')
    m.api.write_u32(BODIES + 160 * 7 + 144, 0xc0000777) -- body 7 rebuilt: new actor, group kept
    step(fix, 40) -- a scan frame sees it stale and starts a new body scan, which completes
    assert(arm.job_ok and arm.marked and arm.job.n == OWN_ARM, 'rescan while grouped keeps all 21: ' .. arm.job.n)
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'nothing released by the rescan')
    m.api.write_u32(BODIES + 160 * 8 + 108, 20) -- the game reset body 8's filter: group-free again
    local counts = budget.wrap(m.api)
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID2))
    local f = budget.frame(counts, fix.step, dt)
    assert(f.write_u32 and f.write_u32 >= 1 and group_of(m, 8) == 2047, 'group-free body grouped again: ' .. budget.describe(f))
    m.poke(ARM_STATE, le32(0)); step(fix, 2)
    m.api.write_u32(BODIES + 160 * 9 + 108, 48 + 2047 * 2097152) -- destroyed: the game moves it to layer 48
    step(fix, 40)
    assert(arm.destroyed and not arm.marked, 'destroyed vehicle released')
    for _, index in ipairs(ARM_FAMILY_BODIES) do
        assert(group_of(m, index) == 0, 'destroyed vehicle body ' .. index .. ' left the group')
    end
    assert(filter_of(m, 9) == 48, 'the new layer is kept')
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    for _, index in ipairs(ARM_FAMILY_BODIES) do assert(group_of(m, index) == 0, 'not grouped again: ' .. index) end
end

-- A rescan never loses track of the grouped bodies: until it is complete the last complete scan stays in use, so a
-- weapon released mid-rescan (it left, below 40 FPS when the 0.5 s weapon scan lands inside the rescan, or after a
-- rescan started by a burst) leaves no body in its group. v1.1 cleared the kept bodies when a rescan began and
-- left all 21 grouped.
do
    local m = world(); physics(m, {limit = 4000}) -- 10 blocks: a body scan takes 3 frames
    local fix = Fix.new(m.api, GAME, EXE, function() end)
    step(fix, 20)
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    m.poke(ARM_STATE, le32(0)); step(fix, 2)
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'grouped before the rescan')
    local arm = fix.weapons[ARM_STATE]
    m.api.write_u32(BODIES + 160 * 7 + 144, 0xc0000777) -- body 7 rebuilt: the next weapon scan starts a rescan
    for _ = 1, 40 do
        fix.step(dt)
        if fix.scanning == arm then break end
    end
    assert(fix.scanning == arm and arm.job_ok and arm.job.n == OWN_ARM, 'mid-rescan, the last complete scan stays in use')
    m.poke(SPRAY_MGR + 0x38, le32(0)) -- the weapon leaves before the rescan is done
    fix.scan()
    assert(fix.scanning == nil and next(fix.weapons) == nil, 'weapon dropped, rescan abandoned')
    bodies_are(m, {}, 2047, 'released mid-rescan')
end

-- ---- a private group stays this mod's alone (nothing reserves it) -------------------------------------------
-- Clears group g's free bit in the allocator, as if the game had handed it out.
local function allocate(m, g)
    local address = BITMAP + 8 + 4 * math.floor(g / 32)
    local word = m.word(address)
    local bitv = 2 ^ (g % 32)
    if math.floor(word / bitv) % 2 == 1 then m.api.write_u32(address, word - bitv) end
end
local function arm_grouped(options)
    local m = world(); physics(m, options)
    local lines = {}
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    step(fix, 6)
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    return m, fix, lines
end
do
    -- The allocator hands out the weapon's group between bursts: the next weapon scan sees it (the group is checked
    -- at every use), the bodies and the live flame systems leave it at once, and the next burst moves to 2046.
    local m, fix, lines = arm_grouped()
    local arm = fix.weapons[ARM_STATE]
    m.poke(ARM_STATE, le32(3)); step(fix, 2)
    assert(arm.group == 2047 and group_of(m, 0) == 2047 and layer_of(m, 1) == FLAME_G, 'grouped in 2047')
    allocate(m, 2047)
    local counts = budget.wrap(m.api)
    local f = next_scan_frame(fix, counts)
    -- Once: the span read and the allocator (as every 0.5 s), then the 21 bodies (a release) and the flame slot with
    -- its live instance's 5 systems.
    pin(f, {u32 = 96, load = 2, writable_region = 2, write_u32 = OWN_ARM + 5}, 'weapon scan: group handed out')
    bodies_are(m, {}, 2047, 'left the handed-out group')
    for index = 1, 5 do assert(layer_of(m, index) == 11, 'flame system ' .. index .. ' back to layer 11') end
    assert(arm.group == nil and not arm.marked, 'the weapon holds no group')
    assert(table.concat(lines, ' | '):find("group 2047 is no longer this mod's alone %(the game's group allocator handed it out%)"),
        table.concat(lines, ' | '))
    m.poke(ARM_STATE, le32(1)); m.poke(ARM_INSTANCE_ID, le32(ID2)); m.poke(PM_LISTS + 24 * 5, le32(2)); step(fix)
    bodies_are(m, ARM_FAMILY_BODIES, 2046, 'next burst: group 2046')
    for index = 7, 11 do assert(layer_of(m, index) == 11 + 2046 * 2097152, 'burst instance in 2046') end
    assert(arm.group == 2046, 'the weapon holds 2046')
end
do
    -- Handed out while the weapon rests, found at the burst start itself: it moves to 2046 within that frame, and the
    -- burst's flame systems join 2046.
    local m, fix = arm_grouped({instances = 2})
    m.poke(ARM_STATE, le32(0)); step(fix, 2)
    allocate(m, 2047)
    local counts = budget.wrap(m.api)
    m.poke(ARM_STATE, le32(1)); m.poke(ARM_INSTANCE_ID, le32(ID2))
    local f = budget.frame(counts, fix.step, dt)
    -- Once: the burst start (106 reads), the 2047 check that fails, the release (21 writes), the flame slot and both
    -- live instances, 2046's check, the regrouping (21 writes) and the new instance's 5 systems.
    pin(f, {u32 = 236, load = 3, writable_region = 4, write_u32 = 2 * OWN_ARM + 10}, 'burst start: group handed out')
    bodies_are(m, ARM_FAMILY_BODIES, 2046, 'moved to 2046 at the burst start')
    for index = 1, 5 do assert(layer_of(m, index) == 11, 'the old instance left 2047') end
    for index = 7, 11 do assert(layer_of(m, index) == 11 + 2046 * 2097152, 'the new instance is in 2046') end
end
do
    -- Another mod's body (here a Charger hit-box) already carries 2047 when the arm's bodies are scanned: the first
    -- burst skips 2047 (logged once) and the other body is never touched.
    local m = world(); physics(m)
    m.api.write_u32(BODIES + 160 * 27 + 108, 20 + 2047 * 2097152)
    local lines = {}
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    step(fix, 6)
    assert(fix.weapons[ARM_STATE].job.foreign[2047] and not fix.weapons[ARM_STATE].job.foreign[2046], 'census')
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    for _, index in ipairs(ARM_FAMILY_BODIES) do assert(group_of(m, index) == 2046, 'arm body ' .. index .. ' in 2046') end
    assert(group_of(m, 27) == 2047 and layer_of(m, 1) == 11 + 2046 * 2097152, 'other body untouched, flame in 2046')
    assert(table.concat(lines, ' | '):find('group 2047 not used: other bodies carry it'), table.concat(lines, ' | '))
    m.poke(ARM_STATE, le32(0)); m.poke(SPRAY_MGR + 0x38, le32(0))
    next_scan_frame(fix, budget.wrap(m.api))
    assert(group_of(m, 27) == 2047 and group_of(m, 0) == 0, 'release leaves the other body alone')
end
do
    -- This mod's other weapon's bodies are not "other bodies": the Flame Sentry grouped in 2047 before the arm's scan.
    local m = world(); physics(m)
    local fix = Fix.new(m.api, GAME, EXE, function() end)
    step(fix, 2) -- the Sentry is scanned; the arm's family is looked up next
    m.poke(SENTRY_STATE, le32(2)); m.poke(SENTRY_INSTANCE_ID, le32(ID1)); step(fix)
    for _, index in ipairs(SENTRY_BODIES) do assert(group_of(m, index) == 2047, 'sentry body ' .. index .. ' in 2047') end
    step(fix, 4)
    local arm = fix.weapons[ARM_STATE]
    assert(arm.job_ok and not arm.job.foreign[2047], 'the Sentry\'s bodies are this mod\'s own')
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID2)); m.poke(PM_LISTS + 24 * 5, le32(2)); step(fix)
    for _, index in ipairs(ARM_FAMILY_BODIES) do assert(group_of(m, index) == 2046, 'arm body ' .. index .. ' in 2046') end
    for _, index in ipairs(SENTRY_BODIES) do assert(group_of(m, index) == 2047, 'sentry body ' .. index .. ' kept') end
end
do
    -- Other bodies start carrying the weapon's group after it was grouped: the next rescan (here after a rebuilt
    -- hit-box) finds them and the weapon leaves the group at once; the next burst moves to 2046.
    local m, fix, lines = arm_grouped()
    local arm = fix.weapons[ARM_STATE]
    m.poke(ARM_STATE, le32(0)); step(fix, 2)
    m.api.write_u32(BODIES + 160 * 28 + 108, 20 + 2047 * 2097152) -- another mod's body joins 2047
    m.api.write_u32(BODIES + 160 * 7 + 144, 0xc0000777)          -- a rebuilt hit-box: rescan
    step(fix, 40)
    assert(arm.group == nil and not arm.marked and group_of(m, 28) == 2047, 'left 2047, the other body untouched')
    for _, index in ipairs(ARM_FAMILY_BODIES) do assert(group_of(m, index) == 0, 'body ' .. index .. ' left 2047') end
    assert(table.concat(lines, ' | '):find("group 2047 is no longer this mod's alone %(other bodies carry it%)"),
        table.concat(lines, ' | '))
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID2)); m.poke(PM_LISTS + 24 * 5, le32(2)); step(fix)
    for _, index in ipairs(ARM_FAMILY_BODIES) do assert(group_of(m, index) == 2046, 'regrouped in 2046: ' .. index) end
    assert(group_of(m, 28) == 2047, 'the other body keeps its group')
end
do
    -- No usable group left: the weapon keeps the game's own collision (logged once); nothing is written.
    local m, fix, lines = arm_grouped()
    m.poke(ARM_STATE, le32(0)); step(fix, 2)
    for g = 2040, 2047 do allocate(m, g) end
    step(fix, 40)
    bodies_are(m, {}, 2047, 'left 2047')
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID2)); m.poke(PM_LISTS + 24 * 5, le32(2)); step(fix)
    bodies_are(m, {}, 2047, 'no group')
    for index = 7, 11 do assert(layer_of(m, index) == 11, 'the flame keeps layer 11 without a group') end
    assert(table.concat(lines, ' | '):find('no free Havok system group'), table.concat(lines, ' | '))
end

-- Refusals: no free group, or an unknown filter, fall back to vanilla collision; the effect still fixes.
do
    local m = world(); physics(m, {used = {2040, 2041, 2042, 2043, 2044, 2045, 2046, 2047}})
    local lines = {}
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    step(fix, 6)
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    assert(fixed_effect(m) and layer_of(m, 1) == 11, 'effect fixed, flame keeps vanilla collision')
    bodies_are(m, {}, 2047, 'no group written')
    assert(table.concat(lines, ' | '):find('no free Havok system group'), table.concat(lines, ' | '))
    local w = world(); physics(w, {flame_row = {0, 2, 20}})
    local wl = {}
    local fx = Fix.new(w.api, GAME, EXE, function(line) wl[#wl + 1] = line end)
    step(fx, 6)
    w.poke(ARM_STATE, le32(2)); w.poke(ARM_INSTANCE_ID, le32(ID1)); step(fx)
    assert(fixed_effect(w) and fx.self_hit_off and layer_of(w, 1) == 11, 'row changed: self-hit fix off')
    local disabled = 0
    for _, line in ipairs(wl) do if line:find('Self%-hit fix disabled') then disabled = disabled + 1 end end
    assert(disabled == 1, 'refusal logged once')
end

-- A new mission reloads the effect: the next burst fixes it again.
do
    local m = world(); physics(m)
    local lines = {}
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    step(fix, 6); m.poke(ARM_STATE, le32(2)); step(fix); m.poke(ARM_STATE, le32(0))
    assert(fixed_effect(m), 'first mission fixed')
    for _, row in ipairs(Fix.PATCHES) do m.poke(DATA + row.o, le32(row.v)) end -- reloaded from disk
    step(fix, 100)
    m.poke(ARM_STATE, le32(2)); step(fix)
    assert(fixed_effect(m), 'reloaded effect fixed again')
    local fixes = 0
    for _, line in ipairs(lines) do if line:find('Flame effect fixed') then fixes = fixes + 1 end end
    assert(fixes == 2, 'each fix is logged once: ' .. fixes)
end

-- Frames that only read make no garbage, even interpreted (in game, cold paths such as the weapon scan run in
-- the interpreter), and neither do a later burst or the release: their writes rewrite words written before.
do
    local m = world(); physics(m)
    local fix = Fix.new(m.api, GAME, EXE, function() end)
    step(fix, 6)
    m.poke(ARM_STATE, le32(2)); m.poke(ARM_INSTANCE_ID, le32(ID1)); step(fix)
    m.poke(ARM_STATE, le32(3)); step(fix, 120) -- grouped, watch window closed, several scans with group checks
    local function garbage(frames)
        collectgarbage('collect'); collectgarbage('stop')
        local before = collectgarbage('count')
        for _ = 1, frames do fix.step(dt) end
        local bytes = (collectgarbage('count') - before) * 1024
        collectgarbage('restart')
        return bytes
    end
    for index = 1, 5 do m.api.write_u32(ps_address(index) + 5764, 11) end -- a fresh instance, same words
    m.api.write_u32(ARM_INSTANCE_ID, ID1 + 1); m.api.write_u32(INST_RECORDS + 16, ID1 + 1)
    jit.off(); jit.flush()
    local present = garbage(90) -- 1.5 s: present frames and three weapon scans with group checks
    m.api.write_u32(ARM_STATE, 2)
    local burst = garbage(1) -- second burst start: effect check, group confirmed, new instance grouped
    local firing = garbage(60)
    m.api.write_u32(ARM_STATE, 0)
    local after = garbage(60)
    m.api.write_u32(SPRAY_MGR + 0x38, 0)
    local release = garbage(40) -- the scan drops the weapon and releases its group
    local idle = garbage(90)
    jit.on()
    assert(present == 0 and burst == 0 and firing == 0 and after == 0 and release == 0 and idle == 0, string.format(
        'garbage: present %d B, burst start %d B, firing %d B, after %d B, release %d B, idle %d B',
        present, burst, firing, after, release, idle))
end

-- ---- update chain: P1 (errors below pass through), pause with restore, P3 bursts, P2 shutdown ----------------
local H = dofile(root .. '/tests/hostile_vm.lua')
-- A grouped Lumberer (bodies in 2047, the burst's flame systems in 2047) under a guard in env, with the game's
-- update below it behind a neighbour that raises when `raising` is set and a step that raises when `failing` is.
local function guarded(options)
    options = options or {}
    local m = world(); physics(m, {instances = 2})
    local lines = {}
    local function log(line) lines[#lines + 1] = line end
    local fix = Fix.new(m.api, GAME, EXE, log)
    local env, ctl = {}, {raising = false, failing = false, game = 0, shutdowns = 0}
    env.update = function(dt, extra) ctl.game = ctl.game + 1; return 'game', dt, extra end
    env.shutdown = function(...) ctl.shutdowns = ctl.shutdowns + 1; return 'shut', ... end
    ctl.below = H.chain(env, 'throw_below', {raise_on = function() return ctl.raising end})
    local function step_or_fail(dt) if ctl.failing then error('step failed on purpose') end return fix.step(dt) end
    -- The same guard the mod installs, in the test's env (so its BingusRuntime is isolated per scenario).
    local guard = runtime.guard({name = 'FlameDamageFixed', env = env, step = step_or_fail,
        stop = Fix.restore_on(fix), pause = Fix.restore_on(fix), log = log}).install()
    for _ = 1, 6 do env.update(dt) end
    m.poke(ARM_STATE, le32(1)); m.poke(ARM_INSTANCE_ID, le32(ID1)); env.update(dt)
    m.poke(ARM_STATE, le32(3)); env.update(dt)
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'grouped under the guard')
    for index = 1, 5 do assert(layer_of(m, index) == FLAME_G, 'flame system ' .. index .. ' grouped') end
    return m, fix, env, ctl, guard, lines
end
local function count_lines(lines, pattern)
    local n = 0
    for _, line in ipairs(lines) do if line:find(pattern) then n = n + 1 end end
    return n
end
do
    -- P1: arguments and returns pass through; an error below reaches the caller unchanged (the same table).
    local m, fix, env, ctl, guard, lines = guarded()
    local a, b, c = env.update(dt, 'extra')
    assert(a == 'game' and b == dt and c == 'extra', 'arguments and returns pass through')
    ctl.raising = true
    local ok, err = pcall(env.update, dt)
    assert(not ok and err == ctl.below.last_error, 'the error below passes through unchanged: ' .. tostring(err))
    ctl.raising = false
    -- Pause: the next frame restores the group writes (bodies and live flame systems), forgets the weapons and skips
    -- the step; one log line.
    local counts = budget.wrap(m.api)
    local clock = fix.clock
    local f = budget.frame(counts, env.update, dt)
    -- Once per pause: the bodies' span read and 21 writes (as a release), then the flame slot and both live
    -- instances (one read per system) and the 5 systems still in the group.
    pin(f, {u32 = 116, load = 1, writable_region = 2, write_u32 = OWN_ARM + 5}, 'pause frame: group writes restored')
    bodies_are(m, {}, 2047, 'released by the pause')
    for index = 1, 12 do assert(layer_of(m, index) == ((index == 6 or index == 12) and 0x4a or 11), 'flame system ' .. index .. ' restored') end
    assert(next(fix.weapons) == nil and #fix.tracked == 0 and fix.clock == clock, 'started over; the step is skipped')
    assert(count_lines(lines, 'paused:') == 1 and guard.status.pauses == 1, table.concat(lines, ' | '))
    -- More errors below while paused: no new pause or line; each one restarts the 60-frame wait.
    for _ = 1, 3 do
        ctl.raising = true; pcall(env.update, dt); ctl.raising = false
        for _ = 1, 30 do env.update(dt) end
    end
    assert(fix.clock == clock and count_lines(lines, 'paused:') == 1, 'still paused')
    for _ = 1, Fix.RESUME_FRAMES - 30 do env.update(dt) end
    assert(fix.clock == clock, 'the updates below returned on 60 frames in a row: the step stays skipped until then')
    env.update(dt)
    assert(fix.clock > clock and count_lines(lines, 'resumed after') == 1, 'resumed on the next frame')
    for _ = 1, 10 do env.update(dt) end
    m.poke(ARM_STATE, le32(1)); m.poke(ARM_INSTANCE_ID, le32(ID2)); env.update(dt)
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'grouped again after the resume')
    assert(guard.running() and guard.status.lower_errors == 4, 'running, 4 errors below counted')
    -- P2: a clean shutdown forwards every argument and return; the guard's status ends 'stopped'.
    local r1, r2, r3 = env.shutdown('x', 'y')
    assert(r1 == 'shut' and r2 == 'x' and r3 == 'y' and ctl.shutdowns == 1, 'shutdown passes through')
    assert(guard.status.state == 'stopped', guard.status.state)
end
do
    -- P3 below: 8 failed updates below within the clean window stop the mod; the restore runs once.
    local m, fix, env, ctl, guard, lines = guarded()
    for _ = 1, Fix.ERRORS do
        ctl.raising = true; pcall(env.update, dt); ctl.raising = false
        env.update(dt)
    end
    assert(not guard.running() and count_lines(lines, 'stopped after 8 failed updates below') == 1,
        table.concat(lines, ' | '))
    bodies_are(m, {}, 2047, 'released by the stop')
    local game = ctl.game
    for _ = 1, 5 do env.update(dt) end
    assert(ctl.game == game + 5, 'the game update keeps running below a stopped mod')
    ctl.raising = true
    assert(not pcall(env.update, dt), 'errors below still pass through')
    ctl.raising = false
    env.shutdown()
    assert(guard.status.state == 'stopped after: stopped after 8 failed updates below this mod', guard.status.state)
end
do
    -- P3 below, spread out: a count starts again after 3600 clean frames, so rare errors never stop the mod.
    local _, _, env, ctl, guard = guarded()
    for _ = 1, 3 do
        for _ = 1, Fix.ERRORS - 1 do
            ctl.raising = true; pcall(env.update, dt); ctl.raising = false
            for _ = 1, Fix.RESUME_FRAMES do env.update(dt) end
        end
        for _ = 1, Fix.CLEAN_FRAMES do env.update(dt) end
    end
    assert(guard.running() and guard.status.lower_errors == 0 and guard.status.pauses == 21, '21 rare errors below')
end
do
    -- P3 own: one line per burst; a burst ends after 3600 clean frames; 8 in a burst stop the mod.
    local m, _, env, ctl, guard, lines = guarded()
    ctl.failing = true
    for _ = 1, Fix.ERRORS - 1 do env.update(dt) end
    ctl.failing = false
    assert(guard.running() and count_lines(lines, ' error: ') == 1, 'one line for a burst of 7')
    for _ = 1, Fix.CLEAN_FRAMES do env.update(dt) end
    assert(guard.status.errors == 0, 'the burst ended')
    ctl.failing = true
    for _ = 1, Fix.ERRORS - 1 do env.update(dt) end
    assert(guard.running() and count_lines(lines, ' error: ') == 2, 'a new burst gets its line')
    env.update(dt)
    assert(not guard.running() and count_lines(lines, 'stopped after 8 errors: .*step failed on purpose') == 1,
        table.concat(lines, ' | '))
    bodies_are(m, {}, 2047, 'released by the stop')
    -- P2: the first failure survives shutdown, also when an error below arrives later.
    ctl.failing, ctl.raising = false, true
    pcall(env.update, dt)
    env.shutdown()
    assert(guard.status.state:find('^stopped after: stopped after 8 errors: '), guard.status.state)
end
do
    -- P2: an update below that raised on the last frame before shutdown is the first failure.
    local _, _, env, ctl, guard, lines = guarded()
    ctl.raising = true; pcall(env.update, dt)
    env.shutdown()
    assert(guard.status.state == 'stopped after: the previous update failed', guard.status.state)
end
do
    -- A restore that cannot write stops the mod instead of pausing it.
    local m, _, env, ctl, guard, lines = guarded()
    m.writable = false
    ctl.raising = true; pcall(env.update, dt); ctl.raising = false
    env.update(dt)
    assert(not guard.running() and count_lines(lines, 'pause failed: body memory not writable') == 1,
        table.concat(lines, ' | '))
end
do
    -- Hostile neighbours: one re-hooking above every frame and one calling the chain below twice.
    local m, fix, env = guarded()
    H.chain(env, 'double_call')
    H.chain(env, 'rehook')
    for _ = 1, 120 do env.update(dt) end
    m.poke(ARM_STATE, le32(1)); m.poke(ARM_INSTANCE_ID, le32(ID2)); env.update(dt)
    bodies_are(m, ARM_FAMILY_BODIES, 2047, 'neighbours above and below')
    assert(fix.weapons[ARM_STATE] and fix.weapons[ARM_STATE].marked, 'still working')
end
do
    -- The guard allocates nothing per frame, even interpreted.
    local _, _, env = guarded()
    for _ = 1, 300 do env.update(dt) end
    jit.off(); jit.flush()
    collectgarbage('collect'); collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 120 do env.update(dt) end
    local bytes = (collectgarbage('count') - before) * 1024
    collectgarbage('restart'); jit.on()
    assert(bytes == 0, 'guarded frames allocate ' .. bytes .. ' B')
end

-- Machine code in the LuaJIT cache the game and every mod share. The straight-line rarely-run paths (burst starts,
-- grouping, releases, the 0.5 s check, the start and end of a body scan) stay interpreted (jit.off on those functions
-- only): no trace may start in them. The body scan's loop stays compiled; this world's block view is a Lua table with
-- a metamethod, so that loop adds little here (with the real adapter: src/flame_damage_fixed.lua, `interpreted`).
-- Over 30 bursts on this world the mod's own traces measured 12.8-16.7 KB in the game's lua51.dll and 6.8-15.4 KB in
-- the workspace LuaJIT (30 runs each); the limit is 18 KB, about 10% over the highest. With the straight-line paths
-- compiled too it is 32-45 KB. The step is called from C, as the game calls update, so its traces end where it
-- returns.
do
    local util = require('jit.util')
    local m = world(); physics(m, {limit = 4000, instances = 2})
    local fix = Fix.new(m.api, GAME, EXE, function() end)
    local rare = {}
    for _, fn in ipairs({Fix.family, Fix.scan_begin, Fix.verify, Fix.mark, Fix.unmark, Fix.group_free,
                         Fix.resolve_effect, Fix.check_effect, Fix.apply_effect, Fix.check_filter, Fix.flame_slot,
                         Fix.find_instance, Fix.retarget_instance, Fix.restore_flames, fix.scan, fix.burst_start,
                         fix.reset}) do
        rare[fn] = true
    end
    local mine, bytes, rare_starts = {}, 0, 0
    jit.flush() -- lint-ok: R5 test only: a fresh code cache for the measurement
    jit.attach(function(what, tr, func) -- lint-ok: R5 test only: counts this test's traces
        if what == 'start' then
            mine[tr] = (util.funcinfo(func).source or ''):find('flame_damage_fixed.lua', 1, true) ~= nil
            if rare[func] then rare_starts = rare_starts + 1 end
        elseif what == 'stop' and mine[tr] then
            local code = util.tracemc(tr)
            bytes = bytes + (code and #code or 0)
        end
    end, 'trace')
    local function tick() fix.step(dt) end
    local ONE = '\0'
    local function frames(n) for _ = 1, n do ONE:gsub('.', tick) end end
    frames(120)
    for b = 1, 30 do
        for index = 1, 12 do m.api.write_u32(ps_address(index) + 5764, (index == 6 or index == 12) and 0x4a or 11) end
        m.poke(ARM_INSTANCE_ID, le32(b % 2 == 1 and ID1 or ID2)); m.poke(ARM_STATE, le32(1)); frames(1)
        m.poke(ARM_STATE, le32(2)); frames(120)
        m.poke(ARM_STATE, le32(0))
        if b == 15 then m.api.write_u32(BODIES + 160 * 7 + 144, 0xc0000777) end -- a rescan
        frames(120)
    end
    m.poke(SPRAY_MGR + 0x38, le32(0)); frames(200)
    jit.attach(function() end, 'trace') -- lint-ok: R5 test only: detaches the counter
    if PRINT_BUDGETS then print(string.format('machine code for 30 bursts: %d bytes', bytes)) end
    assert(rare_starts == 0, rare_starts .. ' traces started in rarely-run functions')
    assert(bytes < 18 * 1024, string.format('%.1f KB of machine code for 30 bursts', bytes / 1024))
end

-- A second deployed copy returns before doing anything: no update hook, no FFI declarations.
do
    local update_before = rawget(_G, 'update')
    _G.FlameDamageFixedInstalled = true
    assert(dofile(root .. '/src/flame_damage_fixed.lua') == nil, 'second copy returns nothing')
    assert(rawget(_G, 'update') == update_before, 'second copy leaves the update hook alone')
    _G.FlameDamageFixedInstalled = nil
end

-- Loader detection matches the published loaders' own tables (the v18 release reports version 17).
do
    local function open_log() end
    assert(Fix.loader_ok({version = 17, api = 1, modules = {}, open_log = open_log, jit = {managed = true}}), 'v18')
    assert(Fix.loader_ok({version = 17, api = 1, modules = {}, open_log = open_log,
        jit = {managed = false, reason = 'unsupported'}}), 'v18 without a managed cache')
    assert(not Fix.loader_ok({version = 17, api = 1, modules = {}, open_log = open_log}), 'v17 refused')
    assert(not Fix.loader_ok({version = 18, api = 2, open_log = open_log, jit = {}}), 'other API refused')
    assert(not Fix.loader_ok(nil), 'no loader refused')
end

print('PASS: patch table layout, effect lookup/check/apply with refusals and write guard, collision filter check, '
    .. 'weapon family (hull, arm, cannon; pilot excluded; bound), body scan in 64 KB blocks (only owned, hittable, '
    .. 'group-free or own-group bodies) and read spans, group allocator, verify/mark/unmark (group bits only; '
    .. 'recycled and regrouped bodies untouched; write guard), instances by id and flame grouping (array read once), '
    .. 'driver budgets (scan, family, body scan, present, first/second burst with one read per span, firing, group '
    .. 'check on the weapon scan, release when weapons leave, idle), groups kept between bursts, distinct groups per '
    .. 'weapon, rebuilt hit-box rescan, release mid-rescan, re-grouping, destroyed vehicle released, group handed out '
    .. 'by the allocator (between bursts and at a burst start), group carried by other bodies (skipped when picking, '
    .. 'left after a rescan; the other bodies untouched; bodies of its other weapons are its own), no usable group, refusals, mission '
    .. 'reload, no garbage (interpreted), straight-line rarely-run paths interpreted (no trace starts in them; under 18 KB '
    .. 'of machine code for 30 bursts), update chain (errors below pass through; pause restores bodies and flames '
    .. 'and resumes after 60 clean frames; 8 errors in a burst stop and restore; bursts end after 3600 clean frames; '
    .. 'first failure at shutdown; restore refused stops; hostile neighbours; no garbage), re-entry guard, loader '
    .. 'detection (v18 reports version 17)')
