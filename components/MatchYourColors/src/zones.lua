-- Match Your Colors: a cape's design zones and emblems kept readable when the cape is recolored (Recolor Cape: the
-- cape as the target). Attached to src/matcher.lua as Matcher.cape_zones and Matcher.cape_emblems (Zones.attach), with
-- the matcher's palette and accent; it was part of src/matcher.lua until v1.5. Nothing here runs per frame.
local Zones = {}

-- Set once by Zones.attach (the matcher's and the color model's functions).
local lab_to_linear, linear_to_lab, palette_of, source_accent, ACCENT_SOURCE_BIG
function Zones.attach(Matcher, colour)
    lab_to_linear, linear_to_lab = colour.lab_to_linear, colour.linear_to_lab
    palette_of, source_accent, ACCENT_SOURCE_BIG = Matcher.palette_of, Matcher.source_accent, Matcher.ACCENT_SOURCE_BIG
    Matcher.cape_zones, Matcher.cape_emblems = Zones.cape_zones, Zones.cape_emblems
end

-- Cape design zones (v1.3, KB match-your-colors-cape-tint; research/match12.py cape_zones; moved from src/matcher.lua in v1.5): an outside emblem, mark or
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
-- A design drawn by lightness: its own lightness and its border's at least STRONG_GAP apart (z.strong; lost_tone). It
-- never takes a color reading by hue alone: Proof of Faultless Virtue's chevrons and skull took the Bloodhound's black
-- on its red, the same lightness, and the cape read plain red (independent review 1 2026-10-14; the user chose
-- "readable by lightness", knowing it changes the agreed Judgment Day x Bloodhound marks the same way).
local STRONG_GAP = 2 * ZONE_READ
local function zone_choice(candidates, minor, z, total)
    local best, good = zone_pick(candidates, z, false)
    if best and 2 * good >= total then return best end
    if not z.strong then
        best, good = zone_pick(candidates, z, true)
        if best and 2 * good >= total then return best end
    end
    best, good = zone_pick(minor, z, false)
    if best and 2 * good >= total then return best end
    return nil
end

-- A design drawn by lightness (z.strong) that no source color keeps readable takes a neutral tone of its planned
-- border, LOST_TONE apart, its own light/dark order kept where that fits; key: the source color it is named after (the
-- first of the candidates). v1.5: Proof of Faultless Virtue's design went the FS-38 Eradicator's olive like its cloth.
local LOST_TONE = 30.0
local function lost_tone(z, key)
    local L = z.order and z.mean + LOST_TONE or z.mean - LOST_TONE
    if L < 8 or L > 92 then L = z.order and z.mean - LOST_TONE or z.mean + LOST_TONE end
    return {L = math.min(math.max(L, 8), 92), a = 0.0, b = 0.0, rep = {key = key}}
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
                  order = L0 >= mean0, mean = mean1, strong = math.abs(L0 - mean0) >= STRONG_GAP}
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
    -- the lost tone for a zone bordered mostly by cloth: one bordered by another zone reads with it as one shape (a
    -- stripe and its outline, Strength in Our Arms)
    local cloth_cells = 0
    if zone.cloth then
        local _, cells = zone_reads(L0, zone.cloth, parts, mapping, ZONE_READ)
        cloth_cells = cells
    end
    if zone.strong and 2 * cloth_cells >= total then
        apply_zone(mapping, p, lost_tone(zone, rule.candidates[1].rep.key))
        return 'picked'
    end
    return 'lost'
end

-- mapping (Matcher.plan's, of a cape item) with its design zones kept readable; zones: src/capes.lua zones, tint_of: the
-- cape's {[cape LUT] = material LUT} or nil. Changes mapping in place; returns it and {picked, kept, lost} (how many
-- zones took a source color, kept their own colors, or read against nothing; diagnostics).
function Zones.cape_zones(mapping, target, source, zones, tint_of)
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
-- over the cloth under them as mapping colors it (Zones.cape_zones applied first): one that read against half that
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
    local z = {around = e.around, parts = parts, plan = mapping, order = e.L >= mean0, mean = mean1,
               strong = math.abs(e.L - mean0) >= STRONG_GAP}
    local best = zone_choice(candidates, minor, z, total) or (z.strong and lost_tone(z, candidates[1].rep.key))
    if best then return 'picked', {source = best.rep.key, L = best.L, a = best.a, b = best.b} end
    return 'lost'
end

function Zones.cape_emblems(mapping, target, source, emblems, tint_of)
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

if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Zones.attach, zone_parts, row_linear, zone_lightness, apart, border_row, zone_reads,
        zone_candidates, zone_minor, on_cloth, zone_pick, zone_choice, lost_tone, apply_zone, cloth_of, keep_zone, Zones.cape_zones,
        keep_emblem, Zones.cape_emblems}) do
        jit.off(fn, true)
    end
end

return Zones
