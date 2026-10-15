-- Match Your Colors: an armor never left in one color (v1.5). The user's rule (2026-10-14): "armors should not _ever_
-- be dominated entirely by a single color. No matter the circumstance, there should always be secondary and accenting
-- colors", and they should match the source ("I fear certain colors will clash harshly"): from the source's palette
-- first, a tone of its main color when it has one, the armor's own accent only when it already matches the source. The
-- SA-25 Steel Trooper took one helmet color on 94-100% of its paint for every helmet, plates, coat, undersuit and its
-- prosthetic arm alike (end-user report 2026-10-14).
--
-- An armor's plan (Matcher.plan; the cape split, src/schemes.lua) is dominated when one design color (a source color,
-- or a target group's own) covers DOMINANT_SHARE of the paint that shows and less than SECOND_MIN of it reads apart
-- from that color (CIE76 >= APART). Then that color's rows take roles: hard armor parts and a coat keep it; clothing
-- (soft rows of undergarment pieces) takes the secondary; gear (small soft armor parts, hard parts of undergarment
-- pieces) the dark; colored trims the accent; and while still too little reads apart, the darkest main parts up to
-- DARKEST_SHARE take the darker of secondary and dark. The secondary is always a color of the source: a source with no
-- muted color of its own covering SECOND_MIN_SHARE of it apart from that color leaves the plan as made (user, independent
-- review 1 2026-10-14: a muted shade of the accent's hue "seems to come from nowhere", the published look was better: the
-- PH-9 Predator's red beret gave clothing a dusty pink, a lemon cape an olive; the GS-17 Frontier Marshal's 6.5% tan face
-- mask dressed a whole B-01 Tactical in mustard). A prosthetic limb (PROSTHETIC_LUTS) is no plate: on every armor plan
-- it takes the source's dark muted color, else keeps its own. Mirrored in research/match12.py balance. Nothing here runs
-- per frame.
local Variety = {}

local de2000, palette_of, source_accent, identity, is_structure, ACCENT_C, MAIN_COLOR
-- Set once with the matcher's functions and constants (src/addon.lua and the tests, after Matcher.use).
function Variety.attach(Matcher, colour)
    de2000 = colour.de2000
    palette_of, source_accent, identity = Matcher.palette_of, Matcher.source_accent, Matcher.identity
    is_structure, ACCENT_C, MAIN_COLOR = Matcher.is_structure, Matcher.ACCENT_C, Matcher.MAIN_COLOR
    Matcher.balance = Variety.balance
end

Variety.DOMINANT_SHARE, Variety.SECOND_MIN, Variety.APART = 0.85, 0.10, 15.0
-- a coat: a LUT whose soft rows outside undergarment pieces show on this share of the paint; the darkest main parts
-- re-colored at most; the smallest source color an accent may come from; the armor's own accent kept within KEEP_DE
-- (CIEDE2000) of the source
Variety.COAT_SHARE, Variety.DARKEST_SHARE, Variety.ACCENT_MIN_SHARE = 0.10, 0.25, 0.005
Variety.KEEP_DE = 8.0
-- the smallest share of the source a secondary may come from (user, review 1 2026-10-14); a dark neutral one (black,
-- dark grey: look under DARK_NEUTRAL_L, model chroma under DARK_NEUTRAL_C) from DARK_SECOND_SHARE: black clothing is no
-- color from nowhere, and the CE-74 Breaker's black (7.7%) keeps the SA-25 Steel Trooper's undersuit black (the ticket)
Variety.SECOND_MIN_SHARE, Variety.DARK_SECOND_SHARE = 0.10, 0.05
Variety.DARK_NEUTRAL_L, Variety.DARK_NEUTRAL_C = 35.0, 8.0
-- an armor of one row over this share of what shows is left as planned (a row takes one color)
Variety.ROW_MAX = 0.90
-- a role color's row keeps at most this much of its lightness offset from its group (src/schemes.lua ROLE_TONE)
Variety.ROLE_TONE, Variety.TONE_UP = 6.0, 2.0
-- the prosthetic arm and leg of the SA-12 Servo-Assisted, SA-25 Steel Trooper and SA-32 Dynamo (Steam build 25480438)
Variety.PROSTHETIC_LUTS = {['5789f549cead6c3d'] = true}
-- a dark muted source color a prosthetic takes: under this lightness (look)
Variety.PROSTHETIC_DARK_L = 40.0

local function chroma(a, b) return math.sqrt(a * a + b * b) end
local function apart(x, y)
    local dL, da, db = x.L - y.L, x.a - y.a, x.b - y.b
    return dL * dL + da * da + db * db >= Variety.APART * Variety.APART
