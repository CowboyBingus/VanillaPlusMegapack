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

    -- Mean linear albedo of a row over the samples. c[column * 4 + channel + 1]; columns 0 base, 1 detail
    -- controls, 2 detail color, 3 intensity controls, 4 roughness controls, 5/6 wear colors, 16-19 camo
    -- colors, 20 camo extra (w), 21 camo controls.
    local function albedo(c)
        local d = c[4] <= 3.0 and detail[layer_index(c[5], detail_layers)] or nil
        local s = c[88] >= 0.0 and camo[layer_index(c[88], camo_layers)] or nil
        local sum_r, sum_g, sum_b = 0, 0, 0
        for i = 0, SAMPLES - 1 do
            local md0, md1 = 0, 0
            if d then md0, md1 = d[i * 4 + 2] - 0.5, d[i * 4 + 3] - 0.5 end
            local rough = clip(md0 * c[17] + md1 * c[18] + c[8])
            local intensity = clip(md0 * c[13] + md1 * c[14] + c[7])
            local mix, r, g, b = 1, c[1], c[2], c[3]
            if s then mix, r, g, b = camo_sample(c, s, i, md0, md1) end
            local cr = rough * mix
            local cr2 = cr * rough
            r, g, b = r + intensity * (c[9] - r), g + intensity * (c[10] - g), b + intensity * (c[11] - b)
            r, g, b = r + cr * (c[25] - r), g + cr * (c[26] - g), b + cr * (c[27] - b)
            r, g, b = r + cr2 * (c[21] - r), g + cr2 * (c[22] - g), b + cr2 * (c[23] - b)
            sum_r, sum_g, sum_b = sum_r + srgb_to_linear(r), sum_g + srgb_to_linear(g), sum_b + srgb_to_linear(b)
        end
        return sum_r / SAMPLES, sum_g / SAMPLES, sum_b / SAMPLES
    end

    -- The CIELAB of a row's mean albedo (no metal darkening): its paint's own color (the transfer's reference).
    function self.albedo_lab(c)
        local r, g, b = albedo(c)
        return Colour.linear_to_lab(r, g, b)
    end

    -- The perceived color of a row given as row_values: L, a, b and its metallic (column 6 w, clipped).
    function self.perceived(c)
        local r, g, b = albedo(c)
        local metallic = clip(c[28])
        local dark = 1 - METAL_DARKEN * metallic
        local L, A, B = Colour.linear_to_lab(r * dark, g * dark, b * dark)
        return L, A, B, metallic
    end

    -- The look of a row through its measured response cal = {gr, gg, gb, sr, sg, sb} (src/appearance.lua): the
    -- CIELAB of Colour.seen(g x mean albedo, s).
    function self.look(c, cal)
        local r, g, b = albedo(c)
        return Colour.linear_to_lab(Colour.seen(cal, r, g, b))
    end

    function self.row_info(values, width, row)
        local c = row_values(values, width, row)
        local r, g, b = albedo(c)
        local metallic = clip(c[28])
        local dark = 1 - METAL_DARKEN * metallic
        local L, A, B = Colour.linear_to_lab(r * dark, g * dark, b * dark)
        return L, A, B, metallic > 0.5, c[88] >= 0, c[4], metallic >= METAL_FULL, r, g, b
    end
    return self
end

-- The color the eye takes for a paint through its measured response cal = {gr, gg, gb, sr, sg, sb} at mean albedo
-- (r, g, b): its diffuse color g x albedo plus its gloss floor s, the floor weighed 1 - chroma / GLOSS_C (clipped to
-- 0-1): on neutral paint gloss reads as lightness, on colored paint as highlights over the paint (match12.seen).
-- Display-linear r, g, b, clipped at 0.
Colour.GLOSS_C = 20.0
function Colour.seen(cal, r, g, b)
    local dr, dg, db = max(cal[1] * r, 0), max(cal[2] * g, 0), max(cal[3] * b, 0)
    local _, A, B = Colour.linear_to_lab(dr, dg, db)
    local w = min(max(1 - math.sqrt(A * A + B * B) / Colour.GLOSS_C, 0), 1)
    return max(dr + w * cal[4], 0), max(dg + w * cal[5], 0), max(db + w * cal[6], 0)
end

Colour.SAMPLES = SAMPLES
-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({mean_hue, Colour.de2000, Colour.srgb_to_lab, lab_finv, linear_to_srgb, Colour.lab_to_linear,
        Colour.lab_to_srgb}) do
        jit.off(fn, true)
    end
end

return Colour
