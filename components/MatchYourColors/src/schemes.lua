-- Match Your Colors: the game's weapon paint schemes as paint schemes for the Helldiver (the Paint Scheme option).
--
-- Each scheme is the weapon customization item of the PaintScheme slot; it swaps the weapons' material LUTs, one
-- shared 8 x 23 LUT per material class. Its m_weapon LUT follows one row convention in all 11 schemes: r0 body
-- paint, r1 the secondary paint (the camo row in camo schemes), r2 cloth (mode 1), r3-r5 detail paints, r6-r7 metal.
-- The scheme -> LUT link lives in the game's encrypted settings, so it is listed here (archive from the game's
-- hash lookup, LUT name); the LUT itself is read from the game's bundles at runtime (KB match-your-colors-schemes-sync,
-- Steam build 25480438).
--
-- A scheme becomes a source item of three groups for src/matcher.lua: primary (share PRIMARY: r0, or the camo row
-- r1), secondary (SECONDARY: r1, or r0) and cloth (CLOTH: r2, counted as undersuit, so it goes to undersuit and dark
-- structure parts only when it is a dark neutral). Rows that take a camo row copy its colors and camo columns
-- (src/recolor.lua). Nothing here runs per frame.
--
-- SEAF (user request 2026-10-09: a scheme in the SEAF forces' colors) is not a weapon scheme: it is the SEAF
-- troopers' own uniform LUT (content/fac_super_earth/cha_seaf/cha_battlefront_seaf, material slot m_seaf_soldier,
-- standard variant; in the SEAF trooper package archive only). Its rows: r0 metal, r1 the light blue-grey uniform
-- (cloth, 31% of its ID mask), r2 the SEAF blue of the helmet and plates (paint, 18%), r3-r5 the dark gear (matte
-- cloth, 45%), r6 lens, r7 white markings. Primary the blue (the one color no weapon scheme has; the uniform first
-- read as Arctic with blue trim), secondary the uniform, cloth r3 (KB match-your-colors-cape-source-seaf).
local Schemes = {}

Schemes.PRIMARY, Schemes.SECONDARY, Schemes.CLOTH = 0.6, 0.25, 0.15

-- In the game's order (Paint_Solid, then Paint_Camo interleaved as its customization list shows them). text: the
-- en.lua key of its name; camo: the camo row (r1) is the primary.
Schemes.LIST = {
    {id = 'helldiver', text = 'scheme.helldiver', archive = 'd7353578fc8df474', lut = '9f09bf697ec501a0'},
    {id = 'forest', text = 'scheme.forest', archive = '5ea029039de33479', lut = '1bd978d3960f3b97'},
    {id = 'forest_camo', text = 'scheme.forest_camo', archive = '6b79bbb20a303671', lut = '72ba1e791ed0a166',
     camo = true},
    {id = 'arctic', text = 'scheme.arctic', archive = 'bbba973314a3b3f1', lut = '642d22bee762b6bd'},
    {id = 'arctic_camo', text = 'scheme.arctic_camo', archive = '4acfca3e8fe5a0e6', lut = 'b0bfc364b70a43d4',
     camo = true},
    {id = 'desert', text = 'scheme.desert', archive = '09510b899fdd4a13', lut = 'f8d36a490676ec43'},
    {id = 'desert_camo', text = 'scheme.desert_camo', archive = '444ff90550d8c91b', lut = 'ade6c402bf0030c9',
     camo = true},
    {id = 'urban', text = 'scheme.urban', archive = '9bdac09de7dd4b69', lut = '650af9d69b7696bc'},
    {id = 'urban_camo', text = 'scheme.urban_camo', archive = '13455c609ccd9960', lut = 'beaa6a092dde05d8',
     camo = true},
    {id = 'night', text = 'scheme.night', archive = '802cc92e12493f63', lut = '7bb4597035f23c80'},
    {id = 'venus', text = 'scheme.venus', archive = '855ea06e998711df', lut = '7b9692abb86210b4'},
    -- rows: the primary, secondary and cloth rows when they are not the weapon schemes' 0, 1, 2; roles = 'material':
    -- parts take them by material and piece (Schemes.role_plan below: plates the primary, clothing the secondary,
    -- gear the cloth row), not by area and lightness
    -- looks: the rows' looks (what a target aims at), calibrated against SEAF troopers spawned beside the Helldiver on
    -- the ship (research/live/live_seaf_reference.py; backs to the camera, one light): their uniform shows about L 31,
    -- a mid grey, where the Helldiver's SEAF uniform aimed at the albedo's look through the median soft-cloth response
    -- (L 63.8) showed L 40 (DS-191 Scorpion) to L 57 (CM-21 Trench Paramedic) and warm; their camo and grime make the
    -- uniform darker than its albedo. At L 46 it still read near-white in the Armory (screen L 45-59, B-01 Tactical up
    -- to 71) and lighter than the troopers' coats in one ship frame (L 39 against 31); the blue at (38, 2.5, -17)
    -- read periwinkle, lilac where a part's own tint added to it (independent image review 2026-10-09: "a greyer slate
    -- blue"); at (35, -0.5, -14) still a step lighter and bluer than the troopers' plates in the same ship frames (round
    -- 9 review; the Bulwark's painted steel "close"), now fitted as paint everywhere (role_plan flat). The uniform and
    -- the gear are neutral and fit their hue too: tinted blue (chroma 8.6) the uniform made armors "almost 100% blue"
    -- (user, 2026-10-09).
    {id = 'seaf', text = 'scheme.seaf', archive = '792b2a2ba11ae85d', lut = '493b5a6a30e49de5', rows = {2, 1, 3},
     roles = 'material', looks = {[1] = {40.0, 0.0, 0.0}, [2] = {32.0, -1.0, -12.0}, [3] = {20.0, 0.0, 0.0}}},
}

