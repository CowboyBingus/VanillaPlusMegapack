-- Match Your Colors: the perceived color of a material-LUT row, as research/effective.py and match.py
-- compute it (a port of filediver's lut.frag albedo path).
--
-- For one LUT row the shader blends the base color (column 0, or the camo colors 16-19 through the camo
-- tiler) towards column 2 by detail intensity, towards column 6 by detail roughness x camo mix and towards
-- column 5 by roughness squared x camo mix, in sRGB, then converts to linear. Detail intensity and roughness
-- come from the global detail tiler layer (column 1 x) and the row's controls (columns 1, 3, 4). The mesh's
-- base data is taken as neutral (roughness 0.5, no occlusion), so the result is per row. The mean linear
-- albedo over 512 detail texels, darkened by 0.55 x metallic (column 6 w), in CIELAB, is the row's perceived
-- color. A row at least METAL_FULL metallic is bare metal (the matcher's paint reflection, src/matcher.lua).
-- Nothing here runs per frame.
local Colour = {}

local SAMPLES = 512
local METAL_DARKEN = 0.55
local METAL_FULL = 0.9
local WHITE_X, WHITE_Z = 0.95047, 1.08883
local EPSILON = (6 / 29) ^ 3
local KAPPA = 3 * (6 / 29) ^ 2

-- Clamped to [0, 1] without branches (min and max compile to single instructions: fewer side traces).
local min, max = math.min, math.max
local function clip(x)
    return min(max(x, 0), 1)
end

local function srgb_to_linear(c)
    if c < 0.000061 then c = 0.000061 end
    if c > 0.04045 then return (c * 0.947867 + 0.052133) ^ 2.4 end
    return c * 0.0774
end
Colour.srgb_to_linear = srgb_to_linear

-- Python's int() then % n for a float layer index.
local function layer_index(x, n)
    local i = x >= 0 and math.floor(x) or math.ceil(x)
    return i % n
end

local function lab_f(t)
    if t > EPSILON then return t ^ (1 / 3) end
    return t / KAPPA + 4 / 29
end

-- CIELAB of a linear RGB triple (clipped to [0, 1]), D65.
function Colour.linear_to_lab(r, g, b)
    r, g, b = clip(r), clip(g), clip(b)
    local fx = lab_f((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / WHITE_X)
    local fy = lab_f(0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
    local fz = lab_f((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / WHITE_Z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

-- CIELAB of an sRGB color as the shader decodes it (LUT values).
function Colour.srgb_to_lab(r, g, b)
    return Colour.linear_to_lab(srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b))
end

local function lab_finv(t)
    if t > 6 / 29 then return t * t * t end
    return 3 * (6 / 29) ^ 2 * (t - 4 / 29)
end

local function linear_to_srgb(x)
    x = clip(x)
    if x > 0.0031308 then return 1.055 * x ^ (1 / 2.4) - 0.055 end
    return 12.92 * x
end
Colour.linear_to_srgb = linear_to_srgb

-- The linear RGB of a CIELAB color (D65), not clipped.
function Colour.lab_to_linear(L, a, b)
    local fy = (L + 16) / 116
    local fx, fz = fy + a / 500, fy - b / 200
    local x, y, z = lab_finv(fx) * WHITE_X, lab_finv(fy), lab_finv(fz) * WHITE_Z
    return 3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
        -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
        0.0556434 * x - 0.2040259 * y + 1.0572252 * z
end

-- The sRGB color of a CIELAB color (D65), clipped to the displayable range.
function Colour.lab_to_srgb(L, a, b)
    local r, g, bl = Colour.lab_to_linear(L, a, b)
    return linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(bl)
end

-- The mean hue angle of CIEDE2000.
local function mean_hue(h1p, h2p, zero)
    local hsum = h1p + h2p
    if zero then return hsum end
    if math.abs(h1p - h2p) > 180 then return hsum < 360 and (hsum + 360) / 2 or (hsum - 360) / 2 end
    return hsum / 2
end

-- CIEDE2000 difference of two Lab colors (match.py's de2000, scalar).
function Colour.de2000(L1, a1, b1, L2, a2, b2)
    local C1, C2 = math.sqrt(a1 * a1 + b1 * b1), math.sqrt(a2 * a2 + b2 * b2)
    local Cm7 = ((C1 + C2) / 2) ^ 7
    local G = 0.5 * (1 - math.sqrt(Cm7 / (Cm7 + 25 ^ 7)))
    local a1p, a2p = (1 + G) * a1, (1 + G) * a2
    local C1p, C2p = math.sqrt(a1p * a1p + b1 * b1), math.sqrt(a2p * a2p + b2 * b2)
    local h1p = math.deg(math.atan2(b1, a1p)) % 360
    local h2p = math.deg(math.atan2(b2, a2p)) % 360
    local zero = C1p * C2p == 0
    local dhp = h2p - h1p
    if dhp > 180 then dhp = dhp - 360 elseif dhp < -180 then dhp = dhp + 360 end
    if zero then dhp = 0 end
    local dHp = 2 * math.sqrt(C1p * C2p) * math.sin(math.rad(dhp / 2))
    local Lpm, Cpm = (L1 + L2) / 2, (C1p + C2p) / 2
    local hpm = mean_hue(h1p, h2p, zero)
    local T = 1 - 0.17 * math.cos(math.rad(hpm - 30)) + 0.24 * math.cos(math.rad(2 * hpm))
        + 0.32 * math.cos(math.rad(3 * hpm + 6)) - 0.20 * math.cos(math.rad(4 * hpm - 63))
    local dtheta = 30 * math.exp(-(((hpm - 275) / 25) ^ 2))
    local Cpm7 = Cpm ^ 7
    local Rc = 2 * math.sqrt(Cpm7 / (Cpm7 + 25 ^ 7))
    local Sl = 1 + 0.015 * (Lpm - 50) ^ 2 / math.sqrt(20 + (Lpm - 50) ^ 2)
    local Sc, Sh = 1 + 0.045 * Cpm, 1 + 0.015 * Cpm * T
    local Rt = -math.sin(math.rad(2 * dtheta)) * Rc
    local l, c, h = (L2 - L1) / Sl, (C2p - C1p) / Sc, dHp / Sh
    return math.sqrt(l * l + c * c + h * h + Rt * c * h)
end

-- A row's columns as a flat Lua array: row_values(values, width, row)[column * 4 + channel + 1].
local function row_values(values, width, row)
    local out = {}
    local base = row * width * 4
    for k = 0, width * 4 - 1 do out[k + 1] = values[base + k] end
    return out
end
Colour.row_values = row_values

-- The model over the shared samples: detail = {layer -> double array of 512 x RGBA}, camo likewise, and
-- their layer counts. row_info(values, width, row) -> L, a, b, metal (bool), camo (bool), mode, full (bool:
-- bare metal, metallic >= METAL_FULL), and the mean linear albedo r, g, b (the measured response's input).
function Colour.new(detail, detail_layers, camo, camo_layers)
    local self = {}

    -- Sums the camo-blended sample colors into the caller's accumulators: returns the camo mix and the
    -- blended sRGB color of sample i. c: the row (row_values).
    local function camo_sample(c, s, i, md0, md1)
        local m0 = clip((s[i * 4] - 0.5) * c[85] + c[86])
        local m1 = clip((s[i * 4 + 1] - 0.5) * c[85] + c[86])
        local m2 = clip((s[i * 4 + 2] - 0.5) * c[85] + c[86])
        local r = ((c[65] * (1 - m0) + c[69] * m0) * (1 - m1) + c[73] * m1) * (1 - m2) + c[77] * m2
        local g = ((c[66] * (1 - m0) + c[70] * m0) * (1 - m1) + c[74] * m1) * (1 - m2) + c[78] * m2
        local b = ((c[67] * (1 - m0) + c[71] * m0) * (1 - m1) + c[75] * m1) * (1 - m2) + c[79] * m2
        if c[4] ~= 1.0 then
            local mix = clip(md0 * c[72] + md1 * c[76] - c[84])
            return mix, r * (1 - mix) + c[1] * mix, g * (1 - mix) + c[2] * mix, b * (1 - mix) + c[3] * mix
        end
        return 1, r, g, b
    end

    -- A sample's sRGB color: the row's color r, g, b (its base, or its camo blend of mix) through the detail's
    -- intensity and roughness at the detail sample's controls less 0.5 (md0, md1).
    local function shade(c, md0, md1, mix, r, g, b)
        local rough = clip(md0 * c[17] + md1 * c[18] + c[8])
        local intensity = clip(md0 * c[13] + md1 * c[14] + c[7])
        local cr = rough * mix
        local cr2 = cr * rough
        r, g, b = r + intensity * (c[9] - r), g + intensity * (c[10] - g), b + intensity * (c[11] - b)
        r, g, b = r + cr * (c[25] - r), g + cr * (c[26] - g), b + cr * (c[27] - b)
        return r + cr2 * (c[21] - r), g + cr2 * (c[22] - g), b + cr2 * (c[23] - b)
    end

    -- A detail layer's distinct samples (made on its first use): first[i + 1], the first sample whose controls (z, w)
    -- are sample i's, and those first samples, in order. A row without camo shows one color per distinct pair: the 26
    -- layers have 44-325 of 512 (fits' albedos: 52% of their samples, research/profiling/albedo_census.lua; srgb_to_linear
    -- was 14% of the mod's time in game, harness profile 2026-10-11, KB match-your-colors-stress-test).
    local distinct = {}
    local function distinct_of(layer, d)
        local found = distinct[layer]
        if found then return found end
        local first, firsts, seen = {}, {}, {}
        for i = 0, SAMPLES - 1 do
            local z, w = d[i * 4 + 2], d[i * 4 + 3]
            local j
            if z == z and w == w then -- a NaN (never in the game's textures) is no key: its sample stands alone
                local by_w = seen[z]
                if not by_w then
                    by_w = {}
                    seen[z] = by_w
                end
                j = by_w[w]
                if not j then by_w[w] = i + 1 end
            end
            if not j then
                j = i + 1
                firsts[#firsts + 1] = i
            end
            first[i + 1] = j
        end
        found = {first = first, firsts = firsts}
        distinct[layer] = found
        return found
    end
    local lin_r, lin_g, lin_b = {}, {}, {} -- linear colors of a layer's distinct samples, by sample index + 1

    -- Every sample shaded and linearized (camo: its own color at nearly every sample).
    local function albedo_each(c, d, s)
        local sum_r, sum_g, sum_b = 0, 0, 0
        for i = 0, SAMPLES - 1 do
            local md0, md1 = 0, 0
            if d then md0, md1 = d[i * 4 + 2] - 0.5, d[i * 4 + 3] - 0.5 end
            local r, g, b = shade(c, md0, md1, camo_sample(c, s, i, md0, md1))
            sum_r, sum_g, sum_b = sum_r + srgb_to_linear(r), sum_g + srgb_to_linear(g), sum_b + srgb_to_linear(b)
        end
        return sum_r / SAMPLES, sum_g / SAMPLES, sum_b / SAMPLES
    end

    -- Mean linear albedo of a row over the samples. c[column * 4 + channel + 1]; columns 0 base, 1 detail
    -- controls, 2 detail color, 3 intensity controls, 4 roughness controls, 5/6 wear colors, 16-19 camo
    -- colors, 20 camo extra (w), 21 camo controls. Without camo each distinct sample color is linearized once and
    -- the sums still run over all samples in order: the same bits as shading every sample (v1.3).
    local function albedo(c)
        local layer = c[4] <= 3.0 and layer_index(c[5], detail_layers)
        local d = layer and detail[layer] or nil
        local s = c[88] >= 0.0 and camo[layer_index(c[88], camo_layers)] or nil
        if s then return albedo_each(c, d, s) end
        local sum_r, sum_g, sum_b = 0, 0, 0
        if not d then -- every sample alike
            local r, g, b = shade(c, 0, 0, 1, c[1], c[2], c[3])
            r, g, b = srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)
            for _ = 1, SAMPLES do sum_r, sum_g, sum_b = sum_r + r, sum_g + g, sum_b + b end
            return sum_r / SAMPLES, sum_g / SAMPLES, sum_b / SAMPLES
        end
        local found = distinct_of(layer, d)
        local firsts, first = found.firsts, found.first
        for k = 1, #firsts do
            local i = firsts[k]
            local r, g, b = shade(c, d[i * 4 + 2] - 0.5, d[i * 4 + 3] - 0.5, 1, c[1], c[2], c[3])
            lin_r[i + 1], lin_g[i + 1], lin_b[i + 1] = srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)
        end
        for i = 1, SAMPLES do
            local j = first[i]
            sum_r, sum_g, sum_b = sum_r + lin_r[j], sum_g + lin_g[j], sum_b + lin_b[j]
        end
        return sum_r / SAMPLES, sum_g / SAMPLES, sum_b / SAMPLES
    end

    -- The mean linear albedo of a row (row_values): r, g, b. perceived_of and look_of take it, so a caller that needs
    -- both the paint's color and the look of one row computes its 512 samples once (src/transfer.lua fit).
    self.albedo = albedo

    -- The CIELAB of a row's mean albedo (no metal darkening): its paint's own color (the transfer's reference).
    function self.albedo_lab(c)
        local r, g, b = albedo(c)
        return Colour.linear_to_lab(r, g, b)
    end

    -- The perceived color of a row given as row_values, from its albedo r, g, b: L, a, b and its metallic (column 6 w,
    -- clipped).
    function self.perceived_of(c, r, g, b)
        local metallic = clip(c[28])
        local dark = 1 - METAL_DARKEN * metallic
        local L, A, B = Colour.linear_to_lab(r * dark, g * dark, b * dark)
        return L, A, B, metallic
    end
    function self.perceived(c)
        local r, g, b = albedo(c)
        return self.perceived_of(c, r, g, b)
    end

    -- The look of a row through its measured response cal = {gr, gg, gb, sr, sg, sb} (src/appearance.lua): the
    -- CIELAB of Colour.seen(g x mean albedo, s); look_of from the albedo r, g, b.
    function self.look_of(r, g, b, cal, soft)
        return Colour.linear_to_lab(Colour.seen(cal, r, g, b, soft))
    end
    function self.look(c, cal, soft)
        local r, g, b = albedo(c)
        return self.look_of(r, g, b, cal, soft)
    end

    function self.row_info(values, width, row)
        local c = row_values(values, width, row)
        local r, g, b = albedo(c)
        local metallic = clip(c[28])
        local dark = 1 - METAL_DARKEN * metallic
        local L, A, B = Colour.linear_to_lab(r * dark, g * dark, b * dark)
        return L, A, B, metallic > 0.5, c[88] >= 0, c[4], metallic >= METAL_FULL, r, g, b
    end
    -- once per layer and session: interpreted (the hot loops above stay compiled)
    if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(distinct_of, true) end
    return self
end

-- The color the eye takes for a paint through its measured response cal = {gr, gg, gb, sr, sg, sb} at mean albedo
-- (r, g, b): its diffuse color g x albedo plus its gloss floor s, the floor weighed 1 - chroma / GLOSS_C (clipped to
-- 0-1): on neutral paint gloss reads as lightness, on colored paint as highlights over the paint (match12.seen).
-- soft: a matte soft row (Colour.is_soft: cloth) counts its whole floor, a broad sheen the eye takes for lightness on
-- any paint; the fit passes it (src/transfer.lua), the items' own looks keep the hard rule (match12.perceived_key).
-- Display-linear r, g, b, clipped at 0.
Colour.GLOSS_C = 20.0
function Colour.seen(cal, r, g, b, soft)
    local dr, dg, db = max(cal[1] * r, 0), max(cal[2] * g, 0), max(cal[3] * b, 0)
    local w = 1
    if not soft then
        local _, A, B = Colour.linear_to_lab(dr, dg, db)
        w = min(max(1 - math.sqrt(A * A + B * B) / Colour.GLOSS_C, 0), 1)
    end
    return max(dr + w * cal[4], 0), max(dg + w * cal[5], 0), max(db + w * cal[6], 0)
end

-- Whether a LUT row (row_values) is matte soft: mode 1 (c[4], column 0 w: cloth, leather, rubber) with no specular
-- (c[33], column 8 x, at 0: the cloth rows; glossy leather has 0.3, the UF-84 Doubt Killer's red trim among them).
function Colour.is_soft(c) return math.abs(c[4] - 1) < 0.5 and math.abs(c[33]) < 0.05 end

-- numpy's pairwise sum of a[1..n] (float64, contiguous), as np.add.reduce computes it for n <= 128.
function Colour.npsum(a, n)
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

-- Python's sum() of floats a[1..n] (Python 3.12+: Neumaier's compensated sum, as CPython's builtin_sum computes it):
-- the first value, then each next one with the rounding error carried apart, the carried error added at the end when
-- finite. A plain loop can differ in the last bit: the Cover of Darkness's paint summed to 0.9999999999999999 instead
-- of 1.0, which put its 0.35 lining above ACCENT_MAX_SHARE (2026-10-07).
function Colour.pysum(a, n)
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

-- A group's perceived color: its rows' perceived linear colors, mean by screen pixels (by texture area when none
-- shows; each row alike when neither does: rows 0 of no coverage, src/kits.lua add_rows), summed in row order
-- (match12.group_look).
-- A group's perceived color (src/matcher.lua): its rows' perceived linear colors, mean by screen pixels (by texture
-- area when none shows; each row alike when neither does: rows 0 of no coverage, src/kits.lua add_rows), summed in row
-- order (match12.group_look).
function Colour.weight_field(rows)
    local pixels, texels = 0, 0
    for _, row in ipairs(rows) do pixels, texels = pixels + row.area, texels + row.tex_area end
    if pixels > 0 then return 'area' end
    return texels > 0 and 'tex_area' or nil
end
function Colour.group_look(rows)
    local field = Colour.weight_field(rows)
    local r, g, b, weight = 0, 0, 0, 0
    for _, row in ipairs(rows) do
        local w = field and row[field] or 1.0
        r, g, b, weight = r + w * row.lin[1], g + w * row.lin[2], b + w * row.lin[3], weight + w
    end
    weight = math.max(weight, 1e-12)
    return Colour.linear_to_lab(math.max(r / weight, 0), math.max(g / weight, 0), math.max(b / weight, 0))
end

-- Paint as seen, its highlights apart, as the eye takes them (src/matcher.lua map_group; research/match12.py
-- diffuse_colors): a target row aims at the source's look less its gloss, keeps its own offset from its group as
-- diffuse colors, and shows its own gloss over it. A look counts a glossy paint's highlights as color: the AF-50 Noxious Ranger's glossy olive mask (paint L 43.6
-- chroma 11, gloss floor 0.10) looks L 44.8 chroma 6, and the SC-30 Trailblazer Scout's matte coat fitted to that look
-- turned a pale grey (user 2026-10-10: "The armor was much lighter tint than the helmet's green"); a white glossy B-01
-- Tactical helmet fitted to the CM-14 Physician's matte grey look got paint L 15 under its own highlights and read
-- black ("some helmets' gray is rendering as slightly darker than their respective armors"). On the game's one-helmet
-- one-armor sets the plans come nearer their own colors (median dE helmets from paint 4.35 -> 3.35, armors from paint
-- 5.55 -> 5.01, helmets from metal 4.65 -> 4.55; armors from metal 6.07 -> 6.45).
-- A measured row's diffuse color (its response's g x its mean albedo; a cape's borrowed response has no look of its
-- own: its look is its model color), or nil.
function Colour.row_diffuse(row)
    local c = row.cal
    if c and row.lin then return c[1] * row.ar, c[2] * row.ag, c[3] * row.ab end
end

-- The source group's diffuse color and target group t's (Lab, for map_group): each look less its rows' gloss, weighed
-- as group_look weighs them; a look as it is where none of its rows shows gloss.
function Colour.diffuse_colors(t, src)
    local field = Colour.weight_field(src.rows)
    local fr, fg, fb, weight = 0, 0, 0, 0
    for _, row in ipairs(src.rows) do
        local w, r, g, b = field and row[field] or 1.0, Colour.row_diffuse(row)
        if r then fr, fg, fb = fr + w * (row.lin[1] - r), fg + w * (row.lin[2] - g), fb + w * (row.lin[3] - b) end
        weight = weight + w
    end
    local sL, sa, sb = src.L, src.a, src.b
    if fr ~= 0 or fg ~= 0 or fb ~= 0 then
        local r, g, b = Colour.lab_to_linear(src.L, src.a, src.b)
        weight = math.max(weight, 1e-12)
        sL, sa, sb = Colour.linear_to_lab(math.max(r - fr / weight, 0), math.max(g - fg / weight, 0), math.max(b - fb / weight, 0))
    end
    field = Colour.weight_field(t.rows)
    local tr, tg, tb, any = 0, 0, 0, false
    weight = 0
    for _, row in ipairs(t.rows) do
        local w, r, g, b = field and row[field] or 1.0, Colour.row_diffuse(row)
        if r then any = true elseif row.lin then r, g, b = row.lin[1], row.lin[2], row.lin[3] else r, g, b = 0, 0, 0 end
        tr, tg, tb, weight = tr + w * r, tg + w * g, tb + w * b, weight + w
    end
    if not any then return sL, sa, sb, t.L, t.a, t.b end
    weight = math.max(weight, 1e-12)
    local tL, ta, tb2 = Colour.linear_to_lab(math.max(tr / weight, 0), math.max(tg / weight, 0), math.max(tb / weight, 0))
    return sL, sa, sb, tL, ta, tb2, true
end

-- A diffuse color (Lab) with row c's gloss floor over it, weighed as Colour.seen weighs it on hard paint. A neutral
-- diffuse color (chroma under GLOSS_TINT_C: src/matcher.lua NEUTRAL_TINT_C) takes at most that much of the floor's
-- tint: the FS-05 Marksman's red dome, its floor a strong cyan (R 0.002, G and B 0.05), aimed at L 27 a -14.5 b -4.4
-- for the pure black cape Honored Heirloom and was painted teal (independent review 2026-10-11, fresh gallery case
-- 103); a slight cast stays in the goal (the B-24 Enforcer's coat cancels its warm floor through it, chroma 3.9).
Colour.GLOSS_TINT_C = 5.0
function Colour.with_gloss(L, a, b, c)
    local neutral = math.sqrt(a * a + b * b) < Colour.GLOSS_TINT_C
    local w = math.min(math.max(1 - math.sqrt(a * a + b * b) / Colour.GLOSS_C, 0), 1)
    local r, g, bl = Colour.lab_to_linear(L, a, b)
    local gL, ga, gb = Colour.linear_to_lab(math.max(r + w * c[4], 0), math.max(g + w * c[5], 0),
                                            math.max(bl + w * c[6], 0))
    local gc = math.sqrt(ga * ga + gb * gb)
    if neutral and gc > Colour.GLOSS_TINT_C then
        ga, gb = ga * (Colour.GLOSS_TINT_C / gc), gb * (Colour.GLOSS_TINT_C / gc)
    end
    return gL, ga, gb
end

-- A cape's colors (src/matcher.lua identity_of; pool: largest first) with the outside first: when its largest color
-- shows mostly on its lining (under half its area on the outside: src/capes.lua source_rows, row.outside), by their
-- area on the outside, most first, then by share; else as they are. Its lining (row 4, weighed 7 to the outside's 13)
-- outweighed the outside on some capes and the armor took it, a grey under the black Vision of Freedom, a tan under the
-- charcoal Standard of Safe Distance (independent review 2026-10-11; the user chose "outside first"); a largest color
-- mostly outside stays (da9ebb65's navy, 59% outside: by outside area alone its red, a little larger there, took the
-- helmet and the plates and the navy left the outfit, round 30).
function Colour.outside_first(pool)
    local area, outside, sorted = {}, {}, {}
    for i, g in ipairs(pool) do
        area[g], outside[g], sorted[i] = 0, 0, g
        for _, row in ipairs(g.rows) do area[g], outside[g] = area[g] + row.area, outside[g] + (row.outside or 0) end
    end
    local top = pool[1]
    if not top or outside[top] >= 0.5 * area[top] then return pool end
    table.sort(sorted, function(x, y) return outside[x] > outside[y] or (outside[x] == outside[y] and x.share > y.share) end)
    return sorted
end

-- Whether every color of palette s besides s[j_main] that is a main color (share min_share or more) is vivid (model
-- chroma vivid_c or more): a cape of one color and vivid ones (src/matcher.lua guard_part, two-tone).
function Colour.two_tone(s, j_main, min_share, vivid_c)
    for j = 1, #s do
        if j ~= j_main and s[j].share >= min_share and math.sqrt(s[j].ma ^ 2 + s[j].mb ^ 2) < vivid_c then return false end
    end
    return true
end

-- The group of `list` nearest to g by lightness (the first of equal gaps; src/matcher.lua).
function Colour.nearest_lightness(list, g)
    local pick, gap = nil, math.huge
    for _, n in ipairs(list) do
        local d = math.abs(n.L - g.L)
        if d < gap then pick, gap = n, d end
    end
    return pick
end

-- A cape of no dark neutral (src/matcher.lua structure_pairs): each structure group of `groups` (undersuit cloth) takes
-- the nearest by lightness of the palette's main colors (share lim.main or more) the cape's part guard allows it
-- (src/capes.lua dark_parts_guard: no light color on a dark part, no tinted lining color on a large one), appended to
-- pairs ({group, color}) and counted in used ({[color] = share}); with none it keeps its colors. The IE-3 Martyr's olive
-- and brown undersuit stayed as they were under Federation's Embrace's blue and gold (independent review 2026-10-11,
-- fresh gallery case 80; the user chose "undersuits"); by lightness alone the Drape of Glory's 7% red took an undersuit
-- over its 28% blue-grey, and 2bcc4463's taupe lining or cream an undersuit its review passed.
function Colour.cape_structure(groups, palette, guard, lim, pairs, used)
    local allowed, keep = {}, {}
    for i, g in ipairs(groups) do
        allowed[i], keep[i] = {}, {}
        for j, p in ipairs(palette) do -- every color first: a guard's fallback then gives none it blocked
            allowed[i][j], keep[i][j] = true, Colour.de2000(g.L, g.a, g.b, p.L, p.a, p.b) < lim.keep
        end
    end
    guard(allowed, groups, palette, keep, lim.accent_c)
    for i, g in ipairs(groups) do
        local list = {}
        for j, p in ipairs(palette) do if allowed[i][j] and p.share >= lim.main then list[#list + 1] = p end end
        local n = Colour.nearest_lightness(list, g)
        if n then pairs[#pairs + 1], used[n] = {g, n}, (used[n] or 0) + g.share end
    end
end

-- Whether group g shows mostly on a cape's outside (half its rows' area or more, as outside_first counts it).
local function mostly_outside(g)
    local area, outside = 0, 0
    for _, row in ipairs(g.rows) do area, outside = area + row.area, outside + (row.outside or 0) end
    return outside >= 0.5 * area
end

-- A cape's second main color: the largest of palette s besides s[j_main] with share lim.second or more, CIEDE2000
-- lim.keep or more from s[j_main] and mostly on the outside, or nil. A lining color stays out (outside first): Vision
-- of Freedom's grey lining (49%) took main parts of armors its black outside makes dark (case 57).
local function second_main(s, j_main, lim)
    local j2
    for j = 1, #s do
        local apart = Colour.de2000(s[j].L, s[j].a, s[j].b, s[j_main].L, s[j_main].a, s[j_main].b) >= lim.keep
        if j ~= j_main and apart and s[j].share >= lim.second and mostly_outside(s[j])
            and (j2 == nil or s[j].share > s[j2].share) then
            j2 = j
        end
    end
    return j2
end

-- A cape's second main color (second_main; lim: src/matcher.lua CAPE_LIMITS) shows on a main part of the target (share
-- lim.main or more): when the pairing search gave it none (assign[i]: the palette color of target group i), the
-- largest near-neutral one that may take it (model chroma under lim.own_c, c.allowed, not the anchor) does. c: the
-- search's {t, s, allowed}. The search keeps the target's light and dark order, so a light color went to specks only on
-- an all-dark item: the BP-32 Jackboot under 1264718e's yellow (37%) stayed all black (independent review 2026-10-11,
-- fresh gallery case 36; the user chose "cape's light color"). A colored part takes the cape's accent as a band
-- (src/matcher.lua tint_bands): Standard of Safe Distance's yellow on an armor's navy plates, which the sage took.
function Colour.cape_second(c, assign, anchor, j_main, lim)
    local t, j2, pick = c.t, second_main(c.s, j_main, lim), nil
    for i = 1, j2 and #t or 0 do
        local main = t[i].share >= lim.main
        if main and assign[i] == j2 then return end
        local muted = math.sqrt(t[i].ma ^ 2 + t[i].mb ^ 2) < lim.own_c
        if main and muted and i ~= anchor and c.allowed[i][j2] and (pick == nil or t[i].share > t[pick].share) then
            pick = i
        end
    end
    if pick then assign[pick] = j2 end
end

Colour.SAMPLES = SAMPLES
-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({mean_hue, Colour.de2000, Colour.srgb_to_lab, lab_finv, linear_to_srgb, Colour.lab_to_linear,
        Colour.lab_to_srgb, Colour.npsum, Colour.pysum, Colour.weight_field, Colour.group_look, Colour.row_diffuse,
        Colour.diffuse_colors, Colour.with_gloss, Colour.outside_first, Colour.two_tone, mostly_outside, second_main,
        Colour.cape_second, Colour.nearest_lightness, Colour.cape_structure}) do
        jit.off(fn, true)
    end
end

return Colour
