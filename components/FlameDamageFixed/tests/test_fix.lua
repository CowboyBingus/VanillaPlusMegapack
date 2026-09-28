-- Offline tests for Flame Damage Fixed against synthetic engine structures, with per-frame call budgets.
-- Usage: luajit tests/test_fix.lua <project root>   (also run in the game's lua51.dll by scripts/build.py)
local root = assert(arg[1], 'project root required')
local budget = dofile(root .. '/tests/frame_budget.lua')
_G.FLAME_DAMAGE_FIXED_TEST = true
local Fix = dofile(root .. '/src/flame_damage_fixed.lua')
_G.FLAME_DAMAGE_FIXED_TEST = nil

local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function le64(v) return le32(v % 4294967296) .. le32(math.floor(v / 4294967296)) end
local function word_at(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
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
local function Memory()
    local m = {segments = {}, writable = true}
    function m.put(base, bytes) m.segments[#m.segments + 1] = {base = base, bytes = bytes} end
    local function find(address, size)
        for _, s in ipairs(m.segments) do
            if address >= s.base and address + size <= s.base + #s.bytes then return s end
        end
    end
    function m.poke(address, bytes)
        local s = assert(find(address, #bytes), 'poke outside memory')
        local o = address - s.base
        s.bytes = s.bytes:sub(1, o) .. bytes .. s.bytes:sub(o + #bytes + 1)
    end
    local api = {}
    function api.u32(address)
        local s = find(address, 4); if not s then return nil end
        return word_at(s.bytes, address - s.base)
    end
    function api.read(address, size)
        local s = find(address, size); if not s then return nil end
        return s.bytes:sub(address - s.base + 1, address - s.base + size)
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
    m.api = api
    return m
end

-- ---- synthetic engine layout -------------------------------------------------------------
local GAME, EXE = 0x7ff000000000, 0x7ff100000000
local ROOT_OBJ, RM, TYPES, NAMES, RECORDS, DATA = 0x10000000, 0x10001000, 0x10010000, 0x10020000, 0x10030000, 0x10100000
local SPRAY_MGR, ENTITY_PTRS, INSTANCES, ENT_ARM, ENT_SENTRY, ENT_OTHER =
    0x20000000, 0x20001000, 0x20002000, 0x20010000, 0x20010100, 0x20010200
local SENTRY_STATE, ARM_STATE = INSTANCES, INSTANCES + 0x218

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
    m.put(ENT_SENTRY, le32(0xfe962858) .. le32(0x820cc3ba) .. string.rep('\0', 16))
    m.put(ENT_ARM, le32(0xd6328726) .. le32(0x0736bee2) .. string.rep('\0', 16))
    m.put(ENT_OTHER, le32(0x63a70795) .. le32(0x78a8185f) .. string.rep('\0', 16)) -- the Cremator
    m.put(INSTANCES, string.rep('\0', 0x218 * 3))
    return m
end

-- ---- synthetic hknp physics: particle manager, flame instances, particle systems, layer matrix --
local WORLD_OBJ, PM, PM_ENTRIES, PM_LISTS, INST_RECORDS, SIM1, SIM2, SYSTEMS1, SYSTEMS2 =
    0x30000000, 0x30001000, 0x30010000, 0x30020000, 0x30030000, 0x30040000, 0x30040100, 0x30050000, 0x30051000
local WRAPPER, PS_TABLE, PS_ARRAY, PS_HEAP, FILTER_OBJ = 0x31000000, 0x31001000, 0x31010000, 0x32000000, 0x33000000
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
-- Instance 1 (SIM1) owns particle systems 1-6 (1-5 flame on layer 11, 6 another filter); instance 2
-- (SIM2, added by add_instance) owns 7-11; SIM_OTHER belongs to another effect.
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
local function physics(m, options)
    options = options or {}
    m.put(GAME + 0x346BFA0, le64(WORLD_OBJ))
    m.put(WORLD_OBJ + 0x230888, le64(PM))
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
    m.put(INST_RECORDS, string.rep('\0', 8) .. le64(SIM1) .. string.rep('\0', 128) .. le64(SIM2) .. string.rep('\0', 120))
    m.put(SIM1, sim_block(options.foreign and 0x10200000 or DATA, SYSTEMS1))
    m.put(SIM2, sim_block(DATA, SYSTEMS2))
    m.put(SYSTEMS1, systems_block(1))
    m.put(SYSTEMS2, systems_block(7))
    m.put(EXE + 0x27BA890 + 176 * 2, le64(WRAPPER))
    m.put(WRAPPER + 32 + 1144, le64(PS_TABLE))
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
    for _, j in ipairs(options.layer104 or {}) do link(104, j) end
    m.put(FILTER_OBJ, le64(options.vtable or EXE + 0x148B938) .. string.rep('\0', 32) .. matrix_bytes(rows) .. string.rep('\0', 8))
    m.put(EXE + 0x27C5E40, le64(FILTER_OBJ))
end
local function row_of(m, layer)
    local b = m.api.read(FILTER_OBJ + 40 + 16 * layer, 16)
    local set = {}
    for k = 0, 3 do
        local w = word_at(b, 4 * k)
        for j = 0, 31 do if math.floor(w / 2 ^ j) % 2 == 1 then set[#set + 1] = 32 * k + j end end
    end
    return set
end
local function layer_of(m, index) return m.api.u32(ps_address(index) + 5764) end
local function fixed_effect(m)
    for _, row in ipairs(Fix.PATCHES) do
        if m.api.u32(DATA + row.o) ~= row.t then return false end
    end
    return true
end

-- ---- patch table ---------------------------------------------------------------------------
do
    assert(#Fix.PATCHES == 16, 'spawn (8) + emitters (8) words')
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
                assert(not (rel >= 0xe0 and rel < 0x108), 'never a layout field: ' .. row.o)
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
    assert(ok and detail == 16 and fixed_effect(m), 'all 16 words fixed')
    budget.check(f, {u32 = 84, writable_data = 1, write_raw = 16}, 'first apply')
    local changed = 0
    local after = m.api.read(DATA, Fix.EFFECT_SIZE)
    for i = 1, #after do if after:byte(i) ~= SHIPPED:byte(i) then changed = changed + 1 end end
    assert(changed <= 64, 'only the 16 patched words differ from the shipped file')
    f, ok, detail = budget.frame(counts, Fix.apply_effect, m.api, DATA)
    assert(ok and detail == 0, 'second apply writes nothing')
    budget.check(f, {u32 = 52}, 'apply on a fixed effect: word checks only')
    local unknown = world(); unknown.poke(DATA + Fix.PATCHES[3].o, '\1\2\3\4')
    assert(select(2, Fix.apply_effect(unknown.api, DATA)):find('unknown value'), 'unknown value refused')
    local header = world({effect = 'X' .. SHIPPED:sub(2)})
    assert(select(2, Fix.apply_effect(header.api, DATA)):find('header'), 'changed header refused')
    local locked = world(); locked.writable = false
    assert(select(2, Fix.apply_effect(locked.api, DATA)):find('not writable') and not fixed_effect(locked), 'write guard')
end

-- ---- self-hit layer ------------------------------------------------------------------------
do
    local m = world(); physics(m)
    local filter, detail = Fix.ensure_layer(m.api, EXE)
    assert(filter == FILTER_OBJ and detail == '25 matrix words', 'layer 104 added: ' .. tostring(detail))
    assert(table.concat(row_of(m, 104), ',') == table.concat(Fix.NEW_ROW, ','), 'row 104 = flame row without 20')
    for _, layer in ipairs(Fix.NEW_ROW) do
        local has = false
        for _, j in ipairs(row_of(m, layer)) do has = has or j == 104 end
        assert(has, 'symmetric bit for layer ' .. layer)
    end
    for _, j in ipairs(row_of(m, 20)) do assert(j ~= 104, 'the Lumberer hit-box layer never meets 104') end
    assert(table.concat(row_of(m, 11), ',') == table.concat(Fix.FLAME_ROW, ','), 'flame layer 11 untouched')
    assert(Fix.layer_present(m.api, FILTER_OBJ), 'layer present')
    assert(select(2, Fix.ensure_layer(m.api, EXE)) == 'present', 'second setup finds it')
    local function untouched(w) return table.concat(row_of(w, 104), ',') == '0' end
    local w = world(); physics(w, {vtable = EXE + 0x1000})
    assert(select(2, Fix.ensure_layer(w.api, EXE)):find('type changed') and untouched(w), 'wrong filter type')
    w = world(); physics(w, {flame_row = {0, 2, 20}})
    assert(select(2, Fix.ensure_layer(w.api, EXE)):find('row changed') and untouched(w), 'changed flame row')
    w = world(); physics(w, {layer104 = {7}})
    assert(select(2, Fix.ensure_layer(w.api, EXE)):find('in use'), 'layer 104 used elsewhere')
    w = world(); physics(w); w.writable = false
    assert(select(2, Fix.ensure_layer(w.api, EXE)):find('not writable') and untouched(w), 'matrix write guard')
    assert(select(2, Fix.ensure_layer(world().api, EXE)):find('unavailable'), 'no physics')
end

-- ---- flame instances: slot lookup and retargeting ------------------------------------------
do
    local m = world(); physics(m)
    local slot = Fix.flame_slot(m.api, GAME)
    assert(slot == PM_LISTS + 24 * 5, 'flame slot entry')
    local counts = budget.wrap(m.api)
    local region = {}
    local f, moved = budget.frame(counts, Fix.retarget_instance, m.api, EXE, SIM1, DATA, region)
    assert(moved == 5, 'five flame particle systems moved: ' .. tostring(moved))
    budget.check(f, {u32 = 77, writable_region = 1, write_raw = 5}, 'retarget one instance (one heap region)')
    for index = 1, 5 do assert(layer_of(m, index) == 104, 'system ' .. index .. ' on 104') end
    assert(layer_of(m, 6) == 0x4a, 'other filters untouched')
    f, moved = budget.frame(counts, Fix.retarget_instance, m.api, EXE, SIM1, DATA, {})
    assert(moved == 0 and not f.write_raw and not f.writable_region, 'already moved: reads only')
    local foreign = world(); physics(foreign, {foreign = true})
    assert(Fix.retarget_instance(foreign.api, EXE, SIM1, DATA, {}) == 0 and layer_of(foreign, 1) == 11, 'another effect untouched')
    local stale = world(); physics(stale, {stale = 3})
    assert(Fix.retarget_instance(stale.api, EXE, SIM1, DATA, {}) == 4, 'generation mismatch skipped')
    local locked = world(); physics(locked); locked.writable = false
    local none, why = Fix.retarget_instance(locked.api, EXE, SIM1, DATA, {})
    assert(none == nil and why:find('not writable') and layer_of(locked, 1) == 11, 'particle write guard')
    assert(Fix.flame_slot(world().api, GAME) == nil, 'no physics: no slot')
end

-- ---- per-frame driver ----------------------------------------------------------------------
do
    local m = world(); physics(m)
    local lines = {}
    local counts = budget.wrap(m.api)
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    local dt = 1 / 60
    local f = budget.frame(counts, fix.step, dt)
    budget.check(f, {u32 = 20}, 'scan frame')
    assert(#fix.tracked == 2 and fix.tracked[1] == SENTRY_STATE and fix.tracked[2] == ARM_STATE,
        'Flame Sentry and Lumberer arm tracked, the Cremator ignored')
    for _ = 1, 10 do
        f = budget.frame(counts, fix.step, dt)
        budget.check(f, {u32 = 2}, 'present frame: one state read per tracked weapon')
        assert(f.u32 == 2, 'present frame reads exactly the two states')
    end
    -- First burst of the session: effect fixed, layer added, the burst's instance moved.
    m.poke(ARM_STATE, le32(1))
    f = budget.frame(counts, fix.step, dt)
    -- Once per session and mission: effect words (16), layer rows (25), the instance's systems (5).
    budget.check(f, {u32 = 217, read = 1, writable_data = 2, writable_region = 1, write_raw = 46}, 'first burst start')
    assert(fixed_effect(m), 'effect fixed')
    for index = 1, 5 do assert(layer_of(m, index) == 104, 'burst instance system ' .. index .. ' on 104') end
    assert(lines[1]:find('Flame effect fixed %(16 words%)') and lines[2]:find('Self%-hit collision layer added')
        and lines[3]:find('Self%-hit fix active'), table.concat(lines, ' | '))
    -- Firing without a new instance: states + the instance list check, no writes.
    m.poke(ARM_STATE, le32(2))
    f = budget.frame(counts, fix.step, dt)
    budget.check(f, {u32 = 7}, 'firing frame')
    assert(not f.write_raw and not f.writable_region, 'firing frame: reads only')
    -- A second instance appears mid-burst (e.g. the Flame Sentry): moved on the next frame.
    m.poke(PM_LISTS + 24 * 5, le32(2))
    f = budget.frame(counts, fix.step, dt)
    budget.check(f, {u32 = 163, writable_region = 1, write_raw = 5}, 'new instance frame')
    for index = 7, 11 do assert(layer_of(m, index) == 104, 'second instance system ' .. index .. ' on 104') end
    assert(layer_of(m, 12) == 0x4a, 'second instance other filter untouched')
    -- Firing stops: the list is watched for WATCH_SECONDS more, then frames go back to the state reads.
    m.poke(ARM_STATE, le32(3))
    for _ = 1, 30 do fix.step(dt) end
    for _ = 1, 40 do fix.step(dt) end
    f = budget.frame(counts, fix.step, dt)
    assert(f.u32 == 2 and not f.read, 'watch window closed: state reads only: ' .. budget.describe(f))
    -- Second burst (same mission): nothing left to write; the effect check stops at its first fixed word.
    local before = #lines
    m.poke(ARM_STATE, le32(2))
    f = budget.frame(counts, fix.step, dt)
    -- Every burst start re-checks the live instances (reads only): an instance can reuse an old address.
    budget.check(f, {u32 = 206}, 'second burst start')
    assert(not f.write_raw and not f.writable_data and not f.writable_region and #lines == before, 'no writes, no log')
    m.poke(ARM_STATE, le32(3))
    -- A Flame Sentry burst is handled the same way.
    for _ = 1, 70 do fix.step(dt) end
    m.poke(SENTRY_STATE, le32(1)); fix.step(dt)
    assert(fix.watch_until, 'sentry burst opens the watch window')
    m.poke(SENTRY_STATE, le32(0))
    -- Weapons gone: zero calls between scans, one scan per SCAN_SECONDS.
    m.poke(SPRAY_MGR + 0x38, le32(0))
    for _ = 1, 100 do fix.step(dt) end
    assert(#fix.tracked == 0, 'weapons dropped after the rescan')
    local calls, scans = 0, 0
    for _ = 1, 30 do
        f = budget.frame(counts, fix.step, dt)
        assert(not f.writable_data and not f.writable_region and not f.write_raw and not f.read, 'idle frame: ' .. budget.describe(f))
        if (f.u32 or 0) > 0 then
            scans = scans + 1
            assert(f.u32 <= 3, 'idle scan reads the manager pointer and count only: ' .. budget.describe(f))
        end
        calls = calls + (f.u32 or 0)
    end
    assert(scans <= 1 and calls <= 3, 'idle: at most one manager check per scan period: ' .. calls)
end

-- A new mission reloads the effect: the next burst fixes it again; the session layer stays.
do
    local m = world(); physics(m)
    local lines = {}
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    local dt = 1 / 60
    fix.step(dt); m.poke(ARM_STATE, le32(2)); fix.step(dt); m.poke(ARM_STATE, le32(0))
    assert(fixed_effect(m), 'first mission fixed')
    for _, row in ipairs(Fix.PATCHES) do m.poke(DATA + row.o, le32(row.v)) end -- reloaded from disk
    for _ = 1, 100 do fix.step(dt) end
    m.poke(ARM_STATE, le32(2)); fix.step(dt)
    assert(fixed_effect(m), 'reloaded effect fixed again')
    local fixes = 0
    for _, line in ipairs(lines) do if line:find('Flame effect fixed') then fixes = fixes + 1 end end
    assert(fixes == 2, 'each fix is logged once: ' .. fixes)
end

-- Refusals disable only the self-hit part, once, with one log line; the effect fix still applies.
do
    local m = world(); physics(m, {flame_row = {0, 2, 20}})
    local lines = {}
    local counts = budget.wrap(m.api)
    local fix = Fix.new(m.api, GAME, EXE, function(line) lines[#lines + 1] = line end)
    local dt = 1 / 60
    fix.step(dt); m.poke(ARM_STATE, le32(2)); fix.step(dt)
    assert(fixed_effect(m) and fix.layer_off and layer_of(m, 1) == 11, 'effect fixed, layer refused')
    local disabled = 0
    for _, line in ipairs(lines) do if line:find('Self%-hit fix disabled') then disabled = disabled + 1 end end
    assert(disabled == 1, 'refusal logged once')
    local f = budget.frame(counts, fix.step, dt)
    assert(f.u32 == 2 and not f.read, 'firing with the layer refused: state reads only: ' .. budget.describe(f))
end

-- Frames that only read make no garbage, even interpreted: in game, cold paths such as the weapon scan
-- run in the interpreter. The fake memory's reads allocate nothing. Test only: jit.flush() drops earlier
-- traces so every measured frame is interpreted (mods never call it).
do
    local m = world(); physics(m)
    local fix = Fix.new(m.api, GAME, EXE, function() end)
    local dt = 1 / 60
    fix.step(dt); m.poke(ARM_STATE, le32(2)); fix.step(dt); m.poke(ARM_STATE, le32(3))
    for _ = 1, 120 do fix.step(dt) end -- first burst written, watch window closed, several scans
    local function garbage(frames)
        collectgarbage('collect'); collectgarbage('stop')
        local before = collectgarbage('count')
        for _ = 1, frames do fix.step(dt) end
        local bytes = (collectgarbage('count') - before) * 1024
        collectgarbage('restart')
        return bytes
    end
    jit.off(); jit.flush()
    local present = garbage(90) -- 1.5 s: present frames and three weapon scans
    m.poke(ARM_STATE, le32(2))
    local burst = garbage(1) -- second burst start: effect check, slot lookup, live instance re-check
    local firing = garbage(60)
    m.poke(ARM_STATE, le32(0)); m.poke(SPRAY_MGR + 0x38, le32(0))
    for _ = 1, 100 do fix.step(dt) end
    local idle = garbage(90)
    jit.on()
    assert(present == 0 and burst == 0 and firing == 0 and idle == 0, string.format(
        'garbage: present %d B, burst start %d B, firing %d B, idle %d B', present, burst, firing, idle))
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

print('PASS: patch table layout, effect lookup/check/apply with refusals and write guard, '
    .. 'self-hit layer (row 104 = flame row minus 20, symmetric, refusals), flame slot and instance '
    .. 'retargeting (one region check, other effects untouched), driver budgets (scan, 1 read per tracked '
    .. 'weapon, first/second burst, firing, new instance, idle 0 between scans), mission reload and refusals, '
    .. 'no garbage in read-only frames (interpreted), re-entry guard, loader detection (v18 reports version 17)')
