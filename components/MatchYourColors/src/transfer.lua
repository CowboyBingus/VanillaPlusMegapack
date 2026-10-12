-- Match Your Colors: the color transfer of matcher v11.1 (research/match11.py recolor_row): a target LUT row takes
-- a desired perceived color and keeps its own material.
--
-- Only colors change: the base color (column 0), the detail and wear colors (2, 5, 6) and, on camo rows, the camo
-- colors (16-19). They follow the row's paint (the CIELAB of its mean albedo) to a new paint color:
--   * tint: on a saturated paint, the colors of its hue family rotate with its hue and scale with its chroma;
--   * shade: on a saturated paint, the neutral colors near it shift their lightness and stay neutral;
--   * shift: on a neutral paint, the colors near it take its CIELAB change;
--   * tone: toward a neutral target, every following color takes the target's tone;
--   * flat: an accent band's row (goal.band: the accent's paint, src/matcher.lua) is one coat of it, every following
--     color the new paint color (apply);
--   * the rest stay (bare metal, dirt, painted details of another hue), except under a flat role color (a paint
--     scheme's material roles: all_rule), where every colored color takes the target's hue ('hue'; 'own' off a
--     neutral paint: its own lightness).
-- The new paint color is fitted in at most FIT_STEPS steps so the row's perceived color (src/colour.lua) reaches
-- the desired one (toward a neutral target only its lightness is fitted); the best step is kept. Mode, detail
-- layer and controls, metallic, specular, roughness, camo controls, tiling and every w channel stay the target's.
-- (v1.0 copied whole rows, material included; v11.0 moved every color by one CIELAB offset, which turned a neutral
-- detail color teal when a red paint went neutral.) Nothing here runs per frame.
local Transfer = {}

Transfer.CLOSE_DE = 20.0
Transfer.FIT_STEPS = 8
Transfer.FIT_DONE = 0.5
Transfer.TINT_C = 8.0          -- a paint at least this saturated is re-tinted by hue rotation and chroma scaling
Transfer.TINT_HUE = 60.0       -- degrees: colors of the paint's hue family follow its tint
Transfer.NEUTRAL_C = 8.0       -- colors below this chroma (and half the paint's) are neutral
Transfer.CHROMA_HEADROOM = 10.0 -- the fitted paint's chroma stays within 1.5 x the desired chroma + this
-- Color columns: base, detail, wear (2), camo (4); index into row_values = column * 4 + channel + 1.
local COLUMNS = {0, 2, 5, 6, 16, 17, 18, 19}
local CAMO_FIRST = 5 -- COLUMNS index of column 16
local sqrt, atan2, deg, cos, sin = math.sqrt, math.atan2, math.deg, math.cos, math.sin

local function chroma(a, b) return sqrt(a * a + b * b) end

-- The angle between two hues in degrees (0-180).
local function hue_gap(a1, b1, a2, b2)
    local d = math.abs(deg(atan2(b1, a1) - atan2(b2, a2))) % 360.0
    return d > 180.0 and 360.0 - d or d
end

-- The rule of one color (lab = {L, a, b}) for paint P: 'tint', 'hue' (a camo color of another hue), 'shade',
-- 'shift' or nil (it stays).
local function rule_of(i, lab, P, chromatic, neutral_below, de2000)
    local near = i >= CAMO_FIRST or de2000(lab[1], lab[2], lab[3], P[1], P[2], P[3]) < Transfer.CLOSE_DE
    local neutral = chroma(lab[2], lab[3]) < neutral_below
    if chromatic and not neutral then
        if hue_gap(lab[2], lab[3], P[2], P[3]) <= Transfer.TINT_HUE then return 'tint' end
        -- a camo color of another hue takes the new hue (a rigid turn sent the TG-8 Sharpshooter's brown camo, 55
        -- degrees, to purple when its olive turned the UF-50 Bloodhound's maroon; user 2026-10-07)
        return i >= CAMO_FIRST and 'hue' or nil
    end
    if not near then return nil end
    if neutral and chromatic then return 'shade' end
    return 'shift'
end

-- Camo colors (COLUMNS CAMO_FIRST to count) take the target's hue (their chroma scaled with the paint's; on a neutral
-- paint the target's tone), their lightness offsets kept: shades of the new color. Turned rigidly or shifted, a green
-- camo became lime and lavender with a yellow-green cape and cyan and lilac with the SEAF blue (image review
-- 2026-10-09; research match11.py CAMO_FAMILY). Under a flat role color (all) they are shades at CAMO_FLAT of their
-- lightness offsets in the target's color ('camo'), and so is the camo row's base, which shows between them (a neutral
-- base scaled by chroma stayed grey): SEAF plates are plain, and the
-- SA-12 Twigsnapper's plates kept their light grey base (0.77) as white splashes on blue (independent image reviews
-- 2026-10-09, rounds 8 and 9).
Transfer.CAMO_FLAT = 0.25
local function camo_rules(rules, count, chromatic, all)
    for i = CAMO_FIRST, count do rules[i] = all and 'camo' or chromatic and 'hue' or 'tone' end
    if all and count >= CAMO_FIRST then rules[1] = 'camo' end
end

-- A flat role color (goal.all: a paint scheme's material roles, src/schemes.lua): every colored color of the row
-- follows the goal's hue, none stays and none turns rigidly ('tint' of a color off the paint's hue sent the PH-9
-- Predator's olive wear to magenta under the SEAF blue; kept detail and wear colors left rust flecks and brown straps,
-- image review 2026-10-09). The base keeps its rule; a neutral color stays as it would.
local function all_rule(i, rule, lab, chromatic, neutral_below)
    if i == 1 or chroma(lab[2], lab[3]) < neutral_below then return rule end
    if rule == 'tint' or rule == 'hue' or not rule then return chromatic and 'hue' or 'own' end
    return rule
end

-- The rule of COLUMNS index i (lab: its CIELAB) for paint P; ctx: {chromatic, neutral_below, de2000, all}.
local function column_rule(i, lab, P, ctx)
    local rule = rule_of(i, lab, P, ctx.chromatic, ctx.neutral_below, ctx.de2000)
    if not rule and ctx.darken and chroma(lab[2], lab[3]) < ctx.neutral_below then
        rule = ctx.chromatic and 'shade' or 'shift'
    end
    if i == 1 and not rule then rule = ctx.chromatic and 'tint' or 'shift' end -- the base always follows its paint
    if ctx.all then rule = all_rule(i, rule, lab, ctx.chromatic, ctx.neutral_below) end
    return rule
end

-- A paint that darkens by DARKEN_FOLLOW_L or more (the desired L under the paint's albedo L by that much) takes its
-- neutral detail and wear colors along ('shift', or the target's tone), not only those near it: a cream helmet shell
-- matched to a black armor kept its grey detail color (L 45) while the fit drove its base to black (the IX-VOIDWALKER
-- on the B-01 Tactical; independent image review 2026-10-09; research/match11.py DARKEN_FOLLOW_L).
Transfer.DARKEN_FOLLOW_L = 30.0

-- A light glossy paint turned dark takes the finish of the dark paint it matches (dark_finish): a hard paint row (not
-- cloth, not metal) whose paint darkens by DARKEN_FOLLOW_L or more to a desired L under DARK_L takes the roughness
-- (column 10 x) of its pair's source row when that row is a hard paint too and rougher. The game finishes its dark
-- paints matte (hard rows of at least 0.15 of an item: roughness median 0.67 under L 25, 0.20 over L 50; the B-01
-- Tactical's black 0.70), and a white enamel shell turned black kept its gloss (0.20): its scuffed roughness texture
-- then reflects the light as a grey-white marbled grime (the IX-VOIDWALKER on the B-01; independent image reviews
-- 2026-10-09, rounds 12 to 15). No color removes it (black wear, detail, sheen: no change in the game); the shell at
-- roughness 0.6 showed none (research/scratch/dark-band/live_row_variants.py). 3,102 of 42,660 plans have such a row
-- (8,423 rows; dark_rough_scan.lua). Flat role colors (paint schemes) keep their finish. Such a row is fitted through
-- its response's gain without its gloss floor, at the goal less that gloss (Transfer.diffuse_goal): the floor was
-- taken at the row's own gloss, whose reflections alone showed a black shell at about L 32 (the IX-VOIDWALKER's floor
-- 0.072), so the fit drove its color to black and, matte, it read pitch black (user 2026-10-09: the CW-36 Winter
-- Warrior and CM-21 Trench Paramedic helmets on the B-01 Tactical "way too dark relative to the armor"). Through the
-- model instead (2026-10-09 to 10) the paint took the diffuse color itself, darker than its source's paint by the
-- source's gain: a white glossy B-01 Tactical helmet got L 28 for the CM-14 Physician's grey plates' L 37.
Transfer.DARK_L = 30.0

-- A row whose fit through its measured response misses the goal by RESPONSE_MISS (CIEDE2000) or more is fitted through
-- the model instead (apply): the response was measured at the row's own colors, and a goal it cannot reach lies where it
-- no longer holds. The I-44 Salamander's bare-metal plates (response 0.19) under the Light of Eternal Liberty cape's
-- yellow went to a base of L 98 at chroma 43 (misses of 12 to 16) and read a pale cream beside the cape (gallery
-- 2026-10-10; on screen chroma 35 against 60); through the model they take L 72 to 82 at chroma 51, the cape's hue.
-- Live variants (research/scratch/dark-band/live_cape13_variants.py) of such a saturated yellow read as the cape
-- (dE 9 against 27). 49 of the 1,697 sampled rows fitted through a response (tests/fixtures/transfers.lua) miss by 6
-- or more; under the model 0 of 177 do.
Transfer.RESPONSE_MISS = 6.0

-- A fit through the response toward a colored goal (chroma NEUTRAL_GOAL_C or more) under the response's floor (the look
-- of black paint through it, its gloss and sheen, lighter than the goal) whose paint (of chroma NEUTRAL_GOAL_C or more:
-- a black paint's hue is noise) turns FLOOR_TURN degrees or more from the goal's hue is done again through the model
-- too (apply, refit): the response reaches such a goal only by cancelling
-- its floor's cast, with a paint of another hue, and the detail colors that follow the paint show that hue. The UF-16
-- Inspector's red sleeve under cape 92762946's navy (goal L 17.4 a -3.8 b -10.4, floor L 19.2) took a near-black paint
-- of hue 296 (L 0.8 a 4.2 b -8.6) and read purple beside the navy gloves (gallery 2026-10-11, case 33); through the model
-- it read the gloves' navy (paint L 10 a 0.7 b -12.5), and at the goal itself, its sheen kept, a lighter teal
-- (research/scratch/dark-band/live_under_floor_variants.py). 33 of the 7,157 under-floor (row, goal) pairs of every
-- helmet, armor and cape match are refitted so (research/scratch/dark-band/gate_scan.lua).
Transfer.FLOOR_TURN = 30.0

-- The goal a fit through the model aims at (apply: the dark finish, a missed response): the plan's goal less the gloss
-- the row's measured response shows at it, weighed as Colour.seen weighs it on hard paint, else the goal. The plan's
-- goal counts the target's own highlights (src/matcher.lua floor_goal); through the model they would turn into paint.
-- An accent band's goal is a paint already (goal.band).
function Transfer.diffuse_goal(Colour, goal)
    local cal = goal.cal
    if not cal or goal.band then return goal.L, goal.a, goal.b end
    local w = math.min(math.max(1 - chroma(goal.a, goal.b) / Colour.GLOSS_C, 0), 1)
    local r, g, b = Colour.lab_to_linear(goal.L, goal.a, goal.b)
    return Colour.linear_to_lab(math.max(r - w * cal[4], 0), math.max(g - w * cal[5], 0), math.max(b - w * cal[6], 0))
end
local ROUGHNESS, METALLIC = 40, 27 -- offsets in a row's values: column 10 x, column 6 w

-- Whether the row at offset o of v is cloth or metal (src/colour.lua: cloth is mode 1 with column 8 x near 0). A
-- row_values table is v with o = 1.
local function not_paint(v, o)
    return (math.abs(v[o + 3] - 1) < 0.5 and math.abs(v[o + 32]) < 0.05) or v[o + METALLIC] > 0.5
end

-- The roughness row c (row_values) takes when fitted to goal (the dark finish above), or nil. source: the source
-- analysis (its luts) the goal's source row is in, or nil; paint_L(c): the lightness of c's paint (its mean albedo),
-- asked only of a candidate; dL: the goal's lightness less the row's own gloss (Transfer.diffuse_goal).
local function dark_finish(c, goal, source, paint_L, dL)
    if goal.kind ~= 'pair' or goal.all or not (source and goal.source) or dL >= Transfer.DARK_L then return nil end
    local lut, r = goal.source:match('^(%x+):(%d+)$')
    local spec = lut and source.luts[lut]
    if not spec or spec.width <= 10 then return nil end -- a cape's tint LUT has no finish columns
    local v, s = spec.values, tonumber(r) * spec.width * 4
    if not_paint(c, 1) or not_paint(v, s) or v[s + ROUGHNESS] <= c[1 + ROUGHNESS] then return nil end
    if paint_L(c) - dL < Transfer.DARKEN_FOLLOW_L then return nil end
    return v[s + ROUGHNESS]
end

-- rules (rules_of) toward the desired color D: a coat's every following color takes the paint ('flat'), a neutral
-- target's its tone.
local function whole_rules(rules, D, coat)
    if coat then
        for i in pairs(rules) do rules[i] = 'flat' end
    elseif chroma(D[2], D[3]) < Transfer.TINT_C then -- a neutral target: every following color takes its tone
        for i, rule in pairs(rules) do rules[i] = (rule == 'own' or rule == 'camo') and rule or 'tone' end
    end
    return rules
end

-- {COLUMNS index -> rule} for row c (row_values) with paint P and the desired color D; labs[i] gets each
-- following color's CIELAB. flat: true (a flat role color: all_rule) or 'coat' (an accent band: every following color
-- takes the paint, 'flat').
local function rules_of(c, P, D, labs, de2000, srgb_to_lab, flat)
    local all = flat == true
    local paint_c = chroma(P[2], P[3])
    local chromatic = paint_c >= Transfer.TINT_C
    local ctx = {chromatic = chromatic, de2000 = de2000, all = all,
                 neutral_below = chromatic and math.min(Transfer.NEUTRAL_C, 0.5 * paint_c) or Transfer.NEUTRAL_C,
                 darken = P[1] - D[1] >= Transfer.DARKEN_FOLLOW_L}
    local rules, count = {}, c[88] >= 0 and #COLUMNS or CAMO_FIRST - 1
    for i = 1, count do
        local o = COLUMNS[i] * 4
        local lab = {srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])}
        local rule = column_rule(i, lab, P, ctx)
        if rule then rules[i], labs[i] = rule, lab end
    end
    camo_rules(rules, count, chromatic, all)
    return whole_rules(rules, D, flat == 'coat')
end

-- A color's new CIELAB when the paint goes from P to T.
local function follow(lab, rule, P, T)
    if rule == 'shift' then return lab[1] + (T[1] - P[1]), lab[2] + (T[2] - P[2]), lab[3] + (T[3] - P[3]) end
    local L = lab[1] + (T[1] - P[1])
    if rule == 'tone' then return L, T[2], T[3] end
    if rule == 'flat' then return T[1], T[2], T[3] end
    if rule == 'tint' then
        local scale = chroma(T[2], T[3]) / chroma(P[2], P[3])
        local turn = atan2(T[3], T[2]) - atan2(P[3], P[2])
        local cc, h = chroma(lab[2], lab[3]) * scale, atan2(lab[3], lab[2]) + turn
        return L, cc * cos(h), cc * sin(h)
    end
    if rule == 'hue' then -- the target's hue, its own chroma scaled with the paint's
        local cc, h = chroma(lab[2], lab[3]) * chroma(T[2], T[3]) / chroma(P[2], P[3]), atan2(T[3], T[2])
        return L, cc * cos(h), cc * sin(h)
    end
    if rule == 'own' then -- off a neutral paint: its own lightness, the target's hue at no more than its own chroma
        local tc = chroma(T[2], T[3])
        local k = tc > 0 and math.min(1, chroma(lab[2], lab[3]) / tc) or 0
        return lab[1], T[2] * k, T[3] * k
    end
    if rule == 'camo' then -- a flat camo color: the target's color, CAMO_FLAT of its lightness offset
        return T[1] + Transfer.CAMO_FLAT * (lab[1] - P[1]), T[2], T[3]
    end
    return L, lab[2], lab[3] -- shade
end

-- A cloth row's sheen color (column 12 RGB of a soft row: the SEAF uniform's is a neutral 0.15, the DS-191 Scorpion's
-- vest a brown 0.148 0.098 0.062 at 0.76) under a flat role color fitted without a response: the goal's hue at its own
-- lightness and no more than its own chroma, as 'own'. The model leaves the sheen out, so a fit to it keeps a brown
-- sheen on a black albedo: the Scorpion's vest, scarf and straps read brown as SEAF gear (round 8 renders, 2026-10-09).
-- A fit through a measured response already counts the row's sheen in it. c: row_values, written in place.
local SHEEN = 12
local function flat_sheen(c, a, b, srgb_to_lab, lab_to_srgb)
    if math.abs(c[4] - 1) >= 0.5 then return end
    local o = SHEEN * 4
    local lab = {srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])}
    c[o + 1], c[o + 2], c[o + 3] = lab_to_srgb(follow(lab, 'own', lab, {lab[1], a, b}))
