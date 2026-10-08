-- Match Your Colors: the Lua port against the research pipeline, on the installed game's files.
--
-- tests/fixtures/ (scripts/make_fixtures.py) holds the research pipeline's float64 results on the runtime data
-- scope: the shared tiler samples, every helmet's and armor's rows and patterns (stocky body), an Adler-32 of every
-- v12 plan and pattern plan and the fitted colors of a sample of plans, and for the v1.3 options the plans of the
-- hooded helmets with their hoods kept (Recolor Hoods off), the rows Match Materials paints and the fitted colors of a
-- sample of them. This test reads the same game files through
-- src/slim.lua and src/texture.lua, builds the rows and patterns with src/kits.lua and src/colour.lua, the plans with
-- src/matcher.lua over the measured appearance (src/appearance.lua, src/appearance_data.lua) and the colors with
-- src/transfer.lua, and compares. Skipped (PASS, with a note) when the game's
-- data folder is missing; HD2_GAME_ROOT names a nonstandard install.
-- Usage: luajit tests/test_parity.lua <repository root> [kit limit]
local root = assert(arg and arg[1], 'usage: test_parity.lua <repository root> [kit limit]')
local limit = tonumber(arg[2])
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Files, Slim, Texture = require('files'), require('slim'), require('texture')
local Colour, Matcher, Kits, Transfer = require('colour'), require('matcher'), require('kits'), require('transfer')
local Recolor, Capes = require('recolor'), require('capes')
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
local PLANS_HOODS, MATERIALS, MATERIAL_TRANSFERS = fixture('plans_hoods'), fixture('materials'),
    fixture('material_transfers')
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

