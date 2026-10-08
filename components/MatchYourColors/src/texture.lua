-- Match Your Colors: the texture data the color model needs, decoded from the game's own files.
--
-- A texture resource's main part holds a 0xC0-byte resource header and the DDS header (DX10, 148 bytes);
-- its pixels are in the GPU part, or in the stream part when that one holds the whole mip chain (9 of the
-- 570 ID masks of build 25480438), else in the two parts end to end. Layers are stored one after another,
-- each with its full mip chain (DDS order).
--
-- Decoded here: material LUTs (23 x N, R16G16B16A16_FLOAT, mip 0) and pattern textures (3 x 1, the same
-- format), ID-mask coverage (R8G8B8A8, 1-2 layers = 4-8 soft slot weights, mip 0), pattern-mask coverage (R8 or
-- R8G8B8A8, red channel, one layer and mip, research/patterns.py), the first 512 texels of the detail tiler's mip
-- 4 per layer (BC7) and of the camo tiler's mip 2 per layer (R8G8B8A8), as research/effective.py samples them.
-- Nothing here runs per frame.
local ffi = require('ffi')
local bit = require('bit')
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local Texture = {}

local HEADER = 0xC0
local DDS_HEADER, DX10_HEADER = 128, 20
local u32 = function(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
Texture.FORMAT_RGBA16F, Texture.FORMAT_RGBA8, Texture.FORMAT_RGBA8_SRGB, Texture.FORMAT_BC7 = 10, 28, 29, 98
Texture.FORMAT_R8 = 61
Texture.FORMAT_BC3 = 77 -- capes' scalar fields (src/capes.lua decodes its blocks)
Texture.FORMAT_BC4 = 80 -- capes' gradients (src/capes.lua)

-- Bytes of mip `m` of a w x h layer in `format`.
local function mip_bytes(format, w, h, m)
    local mw, mh = math.max(1, rshift(w, m)), math.max(1, rshift(h, m))
    if format == Texture.FORMAT_BC7 or format == Texture.FORMAT_BC3 or format == Texture.FORMAT_BC4 then
        local block = format == Texture.FORMAT_BC4 and 8 or 16
        return math.max(1, rshift(mw + 3, 2)) * math.max(1, rshift(mh + 3, 2)) * block
    end
    local per_texel = format == Texture.FORMAT_RGBA16F and 8 or (format == Texture.FORMAT_R8 and 1 or 4)
    return mw * mh * per_texel
end

-- The DDS description in a texture's main part (uint8_t pointer, size): {width, height, mips, format, layers,
-- layer_bytes, mip_offsets (0-based mip -> offset in a layer)}; raises when it is not a DX10 DDS this file
-- decodes.
function Texture.describe(main, size)
    if size < HEADER + DDS_HEADER + DX10_HEADER or u32(main, HEADER) ~= 0x20534444 then -- 'DDS '
        error('texture main part holds no DDS header', 0)
    end
    local d = HEADER
    local info = {height = u32(main, d + 12), width = u32(main, d + 16), mips = math.max(1, u32(main, d + 28))}
    if u32(main, d + 84) ~= 0x30315844 then error('texture is not DX10', 0) end -- 'DX10'
    info.format, info.layers = u32(main, d + 128), math.max(1, u32(main, d + 140))
    local f = info.format
    if f ~= Texture.FORMAT_RGBA16F and f ~= Texture.FORMAT_RGBA8 and f ~= Texture.FORMAT_RGBA8_SRGB
        and f ~= Texture.FORMAT_BC7 and f ~= Texture.FORMAT_R8 and f ~= Texture.FORMAT_BC3
        and f ~= Texture.FORMAT_BC4 then
        error('unsupported texture format ' .. f, 0)
    end
    info.mip_offsets, info.layer_bytes = {}, 0
    for m = 0, info.mips - 1 do
        info.mip_offsets[m] = info.layer_bytes
        info.layer_bytes = info.layer_bytes + mip_bytes(f, info.width, info.height, m)
    end
    info.total = info.layer_bytes * info.layers
    return info