end
-- A source group's color as goals aim at it (a cape's look: src/matcher.lua gL).
local function color_of(g) return {L = g.gL or g.L, a = g.ga or g.a, b = g.gb or g.b, g = g} end
local function muted(g) return chroma(g.ma, g.mb) < ACCENT_C end

-- The plan's colors over what shows, by row in group then row order: {row, group, key (its source, a tone of it by
-- role, or its group's index when kept), L, a, b, share}.
local function cell_of(plan, g, gi, row, paint_area)
    local m, share = plan[row.key], row.area / paint_area
    if not m then return {row = row, group = g, key = gi, L = row.L, a = row.a, b = row.b, share = share} end
    local key = m.tone and m.source .. '/' .. m.tone or m.source
    return {row = row, group = g, key = key, L = m.L, a = m.a, b = m.b, share = share}
end
function Variety.cells(plan, t)
    local cells = {}
    for gi, g in ipairs(t.groups) do
        for _, row in ipairs(g.rows) do
            if row.area > 0 then cells[#cells + 1] = cell_of(plan, g, gi, row, t.paint_area) end
        end
    end
    return cells
end

-- The share of cells apart from color `mean`.
local function distinct_of(cells, mean)
    local distinct = 0.0
    for _, c in ipairs(cells) do if apart(c, mean) then distinct = distinct + c.share end end
    return distinct
end

-- The dominant design color of cells: its key, share and mean color (by share), and the share apart from it; nil when
-- nothing shows.
function Variety.dominance(cells)
    local by, order = {}, {}
    for _, c in ipairs(cells) do
        local d = by[c.key]
        if not d then
            d = {key = c.key, share = 0.0, L = 0.0, a = 0.0, b = 0.0}
            by[c.key], order[#order + 1] = d, d
        end
        d.share, d.L, d.a, d.b = d.share + c.share, d.L + c.share * c.L, d.a + c.share * c.a, d.b + c.share * c.b
    end
    local top
    for _, d in ipairs(order) do if not top or d.share > top.share then top = d end end
    if not top or top.share <= 0 then return nil end
    local mean = {L = top.L / top.share, a = top.a / top.share, b = top.b / top.share}
    return top.key, top.share, mean, distinct_of(cells, mean)
end

-- A tone of color c: dL lighter (darker when negative; the other way when that leaves 12 to 90), chroma times k.
local function tone(c, dL, k)
    local L = c.L + dL
    if L < 12 or L > 90 then L = c.L - dL end
    return {L = math.min(math.max(L, 12), 90), a = c.a * k, b = c.b * k, derived = true}
end

-- The source's secondary and dark colors for main color `main`: its largest muted palette color apart from main
-- covering SECOND_MIN_SHARE of it (DARK_SECOND_SHARE a dark neutral) (a vivid color on clothing is the agreed vivid guard's case: the PH-9 Predator's red
-- beret, 42% of it, turned whole armors red; vivid colors reach trims as the accent; no bare metal either, as cloth never
-- turns into metal: the Cowboy Hat's 7% silver badge made the B-01 Tactical's jacket light grey, review renders
-- 2026-10-14), else none (nil: the plan stays as made); and its darkest muted palette color apart from main (its
-- structure counting, any share), else a tone of main 25 L darker (6 on a dark main) at a third of the chroma.
local function second_share(g, c)
    if c.L < Variety.DARK_NEUTRAL_L and chroma(g.ma, g.mb) < Variety.DARK_NEUTRAL_C then
        return Variety.DARK_SECOND_SHARE
    end
    return Variety.SECOND_MIN_SHARE
end
local function palette_second_dark(source, main)
    local second, dark
    for _, g in ipairs(palette_of(source)) do
        local c = color_of(g)
        if g ~= main.g and not g.hood and muted(g) and apart(c, main) then
            if not second and not g.rep.metal and g.share >= second_share(g, c)
                and (source.suit_paint or not is_structure(g)) then
                second = c
            end
            if not dark or c.L < dark.L then dark = c end
        end
    end
    return second, dark
end
local function second_and_dark(source, main)
    local second, dark = palette_second_dark(source, main)
    if not second then return nil end
    return second, dark or tone(main, main.L >= 40 and -25 or -6, 0.33)
end

-- The source's accent for main and second: its accent (Matcher's source_accent) apart from both, else its most
-- saturated color of ACCENT_MIN_SHARE or more apart from both (chroma x sqrt(share)), else nil.
local function accent_of(source, main, second)
    local a = source_accent(source)
    if a and a ~= main.g then
        local c = color_of(a)
        if apart(c, main) and apart(c, second) then return c end
    end
    local best, score = nil, -1.0
    for _, g in ipairs(source.groups) do
        local c = color_of(g)
        local s = chroma(g.ma, g.mb) * math.sqrt(g.share)
        if g ~= main.g and not g.hood and g.share >= Variety.ACCENT_MIN_SHARE and apart(c, main) and apart(c, second)
            and s > score then
            best, score = c, s
        end
    end
    return best
end

-- Whether target group g's own color matches a color of the source's palette (CIEDE2000 under KEEP_DE).
local function matches_palette(g, source)
    for _, p in ipairs(palette_of(source)) do
        local c = color_of(p)
        if de2000(g.L, g.a, g.b, c.L, c.a, c.b) < Variety.KEEP_DE then return true end
    end
    return false
end

-- The LUTs whose soft rows outside undergarment pieces show on COAT_SHARE of the paint (a coat: main, not gear).
local function coats_of(cells)
    local share, out = {}, {}
    for _, c in ipairs(cells) do
        local row = c.row
        if row.mode >= 0.5 and row.under < 0.5 * row.area then share[row.lut] = (share[row.lut] or 0.0) + c.share end
    end
    for lut, s in pairs(share) do out[lut] = s >= Variety.COAT_SHARE end
    return out
end

-- A cell's role on a dominated armor: 'accent' (a colored trim), 'main' (hard armor parts, a coat), 'second'
-- (clothing) or 'dark' (gear).
local function role_of(c, coats)
    local g, row = c.group, c.row
    if chroma(g.ma, g.mb) >= ACCENT_C and g.share < MAIN_COLOR then return 'accent' end
    local under = row.under >= 0.5 * row.area
    local hard = row.mode < 0.5
    if not under and (hard or coats[row.lut]) then return 'main' end
    if under and not hard then return 'second' end
    return 'dark'
end

-- Row c.row takes role color `color` (kind: 'pair' or 'accent'): its goal the color with its own lightness offset
-- from its group (at most ROLE_TONE), through its own response; source: the color's source row, else main_key (a tone
-- of the main color: goal.tone names its role).
local function assign(plan, c, color, kind, main_key, role)
    local row = c.row
    local up = color.derived and Variety.TONE_UP or Variety.ROLE_TONE -- a tone stays the tone it was made
    local offset = math.max(-Variety.ROLE_TONE, math.min(up, row.L - c.group.L))
    local L = color.L + offset
    plan[row.key] = {source = color.g and color.g.rep.key or main_key, kind = kind, L = L, a = color.a, b = color.b,
                     cal = row.cal, tone = color.derived and role or nil}
    c.L, c.a, c.b = L, color.a, color.b