-- The scheme of an option value: 0 none, 1 to #LIST the list's entries; nil for anything else.
function Schemes.get(index)
    if type(index) ~= 'number' or index % 1 ~= 0 then return nil end
    return Schemes.LIST[index]
end

-- The rows of a scheme's source item, primary first: {row index, share, undersuit share}.
function Schemes.roles(scheme)
    local primary, secondary, cloth = 0, 1, 2
    if scheme.camo then primary, secondary = 1, 0 end
    if scheme.rows then primary, secondary, cloth = scheme.rows[1], scheme.rows[2], scheme.rows[3] end
    return {{primary, Schemes.PRIMARY, 0}, {secondary, Schemes.SECONDARY, 0}, {cloth, Schemes.CLOTH, Schemes.CLOTH}}
end

-- The keys of a scheme's primary, secondary and cloth rows ('lut:row', Schemes.roles order): Matcher.role_plan's.
function Schemes.role_keys(scheme)
    local out = {}
    for i, role in ipairs(Schemes.roles(scheme)) do out[i] = scheme.lut .. ':' .. role[1] end
    return out
end

-- Material roles (a paint scheme whose roles follow materials, src/schemes.lua roles = 'material': SEAF, user request
-- 2026-10-09). Each target row takes the role its part plays on a SEAF trooper, by material and piece, not the color
-- area and lightness pair it with: painted hard parts (plates, shells, pads) the primary (the SEAF blue); the
-- clothing (soft rows of undergarment pieces, and large light cloth of armor pieces) the secondary (the grey uniform);
-- the gear the cloth row (black): straps, pouches, padding, gloves, boots, harness and small cloth of armor pieces,
-- colored trims (chroma ACCENT_C or more, under MAIN_COLOR of the paint), and dark parts the item does not need for
-- its plates or its uniform. A dark hard part is gear once the item's light hard parts reach ROLE_PLATES (the PH-9
-- Predator's gloves under its camo plates), else plate (the B-01 Tactical is one black group); dark clothing is gear
-- once the item's light clothing reaches ROLE_CLOTH (the Predator's and the CM-21 Trench Paramedic's boots), else the
-- largest dark clothing row of each LUT without light clothing (by texture coverage: plates hide trousers on screen)
-- is the uniform when it is ROLE_LEAD times the next (the B-01's jacket and trousers, the SA-12 Twigsnapper's
-- trousers: 34% of its legs' mask, 20% the next, near-equal on screen; the B-01's gloves stay gear) and the rest
-- gear. A helmet's main cloth
-- of ROLE_COAT or more is its shell (blue). Independent image review 2026-10-09, against SEAF troopers on the ship:
-- gloves and boots turned white, the vest areas grey; the troopers wear black there. Paired by area and lightness the
-- SEAF blue went to the largest part whatever it was (a medic's suit) and plates took the light uniform; by group,
-- armors whose plates share their cloth's color were "almost completely pure white" (user, same day).
-- Every role color is flat: a part's tonal offset stays within ROLE_TONE of its role's look, and its hue and that of
-- every color of its LUT row (detail, wear, camo) follow the role (goal.all, src/transfer.lua): kept wear and detail
-- colors left rust flecks and brown straps on the uniform and magenta edges on blue plates (same review). A colored
-- lens (a red or orange visor) takes a dark smoke (LENS_L, neutral); a glowing light never changes.
local ROLE_DARK_L, ROLE_PLATES, ROLE_CLOTH, ROLE_COAT, ROLE_LEAD, ROLE_TONE, LENS_L = 30, 0.15, 0.10, 0.10, 1.5, 6, 28
local BLUE, UNIFORM, GEAR = 1, 2, 3
local function chroma(a, b) return math.sqrt(a * a + b * b) end
local function dark(M, g) return g.mL < ROLE_DARK_L and chroma(g.ma, g.mb) < M.ACCENT_C end
local function accent(M, g) return chroma(g.ma, g.mb) >= M.ACCENT_C and g.share < M.MAIN_COLOR end
local function hard(row) return row.mode < 0.5 end
-- Clothing: a soft row seen mostly on undergarment pieces (src/kits.lua row.under).
local function clothing(row) return not hard(row) and row.area > 0 and row.under >= 0.5 * row.area end

-- A row's texture coverage (src/matcher.lua tex_area: its ID-mask area by piece weight), else its area.
local function coverage(row) return row.tex_area or row.area end
-- Whether row x comes before row y, largest coverage first (ties by key: the same order every run).
local function before(x, y)
    if coverage(x) ~= coverage(y) then return coverage(x) > coverage(y) end
    return x.key < y.key
end
-- The uniform rows of an item without light clothing: of each LUT without light clothing, its largest dark clothing
-- row when ROLE_LEAD times the next. by_lut: {lut -> {rows}}; light: {lut -> true}.
local function lead_rows(by_lut, light)
    local out = {}
    for lut, rows in pairs(by_lut) do
        if not light[lut] then
            table.sort(rows, before)
            if not rows[2] or coverage(rows[1]) >= ROLE_LEAD * coverage(rows[2]) then out[rows[1].key] = true end
        end
    end
    return out
end
-- One row of a group (is_dark: the group is dark) into the inventory's sums (acc: inventory's).
local function tally(acc, row, is_dark, paint_area)
    local share = row.area / paint_area
    if not is_dark and hard(row) then acc.plates = acc.plates + share end
    if not clothing(row) then return end
    if not is_dark then
        acc.cloth, acc.light[row.lut] = acc.cloth + share, true
    else
        acc.by_lut[row.lut] = acc.by_lut[row.lut] or {}
        table.insert(acc.by_lut[row.lut], row)
    end