end

-- A reader of a texture's pixel bytes: read(at, size, out, out_offset) over the DDS pixel data (offset 0 =
-- layer 0 mip 0). slim: the reader (src/slim.lua); record: the resource's TOC record; info: describe().
function Texture.pixels(slim, archive, record, info)
    local stream, gpu = slim.part_size(record, 'stream'), slim.part_size(record, 'gpu')
    if gpu >= info.total then
        return function(at, size, out, out_offset) slim.part(archive, record, 'gpu', at, size, out, out_offset) end
    end
    if stream >= info.total then
        return function(at, size, out, out_offset) slim.part(archive, record, 'stream', at, size, out, out_offset) end
    end
    if stream + gpu < info.total then error('texture data shorter than its mip chain', 0) end
    return function(at, size, out, out_offset)
        out_offset = out_offset or 0
        if at < stream then
            local take = math.min(size, stream - at)
            slim.part(archive, record, 'stream', at, take, out, out_offset)
            at, size, out_offset = at + take, size - take, out_offset + take
        end
        if size > 0 then slim.part(archive, record, 'gpu', at - stream, size, out, out_offset) end
    end
end

-- IEEE half to number.
local function half(lo, hi)
    local h = lo + hi * 256
    local sign = h >= 32768 and -1 or 1
    local exponent = band(rshift(h, 10), 31)
    local mantissa = band(h, 1023)
    if exponent == 0 then return sign * mantissa * 2 ^ -24 end
    if exponent == 31 then return mantissa == 0 and sign * math.huge or 0 / 0 end
    return sign * (1 + mantissa / 1024) * 2 ^ (exponent - 15)
end
Texture.half = half

-- The 23 x N material LUT (mip 0) as a float array: value(row, column, channel) at ((row * width + column) *
-- 4 + channel). Returns the array, width and rows.
function Texture.lut(pixels, info, scratch)
    if info.format ~= Texture.FORMAT_RGBA16F then error('material LUT is not RGBA16F', 0) end
    local count = info.width * info.height * 4
    local raw = scratch(count * 2)
    pixels(0, count * 2, raw, 0)
    local values = ffi.new('float[?]', count)
    for i = 0, count - 1 do values[i] = half(raw[2 * i], raw[2 * i + 1]) end
    return values, info.width, info.height
end

-- Adds the normalized weights of texels [first, first + count) of mip 0 (all layers, `plane` bytes apart in
-- data) to sums (double array); returns how many texels counted (weight sum above 0.05).
local function accumulate(data, plane, layers, first, count, sums, weights)
    local channels, valid = 4 * layers, 0
    for t = first, first + count - 1 do
        local total = 0
        for k = 0, channels - 1 do
            local v = data[(k - k % 4) / 4 * plane + t * 4 + k % 4] / 255
            weights[k] = v
            total = total + v
        end
        if total > 0.05 then
            valid = valid + 1
            for k = 0, channels - 1 do sums[k] = sums[k] + weights[k] / total end
        end
    end
    return valid
end

