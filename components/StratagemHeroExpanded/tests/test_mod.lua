-- Offline tests for Stratagem Hero Expanded: the real Bingus Shared Runtime (reads, and writes on this test
-- process) against a synthetic game.dll in FFI memory, with exact per-scenario call budgets; the game's picker
-- ported to check every stratagem's odds; the page check against this process's own image pages.
-- Usage: luajit tests/test_mod.lua <project root>   (also run in the game's lua51.dll by scripts/build.py)
local root = assert(arg[1], 'project root required')
local H = dofile(root .. '/tests/hostile_vm.lua')
-- A mod that loaded first declared the plain Windows names with a wrong prototype; the runtime's private names
-- must keep working.
local clash = H.clash({'GetModuleHandleA', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
                       'WriteProcessMemory'})
local ffi = require('ffi')
local budget = dofile(root .. '/tests/frame_budget.lua')
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local memory = dofile(root .. '/src/bingus_memory.lua')
local writes = dofile(root .. '/src/bingus_write.lua')
local Mod = dofile(root .. '/src/stratagem_hero_expanded.lua')
local VANILLA = dofile(root .. '/tests/vanilla_tables.lua')
local PRINT_BUDGETS = os.getenv('SHE_PRINT_BUDGETS') ~= nil
local passed = 0

-- This build's settings (Helldivers2_RawData 1.007.100, whose type numbers match game.dll's StratagemType names):
-- the 96 stratagems marked selectable for a loadout, and the 12 mission stratagems the pool adds.
local LOADOUT = {1, 2, 3, 4, 6, 8, 9, 10, 12, 13, 14, 16, 18, 21, 22, 23, 24, 25, 26, 27, 30, 32, 34, 38, 39, 41,
                 43, 44, 45, 46, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 61, 62, 63, 65, 66, 67, 68, 73, 74, 75, 80,
                 81, 83, 87, 88, 89, 91, 92, 96, 97, 99, 100, 101, 104, 105, 106, 107, 110, 112, 113, 114, 115, 116,
                 117, 118, 119, 120, 121, 125, 126, 127, 130, 131, 132, 133, 134, 135, 136, 137, 139, 140, 141, 142,
                 144, 147, 149}
-- Illumination Flare, Super Earth Flag, Seismic Probe, SEAF Artillery, Resupply, Hellbomb, Eagle Rearm,
-- Prospecting Drill, Reinforce, Upload Data, SOS Beacon, Extraction.
local MISSION = {5, 11, 19, 28, 33, 42, 49, 70, 124, 128, 145, 148}
-- The class each pool stratagem's settings give it (StratagemInfo +0x188, same source), and the families those
-- classes form.
local CLASS = {[1] = 27, [2] = 24, [3] = 7, [4] = 2, [5] = 0, [6] = 19, [8] = 30, [9] = 34, [10] = 28, [11] = 0,
    [12] = 36, [13] = 13, [14] = 21, [16] = 19, [18] = 9, [19] = 0, [21] = 4, [22] = 33, [23] = 30, [24] = 22,
    [25] = 20, [26] = 26, [27] = 28, [28] = 0, [30] = 7, [32] = 13, [33] = 0, [34] = 6, [38] = 10, [39] = 19,
    [41] = 6, [42] = 0, [43] = 23, [44] = 32, [45] = 15, [46] = 36, [49] = 7, [50] = 27, [51] = 11, [52] = 32,
    [53] = 31, [54] = 20, [55] = 22, [56] = 14, [57] = 24, [58] = 5, [59] = 33, [61] = 16, [62] = 4, [63] = 17,
    [65] = 9, [66] = 29, [67] = 23, [68] = 18, [70] = 0, [73] = 24, [74] = 6, [75] = 20, [80] = 15, [81] = 15,
    [83] = 2, [87] = 20, [88] = 28, [89] = 19, [91] = 28, [92] = 12, [96] = 23, [97] = 20, [99] = 19, [100] = 11,
    [101] = 21, [104] = 35, [105] = 26, [106] = 3, [107] = 5, [110] = 20, [112] = 16, [113] = 14, [114] = 11,
    [115] = 24, [116] = 0, [117] = 32, [118] = 1, [119] = 36, [120] = 21, [121] = 29, [124] = 0, [125] = 4,
    [126] = 9, [127] = 20, [128] = 0, [130] = 20, [131] = 15, [132] = 0, [133] = 9, [134] = 22, [135] = 26,
    [136] = 3, [137] = 31, [139] = 36, [140] = 8, [141] = 14, [142] = 24, [144] = 34, [145] = 0, [147] = 19,
    [148] = 0, [149] = 17}
