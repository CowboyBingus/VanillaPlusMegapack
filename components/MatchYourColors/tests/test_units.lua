-- Match Your Colors: unit tests of the decoders and helpers that need no game files: LZ4 blocks, half floats,
-- the game's map probing, the idle watch, numpy summation order, CIEDE2000 reference pairs, the color transfer,
-- the matcher's trim and accent rules and LUT building.
-- Usage: luajit tests/test_units.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_units.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Slim, Texture, Avatar = require('slim'), require('texture'), require('avatar')
local Colour, Matcher, Recolor = require('colour'), require('matcher'), require('recolor')
local Transfer = require('transfer')
Matcher.use(Colour)
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local function from_hex(hex)
    return (hex:gsub('..', function(h) return string.char(tonumber(h, 16)) end))
end

check('LZ4 blocks decode to their data (python-lz4 vectors)', function()
    for i, case in ipairs(dofile(root .. '/tests/fixtures/lz4.lua')) do
        local packed, data = from_hex(case[1]), from_hex(case[2])
        local out = ffi.new('uint8_t[?]', #data + 1)
        local n = Slim.lz4(ffi.cast('const uint8_t *', packed), #packed, out, #data)
        assert(n == #data and ffi.string(out, n) == data, 'vector ' .. i)
    end
end)

check('malformed LZ4 blocks raise instead of writing out of bounds', function()
    local out = ffi.new('uint8_t[16]')
    for _, bad in ipairs({'\240', '\16', '\31\120\0', '\31\120\9\0', '\255\255'}) do
        local ok = pcall(Slim.lz4, ffi.cast('const uint8_t *', bad), #bad, out, 16)
        assert(not ok, 'accepted ' .. bad:gsub('.', function(c) return string.format('%02x', c:byte()) end))
    end
    local long = '\31\120\1\0' -- one literal, match of 15 + 4 bytes into a 16-byte buffer
    assert(not pcall(Slim.lz4, ffi.cast('const uint8_t *', long), #long, out, 16), 'match overrun accepted')
end)

check('half floats', function()
    local cases = {{0x00, 0x3C, 1}, {0x00, 0xC0, -2}, {0xFF, 0x7B, 65504}, {0x01, 0x00, 2 ^ -24},
                   {0x00, 0x7C, math.huge}, {0x00, 0x00, 0}, {0x00, 0x38, 0.5}, {0x55, 0x35, 0.333251953125}}
    for _, c in ipairs(cases) do assert(Texture.half(c[1], c[2]) == c[3], 'half ' .. c[3]) end
    local nan = Texture.half(0x01, 0x7C)
    assert(nan ~= nan, 'NaN')
end)

check('32-bit products are exact (the game\'s map hash)', function()
    for _, c in ipairs({{0xe5, 0x9E3779B1}, {0xFFFFFFFF, 0xFFFFFFFF}, {0x12345678, 0x9ABCDEF1}, {5, 3}}) do
        local exact = tonumber((ffi.cast('uint64_t', c[1]) * c[2]) % 4294967296ULL)
        assert(Avatar.low32_product(c[1], c[2]) == exact, string.format('%x * %x', c[1], c[2]))
    end
end)

-- A map in a byte table: {data at 0x10000, capacity, empty, multiplier} at 0x20000; probing as the game does.
local function fake_map(entries, capacity, multiplier)
    local memory = {}
    local function put32(address, value)
        for k = 0, 3 do memory[address + k] = math.floor(value / 256 ^ k) % 256 end
    end
    put32(0x20000, 0x10000) put32(0x20004, 0) put32(0x20008, capacity) put32(0x2000C, 0xFFFFFFFF)
    put32(0x20010, multiplier)
    for slot = 0, capacity - 1 do put32(0x10000 + 8 * slot, 0xFFFFFFFF) put32(0x10004 + 8 * slot, 0) end
    local used = {}
    for key, value in pairs(entries) do
        local slot = Avatar.low32_product(key, multiplier) % capacity
        while used[slot] do slot = (slot + 1) % capacity end
        used[slot] = true
        put32(0x10000 + 8 * slot, key) put32(0x10004 + 8 * slot, value)
    end
    local buffer = ffi.new('uint8_t[64]')
    return function(address, size)
        for k = 0, size - 1 do
            local b = memory[address + k]
            if b == nil then return nil end
            buffer[k] = b
        end
        return buffer
    end
end

check('map lookups probe like the game (collisions, absent keys, wrap-around)', function()
    local read = fake_map({[5] = 0, [21] = 7, [37] = 9, [15] = 3}, 16, 1)
    assert(Avatar.lookup(read, 0x20000, 5) == 0 and Avatar.lookup(read, 0x20000, 21) == 7)
    assert(Avatar.lookup(read, 0x20000, 37) == 9 and Avatar.lookup(read, 0x20000, 15) == 3)
    assert(Avatar.lookup(read, 0x20000, 6) == nil and Avatar.lookup(read, 0x20000, 53) == nil)
    local hashed = fake_map({[0xe5] = 2, [0x96] = 194}, 1024, 0x9E3779B1)
    assert(Avatar.lookup(hashed, 0x20000, 0xe5) == 2 and Avatar.lookup(hashed, 0x20000, 0x96) == 194)
end)

check('numpy summation order (sequential below 8 terms, eight lanes from 8)', function()
    local a = {1e16, 1, -1e16, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
    assert(Matcher.npsum(a, 3) == ((1e16 + 1) - 1e16), 'sequential')
    local r = {a[1] + a[9], a[2] + a[10], a[3] + a[11], a[4] + a[12], a[5], a[6], a[7], a[8]}
    local expected = ((r[1] + r[2]) + (r[3] + r[4])) + ((r[5] + r[6]) + (r[7] + r[8])) + a[13]
    assert(Matcher.npsum(a, 13) == expected, 'pairwise')
end)

check('CIEDE2000 reference pairs (Sharma, Wu and Dalal 2005)', function()
    local pairs_ = {{50, 2.6772, -79.7751, 50, 0, -82.7485, 2.0425}, {50, 3.1571, -77.2803, 50, 0, -82.7485, 2.8615},
                    {50, -1.3802, -84.2814, 50, 0, -82.7485, 1.0000}, {50, 2.5, 0, 50, 0, -2.5, 4.3065},
                    {50, 0, 0, 50, -1, 2, 2.3669}, {60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644},
                    {90.8027, -2.0831, 1.441, 91.1528, -1.6435, 0.0447, 1.4441}}
    for _, p in ipairs(pairs_) do
        local d = Colour.de2000(p[1], p[2], p[3], p[4], p[5], p[6])
        assert(math.abs(d - p[7]) < 1e-4, string.format('dE %.4f, expected %.4f', d, p[7]))
    end
end)

check('the idle watch reports a change once, then only real changes', function()
    local units = ffi.new('uint8_t[120]')
    local count = ffi.new('uint32_t[1]')
    local memory = {}
    function memory.read_into(address, size, out)
        local a = tonumber(ffi.cast('uintptr_t', address))
        if a == 0x1000 then ffi.copy(out, units, size) return true end
        if a == 0x2000 + 64 then ffi.copy(out, count, 4) return true end
        return false
    end
    local watch = Avatar.watch(memory, {units_at = 0x1000}, 0x2000)
    assert(watch.changed(), 'first call')
    assert(not watch.changed() and not watch.changed(), 'unchanged')
    units[5] = 1
    assert(watch.changed() and not watch.changed(), 'unit change, once')
    count[0] = 1 -- an entry appears, and its bytes cannot be read here
    assert(watch.changed() and watch.changed(), 'unreadable entries count as changes')
    count[0] = 0
    assert(watch.changed() and not watch.changed(), 'entry gone')
end)

-- A color model over flat tiler samples (every texel 0.5: no detail, no camo pattern), so a row's albedo is its
-- base color unless its detail strength or roughness bias (column 1 z, w) says otherwise.
local function flat_model()
    local function layers(n)
        local out = {}
        for l = 0, n - 1 do
            local values = ffi.new('double[2048]')
            for i = 0, 2047 do values[i] = 0.5 end
            out[l] = values
        end
        return out
    end
    return Colour.new(layers(26), 26, layers(5), 5)
end

-- One LUT row (23 columns) as Colour.row_values gives it: material columns get marker values.
local function test_row()
    local c = {}
    for k = 1, 92 do c[k] = 100 + k end
    local function set(column, r, g, b, w) c[column * 4 + 1], c[column * 4 + 2], c[column * 4 + 3], c[column * 4 + 4] = r, g, b, w end
    set(0, 0.5, 0.2, 0.2, 0)      -- red base, mode 0
    set(1, 3, 0.5, 0, 0)          -- detail layer 3, no detail strength or roughness bias
    set(2, 0.52, 0.22, 0.2, 1)    -- detail color near the base: moves
    set(5, 0.95, 0.95, 0.95, 2)   -- white wear (bare metal): stays
    set(6, 0.45, 0.18, 0.18, 0.25) -- wear color near the base: moves; metallic 0.25
    set(21, 0, 0, 0, -1)          -- no camo
    return c
end

check('the transfer reaches the desired color and keeps every material column and distant wear color', function()
    local model = flat_model()
    local transfer = Transfer.new(Colour, model)
    local c, before = test_row(), test_row()
    -- desired: sRGB (0.2, 0.4, 0.6) seen through metallic 0.25
    local lin = function(x) return ((x * 0.947867 + 0.052133) ^ 2.4) end
    local dark = 1 - 0.55 * 0.25
    local L, a, b = Colour.linear_to_lab(lin(0.2) * dark, lin(0.4) * dark, lin(0.6) * dark)
    local gL, ga, gb, err = transfer.fit(c, L, a, b)
    assert(err < Transfer.FIT_DONE and Colour.de2000(gL, ga, gb, L, a, b) == err, 'reached: dE ' .. err)
    assert(math.abs(c[1] - 0.2) < 0.01 and math.abs(c[2] - 0.4) < 0.01 and math.abs(c[3] - 0.6) < 0.01, 'base')
    local moved = {[1] = true, [2] = true, [3] = true, [9] = true, [10] = true, [11] = true, [25] = true, [26] = true,
                   [27] = true}
    for k = 1, 92 do
        if moved[k] then
            assert(c[k] ~= before[k], 'color ' .. k .. ' moved')
        else
            assert(c[k] == before[k], 'value ' .. k .. ' kept')
        end
    end
end)

check('camo rows move their camo colors; an unreachable goal keeps the best step', function()
    local transfer = Transfer.new(Colour, flat_model())
    local c = test_row()
    c[85], c[86], c[87], c[88] = 1, 0, 1, 2 -- camo layer 2
    for column = 16, 19 do c[column * 4 + 1], c[column * 4 + 2], c[column * 4 + 3] = 0.3, 0.3 + column / 100, 0.3 end
    local before = test_row()
    local _, _, _, err = transfer.fit(c, 100, 120, 120) -- outside the displayable range
    assert(err > Transfer.FIT_DONE and err < math.huge, 'best step kept: dE ' .. err)
    for column = 16, 19 do assert(c[column * 4 + 2] ~= 0.3 + column / 100, 'camo color ' .. column .. ' moved') end
    for _, k in ipairs({5, 6, 7, 8, 13, 14, 15, 16, 41}) do assert(c[k] == before[k], 'material value ' .. k) end
    local d = test_row()
    local _, _, _, nan_err = transfer.fit(d, 0 / 0, 0, 0)
    assert(nan_err == math.huge and d[1] == 0.5 and d[2] == 0.2, 'a NaN goal leaves the row unchanged')
end)

check('a red paint going neutral leaves no tint: its neutral detail color stays neutral (the brown Bloodhound)', function()
    local transfer = Transfer.new(Colour, flat_model())
    local c = test_row()
    c[9], c[10], c[11] = 0.2, 0.2, 0.2   -- detail color: a dark neutral near the red base
    c[25], c[26], c[27] = 0.6, 0.3, 0.3  -- wear color: a lighter red of the same hue family
    local _, _, _, err = transfer.fit(c, 26, 0, 0)
    assert(err < Transfer.FIT_DONE, 'reached: dE ' .. err)
    for _, o in ipairs({0, 8, 24}) do -- base, detail, wear: neutral now (v11.0 turned the detail color teal)
        local _, a, b = Colour.srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])
        assert(math.sqrt(a * a + b * b) < 1.5, 'color at ' .. o .. ' is neutral: a ' .. a .. ', b ' .. b)
    end
    assert(c[21] == 0.95 and c[22] == 0.95 and c[23] == 0.95, 'the white wear color far from the paint stays')
end)

-- An item from {key, area, L, a, b[, bare metal[, undergarment fraction]]} rows (no camo; paint unless the 6th is
-- true) and patterns {{pattern, area, r, g, b}} (texel 0 in sRGB).
local function item(rows, armor, patterns)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {key = r[1], area = r[2], under = r[2] * (r[7] or 0), L = r[3], a = r[4], b = r[5],
                  metal = r[6] == true, camo = false, mode = 0, full = r[6] == true}
    end
    return Matcher.item(out, armor, patterns)
end

check('trim rule: a large light area takes the main color, not a small trim (the 2026-10-05 gold suit)', function()
    -- v10 matched lightness: the armor's light 28% area took the helmet's 5% gold trim
    local target = item({{'t:0', 0.72, 24, 0, 0}, {'t:1', 0.28, 62, 0, 2}}, true)
    local source = item({{'s:0', 0.95, 25, 0, 0}, {'s:1', 0.05, 62, 3, 30}}, false)
    local plan = Matcher.plan(target, source)
    assert(plan['t:0'].source == 's:0' and plan['t:1'].source == 's:0' and plan['t:1'].kind == 'pair',
           'main color, not the trim: ' .. plan['t:1'].source)
end)

check('accents take the source accent color, even a small one; dark or already matching accents keep theirs', function()
    local target = item({{'t:0', 0.55, 30, 0, 0}, {'t:1', 0.28, 62, 0, 2}, {'t:2', 0.09, 50, 40, 40},
                         {'t:3', 0.05, 15, 30, 20}, {'t:4', 0.03, 60, 3, 30}}, true)
    local source = item({{'s:0', 0.88, 25, 0, 0}, {'s:1', 0.06, 60, 3, 30}, {'s:2', 0.06, 55, 50, -20}}, false)
    local plan = Matcher.plan(target, source)
    local accent = plan['t:2']
    assert(accent.kind == 'accent' and accent.source == 's:2' and accent.L == 55 and accent.a == 50 and accent.b == -20,
           'the accent takes the most salient source accent color')
    assert(plan['t:3'] == nil, 'a dark accent (L < 20) keeps its color')
    assert(plan['t:4'] == nil, 'an accent that already matches a source color keeps it')
    local plain = Matcher.plan(target, item({{'s:0', 1.0, 25, 0, 0}}, false))
    assert(plain['t:2'] == nil and plain['t:0'].source == 's:0', 'no source accent: the accent keeps its color')
    -- the Salamander and the B-01 (2026-10-05): a 25% orange takes the armor's 1% yellow; a 0.3% color or a dark one
    -- is no accent
    local wide = item({{'t:0', 0.70, 30, 0, 0}, {'t:1', 0.25, 60, 37, 58}}, true)
    local small = Matcher.plan(wide, item({{'s:0', 0.99, 21, 0, 0}, {'s:1', 0.01, 65, -9, 55}}, false))
    assert(small['t:1'] and small['t:1'].kind == 'accent' and small['t:1'].source == 's:1', 'a 1% accent counts')
    local tiny = Matcher.plan(wide, item({{'s:0', 0.997, 21, 0, 0}, {'s:1', 0.003, 65, -9, 55}}, false))
    assert(tiny['t:1'] == nil, 'a 0.3% color is no accent')
    local dark = Matcher.plan(wide, item({{'s:0', 0.97, 21, 0, 0}, {'s:1', 0.03, 25, 20, 15}}, false))
    assert(dark['t:1'] == nil, 'a dark muted source color (a brown) is no accent')
    -- the CM-09 Bonesnapper armor's red trim (L 29, chroma 44): dark but vivid, it is the accent (v11.5)
    local red = Matcher.plan(wide, item({{'s:0', 0.97, 21, 0, 0}, {'s:1', 0.03, 29, 38, 21}}, false))
    assert(red['t:1'] and red['t:1'].source == 's:1', 'a vivid dark red is an accent')
end)

check('an armor\'s undersuit black goes only to dark parts; a green armor stays green (2026-10-05 reports)', function()
    -- the UF-84 Doubt Killer: glossy dark plates (L 24), an undersuit black (L 5, mostly undergarment), a red trim
    local doubt = item({{'s:0', 0.48, 24, 0, 0}, {'s:1', 0.47, 5, 1, 0, false, 0.6}, {'s:2', 0.05, 45, 64, 46}}, true)
    -- the CW-36 Winter Warrior helmet: a white shell and a dark part; v11.2 gave the shell the undersuit black
    local winter = Matcher.plan(item({{'t:0', 0.76, 69, 0, 8}, {'t:1', 0.24, 29, 0, 0}}, false), doubt)
    assert(winter['t:0'].source == 's:0', 'the white shell takes the plates, not the undersuit: '
           .. winter['t:0'].source)
    -- the RS-67 Null Cipher: a matte dark main and a glossy grey panel (L 36, not dark neutral)
    local cipher = Matcher.plan(item({{'t:0', 0.69, 22, 0, 0}, {'t:1', 0.29, 36, 0, 0}}, false), doubt)
    assert(cipher['t:1'].source == 's:0', 'the grey panel takes the plates: ' .. cipher['t:1'].source)
    -- the AD-49 Apollonian: a large dark part (17.5%, L 22) takes the plates too; only small dark parts may take it
    local apollo = Matcher.plan(item({{'t:0', 0.53, 33, -2, 7}, {'t:1', 0.18, 32, 0, 0, true}, {'t:2', 0.175, 22, 0, 0},
                                      {'t:3', 0.115, 54, 0, 4, true}}, false), doubt)
    assert(apollo['t:2'].source == 's:0', 'the large dark part takes the plates: ' .. apollo['t:2'].source)
    -- the TR-117 Alpha Commander: 48% scattered dark parts, 26% green plates, a dark green undersuit, tan pouches;
    -- the UF-50 Bloodhound helmet's red shell takes the green (dark parts weighed 0.75 made it dark grey)
    local alpha = item({{'s:0', 0.48, 24, 0, 0}, {'s:1', 0.26, 40, -11, 15}, {'s:2', 0.17, 31, -5, 5, false, 1.0},
                        {'s:3', 0.09, 57, 5, 17}}, true)
    local blood = Matcher.plan(item({{'t:0', 0.72, 31, 24, 13}, {'t:1', 0.18, 29, 0, 0}, {'t:2', 0.10, 54, 0, 4}},
                                    false), alpha)
    assert(blood['t:0'].source == 's:1', 'the red shell takes the green plates: ' .. blood['t:0'].source)
end)

check('accents of any size and pattern accents take the source accent; a pattern can be it (2026-10-05)', function()
    local YELLOW = {0.668, 0.625, 0.195} -- the common pattern texture's color (Lab 65 -9 56)
    -- the UF-84 Doubt Killer: dark plates, undersuit black, a 5% red trim
    local doubt = item({{'s:0', 0.48, 24, 0, 0}, {'s:1', 0.47, 5, 1, 0, false, 0.6}, {'s:2', 0.05, 45, 64, 46}}, true)
    -- the RS-67 Null Cipher's 0.9% yellow: below the pairing minimum, still an accent
    local cipher = Matcher.plan(item({{'t:0', 0.69, 22, 0, 0}, {'t:1', 0.30, 36, 0, 0}, {'t:2', 0.009, 63, -9, 54}},
                                     false), doubt)
    assert(cipher['t:2'] and cipher['t:2'].kind == 'accent' and cipher['t:2'].source == 's:2',
           'the small yellow takes the red')
    -- the FS-23 Battle Master: its yellow stripes are a pattern; they take the red
    local battle = item({{'t:0', 0.55, 31, 0, 0}, {'t:1', 0.45, 43, 0, 0}}, false,
                        {{pattern = 'aaaaaaaaaaaaaaaa', area = 0.13, r = YELLOW[1], g = YELLOW[2], b = YELLOW[3]},
                         {pattern = 'cccccccccccccccc', area = 0.05, r = 0.9, g = 0.9, b = 0.85}})
    local stripes = Matcher.pattern_plan(battle, doubt)
    local red = stripes.aaaaaaaaaaaaaaaa
    assert(red and red.source == 's:2' and red.L == 45 and red.a == 64 and red.b == 46,
           'the yellow pattern takes the red')
    assert(stripes.cccccccccccccccc == nil, 'a neutral pattern keeps its color')
    -- an armor whose only accent is a pattern (yellow, 2%): the pattern is its accent; a matching pattern keeps
    local b01 = item({{'s:0', 1.0, 21, 0, 0}}, true,
                     {{pattern = 'bbbbbbbbbbbbbbbb', area = 0.02, r = YELLOW[1], g = YELLOW[2], b = YELLOW[3]}})
    local salamander = Matcher.plan(item({{'t:0', 0.70, 45, 1, 1}, {'t:1', 0.30, 60, 37, 58}}, false), b01)
    assert(salamander['t:1'] and salamander['t:1'].source == 'pattern:bbbbbbbbbbbbbbbb',
           'the orange accent takes the armor\'s yellow pattern')
    assert(Matcher.pattern_plan(battle, b01).aaaaaaaaaaaaaaaa == nil,
           'a pattern that already matches the source accent keeps its color')
end)

check('the CM-09 Bonesnapper armor: cream plates are its main color, its red trim the accent (2026-10-05)', function()
    -- 56% dark parts (harness, plate backs), a green undersuit (17%, all undergarment), cream plates (16%), a vivid
    -- dark red trim (2%); v11.4 made the helmets grey (dark identity) with the cape piece's yellow as the accent
    local bonesnapper = item({{'s:0', 0.56, 24, 0, 0}, {'s:1', 0.17, 30, -12, 6, false, 1.0}, {'s:2', 0.16, 68, 1, 7},
                              {'s:3', 0.05, 61, -1, 0, true}, {'s:4', 0.02, 29, 38, 21}}, true)
    -- the I-44 Salamander: bare-metal shell, a dark part, an orange accent
    local salamander = Matcher.plan(item({{'t:0', 0.60, 45, 1, 1, true}, {'t:1', 0.28, 22, 0, 0},
                                          {'t:2', 0.10, 60, 37, 58}}, false), bonesnapper)
    assert(salamander['t:0'].source == 's:2', 'the shell takes the cream plates: ' .. salamander['t:0'].source)
    assert(salamander['t:1'].source == 's:0', 'the dark part stays dark: ' .. salamander['t:1'].source)
    assert(salamander['t:2'].kind == 'accent' and salamander['t:2'].source == 's:4', 'the orange takes the red')
    -- the DS-10 Big Game Hunter: a dark mask (70%) and a muted tan hood (26%): the hood is no accent; the cream goes
    -- to the hood, the mask stays dark
    local hunter = Matcher.plan(item({{'t:0', 0.70, 23, 1, 5}, {'t:1', 0.26, 40, 2, 30}}, false), bonesnapper)
    assert(hunter['t:1'].kind == 'pair' and hunter['t:1'].source == 's:2', 'the hood takes the cream: '
           .. hunter['t:1'].kind .. ' ' .. hunter['t:1'].source)
    assert(hunter['t:0'].source == 's:0', 'the mask stays dark: ' .. hunter['t:0'].source)
    -- a muted tan part of 26% beside a cream main is a main part, not an accent: it is paired, not made red
    local banded = Matcher.plan(item({{'t:0', 0.70, 70, 1, 7}, {'t:1', 0.26, 40, 2, 30}}, false), bonesnapper)
    assert(banded['t:1'].kind == 'pair', 'a large muted part is paired: ' .. banded['t:1'].kind)
end)

check('pattern textures: texel 0 takes the planned color in sRGB, the mask layer and controls stay', function()
    local values = ffi.new('float[12]', {0.668, 0.625, 0.195, 0, 0, 0, 0, 1, 0, 0, 0, 0.3})
    local target = {luts = {aaaaaaaaaaaaaaaa = {values = values, width = 3, height = 1}}}
    local out = Recolor.build_patterns(target, {aaaaaaaaaaaaaaaa = {L = 45, a = 64, b = 46}}, Colour)
    local spec = assert(out.aaaaaaaaaaaaaaaa, 'pattern texture built')
    local r, g, b = Colour.lab_to_srgb(45, 64, 46)
    assert(spec.width == 3 and spec.height == 1, 'size')
    for i, want in ipairs({r, g, b}) do
        assert(math.abs(spec.data[i - 1] - want) < 1e-6, 'texel 0 channel ' .. i)
    end
    for i = 3, 11 do assert(spec.data[i] == values[i], 'value ' .. i .. ' kept') end
    assert(values[0] == tonumber(ffi.new('float', 0.668)), 'the vanilla texels are untouched')
end)

check('bare metal taking paint aims for the paint\'s 0.04 white reflection more (the 2026-10-05 Salamander)', function()
    -- a neutral at lightness L with `lift` linear light added, by the CIELAB formula alone
    local function lifted(L, lift)
        return 116 * (((L + 16) / 116) ^ 3 + lift) ^ (1 / 3) - 16
    end
    local function near(got, want, what)
        assert(math.abs(got.L - want) < 1e-3 and math.abs(got.a) < 1e-3 and math.abs(got.b) < 1e-3,
               string.format('%s: L %.4f a %.4f b %.4f, expected L %.4f', what, got.L, got.a, got.b, want))
    end
    -- the Salamander's metal shell and dark paint take the B-01's dark paint (model L21)
    local helmet = item({{'t:0', 0.70, 45, 1, 1, true}, {'t:1', 0.30, 22, 0, 0}}, false)
    local plan = Matcher.plan(helmet, item({{'s:0', 1.0, 21, 0, 0}}, true))
    near(plan['t:0'], lifted(21, 0.04), 'the metal row aims for the paint plus its reflection')
    near(plan['t:1'], 21, 'the paint row takes the paint as it is')
    -- the other direction: paint takes the metal's color as it is (taking the light away turned paint black below
    -- L 23: the FS-37 Ravager helmet from the PH-202 Twigsnapper's dark bronze)
    local back = Matcher.plan(item({{'t:0', 1.0, 21, 0, 0}}, true), item({{'s:0', 1.0, 23, 0, 0, true}}, false))
    near(back['t:0'], 23, 'the paint row takes the metal color as it is')
    -- metal against metal: as it is
    local same = Matcher.plan(item({{'t:0', 1.0, 45, 0, 0, true}}, false), item({{'s:0', 1.0, 60, 0, 0, true}}, true))
    near(same['t:0'], 60, 'a metal row takes a metal color as it is')
end)

check('new LUTs fit the planned rows only and leave the vanilla data alone', function()
    local function lut(height)
        local values = ffi.new('float[?]', 23 * height * 4)
        for i = 0, 23 * height * 4 - 1 do values[i] = i end
        return {values = values, width = 23, height = height}
    end
    local target = {luts = {aaaaaaaaaaaaaaaa = lut(8)}}
    local calls, yields = {}, 0
    local transfer = {apply = function(values, width, row, L, a, b)
        calls[#calls + 1] = {row, L, a, b}
        values[row * width * 4] = -1
        return 0
    end}
    local plan = {['aaaaaaaaaaaaaaaa:2'] = {source = 'bbbbbbbbbbbbbbbb:3', kind = 'pair', L = 40, a = 1, b = 2}}
    local out = Recolor.build_luts(target, plan, transfer, function() yields = yields + 1 end)
    assert(#calls == 1 and calls[1][1] == 2 and calls[1][2] == 40 and calls[1][4] == 2 and yields == 1, 'one fit')
    local data = out.aaaaaaaaaaaaaaaa.data
    for i = 0, 23 * 8 * 4 - 1 do
        assert(data[i] == (i == 2 * 92 and -1 or i), 'value ' .. i)
        assert(target.luts.aaaaaaaaaaaaaaaa.values[i] == i, 'vanilla value ' .. i)
    end
end)

-- Matcher v12: measured items (the Armory front view's screen pixels and each row's measured response). A row of
-- {key, texture area, model L, a, b, screen pixels[, bare metal[, undergarment fraction[, cal[, light]]]]} gets the
-- albedo of its model color, so a row with cal = {1, 1, 1, 0, 0, 0} looks as its model color; light (pixels x mean
-- screen luminance) defaults to pixels x the luminance of that color; look: the kit's appearance entry.
local function measured(rows, armor, patterns)
    local out, kit, cals = {}, {luts = {}, rows = {}, patterns = {}}, {}
    for i, r in ipairs(rows) do
        local lut, row = r[1]:match('^(%w+):(%d+)$')
        local ar, ag, ab = Colour.lab_to_linear(r[3], r[4], r[5])
        out[i] = {key = r[1], lut = lut, row = tonumber(row), area = r[2], under = r[2] * (r[8] or 0), L = r[3],
                  a = r[4], b = r[5], metal = r[7] == true, camo = false, mode = 0, full = r[7] == true, ar = ar,
                  ag = ag, ab = ab}
        kit.luts[lut] = true
        local _, y = Colour.lab_to_linear(r[3], r[4], r[5]) -- the green channel stands in for luminance
        if r[6] > 0 then kit.rows[r[1]] = {r[6], r[10] or math.floor(r[6] * y + 0.5)} end
        cals[r[1]] = r[9] or {1, 1, 1, 0, 0, 0}
    end
    local look = {kit = kit, row = function(lut, row) return cals[lut .. ':' .. row] end}
    return Matcher.item(out, armor, patterns, look), Matcher.item(out, armor, patterns)
end

check('v12: a dark armor with a light main part showing more light reads as that part (SR-64 Cinderblock)', function()
    -- screen: dark plates and straps 72% (L 21), light chest plate and shoulders 19% (L 43); the light part shows
    -- more light (pixels x screen luminance), so helmets take the light grey, not the straps (user 2026-10-05)
    local rows = {{'c:0', 0.66, 21, 0, 0, 7170, false, 0.05, nil, 8565}, {'c:1', 0.15, 43, 0, 0, 1880, false, 0, nil,
                  12847}}
    local cinder = measured(rows, true)
    local salamander = measured({{'t:0', 0.6, 45, 1, 1, 7750, true}, {'t:1', 0.3, 22, 0, 0, 1460}}, false)
    local plan = Matcher.plan(salamander, cinder)
    assert(plan['t:0'].source == 'c:1', 'the light shell takes the light plates: ' .. plan['t:0'].source)
    assert(plan['t:1'].source == 'c:0', 'the dark part takes the dark color: ' .. plan['t:1'].source)
    -- a one-part helmet takes the identity itself
    local plain = measured({{'t:0', 1.0, 40, 0, 0, 9000}}, false)
    assert(Matcher.plan(plain, cinder)['t:0'].source == 'c:1', 'the identity is the light part')
    rows[2][10] = 4000 -- the light part shows less light than the dark one: the dark one stays the identity
    assert(Matcher.plan(plain, measured(rows, true))['t:0'].source == 'c:0', 'dark identity kept')
    rows[2][6], rows[2][10] = 1100, 12847 -- a light part under LARGE_AREA (11%) is no identity
    assert(Matcher.plan(plain, measured(rows, true))['t:0'].source == 'c:0', 'small light part')
end)

check('v12: the helmet\'s main part takes the identity, not a smaller part that already matches it', function()
    -- the FS-23 Battle Master from the SR-64 Cinderblock (identity: its light plates, 19%; 72% dark): the shell (L 33,
    -- a medium grey, not dark, just over the match distance from L 43) takes the light grey; its light part (L 47),
    -- which already matches the light grey, does not anchor it
    local cinder = measured({{'c:0', 0.66, 21, 0, 0, 7170, false, 0.05, nil, 8565},
                             {'c:1', 0.15, 43, 0, 0, 1880, false, 0, nil, 12847}}, true)
    local battle = measured({{'t:0', 0.6, 33, 0, 0, 5840}, {'t:1', 0.2, 47, 0, 0, 1990}}, false)
    local plan = Matcher.plan(battle, cinder)
    assert(plan['t:0'].source == 'c:1', 'the main shell takes the light identity: ' .. plan['t:0'].source)
end)

check('v12: a part that already matches a main source color keeps it (no black crest, 2026-10-05)', function()
    -- the FS-23 Battle Master's light crest (L 47) already matches the SR-64 Cinderblock's light plates (L 43, a main
    -- color); mirroring the armor's 72% dark had turned it black
    local cinder = measured({{'c:0', 0.66, 21, 0, 0, 7170, false, 0.05, nil, 8565},
                             {'c:1', 0.15, 43, 0, 0, 1880, false, 0, nil, 12847}}, true)
    local battle = measured({{'t:0', 0.6, 33, 0, 0, 5840}, {'t:1', 0.2, 47, 0, 0, 1990}}, false)
    assert(Matcher.plan(battle, cinder)['t:1'].source == 'c:1', 'the light crest stays light')
    -- a match to a minor source color (under MAIN_COLOR) does not hold: the DS-191 Scorpion's beige suit goes dark
    local cap = measured({{'s:0', 0.8, 20, 0, 0, 9000}, {'s:1', 0.05, 56, 0, 3, 470}}, false)
    local scorpion = measured({{'t:0', 0.4, 26, 0, 0, 2180}, {'t:1', 0.4, 56, 3, 10, 3800}}, true)
    assert(Matcher.plan(scorpion, cap)['t:1'].source == 's:0', 'a minor color match does not hold')
end)

check('v12: a measured armor\'s small visible emblem is its accent (the SR-64 Cinderblock\'s orange, 2026-10-05)', function()
    -- 0.12% of its pixels, below v11.5's 0.5% texture floor
    local rows = {{'c:0', 0.8, 21, 0, 0, 7170}, {'c:1', 0.2, 43, 0, 0, 1880}, {'c:2', 0.0005, 54, 35, 50, 11}}
    local cinder, cinder_texture = measured(rows, true)
    local salamander = measured({{'t:0', 0.8, 45, 1, 1, 7750, true}, {'t:1', 0.07, 60, 37, 58, 730}}, false)
    local plan = Matcher.plan(salamander, cinder)
    assert(plan['t:1'] and plan['t:1'].kind == 'accent' and plan['t:1'].source == 'c:2', 'the orange takes the emblem')
    assert(Matcher.plan(salamander, cinder_texture)['t:1'] == nil, 'on texture shares (0.05%) there is no accent')
end)

check('v12: a row the Armory never shows is no accent (the SR-64 Cinderblock\'s lime, 2026-10-05)', function()
    -- texture: lime 1.6% (vivid, the most salient accent); screen: never seen
    local cinder, cinder_texture = measured({{'c:0', 0.66, 23, 0, 0, 715}, {'c:1', 0.15, 33, 0, 0, 190},
                                             {'c:2', 0.016, 87, -86, 83, 0}}, true)
    local salamander = Matcher.item({{key = 't:0', lut = 't', row = 0, area = 0.6, under = 0, L = 45, a = 1, b = 1,
                                      metal = true, camo = false, mode = 0, full = true},
                                     {key = 't:1', lut = 't', row = 1, area = 0.1, under = 0, L = 60, a = 37, b = 58,
                                      metal = false, camo = false, mode = 0, full = false}}, false)
    assert(cinder.measured and not cinder_texture.measured, 'measured with its look')
    assert(Matcher.plan(salamander, cinder)['t:1'] == nil, 'the orange keeps its color: no source accent')
    local mutant = Matcher.plan(salamander, cinder_texture)['t:1']
    assert(mutant and mutant.source == 'c:2', 'on texture shares the lime is the accent (v11.5)')
end)

check('v12: the I-92 Fire Fighter\'s identity is its grey, not its tan padding (2026-10-05)', function()
    -- screen: grey plates 42.6% (dark neutral, partly undersuit), blue coat 20.8% (undersuit), brown 12.6%, tan 4.8%;
    -- texture: grey 27%, blue 18%, brown 8%, tan 11%
    local rows = {{'f:0', 0.27, 26, 0, 0, 4260, false, 0.43}, {'f:1', 0.18, 32, -1, -12, 2080, false, 1.0},
                  {'f:2', 0.08, 12, 5, 17, 1260, false, 0.67}, {'f:3', 0.11, 48, 8, 17, 480}}
    local fire, fire_texture = measured(rows, true)
    local salamander = Matcher.item({{key = 't:0', lut = 't', row = 0, area = 0.8, under = 0, L = 45, a = 1, b = 1,
                                      metal = true, camo = false, mode = 0, full = true}}, false)
    assert(Matcher.plan(salamander, fire)['t:0'].source == 'f:0', 'the shell takes the grey')
    assert(Matcher.plan(salamander, fire_texture)['t:0'].source == 'f:3', 'on texture shares: the tan (v11.5)')
end)

check('v12: a part takes the source\'s look, without the paint-reflection lift (Doubt Killer greys, 2026-10-05)', function()
    -- the plates look as their model color (L 24); the Salamander's metal shell (model L 45) looks L 34
    local doubt, doubt_texture = measured({{'d:0', 0.47, 24, 0, 0, 4640}, {'d:1', 0.48, 5, 1, 0, 5170, false, 0.83}},
                                          true)
    local shell = {0.5, 0.5, 0.5, 0, 0, 0} -- s + g x albedo: half the light of the model color
    local salamander, salamander_texture = measured({{'t:0', 0.6, 45, 1, 1, 9000, true, 0, shell}}, false)
    local r, g, b = Colour.lab_to_linear(45, 1, 1)
    assert(math.abs(salamander.groups[1].L - Colour.linear_to_lab(r * 0.5, g * 0.5, b * 0.5)) < 1e-9,
           'the shell looks as its response says')
    local goal = Matcher.plan(salamander, doubt)['t:0']
    assert(goal.source == 'd:0' and math.abs(goal.L - 24) < 1e-4 and goal.cal == shell,
           'the plates as they look, fitted through the shell\'s response: L ' .. goal.L)
    local lifted = Matcher.plan(salamander_texture, doubt_texture)['t:0']
    assert(lifted.L > 30 and lifted.cal == nil, 'unmeasured bare metal keeps the v11.2 lift: L ' .. lifted.L)
end)

check('v12: rows of one model color stay one group, colored by their pixels', function()
    local item = measured({{'s:0', 0.5, 45, 0, 0, 3000, true, 0, {0.6, 0.6, 0.6, 0, 0, 0}},
                           {'s:1', 0.5, 45, 0, 0, 1000, true, 0, {0.3, 0.3, 0.3, 0, 0, 0}}}, false)
    assert(#item.groups == 1, 'one group: ' .. #item.groups)
    local r, g, b = Colour.lab_to_linear(45, 0, 0)
    local k = (3000 * 0.6 + 1000 * 0.3) / 4000
    local want = Colour.linear_to_lab(r * k, g * k, b * k)
    assert(math.abs(item.groups[1].L - want) < 1e-6 and item.groups[1].mL == 45, 'pixel-weighted look, model class')
end)

check('v12: the fit goes through the row\'s response; a reflection floor bounds how dark it can look', function()
    local transfer = Transfer.new(Colour, flat_model())
    local floor = {1, 1, 1, 0.07, 0.07, 0.07}
    local _, _, _, err = transfer.fit(test_row(), 25, 0, 0, floor)
    local L = transfer.fit(test_row(), 25, 0, 0, floor)
    assert(err > 5 and L > 30, 'black paint still reflects 7%: L ' .. L)
    local _, _, _, free = transfer.fit(test_row(), 25, 0, 0, {1, 1, 1, 0, 0, 0})
    assert(free < Transfer.FIT_DONE, 'no floor: reached, dE ' .. free)
end)

check('v12: a measured pattern\'s texel is the desired color through its gain', function()
    local r, g, b = Recolor.pattern_texel({L = 54, a = 41, b = 15, gain = {0.5, 0.6, 0.7}}, Colour)
    local lr, lg, lb = Colour.lab_to_linear(54, 41, 15)
    for i, v in ipairs({{r, lr / 0.5}, {g, lg / 0.6}, {b, lb / 0.7}}) do
        assert(math.abs(v[1] - Colour.linear_to_srgb(v[2])) < 1e-12, 'channel ' .. i)
    end
    local pr, pg, pb = Recolor.pattern_texel({L = 54, a = 41, b = 15}, Colour)
    local er, eg, eb = Colour.lab_to_srgb(54, 41, 15)
    assert(pr == er and pg == eg and pb == eb, 'unmeasured: the desired color itself')
end)

print('PASS test_units (' .. passed .. ' checks)')