-- ID-mask coverage, mip 0: per slot (4 per layer) the mean of each texel's weight divided by the texel's
-- weight sum, over texels whose sum exceeds 0.05 (research/palettes.py). Returns a 1-based Lua array, or nil
-- and why. The mask is read in blocks of rows (every layer's rows, at most COVERAGE_BLOCK bytes: no buffer the
-- size of the mask, 2 MB for a 512 x 512 two-layer mask); texels are summed in the same order as a whole read.
-- yield() is called between rows so a job can pause.
local COVERAGE_BLOCK = 131072
Texture.COVERAGE_BLOCK = COVERAGE_BLOCK
function Texture.coverage(pixels, info, scratch, yield)
    if info.format ~= Texture.FORMAT_RGBA8 and info.format ~= Texture.FORMAT_RGBA8_SRGB then
        return nil, 'id mask format ' .. info.format
    end
    local w, h, layers = info.width, info.height, info.layers
    local row_bytes = w * 4
    local rows_per_block = math.max(1, math.floor(COVERAGE_BLOCK / (row_bytes * layers)))
    local data = scratch(rows_per_block * row_bytes * layers)
    local channels = 4 * layers
    local sums, weights = ffi.new('double[?]', channels), ffi.new('double[?]', channels)
    local valid = 0
    for first = 0, h - 1, rows_per_block do
        local rows = math.min(rows_per_block, h - first)
        local plane = rows * row_bytes
        for l = 0, layers - 1 do pixels(l * info.layer_bytes + first * row_bytes, plane, data, l * plane) end
        for y = 0, rows - 1 do
            valid = valid + accumulate(data, plane, layers, y * w, w, sums, weights)
            if yield then yield() end
        end
    end
    local out = {}
    for k = 1, channels do out[k] = sums[k - 1] / math.max(1, valid) end
    return out
end

-- A pattern mask's coverage: the mean of the shader's mask strength clamp(100 x (red - 0.5), 0, 1) over mip `mip`
-- (the last when the texture has fewer) of layer `layer` (modulo the layers), summed in texel order; nil when the
-- mask is neither R8 nor R8G8B8A8.
function Texture.mask_coverage(pixels, info, layer, mip, scratch)
    local f = info.format
    local per = f == Texture.FORMAT_R8 and 1
        or ((f == Texture.FORMAT_RGBA8 or f == Texture.FORMAT_RGBA8_SRGB) and 4 or nil)
    if not per then return nil end
    mip = math.min(mip, info.mips - 1)
    local w, h = math.max(1, rshift(info.width, mip)), math.max(1, rshift(info.height, mip))
    local count = w * h
    local data = scratch(count * per)
    pixels((layer % info.layers) * info.layer_bytes + info.mip_offsets[mip], count * per, data, 0)
    local sum = 0
    for i = 0, count - 1 do
        local v = 100 * (data[i * per] / 255 - 0.5)
        if v > 1 then v = 1 elseif v < 0 then v = 0 end
        sum = sum + v
    end
    return sum / count
end

-- BC7 -------------------------------------------------------------------------------------------------------