check('every kit\'s rows equal the reference (keys in order, areas, Lab, flags, mean albedo, emissive)', function()
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
            close(row.emissive, e[14], 1e-9, what .. ' emissive')
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

-- Every analysed kit as a matcher item, patterns and measured appearance included. keep_hoods: Recolor Hoods off
-- (the hooded helmets' hood rows kept).
local measured = 0
local function items_of(keep_hoods)
    local items = {}
    measured = 0
    for id, a in pairs(analyses) do
        items[id] = Matcher.item(a.rows, a.kit.kit_type == 'Armor', Recolor.patterns_of(a), Recolor.look_of(a, appearance),
                                 keep_hoods)
        if items[id].measured then measured = measured + 1 end
    end
    return items
end

-- A plan as tests/fixtures/plans.lua hashes it: 'target row=[~]source row;...' in key order (~: an accent).
local function plan_text(mapping)
    local keys = {}
    for k in pairs(mapping) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. '=' .. (mapping[k].kind == 'accent' and '~' or '') .. mapping[k].source end
    return table.concat(parts, ';')
end

local plans, mismatches = 0, {}
check('plans equal the reference for every analysed pair, both directions', function()
    local items = items_of()
    for key, expected in pairs(PLANS) do
        local t, s = key:sub(2, 9), key:sub(10, 17)
        if items[t] and items[s] then
            plans = plans + 1
            if adler32(plan_text(Matcher.plan(items[t], items[s]))) ~= expected then mismatches[#mismatches + 1] = key end
        end
    end
    assert(#mismatches == 0, #mismatches .. ' plans differ, first ' .. tostring(mismatches[1]))
end)

local hood_plans = 0
check('Recolor Hoods off: the hooded helmets\' plans equal the reference, hood rows never planned', function()
    local items, kept, differ = items_of(), items_of(true), {}
    for key, expected in pairs(PLANS_HOODS) do
        local t, s = key:sub(2, 9), key:sub(10, 17)
        if kept[t] and items[s] then
            local mapping = Matcher.plan(kept[t], items[s])
            local hoods = assert(appearance.hoods(t), t .. ' has hood rows')
            for row in pairs(hoods) do assert(mapping[row] == nil, key .. ': hood row ' .. row .. ' planned') end
            hood_plans = hood_plans + 1
            if adler32(plan_text(mapping)) ~= expected then differ[#differ + 1] = key end
        end
    end
    assert(#differ == 0, #differ .. ' hood-kept plans differ, first ' .. tostring(differ[1]))
    local sampled = 0 -- every 10th plan of a helmet without hood rows: the option changes nothing
    for key, expected in pairs(PLANS) do
        local t, s = key:sub(2, 9), key:sub(10, 17)
        if kept[t] and items[s] and key:sub(1, 1) == 'h' and not appearance.hoods(t) then
            sampled = sampled + 1
            if sampled % 10 == 0 then
                assert(adler32(plan_text(Matcher.plan(kept[t], items[s]))) == expected, key .. ': no hood, no change')
            end
        end
    end
end)

-- The rows a Match Materials plan paints: 'target row=finish source row;...' in key order.
local function finish_text(mapping)
    local keys = {}
    for k, goal in pairs(mapping) do if goal.finish then keys[#keys + 1] = k end end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. '=' .. mapping[k].finish end
    return table.concat(parts, ';'), #keys
end

local painting = 0
check('Match Materials: the rows painted equal the reference for every target (all kits only)', function()
    if limit then return end -- a target's sum covers every source
    local items, sums = items_of(), {}
    for _, direction in ipairs({'h', 'a'}) do
        for _, target in ipairs(kit_list) do
            if (target.kit_type == 'Helmet') == (direction == 'h') then
                local parts = {}
                for _, source in ipairs(kit_list) do
                    if source.kit_type ~= target.kit_type then
                        local text, count = finish_text(Matcher.plan(items[target.id], items[source.id], true))
                        if count > 0 then parts[#parts + 1] = source.id .. ':' .. text end
                    end
                end
                if #parts > 0 then
                    sums[direction .. target.id] = adler32(table.concat(parts, '|'))
                    painting = painting + #parts
                end
            end
        end
    end
    for key, expected in pairs(MATERIALS) do assert(sums[key] == expected, key .. ': painted rows differ') end
    for key in pairs(sums) do assert(MATERIALS[key], key .. ': paints rows the reference does not') end
end)

local painted_rows = 0
check('Match Materials: painted rows take their source row\'s finish and the reference\'s fitted colors', function()
    local transfer = Transfer.new(Colour, colour)
    local items = items_of()
    for key, cases in pairs(MATERIAL_TRANSFERS) do
        local t, s = key:sub(2, 9), key:sub(10, 17)
        if items[t] and items[s] then
            local mapping = Matcher.plan(items[t], items[s], true)
            for _, case in ipairs(cases) do
                local goal = assert(mapping[case.key], key .. ' ' .. case.key .. ' planned')
                assert(goal.finish == case.finish, key .. ' ' .. case.key .. ' finish ' .. tostring(goal.finish))
                for _, f in ipairs({'L', 'a', 'b'}) do close(goal[f], case[f], 1e-7, key .. ' ' .. case.key .. ' ' .. f) end
                assert((goal.cal ~= nil) == case.cal, key .. ' ' .. case.key .. ' through a measured response')
                local lut, row = case.key:match('^(%x+):(%d+)$')
                local spec = analyses[t].luts[lut]
                local data = ffi.new('float[?]', spec.width * spec.height * 4)
                ffi.copy(data, spec.values, spec.width * spec.height * 16)
                Recolor.apply_finish(data, spec.width, tonumber(row), analyses[s], goal.finish)
                local c = Colour.row_values(data, spec.width, tonumber(row))
                local _, _, _, err = transfer.fit(c, case.L, case.a, case.b, goal.cal)
                close(err, case.err, 1e-6, key .. ' ' .. case.key .. ' error')
                for k, column in ipairs(Transfer.COLUMNS) do
                    for ch = 0, 2 do
                        close(c[column * 4 + ch + 1], case.colors[(k - 1) * 3 + ch + 1], 1e-7,
                              key .. ' ' .. case.key .. ' column ' .. column)
                    end
                end
                painted_rows = painted_rows + 1
            end
        end
    end
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

-- The new texels of a sample of pattern plans (tests/fixtures/pattern_texels.lua): Recolor.pattern_texel equals
-- research/match12.py pattern_color, through the measured gain and, far from the pattern's own color, its luminance
-- alone (2026-10-07: the B-01 Tactical's stripes asked for navy showed grey-green).
local texels = 0
check('pattern texels equal the reference for a sample of pattern plans (the gain and its hue guard)', function()
    for _, case in ipairs(fixture('pattern_texels')) do
        local d, gain, want = case[2], case[3], case[4]
        local r, g, b = Recolor.pattern_texel({L = d[1], a = d[2], b = d[3], gain = gain or nil}, Colour)
        for i, v in ipairs({r, g, b}) do close(v, want[i], 1e-7, case[1] .. ' texel ' .. i) end
        texels = texels + 1
    end
    assert(texels > 0, 'pattern texels sampled')
end)

-- Every pair the user reported (2026-10-05 and later: playtest, Armory sheets, real play), with the look agreed:
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
    -- 2026-10-06 (user, real play): the SC-34 Infiltrator colored the base of helmets completely white. 93% of it
    -- is undersuit black, which never was its identity, so its 2% light-grey trims were; the black is its paint now.
    {'212df664', '5bb4bbb0', 'EX-16 Prototype 16 <- SC-34 Infiltrator: the base dark like the suit, never white',
     {{{43, -3, 12}, {23, 0, 0}, 'pair', {15, 35}}, {{19, 1, 1}, {23, 0, 0}, 'pair'}}},
    {'d0ce5bc7', '5bb4bbb0', 'Salamander <- SC-34 Infiltrator: a dark shell like the suit, the orange takes its yellow',
     {{{34, 1, 1}, {23, 0, 0}, 'pair', {15, 35}}, {{26, 0, -1}, {23, 0, 0}, 'pair'},
      {{48, 32, 49}, {60, -11, 48}, 'accent'}}},
    {'1e9444f9', '5bb4bbb0', 'Battle Master <- SC-34 Infiltrator: dark like the suit, no white shell',
     {{{34, 0, -1}, {23, 0, 0}, 'pair', {15, 35}}, {{47, 0, 1}, {23, 0, 0}, 'pair'}}},
    -- 2026-10-06 (user, screenshots): the RS-100 Sanctioner's hood and mask (one black group) turned white on the
    -- RE-1861 Parade Commander and red on the CE-07 Demolition Specialist; both armors are mostly their suit (the
    -- suit rule above). Hoods kept (Recolor Hoods off): the hood stays, the mask and band match as before.
    {'47bcec20', 'c71dbba4', 'RS-100 Sanctioner <- RE-1861 Parade Commander: dark like the coat, never white; band red',
     {{{16, 0, 0}, {23, 1, 1}, 'pair', {15, 30}}, {{46, 4, 24}, {27, 33, 25}, 'accent'}}},
    {'47bcec20', '5a17d6d6', 'RS-100 Sanctioner <- CE-07 Demolition Specialist: black like the suit, never red; band red',
     {{{16, 0, 0}, {22, 0, 0}, 'pair', {15, 30}}, {{46, 4, 24}, {29, 35, 31}, 'accent'}}},
    {'47bcec20', 'bc5cf836', 'RS-100 Sanctioner <- O-44 Bonded Pilot, hoods kept: black hood, maroon mask and band',
     {{{15, 0, -1}, 'keep'}, {{19, 1, 1}, {20, 19, 11}, 'pair'}, {{46, 4, 24}, {20, 19, 11}, 'accent'}},
     options = {keep_hoods = true}},
    {'47bcec20', 'fb4b1254', 'RS-100 Sanctioner <- CE-35 Trench Engineer, hoods kept: black hood, orange mask and band',
     {{{15, 0, -1}, 'keep'}, {{19, 1, 1}, {41, 33, 50}, 'pair'}, {{46, 4, 24}, {41, 33, 50}, 'accent'}},
     options = {keep_hoods = true}},
    -- 2026-10-06 (user, screenshot 2): metal helmets stay bronze or gold on a white or green armor. Match Materials:
    -- a big metal part taking paint becomes that paint ('finish'); paint stays paint ('no finish').
    {'ec49526f', '4a545f06', 'B-22 Model Citizen <- DS-42 Federation\'s Blade, materials: the chrome shell takes the paint',
     {{{38, -2, -2}, {41, 1, 5}, 'pair', {38, 44}, 'finish'}, {{19, 1, 1}, {20, 0, 0}, 'pair', nil, 'no finish'}},
     options = {materials = true}},
    {'a8bf0ccb', '4a545f06', 'RE-824 Bearer of the Standard <- DS-42, materials: metal shell and gold crest take the paint',
     {{{37, 0, -3}, {41, 1, 5}, 'pair', {38, 44}, 'finish'}, {{49, 3, 25}, {41, 1, 5}, 'pair', {38, 44}, 'finish'}},
     options = {materials = true}},
    {'b19d6c0a', 'aa32b384', 'DP-8 Mountain-Scaled <- EX-16 Prototype 16, materials: the gold takes the tan paint',
     {{{46, 3, 23}, {37, 0, 14}, 'pair', {34, 40}, 'finish'}}, options = {materials = true}},
    -- 2026-10-06 (user, rendered validation): Armor Matches Helmet turned a whole dark armor the bright red of the PH-9
    -- Predator's beret (42% of what shows: the helmet's largest part). A vivid minority is no helmet's identity now:
    -- the armor takes the mask's dark color; the red stays an accent (the B-01 Tactical's trim takes it).
    {'9f212504', '1b2fde48', 'Armor 9f212504 <- PH-9 Predator: dark like the mask, never the beret\'s red',
     {{{23, 1, 0}, {23, -3, 6}, 'pair', {15, 30}}}},
    {'4f7fb2bd', '1b2fde48', 'B-01 Tactical armor <- PH-9 Predator: dark like the mask, never the beret\'s red',
     {{{23, 0, 0}, {23, -3, 6}, 'pair', {15, 30}}}},
    -- 2026-10-06 (image review of the rendered validation, for the user): the capped Bulwark still went near-black (a
    -- dark color on bare metal reads black) on an ornate silver, navy and gold armor. A bare-metal part taking a dark
    -- color takes the source's bare metal when it shows some: the steel shell the chainmail's silver.
    {'a5574ac2', 'a9a71fe7', 'CPR-80 Bulwark <- DP-8 Mountain-Scaled: the steel echoes the chainmail silver, never black',
     {{{39, 1, 1}, {46, 0, 2}, 'pair', {38, 55}}}},
    -- 2026-10-06 (image review re-check, for the user): the RE-2310 Honorary Guard's gold brow band (15%, model chroma
    -- 28, looks 42) went black with the shell instead of echoing the CE-27 Ground Breaker's bright yellow trim: a
    -- metal group's accent class goes by its look when that is more saturated.
    {'6809ad22', '7edf6505', 'RE-2310 Honorary Guard <- CE-27 Ground Breaker: the gold band takes the yellow trim',
     {{{91, 0, 42}, {47, -5, 44}, 'accent'}}},
    -- 2026-10-07 (user, manual testing, Armor Matches Helmet; an independent review's notes): accents kept their own
    -- color when the helmet had no saturated accent (v1.1's rule), a gold braid just over 10% went black, all-suit
    -- armors did not change, a camo color turned purple (REPORTED_FITS). Agreed looks: the helmet's colors reach the
    -- armor's real parts; without a saturated accent its accents take what the pairing gives, small ones its second
    -- color.
    {'fd456de0', '261c4a52', 'DP-53 Savior of the Free <- B-01 Tactical: the gold braid takes the yellow stripe, not black',
     {{{49, 3, 26}, {61, -10, 42}, 'accent'}}},
    {'3f1bec1a', 'cd3d20dc', 'DP-00 Tactical <- CW-36 Winter Warrior: no yellow left, the trim takes the helmet\'s dark',
     {{{55, -5, 50}, {59, 0, 6}, 'pair'}, {{44, -1, 45}, {24, 0, -2}, 'accent'}}},
    {'3f1bec1a', '0e3b10bf', 'DP-00 Tactical <- UF-50 Bloodhound (right as it was): maroon plates and trim, dark suit',
     {{{55, -5, 50}, {21, 20, 11}, 'pair'}, {{44, -1, 45}, {21, 20, 11}, 'accent'}, {{23, 0, 0}, {22, 0, 0}, 'pair'}}},
    {'f7e6f127', '0e3b10bf', 'O-3 Free Spirit <- UF-50 Bloodhound: the suit takes the maroon',
     {{{26, 1, 1}, {21, 20, 11}, 'pair'}}},
    {'e9add047', '6478678e', 'AF-02 Haz-Master <- IX-VOIDWALKER: the yellow suit and the olive take the cream, dark navy',
     {{{61, -4, 49}, {59, 1, 6}, 'pair'}, {{33, -3, 17}, {59, 1, 6}, 'pair'}, {{22, 0, 0}, {24, -1, -8}, 'pair'}}},
    {'6d30f386', '6478678e', 'B-01 Tactical (6d30f386) <- IX-VOIDWALKER: the suit takes the cream, the yellow the navy',
     {{{22, 0, 0}, {59, 1, 6}, 'pair'}, {{79, 4, 68}, {24, -1, -8}, 'accent'}}, {f18dfbb5346732c1 = {24, -1, -8}}},
    {'b513fd54', '6478678e', 'DP-40 Hero of the Federation <- IX-VOIDWALKER: white with navy trims',
     {{{25, 0, 0}, {59, 1, 6}, 'pair'}, {{52, 8, 42}, {24, -1, -8}, 'pair'}}},
    -- 2026-10-06 (image review) under the rule above: the B-01 Tactical's royal-blue band (a pattern) kept its color
    -- under an armor without an accent; it takes the B-22 Model Citizen's second color, its dark
    {'4f6ccd6c', 'cb7e9736', 'B-01 Tactical <- B-22 Model Citizen: the royal-blue band takes the armor\'s dark',
     {{{25, 8, -31}, {42, -2, -2}, 'pair'}}, {['8f79858a431980c1'] = {22, 0, 0}}},
    -- 2026-10-07 (user, manual testing; Armor Matches Helmet, Match Materials on): the CM-14 Physician turned yellow with
    -- the RS-67 Null Cipher: its green is two groups (15% and 12%), each passed as a trim and took the helmet's 0.3%
    -- yellow accent. A trim's hue family counts whole now: the green takes the helmet's dark. Then (user and image
    -- review of the renders, same day): its 3% red canisters turned that speck's bright yellow and its cream panels (a
    -- pattern, 13.7%) stayed cream on a dark helmet: the canisters take the helmet's dark, the cream its grey.
    {'38aa207d', '58716e11', 'CM-14 Physician <- RS-67 Null Cipher: the green suit and red canisters dark, never the '
     .. '0.3% yellow; the cream panels grey',
     {{{37, -21, 7}, {27, 1, 0}, 'pair'}, {{40, -30, 7}, {27, 1, 0}, 'pair'}, {{23, 34, 22}, {29, 0, -2}, 'pair'}},
     {['4cac10858d877485'] = {51, 0, 0}}, options = {materials = true}},
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
-- One reported pair against its agreed look (t, s: matcher items; materials: Match Materials on). A group's 5th
-- field: 'finish' (its rows take the source row's finish) or 'no finish'.
local function check_reported(case, t, s, why, materials)
    local plan, patterns = Matcher.plan(t, s, materials), Matcher.pattern_plan(t, s)
    for _, e in ipairs(case[4]) do
        local g = assert(near(t, e[1]), why .. ': target color ' .. table.concat(e[1], ' '))
        local m = plan[g.rows[1].key]
        if e[2] == 'keep' then
            for _, row in ipairs(g.rows) do
                assert(plan[row.key] == nil, why .. ': ' .. table.concat(e[1], ' ') .. ' keeps its color')
            end
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
            if e[5] then
                for _, row in ipairs(g.rows) do
                    local goal = plan[row.key]
                    assert((goal.finish == src.rep.key) == (e[5] == 'finish'), string.format('%s: %s row %s %s', why,
                           table.concat(e[1], ' '), row.key, e[5]))
                end
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

check('every pair the user reported plans the agreed look', function()
    local items, kept = items_of(), items_of(true)
    for _, case in ipairs(REPORTED) do
        local options = case.options or {}
        local t, s, why = (options.keep_hoods and kept or items)[case[1]], items[case[2]], case[3]
        assert((t and s) or limit, why .. ': kits analysed') -- a kit limit (quick runs) may leave them out
        if t and s then check_reported(case, t, s, why, options.materials) end
    end
end)

-- Reported pairs whose fitted colors were wrong on screen, with the look agreed: {target kit, source kit, why,
-- {{target color (a group, as REPORTED), max paint chroma over the goal's, min paint b or nil, max hue gap or nil}}}.
-- The paint is the fitted row's mean albedo (CIELAB), the color the eye takes from a metal's reflections; the hue gap
-- bounds every saturated color of the fitted row (chroma >= 8) against the goal's hue, in degrees.
local REPORTED_FITS = {
    -- 2026-10-06 (user, rendered validation): the scratched steel shell turned deep blue from the armor's dull navy
    -- (look chroma 9): its paint got chroma 17 to make up for the metal's dark parts, and the reflections showed it
    -- all. Agreed: a dark metal whose blue is no stronger than the armor's.
    {'a5574ac2', 'a9a71fe7', 'CPR-80 Bulwark <- DP-8 Mountain-Scaled: dark metal, its blue no stronger than the armor\'s',
     {{{39, 1, 1}, 0.5, -10}}},
    -- 2026-10-06 (image review, for the user): Armor Matches Helmet with the GS-66 Lawmaker turned the B-24 Enforcer's
    -- dark leather navy-purple and its grey plates steel-blue: the Lawmaker's silver and dark visor surround measure a
    -- slight tint (chroma 4-5) that does not show on the helmet. Agreed: the leather dark and the plates neutral grey.
    {'ac0adecd', '24fdb2c0', 'B-24 Enforcer <- GS-66 Lawmaker: neutral, never navy-purple leather or steel-blue plates',
     {{{22, 1, 1}, 1.0}, {{35, 2, -2}, 1.0}}},
    -- 2026-10-07 (user, manual testing): the TG-8 Sharpshooter's camo turned a purple that exists nowhere with the UF-50
    -- Bloodhound: its brown camo color (55 degrees) was turned rigidly with the olive paint (-107 degrees). Agreed:
    -- every saturated color of the row near the maroon.
    {'5d0d8002', '0e3b10bf', 'TG-8 Sharpshooter <- UF-50 Bloodhound: maroon camo, no purple',
     {{{32, -5, 6}, 15, nil, 60}}},
}

-- Degrees between two hues (a, b pairs), 0-180.
local function hue_apart(a1, b1, a2, b2)
    local d = math.abs(math.deg(math.atan2(b1, a1) - math.atan2(b2, a2))) % 360
    return d > 180 and 360 - d or d
end

local reported_fits = 0
check('every reported fit keeps the agreed paint', function()
    local transfer = Transfer.new(Colour, colour)
    local items = items_of()
    for _, case in ipairs(REPORTED_FITS) do
        local t, s, why = items[case[1]], items[case[2]], case[3]
        assert((t and s) or limit, why .. ': kits analysed')
        if t and s then
            local plan = Matcher.plan(t, s)
            for _, e in ipairs(case[4]) do
                local g = assert(near(t, e[1]), why .. ': target color ' .. table.concat(e[1], ' '))
                for _, row in ipairs(g.rows) do
                    local goal = assert(plan[row.key], why .. ': ' .. row.key .. ' planned')
                    local spec = analyses[case[1]].luts[row.lut]
                    local c = Colour.row_values(spec.values, spec.width, row.row)
                    transfer.fit(c, goal.L, goal.a, goal.b, goal.cal)
                    local _, pa, pb = colour.albedo_lab(c)
                    local paint_c, goal_c = math.sqrt(pa * pa + pb * pb), math.sqrt(goal.a ^ 2 + goal.b ^ 2)
                    assert(paint_c <= goal_c + e[2], string.format('%s: %s paint chroma %.1f, the goal\'s %.1f', why,
                           row.key, paint_c, goal_c))
                    if e[3] then
                        assert(pb >= e[3], string.format('%s: %s paint b %.1f, at least %d', why, row.key, pb, e[3]))
                    end
                    for _, column in ipairs(e[4] and Transfer.COLUMNS or {}) do
                        local o = column * 4
                        local _, ca, cb = Colour.srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])
                        if math.sqrt(ca * ca + cb * cb) >= 8 then
                            local gap = hue_apart(ca, cb, goal.a, goal.b)
                            assert(gap <= e[4], string.format('%s: %s column %d is %.0f degrees from the goal\'s hue', why,
                                   row.key, column, gap))
                        end
                    end
                end
            end
            reported_fits = reported_fits + 1
        end
    end
end)

-- The desired colors of a sample of plans and the colors fitted to them (on the analysed LUT rows).
local fitted, fits_kept = 0, 0
check('desired and fitted colors equal the reference for a sample of plans; no fit ends farther than the own colors',
      function()
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
                local oL, oa, ob
                if cal then oL, oa, ob = colour.look(c, cal, Colour.is_soft(c)) else oL, oa, ob = colour.perceived(c) end
                local own = Colour.de2000(oL, oa, ob, case.L, case.a, case.b)
                local _, _, _, err = transfer.fit(c, case.L, case.a, case.b, cal)
                close(err, case.err, 1e-6, key .. ' ' .. case.key .. ' error')
                -- a fit never ends farther from the goal than the row's own colors (126 of these rows did before v1.3)
                assert(err <= own + 1e-9, key .. ' ' .. case.key .. string.format(' fitted %.3f, own %.3f', err, own))
                if err == own then fits_kept = fits_kept + 1 end
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

-- Recolor Cape (src/capes.lua): every cape's rows (the cape model over its scalar fields, in the runtime's data
-- scope: its archive and the shared one) and its plans against the fixture's sources equal research/capes.py's.
local CAPES = fixture('capes')
local cape_rows, cape_plans, capes_analysed, cape_seconds, cape_longest, cape_tints = 0, 0, 0, 0, 0, 0
local cape_zones, cape_analyses, cape_stretches = 0, {}, {}
local cape_emblems, cape_sheets = 0, 0

-- Adler-32 of n bytes at a uint8_t pointer.
local function adler32_bytes(data, n)
    local a, b = 1, 0
    for i = 0, n - 1 do
        a = (a + data[i]) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

-- A cape's emblems against the reference rows: {row, layer, L, a, b, cells, x0, y0, x1, y1, host row, bins...}.
local function check_emblems(kit, a)
    local emblems, want = a.emblems or {}, kit.emblems or {}
    assert(#emblems == #want, string.format('%s: %d emblems, expected %d', kit.name, #emblems, #want))
    for i, e in ipairs(emblems) do
        local w, what = want[i], string.format('%s emblem %d', kit.name, i)
        assert(e.row == w[1] and e.layer == w[2], what .. ' row and layer')
        close(e.L, w[3], 1e-7, what .. ' L')
        close(e.a, w[4], 1e-7, what .. ' a')
        close(e.b, w[5], 1e-7, what .. ' b')
        assert(e.cells == w[6], what .. ' cells ' .. e.cells .. ', expected ' .. w[6])
        local r = e.rect or {-1, -1, -1, -1}
        for k = 1, 4 do assert(r[k] == w[6 + k], what .. ' sheet rect ' .. k) end
        local q, counts = next(e.around)
        assert(q == w[11], what .. ' cloth row')
        for k = 0, Capes.ZONE_BINS - 1 do assert(counts[k] == w[12 + k], what .. ' bin ' .. k) end
        cape_emblems = cape_emblems + 1
    end
end

-- A cape's decal sheet, its whole mip chain, read as src/recolor.lua's pipeline reads it (deps.find set).
local function read_sheet(name, size)
    local archive, record = deps.find(name, Kits.TYPE_TEXTURE)
    assert(archive, name .. ': sheet found')
    local main_size = slim.part_size(record, 'main')
    local main = scratch(main_size)
    slim.part(archive, record, 'main', 0, main_size, main, 0)
    local info = Texture.describe(main, main_size)
    assert(info.total == size, name .. ': sheet size')
    local data = ffi.new('uint8_t[?]', size)
    Texture.pixels(slim, archive, record, info)(0, size, data, 0)
    return data
end

-- The sheets a cape's plans recolor (kit.sheets: {source, Adler-32 of the recolored mip chain, cells {x0, y0, x1, y1,
-- dL, da, db}}): the emblems picked, the recipe and the recolored bytes equal the reference.
local function check_sheets(kit, a, t, items, cape_plan)
    for _, entry in ipairs(kit.sheets or {}) do
        local source = items[entry[1]]
        if source then
            local what = kit.name .. ' <- ' .. entry[1]
            local picks = Matcher.cape_emblems(cape_plan(source), t, source, a.emblems, a.tint_of)
            local recipe = assert(Recolor.sheet_recipe(a, picks), what .. ': a sheet recipe')
            assert(#recipe.cells == #entry[3], what .. ': ' .. #recipe.cells .. ' cells, expected ' .. #entry[3])
            for c, cell in ipairs(recipe.cells) do
                local w = entry[3][c]
                for k = 1, 4 do assert(cell.rect[k] == w[k], what .. ' cell ' .. c .. ' rect ' .. k) end
                for k = 1, 3 do close(cell.shift[k], w[4 + k], 1e-7, what .. ' cell ' .. c .. ' shift ' .. k) end
            end
            local data = read_sheet(recipe.name, recipe.size)
            for _, cell in ipairs(recipe.cells) do
                Capes.recolor_sheet(data, recipe, cell, Colour)
            end
            assert(adler32_bytes(data, recipe.size) == entry[2], what .. ': the recolored sheet\'s bytes')
            cape_sheets = cape_sheets + 1
        end
    end
end
check('every cape\'s rows, plans and built tints equal the reference (Recolor Cape)', function()
    local items = items_of()
    local transfer = Transfer.new(Colour, colour)
    deps.Kits, deps.Texture, deps.Colour = Kits, Texture, Colour
    for i, kit in ipairs(CAPES) do
        if not limit or i <= limit then
            local archives = {kit.archive, samples.archive}
            deps.find = function(name, kind)
                for _, archive in ipairs(archives) do
                    local record = slim.locate(archive, name, kind)
                    if record then return archive, record end
                end
                return nil
            end
            local cape_started = clock()
            -- the longest stretch between two pause points (a job slice's floor), with the job's pause points: the
            -- analysis's and the game-data reader's (inside and between chunk decodes, src/slim.lua)
            local last = cape_started
            deps.yield = function()
                local now = clock()
                cape_stretches[#cape_stretches + 1] = now - last
                last = now
            end
            slim.scratch.yield = deps.yield
            local a = Capes.analyse(kit, 0, deps)
            deps.yield, slim.scratch.yield = yield, nil
            local took = clock() - cape_started
            cape_analyses[kit.id] = a
            capes_analysed, cape_seconds = capes_analysed + 1, cape_seconds + took
            if took > cape_longest then cape_longest = took end
            if #kit.rows == 0 then -- its LUT outside the archives searched (no analysis), or no cloth showing
                assert(a == nil or #a.rows == 0, kit.name .. ': no rows')
            else
                assert(a and #a.rows == #kit.rows, string.format('%s: %d rows, expected %d', kit.name,
                       a and #a.rows or -1, #kit.rows))
                for r, row in ipairs(a.rows) do
                    local e = kit.rows[r]
                    local what = kit.name .. ' ' .. row.key
                    assert(row.key == e[1], what .. ' key order: expected ' .. e[1])
                    close(row.area, e[2], 1e-12, what .. ' area')
                    close(row.L, e[3], 1e-7, what .. ' L')
                    close(row.a, e[4], 1e-7, what .. ' a')
                    close(row.b, e[5], 1e-7, what .. ' b')
                    cape_rows = cape_rows + 1
                end
                -- the zones' borders (src/capes.lua zones): zone, row, cells per tint bin
                local zone_lines = 0
                for z, by_row in pairs(a.zones or {}) do
                    for q, counts in pairs(by_row) do
                        zone_lines = zone_lines + 1
                        local found
                        for _, e in ipairs(kit.zones) do if e[1] == z and e[2] == q then found = e end end
                        assert(found, string.format('%s zone %d row %d: not in the reference', kit.name, z, q))
                        for k = 0, Capes.ZONE_BINS - 1 do
                            assert(counts[k] == found[3 + k], string.format('%s zone %d row %d bin %d', kit.name, z, q, k))
                        end
                    end
                end
                assert(zone_lines == #kit.zones, kit.name .. ': zone lines ' .. zone_lines .. ', expected ' .. #kit.zones)
                cape_zones = cape_zones + zone_lines
                check_emblems(kit, a)
                local t = Matcher.item(a.rows, false, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
                local function cape_plan(source)
                    local mapping = Matcher.plan(t, source)
                    if a.zones then Matcher.cape_zones(mapping, t, source, a.zones, a.tint_of) end
                    return mapping
                end
                for _, pair in ipairs(kit.plans) do
                    local source = items[pair[1]]
                    if source then
                        assert(adler32(plan_text(cape_plan(source))) == pair[2], kit.name .. ' <- ' .. pair[1])
                        cape_plans = cape_plans + 1
                    end
                end
                check_sheets(kit, a, t, items, cape_plan)
                -- the tints the first source's plan builds: cape LUT column 3 RGB, fitted alone over the built row
                local first = items[kit.plans[1][1]]
                if #kit.tints > 0 and first then
                    local cape_lut = kit.pieces[1].cape_lut
                    local built = Recolor.build_luts(a, cape_plan(first), transfer, function() end)
                    local spec = assert(built[cape_lut], kit.name .. ': cape LUT built')
                    assert(spec.cape and spec.width == a.luts[cape_lut].width, kit.name .. ': a cape LUT copy')
                    for _, e in ipairs(kit.tints) do
                        local at = (e[1] * spec.width + 3) * 4
                        for ch = 0, 2 do
                            close(spec.data[at + ch], e[2 + ch], 1e-6, string.format('%s tint row %d channel %d', kit.name,
                                                                                      e[1], ch))
                        end
                        cape_tints = cape_tints + 1
                    end
                    for i = 0, spec.width * spec.height * 4 - 1 do -- only column 3 RGB of planned rows changes
                        local column, channel = math.floor(i / 4) % spec.width, i % 4
                        if column ~= 3 or channel == 3 then
                            assert(spec.data[i] == a.luts[cape_lut].values[i], kit.name .. ': cape LUT value ' .. i)
                        end
                    end
                end
            end
        end
    end
end)

-- Reported cape outfits (Recolor Cape; every reported case stays here with its agreed outcome). {cape, source kit,
-- Match Materials, what was reported and is expected, {[row key] = {source group lightness, kind[, 'neutral' (chroma
-- under 6) or 'vivid' (at least 15)]} or false (the row keeps its own colors)}, tint checks {cape LUT row, max chroma
-- of its built color}}. 2026-10-07: United in Equality with the AF-02 Haz-Master armor and the
-- CW-36 Winter Warrior helmet (Armor Matches Helmet, Match Materials on): its purple band stayed (the cape LUT's tint,
-- column 3, was not recolored) while its emblem (row 2) changed; the review asked for no purple and a readable emblem.
local REPORTED_CAPES = {
    {'6d9b8e21', 'cd3d20dc', true, 'United in Equality <- Winter Warrior: no purple left, the band light, the emblem '
     .. 'dark on it, the cloth and lining dark',
     {['11b6cb01f973e29e:0'] = {24, 'pair'}, ['11b6cb01f973e29e:4'] = {24, 'pair'},
      ['11b6cb01f973e29e:2'] = {24, 'zone'}, ['9c385033ddbaaa60:0'] = {59, 'pair'}},
     {{0, 6}}},
    -- the same cape with the CM-14 Physician and the RS-67 Null Cipher (the user's next outfit, rendered 2026-10-07):
    -- the purple band took the helmet's 0.28% yellow (an accent of 24%); a part over ACCENT_SMALL now needs a source
    -- accent of at least 1% (src/matcher.lua ACCENT_SOURCE_BIG). The emblem (row 2, bare metal) fits through the
    -- response its cloth borrows (round 2), so it aims at the grey's look itself, no longer PAINT_REFLECTION lighter (55)
    {'6d9b8e21', '58716e11', true, 'United in Equality <- RS-67 Null Cipher: no yellow, the band dark like the helmet, '
     .. 'the emblem grey on it',
     {['9c385033ddbaaa60:0'] = {29, 'pair'}, ['11b6cb01f973e29e:0'] = {27, 'pair'},
      ['11b6cb01f973e29e:2'] = {51, 'pair'}},
     {{0, 6}}},
    -- the UF-50 Bloodhound (user report 2026-10-07, Helmet Matches Armor, Match Materials on): its red and black share
    -- a lightness (L 21.1 and 20.8), so none of its colors read by lightness against the other. The Pillars of
    -- Freedom's cloth took its red and the red bars on it blended in; the Judgment Day's bands, Liberty's Herald's
    -- chevron and Fre Liberam's eagle went back to their own colors on its black ("fail to get colored"). A lost zone
    -- now takes the source color reading by CIELAB distance when none reads by lightness (Matcher zone_choice).
    -- Liberty's Herald's chevron lies on its black cloth above and its red tint below: neither main color reads against
    -- both, so it takes the Bloodhound's 1.8% silver, V and side stripes alike (one design color stays one).
    {'bd961a7c', 'b3550d20', true, 'Pillars of Freedom <- UF-50 Bloodhound: the cloth red, the bars black on it',
     {['b6c5bbb630fcf839:0'] = {21, 'pair', 'vivid'}, ['b6c5bbb630fcf839:2'] = {21, 'zone', 'neutral'}}, {}},
    {'c24b74f5', 'b3550d20', true, 'Judgment Day <- UF-50 Bloodhound: the cloth black, the bands red',
     {['716e89b0d447112d:0'] = {21, 'pair', 'neutral'}, ['716e89b0d447112d:1'] = {21, 'zone', 'vivid'},
      ['716e89b0d447112d:3'] = {21, 'zone', 'vivid'}}, {}},
    {'d45f0974', 'b3550d20', true, "Liberty's Herald <- UF-50 Bloodhound: the cloth black, its tint red, the chevron "
     .. 'silver',
     {['a52382a8e96628da:0'] = {21, 'pair', 'neutral'}, ['980ffc1d56ece0e8:0'] = {21, 'pair', 'vivid'},
      ['a52382a8e96628da:1'] = {40, 'zone', 'neutral'}, ['a52382a8e96628da:2'] = {40, 'zone', 'neutral'}}, {}},
    {'391bc756', 'b3550d20', true, 'Fre Liberam <- UF-50 Bloodhound: the cloth black, the eagle and its sword red',
     {['4843bbf7f6900021:0'] = {21, 'pair', 'neutral'}, ['4843bbf7f6900021:2'] = {21, 'zone', 'vivid'},
      ['4843bbf7f6900021:3'] = {21, 'zone', 'vivid'}}, {}},
}
local reported_capes = 0
-- One planned row of a reported cape outfit against its expected color (want: see REPORTED_CAPES).
local function check_cape_goal(case, plan, key, want)
    if want == false then
        assert(plan[key] == nil, case[4] .. ': ' .. key .. ' keeps its own colors')
        return
    end
    local goal = assert(plan[key], case[4] .. ': ' .. key .. ' planned')
    assert(math.abs(goal.L - want[1]) < 3 and goal.kind == want[2],
           string.format('%s: %s takes L %.1f (%s), expected about %d (%s)', case[4], key, goal.L, goal.kind,
                         want[1], want[2]))
    local c = math.sqrt(goal.a * goal.a + goal.b * goal.b)
    assert(not want[3] or (want[3] == 'neutral' and c < 6) or (want[3] == 'vivid' and c >= 15),
           string.format('%s: %s takes chroma %.1f, expected %s', case[4], key, c, tostring(want[3])))
end

-- One reported cape outfit against its agreed outcome (a: the cape's analysis, source: the matcher item).
local function check_reported_cape(case, a, source, transfer)
    local t = Matcher.item(a.rows, false, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
    local plan = Matcher.plan(t, source, case[3])
    if a.zones then Matcher.cape_zones(plan, t, source, a.zones, a.tint_of) end
    for key, want in pairs(case[5]) do check_cape_goal(case, plan, key, want) end
    local built = Recolor.build_luts(a, plan, transfer, function() end, nil) -- cloth: no finish to copy
    for _, tint in ipairs(case[6]) do
        local spec = assert(built[next(a.tint_of)], case[4] .. ': its cape LUT rebuilt')
        local at = (tint[1] * spec.width + 3) * 4
        local _, ta, tb = Colour.srgb_to_lab(spec.data[at], spec.data[at + 1], spec.data[at + 2])
        local c = math.sqrt(ta * ta + tb * tb)
        assert(c < tint[2], string.format('%s: tint row %d chroma %.1f', case[4], tint[1], c))
    end
    reported_capes = reported_capes + 1
end

check('reported cape outfits keep their agreed outcome (Recolor Cape)', function()
    local items = items_of()
    local transfer = Transfer.new(Colour, colour)
    for _, case in ipairs(REPORTED_CAPES) do
        local a, source = cape_analyses[case[1]], items[case[2]]
        assert((a and source) or limit, case[4] .. ': analysed') -- a kit limit (quick runs) may leave them out
        if a and source then check_reported_cape(case, a, source, transfer) end
    end
end)

table.sort(cape_stretches)
print(string.format('PASS test_parity (%d checks; %d kits analysed (%d measured) in %.2f s, %d plans (%d with '
    .. 'patterns, %d texels), %d with hoods kept, %d painting plans (%d rows fitted), %d reported pairs (%d by their fits) and %d '
    .. 'fitted rows (%d '
    .. 'keep their own colors) in %.2f s; %d capes (%d rows, %d zone borders, %d emblems, %d recolored sheets, %d plans, '
    .. '%d tints built, %d reported '
    .. 'outfits; analysis %.1f ms each, longest %.1f ms; stretches between pauses: 99%% under %.2f ms, longest %.2f '
    .. 'ms); %d chunk decodes)',
    passed, #kit_list, measured,
    analysed - started, plans,
    pattern_plans, texels, hood_plans, painting, painted_rows, reported, reported_fits, fitted, fits_kept, clock() - analysed,
    capes_analysed,
    cape_rows, cape_zones, cape_emblems, cape_sheets,
    cape_plans, cape_tints, reported_capes, capes_analysed > 0 and cape_seconds * 1000 / capes_analysed or 0,
    cape_longest * 1000, (cape_stretches[math.ceil(#cape_stretches * 0.99)] or 0) * 1000,
    (cape_stretches[#cape_stretches] or 0) * 1000,
    slim.scratch.decodes))