end

-- Prosthetic rows (every armor plan): the source's darkest muted color under PROSTHETIC_DARK_L, else their own.
local function prosthetics(plan, cells, source)
    local dark
    for _, g in ipairs(palette_of(source)) do
        local c = color_of(g)
        if not g.hood and muted(g) and c.L < Variety.PROSTHETIC_DARK_L and (not dark or c.L < dark.L) then dark = c end
    end
    for _, c in ipairs(cells) do
        if Variety.PROSTHETIC_LUTS[c.row.lut] then
            if dark then
                assign(plan, c, dark, 'pair', dark.g.rep.key, 'prosthetic')
            else
                plan[c.row.key] = nil
                c.L, c.a, c.b = c.row.L, c.row.a, c.row.b
            end
        end
    end
end

-- The darkest of cells, up to DARKEST_SHARE of the paint (the darkest one alone up to half of it: the B-01 Tactical's
-- jacket is one row), take `color` (role: its tone's name).
local function darken(plan, cells, color, main_key, role)
    table.sort(cells, function(x, y)
        if x.row.L ~= y.row.L then return x.row.L < y.row.L end
        return x.row.key < y.row.key
    end)
    local taken = 0.0
    for _, c in ipairs(cells) do
        if taken + c.share > (taken == 0 and 0.5 or Variety.DARKEST_SHARE) then break end
        assign(plan, c, color, 'pair', main_key, role)
        taken = taken + c.share
    end
end

-- Whether a plan's dominance (Variety.dominance) leaves it in one color.
local function dominated(key, share, distinct)
    return key ~= nil and share >= Variety.DOMINANT_SHARE and distinct < Variety.SECOND_MIN
end

-- Still dominated by a role color (the B-01 Tactical is mostly clothing: its secondary covered 86% with the O-2 Heavy
-- Operator): the darkest cells of that color take the first of `colors` reading apart from it, else a tone of it.
local function settle(plan, t, colors, main_key)
    local cells = Variety.cells(plan, t)
    local key, share, mean, distinct = Variety.dominance(cells)
    if not dominated(key, share, distinct) then return end
    local pick = tone(mean, mean.L >= 45 and -18 or 15, 0.5)
    for i = #colors, 1, -1 do
        if apart(colors[i], mean) then pick = colors[i] end
    end
    local list = {}
    for _, c in ipairs(cells) do
        if c.key == key and not Variety.PROSTHETIC_LUTS[c.row.lut] then list[#list + 1] = c end
    end
    if pick then darken(plan, list, pick, main_key, 'settle') end
end

-- The dominant color of armor t's plan, as given (a prosthetic counts as the color it was given) and as the prosthetic
-- rule leaves it: its cells, key and mean, or nil when the plan is not dominated.
local function dominant(plan, t, s)
    local cells = Variety.cells(plan, t)
    local key, share, mean, distinct = Variety.dominance(cells)
    prosthetics(plan, cells, s)
    if not dominated(key, share, distinct) then
        cells = Variety.cells(plan, t)
        key, share, mean, distinct = Variety.dominance(cells)
        if not dominated(key, share, distinct) then return nil end
    end
    return cells, key, mean
end

-- Whether one row shows on more than ROW_MAX of the armor (it cannot be split: a dark armor of one row).
local function one_row(cells)
    for _, c in ipairs(cells) do if c.share > Variety.ROW_MAX then return true end end
    return false
end

-- The role colors of a dominated plan (key, mean: Variety.dominance's): {main, main_key, second, dark, accent}; nil when
-- the source has no secondary of its own.
local function role_colors(s, key, mean)
    local main_g
    for _, g in ipairs(s.groups) do if g.rep.key == key then main_g = g end end
    local main = {L = mean.L, a = mean.a, b = mean.b, g = main_g}
    local second, dark = second_and_dark(s, main)
    if not second then return nil end
    return {main = main, main_key = type(key) == 'string' and key or (identity(s) or s.groups[1]).rep.key,
            second = second, dark = dark, accent = accent_of(s, main, second)}
end

-- A colored trim's cell: the accent; else its own color when it already matches the source; else a tone of main.
local function accent_cell(plan, c, k, s)
    if k.accent then return assign(plan, c, k.accent, 'accent', k.main_key, 'accent') end
    if matches_palette(c.group, s) then
        plan[c.row.key] = nil
        c.L, c.a, c.b = c.row.L, c.row.a, c.row.b
        return
    end
    assign(plan, c, tone(k.main, k.second.L > k.main.L and -25 or 25, 1.0), 'accent', k.main_key, 'accent')
end

-- One cell of the dominant color in its role (role_of; k: role_colors); returns the role.
local function play_role(plan, c, coats, k, s)
    local role = role_of(c, coats)
    if role == 'second' or role == 'dark' then
        assign(plan, c, k[role], 'pair', k.main_key, role)
    elseif role == 'accent' then
        accent_cell(plan, c, k, s)
    end
    return role
end

-- Too little apart after the roles: the darkest main parts take the darker of secondary and dark reading apart from
-- main, else the secondary when it does (a charcoal of a black does not: then nothing).
local function shade(plan, cells, roles, k)
    local darker = k.second.L < k.dark.L and k.second or k.dark
    local pick = apart(darker, k.main) and darker or apart(k.second, k.main) and k.second or nil
    if not pick then return end
    local mains = {}
    for i, c in ipairs(cells) do if roles[i] == 'main' then mains[#mains + 1] = c end end
    darken(plan, mains, pick, k.main_key, 'shade')
end

-- The plan of armor item t against source s (Matcher.plan's, or the cape split's), balanced in place (see above).
-- Returns plan and whether it was dominated. A source without colors gives none to balance with: the armor keeps its
-- own, as in v1.4 (a v1.4 analysis of the Cowboy Hat had no rows and its plan failed here, review renders 2026-10-14).
function Variety.balance(plan, t, s)
    if not (s.groups and s.groups[1]) then return plan, false end
    local cells, key, mean = dominant(plan, t, s)
    if not cells then return plan, false end
    if one_row(cells) then return plan, true end
    local k = role_colors(s, key, mean)
    if not k then return plan, true end -- no color of the source to balance with: as made
    local coats, roles = coats_of(cells), {}
    for i, c in ipairs(cells) do
        if c.key == key and not Variety.PROSTHETIC_LUTS[c.row.lut] then roles[i] = play_role(plan, c, coats, k, s) end
    end
    if distinct_of(cells, mean) < Variety.SECOND_MIN then shade(plan, cells, roles, k) end
    for _ = 1, 2 do settle(plan, t, {k.dark, k.main, k.second}, k.main_key) end -- a second color may take the lead once
    return plan, true
end

if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Variety.attach, chroma, apart, color_of, muted, cell_of, Variety.cells, distinct_of,
        Variety.dominance, tone, second_share, palette_second_dark, second_and_dark, accent_of, matches_palette, coats_of, role_of,
        assign, prosthetics, darken, dominated, settle, dominant, one_row, role_colors, accent_cell, play_role, shade,
        Variety.balance}) do
        jit.off(fn, true)
    end
end

return Variety