-- Mode table: partition bits, subsets, color bits, alpha bits, endpoint p-bits (per endpoint), shared p-bits
-- (per subset), index bits, secondary index bits.
local MODES = {
    [0] = {4, 3, 4, 0, true, false, 3, 0}, {6, 2, 6, 0, false, true, 3, 0}, {6, 3, 5, 0, false, false, 2, 0},
    {6, 2, 7, 0, true, false, 2, 0}, {0, 1, 5, 6, false, false, 2, 3}, {0, 1, 7, 8, false, false, 2, 2},
    {0, 1, 7, 7, true, false, 4, 0}, {6, 2, 5, 5, true, false, 2, 0},
}
-- Partition subsets per texel: 64 strings of 16 digits for two and for three subsets.
local PARTITIONS2 = {
    '0011001100110011', '0001000100010001', '0111011101110111', '0001001100110111', '0000000100010011',
    '0011011101111111', '0001001101111111', '0000000100110111', '0000000000010011', '0011011111111111',
    '0000000101111111', '0000000000010111', '0001011111111111', '0000000011111111', '0000111111111111',
    '0000000000001111', '0000100011101111', '0111000100000000', '0000000010001110', '0111001100010000',
    '0011000100000000', '0000100011001110', '0000000010001100', '0111001100110001', '0011000100010000',
    '0000100010001100', '0110011001100110', '0011011001101100', '0001011111101000', '0000111111110000',
    '0111000110001110', '0011100110011100', '0101010101010101', '0000111100001111', '0101101001011010',
    '0011001111001100', '0011110000111100', '0101010110101010', '0110100101101001', '0101101010100101',
    '0111001111001110', '0001001111001000', '0011001001001100', '0011101111011100', '0110100110010110',
    '0011110011000011', '0110011010011001', '0000011001100000', '0100111001000000', '0010011100100000',
    '0000001001110010', '0000010011100100', '0110110010010011', '0011011011001001', '0110001110011100',
    '0011100111000110', '0110110011001001', '0110001100111001', '0111111010000001', '0001100011100111',
    '0000111100110011', '0011001111110000', '0010001011101110', '0100010001110111',
}
local PARTITIONS3 = {
    '0011001102212222', '0001001122112221', '0000200122112211', '0222002200110111', '0000000011221122',
    '0011001100220022', '0022002211111111', '0011001122112211', '0000000011112222', '0000111111112222',
    '0000111122222222', '0012001200120012', '0112011201120112', '0122012201220122', '0011011211221222',
    '0011200122002220', '0001001101121122', '0111001120012200', '0000112211221122', '0022002200221111',
    '0111011102220222', '0001000122212221', '0000001101220122', '0000110022102210', '0122012200110000',
    '0012001211222222', '0110122112210110', '0000011012211221', '0022110211020022', '0110011020022222',
    '0011012201220011', '0000200022112221', '0000000211221222', '0222002200120011', '0011001200220222',
    '0120012001200120', '0000111122220000', '0120120120120120', '0120201212010120', '0011220011220011',
    '0011112222000011', '0101010122222222', '0000000021212121', '0022112200221122', '0022001100220011',
    '0220122102201221', '0101222222220101', '0000212121212121', '0101010101012222', '0222011102220111',
    '0002111200021112', '0000211221122112', '0222011101110222', '0002111211120002', '0110011001102222',
    '0000000021122112', '0110011022222222', '0022001100110022', '0022112211220022', '0000000000002112',
    '0002000100020001', '0222122202221222', '0101222222222222', '0111201122012220',
}
-- Anchor texel of the second subset (two subsets), and of the second and third subsets (three subsets).
local ANCHOR2 = {
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6, 6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
}
local ANCHOR3_1 = {
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3, 3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15, 3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
}
local ANCHOR3_2 = {
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8, 15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8, 15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
}
local WEIGHTS = {
    [2] = {0, 21, 43, 64},
    [3] = {0, 9, 18, 27, 37, 46, 55, 64},
    [4] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64},
}

-- The block being decoded (its 16 bytes from bits_block[bits_offset]) and the next bit, read LSB first. The decoder
-- keeps its state here and in the tables below, refilled per block: it allocates nothing per block (a cape's fields
-- are up to 1,024 blocks, decoded inside a recolor job).
local bits_block, bits_offset, bits_position = nil, 0, 0
-- count is at most 8, so the bits lie in two bytes; the second is read only when they reach it (never past the
-- block's 16 bytes: a block's fields end at bit 128).
local function read_bits(count)
    local p = bits_position
    local at, shift = bits_offset + rshift(p, 3), band(p, 7)
    local value = bits_block[at]
    if shift + count > 8 then value = value + bits_block[at + 1] * 256 end
    bits_position = p + count
    return band(rshift(value, shift), lshift(1, count) - 1)
end
-- Endpoints [channel][endpoint], p-bits, the primary and secondary index lists and the parsed block.
local ENDPOINTS, PBITS, PRIMARY, SECONDARY, BLOCK = {{}, {}, {}, {}}, {}, {}, {}, {}

-- The subset of texel t (0-based) and whether it is its subset's anchor.
local function subset_of(subsets, partition, t)
    if subsets == 1 then return 0, t == 0 end
    local row = subsets == 2 and PARTITIONS2[partition + 1] or PARTITIONS3[partition + 1]
    local s = row:byte(t + 1) - 48
    if s == 0 then return 0, t == 0 end
    if subsets == 2 then return 1, ANCHOR2[partition + 1] == t end
    return s, (s == 1 and ANCHOR3_1 or ANCHOR3_2)[partition + 1] == t
end

-- An endpoint component of `bits` bits (p-bit included) widened to 8 bits.
local function widen(value, bits)
    value = lshift(value, 8 - bits)
    return bor(value, rshift(value, bits))