local function family(class)
    if class == 0 then return 'mission' end
    for _, range in ipairs({{1, 6, 'orbital'}, {7, 10, 'eagle'}, {11, 20, 'weapon'}, {21, 24, 'backpack'},
                            {26, 28, 'vehicle'}, {29, 32, 'sentry'}, {33, 35, 'emplacement'}, {36, 36, 'mine'}}) do
        if class >= range[1] and class <= range[2] then return range[3] end
    end
    error('unknown class ' .. class)
end
-- The families each group must hold, all of them and nothing else.
local GROUP_FAMILIES = {{'backpack'}, {'eagle'}, {'orbital'}, {'weapon'}, {'weapon'}, {'sentry', 'emplacement'},
                        {'vehicle', 'mine'}, {'mission'}}
-- What vanilla reaches (decoded from the game's tables by hand, see the knowledge base entry).
local VANILLA_POOL = {3, 13, 18, 25, 30, 33, 42, 43, 53, 56, 63, 66, 73, 83, 92, 107, 117, 119, 124, 125, 130,
                      134, 136, 140, 141, 144, 147}
local THEMES = {[0] = {1}, [1] = {2}, [2] = {3}, [3] = {4, 5}} -- tier: the groups of its theme

local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function le64(v) return le32(v % 4294967296) .. le32(math.floor(v / 4294967296)) end
local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local float = ffi.new('float[1]')
local function f32(bytes, offset)
    ffi.copy(float, bytes:sub(offset + 1, offset + 4), 4)
    return float[0]
end
local function unhex(text) return (text:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)) end
local function set(list)
    local result = {}
    for _, value in ipairs(list) do result[value] = true end
    return result
end
local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function pin(frame, limits, label)
    if PRINT_BUDGETS then print(label .. ': ' .. budget.describe(frame)) end
    budget.check(frame, limits, label)
    for name, limit in pairs(limits) do
        assert((frame[name] or 0) == limit, label .. ': ' .. name .. ' ' .. tostring(frame[name]) .. ' calls, pinned '
            .. limit)
    end
end

local function expect_error(pattern, fn, ...)
    local ok, err = pcall(fn, ...)
    assert(not ok, 'expected an error matching ' .. pattern)
    assert(tostring(err):find(pattern, 1, true), 'error "' .. tostring(err) .. '" lacks "' .. pattern .. '"')
end

local function test(name, fn)
    fn()
    passed = passed + 1
    if PRINT_BUDGETS then print('ok ' .. name) end
end

