-- Match Your Colors: the Lua port against the research pipeline, on the installed game's files.
--
-- tests/fixtures/ (scripts/make_fixtures.py) holds the research pipeline's float64 results on the runtime data
-- scope: the shared tiler samples, every helmet's and armor's rows and patterns (stocky body), an Adler-32 of every
-- v12 plan and pattern plan and the fitted colors of a sample of plans. This test reads the same game files through
-- src/slim.lua and src/texture.lua, builds the rows and patterns with src/kits.lua and src/colour.lua, the plans with
-- src/matcher.lua over the measured appearance (src/appearance.lua, src/appearance_data.lua) and the colors with
-- src/transfer.lua, and compares. Skipped (PASS, with a note) when the game's
-- data folder is missing; HD2_GAME_ROOT names a nonstandard install.
-- Usage: luajit tests/test_parity.lua <repository root> [kit limit]
local root = assert(arg and arg[1], 'usage: test_parity.lua <repository root> [kit limit]')
local limit = tonumber(arg[2])
package.path = root .. '/src/?.lua;' .. package.path
local Files, Slim, Texture = require('files'), require('slim'), require('texture')
local Colour, Matcher, Kits, Transfer = require('colour'), require('matcher'), require('kits'), require('transfer')
local Recolor = require('recolor')
local appearance = require('appearance').new(require('appearance_data'))
Matcher.use(Colour)
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local clock = dofile(root .. '/src/bingus_memory.lua').new(runtime).time

local game_root = os.getenv('HD2_GAME_ROOT') or 'C:/Program Files (x86)/Steam/steamapps/common/Helldivers 2'
local probe = io.open(game_root .. '/data/bundles.nxa', 'rb')
if not probe then
    print('PASS test_parity (skipped: no game data at ' .. game_root .. ')')
    return
end
probe:close()

local fixture = function(name) return dofile(root .. '/tests/fixtures/' .. name .. '.lua') end
local KITS, SHARED, ROWS, PLANS = fixture('kits'), fixture('shared'), fixture('rows'), fixture('plans')
local TRANSFERS, PATTERNS, PATTERN_PLANS = fixture('transfers'), fixture('patterns'), fixture('pattern_plans')
local passed, started = 0, clock()
local function check(name, fn)
    fn()
    passed = passed + 1
end

local slim = Slim.open(Files.new(game_root .. '/data/'), '')
local scratch, big = Slim.grower(65536), Slim.grower(1048576)
local samples

check('shared samples equal the reference bytes (BC7 detail tiler, RGBA8 camo tiler)', function()
    samples = assert(Kits.shared_samples(slim, Texture, scratch), 'shared archive with the tilers')
    for name, layers in pairs({detail = 26, camo = 5}) do
        assert(samples[name .. '_layers'] == layers, name .. ' layers')
        for l = 0, layers - 1 do
            local expected = SHARED[name][l + 1]
            local values = samples[name][l]
            for i = 0, 512 * 4 - 1 do
                local byte = tonumber(expected:sub(2 * i + 1, 2 * i + 2), 16)
                local got = math.floor(values[i] * 255 + 0.5)
                assert(got == byte, string.format('%s layer %d value %d: %d, expected %d', name, l, i, got, byte))
            end
        end
    end
end)

local colour = Colour.new(samples.detail, samples.detail_layers, samples.camo, samples.camo_layers)
local function yield() end
-- One texture loader for the session (LUTs and coverages are cached by resource name); find searches the
-- current kit's archive, then the shared one.
local deps = {slim = slim, texture = Texture, scratch = scratch, big_scratch = big, yield = yield, colour = colour}
deps.textures = Kits.textures(deps)

-- One kit's analysis (stocky body).
local function analyse(kit)
    local archives = {kit.archive, samples.archive}
    deps.find = function(name, kind)
        for _, archive in ipairs(archives) do
            local record = slim.locate(archive, name, kind)
            if record then return archive, record end
        end
        return nil
    end
    return Kits.analyse(kit, 0, deps)
end

local function close(a, b, tolerance, what)
    local scale = math.max(1, math.abs(a), math.abs(b))
    assert(math.abs(a - b) <= tolerance * scale, string.format('%s: %.17g vs %.17g', what, a, b))
end