end

-- Raw endpoint values into ENDPOINTS: e[channel][endpoint] (channels 1-4 = R, G, B, A; endpoints 1..count); alpha
-- 255 when the mode has none.
local function raw_endpoints(count, color_bits, alpha_bits)
    local e = ENDPOINTS
    for c = 1, 3 do
        local channel = e[c]
        for i = 1, count do channel[i] = read_bits(color_bits) end
    end
    for i = 1, count do e[4][i] = alpha_bits > 0 and read_bits(alpha_bits) or 255 end
    return e
end

-- The p-bits into PBITS: one per endpoint, or one per subset shared by its two endpoints.
local function read_pbits(count, subsets, per_endpoint)
    local p = PBITS
    if per_endpoint then
        for i = 1, count do p[i] = read_bits(1) end
    else
        for s = 1, subsets do
            local v = read_bits(1)
            p[2 * s - 1], p[2 * s] = v, v
        end
    end
    return p
end

-- Appends the p-bits below each component, then widens every component to 8 bits.
local function finish_endpoints(e, p, count, color_bits, alpha_bits)
    for i = 1, count do
        for c = 1, 3 do
            local v = p and bor(lshift(e[c][i], 1), p[i]) or e[c][i]
            e[c][i] = widen(v, color_bits)
        end
        if alpha_bits > 0 then
            local v = p and bor(lshift(e[4][i], 1), p[i]) or e[4][i]
            e[4][i] = widen(v, alpha_bits)
        end
    end
end

-- Endpoints: e[channel][endpoint] (channels 1-4 = R, G, B, A; endpoints 1..2*subsets), widened to 8 bits.
local function read_endpoints(m)
    local subsets, color_bits, alpha_bits = m[2], m[3], m[4]
    local count = subsets * 2
    local e = raw_endpoints(count, color_bits, alpha_bits)
    local p = nil
    if m[5] or m[6] then
        p = read_pbits(count, subsets, m[5])
        color_bits, alpha_bits = color_bits + 1, alpha_bits > 0 and alpha_bits + 1 or 0
    end
    finish_endpoints(e, p, count, color_bits, alpha_bits)
    return e
end

-- An index list (16 entries) into out: the primary one and, for modes 4 and 5, the secondary one.
local function read_indices(subsets, partition, bits, out)
    for t = 0, 15 do
        local _, anchor = subset_of(subsets, partition, t)
        out[t + 1] = read_bits(anchor and bits - 1 or bits)
    end
    return out
end

local function interpolate(a, b, weight)
    return rshift((64 - weight) * a + weight * b + 32, 6)
end

-- Decodes texel t of a parsed block b into out (RGBA at 4 * t).
local function decode_texel(b, t, out)
    local s = subset_of(b.subsets, b.partition, t)
    local e, e0, e1 = b.e, 2 * s + 1, 2 * s + 2
    local wc = WEIGHTS[b.color_bits][b.color_index[t + 1] + 1]
    local r = interpolate(e[1][e0], e[1][e1], wc)
    local g = interpolate(e[2][e0], e[2][e1], wc)
    local bl = interpolate(e[3][e0], e[3][e1], wc)
    local wa = b.alpha_index and WEIGHTS[b.alpha_bits][b.alpha_index[t + 1] + 1] or wc
    local a = interpolate(e[4][e0], e[4][e1], wa)
    local rotation = b.rotation
    if rotation == 1 then r, a = a, r elseif rotation == 2 then g, a = a, g elseif rotation == 3 then bl, a = a, bl end
    out[4 * t], out[4 * t + 1], out[4 * t + 2], out[4 * t + 3] = r, g, bl, a
end

