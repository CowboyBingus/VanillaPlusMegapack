-- Match Your Colors: matcher v12 (research/match12.py), the plan of which color each target LUT row takes.
-- v10's quality was proven on all 21,330 helmet x armor pairs per direction; v11 fixed what the 2026-10-05
-- playtest showed; v12 judges by what the Armory shows (the measured appearance, src/appearance.lua).
--
-- An item is one kit's rows: every LUT row of every piece material. A measured kit (src/appearance.lua: every LUT of
-- its rows measured on the Armory front view) weighs each row by its screen pixels and sees it as it looks there:
-- perceived = s + g x mean albedo per channel (its measured response). Any other kit (new since the measurement, or
-- another body's pieces) weighs rows by ID-mask area (piece weight x coverage / materials of the piece) and sees
-- them as the model color (mean albedo, metal darkened; v11.5). Lens/light rows (mode >= 2.5, and glowing paint:
-- Matcher.light) never change.
-- Rows are grouped by model color (CIEDE2000 < 6, same metal and camo class): one paint stays one design color even
-- where it looks lighter or darker; a group's color is its rows' perceived color, mean by pixels.
-- Classes go by the model color (the design's categories and the thresholds the user's reports validated): dark
-- neutrals mostly from undergarments are structure, they keep their color or take the source's nearest dark neutral;
-- saturated groups are accents. Every color value (identity, matches, lightness relations, offsets, the fit) is
-- perceived.
-- Anchor: a target paint group that already matches the source's identity color keeps it, else the largest paint
-- group of the identity's class (dark neutral or not) takes it, else the largest (an armor's identity color is its
-- most salient paint: undersuit area weighs 0.5 and dark neutrals DARK_SALIENCE, so the CM-09 Bonesnapper's cream
-- plates outweigh its green undersuit and the I-92 Fire Fighter's grey plates its tan padding).
-- The other groups are placed by a local search over the source colors (lightness and saturation relative
-- to the anchor, colors already matched, source proportions, light/dark contrast); a large target area
-- (share >= LARGE_AREA) takes only the source's main colors (share >= MAIN_COLOR) or one it already matches,
-- never a trim. A source's structure color (its undersuit) goes only to a small dark neutral target group or one
-- that already matches it, so no light, colored or large part turns undersuit black. Accents (saturated groups up to
-- ACCENT_MAX_SHARE, not the anchor, or any size below the pairing minimum) take the source's accent color (its most
-- salient visible saturated color, from 0.5% of its paint, among its color groups and its pattern colors), or keep
-- their own when they are dark, already match a source color or the source has none. A target pattern whose color
-- is an accent takes the source's accent the same way (Matcher.pattern_plan).
-- Each recolored row's desired color is its source color plus the row's own offset from its group;
-- src/transfer.lua then fits the row's colors to it (through its measured response when it has one) and keeps its
-- material. An unmeasured bare-metal row taking paint aims PAINT_REFLECTION more linear light in every channel
-- (v11.2: a paint reflects about 4% white light that bare metal does not); a measured row's perceived color already
-- shows how its metal looks.
-- Options (v1.3): Recolor Hoods off (Matcher.item's keep_hoods) groups a hooded helmet's hood rows apart and never
-- recolors them; they still count in the item's paint, so the other parts keep their shares and roles. Match
-- Materials (Matcher.plan's materials) turns a big hard metal part taking paint into that paint (painted).
--
-- Sums follow numpy's order (pairwise above 8 terms) or Python's (sequential) as match12.py, and sorts are stable,
-- so plans equal match12.py's. Nothing here runs per frame.
local Matcher = {}

-- The color functions (Colour.de2000, lab_to_linear, linear_to_lab, srgb_to_lab, srgb_to_linear, seen); set once by
-- Matcher.use before the first item.
local de2000, lab_to_linear, linear_to_lab, srgb_to_lab, srgb_to_linear, seen
function Matcher.use(colour)
    de2000, lab_to_linear, linear_to_lab = colour.de2000, colour.lab_to_linear, colour.linear_to_lab
    srgb_to_lab, srgb_to_linear, seen = colour.srgb_to_lab, colour.srgb_to_linear, colour.seen
end

local GROUP_DE = 6.0
local TGT_MIN_SHARE = 0.02
local PAIR_MIN_SHARE = 0.02
local KEEP_DE = 8.0
local ANCHOR_MIN_SHARE = 0.10
-- The weight of dark neutrals in an armor's identity: screen shares (measured) count them as they show; texture
-- shares overcount an armor's many small dark parts (straps, gloves, plate backs; v11.5).
local DARK_SALIENCE, DARK_SALIENCE_TEXTURE = 0.5, 0.25
local UNDER_SALIENCE = 0.5 -- an armor's undersuit area counts half in its identity: its plates define the look
local ACCENT_SMALL, ACCENT_VIVID = 0.10, 35.0 -- a muted accent is small; a larger or dark one must be vivid
local LARGE_AREA, MAIN_COLOR = 0.15, 0.10
local ACCENT_C, ACCENT_MAX_SHARE, ACCENT_MIN_L = 20.0, 0.35, 20.0
local SOURCE_ACCENT_MIN_L, SOURCE_ACCENT_MIN_SHARE = 30.0, 0.005
local SOURCE_ACCENT_MIN_SHARE_MEASURED = 0.001 -- screen share: the SR-64 Cinderblock's orange emblem shows 0.12%
local NEUTRAL_L, NEUTRAL_C = 35.0, 10.0
local LOOK_DARK_L = 30.0 -- a part looks dark below this perceived lightness (a medium grey L 34 is no dark mask)
local W_LIGHT, W_CHROMA, W_KEEP, W_PROP, W_FLAT = 1.0, 0.5, 0.15, 1.0, 0.5
local PALETTE_LIMIT = 8
local BIG_SHARE = 0.05
local PAINT_REFLECTION = 0.04 -- linear light a paint shows over a bare metal of the same model color
local PAINT_SHARE = 0.05 -- Match Materials: a metal part from this share of the item's paint (or an accent) takes paint

-- numpy's pairwise sum of a[1..n] (float64, contiguous), as np.add.reduce computes it for n <= 128.
local function npsum(a, n)
    if n < 8 then
        local s = 0
        for i = 1, n do s = s + a[i] end
        return s
    end
    local r0, r1, r2, r3, r4, r5, r6, r7 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]
    local i = 9
    local full = n - n % 8
    while i <= full do
        r0, r1, r2, r3 = r0 + a[i], r1 + a[i + 1], r2 + a[i + 2], r3 + a[i + 3]
        r4, r5, r6, r7 = r4 + a[i + 4], r5 + a[i + 5], r6 + a[i + 6], r7 + a[i + 7]
        i = i + 8
    end
    local s = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7))
    for k = i, n do s = s + a[k] end
    return s
end
Matcher.npsum = npsum

-- Python's sum() of floats a[1..n] (Python 3.12+: Neumaier's compensated sum, as CPython's builtin_sum computes it):
-- the first value, then each next one with the rounding error carried apart, the carried error added at the end when
-- finite. A plain loop can differ in the last bit: the Cover of Darkness's paint summed to 0.9999999999999999 instead
-- of 1.0, which put its 0.35 lining above ACCENT_MAX_SHARE (2026-10-07).
local function pysum(a, n)
    if n == 0 then return 0 end
    local f, c = a[1], 0
    for i = 2, n do
        local x = a[i]
        local t = f + x
        if math.abs(f) >= math.abs(x) then c = c + ((f - t) + x) else c = c + ((x - t) + f) end
        f = t
    end
    if c ~= 0 and c - c == 0 then f = f + c end -- c - c is 0 only when c is finite
    return f
end
Matcher.pysum = pysum

