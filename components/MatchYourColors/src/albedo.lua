-- Match Your Colors: modded gear without a color table (v1.5, end-user report 2026-10-14: the Cowboy Hat mod). A mod
-- can give a helmet or armor a material that paints its colors into its albedo texture instead of the game's color
-- table (material LUT) and ID mask: the (third-party) Cowboy Hat replaces the GS-11 Democracy's Deputy's unit with a
-- hat whose material, of the character shader (content/art_shared/base_shaders/character), holds a 2048 x 2048 BC1
-- albedo, a BC3 mra (metallic, roughness, ambient occlusion) and a BC5 normal map. v1.4 found no color table there: the
-- hat gave no colors and was never recolored.
--
-- Read (src/kits.lua): the first mip of the albedo no larger than READ_SIDE (the hat's mip 3, 256 x 256) is decoded with
-- its mra at the same size; its opaque texels are binned (4-4-4 sRGB and a metal bit, linear sums) and clustered
-- (farthest-point seeds at least SEED_DE apart, at most LLOYD_STEPS steps, at most CLUSTERS, a cluster under
-- MERGE_SHARE merged into its nearest): each cluster is a color row of the analysis, a share of its piece like a LUT
-- row's, its color the cluster's mean albedo.
-- Recolor (src/recolor.lua): each planned cluster's goal moves the texture's block endpoints. Every distinct RGB565
-- endpoint is mapped once (memo), by its closeness to the clusters (WEIGHT_DE), each cluster's lightness change as a
-- part's in the matcher (a ratio when it darkens, a difference when it lightens) and its tint; every block of every mip
-- then takes the mapped endpoints with its indices kept, swapped where a BC1 block's endpoint order flips so it keeps its
-- 4-color mode, or its 3-color mode and transparency. BC3 color blocks are always 4-color: endpoints only. The normal
-- and mra maps stay, so grain, shading and metal stay. Endpoints are mapped by their color alone: two clusters of one
-- color (a metal part painted like the leather beside it) move together, by the mean of their moves. Nothing here
-- runs per frame: analyses and recolors run in jobs, with a pause every BLOCKS_PER_PAUSE blocks, POINTS_PER_PAUSE
-- points and MISSES_PER_PAUSE new endpoints. Outside the game a hat-like 2048 x 2048 albedo takes about 2.3 ms to read
-- and 1.4 ms to recolor, a worst case of random colors 19 ms and 77 ms; stretches between pauses mostly under 0.45 ms,
-- the longest 0.9 ms (the first slices: the block loops compile; research/scratch/v15/albedo_timing*.lua).
local ffi = require('ffi')
local bit = require('bit')
local band, bor, bxor, bnot, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift

local Albedo = {}

Albedo.TEMPLATES = {['7712ee7808e0ec50'] = true} -- content/art_shared/base_shaders/character
Albedo.SLOT_ALBEDO, Albedo.SLOT_MRA = 0xac652e43, 0x756f6fa6 -- the material's texture slots 'albedo' and 'mra'
Albedo.BC1 = {[71] = true, [72] = true} -- DXGI BC1 (UNORM, sRGB)
Albedo.BC3 = {[77] = true, [78] = true} -- DXGI BC3 (UNORM, sRGB)
Albedo.READ_SIDE, Albedo.CLUSTERS, Albedo.SEED_DE, Albedo.LLOYD_STEPS = 256, 8, 6.0, 8
Albedo.MERGE_SHARE, Albedo.METAL_AXIS, Albedo.WEIGHT_DE = 0.005, 30.0, 4.0
Albedo.NEUTRAL_C = 5.0 -- a goal under this chroma passes no hue offsets (src/matcher.lua NEUTRAL_TINT_C)
-- How a mod's albedo looks: the study's typical response (gain r, g, b and gloss r, g, b: the medians of its 6,216
-- measured LUT rows, src/appearance_data.lua; research/scratch/v15/typical_response.lua), as an unmeasured LUT row
-- looks through its study row. The Cowboy Hat's crown (albedo L 36.7) shows L 30.2 in the Armory; through this, L 31.9.
-- Matched by its albedo, the B-01 Tactical's jacket took L 49 on screen (review renders 2026-10-14).
Albedo.RESPONSE = {0.7140, 0.6710, 0.6400, 0.00600, 0.00670, 0.00730}

-- A cluster's look (CIELAB) from its mean linear albedo; and the albedo (CIELAB) that looks like a goal.
function Albedo.look(Colour, r, g, b)
    return Colour.linear_to_lab(Colour.seen(Albedo.RESPONSE, r, g, b, true))
end
function Albedo.unlook(Colour, L, a, b)
    local R, k = Albedo.RESPONSE, {Colour.lab_to_linear(L, a, b)}
    return Colour.linear_to_lab(math.max((k[1] - R[4]) / R[1], 0), math.max((k[2] - R[5]) / R[2], 0),
                                math.max((k[3] - R[6]) / R[3], 0))
end
Albedo.BLOCKS_PER_PAUSE, Albedo.POINTS_PER_PAUSE, Albedo.MISSES_PER_PAUSE = 1024, 256, 256

local u32 = function(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end

-- Session buffers, made once: the bins (4,096 colors x metal: count, linear r, g, b sums, metallic sum), the decoded
-- blocks, the endpoint memo.
local BINS = 8192
local bins, texels, mra_texels, memo, seen
local function buffers()
    if bins then return end
    bins = ffi.new('double[?]', BINS * 5)
    texels, mra_texels = ffi.new('uint8_t[64]'), ffi.new('uint8_t[64]')
    memo, seen = ffi.new('uint16_t[65536]'), ffi.new('uint8_t[65536]')
end

-- sRGB byte -> linear, once.
local TO_LINEAR = {}
for i = 0, 255 do
    local c = i / 255
    TO_LINEAR[i] = c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end
local function to_byte(linear)
    local c = math.min(math.max(linear, 0), 1)
    c = c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
    return math.floor(c * 255 + 0.5)
end

-- An RGB565 color's 8-bit channels.
local function rgb565(e)
    local r, g, b = rshift(e, 11), band(rshift(e, 5), 63), band(e, 31)
    return bor(lshift(r, 3), rshift(r, 2)), bor(lshift(g, 2), rshift(g, 4)), bor(lshift(b, 3), rshift(b, 2))
end
local function pack565(r, g, b)
    local r5 = math.floor(r * 31 / 255 + 0.5)
    local g6 = math.floor(g * 63 / 255 + 0.5)
    local b5 = math.floor(b * 31 / 255 + 0.5)
    return r5 * 2048 + g6 * 32 + b5
end

-- A BC1 color block at p[o] (8 bytes; three_color: its c0 <= c1 mode counts, a BC3 color block's never does) into out
-- (16 texels x RGBA, bytes); a transparent texel has alpha 0.
function Albedo.color_block(p, o, out, three_color)
    local c0, c1 = p[o] + p[o + 1] * 256, p[o + 2] + p[o + 3] * 256
    local r0, g0, b0 = rgb565(c0)
    local r1, g1, b1 = rgb565(c1)
    local four = c0 > c1 or not three_color
    local idx = u32(p, o + 4)
    for t = 0, 15 do
        local i = band(rshift(idx, 2 * t), 3)
        local r, g, b, a = r0, g0, b0, 255
        if i == 1 then
            r, g, b = r1, g1, b1
        elseif i == 2 then
            if four then
                r, g, b = math.floor((2 * r0 + r1) / 3), math.floor((2 * g0 + g1) / 3), math.floor((2 * b0 + b1) / 3)
            else
                r, g, b = math.floor((r0 + r1) / 2), math.floor((g0 + g1) / 2), math.floor((b0 + b1) / 2)
            end
        elseif i == 3 then
            if four then
                r, g, b = math.floor((r0 + 2 * r1) / 3), math.floor((g0 + 2 * g1) / 3), math.floor((b0 + 2 * b1) / 3)
            else
                r, g, b, a = 0, 0, 0, 0
            end
        end
        out[4 * t], out[4 * t + 1], out[4 * t + 2], out[4 * t + 3] = r, g, b, a
    end
end

-- The bytes of a block format's mip chain (one layer) and its block size.
local function block_bytes(format) return Albedo.BC1[format] and 8 or 16 end
local function mip_size(info, m)
    return math.max(1, rshift(info.width, m)), math.max(1, rshift(info.height, m))
end

-- Whether a material with no color table can be read and recolored here: a mod's (record.file), of a template in
-- TEMPLATES (parent), with an albedo of a power-of-two size in BC1 or BC3. describe(name) -> info or nil (the
-- texture's Texture.describe). Returns {albedo, mra} or nil and why.
function Albedo.eligible(record, parent, textures, describe)
    if not (record and record.file) then return nil, 'not a mod\'s material' end
    if not Albedo.TEMPLATES[parent] then return nil, 'shader template ' .. tostring(parent) end
    local albedo = textures[Albedo.SLOT_ALBEDO]
    if not albedo then return nil, 'no albedo' end
    local ok, info = pcall(describe, albedo)
    if not ok or not info then return nil, 'albedo ' .. albedo .. ': ' .. tostring(ok and 'not found' or info) end
    local f, w, h = info.format, info.width, info.height
    if not (Albedo.BC1[f] or Albedo.BC3[f]) then return nil, 'albedo format ' .. f end
    if band(w, w - 1) ~= 0 or band(h, h - 1) ~= 0 then return nil, 'albedo size ' .. w .. ' x ' .. h end
    return {albedo = albedo, mra = textures[Albedo.SLOT_MRA]}
end

-- The mip to read: the first no larger than READ_SIDE on either side.
local function read_mip(info)
    for m = 0, info.mips - 1 do
        local w, h = mip_size(info, m)
        if w <= Albedo.READ_SIDE and h <= Albedo.READ_SIDE then return m end
    end
    return info.mips - 1
end

-- One block of the read mip into the bins: its opaque texels, metal where the mra's red reads over half.
local function bin_block(p, o, three_color, mra, mo)
    Albedo.color_block(p, o, texels, three_color)
    if mra then Albedo.color_block(mra, mo + 8, mra_texels, false) end
    for t = 0, 15 do
        if texels[4 * t + 3] >= 128 then
            local r, g, b = texels[4 * t], texels[4 * t + 1], texels[4 * t + 2]
            local metal = mra and mra_texels[4 * t] >= 128
            local k = (rshift(r, 4) * 256 + rshift(g, 4) * 16 + rshift(b, 4) + (metal and 4096 or 0)) * 5
            bins[k] = bins[k] + 1
            bins[k + 1], bins[k + 2], bins[k + 3] = bins[k + 1] + TO_LINEAR[r], bins[k + 2] + TO_LINEAR[g],
                bins[k + 3] + TO_LINEAR[b]
            if metal then bins[k + 4] = bins[k + 4] + 1 end
        end
    end
end

-- The non-empty bins as points {count, lin = {r, g, b}, lab = {L, a, b}, metal (0-1)}, in bin order.
local function points(Colour, yield)
    local out = {}
    for k = 0, BINS - 1 do
        local n = bins[5 * k]
        if n > 0 then
            local r, g, b = bins[5 * k + 1] / n, bins[5 * k + 2] / n, bins[5 * k + 3] / n
            local L, A, B = Colour.linear_to_lab(r, g, b)
            out[#out + 1] = {count = n, lin = {r, g, b}, lab = {L, A, B}, metal = bins[5 * k + 4] / n}
            if #out % Albedo.POINTS_PER_PAUSE == 0 then yield() end
        end
    end
    return out
end

-- Squared distance of a point to a cluster: CIELAB, metal on an axis of its own (METAL_AXIS per unit).
local function d2(p, c)
    local dL, da, db = p.lab[1] - c.lab[1], p.lab[2] - c.lab[2], p.lab[3] - c.lab[3]
    local dm = (p.metal - c.metal) * Albedo.METAL_AXIS
    return dL * dL + da * da + db * db + dm * dm
end

-- The point of the largest count x squared distance to its nearest seed, that distance at least SEED_DE (ties: the
-- earlier point), or nil; near[i]: point i's squared distance to its nearest seed before `last`, updated with it.
local function farthest(pts, near, last, yield)
    local pick, score = nil, -1
    for i, p in ipairs(pts) do
        local d = math.min(near[i], d2(p, last))
        near[i] = d
        if d >= Albedo.SEED_DE * Albedo.SEED_DE and p.count * d > score then pick, score = p, p.count * d end
        if i % Albedo.POINTS_PER_PAUSE == 0 then yield() end
    end
    return pick
end

-- Farthest-point seeds: the heaviest point, then the farthest (above) while there is one, at most CLUSTERS.
local function seeds(pts, yield)
    local best
    for _, p in ipairs(pts) do if not best or p.count > best.count then best = p end end
    local out, near = {{lab = best.lab, metal = best.metal}}, {}
    for i = 1, #pts do near[i] = math.huge end
    while #out < Albedo.CLUSTERS do
        local pick = farthest(pts, near, out[#out], yield)
        if not pick then break end
        out[#out + 1] = {lab = pick.lab, metal = pick.metal}
    end
    return out
end

-- Index of the cluster nearest point p (ties: the earlier).
local function nearest(p, clusters)
    local best, bd = 1, math.huge
    for i, c in ipairs(clusters) do
        local d = d2(p, c)
        if d < bd then best, bd = i, d end
    end
    return best
end

-- Clusters from the points' assignment: mean linear color and metal by count; empty ones dropped.
local function means(pts, assign, k, Colour)
    local acc = {}
    for i = 1, k do acc[i] = {count = 0, r = 0, g = 0, b = 0, m = 0} end
    for i, p in ipairs(pts) do
        local a = acc[assign[i]]
        a.count, a.r, a.g, a.b = a.count + p.count, a.r + p.count * p.lin[1], a.g + p.count * p.lin[2],
            a.b + p.count * p.lin[3]
        a.m = a.m + p.count * p.metal
    end
    local out = {}
    for _, a in ipairs(acc) do
        if a.count > 0 then
            local lin = {a.r / a.count, a.g / a.count, a.b / a.count}
            out[#out + 1] = {count = a.count, lin = lin, lab = {Colour.linear_to_lab(lin[1], lin[2], lin[3])},
                             metal = a.m / a.count}
        end
    end
    return out
end

-- Each point's nearest cluster into assign; whether any changed. A pause every POINTS_PER_PAUSE points.
local function assigned(pts, clusters, assign, yield)
    local moved = false
    for i, p in ipairs(pts) do
        local n = nearest(p, clusters)
        if assign[i] ~= n then assign[i], moved = n, true end
        if i % Albedo.POINTS_PER_PAUSE == 0 then yield() end
    end
    return moved
end

-- Lloyd steps from the seeds, then the small clusters merged into their nearest; largest first.
local function cluster(pts, Colour, yield)
    local clusters, assign = seeds(pts, yield), {}
    for _ = 1, Albedo.LLOYD_STEPS do
        local moved = assigned(pts, clusters, assign, yield)
        clusters = means(pts, assign, #clusters, Colour)
        yield()
        if not moved then break end
    end
    local total = 0
    for _, c in ipairs(clusters) do total = total + c.count end
    local kept = {}
    for _, c in ipairs(clusters) do if c.count >= Albedo.MERGE_SHARE * total then kept[#kept + 1] = c end end
    assigned(pts, kept, assign, yield)
    clusters = means(pts, assign, #kept, Colour)
    table.sort(clusters, function(x, y)
        if x.count ~= y.count then return x.count > y.count end
        return x.lab[1] < y.lab[1]
    end)
    for _, c in ipairs(clusters) do
        c.share = c.count / total
        c.seen = {Albedo.look(Colour, c.lin[1], c.lin[2], c.lin[3])}
    end
    return clusters
end

-- The mra's mip of w x h (BC3 blocks), or nil (no mra, another format, no mip of that size).
local function read_mra(entry, texture, w, h)
    local info, read
    if entry.mra then info, read = texture(entry.mra) end
    if not (info and Albedo.BC3[info.format]) then return nil end
    for m = 0, info.mips - 1 do
        local mw, mh = mip_size(info, m)
        if mw == w and mh == h then
            local size = rshift(w + 3, 2) * rshift(h + 3, 2) * 16
            local mra = ffi.new('uint8_t[?]', size)
            read(info.mip_offsets[m], size, mra, 0)
            return mra
        end
    end
    return nil
end

-- Every block of the read mip (data, w x h) into the emptied bins, with a pause every BLOCKS_PER_PAUSE.
local function bin_mip(data, format, w, h, mra, yield)
    ffi.fill(bins, BINS * 5 * 8)
    local three, step = Albedo.BC1[format] == true, block_bytes(format)
    for i = 0, rshift(w + 3, 2) * rshift(h + 3, 2) - 1 do
        bin_block(data, i * step + (step == 16 and 8 or 0), three, mra, i * 16)
        if i % Albedo.BLOCKS_PER_PAUSE == Albedo.BLOCKS_PER_PAUSE - 1 then yield() end
    end
end

-- An albedo's clusters (above): {format, width, height, mips, total (one layer's bytes), clusters = {{share, lin, lab,
-- metal}, ...}}, or nil and why. texture(name) -> info, read(at, size, out, out_offset) or nil (the analysis's reader);
-- entry: Albedo.eligible's. Colour: src/colour.lua.
function Albedo.read(entry, texture, Colour, yield)
    buffers()
    local info, read = texture(entry.albedo)
    if not info then return nil, 'albedo not found' end
    local m = read_mip(info)
    local w, h = mip_size(info, m)
    local size = rshift(w + 3, 2) * rshift(h + 3, 2) * block_bytes(info.format)
    local data = ffi.new('uint8_t[?]', size)
    read(info.mip_offsets[m], size, data, 0)
    bin_mip(data, info.format, w, h, read_mra(entry, texture, w, h), yield)
    local pts = points(Colour, yield)
    if #pts == 0 then return nil, 'no opaque texel' end
    return {format = info.format, width = info.width, height = info.height, mips = info.mips, total = info.layer_bytes,
            clusters = cluster(pts, Colour, yield)}
end

-- A part's lightness when its cluster, of lightness t_L, takes base (src/matcher.lua row_lightness): a luminance ratio
-- when it darkens, a difference when it lightens.
local function lightness(Colour, base, x_L, t_L)
    if base >= t_L then return base + (x_L - t_L) end
    local y = Colour.lab_to_linear(base, 0, 0) * Colour.lab_to_linear(x_L, 0, 0)
        / math.max(Colour.lab_to_linear(t_L, 0, 0), 1e-9)
    return (Colour.linear_to_lab(y, y, y))
end

-- The cluster moves of a plan: {[cluster] = {lab = its albedo Lab, goal = {L, a, b} or nil, scale}}: a planned
-- cluster's goal (a look) as the albedo that looks like it (Albedo.unlook), its hue offsets kept by the chroma change
-- (none toward a neutral goal).
function Albedo.moves(albedo, goals, Colour)
    local out = {}
    for k, c in ipairs(albedo.clusters) do
        local g = goals[k]
        local move = {lab = c.lab}
        if g then
            local L, a, b = Albedo.unlook(Colour, g.L, g.a, g.b)
            local gc, cc = math.sqrt(a * a + b * b), math.sqrt(c.lab[2] ^ 2 + c.lab[3] ^ 2)
            move.goal = {L, a, b}
            move.scale = math.sqrt(g.a * g.a + g.b * g.b) < Albedo.NEUTRAL_C and 0
                or (cc > 1 and math.min(1, gc / cc) or 1)
        end
        out[k] = move
    end
    return out
end

-- An endpoint's new RGB565: its color moved by every cluster's move weighed by closeness (exp(-d^2 / 2 WEIGHT_DE^2);
-- the nearest alone when all weigh nothing).
local function move_endpoint(e, moves, Colour)
    local r, g, b = rgb565(e)
    local L, A, B = Colour.linear_to_lab(TO_LINEAR[r], TO_LINEAR[g], TO_LINEAR[b])
    local sw, sL, sa, sb, best, bd = 0, 0, 0, 0, nil, math.huge
    for _, mv in ipairs(moves) do
        local dL, da, db = L - mv.lab[1], A - mv.lab[2], B - mv.lab[3]
        local d = dL * dL + da * da + db * db
        local w = math.exp(-d / (2 * Albedo.WEIGHT_DE * Albedo.WEIGHT_DE))
        local tL, ta, tb = L, A, B
        if mv.goal then
            tL = lightness(Colour, mv.goal[1], L, mv.lab[1])
            ta, tb = mv.goal[2] + (A - mv.lab[2]) * mv.scale, mv.goal[3] + (B - mv.lab[3]) * mv.scale
        end
        sw, sL, sa, sb = sw + w, sL + w * tL, sa + w * ta, sb + w * tb
        if d < bd then best, bd = {tL, ta, tb}, d end
    end
    if sw < 1e-12 then sL, sa, sb, sw = best[1], best[2], best[3], 1 end
    local lr, lg, lb = Colour.lab_to_linear(sL / sw, sa / sw, sb / sw)
    return pack565(to_byte(lr), to_byte(lg), to_byte(lb))
end

-- The endpoint memo emptied (before each recolored albedo: a memo holds one albedo's moves).
function Albedo.forget()
    buffers()
    ffi.fill(seen, 65536)
end

-- An endpoint's new RGB565 from the memo, map(e) the first time (Albedo.forget empties the memo).
local function mapped(e, map)
    if seen[e] == 0 then memo[e], seen[e] = map(e), 1 end
    return memo[e]
end

-- A BC1 block's new endpoints n0, n1 (of c0, c1) in the order that keeps its mode, its indices at u32p[x] remapped
-- when they swap: 4-color indices flip 0<->1 and 2<->3 (xor 0x55555555), 3-color ones 0<->1 only (2, the middle, and
-- 3, transparent, stay); two equal endpoints of a 4-color block give index 0 (the same color, never the 3-color mode's
-- transparency).
local function bc1_order(u32p, x, c0, c1, n0, n1)
    if c0 > c1 then
        if n0 < n1 then
            u32p[x] = bxor(u32p[x], 0x55555555)
            return n1, n0
        end
        if n0 == n1 then u32p[x] = 0 end
        return n0, n1
    end
    if n0 > n1 then
        local idx = u32p[x]
        u32p[x] = bxor(idx, band(bnot(rshift(idx, 1)), 0x55555555))
        return n1, n0
    end
    return n0, n1
end

-- Blocks [first, last) of a BC1 (step 8) or BC3 (step 16, color at +8) mip chain rewritten with the memo's endpoints
-- (map(e): an endpoint not in the memo yet), a BC1 block's in the order that keeps its mode (bc1_order).
function Albedo.rewrite(data, first, last, step, map)
    local u16 = ffi.cast('uint16_t *', data)
    local u32p = ffi.cast('int32_t *', data) -- signed: bit operations' results store as they are
    local co = step == 16 and 4 or 0
    for i = first, last - 1 do
        local w = (i * step) / 2 + co -- uint16 index of c0
        local c0, c1 = u16[w], u16[w + 1]
        local n0, n1 = mapped(c0, map), mapped(c1, map)
        if step == 8 then n0, n1 = bc1_order(u32p, i * 2 + 1, c0, c1, n0, n1) end -- its indices: uint32 2i + 1
        u16[w], u16[w + 1] = n0, n1
    end
end

-- The recolored albedo for plan goals {[cluster] = goal}: {albedo = true, bc1, name, width, height, mips, size,
-- format (DXGI), data}; data: its whole mip chain (src/recolor.lua pipeline chain: a fresh copy), rewritten in place.
function Albedo.spec(name, albedo, goals, data, Colour, yield)
    Albedo.forget()
    local moves = Albedo.moves(albedo, goals, Colour)
    local step = block_bytes(albedo.format)
    local blocks = albedo.total / step
    local misses = 0
    local function map(e)
        misses = misses + 1
        if misses % Albedo.MISSES_PER_PAUSE == 0 then yield() end
        return move_endpoint(e, moves, Colour)
    end
    for first = 0, blocks - 1, Albedo.BLOCKS_PER_PAUSE do
        Albedo.rewrite(data, first, math.min(first + Albedo.BLOCKS_PER_PAUSE, blocks), step, map)
        yield()
    end
    return {albedo = true, bc1 = Albedo.BC1[albedo.format] == true, name = name, width = albedo.width,
            height = albedo.height, mips = albedo.mips, size = albedo.total, format = albedo.format, data = data}
end

-- A target's recolored albedos for plan into out (a plan's luts, beside its LUTs: src/recolor.lua binds them on the
-- albedo slot): each albedo with a planned cluster; chain(name, archive) -> data, info (src/recolor.lua). Returns the
-- log line ("Mod texture <name>: <n> colors read (shares); <m> recolored"), one per albedo, and one per mod's material
-- left unread (target.unread, src/kits.lua), or nil.
-- An albedo's plan goals ({[cluster] = goal}), how many, and its clusters' shares as the log gives them.
local function goals_of(name, albedo, plan)
    local goals, count, shares = {}, 0, {}
    for k, c in ipairs(albedo.clusters) do
        goals[k] = plan[name .. ':' .. (k - 1)]
        count = count + (goals[k] and 1 or 0)
        shares[k] = string.format('%.0f%%%s', 100 * c.share, c.metal > 0.5 and ' metal' or '')
    end
    return goals, count, shares
end

-- The albedo recolored for goals (Albedo.spec) in a fresh copy of its chain (ctx: chain, archive, Colour, yield);
-- raises when the texture is not the one analysed.
local function recolored(name, albedo, goals, ctx)
    local data, info = ctx.chain(name, ctx.archive)
    if not data or info.format ~= albedo.format or info.layer_bytes ~= albedo.total then
        error('mod texture ' .. name .. ' is not the texture analysed', 0)
    end
    return Albedo.spec(name, albedo, goals, data, ctx.Colour, ctx.yield)
end

function Albedo.plan_specs(target, plan, out, chain, Colour, yield)
    local lines = {}
    for _, u in pairs(target.unread or {}) do
        lines[#lines + 1] = string.format('Mod material %s (from %s) has no color table and is left as it is: %s.',
                                          u.material, tostring(u.file), u.why)
    end
    local ctx = {chain = chain, archive = target.kit.archive, Colour = Colour, yield = yield}
    for name, albedo in pairs(target.albedos or {}) do
        if albedo then -- false: its read failed (src/kits.lua add_albedo)
            local goals, count, shares = goals_of(name, albedo, plan)
            if count > 0 then out[name] = recolored(name, albedo, goals, ctx) end
            lines[#lines + 1] = string.format('Mod texture %s (a material without a color table): %d colors read (%s); '
                .. '%d recolored.', name, #albedo.clusters, table.concat(shares, ', '), count)
        end
    end
    table.sort(lines)
    return #lines > 0 and table.concat(lines, ' ') or nil
end

-- Interpreted (jobs only), but the block loops: Albedo.rewrite (with mapped and bc1_order) and bin_block (with
-- Albedo.color_block) run a few hundred thousand times per recolor and stay compiled (src/patches.lua's adler
-- likewise).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({buffers, to_byte, pack565, block_bytes, mip_size, Albedo.eligible, read_mip, points, d2,
        farthest, seeds, nearest, means, assigned, cluster, read_mra, bin_mip, Albedo.read, lightness, Albedo.moves,
        move_endpoint, Albedo.forget, Albedo.spec, goals_of, recolored, Albedo.plan_specs, Albedo.look, Albedo.unlook}) do
        jit.off(fn, true)
    end
end

return Albedo