end
-- What item t has of its own: light hard parts reaching ROLE_PLATES (plates), light clothing reaching ROLE_CLOTH (a
-- uniform), the uniform rows of an item without (lead_rows), its main group.
local function inventory(M, t)
    local acc = {plates = 0, cloth = 0, by_lut = {}, light = {}}
    for _, g in ipairs(t.groups) do
        if not g.hood and not accent(M, g) then
            local is_dark = dark(M, g)
            for _, row in ipairs(g.rows) do tally(acc, row, is_dark, t.paint_area) end
        end
    end
    return {plates = acc.plates >= ROLE_PLATES, cloth = acc.cloth >= ROLE_CLOTH,
            lead = lead_rows(acc.by_lut, acc.light), main = t.groups[1], armor = t.armor, paint_area = t.paint_area}
end

-- The role of a hard row of group g, of a soft one, of any row.
local function hard_role(M, g, has)
    if not dark(M, g) then return BLUE end
    if has.plates or (g.share < M.PAINT_SHARE and g ~= has.main) then return GEAR end
    return BLUE
end
local function soft_role(M, g, row, has)
    local large = row.area / has.paint_area >= ROLE_COAT
    if not has.armor then return (large and g == has.main) and BLUE or GEAR end
    if not clothing(row) then return (large and not dark(M, g)) and UNIFORM or GEAR end
    if not dark(M, g) then return UNIFORM end
    return (not has.cloth and has.lead[row.key]) and UNIFORM or GEAR
