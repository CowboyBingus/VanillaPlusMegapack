-- Match Your Colors: matcher v12 (research/match12.py), the plan of which color each target LUT row takes.
-- v10's quality was proven on all 21,330 helmet x armor pairs per direction; v11 fixed what the 2026-10-05
-- playtest showed; v12 judges by what the Armory shows (the measured appearance, src/appearance.lua).
--
-- An item is one kit's rows: every LUT row of every piece material. A measured kit (src/appearance.lua: every LUT of
-- its rows measured on the Armory front view) weighs each row by its screen pixels and sees it as it looks there:
-- perceived = s + g x mean albedo per channel (its measured response). Any other kit (new since the measurement, or
-- another body's pieces) weighs rows by ID-mask area (piece weight x coverage / materials of the piece) and sees
-- them as the model color (mean albedo, metal darkened; v11.5). Lens/light rows (mode >= 2.5) never change.
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

-- Groups of an item's paint rows: greedy by descending area, a row joins the first group of its metal and
-- camo class whose founding model color is within GROUP_DE.
local function make_groups(paint, paint_area)
    local groups = {}
    for _, row in ipairs(sort_desc({unpack(paint)}, 'area')) do
        local joined = false
        for _, g in ipairs(groups) do
            if g.metal == row.metal and g.camo == row.camo and de2000(g.mL, g.ma, g.mb, row.mL, row.ma, row.mb) < GROUP_DE then
                g.rows[#g.rows + 1] = row
                g.area, g.under = g.area + row.area, g.under + row.under
                joined = true
                break
            end
        end
        if not joined then
            groups[#groups + 1] = {L = row.L, a = row.a, b = row.b, mL = row.mL, ma = row.ma, mb = row.mb,
                                   metal = row.metal, camo = row.camo, rows = {row}, area = row.area, under = row.under,
                                   rep = row}
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

-- Measured rows: screen pixels for area (the undersuit part scaled alike), the light they show (pixels x mean
-- screen luminance) and the perceived color of the row's response (row.cal = {gr, gg, gb, sr, sg, sb}; Colour.seen:
-- gloss counts on neutral paint only), else the model color.
local function measure_rows(rows, kit, look)
    for _, row in ipairs(rows) do
        local frac = row.area > 0 and row.under / row.area or 0.0
        local seen_row = kit.rows[row.key]
        row.area, row.light = seen_row and seen_row[1] or 0, seen_row and seen_row[2] or 0
        row.under = row.area * frac
        local cal = look.row(row.lut, row.row)
        if cal then
            row.cal = cal
            row.lin = {seen(cal, row.ar, row.ag, row.ab)}
            row.L, row.a, row.b = linear_to_lab(row.lin[1], row.lin[2], row.lin[3])
        else
            row.lin = {lab_to_linear(row.L, row.a, row.b)}
        end
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

-- An item from rows {key, lut, row, area, under, L, a, b (model), ar, ag, ab (mean linear albedo), metal, camo,
-- mode, full} in first-seen order; armor: true for an armor kit (identity color by salience); patterns:
-- {{pattern, area, r, g, b (texel 0, sRGB)}, ...} or nil; look: nil or {kit = Appearance kit entry or nil, row =
-- Appearance row function}.
-- The item's own copies of the analysis rows (the analysis is kept and cached as it is), with the model color and
-- texture area kept as mL, ma, mb, tex_area.
local function copy_rows(analysis_rows)
    local rows = {}
    for i, source in ipairs(analysis_rows) do
        local row = {}
        for k, v in pairs(source) do row[k] = v end
        row.lens = row.mode >= 2.5
        row.mL, row.ma, row.mb, row.tex_area = row.L, row.a, row.b, row.area
        rows[i] = row
    end
    return rows
end

-- The paint rows (not lens) into item.paint; returns the paint area (a measured kit's pattern pixels included; 1
-- when nothing shows).
local function paint_of(item, kit)
    local paint_area = 0
    for _, row in ipairs(item.rows) do
        if not row.lens then
            item.paint[#item.paint + 1] = row
            paint_area = paint_area + row.area
        end
    end
    if item.measured then
        for _, m in pairs(kit.patterns) do paint_area = paint_area + m.px end
    end
    if paint_area == 0 then paint_area = 1.0 end
    return paint_area
end

function Matcher.item(analysis_rows, armor, patterns, look)
    local kit = look and look.kit
    local rows = copy_rows(analysis_rows)
    local item = {rows = rows, armor = armor, paint = {}, measured = measured_kit(rows, kit)}
    if item.measured then measure_rows(rows, kit, look) end
    local paint_area = paint_of(item, kit)
    item.paint_area = paint_area
    item.groups = make_groups(item.paint, paint_area)
    if item.measured then
        for _, g in ipairs(item.groups) do g.L, g.a, g.b = group_look(g.rows) end
    end
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

-- The source's identity color: a helmet's largest paint group; an armor's most salient (undersuit area weighs
-- UNDER_SALIENCE, dark neutrals DARK_SALIENCE, DARK_SALIENCE_TEXTURE when unmeasured). A measured armor whose most
-- salient color looks dark but which has a main color (share >= LARGE_AREA) that looks light and shows more light
-- reads as that color (the SR-64 Cinderblock as its light plates, not its dark straps). Structure groups are skipped
-- while any other group exists.
-- An armor's most salient group of pool (undersuit area weighs UNDER_SALIENCE, dark neutrals DARK_SALIENCE,
-- DARK_SALIENCE_TEXTURE when unmeasured).
local function most_salient(source, pool)
    local dark = source.measured and DARK_SALIENCE or DARK_SALIENCE_TEXTURE
    local main, best = pool[1], -math.huge
    for _, g in ipairs(pool) do
        local salience = (g.area - g.under * (1 - UNDER_SALIENCE)) / source.paint_area
            * (neutral(g) and dark or 1.0)
        if salience > best then best, main = salience, g end
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