-- The block's fields after its mode bits, parsed into BLOCK: partition, rotation, endpoints, index lists.
local function parse_block(mode)
    local m = MODES[mode]
    local b = BLOCK
    b.subsets = m[2]
    b.partition = m[1] > 0 and read_bits(m[1]) or 0
    b.rotation = (mode == 4 or mode == 5) and read_bits(2) or 0
    local selector = mode == 4 and read_bits(1) or 0
    b.e = read_endpoints(m)
    local primary = read_indices(b.subsets, b.partition, m[7], PRIMARY)
    local secondary = m[8] > 0 and read_indices(1, 0, m[8], SECONDARY) or nil
    b.color_index, b.alpha_index, b.color_bits, b.alpha_bits = primary, secondary, m[7], m[8]
    if selector == 1 then b.color_index, b.alpha_index, b.color_bits, b.alpha_bits = secondary, primary, m[8], m[7] end
    return b
end

-- Decodes one BC7 block (the 16 bytes from block[offset], offset 0 by default: no pointer made per block) into out
-- (64 bytes, RGBA per texel, row-major 4 x 4). An invalid mode gives zeros, as the format defines.
function Texture.bc7_block(block, out, offset)
    offset = offset or 0
    local first = block[offset]
    if first == 0 then
        for i = 0, 63 do out[i] = 0 end
        return
    end
    local mode = 0
    while band(rshift(first, mode), 1) == 0 do mode = mode + 1 end
    bits_block, bits_offset, bits_position = block, offset, mode + 1
    local b = parse_block(mode)
    for t = 0, 15 do decode_texel(b, t, out) end
    bits_block = nil
end

-- Stores the 16 texels of one decoded 4 x 4 block (texel: 64 bytes RGBA) at block position (bx, by) into
-- values (double array, row-major w texels per row), keeping only texels with index below count.
local function place_block(texel, bx, by, w, count, values)
    for t = 0, 15 do
        local x, y = bx * 4 + t % 4, by * 4 + rshift(t, 2)
        local i = y * w + x
        if x < w and i < count then
            for c = 0, 3 do values[i * 4 + c] = texel[t * 4 + c] / 255 end
        end
    end
end

-- The first `count` texels (row-major) of a BC7 mip `w` texels wide starting at `base`, into values.
local function bc7_texels(pixels, base, w, count, scratch, values, yield)
    local texel = ffi.new('uint8_t[64]')
    local blocks_wide = math.max(1, rshift(w + 3, 2))
    local block_rows = math.ceil(math.ceil(count / w) / 4)
    local raw = scratch(blocks_wide * block_rows * 16)
    pixels(base, blocks_wide * block_rows * 16, raw, 0)
    for by = 0, block_rows - 1 do
        for bx = 0, blocks_wide - 1 do
            Texture.bc7_block(raw, texel, (by * blocks_wide + bx) * 16)
            place_block(texel, bx, by, w, count, values)
        end
        if yield then yield() end
    end
end

-- The first `count` texels (row-major) of mip `mip` of every layer, channels/255 as {layer -> double array of
-- count * 4}. For BC7 the block rows those texels need are decoded; RGBA8 is read as is.
function Texture.samples(pixels, info, mip, count, scratch, yield)
    local w = math.max(1, rshift(info.width, mip))
    local out = {}
    for l = 0, info.layers - 1 do
        local base = l * info.layer_bytes + info.mip_offsets[mip]
        local values = ffi.new('double[?]', count * 4)
        if info.format == Texture.FORMAT_BC7 then
            bc7_texels(pixels, base, w, count, scratch, values, yield)
        else
            local raw = scratch(count * 4)
            pixels(base, count * 4, raw, 0)
            for i = 0, count * 4 - 1 do values[i] = raw[i] / 255 end
        end
        out[l] = values
        if yield then yield() end
    end
    return out
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({mip_bytes, Texture.describe, Texture.pixels, half, Texture.lut, read_bits, subset_of, widen, raw_endpoints,
        read_pbits, finish_endpoints, read_endpoints, read_indices, interpolate, decode_texel, parse_block,
        Texture.bc7_block,
        place_block, bc7_texels, Texture.samples, Texture.mask_coverage}) do
        jit.off(fn, true)
    end
end

return Texture