-- The game's picker (game.dll 0x598370) as odds: a group by weight (entries until group 0, at most 8), then one of
-- its stratagems uniformly (until 0, at most 16). Returns {stratagem = chance} for tier.
local function odds(tables, tier)
    local entries, total = {}, 0
    for slot = 0, 7 do
        local group = u32(tables.tiers, tier * 68 + 4 + slot * 8)
        if group == 0 then break end
        local weight = f32(tables.tiers, tier * 68 + 8 + slot * 8)
        entries[#entries + 1], total = {group, weight}, total + weight
    end
    local chance = {}
    for _, entry in ipairs(entries) do
        local members = {}
        for slot = 0, 15 do
            local stratagem = u32(tables.groups, entry[1] * 64 + slot * 4)
            if stratagem == 0 then break end
            members[#members + 1] = stratagem
        end
        assert(#members > 0, 'tier ' .. tier .. ' lists the empty group ' .. entry[1])
        for _, stratagem in ipairs(members) do
            chance[stratagem] = (chance[stratagem] or 0) + entry[2] / total / #members
        end
    end
    return chance
end

local function near(a, b) return math.abs(a - b) < 1e-6 end

-- Tables --------------------------------------------------------------------------------------------------------

test('vanilla encoding equals the game byte for byte', function()
    local tables = Mod.tables()
    assert(tables.vanilla.tiers == unhex(VANILLA.tiers), 'vanilla tiers differ from the game')
    assert(tables.vanilla.groups == unhex(VANILLA.groups), 'vanilla groups differ from the game')
    assert(#tables.expanded.tiers == 612 and #tables.expanded.groups == 640)
end)

test('vanilla reaches its 27 stratagems', function()
    local tables, reached = Mod.tables(), {}
    for tier = 0, 8 do
        for stratagem in pairs(odds(tables.vanilla, tier)) do reached[stratagem] = true end
    end
    local found = sorted_keys(reached)
    assert(table.concat(found, ',') == table.concat(VANILLA_POOL, ','), table.concat(found, ','))
end)

test('expanded pool: every loadout and mission stratagem, once', function()
    local seen, count = {}, 0
    assert(#Mod.GROUPS <= 8, 'a tier lists at most 8 groups')
    for index, group in ipairs(Mod.GROUPS) do
        assert(#group >= 1 and #group <= 16, 'group ' .. index .. ' holds ' .. #group)
        for _, stratagem in ipairs(group) do
            assert(not seen[stratagem], 'stratagem ' .. stratagem .. ' twice')
            seen[stratagem], count = true, count + 1
        end
    end
    local expected = set(LOADOUT)
    for _, stratagem in ipairs(MISSION) do expected[stratagem] = true end
    assert(#LOADOUT == 96 and count == 108, 'pool of ' .. count)
    assert(table.concat(sorted_keys(seen), ',') == table.concat(sorted_keys(expected), ','), 'pool differs')
end)

test("groups follow the game's own classes", function()
    -- Every pool stratagem of a family sits in that family's group(s), and a group holds nothing else.
    local where = {}
    for index, families in ipairs(GROUP_FAMILIES) do
        for _, name in ipairs(families) do
            where[name] = where[name] or {}
            where[name][index] = true
        end
    end
    assert(#Mod.GROUPS == #GROUP_FAMILIES)
    for index, group in ipairs(Mod.GROUPS) do
        for _, stratagem in ipairs(group) do
            local name = family(assert(CLASS[stratagem], 'no class for ' .. stratagem))
            assert(where[name][index], 'stratagem ' .. stratagem .. ' (' .. name .. ') is in group ' .. index)
        end
    end
    -- The themes hold every member of their family: 14 backpacks, 9 Eagles, 13 orbitals, 32 support weapons.
    local count = {}
    for stratagem, class in pairs(CLASS) do count[family(class)] = (count[family(class)] or 0) + 1 end
    assert(#Mod.GROUPS[1] == count.backpack and count.backpack == 14)
    assert(#Mod.GROUPS[2] == count.eagle and count.eagle == 9)
    assert(#Mod.GROUPS[3] == count.orbital and count.orbital == 13)
    assert(#Mod.GROUPS[4] + #Mod.GROUPS[5] == count.weapon and count.weapon == 32)
end)

test('expanded odds: even in plain rounds, vanilla theme shares in themed rounds', function()
    local tables = Mod.tables()
    local pool = 108
    for tier = 0, 8 do
        local chance, total = odds(tables.expanded, tier), 0
        assert(#sorted_keys(chance) == pool, 'tier ' .. tier .. ' reaches ' .. #sorted_keys(chance))
        for _, p in pairs(chance) do total = total + p end
        assert(near(total, 1), 'tier ' .. tier .. ' odds sum to ' .. total)
        local theme = THEMES[tier]
        if not theme then
            for stratagem, p in pairs(chance) do assert(near(p, 1 / pool), 'uneven odds for ' .. stratagem) end
        else
            local members, share = {}, 0
            for _, group in ipairs(theme) do
                for _, stratagem in ipairs(Mod.GROUPS[group]) do members[stratagem] = true end
            end
            for stratagem, p in pairs(chance) do if members[stratagem] then share = share + p end end
            local vanilla = tier == 3 and 0.6 / 1.425 or 1 / 1.825
            assert(near(share, vanilla), 'tier ' .. tier .. ' theme share ' .. share)
            local others = #sorted_keys(chance) - #sorted_keys(members)
            for stratagem, p in pairs(chance) do
                if not members[stratagem] then assert(near(p, (1 - share) / others), 'uneven: ' .. stratagem) end
            end
        end
        -- The banners stay.
        assert(u32(tables.expanded.tiers, tier * 68) == u32(tables.vanilla.tiers, tier * 68))
    end
end)

test('encoders refuse what the picker cannot read', function()
    local tiers = {}
    for i = 1, 9 do tiers[i] = {banner = 0, {1, 1}} end
    tiers[9] = {banner = 0, {1, 1}, {2, 1}, {3, 1}, {4, 1}, {5, 1}, {6, 1}, {7, 1}, {8, 1}, {9, 1}}
    expect_error('A tier lists 1 to 8 groups', Mod.encode_tiers, tiers)
    expect_error('Expected 9 tiers', Mod.encode_tiers, {tiers[1]})
    local big = {}
    for i = 1, 17 do big[i] = i end
    expect_error('at most 16 stratagems', Mod.encode_groups, {big})
    expect_error('At most 9 groups', Mod.encode_groups, {{1}, {1}, {1}, {1}, {1}, {1}, {1}, {1}, {1}, {1}})
end)

-- Synthetic game ----------------------------------------------------------------------------------------------

local LAYOUT = {tiers_rva = 0x100, groups_rva = 0x3B0, settings_rva = 0x800} -- 76 bytes between the tables
local GAP = string.rep('\90', 76)

local keep = {}
local function block(size)
    local bytes = ffi.new('uint8_t[?]', size)
    keep[#keep + 1] = bytes
    return ffi.cast('uint8_t *', bytes)
end
local function address(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end
local function put(pointer, offset, bytes) ffi.copy(pointer + offset, bytes, #bytes) end

-- A game.dll with the arcade tables (vanilla unless options.tiers/groups) and StratagemInfo records for types
-- 1-149. options.settings[type] changes one record: missing, type, length, hud, no_code. options.no_probe leaves
-- the probe's pointer unset (settings not loaded yet).
local function World(options)
    options = options or {}
    local w = {game = block(0x1000)}
    local tables = Mod.tables()
    put(w.game, LAYOUT.tiers_rva, options.tiers or tables.vanilla.tiers)
    put(w.game, LAYOUT.tiers_rva + 612, GAP)
    put(w.game, LAYOUT.groups_rva, options.groups or tables.vanilla.groups)
    local changes = options.settings or {}
    for stratagem = 1, 149 do
        local change = changes[stratagem] or {}
        if not change.missing then
            local record, length = block(0x190), change.length or 5
            put(record, 0, le32(change.type or stratagem))
            if not change.no_code then put(record, 0x40, le64(address(block(4 * math.max(length, 1))))) end
            put(record, 0x48, le32(length))
            put(record, 0xB8, le32(change.hud or 2))
            if not (options.no_probe and stratagem == Mod.PROBE) then
                put(w.game, LAYOUT.settings_rva + stratagem * 8, le64(address(record)))
            end
        end
    end
    return w
end

local function arcade(w)
    return ffi.string(w.game + LAYOUT.tiers_rva, 612), ffi.string(w.game + LAYOUT.groups_rva, 640),
        ffi.string(w.game + LAYOUT.tiers_rva + 612, 76)
end
local function holds(w, name)
    local tables = Mod.tables()
    local tiers, groups, gap = arcade(w)
    assert(gap == GAP, 'the bytes between the tables changed')
    return tiers == tables[name].tiers and groups == tables[name].groups
end

-- The runtime api over the synthetic game.dll; verify_build answers like the real one for a matching build.
local function Api(w, build_ok)
    local api = writes.extend(memory.new(runtime))
    function api.module(name)
        if name == 'game.dll' then return w.game end
    end
    function api.verify_build()
        if build_ok == false then return false, 'unsupported game build' end
        return true
    end
    return api
end

-- The real native writes (WriteProcessMemory into this process); the page query answers for game.dll's data
-- pages unless page changes it: {state, type, protection, allocation_base}.
local function Native(api, w, page)
    page = page or {}
    local native = Mod.native(api)
    function native.query()
        local base = address(w.game)
        return {state = page.state or 0x1000, type = page.type or 0x1000000, protection = page.protection or 0x04,
                allocation_base = page.allocation_base or base, finish = base + 0x1000}
    end
    return native
end

-- Counts api and native calls together (native calls as native.<name>).
local function Counter(api, native)
    local counts, native_counts = budget.wrap(api), budget.wrap(native)
    return function(fn, ...)
        for name in pairs(native_counts) do native_counts[name] = nil end
        local results = {budget.frame(counts, fn, ...)}
        for name, n in pairs(native_counts) do results[1]['native.' .. name] = n end
        return unpack(results)
    end
end

local function Loader()
    local loader = {api = 1, lines = {}}
    function loader.open_log()
        return {write = function(_, text) loader.lines[#loader.lines + 1] = text end, flush = function() end}
    end
    function loader.text() return table.concat(loader.lines) end
    return loader
end

-- The applying attempt: 1 probe read, the pointer table, 108 records, the tables, their read back.
local APPLIED = {read = 112, pointer = 217, address = 6, ['native.query'] = 2, ['native.write'] = 2}
local ALREADY = {read = 111, pointer = 217}

-- Mod.attempt -------------------------------------------------------------------------------------------------

test('applied: both tables written, nothing else', function()
    local w = World()
    local api = Api(w)
    local native = Native(api, w)
    local frame, result, pages = Counter(api, native)(Mod.attempt, api, native, w.game, LAYOUT, Mod.tables())
    assert(result == 'applied' and pages == '0x04, 0x04', tostring(result) .. ' ' .. tostring(pages))
    pin(frame, APPLIED, 'attempt applied')
    assert(holds(w, 'expanded'), 'tables not written')
end)

test('already applied: nothing is written', function()
    local w = World({tiers = Mod.tables().expanded.tiers, groups = Mod.tables().expanded.groups})
    local api = Api(w)
    local native = Native(api, w)
    local frame, result = Counter(api, native)(Mod.attempt, api, native, w.game, LAYOUT, Mod.tables())
    assert(result == 'already applied')
    pin(frame, ALREADY, 'attempt already applied')
end)

test('waits: the stratagem settings are not loaded', function()
    local w = World({no_probe = true})
    local api = Api(w)
    local native = Native(api, w)
    local frame, result, detail = Counter(api, native)(Mod.attempt, api, native, w.game, LAYOUT, Mod.tables())
    assert(result == 'wait' and detail:find('stratagem settings', 1, true))
    pin(frame, {read = 1, pointer = 1}, 'attempt waiting')
    assert(holds(w, 'vanilla'))
end)

test('refuses: settings the arcade cannot show, tables that differ', function()
    local function refuses(pattern, options, page)
        local w = World(options)
        local api = Api(w)
        expect_error(pattern, Mod.attempt, api, Native(api, w, page), w.game, LAYOUT, Mod.tables())
        local tiers, groups = arcade(w)
        local start = options and options.tiers or Mod.tables().vanilla.tiers
        assert(tiers == start and groups == (options and options.groups or Mod.tables().vanilla.groups),
            'wrote although refused: ' .. pattern)
    end
    refuses('No settings for stratagem 149', {settings = {[149] = {missing = true}}})
    refuses('The settings of stratagem 2 belong to another stratagem', {settings = {[2] = {type = 3}}})
    refuses('The code of stratagem 1 does not fit the arcade', {settings = {[1] = {length = 11}}})
    refuses('The code of stratagem 5 does not fit the arcade', {settings = {[5] = {length = 0}}})
    refuses('The code of stratagem 148 does not fit the arcade', {settings = {[148] = {no_code = true}}})
    refuses('Unexpected HUD type for stratagem 33', {settings = {[33] = {hud = 5}}})
    local tables = Mod.tables()
    local changed = tables.vanilla.groups:sub(1, 100) .. '\1' .. tables.vanilla.groups:sub(102)
    refuses("The arcade's tables differ from build 25480438's", {groups = changed})
    refuses("The arcade's tables differ", {tiers = tables.expanded.tiers}) -- half written
    refuses('not in writable game.dll data pages', nil, {type = 0x20000})       -- private memory
    refuses('not in writable game.dll data pages', nil, {protection = 0x02})    -- read-only
    refuses('not in writable game.dll data pages', nil, {protection = 0x20})    -- code
    refuses('not in writable game.dll data pages', nil, {protection = 0x104})   -- guard page
    refuses('not in writable game.dll data pages', nil, {state = 0x2000})       -- reserved
    refuses('not in writable game.dll data pages', nil, {allocation_base = 0x10000}) -- another module
end)

test('settings without a pool stratagem do not matter; ones outside the pool are not read', function()
    -- Type 7 (an extraction variant outside the pool) has no settings: still applies.
    local w = World({settings = {[7] = {missing = true}, [40] = {length = 50}}})
    local api = Api(w)
    assert(Mod.attempt(api, Native(api, w), w.game, LAYOUT, Mod.tables()) == 'applied')
end)

test('refuses: a failed or lost write', function()
    local w = World()
    local api = Api(w)
    local native = Native(api, w)
    native.write = function() return false end
    expect_error('Arcade table write failed', Mod.attempt, api, native, w.game, LAYOUT, Mod.tables())
    assert(holds(w, 'vanilla'))
    native.write = function() return true end -- claims success, writes nothing
    expect_error('Arcade table write did not hold', Mod.attempt, api, native, w.game, LAYOUT, Mod.tables())
end)

-- The real page query on this process's own pages ----------------------------------------------------------------

-- The RVA of the first writable, non-executable section of the module at base (its .data), from its PE headers.
local function data_section(api, base)
    local header = api.read(base, 0x40)
    local pe = u32(header, 0x3C)
    local nt = api.read(base + pe, 24)
    assert(nt:sub(1, 4) == 'PE\0\0', 'not a PE image')
    local sections, optional = nt:byte(7) + nt:byte(8) * 256, nt:byte(21) + nt:byte(22) * 256
    local table_bytes = api.read(base + pe + 24 + optional, sections * 40)
    for index = 0, sections - 1 do
        local flags = u32(table_bytes, index * 40 + 36)
        local writable, executable = flags >= 0x80000000, math.floor(flags / 0x20000000) % 2 == 1
        if writable and not executable and u32(table_bytes, index * 40 + 8) >= 16 then
            return u32(table_bytes, index * 40 + 12)
        end
    end
end

test('page check: image data pages pass; private, read-only and foreign pages do not', function()
    local api = writes.extend(memory.new(runtime))
    local native = Mod.native(api)
    local host = api.module(nil)
    local data = assert(data_section(api, host), 'the host has no data section')
    local ok, seen = Mod.image_writable(api, native, host, host + data, 16)
    assert(ok and #seen >= 1, 'the host data section was refused: ' .. table.concat(seen, ','))
    assert(not Mod.image_writable(api, native, host, host, 16), 'the read-only header page passed')
    assert(not Mod.image_writable(api, native, host, block(64), 16), 'private memory passed')
    local kernel = api.module('kernel32.dll')
    assert(not Mod.image_writable(api, native, kernel, host + data, 16), "another module's page passed")
    -- The real write: into private test memory (the check above is the mod's guard, not WriteProcessMemory's).
    local target = block(8)
    assert(native.write(target, 'ABCDEFGH') and ffi.string(target, 8) == 'ABCDEFGH')
end)

-- Mod.install -------------------------------------------------------------------------------------------------

local function previous_update(env)
    env.frames = 0
    env.update = function(dt, extra)
        env.frames = env.frames + 1
        return 'vanilla', dt, extra
    end
    return env.update
end

local function installed(w, options)
    options = options or {}
    local api = Api(w, options.build_ok)
    local native = Native(api, w)
    local env = options.env or {}
    local loader = options.loader or Loader()
    local count = Counter(api, native)
    local frame, state = count(Mod.install, api, {env = env, layout = LAYOUT, loader = loader, native = native})
    return {api = api, env = env, loader = loader, state = state, frame = frame, count = count}
end

test('install: applied at load, no update hook, shutdown report', function()
    local env = {}
    local vanilla = previous_update(env)
    local shut = 0
    env.shutdown = function(...) shut = shut + 1; return 'bye', ... end
    local w = World()
    local run = installed(w, {env = env})
    local limits = {module = 1, verify_build = 1}
    for name, n in pairs(APPLIED) do limits[name] = n end
    pin(run.frame, limits, 'install applied at load')
    assert(run.state.applied and env.StratagemHeroExpanded == run.state and holds(w, 'expanded'))
    assert(env.update == vanilla, 'an update hook was installed although the tables were written at load')
    local text = run.loader.text()
    assert(text:find('applied (108 stratagems in 8 groups; pages 0x04, 0x04), at load.', 1, true), text)
    pin(run.count(env.update, 1 / 60), {}, 'frame after load')
    local frame, results = run.count(function(...) return {env.shutdown(...)} end, 'quit')
    pin(frame, {read = 1}, 'shutdown')
    assert(shut == 1 and results[1] == 'bye' and results[2] == 'quit')
    assert(run.loader.text():find('At shutdown: the arcade still draws from the expanded pool.', 1, true))
end)

test('install: shutdown reports lost tables', function()
    local w = World()
    local run = installed(w)
    put(w.game, LAYOUT.groups_rva, Mod.tables().vanilla.groups)
    run.env.shutdown()
    assert(run.loader.text():find('no longer hold the expanded pool', 1, true))
end)

test('install: a refused build or loader writes nothing and hooks nothing', function()
    local env = {}
    local vanilla = previous_update(env)
    local w = World()
    local run = installed(w, {env = env, build_ok = false})
    pin(run.frame, {verify_build = 1}, 'install refused build')
    assert(not run.state.applied and run.state.status:find('Unsupported game build', 1, true))
    assert(env.update == vanilla and env.shutdown == nil and holds(w, 'vanilla'))
    assert(run.loader.text():find('disabled: Unsupported game build (needs Steam build 25480438)', 1, true))
    run = installed(w, {loader = {api = 2}})
    assert(run.state.status:find('API 1 required', 1, true) and holds(w, 'vanilla'))
end)

test('install: refused data at load hooks nothing', function()
    local env = {}
    local vanilla = previous_update(env)
    local run = installed(World({settings = {[149] = {missing = true}}}), {env = env})
    assert(run.state.status:find('^disabled: ') and run.state.status:find('No settings for stratagem 149', 1, true))
    assert(env.update == vanilla and env.shutdown == nil)
end)

test('fallback: waits with one read per frame, applies, then unhooks', function()
    local env = {}
    local vanilla = previous_update(env)
    local w = World({no_probe = true})
    local run = installed(w, {env = env})
    pin(run.frame, {read = 1, pointer = 1, module = 1, verify_build = 1}, 'install waiting')
    assert(env.update ~= vanilla and run.state.status:find('waiting', 1, true))
    assert(run.loader.text():find('Waiting for the game: the stratagem settings are not loaded yet.', 1, true))
    for n = 1, 3 do
        local frame, results = run.count(function() return {env.update(0.5, 'x')} end)
        pin(frame, {read = 1, pointer = 1}, 'waiting frame')
        assert(results[1] == 'vanilla' and results[2] == 0.5 and results[3] == 'x' and env.frames == n)
    end
    env.update(1 / 60) -- warm-up, then no C types per waiting frame
    assert(H.ctype_growth(env.update, 1 / 60) == 0, 'C types created per waiting frame')
    local probe = World()
    put(w.game, LAYOUT.settings_rva + Mod.PROBE * 8, ffi.string(probe.game + LAYOUT.settings_rva + Mod.PROBE * 8, 8))
    pin(run.count(env.update, 0.5), APPLIED, 'frame that applies')
    assert(run.state.applied and holds(w, 'expanded') and env.update == vanilla, 'did not unhook')
    -- Waited: 3 frames of 0.5 s, the warm-up and the C type probe (1/60 s each); the applying frame adds none.
    assert(run.loader.text():find('applied (108 stratagems', 1, true) and run.loader.text():find('after 1.5 s', 1, true))
    pin(run.count(env.update, 1 / 60), {}, 'frame after fallback')
end)

test('fallback: gives up after WAIT_SECONDS and unhooks', function()
    local env = {}
    local vanilla = previous_update(env)
    local w = World({no_probe = true})
    local run = installed(w, {env = env})
    for _ = 1, 10 do env.update(Mod.WAIT_SECONDS / 4) end
    assert(env.update == vanilla and run.state.status:find('disabled: ', 1, true) and run.state.status:find('gave up'))
    assert(run.loader.text():find('stratagem settings are not loaded yet', 1, true) and holds(w, 'vanilla'))
end)

test('fallback: no previous update, a hostile neighbour below and above', function()
    local function load_probe(w)
        local probe = World()
        put(w.game, LAYOUT.settings_rva + Mod.PROBE * 8, ffi.string(probe.game + LAYOUT.settings_rva + Mod.PROBE * 8, 8))
    end
    -- Nothing below: the hook ends with an empty update.
    local w, env = World({no_probe = true}), {}
    installed(w, {env = env})
    env.update(0.1)
    load_probe(w)
    env.update(0.1)
    assert(type(env.update) == 'function' and env.update(0.1) == nil and holds(w, 'expanded'))

    -- A failing update below: its error object reaches the game unchanged, the hook keeps working.
    w, env = World({no_probe = true}), {}
    previous_update(env)
    H.chain(env, 'throw_below', {raise_on = 2})
    installed(w, {env = env})
    assert(pcall(env.update, 0.1))
    local ok, err = pcall(env.update, 0.1)
    assert(not ok and type(err) == 'table' and err.hostile_vm == 'throw_below', 'the error below was changed')
    load_probe(w)
    assert(pcall(env.update, 0.1) and holds(w, 'expanded'))

    -- A mod that wraps update later: the hook stays as a pass-through with no calls.
    w, env = World({no_probe = true}), {}
    previous_update(env)
    local run = installed(w, {env = env})
    H.chain(env, 'rehook')
    env.update(0.1)
    load_probe(w)
    env.update(0.1)
    assert(holds(w, 'expanded'))
    pin(run.count(env.update, 0.1), {}, 'pass-through frame under a later mod')
end)

for name, status in pairs(clash) do
    assert(status == 'clashed' or status == 'already declared', name .. ': ' .. status)
end
print(string.format('PASS: %d Stratagem Hero Expanded tests (%s)', passed, jit and jit.version or _VERSION))