-- Stable sort by descending `field` (Python's sorted(..., key=lambda x: -x[field])).
local function sort_desc(list, field)
    for i, item in ipairs(list) do item._order = i end
    table.sort(list, function(x, y)
        if x[field] ~= y[field] then return x[field] > y[field] end
        return x._order < y._order
    end)
    return list
end

local function chroma(a, b) return math.sqrt(a * a + b * b) end

local function is_neutral(L, a, b)
    return L < NEUTRAL_L and chroma(a, b) < NEUTRAL_C
end
Matcher.is_neutral = is_neutral

-- Classes go by the model color (mL, ma, mb).
local function neutral(g) return is_neutral(g.mL, g.ma, g.mb) end

-- Whether a group looks a dark neutral (perceived L < LOOK_DARK_L, chroma < NEUTRAL_C): the anchor's class, so a
-- light identity lands on a light part and a dark one on a dark part.
local function looks_dark(g) return g.L < LOOK_DARK_L and chroma(g.a, g.b) < NEUTRAL_C end

local function is_structure(g)
    return neutral(g) and g.under >= 0.5 * g.area
end

-- Whether an armor's undersuit black is its paint: no group outside it reaches LARGE_AREA of what shows (the SC-34
-- Infiltrator, 93% undersuit: its 2% light-grey trims had become its identity and turned helmets white, user
-- 2026-10-06). As a source its undersuit groups then count as paint, for its identity and its pairs.
local function suit_is_paint(groups, limit)
    for _, g in ipairs(groups) do
        if not is_structure(g) and g.share >= limit then return false end
    end
    return true
end