end

-- T with its chroma at most 1.5 x the desired chroma + CHROMA_HEADROOM (no runaway compensation for colors
-- that stay); on bare metal (metallic > 0.5) at most the desired chroma. A metal's reflections take its paint's color
-- at full strength, so the eye reads the paint's chroma where its mean look is diluted by its dark parts: the CPR-80
-- Bulwark from the DP-8 Mountain-Scaled's dull navy (look chroma 9) got a paint of chroma 17 and turned deep blue on
-- screen (user 2026-10-06).
-- A goal of little color (under TINT_C) caps it the same way: its tint is fitted (Transfer.NEUTRAL_GOAL_C), never more
-- color than it asks (the B-24 Enforcer's leather from the GS-66 Lawmaker's silver, chroma 5.3, turned navy-purple).
local function cap_chroma(T, D, metal)
    local dc = chroma(D[2], D[3])
    local limit = (metal or dc < Transfer.TINT_C) and dc or dc * 1.5 + Transfer.CHROMA_HEADROOM
    local cc = chroma(T[2], T[3])
    if cc > limit then T[2], T[3] = T[2] * (limit / cc), T[3] * (limit / cc) end
    return T
end

-- Transfer.new(Colour, colour model, yield) -> {fit, fit_base, apply}. fit(c, L, a, b, cal, base_only, flat): c
-- (row_values) gets the fitted colors; returns the perceived color reached and its CIEDE2000 error. cal: the row's
-- measured response (matcher v12, src/appearance.lua): the fit then reaches the color the row shows in the game, else
-- the model color.
-- base_only: only the base color (column 0) moves (a cape's tint: the shader blends column 0 alone toward it). flat:
-- true, a flat role color (all_rule), or 'coat', every following color the new paint color (an accent band, apply).
-- yield (optional, a job's): called after every perceived-color evaluation (up to FIT_STEPS + 1 per row, each about
-- 0.07 ms outside the game), so a job can pause inside a row.
local function no_pause() end

-- Whether the fit toward goal (a, b) adjusts lightness only: a neutral goal (under NEUTRAL_GOAL_C, the matcher's own
-- neutral: src/matcher.lua NEUTRAL_TINT_C) fitted through the model. A goal of chroma 5 to 8 is a color the matcher
-- kept: at 8 the SC-30 Trailblazer Scout's coat took the AF-50 Noxious Ranger's olive (chroma 7.9) as its paint's tint
-- and its warm response turned it khaki on screen (hue 92 against the mask's 114; user 2026-10-10: "much lighter tint
-- than the helmet's green"); fitted, its paint compensates (hue 122, its look the goal's). A fit through a measured
-- response cancels the row's own cast toward a neutral goal too, its paint no more saturated than the goal
-- (cap_chroma): the B-24 Enforcer's coat (response R 1.08, B 0.87, a warm floor) took the black cape d79370cb's dark
-- as a paint of that dark's tint and read rust brown, L 40 a 6.7 b 10.4, beside its L 26 plates (gallery 2026-10-11);
-- a cape's cloth through its borrowed response already did (Drape of Glory's sheen cloth looked brown, image review
-- 2026-10-07).
Transfer.NEUTRAL_GOAL_C = 5.0
-- A bare-metal row (metallic > 0.5) the fit darkens keeps a paint of at least METAL_PAINT_MIN_L (its own when darker):
-- a darker metal shows its color only in its highlights and reads black. The CPR-80 Bulwark's steel under Red Planet's
-- Memory took paint L 31 for the cape's black: its mean look reached the goal (L 28 on screen against 27) but its median
-- pixel was L 8, "the helmet went pure black" beside the SR-18 Roadblock's grey plates (user 2026-10-11, gallery case 48).
-- The game's own kits paint 95% of their bare metal at L 47 or lighter (1,099 rows; the darkest, the PH-202
-- Twigsnapper's steel, L 34.6: research/scratch/dark-band/metal_paint_survey.lua); the B-22 Model Citizen's chrome
-- guards read as dark chrome at L 44-50 (2026-10-10).
Transfer.METAL_PAINT_MIN_L = 45.0
local function paint_floor(paint_L, metal)
    if not metal then return -math.huge end
    return math.min(paint_L, Transfer.METAL_PAINT_MIN_L)
