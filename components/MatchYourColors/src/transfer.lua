-- Match Your Colors: the color transfer of matcher v11.1 (research/match11.py recolor_row): a target LUT row takes
-- a desired perceived color and keeps its own material.
--
-- Only colors change: the base color (column 0), the detail and wear colors (2, 5, 6) and, on camo rows, the camo
-- colors (16-19). They follow the row's paint (the CIELAB of its mean albedo) to a new paint color:
--   * tint: on a saturated paint, the colors of its hue family rotate with its hue and scale with its chroma;
--   * shade: on a saturated paint, the neutral colors near it shift their lightness and stay neutral;
--   * shift: on a neutral paint, the colors near it take its CIELAB change;
--   * tone: toward a neutral target, every following color takes the target's tone;
--   * the rest stay (bare metal, dirt, painted details of another hue).
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

-- {COLUMNS index -> rule} for row c (row_values) with paint P and the desired color D; labs[i] gets each
-- following color's CIELAB.
local function rules_of(c, P, D, labs, de2000, srgb_to_lab)
    local paint_c = chroma(P[2], P[3])
    local chromatic = paint_c >= Transfer.TINT_C
    local neutral_below = chromatic and math.min(Transfer.NEUTRAL_C, 0.5 * paint_c) or Transfer.NEUTRAL_C
    local rules, count = {}, c[88] >= 0 and #COLUMNS or CAMO_FIRST - 1
    for i = 1, count do
        local o = COLUMNS[i] * 4
        local lab = {srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])}
        local rule = rule_of(i, lab, P, chromatic, neutral_below, de2000)
        if i == 1 and not rule then rule = chromatic and 'tint' or 'shift' end -- the base always follows its paint
        if rule then rules[i], labs[i] = rule, lab end
    end
    if chroma(D[2], D[3]) < Transfer.TINT_C then -- a neutral target: every following color takes its tone
        for i in pairs(rules) do rules[i] = 'tone' end
    end
    return rules
end

-- A color's new CIELAB when the paint goes from P to T.
local function follow(lab, rule, P, T)
    if rule == 'shift' then return lab[1] + (T[1] - P[1]), lab[2] + (T[2] - P[2]), lab[3] + (T[3] - P[3]) end
    local L = lab[1] + (T[1] - P[1])
    if rule == 'tone' then return L, T[2], T[3] end
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
    return L, lab[2], lab[3] -- shade
end

-- T with its chroma at most 1.5 x the desired chroma + CHROMA_HEADROOM (no runaway compensation for colors
-- that stay); on bare metal (metallic > 0.5) at most the desired chroma. A metal's reflections take its paint's color
-- at full strength, so the eye reads the paint's chroma where its mean look is diluted by its dark parts: the CPR-80
-- Bulwark from the DP-8 Mountain-Scaled's dull navy (look chroma 9) got a paint of chroma 17 and turned deep blue on
-- screen (user 2026-10-06).
local function cap_chroma(T, D, metal)
    local limit = metal and chroma(D[2], D[3]) or chroma(D[2], D[3]) * 1.5 + Transfer.CHROMA_HEADROOM
    local cc = chroma(T[2], T[3])
    if cc > limit then T[2], T[3] = T[2] * (limit / cc), T[3] * (limit / cc) end
    return T
end

-- Transfer.new(Colour, colour model, yield) -> {fit, apply}. fit(c, L, a, b, cal, base_only): c (row_values) gets the
-- fitted colors; returns the perceived color reached and its CIEDE2000 error. cal: the row's measured response
-- (matcher v12, src/appearance.lua): the fit then reaches the color the row shows in the game, else the model color.
-- base_only: only the base color (column 0) moves (a cape's tint: the shader blends column 0 alone toward it). yield
-- (optional, a job's): called after every perceived-color evaluation (up to FIT_STEPS + 1 per row, each about
-- 0.07 ms outside the game), so a job can pause inside a row.
local function no_pause() end

-- Whether the fit toward goal (a, b) adjusts lightness only: a neutral goal, unless the row's response is a cape's
-- borrowed one (cal.hue: its cloth's own tint is cancelled, src/matcher.lua borrow_rows).
local function neutral_goal(a, b, cal)
    return chroma(a, b) < Transfer.TINT_C and not (cal and cal.hue)
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
    -- UF-50 Bloodhound's red at L 22 looked salmon, its look L 29 (rendered check 2026-10-07).
    local function look_of(c, cal)
        if not cal then return model.perceived end
        local soft = math.abs(c[4] - 1) < 0.5 and math.abs(c[33]) < 0.05
        return function(x) return model.look(x, cal, soft) end
    end

    function self.fit(c, L, a, b, cal, base_only)
        local look = look_of(c, cal)
        local D = {L, a, b}
        local P = {model.albedo_lab(c)}
        local labs = {}
        local rules = rules_of(c, P, D, labs, de2000, srgb_to_lab)
        if base_only then rules = {[1] = rules[1]} end
        local neutral = neutral_goal(a, b, cal)
        local metal = c[28] > 0.5 -- column 6 w: metallic (src/colour.lua)
        local pL, pa, pb = look(c)
        pause()
        local T = cap_chroma({P[1] + (L - pL), P[2] + (a - pa), P[3] + (b - pb)}, D, metal)
        if neutral then T[2], T[3] = a, b end
        -- The row's own colors stand until a step is better: a fit never ends farther from the goal than the row
        -- started (v1.3: 126 of 1,865 sampled rows did, one from dE 0.44 to 2.38). A NaN goal is never reached: the
        -- row stays unchanged.
        local best, best_err, best_L, best_a, best_b = {}, own_error(de2000, pL, pa, pb, L, a, b), pL, pa, pb
        for i in pairs(rules) do
            local o = COLUMNS[i] * 4
            best[i] = {c[o + 1], c[o + 2], c[o + 3]}
        end
        for _ = 1, Transfer.FIT_STEPS do
            paint_with(c, rules, labs, P, T)
            local gL, ga, gb = look(c)
            local err = de2000(gL, ga, gb, L, a, b)
            if err < best_err then
                best_err, best_L, best_a, best_b = err, gL, ga, gb
                for i in pairs(rules) do
                    local o = COLUMNS[i] * 4
                    best[i] = {c[o + 1], c[o + 2], c[o + 3]}
                end
            end
            if err < Transfer.FIT_DONE then break end
            if neutral then
                T[1] = T[1] + (L - gL)
            else
                T = cap_chroma({T[1] + (L - gL), T[2] + (a - ga), T[3] + (b - gb)}, D, metal)
            end
            pause()
        end
        for i, color in pairs(best) do
            local o = COLUMNS[i] * 4
            c[o + 1], c[o + 2], c[o + 3] = color[1], color[2], color[3]
        end
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

    -- Writes the fitted colors of LUT row `row` into values (float array, width columns); returns the error.
    function self.apply(values, width, row, L, a, b, cal)
        local c = Colour.row_values(values, width, row)
        local _, _, _, err = self.fit(c, L, a, b, cal)
        local base = row * width * 4
        for _, column in ipairs(COLUMNS) do
            local o = column * 4
            values[base + o], values[base + o + 1], values[base + o + 2] = c[o + 1], c[o + 2], c[o + 3]
        end
        return err
    end
    return self
end

Transfer.COLUMNS = COLUMNS
-- Runs inside a job, a few dozen rows per plan: interpreted (the albedo loop it calls stays compiled).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({chroma, hue_gap, rule_of, rules_of, follow, cap_chroma, no_pause, neutral_goal, own_error,
                         Transfer.new}) do
        jit.off(fn, true)
    end
end

return Transfer