local function identity_of(source, palette)
    local pool = {}
    for _, g in ipairs(palette) do if not is_structure(g) then pool[#pool + 1] = g end end
    if #pool == 0 then pool = palette end
    if not source.armor then return pool[1] end
    local main = most_salient(source, pool)
    if not source.measured or not looks_dark(main) then return main end
    return lighter_main(pool, main) or main
end

-- Structure groups keep a dark neutral: the source's nearest by lightness, when it has one.
local function structure_pairs(targets, palette, pairs)
    local neutrals = {}
    for _, g in ipairs(palette) do if neutral(g) then neutrals[#neutrals + 1] = g end end
    local paint = {}
    for _, g in ipairs(targets) do
        if is_structure(g) and #neutrals > 0 then
            local pick, gap = nil, math.huge
            for _, n in ipairs(neutrals) do
                local d = math.abs(n.L - g.L)
                if d < gap then pick, gap = n, d end
            end
            pairs[#pairs + 1] = {g, pick}
        elseif not is_structure(g) then
            paint[#paint + 1] = g
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
-- shares).
local function largest_paint(s)
    local largest
    for j = 1, #s do
        if not is_structure(s[j]) and (largest == nil or s[j].share > s[largest].share) then largest = j end
    end
    if largest then return largest end
    largest = 1
    for j = 2, #s do if s[j].share > s[largest].share then largest = j end end
    return largest
end

-- Whether target group g may take source color j (keep: g already matches it). A large area takes only main colors,
-- one it already matches or the largest, never a trim; an undersuit color goes only to a small dark neutral group.
local function may_take(g, s, j, keep, largest)
    local small = g.share < LARGE_AREA
    local size_ok = small or s[j].share >= MAIN_COLOR or keep or j == largest
    return size_ok and (keep or not is_structure(s[j]) or (small and neutral(g)))
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

-- Pairs {target group, source group} and the anchor group (nil without paint) (match12.py pair_groups).
function Matcher.pair_groups(target, source)
    local targets = {}
    for _, g in ipairs(target.groups) do if g.share >= TGT_MIN_SHARE then targets[#targets + 1] = g end end
    local palette = palette_of(source)
    local pairs = {}
    if #targets == 0 or #palette == 0 then return pairs, nil end
    local main = identity_of(source, palette)
    local t = structure_pairs(targets, palette, pairs)
    if #t == 0 then return pairs, nil end
    local s = palette
    s.share_sum = npsum(shares(s), #s)
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
local function is_accent(g, anchor)
    local c = chroma(g.ma, g.mb)
    if g == anchor or g.share > ACCENT_MAX_SHARE or c < ACCENT_C then return false end
    return g.share <= ACCENT_SMALL or c >= ACCENT_VIVID
end

-- Whether group g already matches one of the source's colors (share >= PAIR_MIN_SHARE), as they look.
local function matches_source(g, source)
    for _, s in ipairs(source.groups) do
        if s.share >= PAIR_MIN_SHARE and de2000(g.L, g.a, g.b, s.L, s.a, s.b) < KEEP_DE then return true end
    end
    return false
end

-- The source group a target group takes and how ('pair' or 'accent'); nil keeps its color.
local function choice(t, s, anchor, accent, source)
    if not is_accent(t, anchor) then return s, 'pair' end
    if accent == nil or t.mL < ACCENT_MIN_L or matches_source(t, source) then return nil end
    return accent, 'accent'
end

-- A CIELAB color with `lift` linear light added to each channel (white; negative removes it, down to black).
local function reflected(L, a, b, lift)
    local r, g, bl = lab_to_linear(L, a, b)
    return linear_to_lab(r + lift, g + lift, bl + lift)
end

-- mapping[row key] = {source, kind, L, a, b} for every row of target group t taking source color src: each row
-- keeps its lightness offset from its group and its hue offset scaled with the chroma change; an unmeasured bare
-- metal row taking paint aims PAINT_REFLECTION lighter.
local function map_group(mapping, t, kind, src)
    local t_c = chroma(t.a, t.b)
    local scale = t_c > 1.0 and math.min(1.0, chroma(src.a, src.b) / t_c) or 1.0
    local src_full = src.rep.full == true
    for _, row in ipairs(t.rows) do
        local L, a, b = src.L + (row.L - t.L), src.a + (row.a - t.a) * scale, src.b + (row.b - t.b) * scale
        if not row.cal and row.full == true and not src_full then -- bare metal taking paint: the paint's sheen
            L, a, b = reflected(L, a, b, PAINT_REFLECTION)
        end
        mapping[row.key] = {source = src.rep.key, kind = kind, L = L, a = a, b = b, cal = row.cal}
    end
end

-- The plan: {target row key -> {source = source row key, kind, L, a, b (desired perceived color), cal (the row's
-- measured response, or nil)}} for every recolored row.
function Matcher.plan(target, source)
    local mapping = {}
    local pairs, anchor = Matcher.pair_groups(target, source)
    local accent = source_accent(source)
    for _, pair in ipairs(pairs) do
        local t = pair[1]
        local src, kind = choice(t, pair[2], anchor, accent, source)
        if src then map_group(mapping, t, kind, src) end
    end
    if accent then -- accent groups below the pairing minimum (v11.4: the RS-67 Null Cipher's 0.9% yellow)
        for _, t in ipairs(target.groups) do
            if t.share < TGT_MIN_SHARE and chroma(t.ma, t.mb) >= ACCENT_C and t.mL >= ACCENT_MIN_L
                and not matches_source(t, source) then
                map_group(mapping, t, 'accent', accent)
            end
        end
    end
    return mapping
end

-- The pattern plan: {target pattern texture -> {source, L, a, b (desired perceived color), gain}} (v11.4: the FS-23
-- Battle Master's yellow stripes): each target pattern whose color is an accent takes the source's accent, unless it
-- already matches that accent or a source color, or the source has none. gain: the target pattern's measured gain
-- (its new texel color is the desired color through it), or nil.
function Matcher.pattern_plan(target, source)
    local out = {}
    local accent = source_accent(source)
    if not accent then return out end
    for _, p in ipairs(target.patterns) do
        if chroma(p.ma, p.mb) >= ACCENT_C and p.mL >= ACCENT_MIN_L and not matches_source(p, source)
            and de2000(p.L, p.a, p.b, accent.L, accent.a, accent.b) >= KEEP_DE then
            out[p.pattern] = {source = accent.rep.key, L = accent.L, a = accent.a, b = accent.b, gain = p.gain}
        end
    end
    return out
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Matcher.use, npsum, sort_desc, chroma, is_neutral, neutral, looks_dark, light_of,
        is_structure, make_groups,
        group_look, measured_kit, measure_rows, item_patterns, copy_rows, paint_of, Matcher.item, most_salient,
        lighter_main, flat, cost, improve, search, shares,
        big_spread, palette_of, identity_of, structure_pairs, initial_assign, largest_paint, may_take, allowed_matrix,
        keep_matrix, anchor_of, closest_main, keep_matches, needs_flat_check, Matcher.pair_groups, source_accent,
        is_accent, matches_source, choice,
        reflected, map_group, Matcher.plan, Matcher.pattern_plan}) do
        jit.off(fn, true)
    end
end

return Matcher