end

local function neutral_goal(a, b, cal)
    return not cal and chroma(a, b) < Transfer.NEUTRAL_GOAL_C
end

-- The colors of row c (row_values) that rules move: {COLUMNS index -> {r, g, b}}.
local function colors_of(c, rules)
    local out = {}
    for i in pairs(rules) do
        local o = COLUMNS[i] * 4
        out[i] = {c[o + 1], c[o + 2], c[o + 3]}
    end
    return out
end

-- The row's own error against the goal: where a fit starts (a NaN goal is never reached: infinity).
local function own_error(de2000, pL, pa, pb, L, a, b)
    local err = de2000(pL, pa, pb, L, a, b)
    return err == err and err or math.huge
end

function Transfer.new(Colour, model, yield)
    local de2000, srgb_to_lab, lab_to_srgb = Colour.de2000, Colour.srgb_to_lab, Colour.lab_to_srgb
    local pause = yield or no_pause
    local self = {}

    -- The row's colors for paint color T (written into c).
    local function paint_with(c, rules, labs, P, T)
        for i, rule in pairs(rules) do
            local o = COLUMNS[i] * 4
            c[o + 1], c[o + 2], c[o + 3] = lab_to_srgb(follow(labs[i], rule, P, T))
        end
    end

    -- The look the fit reaches for row c: through its measured response cal, else the model. A matte soft row (cloth:
    -- mode 1, column 8 x at 0) counts its whole gloss floor (Colour.seen): the TG-8 Sharpshooter's cloth fitted to the
    -- UF-50 Bloodhound's red at L 22 looked salmon, its look L 29 (rendered check 2026-10-07). Also the same look from
    -- an albedo already computed for c.
    local function look_of(c, cal)
        if not cal then return model.perceived, model.perceived_of end
        local soft = math.abs(c[4] - 1) < 0.5 and math.abs(c[33]) < 0.05
        return function(x) return model.look(x, cal, soft) end,
            function(_, r, g, b) return model.look_of(r, g, b, cal, soft) end
    end

    -- Row c's own albedo r, g, b: c.own ({r, g, b}, set by apply from starts while c is the row as copied) or computed.
    local function own_albedo(c)
        local own = c.own
        if own then return own[1], own[2], own[3] end
        return model.albedo(c)
    end

    function self.fit(c, L, a, b, cal, base_only, flat)
        local all = flat == true
        local look, look_from = look_of(c, cal)
        local D = {L, a, b}
        -- the row's albedo, once for its paint's color and its first look (v1.3 computed its 512 samples twice)
        local r, g, bl = own_albedo(c)
        c.own = nil -- painted from here on
        local P = {Colour.linear_to_lab(r, g, bl)}
        local labs = {}
        local rules = rules_of(c, P, D, labs, de2000, srgb_to_lab, flat)
        if base_only then rules = {[1] = rules[1]} end
        local neutral = neutral_goal(a, b, cal)
        local metal = c[28] > 0.5 -- column 6 w: metallic (src/colour.lua)
        local floor = paint_floor(P[1], metal)
        local pL, pa, pb = look_from(c, r, g, bl)
        pause()
        local T = cap_chroma({math.max(P[1] + (L - pL), floor), P[2] + (a - pa), P[3] + (b - pb)}, D, metal)
        if neutral then T[2], T[3] = a, b end
        -- The row's own colors stand until a step is better: a fit never ends farther from the goal than the row
        -- started (v1.3: 126 of 1,865 sampled rows did, one from dE 0.44 to 2.38). A NaN goal is never reached: the
        -- row stays unchanged.
        local best, best_err, best_L, best_a, best_b = colors_of(c, rules), own_error(de2000, pL, pa, pb, L, a, b),
            pL, pa, pb
        for _ = 1, Transfer.FIT_STEPS do
            paint_with(c, rules, labs, P, T)
            local gL, ga, gb = look(c)
            local err = de2000(gL, ga, gb, L, a, b)
            if err < best_err then
                best_err, best_L, best_a, best_b, best = err, gL, ga, gb, colors_of(c, rules)
            end
            if err < Transfer.FIT_DONE then break end
            if neutral then
                T[1] = math.max(T[1] + (L - gL), floor)
            else
                T = cap_chroma({math.max(T[1] + (L - gL), floor), T[2] + (a - ga), T[3] + (b - gb)}, D, metal)
            end
            pause()
        end
        for i, color in pairs(best) do
            local o = COLUMNS[i] * 4
            c[o + 1], c[o + 2], c[o + 3] = color[1], color[2], color[3]
        end
        if all and not (cal or base_only) then flat_sheen(c, a, b, srgb_to_lab, lab_to_srgb) end
        return best_L, best_a, best_b, best_err
    end

    -- The base color (column 0 RGB) that brings LUT row `row` of values (width columns), with base `tint` ({r, g, b})
    -- instead of its own, to goal ({L, a, b, cal}: a plan's) when only the base moves: a cape's tint (src/capes.lua),
    -- which the shader blends into column 0 alone. Returns R, G, B and the error; values stay as they are.
    function self.fit_base(values, width, row, tint, goal)
        local c = Colour.row_values(values, width, row)
        c[1], c[2], c[3] = tint[1], tint[2], tint[3]
        local _, _, _, err = self.fit(c, goal.L, goal.a, goal.b, goal.cal, true)
        return c[1], c[2], c[3], err
    end

    local function paint_L(c) return (Colour.linear_to_lab(own_albedo(c))) end

    -- Rows' own albedos {r, g, b} per origin (the analysis LUT a row was copied from, Recolor.build_lut) and row, made
    -- from the row's unchanged values c: a plan fits the same target rows for every source it pairs (browsing armors
    -- refits the helmet's), and of a fit's 5.7 albedo evaluations the first is the row's own (2,524 of 2,658 rows
    -- fitted before, research/profiling/fit_census.lua; 2026-10-11). Weak keys: an analysis let go takes them along.
    local starts = setmetatable({}, {__mode = 'k'})
    local function start_of(origin, row, c)
        local rows = starts[origin]
        if not rows then
            rows = {}
            starts[origin] = rows
        end
        local s = rows[row]
        if not s then
            s = {model.albedo(c)}
            rows[row] = s
        end
        return s
    end

    -- Whether row c, fitted through response cal toward (L, a, b) with error err, is fitted again through the model: it
    -- missed by RESPONSE_MISS or more, or its paint (mean albedo) turned off a colored goal under the response's floor
    -- (Transfer.FLOOR_TURN).
    local function refit(c, cal, err, L, a, b)
        if err >= Transfer.RESPONSE_MISS then return true end
        if chroma(a, b) < Transfer.NEUTRAL_GOAL_C or Colour.linear_to_lab(cal[4], cal[5], cal[6]) <= L then return false end
        local _, pa, pb = Colour.linear_to_lab(model.albedo(c))
        return chroma(pa, pb) >= Transfer.NEUTRAL_GOAL_C and hue_gap(pa, pb, a, b) >= Transfer.FLOOR_TURN
    end

    -- Writes the fitted colors of LUT row `row` into values (float array, width columns); returns the error. goal: a
    -- plan's {L, a, b, cal, all (a flat role color: all_rule), band, kind, source}; source (optional): the source
    -- analysis (dark_finish: a light paint turned dark takes its source row's roughness and is fitted through the
    -- model). An accent band's row (goal.band: L, a, b the accent's paint, src/matcher.lua tint_bands) becomes one coat
    -- of that paint, fitted through the model: through its response, measured on its own color, the IX-VOIDWALKER's
    -- band (0.52, on navy) asked a base of L 96 for the B-01 Tactical's yellow and its detail colors followed the hue
    -- turn to lime and light grey; it read a pale butter yellow beside the armor's lemon (user 2026-10-10). Of seven
    -- live variants (research/scratch/dark-band/live_band_variants.py) the armor's paint on every color column matched
    -- it best; its own detail colors read dull and mottled, shades of the paint amber.
    -- A fit through the response that misses its goal by RESPONSE_MISS or more, or turns its paint off a colored goal
    -- under the response's floor (FLOOR_TURN), is done again through the model; a fit through the model aims at the goal
    -- less the row's own gloss (Transfer.diffuse_goal).
    -- What row c is fitted through and toward: cal, L, a, b. Through its response at the goal, else through the model
    -- at the goal less its gloss (dL, da, db); a row dark_finish made rough (a matte paint now) through its gain
    -- without its gloss floor, at the goal less that gloss.
    local function aim(goal, flat, rough, dL, da, db)
        local cal = flat ~= 'coat' and goal.cal or nil
        if not cal then return nil, dL, da, db end
        if rough then return {cal[1], cal[2], cal[3], 0, 0, 0}, dL, da, db end
        return cal, goal.L, goal.a, goal.b
    end

    -- Row c's fitted colors into values from `base` (its sheen too for a flat role color, and the roughness rough).
    local function write_row(values, base, c, goal, rough)
        for _, column in ipairs(COLUMNS) do
            local o = column * 4
            values[base + o], values[base + o + 1], values[base + o + 2] = c[o + 1], c[o + 2], c[o + 3]
        end
        if goal.all then
            local o = SHEEN * 4
            values[base + o], values[base + o + 1], values[base + o + 2] = c[o + 1], c[o + 2], c[o + 3]
        end
        if rough then values[base + ROUGHNESS] = rough end
    end

    -- origin (optional): the analysis LUT the row's values were copied from, unchanged (Recolor.build_lut): its own
    -- albedo is then kept per origin and row (starts) and given to the fit as c.own.
    function self.apply(values, width, row, goal, source, origin)
        local c = Colour.row_values(values, width, row)
        local start = origin and start_of(origin, row, c)
        c.own = start
        local flat = goal.all or goal.band and 'coat' or nil
        local dL, da, db = Transfer.diffuse_goal(Colour, goal)
        local rough = flat ~= 'coat' and dark_finish(c, goal, source, paint_L, dL)
        -- no longer the row as copied: its albedo computed (the same today: the albedo reads no roughness)
        if rough then c[1 + ROUGHNESS], c.own = rough, nil end
        local cal, L, a, b = aim(goal, flat, rough, dL, da, db)
        local _, _, _, err = self.fit(c, L, a, b, cal, nil, flat)
        if cal and refit(c, cal, err, L, a, b) then
            c = Colour.row_values(values, width, row)
            c.own = start
            _, _, _, err = self.fit(c, dL, da, db, nil, nil, flat)
        end
        write_row(values, row * width * 4, c, goal, rough)
        return err
    end

    return self
end

Transfer.COLUMNS = COLUMNS
-- Runs inside a job, a few dozen rows per plan: interpreted (the albedo loop it calls stays compiled).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({chroma, hue_gap, rule_of, camo_rules, all_rule, column_rule, rules_of, not_paint, dark_finish,
                         follow, flat_sheen, cap_chroma, no_pause, paint_floor, neutral_goal, colors_of, own_error,
                         Transfer.new}) do
        jit.off(fn, true)
    end
end

return Transfer