end
local function row_role(M, g, row, has)
    if accent(M, g) then return has.accent_role end
    if hard(row) then return hard_role(M, g, has) end
    return soft_role(M, g, row, has)
end

-- Flat role colors (see above). The uniform's rows fit through their response, hue included, their cloth's own tint
-- cancelled (src/transfer.lua neutral_goal), so they read grey: fitted for lightness alone they kept each armor's warm
-- cast (the DS-191 Scorpion's and the Trench Paramedic's beige next to the troopers' grey, ship renders 2026-10-09).
-- The blue and the gear fit as paint (no response): the same albedo on every armor. Through the response of a red or
-- tan part the fit kept a maroon or teal albedo to cancel what the response saw (the Trench Paramedic's helmet trim);
-- through responses measured on black plastic (albedo under 0.05 linear) plates overshot to a pale powder blue (the
-- Scorpion's pads, the B-01's plates and helmet) while the Bulwark's painted steel read close to the troopers'
-- (independent image review 2026-10-09, round 9).
-- Under a cape (cape: Helmet and Armor Match Cape) the role colors are the cape's look (src/matcher.lua borrow_rows: gL,
-- ga, gb), fitted through each part's own response, and a part ends at most CAPE_TONE_UP lighter than it: up to
-- ROLE_TONE lighter, the B-01 Tactical's gear under Foesmasher's black was asked L 31 for a cape seen at L 21 and read
-- grey (user report 2026-10-14).
local CAPE_TONE_UP = 2
local function flat(mapping, part, src, role, cape)
    local L, a, b, up = src.L, src.a, src.b, ROLE_TONE
    if cape then L, a, b, up = src.gL or src.L, src.ga or src.a, src.gb or src.b, CAPE_TONE_UP end
    for _, row in ipairs(part.rows) do
        local goal = mapping[row.key]
        local tone = math.max(-ROLE_TONE, math.min(up, goal.L - L))
        goal.L, goal.a, goal.b, goal.all = L + tone, a, b, true
        if role ~= UNIFORM and not cape then goal.cal = nil end
    end
end
-- Group g's rows by role and material, each bucket mapped as a part of g (g's lightness: the rows' offsets; hard rows
-- as paint: Match Materials' finish when has.materials: always for SEAF, only with the option on under a cape; v1.4
-- painted every hard row under a cape whatever the option, so the B-22 Model Citizen helmet's chrome turned matte
-- cloth under the Eye of Liberty: user report 2026-10-14).
-- A role's color for hard or soft rows: with has.metal_second (below) hard parts of the main's role take the metal
-- second and soft rows of the second's role the main.
local function role_color(roles, role, is_hard, has)
    if has.metal_second then
        if is_hard and role == BLUE then return roles[UNIFORM] end
        if not is_hard and role == UNIFORM then return roles[BLUE] end
    end
    return roles[role]