local analyses = {}
-- With a limit: the first `limit` helmets and armors in catalogue order (the fixture's first plans).
local kit_list, counts = {}, {Helmet = 0, Armor = 0}
for _, kit in ipairs(KITS) do
    counts[kit.kit_type] = counts[kit.kit_type] + 1
    if not limit or counts[kit.kit_type] <= limit then kit_list[#kit_list + 1] = kit end
end

check('every kit\'s rows equal the reference (keys in order, areas, Lab, flags, mean albedo)', function()
    for _, kit in ipairs(kit_list) do
        local got = analyse(kit)
        analyses[kit.id] = got
        local expected = ROWS[kit.id]
        assert(#got.rows == #expected, string.format('%s (%s): %d rows, expected %d', kit.name, kit.id, #got.rows, #expected))
        for r, row in ipairs(got.rows) do
            local e = expected[r]
            local what = kit.name .. ' ' .. row.key
            assert(row.key == e[1], what .. ' key order: expected ' .. e[1])
            close(row.area, e[2], 1e-9, what .. ' area')
            close(row.under, e[3], 1e-9, what .. ' under')
            close(row.L, e[4], 1e-7, what .. ' L')
            close(row.a, e[5], 1e-7, what .. ' a')
            close(row.b, e[6], 1e-7, what .. ' b')
            assert(row.metal == e[7] and row.camo == e[8] and row.mode == e[9] and row.full == e[10], what .. ' flags')
            close(row.ar, e[11], 1e-9, what .. ' albedo r')
            close(row.ag, e[12], 1e-9, what .. ' albedo g')
            close(row.ab, e[13], 1e-9, what .. ' albedo b')
        end
        local want = PATTERNS[kit.id] or {}
        assert(#got.patterns == #want, string.format('%s (%s): %d patterns, expected %d', kit.name, kit.id,
                                                     #got.patterns, #want))
        for i, pattern in ipairs(got.patterns) do
            assert(pattern.pattern == want[i][1], kit.name .. ' pattern order: expected ' .. want[i][1])
            close(pattern.area, want[i][2], 1e-9, kit.name .. ' pattern ' .. pattern.pattern .. ' area')
        end
    end
end)
local analysed = clock()

-- Adler-32 of a string.
local function adler32(text)
    local a, b = 1, 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

-- Every analysed kit as a matcher item, patterns and measured appearance included.
local measured = 0
local function items_of()
    local items = {}
    measured = 0
    for id, a in pairs(analyses) do
        items[id] = Matcher.item(a.rows, a.kit.kit_type == 'Armor', Recolor.patterns_of(a), Recolor.look_of(a, appearance))
        if items[id].measured then measured = measured + 1 end
    end
    return items
end

local plans, mismatches = 0, {}
check('plans equal the reference for every analysed pair, both directions', function()
    local items = items_of()
    for key, expected in pairs(PLANS) do
        local direction, t, s = key:sub(1, 1), key:sub(2, 9), key:sub(10, 17)
        if items[t] and items[s] then
            local mapping = Matcher.plan(items[t], items[s])
            local keys = {}
            for k in pairs(mapping) do keys[#keys + 1] = k end
            table.sort(keys)
            local parts = {}
            for i, k in ipairs(keys) do parts[i] = k .. '=' .. (mapping[k].kind == 'accent' and '~' or '') .. mapping[k].source end
            plans = plans + 1
            if adler32(table.concat(parts, ';')) ~= expected then mismatches[#mismatches + 1] = key end
        end
    end
    assert(#mismatches == 0, #mismatches .. ' plans differ, first ' .. tostring(mismatches[1]))
end)

local pattern_plans = 0
check('pattern plans equal the reference for every analysed pair, both directions', function()
    local items, differ = items_of(), {}
    for key in pairs(PLANS) do
        local t, s = key:sub(2, 9), key:sub(10, 17)
        if items[t] and items[s] then
            local plan = Matcher.pattern_plan(items[t], items[s])
            local names = {}
            for name in pairs(plan) do names[#names + 1] = name end
            table.sort(names)
            local parts = {}
            for i, name in ipairs(names) do parts[i] = name .. '=' .. plan[name].source end
            local expected = PATTERN_PLANS[key]
            if #names > 0 then pattern_plans = pattern_plans + 1 end
            if (#names == 0 and expected ~= nil) or (#names > 0 and adler32(table.concat(parts, ';')) ~= expected) then
                differ[#differ + 1] = key
            end
        end
    end
    assert(#differ == 0, #differ .. ' pattern plans differ, first ' .. tostring(differ[1]))
end)

-- Every pair the user reported on 2026-10-05 (playtest, Armory sheets, real play), with the look agreed for it:
-- {target kit, source kit, why, {{target color, source color | 'keep', kind[, {lo, hi}]}}, {[pattern] = source
-- color} or false (no pattern plan)}. Colors are rounded CIELAB as matcher v12 sees them (perceived on the Armory
-- front view); a group (or pattern) is the one within CIEDE2000 2, the closest when several. {lo, hi}: the range of
-- the desired lightness of the group's first row (how light the recolored part looks).
local REPORTED = {
    {'0ade6719', '677bee02', 'Scorpion armor <- Parade Commander: the beige suit is no gold suit',
     {{{56, 4, 12}, {20, 0, 0}, 'pair'}}},
    {'30e54b57', '289884f4', 'Honorary Guard armor <- Obedient: dark (its material kept), its gold trim kept',
     {{{23, 0, 0}, {24, 0, 0}, 'pair', {15, 30}}, {{75, 8, 39}, 'keep'}}},
    {'b3550d20', '289884f4', 'Bloodhound armor <- Obedient: the red goes dark grey, never brown or pale',
     {{{21, 20, 11}, {24, 0, 0}, 'pair', {15, 30}}, {{21, 0, 0}, {24, 0, 0}, 'pair'}}},
    {'24fdb2c0', 'b3550d20', 'Lawmaker <- Bloodhound armor: the shell takes the maroon',
     {{{42, -2, -4}, {21, 20, 11}, 'pair'}}},
    {'d0ce5bc7', '4f7fb2bd', 'Salamander <- B-01: dark shell, the orange takes the yellow',
     {{{34, 1, 1}, {23, 0, 0}, 'pair'}, {{48, 32, 49}, {58, -10, 54}, 'accent'}}},
    {'c25abb74', '4f7fb2bd', 'Bonesnapper helmet <- B-01: dark, the red jaw takes the yellow',
     {{{62, 2, 8}, {23, 0, 0}, 'pair'}, {{21, 31, 18}, {58, -10, 54}, 'accent'}}},
    {'58716e11', '2521d401', 'Null Cipher <- Doubt Killer: the plates, never the undersuit black; marks red',
     {{{27, 1, 0}, {20, 0, 0}, 'pair'}, {{29, 0, -2}, {20, 0, 0}, 'pair'}, {{64, -9, 54}, {40, 59, 43}, 'accent'}}},
    {'cd3d20dc', '2521d401', 'Winter Warrior <- Doubt Killer: the white shell takes the plates, not black',
     {{{59, 0, 6}, {20, 0, 0}, 'pair'}}},
    {'1e9444f9', '2521d401', 'Battle Master <- Doubt Killer: the yellow stripes (a pattern) turn red',
     {{{34, 0, -1}, {20, 0, 0}, 'pair'}}, {f18dfbb5346732c1 = {40, 59, 43}}},
    {'0e3b10bf', '9f73133e', 'Bloodhound helmet <- Alpha Commander: green, not black',
     {{{21, 20, 11}, {32, -9, 12}, 'pair'}}},
    {'d0ce5bc7', '1c6c05fa', 'Salamander <- Bonesnapper armor: cream shell, dark part dark, the orange red',
     {{{34, 1, 1}, {58, 2, 8}, 'pair'}, {{26, 0, -1}, {22, 0, 0}, 'pair'}, {{48, 32, 49}, {23, 30, 17}, 'accent'}}},
    {'52791e64', '1c6c05fa', 'DS-10 Big Game Hunter <- Bonesnapper armor: cream hood (no yellow), dark mask',
     {{{40, 2, 31}, {58, 2, 8}, 'pair'}, {{23, 1, 2}, {22, 0, 0}, 'pair'}}},
    -- v11.5 (user, 2026-10-05): the greys looked too bright, the padding took the whole shell, a bright lime came in;
    -- v12 reviews: the Doubt Killer's glossy red accent read coral (its gloss counted): red without it; the
    -- Cinderblock's helmets far darker than the armor (its light plates are its identity); the Obedient made armors
    -- pale (its hood's sheen counted as paint)
    {'d0ce5bc7', '2521d401', 'Salamander <- Doubt Killer: the shell as dark as the plates look, the orange red',
     {{{34, 1, 1}, {20, 0, 0}, 'pair', {15, 30}}, {{26, 0, -1}, {20, 0, 0}, 'pair'},
      {{48, 32, 49}, {40, 59, 43}, 'accent'}}},
    {'d0ce5bc7', '8c83c789', 'Salamander <- I-92 Fire Fighter: the grey plates, never the tan padding',
     {{{34, 1, 1}, {29, 0, 0}, 'pair', {28, 40}}, {{26, 0, -1}, {29, 0, 0}, 'pair'}, {{48, 32, 49}, 'keep'}}},
    {'d0ce5bc7', '5096bce9', 'Salamander <- SR-64 Cinderblock: light grey like its plates, its emblem\'s orange, no lime',
     {{{34, 1, 1}, {43, -1, -1}, 'pair', {38, 55}}, {{26, 0, -1}, {21, 1, 1}, 'pair'},
      {{48, 32, 49}, {49, 17, 41}, 'accent'}}, false},
    {'1e9444f9', '5096bce9', 'Battle Master <- SR-64 Cinderblock: light grey, no black crest, orange stripes, no lime',
     {{{34, 0, -1}, {43, -1, -1}, 'pair', {38, 55}}, {{47, 0, 1}, {43, -1, -1}, 'pair', {38, 55}}},
     {f18dfbb5346732c1 = {49, 17, 41}}},
}

-- The group or pattern of `item` closest to `lab` within CIEDE2000 2, or nil.
local function near(item, lab)
    local best, pick = 2, nil
    for i = 1, #item.groups + #item.patterns do
        local g = item.groups[i] or item.patterns[i - #item.groups]
        local d = Colour.de2000(g.L, g.a, g.b, lab[1], lab[2], lab[3])
        if d < best then best, pick = d, g end
    end
    return pick
end

local reported = 0
-- One reported pair against its agreed look (t, s: matcher items).
local function check_reported(case, t, s, why)
    local plan, patterns = Matcher.plan(t, s), Matcher.pattern_plan(t, s)
    for _, e in ipairs(case[4]) do
        local g = assert(near(t, e[1]), why .. ': target color ' .. table.concat(e[1], ' '))
        local m = plan[g.rows[1].key]
        if e[2] == 'keep' then
            assert(m == nil, why .. ': ' .. table.concat(e[1], ' ') .. ' keeps its color')
        else
            local src = assert(near(s, e[2]), why .. ': source color ' .. table.concat(e[2], ' '))
            assert(m and m.source == src.rep.key and m.kind == e[3], string.format('%s: %s takes %s (%s), got %s',
                   why, table.concat(e[1], ' '), table.concat(e[2], ' '), e[3], m and (m.kind .. ' ' .. m.source)
                   or 'nothing'))
            local range = e[4]
            if range then
                assert(m.L >= range[1] and m.L <= range[2], string.format('%s: %s looks L %.1f, expected %d to %d', why,
                       table.concat(e[1], ' '), m.L, range[1], range[2]))
            end
        end
    end
    if case[5] == false then
        assert(next(patterns) == nil, why .. ': no pattern changes')
    end
    for pattern, lab in pairs(case[5] or {}) do
        local got = patterns[pattern]
        assert(got and Colour.de2000(got.L, got.a, got.b, lab[1], lab[2], lab[3]) < 2,
               why .. ': pattern ' .. pattern .. ' takes ' .. table.concat(lab, ' '))
    end
    reported = reported + 1
end

check('every pair the user reported plans the agreed look (2026-10-05)', function()
    local items = items_of()
    for _, case in ipairs(REPORTED) do
        local t, s, why = items[case[1]], items[case[2]], case[3]
        assert((t and s) or limit, why .. ': kits analysed') -- a kit limit (quick runs) may leave them out
        if t and s then check_reported(case, t, s, why) end
    end
end)

-- The desired colors of a sample of plans and the colors fitted to them (on the analysed LUT rows).
local fitted = 0
check('desired and fitted colors equal the reference for a sample of plans', function()
    local transfer = Transfer.new(Colour, colour)
    local items = items_of()
    for key, cases in pairs(TRANSFERS) do
        local t, s = key:sub(2, 9), key:sub(10, 17)
        if items[t] and items[s] then
            local mapping = Matcher.plan(items[t], items[s])
            for _, case in ipairs(cases) do
                local goal = assert(mapping[case.key], key .. ' ' .. case.key .. ' planned')
                for _, f in ipairs({'L', 'a', 'b'}) do close(goal[f], case[f], 1e-7, key .. ' ' .. case.key .. ' desired ' .. f) end
                local lut, row = case.key:match('^(%x+):(%d+)$')
                local spec = analyses[t].luts[lut]
                local c = Colour.row_values(spec.values, spec.width, tonumber(row))
                local cal = case.cal and assert(appearance.row(lut, tonumber(row)), case.key .. ' measured') or nil
                assert(cal ~= nil == (goal.cal ~= nil), key .. ' ' .. case.key .. ' calibration in the plan')
                local _, _, _, err = transfer.fit(c, case.L, case.a, case.b, cal)
                close(err, case.err, 1e-6, key .. ' ' .. case.key .. ' error')
                for k, column in ipairs(Transfer.COLUMNS) do
                    for ch = 0, 2 do
                        close(c[column * 4 + ch + 1], case.colors[(k - 1) * 3 + ch + 1], 1e-7,
                              key .. ' ' .. case.key .. ' column ' .. column)
                    end
                end
                fitted = fitted + 1
            end
        end
    end
end)

print(string.format('PASS test_parity (%d checks; %d kits analysed (%d measured) in %.2f s, %d plans (%d with '
    .. 'patterns), %d reported pairs and %d fitted rows in %.2f s; %d chunk decodes)', passed, #kit_list, measured,
    analysed - started, plans, pattern_plans, reported, fitted, clock() - analysed, slim.scratch.decodes))