-- Groups of an item's paint rows: greedy by descending area, a row joins the first group of its hood, metal and
-- camo class whose founding model color is within GROUP_DE (row.hood: a hood row kept by Recolor Hoods off).
local function make_groups(paint, paint_area)
    local groups = {}
    for _, row in ipairs(sort_desc({unpack(paint)}, 'area')) do
        local joined = false
        for _, g in ipairs(groups) do
            if g.hood == row.hood and g.metal == row.metal and g.camo == row.camo
                and de2000(g.mL, g.ma, g.mb, row.mL, row.ma, row.mb) < GROUP_DE then
                g.rows[#g.rows + 1] = row
                g.area, g.under = g.area + row.area, g.under + row.under
                joined = true
                break
            end
        end
        if not joined then
            groups[#groups + 1] = {L = row.L, a = row.a, b = row.b, mL = row.mL, ma = row.ma, mb = row.mb,
                                   metal = row.metal, camo = row.camo, hood = row.hood, rows = {row}, area = row.area,
                                   under = row.under, rep = row}
        end
    end
    for _, g in ipairs(groups) do g.share = g.area / paint_area end
    return sort_desc(groups, 'area')
end

-- A group's perceived color: its rows' perceived linear colors, mean by screen pixels (by texture area when none
-- shows), summed in row order (match12.group_look).
local function group_look(rows)
    local field = 'area'
    local pixels = 0
    for _, row in ipairs(rows) do pixels = pixels + row.area end
    if not (pixels > 0) then field = 'tex_area' end
    local r, g, b, weight = 0, 0, 0, 0
    for _, row in ipairs(rows) do
        local w = row[field]
        r, g, b, weight = r + w * row.lin[1], g + w * row.lin[2], b + w * row.lin[3], weight + w
    end
    weight = math.max(weight, 1e-12)
    return linear_to_lab(math.max(r / weight, 0), math.max(g / weight, 0), math.max(b / weight, 0))
end

-- Whether every LUT of the rows was measured with the kit (else it changed since, or the rows are another body's).
local function measured_kit(rows, kit)
    if not kit then return false end
    for _, row in ipairs(rows) do
        if not kit.luts[row.lut] then return false end
    end
    return true
end

-- Relative luminance of display-linear RGB.
local function luminance(r, g, b) return 0.2126 * r + 0.7152 * g + 0.0722 * b end

-- A row of a mod's LUT that differs from the archived one (row.vanilla, src/kits.lua): its measured light, taken
-- with the archived colors, scaled by how much brighter or darker it looks now (through its response, else the
-- model).
local function light_scale(row, cal)
    local v = row.vanilla
    local now, before
    if cal then
        now, before = luminance(seen(cal, row.ar, row.ag, row.ab)), luminance(seen(cal, v.ar, v.ag, v.ab))
    else
        now, before = luminance(lab_to_linear(row.L, row.a, row.b)), luminance(lab_to_linear(v.L, v.a, v.b))
    end
    return before > 1e-9 and now / before or 1.0
end

-- Measured rows: screen pixels for area (the undersuit part scaled alike), the light they show (pixels x mean
-- screen luminance) and the perceived color of the row's response (row.cal = {gr, gg, gb, sr, sg, sb}; Colour.seen:
-- gloss counts on neutral paint only), else the model color. A mod's LUT row keeps its measured response only while
-- its finish is the archived one (row.finish_changed: its metal, gloss or mode differ; the response was measured
-- with them), and its light follows its new colors (KB match-your-colors-review-transmog-v13).
local function measure_rows(rows, kit, look)
    for _, row in ipairs(rows) do
        local frac = row.area > 0 and row.under / row.area or 0.0
        local seen_row = kit.rows[row.key]
        row.area, row.light = seen_row and seen_row[1] or 0, seen_row and seen_row[2] or 0
        row.under = row.area * frac
        local cal = not row.finish_changed and look.row(row.lut, row.row) or nil
        if cal then
            row.cal = cal
            row.lin = {seen(cal, row.ar, row.ag, row.ab)}
            row.L, row.a, row.b = linear_to_lab(row.lin[1], row.lin[2], row.lin[3])
        else
            row.lin = {lab_to_linear(row.L, row.a, row.b)}
        end
        if row.vanilla then row.light = row.light * light_scale(row, cal) end
    end
end

-- The item's patterns: {key, pattern, area, share, L, a, b (perceived), mL, ma, mb (model: texel 0), gain, rep,
-- rows}; measured: the pattern's screen pixels and, when measured, its look (gain x texel color, linear).
local function item_patterns(patterns, kit, paint_area)
    local out = {}
    for _, p in ipairs(patterns or {}) do
        local mL, ma, mb = srgb_to_lab(p.r, p.g, p.b)
        local key = 'pattern:' .. p.pattern
        local entry = {key = key, pattern = p.pattern, area = p.area, L = mL, a = ma, b = mb, mL = mL, ma = ma, mb = mb,
                       texel = {p.r, p.g, p.b}, rep = {key = key}, rows = {}}
        local m = kit and kit.patterns[p.pattern]
        if kit then entry.area = m and m.px or 0 end
        if m and m.gain then
            entry.gain = m.gain
            entry.L, entry.a, entry.b = linear_to_lab(math.max(m.gain[1] * srgb_to_linear(p.r), 0),
                math.max(m.gain[2] * srgb_to_linear(p.g), 0), math.max(m.gain[3] * srgb_to_linear(p.b), 0))
        end
        entry.share = entry.area / paint_area
        out[#out + 1] = entry
    end
    return out
end

-- Whether a row keeps its colors as a lens or light: lenses and lights (mode >= 2.5), and glowing paint (mode 0
-- with an emissive intensity, column 13 x: the game's own light strips, at most 2.7% of a kit, and the glowing
-- visors of LUT mods; v1.3). Cloth rows use column 13 otherwise.
function Matcher.light(row)
    return row.mode >= 2.5 or (row.mode < 0.5 and (row.emissive or 0) > 0)
end

-- An item from rows {key, lut, row, area, under, L, a, b (model), ar, ag, ab (mean linear albedo), metal, camo,
-- mode, full, emissive} in first-seen order; armor: true for an armor kit (identity color by salience); patterns:
-- {{pattern, area, r, g, b (texel 0, sRGB)}, ...} or nil; look: nil or {kit = Appearance kit entry or nil, row =
-- Appearance row function, hoods = the kit's hood rows {['lut:row'] -> true} or nil}; keep_hoods: Recolor Hoods off
-- (the hood rows group apart and take no color).
-- The item's own copies of the analysis rows (the analysis is kept and cached as it is), with the model color and
-- texture area kept as mL, ma, mb, tex_area; hoods: the hood rows to keep, or nil.
local function copy_rows(analysis_rows, hoods)
    local rows = {}
    for i, source in ipairs(analysis_rows) do
        local row = {}
        for k, v in pairs(source) do row[k] = v end
        row.lens = Matcher.light(row)
        row.hood = hoods ~= nil and hoods[row.key] == true
        row.mL, row.ma, row.mb, row.tex_area = row.L, row.a, row.b, row.area
        rows[i] = row
    end
    return rows
end

-- The paint rows (not lens) into item.paint; returns the paint area (a measured kit's pattern pixels included; 1
-- when nothing shows): Python's sum of the rows' areas (pysum; match.py, match12.py), then the pattern pixels.
local function paint_of(item, kit)
    local areas = {}
    for _, row in ipairs(item.rows) do
        if not row.lens then
            item.paint[#item.paint + 1] = row
            areas[#areas + 1] = row.area
        end
    end
    local paint_area = pysum(areas, #areas)
    if item.measured then
        for _, m in pairs(kit.patterns) do paint_area = paint_area + m.px end
    end
    if paint_area == 0 then paint_area = 1.0 end
    return paint_area
end

-- A cape's rows (look.borrow: not measured, the study hid the cape) fit through the response their cloth borrows from
-- measured rows of the same material controls (research/make_appearance.py cape_rows writes it under the cape's LUT
-- rows), a tint row through its material row's (look.tint_of: cape LUT -> material LUT), tint included (hue: the fit
-- cancels the cloth's own tint toward a neutral goal, src/transfer.lua): Drape of Glory's sheen cloth took the B-01
-- Tactical's dark and looked brown (image review 2026-10-07). Looks stay the model's; a mod's row whose finish changed
-- keeps the model.
local function borrow_rows(rows, look)
    for _, row in ipairs(rows) do
        local lut = look.tint_of and look.tint_of[row.lut] or row.lut
        local cal = not row.finish_changed and look.row(lut, row.row) or nil
        if cal then row.cal = {cal[1], cal[2], cal[3], cal[4], cal[5], cal[6], hue = true} end
    end
end

function Matcher.item(analysis_rows, armor, patterns, look, keep_hoods)
    local kit = look and look.kit
    local rows = copy_rows(analysis_rows, keep_hoods and look and look.hoods or nil)
    local item = {rows = rows, armor = armor, paint = {}, measured = measured_kit(rows, kit)}
    if item.measured then
        measure_rows(rows, kit, look)
    elseif look and look.borrow then
        borrow_rows(rows, look)
    end
    local paint_area = paint_of(item, kit)
    item.paint_area = paint_area
    item.groups = make_groups(item.paint, paint_area)
    if item.measured then
        for _, g in ipairs(item.groups) do g.L, g.a, g.b = group_look(g.rows) end
    end
    item.suit_paint = armor and suit_is_paint(item.groups, LARGE_AREA) or false
    -- as a target its suit takes colors when no group outside it reaches PAINT_SHARE: else the recolor shows nowhere
    -- (the O-3 Free Spirit, 97% suit, unchanged with the UF-50 Bloodhound; user 2026-10-07); an armor with a part of
    -- its own that size (the DP-00 Tactical's 7% yellow plates) keeps its dark undersuit
    item.suit_target = armor and suit_is_paint(item.groups, PAINT_SHARE) or false
    item.patterns = item_patterns(patterns, item.measured and kit or nil, paint_area)
    return item
end

-- Whether the assignment's source lightnesses and the identity's span less than 10 (light/dark flattened).
local function flat(assign, s, ref_s)
    local lo, hi = ref_s, ref_s
    for i = 1, #assign do
        local L = s[assign[i]].L
        if L < lo then lo = L end
        if L > hi then hi = L end
    end
    return hi - lo < 10
end

-- The objective of one assignment (source index per target paint group); see match.py _cost. c: the search
-- context {t, s, keep_ok, ref_t, ref_s, flat_check}.
local function cost(assign, c)
    local t, s = c.t, c.s
    local n, m = #t, #s
    local per, used = {}, {}
    for j = 1, m do used[j] = 0 end
    for i = 1, n do
        local j = assign[i]
        local rel = math.abs((s[j].L - c.ref_s) - (t[i].L - c.ref_t))
        local dc = math.abs(chroma(s[j].a, s[j].b) - chroma(t[i].a, t[i].b))
        per[i] = t[i].share * (W_LIGHT * rel / 100 + W_CHROMA * dc / 100 + W_KEEP * (c.keep_ok[i][j] and 0 or 1))
        used[j] = used[j] + t[i].share
    end
    local total = npsum(per, n)
    local used_sum = math.max(npsum(used, m), 1e-9)
    local gaps = {}
    for j = 1, m do gaps[j] = math.abs(used[j] / used_sum - s[j].share / s.share_sum) end
    total = total + W_PROP * npsum(gaps, m) / 2
    if c.flat_check and flat(assign, s, c.ref_s) then total = total + W_FLAT end
    return total
end

-- One pass over target group i's allowed alternatives: returns the best cost and assignment and whether it
-- improved (first improvement wins, as match11.py _search).
local function improve(i, assign, best, c)
    local improved = false
    for j = 1, #c.s do
        if j ~= assign[i] and c.allowed[i][j] then
            local trial = {unpack(assign)}
            trial[i] = j
            local value = cost(trial, c)
            if value < best - 1e-9 then best, assign, improved = value, trial, true end
        end
    end
    return best, assign, improved
end

-- First-improvement local search over single reassignments; target groups in `fixed` (the anchor, parts that
-- already match a main source color) never move.
local function search(assign, fixed, c)
    local best = cost(assign, c)
    local improved = true
    while improved do
        improved = false
        for i = 1, #assign do
            if not fixed[i] then
                local better
                best, assign, better = improve(i, assign, best, c)
                improved = improved or better
            end
        end
    end
    return assign
end

local function shares(list)
    local values = {}
    for i, g in ipairs(list) do values[i] = g.share end
    return values
end

-- Peak-to-peak of the L of groups with share >= BIG_SHARE, and how many there are.
local function big_spread(list)
    local count, lo, hi = 0, math.huge, -math.huge
    for _, g in ipairs(list) do
        if g.share >= BIG_SHARE then
            count = count + 1
            lo, hi = math.min(lo, g.L), math.max(hi, g.L)
        end
    end
    return count, count > 0 and hi - lo or 0
end

-- The source's palette: its groups of at least PAIR_MIN_SHARE, largest first, at most PALETTE_LIMIT (else
-- its largest group).
local function palette_of(source)
    local palette = {}
    for _, g in ipairs(source.groups) do
        if g.share >= PAIR_MIN_SHARE and #palette < PALETTE_LIMIT then palette[#palette + 1] = g end
    end
    if #palette == 0 and source.groups[1] then palette[1] = source.groups[1] end
    return palette
end

-- The light a group shows (measured items): its rows' pixels x mean screen luminance, a row's undersuit part weighed
-- UNDER_SALIENCE.
local function light_of(g)
    local total = 0.0
    for _, row in ipairs(g.rows) do
        local frac = row.area > 0 and row.under / row.area or 0.0
        total = total + (row.light or 0) * (1.0 - frac * (1.0 - UNDER_SALIENCE))
    end
    return total
end

-- The source's identity color: a helmet's largest paint group (helmet_main: not a vivid minority); an armor's most
-- salient (undersuit area weighs
-- UNDER_SALIENCE, dark neutrals DARK_SALIENCE, DARK_SALIENCE_TEXTURE when unmeasured). A measured armor whose most
-- salient color looks dark but which has a main color (share >= LARGE_AREA) that looks light and shows more light
-- reads as that color (the SR-64 Cinderblock as its light plates, not its dark straps). Structure groups are skipped
-- while any other group exists.
-- An armor's most salient group of pool (undersuit area weighs UNDER_SALIENCE, dark neutrals DARK_SALIENCE,
-- DARK_SALIENCE_TEXTURE when unmeasured).
local function salience(source, g)
    if not source.armor then return g.share end
    local dark = source.measured and DARK_SALIENCE or DARK_SALIENCE_TEXTURE
    return (g.area - g.under * (1 - UNDER_SALIENCE)) / source.paint_area * (neutral(g) and dark or 1.0)
end

local function most_salient(source, pool)
    local main, best = pool[1], -math.huge
    for _, g in ipairs(pool) do
        local s = salience(source, g)
        if s > best then best, main = s, g end
    end
    return main
end

-- The main color (share >= LARGE_AREA) of pool that looks light and shows the most light, if it shows more than
-- main.
local function lighter_main(pool, main)
    local light, most = nil, -math.huge
    for _, g in ipairs(pool) do
        if g.share >= LARGE_AREA and not looks_dark(g) and light_of(g) > most then light, most = g, light_of(g) end
    end
    if light and most > light_of(main) then return light end
    return nil
end

-- A helmet's identity: its largest group, unless that is a vivid color (model chroma >= ACCENT_VIVID) on less than
-- VIVID_MAJORITY of its paint while a muted group (model chroma < ACCENT_C) covers at least ANCHOR_MIN_SHARE: then the
-- largest muted group (pool runs from the largest). An armor is far larger than a helmet, so a vivid minority as its
-- main color takes over the whole body: the PH-9 Predator's red beret (42% of what shows) turned an entire dark armor
-- bright red (user 2026-10-06). The vivid color stays the source's accent.
local VIVID_MAJORITY = 0.5
local function helmet_main(pool)
    local top = pool[1]
    if chroma(top.ma, top.mb) < ACCENT_VIVID or top.share >= VIVID_MAJORITY then return top end
    for _, g in ipairs(pool) do
        if chroma(g.ma, g.mb) < ACCENT_C and g.share >= ANCHOR_MIN_SHARE then return g end
    end
    return top
end

local function identity_of(source, palette)
    local pool = {}
    for _, g in ipairs(palette) do
        if source.suit_paint or not is_structure(g) then pool[#pool + 1] = g end
    end
    if #pool == 0 then pool = palette end
    if not source.armor then return helmet_main(pool) end
    local main = most_salient(source, pool)
    if not source.measured or not looks_dark(main) then return main end
    return lighter_main(pool, main) or main
end

-- The group of `list` nearest to g by lightness (the first of equal gaps).
local function nearest_lightness(list, g)
    local pick, gap = nil, math.huge
    for _, n in ipairs(list) do
        local d = math.abs(n.L - g.L)
        if d < gap then pick, gap = n, d end
    end
    return pick
end

-- Structure groups keep a dark neutral: the source's nearest by lightness, when it has one. Returns the paint groups:
-- the others, or all of them when suit (the target's undersuit is its paint: suit_target).
local function structure_pairs(targets, palette, pairs, suit)
    local neutrals = {}
    for _, g in ipairs(palette) do if neutral(g) then neutrals[#neutrals + 1] = g end end
    local paint = {}
    for _, g in ipairs(targets) do
        if suit or not is_structure(g) then
            paint[#paint + 1] = g
        elseif #neutrals > 0 then
            pairs[#pairs + 1] = {g, nearest_lightness(neutrals, g)}
        end
    end
    return paint
end

-- Initial assignment: each target group takes the allowed source color whose lightness relative to the
-- source's identity color best matches its own relative to the anchor.
local function initial_assign(t, s, ref_t, ref_s, allowed)
    local assign = {}
    for i = 1, #t do
        local best, gap = nil, math.huge
        for j = 1, #s do
            local d = math.abs((s[j].L - ref_s) - (t[i].L - ref_t))
            if allowed[i][j] and (best == nil or d < gap) then best, gap = j, d end
        end
        assign[i] = best
    end
    return assign
end

-- The source's largest color that is not its undersuit (the largest of all when every color is; the first of equal
-- shares). s.suit: the source's undersuit black is its paint (suit_is_paint).
local function largest_paint(s)
    local largest
    for j = 1, #s do
        if (s.suit or not is_structure(s[j])) and (largest == nil or s[j].share > s[largest].share) then largest = j end
    end
    if largest then return largest end
    largest = 1
    for j = 2, #s do if s[j].share > s[largest].share then largest = j end end
    return largest
end

-- Whether target group g may take source color j (keep: g already matches it). A large area takes only main colors,
-- one it already matches or the largest, never a trim; an undersuit color goes only to a small dark neutral group,
-- unless the source's undersuit black is its paint (s.suit).
local function may_take(g, s, j, keep, largest)
    local small = g.share < LARGE_AREA
    local size_ok = small or s[j].share >= MAIN_COLOR or keep or j == largest
    return size_ok and (keep or s.suit or not is_structure(s[j]) or (small and neutral(g)))
end

-- allowed[i][j]: target group i may take source color j (may_take); a group allowed none takes the largest.
local function allowed_matrix(t, s, keep_ok)
    local largest = largest_paint(s)
    local allowed = {}
    for i = 1, #t do
        local row, any = {}, false
        for j = 1, #s do
            row[j] = may_take(t[i], s, j, keep_ok[i][j], largest)
            any = any or row[j]
        end
        if not any then row[largest] = true end
        allowed[i] = row
    end
    return allowed
end

-- keep_ok[i][j]: target group i already matches source group j (CIEDE2000 < KEEP_DE, as they look).
local function keep_matrix(t, s)
    local keep_ok = {}
    for i = 1, #t do
        keep_ok[i] = {}
        for j = 1, #s do keep_ok[i][j] = de2000(t[i].L, t[i].a, t[i].b, s[j].L, s[j].a, s[j].b) < KEEP_DE end
    end
    return keep_ok
end

-- The target group that takes the identity: the largest (share >= ANCHOR_MIN_SHARE) of the identity's look class
-- (looks dark or not: the helmet's main part takes the armor's main color, a light identity never lands on a dark
-- mask), else one that already matches it, else the largest.
local function anchor_of(t, keep_ok, j_main, identity)
    local dark = looks_dark(identity)
    for i = 1, #t do
        if t[i].share >= ANCHOR_MIN_SHARE and looks_dark(t[i]) == dark then return i end
    end
    for i = 1, #t do
        if t[i].share >= ANCHOR_MIN_SHARE and keep_ok[i][j_main] then return i end
    end
    return 1
end

-- The closest of the source's main colors (share >= MAIN_COLOR) that target group g already matches, or nil.
local function closest_main(g, s, keep_row, allowed_row)
    local pick, gap = nil, math.huge
    for j = 1, #s do
        if keep_row[j] and allowed_row[j] and s[j].share >= MAIN_COLOR then
            local d = de2000(g.L, g.a, g.b, s[j].L, s[j].a, s[j].b)
            if d < gap then pick, gap = j, d end
        end
    end
    return pick
end

-- Parts that already match one of the source's main colors keep it: assign[i] = the closest such color, fixed[i] =
-- true (the FS-23 Battle Master's light crest, matching the SR-64 Cinderblock's light plates, went black when the
-- search mirrored the armor's 72% dark).
local function keep_matches(t, s, assign, fixed, keep_ok, allowed)
    for i = 1, #t do
        local pick = not fixed[i] and closest_main(t[i], s, keep_ok[i], allowed[i])
        if pick then assign[i], fixed[i] = pick, true end
    end
end

-- Whether both sides show light/dark structure (two big groups 20 L apart): the search then penalizes
-- flattening it.
local function needs_flat_check(t, s)
    local big_t, spread_t = big_spread(t)
    local big_s, spread_s = big_spread(s)
    return big_t >= 2 and spread_t >= 20 and big_s >= 2 and spread_s >= 20
end

-- Pairs {target group, source group} and the anchor group (nil without paint) (match12.py pair_groups). Hood
-- groups (Recolor Hoods off) take no color.
function Matcher.pair_groups(target, source)
    local targets = {}
    for _, g in ipairs(target.groups) do
        if g.share >= TGT_MIN_SHARE and not g.hood then targets[#targets + 1] = g end
    end
    local palette = palette_of(source)
    local pairs = {}
    if #targets == 0 or #palette == 0 then return pairs, nil end
    local main = identity_of(source, palette)
    local t = structure_pairs(targets, palette, pairs, target.suit_target)
    if #t == 0 then return pairs, nil end
    local s = palette
    s.share_sum, s.suit = npsum(shares(s), #s), source.suit_paint
    local j_main = 1
    for j = 1, #s do if s[j] == main then j_main = j end end
    local keep_ok = keep_matrix(t, s)
    local anchor = anchor_of(t, keep_ok, j_main, s[j_main])
    local allowed = allowed_matrix(t, s, keep_ok)
    local c = {t = t, s = s, keep_ok = keep_ok, allowed = allowed, ref_t = t[anchor].L, ref_s = s[j_main].L,
               flat_check = needs_flat_check(t, s)}
    local assign = initial_assign(t, s, c.ref_t, c.ref_s, allowed)
    assign[anchor] = j_main
    local fixed = {[anchor] = true}
    keep_matches(t, s, assign, fixed, keep_ok, allowed)
    assign = search(assign, fixed, c)
    for i = 1, #t do pairs[#pairs + 1] = {t[i], s[assign[i]]} end
    return pairs, t[anchor]
end

-- The source's accent: its most salient visible saturated color (model chroma x sqrt(share)), or nil. A measured
-- item counts what shows from SOURCE_ACCENT_MIN_SHARE_MEASURED of its pixels (a small emblem is what the eye takes for
-- an armor's accent), texture shares from SOURCE_ACCENT_MIN_SHARE.
local function source_accent(source)
    local min_share = source.measured and SOURCE_ACCENT_MIN_SHARE_MEASURED or SOURCE_ACCENT_MIN_SHARE
    local best, pick = 0.0, nil
    for i = 1, #source.groups + #source.patterns do
        local g = source.groups[i] or source.patterns[i - #source.groups]
        local c = chroma(g.ma, g.mb)
        local light = g.mL >= SOURCE_ACCENT_MIN_L or (g.mL >= ACCENT_MIN_L and c >= ACCENT_VIVID)
        local visible = g.share >= min_share and light
        if visible and c >= ACCENT_C and c * math.sqrt(g.share) > best then best, pick = c * math.sqrt(g.share), g end
    end
    return pick
end

-- A target accent: saturated, not the anchor, small (share <= ACCENT_SMALL) or vivid up to ACCENT_MAX_SHARE (the
-- DS-10 Big Game Hunter's 26% muted tan hood is a main part, the CM-09 Bonesnapper helmet's 21% red jaw an accent).
-- A source's second color, what its target's small accents and patterns take when it has no visible saturated accent
-- (its accents then follow the pairing): its most salient paint group other than the identity and unlike it (CIEDE2000
-- >= KEEP_DE), hoods and (unless its suit is its paint) structure left out; nil when there is none (a one-color source:
-- the accents keep their color). They kept their own color before (v1.1), so a 1.5% yellow trim stayed yellow on the
-- DP-00 Tactical with the white and grey CW-36 Winter Warrior (user 2026-10-07); now it takes the Winter Warrior's
-- dark, a muted color counting (the IX-VOIDWALKER's navy).
local function fallback_accent(source)
    local palette = palette_of(source)
    if #palette == 0 then return nil end
    local main = identity_of(source, palette)
    local best, pick = -math.huge, nil
    for _, g in ipairs(palette) do
        if g ~= main and not g.hood and (source.suit_paint or not is_structure(g))
            and de2000(g.L, g.a, g.b, main.L, main.a, main.b) >= KEEP_DE and salience(source, g) > best then
            best, pick = salience(source, g), g
        end
    end
    return pick
end

-- Degrees between two hues (a, b pairs), 0-180 (match11.hue_gap).
local function hue_gap(a1, b1, a2, b2)
    local d = math.abs(math.deg(math.atan2(b1, a1) - math.atan2(b2, a2))) % 360.0
    return d > 180.0 and 360.0 - d or d
end

-- The share of g's hue family: g's own, plus every other group of the target that is saturated (model chroma >=
-- ACCENT_C) within FAMILY_HUE of g's model hue, added in group order (match12.family_share). The CM-14 Physician's
-- green is two groups (15% and 12%): each passed as a trim and the RS-67 Null Cipher's 0.3% yellow painted a quarter of
-- the armor (user 2026-10-07).
local FAMILY_HUE = 30.0
local function family_share(g, target)
    local total = g.share
    for _, o in ipairs(target.groups) do
        if o ~= g and chroma(o.ma, o.mb) >= ACCENT_C and hue_gap(o.ma, o.mb, g.ma, g.mb) <= FAMILY_HUE then
            total = total + o.share
        end
    end
    return total
end

-- A target accent: saturated (model chroma; a metal group's look when that is more saturated: metal's model color is
-- darkened and muted, its look is not, the RE-2310 Honorary Guard's gold band model chroma 28, look 42, image review
-- 2026-10-06), not the anchor, small or vivid up to ACCENT_MAX_SHARE. A trim goes by its hue family's share (family:
-- family_share).
local function is_accent(g, anchor, family)
    local c = chroma(g.ma, g.mb)
    if g.metal then c = math.max(c, chroma(g.a, g.b)) end
    if g == anchor or g.share > ACCENT_MAX_SHARE or c < ACCENT_C then return false end
    -- a colored trim up to LARGE_AREA on a neutral main surface (the anchor) is an accent whatever its chroma, so a
    -- trim's class does not flip between 9.9% and 10.5%: the DP-53 Savior of the Free's gold braid (10.5%, chroma 26) went
    -- black with the B-01 Tactical's dark shell instead of taking its yellow (user 2026-10-07); its hue family counts
    -- whole, so a color split in groups is no trim (family_share: the CM-14 Physician's green)
    return g.share <= ACCENT_SMALL or c >= ACCENT_VIVID or (family <= LARGE_AREA and anchor ~= nil and neutral(anchor))
end

-- Whether group g already matches one of the source's colors (share >= PAIR_MIN_SHARE), as they look.
local function matches_source(g, source)
    for _, s in ipairs(source.groups) do
        if s.share >= PAIR_MIN_SHARE and de2000(g.L, g.a, g.b, s.L, s.a, s.b) < KEEP_DE then return true end
    end
    return false
end

-- The source group a target group takes and how ('pair' or 'accent'); nil keeps its color.
-- The source's most visible bare-metal group (at least PAINT_SHARE of its paint) for target group t when t is bare
-- metal taking s, a dark color (perceived L < LOOK_DARK_L, chroma >= TINT_C), with Match Materials off; else nil. A
-- dark color on bare metal shows only in its dim reflections and reads near-black, while metal next to metal reads as
-- one material: the CPR-80 Bulwark's steel took the DP-8 Mountain-Scaled's dull navy and turned near-black on its
-- silver, navy and gold armor; its chainmail's silver is what the steel should echo (image review 2026-10-06).
local TINT_C = 8.0 -- as src/transfer.lua: a color at least this saturated is a tint
local function metal_echo(t, s, source, materials)
    if materials or not t.metal or s.metal or s.L >= LOOK_DARK_L or chroma(s.a, s.b) < TINT_C then return nil end
    for _, g in ipairs(source.groups) do -- by area: the most visible first
        if g.metal and g.share >= PAINT_SHARE then return g end
    end
    return nil
end

-- What target group t takes: the source's saturated accent when it is an accent (none when it is dark or already
-- matches), else what the pairing gave it, s. Without a saturated accent, a source with a second color leaves its
-- accents the pairing's color (the DP-40 Hero of the Federation's gold trim the IX-VOIDWALKER's navy: v1.1 to v1.3 kept
-- their own color, user 2026-10-07); a one-color source (second nil) leaves them their own, as its color would erase
-- them (the RE-2310 Honorary Guard's gold trim with the all-dark AC-2 Obedient, agreed 2026-10-05).
-- A target accent above ACCENT_SMALL takes the source's accent only when the source shows it on at least
-- ACCENT_SOURCE_BIG of its paint, else what the pairing gives it: the RS-67 Null Cipher's 0.28% yellow painted United
-- in Equality's 24% purple band, as it had the CM-14 Physician's green (user 2026-10-07). The agreed accents keep
-- theirs: the I-44 Salamander's 7% orange (under ACCENT_SMALL) takes the SR-64 Cinderblock's 0.12% emblem, the RE-2310
-- Honorary Guard's 15% band the CE-27 Ground Breaker's 2.8% trim (match12.ACCENT_SOURCE_BIG).
local ACCENT_SOURCE_BIG = 0.01
-- A source accent under ACCENT_SOURCE_BIG (a speck) recolors a target accent bigger than itself only within the
-- accent's hue family: the RS-67 Null Cipher's 0.28% yellow turned the CM-14 Physician's 3% red canisters a bright
-- yellow (image review 2026-10-07, 66 degrees apart). Every agreed accent taking a speck stays within 28 degrees (the
-- I-44 Salamander's orange: the Bonesnapper's, Doubt Killer's and Cinderblock's reds and orange) or is smaller than it
-- (the Null Cipher's 0.3% marks take the Doubt Killer's 0.5% red); patterns keep their rule (match12.speck_across).
local function speck_across(t, accent)
    return accent.share < ACCENT_SOURCE_BIG and t.share > accent.share
        and hue_gap(t.ma, t.mb, accent.ma, accent.mb) > FAMILY_HUE
end

local function choice(t, s, anchor, accent, second, source, target)
    if (accent == nil and second ~= nil) or not is_accent(t, anchor, family_share(t, target)) then return s, 'pair' end
    if accent == nil or t.mL < ACCENT_MIN_L or matches_source(t, source) then return nil end
    if t.share > ACCENT_SMALL and accent.share < ACCENT_SOURCE_BIG or speck_across(t, accent) then return s, 'pair' end
    return accent, 'accent'
end

-- A CIELAB color with `lift` linear light added to each channel (white; negative removes it, down to black).
local function reflected(L, a, b, lift)
    local r, g, bl = lab_to_linear(L, a, b)
    return linear_to_lab(r + lift, g + lift, bl + lift)
end

-- Whether target row `row` of group t becomes the paint it takes (Match Materials): a hard (mode 0) metal row
-- taking a LUT row's paint (a pattern accent has no row), as a pair of a big part (share >= PAINT_SHARE) or as an
-- accent. Small metal details (bolts, rims) stay metal; parts never turn into metal (a metal's look cannot be fitted
-- reliably: it shows what it reflects).
local function painted(t, kind, src, row)
    local rep = src.rep
    if not rep.lut then return false end
    return row.mode == 0 and row.metal and not rep.metal and (kind == 'accent' or t.share >= PAINT_SHARE)
end

-- mapping[row key] = {source, kind, L, a, b, cal, finish, copy} for every row of target group t taking source color
-- src: each row keeps its lightness offset from its group and its hue offset scaled with the chroma change; an
-- unmeasured bare metal row taking paint aims PAINT_REFLECTION lighter. materials: a painted row aims at the paint's own
-- look (its offset came from its metal) through the source row's measured response (cal), and finish names the source
-- row whose finish it takes (src/recolor.lua). A source row marked copy (a paint scheme's camo row, src/schemes.lua)
-- is copied, colors and camo, instead of fitted: copy names it.
-- A source color below NEUTRAL_TINT_C passes its lightness only: its slight tint does not show on it (the GS-66
-- Lawmaker's silver measures b -3.7 from the Armory's bluish fill light in its metal, its dark visor surround a navy
-- that reads black), yet on a big matte part it turns into a cast (the B-24 Enforcer's leather went navy-purple and its
-- plates steel-blue; image review 2026-10-06). A row that becomes the paint it takes (Match Materials) aims at that
-- paint's own look, tint included: the same material shows the same tint on both.
local NEUTRAL_TINT_C = 5.0

-- The tint a target group's rows aim at (the source's a, b) and the share of their own hue offsets they keep (the
-- chroma change, at most 1); a near-neutral source passes no tint and no offsets.
local function source_tint(t, src)
    local s_c = chroma(src.a, src.b)
    if s_c < NEUTRAL_TINT_C then return 0, 0, 0 end
    local t_c = chroma(t.a, t.b)
    return src.a, src.b, t_c > 1.0 and math.min(1.0, s_c / t_c) or 1.0
end

local function map_group(mapping, t, kind, src, materials)
    local sa, sb, scale = source_tint(t, src)
    local src_full = src.rep.full == true
    for _, row in ipairs(t.rows) do
        if src.rep.copy then
            local paint = materials and painted(t, kind, src, row)
            mapping[row.key] = {source = src.rep.key, kind = kind, L = src.L, a = src.a, b = src.b,
                                copy = src.rep.key, finish = paint and src.rep.key or nil}
        elseif materials and painted(t, kind, src, row) then
            mapping[row.key] = {source = src.rep.key, kind = kind, L = src.L, a = src.a, b = src.b, cal = src.rep.cal,
                                finish = src.rep.key}
        else
            local L, a, b = src.L + (row.L - t.L), sa + (row.a - t.a) * scale, sb + (row.b - t.b) * scale
            if not row.cal and row.full == true and not src_full then -- bare metal taking paint: the paint's sheen
                L, a, b = reflected(L, a, b, PAINT_REFLECTION)
            end
            mapping[row.key] = {source = src.rep.key, kind = kind, L = L, a = a, b = b, cal = row.cal}
        end
    end
end

-- Accent groups below the pairing minimum (v11.4: the RS-67 Null Cipher's 0.9% yellow) take `small`: the source's
-- saturated accent, else its second color.
local function map_small_accents(mapping, target, source, small, materials)
    for _, t in ipairs(target.groups) do
        if t.share < TGT_MIN_SHARE and not t.hood and chroma(t.ma, t.mb) >= ACCENT_C and t.mL >= ACCENT_MIN_L
            and not matches_source(t, source) then
            map_group(mapping, t, 'accent', small, materials)
        end
    end
end

-- The plan: {target row key -> {source = source row key, kind, L, a, b (desired perceived color), cal (the measured
-- response the fit goes through, or nil), finish (Match Materials: the source row whose finish the row takes, or
-- nil)}} for every recolored row. materials: Match Materials on.
function Matcher.plan(target, source, materials)
    local mapping = {}
    local pairs, anchor = Matcher.pair_groups(target, source)
    local accent = source_accent(source)
    local second = accent == nil and fallback_accent(source) or nil
    for _, pair in ipairs(pairs) do
        local t = pair[1]
        local src, kind = choice(t, pair[2], anchor, accent, second, source, target)
        if kind == 'pair' then src = metal_echo(t, src, source, materials) or src end
        if src then map_group(mapping, t, kind, src, materials) end
    end
    local small = accent or second
    if small then map_small_accents(mapping, target, source, small, materials) end
    return mapping
end

-- Cape design zones (v1.3, KB match-your-colors-cape-tint; research/match12.py cape_zones): an outside emblem, mark or
-- sash (src/capes.lua zones: the cloth bordering it by row and tint bin) that read against half its border (lightness
-- contrast >= ZONE_READ) and no longer reads against half of it as planned (< ZONE_LOST) takes the source color that
-- reads against the most of its planned border (a palette color or the source's accent; ties: the zone's light/dark
-- order against its border kept, then the larger share), when that reads against half; failing that, the one reading
-- against the most of it by CIELAB distance (and against half its cloth), else a smaller source color by lightness,
-- when that reads against half (zone_choice); else its own colors, when they read against half; else the plan stays.
-- Zones go from the largest; a zone first tries the color an earlier zone of its target group took, so a design drawn
-- in one color stays one. The B-01 Tactical made the Drape of Glory's light top and blue-grey bottom one dark, and the
-- CW-36 Winter Warrior's light gave United in Equality's emblem and the purple band around it the same off-white
-- (2026-10-07).
local ZONE_READ, ZONE_LOST, ZONE_BINS = 15.0, 10.0, 8

-- {[row] = {base = item row, tint = item row}} of a cape item (tint_of: its cape LUT -> material LUT).
local function zone_parts(target, tint_of)
    local parts = {}
    for _, row in ipairs(target.rows) do
        local p = parts[row.row] or {}
        parts[row.row] = p
        if tint_of and tint_of[row.lut] then p.tint = row else p.base = row end
    end
    return parts
end

-- A row's display-linear color: plan's desired color (plan nil: its own).
local function row_linear(row, plan)
    local goal = plan and plan[row.key]
    if goal then return lab_to_linear(goal.L, goal.a, goal.b) end
    return lab_to_linear(row.L, row.a, row.b)
end

-- A zone's lightness: its base and tint mixed by area.
local function zone_lightness(p, plan)
    local r, g, b, w = 0, 0, 0, 0
    for _, row in ipairs({p.base or false, p.tint or false}) do
        if row then
            local lr, lg, lb = row_linear(row, plan)
            r, g, b, w = r + row.tex_area * lr, g + row.tex_area * lg, b + row.tex_area * lb, w + row.tex_area
        end
    end
    return (linear_to_lab(r / w, g / w, b / w))
end

-- Whether a border cell of Lab color (cL, ca, cb) reads against lightness L: their lightness at least `threshold`
-- apart, or (hue: a Lab color {L, a, b}) their CIELAB distance from hue, where hue and chroma count too (squared, in
-- research/match12.py apart's order).
local function apart(L, hue, cL, ca, cb, threshold)
    if not hue then return math.abs(L - cL) >= threshold end
    local dL, da, db = hue.L - cL, hue.a - ca, hue.b - cb
    return dL * dL + da * da + db * db >= threshold * threshold
end

-- One border row's cells into acc ({good, total, mean, hue}): at bin k its color is its base blended toward its tint
-- by (k + 0.5) / ZONE_BINS; a cell reads when it is `threshold` apart from L (acc.hue: from that color; apart).
local function border_row(acc, L, counts, p, plan, threshold)
    local br, bg, bb = row_linear(p.base or p.tint, plan)
    local tr, tg, tb = row_linear(p.tint or p.base, plan)
    for k = 0, ZONE_BINS - 1 do
        local n = counts[k]
        if n > 0 then
            local t = (k + 0.5) / ZONE_BINS
            local bL, ba, bb2 = linear_to_lab(br * (1 - t) + tr * t, bg * (1 - t) + tg * t, bb * (1 - t) + tb * t)
            acc.total, acc.mean = acc.total + n, acc.mean + n * bL
            if apart(L, acc.hue, bL, ba, bb2, threshold) then acc.good = acc.good + n end
        end
    end
end

-- (border cells read, border cells, mean border L) of a zone of lightness L against `around` ({[row] = {[bin] =
-- cells}}) as plan colors it; hue (a Lab color {L, a, b}, or nil): read by CIELAB distance from it instead.
local function zone_reads(L, around, parts, plan, threshold, hue)
    local acc = {good = 0, total = 0, mean = 0.0, hue = hue or false}
    for q = 0, 4 do
        local counts, p = around[q], parts[q]
        if counts and p and (p.base or p.tint) then border_row(acc, L, counts, p, plan, threshold) end
    end
    return acc.good, acc.total, acc.total > 0 and acc.mean / acc.total or 0.0
end

-- The source colors a zone may take: the palette, then the accent when it is not in it.
local function zone_candidates(source)
    local list = palette_of(source)
    local accent = source_accent(source)
    if accent then
        for _, g in ipairs(list) do if g == accent then return list end end
        list[#list + 1] = accent
    end
    return list
end

-- The smaller source colors the zone rule falls back on (zone_choice): groups outside `candidates` the source shows on
-- at least ACCENT_SOURCE_BIG of itself (no speck), largest first.
local function zone_minor(source, candidates)
    local list = {}
    for _, g in ipairs(source.groups) do
        local listed = false
        for _, c in ipairs(candidates) do if c == g then listed = true end end
        if g.share >= ACCENT_SOURCE_BIG and not listed then list[#list + 1] = g end
    end
    return list
end

-- Whether candidate g may be picked by CIELAB distance (hue) for a zone with cloth (z.cloth: its border on rows that
-- are no design zones): it reads against half of that cloth too, so a zone does not take its cloth's color while
-- reading against its outline alone (Strength in Our Arms' stripe on the CW-4 Arctic Ranger, render 2026-10-07).
local function on_cloth(g, z, hue)
    if not (hue and z.cloth) then return true end
    local good, total = zone_reads(g.L, z.cloth, z.parts, z.plan, ZONE_READ, g)
    return 2 * good >= total
end

-- The candidate reading against the most of a zone's border (z: {around, cloth, parts, plan, order, mean}; hue: by
-- CIELAB distance, on_cloth; ties: the order kept, then the earlier): it and its border cells read.
local function zone_pick(candidates, z, hue)
    local best, best_good, best_same
    for _, g in ipairs(candidates) do
        if on_cloth(g, z, hue) then
            local good = zone_reads(g.L, z.around, z.parts, z.plan, ZONE_READ, hue and g)
            local same = (g.L >= z.mean) == z.order
            if not best or good > best_good or (good == best_good and same and not best_same) then
                best, best_good, best_same = g, good, same
            end
        end
    end
    return best, best_good
end

-- The source color a lost zone or emblem takes (z: see zone_pick; total: its border cells), or nil, the first that
-- reads against half its border: the candidates' pick by lightness; their pick by CIELAB distance (on_cloth); the
-- smaller source colors' (minor) pick by lightness. The UF-50 Bloodhound's red and black share a lightness (L 21.1 and
-- 20.8), so none of its colors read by lightness against the other: its red took the Pillars of Freedom's black and red
-- alike (the red bars lost), and the Judgment Day's, Liberty's Herald's and Fre Liberam's marks went back to their own
-- colors on its black (user, 2026-10-07: not recolored). Black reads against red, red against black; Liberty's
-- Herald's chevron, on black cloth above and red below, takes the Bloodhound's 1.8% silver.
local function zone_choice(candidates, minor, z, total)
    local best, good = zone_pick(candidates, z, false)
    if best and 2 * good >= total then return best end
    best, good = zone_pick(candidates, z, true)
    if best and 2 * good >= total then return best end
    best, good = zone_pick(minor, z, false)
    if best and 2 * good >= total then return best end
    return nil
end

-- Zone p's rows take source group `best`, or (best nil) keep their own colors.
local function apply_zone(mapping, p, best)
    for _, row in ipairs({p.base or false, p.tint or false}) do
        if row then -- the row fits through its own response (a cape's borrowed one), as every planned row does
            mapping[row.key] = best and {source = best.rep.key, kind = 'zone', L = best.L, a = best.a, b = best.b,
                                         cal = row.cal} or nil
        end
    end
end

-- The part of a zone's border on rows that are no design zones (its cloth), or nil when it borders none.
local function cloth_of(around, zones)
    local cloth
    for q = 0, 4 do
        if around[q] and not zones[q] then
            cloth = cloth or {}
            cloth[q] = around[q]
        end
    end
    return cloth
end

-- One zone kept readable in mapping (see above; rule: {candidates, minor, zones, group_of, taken}): 'picked' (a source
-- color), 'kept' (its own colors), 'lost' (nothing reads), or nil (it did not read before, or still reads).
local function keep_zone(mapping, z, around, parts, rule)
    local p = parts[z]
    local L0 = zone_lightness(p, nil)
    local good, total, mean0 = zone_reads(L0, around, parts, nil, ZONE_READ)
    if total == 0 or 2 * good < total then return nil end
    local mean1
    good, total, mean1 = zone_reads(zone_lightness(p, mapping), around, parts, mapping, ZONE_LOST)
    if 2 * good >= total then return nil end
    local zone = {around = around, cloth = cloth_of(around, rule.zones), parts = parts, plan = mapping,
                  order = L0 >= mean0, mean = mean1}
    local group = rule.group_of[p.base or p.tint]
    local taken = group and rule.taken[group]
    local best = taken and zone_choice({taken}, rule.none, zone, total)
    best = best or zone_choice(rule.candidates, rule.minor, zone, total)
    if best then
        apply_zone(mapping, p, best)
        if group and not taken then rule.taken[group] = best end
        return 'picked'
    end
    if 2 * zone_reads(L0, around, parts, mapping, ZONE_READ) >= total then
        apply_zone(mapping, p, nil)
        return 'kept'
    end
    return 'lost'
end

-- mapping (Matcher.plan's, of a cape item) with its design zones kept readable; zones: src/capes.lua zones, tint_of: the
-- cape's {[cape LUT] = material LUT} or nil. Changes mapping in place; returns it and {picked, kept, lost} (how many
-- zones took a source color, kept their own colors, or read against nothing; diagnostics).
function Matcher.cape_zones(mapping, target, source, zones, tint_of)
    local parts = zone_parts(target, tint_of)
    local order = {}
    for z in pairs(zones) do
        local p = parts[z]
        if p then
            local area = 0.0
            if p.base then area = area + p.base.tex_area end
            if p.tint then area = area + p.tint.tex_area end
            order[#order + 1] = {zone = z, area = area}
        end
    end
    table.sort(order, function(x, y)
        if x.area ~= y.area then return x.area > y.area end
        return x.zone < y.zone
    end)
    local candidates = zone_candidates(source)
    local rule = {candidates = candidates, minor = zone_minor(source, candidates), none = {}, zones = zones,
                  group_of = {}, taken = {}}
    for i, g in ipairs(target.groups) do
        for _, row in ipairs(g.rows) do rule.group_of[row] = i end
    end
    local outcomes = {picked = 0, kept = 0, lost = 0}
    for _, entry in ipairs(order) do
        local outcome = keep_zone(mapping, entry.zone, zones[entry.zone], parts, rule)
        if outcome then outcomes[outcome] = outcomes[outcome] + 1 end
    end
    return mapping, outcomes
end

-- The emblems of a cape (src/capes.lua emblems: emblem-sheet layers, their colors the decal sheet's) kept readable
-- over the cloth under them as mapping colors it (Matcher.cape_zones applied first): one that read against half that
-- cloth (lightness contrast >= ZONE_READ) and no longer reads against half of it (< ZONE_LOST) takes the source color
-- reading against the most of it (zone_choice: by lightness, else by CIELAB distance), when that reads against half
-- (src/recolor.lua recolors its sheet cell);
-- else it stays, lost. The B-01 Tactical's dark gave the Drape of Glory's cloth its dark grey emblem's lightness and
-- the emblem vanished (user, image review 2026-10-07). Emblems go from the most cells. Returns {[emblem index] =
-- {source, L, a, b}} and {picked, lost} (diagnostics; match12.cape_emblems).
-- One emblem (see below): 'picked' and the source color it takes, 'lost', or nil (it did not read before, or still
-- reads).
local function keep_emblem(e, parts, mapping, candidates, minor)
    local good, total, mean0 = zone_reads(e.L, e.around, parts, nil, ZONE_READ)
    if total == 0 or 2 * good < total then return nil end
    local mean1
    good, total, mean1 = zone_reads(e.L, e.around, parts, mapping, ZONE_LOST)
    if 2 * good >= total then return nil end
    local best = zone_choice(candidates, minor, {around = e.around, parts = parts, plan = mapping, order = e.L >= mean0,
                                                 mean = mean1}, total)
    if best then
        return 'picked', {source = best.rep.key, L = best.L, a = best.a, b = best.b}
    end
    return 'lost'
end

function Matcher.cape_emblems(mapping, target, source, emblems, tint_of)
    local picks, outcomes = {}, {picked = 0, lost = 0}
    if not emblems or #emblems == 0 then return picks, outcomes end
    local parts = zone_parts(target, tint_of)
    local order = {}
    for i = 1, #emblems do order[i] = i end
    table.sort(order, function(x, y)
        if emblems[x].cells ~= emblems[y].cells then return emblems[x].cells > emblems[y].cells end
        return x < y
    end)
    local candidates = zone_candidates(source)
    local minor = zone_minor(source, candidates)
    for _, i in ipairs(order) do
        local outcome, pick = keep_emblem(emblems[i], parts, mapping, candidates, minor)
        if outcome then outcomes[outcome] = outcomes[outcome] + 1 end
        picks[i] = pick
    end
    return picks, outcomes
end

-- The source color a light neutral pattern takes: the source's neutral paint (palette groups under ACCENT_C model
-- chroma; hoods and, unless its suit is its paint, structure left out) nearest in lightness to the pattern's look, the
-- earlier in the palette on a tie; nil when the source has fewer than two (its one neutral would erase the pattern),
-- and never a saturated color (the UF-84 Doubt Killer's red trim). The CM-14 Physician's cream panels (13.7% of what
-- shows) stayed cream with the all-dark RS-67 Null Cipher; they take its grey (image review 2026-10-07;
-- match12.neutral_pattern_color).
local LIGHT_PATTERN_L = 40.0 -- a neutral pattern at least this light (model L) takes a source color
local function neutral_pattern_color(p, source)
    local pick, gap, count = nil, math.huge, 0
    for _, g in ipairs(palette_of(source)) do
        if not g.hood and (source.suit_paint or not is_structure(g)) and chroma(g.ma, g.mb) < ACCENT_C then
            count = count + 1
            local d = math.abs(g.L - p.L)
            if d < gap then pick, gap = g, d end
        end
    end
    return count >= 2 and pick or nil
end

-- The pattern plan: {target pattern texture -> {source, L, a, b (desired perceived color), gain}} (v11.4: the FS-23
-- Battle Master's yellow stripes): each target pattern whose color is an accent takes the source's accent (else its
-- second color), a light neutral one (model L at least LIGHT_PATTERN_L) the color neutral_pattern_color gives, unless
-- it already matches that color or a source color, or the source has none; a dark neutral one keeps its color, as a
-- dark undersuit does. gain: the target pattern's measured gain (its new texel color is the desired color through
-- it), or nil.
function Matcher.pattern_plan(target, source)
    local out = {}
    local accent = source_accent(source) or fallback_accent(source)
    if not accent then return out end
    for _, p in ipairs(target.patterns) do
        local pick
        if matches_source(p, source) then
            pick = nil
        elseif chroma(p.ma, p.mb) < ACCENT_C then
            pick = p.mL >= LIGHT_PATTERN_L and neutral_pattern_color(p, source) or nil
        elseif p.mL >= ACCENT_MIN_L then
            pick = accent
        end
        if pick and de2000(p.L, p.a, p.b, pick.L, pick.a, pick.b) >= KEEP_DE then
            out[p.pattern] = {source = pick.rep.key, L = pick.L, a = pick.a, b = pick.b, gain = p.gain}
        end
    end
    return out
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Matcher.use, npsum, pysum, sort_desc, chroma, is_neutral, neutral, looks_dark, light_of,
        is_structure, suit_is_paint, make_groups,
        group_look, measured_kit, luminance, light_scale, measure_rows, borrow_rows, item_patterns, copy_rows, paint_of,
        Matcher.item,
        most_salient,
        lighter_main, salience, fallback_accent, flat, cost, improve, search, shares,
        big_spread, palette_of, helmet_main, identity_of, nearest_lightness, structure_pairs, initial_assign, largest_paint,
        may_take, allowed_matrix,
        keep_matrix, anchor_of, closest_main, keep_matches, needs_flat_check, Matcher.pair_groups, source_accent,
        hue_gap, family_share, is_accent, matches_source, metal_echo, speck_across, choice, source_tint,
        reflected, painted, map_group, map_small_accents, Matcher.plan, zone_parts, row_linear, zone_lightness,
        apart, border_row, zone_reads, zone_candidates, zone_minor, on_cloth, zone_pick, zone_choice, apply_zone,
        cloth_of, keep_zone, Matcher.cape_zones,
        keep_emblem, Matcher.cape_emblems,
        neutral_pattern_color, Matcher.pattern_plan, Matcher.light}) do
        jit.off(fn, true)
    end
end

return Matcher