end
local function map_group_roles(M, mapping, g, roles, has)
    local buckets, order = {}, {}
    for _, row in ipairs(g.rows) do
        local k = row_role(M, g, row, has) * 2 + (hard(row) and 1 or 0)
        if not buckets[k] then buckets[k], order[#order + 1] = {}, k end
        table.insert(buckets[k], row)
    end
    for _, k in ipairs(order) do
        local role, is_hard = math.floor(k / 2), k % 2 == 1
        local color = role_color(roles, role, is_hard, has)
        local part = {}
        for key, v in pairs(g) do part[key] = v end
        part.rows = buckets[k]
        M.map_group(mapping, part, 'pair', color, is_hard and has.materials, has.armor)
        flat(mapping, part, color, role, has.cape)
    end
end
-- Item t's colored lenses (glass, not glowing): a dark neutral smoke, as the gear.
local function map_lenses(M, mapping, t, gear)
    for _, row in ipairs(t.rows) do
        if row.lens and row.mode < 3.5 and (row.emissive or 0) <= 0
            and chroma(row.ma or row.a, row.mb or row.b) >= M.ACCENT_C then
            mapping[row.key] = {source = gear.rep.key, kind = 'pair', L = math.min(row.L, LENS_L), a = 0, b = 0,
                                all = true}
        end
    end
end
-- The plan of target item t against the scheme's item s by material roles; Matcher: src/matcher.lua; role_keys: the
-- keys of the scheme's primary, secondary and cloth rows (Schemes.role_keys).
-- opts (optional): {accent = the role of colored trims (default the gear), lenses = false (colored lenses keep their
-- colors), materials = false (hard rows keep their own finish; default: they take the role's, as SEAF paints)}.
-- The role plan's options into the inventory: accent_role, materials (hard rows painted: SEAF, or Match Materials under
-- a cape), cape (the cape split).
local function with_options(has, opts)
    has.accent_role = opts and opts.accent or GEAR
    has.materials = not opts or opts.materials ~= false
    has.cape = opts and opts.cape or false
    return has
end
-- Under a cape an armor is never left in one color (src/variety.lua, v1.5); SEAF's roles are its own.
local function cape_balanced(Matcher, mapping, target, source, has)
    if has.cape and target.armor and Matcher.balance then Matcher.balance(mapping, target, source) end
    return mapping
end

function Schemes.role_plan(Matcher, target, source, role_keys, opts)
    local by_key, roles = {}, {}
    for _, g in ipairs(source.groups) do
        for _, row in ipairs(g.rows) do by_key[row.key] = g end
    end
    for i, key in ipairs(role_keys) do roles[i] = by_key[key] end
    local mapping, has = {}, with_options(inventory(Matcher, target), opts)
    -- Match Materials under a cape whose second color is metal (the Eye of Liberty's gold, its LUT's metallic): hard parts
    -- take that metal and clothing the main. Cloth never turns metal: the gold went to clothing as a pale yellow paint
    -- and the plates kept the cape's black (independent review 1 2026-10-14; the user chose "Hard parts gold metal").
    has.metal_second = has.cape and has.materials and roles[UNIFORM] ~= nil and roles[UNIFORM] ~= roles[BLUE]
        and roles[UNIFORM].rep.metal or false
    for _, g in ipairs(target.groups) do
        if not g.hood then map_group_roles(Matcher, mapping, g, roles, has) end
    end
    if not (opts and opts.lenses == false) then map_lenses(Matcher, mapping, target, roles[GEAR]) end
    return cape_balanced(Matcher, mapping, target, source, has)
end

-- Helmet and Armor Match Cape on a near one-color item (its largest group CAPE_SPLIT of its paint or more: the B-01
-- Tactical's black, 94.5%, its helmet's 88%): paired by area and lightness the whole group is the anchor and takes the
-- cape's main color, so the item showed one color and none of the cape's others ("it just colors the entire armor
-- red. No accenting at all", user 2026-10-09, the Thundering Hooves of Loyalty: red 55%, gold 40%, maroon 4.5%). Such
-- an item is split by material as the SEAF roles: plates the cape's main color, clothing its second (the largest at
-- least CAPE_APART from the main), gear its darkest (a muted one first), colored trims its second; lenses keep theirs.
local CAPE_SPLIT, CAPE_APART = 0.8, 15.0
local function apart(x, y)
    local dL, da, db = x.L - y.L, x.a - y.a, x.b - y.b
    return math.sqrt(dL * dL + da * da + db * db) >= CAPE_APART
end
-- The keys of a cape source's main (its identity: the outside first, src/matcher.lua), second and darkest colors
-- (Schemes.role_plan's role_keys).
local function cape_keys(M, s)
    local main, second, dark = M.identity(s) or s.groups[1], nil, nil
    for _, g in ipairs(s.groups) do
        if not second and g ~= main and apart(g, main) then second = g end
    end
    for _, g in ipairs(s.groups) do
        local muted = chroma(g.ma, g.mb) < M.ACCENT_C
        if not dark or (muted and not dark.muted) or (muted == dark.muted and g.L < dark.g.L) then
            dark = {g = g, muted = muted}
        end
    end
    second = second or main
    return {main.rep.key, second.rep.key, dark.g.rep.key}
end
-- Whether cape source s's second color (cape_keys) is metal (the Eye of Liberty's gold): with Match Materials every
-- helmet and armor under it is split by material, so its hard parts take that metal (role_plan metal_second) whatever
-- its largest color's share: the CPR-80 Bulwark helmet (steel 79%, under CAPE_SPLIT) kept the cape's black, its stripe
-- a near-white gold, beside a gilded armor (independent review round 4, 2026-10-14).
function Schemes.metal_second(M, s)
    local keys = cape_keys(M, s)
    if keys[2] == keys[1] then return false end
    for _, g in ipairs(s.groups) do
        if g.rep.key == keys[2] then return g.rep.metal and true or false end
    end
    return false
end

-- The plan of target item t against source item s (src/matcher.lua): a scheme with material roles (SEAF) plans a
-- helmet or an armor by material (Matcher.role_plan), anything else (no scheme: nil; a cape) as Matcher.plan.
function Schemes.plan(Matcher, scheme, t, s, materials, cape)
    if scheme and scheme.roles == 'material' and not cape then
        return Schemes.role_plan(Matcher, t, s, Schemes.role_keys(scheme))
    end
    if s.cape_source and not cape and t.groups[1] and s.groups[1]
        and (t.groups[1].share >= CAPE_SPLIT or (materials and Schemes.metal_second(Matcher, s))) then
        return Schemes.role_plan(Matcher, t, s, cape_keys(Matcher, s),
                                 {accent = UNIFORM, lenses = false, materials = materials and true or false, cape = true})
    end
    return Matcher.plan(t, s, materials, cape)
end

-- The scheme as a source item for src/matcher.lua. lut: {values, width, height} (its m_weapon LUT); Colour: the
-- src/colour.lua module; colour: its color model (Colour.new, row_info); Matcher: src/matcher.lua. Its rows are
-- unmeasured and read as paint: their color is their mean albedo (or, for a row the scheme names in looks, its look
-- measured in the game: a target aims at looks, and a mean albedo reads lighter than the part shows), never darkened
-- as metal (the camo rows carry a
-- metallic bias of up to 4.2 that only shows on worn edges). A camo row carries copy = true (the rows taking it copy
-- its colors and camo, src/recolor.lua).
function Schemes.item(Matcher, Colour, colour, scheme, lut)
    local rows = {}
    for _, role in ipairs(Schemes.roles(scheme)) do
        local r = role[1]
        if r < lut.height then
            local _, _, _, _, camo, mode, _, ar, ag, ab = colour.row_info(lut.values, lut.width, r)
            local L, a, b = Colour.linear_to_lab(ar, ag, ab)
            local look = scheme.looks and scheme.looks[r] -- a look measured in the game (SEAF)
            if look then L, a, b = look[1], look[2], look[3] end
            rows[#rows + 1] = {key = scheme.lut .. ':' .. r, lut = scheme.lut, row = r, area = role[2],
                               under = role[3], L = L, a = a, b = b, metal = false, camo = camo, mode = mode,
                               full = false, ar = ar, ag = ag, ab = ab, copy = camo or nil}
        end
    end
    return Matcher.item(rows, true, nil, nil)
end

-- Runs once per scheme and job: interpreted (it must not add traces to the LuaJIT code cache every mod shares).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Schemes.get, Schemes.roles, Schemes.role_keys, chroma, dark, accent, hard, clothing, coverage, before,
                         lead_rows, tally, inventory, hard_role, soft_role, row_role, flat, role_color, map_group_roles, map_lenses,
                         with_options, cape_balanced, Schemes.metal_second,
                         Schemes.role_plan, apart, cape_keys, Schemes.plan, Schemes.item}) do
        jit.off(fn, true)
    end
end

return Schemes
